-- The g4 sequence-IR interpreter. It owns NNS-style players, active
-- sequences, tracks, program counters, track wait counters, calls, loops,
-- tempo, player variables, and track parameters, and drives a
-- VoiceMixer with the semantic voice spec ({channel, generation} handles,
-- trackVolume/sequenceVolume never folded, raw track pan offset, the clamped
-- transposed midiKey, the TrackInit userPitch 0, and the TrackPlayNote
-- sweep/LFO fields). It interprets project instruction IR, never SSEQ. The
-- tick clock is the NNS relationship verified from GBATEK ("DS Sound Files
-- - SSEQ") and the ARM7 NitroSDK player (SND_seq.c: SND_TIMER_RATE 240 at
-- the 192 Hz sound interval): a quarter note is 48 ticks and tempo is BPM
-- (1..240, default 120). Sequence ticks come from each player's integer
-- `tempoCounter` (PlayerSeqMain) driven only by the global 192 Hz sound
-- interval: while the counter is at least 240 the player executes one
-- sequence tick per 240 subtracted, and after all ticks of the interval
-- the counter gains (tempo * tempoRatio) >> 8 once. A fresh player starts
-- at tempoCounter 240 (PlayerInit), so its first source sequence tick
-- occurs on the first sound interval after play(); play() itself does not
-- fetch or execute the entry program. A track's wait is an integer tick
-- count; a note-off lands on the tick boundary after the boundary frame's
-- render. Tempo changes executed during one of several ticks of the same
-- interval affect the interval's end increment, matching source ordering.
--
-- Track state follows the SDK: wait ticks, the note-finish hold (a
-- zero-length note under note-wait is a note-FINISH wait, never a one-tick
-- gate: the track stays blocked until its live channel handles are gone),
-- note-wait (default true), a polyphonic voice collection of {handle,
-- length, releasing} records (never a single channel), tie, mute, program,
-- priority (default 64), volume/expression 127, the raw pan offset (default
-- 0; the 0xC0 pan command stores amount-64), transpose, bend 0 (the SDK
-- TrackInit; bend is user pitch, never a key fold), bend range 2, the mod
-- snapshot (target 0, depth 0, range 1, speed 16, delay 0), sweepPitch 0,
-- portamentoKey 60, portamentoTime 0, the portamento flag, nullable
-- envelope stage overrides (0xD0-0xD3, applied to a note only when set),
-- and the call/loop control stack. Fresh tracks gate notes by their duration;
-- 0xC7 note_wait clears the flag so composers pair notes with explicit
-- 0x80 waits, and each ringing voice's own length bounds its ring
-- independently of gates (the NNS channel length): only positive finite
-- lengths are decremented toward release, while tied and non-positive-
-- duration channels are indefinite and never released by the duration
-- counter. WAIT 0 does not gate: the next instruction runs in the same
-- pass.
--
-- Voice attachment follows the SDK release/free split: a natural length
-- expiry and mute mode 2 start an ordinary release (TrackReleaseChannels
-- without TrackFreeChannels) that keeps the voice record attached -- marked
-- `releasing` -- until the mixer reports the physical voice dead, and an
-- attached releasing voice receives only the player fader contribution on
-- later track updates (TrackUpdateChannel updates userDecay2 on linked
-- channels after release status and skips every other field). Explicit
-- detach paths -- the tie command, mute mode 3, pause, stop/player
-- replacement, and open_track replacement -- release then immediately drop
-- the handle (TrackReleaseChannels followed by TrackFreeChannels) while the
-- physical release tail may continue in the mixer. The mixer owns voice
-- liveness (isVoiceAlive): the player prunes dead/stolen handles from its
-- collections and waits on real handle liveness for note-finish, never on a
-- predicted release end.
-- The transposed key is clamped to 0..127 before the bank leaf is selected
-- (InstrumentSelector.selectVoice), so key-split and drum-set selection run on the
-- midi key, and pitch comes from the selected voice's root key. Loops
-- follow the ARM7 player (SND_seq.c): loop_begin pushes
-- a frame holding the count and the return index (the instruction after the
-- begin, the SDK's posCallStack); loop_end decrements and jumps back while
-- the count is positive, exits when it reaches zero, jumps forever while
-- the count is zero (the SDK's loopCount 0 -- the real SEQ_GS_P_SAFARI_ROAD),
-- and is a no-op with no active frame. A return with no active call is
-- likewise a no-op. Calls and loops share ONE ordered control stack of at
-- most three frames (SND_seq.c posCallStack/callStackDepth): a push is a
-- source no-op once the depth is full. Random amount operands resolve through
-- the player's injected or default RNG (created once at construction, never
-- reseeded per play) in the SDK u16 draw domain (SND_CalcRandom: state =
-- state*1664525 + 1013904223 mod 2^32, draw = state >> 16, initial state
-- 0x12345678; TrackParseValue scales lo + ((draw * (hi - lo + 1)) >> 16));
-- variables live in the SDK 16-local/16-global domain with s16
-- arithmetic (addvar/subvar/mulvar/divvar/shiftvar/randomvar, div-by-zero
-- skips, negative shifts shift right). The mod commands set the LFO
-- snapshot every noteOn spec carries and queue it to live voices; the
-- sweep/portamento commands set the note's TrackPlayNote sweep fields (the
-- track sweep plus the portamento contribution, and the sweep length
-- derived from portamentoTime), and each note updates the track's
-- portamento key to the note's MIDI key. A tied re-note over a live head
-- voice executes the full TrackPlayNote common tail on the same physical
-- generation through the mixer's semantic retarget: key/velocity and the
-- current track envelope overrides replace the coefficients, the sweep
-- state is recomputed with the counter reset to zero, and the envelope
-- stage and the generator/sample phase never restart; the retargeted voice
-- stays indefinite. A pitch-bend-range command is a live channel control:
-- it recomputes the user pitch and queues it to every attached
-- non-releasing voice immediately, with no note restart.
--
-- Rendering is a span scheduler around the pure PCM mixer: the player owns
-- the one global 192 Hz sound phase (`_soundPhase`), renders each span up
-- to the next sound-interval boundary, and processes that interval once
-- the boundary frame has rendered -- ascending players' `tempoCounter`
-- sequence ticks first, then one `VoiceMixer:controlStep()`, then one
-- unconditional periodic RNG draw (SND_SeqMain then SND_ExChannelMain then
-- SND_CalcRandom). The phase and RNG advance whenever PCM rendering is
-- requested, even with no active sequence, so idle frames and detached
-- release tails keep the clock running. The mixer renders spans that end
-- at the next sound-interval boundary or the requested window end -- never
-- one frame at a time and never on a per-player tick distance, so chunk
-- sizes never change the result. Physical SeqPlayer slots process ascending
-- slot number and tracks ascending track number over the fixed NNS domains
-- (16 slots x 16 tracks), so contested allocation is deterministic. Control values
-- reach the active voices as events: a track/player control command
-- (volume, pan, expression, master volume, pitch bend, modulation) or a
-- fader change queues the current values -- including the user pitch and
-- the live LFO parameters -- to its live voice handles
-- immediately (the NNS TrackUpdateChannel delivery), and the mixer applies
-- them at the next control step after the sequence portion of the same
-- sound interval. play(handle, sequence, bank) starts an ordered sequence instance
-- in its SDAT player's capacity without executing its entry program. Instances
-- share the global track pool and physical mixer.

local Errors = require("libs.errors.src.Errors")
local AudioErrors = require("libs.nds.src.nitro.sound.AudioErrors")
local InstrumentSelector = require("libs.nds.src.nitro.sound.InstrumentSelector")
local NnsSoundMath = require("libs.nds.src.nitro.sound.NnsSoundMath")
local bit = require("bit")

---@class NdsSoundProvider
---@field player fun(self: NdsSoundProvider, id: integer): table<string, unknown>
---@field loadSample fun(self: NdsSoundProvider, key: string): { metadata: table<string, unknown>, pcm: integer[] }

---@class SequencePlayer
---@field private _sampleRate integer
---@field private _mixer VoiceMixer
---@field private _provider NdsSoundProvider
---@field private _logicalPlayers table<integer, table<string, unknown>>
---@field private _seqPlayers table<integer, table<string, unknown>?>
---@field private _freeSeqPlayerSlots integer[] FIFO of inactive physical slots
---@field private _trackPool table<integer, table<string, unknown>?> concrete reusable track objects
---@field private _handles table<table<string, unknown>, boolean> handles created by this player
---@field private _handleAttachments table<table<string, unknown>, table<string, unknown>?> current instance per handle
---@field private _soundPhase integer the one global 192 Hz sound-interval phase accumulator
---@field new fun(opts: { sampleRate: integer, mixer: VoiceMixer, provider: NdsSoundProvider, observer: table<string, unknown>? }): SequencePlayer
---@field createHandle fun(self: SequencePlayer): table<string, unknown>
---@field play fun(self: SequencePlayer, handle: table<string, unknown>, sequence: table<string, unknown>, bank: table<string, unknown>): boolean
---@field playSynthetic fun(self: SequencePlayer, handle: table<string, unknown>, sequence: table<string, unknown>, bank: table<string, unknown>): boolean
---@field render fun(self: SequencePlayer, frames: integer): integer[]
---@field stop fun(self: SequencePlayer)
---@field stopPlayer fun(self: SequencePlayer, playerId: integer)
---@field isPlayerPlaying fun(self: SequencePlayer, playerId: integer): boolean
---@field isPlaying fun(self: SequencePlayer): boolean
---@field setHandleFader fun(self: SequencePlayer, handle: table<string, unknown>, level: integer)
---@field setHandleTrackPitch fun(self: SequencePlayer, handle: table<string, unknown>, pitch: integer)
---@field pauseHandle fun(self: SequencePlayer, handle: table<string, unknown>)
---@field resumeHandle fun(self: SequencePlayer, handle: table<string, unknown>)
---@field stopHandle fun(self: SequencePlayer, handle: table<string, unknown>)
---@field releaseHandle fun(self: SequencePlayer, handle: table<string, unknown>)
---@field isHandlePlaying fun(self: SequencePlayer, handle: table<string, unknown>): boolean
---@field stopSequence fun(self: SequencePlayer, sequenceId: integer)

local SequencePlayer = {}
SequencePlayer.__index = SequencePlayer

local DEFAULT_TEMPO = 120
local DEFAULT_BEND_RANGE = 2
-- The Nitro sound interval: 192 Hz global scheduling clock (SND_main.c
-- SndThread). Each rendered output frame advances the global phase by
-- SOUND_INTERVAL_HZ units; one sound interval fires when the phase reaches
-- the sample rate.
local SOUND_INTERVAL_HZ = 192
-- The fixed NNS scheduling domains (SND_seq.c SND_PLAYER_COUNT /
-- SND_TRACK_COUNT): players and tracks iterate ascending over these bounds,
-- never in Lua table order, so contested allocation is deterministic.
local PLAYER_COUNT = 16
local LOGICAL_PLAYER_COUNT = 32
local TRACK_COUNT = 16
local TRACK_POOL_CAPACITY = 32
-- The Nitro sequence tick relationship at the 192 Hz sound interval
-- (SND_seq.c PlayerSeqMain): SND_TIMER_RATE 240; per interval the player
-- consumes one tick per 240 subtracted from tempoCounter while it is at
-- least 240, then adds tempoInc = (tempo * tempoRatio) >> 8 once. PlayerInit
-- starts a fresh player at tempo = 120, tempoRatio = 256, tempoCounter =
-- 240, so the first source tick occurs on the first interval after play().
local SND_TIMER_RATE = 240
-- The SDK variable domain: vars 0..15 are player-local, 16..31 the shared
-- global variables (SND_work_shared localVars[16] per player plus
-- globalVars[16]).
local LOCAL_VAR_COUNT = 16
-- The one source control-flow stack shared by calls and loops
-- (SND_seq.c SND_TRACK_MAX_CALL): at most three frames per track, consumed
-- by both CALL and LOOP_BEGIN; a push beyond the depth is a source no-op.
local CONTROL_STACK_MAX = 3
-- The host safety budget: an upper bound on instructions executed without a
-- wait gate. A program that exceeds it is an authored runaway (e.g. a jump
-- to itself) and fails loudly instead of hanging the render loop.
local HOST_SAFETY_STEP_BUDGET = 1024

local function validateHandle(self, handle)
  assert(type(handle) == "table" and self._handles[handle], "handle must belong to this SequencePlayer")
end

local function observerCallback(self, method)
  local observer = self._observer
  if observer == nil then
    return nil, nil
  end
  local callback = observer[method]
  if callback == nil then
    return nil, nil
  end
  return observer, callback
end

-- NNS returns retired physical players to a free-list and allocates its head.
-- Keep the ownership checks at this boundary so corruption cannot be repaired
-- by silently reordering or duplicating a slot.
local function appendFreeSeqPlayerSlot(self, slot)
  assert(slot >= 0 and slot < PLAYER_COUNT, "physical slot must be in range")
  assert(self._seqPlayers[slot] == nil, "free physical slot is still occupied")
  for index = 1, #self._freeSeqPlayerSlots do
    assert(self._freeSeqPlayerSlots[index] ~= slot, "free physical slot is duplicated")
  end
  self._freeSeqPlayerSlots[#self._freeSeqPlayerSlots + 1] = slot
end

local function popFreeSeqPlayerSlot(self)
  local slot = table.remove(self._freeSeqPlayerSlots, 1)
  if slot == nil then
    return nil
  end
  assert(self._seqPlayers[slot] == nil, "free physical slot is occupied")
  return slot
end

local function clamp(value, low, high)
  if value < low then
    return low
  end
  if value > high then
    return high
  end
  return value
end

-- The four source storage widths (SND_seq.c fixed-width stores): a resolved
-- dynamic operand is narrowed only after resolution, at the exact width of
-- the command's C storage type. u8/s16 wrap by modulo; s8/u16 are the
-- two's-complement interpretations of their wider forms.
---@param value number
---@return integer
local function toU8(value)
  return math.floor(value % 256)
end

---@param value number
---@return integer
local function toS8(value)
  local wrapped = toU8(value)
  if wrapped >= 128 then
    wrapped = wrapped - 256
  end
  return wrapped
end

---@param value number
---@return integer
local function toU16(value)
  return math.floor(value % 65536)
end

-- The s16 domain of the SDK variables: values wrap to the signed 16-bit
-- range on every store.
---@param value number
---@return integer
local function toS16(value)
  local wrapped = toU16(value)
  if wrapped >= 32768 then
    wrapped = wrapped - 65536
  end
  return wrapped
end

-- A deterministic default RNG matching SND_CalcRandom (SND_seq.c): state =
-- state * 1664525 + 1013904223 mod 2^32 (exact for every integer product,
-- which stays below 2^53 in the double domain), and the draw is the high
-- 16 bits of state, starting from 0x12345678. Created once per player at
-- construction; plays share it and never reseed.
local function newRng()
  local state = 0x12345678
  local function nextRandom()
    state = (state * 1664525 + 1013904223) % 4294967296
    return math.floor(state / 65536)
  end
  return nextRandom
end

-- Reads an SDK variable: 0..15 player-local, 16..31 global. Every valid
-- variable is explicitly initialized (-1) for the lifetime of its owning
-- domain (locals per play, globals per player construction), so a read never
-- infers a value from a missing entry.
local function varRead(self, instance, var)
  if var < LOCAL_VAR_COUNT then
    return instance.localVars[var]
  end
  return self._globalVars[var - LOCAL_VAR_COUNT]
end

-- Stores an SDK variable in its domain, wrapped to the s16 range.
local function varWrite(self, instance, var, value)
  value = toS16(value)
  if var < LOCAL_VAR_COUNT then
    instance.localVars[var] = value
  else
    self._globalVars[var - LOCAL_VAR_COUNT] = value
  end
end

-- Resolves a normalized amount operand against the player instance: a plain
-- value passes through, a random record draws from the player's RNG in the
-- SDK u16 draw domain and scales with the TrackParseValue integer
-- arithmetic (lo + arshift(draw * (hi - lo + 1), 16)), a variable record
-- reads the SDK variable it names. The sequence validator admits only these
-- shapes (the retired min/max random pair is rejected at validation), so
-- anything else is a programmer fault.
local function toS32(value)
  return bit.tobit(value)
end

-- The exact signed 32-bit TrackParseValue arithmetic: the endpoints are the
-- raw source pair, never sorted or renamed, so a descending lo > hi pair
-- resolves through the same formula.
local function randomOperand(draw, operand)
  local lo = operand.lo
  local hi = operand.hi
  local span = toS32(hi - lo + 1)
  local product = toS32(draw * span)
  return toS32(lo + bit.arshift(product, 16))
end

local function resolveAmount(self, amount, instance)
  if type(amount) == "number" then
    return amount
  end
  if amount.kind == "random" then
    return randomOperand(self._rng(), amount)
  end
  if amount.kind == "variable" then
    return varRead(self, instance, assert(amount.var, "variable amount requires a var id"))
  end
  assert(false, "unsupported amount operand in sequence")
end

-- A fresh SDK variable domain: all LOCAL_VAR_COUNT entries explicitly
-- initialized to -1 (the source PlayerInit value). Every valid variable is
-- therefore always explicit; reads never infer a value from a missing entry.
local function newVariableDomain()
  local vars = {}
  for index = 0, LOCAL_VAR_COUNT - 1 do
    vars[index] = -1
  end
  return vars
end

local function newTrack(slot)
  return {
    slot = slot,
    pc = nil,
    ended = false,
    gated = false,
    wait = 0,
    -- The note-finish hold: set by a zero-length note under note-wait; the
    -- track stays blocked until its live channel handles are gone.
    noteFinishWait = false,
    -- The track's ringing voices (polyphonic): a list of
    -- {handle, length, releasing} records -- the mixer {channel, generation}
    -- handle, the voice's remaining length in ticks (the NNS per-channel
    -- length, -1 for an indefinite tied or non-positive-duration voice), and
    -- whether an ordinary source release has begun while the voice is still
    -- attached. A record stays attached through its release tail until the
    -- mixer reports the physical voice dead (pruneTrackVoices) or an
    -- explicit detach path drops it; an attached releasing record receives
    -- only the player fader contribution on later track updates.
    voices = {},
    -- Note gating: fresh tracks gate notes by their duration (the NNS
    -- TrackStart initialization sets noteWait); 0xC7 note_wait clears it so
    -- composers pair notes with explicit waits.
    noteWait = true,
    tie = false,
    mute = 0,
    program = 0,
    priority = 64,
    volume = 127,
    expression = 127,
    -- The raw track pan offset (the NNS 0xC0 pan command stores amount-64;
    -- the mixer scales it into the final pan register).
    pan = 0,
    transpose = 0,
    -- The signed bend (the SDK TrackInit pitchBend 0; 0 is no bend, never
    -- a centered-at-64 convention): the pitch_bend command maps it to the
    -- voice's userPitch, never to a key change.
    bend = 0,
    bendRange = DEFAULT_BEND_RANGE,
    -- The LFO parameter snapshot (TrackInit via SND_InitLfoParam: target 0,
    -- depth 0, range 1, speed 16, delay 0); the mod commands set the fields
    -- and every noteOn spec carries a fresh copy.
    mod = { target = 0, depth = 0, range = 1, speed = 16, delay = 0 },
    -- The pitch-sweep/portamento state (TrackInit): the s16 sweepPitch, the
    -- portamento key/time pair and the portamento flag.
    sweepPitch = 0,
    portamentoKey = 60,
    portamentoTime = 0,
    portamento = false,
    -- Per-track envelope stage overrides (the NNS 0xD0-0xD3 commands), nil
    -- until set; a set override replaces exactly that stage of a note's
    -- envelope.
    attack = nil,
    decay = nil,
    sustain = nil,
    release = nil,
    -- The one source control-flow stack shared by calls and loops
    -- (SND_seq.c posCallStack/callStackDepth): ordered, at most
    -- CONTROL_STACK_MAX frames, each holding a kind discriminator, the
    -- return index, and a loop count when applicable.
    controlStack = {},
    compare = true,
  }
end

-- Resets only TrackStart-owned execution state. TrackInit-owned musical
-- controls remain on an allocated track object when OPEN_TRACK reopens it.
local function startTrack(track, entry)
  track.pc = entry
  track.ended = false
end

local function allocateTrack(self, slot)
  local poolIndex
  for candidate = 0, TRACK_POOL_CAPACITY - 1 do
    if self._trackPool[candidate] == nil then
      poolIndex = candidate
      break
    end
  end
  if poolIndex == nil then
    local observer, callback = observerCallback(self, "onTrackPool")
    if callback ~= nil then
      callback(observer, { allocated = self._trackCount, capacity = TRACK_POOL_CAPACITY })
    end
    return nil
  end

  local track = newTrack(slot)
  track.poolIndex = poolIndex
  track.poolOwned = true
  self._trackPool[poolIndex] = track
  self._trackCount = self._trackCount + 1
  local observer, callback = observerCallback(self, "onTrackPool")
  if callback ~= nil then
    callback(observer, {
      allocated = self._trackCount,
      capacity = TRACK_POOL_CAPACITY,
      poolIndex = poolIndex,
    })
  end
  return track
end

local function releaseTrackObject(self, track)
  assert(track ~= nil and track.poolOwned, "track must own a concrete pool object")
  assert(self._trackPool[track.poolIndex] == track, "track pool ownership is inconsistent")
  self._trackPool[track.poolIndex] = nil
  track.poolOwned = false
  self._trackCount = self._trackCount - 1
  assert(self._trackCount >= 0, "track pool count cannot be negative")
  local observer, callback = observerCallback(self, "onTrackPool")
  if callback ~= nil then
    callback(observer, {
      allocated = self._trackCount,
      capacity = TRACK_POOL_CAPACITY,
      poolIndex = track.poolIndex,
    })
  end
end

-- The SDK user pitch (SND_seq.c TrackUpdateChannel): pitchBend *
-- (bendRange << 6) >> 7 with arithmetic-shift (floor) semantics; bend 0 is
-- no bend.
local function userPitchFor(track)
  return math.floor(track.bend * (track.bendRange * 64) / 128)
end

local function effectiveUserPitch(instance, track)
  return userPitchFor(track) + instance.externalTrackPitch
end

-- The note's effective envelope: a set track override replaces exactly that
-- stage of the voice envelope (SND_seq.c TrackPlayNote applies each
-- non-0xFF override to the channel after allocation).
local function effectiveEnvelope(track, voice)
  return {
    attack = track.attack or voice.envelope.attack,
    decay = track.decay or voice.envelope.decay,
    sustain = track.sustain or voice.envelope.sustain,
    release = track.release or voice.envelope.release,
  }
end

-- TrackPlayNote stores 0xFF as the source-level unset marker. Track state
-- keeps that marker semantic: only concrete values are override coefficients.
local function envelopeOverride(value)
  if value == 0xFF then
    return nil
  end
  return value
end

-- The note's sweep pitch (TrackPlayNote): the track sweepPitch plus, under
-- portamento, the (portamentoKey - midiKey) << 6 contribution (the sums
-- stay in the s16 domain).
local function sweepPitchFor(track, midiKey)
  local sweepPitch = track.sweepPitch
  if track.portamento then
    sweepPitch = toS16(sweepPitch + (track.portamentoKey - midiKey) * 64)
  end
  return sweepPitch
end

-- The note's sweep length (TrackPlayNote): with no portamento time the
-- sweep length is the note length and the sweep does not advance on its
-- own (non-auto); with one it is time^2 * |sweepPitch| >> 11 over the
-- note's own sweep pitch and the mixer advances it per control step
-- (auto).
local function sweepLengthFor(track, length, midiKey)
  local sweepPitch = sweepPitchFor(track, midiKey)
  if track.portamentoTime == 0 then
    return length
  end
  local magnitude = sweepPitch < 0 and -sweepPitch or sweepPitch
  return math.floor(track.portamentoTime * track.portamentoTime * magnitude / 2048)
end

-- Prunes the track's voice collection by mixer liveness: the mixer owns
-- voice death (a stolen channel, a completed one-shot, or the release-stop
-- step), so a handle it reports dead leaves the collection and a later
-- release or finish-wait check touches only the live voices. After the
-- call, `#track.voices` is the live count.
local function pruneTrackVoices(self, track)
  local write = 1
  local count = #track.voices
  for index = 1, count do
    local voice = track.voices[index]
    if self._mixer:isVoiceAlive(voice.handle) then
      track.voices[write] = voice
      write = write + 1
    end
  end
  for index = write, count do
    track.voices[index] = nil
  end
end

-- Starts the mixer release of one attached voice record and marks the
-- record releasing: the handle STAYS attached (the SDK TrackReleaseChannels
-- without TrackFreeChannels -- natural length expiry and mute mode 2), so
-- the release tail keeps receiving fader-only updates and the note-finish
-- hold keeps waiting on real liveness. Ordinary nil-override bookkeeping is
-- suppressed after release starts; an explicit override is forwarded so the
-- forced track-release path can accelerate an existing release.
local function noteOff(self, voice, releaseOverride)
  if releaseOverride == nil and voice.releasing then
    return
  end
  self._mixer:noteOff(voice.handle, releaseOverride)
  voice.releasing = true
end

-- Starts the note's voice on the mixer and returns its {channel, generation}
-- handle (or nil for a silent note). `midiKey` is the already clamped
-- transposed key: it drives the bank leaf selection (SND_ReadInstData) and
-- rides the spec as the voice's key, and the pitch is the selected voice's
-- (midiKey - rootMidiKey) * 0x40 in the mixer -- never the source note key.
-- The voice spec carries the decoded PCM and loop window from the provider,
-- the raw track pan offset, the channel/track priorities and channel mask
-- from the sequence's player record (nothing is folded into the track
-- volume), the TrackInit userPitch 0, the TrackPlayNote sweep fields (the
-- track sweep plus the portamento contribution, the sweep length from
-- portamentoTime, autoSweep, and the counter at 0) and a fresh
-- TrackUpdateChannel lfo snapshot of the track mod state.
---@param provider NdsSoundProvider
---@param mixer VoiceMixer
---@param instance table<string, unknown>
---@param track table<string, unknown>
---@param midiKey integer
---@param velocity integer
---@param length integer
---@return { channel: integer, generation: integer }?, boolean?
local function startNote(provider, mixer, instance, track, midiKey, velocity, length)
  -- A program the bank does not define is a silent note (the NNS
  -- SND_ReadInstData failure path): the real corpus references instruments
  -- whose SBNK records are unused/placeholder and the DS plays silence.
  local instrument = instance.bank.instruments[track.program]
  if instrument == nil then
    return nil
  end
  local voice = InstrumentSelector.selectVoice(instrument, midiKey)
  if voice == nil then
    return nil
  end
  local spec = { generator = voice.generator }
  if voice.generator.kind == "sample" then
    local sample = provider:loadSample(voice.generator.sample)
    spec.baseTimer = sample.metadata.baseTimer
    spec.pcm = sample.pcm
    spec.loop = sample.metadata.loop
    spec.loopEnabled = sample.metadata.loopEnabled
  end
  local sequence = instance.sequence
  spec.originalKey = voice.originalKey
  spec.key = midiKey
  -- The TrackInit user pitch (SND_seq.c TrackInit pitchBend 0, mapped to
  -- the voice by TrackUpdateChannel): bend 0 is no bend.
  spec.userPitch = effectiveUserPitch(instance, track)
  spec.velocity = velocity
  local indefinite = voice.envelope.release == 0xFF
  local envelope = effectiveEnvelope(track, voice)
  spec.length = indefinite and -1 or length
  -- The dB table domain is 0..127 while the asset schemas carry u8 volumes,
  -- so the player bounds them at the mixer boundary (the SDK reads past its
  -- 128-entry table here).
  spec.trackVolume = clamp(track.volume, 0, 127)
  spec.expression = clamp(track.expression, 0, 127)
  spec.sequenceVolume = clamp(instance.sequenceVolume, 0, 127)
  spec.fader = NnsSoundMath.decibel(instance.outerPlayerVolume) + instance.outerFaderDb
  spec.envelope = envelope
  spec.pan = voice.pan
  spec.trackPanOffset = track.pan
  spec.trackPriority = track.priority
  spec.channelPriority = sequence.player.channelPriority
  spec.channelMask = instance.channelMask
  spec.ownerPlayerId = instance.logicalPlayerId
  spec.ownerTrackSlot = track.slot
  -- TrackPlayNote: the sweep starts from the track sweepPitch; a note under
  -- portamento adds (portamentoKey - midiKey) << 6 units (the sums stay in
  -- the s16 domain). With no portamento time the sweep length is the note
  -- length and the sweep does not advance on its own; with one it is
  -- time^2 * |sweepPitch| >> 11 and the mixer advances it per control step.
  spec.sweepPitch = sweepPitchFor(track, midiKey)
  spec.sweepLength = sweepLengthFor(track, length, midiKey)
  spec.autoSweep = track.portamentoTime ~= 0
  spec.sweepCounter = 0
  spec.lfo = {
    target = track.mod.target,
    depth = track.mod.depth,
    range = track.mod.range,
    speed = track.mod.speed,
    delay = track.mod.delay,
  }
  return mixer:noteOn(spec), indefinite
end

local function observeNote(self, instance, track, key, velocity, length)
  local observer, callback = observerCallback(self, "onNoteEvent")
  if callback == nil then
    return
  end
  callback(observer, {
    ordinal = self._intervalOrdinal,
    playerId = instance.logicalPlayerId,
    trackSlot = track.slot,
    key = key,
    velocity = velocity,
    length = length,
    effectiveChannelPriority = instance.sequence.player.channelPriority + track.priority,
    channelPriority = instance.sequence.player.channelPriority,
    sequenceVolume = instance.sequenceVolume,
    outerPlayerVolume = instance.outerPlayerVolume,
    outerFaderDb = instance.outerFaderDb,
  })
end

-- Queues the current track values to every live voice handle of a track
-- (the NNS TrackUpdateChannel delivery): a track/player control command or
-- a fader change delivers the current values as an event immediately, and
-- the mixer applies them at the next control step after the sequence
-- portion of the same sound interval -- the player owns the 192 Hz cadence
-- and never rounds it. New notes already receive the current values in
-- their noteOn spec. The partial carries the user pitch and the track's
-- live LFO parameter table, so later modulation commands change the values
-- the mixer applies. After release status an attached releasing voice
-- receives ONLY the fader contribution (TrackUpdateChannel updates
-- userDecay2 on linked channels and skips every other field); the full
-- track values reach the still-non-releasing voices.
local function pushTrackValues(self, instance, track)
  local full = {
    trackVolume = clamp(track.volume, 0, 127),
    expression = clamp(track.expression, 0, 127),
    sequenceVolume = clamp(instance.sequenceVolume, 0, 127),
    trackPanOffset = track.pan,
    userPitch = effectiveUserPitch(instance, track),
    lfo = track.mod,
    -- The player fader rides the same queue as a dB-domain attenuation.
    fader = NnsSoundMath.decibel(instance.outerPlayerVolume) + instance.outerFaderDb,
  }
  for index = 1, #track.voices do
    local voice = track.voices[index]
    if voice.releasing then
      -- Attached releasing voices take the fader contribution only.
      self._mixer:updateVoice(voice.handle, { fader = full.fader })
    else
      self._mixer:updateVoice(voice.handle, full)
    end
  end
end

-- Releases every live voice handle of a track and clears the collection
-- (the SDK TrackReleaseChannels + TrackFreeChannels -- the tie, mute-stop,
-- pause, stop and open-track-replacement paths): the source release
-- operation first delivers the current full non-release track values to
-- the attached channels once (TrackReleaseChannels starts with
-- TrackUpdateChannel(track, player, 0)), then starts the release on each
-- live voice, then drops every handle -- the physical release tails may
-- continue in the mixer. `releaseOverride` (nil or an integer 0..127) is
-- passed to the mixer noteOffs -- the forced track-release path pause and
-- mute mode 3 use. Explicit forced overrides are forwarded even when a voice
-- is already marked releasing; ordinary repeats are suppressed.
-- An empty collection makes this a no-op, so a replacement/pause over an
-- already-freed instance releases nothing extra.
local function releaseTrackVoices(self, instance, track, releaseOverride)
  pruneTrackVoices(self, track)
  if #track.voices == 0 then
    return
  end
  pushTrackValues(self, instance, track)
  for index = 1, #track.voices do
    noteOff(self, track.voices[index], releaseOverride)
  end
  track.voices = {}
end

-- Executes one instruction, mutating the track, and returns the next
-- program counter. Gating instructions (note/wait) set the track's wait;
-- end ends the track; open_track spawns the target track and lets the
-- current track continue; loop_end jumps to its loop frame's return index
-- while the frame's count is positive (forever at count 0) and falls through
-- when the count reaches zero.
local function execute(self, instance, track, instruction)
  local op = instruction.op
  if op == "if" then
    if track.compare then
      return execute(self, instance, track, instruction.instruction)
    end
    return track.pc + 1
  end
  if op == "note" then
    -- Polyphonic: a new note never releases a ringing one; every note
    -- appends its own voice (or reuses the tied head) and each voice's
    -- length bounds its ring independently. The transposed key is clamped
    -- to the MIDI domain BEFORE the bank leaf is selected (SND_seq.c
    -- TrackStepTicks midiKey + TrackPlayNote SND_ReadInstData), so
    -- key-split and drum-set selection run on the midi key and the spec
    -- key is that clamped key. A note's channel length is its finite
    -- duration when positive; tied starts and non-positive durations are
    -- indefinite (the SDK -1) and are never released by the duration
    -- counter. A zero-length note under note-wait is a note-FINISH wait
    -- (the NNS noteFinishWait), not a one-tick gate: the track stays
    -- blocked until its live channel handles are gone. Muted tracks play
    -- no voice but gate exactly like normal notes.
    local length = resolveAmount(self, instruction.duration, instance)
    local midiKey = clamp(instruction.key + track.transpose, 0, 127)
    local velocity = instruction.velocity
    ---@cast length integer
    ---@cast midiKey integer
    ---@cast velocity integer
    if track.mute == 0 then
      if track.tie then
        -- Tied re-note: reuse the most recent live voice in place (the NNS
        -- TrackPlayNote tie path): no noteOn, no noteOff; the key and
        -- velocity change at the next control step and the envelope never
        -- restarts. The reused head keeps its indefinite length. Without a
        -- live voice a fresh tied channel starts, also indefinite.
        pruneTrackVoices(self, track)
        if #track.voices > 0 then
          -- The full source common tail on the SAME physical generation
          -- (SND_seq.c TrackPlayNote over the existing channelLLHead): the
          -- key/velocity update in place, only the track's set envelope
          -- overrides replace the channel's coefficients, and the sweep
          -- state is recomputed with the counter reset to zero -- the
          -- envelope stage and the generator/sample phase never restart.
          local head = track.voices[#track.voices]
          local retarget = {
            key = midiKey,
            velocity = instruction.velocity,
            -- The current track envelope overrides: a set override replaces
            -- exactly that stage of the voice envelope; unset stages keep
            -- the channel's existing coefficients.
            envelope = {
              attack = track.attack,
              decay = track.decay,
              sustain = track.sustain,
              release = track.release,
            },
            sweepPitch = sweepPitchFor(track, midiKey),
            sweepLength = sweepLengthFor(track, length, midiKey),
            -- The source TrackPlayNote tail resets the sweep counter to
            -- zero so the recomputed sweep runs its full length from the
            -- re-note.
            sweepCounter = 0,
          }
          if track.portamentoTime == 0 then
            retarget.autoSweep = false
          end
          self._mixer:retargetTiedVoice(head.handle, retarget)
        else
          local handle = startNote(self._provider, self._mixer, instance, track, midiKey, velocity, length)
          if handle ~= nil then
            track.voices[#track.voices + 1] = { handle = handle, length = -1, releasing = false }
          end
        end
      else
        local handle, indefinite = startNote(self._provider, self._mixer, instance, track, midiKey, velocity, length)
        if handle ~= nil then
          track.voices[#track.voices + 1] = {
            handle = handle,
            length = indefinite and -1 or (length > 0 and length or -1),
            releasing = false,
          }
        end
      end
    end
    -- TrackPlayNote ends by storing the played MIDI key as the track's
    -- portamento key, so the next note's portamento contribution slides
    -- from the just-played pitch.
    track.portamentoKey = midiKey
    observeNote(self, instance, track, midiKey, instruction.velocity, length)
    if track.noteWait then
      -- The raw resolved length gates the track exactly like the source
      -- wait: a positive length is the integer wait that decrements per
      -- tick, zero is the note-finish hold (not a one-tick gate), and a
      -- negative length never decrements toward zero, so the track stalls
      -- while the physical voice is indefinite.
      track.gated = length ~= 0
      track.wait = length
      if length == 0 then
        track.noteFinishWait = true
      end
    end
    return track.pc + 1
  end
  if op == "wait" then
    -- 0x80: gate the track without releasing a ringing note (the note's own
    -- voice length bounds its ring). The raw resolved duration is the wait:
    -- a positive value gates for that many ticks, zero does not gate at all
    -- (the next instruction runs in the same pass), and a negative value
    -- gates the track into a stall that never decrements toward zero.
    local duration = resolveAmount(self, instruction.duration, instance)
    track.gated = duration ~= 0
    track.wait = duration
    return track.pc + 1
  end
  if op == "end" then
    track.ended = true
    return nil
  end
  if op == "program" then
    -- PROGRAM applies the source guard to the fully resolved integer BEFORE
    -- u16 storage (SND_seq.c 0x81: if (par < 0x10000) program = (u16)par):
    -- a negative dynamic value passes the guard and wraps (so -1 selects
    -- program 65535), while 65536 and larger leave the previous program
    -- unchanged.
    local par = resolveAmount(self, instruction.program, instance)
    if par < 65536 then
      track.program = toU16(par)
    end
  elseif op == "jump" then
    return instruction.target
  elseif op == "call" then
    -- CALL shares the one control stack with LOOP_BEGIN: a push beyond the
    -- depth-three capacity consumes the operand without pushing or jumping
    -- (a source no-op, never a host error).
    if #track.controlStack < CONTROL_STACK_MAX then
      track.controlStack[#track.controlStack + 1] = { kind = "call", returnIndex = track.pc + 1 }
      return instruction.target
    end
  elseif op == "return" then
    -- The SDK's 0xFD with an empty control stack (depth 0) is a no-op:
    -- real tracks end with a top-level return, and mid-program top-level
    -- returns fall through to the next instruction. With a nonzero depth the
    -- top shared frame -- a call or loop frame -- pops and the player jumps
    -- to its return position exactly like the source posCallStack.
    if #track.controlStack > 0 then
      return table.remove(track.controlStack).returnIndex
    end
  elseif op == "open_track" then
    -- Reopening releases channels and restarts the existing track object;
    -- allocation defaults belong only to a newly acquired pool object.
    local previous = instance.tracks[instruction.track]
    if previous ~= nil and previous ~= track then
      releaseTrackVoices(self, instance, previous)
      startTrack(previous, instruction.target)
    end
  elseif op == "compare" then
    local left = toS16(varRead(self, instance, instruction.var))
    local right = toS16(resolveAmount(self, instruction.amount, instance))
    if instruction.condition == "eq" then
      track.compare = left == right
    elseif instruction.condition == "ge" then
      track.compare = left >= right
    elseif instruction.condition == "gt" then
      track.compare = left > right
    elseif instruction.condition == "le" then
      track.compare = left <= right
    elseif instruction.condition == "lt" then
      track.compare = left < right
    elseif instruction.condition == "ne" then
      track.compare = left ~= right
    else
      assert(false, "unsupported comparison condition " .. tostring(instruction.condition))
    end
  elseif op == "tempo" then
    -- 0xE1: the resolved value narrows to s16 (the source union cast) and
    -- stores into the u16 destination domain, so a resolved -1 becomes the
    -- interval increment 65535.
    instance.tempo = toU16(toS16(resolveAmount(self, instruction.amount, instance)))
  elseif op == "pan" then
    -- 0xC0: resolve as u8, subtract 0x40, then store the raw offset as s8.
    track.pan = toS8(toU8(resolveAmount(self, instruction.amount, instance)) - 64)
    pushTrackValues(self, instance, track)
  elseif op == "volume" then
    track.volume = toU8(resolveAmount(self, instruction.amount, instance))
    pushTrackValues(self, instance, track)
  elseif op == "master_volume" then
    -- 0xC2 is the PLAYER volume: it changes every voice of the player.
    instance.sequenceVolume = toU8(resolveAmount(self, instruction.amount, instance))
    for trackId = 0, TRACK_COUNT - 1 do
      local masterTrack = instance.tracks[trackId]
      if masterTrack ~= nil then
        pushTrackValues(self, instance, masterTrack)
      end
    end
  elseif op == "expression" then
    track.expression = toU8(resolveAmount(self, instruction.amount, instance))
    pushTrackValues(self, instance, track)
  elseif op == "transpose" then
    -- The transpose class is the signed byte: 0xFF lowers to -1.
    track.transpose = toS8(resolveAmount(self, instruction.amount, instance))
  elseif op == "pitch_bend" then
    -- The signed bend maps to the voice's user pitch (never a key change);
    -- a change reaches the active voices as a queued userPitch partial.
    track.bend = toS8(resolveAmount(self, instruction.amount, instance))
    pushTrackValues(self, instance, track)
  elseif op == "pitch_bend_range" then
    -- 0xC5: the bend range is a LIVE channel control: the recomputed user
    -- pitch reaches every attached non-releasing voice immediately (the
    -- source TrackUpdateChannel pitch = bend * (range << 6) >> 7), with no
    -- note restart; attached releasing voices still receive the fader only.
    -- With no attached voice the track state alone changes and the next
    -- note starts at the new range.
    track.bendRange = toU8(resolveAmount(self, instruction.amount, instance))
    pushTrackValues(self, instance, track)
  elseif op == "note_wait" then
    -- 0xC7 sets/clears the note-gating flag (u8, nonzero = set).
    track.noteWait = toU8(resolveAmount(self, instruction.amount, instance)) ~= 0
  elseif op == "priority" then
    track.priority = toU8(resolveAmount(self, instruction.amount, instance))
  elseif op == "tie" then
    -- 0xC8: the tie command always releases and frees the track's current
    -- voices, even when the new flag equals the previous flag (SND_seq.c:
    -- TrackReleaseChannels + TrackFreeChannels after setting the flag); a
    -- tied note over an active voice reuses it.
    track.tie = toU8(resolveAmount(self, instruction.amount, instance)) ~= 0
    releaseTrackVoices(self, instance, track)
  elseif op == "mute" then
    -- SDK TrackMute: 0 unmutes, 1 mutes future notes (they still gate the
    -- track), 2 additionally releases the track's voices but leaves the
    -- handles attached -- the releasing voices keep receiving fader-only
    -- updates until the mixer reports them dead (release without free) --
    -- and 3 is the fast release + free: it releases with the forced
    -- override 127 and immediately detaches the handles while the physical
    -- release tails may continue. Other mode values are no-ops.
    local mode = toU8(resolveAmount(self, instruction.amount, instance))
    if mode == 0 then
      track.mute = 0
    elseif mode == 1 then
      track.mute = 1
    elseif mode == 2 then
      track.mute = 2
      -- The SDK TrackMute release-without-free: TrackReleaseChannels first
      -- delivers the current full track values to the attached channels,
      -- then starts the ordinary release; the handles stay attached.
      pushTrackValues(self, instance, track)
      for index = 1, #track.voices do
        noteOff(self, track.voices[index])
      end
    elseif mode == 3 then
      track.mute = 3
      releaseTrackVoices(self, instance, track, 127)
    end
  elseif op == "attack" then
    track.attack = envelopeOverride(toU8(resolveAmount(self, instruction.amount, instance)))
  elseif op == "decay" then
    track.decay = envelopeOverride(toU8(resolveAmount(self, instruction.amount, instance)))
  elseif op == "sustain" then
    track.sustain = envelopeOverride(toU8(resolveAmount(self, instruction.amount, instance)))
  elseif op == "release" then
    track.release = envelopeOverride(toU8(resolveAmount(self, instruction.amount, instance)))
  elseif op == "setvar" then
    -- B-class variable operations: the resolved amount narrows to s16 before
    -- the variable arithmetic uses it (the SDK union cast of the parsed
    -- value), and every store wraps to the s16 variable domain.
    varWrite(self, instance, instruction.var, toS16(resolveAmount(self, instruction.amount, instance)))
  elseif op == "addvar" then
    varWrite(
      self,
      instance,
      instruction.var,
      varRead(self, instance, instruction.var) + toS16(resolveAmount(self, instruction.amount, instance))
    )
  elseif op == "subvar" then
    varWrite(
      self,
      instance,
      instruction.var,
      varRead(self, instance, instruction.var) - toS16(resolveAmount(self, instruction.amount, instance))
    )
  elseif op == "mulvar" then
    varWrite(
      self,
      instance,
      instruction.var,
      varRead(self, instance, instruction.var) * toS16(resolveAmount(self, instruction.amount, instance))
    )
  elseif op == "divvar" then
    -- The SDK skips the division by zero; the quotient truncates toward
    -- zero (C integer division, negative divisors included).
    local divisor = toS16(resolveAmount(self, instruction.amount, instance))
    if divisor ~= 0 then
      varWrite(self, instance, instruction.var, NnsSoundMath.cDiv(varRead(self, instance, instruction.var), divisor))
    end
  elseif op == "shiftvar" then
    -- A nonnegative shift moves left (wrapped to s16); a negative shift
    -- moves right (arithmetic).
    local shift = toS16(resolveAmount(self, instruction.amount, instance))
    local value = varRead(self, instance, instruction.var)
    if shift >= 0 then
      varWrite(self, instance, instruction.var, bit.lshift(value, shift))
    else
      varWrite(self, instance, instruction.var, bit.arshift(value, -shift))
    end
  elseif op == "randomvar" then
    -- The SDK maps the u16 random draw into 0..|par| with the TrackParseValue
    -- integer scaling and negates for a negative par.
    local par = toS16(resolveAmount(self, instruction.amount, instance))
    local neg = par < 0
    if neg then
      par = toS16(-par)
    end
    local random = bit.arshift(toS32(self._rng() * (par + 1)), 16)
    if neg then
      random = -random
    end
    varWrite(self, instance, instruction.var, random)
  elseif op == "nop" then
    -- The reserved no-op opcodes of the corpus (0x82-0x8F, 0x90-0x92,
    -- 0x96-0x9F, 0xA3-0xAF, 0xB7, 0xBE-0xBF, 0xD8-0xDF, 0xE2, 0xE4-0xEF,
    -- 0xF0-0xFB, 0xFE): the SDK consumes them without effect.
  elseif op == "mod_depth" then
    -- 0xCA-0xCD/0xE0: the mod fields are u8/u16 binary values stored as
    -- their C types, so resolved out-of-domain amounts wrap. A change
    -- reaches the active voices as a queued partial carrying the live LFO
    -- parameters.
    track.mod.depth = toU8(resolveAmount(self, instruction.amount, instance))
    pushTrackValues(self, instance, track)
  elseif op == "mod_speed" then
    track.mod.speed = toU8(resolveAmount(self, instruction.amount, instance))
    pushTrackValues(self, instance, track)
  elseif op == "mod_type" then
    track.mod.target = toU8(resolveAmount(self, instruction.amount, instance))
    pushTrackValues(self, instance, track)
  elseif op == "mod_range" then
    track.mod.range = toU8(resolveAmount(self, instruction.amount, instance))
    pushTrackValues(self, instance, track)
  elseif op == "mod_delay" then
    -- 0xE0: the u16 delay stores through the source u16 destination domain,
    -- so a resolved -1 becomes 65535.
    track.mod.delay = toU16(resolveAmount(self, instruction.amount, instance))
    pushTrackValues(self, instance, track)
  elseif op == "sweep" then
    -- 0xE3: the s16 track sweep pitch.
    track.sweepPitch = toS16(resolveAmount(self, instruction.amount, instance))
  elseif op == "portamento_key" then
    -- 0xC9: the u8 key plus the track transpose, stored in the u8 domain;
    -- the sum wraps on the store.
    track.portamentoKey = toU8(toU8(resolveAmount(self, instruction.amount, instance)) + track.transpose)
    track.portamento = true
  elseif op == "portamento" then
    -- 0xCE: the u8 flag (truthiness after narrowing).
    track.portamento = toU8(resolveAmount(self, instruction.amount, instance)) ~= 0
  elseif op == "portamento_time" then
    -- 0xCF: the u8 sweep time.
    track.portamentoTime = toU8(resolveAmount(self, instruction.amount, instance))
  elseif op == "loop_begin" then
    -- LOOP_BEGIN shares the one control stack with CALL: the frame carries
    -- its kind, the count, and the return index (the instruction after the
    -- begin, the SDK's posCallStack). A push beyond the depth-three
    -- capacity consumes the count without pushing (a source no-op, never a
    -- host error).
    if #track.controlStack < CONTROL_STACK_MAX then
      track.controlStack[#track.controlStack + 1] = {
        kind = "loop",
        remaining = toU8(resolveAmount(self, instruction.count, instance)),
        returnIndex = track.pc + 1,
      }
    end
  elseif op == "loop_end" then
    local frame = track.controlStack[#track.controlStack]
    if frame == nil then
      -- The SDK's 0xFC at depth 0 is a no-op; the real corpus has tracks
      -- whose loop code is never entered (dead bytes), so an unmatched
      -- loop_end must never fault.
    else
      -- A call frame on top of the shared stack at loop_end is an
      -- impossible source nesting: the generated bytecode is the only
      -- producer and its nesting is valid, so this is a programming/asset
      -- invariant failure, never silently repaired.
      assert(frame.kind == "loop", "loop_end over a call frame on the shared control stack")
      if frame.remaining > 0 then
        frame.remaining = frame.remaining - 1
        if frame.remaining == 0 then
          -- The count reached zero: pop the frame and fall through.
          table.remove(track.controlStack)
        else
          -- The body runs again: jump back to the instruction after the
          -- begin.
          return frame.returnIndex
        end
      else
        -- Count 0 loops forever (the SDK's loopCount-0 branch; the real
        -- SEQ_GS_P_SAFARI_ROAD rings until the game stops it).
        return frame.returnIndex
      end
    end
  else
    -- The sequence validator admits only the ops above, so an unknown op is
    -- a programmer fault, never a silent no-op.
    assert(false, "unsupported sequence instruction op " .. tostring(op) .. " at pc " .. tostring(track.pc))
  end
  return track.pc + 1
end

-- Executes instructions until the track is gated (waiting on a note or
-- wait) or ended, with a bounded step budget so a runaway non-gating
-- loop fails instead of hanging. A program counter past the instruction
-- list is a fall-through past the last instruction (a top-level return, an
-- SDK no-op): the track ends instead of reading beyond the program.
local function fetch(self, instance, track)
  local steps = 0
  while not track.ended and not track.gated and not track.noteFinishWait do
    local instruction = instance.sequence.program.instructions[track.pc]
    if instruction == nil then
      track.ended = true
      break
    end
    local pc = track.pc
    track.pc = execute(self, instance, track, instruction)
    local observer, callback = observerCallback(self, "onTrackStep")
    if callback ~= nil then
      callback(observer, {
        ordinal = self._intervalOrdinal,
        playerId = instance.logicalPlayerId,
        trackSlot = track.slot,
        pc = pc,
        op = instruction.op,
        wait = track.wait,
        program = track.program,
        compare = track.compare,
      })
    end
    steps = steps + 1
    if steps > HOST_SAFETY_STEP_BUDGET then
      Errors.raise(
        AudioErrors.AUDIO_PLAYER_UNBOUNDED_EXECUTION,
        "sequence executed too many instructions without a wait",
        {
          playerId = instance.logicalPlayerId,
        }
      )
    end
  end
end

local function releaseInstance(self, instance)
  for trackId = 0, TRACK_COUNT - 1 do
    local track = instance.tracks[trackId]
    if track ~= nil then
      releaseTrackVoices(self, instance, track)
      releaseTrackObject(self, track)
    end
  end
end

local retireInstance

-- Releases only the bidirectional handle attachment. The active instance keeps
-- its logical membership, physical slot, tracks, voices, and priority until a
-- separate retirement path disposes it.
local function detachHandle(self, handle)
  local instance = self._handleAttachments[handle]
  if instance == nil then
    return
  end
  assert(instance.handle == handle, "handle attachment is not reciprocal")
  self._handleAttachments[handle] = nil
  instance.handle = nil
end

local function retireTrack(self, instance, trackId, reason)
  local track = instance.tracks[trackId]
  assert(track ~= nil, "track must be attached before retirement")
  releaseTrackVoices(self, instance, track)
  releaseTrackObject(self, track)
  instance.tracks[trackId] = nil
  local observer, callback = observerCallback(self, "onTrackRetirement")
  if callback ~= nil then
    callback(observer, {
      logicalPlayerId = instance.logicalPlayerId,
      seqPlayerSlot = instance.seqPlayerSlot,
      trackSlot = trackId,
      poolIndex = track.poolIndex,
      reason = reason,
    })
  end

  for remaining = 0, TRACK_COUNT - 1 do
    local remainingTrack = instance.tracks[remaining]
    if remainingTrack ~= nil and remainingTrack.pc ~= nil and not remainingTrack.ended then
      return true
    end
  end
  retireInstance(self, instance, "natural_completion")
  return false
end

-- Retires one instance from both ownership structures. Callers must pass an
-- active instance; the assertions make an ownership split fail immediately.
function retireInstance(self, instance, reason)
  assert(instance ~= nil and not instance.retired, "instance must be active")
  local slot = self._seqPlayers[instance.seqPlayerSlot]
  assert(slot == instance, "physical slot does not own instance")
  local logicalPlayer = self._logicalPlayers[instance.logicalPlayerId]
  assert(logicalPlayer ~= nil, "logical player record is missing")
  local instances = logicalPlayer.instances
  local found = false
  for index = 1, #instances do
    if instances[index] == instance then
      table.remove(instances, index)
      found = true
      break
    end
  end
  assert(found, "logical player does not own instance")
  releaseInstance(self, instance)
  self._seqPlayers[instance.seqPlayerSlot] = nil
  appendFreeSeqPlayerSlot(self, instance.seqPlayerSlot)
  instance.retired = true
  local handle = instance.handle
  if handle ~= nil and self._handleAttachments[handle] == instance then
    self._handleAttachments[handle] = nil
  end
  instance.handle = nil
  local observer, callback = observerCallback(self, "onSequenceRetirement")
  if callback ~= nil then
    callback(observer, {
      logicalPlayerId = instance.logicalPlayerId,
      seqPlayerSlot = instance.seqPlayerSlot,
      instanceId = instance.id,
      reason = reason,
    })
  end
end

---@param opts { sampleRate: number, mixer: table<string, unknown>, provider: table<string, unknown>, observer?: table<string, unknown>, rng?: fun(): number }
---@return SequencePlayer
function SequencePlayer.new(opts)
  assert(
    opts and opts.sampleRate and opts.mixer and opts.provider,
    "SequencePlayer requires sampleRate, mixer and provider"
  )
  local freeSeqPlayerSlots = {}
  for slot = 0, PLAYER_COUNT - 1 do
    freeSeqPlayerSlots[#freeSeqPlayerSlots + 1] = slot
  end
  return setmetatable({
    _sampleRate = opts.sampleRate,
    _mixer = opts.mixer,
    _provider = opts.provider,
    _observer = opts.observer,
    _logicalPlayers = {},
    _seqPlayers = {},
    _freeSeqPlayerSlots = freeSeqPlayerSlots,
    _nextInstanceId = 1,
    _trackCount = 0,
    _trackPool = {},
    _handles = {},
    _handleAttachments = {},
    -- The player-scoped RNG (injected or the deterministic default): plays
    -- share it and never reseed, so random operands stay reproducible.
    _rng = opts.rng or newRng(),
    -- The SDK shared global variables (vars 16..31), initialized to -1 once
    -- for the lifetime of the player object (SND_seq.c SND_work_shared
    -- globalVars): writes by any sequence persist across plays. The
    -- player-local variables live on each instance and reset per play.
    _globalVars = newVariableDomain(),
    -- The global 192 Hz sound phase accumulator (SND_main.c SndThread):
    -- each rendered output frame advances the phase by SOUND_INTERVAL_HZ
    -- units; when the phase reaches the sample rate a sound interval fires
    -- and the sample rate is subtracted. Owned here for the lifetime of the
    -- player; plays and stops never reset it, so the clock is continuous
    -- across idle frames and sequence replacements.
    _soundPhase = 0,
    _intervalOrdinal = 0,
  }, SequencePlayer) --[[@as SequencePlayer]]
end

function SequencePlayer:createHandle()
  local handle = {}
  self._handles[handle] = true
  return handle
end

-- Shared instance creation for sequence starts. `enforceBank` controls
-- whether a mismatched bank id is rejected (ordinary play) or allowed
-- (explicit donor-bank override).
local function startSequenceInstance(self, handle, sequence, bank, enforceBank, ordinarySequence)
  validateHandle(self, handle)
  assert(sequence and bank, "play requires a sequence and a bank")
  if enforceBank and bank.id ~= sequence.bankId then
    Errors.raise(
      AudioErrors.AUDIO_PLAYER_BANK_MISMATCH,
      "bank " .. tostring(bank.id) .. " does not match sequence bankId " .. tostring(sequence.bankId),
      {
        bankId = bank.id,
        sequenceBankId = sequence.bankId,
      }
    )
  end
  local logicalPlayerId = sequence.player.id
  assert(logicalPlayerId >= 0 and logicalPlayerId < LOGICAL_PLAYER_COUNT, "logical player id must be in 0..31")
  local initialTrackMask = sequence.program.initialTrackMask
  local playerRecord = self._provider:player(logicalPlayerId)
  local channelMask = playerRecord.channelMask == 0 and 0xFFFF or playerRecord.channelMask
  detachHandle(self, handle)
  local logicalPlayer = self._logicalPlayers[logicalPlayerId]
  if logicalPlayer == nil then
    logicalPlayer = { instances = {} }
    self._logicalPlayers[logicalPlayerId] = logicalPlayer
  end
  local instances = logicalPlayer.instances
  local logicalVictim
  if #instances >= playerRecord.maxSequences then
    for index = 1, #instances do
      local candidate = instances[index]
      if
        logicalVictim == nil
        or candidate.sequence.player.playerPriority < logicalVictim.sequence.player.playerPriority
        or (
          candidate.sequence.player.playerPriority == logicalVictim.sequence.player.playerPriority
          and candidate.id < logicalVictim.id
        )
      then
        logicalVictim = candidate
      end
    end
    if sequence.player.playerPriority < logicalVictim.sequence.player.playerPriority then
      local observer, callback = observerCallback(self, "onSequenceAllocation")
      if callback ~= nil then
        callback(observer, {
          playerId = logicalPlayerId,
          logicalPlayerId = logicalPlayerId,
          accepted = false,
          playerPriority = sequence.player.playerPriority,
          reason = "logical_priority",
        })
      end
      return false
    end
    retireInstance(self, logicalVictim, "logical_eviction")
  end

  local seqPlayerSlot = popFreeSeqPlayerSlot(self)
  if seqPlayerSlot == nil then
    local globalVictim
    for candidateSlot = 0, PLAYER_COUNT - 1 do
      local candidate = self._seqPlayers[candidateSlot]
      if
        globalVictim == nil
        or candidate.sequence.player.playerPriority < globalVictim.sequence.player.playerPriority
        or (
          candidate.sequence.player.playerPriority == globalVictim.sequence.player.playerPriority
          and candidate.id < globalVictim.id
        )
      then
        globalVictim = candidate
      end
    end
    if sequence.player.playerPriority < globalVictim.sequence.player.playerPriority then
      local observer, callback = observerCallback(self, "onSequenceAllocation")
      if callback ~= nil then
        callback(observer, {
          playerId = logicalPlayerId,
          logicalPlayerId = logicalPlayerId,
          accepted = false,
          playerPriority = sequence.player.playerPriority,
          reason = "physical_priority",
        })
      end
      return false
    end
    retireInstance(self, globalVictim, "physical_eviction")
    seqPlayerSlot = popFreeSeqPlayerSlot(self)
    assert(seqPlayerSlot ~= nil, "retired global victim did not free a physical slot")
  end

  local instance = {
    id = self._nextInstanceId,
    logicalPlayerId = logicalPlayerId,
    handle = handle,
    seqPlayerSlot = seqPlayerSlot,
    sequence = sequence,
    ordinarySequenceId = ordinarySequence and sequence.id or nil,
    bank = bank,
    channelMask = channelMask,
    -- The source PlayerInit fields (SND_seq.c): tempo 120, tempoRatio 256,
    -- tempoCounter 240 -- the counter that produces the first sequence tick
    -- on the first sound interval after play.
    tempo = DEFAULT_TEMPO,
    tempoRatio = 256,
    tempoCounter = SND_TIMER_RATE,
    -- The player-level volume (the NNS player->volume): starts at the
    -- sequence's initial volume; master_volume commands change it.
    sequenceVolume = 127,
    outerPlayerVolume = sequence.player.initialVolume,
    -- The player-level fader (the NNS player fader NNS_SndPlayerMoveVolume
    -- drives): a volume-domain level, full by default; GameSound's fade
    -- state moves it and the control-step push delivers its dB-domain
    -- attenuation to the player's voices.
    outerFaderDb = NnsSoundMath.decibel(127),
    -- External handle-level user pitch, kept separate from the track's
    -- SSEQ bend state and reset for every new sequence instance.
    externalTrackPitch = 0,
    -- The transport pause flag (NNS SND_PlayerPause): while paused the
    -- timeline freezes and no control values are pushed; the pause release
    -- already freed the channels.
    paused = false,
    -- The 16 player-local SDK variables (vars 0..15), initialized to -1 on
    -- every play/replacement (SND_seq.c PlayerInit localVars): writes do not
    -- survive a sequence replacement, unlike the shared globals.
    localVars = newVariableDomain(),
    tracks = {},
  }

  local entryTrack = allocateTrack(self, 0)
  if entryTrack == nil then
    appendFreeSeqPlayerSlot(self, seqPlayerSlot)
    local observer, callback = observerCallback(self, "onSequenceAllocation")
    if callback ~= nil then
      callback(observer, {
        playerId = logicalPlayerId,
        logicalPlayerId = logicalPlayerId,
        seqPlayerSlot = seqPlayerSlot,
        accepted = false,
        playerPriority = sequence.player.playerPriority,
        reason = "track_capacity",
      })
    end
    return false
  end
  instance.tracks[0] = entryTrack
  startTrack(entryTrack, sequence.program.entry)
  for trackSlot = 1, TRACK_COUNT - 1 do
    if bit.band(initialTrackMask, bit.lshift(1, trackSlot)) ~= 0 then
      local track = allocateTrack(self, trackSlot)
      if track == nil then
        break
      end
      instance.tracks[trackSlot] = track
    end
  end
  self._nextInstanceId = self._nextInstanceId + 1
  instances[#instances + 1] = instance
  self._seqPlayers[seqPlayerSlot] = instance
  self._handleAttachments[handle] = instance
  local observer, callback = observerCallback(self, "onSequenceAllocation")
  if callback ~= nil then
    callback(observer, {
      playerId = logicalPlayerId,
      logicalPlayerId = logicalPlayerId,
      seqPlayerSlot = seqPlayerSlot,
      instanceId = instance.id,
      playerPriority = sequence.player.playerPriority,
      accepted = true,
    })
  end
  return true
end

-- Starts `sequence` on its player id with `bank`. The bank must be the
-- sequence's bankId; a full player steals only an eligible lower/equal
-- priority instance. The instance is initialized to the source PlayerInit
-- state (tempo 120, tempoRatio 256, tempoCounter 240) and the entry track
-- is armed, but play() does not fetch or execute the entry program: the
-- (tempoCounter 240 naturally produces it). The global sound phase and the
-- shared RNG are never reset by a play.
function SequencePlayer:play(handle, sequence, bank)
  return startSequenceInstance(self, handle, sequence, bank, true, true)
end

-- Starts a provider-independent sequence without assigning it an SDAT
-- sequence number. Synthetic callers must not collide with ordinary IDs.
function SequencePlayer:playSynthetic(handle, sequence, bank)
  return startSequenceInstance(self, handle, sequence, bank, true, false)
end

-- Starts `sequence` with an explicit donor bank whose id may differ from
-- `sequence.bankId`. This is the sole bank-mismatch exception for
-- environmental soundplates that use the base field BGM's bank. Every other
-- player/channel/sequence invariant is identical to ordinary play.
function SequencePlayer:playWithBankOverride(handle, sequence, bank)
  return startSequenceInstance(self, handle, sequence, bank, false, true)
end

-- Sets the player's fader level (0..127, the volume domain -- the NNS
-- player fader NNS_SndPlayerMoveVolume drives). The attenuation reaches the
-- player's voices immediately as a queued dB-domain fader event
-- (NnsSoundMath.decibel; the mixer clamps at -0x8000). The GameSound
-- fade state is the caller; a player with no active instance is a no-op.
---@param handle table<string, unknown>
---@param level integer
---@return nil
function SequencePlayer:setHandleFader(handle, level)
  validateHandle(self, handle)
  assert(level >= 0 and level <= 127 and level % 1 == 0, "fader level must be an integer in 0..127")
  local instance = self._handleAttachments[handle]
  if instance == nil then
    return
  end
  instance.outerFaderDb = NnsSoundMath.decibel(level)
  for trackId = 0, TRACK_COUNT - 1 do
    local track = instance.tracks[trackId]
    if track ~= nil then
      pushTrackValues(self, instance, track)
    end
  end
end

-- Adds an external user-pitch offset to every track attached to one handle.
-- This is a live channel control: active voices receive the resulting pitch
-- through the same update queue as SSEQ track controls, while new voices use
-- the instance value in their initial note spec.
---@param handle table<string, unknown>
---@param pitch integer
---@return nil
function SequencePlayer:setHandleTrackPitch(handle, pitch)
  validateHandle(self, handle)
  assert(
    type(pitch) == "number"
      and pitch == pitch
      and pitch ~= math.huge
      and pitch ~= -math.huge
      and pitch == math.floor(pitch),
    "track pitch must be a finite integer"
  )
  local instance = self._handleAttachments[handle]
  if instance == nil then
    return
  end
  instance.externalTrackPitch = pitch
  for trackId = 0, TRACK_COUNT - 1 do
    local track = instance.tracks[trackId]
    if track ~= nil then
      pushTrackValues(self, instance, track)
    end
  end
end

-- Pauses the sequence on `handle` (the NNS SND_PlayerPause transport
-- pause the HGSS PlayFanfare path uses): the instance stays held
-- (isPlayerPlaying stays true) but its tick timeline freezes, no control
-- values are pushed, and the player's current track channels are released
-- with the forced release override 127 and freed from the tracks -- the
-- SDK pause releases and frees channels, preserving no sample or envelope
-- state for resumption. A player with no active instance, or one already
-- paused, is a no-op.
---@param handle table<string, unknown>
---@return nil
function SequencePlayer:pauseHandle(handle)
  validateHandle(self, handle)
  local instance = self._handleAttachments[handle]
  if instance == nil or instance.paused then
    return
  end
  instance.paused = true
  for trackId = 0, TRACK_COUNT - 1 do
    local track = instance.tracks[trackId]
    if track ~= nil then
      releaseTrackVoices(self, instance, track, 127)
    end
  end
end

---@param handle table<string, unknown>
---@return nil
function SequencePlayer:resumeHandle(handle)
  validateHandle(self, handle)
  local instance = self._handleAttachments[handle]
  if instance ~= nil then
    instance.paused = false
  end
end

---@param handle table<string, unknown>
---@return nil
function SequencePlayer:stopHandle(handle)
  validateHandle(self, handle)
  local instance = self._handleAttachments[handle]
  if instance ~= nil then
    retireInstance(self, instance, "stop_handle")
  end
end

-- Releases only the handle attachment. The active instance remains owned by
-- its logical player and physical slot.
---@param handle table<string, unknown>
---@return nil
function SequencePlayer:releaseHandle(handle)
  validateHandle(self, handle)
  detachHandle(self, handle)
end

function SequencePlayer:isHandlePlaying(handle)
  validateHandle(self, handle)
  local instance = self._handleAttachments[handle]
  if instance == nil then
    return false
  end
  for trackId = 0, TRACK_COUNT - 1 do
    local track = instance.tracks[trackId]
    if track ~= nil and track.pc ~= nil and not track.ended then
      return true
    end
  end
  return false
end

-- Executes one source sequence tick for one active, unpaused player
-- (SND_seq.c PlayerStepTicks): every live track of the player steps
-- ascending track id 0..15, following the TrackStepTicks order -- dead
-- handles are pruned first, then each attached voice's remaining length
-- expires (ordinary release at zero, independent of gates) and its non-auto
-- sweep advances once through the mixer, then the note-finish hold clears
-- only once all attached handles are gone (an attached release tail keeps
-- it blocked), then the gate's integer wait decrements, and a track whose
-- wait reached exactly zero fetches its following instructions (its command
-- loop runs until it gates again or ends). `processSoundInterval` calls
-- this once per tick the player's tempoCounter produces; it owns no frame
-- timing of its own.
local function stepSequenceTick(self, instance)
  for trackId = 0, TRACK_COUNT - 1 do
    local track = instance.tracks[trackId]
    if track ~= nil and track.pc ~= nil then
      -- 1. Dead/stolen handles leave the collection first, so a release or
      -- a later note never touches a stale handle.
      pruneTrackVoices(self, track)
      -- 2. Each attached voice's own length expires at its tick boundary
      -- (the NNS channel length): only positive finite lengths decrement,
      -- and an expired voice starts an ordinary release at zero while its
      -- record STAYS attached and marked releasing (TrackReleaseChannels
      -- without TrackFreeChannels) until the mixer reports it dead. Tied
      -- and non-positive-length voices are indefinite and are never
      -- released by the counter. Every still-attached live voice also gets
      -- exactly one non-auto sweep advancement through the mixer's
      -- explicit track-tick operation (TrackStepTicks advances every linked
      -- non-auto-sweep channel's counter once per tick); an auto-sweep
      -- voice is untouched here, and a voice whose length just expired is
      -- advanced once before its release starts.
      for index = 1, #track.voices do
        local voice = track.voices[index]
        -- Every still-attached live voice gets exactly one non-auto sweep
        -- advancement through the mixer's explicit track-tick operation
        -- (TrackStepTicks advances every linked non-auto-sweep channel's
        -- counter once per tick, releasing voices included -- the release
        -- keeps the channel linked, so its portamento slide continues
        -- through the tail); an auto-sweep voice is untouched here. The
        -- advance happens BEFORE the length expiry marks its release.
        self._mixer:advanceTrackTick(voice.handle)
        if voice.length > 0 then
          voice.length = voice.length - 1
        end
      end
      -- 3. The note-finish hold clears on the first tick whose live handles
      -- are all gone (SND_seq.c TrackStepTicks: the note_finish_wait check
      -- runs per tick over the track's channel list; the wait clears when
      -- the list is empty and the track resumes in the same tick). An
      -- attached release tail keeps the hold blocked even though the
      -- sequence note length reached zero earlier; a voice the mixer
      -- reported dead was already pruned and cannot keep the hold alive.
      -- The hold blocks only THIS track's wait/fetch (the source returns
      -- from the per-track TrackStepTicks); the other tracks of the player
      -- still step in the same pass.
      if not track.noteFinishWait or #track.voices == 0 then
        if track.noteFinishWait then
          track.noteFinishWait = false
        end
        -- 4. The gate: the integer wait decrements only while positive (the
        -- SDK TrackStepTicks `if (track->wait > 0) track->wait--`), so a
        -- negative wait never moves toward zero and the track stays stalled.
        if track.gated then
          if track.wait > 0 then
            track.wait = track.wait - 1
            if track.wait == 0 then
              track.gated = false
            end
          end
        end
        -- 5. Commands execute only at the exact zero wait (never `<= 0`): a
        -- negative wait never fetches, and a gated track whose wait is still
        -- positive waits for its remaining ticks.
        if not track.ended and not track.gated and track.wait == 0 and not track.noteFinishWait then
          fetch(self, instance, track)
        end
      end
      if self._seqPlayers[instance.seqPlayerSlot] == instance and track.ended then
        if not retireTrack(self, instance, trackId, "track_end") then
          return
        end
      end
    end
  end
end

local function releaseExpiredVoices(self, instance)
  for trackId = 0, TRACK_COUNT - 1 do
    local track = instance.tracks[trackId]
    if track ~= nil then
      pruneTrackVoices(self, track)
      for index = 1, #track.voices do
        local voice = track.voices[index]
        if voice.length == 0 and not voice.releasing then
          noteOff(self, voice)
        end
      end
    end
  end
end

-- Processes one completed 192 Hz sound interval in source order
-- (SND_main.c SndThread: SND_SeqMain, then SND_ExChannelMain, then the
-- unconditional SND_CalcRandom draw):
--   1. each active, unpaused physical SeqPlayer slot in ascending slot order
--      0..15 executes
--      one sequence tick per 240 subtracted from its tempoCounter while the
--      counter is at least 240, then adds tempoInc = (tempo * tempoRatio)
--      >> 8 exactly once after all of that interval's ticks (PlayerSeqMain);
--   2. the mixer runs exactly one control step;
--   3. one unconditional periodic RNG draw is consumed, whether or not an
--      explicit random command ran during the sequence portion.
-- A player whose last track ends during a tick is removed according to the
-- existing lifecycle (stopPlayer); remaining player ids still process in
-- ascending order. An error raised during the sequence portion propagates:
-- the interval did not complete, so mixer control and the periodic draw
-- are skipped and the render call fails.
local function processSoundInterval(self)
  local observer, callback = observerCallback(self, "onSoundInterval")
  if callback ~= nil then
    callback(observer, {
      ordinal = self._intervalOrdinal,
      phase = "before_sequence",
    })
  end
  for seqPlayerSlot = 0, PLAYER_COUNT - 1 do
    local instance = self._seqPlayers[seqPlayerSlot]
    if instance ~= nil and not instance.paused then
      while instance.tempoCounter >= SND_TIMER_RATE do
        instance.tempoCounter = instance.tempoCounter - SND_TIMER_RATE
        stepSequenceTick(self, instance)
        if self._seqPlayers[seqPlayerSlot] ~= instance then
          break
        end
      end
      if self._seqPlayers[seqPlayerSlot] == instance then
        instance.tempoCounter = instance.tempoCounter + math.floor(instance.tempo * instance.tempoRatio / 256)
        releaseExpiredVoices(self, instance)
      end
    end
  end
  observer, callback = observerCallback(self, "onSoundInterval")
  if callback ~= nil then
    callback(observer, {
      ordinal = self._intervalOrdinal,
      phase = "after_sequence",
    })
  end
  self._mixer:controlStep(self._intervalOrdinal)
  observer, callback = observerCallback(self, "onSoundInterval")
  if callback ~= nil then
    callback(observer, {
      ordinal = self._intervalOrdinal,
      phase = "after_channels",
    })
  end
  self._rng()
  self._intervalOrdinal = self._intervalOrdinal + 1
end

-- The frames until the next global sound-interval boundary from the
-- current phase: the span of output frames the mixer renders in one call
-- before the boundary fires. The end of the requested window is always a
-- boundary. Sequence ticks never shorten a span -- ticks are produced only
-- at the interval boundaries themselves.
local function spanLength(self, remaining)
  local framesToBoundary = math.ceil((self._sampleRate - self._soundPhase) / SOUND_INTERVAL_HZ)
  return math.min(remaining, framesToBoundary)
end

-- Renders `frames` output frames of interleaved stereo int16 PCM. The
-- renderer is a span scheduler around the pure PCM mixer: it renders up to
-- the next global 192 Hz sound-interval boundary, advances the global phase
-- by the span, and -- when the phase reaches the sample rate -- subtracts
-- the sample rate once and processes that interval (sequence ticks, then
-- one mixer control step, then the periodic RNG draw). The mixer is asked
-- for PCM even when no active sequence exists, so idle frames and detached
-- release tails keep the global clock and the periodic RNG running (the
-- mixer renders silence when no voices exist). Physical slots and tracks
-- process ascending over the fixed NNS domains. Instance-carried tempoCounter/wait
-- state and the global phase keep rendering independent of chunk size.
---@param frames integer
---@return integer[]
function SequencePlayer:render(frames)
  local out = {}
  local remaining = frames
  while remaining > 0 do
    local span = spanLength(self, remaining)
    assert(span >= 1, "a render span must advance the frame count")
    self._mixer:renderInto(out, span)
    self._soundPhase = self._soundPhase + SOUND_INTERVAL_HZ * span
    if self._soundPhase >= self._sampleRate then
      -- One rendered frame adds 192 units, so a span cannot cross more than
      -- one sample-rate threshold at the supported output rates.
      self._soundPhase = self._soundPhase - self._sampleRate
      processSoundInterval(self)
    end
    remaining = remaining - span
  end
  return out
end

-- Releases every voice of every active sequence and clears the players.
function SequencePlayer:stop()
  while true do
    local instance
    for seqPlayerSlot = 0, PLAYER_COUNT - 1 do
      instance = self._seqPlayers[seqPlayerSlot]
      if instance ~= nil then
        break
      end
    end
    if instance == nil then
      break
    end
    retireInstance(self, instance, "stop")
  end
end

-- Releases the voices of the sequence on `playerId` and removes it; a
-- player with no active instance is a no-op.
---@param playerId integer
function SequencePlayer:stopPlayer(playerId)
  local logicalPlayer = self._logicalPlayers[playerId]
  if logicalPlayer == nil then
    return
  end
  while #logicalPlayer.instances > 0 do
    retireInstance(self, logicalPlayer.instances[1], "stop_player")
  end
end

-- Releases every active ordinary sequence whose generated sequence ID matches;
-- the fixed physical-slot scan mirrors NNS_SndPlayerStopSeqBySeqNo and keeps
-- retirement in the single instance lifecycle path.
---@param sequenceId integer
function SequencePlayer:stopSequence(sequenceId)
  assert(sequenceId >= 0 and sequenceId % 1 == 0, "sequence id must be a non-negative integer")
  for seqPlayerSlot = 0, PLAYER_COUNT - 1 do
    local instance = self._seqPlayers[seqPlayerSlot]
    if instance ~= nil and instance.ordinarySequenceId == sequenceId then
      retireInstance(self, instance, "stop_sequence")
    end
  end
end

-- True while the sequence on `playerId` still has a running track; a player
-- whose sequence has ended (or was never started) reports free.
---@param playerId integer
---@return boolean
function SequencePlayer:isPlayerPlaying(playerId)
  local logicalPlayer = self._logicalPlayers[playerId]
  if logicalPlayer == nil then
    return false
  end
  local instances = logicalPlayer.instances
  for index = 1, #instances do
    for trackId = 0, TRACK_COUNT - 1 do
      local track = instances[index].tracks[trackId]
      if track ~= nil and track.pc ~= nil and not track.ended then
        return true
      end
    end
  end
  return false
end

-- True while any track of any active sequence is still running.
function SequencePlayer:isPlaying()
  for seqPlayerSlot = 0, PLAYER_COUNT - 1 do
    local instance = self._seqPlayers[seqPlayerSlot]
    if instance ~= nil then
      for trackId = 0, TRACK_COUNT - 1 do
        local track = instance.tracks[trackId]
        if track ~= nil and track.pc ~= nil and not track.ended then
          return true
        end
      end
    end
  end
  return false
end

return SequencePlayer
