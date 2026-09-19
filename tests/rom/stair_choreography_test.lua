-- Private target test: the stair choreography against the real
-- HGSS dump, run through the production FieldTransition over the real
-- player-house stair pair: 1F (3,3) <-> 2F (3,4), both WARP_STAIRS_WEST (95)
-- standing tiles gated on facing west. Both directions must: lock input,
-- use the source slow horizontal step, play the source-owned HGSS stair sound
-- (SEQ_SE_DP_KAIDAN2), swap only at full black, skip coordinate
-- suppression (pressing the gate direction on the destination stair tile
-- re-arms immediately), and unlock at the end of the destination fade-in --
-- no door animation anywhere. Runs against every ready dump through the ROM
-- layer.

local Assert = require("tests.support.Assert")
local DoorTiles = require("libs.hgss.src.transition.DoorTiles")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local FieldTransition = require("libs.hgss.src.transition.FieldTransition")
local FieldTransitionProfile = require("libs.hgss.src.transition.FieldTransitionProfile")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local MapProps = require("libs.hgss.src.world.MapProps")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local RomRuntimeMap = require("tests.support.RomRuntimeMap")
local TransitionTrigger = require("libs.hgss.src.transition.TransitionTrigger")
local WarpSystem = require("libs.hgss.src.transition.WarpSystem")
local CompiledAsset = require("tests.rom.support.CompiledAsset")

local T = {}

local HOUSE_1F = "MAP_NEW_BARK_PLAYER_HOUSE_1F"
local HOUSE_2F = "MAP_NEW_BARK_PLAYER_HOUSE_2F"

-- One compiled scene: the runtime map and the MapProps facade, the shape
-- MapSceneLoader produces (the player house carries no building placements,
-- so there are no animated instances to advance).
-- The model-space AABB of a descriptor's geometry, recomputed from the
-- compiled bundle's mesh table (the loader stamps this from the decoded
-- .g4mesh assets).
local function footprintOf(desc, assets)
  local batches = desc.kind == "static" and desc.batches or desc.dynamic.batches
  local minX, maxX, minZ, maxZ
  for _, batch in ipairs(batches) do
    local sha = assert(batch.geometry:match("geometry/([%w]+)%.g4mesh"), "batch references .g4mesh geometry")
    local mesh = assert(assets.meshes[sha], "batch geometry present in the bundle")
    for _, v in ipairs(CompiledAsset.mesh(mesh).vertices) do
      minX = minX == nil and v[1] or math.min(minX, v[1])
      maxX = maxX == nil and v[1] or math.max(maxX, v[1])
      minZ = minZ == nil and v[3] or math.min(minZ, v[3])
      maxZ = maxZ == nil and v[3] or math.max(maxZ, v[3])
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

local function compileScene(romFs, symbol)
  local assets = assert(MapAssetCompiler.compile(romFs, symbol))
  local instances = {}
  local placements = {}
  for _, inst in ipairs(assets.scene.buildingInstances or {}) do
    local desc = assert(assets.models[inst.modelKey], "placement model descriptor")
    if desc.kind == "nitro-dynamic" then
      instances[inst.placementIndex] =
        ModelInstance.new(ModelDefinition.fromNitroDescriptor(desc, { key = inst.modelKey }))
    end
    placements[#placements + 1] = {
      placementIndex = inst.placementIndex,
      modelKey = inst.modelKey,
      transform = inst.transform,
      bounds = footprintOf(desc, assets),
    }
  end
  local map = RomRuntimeMap.compile(romFs, symbol)
  local props = MapProps.new({
    placements = placements,
    instances = instances,
    doorTiles = DoorTiles.fromGrid(map.collision),
  })
  return { map = map, props = props, instances = instances }
end

local function surfaceAt(map, fieldX, fieldZ)
  local localX, localZ = FieldCoordinates.fieldToLocal(map, fieldX, fieldZ)
  local candidates = map.terrain:candidatesAt(localX + 0.5, localZ + 0.5)
  Assert.isTrue(#candidates > 0, "spawn tile has terrain")
  return candidates[1].id
end

-- Drive one full stair choreography over the real pair. `spawn` places the
-- source player on the standing stair warp tile; preparation builds the
-- destination player before the black-screen commit, like FieldRuntime.
-- Returns the final player, the transition, the first-tick phase timeline,
-- and the recorded sound ids.
local function runChoreography(_, sourceScene, destinationScene, stairWarp, facing, spawn)
  local srcMap, destinationMap = sourceScene.map, destinationScene.map
  local maps = { [srcMap.mapId] = srcMap, [destinationMap.mapId] = destinationMap }
  local propsByMapId = { [srcMap.mapId] = sourceScene.props, [destinationMap.mapId] = destinationScene.props }
  local instancesByMapId = {
    [srcMap.mapId] = sourceScene.instances,
    [destinationMap.mapId] = destinationScene.instances,
  }
  local loader = {
    load = function(_, mapId)
      return assert(maps[mapId], "map " .. tostring(mapId))
    end,
    requestWarp = function(_, sourceMap, warp)
      assert(type(sourceMap) == "table", "fixture warp source is required")
      assert(type(warp) == "table", "fixture warp record is required")
      assert(maps[warp.destinationMapId], "fixture destination is not preloaded")
      return true
    end,
    protectMap = function() end,
  }

  ---@cast srcMap RuntimeFieldMap
  local player = FieldPlayer.new({
    currentMap = srcMap,
    fieldX = spawn.x,
    fieldZ = spawn.z,
    surfaceId = surfaceAt(srcMap, spawn.x, spawn.z),
    facing = facing,
  })

  local sounds = {}
  local transition
  local currentInstances = sourceScene.instances
  transition = FieldTransition.new({
    loader = loader,
    doorAt = function(runtimeMap, x, z)
      local props = propsByMapId[runtimeMap.mapId]
      if not props then
        return nil
      end
      return props:doorAt(runtimeMap, x, z)
    end,
    playSound = function(soundId)
      sounds[#sounds + 1] = soundId
    end,
    prepare = function(resolution, swapFacing)
      return FieldPlayer.new({
        currentMap = resolution.destinationMap,
        fieldX = resolution.fieldX,
        fieldZ = resolution.fieldZ,
        surfaceId = resolution.surfaceId,
        facing = swapFacing,
      })
    end,
    commit = function(resolution, _, preparedPlayer)
      Assert.equal(transition.fadeAlpha, 1, "the swap happens only at full black")
      player = preparedPlayer
      transition.player = player
      currentInstances = instancesByMapId[resolution.destinationMap.mapId]
    end,
  })
  transition.player = player
  transition:start(srcMap, { kind = "stairs", warp = stairWarp }, facing)

  -- The fixed-tick loop mirrors the session: the transition ticks, and while
  -- the stair choreography is active the scene's animated instances advance.
  local timeline = {}
  local ticks = 0
  while transition.phase ~= "idle" and transition.phase ~= "error" and ticks < 500 do
    ticks = ticks + 1
    transition:updateFixed()
    if transition.locked or transition.completed then
      for _, instance in ipairs(currentInstances) do
        instance:updateFixed()
      end
    end
    transition:updateSourceFrame()
    if timeline[transition.phase] == nil then
      timeline[transition.phase] = ticks
    end
  end
  Assert.equal(transition.phase, "idle", "the stair choreography completes within the tick budget")
  return transition, player, timeline, sounds
end

-- 1F (3,3) -> 2F: the standing WARP_STAIRS_WEST tile climbs in place while
-- the fade runs; the swap lands the player on the 2F stair tile (3,4), which
-- is itself a standing stair warp -- pressing west there re-arms immediately.
function T.house_1f_to_2f_stairs_choreograph(romFs, _)
  local h1 = compileScene(romFs, HOUSE_1F)
  local h2 = compileScene(romFs, HOUSE_2F)
  local warp = assert(WarpSystem.findAt(h1.map, 3, 3))
  local transition, player, timeline, sounds = runChoreography(romFs, h1, h2, warp, "west", {
    x = 3,
    z = 3,
  })

  Assert.equal(player.fieldX, 3)
  Assert.equal(player.fieldZ, 4, "the ascent lands on the 2F stair tile")
  Assert.equal(player.motion, "idle")
  Assert.isFalse(transition.locked, "input unlocks once the destination fade-in completes")
  Assert.isNil(transition.suppression, "stair warps never carry coordinate suppression")
  Assert.notNil(timeline.choreo_hold, "stairs hold until destination presentation completes")
  Assert.equal(#sounds, 1, "the source stair movement owns the stair sound")
  for _, id in ipairs(sounds) do
    Assert.equal(
      id,
      FieldTransitionProfile.ROUTINE_FAMILIES[FieldTransitionProfile.HORIZONTAL_STAIRS].exitSound,
      "the HGSS stair-climb sound id"
    )
  end
  Assert.isTrue(timeline.fade_out < timeline.swap_map, "the fade ran before the swap")
  Assert.equal(transition:consumeCompleted().sourceWarpId, warp.index)

  -- Immediate reversal: the destination tile is a standing stair warp, so
  -- pressing the gate direction re-arms the transition immediately.
  local back =
    assert(TransitionTrigger.inputPath(h2.map, player.fieldX, player.fieldZ, "west"), "the 2F stair tile re-triggers")
  Assert.equal(back.kind, "stairs")
  Assert.equal(assert(back.warp).destinationMapId, h1.map.mapId)
end

-- 2F (3,4) -> 1F: the descent mirrors the ascent and lands back on the 1F
-- stair tile (3,3), unlocked and immediately re-armed.
function T.house_2f_to_1f_stairs_choreograph(romFs, _)
  local h2 = compileScene(romFs, HOUSE_2F)
  local h1 = compileScene(romFs, HOUSE_1F)
  local warp = assert(WarpSystem.findAt(h2.map, 3, 4))
  local transition, player, timeline, sounds = runChoreography(romFs, h2, h1, warp, "west", {
    x = 3,
    z = 4,
  })

  Assert.equal(player.fieldX, 3)
  Assert.equal(player.fieldZ, 3, "the descent lands back on the 1F stair tile")
  Assert.equal(player.motion, "idle")
  Assert.isFalse(transition.locked)
  Assert.isNil(transition.suppression)
  Assert.notNil(timeline.choreo_hold)
  Assert.equal(#sounds, 1)
  Assert.isTrue(timeline.fade_out < timeline.swap_map)

  local back =
    assert(TransitionTrigger.inputPath(h1.map, player.fieldX, player.fieldZ, "west"), "the 1F stair tile re-triggers")
  Assert.equal(back.kind, "stairs")
end

return require("tests.rom.support.RomSuite").fromFacts(T)
