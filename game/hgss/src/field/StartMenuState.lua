-- The per-open Start Menu wrapper: the existing gameplay controller beside
-- one presentation session, mirroring the Bag/Party wrapper pattern. Each
-- tick resolves a complete plan against fresh display facts, maps one
-- ordered batch, advances the controller once, then resolves again for the
-- resulting snapshot without advancing semantic clocks. Geometry lives in
-- the session, never in the host. Construction is failure-safe: a failed
-- session or controller releases whatever the open acquired.

local ApplicationPresentation = require("game.hgss.src.ui.ApplicationPresentation")
local StartMenuController = require("libs.hgss.src.ui.StartMenuController")
local StartMenuInterface = require("game.hgss.src.field.StartMenuInterface")

---@class StartMenuState
---@field _controller StartMenuController the existing selection/action/result owner
---@field _session ApplicationPresentation the per-open presentation session
---@field _measureDisplay fun(): DisplayMeasurement the live display facts
---@field _disposed boolean
local StartMenuState = {}
StartMenuState.__index = StartMenuState

---@class StartMenuState.Options
---@field entries StartMenuController.Entry[] the runtime-composed final interactive action list
---@field interactive StartMenuController.Interactive the generated manifest interactive record
---@field rememberedActionId string? selection remembered across a child-application round trip
---@field effect (fun(sequence: string))? source UI sound effect boundary
---@field measureDisplay fun(): DisplayMeasurement the current display facts
---@field overrides table<string, unknown>? per-case function overrides for this application

---@param opts StartMenuState.Options
---@return StartMenuState
function StartMenuState.new(opts)
  assert(type(opts) == "table", "the start menu wrapper requires options")
  assert(type(opts.measureDisplay) == "function", "the start menu wrapper requires the display facts")
  local controller = StartMenuController.new({
    entries = assert(opts.entries, "the start menu wrapper requires its entries"),
    interactive = assert(opts.interactive, "the start menu wrapper requires the interactive record"),
    rememberedActionId = opts.rememberedActionId,
    effect = opts.effect,
  })
  local built, sessionOrError = pcall(function()
    return ApplicationPresentation.new(StartMenuInterface.withOverrides(opts.overrides))
  end)
  if not built then
    controller:dispose()
    error(sessionOrError, 0)
  end
  local ready = assert(sessionOrError, "the start menu wrapper requires its presentation session")
  local self = setmetatable({
    _controller = controller,
    _session = ready,
    _measureDisplay = opts.measureDisplay,
    _disposed = false,
  }, StartMenuState)
  local resolveOk, resolveErr = pcall(function()
    self._session:resolve(self:_measured(), self:_view())
  end)
  if not resolveOk then
    controller:dispose()
    ready:dispose()
    error(resolveErr, 0)
  end
  return self
end

---@return DisplayMeasurement
function StartMenuState:_measured()
  local measurement = self._measureDisplay()
  return assert(measurement, "the start menu wrapper requires current display facts")
end

---@return table<string, unknown> the controller snapshot for resolvers and renderers
function StartMenuState:_view()
  return self._controller:status()
end

-- One fixed tick: resolve, map once, advance the controller once, resolve
-- again for the resulting snapshot. pointer_cancel flows in batch order;
-- the controller absorbs it without changing selection.
---@param uiInput table[]
function StartMenuState:updateFixed(uiInput)
  assert(not self._disposed, "a disposed start menu wrapper steps nothing")
  local session = self._session
  local measurement = self:_measured()
  session:resolve(measurement, self:_view())
  local mapped = session:mapInput(assert(uiInput, "the start menu input must be an event list"), self:_view())
  self._controller:updateFixed(mapped)
  session:resolve(measurement, self:_view())
end

-- The presentation snapshot: the controller's semantic fields plus
-- presentation=plan, the single host-facing layout authority. Fresh tables
-- per call.
---@return table<string, unknown>
function StartMenuState:status()
  local status = self:_view()
  status.presentation = self._session:plan()
  return status
end

-- The host result contract: launch, field action, and close forward
-- unchanged from the controller.
---@return { kind: "close"|"launch"|"field_action", applicationId?: string, actionId?: string }?
function StartMenuState:takeResult()
  return self._controller:takeResult()
end

-- Cancels a held press through both owners: the session drops its capture
-- and the controller releases its own, so a stale release never activates.
function StartMenuState:cancelPointerCapture()
  self._session:cancelPointers()
  self._controller:cancelPointerCapture()
end

-- Releases the session and the controller exactly once; a pending result
-- is discarded and no close is reported after disposal.
function StartMenuState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._session:dispose()
  self._controller:dispose()
end

return StartMenuState
