-- Persists the derived audio class through the shared staged publication
-- primitive: the provenance record, the index, one file per indexed sequence
-- and bank, and unique content-addressed sample payloads with their metadata
-- are written into a disposable staging root, readback-validated there by the
-- one authoritative cross-file walk (AudioCacheValidator, the same rule
-- AudioCache.isReady runs), and only then is the completed stage published
-- with the marker last. Staging and validation are one step; publication
-- happens outside that step's error handler, so a publish failure never
-- triggers writer-level stage cleanup that could delete the last remaining
-- copy of the previous artifact.
--
-- Bank closures stage independently through the same core: one bank file,
-- its sequence files, its completion record, and the immutable
-- content-addressed samples it references. Shared sample paths deduplicate
-- at controller publication; the catalog owns only the runtime index and
-- its catalog completion, and the family summary owns only the
-- provenance/completion files and refuses while any planned closure is
-- unpublished or the live catalog index differs from the current plan, so
-- neither ever deletes bank children and the index has exactly one owner.

local Errors = require("libs.errors.src.Errors")
local AudioCache = require("libs.assets.src.audio.AudioCache")
local AudioCacheValidator = require("libs.assets.src.audio.AudioCacheValidator")
local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
local AudioErrors = require("libs.assets.src.audio.AudioErrors")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local Hashing = require("romdump.src.digest.Hashing")

local AudioCacheWriter = {}

function AudioCacheWriter.isReady(cacheFs, marker)
  return AudioCache.isReady(cacheFs, marker)
end

---@param message string
---@param context Errors.Context?
---@noreturn
local function raiseReadback(message, context)
  Errors.raise(AudioErrors.AUDIO_CACHE_READBACK_FAILED, message, context)
end

---@param bankPlan unknown
---@return { bankId: integer, sequenceIds: integer[] }
local function checkBankPlan(bankPlan)
  assert(type(bankPlan) == "table", "bank staging requires a bank closure plan")
  ---@cast bankPlan { bankId: integer, sequenceIds: integer[] }
  assert(
    type(bankPlan.bankId) == "number" and bankPlan.bankId % 1 == 0 and bankPlan.bankId >= 0,
    "a bank closure plan carries an invalid bankId"
  )
  assert(type(bankPlan.sequenceIds) == "table", "a bank closure plan carries no sequence selection")
  return bankPlan
end

---@param plan unknown
---@return { index: table<string, unknown>, bankPlans: table<integer, { bankId: integer, sequenceIds: integer[] }> }
local function checkCatalogPlan(plan)
  assert(type(plan) == "table", "audio staging requires the catalog plan")
  ---@cast plan { index: table<string, unknown>, bankPlans: table<integer, { bankId: integer, sequenceIds: integer[] }> }
  assert(type(plan.index) == "table", "audio staging requires the family index")
  assert(type(plan.bankPlans) == "table", "audio staging requires the bank closure plans")
  for position, bankPlan in ipairs(plan.bankPlans) do
    assert(type(bankPlan) == "table", "audio staging requires a bank closure plan at position " .. position)
    checkBankPlan(bankPlan)
  end
  return plan
end

---@param soundIdentity unknown
---@return { romSha1: string, sdatSha1: string, sdatFileId: integer }
local function checkSoundIdentity(soundIdentity)
  assert(type(soundIdentity) == "table", "catalog staging requires the sound source identity")
  ---@cast soundIdentity { romSha1: string, sdatSha1: string, sdatFileId: integer }
  assert(
    type(soundIdentity.romSha1) == "string" and soundIdentity.romSha1 ~= "",
    "catalog staging requires the ROM identity"
  )
  assert(
    type(soundIdentity.sdatSha1) == "string" and soundIdentity.sdatSha1 ~= "",
    "catalog staging requires the archive identity"
  )
  assert(
    type(soundIdentity.sdatFileId) == "number" and soundIdentity.sdatFileId % 1 == 0,
    "catalog staging requires the archive file identity"
  )
  return soundIdentity
end

---@param sequences table<integer, table<string, unknown>>
---@return integer[]
local function ascendingSequenceIds(sequences)
  local ids = {}
  for id in pairs(sequences) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  return ids
end

-- The one bank staging step every bank entry point shares: the bank record,
-- its sequence records, and the closure completion record land in the given
-- stage filesystem. Sample payloads and their metadata are either already
-- staged (the prepared sink streams them during compilation) or carried in
-- the bundle (the batch spelling collects one bank). Readback replays the
-- closure scope readiness runs, so a staged closure always proves its bank,
-- sequences, and referenced samples before anything publishes.
---@param stage CacheFs
---@param compiled AudioCompiler.BankBundle
---@return string
local function persistBank(stage, compiled)
  assert(type(compiled.bankId) == "number", "bank staging requires the closure bank identity")
  assert(type(compiled.bank) == "table", "bank staging requires the bank record")
  assert(type(compiled.sequences) == "table", "bank staging requires the closure sequences")
  assert(type(compiled.marker) == "string" and compiled.marker ~= "", "bank staging requires the closure marker")
  assert(type(compiled.dependencies) == "table", "bank staging requires the closure dependencies")
  if compiled.samples ~= nil then
    assert(type(compiled.sampleMetadata) == "table", "bank staging requires sample metadata for its samples")
    for key, pcm in pairs(compiled.samples) do
      local metadata = compiled.sampleMetadata[key]
      assert(metadata ~= nil, "bank staging is missing sample metadata for " .. tostring(key))
      stage:write(AudioCache.samplePath(key), pcm)
      stage:writeLua(AudioCache.sampleMetadataPath(key), metadata)
    end
  end
  stage:writeLua(AudioCache.bankPath(compiled.bankId), compiled.bank)
  for id, sequence in pairs(compiled.sequences) do
    stage:writeLua(AudioCache.sequencePath(id), sequence)
  end
  stage:writeLua(AudioCache.bankCompletePath(compiled.bankId), {
    schema = AudioCache.BANK_COMPLETION_SCHEMA,
    bankId = compiled.bankId,
    sequenceIds = ascendingSequenceIds(compiled.sequences),
    marker = compiled.marker,
    dependencies = compiled.dependencies,
  })
  local completion = stage:loadLua(AudioCache.bankCompletePath(compiled.bankId))
  if type(completion) ~= "table" or completion.marker ~= compiled.marker then
    raiseReadback("bank " .. tostring(compiled.bankId) .. " completion readback failed", { bankId = compiled.bankId })
  end
  assert(type(completion) == "table", "unreachable: completion readback validated above")
  local sequenceIds = completion.sequenceIds ---@type integer[]
  local problem = AudioCacheValidator.validateBankClosure(stage, compiled.bankId, sequenceIds)
  if problem ~= nil then
    raiseReadback(problem, { bankId = compiled.bankId })
  end
  return compiled.marker
end

-- Stage one bank closure through a caller-owned prepared artifact: the stage
-- owns exactly this bank's file, its sequence files, and its completion
-- record, while the referenced sample payloads travel as immutable shared
-- files, so per-bank jobs never overlap and identical bytes deduplicate at
-- publication. Publication stays with the caller; a stage failure leaves the
-- previous live record untouched once the caller aborts the disposable stage.
---@param source RomFs|AudioCompiler.Session the adopted source reader or the retained worker-generation session
---@param artifact PreparedArtifact
---@param bankPlan AudioCompiler.BankPlan
---@return string
function AudioCacheWriter.stageBank(artifact, source, bankPlan)
  assert(artifact and artifact.stageFs and artifact.cacheFs, "bank staging requires a PreparedArtifact")
  local ownedPlan = checkBankPlan(bankPlan)
  local stage = artifact:stageFs()
  artifact:addOwnedRoot(AudioCache.bankPath(ownedPlan.bankId))
  for _, sequenceId in ipairs(ownedPlan.sequenceIds) do
    artifact:addOwnedRoot(AudioCache.sequencePath(sequenceId))
  end
  artifact:addOwnedRoot(AudioCache.bankCompletePath(ownedPlan.bankId))
  -- The fixed stage-owned sink: every streamed sample lands in the private
  -- stage synchronously and the job retains no caller buffer. A repeated
  -- semantic key restages its identical bytes; shared paths deduplicate at
  -- publication.
  local function sampleSink(key, metadata, pcm)
    stage:write(AudioCache.samplePath(key), pcm)
    stage:writeLua(AudioCache.sampleMetadataPath(key), metadata)
    artifact:addSharedFile(AudioCache.samplePath(key))
    artifact:addSharedFile(AudioCache.sampleMetadataPath(key))
  end
  -- A retained session compiles against its one archive acquisition; a
  -- source reader takes the one-shot path. Both stage identical bytes.
  local bundle, err
  if type(source) == "table" and type(source.compileBank) == "function" then
    local session = source --[[@as AudioCompiler.Session]]
    bundle, err = session:compileBank(ownedPlan, sampleSink)
  else
    bundle, err = AudioCompiler.compileBank(source, ownedPlan, sampleSink)
  end
  if bundle == nil then
    error(assert(err), 0)
  end
  return persistBank(stage, bundle)
end

-- Stage one bank closure straight into the live cache for the batch build:
-- the closure compiles into job-local memory (one bank only, discarded after
-- staging) and publishes through a transaction owning exactly its files. A
-- compilation failure returns its structured error for the per-version
-- report; a staging failure raises like every other writer boundary.
---@param cacheFs CacheFs
---@param romFs RomFs
---@param bankPlan AudioCompiler.BankPlan
---@return string?|nil
---@return Errors.Error?|nil
function AudioCacheWriter.writeBank(cacheFs, romFs, bankPlan)
  local ownedPlan = checkBankPlan(bankPlan)
  local identity, identityErr = AudioCompiler.soundIdentity(romFs)
  if identity == nil then
    return nil, assert(identityErr) --[[@as Errors.Error]]
  end
  -- The standalone caller owns a bounded one-shot session at its existing
  -- lifetime boundary: one acquisition serves the single closure.
  local session, sessionErr = AudioCompiler.openSession(romFs, identity)
  if session == nil then
    return nil, assert(sessionErr) --[[@as Errors.Error]]
  end
  local collected = {}
  local collectedMetadata = {}
  local bundle, err = session:compileBank(ownedPlan, function(key, metadata, pcm)
    if collected[key] == nil then
      collected[key] = pcm
      collectedMetadata[key] = metadata
    end
  end)
  session:close()
  if bundle == nil then
    return nil, assert(err) --[[@as Errors.Error]]
  end
  bundle.samples = collected
  bundle.sampleMetadata = collectedMetadata
  local roots = {
    AudioCache.bankPath(ownedPlan.bankId),
  }
  for _, sequenceId in ipairs(ownedPlan.sequenceIds) do
    roots[#roots + 1] = AudioCache.sequencePath(sequenceId)
  end
  for key in pairs(collected) do
    roots[#roots + 1] = AudioCache.samplePath(key)
    roots[#roots + 1] = AudioCache.sampleMetadataPath(key)
  end
  -- The completion record moves last, so a crash can never leave the new
  -- closure marker visible without its full closure.
  roots[#roots + 1] = AudioCache.bankCompletePath(ownedPlan.bankId)
  local tx = ArtifactPublisher.begin(cacheFs, "audio-bank-" .. ownedPlan.bankId, roots)
  local ok, result = pcall(persistBank, tx.stage, bundle)
  if not ok then
    tx:abort()
    error(result, 0)
  end
  tx:publish()
  return result
end

-- The deterministic completion marker for one covered family: the bank
-- markers already bind each closure's source identity, so the summary binds
-- the index selection to those markers. The ROM identity is carried by the
-- bank markers themselves.
---@param plan { index: table<string, unknown>, bankPlans: table<integer, { bankId: integer, sequenceIds: integer[] }> }
---@param bankMarkers table<integer, string>
---@return string
function AudioCacheWriter.summaryMarker(plan, bankMarkers)
  assert(type(plan.index) == "table", "summary staging requires the family index")
  assert(type(plan.bankPlans) == "table", "summary staging requires the bank closure plans")
  assert(type(bankMarkers) == "table", "summary staging requires one marker per bank")
  local entries = {}
  for _, bankPlan in ipairs(plan.bankPlans) do
    local marker = bankMarkers[bankPlan.bankId]
    assert(
      type(marker) == "string" and marker ~= "",
      "family summary is missing the marker for bank " .. tostring(bankPlan.bankId)
    )
    entries[#entries + 1] = bankPlan.bankId .. "=" .. marker
  end
  assert(#entries > 0, "family summary requires at least one bank closure")
  local firstMarker = bankMarkers[plan.bankPlans[1].bankId]
  local romSha1 = firstMarker:match("^[^:]+:([^:]+):.+$")
  assert(type(romSha1) == "string", "bank markers carry no ROM identity")
  return AudioCache.marker(romSha1, Hashing.hashLua({ index = plan.index, banks = entries }))
end

-- The deterministic catalog completion marker: the sound source identity
-- plus the normalized runtime index content. Equal indexes over equal
-- source repair to the same marker; the ROM identity rides the marker
-- prefix through AudioCache.marker.
---@param plan { index: table<string, unknown>, bankPlans: table<integer, { bankId: integer, sequenceIds: integer[] }> }
---@param soundIdentity { romSha1: string, sdatSha1: string, sdatFileId: integer }
---@return string
function AudioCacheWriter.catalogMarker(plan, soundIdentity)
  assert(type(plan.index) == "table", "catalog staging requires the family index")
  local identity = checkSoundIdentity(soundIdentity)
  return AudioCache.marker(
    identity.romSha1,
    Hashing.hashLua({
      cacheFormat = AudioCache.FORMAT,
      versionRomSha1 = identity.romSha1,
      soundArchive = { fileId = identity.sdatFileId, sha1 = identity.sdatSha1 },
      index = plan.index,
    })
  )
end

-- The one catalog staging step every catalog entry point shares: the
-- runtime index and the catalog completion land in the stage, readback
-- replays catalog readiness there, and only then does the caller publish.
-- No bank, sequence, or sample payload is staged here.
---@param stage CacheFs
---@param plan { index: table<string, unknown>, bankPlans: table<integer, { bankId: integer, sequenceIds: integer[] }> }
---@param soundIdentity { romSha1: string, sdatSha1: string, sdatFileId: integer }
---@return string
local function persistCatalog(stage, plan, soundIdentity)
  local marker = AudioCacheWriter.catalogMarker(plan, soundIdentity)
  stage:writeLua(AudioCache.indexPath(), plan.index)
  stage:write(AudioCache.catalogMarkerPath(), marker)
  local stagedIndex = stage:loadLua(AudioCache.indexPath())
  local problem = AudioCacheValidator.validateCatalog(stagedIndex)
  if problem ~= nil then
    raiseReadback(problem, {})
  end
  if stage:read(AudioCache.catalogMarkerPath()) ~= marker then
    raiseReadback("audio catalog marker readback failed", {})
  end
  return marker
end

-- Stage the runtime catalog through a caller-owned prepared artifact: the
-- stage owns exactly the index and the catalog completion, never bank
-- closures. Publication stays with the caller.
---@param artifact PreparedArtifact
---@param plan { index: table<string, unknown>, bankPlans: table<integer, { bankId: integer, sequenceIds: integer[] }> }
---@param soundIdentity { romSha1: string, sdatSha1: string, sdatFileId: integer }
---@return string
function AudioCacheWriter.stageCatalog(artifact, plan, soundIdentity)
  assert(artifact and artifact.stageFs and artifact.cacheFs, "catalog staging requires a PreparedArtifact")
  local owned = checkCatalogPlan(plan)
  local identity = checkSoundIdentity(soundIdentity)
  artifact:addOwnedRoot(AudioCache.indexPath())
  artifact:addOwnedRoot(AudioCache.catalogMarkerPath())
  return persistCatalog(artifact:stageFs(), owned, identity)
end

-- Publish the runtime catalog straight into the live cache for the batch
-- build. Raises like every other writer boundary.
---@param cacheFs CacheFs
---@param plan { index: table<string, unknown>, bankPlans: table<integer, { bankId: integer, sequenceIds: integer[] }> }
---@param soundIdentity { romSha1: string, sdatSha1: string, sdatFileId: integer }
---@return string
function AudioCacheWriter.writeCatalog(cacheFs, plan, soundIdentity)
  local owned = checkCatalogPlan(plan)
  local identity = checkSoundIdentity(soundIdentity)
  local tx = ArtifactPublisher.begin(cacheFs, "audio-catalog", {
    AudioCache.indexPath(),
    AudioCache.catalogMarkerPath(),
  })
  local ok, result = pcall(persistCatalog, tx.stage, owned, identity)
  if not ok then
    tx:abort()
    error(result, 0)
  end
  tx:publish()
  return result
end

-- The one summary staging step every summary entry point shares: every
-- planned closure must be current in the live cache under its completion
-- marker with its closure revalidated, the live catalog index must match
-- the current plan, and then only the provenance and the completion marker
-- land in the stage. Bank children and the catalog-owned index are never
-- staged here, so the summary cannot erase them. The live index then faces
-- the authoritative complete walk against the on-disk closures without
-- assembling a second PCM bundle.
---@param stage CacheFs
---@param liveFs CacheFs
---@param plan { index: table<string, unknown>, bankPlans: table<integer, { bankId: integer, sequenceIds: integer[] }> }
---@return string
local function persistSummary(stage, liveFs, plan)
  if #plan.bankPlans == 0 then
    Errors.raise("AUDIO_SUMMARY_INCOMPLETE", "family summary refuses a plan with no bank closures", {
      missingBankIds = {},
    })
  end
  local bankMarkers = {}
  local missing = {}
  local provenanceDependencies = nil
  for _, bankPlan in ipairs(plan.bankPlans) do
    local completion = liveFs:loadLua(AudioCache.bankCompletePath(bankPlan.bankId))
    if
      type(completion) ~= "table"
      or type(completion.marker) ~= "string"
      or type(completion.sequenceIds) ~= "table"
    then
      missing[#missing + 1] = bankPlan.bankId
      goto continue
    end
    local sequenceIds = completion.sequenceIds ---@type integer[]
    if AudioCacheValidator.validateBankClosure(liveFs, bankPlan.bankId, sequenceIds) ~= nil then
      missing[#missing + 1] = bankPlan.bankId
    else
      bankMarkers[bankPlan.bankId] = completion.marker
      if provenanceDependencies == nil and type(completion.dependencies) == "table" then
        provenanceDependencies = completion.dependencies
      end
    end
    ::continue::
  end
  if #missing > 0 then
    Errors.raise("AUDIO_SUMMARY_INCOMPLETE", "family summary refuses incomplete bank coverage", {
      missingBankIds = missing,
    })
  end
  if type(provenanceDependencies) ~= "table" then
    Errors.raise("AUDIO_SUMMARY_INCOMPLETE", "family summary recovers no closure dependencies", {
      missingBankIds = {},
    })
  end
  -- The catalog owns the runtime index: the summary attests the live
  -- catalog instead of staging its own copy. A missing catalog or an index
  -- that differs from the current plan refuses before anything publishes.
  local liveIndex = liveFs:loadLua(AudioCache.indexPath())
  if type(liveIndex) ~= "table" then
    Errors.raise("AUDIO_SUMMARY_INCOMPLETE", "family summary refuses a missing catalog index", {
      missingBankIds = {},
    })
  end
  if Hashing.hashLua(liveIndex) ~= Hashing.hashLua(plan.index) then
    Errors.raise(
      "AUDIO_SUMMARY_INCOMPLETE",
      "family summary refuses a catalog index that differs from the current plan",
      { missingBankIds = {} }
    )
  end
  local catalogProblem = AudioCacheValidator.validateCatalog(liveIndex)
  if catalogProblem ~= nil then
    raiseReadback(catalogProblem, {})
  end
  local marker = AudioCacheWriter.summaryMarker(plan, bankMarkers)
  stage:writeLua(AudioCache.provenancePath(), {
    schema = AudioCache.PROVENANCE_SCHEMA,
    dependencies = provenanceDependencies,
  })
  stage:write(AudioCache.markerPath(), marker)
  if stage:read(AudioCache.markerPath()) ~= marker then
    raiseReadback("audio summary marker readback failed", {})
  end
  local problem = AudioCacheValidator.validateWithIndex(liveFs, liveIndex)
  if problem ~= nil then
    raiseReadback(problem, {})
  end
  return marker
end

-- Stage the family summary through a caller-owned prepared artifact: the
-- stage owns exactly the provenance and the completion marker, never the
-- bank closures or the catalog-owned index. Publication stays with the
-- caller.
---@param artifact PreparedArtifact
---@param plan { index: table<string, unknown>, bankPlans: table<integer, { bankId: integer, sequenceIds: integer[] }> }
---@return string
function AudioCacheWriter.stageSummary(artifact, plan)
  assert(artifact and artifact.stageFs and artifact.cacheFs, "summary staging requires a PreparedArtifact")
  local owned = checkCatalogPlan(plan)
  artifact:addOwnedRoot(AudioCache.provenancePath())
  artifact:addOwnedRoot(AudioCache.markerPath())
  return persistSummary(artifact:stageFs(), artifact:cacheFs(), owned)
end

-- Publish the family summary straight into the live cache for the batch
-- build. Refuses while any planned closure is unpublished or the live
-- catalog differs; raises like every other writer boundary.
---@param cacheFs CacheFs
---@param plan { index: table<string, unknown>, bankPlans: table<integer, { bankId: integer, sequenceIds: integer[] }> }
---@return string
function AudioCacheWriter.writeSummary(cacheFs, plan)
  local owned = checkCatalogPlan(plan)
  local tx = ArtifactPublisher.begin(cacheFs, "audio-summary", {
    AudioCache.provenancePath(),
    AudioCache.markerPath(),
  })
  local ok, result = pcall(persistSummary, tx.stage, cacheFs, owned)
  if not ok then
    tx:abort()
    error(result, 0)
  end
  tx:publish()
  return result
end

local function stageBundle(tx, bundle)
  local stage = tx.stage
  stage:writeLua(AudioCache.provenancePath(), {
    schema = AudioCache.PROVENANCE_SCHEMA,
    dependencies = bundle.dependencies,
  })
  stage:writeLua(AudioCache.indexPath(), bundle.index)
  for id, _ in pairs(bundle.index.sequences) do
    local sequence = bundle.sequences[id]
    assert(sequence, "bundle is missing sequence " .. tostring(id))
    stage:writeLua(AudioCache.sequencePath(id), sequence)
  end
  for id, _ in pairs(bundle.index.banks) do
    local bank = bundle.banks[id]
    assert(bank, "bundle is missing bank " .. tostring(id))
    stage:writeLua(AudioCache.bankPath(id), bank)
  end
  for key, bytes in pairs(bundle.samples) do
    assert(bundle.sampleMetadata[key] ~= nil, "bundle is missing sample metadata for " .. tostring(key))
    stage:write(AudioCache.samplePath(key), bytes)
    stage:writeLua(AudioCache.sampleMetadataPath(key), bundle.sampleMetadata[key])
  end
  -- Readback is the same authoritative cross-file walk readiness runs; a
  -- problem fails the staged write before anything is published.
  local problem = AudioCacheValidator.validate(stage)
  if problem ~= nil then
    raiseReadback(problem, {})
  end
  stage:write(AudioCache.markerPath(), bundle.marker)
end

function AudioCacheWriter.write(cacheFs, bundle)
  assert(bundle, "write requires an audio bundle")
  assert(bundle.marker, "marker is a required bundle section")
  assert(bundle.index, "index is a required bundle section")
  assert(bundle.sequences, "sequences is a required bundle section")
  assert(bundle.banks, "banks is a required bundle section")
  assert(bundle.samples, "samples is a required bundle section")
  assert(bundle.sampleMetadata, "sampleMetadata is a required bundle section")
  assert(bundle.dependencies, "dependencies is a required bundle section")
  assert(type(bundle.index.sequences) == "table", "index.sequences is a required bundle section")
  assert(type(bundle.index.banks) == "table", "index.banks is a required bundle section")
  assert(bundle.index.schema == AudioCache.INDEX_SCHEMA, "bundle index schema mismatch")
  local tx = ArtifactPublisher.begin(cacheFs, "audio", { AudioCache.dir() })
  local ok, err = pcall(stageBundle, tx, bundle)
  if not ok then
    tx:abort()
    error(err, 0)
  end
  tx:publish()
  return true
end

return AudioCacheWriter
