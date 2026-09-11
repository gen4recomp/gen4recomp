-- Persisted Bag bucket: strict shape, semantic validation against the
-- shared item catalog, and capture/validate round trips. Unknown fields,
-- wrong pockets, duplicates, quantity/capacity overflow, unsorted canonical
-- pockets, and invalid registration are rejected, never repaired.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local ItemFixture = require("libs.items.tests.item_fixture")
local BagSave = require("libs.hgss.src.save.BagSave")

local T = {}

local function emptyPockets()
  return {
    items = {},
    medicine = {},
    balls = {},
    tmhm = {},
    berries = {},
    mail = {},
    battle_items = {},
    key_items = {},
  }
end

local function record(overrides)
  local value = {
    schema = "hgss-bag-v1",
    pockets = emptyPockets(),
    registered = {},
  }
  for key, replacement in pairs(overrides or {}) do
    rawset(value, key, replacement)
  end
  return value
end

local function rejectionCode(candidate, catalog)
  local valid, err = BagSave.validate(candidate, catalog)
  Assert.isNil(valid, "the malformed bag must not validate")
  Assert.isTrue(Errors.is(err), "rejection uses the structured save-error path")
  return assert(err).code
end

function T.empty_and_populated_captures_validate()
  local catalog = ItemFixture.makeCatalog()
  local valid = assert(BagSave.validate(BagSave.empty(), catalog))
  Assert.equal(valid.schema, "hgss-bag-v1")
  Assert.deepEqual(valid.registered, {})
  for _, pocket in ipairs(ItemFixture.POCKET_KEYS) do
    Assert.deepEqual(valid.pockets[pocket], {}, "pocket " .. pocket .. " starts empty")
  end

  local pockets = emptyPockets()
  pockets.medicine = { { item = "POTION", quantity = 5 } }
  pockets.balls = { { item = "POKE_BALL", quantity = 3 }, { item = "GREAT_BALL", quantity = 2 } }
  pockets.key_items = { { item = "BICYCLE", quantity = 1 } }
  local populated = assert(BagSave.validate(record({ pockets = pockets, registered = { "BICYCLE" } }), catalog))
  Assert.equal(populated.pockets.medicine[1].quantity, 5)
  Assert.deepEqual(populated.registered, { "BICYCLE" })
end

function T.empty_returns_a_fresh_record_per_call()
  local first = BagSave.empty()
  first.pockets.medicine[1] = { item = "POTION", quantity = 1 }
  first.registered[1] = "BICYCLE"
  local second = BagSave.empty()
  Assert.deepEqual(second.pockets.medicine, {})
  Assert.deepEqual(second.registered, {})
end

function T.validation_rejects_structural_defects()
  local catalog = ItemFixture.makeCatalog()
  Assert.equal(rejectionCode(record({ schema = "hgss-bag-v0" }), catalog), "GAME_SAVE_BUCKET_INVALID")
  local noPockets = record()
  noPockets.pockets = nil
  Assert.equal(rejectionCode(noPockets, catalog), "GAME_SAVE_BUCKET_INVALID")
  local noRegistered = record()
  noRegistered.registered = nil
  Assert.equal(rejectionCode(noRegistered, catalog), "GAME_SAVE_BUCKET_INVALID")
  Assert.equal(
    rejectionCode(record({ pockets = emptyPockets(), registered = {}, extra = {} }), catalog),
    "GAME_SAVE_BUCKET_INVALID"
  )
  local pockets = emptyPockets()
  pockets.medicine = { { item = "BOGUS_ITEM", quantity = 1 } }
  Assert.equal(rejectionCode(record({ pockets = pockets }), catalog), "GAME_SAVE_BUCKET_INVALID")
  local noPocket = emptyPockets()
  noPocket.balls = nil
  Assert.equal(rejectionCode(record({ pockets = noPocket }), catalog), "GAME_SAVE_BUCKET_INVALID")
end

function T.validation_rejects_wrong_pocket_and_duplicates()
  local catalog = ItemFixture.makeCatalog()
  local misplaced = emptyPockets()
  misplaced.balls = { { item = "POTION", quantity = 1 } }
  Assert.equal(
    rejectionCode(record({ pockets = misplaced }), catalog),
    "GAME_SAVE_BUCKET_INVALID",
    "an item outside its catalog pocket is rejected"
  )
  local duplicated = emptyPockets()
  duplicated.medicine = { { item = "POTION", quantity = 1 }, { item = "POTION", quantity = 2 } }
  Assert.equal(
    rejectionCode(record({ pockets = duplicated }), catalog),
    "GAME_SAVE_BUCKET_INVALID",
    "a repeated item in one pocket is rejected"
  )
  local crossPocket = emptyPockets()
  crossPocket.medicine = { { item = "POTION", quantity = 1 } }
  crossPocket.balls = { { item = "POTION", quantity = 1 } }
  Assert.equal(
    rejectionCode(record({ pockets = crossPocket }), catalog),
    "GAME_SAVE_BUCKET_INVALID",
    "an item stored in two pockets is rejected"
  )
end

function T.validation_rejects_quantity_and_capacity_overflow()
  local catalog = ItemFixture.makeCatalog()
  for _, quantity in ipairs({ 0, -1, 1.5, 1000, "5" }) do
    local pockets = emptyPockets()
    pockets.medicine = { { item = "POTION", quantity = quantity } }
    Assert.equal(
      rejectionCode(record({ pockets = pockets }), catalog),
      "GAME_SAVE_BUCKET_INVALID",
      "quantity " .. tostring(quantity) .. " is rejected"
    )
  end
  local machine = emptyPockets()
  machine.tmhm = { { item = "TM01", quantity = 100 } }
  Assert.equal(
    rejectionCode(record({ pockets = machine }), catalog),
    "GAME_SAVE_BUCKET_INVALID",
    "a TM stack above 99 is rejected"
  )
  local full = emptyPockets()
  for nativeId = 2, 146, 6 do
    full.balls[#full.balls + 1] = { item = "ITEM_" .. nativeId, quantity = 1 }
  end
  full.balls[#full.balls + 1] = { item = "POKE_BALL", quantity = 1 }
  Assert.isTrue(#full.balls > 24, "the crowded pocket exceeds the 24-slot ball capacity")
  Assert.equal(
    rejectionCode(record({ pockets = full }), catalog),
    "GAME_SAVE_BUCKET_INVALID",
    "an over-capacity pocket is rejected"
  )
end

function T.validation_rejects_unsorted_canonical_pockets()
  local catalog = ItemFixture.makeCatalog()
  local machines = emptyPockets()
  machines.tmhm = { { item = "HM01", quantity = 1 }, { item = "TM01", quantity = 1 } }
  Assert.equal(
    rejectionCode(record({ pockets = machines }), catalog),
    "GAME_SAVE_BUCKET_INVALID",
    "a TM pocket out of native-id order is rejected"
  )
  local sorted = emptyPockets()
  sorted.tmhm = { { item = "TM01", quantity = 1 }, { item = "HM01", quantity = 1 } }
  Assert.notNil(BagSave.validate(record({ pockets = sorted }), catalog))
  local berries = emptyPockets()
  berries.berries = { { item = "SITRUS_BERRY", quantity = 4 }, { item = "CHERI_BERRY", quantity = 2 } }
  Assert.equal(
    rejectionCode(record({ pockets = berries }), catalog),
    "GAME_SAVE_BUCKET_INVALID",
    "a berry pocket out of native-id order is rejected"
  )
end

function T.validation_rejects_invalid_registration()
  local catalog = ItemFixture.makeCatalog()
  local function registeredCandidate(registered, pockets)
    return record({ pockets = pockets or emptyPockets(), registered = registered })
  end
  Assert.equal(
    rejectionCode(registeredCandidate({ "BICYCLE", "BICYCLE" }), catalog),
    "GAME_SAVE_BUCKET_INVALID",
    "a duplicated registered item is rejected"
  )
  Assert.equal(
    rejectionCode(registeredCandidate({ "BICYCLE", "BICYCLE", "BICYCLE" }), catalog),
    "GAME_SAVE_BUCKET_INVALID",
    "more than two registered items are rejected"
  )
  local owned = emptyPockets()
  owned.key_items = { { item = "BICYCLE", quantity = 1 } }
  Assert.equal(
    rejectionCode(registeredCandidate({ "BOGUS_ITEM" }, owned), catalog),
    "GAME_SAVE_BUCKET_INVALID",
    "a registered unknown item is rejected"
  )
  local potion = emptyPockets()
  potion.medicine = { { item = "POTION", quantity = 5 } }
  Assert.equal(
    rejectionCode(registeredCandidate({ "POTION" }, potion), catalog),
    "GAME_SAVE_BUCKET_INVALID",
    "an owned but non-registerable item is rejected"
  )
  local shifted = { [2] = "BICYCLE" }
  Assert.equal(
    rejectionCode(registeredCandidate(shifted, owned), catalog),
    "GAME_SAVE_BUCKET_INVALID",
    "a populated slot two with an empty slot one is rejected"
  )
end

function T.unowned_registerable_registration_validates()
  local catalog = ItemFixture.makeCatalog()
  local valid = assert(BagSave.validate(record({ pockets = emptyPockets(), registered = { "BICYCLE" } }), catalog))
  Assert.deepEqual(valid.registered, { "BICYCLE" }, "a known registerable item stays valid without possession")
end

function T.capture_validate_round_trip_preserves_manual_order_and_quantities()
  local catalog = ItemFixture.makeCatalog()
  local BagInventory = require("libs.hgss.src.items.BagInventory")
  local inventory = BagInventory.new(catalog)
  Assert.isTrue(inventory:add("GREAT_BALL", 2))
  Assert.isTrue(inventory:add("POKE_BALL", 3))
  Assert.isTrue(inventory:add("POTION", 5))
  Assert.isTrue(inventory:add("BICYCLE", 1))
  Assert.notNil(inventory:tryRegister("BICYCLE"))
  local captured = BagSave.capture(inventory)
  local valid = assert(BagSave.validate(captured, catalog))
  local rebuilt = BagInventory.new(catalog, valid)
  Assert.deepEqual(rebuilt:capture(), captured, "a validated capture rebuilds the exact manual order")
end

function T.final_removal_capture_round_trips_with_registration()
  local catalog = ItemFixture.makeCatalog()
  local BagInventory = require("libs.hgss.src.items.BagInventory")
  local inventory = BagInventory.new(catalog)
  Assert.isTrue(inventory:add("BICYCLE", 1))
  Assert.notNil(inventory:tryRegister("BICYCLE"))
  Assert.isTrue(inventory:take("BICYCLE", 1))
  local captured = BagSave.capture(inventory)
  local valid = assert(BagSave.validate(captured, catalog))
  local rebuilt = BagInventory.new(catalog, valid)
  Assert.equal(rebuilt:quantity("BICYCLE"), 0)
  Assert.deepEqual(rebuilt:registeredItems(), { "BICYCLE" }, "the rebuilt bag keeps the registration")
  Assert.deepEqual(rebuilt:capture(), captured, "a validated stale capture rebuilds exactly")
end

return { tests = T }
