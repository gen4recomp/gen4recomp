local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local Writer = require("romdump.src.digest.field.FieldEntranceIndicatorCacheWriter")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

local T = { tests = {} }

local function model()
  return {
    schema = ModelAsset.SCHEMA,
    key = "field-effect:warp-entrance",
    kind = "static",
    batches = {
      {
        geometry = FieldEffectAssetCache.geometryPath("mesh-key"),
        cullMode = "back",
        polygonMode = "modulation",
        polygonId = 0,
        translucentDepthWrite = false,
        depthEqual = false,
        polygonAlpha = 31,
        lightMask = 5,
        fogEnabled = false,
      },
    },
    materials = {
      {
        id = 0,
        name = "effect",
        texture = FieldEffectAssetCache.texturePath("texture-key"),
        textureFormat = 3,
        wrap = { x = "clamp", y = "clamp" },
        flip = { x = false, y = false },
        diffuse = { r = 255, g = 255, b = 255, a = 255 },
      },
    },
  }
end

T.tests["publishes model marker and referenced mesh under owned effect roots"] = function()
  local oldEncode = MeshWriter.encode
  MeshWriter.encode = function()
    return "encoded-mesh"
  end
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local meshPath = FieldEffectAssetCache.geometryPath("mesh-key")
  local bundle = {
    marker = "field-effect-cache-v3:rom:dep",
    index = {
      schema = "g4-field-effect-index-v1",
      effects = {
        warp_entrance = { path = FieldEffectAssetCache.definitionPath("warp_entrance"), definition = "warp_entrance" },
        tall_grass = { path = FieldEffectAssetCache.definitionPath("tall_grass"), definition = "tall_grass" },
        very_tall_grass = {
          path = FieldEffectAssetCache.definitionPath("very_tall_grass"),
          definition = "very_tall_grass",
        },
      },
    },
    effects = {
      warp_entrance = { model = model(), lifetime = 1 },
      tall_grass = { model = model(), lifetime = 1 },
      very_tall_grass = { model = model(), lifetime = 1 },
    },
    meshes = { ["mesh-key"] = {} },
    textures = { ["texture-key"] = { width = 1, height = 1, pixels = "rgba" } },
  }
  local ok, err = pcall(Writer.write, cache, bundle)
  MeshWriter.encode = oldEncode
  Assert.isTrue(ok, tostring(err))
  Assert.isTrue(cache:exists(FieldEffectAssetCache.indexPath(), "file"))
  Assert.equal(cache:read(FieldEffectAssetCache.markerPath()), bundle.marker)
  Assert.equal(cache:read(meshPath), "encoded-mesh")
end

T.tests["aborts before publication when the canonical model is invalid"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local ok = pcall(Writer.write, cache, {
    marker = "field-effect-cache-v3:rom:dep",
    index = { schema = "g4-field-effect-index-v1", effects = {} },
    effects = {},
    model = {},
    meshes = {},
    textures = {},
  })
  Assert.isFalse(ok)
  Assert.isFalse(cache:exists(FieldEffectAssetCache.markerPath(), "file"))
  Assert.isFalse(cache:exists(FieldEffectAssetCache.indexPath(), "file"))
end

T.tests["publishes the surf attachment definition and its referenced paths atomically"] = function()
  local oldEncode = MeshWriter.encode
  MeshWriter.encode = function()
    return "encoded-mesh"
  end
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local surf = model()
  surf.key = "field-effect:surf-attachment"
  local surfDefinition = {
    model = surf,
    presentation = {
      initialPlayerOffset = { x = 0, y = 4 / 16, z = 4 / 16 },
      oscillator = { initialY = 1 / 16, minY = 1 / 16, maxY = 4 / 16, stepY = (1 / 4) / 16 },
      playerBaseOffset = { x = 0, y = 4 / 16, z = 4 / 16 },
      attachmentBaseOffset = { x = 0, y = -1 / 16, z = 0 },
      yawDegrees = { north = 180, south = 0, west = 270, east = 90 },
    },
  }
  local bundle = {
    marker = "field-effect-cache-v8:rom:dep",
    index = {
      schema = "g4-field-effect-index-v2",
      effects = {
        warp_entrance = { path = FieldEffectAssetCache.definitionPath("warp_entrance"), definition = "warp_entrance" },
        tall_grass = { path = FieldEffectAssetCache.definitionPath("tall_grass"), definition = "tall_grass" },
        very_tall_grass = {
          path = FieldEffectAssetCache.definitionPath("very_tall_grass"),
          definition = "very_tall_grass",
        },
        trainer_reveal = {
          path = FieldEffectAssetCache.definitionPath("trainer_reveal"),
          definition = "trainer_reveal",
        },
        surf_attachment = {
          path = FieldEffectAssetCache.definitionPath("surf_attachment"),
          definition = "surf_attachment",
        },
      },
    },
    effects = {
      warp_entrance = { model = model(), lifetime = 1 },
      tall_grass = { model = model(), lifetime = 1 },
      very_tall_grass = { model = model(), lifetime = 1 },
      trainer_reveal = { model = model(), lifetime = 1 },
      surf_attachment = surfDefinition,
    },
    meshes = { ["mesh-key"] = {} },
    textures = { ["texture-key"] = { width = 1, height = 1, pixels = "rgba" } },
  }
  local ok, err = pcall(Writer.write, cache, bundle)
  MeshWriter.encode = oldEncode
  Assert.isTrue(ok, tostring(err))
  local stored = assert(cache:loadLua(FieldEffectAssetCache.definitionPath("surf_attachment")))
  Assert.equal(stored.model.key, "field-effect:surf-attachment")
  Assert.equal(stored.presentation.yawDegrees.east, 90)
  Assert.equal(cache:read(FieldEffectAssetCache.markerPath()), bundle.marker)
end

T.tests["publishes multi-model transition definitions and aborts on a missing reference"] = function()
  local oldEncode = MeshWriter.encode
  MeshWriter.encode = function()
    return "encoded-mesh"
  end
  local function bundleFor(secondTexture)
    local first, second = model(), model()
    second.materials[1].texture = secondTexture
    return {
      marker = "field-effect-cache-v3:rom:dep",
      index = {
        schema = "g4-field-effect-index-v1",
        effects = {
          follower_transition = {
            path = FieldEffectAssetCache.definitionPath("follower_transition"),
            definition = "follower_transition",
          },
        },
      },
      effects = {
        follower_transition = {
          models = { first, second },
          lifecycle = { mode = "once", frameCount = 8, preludeTicks = 2 },
          placementOffset = { x = 0, y = 0.375, z = 0 },
        },
      },
      meshes = { ["mesh-key"] = {} },
      textures = { ["texture-key"] = { width = 1, height = 1, pixels = "rgba" } },
    }
  end
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local ok, err = pcall(Writer.write, cache, bundleFor(FieldEffectAssetCache.texturePath("texture-key")))
  MeshWriter.encode = oldEncode
  Assert.isTrue(ok, tostring(err))
  Assert.isTrue(cache:exists(FieldEffectAssetCache.definitionPath("follower_transition"), "file"))

  local broken = CacheFs.forVersion("heartgold", FakeCache.new())
  local badOk = pcall(Writer.write, broken, bundleFor(FieldEffectAssetCache.texturePath("absent-key")))
  Assert.isFalse(badOk, "a transition with a missing referenced asset must not publish")
  Assert.isFalse(broken:exists(FieldEffectAssetCache.markerPath(), "file"))
end

return T
