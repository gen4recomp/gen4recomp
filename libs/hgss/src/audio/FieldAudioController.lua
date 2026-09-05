-- FieldAudioController: the stateful field-audio policy service. Owns the
-- current field map audio record, effective field-music selection (day/night
-- + flag overrides + persisted override), soundplate selection and
-- environmental audio state, and delegating the script audio facade (play,
-- stop, playMusic, etc.) to the composed GameSound instance.
--
-- Field-music policy:
-- 1. mapHeaderMusic(): day/night selection + flag-based map override
-- 2. effectiveMusic(): persisted override > map-header
-- 3. resetMusic(): map-header only (ignores persisted)
--
-- Soundplate/environment policy:
-- - Selection: iterate source-order records, keep last (highest) match
-- - Active gate: test selected plate's disabledWhenFlag (no fallback if disabled)
-- - Volume ramps: BGM duck + ambient moves via GameSound:moveSequenceVolume
-- - Exit: fade-stop environment, restore BGM to level 128

local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")

---@class FieldAudioControllerOptions
---@field sound GameSound
---@field provider AudioAssetProvider
---@field eventState unknown
---@field fieldPosition fun(): integer, integer
---@field dayNight fun(): "day"|"night"
---@field fieldDataForMap fun(mapId: integer|string): unknown

---@class FieldAudioController
---@field private _sound GameSound
---@field private _provider AudioAssetProvider
---@field private _fieldPosition fun(): integer, integer
---@field private _dayNight fun(): "day"|"night"
---@field private _fieldDataForMap fun(mapId: integer|string): unknown
---@field _currentMap unknown
---@field _fieldMusic integer|nil
---@field _musicOverride integer|nil
---@field _environment { sequence: integer }|nil
---@field _pendingFieldMusicPolicy FieldAudioControllerPendingMusicPolicy|nil
---@field _eventState unknown
---@field isEffectPlaying fun(self: FieldAudioController, idOrSymbol: integer|string): boolean
---@field isEffectWaitComplete fun(self: FieldAudioController, idOrSymbol: integer|string): boolean
local FieldAudioController = {}
FieldAudioController.__index = FieldAudioController

---@class FieldAudioController.RuntimeMap
---@field fieldData table<string, unknown>

---@class FieldAudioControllerPendingMusicPolicy
---@field sourceMusicId integer
---@field destinationMusicId integer
---@field target integer|nil
---@field durationFrames integer

---@param opts FieldAudioControllerOptions
---@return FieldAudioController
function FieldAudioController.new(opts)
  assert(
    opts
      and opts.sound
      and opts.provider
      and opts.eventState
      and opts.fieldPosition
      and opts.dayNight
      and opts.fieldDataForMap,
    "FieldAudioController requires sound, provider, eventState, fieldPosition, dayNight, and fieldDataForMap"
  )
  assert(type(opts.fieldPosition) == "function", "fieldPosition must be a function")
  return setmetatable({
    _sound = opts.sound,
    _provider = opts.provider,
    _eventState = opts.eventState,
    _fieldPosition = opts.fieldPosition,
    _dayNight = opts.dayNight,
    _fieldDataForMap = opts.fieldDataForMap,
    _currentMap = nil,
    _fieldMusic = nil,
    _musicOverride = nil,
    _environment = nil,
    _pendingFieldMusicPolicy = nil,
  }, FieldAudioController)
end

-- Returns the map-header music reference: day/night selection + flag-based override.
-- Does NOT apply persisted overrides (those are part of effectiveMusic).
-- Resolves string symbols to numeric IDs using the provider.
-- @param fieldData optional field data; if omitted, uses current map's data
---@param fieldData table<string, unknown>?
---@return integer|nil
function FieldAudioController:mapHeaderMusic(fieldData)
  if fieldData == nil then
    if self._currentMap == nil then
      return nil
    end
    fieldData = self._currentMap.fieldData
  end
  if fieldData == nil or fieldData.music == nil then
    return nil
  end

  -- Start with day/night selection
  local dayNight = self._dayNight()
  local music = fieldData.music
  local sequence = music[dayNight]

  -- Apply flag-based map overrides in source order
  if music.flagOverrides ~= nil then
    for _, override in ipairs(music.flagOverrides) do
      if self._eventState:isFlagSet(override.flagId) then
        sequence = override.sequence
        break
      end
    end
  end

  -- Resolve string symbol to numeric ID
  if sequence ~= nil and type(sequence) == "string" then
    sequence = self._provider:sequence(sequence).id
  end

  return sequence
end

-- Loads a prepared map's selected music metadata without changing playback state.
---@param runtimeMap FieldAudioController.RuntimeMap
function FieldAudioController:prewarmMapMusic(runtimeMap)
  local reference = self:mapHeaderMusic(assert(runtimeMap.fieldData))
  if reference == nil then
    return
  end
  local sequence = self._provider:sequence(reference)
  self._provider:bank(sequence.bankId)
end

-- Returns the effective field music: persisted override > map-header
---@return integer|nil
function FieldAudioController:effectiveMusic()
  if self._musicOverride ~= nil then
    return self._musicOverride
  end
  return self:mapHeaderMusic()
end

-- Plays the map-header music (not effective music; ignores persisted override).
-- This is the source ResetBGM behavior.
function FieldAudioController:resetMusic()
  self._pendingFieldMusicPolicy = nil
  local reference = self:mapHeaderMusic()
  if reference == nil then
    self._sound:stopMusic()
    return
  end
  self._sound:playMusic(reference)
end

-- Sets the persisted field-music override (converts string to numeric ID)
---@param sequenceRef integer|string|nil
function FieldAudioController:setMusicOverride(sequenceRef)
  if sequenceRef ~= nil and type(sequenceRef) == "string" then
    sequenceRef = self._provider:sequence(sequenceRef --[[@as string]]).id
  end
  ---@cast sequenceRef integer|nil
  self._musicOverride = sequenceRef
end

-- Clears the persisted override
function FieldAudioController:clearMusicOverride()
  self._musicOverride = nil
end

-- Returns the current persisted override (numeric ID)
---@return integer|nil
function FieldAudioController:musicOverride()
  return self._musicOverride
end

-- Enters a map and optionally plays the effective music
-- Options: { clearMusicOverride, restoredMusicOverride, play }
---@param runtimeMap unknown
---@param options table<string, unknown>|nil
function FieldAudioController:enterMap(runtimeMap, options)
  options = options or {}

  -- 1. Deactivate source environment BEFORE replacing state, using old identities
  if self._environment ~= nil then
    local oldSequence = self._environment.sequence
    local oldFieldMusic = self._fieldMusic
    self._sound:stopSequenceWithFade(oldSequence, 10)
    if oldFieldMusic ~= nil then
      self._sound:moveSequenceVolume(oldFieldMusic, 128, 15)
    end
    self._environment = nil
  end

  -- 2. Install new current map
  self._currentMap = runtimeMap

  -- 3. Clear or restore persisted music override
  if options.clearMusicOverride then
    self._musicOverride = nil
  elseif options.restoredMusicOverride ~= nil then
    local override = options.restoredMusicOverride
    if type(override) == "string" then
      override = self._provider:sequence(override --[[@as string]]).id
    end
    ---@cast override integer|nil
    self._musicOverride = override
  end

  -- 4. Compute/store new base _fieldMusic from new map-header policy
  self._fieldMusic = self:mapHeaderMusic()

  -- 5. When play=true, play new effective BGM before ordinary soundplate selection
  if options.play then
    local effective = self:effectiveMusic()
    if effective == nil then
      self._sound:stopMusic()
    elseif effective ~= self._sound:currentMusic() then
      self._sound:playMusic(effective)
    end
  end

  -- 6. Ordinary soundplate selection on map entry, immediately after BGM (the
  -- source FieldMap_Init ordering for initial environmental audio).
  if options.play then
    local fieldX, fieldZ = self._fieldPosition()
    assert(type(fieldX) == "number" and type(fieldZ) == "number", "fieldPosition must return fieldX, fieldZ")
    self:_processSelection(fieldX, fieldZ)
  end
end

---@param runtimeMap FieldAudioController.RuntimeMap
function FieldAudioController:enterZone(runtimeMap)
  local currentMusic = self._sound:currentMusic()
  local destinationMusic = self:mapHeaderMusic(runtimeMap.fieldData)
  local changedMusic = currentMusic ~= nil and destinationMusic ~= nil and currentMusic ~= destinationMusic

  if changedMusic then
    local sourceMusicId = assert(currentMusic)
    local destinationMusicId = assert(destinationMusic)
    self._pendingFieldMusicPolicy = {
      sourceMusicId = sourceMusicId,
      destinationMusicId = destinationMusicId,
      target = 128,
      durationFrames = 15,
    }
  else
    self._pendingFieldMusicPolicy = nil
  end

  self:_deactivateSoundplate()
  self._musicOverride = nil
  self._currentMap = runtimeMap
  self._fieldMusic = destinationMusic
  local effective = self:effectiveMusic()
  if effective == nil then
    self._pendingFieldMusicPolicy = nil
    self._sound:stopMusic()
    self:updateField()
  elseif currentMusic == nil then
    self._sound:queueMusicReplacement(effective, 60)
    self:updateField()
  elseif effective == currentMusic then
    self:updateField()
  else
    self:updateField()
    self._sound:queueMusicReplacement(effective, 60)
  end
end

-- Pre-fade current BGM if destination map-header differs
---@param destinationMapId integer|string
function FieldAudioController:beginWarp(destinationMapId)
  local destData = self._fieldDataForMap(destinationMapId)
  if type(destData) ~= "table" then
    error("missing field data for destination " .. tostring(destinationMapId))
  end
  if destData.schema ~= FieldMapDataCache.FIELD_SCHEMA then
    error("field data schema mismatch for destination " .. tostring(destinationMapId))
  end
  if destData.mapId == nil then
    error("field data missing mapId for destination " .. tostring(destinationMapId))
  end
  if type(destinationMapId) == "number" and destData.mapId ~= destinationMapId then
    error("field data mapId mismatch for destination " .. tostring(destinationMapId))
  end

  -- Get destination map-header music using same policy as map entry
  local destFieldData = { music = destData.music, soundplates = destData.soundplates }
  local destMusic = self:mapHeaderMusic(destFieldData)

  -- If current BGM differs, start fade to 0 over 40 sound frames
  local currentMusic = self._sound:currentMusic()
  if destMusic ~= currentMusic then
    if currentMusic ~= nil and not self._sound:isMusicFadeActive() then
      self._sound:fadeMusicOut({ target = 0, durationTicks = 40 })
    end
  end
end

-- Internal: process soundplate selection for current coords
---@param fieldX integer
---@param fieldZ integer
function FieldAudioController:_processSelection(fieldX, fieldZ)
  if self._currentMap == nil or self._currentMap.fieldData == nil then
    return
  end

  local fieldData = self._currentMap.fieldData
  if fieldData.soundplates == nil or #fieldData.soundplates == 0 then
    if self._environment ~= nil then
      self:_deactivateSoundplate()
    end
    if self._pendingFieldMusicPolicy ~= nil then
      self._pendingFieldMusicPolicy.target = nil
    end
    return
  end

  local localX = fieldX % 32
  local localZ = fieldZ % 32

  -- Iterate soundplates in source order, keep last matching
  local selectedPlate = nil
  for _, plate in ipairs(fieldData.soundplates) do
    if localX >= plate.x and localX <= plate.xBounds and localZ >= plate.z and localZ <= plate.zBounds then
      selectedPlate = plate
    end
  end

  if selectedPlate ~= nil then
    -- Test disabled flag (no fallback if disabled)
    if selectedPlate.disabledWhenFlag ~= nil and self._eventState:isFlagSet(selectedPlate.disabledWhenFlag) then
      if self._pendingFieldMusicPolicy ~= nil then
        self._pendingFieldMusicPolicy.target = nil
      end
      return
    end

    -- Resolve selected sequence id
    local seqRecord = self._provider:sequence(selectedPlate.sequence)
    local seqId = seqRecord.id

    local shouldStart = self._environment == nil or self._environment.sequence ~= seqId
    if shouldStart then
      if selectedPlate.useFieldMusicBank then
        assert(self._fieldMusic ~= nil, "donor-bank soundplate requires base field music")
        local fieldBgm = self._provider:sequence(self._fieldMusic)
        self._sound:playWithBankOverride(selectedPlate.sequence, fieldBgm.bankId)
      else
        self._sound:play(selectedPlate.sequence)
      end
    end

    self._environment = { sequence = seqId }

    if selectedPlate.bgmTarget ~= nil and self._fieldMusic ~= nil then
      self:_applyOrDeferFieldMusicTarget(selectedPlate.bgmTarget, 15)
    elseif self._pendingFieldMusicPolicy ~= nil then
      self._pendingFieldMusicPolicy.target = nil
    end
    if selectedPlate.ambientTarget ~= nil then
      self._sound:moveSequenceVolume(selectedPlate.sequence, selectedPlate.ambientTarget, 5)
    end
  else
    if self._environment ~= nil then
      self:_deactivateSoundplate()
    end
    if self._pendingFieldMusicPolicy ~= nil then
      self._pendingFieldMusicPolicy.target = nil
    end
  end
end

-- Step-completion soundplate selection (the ordinary path).
function FieldAudioController:updateField()
  if self._currentMap == nil or self._currentMap.fieldData == nil then
    return
  end
  local fieldX, fieldZ = self._fieldPosition()
  assert(type(fieldX) == "number" and type(fieldZ) == "number", "fieldPosition must return fieldX, fieldZ")
  self:_processSelection(fieldX, fieldZ)
end

-- Forced soundplate processing for opcode 726: clear identity and process immediately.
function FieldAudioController:processSoundplate()
  self._environment = nil
  if self._currentMap == nil or self._currentMap.fieldData == nil then
    return
  end
  local fieldX, fieldZ = self._fieldPosition()
  assert(type(fieldX) == "number" and type(fieldZ) == "number", "fieldPosition must return fieldX, fieldZ")
  self:_processSelection(fieldX, fieldZ)
end

-- Deactivates the current soundplate: fades environment and restores BGM
function FieldAudioController:_deactivateSoundplate()
  if self._environment == nil then
    return
  end

  self._sound:stopSequenceWithFade(self._environment.sequence, 10)

  if self._fieldMusic ~= nil then
    self:_applyOrDeferFieldMusicTarget(128, 15)
  end

  self._environment = nil
end

-- Applies a soundplate BGM target immediately, or records it while a seamless
-- map replacement still owns the source player's music ramp.
---@param target integer
---@param durationFrames integer
function FieldAudioController:_applyOrDeferFieldMusicTarget(target, durationFrames)
  assert(target >= 0 and target <= 128, "volume target must be an integer in 0..128")
  assert(durationFrames > 0 and durationFrames % 1 == 0, "fader ramp duration must be a positive integer")

  local pending = self._pendingFieldMusicPolicy
  if pending ~= nil then
    pending.target = target
    pending.durationFrames = durationFrames
    return
  end

  if self._fieldMusic ~= nil then
    self._sound:moveSequenceVolume(self._fieldMusic, target, durationFrames)
  end
end

-- Delegates to GameSound:updateSoundFrame() for one ordinary source frame.
function FieldAudioController:updateSoundFrame()
  self._sound:updateSoundFrame()
  local pending = self._pendingFieldMusicPolicy
  if pending ~= nil then
    local current = self._sound:currentMusic()
    if current ~= nil and current == pending.destinationMusicId then
      self._pendingFieldMusicPolicy = nil
      if pending.target ~= nil then
        self._sound:moveSequenceVolume(current, pending.target, pending.durationFrames)
      end
    elseif current ~= pending.sourceMusicId or not self._sound:isMusicFadeActive() then
      self._pendingFieldMusicPolicy = nil
    end
  end
end

-- Script facade delegation to GameSound

function FieldAudioController:play(idOrSymbol)
  self._sound:play(idOrSymbol)
end

function FieldAudioController:stop(idOrSymbol)
  self._sound:stop(idOrSymbol)
end

function FieldAudioController:isEffectPlaying(idOrSymbol)
  return self._sound:isEffectPlaying(idOrSymbol)
end

function FieldAudioController:isEffectWaitComplete(idOrSymbol)
  return self._sound:isEffectWaitComplete(idOrSymbol)
end

function FieldAudioController:playMusic(idOrSymbol)
  self._pendingFieldMusicPolicy = nil
  self._sound:playMusic(idOrSymbol)
end

function FieldAudioController:stopMusic()
  self._pendingFieldMusicPolicy = nil
  self._sound:stopMusic()
end

function FieldAudioController:currentMusic()
  return self._sound:currentMusic()
end

function FieldAudioController:currentMapId()
  return self._currentMap and self._currentMap.mapId or nil
end

function FieldAudioController:playFanfare(idOrSymbol)
  self._sound:playFanfare(idOrSymbol)
end

function FieldAudioController:isFanfarePlaying()
  return self._sound:isFanfarePlaying()
end

function FieldAudioController:fadeMusicOut(spec)
  self._sound:fadeMusicOut(spec)
end

function FieldAudioController:fadeMusicIn(spec)
  self._pendingFieldMusicPolicy = nil
  self._sound:fadeMusicIn(spec)
end

function FieldAudioController:isMusicFadeActive()
  return self._sound:isMusicFadeActive()
end

function FieldAudioController:temporaryMusic(idOrSymbol)
  self._pendingFieldMusicPolicy = nil
  self._sound:temporaryMusic(idOrSymbol)
end

function FieldAudioController:playCry(species, pattern)
  self._sound:playCry(species, pattern)
end

function FieldAudioController:isCryFinished()
  return self._sound:isCryFinished()
end

-- Internal field-policy helpers (not script-facing)

function FieldAudioController:moveSequenceVolume(idOrSymbol, target, durationFrames)
  self._sound:moveSequenceVolume(idOrSymbol, target, durationFrames)
end

function FieldAudioController:stopSequenceWithFade(idOrSymbol, durationFrames)
  self._sound:stopSequenceWithFade(idOrSymbol, durationFrames)
end

return FieldAudioController
