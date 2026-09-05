-- Production-composed contract for Elm's Lab runtime starter props: the real
-- generated scene must publish a semantic, cache-backed descriptor before
-- field scripts can request its map-lifetime placements. The runtime is
-- restarted through the acceptance save boundary to prove the descriptor is
-- reconstructed from generated data rather than persisted prop state. The
-- render trap remains active throughout.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local MapAssetCache = require("libs.assets.src.MapAssetCache")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "elm", "starter", "runtime-props" },
  },
  tests = {},
}

local MAP = "MAP_NEW_BARK_ELMS_LAB_1F"

local function isFinite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function assertIdentityTransform(transform, label)
  Assert.equal(type(transform), "table", label .. " has a transform")
  local expected = {
    [1] = 1,
    [2] = 0,
    [3] = 0,
    [5] = 0,
    [6] = 1,
    [7] = 0,
    [9] = 0,
    [10] = 0,
    [11] = 1,
    [16] = 1,
  }
  for index, value in pairs(expected) do
    Assert.equal(transform[index], value, label .. " preserves ordinary model rotation/scale")
  end
  for _, index in ipairs({ 4, 8, 12, 13, 14, 15 }) do
    Assert.isTrue(isFinite(transform[index]), label .. " has finite normalized translation")
  end
end

local function descriptor(game)
  local scene = assert(game.runtime.runtimeMap and game.runtime.runtimeMap.scene, "Elm's generated scene is loaded")
  local runtimeProps = assert(scene.runtimeProps, "Elm's generated scene publishes runtime props")
  local starterBalls = assert(runtimeProps.starterBalls, "Elm's scene publishes starter-ball props")
  Assert.equal(type(starterBalls.model), "string", "starter-ball props use a semantic model key")
  Assert.isTrue(starterBalls.model ~= "", "starter-ball model key is non-empty")
  Assert.equal(type(starterBalls.placements), "table", "starter-ball props publish placements")
  Assert.equal(#starterBalls.placements, 3, "Elm publishes the complete source placement set")
  Assert.isTrue(
    game.runtime.cacheFs:exists(MapAssetCache.modelPath(starterBalls.model), "file"),
    "the runtime-prop model is present in the validated generated cache"
  )
  for index, placement in ipairs(starterBalls.placements) do
    Assert.equal(type(placement), "table", "starter-ball placement " .. index .. " is a record")
    assertIdentityTransform(placement.transform, "starter-ball placement " .. index)
  end
  return starterBalls
end

function T.tests.elm_lab_runtime_starter_props_rebuild_after_production_restart()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = AcceptanceHarness.new():boot({
    versionId = versionId,
    map = MAP,
    save = "fresh",
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local first = descriptor(game)
    local firstModel = first.model

    game:save()
    game:restart()
    game:waitForFieldEntry()
    local reloaded = descriptor(game)

    Assert.equal(reloaded.model, firstModel, "a production restart reuses the same generated model identity")
    Assert.isNil(game.runtime.errorText, "reloading Elm's Lab does not fault")
    Assert.equal(game:renderAttempts(), 0, "runtime-prop acceptance stops before GPU rendering")
  end, debug.traceback)
  local namespace = game.saveNamespace
  game:close()
  if not ok then
    error(err, 0)
  end
  Assert.equal(game.lifecycle.runtimeDisposals, 2, "restart and close dispose each runtime exactly once")
  Assert.isNil(love.filesystem.getInfo(namespace), "the isolated acceptance save namespace is removed")
end

return T
