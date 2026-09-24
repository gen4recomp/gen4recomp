-- Launcher/process shell for the interactive app root.

local WindowConfig = require("game.src.WindowConfig")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local CacheService = require("app.src.CacheService")
local HgssGame = require("game.hgss.src.HgssGame")
local DerivedAssetProvisioner = require("app.src.DerivedAssetProvisioner")
local CachePreparationState = require("app.src.launcher.CachePreparationState")
local ImportState = require("app.src.launcher.ImportState")
local VersionSelectState = require("app.src.launcher.VersionSelectState")

---@class App
---@field opts AppOptions
---@field state table<string, unknown>|nil
---@field importer RomImporter|nil
---@field provisioner DerivedAssetProvisioner|nil
---@field service CacheService|nil process-owned cache controller service shared by every selection
---@field epoch integer latest borrowed controller epoch, monotonically increasing
---@field pendingQuiesce table<string, integer>|nil unacknowledged source-close barrier for import
---@field drawableWidth number?
---@field drawableHeight number?
local App = {}

---@class AppOptions
---@field test boolean?
---@field dev boolean?

local function readyVersions()
  local out = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      out[#out + 1] = versionId
    end
  end
  return out
end

local function provisionerOptions(versionId)
  -- Every selection borrows a fresh controller epoch, even when the
  -- logical generation is unchanged. Only selectors cross the channel:
  -- the development producer digest and the generation identity are
  -- derived below the controller thread, never on the game thread.
  App._ensureService()
  local options = {
    versionId = versionId,
    service = assert(App.service, "process cache service is unavailable"),
    development = App.opts.dev == true,
  }
  if App.opts.dev == true then
    options.developmentRepositoryRoot = love.filesystem.getSourceBaseDirectory()
  end
  return options
end

function App._ensureService()
  if App.service ~= nil then
    return
  end
  App.service = CacheService.new()
end

-- Retires the selected source interest without joining controller work.
-- The process service is reused; stale results cannot publish afterwards.
function App._retireSelection()
  local provisioner = App.provisioner
  App.provisioner = nil
  if provisioner then
    provisioner:dispose()
  end
end

-- Launches the menu on the current provisioner without touching source
-- ownership: menu/Oak/field transitions within one selection never rotate
-- the epoch. Background corpus completion is authorized once the menu
-- game owns the process state; the authorization itself performs no
-- cache work.
function App._launchMenuWithProvisioner(versionId)
  local provisioner = assert(App.provisioner, "selection has no provisioner")
  local function onExit(result)
    if result and result.kind == "quit" then
      love.event.quit(0)
    end
  end
  local ok, game = pcall(HgssGame.new, {
    versionId = versionId,
    onExit = onExit,
    development = App.opts.dev,
    derivedAssets = provisioner:gameHost(),
  })
  if not ok then
    App._showVersionSelector()
    error(game, 0)
  end
  App.setState(game)
  provisioner:startBackgroundWarmup()
end

function App._showVersionSelector()
  App._retireSelection()
  local ready = readyVersions()
  if #ready == 0 then
    App._startImport()
    return
  end
  App.setState(VersionSelectState.new(ready, function(versionId)
    App._selectVersion(versionId)
  end))
end

-- A pending source-close barrier blocks new selections behind a visible
-- wait: no new session writes shared version roots before the controller
-- acknowledges that every source reader closed successfully.
---@param versionId string newly selected game version
---@param options { freshImport: boolean? }? private selection mode
---@return boolean
function App._waitForQuiescence(versionId, options)
  local pending = App.pendingQuiesce
  local service = App.service
  if pending == nil or service == nil then
    return false
  end
  if service:barrierStatus(pending.epoch, pending.barrier) == "ready" then
    App.pendingQuiesce = nil
    return false
  end
  App.setState(CachePreparationState.new({
    kind = "quiescence",
    epoch = pending.epoch,
    service = service,
    barrier = pending.barrier,
    isCurrent = function(_)
      return App.pendingQuiesce ~= nil and App.pendingQuiesce.barrier == pending.barrier
    end,
    onReady = function()
      App.pendingQuiesce = nil
      App._selectVersion(versionId, options)
    end,
    onCancel = function()
      App.pendingQuiesce = nil
      App._showVersionSelector()
    end,
  }))
  return true
end

-- Selects a game version: borrows a controller epoch through its
-- provisioner, then launches the menu immediately when bootstrap is
-- already ready or waits through a visible preparation state otherwise.
-- A ready bootstrap never recompiles; broader warming starts only after
-- the menu is installed. A fresh import instead waits through the
-- mandatory first-play preparation before the menu may launch.
---@param versionId string newly selected game version
---@param options { freshImport: boolean? }? private selection mode, default bootstrap-only
function App._selectVersion(versionId, options)
  if App._waitForQuiescence(versionId, options) then
    return
  end
  App._retireSelection()
  local provisioner = DerivedAssetProvisioner.new(provisionerOptions(versionId))
  App.provisioner = provisioner
  App.epoch = assert(provisioner.epoch, "selection borrowed no epoch")
  local epoch = App.epoch
  local host = provisioner:gameHost()
  if options ~= nil and options.freshImport == true then
    -- One provisioner epoch owns the mandatory preparation and the
    -- launched game: no retirement or reselection happens between them.
    local preparation = HgssGame.newFirstPlayCachePreparation({
      versionId = versionId,
      derivedAssets = host,
    })
    App.setState(CachePreparationState.new({
      kind = "first-play",
      epoch = epoch,
      preparation = preparation,
      provisioner = host,
      isCurrent = function(selected)
        return App.epoch == selected
      end,
      onReady = function()
        App._launchMenuWithProvisioner(versionId)
      end,
      onCancel = function()
        App._showVersionSelector()
      end,
    }))
    return
  end
  local checkOk, ready = pcall(host.requestMilestone, "bootstrap", "required")
  if checkOk and ready then
    App._launchMenuWithProvisioner(versionId)
    return
  end
  -- A pending bootstrap waits visibly; a thrown readiness check is latched
  -- as the preparation state's visible error on its first update.
  App.setState(CachePreparationState.new({
    kind = "bootstrap",
    epoch = epoch,
    provisioner = host,
    isCurrent = function(selected)
      return App.epoch == selected
    end,
    onReady = function()
      App._launchMenuWithProvisioner(versionId)
    end,
    onCancel = function()
      App._showVersionSelector()
    end,
  }))
end

function App.load(opts)
  App.opts = opts or {}
  App.drawableWidth, App.drawableHeight = love.graphics.getDimensions()
  App.importer = nil
  App.provisioner = nil
  App.service = nil
  App.epoch = 0
  App.pendingQuiesce = nil
  App.setState(nil)
  love.graphics.setBackgroundColor(unpack(WindowConfig.BACKGROUND_COLOR))
  App.saveDir = love.filesystem.getSaveDirectory()

  App._bootExisting()
end

-- Replaces only the UI state. Source ownership is explicit: selection,
-- re-import, selector return and quit retire the session; the
-- bootstrap-state to game handoff must not retire it.
function App.setState(nextState)
  local previous = App.state
  App.state = nextState
  if previous and previous.dispose then
    previous:dispose()
  end
end

function App._startImport()
  local function onComplete(versionId)
    App._onImported(versionId)
  end
  App.importer = RomImporter.new({ onComplete = onComplete })
  App.setState(ImportState.new(App.importer, App.saveDir))
end

function App._onImported(versionId)
  App.importer = nil
  App._selectVersion(versionId, { freshImport = true })
end

function App._bootMainMenu(versions)
  assert(type(versions) == "table" and #versions == 1, "Main Menu needs exactly one selected version")
  App._selectVersion(versions[1])
end

function App._bootExisting()
  local ready = readyVersions()
  if #ready == 0 then
    App._startImport()
    return
  end
  if #ready == 1 then
    App._selectVersion(ready[1])
    return
  end
  App.setState(VersionSelectState.new(ready, function(versionId)
    App._selectVersion(versionId)
  end))
end

function App.update(dt)
  App._syncDrawableSize()
  if App.importer and App.importer:isBusy() then
    App.importer:update()
  end
  if App.importer and not App.importer:isBusy() and App.importer.state == RomImporter.STATES.ERROR then
    App.importer = nil
  end
  if App.service then
    App.service:update()
  end
  if App.provisioner then
    App.provisioner:update()
  end
  if App.state and App.state.update then
    App.state:update(dt)
  end
end

function App.resize(width, height)
  App.drawableWidth = width
  App.drawableHeight = height
  if App.state and App.state.resize then
    App.state:resize(width, height)
  end
end

function App._syncDrawableSize()
  local width, height = love.graphics.getDimensions()
  if width == App.drawableWidth and height == App.drawableHeight then
    return
  end
  App.drawableWidth = width
  App.drawableHeight = height
  if App.state and App.state.resize then
    App.state:resize(width, height)
  end
end

function App.draw()
  App._syncDrawableSize()
  if App.state and App.state.draw then
    App.state:draw()
    return
  end
  if App.opts.dev then
    love.graphics.setColor(1, 1, 1)
    love.graphics.print("portemon", 24, 24)
  end
end

function App.filedropped(file)
  if App.importer and App.importer:isBusy() then
    return
  end
  local waiting = App.state
  if waiting ~= nil and getmetatable(waiting) == CachePreparationState and waiting.kind == "quiescence" then
    -- A replacement dropped while waiting stays queued behind quiescence;
    -- reentering import here would retire the selection under the wait.
    return
  end
  if App.service ~= nil then
    -- Retire selected interest before the barrier so no new admission can
    -- enter the quiescing controller, then wait visibly for actual source
    -- closure. The import starts exactly once from successful barrier
    -- completion, on every raw path including the selector with no
    -- attached provisioner. Progress and input keep pumping while the
    -- readers drain.
    App._retireSelection()
    local epoch = App.epoch or 0
    local barrier = App.service:quiesce(epoch)
    if barrier ~= nil then
      App.pendingQuiesce = { epoch = epoch, barrier = barrier }
      App.setState(CachePreparationState.new({
        kind = "quiescence",
        epoch = epoch,
        service = App.service,
        barrier = barrier,
        isCurrent = function(_)
          return App.pendingQuiesce ~= nil and App.pendingQuiesce.barrier == barrier
        end,
        onReady = function()
          App.pendingQuiesce = nil
          local ok = App.service:importSource(epoch, barrier)
          if ok then
            App._startImport()
            if App.importer then
              App.importer:filedropped(file)
            end
          end
        end,
        onCancel = function()
          App.pendingQuiesce = nil
          App._showVersionSelector()
        end,
      }))
      return
    end
  end
  App._startImport()
  App.importer:filedropped(file)
end

function App.keypressed(key, scancode, isrepeat)
  if App.state and App.state.keypressed then
    App.state:keypressed(key, scancode, isrepeat)
    return
  end
  if key == "escape" then
    love.event.quit(0)
  end
end

function App.keyreleased(key, scancode)
  if App.state and App.state.keyreleased then
    App.state:keyreleased(key, scancode)
  end
end

function App.gamepadpressed(joystick, button)
  if App.state and App.state.gamepadpressed then
    App.state:gamepadpressed(joystick, button)
  end
end

function App.gamepadreleased(joystick, button)
  if App.state and App.state.gamepadreleased then
    App.state:gamepadreleased(joystick, button)
  end
end

function App.gamepadaxis(joystick, axis, value)
  if App.state and App.state.gamepadaxis then
    App.state:gamepadaxis(joystick, axis, value)
  end
end

function App.mousepressed(x, y, button, istouch, presses)
  App._syncDrawableSize()
  if App.state and App.state.mousepressed then
    App.state:mousepressed(x, y, button, istouch, presses)
  end
end

function App.mousemoved(x, y, dx, dy, istouch)
  App._syncDrawableSize()
  if App.state and App.state.mousemoved then
    App.state:mousemoved(x, y, dx, dy, istouch)
  end
end

function App.mousereleased(x, y, button, istouch, presses)
  App._syncDrawableSize()
  if App.state and App.state.mousereleased then
    App.state:mousereleased(x, y, button, istouch, presses)
  end
end

function App.wheelmoved(x, y)
  if App.state and App.state.wheelmoved then
    App.state:wheelmoved(x, y)
  end
end

function App.touchpressed(id, x, y, dx, dy, pressure)
  App._syncDrawableSize()
  if App.state and App.state.touchpressed then
    App.state:touchpressed(id, x, y, dx, dy, pressure)
  end
end

function App.touchmoved(id, x, y, dx, dy, pressure)
  App._syncDrawableSize()
  if App.state and App.state.touchmoved then
    App.state:touchmoved(id, x, y, dx, dy, pressure)
  end
end

function App.touchreleased(id, x, y, dx, dy, pressure)
  App._syncDrawableSize()
  if App.state and App.state.touchreleased then
    App.state:touchreleased(id, x, y, dx, dy, pressure)
  end
end

function App.textinput(text)
  if App.state and App.state.textinput then
    App.state:textinput(text)
  end
end

function App.focus(focused)
  if App.state and App.state.focus then
    App.state:focus(focused)
  end
end

function App.quit()
  App.setState(nil)
  App._retireSelection()
  -- Process shutdown alone joins the controller thread; selection
  -- switching only retires epochs while actual old work stays counted
  -- below the controller.
  local service = App.service
  App.service = nil
  App.pendingQuiesce = nil
  if service then
    service:shutdown()
  end
end

return App
