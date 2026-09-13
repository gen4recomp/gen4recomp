-- Bank-closure equivalence against the real sound archive: deterministic
-- used-bank planning covers every referenced sequence and bank, and each
-- independently compiled bank closure carries the same sequence IR,
-- normalized instruments, and PCM bytes as the aggregate baseline, with no
-- silently omitted sound. Playback over these assets stays with the engine
-- runtime suites; this suite proves the decomposed graph matches.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local AudioCache = require("libs.assets.src.audio.AudioCache")
local AudioSequence = require("libs.assets.src.audio.AudioSequence")
local AudioBank = require("libs.assets.src.audio.AudioBank")
local AudioSample = require("libs.assets.src.audio.AudioSample")
local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
local LuaWriter = require("libs.codec.src.LuaWriter")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local RomFs = require("romdump.src.source.RomFs")

local T = {}
local contexts = nil

function T.beforeAll()
  local opened = {}
  contexts = opened
  local readyVersions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      readyVersions[#readyVersions + 1] = versionId
    end
  end
  for _, versionId in ipairs(readyVersions) do
    local entry = { versionId = versionId, romFs = assert(RomFs.open(versionId)) }
    opened[#opened + 1] = entry
    local ok, err = pcall(function()
      local baseline, compileErr = AudioCompiler.compile(entry.romFs)
      Assert.notNil(baseline, "compile failed: " .. (compileErr and Errors.format(compileErr) or "no error"))
      entry.baseline = assert(baseline)
      Assert.equal(type(AudioCompiler.plan), "function", "bank-closure planning must be a public operation")
      entry.plan = assert(AudioCompiler.plan(entry.romFs))
    end)
    if not ok then
      error(versionId .. ": " .. tostring(err), 0)
    end
  end
end

function T.afterAll()
  local opened = contexts
  contexts = nil
  if opened ~= nil then
    for _, entry in ipairs(opened) do
      entry.romFs:close()
    end
  end
end

local function forEachVersion(fn)
  for _, ctx in ipairs(assert(contexts, "the bank equivalence suite has no open contexts")) do
    local ok, err = pcall(fn, ctx)
    if not ok then
      error(ctx.versionId .. ": " .. tostring(err), 0)
    end
  end
end

-- Collects every table in a closure result whose schema marker matches, keyed
-- by its numeric identity, without naming the closure's field layout.
local function collectBySchema(node, schema, out)
  if type(node) ~= "table" then
    return
  end
  if node.schema == schema and type(node.id) == "number" then
    out[node.id] = node
  end
  for _, value in pairs(node) do
    collectBySchema(value, schema, out)
  end
end

-- Every bank closure of the real archive carries the baseline graph:
-- deterministic ascending plans cover all referenced sequences and banks, and
-- each streamed closure reproduces the baseline sequence IR, instruments, and
-- PCM bytes with authoritative validation passing and no omitted sound.
function T.bank_closures_reproduce_the_baseline_audio_graph()
  forEachVersion(function(ctx)
    Assert.equal(
      type(AudioCompiler.compileBank),
      "function",
      "one-bank streaming compilation must be a public operation"
    )
    local plan = ctx.plan
    Assert.keySet(plan, "bankPlans,index", "planning returns only metadata and closure plans")
    Assert.equal(
      LuaWriter.encode(plan.index),
      LuaWriter.encode(ctx.baseline.index),
      "the planned index matches the baseline runtime index sections and symbol maps"
    )
    local again = assert(AudioCompiler.plan(ctx.romFs))
    Assert.equal(
      LuaWriter.encode(again.bankPlans),
      LuaWriter.encode(plan.bankPlans),
      "closure planning is deterministic"
    )
    local previousBank = -1
    local coveredSequences = {}
    local coveredBanks = {}
    for _, bankPlan in ipairs(plan.bankPlans) do
      Assert.keySet(bankPlan, "bankId,sequenceIds", "a closure plan names only its bank and sequences")
      Assert.isTrue(bankPlan.bankId > previousBank, "bank closures plan in ascending order")
      previousBank = bankPlan.bankId
      coveredBanks[bankPlan.bankId] = true
      local previousSequence = -1
      for _, sequenceId in ipairs(bankPlan.sequenceIds) do
        Assert.isTrue(sequenceId > previousSequence, "closure sequences plan in ascending order")
        previousSequence = sequenceId
        Assert.isNil(coveredSequences[sequenceId], "sequence " .. sequenceId .. " is owned by one closure")
        coveredSequences[sequenceId] = bankPlan.bankId
      end
    end
    for id in pairs(ctx.baseline.index.sequences) do
      local owner = coveredSequences[id]
      Assert.notNil(owner, "referenced sequence " .. id .. " is owned by a closure")
      Assert.notNil(ctx.baseline.index.banks[owner], "sequence " .. id .. " owner bank is used")
    end
    for id in pairs(ctx.baseline.index.banks) do
      Assert.isTrue(coveredBanks[id] == true, "used bank " .. id .. " has its own closure")
    end

    local sunkSamples = {}
    local sunkMetadata = {}
    local closureCount = 0
    for _, bankPlan in ipairs(plan.bankPlans) do
      local closure = assert(AudioCompiler.compileBank(ctx.romFs, bankPlan, function(key, metadata, pcm)
        if sunkSamples[key] == nil then
          sunkSamples[key] = pcm
          sunkMetadata[key] = metadata
        else
          Assert.equal(sunkSamples[key], pcm, "shared samples stream identical bytes")
        end
      end))
      closureCount = closureCount + 1
      local sequences = {}
      collectBySchema(closure, AudioCache.SEQUENCE_SCHEMA, sequences)
      local owned = 0
      for _, sequenceId in ipairs(bankPlan.sequenceIds) do
        local streamed = sequences[sequenceId]
        Assert.notNil(streamed, "closure owns its planned sequence " .. sequenceId)
        owned = owned + 1
        AudioSequence.validate(streamed)
        Assert.equal(
          LuaWriter.encode(streamed),
          LuaWriter.encode(ctx.baseline.sequences[sequenceId]),
          "streamed sequence " .. sequenceId .. " matches the baseline IR"
        )
      end
      local sequenceTotal = 0
      for _ in pairs(sequences) do
        sequenceTotal = sequenceTotal + 1
      end
      Assert.equal(sequenceTotal, owned, "a closure streams only its own sequences")
      local banks = {}
      collectBySchema(closure, AudioCache.BANK_SCHEMA, banks)
      local streamedBank = banks[bankPlan.bankId]
      Assert.notNil(streamedBank, "closure owns its planned bank " .. bankPlan.bankId)
      AudioBank.validate(streamedBank)
      Assert.equal(
        LuaWriter.encode(streamedBank),
        LuaWriter.encode(ctx.baseline.banks[bankPlan.bankId]),
        "streamed bank " .. bankPlan.bankId .. " matches the baseline instruments"
      )
    end
    Assert.isTrue(closureCount >= 1, "the archive plans at least one bank closure")

    local baselineSamples = 0
    for key, payload in pairs(ctx.baseline.samples) do
      baselineSamples = baselineSamples + 1
      Assert.notNil(sunkSamples[key], "referenced sample streams through a bank closure")
      Assert.equal(sunkSamples[key], payload, "streamed PCM bytes match the baseline")
      local metadata = sunkMetadata[key]
      Assert.notNil(metadata, "streamed sample carries its metadata")
      AudioSample.validate(metadata, sunkSamples[key])
      Assert.equal(
        AudioCompiler.sampleKey(
          payload,
          metadata.baseTimer,
          metadata.loopEnabled,
          metadata.loop.startFrame,
          metadata.loop.endFrame
        ),
        key,
        "streamed sample identity preserves timer and loop addressing"
      )
    end
    local streamedSamples = 0
    for _ in pairs(sunkSamples) do
      streamedSamples = streamedSamples + 1
    end
    Assert.equal(streamedSamples, baselineSamples, "no sound is silently omitted or invented")
    Assert.isTrue(baselineSamples >= 1, "the archive streams at least one sample")

    local sequenceBySymbol = plan.index.sequenceBySymbol
    Assert.equal(type(sequenceBySymbol), "table", "the planned index carries the sequence symbol map")
    local maps = 0
    for record in MapCatalog.all() do
      maps = maps + 1
      for _, field in ipairs({ "dayMusic", "nightMusic" }) do
        local id = sequenceBySymbol["SEQ_" .. record[field]]
        Assert.notNil(id, record.symbol .. " " .. field .. " resolves through the closure index")
        Assert.notNil(coveredSequences[id], record.symbol .. " " .. field .. " is owned by a closure")
      end
    end
    Assert.isTrue(maps >= 1, "the map catalog iterated")
  end)
end

return {
  metadata = { capabilities = { "rom_dump" } },
  beforeAll = T.beforeAll,
  afterAll = T.afterAll,
  tests = {
    bank_closures_reproduce_the_baseline_audio_graph = T.bank_closures_reproduce_the_baseline_audio_graph,
  },
}
