-- Field-facing Bag facade: one inventory, one revision, native-ID
-- adapters for script-adjacent callers, and save capture. Every successful
-- semantic mutation bumps the revision exactly once; failed mutations,
-- no-ops, and queries never do.

local Assert = require("tests.support.Assert")
local ItemFixture = require("libs.items.tests.item_fixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")

local T = {}

local function service(bag)
  return HgssBagService.new({ catalog = ItemFixture.makeCatalog(), bag = bag })
end

function T.service_starts_empty_with_zero_revision()
  local bag = service()
  Assert.equal(bag:revision(), 0)
  Assert.equal(bag:quantity("POTION"), 0)
  Assert.deepEqual(bag:registeredItems(), {})
  Assert.deepEqual(bag:pocketItems("balls"), {})
end

function T.service_restores_from_a_validated_capture()
  local first = service()
  Assert.isTrue(first:add("POTION", 5))
  Assert.isTrue(first:add("BICYCLE", 1))
  Assert.notNil(first:tryRegister("BICYCLE"))
  local second = service(first:capture())
  Assert.equal(second:quantity("POTION"), 5)
  Assert.deepEqual(second:registeredItems(), { "BICYCLE" })
  Assert.equal(second:revision(), 0, "a restored service restarts its runtime revision")
end

function T.service_rejects_an_invalid_restore_without_publishing_state()
  Assert.throws(function()
    return service({ schema = "hgss-bag-v1", pockets = {}, registered = {} })
  end)
end

function T.revision_bumps_once_per_successful_mutation_only()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5))
  Assert.equal(bag:revision(), 1)
  Assert.isTrue(bag:add("POKE_BALL", 3))
  Assert.equal(bag:revision(), 2)
  Assert.isTrue(bag:take("POTION", 2))
  Assert.equal(bag:revision(), 3)
  Assert.isTrue(bag:move("balls", 1, 1) == false, "a no-op move reports failure")
  Assert.equal(bag:revision(), 3, "a no-op move never bumps the revision")
  Assert.isFalse(bag:add("POTION", 1000), "an overflowing add fails")
  Assert.equal(bag:revision(), 3, "a failed add never bumps the revision")
  Assert.isFalse(bag:take("POTION", 99), "an insufficient take fails")
  Assert.equal(bag:revision(), 3, "a failed take never bumps the revision")
  Assert.isTrue(bag:add("BICYCLE", 1))
  Assert.equal(bag:revision(), 4)
  Assert.notNil(bag:tryRegister("BICYCLE"))
  Assert.equal(bag:revision(), 5)
  Assert.isNil(bag:tryRegister("BICYCLE"), "a duplicate registration fails")
  Assert.equal(bag:revision(), 5, "a failed registration never bumps the revision")
  Assert.isTrue(bag:unregister("BICYCLE"))
  Assert.equal(bag:revision(), 6)
  Assert.isFalse(bag:unregister("BICYCLE"))
  Assert.equal(bag:revision(), 6, "a failed unregistration never bumps the revision")
end

function T.queries_never_bump_the_revision()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5))
  local revision = bag:revision()
  Assert.isTrue(bag:has("POTION", 5))
  Assert.isFalse(bag:has("POTION", 6))
  Assert.isTrue(bag:hasSpace("POTION", 1))
  Assert.equal(bag:quantity("POTION"), 5)
  Assert.equal(bag:pocketOf("POTION"), "medicine")
  Assert.equal(bag:pocketNativeId("POTION"), 1)
  Assert.isFalse(bag:isTMHM("POTION"))
  Assert.isTrue(bag:isTMHM("TM01"))
  Assert.notNil(bag:pocketItems("medicine"))
  Assert.notNil(bag:registeredItems())
  Assert.notNil(bag:capture())
  Assert.equal(bag:revision(), revision, "no query moves the revision")
end

function T.native_adapters_resolve_through_the_catalog()
  local bag = service()
  local catalog = bag:catalog()
  Assert.isTrue(bag:addNative(catalog:item("POTION").nativeId, 5))
  Assert.equal(bag:quantityNative(catalog:item("POTION").nativeId), 5)
  Assert.isTrue(bag:hasNative(catalog:item("POTION").nativeId, 5))
  Assert.isTrue(bag:hasSpaceNative(catalog:item("POKE_BALL").nativeId, 3))
  Assert.isTrue(bag:takeNative(catalog:item("POTION").nativeId, 2))
  Assert.equal(bag:quantity("POTION"), 3)
  Assert.throws(function()
    bag:addNative(9999, 1)
  end, "an unknown native identity fails loudly")
  Assert.equal(bag:revision(), 2, "only the two successful native mutations bump the revision")
end

function T.native_catalog_queries_match_their_key_forms()
  local bag = service()
  local catalog = bag:catalog()
  local potion = catalog:item("POTION").nativeId
  local machine = catalog:item("TM01").nativeId
  Assert.isFalse(bag:isTMHMNative(potion))
  Assert.isTrue(bag:isTMHMNative(machine))
  Assert.equal(bag:pocketNativeIdNative(potion), bag:pocketNativeId("POTION"))
  Assert.equal(bag:pocketNativeIdNative(machine), 3)
  Assert.throws(function()
    bag:isTMHMNative(9999)
  end, "an unknown native identity fails loudly")
  Assert.throws(function()
    bag:pocketNativeIdNative(9999)
  end, "an unknown native identity fails loudly")
end

function T.native_registration_adapters_match_their_key_forms()
  local bag = service()
  local catalog = bag:catalog()
  local bicycle = catalog:item("BICYCLE").nativeId
  Assert.isTrue(bag:addNative(bicycle, 1))
  Assert.notNil(bag:tryRegisterNative(bicycle))
  Assert.deepEqual(bag:registeredItems(), { "BICYCLE" })
  Assert.isTrue(bag:unregisterNative(bicycle))
  Assert.deepEqual(bag:registeredItems(), {})
end

function T.registerability_follows_the_source_selectable_policy()
  local bag = service()
  Assert.isTrue(bag:isRegisterable("BICYCLE"))
  Assert.isFalse(bag:isRegisterable("POTION"))
  Assert.throws(function()
    bag:isRegisterable("BOGUS_ITEM")
  end, "an unknown item fails loudly")
end

function T.capture_carries_no_cursor_or_revision_state()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5))
  local captured = bag:capture()
  Assert.equal(captured.schema, "hgss-bag-v1")
  Assert.isTrue(captured.revision == nil, "the runtime revision never enters the save")
  Assert.isTrue(captured.cursor == nil and captured.scroll == nil and captured.page == nil)
  Assert.equal(captured.pockets.medicine[1].quantity, 5)
end

return { tests = T }
