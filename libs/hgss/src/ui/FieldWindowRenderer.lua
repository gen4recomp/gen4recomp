-- Shared static HGSS user-frame presentation primitive: the generated
-- dialogue frame-strip image, its lazily built per-frame tile quads, and
-- the content-background fill behind a supplied content box. The frame
-- tiles are composed by the audited DrawFrameAndWindow2 tilemap owned by
-- FieldDialogueTheme. Ordinary windows sample the original strip; the
-- application border samples a keyed copy whose menu-overlapping fill
-- is transparent, drawing whole source tiles on a shared target grid so
-- ornaments stay complete and every joint stays aligned. Exterior rims
-- and margins paint exactly as authored. This primitive owns no modal, controller, cursor, or text lifecycle;
-- callers supply the frame index (or nil for fill only), the content box,
-- and the background color. Construction is failure-safe: a missing frame
-- strip is a typed error and a quad failure after the image was created
-- releases the acquired image before rethrowing.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")

---@class FieldWindowRenderer
---@field _manifest table<string, unknown> the runtime-validated generated field-UI manifest
---@field _graphics love.graphics
---@field _frameImage love.Image?
---@field _applicationFrameImage love.Image? keyed copy, built lazily on first application draw
---@field _frameBytes string? retained strip bytes backing the lazy keyed build
---@field _frameQuadCache table<integer, love.Quad[]>|nil per-frame tile quads, built lazily
---@field _frameClipCache table<integer, love.Quad[]>|nil per-frame keyed application quads, built lazily
local FieldWindowRenderer = {}
FieldWindowRenderer.__index = FieldWindowRenderer

-- The symmetric application tile set: the left source columns and edge
-- rows, mirrored right. Any other strip tile in an application placement
-- is drift between the theme tilemap and this renderer.
local TILE_SIZE = FieldDialogueTheme.frameTileSize
local CAP_OVERLAP = FieldDialogueTheme.applicationFrameCapOverlap
local FRAME_TILES = FieldDialogueTheme.applicationFrameTiles
-- The application tile set mirrors the theme's addressed tiles. Any other
-- strip tile in an application placement is drift between the theme
-- tilemap and this renderer.
local APPLICATION_TILES = {
  [FRAME_TILES.topOuter] = true,
  [FRAME_TILES.topSpan] = true,
  [FRAME_TILES.sideOuter] = true,
  [FRAME_TILES.bottomOuter] = true,
  [FRAME_TILES.bottomSpan] = true,
}

-- Near-white texels read as window-interior fill: the generated frame
-- strip bakes its background white, while border inks stay well clear.
local WHITE_THRESHOLD = 250 / 255

-- Clears the edge-connected white of one 8x8 tile in place: white
-- 4-connected to the keying window boundary is fill showing field or
-- content, while isolated interior white (scaled highlights, dither dots)
-- is decoration and stays opaque. With no window the whole tile is the
-- window.

---@param imageData love.ImageData
---@param x0 integer tile left edge in image space
---@param y0 integer tile top edge in image space
---@param region { x: integer, y: integer, w: integer, h: integer }? tile-local keying window; the whole tile when omitted
function FieldWindowRenderer.clearEdgeWhite(imageData, x0, y0, region)
  assert(imageData and imageData.getPixel and imageData.setPixel, "clearEdgeWhite requires ImageData")
  local window = region or { x = 0, y = 0, w = TILE_SIZE, h = TILE_SIZE }
  assert(
    window.x >= 0
      and window.y >= 0
      and window.w >= 1
      and window.h >= 1
      and window.x + window.w <= TILE_SIZE
      and window.y + window.h <= TILE_SIZE,
    "clearEdgeWhite requires a window inside its tile"
  )
  local function isFill(x, y)
    local r, g, b, a = imageData:getPixel(x, y)
    return a > 0.5 and r >= WHITE_THRESHOLD and g >= WHITE_THRESHOLD and b >= WHITE_THRESHOLD
  end
  local left, top = x0 + window.x, y0 + window.y
  local right, bottom = left + window.w - 1, top + window.h - 1
  local stack = {}
  local function seed(x, y)
    if isFill(x, y) then
      stack[#stack + 1] = { x = x, y = y }
    end
  end
  for x = left, right do
    seed(x, top)
    seed(x, bottom)
  end
  for y = top, bottom do
    seed(left, y)
    seed(right, y)
  end
  local seen = {}
  while #stack > 0 do
    local at = stack[#stack]
    stack[#stack] = nil
    local key = at.x * 4096 + at.y
    if not seen[key] and at.x >= left and at.x <= right and at.y >= top and at.y <= bottom and isFill(at.x, at.y) then
      seen[key] = true
      imageData:setPixel(at.x, at.y, 1, 1, 1, 0)
      stack[#stack + 1] = { x = at.x + 1, y = at.y }
      stack[#stack + 1] = { x = at.x - 1, y = at.y }
      stack[#stack + 1] = { x = at.x, y = at.y + 1 }
      stack[#stack + 1] = { x = at.x, y = at.y - 1 }
    end
  end
end

-- Menu-overlap windows per application tile, tile-local: the inner
-- side column sits fully over content, so its fill clears throughout;
-- each cap clears only its content-facing row. Exterior tiles and rows
-- keep every texel, decorative rims included. The windows are
-- placement-geometry facts: every instance of these tiles shares the
-- same content overlap whatever the body size.
-- Menu-overlap windows per application span tile, tile-local: each cap
-- clears only its content-facing overlap row. Sides sit fully exterior so
-- they keep every texel. The windows are placement-geometry facts: every
-- instance of these tiles shares the same content overlap whatever the
-- body size.
local MENU_OVERLAP_TILE_WINDOWS = {
  [FRAME_TILES.bottomSpan] = { x = 0, y = 0, w = TILE_SIZE, h = CAP_OVERLAP },
  [FRAME_TILES.topSpan] = { x = 0, y = TILE_SIZE - CAP_OVERLAP, w = TILE_SIZE, h = CAP_OVERLAP },
}

-- Keys one strip copy for application frames: edge-connected white
-- clears only inside the menu-overlap windows, so content shows through
-- the frame exactly where the frame covers it while exterior rims and
-- margins paint as authored.
---@param imageData love.ImageData
---@param frames { count: integer, frameTiles: table<integer, { x: integer, y: integer, width: integer, height: integer }> }
function FieldWindowRenderer.keyApplicationCopy(imageData, frames)
  assert(imageData and imageData.getPixel and imageData.setPixel, "keyApplicationCopy requires ImageData")
  assert(type(frames) == "table" and type(frames.count) == "number" and type(frames.frameTiles) == "table")
  for frameIndex = 0, frames.count - 1 do
    local rect = assert(frames.frameTiles[frameIndex])
    for tile, window in pairs(MENU_OVERLAP_TILE_WINDOWS) do
      FieldWindowRenderer.clearEdgeWhite(imageData, rect.x + tile * 8, rect.y, window)
    end
  end
end

---@param opts { cacheFs: CacheFs, manifest: table<string, unknown>, graphics?: love.graphics }
---@return FieldWindowRenderer
function FieldWindowRenderer.new(opts)
  assert(
    type(opts) == "table" and opts.cacheFs and opts.cacheFs.read,
    "FieldWindowRenderer requires a CacheFs-shaped object"
  )
  local graphics = opts.graphics
  if graphics == nil then
    graphics = assert(love.graphics)
  end
  assert(graphics and graphics.newImage and graphics.newQuad, "FieldWindowRenderer requires love.graphics")
  local manifest = opts.manifest
  assert(type(manifest) == "table", "FieldWindowRenderer requires the runtime-validated field-UI manifest")
  local frameAsset = assert(
    manifest.assets[FieldUiAssetCache.ASSET.DIALOGUE_FRAME_TILES],
    "the field-UI manifest must carry the dialogue frame strip asset"
  )
  local frameImagePath = assert(frameAsset.image, "the dialogue frame strip asset must name an image path")
  assert(manifest.dialogueFrames, "the field-UI manifest must carry dialogue frames")
  local self = setmetatable({
    _manifest = manifest,
    _graphics = graphics,
    _frameImage = nil,
    _applicationFrameImage = nil,
    _frameBytes = nil,
    _frameQuadCache = nil,
    _frameClipCache = nil,
  }, FieldWindowRenderer)
  local frameData = opts.cacheFs:read(frameImagePath)
  if not frameData then
    self:release()
    Errors.raise(
      FieldErrors.FIELD_UI_FRAME_ATLAS_MISSING,
      "dialogue frame strip missing at " .. frameImagePath,
      { path = frameImagePath }
    )
  end
  frameData = assert(frameData)
  local ok, err = pcall(function()
    local imageData = love.image.newImageData(love.filesystem.newFileData(frameData, frameImagePath))
    self._frameImage = graphics.newImage(imageData)
    self._frameImage:setFilter("nearest", "nearest")
    self._frameBytes = frameData
  end)
  if not ok then
    self:release()
    error(err)
  end
  return self
end

-- Builds the keyed application copy on first application use: the strip
-- bytes decoded again with menu-overlapping fill transparent, never at
-- construction so dialogue-only callers never pay for frames they never
-- decorate. Failures leave dialogue rendering untouched.
---@param self FieldWindowRenderer
local function ensureKeyed(self)
  if self._applicationFrameImage ~= nil then
    return
  end
  local frameBytes = assert(self._frameBytes, "the window renderer owns no retained frame bytes")
  local manifest = assert(self._manifest, "the window renderer owns no manifest")
  local asset = assert(manifest.assets[FieldUiAssetCache.ASSET.DIALOGUE_FRAME_TILES])
  local keyedData = love.image.newImageData(love.filesystem.newFileData(frameBytes, assert(asset.image)))
  FieldWindowRenderer.keyApplicationCopy(keyedData, assert(manifest.dialogueFrames))
  local graphics = assert(self._graphics, "the window renderer owns no graphics")
  local keyedImage = graphics.newImage(keyedData)
  keyedImage:setFilter("nearest", "nearest")
  self._applicationFrameImage = keyedImage
end

-- The keyed whole-tile quad for one application band tile: every piece
-- samples its complete source tile, so ornaments stay whole and each
-- band paints its own art exactly once. Whole tiles on the shared target
-- grid keep every joint aligned by construction. Unknown frame indexes
-- and off-tilemap tiles fail loudly so theme/renderer contract drift
-- never draws the wrong art silently.
---@param frameIndex integer generated frame index
---@param tile integer strip tile identity, one of the application tile set
---@return love.Quad
function FieldWindowRenderer:clipQuad(frameIndex, tile)
  assert(APPLICATION_TILES[tile], "application frame carries no tile " .. tostring(tile))
  local frames = assert(self._manifest.dialogueFrames, "the field-UI manifest must carry dialogue frames")
  local rect = frames.frameTiles[frameIndex]
  assert(rect ~= nil, "dialogue frame index " .. tostring(frameIndex) .. " is outside the generated frame set")
  ensureKeyed(self)
  local lg = assert(self._graphics)
  local image = assert(self._applicationFrameImage, "the window renderer owns no keyed frame strip")
  local atlasWidth, atlasHeight = image:getWidth(), image:getHeight()
  local cache = self._frameClipCache or {}
  self._frameClipCache = cache
  local quads = cache[frameIndex]
  if quads == nil then
    quads = {}
    cache[frameIndex] = quads
  end
  local quad = quads[tile]
  if quad == nil then
    quad = lg.newQuad(rect.x + tile * TILE_SIZE, rect.y, TILE_SIZE, TILE_SIZE, atlasWidth, atlasHeight)
    quads[tile] = quad
  end
  return quad
end

-- The 18 tile quads of one frame: each 8x8 tile of the strip row named by
-- the manifest rect. Built lazily per frame index and cached, so a caller
-- that only ever shows one frame never materializes the other rows.
---@param frameIndex integer
---@return love.Quad[]
function FieldWindowRenderer:frameQuads(frameIndex)
  local frames = assert(self._manifest.dialogueFrames, "the field-UI manifest must carry dialogue frames")
  local rect = frames.frameTiles[frameIndex]
  assert(rect ~= nil, "dialogue frame index " .. tostring(frameIndex) .. " is outside the generated frame set")
  local lg = assert(self._graphics)
  local image = assert(self._frameImage, "the window renderer owns no frame strip")
  local atlasWidth, atlasHeight = image:getWidth(), image:getHeight()
  local cache = self._frameQuadCache or {}
  local quads = cache[frameIndex]
  if quads == nil then
    quads = {}
    for tile = 0, rect.width / TILE_SIZE - 1 do
      quads[tile] = lg.newQuad(rect.x + tile * TILE_SIZE, rect.y, TILE_SIZE, TILE_SIZE, atlasWidth, atlasHeight)
    end
    cache[frameIndex] = quads
  end
  self._frameQuadCache = cache
  return quads
end

-- Returns the immutable generated palette for the selected dialogue frame.
---@param frameIndex integer
---@return { [integer]: { r: integer, g: integer, b: integer } }
function FieldWindowRenderer:framePalette(frameIndex)
  local frames = assert(self._manifest.dialogueFrames, "the field-UI manifest must carry dialogue frames")
  assert(
    frames.frameTiles[frameIndex] ~= nil,
    "dialogue frame index " .. tostring(frameIndex) .. " is outside the generated frame set"
  )
  return assert(frames.palettes[frameIndex], "dialogue frame palette is missing")
end

-- Draws the application border around the content box from the selected
-- frame row: one exterior side column per side plus the bottom and top
-- caps, sampling whole keyed source tiles with no artwork rotation. The
-- sides reuse the outer source column and each cap its own source edge
-- row; whole tiles on the shared target grid keep every joint aligned
-- while ornaments stay complete and each band paints once. The frame
-- draws after content, so transparent texels reveal it. Never fills the
-- content box or the surrounding host area; callers own the LogicalSurface
-- placement. No graphics transform is borrowed.
---@param box { x: number, y: number, width: number, height: number } content box in the caller's reference space
---@param frameIndex integer generated frame index
function FieldWindowRenderer:drawApplicationFrame(box, frameIndex)
  assert(
    type(box) == "table" and box.x and box.y and box.width and box.height,
    "drawApplicationFrame requires the content box"
  )
  ---@cast box FieldDialogueTheme.Rect
  local lg = assert(self._graphics)
  local frames = assert(self._manifest.dialogueFrames)
  assert(
    frames.frameTiles[frameIndex] ~= nil,
    "dialogue frame index " .. tostring(frameIndex) .. " is outside the generated frame set"
  )
  ensureKeyed(self)
  local keyedImage = assert(self._applicationFrameImage, "the window renderer owns no keyed frame strip")
  local groups = FieldDialogueTheme.applicationFrameTilePlacements(box)
  lg.setColor(1, 1, 1, 1)
  for _, placement in ipairs(groups.sides) do
    local quad = self:clipQuad(frameIndex, placement.tile)
    if placement.flipX then
      lg.draw(keyedImage, quad, placement.x + TILE_SIZE, placement.y, 0, -1, 1)
    else
      lg.draw(keyedImage, quad, placement.x, placement.y)
    end
  end
  for _, placement in ipairs(groups.bottom) do
    local quad = self:clipQuad(frameIndex, placement.tile)
    if placement.flipX then
      lg.draw(keyedImage, quad, placement.x + TILE_SIZE, placement.y, 0, -1, 1)
    else
      lg.draw(keyedImage, quad, placement.x, placement.y)
    end
  end
  for _, placement in ipairs(groups.top) do
    local quad = self:clipQuad(frameIndex, placement.tile)
    if placement.flipX then
      lg.draw(keyedImage, quad, placement.x + TILE_SIZE, placement.y, 0, -1, 1)
    else
      lg.draw(keyedImage, quad, placement.x, placement.y)
    end
  end
end

-- Draws the content-background fill and, for a non-nil frame index, the
-- player frame around the content box. A nil frame index draws the fill only
-- rather than inventing a frame.
---@param box { x: number, y: number, width: number, height: number } content box in the caller's reference space
---@param frameIndex integer? generated frame index, nil draws the fill only
---@param backgroundColor number[] { r, g, b, a } content fill color
function FieldWindowRenderer:drawWindow(box, frameIndex, backgroundColor)
  assert(type(box) == "table" and box.x and box.y and box.width and box.height, "drawWindow requires the content box")
  ---@cast box FieldDialogueTheme.Rect
  assert(
    type(backgroundColor) == "table" and backgroundColor[1] and backgroundColor[2] and backgroundColor[3],
    "drawWindow requires the background color"
  )
  local lg = assert(self._graphics)
  lg.setColor(backgroundColor[1], backgroundColor[2], backgroundColor[3], backgroundColor[4] or 1)
  lg.rectangle("fill", box.x, box.y, box.width, box.height)
  if frameIndex == nil then
    return
  end
  local quads = self:frameQuads(frameIndex)
  local image = assert(self._frameImage)
  lg.setColor(1, 1, 1, 1)
  for _, placement in ipairs(FieldDialogueTheme.frameTilePlacements(box)) do
    local tile = assert(quads[placement.tile])
    for row = 0, (placement.spanY or 1) - 1 do
      for col = 0, (placement.spanX or 1) - 1 do
        lg.draw(image, tile, placement.x + col * TILE_SIZE, placement.y + row * TILE_SIZE)
      end
    end
  end
end

function FieldWindowRenderer:release()
  if self._frameImage and self._frameImage.release then
    self._frameImage:release()
  end
  if self._applicationFrameImage and self._applicationFrameImage.release then
    self._applicationFrameImage:release()
  end
  self._frameImage = nil
  self._applicationFrameImage = nil
  self._frameBytes = nil
  self._frameQuadCache = nil
  self._frameClipCache = nil
end

return FieldWindowRenderer
