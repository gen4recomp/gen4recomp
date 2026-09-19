-- Pure Main Menu interaction state for global actions, save lanes, and modals.

---@class MainMenuGlobalFocus
---@field region "global"
---@field actionId string
---@class MainMenuSaveFocus
---@field region "saves"
---@field saveId string
---@field lane "body"|"overflow"
---@alias MainMenuFocus MainMenuGlobalFocus|MainMenuSaveFocus

---@class MainMenuController
---@field globalActions table[]
---@field saves table[]
---@field focus MainMenuFocus
---@field popup table<string, string>?
---@field confirmation table<string, string>?
---@field rememberedSaveId string?
---@field rememberedLane "body"|"overflow"?
local MainMenuController = {}
MainMenuController.__index = MainMenuController

local function copy(value)
  if value == nil then
    return nil
  end
  local result = {}
  for key, entry in pairs(value) do
    result[key] = entry
  end
  return result
end

local function indexOf(items, id)
  for index, item in ipairs(items) do
    if item.id == id or item.saveId == id then
      return index
    end
  end
  return nil
end

local function itemAt(items, id)
  local index = indexOf(items, id)
  return index and items[index] or nil
end

local function canDelete(item)
  return item ~= nil and item.canDelete == true and item.saveId ~= nil
end

local function focusForSave(saveId, lane)
  assert(lane == "body" or lane == "overflow", "unknown Main Menu save lane")
  return { region = "saves", saveId = saveId, lane = lane }
end

local function firstSave(saves)
  local save = saves[1]
  return save and focusForSave(save.saveId or save.id, "body") or { region = "global", actionId = "new-game" }
end

---@param globalActions table[]
---@param saves table[]
---@return MainMenuController
function MainMenuController.new(globalActions, saves)
  assert(type(globalActions) == "table" and #globalActions > 0, "the Main Menu needs a global action")
  assert(type(saves) == "table", "Main Menu saves must be an array")
  local self = setmetatable({ globalActions = globalActions, saves = saves }, MainMenuController)
  self.focus = firstSave(saves)
  self.rememberedSaveId = self.focus.region == "saves" and self.focus.saveId or nil
  self.rememberedLane = self.focus.region == "saves" and self.focus.lane or nil
  self.popup = nil
  self.confirmation = nil
  return self
end

function MainMenuController:snapshot()
  return { focus = copy(self.focus), popup = copy(self.popup), confirmation = copy(self.confirmation) }
end

function MainMenuController:focusedId()
  return self.focus.region == "global" and self.focus.actionId or self.focus.saveId
end

function MainMenuController:focusedItem()
  if self.focus.region == "global" then
    return assert(itemAt(self.globalActions, self.focus.actionId))
  end
  return assert(itemAt(self.saves, self.focus.saveId))
end

function MainMenuController:focusSave(saveId, lane)
  assert(itemAt(self.saves, saveId), "cannot focus an unknown Main Menu save")
  self.focus = focusForSave(saveId, lane)
  self.rememberedSaveId = saveId
  self.rememberedLane = lane
  self.popup = nil
  self.confirmation = nil
end

function MainMenuController:focusGlobal(actionId)
  assert(itemAt(self.globalActions, actionId), "cannot focus an unknown Main Menu action")
  self.focus = { region = "global", actionId = actionId }
  self.popup = nil
  self.confirmation = nil
end

---@param globalActions table[]
---@param saves table[]
function MainMenuController:setCatalog(globalActions, saves)
  assert(type(globalActions) == "table" and #globalActions > 0, "the Main Menu needs a global action")
  assert(type(saves) == "table", "Main Menu saves must be an array")
  local oldFocus = self.focus
  local hadSaves = #self.saves > 0
  local oldSaveIndex = oldFocus.region == "saves" and indexOf(self.saves, oldFocus.saveId) or nil
  self.globalActions, self.saves = globalActions, saves
  self.popup, self.confirmation = nil, nil

  if oldFocus.region == "global" and not hadSaves and #saves > 0 then
    self.focus = firstSave(saves)
  elseif oldFocus.region == "global" and itemAt(globalActions, oldFocus.actionId) then
    self.focus = { region = "global", actionId = oldFocus.actionId }
  elseif oldFocus.region == "saves" and itemAt(saves, oldFocus.saveId) then
    local kept = assert(itemAt(saves, oldFocus.saveId))
    local lane = oldFocus.lane
    if lane == "overflow" and not canDelete(kept) then
      lane = "body"
    end
    self.focus = focusForSave(oldFocus.saveId, lane)
  elseif #saves > 0 then
    local replacementIndex = math.min(oldSaveIndex or 1, #saves)
    local replacement = assert(saves[replacementIndex])
    local lane = oldFocus.region == "saves" and oldFocus.lane or "body"
    if lane == "overflow" and not canDelete(replacement) then
      lane = "body"
    end
    self.focus = focusForSave(replacement.saveId or replacement.id, lane)
  else
    self.focus = { region = "global", actionId = assert(globalActions[1]).id }
  end
  local remembered = self.rememberedSaveId and itemAt(saves, self.rememberedSaveId) or nil
  if remembered then
    self.rememberedSaveId = remembered.saveId or remembered.id
  elseif self.focus.region == "saves" then
    self.rememberedSaveId = self.focus.saveId
  elseif #saves > 0 then
    local first = assert(saves[1])
    self.rememberedSaveId = first.saveId or first.id
  else
    self.rememberedSaveId = nil
  end
end

local function adjacentSave(saves, saveId, delta)
  local index = indexOf(saves, saveId)
  if not index then
    return nil
  end
  local nextIndex = index + delta
  if nextIndex < 1 or nextIndex > #saves then
    return nil
  end
  local save = saves[nextIndex]
  return save and (save.saveId or save.id) or nil
end

function MainMenuController:move(direction)
  assert(direction == "up" or direction == "down" or direction == "left" or direction == "right")
  if self.confirmation then
    if direction == "up" or direction == "down" then
      self.confirmation.focusedAction = self.confirmation.focusedAction == "cancel" and "delete" or "cancel"
    end
    return
  end
  if self.popup then
    return
  end
  if self.focus.region == "global" then
    if direction == "right" and #self.saves > 0 then
      local remembered = self.rememberedSaveId and itemAt(self.saves, self.rememberedSaveId) or nil
      local target = remembered or assert(self.saves[1])
      local lane = "body"
      if self.rememberedLane == "overflow" and canDelete(target) then
        lane = "overflow"
      end
      self:focusSave(target.saveId or target.id, lane)
    end
    return
  end
  if self.focus.lane == "body" then
    if direction == "left" then
      self:focusGlobal(self.globalActions[1].id)
    elseif direction == "right" and canDelete(self:focusedItem()) then
      self:focusSave(self.focus.saveId, "overflow")
    elseif direction == "up" or direction == "down" then
      local delta = direction == "up" and -1 or 1
      local saveId = adjacentSave(self.saves, self.focus.saveId, delta)
      if saveId then
        self:focusSave(saveId, "body")
      else
        self:focusGlobal(self.globalActions[1].id)
      end
    end
  elseif self.focus.lane == "overflow" then
    if direction == "left" then
      self:focusSave(self.focus.saveId, "body")
    elseif direction == "up" or direction == "down" then
      local delta = direction == "up" and -1 or 1
      local saveId = adjacentSave(self.saves, self.focus.saveId, delta)
      if saveId then
        local adjacent = itemAt(self.saves, saveId)
        self:focusSave(saveId, canDelete(adjacent) and "overflow" or "body")
      else
        self:focusGlobal(self.globalActions[1].id)
      end
    end
  end
end

function MainMenuController:focusConfirmation(action)
  assert(action == "cancel" or action == "delete", "unknown Main Menu confirmation action")
  if not self.confirmation then
    return false
  end
  self.confirmation.focusedAction = action
  return true
end

function MainMenuController:openOverflow(saveId)
  if not canDelete(itemAt(self.saves, saveId)) then
    return false
  end
  self:focusSave(saveId, "overflow")
  self.popup = { saveId = saveId, focusedAction = "delete" }
  return true
end

function MainMenuController:closePopup()
  if self.popup then
    local saveId = self.popup.saveId
    self.popup = nil
    self.confirmation = nil
    if itemAt(self.saves, saveId) then
      self.focus = focusForSave(saveId, "overflow")
    end
  end
end

function MainMenuController:requestDelete()
  if self.focus.region == "saves" then
    return self:openOverflow(self.focus.saveId)
  end
  return false
end

function MainMenuController:activate()
  if self.confirmation then
    if self.confirmation.focusedAction == "delete" then
      local saveId = self.confirmation.saveId
      self.confirmation, self.popup = nil, nil
      return { kind = "delete", saveId = saveId }
    end
    self.confirmation = nil
    return nil
  end
  if self.popup then
    self.confirmation = { saveId = self.popup.saveId, focusedAction = "cancel" }
    return nil
  end
  if self.focus.region == "global" then
    return { kind = "new_game" }
  end
  if self.focus.lane == "overflow" then
    if canDelete(self:focusedItem()) then
      self.popup = { saveId = self.focus.saveId, focusedAction = "delete" }
      return nil
    end
    self.focus = focusForSave(self.focus.saveId, "body")
    return { kind = "continue", saveId = self.focus.saveId }
  end
  return { kind = "continue", saveId = self.focus.saveId }
end

function MainMenuController:back()
  if self.confirmation then
    self.confirmation = nil
    return true
  end
  if self.popup then
    self:closePopup()
    return true
  end
  return false
end

return MainMenuController
