-- One production-composed ROM-backed corridor proving obstacle handling,
-- streamed outdoor travel, logical-zone ownership, persistence, and the
-- existing discontinuous building transition lifecycle.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local RomFs = require("romdump.src.source.RomFs")
local NavigationFacts = require("tests.rom.support.NavigationFacts")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    derivedAssets = { "map:33", "map:60" },
    tags = { "field", "corridor", "navigation" },
  },
  tests = {},
}

local function uniqueActors(snapshot)
  local seen = {}
  for actorId in pairs(snapshot.actors) do
    Assert.isNil(seen[actorId], "active actor IDs must be unique")
    seen[actorId] = true
  end
end

local function freezeAutonomousActors(game)
  local runtime = game.runtime
  for mapId in pairs(runtime.actors.maps) do
    for _, actor in ipairs(runtime.actors:actorsOf(mapId)) do
      runtime.actors:setMovementType(actor.actorId, "stationary")
    end
  end
end

local function assertResident(snapshot)
  Assert.notNil(snapshot.coverage, "production coverage status is required")
  Assert.isTrue(snapshot.coverage.residentCount <= 9, "physical residency must remain bounded")
  Assert.equal(snapshot.coverage.anchorX, math.floor(snapshot.player.fieldX / 32))
  Assert.equal(snapshot.coverage.anchorZ, math.floor(snapshot.player.fieldZ / 32))
  Assert.equal(snapshot.player.fieldX, math.floor(snapshot.player.fieldX))
  Assert.equal(snapshot.player.fieldZ, math.floor(snapshot.player.fieldZ))
  uniqueActors(snapshot)
end

local function withVersion(fn)
  local harness = AcceptanceHarness.new()
  local versionId = AcceptanceHarness.defaultVersion()
  local romFs, err = RomFs.open(versionId)
  assert(romFs, tostring(err))
  local facts = NavigationFacts.discover(CacheFs.forVersion(versionId), romFs)
  romFs:close()
  local game = harness:boot({ versionId = versionId, map = "MAP_NEW_BARK", save = "fresh" })
  OpeningLifecycle.seedNewBarkWestExitScene(game)
  OpeningLifecycle.settleNewBarkFriendScene(game)
  freezeAutonomousActors(game)
  local ok, failure = xpcall(function()
    fn(game, facts)
    Assert.equal(game:renderAttempts(), 0, "navigation acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(failure, 0)
  end
end

local function moveTo(game, point)
  return game:moveTo({ fieldX = point.fieldX, fieldZ = point.fieldZ })
end

local function assertSeam(game, expectedMapId, expectedMapSymbol, label)
  local transition = assert(game.lastTransition, label .. " must publish a seam transition")
  local source = transition.source
  local destination = transition.destination
  local displacement = math.abs(destination.player.fieldX - source.player.fieldX)
    + math.abs(destination.player.fieldZ - source.player.fieldZ)
  Assert.equal(displacement, 1, label .. " must commit exactly one tile")
  Assert.equal(destination.mapId, expectedMapId)
  Assert.equal(destination.mapSymbol, expectedMapSymbol)
  Assert.equal(destination.transition.phase, "idle", label .. " must not start a fade transition")
  Assert.isNil(game.runtime.transition.sourceKind, label .. " must remain outside the warp transition lifecycle")

  -- The seam settles into one coherent active-map identity: the map-scoped
  -- script context and the live actor world both follow the destination, and
  -- the source map no longer owns a published actor entry. The destination's
  -- own entry lifecycle owns actor activation, so the settled boundary is
  -- reached before those observations.
  game:waitForFieldReady()
  freezeAutonomousActors(game)
  Assert.equal(
    game.runtime.scripts.initController.mapId,
    expectedMapId,
    label .. " map-scoped init rules must follow the destination"
  )
  Assert.equal(
    game.runtime.actors.currentMapId,
    expectedMapId,
    label .. " the active actor map must follow the destination"
  )
  Assert.isNil(
    game.runtime.actors.maps[source.mapId],
    label .. " the source actor entry must not remain active/published after the seam settles"
  )

  local origin =
    assert(destination.coverage and destination.coverage.physicalOrigin, label .. " physical origin is required")
  Assert.equal(destination.player.localX, destination.player.fieldX - origin.x, label .. " local X")
  Assert.equal(destination.player.localZ, destination.player.fieldZ - origin.z, label .. " local Z")
  Assert.near(destination.player.worldX, destination.player.localX - 15.5, 1e-9, label .. " world X")
  Assert.near(destination.player.worldZ, destination.player.localZ - 15.5, 1e-9, label .. " world Z")
  Assert.isTrue(
    math.abs(destination.player.worldX - destination.player.previousWorldX) < 1,
    label .. " current and previous X must share the physical frame"
  )
  Assert.isTrue(
    math.abs(destination.player.worldZ - destination.player.previousWorldZ) < 1,
    label .. " current and previous Z must share the physical frame"
  )
  Assert.notNil(destination.camera, label .. " camera frame is required")
  Assert.near(destination.camera.target.x, destination.player.worldX, 1e-9, label .. " camera target X")
  Assert.near(destination.camera.target.y, destination.player.worldY, 1e-9, label .. " camera target Y")
  Assert.near(destination.camera.target.z, destination.player.worldZ, 1e-9, label .. " camera target Z")
  for _, axis in ipairs({ "x", "y", "z" }) do
    Assert.near(
      destination.camera.eye[axis] - destination.camera.target[axis],
      source.camera.eye[axis] - source.camera.target[axis],
      1e-9,
      label .. " camera eye offset " .. axis
    )
  end
  -- `lastTransition` records only the first commit after it was last
  -- cleared; consume it so this corridor's later reverse crossing publishes
  -- its own fresh record instead of being silently ignored behind this one.
  game.lastTransition = nil
end

local function findEffect(snapshot, fieldX, fieldZ)
  for _, instance in ipairs(snapshot.terrainEffects.instances) do
    if instance.fieldX == fieldX and instance.fieldZ == fieldZ then
      return instance
    end
  end
  return nil
end

function T.tests.corridor_traverses_water_zone_streaming_grass_ledge_and_returns()
  withVersion(function(game, facts)
    local initial = game:snapshot()
    local physicalOwner = assert(game.runtime.physicalCoverage, "physical coverage owner is required")
    Assert.equal(game.runtime.runtimeMap.coverage, physicalOwner, "fresh boot must install one committed owner")
    assertResident(initial)

    local waterApproach = moveTo(game, facts.water.approach)
    local beforeWater = waterApproach.player
    game:move(facts.water.direction)
    local afterWater = game:advanceUntil("water rejection settles", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 32)
    Assert.equal(afterWater.player.fieldX, beforeWater.fieldX)
    Assert.equal(afterWater.player.fieldZ, beforeWater.fieldZ)
    Assert.equal(afterWater.player.facing, facts.water.direction)

    local route = game:moveTo(facts.zoneBoundary, 33)
    Assert.equal(route.mapId, 33)
    Assert.equal(route.transition.phase, "idle", "seam crossing must not start a transition")
    Assert.notNil(route.zoneChange, "seam crossing must publish zone ownership")
    assertSeam(game, 33, "MAP_ROUTE_29", "New Bark to Route 29")
    Assert.equal(game.runtime.physicalCoverage, physicalOwner, "seam crossing must preserve the physical world")
    Assert.equal(game.runtime.runtimeMap.coverage, physicalOwner, "same-matrix composition must reuse the owner")
    assertResident(route)

    local far = moveTo(game, facts.far)
    assertResident(far)
    local grass = moveTo(game, facts.grass)
    Assert.notNil(grass.terrainEffects, "terrain effect status is required")
    Assert.isTrue(#grass.terrainEffects.instances > 0, "grass displacement must emit an effect")
    local landedEffect = assert(
      findEffect(grass, grass.player.fieldX, grass.player.fieldZ),
      "the committed grass tile must own a semantic effect"
    )
    local anchorX, anchorZ = landedEffect.fieldX, landedEffect.fieldZ
    local anchorCellKey, anchorSurfaceId = landedEffect.cellKey, landedEffect.sourceSurfaceId
    for _ = 1, 13 do
      game:step()
    end
    local heldSnapshot = game:snapshot()
    local heldEffect = assert(
      findEffect(heldSnapshot, anchorX, anchorZ),
      "the grass effect must remain after its intro while the player is stationary"
    )
    Assert.equal(heldEffect.kind, landedEffect.kind)
    Assert.equal(heldEffect.cellKey, anchorCellKey)
    Assert.equal(heldEffect.sourceSurfaceId, anchorSurfaceId)
    Assert.equal(heldEffect.frame, 12)
    Assert.isTrue(heldEffect.age >= 13)
    assertResident(grass)

    local ledgeStart = moveTo(game, facts.ledge).player
    Assert.isNil(
      findEffect(game:snapshot(), anchorX, anchorZ),
      "moving off the grass anchor must remove its transient effect"
    )
    game:face(facts.ledge.direction)
    game:move(facts.ledge.direction)
    local landing = game:advanceUntil("ledge jump settles", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 48)
    Assert.equal(
      math.abs(landing.player.fieldX - ledgeStart.fieldX) + math.abs(landing.player.fieldZ - ledgeStart.fieldZ),
      2
    )
    assertResident(landing)

    local returned = moveTo(game, facts.newBark)
    assertSeam(game, facts.newBark.mapId, "MAP_NEW_BARK", "Route 29 to New Bark")
    Assert.equal(returned.player.fieldX, facts.newBark.fieldX)
    Assert.equal(returned.player.fieldZ, facts.newBark.fieldZ)
    Assert.equal(game.runtime.physicalCoverage, physicalOwner, "reverse seam must preserve the physical world")
    Assert.equal(
      game.runtime.runtimeMap.coverage,
      physicalOwner,
      "reverse same-matrix composition must reuse the owner"
    )
    Assert.equal(game.lifecycle.runtimeDisposals, 0, "the live return must occur before any save/restart")
    assertResident(returned)

    local farSavePosition = moveTo(game, facts.far)
    Assert.equal(farSavePosition.mapId, 33)
    Assert.equal(farSavePosition.player.fieldX, facts.far.fieldX)
    Assert.equal(farSavePosition.player.fieldZ, facts.far.fieldZ)
    assertResident(farSavePosition)
    local saved = game:save()
    local resumed = game:restart({ save = "resume" }):snapshot()
    Assert.equal(resumed.player.fieldX, saved.player.fieldX)
    Assert.equal(resumed.player.fieldZ, saved.player.fieldZ)
    Assert.equal(resumed.player.facing, saved.player.facing)
    Assert.equal(resumed.player.worldY, saved.player.worldY)
    Assert.equal(resumed.mapId, saved.mapId)
    Assert.equal(resumed.coverage.anchorX, saved.coverage.anchorX)
    Assert.equal(resumed.coverage.anchorZ, saved.coverage.anchorZ)
    Assert.equal(game.runtime.runtimeMap.coverage, game.runtime.physicalCoverage, "restore must install one owner")
    assertResident(resumed)
    local returnSnapshot = moveTo(game, facts.newBark)
    Assert.equal(returnSnapshot.mapId, facts.newBark.mapId)
    assertResident(returnSnapshot)
    local building = facts.buildingWarp
    moveTo(game, building)
    game:face(building.direction)
    game:move(building.direction)
    local started = game:advanceUntil("building transition starts", function(snapshot)
      return snapshot.transition.phase ~= "idle"
    end, 32)
    game:advanceUntil("building transition completes", function(snapshot)
      return snapshot.transition.phase == "idle" and snapshot.mapId ~= facts.newBark.mapId
    end, 120)
    local transition = { destination = game:snapshot() }
    Assert.isTrue(transition.destination.mapId ~= facts.newBark.mapId)
    Assert.isTrue(started.transition.phase ~= "idle")
    local interior = game:snapshot()
    Assert.isTrue(interior.mapId ~= facts.newBark.mapId)
    Assert.equal(#interior.terrainEffects.instances, 0)
    uniqueActors(interior)
    Assert.equal(interior.transition.phase, "idle")
  end)
end

return T
