local Assert = require("tests.support.Assert")
local DialoguePresentationLayout = require("libs.hgss.src.ui.DialoguePresentationLayout")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local FieldUiFixture = require("tests.support.FieldUiFixture")

local T = {}
local CURSOR_PLACEMENT = FieldUiFixture.manifest().dialogueFrames.continueCursor.placement

function T.computes_centered_bottom_aligned_local_geometry()
  local presentation = DialoguePresentationLayout.compute(
    { x = 37, y = 11, width = 900, height = 420 },
    { cursorPlacement = CURSOR_PLACEMENT }
  )
  Assert.near(presentation.scale, 900 / 256, 1e-9)
  Assert.deepEqual(
    presentation.origin,
    { x = 37 + (900 - 256 * presentation.scale) / 2, y = 11 + 420 - 48 * presentation.scale }
  )
  Assert.deepEqual(presentation.box, { x = 16, y = 8, width = 216, height = 32 })
  Assert.deepEqual(presentation.text, { x = 16, y = 8, width = 216, height = 32 })
  Assert.equal(
    presentation.text.width,
    FieldDialogueTheme.textWidth,
    "presentation text width must match the pagination/theme content width"
  )
  Assert.equal(presentation.text.width, presentation.box.width, "no text width is reserved for the cursor")
  Assert.equal(presentation.lineHeight, FieldDialogueTheme.lineHeight)
  Assert.deepEqual(presentation.outerRect, {
    x = presentation.origin.x,
    y = presentation.origin.y,
    width = 256 * presentation.scale,
    height = 48 * presentation.scale,
  })
end

function T.exact_scale_and_cap_are_validated()
  local exact = DialoguePresentationLayout.compute(
    { x = 0, y = 0, width = 640, height = 480 },
    { scale = 2, cursorPlacement = CURSOR_PLACEMENT }
  )
  Assert.equal(exact.scale, 2)
  local capped = DialoguePresentationLayout.compute(
    { x = 0, y = 0, width = 640, height = 480 },
    { maxScale = 1.5, cursorPlacement = CURSOR_PLACEMENT }
  )
  Assert.equal(capped.scale, 1.5)
  Assert.isFalse(pcall(function()
    DialoguePresentationLayout.compute(
      { x = 0, y = 0, width = 100, height = 100 },
      { scale = 1, cursorPlacement = CURSOR_PLACEMENT }
    )
  end))
end

function T.generated_cursor_placement_maps_to_the_local_strip_without_a_fallback()
  local placement = FieldUiFixture.manifest().dialogueFrames.continueCursor.placement
  for _, bounds in ipairs({
    { x = 37, y = 11, width = 900, height = 420 },
    { x = 0, y = 0, width = 390, height = 844 },
  }) do
    local presentation = DialoguePresentationLayout.compute(bounds, { cursorPlacement = placement })
    Assert.deepEqual(presentation.cursor, { x = 240, y = 24, width = 16, height = 16 })
  end

  Assert.isFalse(
    pcall(function()
      DialoguePresentationLayout.compute({ x = 0, y = 0, width = 640, height = 480 })
    end),
    "missing generated cursor placement must not select a layout fallback"
  )
end

function T.capped_scale_shrinks_to_fit_constrained_bounds()
  local bounds = { x = 5, y = 7, width = 200, height = 40 }
  local cap = 3.90625
  local presentation = DialoguePresentationLayout.compute(bounds, {
    maxScale = cap,
    cursorPlacement = CURSOR_PLACEMENT,
  })
  local expectedScale = math.min(cap, bounds.width / 256, bounds.height / 48)
  Assert.near(presentation.scale, expectedScale, 1e-9)
  Assert.deepEqual(presentation.bounds, bounds)
  Assert.near(presentation.outerRect.width, 256 * expectedScale, 1e-9)
  Assert.near(presentation.outerRect.height, 48 * expectedScale, 1e-9)
  Assert.isTrue(presentation.outerRect.x >= bounds.x - 1e-9, "the fitted window stays inside the host horizontally")
  Assert.isTrue(
    presentation.outerRect.x + presentation.outerRect.width <= bounds.x + bounds.width + 1e-9,
    "the fitted window stays inside the host horizontally"
  )
  Assert.isTrue(presentation.outerRect.y >= bounds.y - 1e-9, "the fitted window stays inside the host vertically")
  Assert.isTrue(
    presentation.outerRect.y + presentation.outerRect.height <= bounds.y + bounds.height + 1e-9,
    "the fitted window stays inside the host vertically"
  )
end

return { tests = T }
