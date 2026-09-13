-- Per-bank message staging, warm bank readiness, and family-summary
-- publication through the stage-only boundary, using small synthetic
-- encrypted members.

local Assert = require("tests.support.Assert")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
local FieldMessageCacheWriter = require("romdump.src.digest.ui.FieldMessageCacheWriter")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local FieldMessageTokenizer = require("romdump.src.digest.ui.FieldMessageTokenizer")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local GameVersion = require("romdump.src.source.GameVersion")
local Schema = require("libs.script.src.Schema")
local Sha256 = require("libs.script.src.Sha256")

local T = {}

local function fixture()
  local members = {
    [542] = FieldMessageBank.encodeForTests({
      { 0x0141, 0x0153, 0x015B, 0x01AD, 0x01DE, 0xFFFF },
      { 0x013A, 0x0156, 0x0153, 0xFFFF },
    }, 0x4F2F),
    [543] = FieldMessageBank.encodeForTests({
      { 0x012F, 0x0150, 0x0151, 0x01DE, 0xFFFF },
    }, 0xB447),
    [219] = FieldMessageBank.encodeForTests({
      { 0x012F, 0x0150, 0x0151, 0x01DE, 0xFFFF },
    }, 0xD219),
  }
  local romFs = {
    resolvedNarc = function(_, alias)
      Assert.equal(alias, "messages")
      return { symbol = "NARC_msgdata_msg", alias = "messages", narcId = 27, fileId = 77, path = "a/0/2/7" }
    end,
    read = function(_, fileId)
      Assert.equal(fileId, 77)
      return "archive-bytes"
    end,
    openNarc = function(_, alias)
      Assert.equal(alias, "messages")
      return {
        readMember = function(_, memberId)
          local member = members[memberId]
          assert(member ~= nil, "unexpected bank " .. tostring(memberId))
          return member
        end,
      }
    end,
    metadata = function()
      return { sha1 = "rom-sha" }
    end,
    version = function()
      return "heartgold"
    end,
  }
  ---@cast romFs RomFs
  return romFs
end

local HEARTGOLD_SHA1 = GameVersion.VERSIONS.heartgold.sha1

local function generationIdFor(producerBody)
  local identity = DerivedCacheState.current({
    versionId = "heartgold",
    romSha1 = HEARTGOLD_SHA1,
    mode = "development",
    producerId = "d" .. producerBody,
    assetRevision = DerivedAssetContract.revision,
    scriptApi = Schema.API_VERSION,
  })
  return assert(identity.generationId)
end

local function publishBank(cache, generation, bankId, bundle, stageName)
  local key = tostring(bankId)
  local artifact = PreparedArtifact.new({
    cacheFs = cache,
    generationId = generation,
    epoch = 1,
    kind = "message-bank",
    key = key,
    jobKey = "message-bank:" .. key,
    stageName = stageName,
  })
  FieldMessageCacheWriter.stageBank(artifact, bundle)
  artifact:finishSuccess({ marker = bundle.marker })
  artifact:publish({
    generationId = generation,
    epoch = 1,
    kind = "message-bank",
    key = key,
    jobKey = "message-bank:" .. key,
  })
end

-- A published bank proves ready without touching source decoding: with member
-- reads and tokenization trapped to fail, readiness still answers from the
-- staged files alone, while a stale marker does not read as ready.
function T.published_bank_readiness_needs_no_source_decode()
  Assert.equal(type(FieldMessageCompiler.newSession), "function", "per-bank production reuses one source session")
  Assert.equal(type(FieldMessageCacheWriter.stageBank), "function", "banks stage one at a time")
  Assert.equal(type(FieldMessageCache.isBankReady), "function", "bank readiness is separate from family readiness")
  local session = assert(FieldMessageCompiler.newSession(fixture()))
  local one = assert(session:compileBank(542))
  session:close()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local generation = generationIdFor(Sha256.hex("message bank stage"))
  local key = tostring(542)
  local artifact = PreparedArtifact.new({
    cacheFs = cache,
    generationId = generation,
    epoch = 1,
    kind = "message-bank",
    key = key,
    jobKey = "message-bank:" .. key,
    stageName = "message-bank-542",
  })
  FieldMessageCacheWriter.stageBank(artifact, one)
  local stage = artifact:stageFs()
  Assert.deepEqual(stage:loadLua(FieldMessageCache.bankPath(542)), one.bank, "the staged bank matches")
  Assert.equal(stage:read(FieldMessageCache.bankMarkerPath(542)), one.marker, "the marker stages with the bank")
  Assert.isFalse(stage:exists(FieldMessageCache.bankPath(543)), "no sibling bank is staged")
  artifact:finishSuccess({ marker = one.marker })
  artifact:publish({
    generationId = generation,
    epoch = 1,
    kind = "message-bank",
    key = key,
    jobKey = "message-bank:" .. key,
  })
  local decode = FieldMessageBank.decode
  local tokenize = FieldMessageTokenizer.tokenize
  FieldMessageBank.decode = function()
    error("warm readiness must not decode source members")
  end
  FieldMessageTokenizer.tokenize = function()
    error("warm readiness must not tokenize source members")
  end
  local readyOk, ready = pcall(FieldMessageCache.isBankReady, cache, 542, one.marker)
  local staleOk, stale = pcall(FieldMessageCache.isBankReady, cache, 542, one.marker .. "-stale")
  FieldMessageBank.decode = decode
  FieldMessageTokenizer.tokenize = tokenize
  Assert.isTrue(readyOk, "readiness polling must not fail: " .. tostring(ready))
  Assert.isTrue(ready, "a published bank stays ready without source decoding")
  Assert.isTrue(staleOk, "stale readiness polling must not fail: " .. tostring(stale))
  Assert.isFalse(stale, "a stale marker does not read as ready")
end

-- The family summary attests coverage without touching bank children: it
-- refuses incomplete coverage, leaves every published bank in place, and a
-- removed bank reads as incomplete even under an old summary.
function T.family_summary_attests_coverage_without_erasing_children()
  Assert.equal(type(FieldMessageCompiler.newSession), "function", "per-bank production reuses one source session")
  Assert.equal(type(FieldMessageCacheWriter.stageSummary), "function", "the family summary stages after its banks")
  local session = assert(FieldMessageCompiler.newSession(fixture()))
  local first = assert(session:compileBank(542))
  local second = assert(session:compileBank(543))
  session:close()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local generation = generationIdFor(Sha256.hex("message summary stage"))
  publishBank(cache, generation, 542, first, "message-bank-542")
  local index = {
    schema = FieldMessageCache.INDEX_SCHEMA,
    version = "heartgold",
    bankIds = { 542, 543 },
  }
  local bankMarkers = { [542] = first.marker, [543] = second.marker }
  local partial = PreparedArtifact.new({
    cacheFs = cache,
    generationId = generation,
    epoch = 1,
    kind = "message-bank",
    key = "global",
    jobKey = "message-bank:global",
    stageName = "message-summary-partial",
  })
  local ok, summaryErr = pcall(FieldMessageCacheWriter.stageSummary, partial, index, bankMarkers)
  Assert.isFalse(ok, "the summary must refuse incomplete coverage: " .. tostring(summaryErr))
  partial:abort()
  Assert.isFalse(
    FieldMessageCache.isReady(cache, "no-summary-published"),
    "an unpublished summary leaves the family incomplete"
  )
  publishBank(cache, generation, 543, second, "message-bank-543")
  local complete = PreparedArtifact.new({
    cacheFs = cache,
    generationId = generation,
    epoch = 1,
    kind = "message-bank",
    key = "global",
    jobKey = "message-bank:global",
    stageName = "message-summary",
  })
  local summaryMarker = FieldMessageCacheWriter.stageSummary(complete, index, bankMarkers)
  Assert.equal(type(summaryMarker), "string", "the summary stages its completion marker")
  complete:finishSuccess({ marker = summaryMarker })
  complete:publish({
    generationId = generation,
    epoch = 1,
    kind = "message-bank",
    key = "global",
    jobKey = "message-bank:global",
  })
  Assert.isTrue(FieldMessageCache.isReady(cache, summaryMarker), "full coverage publishes a ready family")
  for _, bankId in ipairs({ 542, 543 }) do
    local bank = cache:loadLua(FieldMessageCache.bankPath(bankId))
    Assert.equal(bank and bank.bankId, bankId, "bank " .. bankId .. " survives its summary")
  end
  cache:remove(FieldMessageCache.bankPath(543))
  Assert.isFalse(FieldMessageCache.isReady(cache, summaryMarker), "a missing bank is never hidden by an old summary")
end

-- The family marker is a deterministic function of its covered banks: the
-- same coverage always attests the same marker, so an unchanged family
-- reads as current without recompiling.
function T.family_marker_is_deterministic_for_its_coverage()
  local session = assert(FieldMessageCompiler.newSession(fixture()))
  local first = assert(session:compileBank(542))
  local second = assert(session:compileBank(543))
  session:close()
  local index = {
    schema = FieldMessageCache.INDEX_SCHEMA,
    version = "heartgold",
    bankIds = { 542, 543 },
  }
  local bankMarkers = { [542] = first.marker, [543] = second.marker }
  Assert.equal(
    FieldMessageCacheWriter.summaryMarker(index, bankMarkers),
    FieldMessageCacheWriter.summaryMarker(index, bankMarkers)
  )
end

return { tests = T }
