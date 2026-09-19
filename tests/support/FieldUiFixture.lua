-- Synthetic field-UI fixtures for the dialogue frame, window style, signpost,
-- and Start Menu surface work: a generated-shape `ui.lua` manifest carrying
-- two dialogue frame strips (18 tiles of 8x8 stacked per frame, like the
-- compiled class), the signpost frame strip and wayfinding atlas (one
-- per-(type,map) row, map 0 and map 1 visibly distinct), the signpost
-- source-type map (the full 25-type corpus set, types 0/1 with per-map
-- wayfinding rects), and the Start Menu surface (background, slot grid,
-- cursor frames), plus cache builders that carry the dialogue font and/or
-- the Start Menu assets. Frame tiles are solid per-tile colors from
-- two distinct palettes (frame 0 blue family, frame 1 cream family, mirroring
-- the real compiled frames' variety) and each Start Menu slot/cursor frame is
-- a distinct color, so a misplacement or wrong rect is a pixel mismatch,
-- never a wash.

local PngWriter = require("libs.assets.src.PngWriter")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")

local FieldUiFixture = {}

FieldUiFixture.STRIP_PATH = "assets/generated/field/ui/dialogue-frame-tiles.png"
FieldUiFixture.CONTINUE_CURSOR_PATH = "assets/generated/field/ui/dialogue-continue-cursor.png"
FieldUiFixture.TILES_PER_FRAME = 18
FieldUiFixture.FRAME_COUNT = 2

FieldUiFixture.SIGNPOST_TILES_PATH = "assets/generated/field/ui/signpost-tiles.png"
FieldUiFixture.WAYFINDING_PATH = "assets/generated/field/ui/wayfinding-tiles.png"

FieldUiFixture.START_MENU_BACKGROUND_PATH = "assets/generated/field/ui/start-menu.png"
FieldUiFixture.START_MENU_CURSOR_PATH = "assets/generated/field/ui/start-menu-cursor.png"
FieldUiFixture.TRAINER_CARD_PATH = "assets/generated/field/ui/trainer-card.png"

-- Every signpost source type the real scr_seq corpus uses (opcodes 55/56),
-- the set pinned by the producer configuration; types 0/1 reserve the
-- wayfinding graphic.
FieldUiFixture.CORPUS_SOURCE_TYPES = {
  0,
  1,
  2,
  3,
  4,
  5,
  8,
  9,
  10,
  11,
  13,
  15,
  16,
  17,
  18,
  19,
  20,
  21,
  23,
  28,
  29,
  30,
  33,
  34,
  39,
}

-- Palette A: blue family. Tile i is a distinct color of the family.
local function paletteA(i)
  return (i * 13) % 256, 140 + (i * 7) % 90, 255 - (i * 11) % 40
end

-- Palette B: cream family, every tile distinct from its frame-0 counterpart.
local function paletteB(i)
  return 255 - (i * 12) % 90, 210 + (i * 3) % 30, 140 + (i * 17) % 90
end

local function tileBytes(i, palette)
  local r, g, b = palette(i)
  return string.rep(string.char(r, g, b, 255), 64)
end

-- The strip atlas: frame rows stacked, each row the 18 tiles of one frame.
---@return string png
function FieldUiFixture.stripBytes()
  local rgba = {}
  for frame = 0, FieldUiFixture.FRAME_COUNT - 1 do
    local palette = frame == 0 and paletteA or paletteB
    for tile = 0, FieldUiFixture.TILES_PER_FRAME - 1 do
      rgba[#rgba + 1] = tileBytes(tile, palette)
    end
  end
  return PngWriter.encode(144, FieldUiFixture.FRAME_COUNT * 8, table.concat(rgba))
end

-- The raw RGBA rows of one frame row (144x8), so tests can compose an
-- independent expected render from the tile bytes.
---@param frame integer
---@return string rgba
function FieldUiFixture.framePixels(frame)
  local palette = frame == 0 and paletteA or paletteB
  local rows = {}
  for tile = 0, FieldUiFixture.TILES_PER_FRAME - 1 do
    rows[#rows + 1] = tileBytes(tile, palette)
  end
  return table.concat(rows)
end

---@return string png
function FieldUiFixture.continueCursorBytes()
  local pixels = {}
  for style = 0, FieldUiFixture.FRAME_COUNT - 1 do
    for _ = 0, 15 do
      for x = 0, 47 do
        local phase = math.floor(x / 16)
        local r = 40 + style * 80 + phase * 30
        pixels[#pixels + 1] = string.char(r, 200 - phase * 30, 80 + style * 50, 255)
      end
    end
  end
  return PngWriter.encode(48, FieldUiFixture.FRAME_COUNT * 16, table.concat(pixels))
end

---@param style integer
---@param phase integer
---@return integer, integer, integer
function FieldUiFixture.continueCursorColor(style, phase)
  return 40 + style * 80 + phase * 30, 200 - phase * 30, 80 + style * 50
end

-- Tile i of the signpost frame strip: a distinct solid color, so a wrong
-- placement (or a divider swap for tile 8) is a pixel mismatch in the
-- goldens.
local function signpostTileColor(i)
  return (40 + i * 12) % 256, (90 + i * 7) % 220, (210 - i * 9) % 180
end

-- Tile t of a wayfinding row: distinct within the row, and every atlas row
-- (one per (type, map) pair) uses a distinct color family so a wrong-row
-- sample is a mismatch.
local function wayfindingTileColor(row, tile)
  return (50 + tile * 9) % 256, (120 + row * 40) % 256, (30 + tile * 11) % 256
end

-- The raw 8x8 RGBA bytes of one signpost frame-strip tile.
---@param tile integer
---@return string rgba
function FieldUiFixture.signpostTilePixels(tile)
  local r, g, b = signpostTileColor(tile)
  return string.rep(string.char(r, g, b, 255), 64)
end

-- The whole signpost frame strip: 18 distinct tiles in one 144x8 row, laid
-- out pixel-row by pixel-row (concatenating 8x8 tile blocks would not match
-- the 144-wide row layout).
---@return string png
function FieldUiFixture.signpostTilesBytes()
  local bytes = {}
  for _ = 0, 7 do
    for x = 0, 143 do
      local r, g, b = signpostTileColor(math.floor(x / 8))
      bytes[#bytes + 1] = string.char(r, g, b, 255)
    end
  end
  return PngWriter.encode(144, 8, table.concat(bytes))
end

-- The raw 8x8 RGBA bytes of one wayfinding 48x32 surface belonging to one
-- (type, map) pair. Each surface is a 6x4 tile grid: tile row*6+col
-- at (col*8, row*8) with a distinct color per row/tile, so a wrong-map
-- sample or a wrong tile offset is a mismatch.
---@param rectY integer top of the 48x32 rect in the atlas
---@return string rgba 48*32*4 bytes
function FieldUiFixture.wayfindingSurfacePixels(rectY)
  local surfaceIndex = math.floor(rectY / 32)
  local bytes = {}
  for y = 0, 31 do
    local tileRow = math.floor(y / 8)
    for x = 0, 47 do
      local tileCol = math.floor(x / 8)
      local tile = tileRow * 6 + tileCol
      local r, g, b = wayfindingTileColor(surfaceIndex, tile)
      bytes[#bytes + 1] = string.char(r, g, b, 255)
    end
  end
  return table.concat(bytes)
end

-- The wayfinding atlas: one 48x32 surface per (type, map) pair, stacked
-- vertically. Type 0 at y=0 (map 0) and y=32 (map 1), type 1 at y=64
-- (map 0) and y=96 (map 1).
---@return string png
function FieldUiFixture.wayfindingBytes()
  return PngWriter.encode(
    48,
    128,
    table.concat({
      FieldUiFixture.wayfindingSurfacePixels(0),
      FieldUiFixture.wayfindingSurfacePixels(32),
      FieldUiFixture.wayfindingSurfacePixels(64),
      FieldUiFixture.wayfindingSurfacePixels(96),
    })
  )
end

-- The canonical Start Menu logical action-slot grid (the manifest's own
-- metadata shape): ten 128x38 rects in two columns of five. The fixture
-- values mirror the compiled class; the runtime renderer must resolve them
-- from the manifest, never hard-code them.
FieldUiFixture.START_MENU_SLOTS = {
  [1] = { x = 0, y = 0, width = 128, height = 38 },
  [2] = { x = 128, y = 0, width = 128, height = 38 },
  [3] = { x = 0, y = 38, width = 128, height = 38 },
  [4] = { x = 128, y = 38, width = 128, height = 38 },
  [5] = { x = 0, y = 76, width = 128, height = 38 },
  [6] = { x = 128, y = 76, width = 128, height = 38 },
  [7] = { x = 0, y = 114, width = 128, height = 38 },
  [8] = { x = 128, y = 114, width = 128, height = 38 },
  [9] = { x = 0, y = 152, width = 128, height = 38 },
  [10] = { x = 128, y = 152, width = 128, height = 38 },
}

-- Two distinct cursor frames in a 16x32 atlas (frame 1 row y=0, frame 2 row
-- y=16) with distinct durations, so the fixed-tick cadence is pixel-visible
-- in the goldens and the durations are observable in unit tests.
FieldUiFixture.START_MENU_CURSOR_FRAMES = {
  { x = 0, y = 0, width = 16, height = 16, duration = 22 },
  { x = 0, y = 16, width = 16, height = 16, duration = 11 },
}

-- The solid color of one Start Menu slot region; every slot is a distinct
-- color so a wrong placement is a pixel mismatch in the goldens.
---@param slotId integer
---@return integer, integer, integer
function FieldUiFixture.startMenuSlotColor(slotId)
  return (10 + slotId * 21) % 256, (90 + slotId * 17) % 200, (220 - slotId * 13) % 240
end

-- The slot containing the pixel (x, y), or nil outside the grid (the two
-- bottom rows of the 256x192 surface are uncovered).
---@param x integer
---@param y integer
---@return integer?
function FieldUiFixture.slotIdAt(x, y)
  for slotId, rect in pairs(FieldUiFixture.START_MENU_SLOTS) do
    if x >= rect.x and x < rect.x + rect.width and y >= rect.y and y < rect.y + rect.height then
      return slotId
    end
  end
  return nil
end

-- The background surface: each slot region is its slot's solid color; the
-- uncovered rows are transparent.
---@return string png
function FieldUiFixture.startMenuBackgroundBytes()
  local bytes = {}
  for y = 0, 191 do
    for x = 0, 255 do
      local slotId = FieldUiFixture.slotIdAt(x, y)
      if slotId then
        local r, g, b = FieldUiFixture.startMenuSlotColor(slotId)
        bytes[#bytes + 1] = string.char(r, g, b, 255)
      else
        bytes[#bytes + 1] = string.char(0, 0, 0, 0)
      end
    end
  end
  return PngWriter.encode(256, 192, table.concat(bytes))
end

-- The solid color of one cursor frame; the two frames are distinct colors.
---@param frame integer 1-based
---@return integer, integer, integer
function FieldUiFixture.startMenuCursorColor(frame)
  if frame == 1 then
    return 255, 0, 255
  end
  return 0, 255, 255
end

-- The cursor atlas: two distinct 16x16 frames stacked (frame 1 at y=0,
-- frame 2 at y=16), so a wrong frame index is a pixel mismatch.
---@return string png
function FieldUiFixture.startMenuCursorBytes()
  local bytes = {}
  for y = 0, 31 do
    local r, g, b = FieldUiFixture.startMenuCursorColor(y < 16 and 1 or 2)
    bytes[#bytes + 1] = string.rep(string.char(r, g, b, 255), 16)
  end
  return PngWriter.encode(16, 32, table.concat(bytes))
end

-- The trainer card front art: a per-tile tinted surface (every 8x8 tile a
-- distinct color so a misplacement is a pixel mismatch), with the bottom 64
-- rows transparent exactly like the compiled class (the DS screen buffer is
-- 32x32 tiles but the visible card fills the 256x192 screen).
---@return string png
function FieldUiFixture.cardBytes()
  local bytes = {}
  for y = 0, 255 do
    for x = 0, 255 do
      if y < 192 then
        local tileX = math.floor(x / 8)
        local tileY = math.floor(y / 8)
        local r = (10 + tileX * 23 + tileY * 7) % 256
        local g = (30 + tileY * 41 + tileX * 5) % 256
        local b = (200 - tileX * 13 - tileY * 17) % 256
        bytes[#bytes + 1] = string.char(r, g, b, 255)
      else
        bytes[#bytes + 1] = string.char(0, 0, 0, 0)
      end
    end
  end
  return PngWriter.encode(256, 256, table.concat(bytes))
end

-- The trainer card label/value charset: the fixture font carries every
-- character the audited front-side labels and values can draw (A-Z, a-z for
-- the "No." label, digits, space, period). Codes 1..64 in the first atlas
-- row; the fallback glyph 0 sits in the second row.
FieldUiFixture.CARD_CHARSET = " ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789."

-- The solid color of card glyph code i: distinct per code, so a wrong glyph
-- (or a wrong anchor) is a pixel mismatch in the goldens.
---@param code integer
---@return integer, integer, integer
function FieldUiFixture.cardGlyphColor(code)
  return (code * 37) % 256, (60 + code * 13) % 200, (200 - code * 11) % 180
end

---@return FieldFontDef
function FieldUiFixture.cardFontDef()
  local glyphs = {}
  for code = 1, #FieldUiFixture.CARD_CHARSET do
    glyphs[code] = { x = (code - 1) * 8, y = 0, w = 8, h = 16, advance = 8, bearingX = 0, bearingY = 0 }
  end
  glyphs[0] = { x = 0, y = 16, w = 8, h = 16, advance = 8, bearingX = 0, bearingY = 0 }
  local charmap = {}
  for index = 1, #FieldUiFixture.CARD_CHARSET do
    charmap[FieldUiFixture.CARD_CHARSET:sub(index, index)] = index
  end
  local baseHeight = 32
  return {
    schema = FieldFontCache.SCHEMA,
    fontId = 0,
    maskAtlasPath = FieldFontCache.maskAtlasPath(0),
    lineHeight = 16,
    maxLetterHeight = 16,
    letterSpacing = 0,
    glyphCount = #FieldUiFixture.CARD_CHARSET,
    fallbackCode = 0,
    atlasPath = "assets/generated/field/font/font-0.png",
    source = {},
    atlas = {
      width = 512,
      height = baseHeight * FieldMessageText.COLOR_VARIANT_COUNT,
      baseHeight = baseHeight,
      glyphsPerRow = 64,
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
      width = FieldFontCache.FOCUS_FRAME_WIDTH,
      height = FieldFontCache.FOCUS_FRAME_HEIGHT,
      frames = {
        [0] = { x = 0, y = 0, width = FieldFontCache.FOCUS_FRAME_WIDTH, height = FieldFontCache.FOCUS_FRAME_HEIGHT },
        [1] = { x = 24, y = 0, width = FieldFontCache.FOCUS_FRAME_WIDTH, height = FieldFontCache.FOCUS_FRAME_HEIGHT },
        [2] = { x = 48, y = 0, width = FieldFontCache.FOCUS_FRAME_WIDTH, height = FieldFontCache.FOCUS_FRAME_HEIGHT },
        [3] = { x = 72, y = 0, width = FieldFontCache.FOCUS_FRAME_WIDTH, height = FieldFontCache.FOCUS_FRAME_HEIGHT },
      },
    },
    glyphs = glyphs,
    charmap = charmap,
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

-- The card font plus one real multibyte glyph: É (U+00C9, a two-byte UTF-8
-- sequence) at compiled code 360 with advance 6, mirroring the generated
-- heartgold field font, so multibyte names exercise the shared text path.
---@return FieldFontDef
function FieldUiFixture.cardFontDefWithMultibyte()
  local def = FieldUiFixture.cardFontDef()
  def.glyphs[360] = { x = (360 - 1) * 8, y = 0, w = 8, h = 16, advance = 6, bearingX = 0, bearingY = 0 }
  def.charmap["\195\137"] = 360
  return def
end

-- The card font atlas: glyph codes 1..64 in the first 512x16 row, the
-- fallback in the second row.
---@return string png
function FieldUiFixture.cardFontAtlasBytes()
  local bytes = {}
  for y = 0, 31 do
    for x = 0, 511 do
      local code = y < 16 and (math.floor(x / 8) + 1) or 0
      local r, g, b = FieldUiFixture.cardGlyphColor(code)
      bytes[#bytes + 1] = string.char(r, g, b, 255)
    end
  end
  return PngWriter.encode(512, 32, table.concat(bytes))
end

-- The card font's semantic glyph mask atlas: the Trainer Card path never
-- draws through the palette-driven text method, so the fixture only needs a
-- valid decodable PNG at the manifest's mask path, not per-glyph class
-- fidelity.
---@return string png
function FieldUiFixture.cardMaskAtlasBytes()
  return PngWriter.encode(16, 16, string.rep(string.char(255, 0, 0, 255), 16 * 16))
end

-- A synthetic 16-color v5 palette bank for one source type: placeholder
-- values distinct per type/slot (not source-decoded), consumed both by the
-- generated manifest fixture below and directly by tests computing the
-- expected palette-driven fill/text colors for a given source type.
---@param sourceType integer
---@return table<integer, {r: integer, g: integer, b: integer}>
function FieldUiFixture.typePalette(sourceType)
  local palette = {}
  for slot = 0, 15 do
    palette[slot] = {
      r = (sourceType * 7 + slot * 13) % 256,
      g = (sourceType * 11 + slot * 5) % 256,
      b = (sourceType * 3 + slot * 17) % 256,
    }
  end
  return palette
end

-- The signpost source-type map in the generated manifest shape: every corpus
-- type with its raw number preserved, its own palette bank and frameTiles
-- rect (every type shares the fixture's single-row 144x8 strip; the atlas
-- shape, not per-type pixel distinctness, is this fixture's contract), and
-- types 0/1 carrying a per-map wayfinding table (map -> 48x32 atlas rect;
-- each pair has its own surface, so the map-0 and map-1 rects are visibly
-- distinct). The on-screen 56px graphic region is NOT the atlas rect; the
-- style loader derives the region from the presence of the table, never its
-- pixels.
---@return table
function FieldUiFixture.signpostTypes()
  local types = {}
  for _, sourceType in ipairs(FieldUiFixture.CORPUS_SOURCE_TYPES) do
    local entry = {
      sourceType = sourceType,
      palette = FieldUiFixture.typePalette(sourceType),
      frameTiles = { x = 0, y = 0, width = 144, height = 8 },
    }
    if sourceType == 0 then
      entry.wayfinding = {
        [0] = { x = 0, y = 0, width = 48, height = 32 },
        [1] = { x = 0, y = 32, width = 48, height = 32 },
      }
    elseif sourceType == 1 then
      entry.wayfinding = {
        [0] = { x = 0, y = 64, width = 48, height = 32 },
        [1] = { x = 0, y = 96, width = 48, height = 32 },
      }
    end
    types[sourceType] = entry
  end
  return types
end

-- The manifest shape the renderer consumes: the asset entry naming the strip
-- and the frame tile rects inside it, plus the signpost frame/wayfinding
-- assets and source-type map.
---@return table
function FieldUiFixture.manifest()
  return {
    schema = FieldUiAssetCache.SCHEMA,
    assets = {
      [FieldUiAssetCache.ASSET.DIALOGUE_FRAME_TILES] = {
        image = FieldUiFixture.STRIP_PATH,
        width = 144,
        height = FieldUiFixture.FRAME_COUNT * 8,
      },
      [FieldUiAssetCache.ASSET.DIALOGUE_CONTINUE_CURSOR] = {
        image = FieldUiFixture.CONTINUE_CURSOR_PATH,
        width = 48,
        height = FieldUiFixture.FRAME_COUNT * 16,
      },
      [FieldUiAssetCache.ASSET.SIGNPOST_TILES] = {
        image = FieldUiFixture.SIGNPOST_TILES_PATH,
        width = 144,
        height = 8,
      },
      [FieldUiAssetCache.ASSET.SIGNPOST_WAYFINDING] = {
        image = FieldUiFixture.WAYFINDING_PATH,
        width = 48,
        height = 128,
      },
      [FieldUiAssetCache.ASSET.START_MENU_BACKGROUND] = {
        image = FieldUiFixture.START_MENU_BACKGROUND_PATH,
        width = 256,
        height = 192,
      },
      [FieldUiAssetCache.ASSET.START_MENU_CURSOR] = {
        image = FieldUiFixture.START_MENU_CURSOR_PATH,
        width = 16,
        height = 32,
      },
      [FieldUiAssetCache.ASSET.TRAINER_CARD_FRONT] = {
        image = FieldUiFixture.TRAINER_CARD_PATH,
        width = 256,
        height = 256,
      },
    },
    dialogueFrames = {
      count = FieldUiFixture.FRAME_COUNT,
      frameTiles = {
        [0] = { x = 0, y = 0, width = 144, height = 8 },
        [1] = { x = 0, y = 8, width = 144, height = 8 },
      },
      continueCursor = {
        asset = FieldUiAssetCache.ASSET.DIALOGUE_CONTINUE_CURSOR,
        cycle = { 0, 1, 2, 1 },
        framePrinterTicks = 9,
        placement = { x = 240, y = 168, width = 16, height = 16 },
        styles = (function()
          local styles = {}
          for style = 0, FieldUiFixture.FRAME_COUNT - 1 do
            styles[style] = {
              phases = {
                [0] = { x = 0, y = style * 16, width = 16, height = 16 },
                [1] = { x = 16, y = style * 16, width = 16, height = 16 },
                [2] = { x = 32, y = style * 16, width = 16, height = 16 },
              },
            }
          end
          return styles
        end)(),
      },
    },
    signposts = {
      textColors = { foreground = 2, shadow = 10, background = 15 },
      types = FieldUiFixture.signpostTypes(),
    },
    startMenu = {
      background = { x = 0, y = 0, width = 256, height = 192 },
      cursor = { frames = FieldUiFixture.START_MENU_CURSOR_FRAMES },
      slots = FieldUiFixture.START_MENU_SLOTS,
    },
    trainerCard = {
      front = { x = 0, y = 0, width = 256, height = 256 },
    },
  }
end

---@return CacheFs
function FieldUiFixture.cacheWithFontAndFrames()
  local cache = FieldDialogueFixture.cacheWithFont()
  cache:writeLua(FieldUiAssetCache.manifestPath(), FieldUiFixture.manifest())
  cache:write(FieldUiFixture.STRIP_PATH, FieldUiFixture.stripBytes())
  cache:write(FieldUiFixture.CONTINUE_CURSOR_PATH, FieldUiFixture.continueCursorBytes())
  cache:write(FieldUiFixture.SIGNPOST_TILES_PATH, FieldUiFixture.signpostTilesBytes())
  cache:write(FieldUiFixture.WAYFINDING_PATH, FieldUiFixture.wayfindingBytes())
  cache:write(FieldUiFixture.START_MENU_BACKGROUND_PATH, FieldUiFixture.startMenuBackgroundBytes())
  cache:write(FieldUiFixture.START_MENU_CURSOR_PATH, FieldUiFixture.startMenuCursorBytes())
  return cache
end

-- The trainer card front viewer fixture: the card font (the full label/value
-- charset, or the caller's own font definition), the field-UI manifest with
-- the trainerCard section, and the synthetic 256x256 card front art.
---@param fontDef FieldFontDef?
---@return CacheFs
function FieldUiFixture.trainerCardCache(fontDef)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua("data/generated/field/font/font-0.lua", fontDef or FieldUiFixture.cardFontDef())
  cache:write("assets/generated/field/font/font-0.png", FieldUiFixture.cardFontAtlasBytes())
  cache:write(FieldFontCache.maskAtlasPath(0), FieldUiFixture.cardMaskAtlasBytes())
  cache:write(FieldDialogueFixture.FOCUS_INDICATOR_PATH, FieldDialogueFixture.focusIndicatorBytes())
  cache:writeLua(FieldUiAssetCache.manifestPath(), FieldUiFixture.manifest())
  cache:write(FieldUiFixture.TRAINER_CARD_PATH, FieldUiFixture.cardBytes())
  return cache
end

-- The same manifest and Start Menu assets without the dialogue font: the
-- Start Menu surface carries its art baked into the background image, so its
-- renderer needs no font atlas.
---@return CacheFs
function FieldUiFixture.startMenuCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(FieldUiAssetCache.manifestPath(), FieldUiFixture.manifest())
  cache:write(FieldUiFixture.START_MENU_BACKGROUND_PATH, FieldUiFixture.startMenuBackgroundBytes())
  cache:write(FieldUiFixture.START_MENU_CURSOR_PATH, FieldUiFixture.startMenuCursorBytes())
  return cache
end

-- Adds the v9 start-menu icon-sprite contract to a fixture manifest in
-- place: the thirteen retail icon rows (sprite cells laid out like the
-- compiled 352x40 shared atlas, the Bag female variant, the trainer-card
-- player-name row, text-only rows 9-10, poke-icon row 11), the shared
-- atlas/highlight/palette asset entries, the seven context rows, the
-- action-to-icon map, sprite bases, label windows, and chrome. Manifests
-- that predate the icon contract (like manifest() above) stay untouched so
-- legacy-surface tests keep proving the background path.
---@param manifest table
---@return table manifest
function FieldUiFixture.addStartMenuIconContract(manifest)
  manifest.assets["hgss.start_menu.icons"] = {
    image = "assets/generated/field/ui/start-menu-icons.png",
    width = 352,
    height = 40,
  }
  manifest.assets["hgss.start_menu.icon_highlight"] = {
    image = "assets/generated/field/ui/start-menu-icons-highlight.png",
    width = 352,
    height = 40,
  }
  manifest.assets["hgss.start_menu.icon_palette"] = {
    image = "assets/generated/field/ui/start-menu-icon-palette.png",
    width = 16,
    height = 2,
  }
  manifest.assets["hgss.start_menu.chrome_sub"] = {
    image = "assets/generated/field/ui/start-menu-chrome-sub.png",
    width = 256,
    height = 256,
  }
  local startMenu = assert(manifest.startMenu, "the fixture manifest must carry the start menu section")
  local iconTable = {}
  local cell = 0
  for icon = 0, 12 do
    if icon == 8 or icon == 9 then
      iconTable[icon + 1] = { art = "text", label = 32, labelKind = "static" }
    elseif icon == 10 then
      iconTable[icon + 1] = { art = "poke_icon", label = 32, labelKind = "static" }
    else
      local labels = { [0] = 0, [1] = 1, [2] = 2, [3] = 14, [4] = 3, [5] = 4, [6] = 5, [7] = 8, [11] = 34, [12] = 35 }
      iconTable[icon + 1] = {
        art = "sprite",
        rect = { x = cell * 32, y = 0, width = 32, height = 40 },
        label = labels[icon],
        labelKind = "static",
      }
      cell = cell + 1
    end
  end
  iconTable[5].labelKind = "player_name"
  iconTable[3].variants = {
    default = iconTable[3].rect,
    female = { x = 10 * 32, y = 0, width = 32, height = 40 },
  }
  startMenu.iconTable = iconTable
  startMenu.iconAtlas = { asset = "hgss.start_menu.icons" }
  startMenu.iconHighlight = { asset = "hgss.start_menu.icon_highlight" }
  startMenu.iconPalette = { asset = "hgss.start_menu.icon_palette", banks = 2, selectionBank = 2 }
  startMenu.contexts = {
    { 0, 1, 2, 3, 4, 5, 6 },
    { 7, 0, 1, 2, 3, 4, 6 },
    { 7, 0, 1, 3, 4, 6, 10 },
    { 7, 0, 1, 3, 4, 6, 9 },
    { 11, 0, 1, 2, 12, 4, 6 },
    { 1, 2, 4, 6, false, false, false },
    { 1, 4, 6, false, false, false, false },
  }
  startMenu.actionIcons = {
    ["vanilla.pokedex"] = 0,
    ["vanilla.pokemon"] = 1,
    ["vanilla.bag"] = 2,
    ["vanilla.pokegear"] = 3,
    ["vanilla.trainer_card"] = 4,
    ["vanilla.save"] = 5,
    ["vanilla.options"] = 6,
  }
  startMenu.iconBases = {
    [2] = { x = 24, y = 22 },
    [3] = { x = 24, y = 62 },
    [4] = { x = 24, y = 102 },
    [5] = { x = 24, y = 142 },
    [6] = { x = 104, y = 22 },
    [7] = { x = 104, y = 62 },
    [8] = { x = 104, y = 102 },
  }
  startMenu.labelWindows = {
    [2] = { x = 8, y = 48, width = 72, height = 16 },
    [3] = { x = 8, y = 88, width = 72, height = 16 },
    [4] = { x = 8, y = 128, width = 72, height = 16 },
    [5] = { x = 8, y = 168, width = 72, height = 16 },
    [6] = { x = 88, y = 48, width = 72, height = 16 },
    [7] = { x = 88, y = 88, width = 72, height = 16 },
    [8] = { x = 88, y = 128, width = 72, height = 16 },
  }
  startMenu.chrome = {
    main = { asset = "hgss.start_menu.background", transparentAboveY = 136 },
    sub = { asset = "hgss.start_menu.chrome_sub" },
  }
  return manifest
end

-- The source-backed naming semantics the reusable renderer consumes: the
-- keyboard/name text layout from the retail keyboard window transform, the
-- control/cursor/slot/player-subject visuals composed from the naming OBJ
-- stack with per-OAM palette selection, and the canonical anchors every
-- visual draws from. Anchors below are the retail source positions the
-- producer transcribes (pret/pokeheartgold src/naming_screen.c): the entered
-- name starts at (80,24) advancing 12px per glyph, entry slots start at
-- (80,39) stepping 12px, controls sit on the home row, the keyboard cursor
-- steps 16px by 19px from (26,91), and the player subject anchors at (24,8).
-- The keyboard text cells deliberately differ from the interaction hit cells
-- so a renderer that centers glyphs in hit rectangles is a mismatch.
---@return table manifest carrying only the assets and namingScreen section
function FieldUiFixture.namingSemanticsManifest()
  local assets = {
    ["hgss.naming_screen.base"] = {
      image = "assets/generated/field/ui/naming-screen-base.png",
      width = 256,
      height = 192,
    },
    ["hgss.naming_screen.page_upper"] = {
      image = "assets/generated/field/ui/naming-screen-page-upper.png",
      width = 256,
      height = 112,
    },
    ["hgss.naming_screen.page_lower"] = {
      image = "assets/generated/field/ui/naming-screen-page-lower.png",
      width = 256,
      height = 112,
    },
    ["hgss.naming_screen.page_symbols"] = {
      image = "assets/generated/field/ui/naming-screen-page-symbols.png",
      width = 256,
      height = 112,
    },
  }
  local function sprite(id, width, height, anchor, offset)
    local path = "assets/generated/field/ui/" .. id .. ".png"
    assets["hgss.naming_screen." .. id] = { image = path, width = width, height = height }
    return {
      asset = "hgss.naming_screen." .. id,
      image = path,
      width = width,
      height = height,
      anchor = anchor,
      offset = offset,
    }
  end
  local cells = {}
  for row = 1, 5 do
    cells[row] = {}
    for column = 1, 13 do
      cells[row][column] = { x = 8 + (column - 1) * 16, y = 92 + (row - 1) * 19, width = 16 }
    end
  end
  return {
    schema = FieldUiAssetCache.SCHEMA,
    reference = { width = 256, height = 192 },
    assets = assets,
    namingScreen = {
      base = { asset = "hgss.naming_screen.base", width = 256, height = 192 },
      pages = {
        upper = { asset = "hgss.naming_screen.page_upper", width = 256, height = 112 },
        lower = { asset = "hgss.naming_screen.page_lower", width = 256, height = 112 },
        symbols = { asset = "hgss.naming_screen.page_symbols", width = 256, height = 112 },
      },
      placement = { x = 0, y = 80, width = 256, height = 112 },
      text = {
        name = { x = 80, y = 24, advanceX = 12 },
        keyboard = { cells = cells },
      },
      controls = {
        upper = sprite("control-upper", 32, 16, { x = 4, y = 68 }, { x = 1, y = 2 }),
        lower = sprite("control-lower", 32, 16, { x = 36, y = 68 }, { x = 0, y = 2 }),
        symbols = sprite("control-symbols", 32, 16, { x = 68, y = 68 }, { x = 0, y = 2 }),
        back = sprite("control-back", 40, 16, { x = 136, y = 68 }, { x = 1, y = 2 }),
        ok = sprite("control-ok", 40, 16, { x = 176, y = 68 }, { x = 0, y = 2 }),
        backing = sprite("control-backing", 216, 32, { x = 22, y = 56 }, { x = 0, y = 0 }),
      },
      cursor = {
        keyboard = (function()
          local record = sprite("cursor-keyboard", 16, 19, { x = 26, y = 91 }, { x = 0, y = 0 })
          record.origin = { x = 26, y = 91 }
          record.stepX = 16
          record.stepY = 19
          return record
        end)(),
        home = {
          upper = sprite("cursor-home-upper", 32, 16, { x = 4, y = 68 }, { x = 0, y = 1 }),
          lower = sprite("cursor-home-lower", 32, 16, { x = 36, y = 68 }, { x = 0, y = 1 }),
          symbols = sprite("cursor-home-symbols", 32, 16, { x = 68, y = 68 }, { x = 0, y = 1 }),
          back = sprite("cursor-home-back", 40, 16, { x = 136, y = 68 }, { x = 0, y = 1 }),
          ok = sprite("cursor-home-ok", 40, 16, { x = 176, y = 68 }, { x = 0, y = 1 }),
        },
      },
      entrySlots = {
        origin = { x = 80, y = 39 },
        stepX = 12,
        normal = sprite("slot-normal", 12, 16, { x = 80, y = 39 }, { x = 0, y = 0 }),
        selected = sprite("slot-selected", 12, 16, { x = 80, y = 39 }, { x = 0, y = 0 }),
      },
      playerSubjects = {
        male = sprite("subject-male", 48, 56, { x = 24, y = 8 }, { x = 0, y = 0 }),
        female = sprite("subject-female", 48, 56, { x = 24, y = 8 }, { x = 2, y = 0 }),
      },
    },
  }
end

-- Grafts the source-backed naming semantics (generated visual assets plus
-- the full text/control/cursor/slot/subject section) onto a fixture
-- manifest that already carries the Start Menu icon contract. Validator
-- fixtures whose subject is another section use this to satisfy the required
-- naming contract without restating it.
---@param manifest table
---@return table manifest
function FieldUiFixture.addNamingSemantics(manifest)
  local semantics = FieldUiFixture.namingSemanticsManifest()
  for id, entry in pairs(semantics.assets) do
    manifest.assets[id] = entry
  end
  manifest.namingScreen = semantics.namingScreen
  return manifest
end

return FieldUiFixture
