-- Live-service query and bounded-mutation coverage: every named script
-- operation reads exact zero-based state through the aggregate, writes
-- source result conventions, mutates through the aggregate exactly once,
-- and fails explicitly on invalid identities or slots.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Errors = require("libs.errors.src.Errors")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

local T = {}

local function openService(catalog, seed, opts)
  opts = opts or {}
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
    mapSection = opts.mapSection,
    date = opts.date,
    dateProvider = opts.dateProvider,
  })
end

local function gift(service, species, overrides)
  local request = {
    species = species,
    level = 5,
    heldItem = "NONE",
    form = 0,
    location = 7,
    date = CatalogFixture.metDate(),
  }
  for key, value in pairs(overrides or {}) do
    request[key] = value
  end
  return service:giveMon(request)
end

local function twoMonService(seed, opts)
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, seed or 0xAAAAAAAA, opts)
  Assert.isTrue(gift(service, "CHIKORITA"), "setup gift must enter the party")
  Assert.isTrue(gift(service, "TOTODILE"), "setup gift must enter the party")
  return catalog, service
end

function T.counts_observe_the_live_party()
  local _, service = twoMonService()
  Assert.equal(service:partyCount(), 2)
  Assert.equal(service:partyCountNotEgg(), 2)
  Assert.equal(service:partyCountEgg(), 0)
  Assert.equal(service:countAliveMons(), 2)
  Assert.equal(service:countAliveMons(6), 2, "the party size excludes nothing")
  Assert.equal(service:countAliveMons(0), 1, "the excluded slot leaves the count")
  Assert.equal(service:partyCountAtOrBelowLevel(5), 2)
  Assert.equal(service:partyCountAtOrBelowLevel(4), 0)
  Assert.equal(service:countSpecies("CHIKORITA"), 1)
  Assert.equal(service:countSpecies("EEVEE"), 0)
end

function T.searches_report_zero_based_slots_or_nothing()
  local _, service = twoMonService()
  Assert.equal(service:partySlotWithSpecies("CHIKORITA"), 0)
  Assert.equal(service:partySlotWithSpecies("TOTODILE"), 1)
  Assert.isNil(service:partySlotWithSpecies("EEVEE"), "absent species report nothing")
  Assert.equal(service:partySlotWithMove("TACKLE"), 0, "both starters open with tackle")
  Assert.isNil(service:partySlotWithMove("CUT"), "absent moves report nothing")
  local nature = service:monNature(1)
  Assert.equal(service:partySlotWithNature(nature), 1, "nature search finds the owning slot")
  Assert.isNil(service:partySlotWithFatefulEncounter(), "no setup mon is fateful")
end

function T.reads_derive_identity_values_without_storing_them()
  local catalog, service = twoMonService()
  Assert.equal(service:partyMonSpecies(0), catalog:species("CHIKORITA").nativeId)
  Assert.equal(service:partyMonSpecies(1), catalog:species("TOTODILE").nativeId)
  Assert.isTrue(service:partyMonIsMine(0), "player-created mons are owned")
  Assert.isFalse(service:partyMonIsMine(9), "out-of-range ownership reads report false")
  local nature = service:monNature(0)
  Assert.isTrue(nature >= 0 and nature <= 24, "nature derives into 0..24")
  Assert.isTrue(service:monGender(0) == 0 or service:monGender(0) == 1, "starter gender is binary")
  Assert.equal(service:monForm(0), 0)
  Assert.equal(service:monFriendship(0), 70, "friendship opens at the species base")
  Assert.equal(service:monRibbonCount(0), 0)
  Assert.equal(service:partyRibbonCount(), 0)
  Assert.isFalse(service:partyHasPokerus(), "fresh mons carry no pokerus")
  Assert.isTrue(service:partyLegal(), "created mons pass native legality")
  Assert.isFalse(service:hasKyogreGroudon(), "the fixture party holds no cover mascot")
  Assert.equal(service:monMove(0, 0), catalog:move("TACKLE").nativeId)
  Assert.equal(service:countMonMoves(0), 2, "the starter opens with two level-up moves")
end

function T.bounded_mutations_clamp_and_bump_revision_once()
  local _, service = twoMonService()
  local revision = service:partyRevision()
  Assert.equal(service:monAddFriendship(0, 200), 255, "friendship clamps at the top")
  Assert.equal(service:partyRevision(), revision + 1, "the mutation bumps the revision once")
  Assert.equal(service:monSubFriendship(0, 255), 0, "friendship clamps at the bottom")
  Assert.equal(service:monAddContestValue(0, 0, 255), 255, "contest values clamp at the top")
  Assert.equal(service:monContestValue(0, 0), 255)
  service:setMove(0, 0, "CUT")
  Assert.equal(service:partyMon(0).moves[1].move, "CUT")
  service:deleteMove(0, 0)
  for _, entry in ipairs(service:partyMon(0).moves) do
    Assert.isTrue(entry.move ~= "CUT", "the deleted move is gone")
  end
end

function T.invalid_operations_fail_without_mutation()
  local _, service = twoMonService()
  local revision = service:partyRevision()
  local ok, err = pcall(function()
    return gift(service, "MISSINGNO")
  end)
  Assert.isFalse(ok, "unknown species fail explicitly")
  Assert.isTrue(Errors.is(err))
  Assert.equal(service:partyCount(), 2, "the failed gift adds nothing")
  Assert.equal(service:partyRevision(), revision, "the failed gift bumps no revision")
  local countErr = Assert.throws(function()
    service:countAliveMons(9)
  end)
  Assert.isTrue(Errors.is(countErr))
  Assert.throws(function()
    service:setMove(9, 0, "CUT")
  end)
  Assert.throws(function()
    service:setMove(0, 9, "CUT")
  end)
  Assert.throws(function()
    service:setMove(0, 0, "MISSINGMOVE")
  end)
  Assert.equal(service:partyRevision(), revision, "failed mutations bump no revision")
end

function T.gifts_accept_native_identities_and_default_ability_sentinels()
  local catalog, service = twoMonService(0xBBBBBBBB)
  Assert.isTrue(
    gift(service, 152, { heldItem = 0, ability = 0 }),
    "native identities resolve and zero keeps the default ability"
  )
  local mon = service:partyMon(2)
  Assert.equal(mon.species, "CHIKORITA")
  Assert.equal(mon.heldItem, "NONE")
  Assert.equal(mon.ability, catalog:form("CHIKORITA", 0).abilities[1])
  Assert.isTrue(gift(service, "EEVEE", { ability = 0xFFFF }), "the all-bits ability sentinel keeps the default ability")
end

function T.native_item_identities_resolve_through_the_catalog_alone()
  local catalog = CatalogFixture.makeCatalog()
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0xEEEEEEEE):capture(), catalog:fingerprint()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    -- Independently maintained runtime maps disagree with the catalog about
    -- the same semantic item; creation still resolves the generated
    -- identity because nothing consults these maps.
    items = { NONE = 0, SITRUS_BERRY = 999 },
    balls = { POKE_BALL = 999 },
    mapSection = 7,
    date = CatalogFixture.metDate(),
  })
  Assert.isTrue(
    service:giveMon({
      species = "CHIKORITA",
      level = 5,
      heldItem = 158,
      form = 0,
      location = 7,
      date = CatalogFixture.metDate(),
    }),
    "a native item identity resolves without runtime tables"
  )
  Assert.equal(service:partyMon(0).heldItem, "SITRUS_BERRY", "the generated catalog names the native identity")
end

function T.gifts_resolve_context_location_and_date_from_the_service()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xCCCCCCCC, {
    mapSection = function()
      return 11
    end,
    dateProvider = function()
      return CatalogFixture.metDate()
    end,
  })
  Assert.isTrue(service:giveMon({ species = "CHIKORITA", level = 5 }), "context supplies section and date")
  local mon = service:partyMon(0)
  Assert.equal(mon.met.location, 11, "creation resolves the current map section first")
  Assert.equal(mon.met.terrain, 24, "script gifts use the source encounter type")
end

function T.return_loan_removes_through_the_aggregate()
  local _, service = twoMonService()
  local revision = service:partyRevision()
  local removed = service:returnLoanMon(0)
  Assert.equal(removed.species, "CHIKORITA")
  Assert.equal(service:partyCount(), 1)
  Assert.equal(service:partyMon(0).species, "TOTODILE")
  Assert.equal(service:partyRevision(), revision + 1)
  Assert.throws(function()
    service:returnLoanMon(5)
  end)
end

function T.add_mon_validates_and_reports_full_parties()
  local _, service = twoMonService()
  local extra = service:partyMon(0)
  Assert.isTrue(service:addMon(extra), "a legal mon enters with room")
  Assert.isTrue(service:addMon(extra))
  Assert.isTrue(service:addMon(extra))
  Assert.isTrue(service:addMon(extra))
  Assert.equal(service:partyCount(), 6)
  Assert.isFalse(service:addMon(extra), "the seventh mon reports false without storage")
  local broken = service:partyMon(0)
  broken.species = "MISSINGNO"
  Assert.throws(function()
    service:addMon(broken)
  end)
end

function T.heal_party_restores_full_health()
  local _, service = twoMonService()
  local revision = service:partyRevision()
  service:healParty()
  for slot = 0, 1 do
    local mon = service:partyMon(slot)
    Assert.equal(mon.condition.status, 0, "status clears")
    Assert.isTrue(mon.condition.currentHp > 0, "health is full")
  end
  Assert.equal(service:partyRevision(), revision + 2, "each restored mon is one owned mutation")
end

function T.derived_display_values_come_from_the_service_owners()
  local _, service = twoMonService()
  local derived = service:partyMonDerived(0)
  Assert.equal(derived.level, 5, "gifted starters open at level five")
  Assert.isTrue(derived.maxHp > 0, "max HP derives positive at level five")
  local mon = service:partyMon(0)
  Assert.equal(mon.condition.currentHp, derived.maxHp, "fresh mons open at full health")
  Assert.throws(function()
    service:partyMonDerived(9)
  end, "derived reads outside the party fail")
end

return { tests = T }
