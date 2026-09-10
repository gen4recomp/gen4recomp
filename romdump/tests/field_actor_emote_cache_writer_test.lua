local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldEmoteAssetCache = require("libs.assets.src.field.FieldEmoteAssetCache")
local Writer = require("romdump.src.digest.actor.FieldActorEmoteCacheWriter")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

local T = { tests = {} }

local function modelAsset()
  return {
    schema = ModelAsset.SCHEMA,
    key = "field-emote:exclamation",
    kind = "static",
    batches = {
      {
        geometry = FieldEmoteAssetCache.geometryPath("mesh-key"),
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
        name = "exclamation",
        texture = FieldEmoteAssetCache.texturePath("texture-key"),
        textureFormat = 3,
        wrap = { x = "clamp", y = "clamp" },
        flip = { x = false, y = false },
        diffuse = { r = 255, g = 255, b = 255, a = 255 },
      },
    },
  }
end

local function model()
  return {
    schema = "g4-field-emote-v1",
    anchorOffset = { x = 0, y = 2, z = 0.0625 },
    model = modelAsset(),
  }
end

T.tests["publishes field-emote descriptor and referenced assets under owned roots"] = function()
  local data = {
    getSize = function()
      return #"encoded-mesh"
    end,
    getString = function()
      return "encoded-mesh"
    end,
  }
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local meshPath = FieldEmoteAssetCache.geometryPath("mesh-key")
  local bundle = {
    marker = "field-emotes-cache-v2:rom:dep",
    model = model(),
    meshes = { ["mesh-key"] = data },
    textures = { ["texture-key"] = { width = 1, height = 1, data = "png" } },
  }
  local ok, err = pcall(Writer.write, cache, bundle)
  Assert.isTrue(ok, tostring(err))
  Assert.isTrue(cache:exists(FieldEmoteAssetCache.exclamationDescriptorPath(), "file"))
  Assert.equal(cache:read(FieldEmoteAssetCache.markerPath()), bundle.marker)
  Assert.equal(cache:read(meshPath), "encoded-mesh")
end

T.tests["aborts before publication when the canonical descriptor is invalid"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local ok = pcall(Writer.write, cache, {
    marker = "field-emotes-cache-v2:rom:dep",
    model = { schema = "g4-field-emote-v1", anchorOffset = { x = 0, y = 2, z = 0.0625 }, model = {} },
    meshes = {},
    textures = {},
  })
  Assert.isFalse(ok)
  Assert.isFalse(cache:exists(FieldEmoteAssetCache.markerPath(), "file"))
  Assert.isFalse(cache:exists(FieldEmoteAssetCache.exclamationDescriptorPath(), "file"))
end

return T
