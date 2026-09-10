-- Private target test: the door/model lookup against the real HGSS dump.
-- Every New Bark town door (DOOR behavior 105) resolves to the placed door
-- model at its tile (members 24/25/26, compiled animated with the
-- door.open/door.close roles) and drives its animation to completion; Elm's
-- Lab interior entrance (WARP_ENTRANCE_SOUTH, 101) and non-door warp tiles
-- resolve nil. Ownership is precomputed at assembly: the scene's door tiles
-- (the permission grid's DOOR-behavior tiles) resolve to the placement whose
-- pivot is nearest the tile centre -- the predicate the real dump verifies
-- (the door models are planar slabs whose AABB does not contain the tile
-- centre), and resolution is an O(1) index lookup that never rescans
-- placements. Runs against every ready dump through the ROM layer.

local Assert = require("tests.support.Assert")
local DoorTiles = require("libs.hgss.src.transition.DoorTiles")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local FieldGrid = require("libs.hgss.src.world.FieldGrid")
local Matrix4 = require("libs.math.src.Matrix4")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local ModelDoorMetadata = require("libs.hgss.src.world.ModelDoorMetadata")
local MapAnalysis = require("romdump.src.digest.map.MapAnalysis")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local CollisionGridAsset = require("libs.assets.src.field.CollisionGridAsset")
local CollisionGrid = require("libs.hgss.src.world.CollisionGrid")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local MapProps = require("libs.hgss.src.world.MapProps")
local RomRuntimeMap = require("tests.support.RomRuntimeMap")

local T = {}

-- World position of a field tile's centre on a runtime map.
local function tileCenterWorld(map, x, z)
  local lx, lz = FieldCoordinates.fieldToLocal(map, x, z)
  return FieldGrid.tileCenterToWorld(lx, lz)
end

local TOWN_DOORS = {
  { x = 684, z = 393, destinationMapId = 61, modelMemberId = 26 },
  { x = 695, z = 396, destinationMapId = 63, modelMemberId = 24 },
  { x = 679, z = 405, destinationMapId = 65, modelMemberId = 25 },
  { x = 690, z = 407, destinationMapId = 66, modelMemberId = 25 },
}

-- The model-space AABB of a descriptor's geometry, recomputed from the
-- compiled bundle's mesh table (the loader stamps this from the decoded
-- .g4mesh assets).
local function footprintOf(desc, assets)
  local batches = desc.kind == "static" and desc.batches or desc.dynamic.batches
  local minX, maxX, minZ, maxZ
  for _, batch in ipairs(batches) do
    local sha = assert(batch.geometry:match("geometry/([%w]+)%.g4mesh"), "batch references .g4mesh geometry")
    local mesh = assert(assets.meshes[sha], "batch geometry present in the bundle")
    for _, v in ipairs(mesh.vertices) do
      minX = minX == nil and v.x or math.min(minX, v.x)
      maxX = maxX == nil and v.x or math.max(maxX, v.x)
      minZ = minZ == nil and v.z or math.min(minZ, v.z)
      maxZ = maxZ == nil and v.z or math.max(maxZ, v.z)
    end
  end
  return {
    minX = minX or 0,
    maxX = maxX or 0,
    minY = 0,
    maxY = 0,
    minZ = minZ or 0,
    maxZ = maxZ or 0,
  }
end

-- The scene's MapProps over the compiled bundle, mirroring MapSceneLoader:
-- every placement whose model descriptor is animated becomes a ModelInstance,
-- every placement carries the model-space AABB the loader stamps from the
-- geometry, every placement carries the production door semantics
-- (doorSoundType/doorRoles) FieldMapLoader reads off the same descriptor
-- through ModelDoorMetadata, and the door tiles (the permission grid's
-- DOOR-behavior tiles) are precomputed into the ownership index the loader
-- builds at assembly.
---@param romFs table
---@param symbol string
---@return MapProps, table, table
local function propsFor(romFs, symbol)
  local assets = assert(MapAssetCompiler.compile(romFs, symbol))
  local scene = assets.scene
  local instances = {}
  local placements = {}
  for _, inst in ipairs(scene.buildingInstances or {}) do
    local desc = assert(assets.models[inst.modelKey], "placement model descriptor")
    if desc.kind == "nitro-dynamic" then
      instances[inst.placementIndex] =
        ModelInstance.new(ModelDefinition.fromNitroDescriptor(desc, { key = inst.modelKey }))
    end
    local doorMeta = ModelDoorMetadata.forDescriptor(desc)
    placements[#placements + 1] = {
      placementIndex = inst.placementIndex,
      modelKey = inst.modelKey,
      transform = inst.transform,
      bounds = footprintOf(desc, assets),
      doorSoundType = doorMeta and doorMeta.doorSoundType or nil,
      doorRoles = doorMeta and doorMeta.roles or nil,
    }
  end
  local map = RomRuntimeMap.compile(romFs, symbol)
  local props = MapProps.new({
    placements = placements,
    instances = instances,
    doorTiles = DoorTiles.fromGrid(map.collision),
  })
  ---@cast props MapProps
  return props,
    map, --[[@as RuntimeFieldMap]]
    instances
end

-- The door at (x, z) resolved to the placement whose model member id matches.
---@param props MapProps
---@param map table
---@param x integer
---@param z integer
---@param memberId integer
---@param destinationMapId integer
---@return nil
local function doorAtMember(props, map, x, z, memberId, destinationMapId)
  ---@cast map RuntimeFieldMap
  local door = assert(MapProps.doorAt(props, map, x, z), "door tile (" .. x .. "," .. z .. ") resolves")
  Assert.equal(door.x, x)
  Assert.equal(door.z, z)
  Assert.isTrue(door.modelKey:find("outdoor:" .. memberId .. ":", 1, true) == 1, "door model member " .. memberId)
  local instance = assert(door.instance, "the door model is animated")
  Assert.notNil(instance.definition:animation("door.open"))
  Assert.notNil(instance.definition:animation("door.close"))
  Assert.equal(assert(door.warp).destinationMapId, destinationMapId)
  return door
end

function T.new_bark_town_doors_resolve_to_their_placed_models(romFs)
  local props, map = propsFor(romFs, "MAP_NEW_BARK")
  -- The assembly enumerates exactly the four town door tiles (and no other
  -- DOOR-behavior tile) from the real permission grid, as local cell
  -- indices.
  local enumerated = DoorTiles.fromGrid(map.collision)
  Assert.equal(#enumerated, #TOWN_DOORS)
  for _, expected in ipairs(TOWN_DOORS) do
    local lx, lz = FieldCoordinates.fieldToLocal(map, expected.x, expected.z)
    local found = false
    for _, tile in ipairs(enumerated) do
      if tile.x == lx and tile.z == lz then
        found = true
      end
    end
    Assert.isTrue(found, "town door tile (" .. expected.x .. "," .. expected.z .. ") is enumerated")
    doorAtMember(props, map, expected.x, expected.z, expected.modelMemberId, expected.destinationMapId)
  end
end

-- The ownership index is precomputed at assembly: appending a decoy
-- placement whose pivot sits ON the door tile after construction must not
-- change what the tile resolves to (doorAt is an O(1) index lookup, not a
-- per-call scan that could re-resolve the tile to the decoy).
function T.new_bark_town_door_resolution_is_precomputed_not_rescanned(romFs)
  local props, map = propsFor(romFs, "MAP_NEW_BARK")
  ---@cast map RuntimeFieldMap
  local x, z = 684, 393
  local door = assert(MapProps.doorAt(props, map, x, z))
  Assert.isTrue(door.modelKey:find("outdoor:26:", 1, true) == 1, "the town door model")
  local wx, wz = tileCenterWorld(map, x, z)
  props.placements[#props.placements + 1] = {
    placementIndex = 999,
    modelKey = "fixture:decoy",
    transform = Matrix4.translate(wx, 0, wz),
    bounds = { minX = -1, maxX = 1, minY = -1, maxY = 1, minZ = -1, maxZ = 1 },
  }
  local again = assert(MapProps.doorAt(props, map, x, z))
  Assert.isTrue(again.modelKey:find("outdoor:26:", 1, true) == 1, "the index snapshot still resolves the town door")
  Assert.equal(again.placementIndex, door.placementIndex)
end

function T.new_bark_lab_door_plays_to_completion(romFs)
  local props, map, instances = propsFor(romFs, "MAP_NEW_BARK")
  ---@cast map RuntimeFieldMap
  local door = assert(MapProps.doorAt(props, map, 684, 393))
  local instance = assert(door.instance)
  Assert.equal(instance, instances[door.placementIndex])
  door:open()
  Assert.isFalse(door:isFinished(), "freshly opened door is not finished")
  local frameCount = assert(instance.definition:animation("door.open")).frameCount
  -- The checked advance completes exactly at numFrame * FRAME_UNIT: the
  -- last key frame (frameCount - 1 ticks) is NOT finished yet.
  for _ = 1, frameCount - 1 do
    instance:updateFixed()
  end
  Assert.isFalse(door:isFinished(), "the checked advance is not done before the terminal")
  instance:updateFixed()
  Assert.isTrue(door:isFinished(), "the door reaches the checked-advance terminal")
  door:close()
  for _ = 1, frameCount - 1 do
    instance:updateFixed()
  end
  Assert.isFalse(door:isFinished(), "the checked advance is not done before the terminal")
  instance:updateFixed()
  Assert.isTrue(door:isFinished(), "the door closes")
end

function T.interior_entrances_and_non_door_warps_resolve_nil(romFs)
  local labProps, labMap = propsFor(romFs, "MAP_NEW_BARK_ELMS_LAB_1F")
  ---@cast labMap RuntimeFieldMap
  Assert.isNil(MapProps.doorAt(labProps, labMap, 4, 14), "Elm Lab's entrance-south tile is not a door lookup")

  local townProps, townMap = propsFor(romFs, "MAP_NEW_BARK")
  ---@cast townMap RuntimeFieldMap
  Assert.isNil(MapProps.doorAt(townProps, townMap, 688, 392), "the WARP_WEST tile is not a door lookup")
  Assert.isNil(
    MapProps.doorAt(townProps, townMap, 684, 394),
    "the walkable tile south of the lab door is not a door lookup"
  )
end

-- Corpus audit over every resolved map's warp-bearing DOOR tiles: the
-- deterministic MapAnalysis census selects the maps, the derived cache
-- supplies the real scene/collision/field/model records, and placements
-- carry the same ModelDoorMetadata join the production loader builds, so
-- ties classify exactly as the runtime does. Every warp-bearing DOOR tile
-- must assemble and resolve without ambiguity or coverage failure; the
-- audit names the version, map, and tile of the first failure instead of
-- swallowing it. Maps without a warp-bearing DOOR tile are skipped; the
-- burned tower presentation setup boots that regression map unchanged
-- through the acceptance layer.
function T.resolved_maps_warp_bearing_doors_resolve(romFs, versionId, context)
  local cache = CacheFs.forVersion(versionId)
  if not cache:exists("data/generated/maps", "directory") then
    context:skip(versionId .. ": no derived cache to census")
  end
  local resolved = {}
  for _, result in ipairs(MapAnalysis.analyze(romFs)) do
    if result.status == "resolved" then
      resolved[#resolved + 1] = result
    end
  end
  Assert.isTrue(#resolved > 0, versionId .. ": the analysis resolved ready maps")
  local checkedMaps = 0
  local checkedTiles = 0
  for _, result in ipairs(resolved) do
    local mapId = result.id
    local dir = MapAssetCache.mapDir(mapId)
    if not cache:exists(dir .. "/complete") then
      error(versionId .. ": resolved map " .. result.symbol .. " (" .. mapId .. ") has no derived cache", 0)
    end
    local scene = assert(cache:loadLua(dir .. "/scene.lua"), versionId .. ": scene " .. mapId .. " is loadable")
    local collisionBytes =
      assert(cache:read(MapAssetCache.collisionPath(mapId)), versionId .. ": collision " .. mapId .. " is readable")
    local decoded = assert(
      CollisionGridAsset.decode(collisionBytes, { mapId = mapId }),
      versionId .. ": collision " .. mapId .. " decodes"
    )
    local grid = CollisionGrid.new(decoded, {
      worldOriginX = scene.matrix.worldOriginX,
      worldOriginZ = scene.matrix.worldOriginZ,
    })
    local fieldData =
      assert(cache:loadLua(FieldMapDataCache.fieldPath(mapId)), versionId .. ": field data " .. mapId .. " is loadable")
    local warped = {}
    for _, warp in ipairs(fieldData.events.warps) do
      warped[(warp.x - scene.matrix.worldOriginX) .. ":" .. (warp.z - scene.matrix.worldOriginZ)] = true
    end
    local doorTiles = {}
    for _, tile in ipairs(DoorTiles.fromGrid(grid)) do
      if warped[tile.x .. ":" .. tile.z] then
        doorTiles[#doorTiles + 1] = tile
      end
    end
    if #doorTiles > 0 then
      Assert.isTrue(
        type(scene.buildingInstances) == "table",
        versionId .. ": map " .. result.symbol .. " (" .. mapId .. ") carries building instances"
      )
      local doorMetaByModelKey = {}
      local placements = {}
      for _, inst in ipairs(scene.buildingInstances) do
        local meta = doorMetaByModelKey[inst.modelKey]
        if meta == nil then
          local desc = assert(
            cache:loadLua(MapAssetCache.modelPath(inst.modelKey)),
            versionId .. ": model " .. inst.modelKey .. " is loadable"
          )
          meta = ModelDoorMetadata.forDescriptor(desc) or false
          doorMetaByModelKey[inst.modelKey] = meta
        end
        placements[#placements + 1] = {
          placementIndex = inst.placementIndex,
          modelKey = inst.modelKey,
          transform = inst.transform,
          doorSoundType = meta and meta.doorSoundType or nil,
          doorRoles = meta and meta.roles or nil,
        }
      end
      local ok, propsOrErr = pcall(MapProps.new, { placements = placements, instances = {}, doorTiles = doorTiles })
      if not ok then
        error(
          versionId
            .. ": map "
            .. result.symbol
            .. " ("
            .. mapId
            .. ") warp-bearing door census failed: "
            .. Errors.format(propsOrErr),
          0
        )
      end
      local props = propsOrErr
      local runtimeMap = {
        coordinateOrigin = { x = scene.matrix.worldOriginX, z = scene.matrix.worldOriginZ },
        fieldData = fieldData,
        collision = grid,
      }
      for _, tile in ipairs(doorTiles) do
        local fieldX, fieldZ = tile.x + scene.matrix.worldOriginX, tile.z + scene.matrix.worldOriginZ
        if MapProps.doorAt(props, runtimeMap, fieldX, fieldZ) == nil then
          error(
            versionId
              .. ": map "
              .. result.symbol
              .. " ("
              .. mapId
              .. ") warp-bearing door tile ("
              .. fieldX
              .. ","
              .. fieldZ
              .. ") does not resolve",
            0
          )
        end
      end
      checkedMaps = checkedMaps + 1
      checkedTiles = checkedTiles + #doorTiles
    end
  end
  Assert.isTrue(checkedMaps > 0, versionId .. ": the census found warp-bearing door maps")
  Assert.isTrue(checkedTiles > 0, versionId .. ": the census found warp-bearing door tiles")
end

local suite = require("tests.rom.support.RomSuite").fromFacts(T)
suite.metadata.capabilities = { "rom_dump", "derived_cache" }
return suite
