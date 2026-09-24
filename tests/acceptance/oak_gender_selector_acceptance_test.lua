-- Production-composed Oak profile selection through the real generated cache.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local NewGame = require("game.hgss.src.newgame.NewGame")
local OakIntroComposition = require("game.hgss.src.newgame.OakIntroComposition")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")

local T = {
  metadata = {
    capabilities = { "graphics", "rom_dump", "derived_cache" },
    tags = { "oak", "new-game", "selector" },
  },
  tests = {},
}

local function candidate(versionId)
  return NewGame.createCandidate({
    saveService = {
      reserve = function()
        return "save-00000001"
      end,
    },
    versionId = versionId,
    eventState = FieldEventState.new(),
    scriptSymbols = FieldScriptSymbols,
    mapIdentity = {
      mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
      fieldX = 6,
      fieldZ = 6,
      sourceFacing = 1,
    },
  })
end

local function compose(versionId, width, height)
  local audio = FakeAudioOutput.new()
  return OakIntroComposition.compose({
    candidate = candidate(versionId),
    versionId = versionId,
    graphics = love.graphics,
    audioOutput = { audio = audio.audio, sound = audio.sound },
    clock = {
      nowLocal = function()
        return { year = 2026, month = 9, day = 15, hour = 12, minute = 0, second = 0 }
      end,
    },
    randomU32 = function()
      return 0x12345678
    end,
    width = width or 640,
    height = height or 480,
    textInputHost = { setTextInput = function() end },
  })
end

local function finishDialogue(state)
  local messageKey = assert(state:view().messageKey, "Oak selection requires an active dialogue")
  for _ = 1, 20000 do
    if state:view().messageKey ~= messageKey then
      return
    end
    local status = state.dialogueController:status()
    if status.state == "WAITING_BOUNDARY" or status.state == "WAITING_CLOSE" then
      state:keypressed("return")
    else
      state:tick(1)
    end
  end
  error("Oak dialogue did not reach its semantic completion boundary: " .. messageKey)
end

local function advanceUntil(state, messageKey)
  for _ = 1, 20000 do
    if state:view().messageKey == messageKey then
      return
    end
    if state.dialogueController:isModal() then
      finishDialogue(state)
    else
      state:tick(1)
    end
  end
  error("Oak dialogue did not open: " .. messageKey)
end

local function advanceUntilPhase(state, phase)
  for _ = 1, 200 do
    if state:view().phase == phase then
      return
    end
    if state.dialogueController:isModal() then
      finishDialogue(state)
    else
      state:tick(1)
    end
  end
  error("Oak did not reach phase " .. phase)
end

local function withComposed(versionId, width, height, fn)
  local state = compose(versionId, width, height)
  local ok, err = xpcall(fn, debug.traceback, state)
  state:dispose()
  if not ok then
    error(err, 0)
  end
end

local function inside(inner, outer)
  return inner.x >= outer.x
    and inner.y >= outer.y
    and inner.x + inner.width <= outer.x + outer.width
    and inner.y + inner.height <= outer.y + outer.height
end

local function driveToGenderSelect(state)
  advanceUntil(state, "profile.gender_question")
  finishDialogue(state)
  advanceUntilPhase(state, "gender_select")
end

local function driveToNameEdit(state)
  driveToGenderSelect(state)
  state:keypressed("return")
  finishDialogue(state)
  state:keypressed("return")
  finishDialogue(state)
  advanceUntilPhase(state, "name_edit")
end

local function submitName(state)
  state:textinput("GOLD")
  state:gamepadpressed(nil, "start")
end

local function clickGenderCard(state, gender)
  local view = state:view()
  local surface = assert(view.pixelSurface)
  local entry = assert(assert(view.layout.genderButtons)[gender])
  local x, y = LayoutGeometry.logicalToHost(
    surface.placement,
    entry.rect.x + entry.rect.width / 2,
    entry.rect.y + entry.rect.height / 2
  )
  state:mousepressed(x, y, 1)
end

T.tests.production_oak_selector_enters_immediately_without_a_slide_and_hides_oak = function()
  withComposed(AcceptanceHarness.defaultVersion(), 640, 480, function(state)
    advanceUntil(state, "profile.gender_question")
    finishDialogue(state)
    local entered = state:view()
    Assert.equal(entered.phase, "gender_select")
    Assert.equal(entered.genderCompositionProgress, 1)
    Assert.isTrue(entered.focusTimer <= 1, "selection focus timing must restart on entry")
    Assert.isNil(entered.layout.subject, "Oak must be absent while the selector is shown")
    Assert.isNil(entered.layout.oakRegion, "Oak must be absent while the selector is shown")
    local selectorRegion = assert(entered.layout.selectorRegion)
    local before = {}
    for gender = 0, 1 do
      local entry = assert(entered.layout.genderButtons[gender])
      Assert.isTrue(inside(entry.rect, selectorRegion), "gender card must stay inside the selector region")
      local button = assert(entry.button, "gender card must resolve shared button geometry")
      Assert.deepEqual(button.rect, entry.rect)
      Assert.equal(button.scale, entry.scale)
      before[gender] = entry.rect
    end
    state:tick(30)
    local settled = state:view()
    Assert.equal(settled.phase, "gender_select")
    for gender = 0, 1 do
      Assert.deepEqual(settled.layout.genderButtons[gender].rect, before[gender])
    end
  end)
end

T.tests.production_oak_selector_treats_keyboard_gamepad_and_pointer_alike = function()
  local versionId = AcceptanceHarness.defaultVersion()
  withComposed(versionId, 640, 480, function(state)
    driveToGenderSelect(state)
    state:keypressed("right")
    Assert.equal(state:view().genderFocus, 1)
    state:keypressed("return")
    Assert.equal(state:view().phase, "gender_confirm")
    Assert.equal(state:view().messageKey, "profile.gender_confirm.female")
    finishDialogue(state)
    Assert.deepEqual(state:view().confirmationChoice, { kind = "gender", selected = 0 })
  end)
  withComposed(versionId, 640, 480, function(state)
    driveToGenderSelect(state)
    state:gamepadpressed(nil, "dpright")
    Assert.equal(state:view().genderFocus, 1)
    state:gamepadpressed(nil, "a")
    Assert.equal(state:view().phase, "gender_confirm")
    Assert.equal(state:view().messageKey, "profile.gender_confirm.female")
    finishDialogue(state)
    Assert.deepEqual(state:view().confirmationChoice, { kind = "gender", selected = 0 })
  end)
  withComposed(versionId, 640, 480, function(state)
    driveToGenderSelect(state)
    clickGenderCard(state, 1)
    Assert.equal(state:view().phase, "gender_confirm")
    Assert.equal(state:view().messageKey, "profile.gender_confirm.female")
    Assert.equal(state:view().genderFocus, 1)
  end)
end

T.tests.production_oak_selector_back_confirmation_and_name_flows_return_to_a_valid_selector = function()
  withComposed(AcceptanceHarness.defaultVersion(), 640, 480, function(state)
    driveToGenderSelect(state)
    state:keypressed("right")
    state:keypressed("return")
    finishDialogue(state)
    state:keypressed("escape")
    Assert.equal(state:view().phase, "gender_question")
    finishDialogue(state)
    advanceUntilPhase(state, "gender_select")
    Assert.equal(state:view().genderFocus, 1)
    state:keypressed("return")
    Assert.equal(state:view().phase, "gender_confirm")
    Assert.equal(state:view().messageKey, "profile.gender_confirm.female")
    finishDialogue(state)
    state:keypressed("return")
    Assert.equal(state:view().messageKey, "profile.name_prompt")
    finishDialogue(state)
    advanceUntilPhase(state, "name_edit")
    Assert.notNil(state:view().namingScreen)
    state:textinput("GOLD")
    Assert.equal(state:view().name, "GOLD")
    state:gamepadpressed(nil, "start")
    state:tick(26)
    Assert.equal(state:view().phase, "name_confirm")
    Assert.equal(state:view().name, "GOLD")
    Assert.equal(state:view().messageKey, "profile.name_confirm.female")
    finishDialogue(state)
    state:keypressed("escape")
    Assert.equal(state:view().phase, "gender_question")
    finishDialogue(state)
    advanceUntilPhase(state, "gender_select")
    state:keypressed("left")
    Assert.equal(state:view().genderFocus, 0)
    state:keypressed("return")
    Assert.equal(state:view().phase, "gender_confirm")
    Assert.equal(state:view().messageKey, "profile.gender_confirm.male")
  end)
end

T.tests.production_oak_name_confirmation_stays_inside_the_safe_frame = function()
  for _, size in ipairs({ { 640, 480 }, { 390, 844 } }) do
    withComposed(AcceptanceHarness.defaultVersion(), size[1], size[2], function(state)
      driveToNameEdit(state)
      submitName(state)
      finishDialogue(state)

      local view = state:view()
      local layout = assert(view.layout)
      local safeFrame = assert(layout.safeFrame)
      local buttons = assert(layout.confirmationButtons)
      Assert.equal(layout.scene.x, 0, "Oak art must retain the full viewport origin")
      Assert.equal(layout.scene.width, layout.viewport.width, "Oak art must retain the full viewport width")
      for _, choice in pairs(buttons) do
        Assert.isTrue(inside(choice.rect, safeFrame), "name confirmation must stay inside the safe frame")
      end
    end)
  end
end

T.tests.production_oak_name_confirmation_is_final_on_the_first_post_submit_frame = function()
  withComposed(AcceptanceHarness.defaultVersion(), 640, 480, function(state)
    driveToNameEdit(state)
    submitName(state)

    local first = state:view()
    Assert.equal(first.phase, "name_confirm", "name submission must enter confirmation immediately")
    Assert.equal(first.messageKey, "profile.name_confirm.male")
    Assert.equal(first.nameCompositionProgress, 1)
    local firstSubject = assert(first.layout.subject)

    state:tick(26)
    local settled = state:view()
    Assert.equal(settled.phase, "name_confirm")
    Assert.deepEqual(firstSubject, settled.layout.subject, "Oak must not slide after name submission")
  end)
end

T.tests.production_intro_cache_publishes_no_selector_masks_and_retains_naming_subjects = function()
  local IntroAssetCache = require("libs.assets.src.newgame.IntroAssetCache")
  local versionId = AcceptanceHarness.defaultVersion()
  local cache = CacheFs.forVersion(versionId)
  local manifest = assert(cache:loadLua(IntroAssetCache.manifestPath()))
  Assert.isTrue(IntroAssetCache.validateManifest(manifest))
  local selector = assert(manifest.genderSelector)
  Assert.notNil(selector.defaultTone)
  Assert.isNil(selector.unselectedRim, "selector rim fields must not survive the compact contract")
  Assert.isNil(selector.selectedRim, "selector rim fields must not survive the compact contract")
  for _, gender in ipairs({ "male", "female" }) do
    local button = assert(selector.buttons[gender])
    Assert.notNil(button.bounds)
    Assert.isNil(button.baseImage, gender .. " card publishes no base image")
    Assert.isNil(button.fillMaskImage, gender .. " card publishes no fill mask")
    Assert.isNil(button.rimMaskImage, gender .. " card publishes no rim mask")
  end
  for _, id in ipairs({ "naming_male", "naming_female" }) do
    local widget = assert(manifest.widgets[id], id .. " naming subject is retained")
    local image = assert(widget.frames[1].image)
    Assert.isTrue(cache:exists(image, "file"), id .. " naming subject payload is missing " .. image)
  end
end

T.tests.production_oak_name_editor_opens_on_a_small_host_without_a_nested_fit_gate = function()
  withComposed(AcceptanceHarness.defaultVersion(), 256, 192, function(state)
    driveToNameEdit(state)
    local view = state:view()
    Assert.equal(view.phase, "name_edit")
    local naming = assert(view.layout.namingScreen)
    Assert.equal(naming.surface.width, 256)
    Assert.equal(naming.surface.height, 192)
    Assert.notNil(view.namingScreen)
  end)
end

T.tests.production_oak_name_editor_keeps_canonical_integer_geometry_at_outer_scales = function()
  local versionId = AcceptanceHarness.defaultVersion()
  for _, host in ipairs({ { 640, 480 }, { 960, 720 } }) do
    withComposed(versionId, host[1], host[2], function(state)
      driveToNameEdit(state)
      local naming = assert(state:view().layout.namingScreen)
      Assert.equal(naming.surface.width, 256)
      Assert.equal(naming.surface.height, 192)
      local function assertIntegerRect(rect, label)
        for _, field in ipairs({ "x", "y", "width", "height" }) do
          Assert.equal(rect[field], math.floor(rect[field]), label .. "." .. field .. " must be an integer")
        end
      end
      for row = 1, 6 do
        for column = 1, 13 do
          assertIntegerRect(naming.cells[row][column], "cells[" .. row .. "][" .. column .. "]")
        end
      end
      for id, region in pairs(naming.controls) do
        assertIntegerRect(region, "controls." .. id)
      end
    end)
  end
end

local function advanceToNaming(versionId)
  local state = compose(versionId)
  driveToNameEdit(state)
  return state
end

local function clickNamingCell(state, row, column)
  local view = state:view()
  local plan = assert(view.namingPresentation, "Oak name entry publishes its parent-owned naming plan")
  local pane = assert(plan.panes[1], "the naming plan carries its content pane")
  local naming = assert(view.layout.namingScreen)
  local cell = assert(naming.cells[row][column])
  local x, y = LayoutGeometry.logicalToHost(
    assert(pane.placement, "the naming pane carries its host placement"),
    cell.x + 1,
    cell.y + 1
  )
  state:mousepressed(x, y, 1)
  state:mousereleased(x, y, 1)
end

T.tests.production_oak_name_entry_uses_the_retail_naming_surface = function()
  local state = advanceToNaming(AcceptanceHarness.defaultVersion())
  local view = state:view()
  Assert.notNil(view.namingScreen, "Oak name entry must expose the HGSS Naming Screen snapshot")
  state:dispose()
end

T.tests.production_oak_name_entry_routes_pointer_keyboard_and_gamepad_to_one_result = function()
  local state = advanceToNaming(AcceptanceHarness.defaultVersion())
  Assert.notNil(state:view().namingScreen, "all naming input paths require the Naming Screen boundary")
  state:textinput("GOLD")
  state:keypressed("backspace")
  Assert.equal(state:view().name, "GOL", "physical input and Back must share naming semantics")
  state:gamepadpressed(nil, "dpdown")
  clickNamingCell(state, 2, 1)
  Assert.equal(state:view().name, "GOLA", "pointer glyph activation must share naming semantics")
  clickNamingCell(state, 1, 10)
  Assert.equal(state:view().name, "GOL", "pointer Back must share naming semantics")
  clickNamingCell(state, 1, 12)
  state:tick(26)
  Assert.equal(state:view().phase, "name_confirm", "pointer OK must publish the same naming result")
  Assert.equal(state:view().name, "GOL")
  state:dispose()
end

T.tests.production_oak_name_draft_survives_reflow_behind_a_parent_owned_session = function()
  withComposed(AcceptanceHarness.defaultVersion(), 640, 480, function(state)
    driveToNameEdit(state)
    state:textinput("GOLD")
    Assert.equal(state:view().name, "GOLD", "the typed draft reaches the profile flow")
    state:resize(960, 720)
    Assert.equal(state:view().name, "GOLD", "a geometry change must not mutate the draft")
    local plan = assert(state:view().namingPresentation, "Oak must own a naming presentation session across reflow")
    Assert.equal(#plan.panes, 1, "the naming session resolves one logical pane after reflow")
    clickNamingCell(state, 2, 1)
    Assert.equal(state:view().name, "GOLDA", "pointer routing survives the geometry change")
    Assert.equal(state:view().phase, "name_edit", "activation must not submit mid-edit")
    state:gamepadpressed(nil, "start")
    state:tick(26)
    Assert.equal(state:view().phase, "name_confirm", "Start submits exactly one naming result")
    Assert.equal(state:view().name, "GOLDA")
  end)
end

return T
