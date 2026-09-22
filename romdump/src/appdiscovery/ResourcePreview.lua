-- Deterministic, source-local previews for decoded NCGR/NCLR resource
-- evidence: an NCGR tile contact sheet and an NCLR swatch grid. Each preview
-- renders exactly one decoded member; no sibling resource is ever consulted.

local Errors = require("libs.errors.src.Errors")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local PngWriter = require("libs.assets.src.PngWriter")

local ResourcePreview = {}

local MAX_TILES_PER_ROW = 16

local function expand5to8(v)
  return math.floor(v * 255 / 31 + 0.5)
end

---@param charData { depth: integer, tiles: string }
---@return { width: integer, height: integer, png: string }
function ResourcePreview.ncgr(charData)
  assert(type(charData) == "table", "ResourcePreview.ncgr requires a decoded NCGR record")
  local depth = charData.depth
  local tileBytes = depth == 3 and 32 or 64
  local rawTileCount = #charData.tiles / tileBytes
  if rawTileCount <= 0 or rawTileCount ~= math.floor(rawTileCount) then
    Errors.raise(
      "APPDISCOVERY_PREVIEW_NCGR_INVALID",
      "NCGR tile data is not a whole multiple of the tile size",
      { tileBytes = #charData.tiles, depth = depth }
    )
  end
  local tileCount = math.floor(rawTileCount)
  ---@cast tileCount integer

  local columns = math.min(tileCount, MAX_TILES_PER_ROW)
  local rows = math.ceil(tileCount / columns)
  ---@cast rows integer
  local totalSlots = columns * rows
  local padCount = totalSlots - tileCount
  local tiles = charData.tiles
  if padCount > 0 then
    tiles = tiles .. string.rep("\0", padCount * tileBytes)
  end

  local entries = {}
  for i = 0, totalSlots - 1 do
    entries[i + 1] = { tile = i, flipH = false, flipV = false, palette = 0 }
  end

  local paletteSize = depth == 3 and 16 or 256
  local colors = {}
  for v = 0, paletteSize - 1 do
    local gray = math.floor(v * 255 / (paletteSize - 1) + 0.5)
    colors[v + 1] = { r = gray, g = gray, b = gray }
  end

  local rendered = G2dRasterizer.renderScreen(
    { depth = depth, tiles = tiles },
    { colors = colors },
    { width = columns * 8, height = rows * 8, entries = entries }
  )
  local png = PngWriter.encode(rendered.width, rendered.height, rendered.pixels)
  return { width = rendered.width, height = rendered.height, png = png }
end

---@param paletteData { colors: { r: integer, g: integer, b: integer }[] }
---@return { width: integer, height: integer, png: string }
function ResourcePreview.nclr(paletteData)
  assert(type(paletteData) == "table", "ResourcePreview.nclr requires a decoded NCLR record")
  local colors = paletteData.colors
  local count = colors and #colors or 0
  if count <= 0 then
    Errors.raise("APPDISCOVERY_PREVIEW_NCLR_EMPTY", "NCLR palette has no colors", {})
  end

  local columns = math.min(count, MAX_TILES_PER_ROW)
  local rows = math.ceil(count / columns)
  local width, height = columns * 8, rows * 8

  local rgba = {}
  for i = 1, width * height * 4 do
    rgba[i] = 0
  end
  for i = 0, count - 1 do
    local c = colors[i + 1]
    local r, g, b = expand5to8(c.r), expand5to8(c.g), expand5to8(c.b)
    local swatchCol = i % columns
    local swatchRow = math.floor(i / columns)
    for y = 0, 7 do
      for x = 0, 7 do
        local px = ((swatchRow * 8 + y) * width + swatchCol * 8 + x) * 4
        rgba[px + 1], rgba[px + 2], rgba[px + 3], rgba[px + 4] = r, g, b, 255
      end
    end
  end

  local parts = {}
  for i = 1, #rgba, 4096 do
    parts[#parts + 1] = string.char(unpack(rgba, i, math.min(i + 4095, #rgba)))
  end
  local pixels = table.concat(parts)

  local png = PngWriter.encode(width, height, pixels)
  return { width = width, height = height, png = png }
end

return ResourcePreview
