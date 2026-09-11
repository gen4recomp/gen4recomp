-- The concrete field-bag application: the per-launch state the field
-- application host steps while the bag owns the tick. It binds the pure
-- browse controller to the live inventory service and runtime cursor,
-- resolves layout from the live viewport and topology every tick so
-- resizes never lose semantic state, advances the hero animation on the
-- fixed cadence, and returns the single close result the host expects. A
-- press held across a viewport or topology change must not activate a
-- different post-change target, so structural geometry changes cancel the
-- pointer capture first. Missing production capabilities fail at
-- construction, never on first draw.

local BagActionPolicy = require("libs.hgss.src.ui.BagActionPolicy")
local BagController = require("libs.hgss.src.ui.BagController")
local BagHeroPresenter = require("libs.hgss.src.presentation.BagHeroPresenter")
local BagLayout = require("libs.hgss.src.ui.BagLayout")
local BagModel = require("libs.hgss.src.ui.BagModel")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

---@class BagScreenState
---@field _service HgssBagService
---@field _cursor BagCursor
---@field _manifest table<string, unknown>
---@field _heroGender "male"|"female"
---@field _measureViewport fun(): number, number
---@field _measureTopology fun(): { topology: ScreenTopology?, referenceFrame: ScreenTopology.Rectangle? }
---@field _controller BagController
---@field _hero BagHeroPresenter
---@field _heroPocket string?
---@field _tickLayout BagLayoutResolved? the single resolved placement shared by one fixed tick
---@field _lastMapping string? the structural host-to-canonical mapping observed on the previous tick
local BagScreenState = {}
BagScreenState.__index = BagScreenState

---@class BagScreenState.Options
---@field service HgssBagService the live bag service
---@field cursor BagCursor the borrowed runtime-only field cursor
---@field manifest table<string, unknown> the validated bag presentation manifest
---@field heroGender "male"|"female" the profile-selected hero backdrop
---@field measureViewport fun(): number, number the live viewport dimensions
---@field measureTopology fun(): { topology: ScreenTopology?, referenceFrame: ScreenTopology.Rectangle? } the live topology

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
  local heroGender = assert(opts.heroGender, "the bag screen requires the hero gender")
  assert(heroGender == "male" or heroGender == "female", "the hero gender selects its backdrop")
  assert(type(opts.measureViewport) == "function", "the bag screen requires the viewport dimensions")
  assert(type(opts.measureTopology) == "function", "the bag screen requires the screen topology")
  local self = setmetatable({
    _service = service,
    _cursor = cursor,
    _manifest = manifest,
    _heroGender = heroGender,
    _measureViewport = opts.measureViewport,
    _measureTopology = opts.measureTopology,
    _heroPocket = nil,
    _tickLayout = nil,
    _lastMapping = nil,
  }, BagScreenState)
  self._hero = BagHeroPresenter.new({ manifest = manifest })
  local function refreshModel()
    return BagModel.build(service, cursor)
  end
  local function resolveLayout()
    return self:_layout()
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
  self._controller = BagController.new({
    model = { refresh = refreshModel },
    cursor = cursor,
    resolveLayout = resolveLayout,
    commands = {
      toss = tossItem,
      move = moveItem,
      register = registerItem,
      unregister = unregisterItem,
    },
    resolveActions = BagActionPolicy.forService(service),
  })
  return self
end

---@param width number
---@param height number
---@return ScreenTopology
---@return ScreenTopology.Rectangle?
function BagScreenState:_measure(width, height)
  local measured = self._measureTopology()
  assert(type(measured) == "table", "the topology measurement returns a record")
  local topology = measured.topology
  if topology == nil then
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = width, height = height },
      touch = false,
      role = "world",
    })
  end
  return topology, measured.referenceFrame
end

-- The structural host-to-canonical mapping one fixed tick observes: viewport
-- dimensions plus the resolved placement geometry rendering and hit testing
-- share. Fresh equivalent topology tables serialize identically, so only a
-- real mapping change invalidates a held press.
---@param width number
---@param height number
---@param layout BagLayoutResolved
---@return string
local function mappingSignature(width, height, layout)
  local interactive = assert(layout.interactive, "the bag layout places its interactive pane")
  local frame = assert(interactive.frame, "the interactive placement carries its frame")
  ---@type (number|string)[]
  local parts = {
    width,
    height,
    layout.mode,
    frame.x,
    frame.y,
    frame.width,
    frame.height,
    interactive.scale,
    interactive.logicalWidth,
    interactive.logicalHeight,
    interactive.surfaceId,
  }
  local hero = layout.hero
  if hero == nil then
    parts[#parts + 1] = "no-hero"
  else
    local heroFrame = assert(hero.frame, "the hero placement carries its frame")
    parts[#parts + 1] = heroFrame.x
    parts[#parts + 1] = heroFrame.y
    parts[#parts + 1] = heroFrame.width
    parts[#parts + 1] = heroFrame.height
    parts[#parts + 1] = hero.scale
    parts[#parts + 1] = hero.surfaceId
  end
  local fallback = layout.descriptionFallback
  if fallback == nil then
    parts[#parts + 1] = "no-fallback"
  else
    parts[#parts + 1] = fallback.x
    parts[#parts + 1] = fallback.y
    parts[#parts + 1] = fallback.width
    parts[#parts + 1] = fallback.height
  end
  return table.concat(parts, "|")
end

---@return BagLayoutResolved
function BagScreenState:_layout()
  local cached = self._tickLayout
  if cached ~= nil then
    return cached
  end
  local width, height = self._measureViewport()
  local topology, referenceFrame = self:_measure(width, height)
  return BagLayout.resolve({ topology = topology, referenceFrame = referenceFrame, manifest = self._manifest })
end

-- One fixed tick with the tick's UI events in host coordinates, the same
-- coordinate space the layout resolves in. A press held across a real
-- mapping change must not activate a different post-change target, so only
-- a structural placement change cancels the pointer capture first.
---@param uiInput table[]
function BagScreenState:updateFixed(uiInput)
  self._tickLayout = nil
  local width, height = self._measureViewport()
  local topology, referenceFrame = self:_measure(width, height)
  local layout = BagLayout.resolve({ topology = topology, referenceFrame = referenceFrame, manifest = self._manifest })
  self._tickLayout = layout
  local mapping = mappingSignature(width, height, layout)
  if self._lastMapping ~= nil and mapping ~= self._lastMapping then
    self._controller:cancelPointerCapture()
  end
  self._lastMapping = mapping
  self._controller:updateFixed(uiInput)
  local status = self._controller:status()
  if status.open then
    if status.pocket ~= self._heroPocket then
      self._hero:selectPocket(status.pocket)
      self._heroPocket = status.pocket
    end
    self._hero:updateFixed()
  end
end

-- The presentation snapshot: the controller status (semantic browse state
-- plus the current resolved layout for hit testing and rendering) with the
-- hero presentation facts. Fresh tables per call.
---@return table<string, unknown>
function BagScreenState:status()
  local status = self._controller:status()
  if not status.open then
    return status
  end
  status.heroGender = self._heroGender
  status.hero = self._hero:status()
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

-- Idempotent release of the logical lifetime: a pending result is
-- discarded and no close is reported after disposal.
function BagScreenState:dispose()
  self._controller:dispose()
end

return BagScreenState
