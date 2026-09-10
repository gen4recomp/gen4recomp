-- Corpus audit over every resolved map's warp-bearing DOOR tiles: the
-- deterministic MapAnalysis census selects the maps, the derived cache
-- supplies the real scene/collision/field/model records, and placements
-- carry the same ModelDoorMetadata join the production loader builds, so
-- ties classify exactly as the runtime does. Every warp-bearing DOOR tile
-- must assemble and resolve without ambiguity or coverage failure; the
-- audit names the version, map, and tile of the first failure instead of
-- swallowing it. Maps without a warp-bearing DOOR tile are skipped. The
-- targeted New Bark and Elm Lab door checks stay in the default tier; this
-- exhaustive audit runs only when the slow tier is selected.

local Assert = require("tests.support.Assert")
local DoorTiles = require("libs.hgss.src.transition.DoorTiles")
local ModelDoorMetadata = require("libs.hgss.src.world.ModelDoorMetadata")
local MapAnalysis = require("romdump.src.digest.map.MapAnalysis")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local CollisionGridAsset = require("libs.assets.src.field.CollisionGridAsset")
local CollisionGrid = require("libs.hgss.src.world.CollisionGrid")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local MapProps = require("libs.hgss.src.world.MapProps")

local T = {}

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
suite.metadata.slow = true
suite.metadata.tags = { "door", "census" }
suite.metadata.capabilities = { "rom_dump", "derived_cache" }
return suite
