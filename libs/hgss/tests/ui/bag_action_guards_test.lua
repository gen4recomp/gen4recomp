-- Controller-level guards for the field Bag action surface: protected
-- items never offer a toss path, canonical-order pockets never offer a move
-- path, cancelled quantity/confirmation states never mutate, overflow adds
-- never mutate, and the menu never carries anything outside the
-- inventory-local action set. Real inventory service, cursor, and layout
-- geometry with the synthetic item catalog; only the view model is injected
-- and the mutation commands bind straight through to the live service. No
-- love, no GPU.

local Assert = require("tests.support.Assert")
local BagActionPolicy = require("libs.hgss.src.ui.BagActionPolicy")
local BagController = require("libs.hgss.src.ui.BagController")
local BagCursor = require("libs.hgss.src.items.BagCursor")
local BagLayout = require("libs.hgss.src.ui.BagLayout")
local BagModel = require("libs.hgss.src.ui.BagModel")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local ItemFixture = require("libs.items.tests.item_fixture")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = {}

local TAB_RECTS = {
  { x = 0, y = 0, width = 32, height = 32 },
  { x = 32, y = 0, width = 32, height = 32 },
  { x = 64, y = 0, width = 32, height = 32 },
  { x = 96, y = 0, width = 32, height = 32 },
  { x = 128, y = 0, width = 32, height = 32 },
  { x = 160, y = 0, width = 32, height = 32 },
  { x = 192, y = 0, width = 32, height = 32 },
  { x = 224, y = 0, width = 32, height = 32 },
}

local SLOT_RECTS = {
  { x = 32, y = 40, width = 88, height = 32 },
  { x = 160, y = 40, width = 88, height = 32 },
  { x = 32, y = 80, width = 88, height = 32 },
  { x = 160, y = 80, width = 88, height = 32 },
  { x = 32, y = 120, width = 88, height = 32 },
  { x = 160, y = 120, width = 88, height = 32 },
}

local function manifest()
  local tabs = {}
  for index, rect in ipairs(TAB_RECTS) do
    tabs[index] = { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
  end
  local slots = {}
  for index, rect in ipairs(SLOT_RECTS) do
    slots[index] = {
      rect = { x = rect.x, y = rect.y, width = rect.width, height = rect.height },
      iconCenter = { x = rect.x + 16, y = rect.y + 16 },
    }
  end
  return {
    interactive = {
      pocketTabs = { rects = tabs },
      itemSlots = { slots = slots },
      pageIndicator = { rect = { x = 80, y = 168, width = 56, height = 16 }, textAt = { x = 0, y = 0 } },
      cancel = { x = 192, y = 168, width = 56, height = 16 },
      overlays = {
        descriptionFallback = { frame = { x = 0, y = 144, width = 256, height = 48 } },
        actionMenu = {
          buttons = {
            { x = 8, y = 136, width = 80, height = 16 },
            { x = 104, y = 136, width = 80, height = 16 },
            { x = 8, y = 168, width = 80, height = 16 },
            { x = 104, y = 168, width = 80, height = 16 },
          },
        },
      },
    },
  }
end

local function topology()
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 512, height = 384 },
    touch = false,
    role = "world",
  })
end

local function service()
  return HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
end

-- The injected command boundary binds straight through to the live service:
-- the controller owns state transitions while the service stays the one
-- mutation authority.
local function commands(bag)
  return {
    toss = function(itemKey, quantity)
      return bag:take(itemKey, quantity)
    end,
    move = function(pocketKey, fromIndex, toIndex)
      return bag:move(pocketKey, fromIndex, toIndex)
    end,
    register = function(itemKey)
      return bag:tryRegister(itemKey)
    end,
    unregister = function(itemKey)
      return bag:unregister(itemKey)
    end,
  }
end

---@param bag HgssBagService
---@param cursor BagCursor
---@param layoutManifest table<string, unknown>?
---@return BagController
local function controller(bag, cursor, layoutManifest)
  layoutManifest = layoutManifest or manifest()
  local function resolveLayout()
    return BagLayout.resolve({ topology = topology(), manifest = layoutManifest })
  end
  return BagController.new({
    model = {
      refresh = function()
        return BagModel.build(bag, cursor)
      end,
    },
    cursor = cursor,
    resolveLayout = resolveLayout,
    commands = commands(bag),
    resolveActions = BagActionPolicy.forService(bag),
  })
end

-- The same geometry plus the compiled action-menu button rectangles, so
-- pointer taps can reach the same semantic actions keyboard input chooses.
local function manifestWithButtons()
  local layoutManifest = manifest()
  layoutManifest.interactive.overlays.actionMenu = {
    buttons = {
      { x = 8, y = 136, width = 80, height = 16 },
      { x = 104, y = 136, width = 80, height = 16 },
      { x = 8, y = 168, width = 80, height = 16 },
      { x = 104, y = 168, width = 80, height = 16 },
    },
  }
  return layoutManifest
end

local function hostAt(layout, logicalX, logicalY)
  local frame = layout.interactive.frame
  local scale = layout.interactive.scale
  return frame.x + logicalX * scale, frame.y + logicalY * scale
end

local function tap(control, layout, logicalX, logicalY)
  local x, y = hostAt(layout, logicalX, logicalY)
  control:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = x, y = y } })
  control:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = x, y = y } })
end

local function navigate(direction)
  return { type = "navigate", direction = direction }
end

local function confirmEvent()
  return { type = "confirm" }
end

local function cancelEvent()
  return { type = "cancel" }
end

local function selectedKey(status)
  local selected = status.selected
  if selected == nil then
    return nil
  end
  return selected.item
end

-- Confirming the selected item must open the action menu.
local function openActionMenu(control)
  control:updateFixed({ confirmEvent() })
  local view = control:status()
  Assert.equal(view.state, "action_menu", "confirming an item must open the action menu")
  Assert.isTrue(
    type(view.actions) == "table" and #view.actions >= 2,
    "the action menu must offer an action plus cancel"
  )
  return view
end

local function hasAction(view, id)
  for _, action in ipairs(assert(view.actions, "the action menu must list its actions")) do
    if action.id == id then
      return true
    end
  end
  return false
end

local function selectedActionId(view)
  local actions = assert(view.actions, "the action menu must list its actions")
  local selection = view.selectedAction
  assert(type(selection) == "number", "the action menu must expose its selection")
  local record = assert(actions[selection + 1], "the selected action must resolve")
  return assert(record.id, "the selected action must carry its id")
end

-- Drive the action menu selection to the wanted semantic action through
-- ordinary vertical input, then confirm it.
local function chooseAction(control, id)
  local view = control:status()
  Assert.equal(view.state, "action_menu", "choosing an action requires the open action menu")
  local count = #assert(view.actions, "the action menu must list its actions")
  for _ = 1, count + 1 do
    if selectedActionId(control:status()) == id then
      control:updateFixed({ confirmEvent() })
      return control:status()
    end
    control:updateFixed({ navigate("down") })
  end
  error("the action menu never selects " .. id, 0)
end

-- Return to plain browsing from any nested action state through bounded
-- cancel presses.
local function backToBrowsing(control)
  for _ = 1, 6 do
    local view = control:status()
    if view.state == nil or view.state == "browsing" then
      return view
    end
    control:updateFixed({ cancelEvent() })
  end
  error("cancel never returns the bag to browsing", 0)
end

function T.protected_item_never_offers_toss()
  local bag = service()
  Assert.isTrue(bag:add("BICYCLE", 1), "setup stocks the protected key item")
  local cursor = BagCursor.new()
  cursor:setPocket("key_items")
  local control = controller(bag, cursor)
  Assert.equal(selectedKey(control:status()), "BICYCLE")
  local revision = bag:revision()
  local view = openActionMenu(control)
  Assert.isFalse(hasAction(view, "toss"), "a protected item must not offer to toss")
  backToBrowsing(control)
  Assert.equal(bag:revision(), revision, "browsing a protected item must not mutate the inventory")
  Assert.equal(bag:quantity("BICYCLE"), 1, "browsing a protected item must not change quantities")
end

function T.canonical_machine_pocket_never_offers_move()
  local bag = service()
  Assert.isTrue(bag:add("TM01", 1), "setup stocks a first machine")
  Assert.isTrue(bag:add("HM01", 1), "setup stocks a second machine")
  local cursor = BagCursor.new()
  cursor:setPocket("tmhm")
  local control = controller(bag, cursor)
  local revision = bag:revision()
  local view = openActionMenu(control)
  Assert.isFalse(hasAction(view, "move"), "a canonical-order pocket must not offer to move")
  backToBrowsing(control)
  Assert.equal(bag:revision(), revision, "browsing a machine must not mutate the inventory")
end

function T.canonical_berry_pocket_never_offers_move()
  local bag = service()
  Assert.isTrue(bag:add("CHERI_BERRY", 3), "setup stocks a first berry")
  Assert.isTrue(bag:add("SITRUS_BERRY", 2), "setup stocks a second berry")
  local cursor = BagCursor.new()
  cursor:setPocket("berries")
  local control = controller(bag, cursor)
  local revision = bag:revision()
  local view = openActionMenu(control)
  Assert.isFalse(hasAction(view, "move"), "a canonical-order pocket must not offer to move")
  backToBrowsing(control)
  Assert.equal(bag:revision(), revision, "browsing a berry must not mutate the inventory")
end

function T.cancelled_quantity_never_mutates()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a tossable item")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control = controller(bag, cursor)
  local view = openActionMenu(control)
  Assert.isTrue(hasAction(view, "toss"), "a tossable item must offer to toss")
  view = chooseAction(control, "toss")
  Assert.equal(view.state, "toss_quantity", "choosing toss must enter the quantity picker")
  local revision = bag:revision()
  control:updateFixed({ navigate("right") })
  backToBrowsing(control)
  Assert.equal(bag:revision(), revision, "cancelling the quantity picker must not mutate the inventory")
  Assert.equal(bag:quantity("POTION"), 5, "cancelling the quantity picker must not change quantities")
end

function T.cancelled_confirmation_never_mutates()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a tossable item")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control = controller(bag, cursor)
  local view = openActionMenu(control)
  view = chooseAction(control, "toss")
  Assert.equal(view.state, "toss_quantity", "choosing toss must enter the quantity picker")
  control:updateFixed({ confirmEvent() })
  view = control:status()
  Assert.equal(view.state, "toss_confirm", "confirming a quantity must ask for confirmation")
  local revision = bag:revision()
  backToBrowsing(control)
  Assert.equal(bag:revision(), revision, "cancelling the confirmation must not mutate the inventory")
  Assert.equal(bag:quantity("POTION"), 5, "cancelling the confirmation must not change quantities")
end

function T.action_menu_carries_only_inventory_local_actions()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a tossable manual-order item")
  Assert.isTrue(bag:add("BICYCLE", 1), "setup stocks a registerable key item")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control = controller(bag, cursor)
  local revision = bag:revision()
  local allowed = { toss = true, move = true, register = true, unregister = true, cancel = true }
  local view = openActionMenu(control)
  for _, action in ipairs(assert(view.actions, "the action menu must list its actions")) do
    Assert.isTrue(allowed[action.id] == true, "the action menu must stay inventory-local: " .. tostring(action.id))
  end
  cursor:setPocket("key_items")
  control:updateFixed({})
  view = openActionMenu(control)
  for _, action in ipairs(assert(view.actions, "the action menu must list its actions")) do
    Assert.isTrue(allowed[action.id] == true, "the action menu must stay inventory-local: " .. tostring(action.id))
  end
  Assert.equal(bag:revision(), revision, "browsing action menus must never mutate the inventory")
end

function T.overflow_add_never_mutates()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 999), "setup fills the exact stack maximum")
  local revision = bag:revision()
  Assert.isFalse(bag:hasSpace("POTION", 1), "a full stack must report no room")
  Assert.isFalse(bag:add("POTION", 1), "adding past the stack maximum must fail")
  Assert.equal(bag:quantity("POTION"), 999, "the overflow attempt must change nothing")
  Assert.equal(bag:revision(), revision, "the overflow attempt must not bump the service revision")
end

function T.confirmed_toss_removes_once_and_returns_to_browsing()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a tossable item")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control = controller(bag, cursor)
  local revision = bag:revision()
  local view = openActionMenu(control)
  view = chooseAction(control, "toss")
  Assert.equal(view.state, "toss_quantity", "choosing toss must enter the quantity picker")
  Assert.equal(view.quantity, 1, "the picker preselects one copy")
  control:updateFixed({ navigate("right") })
  Assert.equal(control:status().quantity, 2, "east steps the quantity up")
  control:updateFixed({ confirmEvent() })
  view = control:status()
  Assert.equal(view.state, "toss_confirm", "confirming a quantity must ask for confirmation")
  Assert.equal(view.quantity, 2, "the confirmation carries the picked quantity")
  control:updateFixed({ confirmEvent() })
  view = control:status()
  Assert.equal(view.state, "browsing", "a committed toss returns to browsing")
  Assert.equal(bag:quantity("POTION"), 3, "the toss must remove exactly the confirmed quantity")
  Assert.equal(bag:revision(), revision + 1, "one confirmation mutates the live service exactly once")
end

function T.toss_quantity_clamps_to_the_owned_bounds()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a tossable item")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control = controller(bag, cursor)
  openActionMenu(control)
  chooseAction(control, "toss")
  control:updateFixed({ navigate("left") })
  Assert.equal(control:status().quantity, 1, "the picker never drops below one copy")
  for _ = 1, 8 do
    control:updateFixed({ navigate("right") })
  end
  Assert.equal(control:status().quantity, 5, "the picker never exceeds the owned quantity")
  backToBrowsing(control)
  Assert.equal(bag:quantity("POTION"), 5, "bounded picker movement never mutates")
end

function T.stale_external_removal_aborts_the_pending_menu()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a tossable item")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control = controller(bag, cursor)
  openActionMenu(control)
  Assert.isTrue(bag:take("POTION", 5), "an external mutation removes the pending item")
  local revision = bag:revision()
  control:updateFixed({})
  local view = control:status()
  Assert.equal(view.state, "browsing", "a vanished selection safely collapses the menu")
  Assert.equal(bag:revision(), revision, "the abort itself mutates nothing")
  control:updateFixed({ confirmEvent() })
  Assert.equal(bag:revision(), revision, "confirming an empty pocket mutates nothing")
end

function T.failing_service_call_never_fakes_success()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a tossable item")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local layoutManifest = manifest()
  local function resolveLayout()
    return BagLayout.resolve({ topology = topology(), manifest = layoutManifest })
  end
  local control = BagController.new({
    model = {
      refresh = function()
        return BagModel.build(bag, cursor)
      end,
    },
    cursor = cursor,
    resolveLayout = resolveLayout,
    commands = {
      toss = function(_, _)
        return false
      end,
      move = function(_, _, _)
        return false
      end,
      register = function(_)
        return nil
      end,
      unregister = function(_)
        return false
      end,
    },
    resolveActions = BagActionPolicy.forService(bag),
  })
  local revision = bag:revision()
  openActionMenu(control)
  chooseAction(control, "toss")
  control:updateFixed({ confirmEvent() })
  control:updateFixed({ confirmEvent() })
  local view = control:status()
  Assert.equal(view.state, "browsing", "a failed toss still leaves the menu")
  Assert.equal(bag:quantity("POTION"), 5, "a failed toss changes nothing")
  Assert.equal(bag:revision(), revision, "a failed toss bumps no revision")
  Assert.equal(view.selected.item, "POTION", "the refreshed model shows the surviving item")
end

function T.reorder_across_pages_keeps_the_moved_item_selected()
  local bag = service()
  for _, nativeId in ipairs({ 6, 12, 18, 24, 30, 36, 42, 48 }) do
    Assert.isTrue(bag:add("ITEM_" .. nativeId, 1))
  end
  local cursor = BagCursor.new()
  cursor:setPocket("items")
  local control = controller(bag, cursor)
  control:updateFixed({ navigate("down") })
  control:updateFixed({ navigate("down") })
  control:updateFixed({ navigate("down") })
  control:updateFixed({ navigate("right") })
  Assert.equal(selectedKey(control:status()), "ITEM_48", "setup selects the last item")
  local revision = bag:revision()
  local view = openActionMenu(control)
  Assert.isTrue(hasAction(view, "move"), "a full manual pocket must offer to move")
  view = chooseAction(control, "move")
  Assert.equal(view.state, "move_select", "choosing move must enter target selection")
  control:updateFixed({ navigate("up") })
  control:updateFixed({ navigate("up") })
  view = control:status()
  Assert.equal(view.moveTarget, 3, "two rows up moves the target across the page boundary")
  control:updateFixed({ confirmEvent() })
  view = control:status()
  Assert.equal(view.state, "browsing", "a committed move returns to browsing")
  local order = {}
  for _, slot in ipairs(bag:pocketItems("items")) do
    order[#order + 1] = slot.item
  end
  Assert.deepEqual(
    order,
    { "ITEM_6", "ITEM_12", "ITEM_18", "ITEM_48", "ITEM_24", "ITEM_30", "ITEM_36", "ITEM_42" },
    "the open model must reflect the cross-page reorder"
  )
  Assert.equal(selectedKey(view), "ITEM_48", "a successful reorder keeps the moved item selected")
  Assert.equal(cursor:position("items"), 3, "the cursor tracks the moved item to its new position")
  Assert.equal(bag:revision(), revision + 1, "one confirmation reorders exactly once")
end

function T.cancelled_move_restores_the_selection_without_mutation()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a first manual-order item")
  Assert.isTrue(bag:add("ITEM_1", 2), "setup stocks a second manual-order item")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control = controller(bag, cursor)
  local revision = bag:revision()
  openActionMenu(control)
  chooseAction(control, "move")
  control:updateFixed({ navigate("right") })
  Assert.equal(control:status().moveTarget, 1, "target navigation follows the grid")
  backToBrowsing(control)
  local order = {}
  for _, slot in ipairs(bag:pocketItems("medicine")) do
    order[#order + 1] = slot.item
  end
  Assert.deepEqual(order, { "POTION", "ITEM_1" }, "cancelling a move preserves the pocket order")
  Assert.equal(selectedKey(control:status()), "POTION", "cancelling a move restores the moved selection")
  Assert.equal(bag:revision(), revision, "cancelling a move mutates nothing")
end

function T.register_and_unregister_commit_once_each()
  local bag = service()
  Assert.isTrue(bag:add("BICYCLE", 1), "setup stocks a registerable key item")
  local cursor = BagCursor.new()
  cursor:setPocket("key_items")
  local control = controller(bag, cursor)
  local revision = bag:revision()
  local view = openActionMenu(control)
  Assert.isTrue(hasAction(view, "register"), "an unregistered registerable item must offer to register")
  view = chooseAction(control, "register")
  Assert.equal(view.state, "browsing", "a committed registration returns to browsing")
  Assert.deepEqual(bag:registeredItems(), { "BICYCLE" }, "registering must claim the first slot")
  Assert.equal(bag:revision(), revision + 1, "one registration mutates exactly once")
  revision = bag:revision()
  view = openActionMenu(control)
  Assert.isTrue(hasAction(view, "unregister"), "a registered item must offer to unregister")
  Assert.isFalse(hasAction(view, "register"), "a registered item must not offer to register again")
  view = chooseAction(control, "unregister")
  Assert.equal(view.state, "browsing", "a committed unregistration returns to browsing")
  Assert.deepEqual(bag:registeredItems(), {}, "unregistering must release the slot")
  Assert.equal(bag:revision(), revision + 1, "one unregistration mutates exactly once")
end

function T.pointer_button_tap_matches_the_keyboard_choice()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a tossable item")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local layoutManifest = manifestWithButtons()
  local control = controller(bag, cursor, layoutManifest)
  local layout = BagLayout.resolve({ topology = topology(), manifest = layoutManifest })
  openActionMenu(control)
  tap(control, layout, 48, 144)
  local view = control:status()
  Assert.equal(view.state, "toss_quantity", "tapping the first button chooses toss like the keyboard")
  local revision = bag:revision()
  tap(control, layout, 220, 176)
  view = control:status()
  Assert.equal(view.state, "action_menu", "tapping cancel pops one level like the cancel key")
  Assert.equal(bag:revision(), revision, "pointer navigation never mutates")
  backToBrowsing(control)
  Assert.equal(bag:quantity("POTION"), 5, "pointer navigation changes no quantities")
end

function T.pointer_cell_tap_steers_the_move_target()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a first manual-order item")
  Assert.isTrue(bag:add("ITEM_1", 2), "setup stocks a second manual-order item")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local layoutManifest = manifestWithButtons()
  local control = controller(bag, cursor, layoutManifest)
  local layout = BagLayout.resolve({ topology = topology(), manifest = layoutManifest })
  openActionMenu(control)
  chooseAction(control, "move")
  tap(control, layout, 204, 56)
  Assert.equal(control:status().moveTarget, 1, "tapping a cell steers the target like the keyboard")
  local revision = bag:revision()
  control:updateFixed({ confirmEvent() })
  local order = {}
  for _, slot in ipairs(bag:pocketItems("medicine")) do
    order[#order + 1] = slot.item
  end
  Assert.deepEqual(order, { "ITEM_1", "POTION" }, "confirming the tapped target reorders")
  Assert.equal(selectedKey(control:status()), "POTION", "the moved item stays selected")
  Assert.equal(bag:revision(), revision + 1, "one pointer-steered confirmation reorders exactly once")
end

local function tapCell(control, layout, visibleIndex)
  local rect = SLOT_RECTS[visibleIndex + 1]
  tap(control, layout, rect.x + rect.width / 2, rect.y + rect.height / 2)
end

local function tapButton(control, layout, layoutManifest, buttonIndex)
  local buttons = assert(
    layoutManifest.interactive.overlays.actionMenu,
    "the pointer journey needs the generated button geometry"
  ).buttons
  local rect = assert(buttons[buttonIndex], "the tapped button must be generated")
  tap(control, layout, rect.x + rect.width / 2, rect.y + rect.height / 2)
end

local function tapCancel(control, layout, layoutManifest)
  local rect = assert(layoutManifest.interactive.cancel, "the pointer journey needs the cancel rectangle")
  tap(control, layout, rect.x + rect.width / 2, rect.y + rect.height / 2)
end

local function openMenuByPointer(control, layout, visibleIndex)
  tapCell(control, layout, visibleIndex)
  local view = control:status()
  Assert.equal(view.state, "action_menu", "activating the selected cell opens the action menu by pointer alone")
  Assert.isTrue(
    type(view.actions) == "table" and #view.actions >= 2,
    "the action menu must offer an action plus cancel"
  )
  return view
end

function T.pointer_only_toss_picks_confirms_once_without_early_mutation()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a tossable item")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local layoutManifest = manifestWithButtons()
  local control = controller(bag, cursor, layoutManifest)
  local layout = BagLayout.resolve({ topology = topology(), manifest = layoutManifest })
  local revision = bag:revision()
  openMenuByPointer(control, layout, 0)
  Assert.equal(bag:revision(), revision, "opening the menu never mutates the inventory")
  tapButton(control, layout, layoutManifest, 1)
  local view = control:status()
  Assert.equal(view.state, "toss_quantity", "the first button enters the quantity picker by pointer alone")
  Assert.equal(view.quantity, 1, "the picker preselects one copy")
  tapButton(control, layout, layoutManifest, 1)
  Assert.equal(control:status().quantity, 1, "the pointer decrement never drops below one copy")
  tapButton(control, layout, layoutManifest, 2)
  tapButton(control, layout, layoutManifest, 2)
  Assert.equal(control:status().quantity, 3, "pointer increments step the quantity up")
  tapButton(control, layout, layoutManifest, 1)
  Assert.equal(control:status().quantity, 2, "pointer decrements step the quantity down")
  for _ = 1, 8 do
    tapButton(control, layout, layoutManifest, 2)
  end
  Assert.equal(control:status().quantity, 5, "the pointer increment never exceeds the owned quantity")
  tapButton(control, layout, layoutManifest, 1)
  Assert.equal(control:status().quantity, 4, "the picker settles on four copies")
  tapButton(control, layout, layoutManifest, 3)
  view = control:status()
  Assert.equal(view.state, "toss_confirm", "the third button enters confirmation by pointer alone")
  Assert.equal(view.quantity, 4, "the confirmation carries the picked quantity")
  Assert.equal(bag:revision(), revision, "entering confirmation never mutates the inventory")
  Assert.equal(bag:quantity("POTION"), 5, "entering confirmation changes no quantities")
  tapButton(control, layout, layoutManifest, 3)
  view = control:status()
  Assert.equal(view.state, "browsing", "a committed toss returns to browsing")
  Assert.equal(bag:quantity("POTION"), 1, "the toss must remove exactly the confirmed quantity")
  Assert.equal(bag:revision(), revision + 1, "one pointer confirmation mutates the live service exactly once")
  tapButton(control, layout, layoutManifest, 3)
  Assert.equal(bag:quantity("POTION"), 1, "a further tap where confirm was mutates nothing")
  Assert.equal(bag:revision(), revision + 1, "a further tap bumps no service revision")
end

function T.pointer_only_toss_cancellation_returns_one_level_without_mutation()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a tossable item")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local layoutManifest = manifestWithButtons()
  local control = controller(bag, cursor, layoutManifest)
  local layout = BagLayout.resolve({ topology = topology(), manifest = layoutManifest })
  local revision = bag:revision()
  openMenuByPointer(control, layout, 0)
  tapButton(control, layout, layoutManifest, 1)
  Assert.equal(control:status().state, "toss_quantity")
  tapButton(control, layout, layoutManifest, 2)
  Assert.equal(control:status().quantity, 2, "setup picks two copies")
  tapCancel(control, layout, layoutManifest)
  local view = control:status()
  Assert.equal(view.state, "action_menu", "cancelling the quantity picker returns to the menu by pointer alone")
  Assert.equal(bag:revision(), revision, "cancelling the quantity picker mutates nothing")
  Assert.equal(bag:quantity("POTION"), 5, "cancelling the quantity picker changes no quantities")
  tapButton(control, layout, layoutManifest, 1)
  Assert.equal(control:status().state, "toss_quantity", "the menu still offers toss after cancellation")
  tapButton(control, layout, layoutManifest, 3)
  Assert.equal(control:status().state, "toss_confirm", "setup reaches confirmation")
  tapCancel(control, layout, layoutManifest)
  view = control:status()
  Assert.equal(view.state, "action_menu", "cancelling the confirmation returns to the menu by pointer alone")
  Assert.equal(bag:revision(), revision, "cancelling the confirmation mutates nothing")
  Assert.equal(bag:quantity("POTION"), 5, "cancelling the confirmation changes no quantities")
  tapCancel(control, layout, layoutManifest)
  Assert.equal(control:status().state, "browsing", "cancelling the menu returns to browsing")
  Assert.equal(bag:revision(), revision, "the whole cancelled journey mutates nothing")
end

function T.pointer_quantity_controls_match_press_and_release_targets()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a tossable item")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local layoutManifest = manifestWithButtons()
  local control = controller(bag, cursor, layoutManifest)
  local layout = BagLayout.resolve({ topology = topology(), manifest = layoutManifest })
  openMenuByPointer(control, layout, 0)
  tapButton(control, layout, layoutManifest, 1)
  Assert.equal(control:status().state, "toss_quantity")
  tapButton(control, layout, layoutManifest, 2)
  tapButton(control, layout, layoutManifest, 2)
  Assert.equal(control:status().quantity, 3, "setup picks three copies by pointer alone")
  local incrementX, incrementY = hostAt(layout, 144, 144)
  local decrementX, decrementY = hostAt(layout, 48, 144)
  control:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = incrementX, y = incrementY } })
  control:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = decrementX, y = decrementY } })
  Assert.equal(control:status().quantity, 3, "a release on a different control activates nothing")
  control:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = incrementX, y = incrementY } })
  control:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = incrementX, y = incrementY, dragged = true } })
  Assert.equal(control:status().quantity, 3, "a dragged release activates nothing")
  tapButton(control, layout, layoutManifest, 1)
  Assert.equal(control:status().quantity, 2, "a matched decrement still steps down")
end

function T.pointer_only_move_selects_a_target_then_confirms_once()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a first manual-order item")
  Assert.isTrue(bag:add("ITEM_1", 2), "setup stocks a second manual-order item")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local layoutManifest = manifestWithButtons()
  local control = controller(bag, cursor, layoutManifest)
  local layout = BagLayout.resolve({ topology = topology(), manifest = layoutManifest })
  local revision = bag:revision()
  openMenuByPointer(control, layout, 0)
  tapButton(control, layout, layoutManifest, 2)
  Assert.equal(control:status().state, "move_select", "the second button enters target selection by pointer alone")
  tapCell(control, layout, 1)
  local view = control:status()
  Assert.equal(view.state, "move_select", "tapping a target never commits on its own")
  Assert.equal(view.moveTarget, 1, "tapping a cell steers the target by pointer alone")
  Assert.equal(bag:revision(), revision, "steering the target never mutates the inventory")
  local order = {}
  for _, slot in ipairs(bag:pocketItems("medicine")) do
    order[#order + 1] = slot.item
  end
  Assert.deepEqual(order, { "POTION", "ITEM_1" }, "steering the target preserves the pocket order")
  tapButton(control, layout, layoutManifest, 3)
  view = control:status()
  Assert.equal(view.state, "browsing", "the explicit confirm commits by pointer alone")
  order = {}
  for _, slot in ipairs(bag:pocketItems("medicine")) do
    order[#order + 1] = slot.item
  end
  Assert.deepEqual(order, { "ITEM_1", "POTION" }, "confirming the tapped target reorders")
  Assert.equal(selectedKey(view), "POTION", "the moved item stays selected")
  Assert.equal(bag:revision(), revision + 1, "one pointer confirmation reorders exactly once")
end

function T.pointer_only_move_cancellation_restores_the_cursor_without_mutation()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a first manual-order item")
  Assert.isTrue(bag:add("ITEM_1", 2), "setup stocks a second manual-order item")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local layoutManifest = manifestWithButtons()
  local control = controller(bag, cursor, layoutManifest)
  local layout = BagLayout.resolve({ topology = topology(), manifest = layoutManifest })
  local revision = bag:revision()
  openMenuByPointer(control, layout, 0)
  tapButton(control, layout, layoutManifest, 2)
  Assert.equal(control:status().state, "move_select")
  tapCell(control, layout, 1)
  Assert.equal(control:status().moveTarget, 1, "setup steers the target by pointer alone")
  tapCancel(control, layout, layoutManifest)
  local view = control:status()
  Assert.equal(view.state, "browsing", "cancelling move returns to browsing by pointer alone")
  local order = {}
  for _, slot in ipairs(bag:pocketItems("medicine")) do
    order[#order + 1] = slot.item
  end
  Assert.deepEqual(order, { "POTION", "ITEM_1" }, "cancelling a move preserves the pocket order")
  Assert.equal(selectedKey(view), "POTION", "cancelling a move restores the moved selection")
  Assert.equal(bag:revision(), revision, "cancelling a move mutates nothing")
end

function T.pointer_only_register_and_unregister_commit_once_each_with_a_refresh()
  local bag = service()
  Assert.isTrue(bag:add("BICYCLE", 1), "setup stocks a registerable key item")
  local cursor = BagCursor.new()
  cursor:setPocket("key_items")
  local layoutManifest = manifestWithButtons()
  local control = controller(bag, cursor, layoutManifest)
  local layout = BagLayout.resolve({ topology = topology(), manifest = layoutManifest })
  local revision = bag:revision()
  local view = openMenuByPointer(control, layout, 0)
  Assert.isTrue(hasAction(view, "register"), "an unregistered registerable item must offer to register")
  tapButton(control, layout, layoutManifest, 1)
  view = control:status()
  Assert.equal(view.state, "browsing", "a committed registration returns to browsing by pointer alone")
  Assert.deepEqual(bag:registeredItems(), { "BICYCLE" }, "registering must claim the first slot")
  Assert.equal(bag:revision(), revision + 1, "one pointer registration mutates exactly once")
  revision = bag:revision()
  view = openMenuByPointer(control, layout, 0)
  Assert.isTrue(hasAction(view, "unregister"), "a registered item must offer to unregister")
  Assert.isFalse(hasAction(view, "register"), "a registered item must not offer to register again")
  tapButton(control, layout, layoutManifest, 1)
  view = control:status()
  Assert.equal(view.state, "browsing", "a committed unregistration returns to browsing by pointer alone")
  Assert.deepEqual(bag:registeredItems(), {}, "unregistering must release the slot")
  Assert.equal(bag:revision(), revision + 1, "one pointer unregistration mutates exactly once")
end

function T.save_capture_matches_the_open_model_after_ui_actions()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a tossable manual-order item")
  Assert.isTrue(bag:add("ITEM_1", 2), "setup stocks a second manual-order item")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control = controller(bag, cursor)
  openActionMenu(control)
  chooseAction(control, "toss")
  control:updateFixed({ navigate("right") })
  control:updateFixed({ confirmEvent() })
  control:updateFixed({ confirmEvent() })
  local captured = bag:capture()
  local view = BagModel.build(bag, cursor)
  local expected = {}
  for _, slot in ipairs(view.slots) do
    expected[#expected + 1] = { item = slot.item, quantity = slot.quantity }
  end
  Assert.deepEqual(
    captured.pockets.medicine,
    expected,
    "the normal save capture must match the open model after ui actions"
  )
end

return { tests = T }
