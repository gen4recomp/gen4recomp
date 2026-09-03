-- Field-script gift semantics: the translated production command creates
-- exactly one legal mon through the live service in source order and
-- reports the source boolean result.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")

local T = {}

local SERVICE_MODULE = "libs.hgss.src.mons.HgssMonService"

local function requireService()
  local ok, service = pcall(require, SERVICE_MODULE)
  Assert.isTrue(ok, "the HGSS mon service owns script-gift creation and party insertion")
  return assert(service)
end

local function lowerGiveMon()
  local script = {
    instructions = {
      {
        opcode = 137,
        operands = { 152, 5, 0, 0, 0xFFFF, 0x800C },
        offset = 0,
      },
    },
  }
  local lowered = SemanticLowering.lowerScript(script, { member = 12, scripts = {}, movements = {} }, {
    stdCatalog = SourceCatalog.catalog(),
  })
  return lowered.items
end

function T.give_mon_lowers_to_a_semantic_service_operation()
  local items = lowerGiveMon()
  Assert.equal(#items, 1, "the gift command lowers to exactly one semantic step")
  Assert.equal(items[1].op, "give_mon", "the gift command lowers to the semantic gift operation")
end

function T.give_mon_creates_adds_and_reports_in_source_order()
  local HgssMonService = requireService()
  local catalog = CatalogFixture.makeCatalog()
  local bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x22222222):capture(), catalog:fingerprint())
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = bucket,
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  })
  local callsBefore = service:capture().rng.calls
  local added = service:giveMon({
    species = "CHIKORITA",
    level = 5,
    heldItem = "NONE",
    form = 0,
    location = 7,
    date = CatalogFixture.metDate(),
  })
  Assert.isTrue(added, "the gift reports the source success result")
  Assert.equal(service:partyCount(), 1, "the created mon enters the party")
  local mon = service:partyMon(0)
  Assert.equal(mon.species, "CHIKORITA", "the created mon carries the requested species")
  Assert.equal(mon.met.location, 7, "creation resolves the current map section first")
  Assert.equal(mon.met.terrain, 24, "script gifts use the source encounter type")
  Assert.equal(mon.heldItem, "NONE", "the held item applies after creation")
  Assert.equal(mon.form, 0, "the form override applies after creation")
  Assert.isTrue(service:capture().rng.calls > callsBefore, "creation consumes generator draws")
  Assert.isTrue(
    require("libs.mons.src.Mon").validate(mon, CatalogFixture.domainContext(catalog)) ~= nil,
    "the gifted mon passes semantic validation"
  )
end

local function openGiftService(catalog)
  local HgssMonService = requireService()
  return HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x33333333):capture(), catalog:fingerprint()),
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

local function giftChikorita(service)
  service:giveMon({
    species = "CHIKORITA",
    level = 5,
    heldItem = "NONE",
    form = 0,
    location = 7,
    date = CatalogFixture.metDate(),
  })
  return service:partyMon(0)
end

function T.give_mon_creation_is_deterministic_for_a_fixed_seed()
  local catalog = CatalogFixture.makeCatalog()
  local first = giftChikorita(openGiftService(catalog))
  local second = giftChikorita(openGiftService(catalog))
  Assert.equal(second.personality, first.personality, "the same seed replays the same creation draws")
  Assert.deepEqual(second.ivs, first.ivs, "the same seed replays the same IV draws")
end

return { tests = T }
