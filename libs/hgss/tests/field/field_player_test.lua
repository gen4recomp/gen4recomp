-- FieldPlayer tests freeze eight-tick commits, collision, buffering, and
-- continuous height sampling without depending on LÖVE or imported data.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")

local T = {}

local EMPTY_MAP_PROPS = {}
---@cast EMPTY_MAP_PROPS MapProps

local ROOT_HALF = math.sqrt(0.5)

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(err.code, code, "expected " .. code .. ", got " .. Errors.format(err))
  return err
end

local function near(actual, expected)
  Assert.isTrue(math.abs(actual - expected) <= 1e-9, string.format("expected %.9f, got %.9f", expected, actual))
end

local function runtimeMap(blocked, plates)
  plates = plates
    or {
      {
        id = 0,
        minX = 0,
        minZ = 0,
        maxX = 1,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 0,
        slopeClass = "flat",
      },
      {
        id = 1,
        minX = 1,
        minZ = 0,
        maxX = 3,
        maxZ = 32,
        normal = { x = -ROOT_HALF, y = ROOT_HALF, z = 0 },
        distance = -ROOT_HALF,
        slopeClass = "ramp-east",
      },
      {
        id = 2,
        minX = 3,
        minZ = 0,
        maxX = 32,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 2,
        slopeClass = "flat",
      },
    }
  return {
    mapId = 60,
    mapSymbol = "test-map",
    mapSection = "test-section",
    mapSectionNativeId = 7,
    followMode = "ALLOW",
    coordinateOrigin = { x = 0, z = 0 },
    scene = {},
    fieldData = {},
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      isBlockedLocal = function(_, x, z)
        return blocked and blocked[x .. ":" .. z] or false
      end,
      getLocal = function()
        return { blocked = false }
      end,
    },
    terrain = TerrainSurface.new({ plates = plates }),
    terrainDependencyHash = "test-terrain",
    mapProps = EMPTY_MAP_PROPS,
    fieldRegion = {},
    cameraType = 0,
    release = function() end,
    updateAnimated = function() end,
  } --[[@as RuntimeFieldMap]]
end

---@param map RuntimeFieldMap
---@param x integer
---@param z integer
---@param surfaceId integer
---@param facing FieldDirection?
---@return FieldPlayer
local function player(map, x, z, surfaceId, facing)
  return FieldPlayer.new({ currentMap = map, fieldX = x, fieldZ = z, surfaceId = surfaceId, facing = facing or "south" })
end

function T.escalator_motion_is_horizontal_and_does_not_change_height()
  local p = player(runtimeMap(), 0, 4, 0)
  local startX, _, startZ = p.worldX, p.worldY, p.worldZ
  Assert.isTrue(p:beginTransitionStep("east"))
  for _ = 1, 16 do
    p:updateFixed()
  end
  near(p.worldX, startX + 1)
  Assert.equal(p.worldY, p:renderPosition(0).y)
  near(p.worldZ, startZ)
  Assert.equal(p.fieldX, 1)
end

function T.ladder_source_presentation_preserves_logical_ownership()
  local cases = {
    { method = "beginTransitionLadderExit", facing = "north", y = 2, z = 0 },
    { method = "beginTransitionLadderExit", facing = "south", y = 0.5, z = -1.5 },
    { method = "beginTransitionLadderDownExit", facing = "south", y = -2, z = 0 },
  }
  for _, case in ipairs(cases) do
    local p = player(runtimeMap(), 0, 4, 0)
    local start = {
      fieldX = p.fieldX,
      fieldZ = p.fieldZ,
      localX = p.localX,
      localZ = p.localZ,
      surfaceId = p.surfaceId,
      worldX = p.worldX,
      worldY = p.worldY,
      worldZ = p.worldZ,
    }
    Assert.isTrue(p[case.method](p, case.facing))
    for _ = 1, 8 do
      p:updateFixed({})
    end
    near(p.worldX, start.worldX)
    near(p.worldY, start.worldY + case.y / 2)
    near(p.worldZ, start.worldZ + case.z / 2)
    Assert.equal(p.fieldX, start.fieldX)
    Assert.equal(p.fieldZ, start.fieldZ)
    Assert.equal(p.localX, start.localX)
    Assert.equal(p.localZ, start.localZ)
    Assert.equal(p.surfaceId, start.surfaceId)

    for _ = 1, 8 do
      p:updateFixed({})
    end
    near(p.worldX, start.worldX)
    near(p.worldY, start.worldY + case.y)
    near(p.worldZ, start.worldZ + case.z)
    Assert.equal(p.motion, "idle")
    Assert.equal(p.fieldX, start.fieldX)
    Assert.equal(p.fieldZ, start.fieldZ)
    Assert.equal(p.localX, start.localX)
    Assert.equal(p.localZ, start.localZ)
    Assert.equal(p.surfaceId, start.surfaceId)
  end
end

function T.held_stair_presentation_moves_into_anchor_without_logical_movement()
  for _, case in ipairs({
    { facing = "west", offset = 1 },
    { facing = "east", offset = -1 },
  }) do
    local p = player(runtimeMap(), 2, 4, 0)
    local anchor = { x = p.worldX, y = p.worldY, z = p.worldZ }
    local start = { x = anchor.x + case.offset, y = anchor.y + 1, z = anchor.z }
    local logical = { p.fieldX, p.fieldZ, p.localX, p.localZ, p.surfaceId }

    Assert.isTrue(p:beginTransitionHeldStair(start, case.facing))
    near(p.worldX, start.x)
    near(p.worldY, start.y)
    near(p.worldZ, start.z)
    Assert.equal(p.motion, "transition")
    Assert.deepEqual({ p.fieldX, p.fieldZ, p.localX, p.localZ, p.surfaceId }, logical)

    for _ = 1, FieldPlayer.WALK_STEP_TICKS / 2 do
      p:updateFixed({})
    end
    Assert.isTrue((case.offset > 0 and p.worldX > anchor.x) or (case.offset < 0 and p.worldX < anchor.x))
    Assert.equal(p.motion, "transition")
    Assert.deepEqual({ p.fieldX, p.fieldZ, p.localX, p.localZ, p.surfaceId }, logical)

    for _ = FieldPlayer.WALK_STEP_TICKS / 2 + 1, FieldPlayer.WALK_STEP_TICKS do
      p:updateFixed({})
    end
    near(p.worldX, anchor.x)
    near(p.worldY, anchor.y)
    near(p.worldZ, anchor.z)
    Assert.equal(p.motion, "idle")
    Assert.deepEqual({ p.fieldX, p.fieldZ, p.localX, p.localZ, p.surfaceId }, logical)
  end
end

local function tick(p, held, pressed)
  p:updateFixed({ heldDirection = held, pressedDirection = pressed })
end

function T.accepted_step_commits_on_exactly_tick_eight()
  local p = player(runtimeMap(), 0, 4, 0, "east")
  for index = 1, 7 do
    tick(p, "east", index == 1 and "east" or nil)
    Assert.equal(p.fieldX, 0)
    Assert.equal(p.motion, "walking")
  end
  tick(p, "east")
  Assert.equal(p.fieldX, 1)
  Assert.equal(p.surfaceId, 1)
  Assert.equal(p.motion, "idle")
  near(p.worldY, 0.5)
end

function T.different_facing_input_turns_in_place_for_two_updates()
  local p = player(runtimeMap(), 0, 4, 0, "south")
  local start = {
    fieldX = p.fieldX,
    fieldZ = p.fieldZ,
    localX = p.localX,
    localZ = p.localZ,
    surfaceId = p.surfaceId,
    worldX = p.worldX,
    worldY = p.worldY,
    worldZ = p.worldZ,
  }

  local firstResult = p:updateFixed({ heldDirection = "north", pressedDirection = "north" })
  Assert.equal(p.facing, "north")
  Assert.equal(p.motion, "turning")
  Assert.equal(p.progressTicks, 1)
  Assert.equal(p.durationTicks, 2)
  Assert.isFalse(firstResult)
  Assert.equal(p.fieldX, start.fieldX)
  Assert.equal(p.fieldZ, start.fieldZ)
  Assert.equal(p.localX, start.localX)
  Assert.equal(p.localZ, start.localZ)
  Assert.equal(p.surfaceId, start.surfaceId)
  near(p.worldX, start.worldX)
  near(p.worldY, start.worldY)
  near(p.worldZ, start.worldZ)

  local secondResult = p:updateFixed({})
  Assert.equal(p.facing, "north")
  Assert.equal(p.motion, "idle")
  Assert.equal(p.progressTicks, 0)
  Assert.isFalse(secondResult)
  Assert.equal(p.fieldX, start.fieldX)
  Assert.equal(p.fieldZ, start.fieldZ)
  Assert.equal(p.localX, start.localX)
  Assert.equal(p.localZ, start.localZ)
  Assert.equal(p.surfaceId, start.surfaceId)
  near(p.worldX, start.worldX)
  near(p.worldY, start.worldY)
  near(p.worldZ, start.worldZ)
end

function T.different_facing_input_does_not_resolve_an_illegal_destination()
  local resolutionCalls = 0
  local map = runtimeMap({ ["0:3"] = true })
  map.collision.isBlockedLocal = function()
    resolutionCalls = resolutionCalls + 1
    return true
  end
  local p = player(map, 0, 4, 0, "south")

  Assert.isFalse(p:updateFixed({ heldDirection = "north", pressedDirection = "north" }))
  Assert.isFalse(p:updateFixed({}))
  Assert.equal(p.facing, "north")
  Assert.equal(p.motion, "idle")
  Assert.equal(p.fieldZ, 4)
  Assert.equal(resolutionCalls, 0)

  Assert.isFalse(p:updateFixed({ heldDirection = "north", pressedDirection = "north" }))
  Assert.equal(resolutionCalls, 1)
  Assert.equal(p.fieldZ, 4)
end

function T.disconnected_height_jump_is_rejected()
  local map = runtimeMap()
  map.terrain.plates[2].distance = 5 * ROOT_HALF
  local p = player(map, 0, 4, 0, "east")
  tick(p, "east", "east")
  Assert.equal(p.fieldX, 0)
  Assert.equal(p.motion, "idle")
end

function T.walking_samples_monotonic_slope_height()
  local p = player(runtimeMap(), 0, 4, 0, "east")
  local heights = {}
  for index = 1, 16 do
    tick(p, "east", index == 1 and "east" or nil)
    heights[#heights + 1] = p.worldY
  end
  for index = 2, #heights do
    Assert.isTrue(heights[index] >= heights[index - 1], "height decreased on ascent")
  end
  Assert.equal(p.fieldX, 2)
  Assert.equal(p.surfaceId, 1)
  near(p.worldY, 1.5)
end

function T.latest_pressed_direction_buffers_during_a_step()
  local p = player(runtimeMap(), 0, 4, 0, "east")
  tick(p, "east", "east")
  for _ = 2, 4 do
    tick(p, "east")
  end
  tick(p, "south", "south")
  for _ = 6, 8 do
    tick(p, "south")
  end
  Assert.equal(p.fieldX, 1)
  Assert.equal(p.fieldZ, 4)
  tick(p, "south")
  Assert.equal(p.motion, "walking")
  for _ = 2, 8 do
    tick(p, "south")
  end
  Assert.equal(p.fieldZ, 5)
end

function T.released_direction_during_a_step_is_not_remembered_by_the_player()
  local p = player(runtimeMap(), 0, 4, 0, "east")
  tick(p, "east", "east")
  tick(p, nil, "north")
  for _ = 3, 8 do
    tick(p)
  end

  Assert.equal(p.motion, "idle")
  Assert.equal(p.facing, "east")
  tick(p)
  Assert.equal(p.motion, "idle")
  Assert.equal(p.facing, "east")
end

function T.render_position_interpolates_previous_and_current_fixed_points()
  local p = player(runtimeMap(), 0, 4, 0)
  tick(p, "east", "east")
  local point = p:renderPosition(0.5)
  Assert.equal(point.x, p.previousWorldX + (p.worldX - p.previousWorldX) * 0.5)
  Assert.equal(point.y, p.previousWorldY + (p.worldY - p.previousWorldY) * 0.5)
end

-- Occupancy is an injected predicate so FieldPlayer never imports the actor
-- manager; it only needs truthy/nil answers per destination cell.
---@param map RuntimeFieldMap
---@param x integer
---@param z integer
---@param surfaceId integer
---@param occupantCells table<string, string>
---@return FieldPlayer
local function occupyingPlayer(map, x, z, surfaceId, occupantCells)
  local p = FieldPlayer.new({
    currentMap = map,
    fieldX = x,
    fieldZ = z,
    surfaceId = surfaceId,
    facing = "east",
    occupancy = function(candidate)
      local key = candidate.fieldX .. ":" .. candidate.fieldZ .. ":" .. candidate.surfaceId
      return occupantCells[key] or nil
    end,
  })
  return p
end

function T.actor_on_the_resolved_destination_surface_blocks_the_step()
  local p = occupyingPlayer(runtimeMap(), 0, 4, 0, { ["1:4:1"] = "map:61:object:0" })
  tick(p, "east", "east")
  Assert.equal(p.facing, "east")
  Assert.equal(p.fieldX, 0)
  Assert.equal(p.motion, "idle")
end

function T.actor_on_a_different_surface_does_not_block_the_same_cell()
  -- The east step resolves onto surface 1; an occupant on surface 0 at the
  -- same cell must not block it.
  local p = occupyingPlayer(runtimeMap(), 0, 4, 0, { ["1:4:0"] = "map:61:object:0" })
  tick(p, "east", "east")
  Assert.equal(p.motion, "walking")
  for _ = 2, 8 do
    tick(p, "east")
  end
  Assert.equal(p.fieldX, 1)
  Assert.equal(p.surfaceId, 1)
end

function T.terrain_rejection_takes_precedence_over_occupancy()
  -- A disconnected height jump fails surface resolution before occupancy is
  -- ever consulted.
  local map = runtimeMap()
  map.terrain.plates[2].distance = 5 * ROOT_HALF
  local p = occupyingPlayer(map, 0, 4, 0, { ["1:4:1"] = "map:61:object:0" })
  tick(p, "east", "east")
  Assert.equal(p.fieldX, 0)
  Assert.equal(p.motion, "idle")
end

-- Flat plate at the given height over the given x range; the fixture map
-- covers z 0..32 and keeps collision over 0..31.
local function flatPlate(id, minX, maxX, distance)
  return {
    id = id,
    minX = minX,
    minZ = 0,
    maxX = maxX,
    maxZ = 32,
    normal = { x = 0, y = 1, z = 0 },
    distance = distance,
    slopeClass = "flat",
  }
end

function T.malformed_terrain_failure_is_not_a_blocked_step()
  -- The destination cell is inside permission coverage but no walkable
  -- surface covers it: malformed terrain must propagate, not silently read
  -- as a blocked step.
  local map = runtimeMap(nil, {
    flatPlate(0, 0, 1, 0),
    flatPlate(1, 2, 32, 0),
  })
  local p = player(map, 0, 4, 0)
  throwsCode("TERRAIN_SURFACE_NOT_FOUND", function()
    p:tryStep("east")
  end)
end

function T.ambiguous_terrain_failure_is_not_a_blocked_step()
  -- Two equally-near surfaces cover the destination: ambiguous terrain must
  -- propagate instead of being swallowed as an ordinary collision.
  local map = runtimeMap(nil, {
    flatPlate(0, 0, 1, 0),
    flatPlate(1, 1, 32, 0),
    flatPlate(2, 1, 32, 0),
  })
  local p = player(map, 0, 4, 0)
  throwsCode("TERRAIN_SURFACE_AMBIGUOUS", function()
    p:tryStep("east")
  end)
end

function T.current_disconnected_terrain_failure_is_not_a_blocked_step()
  -- The player's claimed surface does not cover the player's own position:
  -- an inconsistent current terrain state must propagate.
  local map = runtimeMap(nil, {
    flatPlate(0, 2, 32, 0),
    flatPlate(1, 0, 32, 0),
  })
  local p = player(map, 0, 4, 0)
  local err = throwsCode("TERRAIN_SURFACE_DISCONNECTED", function()
    p:tryStep("east")
  end)
  Assert.equal(err.context.kind, "current-inconsistent")
end

function T.out_of_coverage_step_remains_blocked()
  -- Stepping past the coverage edge is the intended edge-of-map contract: a
  -- blocked move, not an error.
  local p = player(runtimeMap(), 31, 4, 2, "east")
  tick(p, "east", "east")
  Assert.equal(p.fieldX, 31)
  Assert.equal(p.motion, "idle")
end

function T.occupancy_blocks_only_the_cell_it_names()
  local p = occupyingPlayer(runtimeMap(), 0, 4, 0, { ["3:4:2"] = "map:61:object:0" })
  tick(p, "east", "east")
  Assert.equal(p.motion, "walking")
  for _ = 2, 16 do
    tick(p, "east")
  end
  Assert.equal(p.fieldX, 2)
end

function T.scripted_step_walks_into_a_blocked_permission_cell()
  local p = player(runtimeMap({ ["0:3"] = true }), 0, 4, 0)
  Assert.isTrue(p:scriptedStep("north"))
  Assert.equal(p.facing, "north")
  Assert.equal(p.motion, "walking")
  for _ = 1, 7 do
    tick(p)
    Assert.equal(p.motion, "walking")
  end
  tick(p)
  Assert.equal(p.fieldX, 0)
  Assert.equal(p.fieldZ, 3)
  Assert.equal(p.motion, "idle")
end

function T.scripted_step_ignores_dynamic_occupancy()
  local p = occupyingPlayer(runtimeMap(), 0, 4, 0, { ["1:4:1"] = "map:61:object:0" })
  Assert.isTrue(p:scriptedStep("east"))
  for _ = 1, 8 do
    tick(p)
  end
  Assert.equal(p.fieldX, 1)
  Assert.equal(p.surfaceId, 1)
end

function T.scripted_step_fails_without_a_destination_surface()
  local p = player(runtimeMap(), 0, 4, 0)
  Assert.isFalse(p:scriptedStep("west"))
  Assert.equal(p.motion, "idle")
  Assert.equal(p.fieldX, 0)
end

function T.scripted_step_rejects_an_elevation_jump()
  local map = runtimeMap()
  map.terrain.plates[2].distance = 5 * ROOT_HALF
  local p = player(map, 0, 4, 0)
  Assert.isFalse(p:scriptedStep("east"))
  Assert.equal(p.motion, "idle")
end

function T.scripted_step_requires_an_idle_player()
  local p = player(runtimeMap(), 0, 4, 0)
  tick(p, "east", "east")
  local ok, err = pcall(function()
    p:scriptedStep("east")
  end)
  Assert.isFalse(ok, "a scripted step cannot begin mid-walk")
  Assert.notNil(err)
end

-- These fixtures use the normalized HGSS behavior bytes that the production
-- collision contract already carries. They deliberately keep permission open:
-- traversal semantics must classify the behavior before ordinary stepping.
local NAVIGATION_BEHAVIORS = {
  riverWater = 16,
  whirlpool = 17,
  waterfall = 19,
  seaWater = 21,
  jumpEast = 56,
  jumpNorth = 57,
  jumpWest = 58,
  jumpSouth = 59,
  rockClimbEastWest = 75,
  rockClimbNorthSouth = 76,
}

local function behaviorMap(behavior, plates)
  local map = runtimeMap(nil, plates)
  map.collision.getLocal = function(_, x, z)
    if x == 1 and z == 4 then
      return { blocked = false, behavior = behavior }
    end
    return { blocked = false, behavior = 0 }
  end
  return map
end

function T.wrong_direction_and_invalid_ledge_landings_do_not_displace()
  local wrongDirectionMap = behaviorMap(NAVIGATION_BEHAVIORS.jumpEast)
  wrongDirectionMap.collision.getLocal = function(_, x, z)
    return { blocked = false, behavior = x == 0 and z == 3 and NAVIGATION_BEHAVIORS.jumpEast or 0 }
  end
  local wrongDirection = player(wrongDirectionMap, 0, 4, 0, "north")
  tick(wrongDirection, "north", "north")
  Assert.equal(wrongDirection.fieldX, 0)
  Assert.equal(wrongDirection.fieldZ, 4)
  Assert.equal(wrongDirection.motion, "idle")

  local blockedLandingMap = behaviorMap(NAVIGATION_BEHAVIORS.jumpEast)
  blockedLandingMap.collision.isBlockedLocal = function(_, x, z)
    return x == 2 and z == 4
  end
  local blockedLanding = player(blockedLandingMap, 0, 4, 0, "east")
  tick(blockedLanding, "east", "east")
  Assert.equal(blockedLanding.fieldX, 0)
  Assert.equal(blockedLanding.fieldZ, 4)
  Assert.equal(blockedLanding.motion, "idle")

  local occupiedLanding = player(behaviorMap(NAVIGATION_BEHAVIORS.jumpEast), 0, 4, 0, "east")
  occupiedLanding.occupancy = function(candidate)
    return candidate.fieldX == 2 and candidate.fieldZ == 4 and "map:61:object:0" or nil
  end
  tick(occupiedLanding, "east", "east")
  Assert.equal(occupiedLanding.fieldX, 0)
  Assert.equal(occupiedLanding.fieldZ, 4)
  Assert.equal(occupiedLanding.motion, "idle")

  local outOfCoverageMap = runtimeMap()
  outOfCoverageMap.collision.getLocal = function(_, x, z)
    return { blocked = false, behavior = x == 31 and z == 4 and NAVIGATION_BEHAVIORS.jumpEast or 0 }
  end
  local outOfCoverage = player(outOfCoverageMap, 30, 4, 2, "east")
  tick(outOfCoverage, "east", "east")
  Assert.equal(outOfCoverage.fieldX, 30)
  Assert.equal(outOfCoverage.fieldZ, 4)
  Assert.equal(outOfCoverage.motion, "idle")

  local malformedLanding = behaviorMap(NAVIGATION_BEHAVIORS.jumpEast, { flatPlate(0, 0, 1, 0), flatPlate(1, 3, 32, 0) })
  local malformedPlayer = player(malformedLanding, 0, 4, 0, "east")
  throwsCode("TERRAIN_SURFACE_NOT_FOUND", function()
    malformedPlayer:tryStep("east")
  end)
end

function T.field_move_behaviors_do_not_start_ordinary_walking()
  for _, behavior in pairs({
    NAVIGATION_BEHAVIORS.riverWater,
    NAVIGATION_BEHAVIORS.seaWater,
    NAVIGATION_BEHAVIORS.waterfall,
    NAVIGATION_BEHAVIORS.whirlpool,
    NAVIGATION_BEHAVIORS.rockClimbEastWest,
    NAVIGATION_BEHAVIORS.rockClimbNorthSouth,
  }) do
    local p = player(behaviorMap(behavior), 0, 4, 0, "east")
    tick(p, "east", "east")
    Assert.equal(p.fieldX, 0)
    Assert.equal(p.fieldZ, 4)
    Assert.equal(p.motion, "idle")
    Assert.equal(p.facing, "east")
  end
end

function T.direction_matching_ledge_commits_a_two_tile_sixteen_tick_jump()
  local p = player(behaviorMap(NAVIGATION_BEHAVIORS.jumpEast), 0, 4, 0, "east")
  local startX, startZ = p.fieldX, p.fieldZ
  local startWorldX, startWorldY = p.worldX, p.worldY

  tick(p, "east", "east")
  Assert.equal(p.motion, "jumping")
  for _ = 1, 14 do
    tick(p, "east")
    Assert.equal(p.fieldX, startX)
    Assert.equal(p.fieldZ, startZ)
    Assert.equal(p.motion, "jumping")
    Assert.isTrue(p.worldX > startWorldX and p.worldX < startWorldX + 2)
    Assert.isTrue(p.worldY > startWorldY)
  end

  local committed = p:updateFixed({ heldDirection = "east" })
  Assert.isTrue(committed)
  Assert.equal(p.fieldX, startX + 2)
  Assert.equal(p.fieldZ, startZ)
  Assert.equal(p.motion, "idle")
end

function T.normal_steps_preserve_source_surface_identity_for_effects()
  local map = runtimeMap()
  map.terrain:plate(0).cellKey = "0:0"
  map.terrain:plate(0).sourceSurfaceId = 0
  map.terrain:plate(1).cellKey = "0:0"
  map.terrain:plate(1).sourceSurfaceId = 1
  local p = player(map, 0, 4, 0, "east")

  Assert.isTrue(p:tryStep("east"))
  for _ = 1, FieldPlayer.WALK_STEP_TICKS do
    p:updateFixed({})
  end

  Assert.equal(p.fieldX, 1)
  Assert.equal(p.committedSourceCellKey, "0:0")
  Assert.equal(p.committedSourceSurfaceId, 1)
end

function T.direction_tap_during_a_turn_is_not_remembered_by_the_player()
  local p = player(runtimeMap(), 0, 4, 0, "south")
  tick(p, "north", "north")
  Assert.equal(p.motion, "turning")
  tick(p, nil, "west")
  Assert.equal(p.motion, "idle")
  Assert.equal(p.facing, "north")
  Assert.equal(p.fieldX, 0)
  Assert.equal(p.fieldZ, 4)

  tick(p)
  Assert.equal(p.motion, "idle")
  Assert.equal(p.facing, "north")
  Assert.equal(p.fieldX, 0)
  Assert.equal(p.fieldZ, 4)
end

function T.physical_probe_occupancy_preserves_stable_source_identity()
  local queriedCandidate
  local map = runtimeMap()
  map.terrain.plates[1].cellKey = "0:0"
  map.terrain.plates[1].sourceSurfaceId = 0
  local coverage = {
    index = {},
    matrixMemberId = 1,
    loadCell = function() end,
    presentationLoader = nil,
    cells = {},
    anchorX = 0,
    anchorZ = 0,
    origin = { x = 0, y = 0, z = 0 },
    region = {},
    terrainDependencyHash = "test-coverage",
    released = false,
  }
  ---@cast coverage FieldCoverage
  map.coverage = coverage
  function coverage:containsGlobal()
    return false
  end
  map.probePhysicalCell = function()
    return {
      cellKey = "1:0",
      sourceSurfaceId = 0,
      worldY = 0,
      collision = { blocked = false },
    }
  end
  map.fieldRegion = {
    sourceSurface = function(_, cellKey, sourceSurfaceId)
      if cellKey == "1:0" and sourceSurfaceId == 0 then
        return 7
      end
      return nil
    end,
  }
  local p = FieldPlayer.new({
    currentMap = map,
    fieldX = 31,
    fieldZ = 4,
    surfaceId = 0,
    facing = "east",
    occupancy = function(candidate)
      queriedCandidate = candidate
      return candidate.cellKey == "1:0" and candidate.sourceSurfaceId == 0 and "solid-destination" or nil
    end,
  })

  Assert.isFalse(p:tryStep("east"))
  Assert.equal(queriedCandidate.fieldX, 32)
  Assert.equal(queriedCandidate.fieldZ, 4)
  Assert.isNil(queriedCandidate.surfaceId)
  Assert.equal(queriedCandidate.cellKey, "1:0")
  Assert.equal(queriedCandidate.sourceSurfaceId, 0)
end

return { tests = T }
