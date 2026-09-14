-- FieldViewport computes pure presentation rectangles for canonical 4:3 field
-- rendering. Expanded mode preserves height and reveals more world horizontally;
-- strict mode centers a 4:3 view, and narrow hosts fall back to strict fitting.

local FieldViewport = {}
FieldViewport.__index = FieldViewport

local function copyRectangle(rectangle)
  return {
    x = rectangle.x,
    y = rectangle.y,
    width = rectangle.width,
    height = rectangle.height,
  }
end

local function strictRectangle(x, y, width, height, aspect)
  if width / height >= aspect then
    local fittedWidth = height * aspect
    return { x = x + (width - fittedWidth) / 2, y = y, width = fittedWidth, height = height }
  end
  local fittedHeight = width / aspect
  return { x = x, y = y + (height - fittedHeight) / 2, width = width, height = fittedHeight }
end

function FieldViewport.new(width, height, options)
  options = options or {}
  local viewport = setmetatable({
    mode = options.mode or "expanded",
    canonicalAspect = options.canonicalAspect or (4 / 3),
    x = options.x or 0,
    y = options.y or 0,
  }, FieldViewport)
  assert(viewport.mode == "expanded" or viewport.mode == "strict", "unsupported field viewport mode")
  assert(viewport.canonicalAspect > 0, "canonical aspect must be positive")
  viewport:resize(width, height)
  return viewport
end

function FieldViewport:resize(width, height)
  assert(type(width) == "number" and width > 0, "viewport width must be positive")
  assert(type(height) == "number" and height > 0, "viewport height must be positive")
  self.width = width
  self.height = height
  local strict = strictRectangle(self.x, self.y, width, height, self.canonicalAspect)
  if self.mode == "strict" or width / height < self.canonicalAspect then
    self.worldViewport = strict
    self.referenceFrame = copyRectangle(strict)
    return
  end
  self.worldViewport = { x = self.x, y = self.y, width = width, height = height }
  self.referenceFrame = {
    x = self.x + (width - height * self.canonicalAspect) / 2,
    y = self.y,
    width = height * self.canonicalAspect,
    height = height,
  }
end

function FieldViewport:worldAspect()
  return self.worldViewport.width / self.worldViewport.height
end

return FieldViewport
