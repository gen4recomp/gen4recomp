local Assert = require("tests.support.Assert")
local OakIntroLayout = require("game.hgss.src.newgame.OakIntroLayout")
local PixelScale = require("libs.ui.src.PixelScale")

local T = { tests = {} }

local function compute(width, height, view, glyphs, manifestData, preferredScale)
  local resolvedPreferredScale = preferredScale or math.max(1, math.floor(height / 192 + 0.5))
  return OakIntroLayout.compute(width, height, view, glyphs, manifestData, resolvedPreferredScale)
end

local function computeForHost(width, height, view, glyphs, manifestData)
  local bounds = { x = 0, y = 0, width = width, height = height }
  local preferredScale = math.max(1, math.floor(height / 192 + 0.5))
  local scale = PixelScale.fitPreferred(bounds, 256, 192, preferredScale)
  local surface = PixelScale.cover(bounds, scale)
  return OakIntroLayout.compute(
    surface.logicalViewport.width,
    surface.logicalViewport.height,
    view,
    glyphs,
    manifestData,
    scale
  ),
    surface
end

local function logicalHostMetric(physicalPixels, scale)
  return math.floor(physicalPixels / scale + 0.5)
end

local function widget(width, height, anchor, sourceBounds)
  return {
    width = width,
    height = height,
    anchor = anchor,
    sourceBounds = sourceBounds,
    frames = {
      { width = width, height = height, duration = 1, anchor = anchor },
    },
  }
end

local function manifestWithWidth(sourceWidth)
  local data = {
    schemaVersion = 9,
    variant = "heartgold",
    sourceReference = { width = sourceWidth, height = 192 },
    background = { width = sourceWidth, height = 192, sampling = "linear" },
    widgets = {
      oak = widget(80, 100, { x = 20, y = 100 }, { x = 20, y = 30, width = 80, height = 100 }),
      male = widget(96, 120, { x = 24, y = 110 }, { x = 36, y = 24, width = 96, height = 120 }),
      female = widget(88, 116, { x = 22, y = 108 }, { x = 48, y = 28, width = 88, height = 116 }),
      ball_open = widget(40, 30, { x = 20, y = 30 }, { x = 140, y = 50, width = 40, height = 30 }),
      marill = widget(40, 30, { x = 20, y = 30 }, { x = 140, y = 50, width = 40, height = 30 }),
      gender_male = widget(40, 60, { x = 20, y = 30 }, { x = 0, y = 0, width = 40, height = 60 }),
      gender_female = widget(40, 60, { x = 20, y = 30 }, { x = 0, y = 0, width = 40, height = 60 }),
      confirmation_yes = widget(120, 56, { x = 0, y = 0 }, { x = 0, y = 0, width = 120, height = 56 }),
      confirmation_no = widget(120, 56, { x = 0, y = 0 }, { x = 0, y = 0, width = 120, height = 56 }),
    },
  }
  data.widgets.ball_open.sourceCenter = { x = 160, y = 80 }
  data.widgets.marill.sourceCenter = { x = 160, y = 80 }
  data.widgets.gender_male.sourceCenter = { x = 64, y = 104 }
  data.widgets.gender_female.sourceCenter = { x = 192, y = 104 }
  data.widgets.confirmation_yes.contentRect = { x = 8, y = 16, width = 104, height = 24 }
  data.widgets.confirmation_no.contentRect = { x = 8, y = 16, width = 104, height = 24 }
  data.genderSelector = {
    defaultTone = { r = 100, g = 101, b = 102 },
    buttons = {
      male = {
        bounds = { x = 18, y = 25, width = 93, height = 148 },
      },
      female = {
        bounds = { x = 144, y = 25, width = 95, height = 148 },
      },
    },
  }

  return data
end

local function manifest()
  return manifestWithWidth(256)
end

local function profileManifest()
  local data = manifest()
  data.widgets.male = widget(96, 120, { x = 24, y = 110 }, { x = 36, y = 24, width = 96, height = 120 })
  data.widgets.female = widget(88, 116, { x = 22, y = 108 }, { x = 48, y = 28, width = 88, height = 116 })
  data.widgets.shrink_male = widget(44, 68, { x = 12, y = 62 }, { x = 142, y = 70, width = 44, height = 68 })
  data.widgets.shrink_female = widget(40, 64, { x = 11, y = 58 }, { x = 150, y = 72, width = 40, height = 64 })
  return data
end

local function ordinaryView(sourceBgScrollX)
  return {
    phase = "oak_world_inhabited",
    visual = "oak",
    primaryWidget = "oak",
    revealWidget = "ball_open",
    oakBgScrollX = sourceBgScrollX,
  }
end

local function compositionView(progress, phase)
  return {
    phase = phase or "gender_composition_transition",
    visual = "oak",
    primaryWidget = "oak",
    genderFocus = 0,
    genderCompositionProgress = progress,
    oakBgScrollX = 0,
  }
end

---@param region { x: number, y: number, scale: number }
---@param anchor { x: number, y: number }
---@return { x: number, y: number }
local function point(region, anchor)
  return {
    x = region.x + anchor.x * region.scale,
    y = region.y + anchor.y * region.scale,
  }
end

---@param inner OakIntroStateRectangle
---@param outer OakIntroStateRectangle
---@return boolean
local function inside(inner, outer)
  local epsilon = 1e-9
  return inner.x >= outer.x - epsilon
    and inner.y >= outer.y - epsilon
    and inner.x + inner.width <= outer.x + outer.width + epsilon
    and inner.y + inner.height <= outer.y + outer.height + epsilon
end

---@param first OakIntroStateRectangle
---@param second OakIntroStateRectangle
---@return boolean
local function disjoint(first, second)
  return first.x + first.width <= second.x
    or second.x + second.width <= first.x
    or first.y + first.height <= second.y
    or second.y + second.height <= first.y
end

local function assertInterpolated(actual, from, to, progress)
  local expectedX = from.x + (to.x - from.x) * progress
  local expectedY = from.y + (to.y - from.y) * progress
  local expectedScale = from.scale + (to.scale - from.scale) * progress
  local expectedWidth = from.width + (to.width - from.width) * progress
  local expectedHeight = from.height + (to.height - from.height) * progress
  Assert.near(actual.x, expectedX, 1e-4)
  Assert.near(actual.y, expectedY, 1e-4)
  Assert.near(actual.scale, expectedScale, 1e-6)
  Assert.near(actual.width, expectedWidth, 1e-4)
  Assert.near(actual.height, expectedHeight, 1e-4)
end

function T.tests.wide_host_metrics_stay_in_physical_pixel_policy_after_logical_conversion()
  local layout, surface = computeForHost(1710, 895, compositionView(1, "gender_select"), {}, manifest())
  local scale = surface.scale
  Assert.equal(layout.safeFrame.x, logicalHostMetric(12, scale))
  Assert.equal(layout.stageContent.width, logicalHostMetric(1120, scale))
  Assert.equal(layout.selectorRegion.x - (layout.oakRegion.x + layout.oakRegion.width), logicalHostMetric(8, scale))
end

function T.tests.odd_logical_viewport_places_dialogue_on_its_pixel_grid()
  local layout = computeForHost(1705, 895, ordinaryView(0), {}, manifest())
  Assert.equal(layout.dialogue.outerRect.x, math.floor(layout.dialogue.outerRect.x))
  Assert.equal(layout.dialogue.outerRect.y, math.floor(layout.dialogue.outerRect.y))
end

function T.tests.ordinary_source_group_moves_as_one_unit_above_reserved_dialogue()
  local data = manifest()
  data.widgets.oak.height = 200
  data.widgets.oak.sourceBounds.height = 200
  local reserved = computeForHost(1710, 895, ordinaryView(0), {}, data)
  local unreserved = computeForHost(1710, 895, {
    phase = "intro",
    visual = "oak",
    primaryWidget = "oak",
    revealWidget = "ball_open",
    oakBgScrollX = 0,
  }, {}, data)
  Assert.isTrue(disjoint(reserved.subject, reserved.dialogue.outerRect))
  Assert.isTrue(disjoint(reserved.reveal, reserved.dialogue.outerRect))
  local subjectDelta = reserved.subject.y - unreserved.subject.y
  local revealDelta = reserved.reveal.y - unreserved.reveal.y
  Assert.equal(subjectDelta, math.floor(subjectDelta))
  Assert.equal(revealDelta, subjectDelta)
  Assert.near(
    reserved.subject.y - reserved.reveal.y,
    unreserved.subject.y - unreserved.reveal.y,
    1e-9,
    "subject and reveal source geometry must retain their relative placement"
  )
end

function T.tests.source_points_and_slide_direction_survive_responsive_hosts()
  local data = manifest()
  for _, size in ipairs({ { 1024, 768 }, { 1920, 1080 }, { 390, 844 } }) do
    local centered = compute(size[1], size[2], ordinaryView(0), {}, data)
    local shifted = compute(size[1], size[2], ordinaryView(-52), {}, data)
    local scene = assert(centered.scene)
    local sourceCanvas = assert(centered.sourceCanvas)
    local canvasScale = sourceCanvas.scale
    local canvasOriginX = sourceCanvas.origin.x
    local canvasOriginY = sourceCanvas.origin.y
    local oakPoint = point(centered.subject, data.widgets.oak.anchor)
    Assert.near(oakPoint.x, canvasOriginX + 40 * canvasScale, 1e-6)
    Assert.near(oakPoint.y, canvasOriginY + 130 * canvasScale, 1e-6)
    local revealPoint = point(centered.reveal, data.widgets.ball_open.anchor)
    Assert.near(revealPoint.x, canvasOriginX + 160 * canvasScale, 1e-6)
    Assert.near(revealPoint.y, canvasOriginY + 80 * canvasScale, 1e-6)
    local expectedDisplacement = 52 * canvasScale
    Assert.near(point(shifted.subject, data.widgets.oak.anchor).x - oakPoint.x, expectedDisplacement, 1e-6)
    Assert.equal(centered.subject.scale, shifted.subject.scale)
    local shiftedRevealPoint = point(shifted.reveal, data.widgets.ball_open.anchor)
    Assert.near(shiftedRevealPoint.x, revealPoint.x, 1e-6)
    Assert.near(shiftedRevealPoint.y, revealPoint.y, 1e-6)
    Assert.isTrue(inside(centered.subject, scene))
    Assert.isTrue(inside(centered.reveal, scene))
  end
end

function T.tests.slide_progress_is_monotonic_right_then_monotonic_left()
  local data = manifest()
  for _, size in ipairs({ { 1024, 768 }, { 390, 844 } }) do
    local baseX = point(compute(size[1], size[2], ordinaryView(0), {}, data).subject, data.widgets.oak.anchor).x
    local previousX = baseX
    for _, offset in ipairs({ -10, -20, -30, -40, -52 }) do
      local layout = compute(size[1], size[2], ordinaryView(offset), {}, data)
      local x = point(layout.subject, data.widgets.oak.anchor).x
      Assert.isTrue(x >= previousX, "source scroll toward -52 must move host X right")
      previousX = x
    end
    local fullyShiftedX = previousX
    Assert.isTrue(fullyShiftedX > baseX, "the fully scrolled subject must be to the right of the base position")

    previousX = fullyShiftedX
    for _, offset in ipairs({ -40, -30, -20, -10, 0 }) do
      local layout = compute(size[1], size[2], ordinaryView(offset), {}, data)
      local x = point(layout.subject, data.widgets.oak.anchor).x
      Assert.isTrue(x <= previousX, "the return scroll must move host X left")
      previousX = x
    end
    Assert.near(previousX, baseX, 1e-6)
    -- Slide does not affect scale, reveal geometry, or scene geometry
    local slideLayout = compute(size[1], size[2], ordinaryView(-30), {}, data)
    local baseLayout = compute(size[1], size[2], ordinaryView(0), {}, data)
    Assert.equal(slideLayout.subject.scale, baseLayout.subject.scale)
    Assert.deepEqual(slideLayout.reveal, baseLayout.reveal)
    Assert.deepEqual(slideLayout.scene, baseLayout.scene)
  end
end

function T.tests.tall_host_keeps_source_order_and_all_layout_rectangles_inside_viewport()
  local data = manifest()
  local layout = compute(803, 992, ordinaryView(0), {}, data)
  Assert.deepEqual(layout.viewport, { x = 0, y = 0, width = 803, height = 992 })
  Assert.isTrue(inside(layout.subject, layout.viewport))
  Assert.isTrue(inside(layout.reveal, layout.viewport))
  Assert.isTrue(inside(layout.dialogue.outerRect, layout.viewport))
  local oakPoint = point(layout.subject, data.widgets.oak.anchor)
  local revealPoint = point(layout.reveal, data.widgets.ball_open.anchor)
  Assert.isTrue(oakPoint.x < revealPoint.x)
  local sourceCanvas = assert(layout.sourceCanvas)
  local canvasScale = sourceCanvas.scale
  local canvasOriginX = sourceCanvas.origin.x
  Assert.near((oakPoint.x - canvasOriginX) / canvasScale, 40, 1e-9)
  Assert.near((revealPoint.x - canvasOriginX) / canvasScale, 160, 1e-9)
end

function T.tests.gender_selection_maps_source_geometry_and_centers_portraits()
  local data = manifest()
  for _, size in ipairs({ { 1920, 1080 }, { 390, 844 } }) do
    local layout = compute(size[1], size[2], {
      phase = "gender_select",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = 0,
      genderCompositionProgress = 1,
      oakBgScrollX = 0,
    }, {}, data)
    Assert.deepEqual(layout.viewport, { x = 0, y = 0, width = size[1], height = size[2] })
    Assert.isTrue(inside(layout.oakRegion, layout.viewport))
    Assert.isTrue(inside(layout.selectorRegion, layout.viewport))
    Assert.isTrue(disjoint(layout.oakRegion, layout.selectorRegion))
    for gender = 0, 1 do
      local id = gender == 0 and "gender_male" or "gender_female"
      local item = assert(layout.genderButtons[gender])
      local card = item.rect
      local source = data.genderSelector.buttons[gender == 0 and "male" or "female"].bounds
      local canvasScale = item.scale
      local canvasOriginX = layout.selectorRegion.x + (layout.selectorRegion.width - 256 * canvasScale) / 2
      local canvasOriginY = layout.selectorRegion.y + (layout.selectorRegion.height - 192 * canvasScale) / 2
      Assert.near((card.x - canvasOriginX) / canvasScale, source.x)
      Assert.near(card.width / canvasScale, source.width)
      Assert.near((card.y + card.height - canvasOriginY) / canvasScale, source.y + source.height)

      local portrait = item.portraitRect
      local widgetValue = data.widgets[id]
      local center = widgetValue.sourceCenter
      Assert.near((portrait.x + widgetValue.anchor.x * canvasScale - canvasOriginX) / canvasScale, center.x)
      Assert.near((portrait.y + widgetValue.anchor.y * canvasScale - canvasOriginY) / canvasScale, center.y)
      Assert.near(portrait.width / canvasScale, widgetValue.width)
      Assert.near(portrait.height / canvasScale, widgetValue.height)
    end
    Assert.isTrue(disjoint(layout.genderButtons[0].rect, layout.genderButtons[1].rect))
  end
end

function T.tests.gender_confirmation_maps_selected_card_and_source_side_choices()
  local data = manifest()
  for selected, gender in pairs({ [0] = "male", [1] = "female" }) do
    local layout = compute(800, 600, {
      phase = "gender_confirm",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = selected,
      genderCompositionProgress = 1,
      confirmationChoice = { kind = "gender", selected = 0 },
    }, {}, data)
    local profile = assert(layout.selectedProfileButton)
    Assert.equal(profile.key, gender)

    local choices = assert(layout.confirmationButtons)
    local previousBottom
    for choice, key in pairs({ [0] = "yes", [1] = "no" }) do
      local entry = assert(choices[choice])
      Assert.equal(entry.key, key)
      Assert.isTrue(entry.rect.width > 0 and entry.rect.height > 0)
      if previousBottom then
        Assert.near((entry.rect.y - previousBottom) / entry.scale, 8)
      end
      previousBottom = entry.rect.y + entry.rect.height
    end
    Assert.isTrue(inside(profile.rect, layout.selectorRegion))
    Assert.isTrue(inside(choices[0].rect, layout.selectorRegion))
    Assert.isTrue(inside(choices[1].rect, layout.selectorRegion))
    if gender == "male" then
      Assert.isTrue(profile.rect.x + profile.rect.width <= choices[0].rect.x)
    else
      Assert.isTrue(choices[0].rect.x + choices[0].rect.width <= profile.rect.x)
    end
  end
end

function T.tests.gender_confirmation_keeps_selected_card_geometry_stable()
  local data = manifest()
  for _, size in ipairs({ { 800, 600 }, { 1920, 1080 }, { 390, 844 } }) do
    for focus = 0, 1 do
      local selected = compute(size[1], size[2], {
        phase = "gender_select",
        visual = "oak",
        primaryWidget = "oak",
        genderFocus = focus,
        genderCompositionProgress = 1,
        oakBgScrollX = 0,
      }, {}, data)
      local confirmed = compute(size[1], size[2], {
        phase = "gender_confirm",
        visual = "oak",
        primaryWidget = "oak",
        genderFocus = focus,
        genderCompositionProgress = 1,
        confirmationChoice = { kind = "gender", selected = 0 },
      }, {}, data)
      local card = assert(selected.genderButtons[focus])
      local profile = assert(confirmed.selectedProfileButton)
      Assert.equal(profile.key, card.key)
      Assert.deepEqual(profile.rect, card.rect)
      Assert.deepEqual(profile.portraitRect, card.portraitRect)
      Assert.equal(profile.scale, card.scale)
      Assert.deepEqual(profile.button, card.button)
      local opposite = assert(selected.genderButtons[1 - focus])
      local choices = assert(confirmed.confirmationButtons)
      local yes = assert(choices[0])
      local no = assert(choices[1])
      Assert.equal(yes.scale, no.scale)
      local choicesFit = opposite.rect.width >= 120 and opposite.rect.height >= 120
      if choicesFit then
        Assert.isTrue(
          inside(yes.rect, opposite.rect),
          string.format(
            "yes rect %.3f,%.3f %.3fx%.3f must fit opposite %.3f,%.3f %.3fx%.3f",
            yes.rect.x,
            yes.rect.y,
            yes.rect.width,
            yes.rect.height,
            opposite.rect.x,
            opposite.rect.y,
            opposite.rect.width,
            opposite.rect.height
          )
        )
        Assert.isTrue(inside(no.rect, opposite.rect))
        Assert.isTrue(inside(yes.rect, confirmed.selectorRegion))
        Assert.isTrue(inside(no.rect, confirmed.selectorRegion))
        Assert.isTrue(disjoint(profile.rect, yes.rect))
        Assert.isTrue(disjoint(profile.rect, no.rect))
        if card.key == "male" then
          Assert.isTrue(profile.rect.x + profile.rect.width <= yes.rect.x)
        else
          Assert.isTrue(yes.rect.x + yes.rect.width <= profile.rect.x)
        end
      else
        Assert.equal(yes.scale, 1, "small logical regions keep the minimum integer scale")
      end
      Assert.near((no.rect.y - (yes.rect.y + yes.rect.height)) / yes.scale, 8, 1e-6)
    end
  end
end

function T.tests.profile_controls_emit_final_rectangles_without_generic_button_geometry()
  local data = manifest()
  local layout = compute(800, 600, {
    phase = "gender_confirm",
    visual = "oak",
    primaryWidget = "oak",
    genderFocus = 0,
    genderCompositionProgress = 1,
    confirmationChoice = { kind = "gender", selected = 0 },
  }, {}, data)

  local profile = assert(layout.selectedProfileButton)
  local yes = assert(layout.confirmationButtons[0])
  local no = assert(layout.confirmationButtons[1])
  Assert.notNil(profile.rect, "selected profile presentation must expose its final rectangle")
  Assert.notNil(profile.portraitRect, "selected profile presentation must retain portrait geometry")
  Assert.notNil(yes.rect, "YES presentation must expose its final rectangle")
  Assert.notNil(no.rect, "NO presentation must expose its final rectangle")
  Assert.notNil(profile.button, "selected profile presentation must expose shared image button geometry")
  Assert.notNil(yes.button, "YES presentation must expose shared text button geometry")
  Assert.notNil(no.button, "NO presentation must expose shared text button geometry")
  Assert.isTrue(inside(profile.rect, layout.selectorRegion))
  Assert.isTrue(inside(yes.rect, layout.selectorRegion))
  Assert.isTrue(inside(no.rect, layout.selectorRegion))
  Assert.isTrue(OakIntroLayout.contains(yes.rect, yes.rect.x + yes.rect.width / 2, yes.rect.y + yes.rect.height / 2))
  Assert.isFalse(OakIntroLayout.contains(yes.rect, yes.rect.x + yes.rect.width, yes.rect.y + yes.rect.height / 2))
  Assert.equal(profile.button.rect.x, profile.rect.x)
  Assert.equal(yes.button.rect.x, yes.rect.x)
end

function T.tests.name_confirmation_layout_is_oak_left_with_vertical_stack()
  local data = manifest()
  for _, size in ipairs({ { 640, 480 }, { 800, 600 }, { 390, 844 } }) do
    local layout = compute(size[1], size[2], {
      phase = "name_confirm",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = 0,
      confirmationChoice = { kind = "name", selected = 0 },
      genderCompositionProgress = 1,
      nameCompositionProgress = 1,
      oakBgScrollX = 0,
    }, {}, data)
    Assert.notNil(layout.dialogue, "name_confirm must reserve dialogue at " .. size[1] .. "x" .. size[2])
    local oakRegion = assert(layout.oakRegion)
    local choiceRegion = assert(layout.selectorRegion)
    Assert.isTrue(oakRegion.x + oakRegion.width <= choiceRegion.x, "Oak region must be left of choice region")
    Assert.equal(oakRegion.y, choiceRegion.y)
    Assert.equal(oakRegion.height, choiceRegion.height)
    Assert.isTrue(inside(assert(layout.subject), oakRegion))
    local yes = assert(layout.confirmationButtons[0])
    local no = assert(layout.confirmationButtons[1])
    Assert.isTrue(inside(yes.rect, choiceRegion))
    Assert.isTrue(inside(no.rect, choiceRegion))
    Assert.isTrue(disjoint(yes.rect, layout.dialogue.outerRect))
    Assert.isTrue(disjoint(no.rect, layout.dialogue.outerRect))
    Assert.isTrue(disjoint(oakRegion, layout.dialogue.outerRect))
    Assert.isTrue(disjoint(choiceRegion, layout.dialogue.outerRect))
    Assert.equal(yes.scale, no.scale)
    Assert.equal(yes.rect.x, no.rect.x)
    Assert.equal(yes.rect.width, no.rect.width)
    Assert.equal(yes.rect.height, no.rect.height)
    Assert.isTrue(yes.rect.y + yes.rect.height <= no.rect.y)
    Assert.near((no.rect.y - (yes.rect.y + yes.rect.height)) / yes.scale, 8, 1e-6)
    Assert.equal(yes.key, "yes")
    Assert.equal(no.key, "no")
  end
end

function T.tests.name_confirmation_oak_does_not_jump_when_choices_activate()
  local data = manifest()
  for _, size in ipairs({ { 640, 480 }, { 800, 600 }, { 390, 844 } }) do
    local withoutChoice = compute(size[1], size[2], {
      phase = "name_confirm",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = 1,
      genderCompositionProgress = 1,
      nameCompositionProgress = 1,
      oakBgScrollX = 0,
      dialogue = { message = "test", messageKey = "profile.name_confirm.female" },
    }, {}, data)
    local withChoice = compute(size[1], size[2], {
      phase = "name_confirm",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = 1,
      confirmationChoice = { kind = "name", selected = 0 },
      genderCompositionProgress = 1,
      nameCompositionProgress = 1,
      oakBgScrollX = 0,
      dialogue = { message = "test", messageKey = "profile.name_confirm.female" },
    }, {}, data)
    Assert.notNil(withoutChoice.dialogue)
    Assert.notNil(withChoice.dialogue)
    Assert.deepEqual(withoutChoice.dialogue.outerRect, withChoice.dialogue.outerRect)
    Assert.deepEqual(withoutChoice.oakRegion, withChoice.oakRegion)
    Assert.deepEqual(withoutChoice.selectorRegion, withChoice.selectorRegion)
    Assert.deepEqual(withoutChoice.subject, withChoice.subject)
    Assert.isNil(withoutChoice.confirmationButtons)
    Assert.notNil(withChoice.confirmationButtons)
  end
end

function T.tests.name_confirmation_dialogue_is_reserved_without_active_message()
  local data = manifest()
  local layout = compute(640, 480, {
    phase = "name_confirm",
    visual = "oak",
    primaryWidget = "oak",
    genderFocus = 0,
    genderCompositionProgress = 1,
    nameCompositionProgress = 1,
    oakBgScrollX = 0,
  }, {}, data)
  Assert.notNil(layout.dialogue)
  Assert.notNil(layout.oakRegion)
  Assert.notNil(layout.selectorRegion)
end

function T.tests.name_composition_rejects_invalid_progress_state()
  local data = manifest()
  local cases = {
    {
      label = "missing name progress in name_confirm",
      view = {
        phase = "name_confirm",
        visual = "oak",
        primaryWidget = "oak",
        genderFocus = 0,
        genderCompositionProgress = 1,
        oakBgScrollX = 0,
      },
    },
    {
      label = "premature progress in name_confirm",
      view = {
        phase = "name_confirm",
        visual = "oak",
        primaryWidget = "oak",
        genderFocus = 0,
        genderCompositionProgress = 1,
        nameCompositionProgress = 0.5,
        oakBgScrollX = 0,
      },
    },
    {
      label = "final_dialogue below 1",
      view = {
        phase = "final_dialogue",
        visual = "oak",
        primaryWidget = "oak",
        genderFocus = 0,
        genderCompositionProgress = 1,
        nameCompositionProgress = 0.5,
        oakBgScrollX = 0,
      },
    },
    {
      label = "missing progress in forward transition",
      view = {
        phase = "name_composition_transition",
        visual = "oak",
        primaryWidget = "oak",
        genderFocus = 0,
        genderCompositionProgress = 1,
        oakBgScrollX = 0,
      },
    },
    {
      label = "out of range progress in forward transition",
      view = {
        phase = "name_composition_transition",
        visual = "oak",
        primaryWidget = "oak",
        genderFocus = 0,
        genderCompositionProgress = 1,
        nameCompositionProgress = 1.5,
        oakBgScrollX = 0,
      },
    },
    {
      label = "missing progress in return transition",
      view = {
        phase = "name_composition_return",
        visual = "oak",
        primaryWidget = "oak",
        genderFocus = 0,
        genderCompositionProgress = 1,
        oakBgScrollX = 0,
      },
    },
  }
  for _, case in ipairs(cases) do
    Assert.throws(function()
      compute(640, 480, case.view, {}, data)
    end, case.label .. " must fail")
  end
end

function T.tests.gender_composition_interpolates_oak_into_the_contained_region()
  local data = manifest()
  local start = compute(1920, 1080, compositionView(0), {}, data)
  local middle = compute(1920, 1080, compositionView(0.5), {}, data)
  local final = compute(1920, 1080, compositionView(1, "gender_select"), {}, data)

  Assert.isTrue(inside(final.subject, final.oakRegion))
  Assert.isTrue(disjoint(final.oakRegion, final.selectorRegion))
  Assert.near(middle.subject.x, (start.subject.x + final.subject.x) / 2)
  Assert.near(middle.subject.y, (start.subject.y + final.subject.y) / 2)
  Assert.equal(middle.subject.scale, final.subject.scale)
  Assert.near(middle.subject.width, data.widgets.oak.width * middle.subject.scale)
  Assert.near(middle.subject.height, data.widgets.oak.height * middle.subject.scale)
end

function T.tests.gender_composition_uniformly_shrinks_oak_when_the_region_is_small()
  local data = manifest()
  data.widgets.oak.width = 400
  data.widgets.oak.height = 500
  local start = compute(390, 844, compositionView(0), {}, data)
  local final = compute(390, 844, compositionView(1, "gender_select"), {}, data)

  Assert.isTrue(final.subject.scale <= start.subject.scale)
  Assert.equal(final.subject.scale, 1, "small logical regions keep the minimum integer scale")
  Assert.near(final.subject.width, data.widgets.oak.width * final.subject.scale)
  Assert.near(final.subject.height, data.widgets.oak.height * final.subject.scale)
  Assert.near(final.subject.x + final.subject.width / 2, final.oakRegion.x + final.oakRegion.width / 2)
  Assert.near(final.subject.y + final.subject.height / 2, final.oakRegion.y + final.oakRegion.height / 2)
end

-- Full source scroll must inverse-transform to exactly the pinned -52 source
-- pixels under the uniform source-canvas scale, on every viewport shape --
-- not merely ones where the safe frame happens to be 4:3.
function T.tests.full_slide_inverse_transforms_to_exactly_fifty_two_source_pixels_on_every_viewport()
  local data = manifest()
  for _, size in ipairs({ { 390, 844 }, { 800, 600 }, { 1920, 1080 }, { 2560, 1080 } }) do
    local w, h = size[1], size[2]
    local atZero = compute(w, h, ordinaryView(0), {}, data)
    local atFull = compute(w, h, ordinaryView(-52), {}, data)
    local xZero = point(atZero.subject, data.widgets.oak.anchor).x
    local xFull = point(atFull.subject, data.widgets.oak.anchor).x
    local canvasScale = atZero.sourceCanvas.scale
    Assert.near(
      (xFull - xZero) / canvasScale,
      52,
      1e-6,
      "visible Oak displacement must equal +52 source pixels at " .. w .. "x" .. h
    )
    Assert.equal(atZero.subject.y, atFull.subject.y, "slide must not move Oak vertically")
    Assert.equal(atZero.subject.scale, atFull.subject.scale, "slide must not rescale Oak")
  end
end

function T.tests.slide_displacement_uses_manifest_reference_width_not_hardcoded_256()
  local data = manifestWithWidth(512)
  local centered = compute(1024, 768, ordinaryView(0), {}, data)
  local shifted = compute(1024, 768, ordinaryView(-52), {}, data)
  local canvasScale = centered.sourceCanvas.scale
  local expected = 52 * canvasScale
  Assert.near(
    point(shifted.subject, data.widgets.oak.anchor).x - point(centered.subject, data.widgets.oak.anchor).x,
    expected,
    1e-6
  )
end

function T.tests.profile_widgets_use_their_manifest_source_geometry()
  local data = profileManifest()
  for _, id in ipairs({ "male", "female", "shrink_male", "shrink_female" }) do
    local value = data.widgets[id]
    local layout = compute(800, 600, {
      phase = "final_full_art_hold",
      visual = id,
      primaryWidget = id,
      oakBgScrollX = 0,
    }, {}, data)
    local scale = layout.sourceCanvas.scale
    Assert.equal(layout.subject.width, value.width * scale)
    Assert.equal(layout.subject.height, value.height * scale)
    Assert.near(layout.subject.x, layout.sourceCanvas.origin.x + value.sourceBounds.x * scale, 1e-9)
    Assert.near(layout.subject.y, layout.sourceCanvas.origin.y + value.sourceBounds.y * scale, 1e-9)
  end
end

function T.tests.name_confirmation_scale_is_independent_of_gender()
  local data = manifest()
  for _, size in ipairs({ { 800, 600 }, { 640, 480 }, { 390, 844 } }) do
    local male = compute(size[1], size[2], {
      phase = "name_confirm",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = 0,
      confirmationChoice = { kind = "name", selected = 0 },
      genderCompositionProgress = 1,
      nameCompositionProgress = 1,
      oakBgScrollX = 0,
    }, {}, data)
    local female = compute(size[1], size[2], {
      phase = "name_confirm",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = 1,
      confirmationChoice = { kind = "name", selected = 1 },
      genderCompositionProgress = 1,
      nameCompositionProgress = 1,
      oakBgScrollX = 0,
    }, {}, data)
    local mYes = assert(male.confirmationButtons[0])
    local fYes = assert(female.confirmationButtons[0])
    local mNo = assert(male.confirmationButtons[1])
    local fNo = assert(female.confirmationButtons[1])
    Assert.equal(mYes.scale, fYes.scale)
    Assert.equal(mYes.rect.width, fYes.rect.width)
    Assert.equal(mYes.rect.height, fYes.rect.height)
    Assert.equal(mYes.rect.x, fYes.rect.x)
    Assert.equal(mNo.rect.x, fNo.rect.x)
    Assert.deepEqual(male.oakRegion, female.oakRegion)
    Assert.deepEqual(male.selectorRegion, female.selectorRegion)
  end
end

function T.tests.gender_cards_expose_image_button_geometry()
  local data = manifest()
  local layout = compute(800, 600, {
    phase = "gender_select",
    visual = "oak",
    primaryWidget = "oak",
    genderFocus = 0,
    genderCompositionProgress = 1,
    oakBgScrollX = 0,
  }, {}, data)
  for gender = 0, 1 do
    local entry = assert(layout.genderButtons[gender])
    Assert.notNil(entry.button)
    Assert.equal(entry.button.rect.x, entry.rect.x)
    Assert.equal(entry.button.rect.width, entry.rect.width)
    Assert.notNil(entry.portraitRect)
    Assert.isTrue(entry.portraitRect.x >= entry.rect.x)
    Assert.isTrue(entry.portraitRect.y >= entry.rect.y)
  end
end

function T.tests.name_forward_transition_interpolates_directly_between_gender_and_name_endpoints()
  local data = manifest()
  for _, size in ipairs({ { 640, 480 }, { 390, 844 } }) do
    local w, h = size[1], size[2]
    local genderEndpoint = compute(w, h, {
      phase = "gender_select",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = 0,
      genderCompositionProgress = 1,
      nameCompositionProgress = 0,
      oakBgScrollX = 0,
    }, {}, data)
    local nameEndpoint = compute(w, h, {
      phase = "name_confirm",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = 0,
      confirmationChoice = { kind = "name", selected = 0 },
      genderCompositionProgress = 1,
      nameCompositionProgress = 1,
      oakBgScrollX = 0,
    }, {}, data)
    local forwarded = compute(w, h, {
      phase = "name_composition_transition",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = 0,
      genderCompositionProgress = 1,
      nameCompositionProgress = 0.5,
      oakBgScrollX = 0,
    }, {}, data)
    local genderSubject = assert(genderEndpoint.subject, "gender endpoint must have subject at " .. w .. "x" .. h)
    local nameSubject = assert(nameEndpoint.subject, "name endpoint must have subject at " .. w .. "x" .. h)
    local forwardedSubject = assert(forwarded.subject, "forward transition must have subject at " .. w .. "x" .. h)
    assertInterpolated(forwardedSubject, genderSubject, nameSubject, 0.5)
    Assert.deepEqual(forwarded.oakRegion, nameEndpoint.oakRegion)
    Assert.deepEqual(forwarded.selectorRegion, nameEndpoint.selectorRegion)
  end
end

function T.tests.rejected_name_return_interpolates_back_to_gender_endpoint()
  local data = manifest()
  for _, size in ipairs({ { 640, 480 }, { 390, 844 } }) do
    local w, h = size[1], size[2]
    local nameEndpoint = compute(w, h, {
      phase = "name_confirm",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = 0,
      confirmationChoice = { kind = "name", selected = 0 },
      genderCompositionProgress = 1,
      nameCompositionProgress = 1,
      oakBgScrollX = 0,
    }, {}, data)
    local genderEndpoint = compute(w, h, {
      phase = "gender_select",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = 0,
      genderCompositionProgress = 1,
      nameCompositionProgress = 0,
      oakBgScrollX = 0,
    }, {}, data)
    local returnMid = compute(w, h, {
      phase = "name_composition_return",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = 0,
      genderCompositionProgress = 1,
      nameCompositionProgress = 0.5,
      oakBgScrollX = 0,
    }, {}, data)
    local nameSubject = assert(nameEndpoint.subject)
    local genderSubject = assert(genderEndpoint.subject)
    local midSubject = assert(returnMid.subject)
    assertInterpolated(midSubject, nameSubject, genderSubject, 0.5)
    Assert.deepEqual(returnMid.oakRegion, nameEndpoint.oakRegion)
    Assert.deepEqual(returnMid.selectorRegion, nameEndpoint.selectorRegion)
  end
end

function T.tests.resize_recomputes_transition_endpoints_at_current_progress()
  local data = manifest()
  local progress = 0.4
  for _, viewport in ipairs({ { 640, 480 }, { 390, 844 } }) do
    local w, h = viewport[1], viewport[2]
    local genderEndpoint = compute(w, h, {
      phase = "gender_select",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = 0,
      genderCompositionProgress = 1,
      nameCompositionProgress = 0,
      oakBgScrollX = 0,
    }, {}, data)
    local nameEndpoint = compute(w, h, {
      phase = "name_confirm",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = 0,
      confirmationChoice = { kind = "name", selected = 0 },
      genderCompositionProgress = 1,
      nameCompositionProgress = 1,
      oakBgScrollX = 0,
    }, {}, data)
    local transition = compute(w, h, {
      phase = "name_composition_transition",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = 0,
      genderCompositionProgress = 1,
      nameCompositionProgress = progress,
      oakBgScrollX = 0,
    }, {}, data)
    assertInterpolated(
      assert(transition.subject),
      assert(genderEndpoint.subject),
      assert(nameEndpoint.subject),
      progress
    )
    Assert.isTrue(inside(assert(transition.subject), assert(transition.viewport)))
  end
  local first = compute(640, 480, {
    phase = "name_composition_transition",
    visual = "oak",
    primaryWidget = "oak",
    genderFocus = 0,
    genderCompositionProgress = 1,
    nameCompositionProgress = progress,
    oakBgScrollX = 0,
  }, {}, data)
  local second = compute(390, 844, {
    phase = "name_composition_transition",
    visual = "oak",
    primaryWidget = "oak",
    genderFocus = 0,
    genderCompositionProgress = 1,
    nameCompositionProgress = progress,
    oakBgScrollX = 0,
  }, {}, data)
  Assert.isTrue(
    first.subject.x ~= second.subject.x or first.subject.y ~= second.subject.y,
    "resize must recompute host coordinates"
  )
end

function T.tests.gender_answer_phases_reserve_dialogue_and_keep_controls_above_it()
  local data = manifest()
  for _, size in ipairs({ { 800, 600 }, { 390, 844 } }) do
    local w, h = size[1], size[2]
    local selectView = {
      phase = "gender_select",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = 0,
      genderCompositionProgress = 1,
      oakBgScrollX = 0,
    }
    local selectLayout = compute(w, h, selectView, {}, data)
    Assert.notNil(selectLayout.dialogue, "gender_select must reserve dialogue at " .. w .. "x" .. h)
    local dialogueRect = assert(selectLayout.dialogue).outerRect
    Assert.isTrue(inside(dialogueRect, selectLayout.viewport))
    Assert.isTrue(disjoint(assert(selectLayout.oakRegion), dialogueRect))
    Assert.isTrue(disjoint(assert(selectLayout.selectorRegion), dialogueRect))
    for gender = 0, 1 do
      local card = assert(selectLayout.genderButtons[gender])
      Assert.isTrue(disjoint(card.rect, dialogueRect))
      Assert.isTrue(inside(card.rect, selectLayout.viewport))
    end
    Assert.isTrue(inside(assert(selectLayout.subject), selectLayout.viewport))

    local confirmView = {
      phase = "gender_confirm",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = 0,
      genderCompositionProgress = 1,
      confirmationChoice = { kind = "gender", selected = 0 },
      oakBgScrollX = 0,
    }
    local confirmLayout = compute(w, h, confirmView, {}, data)
    Assert.notNil(confirmLayout.dialogue, "gender_confirm answer state must reserve dialogue")
    local confirmDialogue = assert(confirmLayout.dialogue).outerRect
    Assert.deepEqual(
      confirmDialogue,
      dialogueRect,
      "dialogue geometry must be stable between selection and confirmation"
    )
    local profile = assert(confirmLayout.selectedProfileButton)
    local choices = assert(confirmLayout.confirmationButtons)
    Assert.isTrue(disjoint(profile.rect, confirmDialogue))
    Assert.isTrue(disjoint(choices[0].rect, confirmDialogue))
    Assert.isTrue(disjoint(choices[1].rect, confirmDialogue))
    Assert.isTrue(inside(profile.rect, confirmLayout.viewport))
    Assert.isTrue(inside(choices[0].rect, confirmLayout.viewport))
    Assert.isTrue(inside(choices[1].rect, confirmLayout.viewport))
    Assert.deepEqual(confirmLayout.oakRegion, selectLayout.oakRegion)
    Assert.deepEqual(confirmLayout.selectorRegion, selectLayout.selectorRegion)

    local transitionLayout = compute(w, h, {
      phase = "gender_composition_transition",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = 0,
      genderCompositionProgress = 0.5,
      oakBgScrollX = 0,
    }, {}, data)
    Assert.notNil(transitionLayout.dialogue, "gender composition must reserve dialogue")
    Assert.isTrue(disjoint(assert(transitionLayout.oakRegion), assert(transitionLayout.dialogue).outerRect))
  end
end

function T.tests.gender_cards_keep_equal_top_and_bottom_padding_around_portraits()
  local data = manifest()
  for _, size in ipairs({ { 800, 600 }, { 390, 844 } }) do
    local layout = compute(size[1], size[2], {
      phase = "gender_select",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = 0,
      genderCompositionProgress = 1,
      oakBgScrollX = 0,
    }, {}, data)
    for gender = 0, 1 do
      local entry = assert(layout.genderButtons[gender])
      local top = entry.portraitRect.y - entry.rect.y
      local bottom = (entry.rect.y + entry.rect.height) - (entry.portraitRect.y + entry.portraitRect.height)
      Assert.near(top, bottom, 1e-6)
    end
  end
end

function T.tests.name_launch_wait_keeps_dialogue_reserved_and_oak_region_stable()
  local data = manifest()
  for _, size in ipairs({ { 800, 600 }, { 390, 844 } }) do
    local w, h = size[1], size[2]
    local selectLayout = compute(w, h, {
      phase = "gender_select",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = 0,
      genderCompositionProgress = 1,
      oakBgScrollX = 0,
    }, {}, data)
    local launchLayout = compute(w, h, {
      phase = "name_launch_wait",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = 0,
      genderCompositionProgress = 1,
      nameCompositionProgress = 0,
      oakBgScrollX = 0,
    }, {}, data)
    Assert.notNil(launchLayout.dialogue, "name_launch_wait must reserve dialogue at " .. w .. "x" .. h)
    Assert.deepEqual(
      assert(launchLayout.dialogue).outerRect,
      assert(selectLayout.dialogue).outerRect,
      "dialogue geometry must be stable into name launch wait"
    )
    Assert.deepEqual(launchLayout.oakRegion, selectLayout.oakRegion)
    Assert.deepEqual(launchLayout.selectorRegion, selectLayout.selectorRegion)
  end
end

function T.tests.pixel_authored_layout_scales_stay_integer_across_host_sizes_and_transitions()
  local cases = {
    ordinaryView(0),
    compositionView(0.5),
    {
      phase = "gender_select",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = 0,
      genderCompositionProgress = 1,
      oakBgScrollX = 0,
    },
    {
      phase = "gender_confirm",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = 0,
      genderCompositionProgress = 1,
      confirmationChoice = { kind = "gender", selected = 0 },
      oakBgScrollX = 0,
    },
    {
      phase = "name_confirm",
      visual = "oak",
      primaryWidget = "oak",
      genderFocus = 0,
      genderCompositionProgress = 1,
      nameCompositionProgress = 1,
      confirmationChoice = { kind = "name", selected = 0 },
      oakBgScrollX = 0,
    },
  }
  local sizes = {
    { 256, 192 },
    { 640, 480 },
    { 1280, 720 },
    { 1920, 1080 },
    { 2560, 1440 },
    { 3840, 2160 },
    { 390, 844 },
  }
  for _, size in ipairs(sizes) do
    local width, height = size[1], size[2]
    local bounds = { x = 0, y = 0, width = width, height = height }
    local preferred = math.max(1, math.floor(height / 192 + 0.5))
    local outputScale = PixelScale.fitPreferred(bounds, 256, 192, preferred)
    local surface = PixelScale.cover(bounds, outputScale)
    for _, view in ipairs(cases) do
      local layout =
        compute(surface.logicalViewport.width, surface.logicalViewport.height, view, {}, profileManifest(), outputScale)
      local scales = { layout.sourceCanvas and layout.sourceCanvas.scale }
      if layout.subject then
        scales[#scales + 1] = layout.subject.scale
      end
      if layout.reveal then
        scales[#scales + 1] = layout.reveal.scale
      end
      if layout.revealCanvas then
        scales[#scales + 1] = layout.revealCanvas.scale
      end
      if layout.dialogue then
        scales[#scales + 1] = layout.dialogue.scale
      end
      for _, entry in ipairs(layout.genderButtons or {}) do
        scales[#scales + 1] = entry.scale
      end
      if layout.selectedProfileButton then
        scales[#scales + 1] = layout.selectedProfileButton.scale
      end
      for _, entry in pairs(layout.confirmationButtons or {}) do
        scales[#scales + 1] = entry.scale
      end
      for _, scale in ipairs(scales) do
        Assert.isTrue(
          type(scale) == "number" and scale > 0 and scale == math.floor(scale),
          "pixel-authored scale must be integer"
        )
      end
    end
  end
end

return T
