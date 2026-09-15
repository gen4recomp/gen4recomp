-- Lower-layer contracts for Main Menu focus, catalog state, layout, and failures.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local MainMenuController = require("game.hgss.src.menu.MainMenuController")
local MainMenuLayout = require("game.hgss.src.menu.MainMenuLayout")
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
  controller:move("left")
  Assert.deepEqual(controller:snapshot().focus, { region = "global", actionId = "new-game" })
  controller:move("right")
  Assert.deepEqual(controller:snapshot().focus, { region = "saves", saveId = "one", lane = "body" })
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

function T.controller_keeps_overflow_at_the_list_edges()
  local controller = MainMenuController.new(globalActions(), saves({ "one", "two" }))
  controller:focusSave("one", "overflow")
  controller:move("up")
  Assert.equal(controller:focusedId(), "one")
  controller:focusSave("two", "overflow")
  controller:move("down")
  Assert.equal(controller:focusedId(), "two")
end

function T.layout_separates_global_and_scrollable_save_regions()
  local layout = MainMenuLayout.compute(
    globalActions(),
    saves({ "one", "two", "three", "four", "five" }),
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
  local globalY = layout.global.actions["new-game"].y
  local resized = MainMenuLayout.compute(
    globalActions(),
    saves({ "one", "two", "three", "four", "five" }),
    { region = "global", actionId = "new-game" },
    640,
    240,
    layout.saves.offset,
    nil,
    nil,
    false
  )
  Assert.equal(resized.global.actions["new-game"].y, globalY)
  Assert.isTrue(resized.saves.offset >= 0)
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

return { tests = T }
