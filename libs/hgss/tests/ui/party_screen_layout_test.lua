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

-- The native compact interface: two columns and three rows of readable
-- cards inside one 256x192 pane, a footer band carrying the selected name
-- and the cancel control, a centred action overlay, and hit targets over
-- the same rectangles the renderer paints.
local COMPACT_CARDS = {
  { x = 4, y = 4 },
  { x = 130, y = 4 },
  { x = 4, y = 60 },
  { x = 130, y = 60 },
  { x = 4, y = 116 },
  { x = 130, y = 116 },
}
local COMPACT_CARD_WIDTH = 122
local COMPACT_CARD_HEIGHT = 52
local COMPACT_FOOTER_TOP = 172

local function assertCompactRect(rect, expected, label)
  Assert.equal(rect.x, expected.x, label .. " x")
  Assert.equal(rect.y, expected.y, label .. " y")
  Assert.equal(rect.width, expected.width, label .. " width")
  Assert.equal(rect.height, expected.height, label .. " height")
end

function T.compact_native_grid_resolves_six_readable_cards()
  local layout = PartyScreenLayout.resolve({ width = 256, height = 192, cancellable = true })
  assertCompactRect(
    layout.frame,
    { x = 0, y = 0, width = 256, height = 192 },
    "the compact pane fills its native surface"
  )
  Assert.equal(#layout.slotRects, 6, "six slot rectangles resolve")
  local painted = {}
  for slot0 = 0, 5 do
    local rect = layout.slotRects[slot0 + 1]
    assertCompactRect(rect, {
      x = COMPACT_CARDS[slot0 + 1].x,
      y = COMPACT_CARDS[slot0 + 1].y,
      width = COMPACT_CARD_WIDTH,
      height = COMPACT_CARD_HEIGHT,
    }, "card " .. slot0)
    Assert.isTrue(rect.y + rect.height <= COMPACT_FOOTER_TOP, "card " .. slot0 .. " clears the footer band")
    for _, other in ipairs(painted) do
      Assert.isFalse(
        rect.x < other.x + other.width
          and other.x < rect.x + rect.width
          and rect.y < other.y + other.height
          and other.y < rect.y + rect.height,
        "compact cards never overlap"
      )
    end
    painted[#painted + 1] = rect
    local hit = layout.hitTest(rect.x + rect.width / 2, rect.y + rect.height / 2)
    assert(hit ~= nil, "card centers hit their rectangles")
    Assert.equal(hit.kind, "slot", "card centers hit slots")
    Assert.equal(hit.slot, slot0, "card centers hit their own slot")
  end
  assertCompactRect(layout.cancelRect, { x = 192, y = 172, width = 60, height = 16 }, "cancel sits in the footer band")
  assertCompactRect(
    layout.actionRects.switch,
    { x = 64, y = 76, width = 128, height = 20 },
    "the switch row fills the overlay top half"
  )
  assertCompactRect(
    layout.actionRects.cancel,
    { x = 64, y = 96, width = 128, height = 20 },
    "the overlay cancel row fills the overlay bottom half"
  )
  Assert.deepEqual(layout.hitTest(128, 86, true), { kind = "action", action = "switch" })
  Assert.deepEqual(layout.hitTest(128, 106, true), { kind = "action", action = "cancel" })
  local sealed = PartyScreenLayout.resolve({ width = 256, height = 192, cancellable = false })
  Assert.isNil(sealed.cancelRect, "no close affordance resolves when forbidden")
  Assert.isNil(sealed.hitTest(222, 180), "the forbidden cancel region stays noninteractive")
end

function T.compact_grid_neighbors_reach_cancel_without_wrapping()
  local layout = PartyScreenLayout.resolve({ width = 256, height = 192, cancellable = true })
  local neighbors = layout.neighbors
  Assert.equal(neighbors[0].right, 1, "right moves within the top row")
  Assert.equal(neighbors[1].left, 0, "left moves within the top row")
  Assert.equal(neighbors[0].down, 2, "down preserves the left column")
  Assert.equal(neighbors[1].down, 3, "down preserves the right column")
  Assert.equal(neighbors[2].up, 0, "up preserves the left column")
  Assert.equal(neighbors[3].up, 1, "up preserves the right column")
  Assert.equal(neighbors[2].right, 3, "right moves within the middle row")
  Assert.equal(neighbors[3].left, 2, "left moves within the middle row")
  Assert.equal(neighbors[2].down, 4, "down preserves the left column")
  Assert.equal(neighbors[3].down, 5, "down preserves the right column")
  Assert.equal(neighbors[4].up, 2, "up preserves the left column")
  Assert.equal(neighbors[5].up, 3, "up preserves the right column")
  Assert.equal(neighbors[4].right, 5, "right moves within the bottom row")
  Assert.equal(neighbors[5].left, 4, "left moves within the bottom row")
  Assert.equal(neighbors[4].down, "cancel", "the bottom row moves down to cancel")
  Assert.equal(neighbors[5].down, "cancel", "the bottom row moves down to cancel")
  Assert.equal(neighbors.cancel.up, 4, "cancel returns to the bottom row")
  Assert.isNil(neighbors[0].left, "the left column does not wrap")
  Assert.isNil(neighbors[1].right, "the right column does not wrap")
  Assert.isNil(neighbors[2].left, "the left column does not wrap")
  Assert.isNil(neighbors[3].right, "the right column does not wrap")
  Assert.isNil(neighbors[4].left, "the left column does not wrap")
  Assert.isNil(neighbors[5].right, "the right column does not wrap")
  local sealed = PartyScreenLayout.resolve({ width = 256, height = 192, cancellable = false })
  Assert.isNil(sealed.neighbors[5].down, "no cancel node resolves when forbidden")
  Assert.isNil(sealed.neighbors.cancel, "no cancel node resolves when forbidden")
end

return { tests = T }
