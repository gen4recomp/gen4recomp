-- Starter candidate construction without publication: the starter task
-- pre-creates all three candidates through this operation while the party
-- stays empty, then publishes the confirmed instance with addMon. Building
-- never observes party fullness and confirmation never rerolls.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

local T = {}

local SERVICE_MODULE = "libs.hgss.src.mons.HgssMonService"

local function requireService()
  local ok, service = pcall(require, SERVICE_MODULE)
  Assert.isTrue(ok, "the HGSS mon service owns starter candidate construction")
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
    mapSection = 7,
    date = CatalogFixture.metDate(),
  })
end

function T.building_a_starter_leaves_the_party_empty()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x12345678)
  local mon = service:buildStarter("CHIKORITA")
  Assert.equal(mon.species, "CHIKORITA", "the built candidate carries the requested species")
  Assert.equal(mon.form, 0, "starter candidates are native form zero")
  Assert.equal(service:partyCount(), 0, "building never publishes into the party")
  Assert.equal(service:capture().rng.calls, 4, "building consumes the exact source draws")
end

function T.built_candidates_carry_the_source_starter_policy()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x12345678)
  local mon = service:buildStarter("TOTODILE", { location = 9, date = CatalogFixture.metDate() })
  local Experience = require("libs.mons.src.gen4.Experience")
  Assert.equal(
    Experience.level(catalog:growthCurve(catalog:species("TOTODILE").growthCurve), mon.experience),
    5,
    "starter candidates enter at level five"
  )
  Assert.equal(mon.origin.ball, "POKE_BALL", "starter candidates arrive in a normal ball")
  Assert.equal(mon.heldItem, "NONE", "starter candidates hold nothing")
  Assert.equal(mon.met.location, 9, "an explicit met context wins over the service default")
  Assert.equal(mon.met.terrain, 12, "starter candidates carry the source encounter terrain")
end

function T.unknown_species_fail_before_any_generator_draw()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x12345678)
  local Errors = require("libs.errors.src.Errors")
  local err = Assert.throws(function()
    service:buildStarter("MISSINGNO")
  end)
  Assert.isTrue(Errors.is(err), "unknown species fail with a structured error")
  Assert.equal(service:capture().rng.calls, 0, "failed validation draws nothing")
  Assert.equal(service:partyCount(), 0, "failed validation publishes nothing")
end

function T.building_ignores_a_full_party()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x12345678)
  for _ = 1, 6 do
    Assert.isTrue(
      service:giveMon({
        species = "EEVEE",
        level = 5,
        heldItem = "NONE",
        form = 0,
        location = 7,
        date = CatalogFixture.metDate(),
      }),
      "setup gifts must fill the party"
    )
  end
  local mon = service:buildStarter("CHIKORITA")
  Assert.equal(mon.species, "CHIKORITA", "generation succeeds while the party is full")
  Assert.equal(service:partyCount(), 6, "generation never evicts or appends")
end

return { tests = T }
