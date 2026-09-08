-- Contract scenarios for the reusable host dialogue presentation. These run
-- at the graphics boundary because the behavior under test is the production
-- renderer's transform and draw contract.

local Assert = require("tests.support.Assert")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldDialogueRenderer = require("libs.hgss.src.ui.FieldDialogueRenderer")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local DialoguePresentationLayout = require("libs.hgss.src.ui.DialoguePresentationLayout")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FakeGraphics = require("tests.support.FakeGraphics")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")

local T = {}
local CURSOR_PLACEMENT = FieldUiFixture.manifest().dialogueFrames.continueCursor.placement

local function renderer(scope)
  local cache = FieldUiFixture.cacheWithFontAndFrames()
  local graphics = FakeGraphics.new()
  local text = scope:own(FieldTextRenderer.new({ cacheFs = cache, graphics = graphics }))
  local dialogue = scope:own(FieldDialogueRenderer.new({
    cacheFs = cache,
    manifest = FieldUiFixture.manifest(),
    text = text,
    graphics = graphics,
  }))
  return dialogue, graphics
end

T["authentic_window_renders_inside_arbitrary_host_bounds"] = function(scope)
  local dialogue, graphics = renderer(scope)
  local controller = FieldDialogueFixture.openDialogue("AB", 0)
  local presentation = {
    bounds = { x = 37, y = 11, width = 900, height = 420 },
    origin = { x = 359, y = 383 },
    scale = 1.640625,
    outerRect = { x = 359, y = 383, width = 420, height = 78.75 },
    box = { x = 16, y = 8, width = 216, height = 32 },
    text = { x = 16, y = 8, width = 216, height = 32 },
    cursor = { x = 240, y = 24, width = 16, height = 16 },
    lineHeight = 16,
  }

  dialogue:draw(controller, presentation)

  Assert.deepEqual(graphics.transforms, {
    { "translate", presentation.origin.x, presentation.origin.y },
    { "scale", presentation.scale, presentation.scale },
  })
  Assert.isTrue(#graphics.draws > 0, "the active dialogue must draw its frame")
end

T["field_dialogue_remains_geometrically_and_behaviorally_identical"] = function()
  local layout = FieldDialogueTheme.layout({ x = 90, y = 40, width = 700, height = 500 }, 2, CURSOR_PLACEMENT)

  Assert.equal(layout.box.x, 16)
  Assert.equal(layout.box.y, 152)
  Assert.equal(layout.box.width, 216)
  Assert.equal(layout.box.height, 32)
  Assert.equal(layout.text.width, 216)
  Assert.equal(layout.lineHeight, 16)
  Assert.equal(layout.scale, 2)
  Assert.equal(layout.origin.x, 184)
  Assert.equal(layout.origin.y, 156)
end

-- Reference/wide/tall/resized/zoomed hosts: frame, text, and cursor must all
-- come from the one DialoguePresentationLayout.compute() call and its single
-- origin/scale transform, so their source-space spacing never changes with
-- host geometry and the cursor stays fully inside the drawn viewport at
-- every one of them.
T["frame_text_and_cursor_share_one_transform_across_host_geometries"] = function(scope)
  local dialogue, graphics = renderer(scope)
  local controller = FieldDialogueFixture.openDialogue("AB", 0)

  local geometries = {
    { bounds = { x = 0, y = 0, width = 256, height = 48 }, scale = 1 }, -- reference
    { bounds = { x = 0, y = 0, width = 1600, height = 300 }, scale = 2 }, -- wide
    { bounds = { x = 0, y = 0, width = 256, height = 768 }, scale = 1 }, -- tall
    { bounds = { x = 12, y = 30, width = 500, height = 90 }, maxScale = 1.75 }, -- resized/offset
    { bounds = { x = 0, y = 0, width = 900, height = 200 }, scale = 3.5 }, -- zoomed
  }

  local textToBoxDelta, cursorToBoxDelta
  for _, geometry in ipairs(geometries) do
    local presentation = DialoguePresentationLayout.compute(geometry.bounds, {
      scale = geometry.scale,
      maxScale = geometry.maxScale,
      cursorPlacement = CURSOR_PLACEMENT,
    })

    dialogue:draw(controller, presentation)

    Assert.deepEqual(
      graphics.transforms[#graphics.transforms - 1],
      { "translate", presentation.origin.x, presentation.origin.y }
    )
    Assert.deepEqual(graphics.transforms[#graphics.transforms], { "scale", presentation.scale, presentation.scale })

    -- The cursor's source-space rectangle must remain entirely inside the
    -- 256x48 dialogue surface at every geometry: the shared transform may
    -- change scale/translation, but it never clips or repositions a child
    -- independently of the others.
    Assert.isTrue(presentation.cursor.x >= 0 and presentation.cursor.y >= 0, "cursor stays inside the local strip")
    Assert.isTrue(
      presentation.cursor.x + presentation.cursor.width <= 256
        and presentation.cursor.y + presentation.cursor.height <= 48,
      "cursor stays inside the local strip"
    )

    local delta = presentation.text.x - presentation.box.x
    local cursorDelta = presentation.cursor.x - presentation.box.x
    if textToBoxDelta == nil then
      textToBoxDelta, cursorToBoxDelta = delta, cursorDelta
    else
      Assert.equal(delta, textToBoxDelta, "text-to-frame spacing must not depend on host geometry")
      Assert.equal(cursorDelta, cursorToBoxDelta, "cursor-to-frame spacing must not depend on host geometry")
    end
  end

  -- HGSS prints the standard message at the window's local (0,0): the text
  -- pen carries no inset relative to the frame's left edge at any geometry.
  Assert.equal(textToBoxDelta, 0, "the text pen must sit exactly at the frame's left edge, with no added inset")
end

T["invalid_presentations_fail_before_partial_drawing"] = function(scope)
  local dialogue = renderer(scope)
  local controller = FieldDialogueFixture.openDialogue("AB", 0)
  local ok, err = pcall(function()
    dialogue:draw(controller, {
      bounds = { x = 0, y = 0, width = 640, height = 480 },
      origin = { x = 0, y = 0 },
    })
  end)
  Assert.isFalse(ok, "a malformed active presentation must be rejected")
  Assert.isTrue(
    tostring(err):find("presentation", 1, true) ~= nil,
    "malformed active presentations must fail at the presentation boundary"
  )

  local bounds = { x = 10, y = 20, width = 640, height = 480 }
  local layoutOk = pcall(function()
    FieldDialogueTheme.layout(bounds, 0)
  end)
  Assert.isFalse(layoutOk, "zero exact scale must be rejected before drawing")

  local okNaN = pcall(function()
    FieldDialogueTheme.layout(bounds, 0 / 0)
  end)
  Assert.isFalse(okNaN, "NaN exact scale must be rejected before drawing")

  local okMissing = pcall(function()
    FieldDialogueTheme.layout({ x = 0, y = 0, width = 640 }, 1)
  end)
  Assert.isFalse(okMissing, "incomplete bounds must be rejected before drawing")
end

return GraphicsSmoke.suite(T)
