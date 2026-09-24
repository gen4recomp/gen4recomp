-- Renders the field Yes/No list in source coordinates under one host placement.

local FieldDrawState = require("libs.hgss.src.presentation.FieldDrawState")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local LogicalSurface = require("libs.ui.src.LogicalSurface")

---@alias FieldYesNoRenderer.Color { r: integer, g: integer, b: integer }
---@alias FieldYesNoRenderer.Palette { [integer]: FieldYesNoRenderer.Color }
---@alias FieldYesNoRenderer.TextPalette { foreground: FieldYesNoRenderer.Color, shadow: FieldYesNoRenderer.Color, background: FieldYesNoRenderer.Color }

---@class FieldYesNoRenderer.TextRenderer
---@field drawTextWithPalette fun(self: FieldYesNoRenderer.TextRenderer, text: string, x: number, y: number, palette: FieldYesNoRenderer.TextPalette)
---@class FieldYesNoRenderer.WindowRenderer
---@field drawWindow fun(self: FieldYesNoRenderer.WindowRenderer, box: table<string, number>, frameIndex: integer, background: number[])
---@field framePalette fun(self: FieldYesNoRenderer.WindowRenderer, frameIndex: integer): FieldYesNoRenderer.Palette
---@field drawStandardWindow fun(self: FieldYesNoRenderer.WindowRenderer, box: table<string, number>, background: number[])
---@field standardFramePalette fun(self: FieldYesNoRenderer.WindowRenderer): FieldYesNoRenderer.Palette

---@class FieldYesNoRenderer
---@field _graphics love.graphics
---@field _text FieldYesNoRenderer.TextRenderer
---@field _window FieldYesNoRenderer.WindowRenderer
local FieldYesNoRenderer = {}
FieldYesNoRenderer.__index = FieldYesNoRenderer

local CONTENT = { x = 25 * 8, y = 13 * 8, width = 6 * 8, height = 4 * 8 }
local REFERENCE = { width = 256, height = 192 }

local function fits(rect, bounds)
  return rect.x >= bounds.x
    and rect.y >= bounds.y
    and rect.x + rect.width <= bounds.x + bounds.width
    and rect.y + rect.height <= bounds.y + bounds.height
end

local function adaptedFrameBounds()
  local minX, minY = 0, 0
  local maxX, maxY = CONTENT.width, CONTENT.height
  for _, tile in
    ipairs(FieldDialogueTheme.frameTilePlacements({ x = 0, y = 0, width = CONTENT.width, height = CONTENT.height }))
  do
    minX = math.min(minX, tile.x)
    minY = math.min(minY, tile.y)
    maxX = math.max(maxX, tile.x + FieldDialogueTheme.frameTileSize * (tile.spanX or 1))
    maxY = math.max(maxY, tile.y + FieldDialogueTheme.frameTileSize * (tile.spanY or 1))
  end
  return { x = minX, y = minY, width = maxX - minX, height = maxY - minY }
end

local function surfaceFor(topology)
  assert(type(topology) == "table" and type(topology.surfaces) == "table", "yes/no layout requires a screen topology")
  for _, surface in ipairs(topology.surfaces) do
    if surface.role == "auxiliary" then
      return surface
    end
  end
  return assert(topology.surfaces[1], "yes/no layout requires a display surface")
end

---@param palette FieldYesNoRenderer.Palette
---@return number[]
local function windowFill(palette)
  local color = assert(palette[15], "Yes/No window palette has no background color")
  return { color.r / 255, color.g / 255, color.b / 255, 1 }
end

---@param palette FieldYesNoRenderer.Palette
---@return FieldYesNoRenderer.TextPalette
local function textPalette(palette)
  return {
    foreground = assert(palette[1], "Yes/No window palette has no foreground color"),
    shadow = assert(palette[2], "Yes/No window palette has no shadow color"),
    background = assert(palette[15], "Yes/No window palette has no background color"),
  }
end

---@param opts { text: table<string, unknown>, window: table<string, unknown>, graphics?: love.graphics }
---@return FieldYesNoRenderer
function FieldYesNoRenderer.new(opts)
  assert(type(opts) == "table", "yes/no renderer options are required")
  local graphics = opts.graphics or assert(love.graphics)
  assert(graphics and graphics.setColor, "yes/no renderer requires love.graphics")
  local text = opts.text
  assert(text and type(text.drawTextWithPalette) == "function", "yes/no renderer requires the field text renderer")
  ---@cast text FieldYesNoRenderer.TextRenderer
  local window = opts.window
  assert(
    window
      and type(window.drawWindow) == "function"
      and type(window.framePalette) == "function"
      and type(window.drawStandardWindow) == "function"
      and type(window.standardFramePalette) == "function",
    "yes/no renderer requires the field window renderer"
  )
  ---@cast window FieldYesNoRenderer.WindowRenderer
  return setmetatable({ _graphics = graphics, _text = text, _window = window }, FieldYesNoRenderer)
end

---@param status { active: boolean, selectedIndex: integer, yesText: string, noText: string, frameIndex: integer? }
---@param topology ScreenTopology
---@param dialogueBox table<string, number>?
---@return table<string, unknown>
function FieldYesNoRenderer:layout(status, topology, dialogueBox)
  assert(type(status) == "table" and status.active == true, "yes/no layout requires an active choice")
  assert(status.selectedIndex == 0 or status.selectedIndex == 1, "yes/no selection is outside the two choices")
  assert(type(status.yesText) == "string" and type(status.noText) == "string", "yes/no labels are required")
  local surface = surfaceFor(topology)
  local safe = assert(surface.safeRect or surface.rect)
  if
    surface.role == "auxiliary"
    and surface.rect.width >= REFERENCE.width
    and surface.rect.height >= REFERENCE.height
  then
    local scale = math.min(safe.width / REFERENCE.width, safe.height / REFERENCE.height)
    assert(scale > 0, "yes/no source presentation requires a positive scale")
    local originX = safe.x + (safe.width - REFERENCE.width * scale) / 2
    local originY = safe.y + (safe.height - REFERENCE.height * scale) / 2
    return {
      surface = surface,
      presentation = "source",
      content = CONTENT,
      placement = {
        frame = { x = originX, y = originY, width = REFERENCE.width * scale, height = REFERENCE.height * scale },
        origin = { x = originX, y = originY },
        scale = scale,
        clipRect = safe,
      },
    }
  end

  local outer = adaptedFrameBounds()
  local scale = math.min(1, safe.width / outer.width, safe.height / outer.height)
  assert(scale > 0, "yes/no adapted presentation requires a positive scale")
  local width = outer.width * scale
  local height = outer.height * scale
  local hostFrame =
    { x = safe.x + safe.width - width, y = safe.y + safe.height - height, width = width, height = height }
  if dialogueBox then
    local candidates = {
      { x = hostFrame.x, y = dialogueBox.y + dialogueBox.height, width = width, height = height },
      { x = hostFrame.x, y = dialogueBox.y - height, width = width, height = height },
    }
    for _, candidate in ipairs(candidates) do
      if fits(candidate, safe) then
        hostFrame = candidate
        break
      end
    end
  end
  assert(fits(hostFrame, safe), "yes/no choice frame leaves the safe area")
  local hostContentOrigin = {
    x = hostFrame.x - outer.x * scale,
    y = hostFrame.y - outer.y * scale,
  }
  return {
    surface = surface,
    presentation = "adapted",
    content = { x = 0, y = 0, width = CONTENT.width, height = CONTENT.height },
    placement = {
      frame = hostFrame,
      origin = hostContentOrigin,
      scale = scale,
      clipRect = safe,
    },
  }
end

---@param status { selectedIndex: integer, yesText: string, noText: string, frameIndex: integer? }
---@param layout table<string, unknown>
function FieldYesNoRenderer:draw(status, layout)
  assert(type(status) == "table" and type(layout) == "table", "yes/no draw requires status and layout")
  assert(status.selectedIndex == 0 or status.selectedIndex == 1, "yes/no selection is outside the two choices")
  local box = assert(layout.content)
  local presentation = assert(layout.presentation)
  assert(presentation == "source" or presentation == "adapted", "yes/no layout has an unknown presentation")
  FieldDrawState.protectedDraw(self._graphics, function()
    LogicalSurface.draw(self._graphics, assert(layout.placement), function()
      local palette
      if presentation == "source" then
        palette = self._window:standardFramePalette()
        self._window:drawStandardWindow(box, windowFill(palette))
      else
        local frameIndex = assert(status.frameIndex, "adapted yes/no choice has no dialogue frame index")
        palette = self._window:framePalette(frameIndex)
        self._window:drawWindow(box, frameIndex, windowFill(palette))
      end
      local colors = textPalette(palette)
      self._text:drawTextWithPalette("‣", box.x, box.y + status.selectedIndex * 16, colors)
      self._text:drawTextWithPalette(assert(status.yesText), box.x + 8, box.y, colors)
      self._text:drawTextWithPalette(assert(status.noText), box.x + 8, box.y + 16, colors)
    end)
  end)
end

function FieldYesNoRenderer:release() end

return FieldYesNoRenderer
