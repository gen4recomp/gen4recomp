-- Immutable resolved mon definitions. The constructor requires the
-- already-canonical generated asset root, validates it through the owned
-- asset schema, copies it into package-owned state, and indexes semantic and
-- native identities. Lookups never mutate and never reach source formats:
-- native numeric identities stay only because exact native encoding gives
-- them current use. The fingerprint is a deterministic digest of the
-- canonical root; equal roots produce equal fingerprints.

local LuaWriter = require("libs.codec.src.LuaWriter")
local U32 = require("libs.codec.src.U32")
local MonAssetSchema = require("libs.assets.src.MonAssetSchema")
local MonsErrors = require("libs.mons.src.errors")

---@class MonCatalog
---@field private _root table
---@field private _speciesByNative table<integer, string>
---@field private _moveByNative table<integer, string>
---@field private _abilityByNative table<integer, string>
---@field private _fingerprint string
local MonCatalog = {}
MonCatalog.__index = MonCatalog

---@param value any
---@return any
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

---@param root table
---@return MonCatalog
function MonCatalog.new(root)
  assert(type(root) == "table", "MonCatalog requires the generated asset root")
  MonAssetSchema.assertCatalog(root)
  local owned = copyValue(root)
  local self = setmetatable({
    _root = owned,
    _speciesByNative = {},
    _moveByNative = {},
    _abilityByNative = {},
    _fingerprint = "",
  }, MonCatalog)
  for key, species in pairs(owned.species) do
    if self._speciesByNative[species.nativeId] ~= nil then
      MonsErrors.raise(
        MonsErrors.RECORD_INVALID,
        "duplicate native species identity " .. tostring(species.nativeId),
        { species = key }
      )
    end
    self._speciesByNative[species.nativeId] = key
  end
  for key, move in pairs(owned.moves) do
    if self._moveByNative[move.nativeId] ~= nil then
      MonsErrors.raise(
        MonsErrors.RECORD_INVALID,
        "duplicate native move identity " .. tostring(move.nativeId),
        { move = key }
      )
    end
    self._moveByNative[move.nativeId] = key
  end
  for key, ability in pairs(owned.abilities) do
    if self._abilityByNative[ability.nativeId] ~= nil then
      MonsErrors.raise(
        MonsErrors.RECORD_INVALID,
        "duplicate native ability identity " .. tostring(ability.nativeId),
        { ability = key }
      )
    end
    self._abilityByNative[ability.nativeId] = key
  end
  self._fingerprint = fingerprintText(LuaWriter.encode(owned))
  return self
end

---@return string
function MonCatalog:fingerprint()
  return self._fingerprint
end

---@param key string
---@return table
function MonCatalog:species(key)
  assert(type(key) == "string", "species lookup requires a string key")
  local definition = self._root.species[key]
  if definition == nil then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "unknown species " .. key, { species = key })
  end
  assert(definition ~= nil, "catalog index carries the validated entry")
  return definition
end

---@param nativeId integer
---@return string
function MonCatalog:speciesKeyByNativeId(nativeId)
  local key = self._speciesByNative[nativeId]
  if key == nil then
    MonsErrors.raise(
      MonsErrors.RECORD_INVALID,
      "unknown native species identity " .. tostring(nativeId),
      { nativeId = nativeId }
    )
  end
  assert(key ~= nil, "catalog index carries the validated entry")
  return key
end

---@param nativeId integer
---@return table
function MonCatalog:speciesByNativeId(nativeId)
  return self._root.species[self:speciesKeyByNativeId(nativeId)]
end

---@param speciesKey string
---@param form integer
---@return table
function MonCatalog:form(speciesKey, form)
  local definition = self:species(speciesKey)
  local formDefinition = definition.forms[form]
  if formDefinition == nil then
    MonsErrors.raise(
      MonsErrors.RECORD_INVALID,
      "unknown form " .. tostring(form) .. " for species " .. speciesKey,
      { species = speciesKey, form = form }
    )
  end
  assert(formDefinition ~= nil, "catalog index carries the validated entry")
  return formDefinition
end

---@param key string
---@return table
function MonCatalog:move(key)
  assert(type(key) == "string", "move lookup requires a string key")
  local definition = self._root.moves[key]
  if definition == nil then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "unknown move " .. key, { move = key })
  end
  assert(definition ~= nil, "catalog index carries the validated entry")
  return definition
end

---@param nativeId integer
---@return string
function MonCatalog:moveKeyByNativeId(nativeId)
  local key = self._moveByNative[nativeId]
  if key == nil then
    MonsErrors.raise(
      MonsErrors.RECORD_INVALID,
      "unknown native move identity " .. tostring(nativeId),
      { nativeId = nativeId }
    )
  end
  assert(key ~= nil, "catalog index carries the validated entry")
  return key
end

---@param nativeId integer
---@return table
function MonCatalog:moveByNativeId(nativeId)
  return self._root.moves[self:moveKeyByNativeId(nativeId)]
end

---@param key string
---@return table
function MonCatalog:ability(key)
  assert(type(key) == "string", "ability lookup requires a string key")
  local definition = self._root.abilities[key]
  if definition == nil then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "unknown ability " .. key, { ability = key })
  end
  assert(definition ~= nil, "catalog index carries the validated entry")
  return definition
end

---@param nativeId integer
---@return string
function MonCatalog:abilityKeyByNativeId(nativeId)
  local key = self._abilityByNative[nativeId]
  if key == nil then
    MonsErrors.raise(
      MonsErrors.RECORD_INVALID,
      "unknown native ability identity " .. tostring(nativeId),
      { nativeId = nativeId }
    )
  end
  assert(key ~= nil, "catalog index carries the validated entry")
  return key
end

---@param nativeId integer
---@return table
function MonCatalog:abilityByNativeId(nativeId)
  return self._root.abilities[self:abilityKeyByNativeId(nativeId)]
end

---@param key string
---@return integer[]
function MonCatalog:growthCurve(key)
  assert(type(key) == "string", "growth curve lookup requires a string key")
  local curve = self._root.growthCurves[key]
  if curve == nil then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "unknown growth curve " .. key, { curve = key })
  end
  assert(curve ~= nil, "catalog index carries the validated entry")
  return curve
end

---@param selector table
---@return table
local function formOfSelector(self, selector)
  assert(type(selector) == "table", "form selection requires a mon or selector record")
  return self:form(selector.species, selector.form)
end

---@param monOrSelector table
---@return string
function MonCatalog:iconSelection(monOrSelector)
  return formOfSelector(self, monOrSelector).icon
end

---@param monOrSelector table
---@return string
function MonCatalog:portraitSelection(monOrSelector)
  return formOfSelector(self, monOrSelector).portrait
end

---@param monOrSelector table
---@return table?
function MonCatalog:followerSelection(monOrSelector)
  return formOfSelector(self, monOrSelector).follower
end

return MonCatalog
