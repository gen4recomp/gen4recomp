-- Contract tests for the global GameSave catalog. The store owns catalog
-- visibility and canonical game paths; tests inject only the filesystem host
-- boundary and keep all game records in the project-owned schema.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.codec.src.LuaWriter")
local MonsSave = require("libs.mons.src.MonsSave")
local SaveFs = require("libs.storage.src.SaveFs")

local T = {}

local GAME_SCHEMA = "g4-game-save-v2"

local function newStore(backend, opts)
  local loaded, GameSaveStore = pcall(require, "libs.hgss.src.save.GameSaveStore")
  Assert.isTrue(loaded, "global GameSave storage service is not implemented")
  Assert.isTrue(type(GameSaveStore.new) == "function", "global GameSave storage needs a constructor")
  Assert.isTrue(type(SaveFs.global) == "function", "SaveFs needs a global product save root")
  local Store = GameSaveStore --[[@as GameSaveStoreModule]]
  return Store.new(SaveFs.global(backend), opts)
end

local function record(saveId, versionId, overrides)
  local value = {
    schema = GAME_SCHEMA,
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
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 0, money = 3000 },
      options = { textFrame = 0, textSpeed = "mid" },
    },
    world = { flags = {}, variables = {}, objects = {}, rng = { state = 1, calls = 0 } },
    scripts = {},
    auxiliaryUi = { requested = "shown", state = "shown" },
    audio = {},
    mons = MonsSave.empty("test-catalog-fingerprint", 7),
  }
  for key, valueOverride in pairs(overrides or {}) do
    value[key] = valueOverride
  end
  return value
end

local function gamePath(saveId)
  return "saves/games/" .. saveId .. ".lua"
end

local function findEntry(entries, saveId)
  for _, entry in ipairs(entries) do
    if entry.saveId == saveId then
      return entry
    end
  end
  return nil
end

---@param fn fun()
---@return Errors.Error
local function callFailure(fn)
  local ok, first, second = pcall(fn)
  if not ok then
    return first --[[@as Errors.Error]]
  end
  Assert.isNil(first, "the failing storage operation must not return a record or success value")
  Assert.notNil(second, "the failing storage operation must return its error")
  return second --[[@as Errors.Error]]
end

local function failOn(backend, method, occurrence)
  local original = assert(backend[method])
  local calls = 0
  rawset(backend, method, function(self, ...)
    calls = calls + 1
    if calls == occurrence then
      return false, "injected " .. method .. " failure"
    end
    return original(self, ...)
  end)
end

local function expectVisible(store, saveId)
  local entries = assert(store:list())
  local entry = findEntry(entries, saveId)
  Assert.notNil(entry, "published save must be catalog-visible")
  Assert.isNil(entry and entry.error, "a valid published save must not list an error")
  return entries
end

function T.multiple_versions_use_one_global_catalog_and_strict_game_records()
  local backend = FakeCache.new()
  local store = newStore(backend)
  local firstId = store:reserve()
  local secondId = store:reserve()
  local first = record(firstId, "heartgold")
  local second = record(secondId, "soulsilver")
  store:publishFirst(first)
  store:publishFirst(second)

  local entries = expectVisible(store, firstId)
  Assert.notNil(findEntry(entries, secondId))
  Assert.equal(assert(store:load(firstId)).versionId, "heartgold")
  Assert.equal(assert(store:load(secondId)).versionId, "soulsilver")
  Assert.notNil(backend.files["saves/catalog.lua"])
  Assert.notNil(backend.files[gamePath(firstId)])
  Assert.notNil(backend.files[gamePath(secondId)])
  Assert.isNil(backend.files["saves/heartgold/field-session.lua"])
  Assert.isNil(backend.files["saves/soulsilver/field-session.lua"])

  local invalidId = store:reserve()
  local invalid = record(invalidId, "heartgold", { schema = "g4-field-save-v3" })
  callFailure(function()
    store:publishFirst(invalid)
  end)
end

function T.injected_full_record_validator_classifies_payload_errors_per_card()
  local backend = FakeCache.new()
  local calls = 0
  local rejectSoulsilver = false
  local store = newStore(backend, {
    recordValidate = function(value)
      calls = calls + 1
      if rejectSoulsilver and value.versionId == "soulsilver" then
        return nil, Errors.new("SAVE_VERSION_CONTEXT_UNAVAILABLE", "version context unavailable", {})
      end
      return value
    end,
  })
  local heartgold = store:reserve()
  local soulsilver = store:reserve()
  store:publishFirst(record(heartgold, "heartgold"))
  store:publishFirst(record(soulsilver, "soulsilver"))
  rejectSoulsilver = true
  local entries = assert(store:list())
  Assert.equal(#entries, 2)
  Assert.equal(entries[1].saveId, soulsilver)
  Assert.notNil(entries[1].error)
  Assert.equal(entries[2].saveId, heartgold)
  Assert.isNil(entries[2].error)
  Assert.isTrue(calls >= 4, "full validation must cover publication and listing")
end

function T.reservation_survives_restart_without_payload_or_visibility_and_never_reuses_ids()
  local backend = FakeCache.new()
  local firstStore = newStore(backend)
  local first = firstStore:reserve()
  Assert.notNil(first)
  Assert.isNil(backend.files[gamePath(first)])
  Assert.isNil(findEntry(assert(firstStore:list()), first))

  local restarted = newStore(backend)
  local second = restarted:reserve()
  Assert.notNil(second)
  Assert.isFalse(first == second, "a later reservation must not reuse an abandoned identity")
  Assert.isNil(backend.files[gamePath(first)])
  Assert.isNil(findEntry(assert(restarted:list()), first))
  Assert.notNil(backend.files["saves/catalog.lua"], "allocation state must be durable")
end

function T.first_publication_validates_payload_before_catalog_visibility_and_can_retry_an_orphan()
  local backend = FakeCache.new()
  local store = newStore(backend)
  local saveId = store:reserve()
  local value = record(saveId, "heartgold")

  failOn(backend, "write", 1)
  callFailure(function()
    store:publishFirst(value)
  end)
  Assert.isNil(findEntry(assert(store:list()), saveId))
  Assert.isNil(backend.files[gamePath(saveId)])

  local payloadFailureBackend = FakeCache.new()
  local payloadFailureStore = newStore(payloadFailureBackend)
  local payloadFailureId = payloadFailureStore:reserve()
  failOn(payloadFailureBackend, "replace", 1)
  callFailure(function()
    payloadFailureStore:publishFirst(record(payloadFailureId, "heartgold"))
  end)
  Assert.isNil(findEntry(assert(payloadFailureStore:list()), payloadFailureId))
  Assert.isNil(payloadFailureBackend.files[gamePath(payloadFailureId)])
  Assert.isNil(payloadFailureBackend.files[gamePath(payloadFailureId) .. ".tmp"])

  local retryBackend = FakeCache.new()
  local retryStore = newStore(retryBackend)
  local retryId = retryStore:reserve()
  local retryValue = record(retryId, "heartgold")
  failOn(retryBackend, "replace", 2)
  callFailure(function()
    retryStore:publishFirst(retryValue)
  end)
  Assert.isNil(findEntry(assert(retryStore:list()), retryId))
  Assert.notNil(retryBackend.files[gamePath(retryId)], "catalog failure may leave an invisible orphan payload")

  retryStore:publishFirst(retryValue)
  Assert.notNil(findEntry(assert(retryStore:list()), retryId))
  retryValue.avatar = { state = "walking" }
  Assert.deepEqual(assert(retryStore:load(retryId)), retryValue)
end

function T.malformed_nil_catalog_and_payload_are_structured_errors()
  local backend = FakeCache.new()
  local store = newStore(backend)
  local _ = store:reserve()
  backend.files["saves/catalog.lua"] = LuaWriter.encode(nil)
  local catalogErr = callFailure(function()
    store:list()
  end)
  Assert.equal(catalogErr.code, "GAME_SAVE_CATALOG_INVALID")

  local payloadBackend = FakeCache.new()
  local payloadStore = newStore(payloadBackend)
  local payloadId = payloadStore:reserve()
  payloadStore:publishFirst(record(payloadId, "heartgold"))
  payloadBackend.files[gamePath(payloadId)] = LuaWriter.encode(nil)
  local entries = assert(payloadStore:list())
  local entry = findEntry(entries, payloadId)
  Assert.notNil(entry and entry.error)
  local payloadError = assert(entry and entry.error)
  Assert.equal(payloadError.code, "GAME_SAVE_INVALID")
end

function T.update_and_delete_failures_preserve_a_valid_checkpoint_and_order()
  local backend = FakeCache.new()
  local store = newStore(backend)
  local firstId = store:reserve()
  local secondId = store:reserve()
  local first = record(firstId, "heartgold")
  local second = record(secondId, "soulsilver")
  store:publishFirst(first)
  store:publishFirst(second)
  local before = assert(store:list())

  local replacement = record(firstId, "heartgold", { playTimeSeconds = 12 })
  failOn(backend, "replace", 1)
  callFailure(function()
    store:save(replacement)
  end)
  -- Loading canonicalizes the legacy record: validation backfills the
  -- reserved avatar field to walking.
  first.avatar = { state = "walking" }
  Assert.deepEqual(assert(store:load(firstId)), first)
  local afterFailedUpdate = assert(store:list())
  Assert.equal(afterFailedUpdate[1].saveId, before[1].saveId)
  Assert.equal(afterFailedUpdate[2].saveId, before[2].saveId)

  store:save(replacement)
  Assert.equal(assert(store:load(firstId)).playTimeSeconds, 12)
  local afterUpdate = assert(store:list())
  Assert.equal(afterUpdate[1].saveId, before[1].saveId)
  Assert.equal(afterUpdate[2].saveId, before[2].saveId)

  failOn(backend, "remove", 1)
  callFailure(function()
    store:delete(firstId)
  end)
  local failedDeleteEntries = assert(store:list())
  local failedDeleteEntry = findEntry(failedDeleteEntries, firstId)
  if failedDeleteEntry ~= nil then
    Assert.isNil(failedDeleteEntry.error, "a failed delete must not expose a broken visible save")
    Assert.equal(assert(store:load(firstId)).playTimeSeconds, 12)
  end

  store:delete(firstId)
  Assert.isNil(findEntry(assert(store:list()), firstId))
  Assert.isNil(backend.files[gamePath(firstId)])
  Assert.notNil(findEntry(assert(store:list()), secondId), "deleting one save must not affect another")
end

function T.catalog_authority_preserves_errors_and_ignores_orphans_and_reserved_gaps()
  local backend = FakeCache.new()
  local store = newStore(backend)
  local validId = store:reserve()
  local corruptId = store:reserve()
  local oldId = store:reserve()
  local abandonedId = store:reserve()
  store:publishFirst(record(validId, "heartgold"))
  store:publishFirst(record(corruptId, "heartgold"))
  store:publishFirst(record(oldId, "soulsilver"))

  backend.files[gamePath(corruptId)] = "return { schema = 'not-lua-save' }"
  backend.files[gamePath(oldId)] = LuaWriter.encode({
    schema = "g4-field-save-v3",
    saveId = oldId,
    versionId = "soulsilver",
  })
  local orphanId = "save-orphan"
  backend.files[gamePath(orphanId)] = LuaWriter.encode(record(orphanId, "heartgold"))

  local entries = assert(store:list())
  Assert.equal(#entries, 3, "only catalog-referenced IDs may be listed")
  Assert.equal(entries[1].saveId, oldId)
  Assert.equal(entries[2].saveId, corruptId)
  Assert.equal(entries[3].saveId, validId)
  Assert.notNil(findEntry(entries, corruptId).error)
  Assert.notNil(findEntry(entries, oldId).error)
  Assert.isNil(findEntry(entries, orphanId))
  Assert.isNil(findEntry(entries, abandonedId))

  callFailure(function()
    store:load(corruptId)
  end)
  callFailure(function()
    store:load(oldId)
  end)
  store:delete(corruptId)
  store:delete(oldId)
  Assert.isNil(findEntry(assert(store:list()), corruptId))
  Assert.isNil(findEntry(assert(store:list()), oldId))
  Assert.notNil(findEntry(assert(store:list()), validId))
end

function T.deleted_ids_are_not_reusable_and_published_order_follows_creation()
  local backend = FakeCache.new()
  local store = newStore(backend)
  local firstId = store:reserve()
  local secondId = store:reserve()
  store:publishFirst(record(secondId, "soulsilver"))
  store:publishFirst(record(firstId, "heartgold"))
  local entries = assert(store:list())
  Assert.equal(entries[1].saveId, secondId)
  Assert.equal(entries[2].saveId, firstId)

  store:delete(firstId)
  callFailure(function()
    store:publishFirst(record(firstId, "heartgold"))
  end)
  local thirdId = store:reserve()
  Assert.isFalse(thirdId == firstId)
  Assert.equal(thirdId, "save-00000003")
end

function T.hostile_save_ids_are_rejected_before_path_resolution()
  local store = newStore(FakeCache.new())
  local _, err = store:load("../escape")
  Assert.notNil(err)
  Assert.equal(assert(err).code, "GAME_SAVE_SAVE_ID_INVALID")
end

return { tests = T }
