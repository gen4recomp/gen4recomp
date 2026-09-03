-- Party query and bounded-mutation operations: reads observe exact
-- zero-based slots and source result conventions through the live party,
-- mutations go through the aggregate once, and snapshots never alias
-- service-owned state.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Experience = require("libs.mons.src.gen4.Experience")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local Personality = require("libs.mons.src.gen4.Personality")

local T = {}

local SERVICE_MODULE = "libs.hgss.src.mons.HgssMonService"

local function requireService()
  local ok, service = pcall(require, SERVICE_MODULE)
  Assert.isTrue(ok, "the HGSS mon service owns the live party operations used by scripts")
  return assert(service)
end

local function openService(catalog, seed)
  local HgssMonService = requireService()
  return HgssMonService.new({
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
  })
end

local function gift(service, species)
  local added = service:giveMon({
    species = species,
    level = 5,
    heldItem = "NONE",
    form = 0,
    location = 7,
    date = CatalogFixture.metDate(),
  })
  Assert.isTrue(added, "setup gift must enter the party")
end

function T.slots_reads_and_lead_observe_zero_based_party_state()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x55555555)
  gift(service, "CHIKORITA")
  gift(service, "TOTODILE")
  Assert.equal(service:partyCount(), 2, "the count observes both gifts")
  Assert.equal(service:leadSlot(), 0, "the lead is the first occupied slot")
  Assert.equal(service:leadAliveSlot(), 0, "the alive lead is the first conscious mon")
  local first = service:partyMon(0)
  local second = service:partyMon(1)
  Assert.equal(first.species, "CHIKORITA", "slot zero reads the first gift")
  Assert.equal(second.species, "TOTODILE", "slot one reads the second gift")
  Assert.equal(
    Experience.level(catalog:growthCurve("medium_slow"), first.experience),
    5,
    "the level derives from experience"
  )
  Assert.equal(
    Personality.nature(first.personality),
    Personality.nature(service:partyMon(0).personality),
    "nature reads are stable across snapshots"
  )
end

function T.snapshots_are_copies_and_swaps_reorder_through_the_aggregate()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x66666666)
  gift(service, "CHIKORITA")
  gift(service, "TOTODILE")
  local snapshot = service:partyMon(0)
  snapshot.species = "TOTODILE"
  Assert.equal(service:partyMon(0).species, "CHIKORITA", "callers cannot mutate the live party directly")
  local revisionBefore = service:partyRevision()
  service:swapPartyMons(0, 1)
  Assert.equal(service:partyMon(0).species, "TOTODILE", "the swap reorders the live party")
  Assert.equal(service:partyMon(1).species, "CHIKORITA", "both swapped slots observe the reorder")
  Assert.equal(service:partyRevision(), revisionBefore + 1, "a successful mutation bumps the revision once")
  Assert.equal(service:leadSlot(), 0, "the lead follows slot zero after the reorder")
end

function T.move_slots_support_set_delete_and_presence_reads()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x77777777)
  gift(service, "CHIKORITA")
  service:setMove(0, 0, "CUT")
  Assert.equal(service:partyMon(0).moves[1].move, "CUT", "the move slot carries the assigned move")
  local countBefore = #service:partyMon(0).moves
  service:deleteMove(0, 0)
  local remaining = service:partyMon(0).moves
  Assert.equal(#remaining, countBefore - 1, "deleting shrinks the move list by one")
  for _, slot in ipairs(remaining) do
    Assert.isTrue(slot.move ~= "CUT", "the deleted move no longer occupies any slot")
  end
end

function T.removal_keeps_dense_slots_without_fallback()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x88888888)
  gift(service, "CHIKORITA")
  gift(service, "TOTODILE")
  service:removeMon(0)
  Assert.equal(service:partyCount(), 1, "removal shrinks the party")
  Assert.equal(service:partyMon(0).species, "TOTODILE", "later mons shift down into dense slots")
end

return { tests = T }
