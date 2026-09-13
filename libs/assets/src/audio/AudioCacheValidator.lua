-- The one authoritative cross-file bundle/reference walk for the derived
-- audio cache: index -> sequence -> bank -> sample metadata -> payload. Both
-- AudioCache.isReady and AudioCacheWriter's staged readback run this walk, so
-- readiness and the write gate can never drift apart; there is no second
-- inspection vocabulary. The walk is content-only: it returns nil when the
-- cache is valid or a problem message otherwise, never raises (the leaf
-- validators' structured errors are converted into problems). It verifies
-- every runtime-required index section -- sequences, banks, players, and both
-- symbol maps -- including player-record fields (supported id range, the
-- integer U16 channel mask, and a positive slot count for every player a
-- sequence references), index records carrying no stored payload path (all
-- paths derive from the numeric id), sequence player/bank resolution,
-- index/asset identity agreement, and bidirectional symbol-map consistency,
-- but never filesystem orphans. The completion marker is the caller's
-- business (isReady checks it first; the writer writes it last). Pure domain
-- module.

local AudioCache = require("libs.assets.src.audio.AudioCache")
local AudioSequence = require("libs.assets.src.audio.AudioSequence")
local AudioBank = require("libs.assets.src.audio.AudioBank")
local AudioSample = require("libs.assets.src.audio.AudioSample")

local AudioCacheValidator = {}

---@class AudioCacheValidator.IndexEntry
---@field id integer
---@field symbol string?
---@field bankId integer?
---@field playerId integer?
---@field channelMask integer?
---@field maxSequences integer?
---@field file string?

---@class AudioCacheValidator.Index
---@field schema string
---@field sequences table<integer, AudioCacheValidator.IndexEntry>
---@field banks table<integer, AudioCacheValidator.IndexEntry>
---@field players table<integer, AudioCacheValidator.IndexEntry>
---@field sequenceBySymbol table<string, integer>
---@field bankBySymbol table<string, integer>

-- The logical SDAT player table contains 32 groups. Physical sequence-player
-- slots are a separate runtime namespace and do not constrain this index.
local LOGICAL_PLAYER_COUNT = 32

-- Runs a leaf validator that raises on malformed assets, reporting failure as
-- a problem instead of propagating.
---@param validate fun(value: table<string, unknown>): boolean
---@param ... table<string, unknown>
---@return boolean
local function passes(validate, ...)
  local ok = pcall(validate, ...)
  return ok
end

---@param id number
---@return boolean
local function isIndexId(id)
  return type(id) == "number" and id >= 0 and id % 1 == 0
end

---@param value number
---@return boolean
local function isU16(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 0xFFFF
end

---@param value number
---@return boolean
local function isPositiveInteger(value)
  return type(value) == "number" and value % 1 == 0 and value >= 1
end

-- Every index entry of `section` is a self-identifying table under its own
-- nonnegative integer id.
---@param section table<integer, AudioCacheValidator.IndexEntry>
---@param name string
---@return string? problem
local function sectionProblem(section, name)
  for id, rawEntry in pairs(section) do
    local entry = rawEntry
    if not isIndexId(id) or type(entry) ~= "table" or entry.id ~= id then
      return name .. " index entry is malformed"
    end
  end
  return nil
end

-- The symbol map and the indexed symbols must describe each other in both
-- directions: every map entry resolves into `section` and agrees on its
-- symbol, and every indexed symbol (when present) has a map entry back.
---@param section table<integer, AudioCacheValidator.IndexEntry>
---@param symbolMap table<string, integer>
---@param name string
---@return string? problem
local function symbolMapProblem(section, symbolMap, name)
  for symbol, id in pairs(symbolMap) do
    local entry = section[id]
    if entry == nil or entry.symbol ~= symbol then
      return name .. " symbol map does not resolve"
    end
  end
  for _, rawEntry in pairs(section) do
    local entry = rawEntry
    if entry.symbol ~= nil and symbolMap[entry.symbol] ~= entry.id then
      return name .. " indexed symbol is not covered by the symbol map"
    end
  end
  return nil
end

local function validateIndexRoot(index)
  if type(index) ~= "table" or index.schema ~= AudioCache.INDEX_SCHEMA then
    return "index is missing or carries an unexpected schema"
  end
  if
    type(index.sequences) ~= "table"
    or type(index.banks) ~= "table"
    or type(index.players) ~= "table"
    or type(index.sequenceBySymbol) ~= "table"
    or type(index.bankBySymbol) ~= "table"
  then
    return "index sections are missing"
  end
  return nil
end

---@param cacheFs CacheFs
---@param index AudioCacheValidator.Index
---@param id number
---@param entry AudioCacheValidator.IndexEntry
---@param usedPlayers table<integer, boolean>
---@return string?
local function validateSequenceEntry(cacheFs, index, id, entry, usedPlayers)
  if not isIndexId(id) or type(entry) ~= "table" or entry.id ~= id then
    return "sequence index entry is malformed"
  end
  local entryValue = entry
  -- Index records store no payload path: every path derives from the
  -- numeric id (AudioCache.sequencePath), so a redundant `file` field is
  -- malformed index data, never tolerated.
  if entryValue.file ~= nil then
    return "sequence index entry carries a stored payload path"
  end
  if type(entryValue.bankId) ~= "number" or index.banks[entryValue.bankId] == nil then
    return "sequence bank id does not resolve"
  end
  if index.players[entryValue.playerId] == nil then
    return "sequence player id does not resolve"
  end
  usedPlayers[entryValue.playerId] = true
  local sequence = cacheFs:loadLua(AudioCache.sequencePath(id))
  if type(sequence) ~= "table" then
    return "sequence asset is missing or unreadable"
  end
  if not passes(AudioSequence.validate, sequence) then
    return "sequence fails its validator"
  end
  -- The asset duplicates index identity fields (id, bank reference,
  -- symbol, and the player block it starts from; the leaf validator
  -- already proved the player block's shape); a disagreement means the
  -- index no longer describes the cache.
  if sequence.id ~= entry.id or sequence.bankId ~= entry.bankId or sequence.symbol ~= entry.symbol then
    return "sequence identity does not match its index entry"
  end
  if sequence.player.id ~= entry.playerId then
    return "sequence player block does not match its index entry"
  end
  return nil
end

---@param cacheFs CacheFs
---@param index AudioCacheValidator.Index
---@return string?, table<integer, boolean>?
local function validateSequences(cacheFs, index)
  local usedPlayers = {} ---@type table<integer, boolean>
  for id, entry in pairs(index.sequences) do
    local problem = validateSequenceEntry(cacheFs, index, id, entry, usedPlayers)
    if problem ~= nil then
      return problem
    end
  end
  return nil, usedPlayers
end

---@param index AudioCacheValidator.Index
---@param usedPlayers table<integer, boolean>
---@return string?
local function validatePlayers(index, usedPlayers)
  local problem = sectionProblem(index.players, "player")
  if problem ~= nil then
    return problem
  end
  for id, entry in pairs(index.players) do
    -- sectionProblem proved id is a nonnegative integer and entry.id == id.
    if id >= LOGICAL_PLAYER_COUNT then
      return "player id is outside the supported range"
    end
    if not isU16(entry.channelMask) then
      return "player channel mask is not an unsigned 16-bit integer"
    end
    if usedPlayers[id] ~= nil and not isPositiveInteger(entry.maxSequences) then
      return "a used player must declare a positive sequence slot count"
    end
  end
  return nil
end

---@param index AudioCacheValidator.Index
---@return string?
local function validateSymbolMaps(index)
  local problem = symbolMapProblem(index.sequences, index.sequenceBySymbol, "sequence")
  if problem ~= nil then
    return problem
  end
  return symbolMapProblem(index.banks, index.bankBySymbol, "bank")
end

---@param cacheFs CacheFs
---@param keys string[]
---@return string?
local function validateBankSamples(cacheFs, keys)
  for _, key in ipairs(keys) do
    local metadata = cacheFs:loadLua(AudioCache.sampleMetadataPath(key))
    if type(metadata) ~= "table" then
      return "referenced sample metadata is missing or unreadable"
    end
    local payload = cacheFs:read(AudioCache.samplePath(key))
    if payload == nil then
      return "referenced sample payload is missing"
    end
    if not passes(AudioSample.validate, metadata, payload) then
      return "sample metadata or payload fails its validator"
    end
    if metadata.key ~= key then
      return "sample metadata key does not match its address"
    end
  end
  return nil
end

-- One bank closure against the files at hand, without the family index: the
-- bank asset passes its validator under its own identity, every named
-- sequence asset passes its validator under its own identity while naming
-- this bank, and every bank-referenced sample's metadata and payload
-- validate. Samples stream one at a time; no payload set is accumulated.
-- Returns nil when the closure is valid or a problem message otherwise,
-- never raises. The family summary replays the complete walk over the
-- combined on-disk graph; this scope never claims family readiness.
---@param assetFs CacheFs
---@param bankId integer
---@param sequenceIds integer[]
---@return string|nil
function AudioCacheValidator.validateBankClosure(assetFs, bankId, sequenceIds)
  local bank = assetFs:loadLua(AudioCache.bankPath(bankId)) ---@type table?
  if type(bank) ~= "table" then
    return "bank asset is missing or unreadable"
  end
  if not passes(AudioBank.validate, bank) then
    return "bank fails its validator"
  end
  if bank.id ~= bankId then
    return "bank identity does not match its closure"
  end
  for _, sequenceId in ipairs(sequenceIds) do
    local sequence = assetFs:loadLua(AudioCache.sequencePath(sequenceId)) ---@type table?
    if type(sequence) ~= "table" then
      return "closure sequence asset is missing or unreadable"
    end
    if not passes(AudioSequence.validate, sequence) then
      return "closure sequence fails its validator"
    end
    if sequence.id ~= sequenceId or sequence.bankId ~= bankId then
      return "closure sequence identity does not match its bank"
    end
  end
  local keys = AudioBank.sampleKeys(bank)
  if keys == nil then
    return "bank sample references are malformed"
  end
  return validateBankSamples(assetFs, keys)
end

---@param cacheFs CacheFs
---@param id number
---@param entry AudioCacheValidator.IndexEntry
---@return string?
local function validateBankEntry(cacheFs, id, entry)
  if not isIndexId(id) or type(entry) ~= "table" or entry.id ~= id then
    return "bank index entry is malformed"
  end
  -- Bank index records carry no payload path either (AudioCache.bankPath).
  if entry.file ~= nil then
    return "bank index entry carries a stored payload path"
  end
  local bank = cacheFs:loadLua(AudioCache.bankPath(id))
  if type(bank) ~= "table" then
    return "bank asset is missing or unreadable"
  end
  if not passes(AudioBank.validate, bank) then
    return "bank fails its validator"
  end
  if bank.id ~= entry.id or bank.symbol ~= entry.symbol then
    return "bank identity does not match its index entry"
  end
  local keys = AudioBank.sampleKeys(bank)
  if keys == nil then
    return "bank sample references are malformed"
  end
  return validateBankSamples(cacheFs, keys)
end

---@param cacheFs CacheFs
---@param index AudioCacheValidator.Index
---@return string?
local function validateBanks(cacheFs, index)
  for id, entry in pairs(index.banks) do
    local problem = validateBankEntry(cacheFs, id, entry)
    if problem ~= nil then
      return problem
    end
  end
  return nil
end

-- The authoritative walk over an explicitly supplied index: the same rule
-- readiness runs, with assets read from the given filesystem. Summary
-- staging validates the staged index against the already published bank
-- closures through this entry point without assembling a second PCM bundle.
---@param assetFs CacheFs
---@param index AudioCacheValidator.Index|table<string, unknown>|nil
---@return string|nil
function AudioCacheValidator.validateWithIndex(assetFs, index)
  local problem = validateIndexRoot(index)
  if problem ~= nil then
    return problem
  end
  ---@cast index AudioCacheValidator.Index
  local sequenceProblem, usedPlayers = validateSequences(assetFs, index)
  if sequenceProblem ~= nil then
    return sequenceProblem
  end
  ---@cast usedPlayers table<integer, boolean>
  problem = validatePlayers(index, usedPlayers)
  if problem ~= nil then
    return problem
  end
  problem = validateSymbolMaps(index)
  if problem ~= nil then
    return problem
  end
  return validateBanks(assetFs, index)
end

---@param cacheFs CacheFs
---@return string|nil
function AudioCacheValidator.validate(cacheFs)
  local index = cacheFs:loadLua(AudioCache.indexPath()) ---@type table?
  return AudioCacheValidator.validateWithIndex(cacheFs, index)
end

return AudioCacheValidator
