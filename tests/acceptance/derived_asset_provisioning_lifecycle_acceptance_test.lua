-- Production app/game composition for the derived-asset lifecycle. The game
-- receives only semantic operations, while App owns producer progress and
-- teardown ordering.

local Assert = require("tests.support.Assert")
local App = require("app.src.App")
local HgssGame = require("game.hgss.src.HgssGame")
local RomImporter = require("romdump.src.source.RomImporter")
local InteractiveCacheBuild = require("romdump.src.build.InteractiveCacheBuild")

local T = {
  metadata = {
    tags = { "app", "game", "provisioning", "lifecycle" },
  },
  tests = {},
}

---@return InteractiveCacheBuild
local function unusedBuildState()
  local build = {} --[[@as unknown]]
  return build --[[@as InteractiveCacheBuild]]
end

local function withApp(fn)
  local originalState = App.state
  local originalImporter = App.importer
  local originalProvisioner = App.provisioner
  local originalOpts = App.opts
  local originalNew = HgssGame.new
  local originalReady = RomImporter.isReady
  local originalDimensions = love.graphics.getDimensions
  local originalQuit = love.event.quit
  local originalBuildNew = InteractiveCacheBuild.new

  local result = { events = {}, launches = {} }
  App.state = nil
  App.importer = nil
  App.provisioner = nil
  App.opts = { dev = false }
  App.drawableWidth, App.drawableHeight = 800, 600
  RomImporter.isReady = function(versionId)
    return versionId == "heartgold"
  end
  love.graphics.getDimensions = function()
    return 800, 600
  end
  love.event.quit = function() end
  InteractiveCacheBuild.new = function()
    return {
      update = function() end,
      dispose = function() end,
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
  HgssGame.new = function(options)
    result.launches[#result.launches + 1] = options
    return {
      update = function()
        result.events[#result.events + 1] = "game:update"
      end,
      dispose = function()
        result.events[#result.events + 1] = "game:dispose"
      end,
    }
  end

  local ok, err = pcall(fn, result)

  App.state = originalState
  App.importer = originalImporter
  App.provisioner = originalProvisioner
  App.opts = originalOpts
  HgssGame.new = originalNew
  RomImporter.isReady = originalReady
  love.graphics.getDimensions = originalDimensions
  love.event.quit = originalQuit
  InteractiveCacheBuild.new = originalBuildNew
  if not ok then
    error(err, 0)
  end
end

T.tests["the selected game receives only the semantic provisioning host"] = function()
  withApp(function(result)
    App._bootMainMenu({ "heartgold" })
    local launch = assert(result.launches[1])
    local host = assert(launch.derivedAssets, "the running game must receive a derived-asset host")
    Assert.keySet(host, "ensureCell,ensureField,requestCell,requestField")
    Assert.equal(type(host.requestField), "function")
    Assert.equal(type(host.ensureField), "function")
    Assert.equal(type(host.requestCell), "function")
    Assert.equal(type(host.ensureCell), "function")
    Assert.isNil(host.update, "the game must not receive producer lifecycle control")
    Assert.isNil(host.dispose, "the game must not receive producer disposal control")
  end)
end

T.tests["producer progress runs before the running game update"] = function()
  withApp(function(result)
    local order = {}
    ---@type DerivedAssetProvisioner
    local provisioner = {
      build = unusedBuildState(),
      closed = false,
      host = nil,
      update = function()
        order[#order + 1] = "provisioner:update"
      end,
    }
    App.provisioner = provisioner
    App.state = {
      update = function()
        order[#order + 1] = "game:update"
      end,
    }
    App.update(1 / 30)
    Assert.deepEqual(order, { "provisioner:update", "game:update" })
    Assert.deepEqual(result.events, {})
  end)
end

T.tests["game disposal precedes producer disposal"] = function()
  withApp(function()
    local events = {}
    App.state = {
      dispose = function()
        events[#events + 1] = "game:dispose"
      end,
    }
    ---@type DerivedAssetProvisioner
    local provisioner = {
      build = unusedBuildState(),
      closed = false,
      host = nil,
      dispose = function()
        events[#events + 1] = "provisioner:dispose"
      end,
    }
    App.provisioner = provisioner
    App.quit()
    Assert.deepEqual(events, { "game:dispose", "provisioner:dispose" })
    Assert.isNil(App.state)
    Assert.isNil(App.provisioner)
  end)
end

return T
