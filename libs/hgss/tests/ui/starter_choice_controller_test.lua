-- Starter choice controller and layout: pure cursor, confirmation, and
-- geometry semantics over the current button primitives. The screen is
-- non-cancellable while selecting, confirmation never rerolls or exits on
-- no, and hit regions stay positive, disjoint, and stable across sizes.
-- Rendering and asset loading stay outside these modules.

local Assert = require("tests.support.Assert")
local Button = require("libs.ui.src.Button")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = {}

local CONTROLLER_MODULE = "libs.hgss.src.ui.StarterChoiceController"
local LAYOUT_MODULE = "libs.hgss.src.ui.StarterChoiceLayout"

local function requireController()
  local ok, controller = pcall(require, CONTROLLER_MODULE)
  Assert.isTrue(ok, "the starter controller owns cursor and confirmation state")
  return assert(controller)
end

local function requireLayout()
  local ok, layout = pcall(require, LAYOUT_MODULE)
  Assert.isTrue(ok, "the starter layout owns responsive hit regions")
  return assert(layout)
end

local function controller(initialCursor)
  local StarterChoiceController = requireController()
  return StarterChoiceController.new({
    candidates = { "Chikorita", "Cyndaquil", "Totodile" },
    initialCursor = initialCursor,
  })
end

local function topology(width, height)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    role = "world",
    touch = false,
  })
end

local function disjoint(a, b)
  return a.x + a.width <= b.x or b.x + b.width <= a.x or a.y + a.height <= b.y or b.y + b.height <= a.y
end

local function assertPositiveContained(rect, viewport, label)
  for _, field in ipairs({ "x", "y", "width", "height" }) do
    Assert.isTrue(type(rect[field]) == "number" and rect[field] == rect[field], label .. "." .. field .. " is finite")
  end
  Assert.isTrue(rect.width > 0 and rect.height > 0, label .. " has positive dimensions")
  Assert.isTrue(rect.x >= viewport.x, label .. " starts inside the viewport")
  Assert.isTrue(rect.y >= viewport.y, label .. " starts inside the viewport")
  Assert.isTrue(rect.x + rect.width <= viewport.x + viewport.width, label .. " ends inside the viewport")
  Assert.isTrue(rect.y + rect.height <= viewport.y + viewport.height, label .. " ends inside the viewport")
end

local function chrome(rect)
  return {
    rect = rect,
    borderWidth = 2,
    rimWidth = 2,
    innerBorderWidth = 1,
    cornerRadius = 4,
    faceSplit = 0.4,
    contentInsetX = 3,
    contentInsetY = 2,
  }
end

function T.selection_starts_at_the_first_candidate_and_is_not_cancellable()
  local owned = controller()
  local status = owned:status()
  Assert.equal(status.state, "active", "the choice starts active")
  Assert.equal(status.mode, "selecting", "the choice starts in selection")
  Assert.equal(status.candidateIndex, 0, "the cursor starts on the first candidate")
  Assert.isNil(owned:cancel(), "cancel while selecting never closes the story application")
  Assert.equal(owned:status().state, "active", "the choice stays active after cancel")
end

function T.confirmation_requires_an_explicit_yes_and_never_exits_on_no()
  local owned = controller(1)
  Assert.isNil(owned:confirm(), "confirming a candidate opens confirmation, not publication")
  Assert.equal(owned:status().mode, "confirming", "the controller enters confirmation")
  Assert.equal(owned:status().candidateIndex, 1, "confirmation keeps the highlighted candidate")

  owned:focus(1)
  Assert.isNil(owned:confirm(), "answering no returns without a result")
  Assert.equal(owned:status().mode, "selecting", "no returns to selection")
  Assert.equal(owned:status().candidateIndex, 1, "no preserves the candidate cursor")
  Assert.equal(owned:status().state, "active", "no never exits the application")

  Assert.isNil(owned:cancel(), "cancel while confirming is not an exit")
  Assert.equal(owned:status().mode, "selecting", "cancel while confirming returns to selection")

  owned:focus(2)
  owned:confirm()
  owned:focus(0)
  local result = owned:confirm()
  Assert.deepEqual(result, { candidate = 2, accepted = true }, "yes publishes the highlighted candidate once")
  Assert.equal(owned:status().state, "complete", "yes completes the application")
  Assert.isNil(owned:confirm(), "the semantic result is one-shot")
end

function T.pointer_capture_commits_only_on_matching_release()
  local owned = controller()
  owned:hover(2)
  Assert.equal(owned:status().candidateIndex, 2, "hover changes logical focus without activating")
  Assert.equal(owned:status().state, "active", "hover never completes")

  owned:press(0)
  Assert.isNil(owned:release(2), "a drag across candidates commits nothing")
  Assert.equal(owned:status().state, "active", "a mismatched release stays active")

  owned:press(1)
  Assert.isNil(owned:release(1), "a matching release opens confirmation, not publication")
  Assert.equal(owned:status().mode, "confirming", "pointer selection enters confirmation")
  Assert.equal(owned:status().candidateIndex, 1, "pointer selection highlights the pressed candidate")
end

function T.candidate_regions_are_distinct_positive_and_button_compatible()
  local layoutModule = requireLayout()
  local viewport = { x = 0, y = 0, width = 1280, height = 720 }
  local layout = layoutModule.resolve({ topology = topology(1280, 720), scale = 1 })

  Assert.equal(#layout.candidates, 3, "exactly three candidate controls exist")
  for index, rect in ipairs(layout.candidates) do
    assertPositiveContained(rect, viewport, "candidate " .. index)
    local resolved = Button.resolve(chrome(rect))
    Assert.notNil(resolved.contentRect, "candidate regions resolve through the button primitive")
    local centerX = rect.x + rect.width / 2
    local centerY = rect.y + rect.height / 2
    Assert.isTrue(Button.contains(resolved, centerX, centerY), "candidate centers hit-test inside")
    local hit = layoutModule.hitTest(layout, centerX, centerY)
    Assert.deepEqual(hit, { kind = "candidate", index = index - 1 }, "centers map to zero-based candidates")
  end
  for left = 1, 3 do
    for right = left + 1, 3 do
      Assert.isTrue(disjoint(layout.candidates[left], layout.candidates[right]), "candidate regions never overlap")
    end
  end
  Assert.isNil(
    layoutModule.hitTest(layout, viewport.x + viewport.width - 1, viewport.y + viewport.height - 1),
    "outside points hit nothing"
  )
end

function T.confirmation_regions_are_separate_and_layout_survives_resize()
  local layoutModule = requireLayout()
  local small = layoutModule.resolve({ topology = topology(256, 192), scale = 1 })

  Assert.equal(#small.confirm, 2, "confirmation offers yes and no")
  for _, rect in ipairs(small.confirm) do
    assertPositiveContained(rect, { x = 0, y = 0, width = 256, height = 192 }, "confirmation button")
  end
  for _, confirmRect in ipairs(small.confirm) do
    for _, candidateRect in ipairs(small.candidates) do
      Assert.isTrue(disjoint(confirmRect, candidateRect), "confirmation never covers a candidate")
    end
  end

  for _, size in ipairs({ { 256, 192 }, { 1280, 720 }, { 390, 844 } }) do
    local layout = layoutModule.resolve({ topology = topology(size[1], size[2]), scale = 1 })
    Assert.equal(#layout.candidates, 3, "three candidates survive every supported size")
    local viewport = { x = 0, y = 0, width = size[1], height = size[2] }
    for index, rect in ipairs(layout.candidates) do
      assertPositiveContained(rect, viewport, "resized candidate " .. index)
    end
  end

  local before = controller()
  before:focus(2)
  before:confirm()
  local status = before:status()
  Assert.equal(status.candidateIndex, 2, "recomputing layout preserves controller cursor")
  Assert.equal(status.mode, "confirming", "recomputing layout preserves confirmation state")
end

return { tests = T }
