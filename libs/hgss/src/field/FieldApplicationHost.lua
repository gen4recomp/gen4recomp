-- The one application modal owner the field session steps: it owns the
-- active controller, the transition phase machine (closed/menu/fading_out/
-- application/fading_in, plus the terminal failed state for factory
-- failures), the Start Menu selection remembered across a child-application
-- round trip, the modal input lifetime (beginUi once at open, clearUi once
-- on final field return, failure, or disposal), and exactly-once disposal of
-- the active controller on success, cancellation, failure, reset, or runtime
-- disposal. The Start Menu is not an application-registry entry: the host
-- constructs it through its required menuFactory (the runtime's composition
-- step) on open and rebuild; a menuFactory result of nil means the menu is
-- currently unavailable (no interactive actions) and the open is a no-op --
-- the host stays closed and the field continues. An open whose composition
-- throws is a terminal failure: the host enters its failed phase, which owns
-- the tick, so the session must not run any later world phase that tick.
-- The host dispatches child destinations through the immutable
-- FieldApplicationRegistry. Its own
-- fixed-tick fade counter exposes fadeAlpha; FieldTransition is not reused
-- (it owns warp preparation, map protection, and map swaps). The host never
-- launches a child by itself: the menu controller records
-- { kind = "launch", applicationId } results and the host dispatches them
-- through the registry only after the fade-out hides the world. Pointer
-- events are mapped through the StartMenuLayout placement record the runtime
-- supplies; scroll events are not forwarded to the Start Menu. Pure module:
-- no love, no I/O.

local StartMenuLayout = require("libs.hgss.src.field.StartMenuLayout")

---@class FieldApplicationHostOptions
---@field registry FieldApplicationRegistry the immutable per-runtime child-application catalogue
---@field menuFactory fun(rememberedActionId: string?): table<string, unknown>? the Start Menu composition step (nil = menu currently unavailable)
---@field input FieldInput the field input whose modal lifetime the host acquires/releases
---@field fieldAction fun(actionId: string) immediate field-action dispatcher
---@field effect fun(sequence: string)? source UI sound effect boundary

---@class FieldApplicationHost
---@field _registry FieldApplicationRegistry
---@field _menuFactory fun(rememberedActionId: string?): table<string, unknown>?
---@field _input FieldInput
---@field _fieldAction fun(actionId: string)
---@field _phase string
---@field _fadeTicks integer
---@field _fadeAlpha number
---@field _controller table<string, unknown>? the active controller (menu or destination)
---@field _rememberedActionId string?
---@field _applicationId string?
---@field _failure unknown? retained factory/composition failure
---@field _uiHeld boolean the modal input lifetime is held (beginUi done, clearUi pending)
---@field _reopenPending boolean a script reopen request awaits the session
---@field _layout StartMenuLayout.Placement? the StartMenuLayout placement record (setMenuPlacement)
---@field _effect fun(sequence: string)? source UI sound effect boundary
local FieldApplicationHost = {}
FieldApplicationHost.__index = FieldApplicationHost

-- The host's own fixed-tick fade counter: the same 12-tick cadence as the
-- field transition's warp fades. Only the fade length lives here; the phase
-- sequence is the host's own contract.
FieldApplicationHost.FADE_TICKS = 12

-- The normal lifecycle phases plus the terminal failure state
-- (the runtime is left in one terminally consistent state).
FieldApplicationHost.PHASES = {
  closed = "closed",
  menu = "menu",
  fading_out = "fading_out",
  application = "application",
  fading_in = "fading_in",
  failed = "failed",
}

---@param options FieldApplicationHostOptions
---@return FieldApplicationHost
function FieldApplicationHost.new(options)
  assert(options and options.registry and options.registry.create, "the application host requires the registry")
  assert(options and type(options.menuFactory) == "function", "the application host requires the start menu factory")
  assert(
    options and options.input and options.input.beginUi and options.input.clearUi,
    "the application host requires the input"
  )
  assert(options and type(options.fieldAction) == "function", "the application host requires field actions")
  return setmetatable({
    _registry = options.registry,
    _menuFactory = options.menuFactory,
    _input = options.input,
    _fieldAction = options.fieldAction,
    _phase = FieldApplicationHost.PHASES.closed,
    _fadeTicks = 0,
    _fadeAlpha = 0,
    _controller = nil,
    _rememberedActionId = nil,
    _applicationId = nil,
    _failure = nil,
    _uiHeld = false,
    _reopenPending = false,
    _layout = nil,
    _effect = options.effect,
  }, FieldApplicationHost)
end

-- The presentation snapshot: the phase, the host-owned fade
-- alpha, the active application id (while a destination owns the tick or is
-- being entered/left), the Start Menu presentation status while the menu
-- phase runs, and the active destination's own presentation status while
-- the application phase runs (the renderer channel: FieldState
-- chooses the destination renderer from this snapshot; only the one active
-- modal surface is presented).
---@return { phase: string, fadeAlpha: number, applicationId?: string, menu?: table<string, unknown>, application?: table<string, unknown> }
function FieldApplicationHost:status()
  local phase = self._phase
  local status = {
    phase = phase,
    fadeAlpha = self._fadeAlpha,
  }
  if self._applicationId ~= nil then
    status.applicationId = self._applicationId
  end
  local controller = self._controller
  if controller ~= nil and phase == FieldApplicationHost.PHASES.menu then
    status.menu = controller:status()
  end
  if controller ~= nil and phase == FieldApplicationHost.PHASES.application then
    status.application = controller:status()
  end
  return status
end

-- Whether the host owns the tick: while active, the field session steps no
-- world simulation and the save gate stays closed.
---@return boolean
function FieldApplicationHost:isActive()
  return self._phase ~= FieldApplicationHost.PHASES.closed
end

-- The retained factory/composition failure, or nil. The runtime surfaces it
-- as its fatal error text and freezes.
---@return unknown?
function FieldApplicationHost:error()
  return self._failure
end

-- The single acquisition point: constructs the Start Menu through the
-- menuFactory, begins the modal input lifetime, and enters the menu phase on
-- the opening tick. The session returns immediately after the open, so the
-- controller cannot receive input during the opener's tick. Returns whether
-- the open consumed the tick: true for a successful open and for a fatal
-- composition failure (the terminal failed state owns the tick); false only
-- when the factory returns nil -- the menu is unavailable and the field may
-- continue on that tick. A failed composition acquires nothing: no
-- controller, no input lifetime, only the retained error.
---@param tick integer
---@return boolean consumed
function FieldApplicationHost:requestOpen(tick)
  assert(self._phase == FieldApplicationHost.PHASES.closed, "the application host must be closed to open the menu")
  assert(tick == math.floor(tick) and tick >= 0, "the menu open requires a non-negative tick")
  return self:_openMenu(tick, nil)
end

-- Script-side reopen request (the opcode-61 startMenuReopen service): the
-- request is queued and the session consumes it through takeReopen at its
-- post-scheduler arbitration point, so the open consumes a tick of its own.
function FieldApplicationHost:requestReopen()
  assert(self._phase == FieldApplicationHost.PHASES.closed, "a reopen must not target an active application")
  self._reopenPending = true
end

-- Consumes a pending script reopen request by opening the menu. Returns
-- whether the open consumed the tick: true for a successful open and for a
-- fatal composition failure (the terminal failed state owns the tick); false
-- when there was no pending request or the menu is unavailable, so the field
-- continues that tick. The pending request itself is cleared either way.
---@param tick integer
---@return boolean consumed
function FieldApplicationHost:takeReopen(tick)
  if not self._reopenPending then
    return false
  end
  self._reopenPending = false
  return self:_openMenu(tick, nil)
end

-- The menu construction shared by open and reopen. The controller is built
-- through the menu factory before beginUi so a failed composition never
-- begins the input lifetime; beginUi flushes stale UI edges at modal
-- ownership begin so the opening edge cannot immediately close the menu it
-- opened. Returns whether the open consumed the tick: true when the menu
-- opened and when a composition failure entered the terminal failed state
-- (which owns the tick); false when the factory returns nil -- the menu is
-- unavailable and the host stays closed.
---@param tick integer
---@param rememberedActionId string?
---@return boolean consumed
function FieldApplicationHost:_openMenu(tick, rememberedActionId)
  if self._effect then
    self._effect("SEQ_SE_DP_WIN_OPEN")
  end
  local ok, controller = pcall(self._menuFactory, rememberedActionId)
  if not ok then
    self:_fail(controller)
    return true
  end
  if controller == nil then
    return false
  end
  self._controller = controller
  self._rememberedActionId = rememberedActionId
  self._input:beginUi(tick)
  self._uiHeld = true
  self._fadeTicks = 0
  self._fadeAlpha = 0
  self._phase = FieldApplicationHost.PHASES.menu
  return true
end

-- Terminal failure ownership: retain the original error, release the active
-- controller and the modal input lifetime if held, clear the pending
-- destination and fade state, and freeze the host. No successful return to
-- the menu is ever reported; the runtime surfaces the error and stops
-- stepping. No recovery is attempted.
---@param failure unknown
function FieldApplicationHost:_fail(failure)
  self._failure = failure
  self:_disposeController()
  self:_releaseUi()
  self._applicationId = nil
  self._fadeTicks = 0
  self._fadeAlpha = 0
  self._phase = FieldApplicationHost.PHASES.failed
end

-- Disposes the active controller exactly once (idempotent).
function FieldApplicationHost:_disposeController()
  local controller = self._controller
  self._controller = nil
  if controller ~= nil then
    controller:dispose()
  end
end

-- Releases the modal input lifetime exactly once (the final field return,
-- failure, or host disposal).
function FieldApplicationHost:_releaseUi()
  if self._uiHeld then
    self._input:clearUi()
    self._uiHeld = false
  end
end

-- Rebuilds the Start Menu after a child-application return with the
-- remembered selection by action id. A failed rebuild is retained after the
-- destination's own disposal; nothing re-enters the menu. An unavailable
-- menu (nil factory result) releases the modal lifetime and returns to the
-- field.
function FieldApplicationHost:_rebuildMenu()
  local remembered = self._rememberedActionId
  local ok, controller = pcall(self._menuFactory, remembered)
  if not ok then
    self:_fail(controller)
    return
  end
  if controller == nil then
    self:_releaseUi()
    self._applicationId = nil
    self._fadeTicks = 0
    self._fadeAlpha = 0
    self._phase = FieldApplicationHost.PHASES.closed
    return
  end
  self._controller = controller
  self._applicationId = nil
  self._phase = FieldApplicationHost.PHASES.menu
end

-- One fixed tick of the phase machine. The session steps the host exactly
-- once per tick while it is active and feeds it the single UI event list of
-- the tick; no other modal controller receives the same events.
---@param uiInput table[]
function FieldApplicationHost:updateFixed(uiInput)
  assert(self._phase ~= FieldApplicationHost.PHASES.closed, "a closed host is not stepped")
  local phase = self._phase
  if phase == FieldApplicationHost.PHASES.failed then
    return
  end
  if phase == FieldApplicationHost.PHASES.menu then
    self:_stepMenu(uiInput)
    return
  end
  if phase == FieldApplicationHost.PHASES.fading_out then
    self:_stepFadeOut()
    return
  end
  if phase == FieldApplicationHost.PHASES.application then
    self:_stepApplication(uiInput)
    return
  end
  if phase == FieldApplicationHost.PHASES.fading_in then
    self:_stepFadeIn()
    return
  end
  error("unknown application host phase " .. tostring(phase), 2)
end

-- Maps one UI event list for the menu controller: pointer events are
-- consumed by the host (mapped through the StartMenuLayout placement record
-- into canonical logical 0..255 x 0..191 and dropped outside the menu frame;
-- without a placement there is no pointer support at all), unsupported
-- pointer scroll events are dropped rather than taught to the controller,
-- and non-pointer events pass through unchanged.
---@param uiInput table[]
---@return table[]
function FieldApplicationHost:_mapMenuEvents(uiInput)
  local mapped = {}
  for _, event in ipairs(uiInput) do
    if type(event) == "table" and type(event.x) == "number" and type(event.y) == "number" then
      if self._layout ~= nil then
        local x, y = StartMenuLayout.hostToLogical(self._layout, event.x, event.y)
        if x ~= nil then
          mapped[#mapped + 1] = {
            type = event.type,
            pointerId = event.pointerId,
            x = x,
            y = y,
            dragged = event.dragged,
          }
        end
      end
    elseif not (type(event) == "table" and event.type == "pointer_scroll") then
      mapped[#mapped + 1] = event
    end
  end
  return mapped
end

-- The menu phase: one controller step with the tick's (mapped) events, then
-- the recorded result is dispatched. A launch freezes further menu input
-- and starts the fade-out; a close disposes the menu exactly once and
-- releases the input lifetime on the final field return.
---@param uiInput table[]
function FieldApplicationHost:_stepMenu(uiInput)
  local controller = assert(self._controller, "the menu phase requires the menu controller")
  controller:updateFixed(self:_mapMenuEvents(uiInput))
  local result = controller:takeResult()
  if result == nil then
    return
  end
  assert(result.kind == "launch" or result.kind == "field_action" or result.kind == "close", "unknown menu result kind")
  if result.kind == "field_action" then
    assert(type(result.actionId) == "string", "a field action needs an action id")
    local ok, failure = pcall(self._fieldAction, result.actionId)
    if not ok then
      self:_fail(failure)
      return
    end
    self:_disposeController()
    self:_releaseUi()
    self._phase = FieldApplicationHost.PHASES.closed
    self._fadeAlpha = 0
    return
  end
  if result.kind == "launch" then
    assert(type(result.applicationId) == "string", "a menu launch needs a destination id")
    -- The remembered selection rides the launch result: the host restores
    -- the rebuilt menu's selection by this action id after the round trip.
    self._rememberedActionId = result.actionId
    self._applicationId = result.applicationId
    self._fadeTicks = 0
    self._fadeAlpha = 0
    self._phase = FieldApplicationHost.PHASES.fading_out
  else
    self:_disposeController()
    self:_releaseUi()
    self._phase = FieldApplicationHost.PHASES.closed
    self._fadeAlpha = 0
  end
end

-- The fade-out: the host's own fixed-tick counter moves fadeAlpha 0 -> 1.
-- When the world is hidden the Start Menu presentation is disposed exactly
-- once and the destination is constructed through the registry; the
-- destination's first step arrives on the tick after construction -- menu
-- input was frozen for the whole fade, so presses from the fade period must
-- never reach the destination.
function FieldApplicationHost:_stepFadeOut()
  self._fadeTicks = self._fadeTicks + 1
  self._fadeAlpha = math.min(1, self._fadeTicks / FieldApplicationHost.FADE_TICKS)
  if self._fadeTicks < FieldApplicationHost.FADE_TICKS then
    return
  end
  self:_disposeController()
  local applicationId = assert(self._applicationId, "the fade-out requires the destination id")
  local ok, controller = pcall(self._registry.create, self._registry, applicationId)
  if not ok then
    -- Retain the original error, release anything the failed
    -- factory/host acquired, and leave the runtime terminally consistent.
    self:_fail(controller)
    return
  end
  self._controller = controller
  self._phase = FieldApplicationHost.PHASES.application
end

-- The application phase: the destination is stepped once per fixed tick
-- with the tick's events; its close result disposes it exactly once and
-- starts the fade-in back to the rebuilt menu.
---@param uiInput table[]
function FieldApplicationHost:_stepApplication(uiInput)
  local controller = assert(self._controller, "the application phase requires the destination controller")
  controller:updateFixed(uiInput)
  local result = controller:takeResult()
  if result == nil then
    return
  end
  assert(result.kind == "close", "a destination controller only returns close")
  self:_disposeController()
  self._fadeTicks = 0
  self._fadeAlpha = 1
  self._phase = FieldApplicationHost.PHASES.fading_in
end

-- The fade-in: the counter moves fadeAlpha 1 -> 0; at the fully restored
-- boundary the menu is rebuilt from current policy/capabilities with the
-- remembered selection and input arms again.
function FieldApplicationHost:_stepFadeIn()
  self._fadeTicks = self._fadeTicks + 1
  self._fadeAlpha = math.max(0, 1 - self._fadeTicks / FieldApplicationHost.FADE_TICKS)
  if self._fadeTicks < FieldApplicationHost.FADE_TICKS then
    return
  end
  self:_rebuildMenu()
end

-- Stores the StartMenuLayout placement record the renderer and the pointer
-- mapper share. The host may perform the inverse placement transform for
-- pointer mapping, but it does not choose layout: the runtime computes the
-- placement and re-applies it on presentation-geometry changes. A press held
-- across a placement change must not activate a different post-change slot,
-- so an active menu pointer capture is cancelled.
---@param placement StartMenuLayout.Placement?
function FieldApplicationHost:setMenuPlacement(placement)
  self._layout = placement
  -- Only the menu controller ever holds a pointer capture; destinations own
  -- their input policy and capture none.
  if self._phase == FieldApplicationHost.PHASES.menu and self._controller ~= nil then
    self._controller:cancelPointerCapture()
  end
end

-- The one teardown path for reset and runtime disposal: dispose the active
-- controller exactly once, release the modal input lifetime once, clear the
-- queued script reopen, and return to closed. The helpers are idempotent, so
-- unconditional teardown is safe from any phase, including a closed phase
-- that still holds a pending reopen.
function FieldApplicationHost:dispose()
  self:_disposeController()
  self:_releaseUi()
  self._reopenPending = false
  self._applicationId = nil
  self._failure = nil
  self._fadeTicks = 0
  self._fadeAlpha = 0
  self._phase = FieldApplicationHost.PHASES.closed
end

return FieldApplicationHost
