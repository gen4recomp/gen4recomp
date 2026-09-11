-- Script cache writer tests: marker-last publishing, index/provenance
-- layout, and rollback on readback failure (mirrors the field-message cache
-- writer contract).

local Assert = require("tests.support.Assert")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptCacheWriter = require("romdump.src.digest.script.ScriptCacheWriter")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")

local T = {}
local GENERATION_A = string.rep("a", 40)
local GENERATION_B = string.rep("b", 40)

local function memberCoverage(memberId, id, scriptIndex)
  return {
    source = { repository = "g4recomp", romSha1 = "rom-sha" },
    totals = {
      members = 1,
      scripts = 1,
      reachableInstructions = 1,
      supportedInstructions = 1,
      unsupportedInstructions = 0,
      malformedInstructions = 0,
    },
    opcodes = {},
    scripts = {
      {
        sourceId = string.format("hgss.scr_seq.%04d.%03d", memberId, scriptIndex or 0),
        publicId = id,
        status = "complete",
        unsupported = {},
      },
    },
  }
end

local function bundle()
  return {
    marker = "script-cache-v4:rom-sha:dep-sha",
    index = {
      schema = ScriptCache.INDEX_SCHEMA,
      generation = GENERATION_A,
      marker = "script-cache-v4:rom-sha:dep-sha",
      version = "heartgold",
      memberCount = 2,
      scriptMemberCount = 2,
      skippedMemberCount = 0,
      scriptCount = 2,
      resourceCount = 2,
      resources = {
        { id = "common.signpost", member = 3, scriptIndex = 0 },
        { id = "new_bark.lab_sign", member = 843, scriptIndex = 9 },
      },
    },
    dependencies = {
      cacheFormat = ScriptCache.FORMAT,
      versionRomSha1 = "rom-sha",
      scrSeqNarc = { path = "a/0/1/2", sha1 = "archive-sha" },
    },
    coverageRecord = {
      source = { repository = "g4recomp", romSha1 = "rom-sha" },
      totals = {
        members = 1,
        scripts = 2,
        reachableInstructions = 2,
        supportedInstructions = 2,
        unsupportedInstructions = 0,
        malformedInstructions = 0,
      },
      opcodes = {},
      scripts = {},
    },
    resources = {
      {
        id = "common.signpost",
        member = 3,
        scriptIndex = 0,
        resource = {
          api = 1,
          id = "common.signpost",
          metadata = { coverage = { complete = true, unsupportedCount = 0 } },
          steps = { { op = "stop" } },
        },
      },
      {
        id = "new_bark.lab_sign",
        member = 843,
        scriptIndex = 9,
        resource = {
          api = 1,
          id = "new_bark.lab_sign",
          metadata = { coverage = { complete = true, unsupportedCount = 0 } },
          steps = { { op = "stop" } },
        },
      },
    },
    memberCoverage = {
      [3] = memberCoverage(3, "common.signpost"),
      [843] = memberCoverage(843, "new_bark.lab_sign", 9),
    },
  }
end

-- 1. The writer publishes provenance, index, coverage, per-id scripts, and
-- only then the marker; isReady then reports the class complete.
T["write publishes marker last"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local ok, err = ScriptCacheWriter.write(cache, bundle())
  Assert.isNil(err)
  Assert.isTrue(ok)
  Assert.notNil(cache:read(ScriptCache.provenancePath()))
  Assert.notNil(cache:read(ScriptCache.coverageJsonPath()))
  local index = cache:loadLua(ScriptCache.generationIndexPath(GENERATION_A))
  index = index --[[@as { schema: string, resourceCount: integer, resources: table[] }]]
  Assert.equal(index.schema, ScriptCache.INDEX_SCHEMA)
  Assert.equal(index.resourceCount, 2)
  local signpost = cache:loadModule(ScriptCache.scriptPath(GENERATION_A, 3, "common.signpost"))
  signpost = signpost --[[@as { kind: string, id: string }]]
  Assert.equal(signpost.kind, "field_script")
  Assert.equal(signpost.id, "common.signpost")
  Assert.equal(cache:read(ScriptCache.markerPath()), "script-cache-v4:rom-sha:dep-sha")
  local coverage = assert(cache:read(ScriptCache.generationCoverageMdPath(GENERATION_A)))
  Assert.isTrue(coverage:find("| Members | 2 |", 1, true) ~= nil)
  Assert.isTrue(coverage:find("| Scripts | 2 |", 1, true) ~= nil)
  Assert.isTrue(ScriptCache.isReady(cache, "script-cache-v4:rom-sha:dep-sha"))
end

-- 2. A missing script file fails readiness.
T["readiness requires every indexed script"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  ScriptCacheWriter.write(cache, bundle())
  cache:remove(ScriptCache.scriptPath(GENERATION_A, 843, "new_bark.lab_sign"))
  Assert.isFalse(ScriptCache.isReady(cache, "script-cache-v4:rom-sha:dep-sha"))
end

-- 3. A readback failure rolls the whole class back (no partial cache).
T["readback failure rolls back"] = function()
  local real = require("romdump.src.digest.script.ScriptCacheWriter")
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local bad = bundle()
  bad.resources[1].resource = { api = 1, id = "other", steps = {} }
  local failed = false
  local ok = pcall(real.write, cache, bad)
  if not ok then
    failed = true
  end
  Assert.isTrue(failed)
  Assert.equal(cache:read(ScriptCache.markerPath()), nil)
  Assert.isNil(cache:read(ScriptCache.activeIndexPath()))
end

-- 4. A failed rebuild leaves the previous ready artifact untouched, the stage
-- clean, and a retry publishes the new artifact.
T["failed rebuild preserves the previous script artifact"] = function()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  ScriptCacheWriter.write(cache, bundle())
  local original = backend.write
  backend.write = function(self, path, data)
    if path:find("coverage.json", 1, true) then
      error("injected write failure")
    end
    return original(self, path, data)
  end
  local second = bundle()
  second.marker = "script-cache-v4:rom-sha:new-dep-sha"
  second.index.generation = GENERATION_B
  second.index.marker = second.marker
  Assert.throws(function()
    ScriptCacheWriter.write(cache, second)
  end)
  Assert.isTrue(ScriptCache.isReady(cache, "script-cache-v4:rom-sha:dep-sha"), "the previous artifact remains ready")
  Assert.equal(cache:read(ScriptCache.markerPath()), "script-cache-v4:rom-sha:dep-sha", "no new marker leaked")
  Assert.isNil(backend:getInfo("staging/heartgold/scripts"), "the stage is cleaned on failure")
  backend.write = original
  ScriptCacheWriter.write(cache, second)
  Assert.isTrue(ScriptCache.isReady(cache, "script-cache-v4:rom-sha:new-dep-sha"), "a retry publishes the new artifact")
  Assert.isNil(backend:getInfo("staging/heartgold/scripts"), "the stage is cleaned on success")
end

-- 5. A rename failure after publish begins must not trigger writer-level
-- stage cleanup: the adjacent old root remains recovery material.
T["publish failure keeps the stage with recovery material"] = function()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  ScriptCacheWriter.write(cache, bundle())
  local originalReplace = backend.replace
  backend.replace = function(self, sourcePath, destinationPath)
    if
      sourcePath == "heartgold/" .. ScriptCache.activeDir() .. ".__g4next"
      or sourcePath == "heartgold/" .. ScriptCache.activeDir() .. ".__g4old"
    then
      return false, "injected publish failure"
    end
    return originalReplace(self, sourcePath, destinationPath)
  end
  local second = bundle()
  second.marker = "script-cache-v4:rom-sha:new-dep-sha"
  second.index.generation = GENERATION_B
  second.index.marker = second.marker
  local err = Assert.throws(function()
    ScriptCacheWriter.write(cache, second)
  end)
  Assert.equal(err.code, "CACHE_PUBLISH_ROLLBACK_INCOMPLETE")
  Assert.notNil(backend:getInfo("staging/heartgold/scripts"), "the stage is not removed once publish has begun")
  Assert.equal(
    backend.files["heartgold/" .. ScriptCache.activeDir() .. ".__g4old/complete"],
    "script-cache-v4:rom-sha:dep-sha",
    "the last-known-good script class stays in the stage as recovery material"
  )
end

return { tests = T }
