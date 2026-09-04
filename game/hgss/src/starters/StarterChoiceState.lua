-- Modal starter-choice host for the blocking starter task. It owns the
-- pure controller, presents the three pre-created candidates through the
-- starter layout/renderer, and lazily acquires portrait images on first
-- draw only: open, input, status, and close never touch graphics
-- resources, so headless compositions drive the full choice without a
-- GPU. Portrait resources release exactly once on close/dispose.

local MonCache = require("libs.assets.src.MonCache")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local StarterChoiceController = require("libs.hgss.src.ui.StarterChoiceController")
local StarterChoiceLayout = require("libs.hgss.src.ui.StarterChoiceLayout")
local StarterChoiceRenderer = require("libs.hgss.src.ui.StarterChoiceRenderer")

---@class StarterChoiceState
---@field _catalog MonCatalog generated mon catalog for names and portrait selectors
---@field _cacheFs table<string, unknown>? generated-asset filesystem for portrait loading
---@field _controller StarterChoiceController? active choice controller, nil while idle
---@field _names string[]|nil candidate display names while open
---@field _species string[]|nil candidate species keys while open
---@field _doneIndex integer? completed candidate once confirmed
---@field _layout StarterChoiceLayout.Resolved? last resolved geometry for hit testing
---@field _portraitImage table<string, unknown>? shared portrait atlas image
---@field _portraits table<string, unknown>[]? per-candidate { image, quad } entries
local StarterChoiceState = {}
StarterChoiceState.__index = StarterChoiceState

---@param opts { catalog: MonCatalog, cacheFs: table<string, unknown>? }
---@return StarterChoiceState
function StarterChoiceState.new(opts)
  assert(type(opts) == "table", "starter choice requires its composition")
  assert(opts.catalog ~= nil, "starter choice requires the mon catalog")
  return setmetatable({
    _catalog = opts.catalog,
    _cacheFs = opts.cacheFs,
    _controller = nil,
    _names = nil,
    _species = nil,
    _doneIndex = nil,
    _layout = nil,
    _portraitImage = nil,
    _portraits = nil,
  }, StarterChoiceState)
end

---@return boolean
function StarterChoiceState:isActive()
  return self._controller ~= nil
end

-- Opens the modal on the task cursor with the three pre-created
-- candidates. The records are borrowed read-only for presentation; the
-- task owns publication authority.
---@param cursor integer zero-based opening candidate
---@param candidates table[] three complete semantic mon records
function StarterChoiceState:open(cursor, candidates)
  assert(not self:isActive(), "a starter choice is already active")
  assert(
    type(cursor) == "number" and cursor % 1 == 0 and cursor >= 0 and cursor <= 2,
    "starter open requires a candidate cursor"
  )
  assert(type(candidates) == "table" and #candidates == 3, "starter open requires three candidates")
  local names, species = {}, {}
  for index, candidate in ipairs(candidates) do
    assert(type(candidate) == "table" and type(candidate.species) == "string", "starter candidates carry species keys")
    local definition = self._catalog:species(candidate.species)
    names[index] = definition.name
    species[index] = candidate.species
  end
  self._names = names
  self._species = species
  self._doneIndex = nil
  self._layout = nil
  self._controller = StarterChoiceController.new({ candidates = names, initialCursor = cursor })
end

function StarterChoiceState:close()
  assert(self:isActive(), "no starter choice is active")
  self:_releasePortraits()
  self._controller = nil
  self._names = nil
  self._species = nil
  self._doneIndex = nil
  self._layout = nil
end

---@return { done: boolean, cursor: integer?, mode: string?, index: integer? }|nil
function StarterChoiceState:status()
  local controller = self._controller
  if controller == nil then
    return nil
  end
  local controllerStatus = controller:status()
  if controllerStatus.state == "complete" then
    return { done = true, index = assert(self._doneIndex, "a completed choice names its candidate") }
  end
  return { done = false, cursor = controllerStatus.candidateIndex, mode = controllerStatus.mode }
end

---@param self StarterChoiceState
---@return StarterChoiceController active controller
local function activeController(self)
  local controller = self._controller
  assert(controller ~= nil, "no starter choice is active")
  return controller
end

---@param itemIndex integer
function StarterChoiceState:focus(itemIndex)
  activeController(self):focus(itemIndex)
end

---@return { candidate: integer, accepted: boolean }|nil
function StarterChoiceState:confirm()
  local controller = activeController(self)
  local result = controller:confirm()
  if result ~= nil then
    self._doneIndex = result.candidate
  end
  return result
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
---@return { candidate: integer, accepted: boolean }|nil
function StarterChoiceState:release(itemIndex)
  local result = activeController(self):release(itemIndex)
  if result ~= nil then
    self._doneIndex = result.candidate
  end
  return result
end

---@param x number
---@param y number
---@return { kind: "candidate"|"confirm", index: integer }|nil
function StarterChoiceState:hitTest(x, y)
  local layout = self._layout
  if layout == nil then
    return nil
  end
  return StarterChoiceLayout.hitTest(layout, x, y)
end

-- Recomputes the responsive geometry without touching controller state so
-- resizes never reroll or reselect.
---@param width number
---@param height number
function StarterChoiceState:resize(width, height)
  assert(type(width) == "number" and width > 0, "starter resize requires a positive width")
  assert(type(height) == "number" and height > 0, "starter resize requires a positive height")
  self._layout = StarterChoiceLayout.resolve({
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = width, height = height },
      role = "world",
      touch = false,
    }),
    scale = 1,
  })
end

function StarterChoiceState:_releasePortraits()
  local image = self._portraitImage
  self._portraitImage = nil
  self._portraits = nil
  if image ~= nil and type(image.release) == "function" then
    image:release()
  end
end

-- Loads the shared portrait atlas and one quad per candidate through the
-- catalog's own portrait selectors. Draw-only: a missing atlas or selector
-- fails loudly, never as a placeholder swap.
function StarterChoiceState:_ensurePortraits()
  if self._portraits ~= nil or self._cacheFs == nil or self._species == nil then
    return
  end
  local graphics = love and love.graphics
  assert(graphics and graphics.newImage and graphics.newQuad, "starter portraits require the graphics namespace")
  local manifest = self._cacheFs:loadLua(MonCache.portraitManifestPath())
  assert(type(manifest) == "table" and type(manifest.entries) == "table", "starter portrait manifest is invalid")
  local imageData = self._cacheFs:read(MonCache.portraitImagePath())
  assert(imageData, "starter portraits require the generated portrait atlas")
  local image = graphics.newImage(love.filesystem.newFileData(imageData, MonCache.portraitImagePath()))
  image:setFilter("nearest", "nearest")
  self._portraitImage = image
  local portraits = {}
  for index, speciesKey in ipairs(self._species) do
    local form = self._catalog:form(speciesKey, 0)
    local entry = manifest.entries[form.portrait]
    assert(type(entry) == "table", "starter portrait is missing for " .. tostring(speciesKey))
    portraits[index] = {
      image = image,
      quad = graphics.newQuad(entry.x, entry.y, entry.width, entry.height, image:getDimensions()),
    }
  end
  self._portraits = portraits
end

-- Draws the modal through the field text provider. Resolves fresh geometry
-- every frame from the current drawable size; portraits load once.
---@param text table<string, unknown> text provider ({ drawText })
---@param width number
---@param height number
function StarterChoiceState:drawPresentation(text, width, height)
  local controller = activeController(self)
  assert(text ~= nil and type(text.drawText) == "function", "starter presentation requires the text provider")
  self:resize(width, height)
  self:_ensurePortraits()
  local renderer = StarterChoiceRenderer.new()
  renderer:draw({
    status = controller:status(),
    layout = assert(self._layout, "starter presentation requires its layout"),
    names = assert(self._names, "starter presentation requires its candidate names"),
    portraits = self._portraits,
    text = text,
  })
end

function StarterChoiceState:dispose()
  self:_releasePortraits()
  self._controller = nil
  self._names = nil
  self._species = nil
  self._doneIndex = nil
  self._layout = nil
end

return StarterChoiceState
