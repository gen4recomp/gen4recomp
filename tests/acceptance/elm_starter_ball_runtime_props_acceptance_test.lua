-- Elm's Lab starter-ball registration: the three generated runtime-prop
-- transforms must join the same centred lab scene frame as ordinary map
-- geometry. The expected positions come from the retail map-prop base
-- translations combined with the lab cell origin resolved independently
-- through the generic map primitives (matrix resolution plus the centred-cell
-- convention production actors use) -- never from the starter production
-- transform or from the placements under test. The runtime is restarted
-- through the acceptance save boundary to prove the descriptor is
-- reconstructed from generated data rather than persisted prop state. The
-- render trap remains active throughout.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapResolver = require("romdump.src.digest.map.MapResolver")
local MapUnits = require("romdump.src.digest.map.MapUnits")
local FieldGrid = require("libs.hgss.src.world.FieldGrid")
local RomFs = require("romdump.src.source.RomFs")
local StarterLab = require("romdump.src.reference.hgss.starter_lab")

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

-- The expected final-scene ball translations, derived without touching the
-- starter production transform: each retail base translation normalized once
-- through the shared model-unit scale, composed with the lab cell origin.
-- Ordinary lab geometry centres the 32-tile cell on the world origin, so the
-- cell corner (source tile (0,0)) sits at worldOrigin - half a cell; the balls
-- must ride the same origin term as the room and its machines.
local function expectedTranslations(versionId)
  local romFs = assert(RomFs.open(versionId), "the lab scene origin resolves from a ready dump")
  local resolved, resolveErr = MapResolver.resolve(romFs, MAP)
  romFs:close()
  assert(resolved, resolveErr and resolveErr.message or "Elm's Lab resolves to a matrix cell")
  local halfCell = FieldGrid.CELL_TILES / 2
  local origin = { x = resolved.worldOriginX - halfCell, y = 0, z = resolved.worldOriginZ - halfCell }
  Assert.isTrue(origin.x ~= 0 or origin.z ~= 0, "the lab scene origin term is established, not omitted")
  local out = {}
  for index, position in ipairs(StarterLab.positions) do
    local x, y, z = MapUnits.toTiles(position.x, position.y, position.z)
    out[index] = { x = origin.x + x, y = origin.y + y, z = origin.z + z, nx = x, ny = y, nz = z }
  end
  return out, origin
end

local function descriptor(game, expected, origin)
  local scene = assert(game.runtime.runtimeMap and game.runtime.runtimeMap.scene, "Elm's generated scene is loaded")
  local runtimeProps = assert(scene.runtimeProps, "Elm's generated scene publishes runtime props")
  local starterBalls = assert(runtimeProps.starter_balls, "Elm's scene publishes starter-ball props")
  Assert.equal(type(starterBalls.model), "string", "starter-ball props use a semantic model key")
  Assert.isTrue(starterBalls.model ~= "", "starter-ball model key is non-empty")
  Assert.equal(type(starterBalls.placements), "table", "starter-ball props publish placements")
  Assert.equal(#starterBalls.placements, 3, "Elm publishes the complete source placement set")
  Assert.equal(#expected, 3, "the independent oracle covers the complete source placement set")
  Assert.isTrue(
    game.runtime.cacheFs:exists(MapAssetCache.modelPath(starterBalls.model), "file"),
    "the runtime-prop model is present in the validated generated cache"
  )
  for index, placement in ipairs(starterBalls.placements) do
    Assert.equal(type(placement), "table", "starter-ball placement " .. index .. " is a record")
    assertIdentityTransform(placement.transform, "starter-ball placement " .. index)
  end
  for index, want in ipairs(expected) do
    local transform = starterBalls.placements[index].transform
    Assert.equal(transform[13], want.x, "starter-ball placement " .. index .. " joins the lab scene frame in x")
    Assert.equal(transform[14], want.y, "starter-ball placement " .. index .. " joins the lab scene frame in y")
    Assert.equal(transform[15], want.z, "starter-ball placement " .. index .. " joins the lab scene frame in z")
  end
  -- Adding the scene origin translates the group without distorting it: the
  -- pairwise deltas still carry the exact source relationships.
  for _, component in ipairs({ { transformIndex = 13, axis = "x" }, { transformIndex = 15, axis = "z" } }) do
    for first = 1, 2 do
      for second = first + 1, 3 do
        local pairLabel = "ball pairwise " .. component.axis .. " delta " .. first .. "->" .. second
        local got = starterBalls.placements[second].transform[component.transformIndex]
          - starterBalls.placements[first].transform[component.transformIndex]
        local want = expected[second][component.axis] - expected[first][component.axis]
        Assert.equal(got, want, pairLabel .. " preserves source spacing")
        local sourceDelta = (StarterLab.positions[second][component.axis] - StarterLab.positions[first][component.axis])
          / MapUnits.MODEL_UNITS_PER_TILE
        Assert.equal(got, sourceDelta, pairLabel .. " is source-exact")
      end
    end
  end
  -- Every placement shares one derived scene-origin component: the per-ball
  -- residual after removing its own normalized source translation equals the
  -- independently resolved origin.
  for index, want in ipairs(expected) do
    local transform = starterBalls.placements[index].transform
    Assert.equal(transform[13] - want.nx, origin.x, "placement " .. index .. " shares the scene-origin x component")
    Assert.equal(transform[14] - want.ny, origin.y, "placement " .. index .. " shares the scene-origin y component")
    Assert.equal(transform[15] - want.nz, origin.z, "placement " .. index .. " shares the scene-origin z component")
  end
  return starterBalls
end

function T.tests.elm_lab_runtime_starter_props_rebuild_after_production_restart()
  local versionId = AcceptanceHarness.defaultVersion()
  local expected, origin = expectedTranslations(versionId)
  local game = AcceptanceHarness.new():boot({
    versionId = versionId,
    map = MAP,
    save = "fresh",
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local first = descriptor(game, expected, origin)
    local firstModel = first.model

    game:save()
    game:restart()
    game:waitForFieldEntry()
    local reloaded = descriptor(game, expected, origin)

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
