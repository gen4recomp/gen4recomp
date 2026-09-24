-- Cache schema, path, and strict validator for the generated fresh-game
-- startup event initializer. Schema v3 carries the source-grounded initial
-- player-room location alongside the ordered `operations` array plus the
-- source dependency; eventOperations / nonFieldEffects are rejected and
-- unknown operations fail strictly.

local Errors = require("libs.errors.src.Errors")
local Contract = require("libs.assets.src.DerivedAssetContract")

local NewGameInitCache = {}

NewGameInitCache.FORMAT = Contract.newGameInit.cacheFormat
NewGameInitCache.SCHEMA = Contract.newGameInit.schema

local ARTIFACT_INVALID = "NEW_GAME_INIT_ARTIFACT_INVALID"

local DATA_DIR = "data/generated/new_game"

function NewGameInitCache.dir()
  return DATA_DIR
end

function NewGameInitCache.path()
  return DATA_DIR .. "/init.lua"
end

function NewGameInitCache.markerPath()
  return DATA_DIR .. "/complete"
end

function NewGameInitCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", NewGameInitCache.FORMAT, romSha1, depHash)
end

local function strictTableKeys(value, allowed, label)
  for key in pairs(value) do
    if not allowed[key] then
      return false, Errors.new(ARTIFACT_INVALID, label .. " has unknown key " .. tostring(key), { key = key })
    end
  end
  return true
end

local function validateOperation(index, operation)
  if type(operation) ~= "table" then
    return false, Errors.new(ARTIFACT_INVALID, "operation " .. index .. " must be a table", { index = index })
  end
  local op = operation.op
  if op == "set_flag" then
    local allowed = { op = true, id = true, symbol = true }
    local ok, err = strictTableKeys(operation, allowed, "operation " .. index)
    if not ok then
      return false, err
    end
    if type(operation.id) ~= "number" or operation.id ~= math.floor(operation.id) or operation.id < 0 then
      return false,
        Errors.new(ARTIFACT_INVALID, "operation " .. index .. " id must be a non-negative integer", { index = index })
    end
    if type(operation.symbol) ~= "string" or operation.symbol == "" then
      return false,
        Errors.new(ARTIFACT_INVALID, "operation " .. index .. " symbol must be a non-empty string", { index = index })
    end
    return true
  elseif op == "roll_loto_id" then
    local allowed =
      { op = true, lowVariableId = true, lowVariableSymbol = true, highVariableId = true, highVariableSymbol = true }
    local ok, err = strictTableKeys(operation, allowed, "operation " .. index)
    if not ok then
      return false, err
    end
    for _, key in ipairs({ "lowVariableId", "highVariableId" }) do
      local id = operation[key]
      if type(id) ~= "number" or id ~= math.floor(id) or id < 0 or id > 0xFFFF then
        return false,
          Errors.new(
            ARTIFACT_INVALID,
            "operation " .. index .. " " .. key .. " must be a u16 integer",
            { index = index, key = key }
          )
      end
    end
    if operation.lowVariableSymbol ~= "VAR_LOTO_NUMBER_LO" then
      return false,
        Errors.new(
          ARTIFACT_INVALID,
          "operation " .. index .. " lowVariableSymbol must be VAR_LOTO_NUMBER_LO",
          { index = index }
        )
    end
    if operation.highVariableSymbol ~= "VAR_LOTO_NUMBER_HI" then
      return false,
        Errors.new(
          ARTIFACT_INVALID,
          "operation " .. index .. " highVariableSymbol must be VAR_LOTO_NUMBER_HI",
          { index = index }
        )
    end
    return true
  else
    return false,
      Errors.new(
        ARTIFACT_INVALID,
        "operation " .. index .. " has unknown op " .. tostring(op),
        { index = index, op = op }
      )
  end
end

local function validateLocation(location)
  if type(location) ~= "table" then
    return false, Errors.new(ARTIFACT_INVALID, "artifact initialLocation must be a table", {})
  end
  local allowed = { mapSymbol = true, fieldX = true, fieldZ = true, facing = true }
  local ok, err = strictTableKeys(location, allowed, "initialLocation")
  if not ok then
    return false, err
  end
  if type(location.mapSymbol) ~= "string" or not string.match(location.mapSymbol, "^MAP_") then
    return false, Errors.new(ARTIFACT_INVALID, "initialLocation mapSymbol must be a MAP_*-style symbol", {})
  end
  for _, key in ipairs({ "fieldX", "fieldZ" }) do
    local coordinate = location[key]
    if type(coordinate) ~= "number" or coordinate % 1 ~= 0 then
      return false, Errors.new(ARTIFACT_INVALID, "initialLocation " .. key .. " must be an integer", { key = key })
    end
  end
  local facings = { north = true, south = true, west = true, east = true }
  if facings[location.facing] ~= true then
    return false, Errors.new(ARTIFACT_INVALID, "initialLocation facing must be a cardinal direction", {})
  end
  return true
end

function NewGameInitCache.validate(artifact)
  if type(artifact) ~= "table" then
    return false, Errors.new(ARTIFACT_INVALID, "artifact is not a table", {})
  end
  if artifact.schema ~= NewGameInitCache.SCHEMA then
    return false,
      Errors.new(
        ARTIFACT_INVALID,
        "artifact schema mismatch",
        { schema = artifact.schema, expected = NewGameInitCache.SCHEMA }
      )
  end
  if artifact.eventOperations ~= nil or artifact.nonFieldEffects ~= nil then
    return false, Errors.new(ARTIFACT_INVALID, "artifact contains stale v1 fields", {})
  end
  local topAllowed =
    { schema = true, versionId = true, operations = true, sourceDependency = true, initialLocation = true }
  local ok, err = strictTableKeys(artifact, topAllowed, "artifact")
  if not ok then
    return false, err
  end
  if type(artifact.versionId) ~= "string" or artifact.versionId == "" then
    return false, Errors.new(ARTIFACT_INVALID, "artifact versionId must be a non-empty string", {})
  end
  if type(artifact.operations) ~= "table" then
    return false, Errors.new(ARTIFACT_INVALID, "artifact operations must be a table", {})
  end
  local count = #artifact.operations
  if count == 0 then
    return false, Errors.new(ARTIFACT_INVALID, "artifact operations must be a non-empty array", {})
  end
  for index = 1, count do
    if artifact.operations[index] == nil then
      return false, Errors.new(ARTIFACT_INVALID, "artifact operations must be a dense array", { index = index })
    end
  end
  for key in pairs(artifact.operations) do
    if type(key) ~= "number" or key < 1 or key > count or key ~= math.floor(key) then
      return false, Errors.new(ARTIFACT_INVALID, "artifact operations has non-array key", { key = key })
    end
  end
  for index, operation in ipairs(artifact.operations) do
    local opOk, opErr = validateOperation(index, operation)
    if not opOk then
      return false, opErr
    end
  end
  if type(artifact.sourceDependency) ~= "table" then
    return false, Errors.new(ARTIFACT_INVALID, "artifact sourceDependency must be a table", {})
  end
  local depAllowed = { standardScriptMember = true, sha1 = true }
  local depOk, depErr = strictTableKeys(artifact.sourceDependency, depAllowed, "sourceDependency")
  if not depOk then
    return false, depErr
  end
  local member = artifact.sourceDependency.standardScriptMember
  if type(member) ~= "number" or member ~= math.floor(member) or member < 0 then
    return false,
      Errors.new(ARTIFACT_INVALID, "artifact sourceDependency.standardScriptMember must be a non-negative integer", {})
  end
  local sha1 = artifact.sourceDependency.sha1
  if type(sha1) ~= "string" or sha1 == "" then
    return false, Errors.new(ARTIFACT_INVALID, "artifact sourceDependency.sha1 must be a non-empty string", {})
  end
  local locationOk, locationErr = validateLocation(artifact.initialLocation)
  if not locationOk then
    return false, locationErr
  end
  return true
end

function NewGameInitCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(NewGameInitCache.markerPath()) ~= expectedMarker then
    return false
  end
  local artifact = cacheFs:loadLua(NewGameInitCache.path())
  if type(artifact) ~= "table" then
    return false
  end
  return NewGameInitCache.validate(artifact) == true
end

return NewGameInitCache
