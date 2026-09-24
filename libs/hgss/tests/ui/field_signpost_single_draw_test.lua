-- Behavior: signpost renderer draws wayfinding as one quad/draw, not 24.

local Assert = require("tests.support.Assert")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldSignpostFixture = require("tests.support.FieldSignpostFixture")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local FieldSignpostRenderer = require("libs.hgss.src.ui.FieldSignpostRenderer")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")

local T = {}

local function fakeGraphics()
  return require("tests.support.FakeGraphics").new({
    imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 128 }, { 144, 8 }, { 48, 32 } },
  })
end

local function rendererWithStandardManifest(lg)
  local cache = FieldUiFixture.cacheWithFontAndFrames()
  local manifest = FieldUiFixture.manifest()
  local text = FieldTextRenderer.new({ cacheFs = cache, graphics = lg })
  local r = FieldSignpostRenderer.new({
    cacheFs = cache,
    manifest = manifest,
    text = text,
    graphics = lg,
    windowStyles = FieldSignpostFixture.styles(),
  })
  return r, text, manifest
end

local function wayfindingDraws(lg)
  local images = lg.images
  local wayfindingImage = images[5]
  local out = {}
  for _, call in ipairs(lg.draws) do
    if call.image == wayfindingImage then
      out[#out + 1] = call
    end
  end
  return out
end

function T.wayfinding_is_drawn_with_one_quad_and_one_draw_at_graphic_region_plus_wipe()
  local lg = fakeGraphics()
  local r, text = rendererWithStandardManifest(lg)
  local controller = FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 0, map = 0, offset = 0 })
  local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
  r:draw(controller, viewport, 1, 1)
  local draws = wayfindingDraws(lg)
  -- Baseline draws 24 quads (192x8 strip rearranged as 6x4); after fix should be 1 draw of 48x32
  Assert.equal(#draws, 1, "wayfinding should be one draw, not 24")
  local call = draws[1]
  Assert.equal(call.quad.w, 48, "quad width 48")
  Assert.equal(call.quad.h, 32, "quad height 32")
  Assert.equal(call.x, 16, "graphic region x")
  Assert.equal(call.y, 152, "graphic region y + wipe")
  r:release()
  text:release()
end

function T.wayfinding_single_draw_respects_wipe_offset()
  local lg = fakeGraphics()
  local r, text = rendererWithStandardManifest(lg)
  local controller = FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 0, map = 0, offset = -16 })
  local viewport = FieldViewport.new(256, 192, { mode = "expanded" })
  r:draw(controller, viewport, 1, 1)
  local draws = wayfindingDraws(lg)
  Assert.equal(#draws, 1)
  Assert.equal(draws[1].y, 152 + 16, "draw y includes wipe")
  r:release()
  text:release()
end

return { tests = T }
