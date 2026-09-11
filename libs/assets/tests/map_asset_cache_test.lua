-- MapAssetCache: path shapes, and readiness gated on an exact marker plus
-- present artifacts.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local CollisionFixture = require("tests.support.CollisionFixture")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

local T = {}

---@class MapAssetTest.ClipTarget
---@field channels MapAssetTest.ClipChannels

---@class MapAssetTest.ClipChannels
---@field [string] table|nil

---@class MapAssetTest.Clip
---@field compiled { targets: MapAssetTest.ClipTarget[] }

local function cache()
  return CacheFs.forVersion("heartgold", FakeCache.new())
end

local function writeReadyMap(c, marker)
  local dir = MapAssetCache.mapDir(61)
  c:write(
    dir .. "/scene.lua",
    string.format(
      "return { schema = %q, mapId = 61, terrain = { file = %q }, mapBatches = {}, materials = {}, buildingInstances = {}, neighbors = {}, terrainAnimations = { textureSrt = false } }\n",
      MapAssetCache.SCENE_SCHEMA,
      MapAssetCache.terrainPath(61)
    )
  )
  c:write(dir .. "/dependencies.lua", "return {}\n")
  c:write(MapAssetCache.terrainPath(61), "return { schema = 'g4-terrain-surfaces-v1' }\n")
  c:write(MapAssetCache.collisionPath(61), CollisionFixture.asset(32, 32))
  c:write(dir .. "/complete", marker)
end

function T.map_dir_is_zero_padded()
  Assert.equal(MapAssetCache.mapDir(61), "data/generated/maps/0061")
  Assert.equal(MapAssetCache.mapDir(60), "data/generated/maps/0060")
end

function T.model_path_is_filesystem_safe()
  Assert.equal(MapAssetCache.modelPath("indoor:22:abcdef"), "data/generated/models/indoor_22_abcdef.lua")
end

function T.not_ready_without_files()
  Assert.isTrue(not MapAssetCache.isReady(cache(), 61, MapAssetCache.marker("x", 61, "y")), "no files")
end

function T.ready_only_with_exact_marker_and_files()
  local c = cache()
  local marker = MapAssetCache.marker("romsha", 61, "dep")
  writeReadyMap(c, marker)
  Assert.isTrue(MapAssetCache.isReady(c, 61, marker), "ready")
  Assert.isTrue(not MapAssetCache.isReady(c, 61, "different-marker"), "stale marker not ready")
end

function T.outdoor_canonical_scene_uses_its_physical_cell_artifacts()
  local c = cache()
  local mapId = 61
  local marker = MapAssetCache.marker("romsha", mapId, "dep")
  local matrixMemberId, cellIndex = 3, 4
  local collisionPath = FieldCellCache.collisionPath(matrixMemberId, cellIndex)
  local terrainPath = FieldCellCache.terrainPath(matrixMemberId, cellIndex)
  local dir = MapAssetCache.mapDir(mapId)
  c:write(
    dir .. "/scene.lua",
    string.format(
      "return { schema = %q, mapId = %d, type = 'outdoor', collision = { file = %q }, terrain = { file = %q }, mapBatches = {}, materials = {}, buildingInstances = {}, neighbors = {}, terrainAnimations = { textureSrt = false } }\n",
      MapAssetCache.SCENE_SCHEMA,
      mapId,
      collisionPath,
      terrainPath
    )
  )
  c:write(dir .. "/dependencies.lua", "return {}\n")
  c:write(collisionPath, CollisionFixture.asset(32, 32))
  c:write(terrainPath, "return { schema = 'g4-terrain-surfaces-v1' }\n")
  c:write(dir .. "/complete", marker)

  Assert.isTrue(MapAssetCache.isReady(c, mapId, marker), "canonical outdoor maps use physical cell artifacts")
  Assert.isFalse(
    c:exists(MapAssetCache.collisionPath(mapId), "file"),
    "canonical maps do not need a map collision copy"
  )
  Assert.isFalse(c:exists(MapAssetCache.terrainPath(mapId), "file"), "canonical maps do not need a map terrain copy")
end

function T.not_ready_when_referenced_asset_missing()
  local c = cache()
  local marker = MapAssetCache.marker("romsha", 61, "dep")
  local dir = MapAssetCache.mapDir(61)
  c:write(
    dir .. "/scene.lua",
    string.format(
      "return { schema = %q, mapId = 61, mapBatches = { { geometry = 'assets/generated/maps/geometry/abc.g4mesh' } }, materials = {}, buildingInstances = {}, neighbors = {}, terrainAnimations = { textureSrt = false } }\n",
      MapAssetCache.SCENE_SCHEMA
    )
  )
  c:write(dir .. "/dependencies.lua", "return {}\n")
  c:write(dir .. "/collision.g4collision", CollisionFixture.asset(32, 32))
  c:write(dir .. "/complete", marker)
  Assert.isTrue(not MapAssetCache.isReady(c, 61, marker), "missing mesh -> not ready")
end

function T.not_ready_with_malformed_collision_asset()
  local c = cache()
  local marker = MapAssetCache.marker("romsha", 61, "dep")
  writeReadyMap(c, marker)
  c:write(MapAssetCache.collisionPath(61), string.rep("\0", 100))
  Assert.isTrue(not MapAssetCache.isReady(c, 61, marker), "wrong collision bytes -> not ready")
end

function T.not_ready_when_model_descriptor_references_missing_asset()
  local c = cache()
  local marker = MapAssetCache.marker("romsha", 61, "dep")
  local dir = MapAssetCache.mapDir(61)
  local modelKey = "indoor:1:abc"
  local modelPath = MapAssetCache.modelPath(modelKey)
  local meshPath = "assets/generated/maps/geometry/missing.g4mesh"
  c:write(
    dir .. "/scene.lua",
    string.format(
      "return { schema = %q, mapId = 61, mapBatches = {}, materials = {}, buildingInstances = { { modelKey = %q } }, neighbors = {}, terrainAnimations = { textureSrt = false } }\n",
      MapAssetCache.SCENE_SCHEMA,
      modelKey
    )
  )
  c:write(dir .. "/collision.g4collision", CollisionFixture.asset(32, 32))
  c:write(
    modelPath,
    string.format(
      "return { schema = %q, key = %q, memberId = 1, kind = 'static', batches = { { geometry = %q } }, materials = {} }\n",
      ModelAsset.SCHEMA,
      modelKey,
      meshPath
    )
  )
  c:write(dir .. "/complete", marker)
  Assert.isTrue(not MapAssetCache.isReady(c, 61, marker), "missing model-internal geometry -> not ready")
end

function T.not_ready_when_model_descriptor_has_the_wrong_kind()
  local c = cache()
  local marker = MapAssetCache.marker("romsha", 61, "dep")
  local dir = MapAssetCache.mapDir(61)
  local modelKey = "indoor:1:abc"
  local modelPath = MapAssetCache.modelPath(modelKey)
  c:write(
    dir .. "/scene.lua",
    string.format(
      "return { schema = %q, mapId = 61, mapBatches = {}, materials = {}, buildingInstances = { { modelKey = %q } }, neighbors = {}, terrainAnimations = { textureSrt = false } }\n",
      MapAssetCache.SCENE_SCHEMA,
      modelKey
    )
  )
  c:write(dir .. "/dependencies.lua", "return {}\n")
  c:write(dir .. "/collision.g4collision", CollisionFixture.asset(32, 32))
  -- A descriptor without the explicit schema/kind must not read as ready.
  c:write(modelPath, "return { batches = {}, materials = {} }\n")
  c:write(dir .. "/complete", marker)
  Assert.isTrue(not MapAssetCache.isReady(c, 61, marker), "schema-less descriptor -> not ready")
end

function T.not_ready_when_a_variant_texture_is_missing()
  local c = cache()
  local marker = MapAssetCache.marker("romsha", 61, "dep")
  local dir = MapAssetCache.mapDir(61)
  local modelKey = "indoor:1:abc"
  local modelPath = MapAssetCache.modelPath(modelKey)
  local baseTexture = "assets/generated/maps/textures/base.png"
  local variantTexture = "assets/generated/maps/textures/variant.png"
  c:write(
    dir .. "/scene.lua",
    string.format(
      "return { schema = %q, mapId = 61, terrain = { file = %q }, mapBatches = {}, materials = {}, buildingInstances = { { modelKey = %q } }, neighbors = {}, terrainAnimations = { textureSrt = false } }\n",
      MapAssetCache.SCENE_SCHEMA,
      MapAssetCache.terrainPath(61),
      modelKey
    )
  )
  c:write(dir .. "/dependencies.lua", "return {}\n")
  c:write(dir .. "/collision.g4collision", CollisionFixture.asset(32, 32))
  c:write(MapAssetCache.terrainPath(61), "return { schema = 'g4-terrain-surfaces-v1' }\n")
  c:write(
    modelPath,
    string.format(
      "return { schema = %q, key = %q, memberId = 1, kind = 'static', batches = {}, materials = { { id = 0, name = 'wall', texture = %q, textureFormat = 3, wrap = { x = 'clamp', y = 'clamp' }, flip = { x = false, y = false }, diffuse = { r = 255, g = 255, b = 255, a = 255 }, variants = { { name = 'sign.a', texture = %q } } } } }\n",
      ModelAsset.SCHEMA,
      modelKey,
      baseTexture,
      variantTexture
    )
  )
  c:write(baseTexture, "png")
  c:write(dir .. "/complete", marker)
  Assert.isTrue(not MapAssetCache.isReady(c, 61, marker), "missing variant texture -> not ready")
  c:write(variantTexture, "png")
  Assert.isTrue(MapAssetCache.isReady(c, 61, marker), "with the variant present the map is ready")
end

local function contains(list, value)
  for _, v in ipairs(list) do
    if v == value then
      return true
    end
  end
  return false
end

function T.referenced_paths_includes_neighbor_batches_and_materials()
  local neighborGeometry = "assets/generated/maps/geometry/abc.g4mesh"
  local neighborTexture = "assets/generated/maps/textures/def.png"
  local neighborCollision = "data/generated/maps/0060/neighbors/3/collision.g4collision"
  local neighborTerrain = "data/generated/maps/0060/neighbors/3/terrain.lua"
  local scene = {
    schema = "g4-map-scene-v9",
    mapId = 61,
    mapBatches = {},
    materials = {},
    buildingInstances = {},
    neighbors = {
      {
        offsetTilesX = 1,
        offsetTilesY = 0.5,
        offsetTilesZ = 0,
        batches = { { geometry = neighborGeometry, material = 0 } },
        materials = { { id = 0, texture = neighborTexture, texWidth = 16, texHeight = 16, texMtxMode = 0 } },
        collision = { file = neighborCollision },
        terrain = { file = neighborTerrain },
      },
    },
    terrainAnimations = { textureSrt = false },
  }
  ---@cast scene MapAssetCache.Scene
  local paths = MapAssetCache.referencedPaths(scene, nil)
  Assert.isTrue(contains(paths, neighborGeometry), "missing neighbor geometry path")
  Assert.isTrue(contains(paths, neighborTexture), "missing neighbor texture path")
  Assert.isTrue(contains(paths, neighborCollision), "missing neighbor collision path")
  Assert.isTrue(contains(paths, neighborTerrain), "missing neighbor terrain path")
end

function T.current_scene_rejects_malformed_neighbor_xyz_placement()
  local function sceneWith(placement)
    local scene = {
      schema = MapAssetCache.SCENE_SCHEMA,
      kind = "map",
      mapId = 61,
      batches = {},
      mapBatches = {},
      materials = {},
      buildingInstances = {},
      neighbors = {},
      terrainAnimations = { textureSrt = false },
    }
    scene.neighbors = {
      {
        offsetTilesX = placement.x,
        offsetTilesY = placement.y,
        offsetTilesZ = placement.z,
        batches = {},
        materials = {},
      },
    }
    return scene
  end

  local valid = sceneWith({ x = 32, y = 0.5, z = -32 })
  Assert.isTrue(type(MapAssetCache.referencedPaths(valid, nil)) == "table")
  for _, placement in ipairs({
    { x = 32, y = nil, z = 0 },
    { x = 32, y = 0 / 0, z = 0 },
    { x = 32.5, y = 0, z = 0 },
    { x = 32, y = 0, z = 0.5 },
  }) do
    Assert.throws(function()
      MapAssetCache.referencedPaths(sceneWith(placement), nil)
    end)
  end
end

-- ---- terrain-animation contract ----

local BASE_TEX = "assets/generated/maps/textures/base.png"
local ALT1_TEX = "assets/generated/maps/textures/alt1.png"
local ALT2_TEX = "assets/generated/maps/textures/alt2.png"

-- A minimal current-schema scene: no batches, no models, no neighbors, and
-- the required terrainAnimations table with the explicit false clip.
---@return MapAssetCache.Scene
local function baseScene()
  local scene = {
    schema = MapAssetCache.SCENE_SCHEMA,
    mapId = 61,
    mapBatches = {},
    materials = {},
    buildingInstances = {},
    neighbors = {},
    terrainAnimations = { textureSrt = false },
  }
  ---@cast scene MapAssetCache.Scene
  return scene
end

-- Build a scene and apply one mutation, so every malformed-shape case shares
-- the exact same otherwise-valid base.
---@param mutator fun(scene: MapAssetCache.Scene)
---@return MapAssetCache.Scene
local function patchedScene(mutator)
  local s = baseScene()
  mutator(s)
  return s
end

-- A textured terrain material with the textureSwap record and the terrain
-- fields (texWidth/texHeight/texMtxMode). The swap carries direct playback
-- steps, each naming the replacement image and its duration in ticks.
---@param texture string
---@param steps table[]
---@return table
local function swapMaterial(texture, steps)
  return {
    id = 0,
    name = "flower01",
    texture = texture,
    textureFormat = 3,
    wrap = { x = "repeat", y = "repeat" },
    flip = { x = false, y = false },
    diffuse = { r = 255, g = 255, b = 255, a = 255 },
    texWidth = 16,
    texHeight = 16,
    texMtxMode = 0,
    textureSwap = { name = "flower01", steps = steps },
  }
end

local FLOWER_STEPS = {
  { texture = BASE_TEX, durationTicks = 18 },
  { texture = ALT1_TEX, durationTicks = 18 },
  { texture = BASE_TEX, durationTicks = 18 },
  { texture = ALT2_TEX, durationTicks = 18 },
}

local function constant(value)
  return { source = "constant", value = value }
end

-- The data-only clip shape the terrain compiler emits (NsbtaClipCompiler
-- payload plus the clip envelope, without physical source fields). The
-- rate-1 curve covers all eight frames.
---@return MapAssetTest.Clip
local function srtClip()
  local clip = {
    id = "area00_ani",
    name = "area00_ani",
    category = "material",
    kind = "texsrt",
    frameCount = 8,
    tracks = {
      { target = "pond_on", targetIndex = 0 },
      { target = "sea_un", targetIndex = 1 },
    },
    semanticNames = {},
    compiled = {
      targets = {
        {
          index = 0,
          name = "pond_on",
          channels = {
            transS = constant(0),
            transT = constant(0),
            rot = constant(0x10000000),
            scaleS = constant(0x1000),
            scaleT = constant(0x1000),
          },
        },
        {
          index = 1,
          name = "sea_un",
          channels = {
            transS = {
              source = "curve",
              rate = 1,
              limit = 8,
              storage = "fx16",
              keys = { 0, 256, 512, 768, 1024, 1280, 1536, 1792 },
            },
            transT = constant(0),
            rot = constant(0x10000000),
            scaleS = constant(0x1000),
            scaleT = constant(0x1000),
          },
        },
      },
    },
  } ---@cast clip MapAssetTest.Clip
  return clip
end

---@param scene MapAssetCache.Scene
local function raisesSceneInvalid(scene)
  local err = Assert.throws(function()
    MapAssetCache.referencedPaths(scene, nil)
  end)
  Assert.equal(err.code, "MAP_CACHE_SCENE_INVALID")
end

local function translationTransform(x, y, z)
  return { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1 }
end

local function ownerGroup(model, transforms)
  local placements = {}
  for _, t in ipairs(transforms or { { 0, 0, 0 } }) do
    placements[#placements + 1] = { transform = translationTransform(t[1], t[2], t[3]) }
  end
  return { model = model, placements = placements }
end

function T.runtime_prop_groups_validate_by_owner_and_close_model_references()
  local scene = baseScene()
  scene.runtimeProps = {
    lamp_oil = ownerGroup("indoor:1:aaa", { { 1, 0, 2 } }),
    river_foam = ownerGroup("indoor:2:bbb", { { 3, 0, 4 }, { 5, 0, 6 } }),
  }
  local paths = MapAssetCache.referencedPaths(scene, nil)
  Assert.isTrue(contains(paths, MapAssetCache.modelPath("indoor:1:aaa")), "first owner model path is closed")
  Assert.isTrue(contains(paths, MapAssetCache.modelPath("indoor:2:bbb")), "second owner model path is closed")
end

function T.empty_runtime_prop_placement_lists_are_valid()
  local scene = baseScene()
  scene.runtimeProps = { quiet_corner = { model = "indoor:1:aaa", placements = {} } }
  local paths = MapAssetCache.referencedPaths(scene, nil)
  Assert.isTrue(contains(paths, MapAssetCache.modelPath("indoor:1:aaa")), "the known model is still referenced")
end

function T.a_map_without_runtime_props_stays_valid()
  Assert.isTrue(type(MapAssetCache.referencedPaths(baseScene(), nil)) == "table")
end

function T.malformed_runtime_prop_groups_raise_scene_invalid_with_owner_context()
  local cases = {
    { owner = "lamp_oil", group = "not-a-table" },
    { owner = "lamp_oil", group = { placements = {} } },
    { owner = "lamp_oil", group = { model = "", placements = {} } },
    { owner = "lamp_oil", group = { model = 42, placements = {} } },
    { owner = "lamp_oil", group = { model = "indoor:1:aaa" } },
    { owner = "lamp_oil", group = { model = "indoor:1:aaa", placements = { named = 1 } } },
    { owner = "lamp_oil", group = { model = "indoor:1:aaa", placements = { {} } } },
    {
      owner = "lamp_oil",
      group = { model = "indoor:1:aaa", placements = { { transform = { 1, 0 } } } },
    },
    {
      owner = "lamp_oil",
      group = {
        model = "indoor:1:aaa",
        placements = { { transform = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0 / 0 } } },
      },
    },
    {
      owner = "lamp_oil",
      group = {
        model = "indoor:1:aaa",
        placements = { { transform = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, math.huge } } },
      },
    },
  }
  for _, case in ipairs(cases) do
    local scene = baseScene()
    scene.runtimeProps = { [case.owner] = case.group }
    local err = Assert.throws(function()
      MapAssetCache.referencedPaths(scene, nil)
    end)
    Assert.equal(err.code, "MAP_CACHE_SCENE_INVALID")
    Assert.isTrue(tostring(err.message):find(case.owner, 1, true) ~= nil, "the failure names the offending owner")
  end
  for _, badKey in ipairs({ "", 42 }) do
    local scene = baseScene()
    scene.runtimeProps = { [badKey] = ownerGroup("indoor:1:aaa") }
    local err = Assert.throws(function()
      MapAssetCache.referencedPaths(scene, nil)
    end)
    Assert.equal(err.code, "MAP_CACHE_SCENE_INVALID")
  end
end

function T.runtime_prop_model_files_are_traversed_generically()
  local c = cache()
  local modelKey = "indoor:1:abc"
  local modelPath = MapAssetCache.modelPath(modelKey)
  local meshPath = "assets/generated/maps/geometry/prop.g4mesh"
  c:write(
    modelPath,
    string.format(
      "return { schema = %q, key = %q, memberId = 1, kind = 'static', batches = { { geometry = %q, cullMode = 'back', polygonMode = 'modulation', polygonId = 0, polygonAlpha = 31, lightMask = 15, translucentDepthWrite = false, depthEqual = false, fogEnabled = true } }, materials = {} }\n",
      ModelAsset.SCHEMA,
      modelKey,
      meshPath
    )
  )
  local scene = baseScene()
  scene.runtimeProps = { harbor_lantern = ownerGroup(modelKey) }
  local paths = MapAssetCache.referencedPaths(scene, c)
  Assert.isTrue(contains(paths, modelPath), "the owner model descriptor is referenced")
  Assert.isTrue(contains(paths, meshPath), "the owner model geometry is traversed")
end

-- Write a full ready map for `scene`, with exactly the given extra image
-- paths present (written explicitly, never derived from the traversal under
-- test).
local function writeSceneArtifacts(c, scene, marker, imagePaths)
  local dir = MapAssetCache.mapDir(scene.mapId)
  c:writeLua(dir .. "/scene.lua", scene)
  c:write(dir .. "/dependencies.lua", "return {}\n")
  c:write(MapAssetCache.terrainPath(scene.mapId), "return { schema = 'g4-terrain-surfaces-v1' }\n")
  c:write(MapAssetCache.collisionPath(scene.mapId), CollisionFixture.asset(32, 32))
  for _, path in ipairs(imagePaths or {}) do
    c:write(path, "png")
  end
  c:write(dir .. "/complete", marker)
end

-- Mutator helpers for the malformed material/swap batteries below.
---@param mutate fun(material: table)
---@return MapAssetCache.Scene
local function materialPatch(mutate)
  return patchedScene(function(s)
    local m = {
      id = 0,
      name = "m0",
      texture = BASE_TEX,
      texWidth = 16,
      texHeight = 16,
      texMtxMode = 0,
    }
    mutate(m)
    s.materials = { m }
  end)
end

---@param mutate fun(clip: MapAssetTest.Clip)
---@return MapAssetCache.Scene
local function clipPatch(mutate)
  return patchedScene(function(s)
    local clip = srtClip()
    mutate(clip)
    s.terrainAnimations = { textureSrt = clip }
  end)
end

---@param mutate fun(material: table)
---@return MapAssetCache.Scene
local function swapPatch(mutate)
  return patchedScene(function(s)
    local m = swapMaterial(BASE_TEX, {
      { texture = BASE_TEX, durationTicks = 18 },
      { texture = ALT1_TEX, durationTicks = 18 },
    })
    mutate(m)
    s.materials = { m }
  end)
end

function T.current_scene_requires_terrain_animations()
  raisesSceneInvalid(patchedScene(function(s)
    s.terrainAnimations = nil
  end))
end

function T.malformed_terrain_animations_raise_scene_invalid()
  local cases = {} ---@type (fun(scene: MapAssetCache.Scene))[]
  cases = {
    function(s)
      rawset(s, "terrainAnimations", "animations")
    end,
    function(s)
      s.terrainAnimations = {}
    end,
    function(s)
      s.terrainAnimations = { textureSrt = "no" }
    end,
    function(s)
      s.terrainAnimations = { textureSrt = 5 }
    end,
  }
  for _, mutate in ipairs(cases) do
    raisesSceneInvalid(patchedScene(mutate))
  end
end

function T.a_valid_false_clip_is_accepted()
  local c = cache()
  local marker = MapAssetCache.marker("romsha", 61, "dep")
  local s = baseScene()
  s.terrain = { file = MapAssetCache.terrainPath(61) }
  writeSceneArtifacts(c, s, marker)
  Assert.isTrue(MapAssetCache.isReady(c, 61, marker), "textureSrt = false is a valid scene")
end

-- A full valid scene: a clip, a central swap, and a neighbor cell sharing
-- the same swap name and durations with different texture paths (neighboring
-- cells compile the same animation against their own texture packs).
function T.valid_clip_and_texture_swap_shapes_are_accepted()
  local c = cache()
  local marker = MapAssetCache.marker("romsha", 61, "dep")
  local s = baseScene()
  s.terrain = { file = MapAssetCache.terrainPath(61) }
  s.terrainAnimations = { textureSrt = srtClip() }
  s.materials = {
    swapMaterial(BASE_TEX, {
      { texture = BASE_TEX, durationTicks = 18 },
      { texture = ALT1_TEX, durationTicks = 18 },
    }),
  }
  s.neighbors = {
    {
      offsetTilesX = 1,
      offsetTilesY = 0,
      offsetTilesZ = 0,
      batches = {},
      materials = {
        swapMaterial(ALT1_TEX, {
          { texture = ALT1_TEX, durationTicks = 18 },
          { texture = BASE_TEX, durationTicks = 18 },
        }),
      },
    },
  }
  writeSceneArtifacts(c, s, marker, { BASE_TEX, ALT1_TEX })
  Assert.isTrue(MapAssetCache.isReady(c, 61, marker), "a valid clip and textureSwap records are accepted")
end

function T.referenced_paths_includes_every_swap_step_texture()
  local s = baseScene()
  s.materials = {
    swapMaterial(BASE_TEX, FLOWER_STEPS),
  }
  s.neighbors = {
    {
      offsetTilesX = 1,
      offsetTilesY = 0,
      offsetTilesZ = 0,
      batches = {},
      materials = {
        {
          id = 0,
          name = "flower02",
          texture = ALT1_TEX,
          texWidth = 16,
          texHeight = 16,
          texMtxMode = 0,
          textureSwap = {
            name = "flower02",
            steps = {
              { texture = ALT1_TEX, durationTicks = 18 },
              { texture = ALT2_TEX, durationTicks = 18 },
            },
          },
        },
      },
    },
  }
  local paths = MapAssetCache.referencedPaths(s, nil)
  for _, path in ipairs({ BASE_TEX, ALT1_TEX, ALT2_TEX }) do
    Assert.isTrue(contains(paths, path), "missing swap step texture path " .. path)
  end
end

function T.a_missing_swap_step_image_makes_is_ready_false()
  local c = cache()
  local marker = MapAssetCache.marker("romsha", 61, "dep")
  local s = baseScene()
  s.terrain = { file = MapAssetCache.terrainPath(61) }
  s.materials = {
    swapMaterial(BASE_TEX, {
      { texture = BASE_TEX, durationTicks = 18 },
      { texture = ALT1_TEX, durationTicks = 18 },
    }),
  }
  writeSceneArtifacts(c, s, marker, { BASE_TEX })
  Assert.isFalse(MapAssetCache.isReady(c, 61, marker), "the missing step image keeps the map not ready")
  c:write(ALT1_TEX, "png")
  Assert.isTrue(MapAssetCache.isReady(c, 61, marker), "with the step image present the map is ready")
end

-- One malformed-clip case through the MAP_CACHE_SCENE_INVALID boundary: the
-- clip contract itself lives in the shared validator, so a single proof of
-- delegation suffices here.
function T.malformed_nsbta_failures_delegate_to_the_shared_validator()
  raisesSceneInvalid(clipPatch(function(c)
    c.compiled.targets[1].channels.transS =
      { source = "curve", rate = 1, limit = 8, storage = "fx16", keys = { 0, 1, 2 } }
  end))
end

function T.malformed_texture_swap_shapes_raise_scene_invalid()
  local cases = {} ---@type (fun(material: table))[]
  cases = {
    function(m)
      m.textureSwap.name = ""
    end,
    function(m)
      m.textureSwap.name = 5
    end,
    function(m)
      m.textureSwap.steps = {}
    end,
    function(m)
      m.textureSwap.steps = { named = 1 }
    end,
    function(m)
      m.textureSwap.steps = { 5 }
    end,
    function(m)
      m.textureSwap.steps = { { texture = "", durationTicks = 18 } }
    end,
    function(m)
      m.textureSwap.steps = { { texture = 5, durationTicks = 18 } }
    end,
    function(m)
      m.textureSwap.steps = { { texture = BASE_TEX } }
    end,
    function(m)
      m.textureSwap.steps = { { texture = BASE_TEX, durationTicks = -1 } }
    end,
    function(m)
      m.textureSwap.steps = { { texture = BASE_TEX, durationTicks = 2.5 } }
    end,
    -- A swap attached to an untextured material has no base image to start
    -- from.
    function(m)
      rawset(m, "texture", nil)
    end,
  }
  for _, mutate in ipairs(cases) do
    raisesSceneInvalid(swapPatch(mutate))
  end
end

function T.zero_duration_swap_steps_are_accepted()
  local s = baseScene()
  s.materials = {
    swapMaterial(BASE_TEX, {
      { texture = BASE_TEX, durationTicks = 0 },
      { texture = ALT1_TEX, durationTicks = 18 },
    }),
  }
  Assert.isTrue(
    type(MapAssetCache.referencedPaths(s, nil)) == "table",
    "a zero-duration step is a valid source-derived schedule entry"
  )
end

function T.malformed_material_terrain_fields_raise_scene_invalid()
  local cases = {} ---@type (fun(material: table))[]
  cases = {
    function(m)
      m.texWidth = 0
    end,
    function(m)
      m.texWidth = -4
    end,
    function(m)
      m.texWidth = 2.5
    end,
    function(m)
      m.texHeight = "16"
    end,
    function(m)
      m.texMtxMode = 0.5
    end,
    function(m)
      m.texMtxMode = "0"
    end,
    -- Only texture-matrix mode 0 has a compiled convention; the runtime
    -- raises on any other mode, so generated data must fail here instead.
    function(m)
      m.texMtxMode = 1
    end,
    function(m)
      m.texMtxMode = 2
    end,
    function(m)
      m.texMtxMode = 3
    end,
    function(m)
      m.texMtxMode = 4
    end,
    function(m)
      m.texMtxMode = -1
    end,
    function(m)
      m.srt =
        { scaleS = 4096.5, scaleT = 4096, transS = 0, transT = 0, scaleOne = true, transOne = true, rotOne = true }
    end,
    function(m)
      m.srt = {
        scaleS = 4096,
        scaleT = 4096,
        transS = 0,
        transT = 0,
        rot = 5,
        scaleOne = true,
        transOne = true,
        rotOne = true,
      }
    end,
  }
  for _, mutate in ipairs(cases) do
    raisesSceneInvalid(materialPatch(mutate))
  end
end

-- ---- additional strictness rules ----

-- Material ids are the runtime's indexing domain: a record without an id, or
-- with an id outside the non-negative integers, is malformed generated data.
function T.material_ids_must_be_valid_non_negative_integers()
  raisesSceneInvalid(patchedScene(function(s)
    s.materials = {
      { id = nil, name = "a", texture = BASE_TEX, texWidth = 16, texHeight = 16, texMtxMode = 0 },
    }
  end))
  raisesSceneInvalid(patchedScene(function(s)
    s.materials = {
      { id = 0.5, name = "a", texture = BASE_TEX, texWidth = 16, texHeight = 16, texMtxMode = 0 },
    }
  end))
end

function T.duplicate_material_ids_in_one_list_raise_scene_invalid()
  local function withMaterials(materials)
    return patchedScene(function(s)
      s.materials = materials
    end)
  end
  raisesSceneInvalid(withMaterials({
    { id = 0, name = "a", texture = BASE_TEX, texWidth = 16, texHeight = 16, texMtxMode = 0 },
    { id = 0, name = "b", texture = ALT1_TEX, texWidth = 16, texHeight = 16, texMtxMode = 0 },
  }))
  raisesSceneInvalid(withMaterials({
    { id = 3, name = "a", texture = BASE_TEX, texWidth = 16, texHeight = 16, texMtxMode = 0 },
    { id = 3, name = "b", texture = ALT1_TEX, texWidth = 16, texHeight = 16, texMtxMode = 0 },
  }))
end

function T.duplicate_material_ids_in_one_neighbor_list_raise_scene_invalid()
  raisesSceneInvalid(patchedScene(function(s)
    s.neighbors = {
      {
        offsetTilesX = 1,
        offsetTilesY = 0,
        offsetTilesZ = 0,
        batches = {},
        materials = {
          { id = 0, name = "a", texture = BASE_TEX, texWidth = 16, texHeight = 16, texMtxMode = 0 },
          { id = 0, name = "b", texture = ALT1_TEX, texWidth = 16, texHeight = 16, texMtxMode = 0 },
        },
      },
    }
  end))
end

function T.the_same_material_id_in_different_lists_is_valid()
  local s = baseScene()
  s.materials = {
    { id = 0, name = "a", texture = BASE_TEX, texWidth = 16, texHeight = 16, texMtxMode = 0 },
  }
  s.neighbors = {
    {
      offsetTilesX = 1,
      offsetTilesY = 0,
      offsetTilesZ = 0,
      batches = {},
      materials = {
        { id = 0, name = "b", texture = ALT1_TEX, texWidth = 16, texHeight = 16, texMtxMode = 0 },
      },
    },
  }
  Assert.isTrue(type(MapAssetCache.referencedPaths(s, nil)) == "table", "ids are scoped per list")
end

function T.non_finite_numbers_raise_scene_invalid()
  local nan = 0 / 0
  local inf = math.huge
  raisesSceneInvalid(materialPatch(function(m)
    m.srt = { scaleS = nan, scaleT = 4096, transS = 0, transT = 0, scaleOne = true, transOne = true, rotOne = true }
  end))
  raisesSceneInvalid(materialPatch(function(m)
    m.srt = {
      scaleS = 4096,
      scaleT = 4096,
      transS = 0,
      transT = 0,
      rot = { sin = inf, cos = 0 },
      scaleOne = true,
      transOne = true,
      rotOne = true,
    }
  end))
end

function T.incomplete_srt_tables_raise_scene_invalid()
  raisesSceneInvalid(materialPatch(function(m)
    m.srt = {}
  end))
  raisesSceneInvalid(materialPatch(function(m)
    m.srt = { scaleS = 4096, scaleT = 4096, transS = 0, transT = 0, scaleOne = true, transOne = true }
  end))
end

function T.fractional_rotation_components_raise_scene_invalid()
  raisesSceneInvalid(materialPatch(function(m)
    m.srt = {
      scaleS = 4096,
      scaleT = 4096,
      transS = 0,
      transT = 0,
      rot = { sin = 0.5, cos = 0 },
      scaleOne = true,
      transOne = true,
      rotOne = true,
    }
  end))
end

-- Every terrain material record carries the texture-matrix inputs because
-- the terrain animator is constructed unconditionally; an untextured
-- material carries zero authored dimensions.
function T.untextured_materials_require_the_terrain_fields()
  raisesSceneInvalid(patchedScene(function(s)
    s.materials = { { id = 0, name = "untextured" } }
  end))
  local s = baseScene()
  s.materials = { { id = 0, name = "untextured", texWidth = 0, texHeight = 0, texMtxMode = 0 } }
  Assert.isTrue(
    type(MapAssetCache.referencedPaths(s, nil)) == "table",
    "an untextured material with zero authored dimensions is valid"
  )
end

-- The runtime groups texture swaps by name, so every occurrence of one name
-- must share the step count and per-step durations across the central scene
-- and every neighbor cell; only the texture paths may differ.
function T.same_name_swaps_with_different_timing_are_rejected()
  raisesSceneInvalid(patchedScene(function(s)
    s.materials = {
      swapMaterial(BASE_TEX, {
        { texture = BASE_TEX, durationTicks = 18 },
        { texture = ALT1_TEX, durationTicks = 18 },
      }),
    }
    s.neighbors = {
      {
        offsetTilesX = 1,
        offsetTilesY = 0,
        offsetTilesZ = 0,
        batches = {},
        materials = {
          swapMaterial(ALT1_TEX, {
            { texture = ALT1_TEX, durationTicks = 20 },
            { texture = BASE_TEX, durationTicks = 18 },
          }),
        },
      },
    }
  end))
  raisesSceneInvalid(patchedScene(function(s)
    s.materials = {
      swapMaterial(BASE_TEX, {
        { texture = BASE_TEX, durationTicks = 18 },
        { texture = ALT1_TEX, durationTicks = 18 },
      }),
    }
    s.neighbors = {
      {
        offsetTilesX = 1,
        offsetTilesY = 0,
        offsetTilesZ = 0,
        batches = {},
        materials = {
          swapMaterial(ALT1_TEX, {
            { texture = ALT1_TEX, durationTicks = 18 },
          }),
        },
      },
    }
  end))
end

function T.world_path_is_stable()
  Assert.equal(type(MapAssetCache.worldPath()), "string")
  Assert.isTrue(MapAssetCache.worldPath():match("world%.lua$") ~= nil)
end

return { tests = T }
