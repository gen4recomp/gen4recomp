-- Renders the modal dialogue box into the viewport's centered 4:3 reference
-- frame: the authentic HGSS user-frame strip (the player's selected frame
-- index resolved from the generated field-UI manifest and drawn by the
-- DrawFrameAndWindow2 tilemap), the extracted glyph atlas text (ink and
-- shadow baked at import time), and a blinking continue cursor. It owns the
-- frame strip image and builds frame quads lazily per frame index; the
-- shared FieldTextRenderer (owned by FieldState) draws the glyph text. It
-- draws after the 3D world pass and restores every graphics state it
-- touches (canvas, shader, scissor, blend, depth, color). Presentation-only
-- by design: FieldFontLoader owns runtime font definitions and the generated
-- manifest owns frame rects. Construction is failure-safe: a missing frame
-- strip is a typed error, a quad failure after the images were created
-- releases the acquired images before rethrowing, and draw() balances its
-- transform push even when drawing raises. The runtime-validated manifest is
-- injected explicitly; this renderer never reloads it from the cache.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local DialoguePresentationLayout = require("libs.hgss.src.ui.DialoguePresentationLayout")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldDrawState = require("libs.hgss.src.presentation.FieldDrawState")

---@class FieldDialogueRenderer
---@field _theme FieldDialogueTheme
---@field _graphics love.Graphics|love.graphics
---@field _text FieldDialogueRenderer.TextRenderer the shared glyph atlas/line drawing collaborator
---@field _manifest table<string, unknown> the generated field-UI manifest
---@field _focusIndicatorEnabled boolean whether the source focus indicator is composed
---@field _frameImage love.Image?
---@field _cursorImage love.Image?
---@field _frameQuadCache table<integer, love.Quad[]>|nil per-frame tile quads, built lazily
---@field _cursorQuadCache table<integer, table<integer, love.Quad>>|nil
local FieldDialogueRenderer = {}
FieldDialogueRenderer.__index = FieldDialogueRenderer

---@alias FieldDialogueRenderer.Layout DialoguePresentationLayout.Presentation

---@class FieldDialogueRenderer.TextRenderer
---@field fontDef FieldFontDef
---@field _atlas love.Image?
---@field drawLine fun(self: FieldDialogueRenderer.TextRenderer, tokens: MessageToken[], x: number, y: number)
---@field drawFocusIndicator fun(self: FieldDialogueRenderer.TextRenderer, field: integer, x: number, y: number)
---@field windowBackgroundColor fun(self: FieldDialogueRenderer.TextRenderer): number[]

-- opts.cacheFs: version-scoped private cache holding the generated field-UI
-- class (frame strip PNGs); opts.manifest: the already-validated generated
-- field-UI manifest the runtime loaded once (FieldRuntime.uiManifest);
-- opts.text: the shared FieldTextRenderer (FieldState owns exactly one);
-- opts.graphics: injectable LÖVE graphics namespace so tests can record draw
-- calls; LÖVE itself remains an allowed presentation-layer dependency (the
-- PNG bytes still enter through love.filesystem.newFileData); opts.theme:
-- geometry record.

---@param opts { cacheFs: CacheFs, manifest: table<string, unknown>, text: unknown, theme?: FieldDialogueTheme, graphics?: unknown, drawFocusIndicator?: boolean }
---@return FieldDialogueRenderer
function FieldDialogueRenderer.new(opts)
  assert(
    type(opts) == "table" and opts.cacheFs and opts.cacheFs.read,
    "FieldDialogueRenderer requires a CacheFs-shaped object"
  )
  local theme = opts.theme or FieldDialogueTheme
  local graphics = opts.graphics
  if graphics == nil then
    graphics = assert(love.graphics)
  end
  assert(graphics and graphics.newImage and graphics.newQuad, "FieldDialogueRenderer requires love.graphics")
  ---@cast graphics love.Graphics|love.graphics
  local text = opts.text
  assert(
    text and type(text.drawLine) == "function" and type(text.drawFocusIndicator) == "function",
    "FieldDialogueRenderer requires the shared FieldTextRenderer"
  )
  ---@cast text FieldDialogueRenderer.TextRenderer
  local cacheFs = opts.cacheFs
  local manifest = opts.manifest
  assert(type(manifest) == "table", "FieldDialogueRenderer requires the runtime-validated field-UI manifest")

  -- The generated field-UI class is a required renderer asset: the manifest
  -- names the frame strip and every frame's tile rects. The runtime boot
  -- already validated the full manifest, so the renderer only resolves what
  -- it draws.
  local frameAsset = assert(
    manifest.assets[FieldUiAssetCache.ASSET.DIALOGUE_FRAME_TILES],
    "the field-UI manifest must carry the dialogue frame strip asset"
  )
  local frameImagePath = assert(frameAsset.image, "the dialogue frame strip asset must name an image path")

  local self = setmetatable({
    _theme = theme,
    _graphics = graphics,
    _text = text,
    _manifest = manifest,
    _focusIndicatorEnabled = opts.drawFocusIndicator ~= false,
    _frameImage = nil,
    _cursorImage = nil,
    _frameQuadCache = nil,
    _cursorQuadCache = nil,
  }, FieldDialogueRenderer)

  local frameData = cacheFs:read(frameImagePath)
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
  local cursor = assert(manifest.dialogueFrames.continueCursor)
  local cursorAsset = assert(manifest.assets[cursor.asset])
  local cursorData = cacheFs:read(cursorAsset.image)
  if not cursorData then
    self:release()
    Errors.raise(
      FieldErrors.FIELD_UI_CONTINUE_CURSOR_MISSING,
      "dialogue continuation cursor missing at " .. cursorAsset.image,
      { path = cursorAsset.image }
    )
  end
  cursorData = assert(cursorData)
  local cursorOk, cursorErr = pcall(function()
    self._cursorImage = graphics.newImage(love.filesystem.newFileData(cursorData, assert(cursorAsset.image)))
    self._cursorImage:setFilter("nearest", "nearest")
    self._cursorQuadCache = {}
    for style, styleEntry in pairs(cursor.styles) do
      local phases = assert(styleEntry).phases
      local quads = {}
      for phase = 0, 2 do
        local rect = assert(phases[phase])
        quads[phase] = graphics.newQuad(rect.x, rect.y, rect.width, rect.height, cursorAsset.width, cursorAsset.height)
      end
      self._cursorQuadCache[style] = quads
    end
  end)
  if not cursorOk then
    self:release()
    error(cursorErr)
  end
  return self
end

-- The 18 tile quads of one frame: each 8x8 tile of the strip row named by
-- the manifest rect. Built lazily per frame index and cached, so a session
-- that only ever shows one frame never materializes the other rows.
---@param frameIndex integer
---@param rect { x: integer, y: integer, width: integer, height: integer }
---@return love.Quad[]
function FieldDialogueRenderer:_buildFrameQuads(frameIndex, rect)
  local lg = assert(self._graphics)
  local image = assert(self._frameImage)
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

-- Draws the generated continuation phase while the controller waits at a
-- boundary. Timing and phase selection belong to the controller.

---@param status FieldDialogueController.Status
---@param layout FieldDialogueRenderer.Layout
function FieldDialogueRenderer:_drawCursor(status, layout)
  if not status.waiting or status.cursorPhase == nil then
    return
  end
  local lg = assert(self._graphics)
  local frameIndex = status.frameIndex
  if frameIndex == nil then
    return
  end
  assert(self._manifest.dialogueFrames.continueCursor)
  local quads = assert(self._cursorQuadCache)[frameIndex]
  local quad = assert(quads)[status.cursorPhase]
  local placement = assert(layout.cursor, "dialogue layout must supply a cursor rectangle")
  lg.setColor(1, 1, 1, 1)
  lg.draw(assert(self._cursorImage), quad, placement.x, placement.y)
end

-- Draws the player's selected HGSS user-frame: the strip row named by the
-- manifest rect for the status frame index, composed by the audited
-- DrawFrameAndWindow2 tilemap around the content box. The content region
-- itself stays uncovered, so the world shows through the window. A status
-- without a frame index (a host that carries no player options) draws no
-- frame at all rather than inventing one.

---@param status FieldDialogueController.Status
---@param layout FieldDialogueRenderer.Layout
function FieldDialogueRenderer:_drawFrame(status, layout)
  local frameIndex = status.frameIndex
  if frameIndex == nil then
    return
  end
  local lg = assert(self._graphics)
  local image = assert(self._frameImage)
  local frames = assert(self._manifest.dialogueFrames)
  local rect = frames.frameTiles[frameIndex]
  assert(rect ~= nil, "dialogue frame index " .. tostring(frameIndex) .. " is outside the generated frame set")
  local quads = self:_buildFrameQuads(frameIndex, rect)
  -- The frame tilemap consumes the theme content-box shape; the resolved
  -- presentation box carries the same source-local geometry.
  local box = { x = layout.box.x, y = layout.box.y, width = layout.box.width, height = layout.box.height }
  lg.setColor(1, 1, 1, 1)
  for _, placement in ipairs(self._theme.frameTilePlacements(box)) do
    local tile = assert(quads[placement.tile])
    for row = 0, (placement.spanY or 1) - 1 do
      for col = 0, (placement.spanX or 1) - 1 do
        lg.draw(image, tile, placement.x + col * 8, placement.y + row * 8)
      end
    end
  end
end

-- Draws the source screen-focus indicator (the YESNO printer control
-- graphic) once, when the reveal has reached a focus_indicator token: the
-- last visible control in source order wins. Placement is window-relative,
-- not a text-cursor advance: the right edge of the content window, without
-- subtracting the text inset. The indicator and the continuation cursor are
-- distinct source concepts and never suppress each other.

---@param status FieldDialogueController.Status
---@param layout FieldDialogueRenderer.Layout
function FieldDialogueRenderer:_drawFocusIndicator(status, layout)
  if not self._focusIndicatorEnabled then
    return
  end
  local lines = status.scrollLines or status.visibleLines
  local tokensByLine = {}
  for _, line in ipairs(lines) do
    tokensByLine[#tokensByLine + 1] = line.tokens or line
  end
  local field = FieldTextRenderer.lastVisibleFocusField(tokensByLine)
  if field ~= nil then
    self._text:drawFocusIndicator(
      field,
      layout.box.x + layout.box.width - FieldFontCache.FOCUS_FRAME_WIDTH,
      layout.box.y
    )
  end
end

-- Draws the dialogue from a resolved host presentation. No-op (and no state
-- touched) when the controller is closed or this renderer is disposed.
-- Restores canvas, shader, scissor, blend, depth, wireframe, cull, and color
-- afterwards so the HUD and host overlays draw normally. The presentation
-- origin/scale bottom-centers the 256x48 strip inside the host bounds; every
-- host resolves it through DialoguePresentationLayout.compute and hands it
-- here, so this renderer owns no host policy or scale derivation.

---@param controller FieldDialogueController
---@param presentation DialoguePresentationLayout.Presentation?
function FieldDialogueRenderer:draw(controller, presentation)
  -- Inactive (closed) is a pure no-op and requires no presentation; an
  -- inactive draw must not touch graphics state or validate parameters.
  -- The presentation is only required for the active path.
  if not controller or not controller:isModal() or not self._frameImage then
    return
  end
  local layout = assert(presentation, "FieldDialogueRenderer:draw requires a resolved dialogue presentation")
  DialoguePresentationLayout.validate(layout)
  local lg = assert(self._graphics)
  local status = controller:status()
  FieldDrawState.protectedDraw(lg, function()
    -- Everything draws in reference-canvas coordinates under one
    -- translate(origin) + scale transform; the theme never returns
    -- screen-mapped rects, so nothing is scaled twice.
    lg.translate(layout.origin.x, layout.origin.y)
    lg.scale(layout.scale, layout.scale)
    local background = self._text:windowBackgroundColor()
    lg.setColor(background[1], background[2], background[3], background[4])
    lg.rectangle("fill", layout.box.x, layout.box.y, layout.box.width, layout.box.height)
    self:_drawFrame(status, layout)
    local lines = status.scrollLines or status.visibleLines
    local scrollOffset = status.scrollLines and status.scrollOffsetY or 0
    local lineY = layout.text.y - scrollOffset
    for _, line in ipairs(lines) do
      local tokens = line.tokens or line
      self._text:drawLine(tokens, layout.text.x, lineY)
      lineY = lineY + status.lineHeight + status.lineSpacing
    end
    self:_drawFocusIndicator(status, layout)
    self:_drawCursor(status, layout)
  end)
end

function FieldDialogueRenderer:release()
  if self._frameImage and self._frameImage.release then
    self._frameImage:release()
  end
  self._frameImage = nil
  if self._cursorImage and self._cursorImage.release then
    self._cursorImage:release()
  end
  self._cursorImage = nil
  self._frameQuadCache = nil
  self._cursorQuadCache = nil
end

return FieldDialogueRenderer
