-- HGSS field cry pattern policy and ownership over NNS audio resources.

local AudioErrors = require("libs.hgss.src.audio.AudioErrors")
local Errors = require("libs.errors.src.Errors")
local InstrumentSelector = require("libs.nds.src.nitro.sound.InstrumentSelector")
local PlayerFaderTimeline = require("libs.hgss.src.audio.PlayerFaderTimeline")

local CryPlayer = {}
CryPlayer.__index = CryPlayer

local STANDARD_CRY_SEQUENCE_ID = 2
local MAX_STANDARD_SPECIES = 493
local PRIMARY_VOLUME = 100
local SECONDARY_VOLUME = 70

local function isInteger(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value == math.floor(value)
end

-- The table mirrors PlayCryEx's source action families. Controls not listed
-- on a voice are supplied by the common handle reset in play().
local PATTERNS = {
  [0] = { primary = {} },
  [1] = { primary = {}, cleanupTicks = 20 },
  [2] = { primary = { pitch = 64 }, secondary = { pitch = 20, initialVolume = SECONDARY_VOLUME } },
  [3] = {
    primary = { pitch = 192 },
    secondary = { pitch = 16, initialVolume = SECONDARY_VOLUME },
    cleanupTicks = 30,
  },
  [4] = {
    waveOut = {
      { channel = 14, volume = 100, speed = 0x8600 },
      { channel = 15, volume = SECONDARY_VOLUME, speed = 0x8600 },
    },
    cleanupTicks = 15,
  },
  [5] = { primary = { pitch = -224 } },
  [6] = { primary = { pitch = 44 }, secondary = { pitch = -64, initialVolume = SECONDARY_VOLUME } },
  [7] = { primary = { pitch = -128 }, cleanupTicks = 11 },
  [8] = { primary = { pitch = 60 }, cleanupTicks = 60 },
  [9] = { waveOut = { { channel = 14, volume = 100, speed = 0x6800 } }, cleanupTicks = 13 },
  [10] = { primary = { pitch = -44 }, cleanupTicks = 100 },
  [11] = { primary = { pitch = -96 } },
  [12] = { primary = { pitch = -96 }, cleanupTicks = 20 },
  [13] = { primary = { initialVolume = 127 }, secondary = { pitch = 20, moveVolume = 100 } },
  [14] = { primary = {} },
}

local function unavailable(species, pattern, reason)
  Errors.raise(AudioErrors.AUDIO_CRY_UNAVAILABLE, reason, { species = species, pattern = pattern })
end

local function handleApply(self, handle, level)
  self._player:setHandleFader(handle, level)
  self._faderLevels[handle] = level
  return level
end

---@class CryPlayer
---@field new fun(opts: { player: SequencePlayer, provider: AudioAssetProvider, waveOut: WaveOutPlayer?, faderTimeline: PlayerFaderTimeline? }): CryPlayer
---@field play fun(self: CryPlayer, species: integer, pattern: integer|nil)
---@field update fun(self: CryPlayer)
---@field isFinished fun(self: CryPlayer): boolean

---@param opts { player: SequencePlayer, provider: AudioAssetProvider, waveOut: WaveOutPlayer?, faderTimeline: PlayerFaderTimeline? }
---@return CryPlayer
function CryPlayer.new(opts)
  assert(opts and opts.player and opts.provider, "cry player requires the engine player and provider")
  local primaryHandle = opts.player:createHandle()
  local secondaryHandle = opts.player:createHandle()
  return setmetatable({
    _player = opts.player,
    _provider = opts.provider,
    _waveOut = opts.waveOut,
    _timeline = opts.faderTimeline or PlayerFaderTimeline.new(),
    _primaryHandle = primaryHandle,
    _secondaryHandle = secondaryHandle,
    _faderLevels = { [primaryHandle] = 127, [secondaryHandle] = 127 },
    _owned = nil,
    _cleanupTicks = nil,
  }, CryPlayer) --[[@as CryPlayer]]
end

local function sampleForBank(provider, bank)
  local instrument = bank.instruments and bank.instruments[0]
  local voice = instrument and InstrumentSelector.selectVoice(instrument, 60)
  local generator = voice and voice.generator
  if generator == nil or generator.kind ~= "sample" or generator.sample == nil then
    Errors.raise(AudioErrors.AUDIO_PROVIDER_SAMPLE_UNKNOWN, "species bank has no cry sample", { bankId = bank.id })
  end
  local generatorTable = generator --[[@as table]]
  local sampleKey = rawget(generatorTable, "sample")
  assert(type(sampleKey) == "string", "cry sample key must be a string")
  return provider:loadSample(sampleKey)
end

function CryPlayer:_resetHandle(handle)
  self._timeline:reset(handle, 127)
  if self._faderLevels[handle] ~= 127 then
    self._timeline:set(handle, 127, function(level)
      return handleApply(self, handle, level)
    end)
  else
    self._faderLevels[handle] = 127
  end
  self._player:setHandleInitialVolume(handle, PRIMARY_VOLUME)
  self._player:setHandleTrackPan(handle, 0)
  self._player:setHandleTrackPitch(handle, 0)
end

function CryPlayer:_stopOwned()
  local owned = self._owned
  if owned == nil then
    return
  end
  local stopped = {}
  for _, handle in ipairs({ owned.primary, owned.secondary }) do
    if handle ~= nil and not stopped[handle] then
      self._player:stopHandle(handle)
      stopped[handle] = true
      self._timeline:cancel(handle)
    end
  end
  for _, handle in ipairs(owned.waveOut) do
    if not stopped[handle] then
      self._waveOut:stop(handle)
      stopped[handle] = true
    end
  end
  self._owned = nil
  self._cleanupTicks = nil
end

local function startSequence(self, handle, sequence, bank, action, species, pattern)
  local accepted = self._player:playWithBankOverride(handle, sequence, bank)
  if not accepted then
    unavailable(species, pattern, "the cry was rejected by the audio player")
  end
  self:_resetHandle(handle)
  if action.initialVolume ~= nil then
    self._player:setHandleInitialVolume(handle, action.initialVolume)
  end
  if action.pitch ~= nil then
    self._player:setHandleTrackPitch(handle, action.pitch)
  end
end

---@param species integer
---@param pattern integer|nil
function CryPlayer:play(species, pattern)
  if pattern == nil then
    pattern = 0
  end
  if not isInteger(species) or species < 1 or species > MAX_STANDARD_SPECIES then
    unavailable(species, pattern, "standard cry species must be a supported integer")
  end
  local descriptor = isInteger(pattern) and PATTERNS[pattern] or nil
  if descriptor == nil then
    unavailable(species, pattern, "unsupported cry pattern")
  end
  assert(descriptor ~= nil, "cry pattern descriptor must be available")

  -- Resolve every asset before replacing the currently valid request.
  local bank = self._provider:bank(species)
  local sequence
  local sample
  if descriptor.primary ~= nil or descriptor.secondary ~= nil then
    sequence = self._provider:sequence(STANDARD_CRY_SEQUENCE_ID)
  end
  if descriptor.waveOut ~= nil then
    sample = sampleForBank(self._provider, bank)
    if self._waveOut == nil then
      unavailable(species, pattern, "no WaveOut subsystem is available")
    end
  end

  local hadOwned = self._owned ~= nil
  self:_stopOwned()
  if not hadOwned then
    self._player:stopHandle(self._primaryHandle)
  end
  local owned = { primary = nil, secondary = nil, waveOut = {} }
  self._owned = owned

  local ok, err = xpcall(function()
    if descriptor.primary ~= nil then
      owned.primary = self._primaryHandle
      startSequence(self, self._primaryHandle, sequence, bank, descriptor.primary, species, pattern)
    end
    if descriptor.secondary ~= nil then
      owned.secondary = self._secondaryHandle
      startSequence(self, self._secondaryHandle, sequence, bank, descriptor.secondary, species, pattern)
      if descriptor.secondary.moveVolume ~= nil then
        self._timeline:replace(self._secondaryHandle, descriptor.secondary.moveVolume, 0, function(level)
          return handleApply(self, self._secondaryHandle, level)
        end)
      end
    end
    if descriptor.waveOut ~= nil then
      for _, action in ipairs(descriptor.waveOut) do
        local handle = self._waveOut:start(action.channel, sample, {
          volume = action.volume,
          pan = 64,
          speed = action.speed,
          reverse = true,
        })
        if handle == nil then
          unavailable(species, pattern, "the direct-wave cry was rejected by the audio player")
        end
        owned.waveOut[#owned.waveOut + 1] = handle
      end
    end
    self._cleanupTicks = descriptor.cleanupTicks
  end, function(errorValue)
    return errorValue
  end)
  if not ok then
    self:_stopOwned()
    error(err, 0)
  end
end

function CryPlayer:update()
  if self._owned == nil then
    return
  end
  if self:isFinished() then
    return
  end
  if self._cleanupTicks ~= nil and self._cleanupTicks == 10 then
    for _, handle in ipairs({ self._owned.primary, self._owned.secondary }) do
      if handle ~= nil then
        self._timeline:replace(handle, 0, 10, function(level)
          return handleApply(self, handle, level)
        end)
      end
    end
  end
  if self._cleanupTicks ~= nil then
    self._cleanupTicks = self._cleanupTicks - 1
  end
  self._timeline:update()
  if self._cleanupTicks ~= nil and self._cleanupTicks <= 0 then
    self:_stopOwned()
  end
end

---@return boolean
function CryPlayer:isFinished()
  if self._owned == nil then
    return true
  end
  local active = false
  for _, handle in ipairs({ self._owned.primary, self._owned.secondary }) do
    if handle ~= nil and self._player:isHandlePlaying(handle) then
      active = true
    end
  end
  for index = 1, #self._owned.waveOut do
    if self._waveOut:isPlaying(self._owned.waveOut[index]) then
      active = true
    end
  end
  if not active then
    self._owned = nil
    self._cleanupTicks = nil
    return true
  end
  return false
end

return CryPlayer
