-- Modal starter-choice host for the blocking starter task. It owns the
-- pure retail controller, the validated starter-application manifest loaded
-- once per open through the generated-asset cache, the per-candidate
-- portrait descriptors resolved through the mon portrait contract, and the
-- game-local presentation that realizes that manifest across two logical
-- DS surfaces: the machine surface (world role, the only touch surface)
-- and the info surface (auxiliary role). The three pre-created candidates
-- are borrowed read-only for display; the task owns publication authority.
-- GPU resources realize lazily on first draw only: open, input, status, and
-- close never touch graphics objects, so headless compositions drive the
-- full choice without a GPU. Presentation resources release exactly once on
-- close/dispose while the candidate records stay with the task.

local StarterChoiceAssetCache = require("libs.assets.src.StarterChoiceAssetCache")
local MonCache = require("libs.assets.src.MonCache")
local Personality = require("libs.mons.src.gen4.Personality")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local StarterChoiceController = require("libs.hgss.src.ui.StarterChoiceController")
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
---@field _topology ScreenTopology? dual-surface host topology for the current drawable size
---@field _machine table<string, unknown>? machine surface record for draw/hit mapping
---@field _info table<string, unknown>? info surface record for draw mapping
---@field _frameIndex integer player-owned text-frame choice carried into the presentation
---@field _doneIndex integer? completed candidate once the lock settles
---@field _width number last drawable width
---@field _height number last drawable height
local StarterChoiceState = {}
StarterChoiceState.__index = StarterChoiceState

-- Host gap between the machine and info surfaces; placement only, never a
-- semantic coordinate.
local SURFACE_GAP = 8

---@param opts { catalog: MonCatalog, cacheFs: CacheFs, frameIndex: integer }
---@return StarterChoiceState
function StarterChoiceState.new(opts)
  assert(type(opts) == "table", "starter choice requires its composition")
  assert(opts.catalog ~= nil, "starter choice requires the mon catalog")
  assert(opts.cacheFs ~= nil, "starter choice requires the generated-asset filesystem")
  assert(
    type(opts.frameIndex) == "number" and opts.frameIndex % 1 == 0 and opts.frameIndex >= 0,
    "starter choice requires the player-owned frame index"
  )
  return setmetatable({
    _catalog = opts.catalog,
    _cacheFs = opts.cacheFs,
    _frameIndex = opts.frameIndex,
    _controller = nil,
    _candidates = nil,
    _names = nil,
    _portraits = nil,
    _manifest = nil,
    _presentation = nil,
    _topology = nil,
    _machine = nil,
    _info = nil,
    _doneIndex = nil,
    _width = 256,
    _height = 192,
  }, StarterChoiceState)
end

---@return boolean
function StarterChoiceState:isActive()
  return self._controller ~= nil
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
  self:resize(self._width, self._height)
end

function StarterChoiceState:close()
  assert(self:isActive(), "no starter choice is active")
  self:_releasePresentation()
  self._controller = nil
  self._candidates = nil
  self._names = nil
  self._portraits = nil
  self._manifest = nil
  self._topology = nil
  self._machine = nil
  self._info = nil
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
end

---@return { done: boolean, cursor: integer?, index: integer? }|nil
function StarterChoiceState:status()
  local controller = self._controller
  if controller == nil then
    return nil
  end
  local snapshot = controller:snapshot()
  if snapshot.done then
    local index = snapshot.result ~= nil and snapshot.result.index or nil
    self._doneIndex = assert(index, "a completed choice names its candidate")
    return { done = true, index = self._doneIndex }
  end
  return { done = false, cursor = snapshot.selection }
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

-- Maps a host pointer position through the machine surface only onto its
-- 256x192 reference frame, then onto the rendered balls: { kind = "ball",
-- index } zero-based, nil outside every region. Points on the info surface
-- or the host backdrop never hit a ball.
---@param x number
---@param y number
---@return { kind: string, index: integer }|nil
function StarterChoiceState:hitTest(x, y)
  local presentation = self._presentation
  if presentation == nil then
    return nil
  end
  local machine = self._machine
  if machine == nil then
    return nil
  end
  local referenceX, referenceY = presentation:toMachineReference(x, y)
  if referenceX == nil or referenceY == nil then
    return nil
  end
  local ball = presentation:ballAt(referenceX, referenceY, activeController(self):snapshot())
  if ball == nil then
    return nil
  end
  return { kind = "ball", index = ball - 1 }
end

-- Recomputes the dual-surface host layout without touching controller
-- state so resizes never reroll or reselect; hit projection follows the
-- machine surface of the same layout.
---@param width number
---@param height number
function StarterChoiceState:resize(width, height)
  assert(type(width) == "number" and width > 0, "starter resize requires a positive width")
  assert(type(height) == "number" and height > 0, "starter resize requires a positive height")
  self._width = width
  self._height = height
  local scale = math.min(height / 192, (width - SURFACE_GAP) / 512)
  assert(scale > 0, "starter resize requires a non-degenerate drawable size")
  local surfaceWidth, surfaceHeight = 256 * scale, 192 * scale
  local originX = (width - (surfaceWidth * 2 + SURFACE_GAP)) / 2
  local originY = (height - surfaceHeight) / 2
  local topology = ScreenTopology.dualDisplay({
    id = "machine",
    rect = { x = originX, y = originY, width = surfaceWidth, height = surfaceHeight },
    role = "world",
    touch = true,
  }, {
    id = "info",
    rect = { x = originX + surfaceWidth + SURFACE_GAP, y = originY, width = surfaceWidth, height = surfaceHeight },
    role = "auxiliary",
    touch = false,
  })
  self._topology = topology
  self._machine = assert(topology.surfaces[1], "starter presentation requires the machine surface")
  self._info = assert(topology.surfaces[2], "starter presentation requires the info surface")
  if self._presentation ~= nil then
    self._presentation:resize(width, height, self._machine.rect, self._info.rect)
  end
end

function StarterChoiceState:_releasePresentation()
  local presentation = self._presentation
  self._presentation = nil
  if presentation ~= nil then
    presentation:dispose()
  end
end

-- Draws the modal through the field text provider. Refreshes the scene fit
-- from the current drawable size, realizes presentation resources on first
-- presentation, and delegates the frame to the retail presentation.
---@param text table<string, unknown> text provider ({ drawLine, windowBackgroundColor })
---@param width number
---@param height number
function StarterChoiceState:drawPresentation(text, width, height)
  local controller = activeController(self)
  assert(text ~= nil and type(text.drawLine) == "function", "starter presentation requires the text provider")
  self:resize(width, height)
  activePresentation(self):draw(controller:snapshot(), {
    candidates = assert(self._candidates, "starter presentation requires its candidates"),
    names = assert(self._names, "starter presentation requires its candidate names"),
  }, text)
end

function StarterChoiceState:dispose()
  self:_releasePresentation()
  self._controller = nil
  self._candidates = nil
  self._names = nil
  self._portraits = nil
  self._manifest = nil
  self._topology = nil
  self._machine = nil
  self._info = nil
  self._doneIndex = nil
end

return StarterChoiceState
