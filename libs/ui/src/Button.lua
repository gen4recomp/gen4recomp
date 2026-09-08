-- Generic layered button geometry, rounded-rectangle painter, and hit-test primitive.

local Button = {}

local function finite(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function rectangle(value, name)
  assert(type(value) == "table", name .. " is required")
  for _, field in ipairs({ "x", "y", "width", "height" }) do
    assert(finite(value[field]), name .. " fields must be finite numbers")
  end
  assert(value.width > 0 and value.height > 0, name .. " must have positive dimensions")
  return { x = value.x, y = value.y, width = value.width, height = value.height }
end

local function metric(value, name)
  assert(finite(value) and value >= 0, name .. " must be a finite non-negative number")
  return value
end

local function assertPositiveRectangle(value, name)
  assert(value.width > 0 and value.height > 0, name .. " must have positive dimensions")
end

local function assertFiniteRectangle(value, name)
  for _, field in ipairs({ "x", "y", "width", "height" }) do
    assert(finite(value[field]), name .. " fields must be finite")
  end
  assert(value.width >= 0 and value.height >= 0, name .. " dimensions must be non-negative")
end

local function insetRect(rectValue, amount)
  return {
    x = rectValue.x + amount,
    y = rectValue.y + amount,
    width = rectValue.width - amount * 2,
    height = rectValue.height - amount * 2,
  }
end

local function shapeRounded(rectValue, cornerRadius, name)
  assertFiniteRectangle(rectValue, name .. " rectangle")
  assertPositiveRectangle(rectValue, name .. " rectangle")
  return { rect = rectValue, cornerRadius = cornerRadius }
end

---@param spec table<string, unknown>
---@return table<string, unknown>
function Button.resolve(spec)
  assert(type(spec) == "table", "button specification is required")
  local rectValue = rectangle(spec.rect, "button rectangle")
  local borderWidth = metric(spec.borderWidth, "button border width")
  local rimWidth = metric(spec.rimWidth, "button rim width")
  local innerBorderWidth = metric(spec.innerBorderWidth, "button inner border width")
  assert(spec.cornerRadius ~= nil, "button corner radius is required")
  local cornerRadius = metric(spec.cornerRadius, "button corner radius")
  assert(cornerRadius <= math.min(rectValue.width, rectValue.height) / 2, "button corner radius is too large")
  assert(
    finite(spec.faceSplit) and spec.faceSplit > 0 and spec.faceSplit < 1,
    "button face split must be between 0 and 1"
  )
  local contentInsetX = metric(spec.contentInsetX, "button horizontal content inset")
  local contentInsetY = metric(spec.contentInsetY, "button vertical content inset")

  local rimRect = insetRect(rectValue, borderWidth)
  local innerBorderRect = insetRect(rimRect, rimWidth)
  local faceRect = insetRect(innerBorderRect, innerBorderWidth)

  local border = shapeRounded(rectValue, cornerRadius, "button border")
  local rim = shapeRounded(rimRect, math.max(0, cornerRadius - borderWidth), "button rim")
  local innerBorder =
    shapeRounded(innerBorderRect, math.max(0, cornerRadius - borderWidth - rimWidth), "button inner border")
  local face =
    shapeRounded(faceRect, math.max(0, cornerRadius - borderWidth - rimWidth - innerBorderWidth), "button face")

  local contentRect = {
    x = faceRect.x + contentInsetX,
    y = faceRect.y + contentInsetY,
    width = faceRect.width - contentInsetX * 2,
    height = faceRect.height - contentInsetY * 2,
  }
  assertPositiveRectangle(contentRect, "button content rectangle")
  assertFiniteRectangle(contentRect, "button content rectangle")

  face.splitY = faceRect.y + faceRect.height * spec.faceSplit

  return {
    rect = rectValue,
    border = border,
    rim = rim,
    innerBorder = innerBorder,
    face = face,
    contentRect = contentRect,
  }
end

local function color(palette, name)
  local value = palette[name]
  assert(type(value) == "table", "button palette role is required: " .. name)
  assert(#value == 3 or #value == 4, "button palette role must have three or four components: " .. name)
  for index = 1, #value do
    assert(finite(value[index]), "button palette role must contain finite numbers: " .. name)
  end
  return value[1], value[2], value[3], value[4] or 1
end

local function drawRoundedShape(graphics, descriptor)
  local rectValue = descriptor.rect
  local radius = descriptor.cornerRadius
  assert(radius ~= nil, "button corner radius is required")
  if radius == 0 then
    graphics.rectangle("fill", rectValue.x, rectValue.y, rectValue.width, rectValue.height)
    return
  end
  graphics.rectangle("fill", rectValue.x, rectValue.y, rectValue.width, rectValue.height, radius, radius)
end

local function drawRoundedTopPortion(graphics, rectValue, radius, splitY)
  assert(radius ~= nil, "button corner radius is required")
  if radius == 0 then
    graphics.rectangle("fill", rectValue.x, rectValue.y, rectValue.width, splitY - rectValue.y)
    return
  end
  local topHeight = splitY - rectValue.y
  if topHeight <= 0 then
    return
  end
  graphics.rectangle("fill", rectValue.x, rectValue.y, rectValue.width, topHeight, radius, radius)
  if topHeight > radius then
    graphics.rectangle("fill", rectValue.x, splitY - radius, rectValue.width, radius)
  end
end

---@param graphics table<string, unknown>
---@param button table<string, unknown>
---@param palette table<string, unknown>
function Button.draw(graphics, button, palette)
  assert(type(graphics) == "table", "button graphics is required")
  assert(type(graphics.setColor) == "function", "button graphics setColor is required")
  assert(type(graphics.rectangle) == "function", "button graphics rectangle is required")
  assert(type(button) == "table", "resolved button is required")
  assert(type(palette) == "table", "button palette is required")

  local border = { color(palette, "border") }
  local rim = { color(palette, "rim") }
  local innerBorder = { color(palette, "innerBorder") }
  local faceTop = { color(palette, "faceTop") }
  local faceBottom = { color(palette, "faceBottom") }

  graphics.setColor(border[1], border[2], border[3], border[4])
  drawRoundedShape(graphics, button.border)
  graphics.setColor(rim[1], rim[2], rim[3], rim[4])
  drawRoundedShape(graphics, button.rim)
  -- The inner border stops at the face midway point: its base is the dark
  -- face color and only the top portion keeps the intermediate color, the
  -- same split the face itself uses below.
  local innerBorderShape = assert(button.innerBorder, "resolved button inner border is required")
  local innerRect = assert(innerBorderShape.rect, "resolved button inner border rectangle is required")
  local innerRadius = assert(innerBorderShape.cornerRadius, "button inner border corner radius is required")
  local faceShape = assert(button.face, "resolved button face is required")
  local splitY = assert(faceShape.splitY, "resolved button face split is required")
  graphics.setColor(faceBottom[1], faceBottom[2], faceBottom[3], faceBottom[4])
  drawRoundedShape(graphics, button.innerBorder)
  graphics.setColor(innerBorder[1], innerBorder[2], innerBorder[3], innerBorder[4])
  drawRoundedTopPortion(graphics, innerRect, innerRadius, splitY)
  graphics.setColor(faceBottom[1], faceBottom[2], faceBottom[3], faceBottom[4])
  drawRoundedShape(graphics, button.face)
  graphics.setColor(faceTop[1], faceTop[2], faceTop[3], faceTop[4])
  local faceRect = assert(faceShape.rect, "resolved button face rectangle is required")
  local faceRadius = assert(faceShape.cornerRadius, "button face corner radius is required")
  drawRoundedTopPortion(graphics, faceRect, faceRadius, splitY)
end

---@param button table<string, unknown>
---@param x number
---@param y number
---@return boolean
function Button.contains(button, x, y)
  assert(type(button) == "table" and type(button.rect) == "table", "resolved button is required")
  assert(finite(x) and finite(y), "button hit point must be finite")
  local rectValue = button.rect
  assert(
    finite(rectValue.x) and finite(rectValue.y) and finite(rectValue.width) and finite(rectValue.height),
    "resolved button rectangle is invalid"
  )
  assert(rectValue.width > 0 and rectValue.height > 0, "resolved button rectangle must be positive")
  return x >= rectValue.x
    and x < rectValue.x + rectValue.width
    and y >= rectValue.y
    and y < rectValue.y + rectValue.height
end

return Button
