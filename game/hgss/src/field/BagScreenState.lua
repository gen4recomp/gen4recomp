-- The concrete field-bag application: the per-open wrapper binding the
-- existing browse controller and hero presenter to one presentation
-- session. Each tick resolves a complete plan against fresh display
-- facts, maps one ordered batch, advances the controller once, then
-- resolves again for the resulting snapshot without advancing semantic
-- clocks. Geometry lives in the session, never in the host. Construction
-- is failure-safe: a failed session or controller releases whatever the
-- open acquired. Missing production capabilities fail at construction,
-- never on first draw.

local ApplicationPresentation = require("game.hgss.src.ui.ApplicationPresentation")
local BagActionPolicy = require("libs.hgss.src.ui.BagActionPolicy")
local BagController = require("libs.hgss.src.ui.BagController")
local BagHeroPresenter = require("libs.hgss.src.presentation.BagHeroPresenter")
local BagInterface = require("game.hgss.src.field.BagInterface")
local BagModel = require("libs.hgss.src.ui.BagModel")

---@class BagScreenState
---@field _service HgssBagService
---@field _cursor BagCursor
---@field _manifest table<string, unknown>
---@field _heroGender "male"|"female"
---@field _measureDisplay fun(): DisplayMeasurement the live display facts
---@field _controller BagController
---@field _session ApplicationPresentation the per-open presentation session
---@field _hero BagHeroPresenter
---@field _heroPocket string?
---@field _disposed boolean
local BagScreenState = {}
BagScreenState.__index = BagScreenState

---@class BagScreenState.Options
---@field service HgssBagService the live bag service
---@field cursor BagCursor the borrowed runtime-only field cursor
---@field manifest table<string, unknown> the validated bag presentation manifest
---@field uiManifest table<string, unknown> the validated field-UI manifest carrying the prompt section
---@field monCatalog table<string, unknown> the borrowed compiled mon catalog
---@field heroGender "male"|"female" the profile-selected hero backdrop
---@field measureDisplay fun(): DisplayMeasurement the current display facts
---@field overrides table<string, unknown>? per-case function overrides for this application

---@param opts BagScreenState.Options
---@return BagScreenState
function BagScreenState.new(opts)
  assert(type(opts) == "table", "the bag screen requires options")
  local service = assert(opts.service, "the bag screen requires the live bag service")
  assert(type(service.pocketItems) == "function", "the bag screen requires pocket reads")
  assert(type(service.catalog) == "function", "the bag screen requires the item catalog")
  assert(type(service.registeredItems) == "function", "the bag screen requires registration reads")
  assert(type(service.revision) == "function", "the bag screen requires the service revision")
  local cursor = assert(opts.cursor, "the bag screen requires the runtime bag cursor")
  assert(type(cursor.currentPocket) == "function", "the bag screen requires the cursor pocket")
  assert(type(cursor.setPocket) == "function", "the bag screen requires pocket switching")
  local manifest = assert(opts.manifest, "the bag screen requires the bag presentation manifest")
  -- The modal toss confirmation binds the generated prompt shape with the
  -- bag's semantic placement; either missing definition fails the open
  -- instead of falling back to action slots.
  local uiManifest = assert(opts.uiManifest, "the bag screen requires the field-UI manifest")
  local promptSection = assert(uiManifest.yesNoPrompt, "the field-UI manifest carries the prompt section")
  assert(type(promptSection) == "table", "the field-UI manifest carries the prompt section")
  local promptShapes = assert(promptSection.shapes, "the prompt section carries its shape map")
  local promptShape = assert(promptShapes.compact, "the field-UI manifest carries the compact prompt shape")
  local overlays = assert(manifest.interactive, "the bag manifest carries its interactive pane")
  assert(type(overlays) == "table", "the bag manifest carries its interactive pane")
  local bagOverlays = assert(overlays.overlays, "the bag manifest carries its overlay geometry")
  local tossPrompt = assert(bagOverlays.tossPrompt, "the bag manifest carries its toss prompt placement")
  local monCatalog = assert(opts.monCatalog, "the bag screen requires the mon catalog")
  assert(
    type(monCatalog) == "table" and type(monCatalog.moveByNativeId) == "function",
    "the bag screen requires move lookup"
  )
  local heroGender = assert(opts.heroGender, "the bag screen requires the hero gender")
  assert(heroGender == "male" or heroGender == "female", "the hero gender selects its backdrop")
  assert(type(opts.measureDisplay) == "function", "the bag screen requires the display facts")
  local self = setmetatable({
    _service = service,
    _cursor = cursor,
    _manifest = manifest,
    _heroGender = heroGender,
    _measureDisplay = opts.measureDisplay,
    _heroPocket = nil,
    _disposed = false,
  }, BagScreenState)
  self._hero = BagHeroPresenter.new({ manifest = manifest, gender = heroGender })
  local function refreshModel()
    return BagModel.build(service, cursor, monCatalog)
  end
  local wrapper = self
  local function resolveLayout()
    return wrapper:resolveLayout()
  end
  -- The controller stays pure: every inventory mutation rides the injected
  -- semantic commands straight into the one live service, and the action
  -- menu rides the pure policy projection bound to that same service.
  -- Persistence stays with the normal save capture; nothing writes here.
  local function tossItem(itemKey, quantity)
    return service:take(itemKey, quantity)
  end
  local function moveItem(pocketKey, fromIndex, toIndex)
    return service:move(pocketKey, fromIndex, toIndex)
  end
  local function registerItem(itemKey)
    return service:tryRegister(itemKey)
  end
  local function unregisterItem(itemKey)
    return service:unregister(itemKey)
  end
  local controller
  local session
  local built, buildErr = pcall(function()
    session = ApplicationPresentation.new(BagInterface.withOverrides(opts.overrides, manifest))
    controller = BagController.new({
      model = { refresh = refreshModel },
      cursor = cursor,
      resolveLayout = resolveLayout,
      promptShape = promptShape,
      tossPrompt = tossPrompt,
      commands = {
        toss = tossItem,
        move = moveItem,
        register = registerItem,
        unregister = unregisterItem,
      },
      resolveActions = BagActionPolicy.forService(service),
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
  self._controller = assert(controller, "the bag screen requires its browse controller")
  self._session = assert(session, "the bag screen requires its presentation session")
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
function BagScreenState:_measured()
  local measurement = self._measureDisplay()
  return assert(measurement, "the bag screen requires current display facts")
end

---@return table<string, unknown> the controller snapshot for resolvers and renderers
function BagScreenState:_view()
  return self._controller:status()
end

-- The canonical logical content the controller hits against: the current
-- plan's content, never a separately computed host layout.
---@return table<string, unknown>
function BagScreenState:resolveLayout()
  local plan = self._session:plan()
  return assert(plan.content, "the bag plan carries its canonical content")
end

-- One fixed tick: resolve, map once, advance the controller once, sync
-- the hero presenter, then resolve again for the resulting snapshot.
-- pointer_cancel flows in batch order; the controller absorbs it without
-- changing selection.
---@param uiInput table[]
function BagScreenState:updateFixed(uiInput)
  assert(not self._disposed, "a disposed bag wrapper steps nothing")
  local session = self._session
  local measurement = self:_measured()
  session:resolve(measurement, self:_view())
  local mapped = session:mapInput(assert(uiInput, "the bag input must be an event list"), self:_view())
  self._controller:updateFixed(mapped)
  local status = self._controller:status()
  if status.open then
    if status.pocket ~= self._heroPocket then
      self._hero:selectPocket(status.pocket)
      self._heroPocket = status.pocket
    end
    self._hero:updateFixed()
  end
  session:resolve(measurement, self:_view())
end

-- The presentation snapshot: the controller status (semantic browse state)
-- with the hero presentation facts plus presentation=plan, the single
-- host-facing layout authority. Fresh tables per call.
---@return table<string, unknown>
function BagScreenState:status()
  local status = self:_view()
  if not status.open then
    return status
  end
  status.heroGender = self._heroGender
  status.hero = self._hero:status()
  status.presentation = self._session:plan()
  return status
end

-- The host result contract: the bag only ever closes back to the menu.
---@return { kind: "close" }?
function BagScreenState:takeResult()
  local result = self._controller:takeResult()
  if result == nil then
    return nil
  end
  assert(result.kind == "closed", "the bag application only returns close")
  return { kind = "close" }
end

-- Cancels a held press through both owners: the session drops its capture
-- and the controller releases its own, so a stale release never activates.
function BagScreenState:cancelPointerCapture()
  self._session:cancelPointers()
  self._controller:cancelPointerCapture()
end

-- Idempotent release of the logical lifetime: the session and controller
-- release exactly once, a pending result is discarded and no close is
-- reported after disposal.
function BagScreenState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._session:dispose()
  self._controller:dispose()
end

return BagScreenState
