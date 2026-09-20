-- Stateless execution of one logical coordinate boundary over an injected
-- graphics namespace. The caller resolves a complete placement, owns the
-- current render target and every GPU resource; this scope only pushes the
-- graphics state, resets the transform, intersects the visible clip, applies
-- the single root transform, runs the callback, and restores the state even
-- when the callback fails. It allocates no canvases, images, or fonts and
-- retains nothing between calls.

local LayoutGeometry = require("libs.ui.src.LayoutGeometry")

local LogicalSurface = {}

---@param graphics table<string, unknown> the injected LOVE-like graphics namespace
---@param name string the scope name used in validation messages
local function checkScopeGraphics(graphics, name)
  assert(type(graphics) == "table", name .. " requires a graphics namespace")
  for _, key in ipairs({ "push", "pop", "origin", "intersectScissor", "translate", "scale" }) do
    assert(type(graphics[key]) == "function", name .. " requires graphics." .. key)
  end
end

---@param placement LayoutGeometry.Placement
---@return { x: number, y: number } origin
---@return LayoutGeometry.Rect clip
local function resolveScope(placement)
  LayoutGeometry.validatePlacement(placement, "placement")
  local frame = placement.frame
  local origin = placement.origin or frame
  local clip = placement.clipRect or frame
  return { x = origin.x, y = origin.y }, { x = clip.x, y = clip.y, width = clip.width, height = clip.height }
end

-- Runs one callback inside the placement's logical coordinate space: the
-- pushed scope is popped exactly once, the original callback error object
-- propagates unwrapped, and the render target is left unchanged.
---@param graphics love.graphics
---@param placement LayoutGeometry.Placement
---@param draw fun()
function LogicalSurface.draw(graphics, placement, draw)
  assert(type(draw) == "function", "a draw callback is required")
  checkScopeGraphics(graphics, "draw")
  local origin, clip = resolveScope(placement)
  local scale = placement.scale
  graphics.push("all")
  local ok, err = pcall(function()
    graphics.origin()
    graphics.intersectScissor(clip.x, clip.y, clip.width, clip.height)
    graphics.translate(origin.x, origin.y)
    graphics.scale(scale, scale)
    draw()
  end)
  graphics.pop()
  if not ok then
    error(err, 0)
  end
end

-- Runs one callback under a nested logical clip: the rectangle maps through
-- the current graphics transform, intersects (never replaces) the active
-- scissor, and the pushed scope is popped exactly once with the original
-- error object propagated unwrapped. No presentation scale is applied again.
---@param graphics love.graphics
---@param logicalRect LayoutGeometry.Rect logical bounds in the current scope
---@param draw fun()
function LogicalSurface.clip(graphics, logicalRect, draw)
  assert(type(draw) == "function", "a draw callback is required")
  checkScopeGraphics(graphics, "clip")
  assert(type(graphics.transformPoint) == "function", "clip requires graphics.transformPoint")
  local rect = LayoutGeometry.rect(logicalRect, "logicalRect")
  local nearX, nearY = graphics.transformPoint(rect.x, rect.y)
  local farX, farY = graphics.transformPoint(rect.x + rect.width, rect.y + rect.height)
  assert(
    type(nearX) == "number"
      and nearX == nearX
      and type(nearY) == "number"
      and nearY == nearY
      and type(farX) == "number"
      and farX == farX
      and type(farY) == "number"
      and farY == farY,
    "graphics.transformPoint must return finite coordinates"
  )
  local x = math.min(nearX, farX)
  local y = math.min(nearY, farY)
  graphics.push("all")
  local ok, err = pcall(function()
    graphics.intersectScissor(x, y, math.abs(farX - nearX), math.abs(farY - nearY))
    draw()
  end)
  graphics.pop()
  if not ok then
    error(err, 0)
  end
end

return LogicalSurface
