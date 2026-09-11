-- Immutable resolved item definitions. The constructor requires the
-- already-canonical generated asset root, validates it through the owned
-- asset schema, copies it into package-owned state, and indexes semantic and
-- native identities. Lookups never mutate and never reach source formats:
-- native numeric identities stay only because exact native encoding gives
-- them current use. The fingerprint is a deterministic digest of the
-- canonical root; equal roots produce equal fingerprints. Pocket definitions
-- are the schema-owned source contract, re-exported here for consumers.

local LuaWriter = require("libs.codec.src.LuaWriter")
local U32 = require("libs.codec.src.U32")
local ItemAssetSchema = require("libs.assets.src.ItemAssetSchema")
local ItemErrors = require("libs.items.src.errors")

---@class ItemCatalog
---@field private _root table<string, unknown>
---@field private _itemByNative table<integer, string>
---@field private _pocketByNative table<integer, string>
---@field private _fingerprint string
local ItemCatalog = {}
ItemCatalog.__index = ItemCatalog

ItemCatalog.POCKETS = ItemAssetSchema.POCKETS

---@param value unknown
---@return unknown
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copyValue(item)
  end
  return out
end

---@param a integer
---@param b integer
---@return integer
local function xorByte(a, b)
  local value = 0
  local place = 1
  for _ = 1, 8 do
    local abit = math.floor(a / place) % 2
    local bbit = math.floor(b / place) % 2
    if abit ~= bbit then
      value = value + place
    end
    place = place * 2
  end
  return value
end

---@param text string
---@return string
local function fingerprintText(text)
  local hash = 2166136261
  for index = 1, #text do
    local low = hash % 256
    hash = (hash - low) + xorByte(low, text:byte(index))
    hash = U32.mul(hash, 16777619)
  end
  return string.format("%08x", hash)
end

---@param root table<string, unknown>
---@return ItemCatalog
function ItemCatalog.new(root)
  assert(type(root) == "table", "ItemCatalog requires the generated asset root")
  ItemAssetSchema.assertCatalog(root)
  local owned = copyValue(root)
  local self = setmetatable({
    _root = owned,
    _itemByNative = {},
    _pocketByNative = {},
    _fingerprint = "",
  }, ItemCatalog)
  for key, item in pairs(owned.items) do
    if self._itemByNative[item.nativeId] ~= nil then
      ItemErrors.raise(
        ItemErrors.RECORD_INVALID,
        "duplicate native item identity " .. tostring(item.nativeId),
        { item = key }
      )
    end
    self._itemByNative[item.nativeId] = key
  end
  for key, pocket in pairs(owned.pockets) do
    self._pocketByNative[pocket.nativeId] = key
  end
  self._fingerprint = fingerprintText(LuaWriter.encode(owned))
  return self
end

---@return string
function ItemCatalog:fingerprint()
  return self._fingerprint
end

---@param key string
---@return table<string, unknown>
function ItemCatalog:item(key)
  assert(type(key) == "string", "item lookup requires a string key")
  local definition = self._root.items[key]
  if definition == nil then
    ItemErrors.raise(ItemErrors.RECORD_INVALID, "unknown item " .. key, { item = key })
  end
  assert(definition ~= nil, "catalog index carries the validated entry")
  return definition
end

---@param nativeId integer
---@return string
function ItemCatalog:itemKeyByNativeId(nativeId)
  local key = self._itemByNative[nativeId]
  if key == nil then
    ItemErrors.raise(
      ItemErrors.RECORD_INVALID,
      "unknown native item identity " .. tostring(nativeId),
      { nativeId = nativeId }
    )
  end
  assert(key ~= nil, "catalog index carries the validated entry")
  return key
end

---@param nativeId integer
---@return table<string, unknown>
function ItemCatalog:itemByNativeId(nativeId)
  return self._root.items[self:itemKeyByNativeId(nativeId)]
end

---@param key string
---@return table<string, unknown>
function ItemCatalog:pocket(key)
  assert(type(key) == "string", "pocket lookup requires a string key")
  local definition = self._root.pockets[key]
  if definition == nil then
    ItemErrors.raise(ItemErrors.RECORD_INVALID, "unknown pocket " .. key, { pocket = key })
  end
  assert(definition ~= nil, "catalog index carries the validated entry")
  return definition
end

---@param nativeId integer
---@return string
function ItemCatalog:pocketKeyByNativeId(nativeId)
  local key = self._pocketByNative[nativeId]
  if key == nil then
    ItemErrors.raise(
      ItemErrors.RECORD_INVALID,
      "unknown native pocket identity " .. tostring(nativeId),
      { nativeId = nativeId }
    )
  end
  assert(key ~= nil, "catalog index carries the validated entry")
  return key
end

---@param nativeId integer
---@return table<string, unknown>
function ItemCatalog:pocketByNativeId(nativeId)
  return self._root.pockets[self:pocketKeyByNativeId(nativeId)]
end

---@param key string
---@return string
function ItemCatalog:pocketName(key)
  assert(type(key) == "string", "pocket name lookup requires a string key")
  local name = self._root.pocketNames[key]
  if name == nil then
    ItemErrors.raise(ItemErrors.RECORD_INVALID, "unknown pocket " .. key, { pocket = key })
  end
  assert(name ~= nil, "catalog index carries the validated entry")
  return name
end

-- Whether the item may occupy a source registered-item slot: a Key Item
-- whose source selectability flag permits field registration. Unknown keys
-- raise the same structured record error as other lookups.
---@param key string
---@return boolean
function ItemCatalog:isRegisterable(key)
  local definition = self:item(key)
  return definition.pocket == "key_items" and definition.selectable == true
end

return ItemCatalog
