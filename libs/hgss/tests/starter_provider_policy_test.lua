-- Vanilla starter provider policy: the default ordered candidate roster and
-- the hand-editable substitution seam. The provider owns species selection
-- only; creation level, generator draws, met context, presentation, and
-- party publication live in the starter task and the mon service.

local Assert = require("tests.support.Assert")

local T = {}

local PROVIDER_MODULE = "game.hgss.src.starters.VanillaStarterProvider"

local function requireProvider()
  local ok, provider = pcall(require, PROVIDER_MODULE)
  Assert.isTrue(ok, "the vanilla starter provider owns the default candidate roster")
  return assert(provider)
end

function T.default_roster_is_the_source_ordered_trio()
  local provider = requireProvider()
  local roster = provider:resolve()
  Assert.deepEqual(roster, { "CHIKORITA", "CYNDAQUIL", "TOTODILE" }, "default roster")
end

function T.resolve_returns_exactly_three_species_keys()
  local provider = requireProvider()
  local roster = provider:resolve()
  Assert.equal(#roster, 3, "the starter screen supports exactly three candidates")
  for index, key in ipairs(roster) do
    Assert.isTrue(type(key) == "string" and key ~= "", "candidate " .. index .. " is a species key")
  end
end

function T.resolve_returns_a_fresh_table_per_call()
  local provider = requireProvider()
  local first = provider:resolve()
  first[1] = "MUTATED"
  local second = provider:resolve()
  Assert.equal(second[1], "CHIKORITA", "callers must not mutate the provider roster")
end

function T.provider_carries_no_creation_or_presentation_behavior()
  local provider = requireProvider()
  Assert.isNil(provider.create, "creation stays in the factory/service")
  Assert.isNil(provider.level, "creation level stays in the starter policy")
  Assert.isNil(provider.open, "presentation stays in the application")
  Assert.isNil(provider.add, "party publication stays in the task")
end

return { tests = T }
