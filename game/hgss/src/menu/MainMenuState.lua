-- Product Main Menu state. It owns the save catalog refresh, the pure input
-- controller, the responsive layout, and the renderer, then emits only
-- semantic New Game, Continue, or quit results to HGSS application routing.

local Errors = require("libs.errors.src.Errors")
local GameSave = require("libs.hgss.src.save.GameSave")
local MainMenuController = require("game.hgss.src.menu.MainMenuController")
local MainMenuLayout = require("game.hgss.src.menu.MainMenuLayout")
local MainMenuRenderer = require("game.hgss.src.menu.MainMenuRenderer")

---@class MainMenuSaveStore
---@field listMetadata fun(self: MainMenuSaveStore): table[]
---@field load fun(self: MainMenuSaveStore, saveId: string): table<string, unknown>|nil, Errors.Error?
---@field delete fun(self: MainMenuSaveStore, saveId: string): boolean

---@class MainMenuState
---@field saveStore MainMenuSaveStore application-owned global save catalog and payload store
---@field readyVersions table<string, boolean> versions available for Continue
---@field onResult fun(result: table<string, unknown>)|nil semantic result sink owned by HGSS application routing
---@field width number current viewport width
---@field height number current viewport height
---@field renderer MainMenuRenderer menu renderer owned by this state
---@field items table[] published menu cards, beginning with the New Game sentinel
---@field catalogError string|nil recoverable catalog failure summary
---@field controller MainMenuController pure focus and confirmation state
---@field scrollOffset number computed menu scroll offset
local MainMenuState = {}
MainMenuState.__index = MainMenuState

local NEW_GAME_ID = "new-game"

local function errorSummary(value)
  if Errors.is(value) then
    return value.message
  end
  return tostring(value)
end

local function itemId(item)
  return item.saveId or NEW_GAME_ID
end

local function makeItem(fields)
  fields.id = itemId(fields)
  return fields
end

---@param seconds number
---@return string
function MainMenuState.formatPlayTime(seconds)
  assert(type(seconds) == "number" and seconds == math.floor(seconds), "play time must be an integer")
  local capped = math.max(0, math.min(GameSave.MAX_PLAY_TIME_SECONDS, seconds))
  local hours = math.floor(capped / 3600)
  local minutes = math.floor((capped % 3600) / 60)
  return string.format("%d:%02d", hours, minutes)
end

local function newGameItem()
  return makeItem({ canContinue = true, canDelete = false })
end

local function validSaveItem(entry, ready, ordinal)
  if type(entry) ~= "table" or type(entry.saveId) ~= "string" or entry.saveId == "" then
    return makeItem({
      id = "unavailable-save-" .. ordinal,
      errorSummary = "Save data unavailable",
      canContinue = false,
      canDelete = false,
    })
  end
  if entry.error then
    return makeItem({
      saveId = entry.saveId,
      errorSummary = errorSummary(entry.error),
      canContinue = false,
      canDelete = true,
    })
  end

  local playerData = entry.playerData
  local profile = type(playerData) == "table" and playerData.profile
  local playerName = type(profile) == "table" and profile.name
  if type(playerName) ~= "string" or playerName == "" then
    return makeItem({
      saveId = entry.saveId,
      errorSummary = "Save data unavailable",
      canContinue = false,
      canDelete = true,
    })
  end
  if type(entry.versionId) ~= "string" or entry.versionId == "" or type(entry.playTimeSeconds) ~= "number" then
    return makeItem({
      saveId = entry.saveId,
      errorSummary = "Save data unavailable",
      canContinue = false,
      canDelete = true,
    })
  end
  if not ready[entry.versionId] then
    return makeItem({
      saveId = entry.saveId,
      playerName = playerName,
      errorSummary = "Content unavailable",
      canContinue = false,
      canDelete = true,
    })
  end
  return makeItem({
    saveId = entry.saveId,
    playerName = playerName,
    playTimeLabel = MainMenuState.formatPlayTime(entry.playTimeSeconds),
    canContinue = true,
    canDelete = true,
  })
end

local function readySet(versions)
  assert(type(versions) == "table" and #versions > 0, "Main Menu needs a ready version")
  local result = {}
  for _, versionId in ipairs(versions) do
    assert(type(versionId) == "string" and versionId ~= "", "ready version ids must be non-empty strings")
    result[versionId] = true
  end
  return result
end

---@param options table<string, unknown>
---@return MainMenuState
function MainMenuState.new(options)
  assert(type(options) == "table" and options.saveStore, "Main Menu needs the global save store")
  local ready = readySet(options.readyVersions)
  local width = options.width
  local height = options.height
  if width == nil or height == nil then
    width, height = love.graphics.getDimensions()
  end
  assert(type(width) == "number" and type(height) == "number", "Main Menu needs viewport dimensions")

  local self = setmetatable({
    saveStore = options.saveStore,
    readyVersions = ready,
    onResult = options.onResult,
    width = width,
    height = height,
    renderer = options.renderer or MainMenuRenderer.new(),
    items = { newGameItem() },
    catalogError = nil,
    scrollOffset = 0,
  }, MainMenuState)
  self.controller = MainMenuController.new(self.items)
  self:refresh()
  return self
end

function MainMenuState:_readItems()
  -- Menu cards list validated display envelopes only: no deep validation
  -- and no generated-cache reads, so a cold cache never reads as a corrupt
  -- save. Continue stays an intent; semantic validity is decided later at
  -- field entry.
  local ok, entriesOrError = pcall(self.saveStore.listMetadata, self.saveStore)
  if not ok then
    if Errors.is(entriesOrError) then
      return { newGameItem() }, errorSummary(entriesOrError)
    end
    error(entriesOrError, 0)
  end
  assert(type(entriesOrError) == "table", "save catalog list must return an array")
  local items = { newGameItem() }
  for ordinal, entry in ipairs(entriesOrError) do
    items[#items + 1] = validSaveItem(entry, self.readyVersions, ordinal)
  end
  return items, nil
end

function MainMenuState:refresh()
  local items, catalogError = self:_readItems()
  self.items = items
  self.catalogError = catalogError
  self.controller:setItems(items)
  return true
end

function MainMenuState:_emit(result)
  if self.onResult then
    self.onResult(result)
  end
end

function MainMenuState:_activate()
  local item = self.controller:focusedItem()
  if item.id == NEW_GAME_ID then
    self:_emit({ kind = "new_game" })
    return
  end
  if not item.canContinue then
    return
  end
  -- Continue is an intent carrying the selected save id, not a validity
  -- claim: the owning route validates the record strictly after field core
  -- and location geometry are ready. Nothing loads here.
  self:_emit({ kind = "continue", saveId = assert(item.saveId) })
end

function MainMenuState:_confirmDialog()
  local saveId = self.controller:confirmDelete()
  if not saveId then
    return
  end
  local ok, resultOrError = pcall(self.saveStore.delete, self.saveStore, saveId)
  if not ok then
    local deleteError = errorSummary(resultOrError)
    self:refresh()
    self.catalogError = deleteError
    return
  end
  assert(resultOrError == true or resultOrError == nil, "save deletion must report success")
  self:refresh()
end

function MainMenuState:_key(key)
  if self.controller.dialog then
    if key == "escape" or key == "b" then
      self.controller:cancelDelete()
    elseif key == "up" or key == "down" then
      self.controller:toggleDialogAction()
    elseif key == "return" or key == "kpenter" or key == "space" then
      self:_confirmDialog()
    end
    return
  end
  if key == "up" then
    self.controller:move("up")
  elseif key == "down" then
    self.controller:move("down")
  elseif key == "return" or key == "kpenter" or key == "space" then
    self:_activate()
  elseif key == "delete" then
    self.controller:requestDelete()
  elseif key == "escape" then
    self:_emit({ kind = "quit" })
  end
end

function MainMenuState:keypressed(key)
  self:_key(key)
end

function MainMenuState:gamepadpressed(_, button)
  if self.controller.dialog then
    if button == "b" then
      self.controller:cancelDelete()
    elseif button == "dpup" or button == "dpdown" then
      self.controller:toggleDialogAction()
    elseif button == "a" then
      self:_confirmDialog()
    end
    return
  end
  if button == "dpup" then
    self.controller:move("up")
  elseif button == "dpdown" then
    self.controller:move("down")
  elseif button == "a" then
    self:_activate()
  elseif button == "x" then
    self.controller:requestDelete()
  end
end

function MainMenuState:_pointer(x, y)
  if self.controller.dialog then
    local dialog = self:layout().dialog
    if MainMenuLayout.contains(dialog.cancel, x, y) then
      self.controller:cancelDelete()
    elseif MainMenuLayout.contains(dialog.delete, x, y) then
      self.controller:chooseDialogAction("delete")
      self:_confirmDialog()
    end
    return
  end
  local layout = self:layout()
  if not MainMenuLayout.contains(layout.content, x, y) then
    return
  end
  for _, item in ipairs(self.items) do
    local card = layout.cards[item.id]
    if card then
      if card.delete and MainMenuLayout.contains(card.delete, x, y) then
        self.controller:setFocusedId(item.id)
        self.controller:requestDelete()
        return
      end
      if MainMenuLayout.contains(card.body, x, y) then
        self.controller:setFocusedId(item.id)
        self:_activate()
        return
      end
    end
  end
end

function MainMenuState:mousepressed(x, y, button)
  if button == 1 then
    self:_pointer(x, y)
  end
end

function MainMenuState:touchpressed(_, x, y)
  self:_pointer(x, y)
end

---@param x number
---@param y number
---@return { primary: string|nil, delete: string|nil }
function MainMenuState:hitTest(x, y)
  local layout = self:layout()
  if not MainMenuLayout.contains(layout.content, x, y) then
    return { primary = nil, delete = nil }
  end
  for _, item in ipairs(self.items) do
    local card = layout.cards[item.id]
    if card then
      if card.delete and MainMenuLayout.contains(card.delete, x, y) then
        return { primary = nil, delete = item.saveId }
      end
      if MainMenuLayout.contains(card.body, x, y) then
        return { primary = item.id, delete = nil }
      end
    end
  end
  return { primary = nil, delete = nil }
end

function MainMenuState:wheelmoved(_, y)
  if self.controller.dialog then
    return
  end
  if y > 0 then
    self.controller:move("up")
  elseif y < 0 then
    self.controller:move("down")
  end
end

function MainMenuState:resize(width, height)
  assert(type(width) == "number" and type(height) == "number", "Main Menu resize needs dimensions")
  self.width, self.height = width, height
end

function MainMenuState:layout()
  return MainMenuLayout.compute(
    self.items,
    self.controller.focusIndex,
    self.width,
    self.height,
    self.scrollOffset,
    self.controller.dialog,
    type(self.catalogError) == "string" and self.catalogError ~= ""
  )
end

function MainMenuState:view()
  local layout = self:layout()
  self.scrollOffset = layout.offset
  return {
    kind = "main_menu",
    items = self.items,
    focusedId = self.controller:focusedId(),
    scroll = { offset = layout.offset },
    layout = layout,
    dialog = self.controller.dialog,
    catalogError = self.catalogError,
  }
end

function MainMenuState:draw()
  self.renderer:draw(self:view())
end

function MainMenuState:update() end

function MainMenuState:dispose()
  if self.renderer and self.renderer.dispose then
    self.renderer:dispose()
  end
  self.renderer = nil
end

return MainMenuState
