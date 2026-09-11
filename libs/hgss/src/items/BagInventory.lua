-- Mutable HGSS Bag inventory: exact pocket mechanics over the shared item
-- catalog (capacities, stack limits, and ordering come from
-- include/constants/items.h via the catalog, never from a second table).
-- One stack exists per item: a stack-overflow add fails even when another
-- empty slot exists. TM/HM and Berry pockets sort by ascending native item
-- id after add; other pockets preserve mutable order. Removing an item's
-- final copy removes the pocket slot and leaves registration untouched.
-- The service owns the revision; this mechanism
-- only reports success. Pure domain code: no love dependency.

local BagSave = require("libs.hgss.src.save.BagSave")

---@class BagInventory
---@field private _catalog ItemCatalog
---@field private _pockets table<string, { item: string, quantity: integer }[]>
---@field private _registered string[]
---@field private _byItem table<string, { pocket: string, index: integer }>
local BagInventory = {}
BagInventory.__index = BagInventory

---@param catalog ItemCatalog
---@param bag table<string, unknown>?
---@return BagInventory
function BagInventory.new(catalog, bag)
  assert(catalog ~= nil, "bag inventory requires an item catalog")
  local record = bag ~= nil and assert(BagSave.validate(bag, catalog)) or BagSave.empty()
  assert(type(record.pockets) == "table", "validated bag carries its pockets")
  assert(type(record.registered) == "table", "validated bag carries its registration")
  local self = setmetatable({
    _catalog = catalog,
    _pockets = {},
    _registered = {},
    _byItem = {},
  }, BagInventory)
  for _, pocketKey in ipairs(BagSave.POCKET_ORDER) do
    local slots = {}
    for index, slot in ipairs(record.pockets[pocketKey]) do
      slots[index] = { item = slot.item, quantity = slot.quantity }
    end
    self._pockets[pocketKey] = slots
  end
  for index, key in ipairs(record.registered) do
    self._registered[index] = key
  end
  self:_reindex()
  return self
end

function BagInventory:_reindex()
  local index = {}
  for _, pocketKey in ipairs(BagSave.POCKET_ORDER) do
    for slotIndex, slot in ipairs(self._pockets[pocketKey]) do
      index[slot.item] = { pocket = pocketKey, index = slotIndex }
    end
  end
  self._byItem = index
end

---@param itemKey string
---@return table<string, unknown>
function BagInventory:_definition(itemKey)
  return self._catalog:item(itemKey)
end

---@param quantity integer
local function checkQuantity(quantity)
  assert(type(quantity) == "number" and quantity % 1 == 0 and quantity >= 1, "bag quantity must be a positive integer")
end

---@param pocketKey string
---@return { capacity: integer, maxQuantity: integer, ordering: string }
function BagInventory:_pocket(pocketKey)
  return self._catalog:pocket(pocketKey)
end

-- The one add/space decision path, so hasSpace cannot disagree with add.
---@param itemKey string
---@param quantity integer
---@return boolean
function BagInventory:_fits(itemKey, quantity)
  local definition = self:_definition(itemKey)
  local pocket = self:_pocket(definition.pocket)
  if quantity > pocket.maxQuantity then
    return false
  end
  local entry = self._byItem[itemKey]
  if entry ~= nil then
    return self._pockets[entry.pocket][entry.index].quantity + quantity <= pocket.maxQuantity
  end
  return #self._pockets[definition.pocket] < pocket.capacity
end

---@param itemKey string
---@param quantity integer
---@return boolean
function BagInventory:has(itemKey, quantity)
  checkQuantity(quantity)
  self:_definition(itemKey)
  local entry = self._byItem[itemKey]
  if entry == nil then
    return false
  end
  return self._pockets[entry.pocket][entry.index].quantity >= quantity
end

---@param itemKey string
---@return integer
function BagInventory:quantity(itemKey)
  self:_definition(itemKey)
  local entry = self._byItem[itemKey]
  if entry == nil then
    return 0
  end
  return self._pockets[entry.pocket][entry.index].quantity
end

---@param itemKey string
---@param quantity integer
---@return boolean
function BagInventory:hasSpace(itemKey, quantity)
  checkQuantity(quantity)
  return self:_fits(itemKey, quantity)
end

---@param itemKey string
---@param quantity integer
---@return boolean
function BagInventory:add(itemKey, quantity)
  checkQuantity(quantity)
  if not self:_fits(itemKey, quantity) then
    return false
  end
  local definition = self:_definition(itemKey)
  local pocketKey = definition.pocket
  local pocket = self:_pocket(pocketKey)
  local entry = self._byItem[itemKey]
  if entry ~= nil then
    local slot = self._pockets[entry.pocket][entry.index]
    slot.quantity = slot.quantity + quantity
  else
    local slots = self._pockets[pocketKey]
    slots[#slots + 1] = { item = itemKey, quantity = quantity }
    if pocket.ordering == "native_id" then
      local catalog = self._catalog
      table.sort(slots, function(left, right)
        return catalog:item(left.item).nativeId < catalog:item(right.item).nativeId
      end)
    end
  end
  self:_reindex()
  return true
end

---@param itemKey string
---@param quantity integer
---@return boolean
function BagInventory:take(itemKey, quantity)
  checkQuantity(quantity)
  self:_definition(itemKey)
  local entry = self._byItem[itemKey]
  if entry == nil then
    return false
  end
  local slots = self._pockets[entry.pocket]
  local slot = slots[entry.index]
  if slot.quantity < quantity then
    return false
  end
  local remaining = slot.quantity - quantity
  if remaining == 0 then
    table.remove(slots, entry.index)
  else
    slot.quantity = remaining
  end
  self:_reindex()
  return true
end

---@param pocketKey string
---@return { item: string, quantity: integer }[]
function BagInventory:pocketItems(pocketKey)
  self:_pocket(pocketKey)
  local out = {}
  for index, slot in ipairs(self._pockets[pocketKey]) do
    out[index] = { item = slot.item, quantity = slot.quantity }
  end
  return out
end

---@param pocketKey string
---@param fromIndex integer
---@param toIndex integer
---@return boolean
function BagInventory:move(pocketKey, fromIndex, toIndex)
  if self:_pocket(pocketKey).ordering ~= "manual" then
    return false
  end
  local slots = self._pockets[pocketKey]
  for _, index in ipairs({ fromIndex, toIndex }) do
    if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #slots then
      return false
    end
  end
  if fromIndex == toIndex then
    return false
  end
  local slot = table.remove(slots, fromIndex)
  table.insert(slots, toIndex, slot)
  self:_reindex()
  return true
end

---@return string[]
function BagInventory:registeredItems()
  local out = {}
  for index, key in ipairs(self._registered) do
    out[index] = key
  end
  return out
end

---@param itemKey string
---@return "slot1"|"slot2"|nil
function BagInventory:tryRegister(itemKey)
  self:_definition(itemKey)
  if self._byItem[itemKey] == nil then
    return nil
  end
  if not self._catalog:isRegisterable(itemKey) then
    return nil
  end
  for _, key in ipairs(self._registered) do
    if key == itemKey then
      return nil
    end
  end
  if #self._registered >= 2 then
    return nil
  end
  self._registered[#self._registered + 1] = itemKey
  if #self._registered == 1 then
    return "slot1"
  end
  return "slot2"
end

---@param itemKey string
---@return boolean
function BagInventory:unregister(itemKey)
  self:_definition(itemKey)
  for index, key in ipairs(self._registered) do
    if key == itemKey then
      table.remove(self._registered, index)
      return true
    end
  end
  return false
end

---@return table<string, unknown>
function BagInventory:capture()
  local pockets = {}
  for _, pocketKey in ipairs(BagSave.POCKET_ORDER) do
    pockets[pocketKey] = self:pocketItems(pocketKey)
  end
  return { schema = BagSave.SCHEMA, pockets = pockets, registered = self:registeredItems() }
end

return BagInventory
