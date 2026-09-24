-- The integration fixture for the door choreography suites: a REAL scene
-- compiled from the ROM dump, written into an in-memory cache in the
-- MapAssetCache layout, and loaded through the REAL MapSceneLoader with only
-- the filesystem and rendering boundaries substituted (a FakeCache backend and
-- fake mesh/image builders -- the pool's GPU seams). The loaded runtime
-- provides the REAL mapProps (precomputed door ownership), the REAL animated
-- ModelInstances, and the REAL scene animation clock; the harness drives them
-- through the REAL FieldSession + FieldTransition wired exactly like the game
-- (doorAt over the runtime map's sceneRuntime.mapProps, swap rebuilding the
-- player). Nothing about door ownership, model assembly, animation setup, or
-- the locked-tick loop is reconstructed here -- review #16's complaint.
--
-- The harness samples EXTERNALLY VISIBLE events after every tick: the door
-- handle's retained play handle (the tile's index entry holds the LIVE
-- attachment instance:play returned -- the collapsed animation surface) and
-- the finish state read off that handle on real MapDoor handles, plus the
-- real player's motion. The player event is sampled before the door event
-- because on the egress commit tick the step finishes and the close starts
-- in one transition advance -- the chronological order is step-finished then
-- close-start, and the unit contract's shared trace requires the same.

local Assert = require("tests.support.Assert")
local FakeCache = require("tests.support.FakeCache")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local FieldEventResolver = require("libs.hgss.src.interaction.FieldEventResolver")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldInput = require("libs.hgss.src.field.FieldInput")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local FieldSession = require("libs.hgss.src.field.FieldSession")
local FieldTransition = require("libs.hgss.src.transition.FieldTransition")
local LuaWriter = require("libs.codec.src.LuaWriter")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local CollisionGridAsset = require("libs.assets.src.field.CollisionGridAsset")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local MapSceneLoader = require("libs.hgss.src.presentation.MapSceneLoader")
local RomRuntimeMap = require("tests.support.RomRuntimeMap")
local CompiledAsset = require("tests.rom.support.CompiledAsset")

local SceneLoaderFixture = {}

-- The cache facade over the in-memory backend: loadLua reads and evals in an
-- empty environment, like CacheFs.loadLua.
local function luaCache(backend)
  local function loadLua(path)
    local data = assert(backend:read(path), "missing cache file " .. path)
    local chunk = assert(loadstring(data, path))
    setfenv(chunk, {})
    local ok, result = pcall(chunk)
    assert(ok, result)
    return result
  end
  local result = {
    read = function(_, path)
      return backend:read(path)
    end,
    loadLua = function(_, path)
      return loadLua(path)
    end,
  }
  ---@cast result CacheFs
  return result
end

-- The fake mesh builder for the loader's GPU seam: SceneMesh.decode output
-- becomes a plain object, so the loader's assembly, sharing, and playback
-- policy run headless in the ROM layer.
local function fakeMeshBuilder(decoded)
  return {
    id = decoded and decoded.name or "mesh",
    release = function() end,
  }
end

-- The fake image builder: the pool configures and releases images it builds;
-- the fake accepts those calls and never touches love.graphics. Texture bytes
-- are never read, so the bundle's textures are not written into the cache.
local function fakeImageBuilder()
  return {
    release = function() end,
    setFilter = function() end,
    setWrap = function() end,
  }
end

-- Write one compiled bundle into the cache layout the loader reads: scene.lua,
-- the collision asset, every content-addressed .g4mesh, and every model
-- descriptor. Texture blobs are deliberately omitted -- the fake image
-- builder never reads them.
local function writeBundle(backend, assets)
  local scene = assets.scene
  backend:write(MapAssetCache.mapDir(scene.mapId) .. "/scene.lua", LuaWriter.encode(scene))
  backend:write(scene.collision.file, CollisionGridAsset.encode(assets.collision))
  for sha, mesh in pairs(assets.meshes) do
    backend:write(MapAssetCache.geometryPath(sha), CompiledAsset.bytes(mesh))
  end
  for modelKey, desc in pairs(assets.models) do
    backend:write(MapAssetCache.modelPath(modelKey), LuaWriter.encode(desc))
  end
end

-- Compile one real scene, load it through the REAL MapSceneLoader with fake
-- mesh/image builders, and install the loader runtime as the runtime map's
-- sceneRuntime. `opts.editDescriptor(desc)` runs over every model descriptor
-- BEFORE the cache is written -- the deliberately-broken-door probes corrupt
-- the door's compiled clip there. Returns { map, runtime }; the caller must
-- release the runtime (pool ownership) when done.
---@param romFs table
---@param symbol string
---@param opts { editDescriptor?: fun(desc: table) }?
---@return { map: RuntimeFieldMap, runtime: table }
function SceneLoaderFixture.loadScene(romFs, symbol, opts)
  opts = opts or {}
  local assets = assert(MapAssetCompiler.compile(romFs, symbol))
  if opts.editDescriptor then
    for _, desc in pairs(assets.models) do
      opts.editDescriptor(desc)
    end
  end
  local backend = FakeCache.new()
  writeBundle(backend, assets)
  local cache = luaCache(backend)
  local scene = assert(cache:loadLua(MapAssetCache.mapDir(assets.scene.mapId) .. "/scene.lua"))
  local runtime = MapSceneLoader.load(cache, scene, {
    meshBuilder = fakeMeshBuilder,
    imageBuilder = fakeImageBuilder,
  })
  local map = RomRuntimeMap.compile(romFs, symbol, assets)
  map.sceneRuntime = runtime
  return { map = map, runtime = runtime }
end

-- A walkable surface id for a spawn tile (the door choreography steps the
-- player onto real terrain).
function SceneLoaderFixture.surfaceAt(map, fieldX, fieldZ)
  local localX, localZ = FieldCoordinates.fieldToLocal(map, fieldX, fieldZ)
  local candidates = map.terrain:candidatesAt(localX + 0.5, localZ + 0.5)
  assert(#candidates > 0, "spawn tile has terrain")
  return candidates[1].id
end

-- The production session harness: FieldSession + FieldInput + the real
-- FieldTransition wired like FieldState (doorAt over the runtime map's
-- sceneRuntime.mapProps, swap rebuilding the player and rebinding the
-- session), so the locked-tick path advances the real animated instances and
-- the swap lands on the real destination map. `opts.scenes` maps mapId ->
-- loaded scene ({ map, runtime }); `opts.spawn` places the source player;
-- `opts.doorTiles` maps mapId -> the door tile to sample there.
--
-- After every tick the harness records the HGSS event trace: the real door
-- handles' entry state and finish state (open-start, open-finished,
-- close-start, close-finished) and the player's motion edges (step-start,
-- step-finished). The harness also records the phase timeline, the walking
-- pose-clock ticks, and played sounds, like the acceptance harness.
---@param versionId string
---@param opts { scenes: { [integer]: { map: RuntimeFieldMap } }, spawn: { map: RuntimeFieldMap, x: integer, z: integer, facing: string }, doorTiles?: { [integer]: { x: integer, z: integer } } }
---@return table harness
function SceneLoaderFixture.newHarness(versionId, opts)
  local maps = {}
  for mapId, scene in pairs(opts.scenes) do
    maps[mapId] = scene.map
  end
  local loader = {
    load = function(_, mapId)
      return assert(maps[mapId], "map " .. tostring(mapId))
    end,
    transitionEnvironment = function(_, mapId)
      local map = assert(maps[mapId], "map " .. tostring(mapId))
      return assert(map.fieldData.transitionEnvironment, "map transition environment " .. tostring(mapId))
    end,
    protectMap = function() end,
  }
  local spawn = opts.spawn
  local player = FieldPlayer.new({
    currentMap = spawn.map,
    fieldX = spawn.x,
    fieldZ = spawn.z,
    surfaceId = SceneLoaderFixture.surfaceAt(spawn.map, spawn.x, spawn.z),
    facing = spawn.facing,
  })
  local harness = {
    versionId = versionId,
    maps = maps,
    loader = loader,
    input = FieldInput.new(),
    player = player,
    swapCount = 0,
    preSwapPosition = nil,
    sounds = {},
    timeline = {},
    ticks = 0,
    walkingPoseTicks = 0,
    onTick = nil,
    doorTiles = opts.doorTiles,
    events = {},
    walking = false,
    sawOpenStart = false,
    sawOpenFinished = false,
    sawCloseStart = false,
    sawCloseFinished = false,
  }
  local session
  local transition
  transition = FieldTransition.new({
    loader = loader,
    doorAt = function(runtimeMap, fieldX, fieldZ)
      return runtimeMap.sceneRuntime.mapProps:doorAt(runtimeMap, fieldX, fieldZ)
    end,
    playSound = function(soundId)
      harness.sounds[#harness.sounds + 1] = soundId
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
      harness.swapCount = harness.swapCount + 1
      harness.preSwapPosition = { x = player.fieldX, z = player.fieldZ }
      player = preparedPlayer
      transition.player = player
      harness.player = player
      session.currentMap = resolution.destinationMap
      session.player = player
    end,
  })
  transition.player = player
  local camera = {
    updateFixed = function() end,
    collapseRenderInterpolation = function() end,
  }
  local playerVisual = {
    updateFixed = function(_, walking)
      if walking then
        harness.walkingPoseTicks = harness.walkingPoseTicks + 1
      end
    end,
  }
  ---@cast camera FieldCamera
  ---@cast playerVisual FieldPlayerVisual
  local actors = { beginFixedStep = function() end, step = function() end }
  ---@cast actors FieldActorManager
  session = FieldSession.new({
    versionId = versionId,
    currentMap = spawn.map,
    actor = player,
    player = player,
    camera = camera,
    transition = transition,
    input = harness.input,
    playerVisual = playerVisual,
    fieldEntranceIndicator = { updateFixed = function() end },
    actors = actors,
    dialogue = {
      isModal = function()
        return false
      end,
    },
    interactions = { resolve = function() end },
    eventResolver = FieldEventResolver,
    eventState = FieldEventState.new(),
    scriptScheduler = {
      step = function() end,
      playerInputLocked = function()
        return false
      end,
      playerInputOwned = function()
        return false
      end,
      foregroundEnvironmentId = function()
        return nil
      end,
      autonomousActorsLocked = function()
        return false
      end,
      autonomousActorLocked = function()
        return false
      end,
    },
    scriptClient = { consume = function() end },
    menuHost = {
      isModal = function()
        return false
      end,
      advance = function() end,
    },
    contextChoice = {
      isActive = function()
        return false
      end,
    },
    signpost = {
      isModal = function()
        return false
      end,
    },
    applicationHost = {
      isActive = function()
        return false
      end,
      updateFixed = function() end,
      requestOpen = function() end,
      takeReopen = function()
        return false
      end,
    },
    bagUnlocked = function()
      return true
    end,
  })
  harness.session = session
  harness.transition = transition
  return harness
end

-- The semantic role of the door's retained play handle, or nil when nothing
-- plays: the tile's index entry holds the LIVE attachment handle from
-- instance:play (the collapsed animation surface), and the role is the
-- handle's clip semantic name.
---@param door table
---@return string?
function SceneLoaderFixture.entryRole(door)
  local animation = door.entry.animation
  if not animation then
    return nil
  end
  return animation.clip.semanticNames and animation.clip.semanticNames[1]
end

-- One fixed session tick: run the session, then sample the externally
-- visible events (player motion edges, then the real door handles on the
-- current map), record the phase timeline, and run the test's per-tick hook.
---@param harness table
function SceneLoaderFixture.tick(harness)
  harness.ticks = harness.ticks + 1
  harness.session:updateFixed()
  harness.transition:updateSourceFrame()
  local phase = harness.transition.phase
  if harness.timeline[phase] == nil then
    harness.timeline[phase] = harness.ticks
  end
  local player = harness.player
  if player.motion == "walking" then
    if not harness.walking then
      harness.events[#harness.events + 1] = "step-start"
      harness.walking = true
    end
  elseif harness.walking then
    harness.events[#harness.events + 1] = "step-finished"
    harness.walking = false
  end
  local map = harness.session.currentMap
  local props = map.sceneRuntime and map.sceneRuntime.mapProps
  local door
  if props and harness.doorTiles and harness.doorTiles[map.mapId] then
    local tile = harness.doorTiles[map.mapId]
    door = props:doorAt(map, tile.x, tile.z)
  end
  if door then
    local role = SceneLoaderFixture.entryRole(door)
    local finished = door:isFinished()
    if role == "door.open" then
      if not harness.sawOpenStart then
        harness.events[#harness.events + 1] = "open-start"
        harness.sawOpenStart = true
      end
      if finished and not harness.sawOpenFinished then
        harness.events[#harness.events + 1] = "open-finished"
        harness.sawOpenFinished = true
      end
    elseif role == "door.close" then
      if not harness.sawCloseStart then
        harness.events[#harness.events + 1] = "close-start"
        harness.sawCloseStart = true
      end
      if finished and not harness.sawCloseFinished then
        harness.events[#harness.events + 1] = "close-finished"
        harness.sawCloseFinished = true
      end
    end
  end
  if harness.onTick then
    harness.onTick(harness)
  end
end

-- Drive the session until the transition finishes (phase idle + a completion
-- event), with a hard tick budget; asserts the budget was not hit. Consumes
-- the completion like FieldState. Ticks at least once, so a transition that
-- starts on the first tick is driven.
---@param harness table
---@param maxTicks integer
function SceneLoaderFixture.drive(harness, maxTicks)
  local ticks = 0
  while true do
    SceneLoaderFixture.tick(harness)
    ticks = ticks + 1
    if harness.transition.phase == "idle" or harness.transition.phase == "error" or ticks >= maxTicks then
      break
    end
  end
  assert(harness.transition.phase == "idle", "the transition completes within the tick budget")
  assert(harness.transition:consumeCompleted() ~= nil, "the transition records a completion event")
end

-- No-arrival-bounce check: a run of input-free ticks must leave the player on
-- the arrival tile with no new transition.
---@param harness table
---@param ticks integer
function SceneLoaderFixture.assertStable(harness, ticks)
  local startX, startZ = harness.player.fieldX, harness.player.fieldZ
  for _ = 1, ticks do
    SceneLoaderFixture.tick(harness)
  end
  Assert.equal(harness.transition.phase, "idle", "no arrival bounce loop")
  Assert.equal(harness.player.fieldX, startX, "the player stays on the arrival tile")
  Assert.equal(harness.player.fieldZ, startZ, "the player stays on the arrival tile")
  Assert.isNil(harness.transition.completed, "no transition restarts without input")
end

return SceneLoaderFixture
