-- Renders the signpost controller snapshot into the viewport's centered 4:3
-- reference frame: the source window pixel buffer filled with the active
-- source type's own palette slot 15 (FillWindowPixelBuffer(window, 15)), the
-- HGSS signpost frame strip drawn by the audited DrawFrameAndWindow3 tilemap
-- (source types 0/1 additionally blit the precomposed 48x32 wayfinding
-- surface and the divider tile 8), the shared FieldTextRenderer glyph text
-- drawn through the palette-driven path against the source's fixed
-- MAKE_TEXT_COLOR(2, 10, 15) slots of that same source-type palette (never
-- the field font's own baked default color bands, and never a type-0
-- fallback), all translated by the logical wipe offset -- the whole signpost
-- BG layer slides, and the hidden -48 position sits below the screen. Per
-- type geometry comes from the window style catalogue; the strip, wayfinding
-- atlas, and per-type palette banks are the generated field-UI manifest
-- assets, with the wayfinding surface selected by the appearance's exact
-- (type, map) pair. Visibility is keyed on status().active, never on
-- logicalYOffset alone, so the wipe-out endpoint-check reset can never flash
-- the cleared window at the reset position. Interpolation between the
-- previous and the current fixed-tick offset uses the session render alpha,
-- clamped into [0, 1], and is a pure function of the controller's paired
-- wipe history: the renderer holds no interpolation state and never calls
-- back into the controller. Resolved style records are the catalogue's
-- stored records (never copies), so each draw resolves fresh without
-- caching. Construction is failure-safe: a missing strip or wayfinding atlas
-- is a typed error, a quad failure after the images were created releases
-- them before rethrowing, and draw() restores every graphics state it
-- touched. The runtime-validated manifest is injected explicitly; this
-- renderer never reloads it from the cache.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldSignpostTheme = require("libs.hgss.src.ui.FieldSignpostTheme")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldDrawState = require("libs.hgss.src.presentation.FieldDrawState")

-- The frame/palette bank used when a window is shown without a source
-- appearance (a bare SHOW): a degenerate script state the engine's own
-- machinery can reach even though no real signpost print leaves the type
-- unset. Every generated manifest carries type 0 (the corpus's baseline
-- full-width type), so this is always resolvable.
local DEFAULT_SOURCE_TYPE = 0

-- Sets the draw color from a generated 0..255 palette entry, at the given
-- alpha (defaulting to opaque).
---@param color { r: integer, g: integer, b: integer }
---@param alpha number?
---@param lg love.Graphics|love.graphics
local function setColor255(lg, color, alpha)
  lg.setColor(color.r / 255, color.g / 255, color.b / 255, alpha or 1)
end

---@class FieldSignpostRenderer
---@field _graphics love.Graphics|love.graphics
---@field _windowStyles FieldSignpostRenderer.WindowStyles
---@field _text FieldSignpostRenderer.TextRenderer the shared glyph atlas/line drawing collaborator
---@field _manifest table<string, unknown> the generated field-UI manifest
---@field _tilesImage love.Image? the signpost frame strip
---@field _wayfindingImage love.Image? the wayfinding atlas
---@field _frameQuadCache table<integer, love.Quad[]>|nil per-source-type frame quads, built lazily
---@field _wayfindingQuadCache table<string, love.Quad>|nil per-(type,map) final-surface quad, built lazily
local FieldSignpostRenderer = {}
FieldSignpostRenderer.__index = FieldSignpostRenderer

---@class FieldSignpostRenderer.WindowStyles
---@field resolve fun(self: FieldSignpostRenderer.WindowStyles, styleId: string): table<string, unknown>?
---@class FieldSignpostRenderer.TextRenderer
---@field fontDef FieldFontDef
---@field _atlas love.Image?
---@field drawLineWithPalette fun(self: FieldSignpostRenderer.TextRenderer, line: table<string, unknown>, x: number, y: number, palette: table<string, unknown>)
---@field drawFocusIndicator fun(self: FieldSignpostRenderer.TextRenderer, field: integer, x: number, y: number)

-- opts.cacheFs: version-scoped private cache holding the generated field-UI
-- class; opts.manifest: the already-validated generated field-UI manifest
-- the runtime loaded once (FieldRuntime.uiManifest); opts.text: the shared
-- FieldTextRenderer (FieldState owns exactly one); opts.graphics: injectable
-- LÖVE graphics namespace so tests can record draw calls (LÖVE itself
-- remains an allowed presentation-layer dependency: the PNG bytes still
-- enter through love.filesystem.newFileData); opts.windowStyles: the
-- per-runtime window style catalogue the controller's styleId resolves in.

---@param opts { cacheFs: CacheFs, manifest: table<string, unknown>, text: unknown, windowStyles: unknown, graphics?: unknown }
---@return FieldSignpostRenderer
function FieldSignpostRenderer.new(opts)
  assert(
    type(opts) == "table" and opts.cacheFs and opts.cacheFs.read,
    "FieldSignpostRenderer requires a CacheFs-shaped object"
  )
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.newImage and graphics.newQuad, "FieldSignpostRenderer requires love.graphics")
  ---@cast graphics love.Graphics|love.graphics
  local windowStyles = opts.windowStyles
  assert(
    windowStyles and type(windowStyles.resolve) == "function",
    "FieldSignpostRenderer requires a window style catalogue"
  )
  ---@cast windowStyles FieldSignpostRenderer.WindowStyles
  local text = opts.text
  assert(
    text and type(text.drawLineWithPalette) == "function" and type(text.drawFocusIndicator) == "function",
    "FieldSignpostRenderer requires the shared FieldTextRenderer"
  )
  ---@cast text FieldSignpostRenderer.TextRenderer
  local cacheFs = opts.cacheFs
  local manifest = opts.manifest
  assert(type(manifest) == "table", "FieldSignpostRenderer requires the runtime-validated field-UI manifest")

  -- The generated field-UI class is a required renderer asset: the manifest
  -- names the signpost strip, the wayfinding atlas, and the strip's tile
  -- rect. The runtime boot already validated the full manifest; the renderer
  -- resolves what it draws.
  local tilesAsset = assert(
    manifest.assets[FieldUiAssetCache.ASSET.SIGNPOST_TILES],
    "the field-UI manifest must carry the signpost tiles asset"
  )
  local wayfindingAsset = assert(
    manifest.assets[FieldUiAssetCache.ASSET.SIGNPOST_WAYFINDING],
    "the field-UI manifest must carry the signpost wayfinding asset"
  )
  local tilesPath = assert(tilesAsset.image, "the signpost tiles asset must name an image path")
  local wayfindingPath = assert(wayfindingAsset.image, "the wayfinding asset must name an image path")
  assert(
    type(manifest.signposts) == "table" and type(manifest.signposts.types) == "table",
    "the field-UI manifest must carry the signpost type map"
  )

  local self = setmetatable({
    _graphics = graphics,
    _windowStyles = windowStyles,
    _text = text,
    _manifest = manifest,
    _tilesImage = nil,
    _wayfindingImage = nil,
    _frameQuadCache = nil,
    _wayfindingQuadCache = nil,
  }, FieldSignpostRenderer)

  local tilesData = cacheFs:read(tilesPath)
  if not tilesData then
    self:release()
    Errors.raise(FieldErrors.FIELD_UI_SIGNPOST_TILES_MISSING, "signpost frame strip missing at " .. tilesPath, {
      path = tilesPath,
    })
  end
  local wayfindingData = cacheFs:read(wayfindingPath)
  if not wayfindingData then
    self:release()
    Errors.raise(FieldErrors.FIELD_UI_WAYFINDING_MISSING, "wayfinding atlas missing at " .. wayfindingPath, {
      path = wayfindingPath,
    })
  end
  local ok, err = pcall(function()
    self._tilesImage = graphics.newImage(love.filesystem.newFileData(assert(tilesData), tilesPath))
    self._tilesImage:setFilter("nearest", "nearest")
    self._wayfindingImage = graphics.newImage(love.filesystem.newFileData(assert(wayfindingData), wayfindingPath))
    self._wayfindingImage:setFilter("nearest", "nearest")
  end)
  if not ok then
    self:release()
    error(err)
  end
  return self
end

-- The 18 frame-strip tile quads of one source type's row (the manifest's
-- per-type `frameTiles` rect). Built lazily per type and cached, exactly like
-- the wayfinding row cache below: a session that only ever shows one source
-- type never materializes the others' quads.
---@param sourceType integer
---@param rect { x: integer, y: integer, width: integer, height: integer }
---@return love.Quad[]
function FieldSignpostRenderer:_frameQuads(sourceType, rect)
  local cache = self._frameQuadCache or {}
  local quads = cache[sourceType]
  if quads == nil then
    local lg = assert(self._graphics)
    local image = assert(self._tilesImage)
    quads = {}
    for tile = 0, rect.width / 8 - 1 do
      quads[tile] = lg.newQuad(rect.x + tile * 8, rect.y, 8, 8, image:getWidth(), image:getHeight())
    end
    cache[sourceType] = quads
  end
  self._frameQuadCache = cache
  return quads
end

-- One quad for the precomposed 48x32 wayfinding surface of one
-- (type, map) pair. Built lazily per pair and cached, so a session that
-- only ever shows full-width signs never materializes the surface.
---@param key string the "type.map" pair
---@param rect { x: integer, y: integer, width: integer, height: integer }
---@return love.Quad
function FieldSignpostRenderer:_wayfindingQuad(key, rect)
  local cache = self._wayfindingQuadCache or {}
  local quad = cache[key]
  if quad == nil then
    local lg = assert(self._graphics)
    local image = assert(self._wayfindingImage)
    quad = lg.newQuad(rect.x, rect.y, rect.width, rect.height, image:getWidth(), image:getHeight())
    cache[key] = quad
  end
  self._wayfindingQuadCache = cache
  return quad
end

-- The wipe translation for this render: the current fixed-tick offset,
-- interpolated from the previous fixed-tick offset by the session render
-- alpha (clamped into [0, 1]). Pure: only the status pair is read, the
-- renderer holds no interpolation state, and the controller is never called
-- back, so repeated draws under the same status hit the same positions.
---@param status FieldSignpostController.Status
---@param alpha number?
---@return number
function FieldSignpostRenderer:_wipeY(status, alpha)
  local a = math.min(math.max(alpha or 1, 0), 1)
  local previous = status.previousLogicalYOffset
  local current = status.logicalYOffset
  return FieldSignpostTheme.wipeY(previous + (current - previous) * a)
end

-- The active source type's generated manifest entry (palette + frameTiles +
-- optional wayfinding): a bare SHOW without a source appearance resolves the
-- baseline DEFAULT_SOURCE_TYPE, exactly like the style-geometry fallback. No
-- fallback to type 0 ever happens for a real appearance whose type the
-- manifest cannot resolve -- that is a manifest/source-contract failure.
---@param status FieldSignpostController.Status
---@return table<string, unknown>
function FieldSignpostRenderer:_resolveType(status)
  local types =
    assert(self._manifest.signposts and self._manifest.signposts.types, "the manifest must carry signpost types")
  local appearance = status.sourceAppearance
  local sourceType = appearance and appearance.type or DEFAULT_SOURCE_TYPE
  return assert(types[sourceType], "the generated manifest has no signpost type " .. tostring(sourceType))
end

-- Draws the signpost frame strip by the audited tilemap, and for source
-- types with a graphic region the precomposed 48x32 wayfinding surface
-- plus the divider tile. The whole surface is translated by the wipe.

---@param status FieldSignpostController.Status
---@param graphicRegion FieldDialogueTheme.Rect? the type's wayfinding region
---@param wipe number
---@param typeEntry table<string, unknown> the active source type's generated manifest entry
function FieldSignpostRenderer:_drawFrame(status, graphicRegion, wipe, typeEntry)
  local lg = assert(self._graphics)
  local image = assert(self._tilesImage)
  local types =
    assert(self._manifest.signposts and self._manifest.signposts.types, "the manifest must carry signpost types")
  local appearance = status.sourceAppearance
  local sourceType = typeEntry.sourceType
  local frameQuads = self:_frameQuads(
    sourceType,
    assert(typeEntry.frameTiles, "signpost type " .. sourceType .. " carries no frameTiles")
  )
  lg.setColor(1, 1, 1, 1)
  local kind = graphicRegion and "graphic" or "full"
  for _, placement in ipairs(FieldSignpostTheme.frameTilePlacements(kind)) do
    local tile = assert(frameQuads[placement.tile])
    for row = 0, (placement.spanY or 1) - 1 do
      for col = 0, (placement.spanX or 1) - 1 do
        lg.draw(image, tile, placement.x + col * 8, placement.y + row * 8 + wipe)
      end
    end
  end
  if graphicRegion then
    -- graphicRegion only ever comes from style.types[appearance.type], so a
    -- real source appearance is guaranteed here.
    assert(appearance)
    -- The exact (type, map) pair selects the manifest rect; a type requiring
    -- graphic art without a manifest rect for its pair is a
    -- manifest/source-contract failure, never a fallback to another map's rect.
    local manifestRect = types[appearance.type]
      and types[appearance.type].wayfinding
      and types[appearance.type].wayfinding[appearance.map]
    assert(
      manifestRect ~= nil,
      "the generated manifest must index the wayfinding row for signpost (type, map) "
        .. tostring(appearance.type)
        .. ","
        .. tostring(appearance.map)
    )
    local wayfinding = assert(self._wayfindingImage)
    local key = appearance.type .. ":" .. appearance.map
    local quad = self:_wayfindingQuad(key, manifestRect)
    lg.draw(wayfinding, quad, graphicRegion.x, graphicRegion.y + wipe)
  end
end

-- Draws the signpost fitted inside the real world viewport, mirroring the
-- dialogue fit: the field logical pixel scale caps, never forces, the drawn
-- scale, and the shrunken 256x192 surface stays bottom-centered. No-op (and
-- no state touched) when the controller is inactive or this renderer is
-- disposed. Restores canvas, shader, scissor, blend, depth, wireframe, cull,
-- and color afterwards so the HUD and host overlays draw normally. The wipe
-- offset stays in logical pixels so it naturally scales with the surface.

---@param controller FieldSignpostController
---@param viewport { referenceFrame: FieldDialogueTheme.Rect, worldViewport?: FieldDialogueTheme.Rect }
---@param alpha number? session render interpolation factor, clamped into [0, 1]
---@param fieldScale number field logical pixel scale (viewport:logicalPixelScale(camera.zoom))
function FieldSignpostRenderer:draw(controller, viewport, alpha, fieldScale)
  if not controller or not self._tilesImage then
    return
  end
  -- Inactive is a pure no-op and checks no scale precondition: the wipe-out
  -- endpoint reset holds logicalYOffset 0 and must not touch graphics state.
  local status = controller:status()
  if not status.active then
    return
  end
  assert(
    type(fieldScale) == "number"
      and fieldScale > 0
      and fieldScale == fieldScale
      and fieldScale ~= math.huge
      and fieldScale ~= -math.huge,
    "FieldSignpostRenderer:draw requires a finite positive field scale"
  )
  local lg = assert(self._graphics)
  FieldDrawState.protectedDraw(lg, function()
    -- Everything draws in reference-canvas coordinates under one
    -- translate(origin) + scale transform; the per-type geometry from the
    -- style catalogue is already reference-space, so nothing is scaled twice.
    -- The real world viewport bounds the 256x192 surface: roomy hosts keep
    -- the exact field scale, small hosts shrink to fit, always
    -- bottom-centered like the dialogue strip.
    local bounds = viewport.worldViewport
    if type(bounds) ~= "table" or type(bounds.width) ~= "number" or type(bounds.height) ~= "number" then
      bounds = viewport.referenceFrame
    end
    bounds = assert(bounds, "FieldSignpostRenderer:draw requires viewport bounds")
    local scale = math.min(fieldScale, bounds.width / 256, bounds.height / 192)
    assert(scale > 0, "FieldSignpostRenderer:draw signpost does not fit its bounds")
    local layout = {
      scale = scale,
      origin = {
        x = bounds.x + (bounds.width - 256 * scale) / 2,
        y = bounds.y + bounds.height - 192 * scale,
      },
    }
    lg.translate(layout.origin.x, layout.origin.y)
    lg.scale(layout.scale, layout.scale)
    local wipe = self:_wipeY(status, alpha)
    -- resolve() returns the catalogue's stored record (never a copy), so the
    -- style is resolved fresh on every draw without caching.
    local style =
      assert(self._windowStyles:resolve(status.styleId), "unknown window style " .. tostring(status.styleId))
    local appearance = status.sourceAppearance
    local typeRecord = appearance and style.types and style.types[appearance.type]
    local contentGeometry = (typeRecord and typeRecord.contentGeometry) or style.contentGeometry
    assert(contentGeometry ~= nil, "window style " .. tostring(status.styleId) .. " carries no content geometry")

    -- The active source type's own palette (never the field font's baked
    -- default), resolved once and shared by the interior fill and the
    -- palette-driven text below.
    local typeEntry = self:_resolveType(status)
    local textColors = assert(self._manifest.signposts.textColors, "the manifest must carry signposts.textColors")
    local background = assert(typeEntry.palette[textColors.background], "signpost type has no background slot")

    -- The source window pixel buffer is filled with the sign's own palette
    -- slot 15 before anything else draws (DialogBox_DrawFrameWithWayfindingGraphic:
    -- FillWindowPixelBuffer(window, 15)); contentGeometry already excludes the
    -- left wayfinding graphic region for source types 0/1, so the fill never
    -- overwrites it.
    setColor255(lg, background, 1)
    lg.rectangle("fill", contentGeometry.x, contentGeometry.y + wipe, contentGeometry.width, contentGeometry.height)

    self:_drawFrame(status, typeRecord and typeRecord.graphicRegion, wipe, typeEntry)

    -- Sign text sources MAKE_TEXT_COLOR(2, 10, 15) against the active sign
    -- palette, never the field font's own baked color bands.
    local textPalette = {
      foreground = assert(typeEntry.palette[textColors.foreground], "signpost type has no foreground slot"),
      shadow = assert(typeEntry.palette[textColors.shadow], "signpost type has no shadow slot"),
      background = background,
    }
    local lineY = contentGeometry.y + wipe
    for _, tokens in ipairs(status.visibleLines) do
      self._text:drawLineWithPalette(tokens, contentGeometry.x, lineY, textPalette)
      lineY = lineY + FieldSignpostTheme.LINE_HEIGHT
    end
    self:_drawFocusIndicator(status, contentGeometry, wipe)
  end)
end

-- Draws the source screen-focus indicator (the YESNO printer control
-- graphic) once, when the visible print lines carry a focus_indicator
-- token: the last visible control in source order wins. The same shared
-- presentation as the dialogue, placed against this window's own content
-- rectangle (never dialogue box geometry) and translated by the wipe like
-- the rest of the signpost BG surface.

---@param status FieldSignpostController.Status
---@param contentGeometry FieldDialogueTheme.Rect
---@param wipe number
function FieldSignpostRenderer:_drawFocusIndicator(status, contentGeometry, wipe)
  local field = FieldTextRenderer.lastVisibleFocusField(status.visibleLines)
  if field ~= nil then
    self._text:drawFocusIndicator(
      field,
      contentGeometry.x + contentGeometry.width - FieldFontCache.FOCUS_FRAME_WIDTH,
      contentGeometry.y + wipe
    )
  end
end

function FieldSignpostRenderer:release()
  if self._tilesImage and self._tilesImage.release then
    self._tilesImage:release()
  end
  if self._wayfindingImage and self._wayfindingImage.release then
    self._wayfindingImage:release()
  end
  self._tilesImage, self._wayfindingImage = nil, nil
  self._frameQuadCache, self._wayfindingQuadCache = nil, nil
end

return FieldSignpostRenderer
