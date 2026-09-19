-- AudioCacheWriter contract: one staged transaction per class — provenance,
-- index, sequences, banks, unique content-addressed sample payloads/metadata,
-- readback validation of shape and references, marker last, then publish. A
-- failed rebuild must never destroy a previously usable audio cache; publish
-- failures keep the stage as recovery material.

local Assert = require("tests.support.Assert")
local AudioCache = require("libs.assets.src.audio.AudioCache")
local AudioCacheWriter = require("romdump.src.digest.audio.AudioCacheWriter")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local AudioFixture = require("tests.support.AudioFixture")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")

local T = {}

local GENERATION = "audio-catalog-generation"

local function catalogPlan(bundle)
  return {
    index = bundle.index,
    bankPlans = { { bankId = 12, sequenceIds = { 0, 37 } } },
  }
end

local function soundIdentity()
  return { romSha1 = "rom-sha", sdatSha1 = "archive-sha", sdatFileId = 13 }
end

local function catalogArtifact(cache, stageName)
  return PreparedArtifact.new({
    cacheFs = cache,
    generationId = GENERATION,
    epoch = 1,
    kind = "audio-catalog",
    key = "global",
    jobKey = "audio-catalog:global",
    stageName = stageName or "audio-catalog",
  })
end

local function versionCache()
  return CacheFs.forVersion("heartgold", FakeCache.new())
end

-- The writer publishes provenance, the index, every indexed sequence and
-- bank, every sample payload with its metadata, and only then the marker;
-- the class then reads ready.
T["write publishes provenance index assets and marker last"] = function()
  local cache = versionCache()
  local bundle = AudioFixture.bundle()
  Assert.isTrue(AudioCacheWriter.write(cache, bundle))
  local provenance = cache:loadLua(AudioCache.provenancePath())
  provenance = provenance --[[@as { schema: string, dependencies: { soundArchive: { path: string } } }]]
  Assert.equal(provenance.schema, AudioCache.PROVENANCE_SCHEMA)
  Assert.equal(provenance.dependencies.soundArchive.path, "data/sound/gs_sound_data.sdat")
  local index = cache:loadLua(AudioCache.indexPath())
  index = index --[[@as { schema: string, version: string }]]
  Assert.equal(index.schema, AudioCache.INDEX_SCHEMA)
  Assert.equal(index.version, "heartgold")
  local sequence = cache:loadLua(AudioCache.sequencePath(0))
  sequence = sequence --[[@as { schema: string, id: integer }]]
  Assert.equal(sequence.schema, AudioCache.SEQUENCE_SCHEMA)
  Assert.equal(sequence.id, 0)
  local bank = cache:loadLua(AudioCache.bankPath(12))
  bank = bank --[[@as { schema: string, id: integer }]]
  Assert.equal(bank.schema, AudioCache.BANK_SCHEMA)
  Assert.equal(bank.id, 12)
  local key = AudioFixture.key(1)
  Assert.equal(cache:read(AudioCache.samplePath(key)), AudioFixture.pcm16le({ 1000, 2000, 3000, 4000 }))
  local metadata = cache:loadLua(AudioCache.sampleMetadataPath(key))
  metadata = metadata --[[@as { schema: string, key: string }]]
  Assert.equal(metadata.schema, AudioCache.SAMPLE_SCHEMA)
  Assert.equal(metadata.key, key)
  Assert.equal(cache:read(AudioCache.markerPath()), bundle.marker)
  Assert.isTrue(AudioCache.isReady(cache, bundle.marker))
end

-- The E1 bundle shape is required; a missing section is a programming fault,
-- never an empty default.
T["write requires the full bundle shape"] = function()
  local cache = versionCache()
  local bundle = AudioFixture.bundle()
  Assert.throws(function()
    AudioCacheWriter.write(cache, {
      marker = bundle.marker,
      index = bundle.index,
      sequences = bundle.sequences,
      banks = bundle.banks,
      samples = bundle.samples,
      sampleMetadata = bundle.sampleMetadata,
    })
  end, "dependencies is a required bundle section")
  Assert.throws(function()
    AudioCacheWriter.write(cache, {
      marker = bundle.marker,
      index = bundle.index,
      sequences = bundle.sequences,
      banks = bundle.banks,
      samples = bundle.samples,
    })
  end, "sampleMetadata is a required bundle section")
end

-- Samples are content-addressed: several bank voices sharing one key produce
-- exactly one payload and one metadata file.
T["shared sample keys are written once"] = function()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local bundle = AudioFixture.bundle()
  bundle.banks[12].instruments[0].voice.generator.sample = AudioFixture.key(2)
  Assert.isTrue(AudioCacheWriter.write(cache, bundle))
  local payloads = backend:getDirectoryItems("heartgold/data/generated/audio/samples")
  Assert.deepEqual(payloads, { AudioFixture.key(1) .. ".pcm16le", AudioFixture.key(2) .. ".pcm16le" })
  local metadata = backend:getDirectoryItems("heartgold/data/generated/audio/sample-metadata")
  Assert.deepEqual(metadata, { AudioFixture.key(1) .. ".lua", AudioFixture.key(2) .. ".lua" })
end

-- Readback validates every reference: a sequence whose bank id does not
-- resolve into the staged index fails the write and leaves no partial cache.
T["unresolvable sequence bank reference rolls back"] = function()
  local cache = versionCache()
  local bundle = AudioFixture.bundle()
  bundle.index.sequences[37].bankId = 99
  Assert.throws(function()
    AudioCacheWriter.write(cache, bundle)
  end)
  Assert.isNil(cache:read(AudioCache.markerPath()), "no marker may leak from a failed write")
  Assert.isNil(cache:read(AudioCache.indexPath()), "a failed write leaves no live index")
end

-- The readback runs the asset validators: a malformed sequence fails the
-- write with a full rollback.
T["sequence content is validated at the write boundary"] = function()
  local cache = versionCache()
  local bundle = AudioFixture.bundle()
  bundle.sequences[37].program = nil
  Assert.throws(function()
    AudioCacheWriter.write(cache, bundle)
  end)
  Assert.isNil(cache:read(AudioCache.markerPath()))
  Assert.isNil(cache:read(AudioCache.indexPath()))
end

T["sample metadata is validated at the write boundary"] = function()
  local cache = versionCache()
  local bundle = AudioFixture.bundle()
  bundle.sampleMetadata[AudioFixture.key(1)].key = AudioFixture.key(9)
  Assert.throws(function()
    AudioCacheWriter.write(cache, bundle)
  end)
  Assert.isNil(cache:read(AudioCache.markerPath()))
  Assert.isNil(cache:read(AudioCache.indexPath()))
end

-- A metadata record whose key does not match its address is a mis-keyed
-- bundle even when the record itself is self-consistent: the payload address
-- and the record identity must agree.
T["sample metadata key must match its address"] = function()
  local cache = versionCache()
  local bundle = AudioFixture.bundle()
  local keyA, keyB = AudioFixture.key(1), AudioFixture.key(2)
  bundle.sampleMetadata[keyA].key = keyB
  Assert.throws(function()
    AudioCacheWriter.write(cache, bundle)
  end)
  Assert.isNil(cache:read(AudioCache.markerPath()))
  Assert.isNil(cache:read(AudioCache.indexPath()))
end

-- Readback and readiness are one rule set: every malformed cross-file
-- relation must fail the staged write AND read as not ready. No second
-- inspection vocabulary may drift from the staging gate.
T["readback and readiness agree on malformed cross-file relations"] = function()
  local relations = {
    {
      name = "unknown sequence reference",
      breakBundle = function(bundle)
        bundle.sequences[37] = nil
      end,
    },
    {
      name = "sequence bank id does not resolve",
      breakBundle = function(bundle)
        bundle.index.sequences[37].bankId = 99
      end,
    },
    {
      name = "bank sample reference without metadata",
      breakBundle = function(bundle)
        bundle.banks[12].instruments[0].voice.generator.sample = AudioFixture.key(99)
      end,
    },
    {
      name = "sample payload byte count mismatch",
      breakBundle = function(bundle)
        local key = AudioFixture.key(1)
        bundle.samples[key] = bundle.samples[key] .. "\0"
      end,
    },
  }
  for _, relation in ipairs(relations) do
    local broken = AudioFixture.bundle()
    relation.breakBundle(broken)
    Assert.throws(function()
      AudioCacheWriter.write(versionCache(), broken)
    end, relation.name .. " fails the write")
    Assert.isFalse(AudioCache.isReady(AudioFixture.readyCache(broken), broken.marker), relation.name .. " is not ready")
  end
end

-- A failed rebuild leaves the previous ready artifact untouched, the stage
-- clean, and a retry publishes the new artifact.
T["failed rebuild preserves the previous audio artifact"] = function()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  AudioCacheWriter.write(cache, AudioFixture.bundle())
  local original = backend.write
  backend.write = function(self, path, data)
    if path:find(".pcm16le", 1, true) then
      error("injected write failure")
    end
    return original(self, path, data)
  end
  local second = AudioFixture.bundle()
  second.marker = AudioCache.marker("rom-sha", "new-dep-sha")
  Assert.throws(function()
    AudioCacheWriter.write(cache, second)
  end)
  Assert.isTrue(
    AudioCache.isReady(cache, AudioCache.marker("rom-sha", "dep-sha")),
    "the previous artifact remains ready"
  )
  Assert.equal(cache:read(AudioCache.markerPath()), AudioCache.marker("rom-sha", "dep-sha"), "no new marker leaked")
  Assert.isNil(backend:getInfo("staging/heartgold/audio"), "the stage is cleaned on failure")
  backend.write = original
  AudioCacheWriter.write(cache, second)
  Assert.isTrue(AudioCache.isReady(cache, second.marker), "a retry publishes the new artifact")
  Assert.isNil(backend:getInfo("staging/heartgold/audio"), "the stage is cleaned on success")
end

-- A rename failure after publish begins must not trigger writer-level stage
-- cleanup: the adjacent old root remains recovery material.
T["publish failure keeps the stage with recovery material"] = function()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  AudioCacheWriter.write(cache, AudioFixture.bundle())
  local originalReplace = backend.replace
  backend.replace = function(self, sourcePath, destinationPath)
    local nextPrefix = "heartgold/" .. AudioCache.dir() .. ".__g4next."
    local oldPrefix = "heartgold/" .. AudioCache.dir() .. ".__g4old."
    if sourcePath:sub(1, #nextPrefix) == nextPrefix or sourcePath:sub(1, #oldPrefix) == oldPrefix then
      return false, "injected publish failure"
    end
    return originalReplace(self, sourcePath, destinationPath)
  end
  local second = AudioFixture.bundle()
  second.marker = AudioCache.marker("rom-sha", "new-dep-sha")
  local err = Assert.throws(function()
    AudioCacheWriter.write(cache, second)
  end)
  Assert.equal(err.code, "CACHE_PUBLISH_ROLLBACK_INCOMPLETE")
  Assert.notNil(backend:getInfo("staging/heartgold/audio"), "the stage is not removed once publish has begun")
  local oldPrefix = "heartgold/" .. AudioCache.dir() .. ".__g4old."
  local oldMarker
  for path, data in pairs(backend.files) do
    if path:sub(1, #oldPrefix) == oldPrefix and path:sub(-#"/complete") == "/complete" then
      oldMarker = data
    end
  end
  Assert.equal(
    oldMarker,
    AudioCache.marker("rom-sha", "dep-sha"),
    "the last-known-good audio class stays in the stage as recovery material"
  )
end

-- The catalog stages the runtime index apart from every bank payload: the
-- staged index plus the catalog completion reads catalog-ready while the
-- full family still refuses, and the runtime provider constructs from the
-- staged index alone.
T["stageCatalog publishes the runtime index before any bank closure"] = function()
  local bundle = AudioFixture.bundle()
  local cache = versionCache()
  local artifact = catalogArtifact(cache)
  local marker = AudioCacheWriter.stageCatalog(artifact, catalogPlan(bundle), soundIdentity())
  Assert.equal(type(marker), "string", "catalog staging returns its completion marker")
  local stage = artifact:stageFs()
  Assert.isTrue(AudioCache.isCatalogReady(stage, marker), "the staged index reads catalog-ready")
  Assert.isFalse(AudioCache.isReady(stage, marker), "catalog readiness never implies full family readiness")
  local AudioAssetProvider = require("libs.hgss.src.audio.AudioAssetProvider")
  Assert.notNil(AudioAssetProvider.new(stage), "the runtime provider constructs from the catalog stage")
  artifact:abort()
end

-- The family summary no longer owns the runtime index: it publishes only
-- provenance and completion over the already-published catalog and every
-- bank closure, and it refuses a live catalog index that differs from the
-- current plan.
T["stageSummary attests the live catalog without republishing the index"] = function()
  local bundle = AudioFixture.bundle()
  local cache = versionCache()
  local catalog = catalogArtifact(cache)
  local catalogMarker = AudioCacheWriter.stageCatalog(catalog, catalogPlan(bundle), soundIdentity())
  catalog:finishSuccess({ marker = catalogMarker })
  catalog:publish({
    generationId = GENERATION,
    epoch = 1,
    kind = "audio-catalog",
    key = "global",
    jobKey = "audio-catalog:global",
  })
  Assert.isTrue(AudioCache.isCatalogReady(cache, catalogMarker), "the published catalog stays ready")
  local summary = PreparedArtifact.new({
    cacheFs = cache,
    generationId = GENERATION,
    epoch = 1,
    kind = "audio-summary",
    key = "global",
    jobKey = "audio-summary:global",
    stageName = "audio-summary",
  })
  local liveIndex = assert(cache:loadLua(AudioCache.indexPath()), "the live catalog index exists")
  liveIndex.version = "soulsilver"
  cache:writeLua(AudioCache.indexPath(), liveIndex)
  local ok = pcall(AudioCacheWriter.stageSummary, summary, catalogPlan(bundle))
  summary:abort()
  Assert.isFalse(ok, "the summary refuses a live catalog index that differs from the current plan")
end

return { tests = T }
