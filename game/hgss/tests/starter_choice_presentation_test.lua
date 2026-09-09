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

local function chooserTextColors()
  local variants = {}
  for index = 1, 7 do
    variants[index] = {
      foreground = { r = index * 10 + 1, g = index * 10 + 2, b = index * 10 + 3 },
      shadow = { r = index * 10 + 4, g = index * 10 + 5, b = index * 10 + 6 },
    }
  end
  return {
    variants = variants,
    infoBackground = { r = 16, g = 32, b = 48 },
    machineBackground = { r = 64, g = 80, b = 96 },
  }
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
    textColors = chooserTextColors(),
  }
end

local function openPresentation(frameIndex)
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
    frameIndex = frameIndex == nil and 3 or frameIndex,
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
  -- Pinned source derivation, never the manifest under test: one 120-degree
  -- slot step at 11.25 degrees per fixed update completes on update 11.
  Assert.equal(turntable.selectionStepDegrees, 120, "one slot step spans a third of the ring")
  Assert.near(turntable.rotationDegreesPerTick, 11.25, 1e-9, "the turntable rate matches the source rate")
  local expected = 11
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
  local presentation = openPresentation()
  -- One 120-degree slot step at the normalized 11.25-degree source rate
  -- completes on the eleventh fixed update.
  local expected = 11
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
  Assert.equal(elapsed, 11, "reopening restarts the full rotation")

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

function T.construction_carries_the_player_frame_choice()
  local presentation = openPresentation(5)
  Assert.equal(presentation._frameIndex, 5, "the presentation keeps the supplied frame index")

  local Presentation = requirePresentation()
  local manifest = semanticManifest()
  local ok = pcall(Presentation.new, {
    manifest = manifest,
    cacheFs = {
      read = function()
        return nil
      end,
    },
    portraits = { { selector = "a" }, { selector = "b" }, { selector = "c" } },
  })
  Assert.isFalse(ok, "a missing frame index fails instead of falling back to frame 0")
end

function T.camera_uses_normalized_clipping_planes()
  local presentation, manifest = openPresentation()
  local Matrix4 = assert(require("libs.math.src.Matrix4"))
  local _, projection = presentation:cameraMatrices(snapshot({ selection = 0 }))
  local camera = manifest.scene.camera
  Assert.equal(camera.near, 0.25, "the fixture carries the normalized near plane")
  Assert.equal(camera.far, 16, "the fixture carries the normalized far plane")
  local expected = Matrix4.perspective(math.rad(camera.out.perspective), 256 / 192, camera.near, camera.far)
  Assert.equal(#projection, #expected, "the camera projection carries every matrix element")
  for index = 1, #expected do
    Assert.near(
      projection[index],
      expected[index],
      1e-9,
      "projection element " .. index .. " uses the normalized planes"
    )
  end
  local stale = Matrix4.perspective(math.rad(camera.out.perspective), 256 / 192, 20, 250)
  local differs = false
  for index = 1, #expected do
    if math.abs(projection[index] - stale[index]) > 1e-9 then
      differs = true
    end
  end
  Assert.isTrue(differs, "the camera projection no longer uses the old local clipping range")
end

function T.focused_camera_uses_absolute_target_and_distinct_inspect_pivot()
  local presentation, manifest = openPresentation()
  local camera = assert(manifest.scene.camera, "the scene carries its camera poses")
  Assert.deepEqual(
    camera.out.target,
    { x = 0, y = 0.9375, z = 0.875 },
    "outside camera target keeps the fixed height at the outer depth"
  )
  Assert.deepEqual(
    camera.inside.target,
    { x = 0, y = 0.9375, z = 0.75 },
    "focused camera target keeps the fixed height at the inner depth"
  )
  local layout = assert(manifest.scene.ballLayout, "the scene carries its ball ring layout")
  Assert.equal(layout.touchYOffsetY, 0.8125, "touch centers keep the interaction offset")
  Assert.notNil(layout.inspectPivotYOffsetY, "the selected-ball arc carries its own pivot offset")
  Assert.near(layout.inspectPivotYOffsetY, 13.453 / 16, 1e-9, "the inspect pivot keeps the retail arc height")
  Assert.isTrue(layout.inspectPivotYOffsetY ~= layout.touchYOffsetY, "touch and inspect pivots stay distinct")
  local touches = presentation:touchOrigins(snapshot({ selection = 0 }))
  Assert.notNil(touches[1], "the first touch center projects")
  Assert.near(touches[1].y, layout.modelY + 0.8125, 1e-9, "touch projection uses the interaction offset only")

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
  local settled = snapshot({ selection = 0, selectionState = "inspect", transition = "waitZoom" })
  presentation:_drawItems(settled)
  local selectedTransform = assert(presentation._instances.ball1.transform, "the selected ball transform is realized")
  local arc = math.rad(layout.inspectArcDegrees)
  local pivotY = layout.modelY + 13.453 / 16
  local cosine, sine = math.cos(arc), math.sin(arc)
  local rise, reach = layout.modelY - pivotY, 0
  Assert.near(
    selectedTransform[14],
    rise * cosine - reach * sine + pivotY,
    1e-9,
    "the selected ball arcs around the inspect pivot, not the touch center"
  )
  Assert.near(
    selectedTransform[15],
    rise * sine + reach * cosine + layout.radius,
    1e-9,
    "the selected ball arc depth follows the inspect pivot"
  )
end

function T.turntable_slot_step_completes_on_the_eleventh_fixed_update()
  -- The retail turntable speed as normalized degrees per fixed update: the
  -- source binary-angle index 2048/65536 of a turn, pinned here independent
  -- of the manifest under test.
  local stepDegrees = 120
  local rateDegreesPerTick = 11.25
  local presentation, manifest = openPresentation()
  Assert.equal(manifest.scene.turntable.selectionStepDegrees, stepDegrees, "one slot step spans a third of the ring")
  Assert.near(
    manifest.scene.turntable.rotationDegreesPerTick,
    rateDegreesPerTick,
    1e-9,
    "the turntable rate matches the normalized source rate"
  )
  local forward = snapshot({ selection = 0, selectionState = "inspect", transition = "rotate", direction = "right" })
  local observation = nil
  for _ = 1, 10 do
    observation = presentation:update(forward)
    assertObservationShape(observation, "rotation")
  end
  Assert.notNil(observation, "ten rotation ticks report observations")
  Assert.isFalse(observation.rotationComplete, "the slot step is still travelling after ten fixed updates")
  Assert.near(
    math.abs(presentation:yawForSnapshot(forward)),
    math.rad(112.5),
    1e-9,
    "ten fixed updates reach 112.5 degrees"
  )
  observation = presentation:update(forward)
  Assert.isTrue(observation.rotationComplete, "the slot step completes on the eleventh fixed update")
  Assert.near(
    math.abs(presentation:yawForSnapshot(forward)),
    math.rad(120),
    1e-9,
    "completion clamps to exactly 120 degrees"
  )
  observation = presentation:update(forward)
  Assert.isTrue(observation.rotationComplete, "a settled rotation never overshoots its slot")
  Assert.near(
    math.abs(presentation:yawForSnapshot(forward)),
    math.rad(120),
    1e-9,
    "repeated ticks hold the clamped slot"
  )

  presentation:reset()
  local backward = snapshot({ selection = 0, selectionState = "inspect", transition = "rotate", direction = "left" })
  for _ = 1, 10 do
    observation = presentation:update(backward)
  end
  Assert.isFalse(observation.rotationComplete, "the reverse slot step is still travelling after ten fixed updates")
  observation = presentation:update(backward)
  Assert.isTrue(observation.rotationComplete, "the reverse slot step completes on the eleventh fixed update")
  Assert.near(
    math.abs(presentation:yawForSnapshot(backward)),
    math.rad(120),
    1e-9,
    "the reverse step clamps to exactly 120 degrees"
  )
end

-- Starter surfaces draw prepared lines through the generated chooser
-- colors: every line reaches the token-color-variant path with the manifest
-- variants, the machine prompt on the machine background, the framed info
-- message on the info background, and the framed fill uses the generated
-- info background instead of the generic font background.
function T.surface_messages_draw_through_the_generated_chooser_colors()
  local presentation, manifest = openPresentation()
  manifest.textColors = chooserTextColors()
  local variantCalls, lineCalls, windowCalls, fontBackgroundCalls = {}, {}, {}, {}
  local provider = {
    drawLine = function(_, line, x, y)
      lineCalls[#lineCalls + 1] = { line = line, x = x, y = y }
    end,
    drawLineWithColorVariants = function(_, line, x, y, variants, background)
      variantCalls[#variantCalls + 1] = { line = line, x = x, y = y, variants = variants, background = background }
    end,
    windowBackgroundColor = function()
      fontBackgroundCalls[#fontBackgroundCalls + 1] = true
      return { 0.11, 0.22, 0.33, 1 }
    end,
  }
  presentation._window = {
    drawWindow = function(_, box, frameIndex, fill)
      windowCalls[#windowCalls + 1] = { box = box, frameIndex = frameIndex, fill = fill }
    end,
  }
  local surfaces = manifest.surfaces
  presentation:_drawSurfaceMessage(
    presentation._machine,
    surfaces.machine.prompt,
    manifest.messages.bottom.normal,
    provider
  )
  presentation:_drawSurfaceMessage(presentation._info, surfaces.info.message, manifest.messages.topInitial, provider)

  Assert.equal(
    #lineCalls,
    0,
    "starter lines still route through the generic color bands instead of the chooser variants"
  )
  local promptLines = #manifest.messages.bottom.normal.lines
  local messageLines = #manifest.messages.topInitial.lines
  Assert.equal(#variantCalls, promptLines + messageLines, "every starter line draws through the chooser colors")
  for index, call in ipairs(variantCalls) do
    Assert.deepEqual(call.variants, manifest.textColors.variants, "line " .. index .. " carries the generated variants")
  end
  for index = 1, promptLines do
    Assert.deepEqual(
      variantCalls[index].background,
      manifest.textColors.machineBackground,
      "prompt line " .. index .. " uses the machine background"
    )
  end
  for index = promptLines + 1, #variantCalls do
    Assert.deepEqual(
      variantCalls[index].background,
      manifest.textColors.infoBackground,
      "info line " .. index .. " uses the info background"
    )
  end
  Assert.equal(variantCalls[1].x, surfaces.machine.prompt.textOrigin.x, "the prompt starts at the source origin")
  Assert.equal(variantCalls[1].y, surfaces.machine.prompt.textOrigin.y, "the prompt starts at the source origin")
  Assert.equal(
    variantCalls[promptLines + 1].x,
    surfaces.info.message.textOrigin.x,
    "the info message starts at the source origin"
  )
  Assert.equal(
    variantCalls[promptLines + 1].y,
    surfaces.info.message.textOrigin.y,
    "the info message starts at the source origin"
  )
  Assert.equal(#windowCalls, 1, "only the framed info message draws a window")
  Assert.deepEqual(windowCalls[1].box, surfaces.info.message.box, "the window covers the source message box")
  local info = manifest.textColors.infoBackground
  Assert.deepEqual(
    windowCalls[1].fill,
    { info.r / 255, info.g / 255, info.b / 255, 1 },
    "the framed fill is the generated info background"
  )
  Assert.equal(#fontBackgroundCalls, 0, "the generic font background never fills the chooser")
end

return { tests = T }
