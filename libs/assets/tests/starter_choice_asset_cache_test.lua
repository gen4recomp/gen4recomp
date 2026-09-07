-- Contract scenarios for the generated choose-starter application class. The
-- fixtures model the public schema only; source archive/member identities
-- belong to the producer dependency record and are intentionally absent.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

local T = {}

local function dynamicMaterial()
  return {
    id = 0,
    name = "widget",
    baseColor = { r = 255, g = 255, b = 255, a = 255 },
    colors = {
      diffuse = { r = 255, g = 255, b = 255 },
      ambient = { r = 255, g = 255, b = 255 },
      specular = { r = 255, g = 255, b = 255 },
      emission = { r = 0, g = 0, b = 0 },
    },
    alphaMode = "opaque",
    polygonMode = "modulation",
    doubleSided = false,
    polygonAlpha = 31,
    texMtxMode = 0,
    texWidth = 64,
    texHeight = 64,
    wrap = { x = "clamp", y = "clamp" },
    flip = { x = false, y = false },
    diffuse = { r = 255, g = 255, b = 255, a = 255 },
  }
end

local function constantChannel()
  return { source = "constant", value = 0 }
end

local function trsClip(id)
  return {
    id = id,
    name = id,
    category = "joint",
    kind = "trs",
    frameCount = 4,
    tracks = { { target = 0, targetIndex = 0 } },
    semanticNames = {},
    compiled = {
      anmFlags = 0,
      rotData = {},
      pivotData = { { 0, 0, 0, 0, 0 } },
      targets = {
        {
          nodeIndex = 0,
          channels = {
            trans = { x = constantChannel(), y = constantChannel(), z = constantChannel() },
            rot = constantChannel(),
            scale = { x = constantChannel(), y = constantChannel(), z = constantChannel() },
          },
        },
      },
    },
  }
end

local function dynamicDescriptor(clipIds)
  local clips = {}
  for _, id in ipairs(clipIds) do
    clips[#clips + 1] = trsClip(id)
  end
  return {
    schema = ModelAsset.SCHEMA,
    kind = "nitro-dynamic",
    dynamic = { nodes = {}, transformProgram = {}, batches = {} },
    materials = { dynamicMaterial() },
    animations = clips,
  }
end

local function staticDescriptor()
  return {
    schema = ModelAsset.SCHEMA,
    kind = "static",
    batches = {},
    materials = {},
  }
end

local function validManifest()
  local ball = dynamicDescriptor({ "ball-rock", "ball-open" })
  return {
    schema = "g4-starter-choice-v2",
    reference = { width = 256, height = 192 },
    models = {
      tabletop = staticDescriptor(),
      turntable = dynamicDescriptor({ "turntable" }),
      ballEffect = dynamicDescriptor({ "ball-effect" }),
      ball1 = ball,
      ball2 = dynamicDescriptor({ "ball-rock", "ball-open" }),
      ball3 = dynamicDescriptor({ "ball-rock", "ball-open" }),
    },
    animations = {
      ballRock = { "ball-rock", "ball-rock", "ball-rock" },
      ballOpen = "ball-open",
      ballEffect = "ball-effect",
      turntable = "turntable",
    },
    scene = {
      ballLayout = {
        radius = 32,
        modelY = 14,
        touchYOffsetY = 13,
        slotAnglesDegrees = { 0, 120, 240 },
        inspectArcDegrees = -30.76,
      },
      turntable = {
        selectionStepDegrees = 120,
        rotationDegreesPerTick = 0.5,
      },
      camera = {
        out = { angleX = -49.57, perspective = 49.61, target = { x = 0, y = 15, z = 14 }, distance = 100 },
        inside = { angleX = -30.76, perspective = 45.4, target = { x = 0, y = 0, z = 12 }, distance = 60 },
      },
      timing = {
        cameraTicks = 8,
        ballArcTicks = 8,
        smallWobbleFrame = 80,
        infoFadeTicks = 10,
        machineFadeTicks = 16,
      },
    },
    messages = {
      topInitial = "Professor Elm: Touch a Poké Ball to see what Pokémon is inside!",
      inspect = { "inspect one", "inspect two", "inspect three" },
      confirm = { "confirm one", "confirm two", "confirm three" },
      bottom = {
        normal = "Once you've decided, touch a Poké Ball!",
        confirm = "Is this Pokémon good?",
      },
    },
    background = {
      image = "assets/generated/starter_choice/backdrop.png",
      width = 512,
      height = 192,
    },
  }
end

local function cache()
  local ok, module = pcall(require, "libs.assets.src.StarterChoiceAssetCache")
  if not ok then
    error("the starter-choice cache contract is missing: " .. tostring(module), 0)
  end
  return module
end

local function reject(mutate, label)
  local manifest = validManifest()
  mutate(manifest)
  local ok, err = cache().validateManifest(manifest)
  Assert.isFalse(ok, label .. " must be rejected")
  Assert.equal(assert(err).code, "STARTER_CHOICE_MANIFEST_INVALID", label .. " has a typed error")
end

function T.complete_manifest_is_accepted_under_the_contract_schema()
  local module = cache()
  Assert.equal(module.SCHEMA, "g4-starter-choice-v2")
  Assert.equal(module.SCHEMA, DerivedAssetContract.starterChoice.schema)
  Assert.equal(module.FORMAT, DerivedAssetContract.starterChoice.cacheFormat)
  Assert.isTrue(module.validateManifest(validManifest()))
end

function T.missing_model_roles_are_rejected()
  for _, role in ipairs({ "tabletop", "turntable", "ballEffect", "ball1", "ball2", "ball3" }) do
    reject(function(manifest)
      manifest.models[role] = nil
    end, "missing model role " .. role)
  end
end

function T.unknown_model_roles_are_rejected()
  reject(function(manifest)
    manifest.models.extra = staticDescriptor()
  end, "unknown model role")
end

function T.invalid_model_descriptors_are_rejected()
  reject(function(manifest)
    manifest.models.ball1.kind = "billboard"
  end, "invalid model descriptor")
end

function T.malformed_camera_blocks_are_rejected()
  reject(function(manifest)
    manifest.scene.camera.transitionTicks = 8
  end, "universal transition duration on the camera")
  reject(function(manifest)
    manifest.scene.camera.out.target = { x = 0, y = 0, z = 13 }
  end, "wrong outside target")
  reject(function(manifest)
    manifest.scene.camera.inside.distance = 61
  end, "wrong inside distance")
  reject(function(manifest)
    manifest.scene.camera.out.angleX = "steep"
  end, "non-numeric camera angle")
  reject(function(manifest)
    manifest.scene.camera = nil
  end, "missing camera block")
end

function T.legacy_schema_fields_are_rejected()
  reject(function(manifest)
    manifest.speciesSprites = {
      chikorita = { image = "assets/generated/starter_choice/chikorita.png", width = 32, height = 32 },
    }
  end, "fixed species image catalog")
  reject(function(manifest)
    manifest.scene.ballPositions = { { x = 0, y = 0, z = 0 } }
  end, "linear ball positions")
  reject(function(manifest)
    manifest.scene.ballYRotation = { out = 0, inside = 180 }
  end, "misleading rotation pair")
  reject(function(manifest)
    manifest.scene.wobble = { frameCount = 4 }
  end, "legacy wobble block")
  reject(function(manifest)
    manifest.messages.initial = "legacy"
  end, "legacy single initial field")
end

function T.incomplete_message_roles_are_rejected()
  reject(function(manifest)
    manifest.messages.inspect = { "one", "two" }
  end, "missing inspect description")
  reject(function(manifest)
    manifest.messages.confirm[2] = ""
  end, "empty confirm description")
  reject(function(manifest)
    manifest.messages.bottom = { normal = "prompt" }
  end, "missing confirm prompt")
  reject(function(manifest)
    manifest.messages.topInitial = ""
  end, "empty initial top message")
end

function T.incomplete_scene_facts_are_rejected()
  reject(function(manifest)
    manifest.scene.ballLayout = nil
  end, "missing ball layout")
  reject(function(manifest)
    manifest.scene.ballLayout.radius = 16
  end, "wrong ring radius")
  reject(function(manifest)
    manifest.scene.timing = nil
  end, "missing timing")
  reject(function(manifest)
    manifest.scene.timing.machineFadeTicks = 8
  end, "wrong machine fade boundary")
  reject(function(manifest)
    manifest.background = nil
  end, "missing owned backdrop")
end

function T.missing_animation_bindings_are_rejected()
  reject(function(manifest)
    manifest.animations.ballOpen = "no-such-clip"
  end, "unresolvable ball open binding")
  reject(function(manifest)
    manifest.animations.ballRock[2] = "no-such-clip"
  end, "unresolvable ball rock binding")
  reject(function(manifest)
    manifest.animations.turntable = "no-such-clip"
  end, "unresolvable turntable binding")
  reject(function(manifest)
    manifest.animations.ballEffect = "no-such-clip"
  end, "unresolvable effect binding")
end

function T.empty_messages_are_rejected()
  reject(function(manifest)
    manifest.messages.topInitial = ""
  end, "empty initial top message")
  reject(function(manifest)
    manifest.messages.bottom.confirm = ""
  end, "empty confirm prompt")
end

function T.bad_reference_paths_are_rejected()
  reject(function(manifest)
    manifest.background.image = "assets/generated/intro/backdrop.png"
  end, "backdrop outside the starter-choice subtree")
end

function T.source_archive_identities_are_rejected()
  reject(function(manifest)
    manifest.messages.topInitial = "see NARC_application_choose for details"
  end, "source archive symbol in a message")
end

local function readyCache()
  local module = cache()
  local manifest = validManifest()
  local marker = module.marker("deadbeef", "feedface")
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  cacheFs:writeLua(module.manifestPath(), manifest)
  for _, path in ipairs(module.referencedPaths(manifest)) do
    cacheFs:write(path, "payload")
  end
  cacheFs:write(module.markerPath(), marker)
  return cacheFs, marker
end

function T.complete_publication_reads_ready()
  local module = cache()
  local cacheFs, marker = readyCache()
  Assert.isTrue(module.isReady(cacheFs, marker))
end

function T.stale_markers_are_not_ready()
  local module = cache()
  local cacheFs, _ = readyCache()
  Assert.isFalse(module.isReady(cacheFs, "stale-marker"))
end

function T.missing_referenced_files_are_not_ready()
  local module = cache()
  local cacheFs, marker = readyCache()
  cacheFs:remove("assets/generated/starter_choice/backdrop.png")
  Assert.isFalse(module.isReady(cacheFs, marker))
end

function T.missing_manifests_are_not_ready()
  local module = cache()
  local cacheFs, marker = readyCache()
  cacheFs:remove(module.manifestPath())
  Assert.isFalse(module.isReady(cacheFs, marker))
end

return { tests = T }
