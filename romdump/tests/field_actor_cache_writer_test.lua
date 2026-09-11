-- Marker-last transaction tests for the field-actor cache writer, against an
-- in-memory cache and a synthetic bundle. Covers readiness, rollback on a failed
-- write, and the incomplete-bundle rejection.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldActorCacheWriter = require("romdump.src.digest.actor.FieldActorCacheWriter")

local T = {}

local FieldActorFixture = require("tests.support.FieldActorFixture")

local function visual(spriteId)
  return FieldActorFixture.visual(spriteId, { frameCount = 8 })
end

local AVATAR_STATE_KEYS = {
  "walking",
  "cycling",
  "surfing",
  "rocket",
  "watering",
  "fishing",
  "poketch",
  "saving",
  "heal",
  "ladder",
  "rocket_heal",
  "pokeathlon",
  "apricorn_shake",
  "rocket_saving",
}

local function avatarCapability(id, gender, spriteIds)
  local states = {}
  for i, name in ipairs(AVATAR_STATE_KEYS) do
    states[name] = spriteIds[((i - 1) % #spriteIds) + 1]
  end
  return { id = id, gender = gender, states = states }
end

local function bundle(spriteIds)
  local visuals, atlases = {}, {}
  for _, spriteId in ipairs(spriteIds) do
    visuals[spriteId] = visual(spriteId)
    atlases[spriteId] = { width = 4, height = 1, pixels = string.rep("\0", 16) }
  end
  return {
    marker = FieldActorCache.marker("abc", "dep"),
    index = {
      schema = FieldActorCache.INDEX_SCHEMA,
      romVersion = "heartgold",
      spriteIds = spriteIds,
      variableSprites = {},
      recordCount = 3,
      runtime = {
        avatars = { avatarCapability("hero", 0, spriteIds), avatarCapability("heroine", 1, spriteIds) },
        variableSprites = { first = 101, last = 117, variableBase = 0x4020 },
      },
    },
    visuals = visuals,
    atlases = atlases,
    provenance = { schema = "g4-field-actor-provenance-v1" },
    dependencies = {},
  }
end

function T.writes_visuals_atlases_and_marker()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local b = bundle({ 0, 29 })
  Assert.equal(FieldActorCacheWriter.write(cache, b), b.marker)
  Assert.isTrue(FieldActorCache.isReady(cache, b.marker), "ready after write")
  Assert.isTrue(cache:exists(FieldActorCache.atlasPath(29), "file"))
  Assert.equal(cache:loadLua(FieldActorCache.visualPath(0)).spriteId, 0)
  Assert.deepEqual(cache:loadLua(FieldActorCache.indexPath()).runtime.avatars, b.index.runtime.avatars)
end

function T.is_not_ready_for_a_different_marker()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local b = bundle({ 0 })
  FieldActorCacheWriter.write(cache, b)
  Assert.isFalse(FieldActorCache.isReady(cache, FieldActorCache.marker("abc", "other")))
end

function T.is_not_ready_when_an_atlas_is_missing()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local b = bundle({ 0, 29 })
  FieldActorCacheWriter.write(cache, b)
  cache:remove(FieldActorCache.atlasPath(29))
  Assert.isFalse(FieldActorCache.isReady(cache, b.marker))
end

function T.rejects_a_bundle_missing_an_indexed_sprite()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local b = bundle({ 0 })
  b.index.spriteIds = { 0, 99 }
  local err = Assert.throws(function()
    FieldActorCacheWriter.write(cache, b)
  end)
  Assert.isTrue(Errors.is(err), "expected an Errors object")
  Assert.equal(err.code, "FIELD_ACTOR_BUNDLE_INCOMPLETE")
  Assert.isNil(cache:read(FieldActorCache.markerPath()))
end

function T.rolls_back_the_actor_subtree_on_a_failed_write()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local original = backend.write
  backend.write = function(self, path, data)
    if path:find("0029.png", 1, true) then
      error("injected write failure")
    end
    return original(self, path, data)
  end
  Assert.throws(function()
    FieldActorCacheWriter.write(cache, bundle({ 0, 29 }))
  end)
  Assert.isNil(cache:read(FieldActorCache.markerPath()))
  Assert.isFalse(cache:exists(FieldActorCache.visualPath(0), "file"), "a partial build leaves no visual behind")
end

function T.failed_rebuild_preserves_the_previous_artifact()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local first = bundle({ 0, 29 })
  FieldActorCacheWriter.write(cache, first)
  local original = backend.write
  backend.write = function(self, path, data)
    if path:find("visuals/0029.lua", 1, true) then
      error("injected write failure")
    end
    return original(self, path, data)
  end
  local second = bundle({ 0, 29 })
  second.marker = FieldActorCache.marker("abc", "new-dep")
  Assert.throws(function()
    FieldActorCacheWriter.write(cache, second)
  end)
  Assert.isTrue(FieldActorCache.isReady(cache, first.marker), "the previous artifact remains ready")
  Assert.equal(cache:loadLua(FieldActorCache.visualPath(29)).spriteId, 29)
  Assert.equal(cache:read(FieldActorCache.markerPath()), first.marker, "the new marker never reached the live tree")
  Assert.isNil(backend:getInfo("staging/heartgold/field-actors"), "the stage is cleaned on failure")
  backend.write = original
  FieldActorCacheWriter.write(cache, second)
  Assert.isTrue(FieldActorCache.isReady(cache, second.marker), "a successful retry publishes the new artifact")
  Assert.isNil(backend:getInfo("staging/heartgold/field-actors"), "the stage is cleaned on success")
end

-- A rename failure after publish begins must not trigger writer-level stage
-- cleanup: the adjacent old roots remain recovery material.
function T.publish_failure_keeps_the_stage_with_recovery_material()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local first = bundle({ 0 })
  FieldActorCacheWriter.write(cache, first)
  local originalReplace = backend.replace
  backend.replace = function(self, sourcePath, destinationPath)
    if sourcePath:find(".__g4next", 1, true) or sourcePath:find(".__g4old", 1, true) then
      return false, "injected publish failure"
    end
    return originalReplace(self, sourcePath, destinationPath)
  end
  local second = bundle({ 0 })
  second.marker = FieldActorCache.marker("abc", "new-dep")
  local err = Assert.throws(function()
    FieldActorCacheWriter.write(cache, second)
  end)
  Assert.equal(err.code, "CACHE_PUBLISH_ROLLBACK_INCOMPLETE")
  Assert.notNil(backend:getInfo("staging/heartgold/field-actors"), "the stage is not removed once publish has begun")
  Assert.equal(
    backend.files["heartgold/" .. FieldActorCache.dir() .. ".__g4old/complete"],
    first.marker,
    "the last-known-good actor class stays in the stage as recovery material"
  )
end

return { tests = T }
