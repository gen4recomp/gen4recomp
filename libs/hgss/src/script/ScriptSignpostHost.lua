-- Script signpost host : the game-side bridge between the script
-- runtime's signpost operations and the field signpost controller. It
-- resolves message references through the injected public message-resolution
-- operation (ScriptDialogueHost:resolveMessage, never an underscored helper
-- or duplicated substitution semantics), forwards configuration and
-- window/printer requests to the controller, and advances the controller
-- once per scheduler tick from the engine-owned async phase. The host never
-- writes world variables: variable writes stay authoritative in
-- RuntimeValues.writeRef via task results. Pure domain module: no love dependency.

---@class ScriptSignpostHost
---@field private _controller FieldSignpostController
---@field private _resolveMessage fun(message: unknown, bindings: table<string, unknown>, textArgs: table<string, unknown>): FieldMessageProvider.FormattedMessage
local ScriptSignpostHost = {}
ScriptSignpostHost.__index = ScriptSignpostHost

-- Resolve the message and start the controller print as one transaction: if
-- either step raises on an already-presented signpost, that window is
-- cleaned up immediately, exactly once, before the original fault
-- propagates. A successful print leaves normal signpost/task ownership
-- untouched.
---@param message unknown
---@param bindings table<string, unknown>
---@param textArgs table<string, unknown>
---@param printStart fun(formatted: FieldMessageProvider.FormattedMessage)
function ScriptSignpostHost:_startPrintTransaction(message, bindings, textArgs, printStart)
  local ok, err = pcall(function()
    local formatted = self._resolveMessage(message, bindings, textArgs)
    printStart(formatted)
  end)
  if not ok then
    if self._controller:isModal() then
      self._controller:hideImmediately()
    end
    error(err, 0)
  end
end

---@param opts table<string, unknown> { controller, resolveMessage }
---@return ScriptSignpostHost
function ScriptSignpostHost.new(opts)
  assert(
    type(opts) == "table" and opts.controller and opts.controller.isModal,
    "script signpost host requires the signpost controller"
  )
  assert(type(opts.resolveMessage) == "function", "script signpost host requires the message-resolution operation")
  return setmetatable({
    _controller = opts.controller,
    _resolveMessage = opts.resolveMessage,
  }, ScriptSignpostHost)
end

-- The runtime equivalent of HGSS's field-text-box-open state comes straight
-- from the controller: one ownership source, no second boolean that could
-- disagree with it.
---@return boolean
function ScriptSignpostHost:isModal()
  return self._controller:isModal()
end

-- Window request: the semantic command assignment (nop/show/wipe_out/
-- wipe_in/hide). Presentation-neutral passthrough; the controller owns the
-- command state machine.
---@param command "nop"|"show"|"wipe_out"|"wipe_in"|"hide"
function ScriptSignpostHost:setCommand(command)
  self._controller:setCommand(command)
end

-- Signpost configuration: the source appearance (game/type/map) is stored as
-- presentation data. The host never resolves geometry.
---@param appearance { game: string, type: integer, map: integer }?
function ScriptSignpostHost:setSourceAppearance(appearance)
  self._controller:setSourceAppearance(appearance)
end

-- Style routing for the high-level sign operations: the script-requested
-- window style id (a registered id or a semantic appearance already resolved
-- by the runtime) is stamped into the controller's presentation, and any
-- stored source appearance is cleared — the high-level semantic sign never
-- inherits an imported signpost's type/map presentation. The host never
-- resolves geometry from it.
---@param styleId string
function ScriptSignpostHost:setStyleId(styleId)
  self._controller:setStyleId(styleId)
  self._controller:setSourceAppearance(nil)
end

-- Print the whole message instantly in the signpost window (the immediate
-- direction-signpost path): resolve and expand, then print. The request is
-- presentation-neutral; text colors are the style's, never the host's.
---@param message unknown
---@param bindings table<string, unknown>|nil
---@param textArgs table<string, unknown>|nil
function ScriptSignpostHost:printInstant(message, bindings, textArgs)
  local controller = self._controller
  self:_startPrintTransaction(message, bindings or {}, textArgs or {}, function(formatted)
    controller:printInstant(formatted)
  end)
end

-- Print at the player's configured text speed (Trainer Tips path). The
-- cadence is injected into the controller at construction from the single
-- PlayerData authority; the host never chooses one.
---@param message unknown
---@param bindings table<string, unknown>|nil
---@param textArgs table<string, unknown>|nil
function ScriptSignpostHost:printTyped(message, bindings, textArgs)
  local controller = self._controller
  self:_startPrintTransaction(message, bindings or {}, textArgs or {}, function(formatted)
    controller:printTyped(formatted)
  end)
end

-- The instant-fill operation (Trainer Tips A/B speed-up): reveal the whole
-- message immediately without dismissing the window. Direct pass-through;
-- the controller owns the printer state.
function ScriptSignpostHost:finishPrint()
  self._controller:finishPrint()
end

-- The semantic command-idle query, straight from the controller.
---@return boolean
function ScriptSignpostHost:isCommandIdle()
  return self._controller:isCommandIdle()
end

-- The semantic print query, straight from the controller: tasks ask whether
-- the print is complete without building the renderer-oriented snapshot.
---@return boolean
function ScriptSignpostHost:isPrintDone()
  return self._controller:isPrintDone()
end

-- The presentation snapshot, straight from the controller: plain data, no
-- LÖVE objects.
---@return FieldSignpostController.Status
function ScriptSignpostHost:status()
  return self._controller:status()
end

-- One fixed scheduler tick: the controller executes its current command and
-- advances its printer. The scheduler calls this from its engine-owned
-- advanceAsync callback once per tick.
---@param input table<string, unknown>|nil
function ScriptSignpostHost:advance(input)
  self._controller:updateFixed(input)
end

-- Fault/cancellation cleanup: the controller's explicit cleanup releases the
-- window, printer, command, stored offset, and routed style on the call —
-- never a fixed-tick step from outside the scheduler. Idempotent: a second
-- close has no further effect.
function ScriptSignpostHost:close()
  self._controller:hideImmediately()
end

return ScriptSignpostHost
