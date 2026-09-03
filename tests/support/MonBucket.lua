-- Empty mons buckets fingerprinted against the warmed version cache.
-- Production-composition tests boot the real field runtime, whose live mon
-- service validates its bucket against the generated catalog; fakes build
-- the required bucket through this helper instead of synthesizing one.

local CacheFs = require("libs.storage.src.CacheFs")
local MonCache = require("libs.assets.src.MonCache")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonsSave = require("libs.mons.src.MonsSave")

local MonBucket = {}

---@param versionId string
---@param seedU32 integer?
---@return table
function MonBucket.emptyForVersion(versionId, seedU32)
  local cacheFs = CacheFs.forVersion(versionId)
  local catalog = MonCatalog.new(MonCache.loadCatalog(cacheFs))
  return MonsSave.empty(catalog:fingerprint(), seedU32 or 7)
end

return MonBucket
