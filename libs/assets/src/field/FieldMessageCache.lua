-- Readiness and paths for the derived field-message cache. Message banks are
-- one of the independently rebuildable derived classes (map geometry, actor
-- visuals, messages/font): changing the message compiler must not disturb the
-- raw ROM dump or any compiled map. A bank is ready only when the completion
-- marker matches exactly and every bank file it indexes is present, so a
-- partial build never reads as complete. Paths are cache-relative; all IO
-- goes through a CacheFs.

local FieldMessageCache = {}

---@class FieldMessageCache.Index
---@field schema string
---@field version string
---@field bankIds integer[]

local Validate = require("libs.assets.src.Validate")
local Contract = require("libs.assets.src.DerivedAssetContract")

FieldMessageCache.FORMAT = Contract.messages.cacheFormat
FieldMessageCache.SCHEMA = Contract.messages.schema
FieldMessageCache.INDEX_SCHEMA = Contract.messages.indexSchema
FieldMessageCache.PROVENANCE_SCHEMA = Contract.messages.provenanceSchema

local DATA_DIR = "data/generated/field/messages"

function FieldMessageCache.dir()
  return DATA_DIR
end
function FieldMessageCache.indexPath()
  return DATA_DIR .. "/index.lua"
end
function FieldMessageCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end
function FieldMessageCache.markerPath()
  return DATA_DIR .. "/complete"
end

function FieldMessageCache.bankPath(bankId)
  assert(Validate.isNonNegativeInteger(bankId), "bankId must be a non-negative integer")
  return string.format("%s/banks/%04d.lua", DATA_DIR, bankId)
end

function FieldMessageCache.bankMarkerPath(bankId)
  assert(Validate.isNonNegativeInteger(bankId), "bankId must be a non-negative integer")
  return string.format("%s/banks/%04d.complete", DATA_DIR, bankId)
end

function FieldMessageCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", FieldMessageCache.FORMAT, romSha1, depHash)
end

-- True only if the bank's own marker is exact and its payload loads with
-- the expected schema and matching identity. Reads staged or published
-- files only; never touches source decoding or tokenization.
---@param cacheFs CacheFs
---@param bankId integer
---@param expectedMarker string
---@return boolean
function FieldMessageCache.isBankReady(cacheFs, bankId, expectedMarker)
  if cacheFs:read(FieldMessageCache.bankMarkerPath(bankId)) ~= expectedMarker then
    return false
  end
  local bank = cacheFs:loadLua(FieldMessageCache.bankPath(bankId)) ---@type table?
  if type(bank) ~= "table" or bank.schema ~= FieldMessageCache.SCHEMA or bank.bankId ~= bankId then
    return false
  end
  return true
end

-- True only if the marker is exact, the index loads with the expected schema,
-- bankIds is the required array of bank ids, and every indexed bank's file
-- loads with the expected schema and matching identity.
function FieldMessageCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(FieldMessageCache.markerPath()) ~= expectedMarker then
    return false
  end
  local index = cacheFs:loadLua(FieldMessageCache.indexPath()) ---@type table?
  if type(index) ~= "table" or index.schema ~= FieldMessageCache.INDEX_SCHEMA then
    return false
  end
  if not Validate.isArray(index.bankIds) then
    return false
  end
  for _, bankId in ipairs(index.bankIds) do
    if not Validate.isNonNegativeInteger(bankId) then
      return false
    end
    local bank = cacheFs:loadLua(FieldMessageCache.bankPath(bankId)) ---@type table?
    if type(bank) ~= "table" or bank.schema ~= FieldMessageCache.SCHEMA or bank.bankId ~= bankId then
      return false
    end
  end
  return true
end

return FieldMessageCache
