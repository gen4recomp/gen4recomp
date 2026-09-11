-- Pure inventory-local action menu projection: toss follows the source
-- toss metadata, move follows manual ordering plus occupancy, registration
-- follows the two-slot state machine, the menu never leaves the
-- inventory-local set, and an empty selection offers only the way out.
-- Literal semantic facts only; no service, no catalog, no love.

local Assert = require("tests.support.Assert")
local BagActionPolicy = require("libs.hgss.src.ui.BagActionPolicy")

local T = {}

local function facts(overrides)
  local record = {
    itemKey = "POTION",
    preventToss = false,
    registerable = false,
    registered = false,
    pocketOrdering = "manual",
    pocketCount = 2,
    registeredCount = 0,
  }
  for key, value in pairs(overrides or {}) do
    record[key] = value
  end
  return record
end

local function ids(actions)
  local out = {}
  for index, action in ipairs(actions) do
    assert(type(action.id) == "string" and action.id ~= "", "menu actions carry a semantic id")
    Assert.isTrue(action.enabled == true, "offered actions stay enabled")
    out[index] = action.id
  end
  return out
end

local function has(actions, id)
  for _, action in ipairs(actions) do
    if action.id == id then
      return true
    end
  end
  return false
end

function T.toss_follows_the_source_toss_metadata()
  Assert.isTrue(has(BagActionPolicy.actionsFor(facts()), "toss"), "a tossable item offers to toss")
  Assert.isFalse(
    has(BagActionPolicy.actionsFor(facts({ preventToss = true })), "toss"),
    "a protected item never offers to toss"
  )
end

function T.move_needs_a_manual_pocket_with_room_to_reorder()
  Assert.isTrue(has(BagActionPolicy.actionsFor(facts()), "move"), "a manual pocket with two items offers to move")
  Assert.isFalse(
    has(BagActionPolicy.actionsFor(facts({ pocketOrdering = "native_id" })), "move"),
    "a canonical-order pocket never offers to move"
  )
  Assert.isFalse(has(BagActionPolicy.actionsFor(facts({ pocketCount = 1 })), "move"), "a lone item has nowhere to move")
end

function T.registration_offers_exactly_one_direction()
  Assert.isTrue(
    has(BagActionPolicy.actionsFor(facts({ registerable = true })), "register"),
    "an unregistered registerable item offers to register"
  )
  Assert.isFalse(
    has(BagActionPolicy.actionsFor(facts({ registerable = true })), "unregister"),
    "an unregistered item never offers to unregister"
  )
  local registered = facts({ registerable = true, registered = true, registeredCount = 1 })
  Assert.isTrue(has(BagActionPolicy.actionsFor(registered), "unregister"), "a registered item offers to unregister")
  Assert.isFalse(has(BagActionPolicy.actionsFor(registered), "register"), "a registered item never registers again")
  Assert.isFalse(
    has(BagActionPolicy.actionsFor(facts({ registerable = false })), "register"),
    "an ordinary item never offers to register"
  )
  Assert.isFalse(
    has(BagActionPolicy.actionsFor(facts({ registerable = false })), "unregister"),
    "an ordinary item never offers to unregister"
  )
end

function T.full_registration_omits_register_without_a_replacement()
  local full = facts({ registerable = true, registeredCount = 2 })
  Assert.isFalse(has(BagActionPolicy.actionsFor(full), "register"), "a full registration leaves no register path")
  Assert.isFalse(
    has(BagActionPolicy.actionsFor(full), "unregister"),
    "an unregistered item still offers no unregister when full"
  )
end

function T.cancel_is_always_present_and_empty_selections_offer_only_cancel()
  Assert.isTrue(has(BagActionPolicy.actionsFor(facts()), "cancel"), "every menu offers the way out")
  local empty = facts()
  empty.itemKey = nil
  Assert.deepEqual(ids(BagActionPolicy.actionsFor(empty)), { "cancel" }, "no selection means no inventory action")
end

function T.menus_stay_inside_the_inventory_local_set()
  local allowed = { toss = true, move = true, register = true, unregister = true, cancel = true }
  local cases = {
    facts(),
    facts({ preventToss = true }),
    facts({ pocketOrdering = "native_id" }),
    facts({ pocketCount = 1 }),
    facts({ registerable = true }),
    facts({ registerable = true, registered = true, registeredCount = 1 }),
    facts({ registerable = true, registeredCount = 2 }),
  }
  local empty = facts()
  empty.itemKey = nil
  cases[#cases + 1] = empty
  for _, case in ipairs(cases) do
    for _, id in ipairs(ids(BagActionPolicy.actionsFor(case))) do
      Assert.isTrue(allowed[id] == true, "the menu stays inventory-local: " .. tostring(id))
    end
  end
end

return { tests = T }
