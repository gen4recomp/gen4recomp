-- FieldAudio: the production field-audio composition. It adds HGSS field
-- policy around the shared audio runtime and application output sink.

local GameAudio = require("game.hgss.src.audio.GameAudio")

local FieldAudio = {}

---@class FieldAudioComposeOptions
---@field cacheFs CacheFs
---@field outputRate integer
---@field eventState unknown
---@field fieldPosition fun(): integer, integer
---@field dayNight fun(): "day"|"night"
---@field fieldDataForMap fun(mapIdOrSymbol: integer|string): unknown
---@field outputHost table<string, unknown>|nil

---@param opts FieldAudioComposeOptions
---@return { service: FieldAudioController, sink: LoveAudioSink|nil }
function FieldAudio.compose(opts)
  assert(
    opts
      and opts.cacheFs
      and opts.outputRate
      and opts.eventState
      and opts.fieldPosition
      and opts.dayNight
      and opts.fieldDataForMap,
    "FieldAudio.compose requires cacheFs, outputRate, eventState, fieldPosition, dayNight, and fieldDataForMap"
  )
  ---@cast opts +{ outputHost: table<string, unknown>|nil }
  local core = GameAudio.compose({
    cacheFs = opts.cacheFs,
    outputRate = opts.outputRate,
    outputHost = opts.outputHost,
    field = {
      eventState = opts.eventState,
      fieldPosition = opts.fieldPosition,
      dayNight = opts.dayNight,
      fieldDataForMap = opts.fieldDataForMap,
    },
  })
  return { service = assert(core.fieldService), sink = core.sink }
end

return FieldAudio
