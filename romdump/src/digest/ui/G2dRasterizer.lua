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
---@alias G2dRasterizer.CellOptions { paletteOverride: integer|nil }

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

-- Render one decoded sprite cell (OBJ list with flips) into raw RGBA pixels.
-- The canvas is the minimal bounding box of the cell's objects, so negative
-- object origins shift the pixels rather than clipping them. Tiles lay out
-- row-major from each object's base tile and the whole-object flips mirror
-- the tile grid as well as each tile, matching OAM 1D-mapping presentation.
---@param charData G2dRasterizer.CharData
---@param paletteData G2dRasterizer.PaletteData
---@param cell { objs: table[] }
---@param source G2dRasterizer.SourceContext|nil diagnostic context forwarded into failures
---@param options G2dRasterizer.CellOptions|nil
---@return { width: integer, height: integer, pixels: string, origin: { x: number, y: number } }
function G2dRasterizer.renderCell(charData, paletteData, cell, source, options)
  assert(charData ~= nil and paletteData ~= nil and cell ~= nil, "cell rasterization requires decoded records")
  if type(cell.objs) ~= "table" or #cell.objs == 0 then
    Errors.raise(G2dRasterizer.ERROR.SOURCE_INVALID, "sprite cell carries no objects", { source = source })
  end
  local first = cell.objs[1]
  local minX, minY = first.x, first.y
  local maxX, maxY = first.x + first.width, first.y + first.height
  for i = 2, #cell.objs do
    local obj = cell.objs[i]
    minX = math.min(minX, obj.x)
    minY = math.min(minY, obj.y)
    maxX = math.max(maxX, obj.x + obj.width)
    maxY = math.max(maxY, obj.y + obj.height)
  end
  local width, height = maxX - minX, maxY - minY
  if width <= 0 or height <= 0 then
    Errors.raise(G2dRasterizer.ERROR.SOURCE_INVALID, "sprite cell has no extent", { source = source })
  end
  local rgba = newRgba(width, height)
  local paletteOverride = options and options.paletteOverride
  if
    paletteOverride ~= nil and (type(paletteOverride) ~= "number" or paletteOverride % 1 ~= 0 or paletteOverride < 0)
  then
    Errors.raise(G2dRasterizer.ERROR.SOURCE_INVALID, "sprite palette override is invalid", {
      palette = paletteOverride,
      source = source,
    })
  end
  for index, obj in ipairs(cell.objs) do
    local tilesPerRow = obj.width / 8
    local rowsPerObj = obj.height / 8
    if tilesPerRow % 1 ~= 0 or rowsPerObj % 1 ~= 0 or tilesPerRow <= 0 or rowsPerObj <= 0 then
      Errors.raise(G2dRasterizer.ERROR.SOURCE_INVALID, "sprite object is not tile-aligned", {
        width = obj.width,
        height = obj.height,
        source = source,
      })
    end
    for tileRow = 0, rowsPerObj - 1 do
      for tileCol = 0, tilesPerRow - 1 do
        local destCol = obj.flipH and (tilesPerRow - 1 - tileCol) or tileCol
        local destRow = obj.flipV and (rowsPerObj - 1 - tileRow) or tileRow
        blitTile(
          rgba,
          width,
          obj.x - minX + destCol * 8,
          obj.y - minY + destRow * 8,
          charData,
          obj.tile + tileRow * tilesPerRow + tileCol,
          paletteOverride or obj.palette,
          paletteData.colors,
          obj.flipH,
          obj.flipV,
          source or { cell = index }
        )
      end
    end
  end
  return { width = width, height = height, pixels = concatChars(rgba), origin = { x = minX, y = minY } }
end

local function transformedPoint(x, y, frame)
  local radians = frame.rotation * math.pi / 180
  local cosTheta, sinTheta = math.cos(radians), math.sin(radians)
  local scaledX, scaledY = x * frame.scaleX, y * frame.scaleY
  return {
    x = scaledX * cosTheta - scaledY * sinTheta + frame.translateX,
    y = scaledX * sinTheta + scaledY * cosTheta + frame.translateY,
  }
end

local function checkTransform(frame, source)
  for _, field in ipairs({ "translateX", "translateY", "scaleX", "scaleY", "rotation" }) do
    local value = frame[field]
    if type(value) ~= "number" or value ~= value or value >= math.huge or value <= -math.huge then
      Errors.raise(G2dRasterizer.ERROR.SOURCE_INVALID, "sprite animation transform is not finite", {
        field = field,
        value = value,
        source = source,
      })
    end
  end
  if frame.scaleX == 0 or frame.scaleY == 0 then
    Errors.raise(G2dRasterizer.ERROR.SOURCE_INVALID, "sprite animation transform has zero scale", { source = source })
  end
end

local function transformPixels(image, frame, source)
  checkTransform(frame, source)
  local sourceOrigin = assert(image.origin, "cell rasterizer returns the source origin")
  local corners = {
    transformedPoint(sourceOrigin.x, sourceOrigin.y, frame),
    transformedPoint(sourceOrigin.x + image.width, sourceOrigin.y, frame),
    transformedPoint(sourceOrigin.x, sourceOrigin.y + image.height, frame),
    transformedPoint(sourceOrigin.x + image.width, sourceOrigin.y + image.height, frame),
  }
  local minX, minY = corners[1].x, corners[1].y
  local maxX, maxY = minX, minY
  for index = 2, #corners do
    local point = corners[index]
    minX, minY = math.min(minX, point.x), math.min(minY, point.y)
    maxX, maxY = math.max(maxX, point.x), math.max(maxY, point.y)
  end
  local originX, originY = math.floor(minX), math.floor(minY)
  local width, height = math.ceil(maxX) - originX, math.ceil(maxY) - originY
  if width <= 0 or height <= 0 then
    Errors.raise(G2dRasterizer.ERROR.SOURCE_INVALID, "sprite animation transform has no extent", { source = source })
  end
  local pixels = newRgba(width, height)
  local radians = frame.rotation * math.pi / 180
  local cosTheta, sinTheta = math.cos(radians), math.sin(radians)
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local worldX, worldY = x + originX + 0.5 - frame.translateX, y + originY + 0.5 - frame.translateY
      local rotatedX = worldX * cosTheta + worldY * sinTheta
      local rotatedY = -worldX * sinTheta + worldY * cosTheta
      local sourceX = rotatedX / frame.scaleX - sourceOrigin.x - 0.5
      local sourceY = rotatedY / frame.scaleY - sourceOrigin.y - 0.5
      local sampleX, sampleY = math.floor(sourceX + 0.5), math.floor(sourceY + 0.5)
      if sampleX >= 0 and sampleX < image.width and sampleY >= 0 and sampleY < image.height then
        local sourceOffset = (sampleY * image.width + sampleX) * 4
        local targetOffset = (y * width + x) * 4
        pixels[targetOffset + 1] = string.byte(image.pixels, sourceOffset + 1)
        pixels[targetOffset + 2] = string.byte(image.pixels, sourceOffset + 2)
        pixels[targetOffset + 3] = string.byte(image.pixels, sourceOffset + 3)
        pixels[targetOffset + 4] = string.byte(image.pixels, sourceOffset + 4)
      end
    end
  end
  return { width = width, height = height, pixels = concatChars(pixels), offset = { x = originX, y = originY } }
end

-- Realize one decoded NANR frame through the shared cell rasterizer. The
-- returned offset keeps a source translation attached to the semantic visual.
---@param charData G2dRasterizer.CharData
---@param paletteData G2dRasterizer.PaletteData
---@param cellData { cells: table[] }
---@param animation { frames: table[] }
---@param frameIndex integer one-based frame index in the decoded sequence
---@param source G2dRasterizer.SourceContext|nil
---@param paletteOverride integer|nil
---@return { width: integer, height: integer, pixels: string, offset: { x: number, y: number } }
function G2dRasterizer.renderAnimationFrame(
  charData,
  paletteData,
  cellData,
  animation,
  frameIndex,
  source,
  paletteOverride
)
  assert(
    charData ~= nil and paletteData ~= nil and cellData ~= nil and animation ~= nil,
    "animation rasterization requires decoded records"
  )
  if type(animation.frames) ~= "table" or type(frameIndex) ~= "number" or frameIndex % 1 ~= 0 then
    Errors.raise(
      G2dRasterizer.ERROR.SOURCE_INVALID,
      "sprite animation frame selection is malformed",
      { source = source }
    )
  end
  local frame = animation.frames[frameIndex]
  if type(frame) ~= "table" or type(frame.cell) ~= "number" or frame.cell % 1 ~= 0 then
    Errors.raise(
      G2dRasterizer.ERROR.SOURCE_INVALID,
      "sprite animation frame is malformed",
      { frame = frameIndex, source = source }
    )
  end
  local cell = cellData.cells[frame.cell + 1]
  if cell == nil then
    Errors.raise(G2dRasterizer.ERROR.SOURCE_INVALID, "sprite animation references a missing cell", {
      cell = frame.cell,
      available = #cellData.cells,
      source = source,
    })
  end
  assert(cell ~= nil, "missing animation cells fail above")
  local image = G2dRasterizer.renderCell(charData, paletteData, cell, source, { paletteOverride = paletteOverride })
  if frame.element == "none" then
    return {
      width = image.width,
      height = image.height,
      pixels = image.pixels,
      offset = { x = image.origin.x, y = image.origin.y },
    }
  end
  if frame.element ~= "translate" and frame.element ~= "affine" then
    Errors.raise(G2dRasterizer.ERROR.SOURCE_INVALID, "sprite animation element is unsupported", {
      element = frame.element,
      source = source,
    })
  end
  return transformPixels(image, frame, source)
end

return G2dRasterizer
