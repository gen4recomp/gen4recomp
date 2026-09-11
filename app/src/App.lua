-- Launcher/process shell for the interactive app root.

local WindowConfig = require("game.src.WindowConfig")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local ProducerFingerprint = require("romdump.src.ProducerFingerprint")
local HgssGame = require("game.hgss.src.HgssGame")
local DerivedAssetProvisioner = require("app.src.DerivedAssetProvisioner")
local ImportState = require("app.src.launcher.ImportState")
local VersionSelectState = require("app.src.launcher.VersionSelectState")

---@class App
---@field opts AppOptions
---@field state table<string, unknown>|nil
---@field importer RomImporter|nil
---@field provisioner DerivedAssetProvisioner|nil
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
  if App.opts.dev == true then
    local repositoryRoot = love.filesystem.getSourceBaseDirectory()
    local backend = ProducerFingerprint.checkoutBackend(repositoryRoot)
    return {
      versionId = versionId,
      producerFingerprint = ProducerFingerprint.compute(backend, "romdump/src"),
      developmentRepositoryRoot = repositoryRoot,
    }
  end

  local backend = ProducerFingerprint.appBackend()
  local info = assert(backend.getInfo, "producer VFS backend must expose getInfo")("romdump/src")
  assert(info and info.type == "directory", "packaged producer tree romdump/src is missing or is not a directory")
  return {
    versionId = versionId,
    producerFingerprint = ProducerFingerprint.compute(backend, "romdump/src"),
  }
end

local function launchHgss(versionId)
  local function onExit(result)
    if result and result.kind == "quit" then
      love.event.quit(0)
    end
  end
  local provisioner
  local ok, result = pcall(function()
    provisioner = DerivedAssetProvisioner.new(provisionerOptions(versionId))
    return HgssGame.new({
      versionId = versionId,
      onExit = onExit,
      development = App.opts.dev,
      derivedAssets = provisioner:gameHost(),
    })
  end)
  if not ok then
    if provisioner then
      provisioner:dispose()
    end
    error(result, 0)
  end
  local stateOk, stateError = pcall(App.setState, result)
  if not stateOk then
    provisioner:dispose()
    error(stateError, 0)
  end
  App.provisioner = assert(provisioner)
end

function App.load(opts)
  App.opts = opts or {}
  App.drawableWidth, App.drawableHeight = love.graphics.getDimensions()
  App.importer = nil
  App.setState(nil)
  love.graphics.setBackgroundColor(unpack(WindowConfig.BACKGROUND_COLOR))
  App.saveDir = love.filesystem.getSaveDirectory()

  App._bootExisting()
end

function App.setState(nextState)
  local previous = App.state
  App.state = nextState
  if previous and previous.dispose then
    previous:dispose()
  end
  if previous and App.provisioner then
    local provisioner = assert(App.provisioner)
    App.provisioner = nil
    provisioner:dispose()
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
  App.provisioner = nil
  App._bootMainMenu({ versionId })
end

function App._bootMainMenu(versions)
  assert(type(versions) == "table" and #versions == 1, "Main Menu needs exactly one selected version")
  launchHgss(versions[1])
end

function App._bootExisting()
  local ready = readyVersions()
  if #ready == 0 then
    App._startImport()
    return
  end
  if #ready == 1 then
    App._bootMainMenu(ready)
    return
  end
  App.setState(VersionSelectState.new(ready, function(versionId)
    App._bootMainMenu({ versionId })
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
end

return App
