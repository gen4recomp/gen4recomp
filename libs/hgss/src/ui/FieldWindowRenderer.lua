-- Shared static HGSS user-frame presentation primitive: the generated
-- dialogue frame-strip image beside the masked application frame-strip
-- image, their lazily built per-frame tile quads, and the
-- content-background fill behind a supplied content box. The frame tiles are
-- composed by the audited DrawFrameAndWindow2 tilemap owned by
-- FieldDialogueTheme. Ordinary windows sample the original strip while
-- application chrome samples only the masked strip through the same shared
-- row rectangles. This primitive owns no modal, controller, cursor, or
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
---@field _graphics love.graphics
---@field _frameImage love.Image?
---@field _applicationFrameImage love.Image?
---@field _frameQuadCache table<integer, love.Quad[]>|nil per-frame tile quads, built lazily
local FieldWindowRenderer = {}
FieldWindowRenderer.__index = FieldWindowRenderer

-- The borrowed field text surface window chrome draws titles through:
-- plain-string drawing and measurement plus the generated font
-- definition carrying the base text height. Structural so production and
-- test doubles satisfy it without a second font owner.
---@alias FieldWindowRenderer.ChromeFontDef { maxLetterHeight: number }
---@alias FieldWindowRenderer.ChromeTextProvider { fontDef: FieldWindowRenderer.ChromeFontDef, drawText: fun(self: table<string, unknown>, text: string, x: number, y: number), textWidth: fun(self: table<string, unknown>, text: string): number }

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
  local dialogueFrames = assert(manifest.dialogueFrames, "the field-UI manifest must carry dialogue frames")
  local application =
    assert(dialogueFrames.application, "the field-UI manifest must carry the application frame record")
  assert(
    application.asset == FieldUiAssetCache.ASSET.APPLICATION_FRAME_TILES,
    "the application frame record must reference the application frame atlas"
  )
  local applicationAsset = assert(
    manifest.assets[FieldUiAssetCache.ASSET.APPLICATION_FRAME_TILES],
    "the field-UI manifest must carry the application frame strip asset"
  )
  local applicationImagePath =
    assert(applicationAsset.image, "the application frame strip asset must name an image path")
  local self = setmetatable({
    _manifest = manifest,
    _graphics = graphics,
    _frameImage = nil,
    _applicationFrameImage = nil,
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
  local applicationData = opts.cacheFs:read(applicationImagePath)
  if not applicationData then
    self:release()
    Errors.raise(
      FieldErrors.FIELD_UI_FRAME_ATLAS_MISSING,
      "application frame strip missing at " .. applicationImagePath,
      { path = applicationImagePath }
    )
  end
  applicationData = assert(applicationData)
  local applicationOk, applicationErr = pcall(function()
    self._applicationFrameImage = graphics.newImage(love.filesystem.newFileData(applicationData, applicationImagePath))
    self._applicationFrameImage:setFilter("nearest", "nearest")
  end)
  if not applicationOk then
    self:release()
    error(applicationErr)
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

-- Draws only the rotated application border around the content box from the
-- selected frame row: every tile instance of the shared rotated tilemap,
-- each with its artwork visually quarter-turned counter-clockwise so it
-- follows the rotated composition. Never fills the content box or the
-- surrounding host area; callers own the LogicalSurface placement.
---@param box { x: number, y: number, width: number, height: number } content box in the caller's reference space
---@param frameIndex integer generated frame index
function FieldWindowRenderer:drawApplicationFrame(box, frameIndex)
  assert(
    type(box) == "table" and box.x and box.y and box.width and box.height,
    "drawApplicationFrame requires the content box"
  )
  ---@cast box FieldDialogueTheme.Rect
  local quads = self:frameQuads(frameIndex)
  local image = assert(self._applicationFrameImage)
  local lg = assert(self._graphics)
  lg.setColor(1, 1, 1, 1)
  for _, placement in ipairs(FieldDialogueTheme.applicationFrameTilePlacements(box)) do
    local tile = assert(quads[placement.tile])
    lg.draw(image, tile, placement.x, placement.y, -math.pi / 2, 1, 1, 8, 0)
  end
end

-- Draws titled dismissible window chrome around the content box: the
-- masked application border first, then the title text, then the dismiss
-- mark only when the window is dismissible. The title is drawn with the
-- borrowed field text renderer and must fit the shared title region; an
-- oversized title fails before anything paints. The dismiss mark is one
-- crisp horizontal mark centered in the shared dismiss control. Ordinary
-- window drawing stays unrelated.
---@param box { x: number, y: number, width: number, height: number } content box in the caller's reference space
---@param frameIndex integer generated frame index
---@param chrome { title: string, dismissible: boolean } window identity record
---@param text FieldWindowRenderer.ChromeTextProvider borrowed field text renderer
function FieldWindowRenderer:drawApplicationChrome(box, frameIndex, chrome, text)
  assert(
    type(box) == "table" and box.x and box.y and box.width and box.height,
    "drawApplicationChrome requires the content box"
  )
  ---@cast box FieldDialogueTheme.Rect
  assert(
    type(chrome) == "table" and type(chrome.title) == "string" and chrome.title ~= "",
    "drawApplicationChrome requires a nonempty window title"
  )
  assert(type(chrome.dismissible) == "boolean", "drawApplicationChrome requires the dismiss flag")
  assert(
    text ~= nil and type(text.drawText) == "function" and type(text.textWidth) == "function",
    "drawApplicationChrome borrows the field text renderer"
  )
  local fontDef = assert(text.fontDef, "drawApplicationChrome needs the generated field font definition")
  local baseHeight = assert(fontDef.maxLetterHeight, "drawApplicationChrome needs the generated field font base height")
  local geometry = FieldDialogueTheme.applicationChromeGeometry(box)
  local titleWidth = text:textWidth(chrome.title)
  assert(titleWidth <= geometry.title.width, "the window title overflows its frame title region: " .. chrome.title)
  self:drawApplicationFrame(box, frameIndex)
  local lg = assert(self._graphics)
  local titleY = geometry.title.y + (geometry.title.height - baseHeight) / 2
  text:drawText(chrome.title, geometry.title.x, titleY)
  if chrome.dismissible then
    local markWidth, markHeight = 12, 2
    local markX = geometry.dismiss.x + (geometry.dismiss.width - markWidth) / 2
    local markY = geometry.dismiss.y + (geometry.dismiss.height - markHeight) / 2
    lg.setColor(16 / 255, 16 / 255, 32 / 255, 1)
    lg.rectangle("fill", markX, markY, markWidth, markHeight)
    lg.setColor(1, 1, 1, 1)
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
  if self._applicationFrameImage and self._applicationFrameImage.release then
    self._applicationFrameImage:release()
  end
  self._applicationFrameImage = nil
  self._frameQuadCache = nil
end

return FieldWindowRenderer
