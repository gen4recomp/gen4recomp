-- Pure host-native geometry for the Oak intro. Source dimensions are semantic
-- placement relationships, never a fixed render surface.

local OakProfileLayout = require("game.hgss.src.newgame.OakProfileLayout")
local OakSceneLayout = require("game.hgss.src.newgame.OakSceneLayout")
local PixelScale = require("libs.ui.src.PixelScale")
local TextButton = require("libs.ui.src.TextButton")

local OakIntroLayout = {}

local function logicalHostMetric(physicalPixels, presentationScale)
  return math.floor(physicalPixels / presentationScale + 0.5)
end

local function rect(x, y, width, height)
  assert(width > 0 and height > 0, "Oak layout rectangle must be positive")
  return { x = x, y = y, width = width, height = height }
end

local function widget(manifest, id)
  local value = assert(manifest.widgets[id], "Oak widget metrics are missing: " .. id)
  assert(value.width > 0 and value.height > 0 and value.anchor, "Oak widget metrics are invalid")
  assert(value.sourceBounds, "Oak widget source bounds are missing: " .. id)
  return value
end

---@param region { x: number, y: number, width: number, height: number }
---@param reference { width: number, height: number }
---@param preferredScale integer
---@return { scale: number, origin: { x: number, y: number }, [string]: unknown }
local function canvasForRegion(region, reference, preferredScale)
  local scale = PixelScale.fitPreferred(region, reference.width, reference.height, assert(preferredScale))
  local origin = {
    x = region.x + (region.width - reference.width * scale) / 2,
    y = region.y + (region.height - reference.height * scale) / 2,
  }
  assert(scale > 0, "source-canvas scale must be positive")
  return { scale = scale, origin = origin }
end

local function assertFiniteProgress(value, message)
  assert(
    type(value) == "number"
      and value == value
      and value > -math.huge
      and value < math.huge
      and value >= 0
      and value <= 1,
    message
  )
end

local function validateSubjectState(view, dialogue, subjectId, subjectWidget, ordinarySubject)
  local compositionProgress = view.genderCompositionProgress
  local nameProgress = view.nameCompositionProgress
  if nameProgress ~= nil then
    assertFiniteProgress(nameProgress, "Oak name composition progress is invalid")
  end
  local isNameConfirm = view.phase == "name_confirm"
  local isFinalDialogue = view.phase == "final_dialogue"
  local isGenderQuestion = view.phase == "gender_question"
  if isNameConfirm or isFinalDialogue then
    assert(compositionProgress == 1, "Oak gender composition progress is invalid")
    assert(nameProgress == 1, "Oak name composition progress is invalid")
    assert(
      subjectId == "oak" and ordinarySubject ~= nil and subjectWidget ~= nil,
      "Oak subject is required for name composition"
    )
    assert(dialogue ~= nil, "Oak name composition requires reserved dialogue")
  elseif isGenderQuestion then
    assert(nameProgress ~= nil, "Oak name composition progress is invalid")
    assertFiniteProgress(nameProgress, "Oak name composition progress is invalid")
    assert(nameProgress == 0 or nameProgress == 1, "Oak name composition progress is invalid")
    if nameProgress == 1 then
      assert(compositionProgress == 1, "Oak gender composition progress is invalid")
      assert(
        subjectId == "oak" and ordinarySubject ~= nil and subjectWidget ~= nil,
        "Oak subject is required for name composition"
      )
      assert(dialogue ~= nil, "Oak name composition requires reserved dialogue")
    end
  end
end

-- Every opening-stage frame draws Oak against the same reveal lifecycle
-- (ball, appearing Marill, looping Marill, or nothing), so the
-- dialogue-avoidance correction is measured from one envelope containing
-- Oak plus all three reveal assets. Measuring only the currently visible
-- reveal would move Oak whenever the active reveal changes or disappears.
local OPENING_STAGE_PHASES = {
  oak_reveal_wait = true,
  oak_welcome = true,
  oak_slide_right = true,
  oak_world_inhabited = true,
  ball_open_wait = true,
  scene_flash = true,
  marill_appear = true,
  marill_brightness_fade = true,
  marill_cry_wait = true,
  oak_live_alongside = true,
  marill_hide = true,
  marill_hide_wait = true,
  oak_slide_left = true,
  oak_tell_about_yourself = true,
}

---@param view table<string, unknown>
---@return boolean
local function isOpeningStage(view)
  return view.phase ~= nil and OPENING_STAGE_PHASES[view.phase] == true
end

-- The envelope is a measurement authority only: it never causes an inactive
-- asset to render. Oak is measured without scroll displacement because the
-- horizontal slide changes X only and must not alter the vertical delta.
---@param manifest table<string, unknown>
---@param canvas { scale: number, origin: { x: number, y: number } }
---@return number the deepest bottom edge among Oak and every opening reveal asset
local function openingEnvelopeBottom(manifest, canvas)
  local bottom = -math.huge
  local oak = OakSceneLayout.sourceWidgetRect(widget(manifest, "oak"), canvas, 0)
  bottom = math.max(bottom, oak.y + oak.height)
  for _, id in ipairs({ "ball_open", "marill_appear", "marill" }) do
    local reveal = OakSceneLayout.revealRect(widget(manifest, id), canvas)
    bottom = math.max(bottom, reveal.y + reveal.height)
  end
  return bottom
end

-- The boy-or-girl question still shows Oak against the just-finished
-- reveal lifecycle, so it shares the opening stable correction until Oak
-- leaves for card selection. The second asking inside the naming flow
-- (nameCompositionProgress == 1) belongs to the name endpoint and keeps
-- the ordinary correction shared with the surrounding name phases.
---@param view table<string, unknown>
---@return boolean
local function usesStableOpeningEnvelope(view)
  if isOpeningStage(view) then
    return true
  end
  return view.phase == "gender_question" and view.nameCompositionProgress == 0
end

---@param scene { x: number, y: number, width: number, height: number }
---@param dialogue table<string, unknown>?
---@param gap number
---@param subject { x: number, y: number, width: number, height: number, scale: number }?
---@param reveal { x: number, y: number, width: number, height: number, scale: number }?
---@param measuredBottom number?
---@return { x: number, y: number, width: number, height: number, scale: number }?, { x: number, y: number, width: number, height: number, scale: number }?
local function translateSourceGroupAboveDialogue(scene, dialogue, gap, subject, reveal, measuredBottom)
  if dialogue == nil or (subject == nil and reveal == nil) then
    return subject, reveal
  end
  local visualHost = OakSceneLayout.aboveDialogue(scene, dialogue, gap)
  local bottom = measuredBottom
  if bottom == nil then
    bottom = -math.huge
    for _, item in ipairs({ subject, reveal }) do
      if item ~= nil then
        bottom = math.max(bottom, item.y + item.height)
      end
    end
  end
  local delta = 0
  if bottom > visualHost.y + visualHost.height then
    -- Keep the bottom edge above dialogue even when the source group is
    -- taller than the usable host; the excess is clipped at the viewport top.
    delta = -math.ceil(bottom - (visualHost.y + visualHost.height))
  end
  if delta == 0 then
    return subject, reveal
  end
  local function translated(item)
    if item == nil then
      return nil
    end
    return {
      x = item.x,
      y = item.y + delta,
      width = item.width,
      height = item.height,
      scale = item.scale,
    }
  end
  return translated(subject), translated(reveal)
end

-- The phases that lay out the name endpoint through nameStageAndRegions:
-- the name-stage width floor below applies exactly here, so the shared
-- content column never widens for phases that never use the split.
---@param view table<string, unknown>
---@return boolean
local function usesNameStage(view)
  return view.phase == "name_confirm"
    or view.phase == "final_dialogue"
    or (view.phase == "gender_question" and view.nameCompositionProgress == 1)
end

local function subjectLayout(view, scene, sceneContent, gap, dialogue, subjectId, subjectWidget, ordinarySubject)
  validateSubjectState(view, dialogue, subjectId, subjectWidget, ordinarySubject)
  local selectorActive = view.phase == "gender_select" or view.phase == "gender_confirm"
  local oakRegion, selectorRegion
  local nameOakRegion, nameChoiceRegion
  local selectedSubject = ordinarySubject
  local needsNameEndpoint = usesNameStage(view)
  if needsNameEndpoint then
    local _, nameOakRegionInner, nameChoiceRegionInner =
      OakSceneLayout.nameStageAndRegions(sceneContent, assert(dialogue), gap)
    nameOakRegion, nameChoiceRegion = nameOakRegionInner, nameChoiceRegionInner
    local nameOakRect = OakSceneLayout.composedOakRect(assert(ordinarySubject), assert(subjectWidget), nameOakRegion, 1)
    selectedSubject = nameOakRect
    oakRegion, selectorRegion = nameOakRegion, nameChoiceRegion
  elseif selectorActive then
    -- The interactive selector hides Oak, so the cards own the full scene
    -- above the reserved dialogue, keeping the shared gap clear of the box.
    local selectorHost = scene
    if dialogue ~= nil then
      selectorHost = OakSceneLayout.aboveDialogue(scene, dialogue, gap)
    end
    oakRegion, selectorRegion = nil, selectorHost
    selectedSubject = nil
  end
  return selectedSubject, oakRegion, selectorRegion, nameChoiceRegion, selectorActive
end

local function integerConfirmationEntries(region, preferredScale, alignRight, bounds, rightInset)
  local stackWidth = TextButton.REFERENCE_WIDTH
  local stackHeight = TextButton.REFERENCE_HEIGHT * 2 + 8
  local fitRegion = region
  if rightInset ~= nil then
    local bound = assert(bounds)
    local right = math.min(region.x + region.width, bound.x + bound.width - rightInset)
    fitRegion = {
      x = region.x,
      y = region.y,
      width = right - region.x,
      height = region.height,
    }
    assert(fitRegion.width > 0, "Oak name confirmation inset region must be positive")
  end
  local scale = PixelScale.fitPreferred(fitRegion, stackWidth, stackHeight, preferredScale)
  if alignRight then
    local area = fitRegion
    if bounds ~= nil then
      local bound = assert(bounds)
      local left = math.max(fitRegion.x, bound.x)
      local right = math.min(fitRegion.x + fitRegion.width, bound.x + bound.width)
      area = { x = left, y = bound.y, width = right - left, height = bound.height }
    end
    assert(area.width > 0 and area.height > 0, "Oak name confirmation bounds must be positive")

    local visualYes, visualNo
    while scale >= 1 do
      local trialWidth = stackWidth * scale
      local trialHeight = TextButton.REFERENCE_HEIGHT * scale
      local trialGap = 8 * scale
      local yesButton = TextButton.resolve({
        rect = rect(0, 0, trialWidth, trialHeight),
        scale = scale,
        cornerRadius = 6,
      })
      local noButton = TextButton.resolve({
        rect = rect(0, trialHeight + trialGap, trialWidth, trialHeight),
        scale = scale,
        cornerRadius = 6,
      })
      local yesBounds = TextButton.visualBounds(yesButton, true)
      local noBounds = TextButton.visualBounds(noButton, true)
      local unionWidth = math.max(yesBounds.x + yesBounds.width, noBounds.x + noBounds.width)
        - math.min(yesBounds.x, noBounds.x)
      local unionHeight = math.max(yesBounds.y + yesBounds.height, noBounds.y + noBounds.height)
        - math.min(yesBounds.y, noBounds.y)
      if unionWidth <= area.width and unionHeight <= area.height then
        visualYes, visualNo = yesBounds, noBounds
        break
      end
      scale = scale - 1
    end
    assert(
      visualYes ~= nil and visualNo ~= nil,
      string.format("Oak name confirmation focus bounds do not fit at 1x (%s x %s)", area.width, area.height)
    )
    local unionLeft = math.min(visualYes.x, visualNo.x)
    local unionTop = math.min(visualYes.y, visualNo.y)
    local unionRight = math.max(visualYes.x + visualYes.width, visualNo.x + visualNo.width)
    local unionBottom = math.max(visualYes.y + visualYes.height, visualNo.y + visualNo.height)
    local x = area.x + area.width - (unionRight - unionLeft) - unionLeft
    local visualHeight = unionBottom - unionTop
    local desiredTop = region.y + (region.height - visualHeight) / 2
    local visualTop = math.max(area.y, math.min(desiredTop, area.y + area.height - visualHeight))
    local y = visualTop - unionTop
    local width = TextButton.REFERENCE_WIDTH * scale
    local height = TextButton.REFERENCE_HEIGHT * scale
    local yesRect = rect(x, y, width, height)
    local noRect = rect(x, y + height + 8 * scale, width, height)
    local yes = {
      key = "yes",
      rect = yesRect,
      scale = scale,
      button = TextButton.resolve({ rect = yesRect, scale = scale, cornerRadius = 6 }),
    }
    local no = {
      key = "no",
      rect = noRect,
      scale = scale,
      button = TextButton.resolve({ rect = noRect, scale = scale, cornerRadius = 6 }),
    }
    for _, entry in ipairs({ yes, no }) do
      local visual = TextButton.visualBounds(entry.button, true)
      assert(
        visual.x >= area.x
          and visual.y >= area.y
          and visual.x + visual.width <= area.x + area.width
          and visual.y + visual.height <= area.y + area.height,
        "Oak name confirmation focus bounds exceed the safe region"
      )
    end
    return { [0] = yes, [1] = no }
  end
  local width, height = stackWidth * scale, TextButton.REFERENCE_HEIGHT * scale
  -- Snap the centered stack to the logical pixel grid so fractional button
  -- edges do not erase the shared ring pixels during rasterization.
  local x = PixelScale.snapLogical(region.x + (region.width - width) / 2)
  local y = PixelScale.snapLogical(region.y + (region.height - (height * 2 + 8 * scale)) / 2)
  if bounds ~= nil then
    x = math.max(bounds.x, math.min(x, bounds.x + bounds.width - width))
    y = math.max(bounds.y, math.min(y, bounds.y + bounds.height - height * 2 - 8 * scale))
  end
  return {
    [0] = {
      key = "yes",
      rect = rect(x, y, width, height),
      scale = scale,
      button = TextButton.resolve({ rect = rect(x, y, width, height), scale = scale, cornerRadius = 6 }),
    },
    [1] = {
      key = "no",
      rect = rect(x, y + height + 8 * scale, width, height),
      scale = scale,
      button = TextButton.resolve({
        rect = rect(x, y + height + 8 * scale, width, height),
        scale = scale,
        cornerRadius = 6,
      }),
    },
  }
end

-- Gender cards are placed as one group: initial entries resolve from
-- the selector canvas, the deepest card edge decides a single upward shift
-- of that canvas, and final entries regenerate from the shifted canvas so
-- card chrome and portraits move together. A host too short for the whole
-- group keeps the lower edge above dialogue while excess leaves the top;
-- cards never bleed downward out of the selector region.
--
-- The renderer draws each entry portrait as its button image, so the
-- portrait must stay inside the resolved button content. Group translation
-- preserves the resolved relationship instead of clipping it.

---@param portrait { x: number, y: number, width: number, height: number }
---@param content { x: number, y: number, width: number, height: number }
---@return boolean
local function portraitFitsContent(portrait, content)
  local epsilon = 1e-6
  return portrait.x >= content.x - epsilon
    and portrait.y >= content.y - epsilon
    and portrait.x + portrait.width <= content.x + content.width + epsilon
    and portrait.y + portrait.height <= content.y + content.height + epsilon
end
---@param selectorRegion { x: number, y: number, width: number, height: number }
---@param reference { width: number, height: number }
---@param manifest table<string, unknown>
---@param preferredScale integer
---@return OakGenderCardEntry[]
local function genderGroupEntries(selectorRegion, reference, manifest, preferredScale)
  local selectorCanvas = canvasForRegion(selectorRegion, reference, preferredScale)
  local entries = OakProfileLayout.genderSelectionEntries(selectorCanvas, manifest)
  local bottom = -math.huge
  for gender = 0, 1 do
    local card = assert(entries[gender]).rect
    bottom = math.max(bottom, card.y + card.height)
  end
  local regionBottom = selectorRegion.y + selectorRegion.height
  if bottom > regionBottom then
    selectorCanvas = {
      scale = selectorCanvas.scale,
      origin = { x = selectorCanvas.origin.x, y = selectorCanvas.origin.y - (bottom - regionBottom) },
    }
    entries = OakProfileLayout.genderSelectionEntries(selectorCanvas, manifest)
  end
  for gender = 0, 1 do
    local entry = assert(entries[gender])
    assert(
      portraitFitsContent(entry.portraitRect, assert(entry.button.contentRect)),
      "Oak gender portrait must stay inside its button content"
    )
    assert(entry.rect.y + entry.rect.height <= regionBottom + 1e-6, "Oak gender group must stay above dialogue")
  end
  return entries
end

local function profileLayout(
  result,
  view,
  selectorActive,
  selectorRegion,
  reference,
  manifest,
  nameChoiceRegion,
  preferredScale,
  gap
)
  if selectorActive then
    local genderSlots = genderGroupEntries(assert(selectorRegion), reference, manifest, preferredScale)
    if view.phase == "gender_select" then
      result.genderButtons = genderSlots
    else
      local focus = view.genderFocus == 0 and 0 or 1
      local selected = assert(genderSlots[focus])
      local opposite = assert(genderSlots[1 - focus])
      result.selectedProfileButton = selected
      if view.confirmationChoice then
        result.confirmationButtons = integerConfirmationEntries(opposite.rect, assert(preferredScale))
      end
    end
  end
  if view.phase == "name_confirm" and view.confirmationChoice and view.confirmationChoice.kind == "name" then
    result.confirmationButtons =
      integerConfirmationEntries(assert(nameChoiceRegion), assert(preferredScale), true, result.safeFrame, gap)
  end
  -- The reusable Naming Screen child is placed by the parent-owned naming
  -- session, never by scene composition: OakIntroState publishes the
  -- canonical child geometry beside its resolved presentation plan.
end

---@param width number
---@param height number
---@param view table<string, unknown>
---@param glyphs string[]
---@param manifest table<string, unknown>
---@param preferredScale integer
---@return OakIntroStateLayout
function OakIntroLayout.compute(width, height, view, glyphs, manifest, preferredScale)
  assert(type(width) == "number" and width == width and width > 0, "Oak viewport width is invalid")
  assert(type(height) == "number" and height == height and height > 0, "Oak viewport height is invalid")
  assert(type(view) == "table" and type(glyphs) == "table", "Oak layout requires view and glyphs")
  assert(
    type(preferredScale) == "number" and preferredScale > 0 and preferredScale == math.floor(preferredScale),
    "Oak preferred scale must be a positive integer"
  )
  assert(
    type(manifest) == "table" and type(manifest.sourceReference) == "table",
    "Oak layout requires source reference"
  )
  local reference = manifest.sourceReference
  assert(reference.width > 0 and reference.height > 0, "Oak source reference is invalid")
  local physicalWidth, physicalHeight = width * preferredScale, height * preferredScale
  local physicalMinimum = math.min(physicalWidth, physicalHeight)
  local inset = logicalHostMetric(
    math.min(12, math.floor(physicalMinimum * 0.035 + 0.5), math.max(0, math.floor((physicalMinimum - 1) / 2))),
    preferredScale
  )
  local safeFrame = rect(inset, inset, width - inset * 2, height - inset * 2)
  local gap = logicalHostMetric(math.min(8, math.max(0, math.floor(physicalMinimum * 0.02 + 0.5))), preferredScale)
  local mode = OakSceneLayout.mode(view)
  local contentWidthCap = logicalHostMetric(1120, preferredScale)
  -- The cap keeps the content column from spreading across ultra-wide
  -- hosts, but it must never squeeze the name stage below the minimum
  -- width its scale-1 content needs: the Oak portrait plus the gap plus
  -- the Yes/No stack across the stage split owned by nameStageAndRegions.
  -- The floor applies only while the name endpoint is laid out; anywhere
  -- else it would widen the shared column past the pinned 1120.
  if usesNameStage(view) then
    local oakPortraitWidth = widget(manifest, "oak").width
    local confirmationButton = TextButton.resolve({
      rect = rect(0, 0, TextButton.REFERENCE_WIDTH, TextButton.REFERENCE_HEIGHT),
      scale = 1,
      cornerRadius = 6,
    })
    local confirmationWidth = TextButton.visualBounds(confirmationButton, true).width
    local minNameContentWidth = gap + math.max(oakPortraitWidth / 0.46, (confirmationWidth + gap) / 0.54)
    contentWidthCap = math.max(contentWidthCap, math.ceil(minNameContentWidth))
  end
  local dialogue = OakSceneLayout.dialogue(safeFrame, mode.reservesDialogue, preferredScale)
  local scene, sceneContent = OakSceneLayout.sceneRegions(width, safeFrame, contentWidthCap)
  local result ---@type OakIntroStateLayout
  result = {
    viewport = rect(0, 0, width, height),
    safeFrame = safeFrame,
    scene = scene,
    stage = scene,
    stageContent = sceneContent,
    dialogue = dialogue,
    message = dialogue and dialogue.outerRect or scene,
    genderFocus = view.genderFocus,
  }
  local subjectId = view.primaryWidget
  if subjectId == nil and view.visual ~= "background" then
    subjectId = view.visual
  end
  local canvas = OakSceneLayout.sourceCanvas(scene, reference, preferredScale)
  result.sourceCanvas = canvas
  local subjectWidget
  local ordinarySubject
  if subjectId ~= nil then
    subjectWidget = widget(manifest, subjectId)
    local visibleSourceX = subjectId == "oak" and -(view.oakBgScrollX or 0) or 0
    ordinarySubject = OakSceneLayout.sourceWidgetRect(subjectWidget, canvas, visibleSourceX)
  end
  local ordinaryReveal
  if view.revealWidget then
    ordinaryReveal = OakSceneLayout.revealRect(widget(manifest, view.revealWidget), canvas)
  end
  local envelopeBottom
  if usesStableOpeningEnvelope(view) then
    envelopeBottom = openingEnvelopeBottom(manifest, canvas)
  end
  ordinarySubject, ordinaryReveal =
    translateSourceGroupAboveDialogue(scene, dialogue, gap, ordinarySubject, ordinaryReveal, envelopeBottom)
  local selectedSubject, oakRegion, selectorRegion, nameChoiceRegion, selectorActive =
    subjectLayout(view, scene, sceneContent, gap, dialogue, subjectId, subjectWidget, ordinarySubject)
  result.subject = selectedSubject
  result.oakRegion = oakRegion
  result.selectorRegion = selectorRegion
  if view.revealWidget then
    result.revealCanvas = canvas
    result.reveal = ordinaryReveal
  end
  profileLayout(
    result,
    view,
    selectorActive,
    selectorRegion,
    reference,
    manifest,
    nameChoiceRegion,
    preferredScale,
    gap
  )
  return result
end

---@param region table<string, unknown>?
---@param x number
---@param y number
---@return boolean
function OakIntroLayout.contains(region, x, y)
  return region ~= nil
    and x >= region.x
    and y >= region.y
    and x < region.x + region.width
    and y < region.y + region.height
end

return OakIntroLayout
