-- Dev-mode behavior over the playtest presentation. Product mode (the
-- default) renders no playtest HUD and ignores the F1 save / F2 reset
-- developer binds; dev mode keeps both. The zoom keys are product camera
-- controls and stay available in both modes.

local Assert = require("tests.support.Assert")
local FieldState = require("game.hgss.src.field.FieldState")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = {}

-- A bare FieldState (no boot) shaped like a live presentation state: the
-- canonical runtime fields the draw path touches, a stubbed renderer, and the
-- development flag under test. The player visual record is invisible, so the
-- actor assembly never touches the presentation asset provider.
local function drawableState(development)
  return setmetatable({
    development = development == true,
    runtime = {
      runtimeMap = {
        mapId = 61,
        mapSymbol = "MAP_NEW_BARK",
        sceneRuntime = { mapDraws = {}, staticBuildingDraws = {}, animatedBuildingDraws = {} },
      },
      player = { fieldX = 3, fieldZ = 7, worldY = 1.5, surfaceId = 0, facing = "east", motion = "idle" },
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
      session = {
        renderAlpha = function()
          return 0.5
        end,
      },
      destinationWorldPresentable = function()
        return true
      end,
      acknowledgeDestinationPresentation = function() end,
      viewport = FieldViewport.new(640, 480, { mode = "expanded" }),
      camera = { zoom = 1 },
      transition = { fadeAlpha = 0 },
      fieldPixelScale = {
        resolvedScale = function()
          return 3
        end,
      },
      fieldEntranceIndicator = {
        status = function()
          return { visible = false }
        end,
      },
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
      applicationHost = {
        status = function()
          return { phase = "closed", fadeAlpha = 0 }
        end,
      },
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
        rect = { x = 0, y = 0, width = 640, height = 480 },
        touch = false,
        role = "world",
      })
    end,
    worldParts = {},
    worldActorItems = {},
    spriteItems = {},
    presentationResources = {
      renderer = { draw = function() end },
      fieldEntranceIndicatorRenderer = {
        drawItems = function()
          return {}
        end,
      },
      fieldEmoteRenderer = {
        drawItems = function()
          return {}
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
  }, FieldState)
end

-- Counts the HUD's graphics calls through the real offscreen graphics host,
-- restoring print/rectangle on every path.
local function withHudGraphicsSpy(fn)
  local graphics = love.graphics
  local counts = { print = 0, rectangle = 0 }
  local original = {}
  for name in pairs(counts) do
    original[name] = graphics[name]
    graphics[name] = function()
      counts[name] = counts[name] + 1
    end
  end
  local ok, err = pcall(fn)
  for name in pairs(original) do
    graphics[name] = original[name]
  end
  if not ok then
    error(err, 0)
  end
  return counts
end

-- Product mode (the default) renders no playtest HUD.
function T.product_mode_draw_renders_no_playtest_hud()
  local counts = withHudGraphicsSpy(function()
    drawableState(false):draw()
  end)
  Assert.equal(counts.print, 0, "product mode must not print the playtest HUD")
  Assert.equal(counts.rectangle, 0, "product mode must not draw the HUD backdrop")
end

-- Dev mode keeps the playtest HUD.
function T.dev_mode_draw_keeps_the_playtest_hud()
  local counts = withHudGraphicsSpy(function()
    drawableState(true):draw()
  end)
  Assert.equal(counts.print, 4, "dev mode keeps the four playtest HUD lines")
  Assert.equal(counts.rectangle, 1, "dev mode keeps the HUD backdrop")
end

-- Product mode ignores the F1 save / F2 reset developer binds.
function T.product_mode_ignores_the_f1_and_f2_developer_binds()
  local saves, resets = 0, 0
  local state = setmetatable({
    runtime = {
      actionKeys = {},
      cancelKeys = {},
      menuKeys = {},
      saveSession = function()
        saves = saves + 1
      end,
      reset = function()
        resets = resets + 1
      end,
    },
  }, FieldState)
  state:keypressed("f1")
  state:keypressed("f2")
  Assert.equal(saves, 0, "product mode must ignore the F1 developer save bind")
  Assert.equal(resets, 0, "product mode must ignore the F2 developer reset bind")
end

-- Dev mode no longer exposes legacy persistence/reset binds.
function T.dev_mode_ignores_the_legacy_f1_and_f2_persistence_binds()
  local saves, resets = 0, 0
  local state = setmetatable({
    development = true,
    runtime = {
      actionKeys = {},
      cancelKeys = {},
      menuKeys = {},
      saveSession = function()
        saves = saves + 1
      end,
      reset = function()
        resets = resets + 1
      end,
    },
  }, FieldState)
  state:keypressed("f1")
  state:keypressed("f2")
  Assert.equal(saves, 0, "dev mode must not expose the legacy F1 save bind")
  Assert.equal(resets, 0, "dev mode must not expose the legacy F2 reset bind")
end

-- The zoom keys are product camera controls and stay available in both modes.
function T.product_mode_keeps_the_documented_zoom_controls()
  local zooms = {}
  local changes = 0
  local state = setmetatable({
    runtime = {
      actionKeys = {},
      cancelKeys = {},
      menuKeys = {},
      fieldPixelScale = {
        zoomOut = function()
          zooms[#zooms + 1] = "out"
        end,
        zoomIn = function()
          zooms[#zooms + 1] = "in"
        end,
        reset = function()
          zooms[#zooms + 1] = "reset"
        end,
      },
      applyFieldPixelScaleChange = function()
        changes = changes + 1
      end,
    },
  }, FieldState)
  state:keypressed("-")
  state:keypressed("=")
  state:keypressed("0")
  Assert.deepEqual(zooms, { "out", "in", "reset" }, "zoom keys are product controls, not gated")
  Assert.equal(changes, 3, "each zoom key reapplies the camera projection")
end

return { tests = T }
