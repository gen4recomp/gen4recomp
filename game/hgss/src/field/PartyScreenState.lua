-- The concrete party-screen application: the per-open wrapper binding the
-- existing view-mode controller to one presentation session. Each tick
-- resolves a complete plan against fresh display facts, maps one ordered
-- batch, advances the controller once, then resolves again for the
-- resulting snapshot without advancing semantic clocks. Geometry lives in
-- the session, never in the host. Construction is failure-safe: a failed
-- session or controller releases whatever the open acquired. Missing
-- production capabilities fail at construction, never on first draw.

local ApplicationPresentation = require("game.hgss.src.ui.ApplicationPresentation")
local PartyScreenController = require("libs.hgss.src.ui.PartyScreenController")
local PartyScreenInterface = require("game.hgss.src.field.PartyScreenInterface")
local PartyScreenModel = require("libs.hgss.src.ui.PartyScreenModel")

---@class PartyScreenState
---@field _service HgssMonService the live mon service
---@field _measureDisplay fun(): DisplayMeasurement the live display facts
---@field _controller PartyScreenController
---@field _session ApplicationPresentation the per-open presentation session
---@field _disposed boolean
local PartyScreenState = {}
PartyScreenState.__index = PartyScreenState

---@class PartyScreenState.Options
---@field service HgssMonService the live mon service
---@field measureDisplay fun(): DisplayMeasurement the current display facts
---@field overrides table<string, unknown>? per-case function overrides for this application

---@param opts PartyScreenState.Options
---@return PartyScreenState
function PartyScreenState.new(opts)
  assert(type(opts) == "table", "the party screen requires options")
  local service = assert(opts.service, "the party screen requires the live mon service")
  assert(type(opts.measureDisplay) == "function", "the party screen requires the display facts")
  assert(
    type(service.partyCount) == "function" and service:partyCount() > 0,
    "the party screen requires a non-empty party"
  )
  local self = setmetatable({
    _service = service,
    _measureDisplay = opts.measureDisplay,
    _disposed = false,
  }, PartyScreenState)
  local function refreshModel()
    return PartyScreenModel.build(service)
  end
  local function swapPartyMons(a, b)
    service:swapPartyMons(a, b)
  end
  local wrapper = self
  local function resolveLayout()
    return wrapper:resolveLayout()
  end
  local controller
  local session
  local built, buildErr = pcall(function()
    session = ApplicationPresentation.new(PartyScreenInterface.withOverrides(opts.overrides))
    controller = PartyScreenController.new({
      mode = "view",
      model = {
        refresh = refreshModel,
      },
      swap = swapPartyMons,
      resolveLayout = resolveLayout,
    })
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
  self._controller = assert(controller, "the party screen requires its view controller")
  self._session = assert(session, "the party screen requires its presentation session")
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
function PartyScreenState:_measured()
  local measurement = self._measureDisplay()
  return assert(measurement, "the party screen requires current display facts")
end

---@return table<string, unknown> the controller snapshot for resolvers and renderers
function PartyScreenState:_view()
  return self._controller:status()
end

-- The canonical logical content the controller hits against: the current
-- plan's content, never a separately computed host layout.
---@return table<string, unknown>
function PartyScreenState:resolveLayout()
  local plan = self._session:plan()
  return assert(plan.content, "the party plan carries its canonical content")
end

-- One fixed tick: resolve, map once, advance the controller once, then
-- resolve again for the resulting snapshot. pointer_cancel flows in batch
-- order; the controller absorbs it without changing selection.
---@param uiInput table[]
function PartyScreenState:updateFixed(uiInput)
  assert(not self._disposed, "a disposed party wrapper steps nothing")
  local session = self._session
  local measurement = self:_measured()
  session:resolve(measurement, self:_view())
  local mapped = session:mapInput(assert(uiInput, "the party input must be an event list"), self:_view())
  self._controller:updateFixed(mapped)
  session:resolve(measurement, self:_view())
end

-- The presentation snapshot: the controller status (semantic view state)
-- plus presentation=plan, the single host-facing layout authority. Fresh
-- tables per call.
---@return table<string, unknown>
function PartyScreenState:status()
  local status = self:_view()
  if not status.open then
    return status
  end
  status.presentation = self._session:plan()
  return status
end

-- The host result contract: view mode only ever closes back to the menu.
---@return { kind: "close" }?
function PartyScreenState:takeResult()
  local result = self._controller:takeResult()
  if result == nil then
    return nil
  end
  assert(result.kind == "closed", "the party application only returns close")
  return { kind = "close" }
end

-- Cancels a held press through both owners: the session drops its capture
-- and the controller releases its own, so a stale release never activates.
function PartyScreenState:cancelPointerCapture()
  self._session:cancelPointers()
  self._controller:cancelPointerCapture()
end

-- Idempotent release of the logical lifetime: the session and controller
-- release exactly once, a pending result is discarded and no close is
-- reported after disposal.
function PartyScreenState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._session:dispose()
  self._controller:dispose()
end

return PartyScreenState
