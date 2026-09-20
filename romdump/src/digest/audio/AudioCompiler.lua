-- Compiles the raw sound archive (data/sound/gs_sound_data.sdat) into the
-- derived audio bundle the cache writer consumes: every referenced sequence
-- lowers into the project instruction IR, every bank into semantic
-- instruments, and every referenced wave member decodes offline to
-- semantically content-addressed PCM16LE samples (decoded PCM + base timer +
-- loop identity) with engine-meaningful metadata. The
-- bundle carries the marker, the index (sequences/banks/players plus the
-- per-class symbol maps sequenceBySymbol/bankBySymbol; wave-archive symbols
-- are deliberately not indexed), the assets, the samples, and the dependency
-- pins; a malformed archive fails the whole compile with a structured error
-- (an unsupported command in a referenced sequence is a build failure, never
-- a placeholder). Catalog planning (plan) enumerates the deterministic
-- per-bank closures without lowering sequences or decoding waves, and
-- one-bank streaming compilation (compileBank) owns exactly one used bank,
-- the used sequences naming it, and their referenced sample closure: each
-- distinct source wave decodes once per job, its PCM streams through the
-- caller sink, and the returned bundle holds keys and metadata, never
-- retained PCM. Pure domain module; the marker and hashes are computed
-- through the injectable sha1hex/hashLua helpers like the other compilers.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local AudioCache = require("libs.assets.src.audio.AudioCache")
local Sdat = require("libs.nds.src.nitro.sound.Sdat")
local SequenceLowering = require("romdump.src.digest.audio.SequenceLowering")
local Sbnk = require("libs.nds.src.nitro.sound.Sbnk")
local Swar = require("libs.nds.src.nitro.sound.Swar")
local Swav = require("libs.nds.src.nitro.sound.Swav")

local AudioCompiler = {}

local SDAT_PATH = "data/sound/gs_sound_data.sdat"

---@class AudioCompiler.BankPlan
---@field bankId integer
---@field sequenceIds integer[]

---@class AudioCompiler.CatalogPlan
---@field index table<string, unknown>
---@field bankPlans AudioCompiler.BankPlan[]

---@class AudioCompiler.BankBundle
---@field bankId integer
---@field bank table<string, unknown>
---@field sequences table<integer, table<string, unknown>>
---@field sampleMetadata table<string, table<string, unknown>>
---@field samples table<string, string>?
---@field marker string
---@field dependencies table<string, unknown>

---@class AudioCompiler.SoundIdentity
---@field romSha1 string
---@field sdatSha1 string
---@field sdatFileId integer

---@alias AudioCompiler.SampleSink fun(key: string, metadata: table<string, unknown>, pcm16le: string)

local function must(value, err)
  if value == nil then
    error(err)
  end
  return value
end

local function leafKind(recordType)
  if recordType == Sbnk.TYPE_PCM then
    return "sample"
  end
  if recordType == Sbnk.TYPE_PSG then
    return "square"
  end
  assert(recordType == Sbnk.TYPE_NOISE, "leaf kind requires a playable leaf")
  return "noise"
end

local function rejectUnsupportedLeaf(leaf, bankId, location)
  if leaf.type == Sbnk.TYPE_DIRECTPCM then
    Errors.raise("SBNK_UNSUPPORTED_INSTRUMENT", "DIRECTPCM instruments are not supported", {
      bankId = bankId,
      location = location,
      type = Sbnk.TYPE_DIRECTPCM,
    })
  end
end

-- The semantic sample key: the canonical deterministic hash of the complete
-- runtime sample identity (decoded PCM, base timer, loop flag, loop window).
-- Two waves with identical PCM but different timers or loop regions are
-- observably different samples and must never alias under one key.
function AudioCompiler.sampleKey(pcm, baseTimer, loopEnabled, loopStartFrame, loopEndFrame)
  return Hashing.hashLua({
    pcm = pcm,
    baseTimer = baseTimer,
    loopEnabled = loopEnabled,
    loopStartFrame = loopStartFrame,
    loopEndFrame = loopEndFrame,
  })
end

-- Zero-based tables (leaves, keys) have no reliable #; count them instead.
local function countOf(t)
  local count = 0
  for _ in pairs(t) do
    count = count + 1
  end
  return count
end

-- The semantic voice for a direct/leaf record. Sample voices resolve their
-- wave member through the job wave cache (decode once per member, dedupe
-- by semantic identity); PSG duties carry the discrete DS
-- duty index 0..7 from the source record (GBATEK: the SNDInstParam swav
-- field selects the hardware duty pattern, index 7 the all-LOW special
-- pattern); noise is a bare generator. Every leaf carries its source
-- original key, so the common voice shape never drops it for square/noise.
local function voiceFromLeaf(leaf, waveCache, bankId, waveArchives)
  if leaf.type == Sbnk.TYPE_ILLEGAL or leaf.type == Sbnk.TYPE_DUMMY then
    return { kind = "dummy" }
  end
  local kind = leafKind(leaf.type)
  local voice = {
    originalKey = leaf.param.rootKey,
    envelope = {
      attack = leaf.param.attack,
      decay = leaf.param.decay,
      sustain = leaf.param.sustain,
      release = leaf.param.release,
    },
    pan = leaf.param.pan,
  }
  if kind == "sample" then
    voice.generator = {
      kind = "sample",
      sample = waveCache:resolve(bankId, waveArchives, leaf.param.swarSlot, leaf.param.swav),
    }
  elseif kind == "square" then
    voice.generator = { kind = "square", duty = leaf.param.swav % 8 }
  else
    voice.generator = { kind = "noise" }
  end
  return voice
end

-- Job-local wave resolution: maps an instrument's swar slot through the bank
-- record's wave-archive slots to the SDAT wave archives, decodes each
-- referenced member exactly once per job, and streams its PCM through the
-- staging sink. The sink consumes the bytes synchronously; the job retains
-- only the parsed archive views and the small source-identity to semantic
-- key mapping plus the keyed metadata, never decoded PCM.
local WaveCache = {}
WaveCache.__index = WaveCache

---@param sdat table<string, unknown>
---@param sampleSink AudioCompiler.SampleSink
---@return table<string, unknown>
function WaveCache.new(sdat, sampleSink)
  assert(type(sampleSink) == "function", "streaming wave resolution requires a sample sink")
  return setmetatable({
    sdat = sdat,
    sampleSink = sampleSink,
    swars = {},
    decoded = {},
    sampleMetadata = {},
  }, WaveCache)
end

-- The decoded SWAR for a wave-archive id, decoded once and cached. Always
-- returns a usable archive or raises.
---@param waveId integer
---@param bankId integer
---@param slot integer
---@return table<string, unknown>
function WaveCache:swarFor(waveId, bankId, slot)
  local swar = self.swars[waveId]
  if swar ~= nil then
    return swar
  end
  local record = self.sdat.waveArchives[waveId]
  if record == nil or record.fileId == nil then
    Errors.raise("BANK_WAVE_ARCHIVE_UNUSED", "bank references an unused wave-archive record", {
      bankId = bankId,
      slot = slot,
      waveId = waveId,
    })
  end
  record = assert(record)
  local fileId = assert(record.fileId)
  local bytes = must(self.sdat:readFile(fileId))
  local parsed, err = Swar.decode(bytes, "SWAR " .. waveId)
  if parsed == nil then
    err = assert(err)
    err.context.bankId = bankId
    err.context.waveId = waveId
    error(err)
  end
  parsed = assert(parsed)
  self.swars[waveId] = parsed
  return parsed
end

---@param bankId integer
---@param waveArchives table<integer, integer>
---@param slot integer
---@param member integer
---@return string
function WaveCache:resolve(bankId, waveArchives, slot, member)
  local waveId = waveArchives[slot]
  if waveId == nil then
    Errors.raise("BANK_WAVE_SLOT_UNASSIGNED", "instrument references an unassigned wave-archive slot", {
      bankId = bankId,
      slot = slot,
    })
  end
  waveId = assert(waveId)
  local swar = self:swarFor(waveId, bankId, slot)
  local sourceKey = waveId .. ":" .. member
  local key = self.decoded[sourceKey]
  if key == nil then
    local memberBytes, memberErr = swar:readMember(member)
    if memberBytes == nil then
      memberErr = assert(memberErr)
      memberErr.context.bankId = bankId
      memberErr.context.waveId = waveId
      error(memberErr)
    end
    local wave, waveErr = Swav.decode(memberBytes, "SWAV " .. waveId .. ":" .. member)
    if wave == nil then
      waveErr = assert(waveErr)
      waveErr.context.bankId = bankId
      waveErr.context.waveId = waveId
      waveErr.context.member = member
      error(waveErr)
    end
    key =
      AudioCompiler.sampleKey(wave.pcm16le, wave.baseTimer, wave.loopEnabled, wave.loop.startFrame, wave.loop.endFrame)
    self.decoded[sourceKey] = key
    if self.sampleMetadata[key] == nil then
      -- The derived metadata carries only runtime-relevant identity: the
      -- content key (the payload path is derived from it), the frame count,
      -- the DS base timer, and the loop window. The source sample rate never
      -- enters the derived shape (playback derives from the DS sound clock
      -- and the calculated timer).
      self.sampleMetadata[key] = {
        schema = AudioCache.SAMPLE_SCHEMA,
        key = key,
        frames = wave.frames,
        baseTimer = wave.baseTimer,
        loopEnabled = wave.loopEnabled,
        loop = wave.loop,
      }
    end
    -- One source wave streams once: the sink stages the bytes synchronously
    -- and the decoded PCM is discarded before the next wave decodes. A new
    -- source identity with an already seen semantic key streams its identical
    -- bytes again; shared staged paths deduplicate at publication.
    self.sampleSink(key, self.sampleMetadata[key], wave.pcm16le)
  end
  return key
end

local function compileSequence(sdat, symbols, id, record)
  local bytes = must(sdat:readFile(record.fileId))
  local symbol = symbols.sequences[id]
  local program, err = SequenceLowering.lower(bytes, { sequenceId = id, symbol = symbol }, "SSEQ " .. id)
  if program == nil then
    error(err)
  end
  return {
    schema = AudioCache.SEQUENCE_SCHEMA,
    id = id,
    symbol = symbol,
    bankId = record.bankId,
    player = {
      id = record.playerId,
      initialVolume = record.volume,
      playerPriority = record.playerPriority,
      channelPriority = record.channelPriority,
    },
    program = program,
  }
end

local function compileBankRecord(sdat, symbols, id, record, waveCache)
  local bytes = must(sdat:readFile(record.fileId))
  local ir, err = Sbnk.decode(bytes, "SBNK " .. id)
  if ir == nil then
    err = assert(err)
    err.context.bankId = id
    error(err)
  end
  local instruments = {}
  for program, inst in pairs(ir.instruments) do
    if
      inst.type == Sbnk.TYPE_PCM
      or inst.type == Sbnk.TYPE_PSG
      or inst.type == Sbnk.TYPE_NOISE
      or inst.type == Sbnk.TYPE_DUMMY
    then
      instruments[program] = {
        kind = "direct",
        voice = voiceFromLeaf(inst, waveCache, id, record.waveArchives),
      }
    elseif inst.type == Sbnk.TYPE_DIRECTPCM then
      rejectUnsupportedLeaf(inst, id, "program " .. tostring(program))
    elseif inst.type == Sbnk.TYPE_DRUM_SET then
      local voices = {}
      for key = inst.minKey, inst.maxKey do
        local leaf = inst.leaves[key - inst.minKey]
        rejectUnsupportedLeaf(leaf, id, "program " .. tostring(program) .. " key " .. tostring(key))
        voices[#voices + 1] = voiceFromLeaf(leaf, waveCache, id, record.waveArchives)
      end
      instruments[program] = {
        kind = "drum_set",
        lowKey = inst.minKey,
        highKey = inst.maxKey,
        voices = voices,
      }
    else
      -- The SDK selects a key-split leaf by walking the split keys until
      -- midiKey <= key[i]; a later key smaller than the running high is
      -- unreachable (its window is empty), so only the monotonic ranges
      -- become asset ranges.
      local ranges = {}
      local prevHigh = -1
      for i = 0, countOf(inst.leaves) - 1 do
        local leaf = inst.leaves[i]
        local high = inst.keys[i]
        if high > prevHigh then
          rejectUnsupportedLeaf(leaf, id, "program " .. tostring(program) .. " leaf " .. tostring(i))
          ranges[#ranges + 1] = {
            lowKey = prevHigh + 1,
            highKey = high,
            voice = voiceFromLeaf(leaf, waveCache, id, record.waveArchives),
          }
          prevHigh = high
        end
      end
      instruments[program] = { kind = "key_split", ranges = ranges }
    end
  end
  return {
    schema = AudioCache.BANK_SCHEMA,
    id = id,
    symbol = symbols.banks[id],
    instruments = instruments,
  }
end

---@param romFs table<string, unknown>
---@return string
local function openSdatBytes(romFs)
  assert(
    romFs and romFs.readSourcePath and romFs.metadata and romFs.version and romFs.fileIdForPath,
    "audio planning and compilation require a RomFs-shaped object"
  )
  return must(romFs:readSourcePath(SDAT_PATH))
end

---@param sdatBytes string
---@return table<string, unknown>
local function openSdat(sdatBytes)
  local sdat, sdatErr = Sdat.open(sdatBytes, SDAT_PATH)
  if sdat == nil then
    error(sdatErr)
  end
  return assert(sdat)
end

---@param sdat table<string, unknown>
---@return table<string, table<string, unknown>>
local function catalogSymbols(sdat)
  -- The SYMB block is optional; without it the compile emits no symbols.
  -- The fallback mirrors Sdat's symbol-section shape with empty sections.
  return sdat.symbols
    or {
      sequences = {},
      sequenceArchives = {},
      banks = {},
      waveArchives = {},
      players = {},
      groups = {},
      streamPlayers = {},
      streams = {},
    }
end

-- The normalized catalog metadata both planning and compilation share: the
-- existing sequence/bank/player/symbol sections, built without lowering
-- sequences or decoding waves.
---@param sdat table<string, unknown>
---@param symbols table<string, table<string, unknown>>
---@param version string
---@return table<string, unknown>
local function buildIndex(sdat, symbols, version)
  local indexSequences = {}
  local indexBanks = {}
  local sequenceBySymbol = {}
  local bankBySymbol = {}

  for id = 0, sdat.counts.sequences - 1 do
    local record = sdat.sequences[id]
    if record.fileId ~= nil then
      local symbol = symbols.sequences[id]
      indexSequences[id] = {
        id = id,
        symbol = symbol,
        bankId = record.bankId,
        playerId = record.playerId,
      }
      if symbol ~= nil then
        sequenceBySymbol[symbol] = id
      end
    end
  end

  for id = 0, sdat.counts.banks - 1 do
    local record = sdat.banks[id]
    if record.fileId ~= nil then
      local symbol = symbols.banks[id]
      indexBanks[id] = {
        id = id,
        symbol = symbol,
      }
      if symbol ~= nil then
        bankBySymbol[symbol] = id
      end
    end
  end

  -- The index players section mirrors the runtime-relevant INFO player
  -- fields: used slots carry maxSequences/channelMask (the archive-declared
  -- per-player slot count and the hardware channel mask), unused slots stay
  -- id-only records. heapSize is a source heap-budget fact with no runtime
  -- consumer, so it stays in the parser, not in the derived index.
  local players = {}
  for id = 0, sdat.counts.players - 1 do
    local record = sdat.players[id]
    players[id] = {
      id = id,
      maxSequences = record.maxSequences,
      channelMask = record.channelMask,
    }
  end

  return {
    schema = AudioCache.INDEX_SCHEMA,
    version = version,
    sequences = indexSequences,
    banks = indexBanks,
    players = players,
    sequenceBySymbol = sequenceBySymbol,
    bankBySymbol = bankBySymbol,
  }
end

-- The deterministic bank closures: one plan per used bank with the ascending
-- used sequences naming it. A used sequence naming an absent or unused bank
-- fails loudly with both identities; it is never silently omitted.
---@param sdat table<string, unknown>
---@return AudioCompiler.BankPlan[]
local function planClosures(sdat)
  local usedBanks = {}
  for id = 0, sdat.counts.banks - 1 do
    local record = sdat.banks[id]
    if record ~= nil and record.fileId ~= nil then
      usedBanks[id] = true
    end
  end
  local owned = {}
  for id = 0, sdat.counts.sequences - 1 do
    local record = sdat.sequences[id]
    if record ~= nil and record.fileId ~= nil then
      if not usedBanks[record.bankId] then
        Errors.raise(
          "SEQUENCE_BANK_UNRESOLVED",
          "used sequence names an absent or unused bank",
          { sequenceId = id, bankId = record.bankId }
        )
      end
      if owned[record.bankId] == nil then
        owned[record.bankId] = {}
      end
      local sequenceIds = owned[record.bankId]
      sequenceIds[#sequenceIds + 1] = id
    end
  end
  local plans = {}
  for id = 0, sdat.counts.banks - 1 do
    if usedBanks[id] then
      plans[#plans + 1] = { bankId = id, sequenceIds = owned[id] or {} }
    end
  end
  return plans
end

--- One archive observation yielding both the catalog plan and the sound
--- identity: a single SDAT read/open binds both records to the same bytes.
---@param romFs table<string, unknown>
---@return { plan: AudioCompiler.CatalogPlan, identity: AudioCompiler.SoundIdentity }
local function _planSource(romFs)
  local sdatBytes = openSdatBytes(romFs)
  local sdat = openSdat(sdatBytes)
  local symbols = catalogSymbols(sdat)
  return {
    plan = {
      index = buildIndex(sdat, symbols, romFs:version()),
      bankPlans = planClosures(sdat),
    },
    identity = {
      romSha1 = romFs:metadata().sha1,
      sdatSha1 = Hashing.sha1hex(sdatBytes),
      sdatFileId = romFs:fileIdForPath(SDAT_PATH),
    },
  }
end

-- The source identity the derived audio binds: the version ROM identity and
-- the sound archive bytes identity behind one read.
---@param romFs table<string, unknown>
---@return AudioCompiler.SoundIdentity
local function _soundIdentity(romFs)
  local sdatBytes = openSdatBytes(romFs)
  return {
    romSha1 = romFs:metadata().sha1,
    sdatSha1 = Hashing.sha1hex(sdatBytes),
    sdatFileId = romFs:fileIdForPath(SDAT_PATH),
  }
end

-- The deterministic completion marker for one bank closure: the sound
-- identity plus the closure's bank and sequence selection. Equal selections
-- over equal source repair to the same marker.
---@param identity AudioCompiler.SoundIdentity
---@param bankPlan AudioCompiler.BankPlan
---@return string
local function bankMarkerFor(identity, bankPlan)
  assert(type(identity.romSha1) == "string" and identity.romSha1 ~= "", "bank markers require the ROM identity")
  assert(type(identity.sdatSha1) == "string" and identity.sdatSha1 ~= "", "bank markers require the archive identity")
  assert(
    type(identity.sdatFileId) == "number" and identity.sdatFileId % 1 == 0,
    "bank markers require the archive file identity"
  )
  assert(type(bankPlan.bankId) == "number" and bankPlan.bankId % 1 == 0, "bank markers require a bank identity")
  assert(type(bankPlan.sequenceIds) == "table", "bank markers require the closure sequence selection")
  return AudioCache.marker(
    identity.romSha1,
    Hashing.hashLua({
      cacheFormat = AudioCache.FORMAT,
      versionRomSha1 = identity.romSha1,
      soundArchive = {
        path = SDAT_PATH,
        fileId = identity.sdatFileId,
        sha1 = identity.sdatSha1,
      },
      bankId = bankPlan.bankId,
      sequenceIds = bankPlan.sequenceIds,
    })
  )
end

---@param bankPlan unknown
---@return AudioCompiler.BankPlan
local function checkBankPlan(bankPlan)
  assert(type(bankPlan) == "table", "one-bank compilation requires a bank closure plan")
  ---@cast bankPlan AudioCompiler.BankPlan
  assert(
    type(bankPlan.bankId) == "number" and bankPlan.bankId % 1 == 0 and bankPlan.bankId >= 0,
    "a bank closure plan carries an invalid bankId"
  )
  assert(type(bankPlan.sequenceIds) == "table", "a bank closure plan carries no sequence selection")
  for position, sequenceId in ipairs(bankPlan.sequenceIds) do
    assert(
      type(sequenceId) == "number" and sequenceId % 1 == 0 and sequenceId >= 0,
      "a bank closure plan carries an invalid sequenceId at position " .. position
    )
  end
  return bankPlan
end

local function _compileBank(romFs, bankPlan, sampleSink)
  local ownedPlan = checkBankPlan(bankPlan)
  assert(type(sampleSink) == "function", "one-bank compilation requires a sample sink")
  local sdatBytes = openSdatBytes(romFs)
  local sdat = openSdat(sdatBytes)
  local symbols = catalogSymbols(sdat)
  -- Open the archive once, then compile the single closure against it: the
  -- marker binds the bytes already in hand, so no second archive read.
  local ok, bank, sequences, sampleMetadata = pcall(function()
    local record = sdat.banks[ownedPlan.bankId]
    if record == nil or record.fileId == nil then
      Errors.raise("BANK_UNUSED", "one-bank compilation names an absent or unused bank", { bankId = ownedPlan.bankId })
    end
    for _, sequenceId in ipairs(ownedPlan.sequenceIds) do
      local sequence = sdat.sequences[sequenceId]
      if sequence == nil or sequence.fileId == nil or sequence.bankId ~= ownedPlan.bankId then
        Errors.raise(
          "SEQUENCE_BANK_MISMATCH",
          "planned sequence is not a used record of this bank",
          { sequenceId = sequenceId, bankId = ownedPlan.bankId }
        )
      end
    end
    local cache = WaveCache.new(sdat, sampleSink)
    local compiledBank = compileBankRecord(sdat, symbols, ownedPlan.bankId, record, cache)
    local compiledSequences = {}
    for _, sequenceId in ipairs(ownedPlan.sequenceIds) do
      compiledSequences[sequenceId] = compileSequence(sdat, symbols, sequenceId, sdat.sequences[sequenceId])
    end
    return compiledBank, compiledSequences, cache.sampleMetadata
  end)
  if not ok then
    error(bank, 0)
  end
  local identity = {
    romSha1 = romFs:metadata().sha1,
    sdatSha1 = Hashing.sha1hex(sdatBytes),
    sdatFileId = romFs:fileIdForPath(SDAT_PATH),
  }
  return {
    bankId = ownedPlan.bankId,
    bank = bank,
    sequences = sequences,
    sampleMetadata = sampleMetadata,
    marker = bankMarkerFor(identity, ownedPlan),
    dependencies = {
      cacheFormat = AudioCache.FORMAT,
      versionRomSha1 = identity.romSha1,
      soundArchive = {
        path = SDAT_PATH,
        fileId = identity.sdatFileId,
        sha1 = identity.sdatSha1,
      },
    },
  }
end

local function _compile(romFs, sha1hex, hashLua)
  assert(
    romFs and romFs.readSourcePath and romFs.metadata and romFs.version and romFs.fileIdForPath,
    "compile requires a RomFs-shaped object"
  )
  sha1hex = sha1hex or Hashing.sha1hex
  hashLua = hashLua or Hashing.hashLua

  local sdatBytes = must(romFs:readSourcePath(SDAT_PATH))
  local sdat = openSdat(sdatBytes)
  local symbols = catalogSymbols(sdat)
  -- One closure at a time: each bank compiles through its own job-local
  -- wave cache whose decoded PCM is discarded after its samples stream into
  -- the aggregate maps. No corpus-wide decoded-wave dictionary is retained.
  local catalog = {
    index = buildIndex(sdat, symbols, romFs:version()),
    bankPlans = planClosures(sdat),
  }

  local sequences = {}
  local banks = {}
  local samples = {}
  local sampleMetadata = {}
  for _, bankPlan in ipairs(catalog.bankPlans) do
    local collected = {}
    local collectedMetadata = {}
    local waveCache = WaveCache.new(sdat, function(key, metadata, pcm)
      if collected[key] == nil then
        collected[key] = pcm
        collectedMetadata[key] = metadata
      else
        assert(collected[key] == pcm, "a repeated semantic sample streams identical bytes")
      end
    end)
    local record = sdat.banks[bankPlan.bankId]
    banks[bankPlan.bankId] = compileBankRecord(sdat, symbols, bankPlan.bankId, assert(record), waveCache)
    for _, sequenceId in ipairs(bankPlan.sequenceIds) do
      sequences[sequenceId] = compileSequence(sdat, symbols, sequenceId, sdat.sequences[sequenceId])
    end
    for key, pcm in pairs(collected) do
      if samples[key] == nil then
        samples[key] = pcm
        sampleMetadata[key] = collectedMetadata[key]
      end
    end
  end

  local dependencies = {
    cacheFormat = AudioCache.FORMAT,
    versionRomSha1 = romFs:metadata().sha1,
    soundArchive = {
      path = SDAT_PATH,
      fileId = romFs:fileIdForPath(SDAT_PATH),
      sha1 = sha1hex(sdatBytes),
    },
  }

  local marker = AudioCache.marker(romFs:metadata().sha1, hashLua(dependencies))
  return {
    marker = marker,
    index = catalog.index,
    sequences = sequences,
    banks = banks,
    samples = samples,
    sampleMetadata = sampleMetadata,
    dependencies = dependencies,
  }
end

-- Plans the deterministic bank closures without lowering sequences or
-- decoding waves and binds the sound identity from the same single archive
-- observation: the normalized catalog metadata plus one plan per used bank
-- with its ascending used sequences. Producer-internal: generation
-- scheduling owns the one planning pass per source; leaf jobs consume the
-- published record. A used sequence naming an absent or unused bank fails
-- with both identities.
---@param romFs table<string, unknown>
---@return { plan: AudioCompiler.CatalogPlan, identity: AudioCompiler.SoundIdentity }?|nil
---@return Errors.Error?|nil
function AudioCompiler.planSource(romFs)
  local ok, result = pcall(_planSource, romFs)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

-- The catalog plan alone, derived through the same single observation as
-- the sound identity. Preserves the standalone planning contract.
---@param romFs table<string, unknown>
---@return AudioCompiler.CatalogPlan?|nil
---@return Errors.Error?|nil
function AudioCompiler.plan(romFs)
  local planned, err = AudioCompiler.planSource(romFs)
  if planned == nil then
    return nil, err
  end
  return planned.plan
end

-- Reads the sound source identity the derived audio binds. One archive read;
-- batch clients read it once and derive every closure marker from it.
---@param romFs table<string, unknown>
---@return AudioCompiler.SoundIdentity?|nil
---@return Errors.Error?|nil
function AudioCompiler.soundIdentity(romFs)
  local ok, result = pcall(_soundIdentity, romFs)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

-- The deterministic completion marker for one bank closure over an already
-- read source identity. Pure: equal selections over equal source repair to
-- the same marker.
---@param identity AudioCompiler.SoundIdentity
---@param bankPlan AudioCompiler.BankPlan
---@return string
function AudioCompiler.bankMarker(identity, bankPlan)
  assert(type(identity) == "table", "bank markers require the sound source identity")
  return bankMarkerFor(identity, checkBankPlan(bankPlan))
end

-- Compiles exactly one bank closure: the bank record, the planned sequences,
-- and their referenced samples. Each distinct source wave decodes once in
-- this job and streams its PCM through the sink, which must consume the
-- bytes synchronously; the returned bundle holds the bank, the sequences,
-- and the small keyed sample metadata, never retained PCM.
---@param romFs table<string, unknown>
---@param bankPlan AudioCompiler.BankPlan
---@param sampleSink AudioCompiler.SampleSink
---@return AudioCompiler.BankBundle?|nil
---@return Errors.Error?|nil
function AudioCompiler.compileBank(romFs, bankPlan, sampleSink)
  local ok, result = pcall(_compileBank, romFs, bankPlan, sampleSink)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

---@param romFs table<string, unknown>
---@param sha1hex? fun(bytes: string): string
---@param hashLua? fun(value: unknown): string
---@return table<string, unknown>?|nil
---@return Errors.Error?|nil
function AudioCompiler.compile(romFs, sha1hex, hashLua)
  local ok, result = pcall(_compile, romFs, sha1hex, hashLua)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

return AudioCompiler
