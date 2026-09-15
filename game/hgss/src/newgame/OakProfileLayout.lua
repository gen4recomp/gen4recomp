-- Pure profile selector, confirmation, and name-editor geometry for Oak intro.

local TextButton = require("libs.ui.src.TextButton")

local OakProfileLayout = {}

local function rect(x, y, width, height)
  assert(width > 0 and height > 0, "Oak layout rectangle must be positive")
  return { x = x, y = y, width = width, height = height }
end

local function textButtonEntries(origin, scale, gap)
  local refW, refH = TextButton.REFERENCE_WIDTH, TextButton.REFERENCE_HEIGHT
  local w, h = refW * scale, refH * scale
  local firstRect = rect(origin.x, origin.y, w, h)
  local secondRect = rect(origin.x, origin.y + h + gap, w, h)
  return {
    [0] = {
      key = "yes",
      rect = firstRect,
      scale = scale,
      button = TextButton.resolve({ rect = firstRect, scale = scale }),
    },
    [1] = {
      key = "no",
      rect = secondRect,
      scale = scale,
      button = TextButton.resolve({ rect = secondRect, scale = scale }),
    },
  }
end

function OakProfileLayout.genderSelectionEntries(selectorCanvas, manifest)
  local entries = {}
  for index, sourceGender in ipairs({ "male", "female" }) do
    local sourceCard = assert(manifest.genderSelector.buttons[sourceGender]).bounds
    local cardRect = rect(
      selectorCanvas.origin.x + sourceCard.x * selectorCanvas.scale,
      selectorCanvas.origin.y + sourceCard.y * selectorCanvas.scale,
      sourceCard.width * selectorCanvas.scale,
      sourceCard.height * selectorCanvas.scale
    )
    local widget = assert(manifest.widgets["gender_" .. sourceGender])
    local center = assert(widget.sourceCenter)
    local portrait = {
      x = selectorCanvas.origin.x + center.x * selectorCanvas.scale - widget.anchor.x * selectorCanvas.scale,
      y = selectorCanvas.origin.y + center.y * selectorCanvas.scale - widget.anchor.y * selectorCanvas.scale,
      width = widget.width * selectorCanvas.scale,
      height = widget.height * selectorCanvas.scale,
      scale = selectorCanvas.scale,
    }
    assert(portrait.x >= cardRect.x and portrait.x + portrait.width <= cardRect.x + cardRect.width)
    assert(portrait.y >= cardRect.y and portrait.y + portrait.height <= cardRect.y + cardRect.height)
    entries[index - 1] = {
      key = sourceGender,
      rect = cardRect,
      scale = selectorCanvas.scale,
      portraitId = "gender_" .. sourceGender,
      portraitRect = portrait,
    }
  end
  return entries
end

-- Fits the Yes/No stack inside an already-resolved host region. The caller
-- owns which region is offered; this helper never moves other entries.
function OakProfileLayout.genderConfirmationChoices(region)
  assert(region.width > 0 and region.height > 0, "Oak confirmation region must be positive")
  local stackWidth = TextButton.REFERENCE_WIDTH
  local stackHeight = TextButton.REFERENCE_HEIGHT * 2 + 8
  local scale = math.min(region.width / stackWidth, region.height / stackHeight)
  assert(scale > 0, "Oak gender confirmation scale must be positive")
  local origin = {
    x = region.x + (region.width - stackWidth * scale) / 2,
    y = region.y + (region.height - stackHeight * scale) / 2,
  }
  return textButtonEntries(origin, scale, 8 * scale)
end

function OakProfileLayout.nameConfirmationEntries(nameStage, choiceRegion)
  local stackSourceHeight = TextButton.REFERENCE_HEIGHT * 2 + 8
  local stageScale = math.min(nameStage.width / 256, nameStage.height / 192)
  local scale =
    math.min(stageScale, choiceRegion.width / TextButton.REFERENCE_WIDTH, choiceRegion.height / stackSourceHeight)
  assert(
    scale == scale and scale > 0 and scale < math.huge and scale > -math.huge,
    "Oak name confirmation scale must be a finite positive number"
  )
  local scaledWidth = TextButton.REFERENCE_WIDTH * scale
  local scaledHeight = stackSourceHeight * scale
  local origin = {
    x = choiceRegion.x + (choiceRegion.width - scaledWidth) / 2,
    y = choiceRegion.y + (choiceRegion.height - scaledHeight) / 2,
  }
  return textButtonEntries(origin, scale, 8 * scale)
end

return OakProfileLayout
