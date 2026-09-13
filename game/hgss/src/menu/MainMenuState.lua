-- Product Main Menu state for save catalog publication and semantic input.
-- The startup menu owns its presentation session beside its existing
-- controller: every pointer dispatch resolves a complete plan against
-- fresh display facts, maps one ordered batch, advances through the
-- existing controller pathways once, then resolves again for the
-- resulting snapshot. Scroll offsets stay logical across resizes;
-- keyboard, gamepad and wheel keep their direct controller paths.

local ApplicationPresentation = require("game.hgss.src.ui.ApplicationPresentation")
local DisplayContext = require("game.hgss.src.ui.DisplayContext")
local Errors = require("libs.errors.src.Errors")
local HgssInputBindings = require("game.hgss.src.HgssInputBindings")
local GameSave = require("libs.hgss.src.save.GameSave")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local MainMenuController = require("game.hgss.src.menu.MainMenuController")
local MainMenuInterface = require("game.hgss.src.menu.MainMenuInterface")
local MainMenuLayout = require("game.hgss.src.menu.MainMenuLayout")

---@class MainMenuSaveStore
---@field listMetadata fun(self: MainMenuSaveStore): table[]
---@field delete fun(self: MainMenuSaveStore, saveId: string): boolean

---@class MainMenuState
---@field saveStore MainMenuSaveStore
---@field readyVersions table<string, boolean>
---@field onResult fun(result: table<string, unknown>)|nil
---@field width number host drawable width behind the current measurement
---@field height number host drawable height behind the current measurement
---@field renderer table<string, unknown>
---@field globalActions table[]
---@field saves table[]
---@field catalogError string|nil
---@field controller MainMenuController
---@field scrollOffset number logical scroll offset retained across layouts
---@field _measurement DisplayMeasurement|nil fixed facts for direct unit invocation
---@field _displayContext DisplayContext|nil shared actual-display owner from the product route
---@field _session ApplicationPresentation|nil the per-open presentation session
---@field _disposed boolean
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
    _disposed = false,
  }, MainMenuState)
  if options.displayMeasurement ~= nil then
    self._measurement = options.displayMeasurement --[[@as DisplayMeasurement]]
  else
    local displayContext = options.displayContext --[[@as DisplayContext|nil]]
    if displayContext == nil then
      displayContext = DisplayContext.new({})
    end
    self._displayContext = displayContext
  end
  self.controller = MainMenuController.new(self.globalActions, self.saves)
  self:refresh()
  local overrides = options.overrides --[[@as table<string, unknown>|nil]]
  local session
  local built, buildErr = pcall(function()
    session = ApplicationPresentation.new(MainMenuInterface.withOverrides(overrides))
  end)
  if not built then
    error(buildErr, 0)
  end
  self._session = assert(session, "Main Menu needs its presentation session")
  local resolveOk, resolveErr = pcall(function()
    self:_resolve(self:_snapshot())
  end)
  if not resolveOk then
    self._session:dispose()
    error(resolveErr, 0)
  end
  return self
end

---@return table<string, unknown> the controller snapshot resolvers and renderers consume
function MainMenuState:_snapshot()
  return {
    kind = "main_menu",
    globalActions = self.globalActions,
    saves = self.saves,
    focus = self.controller:snapshot().focus,
    popup = self.controller.popup,
    confirmation = self.controller.confirmation,
    catalogError = self.catalogError,
    scrollOffset = self.scrollOffset,
  }
end

---@return DisplayMeasurement|nil the current display facts
function MainMenuState:_measured()
  if self._measurement ~= nil then
    return self._measurement
  end
  local displayContext = assert(self._displayContext, "Main Menu needs its display facts")
  return displayContext:measure(self.width, self.height)
end

---@param snapshot table<string, unknown>
---@return ApplicationPlan the resolved interface plan
function MainMenuState:_resolve(snapshot)
  local session = assert(self._session, "Main Menu session is disposed")
  local plan = session:resolve(assert(self:_measured(), "Main Menu needs its display facts"), snapshot)
  local content = plan.content
  if type(content) == "table" and type(content.layout) == "table" then
    local shaped = content.layout --[[@as { saves: { offset: number } }]]
    if type(shaped.saves) == "table" and type(shaped.saves.offset) == "number" then
      self.scrollOffset = shaped.saves.offset
    end
  end
  return plan
end

function MainMenuState:_readSaves()
  -- Menu cards list validated display envelopes only: no deep validation
  -- and no generated-cache reads, so a cold cache never reads as a corrupt
  -- save. Continue stays an intent; semantic validity is decided later at
  -- field entry.
  local ok, entriesOrError = pcall(self.saveStore.listMetadata, self.saveStore)
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
  -- Continue is an intent carrying the selected save id, not a validity
  -- claim: the owning route validates the record strictly after field core
  -- and location geometry are ready. Nothing loads here.
  self:_emit({ kind = "continue", saveId = assert(save.saveId) })
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

function MainMenuState:_backOrQuit()
  if not self.controller:back() then
    self:_emit({ kind = "quit" })
  end
end

-- Dispatches one session-mapped semantic hit through the existing
-- controller pathways. Confirmation buttons focus-then-act exactly as the
-- keyboard flow does; anything else only clears presentation capture.
---@param hit table<string, string|nil>
function MainMenuState:_dispatchHit(hit)
  if hit.region == "confirmation" then
    if hit.lane == "delete" then
      self.controller:focusConfirmation("delete")
      self:_activate()
    elseif hit.lane == "cancel" then
      self.controller:focusConfirmation("cancel")
      self.controller:back()
    end
    return
  end
  if hit.region == "popup" then
    if hit.lane == "delete" then
      self:_activate()
    else
      self.controller:back()
    end
    return
  end
  if hit.region == "global" then
    if hit.actionId ~= nil then
      self.controller:focusGlobal(hit.actionId)
      self:_activate()
    end
    return
  end
  if hit.region == "saves" then
    if hit.saveId == nil then
      return
    end
    if hit.lane == "overflow" then
      self.controller:openOverflow(hit.saveId)
    elseif hit.lane == "body" then
      self.controller:focusSave(hit.saveId, "body")
      self:_activate()
    end
  end
end

-- Maps one ordered pointer batch through the current plan and dispatches
-- the resulting semantic hits. Cancellation clears presentation capture
-- only and never cancels or confirms a dialog semantically.
---@param events table<string, unknown>[]
function MainMenuState:_dispatchPointer(events)
  if self._disposed then
    return
  end
  local snapshot = self:_snapshot()
  self:_resolve(snapshot)
  local session = assert(self._session, "Main Menu session is disposed")
  local mapped = session:mapInput(events, snapshot)
  for _, event in ipairs(mapped) do
    if self._disposed then
      return
    end
    if type(event) == "table" and event.type ~= "pointer_cancel" and event.region ~= nil then
      self:_dispatchHit(event)
    end
  end
  if self._disposed then
    return
  end
  self:_resolve(self:_snapshot())
end

-- Forwards release/move batches so session capture stays consistent; the
-- click fires on press, so releases and moves never dispatch hits.
---@param events table<string, unknown>[]
function MainMenuState:_trackPointer(events)
  if self._disposed then
    return
  end
  local snapshot = self:_snapshot()
  self:_resolve(snapshot)
  local session = assert(self._session, "Main Menu session is disposed")
  session:mapInput(events, snapshot)
end

function MainMenuState:_key(key)
  if HgssInputBindings.isCancelKey(key) then
    self:_backOrQuit()
    return
  end
  if key == "up" or key == "down" or key == "left" or key == "right" then
    self.controller:move(key)
  elseif HgssInputBindings.isActionKey(key) then
    self:_activate()
  elseif HgssInputBindings.isMenuKey(key) then
    self.controller:requestDelete()
  end
end

function MainMenuState:keypressed(key)
  if self._disposed then
    return
  end
  self:_key(key)
end

function MainMenuState:gamepadpressed(_, button)
  if self._disposed then
    return
  end
  local keys = {
    dpup = "up",
    dpdown = "down",
    dpleft = "left",
    dpright = "right",
  }
  if button == "b" then
    self:_backOrQuit()
  elseif button == "a" then
    self:_activate()
  elseif button == "x" then
    self.controller:requestDelete()
  elseif keys[button] then
    self.controller:move(keys[button])
  end
end

function MainMenuState:mousepressed(x, y, button)
  if self._disposed then
    return
  end
  if button == 1 then
    self:_dispatchPointer({ { type = "pointer_down", pointerId = "mouse:1", x = x, y = y } })
  end
end

function MainMenuState:mousemoved(x, y, _, _, istouch)
  if self._disposed then
    return
  end
  if not istouch then
    self:_trackPointer({ { type = "pointer_move", pointerId = "mouse:1", x = x, y = y } })
  end
end

function MainMenuState:mousereleased(x, y, button)
  if self._disposed then
    return
  end
  if button == 1 then
    self:_trackPointer({ { type = "pointer_up", pointerId = "mouse:1", x = x, y = y } })
  end
end

function MainMenuState:touchpressed(id, x, y)
  if self._disposed then
    return
  end
  self:_dispatchPointer({ { type = "pointer_down", pointerId = "touch:" .. tostring(id), x = x, y = y } })
end

function MainMenuState:touchmoved(id, x, y)
  if self._disposed then
    return
  end
  self:_trackPointer({ { type = "pointer_move", pointerId = "touch:" .. tostring(id), x = x, y = y } })
end

function MainMenuState:touchreleased(id, x, y)
  if self._disposed then
    return
  end
  self:_trackPointer({ { type = "pointer_up", pointerId = "touch:" .. tostring(id), x = x, y = y } })
end

function MainMenuState:wheelmoved(_, y)
  if self._disposed then
    return
  end
  if not self.controller.popup and not self.controller.confirmation then
    self.controller:move(y > 0 and "up" or "down")
  end
end

function MainMenuState:focus(focused)
  if not focused and self._session ~= nil then
    self._session:cancelPointers()
  end
end

function MainMenuState:resize(width, height)
  assert(type(width) == "number" and type(height) == "number")
  self.width, self.height = width, height
end

function MainMenuState:layout()
  return self:view().layout
end

-- Host-coordinate hit query over the current plan: inverts once through
-- the resolved placement, then resolves the shared logical hit test.
-- Outside the visible clip or without a content pane there is no target.
---@param x number host x
---@param y number host y
---@return table<string, string|nil> the current caller-visible hit information
function MainMenuState:hitTest(x, y)
  local snapshot = self:_snapshot()
  local plan = self:_resolve(snapshot)
  local function miss()
    return { region = nil, actionId = nil, saveId = nil, lane = nil }
  end
  local panes = plan.panes
  if type(panes) ~= "table" or type(panes[1]) ~= "table" then
    return miss()
  end
  local placement = panes[1].placement
  if type(placement) ~= "table" then
    return miss()
  end
  local logicalX, logicalY = LayoutGeometry.hostToLogical(placement, x, y)
  if logicalX == nil or logicalY == nil then
    return miss()
  end
  local content = plan.content
  if type(content) ~= "table" or type(content.layout) ~= "table" then
    return miss()
  end
  return MainMenuLayout.hitTest(content.layout, snapshot, logicalX, logicalY)
end

function MainMenuState:view()
  local snapshot = self:_snapshot()
  local plan = self:_resolve(snapshot)
  local content = plan.content
  local layout = type(content) == "table" and content.layout or nil
  snapshot.layout = layout
  snapshot.focusedId = self.controller:focusedId()
  snapshot.scroll = { offset = self.scrollOffset }
  snapshot.presentation = plan
  return snapshot
end

function MainMenuState:draw()
  local snapshot = self:view()
  local plan = assert(snapshot.presentation, "Main Menu draws its resolved presentation plan")
  local renderer = assert(self.renderer, "Main Menu draws its renderer")
  local graphics = renderer.graphics or love.graphics
  ApplicationPresentation.draw(graphics, {
    graphics = graphics,
    renderer = renderer,
    text = renderer.text,
  }, snapshot, plan)
end

function MainMenuState:update() end

function MainMenuState:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  if self._session ~= nil then
    self._session:dispose()
    self._session = nil
  end
  if self.renderer and self.renderer.dispose then
    self.renderer:dispose()
  end
  self.renderer = nil
end

return MainMenuState
