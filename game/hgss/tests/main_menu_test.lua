-- Lower-layer contracts for Main Menu focus, catalog state, layout, and failures.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FakeGraphics = require("tests.support.FakeGraphics")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local MainMenuController = require("game.hgss.src.menu.MainMenuController")
local MainMenuLayout = require("game.hgss.src.menu.MainMenuLayout")
local MainMenuRenderer = require("game.hgss.src.menu.MainMenuRenderer")
local MainMenuState = require("game.hgss.src.menu.MainMenuState")

local T = {}

local function globalActions()
  return { { id = "new-game", kind = "new_game" } }
end

local function save(id, canContinue)
  return {
    id = id,
    saveId = id,
    playerName = id,
    playTimeLabel = "0:00",
    canContinue = canContinue ~= false,
    canDelete = true,
  }
end

local function saves(ids)
  local result = {}
  for _, id in ipairs(ids) do
    result[#result + 1] = save(id)
  end
  return result
end

local function fakeRenderer()
  return { draw = function() end, dispose = function() end }
end

local function state(options)
  options = options or {}
  options.saveStore = options.saveStore or {
    list = function()
      return {}
    end,
  }
  options.readyVersions = options.readyVersions or { "heartgold" }
  options.width = options.width or 640
  options.height = options.height or 480
  options.renderer = options.renderer or fakeRenderer()
  return MainMenuState.new(options)
end

-- Pointer input arrives in host units while layout geometry is logical:
-- forward layout points through the published placement like production.
-- A press pairs down with its release so session capture never leaks
-- across clicks the way production event pairs do not.
local function pressAt(menu, logicalX, logicalY)
  local published = menu:view()
  local placement = assert(published.presentation.panes[1].placement, "pointer input needs the published placement")
  local hostX, hostY = LayoutGeometry.logicalToHost(placement, logicalX, logicalY)
  menu:mousepressed(hostX, hostY, 1)
  menu:mousereleased(hostX, hostY, 1)
end

function T.controller_defaults_to_existing_save_and_reaches_global_action()
  local controller = MainMenuController.new(globalActions(), saves({ "one", "two" }))
  Assert.deepEqual(controller:snapshot().focus, { region = "saves", saveId = "one", lane = "body" })
  controller:move("right")
  Assert.deepEqual(controller:snapshot().focus, { region = "saves", saveId = "one", lane = "overflow" })
  Assert.isNil(controller:snapshot().popup)
  controller:move("left")
  Assert.deepEqual(controller:snapshot().focus, { region = "saves", saveId = "one", lane = "body" })
  controller:move("left")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "left from a save body must reach New Game directly"
  )
  controller:move("right")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "one", lane = "body" },
    "right from New Game must return to the remembered save"
  )
  controller:move("down")
  Assert.deepEqual(controller:snapshot().focus, { region = "saves", saveId = "two", lane = "body" })
  controller:move("down")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "down from the final save must reach the global action"
  )
  controller:move("left")
  Assert.deepEqual(controller:snapshot().focus, { region = "global", actionId = "new-game" })
  controller:move("up")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "two", lane = "body" },
    "up from New Game must wrap to the last save body"
  )
end

function T.controller_back_closes_confirmation_then_popup_without_quitting()
  local controller = MainMenuController.new(globalActions(), saves({ "one" }))
  controller:focusSave("one", "overflow")
  Assert.isTrue(controller:activate() == nil)
  Assert.isTrue(controller:activate() == nil)
  Assert.isTrue(controller:back())
  Assert.isNil(controller:snapshot().confirmation)
  Assert.notNil(controller:snapshot().popup)
  Assert.isTrue(controller:back())
  Assert.isNil(controller:snapshot().popup)
  Assert.isFalse(controller:back())
end

function T.controller_navigation_is_explicit_and_modal_state_captures_input()
  local controller = MainMenuController.new(globalActions(), saves({ "one", "two" }))
  controller:move("down")
  Assert.deepEqual(controller:snapshot().focus, { region = "saves", saveId = "two", lane = "body" })
  controller:move("right")
  Assert.isTrue(controller:activate() == nil)
  Assert.deepEqual(controller:snapshot().popup, { saveId = "two", focusedAction = "delete" })
  controller:move("down")
  Assert.isTrue(controller:activate() == nil)
  Assert.deepEqual(controller:snapshot().confirmation, { saveId = "two", focusedAction = "cancel" })
  controller:move("right")
  Assert.deepEqual(controller:snapshot().confirmation, { saveId = "two", focusedAction = "delete" })
  Assert.deepEqual(controller:activate(), { kind = "delete", saveId = "two" })
  Assert.isNil(controller:snapshot().popup)
  Assert.isNil(controller:snapshot().confirmation)
end

function T.controller_preserves_semantic_focus_and_selects_a_neighbor_after_removal()
  local controller = MainMenuController.new(globalActions(), saves({ "one", "two", "three" }))
  controller:focusSave("two", "overflow")
  controller:setCatalog(globalActions(), saves({ "one", "three" }))
  Assert.deepEqual(controller:snapshot().focus, { region = "saves", saveId = "three", lane = "overflow" })
  Assert.isNil(controller:snapshot().popup)
  controller:focusSave("one", "body")
  controller:setCatalog(globalActions(), {})
  Assert.deepEqual(controller:snapshot().focus, { region = "global", actionId = "new-game" })
end

function T.controller_catalog_replacement_clamps_overflow_focus_to_body_without_delete()
  local controller = MainMenuController.new(globalActions(), saves({ "one", "two", "three" }))
  controller:focusSave("two", "overflow")
  local replacements = saves({ "one", "three" })
  replacements[2].canDelete = false
  controller:setCatalog(globalActions(), replacements)
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "three", lane = "body" },
    "replacing an overflow-focused save with one without overflow must resolve to its body"
  )
  local layout =
    MainMenuLayout.compute(globalActions(), replacements, controller:snapshot().focus, 320, 180, 0, nil, nil, false)
  local card = assert(layout.saves.cards["three"], "the focused save needs card geometry")
  Assert.isTrue(
    card.body.y >= layout.saves.viewport.y
      and card.body.y + card.body.height <= layout.saves.viewport.y + layout.saves.viewport.height,
    "the clamped body focus must stay visible"
  )
  local refreshed = MainMenuController.new(globalActions(), saves({ "one" }))
  refreshed:focusSave("one", "overflow")
  local locked = saves({ "one" })
  locked[1].canDelete = false
  refreshed:setCatalog(globalActions(), locked)
  Assert.deepEqual(
    refreshed:snapshot().focus,
    { region = "saves", saveId = "one", lane = "body" },
    "a catalog refresh that revokes delete must resolve overflow focus to the body"
  )
end

function T.controller_keeps_overflow_at_the_list_edges()
  local controller = MainMenuController.new(globalActions(), saves({ "one", "two" }))
  controller:focusSave("one", "overflow")
  controller:move("up")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "up from the first save overflow must reach the global action"
  )
  controller:focusSave("two", "overflow")
  controller:move("down")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "down from the last save overflow must reach the global action"
  )
end

function T.layout_separates_global_and_scrollable_save_regions()
  local list = saves({ "one", "two", "three", "four", "five" })
  local layout = MainMenuLayout.compute(
    globalActions(),
    list,
    { region = "saves", saveId = "five", lane = "overflow" },
    320,
    180,
    0,
    nil,
    nil,
    false
  )
  Assert.notNil(layout.global.actions["new-game"])
  Assert.notNil(layout.saves.viewport)
  Assert.isTrue(layout.saves.offset > 0)
  local newGame = layout.global.actions["new-game"]
  Assert.isTrue(
    newGame.y >= layout.saves.viewport.y + layout.saves.viewport.height,
    "New Game must sit below the scrollable save viewport"
  )
  local rescrolled = MainMenuLayout.compute(
    globalActions(),
    list,
    { region = "global", actionId = "new-game" },
    320,
    180,
    layout.saves.offset,
    nil,
    nil,
    false
  )
  Assert.equal(rescrolled.global.actions["new-game"].y, newGame.y)
  Assert.equal(rescrolled.saves.offset, layout.saves.offset)
end

function T.layout_focuses_popup_inside_the_viewport_and_keeps_hit_regions_disjoint()
  local layout = MainMenuLayout.compute(
    globalActions(),
    { save("one") },
    { region = "saves", saveId = "one", lane = "overflow" },
    240,
    160,
    0,
    { saveId = "one", focusedAction = "delete" },
    nil,
    false
  )
  local card = assert(layout.saves.cards.one)
  Assert.isFalse(MainMenuLayout.contains(card.body, card.overflow.x + 1, card.overflow.y + 1))
  Assert.isTrue(layout.popup.box.x >= 0 and layout.popup.box.y >= 0)
  Assert.isTrue(layout.popup.box.x + layout.popup.box.width <= 240)
  Assert.isTrue(layout.popup.box.y + layout.popup.box.height <= 160)
end

function T.pointer_overflow_focuses_the_lane_without_continuing()
  local results = {}
  local menu = state({
    saveStore = {
      list = function()
        return {
          {
            saveId = "save-00000001",
            versionId = "heartgold",
            playerData = { profile = { name = "PLAYER" } },
            playTimeSeconds = 0,
          },
        }
      end,
      load = function()
        error("overflow must not load a save")
      end,
    },
    onResult = function(result)
      results[#results + 1] = result
    end,
  })
  local published = menu:view()
  local card = assert(published.layout.saves.cards["save-00000001"])
  -- Query before pressing: once the overflow popup opens, the shared hit
  -- test truthfully reports the modal, so the underlying save hit must
  -- be established first.
  local placement = assert(published.presentation.panes[1].placement, "the menu plan carries its placement")
  local hostX, hostY = LayoutGeometry.logicalToHost(placement, card.overflow.x + 1, card.overflow.y + 1)
  Assert.deepEqual(menu:hitTest(hostX, hostY), {
    region = "saves",
    saveId = "save-00000001",
    lane = "overflow",
  })
  pressAt(menu, card.overflow.x + 1, card.overflow.y + 1)
  Assert.deepEqual(results, {})
  Assert.deepEqual(menu:view().focus, { region = "saves", saveId = "save-00000001", lane = "overflow" })
end

function T.clipped_save_cards_cannot_be_pointer_activated()
  local entries = {}
  for index = 1, 5 do
    entries[#entries + 1] = {
      saveId = string.format("save-%08d", index),
      versionId = "heartgold",
      playerData = { profile = { name = "PLAYER" } },
      playTimeSeconds = 0,
    }
  end
  local results = {}
  local menu = state({
    saveStore = {
      list = function()
        return entries
      end,
      load = function(_, saveId)
        return entries[tonumber(saveId:sub(-1))]
      end,
    },
    width = 320,
    height = 180,
    onResult = function(result)
      results[#results + 1] = result
    end,
  })
  menu:keypressed("down")
  menu:keypressed("down")
  menu:keypressed("down")
  menu:keypressed("down")
  local layout = menu:view().layout
  local clipped = assert(layout.saves.cards["save-00000001"])
  Assert.isTrue(clipped.body.y < layout.saves.viewport.y)
  menu:mousepressed(clipped.body.x + 1, clipped.body.y + 1, 1)
  Assert.deepEqual(results, {})
  Assert.isNil(menu:hitTest(clipped.body.x + 1, clipped.body.y + 1).saveId)
end

function T.state_publishes_separate_catalogs_and_preserves_initial_save_focus()
  local menu = state({
    saveStore = {
      list = function()
        return {
          {
            saveId = "save-00000001",
            versionId = "heartgold",
            playerData = { profile = { name = "PLAYER" } },
            playTimeSeconds = 60,
          },
        }
      end,
    },
  })
  local view = menu:view()
  Assert.equal(view.focusedId, "save-00000001")
  Assert.equal(#view.globalActions, 1)
  Assert.equal(#view.saves, 1)
  Assert.isNil(view.items)
end

function T.state_translates_catalog_and_load_failures_to_recoverable_state()
  local catalogFailure = Errors.new("GAME_SAVE_CATALOG_INVALID", "catalog unreadable")
  local menu = state({ saveStore = {
    list = function()
      error(catalogFailure)
    end,
  } })
  Assert.equal(menu:view().catalogError, "catalog unreadable")
  Assert.equal(menu:view().focusedId, "new-game")

  local loadFailure = Errors.new("GAME_SAVE_LOAD_FAILED", "save could not be loaded")
  local loadMenu = state({
    saveStore = {
      list = function()
        return {
          {
            saveId = "save-00000001",
            versionId = "heartgold",
            playerData = { profile = { name = "PLAYER" } },
            playTimeSeconds = 0,
          },
        }
      end,
      load = function()
        error(loadFailure)
      end,
    },
  })
  loadMenu:keypressed("return")
  local failed = loadMenu:view()
  Assert.equal(failed.saves[1].errorSummary, "save could not be loaded")
  Assert.isFalse(failed.saves[1].canContinue)
end

function T.state_deletes_unavailable_save_only_after_confirmation()
  local entries = {
    { saveId = "save-00000001", playerData = {}, versionId = "heartgold", playTimeSeconds = 0 },
  }
  local deleted = 0
  local menu = state({
    saveStore = {
      list = function()
        return entries
      end,
      delete = function(_, saveId)
        Assert.equal(saveId, "save-00000001")
        deleted = deleted + 1
        entries = {}
        return true
      end,
    },
  })
  menu:keypressed("right")
  menu:keypressed("return")
  Assert.equal(deleted, 0)
  menu:keypressed("return")
  Assert.equal(deleted, 0)
  menu:keypressed("right")
  menu:keypressed("return")
  Assert.equal(deleted, 1)
  Assert.equal(menu:view().focusedId, "new-game")
end

function T.state_keeps_delete_failure_visible_and_save_available_for_retry()
  local failure = Errors.new("GAME_SAVE_DELETE_FAILED", "save could not be deleted")
  local entries = {
    { saveId = "save-00000001", playerData = {}, versionId = "heartgold", playTimeSeconds = 0 },
  }
  local menu = state({
    saveStore = {
      list = function()
        return entries
      end,
      delete = function()
        error(failure)
      end,
    },
  })
  menu:keypressed("tab")
  menu:keypressed("return")
  menu:keypressed("right")
  menu:keypressed("return")
  local view = menu:view()
  Assert.equal(view.catalogError, "save could not be deleted")
  Assert.equal(view.focusedId, "save-00000001")
  Assert.notNil(view.layout.saves.cards["save-00000001"])
end

-- The shared keyboard aliases drive Main Menu actions: confirm activates the
-- focused entry, cancel backs out toward quit, and the menu alias requests
-- save deletion where the controller permits it. Removed aliases stay inert.
function T.shared_aliases_activate_back_out_and_request_delete()
  local results = {}
  local menu = state({
    saveStore = {
      list = function()
        return { { saveId = "one", playerData = {}, versionId = "heartgold", playTimeSeconds = 0 } }
      end,
    },
    onResult = function(result)
      results[#results + 1] = result
    end,
  })
  Assert.equal(menu.controller:snapshot().focus.saveId, "one")
  menu:keypressed("tab")
  Assert.deepEqual(
    menu.controller:snapshot().popup,
    { saveId = "one", focusedAction = "delete" },
    "the menu alias requests deletion for the focused save"
  )
  menu:keypressed("delete")
  Assert.isNil(menu.controller:snapshot().popup, "the delete key backs out as cancel")
  Assert.deepEqual(results, {})
  menu:keypressed("tab")
  Assert.notNil(menu.controller:snapshot().popup)
  menu:keypressed("escape")
  Assert.isNil(menu.controller:snapshot().popup, "escape backs out as cancel")
  Assert.deepEqual(results, {})
  local pressedBefore = #results
  for _, key in ipairs({ "z", "x", "m" }) do
    menu:keypressed(key)
  end
  Assert.isNil(menu.controller:snapshot().popup, "removed aliases never request deletion")
  Assert.equal(#results, pressedBefore, "removed aliases emit no menu result")
  menu:keypressed("backspace")
  Assert.deepEqual(results, { { kind = "quit" } }, "cancel with nothing to close quits")
end

function T.overflow_vertical_movement_falls_back_to_body_without_overflow_control()
  local list = saves({ "one", "two", "three" })
  list[2].canDelete = false
  local controller = MainMenuController.new(globalActions(), list)
  controller:focusSave("one", "overflow")
  controller:move("down")
  Assert.deepEqual(controller:snapshot().focus, { region = "saves", saveId = "two", lane = "body" })
  controller:focusSave("three", "overflow")
  controller:move("up")
  Assert.deepEqual(controller:snapshot().focus, { region = "saves", saveId = "two", lane = "body" })
  controller:focusSave("three", "body")
  controller:move("left")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "left from a save body must reach New Game"
  )
  controller:move("right")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "three", lane = "body" },
    "right from New Game must return to the remembered save"
  )
end

function T.deep_saves_scroll_while_new_game_stays_fixed_and_direct()
  local ids = {}
  for index = 1, 12 do
    ids[#ids + 1] = string.format("save-%02d", index)
  end
  local list = saves(ids)
  local controller = MainMenuController.new(globalActions(), list)
  controller:focusSave("save-12", "body")
  local layout =
    MainMenuLayout.compute(globalActions(), list, controller:snapshot().focus, 640, 480, 0, nil, nil, false)
  local newGame = layout.global.actions["new-game"]
  Assert.isTrue(newGame.y >= layout.saves.viewport.y + layout.saves.viewport.height)
  Assert.notNil(layout.saves.scrollIndicators)
  Assert.notNil(layout.saves.scrollIndicators.up)
  Assert.isNil(layout.saves.scrollIndicators.down)
  local card = assert(layout.saves.cards["save-12"])
  Assert.isTrue(card.frame.y + card.frame.height <= layout.saves.viewport.y + layout.saves.viewport.height)
  controller:move("left")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "left from the final save body must reach New Game"
  )
  controller:move("right")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "save-12", lane = "body" },
    "right from New Game must return to the remembered save body"
  )
  controller:move("down")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "down from the final save must reach the global action"
  )
  local relaid = MainMenuLayout.compute(
    globalActions(),
    list,
    controller:snapshot().focus,
    640,
    480,
    layout.saves.offset,
    nil,
    nil,
    false
  )
  Assert.equal(relaid.global.actions["new-game"].y, newGame.y)
  Assert.notNil(relaid.saves.scrollIndicators.up)
end

function T.pointer_confirmation_click_activates_the_clicked_action()
  local entries = {
    {
      saveId = "save-00000001",
      versionId = "heartgold",
      playerData = { profile = { name = "PLAYER" } },
      playTimeSeconds = 0,
    },
  }
  local deleted = 0
  local menu = state({
    saveStore = {
      list = function()
        return entries
      end,
      delete = function(_, saveId)
        Assert.equal(saveId, "save-00000001")
        deleted = deleted + 1
        entries = {}
        return true
      end,
    },
  })
  menu:keypressed("right")
  menu:keypressed("return")
  menu:keypressed("return")
  menu:keypressed("right")
  Assert.equal(menu.controller.confirmation.focusedAction, "delete")
  local confirmation = assert(menu:layout().confirmation)
  pressAt(
    menu,
    confirmation.delete.x + confirmation.delete.width / 2,
    confirmation.delete.y + confirmation.delete.height / 2
  )
  Assert.equal(deleted, 1)
  Assert.isNil(menu.controller.confirmation)
  Assert.isNil(menu.controller.popup)

  entries = {
    {
      saveId = "save-00000001",
      versionId = "heartgold",
      playerData = { profile = { name = "PLAYER" } },
      playTimeSeconds = 0,
    },
  }
  local cancelMenu = state({
    saveStore = {
      list = function()
        return entries
      end,
      delete = function()
        error("cancel click must not delete")
      end,
    },
  })
  cancelMenu:keypressed("right")
  cancelMenu:keypressed("return")
  cancelMenu:keypressed("return")
  cancelMenu:keypressed("right")
  Assert.equal(cancelMenu.controller.confirmation.focusedAction, "delete")
  local cancelBox = assert(cancelMenu:layout().confirmation)
  pressAt(cancelMenu, cancelBox.cancel.x + cancelBox.cancel.width / 2, cancelBox.cancel.y + cancelBox.cancel.height / 2)
  Assert.isNil(cancelMenu.controller.confirmation)
  Assert.notNil(cancelMenu.controller.popup)
end

function T.vertical_moves_wrap_between_new_game_and_edge_saves()
  local controller = MainMenuController.new(globalActions(), saves({ "one", "two", "three" }))
  controller:focusSave("two", "body")
  controller:move("down")
  Assert.deepEqual(controller:snapshot().focus, { region = "saves", saveId = "three", lane = "body" })
  controller:move("down")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "down from the final save body must reach the global action"
  )
  controller:focusGlobal("new-game")
  controller:move("down")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "one", lane = "body" },
    "down from New Game must wrap to the first save body"
  )
  controller:move("up")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "up from the first save must return to New Game"
  )
  controller:move("up")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "three", lane = "body" },
    "up from New Game must wrap to the last save body"
  )
  controller:move("down")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "down from the last save must return to New Game"
  )
  controller:focusSave("two", "body")
  controller:move("up")
  Assert.deepEqual(controller:snapshot().focus, { region = "saves", saveId = "one", lane = "body" })
  controller:focusSave("one", "body")
  controller:move("up")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "up from the first save must reach the global action"
  )
end

function T.horizontal_moves_cross_between_new_game_and_saves_through_the_remembered_save()
  local controller = MainMenuController.new(globalActions(), saves({ "one", "two" }))
  controller:focusSave("two", "body")
  controller:move("left")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "left from a save body must reach New Game"
  )
  controller:move("right")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "two", lane = "body" },
    "right from New Game must return to the remembered save"
  )
  controller:focusSave("one", "body")
  controller:move("right")
  Assert.deepEqual(controller:snapshot().focus, { region = "saves", saveId = "one", lane = "overflow" })
  controller:move("right")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "one", lane = "overflow" },
    "right from overflow must not cross regions"
  )
  controller:move("left")
  Assert.deepEqual(controller:snapshot().focus, { region = "saves", saveId = "one", lane = "body" })
  controller:move("left")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "left from a save body must reach New Game"
  )
  controller:move("left")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "left from New Game must stay"
  )
end

function T.overflow_lane_vertical_move_falls_back_to_body_without_overflow()
  local entries = {
    save("one"),
    { id = "two", saveId = "two", playerName = "two", playTimeLabel = "0:00", canContinue = true, canDelete = false },
  }
  local controller = MainMenuController.new(globalActions(), entries)
  controller:focusSave("one", "overflow")
  controller:move("down")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "two", lane = "body" },
    "moving down the overflow lane onto a save without overflow must resolve to its body"
  )
end

function T.confirmation_supports_direct_semantic_selection()
  local controller = MainMenuController.new(globalActions(), saves({ "one" }))
  Assert.isTrue(
    type(controller.focusConfirmation) == "function",
    "confirmation needs a direct semantic selection operation instead of simulated movement"
  )
  controller:focusSave("one", "overflow")
  controller:activate()
  controller:activate()
  Assert.equal(controller:snapshot().confirmation.focusedAction, "cancel")
  controller:focusConfirmation("delete")
  Assert.equal(controller:snapshot().confirmation.focusedAction, "delete")
  Assert.deepEqual(controller:snapshot().popup, { saveId = "one", focusedAction = "delete" })
  controller:focusConfirmation("cancel")
  Assert.equal(controller:snapshot().confirmation.focusedAction, "cancel")
  Assert.throws(function()
    controller:focusConfirmation("remove")
  end, "unknown confirmation actions must fail loudly")
end

local function catalogEntry(saveId, name, playTimeSeconds)
  return {
    saveId = saveId,
    versionId = "heartgold",
    playerData = { profile = { name = name } },
    playTimeSeconds = playTimeSeconds,
  }
end

function T.pointer_click_on_focused_delete_action_confirms_deletion()
  local entries = { catalogEntry("save-00000001", "PLAYER", 60) }
  local deleted = 0
  local results = {}
  local menu = state({
    saveStore = {
      list = function()
        return entries
      end,
      delete = function(_, saveId)
        Assert.equal(saveId, "save-00000001")
        deleted = deleted + 1
        entries = {}
        return true
      end,
    },
    onResult = function(result)
      results[#results + 1] = result
    end,
  })
  menu:keypressed("right")
  menu:keypressed("return")
  menu:keypressed("return")
  Assert.equal(menu:view().confirmation.focusedAction, "cancel")
  menu:keypressed("right")
  Assert.equal(menu:view().confirmation.focusedAction, "delete")
  local confirmation = assert(menu:view().layout.confirmation, "confirmation needs hit geometry")
  local deleteRect = confirmation.delete
  pressAt(menu, deleteRect.x + deleteRect.width / 2, deleteRect.y + deleteRect.height / 2)
  Assert.equal(deleted, 1, "clicking the focused Delete action must delete without toggling selection")
  Assert.deepEqual(results, {}, "deletion must not publish Continue")
  Assert.isNil(menu:view().layout.saves.cards["save-00000001"])
  Assert.equal(menu:view().focusedId, "new-game")
end

function T.single_save_places_tall_continue_above_a_short_fixed_new_game()
  local layout = MainMenuLayout.compute(
    globalActions(),
    saves({ "one" }),
    { region = "saves", saveId = "one", lane = "body" },
    640,
    480,
    0,
    nil,
    nil,
    false
  )
  local card = assert(layout.saves.cards.one, "the single save needs card geometry")
  local newGame = assert(layout.global.actions["new-game"], "New Game needs global geometry")
  Assert.isTrue(
    card.frame.y + card.frame.height <= newGame.y,
    "the Continue card must sit above New Game, not below it"
  )
  Assert.isTrue(card.frame.height > newGame.height, "the Continue card must be taller than New Game")
  Assert.isTrue(
    layout.saves.viewport.y + layout.saves.viewport.height <= newGame.y,
    "New Game must sit below the save region instead of sharing its top edge"
  )
end

function T.scroll_state_pins_new_game_and_reports_edge_availability()
  local ids = {}
  for index = 1, 8 do
    ids[#ids + 1] = string.format("save-%d", index)
  end
  local top = MainMenuLayout.compute(
    globalActions(),
    saves(ids),
    { region = "saves", saveId = "save-1", lane = "body" },
    320,
    180,
    0,
    nil,
    nil,
    false
  )
  Assert.equal(top.saves.offset, 0)
  Assert.isNil(top.saves.canScrollUp, "edge availability has a single shape")
  Assert.isNil(top.saves.canScrollDown, "edge availability has a single shape")
  Assert.isNil(top.saves.scrollIndicators.up, "nothing above the top viewport edge needs an indicator")
  Assert.notNil(top.saves.scrollIndicators.down, "content below the top viewport edge needs an indicator")
  local bottom = MainMenuLayout.compute(
    globalActions(),
    saves(ids),
    { region = "saves", saveId = "save-8", lane = "body" },
    320,
    180,
    top.saves.offset,
    nil,
    nil,
    false
  )
  Assert.isTrue(bottom.saves.offset > 0, "many saves must scroll their save viewport")
  local focusedCard = assert(bottom.saves.cards["save-8"], "the focused save needs card geometry")
  Assert.isTrue(
    focusedCard.body.y >= bottom.saves.viewport.y
      and focusedCard.body.y + focusedCard.body.height <= bottom.saves.viewport.y + bottom.saves.viewport.height,
    "scrolling must keep the focused save card visible"
  )
  Assert.equal(bottom.saves.canScrollUp, nil, "edge availability has a single shape")
  Assert.equal(bottom.saves.canScrollDown, nil, "edge availability has a single shape")
  Assert.notNil(bottom.saves.scrollIndicators.up, "content above the bottom viewport edge needs an indicator")
  Assert.isNil(bottom.saves.scrollIndicators.down, "nothing below the bottom viewport edge needs an indicator")
  local topNewGame = assert(top.global.actions["new-game"])
  local bottomNewGame = assert(bottom.global.actions["new-game"])
  Assert.equal(bottomNewGame.x, topNewGame.x)
  Assert.equal(bottomNewGame.y, topNewGame.y)
  local visible = MainMenuLayout.compute(
    globalActions(),
    saves({ "one" }),
    { region = "saves", saveId = "one", lane = "body" },
    640,
    480,
    0,
    nil,
    nil,
    false
  )
  Assert.isNil(visible.saves.scrollIndicators.up)
  Assert.isNil(visible.saves.scrollIndicators.down)
end

local SELECTED_RIM = { 1, 58 / 255, 58 / 255 }
local NEUTRAL_RIM = { 48 / 255, 73 / 255, 97 / 255 }
local CARD_FACE = { 0xFB / 255, 0xFB / 255, 0xFB / 255 }

local function nearColor(recorded, expected)
  for index = 1, 3 do
    if math.abs(recorded[index] - expected[index]) > 0.02 then
      return false
    end
  end
  return true
end

local function recordedRectangles(graphics)
  return graphics.rectangles
end

local function hasRimColor(rectangles, expected)
  for _, record in ipairs(rectangles) do
    if nearColor(record.color, expected) then
      return true
    end
  end
  return false
end

local function overlaps(record, rect)
  return record.x < rect.x + rect.width
    and rect.x < record.x + record.w
    and record.y < rect.y + rect.height
    and rect.y < record.y + record.h
end

local function hasRimColorOverlapping(rectangles, expected, rect)
  for _, record in ipairs(rectangles) do
    if nearColor(record.color, expected) and overlaps(record, rect) then
      return true
    end
  end
  return false
end

-- The selected parent card underpaints the nested overflow region by design;
-- the unfocused overflow inset is face-colored so only its "..." copy shows,
-- and that face paint is drawn after the parent chrome and covers the
-- region. Assert paint order instead of paint-list region purity: the
-- topmost record over the inset must be the card face, whatever the parent
-- selection painted beneath it.
local function overflowInsetCoversParentSelection(rectangles, rect)
  local last = nil
  for _, record in ipairs(rectangles) do
    if overlaps(record, rect) then
      last = record
    end
  end
  return last ~= nil and nearColor(last.color, CARD_FACE)
end

-- Deterministic source advance shared by every headless text double, matching
-- the production textWidth boundary the renderer right-aligns against.
local GLYPH_ADVANCE = 7

local function recordingText(calls)
  return {
    textWidth = function(_, value)
      return #value * GLYPH_ADVANCE
    end,
    drawText = function(_, text, x, y)
      calls[#calls + 1] = { text = text, x = x, y = y }
    end,
    drawTextWithPalette = function(_, text, x, y, palette)
      -- Launcher copy draws at logical coordinates under one root
      -- placement: record the logical point as passed.
      calls[#calls + 1] = { text = text, x = x, y = y, palette = palette }
    end,
  }
end

local CARD_TONE = { r = 123, g = 45, b = 67 }

local function menuRenderer(text, graphics)
  return MainMenuRenderer.new({ text = text, graphics = graphics, versionId = "heartgold" })
end

local function drawnMenu(entries, width, height, setup)
  local graphics = FakeGraphics.new()
  local calls = {}
  local renderer = menuRenderer(recordingText(calls), graphics)
  local menu = state({
    saveStore = {
      list = function()
        return entries
      end,
    },
    width = width,
    height = height,
    renderer = { draw = function() end, dispose = function() end },
  })
  if setup then
    setup(menu)
  end
  local current = menu:view()
  renderer:draw(current, current.presentation)
  return { graphics = graphics, calls = calls, view = current, menu = menu }
end

function T.focused_continue_uses_selected_rim_while_other_cards_stay_neutral()
  local drawn =
    drawnMenu({ catalogEntry("save-00000001", "PLAYER", 60), catalogEntry("save-00000002", "OTHER", 120) }, 640, 480)
  local rectangles = recordedRectangles(drawn.graphics)
  Assert.isTrue(hasRimColor(rectangles, SELECTED_RIM), "the focused Continue card must use the selected rim color")
  Assert.isTrue(hasRimColor(rectangles, NEUTRAL_RIM), "unfocused cards must keep the neutral rim color")
  local focusedCard = assert(drawn.view.layout.saves.cards["save-00000001"])
  Assert.isTrue(
    overflowInsetCoversParentSelection(rectangles, assert(focusedCard.overflow)),
    "the unfocused overflow control must disappear into the card face, covering the parent selection"
  )
end

function T.overflow_focus_marks_only_the_overflow_control()
  local drawn = drawnMenu({ catalogEntry("save-00000001", "PLAYER", 60) }, 640, 480, function(menu)
    menu:keypressed("right")
  end)
  Assert.deepEqual(drawn.view.focus, { region = "saves", saveId = "save-00000001", lane = "overflow" })
  local rectangles = recordedRectangles(drawn.graphics)
  local card = assert(drawn.view.layout.saves.cards["save-00000001"])
  Assert.isTrue(
    hasRimColorOverlapping(rectangles, SELECTED_RIM, assert(card.overflow)),
    "the overflow control needs its own unmistakable selected rim"
  )
  Assert.isFalse(
    hasRimColorOverlapping(rectangles, SELECTED_RIM, card.body),
    "overflow focus must return the Continue body to its neutral rim"
  )
end

function T.new_game_focus_uses_the_selected_rim_grammar()
  local drawn = drawnMenu({}, 640, 480)
  Assert.deepEqual(drawn.view.focus, { region = "global", actionId = "new-game" })
  local rectangles = recordedRectangles(drawn.graphics)
  local newGame = assert(drawn.view.layout.global.actions["new-game"])
  Assert.isTrue(
    hasRimColorOverlapping(rectangles, SELECTED_RIM, newGame),
    "the focused New Game panel must use the selected rim color"
  )
end

function T.confirmation_focus_marks_only_the_active_action()
  local drawn = drawnMenu({ catalogEntry("save-00000001", "PLAYER", 60) }, 640, 480, function(menu)
    menu:keypressed("right")
    menu:keypressed("return")
    menu:keypressed("return")
    menu:keypressed("right")
  end)
  Assert.equal(drawn.view.confirmation.focusedAction, "delete")
  local rectangles = recordedRectangles(drawn.graphics)
  local confirmation = assert(drawn.view.layout.confirmation, "confirmation needs hit geometry")
  Assert.isTrue(
    hasRimColorOverlapping(rectangles, SELECTED_RIM, confirmation.delete),
    "the focused confirmation action must use the selected rim color"
  )
  Assert.isFalse(
    hasRimColorOverlapping(rectangles, SELECTED_RIM, confirmation.cancel),
    "the unfocused confirmation action must not look selected"
  )
end

function T.principal_copy_tracks_the_menu_scale_and_restores_transforms()
  local drawn = drawnMenu({ catalogEntry("save-00000001", "PLAYER", 60) }, 640, 480)
  local placement = assert(drawn.view.presentation.panes[1].placement, "the menu plan carries its placement")
  local menuScale = assert(placement.pixelScale, "the menu placement carries its integer scale")
  local foundMenuScale = false
  for _, transform in ipairs(drawn.graphics.transforms) do
    if transform[1] == "scale" then
      Assert.isTrue(
        transform[2] == math.floor(transform[2]) and transform[3] == math.floor(transform[3]),
        "menu text scaling must never be fractional"
      )
      Assert.equal(transform[2], menuScale, "menu text must track the menu scale")
      Assert.equal(transform[3], menuScale, "menu text must track the menu scale")
      foundMenuScale = true
    end
  end
  Assert.isTrue(foundMenuScale, "principal menu copy must render through the scaled font path")
  Assert.equal(drawn.graphics.pushDepth(), 0, "text scaling must restore graphics transforms after each draw")
  Assert.isTrue(#drawn.calls > 0, "the menu must draw principal copy")
end

function T.continue_card_announces_heading_facts_and_hides_brand_text()
  local drawn = drawnMenu({ catalogEntry("save-00000001", "PLAYER", 60) }, 640, 480)
  local seenHeading, seenName, seenPlayTime, seenBrand = false, false, false, false
  local expectedPlayTime = assert(drawn.view.saves[1].playTimeLabel)
  for _, call in ipairs(drawn.calls) do
    if call.text == "CONTINUE" then
      seenHeading = true
    end
    if call.text == "PLAYER" then
      seenName = true
    end
    if call.text == expectedPlayTime then
      seenPlayTime = true
    end
    if call.text == "portemon" then
      seenBrand = true
    end
  end
  Assert.isTrue(seenHeading, "the Continue card must announce its CONTINUE heading")
  Assert.isTrue(seenName, "the Continue card must show the player name")
  Assert.isTrue(seenPlayTime, "the Continue card must show the play time")
  Assert.isFalse(seenBrand, "the save screen must not displace its hierarchy with brand text")
end

local function rectListSnapshot(rectangles)
  local snapshot = {}
  for _, record in ipairs(rectangles) do
    snapshot[#snapshot + 1] = string.format(
      "%s|%s|%s|%s|%s|%s|%s|%s|%s",
      record.mode,
      record.x,
      record.y,
      record.w,
      record.h,
      record.color[1],
      record.color[2],
      record.color[3],
      record.color[4]
    )
  end
  return snapshot
end

function T.scroll_indicators_track_viewport_edge_availability()
  local entries = {}
  for index = 1, 8 do
    entries[#entries + 1] = catalogEntry(string.format("save-%08d", index), "PLAYER", 60)
  end
  local scrolled = drawnMenu(entries, 320, 180, function(menu)
    for _ = 1, 7 do
      menu:keypressed("down")
    end
  end)
  Assert.isTrue(scrolled.view.layout.saves.offset > 0, "the scroll setup must overflow the save viewport")
  local viewport = scrolled.view.layout.saves.viewport
  local marks = assert(scrolled.view.layout.saves.scrollIndicators)
  Assert.notNil(marks.up, "content above the viewport needs an indicator")
  local function drawWithMarks(up, down)
    local graphics = FakeGraphics.new()
    local renderer = menuRenderer(recordingText({}), graphics)
    local shaped = scrolled.view
    shaped.layout.saves.scrollIndicators = { up = up, down = down }
    renderer:draw(shaped, shaped.presentation)
    return recordedRectangles(graphics)
  end
  local indicated = rectListSnapshot(drawWithMarks(marks.up, marks.down))
  local suppressed = rectListSnapshot(drawWithMarks(nil, nil))
  local differs = #indicated ~= #suppressed
  if not differs then
    for index, signature in ipairs(indicated) do
      if suppressed[index] ~= signature then
        differs = true
        break
      end
    end
  end
  Assert.isTrue(differs, "scroll indicators must respond to edge availability")
  local edgeBand = { x = viewport.x + viewport.width - 32, y = viewport.y, width = 32, height = viewport.height }
  local cards = scrolled.view.layout.saves.cards
  local marked = drawWithMarks(marks.up, marks.down)
  local foundEdgeMark = false
  for _, record in ipairs(marked) do
    if overlaps(record, edgeBand) then
      local insideCard = false
      for _, card in pairs(cards) do
        if overlaps(record, card.frame) then
          insideCard = true
          break
        end
      end
      if not insideCard then
        foundEdgeMark = true
        break
      end
    end
  end
  Assert.isTrue(foundEdgeMark, "the scroll mark must sit near the save viewport right edge")
end

function T.layout_reports_full_scroll_availability()
  local one = saves({ "one" })
  local body = { region = "saves", saveId = "one", lane = "body" }
  local fitted = MainMenuLayout.compute(globalActions(), one, body, 640, 480, 0, nil, nil, false)
  Assert.isNil(fitted.saves.canScrollUp, "edge availability has a single shape")
  Assert.isNil(fitted.saves.canScrollDown, "edge availability has a single shape")
  Assert.isNil(fitted.saves.scrollIndicators.up)
  Assert.isNil(fitted.saves.scrollIndicators.down)

  local ids = {}
  for index = 1, 12 do
    ids[#ids + 1] = string.format("mid-%02d", index)
  end
  local many = saves(ids)
  local middle = MainMenuLayout.compute(
    globalActions(),
    many,
    { region = "saves", saveId = "mid-06", lane = "body" },
    640,
    480,
    500,
    nil,
    nil,
    false
  )
  Assert.isTrue(middle.saves.offset > 0, "a middle save must scroll content above the viewport")
  Assert.isNil(middle.saves.canScrollUp, "edge availability has a single shape")
  Assert.isNil(middle.saves.canScrollDown, "edge availability has a single shape")
  local up = assert(middle.saves.scrollIndicators.up, "content above needs an indicator")
  local down = assert(middle.saves.scrollIndicators.down, "content below needs an indicator")
  local viewport = middle.saves.viewport
  for _, mark in ipairs({ up, down }) do
    Assert.isTrue(mark.x >= viewport.x and mark.x + mark.width <= viewport.x + viewport.width)
    Assert.isTrue(mark.y >= viewport.y and mark.y + mark.height <= viewport.y + viewport.height)
    for _, card in pairs(middle.saves.cards) do
      Assert.isTrue(
        mark.x >= card.frame.x + card.frame.width,
        "scroll marks must sit beside the save cards instead of overlapping them"
      )
    end
  end
end

function T.confirmation_selection_is_inert_without_an_active_confirmation()
  local controller = MainMenuController.new(globalActions(), saves({ "one" }))
  Assert.isFalse(controller:focusConfirmation("cancel"))
  Assert.isFalse(controller:focusConfirmation("delete"))
  Assert.isNil(controller:snapshot().confirmation)
  Assert.isNil(controller:snapshot().popup)
end

function T.renderer_requires_a_supported_game_version()
  local graphics = FakeGraphics.new()
  Assert.throws(function()
    MainMenuRenderer.new({ text = recordingText({}), graphics = graphics })
  end, "construction without a game version must fail")
  Assert.throws(function()
    MainMenuRenderer.new({ text = recordingText({}), graphics = graphics, versionId = "unknown" })
  end, "construction with an unknown game version must fail")
  local renderer = MainMenuRenderer.new({
    text = recordingText({}),
    graphics = graphics,
    versionId = "heartgold",
  })
  Assert.notNil(renderer, "a supported game version must construct the launcher")
  renderer:dispose()
end

function T.card_faces_use_a_white_launcher_face_without_the_old_gradient()
  local drawn = drawnMenu({ catalogEntry("save-00000001", "PLAYER", 60) }, 640, 480)
  local rectangles = recordedRectangles(drawn.graphics)
  Assert.isTrue(hasRimColor(rectangles, { 1, 1, 1 }), "every card face must use the white launcher face")
  Assert.isFalse(
    hasRimColor(rectangles, { CARD_TONE.r / 255, CARD_TONE.g / 255, CARD_TONE.b / 255 }),
    "the retired selector tone must not remain on any launcher card"
  )
  for _, retired in ipairs({
    { 0.97, 0.96, 0.9 },
    { 0.89, 0.87, 0.77 },
    { 1, 0.87, 0.82 },
    { 0.94, 0.72, 0.66 },
  }) do
    Assert.isFalse(hasRimColor(rectangles, retired), "the old gradient face must not remain on any card")
  end
end

function T.renderer_needs_no_intro_manifest_once_the_launcher_owns_its_palette()
  local graphics = FakeGraphics.new()
  local renderer = MainMenuRenderer.new({
    text = recordingText({}),
    graphics = graphics,
    versionId = "soulsilver",
  })
  Assert.notNil(renderer, "launcher construction must not require the intro manifest")
  renderer:dispose()
end

function T.renderer_dispose_releases_its_text_exactly_once()
  local releases = 0
  local text = recordingText({})
  text.release = function()
    releases = releases + 1
  end
  local renderer = menuRenderer(text, FakeGraphics.new())
  renderer:dispose()
  renderer:dispose()
  Assert.equal(releases, 1, "the owned menu text must be released exactly once")
end

function T.body_focus_selects_the_entire_continue_frame()
  local drawn = drawnMenu({ catalogEntry("save-00000001", "PLAYER", 60) }, 640, 480)
  Assert.deepEqual(drawn.view.focus, { region = "saves", saveId = "save-00000001", lane = "body" })
  local rectangles = recordedRectangles(drawn.graphics)
  local card = assert(drawn.view.layout.saves.cards["save-00000001"])
  local rightEdge = {
    x = card.frame.x + card.frame.width - 8,
    y = card.frame.y + math.floor(card.frame.height / 2),
    width = 4,
    height = 4,
  }
  Assert.isTrue(
    hasRimColorOverlapping(rectangles, SELECTED_RIM, rightEdge),
    "body focus must carry the selected rim around the entire Continue frame, including its right edge"
  )
  Assert.isTrue(
    overflowInsetCoversParentSelection(rectangles, assert(card.overflow)),
    "the unfocused overflow control must disappear into the card face, covering the parent selection"
  )
end

-- Headless text doubles carry no fontDef, so the renderer falls back to the
-- canonical ROM line advance; profile-row bottoms below add that advance.
local PROFILE_LINE_HEIGHT = 16
-- Card chrome depth below the face at the renderer's resolve scale: 1px
-- border plus the 2px rim plus the 2px inner border. Profile ink must clear
-- it so the button edge never touches the text.
local BOTTOM_CHROME = 5

function T.continue_profile_rows_keep_bottom_padding_inside_the_card()
  local drawn = drawnMenu({ catalogEntry("save-00000001", "PLAYER", 60) }, 640, 480)
  local card = assert(drawn.view.layout.saves.cards["save-00000001"])
  local lastBottom = nil
  for _, call in ipairs(drawn.calls) do
    if call.text ~= "..." and call.text ~= "NEW GAME" then
      local bottom = call.y + PROFILE_LINE_HEIGHT
      if lastBottom == nil or bottom > lastBottom then
        lastBottom = bottom
      end
    end
  end
  lastBottom = assert(lastBottom, "the Continue card must draw profile rows")
  Assert.isTrue(
    lastBottom <= card.frame.y + card.frame.height - BOTTOM_CHROME,
    "the Continue profile rows must keep bottom padding inside the card instead of touching the button edge"
  )
end

function T.continue_overflow_inlay_matches_the_card_face()
  local drawn = drawnMenu({ catalogEntry("save-00000001", "PLAYER", 60) }, 640, 480)
  local card = assert(drawn.view.layout.saves.cards["save-00000001"])
  local overflow = assert(card.overflow, "the Continue card needs its overflow inlay")
  -- Probe the right rim band: inside the outer border, vertically centered
  -- to dodge the rounded corners.
  local probe = {
    x = overflow.x + overflow.width - 3,
    y = overflow.y + overflow.height / 2 - 2,
    width = 2,
    height = 4,
  }
  local last = nil
  for _, record in ipairs(recordedRectangles(drawn.graphics)) do
    if overlaps(record, probe) then
      last = record
    end
  end
  last = assert(last, "the overflow inlay must paint its rim band")
  Assert.isTrue(
    nearColor(last.color, CARD_FACE),
    "the unfocused Continue overflow inlay must disappear into the card face"
  )
end

function T.saves_reach_new_game_horizontally_and_remember_the_focused_save()
  local controller = MainMenuController.new(globalActions(), saves({ "one", "two", "three" }))
  controller:focusSave("two", "body")
  controller:move("left")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "Left from any save body must reach New Game directly"
  )
  controller:move("right")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "two", lane = "body" },
    "Right from New Game must return to the remembered save"
  )
  controller:focusSave("one", "body")
  controller:move("left")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "Left from the first save body must also reach New Game"
  )
  controller:setCatalog(globalActions(), saves({ "three" }))
  controller:move("right")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "three", lane = "body" },
    "removing the remembered save must make Right choose the first remaining save"
  )
  controller:focusSave("three", "body")
  controller:move("down")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "Down from the final save must reach the global action"
  )
  controller:focusGlobal("new-game")
  controller:move("up")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "three", lane = "body" },
    "Up from New Game must wrap to the last save body"
  )
  controller:focusGlobal("new-game")
  controller:move("down")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "three", lane = "body" },
    "Down from New Game must wrap to the first save body"
  )
  local empty = MainMenuController.new(globalActions(), {})
  empty:move("right")
  Assert.deepEqual(
    empty:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "Right with zero saves must stay on New Game"
  )
end

function T.popup_and_confirmation_geometry_scales_with_the_menu_scale()
  local cases = {
    { width = 320, height = 240, scale = 1 },
    { width = 640, height = 480, scale = 2 },
    { width = 1280, height = 720, scale = 3 },
  }
  for _, case in ipairs(cases) do
    local focus = { region = "saves", saveId = "one", lane = "overflow" }
    local layout = MainMenuLayout.compute(
      globalActions(),
      saves({ "one" }),
      focus,
      case.width,
      case.height,
      0,
      { saveId = "one", focusedAction = "delete" },
      { saveId = "one", focusedAction = "cancel" },
      false
    )
    Assert.isNil(layout.uiScale, "logical layout carries no presentation scale")
    local popup = assert(layout.popup, "popup geometry is required")
    Assert.equal(popup.box.width, 144, "popup width is logical")
    Assert.equal(popup.box.height, 56, "popup height is logical")
    Assert.isTrue(popup.box.x >= 0 and popup.box.y >= 0, "popup must stay inside the viewport")
    Assert.isTrue(
      popup.box.x + popup.box.width <= case.width and popup.box.y + popup.box.height <= case.height,
      "popup must stay contained in the viewport"
    )
    local confirmation = assert(layout.confirmation, "confirmation geometry is required")
    Assert.equal(confirmation.cancel.height, 36, "confirmation cancel height is logical")
    Assert.equal(confirmation.delete.height, 36, "confirmation delete height is logical")
    Assert.isTrue(confirmation.box.x >= 0 and confirmation.box.y >= 0, "confirmation must stay inside the viewport")
    Assert.isTrue(
      confirmation.box.x + confirmation.box.width <= case.width
        and confirmation.box.y + confirmation.box.height <= case.height,
      "confirmation must stay contained in the viewport"
    )
    Assert.isTrue(confirmation.cancel.width > 0 and confirmation.cancel.height > 0, "cancel action must stay positive")
    Assert.isTrue(confirmation.delete.width > 0 and confirmation.delete.height > 0, "delete action must stay positive")
    Assert.isFalse(
      MainMenuLayout.contains(confirmation.cancel, confirmation.delete.x + 1, confirmation.delete.y + 1),
      "confirmation actions must stay disjoint"
    )
  end
end

function T.collection_edge_vertical_moves_reach_global_and_restore_remembered_lane()
  local controller = MainMenuController.new(globalActions(), saves({ "one", "two", "three" }))
  controller:focusSave("one", "body")
  controller:move("up")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "Up from the first save body must reach the global action"
  )
  controller:move("right")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "one", lane = "body" },
    "Right from global must restore the remembered first save body"
  )
  controller:focusSave("one", "overflow")
  controller:move("up")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "Up from the first save overflow must reach the global action"
  )
  controller:move("right")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "one", lane = "overflow" },
    "Right from global must restore the remembered overflow lane"
  )
  controller:focusSave("three", "body")
  controller:move("down")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "Down from the last save body must reach the global action"
  )
  controller:move("right")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "three", lane = "body" },
    "Right from global must restore the remembered last save body"
  )
  controller:focusSave("three", "overflow")
  controller:move("down")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "Down from the last save overflow must reach the global action"
  )
  controller:move("right")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "three", lane = "overflow" },
    "Right from global must restore the remembered last overflow lane"
  )
  controller:focusSave("two", "body")
  controller:move("down")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "three", lane = "body" },
    "interior Down must preserve the body lane"
  )
  controller:focusSave("two", "overflow")
  controller:move("down")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "three", lane = "overflow" },
    "interior Down must preserve the overflow lane"
  )
  local single = MainMenuController.new(globalActions(), saves({ "only" }))
  single:focusSave("only", "body")
  single:move("up")
  Assert.deepEqual(
    single:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "Up from the only save must reach the global action"
  )
  single:focusSave("only", "body")
  single:move("down")
  Assert.deepEqual(
    single:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "Down from the only save must reach the global action"
  )
  local empty = MainMenuController.new(globalActions(), {})
  empty:move("right")
  Assert.deepEqual(
    empty:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "Right with zero saves must stay on the global action"
  )
end

function T.global_right_falls_back_to_body_when_the_remembered_overflow_is_locked()
  local controller = MainMenuController.new(globalActions(), saves({ "one", "two" }))
  controller:focusSave("one", "overflow")
  controller:move("up")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "Up from the first save overflow must reach the global action"
  )
  local locked = saves({ "one", "two" })
  locked[1].canDelete = false
  controller:setCatalog(globalActions(), locked)
  controller:move("right")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "one", lane = "body" },
    "Right must fall back to the body when the remembered save lost its overflow"
  )
end

function T.delete_confirmation_responds_to_horizontal_arrows_only()
  local controller = MainMenuController.new(globalActions(), saves({ "one" }))
  controller:focusSave("one", "overflow")
  Assert.isTrue(controller:activate() == nil)
  Assert.isTrue(controller:activate() == nil)
  Assert.deepEqual(controller:snapshot().confirmation, { saveId = "one", focusedAction = "cancel" })
  controller:move("right")
  Assert.equal(controller:snapshot().confirmation.focusedAction, "delete")
  controller:move("up")
  Assert.equal(controller:snapshot().confirmation.focusedAction, "delete")
  controller:move("down")
  Assert.equal(controller:snapshot().confirmation.focusedAction, "delete")
  controller:move("left")
  Assert.equal(controller:snapshot().confirmation.focusedAction, "cancel")
  controller:move("down")
  Assert.equal(controller:snapshot().confirmation.focusedAction, "cancel")
  controller:move("up")
  Assert.equal(controller:snapshot().confirmation.focusedAction, "cancel")
end

function T.launcher_cards_use_white_faces_blue_inner_borders_and_roomy_content()
  local drawn = drawnMenu({ catalogEntry("save-00000001", "PLAYER", 60) }, 640, 480)
  local rectangles = recordedRectangles(drawn.graphics)
  Assert.isTrue(hasRimColor(rectangles, { 1, 1, 1 }), "save cards must use a white face")
  Assert.isTrue(
    hasRimColor(rectangles, { 162 / 255, 227 / 255, 219 / 255 }),
    "save cards must use the blue inner border"
  )
  local card = assert(drawn.view.layout.saves.cards["save-00000001"])
  local headingX
  for _, call in ipairs(drawn.calls) do
    if call.text == "CONTINUE" then
      headingX = call.x
    end
  end
  Assert.notNil(headingX, "the Continue card must draw its heading")
  assert(headingX)
  Assert.equal(headingX, card.frame.x + 10, "card content must sit 10 logical pixels inside the card")
end

function T.launcher_copy_uses_neutral_gray_text_shadow()
  local drawn = drawnMenu({ catalogEntry("save-00000001", "PLAYER", 60) }, 640, 480)
  local shadow
  for _, call in ipairs(drawn.calls) do
    if call.palette and call.palette.shadow then
      shadow = call.palette.shadow
      break
    end
  end
  Assert.notNil(shadow, "launcher copy must draw through the palette path with a shadow role")
  assert(shadow)
  Assert.equal(shadow.r, 140, "launcher text shadow must be neutral gray")
  Assert.equal(shadow.g, 140, "launcher text shadow must be neutral gray")
  Assert.equal(shadow.b, 140, "launcher text shadow must be neutral gray")
end

local function versionedBackgroundDraw(versionId)
  local graphics = FakeGraphics.new()
  local calls = {}
  local renderer = MainMenuRenderer.new({
    text = recordingText(calls),
    graphics = graphics,
    versionId = versionId,
  })
  local menu = state({
    saveStore = {
      list = function()
        return {}
      end,
    },
    width = 640,
    height = 480,
  })
  local current = menu:view()
  renderer:draw(current, current.presentation)
  return recordedRectangles(graphics)
end

function T.launcher_background_follows_the_active_game_version()
  local heartgold = versionedBackgroundDraw("heartgold")
  Assert.isTrue(hasRimColor(heartgold, { 255 / 255, 214 / 255, 148 / 255 }), "heartgold must own its backdrop fill")
  local soulsilver = versionedBackgroundDraw("soulsilver")
  Assert.isTrue(hasRimColor(soulsilver, { 97 / 255, 97 / 255, 251 / 255 }), "soulsilver must own its backdrop fill")
end

function T.launcher_rejects_an_unknown_game_version()
  Assert.throws(function()
    MainMenuRenderer.new({
      text = recordingText({}),
      graphics = FakeGraphics.new(),
      versionId = "unknown",
    })
  end, "an unknown game version must fail launcher construction")
end

function T.global_vertical_wrap_selects_edge_save_bodies()
  local controller = MainMenuController.new(globalActions(), saves({ "one", "two", "three" }))
  controller:focusGlobal("new-game")
  controller:move("up")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "three", lane = "body" },
    "up from New Game must wrap to the last save body"
  )
  controller:focusGlobal("new-game")
  controller:move("down")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "one", lane = "body" },
    "down from New Game must wrap to the first save body"
  )
  controller:focusSave("one", "body")
  controller:move("up")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "up from the first save must return to New Game"
  )
  controller:focusSave("three", "body")
  controller:move("down")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "down from the last save must return to New Game"
  )
end

function T.global_wrap_lands_on_the_body_lane_from_overflow_memory()
  local controller = MainMenuController.new(globalActions(), saves({ "one", "two", "three" }))
  controller:focusSave("two", "overflow")
  controller:focusGlobal("new-game")
  controller:move("up")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "three", lane = "body" },
    "crossing from New Game to the saves must land on the body lane"
  )
  controller:focusGlobal("new-game")
  controller:move("down")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "one", lane = "body" },
    "crossing from New Game to the saves must land on the body lane"
  )
  controller:focusSave("one", "overflow")
  controller:move("up")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "up from the first save overflow must return to New Game"
  )
  controller:focusSave("three", "overflow")
  controller:move("down")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "down from the last save overflow must return to New Game"
  )
end

function T.global_wrap_with_zero_and_single_save_catalogs()
  local empty = MainMenuController.new(globalActions(), {})
  empty:move("up")
  Assert.deepEqual(
    empty:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "up with zero saves must stay on New Game"
  )
  empty:move("down")
  Assert.deepEqual(
    empty:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "down with zero saves must stay on New Game"
  )
  empty:move("left")
  Assert.deepEqual(empty:snapshot().focus, { region = "global", actionId = "new-game" })
  empty:move("right")
  Assert.deepEqual(empty:snapshot().focus, { region = "global", actionId = "new-game" })

  local single = MainMenuController.new(globalActions(), saves({ "only" }))
  single:focusGlobal("new-game")
  single:move("up")
  Assert.deepEqual(
    single:snapshot().focus,
    { region = "saves", saveId = "only", lane = "body" },
    "up from New Game with one save must select that save body"
  )
  single:focusGlobal("new-game")
  single:move("down")
  Assert.deepEqual(
    single:snapshot().focus,
    { region = "saves", saveId = "only", lane = "body" },
    "down from New Game with one save must select that save body"
  )
  single:focusSave("only", "body")
  single:move("up")
  Assert.deepEqual(
    single:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "up from the only save must return to New Game"
  )
  single:focusSave("only", "body")
  single:move("down")
  Assert.deepEqual(
    single:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "down from the only save must return to New Game"
  )
end

function T.global_right_still_restores_the_remembered_save_after_wrap()
  local controller = MainMenuController.new(globalActions(), saves({ "one", "two", "three" }))
  controller:focusSave("two", "overflow")
  controller:focusGlobal("new-game")
  controller:move("right")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "two", lane = "overflow" },
    "right from New Game must restore the remembered save lane when still valid"
  )
  controller:focusGlobal("new-game")
  controller:setCatalog(globalActions(), saves({ "one", "three" }))
  controller:move("right")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "one", lane = "body" },
    "right from New Game must fall back to the first save body when remembered is gone"
  )
  local locked = saves({ "one", "two" })
  locked[1].canDelete = false
  local overflowed = MainMenuController.new(globalActions(), saves({ "one", "two" }))
  overflowed:focusSave("one", "overflow")
  overflowed:setCatalog(globalActions(), locked)
  overflowed:focusGlobal("new-game")
  overflowed:move("right")
  Assert.deepEqual(
    overflowed:snapshot().focus,
    { region = "saves", saveId = "one", lane = "body" },
    "right must fall back to the save body when the remembered overflow lane is locked"
  )
end

local PROFILE_BLUE = { foreground = { r = 0, g = 113, b = 251 }, shadow = { r = 0, g = 81, b = 251 } }

-- Text double that records the active graphics scale with every palette draw
-- and measures with a deterministic width so alignment can be recomputed
-- from the same observable boundary the renderer must use.
local function scaledRecordingText(calls, graphics)
  return {
    textWidth = function(_, value)
      return #value * GLYPH_ADVANCE
    end,
    drawTextWithPalette = function(_, value, x, y, palette)
      -- Text draws at logical coordinates under one root placement: record
      -- the logical point as passed plus the active root scale behind it.
      local activeScale = 1
      for index = #graphics.transforms, 1, -1 do
        local transform = graphics.transforms[index]
        if transform[1] == "scale" then
          activeScale = transform[2]
          break
        end
      end
      calls[#calls + 1] = { text = value, x = x, y = y, scale = activeScale, palette = palette }
    end,
  }
end

local function scaledDrawnMenu(entries, width, height)
  local graphics = FakeGraphics.new()
  local calls = {}
  local renderer =
    MainMenuRenderer.new({ text = scaledRecordingText(calls, graphics), graphics = graphics, versionId = "heartgold" })
  local menu = state({
    saveStore = {
      list = function()
        return entries
      end,
    },
    width = width,
    height = height,
    renderer = { draw = function() end, dispose = function() end },
  })
  local current = menu:view()
  renderer:draw(current, current.presentation)
  return { graphics = graphics, calls = calls, view = current }
end

function T.continue_body_focus_uses_rounded_selected_chrome_without_a_square_ring()
  local drawn = drawnMenu({ catalogEntry("save-00000001", "PLAYER", 60) }, 640, 480)
  Assert.deepEqual(drawn.view.focus, { region = "saves", saveId = "save-00000001", lane = "body" })
  local card = assert(drawn.view.layout.saves.cards["save-00000001"])
  local frame = assert(card.frame)
  local rectangles = recordedRectangles(drawn.graphics)
  local roundedSelected = false
  for _, record in ipairs(rectangles) do
    if nearColor(record.color, SELECTED_RIM) and overlaps(record, frame) then
      if record.rx ~= nil and record.rx > 0 then
        roundedSelected = true
      else
        error("the Continue body must not paint a square manual focus ring", 0)
      end
    end
  end
  Assert.isTrue(roundedSelected, "body focus must select the Continue card through rounded button chrome")
  Assert.isTrue(
    overflowInsetCoversParentSelection(rectangles, assert(card.overflow)),
    "the unfocused overflow control must disappear into the card face, covering the parent selection"
  )
end

function T.continue_text_scales_exactly_with_the_menu_scale()
  local cases = {
    { width = 320, height = 240, scale = 1 },
    { width = 640, height = 480, scale = 2 },
    { width = 1280, height = 720, scale = 3 },
  }
  for _, case in ipairs(cases) do
    local drawn = scaledDrawnMenu({ catalogEntry("save-00000001", "PLAYER", 60) }, case.width, case.height)
    local placement = assert(drawn.view.presentation.panes[1].placement, "the menu plan carries its placement")
    Assert.equal(placement.pixelScale, case.scale, "viewport must select menu scale " .. case.scale)
    Assert.isTrue(#drawn.calls > 0, "the menu must draw copy at scale " .. case.scale)
    for _, call in ipairs(drawn.calls) do
      Assert.equal(call.scale, math.floor(call.scale), "menu text scaling must never be fractional")
      Assert.equal(call.scale, case.scale, "menu text must track the menu scale: " .. call.text)
    end
  end
end

function T.continue_card_shows_cased_profile_rows_in_retail_blue()
  local drawn = scaledDrawnMenu({ catalogEntry("save-00000001", "Goldie", 4980) }, 640, 480)
  Assert.equal(drawn.view.saves[1].playTimeLabel, "1:23")
  local card = assert(drawn.view.layout.saves.cards["save-00000001"])
  local body = assert(card.body)
  local positions = {}
  for _, call in ipairs(drawn.calls) do
    if call.text == "GOLDIE" then
      error("the Continue card must preserve the stored player-name casing", 0)
    end
    positions[call.text] = positions[call.text] or {}
    positions[call.text][#positions[call.text] + 1] = call
  end
  local wanted = { "PLAYER", "Goldie", "TIME", "1:23", "BADGES", "0" }
  local order = {}
  for index, call in ipairs(drawn.calls) do
    for _, text in ipairs(wanted) do
      if call.text == text and order[text] == nil then
        order[text] = index
      end
    end
  end
  for _, text in ipairs(wanted) do
    Assert.notNil(order[text], "the Continue card must draw " .. text)
  end
  for index = 2, #wanted do
    Assert.isTrue(order[wanted[index - 1]] < order[wanted[index]], "profile rows must read PLAYER/TIME/BADGES in order")
  end
  local blockWidth = 0.62 * body.width
  local blockLeft = body.x + (body.width - blockWidth) / 2
  local blockRight = blockLeft + blockWidth
  local previousY = nil
  for row = 1, 3 do
    local label = assert(positions[wanted[(row - 1) * 2 + 1]][1], "profile label is required")
    local value = assert(positions[wanted[(row - 1) * 2 + 2]][1], "profile value is required")
    Assert.notNil(label.palette, "profile copy must draw through the palette path")
    Assert.equal(label.palette.foreground.r, PROFILE_BLUE.foreground.r, "profile copy uses retail blue")
    Assert.equal(label.palette.foreground.g, PROFILE_BLUE.foreground.g, "profile copy uses retail blue")
    Assert.equal(label.palette.foreground.b, PROFILE_BLUE.foreground.b, "profile copy uses retail blue")
    Assert.equal(label.palette.shadow.r, PROFILE_BLUE.shadow.r, "profile copy uses the dark blue shadow")
    Assert.equal(label.palette.shadow.g, PROFILE_BLUE.shadow.g, "profile copy uses the dark blue shadow")
    Assert.equal(label.palette.shadow.b, PROFILE_BLUE.shadow.b, "profile copy uses the dark blue shadow")
    Assert.equal(value.palette.foreground.r, PROFILE_BLUE.foreground.r, "profile values use retail blue")
    Assert.equal(value.palette.foreground.g, PROFILE_BLUE.foreground.g, "profile values use retail blue")
    Assert.equal(value.palette.foreground.b, PROFILE_BLUE.foreground.b, "profile values use retail blue")
    Assert.near(label.x, blockLeft, 0.51, "profile labels share the centered block left edge")
    Assert.near(
      value.x + #wanted[(row - 1) * 2 + 2] * GLYPH_ADVANCE,
      blockRight,
      0.51,
      "profile values share the centered block right edge"
    )
    Assert.equal(label.y, value.y, "each profile label shares its value baseline")
    Assert.isTrue(label.y >= body.y and value.y >= body.y, "profile rows must stay inside the Continue body")
    Assert.isTrue(
      label.x >= body.x and value.x + #wanted[(row - 1) * 2 + 2] * GLYPH_ADVANCE <= body.x + body.width,
      "profile rows must stay inside the Continue body"
    )
    if previousY ~= nil then
      Assert.isTrue(label.y > previousY, "profile rows must run top to bottom")
    end
    previousY = label.y
  end
end

function T.unavailable_saves_show_error_summary_without_profile_rows()
  local drawn = scaledDrawnMenu({
    {
      saveId = "save-00000001",
      versionId = "heartgold",
      error = "save could not be loaded",
    },
  }, 640, 480)
  Assert.isFalse(drawn.view.saves[1].canContinue, "the fixture must exercise the unavailable save path")
  local seenError = false
  for _, call in ipairs(drawn.calls) do
    Assert.isNil(
      ({ PLAYER = true, TIME = true, BADGES = true })[call.text],
      "unavailable saves must not fabricate profile rows: " .. call.text
    )
    if call.text == "SAVE COULD NOT BE LOADED" then
      seenError = true
    end
  end
  Assert.isTrue(seenError, "unavailable saves keep their error summary")
end

function T.overflow_focus_keeps_the_parent_card_neutral()
  local graphics = FakeGraphics.new()
  local calls = {}
  local renderer = menuRenderer(recordingText(calls), graphics)
  local menu = state({
    saveStore = {
      list = function()
        return { catalogEntry("save-00000001", "Goldie", 4980) }
      end,
    },
    width = 640,
    height = 480,
    renderer = { draw = function() end, dispose = function() end },
  })
  menu:keypressed("right")
  local current = menu:view()
  Assert.deepEqual(current.focus, { region = "saves", saveId = "save-00000001", lane = "overflow" })
  renderer:draw(current, current.presentation)
  local rectangles = recordedRectangles(graphics)
  local card = assert(current.layout.saves.cards["save-00000001"])
  Assert.isFalse(
    hasRimColorOverlapping(rectangles, SELECTED_RIM, card.body),
    "overflow focus must return the Continue body to its neutral rim"
  )
  Assert.isTrue(
    hasRimColorOverlapping(rectangles, SELECTED_RIM, assert(card.overflow)),
    "overflow focus must select the overflow control itself"
  )
  local seenPlayer, seenBadges = false, false
  for _, call in ipairs(calls) do
    if call.text == "Goldie" then
      seenPlayer = true
    end
    if call.text == "BADGES" then
      seenBadges = true
    end
  end
  Assert.isTrue(seenPlayer, "overflow focus must keep the cased profile rows visible")
  Assert.isTrue(seenBadges, "overflow focus must keep every profile row visible")
end

function T.profile_rows_stay_inside_the_continue_body_at_supported_scales()
  local cases = {
    { width = 320, height = 240, scale = 1 },
    { width = 1280, height = 720, scale = 3 },
  }
  local wanted = { "PLAYER", "Goldie", "TIME", "1:23", "BADGES", "0" }
  for _, case in ipairs(cases) do
    local drawn = scaledDrawnMenu({ catalogEntry("save-00000001", "Goldie", 4980) }, case.width, case.height)
    local placement = assert(drawn.view.presentation.panes[1].placement, "the menu plan carries its placement")
    Assert.equal(placement.pixelScale, case.scale, "viewport must select menu scale " .. case.scale)
    local body = assert(drawn.view.layout.saves.cards["save-00000001"].body)
    local overflow = assert(drawn.view.layout.saves.cards["save-00000001"].overflow)
    local previousY = nil
    for _, text in ipairs(wanted) do
      local found = nil
      for _, call in ipairs(drawn.calls) do
        if call.text == text then
          found = call
          break
        end
      end
      Assert.notNil(found, "the Continue card must draw " .. text .. " at scale " .. case.scale)
      assert(found)
      local right = found.x + #text * GLYPH_ADVANCE
      Assert.isTrue(found.x >= body.x, "profile copy must stay inside the Continue body: " .. text)
      Assert.isTrue(right <= body.x + body.width, "profile copy must stay inside the Continue body: " .. text)
      Assert.isTrue(found.y >= body.y, "profile rows must stay inside the Continue body: " .. text)
      Assert.isTrue(found.y <= body.y + body.height, "profile rows must stay inside the Continue body: " .. text)
      Assert.isTrue(
        right <= overflow.x or found.x >= overflow.x + overflow.width,
        "profile rows must stay horizontally clear of the overflow control: " .. text
      )
      if previousY ~= nil then
        Assert.isTrue(found.y >= previousY, "profile rows must run top to bottom at scale " .. case.scale)
      end
      previousY = found.y
    end
  end
end

function T.layout_result_carries_no_presentation_scale()
  local layout = MainMenuLayout.compute(
    globalActions(),
    saves({ "one" }),
    { region = "saves", saveId = "one", lane = "body" },
    640,
    480,
    0,
    nil,
    nil,
    false
  )
  Assert.isNil(layout.uiScale, "logical layout must not carry a presentation scale")
end

function T.state_view_publishes_a_presentation_plan()
  local menu = state({ width = 640, height = 480 })
  local published = menu:view()
  local plan =
    assert(published.presentation, "Main Menu must publish its presentation plan beside its semantic snapshot")
  Assert.isTrue(type(plan.panes) == "table" and #plan.panes >= 1, "the menu plan must carry its content panes")
  Assert.isTrue(
    type(plan.render) == "function" and type(plan.mapInput) == "function",
    "the menu plan must carry its matched render and input callbacks"
  )
end

function T.hit_test_resolves_confirmation_modal_precedence()
  local menu = state({
    saveStore = {
      list = function()
        return {
          {
            saveId = "save-00000001",
            versionId = "heartgold",
            playerData = { profile = { name = "PLAYER" } },
            playTimeSeconds = 60,
          },
        }
      end,
    },
    width = 640,
    height = 480,
  })
  menu:keypressed("right")
  menu:keypressed("return")
  Assert.notNil(menu:view().popup, "overflow activation must open the save popup")
  menu:keypressed("return")
  Assert.notNil(menu:view().confirmation, "popup activation must open the delete confirmation")
  local published = menu:view()
  local deleteRect = assert(published.layout.confirmation).delete
  local placement = assert(published.presentation.panes[1].placement, "the menu plan carries its placement")
  local hostX, hostY =
    LayoutGeometry.logicalToHost(placement, deleteRect.x + deleteRect.width / 2, deleteRect.y + deleteRect.height / 2)
  local hit = menu:hitTest(hostX, hostY)
  Assert.equal(hit.region, "confirmation", "the confirmation delete control must win hit precedence")
  Assert.equal(hit.saveId, "save-00000001", "the confirmation hit must name its owning save")
end

function T.pointer_transition_during_dispatch_does_not_resolve_after_dispose()
  -- Production replaces (and disposes) the menu synchronously inside
  -- onResult via Game:setState; the in-flight pointer dispatch must stop
  -- instead of resolving again against the released session.
  local results = {}
  local menu = nil
  menu = state({
    saveStore = {
      list = function()
        return {}
      end,
    },
    onResult = function(result)
      results[#results + 1] = result
      assert(menu ~= nil, "menu must exist when the result fires")
      menu:dispose()
    end,
  })
  local published = menu:view()
  local action = assert(published.layout.global.actions["new-game"], "New Game needs hit geometry")
  pressAt(menu, action.x + action.width / 2, action.y + action.height / 2)
  Assert.deepEqual(results, { { kind = "new_game" } })
  menu:mousepressed(1, 1, 1)
  menu:mousereleased(1, 1, 1)
  menu:keypressed("return")
end

return { tests = T }
