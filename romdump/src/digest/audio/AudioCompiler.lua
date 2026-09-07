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
-- a placeholder). Pure domain module; the marker and hashes are computed
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
-- wave member through the shared wave cache (decode once per member, dedupe
-- by semantic identity across every bank); PSG duties carry the discrete DS
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

-- Shared wave resolution: maps an instrument's swar slot through the bank
-- record's wave-archive slots to the SDAT wave archives, decodes each
-- referenced member exactly once, and dedupes samples by content key into
-- the bundle's global sample maps.
local WaveCache = {}
WaveCache.__index = WaveCache

function WaveCache.new(sdat)
  return setmetatable({
    sdat = sdat,
    swars = {},
    decoded = {},
    samples = {},
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
  local key = self.decoded[waveId .. ":" .. member]
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
    self.decoded[waveId .. ":" .. member] = key
    if self.samples[key] == nil then
      self.samples[key] = wave.pcm16le
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

local function compileBank(sdat, symbols, id, record, waveCache)
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

local function _compile(romFs, sha1hex, hashLua)
  assert(
    romFs and romFs.readSourcePath and romFs.metadata and romFs.version and romFs.fileIdForPath,
    "compile requires a RomFs-shaped object"
  )
  sha1hex = sha1hex or Hashing.sha1hex
  hashLua = hashLua or Hashing.hashLua

  local sdatBytes = must(romFs:readSourcePath(SDAT_PATH))
  local sdat, sdatErr = Sdat.open(sdatBytes, SDAT_PATH)
  if sdat == nil then
    error(sdatErr)
  end
  sdat = assert(sdat)
  -- The SYMB block is optional; without it the compile emits no symbols.
  -- The fallback mirrors Sdat's symbol-section shape with empty sections.
  local symbols = sdat.symbols
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
  local waveCache = WaveCache.new(sdat)

  local sequences = {}
  local indexSequences = {}
  local banks = {}
  local indexBanks = {}
  local sequenceBySymbol = {}
  local bankBySymbol = {}

  for id = 0, sdat.counts.sequences - 1 do
    local record = sdat.sequences[id]
    if record.fileId ~= nil then
      local sequence = compileSequence(sdat, symbols, id, record)
      sequences[id] = sequence
      indexSequences[id] = {
        id = id,
        symbol = sequence.symbol,
        bankId = record.bankId,
        playerId = record.playerId,
      }
      if sequence.symbol ~= nil then
        sequenceBySymbol[sequence.symbol] = id
      end
    end
  end

  for id = 0, sdat.counts.banks - 1 do
    local record = sdat.banks[id]
    if record.fileId ~= nil then
      local bank = compileBank(sdat, symbols, id, record, waveCache)
      banks[id] = bank
      indexBanks[id] = {
        id = id,
        symbol = bank.symbol,
      }
      if bank.symbol ~= nil then
        bankBySymbol[bank.symbol] = id
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

  local index = {
    schema = AudioCache.INDEX_SCHEMA,
    version = romFs:version(),
    sequences = indexSequences,
    banks = indexBanks,
    players = players,
    sequenceBySymbol = sequenceBySymbol,
    bankBySymbol = bankBySymbol,
  }

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
    index = index,
    sequences = sequences,
    banks = banks,
    samples = waveCache.samples,
    sampleMetadata = waveCache.sampleMetadata,
    dependencies = dependencies,
  }
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
