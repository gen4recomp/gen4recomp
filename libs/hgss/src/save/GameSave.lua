-- Defines the strict project-owned GameSave record. The storage service owns
-- publication, while PlayerData, world, scripts, UI, audio, and mons modules
-- may inject their authoritative validators at this boundary. Pure domain code.

local Errors = require("libs.errors.src.Errors")
local GameSaveErrors = require("libs.hgss.src.save.GameSaveErrors")

local GameSave = {}

GameSave.SCHEMA = "g4-game-save-v3"
GameSave.MAX_PLAY_TIME_SECONDS = 999 * 60 * 60 + 59 * 60 + 59

local FACING = { north = true, south = true, west = true, east = true }
local TOP_LEVEL_FIELDS = {
  avatar = true,
  audio = true,
  auxiliaryUi = true,
  bag = true,
  facing = true,
  fieldX = true,
  fieldZ = true,
  mapId = true,
  mons = true,
  playTimeSeconds = true,
  playerData = true,
  saveId = true,
  schema = true,
  scripts = true,
  surfaceId = true,
  suppression = true,
  terrainDependencyHash = true,
  versionId = true,
  world = true,
  worldY = true,
  weatherId = true,
}

local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value)
  return finite(value) and value % 1 == 0
end

local function safeComponent(value)
  return type(value) == "string" and value ~= "" and value:match("^[%w%-_]+$") ~= nil
end

-- Only durable avatar modes persist. A missing record canonicalizes to
-- walking (every save produced before avatar state existed boots walking);
-- any present malformed record is rejected.
local DURABLE_AVATAR_STATES = {
  walking = true,
  cycling = true,
  surfing = true,
  rocket = true,
}

local function validateAvatar(record)
  if record.avatar == nil then
    return { state = "walking" }
  end
  local avatar = record.avatar
  if type(avatar) ~= "table" then
    Errors.raise(GameSaveErrors.GAME_SAVE_FIELD_INVALID, "game save avatar must be a table", {})
  end
  local fieldCount = 0
  for _ in pairs(avatar) do
    fieldCount = fieldCount + 1
  end
  if fieldCount ~= 1 or type(avatar.state) ~= "string" or DURABLE_AVATAR_STATES[avatar.state] ~= true then
    Errors.raise(GameSaveErrors.GAME_SAVE_FIELD_INVALID, "game save avatar state is invalid", { avatar = avatar })
  end
  return { state = avatar.state }
end

local function validateSaveIdRaised(saveId)
  if not safeComponent(saveId) then
    Errors.raise(
      GameSaveErrors.GAME_SAVE_SAVE_ID_INVALID,
      "save id must be one safe path component",
      { saveId = saveId }
    )
  end
end

local function validateBucket(record, key, opts, validatorKey)
  if type(record[key]) ~= "table" then
    Errors.raise(
      GameSaveErrors.GAME_SAVE_BUCKET_INVALID,
      "game save " .. key .. " bucket is required",
      { bucket = key }
    )
  end
  local validator = opts and opts[validatorKey]
  if validator == nil then
    return record[key]
  end
  assert(type(validator) == "function", validatorKey .. " must be a function")
  local ok, result, validationErr = pcall(validator, record[key])
  if not ok then
    if Errors.is(result) then
      Errors.raise(
        GameSaveErrors.GAME_SAVE_BUCKET_INVALID,
        "game save " .. key .. " bucket is invalid: " .. result.message,
        { bucket = key, cause = result.code }
      )
    end
    error(result)
  end
  if Errors.is(result) or result == false or (result == nil and validationErr ~= nil) then
    local cause = Errors.is(validationErr) and validationErr.code or nil
    Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, "game save " .. key .. " bucket is invalid", {
      bucket = key,
      cause = cause,
    })
  end
  return result or record[key]
end

local function validateFieldState(record, opts)
  if not safeComponent(record.versionId) then
    Errors.raise(
      GameSaveErrors.GAME_SAVE_VERSION_INVALID,
      "game save version is missing",
      { versionId = record.versionId }
    )
  end
  if not integer(record.mapId) or record.mapId < 0 or record.mapId > 0xFFFF then
    Errors.raise(GameSaveErrors.GAME_SAVE_FIELD_INVALID, "game save map id is invalid", { mapId = record.mapId })
  end
  if not integer(record.fieldX) or record.fieldX < 0 or record.fieldX > 0xFFFF then
    Errors.raise(GameSaveErrors.GAME_SAVE_FIELD_INVALID, "game save field x is invalid", { fieldX = record.fieldX })
  end
  if not integer(record.fieldZ) or record.fieldZ < 0 or record.fieldZ > 0xFFFF then
    Errors.raise(GameSaveErrors.GAME_SAVE_FIELD_INVALID, "game save field z is invalid", { fieldZ = record.fieldZ })
  end
  if not finite(record.worldY) then
    Errors.raise(GameSaveErrors.GAME_SAVE_FIELD_INVALID, "game save world y is invalid", { worldY = record.worldY })
  end
  if not integer(record.surfaceId) or record.surfaceId < 0 or record.surfaceId > 0xFFFF then
    Errors.raise(
      GameSaveErrors.GAME_SAVE_FIELD_INVALID,
      "game save surface id is invalid",
      { surfaceId = record.surfaceId }
    )
  end
  if record.weatherId ~= nil and (not integer(record.weatherId) or record.weatherId < 0 or record.weatherId > 13) then
    Errors.raise(
      GameSaveErrors.GAME_SAVE_FIELD_INVALID,
      "game save weather id is invalid",
      { weatherId = record.weatherId }
    )
  end
  if type(record.terrainDependencyHash) ~= "string" or record.terrainDependencyHash == "" then
    Errors.raise(GameSaveErrors.GAME_SAVE_FIELD_INVALID, "game save terrain dependency is missing", {})
  end
  if not FACING[record.facing] then
    Errors.raise(GameSaveErrors.GAME_SAVE_FIELD_INVALID, "game save facing is invalid", { facing = record.facing })
  end
  local validator = opts and opts.fieldValidate
  if validator ~= nil then
    assert(type(validator) == "function", "fieldValidate must be a function")
    validator(record)
  end
end

local function validate(record, opts)
  if type(record) ~= "table" then
    Errors.raise(GameSaveErrors.GAME_SAVE_INVALID, "game save must be a table", {})
  end
  if record.schema ~= GameSave.SCHEMA then
    Errors.raise(
      GameSaveErrors.GAME_SAVE_SCHEMA_UNSUPPORTED,
      "unsupported game save schema",
      { schema = record.schema }
    )
  end
  for key in pairs(record) do
    if not TOP_LEVEL_FIELDS[key] then
      Errors.raise(GameSaveErrors.GAME_SAVE_INVALID, "unknown game save field", { field = key })
    end
  end
  validateSaveIdRaised(record.saveId)
  validateFieldState(record, opts)
  if
    not integer(record.playTimeSeconds)
    or record.playTimeSeconds < 0
    or record.playTimeSeconds > GameSave.MAX_PLAY_TIME_SECONDS
  then
    Errors.raise(
      GameSaveErrors.GAME_SAVE_PLAY_TIME_INVALID,
      "game save play time exceeds 999:59:59",
      { playTimeSeconds = record.playTimeSeconds }
    )
  end
  local canonicalPlayerData = validateBucket(record, "playerData", opts, "playerDataValidate")
  local world = validateBucket(record, "world", opts, "worldValidate")
  for _, key in ipairs({ "flags", "variables", "objects", "rng" }) do
    if type(world[key]) ~= "table" then
      Errors.raise(
        GameSaveErrors.GAME_SAVE_BUCKET_INVALID,
        "game save world bucket is incomplete",
        { bucket = "world." .. key }
      )
    end
  end
  local canonicalScripts = validateBucket(record, "scripts", opts, "scriptsValidate")
  local canonicalMons = validateBucket(record, "mons", opts, "monsValidate")
  local canonicalBag = validateBucket(record, "bag", opts, "bagValidate")
  local canonicalAuxiliaryUi = validateBucket(record, "auxiliaryUi", opts, "auxiliaryUiValidate")
  local canonicalAudio = validateBucket(record, "audio", opts, "audioValidate")
  local canonicalAvatar = validateAvatar(record)
  local canonical = {}
  for key, value in pairs(record) do
    canonical[key] = value
  end
  canonical.playerData = canonicalPlayerData
  canonical.world = world
  canonical.scripts = canonicalScripts
  canonical.mons = canonicalMons
  canonical.bag = canonicalBag
  canonical.auxiliaryUi = canonicalAuxiliaryUi
  canonical.audio = canonicalAudio
  canonical.avatar = canonicalAvatar
  return canonical
end

---@param saveId string
---@return boolean|nil, Errors.Error?
function GameSave.validateSaveId(saveId)
  local ok, result = pcall(validateSaveIdRaised, saveId)
  if ok then
    return true
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

---@param record table<string, unknown>
---@param opts table<string, unknown>?
---@return table<string, unknown>|nil, Errors.Error?
function GameSave.validate(record, opts)
  local ok, result = pcall(validate, record, opts)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

return GameSave
