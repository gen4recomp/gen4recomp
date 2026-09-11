-- Pure browse controller for the field bag: six-cell grid navigation,
-- pocket switching with per-pocket cursor memory, external-revision
-- reconciliation, pointer press/release capture, one-shot close, and the
-- constrained-topology description overlay. Real inventory service, cursor,
-- and layout geometry; only the view model is injected. No love, no GPU.

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

local function topology(width, height)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = false,
    role = "world",
  })
end

local function service()
  return HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
end

local function stockTwoPockets(bag)
  Assert.isTrue(bag:add("POTION", 5))
  Assert.isTrue(bag:add("POKE_BALL", 3))
  Assert.isTrue(bag:add("GREAT_BALL", 2))
  return bag
end

local function stockEightItems(bag)
  for _, nativeId in ipairs({ 6, 12, 18, 24, 30, 36, 42, 48 }) do
    Assert.isTrue(bag:add("ITEM_" .. nativeId, 1))
  end
  return bag
end

---@param bag HgssBagService
---@param cursor BagCursor
---@param width integer?
---@param height integer?
---@return BagController
local function controller(bag, cursor, width, height)
  local layoutManifest = manifest()
  local function resolveLayout()
    return BagLayout.resolve({ topology = topology(width or 512, height or 384), manifest = layoutManifest })
  end
  return BagController.new({
    model = {
      refresh = function()
        return BagModel.build(bag, cursor)
      end,
    },
    cursor = cursor,
    resolveLayout = resolveLayout,
    commands = {
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
    },
    resolveActions = BagActionPolicy.forService(bag),
  })
end

local BUTTON_RECTS = {
  { x = 8, y = 136, width = 80, height = 16 },
  { x = 104, y = 136, width = 80, height = 16 },
  { x = 8, y = 168, width = 80, height = 16 },
  { x = 104, y = 168, width = 80, height = 16 },
}

local function manifestWithButtons()
  local layoutManifest = manifest()
  local buttons = {}
  for index, rect in ipairs(BUTTON_RECTS) do
    buttons[index] = { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
  end
  layoutManifest.interactive.overlays.actionMenu = { buttons = buttons }
  return layoutManifest
end

---@param bag HgssBagService
---@param cursor BagCursor
---@return BagController
---@return table<string, unknown>
local function controllerWithButtons(bag, cursor)
  local layoutManifest = manifestWithButtons()
  local function resolveLayout()
    return BagLayout.resolve({ topology = topology(512, 384), manifest = layoutManifest })
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
    },
    resolveActions = BagActionPolicy.forService(bag),
  })
  return control, layoutManifest
end

local function tap(control, layout, logicalX, logicalY)
  local frame = layout.interactive.frame
  local scale = layout.interactive.scale
  local x = frame.x + logicalX * scale
  local y = frame.y + logicalY * scale
  control:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = x, y = y } })
  control:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = x, y = y } })
end

local function navigate(direction)
  return { type = "navigate", direction = direction }
end

local function selectedKey(status)
  local selected = status.selected
  if selected == nil then
    return nil
  end
  return selected.item
end

function T.grid_navigation_moves_within_the_window_then_scrolls()
  local bag = stockEightItems(service())
  local cursor = BagCursor.new()
  cursor:setPocket("items")
  local control = controller(bag, cursor)
  control:updateFixed({ navigate("right") })
  Assert.equal(cursor:position("items"), 1, "right moves across the row")
  control:updateFixed({ navigate("down") })
  Assert.equal(cursor:position("items"), 3, "down moves down one row")
  Assert.equal(cursor:scroll("items"), 0, "the first page needs no scroll")
  control:updateFixed({ navigate("down") })
  Assert.equal(cursor:position("items"), 5)
  control:updateFixed({ navigate("down") })
  Assert.equal(cursor:position("items"), 7, "down past the window scrolls one row")
  Assert.equal(cursor:scroll("items"), 2)
  local status = control:status()
  Assert.equal(status.visibleStart, 2)
  Assert.equal(selectedKey(status), "ITEM_48")
  Assert.deepEqual(status.page, { current = 2, count = 2 })
end

function T.horizontal_edges_switch_pockets_and_remember_cursors()
  local bag = stockTwoPockets(service())
  local cursor = BagCursor.new()
  cursor:setPocket("balls")
  local control = controller(bag, cursor)
  control:updateFixed({ navigate("right") })
  Assert.equal(cursor:position("balls"), 1, "right selects the second ball")
  control:updateFixed({ navigate("right") })
  Assert.equal(cursor:currentPocket(), "tmhm", "right past the row enters the next pocket")
  Assert.isNil(control:status().selected, "the empty pocket selects nothing")
  control:updateFixed({ navigate("left") })
  Assert.equal(cursor:currentPocket(), "balls", "left returns to the previous pocket")
  Assert.equal(cursor:position("balls"), 1, "returning restores the remembered position")
  Assert.equal(selectedKey(control:status()), "GREAT_BALL")
end

function T.pocket_tabs_focus_switches_pockets()
  local bag = stockTwoPockets(service())
  local cursor = BagCursor.new()
  cursor:setPocket("balls")
  local control = controller(bag, cursor)
  control:updateFixed({ navigate("up") })
  Assert.equal(control:status().focus, "tabs", "up past the top row focuses the tabs")
  control:updateFixed({ navigate("right") })
  Assert.equal(cursor:currentPocket(), "tmhm", "tabs right switches forward")
  Assert.equal(control:status().focus, "items", "a pocket switch lands on the grid")
  control:updateFixed({ navigate("up") })
  control:updateFixed({ navigate("left") })
  Assert.equal(cursor:currentPocket(), "balls", "tabs left switches back")
end

function T.cancel_focus_confirms_close_and_reports_once()
  local bag = stockTwoPockets(service())
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control = controller(bag, cursor)
  control:updateFixed({ navigate("down") })
  Assert.equal(control:status().focus, "cancel", "down past the last row focuses cancel")
  control:updateFixed({ { type = "confirm" } })
  local first = control:takeResult()
  Assert.deepEqual(first, { kind = "closed" })
  Assert.isNil(control:takeResult(), "the close result reports exactly once")
  Assert.isFalse(control:status().open, "a closed controller stays closed")
  control:updateFixed({ navigate("up") })
  Assert.isNil(control:takeResult(), "a closed controller ignores further input")
end

function T.cancel_focus_ignores_horizontal_pocket_switches()
  local bag = stockTwoPockets(service())
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control = controller(bag, cursor)
  control:updateFixed({ navigate("down") })
  Assert.equal(control:status().focus, "cancel", "down past the last row focuses cancel")
  control:updateFixed({ navigate("left") })
  Assert.equal(cursor:currentPocket(), "medicine", "left on cancel keeps the pocket")
  Assert.equal(control:status().focus, "cancel", "left on cancel keeps cancel focus")
  control:updateFixed({ navigate("right") })
  Assert.equal(cursor:currentPocket(), "medicine", "right on cancel keeps the pocket")
  Assert.equal(control:status().focus, "cancel", "right on cancel keeps cancel focus")
  control:updateFixed({ navigate("up") })
  Assert.equal(control:status().focus, "items", "up returns to the grid")
end

function T.cancel_key_closes_from_browse()
  local bag = stockTwoPockets(service())
  local control = controller(bag, BagCursor.new())
  control:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(control:takeResult(), { kind = "closed" })
end

function T.confirm_on_an_item_opens_the_action_menu_without_mutation()
  local bag = stockTwoPockets(service())
  local pocketCursor = BagCursor.new()
  pocketCursor:setPocket("balls")
  local control = controller(bag, pocketCursor)
  local revision = bag:revision()
  control:updateFixed({ { type = "confirm" } })
  Assert.isNil(control:takeResult(), "confirming an item stays inside the bag")
  Assert.isTrue(control:status().open)
  local status = control:status()
  Assert.equal(status.state, "action_menu", "confirming an item opens the action menu")
  Assert.isTrue(type(status.actions) == "table" and #status.actions >= 2, "the menu offers an action plus cancel")
  Assert.equal(bag:revision(), revision, "opening the menu never mutates inventory")
  Assert.equal(selectedKey(control:status()), "POKE_BALL")
  control:updateFixed({ { type = "cancel" } })
  Assert.equal(control:status().state, "browsing", "cancelling the menu returns to browsing")
  Assert.equal(bag:revision(), revision, "cancelling the menu never mutates inventory")
end

function T.external_revision_removal_reconciles_to_the_nearest_item()
  local bag = stockTwoPockets(service())
  local pocketCursor = BagCursor.new()
  pocketCursor:setPocket("balls")
  local control = controller(bag, pocketCursor)
  control:updateFixed({ navigate("right") })
  Assert.equal(selectedKey(control:status()), "GREAT_BALL")
  Assert.isTrue(bag:take("GREAT_BALL", 2), "an external mutation removes the selected item")
  control:updateFixed({})
  local status = control:status()
  Assert.equal(selectedKey(status), "POKE_BALL", "reconciliation keeps the nearest valid item")
  Assert.equal(pocketCursor:position("balls"), 0)
end

function T.pointer_down_up_on_the_same_cell_selects()
  local bag = stockTwoPockets(service())
  local pocketCursor = BagCursor.new()
  pocketCursor:setPocket("balls")
  local control = controller(bag, pocketCursor)
  local layout = BagLayout.resolve({ topology = topology(512, 384), manifest = manifest() })
  local frame = layout.interactive.frame
  local scale = layout.interactive.scale
  local function hostAt(logicalX, logicalY)
    return frame.x + logicalX * scale, frame.y + logicalY * scale
  end
  local x, y = hostAt(204, 56)
  control:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = x, y = y } })
  Assert.equal(selectedKey(control:status()), "POKE_BALL", "press alone never activates")
  control:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = x, y = y } })
  Assert.equal(selectedKey(control:status()), "GREAT_BALL", "release on the same cell selects")
end

function T.pointer_release_on_a_different_target_or_drag_does_nothing()
  local bag = stockTwoPockets(service())
  local pocketCursor = BagCursor.new()
  pocketCursor:setPocket("balls")
  local control = controller(bag, pocketCursor)
  local layout = BagLayout.resolve({ topology = topology(512, 384), manifest = manifest() })
  local frame = layout.interactive.frame
  local function hostAt(logicalX, logicalY)
    return frame.x + logicalX * layout.interactive.scale, frame.y + logicalY * layout.interactive.scale
  end
  local firstX, firstY = hostAt(76, 56)
  local secondX, secondY = hostAt(204, 56)
  control:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = firstX, y = firstY } })
  control:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = secondX, y = secondY } })
  Assert.equal(selectedKey(control:status()), "POKE_BALL", "a drag across cells activates nothing")
  control:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = firstX, y = firstY } })
  control:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = secondX, y = secondY, dragged = true } })
  Assert.equal(selectedKey(control:status()), "POKE_BALL", "a dragged release activates nothing")
end

function T.pointer_cancel_closes_and_pointer_tab_switches_pocket()
  local bag = stockTwoPockets(service())
  local pocketCursor = BagCursor.new()
  pocketCursor:setPocket("balls")
  local control = controller(bag, pocketCursor)
  local layout = BagLayout.resolve({ topology = topology(512, 384), manifest = manifest() })
  local frame = layout.interactive.frame
  local function hostAt(logicalX, logicalY)
    return frame.x + logicalX * layout.interactive.scale, frame.y + logicalY * layout.interactive.scale
  end
  local tabX, tabY = hostAt(48, 16)
  control:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = tabX, y = tabY } })
  control:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = tabX, y = tabY } })
  Assert.equal(pocketCursor:currentPocket(), "medicine", "tapping a tab selects its pocket")
  local cancelX, cancelY = hostAt(220, 176)
  control:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = cancelX, y = cancelY } })
  control:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = cancelX, y = cancelY } })
  Assert.deepEqual(control:takeResult(), { kind = "closed" }, "tapping cancel closes")
end

function T.stale_capture_cannot_activate()
  local bag = stockTwoPockets(service())
  local pocketCursor = BagCursor.new()
  pocketCursor:setPocket("balls")
  local control = controller(bag, pocketCursor)
  local layout = BagLayout.resolve({ topology = topology(512, 384), manifest = manifest() })
  local frame = layout.interactive.frame
  local x = frame.x + 76 * layout.interactive.scale
  local y = frame.y + 56 * layout.interactive.scale
  control:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = x, y = y } })
  control:cancelPointerCapture()
  control:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = x, y = y } })
  Assert.equal(selectedKey(control:status()), "POKE_BALL", "a cancelled press never activates")
  Assert.isNil(control:takeResult())
end

function T.description_overlay_round_trip_in_constrained_mode()
  local bag = stockTwoPockets(service())
  local pocketCursor = BagCursor.new()
  pocketCursor:setPocket("balls")
  local control = controller(bag, pocketCursor, 256, 192)
  Assert.equal(control:status().layout.mode, "interactive_only")
  control:updateFixed({ { type = "menu" } })
  local status = control:status()
  Assert.equal(status.state, "description_overlay", "the info action overlays the description")
  Assert.equal(selectedKey(status), "POKE_BALL", "the overlay keeps the prior selection")
  control:updateFixed({ navigate("down") })
  Assert.equal(selectedKey(control:status()), "POKE_BALL", "navigation never escapes the overlay")
  control:updateFixed({ { type = "confirm" } })
  status = control:status()
  Assert.equal(status.state, "browsing", "confirm closes the overlay")
  Assert.equal(selectedKey(status), "POKE_BALL", "closing restores the exact selection")
  control:updateFixed({ { type = "menu" } })
  Assert.equal(control:status().state, "description_overlay")
  control:updateFixed({ { type = "cancel" } })
  Assert.equal(control:status().state, "browsing", "cancel closes the overlay instead of the app")
  Assert.isNil(control:takeResult())
end

function T.info_action_stays_inert_outside_constrained_mode()
  local bag = stockTwoPockets(service())
  local pocketCursor = BagCursor.new()
  pocketCursor:setPocket("balls")
  local control = controller(bag, pocketCursor)
  Assert.equal(control:status().layout.mode, "horizontal")
  control:updateFixed({ { type = "menu" } })
  Assert.equal(control:status().state, "browsing", "two-pane modes keep the description in the hero pane")
end

function T.pointer_scroll_pages_the_window()
  local bag = stockEightItems(service())
  local pocketCursor = BagCursor.new()
  pocketCursor:setPocket("items")
  local control = controller(bag, pocketCursor)
  control:updateFixed({ { type = "pointer_scroll", pointerId = "touch:0", dx = 0, dy = 1 } })
  local status = control:status()
  Assert.equal(status.visibleStart, 6, "scrolling down pages the window")
  Assert.equal(selectedKey(status), "ITEM_42", "paging carries the selection with the window")
  control:updateFixed({ { type = "pointer_scroll", pointerId = "touch:0", dx = 0, dy = -1 } })
  status = control:status()
  Assert.equal(status.visibleStart, 0)
  Assert.equal(selectedKey(status), "ITEM_6")
end

function T.pointer_tap_on_a_different_cell_selects_only_while_tap_on_the_selected_cell_opens_the_menu()
  local bag = stockTwoPockets(service())
  local pocketCursor = BagCursor.new()
  pocketCursor:setPocket("balls")
  local control, layoutManifest = controllerWithButtons(bag, pocketCursor)
  local layout = BagLayout.resolve({ topology = topology(512, 384), manifest = layoutManifest })
  local revision = bag:revision()
  tap(control, layout, 204, 56)
  local status = control:status()
  Assert.equal(status.state, "browsing", "tapping a different cell only selects it")
  Assert.equal(selectedKey(status), "GREAT_BALL")
  Assert.equal(bag:revision(), revision, "first selection never mutates the inventory")
  tap(control, layout, 204, 56)
  status = control:status()
  Assert.equal(status.state, "action_menu", "activating the selected cell opens the action menu")
  Assert.isTrue(type(status.actions) == "table" and #status.actions >= 2, "the menu offers an action plus cancel")
  Assert.equal(bag:revision(), revision, "opening the menu never mutates the inventory")
end

function T.pointer_action_button_tap_chooses_the_offered_button_position()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a first manual-order item")
  Assert.isTrue(bag:add("ITEM_1", 2), "setup stocks a second manual-order item")
  local pocketCursor = BagCursor.new()
  pocketCursor:setPocket("medicine")
  local control, layoutManifest = controllerWithButtons(bag, pocketCursor)
  local layout = BagLayout.resolve({ topology = topology(512, 384), manifest = layoutManifest })
  tap(control, layout, 76, 56)
  Assert.equal(control:status().state, "action_menu", "activating the selected cell opens the action menu")
  tap(control, layout, 144, 144)
  Assert.equal(
    control:status().state,
    "move_select",
    "the second button chooses the second offered action through pointer alone"
  )
end

function T.pointer_quantity_steps_confirm_and_nested_cancel_hold_across_updates()
  local bag = stockTwoPockets(service())
  local pocketCursor = BagCursor.new()
  pocketCursor:setPocket("medicine")
  local control, layoutManifest = controllerWithButtons(bag, pocketCursor)
  local layout = BagLayout.resolve({ topology = topology(512, 384), manifest = layoutManifest })
  local revision = bag:revision()
  tap(control, layout, 76, 56)
  Assert.equal(control:status().state, "action_menu", "activating the selected cell opens the action menu")
  tap(control, layout, 48, 144)
  Assert.equal(control:status().state, "toss_quantity", "the first offered action starts the quantity picker")
  tap(control, layout, 144, 144)
  Assert.equal(control:status().quantity, 2, "the increment affordance steps the picked quantity")
  tap(control, layout, 48, 144)
  Assert.equal(control:status().quantity, 1, "the decrement affordance steps the picked quantity back")
  tap(control, layout, 144, 144)
  tap(control, layout, 48, 176)
  Assert.equal(control:status().state, "toss_confirm", "the confirm affordance asks for confirmation")
  tap(control, layout, 48, 176)
  local status = control:status()
  Assert.equal(status.state, "browsing", "confirming the toss returns to browsing")
  Assert.equal(bag:quantity("POTION"), 3, "one pointer toss removes the picked copies")
  Assert.equal(bag:revision(), revision + 1, "one pointer toss mutates exactly once")
  tap(control, layout, 76, 56)
  Assert.equal(control:status().state, "action_menu", "a later activation reopens the action menu")
  tap(control, layout, 220, 176)
  Assert.equal(control:status().state, "browsing", "the nested cancel pops one level without mutation")
  Assert.equal(bag:revision(), revision + 1, "the nested cancel never mutates the inventory")
end

function T.unknown_events_are_programming_errors()
  local control = controller(stockTwoPockets(service()), BagCursor.new())
  Assert.throws(function()
    control:updateFixed({ { type = "warp" } })
  end)
end

return { tests = T }
