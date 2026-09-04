-- MapProps + MapDoor tests: the door/model lookup. A MapProps facade over a
-- scene's building placements resolves a field coordinate to the door of the
-- building placed there -- field coordinate -> building placement ->
-- ModelInstance -> semantic door animation -- without ever leaking NARC ids,
-- animation resource numbers, NSBCA, or animation-list slots. Ownership is
-- precomputed once when the scene is assembled: the assembly enumerates the
-- door tiles (the DOOR-kind behavior-105 tiles of the permission grid) and
-- resolves each to the placement whose pivot (transform translation) is
-- NEAREST the tile centre -- the predicate verified against the real ROM,
-- where door models are planar slabs whose AABB does not contain the tile
-- centre (New Bark member 26: x[-0.3,0.0] z[0.0,0.0]) and an AABB test
-- resolves the wrong static building. doorAt is then an O(1) index lookup:
-- no placement scan, no matrix inversion, no epsilon on the hot path.
-- Ambiguity (two placements tied for one door tile) and missing coverage (a
-- door tile with no placement) are data failures diagnosed once at assembly,
-- not per lookup. The index is authoritative: a tile it does not cover
-- resolves nothing, and mutating the placement list after assembly changes
-- nothing. Only DOOR-kind warp tiles resolve; stairs, directional warps, and
-- generic warps return nil. Doors over static buildings (no animated
-- instance) resolve but animate nothing. Pure domain module under test.
--
-- The playback surface is the COLLAPSED animation object graph:
-- MapProps carries no controller. MapDoor plays through the instance and
-- retains the returned play handle on the tile's index entry (entry.animation);
-- isFinished reads that handle, so the finish state never depends on the
-- disposable MapDoor identity. SceneProp keeps play/stop/isFinished.

local Assert = require("tests.support.Assert")
local TilePermissions = require("tests.support.TilePermissions")
local Matrix4 = require("libs.math.src.Matrix4")
local FieldGrid = require("libs.hgss.src.world.FieldGrid")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")
local NitroModelFixture = require("tests.support.NitroModelFixture")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local MapPropsModule = require("libs.hgss.src.world.MapProps")

local T = {}

---@class MapPropsTest.Door : MapDoor
---@class MapPropsTest.Prop : SceneProp
---@class MapPropsTest.Props : MapProps
---@field doorAt fun(self: MapPropsTest.Props, map: RuntimeFieldMap, fieldX: integer, fieldZ: integer): MapPropsTest.Door?
---@field prop fun(self: MapPropsTest.Props, placementIndex: integer): MapPropsTest.Prop?
local MapProps = {}
function MapProps.new(options)
  return MapPropsModule.new(options) --[[@as MapPropsTest.Props]]
end

local BEHAVIOR = MetatileBehavior.BEHAVIOR

local function throwsCode(code, fn)
  local ok, result = pcall(fn)
  if ok then
    error("expected a structured " .. code .. " error, got a result")
  end
  local errorObject = result --[[@as Errors.Error]]
  Assert.equal(errorObject.code, code)
end

-- Stub runtime map in the transition_trigger_test shape: 32x32 permission
-- grid addressed by "fieldX:fieldZ" tiles.
---@return RuntimeFieldMap
---@param originX number
---@param originZ number
---@param warps table
---@param tiles table
local function runtimeMap(originX, originZ, warps, tiles)
  return {
    mapId = 61,
    mapSymbol = "test-map",
    mapSection = "test-section",
    mapSectionNativeId = 7,
    followMode = "ALLOW",
    coordinateOrigin = { x = originX, z = originZ },
    scene = {},
    fieldData = { events = { warps = warps } },
    collision = TilePermissions.new(tiles),
    terrain = { artifact = {}, plates = {}, plateById = {} },
    terrainDependencyHash = "test-terrain",
    fieldRegion = {},
    cameraType = 0,
    release = function() end,
    updateAnimated = function() end,
  }
end

local function doorWarp(x, z)
  return { index = 0, x = x, z = z, destinationMapId = 60, destinationWarpId = 0, y = 0 }
end

-- World position of a field tile's centre under an origin at (0,0).
local function tileCenterWorld(x, z)
  local wx, wz = FieldGrid.tileCenterToWorld(x, z)
  return wx, wz
end

-- A placement record in the scene shape: transform + the model-space AABB
-- (footprint) the loader stamps from the model's geometry. The precomputed
-- ownership index resolves by pivot (transform translation), so bounds no
-- longer participate in the door lookup. `doorSoundType`/`doorRoles` carry
-- the generated door semantics FieldMapLoader reads off the model
-- descriptor (see ModelDoorMetadata); a nil `doorRoles` means the model
-- owns no door.open/door.close animation role.
local function placement(index, modelKey, wx, wz, halfExtent, doorSoundType, doorRoles)
  return {
    placementIndex = index,
    modelKey = modelKey,
    transform = Matrix4.translate(wx, 0, wz),
    bounds = halfExtent and {
      minX = -halfExtent,
      maxX = halfExtent,
      minY = -halfExtent,
      maxY = halfExtent,
      minZ = -halfExtent,
      maxZ = halfExtent,
    } or nil,
    doorSoundType = doorSoundType,
    doorRoles = doorRoles,
  }
end

-- Generated door semantics for a synthetic tied placement: a door.open role
-- that finishes after 3 ticks and a door.close role that finishes after 5,
-- so the selected owner's playback proves which role durations were kept.
local function semanticRoles()
  return { open = { frameCount = 3 }, close = { frameCount = 5 } }
end

-- Reads one role duration out of a candidate's compact role summary,
-- accepting either the full generated shape ({ open = { frameCount = n } })
-- or a bare numeric shorthand ({ open = n }).
local function roleFrameCount(summary, role)
  local entry = summary[role]
  if type(entry) == "table" then
    return entry.frameCount
  end
  return entry
end

-- The default door fixture scene: the door model (a 2x2-tile footprint) is
-- placed exactly at the door tile (4,14)'s centre; a larger building sits at
-- the origin, far from the door tile. The door instance is animated
-- (NitroModelFixture carries door.open/door.close); the building has no
-- animated instance (static). `doorTiles` is what the scene assembly
-- precomputes ownership over: the permission cell's DOOR-behavior tiles as
-- local indices (0..31).
local function doorScene()
  local wx, wz = tileCenterWorld(4, 14)
  local placements = {
    placement(0, "fixture:building", 0, 0, 4),
    placement(1, "fixture:door", wx, wz, 1),
  }
  local instances = {
    [1] = ModelInstance.new(NitroModelFixture.doorDefinition()),
  }
  local props = MapProps.new({
    placements = placements,
    instances = instances,
    doorTiles = { { x = 4, z = 14 } },
  })
  return props, instances
end

local function doorMap()
  return runtimeMap(0, 0, { doorWarp(4, 14) }, {
    ["4:14"] = { behavior = BEHAVIOR.DOOR, blocked = true },
  })
end

-- ---- resolution ---------------------------------------------------------

function T.door_at_resolves_the_door_tile_to_its_animated_door()
  local props, instances = doorScene()
  local door = assert(props:doorAt(doorMap(), 4, 14))
  Assert.equal(door.instance, instances[1])
  Assert.equal(door.placementIndex, 1)
  Assert.equal(door.modelKey, "fixture:door")
  Assert.equal(door.x, 4)
  Assert.equal(door.z, 14)
  Assert.equal(assert(door.warp).destinationMapId, 60)
  -- The chain ends at a semantic door animation on the resolved instance.
  Assert.notNil(instances[1].definition:animation("door.open"))
  Assert.notNil(instances[1].definition:animation("door.close"))
end

function T.door_at_returns_nil_without_a_warp_record()
  local props = doorScene()
  local map = doorMap()
  map.fieldData.events.warps = {}
  Assert.isNil(props:doorAt(map, 4, 14))
end

function T.door_at_returns_nil_for_non_door_behaviors()
  local props = doorScene()
  for _, behavior in ipairs({
    BEHAVIOR.WARP_STAIRS_EAST,
    BEHAVIOR.WARP_ENTRANCE_SOUTH,
    BEHAVIOR.WARP_NORTH,
    BEHAVIOR.LADDER_NORTH,
  }) do
    local map = runtimeMap(0, 0, { doorWarp(3, 3) }, {
      ["3:3"] = { behavior = behavior },
    })
    Assert.isNil(props:doorAt(map, 3, 3), "behavior " .. behavior .. " must not resolve a door")
  end
end

function T.door_at_returns_nil_outside_coverage()
  local props = doorScene()
  local map = runtimeMap(0, 0, { doorWarp(40, 40) }, {
    ["40:40"] = { behavior = BEHAVIOR.DOOR },
  })
  Assert.isNil(props:doorAt(map, 40, 40))
end

-- The regression shape from the real ROM: the door model is a planar slab
-- whose pivot sits near the door tile but whose footprint does NOT contain
-- the tile centre, while a larger building's footprint contains it. The
-- door tile belongs to the placement whose pivot is nearest; the AABB
-- containment test resolves the wrong (static) building on New Bark.
function T.door_at_resolves_the_placement_whose_pivot_is_nearest()
  local wx, wz = tileCenterWorld(4, 14)
  local placements = {
    placement(0, "fixture:door", wx + 0.65, wz - 0.26, 0.5),
    placement(1, "fixture:building", wx - 2.5, wz + 2.5, 4),
  }
  local instances = {
    [0] = ModelInstance.new(NitroModelFixture.doorDefinition()),
  }
  local props = MapProps.new({
    placements = placements,
    instances = instances,
    doorTiles = { { x = 4, z = 14 } },
  })
  local door = assert(props:doorAt(doorMap(), 4, 14))
  Assert.equal(door.placementIndex, 0, "the nearest pivot decides, not containment")
  Assert.equal(door.modelKey, "fixture:door")
  Assert.equal(door.instance, instances[0])
end

function T.door_at_consults_only_the_precomputed_index()
  local props = doorScene()
  local first = assert(props:doorAt(doorMap(), 4, 14))
  Assert.equal(first.placementIndex, 1)
  -- Ownership is precomputed once at assembly: mutating the placement list
  -- afterwards cannot change what the tile resolves to -- doorAt must not
  -- rescan placements per lookup.
  props.placements = { placement(0, "fixture:building", 0, 0, 4) }
  local second = assert(props:doorAt(doorMap(), 4, 14), "the door still resolves from the precomputed index")
  Assert.equal(second.placementIndex, 1, "the precomputed index decides, not a per-call scan")
end

function T.door_at_returns_nil_for_a_tile_the_index_does_not_cover()
  -- The index is authoritative: a door warp whose tile the assembly did not
  -- enumerate resolves nothing, even when a placement sits somewhere else
  -- in the cell. The production assembly enumerates every door-behavior
  -- tile, so this only fires on an assembly bug -- loudly nil, never a
  -- scanned guess.
  local wx, wz = tileCenterWorld(5, 5)
  local props = MapProps.new({
    placements = { placement(0, "fixture:door", wx, wz, 1) },
    instances = {},
    doorTiles = { { x = 5, z = 5 } },
  })
  Assert.isNil(props:doorAt(doorMap(), 4, 14))
end

function T.door_at_resolves_a_static_placement_when_no_door_model_is_placed()
  -- With the door model absent, the tile still resolves to its nearest
  -- placement -- here the static building placed at the door tile (nil
  -- instance, no-op playback). The pivot predicate is total; the assembly
  -- diagnoses only a door tile whose nearest placement is beyond the
  -- corpus-backed bound (or absent altogether). HGSS's static interior
  -- doors resolve and animate nothing the same way.
  local wx, wz = tileCenterWorld(4, 14)
  local props = MapProps.new({
    placements = { placement(0, "fixture:building", wx, wz, 4) },
    instances = {},
    doorTiles = { { x = 4, z = 14 } },
  })
  local door = assert(props:doorAt(doorMap(), 4, 14), "the nearest placement resolves")
  Assert.equal(door.placementIndex, 0)
  Assert.equal(door.modelKey, "fixture:building")
  Assert.isNil(door.instance)
  Assert.isNil(door:isFinished())
end

function T.door_at_resolves_a_static_door_when_no_animated_model_is_placed()
  local props = doorScene()
  -- Drop the door model's instance: the door resolves but animates nothing.
  props.instances = {}
  local door = assert(props:doorAt(doorMap(), 4, 14))
  Assert.equal(door.modelKey, "fixture:door")
  Assert.isNil(door.instance)
  Assert.isNil(door:isFinished())
end

function T.door_at_finish_state_does_not_depend_on_handle_identity()
  local props, instances = doorScene()
  local door = assert(props:doorAt(doorMap(), 4, 14))
  door:open()
  for _ = 1, 7 do
    instances[1]:updateFixed()
  end
  Assert.isFalse(door:isFinished(), "the checked advance is not done before the terminal")
  instances[1]:updateFixed()
  Assert.isTrue(door:isFinished(), "the door finishes exactly at numFrame * FRAME_UNIT")
  -- The tile's door state is not private to the handle that played it: a
  -- fresh resolution of the same tile observes the finished open. The
  -- retained play handle lives on the tile's index entry, so no handle
  -- identity carries the finish state.
  local fresh = assert(props:doorAt(doorMap(), 4, 14))
  Assert.isTrue(fresh:isFinished(), "a freshly resolved handle sees the finished role")
end

function T.assembly_raises_when_two_semantic_owners_claim_the_same_door_tile()
  local wx, wz = tileCenterWorld(4, 14)
  throwsCode("MAP_PROP_AMBIGUOUS_DOOR", function()
    return MapProps.new({
      placements = {
        placement(0, "fixture:door", wx, wz, 1, 1, semanticRoles()),
        placement(1, "fixture:door2", wx, wz, 1, 2, semanticRoles()),
      },
      instances = {},
      doorTiles = { { x = 4, z = 14 } },
    })
  end)
end

function T.assembly_raises_when_two_semantic_owners_tie_for_a_door_tile()
  local wx, wz = tileCenterWorld(4, 14)
  -- Two placements equidistant from the door tile (here: the same pivot)
  -- that both claim door semantics are genuinely ambiguous regardless of
  -- their footprints: the tie is diagnosed once at assembly, not at the
  -- first lookup.
  local slab = {
    minX = -0.3,
    maxX = 0,
    minY = -0.3,
    maxY = 0.3,
    minZ = 0,
    maxZ = 0,
  }
  local function door(index, key)
    return {
      placementIndex = index,
      modelKey = key,
      transform = Matrix4.translate(wx, 0, wz),
      bounds = slab,
      doorSoundType = 1,
      doorRoles = semanticRoles(),
    }
  end
  throwsCode("MAP_PROP_AMBIGUOUS_DOOR", function()
    return MapProps.new({
      placements = { door(0, "fixture:door"), door(1, "fixture:door2") },
      instances = {},
      doorTiles = { { x = 4, z = 14 } },
    })
  end)
end

function T.assembly_raises_when_a_door_tile_has_no_placement()
  -- Missing coverage is a data failure diagnosed once at assembly: a door
  -- tile the scene assembles with no building placement must not silently
  -- resolve nothing at transition time. (Corpus check: every real map with
  -- door tiles places at least one building, so the raise never fires on
  -- real data.)
  throwsCode("MAP_PROP_UNCOVERED_DOOR", function()
    return MapProps.new({
      placements = {},
      instances = {},
      doorTiles = { { x = 4, z = 14 } },
    })
  end)
end

-- The corpus-backed maximum door distance: HGSS door models are planar
-- slabs whose pivot sits at the door tile, so a door tile whose NEAREST
-- placement pivot is far away is uncovered -- the nearest pivot decides
-- ownership only within the bound. A placement 10 tiles away must not own
-- the tile; the assembly raises MAP_PROP_UNCOVERED_DOOR with the tile and
-- the nearest distance in context instead of resolving a wrong building.
-- (Corpus basis: every real door tile's nearest pivot is within a few tiles
-- of its tile -- the largest is 4.001953 tiles -- and the bound clears it
-- with headroom.)
function T.assembly_raises_when_the_nearest_placement_is_beyond_the_door_bound()
  local wx, wz = tileCenterWorld(4, 14)
  local err = Assert.throws(function()
    return MapProps.new({
      placements = { placement(0, "fixture:building", wx + 10, wz, 4) },
      instances = {},
      doorTiles = { { x = 4, z = 14 } },
    })
  end)
  Assert.equal(err.code, "MAP_PROP_UNCOVERED_DOOR")
  Assert.equal(err.context.x, 4, "the uncovered tile x is in the error context")
  Assert.equal(err.context.z, 14, "the uncovered tile z is in the error context")
  Assert.equal(err.context.nearestDistance, 10, "the nearest pivot distance in tiles is in the error context")
end

-- The ambiguity epsilon: transform translations are float products, not
-- integers, so two placements whose pivot distances differ by a hair are a
-- genuine tie when both claim door semantics -- the assembly raises
-- MAP_PROP_AMBIGUOUS_DOOR instead of silently resolving the float
-- near-miss. (The epsilon must stay below the smallest real non-tie gap,
-- 0.01171875 squared tiles.)
function T.assembly_raises_for_a_semantic_near_tie_within_the_ambiguity_epsilon()
  local wx, wz = tileCenterWorld(4, 14)
  local eps = 1e-6
  throwsCode("MAP_PROP_AMBIGUOUS_DOOR", function()
    return MapProps.new({
      placements = {
        placement(0, "fixture:door", wx + 0.65, wz - 0.26, 1, 1, semanticRoles()),
        placement(1, "fixture:door2", wx + 0.65 + eps, wz - 0.26, 1, 2, semanticRoles()),
      },
      instances = {},
      doorTiles = { { x = 4, z = 14 } },
    })
  end)
end

-- The near side of the bound: a placement whose pivot is beyond the real
-- corpus maximum (4.001953 tiles, Rotom room) but within the chosen bound
-- still owns the tile -- the bound must clear the corpus with headroom, and
-- the distance is compared in tiles (not squared).
function T.assembly_resolves_when_the_nearest_placement_is_within_the_door_bound()
  local wx, wz = tileCenterWorld(4, 14)
  local props = MapProps.new({
    placements = { placement(0, "fixture:building", wx + 4.1, wz, 4) },
    instances = {},
    doorTiles = { { x = 4, z = 14 } },
  })
  local door = assert(props:doorAt(doorMap(), 4, 14))
  Assert.equal(door.placementIndex, 0)
  Assert.equal(door.modelKey, "fixture:building")
end

-- The far side of the epsilon: a genuine near-miss ABOVE the ambiguity
-- window (gap 0.01 squared tiles -- just under the smallest real non-tie
-- gap, 0.01171875 squared tiles) resolves to the nearer placement; the
-- epsilon must not swallow distances the transform data really
-- distinguishes.
function T.assembly_resolves_a_near_tie_beyond_the_ambiguity_epsilon()
  local wx, wz = tileCenterWorld(4, 14)
  local props = MapProps.new({
    placements = {
      placement(0, "fixture:door", wx + 1, wz, 1),
      placement(1, "fixture:door2", wx + 1, wz + 0.1, 1),
    },
    instances = {},
    doorTiles = { { x = 4, z = 14 } },
  })
  local door = assert(props:doorAt(doorMap(), 4, 14))
  Assert.equal(door.placementIndex, 0, "the nearer placement wins outside the ambiguity window")
end

-- The ambiguity window is symmetric: a within-epsilon pair of semantic
-- owners raises even when the NEARER placement is processed second -- a tie
-- is a tie in either order, never resolved to whichever candidate the
-- placement list happened to enumerate first.
function T.assembly_raises_for_a_semantic_near_tie_when_the_nearer_placement_comes_second()
  local wx, wz = tileCenterWorld(4, 14)
  local eps = 1e-6
  throwsCode("MAP_PROP_AMBIGUOUS_DOOR", function()
    return MapProps.new({
      placements = {
        placement(0, "fixture:door", wx + 0.65 + eps, wz - 0.26, 1, 1, semanticRoles()),
        placement(1, "fixture:door2", wx + 0.65, wz - 0.26, 1, 2, semanticRoles()),
      },
      instances = {},
      doorTiles = { { x = 4, z = 14 } },
    })
  end)
end

-- A geometric tie with exactly one semantic owner resolves to that owner in
-- either placement order: inside the tie window geometry cannot tell the
-- candidates apart, so the generated door semantics decide. The static
-- candidate stays exactly on the tile centre here, microscopically nearer
-- than the offset semantic candidate in the near-tie pass, and must still
-- lose. The epsilon near-tie takes the same semantic path as the exact tie.
function T.tied_door_selects_the_only_semantic_owner_in_either_order()
  local wx, wz = tileCenterWorld(4, 14)
  for _, offset in ipairs({ 0, 1e-6 }) do
    for _, semanticFirst in ipairs({ true, false }) do
      local static = placement(0, "fixture:static", wx, wz, 1)
      local semantic = placement(1, "fixture:animated-door", wx + offset, wz, 1, 1, semanticRoles())
      local placements = semanticFirst and { semantic, static } or { static, semantic }
      local props = MapProps.new({
        placements = placements,
        instances = {},
        doorTiles = { { x = 4, z = 14 } },
      })
      local where = "offset " .. offset .. " semanticFirst " .. tostring(semanticFirst)
      local door = assert(props:doorAt(doorMap(), 4, 14), "the semantic owner resolves (" .. where .. ")")
      Assert.equal(door.placementIndex, 1, "the semantic placement wins regardless of order (" .. where .. ")")
      Assert.equal(door.modelKey, "fixture:animated-door", "the semantic model wins (" .. where .. ")")
      Assert.isNil(door.instance)
      Assert.equal(door:open(), "SEQ_SE_DP_DOOR_OPEN", "sound comes from the semantic sound type (" .. where .. ")")
      Assert.isFalse(door:isFinished(), "the semantic open duration is not immediate (" .. where .. ")")
      props:updateFixed()
      props:updateFixed()
      Assert.isFalse(door:isFinished(), "the open role is not done before its frame count (" .. where .. ")")
      props:updateFixed()
      Assert.isTrue(door:isFinished(), "the open role finishes at its frame count (" .. where .. ")")
      Assert.equal(door:close(), "SEQ_SE_DP_DOOR_CLOSE2", "close sound comes from the semantic sound type")
      Assert.isFalse(door:isFinished(), "the close role restarts its own duration")
      for _ = 1, 4 do
        props:updateFixed()
      end
      Assert.isFalse(door:isFinished(), "the close role has its own longer duration")
      props:updateFixed()
      Assert.isTrue(door:isFinished(), "the close role finishes at its own frame count")
    end
  end
end

-- A geometric tie with no semantic owner is a static door that invents no
-- placement ownership, while a tie where two placements both claim door
-- semantics stays a diagnosable ambiguity.
function T.tied_doors_without_semantics_resolve_statically_while_two_semantic_owners_conflict()
  local wx, wz = tileCenterWorld(4, 14)
  -- No semantic owner: the tile resolves to a static handle with no
  -- placement identity, no sound, and nothing to wait for.
  local props = MapProps.new({
    placements = {
      placement(0, "fixture:static-a", wx, wz, 1),
      placement(1, "fixture:static-b", wx, wz, 1),
    },
    instances = {},
    doorTiles = { { x = 4, z = 14 } },
  })
  local door = assert(props:doorAt(doorMap(), 4, 14), "a tie with no semantic owner still resolves")
  Assert.isNil(door.placementIndex, "a static tie invents no placement owner")
  Assert.isNil(door.modelKey, "a static tie invents no model owner")
  Assert.isNil(door.instance)
  Assert.isNil(door:open(), "a static tie plays no sound")
  Assert.isNil(door:close(), "a static tie plays no sound")
  Assert.isNil(door:isFinished(), "a static tie has nothing to wait for")
  local fresh = assert(props:doorAt(doorMap(), 4, 14), "a static tie resolves on every lookup")
  Assert.isNil(fresh.placementIndex)
  Assert.isNil(fresh:isFinished())
  -- An epsilon near-tie without semantics takes the same static path.
  local nearProps = MapProps.new({
    placements = {
      placement(0, "fixture:static-a", wx, wz, 1),
      placement(1, "fixture:static-b", wx + 1e-6, wz, 1),
    },
    instances = {},
    doorTiles = { { x = 4, z = 14 } },
  })
  local nearDoor = assert(nearProps:doorAt(doorMap(), 4, 14), "a near-tie with no semantic owner still resolves")
  Assert.isNil(nearDoor.placementIndex)
  Assert.isNil(nearDoor.modelKey)
  Assert.isNil(nearDoor:isFinished())
  -- Two semantic owners: a genuine ambiguity whose context names every tied
  -- candidate with placement identity, pivot distance, sound identity, and
  -- role durations, ordered by placement index regardless of input order.
  for _, swap in ipairs({ false, true }) do
    local first = placement(0, "fixture:door-a", wx, wz, 1, 1, semanticRoles())
    local second = placement(1, "fixture:door-b", wx, wz, 1, 2, semanticRoles())
    local err = Assert.throws(function()
      return MapProps.new({
        placements = swap and { second, first } or { first, second },
        instances = {},
        doorTiles = { { x = 4, z = 14 } },
      })
    end)
    local where = "swap " .. tostring(swap)
    Assert.equal(err.code, "MAP_PROP_AMBIGUOUS_DOOR", "two semantic owners stay ambiguous (" .. where .. ")")
    Assert.equal(err.context.x, 4, "ambiguity names the tile x (" .. where .. ")")
    Assert.equal(err.context.z, 14, "ambiguity names the tile z (" .. where .. ")")
    local candidates = assert(err.context.candidates, "ambiguity names its tied candidates (" .. where .. ")")
    Assert.equal(#candidates, 2, "ambiguity names both candidates (" .. where .. ")")
    Assert.equal(candidates[1].placementIndex, 0, "candidates order by placement index (" .. where .. ")")
    Assert.equal(candidates[2].placementIndex, 1, "candidates order by placement index (" .. where .. ")")
    Assert.equal(candidates[1].modelKey, "fixture:door-a")
    Assert.equal(candidates[2].modelKey, "fixture:door-b")
    Assert.equal(candidates[1].doorSoundType, 1)
    Assert.equal(candidates[2].doorSoundType, 2)
    for _, candidate in ipairs(candidates) do
      Assert.equal(type(candidate.distance), "number", "candidate carries its pivot distance (" .. where .. ")")
      local roles =
        assert(candidate.doorRoles or candidate.roles, "candidate carries its door-role summary (" .. where .. ")")
      Assert.equal(type(roleFrameCount(roles, "open")), "number", "candidate names its open duration")
      Assert.equal(type(roleFrameCount(roles, "close")), "number", "candidate names its close duration")
    end
  end
end

-- A geometric tie with one semantic owner among several static
-- candidates still resolves to that owner: the rule counts semantic
-- candidates, not tie-set size.
function T.tied_door_with_one_semantic_owner_among_many_static_candidates()
  local wx, wz = tileCenterWorld(4, 14)
  local props = MapProps.new({
    placements = {
      placement(0, "fixture:static-a", wx, wz, 1),
      placement(1, "fixture:static-b", wx, wz, 1),
      placement(2, "fixture:animated-door", wx, wz, 1, 1, semanticRoles()),
      placement(3, "fixture:static-c", wx, wz, 1),
    },
    instances = {},
    doorTiles = { { x = 4, z = 14 } },
  })
  local door = assert(props:doorAt(doorMap(), 4, 14))
  Assert.equal(door.placementIndex, 2)
  Assert.equal(door.modelKey, "fixture:animated-door")
end

-- Two semantic owners stay ambiguous even when they carry identical role
-- durations and sound identity: the runtime must not assume tied
-- presentation owners are interchangeable.
function T.tied_doors_with_identical_semantics_stay_ambiguous()
  local wx, wz = tileCenterWorld(4, 14)
  local err = Assert.throws(function()
    return MapProps.new({
      placements = {
        placement(0, "fixture:door-a", wx, wz, 1, 1, semanticRoles()),
        placement(1, "fixture:door-b", wx, wz, 1, 1, semanticRoles()),
      },
      instances = {},
      doorTiles = { { x = 4, z = 14 } },
    })
  end)
  Assert.equal(err.code, "MAP_PROP_AMBIGUOUS_DOOR")
  Assert.equal(#assert(err.context.candidates), 2)
end

-- ---- playback -----------------------------------------------------------

function T.open_plays_the_door_open_role_once_and_finishes()
  local props, instances = doorScene()
  local door = assert(props:doorAt(doorMap(), 4, 14))
  door:open()
  local joint = instances[1].animationState:attachments("joint")
  Assert.equal(#joint, 1)
  Assert.equal(joint[1].clip.name, "DoorOpen")
  Assert.deepEqual(joint[1].clip.semanticNames, { "door.open" })
  Assert.isFalse(door:isFinished())
  for _ = 1, 7 do
    instances[1]:updateFixed()
  end
  Assert.isFalse(door:isFinished(), "the checked advance is not done before the terminal")
  instances[1]:updateFixed()
  Assert.isTrue(door:isFinished(), "the opened door reaches the checked-advance terminal")
end

function T.close_stops_the_open_and_plays_close()
  local props, instances = doorScene()
  local door = assert(props:doorAt(doorMap(), 4, 14))
  door:open()
  instances[1]:updateFixed()
  door:close()
  local joint = instances[1].animationState:attachments("joint")
  Assert.equal(#joint, 1)
  Assert.equal(joint[1].clip.name, "DoorClose")
  door:open()
  joint = instances[1].animationState:attachments("joint")
  Assert.equal(#joint, 1)
  Assert.equal(joint[1].clip.name, "DoorOpen")
end

function T.is_finished_is_nil_before_any_play()
  local props = doorScene()
  local door = assert(props:doorAt(doorMap(), 4, 14))
  Assert.isNil(door:isFinished())
end

function T.open_raises_when_the_door_model_lacks_the_role()
  local props, instances = doorScene()
  -- Replace the door instance with a model that only animates door.close.
  local closeOnly = NitroModelFixture.doorDefinition({
    NitroModelFixture.doorCloseClip(),
  })
  instances[1] = ModelInstance.new(closeOnly)
  props.instances = { [1] = instances[1] }
  local door = assert(props:doorAt(doorMap(), 4, 14))
  throwsCode("MAP_PROP_ANIM_UNKNOWN", function()
    door:open()
  end)
end

function T.static_door_playback_is_a_noop()
  local props = doorScene()
  props.instances = {}
  local door = assert(props:doorAt(doorMap(), 4, 14))
  door:open()
  door:close()
  Assert.isNil(door:isFinished())
end

function T.headless_door_playback_emits_audio_without_visual_animation()
  local wx, wz = tileCenterWorld(4, 14)
  local instances = {}
  local props = MapProps.new({
    placements = { placement(1, "fixture:door", wx, wz, 1, 1) },
    instances = instances,
    doorTiles = { { x = 4, z = 14 } },
  })
  local door = assert(props:doorAt(doorMap(), 4, 14))
  Assert.isNil(door.instance)
  Assert.equal(door:open(), "SEQ_SE_DP_DOOR_OPEN")
  Assert.equal(door:close(), "SEQ_SE_DP_DOOR_CLOSE2")
  Assert.isNil(door:isFinished())
end

-- The collapsed door surface: the tile's index entry retains
-- the PLAY HANDLE from instance:play -- not a role string -- so the finish
-- state is read off the live attachment and survives every fresh resolution.
function T.door_open_retains_the_play_handle_on_the_tile()
  local props, instances = doorScene()
  local door = assert(props:doorAt(doorMap(), 4, 14))
  Assert.isNil(door.entry.currentRole, "the retained entry no longer stores a role string")
  Assert.isNil(door.entry.animation, "nothing plays before the first open")
  door:open()
  local handle = door.entry.animation
  Assert.notNil(handle, "the tile's entry retains the play handle")
  Assert.equal(handle.clip.name, "DoorOpen")
  Assert.isTrue(
    instances[1].animationState:attachments("joint")[1] == handle,
    "the retained handle is the live attachment"
  )
  door:close()
  Assert.equal(door.entry.animation.clip.name, "DoorClose", "the retained handle follows the played role")
end

-- Replaying a role replaces the previous play of that door: the retained
-- handle is stopped and a fresh one attached, so one door has one playing
-- attachment (the controller-identity behavior survives without a
-- controller).
function T.replaying_the_role_replaces_the_previous_play()
  local props, instances = doorScene()
  local door = assert(props:doorAt(doorMap(), 4, 14))
  door:open()
  local first = door.entry.animation
  Assert.notNil(first, "the tile retains the first play handle")
  instances[1]:updateFixed()
  door:open()
  local second = door.entry.animation
  Assert.notNil(second, "the tile retains the replayed play handle")
  Assert.isFalse(first == second, "the replay attaches a fresh handle")
  Assert.equal(#instances[1].animationState:attachments("joint"), 1, "one door has one playing attachment")
  Assert.equal(second.player.frameFx, 0, "the replay restarts the clip")
end

-- ---- scripted props -----------------------------------------------------

function T.prop_resolves_an_animated_placement_by_index()
  local props, instances = doorScene()
  local prop = assert(props:prop(1))
  Assert.equal(prop.instance, instances[1])
  Assert.equal(prop.modelKey, "fixture:door")
  Assert.equal(prop.placementIndex, 1)

  -- The generic scripted surface: play by role or clip name, stop, and the
  -- HGSS completion check (finished exactly at numFrame * FRAME_UNIT).
  local handle = prop:play("door.open", { loopMode = "once" })
  Assert.equal(type(handle), "table", "prop:play returns the instance's attachment handle")
  local joint = instances[1].animationState:attachments("joint")
  Assert.equal(#joint, 1)
  Assert.equal(joint[1].clip.name, "DoorOpen")
  Assert.isFalse(prop:isFinished("door.open"))
  for _ = 1, 7 do
    instances[1]:updateFixed()
  end
  Assert.isFalse(prop:isFinished("door.open"), "the checked advance is not done before the terminal")
  instances[1]:updateFixed()
  Assert.isTrue(prop:isFinished("door.open"))
  prop:stop("door.open")
  Assert.equal(#instances[1].animationState:attachments("joint"), 0)
end

function T.prop_is_finished_is_nil_before_any_play()
  local props = doorScene()
  local prop = assert(props:prop(1))
  Assert.isNil(prop:isFinished("door.open"))
end

function T.prop_for_a_static_placement_is_a_noop_handle()
  local props = doorScene()
  local prop = assert(props:prop(0))
  Assert.isNil(prop.instance)
  Assert.isNil(prop:play("idle"))
  Assert.isNil(prop:stop("idle"))
  Assert.isNil(prop:isFinished("idle"))
end

function T.prop_returns_nil_for_unknown_placement()
  local props = doorScene()
  Assert.isNil(props:prop(5))
end

function T.prop_raises_for_an_unknown_animation()
  local props = doorScene()
  local prop = assert(props:prop(1))
  throwsCode("MAP_PROP_ANIM_UNKNOWN", function()
    prop:play("no.such.animation")
  end)
end

function T.prop_resolves_from_the_precomputed_index()
  local props = doorScene()
  local prop = assert(props:prop(1))
  Assert.equal(prop.placementIndex, 1)
  -- The placement index is precomputed at assembly like the door index:
  -- prop() must not rescan the placement list per call.
  props.placements = { placement(0, "fixture:building", 0, 0, 4) }
  local again = assert(props:prop(1), "the placement index decides, not a per-call scan")
  Assert.equal(again.placementIndex, 1)
  Assert.equal(again.modelKey, "fixture:door")
end

-- ---- generated door duration (no live instance) --------------------------
--
-- A door's sound identity and role duration are generated data carried on
-- the owning placement (`doorSoundType`, `doorRoles`), read at census time
-- regardless of whether a live ModelInstance is ever attached. These tests
-- exercise that authority directly, with no instance at all -- the shape
-- FieldMapLoader builds for a headless composition.

local function generatedDoorPlacement(index, wx, wz, doorSoundType, doorRoles)
  return {
    placementIndex = index,
    modelKey = "fixture:generated-door",
    transform = Matrix4.translate(wx, 0, wz),
    doorSoundType = doorSoundType,
    doorRoles = doorRoles,
  }
end

-- A role with a real generated duration and no live instance is not
-- immediate: it plays a semantic-only timer that only reaches completion
-- once MapProps:updateFixed has advanced it the generated frame count.
function T.generated_duration_role_is_not_immediate_without_a_live_instance()
  local wx, wz = tileCenterWorld(4, 14)
  local props = MapProps.new({
    placements = { generatedDoorPlacement(0, wx, wz, 1, { open = { frameCount = 3 } }) },
    instances = {},
    doorTiles = { { x = 4, z = 14 } },
  })
  local door = assert(props:doorAt(doorMap(), 4, 14))
  local sound = door:open()
  Assert.equal(sound, "SEQ_SE_DP_DOOR_OPEN", "sound identity comes from the generated doorSoundType")
  Assert.isFalse(door:isFinished(), "a real generated duration is not immediate")
  props:updateFixed()
  props:updateFixed()
  Assert.isFalse(door:isFinished(), "the checked advance is not done before the terminal")
  props:updateFixed()
  Assert.isTrue(door:isFinished(), "the semantic timer finishes exactly at the generated frame count")
end

-- A role with NO generated duration and no live instance is the genuinely
-- static case (HGSS's unanimated interior doors): nothing plays, and
-- isFinished stays nil (nothing to wait for), exactly like a static building.
function T.role_with_no_generated_duration_and_no_instance_is_static()
  local wx, wz = tileCenterWorld(4, 14)
  local props = MapProps.new({
    placements = { generatedDoorPlacement(0, wx, wz, nil, nil) },
    instances = {},
    doorTiles = { { x = 4, z = 14 } },
  })
  local door = assert(props:doorAt(doorMap(), 4, 14))
  Assert.isNil(door:open(), "no generated sound type means no sound")
  Assert.isNil(door:isFinished(), "no generated duration means nothing to wait for")
end

-- updateFixed only advances the door role that is actually playing; a role
-- that finished stays finished (no overshoot into a later close role), and a
-- door with nothing playing is untouched.
function T.update_fixed_only_advances_the_active_role_and_stops_at_completion()
  local wx, wz = tileCenterWorld(4, 14)
  local props = MapProps.new({
    placements = {
      generatedDoorPlacement(0, wx, wz, 1, { open = { frameCount = 2 }, close = { frameCount = 5 } }),
    },
    instances = {},
    doorTiles = { { x = 4, z = 14 } },
  })
  local door = assert(props:doorAt(doorMap(), 4, 14))
  door:open()
  props:updateFixed()
  props:updateFixed()
  Assert.isTrue(door:isFinished(), "the open role finishes at its own generated duration")
  local finishedFrame = door.entry.animation.player.frame
  props:updateFixed()
  props:updateFixed()
  Assert.equal(door.entry.animation.player.frame, finishedFrame, "a finished role does not keep advancing")

  door:close()
  Assert.isFalse(door:isFinished(), "the close role restarts its own generated duration")
  for _ = 1, 4 do
    props:updateFixed()
  end
  Assert.isFalse(door:isFinished(), "the close role has its own, longer generated duration")
  props:updateFixed()
  Assert.isTrue(door:isFinished(), "the close role finishes at its own generated duration")
end

return { tests = T }
