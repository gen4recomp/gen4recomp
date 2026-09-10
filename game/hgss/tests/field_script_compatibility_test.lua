-- FieldScriptCompatibility tests: registry identity reads use the production
-- script composition while snapshot publication remains observable at the
-- injected cache boundary.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldScriptCompatibility = require("game.hgss.src.field.FieldScriptCompatibility")
local RegistrySnapshot = require("libs.script.src.RegistrySnapshot")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptLoader = require("libs.script.src.ScriptLoader")
local ScriptOverrides = require("libs.assets.src.ScriptOverrides")
local HgssScript = require("libs.hgss.src.script.Composition")

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

local function snapshotHit(cache, fs)
  local builtins = HgssScript.builtins()
  local registry = ScriptLoader.buildRegistry(cache, fs, nil, { builtins = builtins })
  local key = assert(RegistrySnapshot.key(cache, fs, builtins.contentHash))
  Assert.isTrue(cache:writeLua(RegistrySnapshot.FILE, {
    schema = RegistrySnapshot.SCHEMA,
    key = key,
    fingerprint = registry:fingerprint(),
  }))
end

T["a matching snapshot stays read-only during compatibility reads"] = function()
  local cache = scriptCache()
  local fs = overrideFs()
  snapshotHit(cache, fs)
  local writes = recordingWrites(cache)
  local compatibility = FieldScriptCompatibility.new({ cacheFs = cache, overrideFs = fs })
  ---@cast compatibility FieldScriptCompatibilityTestSurface
  Assert.isNil(compatibility.warmup, "a matching snapshot must use the fast path")

  local firstFingerprint = compatibility:registryFingerprint()
  local secondFingerprint = compatibility:registryFingerprint()
  local firstOptions = compatibility:validationOptions()
  local secondOptions = compatibility:validationOptions()

  Assert.equal(secondFingerprint, firstFingerprint)
  Assert.equal(firstOptions.expectedRegistryFingerprint, firstFingerprint)
  Assert.equal(secondOptions.expectedRegistryFingerprint, firstFingerprint)
  Assert.equal(secondOptions.expectedTaskFingerprint, firstOptions.expectedTaskFingerprint)
  Assert.equal(writes(), 0, "observational reads must not rewrite a matching snapshot")
end

T["a snapshot miss publishes once when a read finishes warm-up"] = function()
  local cache = scriptCache()
  local fs = overrideFs()
  local writes = recordingWrites(cache)
  local compatibility = FieldScriptCompatibility.new({ cacheFs = cache, overrideFs = fs })
  ---@cast compatibility FieldScriptCompatibilityTestSurface
  Assert.notNil(compatibility.warmup)
  Assert.isFalse(compatibility.warmup:isComplete())

  local fingerprint = compatibility:registryFingerprint()
  local options = compatibility:validationOptions()
  compatibility:registryFingerprint()
  compatibility:validationOptions()

  Assert.equal(options.expectedRegistryFingerprint, fingerprint)
  Assert.isTrue(compatibility.warmup:isComplete())
  Assert.equal(writes(), 1, "one completed warm-up must have one publisher")
end

T["a snapshot publication failure is raised without a compatibility retry"] = function()
  local cache = scriptCache()
  local fs = overrideFs()
  local writes = recordingWrites(cache, true)
  local compatibility = FieldScriptCompatibility.new({ cacheFs = cache, overrideFs = fs })
  ---@cast compatibility FieldScriptCompatibilityTestSurface

  local err = Assert.throws(function()
    compatibility:registryFingerprint()
  end)

  Assert.notNil(err)
  Assert.equal(writes(), 1, "a failed publication must not be retried by the accessor")
  Assert.isFalse(compatibility.warmup:isComplete(), "failed publication must not complete warm-up")
end

return { tests = T }
