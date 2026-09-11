-- Mutable Bag inventory mechanics: pocket capacities, stack limits,
-- sorting, compaction, manual reorder rules, and registration. One stack
-- per item only: a stack-overflow add fails even with free slots, and a
-- take to zero removes the slot and compacts the pocket.

local Assert = require("tests.support.Assert")
local ItemFixture = require("libs.items.tests.item_fixture")
local BagInventory = require("libs.hgss.src.items.BagInventory")

local T = {}

local function inventory()
  return BagInventory.new(ItemFixture.makeCatalog())
end

local function order(slots)
  local keys = {}
  for _, slot in ipairs(slots) do
    keys[#keys + 1] = slot.item
  end
  return keys
end

function T.add_stacks_has_and_quantity_share_one_lookup()
  local bag = inventory()
  Assert.isFalse(bag:has("POTION", 1))
  Assert.equal(bag:quantity("POTION"), 0)
  Assert.isTrue(bag:hasSpace("POTION", 999))
  Assert.isTrue(bag:add("POTION", 5))
  Assert.isTrue(bag:has("POTION", 5))
  Assert.isFalse(bag:has("POTION", 6))
  Assert.equal(bag:quantity("POTION"), 5)
  Assert.isTrue(bag:add("POTION", 4))
  Assert.equal(bag:quantity("POTION"), 9)
end

function T.stack_overflow_fails_without_mutation_despite_free_slots()
  local bag = inventory()
  Assert.isTrue(bag:add("POTION", 999))
  Assert.isFalse(bag:hasSpace("POTION", 1), "a full stack has no space even with free slots")
  Assert.isFalse(bag:add("POTION", 1), "a single stack never splits across slots")
  Assert.equal(bag:quantity("POTION"), 999)
  Assert.deepEqual(order(bag:pocketItems("medicine")), { "POTION" })
end

function T.full_pocket_rejects_a_new_item()
  local bag = inventory()
  local added = 0
  for nativeId = 2, 146, 6 do
    if bag:add("ITEM_" .. nativeId, 1) then
      added = added + 1
    end
  end
  Assert.equal(added, 24, "the ball pocket holds exactly 24 distinct items")
  Assert.isFalse(bag:hasSpace("POKE_BALL", 1))
  Assert.isFalse(bag:add("POKE_BALL", 1))
  Assert.equal(bag:quantity("POKE_BALL"), 0)
end

function T.tm_pocket_uses_the_narrower_stack_maximum()
  local bag = inventory()
  Assert.isFalse(bag:hasSpace("TM01", 100))
  Assert.isFalse(bag:add("TM01", 100))
  Assert.isTrue(bag:add("TM01", 99))
  Assert.equal(bag:quantity("TM01"), 99)
  Assert.isFalse(bag:add("TM01", 1))
end

function T.take_requires_sufficient_quantity_and_compacts_to_zero()
  local bag = inventory()
  Assert.isTrue(bag:add("POKE_BALL", 3))
  Assert.isTrue(bag:add("GREAT_BALL", 2))
  Assert.isFalse(bag:take("POKE_BALL", 4), "taking more than owned fails without mutation")
  Assert.equal(bag:quantity("POKE_BALL"), 3)
  Assert.isFalse(bag:take("LUXURY_BALL", 1), "taking an unowned item fails")
  Assert.isTrue(bag:take("POKE_BALL", 1))
  Assert.equal(bag:quantity("POKE_BALL"), 2)
  Assert.isTrue(bag:take("POKE_BALL", 2), "a take to zero removes the slot")
  Assert.equal(bag:quantity("POKE_BALL"), 0)
  Assert.deepEqual(order(bag:pocketItems("balls")), { "GREAT_BALL" }, "removal compacts the pocket")
end

function T.canonical_pockets_sort_by_native_id_after_add()
  local bag = inventory()
  Assert.isTrue(bag:add("HM01", 1))
  Assert.isTrue(bag:add("TM01", 1))
  Assert.deepEqual(
    order(bag:pocketItems("tmhm")),
    { "TM01", "HM01" },
    "the TM pocket sorts ascending by native id, not insertion order"
  )
  Assert.isTrue(bag:add("SITRUS_BERRY", 4))
  Assert.isTrue(bag:add("CHERI_BERRY", 2))
  Assert.deepEqual(
    order(bag:pocketItems("berries")),
    { "CHERI_BERRY", "SITRUS_BERRY" },
    "the berry pocket sorts ascending by native id"
  )
end

function T.move_reorders_manual_pockets_only()
  local bag = inventory()
  Assert.isTrue(bag:add("POKE_BALL", 1))
  Assert.isTrue(bag:add("GREAT_BALL", 1))
  Assert.isTrue(bag:add("LUXURY_BALL", 1))
  Assert.isTrue(bag:move("balls", 1, 3))
  Assert.deepEqual(order(bag:pocketItems("balls")), { "GREAT_BALL", "LUXURY_BALL", "POKE_BALL" })
  Assert.isFalse(bag:move("balls", 0, 1), "zero-based indexes are out of range")
  Assert.isFalse(bag:move("balls", 1, 4), "indexes past the pocket end are out of range")
  Assert.isFalse(bag:move("balls", 2, 2), "a move without an order change is a no-op")
  Assert.deepEqual(
    order(bag:pocketItems("balls")),
    { "GREAT_BALL", "LUXURY_BALL", "POKE_BALL" },
    "a rejected move leaves the order untouched"
  )
end

function T.move_is_rejected_for_canonical_pockets()
  local bag = inventory()
  Assert.isTrue(bag:add("TM01", 1))
  Assert.isTrue(bag:add("HM01", 1))
  Assert.isFalse(bag:move("tmhm", 1, 2), "the TM pocket never reorders manually")
  Assert.deepEqual(order(bag:pocketItems("tmhm")), { "TM01", "HM01" })
  Assert.isTrue(bag:add("CHERI_BERRY", 1))
  Assert.isFalse(bag:move("berries", 1, 1), "the berry pocket never reorders manually")
end

function T.registration_fills_shifts_and_rejects_duplicates()
  local bag = inventory()
  Assert.isTrue(bag:add("BICYCLE", 1))
  Assert.equal(bag:tryRegister("BICYCLE"), "slot1")
  Assert.isNil(bag:tryRegister("BICYCLE"), "registering the same item twice is rejected")
  Assert.deepEqual(bag:registeredItems(), { "BICYCLE" })
  Assert.isNil(bag:tryRegister("POTION"), "an unowned item cannot be registered")
  Assert.isTrue(bag:add("POTION", 1))
  Assert.isNil(bag:tryRegister("POTION"), "a non-key item cannot be registered")
end

function T.registration_requires_the_source_selectable_policy()
  local bag = inventory()
  local catalog = ItemFixture.makeCatalog()
  Assert.isTrue(catalog:item("BICYCLE").selectable, "BICYCLE carries the source selectable flag")
  Assert.isTrue(bag:add("BICYCLE", 1))
  Assert.notNil(bag:tryRegister("BICYCLE"))
  -- A key pocket item without the selectable flag is not registerable even
  -- when owned; the catalog scan below finds such an item through the
  -- shared pocket contract.
  local plainKeyItem = nil
  for nativeId = 0, 536 do
    local key = catalog:itemKeyByNativeId(nativeId)
    local definition = catalog:item(key)
    if definition.pocket == "key_items" and not definition.selectable then
      plainKeyItem = key
      break
    end
  end
  assert(plainKeyItem ~= nil, "the catalog carries a non-selectable key item")
  Assert.isTrue(bag:add(plainKeyItem, 1))
  Assert.isNil(bag:tryRegister(plainKeyItem), "a non-selectable key item cannot be registered")
end

function T.unregistering_slot_one_shifts_slot_two()
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  local root = ItemFixture.buildAssetRoot()
  root.items.ITEM_5.selectable = true
  local catalog = ItemCatalog.new(root)
  local bag = BagInventory.new(catalog)
  Assert.isTrue(bag:add("BICYCLE", 1))
  Assert.isTrue(bag:add("ITEM_5", 1))
  Assert.equal(bag:tryRegister("BICYCLE"), "slot1")
  Assert.equal(bag:tryRegister("ITEM_5"), "slot2")
  Assert.isNil(bag:tryRegister("ITEM_5"), "a third registration while both slots fill fails")
  Assert.isTrue(bag:unregister("BICYCLE"), "unregistering slot one shifts slot two forward")
  Assert.deepEqual(bag:registeredItems(), { "ITEM_5" })
  Assert.isTrue(bag:unregister("ITEM_5"))
  Assert.deepEqual(bag:registeredItems(), {})
  Assert.isFalse(bag:unregister("ITEM_5"), "unregistering an unregistered item fails")
end

function T.removing_the_final_copy_unregisters_the_item()
  local bag = inventory()
  Assert.isTrue(bag:add("BICYCLE", 1))
  Assert.equal(bag:tryRegister("BICYCLE"), "slot1")
  Assert.isTrue(bag:take("BICYCLE", 1))
  Assert.deepEqual(bag:registeredItems(), {}, "the final removal clears registration")
  Assert.deepEqual(bag:pocketItems("key_items"), {})
end

function T.pocket_items_returns_fresh_copies()
  local bag = inventory()
  Assert.isTrue(bag:add("POTION", 5))
  local first = bag:pocketItems("medicine")
  first[1].quantity = 999
  first[2] = { item = "POTION", quantity = 1 }
  Assert.equal(bag:quantity("POTION"), 5, "mutating the observed slots must not reach the inventory")
end

function T.invalid_arguments_fail_loudly_without_mutation()
  local bag = inventory()
  Assert.throws(function()
    bag:add("POTION", 0)
  end)
  Assert.throws(function()
    bag:add("POTION", -2)
  end)
  Assert.throws(function()
    bag:add("BOGUS_ITEM", 1)
  end)
  Assert.throws(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- the fractional quantity is the invalid input under test
    bag:take("POTION", 1.5)
  end)
  Assert.equal(bag:quantity("POTION"), 0)
  Assert.deepEqual(bag:pocketItems("medicine"), {})
end

return { tests = T }
