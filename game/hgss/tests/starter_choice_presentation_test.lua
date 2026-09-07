-- Headless starter-presentation semantics: the presentation owns every source
-- clock (turntable rotation, camera/arc steps, rock wobble frame, sequential
-- surface fades) and reports transition-specific completion observations one
-- fixed tick at a time, without requiring GPU realization. Reads (yaw, ball
-- centers, camera matrices) never advance a clock; reset clears all progress.

local Assert = require("tests.support.Assert")

local T = {}

local PRESENTATION_MODULE = "game.hgss.src.starters.StarterChoicePresentation"
local CACHE_MODULE = "libs.assets.src.StarterChoiceAssetCache"
local MODEL_MODULE = "libs.assets.src.model.ModelAsset"

local function requirePresentation()
  local ok, presentation = pcall(require, PRESENTATION_MODULE)
  Assert.isTrue(ok, "the starter presentation owns the semantic playback clocks")
  return assert(presentation)
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

local function dynamicDescriptor(clipIds)
  local clips = {}
  for _, id in ipairs(clipIds) do
    clips[#clips + 1] = trsClip(id)
  end
  return {
    schema = assert(require(MODEL_MODULE)).SCHEMA,
    kind = "nitro-dynamic",
    dynamic = { nodes = {}, transformProgram = {}, batches = {} },
    materials = { dynamicMaterial() },
    animations = clips,
  }
end

local function staticDescriptor()
  return {
    schema = assert(require(MODEL_MODULE)).SCHEMA,
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

local function semanticManifest()
  local ball = dynamicDescriptor({ "ball-rock", "ball-open" })
  return {
    schema = assert(require(CACHE_MODULE)).SCHEMA,
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
        preparedMessage({ { 0x0200 } }),
        preparedMessage({ { 0x0201 } }),
        preparedMessage({ { 0x0202 } }),
      },
      confirm = {
        preparedMessage({ { 0x0300 } }),
        preparedMessage({ { 0x0301 } }),
        preparedMessage({ { 0x0302 } }),
      },
      bottom = {
        normal = preparedMessage({ { 0x0400 } }),
        confirm = preparedMessage({ { 0x0401 }, { 0x0402 } }),
      },
    },
    background = {
      image = "assets/generated/starter_choice/backdrop.png",
      width = 512,
      height = 192,
    },
  }
end

local function openPresentation()
  local Presentation = requirePresentation()
  local manifest = semanticManifest()
  Assert.isTrue(assert(require(CACHE_MODULE)).validateManifest(manifest), "the semantic fixture validates")
  local presentation = Presentation.new({
    manifest = manifest,
    cacheFs = {
      read = function()
        return nil
      end,
    },
    portraits = { { selector = "a" }, { selector = "b" }, { selector = "c" } },
  })
  presentation:reset()
  return presentation, manifest
end

local function snapshot(overrides)
  local base = {
    selection = 0,
    selectionState = "null",
    transition = "idle",
    direction = nil,
    progress = 0,
    ticks = 8,
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      base[key] = value
    end
  end
  return base
end

local function assertObservationShape(observation, what)
  Assert.notNil(observation, what .. " reports an observation every fixed tick")
  for _, field in ipairs({
    "rotationComplete",
    "cameraComplete",
    "ballArcComplete",
    "smallWobbleReady",
    "infoFadeComplete",
    "machineFadeComplete",
  }) do
    Assert.equal(type(observation[field]), "boolean", what .. " reports " .. field .. " as a boolean")
  end
end

function T.rotation_completes_from_source_step_and_rate_not_the_camera_window()
  local presentation, manifest = openPresentation()
  local turntable = manifest.scene.turntable
  local expected = turntable.selectionStepDegrees / turntable.rotationDegreesPerTick
  Assert.equal(expected, 240, "the source slot step spans 240 ticks at the source rate")
  Assert.isTrue(expected ~= manifest.scene.timing.cameraTicks, "rotation is not the camera window")

  local rotating = snapshot({ transition = "rotate", direction = "right" })
  local elapsed = 0
  local observation = nil
  while elapsed < 1024 do
    observation = presentation:update(rotating)
    assertObservationShape(observation, "rotation")
    elapsed = elapsed + 1
    if observation.rotationComplete then
      break
    end
  end
  Assert.equal(elapsed, expected, "rotation lasts exactly one source slot step")
  local again = presentation:update(rotating)
  Assert.isTrue(again.rotationComplete, "repeated snapshots never restart a settled rotation")
end

function T.zoom_waits_for_camera_arc_and_wobble_before_lock_fades()
  local presentation, manifest = openPresentation()
  local timing = manifest.scene.timing

  presentation:update(snapshot({ selectionState = "inspect" }))
  local zooming = snapshot({ selectionState = "inspect", transition = "zoomIn" })
  local observation = nil
  for tick = 1, timing.cameraTicks - 1 do
    observation = presentation:update(zooming)
    assertObservationShape(observation, "zoom-in")
    Assert.isFalse(observation.cameraComplete, "the camera is still travelling at tick " .. tick)
    Assert.isFalse(observation.ballArcComplete, "the ball arc is still travelling at tick " .. tick)
  end
  observation = presentation:update(zooming)
  Assert.isTrue(observation.cameraComplete, "the camera settles on its own eight-step clock")
  Assert.isTrue(observation.ballArcComplete, "the ball arc settles on its own eight-step clock")
  Assert.isFalse(observation.smallWobbleReady, "camera and arc alone never release the wobble gate")

  local waiting = snapshot({ selectionState = "inspect", transition = "waitZoom" })
  local wobbled = timing.cameraTicks + 1
  while not observation.smallWobbleReady and wobbled < timing.smallWobbleFrame + 64 do
    observation = presentation:update(waiting)
    wobbled = wobbled + 1
  end
  Assert.isTrue(observation.smallWobbleReady, "the rock reaches the small-wobble phase")
  Assert.isTrue(wobbled >= timing.smallWobbleFrame, "readiness needs the source frame count, not the camera window")

  local locking = snapshot({ selectionState = "confirm", transition = "lockExit" })
  local exitTicks = 0
  local infoDoneAt, machineDoneAt = nil, nil
  while exitTicks < timing.infoFadeTicks + timing.machineFadeTicks + 32 do
    observation = presentation:update(locking)
    assertObservationShape(observation, "lock exit")
    exitTicks = exitTicks + 1
    if observation.infoFadeComplete and infoDoneAt == nil then
      infoDoneAt = exitTicks
    end
    if observation.machineFadeComplete and machineDoneAt == nil then
      machineDoneAt = exitTicks
    end
    if observation.machineFadeComplete then
      break
    end
  end
  Assert.equal(infoDoneAt, timing.infoFadeTicks, "the info fade lasts exactly its source window")
  Assert.equal(
    machineDoneAt,
    timing.infoFadeTicks + timing.machineFadeTicks,
    "the machine fade follows the info fade before completing"
  )
end

function T.reads_never_advance_semantic_clocks()
  local presentation, manifest = openPresentation()
  local expected = manifest.scene.turntable.selectionStepDegrees / manifest.scene.turntable.rotationDegreesPerTick
  local rotating = snapshot({ transition = "rotate", direction = "right" })
  presentation:update(rotating)
  for _ = 1, 20 do
    presentation:yawForSnapshot(rotating)
    presentation:ballCenters(rotating)
    presentation:cameraMatrices(rotating)
  end
  local elapsed = 1
  while elapsed < 1024 do
    local observation = presentation:update(rotating)
    elapsed = elapsed + 1
    if observation.rotationComplete then
      break
    end
  end
  Assert.equal(elapsed, expected, "twenty interleaved reads cost zero rotation ticks")
end

function T.reset_clears_all_semantic_progress()
  local presentation, manifest = openPresentation()
  local timing = manifest.scene.timing
  local rotating = snapshot({ transition = "rotate", direction = "right" })
  for _ = 1, 100 do
    presentation:update(rotating)
  end
  presentation:reset()
  local elapsed = 0
  while elapsed < 1024 do
    local observation = presentation:update(rotating)
    elapsed = elapsed + 1
    if observation.rotationComplete then
      break
    end
  end
  Assert.equal(
    elapsed,
    manifest.scene.turntable.selectionStepDegrees / manifest.scene.turntable.rotationDegreesPerTick,
    "reopening restarts the full rotation"
  )

  local locking = snapshot({ selectionState = "confirm", transition = "lockExit" })
  for _ = 1, timing.infoFadeTicks + 5 do
    presentation:update(locking)
  end
  presentation:reset()
  local exitTicks = 0
  while exitTicks < timing.infoFadeTicks + timing.machineFadeTicks + 32 do
    local observation = presentation:update(locking)
    exitTicks = exitTicks + 1
    if observation.machineFadeComplete then
      break
    end
  end
  Assert.equal(
    exitTicks,
    timing.infoFadeTicks + timing.machineFadeTicks,
    "reopening restarts the full sequential fades"
  )
end

function T.static_tabletop_alpha_is_forwarded_without_a_second_normalization()
  local presentation = openPresentation()
  presentation._staticBatches = {
    {
      mesh = "mesh",
      material = {},
      center = { x = 0, y = 0, z = 0 },
      alphaClass = "opaque",
      cullMode = "back",
      polygonAlpha = 1.0,
      polygonMode = "modulation",
      polygonId = 0,
      translucentDepthWrite = false,
      depthEqual = false,
      lightMask = 0,
      fogEnabled = false,
    },
  }
  local function stubInstance()
    return {
      transform = nil,
      evaluatePose = function() end,
      drawItems = function()
        return {}
      end,
    }
  end
  presentation._instances = {
    turntable = stubInstance(),
    ballEffect = stubInstance(),
    ball1 = stubInstance(),
    ball2 = stubInstance(),
    ball3 = stubInstance(),
  }
  presentation._renderMeshes = {
    turntable = {},
    ballEffect = {},
    ball1 = {},
    ball2 = {},
    ball3 = {},
  }
  local items = presentation:_drawItems(snapshot({ transition = "idle", selectionState = "null", selection = 0 }))
  Assert.isTrue(#items >= 1, "prepared static batches reach the renderer")
  Assert.equal(
    items[1].polygonAlpha,
    presentation._staticBatches[1].polygonAlpha,
    "the prepared alpha is forwarded unchanged"
  )
  Assert.near(items[1].polygonAlpha, 1.0, 1e-9, "source alpha 31 reaches the renderer as 1.0")
end

return { tests = T }
