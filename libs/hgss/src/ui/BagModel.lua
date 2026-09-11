-- Field-bag view projection: one fresh immutable browse record per build
-- over the live inventory service and the runtime-only field cursor. The
-- projection joins pocket order and cursor offsets with catalog display
-- facts (name, description, icon) and service quantities; windows the
-- six-cell grid over the ordered pocket slots; and derives the page
-- indicator. Stale cursor offsets clamp to the nearest valid cell without
-- mutating the borrowed cursor. Pure module: no love, no I/O.

local BagSave = require("libs.hgss.src.save.BagSave")

---@class BagModel
local BagModel = {}

BagModel.VISIBLE_COUNT = 6

---@param count integer
---@param position integer
---@return integer
local function clampSelection(count, position)
  if count == 0 then
    return 0
  end
  return math.min(math.max(position, 0), count - 1)
end

---@param count integer
---@param scroll integer
---@return integer
local function clampStart(count, scroll)
  if count <= BagModel.VISIBLE_COUNT then
    return 0
  end
  local start = math.min(math.max(scroll, 0), count - 1)
  return start - (start % 2)
end

---@param service HgssBagService
---@param pocketKey string
---@return { pocket: string, nativeId: integer, name: string }
local function projectTab(service, pocketKey)
  local catalog = service:catalog()
  return {
    pocket = pocketKey,
    nativeId = catalog:pocket(pocketKey).nativeId,
    name = catalog:pocketName(pocketKey),
  }
end

---@param service HgssBagService
---@param registrationSlot integer? the registration slot identity (1, 2, or nil)
---@param itemKey string
---@param quantity integer
---@return table<string, unknown>
local function projectSlot(service, registrationSlot, itemKey, quantity)
  local definition = service:catalog():item(itemKey)
  return {
    item = itemKey,
    nativeId = definition.nativeId,
    name = definition.name,
    quantity = quantity,
    description = definition.description,
    icon = definition.icon,
    registrationSlot = registrationSlot,
  }
end

---@param service HgssBagService
---@param cursor BagCursor
---@return table<string, unknown>
function BagModel.build(service, cursor)
  assert(type(service) == "table", "the bag view needs the live bag service")
  assert(type(cursor) == "table", "the bag view needs the runtime bag cursor")
  assert(type(service.pocketItems) == "function", "the bag view needs pocket reads")
  assert(type(service.catalog) == "function", "the bag view needs the item catalog")
  assert(type(service.registeredItems) == "function", "the bag view needs registration reads")
  assert(type(service.revision) == "function", "the bag view needs the service revision")
  assert(type(cursor.currentPocket) == "function", "the bag view needs the cursor pocket")
  local pocket = cursor:currentPocket()
  local catalog = service:catalog()
  local pocketSlots = service:pocketItems(pocket)
  local count = #pocketSlots
  local registeredList = service:registeredItems()
  local registrationByItem = {}
  for slotNumber, key in ipairs(registeredList) do
    if slotNumber == 1 or slotNumber == 2 then
      registrationByItem[key] = slotNumber
    end
  end
  local pockets = {}
  for index, pocketKey in ipairs(BagSave.POCKET_ORDER) do
    pockets[index] = projectTab(service, pocketKey)
  end
  local slots = {}
  for index, entry in ipairs(pocketSlots) do
    slots[index] = projectSlot(service, registrationByItem[entry.item], entry.item, entry.quantity)
  end
  local selectedAbsoluteIndex = clampSelection(count, cursor:position(pocket))
  local visibleStart = clampStart(count, cursor:scroll(pocket))
  local visibleSlots = {}
  for cell = 1, BagModel.VISIBLE_COUNT do
    local slot = slots[visibleStart + cell]
    if slot ~= nil then
      visibleSlots[cell] = slot
    else
      visibleSlots[cell] = { empty = true, visibleIndex = cell - 1 }
    end
  end
  local pageCount = math.max(1, math.ceil(count / BagModel.VISIBLE_COUNT))
  local pageCurrent = 1
  if count > 0 then
    pageCurrent = math.min(math.floor(selectedAbsoluteIndex / BagModel.VISIBLE_COUNT) + 1, pageCount)
  end
  return {
    revision = service:revision(),
    pocket = pocket,
    pocketNativeId = catalog:pocket(pocket).nativeId,
    pocketName = catalog:pocketName(pocket),
    pockets = pockets,
    slots = slots,
    selectedAbsoluteIndex = selectedAbsoluteIndex,
    visibleStart = visibleStart,
    visibleSlots = visibleSlots,
    page = { current = pageCurrent, count = pageCount },
    selected = slots[selectedAbsoluteIndex + 1],
  }
end

return BagModel
