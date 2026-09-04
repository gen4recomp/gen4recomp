-- Field-effect readiness is defined by the strict current index and every
-- generated definition it references.

local Assert = require("tests.support.Assert")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

local T = { tests = {} }
local EXPECTED_MARKER = "field-effect-cache-v8:rom:dep"

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

local function cache(model, present, marker, omitLifecycle, omitPlacement, extra)
  extra = extra or {}
  local index = {
    schema = "g4-field-effect-index-v2",
    effects = {},
  }
  for _, kind in ipairs({
    "warp_entrance",
    "tall_grass",
    "very_tall_grass",
    "trainer_reveal",
    "surf_attachment",
    "follower_transition",
  }) do
    index.effects[kind] = {
      kind = (kind == "warp_entrance" or kind == "surf_attachment") and "model"
        or kind == "follower_transition" and "transition"
        or "animated_model",
      definition = kind,
      path = FieldEffectAssetCache.definitionPath(kind),
    }
  end
  if extra.omitTrainerReveal then
    index.effects.trainer_reveal = nil
  end
  -- When extra.unknownLifecycleMode is set, keep the index unchanged;
  -- the definition will have the unknown mode.
  return {
    read = function(_, path)
      return path == FieldEffectAssetCache.markerPath() and (marker or EXPECTED_MARKER) or nil
    end,
    loadLua = function(_, path)
      if path == FieldEffectAssetCache.indexPath() then
        return index
      end
      local kind = path:match("/([^/]+)%.lua$")
      if kind == "warp_entrance" then
        return { model = model, lifetime = 1, kind = "model" }
      end
      if kind == "surf_attachment" then
        local surfModel = validModel()
        surfModel.key = "field-effect:surf-attachment"
        return {
          model = surfModel,
          kind = "model",
          presentation = {
            initialPlayerOffset = { x = 0, y = 4 / 16, z = 4 / 16 },
            oscillator = { initialY = 1 / 16, minY = 1 / 16, maxY = 4 / 16, stepY = (1 / 4) / 16 },
            playerBaseOffset = { x = 0, y = 4 / 16, z = 4 / 16 },
            attachmentBaseOffset = { x = 0, y = -1 / 16, z = 0 },
            yawDegrees = { north = 180, south = 0, west = 270, east = 90 },
          },
        }
      end
      if kind == "follower_transition" then
        local transition = {
          models = { validModel(), validDynamicModel() },
          lifecycle = { mode = "once", frameCount = 4, preludeTicks = 2 },
          placementOffset = { x = 0, y = 0.375, z = 0 },
        }
        if extra.omitTransitionLifecycle then
          transition.lifecycle = nil
        end
        if extra.omitTransitionPlacement then
          transition.placementOffset = nil
        end
        return transition
      end
      if kind == "trainer_reveal" then
        if extra.unknownLifecycleMode then
          return {
            model = validDynamicModel(),
            kind = "animated_model",
            lifecycle = { mode = "unknown" },
          }
        end
        if extra.malformedOnceFrameCount then
          return {
            model = validDynamicModel(),
            kind = "animated_model",
            lifecycle = { mode = "once", frameCount = 999 },
          }
        end
        local trainerDefinition = {
          model = validDynamicModel(),
          kind = "animated_model",
          lifecycle = { mode = "once", frameCount = 4 },
          placementOffset = { x = 0, y = 0, z = 0.5 },
        }
        if extra.omitTrainerPlacement then
          trainerDefinition.placementOffset = nil
        elseif extra.trainerPlacement ~= nil then
          trainerDefinition.placementOffset = extra.trainerPlacement
        end
        return trainerDefinition
      end
      local definition = {
        model = validDynamicModel(),
        kind = "animated_model",
      }
      if not omitLifecycle then
        definition.lifecycle = { mode = "hold_until_owner_moves", holdFrame = 3 }
      end
      if not omitPlacement then
        definition.placementOffset = { x = 0.25, y = 0, z = -0.5 }
      end
      if extra.missingTrainerReveal and kind == "trainer_reveal" then
        return nil
      end
      return definition
    end,
    exists = function(_, path)
      return present[path] == true
    end,
  }
end

T.tests["accepts the current format and rejects the previous format"] = function()
  local present = {
    ["mesh-a"] = true,
    ["texture-a"] = true,
    ["texture-variant"] = true,
    ["grass.mesh"] = true,
  }
  local currentReady, currentErr = FieldEffectAssetCache.isReady(cache(validModel(), present), EXPECTED_MARKER)
  Assert.isTrue(currentReady, tostring(currentErr))

  local staleReady = FieldEffectAssetCache.isReady(
    cache(validModel(), {
      ["mesh-a"] = true,
      ["texture-a"] = true,
      ["texture-variant"] = true,
      ["grass.mesh"] = true,
    }, "field-effect-cache-v7:rom:dep"),
    EXPECTED_MARKER
  )
  Assert.isFalse(staleReady)
end

T.tests["accepts a complete runtime definition without source metadata"] = function()
  local ready, err = FieldEffectAssetCache.isReady(
    cache(validModel(), {
      ["mesh-a"] = true,
      ["texture-a"] = true,
      ["texture-variant"] = true,
      ["grass.mesh"] = true,
    }),
    EXPECTED_MARKER
  )
  Assert.isTrue(ready, tostring(err))
end

T.tests["rejects a missing referenced asset"] = function()
  local ready =
    FieldEffectAssetCache.isReady(cache(validModel(), { ["mesh-a"] = true, ["grass.mesh"] = true }), EXPECTED_MARKER)
  Assert.isFalse(ready)
end

T.tests["rejects grass definitions missing lifecycle metadata"] = function()
  local ready = FieldEffectAssetCache.isReady(
    cache(validModel(), {
      ["mesh-a"] = true,
      ["texture-a"] = true,
      ["texture-variant"] = true,
      ["grass.mesh"] = true,
    }, EXPECTED_MARKER, true, false),
    EXPECTED_MARKER
  )
  Assert.isFalse(ready)
end

T.tests["rejects grass definitions missing placement metadata"] = function()
  local ready = FieldEffectAssetCache.isReady(
    cache(validModel(), {
      ["mesh-a"] = true,
      ["texture-a"] = true,
      ["texture-variant"] = true,
      ["grass.mesh"] = true,
    }, EXPECTED_MARKER, false, true),
    EXPECTED_MARKER
  )
  Assert.isFalse(ready)
end

T.tests["rejects missing trainer reveal"] = function()
  local ready = FieldEffectAssetCache.isReady(
    cache(validModel(), {
      ["mesh-a"] = true,
      ["texture-a"] = true,
      ["texture-variant"] = true,
      ["grass.mesh"] = true,
    }, EXPECTED_MARKER, false, false, { omitTrainerReveal = true }),
    EXPECTED_MARKER
  )
  Assert.isFalse(ready)
end

T.tests["rejects unknown lifecycle mode"] = function()
  local ready = FieldEffectAssetCache.isReady(
    cache(validModel(), {
      ["mesh-a"] = true,
      ["texture-a"] = true,
      ["texture-variant"] = true,
      ["grass.mesh"] = true,
    }, EXPECTED_MARKER, false, false, { unknownLifecycleMode = true }),
    EXPECTED_MARKER
  )
  Assert.isFalse(ready)
end

T.tests["rejects malformed one-shot frame count"] = function()
  local ready = FieldEffectAssetCache.isReady(
    cache(validModel(), {
      ["mesh-a"] = true,
      ["texture-a"] = true,
      ["texture-variant"] = true,
      ["grass.mesh"] = true,
    }, EXPECTED_MARKER, false, false, { malformedOnceFrameCount = true }),
    EXPECTED_MARKER
  )
  Assert.isFalse(ready)
end

T.tests["accepts trainer reveal with the normalized source placement"] = function()
  local present = {
    ["mesh-a"] = true,
    ["texture-a"] = true,
    ["texture-variant"] = true,
    ["grass.mesh"] = true,
  }
  local ready, err = FieldEffectAssetCache.isReady(
    cache(validModel(), present, EXPECTED_MARKER, false, false, {
      trainerPlacement = { x = 0, y = 0, z = 0.5 },
    }),
    EXPECTED_MARKER
  )
  Assert.isTrue(ready, tostring(err))
end

T.tests["rejects trainer reveal with missing or malformed placement"] = function()
  local present = {
    ["mesh-a"] = true,
    ["texture-a"] = true,
    ["texture-variant"] = true,
    ["grass.mesh"] = true,
  }
  local missing = FieldEffectAssetCache.isReady(
    cache(validModel(), present, EXPECTED_MARKER, false, false, { omitTrainerPlacement = true }),
    EXPECTED_MARKER
  )
  Assert.isFalse(missing, "trainer reveal without placement must not be ready")
  local malformed = FieldEffectAssetCache.isReady(
    cache(validModel(), present, EXPECTED_MARKER, false, false, {
      trainerPlacement = { x = 0, y = 0, z = 0 / 0 },
    }),
    EXPECTED_MARKER
  )
  Assert.isFalse(malformed, "trainer reveal with non-finite placement must not be ready")
end

local SURF_MARKER = "field-effect-cache-v8:rom:dep"
local SURF_INDEX_SCHEMA = "g4-field-effect-index-v2"

local function validSurfModel()
  local model = validModel()
  model.key = "field-effect:surf-attachment"
  return model
end

local function validSurfPresentation()
  return {
    initialPlayerOffset = { x = 0, y = 4 / 16, z = 4 / 16 },
    oscillator = { initialY = 1 / 16, minY = 1 / 16, maxY = 4 / 16, stepY = (1 / 4) / 16 },
    playerBaseOffset = { x = 0, y = 4 / 16, z = 4 / 16 },
    attachmentBaseOffset = { x = 0, y = -1 / 16, z = 0 },
    yawDegrees = { north = 180, south = 0, west = 270, east = 90 },
  }
end

local function validSurfDefinition()
  return { model = validSurfModel(), kind = "model", presentation = validSurfPresentation() }
end

local function surfCache(surfDefinition, mutateIndex)
  local present = {
    ["mesh-a"] = true,
    ["texture-a"] = true,
    ["texture-variant"] = true,
    ["grass.mesh"] = true,
  }
  local index = {
    schema = SURF_INDEX_SCHEMA,
    effects = {
      warp_entrance = {
        kind = "model",
        definition = "warp_entrance",
        path = FieldEffectAssetCache.definitionPath("warp_entrance"),
      },
      tall_grass = {
        kind = "animated_model",
        definition = "tall_grass",
        path = FieldEffectAssetCache.definitionPath("tall_grass"),
      },
      very_tall_grass = {
        kind = "animated_model",
        definition = "very_tall_grass",
        path = FieldEffectAssetCache.definitionPath("very_tall_grass"),
      },
      trainer_reveal = {
        kind = "animated_model",
        definition = "trainer_reveal",
        path = FieldEffectAssetCache.definitionPath("trainer_reveal"),
      },
      surf_attachment = {
        kind = "model",
        definition = "surf_attachment",
        path = FieldEffectAssetCache.definitionPath("surf_attachment"),
      },
      follower_transition = {
        kind = "transition",
        definition = "follower_transition",
        path = FieldEffectAssetCache.definitionPath("follower_transition"),
      },
    },
  }
  if mutateIndex ~= nil then
    mutateIndex(index)
  end
  return {
    read = function(_, path)
      return path == FieldEffectAssetCache.markerPath() and SURF_MARKER or nil
    end,
    loadLua = function(_, path)
      if path == FieldEffectAssetCache.indexPath() then
        return index
      end
      local kind = path:match("/([^/]+)%.lua$")
      if kind == "warp_entrance" then
        return { model = validModel(), lifetime = 1, kind = "model" }
      end
      if kind == "surf_attachment" then
        return surfDefinition
      end
      if kind == "follower_transition" then
        return {
          models = { validModel(), validDynamicModel() },
          lifecycle = { mode = "once", frameCount = 4, preludeTicks = 2 },
          placementOffset = { x = 0, y = 0.375, z = 0 },
        }
      end
      if kind == "trainer_reveal" then
        return {
          model = validDynamicModel(),
          kind = "animated_model",
          lifecycle = { mode = "once", frameCount = 4 },
          placementOffset = { x = 0, y = 0, z = 0.5 },
        }
      end
      if kind == "tall_grass" or kind == "very_tall_grass" then
        return {
          model = validDynamicModel(),
          kind = "animated_model",
          lifecycle = { mode = "hold_until_owner_moves", holdFrame = 3 },
          placementOffset = { x = 0.25, y = 0, z = -0.5 },
        }
      end
      error("unexpected field-effect cache path " .. path)
    end,
    exists = function(_, path)
      return present[path] == true
    end,
  }
end

T.tests["requires the surf attachment with normalized presentation"] = function()
  local ready, err = FieldEffectAssetCache.isReady(surfCache(validSurfDefinition()), SURF_MARKER)
  Assert.isTrue(ready, tostring(err))
end

T.tests["rejects a field-effect bundle without the surf attachment"] = function()
  local missingEntry = FieldEffectAssetCache.isReady(
    surfCache(validSurfDefinition(), function(index)
      index.effects.surf_attachment = nil
    end),
    SURF_MARKER
  )
  Assert.isFalse(missingEntry, "a bundle without the surf index entry must not be ready")
  local missingDefinition = FieldEffectAssetCache.isReady(surfCache(nil), SURF_MARKER)
  Assert.isFalse(missingDefinition, "a bundle without the surf definition must not be ready")
end

T.tests["rejects a surf attachment without a static model"] = function()
  local definition = validSurfDefinition()
  definition.model.kind = "nitro-dynamic"
  local ready = FieldEffectAssetCache.isReady(surfCache(definition), SURF_MARKER)
  Assert.isFalse(ready, "surf attachment must be a static model")
end

T.tests["rejects malformed surf oscillator bounds and steps"] = function()
  local function readyWithOscillator(oscillator)
    local definition = validSurfDefinition()
    definition.presentation.oscillator = oscillator
    return FieldEffectAssetCache.isReady(surfCache(definition), SURF_MARKER)
  end
  Assert.isFalse(
    readyWithOscillator({ initialY = 1 / 16, minY = 1 / 16, maxY = 4 / 16, stepY = 0 }),
    "a zero oscillator step must not be ready"
  )
  Assert.isFalse(
    readyWithOscillator({ initialY = 1 / 16, minY = 1 / 16, maxY = 4 / 16, stepY = -0.015625 }),
    "a negative oscillator step must not be ready"
  )
  Assert.isFalse(
    readyWithOscillator({ initialY = 1 / 16, minY = 4 / 16, maxY = 1 / 16, stepY = (1 / 4) / 16 }),
    "inverted oscillator bounds must not be ready"
  )
  Assert.isFalse(
    readyWithOscillator({ initialY = 0 / 0, minY = 1 / 16, maxY = 4 / 16, stepY = (1 / 4) / 16 }),
    "a non-finite oscillator bound must not be ready"
  )
end

T.tests["rejects a surf attachment with incomplete facing yaw"] = function()
  local definition = validSurfDefinition()
  definition.presentation.yawDegrees.east = nil
  local ready = FieldEffectAssetCache.isReady(surfCache(definition), SURF_MARKER)
  Assert.isFalse(ready, "surf attachment must yaw for all four facings")
end

T.tests["rejects non-finite surf offsets"] = function()
  local notANumber = validSurfDefinition()
  notANumber.presentation.initialPlayerOffset.y = 0 / 0
  Assert.isFalse(
    FieldEffectAssetCache.isReady(surfCache(notANumber), SURF_MARKER),
    "surf attachment with a NaN offset must not be ready"
  )
  local infinite = validSurfDefinition()
  infinite.presentation.attachmentBaseOffset.y = math.huge
  Assert.isFalse(
    FieldEffectAssetCache.isReady(surfCache(infinite), SURF_MARKER),
    "surf attachment with an infinite offset must not be ready"
  )
end

T.tests["rejects the transition without lifecycle or placement metadata"] = function()
  local present = {
    ["mesh-a"] = true,
    ["texture-a"] = true,
    ["texture-variant"] = true,
    ["grass.mesh"] = true,
  }
  local missingLifecycle = FieldEffectAssetCache.isReady(
    cache(validModel(), present, EXPECTED_MARKER, false, false, { omitTransitionLifecycle = true }),
    EXPECTED_MARKER
  )
  Assert.isFalse(missingLifecycle, "the transition without lifecycle metadata must not be ready")
  local missingPlacement = FieldEffectAssetCache.isReady(
    cache(validModel(), present, EXPECTED_MARKER, false, false, { omitTransitionPlacement = true }),
    EXPECTED_MARKER
  )
  Assert.isFalse(missingPlacement, "the transition without placement metadata must not be ready")
end

return T
