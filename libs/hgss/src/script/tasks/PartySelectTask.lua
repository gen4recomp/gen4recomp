-- The blocking party-selection task behind opcode 349: it drives the
-- shared pure select controller from scheduler input edges and completes
-- with the zero-based slot or the source cancellation value. Selection
-- mutates no party state. Only the named eligibility policy, the cancel
-- permission, and the cursor serialize; the view is re-read from the live
-- service on every poll and reconciled, never stored.
--
-- Source sentinel ownership (pret/pokeheartgold@0985e8718d): opcode 349
-- launches PARTY_MENU_CONTEXT_3, where confirming an occupied slot exits
-- with that slot while B exits with partySlot 7
-- (PARTY_MON_SELECTION_CONFIRM, src/party_menu.c PartyMenu_HandleInput);
-- the companion result command writes 255 for slot 7
-- (src/scrcmd_c.c ScrCmd_GetPartySelection). The controller only ever
-- emits the semantic selected/cancelled records; this task alone
-- translates them to the script-visible slot-or-255 values.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local PartyScreenController = require("libs.hgss.src.ui.PartyScreenController")
local PartyScreenLayout = require("libs.hgss.src.ui.PartyScreenLayout")
local PartyScreenModel = require("libs.hgss.src.ui.PartyScreenModel")

local PartySelectTask = {}

PartySelectTask.type = "party_select"
PartySelectTask.version = 1

-- The script-visible cancellation value the companion result command
-- expects: the source maps the cancelled args slot to 255.
PartySelectTask.CANCEL_RESULT = 255

PartySelectTask.ELIGIBILITY_OCCUPIED = "occupied"

local DIRECTION_BY_FIELD_DIRECTION = { north = "up", south = "down", west = "left", east = "right" }

---@param policy string
local function checkPolicy(policy)
  if policy ~= PartySelectTask.ELIGIBILITY_OCCUPIED then
    Errors.raise(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "unknown party eligibility policy " .. tostring(policy), {
      policy = policy,
    })
  end
end

---@param ctx table<string, unknown>
---@return HgssMonService
local function monsService(ctx)
  local services = ctx.services
  local mons = services ~= nil and services.mons or nil
  if mons == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "party_select requires the live mon service", {})
  end
  assert(mons ~= nil, "the mon service carries the live party")
  return mons
end

---@param request table<string, unknown>
---@return table<string, unknown> normalized
local function checkRequest(request)
  assert(type(request) == "table", "party_select requires a selection request")
  assert(request.mode == "select", "party_select only runs the selection context")
  assert(
    type(request.initialSlot) == "number"
      and request.initialSlot % 1 == 0
      and request.initialSlot >= 0
      and request.initialSlot < 6,
    "party selection needs an initial slot in 0..5"
  )
  assert(type(request.eligibility) == "table", "party selection needs an eligibility policy")
  checkPolicy(request.eligibility.policy)
  assert(type(request.allowCancel) == "boolean", "party selection needs cancel permission")
  return request
end

---@param spec table<string, unknown> { request: table<string, unknown> }
---@param ctx table<string, unknown>
---@return table<string, unknown> state
function PartySelectTask.create(spec, ctx)
  assert(type(spec) == "table" and type(spec.request) == "table", "party_select requires a selection request")
  monsService(ctx)
  local request = checkRequest(spec.request)
  return {
    policy = request.eligibility.policy,
    allowCancel = request.allowCancel,
    selectedSlot = request.initialSlot,
  }
end

---@param service HgssMonService
---@param policy string
---@return fun(slot: integer): boolean
local function eligibilityFor(service, policy)
  checkPolicy(policy)
  local function isEligible(slot)
    return slot < service:partyCount()
  end
  return isEligible
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return PartyScreenController
local function controllerFor(state, ctx)
  local service = monsService(ctx)
  local isEligible = eligibilityFor(service, state.policy)
  local function refresh()
    return PartyScreenModel.build(service, { isEligible = isEligible })
  end
  local model = {
    refresh = refresh,
  }
  local function noHit(_, _, _)
    return nil
  end
  local function resolveLayout()
    return {
      neighbors = PartyScreenLayout.defaultNeighbors(state.allowCancel),
      hitTest = noHit,
    }
  end
  return PartyScreenController.new({
    mode = "select",
    initialSlot = state.selectedSlot,
    allowCancel = state.allowCancel,
    model = model,
    resolveLayout = resolveLayout,
  })
end

---@param input table<string, unknown>
---@return table<string, unknown>[]
local function controllerEvents(input)
  local events = {}
  if input.pressedDirection ~= nil then
    local direction = DIRECTION_BY_FIELD_DIRECTION[input.pressedDirection]
    if direction ~= nil then
      events[#events + 1] = { type = "navigate", direction = direction }
    end
  end
  if input.pressedAction == true then
    events[#events + 1] = { type = "confirm" }
  end
  if input.pressedCancel == true then
    events[#events + 1] = { type = "cancel" }
  end
  return events
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function PartySelectTask.poll(state, ctx)
  local controller = controllerFor(state, ctx)
  local input = ctx.input or {}
  controller:updateFixed(controllerEvents(input))
  local status = controller:status()
  if status.open and type(status.cursorNode) == "number" then
    -- The cursor node can rest on the cancel affordance, which is not a
    -- party position: only numeric slots persist for save/restore.
    state.selectedSlot = status.cursorNode
  end
  local result = controller:takeResult()
  if result == nil then
    return { complete = false, state = state }
  end
  -- Park the completed outcome on the script instance for the companion
  -- result node (the same instance-scoped handoff the menu builder uses);
  -- locals persist across save/restore, so the handoff survives with the
  -- script. The scheduler's own task-result write stays empty: no game
  -- variable is named until the result command runs.
  local instance = assert(ctx.instance, "party_select runs on a script instance")
  assert(type(instance.locals) == "table", "the script instance carries locals")
  if result.kind == "selected" then
    assert(type(result.slot) == "number", "selection completes on a party slot")
    instance.locals.__party_selection = result.slot
  else
    assert(result.kind == "cancelled", "selection ends selected or cancelled")
    instance.locals.__party_selection = PartySelectTask.CANCEL_RESULT
  end
  return { complete = true, state = state }
end

---@param state table<string, unknown>
---@param reason string
function PartySelectTask.cancel(state, reason)
  state.cancelled = reason
end

---@param state unknown
---@return Errors.Error|nil
function PartySelectTask.validate(state)
  if type(state) ~= "table" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "party_select state must be a record", {})
  end
  if type(state.allowCancel) ~= "boolean" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "party_select state needs cancel permission", {})
  end
  if
    type(state.selectedSlot) ~= "number"
    or state.selectedSlot % 1 ~= 0
    or state.selectedSlot < 0
    or state.selectedSlot >= 6
  then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "party_select cursor must sit in 0..5", {})
  end
  if state.policy ~= PartySelectTask.ELIGIBILITY_OCCUPIED then
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "party_select policy must name a known eligibility",
      { policy = state.policy }
    )
  end
  return nil
end

return PartySelectTask
