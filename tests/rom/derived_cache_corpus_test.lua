-- Read-only conformance over the prepared complete corpus: the current
-- development preparation proves the whole inventory through the
-- generation-aware audit, every expected receipt validates, and the
-- published attestation matches the prepared generation. Nothing is compiled
-- or published here; the command tests own publication and failure evidence.

local Assert = require("tests.support.Assert")
local ArtifactState = require("romdump.src.build.ArtifactState")
local CacheFs = require("libs.storage.src.CacheFs")
local DerivedCacheAudit = require("romdump.src.DerivedCacheAudit")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local ProducerFingerprint = require("romdump.src.ProducerFingerprint")

local T = {}

function T.prepared_complete_corpus_passes_audit_with_matching_attestation(romFs, versionId)
  local sha1 = assert(romFs:metadata().sha1, "the published dump carries the validated ROM hash")
  local sourceBase = love.filesystem.getSourceBaseDirectory()
  local identity = DerivedCacheState.currentForSelection({
    versionId = versionId,
    romSha1 = sha1,
    producerId = ProducerFingerprint.compute(ProducerFingerprint.checkoutBackend(sourceBase)),
    developmentRepositoryRoot = sourceBase,
  })
  local generationId = assert(identity.generationId, "the selection identity carries its generation")
  local cacheFs = CacheFs.forVersion(versionId)
  local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
  local plans, plansReason = ArtifactJobs.publishedPlans(cacheFs, identity)
  assert(plans ~= nil, "the prepared corpus publishes its inventory: " .. tostring(plansReason))
  local completeJobs = ArtifactJobs.completeJobs(plans)
  Assert.isTrue(#completeJobs > 0, "the exhaustive inventory covers the real corpus")
  local missing = {}
  for _, job in ipairs(completeJobs) do
    if ArtifactState.read(cacheFs, generationId, job.kind, job.key) == nil then
      missing[#missing + 1] = job.jobKey
    end
  end
  Assert.equal(#missing, 0, "every expected receipt validates: missing " .. table.concat(missing, ", "))
  local ok, reason = DerivedCacheAudit.isAvailable(cacheFs, identity, plans)
  Assert.isTrue(ok, "the prepared corpus passes the generation-aware audit: " .. tostring(reason))
  local stored = cacheFs:loadLua(DerivedCacheState.path)
  Assert.isTrue(
    DerivedCacheState.matches(stored, identity),
    "the published attestation matches the prepared generation"
  )
end

local suite = require("tests.rom.support.RomSuite").fromFacts(T)
-- Read-only corpus check: the suite consumes the proven complete
-- preparation instead of publishing one.
suite.metadata.capabilities = { "rom_dump", "complete_derived_cache" }
suite.metadata.derivedAssets = { "complete" }
return suite
