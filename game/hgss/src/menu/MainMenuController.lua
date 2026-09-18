-- Pure Main Menu interaction state for global actions, save lanes, and modals.

local FocusGraph = require("libs.ui.src.FocusGraph")

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
    if self.rememberedLane == "overflow" and not canDelete(remembered) then
      self.rememberedLane = "body"
    end
  elseif self.focus.region == "saves" then
    self.rememberedSaveId = self.focus.saveId
    self.rememberedLane = self.focus.lane
  elseif #saves > 0 then
    local first = assert(saves[1])
    self.rememberedSaveId = first.saveId or first.id
    self.rememberedLane = "body"
  else
    self.rememberedSaveId = nil
    self.rememberedLane = nil
  end
end

local GLOBAL_NODE = "global"

local function bodyNode(index)
  return "save:" .. index .. ":body"
end

local function overflowNode(index)
  return "save:" .. index .. ":overflow"
end

-- Builds an ephemeral ordered-candidate graph over the current catalog. Node
-- ids are save-index based so arbitrary save ids never need string parsing;
-- callers translate the resolved node back to the public focus structs.
---@class MainMenuFocusTargetGlobal
---@field kind "global"
---@class MainMenuFocusTargetSave
---@field kind "save"
---@field index integer
---@field lane "body"|"overflow"
---@alias MainMenuFocusTarget MainMenuFocusTargetGlobal|MainMenuFocusTargetSave

---@param saves table[]
---@param rememberedSaveId string?
---@param rememberedLane ("body"|"overflow")?
---@return table<string, table<string, string[]>> graph, table<string, MainMenuFocusTarget> targets
local function buildFocusGraph(saves, rememberedSaveId, rememberedLane)
  local graph = {}
  local targets = {}
  local count = #saves
  if count == 0 then
    graph[GLOBAL_NODE] = { up = {}, down = {}, left = {}, right = {} }
    targets[GLOBAL_NODE] = { kind = "global" }
    return graph, targets
  end
  graph[GLOBAL_NODE] = { up = { bodyNode(count) }, down = { bodyNode(1) }, left = {}, right = {} }
  targets[GLOBAL_NODE] = { kind = "global" }
  for index, item in ipairs(saves) do
    local body = bodyNode(index)
    local overflow = overflowNode(index)
    local hasOverflow = canDelete(item)
    graph[body] = {
      up = { index == 1 and GLOBAL_NODE or bodyNode(index - 1) },
      down = { index == count and GLOBAL_NODE or bodyNode(index + 1) },
      left = { GLOBAL_NODE },
      right = hasOverflow and { overflow } or {},
    }
    targets[body] = { kind = "save", index = index, lane = "body" }
    if hasOverflow then
      local upCandidates
      if index == 1 then
        upCandidates = { GLOBAL_NODE }
      elseif canDelete(saves[index - 1]) then
        upCandidates = { overflowNode(index - 1), bodyNode(index - 1) }
      else
        upCandidates = { bodyNode(index - 1) }
      end
      local downCandidates
      if index == count then
        downCandidates = { GLOBAL_NODE }
      elseif canDelete(saves[index + 1]) then
        downCandidates = { overflowNode(index + 1), bodyNode(index + 1) }
      else
        downCandidates = { bodyNode(index + 1) }
      end
      graph[overflow] = { up = upCandidates, down = downCandidates, left = { body }, right = {} }
      targets[overflow] = { kind = "save", index = index, lane = "overflow" }
    end
  end
  local rememberedIndex = rememberedSaveId and indexOf(saves, rememberedSaveId) or nil
  if rememberedIndex ~= nil then
    local remembered = assert(saves[rememberedIndex])
    if rememberedLane == "overflow" and canDelete(remembered) then
      graph[GLOBAL_NODE].right = { overflowNode(rememberedIndex), bodyNode(1) }
    else
      graph[GLOBAL_NODE].right = { bodyNode(rememberedIndex), bodyNode(1) }
    end
  else
    graph[GLOBAL_NODE].right = { bodyNode(1) }
  end
  return graph, targets
end

function MainMenuController:move(direction)
  assert(direction == "up" or direction == "down" or direction == "left" or direction == "right")
  if self.confirmation then
    if direction == "left" or direction == "right" then
      self.confirmation.focusedAction = self.confirmation.focusedAction == "cancel" and "delete" or "cancel"
    end
    return
  end
  if self.popup then
    return
  end
  local graph, targets = buildFocusGraph(self.saves, self.rememberedSaveId, self.rememberedLane)
  local current
  if self.focus.region == "global" then
    current = GLOBAL_NODE
  else
    local index = assert(indexOf(self.saves, self.focus.saveId), "Main Menu focus references an unknown save")
    if self.focus.lane == "overflow" and graph[overflowNode(index)] ~= nil then
      current = overflowNode(index)
    else
      current = bodyNode(index)
    end
  end
  local resolved = FocusGraph.move(graph, current, direction)
  local target = assert(targets[resolved], "the focus resolver returned an unknown node")
  if target.kind == "global" then
    self:focusGlobal(self.globalActions[1].id)
  else
    local item = assert(self.saves[target.index], "the focus resolver returned an unknown save")
    self:focusSave(item.saveId or item.id, target.lane)
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
