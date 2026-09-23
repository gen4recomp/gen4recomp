-- Renders the compact field Yes/No choice over the active dialogue.

---@class FieldYesNoRenderer
---@field _graphics love.graphics
---@field _text table<string, unknown>
---@field _window table<string, unknown>
local FieldYesNoRenderer = {}
FieldYesNoRenderer.__index = FieldYesNoRenderer

local CONTENT = { x = 25 * 8, y = 13 * 8, width = 6 * 8, height = 4 * 8 }

local function surfaceFor(topology)
  assert(type(topology) == "table" and type(topology.surfaces) == "table", "yes/no layout requires a screen topology")
  for _, surface in ipairs(topology.surfaces) do
    if surface.role == "auxiliary" then
      return surface
    end
  end
  return assert(topology.surfaces[1], "yes/no layout requires a display surface")
end

---@param opts { text: table<string, unknown>, window: table<string, unknown>, graphics?: love.graphics }
---@return FieldYesNoRenderer
function FieldYesNoRenderer.new(opts)
  assert(type(opts) == "table", "yes/no renderer options are required")
  local graphics = opts.graphics or assert(love.graphics)
  assert(graphics and graphics.setColor, "yes/no renderer requires love.graphics")
  assert(opts.text and type(opts.text.drawText) == "function", "yes/no renderer requires the field text renderer")
  assert(
    opts.window and type(opts.window.drawWindow) == "function",
    "yes/no renderer requires the field window renderer"
  )
  return setmetatable({ _graphics = graphics, _text = opts.text, _window = opts.window }, FieldYesNoRenderer)
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
  local content
  local scale
  if surface.role == "auxiliary" and surface.rect.width >= 256 and surface.rect.height >= 192 then
    scale = math.min(safe.width / 256, safe.height / 192)
    local originX = safe.x + (safe.width - 256 * scale) / 2
    local originY = safe.y + (safe.height - 192 * scale) / 2
    content = {
      x = originX + CONTENT.x * scale,
      y = originY + CONTENT.y * scale,
      width = CONTENT.width * scale,
      height = CONTENT.height * scale,
    }
    return {
      surface = surface,
      content = content,
      scale = scale,
      dialogueBox = dialogueBox,
      selectedIndex = status.selectedIndex,
      yesText = status.yesText,
      noText = status.noText,
      frameIndex = status.frameIndex,
    }
  else
    scale = math.min(1, safe.width / CONTENT.width, safe.height / CONTENT.height)
    content = {
      x = safe.x + safe.width - CONTENT.width * scale,
      y = safe.y + safe.height - CONTENT.height * scale,
      width = CONTENT.width * scale,
      height = CONTENT.height * scale,
    }
  end
  assert(content.x >= safe.x and content.y >= safe.y, "yes/no choice leaves the safe area")
  assert(content.x + content.width <= safe.x + safe.width, "yes/no choice exceeds the safe width")
  assert(content.y + content.height <= safe.y + safe.height, "yes/no choice exceeds the safe height")
  return {
    surface = surface,
    content = content,
    dialogueBox = dialogueBox,
    scale = scale,
    selectedIndex = status.selectedIndex,
    yesText = status.yesText,
    noText = status.noText,
    frameIndex = status.frameIndex,
  }
end

---@param status { selectedIndex: integer, yesText: string, noText: string, frameIndex: integer? }
---@param layout table<string, unknown>
function FieldYesNoRenderer:draw(status, layout)
  assert(type(status) == "table" and type(layout) == "table", "yes/no draw requires status and layout")
  local box = assert(layout.content)
  self._window:drawWindow(box, status.frameIndex, self._text:windowBackgroundColor())
  local labels = { assert(status.yesText), assert(status.noText) }
  local scale = assert(layout.scale or 1)
  for index, label in ipairs(labels) do
    self._graphics.setColor(1, 1, 1, 1)
    if index - 1 == status.selectedIndex then
      self._text:drawFocusIndicator(status.selectedIndex, box.x, box.y + (index - 1) * 16 * scale)
    end
    self._text:drawText(label, box.x + 16 * scale, box.y + 4 * scale + (index - 1) * 16 * scale)
  end
end

function FieldYesNoRenderer:release() end

return FieldYesNoRenderer
