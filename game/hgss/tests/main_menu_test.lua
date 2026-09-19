-- Lower-layer contracts for Main Menu focus, catalog state, layout, and failures.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FakeGraphics = require("tests.support.FakeGraphics")
local IntroAssetCache = require("libs.assets.src.newgame.IntroAssetCache")
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
    { region = "global", actionId = "new-game" },
    "up from New Game must stay on New Game"
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
  controller:move("down")
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
  local card = assert(menu:view().layout.saves.cards["save-00000001"])
  menu:mousepressed(card.overflow.x + 1, card.overflow.y + 1, 1)
  Assert.deepEqual(results, {})
  Assert.deepEqual(menu:view().focus, { region = "saves", saveId = "save-00000001", lane = "overflow" })
  Assert.deepEqual(menu:hitTest(card.overflow.x + 1, card.overflow.y + 1), {
    region = "saves",
    saveId = "save-00000001",
    lane = "overflow",
  })
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
  menu:keypressed("down")
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
  menu:keypressed("delete")
  menu:keypressed("return")
  menu:keypressed("down")
  menu:keypressed("return")
  local view = menu:view()
  Assert.equal(view.catalogError, "save could not be deleted")
  Assert.equal(view.focusedId, "save-00000001")
  Assert.notNil(view.layout.saves.cards["save-00000001"])
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
  Assert.equal(layout.uiScale, 2)
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
  menu:keypressed("down")
  Assert.equal(menu.controller.confirmation.focusedAction, "delete")
  local confirmation = assert(menu:layout().confirmation)
  menu:mousepressed(
    confirmation.delete.x + confirmation.delete.width / 2,
    confirmation.delete.y + confirmation.delete.height / 2,
    1
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
  cancelMenu:keypressed("down")
  Assert.equal(cancelMenu.controller.confirmation.focusedAction, "delete")
  local cancelBox = assert(cancelMenu:layout().confirmation)
  cancelMenu:mousepressed(
    cancelBox.cancel.x + cancelBox.cancel.width / 2,
    cancelBox.cancel.y + cancelBox.cancel.height / 2,
    1
  )
  Assert.isNil(cancelMenu.controller.confirmation)
  Assert.notNil(cancelMenu.controller.popup)
end

function T.vertical_moves_stay_within_their_region_without_wrapping()
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
    { region = "global", actionId = "new-game" },
    "down from New Game must not wrap to the first save"
  )
  controller:move("up")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "up from New Game must stay on New Game"
  )
  controller:move("right")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "saves", saveId = "three", lane = "body" },
    "right from New Game must return to the remembered save"
  )
  controller:move("up")
  Assert.deepEqual(controller:snapshot().focus, { region = "saves", saveId = "two", lane = "body" })
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
  menu:keypressed("down")
  Assert.equal(menu:view().confirmation.focusedAction, "delete")
  local confirmation = assert(menu:view().layout.confirmation, "confirmation needs hit geometry")
  local deleteRect = confirmation.delete
  menu:mousepressed(deleteRect.x + deleteRect.width / 2, deleteRect.y + deleteRect.height / 2, 1)
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
local NEUTRAL_RIM = { 222 / 255, 230 / 255, 230 / 255 }

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

local function recordingText(calls)
  return {
    drawText = function(_, text, x, y)
      calls[#calls + 1] = { text = text, x = x, y = y }
    end,
    drawTextWithPalette = function(_, text, x, y, palette)
      calls[#calls + 1] = { text = text, x = x, y = y, palette = palette }
    end,
  }
end

local INTRO_WIDGETS = {
  "ball_open",
  "female",
  "gender_female",
  "gender_male",
  "male",
  "marill",
  "marill_appear",
  "naming_female",
  "naming_male",
  "oak",
  "shrink_female",
  "shrink_male",
}

local function introManifestWithTone(tone)
  local widgets = {}
  for _, id in ipairs(INTRO_WIDGETS) do
    local path = "assets/generated/intro/" .. id .. ".png"
    widgets[id] = {
      image = path,
      width = 32,
      height = 32,
      anchor = { x = 16, y = 32 },
      sourceBounds = { x = 0, y = 0, width = 32, height = 32 },
      sampling = "nearest",
      provenance = { rule = "alpha-crop" },
      frames = {
        {
          image = path,
          width = 32,
          height = 32,
          duration = 4,
          element = "none",
          translateX = 0,
          translateY = 0,
          scaleX = 1,
          scaleY = 1,
          rotation = 0,
          anchor = { x = 16, y = 32 },
        },
      },
    }
  end
  for _, id in ipairs({ "ball_open", "marill_appear", "marill" }) do
    widgets[id].sourceCenter = { x = 160, y = 80 }
  end
  for _, id in ipairs({
    "ball_open",
    "marill_appear",
    "marill",
    "gender_male",
    "gender_female",
    "naming_male",
    "naming_female",
  }) do
    widgets[id].playMode = "forward"
    widgets[id].loopStartFrameIdx = 0
  end
  widgets.gender_male.sourceCenter = { x = 64, y = 104 }
  widgets.gender_female.sourceCenter = { x = 192, y = 104 }
  return {
    schemaVersion = IntroAssetCache.SCHEMA_VERSION,
    variant = "heartgold",
    sourceReference = { width = 256, height = 192 },
    background = {
      image = "assets/generated/intro/background.png",
      width = 1,
      height = 192,
      sampling = "linear",
      provenance = { charMember = 0, screenMember = 3, paletteMember = 1 },
    },
    genderSelector = {
      defaultTone = { r = tone.r, g = tone.g, b = tone.b },
      buttons = {
        male = { bounds = { x = 18, y = 25, width = 93, height = 148 } },
        female = { bounds = { x = 144, y = 25, width = 95, height = 148 } },
      },
    },
    widgets = widgets,
  }
end

local CARD_TONE = { r = 123, g = 45, b = 67 }

local function cardCacheFs(tone)
  local manifest = introManifestWithTone(tone or CARD_TONE)
  Assert.isTrue(IntroAssetCache.validateManifest(manifest), "the card face fixture must be a valid intro manifest")
  return {
    loadLua = function(_, path)
      Assert.equal(path, IntroAssetCache.manifestPath(), "the card face must come from the intro manifest path")
      return manifest
    end,
  }
end

local function menuRenderer(text, graphics, tone)
  return MainMenuRenderer.new({ text = text, cacheFs = cardCacheFs(tone), graphics = graphics })
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
  renderer:draw(current)
  return { graphics = graphics, calls = calls, view = current, menu = menu }
end

function T.focused_continue_uses_selected_rim_while_other_cards_stay_neutral()
  local drawn =
    drawnMenu({ catalogEntry("save-00000001", "PLAYER", 60), catalogEntry("save-00000002", "OTHER", 120) }, 640, 480)
  local rectangles = recordedRectangles(drawn.graphics)
  Assert.isTrue(hasRimColor(rectangles, SELECTED_RIM), "the focused Continue card must use the selected rim color")
  Assert.isTrue(hasRimColor(rectangles, NEUTRAL_RIM), "unfocused cards must keep the neutral rim color")
  local focusedCard = assert(drawn.view.layout.saves.cards["save-00000001"])
  Assert.isFalse(
    hasRimColorOverlapping(rectangles, SELECTED_RIM, assert(focusedCard.overflow)),
    "body focus must not leave the nested overflow control looking selected"
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
    menu:keypressed("down")
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

function T.principal_copy_renders_at_an_integer_scale_and_restores_transforms()
  local drawn = drawnMenu({ catalogEntry("save-00000001", "PLAYER", 60) }, 640, 480)
  local foundDouble = false
  for _, transform in ipairs(drawn.graphics.transforms) do
    if transform[1] == "scale" then
      Assert.isTrue(
        transform[2] == math.floor(transform[2]) and transform[3] == math.floor(transform[3]),
        "menu text scaling must never be fractional"
      )
      if transform[2] == 2 and transform[3] == 2 then
        foundDouble = true
      end
    end
  end
  Assert.isTrue(foundDouble, "principal menu copy at the desktop baseline must render at twice the generated font size")
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
    if call.text == "g4recomp" then
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
    renderer:draw(shaped)
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

function T.layout_reports_integer_scale_and_full_scroll_availability()
  local one = saves({ "one" })
  local body = { region = "saves", saveId = "one", lane = "body" }
  Assert.equal(MainMenuLayout.compute(globalActions(), one, body, 320, 240, 0, nil, nil, false).uiScale, 1)
  Assert.equal(MainMenuLayout.compute(globalActions(), one, body, 640, 480, 0, nil, nil, false).uiScale, 2)
  Assert.equal(MainMenuLayout.compute(globalActions(), one, body, 1280, 720, 0, nil, nil, false).uiScale, 3)
  Assert.equal(MainMenuLayout.compute(globalActions(), one, body, 2560, 1440, 0, nil, nil, false).uiScale, 3)

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

function T.renderer_requires_a_version_cache_for_the_generated_card_face()
  local graphics = FakeGraphics.new()
  Assert.throws(function()
    MainMenuRenderer.new({ text = recordingText({}), graphics = graphics })
  end, "the Main Menu card face comes from the generated intro tone, so construction without a version cache must fail")
end

function T.card_faces_use_the_flat_generated_tone_without_the_old_gradient()
  local drawn = drawnMenu({ catalogEntry("save-00000001", "PLAYER", 60) }, 640, 480)
  local rectangles = recordedRectangles(drawn.graphics)
  Assert.isTrue(
    hasRimColor(rectangles, { CARD_TONE.r / 255, CARD_TONE.g / 255, CARD_TONE.b / 255 }),
    "every card face must use the flat generated tone"
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

function T.renderer_rejects_a_missing_or_invalid_intro_manifest()
  local graphics = FakeGraphics.new()
  Assert.throws(function()
    MainMenuRenderer.new({
      text = recordingText({}),
      graphics = graphics,
      cacheFs = {
        loadLua = function()
          return nil
        end,
      },
    })
  end, "a missing intro manifest must fail Main Menu construction")
  Assert.throws(function()
    MainMenuRenderer.new({
      text = recordingText({}),
      graphics = graphics,
      cacheFs = {
        loadLua = function()
          return { schemaVersion = 0 }
        end,
      },
    })
  end, "an invalid intro manifest must fail Main Menu construction")
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
  Assert.isFalse(
    hasRimColorOverlapping(rectangles, SELECTED_RIM, assert(card.overflow)),
    "body focus must leave the nested overflow control neutral"
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
    { region = "global", actionId = "new-game" },
    "Up from the first save must reach the global action"
  )
  controller:focusGlobal("new-game")
  controller:move("up")
  Assert.deepEqual(
    controller:snapshot().focus,
    { region = "global", actionId = "new-game" },
    "Up from New Game must stay on New Game"
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
    Assert.equal(layout.uiScale, case.scale, "viewport must select menu scale " .. case.scale)
    local popup = assert(layout.popup, "popup geometry is required at scale " .. case.scale)
    Assert.equal(popup.box.width, 144 * case.scale, "popup width must scale with the menu")
    Assert.equal(popup.box.height, 56 * case.scale, "popup height must scale with the menu")
    Assert.isTrue(popup.box.x >= 0 and popup.box.y >= 0, "popup must stay inside the viewport")
    Assert.isTrue(
      popup.box.x + popup.box.width <= case.width and popup.box.y + popup.box.height <= case.height,
      "popup must stay contained in the viewport"
    )
    local confirmation = assert(layout.confirmation, "confirmation geometry is required at scale " .. case.scale)
    Assert.equal(confirmation.cancel.height, 36 * case.scale, "confirmation cancel height must scale with the menu")
    Assert.equal(confirmation.delete.height, 36 * case.scale, "confirmation delete height must scale with the menu")
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

return { tests = T }
