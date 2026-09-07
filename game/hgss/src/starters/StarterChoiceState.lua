-- Modal starter-choice host for the blocking starter task. It owns the
-- pure retail controller, the validated starter-application manifest loaded
-- once per open through the generated-asset cache, and the game-local
-- presentation that realizes that manifest. The three pre-created candidates
-- are borrowed read-only for display; the task owns publication authority.
-- GPU resources realize lazily on first draw only: open, input, status, and
-- close never touch graphics objects, so headless compositions drive the
-- full choice without a GPU. Presentation resources release exactly once on
-- close/dispose while the candidate records stay with the task.

local StarterChoiceAssetCache = require("libs.assets.src.StarterChoiceAssetCache")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local StarterChoiceController = require("libs.hgss.src.ui.StarterChoiceController")
local StarterChoicePresentation = require("game.hgss.src.starters.StarterChoicePresentation")

---@class StarterChoiceState
---@field _catalog MonCatalog generated mon catalog for names
---@field _cacheFs table<string, unknown> generated-asset filesystem for the application cache
---@field _controller StarterChoiceController? active choice controller, nil while idle
---@field _candidates table[]|nil borrowed task-owned candidate records while open
---@field _names string[]|nil candidate display names while open
---@field _manifest table<string, unknown>? immutable validated application manifest while open
---@field _presentation StarterChoicePresentation? game-local scene presentation while open
---@field _doneIndex integer? completed candidate once the lock settles
---@field _width number last drawable width
---@field _height number last drawable height
local StarterChoiceState = {}
StarterChoiceState.__index = StarterChoiceState

---@param opts { catalog: MonCatalog, cacheFs: table<string, unknown> }
---@return StarterChoiceState
function StarterChoiceState.new(opts)
  assert(type(opts) == "table", "starter choice requires its composition")
  assert(opts.catalog ~= nil, "starter choice requires the mon catalog")
  assert(opts.cacheFs ~= nil, "starter choice requires the generated-asset filesystem")
  return setmetatable({
    _catalog = opts.catalog,
    _cacheFs = opts.cacheFs,
    _controller = nil,
    _candidates = nil,
    _names = nil,
    _manifest = nil,
    _presentation = nil,
    _doneIndex = nil,
    _width = 256,
    _height = 192,
  }, StarterChoiceState)
end

---@return boolean
function StarterChoiceState:isActive()
  return self._controller ~= nil
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
  self._candidates = candidates
  self._names = names
  self._manifest = manifest
  self._doneIndex = nil
  self._controller = StarterChoiceController.new({
    candidates = names,
    initialCursor = cursor,
    transitionTicks = manifest.scene.camera.transitionTicks,
  })
  local presentation = StarterChoicePresentation.new({ manifest = manifest, cacheFs = cacheFs })
  presentation:reset()
  presentation:resize(self._width, self._height)
  self._presentation = presentation
end

function StarterChoiceState:close()
  assert(self:isActive(), "no starter choice is active")
  self:_releasePresentation()
  self._controller = nil
  self._candidates = nil
  self._names = nil
  self._manifest = nil
  self._doneIndex = nil
end

-- One deterministic application tick: advances the controller transition
-- clocks and the presentation animation/camera clocks from the controller
-- snapshot. The field runtime steps this once per fixed tick while the
-- modal is open; ignored transitions stay settled without input.
function StarterChoiceState:update()
  local controller = self._controller
  if controller == nil then
    return
  end
  controller:update()
  local presentation = self._presentation
  if presentation ~= nil then
    presentation:update(controller:snapshot())
  end
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
function StarterChoiceState:hover(itemIndex)
  activeController(self):hover(itemIndex)
end

---@param itemIndex integer?
function StarterChoiceState:press(itemIndex)
  activeController(self):press(itemIndex)
end

---@param itemIndex integer?
---@return nil
function StarterChoiceState:release(itemIndex)
  return activeController(self):release(itemIndex)
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

-- Display-space pointer position onto the rendered balls through the strict
-- scene fit: { kind = "ball", index } zero-based, nil outside every region.
---@param x number
---@param y number
---@return integer?
function StarterChoiceState:hitTest(x, y)
  local presentation = self._presentation
  if presentation == nil then
    return nil
  end
  local referenceX, referenceY = presentation:toReference(x, y)
  if referenceX == nil or referenceY == nil then
    return nil
  end
  local ball = presentation:ballAt(referenceX, referenceY, activeController(self):snapshot())
  if ball == nil then
    return nil
  end
  return { kind = "ball", index = ball - 1 }
end

-- Recomputes the scene fit without touching controller state so resizes
-- never reroll or reselect; hit projection follows the same fit.
---@param width number
---@param height number
function StarterChoiceState:resize(width, height)
  assert(type(width) == "number" and width > 0, "starter resize requires a positive width")
  assert(type(height) == "number" and height > 0, "starter resize requires a positive height")
  self._width = width
  self._height = height
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    role = "world",
    touch = false,
  })
  local surface = assert(topology.surfaces[1], "starter presentation requires the main display surface")
  local frame = surface.safeRect or surface.rect
  if self._presentation ~= nil then
    self._presentation:resize(frame.width, frame.height)
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
---@param text table<string, unknown> text provider ({ drawText })
---@param width number
---@param height number
function StarterChoiceState:drawPresentation(text, width, height)
  local controller = activeController(self)
  assert(text ~= nil and type(text.drawText) == "function", "starter presentation requires the text provider")
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
  self._manifest = nil
  self._doneIndex = nil
end

return StarterChoiceState
