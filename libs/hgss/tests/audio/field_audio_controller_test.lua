-- Durable controller state-machine coverage for field music and
-- environmental soundplates. The controller owns base field music
-- identity, persisted override, soundplate selection, donor-bank
-- routing, and map-entry lifecycle against the generated field
-- cache. No ROM is required.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local AudioFixture = require("tests.support.AudioFixture")
local AudioAssetProvider = require("libs.hgss.src.audio.AudioAssetProvider")
local VoiceMixer = require("libs.nds.src.nitro.sound.VoiceMixer")
local SequencePlayer = require("libs.nds.src.nitro.sound.SequencePlayer")
local GameSound = require("libs.hgss.src.audio.GameSound")
local FieldAudioController = require("libs.hgss.src.audio.FieldAudioController")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")

local T = {}

---@class FieldAudioControllerTest.FaderRamp
---@field start integer
---@field target integer
---@field durationFrames integer
---@field elapsedFrames integer

---@class FieldAudioControllerTest.Fader
---@field ramp FieldAudioControllerTest.FaderRamp|nil

---@class FieldAudioControllerTest.InspectableSound : GameSound
---@field _faders table<integer, FieldAudioControllerTest.Fader>

---@class FieldAudioControllerTest.SequencePlayer : SequencePlayer
---@field playWithBankOverride fun(self: FieldAudioControllerTest.SequencePlayer, handle: table, sequence: table, bank: table): boolean
---@field isPlayerPlaying fun(self: FieldAudioControllerTest.SequencePlayer, playerId: integer): boolean

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected structured error, got " .. tostring(err))
  Assert.equal(err.code, code)
end

local function voice(key)
  return {
    generator = { kind = "sample", sample = key },
    originalKey = 60,
    envelope = { attack = 127, decay = 0, sustain = 127, release = 127 },
    pan = 0,
  }
end

local function bankWithSamples(id, symbol, key)
  return AudioFixture.bank(id, symbol, { key }, {
    [0] = { kind = "direct", voice = voice(key) },
    [1] = { kind = "direct", voice = voice(key) },
  })
end

local SAMPLE_RATE = 48000

---@param opts table
---@return FieldAudioControllerTest.SequencePlayer
local function newSequencePlayer(opts)
  return SequencePlayer.new(opts) --[[@as FieldAudioControllerTest.SequencePlayer]]
end

---@param id integer
---@param symbol string
---@param bankId integer
---@param playerId integer
---@param instructions table[]
---@return AudioFixture.Sequence
local function seq(id, symbol, bankId, playerId, instructions)
  return AudioFixture.sequence(
    id,
    symbol,
    bankId,
    playerId,
    { entry = 1, initialTrackMask = 0x0001, instructions = instructions },
    {
      id = playerId,
      initialVolume = 127,
      playerPriority = 64,
      channelPriority = 64,
    }
  )
end

---@param sequences table<integer, AudioFixture.Sequence>
---@param banks table<integer, AudioFixture.Bank>
---@return AudioAssetProvider
local function providerFor(sequences, banks)
  local bundle = AudioFixture.bundle()
  local indexSequences, indexPlayers, sequenceBySymbol, indexBanks, bankBySymbol = {}, {}, {}, {}, {}
  for id, s in pairs(sequences) do
    indexSequences[id] = { id = id, symbol = s.symbol, bankId = s.bankId, playerId = s.player.id }
    sequenceBySymbol[s.symbol] = id
    if indexPlayers[s.player.id] == nil then
      indexPlayers[s.player.id] = { id = s.player.id, maxSequences = 16, channelMask = 0xFFFF }
    end
  end
  for id, b in pairs(banks) do
    indexBanks[id] = { id = id, symbol = b.symbol }
    bankBySymbol[b.symbol] = id
  end
  bundle.index.sequences = indexSequences
  bundle.index.players = indexPlayers
  bundle.index.banks = indexBanks
  bundle.index.sequenceBySymbol = sequenceBySymbol
  bundle.index.bankBySymbol = bankBySymbol
  bundle.sequences = sequences
  bundle.banks = banks
  local keyA = AudioFixture.key(1)
  local keyB = AudioFixture.key(2)
  bundle.samples = {
    [keyA] = AudioFixture.pcm16le({ 1000, 2000, 3000, 4000 }),
    [keyB] = AudioFixture.pcm16le({ 5000, 6000 }),
  }
  bundle.sampleMetadata = {
    [keyA] = AudioFixture.sampleMetadata(keyA, { frames = 4 }),
    [keyB] = AudioFixture.sampleMetadata(keyB, { frames = 2 }),
  }
  return AudioAssetProvider.new(AudioFixture.readyCache(bundle) --[[@as CacheFs]])
end

---@param provider AudioAssetProvider
---@param player SequencePlayer
---@return GameSound, table
local function recordingSound(provider, player)
  ---@class RecordingSound : GameSound
  ---@field _spy { moves: table[], stops: table[], fades: table[], plays: table[], playWithBankCalls: table[] }
  local sound = GameSound.new({ provider = provider, player = player }) --[[@as RecordingSound]]
  local spy = { moves = {}, stops = {}, fades = {}, plays = {}, playWithBankCalls = {} }
  local origPlayMusic = sound.playMusic
  sound.playMusic = function(self, idOrSymbol)
    spy.plays[#spy.plays + 1] = idOrSymbol
    return origPlayMusic(self, idOrSymbol)
  end
  local origMove = sound.moveSequenceVolume
  sound.moveSequenceVolume = function(self, ref, target, duration)
    spy.moves[#spy.moves + 1] = { ref = ref, target = target, duration = duration }
    return origMove(self, ref, target, duration)
  end
  local origStop = sound.stopSequenceWithFade
  sound.stopSequenceWithFade = function(self, ref, duration)
    spy.stops[#spy.stops + 1] = { ref = ref, duration = duration }
    return origStop(self, ref, duration)
  end
  local origFadeOut = sound.fadeMusicOut
  sound.fadeMusicOut = function(self, spec)
    spy.fades[#spy.fades + 1] = spec
    return origFadeOut(self, spec)
  end
  local orig = sound.playWithBankOverride
  sound.playWithBankOverride = function(self, seqRef, bankRef)
    spy.playWithBankCalls[#spy.playWithBankCalls + 1] = { seqRef = seqRef, bankRef = bankRef }
    return orig(self, seqRef, bankRef)
  end
  return sound, spy
end

local function eventState(flags)
  flags = flags or {}
  return {
    isFlagSet = function(_, flagId)
      return flags[flagId] == true
    end,
  }
end

local function fieldDataWithSoundplates(soundplates, music)
  music = music
    or {
      day = "SEQ_GS_T_WAKABA",
      night = "SEQ_GS_T_WAKABA",
      flagOverrides = {},
      traversalOverrides = {},
    }
  return {
    music = music,
    soundplates = soundplates,
    schema = FieldMapDataCache.FIELD_SCHEMA,
    mapId = 111,
    events = { warps = {}, background = {}, objects = {}, coordinates = {} },
  }
end

local function gameplayPlayer(fieldX, fieldZ)
  return {
    fieldX = fieldX,
    fieldZ = fieldZ,
  }
end

---@param fieldData table
---@return FieldAudioController.RuntimeMap
local function runtimeMap(fieldData)
  return { fieldData = fieldData }
end

local function prewarmProvider()
  local sequences = {
    [20] = { id = 20, bankId = 7 },
    [21] = { id = 21, bankId = 8 },
    [22] = { id = 22, bankId = 9 },
  }
  local calls = { sequences = {}, banks = {}, samples = 0 }
  local provider = {}
  function provider:sequence(id)
    calls.sequences[#calls.sequences + 1] = id
    return assert(sequences[id])
  end
  function provider:bank(id)
    calls.banks[#calls.banks + 1] = id
    return { id = id }
  end
  function provider:loadSample()
    calls.samples = calls.samples + 1
    error("prewarm must not load PCM samples", 0)
  end
  return provider, calls
end

local function prewarmSound()
  local state = {
    currentMusic = 10,
    playCalls = {},
    queueCalls = {},
    stopCalls = 0,
    fadeCalls = {},
    moveCalls = {},
  }
  local sound = {}
  function sound:currentMusic()
    return state.currentMusic
  end
  function sound:playMusic(id)
    state.playCalls[#state.playCalls + 1] = id
    state.currentMusic = id
  end
  function sound:queueMusicReplacement(id, duration)
    state.queueCalls[#state.queueCalls + 1] = { id = id, duration = duration }
    state.currentMusic = id
  end
  function sound:stopMusic()
    state.stopCalls = state.stopCalls + 1
    state.currentMusic = nil
  end
  function sound:isMusicFadeActive()
    return true
  end
  function sound:fadeMusicOut(spec)
    state.fadeCalls[#state.fadeCalls + 1] = spec
  end
  function sound:moveSequenceVolume(id, target, duration)
    state.moveCalls[#state.moveCalls + 1] = { id = id, target = target, duration = duration }
  end
  function sound:stopSequenceWithFade(id, duration)
    state.fadeCalls[#state.fadeCalls + 1] = { id = id, duration = duration }
  end
  return sound, state
end

local function prewarmController(provider, sound, dayNight, flags)
  local eventFlags = flags or {}
  local event = eventState(eventFlags)
  return FieldAudioController.new({
    sound = sound --[[@as GameSound]],
    provider = provider --[[@as AudioAssetProvider]],
    eventState = event,
    fieldPosition = function()
      return 0, 0
    end,
    dayNight = dayNight,
    fieldDataForMap = function()
      return nil
    end,
  }),
    eventFlags
end

local function musicScenario()
  local keyA = AudioFixture.key(1)
  local bgmA =
    seq(10, "SEQ_GS_T_WAKABA", 12, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local bgmB =
    seq(11, "SEQ_GS_UTSUGI_RABO", 12, 1, { { op = "note", key = 62, velocity = 127, duration = 1 }, { op = "end" } })
  local provider = providerFor({ [10] = bgmA, [11] = bgmB }, { [12] = bankWithSamples(12, "BANK_A", keyA) })
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local player = newSequencePlayer({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  local sound, spy = recordingSound(provider, player)
  local fdA = fieldDataWithSoundplates(
    {},
    { day = "SEQ_GS_T_WAKABA", night = "SEQ_GS_T_WAKABA", flagOverrides = {}, traversalOverrides = {} }
  )
  fdA.mapId = 111
  local fdB = fieldDataWithSoundplates(
    {},
    { day = "SEQ_GS_UTSUGI_RABO", night = "SEQ_GS_UTSUGI_RABO", flagOverrides = {}, traversalOverrides = {} }
  )
  fdB.mapId = 112
  local destination = fdB
  local controller = FieldAudioController.new({
    sound = sound,
    provider = provider,
    eventState = eventState(),
    fieldPosition = function()
      return 0, 0
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return destination
    end,
  })
  return controller, sound, spy, fdA, fdB, function(fieldData)
    destination = fieldData
  end
end

local function seamlessSoundplateScenario()
  local keyA = AudioFixture.key(1)
  local bgmA =
    seq(10, "SEQ_GS_T_WAKABA", 12, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local bgmB =
    seq(11, "SEQ_GS_UTSUGI_RABO", 12, 7, { { op = "note", key = 62, velocity = 127, duration = 1 }, { op = "end" } })
  local bgmC =
    seq(12, "SEQ_GS_T_TOBARI", 12, 7, { { op = "note", key = 64, velocity = 127, duration = 1 }, { op = "end" } })
  local environmentB =
    seq(20, "SEQ_SE_GS_N_SESERAGI", 12, 2, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local environmentC =
    seq(21, "SEQ_SE_GS_N_HUUSHA", 12, 2, { { op = "note", key = 62, velocity = 127, duration = 1 }, { op = "end" } })
  local provider = providerFor(
    { [10] = bgmA, [11] = bgmB, [12] = bgmC, [20] = environmentB, [21] = environmentC },
    { [12] = bankWithSamples(12, "BANK_A", keyA) }
  )
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local player = newSequencePlayer({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  local sound, spy = recordingSound(provider, player)
  local starts = {}
  local originalPlay = player.play
  player.play = function(self, handle, sequence, bankRecord)
    starts[sequence.id] = (starts[sequence.id] or 0) + 1
    return originalPlay(self, handle, sequence, bankRecord)
  end
  local fdA = fieldDataWithSoundplates(
    {},
    { day = "SEQ_GS_T_WAKABA", night = "SEQ_GS_T_WAKABA", flagOverrides = {}, traversalOverrides = {} }
  )
  fdA.mapId = 111
  local fdB = fieldDataWithSoundplates({
    {
      x = 0,
      xBounds = 31,
      z = 0,
      zBounds = 31,
      sequence = "SEQ_SE_GS_N_SESERAGI",
      useFieldMusicBank = false,
      bgmTarget = 64,
    },
  }, { day = "SEQ_GS_UTSUGI_RABO", night = "SEQ_GS_UTSUGI_RABO", flagOverrides = {}, traversalOverrides = {} })
  fdB.mapId = 112
  local fdC = fieldDataWithSoundplates({
    {
      x = 0,
      xBounds = 31,
      z = 0,
      zBounds = 31,
      sequence = "SEQ_SE_GS_N_HUUSHA",
      useFieldMusicBank = false,
      bgmTarget = 32,
    },
  }, { day = "SEQ_GS_T_TOBARI", night = "SEQ_GS_T_TOBARI", flagOverrides = {}, traversalOverrides = {} })
  fdC.mapId = 113
  local controller = FieldAudioController.new({
    sound = sound,
    provider = provider,
    eventState = eventState(),
    fieldPosition = function()
      return 0, 0
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return fdB
    end,
  })
  controller:enterMap({ fieldData = fdA }, { play = true })
  for id in pairs(starts) do
    starts[id] = nil
  end
  spy.plays = {}
  return controller, sound, player, starts, spy, fdA, fdB, fdC
end

function T.same_map_music_entry_preserves_the_running_sequence()
  local controller, sound, spy, fdA, fdB, setDestination = musicScenario()
  fdB.music.day = "SEQ_GS_T_WAKABA"
  fdB.music.night = "SEQ_GS_T_WAKABA"
  controller:enterMap({ fieldData = fdA }, { play = true })
  spy.plays = {}
  spy.fades = {}
  setDestination(fdB)
  controller:beginWarp(fdB.mapId)
  controller:enterMap({ fieldData = fdB }, { clearMusicOverride = true, play = true })
  Assert.equal(#spy.plays, 0, "map entry must not restart the current effective BGM")
  Assert.equal(#spy.fades, 0, "same-BGM map entry must not start a warp fade")
  Assert.equal(sound:currentMusic(), 10)
end

function T.seamless_zone_entry_clears_override_before_selecting_destination_music()
  local controller, sound, _, fdA, fdB = musicScenario()
  controller:enterMap({ fieldData = fdA }, { restoredMusicOverride = 10, play = true })
  Assert.equal(controller:musicOverride(), 10)

  controller:enterZone(runtimeMap(fdB))
  Assert.isNil(controller:musicOverride(), "zone entry clears the source music override immediately")

  for _ = 1, 60 do
    sound:updateSoundFrame()
  end
  Assert.equal(sound:currentMusic(), 11, "the destination map-header BGM replaces the overridden source")
end

function T.seamless_zone_entry_clears_matching_override_without_restarting_music()
  local controller, sound, spy, fdA, fdB = musicScenario()
  controller:enterMap({ fieldData = fdA }, { restoredMusicOverride = 11, play = true })
  Assert.equal(sound:currentMusic(), 11)
  spy.plays = {}

  controller:enterZone(runtimeMap(fdB))

  Assert.isNil(controller:musicOverride(), "zone entry clears even a matching override")
  Assert.equal(#spy.plays, 0, "same destination music does not restart at a seamless boundary")
  Assert.equal(sound:currentMusic(), 11, "the current BGM identity remains unchanged")
end

function T.seamless_zone_entry_selects_destination_soundplate_before_music_admission()
  local controller, sound, player, starts, _, _, fdB = seamlessSoundplateScenario()
  controller:enterZone(runtimeMap(fdB))

  Assert.equal(controller:currentMusic(), 10, "the source remains current during the seamless fade")
  Assert.equal(starts[20], 1, "the destination environment starts at zone entry")
  for _ = 1, 59 do
    controller:updateSoundFrame()
  end
  Assert.equal(controller:currentMusic(), 10, "the destination BGM remains queued before frame 60")
  Assert.isTrue(player:isPlayerPlaying(1), "the source player remains active before admission")

  controller:updateSoundFrame()
  controller:updateSoundFrame()
  Assert.equal(controller:currentMusic(), 11, "the destination BGM is admitted after the source fade")
  Assert.equal(starts[11], 1, "the destination BGM starts exactly once")
  Assert.isFalse(player:isPlayerPlaying(1), "the source BGM player is stopped after admission")
  local inspectableSound = sound --[[@as FieldAudioControllerTest.InspectableSound]]
  Assert.equal(
    assert(inspectableSound._faders[7].ramp).target,
    64,
    "the destination soundplate target applies after admission"
  )
end

function T.seamless_zone_without_soundplate_does_not_add_destination_fade()
  local controller, sound, _, fdA, fdB = musicScenario()
  controller:enterMap({ fieldData = fdA }, { play = true })
  controller:enterZone(runtimeMap(fdB))

  for _ = 1, 60 do
    controller:updateSoundFrame()
  end

  local inspectableSound = sound --[[@as FieldAudioControllerTest.InspectableSound]]
  local fader = assert(inspectableSound._faders[1])
  Assert.isNil(fader.ramp, "a destination without a soundplate must not add a BGM fade-in")
end

function T.seamless_zone_retarget_preserves_fade_and_latest_soundplate_policy()
  local controller, sound, _, starts, _, _, fdB, fdC = seamlessSoundplateScenario()
  controller:enterZone(runtimeMap(fdB))
  for _ = 1, 10 do
    controller:updateSoundFrame()
  end
  local inspectableSound = sound --[[@as FieldAudioControllerTest.InspectableSound]]
  local sourceFader = inspectableSound._faders[1]
  local sourceRamp = assert(sourceFader.ramp)
  local elapsedFrames = sourceRamp.elapsedFrames

  controller:enterZone(runtimeMap(fdC))
  Assert.equal(sourceFader.ramp, sourceRamp, "retargeting keeps the original source ramp")
  Assert.equal(sourceRamp.elapsedFrames, elapsedFrames, "retargeting does not reset elapsed fade time")
  Assert.isNil(starts[11], "the first destination BGM never starts")
  Assert.equal(starts[21], 1, "the latest destination environment starts once")

  for _ = 1, 50 do
    controller:updateSoundFrame()
  end
  Assert.equal(controller:currentMusic(), 12, "the latest destination BGM is admitted on the original schedule")
  Assert.isNil(starts[11], "the superseded destination BGM remains unstarted")
  Assert.equal(starts[12], 1, "the latest destination BGM starts exactly once")
  controller:updateSoundFrame()
  Assert.equal(assert(inspectableSound._faders[7].ramp).target, 32, "the latest destination soundplate target wins")
end

function T.canceled_zone_music_drops_deferred_soundplate_policy()
  local controller, sound, _, _, _, _, fdB = seamlessSoundplateScenario()
  controller:enterZone(runtimeMap(fdB))
  Assert.isTrue(controller._pendingFieldMusicPolicy ~= nil, "a changed-BGM entry owns deferred plate policy")

  sound:stopMusic()
  controller:updateSoundFrame()

  Assert.isNil(controller._pendingFieldMusicPolicy, "canceled music must discard deferred plate policy")
end

function T.fade_in_cancels_deferred_zone_music_policy()
  local controller, _, _, _, _, _, fdB = seamlessSoundplateScenario()
  controller:enterZone(runtimeMap(fdB))
  Assert.isTrue(controller._pendingFieldMusicPolicy ~= nil, "a changed-BGM entry owns deferred plate policy")

  controller:fadeMusicIn({ durationTicks = 3 })

  Assert.isNil(controller._pendingFieldMusicPolicy, "a canceled queue must discard deferred plate policy")
end

function T.different_map_music_entry_starts_the_destination_once()
  local controller, sound, spy, fdA, fdB = musicScenario()
  controller:enterMap({ fieldData = fdA }, { play = true })
  spy.plays = {}
  controller:beginWarp(fdB.mapId)
  controller:enterMap({ fieldData = fdB }, { clearMusicOverride = true, play = true })
  Assert.equal(#spy.plays, 1, "different destination BGM must start exactly once")
  Assert.equal(spy.plays[1], 11)
  Assert.equal(#spy.fades, 1, "different destination BGM must retain the pre-fade")
  Assert.equal(sound:currentMusic(), 11)
end

function T.clearing_an_override_compares_against_actual_playback()
  local controller, sound, spy, fdA, fdB = musicScenario()
  fdA.music.day = "SEQ_GS_UTSUGI_RABO"
  fdA.music.night = "SEQ_GS_UTSUGI_RABO"
  controller:enterMap({ fieldData = fdA }, { restoredMusicOverride = 10, play = true })
  Assert.equal(sound:currentMusic(), 10)
  spy.plays = {}
  controller:enterMap({ fieldData = fdB }, { clearMusicOverride = true, play = true })
  Assert.equal(#spy.plays, 1, "clearing an override must start a different effective destination BGM")
  Assert.equal(spy.plays[1], 11)
  Assert.equal(sound:currentMusic(), 11)
end

function T.explicit_same_music_command_restarts_through_the_generic_service()
  local controller, sound, spy, fdA = musicScenario()
  controller:enterMap({ fieldData = fdA }, { play = true })
  spy.plays = {}
  sound:playMusic(10)
  Assert.equal(#spy.plays, 1, "explicit same-ID playMusic must remain restart-capable")
  Assert.equal(sound:currentMusic(), 10)
end

function T.map_entry_with_play_disabled_does_not_change_music()
  local controller, sound, spy, fdA, fdB = musicScenario()
  controller:enterMap({ fieldData = fdA }, { play = true })
  spy.plays = {}
  spy.stops = {}
  controller:enterMap({ fieldData = fdB }, { clearMusicOverride = true, play = false })
  Assert.equal(#spy.plays, 0, "play=false map entry must not start music")
  Assert.equal(#spy.stops, 0, "play=false map entry must not stop music")
  Assert.equal(sound:currentMusic(), 10)
end

function T.prepared_map_music_loads_only_sequence_and_bank_metadata()
  local provider, calls = prewarmProvider()
  local sound, soundState = prewarmSound()
  local controller = prewarmController(provider, sound, function()
    return "day"
  end)
  local fieldData = fieldDataWithSoundplates({}, {
    day = 20,
    night = 21,
    flagOverrides = {},
    traversalOverrides = {},
  })
  local pending = { sourceMusicId = 10, destinationMusicId = 11, target = 64, durationFrames = 15 }
  controller._fieldMusic = 10
  controller._musicOverride = 99
  controller._environment = { sequence = 30 }
  controller._pendingFieldMusicPolicy = pending

  local prewarmMapMusic = controller.prewarmMapMusic
  Assert.isTrue(
    type(prewarmMapMusic) == "function",
    "prepared map music must have a non-playing metadata warmup operation"
  )
  prewarmMapMusic(controller, runtimeMap(fieldData))

  Assert.deepEqual(calls.sequences, { 20 }, "the selected map-header sequence must be requested")
  Assert.deepEqual(calls.banks, { 7 }, "the selected sequence bank must be requested")
  Assert.equal(calls.samples, 0)
  Assert.equal(#soundState.playCalls, 0)
  Assert.equal(#soundState.queueCalls, 0)
  Assert.equal(soundState.stopCalls, 0)
  Assert.equal(#soundState.fadeCalls, 0)
  Assert.equal(#soundState.moveCalls, 0)
  Assert.equal(soundState.currentMusic, 10)
  Assert.equal(controller._fieldMusic, 10)
  Assert.equal(controller:musicOverride(), 99)
  Assert.equal(controller._environment.sequence, 30)
  Assert.equal(controller._pendingFieldMusicPolicy, pending)
  Assert.isNil(controller._currentMap, "prewarming must not activate the prepared map")
end

function T.prewarming_does_not_decode_samples_or_pin_stale_music_policy()
  local provider, calls = prewarmProvider()
  local sound = prewarmSound()
  local useNight = false
  local flags = {}
  local controller = prewarmController(provider, sound, function()
    return useNight and "night" or "day"
  end, flags)
  local fieldData = fieldDataWithSoundplates({}, {
    day = 20,
    night = 21,
    flagOverrides = { { flagId = 5, sequence = 22 } },
    traversalOverrides = {},
  })

  local prewarmMapMusic = controller.prewarmMapMusic
  Assert.isTrue(
    type(prewarmMapMusic) == "function",
    "prepared map music must have a non-playing metadata warmup operation"
  )
  prewarmMapMusic(controller, runtimeMap(fieldData))
  useNight = true
  flags[5] = true
  controller:enterZone(runtimeMap(fieldData))

  Assert.equal(calls.samples, 0, "metadata prewarm must not decode PCM")
  Assert.deepEqual(calls.sequences, { 20 }, "active entry must re-resolve current day/night and flags")
  Assert.deepEqual(calls.banks, { 7 }, "activation must not turn metadata prewarm into sample work")
  Assert.equal(sound:currentMusic(), 22, "active entry must choose the current destination policy")
end

function T.production_position_is_read_through_a_narrow_fieldX_fieldZ_provider()
  local keyA = AudioFixture.key(1)
  local seqA =
    seq(10, "SEQ_GS_T_WAKABA", 12, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local provider = providerFor({ [10] = seqA }, { [12] = bankWithSamples(12, "BANK_A", keyA) })
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local enginePlayer = newSequencePlayer({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  local sound = GameSound.new({ provider = provider, player = enginePlayer })
  local gp = gameplayPlayer(34, 7)
  local fd = fieldDataWithSoundplates({
    {
      x = 2,
      xBounds = 2,
      z = 7,
      zBounds = 7,
      sequence = "SEQ_GS_T_WAKABA",
      useFieldMusicBank = false,
      bgmTarget = 64,
      ambientTarget = 96,
    },
  })
  local controller = FieldAudioController.new({
    sound = sound,
    provider = provider,
    eventState = eventState(),
    fieldPosition = function()
      return gp.fieldX, gp.fieldZ
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return fd
    end,
  })
  local moves = 0
  local origMove = sound.moveSequenceVolume
  sound.moveSequenceVolume = function(self, ref, target, duration)
    moves = moves + 1
    return origMove(self, ref, target, duration)
  end
  controller:enterMap({ fieldData = fd }, { play = false })
  controller:updateField()
  Assert.equal(moves, 2, "the plate at local 2,7 should be selected from fieldX 34 (34%32=2)")
end

function T.entering_a_new_map_deactivates_the_source_environment_first()
  local keyA = AudioFixture.key(1)
  local bgmA =
    seq(10, "SEQ_GS_T_WAKABA", 12, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local bgmB =
    seq(11, "SEQ_GS_UTSUGI_RABO", 12, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local env =
    seq(20, "SEQ_SE_GS_N_SESERAGI", 12, 2, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local provider = providerFor(
    { [10] = bgmA, [11] = bgmB, [20] = env },
    { [12] = bankWithSamples(12, "BANK_A", keyA), [13] = bankWithSamples(13, "BANK_B", AudioFixture.key(2)) }
  )
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local enginePlayer = newSequencePlayer({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  local sound, spy = recordingSound(provider, enginePlayer)
  local fdA = fieldDataWithSoundplates(
    {},
    { day = "SEQ_GS_T_WAKABA", night = "SEQ_GS_T_WAKABA", flagOverrides = {}, traversalOverrides = {} }
  )
  fdA.mapId = 111
  local fdB = fieldDataWithSoundplates(
    {},
    { day = "SEQ_GS_UTSUGI_RABO", night = "SEQ_GS_UTSUGI_RABO", flagOverrides = {}, traversalOverrides = {} }
  )
  fdB.mapId = 112
  local gp = gameplayPlayer(0, 0)
  local controller = FieldAudioController.new({
    sound = sound,
    provider = provider,
    eventState = eventState(),
    fieldPosition = function()
      return gp.fieldX, gp.fieldZ
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return fdB
    end,
  })
  controller:enterMap({ fieldData = fdA }, { play = true })
  local fdEnv = fieldDataWithSoundplates({
    {
      x = 0,
      xBounds = 31,
      z = 0,
      zBounds = 31,
      sequence = "SEQ_SE_GS_N_SESERAGI",
      useFieldMusicBank = false,
      bgmTarget = 64,
      ambientTarget = 96,
    },
  }, { day = "SEQ_GS_T_WAKABA", night = "SEQ_GS_T_WAKABA", flagOverrides = {}, traversalOverrides = {} })
  fdEnv.mapId = 111
  controller:enterMap({ fieldData = fdEnv }, { play = false })
  spy.moves = {}
  spy.stops = {}
  controller:updateField()
  Assert.equal(#spy.stops, 0, "first activation must not stop")
  spy.moves = {}
  spy.stops = {}
  controller:enterMap({ fieldData = fdB }, { clearMusicOverride = true, play = true })
  Assert.equal(#spy.stops, 1, "old environment must be faded first")
  Assert.equal(spy.stops[1].ref, 20)
  Assert.equal(spy.stops[1].duration, 10)
  Assert.equal(#spy.moves, 1, "old base field music must be restored")
  Assert.equal(spy.moves[1].ref, 10)
  Assert.equal(spy.moves[1].target, 128)
  Assert.equal(spy.moves[1].duration, 15)
end

function T.ordinary_bank_validation_remains_strict_while_the_explicit_donor_path_allows_mismatch()
  local keyA = AudioFixture.key(1)
  local keyB = AudioFixture.key(2)
  local bgm =
    seq(10, "SEQ_GS_T_WAKABA", 12, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local env =
    seq(20, "SEQ_SE_GS_N_SESERAGI", 13, 2, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local provider = providerFor(
    { [10] = bgm, [20] = env },
    { [12] = bankWithSamples(12, "BANK_A", keyA), [13] = bankWithSamples(13, "BANK_B", keyB) }
  )
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local player = newSequencePlayer({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  throwsCode("AUDIO_PLAYER_BANK_MISMATCH", function()
    player:play(player:createHandle(), provider:sequence(20), provider:bank(12))
  end)
  Assert.isTrue(type(player.playWithBankOverride) == "function", "explicit donor-bank start must exist")
  player:playWithBankOverride(player:createHandle(), provider:sequence(20), provider:bank(12))
  Assert.isTrue(player:isPlayerPlaying(2))
  local sound = GameSound.new({ provider = provider, player = player })
  Assert.isTrue(type(sound.playWithBankOverride) == "function", "GameSound explicit donor path must exist")
  sound:playWithBankOverride(20, 12)
  Assert.isTrue(player:isPlayerPlaying(2))
  local spy = { playWithBankCalls = {} }
  local orig = sound.playWithBankOverride
  sound.playWithBankOverride = function(self, seqRef, bankRef)
    spy.playWithBankCalls[#spy.playWithBankCalls + 1] = { seqRef = seqRef, bankRef = bankRef }
    return orig(self, seqRef, bankRef)
  end
  local fd = fieldDataWithSoundplates({
    {
      x = 0,
      xBounds = 31,
      z = 0,
      zBounds = 31,
      sequence = "SEQ_SE_GS_N_SESERAGI",
      useFieldMusicBank = true,
      bgmTarget = 64,
      ambientTarget = 96,
    },
  }, { day = "SEQ_GS_T_WAKABA", night = "SEQ_GS_T_WAKABA", flagOverrides = {}, traversalOverrides = {} })
  local gp = gameplayPlayer(0, 0)
  local controller = FieldAudioController.new({
    sound = sound,
    provider = provider,
    eventState = eventState(),
    fieldPosition = function()
      return gp.fieldX, gp.fieldZ
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return fd
    end,
  })
  controller:enterMap({ fieldData = fd }, { play = true })
  controller:updateField()
  Assert.equal(#spy.playWithBankCalls, 1, "controller must route donor-bank plates through explicit path")
  Assert.equal(spy.playWithBankCalls[1].bankRef, 12)
end

function T.disabled_highest_plate_performs_no_fallback_and_preserves_prior_environment()
  local keyA = AudioFixture.key(1)
  local bgm =
    seq(10, "SEQ_GS_T_WAKABA", 12, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local envA =
    seq(20, "SEQ_SE_GS_N_SESERAGI", 12, 2, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local envB =
    seq(21, "SEQ_SE_GS_N_HUUSHA", 12, 2, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local provider = providerFor({ [10] = bgm, [20] = envA, [21] = envB }, { [12] = bankWithSamples(12, "BANK_A", keyA) })
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local enginePlayer = newSequencePlayer({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  local sound, spy = recordingSound(provider, enginePlayer)
  local fd = fieldDataWithSoundplates({
    {
      x = 0,
      xBounds = 31,
      z = 0,
      zBounds = 31,
      sequence = "SEQ_SE_GS_N_SESERAGI",
      useFieldMusicBank = false,
      bgmTarget = 64,
      ambientTarget = 96,
    },
    {
      x = 0,
      xBounds = 31,
      z = 0,
      zBounds = 31,
      sequence = "SEQ_SE_GS_N_HUUSHA",
      useFieldMusicBank = false,
      bgmTarget = 32,
      ambientTarget = 48,
      disabledWhenFlag = 99,
    },
  })
  local gp2 = gameplayPlayer(5, 5)
  local controller2 = FieldAudioController.new({
    sound = sound,
    provider = provider,
    eventState = eventState({}),
    fieldPosition = function()
      return gp2.fieldX, gp2.fieldZ
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return fd
    end,
  })
  local fdOnlyLow = fieldDataWithSoundplates({
    {
      x = 0,
      xBounds = 31,
      z = 0,
      zBounds = 31,
      sequence = "SEQ_SE_GS_N_SESERAGI",
      useFieldMusicBank = false,
      bgmTarget = 64,
      ambientTarget = 96,
    },
  })
  controller2:enterMap({ fieldData = fdOnlyLow }, { play = true })
  spy.moves = {}
  spy.stops = {}
  controller2:updateField()
  Assert.equal(#spy.moves, 2, "first plate should start with BGM and ambient moves")
  spy.moves = {}
  spy.stops = {}
  controller2._currentMap = { fieldData = fd }
  controller2._fieldMusic = 10
  controller2._eventState = eventState({ [99] = true })
  controller2:updateField()
  Assert.equal(#spy.moves, 0, "disabled selected plate must not start lower fallback and must not move volumes")
  Assert.equal(#spy.stops, 0, "disabled selected plate must not stop prior environment")
  Assert.equal(controller2._environment.sequence, 20, "remembered environment must remain unchanged")
end

function T.environment_identity_is_sequence_based_with_correct_volume_and_exit_transitions()
  local keyA = AudioFixture.key(1)
  local bgm =
    seq(10, "SEQ_GS_T_WAKABA", 12, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local env =
    seq(20, "SEQ_SE_GS_N_SESERAGI", 12, 2, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local provider = providerFor({ [10] = bgm, [20] = env }, { [12] = bankWithSamples(12, "BANK_A", keyA) })
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local enginePlayer = newSequencePlayer({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  local sound, spy = recordingSound(provider, enginePlayer)
  local fdA = fieldDataWithSoundplates({
    {
      x = 0,
      xBounds = 10,
      z = 0,
      zBounds = 10,
      sequence = "SEQ_SE_GS_N_SESERAGI",
      useFieldMusicBank = false,
      bgmTarget = 64,
      ambientTarget = 96,
    },
  })
  local fdB = fieldDataWithSoundplates({
    {
      x = 20,
      xBounds = 30,
      z = 20,
      zBounds = 30,
      sequence = "SEQ_SE_GS_N_SESERAGI",
      useFieldMusicBank = false,
      bgmTarget = 32,
      ambientTarget = 48,
    },
  })
  local gp = gameplayPlayer(5, 5)
  local controller = FieldAudioController.new({
    sound = sound,
    provider = provider,
    eventState = eventState(),
    fieldPosition = function()
      return gp.fieldX, gp.fieldZ
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return fdA
    end,
  })
  controller:enterMap({ fieldData = fdA }, { play = true })
  spy.moves = {}
  spy.stops = {}
  controller:updateField()
  Assert.equal(#spy.stops, 0)
  Assert.equal(#spy.moves, 2, "first plate must schedule BGM and ambient moves")
  Assert.equal(spy.moves[1].duration, 15)
  Assert.equal(spy.moves[2].duration, 5)
  controller._currentMap = { fieldData = fdB }
  gp.fieldX, gp.fieldZ = 25, 25
  spy.moves = {}
  spy.stops = {}
  local envPlays = 0
  local origPlay = sound.play
  sound.play = function(self, ref)
    envPlays = envPlays + 1
    return origPlay(self, ref)
  end
  controller:updateField()
  sound.play = origPlay
  Assert.equal(envPlays, 0, "same sequence on different plate must not restart the sequence")
  Assert.equal(#spy.stops, 0, "same sequence must not stop")
  Assert.equal(#spy.moves, 2, "same sequence must still reapply BGM and ambient targets")
  controller._currentMap = {
    fieldData = fieldDataWithSoundplates(
      {},
      { day = "SEQ_GS_T_WAKABA", night = "SEQ_GS_T_WAKABA", flagOverrides = {}, traversalOverrides = {} }
    ),
  }
  gp.fieldX, gp.fieldZ = 50, 50
  spy.moves = {}
  spy.stops = {}
  controller:updateField()
  Assert.equal(spy.stops[1].ref, 20)
  Assert.equal(spy.stops[1].duration, 10)
  Assert.equal(spy.moves[1].target, 128)
  Assert.equal(spy.moves[1].duration, 15)
end

function T.temporary_music_does_not_change_the_environment_donor_bank()
  local keyA = AudioFixture.key(1)
  local keyB = AudioFixture.key(2)
  local baseBgm =
    seq(10, "SEQ_GS_T_WAKABA", 12, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local tempBgm =
    seq(11, "SEQ_GS_BICYCLE", 13, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local env =
    seq(20, "SEQ_SE_GS_N_SESERAGI", 13, 2, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local provider = providerFor(
    { [10] = baseBgm, [11] = tempBgm, [20] = env },
    { [12] = bankWithSamples(12, "BANK_A", keyA), [13] = bankWithSamples(13, "BANK_B", keyB) }
  )
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local enginePlayer = newSequencePlayer({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  local sound, spy = recordingSound(provider, enginePlayer)
  local fd = fieldDataWithSoundplates({
    {
      x = 0,
      xBounds = 31,
      z = 0,
      zBounds = 31,
      sequence = "SEQ_SE_GS_N_SESERAGI",
      useFieldMusicBank = true,
      bgmTarget = 64,
      ambientTarget = 96,
    },
  })
  local gp = gameplayPlayer(0, 0)
  local controller = FieldAudioController.new({
    sound = sound,
    provider = provider,
    eventState = eventState(),
    fieldPosition = function()
      return gp.fieldX, gp.fieldZ
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return fd
    end,
  })
  controller:enterMap({ fieldData = fd }, { play = true })
  spy.playWithBankCalls = {}
  sound:temporaryMusic(11)
  Assert.equal(sound:currentMusic(), 11)
  controller:processSoundplate()
  Assert.equal(#spy.playWithBankCalls, 1, "donor-bank plate must use explicit path")
  Assert.equal(spy.playWithBankCalls[1].bankRef, 12, "donor must be base field music bank, not temporary music bank")
  Assert.equal(controller._fieldMusic, 10, "controller base identity must remain base music")
end

function T.position_lookup_uses_field_coordinates_modulo_32_and_inclusive_edges()
  local keyA = AudioFixture.key(1)
  local bgm =
    seq(10, "SEQ_GS_T_WAKABA", 12, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local env =
    seq(20, "SEQ_SE_GS_N_SESERAGI", 12, 2, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local provider = providerFor({ [10] = bgm, [20] = env }, { [12] = bankWithSamples(12, "BANK_A", keyA) })
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local enginePlayer = newSequencePlayer({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  local sound, spy = recordingSound(provider, enginePlayer)
  local fd = fieldDataWithSoundplates({
    {
      x = 1,
      xBounds = 1,
      z = 1,
      zBounds = 1,
      sequence = "SEQ_SE_GS_N_SESERAGI",
      useFieldMusicBank = false,
      bgmTarget = 64,
      ambientTarget = 96,
    },
  })
  local gp = gameplayPlayer(33, 33)
  local controller = FieldAudioController.new({
    sound = sound,
    provider = provider,
    eventState = eventState(),
    fieldPosition = function()
      return gp.fieldX, gp.fieldZ
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return fd
    end,
  })
  controller:enterMap({ fieldData = fd }, { play = true })
  spy.moves = {}
  controller:updateField()
  Assert.equal(#spy.moves, 2, "33%32=1 matches inclusive plate at 1,1 when reading fieldX/fieldZ")
end

function T.forced_processing_clears_memory_without_pre_stop_and_restarts_same_plate()
  local keyA = AudioFixture.key(1)
  local bgm =
    seq(10, "SEQ_GS_T_WAKABA", 12, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local env =
    seq(20, "SEQ_SE_GS_N_SESERAGI", 12, 2, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local provider = providerFor({ [10] = bgm, [20] = env }, { [12] = bankWithSamples(12, "BANK_A", keyA) })
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local enginePlayer = newSequencePlayer({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  local sound, spy = recordingSound(provider, enginePlayer)
  local fd = fieldDataWithSoundplates({
    {
      x = 0,
      xBounds = 31,
      z = 0,
      zBounds = 31,
      sequence = "SEQ_SE_GS_N_SESERAGI",
      useFieldMusicBank = false,
      bgmTarget = 64,
      ambientTarget = 96,
    },
  })
  local gp = gameplayPlayer(0, 0)
  local controller = FieldAudioController.new({
    sound = sound,
    provider = provider,
    eventState = eventState(),
    fieldPosition = function()
      return gp.fieldX, gp.fieldZ
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return fd
    end,
  })
  controller:enterMap({ fieldData = fd }, { play = true })
  controller:updateField()
  Assert.isTrue(controller._environment ~= nil)
  spy.stops = {}
  spy.moves = {}
  Assert.isTrue(type(controller.processSoundplate) == "function", "forced processing entry must exist")
  controller:processSoundplate()
  Assert.equal(#spy.stops, 0, "forced wipe must not pre-stop the old environment")
  Assert.isTrue(
    controller._environment ~= nil,
    "forced processing must restart same active plate after clearing memory"
  )
end

function T.begin_warp_raises_when_generated_field_data_is_missing()
  local keyA = AudioFixture.key(1)
  local bgm =
    seq(10, "SEQ_GS_T_WAKABA", 12, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local provider = providerFor({ [10] = bgm }, { [12] = bankWithSamples(12, "BANK_A", keyA) })
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local enginePlayer = newSequencePlayer({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  local sound = GameSound.new({ provider = provider, player = enginePlayer })
  local fd = fieldDataWithSoundplates(
    {},
    { day = "SEQ_GS_T_WAKABA", night = "SEQ_GS_T_WAKABA", flagOverrides = {}, traversalOverrides = {} }
  )
  local gp = gameplayPlayer(0, 0)
  local controller = FieldAudioController.new({
    sound = sound,
    provider = provider,
    eventState = eventState(),
    fieldPosition = function()
      return gp.fieldX, gp.fieldZ
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return nil
    end,
  })
  controller:enterMap({ fieldData = fd }, { play = true })
  sound:playMusic(10)
  Assert.throws(function()
    controller:beginWarp(9999)
  end)
end

function T.audio_owned_traversal_mutation_is_not_a_supported_operation()
  local keyA = AudioFixture.key(1)
  local bgm =
    seq(10, "SEQ_GS_T_WAKABA", 12, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local provider = providerFor({ [10] = bgm }, { [12] = bankWithSamples(12, "BANK_A", keyA) })
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local enginePlayer = newSequencePlayer({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  local sound = GameSound.new({ provider = provider, player = enginePlayer })
  local fd = fieldDataWithSoundplates(
    {},
    { day = "SEQ_GS_T_WAKABA", night = "SEQ_GS_T_WAKABA", flagOverrides = {}, traversalOverrides = {} }
  )
  local gp = gameplayPlayer(0, 0)
  local controller = FieldAudioController.new({
    sound = sound,
    provider = provider,
    eventState = eventState(),
    fieldPosition = function()
      return gp.fieldX, gp.fieldZ
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return fd
    end,
  })
  Assert.isTrue(
    rawget(controller, "setTraversalMode") == nil,
    "controller must not expose an audio-owned traversal setter"
  )
end

return { tests = T }
