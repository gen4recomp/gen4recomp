-- Live party persistence: capturing the service, encoding the global
-- record through storage, and restoring into a fresh service preserves the
-- exact semantic mon and its native boxed bytes with the generator
-- continuing where it stopped.

local Assert = require("tests.support.Assert")
local BoxCodec = require("libs.mons.src.gen4.BoxCodec")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

local T = {}

local SERVICE_MODULE = "libs.hgss.src.mons.HgssMonService"

local function requireService()
  local ok, service = pcall(require, SERVICE_MODULE)
  Assert.isTrue(ok, "the HGSS mon service owns the live party, creation RNG, factory, and capture/restore")
  return assert(service)
end

local function serviceContext(catalog)
  return CatalogFixture.domainContext(catalog)
end

local function openService(HgssMonService, catalog, bucket)
  return HgssMonService.new({
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
end

local function emptyBucket(catalog, seed)
  return MonsSave.capture(Party.new():capture(), Lcrng.new(seed):capture(), catalog:fingerprint())
end

function T.capture_store_restore_preserves_semantics_and_native_bytes()
  local HgssMonService = requireService()
  local catalog = CatalogFixture.makeCatalog()
  local context = serviceContext(catalog)
  local live = openService(HgssMonService, catalog, emptyBucket(catalog, 0x11111111))
  live:createStarter("CHIKORITA", { location = 7, date = CatalogFixture.metDate() })
  Assert.equal(live:partyCount(), 1, "the created starter enters the live party")

  local before = live:partyMon(0)
  local bytesBefore = CatalogFixture.toHex(BoxCodec.encode(before, context))

  local stored = live:capture()
  Assert.isTrue(MonsSave.validate(stored, context), "the captured bucket validates before storage")
  local restoredBucket = MonsSave.capture(stored.party, stored.rng, stored.catalogFingerprint)
  local resumed = openService(HgssMonService, catalog, restoredBucket)

  Assert.equal(resumed:partyCount(), 1, "restore republishes the party without loss")
  Assert.deepEqual(resumed:partyMon(0), before, "the semantic record survives storage exactly")
  Assert.equal(
    CatalogFixture.toHex(BoxCodec.encode(resumed:partyMon(0), context)),
    bytesBefore,
    "the native boxed bytes are identical after the round trip"
  )
  Assert.deepEqual(resumed:capture().rng, stored.rng, "the generator continues instead of restarting")
end

return { tests = T }
