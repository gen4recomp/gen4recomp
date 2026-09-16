-- Exhaustive proof that one generation's derived cache is usable. The audit
-- walks the complete canonical inventory for the exact current generation
-- and checks every expected job through the dispatcher's readiness
-- validation: a current-generation receipt plus a usable payload. Markers
-- alone prove nothing, expected membership is never inferred from whichever
-- directories happen to exist, and the full-build attestation is published
-- only after this audit passes, so it is never consulted here. Read-only:
-- the walk performs no writes.

local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local ArtifactState = require("romdump.src.build.ArtifactState")
local StorageErrors = require("libs.storage.src.errors")

local DerivedCacheAudit = {}

-- A receipt file that no longer parses is damaged data, not a storage
-- failure: the job is unavailable and eligible for repair. Genuine
-- backend read failures keep propagating instead of reading as absence.
local function isUnusableReceipt(failure)
  local message = tostring(failure)
  return message:find(StorageErrors.CACHE_LUA_PARSE_FAILED, 1, true) ~= nil
    or message:find(StorageErrors.CACHE_LUA_EVAL_FAILED, 1, true) ~= nil
end

---@param cacheFs CacheFs
---@param identity { versionId: string, generationId: string, producerId: string } current strict generation record
---@param plans ArtifactJobs.Plans complete published inventory for that exact identity
---@return boolean, string|nil
function DerivedCacheAudit.isAvailable(cacheFs, identity, plans)
  assert(cacheFs and cacheFs.read and cacheFs.loadLua, "DerivedCacheAudit requires a CacheFs-shaped object")
  assert(type(identity) == "table", "DerivedCacheAudit requires the current generation identity")
  local generationId = identity.generationId
  assert(type(generationId) == "string" and generationId ~= "", "DerivedCacheAudit requires a generation identity")
  assert(type(plans) == "table", "DerivedCacheAudit requires the complete source inventory")
  local jobsOk, jobs = pcall(ArtifactJobs.completeJobs, plans)
  if not jobsOk or type(jobs) ~= "table" then
    return false, "complete inventory is not available: " .. tostring(jobs)
  end
  ---@cast jobs { kind: string, key: string }[]
  for _, job in ipairs(jobs) do
    -- The receipt read names the failure precisely without duplicating
    -- family validation: a diagnosable storage failure propagates, a
    -- missing, stale, or corrupt receipt fails the job, and only a present
    -- receipt reaches the payload check.
    local receiptOk, receipt, receiptReason = pcall(ArtifactState.read, cacheFs, generationId, job.kind, job.key)
    if not receiptOk then
      if isUnusableReceipt(receipt) then
        return false, job.kind .. ":" .. job.key .. " has no usable receipt"
      end
      error(receipt, 0)
    end
    if receipt == nil then
      return false, job.kind .. ":" .. job.key .. " has no current receipt: " .. tostring(receiptReason)
    end
    if not ArtifactJobs.validate(cacheFs, generationId, job.kind, job.key, plans) then
      return false, job.kind .. ":" .. job.key .. " fails its family validator"
    end
  end
  return true
end

return DerivedCacheAudit
