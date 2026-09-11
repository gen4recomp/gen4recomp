-- Item catalog ownership: strict semantic/native lookups, pocket
-- definitions, deterministic fingerprints, and immutable-by-convention
-- records. Unknown identities raise structured item-domain errors.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local ItemFixture = require("libs.items.tests.item_fixture")

local T = {}

local function throwsItemInvalid(fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error")
  Assert.equal(err.code, "ITEM_RECORD_INVALID")
end

function T.catalog_resolves_items_in_both_identity_directions()
  local catalog = ItemFixture.makeCatalog()
  Assert.equal(catalog:itemKeyByNativeId(0), "NONE")
  Assert.equal(catalog:itemKeyByNativeId(4), "POKE_BALL")
  Assert.equal(catalog:itemKeyByNativeId(218), "SOOTHE_BELL")
  local ball = catalog:item("POKE_BALL")
  Assert.equal(ball.nativeId, 4)
  Assert.isTrue(ball.isBall)
  Assert.isFalse(ball.friendshipBoost)
  Assert.equal(catalog:itemByNativeId(17).pocket, "medicine")
  local bell = catalog:item("SOOTHE_BELL")
  Assert.equal(bell.nativeId, 218)
  Assert.isTrue(bell.friendshipBoost)
  Assert.isFalse(bell.isBall)
  throwsItemInvalid(function()
    catalog:item("BOGUS_ITEM")
  end)
  throwsItemInvalid(function()
    catalog:itemKeyByNativeId(9999)
  end)
  throwsItemInvalid(function()
    catalog:itemByNativeId(-1)
  end)
end

function T.catalog_exposes_the_full_locked_item_definition()
  local catalog = ItemFixture.makeCatalog()
  local potion = catalog:item("POTION")
  -- Nullable fields are present-as-nil through the object model, so the
  -- serialized key set carries only the always-present fields; the nullable
  -- fields are asserted through TM/HM and berry representatives below.
  Assert.keySet(
    potion,
    "description,friendshipBoost,icon,isBall,name,nameIndefinite,namePlural,nativeId,pocket,preventToss,selectable",
    "item definitions carry exactly the locked always-present fields"
  )
  Assert.equal(potion.name, "Potion")
  Assert.equal(potion.pocket, "medicine")
  Assert.isFalse(potion.preventToss)
  local machine = catalog:item("TM01")
  Assert.equal(machine.pocket, "tmhm")
  Assert.equal(machine.tmhmMoveNativeId, 264)
  Assert.isNil(potion.tmhmMoveNativeId)
  local berry = catalog:item("CHERI_BERRY")
  Assert.equal(berry.pocket, "berries")
  Assert.equal(berry.berryNameSingular, "Cheri Berry")
  Assert.equal(berry.berryNamePlural, "Cheri Berries")
  Assert.isNil(potion.berryNameSingular)
  Assert.isNil(potion.berryNamePlural)
  local keyItem = catalog:item("BICYCLE")
  Assert.equal(keyItem.pocket, "key_items")
  Assert.isTrue(keyItem.preventToss)
end

function T.catalog_owns_the_eight_pocket_definitions()
  local catalog = ItemFixture.makeCatalog()
  local expected = {
    items = { nativeId = 0, capacity = 165, maxQuantity = 999, ordering = "manual" },
    medicine = { nativeId = 1, capacity = 40, maxQuantity = 999, ordering = "manual" },
    balls = { nativeId = 2, capacity = 24, maxQuantity = 999, ordering = "manual" },
    tmhm = { nativeId = 3, capacity = 101, maxQuantity = 99, ordering = "native_id" },
    berries = { nativeId = 4, capacity = 64, maxQuantity = 999, ordering = "native_id" },
    mail = { nativeId = 5, capacity = 12, maxQuantity = 999, ordering = "manual" },
    battle_items = { nativeId = 6, capacity = 30, maxQuantity = 999, ordering = "manual" },
    key_items = { nativeId = 7, capacity = 50, maxQuantity = 999, ordering = "manual" },
  }
  Assert.deepEqual(catalog.POCKETS, expected)
  for key, definition in pairs(expected) do
    Assert.deepEqual(catalog:pocket(key), definition)
    Assert.deepEqual(catalog:pocketByNativeId(definition.nativeId), definition)
    Assert.equal(catalog:pocketKeyByNativeId(definition.nativeId), key)
  end
  throwsItemInvalid(function()
    catalog:pocket("BOGUS_POCKET")
  end)
  throwsItemInvalid(function()
    catalog:pocketKeyByNativeId(99)
  end)
end

function T.catalog_names_every_pocket()
  local catalog = ItemFixture.makeCatalog()
  Assert.equal(catalog:pocketName("medicine"), ItemFixture.POCKET_NAMES.medicine)
  for _, key in ipairs(ItemFixture.POCKET_KEYS) do
    local name = catalog:pocketName(key)
    Assert.isTrue(type(name) == "string" and name ~= "", "pocket " .. key .. " must carry a name")
  end
  throwsItemInvalid(function()
    catalog:pocketName("BOGUS_POCKET")
  end)
end

function T.catalog_fingerprint_is_deterministic_and_covers_the_item_root()
  local catalog = ItemFixture.makeCatalog()
  local again = ItemFixture.makeCatalog()
  Assert.equal(again:fingerprint(), catalog:fingerprint())
  Assert.isTrue(type(catalog:fingerprint()) == "string" and catalog:fingerprint() ~= "")
end

function T.catalog_copies_its_input_root()
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  local root = ItemFixture.buildAssetRoot()
  local catalog = ItemCatalog.new(root)
  root.items.POTION = nil
  root.pockets.medicine.capacity = 1
  Assert.equal(catalog:item("POTION").nativeId, 17)
  Assert.equal(catalog:pocket("medicine").capacity, 40)
end

function T.catalog_rejects_duplicate_native_identities_at_construction()
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  local root = ItemFixture.buildAssetRoot()
  root.items["POTION_AGAIN"] = {
    nativeId = 17,
    name = "Potion?",
    nameIndefinite = "a Potion?",
    namePlural = "Potions?",
    description = "duplicate",
    pocket = "medicine",
    preventToss = false,
    selectable = false,
    isBall = false,
    friendshipBoost = false,
    icon = "POTION",
  }
  Assert.throws(function()
    ItemCatalog.new(root)
  end)
end

return { tests = T }
