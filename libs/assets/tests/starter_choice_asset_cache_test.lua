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

local function glyph(code, colorIndex)
  return { kind = "glyph", code = code, colorIndex = colorIndex or 0 }
end

local function preparedMessage(lineSpecs)
  local lines = {}
  for _, spec in ipairs(lineSpecs) do
    local line = {}
    for _, code in ipairs(spec) do
      line[#line + 1] = glyph(code)
    end
    lines[#lines + 1] = line
  end
  return { lines = lines }
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
      topInitial = preparedMessage({ { 0x0123, 0x0124 }, { 0x0125 } }),
      inspect = {
        preparedMessage({ { 0x0200, 0x0201 } }),
        preparedMessage({ { 0x0202, 0x0203 } }),
        preparedMessage({ { 0x0204, 0x0205 } }),
      },
      confirm = {
        preparedMessage({ { 0x0300, 0x0301 } }),
        preparedMessage({ { 0x0302, 0x0303 } }),
        preparedMessage({ { 0x0304, 0x0305 } }),
      },
      bottom = {
        normal = preparedMessage({ { 0x0400, 0x0401 } }),
        confirm = preparedMessage({ { 0x0402 }, { 0x0403 } }),
      },
    },
    background = {
      image = "assets/generated/starter_choice/backdrop.png",
      width = 512,
      height = 192,
    },
  }
end

local function validV3Manifest()
  local ball = dynamicDescriptor({ "ball-rock", "ball-open" })
  return {
    schema = "g4-starter-choice-v4",
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
        radius = 2,
        modelY = 0.875,
        touchYOffsetY = 0.8125,
        inspectPivotYOffsetY = 13.453 / 16,
        slotAnglesDegrees = { 0, 120, 240 },
        inspectArcDegrees = -30.76,
      },
      turntable = {
        selectionStepDegrees = 120,
        rotationDegreesPerTick = 11.25,
      },
      camera = {
        near = 0.25,
        far = 16,
        out = { angleX = -49.57, perspective = 49.61, target = { x = 0, y = 0.9375, z = 0.875 }, distance = 6.25 },
        inside = { angleX = -30.76, perspective = 45.4, target = { x = 0, y = 0.9375, z = 0.75 }, distance = 3.75 },
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
      topInitial = preparedMessage({ { 0x0123, 0x0124 }, { 0x0125 } }),
      inspect = {
        preparedMessage({ { 0x0200, 0x0201 } }),
        preparedMessage({ { 0x0202, 0x0203 } }),
        preparedMessage({ { 0x0204, 0x0205 } }),
      },
      confirm = {
        preparedMessage({ { 0x0300, 0x0301 } }),
        preparedMessage({ { 0x0302, 0x0303 } }),
        preparedMessage({ { 0x0304, 0x0305 } }),
      },
      bottom = {
        normal = preparedMessage({ { 0x0400, 0x0401 } }),
        confirm = preparedMessage({ { 0x0402 }, { 0x0403 } }),
      },
    },
    backgrounds = {
      host = {
        image = "assets/generated/starter_choice/backdrop.png",
        width = 512,
        height = 192,
      },
      info = {
        base = {
          image = "assets/generated/starter_choice/info-base.png",
          width = 256,
          height = 192,
        },
        overlay = {
          image = "assets/generated/starter_choice/info-overlay.png",
          width = 256,
          height = 192,
        },
        overlayAlpha = 5 / 16,
      },
    },
    surfaces = {
      machine = {
        clearColor = { r = 1, g = 1, b = 16 / 31, a = 1 },
        prompt = {
          box = { x = 8, y = 152, width = 232, height = 32 },
          textOrigin = { x = 8, y = 152 },
          framed = false,
        },
      },
      info = {
        message = {
          box = { x = 16, y = 152, width = 216, height = 32 },
          textOrigin = { x = 16, y = 152 },
          framed = true,
        },
        portrait = { x = 88, y = 56, width = 80, height = 80 },
      },
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
  local manifest = validV3Manifest()
  mutate(manifest)
  local ok, err = cache().validateManifest(manifest)
  Assert.isFalse(ok, label .. " must be rejected")
  Assert.equal(assert(err).code, "STARTER_CHOICE_MANIFEST_INVALID", label .. " has a typed error")
end

-- The previous raw-unit manifest shape is kept only as the stale fixture the
-- strict contract must refuse; all live validation uses the normalized shape.
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
    manifest.messages.inspect = { preparedMessage({ { 1 } }), preparedMessage({ { 2 } }) }
  end, "missing inspect description")
  reject(function(manifest)
    manifest.messages.confirm[2] = { lines = {} }
  end, "empty confirm description")
  reject(function(manifest)
    manifest.messages.bottom = { normal = preparedMessage({ { 1 } }) }
  end, "missing confirm prompt")
  reject(function(manifest)
    manifest.messages.topInitial = { lines = {} }
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
    manifest.backgrounds = nil
  end, "missing background records")
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
    manifest.messages.topInitial = { lines = { {} } }
  end, "empty initial top message")
  reject(function(manifest)
    manifest.messages.bottom.confirm = { lines = { {} } }
  end, "empty confirm prompt")
end

function T.bad_reference_paths_are_rejected()
  reject(function(manifest)
    manifest.backgrounds.host.image = "assets/generated/intro/backdrop.png"
  end, "backdrop outside the starter-choice subtree")
end

function T.source_archive_identities_are_rejected()
  reject(function(manifest)
    manifest.backgrounds.host.image = "assets/generated/starter_choice/NARC_application_choose.png"
  end, "source archive symbol in a backdrop path")
end

function T.malformed_prepared_messages_are_rejected()
  reject(function(manifest)
    manifest.messages.topInitial = "Professor Elm: Touch a Ball!"
  end, "string message leaf")
  reject(function(manifest)
    manifest.messages.bottom.normal = "Once you've decided, touch a Ball!"
  end, "string bottom prompt")
  reject(function(manifest)
    manifest.messages.topInitial = { lines = {} }
  end, "zero-line record")
  reject(function(manifest)
    manifest.messages.topInitial = {
      lines = { { glyph(1) }, { glyph(2) }, { glyph(3) } },
    }
  end, "three-line record")
  reject(function(manifest)
    local sparse = { glyph(1) }
    sparse[3] = glyph(2)
    manifest.messages.topInitial = { lines = sparse }
  end, "sparse lines")
  reject(function(manifest)
    manifest.messages.topInitial = { lines = { { glyph(1) }, {} } }
  end, "empty second line")
  reject(function(manifest)
    local sparse = { glyph(1) }
    sparse[3] = glyph(2)
    manifest.messages.topInitial = { lines = { sparse } }
  end, "sparse line")
  reject(function(manifest)
    manifest.messages.topInitial = { lines = { { { kind = "text", code = 1, colorIndex = 0 } } } }
  end, "non-glyph kind")
  reject(function(manifest)
    manifest.messages.topInitial = { lines = { { glyph(65536) } } }
  end, "glyph code above the field range")
  reject(function(manifest)
    manifest.messages.topInitial = { lines = { { { kind = "glyph", code = 1.5, colorIndex = 0 } } } }
  end, "fractional glyph code")
  reject(function(manifest)
    manifest.messages.topInitial = { lines = { { glyph(1, 7) } } }
  end, "color index above the palette range")
  reject(function(manifest)
    manifest.messages.topInitial = { lines = { { { kind = "glyph", code = 1, colorIndex = "0" } } } }
  end, "string color index")
  reject(function(manifest)
    manifest.messages.topInitial = { lines = { { glyph(1) } }, extra = true }
  end, "extra message field")
  reject(function(manifest)
    local line = { glyph(1) }
    line.extra = glyph(2)
    manifest.messages.topInitial = { lines = { line } }
  end, "extra line field")
  reject(function(manifest)
    local record = glyph(1)
    record.raw = { 1 }
    manifest.messages.topInitial = { lines = { { record } } }
  end, "extra glyph field")
end

local function readyCache()
  local module = cache()
  local manifest = validV3Manifest()
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

local function rejectV3(mutate, label)
  local manifest = validV3Manifest()
  mutate(manifest)
  local ok, err = cache().validateManifest(manifest)
  Assert.isFalse(ok, label .. " must be rejected")
  Assert.equal(assert(err).code, "STARTER_CHOICE_MANIFEST_INVALID", label .. " has a typed error")
end

function T.complete_normalized_manifest_is_accepted()
  local module = cache()
  Assert.equal(module.SCHEMA, "g4-starter-choice-v4")
  Assert.equal(module.SCHEMA, DerivedAssetContract.starterChoice.schema)
  Assert.equal(module.FORMAT, DerivedAssetContract.starterChoice.cacheFormat)
  Assert.isTrue(module.validateManifest(validV3Manifest()))
end

function T.previous_schema_manifests_are_rejected()
  rejectV3(function(manifest)
    manifest.schema = "g4-starter-choice-v2"
  end, "previous schema identity")
  rejectV3(function(manifest)
    manifest.background = {
      image = "assets/generated/starter_choice/backdrop.png",
      width = 512,
      height = 192,
    }
  end, "previous singular background alongside the normalized records")
  local legacy = validManifest()
  local ok, err = cache().validateManifest(legacy)
  Assert.isFalse(ok, "the previous raw-unit manifest must be rejected")
  Assert.equal(assert(err).code, "STARTER_CHOICE_MANIFEST_INVALID", "the previous manifest has a typed error")
end

function T.raw_model_space_scene_values_are_rejected()
  rejectV3(function(manifest)
    manifest.scene.ballLayout.radius = 32
  end, "raw ring radius")
  rejectV3(function(manifest)
    manifest.scene.ballLayout.modelY = 14
  end, "raw model height")
  rejectV3(function(manifest)
    manifest.scene.ballLayout.touchYOffsetY = 13
  end, "raw touch offset")
  rejectV3(function(manifest)
    manifest.scene.ballLayout.inspectPivotYOffsetY = 13.453
  end, "raw inspect pivot")
  rejectV3(function(manifest)
    manifest.scene.camera.out.target = { x = 0, y = 15, z = 14 }
  end, "raw outside target")
  rejectV3(function(manifest)
    manifest.scene.camera.out.distance = 100
  end, "raw outside distance")
  rejectV3(function(manifest)
    manifest.scene.camera.inside.target = { x = 0, y = 0, z = 12 }
  end, "raw inside target")
  rejectV3(function(manifest)
    manifest.scene.camera.inside.distance = 60
  end, "raw inside distance")
  rejectV3(function(manifest)
    manifest.scene.camera.near = nil
  end, "missing near clipping plane")
  rejectV3(function(manifest)
    manifest.scene.camera.far = nil
  end, "missing far clipping plane")
  rejectV3(function(manifest)
    manifest.scene.camera.near = 20
    manifest.scene.camera.far = 250
  end, "invented clipping planes")
end

function T.surface_pixel_geometry_is_never_model_scaled()
  rejectV3(function(manifest)
    manifest.surfaces.info.portrait = { x = 5.5, y = 3.5, width = 5, height = 5 }
  end, "model-scaled portrait rectangle")
  rejectV3(function(manifest)
    manifest.surfaces.machine.prompt.box = { x = 0.5, y = 9.5, width = 14.5, height = 2 }
  end, "model-scaled prompt box")
  rejectV3(function(manifest)
    manifest.surfaces.info.message.box = { x = 1, y = 9.5, width = 13.5, height = 2 }
  end, "model-scaled message box")
end

function T.surface_rectangles_origins_and_frame_policy_are_exact()
  rejectV3(function(manifest)
    manifest.surfaces.machine.prompt.box = { x = 16, y = 152, width = 216, height = 32 }
  end, "prompt box carrying the message geometry")
  rejectV3(function(manifest)
    manifest.surfaces.machine.prompt.framed = true
  end, "framed machine prompt")
  rejectV3(function(manifest)
    manifest.surfaces.machine.prompt.textOrigin = { x = 16, y = 152 }
  end, "prompt text origin carrying the message origin")
  rejectV3(function(manifest)
    manifest.surfaces.info.message.box = { x = 8, y = 152, width = 232, height = 32 }
  end, "message box carrying the prompt geometry")
  rejectV3(function(manifest)
    manifest.surfaces.info.message.framed = false
  end, "unframed info message")
  rejectV3(function(manifest)
    manifest.surfaces.info.portrait = { x = 88, y = 96, width = 80, height = 80 }
  end, "portrait at the wrong slot")
  rejectV3(function(manifest)
    manifest.surfaces = nil
  end, "missing surface records")
end

function T.machine_clear_color_is_the_source_rear_plane_color()
  local manifest = validV3Manifest()
  Assert.equal(manifest.surfaces.machine.clearColor.r, 1)
  Assert.equal(manifest.surfaces.machine.clearColor.g, 1)
  Assert.isTrue(math.abs(manifest.surfaces.machine.clearColor.b - 16 / 31) < 1e-9)
  Assert.equal(manifest.surfaces.machine.clearColor.a, 1)
  rejectV3(function(candidate)
    candidate.surfaces.machine.clearColor = { r = 0, g = 0, b = 0, a = 1 }
  end, "default black clear color")
  rejectV3(function(candidate)
    candidate.surfaces.machine.clearColor = { r = 1, g = 1, b = 1, a = 1 }
  end, "white clear color")
end

function T.info_background_roles_and_blend_are_exact()
  local manifest = validV3Manifest()
  Assert.equal(manifest.backgrounds.info.overlayAlpha, 5 / 16)
  rejectV3(function(candidate)
    candidate.backgrounds.info.overlayAlpha = 11 / 16
  end, "destination blend coefficient in the overlay role")
  rejectV3(function(candidate)
    candidate.backgrounds.info.base = nil
  end, "missing base layer")
  rejectV3(function(candidate)
    candidate.backgrounds.info.overlay = nil
  end, "missing overlay layer")
  rejectV3(function(candidate)
    candidate.backgrounds.info.base.width = 512
  end, "base layer at host dimensions")
  rejectV3(function(candidate)
    candidate.backgrounds.host = nil
  end, "missing host decoration")
end

function T.unknown_surface_fields_and_source_identities_are_rejected()
  rejectV3(function(manifest)
    manifest.surfaces.machine.extra = true
  end, "unknown machine surface field")
  rejectV3(function(manifest)
    manifest.surfaces.info.message.memberId = 11
  end, "source member identity in a surface record")
  rejectV3(function(manifest)
    manifest.backgrounds.info.base.image = "assets/generated/starter_choice/NARC_application.png"
  end, "source archive symbol in a background path")
  rejectV3(function(manifest)
    manifest.backgrounds = nil
  end, "missing background records")
end

function T.normalized_referenced_paths_cover_every_image()
  local module = cache()
  local manifest = validV3Manifest()
  local paths = module.referencedPaths(manifest)
  local seen = {}
  for _, path in ipairs(paths) do
    seen[path] = (seen[path] or 0) + 1
  end
  Assert.equal(seen["assets/generated/starter_choice/backdrop.png"], 1, "the host image is referenced exactly once")
  Assert.equal(seen["assets/generated/starter_choice/info-base.png"], 1, "the base image is referenced exactly once")
  Assert.equal(
    seen["assets/generated/starter_choice/info-overlay.png"],
    1,
    "the overlay image is referenced exactly once"
  )
end

function T.missing_normalized_images_are_not_ready()
  local module = cache()
  local manifest = validV3Manifest()
  local marker = module.marker("deadbeef", "feedface")
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  cacheFs:writeLua(module.manifestPath(), manifest)
  for _, path in ipairs(module.referencedPaths(manifest)) do
    cacheFs:write(path, "payload")
  end
  cacheFs:write(module.markerPath(), marker)
  Assert.isTrue(module.isReady(cacheFs, marker))
  cacheFs:remove("assets/generated/starter_choice/info-overlay.png")
  Assert.isFalse(module.isReady(cacheFs, marker), "a missing overlay image is not ready")
end

function T.unrelated_derived_families_keep_their_identities()
  Assert.equal(DerivedAssetContract.intro.cacheFormat, "intro-cache-v11")
  Assert.equal(DerivedAssetContract.mons.portraitManifestSchema, "g4-mon-portrait-manifest-v1")
end

function T.starter_contract_carries_the_inspect_pivot_and_rejects_the_previous_shape()
  local module = cache()
  local withoutPivot = validV3Manifest()
  withoutPivot.scene.ballLayout.inspectPivotYOffsetY = nil
  local ok, err = module.validateManifest(withoutPivot)
  Assert.isFalse(ok, "a manifest without the inspect pivot must be rejected")
  Assert.equal(assert(err).code, "STARTER_CHOICE_MANIFEST_INVALID", "the missing pivot has a typed error")
  Assert.equal(module.SCHEMA, "g4-starter-choice-v4", "the starter schema carries the current contract")
  Assert.equal(module.FORMAT, "starter-choice-cache-v4", "the starter cache format carries the current contract")
  Assert.equal(module.SCHEMA, DerivedAssetContract.starterChoice.schema, "the cache schema follows the shared contract")
  Assert.equal(
    module.FORMAT,
    DerivedAssetContract.starterChoice.cacheFormat,
    "the cache format follows the shared contract"
  )
  local current = validV3Manifest()
  current.schema = "g4-starter-choice-v4"
  current.scene.ballLayout.inspectPivotYOffsetY = 13.453 / 16
  Assert.isTrue(module.validateManifest(current), "the current pivot shape validates")
  reject(function(manifest)
    manifest.schema = "g4-starter-choice-v3"
  end, "previous schema identity")
end

return { tests = T }
