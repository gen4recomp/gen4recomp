-- Modal starter-choice host for the blocking starter task. It owns the
-- pure retail controller, the validated starter-application manifest loaded
-- once per open through the generated-asset cache, the per-candidate
-- portrait descriptors resolved through the mon portrait contract, and the
-- game-local presentation that realizes that manifest across two logical
-- DS surfaces: the info surface (world role) and the machine surface
-- (auxiliary interaction role). The three pre-created candidates
-- are borrowed read-only for display; the task owns publication authority.
-- The presentation prepares its graphics resources in bounded steps once
-- the field advances it after opening, and draws only once prepared: open,
-- input, status, and close never touch graphics objects, so headless
-- compositions drive the full choice without a GPU. Presentation resources
-- release exactly once on close/dispose while the candidate records stay
-- with the task.

local ApplicationPresentation = require("game.hgss.src.ui.ApplicationPresentation")
local StarterChoiceAssetCache = require("libs.assets.src.StarterChoiceAssetCache")
local MonCache = require("libs.assets.src.MonCache")
local Personality = require("libs.mons.src.gen4.Personality")
local StarterChoiceController = require("libs.hgss.src.ui.StarterChoiceController")
local StarterChoiceInterface = require("game.hgss.src.starters.StarterChoiceInterface")
local StarterChoicePresentation = require("game.hgss.src.starters.StarterChoicePresentation")

---@class StarterChoiceState
---@field _catalog MonCatalog generated mon catalog for names
---@field _cacheFs CacheFs generated-asset filesystem for the application cache
---@field _controller StarterChoiceController? active choice controller, nil while idle
---@field _candidates table[]|nil borrowed task-owned candidate records while open
---@field _names string[]|nil candidate display names while open
---@field _portraits table[]|nil per-candidate portrait descriptors while open
---@field _manifest table<string, unknown>? immutable validated application manifest while open
---@field _presentation StarterChoicePresentation? game-local scene presentation while open
---@field _frameIndex integer player-owned text-frame choice carried into the presentation
---@field _doneIndex integer? completed candidate once the lock settles
---@field _measureDisplay fun(): DisplayMeasurement the live display facts
---@field _windowState table<string, { x: number, y: number }> borrowed caller-owned normalized window memory
---@field _overrides table<string, unknown>? per-case function overrides for this application
---@field _session ApplicationPresentation? the per-open presentation session beside the controller
local StarterChoiceState = {}
StarterChoiceState.__index = StarterChoiceState

---@class StarterChoiceState.Options
---@field catalog MonCatalog generated mon catalog for names
---@field cacheFs CacheFs generated-asset filesystem for the application cache
---@field frameIndex integer player-owned text-frame choice
---@field measureDisplay fun(): DisplayMeasurement the live display facts
---@field windowState table<string, { x: number, y: number }> borrowed caller-owned normalized window memory
---@field overrides table<string, unknown>? per-case function overrides for this application

---@param opts StarterChoiceState.Options
---@return StarterChoiceState
function StarterChoiceState.new(opts)
  assert(type(opts) == "table", "starter choice requires its composition")
  assert(opts.catalog ~= nil, "starter choice requires the mon catalog")
  assert(opts.cacheFs ~= nil, "starter choice requires the generated-asset filesystem")
  assert(
    type(opts.frameIndex) == "number" and opts.frameIndex % 1 == 0 and opts.frameIndex >= 0,
    "starter choice requires the player-owned frame index"
  )
  assert(type(opts.measureDisplay) == "function", "starter choice requires the display facts")
  assert(type(opts.windowState) == "table", "starter choice borrows its window memory")
  return setmetatable({
    _catalog = opts.catalog,
    _cacheFs = opts.cacheFs,
    _frameIndex = opts.frameIndex,
    _measureDisplay = opts.measureDisplay,
    _windowState = opts.windowState,
    _overrides = opts.overrides,
    _controller = nil,
    _candidates = nil,
    _names = nil,
    _portraits = nil,
    _manifest = nil,
    _presentation = nil,
    _session = nil,
    _doneIndex = nil,
  }, StarterChoiceState)
end

---@return boolean
function StarterChoiceState:isActive()
  return self._controller ~= nil
end

-- Whether the presentation scene is fully prepared and drawable.
-- Presentation-only: controller and script semantics never depend on it.
---@return boolean
function StarterChoiceState:isPresentationReady()
  if self._controller == nil then
    return false
  end
  local presentation = self._presentation
  if presentation == nil then
    return false
  end
  return presentation:isReady()
end

-- Advances presentation preparation by at most maxWorkUnits steps and
-- returns the steps completed. Inactive choosers prepare nothing.
-- Presentation-only: headless open and update never call this.
---@param context StarterChoicePrepContext borrowed queue and field backend
---@param maxWorkUnits integer? preparation steps allowed this update, one by default
---@return integer steps completed
function StarterChoiceState:advancePresentationPreparation(context, maxWorkUnits)
  if self._controller == nil then
    return 0
  end
  return assert(self._presentation, "no starter choice is active"):advancePreparation(context, maxWorkUnits)
end

-- Resolves one candidate portrait descriptor from the canonical mon record
-- through the existing portrait contract: personality-derived gender and
-- shininess select the front-portrait atlas entry. A source-genderless
-- species resolves to whichever male/female source variant the portrait
-- manifest actually carries. A candidate with no portrait entry fails
-- loudly; no vanilla substitute is ever shown.
---@param candidate table<string, unknown> canonical mon record
---@param entries table<string, unknown> portrait manifest entries by selector
---@param catalog MonCatalog generated mon catalog for gender ratios
---@return table<string, unknown> { speciesKey: string, form: integer, gender: string, shiny: boolean, selector: string }
local function portraitDescriptor(candidate, entries, catalog)
  assert(type(candidate) == "table", "starter candidates carry mon records")
  local speciesKey = assert(candidate.species, "starter candidate carries its species key")
  assert(type(candidate.form) == "number", "starter candidate carries its form")
  assert(type(candidate.personality) == "number", "starter candidate carries its personality")
  assert(
    type(candidate.origin) == "table" and type(candidate.origin.trainerId) == "number",
    "starter candidate carries its origin trainer identity"
  )
  local ratio = catalog:species(speciesKey).genderRatio
  local gender = Personality.gender(ratio, candidate.personality)
  local shiny = Personality.shiny(candidate.origin.trainerId, candidate.personality)
  if gender == "genderless" then
    local maleSelector = MonCache.portraitSelector(speciesKey, candidate.form, "male", shiny)
    if entries[maleSelector] ~= nil then
      gender = "male"
    else
      local femaleSelector = MonCache.portraitSelector(speciesKey, candidate.form, "female", shiny)
      assert(
        entries[femaleSelector] ~= nil,
        "starter candidate has no reachable portrait variant for " .. tostring(speciesKey)
      )
      gender = "female"
    end
  end
  local selector = MonCache.portraitSelector(speciesKey, candidate.form, gender, shiny)
  assert(entries[selector] ~= nil, "starter candidate has no portrait entry for " .. tostring(speciesKey))
  return { speciesKey = speciesKey, form = candidate.form, gender = gender, shiny = shiny, selector = selector }
end

-- Opens the modal on the task cursor with the three pre-created candidates.
-- The records are borrowed read-only for presentation; the task owns
-- publication authority. A cold or invalid application cache fails loudly
-- here through the generated-cache readiness gate; there is no fallback
-- presentation.
---@param cursor integer zero-based opening candidate
---@param candidates table[] three complete semantic mon records
function StarterChoiceState:open(cursor, candidates)
  assert(not self:isActive(), "a starter choice is already active")
  assert(
    type(cursor) == "number" and cursor % 1 == 0 and cursor >= 0 and cursor <= 2,
    "starter open requires a candidate cursor"
  )
  assert(type(candidates) == "table" and #candidates == 3, "starter open requires three candidates")
  local names = {}
  for index, candidate in ipairs(candidates) do
    assert(type(candidate) == "table" and type(candidate.species) == "string", "starter candidates carry species keys")
    local definition = self._catalog:species(candidate.species)
    names[index] = definition.name
  end
  local cacheFs = assert(self._cacheFs, "starter choice requires the generated-asset filesystem")
  local marker = cacheFs:read(StarterChoiceAssetCache.markerPath())
  assert(marker ~= nil, "starter application cache is cold -- run `scripts/buildcache.sh` first")
  assert(
    StarterChoiceAssetCache.isReady(cacheFs, marker),
    "starter application cache is incomplete -- run `scripts/buildcache.sh` first"
  )
  local manifest =
    assert(cacheFs:loadLua(StarterChoiceAssetCache.manifestPath()), "starter application cache carries no manifest")
  assert(StarterChoiceAssetCache.validateManifest(manifest), "starter application manifest is invalid")
  local portraits = assert(
    cacheFs:loadLua(MonCache.portraitManifestPath()),
    "starter choice requires the generated mon portrait manifest"
  )
  local entries = assert(portraits.entries, "the mon portrait manifest carries its entries")
  local descriptors = {}
  for index, candidate in ipairs(candidates) do
    descriptors[index] = portraitDescriptor(candidate, entries, self._catalog)
  end
  self._candidates = candidates
  self._names = names
  self._portraits = descriptors
  self._manifest = manifest
  self._doneIndex = nil
  self._controller = StarterChoiceController.new({
    candidates = names,
    initialCursor = cursor,
  })
  local presentation = StarterChoicePresentation.new({
    manifest = manifest,
    cacheFs = cacheFs,
    portraits = descriptors,
    frameIndex = self._frameIndex,
  })
  presentation:reset()
  self._presentation = presentation
  local session = ApplicationPresentation.new(StarterChoiceInterface.withOverrides(self._overrides), self._windowState)
  self._session = session
  local resolveOk, resolveErr = pcall(function()
    session:resolve(self:_measured(), self:_sessionView())
  end)
  if not resolveOk then
    session:dispose()
    self._session = nil
    self:_releasePresentation()
    self._controller = nil
    self._candidates = nil
    self._names = nil
    self._portraits = nil
    self._manifest = nil
    error(resolveErr, 0)
  end
end

function StarterChoiceState:close()
  assert(self:isActive(), "no starter choice is active")
  self:_disposeSession()
  self:_releasePresentation()
  self._controller = nil
  self._candidates = nil
  self._names = nil
  self._portraits = nil
  self._manifest = nil
  self._doneIndex = nil
end

-- One deterministic application tick: the presentation advances one source
-- tick for the controller's current snapshot and reports its completion
-- observation, then the controller consumes that observation once. The field
-- runtime steps this once per fixed tick while the modal is open; ignored
-- transitions stay settled without input. An all-false observation never
-- completes a transition, so a missing presentation stalls rather than
-- settling.
---@type StarterChoiceController.Observation
local EMPTY_OBSERVATION = {
  rotationComplete = false,
  cameraComplete = false,
  ballArcComplete = false,
  smallWobbleReady = false,
  infoFadeComplete = false,
  machineFadeComplete = false,
}

function StarterChoiceState:update()
  local controller = self._controller
  if controller == nil then
    return
  end
  local snapshot = controller:snapshot()
  local observation = self._presentation and self._presentation:update(snapshot) or EMPTY_OBSERVATION
  controller:update(observation)
  assert(self._session, "an open choice owns its presentation session"):resolve(self:_measured(), self:_sessionView())
end

---@param self StarterChoiceState
---@return StarterChoiceController active controller
local function activeController(self)
  local controller = self._controller
  assert(controller ~= nil, "no starter choice is active")
  return controller
end

---@param self StarterChoiceState
---@return StarterChoicePresentation active presentation
local function activePresentation(self)
  local presentation = self._presentation
  assert(presentation ~= nil, "no starter choice is active")
  return presentation
end

---@return DisplayMeasurement the current display facts for plan resolution
function StarterChoiceState:_measured()
  local measurement = self._measureDisplay()
  return assert(measurement, "starter choice requires current display facts")
end

-- The session view: the flat controller snapshot fields plus the
-- semantic candidates and names for renderers and the state-owned scene
-- presentation for source-space hit mapping. The snapshot shape matches
-- what resolvers and mappers read directly. Fresh tables per call.
---@return table<string, unknown>
---@class StarterChoiceSessionView : StarterChoiceController.Snapshot
---@field candidates table<string, unknown>[] borrowed task-owned candidate records for renderers
---@field names string[] candidate display names for renderers
---@field presentation table<string, unknown> state-owned scene presentation for source-space hit mapping

---@return StarterChoiceSessionView
function StarterChoiceState:_sessionView()
  local controller = activeController(self)
  local snapshot = controller:snapshot()
  ---@type StarterChoiceSessionView
  local view = {
    selection = snapshot.selection,
    selectionState = snapshot.selectionState,
    transition = snapshot.transition,
    direction = snapshot.direction,
    done = snapshot.done,
    result = snapshot.result,
    candidates = assert(self._candidates, "starter choice requires its candidates"),
    names = assert(self._names, "starter choice requires its candidate names"),
    presentation = activePresentation(self),
  }
  return view
end

---@return { done: boolean, cursor: integer?, index: integer?, presentation: table<string, unknown> }|nil
function StarterChoiceState:status()
  local controller = self._controller
  if controller == nil then
    return nil
  end
  local session = assert(self._session, "an open choice owns its presentation session")
  local snapshot = controller:snapshot()
  if snapshot.done then
    local index = snapshot.result ~= nil and snapshot.result.index or nil
    self._doneIndex = assert(index, "a completed choice names its candidate")
    return { done = true, index = self._doneIndex, presentation = session:plan() }
  end
  return { done = false, cursor = snapshot.selection, presentation = session:plan() }
end

-- One input batch through the published plan: resolve against fresh host
-- facts, map once through the session, then dispatch the resulting app
-- events to the unchanged controller. pointer_cancel carries no
-- semantic cancel meaning and is discarded after gesture invalidation.
-- The plan is resolved again for the resulting snapshot so status and draw publish the post-input interface.
---@param events table<string, unknown>[] the normalized UI event batch
function StarterChoiceState:handleInput(events)
  local controller = activeController(self)
  assert(type(events) == "table", "starter input requires the event batch")
  local session = assert(self._session, "an open choice owns its presentation session")
  session:resolve(self:_measured(), self:_sessionView())
  local mapped = session:mapInput(events, self:_sessionView())
  for _, event in ipairs(mapped) do
    local eventType = event.type
    if eventType == "tap" then
      controller:tap(event.index)
    elseif eventType == "confirm" then
      controller:confirm()
    elseif eventType == "cancel" then
      controller:cancel()
    elseif eventType == "navigate" then
      if event.direction == "left" or event.direction == "right" then
        controller:move(event.direction)
      end
    elseif eventType == "pointer_cancel" then
      -- A cancelled gesture invalidates the press without touching choice semantics.
    else
      assert(false, "unknown starter choice app event " .. tostring(eventType))
    end
  end
  session:resolve(self:_measured(), self:_sessionView())
end

-- Cancels a held presentation press without touching choice semantics:
-- the session drops its capture so a stale release never activates.
function StarterChoiceState:cancelPointerCapture()
  local session = self._session
  if session ~= nil then
    session:cancelPointers()
  end
end

---@param itemIndex integer
function StarterChoiceState:focus(itemIndex)
  activeController(self):focus(itemIndex)
end

---@param direction "left"|"right"
function StarterChoiceState:move(direction)
  activeController(self):move(direction)
end

---@return nil
function StarterChoiceState:confirm()
  return activeController(self):confirm()
end

---@return nil
function StarterChoiceState:cancel()
  return activeController(self):cancel()
end

---@param itemIndex integer?
---@return nil
function StarterChoiceState:tap(itemIndex)
  return activeController(self):tap(itemIndex)
end

---@param x number DS reference-space pointer x
---@param y number DS reference-space pointer y
---@param snapshot StarterChoiceController.Snapshot? controller snapshot the hit resolves under
---@return integer? 1|2|3, nil outside every ball
function StarterChoiceState:ballAt(x, y, snapshot)
  local presentation = self._presentation
  if presentation == nil then
    return nil
  end
  if type(snapshot) ~= "table" or type(snapshot.selectionState) ~= "string" then
    snapshot = activeController(self):snapshot()
  end
  return presentation:ballAt(x, y, snapshot)
end

function StarterChoiceState:_releasePresentation()
  local presentation = self._presentation
  self._presentation = nil
  if presentation ~= nil then
    presentation:dispose()
  end
end

function StarterChoiceState:_disposeSession()
  local session = self._session
  self._session = nil
  if session ~= nil then
    session:dispose()
  end
end

-- Draws the modal through the field text provider. Reconciles the
-- presentation geometry through the state-owned session, then executes
-- the resolved plan with the borrowed presentation and text. Drawing
-- before preparation completes is a composition error and fails loudly;
-- the field draws the starter surface only once ready. Repeated draws
-- never advance semantic clocks.
---@param text table<string, unknown> text provider ({ drawLine, windowBackgroundColor })
function StarterChoiceState:drawPresentation(text)
  activeController(self)
  assert(text ~= nil and type(text.drawLine) == "function", "starter presentation requires the text provider")
  assert(self:isPresentationReady(), "starter presentation is not prepared")
  local session = assert(self._session, "an open choice owns its presentation session")
  local view = self:_sessionView()
  session:resolve(self:_measured(), view)
  local graphics = assert(love and love.graphics, "starter presentation requires the graphics namespace")
  ApplicationPresentation.draw(graphics, {
    graphics = graphics,
    presentation = activePresentation(self),
    text = text,
  }, view, session:plan())
end

function StarterChoiceState:dispose()
  self:_disposeSession()
  self:_releasePresentation()
  self._controller = nil
  self._candidates = nil
  self._names = nil
  self._portraits = nil
  self._manifest = nil
  self._doneIndex = nil
end

return StarterChoiceState
