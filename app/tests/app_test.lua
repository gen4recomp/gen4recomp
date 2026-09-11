-- App shell state replacement tests. App.setState is the single transition point
-- between top-level states: it must dispose the previous state exactly once,
-- tolerate states without a disposal hook (the one centralized optional
-- check), and guarantee application quit can never dispose a state twice.
-- Import sessions are single-use: a file drop must always enter a fresh
-- import session through the import state and never invoke an importer left
-- over from a previous session.

local Assert = require("tests.support.Assert")
local RomImporter = require("romdump.src.source.RomImporter")
local HgssGame = require("game.hgss.src.HgssGame")
local InteractiveCacheBuild = require("romdump.src.build.InteractiveCacheBuild")

local App
local ImportState
local VersionSelectState

local function loadShellModules()
  local ok, appOrError = pcall(require, "app.src.App")
  Assert.isTrue(ok, "the app shell must provide app.src.App: " .. tostring(appOrError))
  App = appOrError
  local okImport, importOrError = pcall(require, "app.src.launcher.ImportState")
  Assert.isTrue(okImport, "the app shell must own its import state: " .. tostring(importOrError))
  ImportState = importOrError
  local okVersion, versionOrError = pcall(require, "app.src.launcher.VersionSelectState")
  Assert.isTrue(okVersion, "the app shell must own its version selector: " .. tostring(versionOrError))
  VersionSelectState = versionOrError
end

local T = {}

-- A contract state that counts disposal invocations.
local function countingState()
  local state = { disposed = 0 }
  function state:dispose()
    self.disposed = self.disposed + 1
  end
  return state
end

-- Clear module state so tests are independent of each other and of the boot
-- flow tests.
local function fresh()
  loadShellModules()
  App.state = nil
  App.importer = nil
  App.provisioner = nil
  App.drawableWidth = nil
  App.drawableHeight = nil
end

-- One harness for every App-level seam a test can touch: fresh module state,
-- the App opts the boot/draw paths read, the RomImporter.isReady seam, a
-- captured HgssGame.new launch, and a graphics.print/quit spy. Every stub is
-- restored on every path, so no test leaks options or stubs into the next.
---@class AppStateHarness
---@field prints integer
---@field state table
---@field launches table[]
---@field quitCodes integer[]
---@field provisionerDisposals integer
---@param opts table|nil
---@param ready fun(id: string): boolean
---@param fn fun(result: AppStateHarness)
---@return AppStateHarness
local function withAppHarness(opts, ready, fn)
  fresh()
  local originalOpts = App.opts
  local originalIsReady = RomImporter.isReady
  local originalNew = HgssGame.new
  local graphics = love.graphics
  local originalPrint = graphics.print
  local originalGetDimensions = graphics.getDimensions
  local originalQuit = love.event.quit
  local originalBuildNew = InteractiveCacheBuild.new
  local result = {
    prints = 0,
    state = countingState(),
    launches = {},
    quitCodes = {},
    provisionerDisposals = 0,
  }
  local unownedOption = {}
  App.opts = setmetatable(opts or { dev = false }, {
    __index = function(_, key)
      if key == "dev" then
        return false
      end
      return unownedOption
    end,
  })
  RomImporter.isReady = ready
  HgssGame.new = function(options)
    result.launches[#result.launches + 1] = options
    return result.state
  end
  graphics.print = function()
    result.prints = result.prints + 1
  end
  graphics.getDimensions = function()
    return 800, 600
  end
  love.event.quit = function(code)
    result.quitCodes[#result.quitCodes + 1] = code
  end
  InteractiveCacheBuild.new = function()
    return {
      update = function() end,
      dispose = function()
        result.provisionerDisposals = result.provisionerDisposals + 1
      end,
      requestField = function()
        return true
      end,
      ensureField = function()
        return true
      end,
      requestCell = function()
        return true
      end,
      ensureCell = function()
        return true
      end,
    }
  end
  local ok, err = pcall(fn, result)
  App.opts = originalOpts
  RomImporter.isReady = originalIsReady
  HgssGame.new = originalNew
  graphics.print = originalPrint
  graphics.getDimensions = originalGetDimensions
  love.event.quit = originalQuit
  InteractiveCacheBuild.new = originalBuildNew
  if not ok then
    error(err, 0)
  end
  return result
end

-- An importer stand-in in a given state. App reads isBusy()/state and forwards
-- drops; a terminal (complete/error) stand-in models an importer left over
-- from a finished session.
local function importerStub(state, busy)
  local importer = {
    state = state,
    busy = busy or false,
    filedroppedCalls = 0,
  }
  function importer:isBusy()
    return self.busy
  end
  function importer:filedropped()
    self.filedroppedCalls = self.filedroppedCalls + 1
  end
  return importer
end

-- A minimal dropped-file stand-in satisfying RomSource.fromDroppedFile's
-- protocol. The bytes are not a ROM, so a real importer routes the drop into
-- its reading state without touching the filesystem or caches.
local function droppedFile()
  return {
    getFilename = function()
      return "dropped.nds"
    end,
    open = function()
      return true
    end,
    read = function()
      return "not a real rom"
    end,
    close = function() end,
  }
end

function T.starting_an_import_disposes_the_active_field_state()
  fresh()
  local field = countingState()
  App.setState(field)
  App.saveDir = nil
  App._startImport()
  Assert.equal(field.disposed, 1)
  Assert.equal(getmetatable(App.state).__index, ImportState)
  Assert.notNil(App.importer)
end

-- The bare "g4recomp" draw is developer branding on an empty frame: product
-- mode draws nothing, dev mode keeps the emergency text.
function T.app_draw_keeps_the_emergency_brand_text_only_in_dev_mode()
  for _, dev in ipairs({ false, true }) do
    local result = withAppHarness({ dev = dev }, function()
      return false
    end, function()
      App.draw()
    end)
    local expected = 0
    if dev then
      expected = 1
    end
    Assert.equal(result.prints, expected, "brand text on an empty frame tracks dev mode")
  end
end

-- An import session is single-use. A file drop during gameplay after a
-- finished import (complete or failed) must enter a fresh import session
-- through the import state; the stale importer's completion callback would
-- otherwise replace the active field state unexpectedly, and re-running a
-- failed importer is just as wrong.
function T.drop_after_a_finished_import_starts_a_fresh_session()
  for _, terminalState in ipairs({ "complete", "error" }) do
    fresh()
    local stale = importerStub(terminalState)
    App.importer = stale
    App.setState({})
    App.filedropped(droppedFile())
    Assert.equal(stale.filedroppedCalls, 0, "the stale importer must not be invoked")
    Assert.isFalse(App.importer == stale, "a finished import session must not be reused")
    Assert.notNil(App.importer)
    Assert.equal(getmetatable(App.state).__index, ImportState)
    Assert.equal(App.state.importer, App.importer)
  end
end

-- Drops while an import is running are ignored: no new session, no forward to
-- the busy importer.
function T.drop_while_busy_is_ignored()
  fresh()
  local busy = importerStub("reading", true)
  App.importer = busy
  local state = {}
  App.setState(state)
  App.filedropped(droppedFile())
  Assert.equal(busy.filedroppedCalls, 0)
  Assert.equal(App.importer, busy)
  Assert.equal(App.state, state)
end

-- A failed import leaves no importer behind: the next update clears it, so a
-- stale reference can never survive the session. The import screen holds its
-- own reference and is unaffected.
function T.failed_import_is_cleared_on_the_next_update()
  fresh()
  App.importer = importerStub("error")
  local state = { update = function() end }
  App.setState(state)
  App.update(0.016)
  Assert.isNil(App.importer, "a failed import session must not linger")
  Assert.equal(App.state, state, "clearing the importer must not disturb the import screen")
end

-- The boot decision when no ROM was supplied: zero ready versions enter the
-- import state, one launches HGSS, and several offer the version selector.

function T.boot_existing_with_no_ready_version_starts_an_import()
  withAppHarness({}, function()
    return false
  end, function()
    App._bootExisting()
    Assert.notNil(App.importer)
    Assert.equal(getmetatable(App.state).__index, ImportState)
  end)
end

function T.boot_existing_with_one_ready_version_enters_the_main_menu()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    App._bootExisting()
    local launch = assert(result.launches[1])
    Assert.keySet(launch, "derivedAssets,development,onExit,versionId")
    Assert.equal(launch.versionId, "heartgold")
    Assert.isFalse(launch.development)
    Assert.equal(App.state, result.state)
    Assert.equal(result.provisionerDisposals, 0, "launch must not dispose its new provisioner")
  end)
end

function T.boot_existing_with_two_ready_versions_offers_the_selector_over_the_ready_array()
  withAppHarness({ dev = true }, function(id)
    return id == "heartgold" or id == "soulsilver"
  end, function(result)
    App._bootExisting()
    local selector = App.state
    ---@cast selector table
    Assert.equal(getmetatable(selector).__index, VersionSelectState)
    Assert.deepEqual(selector.ready, { "heartgold", "soulsilver" })
    selector.onPick("soulsilver")
    local launch = assert(result.launches[1])
    Assert.keySet(launch, "derivedAssets,development,onExit,versionId")
    Assert.equal(launch.versionId, "soulsilver")
    Assert.isTrue(launch.development)
    Assert.equal(App.state, result.state)
  end)
end

function T.completed_import_launches_the_imported_version_through_the_hgss_entry()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    App._onImported("heartgold")
    local launch = assert(result.launches[1])
    Assert.keySet(launch, "derivedAssets,development,onExit,versionId")
    Assert.equal(launch.versionId, "heartgold")
    Assert.equal(App.state, result.state)
  end)
end

function T.shell_exit_mapping_quits_only_for_a_hgss_quit_result()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    App._bootMainMenu({ "heartgold" })
    local launch = assert(result.launches[1])
    launch.onExit({ kind = "continue" })
    launch.onExit(nil)
    Assert.deepEqual(result.quitCodes, {})
    launch.onExit({ kind = "quit" })
    Assert.deepEqual(result.quitCodes, { 0 })
  end)
end

return { tests = T }
