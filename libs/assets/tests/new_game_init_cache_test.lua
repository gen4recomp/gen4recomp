-- Strict validation for the generated fresh-game startup initializer. Schema
-- v3 carries the source-grounded initial player-room location alongside the
-- ordered startup operations; stale v2 artifacts and any raw source-direction
-- fields inside the runtime location are rejected.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local NewGameInitCache = require("libs.assets.src.newgame.NewGameInitCache")

local T = {}

local flags = FieldScriptSymbols.flagsByName
local vars = FieldScriptSymbols.variablesByName

local function operations()
  return {
    {
      op = "set_flag",
      id = flags.FLAG_HIDE_PLAYERS_ROOM_BRONZE_TROPHY,
      symbol = "FLAG_HIDE_PLAYERS_ROOM_BRONZE_TROPHY",
    },
    {
      op = "roll_loto_id",
      lowVariableId = vars.VAR_LOTO_NUMBER_LO,
      lowVariableSymbol = "VAR_LOTO_NUMBER_LO",
      highVariableId = vars.VAR_LOTO_NUMBER_HI,
      highVariableSymbol = "VAR_LOTO_NUMBER_HI",
    },
  }
end

local function sourceDependency()
  return { standardScriptMember = 149, sha1 = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" }
end

local function initialLocation(overrides)
  local location = {
    mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
    fieldX = 6,
    fieldZ = 6,
    facing = "south",
  }
  if overrides then
    for key, value in pairs(overrides) do
      location[key] = value
    end
  end
  return location
end

local function v3Artifact(locationOverrides)
  return {
    schema = "g4-new-game-init-v3",
    versionId = "heartgold",
    operations = operations(),
    sourceDependency = sourceDependency(),
    initialLocation = initialLocation(locationOverrides),
  }
end

local function rejects(artifact)
  local ok = NewGameInitCache.validate(artifact)
  Assert.isFalse(ok, "malformed startup artifact must not validate")
end

function T.stale_v2_artifacts_are_not_current()
  rejects({
    schema = "g4-new-game-init-v2",
    versionId = "heartgold",
    operations = operations(),
    sourceDependency = sourceDependency(),
  })
end

function T.valid_v3_artifact_passes()
  Assert.isTrue(NewGameInitCache.validate(v3Artifact()))
end

function T.missing_initial_location_is_rejected()
  local artifact = v3Artifact()
  artifact.initialLocation = nil
  rejects(artifact)
end

function T.unknown_location_keys_are_rejected()
  local location = initialLocation()
  location.climate = "temperate"
  local artifact = v3Artifact()
  artifact.initialLocation = location
  rejects(artifact)
end

function T.raw_source_direction_fields_are_rejected()
  for _, key in ipairs({ "sourceFacing", "direction", "mapId" }) do
    local location = initialLocation()
    location[key] = 1
    local artifact = v3Artifact()
    artifact.initialLocation = location
    rejects(artifact)
  end
end

function T.malformed_location_domains_are_rejected()
  rejects(v3Artifact({ mapSymbol = "" }))
  rejects(v3Artifact({ mapSymbol = "NOT_A_MAP" }))
  rejects(v3Artifact({ mapSymbol = 64 }))
  rejects(v3Artifact({ fieldX = 6.5 }))
  rejects(v3Artifact({ fieldZ = "6" }))
  rejects(v3Artifact({ facing = "up" }))
  rejects(v3Artifact({ facing = 1 }))
  local missingFacing = v3Artifact()
  missingFacing.initialLocation.facing = nil
  rejects(missingFacing)
end

function T.readiness_requires_a_current_v3_artifact()
  local backend = FakeCache.new()
  local cacheFs = CacheFs.forVersion("heartgold", backend)
  local marker = NewGameInitCache.marker("rom-sha", "dep-hash")
  cacheFs:writeLua(NewGameInitCache.path(), v3Artifact())
  cacheFs:write(NewGameInitCache.markerPath(), marker)
  Assert.isTrue(NewGameInitCache.isReady(cacheFs, marker))

  local staleBackend = FakeCache.new()
  local staleFs = CacheFs.forVersion("heartgold", staleBackend)
  local staleMarker = NewGameInitCache.marker("rom-sha", "old-hash")
  staleFs:writeLua(NewGameInitCache.path(), {
    schema = "g4-new-game-init-v2",
    versionId = "heartgold",
    operations = operations(),
    sourceDependency = sourceDependency(),
  })
  staleFs:write(NewGameInitCache.markerPath(), staleMarker)
  Assert.isFalse(NewGameInitCache.isReady(staleFs, staleMarker))
end

return { tests = T }
