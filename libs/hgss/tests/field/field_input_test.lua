-- Fixed-tick input snapshots choose one held direction deterministically,
-- expose each new press exactly once for the movement buffer, and carry the
-- semantic Action/Cancel/Menu buttons as separate edges and held state.
-- Action, Cancel, and Menu track their physical sources: a semantic button
-- stays down until every pressed source is released, and a repeat press
-- from an already-held source never produces a new edge.

local Assert = require("tests.support.Assert")
local FieldInput = require("libs.hgss.src.field.FieldInput")

local T = {}

function T.physical_direction_sources_drive_field_and_ui_from_one_state_machine()
  local input = FieldInput.new()
  input:beginUi(0)

  input:pressDirection("north", "key:w")
  input:pressDirection("north", "gamepad:7:dpup")
  input:setStick("gamepad:7:left", 0, -0.75)

  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = "north", pressedDirection = "north", actionDown = false, cancelDown = false, menuDown = false }
  )
  Assert.deepEqual(input:uiSnapshot(0), { { type = "navigate", direction = "up" } })

  input:releaseDirection("key:w")
  input:releaseDirection("gamepad:7:dpup")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = "north", actionDown = false, cancelDown = false, menuDown = false }
  )
  input:setStick("gamepad:7:left", 0, -0.3)
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = false })
end

function T.additional_sources_for_a_held_direction_do_not_repeat_ui_navigation()
  local input = FieldInput.new()
  input:beginUi(0)

  input:pressDirection("north", "key:w")
  Assert.deepEqual(input:uiSnapshot(0), { { type = "navigate", direction = "up" } })

  input:pressDirection("north", "gamepad:7:dpup")
  Assert.deepEqual(input:uiSnapshot(1), {})
end

function T.pointer_events_exist_only_during_an_active_ui_lifetime()
  local input = FieldInput.new()
  input:pointerMove("mouse:1", 1, 1)
  input:pointerScroll("mouse", 0, -1)
  Assert.deepEqual(input:uiSnapshot(0), {})

  input:beginUi(1)
  input:pointerMove("mouse:1", 2, 2)
  input:pointerScroll("mouse", 0, -1)
  Assert.deepEqual(input:uiSnapshot(1), {
    { type = "pointer_move", pointerId = "mouse:1", x = 2, y = 2 },
    { type = "pointer_scroll", pointerId = "mouse", dx = 0, dy = -1 },
  })

  input:clearUi()
  input:pointerMove("mouse:1", 3, 3)
  Assert.deepEqual(input:uiSnapshot(2), {})
end

function T.latest_press_wins_until_released()
  local input = FieldInput.new()
  input:press("north")
  input:press("east")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = "east", pressedDirection = "east", actionDown = false, cancelDown = false, menuDown = false }
  )
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = "east", actionDown = false, cancelDown = false, menuDown = false }
  )
  input:release("east")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = "north", actionDown = false, cancelDown = false, menuDown = false }
  )
end

function T.repeated_press_does_not_create_another_edge()
  local input = FieldInput.new()
  input:press("south")
  input:snapshot()
  input:press("south")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = "south", actionDown = false, cancelDown = false, menuDown = false }
  )
end

function T.rejects_unknown_directions()
  local input = FieldInput.new()
  Assert.throws(function()
    input:press("up")
  end)
end

function T.rejects_missing_sources()
  local input = FieldInput.new()
  Assert.throws(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- test supplies a missing action source to verify rejection
    input:pressAction(nil)
  end)
  Assert.throws(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- intentional: a nil source must raise
    input:pressCancel(nil)
  end)
  Assert.throws(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- intentional: a non-string source must raise
    input:releaseAction(42)
  end)
  Assert.throws(function()
    input:releaseCancel("")
  end)
end

function T.action_edge_fires_once_while_held_state_persists()
  local input = FieldInput.new()
  input:pressAction("key:z")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = true, actionPressed = true, cancelDown = false, menuDown = false }
  )
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = true, cancelDown = false, menuDown = false })
  input:releaseAction("key:z")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = false })
end

function T.cancel_edge_is_separate_from_action()
  local input = FieldInput.new()
  input:pressCancel("key:x")
  input:pressAction("key:z")
  Assert.deepEqual(input:snapshot(), {
    heldDirection = nil,
    actionDown = true,
    actionPressed = true,
    cancelDown = true,
    cancelPressed = true,
    menuDown = false,
  })
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = true, cancelDown = true, menuDown = false })
  input:releaseCancel("key:x")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = true, cancelDown = false, menuDown = false })
end

function T.clear_edges_keeps_held_state()
  local input = FieldInput.new()
  input:press("west")
  input:pressAction("key:z")
  input:clearEdges()
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = "west", actionDown = true, cancelDown = false, menuDown = false }
  )
  input:releaseAction("key:z")
  input:release("west")
end

function T.clear_all_drops_edges_and_held_state()
  local input = FieldInput.new()
  input:press("north")
  input:pressAction("key:z")
  input:pressCancel("key:x")
  input:clearAll()
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = false })
end

function T.action_stays_down_until_last_keyboard_source_released()
  local input = FieldInput.new()
  input:pressAction("key:enter")
  input:pressAction("key:space")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = true, actionPressed = true, cancelDown = false, menuDown = false }
  )
  input:releaseAction("key:enter")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = true, cancelDown = false, menuDown = false })
  input:releaseAction("key:space")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = false })
end

function T.action_stays_down_across_keyboard_and_gamepad_sources()
  local input = FieldInput.new()
  input:pressAction("key:space")
  input:pressAction("gamepad:1:a")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = true, actionPressed = true, cancelDown = false, menuDown = false }
  )
  input:releaseAction("key:space")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = true, cancelDown = false, menuDown = false })
  input:releaseAction("gamepad:1:a")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = false })
end

function T.repeat_press_from_held_action_source_creates_no_new_edge()
  local input = FieldInput.new()
  input:pressAction("key:space")
  input:snapshot()
  input:pressAction("key:space")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = true, cancelDown = false, menuDown = false })
end

function T.cancel_stays_down_until_last_keyboard_source_released()
  local input = FieldInput.new()
  input:pressCancel("key:x")
  input:pressCancel("key:backspace")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = false, cancelDown = true, cancelPressed = true, menuDown = false }
  )
  input:releaseCancel("key:x")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = true, menuDown = false })
  input:releaseCancel("key:backspace")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = false })
end

function T.cancel_stays_down_across_keyboard_and_gamepad_sources()
  local input = FieldInput.new()
  input:pressCancel("key:x")
  input:pressCancel("gamepad:0:b")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = false, cancelDown = true, cancelPressed = true, menuDown = false }
  )
  input:releaseCancel("gamepad:0:b")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = true, menuDown = false })
  input:releaseCancel("key:x")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = false })
end

function T.repeat_press_from_held_cancel_source_creates_no_new_edge()
  local input = FieldInput.new()
  input:pressCancel("key:x")
  input:snapshot()
  input:pressCancel("key:x")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = true, menuDown = false })
end

function T.action_edge_occurs_only_on_semantic_rise()
  local input = FieldInput.new()
  input:pressAction("key:z")
  input:pressAction("key:space")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = true, actionPressed = true, cancelDown = false, menuDown = false }
  )
  input:releaseAction("key:z")
  input:releaseAction("key:space")
  input:pressAction("key:z")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = true, actionPressed = true, cancelDown = false, menuDown = false }
  )
end

-- A second physical source pressed while the semantic button is already down
-- must not emit another edge: the edge fires only on the zero-to-one source
-- transition. The button rises only after the last source is released.
function T.second_action_source_while_held_produces_no_new_edge()
  local input = FieldInput.new()
  input:pressAction("key:enter")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = true, actionPressed = true, cancelDown = false, menuDown = false }
  )
  input:pressAction("key:space")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = true, cancelDown = false, menuDown = false },
    "a second source while the button is down produces no new edge"
  )
  input:releaseAction("key:space")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = true, cancelDown = false, menuDown = false })
  input:releaseAction("key:enter")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = false })
  input:pressAction("key:enter")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = true, actionPressed = true, cancelDown = false, menuDown = false },
    "the edge fires again on the next rise"
  )
end

function T.second_cancel_source_while_held_produces_no_new_edge()
  local input = FieldInput.new()
  input:pressCancel("key:x")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = false, cancelDown = true, cancelPressed = true, menuDown = false }
  )
  input:pressCancel("key:backspace")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = false, cancelDown = true, menuDown = false },
    "a second source while the button is down produces no new edge"
  )
  input:releaseCancel("key:backspace")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = true, menuDown = false })
  input:releaseCancel("key:x")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = false })
  input:pressCancel("key:x")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = false, cancelDown = true, cancelPressed = true, menuDown = false },
    "the edge fires again on the next rise"
  )
end

function T.cancel_edge_occurs_only_on_semantic_rise()
  local input = FieldInput.new()
  input:pressCancel("key:x")
  input:pressCancel("key:backspace")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = false, cancelDown = true, cancelPressed = true, menuDown = false }
  )
  input:releaseCancel("key:x")
  input:releaseCancel("key:backspace")
  input:pressCancel("key:x")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = false, cancelDown = true, cancelPressed = true, menuDown = false }
  )
end

function T.focus_loss_clears_all_physical_sources()
  local input = FieldInput.new()
  input:pressAction("key:enter")
  input:pressAction("gamepad:0:a")
  input:pressCancel("key:x")
  input:clearAll()
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = false })
  input:releaseAction("key:enter")
  input:releaseAction("gamepad:0:a")
  input:releaseCancel("key:x")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = false })
end

function T.ui_snapshot_normalizes_navigation_buttons_and_key_repeat()
  local input = FieldInput.new({ uiRepeatDelay = 3, uiRepeatInterval = 2 })
  input:beginUi(0)
  input:pressDirection("south", "key:down")
  input:pressAction("key:z")
  input:pressCancel("key:x")

  Assert.deepEqual(input:uiSnapshot(0), {
    { type = "navigate", direction = "down" },
    { type = "confirm" },
    { type = "cancel" },
  })
  Assert.deepEqual(input:uiSnapshot(1), {})
  Assert.deepEqual(input:uiSnapshot(2), {})
  Assert.deepEqual(input:uiSnapshot(3), { { type = "navigate", direction = "down" } })
  Assert.deepEqual(input:uiSnapshot(4), {})
  Assert.deepEqual(input:uiSnapshot(5), { { type = "navigate", direction = "down" } })
end

function T.ui_ticks_must_be_non_negative_integers()
  local input = FieldInput.new()
  local beginErr = Assert.throws(function()
    input:beginUi(-1)
  end)
  Assert.notNil(
    beginErr:find("non-negative integer", 1, true),
    "beginUi rejects negative ticks: " .. tostring(beginErr)
  )
  local snapshotErr = Assert.throws(function()
    input:uiSnapshot(-1)
  end)
  Assert.notNil(
    snapshotErr:find("non-negative integer", 1, true),
    "uiSnapshot rejects negative ticks: " .. tostring(snapshotErr)
  )
  input:beginUi(0)
  Assert.deepEqual(input:uiSnapshot(0), {})
end

function T.ui_stick_uses_hysteresis_and_modal_open_flushes_held_input()
  local input = FieldInput.new({ uiRepeatDelay = 3, uiRepeatInterval = 1 })
  input:beginUi(0)
  input:setStick("gamepad:4:left", -0.7, 0)
  Assert.deepEqual(input:uiSnapshot(0), { { type = "navigate", direction = "left" } })
  input:setStick("gamepad:4:left", -0.5, 0)
  Assert.deepEqual(input:uiSnapshot(1), {})
  input:setStick("gamepad:4:left", -0.3, 0)
  Assert.deepEqual(input:uiSnapshot(2), {})

  input:setStick("gamepad:4:left", 0.7, 0)
  input:beginUi(10)
  Assert.deepEqual(input:uiSnapshot(10), {})
  Assert.deepEqual(input:uiSnapshot(12), {})
  Assert.deepEqual(input:uiSnapshot(13), { { type = "navigate", direction = "right" } })
end

function T.releasing_an_inactive_direction_does_not_reset_active_direction_repeat()
  local input = FieldInput.new({ uiRepeatDelay = 3, uiRepeatInterval = 1 })
  input:beginUi(0)
  input:pressDirection("north", "key:up")
  input:uiSnapshot(0)
  input:pressDirection("east", "key:right")
  input:uiSnapshot(1)
  input:releaseDirection("key:up")

  Assert.deepEqual(input:uiSnapshot(4), { { type = "navigate", direction = "right" } })
end

function T.ui_pointer_events_preserve_touch_drag_discrimination()
  local input = FieldInput.new({ touchDragThreshold = 5 })
  input:beginUi(0)
  input:pointerDown("touch:1", 10, 10)
  input:pointerMove("touch:1", 13, 14)
  input:pointerUp("touch:1", 13, 14)
  input:pointerDown("touch:2", 20, 20)
  input:pointerMove("touch:2", 26, 20)
  input:pointerUp("touch:2", 26, 20)
  input:pointerDown("touch:3", 30, 30)
  input:pointerUp("touch:3", 36, 30)
  input:pointerScroll("mouse", 2, -3)

  Assert.deepEqual(input:uiSnapshot(0), {
    { type = "pointer_down", pointerId = "touch:1", x = 10, y = 10 },
    { type = "pointer_move", pointerId = "touch:1", x = 13, y = 14 },
    { type = "pointer_up", pointerId = "touch:1", x = 13, y = 14, dragged = false },
    { type = "pointer_down", pointerId = "touch:2", x = 20, y = 20 },
    { type = "pointer_move", pointerId = "touch:2", x = 26, y = 20 },
    { type = "pointer_up", pointerId = "touch:2", x = 26, y = 20, dragged = true },
    { type = "pointer_down", pointerId = "touch:3", x = 30, y = 30 },
    { type = "pointer_up", pointerId = "touch:3", x = 36, y = 30, dragged = true },
    { type = "pointer_scroll", pointerId = "mouse", dx = 2, dy = -3 },
  })
end

function T.ui_pointer_state_and_queued_events_clear_on_focus_loss()
  local input = FieldInput.new()
  input:beginUi(0)
  input:pointerDown("touch:1", 1, 1)
  input:clearAll()
  input:pointerUp("touch:1", 1, 1)
  Assert.deepEqual(input:uiSnapshot(0), {})
end

function T.suspended_ui_snapshot_stays_empty_across_the_repeat_window()
  local input = FieldInput.new({ uiRepeatDelay = 3, uiRepeatInterval = 1 })
  input:beginUi(0)
  input:pressDirection("north", "key:up")
  Assert.deepEqual(input:uiSnapshot(0), { { type = "navigate", direction = "up" } })
  input:clearUi()
  for tick = 1, 6 do
    Assert.deepEqual(input:uiSnapshot(tick), {}, "suspended UI emits nothing at tick " .. tick)
  end
  Assert.isTrue(input:isHeld("north"), "suspension preserves the held physical source")
  Assert.equal(input:heldUiDirection(), "up", "suspension preserves the held UI direction")
  input:beginUi(10)
  Assert.deepEqual(input:uiSnapshot(10), {})
  Assert.deepEqual(input:uiSnapshot(12), {})
  Assert.deepEqual(input:uiSnapshot(13), { { type = "navigate", direction = "up" } })
end

function T.suspended_ui_snapshot_discards_queued_edges_without_replay()
  local input = FieldInput.new()
  input:beginUi(0)
  input:clearUi()
  input:pressDirection("south", "key:down")
  input:pressAction("key:z")
  input:pressCancel("key:x")
  Assert.deepEqual(input:uiSnapshot(1), {}, "suspended UI discards hidden edges instead of emitting them")
  input:beginUi(2)
  Assert.deepEqual(input:uiSnapshot(2), {}, "hidden edges never replay after the visible boundary")
  Assert.isTrue(input:isHeld("south"), "discarding hidden edges preserves held physical sources")
end

function T.clear_ui_flushes_modal_events_without_releasing_field_controls()
  local input = FieldInput.new()
  input:press("north")
  input:pressDirection("north", "key:up")
  input:beginUi(0)
  input:pointerDown("touch:1", 1, 1)
  input:clearUi()
  input:pointerUp("touch:1", 1, 1)

  Assert.deepEqual(input:uiSnapshot(0), {})
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = "north", pressedDirection = "north", actionDown = false, cancelDown = false, menuDown = false }
  )
end

-- The semantic Menu button follows the Action/Cancel ownership model exactly:
-- one edge per zero-to-one source transition, consumed once by a snapshot,
-- held state separate from the edge, and focus loss clearing the sources so a
-- stray release cannot resurrect the button. FieldState maps keyboard "m" and
-- the gamepad west face ("x") to it; the source-aware model is pinned here.

function T.menu_button_edge_fires_once_while_held_state_persists()
  local input = FieldInput.new()
  input:pressMenu("key:m")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = true, menuPressed = true }
  )
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = true })
  input:releaseMenu("key:m")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = false })
end

function T.menu_button_stays_down_until_last_source_released()
  local input = FieldInput.new()
  input:pressMenu("key:m")
  input:pressMenu("gamepad:0:x")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = true, menuPressed = true }
  )
  input:releaseMenu("key:m")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = true })
  input:releaseMenu("gamepad:0:x")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = false })
  input:pressMenu("key:m")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = true, menuPressed = true },
    "the edge fires again on the next rise"
  )
end

function T.repeat_press_from_held_menu_source_creates_no_new_edge()
  local input = FieldInput.new()
  input:pressMenu("key:m")
  input:snapshot()
  input:pressMenu("key:m")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = true })
end

function T.menu_button_is_independent_from_action_and_cancel()
  local input = FieldInput.new()
  input:pressAction("key:z")
  input:pressCancel("key:x")
  input:pressMenu("key:m")
  Assert.deepEqual(input:snapshot(), {
    heldDirection = nil,
    actionDown = true,
    actionPressed = true,
    cancelDown = true,
    cancelPressed = true,
    menuDown = true,
    menuPressed = true,
  })
  input:clearAll()
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = false })
end

function T.clear_edges_keeps_the_held_menu_button_down()
  local input = FieldInput.new()
  input:pressMenu("key:m")
  input:clearEdges()
  Assert.equal(input.menuDown, true, "edge clears must keep the held menu button down")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = true })
end

function T.menu_focus_loss_clears_sources_so_a_stray_release_cannot_resurrect()
  local input = FieldInput.new()
  input:pressMenu("key:m")
  input:pressMenu("gamepad:0:x")
  input:clearAll()
  Assert.equal(input.menuDown, false, "focus loss must clear the held menu button")
  input:releaseMenu("key:m")
  input:releaseMenu("gamepad:0:x")
  Assert.equal(input.menuDown, false, "a stray release after focus loss must not resurrect the menu button")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = false })
end

function T.menu_release_never_produces_a_press_edge()
  local input = FieldInput.new()
  input:releaseMenu("key:m")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = false },
    "a release with no held source produces no edge"
  )
  input:pressMenu("key:m")
  input:snapshot()
  input:releaseMenu("key:m")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = false },
    "a release must never produce a menu press edge"
  )
end

function T.menu_begin_ui_flushes_the_pending_edge_but_keeps_held_state()
  local input = FieldInput.new()
  input:pressMenu("key:m")
  input:beginUi(0)
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = true },
    "the stale opening edge must not survive modal ownership begin"
  )
  input:releaseMenu("key:m")
  input:pressMenu("key:m")
  Assert.equal(input:snapshot().menuPressed, true, "a fresh press inside the modal lifetime produces a new edge")
end

function T.transient_reset_keeps_the_active_modal_lifetime_for_fresh_input()
  local input = FieldInput.new()
  input:beginUi(0)
  input:pressDirection("north", "key:up")
  input:pressAction("key:z")
  input:pointerDown("touch:1", 10, 10)
  input:clearAll()
  Assert.deepEqual(input:uiSnapshot(1), {}, "stale modal edges must not survive the transient reset")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = false },
    "the transient reset clears stale held physical sources"
  )
  input:pointerUp("touch:1", 10, 10)
  Assert.deepEqual(input:uiSnapshot(2), {}, "a stale release after capture reset emits nothing")
  input:pressDirection("south", "key:down")
  input:pressAction("key:enter")
  Assert.deepEqual(input:uiSnapshot(3), {
    { type = "navigate", direction = "down" },
    { type = "confirm" },
  }, "fresh input after the reset reaches the still-active modal lifetime")

  local idle = FieldInput.new()
  idle:clearAll()
  idle:pressDirection("south", "key:down")
  idle:pressAction("key:z")
  Assert.deepEqual(idle:uiSnapshot(4), {}, "the reset must not invent a modal lifetime")
end

function T.menu_rejects_missing_sources()
  local input = FieldInput.new()
  Assert.throws(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- test supplies a missing menu source to verify rejection
    input:pressMenu(nil)
  end)
  Assert.throws(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- intentional: a nil source must raise
    input:releaseMenu(nil)
  end)
  Assert.throws(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- intentional: a non-string source must raise
    input:pressMenu(42)
  end)
  Assert.throws(function()
    input:releaseMenu("")
  end)
end

return { tests = T }
