-- Bounded audio-bank production: catalog planning without wave decoding,
-- per-bank streaming compilation with a recording stage sink, timer/loop
-- sample identity, staged bank/summary publication, and single-bank repair.
-- All source archives are synthetic doubles behind the real format-decoder
-- seams; assertions observe only the compiler/writer public operations,
-- staged files, and readiness.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local AudioCache = require("libs.assets.src.audio.AudioCache")
local AudioBank = require("libs.assets.src.audio.AudioBank")
local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
local AudioCacheWriter = require("romdump.src.digest.audio.AudioCacheWriter")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local LuaWriter = require("libs.codec.src.LuaWriter")
local Sdat = require("libs.nds.src.nitro.sound.Sdat")
local Sbnk = require("libs.nds.src.nitro.sound.Sbnk")
local Swar = require("libs.nds.src.nitro.sound.Swar")
local Swav = require("libs.nds.src.nitro.sound.Swav")
local SequenceLowering = require("romdump.src.digest.audio.SequenceLowering")

local T = {}

local GENERATION = "test-generation-audio-banks"

local function bankCompletePath(bankId)
  return "data/generated/audio/bank-complete/" .. tostring(bankId) .. ".lua"
end

local function fakeRomFs(reads)
  local romFs = {
    readSourcePath = function(_, path)
      reads[path] = (reads[path] or 0) + 1
      return "fake-sdat-bytes"
    end,
    metadata = function()
      return { sha1 = "rom-sha" }
    end,
    version = function()
      return "heartgold"
    end,
    fileIdForPath = function(_, _)
      return 13
    end,
  }
  ---@cast romFs RomFs
  return romFs
end

-- A dense synthetic sound catalog: every id in range carries a record, unused
-- slots carry fileId nil. Sequences name their bank/player; banks name their
-- wave-archive slots; wave archives name their file.
local function fakeSdat(spec)
  local sdat = {
    counts = {
      sequences = spec.sequenceCount,
      banks = spec.bankCount,
      players = spec.playerCount or 2,
    },
    sequences = {},
    banks = {},
    players = {},
    waveArchives = {},
    symbols = {
      sequences = {},
      sequenceArchives = {},
      banks = {},
      waveArchives = {},
      players = {},
      groups = {},
      streamPlayers = {},
      streams = {},
    },
  }
  for id = 0, spec.sequenceCount - 1 do
    sdat.sequences[id] = { fileId = nil }
  end
  for _, seq in ipairs(spec.sequences or {}) do
    sdat.sequences[seq.id] = {
      fileId = 1000 + seq.id,
      bankId = seq.bankId,
      playerId = seq.playerId or 1,
      volume = 127,
      playerPriority = 64,
      channelPriority = 64,
    }
    local symbol = "SEQ_SYNTH_" .. seq.id
    sdat.symbols.sequences[seq.id] = symbol
  end
  for id = 0, spec.bankCount - 1 do
    sdat.banks[id] = { fileId = nil }
  end
  for _, bank in ipairs(spec.banks or {}) do
    sdat.banks[bank.id] = { fileId = 2000 + bank.id, waveArchives = bank.waveArchives or {} }
    sdat.symbols.banks[bank.id] = "BANK_SYNTH_" .. bank.id
  end
  for id = 0, (spec.playerCount or 2) - 1 do
    sdat.players[id] = { maxSequences = 16, channelMask = 0xFFFF }
  end
  for waveId, fileId in pairs(spec.waveArchives or {}) do
    sdat.waveArchives[waveId] = { fileId = fileId }
  end
  function sdat:readFile(fileId)
    return "sdat-file-" .. tostring(fileId)
  end
  return sdat
end

local function withDecoderSeams(fn)
  local saved = {
    open = Sdat.open,
    sbnk = Sbnk.decode,
    swar = Swar.decode,
    swav = Swav.decode,
    lower = SequenceLowering.lower,
  }
  local ok, err = pcall(fn)
  Sdat.open = saved.open
  Sbnk.decode = saved.sbnk
  Swar.decode = saved.swar
  Swav.decode = saved.swav
  SequenceLowering.lower = saved.lower
  if not ok then
    error(err, 0)
  end
end

local function forbidDecodeCounters(counters)
  Sbnk.decode = function(_)
    counters.sbnk = counters.sbnk + 1
    error("catalog planning must not decode bank instruments")
  end
  Swar.decode = function(_)
    counters.swar = counters.swar + 1
    error("catalog planning must not decode wave archives")
  end
  Swav.decode = function(_)
    counters.swav = counters.swav + 1
    error("catalog planning must not decode waves")
  end
  SequenceLowering.lower = function(_)
    counters.lower = counters.lower + 1
    error("catalog planning must not lower sequences")
  end
end

local function validProgram()
  return {
    entry = 1,
    initialTrackMask = 0x0001,
    instructions = {
      { op = "program", program = 4 },
      { op = "note", key = 60, velocity = 96, duration = 24 },
      { op = "wait", duration = 12 },
      { op = "jump", target = 2 },
    },
  }
end

local function pcmLeaf(swarSlot, swav)
  return {
    type = Sbnk.TYPE_PCM,
    param = {
      rootKey = 60,
      attack = 0,
      decay = 0,
      sustain = 127,
      release = 0,
      pan = 64,
      swarSlot = swarSlot,
      swav = swav,
    },
  }
end

-- Installs synthetic instrument/wave/sequence doubles. `waves` maps member
-- bytes to wave heads; `bankInstruments` maps bank fileId to an instrument
-- map. Counts every decode per member bytes.
local function installCompileDoubles(sdat, waves, bankInstruments, counters)
  Sdat.open = function(_, _)
    return sdat
  end
  Sbnk.decode = function(bytes, _)
    counters.sbnk = counters.sbnk + 1
    local instruments = bankInstruments[bytes]
    assert(instruments ~= nil, "unexpected bank bytes " .. tostring(bytes))
    return { instruments = instruments }
  end
  Swar.decode = function(bytes, _)
    counters.swar = counters.swar + 1
    local waveId = string.match(bytes, "^sdat%-file%-(%d+)$")
    assert(waveId ~= nil, "unexpected archive bytes " .. tostring(bytes))
    return {
      readMember = function(_, member)
        return "swav-bytes:" .. waveId .. ":" .. tostring(member)
      end,
    }
  end
  Swav.decode = function(bytes, _)
    counters.swav[bytes] = (counters.swav[bytes] or 0) + 1
    local wave = waves[bytes]
    assert(wave ~= nil, "unexpected wave bytes " .. tostring(bytes))
    return wave
  end
  SequenceLowering.lower = function(_, _, _)
    counters.lower = counters.lower + 1
    return validProgram()
  end
end

local function waveHead(pcm, opts)
  opts = opts or {}
  local frames = math.floor(#pcm / 2)
  local loop = opts.loop or { startFrame = 0, endFrame = frames }
  return {
    pcm16le = pcm,
    baseTimer = opts.baseTimer or 8006,
    loopEnabled = opts.loopEnabled ~= false,
    loop = loop,
    frames = frames,
  }
end

local function collectStrings(node, out)
  if type(node) == "string" then
    out[#out + 1] = node
  elseif type(node) == "table" then
    for _, value in pairs(node) do
      collectStrings(value, out)
    end
  end
end

local function versionCache(backend)
  return CacheFs.forVersion("heartgold", backend or FakeCache.new())
end

local function stageAndPublishBank(cache, romFs, bankPlan, stageName)
  local key = tostring(bankPlan.bankId)
  local artifact = PreparedArtifact.new({
    cacheFs = cache,
    generationId = GENERATION,
    epoch = 1,
    kind = "audio-bank",
    key = key,
    jobKey = "audio-bank:" .. key,
    stageName = stageName,
  })
  AudioCacheWriter.stageBank(artifact, romFs, bankPlan)
  local completion = artifact:stageFs():loadLua(bankCompletePath(bankPlan.bankId))
  Assert.notNil(completion, "the staged bank carries its completion record")
  assert(completion, "a staged completion is a record")
  Assert.equal(type(completion.marker), "string", "the completion record carries a marker")
  artifact:finishSuccess({ marker = completion.marker })
  artifact:publish({
    generationId = GENERATION,
    epoch = 1,
    kind = "audio-bank",
    key = key,
    jobKey = "audio-bank:" .. key,
  })
  return completion.marker
end

local function planById(plan)
  local byId = {}
  for _, bankPlan in ipairs(plan.bankPlans) do
    byId[bankPlan.bankId] = bankPlan
  end
  return byId
end

-- Catalog planning returns deterministic used-bank/sequence ownership without
-- touching wave or sequence decoding: bank ids and per-bank sequence ids are
-- ascending, a used bank without sequences stays in the corpus, and a used
-- sequence naming an absent bank fails with both identities.
function T.catalog_planning_lists_bank_closures_without_decoding_waves()
  Assert.equal(type(AudioCompiler.plan), "function", "catalog planning must be a public compiler operation")
  withDecoderSeams(function()
    local reads = {}
    local romFs = fakeRomFs(reads)
    local sdat = fakeSdat({
      sequenceCount = 10,
      bankCount = 12,
      sequences = {
        { id = 0, bankId = 4 },
        { id = 5, bankId = 4 },
        { id = 9, bankId = 7 },
      },
      banks = {
        { id = 4, waveArchives = { [0] = 0 } },
        { id = 7, waveArchives = { [0] = 1 } },
        { id = 11, waveArchives = { [0] = 0 } },
      },
      waveArchives = { [0] = 3000, [1] = 3001 },
    })
    Sdat.open = function(_, _)
      return sdat
    end
    local counters = { sbnk = 0, swar = 0, swav = 0, lower = 0 }
    forbidDecodeCounters(counters)
    local plan = assert(AudioCompiler.plan(romFs))
    Assert.equal(type(plan.index), "table", "planning returns normalized catalog metadata")
    Assert.equal(type(plan.bankPlans), "table", "planning returns bank closure plans")
    Assert.keySet(plan, "bankPlans,index", "planning returns only metadata and closure plans")
    local ids = {}
    for _, bankPlan in ipairs(plan.bankPlans) do
      Assert.keySet(bankPlan, "bankId,sequenceIds", "a closure plan names only its bank and sequences")
      Assert.equal(type(bankPlan.bankId), "number")
      ids[#ids + 1] = bankPlan.bankId
    end
    Assert.deepEqual(ids, { 4, 7, 11 }, "used banks are planned in ascending order, sequences included")
    local byId = planById(plan)
    Assert.deepEqual(byId[4].sequenceIds, { 0, 5 }, "per-bank sequences ascend")
    Assert.deepEqual(byId[7].sequenceIds, { 9 })
    Assert.deepEqual(byId[11].sequenceIds, {}, "a used bank without sequences stays in the corpus")
    Assert.equal(counters.sbnk, 0, "planning decodes no bank instruments")
    Assert.equal(counters.swar, 0, "planning decodes no wave archives")
    Assert.equal(counters.swav, 0, "planning decodes no waves")
    Assert.equal(counters.lower, 0, "planning lowers no sequences")
    local strings = {}
    collectStrings(plan, strings)
    for _, text in ipairs(strings) do
      Assert.isTrue(#text <= 64, "planning carries no decoded PCM payloads")
    end
    local again = assert(AudioCompiler.plan(romFs))
    Assert.equal(LuaWriter.encode(again.bankPlans), LuaWriter.encode(plan.bankPlans), "planning is deterministic")
    Assert.equal(LuaWriter.encode(again.index), LuaWriter.encode(plan.index))

    local dangling = fakeSdat({
      sequenceCount = 2,
      bankCount = 3,
      sequences = { { id = 0, bankId = 2 } },
      banks = { { id = 0, waveArchives = {} } },
      waveArchives = {},
    })
    Sdat.open = function(_, _)
      return dangling
    end
    local missing, err = AudioCompiler.plan(romFs)
    Assert.isNil(missing, "a sequence naming an absent bank plans nothing")
    Assert.isTrue(Errors.is(err), "the dangling reference is a structured planning failure")
    local detail = Errors.format(err)
    Assert.isTrue(detail:find("0", 1, true) ~= nil, "the failure names the sequence identity")
    Assert.isTrue(detail:find("2", 1, true) ~= nil, "the failure names the absent bank identity")
  end)
end

-- One bank job streams each distinct referenced wave exactly once through the
-- recording sink, reuses the semantic key for repeated references, and keeps
-- no PCM payload in its returned bundle.
function T.bank_compilation_streams_each_referenced_wave_once()
  Assert.equal(
    type(AudioCompiler.compileBank),
    "function",
    "one-bank streaming compilation must be a public compiler operation"
  )
  withDecoderSeams(function()
    local reads = {}
    local romFs = fakeRomFs(reads)
    local sdat = fakeSdat({
      sequenceCount = 3,
      bankCount = 6,
      sequences = { { id = 1, bankId = 4 } },
      banks = { { id = 4, waveArchives = { [0] = 0, [1] = 1 } } },
      waveArchives = { [0] = 3000, [1] = 3001 },
    })
    local pcmA = string.char(1, 0, 2, 0, 3, 0, 4, 0)
    local pcmB = string.char(9, 0, 8, 0)
    local pcmC = string.char(7, 0, 6, 0, 5, 0)
    local waves = {
      ["swav-bytes:3000:0"] = waveHead(pcmA),
      ["swav-bytes:3000:1"] = waveHead(pcmB),
      ["swav-bytes:3001:0"] = waveHead(pcmC),
    }
    local counters = { sbnk = 0, swar = 0, swav = {}, lower = 0 }
    installCompileDoubles(sdat, waves, {}, counters)
    Sbnk.decode = function(bytes, _)
      counters.sbnk = counters.sbnk + 1
      Assert.equal(bytes, "sdat-file-2004", "only the selected bank decodes")
      return {
        instruments = {
          [0] = { type = Sbnk.TYPE_PCM, param = pcmLeaf(0, 0).param },
          [1] = { type = Sbnk.TYPE_PCM, param = pcmLeaf(0, 0).param },
          [2] = {
            type = Sbnk.TYPE_DRUM_SET,
            minKey = 60,
            maxKey = 61,
            leaves = {
              [0] = { type = Sbnk.TYPE_PCM, param = pcmLeaf(0, 1).param },
              [1] = { type = Sbnk.TYPE_PCM, param = pcmLeaf(1, 0).param },
            },
          },
          [3] = {
            type = Sbnk.TYPE_KEY_SPLIT,
            leaves = {
              [0] = { type = Sbnk.TYPE_PCM, param = pcmLeaf(0, 0).param },
              [1] = { type = Sbnk.TYPE_PCM, param = pcmLeaf(1, 0).param },
            },
            keys = { [0] = 59, [1] = 127 },
          },
        },
      }
    end
    local sunk = {}
    local sinkCalls = 0
    local function sampleSink(key, metadata, pcm)
      sinkCalls = sinkCalls + 1
      Assert.equal(type(key), "string", "the sink receives the semantic sample key")
      Assert.equal(metadata.key, key, "sunk metadata matches its address")
      if sunk[key] == nil then
        sunk[key] = { metadata = metadata, pcm = pcm }
      else
        Assert.equal(sunk[key].pcm, pcm, "a repeated identity sinks identical bytes")
      end
    end
    local bundle = assert(AudioCompiler.compileBank(romFs, { bankId = 4, sequenceIds = { 1 } }, sampleSink))
    local distinct = 0
    for _, count in pairs(counters.swav) do
      Assert.equal(count, 1, "each distinct source wave decodes once in the job")
      distinct = distinct + 1
    end
    Assert.equal(distinct, 3, "three distinct source identities stream through the sink")
    local sunkKeys = 0
    for _ in pairs(sunk) do
      sunkKeys = sunkKeys + 1
    end
    Assert.equal(sunkKeys, 3, "the sink receives each semantic sample once")
    Assert.equal(counters.lower, 1, "only the bank's own sequence lowers, not the corpus")
    Assert.equal(counters.sbnk, 1, "only the selected bank decodes")
    Assert.notNil(bundle.bank, "the closure returns its bank record")
    AudioBank.validate(bundle.bank)
    Assert.equal(bundle.bank.id, 4, "the closure returns the selected bank")
    local voices = {}
    local function collectVoices(node)
      if type(node) ~= "table" then
        return
      end
      if type(node.generator) == "table" and node.generator.kind == "sample" then
        voices[#voices + 1] = node.generator.sample
      end
      for _, value in pairs(node) do
        collectVoices(value)
      end
    end
    collectVoices(bundle.bank)
    Assert.isTrue(#voices >= 2, "the bank voices reference streamed samples")
    Assert.equal(voices[1], voices[2], "repeated source identities reuse their semantic key")
    local returned = {}
    collectStrings(bundle, returned)
    for _, text in ipairs(returned) do
      for _, sunkEntry in pairs(sunk) do
        Assert.isFalse(text == sunkEntry.pcm, "the returned bundle holds keys and metadata, never retained PCM")
      end
    end
  end)
end

-- Semantically different samples never alias: equal PCM with a different base
-- timer or loop window produces distinct keys, while a fully identical
-- identity deduplicates to one sunk sample.
function T.sample_identity_keeps_timer_and_loop_windows_distinct()
  Assert.equal(
    type(AudioCompiler.compileBank),
    "function",
    "one-bank streaming compilation must be a public compiler operation"
  )
  local pcm = string.char(1, 0, 2, 0, 3, 0, 4, 0)
  Assert.equal(
    AudioCompiler.sampleKey(pcm, 8006, true, 0, 4),
    AudioCompiler.sampleKey(pcm, 8006, true, 0, 4),
    "a fully identical sample identity is stable"
  )
  Assert.isFalse(
    AudioCompiler.sampleKey(pcm, 8006, true, 0, 4) == AudioCompiler.sampleKey(pcm, 7606, true, 0, 4),
    "a different base timer is a different sample"
  )
  Assert.isFalse(
    AudioCompiler.sampleKey(pcm, 8006, true, 0, 4) == AudioCompiler.sampleKey(pcm, 8006, true, 0, 2),
    "a different loop window is a different sample"
  )
  withDecoderSeams(function()
    local romFs = fakeRomFs({})
    local sdat = fakeSdat({
      sequenceCount = 1,
      bankCount = 5,
      sequences = {},
      banks = { { id = 4, waveArchives = { [0] = 0, [1] = 1 } } },
      waveArchives = { [0] = 3000, [1] = 3001 },
    })
    local counters = { sbnk = 0, swar = 0, swav = {}, lower = 0 }
    installCompileDoubles(sdat, {
      ["swav-bytes:3000:0"] = waveHead(pcm, { baseTimer = 8006, loop = { startFrame = 0, endFrame = 4 } }),
      ["swav-bytes:3000:1"] = waveHead(pcm, { baseTimer = 7606, loop = { startFrame = 0, endFrame = 4 } }),
      ["swav-bytes:3001:0"] = waveHead(pcm, { baseTimer = 8006, loop = { startFrame = 0, endFrame = 2 } }),
      ["swav-bytes:3001:1"] = waveHead(pcm, { baseTimer = 8006, loop = { startFrame = 0, endFrame = 4 } }),
    }, {}, counters)
    Sbnk.decode = function(bytes, _)
      counters.sbnk = counters.sbnk + 1
      Assert.equal(bytes, "sdat-file-2004")
      return {
        instruments = {
          [0] = { type = Sbnk.TYPE_PCM, param = pcmLeaf(0, 0).param },
          [1] = { type = Sbnk.TYPE_PCM, param = pcmLeaf(0, 1).param },
          [2] = { type = Sbnk.TYPE_PCM, param = pcmLeaf(1, 0).param },
          [3] = { type = Sbnk.TYPE_PCM, param = pcmLeaf(1, 1).param },
        },
      }
    end
    local sunk = {}
    local bundle =
      assert(AudioCompiler.compileBank(romFs, { bankId = 4, sequenceIds = {} }, function(key, metadata, bytes)
        sunk[key] = { metadata = metadata, pcm = bytes }
      end))
    local keys = {}
    for _, instrument in pairs(bundle.bank.instruments) do
      keys[#keys + 1] = assert(instrument.voice.generator.sample)
    end
    Assert.equal(#keys, 4, "four voices reference the four source identities")
    Assert.isFalse(keys[1] == keys[2], "equal PCM with a different timer never aliases")
    Assert.isFalse(keys[1] == keys[3], "equal PCM with a different loop window never aliases")
    Assert.equal(keys[1], keys[4], "a fully identical identity deduplicates")
    local sunkCount = 0
    for _ in pairs(sunk) do
      sunkCount = sunkCount + 1
    end
    Assert.equal(sunkCount, 3, "three semantic identities sink exactly once each")
  end)
end

-- One failed closure blocks only completeness: the healthy bank publishes and
-- stays ready, the failed bank publishes no receipt, and the family summary
-- refuses while the failure stays explicit.
function T.failed_bank_closure_blocks_only_the_family_summary()
  Assert.equal(type(AudioCompiler.plan), "function", "catalog planning must be a public compiler operation")
  Assert.equal(type(AudioCacheWriter.stageBank), "function", "bank closures stage one at a time")
  Assert.equal(type(AudioCacheWriter.stageSummary), "function", "the family summary stages after its banks")
  Assert.equal(type(AudioCache.isBankReady), "function", "bank readiness is separate from family readiness")
  withDecoderSeams(function()
    local romFs = fakeRomFs({})
    local sdat = fakeSdat({
      sequenceCount = 2,
      bankCount = 8,
      sequences = {
        { id = 0, bankId = 4 },
        { id = 1, bankId = 7 },
      },
      banks = {
        { id = 4, waveArchives = { [0] = 0 } },
        { id = 7, waveArchives = { [0] = 1 } },
      },
      waveArchives = { [0] = 3000, [1] = 3001 },
    })
    local pcm = string.char(1, 0, 2, 0, 3, 0, 4, 0)
    local counters = { sbnk = 0, swar = 0, swav = {}, lower = 0 }
    installCompileDoubles(sdat, {
      ["swav-bytes:3000:0"] = waveHead(pcm),
    }, {}, counters)
    Sbnk.decode = function(bytes, _)
      counters.sbnk = counters.sbnk + 1
      if bytes == "sdat-file-2004" then
        return { instruments = { [0] = { type = Sbnk.TYPE_PCM, param = pcmLeaf(0, 0).param } } }
      end
      Assert.equal(bytes, "sdat-file-2007")
      return { instruments = { [0] = { type = Sbnk.TYPE_PCM, param = pcmLeaf(0, 0).param } } }
    end
    -- The second bank's wave archive decodes, but its member payload is
    -- malformed: the failure names the bank and never becomes silence.
    local realSwav = Swav.decode
    Swav.decode = function(bytes, context)
      if bytes == "swav-bytes:3001:0" then
        local failure = Errors.new("SWAV_MALFORMED", "synthetic malformed wave", {
          bankId = 7,
          waveId = 1,
          member = 0,
        })
        error(failure)
      end
      return realSwav(bytes, context)
    end
    local plan = assert(AudioCompiler.plan(romFs))
    local byId = planById(plan)
    Assert.notNil(byId[4], "the healthy bank is planned")
    Assert.notNil(byId[7], "the failing bank is planned")
    local backend = FakeCache.new()
    local cache = versionCache(backend)
    local healthyMarker = stageAndPublishBank(cache, romFs, byId[4], "audio-bank-4")
    Assert.isTrue(
      AudioCache.isBankReady(cache, 4, healthyMarker),
      "the healthy bank stays current without source decoding"
    )
    Assert.isFalse(AudioCache.isBankReady(cache, 4, healthyMarker .. "-stale"), "a stale marker does not read as ready")
    local failing = PreparedArtifact.new({
      cacheFs = cache,
      generationId = GENERATION,
      epoch = 1,
      kind = "audio-bank",
      key = "7",
      jobKey = "audio-bank:7",
      stageName = "audio-bank-7",
    })
    local ok, failure = pcall(AudioCacheWriter.stageBank, failing, romFs, byId[7])
    failing:abort()
    Assert.isFalse(ok, "the malformed bank closure fails its staging")
    Assert.isTrue(
      Errors.is(failure) or tostring(failure):find("7", 1, true) ~= nil,
      "the closure failure is explicit about its bank"
    )
    Assert.isNil(cache:read(bankCompletePath(7)), "no receipt is published for the failed closure")
    Assert.isFalse(AudioCache.isBankReady(cache, 7, healthyMarker), "the failed bank is not ready")
    local summary = PreparedArtifact.new({
      cacheFs = cache,
      generationId = GENERATION,
      epoch = 1,
      kind = "audio-bank",
      key = "global",
      jobKey = "audio-bank:global",
      stageName = "audio-summary-partial",
    })
    local summaryOk = pcall(AudioCacheWriter.stageSummary, summary, plan)
    summary:abort()
    Assert.isFalse(summaryOk, "the summary refuses while a bank closure is missing")
    Assert.isFalse(
      AudioCache.isReady(cache, "no-summary-published"),
      "an unpublished summary leaves the family incomplete"
    )
    Assert.isTrue(
      AudioCache.isBankReady(cache, 4, healthyMarker),
      "the failed closure does not revoke the healthy bank"
    )
    Assert.notNil(cache:read(AudioCache.bankPath(4)), "the failed closure does not revoke unrelated bank artifacts")
  end)
end

-- Restart repairs exactly the damaged closure: after removing one bank's
-- receipt and output, re-preparing the same generation restores that bank
-- and the summary while sibling bank, sequence, and sample bytes are
-- untouched.
function T.prepare_repairs_only_the_damaged_bank_closure_and_summary()
  Assert.equal(type(AudioCompiler.plan), "function", "catalog planning must be a public compiler operation")
  Assert.equal(type(AudioCacheWriter.stageBank), "function", "bank closures stage one at a time")
  Assert.equal(type(AudioCacheWriter.stageSummary), "function", "the family summary stages after its banks")
  withDecoderSeams(function()
    local romFs = fakeRomFs({})
    local sdat = fakeSdat({
      sequenceCount = 2,
      bankCount = 8,
      sequences = {
        { id = 0, bankId = 4 },
        { id = 1, bankId = 7 },
      },
      banks = {
        { id = 4, waveArchives = { [0] = 0 } },
        { id = 7, waveArchives = { [0] = 1 } },
      },
      waveArchives = { [0] = 3000, [1] = 3001 },
    })
    local pcmA = string.char(1, 0, 2, 0, 3, 0, 4, 0)
    local pcmB = string.char(9, 0, 8, 0, 7, 0)
    local counters = { sbnk = 0, swar = 0, swav = {}, lower = 0 }
    installCompileDoubles(sdat, {
      ["swav-bytes:3000:0"] = waveHead(pcmA),
      ["swav-bytes:3001:0"] = waveHead(pcmB),
    }, {}, counters)
    Sbnk.decode = function(bytes, _)
      counters.sbnk = counters.sbnk + 1
      if bytes == "sdat-file-2004" then
        return { instruments = { [0] = { type = Sbnk.TYPE_PCM, param = pcmLeaf(0, 0).param } } }
      end
      Assert.equal(bytes, "sdat-file-2007")
      return { instruments = { [0] = { type = Sbnk.TYPE_PCM, param = pcmLeaf(0, 0).param } } }
    end
    local plan = assert(AudioCompiler.plan(romFs))
    local identity = assert(AudioCompiler.soundIdentity(romFs))
    local byId = planById(plan)
    local backend = FakeCache.new()
    local cache = versionCache(backend)
    local markerA = stageAndPublishBank(cache, romFs, byId[4], "audio-bank-4")
    stageAndPublishBank(cache, romFs, byId[7], "audio-bank-7")
    local catalogArtifact = PreparedArtifact.new({
      cacheFs = cache,
      generationId = GENERATION,
      epoch = 1,
      kind = "audio-catalog",
      key = "global",
      jobKey = "audio-catalog:global",
      stageName = "audio-catalog",
    })
    local catalogMarker = AudioCacheWriter.stageCatalog(catalogArtifact, plan, identity)
    catalogArtifact:finishSuccess({ marker = catalogMarker })
    catalogArtifact:publish({
      generationId = GENERATION,
      epoch = 1,
      kind = "audio-catalog",
      key = "global",
      jobKey = "audio-catalog:global",
    })
    Assert.isTrue(AudioCache.isCatalogReady(cache, catalogMarker), "the staged catalog reads ready before the summary")
    local summaryArtifact = PreparedArtifact.new({
      cacheFs = cache,
      generationId = GENERATION,
      epoch = 1,
      kind = "audio-bank",
      key = "global",
      jobKey = "audio-bank:global",
      stageName = "audio-summary",
    })
    local summaryMarker = AudioCacheWriter.stageSummary(summaryArtifact, plan)
    Assert.equal(type(summaryMarker), "string", "the summary stages its completion marker")
    summaryArtifact:finishSuccess({ marker = summaryMarker })
    summaryArtifact:publish({
      generationId = GENERATION,
      epoch = 1,
      kind = "audio-bank",
      key = "global",
      jobKey = "audio-bank:global",
    })
    Assert.isTrue(AudioCache.isReady(cache, summaryMarker), "full coverage publishes a ready family")

    local siblingBank = cache:read(AudioCache.bankPath(4))
    local siblingSequence = cache:read(AudioCache.sequencePath(0))
    local damagedBank = cache:read(AudioCache.bankPath(7))
    Assert.notNil(siblingBank, "sibling bank staged")
    Assert.notNil(damagedBank, "damaged bank staged before removal")
    cache:remove(AudioCache.bankPath(7))
    cache:remove(bankCompletePath(7))
    Assert.isFalse(AudioCache.isBankReady(cache, 7, summaryMarker), "the removed bank reads as not ready")
    Assert.isFalse(AudioCache.isReady(cache, summaryMarker), "a missing bank is never hidden by an old summary")
    Assert.isTrue(AudioCache.isBankReady(cache, 4, markerA), "the sibling bank stays current")

    local writes = {}
    local originalWrite = backend.write
    backend.write = function(self, path, data)
      writes[#writes + 1] = path
      return originalWrite(self, path, data)
    end
    local repairOk, repairErr = pcall(function()
      stageAndPublishBank(cache, romFs, byId[7], "audio-bank-7-repair")
      local repairSummary = PreparedArtifact.new({
        cacheFs = cache,
        generationId = GENERATION,
        epoch = 1,
        kind = "audio-bank",
        key = "global",
        jobKey = "audio-bank:global",
        stageName = "audio-summary-repair",
      })
      local repairedMarker = AudioCacheWriter.stageSummary(repairSummary, plan)
      repairSummary:finishSuccess({ marker = repairedMarker })
      repairSummary:publish({
        generationId = GENERATION,
        epoch = 1,
        kind = "audio-bank",
        key = "global",
        jobKey = "audio-bank:global",
      })
      Assert.equal(repairedMarker, summaryMarker, "the same generation repairs to the same summary")
    end)
    backend.write = originalWrite
    Assert.isTrue(repairOk, "repairing the same generation succeeds: " .. tostring(repairErr))
    Assert.equal(cache:read(AudioCache.bankPath(7)), damagedBank, "only the damaged closure is restored")
    Assert.equal(cache:read(AudioCache.bankPath(4)), siblingBank, "the sibling bank is untouched")
    Assert.equal(cache:read(AudioCache.sequencePath(0)), siblingSequence, "sibling sequences are untouched")
    for _, path in ipairs(writes) do
      Assert.isFalse(
        path == AudioCache.bankPath(4) or path == bankCompletePath(4),
        "repair writes no sibling bank artifact: " .. tostring(path)
      )
    end
    Assert.isTrue(AudioCache.isReady(cache, summaryMarker), "the repaired family reads ready again")
  end)
end

-- One-bank compilation names only used records: an absent bank and a
-- sequence owned by another bank both fail with their identities, never an
-- empty closure.
function T.bank_compilation_rejects_references_outside_the_closure()
  Assert.equal(
    type(AudioCompiler.compileBank),
    "function",
    "one-bank streaming compilation must be a public compiler operation"
  )
  withDecoderSeams(function()
    local romFs = fakeRomFs({})
    local sdat = fakeSdat({
      sequenceCount = 2,
      bankCount = 10,
      sequences = { { id = 0, bankId = 4 } },
      banks = {
        { id = 4, waveArchives = { [0] = 0 } },
        { id = 7, waveArchives = { [0] = 0 } },
      },
      waveArchives = { [0] = 3000 },
    })
    local counters = { sbnk = 0, swar = 0, swav = {}, lower = 0 }
    installCompileDoubles(sdat, {}, {}, counters)
    local function ignoreSink(_, _, _) end
    local missing, missingErr = AudioCompiler.compileBank(romFs, { bankId = 9, sequenceIds = {} }, ignoreSink)
    Assert.isNil(missing, "an absent bank compiles nothing")
    Assert.isTrue(Errors.is(missingErr), "the absent bank is a structured failure")
    Assert.isTrue(Errors.format(missingErr):find("9", 1, true) ~= nil, "the failure names the bank identity")
    local stray, strayErr = AudioCompiler.compileBank(romFs, { bankId = 7, sequenceIds = { 0 } }, ignoreSink)
    Assert.isNil(stray, "a sequence owned by another bank compiles nothing here")
    Assert.isTrue(Errors.is(strayErr), "the stray sequence is a structured failure")
    local detail = Errors.format(strayErr)
    Assert.isTrue(detail:find("0", 1, true) ~= nil, "the failure names the sequence identity")
    Assert.isTrue(detail:find("7", 1, true) ~= nil, "the failure names the closure bank identity")
  end)
end

-- A malformed referenced wave fails the closure with its bank, archive, and
-- member context, never silence or a partial bundle.
function T.bank_compilation_reports_malformed_waves_with_source_context()
  Assert.equal(
    type(AudioCompiler.compileBank),
    "function",
    "one-bank streaming compilation must be a public compiler operation"
  )
  withDecoderSeams(function()
    local romFs = fakeRomFs({})
    local sdat = fakeSdat({
      sequenceCount = 1,
      bankCount = 5,
      sequences = {},
      banks = { { id = 4, waveArchives = { [0] = 0 } } },
      waveArchives = { [0] = 3000 },
    })
    local counters = { sbnk = 0, swar = 0, swav = {}, lower = 0 }
    installCompileDoubles(sdat, {}, {}, counters)
    Sbnk.decode = function(bytes, _)
      counters.sbnk = counters.sbnk + 1
      Assert.equal(bytes, "sdat-file-2004")
      return { instruments = { [0] = { type = Sbnk.TYPE_PCM, param = pcmLeaf(0, 0).param } } }
    end
    local realSwav = Swav.decode
    Swav.decode = function(bytes, context)
      if bytes == "swav-bytes:3000:0" then
        return nil, Errors.new("SWAV_MALFORMED", "synthetic malformed wave", { waveId = 0, member = 0 })
      end
      return realSwav(bytes, context)
    end
    local sunk = 0
    local bundle, err = AudioCompiler.compileBank(romFs, { bankId = 4, sequenceIds = {} }, function(_, _, _)
      sunk = sunk + 1
    end)
    Assert.isNil(bundle, "the malformed wave compiles nothing")
    Assert.isTrue(Errors.is(err), "the malformed wave is a structured failure")
    err = assert(err)
    Assert.equal(err.context.bankId, 4, "the failure names the closure bank")
    Assert.equal(err.context.waveId, 0, "the failure names the wave archive")
    Assert.equal(err.context.member, 0, "the failure names the wave member")
    Assert.equal(sunk, 0, "no sample streams from a failed closure")
  end)
end

-- An unsupported command in a planned sequence fails the closure: lowering
-- errors are build failures, never placeholder instructions.
function T.bank_compilation_reports_unsupported_sequence_commands()
  Assert.equal(
    type(AudioCompiler.compileBank),
    "function",
    "one-bank streaming compilation must be a public compiler operation"
  )
  withDecoderSeams(function()
    local romFs = fakeRomFs({})
    local sdat = fakeSdat({
      sequenceCount = 2,
      bankCount = 5,
      sequences = { { id = 1, bankId = 4 } },
      banks = { { id = 4, waveArchives = { [0] = 0 } } },
      waveArchives = { [0] = 3000 },
    })
    local pcm = string.char(1, 0, 2, 0, 3, 0, 4, 0)
    local counters = { sbnk = 0, swar = 0, swav = {}, lower = 0 }
    installCompileDoubles(sdat, {
      ["swav-bytes:3000:0"] = waveHead(pcm),
    }, {}, counters)
    Sbnk.decode = function(_)
      return { instruments = { [0] = { type = Sbnk.TYPE_PCM, param = pcmLeaf(0, 0).param } } }
    end
    SequenceLowering.lower = function(_, _, _)
      error(Errors.new("AUDIO_SEQUENCE_UNSUPPORTED_COMMAND", "synthetic unsupported command", { sequenceId = 1 }))
    end
    local bundle, err = AudioCompiler.compileBank(romFs, { bankId = 4, sequenceIds = { 1 } }, function(_, _, _) end)
    Assert.isNil(bundle, "the unsupported command compiles nothing")
    Assert.isTrue(Errors.is(err), "the unsupported command is a structured failure")
    assert(err, "a structured failure is an error")
    Assert.equal(err.code, "AUDIO_SEQUENCE_UNSUPPORTED_COMMAND", "the lowering failure keeps its identity")
  end)
end

-- A staging sink failure stops the job immediately with the original error:
-- the compiler never swallows or wraps it into a partial bundle.
function T.bank_compilation_preserves_sink_failures_unchanged()
  Assert.equal(
    type(AudioCompiler.compileBank),
    "function",
    "one-bank streaming compilation must be a public compiler operation"
  )
  withDecoderSeams(function()
    local romFs = fakeRomFs({})
    local sdat = fakeSdat({
      sequenceCount = 1,
      bankCount = 5,
      sequences = {},
      banks = { { id = 4, waveArchives = { [0] = 0 } } },
      waveArchives = { [0] = 3000 },
    })
    local pcm = string.char(1, 0, 2, 0, 3, 0, 4, 0)
    local counters = { sbnk = 0, swar = 0, swav = {}, lower = 0 }
    installCompileDoubles(sdat, {
      ["swav-bytes:3000:0"] = waveHead(pcm),
    }, {}, counters)
    Sbnk.decode = function(_)
      return { instruments = { [0] = { type = Sbnk.TYPE_PCM, param = pcmLeaf(0, 0).param } } }
    end
    local ok, failure = pcall(AudioCompiler.compileBank, romFs, { bankId = 4, sequenceIds = {} }, function(_, _, _)
      error("injected sink failure")
    end)
    Assert.isFalse(ok, "the sink failure stops the job")
    Assert.isFalse(Errors.is(failure), "a plain sink failure stays a plain failure")
    Assert.isTrue(
      tostring(failure):find("injected sink failure", 1, true) ~= nil,
      "the original sink error is preserved"
    )
  end)
end

-- Staging one bank never disturbs a published sibling: the sibling bank,
-- sequence, completion, and sample bytes stay identical and ready.
function T.staging_a_bank_leaves_published_siblings_untouched()
  Assert.equal(type(AudioCompiler.plan), "function", "catalog planning must be a public compiler operation")
  Assert.equal(type(AudioCacheWriter.stageBank), "function", "bank closures stage one at a time")
  withDecoderSeams(function()
    local romFs = fakeRomFs({})
    local sdat = fakeSdat({
      sequenceCount = 2,
      bankCount = 8,
      sequences = {
        { id = 0, bankId = 4 },
        { id = 1, bankId = 7 },
      },
      banks = {
        { id = 4, waveArchives = { [0] = 0 } },
        { id = 7, waveArchives = { [0] = 1 } },
      },
      waveArchives = { [0] = 3000, [1] = 3001 },
    })
    local pcmA = string.char(1, 0, 2, 0, 3, 0, 4, 0)
    local pcmB = string.char(9, 0, 8, 0, 7, 0)
    local counters = { sbnk = 0, swar = 0, swav = {}, lower = 0 }
    installCompileDoubles(sdat, {
      ["swav-bytes:3000:0"] = waveHead(pcmA),
      ["swav-bytes:3001:0"] = waveHead(pcmB),
    }, {}, counters)
    Sbnk.decode = function(bytes, _)
      counters.sbnk = counters.sbnk + 1
      if bytes == "sdat-file-2004" then
        return { instruments = { [0] = { type = Sbnk.TYPE_PCM, param = pcmLeaf(0, 0).param } } }
      end
      Assert.equal(bytes, "sdat-file-2007")
      return { instruments = { [0] = { type = Sbnk.TYPE_PCM, param = pcmLeaf(0, 0).param } } }
    end
    local plan = assert(AudioCompiler.plan(romFs))
    local byId = planById(plan)
    local backend = FakeCache.new()
    local cache = versionCache(backend)
    local markerA = stageAndPublishBank(cache, romFs, byId[4], "audio-bank-4")
    stageAndPublishBank(cache, romFs, byId[7], "audio-bank-7")
    local siblingBank = cache:read(AudioCache.bankPath(4))
    local siblingSequence = cache:read(AudioCache.sequencePath(0))
    local siblingCompletion = cache:read(bankCompletePath(4))
    Assert.notNil(siblingBank, "sibling bank published")
    Assert.notNil(siblingSequence, "sibling sequence published")
    local restage = PreparedArtifact.new({
      cacheFs = cache,
      generationId = GENERATION,
      epoch = 1,
      kind = "audio-bank",
      key = "7",
      jobKey = "audio-bank:7",
      stageName = "audio-bank-7-untouched",
    })
    AudioCacheWriter.stageBank(restage, romFs, byId[7])
    restage:abort()
    Assert.equal(cache:read(AudioCache.bankPath(4)), siblingBank, "staging never rewrites the sibling bank")
    Assert.equal(cache:read(AudioCache.sequencePath(0)), siblingSequence, "staging never rewrites sibling sequences")
    Assert.equal(cache:read(bankCompletePath(4)), siblingCompletion, "staging never rewrites the sibling completion")
    Assert.isTrue(AudioCache.isBankReady(cache, 4, markerA), "the sibling closure stays ready")
  end)
end

-- The batch spelling publishes the same closures without prepared artifacts:
-- each bank stages its marker deterministically, and the summary completes
-- the family exactly once every closure is current.
function T.batch_bank_and_summary_publication_matches_staged_closures()
  Assert.equal(type(AudioCompiler.plan), "function", "catalog planning must be a public compiler operation")
  withDecoderSeams(function()
    local romFs = fakeRomFs({})
    local sdat = fakeSdat({
      sequenceCount = 2,
      bankCount = 8,
      sequences = {
        { id = 0, bankId = 4 },
        { id = 1, bankId = 7 },
      },
      banks = {
        { id = 4, waveArchives = { [0] = 0 } },
        { id = 7, waveArchives = { [0] = 1 } },
      },
      waveArchives = { [0] = 3000, [1] = 3001 },
    })
    local pcmA = string.char(1, 0, 2, 0, 3, 0, 4, 0)
    local pcmB = string.char(9, 0, 8, 0, 7, 0)
    local counters = { sbnk = 0, swar = 0, swav = {}, lower = 0 }
    installCompileDoubles(sdat, {
      ["swav-bytes:3000:0"] = waveHead(pcmA),
      ["swav-bytes:3001:0"] = waveHead(pcmB),
    }, {}, counters)
    Sbnk.decode = function(bytes, _)
      counters.sbnk = counters.sbnk + 1
      if bytes == "sdat-file-2004" then
        return { instruments = { [0] = { type = Sbnk.TYPE_PCM, param = pcmLeaf(0, 0).param } } }
      end
      Assert.equal(bytes, "sdat-file-2007")
      return { instruments = { [0] = { type = Sbnk.TYPE_PCM, param = pcmLeaf(0, 0).param } } }
    end
    local plan = assert(AudioCompiler.plan(romFs))
    local identity = assert(AudioCompiler.soundIdentity(romFs))
    Assert.equal(type(identity.romSha1), "string", "the source identity carries the ROM identity")
    Assert.equal(type(identity.sdatSha1), "string", "the source identity carries the archive identity")
    local byId = planById(plan)
    local cache = versionCache()
    local markers = {}
    for _, bankPlan in ipairs(plan.bankPlans) do
      local expected = AudioCompiler.bankMarker(identity, bankPlan)
      Assert.equal(AudioCompiler.bankMarker(identity, bankPlan), expected, "closure markers are deterministic")
      local marker, err = AudioCacheWriter.writeBank(cache, romFs, bankPlan)
      Assert.notNil(marker, "the bank publishes: " .. tostring(err and Errors.format(err) or "no error"))
      Assert.equal(marker, expected, "a published bank carries its planned marker")
      markers[bankPlan.bankId] = marker
      Assert.isTrue(AudioCache.isBankReady(cache, bankPlan.bankId, expected), "the published bank reads ready")
    end
    local catalogMarker = AudioCacheWriter.writeCatalog(cache, plan, identity)
    Assert.isTrue(AudioCache.isCatalogReady(cache, catalogMarker), "the batch catalog reads ready before the summary")
    local summaryMarker = AudioCacheWriter.summaryMarker(plan, markers)
    Assert.equal(AudioCacheWriter.summaryMarker(plan, markers), summaryMarker, "the family marker is deterministic")
    Assert.equal(AudioCacheWriter.writeSummary(cache, plan), summaryMarker, "the summary publishes its marker")
    Assert.isTrue(AudioCache.isReady(cache, summaryMarker), "the batch family reads ready")
    Assert.notNil(cache:read(AudioCache.bankPath(4)), "bank closures survive the summary")
    Assert.notNil(cache:read(AudioCache.bankPath(byId[7].bankId)), "every planned bank survives the summary")
  end)
end

-- One worker-generation session acquires the archive once no matter how many
-- banks compile through it: a single source read, a single archive open, and
-- a single identity hash serve every bank job, warm reuse opens nothing new,
-- and a new session after close or a generation change acquires exactly
-- once more. A shared sample still streams per bank job; no cross-bank PCM
-- memo suppresses the second stream. A mismatched identity fails
-- structurally, and a closed session refuses further compilation.
function T.session_compilation_reuses_one_archive_acquisition_across_banks()
  Assert.equal(
    type(AudioCompiler.openSession),
    "function",
    "one immutable archive session per worker generation must own bank compilation"
  )
  withDecoderSeams(function()
    local reads = {}
    local romFs = fakeRomFs(reads)
    local sharedPcm = string.char(1, 0, 2, 0, 3, 0, 4, 0)
    local sdat = fakeSdat({
      sequenceCount = 3,
      bankCount = 8,
      sequences = {
        { id = 0, bankId = 4 },
        { id = 1, bankId = 7 },
      },
      banks = {
        { id = 4, waveArchives = { [0] = 0 } },
        { id = 7, waveArchives = { [0] = 1 } },
      },
      waveArchives = { [0] = 3000, [1] = 3001 },
    })
    local counters = { sbnk = 0, swar = 0, swav = {}, lower = 0 }
    installCompileDoubles(sdat, {
      ["swav-bytes:3000:0"] = waveHead(sharedPcm),
      ["swav-bytes:3001:0"] = waveHead(sharedPcm),
    }, {}, counters)
    local bankDecode = function(_, _)
      counters.sbnk = counters.sbnk + 1
      return { instruments = { [0] = { type = Sbnk.TYPE_PCM, param = pcmLeaf(0, 0).param } } }
    end
    Sbnk.decode = bankDecode
    local Hashing = require("romdump.src.digest.Hashing")
    local realSha1hex = Hashing.sha1hex
    local archiveOpens = 0
    local archiveHashes = 0
    local installedOpen = Sdat.open
    Sdat.open = function(bytes, path)
      archiveOpens = archiveOpens + 1
      return installedOpen(bytes, path)
    end
    Hashing.sha1hex = function(bytes)
      if bytes == "fake-sdat-bytes" then
        archiveHashes = archiveHashes + 1
      end
      return realSha1hex(bytes)
    end
    local bodyOk, bodyErr = pcall(function()
      local identity = assert(AudioCompiler.soundIdentity(romFs))
      for key in pairs(reads) do
        reads[key] = nil
      end
      archiveOpens = 0
      archiveHashes = 0
      local plan = assert(AudioCompiler.plan(romFs))
      local byId = planById(plan)
      Assert.notNil(byId[4], "the first bank is planned")
      Assert.notNil(byId[7], "the second bank is planned")
      local sessionReads = reads["data/sound/gs_sound_data.sdat"] or 0
      local sessionOpens = archiveOpens
      local sessionHashes = archiveHashes
      local session = assert(AudioCompiler.openSession(romFs, identity))
      Assert.equal(
        (reads["data/sound/gs_sound_data.sdat"] or 0) - sessionReads,
        1,
        "opening the session reads the archive bytes once"
      )
      Assert.equal(archiveOpens - sessionOpens, 1, "opening the session parses the archive once")
      Assert.equal(archiveHashes - sessionHashes, 1, "opening the session hashes the archive once")
      local sunkA = {}
      local bundleA = assert(session:compileBank(byId[4], function(key, metadata, pcm)
        sunkA[key] = { metadata = metadata, pcm = pcm }
      end))
      local sunkB = {}
      local bundleB = assert(session:compileBank(byId[7], function(key, metadata, pcm)
        sunkB[key] = { metadata = metadata, pcm = pcm }
      end))
      Assert.equal(
        reads["data/sound/gs_sound_data.sdat"] or 0,
        sessionReads + 1,
        "two bank jobs perform no further archive reads"
      )
      Assert.equal(archiveOpens, sessionOpens + 1, "two bank jobs parse the archive no further")
      Assert.equal(archiveHashes, sessionHashes + 1, "two bank jobs hash the archive no further")
      Assert.notNil(bundleA.bank, "the first session closure returns its bank")
      Assert.notNil(bundleB.bank, "the second session closure returns its bank")
      AudioBank.validate(bundleA.bank)
      AudioBank.validate(bundleB.bank)
      local sharedKey = nil
      for key in pairs(sunkA) do
        sharedKey = key
      end
      Assert.notNil(sharedKey, "the first bank streams its shared sample")
      Assert.notNil(sunkB[sharedKey], "the shared sample streams again for the second bank job")
      Assert.equal(sunkB[sharedKey].pcm, sunkA[sharedKey].pcm, "the shared stream carries identical bytes")
      local warmBundle = assert(session:compileBank(byId[4], function(_, _, _) end))
      Assert.equal(warmBundle.marker, bundleA.marker, "repeated compilation through the session is stable")
      Assert.equal(reads["data/sound/gs_sound_data.sdat"] or 0, sessionReads + 1, "warm reuse opens no further archive")
      Assert.equal(archiveOpens, sessionOpens + 1, "warm reuse parses nothing further")
      session:close()
      session:close()
      local closedOk = pcall(session.compileBank, session, byId[4], function(_, _, _) end)
      Assert.isFalse(closedOk, "a closed session refuses further compilation")
      local afterClose = assert(AudioCompiler.openSession(romFs, identity))
      Assert.equal(
        reads["data/sound/gs_sound_data.sdat"] or 0,
        sessionReads + 2,
        "a new session acquires the archive exactly once more"
      )
      Assert.equal(archiveOpens, sessionOpens + 2, "a new session parses the archive exactly once more")
      Assert.equal(archiveHashes, sessionHashes + 2, "a new session hashes the archive exactly once more")
      afterClose:close()
      local wrongIdentity = { romSha1 = "wrong-rom", sdatSha1 = identity.sdatSha1, sdatFileId = 13 }
      local rejected, rejectErr = AudioCompiler.openSession(romFs, wrongIdentity)
      Assert.isNil(rejected, "a mismatched source identity opens no session")
      Assert.isTrue(Errors.is(rejectErr), "the identity mismatch is a structured failure")
    end)
    Hashing.sha1hex = realSha1hex
    if not bodyOk then
      error(bodyErr, 0)
    end
  end)
end

-- A bank staged through the retained session carries byte-identical assets
-- to the direct one-bank path: bank record, sequences, sample payloads and
-- metadata, and the completion marker all match. A mismatched identity
-- fails before staging, and a staging failure still preserves the
-- previously published bank.
function T.session_staged_bank_matches_direct_staged_bytes()
  Assert.equal(
    type(AudioCompiler.openSession),
    "function",
    "one immutable archive session per worker generation must own bank staging"
  )
  withDecoderSeams(function()
    local romFs = fakeRomFs({})
    local pcm = string.char(1, 0, 2, 0, 3, 0, 4, 0)
    local sdat = fakeSdat({
      sequenceCount = 2,
      bankCount = 6,
      sequences = { { id = 0, bankId = 4 } },
      banks = { { id = 4, waveArchives = { [0] = 0 } } },
      waveArchives = { [0] = 3000 },
    })
    local counters = { sbnk = 0, swar = 0, swav = {}, lower = 0 }
    installCompileDoubles(sdat, {
      ["swav-bytes:3000:0"] = waveHead(pcm),
    }, {}, counters)
    Sbnk.decode = function(bytes, _)
      counters.sbnk = counters.sbnk + 1
      Assert.equal(bytes, "sdat-file-2004", "only the selected bank decodes")
      return { instruments = { [0] = { type = Sbnk.TYPE_PCM, param = pcmLeaf(0, 0).param } } }
    end
    local identity = assert(AudioCompiler.soundIdentity(romFs))
    local plan = assert(AudioCompiler.plan(romFs))
    local bankPlan = assert(planById(plan)[4], "the bank is planned")
    local directSunk = {}
    local directCache = versionCache(FakeCache.new())
    local directArtifact = PreparedArtifact.new({
      cacheFs = directCache,
      generationId = GENERATION,
      epoch = 1,
      kind = "audio-bank",
      key = "4",
      jobKey = "audio-bank:4",
      stageName = "audio-bank-4-direct",
    })
    local directBundle = assert(AudioCompiler.compileBank(romFs, bankPlan, function(key, metadata, bytes)
      directSunk[key] = { metadata = metadata, pcm = bytes }
    end))
    AudioCacheWriter.stageBank(directArtifact, romFs, bankPlan)
    local directStage = directArtifact:stageFs()
    local session = assert(AudioCompiler.openSession(romFs, identity))
    local sessionSunk = {}
    local sessionCache = versionCache(FakeCache.new())
    local sessionArtifact = PreparedArtifact.new({
      cacheFs = sessionCache,
      generationId = GENERATION,
      epoch = 1,
      kind = "audio-bank",
      key = "4",
      jobKey = "audio-bank:4",
      stageName = "audio-bank-4-session",
    })
    local sessionBundle = assert(session:compileBank(bankPlan, function(key, metadata, bytes)
      sessionSunk[key] = { metadata = metadata, pcm = bytes }
    end))
    AudioCacheWriter.stageBank(sessionArtifact, session, bankPlan)
    local stagedStage = sessionArtifact:stageFs()
    session:close()
    Assert.equal(
      LuaWriter.encode(sessionBundle.bank),
      LuaWriter.encode(directBundle.bank),
      "the session closure carries the identical bank record"
    )
    Assert.equal(
      LuaWriter.encode(sessionBundle.sequences),
      LuaWriter.encode(directBundle.sequences),
      "the session closure carries the identical sequences"
    )
    Assert.equal(
      LuaWriter.encode(sessionBundle.sampleMetadata),
      LuaWriter.encode(directBundle.sampleMetadata),
      "the session closure carries the identical sample metadata"
    )
    Assert.equal(sessionBundle.marker, directBundle.marker, "the session closure carries the identical marker")
    Assert.equal(
      LuaWriter.encode(stagedStage:loadLua(AudioCache.bankPath(4))),
      LuaWriter.encode(directStage:loadLua(AudioCache.bankPath(4))),
      "the staged bank bytes match the direct staged bank"
    )
    Assert.equal(
      LuaWriter.encode(stagedStage:loadLua(AudioCache.sequencePath(0))),
      LuaWriter.encode(directStage:loadLua(AudioCache.sequencePath(0))),
      "the staged sequence bytes match the direct staged sequence"
    )
    for key, sunk in pairs(directSunk) do
      Assert.notNil(sessionSunk[key], "the session streams every direct sample " .. key)
      Assert.equal(sessionSunk[key].pcm, sunk.pcm, "the streamed sample bytes match for " .. key)
      Assert.equal(
        stagedStage:read(AudioCache.samplePath(key)),
        directStage:read(AudioCache.samplePath(key)),
        "the staged sample payload matches for " .. key
      )
      Assert.equal(
        LuaWriter.encode(stagedStage:loadLua(AudioCache.sampleMetadataPath(key))),
        LuaWriter.encode(directStage:loadLua(AudioCache.sampleMetadataPath(key))),
        "the staged sample metadata matches for " .. key
      )
    end
    local directCompletion = assert(directStage:loadLua(bankCompletePath(4)), "the direct stage carries its completion")
    local stagedCompletion =
      assert(stagedStage:loadLua(bankCompletePath(4)), "the session stage carries its completion")
    Assert.equal(stagedCompletion.marker, directCompletion.marker, "both stages attest the identical marker")
    directArtifact:abort()
    sessionArtifact:abort()
    local wrongIdentity = { romSha1 = identity.romSha1, sdatSha1 = "wrong-archive", sdatFileId = 13 }
    local rejected, rejectErr = AudioCompiler.openSession(romFs, wrongIdentity)
    Assert.isNil(rejected, "a mismatched archive identity stages nothing")
    Assert.isTrue(Errors.is(rejectErr), "the archive mismatch is a structured failure")
  end)
end

-- A staging failure before publication preserves the previously published
-- bank: the live bank, sequence, completion, and readiness survive the
-- aborted stage.
function T.failed_session_bank_stage_preserves_the_published_bank()
  withDecoderSeams(function()
    local romFs = fakeRomFs({})
    local pcm = string.char(1, 0, 2, 0, 3, 0, 4, 0)
    local sdat = fakeSdat({
      sequenceCount = 2,
      bankCount = 6,
      sequences = { { id = 0, bankId = 4 } },
      banks = { { id = 4, waveArchives = { [0] = 0 } } },
      waveArchives = { [0] = 3000 },
    })
    local counters = { sbnk = 0, swar = 0, swav = {}, lower = 0 }
    installCompileDoubles(sdat, {
      ["swav-bytes:3000:0"] = waveHead(pcm),
    }, {}, counters)
    Sbnk.decode = function(_)
      return { instruments = { [0] = { type = Sbnk.TYPE_PCM, param = pcmLeaf(0, 0).param } } }
    end
    local plan = assert(AudioCompiler.plan(romFs))
    local bankPlan = assert(planById(plan)[4], "the bank is planned")
    local backend = FakeCache.new()
    local cache = versionCache(backend)
    local marker = stageAndPublishBank(cache, romFs, bankPlan, "audio-bank-4-live")
    Assert.isTrue(AudioCache.isBankReady(cache, 4, marker), "the published bank reads ready")
    local liveBank = cache:read(AudioCache.bankPath(4))
    local liveSequence = cache:read(AudioCache.sequencePath(0))
    local liveCompletion = cache:read(bankCompletePath(4))
    local failing = PreparedArtifact.new({
      cacheFs = cache,
      generationId = GENERATION,
      epoch = 1,
      kind = "audio-bank",
      key = "4",
      jobKey = "audio-bank:4",
      stageName = "audio-bank-4-failing",
    })
    local stageBackend = failing:stageFs()
    local originalWrite = stageBackend.write
    stageBackend.write = function(self, path, data)
      if path:find(".pcm16le", 1, true) ~= nil then
        error("injected sample staging failure")
      end
      return originalWrite(self, path, data)
    end
    local ok = pcall(AudioCacheWriter.stageBank, failing, romFs, bankPlan)
    stageBackend.write = originalWrite
    failing:abort()
    Assert.isFalse(ok, "the failing stage stages nothing")
    Assert.equal(cache:read(AudioCache.bankPath(4)), liveBank, "the live bank survives the failed stage")
    Assert.equal(cache:read(AudioCache.sequencePath(0)), liveSequence, "the live sequence survives")
    Assert.equal(cache:read(bankCompletePath(4)), liveCompletion, "the live completion survives")
    Assert.isTrue(AudioCache.isBankReady(cache, 4, marker), "the published bank stays ready")
  end)
end

return { tests = T }
