-- ROM-backed producer orchestration scenarios. These stay below the runtime
-- acceptance boundary because this suite owns cache publication and generated
-- producer output rather than a user-visible game journey.

local Assert = require("tests.support.Assert")
local CacheBuilder = require("romdump.src.CacheBuilder")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local Errors = require("libs.errors.src.Errors")
local FieldCameraCompiler = require("romdump.src.digest.field.FieldCameraCompiler")
local IntroAssetCompiler = require("romdump.src.digest.newgame.IntroAssetCompiler")
local RomFs = require("romdump.src.source.RomFs")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function payloadBytes(bundle)
  local paths = {}
  for path in pairs(bundle.assets) do
    paths[#paths + 1] = path
  end
  table.sort(paths)
  local bytes = {}
  for _, path in ipairs(paths) do
    bytes[#bytes + 1] = path .. "\0" .. bundle.assets[path]
  end
  return table.concat(bytes, "\0")
end

function T.cache_builder_failure_preserves_publication_state(romFs, versionId)
  local log = function() end
  local closed = false
  local statePublished = false
  local originalOpen = RomFs.open
  local originalMatches = DerivedCacheState.matches
  local originalPublish = DerivedCacheState.publish
  local originalCompile = FieldCameraCompiler.compile
  RomFs.open = function(...)
    local openedRomFs, openErr = originalOpen(...)
    if openedRomFs ~= nil then
      local originalClose = openedRomFs.close
      openedRomFs.close = function(self)
        closed = true
        return originalClose(self)
      end
    end
    return openedRomFs, openErr
  end
  local function forceMismatch()
    return false
  end
  local function recordPublish(...)
    statePublished = true
    return originalPublish(...)
  end
  local function failCamera()
    return nil, Errors.new("DUMP_FAILURE", "acceptance-injected camera failure")
  end
  rawset(DerivedCacheState, "matches", forceMismatch)
  rawset(DerivedCacheState, "publish", recordPublish)
  rawset(FieldCameraCompiler, "compile", failCamera)
  local ok, report, err = pcall(function()
    return CacheBuilder.buildVersions({ versionId }, { log = log })
  end)
  RomFs.open = originalOpen
  rawset(DerivedCacheState, "matches", originalMatches)
  rawset(DerivedCacheState, "publish", originalPublish)
  rawset(FieldCameraCompiler, "compile", originalCompile)

  Assert.isTrue(ok, tostring(report))
  Assert.isNil(report)
  Assert.equal(err, "cache preparation failed")
  Assert.isTrue(closed, "an expected source failure must close the borrowed RomFs")
  Assert.isFalse(statePublished, "a failed version must not publish its attestation")
  Assert.isTrue(romFs ~= nil, "RomSuite must keep the source handle available for later scenarios")
end

function T.intro_compiler_preserves_rasterized_bytes_and_manifest(romFs)
  local first = assert(IntroAssetCompiler.compile(romFs))
  local second = assert(IntroAssetCompiler.compile(romFs))
  Assert.deepEqual(first.manifest, second.manifest, "intro rasterization must preserve manifest geometry")
  Assert.deepEqual(first.dependencies, second.dependencies, "intro provenance must remain deterministic")
  Assert.equal(payloadBytes(first), payloadBytes(second), "intro rasterization must preserve generated PNG bytes")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.tags = { "producer", "cache" }
return suite
