-- Save compatibility: the former schema and records with a missing Bag
-- or mons bucket are rejected through the structured save-error path
-- without migrating or synthesizing a fallback.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local GameSave = require("libs.hgss.src.save.GameSave")
local BagSave = require("libs.hgss.src.save.BagSave")

local T = {}

local function record(schema, overrides)
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
    mons = {},
    bag = BagSave.empty(),
  }
  for key, replacement in pairs(overrides or {}) do
    rawset(value, key, replacement)
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
    rejectionCode(record("g4-game-save-v2")),
    "GAME_SAVE_SCHEMA_UNSUPPORTED",
    "the former schema is rejected rather than migrated"
  )
end

function T.missing_bag_bucket_is_rejected_without_synthesis()
  local value = record(GameSave.SCHEMA)
  value.bag = nil
  Assert.equal(
    rejectionCode(value),
    "GAME_SAVE_BUCKET_INVALID",
    "a record without a bag bucket is rejected rather than defaulted"
  )
end

function T.missing_mons_bucket_is_rejected_without_synthesis()
  local value = record(GameSave.SCHEMA)
  value.mons = nil
  Assert.equal(
    rejectionCode(value),
    "GAME_SAVE_BUCKET_INVALID",
    "a record without a mons bucket is rejected rather than defaulted"
  )
end

return { tests = T }
