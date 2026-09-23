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

function T.single_display_choice_uses_dialogue_aware_candidate_order()
  local rendererModule = loadYesNoRenderer()
  local graphics = require("tests.support.FakeGraphics").new({ imageSizes = { { 144, 16 } } })
  local cache = FieldUiFixture.cacheWithFontAndFrames()
  local text = FieldTextRenderer.new({ cacheFs = cache, graphics = graphics })
  local window = FieldWindowRenderer.new({ cacheFs = cache, manifest = FieldUiFixture.manifest(), graphics = graphics })
  local renderer = rendererModule.new({ text = text, window = window, graphics = graphics })
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 640, height = 480 },
    safeRect = { x = 12, y = 24, width = 616, height = 432 },
    role = "world",
    touch = false,
  })
  local status = { active = true, selectedIndex = 0, yesText = "YES", noText = "NO", frameIndex = 1 }
  local right = 12 + 616 - 6 * 8
  local below = renderer:layout(status, topology, { x = 100, y = 100, width = 200, height = 80 })
  Assert.deepEqual(below.content, { x = right, y = 180, width = 48, height = 32 }, "below-right wins when it fits")

  local above = renderer:layout(status, topology, { x = 100, y = 410, width = 200, height = 40 })
  Assert.deepEqual(
    above.content,
    { x = right, y = 378, width = 48, height = 32 },
    "above-right is next when below does not fit"
  )

  local fallback = renderer:layout(status, topology, { x = 12, y = 24, width = 616, height = 432 })
  Assert.deepEqual(
    fallback.content,
    { x = right, y = 424, width = 48, height = 32 },
    "fallback stays at safe bottom-right"
  )
  renderer:release()
  window:release()
  text:release()
end

function T.focus_indicator_draw_uses_the_focus_asset_without_black_tint()
  local graphics =
    require("tests.support.FakeGraphics").new({ imageSizes = { { 512, 224 }, { 512, 16 }, { 96, 128 } } })
  local text = FieldTextRenderer.new({
    cacheFs = FieldDialogueFixture.cacheWithFont(),
    graphics = graphics,
  })
  local palette = {}
  for slot = 0, 15 do
    palette[slot] = { r = slot, g = slot, b = slot }
  end
  text:drawFocusIndicator(0, 8, 16, palette)
  local draws = FieldDialogueFixture.focusDraws(graphics)
  Assert.equal(#draws, 4, "one mask for each source palette slot is drawn")
  for index, slot in ipairs({ 11, 12, 13, 14 }) do
    Assert.equal(draws[index].image, graphics.images[3], "focus rendering must use the focus-indicator asset")
    Assert.deepEqual(
      draws[index].color,
      { slot / 255, slot / 255, slot / 255, 1 },
      "focus rendering uses its owning palette without a black tint"
    )
  end
  text:release()
end

function T.yes_no_focus_indicator_uses_its_selected_window_frame_palette()
  local rendererModule = loadYesNoRenderer()
  local graphics = require("tests.support.FakeGraphics").new()
  local selectedPalette = { [11] = { r = 17, g = 83, b = 149 } }
  local focusCalls = {}
  local window = {
    drawWindow = function() end,
    framePalette = function(_, frameIndex)
      Assert.equal(frameIndex, 1)
      return selectedPalette
    end,
  }
  local text = {
    drawText = function() end,
    drawFocusIndicator = function(_, field, x, y, palette)
      focusCalls[#focusCalls + 1] = { field = field, x = x, y = y, palette = palette }
    end,
    windowBackgroundColor = function()
      return { 0, 0, 0, 1 }
    end,
  }
  local renderer = rendererModule.new({ text = text, window = window, graphics = graphics })
  local status = { active = true, selectedIndex = 0, yesText = "YES", noText = "NO", frameIndex = 1 }
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 640, height = 480 },
    role = "world",
    touch = false,
  })
  local layout = renderer:layout(status, topology, nil)

  renderer:draw(status, layout)

  Assert.equal(#focusCalls, 1)
  Assert.equal(focusCalls[1].field, 0)
  Assert.equal(focusCalls[1].palette, selectedPalette, "focus tint uses the selected frame palette")
end

return GraphicsSmoke.suite(T)
