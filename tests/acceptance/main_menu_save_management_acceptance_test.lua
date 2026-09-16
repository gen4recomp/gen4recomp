-- Production-composed Main Menu save-management contracts. The menu state,
-- save catalog, version validation, and derived cache remain real; only the
-- persistent save-root host boundary and result publication are observed.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
local GameSaveValidation = require("game.hgss.src.save.GameSaveValidation")
local MainMenuState = require("game.hgss.src.menu.MainMenuState")
local MainMenuRenderer = require("game.hgss.src.menu.MainMenuRenderer")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local CacheFs = require("libs.storage.src.CacheFs")
local RepoFs = require("game.src.RepoFs")
local SaveFs = require("libs.storage.src.SaveFs")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "product", "menu", "save-management" },
  },
  tests = {},
}

local namespaceSerial = 0
local templateRecord

local function isolatedBackend(namespace)
  local fs = love.filesystem
  local function map(path)
    return namespace .. "/" .. path:gsub("^saves/", "")
  end
  return {
    write = function(_, path, data)
      return fs.write(map(path), data)
    end,
    read = function(_, path)
      return fs.read(map(path))
    end,
    getInfo = function(_, path)
      return fs.getInfo(map(path))
    end,
    createDirectory = function(_, path)
      return fs.createDirectory(map(path))
    end,
    remove = function(_, path)
      return fs.remove(map(path))
    end,
    replace = function(_, sourcePath, destinationPath)
      return os.rename(
        fs.getSaveDirectory() .. "/" .. map(sourcePath),
        fs.getSaveDirectory() .. "/" .. map(destinationPath)
      )
    end,
  }
end

local function removeTree(path)
  local fs = love.filesystem
  local info = fs.getInfo(path)
  if info == nil then
    return
  end
  if info.type == "directory" then
    for _, child in ipairs(fs.getDirectoryItems(path)) do
      removeTree(path .. "/" .. child)
    end
  end
  assert(fs.remove(path), "acceptance cleanup must remove " .. path)
end

local function renderTrap(fn)
  local names = { "newShader", "newCanvas", "newImage", "newMesh", "newQuad", "draw" }
  local originals = {}
  local attempts = 0
  for _, name in ipairs(names) do
    originals[name] = love.graphics[name]
    love.graphics[name] = function()
      attempts = attempts + 1
      error("Main Menu acceptance attempted love.graphics." .. name, 2)
    end
  end
  local ok, result = xpcall(fn, debug.traceback)
  for name, original in pairs(originals) do
    love.graphics[name] = original
  end
  if not ok then
    error(result, 0)
  end
  Assert.equal(attempts, 0, "Main Menu acceptance must stop before GPU rendering")
  return result
end

local function freshRecord(versionId)
  local game = AcceptanceHarness.new():boot({
    versionId = versionId,
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
  })
  local ok, result = xpcall(function()
    game:waitForFieldReady()
    return assert(game.runtime:captureGameSave(), "fresh production runtime must provide a save record")
  end, debug.traceback)
  local closeOk, closeError = pcall(function()
    game:close()
  end)
  if not closeOk then
    error(closeError, 0)
  end
  if not ok then
    error(result, 0)
  end
  return result
end

local function copyRecord(record, saveId, name, playTimeSeconds)
  local copy = {}
  for key, value in pairs(record) do
    copy[key] = value
  end
  copy.saveId = saveId
  copy.playTimeSeconds = playTimeSeconds

  local playerData = {}
  for key, value in pairs(record.playerData) do
    playerData[key] = value
  end
  local profile = {}
  for key, value in pairs(record.playerData.profile) do
    profile[key] = value
  end
  profile.name = name
  playerData.profile = profile
  copy.playerData = playerData
  return copy
end

local function seedRecords(saveFs, count, corruptSave)
  local store = GameSaveStore.new(saveFs)
  local saveIds = {}
  for index = 1, count do
    local saveId = store:reserve()
    saveIds[index] = saveId
    store:publishFirst(copyRecord(templateRecord, saveId, "PLAYER" .. index, index * 60))
  end
  if corruptSave then
    saveFs:write("games/" .. corruptSave .. ".lua", "return { schema = 'not-a-game-save' }")
  end
  return saveIds
end

local function withMenu(count, width, height, options, fn)
  namespaceSerial = namespaceSerial + 1
  local namespace = "acceptance/main-menu/" .. namespaceSerial
  local backend = isolatedBackend(namespace)
  local saveFs = SaveFs.global(backend)
  local saveIds = seedRecords(saveFs, count, options and options.corruptSave)
  local results = {}
  local validation = GameSaveValidation.new({
    overrideFs = RepoFs.new(love.filesystem.getSourceBaseDirectory()),
  })
  local store = GameSaveStore.new(saveFs, {
    recordValidate = function(record)
      return validation:validate(record)
    end,
  })
  local menuText = FieldTextRenderer.new({ cacheFs = CacheFs.forVersion(templateRecord.versionId) })
  local menuRenderer = MainMenuRenderer.new({ text = menuText })
  local menu = MainMenuState.new({
    saveStore = store,
    readyVersions = { templateRecord.versionId },
    onResult = function(result)
      results[#results + 1] = result
    end,
    width = width,
    height = height,
    renderer = menuRenderer,
  })
  local ok, err = xpcall(function()
    renderTrap(function()
      fn(menu, saveIds, results, saveFs)
    end)
  end, debug.traceback)
  local disposeOk, disposeError = pcall(function()
    menu:dispose()
  end)
  removeTree(namespace)
  if not ok then
    error(err, 0)
  end
  if not disposeOk then
    error(disposeError, 0)
  end
end

local function view(menu)
  return assert(menu:view(), "Main Menu must publish a production view")
end

local function center(rect)
  return rect.x + rect.width / 2, rect.y + rect.height / 2
end

local function pressGamepad(menu, button)
  menu:gamepadpressed("acceptance", button)
end

local function assertDeletionSequence(menu, useGamepad)
  local function pressConfirm()
    if useGamepad then
      pressGamepad(menu, "a")
    else
      menu:keypressed("return")
    end
  end
  local function pressCancel()
    if useGamepad then
      pressGamepad(menu, "b")
    else
      menu:keypressed("escape")
    end
  end

  pressConfirm()
  Assert.notNil(view(menu).confirmation, "Delete must open a confirmation modal")
  pressCancel()
  Assert.notNil(view(menu).popup, "cancel must return to the save overflow popup")
  pressConfirm()
  if useGamepad then
    pressGamepad(menu, "dpdown")
    pressGamepad(menu, "a")
  else
    menu:keypressed("down")
    menu:keypressed("return")
  end
end

local function openOverflowByKeyboard(menu)
  menu:keypressed("down")
  local focusedSaveId = view(menu).focusedId
  Assert.isTrue(focusedSaveId ~= "new-game", "overflow setup must focus a save")
  menu:keypressed("right")
  menu:keypressed("return")
  Assert.equal(view(menu).popup.saveId, focusedSaveId, "keyboard overflow must own the focused save")
  return focusedSaveId
end

local function openOverflowByGamepad(menu)
  pressGamepad(menu, "dpdown")
  local focusedSaveId = view(menu).focusedId
  Assert.isTrue(focusedSaveId ~= "new-game", "overflow setup must focus a save")
  pressGamepad(menu, "dpright")
  pressGamepad(menu, "a")
  Assert.equal(view(menu).popup.saveId, focusedSaveId, "gamepad overflow must own the focused save")
  return focusedSaveId
end

function T.tests.zero_and_one_save_boots_choose_the_correct_initial_continue_path()
  local versionId = AcceptanceHarness.defaultVersion()
  if templateRecord == nil then
    templateRecord = freshRecord(versionId)
  end

  withMenu(0, 640, 480, nil, function(menu, _, results)
    Assert.equal(view(menu).focusedId, "new-game")
    menu:keypressed("return")
    Assert.equal(results[1].kind, "new_game", "zero-save confirmation must publish New Game")
  end)

  withMenu(1, 640, 480, nil, function(menu, saveIds, results)
    local initial = view(menu)
    Assert.equal(initial.focusedId, saveIds[1], "an existing save must be the default focus")
    Assert.equal(#initial.saves, 1, "save records must be separate from global actions")
    Assert.equal(#initial.globalActions, 1, "New Game must remain a separate global action")
    menu:keypressed("return")
    Assert.equal(results[1].kind, "continue", "save confirmation must publish Continue")
    Assert.equal(results[1].game.saveId, saveIds[1])
  end)
end

function T.tests.many_saves_scroll_without_moving_the_fixed_new_game_action()
  local versionId = AcceptanceHarness.defaultVersion()
  if templateRecord == nil then
    templateRecord = freshRecord(versionId)
  end

  withMenu(8, 320, 180, nil, function(menu, saveIds)
    for _ = 1, #saveIds - 1 do
      menu:keypressed("down")
    end
    local scrolled = view(menu)
    Assert.equal(scrolled.focusedId, saveIds[1], "down navigation must reach the oldest save")
    local saves = assert(scrolled.layout.saves, "save cards need their own scroll viewport")
    Assert.isTrue(saves.offset > 0, "many saves must scroll their save viewport")
    local focusedCard = assert(saves.cards[saveIds[1]])
    Assert.isTrue(
      focusedCard.body.y >= saves.viewport.y
        and focusedCard.body.y + focusedCard.body.height <= saves.viewport.y + saves.viewport.height,
      "scrolling must keep the focused save card visible"
    )
    local globalAction = assert(scrolled.layout.global.actions["new-game"])
    menu:keypressed("left")
    Assert.equal(view(menu).focusedId, saveIds[1], "Left from a save body must not cross to New Game")
    menu:keypressed("down")
    local globalFocus = view(menu)
    Assert.equal(globalFocus.focusedId, "new-game", "Down from the final save must reach New Game")
    Assert.equal(globalFocus.layout.global.actions["new-game"].y, globalAction.y)
    Assert.equal(globalFocus.layout.global.actions["new-game"].x, globalAction.x)
    menu:keypressed("right")
    Assert.equal(view(menu).focusedId, "new-game", "Right from New Game must not cross to the saves")
    menu:keypressed("up")
    Assert.equal(view(menu).focusedId, saveIds[1], "Up from New Game must return to the final save")
    menu:resize(640, 240)
    menu:keypressed("up")
    Assert.equal(view(menu).focusedId, saveIds[2], "semantic navigation must survive resize")
  end)
end

function T.tests.overflow_delete_confirmation_is_input_independent_and_never_continues()
  local versionId = AcceptanceHarness.defaultVersion()
  if templateRecord == nil then
    templateRecord = freshRecord(versionId)
  end

  withMenu(3, 640, 480, { corruptSave = "save-00000001" }, function(menu, saveIds, results)
    local focusedSaveId = openOverflowByKeyboard(menu)
    Assert.deepEqual(results, {}, "opening overflow must not activate Continue")
    assertDeletionSequence(menu, false)
    local afterDelete = view(menu)
    Assert.isNil(afterDelete.layout.saves.cards[focusedSaveId], "confirmed deletion must remove the save")
    Assert.equal(afterDelete.focusedId, saveIds[1], "deletion must focus the next available save")
    Assert.notNil(afterDelete.layout.saves.cards[saveIds[1]].overflow, "unavailable saves need the same overflow path")
    Assert.notNil(afterDelete.globalActions, "New Game must remain visible after deletion")
  end)

  withMenu(3, 640, 480, { corruptSave = "save-00000001" }, function(menu, saveIds, results)
    local focusedSaveId = openOverflowByGamepad(menu)
    Assert.deepEqual(results, {}, "gamepad overflow must not activate Continue")
    assertDeletionSequence(menu, true)
    local afterDelete = view(menu)
    Assert.isNil(afterDelete.layout.saves.cards[focusedSaveId])
    Assert.equal(afterDelete.focusedId, saveIds[1])
    Assert.notNil(afterDelete.globalActions)
  end)

  withMenu(3, 640, 480, { corruptSave = "save-00000001" }, function(menu, saveIds, results)
    local initial = view(menu)
    local card = assert(initial.layout.saves.cards[saveIds[3]], "pointer run needs the visible save overflow")
    local x, y = center(card.overflow)
    menu:mousepressed(x, y, 1)
    Assert.equal(view(menu).popup.saveId, saveIds[3], "pointer overflow must focus its owning save")
    Assert.deepEqual(results, {}, "pointer overflow must not activate Continue")

    local deleteRect = assert(view(menu).layout.popup.actions.delete)
    x, y = center(deleteRect)
    menu:mousepressed(x, y, 1)
    Assert.notNil(view(menu).confirmation)
    menu:keypressed("escape")
    Assert.notNil(view(menu).popup)
    menu:keypressed("return")
    menu:keypressed("down")
    menu:keypressed("return")
    Assert.isNil(view(menu).layout.saves.cards[saveIds[3]])
  end)
end

function T.tests.keyboard_focused_delete_action_activates_by_pointer_click()
  local versionId = AcceptanceHarness.defaultVersion()
  if templateRecord == nil then
    templateRecord = freshRecord(versionId)
  end

  withMenu(1, 640, 480, nil, function(menu, saveIds, results)
    menu:keypressed("right")
    menu:keypressed("return")
    menu:keypressed("return")
    Assert.equal(view(menu).confirmation.focusedAction, "cancel")
    menu:keypressed("down")
    Assert.equal(view(menu).confirmation.focusedAction, "delete")
    local deleteRect = assert(view(menu).layout.confirmation).delete
    menu:mousepressed(deleteRect.x + deleteRect.width / 2, deleteRect.y + deleteRect.height / 2, 1)
    Assert.deepEqual(results, {}, "pointer confirmation must not publish Continue")
    Assert.isNil(
      view(menu).layout.saves.cards[saveIds[1]],
      "clicking the keyboard-focused Delete action must delete the save"
    )
    Assert.equal(view(menu).focusedId, "new-game")
  end)
end

return T
