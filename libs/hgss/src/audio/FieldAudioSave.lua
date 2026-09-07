-- Validates the persisted field-audio override without constructing playback
-- objects. The generated audio index supplies the version-specific sequence
-- identity set used by this save boundary.

local Errors = require("libs.errors.src.Errors")
local AudioErrors = require("libs.hgss.src.audio.AudioErrors")

local FieldAudioSave = {}

local function invalid(message, context)
  return Errors.new(AudioErrors.AUDIO_SAVE_INVALID, message, context or {})
end

---@param record unknown
---@param context table<string, unknown>
---@return table<string, unknown>|nil, Errors.Error?
function FieldAudioSave.validate(record, context)
  if type(record) ~= "table" then
    return nil, invalid("audio save bucket must be a table")
  end
  context = context or {}
  if type(context.audioSequenceIds) ~= "table" then
    return nil, invalid("audio sequence ids are required")
  end
  for key in pairs(record) do
    if key ~= "fieldMusicOverride" then
      return nil, invalid("audio save bucket contains an unknown field", { field = key })
    end
  end
  local override = record.fieldMusicOverride
  if override ~= nil then
    if type(override) ~= "number" or override % 1 ~= 0 or override < 0 or not context.audioSequenceIds[override] then
      return nil, invalid("field music override is not an indexed sequence", { sequenceId = override })
    end
  end
  return { fieldMusicOverride = override }
end

---@param audio unknown
---@return table<string, unknown>
function FieldAudioSave.capture(audio)
  assert(audio == nil or type(audio) == "table", "audio service must be a table")
  return { fieldMusicOverride = audio and audio:musicOverride() or nil }
end

return FieldAudioSave
