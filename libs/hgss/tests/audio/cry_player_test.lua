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
    initialVolume = 100,
    pan = 0,
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
    setHandleInitialVolume = function(_, _, level)
      state.initialVolume = level
    end,
    setHandleTrackPan = function(_, _, pan)
      state.pan = pan
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

function T.play_cry_pattern_11_applies_source_pitch()
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
  Assert.isTrue(#state.faderChanges > 0, "pattern 1 starts its cleanup ramp at the midpoint")
  Assert.isTrue(
    state.faderChanges[#state.faderChanges] > 0,
    "pattern 1 does not mute the private cry handle at the midpoint"
  )
  for _ = 1, 9 do
    cry:update()
  end
  Assert.equal(state.faderChanges[#state.faderChanges], 0, "pattern 1 reaches silence on the cleanup endpoint")
  Assert.equal(state.stopCount, 2, "pattern 1 stops the private cry handle at tick 20")
end

function T.pattern_12_combines_cleanup_with_source_pitch()
  local cry, state = newRecordingCry()
  cry:play(183, 12)

  Assert.deepEqual(state.pitchChanges, { 0, -96 }, "pattern 12 applies the source pitch modifier")
  for _ = 1, 11 do
    cry:update()
  end
  Assert.isTrue(#state.faderChanges > 0, "pattern 12 starts the cleanup ramp")
  Assert.isTrue(state.faderChanges[#state.faderChanges] > 0, "pattern 12 is not immediately muted")
end

-- Recording collaborators expose the semantic resource boundary used by the
-- cry owner. They intentionally contain no NNS implementation, PCM mixer, or
-- production composition: the source scenarios only observe what CryPlayer
-- asks those owners to start and control.
local function newPatternRecordingCry()
  local sampleKey = "cry-species-183"
  local sample = {
    metadata = { frames = 4, baseTimer = 8006, loopEnabled = false, loop = { startFrame = 0, endFrame = 4 } },
    pcm = { 101, 202, 303, 404 },
  }
  local sequence = {
    id = 2,
    bankId = 0,
    player = { id = 3, initialVolume = 100 },
  }
  local bank = {
    id = 183,
    instruments = {
      [0] = {
        kind = "direct",
        voice = { generator = { kind = "sample", sample = sampleKey } },
      },
    },
  }
  local state = {
    nextSequenceHandle = 0,
    sequenceHandles = {},
    waveHandles = {},
    sequenceStarts = {},
    waveStarts = {},
    faderWrites = {},
    sourceSample = sample,
  }

  local provider = {
    sequence = function(_, id)
      Assert.equal(id, 2, "every cry pattern uses generated sequence 2")
      return sequence
    end,
    bank = function(_, id)
      Assert.equal(id, 183, "the cry resolves the requested species bank")
      return bank
    end,
    loadSample = function(_, key)
      Assert.equal(key, sampleKey, "direct-wave playback uses the species bank sample")
      return sample
    end,
  }
  ---@cast provider AudioAssetProvider

  local player = {
    createHandle = function()
      state.nextSequenceHandle = state.nextSequenceHandle + 1
      local handle = {
        kind = "sequence",
        name = "sequence:" .. tostring(state.nextSequenceHandle),
        playing = false,
        controls = { pitch = 0, pan = 0, initialVolume = sequence.player.initialVolume, fader = 127 },
      }
      state.sequenceHandles[#state.sequenceHandles + 1] = handle
      return handle
    end,
    stopHandle = function(_, handle)
      handle.playing = false
      handle.stopCount = (handle.stopCount or 0) + 1
    end,
    playWithBankOverride = function(_, handle, resolvedSequence, resolvedBank)
      Assert.equal(resolvedSequence, sequence)
      Assert.equal(resolvedBank, bank)
      handle.playing = true
      state.sequenceStarts[#state.sequenceStarts + 1] = handle
      return true
    end,
    setHandleInitialVolume = function(_, handle, level)
      handle.controls.initialVolume = level
    end,
    setHandleTrackPan = function(_, handle, pan)
      handle.controls.pan = pan
    end,
    setHandleTrackPitch = function(_, handle, pitch)
      handle.controls.pitch = pitch
    end,
    setHandleFader = function(_, handle, level)
      handle.controls.fader = level
      state.faderWrites[#state.faderWrites + 1] = { handle = handle, level = level }
    end,
    isHandlePlaying = function(_, handle)
      return handle.playing
    end,
  }
  ---@cast player SequencePlayer

  local waveOut = {
    start = function(_, channel, resolvedSample, options)
      local playbackSample = resolvedSample
      if options.reverse then
        local reversed = {}
        for index = #resolvedSample.pcm, 1, -1 do
          reversed[#reversed + 1] = resolvedSample.pcm[index]
        end
        playbackSample = { metadata = resolvedSample.metadata, pcm = reversed }
      end
      local handle = {
        kind = "wave",
        channel = channel,
        sample = playbackSample,
        volume = options.volume,
        pan = options.pan,
        speed = options.speed,
        reverse = options.reverse,
        playing = true,
      }
      state.waveHandles[#state.waveHandles + 1] = handle
      state.waveStarts[#state.waveStarts + 1] = handle
      return handle
    end,
    isPlaying = function(_, handle)
      return handle.playing
    end,
    stop = function(_, handle)
      handle.playing = false
      handle.stopCount = (handle.stopCount or 0) + 1
    end,
    setVolume = function(_, handle, volume)
      handle.volume = volume
    end,
    setPan = function(_, handle, pan)
      handle.pan = pan
    end,
    setSpeed = function(_, handle, speed)
      handle.speed = speed
    end,
  }
  ---@cast waveOut WaveOutPlayer

  return CryPlayer.new({ player = player, provider = provider, waveOut = waveOut }), state
end

local function sequenceControls(state)
  local controls = {}
  for _, handle in ipairs(state.sequenceStarts) do
    controls[#controls + 1] = {
      pitch = handle.controls.pitch,
      pan = handle.controls.pan,
      initialVolume = handle.controls.initialVolume,
      fader = handle.controls.fader,
    }
  end
  return controls
end

local function recordPatternFailure(failures, pattern, check)
  local ok, err = pcall(check)
  if not ok then
    failures[#failures + 1] = tostring(pattern) .. ": " .. tostring(err)
  end
end

function T.all_retail_integer_patterns_start_a_defined_cry_resource_plan()
  local failures = {}
  for pattern = 0, 14 do
    recordPatternFailure(failures, pattern, function()
      local cry, state = newPatternRecordingCry()
      cry:play(183, pattern)
      local wavePattern = pattern == 4 or pattern == 9
      if wavePattern then
        Assert.isTrue(#state.waveStarts > 0, "direct-wave starts WaveOut")
      else
        Assert.isTrue(#state.sequenceStarts > 0, "sequence pattern starts a cry")
      end
    end)
  end
  Assert.isTrue(
    #failures == 0,
    "retail cry patterns rejected or had no resource plan: " .. table.concat(failures, " | ")
  )
end

function T.complex_patterns_keep_their_source_voice_families_and_controls()
  local failures = {}
  recordPatternFailure(failures, 2, function()
    local cry, state = newPatternRecordingCry()
    cry:play(183, 2)
    Assert.deepEqual(sequenceControls(state), {
      { pitch = 64, pan = 0, initialVolume = 100, fader = 127 },
      { pitch = 20, pan = 0, initialVolume = 70, fader = 127 },
    }, "pattern 2 keeps both source sequence voices and their controls")
  end)

  recordPatternFailure(failures, 4, function()
    local cry, state = newPatternRecordingCry()
    cry:play(183, 4)
    Assert.deepEqual(state.waveStarts, {
      {
        kind = "wave",
        channel = 14,
        sample = state.waveStarts[1].sample,
        volume = 100,
        pan = 64,
        speed = 0x8600,
        reverse = true,
        playing = true,
      },
      {
        kind = "wave",
        channel = 15,
        sample = state.waveStarts[2].sample,
        volume = 70,
        pan = 64,
        speed = 0x8600,
        reverse = true,
        playing = true,
      },
    }, "pattern 4 uses both fixed WaveOut channels with reversed samples")
    Assert.isFalse(state.waveStarts[1].sample == state.waveStarts[2].sample, "each wave owns its playback buffer")
    Assert.deepEqual(state.waveStarts[1].sample.pcm, { 404, 303, 202, 101 }, "pattern 4 reverses a private sample")
    Assert.deepEqual(state.sourceSample.pcm, { 101, 202, 303, 404 }, "the cached sample stays unchanged")
  end)

  recordPatternFailure(failures, 9, function()
    local cry, state = newPatternRecordingCry()
    cry:play(183, 9)
    Assert.equal(#state.waveStarts, 1, "pattern 9 uses one direct-wave voice")
    Assert.equal(state.waveStarts[1].channel, 14)
    Assert.equal(state.waveStarts[1].speed, 0x6800)
    Assert.equal(state.waveStarts[1].pan, 64)
    Assert.equal(state.waveStarts[1].volume, 100)
    Assert.isTrue(state.waveStarts[1].reverse, "pattern 9 reverses its private sample")
  end)

  recordPatternFailure(failures, 13, function()
    local cry, state = newPatternRecordingCry()
    cry:play(183, 13)
    Assert.deepEqual(sequenceControls(state), {
      { pitch = 0, pan = 0, initialVolume = 127, fader = 127 },
      { pitch = 20, pan = 0, initialVolume = 100, fader = 100 },
    }, "pattern 13 applies the primary volume and immediate secondary move")
  end)
  Assert.isTrue(#failures == 0, "complex cry patterns missing source behavior: " .. table.concat(failures, " | "))
end

function T.cry_completion_waits_for_every_owned_voice()
  local cry, state = newPatternRecordingCry()
  cry:play(183, 2)
  Assert.isFalse(cry:isFinished(), "a multi-voice cry is busy while both voices play")
  state.sequenceStarts[1].playing = false
  Assert.isFalse(cry:isFinished(), "completion ignores neither the secondary cry voice nor its owner")
  state.sequenceStarts[2].playing = false
  Assert.isTrue(cry:isFinished(), "completion follows the complete private cry lifecycle")
end

function T.invalid_domain_requests_preserve_an_active_cry()
  local cry, state = newRecordingCry()
  cry:play(183, 0)
  local activeHandle = state
  for _, request in ipairs({
    { species = 0, pattern = 0 },
    { species = 494, pattern = 0 },
    { species = 183, pattern = 15 },
  }) do
    local err = Assert.throws(function()
      cry:play(request.species, request.pattern)
    end)
    Assert.isTrue(Errors.is(err))
    Assert.equal(err.code, AudioErrors.AUDIO_CRY_UNAVAILABLE)
    Assert.isTrue(activeHandle.playing, "domain rejection leaves the prior active cry untouched")
    Assert.equal(state.startCount, 1, "domain rejection does not start a replacement")
  end
end

function T.partial_direct_wave_construction_releases_the_first_channel()
  local cry, state = newPatternRecordingCry()
  local first = state.waveHandles
  local waveOut = {
    start = function(_, channel, sample, options)
      if channel == 15 then
        return nil
      end
      local handle = { channel = channel, sample = sample, options = options, playing = true }
      first[#first + 1] = handle
      return handle
    end,
    stop = function(_, handle)
      handle.playing = false
      handle.stopCount = (handle.stopCount or 0) + 1
    end,
    isPlaying = function(_, handle)
      return handle.playing
    end,
  }
  ---@cast waveOut WaveOutPlayer
  local player = {
    createHandle = function()
      return { playing = false }
    end,
    stopHandle = function(_, handle)
      handle.playing = false
    end,
  }
  ---@cast player SequencePlayer
  local provider = {
    bank = function(_, id)
      Assert.equal(id, 183)
      return {
        id = 183,
        instruments = {
          [0] = { kind = "direct", voice = { generator = { kind = "sample", sample = "sample" } } },
        },
      }
    end,
    loadSample = function()
      return { metadata = { loop = { startFrame = 0, endFrame = 4 } }, pcm = { 1, 2, 3, 4 } }
    end,
  }
  ---@cast provider AudioAssetProvider
  cry = CryPlayer.new({
    player = player,
    provider = provider,
    waveOut = waveOut,
  })
  local err = Assert.throws(function()
    cry:play(183, 4)
  end)
  Assert.isTrue(Errors.is(err) or type(err) == "string", "the failed construction remains diagnosable")
  Assert.equal(#first, 1, "the first direct-wave resource was acquired before the failure")
  Assert.equal(first[1].stopCount, 1, "partial direct-wave construction releases channel 14")
  Assert.isTrue(cry:isFinished(), "a failed direct-wave construction leaves no active cry")
end

function T.a_new_cry_restores_full_fader_after_cleanup()
  local cry, state = newPatternRecordingCry()
  cry:play(183, 1)
  for _ = 1, 20 do
    cry:update()
  end
  cry:play(183, 0)
  local primary = state.sequenceStarts[#state.sequenceStarts]
  Assert.equal(primary.controls.fader, 127, "a replacement cry restores the private fader to full")
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
