local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")

local T = { tests = {} }

-- Reduce one section's observed model member ids to a sorted distinct set
-- so duplicate decodes and call order never affect the source contract.
local function distinctMembers(observations, section)
  local seen = {}
  for _, memberId in ipairs(observations[section] or {}) do
    seen[memberId] = true
  end
  local ids = {}
  for memberId in pairs(seen) do
    ids[#ids + 1] = memberId
  end
  table.sort(ids)
  return ids
end

T.tests["compiles source-derived renderer 8 and 12 resources"] = function()
  local names = {
    "romdump.src.digest.field.FieldEntranceIndicatorCompiler",
    "libs.nds.src.nitro.g3d.Nsbmd",
    "libs.nds.src.nitro.g3d.NitroAnimation",
    "romdump.src.digest.field.FieldEffectPatternAnimation",
    "romdump.src.digest.model.ModelAssetCompiler",
    "romdump.src.digest.model.DynamicModelCompiler",
    "romdump.src.digest.model.MapPropAnimCompiler",
    "libs.assets.src.model.ModelAsset",
    "romdump.src.digest.Hashing",
    "romdump.src.config.FieldEffects",
  }
  local saved = {}
  for _, name in ipairs(names) do
    saved[name] = package.loaded[name]
  end

  local modelMembersBySection = {}
  local invalidSelector = false
  package.loaded["romdump.src.config.FieldEffects"] = {
    archive = { alias = "field_static_models" },
    animationArchive = { alias = "field_static_models" },
    effects = {
      warp_entrance = { renderer = 3, modelMembers = { 85 }, animationMembers = {} },
      tall_grass = {
        renderer = 8,
        modelMembers = { 126 },
        animationMembers = { 140 },
        lifecycle = { mode = "hold_until_owner_moves", holdFrame = 12 },
        placementOffset = { x = 0, y = 0, z = 0.625 },
      },
      very_tall_grass = {
        renderer = 12,
        modelMembers = { 122 },
        animationMembers = { 146 },
        lifecycle = { mode = "hold_until_owner_moves", holdFrame = 12 },
        placementOffset = { x = 0, y = 0, z = 0.625 },
      },
      trainer_reveal = {
        renderer = 1,
        modelMembers = { 124 },
        animationMembers = { 148 },
        lifecycle = { mode = "once", frameCount = 7 },
        placementOffset = { x = 0, y = 0, z = 0.5 },
      },
      surf_attachment = {
        modelMembers = { 86 },
        animationMembers = {},
        presentation = {
          initialPlayerOffset = { x = 0, y = 4 / 16, z = 4 / 16 },
          oscillator = { initialY = 1 / 16, minY = 1 / 16, maxY = 4 / 16, stepY = (1 / 4) / 16 },
          playerBaseOffset = { x = 0, y = 4 / 16, z = 4 / 16 },
          attachmentBaseOffset = { x = 0, y = -1 / 16, z = 0 },
          yawDegrees = { north = 180, south = 0, west = 270, east = 90 },
        },
      },
      follower_transition = {
        modelMembers = { 129, 104 },
        animationMembers = { 164 },
        animatedModelMember = 104,
        lifecycle = { mode = "once", preludeTicks = 2 },
        placementOffset = { x = 0, y = 6, z = 0 },
      },
    },
  }
  package.loaded["libs.nds.src.nitro.g3d.Nsbmd"] = {
    decode = function(_, context)
      assert(context and context.section, "Nsbmd.decode context.section is required")
      local bucket = modelMembersBySection[context.section]
      if not bucket then
        bucket = {}
        modelMembersBySection[context.section] = bucket
      end
      bucket[#bucket + 1] = context.memberId
      return {
        models = { { name = "model-" .. context.memberId, materials = { { name = "effect" } } } },
        embeddedTextures = {
          textures = { { name = "texture" } },
          palettes = { { name = "palette" } },
        },
      }
    end,
  }
  package.loaded["libs.nds.src.nitro.g3d.NitroAnimation"] = {
    decode = function(bytes)
      return {
        format = "NSBTA",
        bytes = bytes,
        animations = { { name = "mb_out", recordOffset = 0, resource = { numFrame = 8 } } },
      }
    end,
  }
  package.loaded["romdump.src.digest.field.FieldEffectPatternAnimation"] = {
    FORMAT = "FIELD_EFFECT_PATTERN",
    decode = function(_, context)
      local lastFrame
      if context.memberId == 146 then
        lastFrame = 119
      elseif context.memberId == 148 then
        lastFrame = 6
      else
        lastFrame = 1
      end
      return {
        lastFrame = lastFrame,
        keys = { { frame = 0, texIdx = invalidSelector and 1 or 0, plttIdx = 0 } },
      }
    end,
  }
  package.loaded["romdump.src.digest.model.ModelAssetCompiler"] = {
    compileModel = function(_, _, _, _, context)
      return {
        unresolved = {},
        batches = { { geometry = "assets/generated/maps/geometry/mesh.g4mesh" } },
        materials = { { name = context.modelName, texture = "assets/generated/maps/textures/texture.png" } },
      }
    end,
  }
  package.loaded["romdump.src.digest.model.MapPropAnimCompiler"] = {
    compileDecoded = function(decoded, opts)
      return {
        id = opts.id,
        name = opts.name,
        category = "material",
        kind = "pattern",
        frameCount = decoded.animations[1].resource.numFrame,
        tracks = { { target = "effect", targetIndex = 0 } },
        semanticNames = {},
        source = opts.source,
        compiled = { targets = { { name = "effect", index = 0 } } },
      }
    end,
  }
  package.loaded["romdump.src.digest.model.DynamicModelCompiler"] = {
    compile = function(_, _, _, animResult, _, memberId, meshes, textures)
      meshes["mesh"] = {}
      textures["texture"] = { width = 1, height = 1, pixels = "pixel" }
      return {
        schema = "g4-model-v1",
        memberId = memberId,
        kind = "nitro-dynamic",
        dynamic = {
          nodes = {},
          transformProgram = {},
          batches = { { geometry = "assets/generated/maps/geometry/mesh.g4mesh" } },
        },
        materials = {
          {
            id = 0,
            name = "effect",
            texture = "assets/generated/maps/textures/texture.png",
            wrap = { x = "clamp", y = "clamp" },
            flip = { x = false, y = false },
          },
        },
        animations = animResult.clips,
      }, {}
    end,
  }
  package.loaded["libs.assets.src.model.ModelAsset"] = {
    SCHEMA = "g4-model-v1",
    validate = function() end,
  }
  package.loaded["romdump.src.digest.Hashing"] = {
    sha1hex = function(bytes)
      return "hash-" .. bytes
    end,
    hashLua = function()
      return "dependency-hash"
    end,
  }
  package.loaded["romdump.src.digest.field.FieldEntranceIndicatorCompiler"] = nil

  local ok, result, compiler, romFs = pcall(function()
    local compiler = require("romdump.src.digest.field.FieldEntranceIndicatorCompiler")
    local modelNarc = {
      memberCount = function()
        return 169
      end,
      readMember = function(_, memberId)
        return "model-" .. memberId
      end,
    }
    local animationNarc = {
      memberCount = function()
        return 169
      end,
      readMember = function(_, memberId)
        return "animation-" .. memberId
      end,
    }
    local openCount = 0
    local romFs = {
      openNarc = function()
        openCount = openCount + 1
        return openCount == 1 and modelNarc or animationNarc
      end,
      metadata = function()
        return { sha1 = "rom-sha1" }
      end,
    }
    return compiler.compile(romFs), compiler, romFs
  end)

  for _, name in ipairs(names) do
    package.loaded[name] = saved[name]
  end
  package.loaded["romdump.src.digest.field.FieldEntranceIndicatorCompiler"] = nil

  Assert.isTrue(ok, tostring(result))
  Assert.deepEqual(distinctMembers(modelMembersBySection, "warp-entrance-effect"), { 85 }, "warp-entrance-effect")
  Assert.deepEqual(distinctMembers(modelMembersBySection, "tall-grass-renderer-8"), { 126 }, "tall-grass-renderer-8")
  Assert.deepEqual(distinctMembers(modelMembersBySection, "tall-grass-renderer-12"), { 122 }, "tall-grass-renderer-12")
  Assert.deepEqual(distinctMembers(modelMembersBySection, "trainer-reveal-effect"), { 124 }, "trainer-reveal-effect")
  Assert.deepEqual(distinctMembers(modelMembersBySection, "surf-attachment-effect"), { 86 }, "surf-attachment-effect")
  Assert.deepEqual(
    distinctMembers(modelMembersBySection, "follower-transition-effect"),
    { 104, 129 },
    "follower-transition-effect"
  )
  Assert.equal(result.effects.warp_entrance.model.kind, "static")
  Assert.isNil(result.effects.warp_entrance.model.animations)
  local animation = result.effects.tall_grass.model.animations[1]
  Assert.equal(animation.source.memberId, 140)
  Assert.equal(animation.frameCount, 13)
  Assert.equal(animation.source.type, "field-effect")
  Assert.equal(animation.source.format, "FIELD_EFFECT_PATTERN")
  Assert.equal(result.effects.tall_grass.model.kind, "nitro-dynamic")
  Assert.equal(result.effects.tall_grass.lifecycle.mode, "hold_until_owner_moves")
  Assert.equal(result.effects.tall_grass.lifecycle.holdFrame, 12)
  Assert.isNil(result.effects.tall_grass.source)
  Assert.isNil(result.effects.tall_grass.animationSourceSha1)
  Assert.isNil(result.effects.tall_grass.lifetime)
  Assert.equal(result.effects.very_tall_grass.model.animations[1].source.memberId, 146)
  Assert.equal(result.effects.very_tall_grass.model.animations[1].frameCount, 120)
  Assert.equal(result.effects.very_tall_grass.model.kind, "nitro-dynamic")
  Assert.isNil(result.effects.very_tall_grass.lifetime)
  Assert.equal(result.effects.trainer_reveal.model.animations[1].source.memberId, 148)
  Assert.equal(result.effects.trainer_reveal.model.kind, "nitro-dynamic")
  Assert.equal(result.effects.trainer_reveal.lifecycle.mode, "once")
  Assert.equal(result.effects.trainer_reveal.lifecycle.frameCount, 7)
  Assert.equal(result.effects.trainer_reveal.placementOffset.x, 0)
  Assert.equal(result.effects.trainer_reveal.placementOffset.y, 0)
  Assert.equal(result.effects.trainer_reveal.placementOffset.z, 0.5)
  local surf = result.effects.surf_attachment
  Assert.notNil(surf)
  Assert.equal(surf.model.kind, "static")
  Assert.isNil(surf.model.animations)
  Assert.isNil(surf.lifecycle)
  Assert.isNil(surf.source)
  Assert.equal(surf.presentation.initialPlayerOffset.x, 0)
  Assert.equal(surf.presentation.initialPlayerOffset.y, 4 / 16)
  Assert.equal(surf.presentation.initialPlayerOffset.z, 4 / 16)
  Assert.equal(surf.presentation.oscillator.initialY, 1 / 16)
  Assert.equal(surf.presentation.oscillator.minY, 1 / 16)
  Assert.equal(surf.presentation.oscillator.maxY, 4 / 16)
  Assert.equal(surf.presentation.oscillator.stepY, (1 / 4) / 16)
  Assert.equal(surf.presentation.playerBaseOffset.x, 0)
  Assert.equal(surf.presentation.playerBaseOffset.y, 4 / 16)
  Assert.equal(surf.presentation.playerBaseOffset.z, 4 / 16)
  Assert.equal(surf.presentation.attachmentBaseOffset.x, 0)
  Assert.equal(surf.presentation.attachmentBaseOffset.y, -1 / 16)
  Assert.equal(surf.presentation.attachmentBaseOffset.z, 0)
  Assert.equal(surf.presentation.yawDegrees.north, 180)
  Assert.equal(surf.presentation.yawDegrees.south, 0)
  Assert.equal(surf.presentation.yawDegrees.west, 270)
  Assert.equal(surf.presentation.yawDegrees.east, 90)
  Assert.equal(result.index.effects.surf_attachment.kind, "model")
  Assert.equal(result.index.effects.surf_attachment.definition, "surf_attachment")
  local transition = result.effects.follower_transition
  Assert.notNil(transition, "the transition must compile from the traced members")
  Assert.equal(#transition.models, 2)
  Assert.equal(transition.models[1].key, "follower-transition-model-129")
  Assert.equal(transition.models[1].kind, "static")
  Assert.equal(transition.models[2].key, "follower-transition-model-104")
  Assert.equal(transition.models[2].kind, "nitro-dynamic")
  local transitionClip = assert(transition.models[2].animations[1])
  Assert.equal(transitionClip.source.memberId, 164)
  Assert.equal(transitionClip.source.format, "NSBTA")
  Assert.equal(transitionClip.frameCount, 8)
  Assert.equal(transition.lifecycle.mode, "once")
  Assert.equal(transition.lifecycle.frameCount, 8)
  Assert.equal(transition.lifecycle.preludeTicks, 2)
  Assert.equal(transition.placementOffset.x, 0)
  Assert.equal(transition.placementOffset.y, 0.375)
  Assert.equal(transition.placementOffset.z, 0)

  invalidSelector = true
  local invalidOk, invalidErr = pcall(compiler.compile, romFs)
  Assert.isFalse(invalidOk)
  Assert.isTrue(Errors.is(invalidErr))
  Assert.equal(invalidErr.code, "FIELD_EFFECT_SOURCE_INVALID")
end

T.tests["rewrites compiled geometry and texture references into the effect root"] = function()
  local names = {
    "romdump.src.digest.field.FieldEntranceIndicatorCompiler",
    "libs.nds.src.nitro.g3d.Nsbmd",
    "libs.nds.src.nitro.g3d.NitroAnimation",
    "romdump.src.digest.field.FieldEffectPatternAnimation",
    "romdump.src.digest.model.ModelAssetCompiler",
    "romdump.src.digest.model.DynamicModelCompiler",
    "romdump.src.digest.model.MapPropAnimCompiler",
    "libs.assets.src.model.ModelAsset",
    "romdump.src.digest.Hashing",
  }
  local saved = {}
  for _, name in ipairs(names) do
    saved[name] = package.loaded[name]
  end
  package.loaded["libs.nds.src.nitro.g3d.Nsbmd"] = {
    decode = function()
      return {
        models = { { name = "mock-effect", materials = { { name = "target" } } } },
        embeddedTextures = {
          textures = { { name = "texture" } },
          palettes = { { name = "palette" } },
        },
      }
    end,
  }
  package.loaded["libs.nds.src.nitro.g3d.NitroAnimation"] = {
    decode = function(bytes)
      return {
        format = "NSBTA",
        bytes = bytes,
        animations = { { name = "mb_out", recordOffset = 0, resource = { numFrame = 8 } } },
      }
    end,
  }
  package.loaded["romdump.src.digest.field.FieldEffectPatternAnimation"] = {
    FORMAT = "FIELD_EFFECT_PATTERN",
    decode = function(_, context)
      local memberId = context and context.memberId or 0
      local lastFrame = memberId == 148 and 6 or 0
      return {
        frameCount = 1,
        keys = { { frame = 0, texIdx = 0, plttIdx = 0 } },
        lastFrame = lastFrame,
      }
    end,
  }
  package.loaded["romdump.src.digest.model.ModelAssetCompiler"] = {
    compileModel = function(_, _, meshes, textures)
      meshes.mesh = {}
      textures.texture = { width = 1, height = 1, pixels = "pixel" }
      return {
        unresolved = {},
        batches = { { geometry = "assets/generated/maps/geometry/mesh.g4mesh" } },
        materials = { { name = "effect", texture = "assets/generated/maps/textures/texture.png" } },
      }
    end,
  }
  package.loaded["romdump.src.digest.model.MapPropAnimCompiler"] = {
    compileDecoded = function(decoded, opts)
      return {
        id = opts.id,
        name = opts.name,
        category = "joint",
        kind = "trs",
        frameCount = decoded.animations[1].resource.numFrame,
        tracks = { { target = "target", targetIndex = 0 } },
        semanticNames = {},
        source = opts.source,
        compiled = {},
      }
    end,
  }
  package.loaded["romdump.src.digest.model.DynamicModelCompiler"] = {
    compile = function(_, _, _, animResult, _, memberId, meshes, textures)
      meshes.mesh = {}
      textures.texture = { width = 1, height = 1, pixels = "pixel" }
      return {
        schema = "g4-model-v1",
        memberId = memberId,
        kind = "nitro-dynamic",
        dynamic = {
          nodes = {},
          transformProgram = {},
          batches = { { geometry = "assets/generated/maps/geometry/mesh.g4mesh" } },
        },
        materials = { { id = 0, name = "effect", texture = "assets/generated/maps/textures/texture.png" } },
        animations = animResult.clips,
      }, {}
    end,
  }
  package.loaded["libs.assets.src.model.ModelAsset"] = { SCHEMA = "g4-model-v1", validate = function() end }
  package.loaded["romdump.src.digest.Hashing"] = {
    sha1hex = function()
      return "rom-hash"
    end,
    hashLua = function()
      return "dependency-hash"
    end,
  }
  package.loaded["romdump.src.digest.field.FieldEntranceIndicatorCompiler"] = nil

  local ok, result = pcall(function()
    local compiler = require("romdump.src.digest.field.FieldEntranceIndicatorCompiler")
    local romFs = {
      openNarc = function()
        return {
          memberCount = function()
            return 169
          end,
          readMember = function()
            return "member-85"
          end,
        }
      end,
      metadata = function()
        return { sha1 = "rom-sha1" }
      end,
    }
    return compiler.compile(romFs)
  end)
  for _, name in ipairs(names) do
    package.loaded[name] = saved[name]
  end
  package.loaded["romdump.src.digest.field.FieldEntranceIndicatorCompiler"] = nil
  Assert.isTrue(ok, tostring(result))
  Assert.equal(result.model.batches[1].geometry, FieldEffectAssetCache.geometryPath("mesh"))
  Assert.equal(result.model.materials[1].texture, FieldEffectAssetCache.texturePath("texture"))
  Assert.notNil(result.effects.follower_transition, "the transition compiles alongside the entrance effects")
  Assert.isNil(result.model.memberId)
  Assert.isNil(result.manifest)
  Assert.isNil(result.archive)
  Assert.isNil(result.memberId)
  Assert.isNil(result.romSha1)
end

return T
