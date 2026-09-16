-- Product Main Menu state for save catalog publication and semantic input.

local Errors = require("libs.errors.src.Errors")
local GameSave = require("libs.hgss.src.save.GameSave")
local MainMenuController = require("game.hgss.src.menu.MainMenuController")
local MainMenuLayout = require("game.hgss.src.menu.MainMenuLayout")

---@class MainMenuSaveStore
---@field list fun(self: MainMenuSaveStore): table[]
---@field load fun(self: MainMenuSaveStore, saveId: string): table<string, unknown>|nil, Errors.Error?
---@field delete fun(self: MainMenuSaveStore, saveId: string): boolean

---@class MainMenuState
---@field saveStore MainMenuSaveStore
---@field readyVersions table<string, boolean>
---@field onResult fun(result: table<string, unknown>)|nil
---@field width number
---@field height number
---@field renderer table<string, unknown>
---@field globalActions table[]
---@field saves table[]
---@field catalogError string|nil
---@field controller MainMenuController
---@field scrollOffset number
local MainMenuState = {}
MainMenuState.__index = MainMenuState

local NEW_GAME_ID = "new-game"

local function errorSummary(value)
  if Errors.is(value) then
    return value.message
  end
  return tostring(value)
end

local function globalActions()
  return { { id = NEW_GAME_ID, kind = "new_game" } }
end

local function itemId(entry, ordinal)
  if type(entry) == "table" and type(entry.saveId) == "string" and entry.saveId ~= "" then
    return entry.saveId
  end
  return "unavailable-save-" .. ordinal
end

local function validSaveItem(entry, ready, ordinal)
  local saveId = itemId(entry, ordinal)
  if type(entry) ~= "table" or type(entry.saveId) ~= "string" or entry.saveId == "" then
    return {
      id = saveId,
      errorSummary = "Save data unavailable",
      canContinue = false,
      canDelete = false,
    }
  end
  if entry.error then
    return {
      id = saveId,
      saveId = saveId,
      errorSummary = errorSummary(entry.error),
      canContinue = false,
      canDelete = true,
    }
  end

  local playerData = entry.playerData
  local profile = type(playerData) == "table" and playerData.profile
  local playerName = type(profile) == "table" and profile.name
  if type(playerName) ~= "string" or playerName == "" then
    return {
      id = saveId,
      saveId = saveId,
      errorSummary = "Save data unavailable",
      canContinue = false,
      canDelete = true,
    }
  end
  if type(entry.versionId) ~= "string" or entry.versionId == "" or type(entry.playTimeSeconds) ~= "number" then
    return {
      id = saveId,
      saveId = saveId,
      errorSummary = "Save data unavailable",
      canContinue = false,
      canDelete = true,
    }
  end
  if not ready[entry.versionId] then
    return {
      id = saveId,
      saveId = saveId,
      playerName = playerName,
      errorSummary = "Content unavailable",
      canContinue = false,
      canDelete = true,
    }
  end
  return {
    id = saveId,
    saveId = saveId,
    playerName = playerName,
    playTimeLabel = MainMenuState.formatPlayTime(entry.playTimeSeconds),
    canContinue = true,
    canDelete = true,
  }
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

---@param seconds number
---@return string
function MainMenuState.formatPlayTime(seconds)
  assert(type(seconds) == "number" and seconds == math.floor(seconds), "play time must be an integer")
  local capped = math.max(0, math.min(GameSave.MAX_PLAY_TIME_SECONDS, seconds))
  return string.format("%d:%02d", math.floor(capped / 3600), math.floor((capped % 3600) / 60))
end

---@param options table<string, unknown>
---@return MainMenuState
function MainMenuState.new(options)
  assert(type(options) == "table" and options.saveStore, "Main Menu needs the global save store")
  assert(options.renderer, "Main Menu needs its renderer")
  local ready = readySet(options.readyVersions)
  local width, height = options.width, options.height
  if width == nil or height == nil then
    width, height = love.graphics.getDimensions()
  end
  assert(type(width) == "number" and type(height) == "number")
  local self = setmetatable({
    saveStore = options.saveStore,
    readyVersions = ready,
    onResult = options.onResult,
    width = width,
    height = height,
    renderer = options.renderer,
    globalActions = globalActions(),
    saves = {},
    catalogError = nil,
    scrollOffset = 0,
  }, MainMenuState)
  self.controller = MainMenuController.new(self.globalActions, self.saves)
  self:refresh()
  return self
end

function MainMenuState:_readSaves()
  local ok, entriesOrError = pcall(self.saveStore.list, self.saveStore)
  if not ok then
    if Errors.is(entriesOrError) then
      return {}, errorSummary(entriesOrError)
    end
    error(entriesOrError, 0)
  end
  assert(type(entriesOrError) == "table", "save catalog list must return an array")
  local saves = {}
  for ordinal, entry in ipairs(entriesOrError) do
    saves[#saves + 1] = validSaveItem(entry, self.readyVersions, ordinal)
  end
  return saves, nil
end

function MainMenuState:refresh()
  local saves, catalogError = self:_readSaves()
  self.saves = saves
  self.catalogError = catalogError
  self.controller:setCatalog(self.globalActions, saves)
  return true
end

function MainMenuState:_markLoadError(saveId, failure)
  for _, save in ipairs(self.saves) do
    if save.saveId == saveId then
      save.playerName = nil
      save.playTimeLabel = nil
      save.errorSummary = errorSummary(failure)
      save.canContinue = false
      return
    end
  end
end

function MainMenuState:_emit(result)
  if self.onResult then
    self.onResult(result)
  end
end

function MainMenuState:_continue(saveId)
  local save = nil
  for _, candidate in ipairs(self.saves) do
    if candidate.saveId == saveId then
      save = candidate
      break
    end
  end
  if not save or not save.canContinue then
    return
  end
  local ok, recordOrError, loadError = pcall(self.saveStore.load, self.saveStore, saveId)
  if not ok then
    self:_markLoadError(saveId, recordOrError)
    return
  end
  if recordOrError == nil then
    self:_markLoadError(saveId, loadError or "save could not be loaded")
    return
  end
  self:_emit({ kind = "continue", game = recordOrError })
end

function MainMenuState:_delete(saveId)
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

function MainMenuState:_activate()
  local intent = self.controller:activate()
  if not intent then
    return
  end
  if intent.kind == "new_game" then
    self:_emit({ kind = "new_game" })
  elseif intent.kind == "continue" then
    self:_continue(intent.saveId)
  elseif intent.kind == "delete" then
    self:_delete(intent.saveId)
  else
    error("unknown Main Menu intent: " .. tostring(intent.kind), 0)
  end
end

function MainMenuState:_key(key)
  if key == "escape" or key == "b" then
    if not self.controller:back() then
      self:_emit({ kind = "quit" })
    end
    return
  end
  if key == "up" or key == "down" or key == "left" or key == "right" then
    self.controller:move(key)
  elseif key == "return" or key == "kpenter" or key == "space" then
    self:_activate()
  elseif key == "delete" then
    self.controller:requestDelete()
  end
end

function MainMenuState:keypressed(key)
  self:_key(key)
end

function MainMenuState:gamepadpressed(_, button)
  local keys = {
    dpup = "up",
    dpdown = "down",
    dpleft = "left",
    dpright = "right",
  }
  if button == "b" then
    self:_key("b")
  elseif button == "a" then
    self:_activate()
  elseif button == "x" then
    self.controller:requestDelete()
  elseif keys[button] then
    self.controller:move(keys[button])
  end
end

function MainMenuState:_pointer(x, y)
  local layout = self:layout()
  if self.controller.confirmation then
    if layout.confirmation and MainMenuLayout.contains(layout.confirmation.cancel, x, y) then
      self.controller:focusConfirmation("cancel")
      self.controller:back()
    elseif layout.confirmation and MainMenuLayout.contains(layout.confirmation.delete, x, y) then
      self.controller:focusConfirmation("delete")
      self:_activate()
    end
    return
  end
  if self.controller.popup then
    if layout.popup and MainMenuLayout.contains(layout.popup.actions.delete, x, y) then
      self:_activate()
    elseif not layout.popup or not MainMenuLayout.contains(layout.popup.box, x, y) then
      self.controller:back()
    end
    return
  end
  for _, action in ipairs(self.globalActions) do
    local rect = layout.global.actions[action.id]
    if MainMenuLayout.contains(rect, x, y) then
      self.controller:focusGlobal(action.id)
      self:_activate()
      return
    end
  end
  for _, save in ipairs(self.saves) do
    local card = layout.saves.cards[save.saveId or save.id]
    if
      save.saveId
      and card
      and card.overflow
      and MainMenuLayout.contains(layout.saves.viewport, x, y)
      and MainMenuLayout.contains(card.overflow, x, y)
    then
      self.controller:openOverflow(save.saveId)
      return
    end
    if
      save.saveId
      and card
      and MainMenuLayout.contains(layout.saves.viewport, x, y)
      and MainMenuLayout.contains(card.body, x, y)
    then
      self.controller:focusSave(save.saveId, "body")
      self:_activate()
      return
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
---@return table<string, string|nil>
function MainMenuState:hitTest(x, y)
  local layout = self:layout()
  for _, action in ipairs(self.globalActions) do
    if MainMenuLayout.contains(layout.global.actions[action.id], x, y) then
      return { region = "global", actionId = action.id }
    end
  end
  for _, save in ipairs(self.saves) do
    local card = layout.saves.cards[save.saveId or save.id]
    if
      save.saveId
      and card
      and card.overflow
      and MainMenuLayout.contains(layout.saves.viewport, x, y)
      and MainMenuLayout.contains(card.overflow, x, y)
    then
      return { region = "saves", saveId = save.saveId, lane = "overflow" }
    end
    if
      save.saveId
      and card
      and MainMenuLayout.contains(layout.saves.viewport, x, y)
      and MainMenuLayout.contains(card.body, x, y)
    then
      return { region = "saves", saveId = save.saveId, lane = "body" }
    end
  end
  return { region = nil, actionId = nil, saveId = nil, lane = nil }
end

function MainMenuState:wheelmoved(_, y)
  if not self.controller.popup and not self.controller.confirmation then
    self.controller:move(y > 0 and "up" or "down")
  end
end

function MainMenuState:resize(width, height)
  assert(type(width) == "number" and type(height) == "number")
  self.width, self.height = width, height
end

function MainMenuState:layout()
  return MainMenuLayout.compute(
    self.globalActions,
    self.saves,
    self.controller.focus,
    self.width,
    self.height,
    self.scrollOffset,
    self.controller.popup,
    self.controller.confirmation,
    type(self.catalogError) == "string" and self.catalogError ~= ""
  )
end

function MainMenuState:view()
  local layout = self:layout()
  self.scrollOffset = layout.saves.offset
  return {
    kind = "main_menu",
    globalActions = self.globalActions,
    saves = self.saves,
    focusedId = self.controller:focusedId(),
    focus = self.controller:snapshot().focus,
    scroll = { offset = layout.saves.offset },
    layout = layout,
    popup = self.controller.popup,
    confirmation = self.controller.confirmation,
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
