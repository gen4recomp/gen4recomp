-- ROM-backed worker evidence: two supported maps must cross the production
-- compiler boundary and become independently ready published map roots.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function requirePool()
  local ok, pool = pcall(require, "romdump.src.build.CompilerPool")
  Assert.isTrue(ok, "the production compiler-pool boundary is missing")
  return pool
end

function T.independent_map_jobs_use_distinct_workers(romFs, versionId)
  local CompilerPool = requirePool()
  local pool = CompilerPool.new({
    versionId = versionId,
    mode = "batch",
  })

  local jobs = {
    { key = "map:60", mapId = 60 },
    { key = "map:61", mapId = 61 },
  }
  for _, job in ipairs(jobs) do
    pool:request({
      kind = "map",
      key = job.key,
      priority = 0,
      payload = { mapId = job.mapId },
    })
  end
  pool:drain()

  local workerIds = {}
  local cache = CacheFs.forVersion(versionId)
  for _, job in ipairs(jobs) do
    local state, details = pool:status(job.key)
    Assert.equal(state, "ready")
    local workerId = assert(details and details.workerId, "ready result reports its worker")
    workerIds[#workerIds + 1] = workerId

    local marker =
      assert(cache:read(MapAssetCache.mapDir(job.mapId) .. "/complete"), "published map has a completion marker")
    Assert.isTrue(MapAssetCache.isReady(cache, job.mapId, marker), "published map is semantically ready")
    local scene = assert(cache:loadLua(MapAssetCache.mapDir(job.mapId) .. "/scene.lua"))
    Assert.equal(scene.mapId, job.mapId, "published scene retains its requested map identity")
  end
  Assert.isTrue(workerIds[1] ~= workerIds[2], "independent maps use distinct workers when available")
  pool:shutdown()
  Assert.isTrue(romFs ~= nil, "the ROM suite keeps the source handle alive")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump", "derived_cache" }
suite.metadata.tags = { "producer", "cache", "parallel" }
return suite
