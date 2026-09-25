-- The fresh-New-Game-only source event initializer handoff: applies the
-- generated `_std_init` operations in source order to a finalized Oak
-- candidate's authoritative worldState before FieldState/FieldRuntime construct any
-- actor. It never creates a second event-state copy, never touches
-- player/profile/options, and never runs on Continue.

local CacheFs = require("libs.storage.src.CacheFs")
local NewGameInitCache = require("libs.assets.src.newgame.NewGameInitCache")

local NewGameInitialization = {}

local function loadArtifact(versionId)
  assert(type(versionId) == "string", "NewGameInitialization requires a versionId to load the startup artifact")
  local cacheFs = CacheFs.forVersion(versionId)
  local artifact = assert(
    cacheFs:loadLua(NewGameInitCache.path()),
    "fresh-game startup initializer cache is cold -- run `scripts/buildcache.sh` first"
  )
  assert(NewGameInitCache.validate(artifact), "fresh-game startup initializer cache is invalid")
  return artifact
end

local function validateU16(value)
  if type(value) ~= "number" or value ~= math.floor(value) or value < 0 or value > 0xFFFF then
    error("randomU16 must return an integer in 0..0xFFFF, got " .. tostring(value))
  end
  return value
end

local function defaultRandomU16()
  local v = love.math.random(0, 0xFFFF)
  return validateU16(v)
end

local function applyRollLotoId(operation, candidate, randomU16)
  local lowDraw = validateU16(randomU16())
  candidate.worldState:setVar(operation.lowVariableId, lowDraw)
  local highDraw = validateU16(randomU16())
  candidate.worldState:setVar(operation.lowVariableId, highDraw)
end

function NewGameInitialization.apply(candidate, artifactOrOptions)
  assert(type(candidate) == "table", "apply requires a candidate")
  assert(
    type(candidate.worldState) == "table"
      and type(candidate.worldState.setFlag) == "function"
      and type(candidate.worldState.setVar) == "function"
      and type(candidate.worldState.serialize) == "function",
    "apply requires a candidate with an authoritative worldState"
  )

  local artifact
  local randomU16
  if artifactOrOptions ~= nil then
    if
      type(artifactOrOptions) == "table" and (artifactOrOptions.artifact ~= nil or artifactOrOptions.randomU16 ~= nil)
    then
      artifact = artifactOrOptions.artifact
      randomU16 = artifactOrOptions.randomU16
    elseif
      type(artifactOrOptions) == "table" and (artifactOrOptions.operations ~= nil or artifactOrOptions.schema ~= nil)
    then
      artifact = artifactOrOptions
    end
  end
  artifact = artifact or loadArtifact(candidate.versionId)
  assert(NewGameInitCache.validate(artifact), "fresh-game startup initializer artifact is invalid")

  if randomU16 ~= nil then
    assert(type(randomU16) == "function", "randomU16 must be a function")
  else
    randomU16 = defaultRandomU16
  end

  for _, operation in ipairs(artifact.operations) do
    if operation.op == "set_flag" then
      candidate.worldState:setFlag(operation.id)
    elseif operation.op == "roll_loto_id" then
      applyRollLotoId(operation, candidate, randomU16)
    else
      error("unsupported startup operation " .. tostring(operation.op))
    end
  end
  return candidate
end

--- Reads the generated initial player-room location for a fresh New Game.
--- Loads through the same strict artifact path as apply and returns a fresh
--- caller-owned copy of the normalized record; stale or missing caches fail
--- loudly instead of falling back to a default location.
---@param versionId string
---@return table<string, string|integer> location
function NewGameInitialization.initialLocation(versionId)
  local artifact = loadArtifact(versionId)
  local location = artifact.initialLocation
  assert(type(location) == "table", "fresh-game startup initializer cache has no initial location")
  return {
    mapSymbol = location.mapSymbol,
    fieldX = location.fieldX,
    fieldZ = location.fieldZ,
    facing = location.facing,
  }
end

return NewGameInitialization
