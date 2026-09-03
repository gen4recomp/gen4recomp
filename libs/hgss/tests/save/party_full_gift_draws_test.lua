-- Full-party gift ordering: creation consumes its generator draws even
-- when the party has no room, the result is false, and nothing is
-- published anywhere.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

local T = {}

local SERVICE_MODULE = "libs.hgss.src.mons.HgssMonService"

local function requireService()
  local ok, service = pcall(require, SERVICE_MODULE)
  Assert.isTrue(ok, "the HGSS mon service owns script-gift creation and party insertion")
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
  return service:giveMon({
    species = species,
    level = 5,
    heldItem = "NONE",
    form = 0,
    location = 7,
    date = CatalogFixture.metDate(),
  })
end

function T.full_party_reports_false_without_changing_state_or_branching()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x44444444)
  for _ = 1, Party.MAX do
    Assert.isTrue(gift(service, "CHIKORITA"), "setup gifts fill the party")
  end
  Assert.equal(service:partyCount(), 6, "the party holds six mons")
  local revisionBefore = service:partyRevision()
  local rngBefore = service:capture().rng
  local partyBefore = {}
  for slot = 0, 5 do
    partyBefore[slot] = service:partyMon(slot)
  end

  Assert.isFalse(gift(service, "TOTODILE"), "the seventh gift reports the source failure result")
  Assert.equal(service:partyCount(), 6, "a full party never overflows into storage")
  Assert.equal(service:partyRevision(), revisionBefore, "the discarded gift bumps no revision")
  for slot = 0, 5 do
    Assert.deepEqual(service:partyMon(slot), partyBefore[slot], "the published party is unchanged")
  end
  Assert.isTrue(service:capture().rng.calls > rngBefore.calls, "creation draws precede the insertion result")
end

return { tests = T }
