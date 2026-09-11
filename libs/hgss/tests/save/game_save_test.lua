-- GameSave validation tests cover the strict persisted record boundary while
-- leaving domain-owned bucket rules with their injected validators.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local GameSave = require("libs.hgss.src.save.GameSave")
local BagSave = require("libs.hgss.src.save.BagSave")

local T = {}

local function record(overrides)
  local value = {
    schema = GameSave.SCHEMA,
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

local function returnsCode(code, fn)
  local valid, err = fn()
  Assert.isNil(valid)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, code)
end

function T.validates_required_buckets_and_numeric_ranges()
  local valid = assert(GameSave.validate(record()))
  Assert.equal(valid.saveId, "save-00000001")

  returnsCode("GAME_SAVE_SCHEMA_UNSUPPORTED", function()
    return GameSave.validate(record({ schema = "g4-field-save-v3" }))
  end)
  returnsCode("GAME_SAVE_SAVE_ID_INVALID", function()
    return GameSave.validate(record({ saveId = "../escape" }))
  end)
  returnsCode("GAME_SAVE_PLAY_TIME_INVALID", function()
    return GameSave.validate(record({ playTimeSeconds = 3599999 + 1 }))
  end)
  returnsCode("GAME_SAVE_FIELD_INVALID", function()
    return GameSave.validate(record({ facing = "up" }))
  end)
  returnsCode("GAME_SAVE_BUCKET_INVALID", function()
    local value = record()
    value.scripts = nil
    return GameSave.validate(value)
  end)
end

function T.live_weather_is_optional_for_legacy_records_and_strict_when_present()
  Assert.isTrue(GameSave.validate(record({ weatherId = 0 })) ~= nil)
  Assert.isTrue(GameSave.validate(record({ weatherId = 13 })) ~= nil)
  Assert.isTrue(GameSave.validate(record({ weatherId = -1 })) == nil)
  Assert.isTrue(GameSave.validate(record({ weatherId = 14 })) == nil)
  Assert.isTrue(GameSave.validate(record({ weatherId = 1.5 })) == nil)
  Assert.isTrue(GameSave.validate(record()) ~= nil)
end

function T.uses_injected_authoritative_bucket_validators()
  local calls = {}
  local opts = {
    playerDataValidate = function(value)
      calls.playerData = value
      return { canonical = true }
    end,
    worldValidate = function(value)
      calls.world = value
    end,
    scriptsValidate = function(value)
      calls.scripts = value
    end,
    auxiliaryUiValidate = function(value)
      calls.auxiliaryUi = value
    end,
    audioValidate = function(value)
      calls.audio = value
    end,
    monsValidate = function(value)
      calls.mons = value
    end,
    bagValidate = function(value)
      calls.bag = value
    end,
  }
  local valid = assert(GameSave.validate(record(), opts))
  Assert.deepEqual(valid.playerData, { canonical = true })
  Assert.notNil(calls.playerData)
  Assert.notNil(calls.world)
  Assert.notNil(calls.scripts)
  Assert.notNil(calls.auxiliaryUi)
  Assert.notNil(calls.audio)
  Assert.notNil(calls.mons)
  Assert.notNil(calls.bag)
end

function T.rejects_non_table_and_missing_required_buckets()
  returnsCode("GAME_SAVE_INVALID", function()
    ---@diagnostic disable-next-line: param-type-mismatch -- test deliberately exercises an invalid call
    return GameSave.validate(nil)
  end)
  for _, key in ipairs({ "playerData", "world", "auxiliaryUi", "audio", "mons" }) do
    returnsCode("GAME_SAVE_BUCKET_INVALID", function()
      local value = record()
      value[key] = nil
      return GameSave.validate(value)
    end)
  end
  returnsCode("GAME_SAVE_BUCKET_INVALID", function()
    local value = record()
    value.bag = nil
    return GameSave.validate(value)
  end)
end

function T.rejects_removed_top_level_session_fields()
  for _, field in ipairs({ "scenario", "currentState" }) do
    local valid = record({ [field] = {} })
    local canonical, err = GameSave.validate(valid)
    Assert.isNil(canonical)
    err = assert(err)
    Assert.equal(err.code, "GAME_SAVE_INVALID")
    Assert.equal(err.context.field, field)
  end
  Assert.notNil(GameSave.validate(record()))
end

return { tests = T }
