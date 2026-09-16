-- Launcher/process shell for the interactive app root.

local WindowConfig = require("game.src.WindowConfig")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local ProducerFingerprint = require("romdump.src.ProducerFingerprint")
local DerivedCacheVersions = require("romdump.src.config.DerivedCacheVersions")
local CompilerPool = require("romdump.src.build.CompilerPool")
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
---@field pool CompilerPool|nil process-owned compiler pool shared by every selection
---@field epoch integer latest selected source epoch, monotonically increasing
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

-- The process development digest, frozen on first selection: a developer
-- restarts the process to consume producer edits. The frozen selection
-- records which checkout factory produced it, so a backend swap (a different
-- process configuration) reselects instead of reusing a stale digest.
local frozenDevelopment = nil

local function developmentProducerId(repositoryRoot)
  local factory = ProducerFingerprint.checkoutBackend
  if frozenDevelopment ~= nil and frozenDevelopment.root == repositoryRoot and frozenDevelopment.factory == factory then
    return frozenDevelopment.producerId
  end
  local producerId = ProducerFingerprint.compute(factory(repositoryRoot))
  frozenDevelopment = { root = repositoryRoot, factory = factory, producerId = producerId }
  return producerId
end

local function releaseProducerId(versionId)
  local counter = DerivedCacheVersions[versionId]
  assert(
    type(counter) == "number" and counter == math.floor(counter) and counter >= 1,
    "release counter must be a positive integer for version: " .. tostring(versionId)
  )
  return "r" .. tostring(counter)
end

local function provisionerOptions(versionId)
  -- Every selection mints a new epoch on the one process pool, even when
  -- the logical generation is unchanged. Old physical jobs retain their
  -- capacity until their actual completion; no second pool is spawned.
  App.epoch = (App.epoch or 0) + 1
  App._ensurePool()
  local options = {
    versionId = versionId,
    pool = assert(App.pool, "process compiler pool is unavailable"),
    epoch = App.epoch,
  }
  if App.opts.dev == true then
    local repositoryRoot = love.filesystem.getSourceBaseDirectory()
    options.producerFingerprint = developmentProducerId(repositoryRoot)
    options.developmentRepositoryRoot = repositoryRoot
    return options
  end

  options.producerFingerprint = releaseProducerId(versionId)
  return options
end

function App._ensurePool()
  if App.pool ~= nil then
    return
  end
  local options = { mode = "interactive" }
  if App.opts.dev == true then
    options.developmentRepositoryRoot = love.filesystem.getSourceBaseDirectory()
  end
  App.pool = CompilerPool.new(options)
end

-- Retires the selected source interest without joining long compiler jobs.
-- The process pool is reused; stale results cannot publish afterwards.
function App._retireSelection()
  local provisioner = App.provisioner
  App.provisioner = nil
  if provisioner then
    provisioner:dispose()
  end
end

-- Launches the menu on the current provisioner without touching source
-- ownership: menu/Oak/field transitions within one selection never rotate
-- the epoch or restart the sweep.
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

-- Selects a game version: constructs its session on the process pool, then
-- launches the menu immediately when bootstrap is already ready or waits
-- through a visible preparation state otherwise. A ready bootstrap never
-- recompiles; field core and sweep warm while the menu shows.
function App._selectVersion(versionId)
  local pool = App.pool
  if pool ~= nil then
    local diagnostics = pool:diagnostics()
    if diagnostics.quiescing and not pool:isQuiescent() then
      local pendingEpoch = App.epoch or 0
      App.setState(CachePreparationState.new({
        kind = "quiescence",
        epoch = pendingEpoch,
        pool = pool,
        isCurrent = function(selected)
          return App.epoch == selected
        end,
        onReady = function()
          App._selectVersion(versionId)
        end,
        onCancel = function()
          App._showVersionSelector()
        end,
      }))
      return
    end
  end
  App._retireSelection()
  local provisioner = DerivedAssetProvisioner.new(provisionerOptions(versionId))
  App.provisioner = provisioner
  local epoch = assert(App.epoch, "selection has no epoch")
  local host = provisioner:gameHost()
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
  App.pool = nil
  App.epoch = 0
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
  App._selectVersion(versionId)
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
  if App.provisioner then
    App.provisioner:update()
  elseif App.pool then
    -- No session is attached (selector, waiting view, cancelled preparation):
    -- keep the process pool's physical lifecycle moving exactly once so old
    -- work settles and the source-close barrier progresses. A recorded
    -- infrastructure failure stays for the waiting view to display instead
    -- of raising here; anything else keeps propagating.
    local ok, err = pcall(function()
      App.pool:update()
    end)
    if not ok then
      local diagOk, diagnostics = pcall(App.pool.diagnostics, App.pool)
      if not (diagOk and type(diagnostics) == "table" and diagnostics.error ~= nil) then
        error(err, 0)
      end
    end
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
    love.graphics.print("g4recomp", 24, 24)
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
  if App.pool ~= nil then
    -- Retire selected interest before the barrier so no new admission can
    -- enter the quiescing pool, then wait visibly for actual source closure.
    -- The import starts exactly once from successful barrier completion, on
    -- every raw path including the selector with no attached provisioner.
    -- Progress and input keep pumping while the readers drain.
    App._retireSelection()
    App.pool:quiesce()
    local epoch = App.epoch or 0
    App.setState(CachePreparationState.new({
      kind = "quiescence",
      epoch = epoch,
      pool = App.pool,
      isCurrent = function(selected)
        return App.epoch == selected
      end,
      onReady = function()
        App._startImport()
        if App.importer then
          App.importer:filedropped(file)
        end
      end,
      onCancel = function()
        App._showVersionSelector()
      end,
    }))
    return
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
  -- Process shutdown alone joins the physical workers; game switching
  -- leaves actual old jobs counted on the shared pool.
  local pool = App.pool
  App.pool = nil
  if pool then
    pool:shutdown()
  end
end

return App
