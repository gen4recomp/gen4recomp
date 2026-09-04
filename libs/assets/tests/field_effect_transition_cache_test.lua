-- Field-effect transition readiness: the strict cache accepts only the known
-- effect inventory, so a cache without the follower transition (or with an
-- entry beyond the inventory) is never ready.

local Assert = require("tests.support.Assert")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

local T = {}

-- The marker always tracks the current cache contract: these suites pin the
-- inventory rule, while the format-migration suites own the version literal.
local MARKER = FieldEffectAssetCache.FORMAT .. ":rom:dep"

local function validModel()
  return {
    schema = ModelAsset.SCHEMA,
    key = "field-effect:warp-entrance",
    kind = "static",
    batches = {
      {
        geometry = "mesh-a",
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
        texture = "texture-a",
        textureFormat = 3,
        wrap = { x = "clamp", y = "clamp" },
        flip = { x = false, y = false },
        diffuse = { r = 255, g = 255, b = 255, a = 255 },
        variants = {
          {
            name = "pattern.1",
            texture = "texture-variant",
            width = 1,
            height = 1,
            textureFormat = 3,
            alphaUsage = { hasZero = false, hasPartial = false, hasOpaque = true },
          },
        },
      },
    },
  }
end

local function validDynamicModel()
  return {
    schema = ModelAsset.SCHEMA,
    key = "field-effect:tall-grass",
    kind = "nitro-dynamic",
    dynamic = {
      nodes = { { name = "root" } },
      transformProgram = {},
      batches = {
        {
          id = "draw0",
          drawIndex = 0,
          nodeIndex = 0,
          materialIndex = 0,
          geometry = "grass.mesh",
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
    },
    materials = {
      {
        id = 0,
        name = "grass",
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
        diffuse = { r = 255, g = 255, b = 255, a = 255 },
        colors = {
          diffuse = { r = 255, g = 255, b = 255 },
          ambient = { r = 255, g = 255, b = 255 },
          specular = { r = 255, g = 255, b = 255 },
          emission = { r = 0, g = 0, b = 0 },
        },
      },
    },
    animations = {
      {
        id = "grass-animation",
        name = "grass",
        category = "joint",
        kind = "trs",
        frameCount = 4,
        tracks = { { target = 0, targetIndex = 0 } },
        semanticNames = {},
        compiled = {
          anmFlags = 0,
          rotData = { { control = 0, a = 0, b = 0 } },
          pivotData = { { 0, 0, 0, 0, 0 } },
          targets = {
            {
              nodeIndex = 0,
              channels = {
                trans = { x = { source = "model" }, y = { source = "model" }, z = { source = "model" } },
                rot = { source = "curve", rate = 1, limit = 4, storage = "fx16", keys = { 0, 0, 0, 0 } },
                scale = { x = { source = "model" }, y = { source = "model" }, z = { source = "model" } },
              },
            },
          },
        },
      },
    },
  }
end

-- The previous inventory, each definition independently valid, so the only
-- reason readiness can fail is the missing transition effect.
local function cacheWithoutTransition(extraEffect)
  local index = {
    schema = "g4-field-effect-index-v1",
    effects = {},
  }
  for _, kind in ipairs({ "warp_entrance", "tall_grass", "very_tall_grass", "trainer_reveal" }) do
    index.effects[kind] = {
      kind = kind == "warp_entrance" and "model" or "animated_model",
      definition = kind,
      path = FieldEffectAssetCache.definitionPath(kind),
    }
  end
  if extraEffect ~= nil then
    index.effects[extraEffect] = {
      kind = "model",
      definition = extraEffect,
      path = FieldEffectAssetCache.definitionPath(extraEffect),
    }
  end
  return {
    read = function(_, path)
      return path == FieldEffectAssetCache.markerPath() and MARKER or nil
    end,
    loadLua = function(_, path)
      if path == FieldEffectAssetCache.indexPath() then
        return index
      end
      if path == FieldEffectAssetCache.definitionPath("warp_entrance") then
        return { model = validModel(), lifetime = 1, kind = "model" }
      end
      if extraEffect ~= nil and path == FieldEffectAssetCache.definitionPath(extraEffect) then
        return { model = validModel(), lifetime = 1, kind = "model" }
      end
      if path == FieldEffectAssetCache.definitionPath("trainer_reveal") then
        return {
          model = validDynamicModel(),
          kind = "animated_model",
          lifecycle = { mode = "once", frameCount = 4 },
          placementOffset = { x = 0, y = 0, z = 0.5 },
        }
      end
      return {
        model = validDynamicModel(),
        kind = "animated_model",
        lifecycle = { mode = "hold_until_owner_moves", holdFrame = 3 },
        placementOffset = { x = 0.25, y = 0, z = -0.5 },
      }
    end,
    exists = function()
      return true
    end,
  }
end

function T.rejects_a_cache_without_the_transition_definition()
  -- Every carried definition validates on its own: the failure below can
  -- only come from the missing transition effect.
  Assert.isTrue(pcall(ModelAsset.validate, validModel()))
  Assert.isTrue(pcall(ModelAsset.validate, validDynamicModel()))
  Assert.isFalse(
    FieldEffectAssetCache.isReady(cacheWithoutTransition(), MARKER),
    "the previous four-effect inventory must not pass the transition-era contract"
  )
end

function T.rejects_an_effect_inventory_with_an_extra_entry()
  Assert.isFalse(
    FieldEffectAssetCache.isReady(cacheWithoutTransition("bogus_effect"), MARKER),
    "an entry beyond the known inventory must never be ready"
  )
end

return { tests = T }
