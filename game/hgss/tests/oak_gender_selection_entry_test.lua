-- Completing the gender question drops straight into gender selection:
-- no composition slide is observable, Oak stays hidden, and selection input
-- is live on the next tick, including after a rejection returns.

local Assert = require("tests.support.Assert")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local NewGame = require("game.hgss.src.newgame.NewGame")
local OakIntroController = require("game.hgss.src.newgame.OakIntroController")
local OakIntroLayout = require("game.hgss.src.newgame.OakIntroLayout")

local T = { tests = {} }

local CHARMAP = { A = 1, G = 6, O = 7, L = 8, D = 4 }
local PLAYER_DATA_CONTEXT = { charmap = CHARMAP, frameIndexes = { [0] = true } }

local function candidate()
  return NewGame.createCandidate({
    saveService = {
      reserve = function()
        return "save-00000017"
      end,
    },
    versionId = "heartgold",
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

local function testAudio()
  return {
    playMusic = function() end,
    stopMusic = function() end,
    fadeMusicOut = function() end,
    play = function() end,
    playCry = function() end,
    updateSoundFrame = function() end,
    isMusicFadeActive = function()
      return false
    end,
  }
end

local function messages()
  return {
    ["greeting.midnight"] = "greeting.midnight",
    ["greeting.morning"] = "greeting.morning",
    ["greeting.day"] = "greeting.day",
    ["greeting.evening"] = "greeting.evening",
    ["greeting.night"] = "greeting.night",
    ["oak.welcome"] = "oak.welcome",
    ["oak.world_inhabited"] = "oak.world_inhabited",
    ["oak.live_alongside"] = "oak.live_alongside",
    ["oak.tell_about_yourself"] = "oak.tell_about_yourself",
    ["profile.gender_question"] = "profile.gender_question",
    ["profile.gender_confirm.male"] = "profile.gender_confirm.male",
    ["profile.gender_confirm.female"] = "profile.gender_confirm.female",
    ["profile.name_prompt"] = "profile.name_prompt",
    ["profile.name_confirm.male"] = "profile.name_confirm.male",
    ["profile.name_confirm.female"] = "profile.name_confirm.female",
    ["profile.final"] = "profile.final",
  }
end

local function assets()
  return {
    marill = { playMode = "forward_loop", loopStartFrameIdx = 0, frames = { { duration = 1 } } },
    marill_appear = { playMode = "forward", loopStartFrameIdx = 0, frames = { { duration = 1 } } },
    ball_open = { playMode = "forward", loopStartFrameIdx = 0, frames = { { duration = 1 } } },
  }
end

local function controller()
  return OakIntroController.new({
    candidate = candidate(),
    clock = {
      nowLocal = function()
        return { year = 2026, month = 8, day = 22, hour = 12, minute = 0, second = 0 }
      end,
    },
    audio = testAudio(),
    messages = messages(),
    assets = assets(),
    playerDataContext = PLAYER_DATA_CONTEXT,
    randomU32 = function()
      return 0x12345678
    end,
  })
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

local function layoutManifest()
  return {
    sourceReference = { width = 256, height = 192 },
    background = { width = 256, height = 192, sampling = "linear" },
    genderSelector = {
      defaultTone = { r = 100, g = 101, b = 102 },
      buttons = {
        male = { bounds = { x = 18, y = 25, width = 93, height = 148 } },
        female = { bounds = { x = 144, y = 25, width = 95, height = 148 } },
      },
    },
    widgets = {
      oak = widget(80, 100, { x = 20, y = 100 }, { x = 20, y = 30, width = 80, height = 100 }),
      gender_male = widget(40, 60, { x = 20, y = 30 }, { x = 0, y = 0, width = 40, height = 60 }),
      gender_female = widget(40, 60, { x = 20, y = 30 }, { x = 0, y = 0, width = 40, height = 60 }),
      ball_open = widget(40, 30, { x = 20, y = 30 }, { x = 140, y = 50, width = 40, height = 30 }),
      marill = widget(40, 30, { x = 20, y = 30 }, { x = 140, y = 50, width = 40, height = 30 }),
    },
  }
end

local function layoutManifestWithPortraits()
  local manifest = layoutManifest()
  manifest.widgets.gender_male.sourceCenter = { x = 64, y = 104 }
  manifest.widgets.gender_female.sourceCenter = { x = 192, y = 104 }
  return manifest
end

local function completeActiveMessage(state)
  local key = assert(state:view().messageKey, "expected an active message")
  return state:messageCompleted(key)
end

local function advanceToPhase(state, phase)
  for _ = 1, 2000 do
    if state:view().phase == phase then
      return
    end
    state:tick(1)
  end
  error("did not reach phase: " .. phase)
end

local function reachGenderQuestion(state)
  state:start()
  state:tick(40)
  completeActiveMessage(state)
  state:tick(6 + 30)
  completeActiveMessage(state)
  state:tick(26)
  completeActiveMessage(state)
  advanceToPhase(state, "oak_live_alongside")
  completeActiveMessage(state)
  advanceToPhase(state, "oak_tell_about_yourself")
  completeActiveMessage(state)
  Assert.equal(state:view().phase, "gender_question")
  Assert.equal(state:view().messageKey, "profile.gender_question")
end

function T.tests.gender_question_completion_enters_selection_with_oak_hidden()
  local state = controller()
  reachGenderQuestion(state)
  Assert.isTrue(completeActiveMessage(state))
  state:tick(1)
  local view = state:view()
  Assert.equal(view.phase, "gender_select")
  Assert.isNil(view.messageKey)
  Assert.isTrue(view.focusTimer <= 1, "selection focus timing must restart on entry")
  local layout = OakIntroLayout.compute(256, 192, view, {}, layoutManifestWithPortraits(), 1)
  Assert.isNil(layout.subject, "Oak must be absent while the selector is shown")
  Assert.isNil(layout.oakRegion, "Oak must be absent while the selector is shown")
  Assert.notNil(layout.genderButtons[0])
  Assert.notNil(layout.genderButtons[1])
  -- Selection input is live immediately: confirming reaches the confirm step.
  Assert.isTrue(state:press("confirm"))
  Assert.equal(state:view().phase, "gender_confirm")
end

function T.tests.rejected_confirmation_returns_to_selection_without_a_slide()
  local state = controller()
  reachGenderQuestion(state)
  completeActiveMessage(state)
  state:tick(1)
  Assert.equal(state:view().phase, "gender_select")
  state:press("right")
  Assert.isTrue(state:press("confirm"))
  completeActiveMessage(state)
  Assert.isTrue(state:press("cancel"))
  Assert.equal(state:view().phase, "gender_question")
  completeActiveMessage(state)
  state:tick(1)
  Assert.equal(state:view().phase, "gender_select")
  Assert.equal(state:view().genderFocus, 1)
end

return T
