-- Resource-free selected-button focus outline shared by button controls.
-- Draws the white outer / red inner two-line decoration over a caller-owned
-- rectangle. Owns no resources or state; callers own selection and geometry.

local FocusOutline = {}

local DEFAULT_OUTER = { 1, 1, 1, 1 }
local DEFAULT_INNER = { 1, 0, 0, 1 }

local function finite(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function checkGraphics(graphics)
  assert(type(graphics) == "table", "focus outline graphics is required")
  assert(type(graphics.setColor) == "function", "focus outline graphics setColor is required")
  assert(type(graphics.getLineWidth) == "function", "focus outline graphics getLineWidth is required")
  assert(type(graphics.setLineWidth) == "function", "focus outline graphics setLineWidth is required")
  assert(type(graphics.rectangle) == "function", "focus outline graphics rectangle is required")
end

local function checkRect(rect)
  assert(type(rect) == "table", "focus outline rectangle is required")
  for _, field in ipairs({ "x", "y", "width", "height" }) do
    assert(finite(rect[field]), "focus outline rectangle fields must be finite numbers")
  end
  assert(rect.width > 0 and rect.height > 0, "focus outline rectangle must have positive dimensions")
end

local function checkScale(spec)
  assert(type(spec) == "table", "focus outline specification is required")
  assert(finite(spec.scale) and spec.scale > 0, "focus outline scale must be a finite positive number")
  return spec.scale
end

---@param value number[]|nil
---@param name string
---@param default number[]
---@return number[]
local function resolveColor(value, name, default)
  if value == nil then
    return { default[1], default[2], default[3], default[4] }
  end
  assert(type(value) == "table", "focus outline " .. name .. " must be a table")
  assert(#value == 3 or #value == 4, "focus outline " .. name .. " must have three or four components")
  for index = 1, #value do
    assert(finite(value[index]), "focus outline " .. name .. " components must be finite numbers")
  end
  if #value == 3 then
    return { value[1], value[2], value[3], 1 }
  end
  return { value[1], value[2], value[3], value[4] }
end

---@param graphics table<string, unknown>
---@param rect {x:number, y:number, width:number, height:number}
---@param spec {scale:number, outerColor?:number[], innerColor?:number[]}
function FocusOutline.draw(graphics, rect, spec)
  checkGraphics(graphics)
  checkRect(rect)
  local scale = checkScale(spec)
  local outerColor = resolveColor(spec.outerColor, "outer color", DEFAULT_OUTER)
  local innerColor = resolveColor(spec.innerColor, "inner color", DEFAULT_INNER)

  local savedLineWidth = graphics.getLineWidth()
  local outerWidth = 5 * scale
  local innerWidth = 3 * scale
  local inset = 1 * scale
  local radius = math.max(0, 3 * scale - outerWidth / 2)

  graphics.setColor(outerColor[1], outerColor[2], outerColor[3], outerColor[4])
  graphics.setLineWidth(outerWidth)
  graphics.rectangle(
    "line",
    rect.x + inset,
    rect.y + inset,
    rect.width - inset * 2,
    rect.height - inset * 2,
    radius,
    radius
  )
  graphics.setColor(innerColor[1], innerColor[2], innerColor[3], innerColor[4])
  graphics.setLineWidth(innerWidth)
  graphics.rectangle(
    "line",
    rect.x + inset,
    rect.y + inset,
    rect.width - inset * 2,
    rect.height - inset * 2,
    radius,
    radius
  )
  graphics.setLineWidth(savedLineWidth)
end

return FocusOutline
