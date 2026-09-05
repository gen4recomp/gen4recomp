-- Deterministic 16-channel DS sound engine per the ARM7 NitroSDK
-- (SND_exChannel.c, SND_util.c, SND_bank.c, SND_seq.c) and GBATEK
-- ("DS Sound" chapter). The mixer owns per-voice NNS channel behavior and
-- the physical host boundary; the 192 Hz control cadence belongs to the
-- external scheduler, which drives it through one controlStep per sound
-- interval:
--   * Volume is a dB-like integer sum per control step
--     (SNDi_DecibelSquareTable[velocity] + envAttenuation>>7 +
--     DecibelSquare[trackVolume] + DecibelSquare[expression] +
--     DecibelSquare[sequenceVolume] + fader), converted once per step by
--     SND_CalcChannelVolume; the host gain is the register mantissa N/128
--     (127 -> 128) >> sSampleDataShiftTable.
--   * The envelope is the SDK state machine (SND_SetExChannelAttack
--     coefficients, CalcDecayCoeff decay/release with the 127/126 special
--     cases, DecibelSquare[sustain]<<7 decay target); a release voice
--     stops at the control step whose current pre-register dB sum crosses
--     SND_VOL_DB_MIN (vol <= -723), the SDK's death moment -- never a
--     noteOff-time prediction. The envelope advances once per external
--     control step. noteOn synchronizes the initial registers without
--     consuming elapsed control time; external controlStep owns the first
--     elapsed 192 Hz advancement.
--   * Pitch is the integer domain (key - originalKey)*0x40 + userPitch
--     (the note's user pitch, default 0) + sweep + pitch LFO through
--     SND_CalcTimer (BIOS pitch table); square timers are masked with
--     0xFFFC and square/noise use the 8006 base timer. The host phase
--     increment is the DS sample clock/(timer*outputRate) for every
--     generator: the calculated NDS timer feeds the physical boundary,
--     never a MIDI frequency and never a source sample-rate header.
--   * Pan has three distinct domains: the instrument pan (initPan =
--     pan - 0x40), the track pan offset (TrackUpdateChannel: scaled by
--     panRange, starts 0), and the final hardware register (initPan +
--     userPan + 0x40, clamped 0..127) feeding the linear hardware mix
--     (128-N)/128 and N/128 with register 127 as N=128.
--   * Allocation is SND_AllocExChannel: the fixed order
--     {4,5,6,7,2,0,3,1,8,9,10,11,14,12,15,13} inside (generator range AND
--     channelMask); the victim is the lowest effective priority
--     channel/track priority and among equals the
--     quieter last-synced volume register; an incoming note below the
--     victim's priority is rejected; a stolen channel revokes the previous
--     voice handle. noteOn returns {channel, generation} with the
--     generation a persistent per-channel counter (incremented on every
--     allocation of the channel, never derived from the victim, so a
--     naturally freed channel never reuses an old generation) or nil;
--     noteOff/updateVoice/isVoiceAlive on a stale handle are harmless.
--   * LFO (SND_UpdateLfo/SND_GetLfoValue/SND_SinIdx) and sweep
--     (ExChannelSweepUpdate) state machines run per control step and feed
--     the pitch/volume/pan calculations; the sweep counter has exactly one
--     owner per auto flag (TrackStepTicks vs ExChannelMain): a non-auto
--     voice advances it once per sequence tick through the explicit
--     advanceTrackTick(handle) -- capped at the sweep length -- and an
--     auto voice advances it at control steps only. noteOn contributes the
--     full initial sweepPitch without advancing elapsed control time or the
--     sweep counter.
--   * Square duty is the discrete integer 0..7 index consumed directly
--     (8-sample cycle starting at LOW, HIGH=(d+1)*12.5%; duty 7 is the
--     all-LOW special pattern); noise is the 15-bit LFSR from 7FFFh
--     (X = X SHR 1; carry -> LOW and X = X XOR 6000h, else HIGH).
-- Queued control values (updateVoice) apply at the next explicit
-- controlStep; renderInto is a pure PCM span renderer and never steps the
-- control state itself. Output is interleaved stereo int16; mixing sums and
-- saturates at +-32767/+-32768; per-voice host gains round with
-- floor(x+0.5).

local bit = require("bit")
local NnsSoundMath = require("libs.nds.src.nitro.sound.NnsSoundMath")

---@class VoiceMixer
---@field private _outputRate integer
---@field private _channels table<integer, table<string, unknown>>
---@field private _channelGeneration table<integer, integer>
---@field new fun(opts: { sampleRate: integer, observer: table<string, unknown>? }): VoiceMixer
---@field noteOn fun(self: VoiceMixer, spec: table<string, unknown>): { channel: integer, generation: integer } | nil
---@field waveOn fun(self: VoiceMixer, spec: table<string, unknown>): { channel: integer, generation: integer } | nil
---@field noteOff fun(self: VoiceMixer, handle: { channel: integer, generation: integer }, releaseOverride: integer?)
---@field stopVoice fun(self: VoiceMixer, handle: { channel: integer, generation: integer })
---@field updateVoice fun(self: VoiceMixer, handle: { channel: integer, generation: integer }, partial: table<string, unknown>)
---@field advanceTrackTick fun(self: VoiceMixer, handle: { channel: integer, generation: integer })
---@field retargetTiedVoice fun(self: VoiceMixer, handle: { channel: integer, generation: integer }, spec: table<string, unknown>)
---@field isVoiceAlive fun(self: VoiceMixer, handle: { channel: integer, generation: integer }): boolean
---@field controlStep fun(self: VoiceMixer)
---@field renderInto fun(self: VoiceMixer, out: integer[], frames: integer)
---@field render fun(self: VoiceMixer, frames: integer): integer[]

local VoiceMixer = {}
VoiceMixer.__index = VoiceMixer

local function observe(self, event)
  local observer = self._observer
  if observer ~= nil then
    local callback = observer.onChannelState
    if callback ~= nil then
      callback(observer, event)
    end
  end
end

-- DS hardware channel count; the PSG ranges live inside the generator
-- masks below.
local CHANNEL_COUNT = 16

-- The generator's allocatable channel mask (SND_seq.c TrackPlayNote):
-- sample on all 16, square only on 8..13, noise only on 14..15 (GBATEK
-- "NDS Sound": PSG rectangular wave only on those ranges).
local GENERATOR_MASK = {
  sample = 0xFFFF,
  square = 0x3F00,
  noise = 0xC000,
}

-- The fixed extended-channel allocation order (wram2.s
-- sChannelAllocationOrder).
local ALLOCATION_ORDER = { 4, 5, 6, 7, 2, 0, 3, 1, 8, 9, 10, 11, 14, 12, 15, 13 }

-- The register divider shifts (wram2.s sSampleDataShiftTable).
local SAMPLE_DATA_SHIFT = { 0, 1, 2, 4 }

-- The PSG/noise base timer and the DS sample clock (SND_exChannel.c
-- SND_StartExChannelPsg/Noise; GBATEK: 16.757 MHz sample clock).
local PSG_BASE_TIMER = 8006
local DS_SAMPLE_CLOCK = 16756991

-- The pan-center bias of the NNS pan domains: the instrument pan enters as
-- pan - PAN_CENTER (initPan), the track offset is a signed deviation, and
-- the final hardware register is initPan + userPan + PAN_CENTER.
local PAN_CENTER = 0x40

-- The envelope starts fully attenuated (SND_exChannel.c ExChannelStart);
-- the release stops at the control step whose current pre-register dB sum
-- reaches the SDK threshold SND_VOL_DB_MIN.
local ENV_START = -92544
local RELEASE_STOP_DB = -723

-- The 192 Hz sound interval (SND_main.c SndThread) is owned by the
-- external scheduler: the mixer exposes one controlStep per interval and
-- keeps no phase accumulator of its own. ExChannelStart synchronizes a fresh
-- note's initial registers; controlStep owns elapsed 192 Hz advancement.

-- Phase snap for square/noise: the pinned duty and LFSR boundaries sit on
-- exact frame multiples of the timer, and the float phase accumulation may
-- land a few ulp below an integer; the snap is far smaller than the
-- 1/timer gap between genuine states (timers are at most 0xFFFF).
local PHASE_SNAP = 1e-6

local function clamp(value, low, high)
  if value < low then
    return low
  end
  if value > high then
    return high
  end
  return value
end

-- Saturates the summed sample at the int16 bounds.
---@param value integer
---@return integer
local function saturate(value)
  if value > 32767 then
    return 32767
  end
  if value < -32768 then
    return -32768
  end
  return value
end

-- ExChannelVolumeCmp: the allocation tie-break compares the last-synced
-- volume register (mantissa<<4 >> sSampleDataShiftTable[divider]); a free
-- channel has a zero register. Returns 1 when a is quieter, -1 when louder,
-- 0 on a tie.
---@param a table<string, unknown>?
---@param b table<string, unknown>?
---@return integer
local function volumeCmp(a, b)
  local va = a and a.volume or 0
  local vb = b and b.volume or 0
  local ma = bit.lshift(bit.band(va, 0xFF), 4)
  local mb = bit.lshift(bit.band(vb, 0xFF), 4)
  ma = bit.rshift(ma, SAMPLE_DATA_SHIFT[bit.rshift(va, 8) + 1])
  mb = bit.rshift(mb, SAMPLE_DATA_SHIFT[bit.rshift(vb, 8) + 1])
  if ma ~= mb then
    if ma < mb then
      return 1
    end
    return -1
  end
  return 0
end

-- SND_AllocExChannel: inside (generator range AND channelMask), the victim
-- is the lowest (priority, then quieter last-synced register), with free
-- channels represented by priority and volume zero. An incoming note below
-- the chosen candidate's priority is rejected. Returns the channel and the
-- current occupant (nil when free).
---@param kind string
---@param channelMask integer
---@param priority integer
---@return integer?, table<string, unknown>?
local function allocateChannel(self, kind, channelMask, priority)
  local allowed = bit.band(GENERATOR_MASK[kind], channelMask)
  local chosenChannel, chosenVoice
  for _, candidate in ipairs(ALLOCATION_ORDER) do
    local candidateBit = bit.lshift(1, candidate)
    if bit.band(allowed, candidateBit) ~= 0 then
      local voice = self._channels[candidate]
      if chosenChannel == nil then
        chosenChannel = candidate
        chosenVoice = voice
      else
        local voicePriority = voice and voice.priority or 0
        local chosenPriority = chosenVoice and chosenVoice.priority or 0
        if
          voicePriority <= chosenPriority
          and (voicePriority ~= chosenPriority or volumeCmp(chosenVoice, voice) < 0)
        then
          chosenChannel = candidate
          chosenVoice = voice
        end
      end
    end
  end
  if chosenChannel == nil then
    return nil
  end
  local chosenPriority = chosenVoice and chosenVoice.priority or 0
  if priority < chosenPriority then
    return nil
  end
  return chosenChannel, chosenVoice
end

-- The volume register's host gain: mantissa N/128 (127 -> 128) divided by
-- the divider shift (GBATEK "7bit Volume and Panning Values" and
-- "Channel/Mixer Bit-Widths").
---@param register integer
---@return number
local function registerGain(register)
  local mantissa = bit.band(register, 0xFF)
  local n = mantissa == 127 and 128 or mantissa
  local shift = SAMPLE_DATA_SHIFT[bit.rshift(register, 8) + 1]
  return n / 128 / (2 ^ shift)
end

-- The linear hardware pan mix from the pan register (register 127 read as
-- N = 128, so the extremes are full gain on one side).
---@param register integer
---@return number, number
local function panMix(register)
  local n = register == 127 and 128 or register
  return (128 - n) / 128, n / 128
end

-- The discrete square duty index 0..7 (GBATEK "PSG rectangular wave": the
-- 8-step cycle is LOW for 7-d steps and HIGH for d+1 steps, with index 7
-- the all-LOW special pattern). The asset contract carries the integer
-- index directly; anything else is a programming fault at the mixer
-- boundary.
---@param duty integer
---@return integer
local function checkDuty(duty)
  assert(duty >= 0 and duty <= 7 and duty % 1 == 0, "square duty must be an integer index 0..7")
  return duty
end

-- ---------------------------------------------------------------------------
-- Voices

-- The per-note voice state: the SDK channel fields, the track-pushed user
-- values pending the next control step, and the generator playback state.
---@param spec table<string, unknown>
---@return table<string, unknown>
local function newVoice(spec)
  local generator = spec.generator
  assert(spec.originalKey ~= nil, "voice spec requires the original key")
  local release = spec.envelope.release == 0xFF and 0 or spec.envelope.release
  local voice = {
    generator = generator,
    midiKey = spec.key,
    rootMidiKey = spec.originalKey,
    -- The user pitch (TrackUpdateChannel: the player scales pitchBend by
    -- bendRange<<6 then >>7; the mixer never derives it from a key).
    userPitch = spec.userPitch or 0,
    velocity = spec.velocity,
    envAttenuation = ENV_START,
    envStatus = "attack",
    envAttack = NnsSoundMath.attackCoefficient(spec.envelope.attack),
    envDecay = NnsSoundMath.decayCoefficient(spec.envelope.decay),
    envSustain = spec.envelope.sustain,
    envRelease = NnsSoundMath.decayCoefficient(release),
    initPan = spec.pan - PAN_CENTER,
    pending = {
      trackVolume = spec.trackVolume,
      expression = spec.expression,
      sequenceVolume = spec.sequenceVolume,
      fader = spec.fader or 0,
      trackPanOffset = spec.trackPanOffset or 0,
      panRange = spec.panRange or 127,
      lfo = spec.lfo or { target = 0, depth = 0, range = 1, speed = 16, delay = 0 },
      fixedTimer = spec.fixedTimer,
      dirty = true,
    },
    sweepPitch = spec.sweepPitch or 0,
    sweepLength = spec.sweepLength or 0,
    sweepCounter = 0,
    autoSweep = spec.autoSweep ~= false,
    lfoCounter = 0,
    lfoDelayCounter = 0,
    -- The last-synced registers (the volume feeds the allocation tie-break).
    volume = 0,
    timer = 0,
    hardwarePan = 0,
    ratio = 0,
    released = false,
    physicalInactive = false,
    dead = false,
    length = spec.envelope.release == 0xFF and -1 or spec.length,
    ownerPlayerId = spec.ownerPlayerId,
    ownerTrackSlot = spec.ownerTrackSlot,
    baseTimer = PSG_BASE_TIMER,
    fixedTimer = spec.fixedTimer,
  }
  if generator.kind == "sample" then
    -- The spec carries the provider-decoded PCM array (shared, immutable);
    -- the mixer never decodes payload bytes. The base timer and the
    -- calculated channel timer drive the phase; no source sample rate is
    -- involved.
    voice.pcm = spec.pcm
    voice.baseTimer = spec.baseTimer
    voice.pos = 0
    voice.loop = spec.loop
    voice.loopEnabled = spec.loopEnabled
  elseif generator.kind == "square" then
    voice.duty = checkDuty(generator.duty)
    voice.phase = 0
  else
    voice.phase = 0
    voice.lfsr = 0x7FFF
  end
  return voice
end

-- TrackUpdateChannel: the track-level values become the channel's user
-- values (the dB sum is clamped at -0x8000; the pan offset is scaled by
-- the panRange when it is not 127).
---@param voice table<string, unknown>
local function applyPending(voice)
  local pending = voice.pending
  local vol = NnsSoundMath.decibelSquare(pending.trackVolume)
    + NnsSoundMath.decibelSquare(pending.expression)
    + NnsSoundMath.decibelSquare(pending.sequenceVolume)
  if vol < -0x8000 then
    vol = -0x8000
  end
  voice.userDecay = vol
  local fader = pending.fader
  if fader < -0x8000 then
    fader = -0x8000
  end
  voice.userDecay2 = fader
  if pending.panRange == 127 then
    voice.userPan = pending.trackPanOffset
  else
    voice.userPan = math.floor((pending.trackPanOffset * pending.panRange + 0x40) / 128)
  end
  voice.lfoParam = pending.lfo
  if pending.fixedTimer ~= nil then
    voice.fixedTimer = pending.fixedTimer
  end
  -- The tie partials: key retunes the pitch path, userPitch offsets it,
  -- velocity re-enters the dB sum; all leave the envelope and the
  -- release/attack status alone.
  if pending.key ~= nil then
    voice.midiKey = pending.key
  end
  if pending.userPitch ~= nil then
    voice.userPitch = pending.userPitch
  end
  if pending.velocity ~= nil then
    voice.velocity = pending.velocity
  end
  pending.dirty = false
end

-- The LFO value for the current counter state (SND_GetLfoValue), scaled by
-- the target (SND_exChannel.c ExChannelLfoUpdate): 0 while the delay
-- counter runs or the depth is zero.
---@param voice table<string, unknown>
---@return integer
local function lfoValue(voice)
  local param = voice.lfoParam
  if param.depth == 0 or voice.lfoDelayCounter < param.delay then
    return 0
  end
  local value = NnsSoundMath.sinIdx(math.floor(voice.lfoCounter / 256)) * param.depth * param.range
  if value ~= 0 then
    if param.target == 1 then
      value = value * 60
    else
      value = value * 64
    end
    value = math.floor(value / 16384)
  end
  return value
end

-- SND_UpdateLfo: the delay counter advances first; once the delay is
-- exhausted the 8.8 fixed-point counter advances by speed<<6 with the high
-- byte wrapped at 0x80.
---@param voice table<string, unknown>
local function advanceLfo(voice)
  local param = voice.lfoParam
  if voice.lfoDelayCounter < param.delay then
    voice.lfoDelayCounter = voice.lfoDelayCounter + 1
  else
    local high = math.floor((voice.lfoCounter + param.speed * 64) / 256)
    while high >= 0x80 do
      high = high - 0x80
    end
    voice.lfoCounter = bit.band(voice.lfoCounter + param.speed * 64, 0xFF) + high * 256
  end
end

-- The host phase increment: the calculated NDS timer feeds the physical
-- boundary through the DS sample clock for every generator (the source
-- hardware path SND_CalcTimer -> sound timer -> sample clock; at a
-- DS-rate mixer the translation is exactly 1/timer).
---@param voice table<string, unknown>
---@return number
local function voiceRatio(voice)
  return DS_SAMPLE_CLOCK / (voice.timer * voice._outputRate)
end

-- SND_ExChannelMain: the vol/pitch/pan computation and the register sync
-- from the current channel state (without advancing the envelope/sweep/LFO
-- state machines). The release stops when the current pre-register dB sum
-- crosses SND_VOL_DB_MIN (the SDK's death moment; the -0x8000 volume-LFO
-- guard lives here); the PSG timer is masked with 0xFFFC.
---@param voice table<string, unknown>
---@return boolean -- false when the voice hit the release stop threshold
local function syncRegisters(voice)
  local param = voice.lfoParam
  local lfo = lfoValue(voice)
  local vol = NnsSoundMath.decibelSquare(voice.velocity)
    + math.floor(voice.envAttenuation / 128)
    + voice.userDecay
    + voice.userDecay2
  if lfo ~= 0 and param.target == 1 and vol > -0x8000 then
    vol = vol + lfo
  end
  if voice.released and vol <= RELEASE_STOP_DB then
    voice.dead = true
    return false
  end
  local pitch = (voice.midiKey - voice.rootMidiKey) * 0x40 + voice.userPitch
  if lfo ~= 0 and param.target == 0 then
    pitch = pitch + lfo
  end
  local sweep = 0
  if voice.sweepPitch ~= 0 and voice.sweepCounter < voice.sweepLength then
    sweep = NnsSoundMath.cDiv(voice.sweepPitch * (voice.sweepLength - voice.sweepCounter), voice.sweepLength)
    pitch = pitch + sweep
  end
  local pan = voice.initPan
  if lfo ~= 0 and param.target == 2 then
    pan = pan + lfo
  end
  pan = pan + voice.userPan
  voice.volume = NnsSoundMath.calcChannelVolume(vol)
  local timer = voice.fixedTimer or NnsSoundMath.calcTimer(voice.baseTimer, pitch)
  if voice.generator.kind == "square" then
    timer = bit.band(timer, 0xFFFC)
  end
  voice.timer = timer
  pan = pan + PAN_CENTER
  voice.hardwarePan = clamp(pan, 0, 127)
  voice.ratio = voiceRatio(voice)
  return true
end

-- One control step (SND_ExChannelMain(step = TRUE)): track values, then
-- the envelope advance (SND_UpdateExChannelEnvelope), the sweep counter
-- advance (only at regular steps, never at the noteOn step itself), the
-- LFO advance, and the register sync (a release voice whose pre-register
-- dB sum reaches the SND_VOL_DB_MIN threshold is stopped by the sync).
---@param voice table<string, unknown>
---@param advanceSweep boolean
local function controlStep(voice, advanceSweep)
  applyPending(voice)
  if voice.envStatus == "attack" then
    voice.envAttenuation = -math.floor((-voice.envAttenuation * voice.envAttack) / 256)
    if voice.envAttenuation == 0 then
      voice.envStatus = "decay"
    end
  elseif voice.envStatus == "decay" then
    local sustain = NnsSoundMath.decibelSquare(voice.envSustain) * 128
    voice.envAttenuation = voice.envAttenuation - voice.envDecay
    if voice.envAttenuation <= sustain then
      voice.envAttenuation = sustain
      voice.envStatus = "sustain"
    end
  elseif voice.envStatus == "release" then
    voice.envAttenuation = voice.envAttenuation - voice.envRelease
  end
  local alive = syncRegisters(voice)
  if
    alive
    and advanceSweep
    and voice.autoSweep
    and voice.sweepPitch ~= 0
    and voice.sweepCounter < voice.sweepLength
  then
    voice.sweepCounter = voice.sweepCounter + 1
  end
  if alive then
    advanceLfo(voice)
  end
end

-- Reads the generator's sample at the current position and advances the
-- playback state by one frame (read-then-advance). One-shot waves stop at
-- the window end (the boundary sample still sounds).
---@param voice table<string, unknown>
---@return integer
local function sampleAt(voice)
  if voice.generator.kind == "sample" then
    if voice.physicalInactive then
      return 0
    end
    local sample = voice.pcm[math.floor(voice.pos) + 1]
    voice.pos = voice.pos + voice.ratio
    if voice.pos >= voice.loop.endFrame then
      if voice.loopEnabled then
        local span = voice.loop.endFrame - voice.loop.startFrame
        while voice.pos >= voice.loop.endFrame do
          voice.pos = voice.pos - span
        end
      else
        voice.physicalInactive = true
      end
    end
    return sample
  end
  if voice.generator.kind == "noise" then
    local sample = voice.lfsr % 2 == 1 and -32767 or 32767
    voice.phase = voice.phase + voice.ratio
    while voice.phase >= 1 - PHASE_SNAP do
      voice.phase = voice.phase - 1
      if voice.lfsr % 2 == 1 then
        voice.lfsr = bit.bxor(bit.rshift(voice.lfsr, 1), 0x6000)
      else
        voice.lfsr = bit.rshift(voice.lfsr, 1)
      end
    end
    return sample
  end
  local state = math.floor(voice.phase + PHASE_SNAP)
  -- The 8-step duty grid: LOW for 7-d states, HIGH for d+1; duty 7 is the
  -- GBATEK all-LOW special pattern, not a full-HIGH cycle.
  local sample = (voice.duty == 7 and -32767) or (state % 8 < 7 - voice.duty and -32767 or 32767)
  voice.phase = voice.phase + voice.ratio
  return sample
end

-- ---------------------------------------------------------------------------
-- Mixer

function VoiceMixer.new(opts)
  assert(opts and opts.sampleRate, "VoiceMixer requires a sampleRate")
  return setmetatable({
    _outputRate = opts.sampleRate,
    _observer = opts.observer,
    _channels = {},
    -- The persistent per-channel generation counter: every allocation of a
    -- channel increments it, so two distinct allocations never share a
    -- generation while an old handle may still exist (doubles hold the
    -- count exactly; no wrap is needed).
    _channelGeneration = {},
  }, VoiceMixer)
end

-- Starts a voice for `spec` (the NNS spec: trackVolume/trackPriority,
-- {channel, generation} handle). Returns nil when the note is rejected (no
-- allowed channel or priority below the chosen occupied channel's).
---@param spec table<string, unknown>
---@return { channel: integer, generation: integer } | nil
function VoiceMixer:noteOn(spec)
  assert(spec and spec.generator and spec.envelope, "voice spec requires a generator and envelope")
  assert(
    spec.key ~= nil and spec.velocity ~= nil and spec.channelPriority ~= nil and spec.channelMask ~= nil,
    "voice spec requires key/velocity/channelPriority/channelMask"
  )
  assert(
    spec.trackVolume ~= nil and spec.expression ~= nil and spec.sequenceVolume ~= nil,
    "voice spec requires trackVolume/expression/sequenceVolume"
  )
  assert(spec.pan ~= nil and spec.trackPriority ~= nil, "voice spec requires pan/trackPriority")
  local priority = spec.channelPriority + spec.trackPriority
  local channel, victim
  if spec.fixedChannel ~= nil then
    assert(spec.fixedChannel >= 0 and spec.fixedChannel < CHANNEL_COUNT and spec.fixedChannel % 1 == 0)
    channel = spec.fixedChannel
    victim = self._channels[channel]
    if victim ~= nil and priority < victim.priority then
      return nil
    end
  else
    channel, victim = allocateChannel(self, spec.generator.kind, spec.channelMask, priority)
  end
  if channel == nil then
    return nil
  end
  if spec.generator.kind == "sample" then
    assert(
      spec.pcm ~= nil and spec.baseTimer ~= nil and spec.loop ~= nil,
      "sample voice spec requires pcm/baseTimer/loop"
    )
    assert(type(spec.loopEnabled) == "boolean", "sample voice spec requires the wave's loop flag")
  end
  local voice = newVoice(spec)
  voice._outputRate = self._outputRate
  voice.priority = priority % 256
  -- The generation is the channel's persistent counter, not the victim's:
  -- a channel freed by a natural death keeps its count so a stale handle
  -- can never alias a later allocation of the same channel.
  voice.generation = (self._channelGeneration[channel] or -1) + 1
  self._channelGeneration[channel] = voice.generation
  -- ExChannelStart synchronizes the initial registers without advancing
  -- envelope, LFO, or sweep time. The scheduler owns the first elapsed step.
  applyPending(voice)
  syncRegisters(voice)
  self._channels[channel] = voice
  return { channel = channel, generation = voice.generation }
end

-- Starts a raw WaveOut-style sample on a fixed channel through the same
-- generation/liveness table used by sequence voices.
---@param spec { channel: integer, pcm: integer[], metadata: table<string, unknown>, volume: integer, pan: integer, speed: integer }
---@return { channel: integer, generation: integer } | nil
function VoiceMixer:waveOn(spec)
  assert(spec and (spec.channel == 14 or spec.channel == 15), "WaveOut channel must be 14 or 15")
  assert(type(spec.pcm) == "table" and type(spec.metadata) == "table", "WaveOut requires sample data")
  assert(spec.volume >= 0 and spec.volume <= 127 and spec.volume % 1 == 0, "WaveOut volume must be 0..127")
  assert(spec.pan >= 0 and spec.pan <= 127 and spec.pan % 1 == 0, "WaveOut pan must be 0..127")
  assert(spec.speed > 0 and spec.speed <= 0xFFFF and spec.speed % 1 == 0, "WaveOut speed must be a timer")
  local loop = spec.metadata.loop
  assert(loop and loop.startFrame ~= nil and loop.endFrame ~= nil, "WaveOut sample requires loop bounds")
  return self:noteOn({
    fixedChannel = spec.channel,
    fixedTimer = spec.speed,
    generator = { kind = "sample", sample = "waveout" },
    pcm = spec.pcm,
    baseTimer = spec.speed,
    loop = loop,
    loopEnabled = false,
    key = 60,
    originalKey = 60,
    velocity = 127,
    trackVolume = spec.volume,
    expression = 127,
    sequenceVolume = 127,
    fader = 0,
    pan = spec.pan,
    trackPanOffset = 0,
    channelMask = bit.lshift(1, spec.channel),
    trackPriority = 127,
    channelPriority = 127,
    envelope = { attack = 127, decay = 127, sustain = 127, release = 0xFF },
    length = -1,
  })
end

-- Starts or updates the release of the voice a handle names. A stale handle
-- (channel stolen, generation replaced) and a dead voice are harmless no-ops.
-- `releaseOverride` (nil or an integer 0..127) replaces the voice's instrument
-- release coefficient; this lets the forced track-release path (pause/mute
-- stop) accelerate an already-running ordinary release without restarting it.
-- The voice then stops at the control step whose current pre-register dB sum
-- crosses SND_VOL_DB_MIN; the death moment is the mixer's, never precomputed.
---@param handle { channel: integer, generation: integer }
---@param releaseOverride integer?
function VoiceMixer:noteOff(handle, releaseOverride)
  if releaseOverride ~= nil then
    assert(
      releaseOverride >= 0 and releaseOverride <= 127 and releaseOverride % 1 == 0,
      "release override must be nil or an integer 0..127"
    )
  end
  local voice = self._channels[handle.channel]
  if voice == nil or voice.generation ~= handle.generation or voice.dead then
    return
  end
  voice.priority = 1
  if releaseOverride ~= nil then
    voice.envRelease = NnsSoundMath.decayCoefficient(releaseOverride)
  end
  if not voice.released then
    voice.released = true
    voice.envStatus = "release"
  end
end

-- Immediately removes a voice for the internal WaveOut stop path. A stale
-- generation is harmless, just like noteOff and updateVoice.
---@param handle { channel: integer, generation: integer }
function VoiceMixer:stopVoice(handle)
  local voice = self._channels[handle.channel]
  if voice ~= nil and voice.generation == handle.generation then
    self._channels[handle.channel] = nil
  end
end

-- Queues track-level control values for the voice a handle names; they are
-- applied at the next control step -- also while the voice is releasing,
-- because the current inputs decide the release's death moment. The `key`
-- partial retunes the voice through the note's pitch path (the
-- timer/ratio recompute) and `userPitch` offsets it, both without
-- touching the envelope or the release/attack status; `velocity` updates
-- the velocity in the volume dB sum. A stale handle is harmless.
---@param handle { channel: integer, generation: integer }
---@param partial table<string, unknown>
function VoiceMixer:updateVoice(handle, partial)
  local voice = self._channels[handle.channel]
  if voice == nil or voice.generation ~= handle.generation then
    return
  end
  for key, value in pairs(partial) do
    voice.pending[key] = value
  end
  voice.pending.dirty = true
end

-- The sequence-owned non-auto sweep advancement (SND_seq.c TrackStepTicks:
-- every linked non-auto-sweep channel's counter advances once per sequence
-- tick while below the sweep length): increments the named live voice's
-- sweep counter exactly once, capped at its sweep length. An auto-sweep
-- voice is untouched -- its counter belongs to the 192 Hz control cadence
-- (controlStep) -- and a stale/dead handle is a harmless no-op like the
-- other handle operations. This is a pure counter advance: the envelope,
-- the release status and the generator position never move here.
---@param handle { channel: integer, generation: integer }
function VoiceMixer:advanceTrackTick(handle)
  local voice = self._channels[handle.channel]
  if voice == nil or voice.generation ~= handle.generation then
    return
  end
  if not voice.autoSweep and voice.sweepPitch ~= 0 and voice.sweepCounter < voice.sweepLength then
    voice.sweepCounter = voice.sweepCounter + 1
  end
end

-- The tied-note common-tail mutation (SND_seq.c TrackPlayNote over an
-- existing channelLLHead): applies the key/velocity to the named live
-- voice and recomputes the sweep configuration (sweep pitch, the sweep
-- length, the auto-sweep choice) with the sweep counter reset to zero, all
-- on the SAME voice generation: no allocation, no release, and no
-- envelope-stage or generator/sample phase reset. The optional `envelope`
-- carries only the track's set override stages -- nil keeps the channel's
-- existing coefficient, mirroring the source's non-0xFF guards -- and a
-- `sweepLength` of zero disables the sweep contribution (the non-auto
-- counter can never reach a zero length). A stale/dead handle is a
-- harmless no-op.
---@param handle { channel: integer, generation: integer }
---@param spec table<string, unknown>
function VoiceMixer:retargetTiedVoice(handle, spec)
  local voice = self._channels[handle.channel]
  if voice == nil or voice.generation ~= handle.generation then
    return
  end
  if spec.key ~= nil then
    voice.midiKey = spec.key
  end
  if spec.velocity ~= nil then
    voice.velocity = spec.velocity
  end
  if spec.envelope ~= nil then
    if spec.envelope.attack ~= nil then
      voice.envAttack = NnsSoundMath.attackCoefficient(spec.envelope.attack)
    end
    if spec.envelope.decay ~= nil then
      voice.envDecay = NnsSoundMath.decayCoefficient(spec.envelope.decay)
    end
    if spec.envelope.sustain ~= nil then
      voice.envSustain = spec.envelope.sustain
    end
    if spec.envelope.release ~= nil then
      local release = spec.envelope.release == 0xFF and 0 or spec.envelope.release
      voice.envRelease = NnsSoundMath.decayCoefficient(release)
    end
  end
  if spec.sweepPitch ~= nil then
    voice.sweepPitch = spec.sweepPitch
  end
  if spec.sweepLength ~= nil then
    voice.sweepLength = spec.sweepLength
  end
  if spec.autoSweep ~= nil then
    voice.autoSweep = spec.autoSweep
  end
  voice.sweepCounter = 0
end

-- The mixer owns voice liveness: true from noteOn until the mixer removes
-- the voice (one-shot retirement at channel control or the release-stop
-- step); false for an empty channel, a generation mismatch, and a removed
-- voice. The sequencer prunes its voice collections with this query.
---@param handle { channel: integer, generation: integer }
---@return boolean
function VoiceMixer:isVoiceAlive(handle)
  local voice = self._channels[handle.channel]
  return voice ~= nil and voice.generation == handle.generation and not voice.dead
end

-- One externally driven channel-control step (SND_ExChannelMain(step =
-- TRUE) at one 192 Hz sound interval): queued track-level values apply
-- first -- so the boundary frame's own PCM read hears the new registers and
-- a releasing voice whose current inputs cross the stop threshold dies
-- here -- then every live channel advances its envelope/sweep/LFO state
-- machines once and resyncs its registers. The sweep counter advances only
-- for auto-sweep voices at this step (ExChannelSweepUpdate); the non-auto
-- counter is the sequence tick's property (advanceTrackTick) and never
-- moves here. Deterministic ascending channel order; the external scheduler
-- calls this exactly once per completed sound interval after all sequence
-- ticks.
function VoiceMixer:controlStep(ordinal)
  for channel = 0, CHANNEL_COUNT - 1 do
    local voice = self._channels[channel]
    if voice ~= nil then
      if voice.physicalInactive then
        voice.dead = true
      else
        controlStep(voice, true)
      end
      if voice.dead then
        self._channels[channel] = nil
      end
    end
  end
  if self._observer ~= nil then
    for channel = 0, CHANNEL_COUNT - 1 do
      local voice = self._channels[channel]
      observe(self, {
        ordinal = ordinal,
        channel = channel,
        generation = (voice and voice.generation) or self._channelGeneration[channel] or 0,
        active = voice ~= nil and not voice.dead,
        ownerPlayerId = voice and voice.ownerPlayerId or nil,
        ownerTrackSlot = voice and voice.ownerTrackSlot or nil,
        priority = voice and voice.priority or 0,
        key = voice and voice.midiKey or nil,
        envStatus = voice and voice.envStatus or nil,
        envAttenuation = voice and voice.envAttenuation or nil,
        timer = voice and voice.timer or 0,
        volumeRegister = voice and voice.volume or 0,
        panRegister = voice and voice.hardwarePan or 0,
        released = voice ~= nil and voice.released or false,
        length = voice and voice.length or nil,
      })
    end
  end
end

-- Renders `frames` output frames of interleaved stereo int16 PCM (2*frames
-- entries) appended to `out` after its current end, so a caller-owned
-- buffer is reused across span renders instead of allocating a fresh result
-- table per call. This is a pure PCM span renderer: voices read at their
-- position and advance with the current ratio, and no control state -- no
-- envelope step, no sweep/LFO advance, no queued-value application -- moves
-- during rendering. The external scheduler runs one controlStep per sound
-- interval after the sequence portion. The mix sums and saturates at the
-- int16 bounds; chunk sizes never change the result.
---@param out integer[]
---@param frames integer
function VoiceMixer:renderInto(out, frames)
  for _ = 1, frames do
    local left, right = 0, 0
    for channel = 0, CHANNEL_COUNT - 1 do
      local voice = self._channels[channel]
      if voice ~= nil then
        local sample = sampleAt(voice)
        local gain = registerGain(voice.volume)
        local panLeft, panRight = panMix(voice.hardwarePan)
        left = left + math.floor(sample * gain * panLeft + 0.5)
        right = right + math.floor(sample * gain * panRight + 0.5)
      end
    end
    out[#out + 1] = saturate(left)
    out[#out + 1] = saturate(right)
  end
end

-- The per-call render pattern: a fresh result table holding `frames` frames
-- of interleaved stereo int16 PCM, rendered through the same span machinery
-- as renderInto.
---@param frames integer
---@return integer[]
function VoiceMixer:render(frames)
  local out = {}
  self:renderInto(out, frames)
  return out
end

return VoiceMixer
