-- Gender-card-style image button composing the generic Button geometry.

local Button = require("libs.ui.src.Button")

local ImageButton = {}

local DEFAULT_BORDER = { 58 / 255, 58 / 255, 58 / 255, 1 }
local DEFAULT_RIM = { 222 / 255, 230 / 255, 230 / 255, 1 }
local DEFAULT_SELECTED_RIM = { 255 / 255, 58 / 255, 58 / 255, 1 }

local ALLOWED_COLOR_KEYS = {
  border = true,
  rim = true,
  selectedRim = true,
  innerBorder = true,
  face = true,
}

local function finite(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function assertFinitePositiveScale(value)
  assert(finite(value) and value > 0, "image button scale must be a finite positive number")
end

local function rectangle(value, name)
  assert(type(value) == "table", name .. " is required")
  for _, field in ipairs({ "x", "y", "width", "height" }) do
    assert(finite(value[field]), name .. " fields must be finite numbers")
  end
  assert(value.width > 0 and value.height > 0, name .. " must have positive dimensions")
  return { x = value.x, y = value.y, width = value.width, height = value.height }
end

local function copyColor(value)
  local result = {}
  for index = 1, #value do
    result[index] = value[index]
  end
  return result
end

local function validateColor(value, name)
  assert(type(value) == "table", name .. " must be a table")
  assert(#value == 3 or #value == 4, name .. " must have three or four components")
  for index = 1, #value do
    assert(finite(value[index]), name .. " must contain finite numbers")
  end
  local copy = {}
  for index = 1, #value do
    copy[index] = value[index]
  end
  if #copy == 3 then
    copy[4] = 1
  end
  return copy
end

---@param spec { rect: {x:number,y:number,width:number,height:number}, scale: number }
---@return table<string, unknown>
function ImageButton.resolve(spec)
  assert(type(spec) == "table", "image button specification is required")
  local rectValue = rectangle(spec.rect, "image button rectangle")
  assertFinitePositiveScale(spec.scale)
  local scale = spec.scale
  local resolved = Button.resolve({
    rect = rectValue,
    borderWidth = 2 * scale,
    rimWidth = 2 * scale,
    innerBorderWidth = 1 * scale,
    cornerRadius = 3 * scale,
    faceSplit = 0.5,
    contentInsetX = 0,
    contentInsetY = 0,
  })
  resolved.scale = scale
  return resolved
end

---@param graphics table<string, unknown>
---@param button table<string, unknown>
---@param spec { selected: boolean, colors: {face:number[], border?:number[], rim?:number[], selectedRim?:number[], innerBorder?:number[]}, imageRect: {x:number,y:number,width:number,height:number}, drawImage: fun(rect:table<string, unknown>)}
function ImageButton.draw(graphics, button, spec)
  assert(type(graphics) == "table", "image button graphics is required")
  assert(type(graphics.setColor) == "function", "image button graphics setColor is required")
  assert(type(graphics.rectangle) == "function", "image button graphics rectangle is required")
  assert(type(button) == "table" and type(button.rect) == "table", "resolved image button is required")
  assert(type(button.contentRect) == "table", "image button content rectangle is missing")
  assert(type(spec) == "table", "image button spec is required")
  assert(type(spec.selected) == "boolean", "image button selected flag is required")
  assert(type(spec.colors) == "table", "image button colors is required")
  assert(type(spec.colors.face) == "table", "image button face color is required")
  assert(type(spec.imageRect) == "table", "image button imageRect is required")
  assert(type(spec.drawImage) == "function", "image button drawImage is required")

  for key in pairs(spec.colors) do
    assert(ALLOWED_COLOR_KEYS[key], "image button unknown color role: " .. tostring(key))
  end

  local face = validateColor(spec.colors.face, "image button face color")
  local border = spec.colors.border and validateColor(spec.colors.border, "image button border color")
    or copyColor(DEFAULT_BORDER)
  local rimColor = copyColor(DEFAULT_RIM)
  local selectedRim = copyColor(DEFAULT_SELECTED_RIM)
  if spec.colors.rim ~= nil then
    rimColor = validateColor(spec.colors.rim, "image button rim color")
  end
  if spec.colors.selectedRim ~= nil then
    selectedRim = validateColor(spec.colors.selectedRim, "image button selectedRim color")
  end
  local innerBorder
  if spec.colors.innerBorder ~= nil then
    innerBorder = validateColor(spec.colors.innerBorder, "image button innerBorder color")
  else
    innerBorder = copyColor(face)
  end

  local rimToUse = spec.selected and selectedRim or rimColor

  local palette = {
    border = border,
    rim = rimToUse,
    innerBorder = innerBorder,
    faceTop = face,
    faceBottom = face,
  }

  Button.draw(graphics, button, palette)

  local imageRect = spec.imageRect
  for _, field in ipairs({ "x", "y", "width", "height" }) do
    assert(finite(imageRect[field]), "image button imageRect fields must be finite numbers")
  end
  assert(imageRect.width > 0 and imageRect.height > 0, "image button imageRect must have positive dimensions")
  local content = button.contentRect
  assert(
    imageRect.x >= content.x - 1e-6
      and imageRect.y >= content.y - 1e-6
      and imageRect.x + imageRect.width <= content.x + content.width + 1e-6
      and imageRect.y + imageRect.height <= content.y + content.height + 1e-6,
    "image button imageRect must be inside content rectangle"
  )

  spec.drawImage(imageRect)
end

return ImageButton
