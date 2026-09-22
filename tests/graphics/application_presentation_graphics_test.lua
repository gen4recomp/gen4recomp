-- Real-driver proof for shared presentation drawing: a settled plan leaves
-- fade regions untouched while invoking the chosen render callback, a
-- static framed plan carries border-only geometry while leaving outside
-- pixels untouched, and borrowed graphics state survives callback failure.
-- Plans resolve through the real Start Menu interface and session; only
-- solid fills are compared, with every painted edge on whole host pixels.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local ApplicationPresentation = require("game.hgss.src.ui.ApplicationPresentation")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldWindowRenderer = require("libs.hgss.src.ui.FieldWindowRenderer")
local PngWriter = require("libs.assets.src.PngWriter")
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
  return ApplicationPresentation.new(interfaces)
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

function T.settled_plan_leaves_fade_regions_untouched(scope)
  local lg = love.graphics
  local session = startMenuSession()
  local measurement = measurementFor(640, 480)
  local plan = withContentRender(session:resolve(measurement, {}), paintBlock({ 0.1, 0.1, 0.8, 1 }))
  local before = captureState(lg)
  local canvas = renderToCanvas(scope, 640, 480, function()
    -- A visible sentinel prepaints the fade region outside the body: settled
    -- drawing must preserve it because fade coverage is transition metadata.
    local r, g, b, a = lg.getColor()
    lg.setColor(0.9, 0.2, 0.2, 1)
    lg.rectangle("fill", 600, 440, 40, 40)
    lg.setColor(r, g, b, a)
    ApplicationPresentation.draw(lg, {}, {}, plan)
  end)
  assertStateRestored(before, lg, "fullscreen draw")
  local data = scope:own(canvas:newImageData())
  -- Decorated body at 2x from (64,48): the 544x480 outer frame centers
  -- in the host and the body starts 24 logical pixels below its top.
  -- Content paint covers the canonical surface inside that body.
  assertPixelNear(data, 64 + 10, 48 + 10, 0.1, 0.1, 0.8, 1, "content paints inside the body")
  -- The sentinel survives outside the body frame: no settled matte paints.
  assertPixelNear(data, 630, 470, 0.9, 0.2, 0.2, 1, "fade regions stay unpainted outside the body")
  local pane = assert(plan.panes[1], "the plan needs its body pane")
  Assert.deepEqual(pane.placement.frame, { x = 64, y = 48, width = 512, height = 384 })
end

function T.static_frame_carries_border_only_decoration_and_leaves_outside_pixels_clear(scope)
  local lg = love.graphics
  local session = startMenuSession()
  local measurement = measurementFor(1280, 720)
  local resolved = session:resolve(measurement, {})
  local frame = assert(resolved.frames, "a wide host frames the content")[1]
  Assert.notNil(frame, "one outer frame decorates the pane")
  local plan = withContentRender(resolved, paintBlock({ 0.1, 0.8, 0.1, 1 }))
  local before = captureState(lg)
  local canvas = renderToCanvas(scope, 1280, 720, function()
    ApplicationPresentation.draw(lg, {}, {}, plan)
  end)
  assertStateRestored(before, lg, "framed draw")
  local data = scope:own(canvas:newImageData())
  -- Outside the frame the drawable stays as cleared: static plans never
  -- paint settled pixels outside their panes.
  assertPixelNear(data, 5, 5, 0, 0, 0, 0, "outside the frame stays clear")
  -- Body content paints inside the body placement.
  local pane = assert(plan.panes[1], "the plan needs its body pane")
  local bodyX, bodyY = pane.placement.origin.x, pane.placement.origin.y
  assertPixelNear(data, math.floor(bodyX + 4), math.floor(bodyY + 4), 0.1, 0.8, 0.1, 1, "content paints in the body")
end

-- The production application-frame draw sequence: the shared HGSS frame
-- primitive renders the selected strip row under each published frame
-- placement, before application content paints.
local function drawApplicationFrame(lg, window, frame, frameIndex)
  local draw = assert(
    window.drawApplicationFrame,
    "the framed application draws its selected HGSS frame border around the content box"
  )
  local record = assert(frame, "the plan publishes its outer frame")
  LogicalSurface.draw(lg, record.placement, function()
    draw(window, record.contentBox, frameIndex)
  end)
end

local function wideStartMenuFrame()
  local session = startMenuSession()
  local plan = session:resolve(measurementFor(1280, 720), {})
  local frames = assert(plan.frames, "a wide host frames the menu")
  Assert.equal(#frames, 1, "one outer frame decorates the menu")
  return plan, frames[1]
end

local function openFrameAtlas(cacheFs)
  return FieldWindowRenderer.new({
    cacheFs = cacheFs or FieldUiFixture.cacheWithFontAndFrames(),
    manifest = FieldUiFixture.manifest(),
  })
end

-- One fixture-strip texel as normalized floats, read back from the
-- fixture's own tile bytes rather than duplicating palette math. The strip
-- atlas is a row-major 144-wide image, so the texel at quad-local (lx,ly)
-- of tile `tile` lives at ((ly * 144 + tile * 8 + lx) * 4 + 1): the same
-- image-space addressing the frame-strip quads and the dialogue golden
-- reference use. A tile-major block offset would sample another tile's
-- bytes and never the drawn texel.
local function tileTexel(frameIndex, tile, lx, ly)
  local rgba = FieldUiFixture.framePixels(frameIndex)
  local offset = (ly * 144 + tile * 8 + lx) * 4
  local r, g, b, a = string.byte(rgba, offset + 1, offset + 4)
  return { r / 255, g / 255, b / 255, a / 255 }
end

local function hostPixel(placement, lx, ly)
  local scale = assert(placement.scale, "the frame placement carries its integer scale")
  local origin = assert(placement.origin, "the frame placement carries its host origin")
  return math.floor(origin.x + lx * scale), math.floor(origin.y + ly * scale)
end

local function assertPixel(data, placement, lx, ly, expected, label)
  local hx, hy = hostPixel(placement, lx, ly)
  local ar, ag, ab, aa = data:getPixel(hx, hy)
  Assert.near(ar, expected[1], 1e-2, label .. " red")
  Assert.near(ag, expected[2], 1e-2, label .. " green")
  Assert.near(ab, expected[3], 1e-2, label .. " blue")
  Assert.near(aa, expected[4], 1e-2, label .. " alpha")
end

-- The locked rotated mapping for the 256x192 content box: source right
-- becomes the target top (tile 10 at the top-band center, drawn again
-- mirrored as the bottom cap), source top becomes the target left
-- (tile 1) and source bottom becomes the target right (tile 14).
local TOP_BAND_TILE = 10

function T.selected_frame_choice_drives_the_application_border(scope)
  local lg = love.graphics
  local _, frame = wideStartMenuFrame()
  local window = scope:own(openFrameAtlas())
  local placement = assert(frame.placement, "the frame carries its host placement")
  local function renderAt(frameIndex)
    local canvas = scope:own(lg.newCanvas(1280, 720))
    lg.setCanvas(canvas)
    lg.clear(0, 0, 0, 0)
    drawApplicationFrame(lg, window, frame, frameIndex)
    lg.setCanvas()
    return scope:own(canvas:newImageData())
  end
  local first = renderAt(0)
  local second = renderAt(1)
  -- The top-band center carries the selected row's artwork: frame 0 shows
  -- its blue-family tile, frame 1 its cream-family tile.
  assertPixel(first, placement, 140, 12, tileTexel(0, TOP_BAND_TILE, 4, 4), "selected frame 0 border")
  assertPixel(second, placement, 140, 12, tileTexel(1, TOP_BAND_TILE, 4, 4), "selected frame 1 border")
  local fx0, fy0 = hostPixel(placement, 140, 12)
  local r0, g0, b0 = first:getPixel(fx0, fy0)
  local r1, g1, b1 = second:getPixel(fx0, fy0)
  Assert.isTrue(
    math.abs(r0 - r1) + math.abs(g0 - g1) + math.abs(b0 - b1) > 0.05,
    "the two selected frames paint visibly distinct borders"
  )
  -- The content box is identical (untouched) under both selections.
  local cx, cy = hostPixel(placement, 136, 120)
  local c0 = { first:getPixel(cx, cy) }
  local c1 = { second:getPixel(cx, cy) }
  Assert.deepEqual(c0, c1, "the frame draw never paints inside the content box")
  Assert.near(c0[4], 0, 1e-2, "the content box stays transparent to its own renderer")
end

-- Both horizontal caps are the same selected-frame decoration: every
-- sampled top-cap pixel equals the pixel vertically reflected across the
-- body midline, for more than one frame style at 1x and 2x, while the two
-- styles stay visibly distinct. The reflection is exact target-space
-- mirroring about the body midline: rows are 8px cells, so the counterpart
-- of row y is 2 * axis - y - 1 with axis = box.y + box.height / 2, and
-- the probes stay valid whatever exterior depth the geometry reserves.

function T.framed_application_caps_mirror_the_selected_top_band(scope)
  local lg = love.graphics
  local box = { x = 16, y = 32, width = 256, height = 192 }
  local axis = box.y + box.height / 2
  local probeX = { box.x + 2, box.x + 10, box.x + 128, box.x + 246, box.x + 254 }
  local topSamples = {}
  for _, density in ipairs({ 1, 2 }) do
    for _, frameIndex in ipairs({ 0, 1 }) do
      local tag = density .. "x style " .. frameIndex
      local window = scope:own(openFrameAtlas())
      local canvas = scope:own(lg.newCanvas(320 * density, 320 * density))
      lg.setCanvas(canvas)
      lg.clear(0, 0, 0, 0)
      lg.push("all")
      lg.scale(density, density)
      window:drawApplicationFrame(box, frameIndex)
      lg.pop()
      lg.setCanvas()
      local data = scope:own(canvas:newImageData())
      local function sample(lx, ly)
        return data:getPixel(lx * density, ly * density)
      end
      for _, lx in ipairs(probeX) do
        for i = 0, 23 do
          local topY = box.y - 1 - i
          local bottomY = 2 * axis - topY - 1
          local tr, tg, tb, ta = sample(lx, topY)
          Assert.near(ta, 1, 1e-2, tag .. " top cap is opaque decoration at " .. lx .. "," .. topY)
          local br, bg, bb, ba = sample(lx, bottomY)
          Assert.near(tr, br, 1e-2, tag .. " mirrored red at " .. lx .. "," .. topY)
          Assert.near(tg, bg, 1e-2, tag .. " mirrored green at " .. lx .. "," .. topY)
          Assert.near(tb, bb, 1e-2, tag .. " mirrored blue at " .. lx .. "," .. topY)
          Assert.near(ta, ba, 1e-2, tag .. " mirrored alpha at " .. lx .. "," .. topY)
        end
      end
      local cr, cg, cb = sample(box.x + 128, box.y - 4)
      topSamples[density .. ":" .. frameIndex] = { cr, cg, cb }
    end
  end
  for _, density in ipairs({ 1, 2 }) do
    local first = topSamples[density .. ":0"]
    local second = topSamples[density .. ":1"]
    Assert.isTrue(
      math.abs(first[1] - second[1]) + math.abs(first[2] - second[2]) + math.abs(first[3] - second[3]) > 0.05,
      density .. "x: the two selected frames paint visibly distinct caps"
    )
  end
end

-- The framed body sits fully inside real exterior room on every edge:
-- a canonical single pane reserves 8px sides and 24px caps, so the
-- outer logical frame is 272x240 with the body at (8, 24). The host is
-- sized so the integer-scaled frame leaves a real margin on both axes.
function T.framed_application_body_sits_inside_full_exterior_room(scope)
  local lg = love.graphics
  local session = startMenuSession()
  local plan = session:resolve(measurementFor(1600, 900), {})
  local frames = assert(plan.frames, "a wide host frames the menu")
  Assert.equal(#frames, 1, "one outer frame decorates the menu")
  local frame = frames[1]
  local window = scope:own(openFrameAtlas())
  local placement = assert(frame.placement, "the frame carries its host placement")
  local insets = FieldDialogueTheme.applicationFrameInsets()
  Assert.deepEqual(
    { insets.left, insets.top, insets.right, insets.bottom },
    { 8, 24, 8, 24 },
    "the full exterior frame reserves room on every edge"
  )
  local box = assert(frame.contentBox, "the frame carries its content box")
  Assert.deepEqual(
    { box.x, box.y, box.width, box.height },
    { 8, 24, 256, 192 },
    "the content box starts inside the exterior frame"
  )
  Assert.equal(placement.logicalWidth, 272, "the outer frame adds left and right room")
  Assert.equal(placement.logicalHeight, 240, "the outer frame adds top and bottom room")
  local OUTSIDE = { 1, 0, 1, 1 }
  local CONTENT = { 0, 1, 0, 1 }
  local canvas = scope:own(lg.newCanvas(1600, 900))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  lg.setColor(OUTSIDE[1], OUTSIDE[2], OUTSIDE[3], OUTSIDE[4])
  lg.rectangle("fill", 0, 0, 1600, 900)
  do
    local bx, by = hostPixel(placement, box.x, box.y)
    local ex, ey = hostPixel(placement, box.x + box.width, box.y + box.height)
    lg.setColor(CONTENT[1], CONTENT[2], CONTENT[3], CONTENT[4])
    lg.rectangle("fill", bx, by, ex - bx, ey - by)
  end
  drawApplicationFrame(lg, window, frame, 0)
  lg.setCanvas()
  local data = scope:own(canvas:newImageData())
  assertPixel(data, placement, 136, 120, CONTENT, "the content sentinel survives the border draw")
  local ox, oy = hostPixel(placement, 0, 0)
  Assert.isTrue(ox > 0 and oy > 0, "the framed box leaves a host margin on a wide host")
  local or_, og, ob, oa = data:getPixel(math.max(0, ox - 4), math.max(0, oy - 4))
  Assert.near(or_, OUTSIDE[1], 1e-2, "outside sentinel red")
  Assert.near(og, OUTSIDE[2], 1e-2, "outside sentinel green")
  Assert.near(ob, OUTSIDE[3], 1e-2, "outside sentinel blue")
  Assert.near(oa, OUTSIDE[4], 1e-2, "outside sentinel alpha")
end

function T.settled_field_stays_visible_outside_the_framed_application(scope)
  local lg = love.graphics
  local _, frame = wideStartMenuFrame()
  local window = scope:own(openFrameAtlas())
  local placement = assert(frame.placement, "the frame carries its host placement")
  local FIELD = { 0.15, 0.6, 0.15, 1 }
  local canvas = scope:own(lg.newCanvas(1280, 720))
  lg.setCanvas(canvas)
  -- The paused field already painted its host presentation.
  lg.setColor(FIELD[1], FIELD[2], FIELD[3], FIELD[4])
  lg.rectangle("fill", 0, 0, 1280, 720)
  -- The settled application paints its content, then its frame border
  -- around the fully exterior silhouette.
  local settledPlan = withContentRender(
    (function()
      local session = startMenuSession()
      return session:resolve(measurementFor(1280, 720), {})
    end)(),
    paintBlock({ 0.1, 0.1, 0.8, 1 })
  )
  ApplicationPresentation.draw(lg, {}, {}, settledPlan)
  drawApplicationFrame(lg, window, frame, 0)
  lg.setCanvas()
  local data = scope:own(canvas:newImageData())
  local fr, fg, fb, fa = data:getPixel(10, 10)
  Assert.near(fr, FIELD[1], 1e-2, "field red outside the frame")
  Assert.near(fg, FIELD[2], 1e-2, "field green outside the frame")
  Assert.near(fb, FIELD[3], 1e-2, "field blue outside the frame")
  Assert.near(fa, FIELD[4], 1e-2, "field alpha outside the frame")
  assertPixel(data, placement, 140, 12, tileTexel(0, TOP_BAND_TILE, 4, 4), "the frame border renders above the field")
  assertPixel(data, placement, 136, 120, { 0.1, 0.1, 0.8, 1 }, "the application content renders inside its body")
end

function T.application_frame_tiles_carry_rotated_artwork(scope)
  local lg = love.graphics
  local _, frame = wideStartMenuFrame()
  -- Tile 10 (the top-band center tile) gets an asymmetric marker: red rows
  -- on top, blue rows below. A composition that merely relocates tiles
  -- without rotating their artwork would keep the marker horizontal; the
  -- contract requires a visual quarter turn in either direction. The patch
  -- addresses the strip atlas in image space (row-major 144-wide, the same
  -- addressing the frame-strip quads use), not tile-major block offsets.
  local raw = FieldUiFixture.framePixels(0)
  local bytes = { raw:byte(1, -1) }
  for ty = 0, 7 do
    for tx = 0, 7 do
      local color = ty < 4 and { 255, 0, 0, 255 } or { 0, 0, 255, 255 }
      local offset = (ty * 144 + TOP_BAND_TILE * 8 + tx) * 4
      bytes[offset + 1], bytes[offset + 2], bytes[offset + 3], bytes[offset + 4] =
        color[1], color[2], color[3], color[4]
    end
  end
  local parts = {}
  for index = 1, #bytes, 4 do
    parts[#parts + 1] = string.char(bytes[index], bytes[index + 1], bytes[index + 2], bytes[index + 3])
  end
  local strip = table.concat(parts) .. FieldUiFixture.framePixels(1)
  local cache = FieldUiFixture.cacheWithFontAndFrames()
  -- Application decoration samples the dialogue atlas, so the marker
  -- addresses that strip directly.
  cache:write(FieldUiFixture.STRIP_PATH, PngWriter.encode(144, FieldUiFixture.FRAME_COUNT * 8, strip))
  local window = scope:own(openFrameAtlas(cache))
  local placement = assert(frame.placement, "the frame carries its host placement")
  local canvas = scope:own(lg.newCanvas(1280, 720))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  drawApplicationFrame(lg, window, frame, 0)
  lg.setCanvas()
  local data = scope:own(canvas:newImageData())
  -- Inside the drawn tile-10 cell (logical 136..144 x 8..16), two
  -- horizontally separated samples must land in different marker halves.
  local ax, ay = hostPixel(placement, 138, 12)
  local bx, by = hostPixel(placement, 142, 12)
  local ar, ag, ab = data:getPixel(ax, ay)
  local br, bg, bb = data:getPixel(bx, by)
  local function isRed(r, g, b)
    return r > 0.9 and g < 0.1 and b < 0.1
  end
  local function isBlue(r, g, b)
    return r < 0.1 and g < 0.1 and b > 0.9
  end
  local aIsRed, aIsBlue = isRed(ar, ag, ab), isBlue(ar, ag, ab)
  local bIsRed, bIsBlue = isRed(br, bg, bb), isBlue(br, bg, bb)
  Assert.isTrue(
    (aIsRed and bIsBlue) or (aIsBlue and bIsRed),
    "the marker tile is quarter-turned: its halves read across, not along, the band"
  )
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
