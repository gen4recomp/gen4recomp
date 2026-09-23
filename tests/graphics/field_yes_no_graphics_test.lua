-- Graphics contract for the production field Yes/No renderer. The smoke uses
-- synthetic UI resources but keeps topology and frame ownership real.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldWindowRenderer = require("libs.hgss.src.ui.FieldWindowRenderer")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = {}

local function loadYesNoRenderer()
  local ok, renderer = pcall(require, "libs.hgss.src.ui.FieldYesNoRenderer")
  Assert.isTrue(ok, "production field Yes/No renderer is required for the dual-display choice")
  return renderer
end

local function dualTopology()
  return ScreenTopology.dualDisplay({
    id = "world",
    rect = { x = 0, y = 0, width = 512, height = 384 },
    role = "world",
    touch = false,
  }, {
    id = "auxiliary",
    rect = { x = 520, y = 40, width = 256, height = 192 },
    role = "auxiliary",
    touch = false,
  })
end

function T.dual_display_choice_uses_canonical_auxiliary_geometry()
  local rendererModule = loadYesNoRenderer()
  local graphics = require("tests.support.FakeGraphics").new({ imageSizes = { { 144, 16 } } })
  local cache = FieldUiFixture.cacheWithFontAndFrames()
  local text = FieldTextRenderer.new({ cacheFs = cache, graphics = graphics })
  local window = FieldWindowRenderer.new({ cacheFs = cache, manifest = FieldUiFixture.manifest(), graphics = graphics })
  local renderer = rendererModule.new({ text = text, window = window, graphics = graphics })
  local layout = renderer:layout({
    active = true,
    selectedIndex = 0,
    yesText = "YES",
    noText = "NO",
    frameIndex = 1,
  }, dualTopology(), nil)
  Assert.equal(layout.surface.role, "auxiliary")
  Assert.equal(layout.content.x, 520 + 25 * 8)
  Assert.equal(layout.content.y, 40 + 13 * 8)
  Assert.equal(layout.content.width, 6 * 8)
  Assert.equal(layout.content.height, 4 * 8)
  renderer:release()
  window:release()
  text:release()
end

function T.single_display_choice_stays_inside_portrait_safe_area()
  local rendererModule = loadYesNoRenderer()
  local graphics = require("tests.support.FakeGraphics").new({ imageSizes = { { 144, 16 } } })
  local cache = FieldUiFixture.cacheWithFontAndFrames()
  local text = FieldTextRenderer.new({ cacheFs = cache, graphics = graphics })
  local window = FieldWindowRenderer.new({ cacheFs = cache, manifest = FieldUiFixture.manifest(), graphics = graphics })
  local renderer = rendererModule.new({ text = text, window = window, graphics = graphics })
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 360, height = 640 },
    safeRect = { x = 12, y = 24, width = 336, height = 592 },
    role = "world",
    touch = false,
  })
  local layout = renderer:layout({
    active = true,
    selectedIndex = 1,
    yesText = "YES",
    noText = "NO",
    frameIndex = 1,
  }, topology, { x = 12, y = 300, width = 336, height = 160 })
  local safe = topology.surfaces[1].safeRect
  Assert.isTrue(layout.content.x >= safe.x)
  Assert.isTrue(layout.content.y >= safe.y)
  Assert.isTrue(layout.content.x + layout.content.width <= safe.x + safe.width)
  Assert.isTrue(layout.content.y + layout.content.height <= safe.y + safe.height)
  renderer:release()
  window:release()
  text:release()
end

function T.focus_indicator_draw_uses_the_focus_asset_without_black_tint()
  local graphics = require("tests.support.FakeGraphics").new({ imageSizes = { { 512, 224 }, { 512, 16 }, { 96, 32 } } })
  local text = FieldTextRenderer.new({
    cacheFs = FieldDialogueFixture.cacheWithFont(),
    graphics = graphics,
  })
  text:drawFocusIndicator(0, 8, 16)
  local draws = FieldDialogueFixture.focusDraws(graphics)
  Assert.equal(#draws, 1)
  Assert.equal(draws[1].image, graphics.images[3], "focus rendering must use the focus-indicator asset")
  Assert.deepEqual(draws[1].color, { 1, 1, 1, 1 }, "focus rendering must not apply a black tint")
  text:release()
end

return GraphicsSmoke.suite(T)
