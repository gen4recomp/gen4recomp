-- Composes the HGSS semantic audio services over the Nintendo sound runtime.

local AudioAssetProvider = require("libs.hgss.src.audio.AudioAssetProvider")
local CryPlayer = require("libs.hgss.src.audio.CryPlayer")
local FieldAudioController = require("libs.hgss.src.audio.FieldAudioController")
local GameSound = require("libs.hgss.src.audio.GameSound")
local SequencePlayer = require("libs.nds.src.nitro.sound.SequencePlayer")
local VoiceMixer = require("libs.nds.src.nitro.sound.VoiceMixer")
local WaveOutPlayer = require("libs.nds.src.nitro.sound.WaveOutPlayer")

local AudioRuntime = {}

---@class HgssAudioRuntimeFieldOptions
---@field eventState unknown
---@field fieldPosition fun(): integer, integer
---@field dayNight fun(): "day"|"night"
---@field fieldDataForMap fun(mapId: integer|string): unknown

---@class HgssAudioRuntimeOptions
---@field cacheFs CacheFs
---@field outputRate integer
---@field field HgssAudioRuntimeFieldOptions?

---@class HgssAudioRuntimeComposition
---@field sound GameSound
---@field renderer { render: fun(self: table<string, unknown>, frames: integer): integer[] }
---@field fieldService FieldAudioController?

---@param opts HgssAudioRuntimeOptions
---@return HgssAudioRuntimeComposition
function AudioRuntime.compose(opts)
  assert(opts and opts.cacheFs and opts.outputRate, "AudioRuntime.compose requires cacheFs and outputRate")

  local provider = AudioAssetProvider.new(opts.cacheFs)
  local mixer = VoiceMixer.new({ sampleRate = opts.outputRate })
  local player = SequencePlayer.new({
    sampleRate = opts.outputRate,
    mixer = mixer,
    provider = provider,
  })
  local cry = CryPlayer.new({ player = player, provider = provider, waveOut = WaveOutPlayer.new({ mixer = mixer }) })
  local sound = GameSound.new({
    provider = provider,
    player = player,
    cry = cry,
  })
  local fieldService
  if opts.field ~= nil then
    fieldService = FieldAudioController.new({
      sound = sound,
      provider = provider,
      eventState = opts.field.eventState,
      fieldPosition = opts.field.fieldPosition,
      dayNight = opts.field.dayNight,
      fieldDataForMap = opts.field.fieldDataForMap,
    })
  end
  return {
    sound = sound,
    renderer = player,
    fieldService = fieldService,
  }
end

return AudioRuntime
