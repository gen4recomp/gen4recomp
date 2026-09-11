-- Scene-loader animation path tests: a scene whose building instance
-- references an animated (dynamic) model descriptor loads through
-- MapSceneLoader into a ModelInstance, advances with the scene runtime, and
-- renders through FieldRenderer. The descriptor shape is the compiler's:
-- explicit schema/kind, dynamic batches referencing content-addressed .g4mesh
-- geometry, compiled clips with playback policy (timeBand / ambientLoop).
-- The rendering tests build real GPU resources, so the whole suite declares
-- the graphics layer and the runner skips it explicitly on hosts without one.

local Assert = require("tests.support.Assert")
local Matrix3 = require("libs.math.src.Matrix3")
local MapSceneLoader = require("libs.hgss.src.presentation.MapSceneLoader")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local FieldGrid = require("libs.hgss.src.world.FieldGrid")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local FieldSession = require("libs.hgss.src.field.FieldSession")
local FieldEventResolver = require("libs.hgss.src.interaction.FieldEventResolver")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.codec.src.LuaWriter")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local CollisionGridAsset = require("libs.assets.src.field.CollisionGridAsset")
local TextureSrtEvaluator = require("libs.hgss.src.presentation.TextureSrtEvaluator")

local T = {}

-- A disabled fog preset shape (HgssFieldFog.runtimePreset's shape for a
-- disabled weather), the default for scene builders not exercising fog
-- forwarding itself.
local function defaultFogFixture()
  local table32 = {}
  for i = 1, 32 do
    table32[i] = 0
  end
  return { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = table32 }
end

-- A 32x32 all-plain collision grid (the scene cell), optionally with
-- DOOR-behavior (105) tiles. `doorTiles` is either one { x, z } tile or a
-- list of them.
local function collisionGrid(doorTiles)
  local cells = {}
  for index = 1, 32 * 32 do
    cells[index] = { behavior = 0, terrainResponseId = 0, blocked = false }
  end
  local function mark(tile)
    cells[tile.z * 32 + tile.x + 1] = { behavior = 105, terrainResponseId = 0, blocked = false }
  end
  if doorTiles then
    if doorTiles.z ~= nil then
      mark(doorTiles)
    else
      for _, tile in ipairs(doorTiles) do
        mark(tile)
      end
    end
  end
  return CollisionGridAsset.encode({ width = 32, height = 32, cells = cells })
end

local function identity9()
  return { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
end

local function identityMatrix()
  return { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
end

-- The transform of a door placement at the door tile (4,14)'s centre -- the
-- tile the door fixtures enumerate, so the placement sits within the
-- corpus-backed door-ownership bound (the scene fixture's cell origin is
-- (0,0)).
local function doorTransform()
  local wx, wz = FieldGrid.tileCenterToWorld(4, 14)
  local transform = identityMatrix()
  transform[13] = wx
  transform[15] = wz
  return transform
end

-- The in-memory cache facade over a FakeCache backend: loadLua reads and
-- evals in an empty environment, like CacheFs.loadLua.
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

-- The 2x2-tile quad in tile space (MeshWriter vertex shape).
local function doorQuad()
  local function v(x, z)
    return {
      x = x,
      y = 0,
      z = z,
      u = 0,
      v = 0,
      nx = 0,
      ny = 1,
      nz = 0,
      r = 255,
      g = 255,
      b = 255,
      a = 255,
      colorSource = 0,
    }
  end
  return {
    vertices = { v(0, 0), v(2, 0), v(2, 2), v(0, 2) },
    indices = { 0, 1, 2, 0, 2, 3 },
  }
end

local function doorProgram()
  return {
    name = "wk_door3",
    scalingRule = 0,
    posScale = 1,
    invPosScale = 1,
    tileScale = 1 / 16,
    nodes = {
      {
        index = 0,
        matrixStackIndex = 0,
        translation = { x = 0, y = 0, z = 0 },
        rotation = identity9(),
        scale = { x = 1, y = 1, z = 1 },
        transZero = true,
        rotZero = true,
        scaleOne = true,
      },
    },
    commands = {
      { opcode = 0x06, nodeIndex = 0, parentIndex = 0, flags = 0 },
      { opcode = 0x02, nodeIndex = 0, visible = true },
      { opcode = 0x04, materialIndex = 0 },
      { opcode = 0x05, shapeIndex = 0 },
      { opcode = 0x01 },
    },
    evpMatrices = nil,
  }
end

-- A compiled NSBCA-style pivot rotation clip (pivot A = 1 - i/16, B = i/16,
-- like the real `door_op`).
local function swingClip(id, name, semantic)
  local rotData = {}
  for i = 0, 7 do
    rotData[i + 1] = { control = 0x0024, a = 4096 - i * 256, b = i * 256 }
  end
  local keys = {}
  for i = 0, 7 do
    keys[i + 1] = 0x8000 + i
  end
  return {
    id = id,
    name = name,
    category = "joint",
    kind = "trs",
    frameCount = 8,
    tracks = { { target = 0, targetIndex = 0 } },
    semanticNames = semantic and { semantic } or {},
    source = { type = "nitro", format = "NSBCA", archive = "build_anim", memberId = 1 },
    compiled = {
      anmFlags = 0,
      rotData = rotData,
      pivotData = {},
      targets = {
        {
          nodeIndex = 0,
          channels = {
            trans = { x = { source = "model" }, y = { source = "model" }, z = { source = "model" } },
            rot = { source = "curve", rate = 1, limit = 8, storage = "fx16", keys = keys },
            scale = { x = { source = "model" }, y = { source = "model" }, z = { source = "model" } },
          },
        },
      },
    },
  }
end

-- The serialized dynamic descriptor shape MapAssetCompiler writes for an
-- animated building: an 8-frame door with a compiled NSBCA pivot rotation.
-- The dynamic batches reference the content-addressed .g4mesh path of the
-- encoded quad; the fixture writes those bytes into the cache alongside.
local function doorDescriptor()
  -- Content-addressed key: the same literal the fixture writes the encoded
  -- quad under (the geometry path is arbitrary within this test).
  local meshSha = "mesh_door_quad_0000000000000000000000000000000000"
  return {
    schema = "g4-model-v5",
    key = "outdoor:26:door",
    memberId = 26,
    kind = "nitro-dynamic",
    dynamic = {
      nodes = {
        {
          index = 0,
          matrixStackIndex = 0,
          translation = { x = 0, y = 0, z = 0 },
          rotation = identity9(),
          scale = { x = 1, y = 1, z = 1 },
          transZero = true,
          rotZero = true,
          scaleOne = true,
        },
      },
      transformProgram = doorProgram(),
      batches = {
        {
          id = "draw0.seg0",
          drawIndex = 0,
          segmentIndex = 0,
          nodeIndex = 0,
          materialIndex = 0,
          transformMode = "static",
          positionSource = "draw",
          geometry = MapAssetCache.geometryPath(meshSha),
          cullMode = "back",
          polygonMode = "modulation",
          polygonId = 0,
          translucentDepthWrite = false,
          depthEqual = false,
          polygonAlpha = 31,
          lightMask = 5,
        },
      },
    },
    materials = {
      {
        id = 0,
        name = "wall",
        baseColor = { r = 255, g = 255, b = 255, a = 255 },
        alphaMode = "opaque",
        polygonMode = "modulation",
        doubleSided = false,
        polygonAlpha = 31,
        texMtxMode = 0,
        texWidth = 0,
        texHeight = 0,
        wrap = { x = "clamp", y = "clamp" },
        flip = { x = false, y = false },
      },
    },
    animations = { swingClip("build_anim-1", "door_op", "door.open") },
    doorSoundType = 1,
  }
end

-- The door descriptor's single clip re-parameterized: a banded-sky clip
-- (the compiled record stays a valid NSBCA pivot).
local BAND_BY_SUFFIX = { m = "morn", d = "day", e = "eve", n = "nite" }

local function skyClipRecord(name)
  local base = assert(doorDescriptor()).animations[1]
  local clip = {}
  for k, v in pairs(base) do
    clip[k] = v
  end
  clip.id = "sky:" .. name
  clip.name = name
  clip.semanticNames = {}
  clip.timeBand = BAND_BY_SUFFIX[name:match("_(%a)$")]
  return clip
end

-- The door descriptor with the full open/close pair (the multi-clip shape:
-- nothing auto-plays; the door choreography scripts the roles).
local function doorPairDescriptor()
  local desc = doorDescriptor()
  local close = skyClipRecord("door_cl")
  close.id = "build_anim-2"
  close.semanticNames = { "door.close" }
  close.timeBand = nil
  desc.animations[2] = close
  return desc
end

-- A banded model descriptor: the door's program with four time-of-day clips
-- (kk_sky_m/d/e/n, the corpus naming convention).
local function skyDescriptor()
  local desc = doorDescriptor()
  desc.key = "indoor:113:sky"
  desc.memberId = 113
  desc.animations = {
    skyClipRecord("kk_sky_m"),
    skyClipRecord("kk_sky_d"),
    skyClipRecord("kk_sky_e"),
    skyClipRecord("kk_sky_n"),
  }
  return desc
end

-- A single non-door clip: the compiled ambient role (the field effects --
-- wind, machine, spring).
local function ambientDescriptor()
  local desc = doorDescriptor()
  desc.key = "outdoor:7:wind"
  desc.memberId = 7
  local clip = swingClip("build_anim-3", "wind", nil)
  clip.ambientLoop = true
  desc.animations = { clip }
  return desc
end

-- A static (non-animated) building descriptor: one plain quad batch, no
-- transform program, sharing the door descriptor's material list (the
-- material shape is kind-independent).
local function staticBuildingDescriptor()
  local meshSha = "mesh_static_hut_quad_000000000000000000000000000000"
  return {
    schema = "g4-model-descriptor-v1",
    key = "outdoor:1:hut",
    memberId = 1,
    kind = "static",
    batches = {
      {
        geometry = MapAssetCache.geometryPath(meshSha),
        material = 0,
        alphaClass = "opaque",
        cullMode = "back",
        polygonMode = "modulation",
        polygonId = 0,
        translucentDepthWrite = false,
        depthEqual = false,
        polygonAlpha = 31,
        lightMask = 0,
      },
    },
    materials = doorDescriptor().materials,
  }
end

-- A minimal scene with the given building instances over the given model
-- descriptors, in the loader test fixture shape. Writes each descriptor's
-- referenced .g4mesh geometry into the cache. `doorTiles` (optional local
-- indices) marks the listed tiles with the DOOR behavior (105) in the
-- permission cell, so the loader's MapProps precomputes door ownership over
-- them.
local function sceneWith(instances, descriptors, doorTiles)
  local mapId = 61
  local backend = FakeCache.new()
  local dir = MapAssetCache.mapDir(mapId)
  local scene = {
    schema = MapAssetCache.SCENE_SCHEMA,
    versionId = "heartgold",
    mapId = mapId,
    mapSymbol = "MAP_NEW_BARK",
    matrix = {
      memberId = 0,
      name = "map",
      width = 1,
      height = 1,
      x = 0,
      z = 0,
      index = 0,
      altitude = 0,
      worldOriginX = 0,
      worldOriginZ = 0,
    },
    area = {
      memberId = 2,
      type = "outdoor",
      mapTexturePackId = 0,
      buildingTexturePackId = 0,
      dynamicTextureType = 0,
      lightType = 0,
    },
    collision = { width = 32, height = 32, file = dir .. "/collision.g4collision" },
    mapBatches = {},
    materials = {},
    buildingInstances = instances,
    neighbors = {},
    terrainAnimations = { textureSrt = false },
    lighting = nil,
    fog = defaultFogFixture(),
  }
  backend:write(dir .. "/scene.lua", LuaWriter.encode(scene))
  for _, desc in pairs(descriptors) do
    backend:write(MapAssetCache.modelPath(desc.key), LuaWriter.encode(desc))
    local batches = desc.kind == "nitro-dynamic" and desc.dynamic.batches or desc.batches
    for _, batch in ipairs(batches) do
      backend:write(batch.geometry, MeshWriter.encode(doorQuad()))
    end
  end
  backend:write(dir .. "/collision.g4collision", collisionGrid(doorTiles))
  return luaCache(backend)
end

-- The runtime-map shape doorAt consumes for a loader-built runtime: the
-- loader's collision is the permission grid, the cell origin is (0,0) (the
-- fixture matrix), and the door tile carries a warp record.
local function doorMapFor(runtime, x, z)
  return {
    mapId = 61,
    coordinateOrigin = { x = 0, z = 0 },
    fieldData = {
      events = {
        warps = {
          { index = 0, x = x, z = z, destinationMapId = 60, destinationWarpId = 0, y = 0 },
        },
      },
    },
    collision = runtime.collision,
  }
end

-- A fake mesh builder for the loader's GPU seam: SceneMesh.decode output
-- becomes a plain object, so the loader's assembly, sharing, and playback
-- policy run headless.
local function fakeMeshBuilder(decoded)
  return {
    id = decoded and decoded.name or "mesh",
    release = function() end,
  }
end

-- A fake image builder that RECORDS the sampler configuration: the pool
-- configures every image it builds with image:setWrap(wrapX, wrapY), so the
-- recorded wrap pair is the observable imageFor request. `images` collects
-- the built objects in build order, each tagged with its texture path.
local function recordingImageBuilder(images)
  return function(path)
    local image = { path = path, wraps = {} }
    image.setFilter = function() end
    image.setWrap = function(_, wrapX, wrapY)
      image.wraps[#image.wraps + 1] = { wrapX, wrapY }
    end
    image.release = function() end
    images[#images + 1] = image
    return image
  end
end

-- Run a live callback in a disposable coroutine so an accidental construction
-- checkpoint is observable as a suspended callback instead of being hidden by
-- the host's main-thread coroutine behavior.
local function runToCompletion(callback)
  local thread = coroutine.create(callback)
  local ok, result = coroutine.resume(thread)
  Assert.isTrue(ok, tostring(result))
  Assert.equal(coroutine.status(thread), "dead", "the live callback must not yield")
end

-- The door descriptor with a textured material: base texture (64x64) plus
-- optional pattern variants, sampled under the material's wrap pair. The
-- loader maps every texture key (base and variants) to the material's wrap
-- for the animated resolveImage path; the fixture pins that the resolve
-- requests carry the precomputed wrap, never an unconditional clamp.
local function texturedDescriptor(opts)
  opts = opts or {}
  local desc = doorDescriptor()
  desc.key = "outdoor:26:texdoor"
  desc.memberId = 26
  local material = desc.materials[1]
  material.texture = opts.baseTexture or MapAssetCache.texturePath("texbase")
  material.texWidth = 64
  material.texHeight = 64
  material.textureFormat = 3
  material.alphaUsage = { hasZero = true }
  material.wrap = opts.wrap or { x = "repeat", y = "repeat" }
  material.variants = opts.variants
  desc.animations = opts.animations or desc.animations
  return desc
end

-- A compiled NSBTP-style pattern clip selecting the first variant at frame 0.
local function patternClip()
  return {
    id = "build_anim-3",
    name = "pattern",
    category = "material",
    kind = "pattern",
    frameCount = 8,
    tracks = { { target = "wall", targetIndex = 0 } },
    semanticNames = {},
    source = { type = "nitro", format = "NSBTP", archive = "build_anim", memberId = 3 },
    compiled = {
      textureNames = { "v1" },
      paletteNames = {},
      targets = {
        {
          index = 0,
          name = "wall",
          rate = 0x1000,
          keys = { { frame = 0, texIdx = 0, plttIdx = 0xFF } },
        },
      },
    },
  }
end

-- ---- terrain animation fixtures ----

-- The new-bark-like replacement schedule: R0 for 18 ticks, R1 for 18, R0
-- for 18, R2 for 18, loop.
local function flowerSteps()
  return {
    { texture = "a.png", durationTicks = 18 },
    { texture = "b.png", durationTicks = 18 },
    { texture = "a.png", durationTicks = 18 },
    { texture = "c.png", durationTicks = 18 },
  }
end

-- A scene-form terrain material with a texture-swap descriptor. The initial
-- image `baseTexture` is the map texture pack's bound image and is NOT part
-- of the replacement schedule.
local function swapMaterial(id, name, baseTexture, steps)
  return {
    id = id,
    name = name,
    texture = baseTexture,
    wrap = { x = "repeat", y = "repeat" },
    texWidth = 16,
    texHeight = 16,
    texMtxMode = 0,
    textureSwap = {
      name = name,
      steps = steps,
    },
  }
end

-- A compiled texsrt clip in the NsbtaClipCompiler payload shape (the scene's
-- terrainAnimations.textureSrt): one target with a translation-S curve and
-- identity scale/rotation constants, matching the pure animator-test fixture.
local function terrainSrtClip(frames, transKeys)
  return {
    id = "fixture:area00_ani",
    name = "area00_ani",
    category = "material",
    kind = "texsrt",
    frameCount = frames,
    tracks = { { target = "water", targetIndex = 0 } },
    semanticNames = {},
    compiled = {
      targets = {
        {
          index = 0,
          name = "water",
          channels = {
            scaleS = { source = "constant", value = 0x1000 },
            scaleT = { source = "constant", value = 0x1000 },
            rot = { source = "constant", value = 0x10000000 },
            transS = { source = "curve", rate = 1, limit = frames, storage = "fx32", keys = transKeys },
            transT = { source = "constant", value = 0 },
          },
        },
      },
    },
  }
end

-- A terrain-only scene over the given materials: one map batch per material
-- (all sharing one geometry path), no buildings, no neighbors, and the
-- optional compiled terrain-SRT clip (false = no area animation). Returns
-- the cache facade and the scene table.
local function terrainScene(materials, clip)
  local mapId = 61
  local backend = FakeCache.new()
  local dir = MapAssetCache.mapDir(mapId)
  local scene = {
    schema = MapAssetCache.SCENE_SCHEMA,
    versionId = "heartgold",
    mapId = mapId,
    mapSymbol = "MAP_NEW_BARK",
    matrix = {
      memberId = 0,
      name = "map",
      width = 1,
      height = 1,
      x = 0,
      z = 0,
      index = 0,
      altitude = 0,
      worldOriginX = 0,
      worldOriginZ = 0,
    },
    area = {
      memberId = 2,
      type = "outdoor",
      mapTexturePackId = 0,
      buildingTexturePackId = 0,
      dynamicTextureType = 0,
      lightType = 0,
    },
    collision = { width = 32, height = 32, file = dir .. "/collision.g4collision" },
    mapBatches = {},
    materials = materials,
    buildingInstances = {},
    neighbors = {},
    lighting = nil,
    terrainAnimations = { textureSrt = clip or false },
    fog = defaultFogFixture(),
  }
  local geomPath = MapAssetCache.geometryPath("terrain-quad")
  for _, material in ipairs(materials) do
    scene.mapBatches[#scene.mapBatches + 1] = {
      geometry = geomPath,
      material = material.id,
      cullMode = "back",
      polygonMode = "modulation",
      polygonId = 0,
      translucentDepthWrite = false,
      depthEqual = false,
      polygonAlpha = 31,
      lightMask = 0,
      alphaClass = "opaque",
    }
  end
  backend:write(dir .. "/scene.lua", LuaWriter.encode(scene))
  backend:write(geomPath, MeshWriter.encode(doorQuad()))
  backend:write(dir .. "/collision.g4collision", collisionGrid())
  return luaCache(backend), scene
end

-- A fake image builder that records created images and their release calls,
-- so the loader's pool ownership is observable: `images` collects the built
-- objects in build order, each tagged with its texture path and a release
-- counter.
local function trackingImageBuilder(images)
  return function(path)
    local image = { path = path, releases = 0 }
    image.setFilter = function() end
    image.setWrap = function() end
    image.release = function()
      image.releases = image.releases + 1
    end
    images[#images + 1] = image
    return image
  end
end

-- A tracking image builder that raises on the Nth build call (the failed
-- creation still records its own entry, so the test sees the failure landed
-- on an alternate-frame creation; the pool never owns that object).
local function failingImageBuilder(images, failOn)
  return function(path)
    local image = { path = path, releases = 0 }
    image.setFilter = function() end
    image.setWrap = function() end
    image.release = function()
      image.releases = image.releases + 1
    end
    images[#images + 1] = image
    if #images == failOn then
      error("injected alternate-image failure")
    end
    return image
  end
end

function T.animated_building_loads_advances_and_renders()
  local mapId = 61
  local backend = FakeCache.new()
  local dir = MapAssetCache.mapDir(mapId)
  local scene = {
    schema = MapAssetCache.SCENE_SCHEMA,
    versionId = "heartgold",
    mapId = mapId,
    mapSymbol = "MAP_NEW_BARK",
    matrix = {
      memberId = 0,
      name = "map",
      width = 1,
      height = 1,
      x = 0,
      z = 0,
      index = 0,
      altitude = 0,
      worldOriginX = 0,
      worldOriginZ = 0,
    },
    area = {
      memberId = 2,
      type = "outdoor",
      mapTexturePackId = 0,
      buildingTexturePackId = 0,
      dynamicTextureType = 0,
      lightType = 0,
    },
    collision = { width = 32, height = 32, file = dir .. "/collision.g4collision" },
    mapBatches = {},
    materials = {},
    buildingInstances = {
      {
        placementIndex = 0,
        modelKey = "outdoor:26:door",
        -- The door model is placed at the door tile (4,14)'s centre, which
        -- the door lookup measures against.
        transform = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -11.5, 0, -1.5, 1 },
      },
    },
    neighbors = {},
    terrainAnimations = { textureSrt = false },
    lighting = nil,
    edgeColors = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 },
    fog = defaultFogFixture(),
  }
  local descriptor = doorDescriptor()
  local modelPath = MapAssetCache.modelPath("outdoor:26:door")

  backend:write(dir .. "/scene.lua", LuaWriter.encode(scene))
  backend:write(modelPath, LuaWriter.encode(descriptor))
  for _, batch in ipairs(descriptor.dynamic.batches) do
    backend:write(batch.geometry, MeshWriter.encode(doorQuad()))
  end
  -- The door tile (4,14) carries DOOR behavior (105); everything else is
  -- plain floor, so the door lookup resolves the placed door model.
  backend:write(dir .. "/collision.g4collision", collisionGrid({ x = 4, z = 14 }))

  local cache = luaCache(backend)
  local runtime = MapSceneLoader.load(cache, scene)
  Assert.equal(runtime.stats.animatedInstances, 1)
  Assert.equal(#runtime.animatedInstances, 1)

  -- The door is scripted (its clip carries a door role, not ambientLoop);
  -- loading still produces the frame-0 renderable draw list immediately --
  -- the animated item exists without any tick -- and the animation clock
  -- has not advanced.
  local instance = runtime.animatedInstances[1]
  Assert.equal(#runtime.animatedBuildingDraws, 1, "the animated door item exists right after load")
  local m0 = runtime.animatedBuildingDraws[1].transform
  local normal0 = runtime.animatedBuildingDraws[1].modelNormal
  Assert.deepEqual(normal0, Matrix3.modelNormal(m0), "load builds the frame-0 model normal")
  -- The animated draw items carry the compiled per-segment polygon state:
  -- the light mask survives descriptor -> definition -> drawItems on the
  -- loader-assembled animated model.
  Assert.equal(runtime.animatedBuildingDraws[1].lightMask, 5, "the animated door item carries its polygon light mask")

  -- Advance and sync: a scripted door holds its bind pose.
  for _ = 1, 7 do
    runtime:updateAnimated()
  end
  local m7 = runtime.animatedBuildingDraws[1].transform
  for i = 1, 16 do
    Assert.near(m0[i], m7[i], 1e-3, "a scripted door holds its bind pose until played")
  end

  -- The production renderer draws the animated door. The renderer takes
  -- ordered parts; the loader's sync refreshed runtime.animatedBuildingDraws.
  local renderer = FieldRenderer.new()
  local identity = identityMatrix()
  local camera = {
    cameraSourceY = 0,
    cameraAppliedY = 0,
    zoom = 1,
    projectionType = "orthographic",
    profile = {},
    distance = 26,
    near = 0.1,
    far = 400,
    sourceTarget = { x = 0, y = 0, z = 0 },
    target = { x = 0, y = 0, z = 0 },
    previousTarget = { x = 0, y = 0, z = 0 },
    eye = { x = 0, y = 0, z = 0 },
    previousEye = { x = 0, y = 0, z = 0 },
    up = { x = 0, y = 1, z = 0 },
    history = {},
    historyEnabled = false,
    canonicalAspect = 1,
    projectionAspect = 1,
    _billboardDepthOffset = 0,
    _projectionDirty = false,
    view = function()
      return identity
    end,
    projection = function()
      return identity
    end,
    billboardProjection = function()
      return identity
    end,
  } --[[@as FieldCamera]]
  renderer:draw(
    runtime,
    camera,
    { runtime.animatedBuildingDraws },
    nil,
    FieldViewport.new(320, 240, { mode = "strict" }),
    1
  )
  Assert.isTrue(renderer.stats.drawCalls >= 1, "the animated door draws")

  -- The handle surface drives the semantic role on the loader-built
  -- instance: play returns the live attachment, whose player reaches the
  -- checked-advance terminal (numFrame * FRAME_UNIT) exactly.
  local handle = instance:play("door.open", { loopMode = "once" })
  Assert.equal(type(handle), "table", "play returns the attachment handle")
  Assert.equal(handle.clip.name, "door_op")
  for _ = 1, 7 do
    instance:updateFixed()
  end
  Assert.isFalse(handle.player:isComplete(), "the checked advance is not done before the terminal")
  instance:updateFixed()
  Assert.isTrue(handle.player:isComplete())

  local doorMap = {
    mapId = 61,
    coordinateOrigin = { x = 0, z = 0 },
    fieldData = {
      events = {
        warps = {
          { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0, y = 0 },
        },
      },
    },
    collision = runtime.collision,
  }
  -- The scene's door lookup resolves the loader-built instance from the door
  -- tile and drives the semantic door animation (the manual play above is
  -- stopped first: one attachment per kind, so the door replay must not
  -- stack).
  instance:stop(handle)
  local door = runtime.mapProps:doorAt(doorMap, 4, 14)
  assert(door)
  Assert.equal(door.instance, instance)
  Assert.equal(door.modelKey, "outdoor:26:door")
  Assert.equal(door:open(), "SEQ_SE_DP_DOOR_OPEN")
  for _ = 1, 7 do
    instance:updateFixed()
  end
  Assert.isFalse(door:isFinished(), "the checked advance is not done before the terminal")
  instance:updateFixed()
  Assert.isTrue(door:isFinished(), "the loader-resolved door opens to completion")

  renderer:release()
  runtime:release()
end

function T.shared_definitions_share_resources_and_isolate_state()
  local desc = doorPairDescriptor()
  local cache = sceneWith({
    {
      placementIndex = 0,
      modelKey = "outdoor:26:door",
      transform = identityMatrix(),
    },
    {
      placementIndex = 1,
      modelKey = "outdoor:26:door",
      transform = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 5, 0, 0, 1 },
    },
  }, { [desc.key] = desc })
  local runtime = MapSceneLoader.load(
    cache,
    assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua")),
    { meshBuilder = fakeMeshBuilder }
  )
  Assert.equal(runtime.stats.animatedInstances, 2)
  Assert.equal(runtime.stats.animatedModelCount, 1, "one definition serves both placements")

  local a, b = runtime.animatedInstances[1], runtime.animatedInstances[2]
  Assert.isTrue(a.definition == b.definition, "placements share the model definition")
  Assert.isTrue(a.renderMeshesById == b.renderMeshesById, "placements share the render meshes")
  Assert.isFalse(a.materialState == b.materialState, "material state is per instance")

  -- No ambient policy fires on a multi-clip model: the handles drive the
  -- two instances forward independently. Independent control: b is
  -- advanced two ticks while a runs to the checked-advance terminal, so
  -- the shared definition cannot couple their playback.
  local aHandle = a:play("door.open", { loopMode = "once" })
  local bHandle = b:play("door.close", { loopMode = "once" })
  for _ = 1, 2 do
    a:updateFixed()
    b:updateFixed()
  end
  for _ = 1, 6 do
    a:updateFixed()
  end
  Assert.isTrue(aHandle.player:isComplete())
  Assert.isFalse(bHandle.player:isComplete())
  Assert.equal(aHandle.clip.name, "door_op")
  Assert.equal(bHandle.clip.name, "door_cl")
  Assert.equal(aHandle.player.frameFx, 8 * 4096, "the terminal is exactly numFrame * FRAME_UNIT")
  Assert.isTrue(aHandle.player.frameFx > bHandle.player.frameFx)
  Assert.equal(bHandle.player.frameFx, 2 * 4096, "the independent handle keeps its own frame")

  runtime:release()
end

function T.banded_model_plays_its_time_band_and_swaps()
  local desc = skyDescriptor()
  local cache = sceneWith({
    {
      placementIndex = 0,
      modelKey = "indoor:113:sky",
      transform = identityMatrix(),
    },
  }, { [desc.key] = desc })
  local runtime = MapSceneLoader.load(
    cache,
    assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua")),
    { meshBuilder = fakeMeshBuilder }
  )

  -- Noon is the default field time: the day band plays at load.
  local instance = runtime.animatedInstances[1]
  Assert.equal(runtime.timeBand, "day")
  Assert.isTrue(instance.timeOfDayPlan ~= nil, "the banded model carries its band plan")
  local names = {}
  for _, category in ipairs({ "joint", "material" }) do
    for _, attachment in ipairs(instance.animationState:attachments(category)) do
      names[#names + 1] = attachment.clip.name
    end
  end
  Assert.deepEqual(names, { "kk_sky_d" })
  Assert.equal(
    instance.animationState:attachments("joint")[1].player.frameFx,
    0,
    "load starts the day band at frame 0 without advancing the clock"
  )

  -- A time-of-day change swaps the band (stop the old, play the new).
  runtime:setTimeBand("nite")
  Assert.equal(runtime.timeBand, "nite")
  names = {}
  for _, category in ipairs({ "joint", "material" }) do
    for _, attachment in ipairs(instance.animationState:attachments(category)) do
      names[#names + 1] = attachment.clip.name
    end
  end
  Assert.deepEqual(names, { "kk_sky_n" })

  -- The swapped band advances with the scene.
  runtime:updateAnimated()
  local attachment = instance.animationState:attachments("joint")[1]
  Assert.equal(attachment.clip.name, "kk_sky_n")
  Assert.equal(attachment.player.frameFx, 4096)

  -- Re-setting the same band is a no-op (the clip keeps its frame).
  runtime:setTimeBand("nite")
  runtime:updateAnimated()
  Assert.equal(attachment.player.frameFx, 2 * 4096)

  runtime:release()
end

-- The fixed tick re-evaluates each instance's pose from its attachment
-- frames: after a play, the scene's draw items track the swing (this is the
-- headless guarantee behind the graphics-gated render test).
function T.update_advances_the_pose_driven_draw_items()
  local desc = doorDescriptor()
  local cache = sceneWith({
    {
      placementIndex = 0,
      modelKey = "outdoor:26:door",
      transform = doorTransform(),
    },
  }, { [desc.key] = desc }, { { x = 4, z = 14 } })
  local runtime = MapSceneLoader.load(
    cache,
    assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua")),
    { meshBuilder = fakeMeshBuilder }
  )
  local door = assert(runtime.mapProps:doorAt(doorMapFor(runtime, 4, 14), 4, 14))
  door:open()
  runtime:updateAnimated()
  local m0 = runtime.animatedBuildingDraws[1].transform
  local normal0 = runtime.animatedBuildingDraws[1].modelNormal
  Assert.deepEqual(normal0, Matrix3.modelNormal(m0))
  for _ = 1, 7 do
    runtime:updateAnimated()
  end
  local m7 = runtime.animatedBuildingDraws[1].transform
  local normal7 = runtime.animatedBuildingDraws[1].modelNormal
  Assert.deepEqual(normal7, Matrix3.modelNormal(m7), "the fixed-tick item refresh recomputes the model normal")
  Assert.isFalse(normal0 == normal7, "animated item production replaces the changed normal transform")
  local differs = false
  for i = 1, 16 do
    if math.abs(m0[i] - m7[i]) > 1e-3 then
      differs = true
    end
  end
  Assert.isTrue(differs, "the scrubbed door draw differs from frame 0")
  runtime:release()
end

-- A staged scene owns its build coroutine only until finish transfers the
-- runtime. Live animation then advances through ordinary scene ticks, with
-- the draw list refreshed from the new pose each time.
function T.dynamic_scene_ticks_after_staged_build()
  local desc = doorDescriptor()
  local cache = sceneWith({
    {
      placementIndex = 0,
      modelKey = "outdoor:26:door",
      transform = doorTransform(),
    },
  }, { [desc.key] = desc }, { { x = 4, z = 14 } })
  local task = MapSceneLoader.begin(
    cache,
    assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua")),
    { meshBuilder = fakeMeshBuilder }
  )
  local runtime = task:finish()
  local instance = runtime.animatedInstances[1]
  local handle = instance:play("door.open", { loopMode = "loop" })
  local initialFrame = handle.player.frameFx

  for _ = 1, 3 do
    runToCompletion(function()
      runtime:updateAnimated()
    end)
    local item = runtime.animatedBuildingDraws[1]
    Assert.notNil(item, "the staged runtime keeps an animated draw item")
    Assert.deepEqual(item.modelNormal, Matrix3.modelNormal(item.transform))
  end

  Assert.isTrue(handle.player.frameFx > initialFrame, "live ticks advance the active animation")
  Assert.equal(#runtime.animatedBuildingDraws, 1)
  runtime:release()
end

-- The scene's draw list refreshes on the scene TICK, not on control ops:
-- every animation tick (FieldSession -> updateAnimated) rebuilds all
-- animated items unconditionally, and nothing between ticks consumes a
-- refresh -- so there is no dirty-forwarding layer. A play
-- between ticks leaves the cached list untouched; the next tick rebuilds
-- it.
function T.draw_items_refresh_only_on_the_scene_tick()
  local desc = doorPairDescriptor()
  local cache = sceneWith({
    {
      placementIndex = 0,
      modelKey = "outdoor:26:door",
      transform = doorTransform(),
    },
  }, { [desc.key] = desc }, { { x = 4, z = 14 } })
  local runtime = MapSceneLoader.load(
    cache,
    assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua")),
    { meshBuilder = fakeMeshBuilder }
  )
  local instance = runtime.animatedInstances[1]
  -- The load-time build already produced the frame-0 draw list; a control
  -- op between ticks marks nothing: the cached list stays until the scene
  -- tick rebuilds it.
  local draws = runtime.animatedBuildingDraws
  instance:play("door.open")
  runtime:updateAnimated()
  Assert.isFalse(runtime.animatedBuildingDraws == draws, "updateAnimated rebuilds the items")
  Assert.equal(instance.animationState:attachments("joint")[1].player.frameFx, 4096)

  runtime:release()
end

-- A fixed tick only rebuilds the animated building list; the static building
-- list is built once at load and its table identity never changes, and it
-- never gets copied into the animated rebuild.
function T.fixed_tick_does_not_copy_the_static_building_list()
  local staticDesc = staticBuildingDescriptor()
  local animatedDesc = doorDescriptor()
  local cache = sceneWith({
    {
      placementIndex = 0,
      modelKey = staticDesc.key,
      transform = identityMatrix(),
    },
    {
      placementIndex = 1,
      modelKey = animatedDesc.key,
      transform = doorTransform(),
    },
  }, { [staticDesc.key] = staticDesc, [animatedDesc.key] = animatedDesc }, { { x = 4, z = 14 } })
  local runtime = MapSceneLoader.load(
    cache,
    assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua")),
    { meshBuilder = fakeMeshBuilder }
  )

  Assert.equal(#runtime.staticBuildingDraws, 1, "the static building loads once")
  Assert.equal(#runtime.animatedBuildingDraws, 1, "the animated building's frame-0 item loads once")
  local staticList = runtime.staticBuildingDraws
  local staticItem = staticList[1]

  for _ = 1, 3 do
    runtime:updateAnimated()
    Assert.isTrue(runtime.staticBuildingDraws == staticList, "a fixed tick never replaces the static list")
    Assert.isTrue(runtime.staticBuildingDraws[1] == staticItem, "the static item is never rebuilt")
    for _, item in ipairs(runtime.animatedBuildingDraws) do
      Assert.isFalse(item == staticItem, "the animated rebuild never copies a static item into it")
    end
  end

  runtime:release()
end

-- The scene animation clock: FieldSession advances the loaded ambient props
-- exactly once per tick -- ordinary ticks and modal-dialogue ticks alike. The
-- HGSS field update path does not couple map-prop animation progression to
-- dialogue ownership, so wind/machines keep running while a message box is
-- up. Only the world steps freeze under the modal gate: movement, warps, pose
-- clocks, and the camera; the dialogue still owns the tick for its own
-- stepping.
function T.ambient_clip_advances_once_per_session_tick_and_through_dialogue()
  local desc = ambientDescriptor()
  local cache = sceneWith({
    {
      placementIndex = 0,
      modelKey = "outdoor:7:wind",
      transform = identityMatrix(),
    },
  }, { [desc.key] = desc })
  local runtime = MapSceneLoader.load(
    cache,
    assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua")),
    { meshBuilder = fakeMeshBuilder }
  )
  local instance = runtime.animatedInstances[1]
  Assert.isTrue(#instance.animationState:attachments("joint") == 1, "the ambient clip autoplays at load")

  local playerSteps, cameraSteps = 0, 0
  local player = {
    fieldX = 4,
    fieldZ = 14,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "idle",
    updateFixed = function()
      playerSteps = playerSteps + 1
      return false
    end,
    collapseRenderInterpolation = function() end,
    collisionCandidates = function(self)
      return { { fieldX = self.fieldX, fieldZ = self.fieldZ, surfaceId = self.surfaceId } }
    end,
    collisionCandidatesInto = function(self, out)
      local current = out[1]
      if current == nil then
        current = {}
        out[1] = current
      end
      current.fieldX = self.fieldX
      current.fieldZ = self.fieldZ
      current.surfaceId = self.surfaceId
      out[2] = nil
      return out
    end,
    clearGesturePresentation = function() end,
    presentationState = function(self)
      local locomotionActive = self.motion == "walking" or self.motion == "turning" or self.motion == "jumping"
      return {
        locomotionActive = locomotionActive,
        gesturePose = nil,
        gestureTick = nil,
        gestureOffsetY = 0,
      }
    end,
    presentationStateInto = function(self, out)
      out.locomotionActive = self.motion == "walking" or self.motion == "turning" or self.motion == "jumping"
      out.gesturePose = nil
      out.gestureTick = nil
      out.gestureOffsetY = 0
      return out
    end,
  }
  ---@cast player FieldPlayer
  local map = {
    mapId = 61,
    cameraType = 4,
    sceneRuntime = runtime,
    updateAnimated = function(self)
      if self.sceneRuntime then
        self.sceneRuntime:updateAnimated()
      end
    end,
  }
  ---@cast map RuntimeFieldMap
  local camera = {
    updateFixed = function()
      cameraSteps = cameraSteps + 1
    end,
    collapseRenderInterpolation = function() end,
  }
  ---@cast camera FieldCamera
  local inactiveDialogue = {
    isModal = function()
      return false
    end,
  }
  ---@cast inactiveDialogue FieldDialogueController
  local transition = {
    locked = false,
    updateFixed = function() end,
    start = function() end,
  }
  ---@cast transition FieldTransition
  local actors = {
    step = function() end,
  }
  ---@cast actors FieldActorManager
  local input = {
    snapshot = function()
      return {}
    end,
  }
  ---@cast input FieldInput
  local menuHost = {
    isModal = function()
      return false
    end,
    advance = function() end,
  }
  ---@cast menuHost FieldMenuHost
  local signpost = {
    isModal = function()
      return false
    end,
  }
  ---@cast signpost FieldSignpostController
  local applicationHost = {
    isActive = function()
      return false
    end,
    updateFixed = function() end,
    requestOpen = function() end,
    takeReopen = function()
      return false
    end,
  }
  ---@cast applicationHost FieldApplicationHost
  local session = FieldSession.new({
    versionId = "heartgold",
    currentMap = map,
    player = player,
    fieldEntranceIndicator = { updateFixed = function() end },
    camera = camera,
    transition = transition,
    actors = actors,
    input = input,
    dialogue = inactiveDialogue,
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
    eventResolver = FieldEventResolver,
    eventState = FieldEventState.new(),
    menuHost = menuHost,
    contextChoice = {
      isActive = function()
        return false
      end,
    },
    signpost = signpost,
    applicationHost = applicationHost,
    interactions = {
      resolve = function()
        return nil
      end,
    },
    bagUnlocked = function()
      return true
    end,
  })

  session:updateFixed({})
  local attachment = instance.animationState:attachments("joint")[1]
  Assert.equal(attachment.player.frameFx, 4096, "one scene-animation advance per ordinary tick")
  session:updateFixed({})
  Assert.equal(attachment.player.frameFx, 2 * 4096)

  -- Count only the modal phase below: the two ordinary ticks already stepped
  -- the player and camera; the modal gate's freeze covers the ticks it owns.
  playerSteps, cameraSteps = 0, 0

  -- A modal dialogue freezes the world steps but not the scene clock: the
  -- ambient props advance once per modal tick, exactly as on locked
  -- transition ticks, while the dialogue alone reads the input.
  local dialogueSteps = 0
  local dialogue = {
    isModal = function()
      return true
    end,
    step = function()
      dialogueSteps = dialogueSteps + 1
    end,
  }
  ---@cast dialogue FieldDialogueController
  session.dialogue = dialogue
  session:updateFixed({})
  Assert.equal(attachment.player.frameFx, 3 * 4096, "the modal tick advances the scene clock once")
  Assert.equal(dialogueSteps, 1, "the dialogue still owns the modal tick's stepping")
  Assert.equal(playerSteps, 0, "the modal tick does not move the player")
  Assert.equal(cameraSteps, 0, "the modal tick does not move the camera")
  session:updateFixed({})
  Assert.equal(attachment.player.frameFx, 4 * 4096, "the scene clock keeps advancing while the box is up")
  Assert.equal(dialogueSteps, 2)
  Assert.equal(playerSteps, 0)
  Assert.equal(cameraSteps, 0)
  session.dialogue = inactiveDialogue
  session:updateFixed({})
  Assert.equal(attachment.player.frameFx, 5 * 4096, "the ordinary tick cadence resumes when the dialogue closes")

  -- Script-owned boxes keep their exemption: the script scheduler steps them
  -- from its own async phase, so the modal gate does not apply and the world
  -- -- scene clock included -- runs normally.
  local scriptOwned = {
    isModal = function()
      return true
    end,
    isScriptOwned = function()
      return true
    end,
    step = function() end,
  }
  ---@cast scriptOwned FieldDialogueController
  session.dialogue = scriptOwned
  session:updateFixed({})
  Assert.equal(attachment.player.frameFx, 6 * 4096, "a script-owned box keeps the world running")

  runtime:release()
end

function T.load_rejects_an_unknown_initial_band()
  local desc = skyDescriptor()
  local cache = sceneWith({
    {
      placementIndex = 0,
      modelKey = "indoor:113:sky",
      transform = identityMatrix(),
    },
  }, { [desc.key] = desc })
  local ok, err = pcall(
    MapSceneLoader.load,
    cache,
    assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua")),
    { meshBuilder = fakeMeshBuilder, timeBand = "bogus" }
  )
  Assert.isFalse(ok)
  assert(tostring(err):find("unknown time-of-day band", 1, true) ~= nil, tostring(err))
end

-- The animated (dynamic) image path must honor the material's sampler wrap:
-- an animated material with a repeat wrap resolves through the pool with
-- repeat/repeat, never the unconditional clamp/clamp of the old callback.
function T.animated_material_resolves_its_image_with_the_material_wrap()
  local desc = texturedDescriptor()
  local cache = sceneWith({
    {
      placementIndex = 0,
      modelKey = "outdoor:26:texdoor",
      transform = identityMatrix(),
    },
  }, { [desc.key] = desc })
  local images = {}
  local runtime = MapSceneLoader.load(
    cache,
    assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua")),
    { meshBuilder = fakeMeshBuilder, imageBuilder = recordingImageBuilder(images) }
  )
  runtime:updateAnimated()
  local image = runtime.animatedBuildingDraws[1].material.image
  Assert.notNil(image, "the animated material resolves an image")
  Assert.equal(image.path, desc.materials[1].texture)
  Assert.deepEqual(image.wraps, { { "repeat", "repeat" } }, "the image is requested with the material's wrap")
  Assert.equal(runtime.stats.textureCount, 1)
  runtime:release()
end

-- A pattern variant texture is resolved with the SAME wrap as its material:
-- the sampler state is keyed by material id, so a variant never samples
-- with the wrong sampler.
function T.animated_variant_texture_uses_the_material_wrap()
  local variantTexture = MapAssetCache.texturePath("texvariant")
  local desc = texturedDescriptor({
    variants = {
      {
        name = "v1",
        texture = variantTexture,
        width = 32,
        height = 32,
        textureFormat = 7,
      },
    },
    animations = { patternClip() },
  })
  local cache = sceneWith({
    {
      placementIndex = 0,
      modelKey = "outdoor:26:texdoor",
      transform = identityMatrix(),
    },
  }, { [desc.key] = desc })
  local images = {}
  local runtime = MapSceneLoader.load(
    cache,
    assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua")),
    { meshBuilder = fakeMeshBuilder, imageBuilder = recordingImageBuilder(images) }
  )
  local instance = runtime.animatedInstances[1]

  -- The base texture first: the material's wrap applies to the base too.
  runtime:updateAnimated()
  local baseImage = runtime.animatedBuildingDraws[1].material.image
  Assert.deepEqual(baseImage.wraps, { { "repeat", "repeat" } }, "the base texture uses the material's wrap")

  -- The pattern selects the variant; the variant resolves with the same wrap.
  -- The pattern play attaches the clip; the next scene tick advances it and
  -- refreshes the draw items, so the rebuild sees the switched texture.
  instance:play("pattern")
  runtime:updateAnimated()
  local variantImage = runtime.animatedBuildingDraws[1].material.image
  Assert.equal(variantImage.path, variantTexture, "the pattern switches to the variant texture")
  Assert.deepEqual(variantImage.wraps, { { "repeat", "repeat" } }, "the variant texture uses its material's wrap")
  runtime:release()
end

-- A pattern variant that was not needed for frame 0 remains a live pool
-- lookup after a staged build has transferred the runtime.
function T.lazy_variant_loads_after_staged_build()
  local variantTexture = MapAssetCache.texturePath("texvariant")
  local desc = texturedDescriptor({
    variants = {
      {
        name = "v1",
        texture = variantTexture,
        width = 32,
        height = 32,
        textureFormat = 7,
      },
    },
    animations = { patternClip() },
  })
  local cache = sceneWith({
    {
      placementIndex = 0,
      modelKey = "outdoor:26:texdoor",
      transform = identityMatrix(),
    },
  }, { [desc.key] = desc })
  local images = {}
  local task = MapSceneLoader.begin(
    cache,
    assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua")),
    { meshBuilder = fakeMeshBuilder, imageBuilder = recordingImageBuilder(images) }
  )
  local runtime = task:finish()
  Assert.equal(#images, 1, "only the frame-0 base image is acquired during construction")

  runtime.animatedInstances[1]:play("pattern")
  runToCompletion(function()
    runtime:updateAnimated()
  end)

  local variantImage = runtime.animatedBuildingDraws[1].material.image
  Assert.equal(#images, 2, "the live tick acquires the lazy variant")
  Assert.equal(variantImage.path, variantTexture)
  Assert.deepEqual(variantImage.wraps, { { "repeat", "repeat" } })
  runtime:release()
end

-- Untextured animated materials never touch the image pool: the resolveImage
-- callback only fires for a material with a current texture.
function T.untextured_animated_materials_never_request_an_image()
  local desc = doorDescriptor()
  local cache = sceneWith({
    {
      placementIndex = 0,
      modelKey = "outdoor:26:door",
      transform = identityMatrix(),
    },
  }, { [desc.key] = desc })
  local images = {}
  local runtime = MapSceneLoader.load(
    cache,
    assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua")),
    { meshBuilder = fakeMeshBuilder, imageBuilder = recordingImageBuilder(images) }
  )
  Assert.equal(#images, 0, "no image is requested for an untextured material")
  Assert.equal(runtime.stats.textureCount, 0)
  runtime:updateAnimated()
  Assert.isNil(runtime.animatedBuildingDraws[1].material.image)
  -- Even while a clip plays, an untextured material never resolves an image.
  local instance = runtime.animatedInstances[1]
  instance:play("door.open")
  runtime:updateAnimated()
  Assert.equal(#images, 0, "playing an untextured clip never touches the image pool")
  runtime:release()
end

-- ---- terrain animation wiring ----

-- Every swap-frame image is acquired inside the load transaction: the pool's
-- acquired set at commit time (runtime.stats.textureCount, computed inside
-- the build) covers the base texture plus every replacement step, and each
-- unique step path is built exactly once (repeated paths dedup through the
-- pool).
function T.all_swap_frames_are_acquired_inside_the_load_transaction()
  local cache, scene = terrainScene({ swapMaterial(0, "flower01", "base.png", flowerSteps()) }, false)
  local images = {}
  local runtime = MapSceneLoader.load(cache, scene, { imageBuilder = trackingImageBuilder(images) })
  Assert.equal(
    runtime.stats.textureCount,
    4,
    "base and the three unique steps are pooled before the transaction commits"
  )
  local built = {}
  for _, image in ipairs(images) do
    built[#built + 1] = image.path
  end
  Assert.deepEqual(
    built,
    { "base.png", "a.png", "b.png", "c.png" },
    "base first, then each unique step path exactly once"
  )
  runtime:release()
end

-- Same path/wrap deduplicates through the pool: two same-name materials
-- (one playback group) with identical steps cost one pooled image per
-- unique path, never one per material.
function T.same_path_and_wrap_dedup_through_the_pool()
  local materials = {
    swapMaterial(0, "flower", "base.png", flowerSteps()),
    swapMaterial(1, "flower", "base.png", flowerSteps()),
  }
  local cache, scene = terrainScene(materials, false)
  local images = {}
  local runtime = MapSceneLoader.load(cache, scene, { imageBuilder = trackingImageBuilder(images) })
  Assert.equal(#images, 4, "one pool image per unique path/wrap across the group")
  Assert.equal(runtime.stats.textureCount, 4)
  runtime:release()
end

-- ---- sampler wrap normalization (loader boundary) ----
--
-- SceneDescriptor.wrap() is the one owner of the raw wrap/flip -> resolved
-- sampler fold. These tests prove the RESOLVED value is what the GPU pool's
-- image is configured with (image:setWrap), never the raw descriptor
-- wrap/flip pair -- the actual loader-boundary bug (materialsById used to
-- pass record.wrap.x/y straight through, discarding record.flip before the
-- pool ever saw it).

-- A central map material's raw descriptor state is `wrap.x = "repeat"` with
-- `flip.x = true` (the NSBTX TEXIMAGE_PARAM flip bit). The image the pool
-- builds must be configured with the resolved DS mirrored-repeat mode, not
-- the raw "repeat".
function T.central_map_material_with_flip_resolves_to_mirrored_repeat()
  local material = {
    id = 0,
    name = "ground",
    texture = "ground.png",
    wrap = { x = "repeat", y = "repeat" },
    flip = { x = true, y = false },
    texWidth = 16,
    texHeight = 16,
    texMtxMode = 0,
  }
  local cache, scene = terrainScene({ material }, false)
  local images = {}
  local runtime = MapSceneLoader.load(cache, scene, { imageBuilder = recordingImageBuilder(images) })
  Assert.deepEqual(
    images[1].wraps,
    { { "mirroredrepeat", "repeat" } },
    "a flipped repeat axis must reach the image as the resolved mirrored-repeat sampler, not raw repeat"
  )
  runtime:release()
end

-- Clamp is inert to flip (mirroring never applies without wraparound):
-- SceneDescriptor.wrap keeps a flipped clamped axis clamped, and that must
-- stay true once the resolved value crosses the loader boundary.
function T.clamp_with_flip_remains_clamp_through_the_loader()
  local material = {
    id = 0,
    name = "wall",
    texture = "wall.png",
    wrap = { x = "clamp", y = "clamp" },
    flip = { x = true, y = true },
    texWidth = 16,
    texHeight = 16,
    texMtxMode = 0,
  }
  local cache, scene = terrainScene({ material }, false)
  local images = {}
  local runtime = MapSceneLoader.load(cache, scene, { imageBuilder = recordingImageBuilder(images) })
  Assert.deepEqual(images[1].wraps, { { "clamp", "clamp" } }, "a flipped clamp axis stays clamp")
  runtime:release()
end

-- Two materials sampling the SAME texture path under different resolved
-- wraps must stay separately pooled: the (path, wrapX, wrapY) cache identity
-- is unaffected by resolving wrap before acquisition.
function T.same_texture_under_different_resolved_wraps_stays_separately_pooled()
  local materials = {
    {
      id = 0,
      name = "a",
      texture = "shared.png",
      wrap = { x = "repeat", y = "repeat" },
      flip = { x = true, y = false },
      texWidth = 16,
      texHeight = 16,
      texMtxMode = 0,
    },
    {
      id = 1,
      name = "b",
      texture = "shared.png",
      wrap = { x = "repeat", y = "repeat" },
      flip = { x = false, y = false },
      texWidth = 16,
      texHeight = 16,
      texMtxMode = 0,
    },
  }
  local cache, scene = terrainScene(materials, false)
  local images = {}
  local runtime = MapSceneLoader.load(cache, scene, { imageBuilder = recordingImageBuilder(images) })
  Assert.equal(#images, 2, "distinct resolved wraps over the same path stay separately pooled")
  Assert.deepEqual(images[1].wraps, { { "mirroredrepeat", "repeat" } })
  Assert.deepEqual(images[2].wraps, { { "repeat", "repeat" } })
  runtime:release()
end

-- The terrain texture-swap animator must acquire its replacement images
-- under the SAME resolved sampler as the base image -- base and every
-- replacement step share one material's wrap, flip included. This is the
-- TerrainMaterialAnimator half of the bug: it read record.wrap directly.
function T.terrain_swap_replacement_images_share_the_resolved_mirrored_repeat_wrap()
  local material = {
    id = 0,
    name = "flower01",
    texture = "base.png",
    wrap = { x = "repeat", y = "repeat" },
    flip = { x = true, y = false },
    texWidth = 16,
    texHeight = 16,
    texMtxMode = 0,
    textureSwap = { name = "flower01", steps = flowerSteps() },
  }
  local cache, scene = terrainScene({ material }, false)
  local images = {}
  local runtime = MapSceneLoader.load(cache, scene, { imageBuilder = recordingImageBuilder(images) })
  Assert.equal(#images, 4, "base plus the three unique replacement steps")
  for _, image in ipairs(images) do
    Assert.deepEqual(
      image.wraps,
      { { "mirroredrepeat", "repeat" } },
      "replacement image " .. image.path .. " uses the same resolved wrap as the base"
    )
  end
  runtime:release()
end

-- A terrain-only tick mutates the runtime draw materials in place: the
-- texture-swap step image switches and the targeted material's texMatrix
-- advances, while the draw array, its items, their meshes, and the
-- untargeted matrix keep their identities -- no draw-list rebuild and no
-- geometry re-acquisition on a terrain-only update.
function T.terrain_frame_and_matrix_mutate_in_place_without_rebuilding_draws()
  local clip = terrainSrtClip(4, { 0x0, 0x1000, 0x2000, 0x3000 })
  local materials = {
    swapMaterial(0, "flower01", "base.png", flowerSteps()),
    {
      id = 1,
      name = "water",
      texture = "water.png",
      wrap = { x = "repeat", y = "repeat" },
      texWidth = 16,
      texHeight = 16,
      texMtxMode = 0,
    },
  }
  local cache, scene = terrainScene(materials, clip)
  local images = {}
  local runtime = MapSceneLoader.load(cache, scene, { imageBuilder = trackingImageBuilder(images) })
  local draws = runtime.mapDraws
  local flower = draws[1].material
  local water = draws[2].material
  local flowerImage0 = flower.image
  local flowerMatrix0 = flower.texMatrix
  local waterMatrix0 = water.texMatrix
  local meshes = { draws[1].mesh, draws[2].mesh }
  Assert.equal(
    flowerImage0.path,
    "base.png",
    "load binds the base image and leaves it in place -- never the first replacement step"
  )

  for _ = 1, 19 do
    runtime:updateAnimated()
  end

  Assert.equal(runtime.mapDraws, draws, "the draw array is not rebuilt on a terrain tick")
  Assert.equal(draws[1].material, flower, "the draw item keeps its material table")
  Assert.equal(draws[2].material, water)
  Assert.equal(draws[1].mesh, meshes[1], "the mesh identity is unchanged")
  Assert.equal(draws[2].mesh, meshes[2])
  Assert.equal(flower.image.path, "b.png", "the step image switched to step 2 at tick 19")
  Assert.isFalse(flower.image == flowerImage0, "the switched image is a different pooled image")
  Assert.equal(flower.texMatrix, flowerMatrix0, "an untargeted matrix keeps its table identity")
  Assert.near(water.texMatrix[7], -3, 1e-9, "the SRT sample advanced to frame 3 (0x3000 scroll)")
  Assert.isFalse(water.texMatrix == waterMatrix0, "a targeted matrix is replaced per tick")
  runtime:release()
end

-- A failure on an Nth alternate-frame creation rolls back the whole load
-- transaction: every earlier image (base and already-built steps) is
-- released exactly once, the failed creation is never owned, and the pool
-- re-raises the image build failure.
function T.failure_on_an_alternate_frame_creation_releases_resources_exactly_once()
  local cache, scene = terrainScene({ swapMaterial(0, "flower01", "base.png", flowerSteps()) }, false)
  local images = {}
  local err = Assert.throws(function()
    MapSceneLoader.load(cache, scene, { imageBuilder = failingImageBuilder(images, 3) })
  end)
  Assert.isTrue(tostring(err):find("injected alternate-image failure", 1, true) ~= nil, "the frame failure propagates")
  Assert.equal(#images, 3, "base, step 1, and the failing step 2 creation all ran")
  Assert.equal(images[1].releases, 1, "the base image is released exactly once")
  Assert.equal(images[2].releases, 1, "the earlier step image is released exactly once")
  Assert.equal(images[3].releases, 0, "the failed creation is never owned, so never released")
end

-- Release after a successful load releases every base and step image
-- exactly once through the scene's one pool owner.
function T.release_after_a_successful_load_releases_every_image_exactly_once()
  local cache, scene = terrainScene({ swapMaterial(0, "flower01", "base.png", flowerSteps()) }, false)
  local images = {}
  local runtime = MapSceneLoader.load(cache, scene, { imageBuilder = trackingImageBuilder(images) })
  runtime:release()
  Assert.equal(#images, 4)
  for _, image in ipairs(images) do
    Assert.equal(image.releases, 1, "base and step images are released exactly once")
  end
end

-- A scene with no terrain animation inputs still updates safely: no swap
-- records and no SRT clip leave the terrain animator a no-op, the scene tick
-- keeps working, and the draw array stays untouched.
function T.no_animation_scenes_update_safely()
  local cache, scene = terrainScene({
    {
      id = 0,
      name = "plain",
      texture = "soil.png",
      wrap = { x = "repeat", y = "repeat" },
      texWidth = 16,
      texHeight = 16,
      texMtxMode = 0,
    },
  }, false)
  local images = {}
  local runtime = MapSceneLoader.load(cache, scene, { imageBuilder = trackingImageBuilder(images) })
  local draws = runtime.mapDraws
  runtime:updateAnimated()
  Assert.equal(runtime.mapDraws, draws, "a no-animation scene tick leaves the draws untouched")
  Assert.equal(#images, 1)
  runtime:release()
end

-- A fully static terrain scene (non-identity static srt, no textureSwap, no
-- area SRT clip) still gets its matrix through the real loader/animator
-- boundary: load initializes texMatrix from the record's static srt -- never
-- the identity assembly -- and the scene tick leaves it untouched.
function T.static_only_terrain_srt_is_initialized_by_the_loader()
  local srt = {
    scaleS = 0x1000,
    scaleT = 0x1000,
    transS = 0x100,
    transT = 0,
    scaleOne = true,
    rotOne = true,
    transOne = false,
  }
  local material = {
    id = 0,
    name = "soil",
    texture = "soil.png",
    wrap = { x = "repeat", y = "repeat" },
    texWidth = 16,
    texHeight = 16,
    texMtxMode = 0,
    srt = srt,
  }
  local cache, scene = terrainScene({ material }, false)
  local runtime = MapSceneLoader.load(cache, scene, { imageBuilder = trackingImageBuilder({}) })
  local matrix = runtime.mapDraws[1].material.texMatrix
  Assert.near(matrix[7], -1 / 16, 1e-9, "the static srt matrix is non-identity")
  local expected = TextureSrtEvaluator.matrix(material, nil)
  for i = 1, 9 do
    Assert.near(matrix[i], expected[i], 1e-9, "texMatrix cell " .. tostring(i))
  end
  runtime:updateAnimated()
  Assert.equal(runtime.mapDraws[1].material.texMatrix, matrix, "a static scene tick leaves the matrix untouched")
  runtime:release()
end

-- A static building's descriptor materials never pass through the terrain
-- animator (its bindings cover scene terrain materials only), yet every
-- draw material the renderer sends u_texMatrix for must still carry a
-- matrix: the loader seeds descriptor materials with identity.
function T.static_building_draw_materials_carry_a_tex_matrix()
  local geometry = "assets/generated/maps/geometry/wall.g4mesh"
  local desc = {
    schema = "g4-model-descriptor-v1",
    key = "building:wall",
    kind = "static",
    batches = {
      {
        geometry = geometry,
        material = 0,
        alphaClass = "opaque",
        cullMode = "back",
        polygonAlpha = 31,
        polygonMode = "modulation",
        lightMask = 0,
        polygonId = 0,
        translucentDepthWrite = false,
        depthEqual = false,
      },
    },
    materials = {
      {
        id = 0,
        name = "wall",
        texture = MapAssetCache.texturePath("wall"),
        wrap = { x = "repeat", y = "repeat" },
      },
    },
  }
  local cache = sceneWith(
    { { placementIndex = 0, modelKey = "building:wall", transform = identityMatrix() } },
    { desc }
  )
  local runtime = MapSceneLoader.load(
    cache,
    assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua")),
    { meshBuilder = fakeMeshBuilder, imageBuilder = recordingImageBuilder({}) }
  )
  Assert.deepEqual(
    runtime.staticBuildingDraws[1].material.texMatrix,
    identity9(),
    "a static building draw material carries the identity tex matrix"
  )
  runtime:release()
end

-- ---- global fog preset forwarding ----

-- A resolved HgssFieldFog.runtimePreset(1) shape (Rain/Heavy Rain/Thunder-
-- storm): enabled, RGB555 color, offset, and the generated 32-entry ramp.
-- Written out here as a literal (rather than requiring romdump's
-- HgssFieldFog) because MapSceneLoader is a runtime module that must never
-- import romdump -- the loader only ever sees this shape already resolved on
-- the compiled scene.
local function fogPresetFixture()
  local table32 = {}
  for i = 1, 32 do
    table32[i] = (i - 1) * 4
  end
  return { enabled = true, color = 26 + 26 * 32 + 26 * 1024, offset = 0x726F, table = table32 }
end

-- The compiled area's resolved global fog preset is opaque scene state,
-- forwarded to the runtime exactly like edgeColors -- MapSceneLoader has no
-- ROM/weather knowledge of its own.
function T.load_forwards_the_scenes_resolved_fog_preset()
  local cache, scene = terrainScene({}, false)
  scene.fog = fogPresetFixture()
  local runtime = MapSceneLoader.load(cache, scene)
  Assert.deepEqual(runtime.fog, fogPresetFixture(), "the runtime carries the scene's resolved fog preset")
  runtime:release()
end

-- Every compiled HGSS field scene carries a resolved fog preset (global fog
-- is unconditionally evaluated per map, even when the result is "disabled");
-- a scene missing it is a required production collaborator gone missing, not
-- a case the loader defaults around.
function T.load_requires_the_scenes_fog_preset()
  local cache, scene = terrainScene({}, false)
  scene.fog = nil
  Assert.throws(function()
    MapSceneLoader.load(cache, scene)
  end)
end

return {
  metadata = { capabilities = { "graphics" } },
  tests = T,
}
