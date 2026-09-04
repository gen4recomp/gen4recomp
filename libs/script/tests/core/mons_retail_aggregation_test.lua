-- Retail aggregation and no-op quirks through the script runtime: ribbon
-- kinds count once across non-eggs, species zero enters duplicate
-- detection, representable parties report no checksum failure, and contest
-- updates honor the selector and sheen no-ops with saturation. Source
-- commands covered: ScrCmd_GetPartyRibbonCount (479),
-- ScrCmd_PartyLegalCheck (584), ScrCmd_CountPartyMonsOfSpecies (632), and
-- ScrCmd_MonAddContestValue (828), whose contest selector rides as a raw
-- immediate byte while slot and modifier stay variable values.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")

local T = {}

local function openService(seed)
  local catalog = CatalogFixture.makeCatalog()
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(seed):capture(), catalog:fingerprint()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    mapSection = 7,
    date = CatalogFixture.metDate(),
  })
  return catalog, service
end

local function factoryFor(catalog, seed)
  return CatalogFixture.makeFactory(seed, catalog)
end

local function gift(service, factory, species, overrides)
  local record = factory:createNormal({
    species = species,
    level = 5,
    form = 0,
    profile = CatalogFixture.profile(),
    ball = "POKE_BALL",
    location = 7,
    terrain = 4,
    date = CatalogFixture.metDate(),
  })
  for key, value in pairs(overrides or {}) do
    if key == "ribbons" or key == "contest" or key == "isEgg" then
      record[key] = value
    end
  end
  if overrides ~= nil and overrides.friendship ~= nil then
    record.friendship = overrides.friendship
  end
  Assert.isTrue(service:addMon(record), "setup mon must enter the party: " .. species)
end

local function runWith(service)
  local world = {
    vars = {},
    getVar = function(self, id)
      return self.vars[id]
    end,
    setVar = function(self, id, value)
      self.vars[id] = value
    end,
  }
  return {
    instance = { scriptId = "test.retail.aggregation", locals = {}, textArgs = {} },
    services = { mons = service, world = world },
    semantics = RuntimeValues,
  }
end

local function execute(service, node)
  local run = runWith(service)
  local ok, outcome = pcall(function()
    return Runtime.executeNode(node, run)
  end)
  Assert.isTrue(ok, "a source-defined case must never fault")
  Assert.equal(outcome, Runtime.OUTCOME_CONTINUE)
  return run.services.world.vars
end

local function var(id)
  return { value = "var", id = id }
end

function T.ribbon_census_counts_distinct_kinds_once_ignoring_eggs()
  local catalog, service = openService(0xD0D0D0D0)
  local factory = factoryFor(catalog, 0xE0E0E0E0)
  -- Two non-eggs share ribbon bit zero; the second adds bit one. The egg
  -- carries bit two plus the shared bit zero; neither egg bit may count.
  gift(service, factory, "CHIKORITA", { ribbons = { ds1 = 1, gba = 0, ds2 = 0 } })
  gift(service, factory, "TOTODILE", { ribbons = { ds1 = 3, gba = 0, ds2 = 0 } })
  gift(service, factory, "EEVEE", { isEgg = true, ribbons = { ds1 = 5, gba = 0, ds2 = 0 } })
  -- ScrCmd_GetPartyRibbonCount (479): two kinds represented, counted once each.
  local vars = execute(service, { op = "party_ribbon_count", result = var("R1") })
  Assert.equal(vars.R1, 2, "shared and distinct kinds count once each while egg ribbons never count")
end

function T.species_zero_enters_duplicate_detection_among_non_eggs()
  local catalog, service = openService(0xD1D1D1D1)
  local factory = factoryFor(catalog, 0xE1E1E1E1)
  local chikorita = catalog:species("CHIKORITA").nativeId
  gift(service, factory, "CHIKORITA")
  gift(service, factory, "TOTODILE")
  -- ScrCmd_CountPartyMonsOfSpecies (632) with a nonzero species counts
  -- exact non-egg matches.
  local single = execute(service, { op = "count_species", species = chikorita, result = var("R1") })
  Assert.equal(single.R1, 1, "one non-egg matches the requested species")
  -- Species zero is duplicate detection, not a lookup: distinct non-eggs
  -- report zero.
  local distinct = execute(service, { op = "count_species", species = 0, result = var("R2") })
  Assert.equal(distinct.R2, 0, "distinct non-egg species report no duplicate")

  local catalog2, doubled = openService(0xD2D2D2D2)
  local factory2 = factoryFor(catalog2, 0xE2E2E2E2)
  gift(doubled, factory2, "CHIKORITA")
  gift(doubled, factory2, "CHIKORITA")
  local duplicate = execute(doubled, { op = "count_species", species = 0, result = var("R3") })
  Assert.equal(duplicate.R3, 1, "two non-eggs sharing a species report a duplicate")

  local catalog3, withEgg = openService(0xD3D3D3D3)
  local factory3 = factoryFor(catalog3, 0xE3E3E3E3)
  gift(withEgg, factory3, "CHIKORITA")
  gift(withEgg, factory3, "CHIKORITA", { isEgg = true })
  local eggOnly = execute(withEgg, { op = "count_species", species = 0, result = var("R4") })
  Assert.equal(eggOnly.R4, 0, "an egg never completes a duplicate pair")
  local ordinary = execute(withEgg, { op = "count_species", species = chikorita, result = var("R5") })
  Assert.equal(ordinary.R5, 1, "ordinary counts skip eggs as well")
end

function T.representable_parties_report_no_checksum_failure()
  local catalog, service = openService(0xD4D4D4D4)
  local factory = factoryFor(catalog, 0xE4E4E4E4)
  gift(service, factory, "CHIKORITA")
  gift(service, factory, "TOTODILE", { isEgg = true })
  -- ScrCmd_PartyLegalCheck (584) is the narrow checksum-failed-egg query:
  -- semantic records cannot carry checksum failure, so every representable
  -- party yields false.
  local vars = execute(service, { op = "party_legal_check", result = var("R1") })
  Assert.equal(vars.R1, 0, "a representable party holds no checksum-failed egg")
end

function T.contest_updates_saturate_and_honor_source_no_ops()
  local catalog, service = openService(0xD5D5D5D5)
  local factory = factoryFor(catalog, 0xE5E5E5E5)
  gift(service, factory, "CHIKORITA", {
    contest = { cool = 10, beauty = 20, cute = 0, smart = 0, tough = 0, sheen = 0 },
  })
  gift(service, factory, "TOTODILE", {
    contest = { cool = 10, beauty = 0, cute = 0, smart = 0, tough = 0, sheen = 255 },
  })
  -- ScrCmd_MonAddContestValue (828): the fifth selector addresses the sixth
  -- contest byte while sheen stays the separately checked blocker.
  execute(service, { op = "mon_add_contest_value", slot = 0, contestType = 0, amount = 5 })
  Assert.equal(service:monContestValue(0, 0), 15, "a valid selector adds to its contest value")
  execute(service, { op = "mon_add_contest_value", slot = 0, contestType = 5, amount = 7 })
  Assert.equal(service:monContestValue(0, 5), 7, "selector five targets the sixth contest byte")
  Assert.equal(service:monContestValue(0, 1), 20, "untouched contest values never move")
  -- A selector at or above six is a silent no-op.
  execute(service, { op = "mon_add_contest_value", slot = 0, contestType = 6, amount = 5 })
  Assert.equal(service:monContestValue(0, 0), 15, "an out-of-range selector changes nothing")
  -- A maxed sheen blocks the update entirely.
  execute(service, { op = "mon_add_contest_value", slot = 1, contestType = 0, amount = 5 })
  Assert.equal(service:monContestValue(1, 0), 10, "a maxed sheen blocks the contest update")
  -- A large source-valid modifier saturates instead of failing.
  execute(service, { op = "mon_add_contest_value", slot = 0, contestType = 0, amount = 300 })
  Assert.equal(service:monContestValue(0, 0), 255, "an overflowing addition saturates at the top")
end

return { tests = T }
