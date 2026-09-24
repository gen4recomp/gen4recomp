-- The reusable two-row choice prompt: initial selection, vertical toggle,
-- confirm/cancel result semantics, and pointer taps resolved against the two
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

function T.confirm_resolves_the_selected_value_once()
  local controller = openAt(200, 48, "yes")
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(controller:takeResult(), "yes")
  Assert.isNil(controller:takeResult(), "the result is one-shot")

  local toggled = openAt(200, 48, "yes")
  toggled:updateFixed({ { type = "navigate", direction = "down" } })
  toggled:updateFixed({ { type = "confirm" } })
  Assert.equal(toggled:takeResult(), "no")
  Assert.isNil(toggled:takeResult())
end

function T.cancel_always_resolves_no()
  local fromYes = openAt(200, 48, "yes")
  fromYes:updateFixed({ { type = "cancel" } })
  Assert.equal(fromYes:takeResult(), "no")
  Assert.isNil(fromYes:takeResult())

  local fromNo = openAt(200, 48, "yes")
  fromNo:updateFixed({ { type = "navigate", direction = "down" } })
  fromNo:updateFixed({ { type = "cancel" } })
  Assert.equal(fromNo:takeResult(), "no")
  Assert.isNil(fromNo:takeResult())
end

function T.reopening_resets_selection_capture_and_result()
  local controller = openAt(200, 48, "yes")
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch", x = 210, y = 60 } })
  controller:open({ x = 200, y = 48, shape = "compact", initialSelection = "yes" })
  Assert.equal(controller:status().selected, "yes")
  Assert.isNil(controller:takeResult())
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch", x = 210, y = 60 } })
  Assert.isNil(controller:takeResult(), "the pre-reopen capture does not resolve")
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

function T.tap_inside_each_row_resolves_that_row()
  local yes = openAt(200, 48, "no")
  yes:updateFixed({ { type = "pointer_down", pointerId = "touch", x = 210, y = 60 } })
  yes:updateFixed({ { type = "pointer_up", pointerId = "touch", x = 210, y = 60 } })
  Assert.equal(yes:takeResult(), "yes")

  local no = openAt(200, 48, "yes")
  no:updateFixed({ { type = "pointer_down", pointerId = "touch", x = 247, y = 111 } })
  no:updateFixed({ { type = "pointer_up", pointerId = "touch", x = 247, y = 111 } })
  Assert.equal(no:takeResult(), "no")
end

function T.mismatched_press_release_and_outside_taps_resolve_nothing()
  local across = openAt(200, 48, "yes")
  across:updateFixed({ { type = "pointer_down", pointerId = "touch", x = 210, y = 60 } })
  across:updateFixed({ { type = "pointer_up", pointerId = "touch", x = 210, y = 90 } })
  Assert.isNil(across:takeResult())

  local dragged = openAt(200, 48, "yes")
  dragged:updateFixed({ { type = "pointer_down", pointerId = "touch", x = 210, y = 60 } })
  dragged:updateFixed({ { type = "pointer_up", pointerId = "touch", x = 210, y = 60, dragged = true } })
  Assert.isNil(dragged:takeResult())

  local outside = openAt(200, 48, "yes")
  outside:updateFixed({ { type = "pointer_down", pointerId = "touch", x = 10, y = 10 } })
  outside:updateFixed({ { type = "pointer_up", pointerId = "touch", x = 10, y = 10 } })
  Assert.isNil(outside:takeResult())
end

function T.pointer_cancellation_clears_capture_without_a_result()
  local controller = openAt(200, 48, "yes")
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch", x = 210, y = 60 } })
  controller:updateFixed({ { type = "pointer_cancel" } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch", x = 210, y = 60 } })
  Assert.isNil(controller:takeResult())
  Assert.isTrue(controller:status().active)
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
