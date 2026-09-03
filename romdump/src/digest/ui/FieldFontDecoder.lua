-- Import-time decoder for the HGSS field font (NARC_graphic_font) members used
-- by the field dialogue: the glyph member (FontHeader + 2bpp tiles + per-glyph
-- width table, per src/font_data.c FontData_Init/TryLoadGlyph) and the palette
-- member (RLCN-wrapped TTLP palette data loaded through
-- NNS_G2dGetUnpackedPaletteData per src/font.c LoadFontPal0). Tile pixel
-- values are 2-bit: 0 = transparent, 1 = foreground, 2 = shadow, 3 = background,
-- converted by GenerateFontHalfRowLookupTable (src/text.c). The runtime only
-- consumes the compiled font definition, never this digester. Pure module: no
-- love dependency.

local BinaryReader = require("libs.codec.src.BinaryReader")
local Errors = require("libs.errors.src.Errors")
local Rgb555 = require("libs.codec.src.Rgb555")

---@class FieldFontDecoder
---@field FALLBACK_GLYPH_INDEX integer
---@field FG_PALETTE_INDEX integer
---@field SHADOW_PALETTE_INDEX integer
---@field BG_PALETTE_INDEX integer
---@field MAX_GLYPHS integer
---@field MAX_PALETTE_BYTES integer
local FieldFontDecoder = {}

-- Glyph index used by TryLoadGlyph for code 0 and codes above numGlyphs.
FieldFontDecoder.FALLBACK_GLYPH_INDEX = 428 - 1
-- Default font colors per sFontInfos[0] in src/font.c.
FieldFontDecoder.FG_PALETTE_INDEX = 1
FieldFontDecoder.SHADOW_PALETTE_INDEX = 2
FieldFontDecoder.BG_PALETTE_INDEX = 0x0F

FieldFontDecoder.MAX_GLYPHS = 0x1000
FieldFontDecoder.MAX_PALETTE_BYTES = 0x200

local TILE_BYTES = 16

-- Decodes the member into a font object with per-glyph accessors. The member
-- keeps its byte string; callers must not mutate it.

---@param data string
---@param opts { label?: string }
---@return FieldFontDecoder.DecodedFont
local function openMember(data, opts)
  opts = opts or {}
  local reader = BinaryReader.new(data, opts.label or "field-font-glyphs")
  local size = reader:length()
  if size < 16 then
    Errors.raise(
      "FONT_FORMAT_INVALID",
      "font glyph member is " .. size .. " bytes, need a 16-byte header",
      { size = size }
    )
  end
  local headerSize = reader:u32le(0)
  local widthDataStart = reader:u32le(4)
  local numGlyphs = reader:u32le(8)
  local fixedWidth = reader:u8(12)
  local fixedHeight = reader:u8(13)
  local glyphWidth = reader:u8(14)
  local glyphHeight = reader:u8(15)

  if headerSize < 16 or headerSize > widthDataStart then
    Errors.raise(
      "FONT_FORMAT_INVALID",
      "font header claims headerSize " .. headerSize .. " and width table at " .. widthDataStart,
      { headerSize = headerSize, widthDataStart = widthDataStart }
    )
  end
  if numGlyphs == 0 or numGlyphs > FieldFontDecoder.MAX_GLYPHS then
    Errors.raise(
      "FONT_FORMAT_INVALID",
      "glyph count " .. numGlyphs .. " outside (0, " .. FieldFontDecoder.MAX_GLYPHS .. "]",
      { numGlyphs = numGlyphs }
    )
  end
  if glyphWidth < 1 or glyphWidth > 2 or glyphHeight < 1 or glyphHeight > 2 then
    Errors.raise(
      "FONT_FORMAT_INVALID",
      "tile shape " .. glyphWidth .. "x" .. glyphHeight .. " is outside the 8x8..16x16 range",
      { glyphWidth = glyphWidth, glyphHeight = glyphHeight }
    )
  end
  local glyphSize = TILE_BYTES * glyphWidth * glyphHeight
  local tilesEnd = headerSize + glyphSize * numGlyphs
  local widthEnd = widthDataStart + numGlyphs
  if tilesEnd > widthDataStart or widthEnd > size then
    Errors.raise(
      "FONT_FORMAT_INVALID",
      "tile region ["
        .. headerSize
        .. ", "
        .. tilesEnd
        .. ") and width table ["
        .. widthDataStart
        .. ", "
        .. widthEnd
        .. ") exceed member size "
        .. size,
      { tilesEnd = tilesEnd, widthDataStart = widthDataStart, widthEnd = widthEnd, size = size }
    )
  end

  local widths = {}
  for index = 0, numGlyphs - 1 do
    widths[index + 1] = reader:u8(widthDataStart + index)
  end

  local font = {}
  font.schema = "g4-field-font-member-v1"
  font.headerSize = headerSize
  font.widthDataStart = widthDataStart
  font.numGlyphs = numGlyphs
  font.fixedWidth = fixedWidth
  font.fixedHeight = fixedHeight
  font.tileColumns = glyphWidth
  font.tileRows = glyphHeight
  font.glyphSize = glyphSize
  font.widths = widths

  -- glyphIndex: 0-based index into the tile region (TryLoadGlyph semantics).
  function font.glyphWidth(glyphIndex)
    if glyphIndex < numGlyphs then
      return widths[glyphIndex + 1]
    end
    return widths[FieldFontDecoder.FALLBACK_GLYPH_INDEX + 1]
  end

  -- Resolves a charcode to its tile index. Codes above numGlyphs resolve to
  -- the fallback glyph (TryLoadGlyph's else branch); code 0 (CHAR_NUL) is
  -- never rendered by the original (GetGlyphWidth asserts on it), so it also
  -- resolves to the fallback here rather than to a negative index.
  function font.glyphIndexForCode(code)
    if code >= 1 and code <= numGlyphs then
      return code - 1
    end
    return FieldFontDecoder.FALLBACK_GLYPH_INDEX
  end

  -- Returns pixel values 0..3 as a glyphHeight*8 x glyphWidth*8 grid (rows of
  -- width glyphWidth*8). Sub-tiles run row-major (TL, TR, BL, BR); each tile
  -- row is two bytes with the SECOND byte holding the left half, and pixel 0
  -- of a byte is its HIGH two bits. The high-bit order follows
  -- DecompressGlyphTile (src/text.c): the half-row lookup table places the
  -- source byte's bits 6-7 into dest bits 0-3, and pixel 0 of a 4bpp group is
  -- the low nibble -- so the leftmost pixel is the byte's most significant
  -- pair. (The DS shadow sits down-right of the ink; low-bit ordering would
  -- mirror each 4-pixel group and put the shadow on the wrong side.)

  ---@param glyphIndex integer
  ---@return FieldFontDecoder.Glyph
  function font.glyphPixels(glyphIndex)
    if glyphIndex >= numGlyphs then
      Errors.raise(
        "FONT_GLYPH_MISSING",
        "glyph index " .. glyphIndex .. " out of range " .. numGlyphs,
        { glyphIndex = glyphIndex, numGlyphs = numGlyphs }
      )
    end
    local offset = headerSize + glyphIndex * glyphSize
    local width = glyphWidth * 8
    local height = glyphHeight * 8
    local pixels = {}
    for tile = 0, glyphWidth * glyphHeight - 1 do
      local tileX = (tile % glyphWidth) * 8
      local tileY = math.floor(tile / glyphWidth) * 8
      local tileOffset = offset + tile * TILE_BYTES
      for row = 0, 7 do
        local left = reader:u8(tileOffset + row * 2 + 1)
        local right = reader:u8(tileOffset + row * 2)
        for p = 0, 3 do
          local y = tileY + row + 1
          pixels[y] = pixels[y] or {}
          pixels[y][tileX + p + 1] = math.floor(left / 2 ^ (6 - p * 2)) % 4
          pixels[y][tileX + 4 + p + 1] = math.floor(right / 2 ^ (6 - p * 2)) % 4
        end
      end
    end
    return { width = width, height = height, values = pixels }
  end

  return font --[[@as FieldFontDecoder.DecodedFont]]
end

-- Decodes an RLCN-wrapped TTLP palette member (16-bit colors). The container
-- layout follows GBATEK's Nitro Color Palette entry and the TTLP chunk of the
-- NNS G2D compressed palette format.

---@param data string
---@param opts { label?: string }
---@return FieldFontDecoder.Palette
local function decodePalette(data, opts)
  opts = opts or {}
  local reader = BinaryReader.new(data, opts.label or "field-font-palette")
  local size = reader:length()
  if size < 0x10 or reader:ascii(0, 4) ~= "RLCN" then
    Errors.raise(
      "FONT_FORMAT_INVALID",
      "palette member lacks the RLCN header",
      { size = size, magic = size >= 4 and reader:ascii(0, 4) or nil }
    )
  end
  if reader:u16le(4) ~= 0xFEFF then
    Errors.raise("FONT_FORMAT_INVALID", "palette RLCN byte order is not 0xFEFF", { byteOrder = reader:u16le(4) })
  end
  local totalSize = reader:u32le(8)
  if totalSize ~= size then
    Errors.raise(
      "FONT_FORMAT_INVALID",
      "palette RLCN declares " .. totalSize .. " bytes but member is " .. size,
      { declared = totalSize, size = size }
    )
  end
  local ttlpOffset = reader:u16le(0x0C)
  local chunkCount = reader:u16le(0x0E)
  if chunkCount < 1 then
    Errors.raise("FONT_FORMAT_INVALID", "palette RLCN declares no chunks", { chunkCount = chunkCount })
  end
  if ttlpOffset + 0x18 > size or reader:ascii(ttlpOffset, 4) ~= "TTLP" then
    Errors.raise(
      "FONT_FORMAT_INVALID",
      "palette RLCN has no valid TTLP chunk at " .. ttlpOffset,
      { ttlpOffset = ttlpOffset, size = size }
    )
  end
  local chunkSize = reader:u32le(ttlpOffset + 4)
  local depth = reader:u32le(ttlpOffset + 8)
  local paletteBytes = reader:u32le(ttlpOffset + 0x10)
  local dataOffset = reader:u32le(ttlpOffset + 0x14)
  -- Single-palette NCLR members (pokegra/otherpoke portrait palettes) carry
  -- depth word 0xA0004 with 16 colors at the standard offset instead of the
  -- bank form's 3. The word is advisory: retail NNS loaders consume both
  -- forms, the color layout and every structural bound below are identical,
  -- and the decoded colors match the addressed graphics. Anything else is
  -- still malformed.
  if depth ~= 3 and depth ~= 4 and depth ~= 0xA0004 then
    Errors.raise(
      "FONT_FORMAT_INVALID",
      "palette depth " .. depth .. " is not 3 (4bpp), 4 (8bpp), or the single-palette form",
      { depth = depth }
    )
  end
  if paletteBytes > FieldFontDecoder.MAX_PALETTE_BYTES then
    Errors.raise(
      "FONT_FORMAT_INVALID",
      "palette size " .. paletteBytes .. " exceeds " .. FieldFontDecoder.MAX_PALETTE_BYTES,
      { paletteBytes = paletteBytes }
    )
  end
  local colorsOffset = ttlpOffset + 8 + dataOffset
  if dataOffset < 8 or colorsOffset + paletteBytes > ttlpOffset + chunkSize or colorsOffset + paletteBytes > size then
    Errors.raise(
      "FONT_FORMAT_INVALID",
      "palette data at " .. colorsOffset .. " exceeds chunk bounds",
      { colorsOffset = colorsOffset, paletteBytes = paletteBytes, chunkEnd = ttlpOffset + chunkSize, size = size }
    )
  end
  local colorCount = math.floor(paletteBytes / 2)
  local colors = {} ---@type { r: integer, g: integer, b: integer }[]
  for i = 0, colorCount - 1 do
    colors[i + 1] = Rgb555.decode(reader:u16le(colorsOffset + i * 2))
  end
  return { colors = colors, colorCount = colorCount, depth = depth }
end

---@param data string
---@param opts { label?: string }
---@return FieldFontDecoder.DecodedFont?
---@return Errors.Error?
function FieldFontDecoder.decodeMember(data, opts)
  assert(type(data) == "string", "FieldFontDecoder.decodeMember requires a string")
  local ok, result = pcall(openMember, data, opts)
  if ok then
    return result, nil
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

---@param data string
---@param opts { label?: string }
---@return FieldFontDecoder.Palette?
---@return Errors.Error?
function FieldFontDecoder.decodePalette(data, opts)
  assert(type(data) == "string", "FieldFontDecoder.decodePalette requires a string")
  local ok, result = pcall(decodePalette, data, opts)
  if ok then
    return result, nil
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

-- The decoded glyph member: header facts plus per-glyph accessors
-- (TryLoadGlyph semantics from src/font_data.c).

---@class FieldFontDecoder.DecodedFont
---@field schema string
---@field headerSize integer
---@field widthDataStart integer
---@field numGlyphs integer
---@field fixedWidth integer
---@field fixedHeight integer
---@field tileColumns integer
---@field tileRows integer
---@field glyphSize integer
---@field widths integer[]
---@field glyphWidth fun(glyphIndex: integer): integer
---@field glyphIndexForCode fun(code: integer): integer
---@field glyphPixels fun(glyphIndex: integer): FieldFontDecoder.Glyph

-- One decoded glyph: a width x height grid of 2-bit pixel values (0..3).

---@class FieldFontDecoder.Glyph
---@field width integer
---@field height integer
---@field values integer[][]

-- The decoded palette member: colors is 1-based (colors[i] = slot i-1).

---@class FieldFontDecoder.Palette
---@field colors { r: integer, g: integer, b: integer }[]
---@field colorCount integer
---@field depth integer

return FieldFontDecoder
