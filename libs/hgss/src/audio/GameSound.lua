-- GameSound: the semantic audio facade field scripts receive as their
-- `audio` service. It wraps the composed audio runtime (HGSS asset provider
-- over the NDS player and mixer) and owns the script-observable semantics:
-- BGM (play/stop/replace/current; stopping the BGM cancels its fade),
-- effects (play/stop;
-- waits follow the HGSS IsSEPlaying model -- resolve the sequence's player
-- and test that player's playback state, never an individual host-source
-- token). `isEffectPlaying` always exposes that active player state. The
-- separate `isEffectWaitComplete` query completes immediately when no output
-- completion clock is composed because there is no real playback lifecycle to
-- await.
-- fanfare state machine (the HGSS PlayFanfare path PAUSES the
-- BGM player: the sequence timeline freezes and the paused player's
-- channels are released with the forced release override -- no channel or
-- sample state is preserved; after the fanfare and its 15-tick post-play
-- wait the still-current BGM's timeline resumes, and a BGM replaced or
-- stopped during the fanfare is never resumed), fixed-tick fades (the
-- HGSS GF_SndStartFadeOutBGM/FadeInBGM model: the fade state carries
-- starting level/target/total duration/elapsed, the level ramps linearly
-- per tick into a dB-domain attenuation the player pushes to the mixer's
-- per-voice fader, a fade-out while one is active is skipped while a
-- fade-in restarts from silence, a fade never stops the BGM player, and
-- the fade timer is frozen while a fanfare is active per the HGSS
-- DoSoundUpdateFrame trace), and the cry boundary (a reachable cry without
-- a cry subsystem is an attributed failure; the cry data path is a
-- separate subsystem the production composition supplies). All polls
-- return booleans, never nil. The only injectable boundaries are the cry
-- subsystem and the map-music resolver (the field-music policy owner);
-- everything else runs the composed audio runtime. PCM rendering is the output
-- sink's business: GameSound never renders.
--
-- Fader ownership: each NNS player carries exactly one applied fader record
-- (level + at most one ramp) in this module. Script music fades, generic
-- sequence-volume moves, and fade-stop operations all create/replace that
-- same ramp, so no second authority can write the player. SequencePlayer
-- owns the instance fader used for voice updates; this module is the only
-- semantic ramp generator in the field-audio stack.

local Errors = require("libs.errors.src.Errors")
local AudioErrors = require("libs.hgss.src.audio.AudioErrors")
local PlayerFaderTimeline = require("libs.hgss.src.audio.PlayerFaderTimeline")

---@class GameSound
---@field private _provider AudioAssetProvider
---@field private _player SequencePlayer
---@field private _completionAvailable boolean
---@field private _cry table<string, unknown>?
---@field private _mapMusic fun(): integer|string|nil?
---@field private _currentMusic integer|nil
---@field private _queuedMusicReplacement GameSoundQueuedMusicReplacement|nil
---@field private _fanfare table<string, unknown>|nil
---@field private _faders table<integer, GameSoundPlayerFader>
---@field private _handles table<integer, table<string, unknown>>
---@field private _faderTimeline PlayerFaderTimeline
---@field private _cryActive boolean
---@field new fun(opts: { provider: AudioAssetProvider, player: SequencePlayer, completionAvailable: boolean?, cry: table<string, unknown>?, mapMusic: fun(): integer|string|nil? }): GameSound
---@field play fun(self: GameSound, idOrSymbol: integer|string)
---@field stop fun(self: GameSound, idOrSymbol: integer|string)
---@field isEffectPlaying fun(self: GameSound, idOrSymbol: integer|string): boolean
---@field isEffectWaitComplete fun(self: GameSound, idOrSymbol: integer|string): boolean
---@field playMusic fun(self: GameSound, idOrSymbol: integer|string)
---@field stopMusic fun(self: GameSound)
---@field currentMusic fun(self: GameSound): integer?
---@field playFanfare fun(self: GameSound, idOrSymbol: integer|string)
---@field isFanfarePlaying fun(self: GameSound): boolean
---@field playCry fun(self: GameSound, species: integer, pattern: integer)
---@field isCryFinished fun(self: GameSound): boolean
---@field fadeMusicOut fun(self: GameSound, spec: { target: integer, durationTicks: integer })
---@field fadeMusicIn fun(self: GameSound, spec: { durationTicks: integer })
---@field queueMusicReplacement fun(self: GameSound, idOrSymbol: integer|string, durationTicks: integer)
---@field isMusicFadeActive fun(self: GameSound): boolean
---@field resetMusic fun(self: GameSound)
---@field temporaryMusic fun(self: GameSound, idOrSymbol: integer|string)
---@field updateSoundFrame fun(self: GameSound)
---@field moveSequenceVolume fun(self: GameSound, idOrSymbol: integer|string, target: integer, durationFrames: integer)
---@field stopSequenceWithFade fun(self: GameSound, idOrSymbol: integer|string, durationFrames: integer)
---@field playWithBankOverride fun(self: GameSound, sequenceRef: integer|string, bankRef: integer|string)

-- One applied fader timeline per NNS player. `level` is the level this
-- module last asked SequencePlayer to apply (always 0..127 after the apply
-- boundary normalizes the source full-restore spelling 128). `ramp` is nil
-- or the one active ramp owning the player; `kind` tags a script music fade
-- ("music") so the BGM facade can answer its source fade polls without a
-- second level accumulator.
---@class GameSoundPlayerFader
---@field level integer
---@field ramp GameSoundFaderRamp?

-- A single ramp owning one logical player's canonical-handle fader for
-- `durationFrames` source frames. `start` is the applied level at creation; `target` is the source
-- volume-domain goal (may be the full-restore spelling 128); the applied
-- level interpolates with the source cDiv formula and is normalized to
-- 0..127 only when it reaches SequencePlayer:setFader.
---@class GameSoundFaderRamp
---@field start integer
---@field target integer
---@field durationFrames integer
---@field elapsedFrames integer
---@field kind "music"|"generic"
---@field stopWhenDone boolean

---@class GameSoundQueuedMusicReplacement
---@field sourceMusicId integer
---@field sourcePlayerId integer
---@field destinationId integer

local GameSound = {}
GameSound.__index = GameSound

-- The post-fanfare wait interval in ordinary source frames: HGSS PlayFanfare
-- sets a u16 timer to 0x0F and the fanfare stays "playing" until it counts
-- down after the fanfare player stops. At 30 Hz, 15 frames is about 500 ms.
local FANFARE_POST_WAIT_FRAMES = 15

-- The strict handle fader domain (SequencePlayer:setHandleFader asserts 0..127)
-- and the source full-restore spelling accepted only at the GameSound
-- boundary (HGSS GF_SndHandleMoveVolume(0, 128, 15) on soundplate exit).
local PLAYER_FADER_FULL = 127
local SOURCE_FULL_RESTORE = 128

---@param opts { provider: AudioAssetProvider, player: SequencePlayer, completionAvailable: boolean?, cry: table<string, unknown>?, mapMusic: fun(): integer|string|nil? }
---@return GameSound
function GameSound.new(opts)
  assert(opts and opts.provider and opts.player, "GameSound requires a provider and a player")
  if opts.cry then
    assert(
      type(opts.cry.play) == "function" and type(opts.cry.isFinished) == "function",
      "cry subsystem requires play and isFinished"
    )
  end
  if opts.mapMusic then
    assert(type(opts.mapMusic) == "function", "mapMusic resolver must be callable")
  end
  local self = {
    _provider = opts.provider,
    _player = opts.player,
    _completionAvailable = opts.completionAvailable ~= false,
    _cry = opts.cry,
    _mapMusic = opts.mapMusic,
    _currentMusic = nil,
    _queuedMusicReplacement = nil,
    _fanfare = nil,
    _faders = {},
    _faderTimeline = PlayerFaderTimeline.new(),
    _handles = {},
    _cryActive = false,
  } ---@type GameSound
  return setmetatable(self, GameSound)
end

-- Starts a resolved sequence on the engine player and resets fader bookkeeping
-- only when the engine attaches a fresh instance.
---@param sequence table<string, unknown>
---@return boolean
function GameSound:_startResolvedSequence(sequence)
  local bank = self._provider:bank(sequence.bankId)
  local accepted = self._player:play(self:_handleForPlayer(sequence.player.id), sequence, bank)
  if accepted then
    self:_resetPlayerFader(sequence.player.id)
  end
  return accepted
end

-- Resolves a sequence reference and starts it on the engine player, returning
-- the resolved sequence for the caller's bookkeeping.
---@param idOrSymbol integer|string
---@return table<string, unknown>, boolean
function GameSound:_startSequence(idOrSymbol)
  local sequence = self._provider:sequence(idOrSymbol)
  local accepted = self:_startResolvedSequence(sequence)
  return sequence, accepted
end

---@param playerId integer
---@return table<string, unknown>
function GameSound:_handleForPlayer(playerId)
  local handle = self._handles[playerId]
  if handle == nil then
    handle = self._player:createHandle()
    self._handles[playerId] = handle
  end
  return handle
end

-- The fader record for `playerId`, created at the known actual full level
-- 127 when the player has no record yet. A player that never started a
-- sequence in this module is still created at full because that is what a
-- fresh SequencePlayer instance starts at; the record is only ever written
-- after a real sequence start or a ramp application.
---@param playerId integer
---@return GameSoundPlayerFader
function GameSound:_faderFor(playerId)
  local fader = self._faders[playerId]
  if fader == nil then
    fader = { level = PLAYER_FADER_FULL, ramp = nil }
    self._faders[playerId] = fader
  end
  return fader
end

-- Synchronizes the player's fader record to the state SequencePlayer actually
-- holds after creating a fresh instance: full level and no active ramp.
---@param playerId integer
function GameSound:_resetPlayerFader(playerId)
  self._faderTimeline:reset(playerId, PLAYER_FADER_FULL)
  self._faders[playerId] = { level = PLAYER_FADER_FULL, ramp = nil }
end

-- Applies a volume-domain level to the player through the strict
-- SequencePlayer:setHandleFader contract, normalizing the source full-restore
-- spelling 128 to the player full level 127 exactly at this boundary.
-- Returns the level actually applied, so the module's record always matches
-- what SequencePlayer holds.
---@param playerId integer
---@param level integer
---@return integer
function GameSound:_applyFader(playerId, level)
  if level > PLAYER_FADER_FULL then
    level = PLAYER_FADER_FULL
  end
  self._player:setHandleFader(self:_handleForPlayer(playerId), level)
  return level
end

-- Creates (or replaces) the player's single ramp. The ramp interpolates from
-- the current applied level -- never from a stale original-ramp start -- and
-- carries the source target: a full-restore spelling 128 ramps toward 128
-- and is normalized to 127 only when the interpolated level is applied, so
-- the exact final-frame value matches the source move. The start level is
-- pushed to the player immediately, matching the HGSS command's first volume
-- move happening in its start tick rather than on the first fixed tick.
-- `kind` tags script music fades for the BGM facade polls; `stopWhenDone`
-- makes the final applied frame stop the player.
---@param playerId integer
---@param target integer
---@param durationFrames integer
---@param kind "music"|"generic"
---@param stopWhenDone boolean
function GameSound:_replaceFaderRamp(playerId, target, durationFrames, kind, stopWhenDone)
  if self._queuedMusicReplacement ~= nil and self._queuedMusicReplacement.sourcePlayerId == playerId then
    self._queuedMusicReplacement = nil
  end
  local fader = self:_faderFor(playerId)
  fader.ramp = {
    start = fader.level,
    target = target,
    durationFrames = durationFrames,
    elapsedFrames = 0,
    kind = kind,
    stopWhenDone = stopWhenDone,
  }
  self._faderTimeline:replace(playerId, target, durationFrames, function(level)
    fader.level = self:_applyFader(playerId, level)
    return fader.level
  end, function()
    fader.ramp = nil
    if stopWhenDone then
      self._player:stopHandle(self:_handleForPlayer(playerId))
      self:_resetPlayerFader(playerId)
    elseif
      self._queuedMusicReplacement ~= nil
      and kind == "music"
      and self._queuedMusicReplacement.sourceMusicId == self._currentMusic
      and self._queuedMusicReplacement.sourcePlayerId == playerId
    then
      local destinationId = self._queuedMusicReplacement.destinationId
      self._queuedMusicReplacement = nil
      self:_stopBgmPlayer()
      local destination = self:_startSequence(destinationId)
      self._currentMusic = destination.id
    end
  end)
end

-- Stops only the recorded BGM sequence and releases its canonical handle;
-- detached siblings in the same logical player remain active.
function GameSound:_stopBgmPlayer()
  if self._currentMusic == nil then
    return
  end
  local bgm = self._provider:sequence(self._currentMusic)
  self._player:stopSequence(bgm.id)
  self._player:releaseHandle(self:_handleForPlayer(bgm.player.id))
  if not self._player:isPlayerPlaying(bgm.player.id) then
    self:_resetPlayerFader(bgm.player.id)
  end
end

-- `play` is the effect (SE) path: the sequence runs on its own player id,
-- so a later effect on the same player reuses its canonical handle and
-- replaces the earlier attachment while the player stays busy -- exactly
-- what an HGSS WaitSE observes through the player-state query.
---@param idOrSymbol integer|string
function GameSound:play(idOrSymbol)
  self:_startSequence(idOrSymbol)
end

-- Stops every instance of the requested sequence ID. Effect waits remain
-- player-scoped, so a surviving sibling keeps the logical player busy. A
-- surviving canonical attachment also keeps its fader record and ramp.
---@param idOrSymbol integer|string
function GameSound:stop(idOrSymbol)
  local sequence = self._provider:sequence(idOrSymbol)
  self._player:stopSequence(sequence.id)
  local handle = self._handles[sequence.player.id]
  if handle == nil or not self._player:isHandlePlaying(handle) then
    self:_resetPlayerFader(sequence.player.id)
  end
end

-- True while the sequence's player has a running sequence. An unresolvable
-- reference surfaces the provider's unknown-sequence failure: a poll never
-- answers nil.
---@param idOrSymbol integer|string
---@return boolean
function GameSound:isEffectPlaying(idOrSymbol)
  local sequence = self._provider:sequence(idOrSymbol)
  return self._player:isPlayerPlaying(sequence.player.id)
end

-- True when a script wait on the effect may resume. A sinkless composition
-- still exposes active player state through isEffectPlaying, but has no clock
-- that can ever retire a finite sequence, so there is no completion to await.
---@param idOrSymbol integer|string
---@return boolean
function GameSound:isEffectWaitComplete(idOrSymbol)
  local sequence = self._provider:sequence(idOrSymbol)
  if not self._completionAvailable then
    return true
  end
  return not self._player:isPlayerPlaying(sequence.player.id)
end

-- Starts `idOrSymbol` as the current BGM. The requested identity is recorded
-- after the admission attempt even when no instance is attached; allocation
-- and semantic current-music bookkeeping are separate state domains.
---@param idOrSymbol integer|string
function GameSound:playMusic(idOrSymbol)
  self._queuedMusicReplacement = nil
  local sequence = self:_startSequence(idOrSymbol)
  self._currentMusic = sequence.id
end

-- Stops the current BGM, drops the reference, and cancels its fade (a
-- music fade belongs to the BGM it fades; the StopBGM operand is an
-- erasure both at lowering and here -- the service takes no arguments).
function GameSound:stopMusic()
  self._queuedMusicReplacement = nil
  self:_stopBgmPlayer()
  self._currentMusic = nil
end

-- The resolved id of the current BGM reference, or nil while silent. The
-- reference survives a fade-out to 0 so a later fade-in can restore it.
---@return integer?
function GameSound:currentMusic()
  return self._currentMusic
end

-- The fanfare machine, per the HGSS PlayFanfare path: the BGM player is
-- PAUSED -- its timeline freezes and the pause releases the player's
-- channels with the forced release override, so no channel or sample state
-- survives the pause -- and the fanfare plays through its own player, then
-- the post-play wait is held on field ticks before the pause lifts. Only
-- the still-current BGM is resumed at completion; a BGM replaced or stopped
-- during the fanfare is never resumed, even if its detached instance remains
-- active. Without a current BGM the pause is a no-op.
---@param idOrSymbol integer|string
function GameSound:playFanfare(idOrSymbol)
  local sequence = self._provider:sequence(idOrSymbol)
  self._fanfare = { playerId = sequence.player.id, frames = FANFARE_POST_WAIT_FRAMES }
  if self._currentMusic ~= nil then
    local bgm = self._provider:sequence(self._currentMusic)
    self._player:pauseHandle(self:_handleForPlayer(bgm.player.id))
  end
  self:_startResolvedSequence(sequence)
end

---@return boolean
function GameSound:isFanfarePlaying()
  return self._fanfare ~= nil
end

-- Queues a changed field BGM behind one source fade. The destination remains
-- private until the source ramp completes; a later request only retargets the
-- existing queue and never changes its elapsed frame count.
---@param idOrSymbol integer|string
---@param durationTicks integer
function GameSound:queueMusicReplacement(idOrSymbol, durationTicks)
  local destination = self._provider:sequence(idOrSymbol)
  assert(
    durationTicks > 0 and durationTicks % 1 == 0,
    "queued music replacement duration must be a positive tick count"
  )

  if self._queuedMusicReplacement ~= nil then
    self._queuedMusicReplacement.destinationId = destination.id
    return
  end

  if self._currentMusic == nil then
    self:_startResolvedSequence(destination)
    self._currentMusic = destination.id
    return
  end

  if destination.id == self._currentMusic then
    return
  end

  local source = self._provider:sequence(self._currentMusic)
  local fader = self:_faderFor(source.player.id)
  if fader.ramp == nil or fader.ramp.kind ~= "music" then
    self:_replaceFaderRamp(source.player.id, 0, durationTicks, "music", false)
  end
  self._queuedMusicReplacement = {
    sourceMusicId = source.id,
    sourcePlayerId = source.player.id,
    destinationId = destination.id,
  }
end

-- The cry boundary. Without an injected cry subsystem a reachable cry is
-- an attributed failure; the cry data path is a separate subsystem and
-- plays through it when injected, with the facade tracking activity for
-- the wait and stability predicates.
---@param species integer
---@param pattern integer
function GameSound:playCry(species, pattern)
  if self._cry == nil then
    Errors.raise(AudioErrors.AUDIO_CRY_UNAVAILABLE, "no cry subsystem is available", {
      species = species,
      pattern = pattern,
    })
  end
  self._cry:play(species, pattern)
  self._cryActive = true
end

---@return boolean
function GameSound:isCryFinished()
  if not self._cryActive then
    return true
  end
  if self._cry:isFinished() then
    self._cryActive = false
    return true
  end
  return false
end

-- Starts a fade-out from the current music level to the target level over
-- the requested ticks (the HGSS GF_SndStartFadeOutBGM model: the first
-- script operand is a target LEVEL, 0..127). A fade while the current music
-- still owns an active script-music fade is skipped -- the HGSS fade timer
-- is nonzero, so the volume move is ignored -- and with no current BGM the
-- fade never starts and the script wait completes immediately. The ramp is
-- the player's single unified ramp, tagged as a music fade.
---@param spec { target: integer, durationTicks: integer }
function GameSound:fadeMusicOut(spec)
  if self._currentMusic == nil then
    return
  end
  local bgm = self._provider:sequence(self._currentMusic)
  local playerId = bgm.player.id
  local fader = self:_faderFor(playerId)
  if fader.ramp ~= nil and fader.ramp.kind == "music" then
    return
  end
  assert(spec.target ~= nil and spec.durationTicks, "fade-out spec requires a target and a duration")
  assert(spec.target >= 0 and spec.target <= 127, "fade-out target must be a level in 0..127")
  assert(spec.durationTicks > 0 and spec.durationTicks % 1 == 0, "fade-out duration must be a positive tick count")
  self:_replaceFaderRamp(playerId, spec.target, spec.durationTicks, "music", false)
end

-- Starts a fade-in: the BGM first snaps to silence, then ramps to full
-- over the requested ticks (the HGSS GF_SndStartFadeInBGM path, which
-- moves the volume to 0 with a zero-length ramp before the real one).
-- Unlike a fade-out there is no active-fade guard: a fade-in issued while
-- a fade is active replaces it (snap + new duration). The BGM player is
-- never replayed -- the fade only moves the level of the still-playing
-- player.
---@param spec { durationTicks: integer }
function GameSound:fadeMusicIn(spec)
  self._queuedMusicReplacement = nil
  if self._currentMusic == nil then
    return
  end
  assert(spec.durationTicks, "fade-in spec requires a duration")
  assert(spec.durationTicks > 0 and spec.durationTicks % 1 == 0, "fade-in duration must be a positive tick count")
  local bgm = self._provider:sequence(self._currentMusic)
  local playerId = bgm.player.id
  local fader = self:_faderFor(playerId)
  -- The fade-in snap: the unified level becomes 0 immediately and the player
  -- hears it before the ramp starts (the HGSS zero-length move). The ramp
  -- creation pushes the snapped 0 as its start level.
  fader.level = 0
  fader.ramp = nil
  self._faderTimeline:reset(playerId, 0)
  self:_replaceFaderRamp(playerId, PLAYER_FADER_FULL, spec.durationTicks, "music", false)
end

---@return boolean
function GameSound:isMusicFadeActive()
  if self._currentMusic == nil then
    return false
  end
  local bgm = self._provider:sequence(self._currentMusic)
  local fader = self._faders[bgm.player.id]
  return fader ~= nil and fader.ramp ~= nil and fader.ramp.kind == "music"
end

-- Plays the map-header music reference from the injected field-policy
-- resolver. A nil resolver result means the map has no music: the current
-- BGM stops. Without a resolver the reset is an attributed failure rather
-- than a guess.
function GameSound:resetMusic()
  if self._mapMusic == nil then
    Errors.raise(AudioErrors.AUDIO_MAP_MUSIC_UNAVAILABLE, "no map-music resolver is available", {})
  end
  local reference = self._mapMusic()
  if reference == nil then
    self:stopMusic()
    return
  end
  self:playMusic(reference)
end

-- The temporary-music path (ScrCmd_TempBGM): the referenced special-music
-- sequence starts on its own player slot (the retail corpus always targets
-- the special scripted-music player) and becomes the current BGM identity
-- for the purposes of stop/fade/query operations, but does NOT update the
-- base field-music reference (that remains separate for soundplate bank
-- selection and future resetMusic).
---@param idOrSymbol integer|string
function GameSound:temporaryMusic(idOrSymbol)
  self._queuedMusicReplacement = nil
  local sequence = self:_startSequence(idOrSymbol)
  self._currentMusic = sequence.id
end

-- Advances the game-semantic audio state once per ordinary source frame: the
-- fanfare post-play wait (and the resume it ends with) first, then the
-- per-player fader ramps. The fanfare runs before the ramps so the
-- fanfare-completion frame decides whether a script music fade stays frozen:
-- while a fanfare is active the HGSS DoSoundUpdateFrame trace only
-- decrements the fade timer when no fanfare is playing, so the music fade
-- ramp is skipped while generic ramps keep advancing (only the script music
-- fade carries the freeze).
function GameSound:updateSoundFrame()
  if self._cry ~= nil and type(self._cry.update) == "function" then
    self._cry:update()
  end
  if self._fanfare ~= nil and not self._player:isPlayerPlaying(self._fanfare.playerId) then
    self._fanfare.frames = self._fanfare.frames - 1
    if self._fanfare.frames <= 0 then
      self:_completeFanfare()
    end
  end
  self:_advanceFaderRamps()
end

-- Advances each player's single ramp once per sound frame. Iteration is in
-- ascending player-id order (never pairs()) so simultaneous ramp
-- completions/stops are deterministic. Each active ramp applies exactly one
-- interpolated level per frame; a ramp completes -- and, when requested,
-- stops the player -- only after its final frame has applied the target
-- level. The script music fade freeze is the fanfare's: while a fanfare is
-- active, ramps tagged as music fades do not advance.
function GameSound:_advanceFaderRamps()
  self._faderTimeline:update(function(playerId)
    local fader = self._faders[playerId]
    return fader ~= nil and not (self._fanfare ~= nil and fader.ramp ~= nil and fader.ramp.kind == "music")
  end)
end

-- Releases the fanfare handle and lifts the current BGM's transport pause.
-- Resume never resurrects a previous current-music handle.
function GameSound:_completeFanfare()
  local playerId = self._fanfare.playerId
  self._fanfare = nil
  self._player:stopHandle(self:_handleForPlayer(playerId))
  if self._currentMusic ~= nil then
    local bgm = self._provider:sequence(self._currentMusic)
    self._player:resumeHandle(self:_handleForPlayer(bgm.player.id))
  end
end

-- Moves a sequence's player fader to the target level over the duration in
-- source frames using frame-exact linear interpolation. The target is
-- an integer in the source volume domain 0..128: the HGSS full-restore
-- spelling 128 is accepted (and normalized to player level 127 at the apply
-- boundary) while any other out-of-domain value is a programming-contract
-- violation. Starting a new ramp replaces any active ramp on the same
-- player from the current applied level, and replaces a script music fade
-- ramp -- which also ends that fade's timer because no active script fade
-- remains to poll.
---@param idOrSymbol integer|string
---@param target integer
---@param durationFrames integer
function GameSound:moveSequenceVolume(idOrSymbol, target, durationFrames)
  assert(target >= 0 and target <= SOURCE_FULL_RESTORE, "volume target must be an integer in 0..128")
  assert(durationFrames > 0 and durationFrames % 1 == 0, "fader ramp duration must be a positive integer")

  local sequence = self._provider:sequence(idOrSymbol)
  self:_replaceFaderRamp(sequence.player.id, target, durationFrames, "generic", false)
end

-- Stops a sequence's player after fading to silence over the duration in
-- source frames. The player stops only after the final ramp frame has
-- applied level 0. Used by soundplate environmental audio to fade out
-- before stopping.
---@param idOrSymbol integer|string
---@param durationFrames integer
function GameSound:stopSequenceWithFade(idOrSymbol, durationFrames)
  assert(durationFrames > 0 and durationFrames % 1 == 0, "fade-stop duration must be a positive integer")

  local sequence = self._provider:sequence(idOrSymbol)
  self:_replaceFaderRamp(sequence.player.id, 0, durationFrames, "generic", true)
end

-- Starts `sequenceRef` with an explicit donor bank `bankRef` whose id may
-- differ from the sequence's declared bankId. This is the sole
-- bank-mismatch exception for environmental donor-bank soundplates. The
-- fader bookkeeping is reset exactly like any fresh sequence start.
---@param sequenceRef integer|string
---@param bankRef integer|string
function GameSound:playWithBankOverride(sequenceRef, bankRef)
  local sequence = self._provider:sequence(sequenceRef)
  local bank = self._provider:bank(bankRef)
  local accepted = self._player:playWithBankOverride(self:_handleForPlayer(sequence.player.id), sequence, bank)
  if accepted then
    self:_resetPlayerFader(sequence.player.id)
  end
end

return GameSound
