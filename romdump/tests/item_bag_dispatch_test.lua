-- The item and bag families travel the single worker dispatcher like every
-- other coarse family: the session plans no per-member work, the dispatcher
-- compiles the whole bundle from ROM and stages it through the family
-- writer, and validation delegates to the family readiness check.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")

local T = {}

---@param compilerPath string
---@param writerPath string
---@param compiled table<string, unknown>
---@param kind string
local function checkDispatch(compilerPath, writerPath, compiled, kind)
  local savedCompiler, savedWriter = package.loaded[compilerPath], package.loaded[writerPath]
  local stagedBundle
  package.loaded[compilerPath] = {
    compileAll = function()
      return compiled
    end,
    compile = function()
      return compiled
    end,
  }
  package.loaded[writerPath] = {
    stage = function(artifact, bundle)
      stagedBundle = bundle
      artifact:addOwnedRoot("data/generated/" .. kind)
      return bundle.marker
    end,
  }
  local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
  local ok, outcome = pcall(ArtifactJobs.execute, {
    kind = kind,
    key = "global",
    generationId = "test-generation",
    epoch = 1,
    stageName = kind .. "-dispatch-test",
  }, {
    romFs = {},
    cacheFs = CacheFs.forVersion("heartgold", FakeCache.new()),
  })
  package.loaded[compilerPath] = savedCompiler
  package.loaded[writerPath] = savedWriter
  Assert.isTrue(ok, "the single dispatcher runs the " .. kind .. " family: " .. tostring(outcome))
  Assert.equal(outcome.result.marker, compiled.marker)
  Assert.equal(stagedBundle, compiled, "the dispatcher stages the family compiler bundle")
  Assert.equal(ArtifactJobs.sizeClass(kind), "normal")
  Assert.deepEqual(ArtifactJobs.dependencies(kind, "global", {}), {})
end

function T.common_session_compiles_items_through_the_single_dispatcher()
  checkDispatch(
    "romdump.src.digest.items.ItemCatalogCompiler",
    "romdump.src.digest.items.ItemCacheWriter",
    { marker = "items-marker" },
    "items"
  )
end

function T.common_session_compiles_bag_through_the_single_dispatcher()
  checkDispatch(
    "romdump.src.digest.ui.BagAssetCompiler",
    "romdump.src.digest.ui.BagCacheWriter",
    { marker = "bag-marker" },
    "bag"
  )
end

return { tests = T }
