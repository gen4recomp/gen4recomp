-- Save compatibility: former records and records with a missing mons
-- bucket are rejected through the structured save-error path without
-- synthesizing a fallback party.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local GameSave = require("libs.hgss.src.save.GameSave")

local T = {}

local function record(schema, mons)
  local value = {
    schema = schema,
    saveId = "save-00000001",
    versionId = "heartgold",
    playTimeSeconds = 0,
    mapId = 60,
    fieldX = 684,
    fieldZ = 393,
    worldY = 0,
    surfaceId = 0,
    terrainDependencyHash = "terrain-heartgold",
    facing = "south",
    playerData = { profile = {}, options = {} },
    world = { flags = {}, variables = {}, objects = {}, rng = {} },
    scripts = {},
    auxiliaryUi = {},
    audio = {},
  }
  if mons ~= nil then
    rawset(value, "mons", mons)
  end
  return value
end

local function rejectionCode(candidate)
  local valid, err = GameSave.validate(candidate)
  Assert.isNil(valid, "the record must not validate")
  Assert.isTrue(Errors.is(err), "rejection uses the structured save-error path")
  return assert(err).code
end

function T.former_schema_is_rejected_without_migration()
  Assert.equal(
    rejectionCode(record("g4-game-save-v1")),
    "GAME_SAVE_SCHEMA_UNSUPPORTED",
    "the former schema is rejected rather than migrated"
  )
end

function T.missing_mons_bucket_is_rejected_without_synthesis()
  Assert.equal(
    rejectionCode(record("g4-game-save-v2")),
    "GAME_SAVE_BUCKET_INVALID",
    "a record without a mons bucket is rejected rather than defaulted"
  )
end

return { tests = T }
