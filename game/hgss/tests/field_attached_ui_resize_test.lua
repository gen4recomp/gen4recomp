-- Resize coupling: UI scale follows the field pixel-scale controller, not host
-- height proportion.

local Assert = require("tests.support.Assert")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local FieldPixelScale = require("libs.hgss.src.presentation.FieldPixelScale")
local FieldPresentation = require("data.manifests.field_presentation")
local FieldState = require("game.hgss.src.field.FieldState")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local PixelScale = require("libs.ui.src.PixelScale")

local T = {}

---@class ResizeTestRuntime
---@field resizeCalls integer?
---@field lastResize table?
---@field rendererObservations table?

local function drawState(topologyProvider, pollTopology)
  topologyProvider = topologyProvider
    or function(width, height)
      return ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = width, height = height },
        touch = false,
        role = "world",
      })
    end
  ---@type ResizeTestRuntime
  local runtime = {
    session = {
      renderAlpha = function()
        return 0
      end,
    },
    destinationWorldPresentable = function()
      return true
    end,
    acknowledgeDestinationPresentation = function() end,
    runtimeMap = { sceneRuntime = {} },
    camera = { zoom = 1 },
    viewport = {
      width = 800,
      height = 600,
      worldViewport = {},
      referenceFrame = { height = 600 },
      fieldPixelScale = FieldPixelScale.new(FieldPresentation.fieldScale),
    },
    fieldPixelScale = FieldPixelScale.new(FieldPresentation.fieldScale),
    applicationHost = {
      status = function()
        return { fadeAlpha = 0 }
      end,
    },
    transition = { fadeAlpha = 0 },
    dialogue = {
      isModal = function()
        return false
      end,
    },
    signpost = {
      isModal = function()
        return false
      end,
    },
    menuHost = {
      presentation = function()
        return nil
      end,
    },
    resizePresentation = function(self, width, height, topology)
      self.resizeCalls = (self.resizeCalls or 0) + 1
      self.lastResize = { width, height, topology }
      self.viewport.width = width
      self.viewport.height = height
    end,
  }
  local rendererObservations = {}
  local state = setmetatable({
    runtime = runtime,
    topologyProvider = topologyProvider,
    _pollPresentationTopology = pollTopology == true,
    presentationResources = {
      renderer = {
        draw = function(_, _, _, _, _, viewport)
          rendererObservations[#rendererObservations + 1] = {
            width = viewport.width,
            height = viewport.height,
            resizeCalls = runtime.resizeCalls or 0,
          }
        end,
      },
    },
    actorPresentation = {
      drawItems = function()
        return {}
      end,
      records = function()
        return {}
      end,
    },
    worldParts = {},
    worldActorItems = {},
    spriteItems = {},
  }, FieldState)
  state._worldParts = function()
    return state.worldParts
  end
  runtime.rendererObservations = rendererObservations
  return state, runtime
end

local function oneDisplay(width, height, safeRect)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    safeRect = safeRect,
    touch = false,
    role = "world",
  })
end

function T.missed_resize_is_reconciled_before_renderer_and_restored_once()
  local topologyCalls = 0
  local state, runtime = drawState(function(width, height)
    topologyCalls = topologyCalls + 1
    return ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = width, height = height },
      touch = false,
      role = "world",
    })
  end, true)
  local originalGetDimensions = love.graphics.getDimensions
  local dimensions = { width = 1600, height = 900 }
  rawset(love.graphics, "getDimensions", function()
    return dimensions.width, dimensions.height
  end)
  local ok, err = pcall(function()
    state:draw()
  end)
  Assert.isTrue(ok, "missed grow resize should be repaired: " .. tostring(err))
  Assert.equal(runtime.resizeCalls, 1)
  Assert.equal(runtime.lastResize[1], 1600)
  Assert.equal(runtime.lastResize[2], 900)
  Assert.deepEqual(runtime.rendererObservations, {
    { width = 1600, height = 900, resizeCalls = 1 },
  })
  Assert.equal(topologyCalls, 1)

  dimensions.width, dimensions.height = 800, 600
  ok, err = pcall(function()
    state:draw()
  end)
  love.graphics.getDimensions = originalGetDimensions
  Assert.isTrue(ok, "missed restore resize should be repaired: " .. tostring(err))
  Assert.equal(runtime.resizeCalls, 2)
  Assert.equal(runtime.lastResize[1], 800)
  Assert.equal(runtime.lastResize[2], 600)
  Assert.deepEqual(runtime.rendererObservations[2], {
    width = 800,
    height = 600,
    resizeCalls = 2,
  })
  Assert.equal(topologyCalls, 2)
end

function T.resize_event_applies_presentation_geometry_once_before_an_unchanged_draw()
  local topology = oneDisplay(1280, 720)
  local state, runtime = drawState(function()
    return topology
  end)
  state:resize(1280, 720)
  Assert.equal(runtime.resizeCalls, 1)
  Assert.deepEqual(runtime.lastResize, { 1280, 720, topology })

  local originalGetDimensions = love.graphics.getDimensions
  rawset(love.graphics, "getDimensions", function()
    return 1280, 720
  end)
  local ok, err = pcall(function()
    state:draw()
    state:draw()
  end)
  rawset(love.graphics, "getDimensions", originalGetDimensions)
  Assert.isTrue(ok, "unchanged draw must use the event-synchronized geometry: " .. tostring(err))
  Assert.equal(runtime.resizeCalls, 1)
  Assert.deepEqual(runtime.rendererObservations, {
    { width = 1280, height = 720, resizeCalls = 1 },
    { width = 1280, height = 720, resizeCalls = 1 },
  })
end

function T.injected_topology_provider_publishes_one_same_size_structural_change()
  local current = oneDisplay(1280, 720, { x = 0, y = 0, width = 1280, height = 700 })
  local state, runtime = drawState(function()
    return current
  end, true)
  state._lastGeometrySignature = state:_geometrySignature(1280, 720, current)
  current = oneDisplay(1280, 720, { x = 0, y = 20, width = 1280, height = 700 })

  local originalGetDimensions = love.graphics.getDimensions
  rawset(love.graphics, "getDimensions", function()
    return 1280, 720
  end)
  local ok, err = pcall(function()
    state:draw()
    state:draw()
  end)
  rawset(love.graphics, "getDimensions", originalGetDimensions)
  Assert.isTrue(ok, "injected topology polling must remain supported: " .. tostring(err))
  Assert.equal(runtime.resizeCalls, 1)
  Assert.deepEqual(runtime.lastResize, { 1280, 720, current })
end

local function effectiveScaleAtHeight(height)
  local viewport = FieldViewport.new(1280, height, { mode = "expanded" })
  local scale = FieldPixelScale.new(FieldPresentation.fieldScale)
  scale:resize(viewport.referenceFrame.height)
  return scale:resolvedScale(), scale:cameraZoom(), viewport
end

function T.field_scale_preserves_the_resize_curve_and_camera_projection()
  local scaleA, zoomA = effectiveScaleAtHeight(600)
  local scaleB, zoomB = effectiveScaleAtHeight(720)
  -- With resizeCompensation 0.7, zoom changes with height
  Assert.isTrue(zoomA ~= zoomB, "resize must change effective zoom per field_presentation.lua")
  Assert.equal(scaleA % 1, 0, "the resolved scale at the reference height is integral")
  Assert.equal(scaleB % 1, 0, "the resolved scale after resize is integral")
  Assert.near(scaleA, (600 / 192) * zoomA, 1e-9)
  Assert.near(scaleB, (720 / 192) * zoomB, 1e-9)
end

-- Field dialogue shares one resolved presentation contract with Oak: the host
-- supplies real bounds plus the resolved field pixel scale as a cap, and the
-- renderer draws exactly the resulting presentation. The signpost keeps its
-- existing exact-scale contract.
local function fieldStateWithCapturedUi(worldViewport, cameraZoom, viewportWidth, viewportHeight)
  viewportWidth = viewportWidth or 1280
  viewportHeight = viewportHeight or 600
  local viewport = FieldViewport.new(viewportWidth, viewportHeight, { mode = "expanded" })
  local scale = FieldPixelScale.new(FieldPresentation.fieldScale)
  scale:resize(viewport.referenceFrame.height)
  local fieldScale = scale:resolvedScale()
  viewport.worldViewport = {
    x = worldViewport.x,
    y = worldViewport.y,
    width = worldViewport.width,
    height = worldViewport.height,
  }
  local fakeRuntimeMap = {
    mapId = 1,
    mapSymbol = "MAP_FAKE",
    sceneRuntime = { mapDraws = {}, staticBuildingDraws = {}, animatedBuildingDraws = {} },
  }
  local state = setmetatable({
    runtime = {
      viewport = viewport,
      fieldPixelScale = scale,
      uiManifest = FieldUiFixture.manifest(),
      camera = { zoom = cameraZoom },
      runtimeMap = fakeRuntimeMap,
      player = { fieldX = 0, fieldZ = 0, worldY = 0, surfaceId = 0, facing = "south", motion = "idle" },
      playerVisual = {
        drawRecord = function()
          return { visible = false }
        end,
      },
      actors = {
        drawRecords = function()
          return {}
        end,
      },
      dialogue = {
        isModal = function()
          return true
        end,
      },
      scripts = {
        dialogueHost = {
          yesNoPresentation = function()
            return nil
          end,
        },
      },
      signpost = {
        isModal = function()
          return true
        end,
      },
      session = {
        renderAlpha = function()
          return 0
        end,
      },
      destinationWorldPresentable = function()
        return true
      end,
      acknowledgeDestinationPresentation = function() end,
      applicationHost = {
        status = function()
          return { fadeAlpha = 0 }
        end,
      },
      transition = { fadeAlpha = 0 },
      menuHost = {
        presentation = function()
          return nil
        end,
      },
      resizePresentation = function() end,
    },
    topologyProvider = function()
      return ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = viewportWidth, height = viewportHeight },
        touch = false,
        role = "world",
      })
    end,
    presentationResources = { renderer = { draw = function() end } },
    actorPresentation = {
      drawItems = function()
        return {}
      end,
      records = function()
        return {}
      end,
    },
    worldParts = {},
    worldActorItems = {},
    spriteItems = {},
    _lastGeometrySignature = string.format(
      "%d:%d:main:world:0:0:%d:%d",
      viewportWidth,
      viewportHeight,
      viewportWidth,
      viewportHeight
    ),
  }, FieldState)
  state._worldParts = function()
    return {}
  end
  local dialogueCalls = {}
  state.presentationResources.dialogueRenderer = {
    draw = function(_, a, b, c, d)
      dialogueCalls[#dialogueCalls + 1] = { controller = a, second = b, third = c, fourth = d }
    end,
  } --[[@as any]]
  local signpostScales = {}
  local presentationResources = state.presentationResources --[[@as any]]
  presentationResources.signpostRenderer = {
    draw = function(_, _, _, alphaOrScale, maybeScale)
      if type(maybeScale) == "number" then
        signpostScales[#signpostScales + 1] = maybeScale
      elseif type(alphaOrScale) == "number" and alphaOrScale ~= 0 then
        signpostScales[#signpostScales + 1] = alphaOrScale
      end
    end,
  }
  local oldGetDimensions = love.graphics.getDimensions
  rawset(love.graphics, "getDimensions", function()
    return viewportWidth, viewportHeight
  end)
  local FieldDrawState = require("libs.hgss.src.presentation.FieldDrawState")
  local savedProtected = FieldDrawState.protectedDraw
  FieldDrawState.protectedDraw = function(_, fn)
    fn()
  end
  local ok, err = pcall(function()
    state:draw()
  end)
  FieldDrawState.protectedDraw = savedProtected
  love.graphics.getDimensions = oldGetDimensions
  Assert.isTrue(ok, "FieldState draw should not throw: " .. tostring(err))
  return fieldScale, dialogueCalls, signpostScales
end

local function assertOuterRectInsideBounds(outerRect, bounds)
  Assert.isTrue(outerRect.x >= bounds.x - 1e-9, "dialogue stays inside the real host horizontally")
  Assert.isTrue(
    outerRect.x + outerRect.width <= bounds.x + bounds.width + 1e-9,
    "dialogue stays inside the real host horizontally"
  )
  Assert.isTrue(outerRect.y >= bounds.y - 1e-9, "dialogue stays inside the real host vertically")
  Assert.isTrue(
    outerRect.y + outerRect.height <= bounds.y + bounds.height + 1e-9,
    "dialogue stays inside the real host vertically"
  )
end

function T.constrained_dialogue_shrinks_to_fit_the_real_world_viewport()
  local realBounds = { x = 5, y = 7, width = 256, height = 48 }
  local fieldScale, dialogueCalls, signpostScales = fieldStateWithCapturedUi(realBounds, 1.25)
  Assert.equal(#dialogueCalls, 1, "field dialogue draws once per frame")
  local call = dialogueCalls[1]
  Assert.isNil(call.third, "dialogue renders from one resolved presentation, not viewport plus scale")
  Assert.isNil(call.fourth, "dialogue renders from one resolved presentation, not a four-argument call")
  local presentation = call.second
  Assert.deepEqual(
    presentation.bounds,
    realBounds,
    "field passes its real bounds unchanged: no inflated stand-in width or height"
  )
  local expectedScale = PixelScale.fitPreferred(realBounds, 256, 48, fieldScale)
  Assert.isTrue(expectedScale < fieldScale, "the fixture host must be too small for the field scale")
  Assert.equal(expectedScale % 1, 0, "a constrained dialogue must use an integer scale")
  Assert.near(presentation.scale, expectedScale, 1e-9)
  Assert.near(presentation.outerRect.width, 256 * expectedScale, 1e-9)
  Assert.near(presentation.outerRect.height, 48 * expectedScale, 1e-9)
  assertOuterRectInsideBounds(presentation.outerRect, realBounds)
  Assert.near(
    presentation.outerRect.x,
    realBounds.x + (realBounds.width - 256 * expectedScale) / 2,
    1e-9,
    "the shrunken dialogue stays horizontally centered"
  )
  Assert.near(
    presentation.outerRect.y,
    realBounds.y + realBounds.height - 48 * expectedScale,
    1e-9,
    "the shrunken dialogue stays bottom-aligned"
  )
  Assert.equal(#signpostScales, 1, "the signpost still draws in the same frame")
  local expectedSignpostScale = PixelScale.fitPreferred(realBounds, 256, 192, fieldScale)
  Assert.equal(signpostScales[1], expectedSignpostScale, "the signpost uses its own integer fit")
end

function T.dialogue_and_signpost_fit_the_640_by_480_field_view()
  local fieldScale, dialogueCalls, signpostScales =
    fieldStateWithCapturedUi({ x = 0, y = 0, width = 640, height = 480 }, 0.25, 640, 480)
  local dialogue = dialogueCalls[1].second
  local expectedDialogueScale = PixelScale.fitPreferred(dialogue.bounds, 256, 48, fieldScale)
  local expectedSignpostScale =
    PixelScale.fitPreferred({ x = 0, y = 0, width = 640, height = 480 }, 256, 192, fieldScale)
  Assert.equal(expectedDialogueScale, 2, "the 640x480 dialogue uses the greatest fitting integer")
  Assert.equal(expectedSignpostScale, 2, "the 640x480 signpost uses the greatest fitting integer")
  Assert.equal(dialogue.scale, expectedDialogueScale, "FieldState publishes the fitted dialogue scale")
  Assert.equal(signpostScales[1], expectedSignpostScale, "FieldState publishes the fitted signpost scale")
  Assert.equal(dialogue.scale % 1, 0, "the dialogue scale is integral")
  Assert.equal(signpostScales[1] % 1, 0, "the signpost scale is integral")
end

function T.roomy_dialogue_keeps_the_field_scale_bottom_centered()
  local viewport = FieldViewport.new(1280, 600, { mode = "expanded" })
  local realBounds = {
    x = viewport.worldViewport.x,
    y = viewport.worldViewport.y,
    width = viewport.worldViewport.width,
    height = viewport.worldViewport.height,
  }
  local fieldScale, dialogueCalls, signpostScales = fieldStateWithCapturedUi(realBounds, 1.25)
  Assert.equal(#dialogueCalls, 1, "field dialogue draws once per frame")
  local call = dialogueCalls[1]
  Assert.isNil(call.third, "dialogue renders from one resolved presentation, not viewport plus scale")
  Assert.isNil(call.fourth, "dialogue renders from one resolved presentation, not a four-argument call")
  local presentation = call.second
  Assert.deepEqual(presentation.bounds, realBounds, "field passes its real bounds unchanged")
  Assert.near(presentation.scale, PixelScale.fitPreferred(realBounds, 256, 48, fieldScale), 1e-9)
  assertOuterRectInsideBounds(presentation.outerRect, realBounds)
  Assert.near(
    presentation.outerRect.x,
    realBounds.x + (realBounds.width - 256 * fieldScale) / 2,
    1e-9,
    "dialogue stays horizontally centered"
  )
  Assert.near(
    presentation.outerRect.y,
    realBounds.y + realBounds.height - 48 * fieldScale,
    1e-9,
    "dialogue stays bottom-aligned"
  )
  Assert.equal(#signpostScales, 1, "the signpost still draws in the same frame")
  Assert.equal(signpostScales[1], PixelScale.fitPreferred(realBounds, 256, 192, fieldScale))
end

function T.undersized_dialogue_width_keeps_one_x_and_exposes_only_the_overflow()
  local bounds = { x = 0, y = 0, width = 255, height = 48 }
  local _, dialogueCalls = fieldStateWithCapturedUi(bounds, 1.25)
  Assert.equal(#dialogueCalls, 1, "field dialogue draws once at the undersized width")

  local presentation = dialogueCalls[1].second
  Assert.equal(presentation.scale, 1, "the minimum presentation scale remains integer 1")
  Assert.deepEqual(presentation.bounds, bounds, "field passes the real undersized bounds")
  Assert.deepEqual(presentation.outerRect, { x = 0, y = 0, width = 256, height = 48 })
  Assert.equal(presentation.origin.x, 0, "the one-pixel width overflow starts on the host pixel lattice")
end

function T.undersized_dialogue_height_keeps_one_x_and_bottom_anchors_the_overflow()
  local bounds = { x = 11, y = 13, width = 256, height = 47 }
  local _, dialogueCalls = fieldStateWithCapturedUi(bounds, 1.25)
  Assert.equal(#dialogueCalls, 1, "field dialogue draws once at the undersized height")

  local presentation = dialogueCalls[1].second
  Assert.equal(presentation.scale, 1, "the minimum presentation scale remains integer 1")
  Assert.deepEqual(presentation.bounds, bounds, "field passes the real undersized bounds")
  Assert.deepEqual(presentation.outerRect, { x = 11, y = 12, width = 256, height = 48 })
  Assert.equal(presentation.origin.y, 12, "the one-pixel height overflow stays bottom anchored")
end

function T.undersized_dialogue_on_both_axes_keeps_one_x_and_real_bounds()
  local bounds = { x = 7, y = 9, width = 255, height = 47 }
  local _, dialogueCalls = fieldStateWithCapturedUi(bounds, 1.25)
  local presentation = dialogueCalls[1].second
  Assert.equal(presentation.scale, 1)
  Assert.deepEqual(presentation.bounds, bounds)
  Assert.deepEqual(presentation.outerRect, { x = 7, y = 8, width = 256, height = 48 })
end

return { tests = T }
