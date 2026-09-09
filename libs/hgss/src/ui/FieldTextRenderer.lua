-- Shared presentation collaborator for authentic field text: the generated
-- HGSS field-font definition, its seven-band glyph atlas, its semantic glyph
-- mask atlas, and the focus-indicator strip, plus the color-aware glyph
-- quads (built lazily per color band so plain color-0 UI never materializes
-- variant quads), the mask-atlas quads (built lazily, one cache shared by
-- every palette-driven caller), the token-line and plain-string drawing
-- operations, the palette-driven drawLineWithPalette operation, the
-- caller-variant drawLineWithColorVariants operation, and the
-- drawFocusIndicator operation the dialogue, signpost, and Trainer Card
-- renderers all share. FieldState owns exactly one instance (a renderer
-- never acquires an independent atlas) and injects it; the renderer owns
-- the glyph atlas, the mask atlas, the palette shader, the focus-indicator
-- image, and their quad caches. Glyph ink and shadow colors are baked at
-- import time per band, so drawLine draws at identity tint; control tokens
-- in a line draw nothing and take no width, exactly as the paginator
-- measured them -- the serialized marker spelling is an editing contract,
-- not presentation geometry. Glyph color is part of the prepared token
-- stream (colorIndex), never mutable renderer state; the palette path is
-- separate and deliberately ignores colorIndex, since sign printing sources
-- a fixed foreground/shadow/background triple regardless of any token
-- coloring, while the caller-variant path selects a caller-supplied
-- foreground/shadow pair by each glyph's colorIndex against one constant
-- background. Construction is failure-safe: a missing font atlas, mask atlas,
-- or focus-indicator image is a typed error, and any later image/shader/quad
-- failure releases every resource already created before rethrowing.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local FieldFontLoader = require("libs.hgss.src.ui.FieldFontLoader")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

-- The palette-text shader source is an HGSS UI asset colocated with this
-- module, addressed by repo-relative path like every `require` -- the same
-- convention GxRenderer uses for its own shaders. opts.readSource injects
-- the reader so construction is testable headless without any filesystem.
local PALETTE_SHADER_PATH = "libs/hgss/src/ui/shaders/palette_text.glsl"

---@param path string
---@return string
local function defaultReadSource(path)
  if love and love.filesystem then
    local source = love.filesystem.read(path)
    if source then
      return source
    end
    local base = love.filesystem.getSourceBaseDirectory()
    local f = io.open(base .. "/" .. path, "rb")
    if f then
      local src = f:read("*a")
      f:close()
      return src
    end
  end
  error("cannot read shader source: " .. path)
end

---@class FieldTextRenderer : FieldDialogueRenderer.TextRenderer, FieldSignpostRenderer.TextRenderer
---@field fontDef FieldFontDef
---@field _graphics love.Graphics|love.graphics
---@field _atlas love.Image?
---@field _maskAtlas love.Image?
---@field _paletteShader love.Shader?
---@field _focusImage love.Image?
---@field _quads table<integer, table<integer, love.Quad>>? glyph quads per color band, band 0 built eagerly
---@field _maskQuads table<integer, love.Quad>? mask-atlas glyph quads, built lazily
---@field _focusQuads table<integer, love.Quad>? focus-indicator frame quads, built lazily
local FieldTextRenderer = {}
FieldTextRenderer.__index = FieldTextRenderer

-- opts.cacheFs: version-scoped private cache holding the compiled font def
-- and the atlas/focus PNGs; opts.graphics: injectable LÖVE graphics
-- namespace so tests can record draw calls; opts.readSource: injectable
-- shader-source reader (see defaultReadSource above); LÖVE itself remains an
-- allowed presentation-layer dependency (the atlas bytes still enter through
-- love.filesystem.newFileData).

---@param opts { cacheFs: CacheFs, fontId?: integer, graphics?: unknown, readSource?: fun(path: string): string }
---@return FieldTextRenderer
function FieldTextRenderer.new(opts)
  assert(
    type(opts) == "table" and opts.cacheFs and opts.cacheFs.read,
    "FieldTextRenderer requires a CacheFs-shaped object"
  )
  local fontId = opts.fontId or 0
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.newImage and graphics.newQuad, "FieldTextRenderer requires love.graphics")
  ---@cast graphics love.Graphics|love.graphics
  local readSource = opts.readSource or defaultReadSource
  local fontDef = FieldFontLoader.load(opts.cacheFs, fontId)
  local self = setmetatable({
    fontDef = fontDef,
    _graphics = graphics,
    _atlas = nil,
    _maskAtlas = nil,
    _paletteShader = nil,
    _quads = nil,
    _maskQuads = nil,
    _focusImage = nil,
    _focusQuads = nil,
  }, FieldTextRenderer)
  local atlasPath = FieldFontCache.atlasPath(fontId)
  local data = opts.cacheFs:read(atlasPath)
  if not data then
    Errors.raise(FieldErrors.FONT_ATLAS_MISSING, "font atlas missing at " .. atlasPath, {
      fontId = fontId,
      path = atlasPath,
    })
  end
  data = assert(data)
  local maskAtlasPath = FieldFontCache.maskAtlasPath(fontId)
  local maskData = opts.cacheFs:read(maskAtlasPath)
  if not maskData then
    Errors.raise(FieldErrors.FONT_MASK_ATLAS_MISSING, "font mask atlas missing at " .. maskAtlasPath, {
      fontId = fontId,
      path = maskAtlasPath,
    })
  end
  maskData = assert(maskData)
  local focusPath = FieldFontCache.focusIndicatorsPath(fontId)
  local focusData = opts.cacheFs:read(focusPath)
  if not focusData then
    Errors.raise(FieldErrors.FONT_FOCUS_IMAGE_MISSING, "focus indicator strip missing at " .. focusPath, {
      fontId = fontId,
      path = focusPath,
    })
  end
  focusData = assert(focusData)
  local ok, err = pcall(function()
    self._atlas = graphics.newImage(love.filesystem.newFileData(data, atlasPath))
    self._atlas:setFilter("nearest", "nearest")
    self._maskAtlas = graphics.newImage(love.filesystem.newFileData(maskData, maskAtlasPath))
    self._maskAtlas:setFilter("nearest", "nearest")
    self._paletteShader = graphics.newShader(readSource(PALETTE_SHADER_PATH))
    self:_buildQuads()
    self._focusImage = graphics.newImage(love.filesystem.newFileData(focusData, focusPath))
    self._focusImage:setFilter("nearest", "nearest")
  end)
  if not ok then
    self:release()
    error(err)
  end
  return self
end

-- The base-band glyph quads, built eagerly: every plain drawText and
-- color-0 line starts from this cache, while higher bands stay lazy so
-- ordinary color-0 UI never materializes variant quads.
function FieldTextRenderer:_buildQuads()
  local lg = assert(self._graphics)
  local atlas = assert(self._atlas)
  local width, height = atlas:getWidth(), atlas:getHeight()
  local quads = {}
  for code, glyph in pairs(self.fontDef.glyphs) do
    quads[code] = lg.newQuad(glyph.x, glyph.y, glyph.w, glyph.h, width, height)
  end
  self._quads = { [0] = quads }
end

-- The quad of one glyph in one color band: variant y = glyph.y +
-- colorIndex * colorVariants.strideY, geometry identical across bands.
-- Built lazily per (band, code) pair; an out-of-range color index fails
-- loudly instead of clamping to the base band.
---@param colorIndex integer
---@param code integer
---@return love.Quad
function FieldTextRenderer:_quad(colorIndex, code)
  if
    type(colorIndex) ~= "number"
    or colorIndex % 1 ~= 0
    or colorIndex < 0
    or colorIndex >= FieldMessageText.COLOR_VARIANT_COUNT
  then
    Errors.raise(
      FieldErrors.FONT_COLOR_INDEX_INVALID,
      "glyph color index "
        .. tostring(colorIndex)
        .. " is outside 0.."
        .. tostring(FieldMessageText.COLOR_VARIANT_COUNT - 1),
      { colorIndex = colorIndex }
    )
  end
  local byColor = self._quads[colorIndex]
  if not byColor then
    byColor = {}
    self._quads[colorIndex] = byColor
  end
  local quad = byColor[code]
  if quad then
    return quad
  end
  local lg = assert(self._graphics)
  local atlas = assert(self._atlas)
  local glyph = self.fontDef.glyphs[code] or self.fontDef.glyphs[0]
  quad = lg.newQuad(
    glyph.x,
    glyph.y + colorIndex * self.fontDef.colorVariants.strideY,
    glyph.w,
    glyph.h,
    atlas:getWidth(),
    atlas:getHeight()
  )
  byColor[code] = quad
  return quad
end

-- Draws one page line at the reference-canvas position: glyphs through the
-- atlas band named by the prepared colorIndex at identity tint (the
-- compiled ink/shadow/background colors are baked). Control tokens draw
-- nothing and take no width, matching the paginator's widthless
-- measurement, so following glyphs start exactly where layout placed them
-- and no diagnostic text ever appears in production presentation.

---@param tokens MessageToken[]
---@param x number
---@param y number
function FieldTextRenderer:drawLine(tokens, x, y)
  local lg = assert(self._graphics)
  local atlas = assert(self._atlas)
  local def = self.fontDef
  local letterSpacing = def.letterSpacing or 0
  lg.setColor(1, 1, 1, 1)
  for _, token in ipairs(tokens) do
    if token.kind == "glyph" then
      local quad = self:_quad(token.colorIndex or 0, token.code)
      lg.draw(atlas, quad, x, y)
      local glyph = def.glyphs[token.code] or def.glyphs[0]
      x = x + glyph.advance + letterSpacing
    end
  end
end

-- The mask-atlas quad of one glyph code, built lazily and cached: the mask
-- atlas carries only the base glyph geometry (no color bands), so the same
-- quad serves every palette-driven draw of that code.
---@param code integer
---@return love.Quad
function FieldTextRenderer:_maskQuad(code)
  local quads = self._maskQuads or {}
  local quad = quads[code]
  if quad then
    return quad
  end
  local lg = assert(self._graphics)
  local atlas = assert(self._maskAtlas)
  local glyph = self.fontDef.glyphs[code] or self.fontDef.glyphs[0]
  quad = lg.newQuad(glyph.x, glyph.y, glyph.w, glyph.h, atlas:getWidth(), atlas:getHeight())
  quads[code] = quad
  self._maskQuads = quads
  return quad
end

local function normalizePaletteColor(color)
  local alpha = color.a
  if alpha == nil then
    alpha = 1
  else
    assert(type(alpha) == "number" and alpha == alpha and alpha > -math.huge and alpha < math.huge)
    assert(alpha >= 0 and alpha <= 1)
  end
  return { color.r / 255, color.g / 255, color.b / 255, alpha }
end

-- Draws one line through the palette-driven path: the mask atlas recolored
-- by the shader against the caller's exact foreground/shadow/background
-- triple, at the same glyph advance/letterSpacing geometry as drawLine.
-- Deliberately ignores token.colorIndex -- this path exists precisely
-- because sign printing sources a fixed color triple from the sign's own
-- palette, never the font's baked color bands. Separate from drawLine so
-- ordinary token-color semantics are never overloaded.
---@param tokens MessageToken[]
---@param x number
---@param y number
---@param palette { foreground: {r:number,g:number,b:number,a:number?}, shadow: {r:number,g:number,b:number,a:number?}, background: {r:number,g:number,b:number,a:number?} }
function FieldTextRenderer:drawLineWithPalette(tokens, x, y, palette)
  local lg = assert(self._graphics)
  local atlas = assert(self._maskAtlas)
  local shader = assert(self._paletteShader)
  local def = self.fontDef
  local letterSpacing = def.letterSpacing or 0

  shader:send("u_foreground", normalizePaletteColor(palette.foreground))
  shader:send("u_shadow", normalizePaletteColor(palette.shadow))
  shader:send("u_background", normalizePaletteColor(palette.background))

  lg.setShader(shader)
  lg.setColor(1, 1, 1, 1)
  for _, token in ipairs(tokens) do
    if token.kind == "glyph" then
      local quad = self:_maskQuad(token.code)
      lg.draw(atlas, quad, x, y)
      local glyph = def.glyphs[token.code] or def.glyphs[0]
      x = x + glyph.advance + letterSpacing
    end
  end
  lg.setShader()
end

-- Draws one prepared token line through the caller-supplied color variants:
-- each glyph selects variants[colorIndex + 1] for its foreground/shadow pair
-- while the background stays constant for the line. Geometry (mask-atlas
-- quads, advances, letter spacing, widthless control tokens) matches
-- drawLine exactly; only the palette authority differs. An unknown color
-- index is a programmer fault and fails loudly instead of clamping.
---@param tokens MessageToken[]
---@param x number
---@param y number
---@param variants { foreground: {r:number,g:number,b:number}, shadow: {r:number,g:number,b:number} }[]
---@param background {r:number,g:number,b:number}
function FieldTextRenderer:drawLineWithColorVariants(tokens, x, y, variants, background)
  local lg = assert(self._graphics)
  local atlas = assert(self._maskAtlas)
  local shader = assert(self._paletteShader)
  local def = self.fontDef
  local letterSpacing = def.letterSpacing or 0
  assert(type(variants) == "table", "drawLineWithColorVariants requires the caller color variants")
  assert(type(background) == "table", "drawLineWithColorVariants requires the line background color")

  shader:send("u_background", normalizePaletteColor(background))

  lg.setShader(shader)
  lg.setColor(1, 1, 1, 1)
  local active = nil
  for _, token in ipairs(tokens) do
    if token.kind == "glyph" then
      local colorIndex = token.colorIndex or 0
      if
        type(colorIndex) ~= "number"
        or colorIndex % 1 ~= 0
        or colorIndex < 0
        or colorIndex >= FieldMessageText.COLOR_VARIANT_COUNT
      then
        error("glyph color index " .. tostring(colorIndex) .. " is outside the caller variants", 0)
      end
      local variant = variants[colorIndex + 1]
      if type(variant) ~= "table" then
        error("glyph color index " .. tostring(colorIndex) .. " names no caller variant", 0)
      end
      if variant ~= active then
        shader:send("u_foreground", normalizePaletteColor(variant.foreground))
        shader:send("u_shadow", normalizePaletteColor(variant.shadow))
        active = variant
      end
      local quad = self:_maskQuad(token.code)
      lg.draw(atlas, quad, x, y)
      local glyph = def.glyphs[token.code] or def.glyphs[0]
      x = x + glyph.advance + letterSpacing
    end
  end
  lg.setShader()
end

-- Draws one plain text string at the reference-canvas position (the audited
-- card labels/values path), glyph by glyph at identity tint on the base
-- color band.

---@param text string
---@param x number
---@param y number
function FieldTextRenderer:drawText(text, x, y)
  local lg = assert(self._graphics)
  local atlas = assert(self._atlas)
  local def = self.fontDef
  for char in Utf8Glyphs.iter(text) do
    local code = def.charmap[char]
    if not code then
      code = 0
    end
    local glyph = def.glyphs[code] or def.glyphs[0]
    local quad = self:_quad(0, code)
    lg.draw(atlas, quad, x, y)
    x = x + glyph.advance + (def.letterSpacing or 0)
  end
end

-- Draws a plain UTF-8 string through the semantic mask atlas and caller
-- palette, using the same glyph fallback and advances as drawText.
---@param text string
---@param x number
---@param y number
---@param palette { foreground: {r:number,g:number,b:number,a:number?}, shadow: {r:number,g:number,b:number,a:number?}, background: {r:number,g:number,b:number,a:number?} }
function FieldTextRenderer:drawTextWithPalette(text, x, y, palette)
  local lg = assert(self._graphics)
  local atlas = assert(self._maskAtlas)
  local shader = assert(self._paletteShader)
  local def = self.fontDef

  shader:send("u_foreground", normalizePaletteColor(palette.foreground))
  shader:send("u_shadow", normalizePaletteColor(palette.shadow))
  shader:send("u_background", normalizePaletteColor(palette.background))

  lg.setShader(shader)
  lg.setColor(1, 1, 1, 1)
  for char in Utf8Glyphs.iter(text) do
    local code = def.charmap[char]
    if not code then
      code = 0
    end
    local glyph = def.glyphs[code] or def.glyphs[0]
    lg.draw(atlas, self:_maskQuad(code), x, y)
    x = x + glyph.advance + (def.letterSpacing or 0)
  end
  lg.setShader()
end

-- The measured width of one text string in the generated field font (the
-- source's FontID_String_GetWidth equivalent): the sum of the glyph advances.
---@param text string
---@return number
function FieldTextRenderer:textWidth(text)
  local def = self.fontDef
  local width = 0
  for char in Utf8Glyphs.iter(text) do
    local code = def.charmap[char]
    if not code then
      code = 0
    end
    local glyph = def.glyphs[code] or def.glyphs[0]
    width = width + glyph.advance + (def.letterSpacing or 0)
  end
  return width
end

-- Returns the source field-window fill color (palette slot 15, represented by
-- Lua entry 16). ROM palettes are byte-valued; normalized fixture palettes are
-- accepted so the same semantic accessor remains deterministic in headless UI.
---@return number[]
function FieldTextRenderer:windowBackgroundColor()
  local color = assert(self.fontDef.palette and self.fontDef.palette[16], "field font palette slot 15 is required")
  assert(type(color) == "table", "field font palette slot 15 must be a color")
  local r = assert(tonumber(color.r or color[1]))
  local g = assert(tonumber(color.g or color[2]))
  local b = assert(tonumber(color.b or color[3]))
  assert(r ~= nil and g ~= nil and b ~= nil, "field font palette slot 15 must contain RGB components")
  if r > 1 or g > 1 or b > 1 then
    r, g, b = r / 255, g / 255, b / 255
  end
  return { r, g, b, 1 }
end

-- The field index of the last focus_indicator token visible in source
-- order, or nil when none is visible. The one authoritative last-wins scan
-- the window renderers use: several visible controls draw one frame.
-- Prepared tokens always carry exactly one frame argument.
---@param visibleLines MessageToken[][]
---@return integer?
function FieldTextRenderer.lastVisibleFocusField(visibleLines)
  local field
  for _, line in ipairs(visibleLines) do
    for _, token in ipairs(line) do
      if token.kind == "focus_indicator" then
        field = token.args[1]
      end
    end
  end
  return field
end

-- Draws the source screen-focus indicator frame (the YESNO printer control
-- graphic) at the caller's position: the imported 24x32 frame rect of the
-- requested field at identity tint. The method owns no placement decision --
-- window-specific renderers place the indicator at their content edges. An
-- out-of-range field fails loudly instead of clamping.
---@param field integer
---@param x number
---@param y number
function FieldTextRenderer:drawFocusIndicator(field, x, y)
  if type(field) ~= "number" or field % 1 ~= 0 or field < 0 or field >= FieldMessageText.FOCUS_INDICATOR_COUNT then
    Errors.raise(
      FieldErrors.FONT_FOCUS_FIELD_INVALID,
      "focus indicator field "
        .. tostring(field)
        .. " is outside 0.."
        .. tostring(FieldMessageText.FOCUS_INDICATOR_COUNT - 1),
      { field = field }
    )
  end
  local lg = assert(self._graphics)
  local focusImage = assert(self._focusImage)
  local rect = self.fontDef.focusIndicators.frames[field]
  local quads = self._focusQuads or {}
  local quad = quads[field]
  if quad == nil then
    quad = lg.newQuad(rect.x, rect.y, rect.width, rect.height, focusImage:getWidth(), focusImage:getHeight())
    quads[field] = quad
    self._focusQuads = quads
  end
  lg.setColor(1, 1, 1, 1)
  lg.draw(focusImage, quad, x, y)
end

function FieldTextRenderer:release()
  if self._atlas and self._atlas.release then
    self._atlas:release()
  end
  if self._maskAtlas and self._maskAtlas.release then
    self._maskAtlas:release()
  end
  if self._paletteShader and self._paletteShader.release then
    self._paletteShader:release()
  end
  if self._focusImage and self._focusImage.release then
    self._focusImage:release()
  end
  self._atlas, self._quads = nil, nil
  self._maskAtlas, self._maskQuads = nil, nil
  self._paletteShader = nil
  self._focusImage, self._focusQuads = nil, nil
end

return FieldTextRenderer
