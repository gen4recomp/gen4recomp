-- Gated New Game through production menu routing. Choosing New Game
-- requests the semantic intro milestone and hands the real candidate from
-- the real mon and item catalogs to Oak composition only once that
-- milestone is ready, without waiting on field-core work. A read facade
-- derives item availability from the real bootstrap closure, so a warm
-- complete cache cannot conceal the declared boundary: every catalog byte
-- still loads through the genuine readers and validators.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FakeCache = require("tests.support.FakeCache")
local SaveFs = require("libs.storage.src.SaveFs")
local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
local HgssGame = require("game.hgss.src.HgssGame")
local FieldState = require("game.hgss.src.field.FieldState")
local OakIntroComposition = require("game.hgss.src.newgame.OakIntroComposition")
local CacheFs = require("libs.storage.src.CacheFs")
local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local ItemCache = require("libs.assets.src.ItemCache")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = { "bootstrap" },
  },
  tests = {},
}

local function bootstrapDeclaresItems()
  for _, job in ipairs(ArtifactJobs.bootstrapJobs({})) do
    if job.kind == "items" and job.key == "global" then
      return true
    end
  end
  return false
end

function T.tests.new_game_enters_oak_on_bootstrap_alone()
  local versionId = AcceptanceHarness.defaultVersion()
  local store = GameSaveStore.new(SaveFs.global(FakeCache.new()))
  local itemsDeclared = bootstrapDeclaresItems()
  local itemCatalogPath = ItemCache.catalogPath()

  local originalForVersion = CacheFs.forVersion
  local originalStoreNew = GameSaveStore.new
  local originalFieldNew = FieldState.new
  local originalCompose = OakIntroComposition.compose

  local candidates = {}
  local requestedMilestones = {}
  local fieldCalls = 0
  local introReady = false
  local host = {
    requestMilestone = function(name, _)
      requestedMilestones[#requestedMilestones + 1] = name
      if name == "new-game-intro" then
        return introReady
      end
      return false
    end,
    requestField = function(_, _)
      return false
    end,
    ensureField = function(_)
      return true
    end,
    requestCell = function(_)
      return true
    end,
    ensureCell = function(_)
      return true
    end,
  }

  CacheFs.forVersion = function(forVersionId, backend)
    if backend ~= nil then
      return originalForVersion(forVersionId, backend)
    end
    local realFs = originalForVersion(forVersionId)
    if itemsDeclared then
      return realFs
    end
    local realBackend = realFs.backend
    local hiddenPath = realFs:resolve(itemCatalogPath)
    local filtered = {}
    function filtered:read(fullPath)
      if fullPath == hiddenPath then
        return nil
      end
      return realBackend:read(fullPath)
    end
    function filtered:getInfo(fullPath)
      if fullPath == hiddenPath then
        return nil
      end
      return realBackend:getInfo(fullPath)
    end
    function filtered:getDirectoryItems(fullPath)
      return realBackend:getDirectoryItems(fullPath)
    end
    function filtered:write(fullPath, data)
      return realBackend:write(fullPath, data)
    end
    function filtered:createDirectory(fullPath)
      return realBackend:createDirectory(fullPath)
    end
    function filtered:remove(fullPath)
      return realBackend:remove(fullPath)
    end
    function filtered:replace(sourcePath, destinationPath)
      return realBackend:replace(sourcePath, destinationPath)
    end
    return originalForVersion(forVersionId, filtered)
  end
  rawset(GameSaveStore, "new", function()
    return store
  end)
  FieldState.new = function(...)
    fieldCalls = fieldCalls + 1
    return originalFieldNew(...)
  end
  rawset(OakIntroComposition, "compose", function(options)
    candidates[#candidates + 1] = assert(options.candidate, "Oak composition requires the real candidate")
    return { dispose = function() end }
  end)

  local game = nil
  local ok, err = pcall(function()
    game = HgssGame.new({ versionId = versionId, onExit = function() end, derivedAssets = host })
    game.state:keypressed("return")
    for _ = 1, 10 do
      game:update(1 / 60)
    end
    Assert.equal(#candidates, 0, "Oak waits for the intro milestone while it is cold")
    local introRequests = 0
    for _, name in ipairs(requestedMilestones) do
      Assert.isTrue(name ~= "field-core", "no field-core request is used to make this pass")
      if name == "new-game-intro" then
        introRequests = introRequests + 1
      end
    end
    Assert.isTrue(introRequests >= 1, "New Game requests its intro milestone as required")
    introReady = true
    for _ = 1, 10 do
      game:update(1 / 60)
    end
    Assert.equal(#candidates, 1, "Oak receives the real candidate once")
    local candidate = assert(candidates[1], "the captured candidate is available")
    Assert.equal(candidate.versionId, versionId, "the candidate carries the selected version")
    Assert.notNil(candidate.mons, "the candidate carries its real mons bucket")
    Assert.isTrue(type(candidate.mons) == "table", "the mons bucket is the constructed domain value")
    Assert.equal(fieldCalls, 0, "no field is constructed before the Oak handoff")
  end)

  CacheFs.forVersion = originalForVersion
  rawset(GameSaveStore, "new", originalStoreNew)
  FieldState.new = originalFieldNew
  rawset(OakIntroComposition, "compose", originalCompose)
  if game ~= nil then
    game:dispose()
  end
  if not ok then
    error(err, 0)
  end
end

return T
