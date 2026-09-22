-- Seeded script-hash save compatibility against the real published corpus:
-- the fingerprint computed from published hashes equals the fingerprint
-- computed by loading every generated body, a save envelope carrying that
-- fingerprint validates strictly, a tampered fingerprint is rejected, and
-- fingerprint acquisition reads no generated bodies.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldScriptCompatibility = require("game.hgss.src.field.FieldScriptCompatibility")
local HgssScript = require("libs.hgss.src.script.Composition")
local Registry = require("libs.script.src.Registry")
local ScriptLoader = require("libs.script.src.ScriptLoader")
local ScriptOverrides = require("libs.assets.src.ScriptOverrides")
local ScriptSave = require("libs.script.src.ScriptSave")

local T = {}

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

local function builtins()
  return HgssScript.builtins()
end

-- The pre-change algorithm: every generated body loaded and hashed, no
-- published hash consulted. Mirrors the loader's layer composition exactly
-- except hash seeding, so any divergence names a compatibility break.
local function oracleFingerprint(cacheFs, fs, selection)
  local registry = Registry.new()
  for id, script in pairs(builtins().all()) do
    registry:installBuiltin(id, script)
  end
  ScriptLoader.installGenerated(registry, cacheFs, nil, { lazy = false, selection = selection })
  ScriptLoader.installOverrides(registry, fs, nil)
  registry:seal()
  return registry:fingerprint()
end

local function countBodyReads(cacheFs)
  local reads = 0
  local backend = assert(cacheFs.backend, "the cache exposes its backend")
  local originalRead = assert(backend.read, "the backend reads by path")
  backend.read = function(self, path)
    if type(path) == "string" and path:find("/scripts/", 1, true) ~= nil and path:sub(-4) == ".lua" then
      reads = reads + 1
    end
    return originalRead(self, path)
  end
  return function()
    backend.read = originalRead
    return reads
  end
end

local function saveBucket(fingerprint, taskFingerprint)
  return {
    schema = ScriptSave.SCHEMA_NAME,
    registryFingerprint = fingerprint,
    taskFingerprint = taskFingerprint,
    capturedAtSimulationTick = 0,
    nextEnvironmentId = 0,
    nextInstanceId = 0,
    nextTaskId = 0,
    environments = {},
    instances = {},
    tasks = {},
  }
end

function T.published_hashes_reproduce_the_body_loaded_fingerprint_without_body_reads(_, versionId)
  local cacheFs = CacheFs.forVersion(versionId)
  local fs = overrideFs()
  local _, selection = ScriptLoader.buildRegistry(cacheFs, fs, nil, { lazy = true, builtins = builtins() })
  local oracle = oracleFingerprint(cacheFs, fs, selection)
  local finishBodyReads = countBodyReads(cacheFs)
  local compatibility = FieldScriptCompatibility.new({ cacheFs = cacheFs, overrideFs = fs })
  local fingerprint = compatibility:registryFingerprint()
  local bodyReads = finishBodyReads()
  Assert.equal(fingerprint, oracle, "seeded hashes reproduce the body-loaded registry fingerprint")
  Assert.equal(bodyReads, 0, "fingerprint acquisition reads no generated bodies")
  Assert.isTrue(#fingerprint > 0, "the reproduced fingerprint is non-empty")
end

function T.save_envelope_with_the_published_fingerprint_validates_strictly(_, versionId)
  local cacheFs = CacheFs.forVersion(versionId)
  local fs = overrideFs()
  local compatibility = FieldScriptCompatibility.new({ cacheFs = cacheFs, overrideFs = fs })
  local options = compatibility:validationOptions()
  local bucket = saveBucket(compatibility:registryFingerprint(), options.expectedTaskFingerprint)
  Assert.isNil(ScriptSave.validate(bucket, options), "a save carrying the published fingerprint validates")
  local tampered = saveBucket(compatibility:registryFingerprint() .. "0", options.expectedTaskFingerprint)
  local err = assert(ScriptSave.validate(tampered, options), "a tampered registry fingerprint is rejected")
  Assert.equal(err.code, "SCRIPT_REGISTRY_FINGERPRINT_MISMATCH", "rejection names the fingerprint mismatch")
end

local suite = require("tests.rom.support.RomSuite").fromFacts(T)
-- Reads the runner-prepared complete scope (which publishes the complete
-- script corpus with canonical sidecars) read-only; the oracle loads bodies
-- through the same cache without writing.
suite.metadata.capabilities = { "rom_dump", "derived_cache" }
suite.metadata.derivedAssets = {}
suite.metadata.tags = { "script", "save", "compatibility" }
return suite
