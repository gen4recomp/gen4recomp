-- Pure common scene, dialogue, and Oak placement geometry for Oak intro.

local OakSceneLayout = {}

local function rect(x, y, width, height)
  assert(width > 0 and height > 0, "Oak layout rectangle must be positive")
  return { x = x, y = y, width = width, height = height }
end

local function canvasForRegion(region, reference)
  local scale = math.min(region.width / reference.width, region.height / reference.height)
  local origin = {
    x = region.x + (region.width - reference.width * scale) / 2,
    y = region.y + (region.height - reference.height * scale) / 2,
  }
  assert(scale > 0, "source-canvas scale must be positive")
  return { scale = scale, origin = origin }
end

function OakSceneLayout.sourceCanvas(scene, reference)
  local canvas = canvasForRegion(scene, reference)
  canvas.scene = scene
  canvas.reference = reference
  return canvas
end

local function canvasPoint(canvas, sourcePoint)
  return {
    x = canvas.origin.x + sourcePoint.x * canvas.scale,
    y = canvas.origin.y + sourcePoint.y * canvas.scale,
  }
end

function OakSceneLayout.sourceWidgetRect(widget, canvas, displaceX, displaceY)
  local sourceBounds = assert(widget.sourceBounds, "Oak widget source bounds are missing")
  local anchorSource = {
    x = sourceBounds.x + widget.anchor.x + (displaceX or 0),
    y = sourceBounds.y + widget.anchor.y + (displaceY or 0),
  }
  local hostAnchor = canvasPoint(canvas, anchorSource)
  return {
    x = hostAnchor.x - widget.anchor.x * canvas.scale,
    y = hostAnchor.y - widget.anchor.y * canvas.scale,
    width = widget.width * canvas.scale,
    height = widget.height * canvas.scale,
    scale = canvas.scale,
  }
end

function OakSceneLayout.revealRect(widget, canvas)
  local hostCenter = canvasPoint(canvas, assert(widget.sourceCenter, "Oak reveal source center is missing"))
  return {
    x = hostCenter.x - widget.anchor.x * canvas.scale,
    y = hostCenter.y - widget.anchor.y * canvas.scale,
    width = widget.width * canvas.scale,
    height = widget.height * canvas.scale,
    scale = canvas.scale,
  }
end

function OakSceneLayout.mappedRect(canvas, source)
  return {
    x = canvas.origin.x + source.x * canvas.scale,
    y = canvas.origin.y + source.y * canvas.scale,
    width = source.width * canvas.scale,
    height = source.height * canvas.scale,
  }
end

function OakSceneLayout.sourceCenteredWidget(widget, canvas)
  local hostCenter = canvasPoint(canvas, assert(widget.sourceCenter, "Oak selector source center is missing"))
  return {
    x = hostCenter.x - widget.anchor.x * canvas.scale,
    y = hostCenter.y - widget.anchor.y * canvas.scale,
    width = widget.width * canvas.scale,
    height = widget.height * canvas.scale,
    scale = canvas.scale,
  }
end

function OakSceneLayout.dialogue(safeFrame, reservesDialogue)
  if not reservesDialogue then
    return nil
  end
  local scale = math.min(safeFrame.width / 256, safeFrame.height * 0.28 / 48, 5)
  local outerWidth, outerHeight = 256 * scale, 48 * scale
  return {
    outerRect = rect(
      safeFrame.x + (safeFrame.width - outerWidth) / 2,
      safeFrame.y + safeFrame.height - outerHeight,
      outerWidth,
      outerHeight
    ),
    scale = scale,
  }
end

function OakSceneLayout.sceneRegions(width, safeFrame)
  local scene = rect(0, safeFrame.y, width, safeFrame.height)
  local contentWidth = math.min(scene.width, 1120)
  local sceneContent = rect(scene.x + (scene.width - contentWidth) / 2, scene.y, contentWidth, scene.height)
  return scene, sceneContent
end

function OakSceneLayout.nameStageAndRegions(sceneContent, dialogue, gap)
  local nameStage =
    rect(sceneContent.x, sceneContent.y, sceneContent.width, dialogue.outerRect.y - gap - sceneContent.y)
  local oakWidth = (nameStage.width - gap) * 0.46
  local choiceWidth = nameStage.width - oakWidth - gap
  return nameStage,
    rect(nameStage.x, nameStage.y, oakWidth, nameStage.height),
    rect(nameStage.x + oakWidth + gap, nameStage.y, choiceWidth, nameStage.height)
end

-- The usable scene above a reserved dialogue box: the full scene width from
-- the scene top down to a gap above the dialogue. Interactive composition
-- regions shrink into this host so the dialogue never overlays them.
function OakSceneLayout.aboveDialogue(scene, dialogue, gap)
  assert(dialogue ~= nil and dialogue.outerRect ~= nil, "Oak dialogue geometry is required")
  local bottom = dialogue.outerRect.y - gap
  local height = bottom - scene.y
  assert(height > 0, "Oak scene above dialogue must be positive")
  return rect(scene.x, scene.y, scene.width, height)
end

function OakSceneLayout.mode(view)
  local phase = view.phase
  return {
    reservesDialogue = view.dialogue ~= nil
      or phase == "name_confirm"
      or phase == "name_composition_transition"
      or phase == "name_composition_return"
      or phase == "name_prompt"
      or phase == "name_launch_wait"
      or phase == "final_dialogue"
      or (phase == "gender_question" and view.nameCompositionProgress ~= nil and view.nameCompositionProgress > 0)
      or phase == "gender_composition_transition"
      or phase == "gender_select"
      or phase == "gender_confirm"
      or phase == "greeting"
      or phase == "oak_welcome"
      or phase == "oak_world_inhabited"
      or phase == "oak_live_alongside"
      or phase == "oak_tell_about_yourself",
    selectorActive = phase == "gender_select" or phase == "gender_confirm",
    nameForward = phase == "name_composition_transition",
    nameReturn = phase == "name_composition_return",
    nameConfirm = phase == "name_confirm",
    finalDialogue = phase == "final_dialogue",
    genderQuestion = phase == "gender_question",
  }
end

function OakSceneLayout.selectorRegions(safeFrame, gap)
  gap = math.min(gap, math.min(safeFrame.width, safeFrame.height) / 2)
  if safeFrame.width >= safeFrame.height * 1.15 then
    local oakWidth = (safeFrame.width - gap) * 0.46
    return rect(safeFrame.x, safeFrame.y, oakWidth, safeFrame.height),
      rect(safeFrame.x + oakWidth + gap, safeFrame.y, safeFrame.width - oakWidth - gap, safeFrame.height)
  end
  local oakHeight = (safeFrame.height - gap) * 0.42
  return rect(safeFrame.x, safeFrame.y, safeFrame.width, oakHeight),
    rect(safeFrame.x, safeFrame.y + oakHeight + gap, safeFrame.width, safeFrame.height - oakHeight - gap)
end

function OakSceneLayout.composedOakRect(startRect, oak, oakRegion, progress)
  local targetScale = math.min(startRect.scale, oakRegion.width / oak.width, oakRegion.height / oak.height)
  local targetWidth, targetHeight = oak.width * targetScale, oak.height * targetScale
  local targetX = oakRegion.x + (oakRegion.width - targetWidth) / 2
  local targetY = oakRegion.y + (oakRegion.height - targetHeight) / 2
  local scale = startRect.scale + (targetScale - startRect.scale) * progress
  return {
    x = startRect.x + (targetX - startRect.x) * progress,
    y = startRect.y + (targetY - startRect.y) * progress,
    width = oak.width * scale,
    height = oak.height * scale,
    scale = scale,
  }
end

function OakSceneLayout.interpolateSubjectRect(from, to, progress)
  assert(
    type(progress) == "number"
      and progress == progress
      and progress > -math.huge
      and progress < math.huge
      and progress >= 0
      and progress <= 1,
    "Oak subject interpolation progress is invalid"
  )
  assert(from.scale > 0 and to.scale > 0, "Oak subject interpolation scale is invalid")
  return {
    x = from.x + (to.x - from.x) * progress,
    y = from.y + (to.y - from.y) * progress,
    width = from.width + (to.width - from.width) * progress,
    height = from.height + (to.height - from.height) * progress,
    scale = from.scale + (to.scale - from.scale) * progress,
  }
end

return OakSceneLayout
