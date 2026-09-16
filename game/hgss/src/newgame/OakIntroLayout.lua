-- Pure host-native geometry for the Oak intro. Source dimensions are semantic
-- placement relationships, never a fixed render surface.

local OakProfileLayout = require("game.hgss.src.newgame.OakProfileLayout")
local NamingScreenLayout = require("libs.hgss.src.ui.NamingScreenLayout")
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
  local isNameForward = view.phase == "name_composition_transition"
  local isNameReturn = view.phase == "name_composition_return"
  local isNameConfirm = view.phase == "name_confirm"
  local isFinalDialogue = view.phase == "final_dialogue"
  local isGenderQuestion = view.phase == "gender_question"
  if isNameForward or isNameReturn then
    assert(nameProgress ~= nil, "Oak name composition progress is invalid")
    assertFiniteProgress(nameProgress, "Oak name composition progress is invalid")
    assert(compositionProgress == 1, "Oak gender composition progress is invalid")
    assert(
      subjectId == "oak" and ordinarySubject ~= nil and subjectWidget ~= nil,
      "Oak subject is required for name composition"
    )
    assert(dialogue ~= nil, "Oak name composition requires reserved dialogue")
  elseif isNameConfirm or isFinalDialogue then
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

local function translateSourceGroupAboveDialogue(scene, dialogue, gap, subject, reveal)
  if dialogue == nil or (subject == nil and reveal == nil) then
    return subject, reveal
  end
  local visualHost = OakSceneLayout.aboveDialogue(scene, dialogue, gap)
  local bottom = -math.huge
  for _, item in ipairs({ subject, reveal }) do
    if item ~= nil then
      bottom = math.max(bottom, item.y + item.height)
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

local function subjectLayout(view, scene, sceneContent, gap, dialogue, subjectId, subjectWidget, ordinarySubject)
  local nameProgress = view.nameCompositionProgress
  validateSubjectState(view, dialogue, subjectId, subjectWidget, ordinarySubject)
  local isNameForward = view.phase == "name_composition_transition"
  local isNameReturn = view.phase == "name_composition_return"
  local isNameConfirm = view.phase == "name_confirm"
  local isFinalDialogue = view.phase == "final_dialogue"
  local isGenderQuestion = view.phase == "gender_question"
  local selectorActive = view.phase == "gender_select" or view.phase == "gender_confirm"
  local oakRegion, selectorRegion
  local nameOakRegion, nameChoiceRegion
  local selectedSubject = ordinarySubject
  local needsNameEndpoint = isNameForward
    or isNameReturn
    or isNameConfirm
    or isFinalDialogue
    or isGenderQuestion and nameProgress == 1
  if needsNameEndpoint then
    local genderHost = OakSceneLayout.aboveDialogue(scene, assert(dialogue), gap)
    local genderRegion = OakSceneLayout.selectorRegions(genderHost, gap)
    local genderOakRegion = genderRegion
    local genderOakRect =
      OakSceneLayout.composedOakRect(assert(ordinarySubject), assert(subjectWidget), genderOakRegion, 1)
    local _, nameOakRegionInner, nameChoiceRegionInner =
      OakSceneLayout.nameStageAndRegions(sceneContent, assert(dialogue), gap)
    nameOakRegion, nameChoiceRegion = nameOakRegionInner, nameChoiceRegionInner
    local nameOakRect = OakSceneLayout.composedOakRect(assert(ordinarySubject), assert(subjectWidget), nameOakRegion, 1)
    if isNameForward then
      selectedSubject = OakSceneLayout.interpolateSubjectRect(genderOakRect, nameOakRect, assert(nameProgress), true)
    elseif isNameReturn then
      selectedSubject =
        OakSceneLayout.interpolateSubjectRect(nameOakRect, genderOakRect, 1 - assert(nameProgress), true)
    else
      selectedSubject = nameOakRect
    end
    oakRegion, selectorRegion = nameOakRegion, nameChoiceRegion
  elseif selectorActive then
    -- The interactive selector hides Oak, so the cards own the full
    -- above the dialogue instead of the Oak-visible cards half. Fitting
    -- the 256x192 reference into the half leaves cards hanging off the
    -- logical viewport on representative hosts such as 640x480. The host
    -- runs to the dialogue edge: the centered canvas already keeps its
    -- content clear of the box, and reserving the gap on top would push
    -- cards half a pixel past the region on tall-scale hosts such as
    -- 2560x1440.
    local selectorHost = scene
    if dialogue ~= nil then
      selectorHost = rect(scene.x, scene.y, scene.width, dialogue.outerRect.y - scene.y)
    end
    oakRegion, selectorRegion = nil, selectorHost
    selectedSubject = nil
  end
  return selectedSubject, oakRegion, selectorRegion, nameChoiceRegion, selectorActive
end

local function integerConfirmationEntries(region, preferredScale)
  local stackWidth = TextButton.REFERENCE_WIDTH
  local stackHeight = TextButton.REFERENCE_HEIGHT * 2 + 8
  local scale = PixelScale.fitPreferred(region, stackWidth, stackHeight, preferredScale)
  local width, height = stackWidth * scale, TextButton.REFERENCE_HEIGHT * scale
  -- Snap the stack origin to the logical pixel grid: fractional button
  -- edges rasterize the 1px shared rings onto pixel centers, where the
  -- later face fill wins the tie and erases the ring pixel.
  local x = PixelScale.snapLogical(region.x + (region.width - width) / 2)
  local y = PixelScale.snapLogical(region.y + (region.height - (height * 2 + 8 * scale)) / 2)
  return {
    [0] = {
      key = "yes",
      rect = rect(x, y, width, height),
      scale = scale,
      button = TextButton.resolve({ rect = rect(x, y, width, height), scale = scale }),
    },
    [1] = {
      key = "no",
      rect = rect(x, y + height + 8 * scale, width, height),
      scale = scale,
      button = TextButton.resolve({ rect = rect(x, y + height + 8 * scale, width, height), scale = scale }),
    },
  }
end

local function profileLayout(
  result,
  view,
  selectorActive,
  selectorRegion,
  reference,
  manifest,
  nameChoiceRegion,
  preferredScale
)
  if selectorActive then
    local selectorCanvas = canvasForRegion(assert(selectorRegion), reference, preferredScale)
    local genderSlots = OakProfileLayout.genderSelectionEntries(selectorCanvas, manifest)
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
    result.confirmationButtons = integerConfirmationEntries(assert(nameChoiceRegion), assert(preferredScale))
  end
  if view.phase == "name_edit" then
    result.namingScreen = NamingScreenLayout.compute(result.viewport)
  end
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
  local contentWidthCap = logicalHostMetric(1120, preferredScale)
  local mode = OakSceneLayout.mode(view)
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
  ordinarySubject, ordinaryReveal =
    translateSourceGroupAboveDialogue(scene, dialogue, gap, ordinarySubject, ordinaryReveal)
  local selectedSubject, oakRegion, selectorRegion, nameChoiceRegion, selectorActive =
    subjectLayout(view, scene, sceneContent, gap, dialogue, subjectId, subjectWidget, ordinarySubject)
  result.subject = selectedSubject
  result.oakRegion = oakRegion
  result.selectorRegion = selectorRegion
  if view.revealWidget then
    result.revealCanvas = canvas
    result.reveal = ordinaryReveal
  end
  profileLayout(result, view, selectorActive, selectorRegion, reference, manifest, nameChoiceRegion, preferredScale)
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
