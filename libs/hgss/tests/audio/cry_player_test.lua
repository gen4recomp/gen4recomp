-- CryPlayer contract: standard pattern-0 cries resolve the generated generic
-- cry sequence and the species bank through the shared engine player. The
-- player owns busy/completion state; this suite pins the subsystem the
-- production composition injects.

local Assert = require("tests.support.Assert")
local AudioErrors = require("libs.hgss.src.audio.AudioErrors")
local Errors = require("libs.errors.src.Errors")
local CryPlayer = require("libs.hgss.src.audio.CryPlayer")

local T = {}

local function newRecordingCry()
  local sequence = { id = 2, bankId = 0, player = { id = 3 } }
  local bank = { id = 183 }
  local state = {
    sequenceId = nil,
    bankId = nil,
    startCount = 0,
    stopCount = 0,
    playing = false,
    pitchChanges = {},
    faderChanges = {},
  }
  local provider = {
    sequence = function(_, id)
      state.sequenceId = id
      return sequence
    end,
    bank = function(_, id)
      state.bankId = id
      bank.id = id
      return bank
    end,
  }
  ---@cast provider AudioAssetProvider
  local player = {
    createHandle = function()
      return state
    end,
    stopHandle = function(_, handle)
      state.stopCount = state.stopCount + 1
      handle.playing = false
    end,
    playSynthetic = function()
      state.synthetic = true
      state.playing = true
      return true
    end,
    playWithBankOverride = function(_, handle, resolvedSequence, resolvedBank)
      state.startCount = state.startCount + 1
      state.startedSequence = resolvedSequence
      state.startedBank = resolvedBank
      handle.playing = true
      return true
    end,
    setHandleTrackPitch = function(_, handle, pitch)
      state.pitchHandle = handle
      state.pitchChanges[#state.pitchChanges + 1] = pitch
    end,
    setHandleFader = function(_, handle, level)
      state.faderHandle = handle
      state.faderChanges[#state.faderChanges + 1] = level
    end,
    isHandlePlaying = function(_, handle)
      return handle.playing
    end,
  }
  ---@cast player SequencePlayer
  return CryPlayer.new({ player = player, provider = provider }), state, provider
end

function T.standard_cries_use_the_generic_sequence_and_species_bank()
  local cry, state = newRecordingCry()
  Assert.isTrue(cry:isFinished(), "an idle cry is finished")

  cry:play(183, 0)

  Assert.equal(state.sequenceId, 2, "standard cries resolve generated sequence 2")
  Assert.equal(state.bankId, 183, "standard cries resolve the species bank")
  Assert.equal(state.startCount, 1, "the cry starts through the shared player")
  Assert.isFalse(state.synthetic == true, "standard cries must not use synthetic assets")
  Assert.isFalse(cry:isFinished(), "busy state follows the started playback handle")

  state.playing = false
  Assert.isTrue(cry:isFinished(), "completion follows the playback handle")
end

function T.replacing_a_cry_stops_the_previous_handle()
  local cry, state = newRecordingCry()
  cry:play(183, 0)
  cry:play(25, 0)

  Assert.equal(state.stopCount, 2, "each start replaces the previous cry handle explicitly")
  Assert.equal(state.bankId, 25, "the replacement resolves its own species bank")
  Assert.isFalse(cry:isFinished(), "the replacement cry remains busy")
end

function T.unsupported_cry_patterns_fail_at_the_semantic_boundary()
  local cry = newRecordingCry()
  local err = Assert.throws(function()
    cry:play(183, 99)
  end)
  Assert.isTrue(Errors.is(err), "unsupported cries must use a structured audio error")
  Assert.equal(err.code, AudioErrors.AUDIO_CRY_UNAVAILABLE)
end

function T.species_and_pattern_are_finite_integers_in_the_standard_domain()
  local cry = newRecordingCry()
  for _, species in ipairs({ 0, 183.5, 494 }) do
    local err = Assert.throws(function()
      cry:play(species --[[@as integer]], 0)
    end)
    Assert.isTrue(Errors.is(err))
    Assert.equal(err.code, AudioErrors.AUDIO_CRY_UNAVAILABLE)
  end
  local err = Assert.throws(function()
    local invalidPattern = 0.5
    ---@cast invalidPattern integer
    cry:play(183, invalidPattern)
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, AudioErrors.AUDIO_CRY_UNAVAILABLE)
end

function T.pattern_11_applies_external_pitch_after_standard_admission()
  local cry, state = newRecordingCry()
  cry:play(183, 11)

  Assert.deepEqual(state.pitchChanges, { 0, -96 }, "pattern 11 modifies the admitted cry handle")
  Assert.equal(state.pitchHandle, state, "pattern pitch stays on the private handle")
end

function T.pattern_1_runs_the_source_twenty_tick_cleanup()
  local cry, state = newRecordingCry()
  cry:play(183, 1)

  for _ = 1, 10 do
    cry:update()
  end
  Assert.deepEqual(state.faderChanges, {}, "pattern 1 keeps the cry audible before the cleanup midpoint")
  cry:update()
  Assert.deepEqual(state.faderChanges, { 0 }, "pattern 1 fades the private cry handle at tick 11")
  for _ = 1, 9 do
    cry:update()
  end
  Assert.equal(state.stopCount, 2, "pattern 1 stops the private cry handle at tick 20")
end

function T.pattern_12_combines_cleanup_with_source_pitch()
  local cry, state = newRecordingCry()
  cry:play(183, 12)

  Assert.deepEqual(state.pitchChanges, { 0, -96 }, "pattern 12 applies the source pitch modifier")
  for _ = 1, 11 do
    cry:update()
  end
  Assert.deepEqual(state.faderChanges, { 0 }, "pattern 12 applies the same cleanup task as pattern 1")
end

function T.missing_standard_assets_keep_provider_error_attribution()
  local cry, _, provider = newRecordingCry()
  provider.sequence = function()
    Errors.raise(AudioErrors.AUDIO_PROVIDER_SEQUENCE_UNKNOWN, "missing sequence")
    error("unreachable")
  end
  local sequenceErr = Assert.throws(function()
    cry:play(183, 0)
  end)
  Assert.isTrue(Errors.is(sequenceErr))
  Assert.equal(sequenceErr.code, AudioErrors.AUDIO_PROVIDER_SEQUENCE_UNKNOWN)

  local cryWithBank, _, bankProvider = newRecordingCry()
  bankProvider.bank = function()
    Errors.raise(AudioErrors.AUDIO_PROVIDER_BANK_UNKNOWN, "missing bank")
    error("unreachable")
  end
  local bankErr = Assert.throws(function()
    cryWithBank:play(183, 0)
  end)
  Assert.isTrue(Errors.is(bankErr))
  Assert.equal(bankErr.code, AudioErrors.AUDIO_PROVIDER_BANK_UNKNOWN)
end
function T.construction_requires_the_engine_player_and_provider()
  Assert.isFalse(pcall(CryPlayer.new, {}), "a cry player without its collaborators is a composition fault")
end

return { tests = T }
