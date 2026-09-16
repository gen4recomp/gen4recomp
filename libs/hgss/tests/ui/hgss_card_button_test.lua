local Assert = require("tests.support.Assert")
local FakeGraphics = require("tests.support.FakeGraphics")
local HgssCardButton = require("libs.hgss.src.ui.HgssCardButton")
local ImageButton = require("libs.ui.src.ImageButton")

local T = {}

local TONE = { r = 10, g = 200, b = 100 }
local BORDER = { 58 / 255, 58 / 255, 58 / 255 }
local NEUTRAL_RIM = { 222 / 255, 230 / 255, 230 / 255 }
local SELECTED_RIM = { 255 / 255, 58 / 255, 58 / 255 }

local function nearColor(recorded, expected)
  for index = 1, 3 do
    if math.abs(recorded[index] - expected[index]) > 0.02 then
      return false
    end
  end
  return true
end

local function hasColor(rectangles, expected)
  for _, record in ipairs(rectangles) do
    if nearColor(record.color, expected) then
      return true
    end
  end
  return false
end

local function draw(tone, selected, delta)
  local graphics = FakeGraphics.new()
  local rect = { x = 10, y = 20, width = 120, height = 80 }
  local resolved = HgssCardButton.resolve({ rect = rect, scale = 2 })
  local seen = {}
  HgssCardButton.draw(graphics, resolved, {
    defaultTone = tone,
    selected = selected,
    focusBlinkDelta = delta,
    contentRect = {
      x = resolved.contentRect.x,
      y = resolved.contentRect.y,
      width = resolved.contentRect.width,
      height = resolved.contentRect.height,
    },
    drawContent = function(content)
      seen[#seen + 1] = content
    end,
  })
  return graphics, resolved, seen
end

function T.resolves_the_shared_image_button_geometry()
  local spec = { rect = { x = 4, y = 6, width = 120, height = 80 }, scale = 2 }
  Assert.deepEqual(HgssCardButton.resolve(spec), ImageButton.resolve(spec))
end

function T.neutral_cards_use_the_neutral_rim_over_a_flat_tone_face()
  local graphics = draw(TONE, false, 0)
  Assert.isTrue(hasColor(graphics.rectangles, NEUTRAL_RIM), "a neutral card must use the neutral rim")
  Assert.isFalse(hasColor(graphics.rectangles, SELECTED_RIM), "a neutral card must not use the selected rim")
  Assert.isTrue(
    hasColor(graphics.rectangles, { TONE.r / 255, TONE.g / 255, TONE.b / 255 }),
    "the card face must be the flat generated tone"
  )
  Assert.isTrue(hasColor(graphics.rectangles, BORDER), "the card must keep the source border")
end

function T.selected_cards_use_the_selected_rim_without_changing_the_face()
  local graphics = draw(TONE, true, 0)
  Assert.isTrue(hasColor(graphics.rectangles, SELECTED_RIM), "a selected card must use the selected rim")
  Assert.isTrue(
    hasColor(graphics.rectangles, { TONE.r / 255, TONE.g / 255, TONE.b / 255 }),
    "a zero-delta selection must leave the face on the generated tone"
  )
end

function T.focus_delta_brightens_only_the_selected_face_with_clamping()
  local selected, _, _ = draw({ r = 0, g = 0, b = 0 }, true, 31)
  Assert.isTrue(hasColor(selected.rectangles, { 1, 1, 1 }), "a full delta must brighten the selected face to white")
  local unselected, _, _ = draw({ r = 0, g = 0, b = 0 }, false, 31)
  Assert.isFalse(hasColor(unselected.rectangles, { 1, 1, 1 }), "the focus delta must never brighten a neutral card")
  Assert.isTrue(hasColor(unselected.rectangles, { 0, 0, 0 }), "a neutral card must keep the raw tone face")
  local negative, _, _ = draw({ r = 10, g = 10, b = 10 }, true, -62)
  Assert.isTrue(hasColor(negative.rectangles, { 0, 0, 0 }), "a negative delta must clamp at black")
  local partial, _, _ = draw({ r = 0, g = 0, b = 0 }, true, 15)
  Assert.isTrue(
    hasColor(partial.rectangles, { 15 / 31, 15 / 31, 15 / 31 }),
    "a partial delta must brighten the face proportionally"
  )
end

function T.delegates_drawing_through_the_shared_geometry_primitive()
  local rect = { x = 10, y = 20, width = 120, height = 80 }
  local resolved = HgssCardButton.resolve({ rect = rect, scale = 2 })
  local tone = { r = 40, g = 80, b = 120 }
  local face = { tone.r / 255, tone.g / 255, tone.b / 255 }
  local expected = FakeGraphics.new()
  ImageButton.draw(expected, resolved, {
    selected = true,
    colors = {
      face = face,
      border = { BORDER[1], BORDER[2], BORDER[3] },
      rim = { NEUTRAL_RIM[1], NEUTRAL_RIM[2], NEUTRAL_RIM[3] },
      selectedRim = { SELECTED_RIM[1], SELECTED_RIM[2], SELECTED_RIM[3] },
      innerBorder = { face[1], face[2], face[3] },
    },
    imageRect = {
      x = resolved.contentRect.x,
      y = resolved.contentRect.y,
      width = resolved.contentRect.width,
      height = resolved.contentRect.height,
    },
    drawImage = function() end,
  })
  local actual, _, seen = draw(tone, true, 0)
  Assert.deepEqual(actual.rectangles, expected.rectangles)
  Assert.equal(#seen, 1, "the content callback must run exactly once")
  Assert.deepEqual(seen[1], {
    x = resolved.contentRect.x,
    y = resolved.contentRect.y,
    width = resolved.contentRect.width,
    height = resolved.contentRect.height,
  })
end

function T.selected_rim_accessor_matches_the_selected_draw_rim()
  local rim = HgssCardButton.selectedRim()
  Assert.deepEqual(rim, SELECTED_RIM)
  local graphics = draw(TONE, true, 0)
  Assert.isTrue(hasColor(graphics.rectangles, rim), "the accessor must match the rim used by a selected draw")
end

function T.rejects_missing_tone_and_content_outside_the_card()
  local resolved = HgssCardButton.resolve({ rect = { x = 0, y = 0, width = 60, height = 40 }, scale = 1 })
  local graphics = FakeGraphics.new()
  Assert.throws(function()
    HgssCardButton.draw(graphics, resolved, {
      selected = true,
      contentRect = resolved.contentRect,
      drawContent = function() end,
    })
  end, "drawing without the generated tone must fail")
  Assert.throws(function()
    HgssCardButton.draw(graphics, resolved, {
      defaultTone = TONE,
      selected = true,
      contentRect = { x = -100, y = -100, width = 8, height = 8 },
      drawContent = function() end,
    })
  end, "content outside the resolved card must fail")
end

return { tests = T }
