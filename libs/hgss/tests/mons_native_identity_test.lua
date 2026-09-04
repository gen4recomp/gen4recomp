-- Native identity authority for mon creation and encoding: starter and
-- script-gift met metadata resolve the native map-section identity the
-- service is constructed with, creation draws stay fixed, the first-starter
-- boxed bytes freeze at the corrected section, native projection follows
-- the generated catalog even when independently maintained runtime maps
-- disagree, and save capture preserves the corrected bytes exactly.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local BoxCodec = require("libs.mons.src.gen4.BoxCodec")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local NativeLegality = require("libs.mons.src.gen4.NativeLegality")
local Party = require("libs.mons.src.Party")

local T = {}

-- Fixed starter inputs shared with the integrated starter journey: bucket
-- seed 7, GOLD with trainer id 1, host date 2000-01-01, starter policy.
local SEED = 7
local PROFILE = { name = "GOLD", gender = 0, trainerId = 1 }
local MET_DATE = { year = 2000, month = 1, day = 1 }
local NATIVE_SECTION = 126
-- The first-candidate personality produced by four creation draws from seed
-- 7; the location-61 journey vector decodes to this same personality, which
-- pins the draw order while the section correction lands.
local FIRST_PERSONALITY = 1005636716
-- Independent 0x88 boxed bytes for the first candidate at the corrected
-- section: the creation pipeline reproduces the frozen location-61 journey
-- vector byte-for-byte when run with the old substitute, so rerunning it
-- with only the location corrected refreshes the vector without touching
-- draws, personality, IVs, or identity. Never computed by the codec under
-- test at assertion time.
local CORRECTED_HEX =
  "6cccf03b0000d10401cc855a0b30fa9e2c5a104b9a3b7b9374ba3f8fae86510962d9c6692508ce8be4ec2691a6e1bd9ac6d28e5b6ba193986b3e5766c780e5938acb2dec997d1a76b138d069162654d0cef342a7e30cda3a47fa657861403dd1a9aded22409e28a3efeb1e05661054a75c5f025a2467ae0019c984791e858d713049c20a905c7a12"

local function openService(catalog, seed, mapSection)
  return HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(seed):capture(), catalog:fingerprint()),
    profile = PROFILE,
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    mapSection = mapSection,
    date = function()
      return { year = MET_DATE.year, month = MET_DATE.month, day = MET_DATE.day }
    end,
  })
end

local function toHex(bytes)
  local parts = {}
  for index = 1, #bytes do
    parts[#parts + 1] = string.format("%02x", string.byte(bytes, index))
  end
  return table.concat(parts)
end

local function contextFor(catalog)
  return {
    catalog = catalog,
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  }
end

function T.starter_met_uses_the_native_section_identity()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED, function()
    return NATIVE_SECTION
  end)
  local candidate = service:buildStarter("CHIKORITA", {
    date = { year = MET_DATE.year, month = MET_DATE.month, day = MET_DATE.day },
  })
  Assert.equal(candidate.met.location, NATIVE_SECTION, "the starter records the native section, not the map id")
  Assert.equal(candidate.met.date.year, 2000, "the met date still flows from the supplied context")
  Assert.equal(candidate.met.level, 5, "starter policy still opens at level five")
  Assert.equal(service:partyCount(), 0, "generation never publishes into the party")
end

function T.corrected_section_keeps_draws_identity_and_bytes()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED, NATIVE_SECTION)
  local candidate = service:buildStarter("CHIKORITA", {
    date = { year = MET_DATE.year, month = MET_DATE.month, day = MET_DATE.day },
  })
  Assert.equal(service:capture().rng.calls, 4, "one candidate still consumes exactly four generator draws")
  Assert.equal(candidate.personality, FIRST_PERSONALITY, "the draw order and personality never move")
  local context = contextFor(catalog)
  Assert.equal(toHex(BoxCodec.encode(candidate, context)), CORRECTED_HEX, "the corrected bytes freeze literally")
  local projection = BoxCodec.decode(CatalogFixture.fromHex(CORRECTED_HEX), context)
  Assert.equal(projection.personality, FIRST_PERSONALITY, "the frozen bytes carry the same candidate")
  Assert.equal(projection.met.location, NATIVE_SECTION, "the frozen bytes carry the corrected section")
  Assert.equal(projection.met.level, 5, "the frozen bytes carry the starter level")
  local ok = pcall(function()
    NativeLegality.project(candidate, context)
  end)
  Assert.isTrue(ok, "the corrected candidate passes native legality")
end

function T.native_projection_follows_the_generated_catalog()
  local catalog = CatalogFixture.makeCatalog()
  local authoritative = contextFor(catalog)
  local factory = CatalogFixture.makeFactory(0x10000021, catalog)
  local record = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE", level = 5 }))
  record.heldItem = "SITRUS_BERRY"
  local expectedId = catalog:item("SITRUS_BERRY").nativeId
  Assert.equal(expectedId, 158, "the fixture pins the representative native item identity")
  local expectedBytes = BoxCodec.encode(record, authoritative)
  -- Independently maintained runtime maps disagree with the catalog about
  -- the same semantic item; every native consumer must still resolve the
  -- generated identity.
  local divergent = {
    catalog = catalog,
    charmap = authoritative.charmap,
    games = authoritative.games,
    languages = authoritative.languages,
    items = { NONE = 0, POKE_BALL = 4, GREAT_BALL = 3, SITRUS_BERRY = 999 },
    balls = { POKE_BALL = 999, GREAT_BALL = 3 },
  }
  Assert.equal(
    NativeLegality.project(record, divergent).heldItemId,
    expectedId,
    "legality resolves the catalog identity under divergent runtime maps"
  )
  Assert.equal(
    toHex(BoxCodec.encode(record, divergent)),
    toHex(expectedBytes),
    "encoding resolves the catalog identity under divergent runtime maps"
  )
  local decodeOk, decoded = pcall(function()
    return BoxCodec.decode(expectedBytes, divergent)
  end)
  Assert.isTrue(decodeOk, "decoding with divergent runtime maps must still resolve the catalog")
  Assert.equal(
    assert(decodeOk and decoded).heldItem,
    "SITRUS_BERRY",
    "decoding resolves the catalog identity under divergent maps"
  )
  Assert.equal(
    assert(decodeOk and decoded).origin.ball,
    "POKE_BALL",
    "decoding resolves the catalog ball under divergent maps"
  )
end

function T.save_capture_preserves_the_corrected_bytes()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED, NATIVE_SECTION)
  service:createStarter("CHIKORITA", {
    date = { year = MET_DATE.year, month = MET_DATE.month, day = MET_DATE.day },
  })
  local context = contextFor(catalog)
  local before = toHex(BoxCodec.encode(service:partyMon(0), context))
  Assert.equal(before, CORRECTED_HEX, "the published starter matches the frozen vector")
  local restored = HgssMonService.new({
    catalog = catalog,
    bucket = service:capture(),
    profile = PROFILE,
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    mapSection = NATIVE_SECTION,
    date = function()
      return { year = MET_DATE.year, month = MET_DATE.month, day = MET_DATE.day }
    end,
  })
  Assert.equal(restored:partyCount(), 1, "capture restores exactly the chosen mon")
  Assert.equal(
    toHex(BoxCodec.encode(restored:partyMon(0), context)),
    CORRECTED_HEX,
    "capture changes no corrected byte"
  )
end

return { tests = T }
