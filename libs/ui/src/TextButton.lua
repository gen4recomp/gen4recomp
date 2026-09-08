-- Yes/No-style text button composing the generic Button geometry.

local Button = require("libs.ui.src.Button")

---@class TextAdapter
---@field measure fun(label:string):number
---@field lineHeight number
---@field draw fun(label:string, x:number, y:number)

local TextButton = {}

TextButton.REFERENCE_WIDTH = 120
TextButton.REFERENCE_HEIGHT = 56

local DEFAULT_COLORS = {
  border = { 66 / 255, 66 / 255, 66 / 255, 1 },
  rim = { 230 / 255, 230 / 255, 222 / 255, 1 },
  innerBorder = { 25 / 255, 189 / 255, 197 / 255, 1 },
  faceTop = { 49 / 255, 222 / 255, 230 / 255, 1 },
  faceBottom = { 8 / 255, 156 / 255, 165 / 255, 1 },
  focusOuter = { 1, 1, 1, 1 },
  focusInner = { 1, 0, 0, 1 },
}

local ALLOWED_COLOR_KEYS = {
  border = true,
  rim = true,
  innerBorder = true,
  faceTop = true,
  faceBottom = true,
  focusOuter = true,
  focusInner = true,
}

local function finite(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function assertFinitePositiveScale(value)
  assert(finite(value) and value > 0, "text button scale must be a finite positive number")
end

local function copyColor(value)
  local result = {}
  for index = 1, #value do
    result[index] = value[index]
  end
  return result
end

local function mergeColors(overrides)
  local result = {}
  for key, value in pairs(DEFAULT_COLORS) do
    result[key] = copyColor(value)
  end
  if overrides ~= nil then
    assert(type(overrides) == "table", "text button colors must be a table")
    for key, value in pairs(overrides) do
      assert(ALLOWED_COLOR_KEYS[key], "text button unknown color role: " .. tostring(key))
      assert(type(value) == "table", "text button color role must be a table: " .. tostring(key))
      assert(#value == 3 or #value == 4, "text button color role must have three or four components: " .. tostring(key))
      for index = 1, #value do
        assert(finite(value[index]), "text button color must be finite: " .. tostring(key))
      end
      local copy = {}
      for index = 1, #value do
        copy[index] = value[index]
      end
      if #copy == 3 then
        copy[4] = 1
      end
      result[key] = copy
    end
  end
  return result
end

local function rectangle(value, name)
  assert(type(value) == "table", name .. " is required")
  for _, field in ipairs({ "x", "y", "width", "height" }) do
    assert(finite(value[field]), name .. " fields must be finite numbers")
  end
  assert(value.width > 0 and value.height > 0, name .. " must have positive dimensions")
  return { x = value.x, y = value.y, width = value.width, height = value.height }
end

---@param spec { rect: {x:number,y:number,width:number,height:number}, scale: number }
---@return table<string, unknown>
function TextButton.resolve(spec)
  assert(type(spec) == "table", "text button specification is required")
  local rectValue = rectangle(spec.rect, "text button rectangle")
  assertFinitePositiveScale(spec.scale)
  local scale = spec.scale
  local resolved = Button.resolve({
    rect = rectValue,
    borderWidth = 2 * scale,
    rimWidth = 1 * scale,
    innerBorderWidth = 1 * scale,
    cornerRadius = 3 * scale,
    faceSplit = 0.5,
    contentInsetX = 4 * scale,
    contentInsetY = 12 * scale,
  })
  resolved.scale = scale
  return resolved
end

local function drawFaceDivider(graphics, button, colors)
  local scale = assert(button.scale, "text button scale is missing")
  local innerBorder = assert(button.innerBorder, "text button inner border is missing")
  local innerRect = assert(innerBorder.rect, "text button inner border rectangle is missing")
  local face = assert(button.face, "text button face is missing")
  local splitY = assert(face.splitY, "text button face split is missing")
  graphics.setColor(colors.innerBorder[1], colors.innerBorder[2], colors.innerBorder[3], colors.innerBorder[4])
  local dividerHeight = 2 * scale
  graphics.rectangle("fill", innerRect.x, splitY - scale, innerRect.width, dividerHeight)
end

local function drawFocusOutline(graphics, button, colors)
  local scale = assert(button.scale, "text button scale is missing")
  local whiteWidth = 5 * scale
  local redWidth = 3 * scale
  local outerRadius = 3 * scale
  local inset = 1 * scale
  local radius = math.max(0, outerRadius - whiteWidth / 2)
  graphics.setColor(colors.focusOuter[1], colors.focusOuter[2], colors.focusOuter[3], colors.focusOuter[4])
  graphics.setLineWidth(whiteWidth)
  graphics.rectangle(
    "line",
    button.rect.x + inset,
    button.rect.y + inset,
    button.rect.width - inset * 2,
    button.rect.height - inset * 2,
    radius,
    radius
  )
  graphics.setColor(colors.focusInner[1], colors.focusInner[2], colors.focusInner[3], colors.focusInner[4])
  graphics.setLineWidth(redWidth)
  graphics.rectangle(
    "line",
    button.rect.x + inset,
    button.rect.y + inset,
    button.rect.width - inset * 2,
    button.rect.height - inset * 2,
    radius,
    radius
  )
end

---@param graphics table<string, unknown>
---@param button table<string, unknown>
---@param spec { label: string, selected: boolean, text: TextAdapter, colors?: table<string, unknown> }
function TextButton.draw(graphics, button, spec)
  assert(type(graphics) == "table", "text button graphics is required")
  assert(type(graphics.setColor) == "function", "text button graphics setColor is required")
  assert(type(graphics.rectangle) == "function", "text button graphics rectangle is required")
  assert(type(graphics.getLineWidth) == "function", "text button graphics getLineWidth is required")
  assert(type(graphics.setLineWidth) == "function", "text button graphics setLineWidth is required")
  assert(type(graphics.push) == "function", "text button graphics push is required")
  assert(type(graphics.pop) == "function", "text button graphics pop is required")
  assert(type(graphics.translate) == "function", "text button graphics translate is required")
  assert(type(graphics.scale) == "function", "text button graphics scale is required")
  assert(type(button) == "table" and type(button.rect) == "table", "resolved text button is required")
  assert(type(spec) == "table", "text button spec is required")
  assert(type(spec.label) == "string", "text button label is required")
  assert(type(spec.selected) == "boolean", "text button selected flag is required")
  assert(type(spec.text) == "table", "text button text adapter is required")
  assert(type(spec.text.measure) == "function", "text button text measure is required")
  assert(
    finite(spec.text.lineHeight) and spec.text.lineHeight > 0,
    "text button lineHeight must be a finite positive number"
  )
  assert(type(spec.text.draw) == "function", "text button text draw is required")
  if spec.colors ~= nil then
    assert(type(spec.colors) == "table", "text button colors must be a table")
  end

  local scale = assert(button.scale, "text button scale is missing")
  local content = button.contentRect
  assert(type(content) == "table", "text button content rectangle is missing")

  local labelWidth = spec.text.measure(spec.label)
  assert(finite(labelWidth) and labelWidth >= 0, "text button label width must be a finite non-negative number")
  local lineHeight = spec.text.lineHeight
  local sourceContentWidth = content.width / scale
  local sourceContentHeight = content.height / scale
  assert(labelWidth <= sourceContentWidth + 1e-6, "text button label does not fit inside content rectangle")
  assert(lineHeight <= sourceContentHeight + 1e-6, "text button label height does not fit inside content rectangle")

  local colors = mergeColors(spec.colors)

  local palette = {
    border = colors.border,
    rim = colors.rim,
    innerBorder = colors.innerBorder,
    faceTop = colors.faceTop,
    faceBottom = colors.faceBottom,
  }

  local savedLineWidth = graphics.getLineWidth()

  Button.draw(graphics, button, palette)

  drawFaceDivider(graphics, button, colors)

  if spec.selected then
    drawFocusOutline(graphics, button, colors)
  end

  graphics.push()
  graphics.translate(content.x, content.y)
  graphics.scale(scale, scale)

  local textXSource = (sourceContentWidth - labelWidth) / 2
  local textYSource = (sourceContentHeight - lineHeight) / 2

  local ok, err = pcall(function()
    spec.text.draw(spec.label, textXSource, textYSource)
  end)

  graphics.pop()
  graphics.setLineWidth(savedLineWidth)

  if not ok then
    error(err, 0)
  end
end

return TextButton
