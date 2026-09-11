-- Synthetic item catalog root for domain tests. The root satisfies the
-- generated item catalog contract without touching ROM data: every source
-- native identity 0..536 resolves exactly once across all eight pockets, and
-- only the domain-known keys carry meaningful metadata. Shared by the item
-- package tests and the mon package tests that construct catalogs.

local ItemFixture = {}

ItemFixture.POCKET_KEYS = {
  "items",
  "medicine",
  "balls",
  "tmhm",
  "berries",
  "mail",
  "battle_items",
  "key_items",
}

ItemFixture.POCKET_NAMES = {
  items = "Items",
  medicine = "Medicine",
  balls = "Balls",
  tmhm = "TMs & HMs",
  berries = "Berries",
  mail = "Mail",
  battle_items = "Battle Items",
  key_items = "Key Items",
}

-- Meaningful domain-known identities: native id plus the metadata the
-- domain tests assert. Every other identity becomes a deterministic
-- placeholder below.
local KNOWN = {
  NONE = { nativeId = 0, pocket = "items" },
  POKE_BALL = { nativeId = 4, pocket = "balls", isBall = true },
  GREAT_BALL = { nativeId = 3, pocket = "balls", isBall = true },
  LUXURY_BALL = { nativeId = 11, pocket = "balls", isBall = true },
  POTION = { nativeId = 17, pocket = "medicine", name = "Potion" },
  SOOTHE_BELL = { nativeId = 218, pocket = "items", friendshipBoost = true },
  TM01 = { nativeId = 328, pocket = "tmhm", tmhmMoveNativeId = 264 },
  HM01 = { nativeId = 420, pocket = "tmhm", tmhmMoveNativeId = 15 },
  CHERI_BERRY = {
    nativeId = 149,
    pocket = "berries",
    berryNameSingular = "Cheri Berry",
    berryNamePlural = "Cheri Berries",
  },
  SITRUS_BERRY = {
    nativeId = 158,
    pocket = "berries",
    berryNameSingular = "Sitrus Berry",
    berryNamePlural = "Sitrus Berries",
  },
  BICYCLE = { nativeId = 450, pocket = "key_items", preventToss = true, selectable = true },
}

local MANUAL_POCKETS = { "items", "medicine", "balls", "mail", "battle_items", "key_items" }

---@param nativeId integer
---@param key string
---@return table<string, unknown>
local function placeholder(nativeId, key)
  local record = {
    nativeId = nativeId,
    name = key,
    nameIndefinite = "a " .. key,
    namePlural = key .. "s",
    description = key .. " description",
    preventToss = false,
    selectable = false,
    isBall = false,
    friendshipBoost = false,
    icon = key,
  }
  if nativeId >= 328 and nativeId <= 427 then
    record.pocket = "tmhm"
    record.tmhmMoveNativeId = 1
  elseif nativeId >= 149 and nativeId <= 212 then
    record.pocket = "berries"
    record.berryNameSingular = key .. " singular"
    record.berryNamePlural = key .. " plural"
  else
    record.pocket = MANUAL_POCKETS[(nativeId % #MANUAL_POCKETS) + 1]
  end
  return record
end

function ItemFixture.buildAssetRoot()
  local byNativeId = {}
  for key, known in pairs(KNOWN) do
    byNativeId[known.nativeId] = key
  end
  local items = {}
  for nativeId = 0, 536 do
    local key = byNativeId[nativeId]
    if key ~= nil then
      local known = KNOWN[key]
      local record = {
        nativeId = nativeId,
        name = known.name or key,
        nameIndefinite = "a " .. (known.name or key),
        namePlural = (known.name or key) .. "s",
        description = (known.name or key) .. " description",
        pocket = known.pocket,
        preventToss = known.preventToss or false,
        selectable = known.selectable or false,
        isBall = known.isBall or false,
        friendshipBoost = known.friendshipBoost or false,
        icon = key,
      }
      if known.pocket == "tmhm" then
        record.tmhmMoveNativeId = known.tmhmMoveNativeId
      end
      if known.pocket == "berries" then
        record.berryNameSingular = known.berryNameSingular
        record.berryNamePlural = known.berryNamePlural
      end
      items[key] = record
    else
      items["ITEM_" .. nativeId] = placeholder(nativeId, "ITEM_" .. nativeId)
    end
  end
  local pockets = {
    items = { nativeId = 0, capacity = 165, maxQuantity = 999, ordering = "manual" },
    medicine = { nativeId = 1, capacity = 40, maxQuantity = 999, ordering = "manual" },
    balls = { nativeId = 2, capacity = 24, maxQuantity = 999, ordering = "manual" },
    tmhm = { nativeId = 3, capacity = 101, maxQuantity = 99, ordering = "native_id" },
    berries = { nativeId = 4, capacity = 64, maxQuantity = 999, ordering = "native_id" },
    mail = { nativeId = 5, capacity = 12, maxQuantity = 999, ordering = "manual" },
    battle_items = { nativeId = 6, capacity = 30, maxQuantity = 999, ordering = "manual" },
    key_items = { nativeId = 7, capacity = 50, maxQuantity = 999, ordering = "manual" },
  }
  return {
    schema = "g4-item-catalog-v1",
    version = { id = "heartgold", language = "en" },
    items = items,
    pockets = pockets,
    pocketNames = ItemFixture.POCKET_NAMES,
  }
end

function ItemFixture.makeCatalog()
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  return ItemCatalog.new(ItemFixture.buildAssetRoot())
end

return ItemFixture
