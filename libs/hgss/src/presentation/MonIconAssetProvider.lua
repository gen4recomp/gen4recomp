-- Runtime owner of the compiled mon icon pages. Construction loads and
-- validates the generated icon layout metadata only and builds the
-- page-to-entries index; no GPU image is realized there. The visible party
-- demands exactly the pages behind its current icon keys through
-- prepareKeys, which stages each page through compilation readiness, image
-- worker decoding, and at most one GPU realization per call. Getters stay
-- read-only: an unprepared page is a loud error, never a blank icon or a
-- draw-time load. Portrait pages are never acquired here: the visible party
-- demands its icon pages through prepareKeys, and portraits stay on demand elsewhere.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local MonAssetSchema = require("libs.assets.src.MonAssetSchema")
local MonCache = require("libs.assets.src.MonCache")

---@class MonIconAssetProvider
---@field _graphics love.graphics
---@field _cacheFs CacheFs
---@field _manifest table<string, unknown>
---@field _pageEntries table<integer, table<string, unknown>[]> validated entries by zero-based page id
---@field _pages table<integer, table<string, unknown>> preparation state by zero-based page id
---@field _queue table<string, unknown>? borrowed image preparation worker
---@field _derivedAssets table<string, unknown>? borrowed semantic cache host
---@field _images table<integer, love.Image> page image by zero-based page id
---@field _quads table<string, love.Quad>
---@field _released boolean
local MonIconAssetProvider = {}
MonIconAssetProvider.__index = MonIconAssetProvider

---@param cacheFs CacheFs
---@return table<string, unknown>
local function loadManifest(cacheFs)
  local manifest = cacheFs:loadLua(MonCache.iconManifestPath())
  if type(manifest) ~= "table" then
    Errors.raise(
      FieldErrors.MON_ICON_MANIFEST_UNAVAILABLE,
      "no compiled mon icon manifest at " .. MonCache.iconManifestPath(),
      { path = MonCache.iconManifestPath() }
    )
  end
  local ok, err = pcall(MonAssetSchema.assertManifest, manifest, MonCache.ICON_MANIFEST_SCHEMA)
  if not ok then
    Errors.raise(
      FieldErrors.MON_ICON_MANIFEST_UNAVAILABLE,
      "the compiled mon icon manifest is invalid: " .. tostring(err),
      { path = MonCache.iconManifestPath() }
    )
  end
  assert(manifest ~= nil, "the icon manifest carries validated entries")
  return manifest
end

---@param manifest table<string, unknown>
---@param iconKey string
---@return table<string, unknown>
local function entryFor(manifest, iconKey)
  assert(type(iconKey) == "string" and iconKey ~= "", "icon selection requires a semantic key")
  local entry = manifest.entries[iconKey]
  if entry == nil then
    Errors.raise(FieldErrors.MON_ICON_UNKNOWN_KEY, "unknown mon icon key " .. iconKey, { iconKey = iconKey })
  end
  assert(entry ~= nil, "the manifest carries the resolved entry")
  return entry
end

---@param manifest table<string, unknown>
---@return table<integer, table<string, unknown>[]>
local function indexEntriesByPage(manifest)
  local index = {}
  for _, entry in pairs(manifest.entries) do
    local pageId = entry.pageId
    local bucket = index[pageId]
    if bucket == nil then
      bucket = {}
      index[pageId] = bucket
    end
    bucket[#bucket + 1] = entry
  end
  return index
end

---@param cacheFs CacheFs
---@param opts { graphics?: love.graphics, preparationQueue?: table<string, unknown>, derivedAssets?: table<string, unknown> }?
---@return MonIconAssetProvider
function MonIconAssetProvider.new(cacheFs, opts)
  assert(cacheFs ~= nil, "MonIconAssetProvider requires a CacheFs")
  opts = opts or {}
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.newImage and graphics.newQuad, "MonIconAssetProvider requires love.graphics")
  local manifest = loadManifest(cacheFs)
  return setmetatable({
    _graphics = graphics,
    _cacheFs = cacheFs,
    _manifest = manifest,
    _pageEntries = indexEntriesByPage(manifest),
    _pages = {},
    _queue = opts.preparationQueue,
    _derivedAssets = opts.derivedAssets,
    _images = {},
    _quads = {},
    _released = false,
  }, MonIconAssetProvider)
end

---@param self MonIconAssetProvider
---@param pageId integer
---@return table<string, unknown> the mutable preparation record for the page
local function pageState(self, pageId)
  local state = self._pages[pageId]
  if state == nil then
    state = { phase = "compile-pending", token = nil, payload = nil, image = nil, failure = nil }
    self._pages[pageId] = state
  end
  return state
end

---@param self MonIconAssetProvider
---@param iconKeys string[]
---@return integer[] sorted unique page ids behind the keys
local function uniquePages(self, iconKeys)
  assert(type(iconKeys) == "table", "icon preparation requires the visible icon keys")
  local seen = {}
  local pages = {}
  for _, iconKey in ipairs(iconKeys) do
    local entry = entryFor(self._manifest, iconKey)
    local pageId = entry.pageId
    if not seen[pageId] then
      seen[pageId] = true
      pages[#pages + 1] = pageId
    end
  end
  table.sort(pages)
  return pages
end

---@param self MonIconAssetProvider
---@param pageId integer
---@param image love.Image
local function validatePageBounds(self, pageId, image)
  local imageWidth, imageHeight = image:getWidth(), image:getHeight()
  for _, entry in ipairs(assert(self._pageEntries[pageId], "the page index carries the realized page")) do
    for _, frame in ipairs(entry.frames) do
      assert(
        frame.x + frame.width <= imageWidth and frame.y + frame.height <= imageHeight,
        "icon frame exceeds its page"
      )
    end
  end
end

---@param self MonIconAssetProvider
---@param pageId integer
---@param payload table<string, unknown>
local function realizePage(self, pageId, payload)
  local imageData = assert(payload.imageData, "decoded icon page carries its image data")
  local image = self._graphics.newImage(imageData)
  image:setFilter("nearest", "nearest")
  validatePageBounds(self, pageId, image)
  self._images[pageId] = image
  local state = pageState(self, pageId)
  state.image = image
  state.payload = nil
  state.phase = "ready"
end

-- Advances the demanded pages one step: compilation readiness through the
-- semantic cache host, then one image-worker decode per compiled page,
-- then at most one GPU realization. Returns whether the full key set is
-- ready and the first page failure, if any. Unknown keys fail the round
-- as a visible error instead of enrolling partial work.
---@param iconKeys string[]
---@return boolean ready
---@return string? failure
function MonIconAssetProvider:prepareKeys(iconKeys)
  assert(not self._released, "the icon provider is released")
  local queue = assert(self._queue, "presented icon preparation requires the image preparation queue")
  local derivedAssets = assert(self._derivedAssets, "presented icon preparation requires the semantic cache host")
  local ok, pages = pcall(uniquePages, self, iconKeys)
  if not ok then
    return false, tostring(pages)
  end
  assert(pages ~= nil, "icon keys resolve to demanded pages")
  local allReady = true
  local firstFailure = nil
  local realized = 0
  for _, pageId in ipairs(pages) do
    local state = pageState(self, pageId)
    if state.phase == "ready" then
      -- Already realized for the field lifetime; nothing to do.
    elseif state.phase == "failed" then
      allReady = false
      if firstFailure == nil then
        firstFailure = state.failure
      end
    else
      local pageReady, pageFailure = derivedAssets.requestIconPage(pageId, "required")
      if pageFailure ~= nil then
        state.phase = "failed"
        state.failure = tostring(pageFailure)
        allReady = false
        if firstFailure == nil then
          firstFailure = state.failure
        end
      elseif not pageReady then
        allReady = false
      else
        if state.token == nil and state.payload == nil then
          local path = MonCache.iconPagePath(pageId)
          local bytes = self._cacheFs:read(path)
          if bytes == nil then
            state.phase = "failed"
            state.failure = "mon icon page missing at " .. path
            allReady = false
            if firstFailure == nil then
              firstFailure = state.failure
            end
          else
            state.token = queue:request("image", path, "demand")
          end
        end
        if state.phase ~= "failed" then
          if state.payload ~= nil then
            if realized == 0 then
              local payloadOk, payloadErr = pcall(realizePage, self, pageId, state.payload)
              if payloadOk then
                realized = realized + 1
              else
                state.phase = "failed"
                state.failure = tostring(payloadErr)
                state.payload = nil
                allReady = false
                if firstFailure == nil then
                  firstFailure = state.failure
                end
              end
            else
              allReady = false
            end
          elseif state.token ~= nil then
            local status, cause = queue:poll(state.token)
            if status == "failed" then
              queue:cancel(state.token)
              state.token = nil
              state.phase = "failed"
              state.failure = tostring(cause)
              allReady = false
              if firstFailure == nil then
                firstFailure = state.failure
              end
            elseif status == "ready" then
              state.payload = queue:take(state.token)
              state.token = nil
              if realized == 0 then
                local payloadOk, payloadErr = pcall(realizePage, self, pageId, state.payload)
                if payloadOk then
                  realized = realized + 1
                else
                  state.phase = "failed"
                  state.failure = tostring(payloadErr)
                  state.payload = nil
                  allReady = false
                  if firstFailure == nil then
                    firstFailure = state.failure
                  end
                end
              else
                allReady = false
              end
            else
              allReady = false
            end
          else
            allReady = false
          end
        end
      end
    end
  end
  return allReady, firstFailure
end

-- Drops pending image interest without touching realized pages: owned
-- decode tokens cancel through the borrowed queue and compiled pages wait
-- for a fresh decode on the next round. Ready GPU pages survive for
-- reopen and reorder; release owns their lifetime instead.
function MonIconAssetProvider:cancelPreparation()
  local queue = self._queue
  if queue == nil then
    return
  end
  for _, state in pairs(self._pages) do
    if state.token ~= nil then
      queue:cancel(state.token)
      state.token = nil
      if state.phase ~= "failed" then
        state.phase = "compile-pending"
      end
    end
  end
end

-- The page image carrying one icon selector. Selectors sharing a page
-- share its image; selectors on different pages resolve to their own.
-- Read-only: an unprepared page is a loud error, never a blank icon.
---@param iconKey string
---@return love.Image the page image for draw calls
function MonIconAssetProvider:image(iconKey)
  assert(not self._released, "the icon provider is released")
  local entry = entryFor(self._manifest, iconKey)
  local image = self._images[entry.pageId]
  assert(image ~= nil, "the icon page is not prepared for " .. iconKey)
  return image
end

---@param iconKey string
---@param frameIndex integer?
---@return love.Quad quad
function MonIconAssetProvider:quadFor(iconKey, frameIndex)
  assert(not self._released, "the icon provider is released")
  frameIndex = frameIndex or 1
  assert(type(frameIndex) == "number" and frameIndex % 1 == 0 and frameIndex >= 1, "icon frame index starts at one")
  local entry = entryFor(self._manifest, iconKey)
  assert(frameIndex <= #entry.frames, "icon frame " .. frameIndex .. " is missing for " .. iconKey)
  local cacheKey = iconKey .. "#" .. frameIndex
  local quad = self._quads[cacheKey]
  if quad == nil then
    local frame = entry.frames[frameIndex]
    local image = self._images[entry.pageId]
    assert(image ~= nil, "the icon page is not prepared for " .. iconKey)
    quad = self._graphics.newQuad(frame.x, frame.y, frame.width, frame.height, image:getWidth(), image:getHeight())
    self._quads[cacheKey] = quad
  end
  return quad
end

---@param iconKey string
---@return { width: integer, height: integer }
function MonIconAssetProvider:dimensions(iconKey)
  assert(not self._released, "the icon provider is released")
  local entry = entryFor(self._manifest, iconKey)
  return { width = entry.width, height = entry.height }
end

-- Releases every page image exactly once; quads reference no resources of
-- their own, so dropping the cache is sufficient. Safe to call repeatedly.
-- Preparation tokens cancel first so no decode outlives the provider; the
-- borrowed image queue itself is field-owned and stays live.
function MonIconAssetProvider:release()
  self:cancelPreparation()
  local images = self._images
  self._images = {}
  self._quads = {}
  self._pages = {}
  self._released = true
  for _, image in pairs(images) do
    if image ~= nil and image.release then
      image:release()
    end
  end
end

return MonIconAssetProvider
