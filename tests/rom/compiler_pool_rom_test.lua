-- ROM-backed worker evidence: two supported maps must cross the production
-- compiler boundary and become independently ready published map roots.

local Assert = require("tests.support.Assert")
local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local CacheFs = require("libs.storage.src.CacheFs")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local DerivedCacheVersions = require("romdump.src.config.DerivedCacheVersions")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function requirePool()
  local ok, pool = pcall(require, "romdump.src.build.CompilerPool")
  Assert.isTrue(ok, "the production compiler-pool boundary is missing")
  return pool
end

function T.independent_map_jobs_serialize_on_the_exclusive_jumbo_worker(romFs, versionId)
  local CompilerPool = requirePool()
  -- Jobs cross the pool boundary under an explicit generation: select it
  -- first and tag every job, exactly as the production session does.
  local sha1 = assert(romFs:metadata().sha1, "dump has no SHA-1 identity")
  -- The runner prepares the declared map scope under the release identity,
  -- so the jobs below use the same release generation to consume the
  -- prepared cells (mirrors App.opts.dev=false in the acceptance layer).
  local producerId = "r" .. tostring(assert(DerivedCacheVersions[versionId], "release counter is required"))
  local identity = DerivedCacheState.currentForSelection({
    versionId = versionId,
    romSha1 = sha1,
    producerId = producerId,
  })
  local generationId = assert(identity.generationId, "generation identity is required")
  local pool = CompilerPool.new({
    versionId = versionId,
    mode = "batch",
  })
  pool:selectGeneration(identity, 1)

  local jobs = {
    { key = "60", mapId = 60 },
    { key = "61", mapId = 61 },
  }
  for _, job in ipairs(jobs) do
    pool:request({
      versionId = versionId,
      generationId = generationId,
      epoch = 1,
      kind = "map",
      key = job.key,
      jobKey = "map:" .. job.key,
      priority = 0,
      sizeClass = ArtifactJobs.sizeClass("map"),
      payload = { mapId = job.mapId, producerFingerprint = producerId },
    })
  end
  pool:drain()

  local workerIds = {}
  local cache = CacheFs.forVersion(versionId)
  for _, job in ipairs(jobs) do
    local state, details = pool:status("map:" .. job.key)
    Assert.equal(state, "ready", "map " .. job.key .. " completes: " .. tostring(details and details.error))
    local workerId = assert(details and details.workerId, "ready result reports its worker")
    workerIds[#workerIds + 1] = workerId

    local marker =
      assert(cache:read(MapAssetCache.mapDir(job.mapId) .. "/complete"), "published map has a completion marker")
    Assert.isTrue(MapAssetCache.isReady(cache, job.mapId, marker), "published map is semantically ready")
    local scene = assert(cache:loadLua(MapAssetCache.mapDir(job.mapId) .. "/scene.lua"))
    Assert.equal(scene.mapId, job.mapId, "published scene retains its requested map identity")
  end
  -- Maps are jumbo jobs: admission serializes them onto the single
  -- exclusive worker (CompilerPool._idleWorkerFor pins jumbos to
  -- workers[1]), so independence here means separate jobs, separate
  -- published roots, and sequential completion -- never parallel placement.
  Assert.equal(workerIds[1], 1, "the first map runs on the exclusive jumbo worker")
  Assert.equal(workerIds[2], 1, "the second map follows sequentially on the exclusive jumbo worker")
  pool:shutdown()
  Assert.isTrue(romFs ~= nil, "the ROM suite keeps the source handle alive")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump", "derived_cache" }
suite.metadata.derivedAssets = { "map:60", "map:61" }
suite.metadata.tags = { "producer", "cache", "parallel" }
return suite
