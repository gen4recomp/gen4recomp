-- The concrete trainer card application: the per-open wrapper binding the
-- existing close-only controller to one presentation session. Each tick
-- resolves a complete plan against fresh display facts, maps one ordered
-- batch, advances the controller once, then resolves again for the
-- resulting snapshot without advancing semantic clocks. Geometry lives in
-- the session, never in the host. Construction is failure-safe: a failed
-- session or controller releases whatever the open acquired. Missing
-- production capabilities fail at construction, never on first draw. The
-- close-only controller holds no pointer press, so capture cancellation is
-- session-owned; the controller keeps its current input contract unchanged.

local ApplicationPresentation = require("game.hgss.src.ui.ApplicationPresentation")
local TrainerCardController = require("libs.hgss.src.ui.TrainerCardController")
local TrainerCardInterface = require("game.hgss.src.field.TrainerCardInterface")

---@class TrainerCardScreenState
---@field _measureDisplay fun(): DisplayMeasurement the live display facts
---@field _controller TrainerCardController
---@field _session ApplicationPresentation the per-open presentation session
---@field _disposed boolean
local TrainerCardScreenState = {}
TrainerCardScreenState.__index = TrainerCardScreenState

---@class TrainerCardScreenState.Options
---@field profile TrainerCardController.Profile the authoritative player profile fields
---@field playTimeSeconds number the current play time
---@field effect fun(sequence: string)? source UI sound effect boundary
---@field measureDisplay fun(): DisplayMeasurement the current display facts
---@field overrides table<string, unknown>? per-case function overrides for this application

---@param opts TrainerCardScreenState.Options
---@return TrainerCardScreenState
function TrainerCardScreenState.new(opts)
  assert(type(opts) == "table", "the trainer card requires options")
  assert(type(opts.profile) == "table", "the trainer card requires the player profile")
  assert(type(opts.measureDisplay) == "function", "the trainer card requires the display facts")
  local self = setmetatable({
    _measureDisplay = opts.measureDisplay,
    _disposed = false,
  }, TrainerCardScreenState)
  local controller
  local session
  local built, buildErr = pcall(function()
    controller = TrainerCardController.new({
      profile = opts.profile,
      playTimeSeconds = opts.playTimeSeconds,
      effect = opts.effect,
    })
    session = ApplicationPresentation.new(TrainerCardInterface.withOverrides(opts.overrides))
  end)
  if not built then
    if session ~= nil then
      session:dispose()
    end
    if controller ~= nil then
      controller:dispose()
    end
    error(buildErr, 0)
  end
  self._controller = assert(controller, "the trainer card requires its close controller")
  self._session = assert(session, "the trainer card requires its presentation session")
  local resolveOk, resolveErr = pcall(function()
    self._session:resolve(self:_measured(), self:_view())
  end)
  if not resolveOk then
    self._controller:dispose()
    self._session:dispose()
    error(resolveErr, 0)
  end
  return self
end

---@return DisplayMeasurement
function TrainerCardScreenState:_measured()
  local measurement = self._measureDisplay()
  return assert(measurement, "the trainer card requires current display facts")
end

---@return table<string, unknown> the controller snapshot for resolvers and renderers
function TrainerCardScreenState:_view()
  return self._controller:status()
end

-- One fixed tick: resolve, map once, advance the controller once, then
-- resolve again for the resulting snapshot. Pointer content never reaches
-- the close-only controller as an action; pointer_cancel is discarded by
-- the interface mapper after invalidating the session gesture.
---@param uiInput table[]
function TrainerCardScreenState:updateFixed(uiInput)
  assert(not self._disposed, "a disposed card wrapper steps nothing")
  local session = self._session
  local measurement = self:_measured()
  session:resolve(measurement, self:_view())
  local mapped = session:mapInput(assert(uiInput, "the card input must be an event list"), self:_view())
  self._controller:updateFixed(mapped)
  session:resolve(measurement, self:_view())
end

-- The presentation snapshot: the controller status (copied profile fields)
-- plus presentation=plan, the single host-facing layout authority. Fresh
-- tables per call.
---@return table<string, unknown>
function TrainerCardScreenState:status()
  local status = self:_view()
  if not status.open then
    return status
  end
  status.presentation = self._session:plan()
  return status
end

-- The host result contract: the card only ever closes back to the menu.
---@return { kind: "close" }?
function TrainerCardScreenState:takeResult()
  local result = self._controller:takeResult()
  if result == nil then
    return nil
  end
  assert(result.kind == "close", "the card application only returns close")
  return result
end

-- Drops the session capture so a stale release never activates. The
-- close-only controller holds no press and keeps no capture capability;
-- keyboard-only destinations stay valid without it.
function TrainerCardScreenState:cancelPointerCapture()
  self._session:cancelPointers()
end

-- Idempotent release of the logical lifetime: the session and controller
-- release exactly once, a pending result is discarded and no close is
-- reported after disposal.
function TrainerCardScreenState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._session:dispose()
  self._controller:dispose()
end

return TrainerCardScreenState
