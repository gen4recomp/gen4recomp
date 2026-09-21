-- The one application modal owner the field session steps: it owns the
-- Start Menu controller and, while a child destination is open, the
-- foreground application controller (closed/menu/application, plus the
-- terminal failed state for factory failures), the Start Menu selection
-- remembered across a child-application round trip, the modal input
-- lifetime (beginUi once at open, clearUi once on final field return,
-- failure, or disposal), and exactly-once disposal of each owned
-- controller on success, cancellation, failure, reset, or runtime
-- disposal. The Start Menu is not an application-registry entry: the host
-- constructs it through its required menuFactory (the runtime's composition
-- step) on open and rebuild; a menuFactory result of nil means the menu is
-- currently unavailable (no interactive actions) and the open is a no-op --
-- the host stays closed and the field continues. An open whose composition
-- throws is a terminal failure: the host enters its failed phase, which owns
-- the tick, so the session must not run any later world phase that tick.
-- The host dispatches child destinations through the immutable
-- FieldApplicationRegistry and publishes them on the launch tick over the
-- retained Start Menu: the menu stays drawable while the child owns
-- semantic input, and a fresh menu is composed atomically when the child
-- closes so policy changes are reflected. The host never launches a child
-- by itself: the menu controller records { kind = "launch", applicationId }
-- results and the host dispatches them through the registry on that same
-- tick. Pointer events reach the menu wrapper unmapped: the wrapper owns
-- its presentation session and maps host coordinates itself, so the host
-- never holds a placement record and never drops scroll events on the
-- menu's behalf. Pure module: no love, no I/O.

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
---@field _menuController table<string, unknown>? the Start Menu controller, retained under an open child
---@field _applicationController table<string, unknown>? the foreground destination controller while open
---@field _rememberedActionId string?
---@field _applicationId string?
---@field _failure unknown? retained factory/composition failure
---@field _uiHeld boolean the modal input lifetime is held (beginUi done, clearUi pending)
---@field _reopenPending boolean a script reopen request awaits the session
---@field _effect fun(sequence: string)? source UI sound effect boundary
local FieldApplicationHost = {}
FieldApplicationHost.__index = FieldApplicationHost

-- The normal lifecycle phases plus the terminal failure state
-- (the runtime is left in one terminally consistent state).
FieldApplicationHost.PHASES = {
  closed = "closed",
  menu = "menu",
  application = "application",
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
    _menuController = nil,
    _applicationController = nil,
    _rememberedActionId = nil,
    _applicationId = nil,
    _failure = nil,
    _uiHeld = false,
    _reopenPending = false,
    _effect = options.effect,
  }, FieldApplicationHost)
end

-- The presentation snapshot: the phase, the active application id (while a
-- destination owns the tick), the retained Start Menu presentation status
-- while the menu phase runs and while a destination is open above it, and
-- the foreground destination's own presentation status while the
-- application phase runs (the renderer channel: FieldState draws the menu
-- first and the destination second; both modal surfaces are presented).
---@return { phase: string, applicationId?: string, menu?: table<string, unknown>, application?: table<string, unknown> }
function FieldApplicationHost:status()
  local phase = self._phase
  local status = {
    phase = phase,
  }
  if self._applicationId ~= nil then
    status.applicationId = self._applicationId
  end
  local menu = self._menuController
  if
    menu ~= nil and (phase == FieldApplicationHost.PHASES.menu or phase == FieldApplicationHost.PHASES.application)
  then
    status.menu = menu:status()
  end
  local application = self._applicationController
  if application ~= nil and phase == FieldApplicationHost.PHASES.application then
    status.application = application:status()
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
  self._menuController = controller
  self._rememberedActionId = rememberedActionId
  self._input:beginUi(tick)
  self._uiHeld = true
  self._phase = FieldApplicationHost.PHASES.menu
  return true
end

-- Terminal failure ownership: retain the original error, release both owned
-- controllers and the modal input lifetime if held, clear the pending
-- destination, and freeze the host. No successful return to the menu is
-- ever reported; the runtime surfaces the error and stops stepping. No
-- recovery is attempted, and the stale retained menu is never republished.
---@param failure unknown
function FieldApplicationHost:_fail(failure)
  self._failure = failure
  self:_disposeMenuController()
  self:_disposeApplicationController()
  self:_releaseUi()
  self._applicationId = nil
  self._phase = FieldApplicationHost.PHASES.failed
end

-- Disposes the retained menu controller exactly once (idempotent).
function FieldApplicationHost:_disposeMenuController()
  local controller = self._menuController
  self._menuController = nil
  if controller ~= nil then
    controller:dispose()
  end
end

-- Disposes the foreground destination controller exactly once (idempotent).
function FieldApplicationHost:_disposeApplicationController()
  local controller = self._applicationController
  self._applicationController = nil
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
  if phase == FieldApplicationHost.PHASES.application then
    self:_stepApplication(uiInput)
    return
  end
  error("unknown application host phase " .. tostring(phase), 2)
end

-- Delegates capture cancellation to each live owner (the retained menu and,
-- while open, the foreground child), which drops its session and controller
-- presses so a stale release never activates. Controllers without the
-- capability (keyboard-only destinations) stay valid without it, and a host
-- with no live controller cancels nothing.
function FieldApplicationHost:cancelPointerCapture()
  local menu = self._menuController
  if menu ~= nil then
    local cancel = menu.cancelPointerCapture
    if type(cancel) == "function" then
      cancel(menu)
    end
  end
  local application = self._applicationController
  if application ~= nil then
    local cancel = application.cancelPointerCapture
    if type(cancel) == "function" then
      cancel(application)
    end
  end
end

-- The menu phase: one controller step with the tick's normalized events,
-- then the recorded result is dispatched. The menu wrapper maps pointer
-- input through its own presentation session, so the host forwards the
-- batch unchanged like a child destination. A launch preserves the menu
-- controller and publishes the staged child on the same tick; a close or
-- field action disposes the menu exactly once and releases the input
-- lifetime on the final field return.
---@param uiInput table[]
function FieldApplicationHost:_stepMenu(uiInput)
  local controller = assert(self._menuController, "the menu phase requires the menu controller")
  controller:updateFixed(uiInput)
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
    self:_disposeMenuController()
    self:_releaseUi()
    self._phase = FieldApplicationHost.PHASES.closed
    return
  end
  if result.kind == "launch" then
    assert(type(result.applicationId) == "string", "a menu launch needs a destination id")
    -- The remembered selection rides the launch result: the host restores
    -- the rebuilt menu's selection by this action id after the round trip.
    self._rememberedActionId = result.actionId
    self._applicationId = result.applicationId
    -- Stage the child before publishing it: a failed construction enters
    -- the terminal failure state, which disposes the retained menu and
    -- releases the modal lifetime. The child is published without a first
    -- step -- menu input stopped at the launch result, so presses from the
    -- launch tick must never reach the destination.
    local ok, child = pcall(self._registry.create, self._registry, result.applicationId)
    if not ok then
      self:_fail(child)
      return
    end
    self._applicationController = child
    self._phase = FieldApplicationHost.PHASES.application
  else
    self:_disposeMenuController()
    self:_releaseUi()
    self._phase = FieldApplicationHost.PHASES.closed
  end
end

-- The application phase: the retained menu re-resolves its presentation
-- against fresh display facts with an empty event batch (it stays drawable
-- but cannot activate actions while covered), then the destination is
-- stepped once per fixed tick with the tick's events. Its close result
-- stages a fresh menu from current policy with the remembered selection
-- before either current owner is disposed, so the replacement is visible
-- that same tick and no stale menu returns as the semantic menu.
---@param uiInput table[]
function FieldApplicationHost:_stepApplication(uiInput)
  local menu = assert(self._menuController, "the application phase requires the retained menu controller")
  local controller = assert(self._applicationController, "the application phase requires the destination controller")
  menu:updateFixed({})
  controller:updateFixed(uiInput)
  local result = controller:takeResult()
  if result == nil then
    return
  end
  assert(result.kind == "close", "a destination controller only returns close")
  local remembered = self._rememberedActionId
  local ok, replacement = pcall(self._menuFactory, remembered)
  if not ok then
    self:_fail(replacement)
    return
  end
  self:_disposeApplicationController()
  self:_disposeMenuController()
  if replacement == nil then
    self:_releaseUi()
    self._applicationId = nil
    self._phase = FieldApplicationHost.PHASES.closed
    return
  end
  self._menuController = replacement
  self._applicationId = nil
  self._phase = FieldApplicationHost.PHASES.menu
end

-- The one teardown path for reset and runtime disposal: dispose each owned
-- controller exactly once, release the modal input lifetime once, clear the
-- queued script reopen, and return to closed. The helpers are idempotent, so
-- unconditional teardown is safe from any phase, including a closed phase
-- that still holds a pending reopen.
function FieldApplicationHost:dispose()
  self:_disposeMenuController()
  self:_disposeApplicationController()
  self:_releaseUi()
  self._reopenPending = false
  self._applicationId = nil
  self._failure = nil
  self._phase = FieldApplicationHost.PHASES.closed
end

return FieldApplicationHost
