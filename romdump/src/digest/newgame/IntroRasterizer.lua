-- Rasterizes decoded intro character, screen, cell, and animation resources.

local Errors = require("libs.errors.src.Errors")

local IntroRasterizer = {}
local SOURCE_INVALID = "INTRO_SOURCE_INVALID"

local function sourceError(message, context)
  Errors.raise(SOURCE_INVALID, message, context or {})
end

local function byteAt(bytes, offset)
  return string.byte(bytes, offset --[[@as integer]])
end

local function newRgba(width, height)
  local rgba = {}
  for index = 1, width * height * 4 do
    rgba[index] = 0
  end
  return rgba
end

local function concatBytes(bytes)
  local out = {}
  for index = 1, #bytes, 4096 do
    out[#out + 1] = string.char(unpack(bytes, index, math.min(index + 4095, #bytes)))
  end
  return table.concat(out)
end

local function blitTile(rgba, width, char, x, y, tileIndex, palette, paletteBank, flipH, flipV)
  local tileBytes = char.depth == 3 and 32 or 64
  local tileCount = #char.tiles / tileBytes
  if tileIndex < 0 or tileIndex >= tileCount then
    sourceError("intro tile reference exceeds source char data", {
      tile = tileIndex,
      available = tileCount,
      sourceOffset = tileIndex * tileBytes,
    })
  end
  local function put(px, py, value)
    if value == 0 then
      return
    end
    local paletteIndex = value + 1
    if char.depth == 3 then
      paletteIndex = paletteIndex + (paletteBank or 0) * 16
    end
    local color = palette[paletteIndex]
    if not color then
      sourceError("intro pixel references a missing palette entry", { value = value })
    end
    local targetX = flipH and 7 - px or px
    local targetY = flipV and 7 - py or py
    local offset = ((y + targetY) * width + x + targetX) * 4
    rgba[offset + 1], rgba[offset + 2], rgba[offset + 3], rgba[offset + 4] = color.r, color.g, color.b, 255
  end
  local base = tileIndex * tileBytes
  if char.depth == 3 then
    for row = 0, 7 do
      for column = 0, 3 do
        local value = string.byte(char.tiles, base + row * 4 + column + 1)
        put(column * 2, row, value % 16)
        put(column * 2 + 1, row, math.floor(value / 16))
      end
    end
  else
    for row = 0, 7 do
      for column = 0, 7 do
        put(column, row, string.byte(char.tiles, base + row * 8 + column + 1))
      end
    end
  end
end

---@param char table<string, unknown>
---@param palette table[]
---@return table<string, unknown>
function IntroRasterizer.renderChar(char, palette)
  local tileBytes = char.depth == 3 and 32 or 64
  local tileCount = #char.tiles / tileBytes
  local width = 16 * 8
  local height = math.ceil(tileCount / 16) * 8
  local rgba = newRgba(width, height)
  for tile = 0, tileCount - 1 do
    blitTile(rgba, width, char, tile % 16 * 8, math.floor(tile / 16) * 8, tile, palette)
  end
  return { width = width, height = height, rgba = concatBytes(rgba) }
end

---@param char table<string, unknown>
---@param palette table[]
---@param screen table<string, unknown>
---@param paletteBankOverride integer|nil
---@return table<string, unknown>
function IntroRasterizer.renderScreen(char, palette, screen, paletteBankOverride)
  local rgba = newRgba(screen.width, screen.height)
  local columns = screen.width / 8
  for row = 0, screen.height / 8 - 1 do
    for column = 0, columns - 1 do
      local entry = screen.entries[row * columns + column + 1]
      blitTile(
        rgba,
        screen.width,
        char,
        column * 8,
        row * 8,
        entry.tile,
        palette,
        paletteBankOverride or entry.palette,
        entry.flipH,
        entry.flipV
      )
    end
  end
  return { width = screen.width, height = screen.height, rgba = concatBytes(rgba) }
end

local function cellBounds(cell, bounds)
  for _, object in ipairs(cell.objs) do
    bounds.minX = math.min(bounds.minX, object.x)
    bounds.minY = math.min(bounds.minY, object.y)
    bounds.maxX = math.max(bounds.maxX, object.x + object.width)
    bounds.maxY = math.max(bounds.maxY, object.y + object.height)
  end
end

local function renderCell(char, palette, cell, bounds)
  if #cell.objs == 0 then
    sourceError("intro cell has no objects", { sourceOffset = 0 })
  end
  local minX, minY = bounds.minX, bounds.minY
  local width, height = bounds.maxX - minX, bounds.maxY - minY
  local rgba = newRgba(width, height)
  for _, object in ipairs(cell.objs) do
    local columns, rows = object.width / 8, object.height / 8
    for row = 0, rows - 1 do
      for column = 0, columns - 1 do
        local tileColumn = object.flipH and columns - 1 - column or column
        local tileRow = object.flipV and rows - 1 - row or row
        blitTile(
          rgba,
          width,
          char,
          object.x - minX + column * 8,
          object.y - minY + row * 8,
          object.tile + tileRow * columns + tileColumn,
          palette,
          0,
          object.flipH,
          object.flipV
        )
      end
    end
  end
  return { width = width, height = height, rgba = concatBytes(rgba) }
end

local function transformedBounds(cell, frame)
  local cellB = { minX = math.huge, minY = math.huge, maxX = -math.huge, maxY = -math.huge }
  cellBounds(cell, cellB)
  local minX, minY, maxX, maxY
  local radians = math.rad(frame.rotation)
  local cosR, sinR = math.cos(radians), math.sin(radians)
  for _, point in ipairs({
    { x = cellB.minX, y = cellB.minY },
    { x = cellB.maxX, y = cellB.minY },
    { x = cellB.minX, y = cellB.maxY },
    { x = cellB.maxX, y = cellB.maxY },
  }) do
    local sx, sy = point.x * frame.scaleX, point.y * frame.scaleY
    local x = frame.rotation == 0 and sx or sx * cosR - sy * sinR
    local y = frame.rotation == 0 and sy or sx * sinR + sy * cosR
    x, y = x + frame.translateX, y + frame.translateY
    minX, minY = minX and math.min(minX, x) or x, minY and math.min(minY, y) or y
    maxX, maxY = maxX and math.max(maxX, x) or x, maxY and math.max(maxY, y) or y
  end
  return cellB, { minX = minX, minY = minY, maxX = maxX, maxY = maxY }
end

local function copyTransformed(rgba, width, height, cellImage, cellB, frame, bounds)
  local cellW, cellH = cellB.maxX - cellB.minX, cellB.maxY - cellB.minY
  local radians = math.rad(frame.rotation)
  local cosR, sinR = math.cos(radians), math.sin(radians)
  for dy = 0, height - 1 do
    for dx = 0, width - 1 do
      local worldX, worldY = bounds.minX + dx - frame.translateX, bounds.minY + dy - frame.translateY
      local ix = worldX * cosR + worldY * sinR
      local iy = -worldX * sinR + worldY * cosR
      local srcX = math.floor(ix / frame.scaleX - cellB.minX + 0.5)
      local srcY = math.floor(iy / frame.scaleY - cellB.minY + 0.5)
      if srcX >= 0 and srcX < cellW and srcY >= 0 and srcY < cellH then
        local sourceOffset = (srcY * cellW + srcX) * 4
        local alpha = byteAt(cellImage.rgba, sourceOffset + 4)
        if alpha ~= 0 and alpha ~= nil then
          local destinationOffset = (dy * width + dx) * 4
          rgba[destinationOffset + 1] = byteAt(cellImage.rgba, sourceOffset + 1)
          rgba[destinationOffset + 2] = byteAt(cellImage.rgba, sourceOffset + 2)
          rgba[destinationOffset + 3] = byteAt(cellImage.rgba, sourceOffset + 3)
          rgba[destinationOffset + 4] = alpha
        end
      end
    end
  end
end

---@param char table<string, unknown>
---@param palette table[]
---@param cells table<string, unknown>
---@param animation table<string, unknown>
---@param animationIndex integer|nil
---@return table<string, unknown>, table[], { playMode: string, loopStartFrameIdx: integer }|nil
function IntroRasterizer.renderAnimations(char, palette, cells, animation, animationIndex)
  local animations = animationIndex ~= nil and { animation.anims[animationIndex + 1] } or animation.anims
  if animationIndex ~= nil and not animations[1] then
    sourceError("intro animation index is outside the source animation table", { animationIndex = animationIndex })
  end
  local selectedFrames, bounds, playback = {}, nil, nil
  for _, selected in ipairs(animations) do
    if type(selected.playMode) ~= "string" or type(selected.loopStartFrameIdx) ~= "number" then
      sourceError("intro animation is missing decoded playback policy", { sourceOffset = 0 })
    end
    if playback == nil then
      playback = { playMode = selected.playMode, loopStartFrameIdx = selected.loopStartFrameIdx }
    end
    for _, sourceFrame in ipairs(selected.frames) do
      if sourceFrame.duration <= 0 then
        sourceError("intro animation frame has no positive source duration", { duration = sourceFrame.duration })
      end
      local cell = cells.cells[sourceFrame.cell + 1]
      if not cell then
        sourceError("intro animation references a missing cell", { cell = sourceFrame.cell })
      end
      local frame = {
        translateX = sourceFrame.translateX or 0,
        translateY = sourceFrame.translateY or 0,
        scaleX = sourceFrame.scaleX or 1,
        scaleY = sourceFrame.scaleY or 1,
        rotation = sourceFrame.rotation or 0,
      }
      local _, transformed = transformedBounds(cell, frame)
      bounds = bounds
        or { minX = transformed.minX, minY = transformed.minY, maxX = transformed.maxX, maxY = transformed.maxY }
      bounds.minX, bounds.minY = math.min(bounds.minX, transformed.minX), math.min(bounds.minY, transformed.minY)
      bounds.maxX, bounds.maxY = math.max(bounds.maxX, transformed.maxX), math.max(bounds.maxY, transformed.maxY)
      frame.cell, frame.duration, frame.element = cell, sourceFrame.duration, sourceFrame.element or "none"
      selectedFrames[#selectedFrames + 1] = frame
    end
  end
  if #selectedFrames == 0 then
    sourceError("intro source animation is empty", { sourceOffset = 0 })
  end
  assert(bounds ~= nil)
  bounds.minX, bounds.minY = math.min(math.floor(bounds.minX + 0.5), 0), math.min(math.floor(bounds.minY + 0.5), 0)
  bounds.maxX, bounds.maxY = math.max(math.ceil(bounds.maxX - 0.5), 0), math.max(math.ceil(bounds.maxY - 0.5), 0)
  local width, height = math.max(bounds.maxX - bounds.minX, 1), math.max(bounds.maxY - bounds.minY, 1)
  local anchor = { x = math.max(0, math.min(width, -bounds.minX)), y = math.max(0, math.min(height, -bounds.minY)) }
  local output = {}
  for index, frame in ipairs(selectedFrames) do
    local rgba = newRgba(width, height)
    local cellB = transformedBounds(frame.cell, frame)
    local identity = frame.translateX == 0
      and frame.translateY == 0
      and frame.scaleX == 1
      and frame.scaleY == 1
      and frame.rotation == 0
    local renderedRgba
    if identity then
      renderedRgba = renderCell(char, palette, frame.cell, bounds).rgba
    else
      local cellImage = renderCell(char, palette, frame.cell, cellB)
      copyTransformed(rgba, width, height, cellImage, cellB, frame, bounds)
      renderedRgba = concatBytes(rgba)
    end
    output[index] = {
      width = width,
      height = height,
      rgba = renderedRgba,
      duration = frame.duration,
      element = frame.element,
      translateX = frame.translateX,
      translateY = frame.translateY,
      scaleX = frame.scaleX,
      scaleY = frame.scaleY,
      rotation = frame.rotation,
    }
  end
  return {
    width = width,
    height = height,
    anchor = anchor,
    sourceBounds = { x = bounds.minX, y = bounds.minY, width = width, height = height },
    frames = output,
    rgba = output[1].rgba,
  },
    output,
    playback
end

return IntroRasterizer
