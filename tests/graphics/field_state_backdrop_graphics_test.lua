-- Field host backdrop: host pixels outside worldViewport must stay black on
-- every field map instead of falling back to the application background
-- color. The world still renders inside worldViewport.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local FieldState = require("game.hgss.src.field.FieldState")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local WindowConfig = require("game.src.WindowConfig")

local FIELD_BACKDROP_BLACK = { 0, 0, 0 }

local T = {}

local function drawableState(environment, worldViewport, windowWidth, windowHeight)
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = windowWidth, height = windowHeight },
    touch = false,
    role = "world",
  })
  local viewport = {
    width = windowWidth,
    height = windowHeight,
    worldViewport = worldViewport,
    referenceFrame = worldViewport,
    logicalPixelScale = function()
      return 1
    end,
  }
  local runtime = {
    errorText = nil,
    uiManifest = {
      dialogueFrames = { continueCursor = { placement = { x = 240, y = 168, width = 16, height = 16 } } },
    },
    runtimeMap = {
      mapId = 1,
      mapSymbol = "MAP_TEST",
      sceneRuntime = { mapDraws = {}, staticBuildingDraws = {}, animatedBuildingDraws = {} },
      fieldData = {
        transitionEnvironment = environment,
      },
    },
    player = { fieldX = 0, fieldZ = 0, worldY = 0, surfaceId = 0, facing = "east", motion = "idle" },
    session = {
      renderAlpha = function()
        return 0.5
      end,
    },
    destinationWorldPresentable = function()
      return true
    end,
    acknowledgeDestinationPresentation = function() end,
    viewport = viewport,
    camera = { zoom = 1 },
    transition = { fadeAlpha = 0 },
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
        return { fadeAlpha = 0 }
      end,
    },
    menuHost = {
      presentation = function()
        return nil
      end,
    },
    startMenuPlacement = { frame = { x = 0, y = 0, width = windowWidth, height = windowHeight } },
    resizePresentation = function() end,
  }
  local state = setmetatable({
    runtime = runtime,
    topologyProvider = function()
      return topology
    end,
    worldParts = {},
    worldActorItems = {},
    spriteItems = {},
    presentationResources = {
      renderer = {
        draw = function(_, _, _, _, _, drawViewport)
          local world = drawViewport.worldViewport
          love.graphics.setColor(1, 1, 1, 1)
          love.graphics.rectangle("fill", world.x, world.y, world.width, world.height)
        end,
      },
      dialogueRenderer = {
        draw = function() end,
      },
      signpostRenderer = {
        draw = function() end,
      },
      startMenuRenderer = {
        draw = function() end,
      },
      trainerCardRenderer = {
        draw = function() end,
      },
      menuRenderer = {
        draw = function() end,
      },
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
  return state
end

local function quantize(value)
  return math.floor(value * 255 + 0.5)
end

local function renderOnCanvas(scope, environment)
  local windowWidth, windowHeight = love.graphics.getDimensions()
  local worldViewport = {
    x = math.floor(windowWidth / 4),
    y = math.floor(windowHeight / 4),
    width = math.floor(windowWidth / 2),
    height = math.floor(windowHeight / 2),
  }
  Assert.isTrue(worldViewport.x > 0 and worldViewport.y > 0, "world viewport must leave host area outside")
  local state = drawableState(environment, worldViewport, windowWidth, windowHeight)
  local canvas = scope:own(love.graphics.newCanvas(windowWidth, windowHeight))
  love.graphics.setCanvas(canvas)
  local bg = WindowConfig.BACKGROUND_COLOR
  love.graphics.clear(bg[1], bg[2], bg[3], bg[4] or 1)
  local ok, err = pcall(function()
    state:draw()
  end)
  love.graphics.setCanvas()
  Assert.isTrue(ok, "FieldState draw must not throw: " .. tostring(err))
  local image = scope:own(canvas:newImageData())
  return image, worldViewport, windowWidth, windowHeight
end

function T.building_map_paints_host_area_black_while_world_still_renders(scope)
  local image, world, windowWidth, windowHeight = renderOnCanvas(scope, "building")
  local outsideX, outsideY = 2, 2
  Assert.isTrue(
    outsideX < world.x and outsideY < world.y,
    "outside sample must be outside worldViewport at " .. windowWidth .. "x" .. windowHeight
  )
  local r, g, b = image:getPixel(outsideX, outsideY)
  Assert.notNil(r, "outside pixel must be readable")
  Assert.equal(quantize(r), 0, "building host area r must be black")
  Assert.equal(quantize(g), 0, "building host area g must be black")
  Assert.equal(quantize(b), 0, "building host area b must be black")
  local insideX = math.floor(world.x + world.width / 2)
  local insideY = math.floor(world.y + world.height / 2)
  local ir, ig, ib = image:getPixel(insideX, insideY)
  Assert.equal(quantize(ir), 255, "world rendering must still appear inside worldViewport")
  Assert.equal(quantize(ig), 255, "world rendering must still appear inside worldViewport")
  Assert.equal(quantize(ib), 255, "world rendering must still appear inside worldViewport")
end

function T.outdoors_map_paints_host_area_black_while_world_still_renders(scope)
  local image, world, _, _ = renderOnCanvas(scope, "outdoors")
  local r, g, b = image:getPixel(2, 2)
  Assert.notNil(r, "outside pixel must be readable")
  Assert.equal(quantize(r), FIELD_BACKDROP_BLACK[1], "outdoors host area r must be black")
  Assert.equal(quantize(g), FIELD_BACKDROP_BLACK[2], "outdoors host area g must be black")
  Assert.equal(quantize(b), FIELD_BACKDROP_BLACK[3], "outdoors host area b must be black")
  local insideX = math.floor(world.x + world.width / 2)
  local insideY = math.floor(world.y + world.height / 2)
  local ir, _, _ = image:getPixel(insideX, insideY)
  Assert.equal(quantize(ir), 255, "world rendering must still appear inside worldViewport")
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics" }
return suite
