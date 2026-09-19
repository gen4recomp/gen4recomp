-- Real-driver proof for shared presentation drawing: a fullscreen plan
-- paints its matte over the owned region before the chosen render
-- callback, a windowed plan frames its body with border and grip while
-- leaving outside pixels untouched, and borrowed graphics state survives
-- callback failure. Plans resolve through the real Start Menu interface
-- and session; only solid fills are compared, with every painted edge on
-- whole host pixels.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local ApplicationPresentation = require("game.hgss.src.ui.ApplicationPresentation")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local StartMenuInterface = require("game.hgss.src.field.StartMenuInterface")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = {}

local function measurementFor(width, height)
  return {
    width = width,
    height = height,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = width, height = height },
      role = "world",
      touch = true,
    }),
    pixelRatio = 1,
    signature = "graphics:" .. width .. "x" .. height,
  }
end

local function sessionFor(interfaces)
  return ApplicationPresentation.new(interfaces, { wide = { x = 0.5, y = 0.5 }, tall = { x = 0.5, y = 0.5 } })
end

local function startMenuSession()
  return sessionFor(StartMenuInterface.withOverrides(nil))
end

local function paintBlock(color)
  return function(_, _, plan)
    local lg = love.graphics
    LogicalSurface.draw(lg, assert(plan.panes[1], "content needs its body pane").placement, function()
      lg.setColor(color[1], color[2], color[3], color[4])
      lg.rectangle("fill", 0, 0, 256, 192)
    end)
  end
end

local function withContentRender(plan, render)
  plan.render = render
  return plan
end

local function renderToCanvas(scope, width, height, paint)
  local lg = love.graphics
  local canvas = scope:own(lg.newCanvas(width, height))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  paint()
  lg.setCanvas()
  return canvas
end

local function assertPixelNear(data, x, y, r, g, b, a, label)
  local ar, ag, ab, aa = data:getPixel(x, y)
  Assert.near(ar, r, 1e-2, label .. " red")
  Assert.near(ag, g, 1e-2, label .. " green")
  Assert.near(ab, b, 1e-2, label .. " blue")
  Assert.near(aa, a, 1e-2, label .. " alpha")
end

local function captureState(lg)
  local r, g, b, a = lg.getColor()
  local sx, sy, sw, sh = lg.getScissor()
  return { color = { r, g, b, a }, scissor = { sx, sy, sw, sh }, canvas = lg.getCanvas() }
end

local function assertStateRestored(before, lg, label)
  local after = captureState(lg)
  Assert.deepEqual(after.color, before.color, label .. " color")
  Assert.deepEqual(after.scissor, before.scissor, label .. " scissor")
  Assert.isTrue(after.canvas == before.canvas, label .. " render target")
end

function T.fullscreen_plan_paints_matte_before_content(scope)
  local lg = love.graphics
  local session = startMenuSession()
  local measurement = measurementFor(640, 480)
  local plan = withContentRender(session:resolve(measurement, {}), paintBlock({ 0.1, 0.1, 0.8, 1 }))
  local before = captureState(lg)
  local canvas = renderToCanvas(scope, 640, 480, function()
    ApplicationPresentation.draw(lg, {}, {}, plan)
  end)
  assertStateRestored(before, lg, "fullscreen draw")
  local data = scope:own(canvas:newImageData())
  -- Body at 2x from (64,48): content paint covers the canonical surface.
  assertPixelNear(data, 64 + 10, 48 + 10, 0.1, 0.1, 0.8, 1, "content paints inside the body")
  -- Matte owns the target remainder outside the body frame.
  assertPixelNear(data, 630, 470, 0, 0, 0, 1, "matte covers the owned region outside the body")
  local pane = assert(plan.panes[1], "the plan needs its body pane")
  Assert.deepEqual(pane.placement.frame, { x = 64, y = 48, width = 512, height = 384 })
end

function T.window_chrome_frames_the_body_and_leaves_outside_pixels_clear(scope)
  local lg = love.graphics
  local session = startMenuSession()
  local measurement = measurementFor(1280, 720)
  local resolved = session:resolve(measurement, {})
  local window = assert(resolved.window, "a wide host frames a window")
  local plan = withContentRender(resolved, paintBlock({ 0.1, 0.8, 0.1, 1 }))
  local before = captureState(lg)
  local canvas = renderToCanvas(scope, 1280, 720, function()
    ApplicationPresentation.draw(lg, {}, {}, plan)
  end)
  assertStateRestored(before, lg, "windowed draw")
  local data = scope:own(canvas:newImageData())
  local outer = window.outer.frame
  -- Outside the window the drawable stays as cleared: windows never clear
  -- pixels outside themselves.
  assertPixelNear(data, 5, 5, 0, 0, 0, 0, "outside the window stays clear")
  -- One-pixel neutral border around the outer frame.
  assertPixelNear(data, outer.x, outer.y, 0.45, 0.50, 0.55, 1, "the outer border paints")
  -- The light grip sits centred in the title strip.
  local gripX = math.floor(outer.x + 1 + (256 - 16) / 2 * window.outer.scale)
  local gripY = math.floor(outer.y + 6 * window.outer.scale)
  assertPixelNear(data, gripX + 2, gripY, 0.80, 0.84, 0.88, 1, "the title grip paints")
  -- Body content paints inside the body placement.
  local bodyX, bodyY = window.body.origin.x, window.body.origin.y
  assertPixelNear(data, math.floor(bodyX + 4), math.floor(bodyY + 4), 0.1, 0.8, 0.1, 1, "content paints in the body")
end

function T.callback_failure_restores_state_and_propagates(scope)
  local lg = love.graphics
  local session = startMenuSession()
  local plan = session:resolve(measurementFor(640, 480), {})
  local marker = {}
  plan.render = function()
    error(marker, 0)
  end
  local before = captureState(lg)
  local canvas = scope:own(lg.newCanvas(640, 480))
  lg.setCanvas(canvas)
  local ok, err = pcall(function()
    ApplicationPresentation.draw(lg, {}, {}, plan)
  end)
  lg.setCanvas()
  Assert.isFalse(ok, "the callback failure must propagate")
  Assert.isTrue(err == marker, "the original error object propagates unwrapped")
  assertStateRestored(before, lg, "failed draw")
  local depthOk = pcall(function()
    lg.push("all")
    lg.pop()
  end)
  Assert.isTrue(depthOk, "the graphics stack stays balanced after failure")
end

return GraphicsSmoke.suite(T)
