-- Synthetic dialogue-renderer fixtures shared by the dialogue smoke suite and
-- the injected-failure suite: a 16x16 font atlas, its matching 16x16 semantic
-- glyph mask atlas, the 96x32 focus-indicator strip, the cache holding the
-- ready font bundle, an opened controller with a canned layout, and the exact
-- graphics-state restoration contract a draw must honour.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local PngWriter = require("libs.assets.src.PngWriter")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local FieldDialogueController = require("libs.hgss.src.ui.FieldDialogueController")

local FieldDialogueFixture = {}

local MASK_ATLAS_PATH = FieldFontCache.maskAtlasPath(0)

FieldDialogueFixture.FOCUS_INDICATOR_PATH = "assets/generated/field/font/font-0-focus-indicators.png"
FieldDialogueFixture.MASK_ATLAS_PATH = MASK_ATLAS_PATH

local function px(r, g, b, a)
  return string.char(r, g, b, a)
end

-- 16x16 atlas: two 8x16 glyph cells, red 'A' and green 'B'.
---@return string png
function FieldDialogueFixture.atlasBytes()
  local rgba = {}
  for _ = 1, 16 do
    for x = 1, 16 do
      rgba[#rgba + 1] = x <= 8 and px(200, 40, 40, 255) or px(40, 200, 40, 255)
    end
  end
  return PngWriter.encode(16, 16, table.concat(rgba))
end

-- 96x32 focus-indicator strip: four 24x32 frames side by side, each a
-- distinct color so a wrong frame rect is a pixel mismatch. This is the
-- ready font bundle's required third asset; the shared text renderer owns
-- the image after the renderer-integration change.
---@return string png
function FieldDialogueFixture.focusIndicatorBytes()
  local rgba = {}
  for y = 0, 127 do
    for x = 0, 95 do
      local layer, localX = math.floor(x / 24), x % 24
      local localY = y % 32
      local role = (math.floor(localX / 6) + math.floor(localY / 8)) % 4
      local visible = role == layer and (localX < 8 or localX >= 16 or localY < 8 or localY >= 24)
      local alpha = visible and 255 or 0
      rgba[#rgba + 1] = px(255, 255, 255, alpha)
    end
  end
  return PngWriter.encode(96, 128, table.concat(rgba))
end

-- 16x16 mask atlas: the same two 8x16 glyph cells as atlasBytes(), encoding
-- the categorical glyph class instead of a baked color -- glyph 1 (code 1,
-- x=0) all foreground class, glyph 2 (code 2, x=8) all shadow class -- so a
-- palette-driven draw recolors them against the caller's own palette rather
-- than these fixed marker colors.
---@return string png
function FieldDialogueFixture.maskAtlasBytes()
  local rgba = {}
  for _ = 1, 16 do
    for x = 1, 16 do
      rgba[#rgba + 1] = x <= 8 and px(255, 0, 0, 255) or px(0, 255, 0, 255)
    end
  end
  return PngWriter.encode(16, 16, table.concat(rgba))
end

---@return FieldFontDef
function FieldDialogueFixture.fontDef()
  local baseHeight = 16
  return {
    schema = FieldFontCache.SCHEMA,
    fontId = 0,
    maskAtlasPath = MASK_ATLAS_PATH,
    lineHeight = 16,
    maxLetterHeight = 16,
    letterSpacing = 0,
    glyphCount = 2,
    fallbackCode = 0,
    atlasPath = "assets/generated/field/font/font-0.png",
    source = {},
    atlas = {
      width = 16,
      height = baseHeight * FieldMessageText.COLOR_VARIANT_COUNT,
      baseHeight = baseHeight,
      glyphsPerRow = 2,
      glyphWidth = 8,
      glyphHeight = 16,
    },
    colorVariants = {
      count = FieldMessageText.COLOR_VARIANT_COUNT,
      strideY = baseHeight,
    },
    focusIndicators = {
      imagePath = "assets/generated/field/font/font-0-focus-indicators.png",
      count = FieldMessageText.FOCUS_INDICATOR_COUNT,
      width = 24,
      height = 32,
      sourcePaletteSlots = { 11, 12, 13, 14 },
      frames = (function()
        local frames = {}
        for field = 0, FieldMessageText.FOCUS_INDICATOR_COUNT - 1 do
          local layers = {}
          for index, slot in ipairs({ 11, 12, 13, 14 }) do
            layers[slot] = { x = (index - 1) * 24, y = field * 32, width = 24, height = 32 }
          end
          frames[field] = { layers = layers }
        end
        return frames
      end)(),
    },
    glyphs = {
      [1] = { x = 0, y = 0, w = 8, h = 16, advance = 6, bearingX = 0, bearingY = 0 },
      [2] = { x = 8, y = 0, w = 8, h = 16, advance = 6, bearingX = 0, bearingY = 0 },
      [0] = { x = 0, y = 0, w = 8, h = 16, advance = 4, bearingX = 0, bearingY = 0 },
    },
    charmap = { A = 1, B = 2, [" "] = 0 },
    palette = (function()
      local palette = {}
      for slot = 1, 16 do
        palette[slot] = {
          r = math.floor(255 * slot / 16) / 255,
          g = math.floor(255 * slot / 32) / 255,
          b = math.floor(255 * slot / 64) / 255,
        }
      end
      return palette
    end)(),
  }
end

---@return CacheFs
function FieldDialogueFixture.cacheWithFont()
  return FieldDialogueFixture.cacheWithFontId(0)
end

---@param fontId integer
---@return CacheFs
function FieldDialogueFixture.cacheWithFontId(fontId)
  local definition = FieldDialogueFixture.fontDef()
  definition.fontId = fontId
  definition.atlasPath = FieldFontCache.atlasPath(fontId)
  definition.maskAtlasPath = FieldFontCache.maskAtlasPath(fontId)
  definition.focusIndicators.imagePath = FieldFontCache.focusIndicatorsPath(fontId)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(FieldFontCache.defPath(fontId), definition)
  cache:write(FieldFontCache.atlasPath(fontId), FieldDialogueFixture.atlasBytes())
  cache:write(FieldFontCache.maskAtlasPath(fontId), FieldDialogueFixture.maskAtlasBytes())
  cache:write(FieldFontCache.focusIndicatorsPath(fontId), FieldDialogueFixture.focusIndicatorBytes())
  return cache
end

-- The prepared focus_indicator token shape the provider produces: zero-width,
-- carrying the imported field index.
---@param field integer
---@return MessageToken
function FieldDialogueFixture.focusToken(field)
  return { kind = "focus_indicator", control = 0x0200, name = "YESNO", args = { field }, raw = { field } }
end

-- The drawn 24x32 indicator frames in a recorded draw stream: only the focus
-- indicator has that rect in the dialogue/signpost streams (frame and
-- wayfinding tiles are 8x8, glyphs 8x16).
---@param lg table love.graphics-shaped namespace
---@return table[]
function FieldDialogueFixture.focusDraws(lg)
  local out = {}
  for _, call in ipairs(lg.draws) do
    if call.quad and call.quad.w == 24 and call.quad.h == 32 then
      out[#out + 1] = call
    end
  end
  return out
end

-- An opened modal controller whose layout is canned, so the smoke tests
-- exercise the renderer rather than the layout engine.
---@param text string
---@param frameIndex integer|nil optional player-selected user-frame index
---@return FieldDialogueController
function FieldDialogueFixture.openDialogue(text, frameIndex)
  local tokens = {
    { kind = "glyph", code = 1, text = "A", raw = { 1 } },
    { kind = "glyph", code = 2, text = "B", raw = { 2 } },
  }
  local controller = FieldDialogueController.new({
    layout = function()
      return {
        pages = { { lines = { { tokens = tokens, width = 12 } }, breakKind = "eos" } },
        warnings = {},
        lineHeight = 8,
        lineSpacing = 0,
      } --[[@as DialogueLayout.Result]]
    end,
    continueCursor = {
      cycle = { 0, 1, 2, 1 },
      framePrinterTicks = 9,
      placement = { x = 240, y = 168, width = 16, height = 16 },
    },
  })
  local request = {
    id = "smoke",
    message = { bankId = 543, messageId = 5, text = text, tokens = tokens, hadUnresolvedSubstitutions = false },
    allowCancel = false,
  }
  if frameIndex ~= nil then
    request.frameIndex = frameIndex
  end
  controller:open(request)
  return controller
end

-- Every captured state (canvas, shader, blend, depth, wireframe, cull, color,
-- scissor) equals the pre-draw value, never a hard-coded default. The caller
-- sets exactly this state before drawing.
---@param lg table love.graphics-shaped namespace
---@param canvas table
---@param shader table|love.Shader|nil
---@param expectedScissor number[]? caller scissor expected after the draw
function FieldDialogueFixture.assertRestoredState(lg, canvas, shader, expectedScissor)
  Assert.equal(lg.getCanvas(), canvas)
  Assert.equal(lg.getShader(), shader)
  local blend, alpha = lg.getBlendMode()
  Assert.equal(blend, "add")
  Assert.equal(alpha, "alphamultiply")
  local depthMode, depthWrite = lg.getDepthMode()
  Assert.equal(depthMode, "lequal")
  Assert.equal(depthWrite, true)
  Assert.equal(lg.isWireframe(), true)
  Assert.equal(lg.getMeshCullMode(), "back")
  local r, g, b, a = lg.getColor()
  Assert.near(r, 0.2, 1e-6)
  Assert.near(g, 0.4, 1e-6)
  Assert.near(b, 0.6, 1e-6)
  Assert.near(a, 0.8, 1e-6)
  local expected = expectedScissor or { 4, 8, 32, 16 }
  local sx, sy, sw, sh = lg.getScissor()
  Assert.equal(sx, expected[1])
  Assert.equal(sy, expected[2])
  Assert.equal(sw, expected[3])
  Assert.equal(sh, expected[4])
end

return FieldDialogueFixture
