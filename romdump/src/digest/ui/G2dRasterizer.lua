-- Pure rasterization of already-decoded G2D background screens into
-- source-independent RGBA pixels. The mechanics are the tile/screen/palette
-- semantics the field-UI producer has always used, shared verbatim with the
-- chooser info-background producer so a second tilemap raster implementation
-- never appears. Decoded records come from G2dDecoder; this module owns no
-- ROM access, member selection, palette-slot policy, PNG encoding, file
-- publication, or LÖVE objects. The typed failure family is shared with the
-- field-UI producer so its existing diagnostics stay byte-identical.
-- Source basis: GBATEK "Nitro Character Tiles / BG Maps Screens".

local Errors = require("libs.errors.src.Errors")

local G2dRasterizer = {}

-- Named ownership of the shared raster failure code; consumers assert the
-- constant, never the raw string.
G2dRasterizer.ERROR = {
  SOURCE_INVALID = "FIELD_UI_SOURCE_INVALID",
}

---@alias G2dRasterizer.CharData { depth: integer, tiles: string }
---@alias G2dRasterizer.PaletteData { colors: { r: integer, g: integer, b: integer }[] }
---@alias G2dRasterizer.ScreenData { width: integer, height: integer, entries: { tile: integer, flipH: boolean, flipV: boolean, palette: integer }[] }
---@alias G2dRasterizer.SourceContext { asset: string|nil, member: integer|nil, role: string|nil }

local function concatChars(chars)
  -- string.char/unpack are limited by the Lua stack; build in row chunks.
  local out = {}
  for i = 1, #chars, 4096 do
    out[#out + 1] = string.char(unpack(chars, i, math.min(i + 4095, #chars)))
  end
  return table.concat(out)
end

local function newRgba(width, height)
  local rgba = {}
  for i = 1, width * height * 4 do
    rgba[i] = 0
  end
  return rgba
end

-- Blit one tile's pixels into an RGBA buffer. 4bpp tiles hold two pixel
-- values per byte (low nibble first); 8bpp tiles hold one. Pixel value 0 is
-- the reserved transparency slot. Values >= 1 map to palette color `value`
-- within the tile's palette bank — colors is 1-based (colors[i] = color
-- i-1), so the lookup is value + 1. A tile index beyond the decoded tiles,
-- or a palette entry the decoded palette cannot cover, is malformed source,
-- never silent transparency. `source` names the asset/member/cell/obj that
-- produced the reference for the typed error context.
local function blitTile(rgba, atlasWidth, destX, destY, charData, tileIndex, palIndex, colors, flipH, flipV, source)
  local depth = charData.depth
  local tileBytes = depth == 3 and 32 or 64
  local tileCount = math.floor(#charData.tiles / tileBytes)
  if tileIndex < 0 or tileIndex >= tileCount then
    Errors.raise(
      G2dRasterizer.ERROR.SOURCE_INVALID,
      "tile reference exceeds the decoded char data",
      { tile = tileIndex, available = tileCount, source = source }
    )
  end
  local palBase = depth == 3 and palIndex * 16 or palIndex * 256
  local function put(x, y, v)
    if v == 0 then
      return
    end
    local c = colors[palBase + v + 1]
    if not c then
      Errors.raise(
        G2dRasterizer.ERROR.SOURCE_INVALID,
        "pixel references a palette entry the decoded palette cannot cover",
        { value = v, palette = palIndex, available = #colors, source = source }
      )
    end
    if flipH then
      x = 7 - x
    end
    if flipV then
      y = 7 - y
    end
    local px = ((destY + y) * atlasWidth + destX + x) * 4
    rgba[px + 1], rgba[px + 2], rgba[px + 3], rgba[px + 4] = c.r, c.g, c.b, 255
  end
  local base = tileIndex * tileBytes
  if depth == 3 then
    for y = 0, 7 do
      for x = 0, 3 do
        local byte = string.byte(charData.tiles, base + y * 4 + x + 1)
        put(x * 2, y, byte % 16)
        put(x * 2 + 1, y, math.floor(byte / 16))
      end
    end
  else
    for y = 0, 7 do
      for x = 0, 7 do
        put(x, y, string.byte(charData.tiles, base + y * 8 + x + 1))
      end
    end
  end
end

-- Render a decoded screen (BG tilemap with flips) into raw RGBA pixels.
-- The entry count must match the declared dimensions exactly: metadata
-- describing one geometry while supplying another amount of map data is
-- malformed source, never a truncated render.
---@param charData G2dRasterizer.CharData
---@param paletteData G2dRasterizer.PaletteData
---@param screenData G2dRasterizer.ScreenData
---@param source G2dRasterizer.SourceContext|nil diagnostic context forwarded into failures
---@return { width: integer, height: integer, pixels: string }
function G2dRasterizer.renderScreen(charData, paletteData, screenData, source)
  assert(charData ~= nil and paletteData ~= nil and screenData ~= nil, "rasterization requires decoded records")
  local width = screenData.width
  local height = screenData.height
  local columns = width / 8
  local rows = height / 8
  if
    type(width) ~= "number"
    or type(height) ~= "number"
    or width % 8 ~= 0
    or height % 8 ~= 0
    or #screenData.entries ~= columns * rows
  then
    Errors.raise(
      G2dRasterizer.ERROR.SOURCE_INVALID,
      "screen entries do not match the declared screen dimensions",
      { width = width, height = height, entries = #screenData.entries, source = source }
    )
  end
  local rgba = newRgba(width, height)
  for row = 0, rows - 1 do
    for col = 0, columns - 1 do
      local entry = screenData.entries[row * columns + col + 1]
      blitTile(
        rgba,
        width,
        col * 8,
        row * 8,
        charData,
        entry.tile,
        entry.palette,
        paletteData.colors,
        entry.flipH,
        entry.flipV,
        source
      )
    end
  end
  return { width = width, height = height, pixels = concatChars(rgba) }
end

return G2dRasterizer
