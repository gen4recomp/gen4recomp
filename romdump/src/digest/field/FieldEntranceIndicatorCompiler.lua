-- Compiles HGSS field effects from the curated model and animation archives.
-- Nitro decoding ends here; the runtime receives only normalized model data
-- and content-addressed mesh/texture references.

local Errors = require("libs.errors.src.Errors")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local NitroAnimation = require("libs.nds.src.nitro.g3d.NitroAnimation")
local FieldEffectPatternAnimation = require("romdump.src.digest.field.FieldEffectPatternAnimation")
local ModelAssetCompiler = require("romdump.src.digest.model.ModelAssetCompiler")
local DynamicModelCompiler = require("romdump.src.digest.model.DynamicModelCompiler")
local MapPropAnimCompiler = require("romdump.src.digest.model.MapPropAnimCompiler")
local MapUnits = require("romdump.src.digest.map.MapUnits")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local Hashing = require("romdump.src.digest.Hashing")
local FieldEffects = require("romdump.src.config.FieldEffects")
local Contract = require("libs.assets.src.DerivedAssetContract")

local Compiler = {}

local function member(narc, memberId, archive)
  if memberId < 0 or memberId >= narc:memberCount() then
    Errors.raise("FIELD_EFFECT_SOURCE_MISSING", "field-effect source member is unavailable", {
      archive = archive or "field_static_models",
      memberId = memberId,
      count = narc:memberCount(),
    })
  end
  return assert(narc:readMember(memberId))
end

local function sourceHashes(narc, members, archive)
  local hashes = {}
  for _, memberId in ipairs(members) do
    hashes[#hashes + 1] = { memberId = memberId, sha1 = Hashing.sha1hex(member(narc, memberId, archive)) }
  end
  return hashes
end

local function compileModel(narc, memberId, key, section, role)
  local bytes = member(narc, memberId)
  local decoded = assert(Nsbmd.decode(bytes, {
    alias = "field_static_models",
    memberId = memberId,
    section = section,
  }))
  local model = decoded.models[1]
  if not model or not decoded.embeddedTextures then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "field-effect model has no decodable model textures", {
      archive = "field_static_models",
      memberId = memberId,
    })
  end
  local meshes, textures = {}, {}
  local compiled = ModelAssetCompiler.compileModel(model, decoded.embeddedTextures, meshes, textures, {
    role = role,
    modelArchive = "field_static_models",
    modelMemberId = memberId,
    modelName = model.name,
    textureArchive = "field_static_models",
    textureMemberId = memberId,
  })
  if #compiled.unresolved > 0 then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "field-effect model has unresolved materials", {
      archive = "field_static_models",
      memberId = memberId,
      unresolved = compiled.unresolved,
    })
  end
  local descriptor = {
    schema = ModelAsset.SCHEMA,
    key = key,
    kind = "static",
    batches = compiled.batches,
    materials = compiled.materials,
  }
  for _, batch in ipairs(descriptor.batches) do
    local sha1 = assert(batch.geometry:match("/([^/]+)%.g4mesh$"), "compiled field-effect geometry path is malformed")
    batch.geometry = FieldEffectAssetCache.geometryPath(sha1)
  end
  for _, material in ipairs(descriptor.materials) do
    if material.texture then
      local sha1 = assert(material.texture:match("/([^/]+)%.png$"), "compiled field-effect texture path is malformed")
      material.texture = FieldEffectAssetCache.texturePath(sha1)
    end
  end
  ModelAsset.validate(descriptor)
  return descriptor, meshes, textures, Hashing.sha1hex(bytes)
end

local function rewriteEffectPaths(descriptor)
  for _, batch in ipairs(descriptor.dynamic.batches) do
    local sha1 = assert(batch.geometry:match("/([^/]+)%.g4mesh$"))
    batch.geometry = FieldEffectAssetCache.geometryPath(sha1)
  end
  for _, material in ipairs(descriptor.materials) do
    if material.texture then
      local sha1 = assert(material.texture:match("/([^/]+)%.png$"))
      material.texture = FieldEffectAssetCache.texturePath(sha1)
    end
    for _, variant in ipairs(material.variants or {}) do
      if variant.texture then
        local sha1 = assert(variant.texture:match("/([^/]+)%.png$"))
        variant.texture = FieldEffectAssetCache.texturePath(sha1)
      end
    end
  end
end

local function compileDynamicEffect(
  narc,
  animationNarc,
  animationArchive,
  modelMemberId,
  animationMemberId,
  key,
  section,
  role,
  source
)
  local modelBytes = member(narc, modelMemberId)
  local decodedModel = assert(Nsbmd.decode(modelBytes, {
    alias = "field_static_models",
    memberId = modelMemberId,
    section = section,
  }))
  local model = decodedModel.models[1]
  if not model or not decodedModel.embeddedTextures then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "field-effect dynamic model is incomplete", {
      archive = "field_static_models",
      memberId = modelMemberId,
    })
  end

  local animationBytes = member(animationNarc, animationMemberId, animationArchive)
  local decodedPattern, err = FieldEffectPatternAnimation.decode(animationBytes, {
    alias = animationArchive,
    memberId = animationMemberId,
    section = "field-effect-grass-animation",
  })
  if not decodedPattern then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "field-effect animation could not be decoded", {
      archive = animationArchive,
      memberId = animationMemberId,
      error = err,
    })
  end
  assert(decodedPattern)
  assert(source.lifecycle and source.lifecycle.mode, "effect source semantics are required")
  local material = model.materials[1]
  if not material then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "field-effect model has no material target", {
      archive = "field_static_models",
      memberId = modelMemberId,
    })
  end
  local textureNames, paletteNames = {}, {}
  for _, texture in ipairs(decodedModel.embeddedTextures.textures) do
    textureNames[#textureNames + 1] = texture.name
  end
  for _, palette in ipairs(decodedModel.embeddedTextures.palettes) do
    paletteNames[#paletteNames + 1] = palette.name
  end
  local keys = {}
  for index, keyFrame in ipairs(decodedPattern.keys) do
    local function validateSelector(selector, names, selectorName)
      if selector < 0 or selector >= #names then
        Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "field-effect animation selector is out of range", {
          effect = key,
          archive = animationArchive,
          memberId = animationMemberId,
          keyIndex = index - 1,
          frame = keyFrame.frame,
          selector = selectorName,
          value = selector,
          count = #names,
        })
      end
    end
    validateSelector(keyFrame.texIdx, textureNames, "texture")
    validateSelector(keyFrame.plttIdx, paletteNames, "palette")
    keys[#keys + 1] = {
      frame = keyFrame.frame,
      texIdx = keyFrame.texIdx,
      plttIdx = keyFrame.plttIdx,
    }
  end
  local mode = source.lifecycle.mode
  local lastFrame = decodedPattern.lastFrame
  assert(type(lastFrame) == "number", "effect source frame metadata is required")
  local frameCount
  if mode == "hold_until_owner_moves" then
    local holdFrame = source.lifecycle.holdFrame
    assert(type(holdFrame) == "number", "grass source frame metadata is required")
    assert(source.placementOffset, "grass placement is required")
    frameCount = math.max(holdFrame + 1, lastFrame + 1)
  elseif mode == "once" then
    local onceCount = source.lifecycle.frameCount
    assert(
      type(onceCount) == "number" and onceCount == math.floor(onceCount) and onceCount >= 1,
      "once frame count is required"
    )
    if lastFrame + 1 < onceCount then
      Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "field-effect animation has too few frames", {
        archive = animationArchive,
        memberId = animationMemberId,
        expected = onceCount,
        actual = lastFrame + 1,
      })
    end
    frameCount = onceCount
  else
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "unknown field-effect lifecycle mode", {
      mode = mode,
    })
  end
  local normalizedAnimation = {
    format = "NSBTP",
    bytes = animationBytes,
    animations = {
      {
        name = "field-effect-pattern",
        resource = {
          numFrame = frameCount,
          textureNames = textureNames,
          paletteNames = paletteNames,
          targets = {
            {
              index = 0,
              name = material.name,
              rate = 1,
              keys = keys,
            },
          },
        },
      },
    },
  }
  local clip = MapPropAnimCompiler.compileDecoded(normalizedAnimation, {
    name = normalizedAnimation.animations[1].name,
    id = key .. ":animation",
    source = {
      type = "field-effect",
      format = FieldEffectPatternAnimation.FORMAT,
      archive = animationArchive,
      memberId = animationMemberId,
      sha1 = Hashing.sha1hex(animationBytes),
    },
  })
  local meshes, textures = {}, {}
  local descriptor, unresolved = DynamicModelCompiler.compile(
    model,
    decodedModel,
    decodedModel.embeddedTextures,
    { clips = { clip } },
    {
      role = role,
      modelArchive = "field_static_models",
      modelMemberId = modelMemberId,
      modelName = model.name,
      textureArchive = "field_static_models",
      textureMemberId = modelMemberId,
    },
    modelMemberId,
    textures,
    meshes
  )
  if #unresolved > 0 then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "field-effect dynamic model has unresolved materials", {
      archive = "field_static_models",
      memberId = modelMemberId,
      unresolved = unresolved,
    })
  end
  descriptor.key = key
  rewriteEffectPaths(descriptor)
  ModelAsset.validate(descriptor)
  return descriptor, meshes, textures, Hashing.sha1hex(modelBytes)
end

local compileDynamicModel = compileDynamicEffect

-- Compile the transient follower effect from its two source models and the
-- single animation member. The animation rides the shared Nitro dispatch
-- (member 164 decodes on the NSBTA path, unlike the pattern animations of
-- the grass/trainer effects), and the clip attaches to the selection's
-- animated model. The companion model compiles static through the same path
-- as the warp entrance. The traced source-model-unit placement offset
-- normalizes through MapUnits, and the lifecycle carries the exact compiled
-- clip frame count with the traced two-tick prelude.
local function compileTransitionEffect(narc, animationNarc, animationArchive, key, section, role, source)
  if #source.modelMembers ~= 2 then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "the follower transition requires exactly two source models", {
      effect = key,
      modelMembers = source.modelMembers,
    })
  end
  if #source.animationMembers ~= 1 then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "the follower transition requires exactly one source animation", {
      effect = key,
      animationMembers = source.animationMembers,
    })
  end
  if source.lifecycle == nil or source.lifecycle.mode ~= "once" then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "the follower transition requires a once lifecycle", {
      effect = key,
      lifecycle = source.lifecycle,
    })
  end
  local preludeTicks = source.lifecycle.preludeTicks
  if type(preludeTicks) ~= "number" or preludeTicks % 1 ~= 0 or preludeTicks < 1 then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "the follower transition requires a positive prelude tick count", {
      effect = key,
      preludeTicks = preludeTicks,
    })
  end
  if type(source.placementOffset) ~= "table" then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "the follower transition requires a placement offset", {
      effect = key,
    })
  end
  assert(
    type(source.placementOffset.x) == "number"
      and type(source.placementOffset.y) == "number"
      and type(source.placementOffset.z) == "number",
    "follower-transition placement offset must carry numeric axes"
  )

  local animationMemberId = source.animationMembers[1]
  local animationBytes = member(animationNarc, animationMemberId, animationArchive)
  local decoded, decodeErr = NitroAnimation.decode(animationBytes, {
    alias = animationArchive,
    memberId = animationMemberId,
  })
  if not decoded then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "follower-transition animation could not be decoded", {
      archive = animationArchive,
      memberId = animationMemberId,
      error = decodeErr,
    })
  end
  assert(decoded)
  local clip = MapPropAnimCompiler.compileDecoded(decoded, {
    name = assert(decoded.animations[1]).name,
    id = key .. ":animation",
    source = {
      type = "field-effect",
      format = decoded.format,
      archive = animationArchive,
      memberId = animationMemberId,
      sha1 = Hashing.sha1hex(animationBytes),
    },
  })

  local animatedMemberId = source.animatedModelMember
  local animatedSelected = false
  for _, memberId in ipairs(source.modelMembers) do
    if memberId == animatedMemberId then
      animatedSelected = true
      break
    end
  end
  if not animatedSelected then
    Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "the follower-transition animated model is not selected", {
      effect = key,
      animatedModelMember = animatedMemberId,
    })
  end

  -- Decode both source models once: the animated member takes the clip, the
  -- companion compiles static.
  local decodedModels = {}
  for _, memberId in ipairs(source.modelMembers) do
    local modelBytes = member(narc, memberId)
    decodedModels[memberId] = {
      bytes = modelBytes,
      decoded = assert(Nsbmd.decode(modelBytes, {
        alias = "field_static_models",
        memberId = memberId,
        section = section,
      })),
    }
  end

  local meshes, textures = {}, {}
  local descriptors = {}
  local modelSha1s = {}
  for _, memberId in ipairs(source.modelMembers) do
    local modelBytes = decodedModels[memberId].bytes
    if memberId == animatedMemberId then
      local decodedModel = decodedModels[memberId].decoded
      local model = decodedModel.models[1]
      if not model or not decodedModel.embeddedTextures then
        Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "field-effect dynamic model is incomplete", {
          archive = "field_static_models",
          memberId = memberId,
        })
      end
      local descriptor, unresolved = DynamicModelCompiler.compile(
        model,
        decodedModel,
        decodedModel.embeddedTextures,
        { clips = { clip } },
        {
          role = role,
          modelArchive = "field_static_models",
          modelMemberId = memberId,
          modelName = model.name,
          textureArchive = "field_static_models",
          textureMemberId = memberId,
        },
        memberId,
        textures,
        meshes
      )
      if #unresolved > 0 then
        Errors.raise("FIELD_EFFECT_SOURCE_INVALID", "field-effect dynamic model has unresolved materials", {
          archive = "field_static_models",
          memberId = memberId,
          unresolved = unresolved,
        })
      end
      descriptor.key = key .. "-" .. model.name
      rewriteEffectPaths(descriptor)
      ModelAsset.validate(descriptor)
      descriptors[#descriptors + 1] = descriptor
      modelSha1s[#modelSha1s + 1] = Hashing.sha1hex(modelBytes)
    else
      local probe = assert(Nsbmd.decode(modelBytes, {
        alias = "field_static_models",
        memberId = memberId,
        section = section,
      }))
      local probeModel = probe.models[1]
      assert(probeModel, "field-effect companion model is missing")
      local descriptor, staticMeshes, staticTextures, sha =
        compileModel(narc, memberId, key .. "-" .. probeModel.name, section, role)
      for sha1, mesh in pairs(staticMeshes) do
        meshes[sha1] = mesh
      end
      for sha1, texture in pairs(staticTextures) do
        textures[sha1] = texture
      end
      descriptors[#descriptors + 1] = descriptor
      modelSha1s[#modelSha1s + 1] = sha
    end
  end
  local offsetX, offsetY, offsetZ =
    MapUnits.toTiles(source.placementOffset.x, source.placementOffset.y, source.placementOffset.z)
  return {
    models = descriptors,
    lifecycle = {
      mode = "once",
      frameCount = clip.frameCount,
      preludeTicks = preludeTicks,
    },
    placementOffset = { x = offsetX, y = offsetY, z = offsetZ },
  },
    meshes,
    textures,
    modelSha1s
end

function Compiler.compile(romFs, hashLua)
  assert(romFs and romFs.openNarc, "field-effect compiler requires RomFs")
  hashLua = hashLua or Hashing.hashLua
  local narc = assert(romFs:openNarc(FieldEffects.archive.alias))
  local animationNarc = assert(romFs:openNarc(FieldEffects.animationArchive.alias))
  local sourceHashesByKind = {}
  for kind, source in pairs(FieldEffects.effects) do
    sourceHashesByKind[kind] = {
      model = sourceHashes(narc, source.modelMembers, FieldEffects.archive.alias),
      animation = sourceHashes(animationNarc, source.animationMembers, FieldEffects.animationArchive.alias),
    }
  end
  local model, meshes, textures, warpSha = compileModel(
    narc,
    FieldEffects.effects.warp_entrance.modelMembers[1],
    "field-effect:warp-entrance",
    "warp-entrance-effect",
    "field-effect"
  )
  local tall, tallMeshes, tallTextures, tallSha = compileDynamicModel(
    narc,
    animationNarc,
    FieldEffects.animationArchive.alias,
    FieldEffects.effects.tall_grass.modelMembers[1],
    FieldEffects.effects.tall_grass.animationMembers[1],
    "field-effect:tall-grass",
    "tall-grass-renderer-8",
    "field-effect-grass",
    FieldEffects.effects.tall_grass
  )
  local veryTall, veryTallMeshes, veryTallTextures, veryTallSha = compileDynamicModel(
    narc,
    animationNarc,
    FieldEffects.animationArchive.alias,
    FieldEffects.effects.very_tall_grass.modelMembers[1],
    FieldEffects.effects.very_tall_grass.animationMembers[1],
    "field-effect:very-tall-grass",
    "tall-grass-renderer-12",
    "field-effect-grass",
    FieldEffects.effects.very_tall_grass
  )
  local trainerReveal, trainerRevealMeshes, trainerRevealTextures, trainerRevealSha = compileDynamicModel(
    narc,
    animationNarc,
    FieldEffects.animationArchive.alias,
    FieldEffects.effects.trainer_reveal.modelMembers[1],
    FieldEffects.effects.trainer_reveal.animationMembers[1],
    "field-effect:trainer-reveal",
    "trainer-reveal-effect",
    "field-effect-trainer",
    FieldEffects.effects.trainer_reveal
  )
  local surfSelection = assert(FieldEffects.effects.surf_attachment, "surf attachment source selection is required")
  local surfModel, surfMeshes, surfTextures, surfSha = compileModel(
    narc,
    surfSelection.modelMembers[1],
    "field-effect:surf-attachment",
    "surf-attachment-effect",
    "field-effect"
  )
  local transition, transitionMeshes, transitionTextures, transitionSha1s = compileTransitionEffect(
    narc,
    animationNarc,
    FieldEffects.animationArchive.alias,
    "follower-transition",
    "follower-transition-effect",
    "field-effect-transition",
    FieldEffects.effects.follower_transition
  )
  for sha1, mesh in pairs(tallMeshes) do
    meshes[sha1] = mesh
  end
  for sha1, texture in pairs(tallTextures) do
    textures[sha1] = texture
  end
  for sha1, mesh in pairs(veryTallMeshes) do
    meshes[sha1] = mesh
  end
  for sha1, texture in pairs(veryTallTextures) do
    textures[sha1] = texture
  end
  for sha1, mesh in pairs(trainerRevealMeshes) do
    meshes[sha1] = mesh
  end
  for sha1, texture in pairs(trainerRevealTextures) do
    textures[sha1] = texture
  end
  for sha1, mesh in pairs(surfMeshes) do
    meshes[sha1] = mesh
  end
  for sha1, texture in pairs(surfTextures) do
    textures[sha1] = texture
  end
  for sha1, mesh in pairs(transitionMeshes) do
    meshes[sha1] = mesh
  end
  for sha1, texture in pairs(transitionTextures) do
    textures[sha1] = texture
  end
  local surfPresentation = assert(surfSelection.presentation, "surf attachment presentation is required")
  local effects = {
    warp_entrance = {
      model = model,
      lifetime = 1,
    },
    tall_grass = {
      model = tall,
      lifecycle = {
        mode = FieldEffects.effects.tall_grass.lifecycle.mode,
        holdFrame = FieldEffects.effects.tall_grass.lifecycle.holdFrame,
      },
      placementOffset = FieldEffects.effects.tall_grass.placementOffset,
    },
    very_tall_grass = {
      model = veryTall,
      lifecycle = {
        mode = FieldEffects.effects.very_tall_grass.lifecycle.mode,
        holdFrame = FieldEffects.effects.very_tall_grass.lifecycle.holdFrame,
      },
      placementOffset = FieldEffects.effects.very_tall_grass.placementOffset,
    },
    trainer_reveal = {
      model = trainerReveal,
      lifecycle = {
        mode = FieldEffects.effects.trainer_reveal.lifecycle.mode,
        frameCount = FieldEffects.effects.trainer_reveal.lifecycle.frameCount,
      },
      placementOffset = FieldEffects.effects.trainer_reveal.placementOffset,
    },
    surf_attachment = {
      model = surfModel,
      presentation = {
        initialPlayerOffset = {
          x = surfPresentation.initialPlayerOffset.x,
          y = surfPresentation.initialPlayerOffset.y,
          z = surfPresentation.initialPlayerOffset.z,
        },
        oscillator = {
          initialY = surfPresentation.oscillator.initialY,
          minY = surfPresentation.oscillator.minY,
          maxY = surfPresentation.oscillator.maxY,
          stepY = surfPresentation.oscillator.stepY,
        },
        playerBaseOffset = {
          x = surfPresentation.playerBaseOffset.x,
          y = surfPresentation.playerBaseOffset.y,
          z = surfPresentation.playerBaseOffset.z,
        },
        attachmentBaseOffset = {
          x = surfPresentation.attachmentBaseOffset.x,
          y = surfPresentation.attachmentBaseOffset.y,
          z = surfPresentation.attachmentBaseOffset.z,
        },
        yawDegrees = {
          north = surfPresentation.yawDegrees.north,
          south = surfPresentation.yawDegrees.south,
          west = surfPresentation.yawDegrees.west,
          east = surfPresentation.yawDegrees.east,
        },
      },
    },
    follower_transition = transition,
  }
  local index = {
    schema = Contract.fieldEffects.indexSchema,
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
  local memberSha1 = { warpSha, tallSha, veryTallSha, trainerRevealSha, surfSha }
  for _, sha1 in ipairs(transitionSha1s) do
    memberSha1[#memberSha1 + 1] = sha1
  end
  local depHash = hashLua({
    memberSha1 = memberSha1,
    sourceHashes = sourceHashesByKind,
    index = index,
    effects = effects,
  })
  return {
    model = model,
    index = index,
    effects = effects,
    meshes = meshes,
    textures = textures,
    marker = FieldEffectAssetCache.marker(romFs:metadata().sha1, depHash),
  }
end

return Compiler
