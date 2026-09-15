-- The pure Start Menu controller: final interactive action display,
-- selection, the folded-in fixed-tick cursor animation, confirm/cancel/
-- menu-key close, and touch/pointer slot interaction. The controller
-- receives the runtime-composed final action list (each entry already
-- intersected with the registered destination capabilities, carrying only
-- id / targetApplication / displayPosition) and the generated manifest slot
-- surface; it carries no labels, no product-mode projections, and no
-- capability or progression knowledge. The final list is never empty -- the
-- menu factory returns nil when no action is interactive -- so the
-- controller's invariants are that at least one action exists, every
-- display position fits the slot surface, and the selection always resolves.
-- The cursor animation is the manifest frame durations stepped exactly once
-- per fixed tick. The controller is silent: it never names a ROM sequence
-- and never touches love. No application launches happen here: the
-- controller records the takeResult contract and the host launches.

local Assert = require("tests.support.Assert")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local StartMenuController = require("libs.hgss.src.ui.StartMenuController")

local T = {}

local SLOTS = FieldUiFixture.START_MENU_SLOTS
local CURSOR_FRAMES = FieldUiFixture.START_MENU_CURSOR_FRAMES

-- The full-progression interactive list (every destination registered):
-- display positions 0..6 plus the special Pokégear-family entries at the
-- reserved positions 7/8.
local function fullEntries()
  return {
    { id = "vanilla.pokedex", targetApplication = "pokedex", actionKind = "application", displayPosition = 0 },
    { id = "vanilla.pokemon", targetApplication = "pokemon", actionKind = "application", displayPosition = 1 },
    { id = "vanilla.bag", targetApplication = "bag", actionKind = "application", displayPosition = 2 },
    { id = "vanilla.pokegear", targetApplication = "pokegear", actionKind = "application", displayPosition = 3 },
    {
      id = "vanilla.trainer_card",
      targetApplication = "trainer_card",
      actionKind = "application",
      displayPosition = 4,
    },
    { id = "vanilla.save", targetApplication = "save", actionKind = "application", displayPosition = 5 },
    { id = "vanilla.options", targetApplication = "options", actionKind = "application", displayPosition = 6 },
    { id = "vanilla.special_9", targetApplication = "pokegear", actionKind = "application", displayPosition = 7 },
    { id = "vanilla.special_10", targetApplication = "pokegear", actionKind = "application", displayPosition = 8 },
  }
end

---@param opts table?
---@return StartMenuController
local function newController(opts)
  opts = opts or {}
  local controller = StartMenuController.new({
    entries = opts.entries ~= nil and opts.entries or fullEntries(),
    slots = opts.slots or SLOTS,
    cursorFrames = opts.cursorFrames or CURSOR_FRAMES,
    rememberedActionId = opts.rememberedActionId,
  })
  return controller
end

local function slotCenter(slotId)
  local rect = assert(SLOTS[slotId], "fixture slot " .. slotId .. " required")
  return rect.x + rect.width / 2, rect.y + rect.height / 2
end

function T.construction_succeeds_with_only_the_documented_options()
  local controller = newController()
  Assert.equal(controller:status().open, true)
end

function T.visible_actions_follow_positions_and_slot_ids()
  local controller = newController()
  local status = controller:status()
  Assert.equal(status.open, true)
  Assert.equal(status.cancelSlotId, 1, "the cancel touch region is slot 1")
  Assert.deepEqual(status.actions, {
    { id = "vanilla.pokedex", targetApplication = "pokedex", position = 0, slotId = 2, enabled = true },
    { id = "vanilla.pokemon", targetApplication = "pokemon", position = 1, slotId = 3, enabled = true },
    { id = "vanilla.bag", targetApplication = "bag", position = 2, slotId = 4, enabled = true },
    { id = "vanilla.pokegear", targetApplication = "pokegear", position = 3, slotId = 5, enabled = true },
    { id = "vanilla.trainer_card", targetApplication = "trainer_card", position = 4, slotId = 6, enabled = true },
    { id = "vanilla.save", targetApplication = "save", position = 5, slotId = 7, enabled = true },
    { id = "vanilla.options", targetApplication = "options", position = 6, slotId = 8, enabled = true },
    { id = "vanilla.special_9", targetApplication = "pokegear", position = 7, slotId = 9, enabled = true },
    { id = "vanilla.special_10", targetApplication = "pokegear", position = 8, slotId = 10, enabled = true },
  })
  Assert.equal(status.cursorSlotId, 2, "the default selection is the first visible action")
  Assert.equal(status.cursorFrameIndex, 0, "a selected menu presents the cursor animation frame")
end

function T.actions_carry_id_destination_position_slot_and_enabled()
  local actions = newController():status().actions
  for _, action in ipairs(actions) do
    local keys = {}
    for key in pairs(action) do
      keys[#keys + 1] = key
    end
    table.sort(keys)
    Assert.deepEqual(
      keys,
      { "enabled", "id", "position", "slotId", "targetApplication" },
      "status actions include enabled flag"
    )
  end
end

function T.status_preserves_source_and_implementation_capabilities()
  local controller = newController({
    entries = {
      {
        id = "vanilla.trainer_card",
        targetApplication = "trainer_card",
        actionKind = "application",
        displayPosition = 0,
        sourcePresent = true,
        sourceEnabled = true,
        implemented = true,
        enabled = true,
      },
      {
        id = "vanilla.options",
        targetApplication = "options",
        actionKind = "application",
        displayPosition = 1,
        sourcePresent = true,
        sourceEnabled = true,
        implemented = false,
        enabled = false,
      },
    },
  })
  Assert.deepEqual(controller:status().actions, {
    {
      id = "vanilla.trainer_card",
      targetApplication = "trainer_card",
      position = 0,
      slotId = 2,
      enabled = true,
      sourcePresent = true,
      sourceEnabled = true,
      implemented = true,
    },
    {
      id = "vanilla.options",
      targetApplication = "options",
      position = 1,
      slotId = 3,
      enabled = false,
      sourcePresent = true,
      sourceEnabled = true,
      implemented = false,
    },
  })
end

function T.selection_and_close_emit_source_effects()
  local effects = {}
  local controller = StartMenuController.new({
    entries = fullEntries(),
    slots = SLOTS,
    cursorFrames = CURSOR_FRAMES,
    effect = function(sequence)
      effects[#effects + 1] = sequence
    end,
  })
  controller:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(effects, { "SEQ_SE_DP_SELECT" })
  local closing = StartMenuController.new({
    entries = fullEntries(),
    slots = SLOTS,
    cursorFrames = CURSOR_FRAMES,
    effect = function(sequence)
      effects[#effects + 1] = sequence
    end,
  })
  closing:updateFixed({ { type = "cancel" } })
  Assert.equal(effects[#effects], "SEQ_SE_GS_GEARCANCEL")
end

function T.selection_restores_by_remembered_action_id()
  local controller = newController({ rememberedActionId = "vanilla.bag" })
  Assert.equal(controller:status().cursorSlotId, 4, "the remembered action restores its display slot")
end

function T.selection_falls_back_to_the_first_action_when_the_remembered_id_is_absent()
  local controller = newController({ rememberedActionId = "vanilla.running_shoes" })
  Assert.equal(controller:status().cursorSlotId, 2, "an absent remembered id falls back to the first action")
end

function T.directional_navigation_follows_the_source_two_column_topology()
  local controller = newController({
    entries = {
      {
        id = "vanilla.trainer_card",
        targetApplication = "trainer_card",
        actionKind = "application",
        displayPosition = 0,
        enabled = false,
      },
      {
        id = "vanilla.running_shoes",
        targetApplication = "running_shoes",
        actionKind = "application",
        displayPosition = 1,
      },
      { id = "vanilla.bag", targetApplication = "bag", actionKind = "application", displayPosition = 2 },
      {
        id = "vanilla.special_9",
        targetApplication = "pokegear",
        actionKind = "application",
        displayPosition = 7,
        enabled = false,
      },
      { id = "vanilla.special_10", targetApplication = "pokegear", actionKind = "application", displayPosition = 8 },
    },
  })
  Assert.equal(controller:status().cursorSlotId, 2, "the first visible action starts in the right column")

  controller:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(controller:status().cursorSlotId, 2, "right stays when the same row has no other visible action")

  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(controller:status().cursorSlotId, 4, "down scans the same column and skips the missing left slot")

  controller:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.equal(controller:status().cursorSlotId, 3, "left selects the visible action in the same row")

  controller:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(controller:status().cursorSlotId, 9, "up wraps through the same column to the last visible row")

  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(controller:status().cursorSlotId, 3, "down wraps through the same column to the first visible row")

  controller:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(controller:status().cursorSlotId, 4, "right selects the visible action in the same row")

  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(controller:status().cursorSlotId, 10, "down scans and wraps in the right column")
  controller:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.equal(controller:status().cursorSlotId, 9, "left selects the visible disabled action in the same row")
  controller:updateFixed({ { type = "confirm" } })
  Assert.isNil(controller:takeResult(), "a visible disabled action remains selectable but cannot activate")
  Assert.equal(controller:status().open, true, "a disabled activation leaves the menu open")
end

function T.navigation_skips_holes_in_the_display_array()
  local controller = newController({
    entries = {
      { id = "vanilla.trainer_card", targetApplication = "trainer_card", displayPosition = 0 },
      { id = "vanilla.save", targetApplication = "save", displayPosition = 1 },
      { id = "vanilla.options", targetApplication = "options", displayPosition = 2 },
      { id = "vanilla.special_9", targetApplication = "pokegear", displayPosition = 7 },
      { id = "vanilla.special_10", targetApplication = "pokegear", displayPosition = 8 },
    },
  })
  -- positions 0,1,2,7,8 are filled; 3..6 are holes.
  for _ = 1, 2 do
    controller:updateFixed({ { type = "navigate", direction = "down" } })
  end
  Assert.equal(controller:status().cursorSlotId, 10, "navigation must skip empty display positions")
end

function T.confirm_launches_the_selected_application()
  local controller = newController()
  controller:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(controller:takeResult(), {
    kind = "launch",
    applicationId = "pokedex",
    actionId = "vanilla.pokedex",
  })
  Assert.equal(controller:status().open, false, "a taken result ends the menu lifetime")
end

function T.confirming_a_field_action_emits_a_field_action_result()
  local controller = newController({
    entries = {
      { id = "vanilla.save", actionKind = "field_action", displayPosition = 0, enabled = true },
    },
  })
  controller:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(controller:takeResult(), { kind = "field_action", actionId = "vanilla.save" })
end

function T.cancel_and_the_menu_event_close()
  local controller = newController()
  controller:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(controller:takeResult(), { kind = "close" })

  local menuController = newController()
  menuController:updateFixed({ { type = "menu" } })
  Assert.deepEqual(menuController:takeResult(), { kind = "close" })
end

function T.a_terminal_event_ends_the_ticks_processing()
  local closeFirst = newController()
  closeFirst:updateFixed({ { type = "cancel" }, { type = "confirm" } })
  Assert.deepEqual(closeFirst:takeResult(), { kind = "close" }, "a close before a confirm in one tick must win")
  Assert.equal(closeFirst:status().open, false)

  local confirmFirst = newController()
  confirmFirst:updateFixed({ { type = "confirm" }, { type = "cancel" } })
  Assert.deepEqual(
    confirmFirst:takeResult(),
    { kind = "launch", applicationId = "pokedex", actionId = "vanilla.pokedex" },
    "a confirm before a cancel in one tick must win"
  )
end

function T.take_result_is_exactly_once_and_terminal()
  local controller = newController()
  controller:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(controller:takeResult(), { kind = "close" })
  Assert.isNil(controller:takeResult(), "the result is consumed exactly once")
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(controller:status().open, false, "a terminal controller stays closed")
end

function T.pointer_hover_moves_selection_without_activating()
  local controller = newController()
  local x, y = slotCenter(5)
  controller:updateFixed({ { type = "pointer_move", pointerId = "mouse:1", x = x, y = y } })
  Assert.equal(controller:status().cursorSlotId, 5, "hover selects the hovered slot")
end

function T.pointer_down_up_on_the_same_action_slot_activates()
  local controller = newController()
  local x, y = slotCenter(6)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  Assert.equal(controller:status().cursorSlotId, 6, "pointer down selects the pressed slot")
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y, dragged = false } })
  Assert.deepEqual(controller:takeResult(), {
    kind = "launch",
    applicationId = "trainer_card",
    actionId = "vanilla.trainer_card",
  })
end

function T.pointer_down_up_mismatch_and_drag_discard_the_activation()
  local mismatch = newController()
  local downX, downY = slotCenter(4)
  local upX, upY = slotCenter(5)
  mismatch:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = downX, y = downY } })
  mismatch:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = upX, y = upY, dragged = false } })
  Assert.isNil(mismatch:takeResult(), "a down/up mismatch must not activate")
  Assert.equal(mismatch:status().open, true)

  local dragged = newController()
  dragged:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = downX, y = downY } })
  dragged:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = downX, y = downY, dragged = true } })
  Assert.isNil(dragged:takeResult(), "a drag must not activate")
  Assert.equal(dragged:status().open, true)
end

function T.pointer_cancel_slot_down_up_closes()
  local controller = newController()
  local x, y = slotCenter(1)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y, dragged = false } })
  Assert.deepEqual(controller:takeResult(), { kind = "close" })
end

function T.pointer_cancel_mismatch_and_drag_do_not_close()
  local mismatch = newController()
  local x, y = slotCenter(1)
  local otherX, otherY = slotCenter(2)
  mismatch:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  mismatch:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = otherX, y = otherY, dragged = false } })
  Assert.isNil(mismatch:takeResult(), "a cancel-slot down/up mismatch must not close")
  Assert.equal(mismatch:status().open, true)

  local dragged = newController()
  dragged:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  dragged:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y, dragged = true } })
  Assert.isNil(dragged:takeResult(), "a dragged cancel press must not close")
  Assert.equal(dragged:status().open, true)
end

function T.pointer_capture_ignores_other_pointers()
  local controller = newController()
  local firstX, firstY = slotCenter(6)
  local secondX, secondY = slotCenter(10)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = firstX, y = firstY } })
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:2", x = secondX, y = secondY } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:2", x = secondX, y = secondY, dragged = false } })
  Assert.isNil(controller:takeResult(), "a second pointer cannot steal the capture")
  Assert.equal(controller:status().open, true)
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = firstX, y = firstY, dragged = false } })
  Assert.deepEqual(controller:takeResult(), {
    kind = "launch",
    applicationId = "trainer_card",
    actionId = "vanilla.trainer_card",
  })
end

-- A placement change cancels the active pointer capture, so a press held
-- across a layout change cannot activate a different post-change slot.
function T.cancel_pointer_capture_discards_the_held_press()
  local controller = newController()
  local x, y = slotCenter(6)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  controller:cancelPointerCapture()
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y, dragged = false } })
  Assert.isNil(controller:takeResult(), "a cancelled capture cannot activate")
  Assert.equal(controller:status().open, true)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y, dragged = false } })
  Assert.notNil(controller:takeResult(), "a fresh press after the cancellation works normally")
end

function T.pointer_press_outside_any_slot_does_not_move_selection()
  local controller = newController()
  controller:updateFixed({ { type = "pointer_move", pointerId = "mouse:1", x = 255, y = 191 } })
  Assert.equal(controller:status().cursorSlotId, 2, "a point outside the slot grid changes nothing")
end

function T.pointer_over_an_empty_display_position_changes_nothing()
  -- Display positions 4..6 are holes in this list, so slots 6..8 have no
  -- action.
  local controller = newController({
    entries = {
      { id = "vanilla.trainer_card", targetApplication = "trainer_card", displayPosition = 0 },
      { id = "vanilla.save", targetApplication = "save", displayPosition = 1 },
      { id = "vanilla.options", targetApplication = "options", displayPosition = 2 },
      { id = "vanilla.special_9", targetApplication = "pokegear", displayPosition = 7 },
      { id = "vanilla.special_10", targetApplication = "pokegear", displayPosition = 8 },
    },
  })
  local x, y = slotCenter(7)
  controller:updateFixed({ { type = "pointer_move", pointerId = "mouse:1", x = x, y = y } })
  Assert.equal(controller:status().cursorSlotId, 2, "hovering an empty slot must not move the selection")
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y, dragged = false } })
  Assert.isNil(controller:takeResult(), "a press on an empty slot must not activate anything")
  Assert.equal(controller:status().open, true)
end

-- The cursor animation is folded into the controller: the manifest frame
-- durations are stepped exactly once per fixed tick.
function T.cursor_animation_advances_on_fixed_ticks_while_selected()
  local controller = newController()
  -- Fixture frames: frame 0 holds 22 ticks, frame 1 holds 11.
  for _ = 1, 21 do
    controller:updateFixed({})
  end
  Assert.equal(controller:status().cursorFrameIndex, 0, "the first frame holds for its duration")
  controller:updateFixed({})
  Assert.equal(controller:status().cursorFrameIndex, 1, "the animation advances exactly once per fixed tick")
end

function T.dispose_is_idempotent_and_discards_a_pending_result()
  local controller = newController()
  controller:updateFixed({ { type = "cancel" } })
  controller:dispose()
  controller:dispose()
  Assert.equal(controller:status().open, false)
  Assert.isNil(controller:takeResult(), "dispose discards the pending result")
end

-- The constructor guards the real controller invariants: the final list is
-- never empty (the menu factory returns nil instead), every display position
-- fits the manifest slot surface, and the cursor animation has frames.
function T.construction_guards_the_controller_invariants()
  local function with(overrides)
    local opts = {
      entries = fullEntries(),
      slots = SLOTS,
      cursorFrames = CURSOR_FRAMES,
    }
    for key, value in pairs(overrides) do
      opts[key] = value
    end
    return opts
  end
  Assert.throws(function()
    StartMenuController.new(with({ entries = {} }))
  end, "a blank menu is never constructed -- the factory returns nil")
  Assert.throws(function()
    StartMenuController.new(
      with({ entries = { { id = "vanilla.save", targetApplication = "save", displayPosition = 9 } } })
    )
  end, "a position beyond the slot capacity is rejected")
  Assert.throws(function()
    StartMenuController.new(with({ cursorFrames = {} }))
  end, "the cursor animation requires frames")
end

-- Disabled entries (enabled=false) are visible and selectable but do not
-- activate on confirm or pointer tap.
function T.disabled_entries_are_visible_and_selectable()
  local mixed = {
    { id = "vanilla.trainer_card", targetApplication = "trainer_card", displayPosition = 0, enabled = true },
    { id = "vanilla.save", targetApplication = "save", displayPosition = 2, enabled = false },
    { id = "vanilla.options", targetApplication = "options", displayPosition = 3, enabled = true },
  }
  local controller = newController({ entries = mixed })
  local status = controller:status()
  Assert.equal(#status.actions, 3, "disabled entries appear in the visible list")
  Assert.equal(status.actions[2].id, "vanilla.save", "disabled entry is at its display position")
end

-- Confirming on a disabled entry is a no-op: the menu stays open,
-- no result is taken, and the selection is unchanged.
function T.confirming_disabled_entry_is_noop()
  local mixed = {
    { id = "vanilla.trainer_card", targetApplication = "trainer_card", displayPosition = 0, enabled = true },
    { id = "vanilla.save", targetApplication = "save", displayPosition = 2, enabled = false },
  }
  local controller = newController({ entries = mixed })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  local selectedBefore = controller:status().cursorSlotId
  controller:updateFixed({ { type = "confirm" } })
  Assert.isNil(controller:takeResult(), "confirming disabled entry produces no result")
  Assert.equal(controller:status().open, true, "menu remains open")
  Assert.equal(controller:status().cursorSlotId, selectedBefore, "selection unchanged")
end

-- Pointer tap on a disabled entry is a no-op.
function T.pointer_tap_on_disabled_entry_is_noop()
  local mixed = {
    { id = "vanilla.trainer_card", targetApplication = "trainer_card", displayPosition = 0, enabled = true },
    { id = "vanilla.save", targetApplication = "save", displayPosition = 1, enabled = false },
  }
  local controller = newController({ entries = mixed })
  local x, y = slotCenter(3) -- slot 3 is the disabled save action
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y, dragged = false } })
  Assert.isNil(controller:takeResult(), "tap on disabled entry produces no result")
  Assert.equal(controller:status().open, true, "menu remains open")
end

-- An enabled action whose kind has no implemented routing is a programming
-- fault: the runtime must never compose enabled=true for a non-application
-- action, so activating one is an error, never a silent close.
function T.confirming_an_enabled_non_application_action_errors()
  local controller = newController({
    entries = {
      { id = "vanilla.running_shoes", actionKind = "toggle", displayPosition = 0, enabled = true },
    },
  })
  Assert.throws(function()
    controller:updateFixed({ { type = "confirm" } })
  end, "an enabled action with unimplemented routing must error, not silently close")
end

-- Status output includes enabled field for each action.
function T.status_includes_enabled_field()
  local mixed = {
    { id = "vanilla.trainer_card", targetApplication = "trainer_card", displayPosition = 0, enabled = true },
    { id = "vanilla.save", targetApplication = "save", displayPosition = 1, enabled = false },
  }
  local controller = newController({ entries = mixed })
  local actions = controller:status().actions
  Assert.equal(actions[1].enabled, true, "enabled action has enabled=true")
  Assert.equal(actions[2].enabled, false, "disabled action has enabled=false")
end

return { tests = T }
