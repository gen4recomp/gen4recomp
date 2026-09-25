-- FieldScriptCompatibility tests: registry identity reads use the production
-- script composition; the published index hashes seed the fingerprint, so
-- acquisition reads no generated bodies and writes nothing.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldScriptCompatibility = require("game.hgss.src.field.FieldScriptCompatibility")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptLoader = require("libs.script.src.ScriptLoader")
local ScriptOverrides = require("libs.assets.src.ScriptOverrides")
local LuaWriter = require("libs.codec.src.LuaWriter")
local Sha256 = require("libs.script.src.Sha256")

local T = {}
local GENERATION = string.rep("a", 40)
local MARKER = "script-cache-v4:rom-sha:dep-sha"

---@class FieldScriptCompatibilityTestSurface : FieldScriptCompatibility
---@field validationOptions fun(self: FieldScriptCompatibilityTestSurface): table

local SCRIPT_ID = "new_bark.lab_sign"
local SCRIPT = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "'
  .. SCRIPT_ID
  .. '", steps = { S.stop() } }\n'

local function overrideFs()
  return {
    read = function(_, path)
      if path == ScriptOverrides.MANIFEST then
        return "return {}\n"
      end
      return nil
    end,
  }
end

local function scriptCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:write(ScriptCache.markerPath(), MARKER)
  cache:write(ScriptCache.generationMarkerPath(GENERATION), MARKER)
  cache:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = MARKER,
  })
  cache:writeLua(ScriptCache.generationIndexPath(GENERATION), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = MARKER,
    resources = { { id = SCRIPT_ID, member = 0, scriptIndex = 0 } },
  })
  cache:write(ScriptCache.scriptPath(GENERATION, 0, SCRIPT_ID), SCRIPT)
  return cache
end

local function recordingWrites(cache, failFirst)
  local writes = 0
  local originalWriteLua = cache.writeLua
  cache.writeLua = function(self, path, value)
    writes = writes + 1
    if failFirst and writes == 1 then
      return false
    end
    return originalWriteLua(self, path, value)
  end
  return function()
    return writes
  end
end

-- A generated cache whose index entries carry the published canonical hash
-- of each decoded resource.
local function hashIndexedCache()
  local cache = scriptCache()
  local resource = assert(ScriptLoader.loadGeneratedFrom(cache, GENERATION, 0, SCRIPT_ID, nil, { validate = false }))
  cache:writeLua(ScriptCache.generationIndexPath(GENERATION), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = MARKER,
    resources = {
      {
        id = SCRIPT_ID,
        member = 0,
        scriptIndex = 0,
        resourceHash = Sha256.hex(LuaWriter.encode(resource)),
      },
    },
  })
  return cache
end

-- Count generated body reads through the cache backend from here on.
local function countScriptReads(cache)
  local reads = 0
  local originalRead = cache.backend.read
  cache.backend.read = function(self, path)
    if path:find("/scripts/", 1, true) then
      reads = reads + 1
    end
    return originalRead(self, path)
  end
  return function()
    return reads
  end
end

T["fingerprint reads use no generated bodies and publish no snapshot"] = function()
  local cache = hashIndexedCache()
  local fs = overrideFs()
  local scriptReads = countScriptReads(cache)
  local writes = recordingWrites(cache)
  local compatibility = FieldScriptCompatibility.new({ cacheFs = cache, overrideFs = fs })
  ---@cast compatibility FieldScriptCompatibilityTestSurface

  local firstFingerprint = compatibility:registryFingerprint()
  local secondFingerprint = compatibility:registryFingerprint()
  local options = compatibility:validationOptions()

  Assert.equal(secondFingerprint, firstFingerprint)
  Assert.equal(options.expectedRegistryFingerprint, firstFingerprint)
  Assert.equal(scriptReads(), 0, "fingerprint acquisition must not decode generated bodies")
  Assert.equal(writes(), 0, "fingerprint acquisition must not publish snapshots")
end

T["first script use still decodes its own body"] = function()
  local cache = hashIndexedCache()
  local fs = overrideFs()
  local scriptReads = countScriptReads(cache)
  local compatibility = FieldScriptCompatibility.new({ cacheFs = cache, overrideFs = fs })
  ---@cast compatibility FieldScriptCompatibilityTestSurface
  compatibility:registryFingerprint()
  local before = scriptReads()
  Assert.notNil(compatibility.registry:base(SCRIPT_ID))
  Assert.equal(scriptReads() - before, 1, "first use decodes exactly its own body")
end

-- A hashless index is a stale cache: compatibility fails fast instead of
-- decoding the corpus or warming anything up. No fallback registry, no
-- empty-registry success, no snapshot machinery.
T["a hashless index fails fast as a stale cache"] = function()
  local cache = scriptCache()
  local fs = overrideFs()
  local scriptReads = countScriptReads(cache)
  local err = Assert.throws(function()
    FieldScriptCompatibility.new({ cacheFs = cache, overrideFs = fs })
  end)
  Assert.notNil(err, "a hashless cache must fail compatibility construction")
  Assert.equal(scriptReads(), 0, "a stale cache must not trigger corpus decoding")
end

-- Validation options carry the once-acquired fingerprint plus the live task
-- identity and resolvers, stable across repeated calls.
T["validation options carry the stable fingerprint and task identity"] = function()
  local cache = hashIndexedCache()
  local fs = overrideFs()
  local compatibility = FieldScriptCompatibility.new({ cacheFs = cache, overrideFs = fs })
  ---@cast compatibility FieldScriptCompatibilityTestSurface
  local firstOptions = compatibility:validationOptions()
  local secondOptions = compatibility:validationOptions()
  Assert.equal(firstOptions.expectedRegistryFingerprint, compatibility:registryFingerprint())
  Assert.equal(secondOptions.expectedRegistryFingerprint, firstOptions.expectedRegistryFingerprint)
  Assert.equal(secondOptions.expectedTaskFingerprint, firstOptions.expectedTaskFingerprint)
  Assert.isTrue(type(firstOptions.resolveTask) == "function", "task resolution stays available")
  Assert.isTrue(type(firstOptions.resolveComposition) == "function", "composition resolution stays available")
end

return { tests = T }
