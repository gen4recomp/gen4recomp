-- Production audio/script boundary scenarios for field cry playback.

local Assert = require("tests.support.Assert")
local CryPlayer = require("libs.hgss.src.audio.CryPlayer")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
local SoundWaitTask = require("libs.hgss.src.script.tasks.SoundWaitTask")

local function recordingCry()
  local sequence = { id = 2, bankId = 0, player = { id = 3 } }
  local state = {
    sequenceId = nil,
    bankId = nil,
    pitch = nil,
    pitchChanges = {},
    startedHandle = nil,
    playing = false,
    stopCount = 0,
  }
  local provider = {
    sequence = function(_, id)
      state.sequenceId = id
      return sequence
    end,
    bank = function(_, id)
      state.bankId = id
      return { id = id }
    end,
  }
  ---@cast provider AudioAssetProvider
  local handle = {}
  state.handle = handle
  local player = {
    createHandle = function()
      return handle
    end,
    stopHandle = function(_, attached)
      Assert.equal(attached, handle, "cry replacement stops its private handle")
      state.stopCount = state.stopCount + 1
      state.playing = false
    end,
    playWithBankOverride = function(_, attached, resolvedSequence, resolvedBank)
      state.startedHandle = attached
      state.startedSequence = resolvedSequence
      state.startedBank = resolvedBank
      state.playing = true
      return true
    end,
    setHandleTrackPitch = function(_, attached, pitch)
      Assert.equal(attached, handle, "cry pitch stays on the private handle")
      state.pitch = pitch
      state.pitchChanges[#state.pitchChanges + 1] = pitch
    end,
    isHandlePlaying = function(_, attached)
      Assert.equal(attached, handle, "cry completion reads its private handle")
      return state.playing
    end,
  }
  ---@cast player SequencePlayer
  return CryPlayer.new({ player = player, provider = provider }), state
end

local function runtimeWithAudio(audio)
  local tasks = {}
  local run = {
    instance = { scriptId = "field-cry", locals = {}, textArgs = {} },
    services = { audio = audio },
    semantics = RuntimeValues,
    scheduler = {
      createTask = function(_, taskType, spec)
        tasks[#tasks + 1] = { type = taskType, spec = spec }
        return "task:" .. taskType
      end,
    },
    tick = 1,
    input = {},
  }
  return run, tasks
end

local T = {}

function T.standard_cry_uses_sequence_two_and_species_bank()
  local cry, state = recordingCry()

  cry:play(183, 0)

  Assert.equal(state.sequenceId, 2, "pattern 0 admits generic cry sequence 2")
  Assert.equal(state.bankId, 183, "pattern 0 admits the requested species bank")
  Assert.equal(state.startedHandle, state.handle, "playback has an attached cry handle")
  Assert.equal(state.pitchChanges[1], 0, "pattern 0 starts with no external pitch")
  Assert.isFalse(cry:isFinished(), "an admitted cry remains active")

  state.playing = false
  Assert.isTrue(cry:isFinished(), "completion follows the private cry handle")
end

function T.play_cry_pattern_11_applies_source_pitch()
  local cry, state = recordingCry()

  cry:play(183, 11)
  Assert.equal(state.sequenceId, 2, "pattern 11 keeps the generic cry sequence")
  Assert.equal(state.bankId, 183, "pattern 11 keeps the species bank")
  Assert.equal(state.pitchChanges[1], 0, "a new cry instance starts with a reset pitch")
  Assert.equal(state.pitchChanges[2], -96, "pattern 11 applies the source pitch offset")
  Assert.isFalse(cry:isFinished(), "pattern 11 remains on the private cry handle")

  cry:play(183, 0)
  Assert.equal(state.pitchChanges[3], 0, "pattern 0 replacement clears the prior pitch")
  Assert.equal(state.stopCount, 2, "replacement stops the previous private cry instance")
end

function T.wait_cry_ignores_unrelated_audio()
  local cryFinished = false
  local unrelatedEffectFinished = false
  local played = {}
  local audio = {
    playCry = function(_, species, pattern)
      played[#played + 1] = { species = species, pattern = pattern }
    end,
    isCryFinished = function()
      return cryFinished
    end,
    isEffectWaitComplete = function()
      return unrelatedEffectFinished
    end,
  }
  local run, tasks = runtimeWithAudio(audio)

  Assert.equal(Runtime.executeNode({ op = "play_cry", species = 183, pattern = 11 }, run), Runtime.OUTCOME_CONTINUE)
  Assert.deepEqual(played, { { species = 183, pattern = 11 } }, "play_cry forwards the pattern value")

  Assert.equal(Runtime.executeNode({ op = "wait_cry" }, run), Runtime.OUTCOME_BLOCK)
  local task = assert(tasks[1], "wait_cry creates one sound-wait task")
  local context = { services = run.services, instance = run.instance }
  local state = SoundWaitTask.create(task.spec, context)
  local pending = SoundWaitTask.poll(state, context)
  Assert.isFalse(pending.complete == true, "wait_cry remains blocked while the cry is active")

  cryFinished = true
  local complete = SoundWaitTask.poll(state, context)
  Assert.isTrue(complete.complete == true, "wait_cry resumes when the cry handle finishes")
  Assert.isFalse(unrelatedEffectFinished, "unrelated audio remains active when wait_cry resumes")
end

return { tests = T }
