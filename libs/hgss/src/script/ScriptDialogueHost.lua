-- Script dialogue host : the game-side bridge between the
-- script runtime's dialogue contract and the field dialogue controller. It
-- resolves message references (`msg.hgss.<bank>.<id>` through the message
-- provider), formats substitution slots from the instance's buffered text
-- arguments, opens the controller as a script-owned request (the session's
-- modal gate skips script-owned boxes; the scheduler steps them through
-- `advance`), and reports typing progress from the controller's status.
-- Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")

---@class ScriptDialogueHost
---@field private _controller table<string, unknown> FieldDialogueController-shaped
---@field private _provider FieldMessageProvider
---@field private _layout fun(formatted: table<string, unknown>): table<string, unknown>
---@field private _fontDef table<string, unknown>
---@field private _player table<string, unknown>|nil
---@field private _world table<string, unknown>|nil world state { getVar(id) -> unknown }
---@field private _mons HgssMonService|nil the live HGSS mon service for party/mon text
---@field private _frameIndex integer|nil player-selected user-frame index, captured at open
---@field private _pendingNode table<string, unknown>|nil
local ScriptDialogueHost = {}
ScriptDialogueHost.__index = ScriptDialogueHost

-- Text-value descriptor resolvers for the implemented forms: player name,
-- the opposite protagonist's canonical name from the generated name bank,
-- and integers backed by a variable. Any other form is a fault: the
-- resolver contract never leaves a marker visible in the stream.
--
-- The opposite protagonist's canonical name lives in generated message bank
-- 445: message 1 names her for a male player, message 0 names him for a
-- female player. The source `BufferFriendsName` operation addresses that
-- bank through the player gender, so this boundary reads it the same way
-- instead of hard-coding either name.
local FRIEND_NAME_BANK_ID = 445

-- Read one generated message as substitution glyphs with scoped bank
-- ownership: the nested bank reference is released after a successful read
-- and also released before rethrowing the original fault when the bank get,
-- text parsing, or substitution formatting fails.
---@param provider FieldMessageProvider
---@param bankId integer
---@param messageId integer
---@param fontDef table<string, unknown>
---@return table<string, unknown> replacementTokens glyph-kind tokens without a terminal marker
local function scopedNameGlyphs(provider, bankId, messageId, fontDef)
  local acquired, acquireErr = provider:acquireBank(bankId)
  if not acquired then
    error(acquireErr, 0)
  end
  local template, templateErr = provider:get(bankId, messageId)
  if not template then
    provider:releaseBank(bankId)
    error(templateErr, 0)
  end
  local tokens, parseErr = FieldMessageProvider.asciiGlyphTokens(template.text, fontDef)
  if not tokens then
    provider:releaseBank(bankId)
    error(parseErr, 0)
  end
  provider:releaseBank(bankId)
  return tokens
end

-- Evaluates a text-operand that may be a literal scalar or a variable
-- reference through the world state.
---@param operand unknown
---@param world table<string, unknown>|nil
---@return unknown
local function evaluateTextOperand(operand, world)
  if type(operand) == "table" and operand.value == "var" then
    if world == nil or world.getVar == nil then
      local context = { operand = operand }
      ---@cast context Errors.Context
      Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "buffered text variable requires the world state", context)
    end
    local worldState = world --[[@as { getVar: fun(self: table, id: unknown): unknown }]]
    return worldState:getVar(operand.id)
  end
  return operand
end

-- Mon/party text identities. Returns the display string, or nil when the
-- descriptor names a form owned elsewhere. Out-of-range party positions
-- fail through the service's structured slot validation rather than
-- rendering an empty window.
---@param kind string
---@param descriptor table<string, unknown>
---@param mons HgssMonService the live HGSS mon service
---@param world table<string, unknown>|nil
---@return string|nil
local function resolveMonsTextValue(kind, descriptor, mons, world)
  local Mon = require("libs.mons.src.Mon")
  local catalog = mons:catalog()
  if kind == "party_species_name" then
    local position = evaluateTextOperand(descriptor.position, world)
    local mon = mons:partyMon(position)
    return catalog:species(mon.species).name
  elseif kind == "party_nickname" then
    local position = evaluateTextOperand(descriptor.position, world)
    return Mon.displayName(mons:partyMon(position), catalog)
  elseif kind == "species_name" then
    local identity = evaluateTextOperand(descriptor.value, world)
    if type(identity) == "number" then
      return catalog:speciesByNativeId(identity).name
    end
    return catalog:species(identity --[[@as string]]).name
  elseif kind == "move_name" then
    local identity = evaluateTextOperand(descriptor.value, world)
    if type(identity) == "number" then
      return catalog:moveByNativeId(identity).name
    end
    return catalog:move(identity --[[@as string]]).name
  elseif kind == "party_mon_move_name" then
    local position = evaluateTextOperand(descriptor.position, world)
    local moveSlot = evaluateTextOperand(descriptor.moveSlot, world)
    local mon = mons:partyMon(position)
    local entry
    if type(moveSlot) == "number" then
      entry = mon.moves[moveSlot + 1]
    end
    if type(moveSlot) ~= "number" or entry == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_INVALID_REFERENCE,
        "party move slot is out of range",
        { position = position, moveSlot = moveSlot }
      )
    end
    assert(entry ~= nil, "move entry carries the validated move")
    return catalog:move(entry.move).name
  elseif kind == "nature_name" then
    local nature = evaluateTextOperand(descriptor.value, world)
    return require("libs.hgss.src.mons.HgssMonService").natureName(nature --[[@as integer]])
  end
  return nil
end

-- Text-value descriptor resolvers for the implemented forms: player name,
-- integers backed by a variable, and mon/party identities resolved through
-- the injected live mon service and its catalog. Any other form is a fault:
-- the resolver contract never leaves a marker visible in the stream.
---@param descriptor table<string, unknown>
---@param player table<string, unknown>
---@param fontDef table<string, unknown>
---@param world table<string, unknown>|nil
---@param provider FieldMessageProvider
---@param mons HgssMonService|nil the live HGSS mon service
---@return table<string, unknown>|nil replacementTokens
local function resolveTextValue(descriptor, player, fontDef, world, provider, mons)
  if type(descriptor) ~= "table" or descriptor.text == nil then
    return nil
  end
  local kind = descriptor.text
  local value = descriptor.value
  if kind == "player_name" then
    return FieldMessageProvider.asciiGlyphTokens(player:name(), fontDef)
  elseif kind == "friend_name" then
    local gender = player:gender()
    return scopedNameGlyphs(provider, FRIEND_NAME_BANK_ID, gender == 0 and 1 or 0, fontDef)
  elseif kind == "integer" then
    if value == nil or type(value) ~= "table" or value.value ~= "var" then
      return nil
    end
    if world == nil or world.getVar == nil then
      local context = { kind = kind, value = value }
      ---@cast context Errors.Context
      Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "integer text values require the world state", context)
    end
    local worldState = world --[[@as { getVar: fun(self: table, id: unknown): unknown }]]
    return FieldMessageProvider.asciiGlyphTokens(tostring(worldState:getVar(value.id)), fontDef)
  end
  if mons ~= nil and type(kind) == "string" then
    local resolved = resolveMonsTextValue(kind, descriptor, mons, world)
    if resolved ~= nil then
      return FieldMessageProvider.asciiGlyphTokens(resolved, fontDef)
    end
  end
  Errors.raise(
    ScriptErrors.SCRIPT_UNSUPPORTED_REACHABLE,
    "unsupported buffered text form " .. tostring(kind),
    { kind = kind }
  )
end

---@param opts table<string, unknown> { controller, provider, layout, fontDef, player, world, mons?, frameIndex? }
---@return ScriptDialogueHost
function ScriptDialogueHost.new(opts)
  assert(
    type(opts) == "table" and opts.controller and opts.provider,
    "script dialogue host requires a controller and message provider"
  )
  assert(type(opts.layout) == "function", "script dialogue host requires the dialogue layout")
  assert(
    type(opts.fontDef) == "table" and type(opts.fontDef.charmap) == "table",
    "script dialogue host requires the generated font definition"
  )
  assert(opts.player and type(opts.player.name) == "function", "script dialogue host requires the player facade")
  local frameIndex = opts.frameIndex
  assert(
    frameIndex == nil or (type(frameIndex) == "number" and frameIndex >= 0 and frameIndex % 1 == 0),
    "script dialogue host frameIndex must be a non-negative integer"
  )
  return setmetatable({
    _controller = opts.controller,
    _provider = opts.provider,
    _layout = opts.layout,
    _fontDef = opts.fontDef,
    _player = opts.player,
    _world = opts.world,
    _mons = opts.mons,
    _frameIndex = frameIndex,
  }, ScriptDialogueHost)
end

function ScriptDialogueHost:isOpen()
  return self._controller:isModal()
end

-- Resolve a message reference to a controller-ready formatted message.
---@param message unknown string reference or external descriptor
---@param bindings table<string, unknown> slot -> text value
---@param textArgs table<string, unknown> slot -> text value
---@return FieldMessageProvider.FormattedMessage formatted { tokens, ... }
function ScriptDialogueHost:resolveMessage(message, bindings, textArgs)
  local bankId, messageId
  if type(message) == "string" then
    bankId, messageId = message:match("^msg%.hgss%.(%d+)%.(%d+)$")
    if bankId == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_INVALID_REFERENCE,
        "unknown message reference " .. tostring(message),
        { message = message }
      )
    end
    bankId, messageId = tonumber(bankId), tonumber(messageId)
  elseif type(message) == "table" and message.message == "external" then
    bankId, messageId = message.bank, message.id
    if type(bankId) ~= "number" or bankId % 1 ~= 0 or type(messageId) ~= "number" or messageId % 1 ~= 0 then
      Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "external message location is invalid", { message = message })
    end
  else
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "unsupported message reference form", { message = message })
  end
  local bank, bankErr = self._provider:acquireBank(bankId)
  if not bank then
    local err = bankErr --[[@as Errors.Error]]
    local context = { bankId = bankId, cause = err.context }
    ---@cast context Errors.Context
    Errors.raise(err.code, err.message, context)
  end
  local template, templateErr = self._provider:get(bankId, messageId)
  if not template then
    self._provider:releaseBank(bankId)
    local err = templateErr --[[@as Errors.Error]]
    local context = { bankId = bankId, messageId = messageId, cause = err.context }
    ---@cast context Errors.Context
    Errors.raise(err.code, err.message, context)
  end
  -- One resolver per substitution control; the buffer slot is each marker's
  -- own first argument, so a control occurring at several slots resolves
  -- every occurrence from its own slot. The node's own bindings win over
  -- instance textArgs.
  local resolvers = {}
  local templateTokens = template --[[@as table]].tokens
  for _, token in ipairs(templateTokens) do
    if token.kind == "substitution" and token.args ~= nil and resolvers[token.control] == nil then
      local function resolveSubstitution(_, args, _)
        local slot = args and args[1]
        local descriptor = bindings[slot] or textArgs[slot]
        return resolveTextValue(descriptor, self._player, self._fontDef, self._world, self._provider, self._mons)
      end
      resolvers[token.control] = resolveSubstitution
    end
  end
  local okFormat, formatted = pcall(self._provider.format, self._provider, template, {}, resolvers)
  self._provider:releaseBank(bankId)
  if not okFormat then
    error(formatted)
  end
  if formatted.hadUnresolvedSubstitutions then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "message " .. message .. " has unresolvable substitutions",
      { bankId = bankId, messageId = messageId }
    )
  end
  return formatted
end

-- Open: called with the graph node; the controller request
-- opens on the following startPrint so a failed resolve cannot leave a
-- half-open box.
---@param node table<string, unknown>
function ScriptDialogueHost:openMessage(node)
  self._pendingNode = node
end

-- Open the controller as a script-owned request and start revealing.
---@param message unknown
---@param bindings table<string, unknown>|nil
---@param textArgs table<string, unknown>|nil
function ScriptDialogueHost:startPrint(message, bindings, textArgs)
  local node = self._pendingNode or {}
  self._pendingNode = nil
  local formatted = self:resolveMessage(message, bindings or {}, textArgs or {})
  -- Stable per-node identity for diagnostics: the full reference string,
  -- never a digit run that could collide across banks.
  local id = "script-dialogue"
  if node.message ~= nil then
    id = "script-" .. tostring(node.message):gsub("[^%w]", "_")
  end
  self._controller:open({
    id = id,
    message = formatted,
    allowCancel = false,
    frameIndex = self._frameIndex,
    metadata = {
      scriptOwned = true,
      message = message,
    },
  })
end

-- Typing progress for the dialogue task: page and glyph within the current
-- page, plus completion of the whole reveal (the controller reached its
-- final wait).
---@return table<string, unknown>|nil { pageIndex, glyphIndex, done }
function ScriptDialogueHost:printProgress()
  if not self:isOpen() then
    return { pageIndex = 0, glyphIndex = 0, done = true }
  end
  local status = self._controller:status()
  local done = status.state == "WAITING_CLOSE" or status.state == "CLOSING" or status.state == "CLOSED"
  return {
    pageIndex = math.max(0, (status.pageIndex or 1) - 1),
    glyphIndex = status.revealedGlyphs or 0,
    done = done,
  }
end

-- Close the box (idempotent on the controller). A non-erasing close would
-- need a message buffer the controller does not own; requesting one is an
-- attributed fault rather than a silent ignore.
---@param erase boolean
function ScriptDialogueHost:close(erase)
  if erase == false then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the dialogue controller cannot preserve a closed message box")
  end
  self._controller:close()
end

-- Message-hold and waiting-icon controls are part of the script dialogue
-- contract the controller does not implement; reaching them is an
-- attributed fault, never a silent no-op.
function ScriptDialogueHost:hold()
  Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the dialogue controller cannot hold a message")
end

function ScriptDialogueHost:showWaitingIcon()
  Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the dialogue controller has no waiting icon")
end

function ScriptDialogueHost:hideWaitingIcon()
  Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the dialogue controller has no waiting icon")
end

-- Advance an open script-owned box by one fixed tick. The scheduler calls
-- this from its engine-owned async phase with the immutable input snapshot;
-- the session's modal gate never steps script-owned requests.
---@param input table<string, unknown>|nil
function ScriptDialogueHost:advance(input)
  if not self:isOpen() then
    return
  end
  input = input or {}
  local status = self._controller:status()
  -- DialogueTask owns the final confirm edge and performs the delayed close.
  -- Passing that edge to the controller would close it early, leaving the
  -- task blocked forever waiting for an edge that has already been consumed.
  local actionPressed = input.pressedAction == true and status.state ~= "WAITING_CLOSE"
  local cancelPressed = input.pressedCancel == true and status.state ~= "WAITING_CLOSE"
  self._controller:step({
    actionPressed = actionPressed,
    actionDown = input.actionDown == true,
    cancelPressed = cancelPressed,
    cancelDown = input.cancelDown == true,
  })
end

return ScriptDialogueHost
