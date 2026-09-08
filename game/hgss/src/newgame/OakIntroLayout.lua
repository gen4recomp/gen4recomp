-- Pure host-native geometry for the Oak intro. Source dimensions are semantic
-- placement relationships, never a fixed render surface.

local OakProfileLayout = require("game.hgss.src.newgame.OakProfileLayout")
local OakSceneLayout = require("game.hgss.src.newgame.OakSceneLayout")

local OakIntroLayout = {}

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
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
---@return { scale: number, origin: { x: number, y: number }, [string]: unknown }
local function canvasForRegion(region, reference)
  local scale = math.min(region.width / reference.width, region.height / reference.height)
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

local function subjectLayout(view, scene, sceneContent, gap, dialogue, subjectId, subjectWidget, ordinarySubject)
  local compositionProgress = view.genderCompositionProgress
  local nameProgress = view.nameCompositionProgress
  validateSubjectState(view, dialogue, subjectId, subjectWidget, ordinarySubject)
  local isNameForward = view.phase == "name_composition_transition"
  local isNameReturn = view.phase == "name_composition_return"
  local isNameConfirm = view.phase == "name_confirm"
  local isFinalDialogue = view.phase == "final_dialogue"
  local isGenderQuestion = view.phase == "gender_question"
  local selectorActive = view.phase == "gender_select" or view.phase == "gender_confirm"
  local compositionActive = selectorActive
    or view.phase == "gender_composition_transition"
    or compositionProgress ~= nil and compositionProgress > 0
  if compositionActive then
    assertFiniteProgress(compositionProgress, "Oak gender composition progress is invalid")
  end
  local oakRegion, selectorRegion
  local nameStage, nameOakRegion, nameChoiceRegion
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
    nameStage, nameOakRegion, nameChoiceRegion = OakSceneLayout.nameStageAndRegions(sceneContent, assert(dialogue), gap)
    local nameOakRect = OakSceneLayout.composedOakRect(assert(ordinarySubject), assert(subjectWidget), nameOakRegion, 1)
    if isNameForward then
      selectedSubject = OakSceneLayout.interpolateSubjectRect(genderOakRect, nameOakRect, assert(nameProgress))
    elseif isNameReturn then
      selectedSubject = OakSceneLayout.interpolateSubjectRect(nameOakRect, genderOakRect, 1 - assert(nameProgress))
    else
      selectedSubject = nameOakRect
    end
    oakRegion, selectorRegion = nameOakRegion, nameChoiceRegion
  elseif compositionActive then
    local compositionHost = scene
    if dialogue ~= nil then
      compositionHost = OakSceneLayout.aboveDialogue(scene, dialogue, gap)
    end
    oakRegion, selectorRegion = OakSceneLayout.selectorRegions(compositionHost, gap)
    if subjectId == "oak" and ordinarySubject and subjectWidget then
      selectedSubject =
        OakSceneLayout.composedOakRect(ordinarySubject, subjectWidget, oakRegion, assert(compositionProgress))
    end
  end
  return selectedSubject, oakRegion, selectorRegion, nameStage, nameChoiceRegion, selectorActive
end

local function profileLayout(
  result,
  view,
  selectorActive,
  selectorRegion,
  reference,
  manifest,
  sceneContent,
  gap,
  nameStage,
  nameChoiceRegion
)
  if selectorActive then
    local selectorCanvas = canvasForRegion(assert(selectorRegion), reference)
    local genderSlots = OakProfileLayout.genderSelectionEntries(selectorCanvas, manifest)
    if view.phase == "gender_select" then
      result.genderButtons = genderSlots
    else
      local focus = view.genderFocus == 0 and 0 or 1
      local selected = assert(genderSlots[focus])
      local opposite = assert(genderSlots[1 - focus])
      result.selectedProfileButton = selected
      if view.confirmationChoice then
        result.confirmationButtons = OakProfileLayout.genderConfirmationChoices(opposite.rect)
      end
    end
  end
  if view.phase == "name_confirm" and view.confirmationChoice and view.confirmationChoice.kind == "name" then
    result.confirmationButtons = OakProfileLayout.nameConfirmationEntries(assert(nameStage), assert(nameChoiceRegion))
  end
  if view.phase == "name_edit" then
    result.nameKeys, result.namePreview = OakProfileLayout.nameEditor(sceneContent, gap, view, clamp)
    result.nameGrid = result.nameKeys
  end
end

---@param width number
---@param height number
---@param view table<string, unknown>
---@param glyphs string[]
---@param manifest table<string, unknown>
---@return OakIntroStateLayout
function OakIntroLayout.compute(width, height, view, glyphs, manifest)
  assert(type(width) == "number" and width == width and width > 0, "Oak viewport width is invalid")
  assert(type(height) == "number" and height == height and height > 0, "Oak viewport height is invalid")
  assert(type(view) == "table" and type(glyphs) == "table", "Oak layout requires view and glyphs")
  assert(
    type(manifest) == "table" and type(manifest.sourceReference) == "table",
    "Oak layout requires source reference"
  )
  local reference = manifest.sourceReference
  assert(reference.width > 0 and reference.height > 0, "Oak source reference is invalid")
  local minimum = math.min(width, height)
  local inset = math.min(12, math.floor(minimum * 0.035 + 0.5), math.max(0, math.floor((minimum - 1) / 2)))
  local safeFrame = rect(inset, inset, width - inset * 2, height - inset * 2)
  local gap = math.min(8, math.max(0, math.floor(minimum * 0.02 + 0.5)))
  local mode = OakSceneLayout.mode(view)
  local dialogue = OakSceneLayout.dialogue(safeFrame, mode.reservesDialogue)
  local scene, sceneContent = OakSceneLayout.sceneRegions(width, safeFrame)
  local result ---@type OakIntroStateLayout
  result = {
    viewport = rect(0, 0, width, height),
    safeFrame = safeFrame,
    scene = scene,
    stage = scene,
    stageContent = sceneContent,
    dialogue = dialogue,
    message = dialogue and dialogue.outerRect or scene,
    nameGrid = {},
    nameKeys = {},
    genderFocus = view.genderFocus,
  }
  local subjectId = view.primaryWidget
  if subjectId == nil and view.visual ~= "background" then
    subjectId = view.visual
  end
  local canvas = OakSceneLayout.sourceCanvas(scene, reference)
  result.sourceCanvas = canvas
  local subjectWidget
  local ordinarySubject
  if subjectId ~= nil then
    subjectWidget = widget(manifest, subjectId)
    local visibleSourceX = subjectId == "oak" and -(view.oakBgScrollX or 0) or 0
    ordinarySubject = OakSceneLayout.sourceWidgetRect(subjectWidget, canvas, visibleSourceX)
  end
  local selectedSubject, oakRegion, selectorRegion, nameStage, nameChoiceRegion, selectorActive =
    subjectLayout(view, scene, sceneContent, gap, dialogue, subjectId, subjectWidget, ordinarySubject)
  result.subject = selectedSubject
  result.oakRegion = oakRegion
  result.selectorRegion = selectorRegion
  if view.revealWidget then
    local revealWidget = widget(manifest, view.revealWidget)
    result.revealCanvas = canvas
    result.reveal = OakSceneLayout.revealRect(revealWidget, canvas)
  end
  profileLayout(
    result,
    view,
    selectorActive,
    selectorRegion,
    reference,
    manifest,
    sceneContent,
    gap,
    nameStage,
    nameChoiceRegion
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
