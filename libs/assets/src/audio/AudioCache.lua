-- Paths, contract constants, and strict readiness for the derived audio cache.
-- The audio class shares the per-version derived-cache identity with every
-- other derived class (the build-state identity includes the whole
-- DerivedAssetContract), so a sound-archive compiler change alone never
-- disturbs the raw ROM dump, and an audio contract change is not rebuildable
-- in isolation from the other classes. Readiness verifies more than the
-- completion marker: the exact marker and the authoritative cross-file walk
-- (AudioCacheValidator) over the index (schema and every runtime-required
-- section), every indexed sequence and bank (schema, identity, and index
-- agreement), and every bank-referenced sample's metadata and PCM payload. A
-- missing artifact is never interpreted as silence. Paths are
-- cache-relative; all IO goes through a CacheFs.

local AudioCache = {}

local Contract = require("libs.assets.src.DerivedAssetContract")

AudioCache.FORMAT = Contract.audio.cacheFormat
AudioCache.INDEX_SCHEMA = Contract.audio.indexSchema
AudioCache.SEQUENCE_SCHEMA = Contract.audio.sequenceSchema
AudioCache.BANK_SCHEMA = Contract.audio.bankSchema
AudioCache.SAMPLE_SCHEMA = Contract.audio.sampleSchema
AudioCache.PROVENANCE_SCHEMA = Contract.audio.provenanceSchema
AudioCache.BANK_COMPLETION_SCHEMA = "g4-audio-bank-complete-v1"

local DATA_DIR = "data/generated/audio"

function AudioCache.dir()
  return DATA_DIR
end
function AudioCache.indexPath()
  return DATA_DIR .. "/index.lua"
end
function AudioCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end
function AudioCache.markerPath()
  return DATA_DIR .. "/complete"
end

function AudioCache.sequencePath(id)
  return string.format("%s/sequences/%04d.lua", DATA_DIR, id)
end

function AudioCache.bankPath(id)
  return string.format("%s/banks/%04d.lua", DATA_DIR, id)
end

function AudioCache.samplePath(key)
  return string.format("%s/samples/%s.pcm16le", DATA_DIR, key)
end

function AudioCache.sampleMetadataPath(key)
  return string.format("%s/sample-metadata/%s.lua", DATA_DIR, key)
end

-- The per-bank completion record: progress metadata for one independently
-- staged bank closure, never a family readiness claim. It carries the
-- closure marker plus the bank and sequence selection the closure validated,
-- so bank readiness revalidates the exact closure without the family index.
function AudioCache.bankCompletePath(bankId)
  return string.format("%s/bank-complete/%s.lua", DATA_DIR, tostring(bankId))
end

function AudioCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", AudioCache.FORMAT, romSha1, depHash)
end

-- True only if the marker is exact and the authoritative cross-file walk
-- (AudioCacheValidator) finds no problem: the index schema and every
-- runtime-required section (sequences, banks, players, both symbol maps),
-- player-record validity (supported id range, integer U16 channel mask,
-- positive slot count for used players), index records carrying no stored
-- payload path, every indexed sequence/bank asset with its validator passing
-- and its identity agreeing with the index, sequence bank-id and player-id
-- resolution, bidirectional symbol-map consistency, and every
-- bank-referenced sample's metadata (schema, address-matching key) and PCM
-- payload. The validator requires this module for its paths, so it is loaded
-- here rather than at module scope (the walk is never needed before isReady
-- runs).
function AudioCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(AudioCache.markerPath()) ~= expectedMarker then
    return false
  end
  return require("libs.assets.src.audio.AudioCacheValidator").validate(cacheFs) == nil
end

-- True only if the bank's own completion marker is exact and the closure it
-- names revalidates: the bank asset with its validator passing and matching
-- identity, every named sequence asset with its validator passing and naming
-- this bank, and every bank-referenced sample's metadata and PCM payload. A
-- marker without its sequence/sample closure is never ready. The validator
-- requires this module for its paths, so it is loaded here rather than at
-- module scope. Reads staged or published files only; never source decoding.
---@param cacheFs CacheFs
---@param bankId integer
---@param expectedMarker string
---@return boolean
function AudioCache.isBankReady(cacheFs, bankId, expectedMarker)
  local completion = cacheFs:loadLua(AudioCache.bankCompletePath(bankId)) ---@type table?
  if type(completion) ~= "table" then
    return false
  end
  if completion.marker ~= expectedMarker then
    return false
  end
  if completion.schema ~= AudioCache.BANK_COMPLETION_SCHEMA or completion.bankId ~= bankId then
    return false
  end
  if type(completion.sequenceIds) ~= "table" then
    return false
  end
  for _, sequenceId in ipairs(completion.sequenceIds) do
    if type(sequenceId) ~= "number" or sequenceId % 1 ~= 0 or sequenceId < 0 then
      return false
    end
  end
  local sequenceIds = completion.sequenceIds ---@type integer[]
  return require("libs.assets.src.audio.AudioCacheValidator").validateBankClosure(cacheFs, bankId, sequenceIds) == nil
end

return AudioCache
