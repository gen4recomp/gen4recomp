-- Tests the one version-aware semantic boundary used by persisted records and
-- in-memory field construction.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Errors = require("libs.errors.src.Errors")
local GameSaveValidation = require("game.hgss.src.save.GameSaveValidation")
local MonsSave = require("libs.mons.src.MonsSave")

local T = {}

local function monsBucket()
  return MonsSave.empty(CatalogFixture.makeCatalog():fingerprint(), 7)
end

local function context()
  return {
    charmap = { G = 1, O = 2, L = 3, D = 4 },
    frameIndexes = { [0] = true },
    audioSequenceIds = { [7] = true },
    monCatalog = CatalogFixture.makeCatalog(),
    scriptCompatibility = {
      validationOptions = function()
        return {
          expectedRegistryFingerprint = "registry",
          expectedTaskFingerprint = "tasks",
          resolveTask = function()
            return nil
          end,
          resolveComposition = function()
            return nil
          end,
        }
      end,
    },
  }
end

local function record(saveId, versionId, playerData)
  return {
    schema = "g4-game-save-v2",
    saveId = saveId,
    versionId = versionId,
    playTimeSeconds = 0,
    mapId = 60,
    fieldX = 684,
    fieldZ = 393,
    worldY = 0,
    surfaceId = 0,
    terrainDependencyHash = "terrain-" .. versionId,
    facing = "south",
    playerData = playerData,
    world = { flags = {}, variables = {}, objects = {}, rng = { state = 1, calls = 0 } },
    scripts = {
      schema = "g4-script-save-v1",
      registryFingerprint = "registry",
      taskFingerprint = "tasks",
      capturedAtSimulationTick = 0,
      nextEnvironmentId = 0,
      nextInstanceId = 0,
      nextTaskId = 0,
      environments = {},
      instances = {},
      tasks = {},
    },
    auxiliaryUi = { requested = "shown", state = "shown" },
    audio = {},
    mons = monsBucket(),
  }
end

local function fieldObjectActor(overrides)
  local result = {
    actorId = "map:60:object:7",
    mapId = 60,
    objectEventId = 7,
    sourceMovementType = "walk_north_east_west_south",
    movementType = "walk_north_east_west_south",
    fieldX = 12,
    fieldZ = 14,
    cellKey = "0:0",
    sourceSurfaceId = 3,
    facing = "east",
    managerOrder = 0,
    controller = { kind = "pattern", timer = 0, sequenceIndex = 1 },
  }
  for key, value in pairs(overrides or {}) do
    rawset(result, key, value)
  end
  return result
end

local function fieldObjectBucket(actor)
  return {
    schema = "g4-field-objects-v1",
    rng = { state = 7, calls = 3 },
    actors = { [actor.actorId] = actor },
  }
end

local validPlayerData = {
  profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
  options = { textFrame = 0, textSpeed = "mid" },
}

function T.full_record_validation_is_shared_and_version_context_is_cached()
  local loads = 0
  local service = GameSaveValidation.new({
    contextLoader = function(versionId)
      loads = loads + 1
      Assert.equal(versionId, "heartgold")
      return context()
    end,
  })
  local first = assert(service:validate(record("save-00000001", "heartgold", validPlayerData)))
  local second = assert(service:validate(record("save-00000002", "heartgold", validPlayerData)))
  Assert.equal(first.saveId, "save-00000001")
  Assert.equal(second.saveId, "save-00000002")
  Assert.equal(loads, 1)
  local invalid, err = service:validate(record("save-00000003", "heartgold", { options = {} }))
  Assert.isNil(invalid)
  Assert.isTrue(Errors.is(err))
end

function T.version_context_failure_does_not_borrow_another_version()
  local service = GameSaveValidation.new({
    contextLoader = function(versionId)
      if versionId == "heartgold" then
        return context()
      end
      Errors.raise("SAVE_VERSION_CONTEXT_UNAVAILABLE", "version context is unavailable", { versionId = versionId })
    end,
  })
  Assert.notNil(service:validate(record("save-00000001", "heartgold", validPlayerData)))
  local invalid, err = service:validate(record("save-00000002", "soulsilver", validPlayerData))
  Assert.isNil(invalid)
  local unavailableError = assert(err)
  Assert.equal(unavailableError.code, "SAVE_VERSION_CONTEXT_UNAVAILABLE")
end

function T.complete_validation_rejects_stale_task_identity()
  local selected = context()
  selected.scriptCompatibility.validationOptions = function()
    return {
      expectedRegistryFingerprint = "registry",
      expectedTaskFingerprint = "current-tasks",
      resolveTask = function()
        return nil
      end,
      resolveComposition = function()
        return nil
      end,
    }
  end
  local service = GameSaveValidation.new({
    contextLoader = function()
      return selected
    end,
  })
  local invalid, err = service:validate(record("save-00000004", "heartgold", validPlayerData))
  Assert.isNil(invalid)
  Assert.isTrue(Errors.is(err))
  local validationError = assert(err)
  Assert.equal(validationError.code, "GAME_SAVE_BUCKET_INVALID")
end

function T.complete_validation_composes_field_object_validation()
  local service = GameSaveValidation.new({
    contextLoader = function()
      return context()
    end,
  })
  local candidate = record("save-00000005", "heartgold", validPlayerData)
  candidate.world.objects = {
    schema = "g4-field-objects-v1",
    rng = { state = 7, calls = 3 },
    actors = {},
  }
  local valid = assert(service:validate(candidate))
  Assert.equal(valid.world.objects.schema, "g4-field-objects-v1")
end

function T.complete_validation_rejects_malformed_field_object_actor_state()
  local service = GameSaveValidation.new({
    contextLoader = function()
      return context()
    end,
  })

  local validRecord = record("save-00000006", "heartgold", validPlayerData)
  validRecord.world.objects = fieldObjectBucket(fieldObjectActor())
  Assert.notNil(service:validate(validRecord), "the valid field-object actor must pass")

  local oversizedPatternIndex = record("save-00000007", "heartgold", validPlayerData)
  local invalidPatternActor = fieldObjectActor()
  invalidPatternActor.controller.sequenceIndex = 999
  oversizedPatternIndex.world.objects = fieldObjectBucket(invalidPatternActor)
  local invalid, err = service:validate(oversizedPatternIndex)
  Assert.isNil(invalid)
  Assert.isTrue(Errors.is(err))

  local removedBlockedState = record("save-00000008", "heartgold", validPlayerData)
  removedBlockedState.world.objects = fieldObjectBucket(fieldObjectActor({
    controller = { kind = "pattern", timer = 0, sequenceIndex = 1, blocked = false },
  }))
  invalid, err = service:validate(removedBlockedState)
  Assert.isNil(invalid)
  Assert.isTrue(Errors.is(err))
end

function T.complete_validation_canonicalizes_a_missing_avatar_to_walking()
  local service = GameSaveValidation.new({
    contextLoader = function()
      return context()
    end,
  })
  local candidate = record("save-00000009", "heartgold", validPlayerData)
  Assert.isNil(candidate.avatar)
  local valid = assert(service:validate(candidate))
  Assert.deepEqual(valid.avatar, { state = "walking" }, "a legacy record without avatar state loads as walking")
  Assert.equal(valid.schema, "g4-game-save-v1", "canonicalization must not bump the schema")
end

function T.complete_validation_round_trips_every_durable_avatar_state()
  local service = GameSaveValidation.new({
    contextLoader = function()
      return context()
    end,
  })
  for _, durable in ipairs({ "walking", "cycling", "surfing", "rocket" }) do
    local candidate = record("save-00000010", "heartgold", validPlayerData)
    candidate.avatar = { state = durable }
    local valid = assert(service:validate(candidate))
    Assert.deepEqual(valid.avatar, { state = durable })
  end
end

function T.complete_validation_rejects_non_durable_and_malformed_avatar_records()
  local service = GameSaveValidation.new({
    contextLoader = function()
      return context()
    end,
  })
  local cases = {
    { avatar = { state = "heal" }, label = "temporary visual state" },
    { avatar = { state = "saving" }, label = "temporary saving state" },
    { avatar = { state = "nope" }, label = "unknown state" },
    { avatar = {}, label = "missing state" },
    { avatar = { state = 7 }, label = "non-string state" },
    { avatar = { state = "walking", phase = 3 }, label = "unknown extra field" },
    { avatar = "walking", label = "non-table record" },
  }
  for _, case in ipairs(cases) do
    local candidate = record("save-00000011", "heartgold", validPlayerData)
    candidate.avatar = case.avatar
    local invalid, err = service:validate(candidate)
    Assert.isNil(invalid, case.label .. " must not validate")
    Assert.isTrue(Errors.is(err), case.label .. " must raise a structured error")
  end
end

return { tests = T }
