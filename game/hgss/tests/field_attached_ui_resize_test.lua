-- Resize coupling: UI scale follows camera.zoom via logicalPixelScale, not
-- host height proportion.

local Assert = require("tests.support.Assert")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local FieldZoom = require("libs.hgss.src.presentation.FieldZoom")
local FieldPresentation = require("data.manifests.field_presentation")
local FieldState = require("game.hgss.src.field.FieldState")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local FieldUiFixture = require("tests.support.FieldUiFixture")

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
      logicalPixelScale = function()
        return 1
      end,
    },
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
  local zoom = FieldZoom.new(FieldPresentation.zoom)
  zoom:resize(viewport.worldViewport.height)
  local effective = zoom:effectiveZoom()
  return viewport:logicalPixelScale(effective), effective, viewport
end

function T.ui_scale_equals_logical_pixel_scale_at_two_heights()
  local scaleA, zoomA = effectiveScaleAtHeight(600)
  local scaleB, zoomB = effectiveScaleAtHeight(720)
  -- With resizeCompensation 0.7, zoom changes with height
  Assert.isTrue(zoomA ~= zoomB, "resize must change effective zoom per field_presentation.lua")
  local expectedA = (600 / 192) * zoomA
  local expectedB = (720 / 192) * zoomB
  Assert.near(scaleA, expectedA, 1e-9)
  Assert.near(scaleB, expectedB, 1e-9)
  -- Not simply proportional to host height: scaleB/scaleA != 720/600
  local hostRatio = 720 / 600
  local scaleRatio = scaleB / scaleA
  Assert.isTrue(
    math.abs(scaleRatio - hostRatio) > 0.01,
    "scale ratio must not equal host-height ratio when compensation active"
  )
end

function T.field_state_draw_sends_same_scale_to_both_renderers()
  local viewport = FieldViewport.new(1280, 600, { mode = "expanded" })
  local camera = { zoom = 1.25 }
  local expected = viewport:logicalPixelScale(camera.zoom)
  local fakeRuntimeMap = {
    mapId = 1,
    mapSymbol = "MAP_FAKE",
    sceneRuntime = { mapDraws = {}, staticBuildingDraws = {}, animatedBuildingDraws = {} },
  }
  local state = setmetatable({
    runtime = {
      viewport = viewport,
      uiManifest = FieldUiFixture.manifest(),
      camera = camera,
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
      startMenuPlacement = nil,
      resizePresentation = function() end,
    },
    topologyProvider = function()
      return ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 1280, height = 600 },
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
    _lastGeometrySignature = "1280:600:main:world:0:0:1280:600",
  }, FieldState)
  state._worldParts = function()
    return {}
  end
  local gotDialogue, gotSignpost
  -- Current signature: dialogue:draw(controller, viewport), signpost:draw(controller, viewport, alpha)
  -- Future should be: dialogue:draw(controller, viewport, fieldScale), signpost:draw(controller, viewport, alpha, fieldScale)
  -- Capture any numeric that equals expected.
  state.presentationResources.dialogueRenderer = {
    draw = function(_, a, b, c)
      for _, v in ipairs({ a, b, c }) do
        if type(v) == "number" and math.abs(v - expected) < 1e-9 then
          gotDialogue = v
        end
      end
      if gotDialogue == nil and type(c) == "number" then
        gotDialogue = c
      end
    end,
  } --[[@as any]]
  local presentationResources = state.presentationResources --[[@as any]]
  presentationResources.signpostRenderer = {
    draw = function(_, a, b, c, d)
      for _, v in ipairs({ a, b, c, d }) do
        if type(v) == "number" and math.abs(v - expected) < 1e-9 then
          gotSignpost = v
        end
      end
      if gotSignpost == nil and type(d) == "number" then
        gotSignpost = d
      end
      if gotSignpost == nil and type(c) == "number" and c ~= 0 then
        gotSignpost = c
      end
    end,
  }
  local oldGetDimensions = love.graphics.getDimensions
  rawset(love.graphics, "getDimensions", function()
    return 1280, 600
  end)
  local FieldDrawState = require("libs.hgss.src.presentation.FieldDrawState")
  local savedProtected = FieldDrawState.protectedDraw
  ---@diagnostic disable-next-line: duplicate-set-field -- test replaces an externally owned callback
  FieldDrawState.protectedDraw = function(_, fn)
    fn()
  end
  local ok, err = pcall(function()
    state:draw()
  end)
  FieldDrawState.protectedDraw = savedProtected
  love.graphics.getDimensions = oldGetDimensions
  Assert.isTrue(ok, "FieldState draw should not throw: " .. tostring(err))
  Assert.notNil(
    gotDialogue,
    "dialogue renderer must receive field scale via viewport:logicalPixelScale(camera.zoom); got nil (layout ignores zoom)"
  )
  Assert.near(gotDialogue, expected, 1e-9)
  Assert.notNil(gotSignpost, "signpost renderer must receive same field scale; got nil")
  Assert.near(gotSignpost, expected, 1e-9)
end

return { tests = T }
