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

local SLOT_SHAPES = {
  { rect = { x = 0, y = 32, width = 128, height = 42 }, center = { x = 48, y = 56 } },
  { rect = { x = 128, y = 32, width = 128, height = 42 }, center = { x = 176, y = 56 } },
  { rect = { x = 0, y = 74, width = 128, height = 44 }, center = { x = 48, y = 96 } },
  { rect = { x = 128, y = 74, width = 128, height = 44 }, center = { x = 176, y = 96 } },
  { rect = { x = 0, y = 118, width = 128, height = 36 }, center = { x = 48, y = 136 } },
  { rect = { x = 128, y = 118, width = 128, height = 36 }, center = { x = 176, y = 136 } },
}

local function manifest()
  local tabs = {}
  for index, rect in ipairs(TAB_RECTS) do
    tabs[index] = { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
  end
  local slots = {}
  for _, shape in ipairs(SLOT_SHAPES) do
    slots[#slots + 1] = {
      rect = { x = shape.rect.x, y = shape.rect.y, width = shape.rect.width, height = shape.rect.height },
      iconCenter = { x = shape.center.x, y = shape.center.y },
    }
  end
  return {
    interactive = {
      pocketTabs = { rects = tabs },
      itemSlots = { slots = slots },
      pageIndicator = { rect = { x = 80, y = 168, width = 56, height = 16 }, textAt = { x = 0, y = 0 } },
      cancel = {
        rect = { x = 192, y = 168, width = 64, height = 24 },
        textRect = { x = 192, y = 168, width = 56, height = 16 },
      },
      overlays = {
        descriptionFallback = {
          frame = { x = 0, y = 144, width = 256, height = 48 },
          textRect = { x = 20, y = 144, width = 236, height = 48 },
        },
        actionMenu = {
          slots = {
            { hitRect = { x = 8, y = 136, width = 80, height = 16 } },
            { hitRect = { x = 104, y = 136, width = 80, height = 16 } },
            { hitRect = { x = 8, y = 168, width = 80, height = 16 } },
            { hitRect = { x = 104, y = 168, width = 80, height = 16 } },
          },
        },
        quantity = {
          controls = {
            { delta = 100, role = "increment", hitRect = { x = 0, y = 128, width = 32, height = 32 } },
            { delta = 10, role = "increment", hitRect = { x = 32, y = 128, width = 32, height = 32 } },
            { delta = 1, role = "increment", hitRect = { x = 64, y = 128, width = 32, height = 32 } },
            { delta = -100, role = "decrement", hitRect = { x = 0, y = 160, width = 32, height = 32 } },
            { delta = -10, role = "decrement", hitRect = { x = 32, y = 160, width = 32, height = 32 } },
            { delta = -1, role = "decrement", hitRect = { x = 64, y = 160, width = 32, height = 32 } },
          },
          pressTicks = 2,
          cancelHitRect = { x = 178, y = 168, width = 78, height = 24 },
          confirm = { hitRect = { x = 112, y = 160, width = 64, height = 32 } },
        },
      },
    },
  }
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

local function promptShape()
  local visual = function()
    return {}
  end
  return {
    width = 48,
    height = 32,
    yes = { normal = visual(), selected = visual() },
    no = { normal = visual(), selected = visual() },
  }
end

local function tossPrompt()
  return { x = 200, y = 48, shape = "compact", initialSelection = "yes" }
end

---@param bag HgssBagService
---@param cursor BagCursor
---@param heroVisible boolean? true unless the constrained lower-only composition is under test
---@return BagController
---@return table<string, unknown>
local function controller(bag, cursor, heroVisible)
  local layoutManifest = manifest()
  local function resolveLayout()
    return BagLayout.resolve({ manifest = layoutManifest, heroVisible = heroVisible ~= false })
  end
  local control = BagController.new({
    model = {
      refresh = function()
        return BagModel.build(bag, cursor)
      end,
    },
    cursor = cursor,
    resolveLayout = resolveLayout,
    promptShape = promptShape(),
    tossPrompt = tossPrompt(),
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
  local _ = layout
  local x = logicalX
  local y = logicalY
  control:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = x, y = y } })
  control:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = x, y = y } })
end

local function navigate(direction)
  return { type = "navigate", direction = direction }
end

-- Runs one latched modal choice through its full confirmation interval:
-- eight waiting updates hold confirmation, and the terminal update
-- publishes the latched result.
---@param control table
local function settlePromptChoice(control)
  for _ = 1, 9 do
    control:updateFixed({})
  end
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

function T.item_horizontal_edges_stay_inside_the_grid()
  local bag = stockTwoPockets(service())
  local cursor = BagCursor.new()
  cursor:setPocket("balls")
  local control = controller(bag, cursor)
  control:updateFixed({ navigate("right") })
  Assert.equal(cursor:position("balls"), 1, "right selects the second ball")
  control:updateFixed({ navigate("left") })
  Assert.equal(cursor:position("balls"), 0, "left selects the first ball")
  control:updateFixed({ navigate("left") })
  Assert.equal(cursor:currentPocket(), "balls", "left past the row keeps the pocket")
  Assert.equal(control:status().focus, "items", "left past the row keeps item focus")
  Assert.equal(cursor:position("balls"), 0, "left past the row keeps the cell")
  Assert.equal(selectedKey(control:status()), "POKE_BALL")
  control:updateFixed({ navigate("right") })
  control:updateFixed({ navigate("right") })
  Assert.equal(cursor:currentPocket(), "balls", "right past the row keeps the pocket")
  Assert.equal(control:status().focus, "items", "right past the row keeps item focus")
  Assert.equal(cursor:position("balls"), 1, "right past the row keeps the cell")
  Assert.equal(selectedKey(control:status()), "GREAT_BALL")
end

function T.item_horizontal_edges_reach_padded_cells_but_never_leave_the_grid()
  local bag = stockTwoPockets(service())
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control = controller(bag, cursor)
  Assert.equal(selectedKey(control:status()), "POTION")
  control:updateFixed({ navigate("right") })
  local status = control:status()
  Assert.equal(cursor:currentPocket(), "medicine", "right toward an empty cell keeps the pocket")
  Assert.equal(status.focus, "items", "right toward an empty cell keeps item focus")
  Assert.equal(status.focusedAbsoluteIndex, 1, "right focuses the padded empty cell")
  Assert.isNil(status.selected, "an empty focus selects no item")
  Assert.equal(cursor:position("medicine"), 0, "empty focus never invents an item index")
  control:updateFixed({ navigate("right") })
  Assert.equal(control:status().focusedAbsoluteIndex, 1, "right past the row keeps the cell")
  Assert.equal(cursor:currentPocket(), "medicine", "right past the row keeps the pocket")
  control:updateFixed({ navigate("left") })
  Assert.equal(selectedKey(control:status()), "POTION", "left returns to the occupied cell")
  control:updateFixed({ navigate("left") })
  Assert.equal(cursor:currentPocket(), "medicine", "left past a sparse row keeps the pocket")
  Assert.equal(control:status().focus, "items", "left past a sparse row keeps item focus")
  Assert.equal(cursor:position("medicine"), 0, "left past a sparse row keeps the cell")
end

function T.tab_arrows_move_focus_without_committing()
  local bag = stockTwoPockets(service())
  local cursor = BagCursor.new()
  cursor:setPocket("balls")
  local control = controller(bag, cursor)
  control:updateFixed({ navigate("right") })
  Assert.equal(cursor:position("balls"), 1, "setup selects the second ball")
  local ballPosition = cursor:position("balls")
  local ballScroll = cursor:scroll("balls")
  local medicinePosition = cursor:position("medicine")
  local medicineScroll = cursor:scroll("medicine")
  local revision = bag:revision()
  control:updateFixed({ navigate("up") })
  Assert.equal(control:status().focus, "tabs", "up past the top row focuses the tabs")
  Assert.equal(control:status().tabFocusPocket, "balls", "entering tabs starts from the committed pocket")
  Assert.equal(cursor:currentPocket(), "balls", "entering tabs never commits")
  control:updateFixed({ navigate("right") })
  local moved = control:status()
  Assert.equal(moved.focus, "tabs", "tab right keeps tab focus")
  Assert.equal(moved.tabFocusPocket, "tmhm", "tab right moves the candidate forward")
  Assert.equal(cursor:currentPocket(), "balls", "tab right never commits")
  Assert.equal(cursor:position("balls"), ballPosition, "candidate movement keeps the remembered position")
  Assert.equal(cursor:scroll("balls"), ballScroll, "candidate movement keeps the remembered scroll")
  Assert.equal(selectedKey(moved), "GREAT_BALL", "candidate movement keeps the selected item")
  Assert.equal(bag:revision(), revision, "candidate movement never mutates inventory")
  control:updateFixed({ navigate("left") })
  Assert.equal(control:status().tabFocusPocket, "balls", "tab left returns the candidate")
  Assert.equal(cursor:currentPocket(), "balls", "tab left never commits")
  control:updateFixed({ navigate("left") })
  Assert.equal(control:status().tabFocusPocket, "medicine", "tab left steps back")
  Assert.equal(cursor:currentPocket(), "balls", "tab travel never commits")
  control:updateFixed({ navigate("left") })
  Assert.equal(control:status().tabFocusPocket, "items", "tab left reaches the first pocket")
  Assert.equal(cursor:currentPocket(), "balls", "tab travel never commits")
  control:updateFixed({ navigate("left") })
  Assert.equal(control:status().tabFocusPocket, "key_items", "tab left past the first pocket wraps")
  Assert.equal(cursor:currentPocket(), "balls", "wrap never commits")
  control:updateFixed({ navigate("right") })
  Assert.equal(control:status().tabFocusPocket, "items", "tab right past the last pocket wraps")
  Assert.equal(cursor:currentPocket(), "balls", "wrap never commits")
  Assert.equal(cursor:position("medicine"), medicinePosition, "other pockets keep their cursor memory")
  Assert.equal(cursor:scroll("medicine"), medicineScroll, "other pockets keep their scroll memory")
  Assert.equal(bag:revision(), revision, "tab travel never mutates inventory")
  Assert.equal(control:status().focus, "tabs", "tab focus survives every move")
end

function T.confirm_commits_focused_tab_and_keeps_tab_focus()
  local bag = stockTwoPockets(service())
  local cursor = BagCursor.new()
  cursor:setPocket("balls")
  local control = controller(bag, cursor)
  control:updateFixed({ navigate("right") })
  Assert.equal(selectedKey(control:status()), "GREAT_BALL", "setup selects the second ball")
  local revision = bag:revision()
  control:updateFixed({ navigate("up") })
  Assert.equal(control:status().focus, "tabs", "setup focuses the tabs")
  control:updateFixed({ navigate("right") })
  Assert.equal(control:status().tabFocusPocket, "tmhm", "setup moves the candidate without committing")
  Assert.equal(cursor:currentPocket(), "balls", "setup never commits")
  control:updateFixed({ { type = "confirm" } })
  local committed = control:status()
  Assert.equal(committed.pocket, "tmhm", "confirm commits the candidate")
  Assert.equal(committed.focus, "tabs", "confirm keeps tab focus")
  Assert.equal(committed.tabFocusPocket, "tmhm", "confirm synchronizes the candidate")
  Assert.isNil(committed.selected, "the empty pocket selects nothing")
  Assert.equal(cursor:currentPocket(), "tmhm", "confirm moves the committed pocket")
  Assert.equal(bag:revision(), revision, "confirm never mutates inventory")
  control:updateFixed({ navigate("left") })
  Assert.equal(control:status().tabFocusPocket, "balls", "the candidate moves back without committing")
  Assert.equal(cursor:currentPocket(), "tmhm", "candidate movement never commits")
  control:updateFixed({ { type = "confirm" } })
  local back = control:status()
  Assert.equal(back.pocket, "balls", "confirm returns to the balls pocket")
  Assert.equal(back.focus, "tabs", "confirm keeps tab focus")
  Assert.equal(back.tabFocusPocket, "balls", "confirm synchronizes the candidate")
  Assert.equal(cursor:position("balls"), 1, "returning restores the remembered position")
  Assert.equal(selectedKey(back), "GREAT_BALL", "returning restores the remembered selection")
  local settled = bag:revision()
  control:updateFixed({ { type = "confirm" } })
  local noop = control:status()
  Assert.equal(noop.pocket, "balls", "confirm on the committed candidate keeps the pocket")
  Assert.equal(noop.focus, "tabs", "confirm on the committed candidate keeps tab focus")
  Assert.equal(noop.tabFocusPocket, "balls", "confirm on the committed candidate keeps the candidate")
  Assert.equal(bag:revision(), settled, "confirm on the committed candidate never mutates inventory")
  control:updateFixed({ navigate("right") })
  Assert.equal(control:status().tabFocusPocket, "tmhm", "setup stages an abandoned candidate")
  control:updateFixed({ navigate("down") })
  Assert.equal(control:status().focus, "items", "leaving tabs returns to the grid")
  Assert.equal(cursor:currentPocket(), "balls", "abandoning the candidate never commits")
  control:updateFixed({ navigate("up") })
  Assert.equal(control:status().focus, "tabs", "re-entering focuses the tabs")
  Assert.equal(control:status().tabFocusPocket, "balls", "re-entering resets the candidate to the committed pocket")
end

-- A pocket round trip through the tabs must return browse focus to the
-- remembered per-pocket selection, not the window top-left: selection and
-- focus diverge otherwise, and a later confirm acts on a different item
-- than the restored selection names.
function T.tab_round_trip_returns_focus_to_the_remembered_selection()
  local bag = stockTwoPockets(service())
  local cursor = BagCursor.new()
  cursor:setPocket("balls")
  local control = controller(bag, cursor)
  control:updateFixed({ navigate("right") })
  Assert.equal(selectedKey(control:status()), "GREAT_BALL", "setup selects the second ball")
  control:updateFixed({ navigate("up") })
  Assert.equal(control:status().focus, "tabs", "setup focuses the tabs")
  control:updateFixed({ navigate("right") })
  control:updateFixed({ { type = "confirm" } })
  Assert.equal(cursor:currentPocket(), "tmhm", "setup leaves for another pocket")
  control:updateFixed({ navigate("left") })
  control:updateFixed({ { type = "confirm" } })
  Assert.equal(cursor:currentPocket(), "balls", "setup returns to the balls pocket")
  Assert.equal(cursor:position("balls"), 1, "returning restores the remembered position")
  Assert.equal(selectedKey(control:status()), "GREAT_BALL", "returning restores the remembered selection")
  control:updateFixed({ navigate("down") })
  local returned = control:status()
  Assert.equal(returned.focus, "items", "leaving tabs returns to the grid")
  Assert.equal(returned.focusedAbsoluteIndex, 1, "leaving tabs returns to the remembered selection")
  Assert.equal(selectedKey(returned), "GREAT_BALL", "the refocused cell carries the remembered item")
  control:updateFixed({ { type = "confirm" } })
  Assert.equal(control:status().state, "action_menu", "confirming acts on the remembered selection")
end

function T.pointer_pocket_activation_enters_item_focus()
  local bag = stockTwoPockets(service())
  local pocketCursor = BagCursor.new()
  pocketCursor:setPocket("balls")
  local control = controller(bag, pocketCursor)
  local layout = BagLayout.resolve({ manifest = manifest(), heroVisible = true })
  control:updateFixed({ navigate("up") })
  Assert.equal(control:status().focus, "tabs", "setup focuses the tabs")
  tap(control, layout, 48, 16)
  Assert.equal(pocketCursor:currentPocket(), "medicine", "tapping a tab selects its pocket")
  Assert.equal(control:status().focus, "items", "tapping a tab enters item focus")
  Assert.equal(selectedKey(control:status()), "POTION", "tapping a tab reconciles the selection")
  control:updateFixed({ navigate("up") })
  Assert.equal(control:status().focus, "tabs", "setup refocuses the tabs")
  tap(control, layout, 80, 16)
  Assert.equal(pocketCursor:currentPocket(), "balls", "tapping the current tab keeps its pocket")
  Assert.equal(control:status().focus, "items", "tapping the current tab enters item focus")
  Assert.equal(selectedKey(control:status()), "POKE_BALL")
end

function T.cancel_focus_confirms_close_and_reports_once()
  local bag = stockTwoPockets(service())
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control = controller(bag, cursor)
  control:updateFixed({ navigate("down") })
  control:updateFixed({ navigate("down") })
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
  control:updateFixed({ navigate("down") })
  control:updateFixed({ navigate("down") })
  Assert.equal(control:status().focus, "cancel", "down past the last row focuses cancel")
  control:updateFixed({ navigate("left") })
  Assert.equal(cursor:currentPocket(), "medicine", "left on cancel keeps the pocket")
  Assert.equal(control:status().focus, "cancel", "left on cancel keeps cancel focus")
  control:updateFixed({ navigate("right") })
  Assert.equal(cursor:currentPocket(), "medicine", "right on cancel keeps the pocket")
  Assert.equal(control:status().focus, "cancel", "right on cancel keeps cancel focus")
  control:updateFixed({ navigate("down") })
  Assert.equal(control:status().focus, "cancel", "down on cancel keeps cancel focus")
  control:updateFixed({ navigate("up") })
  Assert.equal(control:status().focus, "items", "up returns to the grid")
  Assert.equal(control:status().focusedAbsoluteIndex, 4, "up returns to the remembered cell")
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

function T.action_menu_uses_physical_nodes_and_fixed_cancel()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5))
  Assert.isTrue(bag:add("ITEM_1", 2))
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control = controller(bag, cursor)
  control:updateFixed({ { type = "confirm" } })
  local status = control:status()
  Assert.equal(status.state, "action_menu")
  Assert.equal(status.actionNode, 1, "the first populated source slot owns initial focus")
  control:updateFixed({ navigate("right") })
  Assert.equal(control:status().actionNode, 0, "navigation follows the retail node table through empty slots")
  control:updateFixed({ navigate("right") })
  Assert.equal(control:status().actionNode, 1, "navigation returns to the physical slot")
  control:updateFixed({ navigate("up") })
  Assert.equal(control:status().actionNode, 3, "vertical navigation uses source adjacency")
  control:updateFixed({ navigate("left") })
  Assert.equal(control:status().actionNode, 2, "empty nodes remain focusable")
  control:updateFixed({ { type = "confirm" } })
  Assert.equal(control:status().state, "action_menu", "confirming an empty node is inert")
  control:updateFixed({ navigate("right") })
  control:updateFixed({ navigate("right") })
  Assert.equal(control:status().actionNode, 4)
  control:updateFixed({ { type = "confirm" } })
  Assert.equal(control:status().state, "browsing", "node four is fixed Cancel")
end

function T.external_revision_removal_clamps_the_cursor_while_focus_may_go_empty()
  local bag = stockTwoPockets(service())
  local pocketCursor = BagCursor.new()
  pocketCursor:setPocket("balls")
  local control = controller(bag, pocketCursor)
  control:updateFixed({ navigate("right") })
  Assert.equal(selectedKey(control:status()), "GREAT_BALL")
  Assert.isTrue(bag:take("GREAT_BALL", 2), "an external mutation removes the focused item")
  control:updateFixed({})
  local status = control:status()
  Assert.equal(status.focus, "items")
  Assert.equal(status.focusedAbsoluteIndex, 1, "a valid focused cell is kept even when emptied")
  Assert.isNil(status.selected, "an emptied focus selects no item")
  Assert.equal(pocketCursor:position("balls"), 0, "the borrowed cursor keeps a valid occupied position")
end

function T.pointer_down_up_on_the_same_cell_selects()
  local bag = stockTwoPockets(service())
  local pocketCursor = BagCursor.new()
  pocketCursor:setPocket("balls")
  local control = controller(bag, pocketCursor)
  local x, y = 204, 56
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
  local firstX, firstY = 76, 56
  local secondX, secondY = 204, 56
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
  local tabX, tabY = 48, 16
  control:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = tabX, y = tabY } })
  control:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = tabX, y = tabY } })
  Assert.equal(pocketCursor:currentPocket(), "medicine", "tapping a tab selects its pocket")
  local cancelX, cancelY = 220, 176
  control:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = cancelX, y = cancelY } })
  control:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = cancelX, y = cancelY } })
  Assert.deepEqual(control:takeResult(), { kind = "closed" }, "tapping cancel closes")
end

function T.stale_capture_cannot_activate()
  local bag = stockTwoPockets(service())
  local pocketCursor = BagCursor.new()
  pocketCursor:setPocket("balls")
  local control = controller(bag, pocketCursor)
  local x = 76
  local y = 56
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
  local control = controller(bag, pocketCursor, false)
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
  local control, layoutManifest = controller(bag, pocketCursor)
  local layout = BagLayout.resolve({ manifest = layoutManifest, heroVisible = true })
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

function T.pointer_action_slot_tap_chooses_the_offered_slot_position()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a first manual-order item")
  Assert.isTrue(bag:add("ITEM_1", 2), "setup stocks a second manual-order item")
  local pocketCursor = BagCursor.new()
  pocketCursor:setPocket("medicine")
  local control, layoutManifest = controller(bag, pocketCursor)
  local layout = BagLayout.resolve({ manifest = layoutManifest, heroVisible = true })
  tap(control, layout, 76, 56)
  Assert.equal(control:status().state, "action_menu", "activating the selected cell opens the action menu")
  tap(control, layout, 144, 176)
  Assert.equal(
    control:status().state,
    "move_select",
    "the second slot chooses the second offered action through pointer alone"
  )
end

function T.quantity_keyboard_and_pointer_use_source_control_identity()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 25))
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control, layoutManifest = controller(bag, cursor)
  local layout = BagLayout.resolve({ manifest = layoutManifest, heroVisible = true })
  tap(control, layout, 76, 56)
  control:updateFixed({ { type = "confirm" } })
  Assert.equal(control:status().state, "toss_quantity")
  control:updateFixed({ navigate("right") })
  Assert.equal(control:status().quantity, 11, "keyboard right advances by ten")
  control:updateFixed({ navigate("left") })
  Assert.equal(control:status().quantity, 1, "keyboard left subtracts ten with a lower clamp")
  tap(control, layout, 16, 176)
  local status = control:status()
  Assert.equal(status.quantity, 25, "the source -100 touch control wraps at one")
  Assert.equal(status.quantityPressedControl, 3, "pointer state identifies the physical control")
end

function T.pointer_quantity_steps_confirm_and_nested_cancel_hold_across_updates()
  local bag = stockTwoPockets(service())
  local pocketCursor = BagCursor.new()
  pocketCursor:setPocket("medicine")
  local control, layoutManifest = controller(bag, pocketCursor)
  local layout = BagLayout.resolve({ manifest = layoutManifest, heroVisible = true })
  local revision = bag:revision()
  tap(control, layout, 76, 56)
  Assert.equal(control:status().state, "action_menu", "activating the selected cell opens the action menu")
  tap(control, layout, 144, 144)
  Assert.equal(control:status().state, "toss_quantity", "the first offered action starts the quantity picker")
  tap(control, layout, 80, 144)
  Assert.equal(control:status().quantity, 2, "the increment affordance steps the picked quantity")
  tap(control, layout, 80, 176)
  Assert.equal(control:status().quantity, 1, "the decrement affordance steps the picked quantity back")
  tap(control, layout, 144, 176)
  Assert.equal(control:status().state, "toss_confirm", "the confirm affordance asks for confirmation")
  -- Toss confirmation is a modal Yes/No prompt, not a Bag action slot: the
  -- YES row latches through the prompt interval into a post-choice state
  -- without mutating, and only a later acknowledgement commits.
  tap(control, layout, 224, 64)
  -- The press latched immediately, so the release half of the tap already
  -- consumed one confirmation step; eight further updates close the interval.
  for _ = 1, 8 do
    control:updateFixed({})
  end
  local acknowledged = control:status()
  Assert.equal(acknowledged.state, "toss_ack", "tapping the YES row acknowledges without mutating")
  Assert.equal(bag:quantity("POTION"), 5, "the YES tap changes no quantities")
  Assert.equal(bag:revision(), revision, "the YES tap bumps no service revision")
  control:updateFixed({ { type = "confirm" } })
  local status = control:status()
  Assert.equal(status.state, "browsing", "the first acknowledgement returns to browsing")
  Assert.equal(bag:quantity("POTION"), 4, "one pointer toss removes the picked copies")
  Assert.equal(bag:revision(), revision + 1, "one pointer toss mutates exactly once")
  tap(control, layout, 76, 56)
  Assert.equal(control:status().state, "action_menu", "a later activation reopens the action menu")
  tap(control, layout, 220, 176)
  Assert.equal(control:status().state, "browsing", "the nested cancel pops one level without mutation")
  Assert.equal(bag:revision(), revision + 1, "the nested cancel never mutates the inventory")
end

function T.dismiss_from_browsing_closes_without_unwinding()
  local control = controller(stockTwoPockets(service()), BagCursor.new())
  Assert.equal(control:status().state, "browsing", "setup starts in top-level browsing")
  control:updateFixed({ { type = "dismiss" } })
  Assert.deepEqual(control:takeResult(), { kind = "closed" }, "dismiss closes the bag immediately")
  Assert.isFalse(control:status().open, "the bag is closed")
end

function T.dismiss_from_a_nested_action_menu_closes_without_unwinding()
  local bag = stockTwoPockets(service())
  local pocketCursor = BagCursor.new()
  pocketCursor:setPocket("balls")
  local control = controller(bag, pocketCursor)
  local revision = bag:revision()
  control:updateFixed({ { type = "confirm" } })
  Assert.equal(control:status().state, "action_menu", "setup opens the nested action menu")
  control:updateFixed({ { type = "dismiss" } })
  Assert.deepEqual(control:takeResult(), { kind = "closed" }, "dismiss closes instead of popping one level")
  Assert.isFalse(control:status().open, "the bag is closed")
  Assert.equal(bag:revision(), revision, "dismiss never mutates the inventory")
end

function T.dismiss_from_a_toss_state_closes_without_unwinding()
  local bag = stockTwoPockets(service())
  local pocketCursor = BagCursor.new()
  pocketCursor:setPocket("medicine")
  local control, layoutManifest = controller(bag, pocketCursor)
  local layout = BagLayout.resolve({ manifest = layoutManifest, heroVisible = true })
  local revision = bag:revision()
  tap(control, layout, 76, 56)
  Assert.equal(control:status().state, "action_menu", "setup opens the action menu")
  tap(control, layout, 144, 144)
  Assert.equal(control:status().state, "toss_quantity", "setup enters the nested quantity picker")
  control:updateFixed({ { type = "dismiss" } })
  Assert.deepEqual(control:takeResult(), { kind = "closed" }, "dismiss closes instead of popping to the menu")
  Assert.isFalse(control:status().open, "the bag is closed")
  Assert.equal(bag:revision(), revision, "dismiss never mutates the inventory")
end

function T.dismiss_ends_the_batch_so_later_events_cannot_reopen_or_mutate()
  local bag = stockTwoPockets(service())
  local control = controller(bag, BagCursor.new())
  local revision = bag:revision()
  control:updateFixed({ { type = "dismiss" }, { type = "confirm" }, navigate("down") })
  Assert.deepEqual(control:takeResult(), { kind = "closed" }, "only the terminal close survives the batch")
  Assert.isNil(control:takeResult(), "the close result is delivered exactly once")
  Assert.equal(bag:revision(), revision, "events after dismiss never mutate")
end

function T.unknown_events_are_programming_errors()
  local control = controller(stockTwoPockets(service()), BagCursor.new())
  Assert.throws(function()
    control:updateFixed({ { type = "warp" } })
  end)
end

local function stockItemsPocket(bag, quantity)
  local natives = { 6, 12, 18, 24, 30, 36, 42, 48 }
  assert(quantity >= 1 and quantity <= #natives, "the padded-grid probe needs one to eight items")
  for index = 1, quantity do
    Assert.isTrue(bag:add("ITEM_" .. natives[index], 1))
  end
  return bag
end

local function itemsControl(bag, pocketKey)
  local cursor = BagCursor.new()
  cursor:setPocket(pocketKey or "items")
  return controller(bag, cursor), cursor
end

function T.empty_pocket_opens_on_the_first_cell_with_no_item_selected()
  local control, cursor = itemsControl(service())
  local status = control:status()
  Assert.equal(status.focus, "items")
  Assert.equal(status.focusedAbsoluteIndex, 0, "browse focus starts on the top-left visible cell")
  Assert.equal(status.focusedVisibleIndex, 0)
  Assert.isNil(status.selected, "an empty focus selects no item")
  Assert.isNil(status.selectedAbsoluteIndex, "an empty focus publishes no item index")
  Assert.equal(cursor:position("items"), 0, "the borrowed cursor keeps a valid occupied position")
end

function T.empty_pocket_grid_navigation_reaches_every_cell()
  local control, cursor = itemsControl(service())
  local function focusedAbsolute()
    local status = control:status()
    Assert.equal(status.focus, "items")
    return assert(status.focusedAbsoluteIndex, "browse focus always names its cell")
  end
  Assert.equal(focusedAbsolute(), 0)
  control:updateFixed({ navigate("right") })
  Assert.equal(focusedAbsolute(), 1)
  control:updateFixed({ navigate("down") })
  Assert.equal(focusedAbsolute(), 3)
  control:updateFixed({ navigate("down") })
  Assert.equal(focusedAbsolute(), 5)
  control:updateFixed({ navigate("left") })
  Assert.equal(focusedAbsolute(), 4)
  control:updateFixed({ navigate("up") })
  Assert.equal(focusedAbsolute(), 2)
  control:updateFixed({ navigate("up") })
  Assert.equal(focusedAbsolute(), 0)
  Assert.isNil(control:status().selected, "empty navigation never invents a selection")
  Assert.equal(cursor:position("items"), 0, "empty navigation never moves the occupied cursor")
end

function T.empty_pocket_confirm_and_info_stay_no_ops()
  local control, cursor = itemsControl(service())
  local revision = cursor:position("items")
  control:updateFixed({ navigate("right") })
  control:updateFixed({ { type = "confirm" } })
  Assert.equal(control:status().state, "browsing", "confirming an empty cell opens no menu")
  Assert.isNil(control:takeResult(), "confirming an empty cell closes nothing")
  Assert.equal(cursor:position("items"), revision, "confirming an empty cell moves no cursor")
  local narrow = controller(service(), BagCursor.new(), false)
  narrow:updateFixed({ { type = "menu" } })
  Assert.equal(narrow:status().state, "browsing", "info on an empty cell overlays nothing")
  Assert.isNil(narrow:takeResult())
end

function T.empty_pocket_vertical_edges_reach_tabs_and_cancel_and_return()
  local control, _ = itemsControl(service())
  control:updateFixed({ navigate("up") })
  Assert.equal(control:status().focus, "tabs", "up past the top row focuses the tabs")
  Assert.equal(control:status().tabFocusPocket, "items")
  control:updateFixed({ navigate("down") })
  Assert.equal(control:status().focus, "items", "leaving tabs returns to the grid")
  Assert.equal(control:status().focusedAbsoluteIndex, 0, "vertical return restores the remembered cell")
  control:updateFixed({ navigate("down") })
  control:updateFixed({ navigate("down") })
  Assert.equal(control:status().focus, "items")
  Assert.equal(control:status().focusedAbsoluteIndex, 4)
  control:updateFixed({ navigate("down") })
  Assert.equal(control:status().focus, "cancel", "down past the last row focuses cancel")
  control:updateFixed({ navigate("up") })
  Assert.equal(control:status().focus, "items")
  Assert.equal(control:status().focusedAbsoluteIndex, 4, "cancel returns to the remembered cell")
end

function T.single_item_pocket_keeps_selection_while_empty_neighbors_take_focus()
  local control, cursor = itemsControl(stockItemsPocket(service(), 1))
  local status = control:status()
  Assert.equal(status.focusedAbsoluteIndex, 0)
  Assert.equal(selectedKey(status), "ITEM_6")
  control:updateFixed({ navigate("right") })
  status = control:status()
  Assert.equal(status.focus, "items")
  Assert.equal(status.focusedAbsoluteIndex, 1)
  Assert.equal(status.focusedVisibleIndex, 1)
  Assert.isNil(status.selected, "an empty focus clears the browse selection")
  Assert.isNil(status.selectedAbsoluteIndex)
  Assert.equal(cursor:position("items"), 0, "empty focus never invents an item index")
  control:updateFixed({ { type = "confirm" } })
  Assert.equal(control:status().state, "browsing", "confirming an empty cell opens no menu")
  Assert.isNil(control:takeResult())
end

function T.five_item_pocket_pads_to_a_full_row()
  local control, _ = itemsControl(stockItemsPocket(service(), 5))
  control:updateFixed({ navigate("down") })
  control:updateFixed({ navigate("down") })
  Assert.equal(control:status().focusedAbsoluteIndex, 4)
  Assert.equal(selectedKey(control:status()), "ITEM_30")
  control:updateFixed({ navigate("right") })
  local status = control:status()
  Assert.equal(status.focusedAbsoluteIndex, 5, "the padded trailing cell takes focus")
  Assert.isNil(status.selected)
  control:updateFixed({ navigate("down") })
  Assert.equal(control:status().focus, "cancel", "down past the padded row focuses cancel")
end

function T.six_item_pocket_bottom_row_reaches_cancel()
  local control, _ = itemsControl(stockItemsPocket(service(), 6))
  control:updateFixed({ navigate("down") })
  control:updateFixed({ navigate("down") })
  control:updateFixed({ navigate("right") })
  Assert.equal(control:status().focusedAbsoluteIndex, 5)
  control:updateFixed({ navigate("down") })
  Assert.equal(control:status().focus, "cancel", "no fabricated row follows the last occupied row")
end

function T.trailing_empty_cell_after_an_odd_row_takes_keyboard_focus()
  local control, cursor = itemsControl(stockItemsPocket(service(), 7))
  control:updateFixed({ navigate("right") })
  control:updateFixed({ navigate("down") })
  control:updateFixed({ navigate("down") })
  Assert.equal(cursor:position("items"), 5)
  control:updateFixed({ navigate("down") })
  local status = control:status()
  Assert.equal(status.focus, "items")
  Assert.equal(status.focusedAbsoluteIndex, 7, "the padded cell past six items takes focus")
  Assert.equal(status.focusedVisibleIndex, 5)
  Assert.equal(status.visibleStart, 2, "the window scrolls one row to show the padded cell")
  Assert.isNil(status.selected)
  Assert.isNil(status.selectedAbsoluteIndex)
  Assert.equal(cursor:position("items"), 5, "scroll follows focus but selection stays occupied")
  control:updateFixed({ { type = "confirm" } })
  Assert.equal(control:status().state, "browsing", "confirming the padded cell opens no menu")
  Assert.isNil(control:takeResult())
end

function T.eight_item_pocket_scrolls_rows_without_fabricated_cells()
  local control, cursor = itemsControl(stockItemsPocket(service(), 8))
  control:updateFixed({ navigate("right") })
  control:updateFixed({ navigate("down") })
  control:updateFixed({ navigate("down") })
  control:updateFixed({ navigate("down") })
  local status = control:status()
  Assert.equal(status.focusedAbsoluteIndex, 7)
  Assert.equal(status.focusedVisibleIndex, 5)
  Assert.equal(status.visibleStart, 2)
  Assert.equal(selectedKey(status), "ITEM_48")
  Assert.equal(cursor:position("items"), 7, "occupied focus synchronizes the cursor")
  Assert.equal(cursor:scroll("items"), 2)
  control:updateFixed({ navigate("down") })
  Assert.equal(control:status().focus, "cancel", "no fabricated row follows the last occupied row")
  control:updateFixed({ navigate("up") })
  Assert.equal(control:status().focusedAbsoluteIndex, 7, "cancel returns to the remembered cell")
end

function T.browse_journey_across_tabs_and_cancel_keeps_window_and_memory()
  local bag = stockEightItems(service())
  local cursor = BagCursor.new()
  cursor:setPocket("items")
  local control = controller(bag, cursor)
  control:updateFixed({ navigate("right") })
  control:updateFixed({ navigate("down") })
  Assert.equal(control:status().focusedAbsoluteIndex, 3)
  control:updateFixed({ navigate("up") })
  control:updateFixed({ navigate("up") })
  Assert.equal(control:status().focus, "tabs", "up past the top row focuses the tabs")
  Assert.equal(control:status().tabFocusPocket, "items")
  Assert.equal(cursor:currentPocket(), "items", "entering tabs never commits")
  local revision = bag:revision()
  control:updateFixed({ navigate("right") })
  Assert.equal(control:status().tabFocusPocket, "medicine", "tab travel moves the candidate")
  Assert.equal(cursor:currentPocket(), "items", "tab travel never commits")
  control:updateFixed({ navigate("left") })
  control:updateFixed({ navigate("left") })
  Assert.equal(control:status().tabFocusPocket, "key_items", "tab travel past the first pocket wraps")
  Assert.equal(cursor:currentPocket(), "items", "wrap never commits")
  Assert.equal(bag:revision(), revision, "tab travel never mutates inventory")
  control:updateFixed({ navigate("right") })
  Assert.equal(control:status().tabFocusPocket, "items")
  control:updateFixed({ navigate("down") })
  local status = control:status()
  Assert.equal(status.focus, "items", "leaving tabs returns to the grid")
  Assert.equal(status.focusedAbsoluteIndex, 1, "vertical return restores the remembered cell")
  Assert.equal(cursor:currentPocket(), "items", "abandoning the candidate never commits")
end

function T.external_removal_of_the_focused_item_normalizes_focus()
  local bag = stockTwoPockets(service())
  local cursor = BagCursor.new()
  cursor:setPocket("balls")
  local control = controller(bag, cursor)
  control:updateFixed({ navigate("right") })
  Assert.equal(selectedKey(control:status()), "GREAT_BALL")
  Assert.isTrue(bag:take("GREAT_BALL", 2), "an external mutation removes the focused item")
  control:updateFixed({})
  local status = control:status()
  local focused = assert(status.focusedAbsoluteIndex, "focus normalizes to a valid cell after removal")
  Assert.isTrue(focused >= 0 and focused < 6, "the normalized focus stays inside the logical grid")
  Assert.equal(cursor:position("balls"), 0, "the borrowed cursor keeps a valid occupied position")
  control:updateFixed({ navigate("left") })
  control:updateFixed({ navigate("down") })
  status = control:status()
  Assert.isTrue(status.focus == "items" or status.focus == "cancel", "navigation resolves after the revision")
end

function T.pointer_hover_and_tap_focus_empty_browse_cells_without_opening_actions()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5))
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control = controller(bag, cursor)
  local x = 204
  local y = 56
  control:updateFixed({ { type = "pointer_move", pointerId = "touch:0", x = x, y = y } })
  local status = control:status()
  Assert.equal(status.focus, "items")
  Assert.equal(status.focusedVisibleIndex, 1, "hover focuses the empty browse cell")
  Assert.isNil(status.selected)
  Assert.equal(cursor:position("medicine"), 0, "hover never invents an item index")
  control:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = x, y = y } })
  control:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = x, y = y } })
  Assert.equal(control:status().state, "browsing", "tapping an empty cell opens no menu")
  Assert.isNil(control:takeResult())
  control:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = x, y = y } })
  control:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = x, y = y } })
  Assert.equal(control:status().state, "browsing", "confirming an empty cell opens no menu")
  Assert.isNil(control:takeResult())
end

function T.scrolled_partial_window_keyboard_reaches_every_visible_cell_before_cancel()
  local bag = stockItemsPocket(service(), 8)
  local control, cursor = itemsControl(bag)
  local revision = bag:revision()
  control:updateFixed({ { type = "pointer_scroll", pointerId = "touch:0", dx = 0, dy = 1 } })
  local status = control:status()
  Assert.equal(status.visibleStart, 6, "paging carries the window to the partial page")
  Assert.equal(status.focusedAbsoluteIndex, 6)
  Assert.equal(status.focusedVisibleIndex, 0)
  Assert.equal(selectedKey(status), "ITEM_42")
  control:updateFixed({ navigate("right") })
  status = control:status()
  Assert.equal(status.focusedAbsoluteIndex, 7, "right reaches the second occupied cell")
  Assert.equal(status.focusedVisibleIndex, 1)
  Assert.equal(selectedKey(status), "ITEM_48")
  control:updateFixed({ navigate("down") })
  status = control:status()
  Assert.equal(status.focus, "items", "down from the first row stays inside the visible window")
  Assert.equal(status.focusedAbsoluteIndex, 9, "down from cell 7 reaches the empty cell below it")
  Assert.equal(status.focusedVisibleIndex, 3)
  Assert.isNil(status.selected, "an empty focus selects no item")
  control:updateFixed({ navigate("left") })
  status = control:status()
  Assert.equal(status.focusedAbsoluteIndex, 8, "left reaches the empty row sibling")
  Assert.equal(status.focusedVisibleIndex, 2)
  Assert.isNil(status.selected, "an empty focus selects no item")
  control:updateFixed({ navigate("down") })
  status = control:status()
  Assert.equal(status.focusedAbsoluteIndex, 10, "down reaches the last-row empty cell")
  Assert.equal(status.focusedVisibleIndex, 4)
  Assert.isNil(status.selected, "an empty focus selects no item")
  control:updateFixed({ navigate("right") })
  status = control:status()
  Assert.equal(status.focusedAbsoluteIndex, 11, "right reaches the final visible cell")
  Assert.equal(status.focusedVisibleIndex, 5)
  Assert.isNil(status.selected, "an empty focus selects no item")
  Assert.equal(cursor:position("items"), 7, "empty focus never moves the occupied cursor")
  Assert.equal(cursor:scroll("items"), 6, "empty focus keeps the scrolled window")
  Assert.equal(bag:revision(), revision, "keyboard focus never mutates inventory")
  control:updateFixed({ navigate("down") })
  Assert.equal(control:status().focus, "cancel", "down past the last visible row focuses cancel")
  control:updateFixed({ navigate("up") })
  status = control:status()
  Assert.equal(status.focus, "items", "cancel returns to the grid")
  Assert.equal(status.focusedAbsoluteIndex, 11, "cancel returns to the remembered cell")
end

function T.scrolled_partial_window_pointer_targets_every_trailing_empty_cell_exactly()
  local bag = stockItemsPocket(service(), 8)
  local control, cursor = itemsControl(bag)
  control:updateFixed({ { type = "pointer_scroll", pointerId = "touch:0", dx = 0, dy = 1 } })
  Assert.equal(control:status().visibleStart, 6, "setup pages to the partial window")
  local revision = bag:revision()
  local cells = {
    { x = 48, y = 96, absolute = 8, visible = 2 },
    { x = 176, y = 96, absolute = 9, visible = 3 },
    { x = 48, y = 136, absolute = 10, visible = 4 },
    { x = 176, y = 136, absolute = 11, visible = 5 },
  }
  for _, cell in ipairs(cells) do
    local x = cell.x
    local y = cell.y
    control:updateFixed({ { type = "pointer_move", pointerId = "touch:0", x = x, y = y } })
    local status = control:status()
    Assert.equal(status.focus, "items")
    Assert.equal(status.focusedAbsoluteIndex, cell.absolute, "hover focuses the exact empty cell")
    Assert.equal(status.focusedVisibleIndex, cell.visible)
    Assert.isNil(status.selected, "hovering an empty cell selects no item")
    Assert.equal(cursor:position("items"), 6, "hover never moves the occupied cursor")
    control:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = x, y = y } })
    control:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = x, y = y } })
    status = control:status()
    Assert.equal(status.state, "browsing", "tapping an empty cell opens no menu")
    Assert.isNil(control:takeResult(), "tapping an empty cell closes nothing")
    Assert.equal(bag:revision(), revision, "pointer focus never mutates inventory")
  end
  Assert.equal(cursor:scroll("items"), 6, "pointer focus keeps the scrolled window")
end

function T.external_fill_of_the_focused_empty_cell_reconciles_selection_before_confirm()
  local bag = stockItemsPocket(service(), 1)
  local control, cursor = itemsControl(bag)
  control:updateFixed({ navigate("right") })
  local status = control:status()
  Assert.equal(status.focusedAbsoluteIndex, 1, "setup focuses the empty neighbor")
  Assert.isNil(status.selected, "an empty focus selects no item")
  Assert.equal(cursor:position("items"), 0)
  Assert.isTrue(bag:add("ITEM_12", 1), "an external mutation fills the focused cell")
  control:updateFixed({})
  status = control:status()
  Assert.equal(status.focusedAbsoluteIndex, 1, "reconciliation keeps the focused cell")
  Assert.equal(cursor:position("items"), 1, "reconciliation carries the cursor to the focused cell")
  Assert.equal(status.selectedAbsoluteIndex, 1)
  Assert.equal(selectedKey(status), "ITEM_12", "focus and selection name the same new item")
  local revision = bag:revision()
  control:updateFixed({ { type = "confirm" } })
  status = control:status()
  Assert.equal(status.state, "action_menu", "confirming the reconciled cell opens its menu")
  Assert.isTrue(type(status.actions) == "table" and #status.actions >= 1, "the menu offers an action plus cancel")
  Assert.equal(bag:revision(), revision, "opening the menu never mutates inventory")
  control:updateFixed({})
  Assert.equal(control:status().state, "action_menu", "the menu survives a quiet update")
end

---@param actions table<integer, table<string, unknown>>|nil the published action set
---@param id string the action identity to locate
---@return table<string, unknown>? the matching action record, when offered
local function actionById(actions, id)
  if actions == nil then
    return nil
  end
  for _, action in ipairs(actions) do
    if action.id == id then
      return action
    end
  end
  return nil
end

-- An open action menu survives an external revision that keeps the same
-- selected item: the menu stays open on the item while its offered actions
-- follow the live registration facts, and a later confirm dispatches the
-- refreshed action rather than the snapshot from when the menu opened.
function T.external_registration_revision_refreshes_same_item_actions_before_dispatch()
  local bag = service()
  Assert.isTrue(bag:add("BICYCLE", 1))
  local cursor = BagCursor.new()
  cursor:setPocket("key_items")
  local control = controller(bag, cursor)
  Assert.equal(selectedKey(control:status()), "BICYCLE", "setup selects the stocked bicycle")
  control:updateFixed({ { type = "confirm" } })
  local opened = control:status()
  Assert.equal(opened.state, "action_menu", "confirming the bicycle opens the action menu")
  Assert.equal(selectedKey(opened), "BICYCLE", "the menu keeps the confirmed selection")
  Assert.equal(opened.actionNode, 1, "the lone registration action owns initial focus")
  local offered =
    assert(actionById(opened.actions, "register"), "the menu offers registration while the bicycle is unregistered")
  Assert.equal(offered.slot, 1, "registration keeps its physical slot")
  Assert.isNil(actionById(opened.actions, "unregister"), "release is absent while nothing is registered")
  Assert.equal(bag:tryRegister("BICYCLE"), "slot1", "an external revision registers the same bicycle")
  control:updateFixed({})
  local refreshed = control:status()
  Assert.equal(refreshed.state, "action_menu", "the menu survives a same-item external revision")
  Assert.equal(selectedKey(refreshed), "BICYCLE", "the revision keeps the semantic selection")
  Assert.equal(refreshed.actionNode, 1, "the revision keeps the physical focus node")
  local released =
    assert(actionById(refreshed.actions, "unregister"), "the quiet refresh exposes release for the registered bicycle")
  Assert.equal(released.slot, 1, "release keeps the registration slot")
  Assert.isNil(actionById(refreshed.actions, "register"), "registration is absent while registered")
  Assert.isTrue(bag:unregister("BICYCLE"), "a second external revision releases the bicycle")
  control:updateFixed({ { type = "confirm" } })
  local dispatched = control:status()
  Assert.equal(dispatched.state, "browsing", "confirming dispatches through the refreshed menu")
  Assert.deepEqual(
    bag:registeredItems(),
    { "BICYCLE" },
    "the confirm runs the current registration, not the stale release"
  )
end

-- A lone copy skips the quantity picker: choosing Toss with exactly one
-- owned copy opens the modal Yes/No confirmation directly with the picked
-- quantity of one, without ever entering the quantity state.
function T.single_copy_toss_skips_the_quantity_picker()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 1), "setup stocks a single tossable copy")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control, layoutManifest = controller(bag, cursor)
  local layout = BagLayout.resolve({ manifest = layoutManifest, heroVisible = true })
  local revision = bag:revision()
  tap(control, layout, 76, 56)
  Assert.equal(control:status().state, "action_menu", "activating the selected cell opens the action menu")
  tap(control, layout, 144, 144)
  local status = control:status()
  Assert.equal(status.state, "toss_confirm", "a single copy confirms without the quantity picker")
  Assert.equal(status.quantity, 1, "the skipped picker preselects the one owned copy")
  local prompt = assert(status.yesNoPrompt, "the confirmation exposes its modal prompt presentation")
  Assert.equal(prompt.selected, "yes", "the prompt opens with YES selected")
  Assert.deepEqual(prompt.buttons.yes, { x = 200, y = 48, width = 48, height = 32 }, "YES sits on the upper row")
  Assert.deepEqual(prompt.buttons.no, { x = 200, y = 80, width = 48, height = 32 }, "NO stacks below YES")
  Assert.equal(bag:revision(), revision, "skipping the picker mutates nothing")
  Assert.equal(bag:quantity("POTION"), 1, "skipping the picker changes no quantities")
end

-- Cancelling the quantity picker returns straight to browsing: the
-- cancelled amount never reopens the action menu and never mutates.
function T.quantity_cancel_returns_directly_to_browsing()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a tossable stack")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control, layoutManifest = controller(bag, cursor)
  local layout = BagLayout.resolve({ manifest = layoutManifest, heroVisible = true })
  local revision = bag:revision()
  tap(control, layout, 76, 56)
  tap(control, layout, 144, 144)
  Assert.equal(control:status().state, "toss_quantity", "setup enters the quantity picker")
  control:updateFixed({ { type = "cancel" } })
  local status = control:status()
  Assert.equal(status.state, "browsing", "one cancel leaves the picker for browsing")
  Assert.equal(bag:revision(), revision, "cancelling the picker mutates nothing")
  Assert.equal(bag:quantity("POTION"), 5, "cancelling the picker changes no quantities")
end

-- Down plus confirm is a rejection, never a destructive confirmation: the
-- vertical toggle moves YES to NO, and accepting NO returns to browsing
-- with the inventory untouched.
function T.down_then_confirm_rejects_the_toss()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a tossable stack")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control, layoutManifest = controller(bag, cursor)
  local layout = BagLayout.resolve({ manifest = layoutManifest, heroVisible = true })
  local revision = bag:revision()
  tap(control, layout, 76, 56)
  tap(control, layout, 144, 144)
  control:updateFixed({ { type = "confirm" } })
  Assert.equal(control:status().state, "toss_confirm", "setup reaches the modal confirmation")
  control:updateFixed({ navigate("down") })
  local prompt = assert(control:status().yesNoPrompt, "the confirmation exposes its modal prompt")
  Assert.equal(prompt.selected, "no", "down toggles YES to NO")
  control:updateFixed({ { type = "confirm" } })
  settlePromptChoice(control)
  local status = control:status()
  Assert.equal(status.state, "browsing", "accepting NO returns to browsing")
  Assert.equal(bag:revision(), revision, "a rejected toss mutates nothing")
  Assert.equal(bag:quantity("POTION"), 5, "a rejected toss changes no quantities")
end

-- The modal rows own pointer confirmation: YES acknowledges into the
-- post-choice state and NO returns to browsing, both without mutating,
-- while the retired action-slot and cancel coordinates resolve nothing.
function T.pointer_rows_resolve_the_choice_and_retired_controls_resolve_nothing()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a tossable stack")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control, layoutManifest = controller(bag, cursor)
  local layout = BagLayout.resolve({ manifest = layoutManifest, heroVisible = true })
  local revision = bag:revision()
  tap(control, layout, 76, 56)
  tap(control, layout, 144, 144)
  control:updateFixed({ { type = "confirm" } })
  Assert.equal(control:status().state, "toss_confirm", "setup reaches the modal confirmation")
  tap(control, layout, 48, 176)
  Assert.equal(control:status().state, "toss_confirm", "the retired slot coordinate never confirms")
  Assert.equal(bag:revision(), revision, "the retired slot coordinate mutates nothing")
  tap(control, layout, 224, 180)
  Assert.equal(control:status().state, "toss_confirm", "the retired cancel coordinate never cancels")
  Assert.equal(bag:revision(), revision, "the retired cancel coordinate mutates nothing")
  tap(control, layout, 224, 96)
  settlePromptChoice(control)
  Assert.equal(control:status().state, "browsing", "the NO row returns to browsing")
  Assert.equal(bag:revision(), revision, "the NO row mutates nothing")
  Assert.equal(bag:quantity("POTION"), 5, "the NO row changes no quantities")
  tap(control, layout, 76, 56)
  tap(control, layout, 144, 144)
  control:updateFixed({ { type = "confirm" } })
  Assert.equal(control:status().state, "toss_confirm", "setup reaches the modal confirmation again")
  tap(control, layout, 224, 64)
  settlePromptChoice(control)
  local acknowledged = control:status()
  Assert.equal(acknowledged.state, "toss_ack", "the YES row acknowledges without mutating")
  Assert.isNil(acknowledged.yesNoPrompt, "the prompt closes once YES is accepted")
  Assert.equal(bag:revision(), revision, "the YES row mutates nothing")
  Assert.equal(bag:quantity("POTION"), 5, "the YES row changes no quantities")
end

-- Accepting YES is non-destructive: the controller enters the
-- acknowledgement state with the picked amount, and only a later
-- acknowledgement commits exactly once.
function T.yes_then_a_later_acknowledgement_commits_exactly_once()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a tossable stack")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control, layoutManifest = controller(bag, cursor)
  local layout = BagLayout.resolve({ manifest = layoutManifest, heroVisible = true })
  local revision = bag:revision()
  tap(control, layout, 76, 56)
  tap(control, layout, 144, 144)
  control:updateFixed({ { type = "confirm" } })
  control:updateFixed({ { type = "confirm" } })
  settlePromptChoice(control)
  local acknowledged = control:status()
  Assert.equal(acknowledged.state, "toss_ack", "accepting YES enters the acknowledgement state")
  Assert.equal(acknowledged.quantity, 1, "the acknowledgement carries the picked amount")
  Assert.equal(bag:revision(), revision, "entering the acknowledgement mutates nothing")
  control:updateFixed({ { type = "confirm" } })
  local committed = control:status()
  Assert.equal(committed.state, "browsing", "the first acknowledgement returns to browsing")
  Assert.equal(bag:quantity("POTION"), 4, "the acknowledgement removes the picked copies")
  Assert.equal(bag:revision(), revision + 1, "the acknowledgement mutates exactly once")
  control:updateFixed({ { type = "confirm" } })
  Assert.equal(bag:quantity("POTION"), 4, "a later input cannot repeat the toss")
  Assert.equal(bag:revision(), revision + 1, "a later input bumps no further revision")
end

-- Cancelling from the acknowledgement commits exactly like confirming:
-- the first later cancel removes the picked copies and returns to
-- browsing without needing a prior arming input.
function T.cancel_from_the_acknowledgement_commits_immediately()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a tossable stack")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control, layoutManifest = controller(bag, cursor)
  local layout = BagLayout.resolve({ manifest = layoutManifest, heroVisible = true })
  local revision = bag:revision()
  tap(control, layout, 76, 56)
  tap(control, layout, 144, 144)
  control:updateFixed({ { type = "confirm" } })
  control:updateFixed({ { type = "confirm" } })
  settlePromptChoice(control)
  Assert.equal(control:status().state, "toss_ack", "setup reaches the acknowledgement state")
  Assert.equal(bag:revision(), revision, "entering the acknowledgement mutates nothing")
  control:updateFixed({ { type = "cancel" } })
  local committed = control:status()
  Assert.equal(committed.state, "browsing", "the first cancel returns to browsing")
  Assert.equal(bag:quantity("POTION"), 4, "the cancel removes the picked copies")
  Assert.equal(bag:revision(), revision + 1, "the cancel mutates exactly once")
end

-- A press inside the pane acknowledges like the keys do: the first
-- in-pane press on a later update commits and returns to browsing.
function T.pointer_press_inside_the_pane_acknowledges_immediately()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a tossable stack")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control, layoutManifest = controller(bag, cursor)
  local layout = BagLayout.resolve({ manifest = layoutManifest, heroVisible = true })
  local revision = bag:revision()
  tap(control, layout, 76, 56)
  tap(control, layout, 144, 144)
  control:updateFixed({ { type = "confirm" } })
  control:updateFixed({ { type = "confirm" } })
  settlePromptChoice(control)
  Assert.equal(control:status().state, "toss_ack", "setup reaches the acknowledgement state")
  Assert.equal(bag:revision(), revision, "entering the acknowledgement mutates nothing")
  control:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = 10, y = 10 } })
  local committed = control:status()
  Assert.equal(committed.state, "browsing", "the first in-pane press returns to browsing")
  Assert.equal(bag:quantity("POTION"), 4, "the in-pane press removes the picked copies")
  Assert.equal(bag:revision(), revision + 1, "the in-pane press mutates exactly once")
end

-- A press outside the pane resolves nothing: the acknowledgement state
-- holds and the inventory stays untouched.
function T.pointer_press_outside_the_pane_never_acknowledges()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a tossable stack")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control, layoutManifest = controller(bag, cursor)
  local layout = BagLayout.resolve({ manifest = layoutManifest, heroVisible = true })
  local revision = bag:revision()
  tap(control, layout, 76, 56)
  tap(control, layout, 144, 144)
  control:updateFixed({ { type = "confirm" } })
  control:updateFixed({ { type = "confirm" } })
  settlePromptChoice(control)
  Assert.equal(control:status().state, "toss_ack", "setup reaches the acknowledgement state")
  control:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = 300, y = 200 } })
  Assert.equal(control:status().state, "toss_ack", "a press outside the pane never acknowledges")
  Assert.equal(bag:quantity("POTION"), 5, "the outside press changes no quantities")
  Assert.equal(bag:revision(), revision, "the outside press mutates nothing")
end

-- The YES-producing input edge never doubles as the acknowledgement: two
-- confirms in one batch still leave the controller waiting in the
-- acknowledgement state with the inventory untouched.
function T.yes_and_acknowledgement_cannot_share_one_input_batch()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a tossable stack")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control, layoutManifest = controller(bag, cursor)
  local layout = BagLayout.resolve({ manifest = layoutManifest, heroVisible = true })
  local revision = bag:revision()
  tap(control, layout, 76, 56)
  tap(control, layout, 144, 144)
  control:updateFixed({ { type = "confirm" } })
  Assert.equal(control:status().state, "toss_confirm", "setup reaches the modal confirmation")
  control:updateFixed({ { type = "confirm" }, { type = "confirm" } })
  settlePromptChoice(control)
  Assert.equal(control:status().state, "toss_ack", "the batch edge after YES still waits for a later input")
  Assert.equal(bag:revision(), revision, "the shared batch mutates nothing")
  Assert.equal(bag:quantity("POTION"), 5, "the shared batch changes no quantities")
end

-- Cancelling the modal prompt resolves NO: one cancel press returns to
-- browsing without mutation instead of reopening the action menu.
function T.modal_cancel_resolves_no_and_returns_to_browsing()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a tossable stack")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control, layoutManifest = controller(bag, cursor)
  local layout = BagLayout.resolve({ manifest = layoutManifest, heroVisible = true })
  local revision = bag:revision()
  tap(control, layout, 76, 56)
  tap(control, layout, 144, 144)
  control:updateFixed({ { type = "confirm" } })
  Assert.equal(control:status().state, "toss_confirm", "setup reaches the modal confirmation")
  control:updateFixed({ { type = "cancel" } })
  settlePromptChoice(control)
  Assert.equal(control:status().state, "browsing", "one modal cancel returns to browsing")
  Assert.equal(bag:revision(), revision, "the modal cancel mutates nothing")
end

-- Accepting YES only latches the modal choice: the controller stays in
-- the confirmation state through every later prompt update, mirrors the
-- prompt highlight phase, and only the terminal prompt update acknowledges
-- into the post-choice state without mutating. A later acknowledgement
-- still commits exactly once.
function T.toss_acceptance_waits_through_the_prompt_interval_before_acknowledging()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a tossable stack")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control, layoutManifest = controller(bag, cursor)
  local layout = BagLayout.resolve({ manifest = layoutManifest, heroVisible = true })
  local revision = bag:revision()
  tap(control, layout, 76, 56)
  tap(control, layout, 144, 144)
  control:updateFixed({ { type = "confirm" } })
  Assert.equal(control:status().state, "toss_confirm", "setup reaches the modal confirmation")
  control:updateFixed({ { type = "confirm" } })
  local latched = control:status()
  Assert.equal(latched.state, "toss_confirm", "the choice input latches without leaving confirmation")
  local prompt = assert(latched.yesNoPrompt, "the confirmation exposes its modal prompt")
  Assert.equal(prompt.selected, "yes", "the choice input keeps the YES row")
  Assert.isTrue(prompt.selectionHighlighted, "the choice input leaves the row highlighted")
  Assert.equal(bag:revision(), revision, "latching the choice mutates nothing")
  Assert.equal(bag:quantity("POTION"), 5, "latching the choice changes no quantities")
  local phases = { true, true, false, false, true, true, false, false }
  for index, phase in ipairs(phases) do
    control:updateFixed({})
    local waiting = control:status()
    Assert.equal(waiting.state, "toss_confirm", "interval update " .. index .. " stays in confirmation")
    local waitingPrompt = assert(waiting.yesNoPrompt, "interval update " .. index .. " keeps its prompt")
    Assert.equal(waitingPrompt.selected, "yes", "interval update " .. index .. " keeps the YES row")
    if phase then
      Assert.isTrue(waitingPrompt.selectionHighlighted, "interval update " .. index .. " shows the blink phase")
    else
      Assert.isFalse(waitingPrompt.selectionHighlighted, "interval update " .. index .. " shows the blink phase")
    end
    Assert.equal(bag:revision(), revision, "interval update " .. index .. " mutates nothing")
  end
  Assert.equal(bag:quantity("POTION"), 5, "the whole interval changes no quantities")
  control:updateFixed({ { type = "confirm" } })
  local acknowledged = control:status()
  Assert.equal(acknowledged.state, "toss_ack", "the terminal prompt update acknowledges the choice")
  Assert.isNil(acknowledged.yesNoPrompt, "the prompt closes once YES is accepted")
  Assert.equal(bag:revision(), revision, "the terminal update mutates nothing")
  Assert.equal(bag:quantity("POTION"), 5, "the terminal update changes no quantities")
  control:updateFixed({ { type = "confirm" } })
  local committed = control:status()
  Assert.equal(committed.state, "browsing", "the first acknowledgement returns to browsing")
  Assert.equal(bag:quantity("POTION"), 4, "the acknowledgement removes the picked copies")
  Assert.equal(bag:revision(), revision + 1, "the acknowledgement mutates exactly once")
end

-- Rejecting through NO follows the same delayed interval: toggling to NO
-- then confirming latches without leaving confirmation, every later prompt
-- update stays without mutation, and only the terminal update returns to
-- browsing with the inventory untouched and the terminal input unreplayed.
function T.toss_rejection_waits_through_the_prompt_interval_before_browsing()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a tossable stack")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control, layoutManifest = controller(bag, cursor)
  local layout = BagLayout.resolve({ manifest = layoutManifest, heroVisible = true })
  local revision = bag:revision()
  tap(control, layout, 76, 56)
  tap(control, layout, 144, 144)
  Assert.equal(control:status().state, "toss_quantity", "setup enters the quantity picker")
  tap(control, layout, 80, 144)
  Assert.equal(control:status().quantity, 2, "setup picks two copies")
  tap(control, layout, 144, 176)
  Assert.equal(control:status().state, "toss_confirm", "setup reaches the modal confirmation")
  Assert.equal(control:status().quantity, 2, "the confirmation carries the picked amount")
  control:updateFixed({ navigate("down") })
  local toggled = control:status()
  Assert.equal(toggled.state, "toss_confirm", "toggling to NO stays in confirmation")
  Assert.equal(assert(toggled.yesNoPrompt, "toggling keeps the prompt").selected, "no", "down toggles YES to NO")
  Assert.equal(bag:revision(), revision, "toggling mutates nothing")
  control:updateFixed({ { type = "confirm" } })
  local latched = control:status()
  Assert.equal(latched.state, "toss_confirm", "confirming NO latches without leaving confirmation")
  Assert.equal(assert(latched.yesNoPrompt, "latching keeps the prompt").selected, "no", "latching keeps NO")
  Assert.equal(bag:revision(), revision, "latching NO mutates nothing")
  local phases = { true, true, false, false, true, true, false, false }
  for index, phase in ipairs(phases) do
    control:updateFixed({})
    local waiting = control:status()
    Assert.equal(waiting.state, "toss_confirm", "interval update " .. index .. " stays in confirmation")
    local waitingPrompt = assert(waiting.yesNoPrompt, "interval update " .. index .. " keeps its prompt")
    Assert.equal(waitingPrompt.selected, "no", "interval update " .. index .. " keeps NO")
    if phase then
      Assert.isTrue(waitingPrompt.selectionHighlighted, "interval update " .. index .. " shows the blink phase")
    else
      Assert.isFalse(waitingPrompt.selectionHighlighted, "interval update " .. index .. " shows the blink phase")
    end
    Assert.equal(bag:revision(), revision, "interval update " .. index .. " mutates nothing")
  end
  Assert.equal(bag:quantity("POTION"), 5, "the whole interval changes no quantities")
  control:updateFixed({ { type = "confirm" } })
  local rejected = control:status()
  Assert.equal(rejected.state, "browsing", "the terminal prompt update returns to browsing")
  Assert.isNil(control:takeResult(), "the terminal update closes nothing")
  Assert.equal(bag:revision(), revision, "a rejected toss mutates nothing")
  Assert.equal(bag:quantity("POTION"), 5, "a rejected toss changes no quantities")
end

-- A layout change after the modal prompt resolved its row cannot undo the
-- choice: clearing Bag capture leaves the pending confirmation running
-- until the terminal update acknowledges into the post-choice state.
function T.cancelling_capture_after_a_modal_press_keeps_the_pending_choice()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5), "setup stocks a tossable stack")
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local control, layoutManifest = controller(bag, cursor)
  local layout = BagLayout.resolve({ manifest = layoutManifest, heroVisible = true })
  local revision = bag:revision()
  tap(control, layout, 76, 56)
  tap(control, layout, 144, 144)
  control:updateFixed({ { type = "confirm" } })
  Assert.equal(control:status().state, "toss_confirm", "setup reaches the modal confirmation")
  control:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = 224, y = 64 } })
  local prompt = assert(control:status().yesNoPrompt, "the modal press keeps the prompt")
  Assert.equal(prompt.selected, "yes", "the press resolves the YES row")
  control:cancelPointerCapture()
  settlePromptChoice(control)
  local acknowledged = control:status()
  Assert.equal(acknowledged.state, "toss_ack", "the resolved choice survives capture cancellation")
  Assert.isNil(acknowledged.yesNoPrompt, "the prompt closes once YES is accepted")
  Assert.equal(bag:revision(), revision, "the cancelled capture mutates nothing")
  Assert.equal(bag:quantity("POTION"), 5, "the cancelled capture changes no quantities")
end

return { tests = T }
