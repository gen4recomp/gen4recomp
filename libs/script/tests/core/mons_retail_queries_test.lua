-- Retail query semantics through the script runtime: egg masking, exact
-- search sentinels, inverted ownership polarity, and source out-of-range
-- conventions. Every case drives a semantic node through Runtime.executeNode
-- against the live HGSS service and reads the value the script variable
-- would carry. Source commands covered: ScrCmd_MonHasMove (140),
-- ScrCmd_GetPartySlotWithMove (141), ScrCmd_GetPartyMonSpecies (354),
-- ScrCmd_PartyMonIsMine (355), ScrCmd_PartyCountMonsAtOrBelowLevel (434),
-- ScrCmd_MonGetNature (457), ScrCmd_GetPartySlotWithNature (458), and
-- ScrCmd_GetPartySlotWithSpecies (647).

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local Personality = require("libs.mons.src.gen4.Personality")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")

local T = {}

local SEED = 0xAAAAAAAA

local function openService()
  local catalog = CatalogFixture.makeCatalog()
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(SEED):capture(), catalog:fingerprint()),
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
  local function gift(species, level)
    Assert.isTrue(
      service:giveMon({
        species = species,
        level = level or 5,
        heldItem = "NONE",
        form = 0,
        location = 7,
        date = CatalogFixture.metDate(),
      }),
      "setup gift must enter the party"
    )
  end
  gift("CHIKORITA")
  gift("TOTODILE")
  -- An egg that still carries ordinary internal data: its move list holds
  -- TAIL_WHIP, a move no non-egg party member knows, so searches prove
  -- whether the egg is masked rather than merely absent.
  local factory = CatalogFixture.makeFactory(0x12345678, catalog)
  local egg = factory:createNormal({
    species = "EEVEE",
    level = 5,
    form = 0,
    profile = CatalogFixture.profile(),
    ball = "POKE_BALL",
    location = 7,
    terrain = 4,
    date = CatalogFixture.metDate(),
  })
  egg.isEgg = true
  Assert.isTrue(service:addMon(egg), "setup egg must enter the party")
  -- A mon with the same trainer name but a different trainer id isolates the
  -- ownership rule to the numeric id alone.
  local stranger = factory:createNormal({
    species = "CHIKORITA",
    level = 5,
    form = 0,
    profile = { name = "RED", gender = 0, trainerId = 999 },
    ball = "POKE_BALL",
    location = 7,
    terrain = 4,
    date = CatalogFixture.metDate(),
  })
  Assert.isTrue(service:addMon(stranger), "setup stranger must enter the party")
  -- A mon with the same trainer id but a different name: retail ownership
  -- compares the id only, so this mon still counts as mine.
  local renamed = factory:createNormal({
    species = "TOTODILE",
    level = 5,
    form = 0,
    profile = { name = "BLUE", gender = 0, trainerId = CatalogFixture.profile().trainerId },
    ball = "POKE_BALL",
    location = 7,
    terrain = 4,
    date = CatalogFixture.metDate(),
  })
  Assert.isTrue(service:addMon(renamed), "setup renamed mon must enter the party")
  return catalog, service
end

local function runWith(service, vars)
  local world = {
    vars = vars or {},
    getVar = function(self, id)
      return self.vars[id]
    end,
    setVar = function(self, id, value)
      self.vars[id] = value
    end,
  }
  return {
    instance = { scriptId = "test.retail.queries", locals = {}, textArgs = {} },
    services = { mons = service, world = world },
    semantics = RuntimeValues,
  }
end

local function var(id)
  return { value = "var", id = id }
end

local function execute(service, node)
  local run = runWith(service)
  Assert.equal(Runtime.executeNode(node, run), Runtime.OUTCOME_CONTINUE)
  return run.services.world.vars
end

function T.move_queries_mask_eggs()
  local catalog, service = openService()
  local tackle = catalog:move("TACKLE").nativeId
  -- ScrCmd_MonHasMove (140) initializes false and never inspects an egg.
  local eggMiss = execute(service, { op = "mon_has_move", slot = 2, move = "TAIL_WHIP", result = var("R1") })
  Assert.equal(eggMiss.R1, 0, "an egg never reports its move list")
  local hit = execute(service, { op = "mon_has_move", slot = 0, move = tackle, result = var("R2") })
  Assert.equal(hit.R2, 1, "a matching non-egg reports its move by native id")
  -- ScrCmd_GetPartySlotWithMove (141) scans upward from zero, skips eggs,
  -- and leaves PARTY_SIZE when nothing non-egg matches.
  local eggOnly = execute(service, { op = "party_slot_with_move", move = "TAIL_WHIP", result = var("R3") })
  Assert.equal(eggOnly.R3, 6, "a move known only to an egg leaves the party-size sentinel")
  local shared = execute(service, { op = "party_slot_with_move", move = "SCRATCH", result = var("R4") })
  Assert.equal(shared.R4, 1, "a shared move resolves to the first non-egg holder")
  local absent = execute(service, { op = "party_slot_with_move", move = "CUT", result = var("R5") })
  Assert.equal(absent.R5, 6, "an unknown move leaves the party-size sentinel")
end

function T.species_queries_mask_eggs_and_use_exact_sentinels()
  local catalog, service = openService()
  -- ScrCmd_GetPartyMonSpecies (354) writes SPECIES_NONE for eggs.
  local eggSpecies = execute(service, { op = "party_mon_species", slot = 2, result = var("R1") })
  Assert.equal(eggSpecies.R1, 0, "an egg reads as species zero")
  local plain = execute(service, { op = "party_mon_species", slot = 0, result = var("R2") })
  Assert.equal(plain.R2, catalog:species("CHIKORITA").nativeId, "a non-egg reads its native species")
  -- ScrCmd_GetPartySlotWithSpecies (647) scans non-eggs upward and leaves
  -- 255 on no match.
  local hit = execute(service, { op = "party_slot_with_species", species = "TOTODILE", result = var("R3") })
  Assert.equal(hit.R3, 1, "an exact species match reports its zero-based slot")
  local eggOnly = execute(service, { op = "party_slot_with_species", species = "EEVEE", result = var("R4") })
  Assert.equal(eggOnly.R4, 255, "a species held only by an egg leaves the 255 sentinel")
  local absent = execute(service, {
    op = "party_slot_with_species",
    species = catalog:species("SHEDINJA").nativeId,
    result = var("R5"),
  })
  Assert.equal(absent.R5, 255, "an absent species leaves the 255 sentinel")
end

function T.ownership_compares_trainer_identity_with_inverted_polarity()
  local _, service = openService()
  -- ScrCmd_PartyMonIsMine (355) compares only the numeric trainer id and
  -- writes FALSE when the ids are equal, TRUE when they differ.
  local mine = execute(service, { op = "party_mon_is_mine", slot = 0, result = var("R1") })
  Assert.equal(mine.R1, 0, "the player's own mon reports not-mine")
  local renamed = execute(service, { op = "party_mon_is_mine", slot = 4, result = var("R2") })
  Assert.equal(renamed.R2, 0, "a matching id with a different name still reports not-mine")
  local stranger = execute(service, { op = "party_mon_is_mine", slot = 3, result = var("R3") })
  Assert.equal(stranger.R3, 1, "a different id with the same name reports mine")
end

function T.level_census_skips_eggs()
  local _, service = openService()
  -- ScrCmd_PartyCountMonsAtOrBelowLevel (434) counts non-eggs at or below
  -- the requested level.
  local atFive = execute(service, { op = "party_count_at_or_below_level", level = 5, result = var("R1") })
  Assert.equal(atFive.R1, 4, "four non-eggs sit at level five while the egg is skipped")
  local atFour = execute(service, { op = "party_count_at_or_below_level", level = 4, result = var("R2") })
  Assert.equal(atFour.R2, 0, "no non-egg sits at or below level four")
end

function T.nature_lookup_and_search_use_retail_conventions()
  local _, service = openService()
  -- ScrCmd_MonGetNature (457) writes 0 for out-of-range slots and eggs
  -- instead of faulting.
  local farRun = runWith(service)
  local farOk, farOutcome = pcall(function()
    return Runtime.executeNode({ op = "party_mon_nature", slot = 5, result = var("R1") }, farRun)
  end)
  Assert.isTrue(farOk, "an out-of-range nature read must not fault")
  Assert.equal(farOutcome, Runtime.OUTCOME_CONTINUE, "an out-of-range nature read continues")
  Assert.equal(farRun.services.world.vars.R1, 0, "an out-of-range slot reads nature zero")
  local eggNature = execute(service, { op = "party_mon_nature", slot = 2, result = var("R2") })
  Assert.equal(eggNature.R2, 0, "an egg reads nature zero")
  local expected = Personality.nature(service:partyMon(0).personality)
  local plain = execute(service, { op = "party_mon_nature", slot = 0, result = var("R3") })
  Assert.equal(plain.R3, expected, "a non-egg reads its personality-derived nature")
  -- ScrCmd_GetPartySlotWithNature (458) scans non-eggs upward and leaves
  -- 255 on no match.
  local ownerNature = service:monNature(1)
  local hit = execute(service, { op = "party_slot_with_nature", nature = ownerNature, result = var("R4") })
  Assert.equal(hit.R4, 1, "a nature search reports the first non-egg owner")
  local seen = {}
  for slot = 0, service:partyCount() - 1 do
    if slot ~= 2 then
      seen[service:monNature(slot)] = true
    end
  end
  local missing = nil
  for nature = 0, 24 do
    if not seen[nature] then
      missing = nature
      break
    end
  end
  Assert.notNil(missing, "five mons cannot cover all twenty-five natures")
  local noHit = execute(service, { op = "party_slot_with_nature", nature = assert(missing), result = var("R5") })
  Assert.equal(noHit.R5, 255, "an unmatched nature leaves the 255 sentinel")
end

return { tests = T }
