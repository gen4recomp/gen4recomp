-- CryPlayer: the standard HGSS cry path over generated SDAT assets. Retail
-- PlayCry starts generic sequence 2 with the normalized species number as
-- its bank override (see asm/unk_02005D10.s); the shared SequencePlayer
-- owns the resulting playback and the private handle identifies this cry
-- independently of other uses of the logical player. Pure domain module: no
-- love dependency.

local AudioErrors = require("libs.hgss.src.audio.AudioErrors")
local Errors = require("libs.errors.src.Errors")

local CryPlayer = {}
CryPlayer.__index = CryPlayer

local STANDARD_CRY_SEQUENCE_ID = 2
local MAX_STANDARD_SPECIES = 493

local function isInteger(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value == math.floor(value)
end

local PATTERN_BEHAVIORS = {
  [0] = { externalPitch = 0 },
  [1] = { externalPitch = 0, cleanupTicks = 20 },
  [11] = { externalPitch = -96 },
  [12] = { externalPitch = -96, cleanupTicks = 20 },
}

local function unavailable(species, pattern, reason)
  Errors.raise(AudioErrors.AUDIO_CRY_UNAVAILABLE, reason, { species = species, pattern = pattern })
end

---@class CryPlayer
---@field new fun(opts: { player: SequencePlayer, provider: AudioAssetProvider }): CryPlayer
---@field play fun(self: CryPlayer, species: integer, pattern: integer|nil)
---@field update fun(self: CryPlayer)
---@field isFinished fun(self: CryPlayer): boolean

---@param opts { player: SequencePlayer, provider: AudioAssetProvider }
---@return CryPlayer
function CryPlayer.new(opts)
  assert(opts and opts.player and opts.provider, "cry player requires the engine player and provider")
  return setmetatable({
    _player = opts.player,
    _provider = opts.provider,
    _handle = opts.player:createHandle(),
    _cleanupTicks = nil,
  }, CryPlayer) --[[@as CryPlayer]]
end

-- Starts the source-compatible generic cry sequence with the species bank.
-- Resolving assets before stopping the current handle leaves an active cry
-- untouched when a replacement request is invalid or absent from the cache.
---@param species integer
---@param pattern integer|nil
function CryPlayer:play(species, pattern)
  if pattern == nil then
    pattern = 0
  end
  if not isInteger(species) or species < 1 or species > MAX_STANDARD_SPECIES then
    unavailable(species, pattern, "standard cry species must be a supported integer")
  end
  local behavior = isInteger(pattern) and PATTERN_BEHAVIORS[pattern] or nil
  if behavior == nil then
    unavailable(species, pattern, "unsupported cry pattern")
  end
  assert(behavior ~= nil, "cry pattern behavior must be available")

  local sequence = self._provider:sequence(STANDARD_CRY_SEQUENCE_ID)
  local bank = self._provider:bank(species)
  self._player:stopHandle(self._handle)
  local accepted = self._player:playWithBankOverride(self._handle, sequence, bank)
  if not accepted then
    unavailable(species, pattern, "the standard cry was rejected by the audio player")
  end
  self._player:setHandleTrackPitch(self._handle, 0)
  if behavior.externalPitch ~= 0 then
    self._player:setHandleTrackPitch(self._handle, behavior.externalPitch)
  end
  self._cleanupTicks = behavior.cleanupTicks
end

-- Patterns 1 and 12 schedule the retail 20-tick cry cleanup task. The source
-- fades the cry player at its midpoint and stops the cry lifecycle at the end;
-- the private handle is the corresponding owner in the recreated runtime.
function CryPlayer:update()
  if self._cleanupTicks == nil then
    return
  end
  if self:isFinished() then
    self._cleanupTicks = nil
    return
  end
  if self._cleanupTicks == 10 then
    self._player:setHandleFader(self._handle, 0)
  end
  self._cleanupTicks = self._cleanupTicks - 1
  if self._cleanupTicks <= 0 then
    self._player:stopHandle(self._handle)
    self._cleanupTicks = nil
  end
end

-- True once the source playback attached to this cry's private handle ends.
---@return boolean
function CryPlayer:isFinished()
  return not self._player:isHandlePlaying(self._handle)
end

return CryPlayer
