-- Shared static HGSS user-frame presentation primitive: the generated
-- dialogue frame-strip image, its lazily built per-frame tile quads, and the
-- content-background fill behind a supplied content box. The frame tiles are
-- composed by the audited DrawFrameAndWindow2 tilemap owned by
-- FieldDialogueTheme. This primitive owns no modal, controller, cursor, or
-- text lifecycle; callers supply the frame index (or nil for fill only), the
-- content box, and the background color. Construction is failure-safe: a
-- missing frame strip is a typed error and a quad failure after the image
-- was created releases the acquired image before rethrowing.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")

---@class FieldWindowRenderer
---@field _manifest table<string, unknown> the runtime-validated generated field-UI manifest
---@field _graphics love.Graphics|love.graphics
---@field _frameImage love.Image?
---@field _frameQuadCache table<integer, love.Quad[]>|nil per-frame tile quads, built lazily
local FieldWindowRenderer = {}
FieldWindowRenderer.__index = FieldWindowRenderer

---@param opts { cacheFs: CacheFs, manifest: table<string, unknown>, graphics?: love.Graphics|love.graphics }
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
  local self = setmetatable({
    _manifest = manifest,
    _graphics = graphics,
    _frameImage = nil,
    _frameQuadCache = nil,
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
    self._frameImage = graphics.newImage(love.filesystem.newFileData(frameData, frameImagePath))
    self._frameImage:setFilter("nearest", "nearest")
  end)
  if not ok then
    self:release()
    error(err)
  end
  return self
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
    for tile = 0, rect.width / 8 - 1 do
      quads[tile] = lg.newQuad(rect.x + tile * 8, rect.y, 8, 8, atlasWidth, atlasHeight)
    end
    cache[frameIndex] = quads
  end
  self._frameQuadCache = cache
  return quads
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
        lg.draw(image, tile, placement.x + col * 8, placement.y + row * 8)
      end
    end
  end
end

function FieldWindowRenderer:release()
  if self._frameImage and self._frameImage.release then
    self._frameImage:release()
  end
  self._frameImage = nil
  self._frameQuadCache = nil
end

return FieldWindowRenderer
