-- Pure interaction-resolution tests: object-first
-- priority, background direction compatibility, surface reachability, and
-- immutable intent values. Uses synthetic maps and a fake actor lookup, so no
-- LÖVE or ROM data is involved.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldInteractionResolver = require("libs.hgss.src.interaction.FieldInteractionResolver")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")

local T = {}

local EMPTY_MAP_PROPS = {}
---@cast EMPTY_MAP_PROPS MapProps

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(err.code, code, "expected " .. code .. ", got " .. Errors.format(err))
  return err
end

-- A flat synthetic map centered at field origin (0,0) covering local
-- (0..31, 0..31). Optional background events with raw direction codes.
local function map(backgrounds)
  local value = {
    mapId = 61,
    mapSymbol = "test-map",
    mapSection = "test-section",
    mapSectionNativeId = 7,
    followMode = "ALLOW",
    cameraType = 4,
    coordinateOrigin = { x = 0, z = 0 },
    scene = {},
    fieldData = {
      scriptBankId = 843,
      messageBankId = 543,
      events = { background = backgrounds or {} },
    },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      isBlockedLocal = function()
        return false
      end,
    },
    terrain = TerrainSurface.new({
      plates = {
        {
          id = 0,
          minX = 0,
          minZ = 0,
          maxX = 32,
          maxZ = 32,
          normal = { x = 0, y = 1, z = 0 },
          distance = 0,
          slopeClass = "flat",
        },
      },
    }),
    terrainDependencyHash = "test-terrain",
    mapProps = EMPTY_MAP_PROPS,
    fieldRegion = {},
    release = function() end,
    updateAnimated = function() end,
  } --[[@as RuntimeFieldMap]]
  return value
end

local function bgEvent(index, scriptId, x, z, directionRaw, eventType)
  return {
    index = index,
    scriptId = scriptId,
    type = eventType or 0,
    hiddenItem = (eventType or 0) == 2,
    x = x,
    z = z,
    y = 0,
    directionRaw = directionRaw,
    direction = "unknown",
  }
end

local function actor(id, objectEventId, spriteId, x, z, scriptId)
  return {
    actorId = id,
    objectEventId = objectEventId,
    spriteId = spriteId,
    fieldX = x,
    fieldZ = z,
    surfaceId = 0,
    facing = "south",
    sourceEvent = { scriptId = scriptId },
  }
end

-- A map whose surface-0 plate covers z >= 14 and surface 1 covers z <= 14,
-- so a cell at z 13 is on the far side of a cross-surface boundary from a
-- player at z 14.
local function crossSurfaceMap(backgrounds)
  local m = map(backgrounds)
  m.terrain = TerrainSurface.new({
    plates = {
      {
        id = 0,
        minX = 0,
        minZ = 14.0,
        maxX = 32,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = 0,
        slopeClass = "flat",
      },
      {
        id = 1,
        minX = 0,
        minZ = 0,
        maxX = 32,
        maxZ = 14.0,
        normal = { x = 0, y = 1, z = 0 },
        distance = 0,
        slopeClass = "flat",
      },
    },
  })
  return m
end

-- Flat plate at the given height over the given z range.
local function flatPlate(id, minZ, maxZ, distance)
  return {
    id = id,
    minX = 0,
    minZ = minZ,
    maxX = 32,
    maxZ = maxZ,
    normal = { x = 0, y = 1, z = 0 },
    distance = distance,
    slopeClass = "flat",
  }
end

-- A map whose terrain is exactly the given plates. The base snapshot puts the
-- player at field (4, 14) on surface 0 facing north onto cell (4, 13).
local function terrainMap(plates, backgrounds)
  local m = map(backgrounds)
  m.terrain = TerrainSurface.new({ plates = plates })
  return m
end

-- resolver with an actor lookup table keyed by "x:z"
local function resolver(actorsByCell)
  local actorAt = function(_, candidate)
    local entry = actorsByCell and actorsByCell[candidate.fieldX .. ":" .. candidate.fieldZ]
    return entry and entry.surfaceId == candidate.surfaceId and entry.actor or nil
  end
  return FieldInteractionResolver.new({
    actorAt = actorAt,
    targetMapAt = function(_, _, currentMap)
      return currentMap
    end,
  })
end

local function baseSnapshot(overrides)
  local snapshot = {
    runtimeMap = map(),
    fieldX = 4,
    fieldZ = 14,
    surfaceId = 0,
    worldY = 0,
    facing = "north",
    tick = 100,
  }
  for key, value in pairs(overrides or {}) do
    snapshot[key] = value
  end
  return snapshot --[[@as InteractionResolverSnapshot]]
end

function T.background_direction_compatibility_matches_the_source_table()
  -- The pinned assembly's BgEventDirectionIsCompatibleWithPlayerFacing.
  Assert.isTrue(FieldInteractionResolver.backgroundDirectionCompatible(0, 0))
  Assert.isTrue(FieldInteractionResolver.backgroundDirectionCompatible(0, 6))
  Assert.isFalse(FieldInteractionResolver.backgroundDirectionCompatible(0, 3))
  Assert.isTrue(FieldInteractionResolver.backgroundDirectionCompatible(1, 3))
  Assert.isTrue(FieldInteractionResolver.backgroundDirectionCompatible(1, 6))
  Assert.isFalse(FieldInteractionResolver.backgroundDirectionCompatible(1, 0))
  Assert.isTrue(FieldInteractionResolver.backgroundDirectionCompatible(2, 2))
  Assert.isTrue(FieldInteractionResolver.backgroundDirectionCompatible(2, 5))
  Assert.isFalse(FieldInteractionResolver.backgroundDirectionCompatible(2, 1))
  Assert.isTrue(FieldInteractionResolver.backgroundDirectionCompatible(3, 1))
  Assert.isTrue(FieldInteractionResolver.backgroundDirectionCompatible(3, 5))
  Assert.isFalse(FieldInteractionResolver.backgroundDirectionCompatible(3, 0))
  for facing = 0, 3 do
    Assert.isTrue(
      FieldInteractionResolver.backgroundDirectionCompatible(facing, 4),
      "raw 4 is the wildcard for every facing"
    )
  end
end

function T.named_facing_mapping_agrees_with_the_zone_event_direction_normalization()
  -- The named -> raw mapping must agree with the decoder's raw -> named
  -- DIRECTIONS table so north/south are not accidentally inverted.
  local zoneDirections = { [0] = "north", [1] = "south", [2] = "west", [3] = "east" }
  for raw, named in pairs(zoneDirections) do
    Assert.equal(FieldInteractionResolver.RAW_FACING[named], raw)
  end
end

function T.settled_player_with_actor_ahead_resolves_an_object_intent()
  local elm = actor("map:61:object:0", 0, 99, 4, 13, 1)
  local r = resolver({ ["4:13"] = { surfaceId = 0, actor = elm } })
  local intent = r:resolve(baseSnapshot())
  assert(intent, "actor ahead must resolve")
  Assert.equal(intent.kind, "object")
  Assert.equal(intent.mapId, 61)
  Assert.equal(intent.sourceFieldX, 4)
  Assert.equal(intent.sourceFieldZ, 14)
  Assert.equal(intent.sourceSurfaceId, 0)
  Assert.equal(intent.targetFieldX, 4)
  Assert.equal(intent.targetFieldZ, 13)
  Assert.equal(intent.playerFacing, "north")
  Assert.equal(intent.scriptBankId, 843)
  Assert.equal(intent.scriptId, 1)
  Assert.equal(intent.object.actorId, "map:61:object:0")
  Assert.equal(intent.object.objectEventId, 0)
  Assert.equal(intent.object.spriteId, 99)
  Assert.isNil(intent.background)
  Assert.equal(intent.tick, 100)
end

function T.actor_and_background_ahead_object_wins()
  local elm = actor("map:61:object:0", 0, 99, 4, 13, 1)
  local r = resolver({ ["4:13"] = { surfaceId = 0, actor = elm } })
  local m = map({ bgEvent(0, 6, 4, 13, 0) })
  local intent = r:resolve(baseSnapshot({ runtimeMap = m }))
  assert(intent, "object priority wins over a co-located background event")
  Assert.equal(intent.kind, "object")
  Assert.equal(intent.object.actorId, "map:61:object:0")
end

function T.no_actor_with_compatible_background_resolves_a_background_intent()
  local m = map({ bgEvent(0, 6, 4, 13, 0) })
  local r = resolver()
  local intent = r:resolve(baseSnapshot({ runtimeMap = m }))
  assert(intent, "compatible background must resolve")
  Assert.equal(intent.kind, "background")
  Assert.equal(intent.targetFieldX, 4)
  Assert.equal(intent.targetFieldZ, 13)
  Assert.equal(intent.scriptId, 6)
  Assert.equal(intent.scriptBankId, 843)
  Assert.equal(intent.background.eventIndex, 0)
  Assert.equal(intent.background.type, 0)
  Assert.equal(intent.background.direction, 0)
  Assert.isNil(intent.object)
end

function T.incompatible_raw_direction_returns_nil()
  -- Facing north (raw 0) accepts {0, 6}; a south-facing event (raw 3) must not.
  local m = map({ bgEvent(0, 6, 4, 13, 3) })
  local r = resolver()
  Assert.isNil(r:resolve(baseSnapshot({ runtimeMap = m })))
end

function T.wildcard_direction_4_matches_every_facing()
  local facingCells = {
    north = { 4, 13 },
    south = { 4, 15 },
    west = { 3, 14 },
    east = { 5, 14 },
  }
  for _, facing in ipairs({ "north", "south", "west", "east" }) do
    local cell = facingCells[facing]
    local m = map({ bgEvent(0, 10, cell[1], cell[2], 4) })
    local r = resolver()
    local snapshot = baseSnapshot({ runtimeMap = m, facing = facing })
    local intent = r:resolve(snapshot)
    assert(intent, "raw 4 must match facing " .. facing)
    Assert.equal(intent.kind, "background")
  end
end

function T.vertical_and_horizontal_direction_rows()
  -- South-facing player (raw 1) accepts 3 and 6; west-facing (raw 2) accepts
  -- 2 and 5; east-facing (raw 3) accepts 1 and 5; a north event (raw 0) only
  -- pairs with a north-facing player. Events sit on the facing cell of each
  -- direction so only the direction compatibility is under test.
  local facingCells = {
    north = { 4, 13 },
    south = { 4, 15 },
    west = { 3, 14 },
    east = { 5, 14 },
  }
  local cases = {
    { facing = "south", compatible = { 3, 6 }, incompatible = { 0, 1, 2, 5 } },
    { facing = "west", compatible = { 2, 5 }, incompatible = { 0, 1, 3, 6 } },
    { facing = "east", compatible = { 1, 5 }, incompatible = { 0, 2, 3, 6 } },
    { facing = "north", compatible = { 0, 6 }, incompatible = { 1, 2, 3, 5 } },
  }
  for _, case in ipairs(cases) do
    local cell = facingCells[case.facing]
    for _, raw in ipairs(case.compatible) do
      local m = map({ bgEvent(0, 6, cell[1], cell[2], raw) })
      local intent = FieldInteractionResolver.new({
        actorAt = function()
          return nil
        end,
        targetMapAt = function(_, _, currentMap)
          return currentMap
        end,
      }):resolve(baseSnapshot({ runtimeMap = m, facing = case.facing }))
      assert(intent, "facing " .. case.facing .. " accepts raw " .. raw)
      Assert.equal(intent.kind, "background")
    end
    for _, raw in ipairs(case.incompatible) do
      local m = map({ bgEvent(0, 6, cell[1], cell[2], raw) })
      local intent = FieldInteractionResolver.new({
        actorAt = function()
          return nil
        end,
        targetMapAt = function(_, _, currentMap)
          return currentMap
        end,
      }):resolve(baseSnapshot({ runtimeMap = m, facing = case.facing }))
      Assert.isNil(intent, "facing " .. case.facing .. " rejects raw " .. raw)
    end
  end
end

function T.background_requires_exact_facing_cell_match()
  local m = map({ bgEvent(0, 6, 4, 12, 0) })
  local r = resolver()
  Assert.isNil(
    r:resolve(baseSnapshot({ runtimeMap = m })),
    "an event one cell short of the facing tile does not resolve"
  )
end

-- The hidden-item family is an explicit normalized declaration, not an
-- accidental eligibility gap: the named predicate is its single owner.
function T.is_hidden_item_identifies_the_hidden_item_marker()
  Assert.isTrue(
    FieldInteractionResolver.isHiddenItem({ hiddenItem = true }),
    "the hidden-item marker identifies the noninteractive family"
  )
  Assert.isFalse(FieldInteractionResolver.isHiddenItem({ hiddenItem = false }))
  Assert.isFalse(FieldInteractionResolver.isHiddenItem({ type = 2 }))
end

-- The resolver owns one surface resolver per terrain: resolving against a
-- second map with different terrain must not reuse the first map's surface
-- state (no stale selection across maps).
function T.resolving_across_maps_never_reuses_stale_terrain_state()
  local r = resolver()
  local first = assert(r:resolve(baseSnapshot({ runtimeMap = map({ bgEvent(0, 6, 4, 13, 0) }) })))
  Assert.equal(first.kind, "background")
  local second = assert(r:resolve(baseSnapshot({ runtimeMap = crossSurfaceMap({ bgEvent(0, 6, 4, 13, 0) }) })))
  Assert.equal(second.kind, "background")
  Assert.equal(second.background.eventIndex, 0)
end

-- The hidden-item family is declared noninteractive (hidden-item pickup depends
-- on collection flags that are not tracked); it resolves to nothing rather
-- than emitting an intent the client could never bind.
function T.hidden_item_background_events_are_skipped()
  local m = map({ bgEvent(0, 100, 4, 13, 4, 2) })
  local r = resolver()
  Assert.isNil(r:resolve(baseSnapshot({ runtimeMap = m })))
end

function T.hidden_item_does_not_block_a_later_compatible_event()
  local m = map({
    bgEvent(0, 100, 4, 13, 4, 2),
    bgEvent(1, 6, 4, 13, 0),
  })
  local r = resolver()
  local intent = r:resolve(baseSnapshot({ runtimeMap = m }))
  assert(intent, "the hidden-item record is skipped, the later compatible one wins")
  Assert.equal(intent.kind, "background")
  Assert.equal(intent.background.eventIndex, 1)
end

function T.script_id_zero_actor_is_an_interaction()
  local elm = actor("map:61:object:0", 0, 99, 4, 13, 0)
  local r = resolver({ ["4:13"] = { surfaceId = 0, actor = elm } })
  local m = map({ bgEvent(0, 6, 4, 13, 0) })
  local intent = assert(r:resolve(baseSnapshot({ runtimeMap = m })))
  Assert.equal(intent.kind, "object")
  Assert.equal(intent.scriptId, 0)
end

function T.script_id_zero_background_is_an_interaction()
  local m = map({ bgEvent(0, 0, 4, 13, 0) })
  local r = resolver()
  local intent = assert(r:resolve(baseSnapshot({ runtimeMap = m })))
  Assert.equal(intent.kind, "background")
  Assert.equal(intent.scriptId, 0)
end

function T.hidden_actor_leaves_the_background_to_win()
  local m = map({ bgEvent(0, 6, 4, 13, 0) })
  local r = resolver({}) -- no actor at the cell (hidden actors are not in the index)
  local intent = r:resolve(baseSnapshot({ runtimeMap = m }))
  assert(intent, "no visible actor means the background may win")
  Assert.equal(intent.kind, "background")
end

function T.cross_surface_facing_cell_looks_up_the_actor_on_the_target_surface()
  -- The facing cell lies outside the player's surface-0 plate but inside
  -- surface 1's, so the reachable crossing resolves the target to surface 1.
  -- The actor lookup must use the RESOLVED target surface, not the player's
  -- source surface.
  local elm = actor("map:61:object:0", 0, 99, 4, 13, 1)
  local r = resolver({ ["4:13"] = { surfaceId = 1, actor = elm } })
  local intent = r:resolve(baseSnapshot({ runtimeMap = crossSurfaceMap() }))
  assert(intent, "actor on the resolved target surface must be found")
  Assert.equal(intent.kind, "object")
  Assert.equal(intent.object.actorId, "map:61:object:0")
end

function T.cross_surface_miss_leaves_a_compatible_background_to_win()
  -- Same boundary as above, but no actor sits on the resolved target surface:
  -- the compatible background on the facing cell still resolves.
  local r = resolver()
  local intent = r:resolve(baseSnapshot({ runtimeMap = crossSurfaceMap({ bgEvent(0, 6, 4, 13, 0) }) }))
  assert(intent, "background on the cross-surface facing cell must resolve")
  Assert.equal(intent.kind, "background")
  Assert.equal(intent.background.eventIndex, 0)
end

function T.actor_on_another_surface_is_ineligible()
  -- The actor occupies surface 1 while the player stands on surface 0, so the
  -- occupancy lookup misses and the compatible background on the facing cell
  -- wins: different surfaces do not interact.
  local elm = actor("map:61:object:0", 0, 99, 4, 13, 1)
  local actorAt = function(_, candidate)
    if candidate.surfaceId == 0 then
      return nil
    end
    return elm
  end
  local m = map({ bgEvent(0, 6, 4, 13, 0) })
  local r = FieldInteractionResolver.new({
    actorAt = actorAt,
    targetMapAt = function(_, _, currentMap)
      return currentMap
    end,
  })
  local intent = r:resolve(baseSnapshot({ runtimeMap = m }))
  assert(intent, "the background on the reachable surface wins")
  Assert.equal(intent.kind, "background")
end

function T.facing_outside_coverage_returns_nil()
  local m = map()
  -- Player at the coverage edge facing north would step outside the map.
  local r = resolver()
  Assert.isNil(r:resolve(baseSnapshot({ runtimeMap = m, fieldZ = 0, facing = "north" })))
end

function T.malformed_terrain_failure_propagates_instead_of_nothing_there()
  -- The facing cell has permission coverage but no walkable surface: that is
  -- malformed terrain, not "nothing interactable there".
  local m = terrainMap({
    flatPlate(0, 14, 32, 0),
  })
  local r = resolver()
  throwsCode("TERRAIN_SURFACE_NOT_FOUND", function()
    r:resolve(baseSnapshot({ runtimeMap = m }))
  end)
end

function T.ambiguous_terrain_failure_propagates_instead_of_nothing_there()
  -- Two equally-near surfaces cover the facing cell: ambiguous terrain must
  -- propagate rather than silently reading as a miss.
  local m = terrainMap({
    flatPlate(0, 14, 32, 0),
    flatPlate(1, 0, 14, 0),
    flatPlate(2, 0, 14, 0),
  })
  local r = resolver()
  throwsCode("TERRAIN_SURFACE_AMBIGUOUS", function()
    r:resolve(baseSnapshot({ runtimeMap = m }))
  end)
end

function T.disconnected_current_terrain_failure_propagates_instead_of_nothing_there()
  -- The player's claimed surface does not cover the player's own position:
  -- an inconsistent current terrain state must propagate.
  local m = terrainMap({
    flatPlate(0, 15, 32, 0),
    flatPlate(1, 0, 14, 0),
  })
  local r = resolver()
  local err = throwsCode("TERRAIN_SURFACE_DISCONNECTED", function()
    r:resolve(baseSnapshot({ runtimeMap = m }))
  end)
  Assert.equal(err.context.kind, "current-inconsistent")
end

function T.unreachable_height_facing_cell_means_nothing_there()
  -- The facing cell is beyond the reachable step height: an expected
  -- boundary, so "nothing interactable there" instead of a raised error.
  local m = terrainMap({
    flatPlate(0, 14, 32, 0),
    flatPlate(1, 0, 14, 2),
  })
  local r = resolver()
  Assert.isNil(r:resolve(baseSnapshot({ runtimeMap = m })))
end

function T.intent_values_survive_source_mutation()
  local elm = actor("map:61:object:0", 0, 99, 4, 13, 1)
  local r = resolver({ ["4:13"] = { surfaceId = 0, actor = elm } })
  local intent = assert(r:resolve(baseSnapshot()))
  elm.facing = "east"
  elm.actorId = "mutated"
  elm.sourceEvent.scriptId = 999
  Assert.equal(intent.object.actorId, "map:61:object:0")
  Assert.equal(intent.scriptId, 1)
  Assert.equal(intent.playerFacing, "north")
end

function T.cross_map_background_uses_target_events_and_identity()
  local source = map()
  source.terrain = TerrainSurface.new({ plates = { flatPlate(0, 0, 32, 0) } })
  local target = map({ bgEvent(7, 19, 4, 13, 0) })
  target.mapId = 62
  target.fieldData.scriptBankId = 912
  local lookups = {}
  local crossMapResolver = FieldInteractionResolver.new({
    actorAt = function(mapId, candidate)
      lookups.actorMapId = mapId
      lookups.candidate = candidate
      return nil
    end,
    targetMapAt = function(fieldX, fieldZ, currentMap)
      Assert.equal(fieldX, 4)
      Assert.equal(fieldZ, 13)
      Assert.equal(currentMap, source)
      return target
    end,
  })

  local intent = assert(crossMapResolver:resolve(baseSnapshot({ runtimeMap = source })))
  Assert.equal(lookups.actorMapId, 62)
  Assert.equal(lookups.candidate.fieldX, 4)
  Assert.equal(lookups.candidate.fieldZ, 13)
  Assert.equal(intent.kind, "background")
  Assert.equal(intent.mapId, 62)
  Assert.equal(intent.scriptBankId, 912)
  Assert.equal(intent.background.eventIndex, 7)
  Assert.equal(intent.scriptId, 19)
  Assert.equal(intent.sourceFieldX, 4)
  Assert.equal(intent.sourceFieldZ, 14)
end

function T.cross_map_object_keeps_priority_and_forwards_stable_surface_identity()
  local source = map()
  source.terrain = TerrainSurface.new({
    plates = { flatPlate(0, 0, 32, 0) },
  })
  source.terrain:plate(0).cellKey = "7:3"
  source.terrain:plate(0).sourceSurfaceId = 44
  local target = map({ bgEvent(3, 19, 4, 13, 0) })
  target.mapId = 62
  target.fieldData.scriptBankId = 912
  local targetActor = actor("map:62:object:2", 2, 101, 4, 13, 23)
  local crossMapResolver = FieldInteractionResolver.new({
    actorAt = function(mapId, candidate)
      Assert.equal(mapId, 62)
      Assert.equal(candidate.cellKey, "7:3")
      Assert.equal(candidate.sourceSurfaceId, 44)
      return targetActor
    end,
    targetMapAt = function()
      return target
    end,
  })

  local intent = assert(crossMapResolver:resolve(baseSnapshot({ runtimeMap = source })))
  Assert.equal(intent.kind, "object")
  Assert.equal(intent.mapId, 62)
  Assert.equal(intent.scriptBankId, 912)
  Assert.equal(intent.object.actorId, "map:62:object:2")
  Assert.equal(intent.scriptId, 23)
end

return { tests = T }
