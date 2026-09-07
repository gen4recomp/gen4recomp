-- Lower-layer contracts for the source-shaped Oak/profile state machine.
-- The controller is pure: clocks, generated assets/messages, audio, and the
-- finalization boundary are explicit collaborators.

local Assert = require("tests.support.Assert")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local NewGame = require("game.hgss.src.newgame.NewGame")
local OakGreetingPolicy = require("game.hgss.src.newgame.OakGreetingPolicy")
local OakIntroController = require("game.hgss.src.newgame.OakIntroController")

local T = {}

-- Includes the lowercase glyphs of the generated Ethan/Lyra defaults so
-- finalization tests can encode them through the same charmap contract.
local CHARMAP = {
  A = 1,
  B = 2,
  C = 3,
  D = 4,
  E = 5,
  G = 6,
  O = 7,
  L = 8,
  [" "] = 9,
  ["é"] = 10,
  a = 11,
  h = 12,
  n = 13,
  r = 14,
  t = 15,
  y = 16,
}
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

local function clock(hour, minute)
  local value = { hour = hour, minute = minute, second = 0 }
  return {
    nowLocal = function()
      return {
        year = 2026,
        month = 8,
        day = 22,
        hour = value.hour,
        minute = value.minute,
        second = value.second,
      }
    end,
    value = value,
  }
end

local function audio()
  local trace = {}
  local function record(name, value)
    trace[#trace + 1] = { name = name, value = value }
  end
  return {
    trace = trace,
    playMusic = function(_, id)
      record("music", id)
    end,
    stopMusic = function()
      record("stop_music")
    end,
    fadeMusicOut = function(_, spec)
      record("fade_out", spec)
    end,
    play = function(_, id)
      record("effect", id)
    end,
    playCry = function(_, species, pattern)
      record("cry", { species = species, pattern = pattern })
    end,
    updateSoundFrame = function()
      record("sound_frame")
    end,
    isMusicFadeActive = function()
      return false
    end,
  }
end

local function selectionEffects(trace)
  local count = 0
  for _, event in ipairs(trace) do
    if event.name == "effect" and event.value == "SEQ_SE_DP_SELECT" then
      count = count + 1
    end
  end
  return count
end

local function controller(options)
  options = options or {}
  local time = options.clock or clock(12, 0)
  return OakIntroController.new({
    candidate = options.candidate or candidate(),
    clock = time,
    audio = (options.audio or audio()) --[[@as GameSound]],
    messages = options.messages or {
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
    },
    assets = options.assets or {
      marill = { playMode = "forward_loop", loopStartFrameIdx = 0, frames = { { duration = 1 } } },
      marill_appear = { playMode = "forward", loopStartFrameIdx = 0, frames = { { duration = 1 } } },
      ball_open = { playMode = "forward", loopStartFrameIdx = 0, frames = { { duration = 1 } } },
    },
    virtualGlyphs = { "A", "B", "C", "D", "E", "F", "G", "O", "L", "é" },
    playerDataContext = PLAYER_DATA_CONTEXT,
    randomU32 = function()
      return 0x12345678
    end,
  })
end

local function animatedAssets()
  return {
    marill = {
      playMode = "forward_loop",
      loopStartFrameIdx = 0,
      frames = { { duration = 1 }, { duration = 4 }, { duration = 2 } },
    },
    marill_appear = { playMode = "forward", loopStartFrameIdx = 0, frames = { { duration = 1 } } },
    ball_open = { playMode = "forward", loopStartFrameIdx = 0, frames = { { duration = 1 } } },
    shrink_male = { frames = { { duration = 2 }, { duration = 3 } } },
    shrink_female = { frames = { { duration = 2 }, { duration = 3 } } },
  }
end

local function finalSequenceAssets()
  return {
    marill = { playMode = "forward_loop", loopStartFrameIdx = 0, frames = { { duration = 1 } } },
    marill_appear = { playMode = "forward", loopStartFrameIdx = 0, frames = { { duration = 1 } } },
    ball_open = { playMode = "forward", loopStartFrameIdx = 0, frames = { { duration = 1 } } },
    male = { frames = { { duration = 1 } } },
    female = { frames = { { duration = 1 } } },
    shrink_male = {
      frames = {
        { duration = 9 },
        { duration = 9 },
        { duration = 9 },
        { duration = 9 },
      },
    },
    shrink_female = {
      frames = {
        { duration = 9 },
        { duration = 9 },
        { duration = 9 },
        { duration = 9 },
      },
    },
  }
end

local function advanceToPhase(state, phase)
  for _ = 1, 2000 do
    if state:view().phase == phase then
      return
    end
    state:tick(1)
  end
  error("Oak test did not reach phase: " .. phase)
end

local function advanceThroughHide(state)
  advanceToPhase(state, "oak_tell_about_yourself")
end

local function completeActiveMessage(state)
  local key = assert(state:view().messageKey, "Oak test expected an active message")
  return state:messageCompleted(key)
end

-- Reaches name_edit without navigating the confirmation-choice UI (matching
-- the other controller-only tests in this suite); an optional female flag
-- selects gender focus before the name editor opens, and the virtual
-- keyboard focus starts on the first glyph key, matching production.
local function advanceToNameEdit(options, female)
  local state = controller(options)
  state:start()
  state:tick(40)
  completeActiveMessage(state)
  state:tick(6 + 30)
  completeActiveMessage(state)
  state:tick(26)
  completeActiveMessage(state)
  advanceToPhase(state, "oak_live_alongside")
  completeActiveMessage(state)
  advanceThroughHide(state)
  completeActiveMessage(state)
  completeActiveMessage(state)
  state:tick(26)
  if female then
    state:press("right")
  end
  state:press("confirm")
  completeActiveMessage(state)
  state:press("confirm")
  completeActiveMessage(state)
  state:tick(40)
  Assert.equal(state:view().phase, "name_edit")
  return state
end

-- The Confirm virtual key is last in focus order (glyphs, then Delete, then
-- Confirm); one left-navigation step from the initial glyph focus wraps
-- directly onto it.
local function focusConfirmKey(state)
  state:press("left")
end

local function genderConfirmation(selectFemale, options)
  selectFemale = selectFemale ~= false
  local state = controller(options)
  state:start()
  state:tick(40)
  completeActiveMessage(state)
  state:tick(6 + 30)
  completeActiveMessage(state)
  state:tick(26)
  completeActiveMessage(state)
  advanceToPhase(state, "oak_live_alongside")
  completeActiveMessage(state)
  advanceThroughHide(state)
  completeActiveMessage(state)
  completeActiveMessage(state)
  state:tick(26)
  state:tick(40)
  if selectFemale then
    state:press("right")
  end
  state:press("confirm")
  Assert.equal(state:view().phase, "gender_confirm")
  state:messageCompleted(selectFemale and "profile.gender_confirm.female" or "profile.gender_confirm.male")
  Assert.deepEqual(state:view().confirmationChoice, { kind = "gender", selected = 0 })
  return state
end

local function genderSelection(options)
  local state = controller(options)
  state:start()
  state:tick(40)
  completeActiveMessage(state)
  state:tick(6 + 30)
  completeActiveMessage(state)
  state:tick(26)
  completeActiveMessage(state)
  advanceToPhase(state, "oak_live_alongside")
  completeActiveMessage(state)
  advanceThroughHide(state)
  completeActiveMessage(state)
  completeActiveMessage(state)
  state:tick(26)
  Assert.equal(state:view().phase, "gender_select")
  return state
end

local function nameConfirmation(selectFemale, options)
  options = options or {}
  local state = genderConfirmation(selectFemale, options)
  state:press("confirm")
  completeActiveMessage(state)
  state:tick(40)
  state:inputText("GOLD")
  state:press("submit")
  state:tick(26)
  state:messageCompleted(selectFemale == false and "profile.name_confirm.male" or "profile.name_confirm.female")
  Assert.equal(state:view().phase, "name_confirm")
  Assert.deepEqual(state:view().confirmationChoice, { kind = "name", selected = 0 })
  return state
end

local function assertIgnoredMessageInput(state, action, before, trace, traceLength)
  Assert.isFalse(state:press(action), "input must be ignored while an Oak message is active: " .. action)
  local after = state:view()
  Assert.equal(after.phase, before.phase)
  Assert.equal(after.messageKey, before.messageKey)
  Assert.deepEqual(after.confirmationChoice, before.confirmationChoice)
  Assert.equal(#trace, traceLength, "audio trace must remain unchanged")
end

function T.active_dialogue_rejects_direct_semantic_input_until_completion()
  local ordinaryAudio = audio()
  local ordinary = controller({ audio = ordinaryAudio })
  ordinary:start()
  ordinary:tick(40)
  local ordinaryBefore = ordinary:view()
  local ordinaryTraceLength = #ordinaryAudio.trace
  for _, action in ipairs({ "confirm", "yes", "no", "cancel" }) do
    assertIgnoredMessageInput(ordinary, action, ordinaryBefore, ordinaryAudio.trace, ordinaryTraceLength)
  end

  Assert.isTrue(ordinary:messageCompleted(ordinaryBefore.messageKey))
  Assert.equal(ordinary:view().phase, "fade_wait")
  Assert.isNil(ordinary:view().messageKey)
  Assert.throws(function()
    ordinary:messageCompleted(ordinaryBefore.messageKey)
  end, "a stale dialogue completion must remain a programming error")

  local confirmationAudio = audio()
  local confirmation = genderSelection({ audio = confirmationAudio })
  Assert.isTrue(confirmation:press("confirm"))
  local confirmationBefore = confirmation:view()
  local confirmationTraceLength = #confirmationAudio.trace
  for _, action in ipairs({ "confirm", "yes", "no", "cancel" }) do
    assertIgnoredMessageInput(
      confirmation,
      action,
      confirmationBefore,
      confirmationAudio.trace,
      confirmationTraceLength
    )
  end

  Assert.isTrue(confirmation:messageCompleted(confirmationBefore.messageKey))
  Assert.deepEqual(confirmation:view().confirmationChoice, { kind = "gender", selected = 0 })
end

function T.confirmation_direction_and_semantic_actions_follow_each_choice_orientation()
  local genderAudio = audio()
  local gender = genderConfirmation(false, { audio = genderAudio })
  local genderTraceLength = #genderAudio.trace
  Assert.isFalse(gender:press("left"))
  Assert.isFalse(gender:press("right"))
  Assert.equal(gender:view().confirmationChoice.selected, 0)
  Assert.equal(#genderAudio.trace, genderTraceLength)
  Assert.isTrue(gender:press("up"))
  Assert.equal(gender:view().confirmationChoice.selected, 0)
  Assert.equal(#genderAudio.trace, genderTraceLength)
  Assert.isTrue(gender:press("down"))
  Assert.equal(gender:view().confirmationChoice.selected, 1)
  Assert.equal(#genderAudio.trace, genderTraceLength + 1)
  Assert.isTrue(gender:press("down"))
  Assert.equal(gender:view().confirmationChoice.selected, 1)
  Assert.equal(#genderAudio.trace, genderTraceLength + 1)
  Assert.isTrue(gender:press("confirm"))
  Assert.equal(gender:view().phase, "gender_question")
  Assert.equal(gender:view().messageKey, "profile.gender_question")

  local nameAudio = audio()
  local name = nameConfirmation(false, { audio = nameAudio })
  local nameTraceLength = #nameAudio.trace
  Assert.isFalse(name:press("left"))
  Assert.isFalse(name:press("right"))
  Assert.equal(name:view().confirmationChoice.selected, 0)
  Assert.equal(#nameAudio.trace, nameTraceLength)
  Assert.isTrue(name:press("up"))
  Assert.equal(name:view().confirmationChoice.selected, 0)
  Assert.equal(#nameAudio.trace, nameTraceLength)
  Assert.isTrue(name:press("down"))
  Assert.equal(name:view().confirmationChoice.selected, 1)
  Assert.equal(#nameAudio.trace, nameTraceLength + 1)
  Assert.isTrue(name:press("down"))
  Assert.equal(name:view().confirmationChoice.selected, 1)
  Assert.equal(#nameAudio.trace, nameTraceLength + 1)
  Assert.isTrue(name:press("confirm"))
  Assert.equal(name:view().phase, "gender_question")
  Assert.equal(name:view().messageKey, "profile.gender_question")

  local genderYes = genderConfirmation(false)
  Assert.isTrue(genderYes:press("yes"))
  Assert.equal(genderYes:view().phase, "name_prompt")
  Assert.equal(genderYes:view().messageKey, "profile.name_prompt")

  local nameYes = nameConfirmation(false)
  Assert.isTrue(nameYes:press("yes"))
  Assert.equal(nameYes:view().phase, "final_dialogue")
  Assert.equal(nameYes:view().messageKey, "profile.final")

  for _, action in ipairs({ "no", "cancel" }) do
    local genderNo = genderConfirmation(false)
    Assert.isTrue(genderNo:press(action))
    Assert.equal(genderNo:view().phase, "gender_question")
    Assert.equal(genderNo:view().messageKey, "profile.gender_question")

    local nameNo = nameConfirmation(false)
    Assert.isTrue(nameNo:press(action))
    Assert.equal(nameNo:view().phase, "gender_question")
    Assert.equal(nameNo:view().messageKey, "profile.gender_question")
  end
end

function T.gender_activation_restarts_the_selection_blink()
  local state = genderSelection()
  state:tick(5)
  Assert.equal(state:view().focusTimer, 5)
  local before = state:view()
  Assert.isTrue(state:press("left"))
  Assert.equal(state:view().genderFocus, 0)
  Assert.equal(state:view().focusTimer, before.focusTimer)
  Assert.equal(state:view().focusBlinkDelta, before.focusBlinkDelta)
  Assert.isTrue(state:press("right"))
  Assert.equal(state:view().genderFocus, 1)
  Assert.equal(state:view().focusTimer, 0)
  Assert.equal(state:view().focusBlinkDelta, 0)
  state:tick(3)
  Assert.equal(state:view().focusTimer, 3)
  local sameFocus = state:view()
  Assert.isTrue(state:press("right"))
  Assert.equal(state:view().genderFocus, 1)
  Assert.equal(state:view().focusTimer, sameFocus.focusTimer)
  Assert.equal(state:view().focusBlinkDelta, sameFocus.focusBlinkDelta)
  Assert.isTrue(state:press("confirm"))
  Assert.equal(state:view().phase, "gender_confirm")
  Assert.equal(state:view().focusTimer, 0)
  Assert.equal(state:view().focusBlinkDelta, 0)
end

function T.greeting_policy_uses_each_source_boundary()
  local cases = {
    { 3, 59, "midnight" },
    { 4, 0, "morning" },
    { 10, 59, "morning" },
    { 11, 0, "day" },
    { 15, 59, "day" },
    { 16, 0, "evening" },
    { 18, 59, "evening" },
    { 19, 0, "night" },
    { 23, 59, "night" },
  }
  for _, case in ipairs(cases) do
    Assert.equal(OakGreetingPolicy.bandAt(case[1], case[2]), case[3])
  end
end

function T.greeting_samples_clock_when_the_greeting_is_queued()
  local time = clock(3, 59)
  local state = controller({ clock = time })
  state:start()
  time.value.hour, time.value.minute = 4, 0
  state:tick(40)
  Assert.equal(state:view().message, "greeting.morning")
end

function T.gender_rejection_returns_through_question_with_remembered_focus()
  local state = controller()
  state:start()
  state:tick(40)
  completeActiveMessage(state)
  state:tick(6 + 30)
  completeActiveMessage(state)
  state:tick(26)
  completeActiveMessage(state)
  advanceToPhase(state, "oak_live_alongside")
  completeActiveMessage(state)
  advanceThroughHide(state)
  completeActiveMessage(state)
  completeActiveMessage(state)
  state:tick(26)
  state:press("right")
  state:press("confirm")
  Assert.equal(state:view().phase, "gender_confirm")
  completeActiveMessage(state)
  state:press("cancel")
  Assert.equal(state:view().phase, "gender_question")
  completeActiveMessage(state)
  Assert.equal(state:view().phase, "gender_select")
  Assert.equal(state:view().genderFocus, 1)
end

function T.gender_composition_uses_exactly_twenty_six_source_frames_and_does_not_replay()
  local state = controller()
  state:start()
  state:tick(40)
  completeActiveMessage(state)
  state:tick(6 + 30)
  completeActiveMessage(state)
  state:tick(26)
  completeActiveMessage(state)
  advanceToPhase(state, "oak_live_alongside")
  completeActiveMessage(state)
  advanceThroughHide(state)
  completeActiveMessage(state)
  Assert.equal(state:view().phase, "gender_question")

  completeActiveMessage(state)
  Assert.equal(state:view().phase, "gender_composition_transition")
  Assert.equal(state:view().genderCompositionProgress, 0)
  state:press("right")
  state:press("confirm")
  Assert.equal(state:view().phase, "gender_composition_transition")
  Assert.equal(state:view().genderFocus, 0)

  state:tick(25)
  Assert.equal(state:view().phase, "gender_composition_transition")
  Assert.near(state:view().genderCompositionProgress, 25 / 26)
  state:tick(1)
  Assert.equal(state:view().phase, "gender_select")
  Assert.equal(state:view().genderCompositionProgress, 1)

  state:press("confirm")
  Assert.equal(state:view().phase, "gender_confirm")
  completeActiveMessage(state)
  state:press("cancel")
  Assert.equal(state:view().phase, "gender_question")
  Assert.equal(state:view().genderCompositionProgress, 1)
  completeActiveMessage(state)
  Assert.equal(state:view().phase, "gender_select")
  Assert.equal(state:view().genderCompositionProgress, 1)
end

function T.confirmation_completion_activates_an_explicit_yes_choice()
  local state = controller()
  state:start()
  state:tick(40)
  completeActiveMessage(state)
  state:tick(6 + 30)
  completeActiveMessage(state)
  state:tick(26)
  completeActiveMessage(state)
  advanceToPhase(state, "oak_live_alongside")
  completeActiveMessage(state)
  advanceThroughHide(state)
  completeActiveMessage(state)
  completeActiveMessage(state)
  state:tick(26)
  state:press("right")
  state:press("confirm")
  Assert.equal(state:view().phase, "gender_confirm")

  completeActiveMessage(state)
  local view = state:view()
  Assert.equal(view.phase, "gender_confirm")
  Assert.deepEqual(view.confirmationChoice, { kind = "gender", selected = 0 })

  state:press("down")
  Assert.equal(state:view().confirmationChoice.selected, 1)
  state:press("cancel")
  Assert.equal(state:view().phase, "gender_question")
  Assert.equal(state:view().genderFocus, 1)
end

function T.focused_no_resolves_gender_rejection()
  local state = genderConfirmation()
  state:press("down")
  state:press("confirm")
  Assert.equal(state:view().phase, "gender_question")
  Assert.equal(state:view().genderFocus, 1)
end

function T.focused_no_resolves_name_rejection()
  local state = nameConfirmation()
  state:press("down")
  state:press("confirm")
  Assert.equal(state:view().phase, "gender_question")
end

function T.focused_yes_remains_affirmative_for_gender_and_name()
  local gender = genderConfirmation()
  gender:press("confirm")
  Assert.equal(gender:view().phase, "name_prompt")

  local name = nameConfirmation()
  name:press("confirm")
  Assert.equal(name:view().phase, "final_dialogue")
end

function T.profile_focus_and_activation_play_one_selection_effect_per_meaningful_action()
  local sounds = audio()
  local state = genderSelection({ audio = sounds })
  local before = selectionEffects(sounds.trace)

  state:press("left")
  Assert.equal(selectionEffects(sounds.trace), before, "a boundary focus no-op must be silent")
  state:press("right")
  Assert.equal(selectionEffects(sounds.trace), before + 1, "an actual gender focus change must play once")
  state:press("right")
  Assert.equal(selectionEffects(sounds.trace), before + 1, "a repeated boundary focus no-op must be silent")

  before = selectionEffects(sounds.trace)
  state:press("confirm")
  Assert.equal(state:view().phase, "gender_confirm")
  Assert.equal(selectionEffects(sounds.trace), before + 1, "gender activation must play once")

  local confirmationBefore = selectionEffects(sounds.trace)
  state:messageCompleted("profile.gender_confirm.female")
  state:press("up")
  Assert.equal(selectionEffects(sounds.trace), confirmationBefore, "a confirmation focus no-op must be silent")
  state:press("down")
  Assert.equal(selectionEffects(sounds.trace), confirmationBefore + 1, "confirmation focus change must play once")
  state:press("no")
  Assert.equal(selectionEffects(sounds.trace), confirmationBefore + 2, "confirmation activation must play once")
end

function T.direct_gender_actions_share_the_confirmation_activation_sound()
  local sounds = audio()
  local state = genderSelection({ audio = sounds })
  local before = selectionEffects(sounds.trace)
  state:press("female")
  Assert.equal(state:view().phase, "gender_confirm")
  Assert.equal(state:view().genderFocus, 1)
  Assert.equal(selectionEffects(sounds.trace), before + 1)

  local directMaleSounds = audio()
  local directMale = genderSelection({ audio = directMaleSounds })
  local directBefore = selectionEffects(directMaleSounds.trace)
  directMale:press("male")
  Assert.equal(directMale:view().phase, "gender_confirm")
  Assert.equal(directMale:view().genderFocus, 0)
  Assert.equal(selectionEffects(directMaleSounds.trace), directBefore + 1)
end

function T.confirmation_yes_and_no_resolve_only_from_the_active_choice()
  local state = controller()
  state:start()
  state:tick(40)
  completeActiveMessage(state)
  state:tick(6 + 30)
  completeActiveMessage(state)
  state:tick(26)
  completeActiveMessage(state)
  advanceToPhase(state, "oak_live_alongside")
  completeActiveMessage(state)
  advanceThroughHide(state)
  completeActiveMessage(state)
  completeActiveMessage(state)
  state:tick(26)
  state:press("confirm")
  completeActiveMessage(state)
  state:press("confirm")
  completeActiveMessage(state)
  state:tick(40)
  state:inputText("GOLD")
  state:press("submit")
  state:tick(26)
  completeActiveMessage(state)
  Assert.equal(state:view().phase, "name_confirm")
  state:press("yes")
  Assert.equal(state:view().phase, "final_dialogue")
end

function T.name_buffer_has_shared_utf8_limits_and_deletes_glyphs()
  local state = controller()
  state:start()
  state:tick(40)
  completeActiveMessage(state)
  state:tick(6 + 30)
  completeActiveMessage(state)
  state:tick(26)
  completeActiveMessage(state)
  advanceToPhase(state, "oak_live_alongside")
  completeActiveMessage(state)
  advanceThroughHide(state)
  completeActiveMessage(state)
  completeActiveMessage(state)
  state:tick(26)
  state:press("confirm")
  completeActiveMessage(state)
  state:press("confirm")
  completeActiveMessage(state)
  state:tick(40)
  Assert.equal(state:view().phase, "name_edit")
  state:inputText("Aé")
  Assert.equal(state:view().name, "Aé")
  state:deleteGlyph()
  Assert.equal(state:view().name, "A")
  state:inputText("BBBBBB")
  Assert.equal(state:view().name, "ABBBBBB")
  state:inputText("C")
  Assert.equal(state:view().name, "ABBBBBB")
  state:press("submit")
  state:tick(26)
  Assert.equal(state:view().phase, "name_confirm")
end

function T.blank_name_submission_uses_the_gender_default()
  local state = nameConfirmation(false)
  state:press("no")
  state:messageCompleted("profile.gender_question")
  state:tick(26) -- re-entering composition before gender_select
  state:press("confirm")
  completeActiveMessage(state)
  state:press("confirm")
  completeActiveMessage(state)
  state:press("confirm")
  state:tick(40)
  Assert.equal(state:view().phase, "name_edit")

  state:press("submit")
  state:tick(26)
  Assert.equal(state:view().phase, "name_confirm")
  Assert.equal(state:view().name, "Ethan")

  completeActiveMessage(state)
  state:press("no")
  Assert.equal(state:view().phase, "gender_question")
end

function T.name_rejection_clears_the_buffer_on_reentry()
  local state = controller()
  state:start()
  state:tick(40)
  completeActiveMessage(state)
  state:tick(6 + 30)
  completeActiveMessage(state)
  state:tick(26)
  completeActiveMessage(state)
  advanceToPhase(state, "oak_live_alongside")
  completeActiveMessage(state)
  advanceThroughHide(state)
  completeActiveMessage(state)
  completeActiveMessage(state)
  state:tick(26)
  for _ = 1, 5 do
    state:press("confirm")
  end
  state:tick(40)
  state:inputText("GOLD")
  state:press("submit")
  state:tick(26)
  completeActiveMessage(state)
  state:press("cancel")
  Assert.equal(state:view().phase, "gender_question")
  completeActiveMessage(state) -- re-enters gender_composition_transition from zero
  state:tick(26)
  state:press("confirm") -- gender_select -> gender_confirm
  completeActiveMessage(state) -- gender_confirm -> confirmation choice
  state:press("confirm") -- confirmation choice -> name_prompt
  completeActiveMessage(state) -- name_prompt -> name_launch_wait
  state:tick(40)
  Assert.equal(state:view().phase, "name_edit")
  Assert.equal(state:view().name, "")
end

function T.fixed_source_waits_and_cry_do_not_wait_for_completion()
  local sounds = audio()
  local state = controller({ audio = sounds })
  state:start()
  state:tick(40)
  completeActiveMessage(state)
  state:tick(6)
  Assert.equal(state:view().phase, "oak_reveal_wait")
  state:tick(30)
  Assert.equal(state:view().phase, "oak_welcome")
  completeActiveMessage(state)
  state:tick(26)
  Assert.equal(state:view().phase, "oak_world_inhabited")
  completeActiveMessage(state)
  advanceToPhase(state, "marill_cry_wait")
  Assert.equal(state:view().phase, "marill_cry_wait")
  Assert.equal(sounds.trace[#sounds.trace].name, "cry")
  state:tick(39)
  Assert.equal(state:view().phase, "marill_cry_wait")
  state:tick(1)
  Assert.equal(state:view().phase, "oak_live_alongside")
end

function T.reveal_stages_are_sequential_and_cry_waits_for_idle_marill()
  local sounds = audio()
  local state = controller({
    audio = sounds,
    assets = {
      marill = { playMode = "forward_loop", loopStartFrameIdx = 0, frames = { { duration = 2 }, { duration = 2 } } },
      marill_appear = { playMode = "forward", loopStartFrameIdx = 0, frames = { { duration = 2 }, { duration = 2 } } },
      ball_open = { playMode = "forward", loopStartFrameIdx = 0, frames = { { duration = 1 }, { duration = 1 } } },
    },
  })
  state:start()
  state:tick(40)
  completeActiveMessage(state)
  state:tick(6 + 30)
  completeActiveMessage(state)
  state:tick(26)
  completeActiveMessage(state)

  Assert.equal(state:view().revealWidget, "ball_open")
  local function count(name)
    local total = 0
    for _, event in ipairs(sounds.trace) do
      if event.name == name then
        total = total + 1
      end
    end
    return total
  end
  Assert.equal(count("effect"), 0, "ball opening does not emit flash sound yet")
  Assert.equal(count("cry"), 0, "ball opening does not emit cry yet")
  state:tick(29)
  Assert.equal(state:view().revealWidget, "ball_open")
  Assert.equal(count("effect"), 0)
  state:tick(1)
  Assert.equal(state:view().phase, "scene_flash")
  state:tick(4)
  Assert.equal(state:view().revealWidget, "marill_appear")
  Assert.equal(count("cry"), 0)
  local appearanceStartSourceFrame = state:view().sourceFrames
  state:tick(2)
  local appearanceComplete = state:view()
  Assert.equal(appearanceComplete.phase, "marill_brightness_fade")
  Assert.equal(appearanceComplete.sourceFrames - appearanceStartSourceFrame, 2)
  Assert.equal(appearanceComplete.revealBrightness, 1)
  Assert.equal(count("cry"), 0)

  state:tick(15)
  Assert.equal(state:view().phase, "marill_brightness_fade")
  Assert.equal(state:view().revealBrightness, 1 / 16)
  Assert.equal(count("cry"), 0)
  state:tick(1)
  Assert.equal(state:view().phase, "marill_cry_wait")
  Assert.equal(state:view().revealWidget, "marill")
  Assert.equal(state:view().revealBrightness, 0)
  Assert.equal(count("cry"), 1)
  state:tick(39)
  Assert.equal(state:view().message, nil)
  state:tick(1)
  Assert.equal(state:view().message, "oak.live_alongside")
  Assert.equal(state:view().revealWidget, "marill")
end

function T.core_sequence_exposes_source_beats_in_order()
  local state = controller()
  state:start()
  state:tick(40)
  completeActiveMessage(state)
  state:tick(6 + 30)
  Assert.equal(state:view().message, "oak.welcome")
  completeActiveMessage(state)
  state:tick(26)
  Assert.equal(state:view().message, "oak.world_inhabited")
  completeActiveMessage(state)
  advanceToPhase(state, "marill_cry_wait")
  Assert.equal(state:view().primaryWidget, "oak")
  Assert.equal(state:view().revealWidget, "marill")
  Assert.equal(state:view().revealFrameIndex, 1)
  state:tick(40)
  Assert.equal(state:view().message, "oak.live_alongside")
  completeActiveMessage(state)
  advanceThroughHide(state)
  Assert.equal(state:view().message, "oak.tell_about_yourself")
  completeActiveMessage(state)
  Assert.equal(state:view().message, "profile.gender_question")
end

function T.background_visual_has_no_primary_widget_outside_the_reveal_subject()
  local state = controller()
  state:start()
  Assert.equal(state:view().visual, "background")
  Assert.equal(state:view().primaryWidget, nil)

  state:tick(40)
  Assert.equal(state:view().phase, "greeting")
  Assert.equal(state:view().primaryWidget, nil)
end

function T.dialogue_view_keeps_the_generated_message_key_boundary()
  local state = controller()
  state:start()
  state:tick(40)
  completeActiveMessage(state)
  state:tick(6 + 30)
  local view = state:view()
  Assert.equal(view.messageKey, "oak.welcome")
  Assert.equal(view.dialogue.message, view.message)
  Assert.equal(view.dialogue.messageKey, view.messageKey)
end

function T.looping_marill_consumes_animation_units_with_carry()
  local state = controller({ assets = animatedAssets() })
  state:start()
  state:tick(40)
  completeActiveMessage(state)
  state:tick(6 + 30)
  completeActiveMessage(state)
  state:tick(26)
  completeActiveMessage(state)
  advanceToPhase(state, "marill_cry_wait")
  Assert.equal(state:view().primaryWidget, "oak")
  Assert.equal(state:view().revealWidget, "marill")
  Assert.equal(state:view().revealFrameIndex, 1)
  local startSourceFrame = state:view().sourceFrames
  local expectedFrames = { 2, 2, 3, 2 }
  for sourceFrame, expectedFrame in ipairs(expectedFrames) do
    state:tick(1)
    local view = state:view()
    Assert.equal(view.revealFrameIndex, expectedFrame)
    Assert.equal(view.sourceFrames, startSourceFrame + sourceFrame)
  end
end

local function advanceToBallOpen(options)
  local state = controller(options)
  state:start()
  state:tick(40)
  completeActiveMessage(state)
  state:tick(6 + 30)
  completeActiveMessage(state)
  state:tick(26)
  completeActiveMessage(state)
  Assert.equal(state:view().revealWidget, "ball_open")
  return state
end

local function revealAnimation(playMode, loopStartFrameIdx, durations)
  local frames = {}
  for _, duration in ipairs(durations) do
    frames[#frames + 1] = { duration = duration }
  end
  return { playMode = playMode, loopStartFrameIdx = loopStartFrameIdx, frames = frames }
end

function T.reveal_playback_follows_the_generated_animation_policy()
  -- A forward one-shot completes only after its terminal duration elapses,
  -- and a forward loop wraps to its configured loop start instead of
  -- restarting at the first frame.
  local state = advanceToBallOpen({
    assets = {
      ball_open = revealAnimation("forward", 0, { 2 }),
      marill_appear = revealAnimation("forward", 0, { 2, 2 }),
      marill = revealAnimation("forward_loop", 1, { 2, 2, 2 }),
    },
  })
  state:tick(30)
  Assert.equal(state:view().phase, "scene_flash")
  state:tick(4)
  Assert.equal(state:view().phase, "marill_appear")
  Assert.equal(state:view().revealFrameIndex, 1)
  state:tick(1)
  Assert.equal(state:view().phase, "marill_appear")
  Assert.equal(state:view().revealFrameIndex, 2)
  state:tick(1)
  Assert.equal(state:view().phase, "marill_brightness_fade")
  state:tick(16)
  Assert.equal(state:view().phase, "marill_cry_wait")
  Assert.equal(state:view().revealWidget, "marill")
  Assert.equal(state:view().revealFrameIndex, 1)
  local looped = {}
  for _ = 1, 6 do
    state:tick(1)
    looped[#looped + 1] = state:view().revealFrameIndex
  end
  Assert.deepEqual(looped, { 2, 3, 2, 3, 2, 3 })

  -- Reverse modes start at the last frame and traverse backward. A reverse
  -- loop wraps from its loop start back to the last frame without
  -- re-entering earlier pre-loop frames.
  local reverse = advanceToBallOpen({
    assets = {
      ball_open = revealAnimation("forward", 0, { 2 }),
      marill_appear = revealAnimation("reverse", 0, { 2, 2, 2 }),
      marill = revealAnimation("reverse_loop", 1, { 2, 2, 2 }),
    },
  })
  reverse:tick(30)
  reverse:tick(4)
  Assert.equal(reverse:view().phase, "marill_appear")
  Assert.equal(reverse:view().revealFrameIndex, 3)
  reverse:tick(1)
  Assert.equal(reverse:view().revealFrameIndex, 2)
  reverse:tick(1)
  Assert.equal(reverse:view().revealFrameIndex, 1)
  Assert.equal(reverse:view().phase, "marill_appear")
  reverse:tick(1)
  Assert.equal(reverse:view().phase, "marill_brightness_fade")
  reverse:tick(16)
  Assert.equal(reverse:view().phase, "marill_cry_wait")
  Assert.equal(reverse:view().revealFrameIndex, 3)
  local rewound = {}
  for _ = 1, 6 do
    reverse:tick(1)
    rewound[#rewound + 1] = reverse:view().revealFrameIndex
  end
  Assert.deepEqual(rewound, { 2, 3, 2, 3, 2, 3 })

  -- The configured Marill cadence repeats its two source durations and wraps
  -- to its loop start instead of holding at the terminal frame.
  local marill = advanceToBallOpen({
    assets = {
      ball_open = revealAnimation("forward", 0, { 2 }),
      marill_appear = revealAnimation("forward", 0, { 2 }),
      marill = revealAnimation("forward_loop", 0, { 12, 60 }),
    },
  })
  advanceToPhase(marill, "marill_cry_wait")
  Assert.equal(marill:view().revealFrameIndex, 1)
  marill:tick(6)
  Assert.equal(marill:view().revealFrameIndex, 2)
  marill:tick(29)
  Assert.equal(marill:view().revealFrameIndex, 2)
  marill:tick(1)
  Assert.equal(marill:view().revealFrameIndex, 1)
  marill:tick(6)
  Assert.equal(marill:view().revealFrameIndex, 2)
end

function T.visible_marill_keeps_cycling_its_configured_loop()
  local state = controller({
    assets = {
      ball_open = revealAnimation("forward", 0, { 2 }),
      marill_appear = revealAnimation("forward", 0, { 2 }),
      marill = revealAnimation("forward_loop", 0, { 12, 60 }),
    },
  })
  state:start()
  state:tick(40)
  completeActiveMessage(state)
  state:tick(6 + 30)
  completeActiveMessage(state)
  state:tick(26)
  completeActiveMessage(state)
  advanceToPhase(state, "oak_live_alongside")
  Assert.equal(state:view().revealWidget, "marill")
  Assert.notNil(state:view().messageKey, "Marill stays visible while its dialogue is active")
  local wraps = 0
  local previous = state:view().revealFrameIndex
  for _ = 1, 72 do
    state:tick(1)
    local view = state:view()
    Assert.equal(view.revealWidget, "marill")
    local current = view.revealFrameIndex
    Assert.isTrue(current == 1 or current == 2, "Marill stays inside its two-frame loop")
    if previous == 2 and current == 1 then
      wraps = wraps + 1
    end
    previous = current
  end
  Assert.equal(wraps, 2, "two full two-frame cycles wrap back to the loop start instead of holding")
end

function T.shrink_frames_remain_drawable_until_their_generated_durations_end()
  local state = controller({ assets = animatedAssets() })
  state:start()
  state:tick(40)
  completeActiveMessage(state)
  state:tick(6 + 30)
  completeActiveMessage(state)
  state:tick(26)
  completeActiveMessage(state)
  advanceToPhase(state, "oak_live_alongside")
  completeActiveMessage(state)
  advanceThroughHide(state)
  completeActiveMessage(state)
  completeActiveMessage(state)
  state:tick(26)
  state:press("confirm")
  completeActiveMessage(state)
  state:press("confirm")
  completeActiveMessage(state)
  state:tick(40)
  state:inputText("GOLD")
  state:press("submit")
  state:tick(26)
  completeActiveMessage(state)
  state:press("confirm")
  completeActiveMessage(state)
  Assert.equal(state:view().phase, "final_fade_out")
  state:tick(1)
  Assert.equal(state:view().phase, "final_full_art_fade_in")
  Assert.equal(state:view().primaryWidget, "male")
  state:tick(1)
  Assert.equal(state:view().phase, "final_full_art_hold")
  advanceToPhase(state, "shrink_animation")
  Assert.equal(state:view().phase, "shrink_animation")
  Assert.equal(state:view().visualFrameIndex, 1)
  state:tick(2)
  Assert.equal(state:view().phase, "shrink_animation")
  Assert.equal(state:view().visualFrameIndex, 2)
  state:tick(3)
  Assert.isTrue(state:view().phase ~= "complete", "the last shrink frame must enter the cover, not complete")
  Assert.isNil(state:result())
  Assert.near(state:view().finalFadeAlpha, 0, 1e-9)
  state:tick(6)
  Assert.near(state:view().finalFadeAlpha, 1, 1e-9, "the cover must reach full black")
  Assert.isTrue(state:view().phase ~= "complete", "full black must wait for presentation acknowledgement")
  Assert.isNil(state:result(), "the candidate stays unpublished until the black frame is presented")
  Assert.isTrue(state:confirmHandoffPresented(), "acknowledging the presented black frame finalizes the handoff")
  Assert.equal(state:view().phase, "complete")
  Assert.notNil(state:result())
end

function T.final_handoff_shows_selected_full_art_then_source_timed_shrink_for_both_genders()
  for _, gender in ipairs({ 0, 1 }) do
    local sounds = audio()
    local state = controller({ audio = sounds, assets = finalSequenceAssets() })
    state:start()
    state:tick(40)
    completeActiveMessage(state)
    state:tick(6 + 30)
    completeActiveMessage(state)
    state:tick(26)
    completeActiveMessage(state)
    advanceToPhase(state, "oak_live_alongside")
    completeActiveMessage(state)
    advanceThroughHide(state)
    state = nameConfirmation(gender == 1, { audio = sounds, assets = finalSequenceAssets() })
    state:press("confirm")
    Assert.equal(state:view().phase, "final_dialogue")
    completeActiveMessage(state)
    Assert.equal(state:view().phase, "final_fade_out")
    Assert.equal(state:view().primaryWidget, nil)
    Assert.isNil(state:result())

    state:tick(1)
    Assert.equal(state:view().phase, "final_full_art_fade_in")
    Assert.equal(state:view().primaryWidget, gender == 0 and "male" or "female")
    Assert.isNil(state:result())

    state:tick(1)
    Assert.equal(state:view().phase, "final_full_art_hold")
    Assert.equal(state:view().primaryWidget, gender == 0 and "male" or "female")
    state:tick(29)
    Assert.equal(state:view().phase, "final_full_art_hold")
    Assert.isNil(state:result())
    state:tick(1)
    Assert.equal(state:view().phase, "shrink_animation")
    Assert.equal(state:view().visualFrameIndex, 1)
    Assert.equal(state:view().primaryWidget, gender == 0 and "shrink_male" or "shrink_female")

    local soundCount = 0
    for _, event in ipairs(sounds.trace) do
      if event.name == "effect" and event.value == "SEQ_SE_GS_HERO_SHUKUSHOU" then
        soundCount = soundCount + 1
      end
    end
    Assert.equal(soundCount, 1)
    state:tick(8)
    Assert.equal(state:view().visualFrameIndex, 1)
    Assert.isNil(state:result())
    state:tick(1)
    Assert.equal(state:view().visualFrameIndex, 2)
    state:tick(9)
    Assert.equal(state:view().visualFrameIndex, 3)
    state:tick(9)
    Assert.equal(state:view().visualFrameIndex, 4)
    Assert.isNil(state:result())
    state:tick(9)
    Assert.isTrue(state:view().phase ~= "complete", "the last shrink frame must enter the cover, not complete")
    Assert.isNil(state:result())
    Assert.near(state:view().finalFadeAlpha, 0, 1e-9)
    for _, alpha in ipairs({ 2 / 16, 5 / 16, 7 / 16, 10 / 16, 13 / 16, 1 }) do
      state:tick(1)
      Assert.near(state:view().finalFadeAlpha, alpha, 1e-9)
    end
    Assert.isTrue(state:view().phase ~= "complete", "full black must wait for presentation acknowledgement")
    Assert.isNil(state:result(), "the candidate stays unpublished until the black frame is presented")
    Assert.isTrue(state:confirmHandoffPresented(), "acknowledging the presented black frame finalizes the handoff")
    Assert.equal(state:view().phase, "complete")
    Assert.notNil(state:result())
    local handoffs = 0
    for _, event in ipairs(state:view().events) do
      if event.kind == "handoff" then
        handoffs = handoffs + 1
      end
    end
    Assert.equal(handoffs, 1)
    Assert.isFalse(state:confirmHandoffPresented(), "acknowledging after completion must not finalize a second handoff")
    state:tick(20)
    local repeatedHandoffs = 0
    for _, event in ipairs(state:view().events) do
      if event.kind == "handoff" then
        repeatedHandoffs = repeatedHandoffs + 1
      end
    end
    Assert.equal(repeatedHandoffs, 1)
  end
end

function T.shrink_animation_uses_each_generated_frame_duration()
  local assets = finalSequenceAssets()
  assets.shrink_male.frames = {
    { duration = 2 },
    { duration = 3 },
    { duration = 4 },
    { duration = 5 },
  }
  local state = nameConfirmation(false, { assets = assets })
  state:press("confirm")
  completeActiveMessage(state)
  state:tick(2)
  Assert.equal(state:view().phase, "final_full_art_hold")
  state:tick(30)
  Assert.equal(state:view().phase, "shrink_animation")
  Assert.equal(state:view().visualFrameIndex, 1)

  state:tick(2)
  Assert.equal(state:view().visualFrameIndex, 2)
  state:tick(3)
  Assert.equal(state:view().visualFrameIndex, 3)
  state:tick(4)
  Assert.equal(state:view().visualFrameIndex, 4)
  state:tick(5)
  Assert.isTrue(state:view().phase ~= "complete", "the last shrink frame must enter the cover, not complete")
  Assert.isNil(state:result())
  state:tick(6)
  Assert.near(state:view().finalFadeAlpha, 1, 1e-9, "the cover must reach full black")
  Assert.isTrue(state:view().phase ~= "complete", "full black must wait for presentation acknowledgement")
  Assert.isNil(state:result(), "the candidate stays unpublished until the black frame is presented")
  Assert.isTrue(state:confirmHandoffPresented(), "acknowledging the presented black frame finalizes the handoff")
  Assert.equal(state:view().phase, "complete")

  local oneFrameAssets = finalSequenceAssets()
  oneFrameAssets.shrink_male.frames = { { duration = 2 } }
  state = nameConfirmation(false, { assets = oneFrameAssets })
  state:press("confirm")
  completeActiveMessage(state)
  state:tick(2)
  state:tick(30)
  Assert.equal(state:view().phase, "shrink_animation")
  state:tick(1)
  Assert.equal(state:view().phase, "shrink_animation")
  state:tick(1)
  Assert.isTrue(state:view().phase ~= "complete", "the last shrink frame must enter the cover, not complete")
  Assert.isNil(state:result())
  state:tick(6)
  Assert.near(state:view().finalFadeAlpha, 1, 1e-9, "the cover must reach full black")
  Assert.isTrue(state:view().phase ~= "complete", "full black must wait for presentation acknowledgement")
  Assert.isNil(state:result(), "the candidate stays unpublished until the black frame is presented")
  Assert.isTrue(state:confirmHandoffPresented(), "acknowledging the presented black frame finalizes the handoff")
  Assert.equal(state:view().phase, "complete")
end

function T.virtual_keyboard_focus_reaches_delete_and_confirm_actions()
  local state = advanceToNameEdit()
  state:press("confirm")
  for _ = 1, 10 do
    state:press("right")
  end
  state:press("confirm")
  Assert.equal(state:view().name, "")
  state:press("right")
  state:press("confirm")
  Assert.equal(state:view().name, "Ethan")
end

function T.name_editor_vertical_navigation_uses_the_configured_column_count()
  local state = advanceToNameEdit()
  Assert.equal(state:view().phase, "name_edit")
  Assert.equal(state:view().virtualKeyColumns, 10)
  Assert.equal(state:view().virtualGlyphFocus, 1)
  state:press("down")
  Assert.equal(state:view().virtualGlyphFocus, 11)
  state:press("up")
  Assert.equal(state:view().virtualGlyphFocus, 1)
end

function T.source_scroll_endpoint_survives_non_slide_phases_and_reverse_starts_there()
  local state = controller()
  state:start()
  state:tick(40)
  completeActiveMessage(state)
  state:tick(6 + 30)
  completeActiveMessage(state)
  Assert.equal(state:view().phase, "oak_slide_right")
  local sourceScroll = { state:view().oakBgScrollX }
  for _ = 1, 26 do
    state:tick(1)
    sourceScroll[#sourceScroll + 1] = state:view().oakBgScrollX
  end
  for index = 2, #sourceScroll do
    Assert.isTrue(
      sourceScroll[index] <= sourceScroll[index - 1],
      "Oak source BG scroll must decrease during right slide"
    )
  end
  local world = state:view()
  Assert.equal(world.phase, "oak_world_inhabited")
  Assert.equal(world.oakBgScrollX, -52)
  completeActiveMessage(state)
  advanceToPhase(state, "oak_live_alongside")
  Assert.equal(state:view().phase, "oak_live_alongside")
  Assert.equal(state:view().oakBgScrollX, -52)
  completeActiveMessage(state)
  advanceToPhase(state, "oak_slide_left")
  Assert.equal(state:view().phase, "oak_slide_left")
  Assert.equal(state:view().oakBgScrollX, -52)
  local reverseScroll = { state:view().oakBgScrollX }
  for _ = 1, 26 do
    state:tick(1)
    reverseScroll[#reverseScroll + 1] = state:view().oakBgScrollX
  end
  for index = 2, #reverseScroll do
    Assert.isTrue(
      reverseScroll[index] >= reverseScroll[index - 1],
      "Oak source BG scroll must increase during left slide"
    )
  end
  Assert.equal(reverseScroll[#reverseScroll], 0)
end

function T.finalization_handoff_keeps_reserved_identity_without_storage_publication()
  local state = controller()
  local calls = 0
  state:start()
  state:tick(40)
  completeActiveMessage(state)
  state:tick(6 + 30)
  completeActiveMessage(state)
  state:tick(26)
  completeActiveMessage(state)
  advanceToPhase(state, "oak_live_alongside")
  completeActiveMessage(state)
  advanceThroughHide(state)
  completeActiveMessage(state)
  completeActiveMessage(state)
  state:tick(26)
  state:press("confirm")
  completeActiveMessage(state)
  state:press("confirm")
  completeActiveMessage(state)
  state:tick(40)
  state:inputText("GOLD")
  state:press("submit")
  state:tick(26)
  completeActiveMessage(state)
  state:press("confirm")
  completeActiveMessage(state)
  state:tick(1 + 1 + 30)
  Assert.isTrue(state:view().phase ~= "complete", "completion must wait for the full-black cover")
  Assert.isNil(state:result())
  state:tick(6)
  Assert.near(state:view().finalFadeAlpha, 1, 1e-9, "the cover must reach full black")
  Assert.isTrue(state:view().phase ~= "complete", "full black must wait for presentation acknowledgement")
  Assert.isNil(state:result(), "the candidate stays unpublished until the black frame is presented")
  Assert.isTrue(state:confirmHandoffPresented(), "acknowledging the presented black frame finalizes the handoff")
  Assert.equal(state:view().phase, "complete")
  local result = assert(state:result())
  Assert.equal(result.saveId, "save-00000017")
  Assert.equal(result.playerData.profile.name, "GOLD")
  Assert.equal(result.playerData.profile.trainerId, 0x12345678)
  Assert.equal(calls, 0)
end

function T.blank_and_whitespace_names_resolve_to_the_gender_default_through_the_confirm_key()
  local cases = {
    { text = nil, female = false, expected = "Ethan" },
    { text = " ", female = false, expected = "Ethan" },
    { text = "   ", female = false, expected = "Ethan" },
    { text = nil, female = true, expected = "Lyra" },
    { text = " ", female = true, expected = "Lyra" },
    { text = "   ", female = true, expected = "Lyra" },
  }
  for _, case in ipairs(cases) do
    local state = advanceToNameEdit(nil, case.female)
    if case.text then
      Assert.isTrue(state:inputText(case.text))
    end
    focusConfirmKey(state)
    state:press("confirm")
    state:tick(26)
    Assert.equal(
      state:view().phase,
      "name_confirm",
      "a blank/whitespace-only name must still reach confirmation: " .. tostring(case.text)
    )
    Assert.equal(state:view().name, case.expected)
  end
end

function T.blank_name_default_survives_into_the_finalized_profile()
  for _, female in ipairs({ false, true }) do
    local state = advanceToNameEdit({ assets = finalSequenceAssets() }, female)
    focusConfirmKey(state)
    state:press("confirm")
    local expected = female and "Lyra" or "Ethan"
    Assert.equal(state:view().name, expected)
    state:tick(26)
    completeActiveMessage(state) -- name_confirm -> confirmation choice
    state:press("confirm") -- confirmation choice -> final_dialogue
    completeActiveMessage(state) -- final_dialogue -> final_fade_out
    state:tick(1) -- final_fade_out -> final_full_art_fade_in
    state:tick(1) -- final_full_art_fade_in -> final_full_art_hold
    advanceToPhase(state, "shrink_animation")
    state:tick(9 * 4)
    Assert.isTrue(state:view().phase ~= "complete", "completion must wait for the full-black cover")
    Assert.isNil(state:result())
    state:tick(6)
    Assert.near(state:view().finalFadeAlpha, 1, 1e-9, "the cover must reach full black")
    Assert.isTrue(state:view().phase ~= "complete", "full black must wait for presentation acknowledgement")
    Assert.isNil(state:result(), "the candidate stays unpublished until the black frame is presented")
    Assert.isTrue(state:confirmHandoffPresented(), "acknowledging the presented black frame finalizes the handoff")
    Assert.equal(state:view().phase, "complete")
    Assert.equal(assert(state:result()).playerData.profile.name, expected)
  end
end

function T.nonblank_names_are_preserved_exactly_through_the_confirm_key()
  local cases = { "A", "GOLD", "ABCDEGO", "A B" }
  for _, name in ipairs(cases) do
    local state = advanceToNameEdit()
    Assert.isTrue(state:inputText(name), "generated charmap must accept: " .. name)
    focusConfirmKey(state)
    state:press("confirm")
    state:tick(26)
    Assert.equal(state:view().phase, "name_confirm", "a valid nonblank name must reach confirmation: " .. name)
    Assert.equal(state:view().name, name, "the entered name must not be trimmed or replaced")
  end
end

function T.invalid_or_oversized_input_is_rejected_without_ever_defaulting()
  local state = advanceToNameEdit()
  Assert.isTrue(state:inputText("ABCDEGO"))
  Assert.isFalse(state:inputText("L"), "an eighth glyph must be rejected by the existing capacity contract")
  Assert.equal(state:view().name, "ABCDEGO")
  Assert.isFalse(state:inputText("!"), "an unencodable glyph must be rejected by the generated charmap")
  Assert.equal(state:view().name, "ABCDEGO")
  focusConfirmKey(state)
  state:press("confirm")
  Assert.equal(state:view().name, "ABCDEGO", "rejected input must never be silently replaced by a default")
end

function T.name_submission_advances_directly_to_name_placement_over_twenty_six_frames()
  local state = advanceToNameEdit()
  Assert.equal(state:view().genderCompositionProgress, 1)
  state:inputText("GOLD")
  state:press("submit")
  Assert.equal(state:view().genderCompositionProgress, 1, "name submit must keep gender composition at 1")
  local progress = state:view().nameCompositionProgress
  Assert.notNil(progress, "name composition progress must be exposed")
  Assert.equal(progress, 0)
  local previous = 0
  for _ = 1, 25 do
    state:tick(1)
    local view = state:view()
    Assert.equal(view.genderCompositionProgress, 1)
    local current = assert(view.nameCompositionProgress)
    Assert.isTrue(current > previous, "name progress must strictly increase each tick")
    Assert.isTrue(current > 0 and current < 1)
    Assert.isTrue(view.phase ~= "name_confirm", "name_confirm must wait for forward transition")
    previous = current
  end
  state:tick(1)
  local finished = state:view()
  Assert.equal(finished.genderCompositionProgress, 1)
  Assert.equal(finished.nameCompositionProgress, 1)
  Assert.equal(finished.phase, "name_confirm")
  Assert.equal(finished.name, "GOLD")
end

function T.affirmative_name_answer_keeps_name_placement()
  local state = nameConfirmation(false)
  Assert.equal(state:view().genderCompositionProgress, 1)
  local progressBefore = assert(state:view().nameCompositionProgress)
  Assert.equal(progressBefore, 1)
  state:press("yes")
  local after = state:view()
  Assert.equal(after.phase, "final_dialogue")
  Assert.equal(after.messageKey, "profile.final")
  Assert.equal(after.genderCompositionProgress, 1)
  Assert.equal(assert(after.nameCompositionProgress), 1, "YES must keep name composition at 1")
end

function T.rejected_name_returns_to_gender_placement_over_twenty_six_frames()
  local state = advanceToNameEdit()
  state:inputText("GOLD")
  state:press("submit")
  state:tick(26)
  Assert.equal(state:view().phase, "name_confirm")
  completeActiveMessage(state)
  state:press("cancel")
  Assert.equal(state:view().phase, "gender_question")
  Assert.equal(state:view().genderCompositionProgress, 1)
  Assert.equal(assert(state:view().nameCompositionProgress), 1, "rejected question must keep name progress at 1")
  completeActiveMessage(state)
  local start = state:view()
  -- closing gender_question must start return transition without consuming a frame
  Assert.equal(assert(start.nameCompositionProgress), 1, "return must start at 1 before ticking")
  Assert.isTrue(start.phase ~= "gender_select", "gender_select must wait for return transition")
  state:tick(1)
  Assert.isTrue(assert(state:view().nameCompositionProgress) < 1, "progress must decrease after first tick")
  for _ = 1, 24 do
    state:tick(1)
  end
  state:tick(1)
  local finished = state:view()
  Assert.equal(finished.phase, "gender_select")
  Assert.equal(finished.genderCompositionProgress, 1)
  Assert.equal(finished.nameCompositionProgress, 0)
end

-- Drives a male profile through the final dialogue into the shrink
-- animation using the full-art/shrink fixture, matching the existing
-- final-handoff flow in this suite.
local function advanceToShrinkAnimation()
  local state = nameConfirmation(false, { assets = finalSequenceAssets() })
  state:press("confirm")
  Assert.equal(state:view().phase, "final_dialogue")
  completeActiveMessage(state)
  Assert.equal(state:view().phase, "final_fade_out")
  state:tick(2)
  Assert.equal(state:view().phase, "final_full_art_hold")
  state:tick(30)
  Assert.equal(state:view().phase, "shrink_animation")
  return state
end

local function tickToShrinkEnd(state)
  for _ = 1, 9 * 4 - 1 do
    state:tick(1)
    Assert.equal(state:view().phase, "shrink_animation", "shrink must not finish early")
    Assert.isNil(state:result(), "no candidate may publish before the shrink visual completes")
  end
end

function T.shrink_completion_enters_the_covered_handoff_instead_of_completing()
  local state = advanceToShrinkAnimation()
  tickToShrinkEnd(state)
  state:tick(1)
  Assert.isTrue(
    state:view().phase ~= "complete",
    "the last shrink frame must enter the post-shrink cover, not complete (got complete)"
  )
  Assert.isNil(state:result(), "the candidate must stay unpublished while the cover is not yet black")
  Assert.near(state:view().finalFadeAlpha, 0, 1e-9, "the cover starts transparent over the shrink visual")
end

function T.covered_handoff_waits_at_full_black_until_presentation_is_acknowledged()
  local state = advanceToShrinkAnimation()
  tickToShrinkEnd(state)
  state:tick(1)
  local expected = { 2 / 16, 5 / 16, 7 / 16, 10 / 16, 13 / 16, 1 }
  for step, alpha in ipairs(expected) do
    state:tick(1)
    Assert.near(
      state:view().finalFadeAlpha,
      alpha,
      1e-9,
      "cover step " .. step .. " must follow the shared outward fade"
    )
    if step < #expected then
      Assert.isTrue(
        state:view().phase ~= "complete",
        "completion must wait for full black (leaked at cover step " .. step .. ")"
      )
      Assert.isNil(state:result(), "the candidate must stay unpublished before full black")
    end
  end
  Assert.isTrue(state:view().phase ~= "complete", "full black must wait for presentation acknowledgement")
  Assert.isNil(state:result(), "the candidate must stay unpublished until the black frame is presented")
  Assert.isTrue(state:confirmHandoffPresented(), "acknowledging the presented black frame finalizes the handoff")
  Assert.equal(state:view().phase, "complete")
  Assert.notNil(state:result(), "the finalized candidate publishes after the presented full black")
  Assert.near(state:view().finalFadeAlpha, 1, 1e-9, "completion keeps the full-black cover")
  local handoffs = 0
  for _, event in ipairs(state:view().events) do
    if event.kind == "handoff" then
      handoffs = handoffs + 1
    end
  end
  Assert.equal(handoffs, 1)
  state:tick(20)
  Assert.equal(state:view().phase, "complete")
  Assert.near(state:view().finalFadeAlpha, 1, 1e-9, "the completed cover stays black")
end

-- The full-black cover is a waiting state, not completion: the finalized
-- candidate stays unpublished until the host presents the black frame and the
-- state acknowledges that presentation on a later update.
function T.full_black_cover_waits_for_presentation_before_publishing_the_candidate()
  local state = advanceToShrinkAnimation()
  tickToShrinkEnd(state)
  state:tick(1)
  Assert.isTrue(
    state:view().phase ~= "complete",
    "the last shrink frame must enter the post-shrink cover, not complete"
  )
  Assert.isNil(state:result(), "the candidate must stay unpublished while the cover is not yet black")
  for step = 1, 5 do
    state:tick(1)
    Assert.isTrue(
      state:view().phase ~= "complete",
      "the cover must not complete before full black (leaked at cover step " .. step .. ")"
    )
    Assert.isNil(state:result(), "the candidate must stay unpublished before full black")
  end
  state:tick(1)
  Assert.near(state:view().finalFadeAlpha, 1, 1e-9, "the cover must reach full black")
  Assert.isTrue(state:view().phase ~= "complete", "full black must wait for presentation acknowledgement, not complete")
  Assert.isNil(state:result(), "the candidate must stay unpublished until the black frame is presented")
  state:tick(20)
  Assert.isTrue(
    state:view().phase ~= "complete",
    "extra source ticks without presentation acknowledgement must not complete"
  )
  Assert.isNil(state:result(), "the candidate must stay unpublished without presentation acknowledgement")
  Assert.near(state:view().finalFadeAlpha, 1, 1e-9, "the waiting cover stays black")
end

return { tests = T }
