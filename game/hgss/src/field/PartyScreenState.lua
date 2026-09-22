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
local PartyScreenLayout = require("libs.hgss.src.ui.PartyScreenLayout")
local PartyScreenModel = require("libs.hgss.src.ui.PartyScreenModel")

---@class PartyScreenState
---@field _service HgssMonService the live mon service
---@field _measureDisplay fun(): DisplayMeasurement the live display facts
---@field _prepareIcons fun(iconKeys: string[]): boolean, string?
---@field _cancelIconPreparation fun()
---@field _preparationState "pending"|"ready"|"failed"
---@field _preparationError string?
---@field _preparedKeys string?
---@field _preparationReleased boolean
---@field _controller PartyScreenController
---@field _session ApplicationPresentation the per-open presentation session
---@field _disposed boolean
local PartyScreenState = {}
PartyScreenState.__index = PartyScreenState

---@class PartyScreenState.Options
---@field service HgssMonService the live mon service
---@field measureDisplay fun(): DisplayMeasurement the current display facts
---@field overrides table<string, unknown>? per-case function overrides for this application
---@field prepareIcons fun(iconKeys: string[]): boolean, string? required icon preparation collaborator
---@field cancelIconPreparation fun() required preparation release collaborator

---@param opts PartyScreenState.Options
---@return PartyScreenState
function PartyScreenState.new(opts)
  assert(type(opts) == "table", "the party screen requires options")
  local service = assert(opts.service, "the party screen requires the live mon service")
  assert(type(opts.measureDisplay) == "function", "the party screen requires the display facts")
  assert(type(opts.prepareIcons) == "function", "the party screen requires its icon preparation")
  assert(type(opts.cancelIconPreparation) == "function", "the party screen requires its preparation release")
  assert(
    type(service.partyCount) == "function" and service:partyCount() > 0,
    "the party screen requires a non-empty party"
  )
  local self = setmetatable({
    _service = service,
    _measureDisplay = opts.measureDisplay,
    _prepareIcons = opts.prepareIcons,
    _cancelIconPreparation = opts.cancelIconPreparation,
    _preparationState = "pending",
    _preparationError = nil,
    _preparedKeys = nil,
    _preparationReleased = false,
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

-- The icon keys behind the current view: occupied slots only, in slot
-- order. Read-only: preparation advances on update, never on status/draw.
---@return string[] keys
---@return string joined
function PartyScreenState:_currentIconKeys()
  local service = assert(self._service, "the party screen keeps its mon service")
  local model = PartyScreenModel.build(service)
  local keys = {}
  for _, slot in ipairs(model.slots) do
    if slot.occupied and type(slot.iconKey) == "string" then
      keys[#keys + 1] = slot.iconKey
    end
  end
  return keys, table.concat(keys, "\0")
end

-- The resolved layout for the preparation wait screen, measured against
-- the current display facts. Ready draws resolve through the session
-- plan instead; this layout only places the wait/failure copy.
---@return PartyScreenLayoutResolved
function PartyScreenState:_layout()
  local measurement = self:_measured()
  return PartyScreenLayout.resolve({
    width = measurement.width,
    height = measurement.height,
    cancellable = self._controller:cancellable(),
  })
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
  local keys, joined = self:_currentIconKeys()
  if self._preparedKeys ~= joined then
    self._preparedKeys = joined
    self._preparationState = "pending"
    self._preparationError = nil
  end
  if self._preparationState == "pending" then
    local ready, failure = self._prepareIcons(keys)
    if failure ~= nil then
      self._preparationState = "failed"
      self._preparationError = tostring(failure)
    elseif ready then
      self._preparationState = "ready"
      self._preparationError = nil
    end
  end
  if self._preparationState ~= "ready" then
    -- While waiting the screen stays cancellable but discards every other
    -- activation: held input must never replay once readiness arrives.
    local cancellations = {}
    for _, event in ipairs(assert(uiInput, "the party input must be an event list")) do
      assert(type(event) == "table" and type(event.type) == "string", "party events need a type")
      if event.type == "cancel" then
        cancellations[#cancellations + 1] = event
      end
    end
    if #cancellations > 0 then
      self._controller:updateFixed(cancellations)
    end
    return
  end
  local session = self._session
  local measurement = self:_measured()
  session:resolve(measurement, self:_view())
  local mapped = session:mapInput(assert(uiInput, "the party input must be an event list"), self:_view())
  self._controller:updateFixed(mapped)
  session:resolve(measurement, self:_view())
end

-- The presentation snapshot: the preparation wait while icons are not
-- ready, the controller status plus presentation=plan and readiness once
-- they are. Read-only: status never advances preparation. Fresh tables
-- per call.
---@return table<string, unknown>
function PartyScreenState:status()
  if self._preparationState ~= "ready" then
    return {
      open = true,
      preparationState = self._preparationState,
      preparationError = self._preparationError,
      layout = self:_layout(),
    }
  end
  local status = self:_view()
  if not status.open then
    return status
  end
  status.presentation = self._session:plan()
  status.preparationState = "ready"
  return status
end

-- The host result contract: view mode only ever closes back to the menu.
-- Closing releases the preparation interest exactly once.
---@return { kind: "close" }?
function PartyScreenState:takeResult()
  local result = self._controller:takeResult()
  if result == nil then
    return nil
  end
  assert(result.kind == "closed", "the party application only returns close")
  self:_releasePreparation()
  return { kind = "close" }
end

-- Cancels a held press through both owners: the session drops its capture
-- and the controller releases its own, so a stale release never activates.
function PartyScreenState:cancelPointerCapture()
  self._session:cancelPointers()
  self._controller:cancelPointerCapture()
end

-- Releases the preparation interest exactly once across close and
-- disposal: a late readiness arrival cannot reopen or draw the screen.
function PartyScreenState:_releasePreparation()
  if not self._preparationReleased then
    self._preparationReleased = true
    self._cancelIconPreparation()
  end
end

-- Idempotent release of the logical lifetime: the session and controller
-- release exactly once, a pending result is discarded and no close is
-- reported after disposal.
function PartyScreenState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self:_releasePreparation()
  self._session:dispose()
  self._controller:dispose()
end

return PartyScreenState
