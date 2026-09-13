-- Lower-layer contracts for the product Main Menu's pure formatting, focus,
-- layout, and catalog-error behavior.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local MainMenuController = require("game.hgss.src.menu.MainMenuController")
local MainMenuLayout = require("game.hgss.src.menu.MainMenuLayout")
local MainMenuState = require("game.hgss.src.menu.MainMenuState")

local T = {}

local function item(id, canContinue)
  return {
    id = id,
    saveId = id == "new-game" and nil or id,
    playerName = id,
    playTimeLabel = "0:00",
    canContinue = canContinue,
    canDelete = id ~= "new-game",
  }
end

local function items(ids)
  local result = {}
  for _, id in ipairs(ids) do
    result[#result + 1] = item(id, true)
  end
  return result
end

function T.formats_capped_play_time_as_hours_and_minutes()
  Assert.equal(MainMenuState.formatPlayTime(0), "0:00")
  Assert.equal(MainMenuState.formatPlayTime(59 * 60 + 59), "0:59")
  Assert.equal(MainMenuState.formatPlayTime(60 * 60), "1:00")
  Assert.equal(MainMenuState.formatPlayTime(999 * 60 * 60 + 59 * 60 + 59), "999:59")
end

function T.delete_focus_uses_the_replacement_item_at_each_boundary()
  local cases = {
    { target = "one", expected = "two", ids = { "new-game", "one", "two" } },
    {
      target = "two",
      expected = "three",
      ids = { "new-game", "one", "two", "three" },
    },
    {
      target = "three",
      expected = "two",
      ids = { "new-game", "one", "two", "three" },
    },
  }
  for _, case in ipairs(cases) do
    local controller = MainMenuController.new(items(case.ids))
    controller:setFocusedId(case.target)
    Assert.isTrue(controller:requestDelete())
    controller:chooseDialogAction("delete")
    Assert.equal(controller:confirmDelete(), case.target)
    controller:setItems({ item("new-game", true), item("one", true), item("two", true), item("three", true) })
    local remaining = {}
    for _, candidate in ipairs(controller.items) do
      if candidate.id ~= case.target then
        remaining[#remaining + 1] = candidate
      end
    end
    controller:setItems(remaining)
    Assert.equal(controller:focusedId(), case.expected)
  end

  local only = MainMenuController.new(items({ "new-game", "only" }))
  only:setFocusedId("only")
  Assert.isTrue(only:requestDelete())
  only:chooseDialogAction("delete")
  Assert.equal(only:confirmDelete(), "only")
  only:setItems({ item("new-game", true) })
  Assert.equal(only:focusedId(), "new-game")
end

function T.layout_keeps_card_body_and_delete_hit_regions_exclusive()
  local layoutItems = { item("new-game", true), item("save-1", true) }
  local layout = MainMenuLayout.compute(layoutItems, 2, 240, 160, 0, nil)
  local card = layout.cards["save-1"]
  Assert.isTrue(card.body.width > 0 and card.delete.width > 0)
  Assert.isTrue(MainMenuLayout.contains(card.body, card.body.x + 1, card.body.y + 1))
  Assert.isTrue(MainMenuLayout.contains(card.delete, card.delete.x + 1, card.delete.y + 1))
  Assert.isFalse(MainMenuLayout.contains(card.body, card.delete.x + 1, card.delete.y + 1))
end

function T.layout_clamps_previous_offset_after_resize()
  local menuItems = items({
    "new-game",
    "save-1",
    "save-2",
    "save-3",
    "save-4",
    "save-5",
    "save-6",
    "save-7",
    "save-8",
  })
  local narrow = MainMenuLayout.compute(menuItems, 9, 320, 180, 0, nil)
  local layout = MainMenuLayout.compute(menuItems, 9, 320, 400, narrow.offset, nil)

  Assert.equal(layout.offset, 124)
end

function T.content_hit_testing_uses_half_open_boundaries()
  local content = { x = 16, y = 48, width = 128, height = 64 }
  Assert.isTrue(MainMenuLayout.contains(content, 16, 48))
  Assert.isTrue(MainMenuLayout.contains(content, 143, 111))
  Assert.isFalse(MainMenuLayout.contains(content, 144, 111))
  Assert.isFalse(MainMenuLayout.contains(content, 143, 112))
end

function T.layout_caps_and_centers_content_with_floor_rounding()
  local menuItems = { item("new-game", true) }
  local atCap = MainMenuLayout.compute(menuItems, 1, 992, 480, 0, nil, false)
  local evenWide = MainMenuLayout.compute(menuItems, 1, 1600, 480, 0, nil, false)
  local oddWide = MainMenuLayout.compute(menuItems, 1, 1601, 480, 0, nil, false)

  Assert.equal(atCap.content.width, 960)
  Assert.equal(atCap.content.x, 16)
  Assert.equal(evenWide.content.width, 960)
  Assert.equal(evenWide.content.x, 320)
  Assert.equal(oddWide.content.width, 960)
  Assert.equal(oddWide.content.x, 320)
end

function T.layout_places_catalog_error_inside_content_and_shifts_cards()
  local menuItems = { item("new-game", true), item("save-1", true) }
  local withoutError = MainMenuLayout.compute(menuItems, 1, 640, 480, 0, nil, false)
  local withError = MainMenuLayout.compute(menuItems, 1, 640, 480, 0, nil, true)
  local errorRect = assert(withError.catalogErrorRect)

  Assert.isNil(withoutError.catalogErrorRect)
  Assert.equal(withError.cards["new-game"].body.y, withoutError.cards["new-game"].body.y + 32)
  Assert.equal(withError.cards["save-1"].body.y, withoutError.cards["save-1"].body.y + 32)
  Assert.equal(errorRect.x, withError.content.x)
  Assert.equal(errorRect.y, withError.content.y)
  Assert.equal(errorRect.width, withError.content.width)
  Assert.equal(errorRect.height, 24)
  Assert.equal(withError.totalContentHeight, withError.totalCardsHeight + 32)
end

function T.long_menu_keeps_the_last_focused_card_inside_the_content_viewport()
  local entries = {}
  for index = 1, 8 do
    entries[#entries + 1] = {
      saveId = string.format("save-%08d", index),
      versionId = "heartgold",
      playerData = { profile = { name = "P" .. index } },
      playTimeSeconds = index * 60,
    }
  end
  local menu = MainMenuState.new({
    saveStore = {
      listMetadata = function()
        return entries
      end,
    },
    readyVersions = { "heartgold" },
    width = 320,
    height = 180,
  })

  for _ = 1, 40 do
    menu:keypressed("down")
  end

  local view = menu:view()
  local content = assert(view.layout.content)
  local card = assert(view.layout.cards["save-00000008"])
  Assert.equal(view.focusedId, "save-00000008")
  Assert.isTrue(view.layout.offset > 0)
  Assert.isTrue(card.body.y >= content.y)
  Assert.isTrue(card.body.y + card.body.height <= content.y + content.height)
end

function T.pointer_outside_the_content_viewport_does_not_activate_a_clipped_card()
  local results = {}
  local menu = MainMenuState.new({
    saveStore = {
      listMetadata = function()
        return {}
      end,
    },
    readyVersions = { "heartgold" },
    onResult = function(result)
      results[#results + 1] = result
    end,
    width = 320,
    height = 80,
  })
  local view = menu:view()
  local content = assert(view.layout.content)
  local card = assert(view.layout.cards["new-game"])
  Assert.isTrue(card.body.y < card.body.y + card.body.height)
  Assert.isTrue(card.body.y + card.body.height > content.y + content.height)

  menu:mousepressed(card.body.x + 1, content.y + content.height, 1)
  menu:touchpressed("finger-1", card.body.x + 1, content.y + content.height)

  Assert.deepEqual(menu:hitTest(card.body.x + 1, content.y + content.height), { primary = nil, delete = nil })
  Assert.deepEqual(results, {})
  Assert.equal(menu:view().focusedId, "new-game")
end

function T.refresh_preserves_focus_by_stable_save_identity()
  local controller = MainMenuController.new({ item("new-game", true), item("one", true), item("two", true) })
  controller:setFocusedId("two")
  controller:setItems({ item("new-game", true), item("one", true), item("two", true), item("three", true) })
  Assert.equal(controller:focusedId(), "two")
  controller:setItems({ item("new-game", true), item("one", true), item("three", true) })
  Assert.equal(controller:focusedId(), "three")
end

function T.catalog_error_is_not_represented_as_an_empty_catalog()
  local catalogError = Errors.new("GAME_SAVE_CATALOG_INVALID", "catalog unreadable")
  local store = {
    listMetadata = function()
      error(catalogError)
    end,
  }
  local menu = MainMenuState.new({ saveStore = store, readyVersions = { "heartgold" }, width = 640, height = 480 })
  local view = menu:view()
  Assert.notNil(view.catalogError)
  Assert.equal(#view.items, 1)
  Assert.equal(view.items[1].id, "new-game")
end

function T.failed_delete_preserves_its_error_after_catalog_refresh()
  local deleteFailure = Errors.new("GAME_SAVE_DELETE_FAILED", "save could not be deleted")
  local entries = {
    {
      saveId = "save-00000001",
      versionId = "heartgold",
      playerData = { profile = { name = "PLAYER" } },
      playTimeSeconds = 60,
    },
  }
  local calls = { listMetadata = 0, delete = 0 }
  local store = {}
  function store:listMetadata()
    calls.listMetadata = calls.listMetadata + 1
    return entries
  end
  function store:delete(saveId)
    Assert.equal(saveId, "save-00000001")
    calls.delete = calls.delete + 1
    error(deleteFailure)
  end

  local menu = MainMenuState.new({
    saveStore = store,
    readyVersions = { "heartgold" },
    width = 640,
    height = 480,
  })
  menu:keypressed("down")
  menu:keypressed("delete")
  menu:keypressed("down")
  menu:keypressed("return")

  local failed = menu:view()
  Assert.equal(calls.listMetadata, 2)
  Assert.equal(calls.delete, 1)
  Assert.isNil(failed.dialog)
  Assert.equal(failed.focusedId, "save-00000001")
  Assert.equal(failed.items[2].saveId, "save-00000001")
  Assert.equal(failed.catalogError, "save could not be deleted")

  menu:refresh()
  Assert.isNil(menu:view().catalogError)
end

function T.successful_delete_refreshes_the_catalog_without_an_error()
  local entries = {
    {
      saveId = "save-00000001",
      versionId = "heartgold",
      playerData = { profile = { name = "PLAYER" } },
      playTimeSeconds = 60,
    },
  }
  local calls = { listMetadata = 0, delete = 0 }
  local store = {}
  function store:listMetadata()
    calls.listMetadata = calls.listMetadata + 1
    return entries
  end
  function store:delete(saveId)
    Assert.equal(saveId, "save-00000001")
    calls.delete = calls.delete + 1
    entries = {}
    return true
  end

  local menu = MainMenuState.new({
    saveStore = store,
    readyVersions = { "heartgold" },
    width = 640,
    height = 480,
  })
  menu:keypressed("down")
  menu:keypressed("delete")
  menu:keypressed("down")
  menu:keypressed("return")

  local deleted = menu:view()
  Assert.equal(calls.listMetadata, 2)
  Assert.equal(calls.delete, 1)
  Assert.isNil(deleted.catalogError)
  Assert.equal(#deleted.items, 1)
  Assert.equal(deleted.items[1].id, "new-game")
  Assert.equal(deleted.focusedId, "new-game")
end

function T.malformed_save_metadata_is_an_unavailable_deletable_card()
  local menu = MainMenuState.new({
    saveStore = {
      listMetadata = function()
        return { { saveId = "save-00000001", playerData = {} } }
      end,
    },
    readyVersions = { "heartgold" },
    width = 640,
    height = 480,
  })
  local card = menu:view().items[2]
  Assert.equal(card.id, "save-00000001")
  Assert.isFalse(card.canContinue)
  Assert.isTrue(card.canDelete)
  Assert.notNil(card.errorSummary)
end

function T.continue_emits_the_selected_save_intent_without_loading()
  local listed = {
    saveId = "save-00000001",
    versionId = "heartgold",
    playerData = { profile = { name = "GOLD" } },
    playTimeSeconds = 0,
  }
  local results = {}
  local menu = MainMenuState.new({
    saveStore = {
      listMetadata = function()
        return { listed }
      end,
      load = function()
        error("Continue must not load before preparation", 0)
      end,
    },
    readyVersions = { "heartgold" },
    onResult = function(result)
      results[#results + 1] = result
    end,
    width = 640,
    height = 480,
  })
  menu:keypressed("down")
  menu:keypressed("return")
  Assert.deepEqual(results, { { kind = "continue", saveId = "save-00000001" } })
end

return { tests = T }
