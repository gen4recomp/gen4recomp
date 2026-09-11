-- Strict persisted Bag bucket: ordered occupied slots per pocket plus the
-- two registered item keys. The project save stores only occupied ordered
-- slots while enforcing the source invariants (eight BagViewPockets and two
-- registered items per include/bag_types_def.h): every slot carries a known
-- catalog key in its catalog pocket with a positive stack quantity, canonical
-- pockets stay in native-id order, and registration names known registerable
-- items, even when the bag no longer holds a copy. Malformed records are rejected, never repaired. Pure domain
-- code: no love dependency.

local Errors = require("libs.errors.src.Errors")
local GameSaveErrors = require("libs.hgss.src.save.GameSaveErrors")

---@class BagSave
local BagSave = {}

BagSave.SCHEMA = "hgss-bag-v1"

-- The eight source pockets in native order; every record carries all eight.
BagSave.POCKET_ORDER = {
  "items",
  "medicine",
  "balls",
  "tmhm",
  "berries",
  "mail",
  "battle_items",
  "key_items",
}

local TOP_LEVEL_FIELDS = { schema = true, pockets = true, registered = true }
local SLOT_FIELDS = { item = true, quantity = true }

---@param message string
---@param context table<string, unknown>?
local function fail(message, context)
  context = context or {}
  if context.bucket == nil then
    context.bucket = "bag"
  end
  Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, message, context)
end

---@return table<string, unknown>
function BagSave.empty()
  local pockets = {}
  for _, pocketKey in ipairs(BagSave.POCKET_ORDER) do
    pockets[pocketKey] = {}
  end
  return { schema = BagSave.SCHEMA, pockets = pockets, registered = {} }
end

---@param slots table<string, unknown>
---@param pocketKey string
local function checkSlotArray(slots, pocketKey)
  if type(slots) ~= "table" then
    fail("bag pocket " .. pocketKey .. " must be an array", { pocket = pocketKey })
  end
  assert(type(slots) == "table", "bag pocket carries its slot array")
  local count = #slots
  for key in pairs(slots) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > count then
      fail("bag pocket " .. pocketKey .. " has a non-contiguous slot array", { pocket = pocketKey })
    end
  end
end

---@param value unknown
---@param itemCatalog ItemCatalog
---@return table<string, unknown>
local function validateRecord(value, itemCatalog)
  assert(itemCatalog ~= nil, "bag validation requires an item catalog")
  if type(itemCatalog.item) ~= "function" then
    fail("bag validation requires an item catalog")
  end
  if type(value) ~= "table" then
    fail("bag bucket must be a table")
  end
  assert(type(value) == "table", "bag bucket carries its record")
  if value.schema ~= BagSave.SCHEMA then
    fail("bag schema must be " .. BagSave.SCHEMA, { schema = value.schema })
  end
  for key in pairs(value) do
    if not TOP_LEVEL_FIELDS[key] then
      fail("bag bucket contains an unknown field", { field = key })
    end
  end
  if type(value.pockets) ~= "table" then
    fail("bag pockets must be a record")
  end
  if type(value.registered) ~= "table" then
    fail("bag registered slots must be an array")
  end
  for key in pairs(value.pockets) do
    local known = false
    for _, pocketKey in ipairs(BagSave.POCKET_ORDER) do
      if key == pocketKey then
        known = true
        break
      end
    end
    if not known then
      fail("bag pocket is unknown", { pocket = key })
    end
  end
  local seen = {}
  local canonicalPockets = {}
  for _, pocketKey in ipairs(BagSave.POCKET_ORDER) do
    local slots = value.pockets[pocketKey]
    checkSlotArray(slots, pocketKey)
    assert(type(slots) == "table", "bag pocket carries its slot array")
    local pocket = itemCatalog:pocket(pocketKey)
    if #slots > pocket.capacity then
      fail("bag pocket " .. pocketKey .. " exceeds its capacity", { pocket = pocketKey })
    end
    local canonicalSlots = {}
    local previousNativeId = nil
    for index = 1, #slots do
      local slot = slots[index]
      if type(slot) ~= "table" then
        fail("bag pocket " .. pocketKey .. " slot " .. index .. " must be a record", { pocket = pocketKey })
      end
      for key in pairs(slot) do
        if not SLOT_FIELDS[key] then
          fail("bag slot contains an unknown field", { pocket = pocketKey, field = key })
        end
      end
      local ok, definition = pcall(itemCatalog.item, itemCatalog, slot.item)
      if not ok or type(definition) ~= "table" then
        fail("bag slot names an unknown item", { pocket = pocketKey, item = slot.item })
      end
      assert(definition ~= nil, "catalog lookup carries the validated definition")
      if definition.pocket ~= pocketKey then
        fail("bag item " .. slot.item .. " is stored outside its pocket", { pocket = pocketKey, item = slot.item })
      end
      if
        type(slot.quantity) ~= "number"
        or slot.quantity % 1 ~= 0
        or slot.quantity < 1
        or slot.quantity > pocket.maxQuantity
      then
        fail(
          "bag item " .. slot.item .. " quantity is outside 1.." .. pocket.maxQuantity,
          { pocket = pocketKey, item = slot.item }
        )
      end
      if seen[slot.item] then
        fail("bag item " .. slot.item .. " is stored twice", { item = slot.item })
      end
      seen[slot.item] = true
      if pocket.ordering == "native_id" then
        if previousNativeId ~= nil and definition.nativeId <= previousNativeId then
          fail("bag pocket " .. pocketKey .. " is not in native-id order", { pocket = pocketKey })
        end
        previousNativeId = definition.nativeId
      end
      canonicalSlots[index] = { item = slot.item, quantity = slot.quantity }
    end
    canonicalPockets[pocketKey] = canonicalSlots
  end
  local registered = value.registered
  assert(type(registered) == "table", "bag registered slots carry their array")
  for key in pairs(registered) do
    if key ~= 1 and key ~= 2 then
      fail("bag registered slots carry at most two entries", {})
    end
  end
  local first, second = registered[1], registered[2]
  if second ~= nil and first == nil then
    fail("bag registered slot two requires slot one", {})
  end
  local canonicalRegistered = {}
  for index, key in ipairs({ first, second }) do
    if key ~= nil then
      if type(key) ~= "string" then
        fail("bag registered slot " .. index .. " must be an item key", {})
      end
      local ok, definition = pcall(itemCatalog.item, itemCatalog, key)
      if not ok or type(definition) ~= "table" then
        fail("bag registered slot names an unknown item", { item = key })
      end
      assert(definition ~= nil, "catalog lookup carries the validated definition")
      if not itemCatalog:isRegisterable(key) then
        fail("bag registered item " .. key .. " is not registerable", { item = key })
      end
      if canonicalRegistered[1] == key then
        fail("bag registered item " .. key .. " is stored twice", { item = key })
      end
      canonicalRegistered[index] = key
    end
  end
  return { schema = BagSave.SCHEMA, pockets = canonicalPockets, registered = canonicalRegistered }
end

---@param value unknown
---@param itemCatalog ItemCatalog
---@return table<string, unknown>|nil, Errors.Error?
function BagSave.validate(value, itemCatalog)
  local ok, result = pcall(validateRecord, value, itemCatalog)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

-- Copies a trusted inventory capture without introspecting inventory
-- internals: the inventory owns its serialization shape.
---@param inventory table<string, unknown>
---@return table<string, unknown>
function BagSave.capture(inventory)
  assert(type(inventory) == "table" and type(inventory.capture) == "function", "bag capture needs an inventory")
  local capture = inventory:capture()
  assert(type(capture) == "table", "inventory capture carries the bag record")
  return capture
end

return BagSave
