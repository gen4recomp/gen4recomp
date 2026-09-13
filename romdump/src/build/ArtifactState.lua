-- Producer-private generation receipts for derived-cache artifacts. A receipt
-- is a cheap per-artifact proof that its family output was published for one
-- immutable generation; the family payload and its own validator stay
-- authoritative, so a receipt alone never means ready. Receipts live at
-- data/generated/jobs/<kind>/<key>.lua and travel to the live cache inside
-- the same staged transaction as the family output they accompany.

local StorageErrors = require("libs.storage.src.errors")

---@class ArtifactState.Receipt
---@field schema string
---@field generationId string
---@field kind string
---@field key string
---@field marker string
local ArtifactState = {}

ArtifactState.KINDS = {
  map = true,
  ["field-cell"] = true,
  ["script-member"] = true,
  -- Structural producers with staged publication: the world catalog owns the
  -- single world file, and each field-map-data job owns its own map record.
  world = true,
  ["field-map-data"] = true,
}

ArtifactState.RECEIPT_SCHEMA = "g4-derived-receipt-v1"
ArtifactState.RECEIPT_ROOT = "data/generated/jobs"

local RECEIPT_FIELDS = {
  schema = true,
  generationId = true,
  kind = true,
  key = true,
  marker = true,
}

local function checkKind(kind)
  assert(type(kind) == "string" and ArtifactState.KINDS[kind], "unknown artifact kind: " .. tostring(kind))
end

local function isCanonicalInteger(text)
  return text == "0" or text:match("^[1-9][0-9]*$") ~= nil
end

local function checkKey(kind, key)
  assert(type(key) == "string" and key ~= "", "artifact key must be a non-empty string")
  if key == "global" or isCanonicalInteger(key) then
    return
  end
  local first, second = key:match("^([0-9]+)-([0-9]+)$")
  local compound = first ~= nil and isCanonicalInteger(first) and isCanonicalInteger(second)
  assert(compound, "invalid artifact key: " .. key)
  assert(kind == "field-cell", "compound artifact key is only valid for field cells: " .. key)
end

---@param kind string
---@param key string
---@return string
function ArtifactState.path(kind, key)
  checkKind(kind)
  checkKey(kind, key)
  return ArtifactState.RECEIPT_ROOT .. "/" .. kind .. "/" .. key .. ".lua"
end

---@param receipt unknown
---@param expected { generationId: string, kind: string, key: string }
---@return true|nil
---@return string|nil
function ArtifactState.validate(receipt, expected)
  assert(type(expected) == "table", "receipt expectation is required")
  if type(receipt) ~= "table" then
    return nil, "receipt is not a table"
  end
  ---@cast receipt table<string, unknown>
  for field in pairs(receipt) do
    if not RECEIPT_FIELDS[field] then
      return nil, "receipt has an unexpected field: " .. tostring(field)
    end
  end
  for field in pairs(RECEIPT_FIELDS) do
    if receipt[field] == nil then
      return nil, "receipt is missing " .. field
    end
  end
  if receipt.schema ~= ArtifactState.RECEIPT_SCHEMA then
    return nil, "receipt schema mismatch"
  end
  if type(receipt.marker) ~= "string" or receipt.marker == "" then
    return nil, "receipt marker is missing"
  end
  if receipt.generationId ~= expected.generationId then
    return nil, "receipt generation is not current"
  end
  if receipt.kind ~= expected.kind then
    return nil, "receipt kind mismatch"
  end
  if receipt.key ~= expected.key then
    return nil, "receipt key mismatch"
  end
  return true
end

---@param cacheFs CacheFs
---@param generationId string
---@param kind string
---@param key string
---@return ArtifactState.Receipt|nil
---@return string|nil
function ArtifactState.read(cacheFs, generationId, kind, key)
  assert(cacheFs and cacheFs.versionId, "receipt read requires a cache filesystem")
  assert(type(generationId) == "string" and generationId ~= "", "receipt read requires a generation identity")
  checkKind(kind)
  checkKey(kind, key)
  local path = ArtifactState.path(kind, key)
  local receipt, loadError = cacheFs:loadLua(path)
  if receipt == nil then
    assert(loadError, "receipt read failed without a cause")
    if loadError.code == StorageErrors.CACHE_FILE_MISSING then
      return nil, "no current receipt is published"
    end
    error(loadError, 0)
  end
  local valid, reason = ArtifactState.validate(receipt, { generationId = generationId, kind = kind, key = key })
  if not valid then
    return nil, assert(reason, "receipt rejection must name its reason")
  end
  return receipt --[[@as ArtifactState.Receipt]]
end

return ArtifactState
