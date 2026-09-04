-- Party-screen layout: responsive six-slot geometry with a close affordance
-- and an action overlay, deterministic directional neighbors, and a
-- hit-test over the same rectangles the renderer paints. Slot rectangles
-- are positive, non-overlapping, inside the frame, and present for empty
-- slots; hit targets are never smaller than the visual controls.

local Assert = require("tests.support.Assert")
local PartyScreenLayout = require("libs.hgss.src.ui.PartyScreenLayout")

local T = {}

local SIZES = {
  { width = 320, height = 240 },
  { width = 640, height = 480 },
  { width = 1280, height = 720 },
}

local function area(rect)
  return rect.width * rect.height
end

local function overlaps(a, b)
  return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
end

local function inside(rect, frame)
  return rect.x >= frame.x
    and rect.y >= frame.y
    and rect.x + rect.width <= frame.x + frame.width
    and rect.y + rect.height <= frame.y + frame.height
end

local function center(rect)
  assert(rect ~= nil, "layout rectangles resolve")
  return rect.x + rect.width / 2, rect.y + rect.height / 2
end

local function checkSize(width, height, cancellable)
  local layout = PartyScreenLayout.resolve({ width = width, height = height, cancellable = cancellable })
  Assert.equal(#layout.slotRects, 6, "six slot rectangles resolve")
  local painted = {}
  for slot0 = 0, 5 do
    local rect = layout.slotRects[slot0 + 1]
    Assert.isTrue(rect.width > 0 and rect.height > 0, "slot " .. slot0 .. " is positive")
    Assert.isTrue(inside(rect, layout.frame), "slot " .. slot0 .. " stays in the frame")
    for _, other in ipairs(painted) do
      Assert.isFalse(overlaps(rect, other), "slot rectangles never overlap")
    end
    painted[#painted + 1] = rect
    local x, y = center(rect)
    local hit = layout.hitTest(x, y)
    assert(hit ~= nil, "slot centers hit their rectangles")
    Assert.equal(hit.kind, "slot")
    Assert.equal(hit.slot, slot0, "hit targets match the painted slot rectangles")
  end
  Assert.isTrue(area(layout.slotRects[1]) > area(layout.slotRects[2]), "the lead slot stays distinguishable")
  if cancellable then
    Assert.isTrue(layout.cancelRect.width > 0, "the close affordance resolves when cancellable")
    local x, y = center(layout.cancelRect)
    Assert.equal(layout.hitTest(x, y).kind, "cancel")
  else
    Assert.isNil(layout.cancelRect, "no close affordance resolves when cancellation is forbidden")
  end
  local switchX, switchY = center(layout.actionRects.switch)
  Assert.deepEqual(layout.hitTest(switchX, switchY, true), { kind = "action", action = "switch" })
  local cancelX, cancelY = center(layout.actionRects.cancel)
  Assert.deepEqual(layout.hitTest(cancelX, cancelY, true), { kind = "action", action = "cancel" })
  Assert.isTrue(
    layout.hitTest(switchX, switchY) == nil or layout.hitTest(switchX, switchY).kind ~= "action",
    "the idle overlay never swallows slot taps"
  )
  Assert.isNil(layout.hitTest(-8, -8), "points outside the frame hit nothing")
  return layout
end

function T.geometry_adapts_without_overlap_or_clipping()
  for _, size in ipairs(SIZES) do
    checkSize(size.width, size.height, true)
    checkSize(size.width, size.height, false)
  end
end

function T.neighbors_walk_the_column_to_cancel()
  local layout = PartyScreenLayout.resolve({ width = 640, height = 480, cancellable = true })
  ---@type integer|string
  local node = 0
  for expected = 1, 5 do
    node = assert(layout.neighbors[node].down, "slot " .. node .. " leads down")
    Assert.equal(node, expected)
  end
  Assert.equal(layout.neighbors[node].down, "cancel")
  Assert.equal(layout.neighbors.cancel.up, 5)
  local sealed = PartyScreenLayout.resolve({ width = 640, height = 480, cancellable = false })
  Assert.isNil(sealed.neighbors[5].down, "no cancel node resolves when forbidden")
end

function T.resize_keeps_the_navigation_structure()
  local before = PartyScreenLayout.resolve({ width = 640, height = 480, cancellable = true })
  local after = PartyScreenLayout.resolve({ width = 1280, height = 720, cancellable = true })
  for slot0 = 0, 5 do
    Assert.deepEqual(after.neighbors[slot0], before.neighbors[slot0], "resize preserves neighbor keys")
  end
  Assert.deepEqual(after.neighbors.cancel, before.neighbors.cancel)
end

return { tests = T }
