-- Exhaustive preparation through the common generation session publishes a
-- complete attestation that passes the generation-aware audit: the published
-- corpus agrees with the plans it was computed from, every expected receipt
-- validates, and the reported census partitions without hardcoded totals.

local Assert = require("tests.support.Assert")
local CacheBuilder = require("romdump.src.CacheBuilder")
local CacheFs = require("libs.storage.src.CacheFs")
local DerivedCacheAudit = require("romdump.src.DerivedCacheAudit")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local ProducerFingerprint = require("romdump.src.ProducerFingerprint")

local T = {}

local function scopedPreparationAvailable()
  return type(CacheBuilder.prepareVersion) == "function"
end

function T.exhaustive_scope_publishes_a_complete_attestation_that_passes_audit(romFs, versionId)
  Assert.isTrue(scopedPreparationAvailable(), "exhaustive preparation must drive one common session per version")
  local metadata = romFs:metadata()
  local sha1 = assert(metadata.sha1, "the published dump carries the validated ROM hash")
  local identity = DerivedCacheState.currentForSelection({
    versionId = versionId,
    romSha1 = sha1,
    producerId = ProducerFingerprint.compute(ProducerFingerprint.appBackend()),
    developmentRepositoryRoot = love.filesystem.getSourceBaseDirectory(),
  })
  local lines = {}
  local report, err = CacheBuilder.prepareVersion(versionId, {
    identity = identity,
    requirements = { "complete" },
    log = function(line)
      lines[#lines + 1] = line
    end,
  })
  Assert.isNil(err)
  assert(report, "a successful preparation returns its report")
  Assert.isTrue(report.complete, "an exhaustive strict run reports a complete cache")
  Assert.isTrue(report.requestedReady, "the requested exhaustive scope is ready")
  Assert.deepEqual(report.exclusions, {}, "a strict run carries no accepted exclusions")
  Assert.deepEqual(report.failures, {}, "a strict run carries no failures")
  local counts = report.counts
  Assert.equal(
    counts.successful + counts.failed + counts.cancelled + counts.excluded,
    counts.planned,
    "every planned key lands in exactly one outcome category"
  )
  Assert.isTrue(counts.planned > 0, "the exhaustive census covers the real corpus")
  Assert.equal(counts.failed, 0, "a strict run has no failed jobs")
  local ok, reason = DerivedCacheAudit.isAvailable(CacheFs.forVersion(versionId))
  Assert.isTrue(ok, "the published corpus passes the generation-aware audit: " .. tostring(reason))
  local stored = CacheFs.forVersion(versionId):loadLua(DerivedCacheState.path)
  Assert.isTrue(
    DerivedCacheState.matches(stored, identity),
    "the published attestation matches the prepared generation"
  )
  Assert.isTrue(#lines > 0, "the exhaustive run reports its progress")
end

local suite = require("tests.rom.support.RomSuite").fromFacts(T)
return suite
