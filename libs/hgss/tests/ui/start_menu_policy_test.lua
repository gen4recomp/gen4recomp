-- StartMenuPolicy contract tests: the pure canonical action definitions and
-- the normal-field progression rules for the implemented field context. The
-- facts are the seven unlock values the runtime reads from the event-state
-- flags (the CheckGot*/FLAG_GOT_* gates, start_menu.c:535-556) as ordinary
-- internal data; each source action separates list presence (the source
-- inhibit masks, start_menu.c:288-331) from the gameplay unlock gate
-- (source enablement). actions() returns every source-present entry with its
-- source-enablement state and routing metadata, independent of
-- implementation capability -- the runtime is the sole place that composes
-- this with the registered destination applications. Source evidence:
-- pret/pokeheartgold@008257708: src/start_menu.c and src/sys_flags.c.

local Assert = require("tests.support.Assert")
local StartMenuPolicy = require("libs.hgss.src.ui.StartMenuPolicy")

local T = {
  tests = {},
}

local FRESH = {
  hasPokedex = false,
  hasStarter = false,
  bagUnlocked = false,
  hasPokegear = false,
  trainerCardUnlocked = false,
  saveUnlocked = false,
  optionsUnlocked = false,
}

local function fullFacts()
  return {
    hasPokedex = true,
    hasStarter = true,
    bagUnlocked = true,
    hasPokegear = true,
    trainerCardUnlocked = true,
    saveUnlocked = true,
    optionsUnlocked = true,
  }
end

local function facts(overrides)
  local value = fullFacts()
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

local function actionById(actions, id)
  for _, action in ipairs(actions) do
    if action.id == id then
      return action
    end
  end
  return nil
end

-- No application predicate: the API takes only the source facts.
function T.tests.actions_accepts_only_source_facts()
  local actions = StartMenuPolicy.actions(facts())
  Assert.isTrue(#actions > 0, "actions() takes exactly one argument: the facts")
end

-- A fresh game still returns source-present entries even though none of
-- them are unlockable yet: Trainer Card, Save, Options (unconditionally
-- present, unlockedBy gates their sourceEnabled) and Running Shoes/specials
-- (never inhibited).
function T.tests.fresh_facts_still_return_source_present_entries()
  local actions = StartMenuPolicy.actions(FRESH)
  Assert.isTrue(#actions > 0, "a fresh game still has source-present entries")
  local unlockable = { "vanilla.trainer_card", "vanilla.save", "vanilla.options" }
  for _, id in ipairs(unlockable) do
    local action = assert(actionById(actions, id), id .. " must be present in a fresh game")
    Assert.equal(action.sourceEnabled, false, id .. " is present but not source-enabled in a fresh game")
  end
end

-- Trainer Card, Save, and Options are never inhibited by presence facts, so
-- they can be present with sourceEnabled=false whenever their unlock fact is
-- false, independent of each other.
function T.tests.trainer_card_save_options_present_with_source_enabled_false()
  local actions = StartMenuPolicy.actions(facts({
    trainerCardUnlocked = false,
    saveUnlocked = false,
    optionsUnlocked = true,
  }))
  Assert.equal(assert(actionById(actions, "vanilla.trainer_card")).sourceEnabled, false)
  Assert.equal(assert(actionById(actions, "vanilla.save")).sourceEnabled, false)
  Assert.equal(assert(actionById(actions, "vanilla.options")).sourceEnabled, true)
end

-- Pokedex/Pokemon/Bag/Pokegear presence follows the source inhibit facts
-- exactly: each is present only when its own fact is true, and absence does
-- not touch the presence of the others.
function T.tests.pokedex_pokemon_bag_pokegear_presence_follows_inhibit_facts()
  local none = StartMenuPolicy.actions(FRESH)
  for _, id in ipairs({ "vanilla.pokedex", "vanilla.pokemon", "vanilla.bag", "vanilla.pokegear" }) do
    Assert.isNil(actionById(none, id), id .. " must be absent when its fact is false")
  end

  local all = StartMenuPolicy.actions(fullFacts())
  for _, id in ipairs({ "vanilla.pokedex", "vanilla.pokemon", "vanilla.bag", "vanilla.pokegear" }) do
    Assert.notNil(actionById(all, id), id .. " must be present when its fact is true")
  end

  local onlyBag = StartMenuPolicy.actions(facts({ hasPokedex = false, hasStarter = false, hasPokegear = false }))
  Assert.isNil(actionById(onlyBag, "vanilla.pokedex"))
  Assert.isNil(actionById(onlyBag, "vanilla.pokemon"))
  Assert.notNil(actionById(onlyBag, "vanilla.bag"))
  Assert.isNil(actionById(onlyBag, "vanilla.pokegear"))
end

-- The unconditional special Pokégear-family entries occupy the reserved
-- display positions regardless of any other fact.
function T.tests.special_9_uses_display_position_7()
  Assert.equal(assert(actionById(StartMenuPolicy.actions(FRESH), "vanilla.special_9")).displayPosition, 7)
end

function T.tests.special_10_uses_display_position_8()
  Assert.equal(assert(actionById(StartMenuPolicy.actions(FRESH), "vanilla.special_10")).displayPosition, 8)
end

-- Running Shoes has no application destination but is never inhibited, so
-- its source membership does not depend on any implementation existing.
function T.tests.running_shoes_membership_is_not_removed_for_lacking_a_destination()
  local action = assert(actionById(StartMenuPolicy.actions(FRESH), "vanilla.running_shoes"))
  Assert.equal(action.actionKind, "toggle")
  Assert.isNil(action.targetApplication, "running shoes has no application destination")
end

-- actions() separates source enablement from any notion of implementation
-- availability -- it never asks anything about registered applications.
function T.tests.actions_includes_source_enabled_distinct_from_implementation()
  local withUnlock = facts({ trainerCardUnlocked = true, saveUnlocked = true })
  local actions = StartMenuPolicy.actions(withUnlock)
  Assert.equal(assert(actionById(actions, "vanilla.trainer_card")).sourceEnabled, true)
  Assert.equal(assert(actionById(actions, "vanilla.save")).sourceEnabled, true)
end

-- With full facts, all 10 source-present actions appear (pokedex, pokemon,
-- bag, pokegear, trainer_card, save, options, running_shoes, special_9,
-- special_10). The retired actions (retire, special_7) are never present.
function T.tests.actions_does_not_query_applications()
  local actions = StartMenuPolicy.actions(facts())
  Assert.equal(#actions, 10, "full facts produce all source-present actions")
  Assert.isNil(actionById(actions, "vanilla.retire"))
  Assert.isNil(actionById(actions, "vanilla.special_7"))
  for _, action in ipairs(actions) do
    if action.actionKind == "application" then
      Assert.notNil(action.targetApplication, "app action has targetApplication")
    else
      Assert.isNil(action.targetApplication, "non-app action has no targetApplication")
    end
  end
end

-- Visual slots are fixed retail identities, never compacted by presence: when
-- pokedex is not present, pokemon keeps position 1 and trainer_card keeps
-- position 4, leaving holes where the absent actions would draw.
function T.tests.actions_preserves_display_positions_by_presence()
  local withoutPokedex = facts({ hasPokedex = false })
  local actions = StartMenuPolicy.actions(withoutPokedex)
  Assert.equal(assert(actionById(actions, "vanilla.pokemon")).displayPosition, 1)
  Assert.equal(assert(actionById(actions, "vanilla.trainer_card")).displayPosition, 4)
end

-- The seven normal actions own stable retail visual slots: an absent early
-- action leaves a hole instead of shifting later actions forward. With only
-- the unconditionally present actions unlocked, the trainer card stays in
-- its right-column slot rather than compacting into the first position.
function T.tests.normal_actions_keep_stable_visual_slots_when_early_actions_are_absent()
  local actions = StartMenuPolicy.actions(facts({
    hasPokedex = false,
    hasStarter = false,
    bagUnlocked = false,
    hasPokegear = false,
  }))
  Assert.equal(assert(actionById(actions, "vanilla.trainer_card")).displayPosition, 4)
  Assert.equal(assert(actionById(actions, "vanilla.save")).displayPosition, 5)
  Assert.equal(assert(actionById(actions, "vanilla.options")).displayPosition, 6)
end

-- The full normal set pins every retail slot in one assertion, so a future
-- reorder of the canonical definitions cannot silently renumber the screen.
function T.tests.full_normal_set_pins_every_retail_visual_slot()
  local actions = StartMenuPolicy.actions(facts())
  local expected = {
    ["vanilla.pokedex"] = 0,
    ["vanilla.pokemon"] = 1,
    ["vanilla.bag"] = 2,
    ["vanilla.pokegear"] = 3,
    ["vanilla.trainer_card"] = 4,
    ["vanilla.save"] = 5,
    ["vanilla.options"] = 6,
  }
  for id, position in pairs(expected) do
    local action = assert(actionById(actions, id), id .. " must be present")
    Assert.equal(action.displayPosition, position, id .. " keeps its retail visual slot")
  end
end

-- The facts are ordinary internal data: the seven required booleans are
-- asserted (a missing or malformed fact is a programming fault), but
-- additional keys are tolerated and never read.
function T.tests.facts_are_internal_data_with_asserted_booleans()
  Assert.throws(function()
    local value = facts()
    value.hasPokedex = nil
    StartMenuPolicy.actions(value)
  end)
  Assert.throws(function()
    local value = facts()
    value.bagUnlocked = "yes"
    StartMenuPolicy.actions(value)
  end)
  Assert.throws(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- exercising the runtime guard against a missing facts table
    StartMenuPolicy.actions(nil)
  end)
  local withExtras = facts()
  withExtras.context = "normal_field"
  withExtras.capabilities = { "trainer_card" }
  Assert.equal(#StartMenuPolicy.actions(withExtras), 10, "unknown fact keys are ordinary data, not errors")
end

-- actions() is a pure projection: it never mutates the facts and returns
-- fresh records per call, so mutating one call's result cannot leak into the
-- next.
function T.tests.actions_returns_fresh_records_and_does_not_mutate_facts()
  local value = facts()
  local before = facts()
  local first = StartMenuPolicy.actions(value)
  first[1].displayPosition = 999
  local second = StartMenuPolicy.actions(value)
  Assert.deepEqual(value, before, "the facts are untouched")
  Assert.equal(second[1].displayPosition, 0, "the mutation of the first result did not leak into the second")
end

return T
