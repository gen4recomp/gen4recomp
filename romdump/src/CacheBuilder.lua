-- Owns per-version cache lifecycle, batch aggregation, and atomic publication.

local CacheFs = require("libs.storage.src.CacheFs")
local RomFs = require("romdump.src.source.RomFs")
local Errors = require("libs.errors.src.Errors")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local ProducerFingerprint = require("romdump.src.ProducerFingerprint")
local DerivedCacheAudit = require("romdump.src.DerivedCacheAudit")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local RawDumpContract = require("romdump.src.source.RawDumpContract")
local ScriptDsl = require("gen4.script")
local FieldCacheBuild = require("romdump.src.build.FieldCacheBuild")
local ScriptAudioCacheBuild = require("romdump.src.build.ScriptAudioCacheBuild")
local MapCacheBuild = require("romdump.src.build.MapCacheBuild")

local CacheBuilder = {}

---@class VersionBuildContext
---@field version string
---@field cacheFs CacheFs
---@field romFs RomFs
---@field forced boolean
---@field log fun(line: string)
---@field developmentRepositoryRoot string?
---@field producerFingerprint string

local function versionFailure(err)
  assert(Errors.is(err), "source-data stage failure must be a structured error")
  return nil, err
end

---@param version string
---@param cacheFs CacheFs
---@param romFs RomFs
---@param forced boolean
---@param log fun(line: string)
---@param developmentRepositoryRoot string?
---@param producerFingerprint string
---@return VersionBuildContext
local function buildContext(version, cacheFs, romFs, forced, log, developmentRepositoryRoot, producerFingerprint)
  return {
    version = version,
    cacheFs = cacheFs,
    romFs = romFs,
    forced = forced,
    log = log,
    developmentRepositoryRoot = developmentRepositoryRoot,
    producerFingerprint = producerFingerprint,
  }
end

---@param versionIds string[]
---@param options { allowCompileExclusions?: boolean, log?: fun(line: string), developmentRepositoryRoot?: string }|nil
---@return table<string, unknown>|nil report, string|nil err
function CacheBuilder.buildVersions(versionIds, options)
  options = options or {}
  local log = options.log or print
  if #versionIds == 0 then
    log("build: no ready version to compile")
    return nil, "no ready version to compile"
  end

  local producerFingerprint = ProducerFingerprint.compute(ProducerFingerprint.appBackend())
  local allOk, hasCompileExclusions, exclusionCount = true, false, 0
  local stagedWorlds, strictVersions = {}, {}
  local function discardStagedWorlds()
    for _, world in ipairs(stagedWorlds) do
      world:abort()
    end
  end

  for _, version in ipairs(versionIds) do
    local romFs
    local ok, result, failureErr = pcall(function()
      local cacheFs = CacheFs.forVersion(version)
      local dumpMarker = cacheFs:read(RawDumpContract.MARKER_PATH)
      assert(type(dumpMarker) == "string", "a ready version must have a published dump marker")
      local identity = DerivedCacheState.current({
        dump = dumpMarker,
        producer = producerFingerprint,
        assetContract = DerivedAssetContract,
        scriptApi = ScriptDsl.apiVersion,
      })
      local stored = cacheFs:loadLua(DerivedCacheState.path)
      local forced = false
      if DerivedCacheState.matches(stored, identity) then
        if DerivedCacheAudit.isAvailable(cacheFs) then
          log(string.format("build-cache: %s current", version))
          return true
        end
      else
        forced = true
      end
      DerivedCacheState.invalidate(cacheFs)
      local opened, openErr = RomFs.open(version)
      if not opened then
        return versionFailure(openErr)
      end
      romFs = opened
      local context =
        buildContext(version, cacheFs, romFs, forced, log, options.developmentRepositoryRoot, producerFingerprint)
      local _, stageErr = FieldCacheBuild.build(context)
      if stageErr then
        return versionFailure(stageErr)
      end
      local _, scriptErr = ScriptAudioCacheBuild.build(context)
      if scriptErr then
        return versionFailure(scriptErr)
      end
      local mapResult, mapErr = MapCacheBuild.build(context)
      if not mapResult then
        return versionFailure(mapErr)
      end
      stagedWorlds[#stagedWorlds + 1] = mapResult.world
      if mapResult.hasCompileExclusions then
        hasCompileExclusions = true
        exclusionCount = exclusionCount + mapResult.exclusionCount
      else
        strictVersions[#strictVersions + 1] = { cacheFs = cacheFs, identity = identity }
      end
      return true
    end)
    if romFs then
      romFs:close()
    end
    if not ok then
      discardStagedWorlds()
      error(result, 0)
    end
    if result == nil then
      allOk = false
      log("build-cache: " .. version .. " failed: " .. Errors.format(failureErr))
    end
  end

  if hasCompileExclusions and not options.allowCompileExclusions then
    log("build-cache: compile exclusions remain; rerun with --allow-compile-exclusions to accept them")
    allOk = false
  end
  if not allOk then
    discardStagedWorlds()
    return nil, "cache preparation failed"
  end
  for _, world in ipairs(stagedWorlds) do
    world:publish()
    log("build-cache: " .. world.version .. " world.lua published")
  end
  for _, strict in ipairs(strictVersions) do
    DerivedCacheState.publish(strict.cacheFs, strict.identity)
  end
  return { published = true, complete = not hasCompileExclusions, exclusionCount = exclusionCount }
end

return CacheBuilder
