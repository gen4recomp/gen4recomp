-- The reusable two-row choice prompt: initial selection, vertical toggle,
-- confirm/cancel result semantics, and pointer presses resolved against the two
-- stacked button rows derived from the placement template plus the generated
-- compact dimensions. The prompt never touches inventory, messages, or Bag
-- state: it reports one-shot semantic results only.

local Assert = require("tests.support.Assert")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local Prompt = require("libs.hgss.src.ui.YesNoPromptController")

local T = {}

local function shape()
  return FieldUiFixture.promptCompactSection().shapes.compact
end

local function openAt(x, y, initialSelection)
  local controller = Prompt.new(shape())
  controller:open({ x = x, y = y, shape = "compact", initialSelection = initialSelection or "yes" })
  return controller
end

-- The source confirmation blink: pairs of highlighted updates alternating
-- with pairs of unhighlighted updates across the fixed interval.
local CONFIRMATION_HIGHLIGHTS = { true, true, false, false, true, true, false, false }

-- Advances one latched choice through its eight confirmation updates,
-- asserting the blink cadence and that nothing is published early.
local function drainConfirmation(controller, expectedSelected, expectedHighlights)
  for step = 1, 8 do
    controller:updateFixed({})
    Assert.equal(controller:status().selected, expectedSelected, "the latched row holds through step " .. step)
    Assert.equal(
      controller:status().selectionHighlighted,
      expectedHighlights[step],
      "the confirmation blink at step " .. step
    )
    Assert.isNil(controller:takeResult(), "no result is published during confirmation")
  end
end

-- Runs the terminal update that follows the interval and returns the
-- published one-shot result.
local function takeTerminalResult(controller)
  controller:updateFixed({})
  local result = controller:takeResult()
  Assert.isNil(controller:takeResult(), "the result is one-shot")
  return result
end

function T.opens_with_the_template_initial_selection()
  local yes = openAt(200, 48, "yes")
  Assert.isTrue(yes:status().active)
  Assert.equal(yes:status().selected, "yes")

  local no = openAt(200, 48, "no")
  Assert.isTrue(no:status().active)
  Assert.equal(no:status().selected, "no")
end

function T.either_vertical_direction_toggles_and_horizontal_keeps()
  local controller = openAt(200, 48, "yes")
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(controller:status().selected, "no")
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(controller:status().selected, "yes")
  controller:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(controller:status().selected, "no")
  controller:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(controller:status().selected, "yes")
  controller:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.equal(controller:status().selected, "yes")
  controller:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(controller:status().selected, "yes")
end

function T.confirm_latches_the_row_and_publishes_only_on_the_terminal_update()
  local controller = openAt(200, 48, "yes")
  Assert.isTrue(controller:status().selectionHighlighted, "an idle prompt renders its selection highlighted")
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(controller:status().selected, "yes")
  Assert.isTrue(controller:status().selectionHighlighted, "the choice tick keeps the highlight")
  Assert.isNil(controller:takeResult(), "the choice tick latches without publishing")
  drainConfirmation(controller, "yes", CONFIRMATION_HIGHLIGHTS)
  Assert.equal(takeTerminalResult(controller), "yes")

  local toggled = openAt(200, 48, "yes")
  toggled:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(toggled:status().selected, "no")
  Assert.isTrue(toggled:status().selectionHighlighted, "navigation keeps the highlight")
  toggled:updateFixed({ { type = "confirm" } })
  Assert.isNil(toggled:takeResult(), "the choice tick latches without publishing")
  drainConfirmation(toggled, "no", CONFIRMATION_HIGHLIGHTS)
  Assert.equal(takeTerminalResult(toggled), "no")
end

function T.cancel_latches_no_through_the_same_delayed_interval()
  local fromYes = openAt(200, 48, "yes")
  fromYes:updateFixed({ { type = "cancel" } })
  Assert.equal(fromYes:status().selected, "no")
  Assert.isTrue(fromYes:status().selectionHighlighted, "the choice tick keeps the highlight")
  Assert.isNil(fromYes:takeResult(), "the choice tick latches without publishing")
  drainConfirmation(fromYes, "no", CONFIRMATION_HIGHLIGHTS)
  Assert.equal(takeTerminalResult(fromYes), "no")

  local fromNo = openAt(200, 48, "yes")
  fromNo:updateFixed({ { type = "navigate", direction = "down" } })
  fromNo:updateFixed({ { type = "cancel" } })
  Assert.isNil(fromNo:takeResult(), "the choice tick latches without publishing")
  drainConfirmation(fromNo, "no", CONFIRMATION_HIGHLIGHTS)
  Assert.equal(takeTerminalResult(fromNo), "no")
end

function T.reopening_resets_selection_pending_choice_and_result()
  local controller = openAt(200, 48, "no")
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch", x = 210, y = 60 } })
  Assert.equal(controller:status().selected, "yes", "the press resolves immediately")
  controller:open({ x = 200, y = 48, shape = "compact", initialSelection = "yes" })
  Assert.equal(controller:status().selected, "yes")
  Assert.isTrue(controller:status().selectionHighlighted, "a reopened prompt starts highlighted")
  Assert.isNil(controller:takeResult())
  for _ = 1, 9 do
    controller:updateFixed({})
    Assert.isTrue(controller:status().selectionHighlighted, "no pending choice blinks")
    Assert.isNil(controller:takeResult(), "the discarded pending choice never publishes")
  end
end

function T.input_while_inactive_produces_no_result()
  local controller = Prompt.new(shape())
  Assert.isFalse(controller:status().active)
  controller:updateFixed({
    { type = "navigate", direction = "down" },
    { type = "confirm" },
    { type = "cancel" },
    { type = "pointer_down", pointerId = "touch", x = 210, y = 60 },
    { type = "pointer_up", pointerId = "touch", x = 210, y = 60 },
  })
  Assert.isNil(controller:takeResult())

  local opened = openAt(200, 48, "yes")
  opened:dispose()
  Assert.isFalse(opened:status().active)
  opened:updateFixed({ { type = "confirm" } })
  Assert.isNil(opened:takeResult())
end

function T.stacked_rows_come_from_the_template_and_shape_dimensions()
  local controller = openAt(200, 48, "yes")
  local buttons = assert(controller:status().buttons, "an open prompt carries its button rows")
  Assert.deepEqual(buttons.yes, { x = 200, y = 48, width = 48, height = 32 })
  Assert.deepEqual(buttons.no, { x = 200, y = 80, width = 48, height = 32 })

  local moved = openAt(10, 20, "no")
  Assert.deepEqual(moved:status().buttons.yes, { x = 10, y = 20, width = 48, height = 32 })
  Assert.deepEqual(moved:status().buttons.no, { x = 10, y = 52, width = 48, height = 32 })
end

function T.press_inside_each_row_latches_that_row_through_the_delayed_interval()
  local yes = openAt(200, 48, "no")
  yes:updateFixed({ { type = "pointer_down", pointerId = "touch", x = 210, y = 60 } })
  Assert.equal(yes:status().selected, "yes", "the press resolves the YES row immediately")
  Assert.isTrue(yes:status().selectionHighlighted, "the choice press keeps the highlight")
  Assert.isNil(yes:takeResult(), "the choice press latches without publishing")
  drainConfirmation(yes, "yes", CONFIRMATION_HIGHLIGHTS)
  Assert.equal(takeTerminalResult(yes), "yes")

  local no = openAt(200, 48, "yes")
  no:updateFixed({ { type = "pointer_down", pointerId = "touch", x = 247, y = 111 } })
  Assert.equal(no:status().selected, "no", "the press resolves the NO row immediately")
  Assert.isTrue(no:status().selectionHighlighted, "the choice press keeps the highlight")
  Assert.isNil(no:takeResult(), "the choice press latches without publishing")
  drainConfirmation(no, "no", CONFIRMATION_HIGHLIGHTS)
  Assert.equal(takeTerminalResult(no), "no")
end

function T.input_while_confirmation_is_pending_cannot_change_the_latched_choice()
  local controller = openAt(200, 48, "yes")
  controller:updateFixed({ { type = "confirm" } })
  Assert.isNil(controller:takeResult())
  controller:updateFixed({
    { type = "navigate", direction = "down" },
    { type = "confirm" },
    { type = "cancel" },
    { type = "pointer_down", pointerId = "touch", x = 247, y = 111 },
    { type = "pointer_up", pointerId = "touch", x = 247, y = 111 },
  })
  Assert.equal(controller:status().selected, "yes", "pending input cannot move the latched row")
  Assert.isTrue(controller:status().selectionHighlighted)
  Assert.isNil(controller:takeResult(), "pending input cannot publish early")
  -- One interval step was consumed by the ignored-input update, so the
  -- remaining seven follow the same cadence from its second step on.
  for step, expected in ipairs({ true, false, false, true, true, false, false }) do
    controller:updateFixed({})
    Assert.equal(controller:status().selected, "yes")
    Assert.equal(controller:status().selectionHighlighted, expected, "the confirmation blink at step " .. step + 1)
    Assert.isNil(controller:takeResult())
  end
  Assert.equal(takeTerminalResult(controller), "yes")
end

-- Once a press resolves the source hitbox, later gesture events are
-- irrelevant: releases elsewhere, dragged or clean releases over the other
-- row, and cancellation all leave the resolved row and its delayed result
-- untouched.
function T.later_release_drag_and_cancel_events_cannot_undo_a_latched_press()
  local controller = openAt(200, 48, "yes")
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch", x = 247, y = 111 } })
  Assert.equal(controller:status().selected, "no", "the press resolves the NO row immediately")
  Assert.isNil(controller:takeResult(), "the choice press latches without publishing")
  controller:updateFixed({ { type = "pointer_move", x = 10, y = 10 } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch", x = 10, y = 10 } })
  Assert.equal(controller:status().selected, "no", "a release outside cannot move the latched row")
  controller:updateFixed({ { type = "pointer_down", pointerId = "other", x = 210, y = 60 } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "other", x = 210, y = 60, dragged = true } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "other", x = 210, y = 60, dragged = false } })
  Assert.equal(controller:status().selected, "no", "a later release over YES cannot move the latched row")
  controller:updateFixed({ { type = "pointer_cancel" } })
  Assert.equal(controller:status().selected, "no", "cancellation cannot move the latched row")
  Assert.isNil(controller:takeResult(), "gesture events cannot publish early")
  -- The six gesture updates above each consumed one interval step, so the
  -- final two steps close the same cadence from its seventh step on.
  for step, expected in ipairs({ false, false }) do
    controller:updateFixed({})
    Assert.equal(controller:status().selected, "no")
    Assert.equal(controller:status().selectionHighlighted, expected, "the confirmation blink at step " .. step + 6)
    Assert.isNil(controller:takeResult())
  end
  Assert.equal(takeTerminalResult(controller), "no")
end

function T.reopening_or_disposing_during_confirmation_discards_the_pending_choice()
  local controller = openAt(200, 48, "yes")
  controller:updateFixed({ { type = "confirm" } })
  Assert.isNil(controller:takeResult())
  controller:updateFixed({})
  controller:open({ x = 200, y = 48, shape = "compact", initialSelection = "no" })
  Assert.equal(controller:status().selected, "no")
  Assert.isTrue(controller:status().selectionHighlighted, "a reopened prompt starts highlighted")
  Assert.isNil(controller:takeResult())
  for _ = 1, 9 do
    controller:updateFixed({})
    Assert.isTrue(controller:status().selectionHighlighted, "no pending choice blinks")
    Assert.isNil(controller:takeResult(), "the discarded pending choice never publishes")
  end

  local disposed = openAt(200, 48, "yes")
  disposed:updateFixed({ { type = "confirm" } })
  disposed:dispose()
  Assert.isFalse(disposed:status().active)
  disposed:updateFixed({ { type = "confirm" } })
  Assert.isNil(disposed:takeResult(), "a disposed prompt publishes nothing")
end

function T.press_outside_both_rows_and_idle_gestures_resolve_nothing()
  local outside = openAt(200, 48, "yes")
  outside:updateFixed({ { type = "pointer_down", pointerId = "touch", x = 10, y = 10 } })
  Assert.equal(outside:status().selected, "yes", "an outside press keeps the selection")
  Assert.isNil(outside:takeResult())
  outside:updateFixed({ { type = "pointer_up", pointerId = "touch", x = 10, y = 10 } })
  Assert.equal(outside:status().selected, "yes", "an outside release keeps the selection")
  Assert.isNil(outside:takeResult(), "outside gestures publish nothing")

  local idle = openAt(200, 48, "yes")
  idle:updateFixed({ { type = "pointer_up", pointerId = "touch", x = 210, y = 60 } })
  idle:updateFixed({ { type = "pointer_cancel" } })
  Assert.equal(idle:status().selected, "yes", "an idle release or cancel keeps the selection")
  Assert.isNil(idle:takeResult(), "idle gestures publish nothing")
end

function T.cancellation_after_a_latched_press_keeps_the_pending_choice()
  local controller = openAt(200, 48, "no")
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch", x = 210, y = 60 } })
  Assert.equal(controller:status().selected, "yes", "the press resolves immediately")
  controller:updateFixed({ { type = "pointer_cancel" } })
  Assert.equal(controller:status().selected, "yes", "cancellation cannot undo the resolved row")
  Assert.isNil(controller:takeResult(), "cancellation publishes nothing")
  -- The cancellation update consumed the first interval step, so the
  -- remaining seven follow the same cadence from its second step on.
  for step, expected in ipairs({ true, false, false, true, true, false, false }) do
    controller:updateFixed({})
    Assert.equal(controller:status().selected, "yes")
    Assert.equal(controller:status().selectionHighlighted, expected, "the confirmation blink at step " .. step + 1)
    Assert.isNil(controller:takeResult())
  end
  Assert.equal(takeTerminalResult(controller), "yes")
end

function T.construction_rejects_a_shape_without_both_button_states()
  Assert.throws(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- the missing shape is the invalid input under test
    Prompt.new(nil)
  end)
  Assert.throws(function()
    Prompt.new({ width = 48, height = 32 })
  end)
  local incomplete = shape()
  incomplete.no.selected = nil
  Assert.throws(function()
    Prompt.new(incomplete)
  end)
  local wrongSize = shape()
  wrongSize.width = 64
  Assert.throws(function()
    Prompt.new(wrongSize)
  end)
end

function T.malformed_templates_fail_loudly()
  local controller = Prompt.new(shape())
  Assert.throws(function()
    controller:open({ x = 200, y = 48, shape = "wide", initialSelection = "yes" })
  end)
  Assert.throws(function()
    -- the fractional placement is the invalid input under test; openAt
    -- carries it through unannotated so no diagnostic suppression is needed
    openAt(200.5, 48, "yes")
  end)
  Assert.throws(function()
    controller:open({ x = 200, y = 48, shape = "compact", initialSelection = "maybe" })
  end)
  Assert.isFalse(controller:status().active, "a rejected open leaves the prompt inactive")
end

return { tests = T }
