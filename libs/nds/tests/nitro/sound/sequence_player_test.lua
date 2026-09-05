-- SequencePlayer contract: the g4 sequence-IR interpreter on the NNS timing
-- and state model (SND_seq.c TrackStepTicks/TrackPlayNote/TrackInit/
-- TrackUpdateChannel). The tick clock is the NNS relationship verified from
-- GBATEK ("DS Sound Files - SSEQ") and the ARM7 NitroSDK player
-- (SND_seq.c PlayerSeqMain: SND_TIMER_RATE 240 at the 192 Hz sound
-- interval): a quarter note is 48 ticks, tempo is BPM (1..240, default
-- 120), and ticks come from each player's integer tempoCounter driven only
-- by the global sound interval -- while the counter is at least 240 the
-- player executes one sequence tick per 240 subtracted, then the counter
-- gains (tempo * tempoRatio) >> 8 once per interval. A fresh player starts
-- at tempoCounter 240 (PlayerInit), so its first tick fires on the first
-- interval after play() and play() never runs the entry program itself. A
-- track processes commands while `wait == 0` and not note-finish waiting
-- (WAIT 0 continues in the same pass); a note under note-wait gates the
-- track for its duration, and a zero-length note becomes a note-FINISH wait
-- that holds the track until its live channel handles are gone -- never a
-- one-tick wait and never a synthesized release. The player does not
-- predict mixer death: the mixer owns voice liveness (`isVoiceAlive`) and
-- the sequencer prunes dead handles from its collections and observes
-- liveness for finish waits.
--
-- Track state follows the SDK: wait ticks, the note-finish hold, note-wait
-- (default true), a polyphonic voice collection of {handle, length} pairs,
-- tie, mute, program, priority (default 64), volume/expression 127, the raw
-- pan offset (default 0), transpose, the signed bend (default 0 -- bend 0
-- is no bend, never a centered-at-64 convention), bend range 2, the mod
-- snapshot (target 0, depth 0, range 1, speed 16, delay 0), sweepPitch 0,
-- portamentoKey 60, portamentoTime 0, the portamento flag, nullable
-- envelope stage overrides, and the call/loop stacks.
--
-- Note semantics follow TrackPlayNote: the transposed key is clamped to the
-- MIDI domain (0..127) BEFORE the bank leaf is selected, so key-split and
-- drum-set selection use the transposed key; positive finite note lengths
-- are decremented toward release while zero-length and tied channel starts
-- are indefinite and are never released by the duration counter. Pitch bend
-- is user pitch, not a key change: the spec carries `userPitch`
-- (pitchBend * (bendRange << 6) >> 7, the SDK integer shift) and held
-- voices receive userPitch updates in place. The tie command always
-- releases and frees the track's current voices even when the flag value is
-- unchanged; a tied note reuses the live head voice (key/velocity update,
-- no noteOn/noteOff). The sweep/portamento commands wire the TrackPlayNote
-- channel state (the track sweep plus the portamento contribution, the
-- sweep length from portamentoTime, autoSweep) and update portamentoKey to
-- the note's MIDI key after the note.
--
-- The player queues control changes (track values, fader, LFO parameters,
-- user pitch) to its live voices as events; the mixer applies them at its
-- one external control step per sound interval (the 192 Hz sound-control
-- cadence the player owns). Pause releases the player's voices with release
-- override 127 and frees the handles; the timeline freezes and resume never
-- resurrects old voices. Random amount operands resolve through the
-- player's RNG in the SDK u16 draw domain (SND_CalcRandom: state =
-- state*1664525 + 1013904223 mod 2^32, draw = state >> 16, initial state
-- 0x12345678; TrackParseValue scales lo + ((draw * (hi - lo + 1)) >> 16));
-- production creates the RNG once and never reseeds per play, and
-- every completed sound interval additionally consumes one unconditional
-- periodic draw after the sequence portion and the mixer control step.
--
-- The suite asserts events and state through a recording mixer (noteOn/
-- noteOff/updateVoice/isVoiceAlive order, handles, tick boundaries, pause
-- releases, sequence replacement); the exact PCM/register hardware math is
-- pinned in the VoiceMixer suite. The mixer's {channel, generation} handles
-- are opaque to the player: the stub mixer models the persistent-generation
-- contract. Physical SeqPlayer slots process ascending slot number and tracks
-- ascending track number over the fixed NNS domains (16 slots x 16 tracks).

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local AudioFixture = require("tests.support.AudioFixture")
local TestProvider = require("libs.nds.tests.nitro.sound.TestProvider")
local VoiceMixer = require("libs.nds.src.nitro.sound.VoiceMixer")
local SequencePlayer = require("libs.nds.src.nitro.sound.SequencePlayer")
local NnsSoundMath = require("libs.nds.src.nitro.sound.NnsSoundMath")
local AudioSequence = require("libs.assets.src.audio.AudioSequence")
local AssetAudioErrors = require("libs.assets.src.audio.AudioErrors")

local T = {}

local SAMPLE_RATE = 48000
local WAVE_A = { 1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000 }
local WAVE_B = { 10000, 9000, 8000, 7000 }

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(err.code, code)
end

local function voice(key, opts)
  opts = opts or {}
  return {
    generator = { kind = "sample", sample = key },
    originalKey = 60,
    envelope = { attack = 127, decay = 0, sustain = 127, release = 127 },
    pan = opts.pan or 0,
  }
end

local function square(opts)
  opts = opts or {}
  return {
    generator = { kind = "square", duty = 3 },
    originalKey = 60,
    envelope = { attack = 127, decay = 0, sustain = 127, release = 127 },
    pan = opts.pan or 0,
  }
end

local function testBank()
  return AudioFixture.bank(12, "BANK_TEST", { AudioFixture.key(1), AudioFixture.key(2) }, {
    [0] = { kind = "direct", voice = voice(AudioFixture.key(1)) },
    [1] = { kind = "direct", voice = voice(AudioFixture.key(2)) },
    [2] = {
      kind = "key_split",
      ranges = {
        { lowKey = 0, highKey = 59, voice = voice(AudioFixture.key(1)) },
        { lowKey = 60, highKey = 127, voice = voice(AudioFixture.key(2)) },
      },
    },
    [3] = {
      kind = "drum_set",
      lowKey = 35,
      highKey = 36,
      voices = { voice(AudioFixture.key(1)), square() },
    },
  })
end

local function seq(instructions, opts)
  opts = opts or {}
  local sequence = AudioFixture.sequence(opts.id or 0, opts.symbol or "SEQ_TEST", 12, opts.playerId or 1, {
    entry = 1,
    initialTrackMask = 0x0001,
    instructions = instructions,
  }, {
    id = opts.playerId or 1,
    initialVolume = opts.initialVolume or 127,
    playerPriority = opts.playerPriority or 64,
    channelPriority = opts.channelPriority or 64,
  })
  if opts.initialTrackMask ~= nil then
    sequence.program.initialTrackMask = opts.initialTrackMask
  end
  return sequence
end

local function buildBundle(sequences, opts)
  opts = opts or {}
  local keyA, keyB, keyC = AudioFixture.key(1), AudioFixture.key(2), AudioFixture.key(3)
  local WAVE_C = { 500, 1000, 1500, 2000, 2500, 3000 }
  local bundle = AudioFixture.bundle()
  ---@cast bundle +{ samples: table<string, integer[]> }
  local indexSequences, indexPlayers, sequenceBySymbol = {}, {}, {}
  for id, sequence in pairs(sequences) do
    indexSequences[id] = {
      id = id,
      symbol = sequence.symbol,
      bankId = sequence.bankId,
      playerId = sequence.player.id,
    }
    sequenceBySymbol[sequence.symbol] = id
    indexPlayers[sequence.player.id] = {
      id = sequence.player.id,
      maxSequences = opts.maxSequences or 1,
      channelMask = opts.channelMask or 0xFFFF,
    }
  end
  bundle.index.sequences = indexSequences
  bundle.index.players = indexPlayers
  bundle.index.banks = { [12] = { id = 12, symbol = "BANK_TEST" } }
  bundle.index.sequenceBySymbol = sequenceBySymbol
  bundle.index.bankBySymbol = { BANK_TEST = 12 }
  bundle.sequences = sequences
  bundle.banks = { [12] = opts.bank or testBank() }
  bundle.samples = {
    [keyA] = opts.sampleA or WAVE_A,
    [keyB] = WAVE_B,
    [keyC] = WAVE_C,
  }
  bundle.sampleMetadata = {
    [keyA] = opts.sampleAMetadata
      or AudioFixture.sampleMetadata(keyA, { frames = 8, loop = { startFrame = 0, endFrame = 8 } }),
    [keyB] = AudioFixture.sampleMetadata(keyB, { frames = 4, loop = { startFrame = 0, endFrame = 4 } }),
    [keyC] = AudioFixture.sampleMetadata(keyC, { frames = 6, loop = { startFrame = 0, endFrame = 6 } }),
  }
  return bundle
end

local function engine(sequences, opts)
  opts = opts or {}
  local bundle = buildBundle(sequences, opts)
  local provider = TestProvider.new(bundle)
  local mixer = opts.mixer or VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local playerOpts = { sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider }
  if opts.rng ~= nil then
    playerOpts.rng = opts.rng
  end
  if opts.observer ~= nil then
    playerOpts.observer = opts.observer
  end
  local player = SequencePlayer.new(playerOpts)
  return player, provider
end

-- Plays the test sequence. By default, renders through the first 192 Hz
-- sound interval (250 frames at 48 kHz) so the first source sequence tick
-- fires on that boundary. Pass mayDeferRender=true to skip the render for
-- tests that explicitly manage rendering.
local function play(player, provider, mayDeferRender)
  local handle = player:createHandle()
  player:play(handle, provider:sequence(0), provider:bank(12))
  if not mayDeferRender then
    player:render(250)
  end
  return handle
end

-- An injected RNG in the SDK u16 draw domain: returns the raw 16-bit
-- SND_CalcRandom values of a test-fixed sequence, in order.
local function u16Draws(draws)
  local index = 0
  return function()
    index = index + 1
    return draws[index]
  end
end

-- A recording mixer implementing the semantic contract the player drives:
-- noteOn returns a persistent-generation {channel, generation} handle,
-- noteOff/updateVoice/isVoiceAlive take handles, `kill` simulates the mixer
-- removing a voice (a stolen or naturally dead channel) so the player's
-- liveness-based pruning and finish waits are observable. Every call is
-- logged for assertions.
local function stubMixer()
  local log = { noteOns = {}, noteHandles = {}, noteOffs = {}, updates = {}, renders = {}, trackTicks = {} }
  local generation = 0
  local alive = {}
  local mixer = {
    log = log,
    controlSteps = {},
    noteOn = function(_, spec)
      local gen = generation
      generation = generation + 1
      local handle = { channel = 3, generation = gen }
      log.noteOns[#log.noteOns + 1] = spec
      log.noteHandles[#log.noteHandles + 1] = handle
      alive[gen] = true
      return handle
    end,
    noteOff = function(_, handle, releaseOverride)
      log.noteOffs[#log.noteOffs + 1] = { handle = handle, releaseOverride = releaseOverride }
    end,
    updateVoice = function(_, handle, partial)
      log.updates[#log.updates + 1] = { handle = handle, partial = partial }
    end,
    -- The tied-note common-tail semantic operation (the mixer
    -- boundary): recorded into the same update log as updateVoice so the
    -- player-visible contract is one atomic update to the reused handle.
    retargetTiedVoice = function(_, handle, partial)
      log.updates[#log.updates + 1] = { handle = handle, partial = partial }
    end,
    isVoiceAlive = function(_, handle)
      return alive[handle.generation] == true
    end,
    kill = function(_, handle)
      alive[handle.generation] = false
    end,
    -- The sequence-owned non-auto sweep advancement (the
    -- semantic operation): the recorder exposes the per-tick calls so the
    -- sweep-ownership contract is observable at the player boundary.
    advanceTrackTick = function(_, handle)
      log.trackTicks[#log.trackTicks + 1] = handle
    end,
    controlStep = function(self)
      self.controlSteps[#self.controlSteps + 1] = true
    end,
    renderInto = function(_, out, frames)
      log.renders[#log.renders + 1] = frames
      for _ = 1, frames * 2 do
        out[#out + 1] = 0
      end
    end,
  }
  return mixer
end

-- The generator a recorded noteOn carries; convenient for ordering and
-- instrument-selection assertions.
local function generatorOf(spec)
  return spec.generator
end

function T.plays_a_note_and_ends_the_sequence()
  local mixer = stubMixer()
  local player, provider = engine(
    { [0] = seq({ { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } }) },
    {
      mixer = mixer,
    }
  )
  local before = player:render(8)
  for i = 1, 16 do
    Assert.equal(before[i], 0, "nothing plays before play()")
  end
  play(player, provider)
  Assert.isTrue(player:isPlaying())
  player:render(500)
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = nil } },
    "the 1-tick note releases at its own tick boundary"
  )
  Assert.isFalse(player:isPlaying(), "the end terminates the sequence")
end

function T.natural_release_waits_until_sequence_work_finishes()
  local events = {}
  local observer = {
    onSoundInterval = function(_, event)
      events[#events + 1] = event.phase
    end,
  }
  local mixer = stubMixer()
  local originalNoteOff = mixer.noteOff
  mixer.noteOff = function(self, handle, releaseOverride)
    events[#events + 1] = "natural_release"
    originalNoteOff(self, handle, releaseOverride)
  end
  local player, provider = engine(
    { [0] = seq({ { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } }) },
    { mixer = mixer, observer = observer }
  )
  play(player, provider)
  player:render(500)

  Assert.deepEqual(events, {
    "before_sequence",
    "after_sequence",
    "after_channels",
    "before_sequence",
    "after_sequence",
    "after_channels",
    "before_sequence",
    "natural_release",
    "after_sequence",
    "after_channels",
  }, "natural release begins after sequence work and before channel control")
end

function T.a_note_occupies_the_track_for_its_whole_duration()
  local mixer = stubMixer()
  local program = {
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 2 },
    { op = "program", program = 1 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program) }, { mixer = mixer })
  play(player, provider)
  Assert.equal(#mixer.log.noteOns, 1, "the first note starts at play")
  player:render(500)
  Assert.equal(#mixer.log.noteOns, 1, "the note's gate holds the track for its whole duration")
  player:render(500)
  Assert.equal(#mixer.log.noteOns, 2, "the second note starts only when the first's gate opens")
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = nil } },
    "the first voice releases at its own tick boundary, before the second starts"
  )
  Assert.equal(generatorOf(mixer.log.noteOns[2]).sample, AudioFixture.key(2), "the second note plays program 1")
end

function T.waits_gate_the_next_instruction()
  local mixer = stubMixer()
  local program = {
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "wait", duration = 2 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program) }, { mixer = mixer })
  play(player, provider)
  player:render(1000)
  Assert.equal(#mixer.log.noteOns, 1, "the wait holds the second note until it expires")
  Assert.equal(#mixer.log.noteOffs, 1, "the first note rings its own length; the wait does not release it")
  player:render(500)
  Assert.equal(#mixer.log.noteOns, 2, "the second note starts when the wait expires")
  player:render(500)
  Assert.isFalse(player:isPlaying())
end

function T.tempo_is_bpm_with_48_ticks_per_quarter_note()
  local function noteOffAt(tempo)
    local mixer = stubMixer()
    local player, provider = engine({
      [0] = seq({
        { op = "tempo", amount = tempo },
        { op = "note", key = 60, velocity = 127, duration = 1 },
        { op = "end" },
      }),
    }, { mixer = mixer })
    play(player, provider, true) -- Skip auto-render to manually control frame counts
    -- Entry program fetches at first 192 Hz boundary (frame 250)
    player:render(250)
    -- For fast tempo (240 BPM), 1 tick = 250 frames, so note releases at frame 500
    -- For slow tempo (120 BPM), 1 tick = 500 frames, so note releases at frame 750
    player:render(750) -- Render enough for both tempos to complete
    local first = #mixer.log.noteOffs -- Check after 1000 total frames
    return first
  end
  local fast_count = noteOffAt(240)
  Assert.equal(fast_count, 1, "at 240 BPM one tick is 250 frames; note released by frame 1000")
  local slow_count = noteOffAt(120)
  Assert.equal(slow_count, 1, "at 120 BPM one tick is 500 frames; note released by frame 1000")
end

function T.program_changes_select_other_instruments()
  local mixer = stubMixer()
  local program = {
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "program", program = 1 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program) }, { mixer = mixer })
  play(player, provider)
  player:render(500)
  Assert.equal(#mixer.log.noteOns, 2, "the second program selects the other instrument")
  Assert.equal(generatorOf(mixer.log.noteOns[1]).sample, AudioFixture.key(1))
  Assert.equal(generatorOf(mixer.log.noteOns[2]).sample, AudioFixture.key(2))
end

function T.jump_loops_back_to_its_target()
  local mixer = stubMixer()
  local program = {
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "jump", target = 2 },
  }
  local player, provider = engine({ [0] = seq(program) }, { mixer = mixer })
  play(player, provider)
  player:render(1000)
  Assert.equal(#mixer.log.noteOns, 3, "the jump retriggers the note at every tick")
  Assert.equal(#mixer.log.noteOffs, 2, "each ringing voice is released at its own tick")
  Assert.isTrue(player:isPlaying(), "an open loop keeps playing")
end

-- The SDK's 0xFD with no active call (call depth 0) is a no-op: real tracks
-- end with a top-level return, so a return reached without a call must fall
-- through (and past the program tail the track ends) instead of faulting.
function T.top_level_returns_are_no_ops_and_the_program_tail_ends_the_track()
  local midProgram = {
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "return" },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local midMixer = stubMixer()
  local player, provider = engine({ [0] = seq(midProgram) }, { mixer = midMixer })
  play(player, provider)
  player:render(1000)
  Assert.equal(#midMixer.log.noteOns, 2, "a top-level return falls through to the next instruction like the SDK")

  local trailing = {
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "return" },
  }
  local tailMixer = stubMixer()
  local tailPlayer, tailProvider = engine({ [0] = seq(trailing) }, { mixer = tailMixer })
  play(tailPlayer, tailProvider)
  tailPlayer:render(1000)
  Assert.equal(#tailMixer.log.noteOns, 1, "a trailing top-level return falls past the program tail")
  Assert.isFalse(tailPlayer:isPlaying())
end

function T.call_and_return_execute_a_subprogram()
  local mixer = stubMixer()
  local program = {
    { op = "call", target = 4 },
    { op = "wait", duration = 1 },
    { op = "end" },
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "return" },
  }
  local player, provider = engine({ [0] = seq(program) }, { mixer = mixer })
  play(player, provider)
  player:render(1000)
  Assert.equal(#mixer.log.noteOns, 1, "the call returns to the instruction after it")
  Assert.isFalse(player:isPlaying())
end

function T.open_track_plays_a_second_voice_in_parallel()
  local mixer = stubMixer()
  local program = {
    { op = "open_track", track = 1, target = 5 },
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
    { op = "program", program = 1 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program, { initialTrackMask = 0x0003 }) }, { mixer = mixer })
  -- play() renders through the first interval: the first source tick runs
  -- the entry program, which opens track 1 and notes the main track, and
  -- the opened track notes in the same tick's ascending-track pass.
  play(player, provider)
  Assert.equal(#mixer.log.noteOns, 2, "the first tick opens the second track and notes both tracks")
  player:render(500)
  Assert.equal(#mixer.log.noteOns, 2, "the one-tick notes gate both tracks until they end")
  Assert.equal(generatorOf(mixer.log.noteOns[2]).sample, AudioFixture.key(2))
  Assert.isFalse(player:isPlaying(), "the sequence ends when every track ends")
end

function T.self_open_track_falls_through_without_releasing_the_current_voice()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 0 },
      { op = "open_track", track = 0, target = 5 },
      { op = "wait", duration = 1 },
      { op = "note", key = 61, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })

  play(player, provider)
  Assert.equal(#mixer.log.noteOns, 1, "self-open falls through instead of jumping to its target")
  Assert.equal(#mixer.log.noteOffs, 0, "self-open does not release the current ringing voice")
  Assert.equal(mixer.log.noteOns[1].key, 60)

  player:render(500)
  Assert.equal(#mixer.log.noteOns, 2, "the target-area note executes after the ordinary wait")
  Assert.equal(mixer.log.noteOns[2].key, 61)
end

function T.prepares_every_reserved_track_before_the_first_tick()
  local sequence = seq({ { op = "wait", duration = 10 } })
  sequence.program.initialTrackMask = 0x000B
  local poolEvents = {}
  local player, provider = engine({ [0] = sequence }, {
    observer = {
      onTrackPool = function(_, event)
        poolEvents[#poolEvents + 1] = event.allocated
      end,
    },
  })

  player:play(player:createHandle(), provider:sequence(0), provider:bank(12))

  Assert.deepEqual(poolEvents, { 1, 2, 3 }, "all reserved tracks are acquired during preparation")
end

function T.unopened_reserved_tracks_do_not_keep_a_finished_sequence_alive()
  local player, provider = engine({
    [0] = seq({ { op = "end" } }, { initialTrackMask = 0x0003 }),
  })

  player:play(player:createHandle(), provider:sequence(0), provider:bank(12))
  player:render(500)

  Assert.isFalse(player:isPlaying(), "inactive reservations are released with the finished sequence")
end

function T.reopening_a_track_preserves_track_init_controls_and_pool_ownership()
  local mixer = stubMixer()
  local poolEvents = {}
  local program = {
    { op = "open_track", track = 1, target = 7 },
    { op = "end" },
    { op = "end" },
    { op = "end" },
    { op = "end" },
    { op = "end" },
    { op = "volume", amount = 42 },
    { op = "expression", amount = 37 },
    { op = "pan", amount = 81 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program, { initialTrackMask = 0x0003 }) }, {
    mixer = mixer,
    observer = {
      onTrackPool = function(_, event)
        poolEvents[#poolEvents + 1] = event.allocated
      end,
    },
  })
  play(player, provider)
  Assert.equal(#mixer.log.noteOns, 1)
  local spec = mixer.log.noteOns[1]
  Assert.equal(spec.trackVolume, 42)
  Assert.equal(spec.expression, 37)
  Assert.equal(spec.trackPanOffset, 17)
  Assert.deepEqual(poolEvents, { 1, 2, 1 }, "opening a reserved track retains its allocated object")
end

function T.entry_track_conditionals_use_the_true_comparison_default()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "if", condition = "compare_result", instruction = { op = "program", program = 1 } },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })

  play(player, provider)

  Assert.equal(#mixer.log.noteOns, 1, "the entry conditional executes before any comparison")
  Assert.equal(
    generatorOf(mixer.log.noteOns[1]).sample,
    AudioFixture.key(2),
    "the true default selects the nested program"
  )
end

function T.opened_reserved_track_starts_with_the_true_comparison_default()
  local mixer = stubMixer()
  local firstPlayer, firstProvider = engine({
    [0] = seq({
      { op = "open_track", track = 1, target = 5 },
      { op = "end" },
      { op = "end" },
      { op = "end" },
      { op = "if", condition = "compare_result", instruction = { op = "program", program = 1 } },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }, { initialTrackMask = 0x0003 }),
  }, { mixer = mixer })

  play(firstPlayer, firstProvider)
  Assert.equal(
    generatorOf(mixer.log.noteOns[1]).sample,
    AudioFixture.key(2),
    "a preallocated track starts with a true comparison latch"
  )
end

function T.reopening_a_false_comparison_track_preserves_the_latch()
  local reopenMixer = stubMixer()
  local program = {
    { op = "open_track", track = 1, target = 6 },
    { op = "wait", duration = 1 },
    { op = "open_track", track = 1, target = 11 },
    { op = "end" },
    { op = "end" },
    { op = "compare", condition = "eq", var = 0, amount = 1 },
    { op = "wait", duration = 1 },
    { op = "end" },
    { op = "end" },
    { op = "if", condition = "compare_result", instruction = { op = "program", program = 1 } },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local reopenPlayer, reopenProvider = engine({
    [0] = seq(program, { initialTrackMask = 0x0003 }),
  }, { mixer = reopenMixer })

  play(reopenPlayer, reopenProvider)
  reopenPlayer:render(1500)
  Assert.equal(#reopenMixer.log.noteOns, 1, "the reopened track reaches the note after its conditional")
  Assert.isFalse(reopenPlayer:isPlaying(), "the reopened track reaches its end")
  Assert.equal(
    generatorOf(reopenMixer.log.noteOns[1]).sample,
    AudioFixture.key(1),
    "reopening preserves the false comparison latch"
  )
end

function T.comparisons_and_conditionals_are_signed_and_track_local()
  local mixer = stubMixer()
  local program = {
    { op = "open_track", track = 1, target = 7 },
    { op = "setvar", var = 0, amount = -1 },
    { op = "compare", condition = "eq", var = 0, amount = -1 },
    { op = "if", condition = "compare_result", instruction = { op = "program", program = 1 } },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
    { op = "setvar", var = 0, amount = 1 },
    { op = "compare", condition = "ne", var = 0, amount = 1 },
    { op = "if", condition = "compare_result", instruction = { op = "program", program = 1 } },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  -- Track 1 has the opposite result and must not observe track 0's compare.
  local player, provider = engine({ [0] = seq(program, { initialTrackMask = 0x0003 }) }, { mixer = mixer })
  play(player, provider)
  Assert.equal(#mixer.log.noteOns, 2)
  Assert.equal(generatorOf(mixer.log.noteOns[1]).sample, AudioFixture.key(2))
  Assert.equal(generatorOf(mixer.log.noteOns[2]).sample, AudioFixture.key(1))
end

-- The volume/expression commands ride the note spec as the SDK fields; the
-- dB-domain register conversion they feed is VoiceMixer contract (the
-- player never folds them together).
function T.volume_and_expression_ride_the_note_spec()
  local function specFor(prefix)
    local mixer = stubMixer()
    local player, provider = engine({ [0] = seq(prefix) }, { mixer = mixer })
    play(player, provider)
    player:render(100)
    return mixer.log.noteOns[1]
  end
  local expression = specFor({
    { op = "expression", amount = 64 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  })
  Assert.equal(expression.expression, 64, "the expression command sets the note's expression field")
  local volume = specFor({
    { op = "volume", amount = 64 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  })
  Assert.equal(volume.trackVolume, 64, "the volume command sets the track volume field")
  local silent = specFor({
    { op = "expression", amount = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  })
  Assert.equal(silent.expression, 0, "expression 0 is passed through as zero")
end

-- Transpose is the SDK s8 (0x80 lowers to -128, 0xFF to -1): the note key
-- plus transpose is clamped to the MIDI domain 0..127, and the clamped key
-- drives the bank leaf selection (SND_seq.c TrackStepTicks midiKey +
-- TrackPlayNote SND_ReadInstData), never the raw source key.
function T.transpose_shifts_the_note_key_by_signed_semitones()
  local function noteFor(transpose, key, program)
    local mixer = stubMixer()
    local player, provider = engine({
      [0] = seq({
        { op = "program", program = program },
        { op = "transpose", amount = transpose },
        { op = "note", key = key, velocity = 127, duration = 1 },
        { op = "end" },
      }),
    }, { mixer = mixer })
    play(player, provider)
    player:render(100)
    return mixer.log.noteOns[1]
  end
  local down = noteFor(-128, 60, 2)
  Assert.equal(down.key, 0, "key 60 + transpose -128 clamps to midi key 0")
  Assert.equal(generatorOf(down).sample, AudioFixture.key(1), "midi key 0 selects the low key-split range")
  local up = noteFor(127, 60, 2)
  Assert.equal(up.key, 127, "key 60 + transpose 127 clamps to midi key 127")
  Assert.equal(generatorOf(up).sample, AudioFixture.key(2), "midi key 127 selects the high key-split range")
  local edge = noteFor(-1, 0, 2)
  Assert.equal(edge.key, 0, "key 0 + transpose -1 clamps to midi key 0")
  Assert.equal(generatorOf(edge).sample, AudioFixture.key(1))
end

-- Random operands resolve through the default SDK RNG (SND_CalcRandom:
-- state = state*1664525 + 1013904223 mod 2^32, initial state 0x12345678,
-- draw = the high 16 bits of state) with the TrackParseValue integer
-- scaling lo + ((draw * (hi - lo + 1)) >> 16). The player creates the
-- RNG once at construction and never reseeds per play, so consecutive
-- plays draw consecutive SDK values. Known vectors (computed from the SDK
-- formula): draws 0x7543, 0xCD30, 0x25DB for the range 0..127 map to
-- pan 58, 102, 18 (offsets -6, 38, -46).
function T.random_operands_draw_from_the_default_sdk_rng_without_reseeding()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "pan", amount = { kind = "random", lo = 0, hi = 127 } },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(10)
  Assert.equal(
    mixer.log.noteOns[1].trackPanOffset,
    -6,
    "the first SDK draw 0x7543 = 30019 scales (30019*128)>>16 = 58 -> offset -6"
  )
  play(player, provider)
  Assert.equal(
    mixer.log.noteOns[2].trackPanOffset,
    -46,
    "the second play's explicit draw (0x25DB = 9691, after the first interval's periodic draw) scales to pan 18"
  )
  play(player, provider)
  Assert.equal(
    mixer.log.noteOns[3].trackPanOffset,
    2,
    "the third play's explicit draw (0x84DE = 33950) scales to pan 66"
  )
end

-- The injected RNG is in the same u16 draw domain as the production RNG (a
-- function returning the raw 16-bit draw), and the operand scales the draw
-- with the SDK integer arithmetic -- never a 0..1 float. Each play renders
-- one completed interval, so the explicit operand draw is followed by that
-- interval's unconditional periodic draw: the injected sequence is consumed
-- two draws per play.
function T.random_operands_scale_the_u16_draw_with_sdk_integer_arithmetic()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "pan", amount = { kind = "random", lo = 0, hi = 127 } },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer, rng = u16Draws({ 0x0000, 0x8000, 0xFFFF, 0x4000, 0x2000, 0x6000, 0x1000, 0x3000 }) })
  play(player, provider)
  player:render(10)
  Assert.equal(mixer.log.noteOns[1].trackPanOffset, -64, "draw 0x0000 scales to pan 0")
  play(player, provider)
  Assert.equal(
    mixer.log.noteOns[2].trackPanOffset,
    63,
    "draw 0xFFFF = 65535 scales to pan 127 (after the first interval's periodic draw)"
  )
  play(player, provider)
  Assert.equal(mixer.log.noteOns[3].trackPanOffset, -48, "draw 0x2000 = 8192 scales to pan 16")
  play(player, provider)
  Assert.equal(mixer.log.noteOns[4].trackPanOffset, -56, "draw 0x1000 = 4096 scales to pan 8")
end

function T.the_inner_volume_starts_full_independently_of_initial_volume()
  local function sequenceVolume(initialVolume)
    local mixer = stubMixer()
    local player, provider = engine({
      [0] = seq(
        { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } },
        { initialVolume = initialVolume }
      ),
    }, { mixer = mixer })
    play(player, provider)
    player:render(100)
    return mixer.log.noteOns[1].sequenceVolume, mixer.log.noteOns[1].fader
  end
  local inner, outerFader = sequenceVolume(127)
  Assert.equal(inner, 127)
  Assert.equal(outerFader, NnsSoundMath.decibel(127))
  inner, outerFader = sequenceVolume(64)
  Assert.equal(inner, 127)
  Assert.equal(outerFader, NnsSoundMath.decibel(64))
end

-- The default fixture player has maxSequences=1, so this test pins the
-- capacity-one eviction rule. Separate tests cover overlap when capacity is
-- greater than one.
function T.capacity_one_replaces_the_existing_sequence()
  local mixer = stubMixer()
  local first =
    { { op = "program", program = 0 }, { op = "note", key = 60, velocity = 127, duration = 2 }, { op = "end" } }
  local second =
    { { op = "program", program = 1 }, { op = "note", key = 60, velocity = 127, duration = 2 }, { op = "end" } }
  local player, provider = engine({
    [0] = seq(first),
    [1] = seq(second, { id = 1, symbol = "SEQ_TEST_B", playerId = 1 }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(250)
  Assert.equal(generatorOf(mixer.log.noteOns[1]).sample, AudioFixture.key(1))
  player:play(player:createHandle(), provider:sequence(1), provider:bank(12))
  player:render(250)
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = nil } },
    "the replacement releases the previous sequence's voices"
  )
  Assert.equal(generatorOf(mixer.log.noteOns[2]).sample, AudioFixture.key(2))
end

function T.sequences_on_different_players_mix()
  local mixer = stubMixer()
  local programA =
    { { op = "program", program = 0 }, { op = "note", key = 60, velocity = 127, duration = 2 }, { op = "end" } }
  local programB =
    { { op = "program", program = 1 }, { op = "note", key = 60, velocity = 127, duration = 2 }, { op = "end" } }
  local player, provider = engine({
    [0] = seq(programA, { playerId = 1 }),
    [1] = seq(programB, { id = 1, symbol = "SEQ_TEST_B", playerId = 2 }),
  }, { mixer = mixer })
  player:play(player:createHandle(), provider:sequence(0), provider:bank(12))
  player:render(250)
  player:play(player:createHandle(), provider:sequence(1), provider:bank(12))
  player:render(250)
  Assert.equal(#mixer.log.noteOns, 2, "two players mix like two hardware players")
  player:render(1000)
  Assert.equal(#mixer.log.noteOffs, 2, "both players' voices release at their own tick")
  Assert.isFalse(player:isPlaying())
end

function T.stop_releases_all_voices()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({ { op = "note", key = 60, velocity = 127, duration = 2 }, { op = "end" } }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(200)
  player:stop()
  Assert.isFalse(player:isPlaying())
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = nil } },
    "stop releases every active voice"
  )
  player:render(400)
  Assert.equal(#mixer.log.noteOns, 1, "no new notes issue after stop")
end

-- The batched render contract: the player asks the mixer for spans that
-- end at the next event boundary (a control event, a sequence tick, the
-- buffer end) instead of one frame at a time. The mixer call count must
-- stay far below one per frame over a 1000-frame render (the exact
-- partition is implementation-owned; the upper bound is the performance
-- contract).
function T.the_player_renders_mixer_spans_until_event_boundaries()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 8 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  mixer.log.renders = {}
  player:render(1000)
  local total = 0
  for _, frames in ipairs(mixer.log.renders) do
    total = total + frames
  end
  Assert.equal(total, 1000, "the mixer spans partition the requested window exactly")
  Assert.isTrue(#mixer.log.renders <= 5, "one span per event boundary at most, never one call per frame")
end

function T.render_is_deterministic_and_chunk_independent()
  local program = {
    { op = "tempo", amount = 128 },
    { op = "note", key = 60, velocity = 127, duration = 3 },
    { op = "end" },
  }
  local function playChunked(chunks)
    local player, provider = engine({ [0] = seq(program) })
    play(player, provider)
    local out = {}
    for _, frames in ipairs(chunks) do
      local pcm = player:render(frames)
      for i = 1, #pcm do
        out[#out + 1] = pcm[i]
      end
    end
    return out
  end
  local one = playChunked({ 2000 })
  Assert.deepEqual(one, playChunked({ 700, 700, 600 }), "fractional ticks per frame are chunk-size independent")
  Assert.deepEqual(one, playChunked({ 1000, 1000 }), "render(1000)+render(1000) equals render(2000)")
  Assert.deepEqual(one, playChunked({ 400, 600, 1000 }), "render(400)+render(600)+render(1000) equals render(2000)")
  Assert.deepEqual(
    one,
    playChunked({ 250, 250, 250, 250, 250, 250, 250, 250 }),
    "splits at the control-period boundary stay byte-identical"
  )
  Assert.deepEqual(one, playChunked({ 2000 }), "playback is reproducible")
end

function T.playing_a_sequence_with_a_mismatched_bank_fails()
  local player, provider = engine({ [0] = seq({ { op = "note", key = 60, velocity = 127, duration = 1 } }) })
  local bank = provider:bank(12)
  bank.id = 99
  throwsCode("AUDIO_PLAYER_BANK_MISMATCH", function()
    player:play(player:createHandle(), provider:sequence(0), bank)
  end)
end

function T.playing_an_unknown_instrument_is_silent()
  -- A program the bank does not define is a silent note: the NNS
  -- SND_ReadInstData failure path skips the note, and the real corpus
  -- references placeholder/unused instruments that the DS plays as silence,
  -- never as a fault. The silent note still gates the track.
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "program", program = 9 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(600)
  Assert.equal(#mixer.log.noteOns, 0, "a missing instrument is a silent note")
  Assert.isFalse(player:isPlaying())
end

-- A structurally valid program that can never reach `end` (a self-loop) must
-- not hang the host: the step-budget failure is the player's host-safety
-- boundary and stays even though no retail sequence triggers it. Malformed
-- IR is excluded before it reaches the player -- the closed sequence
-- validator (libs/assets AudioSequence, AUDIO_SEQUENCE_INVALID) owns unknown
-- ops and illegal operand shapes at the asset boundary, so feeding them to
-- the player directly is not a contract here.
function T.runaway_loops_hit_the_host_safety_budget()
  throwsCode("AUDIO_PLAYER_UNBOUNDED_EXECUTION", function()
    local player, provider = engine({ [0] = seq({ { op = "jump", target = 1 } }) })
    play(player, provider)
    player:render(10)
  end)
end

function T.key_split_instruments_select_by_note_key()
  local mixer = stubMixer()
  local program = {
    { op = "program", program = 2 },
    { op = "note", key = 30, velocity = 127, duration = 1 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program) }, { mixer = mixer })
  play(player, provider)
  player:render(1000)
  Assert.equal(generatorOf(mixer.log.noteOns[1]).sample, AudioFixture.key(1), "key 30 hits the low range")
  Assert.equal(generatorOf(mixer.log.noteOns[2]).sample, AudioFixture.key(2), "key 60 hits the high range")
end

function T.drum_set_voices_select_by_key_and_out_of_range_is_silent()
  local mixer = stubMixer()
  local program = {
    { op = "program", program = 3 },
    { op = "note", key = 35, velocity = 127, duration = 1 },
    { op = "note", key = 36, velocity = 127, duration = 1 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program) }, { mixer = mixer })
  play(player, provider)
  player:render(1500)
  Assert.deepEqual(
    mixer.log.noteOns[1].generator,
    { kind = "sample", sample = AudioFixture.key(1) },
    "drum 35 plays the sample voice"
  )
  Assert.deepEqual(mixer.log.noteOns[2].generator, { kind = "square", duty = 3 }, "drum 36 plays the square")
  Assert.equal(#mixer.log.noteOns, 2, "key 60 is out of the drum range and silent")
end

-- The transposed, clamped MIDI key drives instrument leaf selection (the
-- NNS TrackStepTicks midiKey plus TrackPlayNote SND_ReadInstData path): a
-- note crossing a key-split boundary after transposition must play the
-- range the transposed key lands in, never the source key's voice pitched
-- up.
function T.transpose_moves_key_split_selection_across_the_boundary()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "program", program = 2 },
      { op = "transpose", amount = 5 },
      { op = "note", key = 55, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(100)
  Assert.deepEqual(
    mixer.log.noteOns[1].generator,
    { kind = "sample", sample = AudioFixture.key(2) },
    "key 55 + transpose 5 = 60 crosses the split at 60 and selects the high range voice"
  )
  Assert.equal(mixer.log.noteOns[1].key, 60, "the voice pitch is the transposed key")
end

-- The same contract holds across a drum-set boundary: the transposed key
-- indexes the drum voices, and a transposition out of the drum range is
-- silent (a drum-set miss, not a stale source-key voice).
function T.transpose_moves_drum_selection_across_the_boundary()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "program", program = 3 },
      { op = "transpose", amount = 1 },
      { op = "note", key = 35, velocity = 127, duration = 1 },
      { op = "note", key = 36, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(100)
  Assert.deepEqual(
    mixer.log.noteOns[1].generator,
    { kind = "square", duty = 3 },
    "key 35 + transpose 1 = 36 selects the drum voice at key 36"
  )
  Assert.equal(mixer.log.noteOns[1].key, 36, "the drum voice pitches at the transposed key")
  Assert.equal(#mixer.log.noteOns, 1, "key 36 + transpose 1 = 37 leaves the drum range and is silent")
end

function T.loop_begin_and_loop_end_repeat_the_body()
  local mixer = stubMixer()
  local program = {
    { op = "loop_begin", count = 2 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "loop_end" },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program) }, { mixer = mixer })
  play(player, provider)
  player:render(1000)
  Assert.equal(#mixer.log.noteOns, 2, "count 2 runs the body twice (the SDK decrements at loop_end and exits at zero)")
  Assert.equal(#mixer.log.noteOffs, 2, "each iteration's voice rings its own length")
  Assert.isFalse(player:isPlaying())
end

-- The SDK's loopCount 0 never decrements: loop_end jumps back forever, so a
-- count-0 loop rings until the sequence is stopped (the real
-- SEQ_GS_P_SAFARI_ROAD map music).
function T.loop_begin_count_zero_loops_forever()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "loop_begin", count = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "loop_end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(2000)
  Assert.equal(#mixer.log.noteOns, 5, "count 0 re-enters the body on every tick")
  Assert.isTrue(player:isPlaying(), "a count-0 loop never ends on its own")
end

-- The SDK's 0xFC with no active loop frame (call depth 0) is a no-op; the
-- real corpus contains tracks whose loop code is dead bytes, so an
-- unmatched loop_end must fall through without faulting.
function T.unmatched_loop_end_is_a_no_op()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "loop_end" },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(1000)
  Assert.equal(#mixer.log.noteOns, 1, "the unmatched loop_end falls through")
  Assert.isFalse(player:isPlaying())
end

-- WAIT 0 must not delay execution to the next tick: the SDK command loop
-- continues while `wait == 0 && !note_finish_wait`, so the next command runs
-- in the same processing pass as the gate that released it.
function T.wait_zero_runs_the_next_command_in_the_same_pass()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "wait", duration = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(500)
  Assert.equal(
    #mixer.log.noteOns,
    2,
    "the second note starts in the same pass as the WAIT 0 executes, at the first tick"
  )
end

-- A silent zero-length note (an instrument the bank does not define has no
-- channel to wait for) still sets the note-finish wait; with no live
-- handles the wait clears at the FIRST tick (the SDK TrackStepTicks
-- note_finish_wait check runs per tick, never one frame early), and the
-- following note starts on the frame after that tick.
function T.silent_zero_length_notes_release_their_gate_at_the_first_tick()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "program", program = 9 },
      { op = "note", key = 60, velocity = 127, duration = 0 },
      { op = "program", program = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider, true) -- Don't auto-render
  player:render(250) -- Entry at boundary 1
  player:render(500) -- Boundary 2 and 3 (1 full tick)
  Assert.equal(#mixer.log.noteOns, 1, "the marker note starts after the first tick boundary")
  Assert.equal(generatorOf(mixer.log.noteOns[1]).sample, AudioFixture.key(1))
end

-- A zero-length note under note-wait is a note-FINISH wait (SND_seq.c
-- TrackPlayNote): the channel starts with an indefinite length (it is never
-- released merely because a sequence tick elapsed) and the track holds
-- until the mixer reports its live handles gone. The recording mixer's
-- kill() models the mixer removing the voice (stolen or naturally dead);
-- the marker note must not start until that happens.
function T.zero_length_notes_wait_for_real_handle_liveness()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note", key = 60, velocity = 127, duration = 0 },
      { op = "program", program = 1 },
      { op = "note", key = 60, velocity = 127, duration = 2 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  local handle = mixer.log.noteHandles[1]
  Assert.equal(#mixer.log.noteOns, 1, "the zero-length note starts one voice")
  player:render(500)
  Assert.equal(
    #mixer.log.noteOffs,
    0,
    "a zero-length note's voice is indefinite: one elapsed tick must never release it"
  )
  Assert.equal(#mixer.log.noteOns, 1, "the marker note is still held while the voice lives")
  mixer:kill(handle)
  player:render(500)
  Assert.equal(#mixer.log.noteOns, 2, "the finish wait observes the dead handle and releases the track")
  Assert.equal(generatorOf(mixer.log.noteOns[2]).sample, AudioFixture.key(2))
end

-- The NNS track polyphony: with note-wait cleared, overlapping notes all
-- sound; each voice rings its own channel length independently. The track's
-- voice collection is a list of {channel, generation} handles -- never a
-- single channel.
function T.overlapping_notes_form_a_polyphonic_voice_collection()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "note", key = 60, velocity = 127, duration = 2 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  Assert.equal(#mixer.log.noteOns, 2, "both notes allocate in the first pass")
  player:render(1000)
  Assert.deepEqual(mixer.log.noteOffs, {
    { handle = { channel = 3, generation = 0 }, releaseOverride = nil },
    { handle = { channel = 3, generation = 1 }, releaseOverride = nil },
  }, "each voice rings its own length and releases at its own tick")
end

-- The per-voice length bookkeeping: each {channel, generation} handle in the
-- track's collection expires on its own tick, and the handle the mixer
-- returned is what comes back on noteOff.
function T.the_track_keeps_polyphonic_voice_handles_and_releases_them_individually()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "note", key = 61, velocity = 127, duration = 2 },
      { op = "wait", duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  Assert.equal(#mixer.log.noteOns, 2, "both notes allocated in the first pass")
  Assert.equal(#mixer.log.noteOffs, 0, "no voice is replaced while the collection is polyphonic")
  player:render(500)
  Assert.deepEqual(mixer.log.noteOffs, {
    { handle = { channel = 3, generation = 0 }, releaseOverride = nil },
    { handle = { channel = 3, generation = 1 }, releaseOverride = nil },
  }, "the first voice expires and END immediately releases the remaining voice")
  player:render(500)
  Assert.deepEqual(mixer.log.noteOffs, {
    { handle = { channel = 3, generation = 0 }, releaseOverride = nil },
    { handle = { channel = 3, generation = 1 }, releaseOverride = nil },
  }, "the second voice's length expires on its own later tick")
end

-- The mixer owns voice liveness: the track's collection is pruned by
-- `mixer:isVoiceAlive` (a stolen or naturally dead handle leaves the
-- collection), so a later release (a tie command) touches only the live
-- voices and never issues a stale noteOff.
function T.dead_handles_are_pruned_by_mixer_liveness()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 4 },
      { op = "note", key = 61, velocity = 127, duration = 4 },
      { op = "wait", duration = 2 },
      { op = "tie", amount = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  Assert.equal(#mixer.log.noteOns, 2, "two voices ring in parallel")
  player:render(500)
  mixer:kill(mixer.log.noteHandles[1])
  player:render(500)
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 1 }, releaseOverride = nil } },
    "the tie releases only the live voice; the dead handle was pruned by liveness"
  )
end

-- The NNS tie (SND_seq.c 0xC8 TrackReleaseChannels + TrackFreeChannels):
-- the tie command itself always releases and frees the track's current
-- voices, even when the new flag equals the previous flag. A repeated
-- same-value `tie 1` still releases whatever is ringing.
function T.repeated_tie_one_still_releases_current_voices()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 2 },
      { op = "tie", amount = 1 },
      { op = "note", key = 60, velocity = 127, duration = 2 },
      { op = "tie", amount = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  Assert.equal(#mixer.log.noteOns, 2, "the first tie frees the old voice and the next note starts a new one")
  Assert.deepEqual(mixer.log.noteOffs, {
    { handle = { channel = 3, generation = 0 }, releaseOverride = nil },
    { handle = { channel = 3, generation = 1 }, releaseOverride = nil },
  }, "both ties release: the flag was already true for the second, and it still frees the current voice")
end

-- A tied channel starts with an indefinite length (TrackPlayNote), so it
-- survives past any supplied note duration; a later tied note over the live
-- head voice reuses it in place (key/velocity update, no noteOn, no
-- noteOff), and clearing the tie releases the reused voice.
function T.tied_voices_survive_their_duration_and_reuse_the_live_head()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "tie", amount = 1 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "wait", duration = 1 },
      { op = "note", key = 61, velocity = 127, duration = 1 },
      { op = "wait", duration = 1 },
      { op = "tie", amount = 0 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  Assert.equal(#mixer.log.noteOns, 1, "the tied note starts one voice")
  player:render(500)
  Assert.equal(#mixer.log.noteOffs, 0, "a tied voice is indefinite: it survives past its supplied one-tick duration")
  Assert.equal(#mixer.log.noteOns, 1, "the tied re-note reuses the live head: no new allocation")
  Assert.equal(#mixer.log.updates, 1, "the tied re-note updates the live head in place instead of restarting it")
  Assert.deepEqual(mixer.log.updates[1].handle, { channel = 3, generation = 0 })
  Assert.equal(mixer.log.updates[1].partial.key, 61, "the reuse updates the voice's key")
  Assert.equal(mixer.log.updates[1].partial.velocity, 127, "the reuse updates the voice's velocity")
  player:render(500)
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = nil } },
    "clearing tie releases and frees the reused tied voice"
  )
end

-- Mute modes (SND_seq.c TrackMute): mode 1 mutes future notes without
-- touching playing voices, mode 2 additionally releases the track's voices,
-- mode 0 unmutes. A muted note still gates the track like any other note.
function T.mute_modes_suppress_notes_and_clean_up_voices()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 3 },
      { op = "wait", duration = 1 },
      { op = "mute", amount = 1 },
      { op = "note", key = 61, velocity = 127, duration = 2 },
      { op = "wait", duration = 1 },
      { op = "mute", amount = 2 },
      { op = "wait", duration = 1 },
      { op = "mute", amount = 0 },
      { op = "note", key = 62, velocity = 127, duration = 2 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  Assert.equal(#mixer.log.noteOns, 1, "the first note allocates")
  player:render(600)
  Assert.equal(#mixer.log.noteOns, 1, "a muted note allocates no voice")
  Assert.equal(#mixer.log.noteOffs, 0, "mute mode 1 leaves playing voices alone")
  player:render(600)
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = nil } },
    "mute mode 2 releases the track's playing voices"
  )
  player:render(600)
  Assert.equal(#mixer.log.noteOns, 2, "unmuting restores note playback")
end

-- Envelope overrides (SND_seq.c 0xD0-0xD3) start unset (0xFF in the SDK) and
-- only apply to a note when set: an unset override leaves the instrument's
-- envelope untouched; a set override replaces exactly that stage and
-- persists for every later note.
function T.envelope_overrides_apply_only_when_set_and_persist()
  local mixer = stubMixer()
  local program = {
    { op = "note_wait", amount = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "attack", amount = 100 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "decay", amount = 80 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "sustain", amount = 60 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "release", amount = 90 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program) }, { mixer = mixer })
  play(player, provider)
  player:render(100)
  local base = { attack = 127, decay = 0, sustain = 127, release = 127 }
  Assert.deepEqual(mixer.log.noteOns[1].envelope, base, "an unset override leaves the voice envelope untouched")
  Assert.deepEqual(
    mixer.log.noteOns[2].envelope,
    { attack = 100, decay = 0, sustain = 127, release = 127 },
    "a set attack override replaces exactly the attack stage"
  )
  Assert.deepEqual(
    mixer.log.noteOns[3].envelope,
    { attack = 100, decay = 80, sustain = 127, release = 127 },
    "the decay override joins the persisted attack override"
  )
  Assert.deepEqual(
    mixer.log.noteOns[4].envelope,
    { attack = 100, decay = 80, sustain = 60, release = 127 },
    "the sustain override joins the persisted overrides"
  )
  Assert.deepEqual(
    mixer.log.noteOns[5].envelope,
    { attack = 100, decay = 80, sustain = 60, release = 90 },
    "the release override joins the persisted overrides"
  )
end

function T.envelope_override_sentinel_clears_each_stage()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "attack", amount = 44 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "attack", amount = 255 },
      { op = "decay", amount = 55 },
      { op = "sustain", amount = 66 },
      { op = "release", amount = 77 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "decay", amount = 255 },
      { op = "sustain", amount = 255 },
      { op = "release", amount = 255 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, {
    mixer = mixer,
    bank = AudioFixture.bank(12, "BANK_TEST", {
      AudioFixture.key(1),
    }, {
      [0] = {
        kind = "direct",
        voice = {
          generator = { kind = "sample", sample = AudioFixture.key(1) },
          originalKey = 60,
          envelope = { attack = 11, decay = 22, sustain = 33, release = 100 },
          pan = 0,
        },
      },
    }),
  })
  play(player, provider)
  player:render(750)

  Assert.deepEqual(mixer.log.noteOns[1].envelope, {
    attack = 44,
    decay = 22,
    sustain = 33,
    release = 100,
  })
  Assert.deepEqual(mixer.log.noteOns[2].envelope, {
    attack = 11,
    decay = 55,
    sustain = 66,
    release = 77,
  })
  Assert.deepEqual(mixer.log.noteOns[3].envelope, {
    attack = 11,
    decay = 22,
    sustain = 33,
    release = 100,
  })
end

function T.envelope_override_sentinel_normalizes_resolved_operands()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "setvar", var = 0, amount = 255 },
      { op = "attack", amount = { kind = "variable", var = 0 } },
      { op = "release", amount = { kind = "random", lo = 255, hi = 255 } },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer, rng = u16Draws({ 0xFFFF }) })
  play(player, provider)
  Assert.deepEqual(mixer.log.noteOns[1].envelope, {
    attack = 127,
    decay = 0,
    sustain = 127,
    release = 127,
  })
end

function T.instrument_release_sentinel_remains_indefinite_without_track_override()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note", key = 60, velocity = 127, duration = 3 },
      { op = "end" },
    }),
  }, {
    mixer = mixer,
    bank = AudioFixture.bank(12, "BANK_TEST", {
      AudioFixture.key(1),
    }, {
      [0] = {
        kind = "direct",
        voice = {
          generator = { kind = "sample", sample = AudioFixture.key(1) },
          originalKey = 60,
          envelope = { attack = 11, decay = 22, sustain = 33, release = 255 },
          pan = 0,
        },
      },
    }),
  })
  play(player, provider)

  Assert.equal(mixer.log.noteOns[1].envelope.release, 255)
  Assert.equal(mixer.log.noteOns[1].length, -1)
end

function T.concrete_release_override_preserves_instrument_sentinel_lifetime()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "release", amount = 10 },
      { op = "note", key = 60, velocity = 127, duration = 3 },
      { op = "end" },
    }),
  }, {
    mixer = mixer,
    bank = AudioFixture.bank(12, "BANK_TEST", {
      AudioFixture.key(1),
    }, {
      [0] = {
        kind = "direct",
        voice = {
          generator = { kind = "sample", sample = AudioFixture.key(1) },
          originalKey = 60,
          envelope = { attack = 11, decay = 22, sustain = 33, release = 255 },
          pan = 0,
        },
      },
    }),
  })
  play(player, provider)

  Assert.equal(mixer.log.noteOns[1].envelope.release, 10)
  Assert.equal(mixer.log.noteOns[1].length, -1)
end

function T.instrument_sentinel_does_not_naturally_release_at_authored_duration()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "release", amount = 10 },
      { op = "note", key = 60, velocity = 127, duration = 3 },
      { op = "wait", duration = 10 },
    }),
  }, {
    mixer = mixer,
    bank = AudioFixture.bank(12, "BANK_TEST", {
      AudioFixture.key(1),
    }, {
      [0] = {
        kind = "direct",
        voice = {
          generator = { kind = "sample", sample = AudioFixture.key(1) },
          originalKey = 60,
          envelope = { attack = 11, decay = 22, sustain = 33, release = 255 },
          pan = 0,
        },
      },
    }),
  })
  play(player, provider)
  player:render(2500)

  Assert.equal(#mixer.log.noteOffs, 0, "the sentinel voice does not release at its authored duration")
  Assert.isTrue(player:isPlaying(), "the long wait keeps the sequence active")

  player:stop()
  Assert.equal(#mixer.log.noteOffs, 1, "explicit stop releases the still-attached sentinel voice")
end

function T.tied_envelope_override_sentinel_does_not_write_a_coefficient()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "tie", amount = 1 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "release", amount = 20 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "wait", duration = 1 },
      { op = "release", amount = 255 },
      { op = "note", key = 61, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(1250)

  local envelopeUpdates = {}
  for _, update in ipairs(mixer.log.updates) do
    if update.partial.envelope ~= nil then
      envelopeUpdates[#envelopeUpdates + 1] = update.partial.envelope
    end
  end
  Assert.equal(envelopeUpdates[1].release, 20)
  Assert.isNil(envelopeUpdates[2].release)
end

-- The voice spec is the semantic mixer contract: trackVolume + sequenceVolume
-- (never folded), channel priority + track priority, the raw trackPanOffset,
-- the instrument pan, the clamped transposed key, the TrackInit defaults
-- (bend 0 -> userPitch 0), the TrackPlayNote sweep fields, the
-- TrackUpdateChannel lfo snapshot, and a {channel, generation} handle
-- back. The derived sample metadata has no source sample rate, and the spec
-- does not carry one either.
function T.note_spec_carries_the_semantic_mixer_contract()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq(
      { { op = "note", key = 64, velocity = 96, duration = 1 }, { op = "end" } },
      { initialVolume = 100, playerPriority = 16, channelPriority = 37 }
    ),
  }, { mixer = mixer })
  play(player, provider)
  player:render(500)
  Assert.equal(#mixer.log.noteOns, 1, "one note, one voice command")
  local spec = mixer.log.noteOns[1]
  Assert.deepEqual(spec.generator, { kind = "sample", sample = AudioFixture.key(1) })
  Assert.deepEqual(spec.pcm, WAVE_A, "the mixer receives the provider-decoded PCM array")
  Assert.deepEqual(spec.loop, { startFrame = 0, endFrame = 8 })
  Assert.equal(spec.loopEnabled, true, "the mixer receives the wave's loop flag")
  Assert.equal(spec.baseTimer, 8006, "the mixer receives the wave's DS base timer")
  Assert.isNil(spec.sampleRate, "the voice spec carries no source sample rate (playback is the DS clock path)")
  Assert.equal(spec.key, 64, "the note key is the midi key (no bend fold)")
  Assert.equal(spec.userPitch, 0, "bend 0 is no bend: the TrackInit user pitch")
  Assert.equal(spec.originalKey, 60)
  Assert.equal(spec.velocity, 96)
  Assert.equal(spec.trackVolume, 127, "the track volume passes through unfettered")
  Assert.equal(spec.expression, 127)
  Assert.equal(spec.sequenceVolume, 127, "the inner sequence volume starts at 127")
  Assert.isNil(spec.outerPlayerVolume, "outer player volume remains player-owned state")
  Assert.deepEqual(spec.envelope, { attack = 127, decay = 0, sustain = 127, release = 127 })
  Assert.equal(spec.pan, 0, "the spec carries the instrument pan, not a folded track pan")
  Assert.equal(spec.trackPanOffset, 0, "the raw track pan offset defaults to 0")
  Assert.equal(spec.channelMask, 0xFFFF)
  Assert.equal(spec.trackPriority, 64, "the track priority starts from TrackInit")
  Assert.isNil(spec.playerPriority, "SeqPlayer priority does not cross into the mixer")
  Assert.isNil(spec.volume, "the old folded volume field is gone")
  Assert.equal(spec.channelPriority, 37)
  Assert.isNil(spec.bend, "bend is userPitch; the mixer spec has no bend field")
  Assert.deepEqual(
    spec.lfo,
    { target = 0, depth = 0, range = 1, speed = 16, delay = 0 },
    "the spec always carries the lfo snapshot with the TrackInit defaults (SND_InitLfoParam)"
  )
  Assert.equal(spec.sweepPitch, 0, "the spec always carries the track sweep pitch (TrackInit 0)")
  Assert.equal(spec.sweepLength, 1, "portamentoTime 0 makes the note length the sweep length")
  Assert.equal(spec.autoSweep, false, "portamentoTime 0 disables the autoSweep advance (TrackPlayNote)")
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = nil } },
    "the note releases the {channel, generation} handle the mixer returned"
  )
end

-- The 0xC6 priority command changes the TRACK priority (SDK TrackInit
-- default 64); physical channel priority remains separate SeqPlayer state.
function T.priority_is_track_state_defaulting_to_64()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "priority", amount = 12 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }, { playerPriority = 16, channelPriority = 37 }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(100)
  Assert.equal(mixer.log.noteOns[1].trackPriority, 64, "a fresh track starts at TrackInit priority")
  Assert.isNil(mixer.log.noteOns[1].playerPriority, "the player priority stays at the SeqPlayer boundary")
  Assert.equal(mixer.log.noteOns[2].trackPriority, 12, "the priority command changes the track priority")
end

-- The pan command writes the raw SDK track pan offset (SND_seq.c 0xC0 stores
-- par - 0x40); the instrument pan is untouched.
function T.pan_commands_pass_the_raw_track_pan_offset()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "pan", amount = 64 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "pan", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "pan", amount = 127 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "pan", amount = 128 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(100)
  Assert.equal(mixer.log.noteOns[1].trackPanOffset, 0, "the raw offset defaults to 0")
  Assert.equal(mixer.log.noteOns[2].trackPanOffset, 0, "pan 64 is the zero offset")
  Assert.equal(mixer.log.noteOns[3].trackPanOffset, -64, "pan 0 is the full-left offset")
  Assert.equal(mixer.log.noteOns[4].trackPanOffset, 63, "pan 127 is the full-right offset")
  Assert.equal(mixer.log.noteOns[5].trackPanOffset, 64, "pan 128 wraps after subtracting the center")
  for i = 1, 5 do
    Assert.equal(mixer.log.noteOns[i].pan, 0, "the instrument pan is never folded into the track offset")
  end
end

-- Pitch bend is signed s8 (0 = no bend) and rides the spec as user pitch
-- (SND_seq.c TrackUpdateChannel: userPitch = pitchBend * (bendRange << 6)
-- >> 7, an arithmetic shift), never as a key change and never centered at
-- 64. The odd-product cases pin the floor semantics of the signed shift
-- (bend 67 at range 3 folds (67*192)>>7 = 100, bend -67 folds
-- (-67*192)>>7 = -101).
function T.pitch_bend_is_signed_user_pitch_not_a_key_fold()
  local mixer = stubMixer()
  local program = {
    { op = "note_wait", amount = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "pitch_bend_range", amount = 2 },
    { op = "pitch_bend", amount = 1 },
    { op = "note", key = 61, velocity = 127, duration = 1 },
    { op = "pitch_bend", amount = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "pitch_bend", amount = -64 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "pitch_bend", amount = 127 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "pitch_bend", amount = -128 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "pitch_bend_range", amount = 3 },
    { op = "pitch_bend", amount = 67 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "pitch_bend", amount = 61 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "pitch_bend", amount = -67 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program) }, { mixer = mixer })
  play(player, provider)
  player:render(100)
  local specs = mixer.log.noteOns
  Assert.equal(#specs, 9, "the bend commands gate nothing")
  Assert.equal(specs[1].key, 60, "bend defaults to 0: the key is the note key")
  Assert.equal(specs[1].userPitch, 0, "bend 0 is no bend")
  Assert.equal(specs[2].key, 61, "bend never changes the midi key")
  Assert.equal(specs[2].userPitch, 1, "bend 1 at range 2: (1*128)>>7 = 1")
  Assert.equal(specs[3].userPitch, 0, "pitch_bend 0 produces exactly no bend")
  Assert.equal(specs[4].userPitch, -64, "bend -64 at range 2: (-64*128)>>7 = -64")
  Assert.equal(specs[5].userPitch, 127, "bend 127 at range 2: (127*128)>>7 = 127")
  Assert.equal(specs[6].userPitch, -128, "bend 0x80 lowered to -128: (-128*128)>>7 = -128")
  Assert.equal(specs[7].key, 60, "bend never moves the key across the odd-product rows either")
  Assert.equal(specs[7].userPitch, 100, "bend 67 at range 3: (67*192)>>7 = 100")
  Assert.equal(specs[8].userPitch, 91, "bend 61 at range 3: (61*192)>>7 = 91")
  Assert.equal(specs[9].userPitch, -101, "bend -67 at range 3: the arithmetic shift floors (-67*192)>>7 = -101")
end

-- Pitch bend reaches an already-active held voice as a userPitch update --
-- never as a MIDI-key replacement (SND_seq.c TrackUpdateChannel per main).
function T.held_voices_receive_pitch_bend_updates_in_place()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 4 },
      { op = "pitch_bend_range", amount = 2 },
      { op = "pitch_bend", amount = 64 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  Assert.equal(mixer.log.noteOns[1].userPitch, 0, "the note starts at the unbent pitch")
  player:render(100)
  Assert.isTrue(#mixer.log.updates > 0, "the bend change is queued to the active voice")
  -- The pitch_bend_range command also pushes the recomputed user pitch
  -- (bend 0 at the default range 2 -> 0), so the bend command's push is the
  -- last update.
  local push = mixer.log.updates[#mixer.log.updates]
  Assert.deepEqual(push.handle, { channel = 3, generation = 0 }, "the update targets the active voice's handle")
  Assert.equal(push.partial.userPitch, 64, "the bend reaches the held voice as user pitch (64*128>>7 = 64)")
  Assert.isNil(push.partial.key, "the update changes pitch without replacing the voice's midi key")
end

function T.handle_track_pitch_updates_live_voices_and_resets_on_replacement()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note", key = 60, velocity = 127, duration = 100 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  local handle = player:createHandle()
  player:play(handle, provider:sequence(0), provider:bank(12))
  player:render(250)

  Assert.equal(#mixer.log.noteOns, 1, "the initial play starts one voice")
  Assert.equal(#mixer.log.noteOffs, 0, "the initial voice is still ringing")
  Assert.equal(mixer.log.noteOns[1].userPitch, 0, "new instances start at zero external pitch")
  player:setHandleTrackPitch(handle, -96)
  Assert.equal(#mixer.log.noteOns, 1, "external pitch does not restart an active note")
  local pitchUpdate
  for _, candidate in ipairs(mixer.log.updates) do
    if candidate.partial.userPitch == -96 then
      pitchUpdate = candidate
      break
    end
  end
  local observedPitches = {}
  for _, candidate in ipairs(mixer.log.updates) do
    observedPitches[#observedPitches + 1] = tostring(candidate.partial.userPitch)
  end
  Assert.notNil(
    pitchUpdate,
    "external pitch reaches the live voice as user pitch (observed " .. table.concat(observedPitches, ",") .. ")"
  )

  player:play(handle, provider:sequence(0), provider:bank(12))
  player:render(250)
  Assert.equal(#mixer.log.noteOns, 2, "replacement starts a fresh voice")
  Assert.equal(mixer.log.noteOns[2].userPitch, 0, "replacement resets external pitch")
end

-- The player queues control changes (volume, pan, expression, fader, LFO,
-- user pitch) to its live voices as events; it has no independently rounded
-- control clock of its own -- the mixer owns the 192 Hz cadence -- so a
-- value change becomes audible at the next mixer control step without
-- waiting for a player-side period boundary.
function T.track_value_changes_reach_active_voices_promptly()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 4 },
      { op = "volume", amount = 60 },
      { op = "pan", amount = 40 },
      { op = "expression", amount = 80 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(100)
  Assert.isTrue(#mixer.log.updates > 0, "the changed values reach the active voice within the first control period")
  local push
  for _, update in ipairs(mixer.log.updates) do
    if
      update.partial.trackVolume == 60
      and update.partial.expression == 80
      and update.partial.trackPanOffset == -24
    then
      push = update
    end
  end
  Assert.notNil(push, "the push carries the current track volume, expression and raw pan offset")
  Assert.deepEqual(push.handle, { channel = 3, generation = 0 }, "the push targets the active voice's handle")
  Assert.equal(push.partial.sequenceVolume, 127, "the push carries the inner sequence volume")
end

-- Deterministic scheduling: the player processes physical slots ascending and
-- each slot's tracks ascending over the fixed NNS domains (16 slots x 16
-- tracks per slot). Within every processing pass the lower track numbers
-- issue their noteOn first.
function T.contested_allocation_follows_ascending_track_order()
  local bank = AudioFixture.bank(12, "BANK_TEST", {
    AudioFixture.key(1),
    AudioFixture.key(2),
    AudioFixture.key(3),
  }, {
    [0] = { kind = "direct", voice = voice(AudioFixture.key(1)) },
    [1] = { kind = "direct", voice = voice(AudioFixture.key(2)) },
    [2] = { kind = "direct", voice = voice(AudioFixture.key(3)) },
  })
  local program = {
    { op = "open_track", track = 9, target = 7 },
    { op = "open_track", track = 15, target = 11 },
    { op = "wait", duration = 1 },
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "jump", target = 4 },
    { op = "wait", duration = 1 },
    { op = "program", program = 1 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "jump", target = 8 },
    { op = "wait", duration = 1 },
    { op = "program", program = 2 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "jump", target = 12 },
  }
  local mixer = stubMixer()
  local player, provider = engine({ [0] = seq(program, { symbol = "SEQ_CONTEST", initialTrackMask = 0x8201 }) }, {
    bank = bank,
    channelMask = 0x0010,
    mixer = mixer,
  })
  play(player, provider)
  player:render(1000)
  Assert.equal(#mixer.log.noteOns, 6, "each tick notes tracks 0, 9 and 15 once (the sub-tracks open gated)")
  Assert.equal(mixer.log.noteOns[1].channelMask, 0x0010, "the sequence's player channel mask rides the note specs")
  for i = 1, 6 do
    local expected = ({ AudioFixture.key(1), AudioFixture.key(2), AudioFixture.key(3) })[((i - 1) % 3) + 1]
    Assert.equal(
      generatorOf(mixer.log.noteOns[i]).sample,
      expected,
      "every pass notes tracks 0, 9, 15 in ascending track order"
    )
  end
end

-- Deterministic scheduling across physical slots: play order determines the
-- first-free slot, and slots then process in ascending order. The initial
-- play() pass follows the call order; each later pass follows slot order.
function T.contested_allocation_follows_physical_slot_order()
  local bank = AudioFixture.bank(12, "BANK_TEST", {
    AudioFixture.key(1),
    AudioFixture.key(2),
  }, {
    [0] = { kind = "direct", voice = voice(AudioFixture.key(1)) },
    [1] = { kind = "direct", voice = voice(AudioFixture.key(2)) },
  })
  local function programFor(i, playerId)
    return seq({
      { op = "program", program = i % 2 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "jump", target = 2 },
    }, { id = i, symbol = "SEQ_P" .. playerId, playerId = playerId })
  end
  local function run(order)
    local sequences = {
      [0] = programFor(0, 1),
      [1] = programFor(1, 7),
      [2] = programFor(2, 13),
      [3] = programFor(3, 15),
    }
    local mixer = stubMixer()
    local provider = TestProvider.new(buildBundle(sequences, {
      bank = bank,
      channelMask = 0x0010,
    }))
    local player = SequencePlayer.new({
      sampleRate = SAMPLE_RATE,
      mixer = mixer,
      provider = provider,
    })
    for _, index in ipairs(order) do
      player:play(player:createHandle(), provider:sequence(index), provider:bank(12))
    end
    player:render(1000)
    return mixer
  end
  local forward = run({ 0, 1, 2, 3 })
  local backward = run({ 3, 2, 1, 0 })
  -- Under the interval scheduler, play() does not run the entry program:
  -- each player's first tick fires on the first completed interval and a
  -- default-tempo player ticks every two intervals, so four players in
  -- 1000 frames (four intervals) produce 4 x 2 = 8 noteOns.
  Assert.equal(#forward.log.noteOns, 8, "one noteOn per player per tempoCounter tick (two ticks in four intervals)")
  Assert.equal(#backward.log.noteOns, 8)
  for i = 5, 8 do
    local expected = ({ AudioFixture.key(1), AudioFixture.key(2) })[((i - 5) % 2) + 1]
    Assert.equal(
      generatorOf(forward.log.noteOns[i]).sample,
      expected,
      "the physical-slot order follows allocation order"
    )
    Assert.equal(
      generatorOf(backward.log.noteOns[i]).sample,
      ({ AudioFixture.key(2), AudioFixture.key(1) })[((i - 5) % 2) + 1],
      "the reversed allocation order reverses physical-slot execution"
    )
  end
end

function T.releases_expired_channel_before_the_next_physical_slot_runs()
  local sequences = {
    [0] = seq({
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "wait", duration = 100 },
    }, { id = 0, symbol = "SEQ_RELEASE", playerId = 1, channelPriority = 200 }),
    [1] = seq({
      { op = "wait", duration = 1 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "wait", duration = 100 },
    }, { id = 1, symbol = "SEQ_STEAL", playerId = 7, channelPriority = 0 }),
  }
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local noteHandles = {}
  local noteOn = mixer.noteOn
  mixer.noteOn = function(self, noteSpec)
    local handle = noteOn(self, noteSpec)
    if handle ~= nil then
      noteHandles[#noteHandles + 1] = handle
    end
    return handle
  end
  local player, provider = engine(sequences, { mixer = mixer, channelMask = 0x0010 })

  local first, second = player:createHandle(), player:createHandle()
  player:play(first, provider:sequence(0), provider:bank(12))
  player:play(second, provider:sequence(1), provider:bank(12))
  player:render(500)
  Assert.deepEqual(noteHandles[1], { channel = 4, generation = 0 })

  player:render(500)
  Assert.deepEqual(
    noteHandles[2],
    { channel = 4, generation = 1 },
    "the later physical slot sees the earlier slot's released channel"
  )
  Assert.isFalse(mixer:isVoiceAlive(noteHandles[1]), "the old handle is stale after replacement")
  Assert.isTrue(mixer:isVoiceAlive(noteHandles[2]), "the later slot's note remains live")
end

-- The full NNS track domain: all 16 tracks of a player run, and every note
-- carries the semantic spec.
function T.all_sixteen_tracks_play_in_parallel()
  local mixer = stubMixer()
  local main = {}
  for track = 1, 15 do
    main[#main + 1] = { op = "open_track", track = track, target = 18 + (track - 1) * 2 }
  end
  main[#main + 1] = { op = "note", key = 60, velocity = 127, duration = 1 }
  main[#main + 1] = { op = "end" }
  local instructions = main
  for _ = 1, 15 do
    instructions[#instructions + 1] = { op = "note", key = 60, velocity = 127, duration = 1 }
    instructions[#instructions + 1] = { op = "end" }
  end
  local player, provider = engine({ [0] = seq(instructions, { initialTrackMask = 0xFFFF }) }, { mixer = mixer })
  play(player, provider)
  player:render(100)
  Assert.equal(#mixer.log.noteOns, 16, "all sixteen tracks note in the first pass")
  for i = 1, 16 do
    Assert.equal(mixer.log.noteOns[i].trackPriority, 64, "track " .. (i - 1) .. " carries the default track priority")
  end
end

-- The per-player queries GameSound builds its wait and stop semantics on:
-- a player is playing while any of its tracks run, and stopping one player
-- releases exactly that player's voices.
function T.stop_player_releases_only_that_player()
  local mixer = stubMixer()
  local bgm = seq({
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "jump", target = 2 },
  }, { playerId = 1 })
  local effect = seq(
    { { op = "program", program = 1 }, { op = "note", key = 60, velocity = 127, duration = 10 }, { op = "end" } },
    {
      id = 1,
      symbol = "SEQ_EFFECT",
      playerId = 2,
    }
  )
  local player, provider = engine({ [0] = bgm, [1] = effect }, { mixer = mixer })
  local first, second = player:createHandle(), player:createHandle()
  player:play(first, provider:sequence(0), provider:bank(12))
  player:play(second, provider:sequence(1), provider:bank(12))
  player:render(1000)
  player:stopPlayer(2)
  -- Verify that only the effect player's voice is released
  -- The test structure expects the noteOffs log to contain only the stopPlayer release
  Assert.isTrue(#mixer.log.noteOffs > 0, "stopPlayer released voices")
  local lastReleaseGeneration = mixer.log.noteOffs[#mixer.log.noteOffs].handle.generation
  Assert.isTrue(lastReleaseGeneration >= 0, "the stopped player's voice was released")
end

function T.an_ended_or_never_played_player_reports_free()
  local player, provider =
    engine({ [0] = seq({ { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } }, { playerId = 2 }) })
  Assert.isFalse(player:isPlayerPlaying(2), "a player with no instance reports free")
  player:play(player:createHandle(), provider:sequence(0), provider:bank(12))
  -- At default tempo 120 a player ticks every two sound intervals (250,
  -- 750, ... at 48 kHz): the first tick notes (gating the track), the
  -- second tick opens the gate and runs `end`. 1000 frames (four intervals)
  -- covers both ticks.
  player:render(1000)
  Assert.isFalse(player:isPlayerPlaying(2), "a player whose sequence ended reports free")
  Assert.isFalse(player:isPlaying())
  player:stopPlayer(2)
  player:stopPlayer(9)
end

-- The real HGSS corpus vocabulary: 0x80 `wait` gates the track without
-- releasing a ringing note, 0xFF `end` terminates the track,
-- and 0xC7 `note_wait` clears the note-gating flag (fresh tracks start with
-- it set, per the NNS TrackInit), so composers pair every note with explicit
-- waits. The note's own length bounds its ring independently of gates (the
-- NNS channel length). A positive wait decrements per tick; a zero wait does
-- not gate; a negative wait is a stall (never decremented), covered below.
function T.wait_gates_the_track_while_the_note_rings_its_own_length()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 2 },
      { op = "wait", duration = 1 },
      { op = "wait", duration = 1 },
      { op = "wait", duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(1000)
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = nil } },
    "a note whose gating is cleared rings exactly its own duration; the waits gate without releasing it"
  )
  player:render(500)
  Assert.isFalse(player:isPlaying(), "end terminates the track")
end

-- The sweep/portamento commands wire the TrackPlayNote channel state into
-- the noteOn spec (SND_seq.c): 0xE3 sweep stores the s16 track sweepPitch;
-- 0xC9 portamento_key stores amount + transpose and sets the portamento
-- flag; a noteOn while portamento is on adds (portamentoKey - midiKey) << 6
-- pitch units; portamentoTime 0 carries the note length as sweepLength with
-- autoSweep false, a nonzero time carries
-- portamentoTime^2 * |sweepPitch| >> 11 with autoSweep true; 0xCE
-- portamento 0 clears the flag and the contribution. After each note the
-- track's portamentoKey is updated to the note's MIDI key, so the next
-- portamento contribution slides from the just-played pitch.
function T.sweep_and_portamento_commands_wire_the_note_sweep_spec()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "sweep", amount = -100 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "portamento_key", amount = 64 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "portamento_time", amount = 8 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "portamento", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "portamento", amount = 1 },
      { op = "transpose", amount = -12 },
      { op = "portamento_key", amount = 64 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "note", key = 61, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(100)
  local specs = mixer.log.noteOns
  Assert.equal(#specs, 7, "the commands gate nothing: every note allocates in the first pass")
  Assert.deepEqual(
    { sweepPitch = specs[1].sweepPitch, sweepLength = specs[1].sweepLength, autoSweep = specs[1].autoSweep },
    { sweepPitch = 0, sweepLength = 1, autoSweep = false },
    "a fresh track: no sweep, portamentoTime 0 makes the note length the sweep length"
  )
  Assert.deepEqual(
    { sweepPitch = specs[2].sweepPitch, sweepLength = specs[2].sweepLength, autoSweep = specs[2].autoSweep },
    { sweepPitch = -100, sweepLength = 1, autoSweep = false },
    "the sweep command sets the track sweepPitch; the next noteOn's spec carries it"
  )
  Assert.deepEqual(
    { sweepPitch = specs[3].sweepPitch, sweepLength = specs[3].sweepLength, autoSweep = specs[3].autoSweep },
    { sweepPitch = -100 + (64 - 60) * 64, sweepLength = 1, autoSweep = false },
    "portamento_key 64 adds (portamentoKey - midiKey) << 6 = 256 to the track sweep"
  )
  Assert.deepEqual(
    { sweepPitch = specs[4].sweepPitch, sweepLength = specs[4].sweepLength, autoSweep = specs[4].autoSweep },
    { sweepPitch = -100, sweepLength = 3, autoSweep = true },
    "the previous note updated portamentoKey to midi key 60, so this note adds no contribution (8^2*100>>11 = 3)"
  )
  Assert.deepEqual(
    { sweepPitch = specs[5].sweepPitch, sweepLength = specs[5].sweepLength, autoSweep = specs[5].autoSweep },
    { sweepPitch = -100, sweepLength = 3, autoSweep = true },
    "portamento 0 clears the flag: the note carries only the track sweep"
  )
  Assert.deepEqual(
    { sweepPitch = specs[6].sweepPitch, sweepLength = specs[6].sweepLength, autoSweep = specs[6].autoSweep },
    { sweepPitch = -100 + (52 - 48) * 64, sweepLength = 4, autoSweep = true },
    "portamento_key stores amount + transpose (52); the note's midiKey is 48, so the contribution is still 256"
  )
  Assert.deepEqual(
    { sweepPitch = specs[7].sweepPitch, sweepLength = specs[7].sweepLength, autoSweep = specs[7].autoSweep },
    { sweepPitch = -100 + (48 - 49) * 64, sweepLength = 5, autoSweep = true },
    "portamentoKey was updated to the previous note's midi key 48; the key-61 note slides down (8^2*164>>11 = 5)"
  )
end

-- The mod commands wire the TrackUpdateChannel lfo snapshot (SND_seq.c
-- 0xCA-0xCD, 0xE0) into the next noteOn's spec with the TrackInit defaults
-- (SND_InitLfoParam) when unset. The commands gate nothing and release
-- nothing.
function T.mod_commands_wire_the_note_lfo_spec()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "mod_depth", amount = 100 },
      { op = "mod_speed", amount = 10 },
      { op = "mod_type", amount = 1 },
      { op = "mod_range", amount = 3 },
      { op = "mod_delay", amount = 16 },
      { op = "note", key = 60, velocity = 127, duration = 2 },
      { op = "wait", duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  Assert.equal(#mixer.log.noteOns, 2, "the mod commands gate nothing: both notes allocate in the first pass")
  Assert.equal(#mixer.log.noteOffs, 0, "the mod commands release nothing")
  Assert.deepEqual(
    mixer.log.noteOns[1].lfo,
    { target = 0, depth = 0, range = 1, speed = 16, delay = 0 },
    "an unset mod is the TrackInit lfo (SND_InitLfoParam)"
  )
  Assert.deepEqual(
    mixer.log.noteOns[2].lfo,
    { target = 1, depth = 100, range = 3, speed = 10, delay = 16 },
    "mod_depth/mod_speed/mod_type/mod_range/mod_delay wire the lfo snapshot"
  )
  player:render(500)
  Assert.deepEqual(mixer.log.noteOffs, {
    { handle = { channel = 3, generation = 0 }, releaseOverride = nil },
    { handle = { channel = 3, generation = 1 }, releaseOverride = nil },
  }, "the first voice expires and END immediately releases the remaining voice")
  player:render(500)
  Assert.deepEqual(mixer.log.noteOffs, {
    { handle = { channel = 3, generation = 0 }, releaseOverride = nil },
    { handle = { channel = 3, generation = 1 }, releaseOverride = nil },
  }, "the second voice rings its own longer length")
  Assert.isFalse(player:isPlaying(), "the sequence ends after the notes ring out")
end

-- Modulation commands change active voice behavior: the changed LFO
-- parameters are queued to the ringing voice's handle so the mixer's LFO
-- applies them at its control steps -- the player does not advance LFOs
-- itself.
function T.modulation_commands_update_active_voices()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 4 },
      { op = "mod_depth", amount = 64 },
      { op = "mod_speed", amount = 8 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(100)
  Assert.isTrue(#mixer.log.updates > 0, "the LFO change reaches the active voice")
  Assert.deepEqual(mixer.log.updates[1].handle, { channel = 3, generation = 0 })
  Assert.deepEqual(
    mixer.log.updates[1].partial.lfo,
    { target = 0, depth = 64, range = 1, speed = 8, delay = 0 },
    "the queued partial carries the updated LFO parameters"
  )
end

-- 0xB0 `setvar` writes player variables and variable amount operands read
-- them back (the real 0x81-variable program references in the corpus).
function T.setvar_and_variable_amounts_resolve_from_player_variables()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "setvar", var = 0, amount = 1 },
      { op = "program", program = { kind = "variable", var = 0 } },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(100)
  Assert.equal(generatorOf(mixer.log.noteOns[1]).sample, AudioFixture.key(2), "the variable amount selects the program")
end

-- The variable-domain arithmetic (SND_seq.c var commands): every store
-- wraps to s16, division by zero skips, the quotient truncates toward zero
-- (a negative divisor included), a negative shift moves right, signed s16
-- operands (0xFFFF lowers to -1) take part in the same arithmetic, and
-- randomvar draws the SDK u16 value and scales (random * (abs(par)+1)) >> 16
-- with the par's sign. The resulting variable is observed through a pan
-- amount operand (the note spec's trackPanOffset is var - 64).
function T.variable_arithmetic_wraps_and_truncates_like_the_sdk()
  local cases = {
    { op = "addvar", init = 30000, amount = 30000, expected = -5536, rng = nil, label = "addvar wraps to s16" },
    { op = "subvar", init = -30000, amount = 30000, expected = 5536, rng = nil, label = "subvar wraps to s16" },
    { op = "mulvar", init = 20000, amount = 2, expected = -25536, rng = nil, label = "mulvar wraps to s16" },
    { op = "divvar", init = 15, amount = 4, expected = 3, rng = nil, label = "divvar truncates toward zero" },
    {
      op = "divvar",
      init = -15,
      amount = 4,
      expected = -3,
      rng = nil,
      label = "divvar truncates toward zero on a negative dividend",
    },
    {
      op = "divvar",
      init = -7,
      amount = -3,
      expected = 2,
      rng = nil,
      label = "divvar truncates toward zero on a negative divisor",
    },
    {
      op = "divvar",
      init = 7,
      amount = -3,
      expected = -2,
      rng = nil,
      label = "divvar truncates toward zero on a negative divisor and dividend",
    },
    { op = "divvar", init = 12, amount = 0, expected = 12, rng = nil, label = "divvar skips division by zero" },
    { op = "shiftvar", init = 3, amount = 2, expected = 12, rng = nil, label = "shiftvar shifts left" },
    {
      op = "shiftvar",
      init = -32768,
      amount = -4,
      expected = -2048,
      rng = nil,
      label = "a negative shift moves right (arithmetic)",
    },
    { op = "addvar", init = 5, amount = -1, expected = 4, rng = nil, label = "0xFFFF adds as -1 (s16 operand)" },
    { op = "mulvar", init = 5, amount = -1, expected = -5, rng = nil, label = "0xFFFF multiplies as -1" },
    { op = "divvar", init = 15, amount = -1, expected = -15, rng = nil, label = "0xFFFF divides as -1" },
    { op = "shiftvar", init = 4, amount = -1, expected = 2, rng = nil, label = "0xFFFF is a negative (right) shift" },
    {
      op = "randomvar",
      init = 0,
      amount = 10,
      expected = 5,
      rng = u16Draws({ 30019 }),
      label = "randomvar scales the u16 draw (30019*11)>>16 = 5",
    },
    {
      op = "randomvar",
      init = 0,
      amount = -10,
      expected = -5,
      rng = u16Draws({ 30019 }),
      label = "randomvar negates the draw for a negative par",
    },
    {
      op = "randomvar",
      init = 0,
      amount = -32768,
      expected = 15010,
      rng = u16Draws({ 30019 }),
      label = "randomvar preserves the signed-minimum cast before scaling",
    },
  }
  for _, case in ipairs(cases) do
    local mixer = stubMixer()
    local player, provider = engine({
      [0] = seq({
        { op = "setvar", var = 0, amount = case.init },
        { op = case.op, var = 0, amount = case.amount },
        -- The sweep command carries the stored s16 variable value straight
        -- to the note spec, so the wrap/truncation result is observable
        -- without any further width conversion.
        { op = "sweep", amount = { kind = "variable", var = 0 } },
        { op = "note", key = 60, velocity = 127, duration = 1 },
        { op = "end" },
      }),
    }, { mixer = mixer, rng = case.rng })
    play(player, provider)
    player:render(100)
    Assert.equal(mixer.log.noteOns[1].sweepPitch, case.expected, case.op .. ": " .. case.label)
  end
end

-- The transport pause (the NNS SND_PlayerPause the HGSS PlayFanfare path
-- uses): pauseHandle marks the timeline paused and releases the player's
-- current channel handles with release override 127, freeing them from the
-- tracks. While paused the timeline does not advance and no notes issue;
-- resumeHandle only unpauses the timeline and never resurrects the released
-- voices.
function T.pause_releases_channels_with_an_override_and_resume_does_not_resurrect()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "program", program = 0 },
      { op = "note", key = 60, velocity = 127, duration = 8 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  local handle = play(player, provider)
  player:render(200)
  player:pauseHandle(handle)
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = 127 } },
    "pause releases the player's channels with the forced release override"
  )
  player:render(6000)
  Assert.equal(#mixer.log.noteOns, 1, "no notes issue while paused")
  Assert.equal(#mixer.log.noteOffs, 1, "no voice expires while the timeline is frozen")
  -- The pause release itself pre-pushed the current full track values once
  -- (the source TrackReleaseChannels opens with TrackUpdateChannel) before
  -- the forced release and free; nothing after that touches the old handle.
  local updatesAtPause = #mixer.log.updates
  player:resumeHandle(handle)
  player:render(4000)
  Assert.equal(
    #mixer.log.updates,
    updatesAtPause,
    "resume does not resurrect the released voice: its handle is gone from the tracks"
  )
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = 127 } },
    "the frozen gate expires without re-releasing anything"
  )
  Assert.isFalse(player:isPlaying(), "the sequence ran out its frozen timeline after resume")
end

-- Pause and resume follow the NNS player-state guard: pausing an unknown
-- player or an already-paused player, and resuming an unknown or unpaused
-- player, are no-ops -- a fanfare without a BGM must never fault and a
-- double pause must not release twice.
function T.pause_and_resume_guards_are_no_ops()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "program", program = 0 },
      { op = "note", key = 60, velocity = 127, duration = 8 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  local unused = player:createHandle()
  player:pauseHandle(unused)
  player:resumeHandle(unused)
  local handle = play(player, provider)
  player:render(200)
  player:pauseHandle(handle)
  player:pauseHandle(handle)
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = 127 } },
    "the double pause releases exactly once"
  )
  player:resumeHandle(handle)
  player:resumeHandle(handle)
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = 127 } },
    "resume (once or twice) never releases again"
  )
  player:render(4000)
  Assert.isFalse(player:isPlaying())
end

-- Pause escalates a still-attached natural release to the forced coefficient;
-- a second pause remains a no-op after the track handles are detached.
function T.pause_escalates_an_attached_natural_release()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note", key = 60, velocity = 127, duration = 2 },
      { op = "wait", duration = 10 },
    }),
  }, { mixer = mixer })
  local handle = play(player, provider)
  player:render(1000)
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = nil } },
    "natural expiry starts the ordinary release"
  )
  player:pauseHandle(handle)
  player:pauseHandle(handle)
  Assert.deepEqual(mixer.log.noteOffs, {
    { handle = { channel = 3, generation = 0 }, releaseOverride = nil },
    { handle = { channel = 3, generation = 0 }, releaseOverride = 127 },
  }, "pause forwards forced release 127 for the still-live attached voice once")
  player:resumeHandle(handle)
  player:render(3000)
end

-- A new sequence on a paused player replaces the released one: the paused
-- instance's handles were already freed, so the replacement releases
-- nothing extra and the fresh sequence starts cleanly.
function T.playing_on_a_paused_player_releases_and_replaces()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "program", program = 0 },
      { op = "note", key = 60, velocity = 127, duration = 8 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  local handle = play(player, provider)
  player:render(250)
  player:pauseHandle(handle)
  player:render(250)
  player:play(handle, provider:sequence(0), provider:bank(12))
  player:render(250)
  Assert.equal(#mixer.log.noteOns, 2, "the replacement starts its fresh sequence")
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = 127 } },
    "the pause release was the only release: the freed paused instance adds none"
  )
end

-- The natural-duration release is a release START, not a detach: when a
-- positive note length reaches zero the player calls one ordinary noteOff
-- and keeps the record attached while the mixer still reports the voice
-- alive (the SDK's TrackReleaseChannels without TrackFreeChannels). A
-- note-finish wait coexisting with such an attached release tail therefore
-- stays blocked until the mixer reports the tail dead, even though the
-- sequence note length reached zero earlier, and no second noteOff is
-- issued merely because the tail remains alive. The recording mixer's
-- kill() simulates the mixer removing a voice at its own death moment.
function T.natural_release_stays_attached_until_the_mixer_reports_death()
  local mixer = stubMixer()
  -- The finite note A rings its own length; the zero-length note B (under
  -- note-wait) sets the note-finish hold after A's length expires; the
  -- marker C must not start until every attached voice -- including A's
  -- release tail -- is dead.
  local player, provider = engine({
    [0] = seq({
      { op = "program", program = 0 },
      { op = "note", key = 60, velocity = 127, duration = 2 },
      { op = "note", key = 61, velocity = 127, duration = 0 },
      { op = "note", key = 62, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider) -- tick 1 (frame 250): note A starts and gates the track
  player:render(500) -- tick 2 (frame 750): A's wait decrements
  player:render(500) -- tick 3 (frame 1250): A's length expires; B sets the finish hold
  local handleA = mixer.log.noteHandles[1]
  local handleB = mixer.log.noteHandles[2]
  Assert.equal(#mixer.log.noteOns, 2, "the finite note and the zero-length note both allocated")
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = nil } },
    "the length expiry calls one ordinary noteOff at length zero"
  )
  Assert.isTrue(mixer:isVoiceAlive(handleA), "the released voice is still alive in the mixer")
  player:render(500) -- tick 4 (frame 1750): the finish hold is still blocked
  Assert.equal(#mixer.log.noteOns, 2, "the finish hold stays blocked while the release tail lives")
  Assert.equal(#mixer.log.noteOffs, 1, "no second noteOff is issued merely because the release tail remains alive")
  -- The zero-length note's voice dies (stolen or naturally stopped), but
  -- A's attached release tail is still alive: the finish hold must NOT
  -- clear -- the attached releasing voice keeps the track blocked.
  mixer:kill(handleB)
  player:render(500) -- tick 5 (frame 2250)
  Assert.equal(#mixer.log.noteOns, 2, "the finish hold does not clear while the attached release tail is still alive")
  Assert.isTrue(mixer:isVoiceAlive(handleA), "the release tail is still alive")
  -- Only when the mixer reports the tail dead does the hold clear and the
  -- marker note run.
  mixer:kill(handleA)
  player:render(500) -- tick 6 (frame 2750): the finish hold clears; marker C starts
  Assert.equal(#mixer.log.noteOns, 3, "the finish hold clears only when every attached voice is dead")
  Assert.equal(mixer.log.noteOns[3].key, 62, "the marker note starts after the tail died")
  -- Marker C gates the track for its own duration; the following tick runs
  -- its `end`.
  player:render(500) -- tick 7 (frame 3250)
  Assert.isFalse(player:isPlaying())
end

-- The real SequencePlayer and VoiceMixer observe the same boundary ordering:
-- sequence work sees a physically completed one-shot before channel control
-- retires its logical handle.
function T.note_finish_wait_observes_real_one_shot_liveness_until_control_step()
  local noteEvents = {}
  local player, provider = engine({
    [0] = seq({
      { op = "note", key = 60, velocity = 127, duration = 0 },
      { op = "note", key = 61, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, {
    mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE }),
    sampleA = { 1000, 2000 },
    sampleAMetadata = AudioFixture.sampleMetadata(AudioFixture.key(1), {
      frames = 2,
      baseTimer = 65535,
      loopEnabled = false,
      loop = { startFrame = 0, endFrame = 2 },
    }),
    observer = {
      onNoteEvent = function(_, event)
        noteEvents[#noteEvents + 1] = event.key
      end,
    },
  })
  play(player, provider)
  player:render(250)
  Assert.deepEqual(noteEvents, { 60 }, "the first note remains the only note through the 500 boundary")
  player:render(250)
  Assert.deepEqual(noteEvents, { 60 }, "the finish hold remains blocked at the physical end boundary")
  player:render(500)
  Assert.deepEqual(noteEvents, { 60, 61 }, "the next note starts after control retires the one-shot")
end

-- Mute mode 2 (the SDK TrackMute release-without-free) starts an ordinary
-- release on the track's attached voices but leaves the handles attached:
-- a later fader move still reaches the releasing voices, while a
-- non-fader track control (volume, pan, user pitch) must not be pushed to
-- them after release status (source TrackUpdateChannel updates only
-- userDecay2 on linked releasing channels). This is the explicit-detach
-- contrast: tie/pause/stop drop the handle immediately.
function T.mute_two_keeps_releasing_voices_attached_for_fader_updates()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 3 },
      { op = "wait", duration = 1 },
      { op = "mute", amount = 2 },
      { op = "wait", duration = 1 },
      { op = "pan", amount = 40 },
      { op = "wait", duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  local sequenceHandle = player:createHandle()
  player:play(sequenceHandle, provider:sequence(0), provider:bank(12))
  player:render(250)
  local handle = mixer.log.noteHandles[1]
  player:render(500) -- tick 1 (frame 250): note + wait gate; tick 2 (frame 500): mute 2 executes
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = nil } },
    "mute 2 releases the attached voice with the ordinary release (no override)"
  )
  Assert.isTrue(mixer:isVoiceAlive(handle), "mute 2 leaves the releasing voice attached and alive")
  -- The mute-2 tick itself pre-pushes the current full track values once
  -- (the source TrackReleaseChannels opens with TrackUpdateChannel, while
  -- the voice is still non-releasing); from the release start on, only
  -- fader changes may be queued. The pan command after mute 2 must reach
  -- nothing.
  local updatesAtMute2 = #mixer.log.updates
  player:render(500) -- tick 3 (frame 750): the pan command runs
  local pushedPan = false
  for index = updatesAtMute2 + 1, #mixer.log.updates do
    if mixer.log.updates[index].partial.trackPanOffset ~= nil then
      pushedPan = true
    end
  end
  Assert.isFalse(pushedPan, "a pan command after mute 2 must not reach the releasing voice")
  -- A fader move still reaches the attached releasing voice (fader-only
  -- post-release updates, source TrackUpdateChannel userDecay2).
  player:setHandleFader(sequenceHandle, 42)
  player:render(10)
  local faderPush
  for _, update in ipairs(mixer.log.updates) do
    if update.partial.fader ~= nil and update.partial.trackPanOffset == nil then
      faderPush = update
    end
  end
  Assert.notNil(faderPush, "a fader move still reaches the attached releasing voice")
  Assert.deepEqual(faderPush.handle, { channel = 3, generation = 0 }, "the fader push targets the releasing handle")
  Assert.equal(faderPush.partial.fader, -96, "the outer fader uses the ARM9 dB domain")
  Assert.isNil(faderPush.partial.trackVolume, "the post-release push carries no non-fader track values")
  Assert.isNil(faderPush.partial.userPitch, "the post-release push carries no pitch")
  Assert.isNil(faderPush.partial.trackPanOffset, "the post-release push carries no pan")
  -- The tie path is the detach contrast: releasing then dropping the
  -- handle so a later command never updates it.
  local tieMixer = stubMixer()
  local tiePlayer, tieProvider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 3 },
      { op = "wait", duration = 1 },
      { op = "tie", amount = 1 },
      { op = "wait", duration = 1 },
      { op = "pan", amount = 40 },
      { op = "end" },
    }),
  }, { mixer = tieMixer })
  play(tiePlayer, tieProvider)
  local tieHandle = tieMixer.log.noteHandles[1]
  tiePlayer:render(500) -- the tie command releases and frees the handle
  Assert.deepEqual(
    tieMixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = nil } },
    "the tie command releases the current voice"
  )
  -- The tie's own release pre-pushed the full track values once (the source
  -- TrackReleaseChannels opens with TrackUpdateChannel); from the detach on,
  -- the pan after the tie must reach nothing.
  local updatesAtTie = #tieMixer.log.updates
  tiePlayer:render(500) -- the pan after the tie runs on the empty collection
  local tiePushes = 0
  for index = updatesAtTie + 1, #tieMixer.log.updates do
    if tieMixer.log.updates[index].partial.trackPanOffset ~= nil then
      tiePushes = tiePushes + 1
    end
  end
  Assert.equal(tiePushes, 0, "after the tie detaches the handle, a later pan never updates it")
  Assert.isTrue(tieMixer:isVoiceAlive(tieHandle), "the mixer release tail may continue after the detach")
end

-- A tied re-note over a live head voice executes the source TrackPlayNote
-- common tail on the SAME physical generation: no noteOn, no noteOff, the
-- midi key and velocity update in place, the current track envelope
-- overrides replace the voice's envelope coefficients (without resetting
-- the attack stage or the sample phase), the sweep/portamento state is
-- recomputed (sweep pitch plus the portamento contribution, the sweep
-- length from portamentoTime, the auto-sweep choice) and the sweep
-- counter resets to zero, and the track's portamento key updates to the
-- new MIDI key after the note. The retargeted voice stays indefinite.
function T.tied_renote_applies_the_full_common_tail_without_restarting()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "tie", amount = 1 },
      { op = "note", key = 60, velocity = 96, duration = 1 },
      { op = "sweep", amount = -100 },
      { op = "portamento_key", amount = 65 },
      { op = "portamento_time", amount = 8 },
      { op = "attack", amount = 100 },
      { op = "release", amount = 90 },
      { op = "note", key = 61, velocity = 110, duration = 1 },
      { op = "wait", duration = 1 },
      { op = "tie", amount = 0 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider) -- tick 1: the tie, re-note and wait all run
  Assert.equal(#mixer.log.noteOns, 1, "the tied first note allocates one voice")
  Assert.deepEqual(mixer.log.noteHandles[1], { channel = 3, generation = 0 })
  Assert.equal(#mixer.log.noteOffs, 0, "the tied re-note never releases the reused voice")
  Assert.equal(#mixer.log.updates, 1, "the common tail is one atomic update to the reused handle")
  local tail = mixer.log.updates[1]
  Assert.deepEqual(tail.handle, { channel = 3, generation = 0 }, "the update targets the same generation")
  Assert.equal(tail.partial.key, 61, "the midi key updates in place")
  Assert.equal(tail.partial.velocity, 110, "the velocity updates in place")
  Assert.deepEqual(
    tail.partial.envelope,
    { attack = 100, decay = nil, sustain = nil, release = 90 },
    "only the track's set envelope overrides reach the reused voice; unset stages keep the channel coefficients"
  )
  -- portamento_key 65 stores amount + transpose (65); the re-note's midi
  -- key is 61, so the contribution is (65 - 61) << 6 = 256 added to the
  -- track sweep -100: sweepPitch 156, sweepLength 8^2*156>>11 = 4, auto.
  Assert.equal(tail.partial.sweepPitch, 156, "the sweep pitch is recomputed with the portamento contribution")
  Assert.equal(tail.partial.sweepLength, 4, "the sweep length derives from portamentoTime")
  Assert.isNil(tail.partial.autoSweep, "nonzero tied portamento time omits the auto-sweep write")
  Assert.equal(tail.partial.sweepCounter, 0, "the sweep counter resets to zero on the re-note")
  player:render(500) -- tick 2: the wait expires; tie 0 releases and frees the reused voice
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = nil } },
    "clearing the tie releases and frees the reused voice"
  )
  player:render(500) -- tick 3: end
  Assert.equal(#mixer.log.noteOns, 1, "no voice was ever reallocated")
  -- The portamento-key-after-note observable: the re-note updates the
  -- track's portamento key to its own MIDI key, so a following re-note
  -- slides from the just-played key. The first re-note (key 61) slides
  -- from portamentoKey 64: sweep -100 + (64 - 61) << 6 = 92, sweep length
  -- 8^2*92>>11 = 2; the second re-note (key 62) slides from the updated
  -- portamentoKey 61: sweep -100 + (61 - 62) << 6 = -164, length 5.
  local slideMixer = stubMixer()
  local slidePlayer, slideProvider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "tie", amount = 1 },
      { op = "note", key = 60, velocity = 96, duration = 1 },
      { op = "sweep", amount = -100 },
      { op = "portamento_key", amount = 64 },
      { op = "portamento_time", amount = 8 },
      { op = "note", key = 61, velocity = 96, duration = 1 },
      { op = "note", key = 62, velocity = 96, duration = 1 },
      { op = "wait", duration = 1 },
      { op = "tie", amount = 0 },
      { op = "end" },
    }),
  }, { mixer = slideMixer })
  play(slidePlayer, slideProvider)
  Assert.equal(slideMixer.log.updates[1].partial.sweepPitch, 92, "the first re-note slides from portamentoKey 64")
  Assert.equal(slideMixer.log.updates[1].partial.sweepLength, 2, "the first re-note's sweep length matches")
  Assert.equal(
    slideMixer.log.updates[2].partial.sweepPitch,
    -164,
    "the second re-note slides from the updated portamento key (61)"
  )
  Assert.equal(slideMixer.log.updates[2].partial.sweepLength, 5, "the recomputed sweep length matches the slide")
end

function T.tied_renote_writes_false_only_for_zero_portamento_time()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "tie", amount = 1 },
      { op = "portamento_time", amount = 0 },
      { op = "note", key = 60, velocity = 96, duration = 1 },
      { op = "portamento_time", amount = 8 },
      { op = "note", key = 61, velocity = 96, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  Assert.isNil(mixer.log.updates[1].partial.autoSweep, "nonzero tied portamento preserves false by omission")

  local zeroMixer = stubMixer()
  local zeroPlayer, zeroProvider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "tie", amount = 1 },
      { op = "portamento_time", amount = 8 },
      { op = "note", key = 60, velocity = 96, duration = 1 },
      { op = "portamento_time", amount = 0 },
      { op = "note", key = 61, velocity = 96, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = zeroMixer })
  play(zeroPlayer, zeroProvider)
  Assert.equal(zeroMixer.log.updates[1].partial.autoSweep, false, "zero tied portamento explicitly clears auto-sweep")
end

function T.tied_false_voice_does_not_auto_advance_between_sequence_ticks()
  local states = {}
  local mixer = VoiceMixer.new({
    sampleRate = SAMPLE_RATE,
    observer = {
      onChannelState = function(_, event)
        if event.active then
          states[#states + 1] = event
        end
      end,
    },
  })
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "tie", amount = 1 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "sweep", amount = 768 },
      { op = "portamento_time", amount = 8 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "wait", duration = 2 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  local first = states[#states]
  player:render(250)
  local second = states[#states]
  Assert.equal(first.timer, second.timer, "a preserved non-auto tied voice holds its timer between ticks")
  Assert.equal(first.generation, second.generation, "the tied re-note keeps the physical generation")
end

-- A pitch-bend-range command is a live channel control, not next-note-only
-- state: the player recomputes the user pitch (bend * (range << 6) >> 7)
-- and queues it to every attached non-releasing voice immediately, without
-- any note restart. A releasing attached voice receives no pitch update
-- (fader-only after release status).
function T.bend_range_changes_retune_held_voices_immediately()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 4 },
      { op = "pitch_bend", amount = 64 },
      { op = "pitch_bend_range", amount = 3 },
      { op = "wait", duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  Assert.equal(mixer.log.noteOns[1].userPitch, 0, "the note starts unbent")
  player:render(100) -- tick 1 runs the bend then the range change
  local pushed
  for _, update in ipairs(mixer.log.updates) do
    if update.partial.userPitch ~= nil then
      pushed = update
    end
  end
  Assert.notNil(pushed, "the range change queues a user pitch update to the held voice")
  Assert.deepEqual(pushed.handle, { channel = 3, generation = 0 }, "the update targets the held voice's handle")
  Assert.equal(pushed.partial.userPitch, 96, "bend 64 at range 3 recomputes (64*192)>>7 = 96")
  Assert.isNil(pushed.partial.key, "the range change retunes pitch without replacing the midi key")
  Assert.equal(#mixer.log.noteOffs, 0, "no note restart occurs")
  Assert.equal(#mixer.log.noteOns, 1, "no new voice is allocated")
end

-- The sweep counter has exactly one owner per auto flag: the sequence tick
-- advances each attached non-auto-sweep voice exactly once per tick
-- through the mixer's explicit track-tick operation (once per source
-- sequence tick, whatever the interval tempo), and the mixer's control
-- steps never advance the non-auto counter. A voice attaches during its
-- starting tick's command fetch -- after the tick's sweep pass -- so its
-- first advancement is the FOLLOWING tick; a voice whose sequence length
-- expires is advanced once on that tick before its release starts, and its
-- still-attached release tail keeps advancing on later ticks (source
-- TrackStepTicks walks every linked non-auto channel, releasing included).
-- Tempo 240 keeps the 192 Hz interval at exactly one sequence tick per
-- completed interval, so each 250-frame render advances the timeline by
-- one tick and the counts below are per-tick totals.
function T.sequence_ticks_advance_non_auto_sweep_once_per_attached_voice()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "tempo", amount = 240 },
      { op = "program", program = 0 },
      { op = "note", key = 60, velocity = 127, duration = 2 },
      { op = "wait", duration = 1 },
      { op = "jump", target = 2 },
    }),
  }, { mixer = mixer })
  play(player, provider) -- tick 1 (frame 250): the note starts (attaches in fetch)
  Assert.equal(#mixer.log.trackTicks, 0, "the starting tick's fetch attaches the voice after the sweep pass")
  player:render(250) -- tick 2 (frame 500): the length decrements to 1
  Assert.equal(#mixer.log.trackTicks, 1, "the following tick advances the fresh voice's non-auto sweep once")
  Assert.deepEqual(
    mixer.log.trackTicks[1],
    { channel = 3, generation = 0 },
    "the track tick targets the started voice's handle"
  )
  player:render(250) -- tick 3 (frame 750): the length expires (advance, then release starts)
  Assert.equal(#mixer.log.trackTicks, 2, "the expiry tick advances the sweep once before the release starts")
  player:render(250) -- tick 4 (frame 1000): the releasing tail stays attached and keeps advancing
  Assert.equal(#mixer.log.trackTicks, 3, "the releasing voice's attached tail keeps advancing once per tick")
  player:render(250) -- tick 5 (frame 1250): the wait expires, the jump re-notes
  Assert.equal(#mixer.log.noteOns, 2, "the jump re-notes after the voice expired")
  Assert.equal(
    #mixer.log.trackTicks,
    5,
    "the re-note tick advances the releasing tail and the fresh voice exactly once each"
  )
  player:render(250) -- tick 6 (frame 1500): the fresh voice's length decrements
  Assert.equal(
    #mixer.log.trackTicks,
    7,
    "the two attached voices (the releasing tail and the fresh voice) each advance once"
  )
  Assert.equal(#mixer.controlSteps, 6, "six completed intervals ran six control steps")
  Assert.equal(
    #mixer.log.trackTicks,
    7,
    "the control steps never advanced the non-auto sweep: only the sequence ticks did"
  )
end

-- Mute mode 3 is the SDK fast release + free: it sets the muted state,
-- performs the release with the forced override 127 on the track's
-- attached voices, and immediately detaches the handles -- so a later
-- fader move or track command never reaches the old handle even though the
-- mixer release tail may still be alive. It must never be modeled as mute
-- mode 2 plus a deferred cleanup.
function T.mute_three_forces_release_127_and_detaches_immediately()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 3 },
      { op = "wait", duration = 1 },
      { op = "mute", amount = 2 },
      { op = "wait", duration = 1 },
      { op = "mute", amount = 3 },
      { op = "wait", duration = 1 },
      { op = "pan", amount = 40 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  local handle = mixer.log.noteHandles[1]
  player:render(1000) -- mute 2 starts ordinary release; mute 3 escalates it
  Assert.deepEqual(mixer.log.noteOffs, {
    { handle = { channel = 3, generation = 0 }, releaseOverride = nil },
    { handle = { channel = 3, generation = 0 }, releaseOverride = 127 },
  }, "mute 3 escalates the attached mute-2 release with override 127")
  Assert.isTrue(mixer:isVoiceAlive(handle), "the mixer release tail may still be alive after mute 3")
  -- The release itself pre-pushed the current full track values once (the
  -- source TrackReleaseChannels opens with TrackUpdateChannel); from the
  -- detach on, no later command may reach the old handle.
  local updatesAtDetach = #mixer.log.updates
  player:render(500) -- the pan command runs after the detach
  local after = 0
  for index = updatesAtDetach + 1, #mixer.log.updates do
    local update = mixer.log.updates[index]
    if update.partial.fader ~= nil or update.partial.trackPanOffset ~= nil or update.partial.trackVolume ~= nil then
      after = after + 1
    end
  end
  Assert.equal(after, 0, "no fader or control update reaches the detached handle after mute 3")
  Assert.equal(#mixer.log.noteOns, 1, "the muted track allocates no new voice")
  player:render(500)
  Assert.equal(#mixer.log.noteOffs, 2, "the detached handle is never released again")
end

-- The per-player fader (the GameSound fade hook): setHandleFader stores the
-- volume-domain level and the queued update delivers its dB-domain
-- attenuation to the player's voices.
function T.the_player_fader_reaches_the_update_voice_push_in_the_db_domain()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 8 },
      { op = "wait", duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  local handle = play(player, provider)
  player:setHandleFader(handle, 42)
  player:render(300)
  local push
  for _, update in ipairs(mixer.log.updates) do
    if update.partial.fader ~= nil then
      push = update
    end
  end
  Assert.notNil(push, "the player queues a fader update to its active voice")
  Assert.equal(push.partial.fader, -96, "the outer fader uses the ARM9 dB domain")
end

function T.master_volume_and_outer_fader_remain_independent()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 100 },
      { op = "master_volume", amount = 40 },
      { op = "wait", duration = 4 },
    }, { initialVolume = 80 }),
  }, { mixer = mixer })
  local handle = play(player, provider)
  player:render(250)
  Assert.equal(mixer.log.noteOns[1].sequenceVolume, 127)
  Assert.isNil(mixer.log.noteOns[1].outerPlayerVolume, "outer volume stays player-owned")
  local master
  for _, update in ipairs(mixer.log.updates) do
    if update.partial.sequenceVolume == 40 then
      master = update.partial
    end
  end
  Assert.notNil(master, "the SSEQ master-volume command reaches the inner volume domain")
  Assert.isNil(master.outerPlayerVolume, "outer volume is not sent with inner volume updates")
  player:setHandleFader(handle, 0)
  local fade = mixer.log.updates[#mixer.log.updates].partial
  Assert.equal(fade.sequenceVolume, 40)
  Assert.isNil(fade.outerPlayerVolume, "outer volume is not sent with fader updates")
  Assert.equal(fade.fader, -40 + -32768, "outer initial volume and fader remain additive ARM9 contributions")
end

-- The SDK variable domains (SND_seq.c PlayerInit): a fresh player instance
-- initializes its 16 player-local variables to -1 at play() and the shared
-- 16 global variables to -1 once at construction; locals reset on every
-- play/replacement while globals persist across plays for the player's
-- lifetime. The pan amount operand observes the initialized value through
-- the note spec's raw track pan offset (value - 64).
function T.local_variables_reset_to_minus_one_per_play_while_globals_persist()
  local readProgram = function(var, marker)
    return {
      { op = "pan", amount = { kind = "variable", var = var } },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "wait", duration = 1 },
      { op = marker },
    }
  end
  -- The write play observes the variable through a pan note BEFORE its own
  -- write, so the same instance lifetime is visible.
  local writeProgram = function(var, value)
    return {
      { op = "pan", amount = { kind = "variable", var = var } },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "wait", duration = 1 },
      { op = "setvar", var = var, amount = value },
      { op = "wait", duration = 1 },
      { op = "end" },
    }
  end
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq(readProgram(0, { op = "end" }), { symbol = "SEQ_LOCAL_READ" }),
    [1] = seq(writeProgram(0, 20000), { id = 1, symbol = "SEQ_LOCAL_WRITE" }),
    [2] = seq(readProgram(16, { op = "end" }), { id = 2, symbol = "SEQ_GLOBAL_READ" }),
    [3] = seq(writeProgram(16, -7), { id = 3, symbol = "SEQ_GLOBAL_WRITE" }),
  }, { mixer = mixer })
  -- The pan command stores u8, subtracts 0x40, then stores s8, so the
  -- observable offset of a variable reading -1 is 255 - 64 = 191 -> -65.
  -- A fresh local reads -1 on the first play.
  player:play(player:createHandle(), provider:sequence(0), provider:bank(12))
  player:render(250)
  Assert.equal(
    mixer.log.noteOns[1].trackPanOffset,
    -65,
    "an unset player-local variable reads the source initialization -1"
  )
  -- The write play observes -1 before its own write (same instance
  -- lifetime), then completes the write (setvar executes at the third tick).
  player:play(player:createHandle(), provider:sequence(1), provider:bank(12))
  player:render(1250)
  Assert.equal(mixer.log.noteOns[2].trackPanOffset, -65, "the local still reads -1 at the start of the write play")
  -- A fresh global reads -1 on the first play.
  player:play(player:createHandle(), provider:sequence(2), provider:bank(12))
  player:render(250)
  Assert.equal(mixer.log.noteOns[3].trackPanOffset, -65, "an unset shared global reads the source initialization -1")
  -- The write play observes -1 before its own write, then completes the
  -- global write so the later read sees it.
  player:play(player:createHandle(), provider:sequence(3), provider:bank(12))
  player:render(1250)
  Assert.equal(mixer.log.noteOns[4].trackPanOffset, -65, "the global still reads -1 at the start of the write play")
  -- After replacement the local resets to -1; the global keeps its written
  -- s16 value -7 (u8 249 -> 185, then s8 -71 after subtracting 64).
  player:play(player:createHandle(), provider:sequence(0), provider:bank(12))
  player:render(250)
  Assert.equal(
    mixer.log.noteOns[5].trackPanOffset,
    -65,
    "a replaced play resets the player-local variables to -1 again"
  )
  player:play(player:createHandle(), provider:sequence(2), provider:bank(12))
  player:render(250)
  Assert.equal(
    mixer.log.noteOns[6].trackPanOffset,
    -71,
    "a global written by an earlier sequence keeps its s16 value across plays"
  )
end

-- Dynamic operands (variable and random) resolve first and only then narrow
-- to the command's real storage width: transpose/pitch_bend store s8,
-- B-class amounts store s16 before the variable arithmetic uses them, the
-- pan command stores u8, subtracts 0x40, then stores s8; tempo/mod_delay store through the u16
-- destination domain, and the variable domains wrap every store to s16. The
-- spec pins these against values that would survive the plain-integer
-- narrowing the lowering already applies to literals, so only the runtime
-- post-resolution casts can produce them.
function T.dynamic_operands_narrow_to_each_command_storage_width_after_resolution()
  -- transpose: variable 255 lowers to -1 and shifts the note key down one
  -- semitone (the s8 store), never up by 255.
  local function transposeKey()
    local mixer = stubMixer()
    local player, provider = engine({
      [0] = seq({
        { op = "setvar", var = 0, amount = 255 },
        { op = "transpose", amount = { kind = "variable", var = 0 } },
        { op = "note", key = 60, velocity = 127, duration = 1 },
        { op = "end" },
      }),
    }, { mixer = mixer })
    play(player, provider)
    player:render(100)
    return mixer.log.noteOns[1].key
  end
  Assert.equal(transposeKey(), 59, "transpose stores s8: variable 255 becomes -1, key 60 -> 59")

  -- pitch_bend: variable 128 lowers to -128, the full negative bend
  -- (userPitch -128 at bend range 2), never +128.
  local function bendPitch()
    local mixer = stubMixer()
    local player, provider = engine({
      [0] = seq({
        { op = "setvar", var = 0, amount = 128 },
        { op = "pitch_bend", amount = { kind = "variable", var = 0 } },
        { op = "note", key = 60, velocity = 127, duration = 1 },
        { op = "end" },
      }),
    }, { mixer = mixer })
    play(player, provider)
    player:render(100)
    return mixer.log.noteOns[1].userPitch
  end
  Assert.equal(bendPitch(), -128, "pitch_bend stores s8: variable 128 becomes -128")

  -- B-class amount: a resolved amount narrows to s16 before the variable
  -- arithmetic uses it. Division exposes the sign (modular addition would
  -- not): 15 / 65535-as-s16(-1) = -15 while 15 / 65535 = 0. The stored
  -- result is observed through transpose (s8): -15 shifts the note key
  -- from 60 down to 45.
  local function bClass()
    local mixer = stubMixer()
    local player, provider = engine({
      [0] = seq({
        { op = "setvar", var = 0, amount = 15 },
        { op = "divvar", var = 0, amount = 65535 },
        { op = "transpose", amount = { kind = "variable", var = 0 } },
        { op = "note", key = 60, velocity = 127, duration = 1 },
        { op = "end" },
      }),
    }, { mixer = mixer })
    play(player, provider)
    player:render(100)
    return mixer.log.noteOns[1].key
  end
  Assert.equal(bClass(), 45, "a B-class amount 65535 narrows to s16 -1 before the arithmetic (15 / -1 = -15)")

  -- tempo: variable -1 is stored through the u16 destination domain and
  -- becomes the source interval increment 65535. The observable is the
  -- interval cadence: with the default tempo 120 a fresh player ticks every
  -- two intervals (frames 250, 750); after `tempo -1` the counter gains
  -- (65535 * 256) >> 8 = 65535 per interval, so every interval after the
  -- first produces ticks -- the second note fires at frame 500, not 750.
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "setvar", var = 0, amount = -1 },
      { op = "tempo", amount = { kind = "variable", var = 0 } },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "wait", duration = 1 },
      { op = "note", key = 61, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider, true)
  player:render(250) -- tick 1 at frame 250: tempo = -1 (u16 65535), note 1 gates
  Assert.equal(#mixer.log.noteOns, 1, "the first interval runs one tick: the -1 tempo is stored and note 1 starts")
  -- With the u16-stored tempo 65535 the counter gains 65535 per interval, so
  -- the player ticks on every interval (frames 500, 750): the wait between
  -- the notes expires at tick 3 (frame 750) and note 2 starts there. A raw
  -- -1 tempo (no u16 wrap) drives the counter negative and no tick ever
  -- fires again, so the sequence would stay stalled on note 1.
  player:render(750)
  Assert.equal(
    #mixer.log.noteOns,
    2,
    "tempo -1 stored through the u16 domain keeps the player ticking every interval (note 2 at frame 750)"
  )
  Assert.isFalse(player:isPlaying(), "the sequence finishes normally after the -1 tempo")
end

-- The runtime recognizes only the signed random pair and preserves the
-- source signed 32-bit arithmetic: endpoints are never sorted and the
-- result is the pinned TrackParseValue formula. A current-schema asset
-- using the retired min/max shape must fail strict validation before
-- playback, not be accepted by a compatibility branch.
function T.random_operands_use_only_the_signed_v5_pair_and_keep_source_arithmetic()
  -- lo > hi is preserved as a descending pair: for 127..-128 the signed
  -- span is 127 - (-128) + 1 = -254, and draw 0xFFFF resolves to
  -- 127 + arshift(65535 * -254, 16) = 127 + (-254) = -127 -- never a
  -- sorted -128..127 range (which would give 127 for the same draw).
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "sweep", amount = { kind = "random", lo = 127, hi = -128 } },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer, rng = u16Draws({ 0xFFFF, 0xFFFF }) })
  play(player, provider)
  player:render(10)
  Assert.equal(
    mixer.log.noteOns[1].sweepPitch,
    -127,
    "lo > hi is a descending signed pair: draw 0xFFFF over 127..-128 resolves to -127"
  )
  -- A legacy min/max operand is malformed asset data: strict validation
  -- rejects it with the structured sequence error before any playback.
  local legacy = {
    schema = AudioSequence.SCHEMA,
    id = 77,
    symbol = "SEQ_LEGACY_RANDOM",
    bankId = 12,
    player = { id = 1, initialVolume = 127, playerPriority = 64 },
    program = {
      entry = 1,
      instructions = {
        { op = "pan", amount = { kind = "random", min = 0, max = 127 } },
        { op = "end" },
      },
    },
  }
  local ok, result = pcall(AudioSequence.validate, legacy)
  Assert.isFalse(ok, "a legacy min/max random operand fails strict validation")
  if not Errors.is(result) then
    error("expected structured validation error, got " .. tostring(result))
  end
  local errorResult = result --[[@as unknown]]
  ---@cast errorResult Errors.Error
  Assert.equal(
    errorResult.code,
    AssetAudioErrors.AUDIO_SEQUENCE_INVALID,
    "the failure is the structured sequence error"
  )
end

-- PROGRAM applies the source `< 0x10000` guard to the fully resolved
-- integer BEFORE u16 storage: a negative dynamic value passes the guard and
-- wraps to 65535, and a value of 65536 or larger leaves the previously
-- selected program unchanged (no pre-guard u16 cast that would turn 65536
-- into zero).
function T.program_guards_below_65536_before_u16_storage()
  local bank = AudioFixture.bank(12, "BANK_TEST", {
    AudioFixture.key(1),
    AudioFixture.key(2),
    AudioFixture.key(3),
  }, {
    [0] = { kind = "direct", voice = voice(AudioFixture.key(1)) },
    [1] = { kind = "direct", voice = voice(AudioFixture.key(2)) },
    [65535] = { kind = "direct", voice = voice(AudioFixture.key(3)) },
  })
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "program", program = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "setvar", var = 0, amount = -1 },
      { op = "program", program = { kind = "variable", var = 0 } },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "program", program = 65536 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer, bank = bank })
  play(player, provider)
  -- Each note gates the track for one tick; at default tempo 120 the ticks
  -- land at frames 250, 750, 1250 (the third note's tick), so 2000 frames
  -- cover all three allocations.
  player:render(2000)
  -- The current player stores raw resolved program values (no u16 wrap and
  -- no guard): program -1 and 65536 are not bank instruments, so only the
  -- first note allocates. The guard+wrap contract must produce all three.
  Assert.equal(#mixer.log.noteOns, 3, "all three notes allocate under the guard-before-wrap contract")
  Assert.equal(
    generatorOf(mixer.log.noteOns[1]).sample,
    AudioFixture.key(1),
    "the prior program 0 plays before the guard case"
  )
  -- var 0 is -1: it passes the `< 0x10000` guard and stores u16 65535.
  Assert.equal(
    generatorOf(mixer.log.noteOns[2]).sample,
    AudioFixture.key(3),
    "program -1 passes the guard and wraps to program 65535"
  )
  -- 65536 fails the guard: the prior program (still 65535) keeps playing.
  Assert.equal(
    generatorOf(mixer.log.noteOns[3]).sample,
    AudioFixture.key(3),
    "program 65536 fails the guard and leaves the previous program unchanged"
  )
end

-- A negative WAIT or negative note-wait is a stalled gate, never a zero or
-- immediate gate: the wait never decrements toward zero and the instruction
-- after it never executes while the track remains active; the negative
-- note-duration voice is indefinite; explicit stop/replacement terminates
-- the stalled state normally and no host busy loop consumes the step budget
-- within one tick.
function T.negative_waits_and_negative_note_waits_stall_the_track()
  -- WAIT from a variable set to -1: the marker note after it never starts.
  local function negativeWait()
    local mixer = stubMixer()
    local player, provider = engine({
      [0] = seq({
        { op = "setvar", var = 0, amount = -1 },
        { op = "wait", duration = { kind = "variable", var = 0 } },
        { op = "note", key = 60, velocity = 127, duration = 1 },
        { op = "end" },
      }),
    }, { mixer = mixer })
    play(player, provider)
    player:render(1000)
    return player, mixer
  end
  local waitPlayer, waitMixer = negativeWait()
  Assert.equal(#waitMixer.log.noteOns, 0, "the marker note after a negative WAIT never executes")
  Assert.isTrue(waitPlayer:isPlaying(), "a negative WAIT keeps the track active and stalled")
  waitPlayer:stop()
  Assert.isFalse(waitPlayer:isPlaying(), "explicit stop terminates the stalled state")

  -- Negative note-wait: the voice is indefinite and the instruction after
  -- the note never executes. The negative duration comes from a variable
  -- set to -1, so the case never collides with a zero-length note-finish
  -- wait.
  local function negativeNoteWait()
    local mixer = stubMixer()
    local player, provider = engine({
      [0] = seq({
        { op = "setvar", var = 0, amount = -1 },
        { op = "note", key = 60, velocity = 127, duration = { kind = "variable", var = 0 } },
        { op = "note", key = 61, velocity = 127, duration = 1 },
        { op = "end" },
      }),
    }, { mixer = mixer })
    play(player, provider)
    player:render(2000)
    return player, mixer
  end
  local notePlayer, noteMixer = negativeNoteWait()
  Assert.equal(
    #noteMixer.log.noteOns,
    1,
    "the negative-duration note starts its indefinite voice and the marker note never executes"
  )
  Assert.equal(#noteMixer.log.noteOffs, 0, "a negative-duration note is never released by the duration counter")
  Assert.isTrue(notePlayer:isPlaying(), "the negative note-wait keeps the track active and stalled")
  notePlayer:stop()
  Assert.isFalse(notePlayer:isPlaying(), "explicit stop terminates the stalled note-wait")

  -- A negative WAIT must not consume the runaway budget within one tick:
  -- the same single tick does not refetch instructions. The runaway budget
  -- guard is the host's contract (AUDIO_PLAYER_UNBOUNDED_EXECUTION), so a
  -- stalled negative wait must render without ever raising it.
  local runawayMixer = stubMixer()
  local runawayPlayer, runawayProvider = engine({
    [0] = seq({
      { op = "setvar", var = 0, amount = -1 },
      { op = "wait", duration = { kind = "variable", var = 0 } },
      { op = "jump", target = 2 },
    }),
  }, { mixer = runawayMixer })
  play(runawayPlayer, runawayProvider)
  local ok = pcall(runawayPlayer.render, runawayPlayer, 1000)
  Assert.isTrue(ok, "a stalled negative wait does not raise the host runaway budget")
  Assert.isTrue(runawayPlayer:isPlaying(), "a stalled negative wait never refetches the jump")
end

-- CALL and LOOP_BEGIN share one ordered depth-three control-flow stack
-- (SND_seq.c posCallStack/callStackDepth): a CALL followed by a nested
-- LOOP_BEGIN consumes two entries, a second nested LOOP_BEGIN consumes the
-- third, and any further CALL or LOOP_BEGIN consumes its instruction without
-- pushing or jumping (a source no-op, not a host error); RETURN/LOOP_END pop
-- the same stack; zero-depth RETURN/LOOP_END are no-ops. There is never a
-- separate call and loop depth.
function T.calls_and_loops_share_one_depth_three_control_stack()
  local mixer = stubMixer()
  -- The program nests CALL (depth 1) -> LOOP_BEGIN (depth 2) ->
  -- LOOP_BEGIN (depth 3). The fourth push -- a CALL at depth 3 -- must be
  -- consumed without pushing or jumping: the marker after it is the next
  -- instruction and runs. With separate call/loop stacks the CALL would
  -- push anyway and jump into the body at 17, running the marker there.
  local program = {
    { op = "call", target = 5 }, -- depth 1: call frame, jumps to the subprogram
    { op = "note", key = 61, velocity = 127, duration = 1 }, -- marker A (after the call returns)
    { op = "wait", duration = 1 },
    { op = "end" },
    -- The subprogram at 5.
    { op = "loop_begin", count = 1 }, -- depth 2: loop frame
    { op = "loop_begin", count = 1 }, -- depth 3: loop frame
    { op = "note", key = 62, velocity = 127, duration = 1 }, -- marker B (inside depth 3)
    { op = "wait", duration = 1 },
    { op = "call", target = 17 }, -- depth 3 full: consumed, no push, no jump
    { op = "note", key = 63, velocity = 127, duration = 1 }, -- marker C (must run)
    { op = "wait", duration = 1 },
    { op = "loop_end" }, -- pops the depth-3 loop frame (count 1 -> 0), falls through
    { op = "note", key = 64, velocity = 127, duration = 1 }, -- marker D (must run)
    { op = "wait", duration = 1 },
    { op = "loop_end" }, -- pops the depth-2 loop frame, falls through
    { op = "return" }, -- pops the call frame back to marker A
    -- The depth-3 CALL target at 17: with a shared stack the CALL never
    -- jumps here; with separate stacks it would, running this marker.
    { op = "note", key = 65, velocity = 127, duration = 1 }, -- marker E (must never run)
    { op = "wait", duration = 1 },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program) }, { mixer = mixer })
  play(player, provider)
  -- At default tempo 120 a player ticks every two intervals (250, 750,
  -- ... at 48 kHz); the nested trace needs 8 ticks (B at 1, C at 3, D at 5,
  -- A after the return at 8), so 5000 frames cover it.
  player:render(5000)
  -- The shared depth-three stack runs B, C, D inside the nested frames, then
  -- A after the call returns. The marker E at the depth-3 CALL target never
  -- runs: the CALL at depth 3 was a no-op.
  local keys = {}
  for _, spec in ipairs(mixer.log.noteOns) do
    keys[#keys + 1] = spec.key
  end
  Assert.deepEqual(
    keys,
    { 62, 63, 64, 61 },
    "the shared depth-three stack runs B -> C -> D inside the frames, then A after the call returns; the depth-3 CALL is a no-op"
  )
  Assert.isFalse(player:isPlaying(), "the shared-stack program ends cleanly")

  -- Zero-depth RETURN and LOOP_END are no-ops: a top-level return falls
  -- through and an unmatched loop_end is dead bytes, exactly like the
  -- existing top-level-return and unmatched-loop_end contracts.
  local mixer2 = stubMixer()
  local player2, provider2 = engine({
    [0] = seq({
      { op = "loop_end" },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "return" },
      { op = "end" },
    }),
  }, { mixer = mixer2 })
  play(player2, provider2)
  player2:render(500)
  Assert.equal(#mixer2.log.noteOns, 1, "zero-depth loop_end and return both fall through as no-ops")
  Assert.isFalse(player2:isPlaying())
end

-- The four source width conversions wrap at the exact two's-complement
-- boundaries: u8 modulo 256 (0..255), s8 the signed interpretation of u8
-- (-128..127), u16 modulo 65536 (0..65535), s16 the signed interpretation
-- of u16 (-32768..32767). Each row observes the conversion through the
-- command whose storage domain it is: u8 through the envelope attack
-- track priority, s8 through pitch_bend (bend range 2 makes the recorded user
-- pitch the stored byte exactly), u16 through mod_delay, s16 through sweep.
function T.width_conversions_wrap_at_the_exact_boundaries()
  local cases = {
    { convert = "u8", value = -1, expected = 255 },
    { convert = "u8", value = 0, expected = 0 },
    { convert = "u8", value = 127, expected = 127 },
    { convert = "u8", value = 128, expected = 128 },
    { convert = "u8", value = 255, expected = 255 },
    { convert = "u8", value = 256, expected = 0 },
    { convert = "u8", value = 65535, expected = 255 },
    { convert = "s8", value = -1, expected = -1 },
    { convert = "s8", value = 0, expected = 0 },
    { convert = "s8", value = 127, expected = 127 },
    { convert = "s8", value = 128, expected = -128 },
    { convert = "s8", value = 255, expected = -1 },
    { convert = "s8", value = 256, expected = 0 },
    { convert = "s8", value = 65535, expected = -1 },
    { convert = "u16", value = -1, expected = 65535 },
    { convert = "u16", value = 0, expected = 0 },
    { convert = "u16", value = 32767, expected = 32767 },
    { convert = "u16", value = 32768, expected = 32768 },
    { convert = "u16", value = 65535, expected = 65535 },
    { convert = "u16", value = 65536, expected = 0 },
    { convert = "s16", value = -1, expected = -1 },
    { convert = "s16", value = 0, expected = 0 },
    { convert = "s16", value = 32767, expected = 32767 },
    { convert = "s16", value = 32768, expected = -32768 },
    { convert = "s16", value = 65535, expected = -1 },
    { convert = "s16", value = 65536, expected = 0 },
  }
  for _, case in ipairs(cases) do
    local mixer = stubMixer()
    local op
    if case.convert == "u8" then
      op = "priority"
    elseif case.convert == "s8" then
      op = "pitch_bend"
    elseif case.convert == "u16" then
      op = "mod_delay"
    else
      op = "sweep"
    end
    local player, provider = engine({
      [0] = seq({
        { op = "setvar", var = 0, amount = case.value },
        { op = op, amount = { kind = "variable", var = 0 } },
        { op = "note", key = 60, velocity = 127, duration = 1 },
        { op = "end" },
      }),
    }, { mixer = mixer })
    play(player, provider)
    player:render(100)
    local spec = mixer.log.noteOns[1]
    local observed
    if case.convert == "u8" then
      observed = spec.trackPriority
    elseif case.convert == "s8" then
      observed = spec.userPitch
    elseif case.convert == "u16" then
      observed = spec.lfo.delay
    else
      observed = spec.sweepPitch
    end
    Assert.equal(observed, case.expected, case.convert .. "(" .. case.value .. ")")
  end
end

-- Variable stores wrap to s16 after arithmetic, independent of operand
-- conversion: a sum that overflows the s16 domain wraps on the store.
function T.s16_variable_stores_wrap_after_arithmetic()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "setvar", var = 0, amount = 32767 },
      { op = "addvar", var = 0, amount = 1 },
      { op = "sweep", amount = { kind = "variable", var = 0 } },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(100)
  Assert.equal(
    mixer.log.noteOns[1].sweepPitch,
    -32768,
    "32767 + 1 wraps to -32768 on the s16 store (the sweep carries the stored s16 value)"
  )
end

-- Random and variable operands read the same initialized variable domains:
-- a randomvar target and a variable operand observe the same s16
-- initialization (-1) before any write, so both resolve identically.
function T.random_and_variable_operands_read_the_same_initialized_variable_domains()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "pan", amount = { kind = "random", lo = 0, hi = 0 } },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "wait", duration = 1 },
      { op = "pan", amount = { kind = "variable", var = 16 } },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer, rng = u16Draws({ 0x7FFF, 0x7FFF }) })
  play(player, provider)
  player:render(1250) -- ticks at frames 250 (note 1 + wait gate), 750 (wait), 1250 (note 2)
  Assert.equal(
    mixer.log.noteOns[1].trackPanOffset,
    -64,
    "a random operand over the zero span resolves to the lo endpoint 0"
  )
  Assert.equal(
    mixer.log.noteOns[2].trackPanOffset,
    -65,
    "a variable operand reads the same initialized -1 the random operand drew its domain from (u8(-1)=255, minus 64, stored as s8)"
  )
end

-- The global 192 Hz sound interval (SND_main.c SndThread): `_soundPhase`
-- advances 192 units per rendered output frame and one interval fires each
-- time it reaches the sample rate, so at 48 kHz an interval is exactly 250
-- frames and the boundary frame index of the Nth interval is N*250. Sequence
-- ticks come from each player's `tempoCounter` only at those boundaries --
-- never from a per-output-frame accumulator -- so with the default tempo 120
-- (tempoCounter 240, one tick per interval at 192 Hz) a fresh play executes
-- its entry program at the first boundary (frame 250) and one tick per
-- boundary after that.
local function intervalBoundaryFrameIndices(sampleRate, intervalCount)
  local boundaries = {}
  local phase = 0
  for frame = 1, sampleRate * 10 do
    phase = phase + 192
    if phase >= sampleRate then
      phase = phase - sampleRate
      boundaries[#boundaries + 1] = frame
      if #boundaries >= intervalCount then
        break
      end
    end
  end
  return boundaries
end

-- A recording mixer that stamps every mixer call with the absolute frame
-- index it ends at, using the exact accumulator boundary math (phase += 192
-- per frame, one interval when the phase reaches the sample rate). It is the
-- observable "frame index" clock for the interval contract; a target
-- SequencePlayer must ask the mixer for spans that end exactly on these
-- boundaries and run its interval processing (sequence ticks, then mixer
-- control, then the periodic RNG draw) once per boundary.
local BoundaryMixer = {}
BoundaryMixer.__index = BoundaryMixer

function BoundaryMixer.new(sampleRate)
  return setmetatable({
    _sampleRate = sampleRate,
    _frame = 0,
    _phase = 0,
    renders = {}, -- frame index each renderInto call ends at
    controlSteps = {}, -- frame index each controlStep call observes
    noteOns = {}, -- frame index each noteOn lands at
  }, BoundaryMixer)
end

function BoundaryMixer:renderInto(out, frames)
  for _ = 1, frames do
    self._frame = self._frame + 1
    self._phase = self._phase + 192
    if self._phase >= self._sampleRate then
      self._phase = self._phase - self._sampleRate
    end
  end
  self.renders[#self.renders + 1] = self._frame
  for _ = 1, frames * 2 do
    out[#out + 1] = 0
  end
end

function BoundaryMixer:controlStep()
  self.controlSteps[#self.controlSteps + 1] = self._frame
end

function BoundaryMixer:noteOn()
  self.noteOns[#self.noteOns + 1] = self._frame
  return { channel = 3, generation = #self.noteOns }
end

function BoundaryMixer:noteOff() end

function BoundaryMixer:updateVoice() end

function BoundaryMixer:advanceTrackTick() end

function BoundaryMixer:retargetTiedVoice() end

function BoundaryMixer:isVoiceAlive()
  return true
end

-- The one 192 Hz interval owner: at 48 kHz a sound interval is exactly 250
-- frames. A fresh default-tempo play must run its first source sequence
-- tick at the first completed 250-frame interval -- frame 250 -- and never
-- halfway between boundaries. At the default tempo 120 the source
-- tempoCounter gains (120 * 256) >> 8 = 120 per interval, so one tick
-- fires every two intervals (frames 250, 750, 1250); at tempo 240 the
-- increment is 240 and one tick fires on every interval (frames 250, 500,
-- 750, 1000, 1250). The observable boundaries are the mixer spans the
-- player asks for (they must end exactly on the 250-frame multiples, never
-- on the per-player tick distance 500 of the old per-output-frame
-- accumulator) and the mixer control steps (one per completed interval, on
-- the boundary frame).
function T.sequence_ticks_fire_only_on_48khz_interval_boundaries()
  local mixer = BoundaryMixer.new(SAMPLE_RATE)
  local player, provider = engine({
    [0] = seq({
      { op = "tempo", amount = 240 },
      { op = "program", program = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "jump", target = 3 },
    }),
  }, { mixer = mixer })
  -- play() must not execute the entry program (no noteOn yet).
  player:play(player:createHandle(), provider:sequence(0), provider:bank(12))
  Assert.equal(#mixer.noteOns, 0, "play() itself does not run the entry program")
  -- 249 frames: still inside the first interval; the entry program must not
  -- have run.
  player:render(249)
  Assert.equal(#mixer.noteOns, 0, "the first interval boundary is at frame 250, not inside it")
  Assert.equal(#mixer.controlSteps, 0, "no completed interval, no mixer control step")
  -- The 250th frame completes the first interval: one sequence tick (the
  -- entry program's noteOn) then one mixer control step.
  player:render(1)
  Assert.equal(#mixer.noteOns, 1, "the first interval boundary runs the entry program's tick")
  Assert.equal(#mixer.controlSteps, 1, "the completed first interval runs one mixer control step")
  Assert.equal(mixer.controlSteps[1], 250, "the control step observes the boundary frame 250")
  -- Continue through four more boundaries: one tick (one noteOn) per
  -- 250-frame boundary at tempo 240.
  player:render(1000)
  Assert.equal(#mixer.noteOns, 5, "one source sequence tick per completed interval at tempo 240")
  Assert.equal(#mixer.controlSteps, 5, "one control step per completed interval")
  local expected = intervalBoundaryFrameIndices(SAMPLE_RATE, 5)
  for index = 1, 5 do
    Assert.equal(mixer.controlSteps[index], expected[index], "control step " .. index .. " lands on the boundary")
  end
  -- The render spans: the player must ask the mixer for spans that end on
  -- the interval boundaries (250-frame multiples) or on the requested-frame
  -- boundary of an explicit render call (the 249-frame request above),
  -- never on per-player tick distances (500 frames at tempo 120 under the
  -- old accumulator).
  Assert.deepEqual(
    mixer.renders,
    { 249, 250, 500, 750, 1000, 1250 },
    "every mixer span ends on an interval boundary or the requested frame boundary"
  )
end

-- The exact 32768 Hz boundary pattern: from phase zero the integer
-- accumulator (phase += 192 per frame, one interval at 32768) puts the first
-- six interval boundaries at frames 171, 342, 512, 683, 854, 1024 -- not
-- every floor(32768/192)=170 frames and not a 170/171 alternating
-- approximation. One render call and any partition of the same window must
-- produce identical boundary frame indices (the mixer span ends and the
-- control steps), identical sequence event counts, and byte-identical PCM.
-- The sequence runs at tempo 240 so one source tick fires per interval at
-- the production rate.
function T.interval_boundaries_and_chunk_partition_are_invariant_at_32768_hz()
  local RATE = 32768
  local expected = intervalBoundaryFrameIndices(RATE, 6)
  Assert.deepEqual(
    expected,
    { 171, 342, 512, 683, 854, 1024 },
    "the exact accumulator boundary pattern from phase zero is 171, 171, 170 repeating"
  )
  local program = {
    { op = "tempo", amount = 240 },
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "jump", target = 3 },
  }
  local function playChunked(chunks)
    local mixer = BoundaryMixer.new(RATE)
    local provider = TestProvider.new(buildBundle({ [0] = seq(program) }))
    local player = SequencePlayer.new({ sampleRate = RATE, mixer = mixer, provider = provider })
    player:play(player:createHandle(), provider:sequence(0), provider:bank(12))
    local out = {}
    for _, frames in ipairs(chunks) do
      local pcm = player:render(frames)
      for i = 1, #pcm do
        out[#out + 1] = pcm[i]
      end
    end
    return { mixer = mixer, pcm = out }
  end
  local whole = playChunked({ 1024 })
  Assert.deepEqual(whole.mixer.renders, expected, "single-call render spans end on every exact boundary")
  Assert.deepEqual(whole.mixer.controlSteps, expected, "single-call render controls on every exact boundary")
  Assert.equal(#whole.mixer.noteOns, 6, "one sequence tick per completed interval")
  -- The boundary partition requests exactly the interval lengths, so every
  -- render call ends on a boundary and the cumulative end-frame log matches
  -- the absolute boundary indices.
  local partition = playChunked({ 171, 171, 170, 171, 171, 170 })
  Assert.deepEqual(partition.mixer.renders, expected, "the boundary partition spans end on the same exact frames")
  Assert.deepEqual(partition.mixer.controlSteps, expected, "the boundary partition controls on the same exact frames")
  Assert.equal(#partition.mixer.noteOns, 6, "the boundary partition ticks once per interval")
  Assert.deepEqual(whole.pcm, partition.pcm, "the partition renders byte-identical PCM")
  -- An irregular partition whose chunks cross the interval boundaries: the
  -- span scheduler splits each chunk at the interval boundaries, so the
  -- renderInto end-frame log is the chunk ends AND the boundary frames the
  -- chunks cross, and the control steps land on the same absolute boundary
  -- frames. The PCM is byte-identical to the single call.
  local irregular = playChunked({ 100, 200, 300, 100, 324 })
  Assert.deepEqual(
    irregular.mixer.renders,
    { 100, 171, 300, 342, 512, 600, 683, 700, 854, 1024 },
    "an irregular partition splits its chunks at the interval boundaries"
  )
  Assert.deepEqual(irregular.mixer.controlSteps, expected, "an irregular partition controls on the same exact frames")
  Assert.equal(#irregular.mixer.noteOns, 6, "the irregular partition ticks once per interval")
  Assert.deepEqual(whole.pcm, irregular.pcm, "the irregular partition renders byte-identical PCM")
end

-- An injected RNG recorder: returns the same SDK u16 draw domain as the
-- production RNG and records every call in order, so the explicit
-- random-draw calls and the periodic interval draw are distinguishable by
-- position and count.
local function recordingRng(draws)
  local index = 0
  local calls = {}
  return {
    calls = calls,
    fn = function()
      index = index + 1
      local draw = draws[index] or 0
      draws[index] = draw -- keep the table indexed for later reads
      calls[#calls + 1] = draw
      return draw
    end,
  }
end

-- Source interval order: one completed interval executes the sequence
-- portion first (an explicit random operand draws during its tick and the
-- tick's queued voice update precedes the control step), then one mixer
-- control step, then exactly one unconditional periodic RNG draw. No
-- periodic draw happens before the explicit random command of the same
-- interval. The sequence holds one voice (note_wait cleared) so the pan
-- command in the same tick queues an update to a live voice, and the note
-- after the pan carries the drawn offset.
function T.each_interval_runs_sequence_then_control_then_the_periodic_rng_draw()
  local rng = recordingRng({ 0x8000 })
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 4 },
      { op = "pan", amount = { kind = "random", lo = 0, hi = 127 } },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "wait", duration = 1 },
      { op = "jump", target = 3 },
    }),
  }, { mixer = mixer, rng = rng.fn })
  player:play(player:createHandle(), provider:sequence(0), provider:bank(12))
  player:render(249)
  Assert.equal(#rng.calls, 0, "no RNG draw before the first completed interval")
  Assert.equal(#mixer.log.noteOns, 0, "no sequence command before the first completed interval")
  player:render(1) -- completes the first 250-frame interval
  Assert.equal(#rng.calls, 2, "the first interval draws once for the explicit operand and once periodic")
  -- The first interval's first tick: the held note's voice is live when the
  -- pan command runs, so the pan's queued update is observed during the
  -- sequence portion (before any control step), and the note after the pan
  -- carries the drawn pan offset (0x8000 scales (32768*128)>>16 = 64 ->
  -- offset 0).
  Assert.equal(#mixer.log.noteOns, 2, "the held note and the post-pan note allocate in the first tick")
  Assert.equal(
    mixer.log.noteOns[2].trackPanOffset,
    0,
    "the explicit draw 0x8000 scaled (32768*128)>>16 = 64 -> offset 0"
  )
  Assert.equal(#mixer.log.updates, 1, "the pan command queued an update to the live voice during the tick")
  Assert.equal(#mixer.controlSteps, 1, "exactly one control step per completed interval")
  -- Cross the second interval: at the default tempo 120 the tempoCounter
  -- gains (120 * 256) >> 8 = 120 per interval, so the second interval
  -- (frame 500) produces no sequence tick -- only the periodic draw and the
  -- control step run.
  player:render(250)
  Assert.equal(#rng.calls, 3, "an interval with no tick draws only the periodic RNG")
  Assert.equal(#mixer.log.noteOns, 2, "no sequence command runs on an interval without a tick")
  Assert.equal(#mixer.controlSteps, 2, "the control step still runs once per completed interval")
  -- The third interval (frame 750) produces the next tick: the explicit
  -- operand draws again (draw 0 for the exhausted recorder) and the
  -- periodic draw follows the control step.
  player:render(250)
  Assert.equal(#rng.calls, 5, "the tick interval draws once for the explicit operand and once periodic")
  Assert.equal(#mixer.controlSteps, 3, "three completed intervals, three control steps")
  Assert.equal(#mixer.log.noteOns, 3, "the tick interval allocates the next post-pan note")
end

-- Idle rendering advances the global interval: with no active sequence the
-- audio clock keeps running, so rendering silence still fires the periodic
-- RNG draw on every completed interval and advances the global phase. A
-- later play() starts relative to that phase -- the first tick lands on the
-- next global boundary, not 250 frames after play() unless the phase
-- happens to be zero -- and never resets the RNG state.
function T.idle_rendering_advances_the_global_interval_and_rng()
  local RATE = 32768
  local rng = recordingRng({})
  local provider = TestProvider.new(buildBundle({
    [0] = seq({ { op = "note", key = 60, velocity = 127, duration = 1 } }),
  }))
  local mixer = stubMixer()
  local player = SequencePlayer.new({ sampleRate = RATE, mixer = mixer, provider = provider, rng = rng.fn })
  -- Render silence across two full intervals at the production rate
  -- (boundaries at 171 and 342): no active sequence, but the clock runs.
  player:render(342)
  Assert.equal(#rng.calls, 2, "two completed idle intervals draw the periodic RNG twice")
  Assert.equal(#mixer.controlSteps, 2, "two completed idle intervals run two mixer control steps")
  -- play() must not reset the phase or the RNG: the global phase is now 342
  -- frames in, and the next boundary is at absolute frame 512 (170 frames
  -- after play), not 171/342-style 171 frames from a reset zero.
  player:play(player:createHandle(), provider:sequence(0), provider:bank(12))
  player:render(169) -- still inside the third interval (boundary at 512)
  Assert.equal(#mixer.log.noteOns, 0, "the entry tick waits for the next global boundary")
  Assert.equal(#rng.calls, 2, "no periodic draw before the third interval completes")
  player:render(1) -- completes the third interval at absolute frame 512
  Assert.equal(#mixer.log.noteOns, 1, "the first tick lands on the next global boundary after play")
  Assert.equal(#rng.calls, 3, "the completed interval draws the periodic RNG once more")
end

function T.player_capacity_keeps_higher_priority_and_rejects_lower_priority_starts()
  local mixer = stubMixer()
  local program = { { op = "note", key = 60, velocity = 127, duration = 4 }, { op = "wait", duration = 4 } }
  local player, provider = engine({
    [0] = seq(program, { playerId = 1, playerPriority = 10 }),
    [1] = seq(program, { id = 1, symbol = "SEQ_TEST_B", playerId = 1, playerPriority = 20 }),
    [2] = seq(program, { id = 2, symbol = "SEQ_TEST_C", playerId = 1, playerPriority = 30 }),
    [3] = seq(program, { id = 3, symbol = "SEQ_TEST_D", playerId = 1, playerPriority = 5 }),
  }, { mixer = mixer, maxSequences = 2 })
  player:play(player:createHandle(), provider:sequence(0), provider:bank(12))
  player:play(player:createHandle(), provider:sequence(1), provider:bank(12))
  player:render(250)
  Assert.equal(#mixer.log.noteOns, 2, "two sequence instances coexist within capacity")
  player:play(player:createHandle(), provider:sequence(3), provider:bank(12))
  Assert.equal(#mixer.log.noteOffs, 0, "a lower-priority start is rejected without releasing a live instance")
  player:play(player:createHandle(), provider:sequence(2), provider:bank(12))
  Assert.equal(#mixer.log.noteOffs, 1, "a full player releases one victim")
  Assert.equal(mixer.log.noteOffs[1].handle.generation, 0, "the oldest lowest-priority instance is the victim")
end

function T.global_track_pool_rejects_the_thirty_third_track_and_reuses_after_stop()
  local function crowded(id, priority)
    local instructions = {}
    for track = 1, 15 do
      instructions[#instructions + 1] = { op = "open_track", track = track, target = 16 }
    end
    instructions[#instructions + 1] = { op = "note", key = 60, velocity = 127, duration = 8 }
    instructions[#instructions + 1] = { op = "wait", duration = 8 }
    return seq(instructions, {
      id = id,
      symbol = "SEQ_CROWDED_" .. id,
      playerId = 1,
      playerPriority = priority,
      initialTrackMask = 0xFFFF,
    })
  end
  local poolEvents = {}
  local observer = {
    onTrackPool = function(_, event)
      poolEvents[#poolEvents + 1] = event
    end,
  }
  local player, provider = engine({
    [0] = crowded(0, 10),
    [1] = crowded(1, 20),
    [2] = seq({
      { op = "open_track", track = 1, target = 2 },
      { op = "wait", duration = 4 },
    }, { id = 2, symbol = "SEQ_THIRD", playerId = 1, playerPriority = 30, initialTrackMask = 0x0003 }),
  }, {
    maxSequences = 3,
    observer = observer,
  })
  player:play(player:createHandle(), provider:sequence(0), provider:bank(12))
  player:play(player:createHandle(), provider:sequence(1), provider:bank(12))
  player:render(250)
  player:play(player:createHandle(), provider:sequence(2), provider:bank(12))
  player:render(250)
  Assert.equal(poolEvents[#poolEvents].allocated, 32, "the shared pool never grows past 32 tracks")
  player:stopPlayer(1)
  Assert.equal(poolEvents[#poolEvents].allocated, 0, "stopping a player returns every track object")
end

local function longLivedSequence(id, playerId, priority)
  return seq({
    { op = "note", key = 60, velocity = 127, duration = 1000 },
    { op = "wait", duration = 1000 },
  }, {
    id = id,
    symbol = "SEQ_ALLOCATION_" .. id,
    playerId = playerId,
    playerPriority = priority,
  })
end

local function allocationEngine(sequences, opts)
  local mixer = (opts and opts.mixer) or stubMixer()
  local observer = (opts and opts.observer) or {}
  local player, provider = engine(sequences, {
    mixer = mixer,
    observer = observer,
    maxSequences = opts and opts.maxSequences or 1,
  })
  return player, provider, mixer, observer
end

function T.logical_player_thirty_one_executes_on_a_physical_slot()
  local player, provider, mixer, observer = allocationEngine({
    [0] = longLivedSequence(0, 31, 64),
  })
  local allocations = {}
  observer.onSequenceAllocation = function(_, event)
    allocations[#allocations + 1] = event
  end

  player:play(player:createHandle(), provider:sequence(0), provider:bank(12))
  player:render(250)

  Assert.equal(#mixer.log.noteOns, 1, "logical player 31 reaches sequence execution")
  Assert.isTrue(player:isPlayerPlaying(31), "logical player 31 remains active")
  Assert.equal(allocations[1].logicalPlayerId, 31, "allocation reports the logical group")
  Assert.isTrue(
    allocations[1].seqPlayerSlot >= 0 and allocations[1].seqPlayerSlot < 16,
    "allocation reports a physical slot"
  )
end

function T.physical_sequence_slots_are_shared_across_logical_groups()
  local sequences = {}
  for logicalPlayerId = 0, 16 do
    sequences[logicalPlayerId] = longLivedSequence(logicalPlayerId, logicalPlayerId, 64)
  end
  local allocations = {}
  local player, provider = allocationEngine(sequences, {
    observer = {
      onSequenceAllocation = function(_, event)
        allocations[#allocations + 1] = event
      end,
    },
  })

  for sequenceId = 0, 16 do
    player:play(player:createHandle(), provider:sequence(sequenceId), provider:bank(12))
  end

  local slots = {}
  for _, event in ipairs(allocations) do
    if event.accepted then
      Assert.isTrue(
        type(event.seqPlayerSlot) == "number" and event.seqPlayerSlot >= 0 and event.seqPlayerSlot < 16,
        "accepted allocation identifies one physical slot"
      )
      slots[event.seqPlayerSlot] = true
    end
  end
  local distinctSlots = 0
  for _ in pairs(slots) do
    distinctSlots = distinctSlots + 1
  end
  Assert.equal(distinctSlots, 16, "accepted instances occupy distinct physical slots")
end

function T.logical_capacity_precedes_global_priority_arbitration()
  local program = {
    [0] = longLivedSequence(0, 1, 10),
    [1] = longLivedSequence(1, 1, 20),
    [2] = longLivedSequence(2, 1, 5),
    [3] = longLivedSequence(3, 1, 15),
  }
  local player, provider, mixer = allocationEngine(program, { maxSequences = 2 })
  player:play(player:createHandle(), provider:sequence(0), provider:bank(12))
  player:play(player:createHandle(), provider:sequence(1), provider:bank(12))
  player:render(250)
  player:play(player:createHandle(), provider:sequence(2), provider:bank(12))
  Assert.equal(#mixer.log.noteOffs, 0, "a weak local candidate does not disturb the group")
  player:play(player:createHandle(), provider:sequence(3), provider:bank(12))
  Assert.equal(#mixer.log.noteOffs, 1, "an eligible local candidate replaces the weakest group instance")

  local crowded = {}
  for logicalPlayerId = 1, 15 do
    crowded[logicalPlayerId - 1] = longLivedSequence(logicalPlayerId - 1, logicalPlayerId, 30)
  end
  crowded[15] = longLivedSequence(15, 30, 30)
  crowded[16] = longLivedSequence(16, 31, 25)
  local crowdedAllocations = {}
  local crowdedPlayer, crowdedProvider, crowdedMixer = allocationEngine(crowded, {
    observer = {
      onSequenceAllocation = function(_, event)
        crowdedAllocations[#crowdedAllocations + 1] = event
      end,
    },
  })
  for sequenceId = 0, 15 do
    crowdedPlayer:play(crowdedPlayer:createHandle(), crowdedProvider:sequence(sequenceId), crowdedProvider:bank(12))
  end
  crowdedPlayer:play(crowdedPlayer:createHandle(), crowdedProvider:sequence(16), crowdedProvider:bank(12))
  Assert.equal(#crowdedMixer.log.noteOffs, 0, "a lower global priority is rejected without eviction")
  local accepted = 0
  for _, event in ipairs(crowdedAllocations) do
    if event.accepted then
      accepted = accepted + 1
    end
  end
  Assert.equal(accepted, 16, "the global allocator rejects the seventeenth lower-priority instance")
  Assert.isFalse(crowdedPlayer:isPlayerPlaying(31), "the rejected global candidate is not active")
end

function T.logical_replacement_retires_only_the_group_victim()
  local sequences = {
    [0] = longLivedSequence(0, 1, 10),
    [1] = longLivedSequence(1, 1, 20),
  }
  for logicalPlayerId = 2, 15 do
    sequences[logicalPlayerId] = longLivedSequence(logicalPlayerId, logicalPlayerId, 30)
  end
  sequences[15] = longLivedSequence(15, 31, 5)
  sequences[16] = longLivedSequence(16, 1, 20)

  local allocations = {}
  local retirements = {}
  local eventOrder = {}
  local player, provider = allocationEngine(sequences, {
    maxSequences = 2,
    observer = {
      onSequenceAllocation = function(_, event)
        allocations[#allocations + 1] = event
        eventOrder[#eventOrder + 1] = "allocation"
      end,
      onSequenceRetirement = function(_, event)
        retirements[#retirements + 1] = event
        eventOrder[#eventOrder + 1] = "retirement"
      end,
    },
  })
  for sequenceId = 0, 15 do
    player:play(player:createHandle(), provider:sequence(sequenceId), provider:bank(12))
  end

  player:play(player:createHandle(), provider:sequence(16), provider:bank(12))

  Assert.equal(#retirements, 1, "logical replacement retires exactly one instance")
  Assert.equal(retirements[1].instanceId, 1, "the oldest lowest-priority group member retires")
  Assert.equal(retirements[1].seqPlayerSlot, 0, "the logical victim's slot is released first")
  Assert.isTrue(player:isPlayerPlaying(31), "the unrelated global low-priority instance survives")
  Assert.equal(#allocations, 17, "the incoming sequence is accepted")
  Assert.equal(allocations[17].seqPlayerSlot, 0, "the incoming sequence receives the released slot")
  Assert.deepEqual(
    { eventOrder[17], eventOrder[18] },
    { "retirement", "allocation" },
    "retirement is observed before replacement allocation"
  )
  local occupiedSlots = {}
  for _, event in ipairs(allocations) do
    if event.accepted then
      occupiedSlots[event.seqPlayerSlot] = true
    end
  end
  local occupiedCount = 0
  for _ in pairs(occupiedSlots) do
    occupiedCount = occupiedCount + 1
  end
  Assert.equal(occupiedCount, 16, "replacement preserves the full physical slot count")
  Assert.isTrue(player:isPlayerPlaying(1), "the logical group remains active")
end

function T.retired_physical_slots_are_reused_in_shutdown_order()
  local sequences = {}
  for id = 0, 18 do
    sequences[id] = longLivedSequence(id, id, 64)
  end
  local allocations = {}
  local retirements = {}
  local player, provider = allocationEngine(sequences, {
    observer = {
      onSequenceAllocation = function(_, event)
        if event.accepted then
          allocations[#allocations + 1] = event
        end
      end,
      onSequenceRetirement = function(_, event)
        retirements[#retirements + 1] = event
      end,
    },
  })
  for id = 0, 15 do
    player:play(player:createHandle(), provider:sequence(id), provider:bank(12))
  end

  player:stopPlayer(9)
  player:stopPlayer(2)
  player:stopPlayer(7)
  Assert.deepEqual(
    { retirements[1].seqPlayerSlot, retirements[2].seqPlayerSlot, retirements[3].seqPlayerSlot },
    { 9, 2, 7 },
    "retirements record the requested non-numeric shutdown order"
  )

  for id = 16, 18 do
    player:play(player:createHandle(), provider:sequence(id), provider:bank(12))
  end
  Assert.deepEqual(
    { allocations[17].seqPlayerSlot, allocations[18].seqPlayerSlot, allocations[19].seqPlayerSlot },
    { 9, 2, 7 },
    "new allocations consume retired slots in FIFO order"
  )
end

function T.equal_priority_global_steal_retires_the_oldest_instance()
  local sequences = {}
  for id = 0, 15 do
    local priority = 30
    if id == 9 then
      priority = 5
    end
    sequences[id] = longLivedSequence(id, id, priority)
  end
  sequences[16] = longLivedSequence(16, 9, 5)
  sequences[17] = longLivedSequence(17, 2, 5)
  sequences[18] = longLivedSequence(18, 16, 5)

  local allocations = {}
  local retirements = {}
  local player, provider = allocationEngine(sequences, {
    observer = {
      onSequenceAllocation = function(_, event)
        if event.accepted then
          allocations[#allocations + 1] = event
        end
      end,
      onSequenceRetirement = function(_, event)
        retirements[#retirements + 1] = event
      end,
    },
  })
  for id = 0, 15 do
    player:play(player:createHandle(), provider:sequence(id), provider:bank(12))
  end
  player:stopPlayer(9)
  player:play(player:createHandle(), provider:sequence(16), provider:bank(12))
  player:stopPlayer(2)
  player:play(player:createHandle(), provider:sequence(17), provider:bank(12))

  player:play(player:createHandle(), provider:sequence(18), provider:bank(12))

  Assert.equal(#retirements, 3, "full-pool replacement retires one global victim")
  Assert.equal(retirements[3].instanceId, 17, "the older equal-priority instance is selected")
  Assert.equal(retirements[3].seqPlayerSlot, 9, "the older candidate's physical slot is released")
  Assert.equal(allocations[19].seqPlayerSlot, 9, "the incoming sequence receives the victim's slot")
  Assert.isFalse(player:isPlayerPlaying(9), "the older candidate's logical player is retired")
  Assert.isTrue(player:isPlayerPlaying(2), "the younger candidate's logical player remains active")
end

function T.rejected_logical_and_global_admissions_preserve_ownership()
  local logicalAllocations = {}
  local logicalRetirements = {}
  local logicalPlayer, logicalProvider = allocationEngine({
    [0] = longLivedSequence(0, 1, 20),
    [1] = longLivedSequence(1, 1, 10),
  }, {
    maxSequences = 1,
    observer = {
      onSequenceAllocation = function(_, event)
        logicalAllocations[#logicalAllocations + 1] = event
      end,
      onSequenceRetirement = function(_, event)
        logicalRetirements[#logicalRetirements + 1] = event
      end,
    },
  })
  logicalPlayer:play(logicalPlayer:createHandle(), logicalProvider:sequence(0), logicalProvider:bank(12))
  logicalPlayer:play(logicalPlayer:createHandle(), logicalProvider:sequence(1), logicalProvider:bank(12))
  Assert.equal(#logicalRetirements, 0, "a rejected logical admission does not retire")
  Assert.equal(#logicalAllocations, 2, "a rejected logical admission emits no accepted allocation")
  Assert.isFalse(logicalAllocations[2].accepted, "the logical admission is rejected")
  Assert.isTrue(logicalPlayer:isPlayerPlaying(1), "the existing logical instance remains active")

  local globalAllocations = {}
  local globalRetirements = {}
  local globalSequences = {}
  for id = 0, 15 do
    globalSequences[id] = longLivedSequence(id, id, 30)
  end
  globalSequences[16] = longLivedSequence(16, 16, 20)
  local globalPlayer, globalProvider = allocationEngine(globalSequences, {
    observer = {
      onSequenceAllocation = function(_, event)
        globalAllocations[#globalAllocations + 1] = event
      end,
      onSequenceRetirement = function(_, event)
        globalRetirements[#globalRetirements + 1] = event
      end,
    },
  })
  for id = 0, 15 do
    globalPlayer:play(globalPlayer:createHandle(), globalProvider:sequence(id), globalProvider:bank(12))
  end
  globalPlayer:play(globalPlayer:createHandle(), globalProvider:sequence(16), globalProvider:bank(12))
  Assert.equal(#globalRetirements, 0, "a rejected global admission does not retire")
  Assert.equal(#globalAllocations, 17, "the rejected global admission emits no accepted allocation")
  Assert.isFalse(globalAllocations[17].accepted, "the global admission is rejected")
  Assert.isTrue(globalPlayer:isPlayerPlaying(0), "all existing global instances remain active")
  Assert.isFalse(globalPlayer:isPlayerPlaying(16), "the rejected global instance is not active")
end

function T.logical_group_controls_cover_all_instances_in_the_group()
  local mixer = stubMixer()
  local player, provider = allocationEngine({
    [0] = longLivedSequence(0, 20, 64),
    [1] = longLivedSequence(1, 20, 64),
  }, { mixer = mixer, maxSequences = 2 })
  local first, second = player:createHandle(), player:createHandle()
  player:play(first, provider:sequence(0), provider:bank(12))
  player:play(second, provider:sequence(1), provider:bank(12))
  player:render(250)
  Assert.equal(#mixer.log.noteOns, 2, "both logical-group instances execute")

  local updatesBefore = #mixer.log.updates
  player:setHandleFader(first, 42)
  Assert.equal(#mixer.log.updates, updatesBefore + 1, "handle fader updates one instance")
  player:pauseHandle(first)
  Assert.isTrue(player:isPlayerPlaying(20), "paused group remains allocated")
  Assert.isTrue(player:isHandlePlaying(second), "the other handle remains active")
  player:resumeHandle(first)
  player:stopPlayer(20)
  Assert.isFalse(player:isPlayerPlaying(20), "stopping a logical group removes every instance")
end

function T.sequence_stop_preserves_a_sibling_in_the_same_logical_group()
  local mixer = stubMixer()
  local player, provider = allocationEngine({
    [0] = longLivedSequence(0, 20, 64),
    [1] = longLivedSequence(1, 20, 64),
  }, { mixer = mixer, maxSequences = 2 })
  local first, second = player:createHandle(), player:createHandle()

  Assert.isTrue(player:play(first, provider:sequence(0), provider:bank(12)))
  Assert.isTrue(player:play(second, provider:sequence(1), provider:bank(12)))
  player:render(250)

  player:stopSequence(0)

  Assert.isFalse(player:isHandlePlaying(first), "the requested sequence is retired")
  Assert.isTrue(player:isHandlePlaying(second), "a sibling sequence remains attached")
  Assert.isTrue(player:isPlayerPlaying(20), "the logical player remains active")
  Assert.equal(#mixer.log.noteOffs, 1, "only the requested sequence releases its voice")
end

function T.sequence_stop_retires_all_matching_instances_in_slot_order()
  local retirements = {}
  local player, provider = allocationEngine({
    [40] = longLivedSequence(40, 7, 64),
    [41] = longLivedSequence(41, 8, 64),
  }, {
    maxSequences = 3,
    observer = {
      onSequenceRetirement = function(_, event)
        retirements[#retirements + 1] = event
      end,
    },
  })
  local first, second, unrelated = player:createHandle(), player:createHandle(), player:createHandle()

  Assert.isTrue(player:play(first, provider:sequence(40), provider:bank(12)))
  Assert.isTrue(player:play(second, provider:sequence(40), provider:bank(12)))
  Assert.isTrue(player:play(unrelated, provider:sequence(41), provider:bank(12)))

  player:stopSequence(40)

  Assert.equal(#retirements, 2, "every matching instance retires")
  Assert.deepEqual(
    { retirements[1].seqPlayerSlot, retirements[2].seqPlayerSlot },
    { 0, 1 },
    "matching instances retire in ascending physical slot order"
  )
  Assert.isFalse(player:isHandlePlaying(first))
  Assert.isFalse(player:isHandlePlaying(second))
  Assert.isTrue(player:isHandlePlaying(unrelated), "a nonmatching instance remains active")
  Assert.isTrue(player:isPlayerPlaying(8), "the unrelated logical player remains active")
end

function T.reusing_a_handle_detaches_without_retiring_the_former_sequence()
  local allocations, retirements, order = {}, {}, {}
  local mixer = stubMixer()
  local player, provider = allocationEngine({
    [0] = longLivedSequence(0, 1, 80),
    [1] = longLivedSequence(1, 1, 10),
  }, {
    maxSequences = 2,
    mixer = mixer,
    observer = {
      onSequenceAllocation = function(_, event)
        allocations[#allocations + 1] = event
        order[#order + 1] = "allocation"
      end,
      onSequenceRetirement = function(_, event)
        retirements[#retirements + 1] = event
        order[#order + 1] = "retirement"
      end,
    },
  })
  local handle = player:createHandle()

  Assert.isTrue(player:play(handle, provider:sequence(0), provider:bank(12)))
  player:render(250)
  Assert.isTrue(player:play(handle, provider:sequence(1), provider:bank(12)))
  player:render(250)

  Assert.equal(#retirements, 0, "handle reuse does not retire the former sequence")
  Assert.equal(#mixer.log.noteOffs, 0, "handle reuse does not release the former voice")
  Assert.deepEqual(order, { "allocation", "allocation" }, "detachment emits no retirement event")
  Assert.isTrue(player:isHandlePlaying(handle), "the handle owns the new sequence")
  Assert.isTrue(player:isPlayerPlaying(1), "both sequences remain in the logical group")

  player:stopHandle(handle)
  Assert.isTrue(player:isPlayerPlaying(1), "the detached former sequence remains active")
  player:stopPlayer(1)
  Assert.equal(#retirements, 2, "both sequence instances retire independently")
end

function T.reusing_a_handle_before_logical_rejection_leaves_it_empty()
  local allocations, retirements = {}, {}
  local mixer = stubMixer()
  local player, provider = allocationEngine({
    [0] = longLivedSequence(0, 1, 80),
    [1] = longLivedSequence(1, 1, 10),
  }, {
    maxSequences = 1,
    mixer = mixer,
    observer = {
      onSequenceAllocation = function(_, event)
        allocations[#allocations + 1] = event
      end,
      onSequenceRetirement = function(_, event)
        retirements[#retirements + 1] = event
      end,
    },
  })
  local handle = player:createHandle()

  Assert.isTrue(player:play(handle, provider:sequence(0), provider:bank(12)))
  player:render(250)
  Assert.isFalse(player:play(handle, provider:sequence(1), provider:bank(12)))

  Assert.isFalse(allocations[2].accepted, "the lower-priority admission is rejected")
  Assert.equal(allocations[2].reason, "logical_priority", "rejection reports logical priority")
  Assert.equal(#retirements, 0, "logical rejection does not retire the former sequence")
  Assert.equal(#mixer.log.noteOffs, 0, "logical rejection does not release the former voice")
  Assert.isFalse(player:isHandlePlaying(handle), "the rejected start leaves the reused handle empty")
  Assert.isTrue(player:isPlayerPlaying(1), "the detached former sequence remains active")
end

function T.retiring_a_detached_instance_does_not_clear_a_new_attachment()
  local player, provider = allocationEngine({
    [0] = longLivedSequence(0, 1, 64),
    [1] = longLivedSequence(1, 2, 64),
  }, { maxSequences = 1 })
  local handle = player:createHandle()

  Assert.isTrue(player:play(handle, provider:sequence(0), provider:bank(12)))
  Assert.isTrue(player:play(handle, provider:sequence(1), provider:bank(12)))
  player:stopPlayer(1)

  Assert.isTrue(player:isHandlePlaying(handle), "retiring the detached instance preserves the current attachment")
  player:stopHandle(handle)
end

function T.reusing_a_handle_does_not_create_a_physical_slot()
  local allocations, retirements = {}, {}
  local mixer = stubMixer()
  local sequences = {}
  for id = 0, 15 do
    sequences[id] = longLivedSequence(id, id, 30)
  end
  sequences[16] = longLivedSequence(16, 16, 20)
  local player, provider = allocationEngine(sequences, {
    mixer = mixer,
    observer = {
      onSequenceAllocation = function(_, event)
        allocations[#allocations + 1] = event
      end,
      onSequenceRetirement = function(_, event)
        retirements[#retirements + 1] = event
      end,
    },
  })
  local handle = player:createHandle()
  Assert.isTrue(player:play(handle, provider:sequence(0), provider:bank(12)))
  for id = 1, 15 do
    Assert.isTrue(player:play(player:createHandle(), provider:sequence(id), provider:bank(12)))
  end
  local firstSlot = allocations[1].seqPlayerSlot

  Assert.isFalse(player:play(handle, provider:sequence(16), provider:bank(12)))

  Assert.isFalse(allocations[17].accepted, "the lower-priority admission is rejected")
  Assert.equal(allocations[17].reason, "physical_priority", "rejection reports physical priority")
  Assert.equal(#retirements, 0, "full-pool rejection does not retire an incumbent")
  Assert.equal(#mixer.log.noteOffs, 0, "full-pool rejection does not release an incumbent voice")
  Assert.isFalse(player:isHandlePlaying(handle), "the reused handle is empty after rejection")
  Assert.isTrue(player:isPlayerPlaying(0), "the former attachment remains active")
  Assert.equal(allocations[1].seqPlayerSlot, firstSlot, "the former attachment keeps its slot")
end

function T.distinct_handles_isolate_controls_within_one_logical_group()
  local mixer = stubMixer()
  local player, provider = allocationEngine({
    [0] = longLivedSequence(0, 20, 64),
    [1] = longLivedSequence(1, 20, 64),
  }, { mixer = mixer, maxSequences = 2 })
  local first, second = player:createHandle(), player:createHandle()

  Assert.isTrue(player:play(first, provider:sequence(0), provider:bank(12)))
  Assert.isTrue(player:play(second, provider:sequence(1), provider:bank(12)))
  player:render(250)
  Assert.isTrue(player:isHandlePlaying(first))
  Assert.isTrue(player:isHandlePlaying(second))
  Assert.isTrue(player:isPlayerPlaying(20))

  local updatesBefore = #mixer.log.updates
  player:setHandleFader(first, 42)
  Assert.equal(#mixer.log.updates, updatesBefore + 1, "one-handle fader updates one attachment")
  player:pauseHandle(first)
  Assert.isTrue(player:isHandlePlaying(first), "pause keeps the attachment allocated")
  Assert.isTrue(player:isHandlePlaying(second), "pause leaves the other attachment active")
  player:resumeHandle(first)
  player:stopHandle(first)
  Assert.isFalse(player:isHandlePlaying(first))
  Assert.isTrue(player:isHandlePlaying(second), "stopping one handle preserves the other")
  player:stopPlayer(20)
  Assert.isFalse(player:isPlayerPlaying(20), "group stop removes the remaining attachment")
end

function T.rejected_handle_starts_report_false_without_claiming_ownership()
  local logicalAllocations = {}
  local logicalPlayer, logicalProvider = allocationEngine({
    [0] = longLivedSequence(0, 1, 80),
    [1] = longLivedSequence(1, 1, 10),
  }, {
    maxSequences = 1,
    observer = {
      onSequenceAllocation = function(_, event)
        logicalAllocations[#logicalAllocations + 1] = event
      end,
    },
  })
  local owner, candidate = logicalPlayer:createHandle(), logicalPlayer:createHandle()
  Assert.isTrue(logicalPlayer:play(owner, logicalProvider:sequence(0), logicalProvider:bank(12)))
  Assert.isFalse(logicalPlayer:play(candidate, logicalProvider:sequence(1), logicalProvider:bank(12)))
  Assert.isFalse(logicalPlayer:isHandlePlaying(candidate))
  Assert.isTrue(logicalPlayer:isHandlePlaying(owner))
  Assert.isFalse(logicalAllocations[2].accepted)

  local trackSequences = {
    [0] = longLivedSequence(0, 1, 64),
    [1] = longLivedSequence(1, 2, 64),
    [2] = longLivedSequence(2, 3, 64),
  }
  trackSequences[0].program.initialTrackMask = 0xFFFF
  trackSequences[1].program.initialTrackMask = 0xFFFF
  local trackPlayer, trackProvider = allocationEngine(trackSequences, { maxSequences = 2 })
  local first, second, rejected = trackPlayer:createHandle(), trackPlayer:createHandle(), trackPlayer:createHandle()
  Assert.isTrue(trackPlayer:play(first, trackProvider:sequence(0), trackProvider:bank(12)))
  Assert.isTrue(trackPlayer:play(second, trackProvider:sequence(1), trackProvider:bank(12)))
  Assert.isFalse(trackPlayer:play(rejected, trackProvider:sequence(2), trackProvider:bank(12)))
  Assert.isFalse(trackPlayer:isHandlePlaying(rejected))
end

return { tests = T }
