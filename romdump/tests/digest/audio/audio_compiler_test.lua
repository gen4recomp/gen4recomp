-- Audio compiler contract: a synthetic SDAT holding real SSEQ/SBNK/SWAR
-- payloads compiles into the full writer-shaped bundle (marker/index/
-- sequences/banks/samples/sampleMetadata/dependencies) with zero-based ids,
-- symbolic resolution, content-addressed deduplicated samples, and every
-- asset passing its validator. Malformed archives return nil, err; repeated
-- compiles are byte-identical.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
local AudioCache = require("libs.assets.src.audio.AudioCache")
local AudioSequence = require("libs.assets.src.audio.AudioSequence")
local AudioBank = require("libs.assets.src.audio.AudioBank")
local AudioSample = require("libs.assets.src.audio.AudioSample")
local Sdat = require("libs.nds.src.nitro.sound.Sdat")
local SdatFixture = require("tests.support.SdatFixture")
local SseqFixture = require("tests.support.SseqFixture")
local SbnkFixture = require("tests.support.SbnkFixture")
local SwarFixture = require("tests.support.SwarFixture")
local Swav = require("libs.nds.src.nitro.sound.Swav")
local Hashing = require("romdump.src.digest.Hashing")

local SDAT_PATH = "data/sound/gs_sound_data.sdat"

local T = {}

---@param e any
---@return Errors.Error
local function asError(e)
  return e
end

local PCM_A = { swav = 0, swarSlot = 0, rootKey = 60, attack = 120, decay = 60, sustain = 80, release = 100, pan = 64 }
local PCM_B = { swav = 1, swarSlot = 0, rootKey = 40, attack = 127, decay = 0, sustain = 127, release = 127, pan = 40 }
local PSG_A = { swav = 3, swarSlot = 0, rootKey = 48, attack = 127, decay = 0, sustain = 127, release = 127, pan = 32 }
local NOISE_A =
  { swav = 0, swarSlot = 0, rootKey = 60, attack = 127, decay = 0, sustain = 127, release = 127, pan = 96 }

local PCM8_SAMPLES = { -128, -64, 0, 64, 127, -1, 1, 2 }
local PCM16_SAMPLES = { -32768, -1, 0, 1, 32767, -1000, 1000, 500 }
local ADPCM_SAMPLES = {
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  3000,
  3000,
  3000,
  3000,
  3000,
  3000,
  3000,
  3000,
  -5000,
  -5000,
  -5000,
  -5000,
  -5000,
  -5000,
  -5000,
  -5000,
}

local function pcm8Member()
  return SwarFixture.pcm8(PCM8_SAMPLES, { sampleRate = 16000 })
end

local function pcm16Member()
  return SwarFixture.pcm16(PCM16_SAMPLES, { sampleRate = 22050 })
end

local function adpcmMember()
  return SwarFixture.adpcm(ADPCM_SAMPLES, { sampleRate = 22050 })
end

-- The semantic sample key of a member: the canonical deterministic hash of
-- the full runtime sample identity (decoded PCM, base timer, loop flag and
-- loop window), not the payload alone.
local function memberKey(memberBytes)
  local wave = assert(Swav.decode(memberBytes, "fixture"))
  return AudioCompiler.sampleKey(
    wave.pcm16le,
    wave.baseTimer,
    wave.loopEnabled,
    wave.loop.startFrame,
    wave.loop.endFrame
  )
end

local PCM8_KEY = memberKey(pcm8Member())

-- Builds the two-track sequence payload: the FE header's open-track record
-- (track 0's first command), the main program, and a call target deep in the
-- file. Symbolic targets resolve against the fixture's own layout.
local function sseq0Bytes()
  return SseqFixture.build({
    { op = "fe", mask = 3 },
    { op = "open_track", track = 1, target = { cmd = 7 } },
    { op = "note", key = 60, velocity = 96, duration = 24 },
    { op = "wait", duration = 12 },
    { op = "jump", target = { cmd = 4 } },
    { op = "note", key = 72, velocity = 80, duration = 8 },
    { op = "call", target = { cmd = 7 } },
    { op = "fin" },
  })
end

-- The synthetic archive: two sequences on two banks, one SWAR per bank, and
-- wave members shared across instruments so content deduplication is
-- exercised. Returns the SDAT bytes and its build layout.
local function buildArchive(overrides)
  ---@type table
  local spec = {
    sequences = {
      [0] = { bankId = 1, volume = 120, channelPriority = 127, playerPriority = 64, playerId = 0 },
      [2] = { bankId = 0, volume = 100, channelPriority = 64, playerPriority = 64, playerId = 1 },
    },
    banks = {
      [0] = { waveArchives = { 0, 0xFFFF, 0xFFFF, 0xFFFF } },
      [1] = { waveArchives = { 1, 0xFFFF, 0xFFFF, 0xFFFF } },
    },
    waveArchives = { [0] = {}, [1] = {} },
    players = { [0] = { maxSequences = 2, channelMask = 0xC000, heapSize = 0x5E88 } },
    extraFiles = 0,
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      rawset(spec, key, value)
    end
  end
  local _, layout = SdatFixture.build(spec)
  local sbnk0 = SbnkFixture.build({
    { type = 1, param = PCM_A },
    {
      type = 0x10,
      minKey = 35,
      maxKey = 37,
      leaves = { { type = 1, param = PCM_B }, { type = 1, param = PCM_A }, { type = 2, param = PSG_A } },
    },
    { type = 0x11, keys = { 48, 72 }, leaves = { { type = 1, param = PCM_A }, { type = 1, param = PCM_B } } },
    { type = 0 },
    { type = 2, param = PSG_A },
    { type = 3, param = NOISE_A },
    { type = 5, param = PCM_A },
  })
  local sbnk1 = SbnkFixture.build({
    {
      type = 1,
      param = { swav = 0, swarSlot = 0, rootKey = 60, attack = 127, decay = 0, sustain = 127, release = 127, pan = 64 },
    },
  })
  local swar0 = SwarFixture.build({ pcm8Member(), pcm16Member() })
  local swar1 = SwarFixture.build({ adpcmMember() })
  spec.payloads = {
    [layout.fileIds.sequences[0]] = sseq0Bytes(),
    [layout.fileIds.sequences[2]] = SseqFixture.build({
      { op = "program", program = 3 },
      { op = "note", key = 64, velocity = 100, duration = 48 },
      { op = "wait", duration = 24 },
      { op = "fin" },
    }),
    [layout.fileIds.banks[0]] = sbnk0,
    [layout.fileIds.banks[1]] = sbnk1,
    [layout.fileIds.waveArchives[0]] = swar0,
    [layout.fileIds.waveArchives[1]] = swar1,
  }
  return SdatFixture.build(spec)
end

local function fakeRomFs(bytes)
  return {
    _bytes = bytes,
    readSourcePath = function(self, path)
      Assert.equal(path, SDAT_PATH)
      return self._bytes
    end,
    metadata = function()
      return { sha1 = "fake-rom-sha1" }
    end,
    version = function()
      return "heartgold"
    end,
    fileIdForPath = function(_, path)
      Assert.equal(path, SDAT_PATH)
      return 123
    end,
  }
end

local function compileOrFail(bytes)
  local bundle, err = AudioCompiler.compile(fakeRomFs(bytes))
  Assert.notNil(bundle, "expected compile to succeed: " .. tostring(err and Errors.format(err) or "no error"))
  return assert(bundle)
end

local function directPcmArchive(instruments)
  local spec = {
    sequences = { [0] = { bankId = 0, volume = 120, channelPriority = 127, playerPriority = 64, playerId = 0 } },
    banks = { [0] = { waveArchives = { 0, 0xFFFF, 0xFFFF, 0xFFFF } } },
    waveArchives = { [0] = {} },
    players = { [0] = { maxSequences = 2, channelMask = 0xC000, heapSize = 0x5E88 } },
    extraFiles = 0,
  }
  local _, layout = SdatFixture.build(spec)
  spec.payloads = {
    [layout.fileIds.sequences[0]] = SseqFixture.build({ { op = "fin" } }),
    [layout.fileIds.banks[0]] = SbnkFixture.build(instruments),
    [layout.fileIds.waveArchives[0]] = SwarFixture.build({ pcm8Member() }),
  }
  return SdatFixture.build(spec)
end

local function assertUnsupportedDirectPcm(bytes)
  local bundle, err = AudioCompiler.compile(fakeRomFs(bytes))
  Assert.isNil(bundle, "DIRECTPCM must not compile as a SWAR sample")
  Assert.isTrue(Errors.is(err), "DIRECTPCM failure must be structured")
  err = assert(err)
  Assert.equal(err.code, "SBNK_UNSUPPORTED_INSTRUMENT")
  Assert.equal(err.context.bankId, 0)
  Assert.equal(err.context.type, 4)
end

function T.rejects_directpcm_before_wave_resolution()
  local direct = { type = 4, param = PCM_A }
  assertUnsupportedDirectPcm(directPcmArchive({ direct }))
  assertUnsupportedDirectPcm(directPcmArchive({
    {
      type = 0x10,
      minKey = 35,
      maxKey = 35,
      leaves = { direct },
    },
  }))
  assertUnsupportedDirectPcm(directPcmArchive({
    {
      type = 0x11,
      keys = { 35 },
      leaves = { direct },
    },
  }))
end

function T.keeps_dummy_leaves_silent_and_sample_free()
  local bundle = compileOrFail(directPcmArchive({
    { type = 1, param = PCM_A },
    { type = 5, param = PCM_A },
    {
      type = 0x10,
      minKey = 35,
      maxKey = 36,
      leaves = { { type = 5, param = PCM_A }, { type = 0, param = PCM_A } },
    },
    {
      type = 0x11,
      keys = { 35, 72 },
      leaves = { { type = 0, param = PCM_A }, { type = 1, param = PCM_A } },
    },
  }))
  local bank = bundle.banks[0]
  AudioBank.validate(bank)
  Assert.equal(bank.instruments[1].voice.kind, "dummy")
  Assert.equal(bank.instruments[2].voices[1].kind, "dummy")
  Assert.equal(bank.instruments[2].voices[2].kind, "dummy")
  Assert.equal(bank.instruments[3].ranges[1].voice.kind, "dummy")
  Assert.equal(bank.instruments[3].ranges[2].voice.generator.kind, "sample")
  local sampleCount = 0
  for _ in pairs(bundle.samples) do
    sampleCount = sampleCount + 1
  end
  Assert.equal(sampleCount, 1, "silent leaves add no sample references")
end

-- The full writer-shaped bundle: marker, index, dependencies, and the four
-- content sections, all consistent with the frozen audio contract.
function T.compiles_the_archive_into_a_complete_bundle()
  local bytes = buildArchive()
  local bundle = compileOrFail(bytes)
  local sdat = assert(Sdat.open(bytes, SDAT_PATH))

  Assert.isTrue(bundle.marker:sub(1, #AudioCache.FORMAT) == AudioCache.FORMAT, "marker carries the format")
  Assert.isTrue(bundle.marker:find("fake-rom-sha1", 1, true) ~= nil, "marker embeds the rom sha1")
  Assert.equal(bundle.index.schema, AudioCache.INDEX_SCHEMA)
  Assert.equal(bundle.index.version, "heartgold")

  Assert.deepEqual(bundle.index.sequences[0], {
    id = 0,
    symbol = "SEQ_0",
    bankId = 1,
    playerId = 0,
  })
  Assert.deepEqual(bundle.index.sequences[2], {
    id = 2,
    symbol = "SEQ_2",
    bankId = 0,
    playerId = 1,
  })
  Assert.deepEqual(bundle.index.banks[0], {
    id = 0,
    symbol = "BANK_0",
  })
  Assert.equal(bundle.index.players[0].maxSequences, 2)
  Assert.equal(bundle.index.players[0].channelMask, 0xC000)
  Assert.equal(bundle.index.sequenceBySymbol["SEQ_0"], 0)
  Assert.equal(bundle.index.sequenceBySymbol["SEQ_2"], 2)
  Assert.equal(bundle.index.bankBySymbol["BANK_0"], 0)
  local indexedSymbols = {}
  for _, map in ipairs({ bundle.index.sequenceBySymbol, bundle.index.bankBySymbol }) do
    for symbol in pairs(map) do
      indexedSymbols[symbol] = true
    end
  end
  Assert.isNil(indexedSymbols["WAVE_1"], "wave-archive symbols are not indexed")

  Assert.equal(bundle.dependencies.cacheFormat, AudioCache.FORMAT)
  Assert.equal(bundle.dependencies.versionRomSha1, "fake-rom-sha1")
  Assert.equal(bundle.dependencies.soundArchive.path, SDAT_PATH)
  Assert.equal(bundle.dependencies.soundArchive.fileId, 123)
  Assert.equal(bundle.dependencies.soundArchive.sha1, Hashing.sha1hex(bytes))
  Assert.equal(sdat.counts.sequences, 3, "the fixture archive has three sequence slots")
end

-- Sequences carry the INFO identity and player parameters, and branch
-- targets are instruction indices.
function T.compiles_sequences_with_index_targets()
  local bytes = buildArchive()
  local bundle = compileOrFail(bytes)
  local seq0 = bundle.sequences[0]
  AudioSequence.validate(seq0)
  Assert.equal(seq0.id, 0)
  Assert.equal(seq0.symbol, "SEQ_0")
  Assert.equal(seq0.bankId, 1)
  Assert.equal(seq0.player.id, 0)
  Assert.equal(seq0.player.initialVolume, 120)
  Assert.equal(seq0.player.playerPriority, 64)
  Assert.equal(seq0.player.channelPriority, 127)
  Assert.equal(seq0.program.initialTrackMask, 0x0003)

  Assert.equal(seq0.program.entry, 1, "entry is the header open-track record")
  local openTrack, jump, call
  for _, instruction in ipairs(seq0.program.instructions) do
    if instruction.op == "open_track" then
      openTrack = instruction
    elseif instruction.op == "jump" then
      jump = instruction
    elseif instruction.op == "call" then
      call = instruction
    end
  end
  Assert.notNil(openTrack, "open_track instruction present")
  Assert.equal(openTrack.track, 1)
  Assert.equal(openTrack.target, 5, "open-track target is an instruction index")
  Assert.notNil(jump, "jump instruction present")
  Assert.equal(jump.target, 3, "jump target is an instruction index")
  Assert.notNil(call, "call instruction present")
  Assert.equal(call.target, 5, "call target is an instruction index")

  local seq2 = bundle.sequences[2]
  AudioSequence.validate(seq2)
  Assert.equal(seq2.player.id, 1)
  Assert.equal(seq2.program.instructions[1].op, "program")
  Assert.equal(seq2.program.instructions[1].program, 3)
  Assert.equal(seq2.program.initialTrackMask, 0x0001)
end

-- Banks carry normalized instruments: sample voices reference content keys,
-- PSG duties become the discrete source duty index, drums and splits keep
-- their key ranges, and illegal records are dropped.
function T.compiles_banks_with_semantic_instruments()
  local bytes = buildArchive()
  local bundle = compileOrFail(bytes)
  local bank0 = bundle.banks[0]
  AudioBank.validate(bank0)
  Assert.equal(bank0.id, 0)

  Assert.isNil(bank0.instruments[3], "type-0 instrument is dropped")

  local direct = bank0.instruments[0]
  Assert.equal(direct.kind, "direct")
  Assert.deepEqual(direct.voice.generator, { kind = "sample", sample = PCM8_KEY })
  Assert.equal(direct.voice.originalKey, 60)
  Assert.deepEqual(direct.voice.envelope, { attack = 120, decay = 60, sustain = 80, release = 100 })
  Assert.equal(direct.voice.pan, 64)

  local drums = bank0.instruments[1]
  Assert.equal(drums.kind, "drum_set")
  Assert.equal(drums.lowKey, 35)
  Assert.equal(drums.highKey, 37)
  Assert.equal(#drums.voices, 3)
  Assert.equal(drums.voices[1].generator.kind, "sample")
  Assert.equal(drums.voices[3].generator.kind, "square")

  local split = bank0.instruments[2]
  Assert.equal(split.kind, "key_split")
  Assert.equal(#split.ranges, 2)
  Assert.deepEqual({ split.ranges[1].lowKey, split.ranges[1].highKey }, { 0, 48 })
  Assert.deepEqual({ split.ranges[2].lowKey, split.ranges[2].highKey }, { 49, 72 })

  -- Square and noise leaves carry their source original key like sample
  -- leaves: the common voice shape never drops it. The PSG duty is the
  -- discrete hardware index from the source record, never a fraction.
  Assert.equal(bank0.instruments[4].voice.generator.kind, "square")
  Assert.equal(bank0.instruments[4].voice.generator.duty, 3)
  Assert.equal(bank0.instruments[4].voice.originalKey, 48)
  Assert.equal(bank0.instruments[5].voice.generator.kind, "noise")
  Assert.equal(bank0.instruments[5].voice.originalKey, 60)
  Assert.deepEqual(bank0.instruments[6].voice, { kind = "dummy" })

  local bank1 = bundle.banks[1]
  AudioBank.validate(bank1)
  Assert.equal(bank1.instruments[0].voice.generator.sample, memberKey(adpcmMember()))
end

-- The compiled PSG duty is the source record's discrete index 0..7, never a
-- reconstructed fraction: every index survives verbatim, and index 7 is the
-- hardware all-LOW pattern, not 100% HIGH.
function T.psg_duty_is_the_source_index_with_seven_all_low()
  local sbnk = SbnkFixture.build({
    {
      type = 2,
      param = { swav = 0, rootKey = 60, attack = 127, decay = 0, sustain = 127, release = 127, pan = 64 },
    },
    {
      type = 2,
      param = { swav = 7, rootKey = 60, attack = 127, decay = 0, sustain = 127, release = 127, pan = 64 },
    },
  })
  local spec = {
    sequences = { [0] = { bankId = 0, volume = 120, channelPriority = 127, playerPriority = 64, playerId = 0 } },
    banks = { [0] = { waveArchives = { 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF } } },
    waveArchives = {},
    players = { [0] = { maxSequences = 2, channelMask = 0xC000, heapSize = 0x5E88 } },
    extraFiles = 0,
  }
  local _, layout = SdatFixture.build(spec)
  spec.payloads = {
    [layout.fileIds.sequences[0]] = SseqFixture.build({ { op = "fin" } }),
    [layout.fileIds.banks[0]] = sbnk,
  }
  local bundle = compileOrFail(SdatFixture.build(spec))
  local bank = bundle.banks[0]
  AudioBank.validate(bank)
  Assert.equal(bank.instruments[0].voice.generator.duty, 0, "the source duty index is preserved")
  Assert.equal(bank.instruments[1].voice.generator.duty, 7, "duty index 7 is the all-LOW hardware pattern")
end

-- Samples are content-addressed by their semantic identity: equal wave
-- content shares one key, every key has metadata and payload, and the
-- metadata matches the decoded frames and the wave's base timer.
function T.samples_deduplicate_by_content()
  local bytes = buildArchive()
  local bundle = compileOrFail(bytes)
  local keys = {}
  for key in pairs(bundle.samples) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  Assert.equal(#keys, 3, "three unique waves across both banks")

  for key, payload in pairs(bundle.samples) do
    local metadata = bundle.sampleMetadata[key]
    Assert.notNil(metadata)
    AudioSample.validate(metadata, payload)
    Assert.equal(metadata.key, key)
    Assert.isNil(metadata.file, "the payload path is derived from the content key, never stored")
    Assert.isNil(metadata.sampleRate, "the source rate never enters the derived sample metadata")
    Assert.equal(metadata.frames, math.floor(#payload / 2))
    Assert.isTrue(metadata.baseTimer > 0, "sample metadata carries the wave's base timer")
  end
  for key in pairs(bundle.sampleMetadata) do
    Assert.notNil(bundle.samples[key], "metadata without payload")
  end

  -- The split's first voice and the drum's second voice reference the same
  -- member as instrument 0 through different instrument paths.
  local bank0 = bundle.banks[0]
  Assert.equal(bank0.instruments[1].voices[2].generator.sample, PCM8_KEY)
  Assert.equal(bank0.instruments[2].ranges[1].voice.generator.sample, PCM8_KEY)
end

-- The sample key covers the complete runtime sample identity: the same
-- decoded PCM at a different base timer is a different sample, and so is the
-- same PCM with a different loop window. Key equality never aliases
-- observably different sounds.
function T.sample_keys_distinguish_metadata()
  local samples = { 1, 2, 3, 4, 5, 6, 7, 8 }
  local fast = SwarFixture.pcm16(samples, { sampleRate = 32000 })
  local slow = SwarFixture.pcm16(samples, { sampleRate = 24000 })
  local oneShot = SwarFixture.pcm16(samples, { sampleRate = 24000, loopFlag = 0 })
  local looped = SwarFixture.pcm16(samples, { sampleRate = 24000, loopFlag = 1, pnt = 2, len = 2 })
  local sbnk = SbnkFixture.build({
    {
      type = 1,
      param = { swav = 0, swarSlot = 0, rootKey = 60, attack = 127, decay = 0, sustain = 127, release = 127, pan = 64 },
    },
    {
      type = 1,
      param = { swav = 1, swarSlot = 0, rootKey = 60, attack = 127, decay = 0, sustain = 127, release = 127, pan = 64 },
    },
    {
      type = 1,
      param = { swav = 2, swarSlot = 0, rootKey = 60, attack = 127, decay = 0, sustain = 127, release = 127, pan = 64 },
    },
    {
      type = 1,
      param = { swav = 3, swarSlot = 0, rootKey = 60, attack = 127, decay = 0, sustain = 127, release = 127, pan = 64 },
    },
  })
  local swar = SwarFixture.build({ fast, slow, oneShot, looped })
  local spec = {
    sequences = { [0] = { bankId = 0, volume = 120, channelPriority = 127, playerPriority = 64, playerId = 0 } },
    banks = { [0] = { waveArchives = { 0, 0xFFFF, 0xFFFF, 0xFFFF } } },
    waveArchives = { [0] = {} },
    players = { [0] = { maxSequences = 2, channelMask = 0xC000, heapSize = 0x5E88 } },
    extraFiles = 0,
  }
  local _, layout = SdatFixture.build(spec)
  spec.payloads = {
    [layout.fileIds.sequences[0]] = SseqFixture.build({
      { op = "program", program = 0 },
      { op = "note", key = 60, velocity = 100, duration = 48 },
      { op = "fin" },
    }),
    [layout.fileIds.banks[0]] = sbnk,
    [layout.fileIds.waveArchives[0]] = swar,
  }
  local bundle = compileOrFail(SdatFixture.build(spec))
  local function keyFor(memberBytes)
    local wave = assert(Swav.decode(memberBytes, "fixture"))
    local key =
      AudioCompiler.sampleKey(wave.pcm16le, wave.baseTimer, wave.loopEnabled, wave.loop.startFrame, wave.loop.endFrame)
    Assert.notNil(bundle.samples[key], "the metadata-distinct sample is compiled")
    return key
  end
  local fastKey = keyFor(fast)
  Assert.isFalse(fastKey == keyFor(slow), "a different base timer is a different sample")
  Assert.isFalse(keyFor(oneShot) == keyFor(looped), "loop vs one-shot is a different sample")
  Assert.isTrue(fastKey == keyFor(fast), "the same identity always has the same key")
end

-- A valid archive without the optional SYMB block compiles: the index gains
-- no symbols, sequence/bank assets carry none, and the rest is unchanged.
function T.compiles_archives_without_symbols()
  local bytes = buildArchive({ symbols = false })
  local bundle = compileOrFail(bytes)
  Assert.equal(next(bundle.index.sequenceBySymbol), nil, "no sequence symbols without a SYMB block")
  Assert.equal(next(bundle.index.bankBySymbol), nil, "no bank symbols without a SYMB block")
  Assert.equal(bundle.sequences[0].symbol, nil)
  Assert.equal(bundle.banks[0].symbol, nil)
  AudioSequence.validate(bundle.sequences[0])
  AudioBank.validate(bundle.banks[0])
end

-- The symbol maps are per class: a symbol shared by a sequence and a bank
-- survives in both maps, so a cross-class collision is never ambiguous.
function T.symbols_colliding_across_classes_stay_unambiguous()
  local spec = {
    sequences = { [0] = { bankId = 0, volume = 120, channelPriority = 127, playerPriority = 64, playerId = 0 } },
    banks = { [0] = { waveArchives = { 0, 0xFFFF, 0xFFFF, 0xFFFF } } },
    waveArchives = { [0] = {} },
    players = { [0] = { maxSequences = 2, channelMask = 0xC000, heapSize = 0x5E88 } },
    symbolNames = {
      sequences = { [0] = "SHARED" },
      banks = { [0] = "SHARED" },
    },
    extraFiles = 0,
  }
  local sbnk0 = SbnkFixture.build({
    { type = 1, param = PCM_A },
  })
  local swar0 = SwarFixture.build({ pcm8Member(), pcm16Member() })
  local _, layout = SdatFixture.build(spec)
  spec.payloads = {
    [layout.fileIds.sequences[0]] = SseqFixture.build({
      { op = "program", program = 0 },
      { op = "note", key = 60, velocity = 100, duration = 48 },
      { op = "fin" },
    }),
    [layout.fileIds.banks[0]] = sbnk0,
    [layout.fileIds.waveArchives[0]] = swar0,
  }
  local bundle = compileOrFail(SdatFixture.build(spec))
  Assert.equal(bundle.index.sequenceBySymbol["SHARED"], 0)
  Assert.equal(bundle.index.bankBySymbol["SHARED"], 0)
  Assert.equal(bundle.sequences[0].symbol, "SHARED")
  Assert.equal(bundle.banks[0].symbol, "SHARED")
end

-- A malformed archive fails the compile with a structured error, never a
-- partial bundle.
function T.rejects_malformed_archives()
  local bytes, layout = buildArchive()
  local corrupted = SdatFixture.corrupt(bytes, layout, { magic = "XXXX" })
  local bundle, err = AudioCompiler.compile(fakeRomFs(corrupted))
  Assert.isNil(bundle)
  Assert.isTrue(Errors.is(err))
  Assert.equal(asError(err).code, "SDAT_BAD_MAGIC")
end

-- Compiling the same archive twice produces identical bundles.
function T.compilation_is_deterministic()
  local bytes = buildArchive()
  local first = compileOrFail(bytes)
  local second = compileOrFail(bytes)
  Assert.deepEqual(first, second)
end

-- Generation audio planning binds the catalog plan and the sound identity
-- to one archive observation: a single SDAT read yields the same plan the
-- standalone planner returns plus the identity of those exact bytes.
function T.source_planning_binds_plan_and_identity_to_one_archive_read()
  local bytes = buildArchive()
  local reads = 0
  local romFs = fakeRomFs(bytes)
  local realRead = romFs.readSourcePath
  romFs.readSourcePath = function(self, path)
    reads = reads + 1
    return realRead(self, path)
  end
  local planned = assert(AudioCompiler.planSource(romFs))
  Assert.equal(reads, 1, "plan and identity derive from one archive read")
  local legacy = assert(AudioCompiler.plan(fakeRomFs(bytes)))
  Assert.deepEqual(planned.plan, legacy, "source plan")
  Assert.equal(planned.identity.sdatSha1, Hashing.sha1hex(bytes), "identity hashes the observed bytes")
  Assert.equal(planned.identity.romSha1, "fake-rom-sha1", "identity carries the source ROM")
  Assert.equal(planned.identity.sdatFileId, 123, "identity carries the archive file")
end

return { tests = T }
