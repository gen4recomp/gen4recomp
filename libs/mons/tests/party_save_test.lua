-- Ordered parties and the persisted bucket: six dense zero-based slots
-- with explicit full handling, revision tracking, alive-lead selection,
-- canonical snapshots, and fingerprint-gated save round trips.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")

local T = {}

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error")
  Assert.equal(err.code, code)
end

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copy(item)
  end
  return out
end

local function makePartyMons(catalog)
  local factory = CatalogFixture.makeFactory(0x50000000, catalog)
  local specs = {
    { species = "CHIKORITA", level = 5 },
    { species = "TOTODILE", level = 5 },
    { species = "EEVEE", level = 5 },
    { species = "CHIKORITA", level = 6 },
    { species = "TOTODILE", level = 6 },
    { species = "EEVEE", level = 6 },
    { species = "CHIKORITA", level = 7 },
  }
  local mons = {}
  for _, spec in ipairs(specs) do
    mons[#mons + 1] = factory:createNormal(CatalogFixture.normalRequest(spec))
  end
  return mons
end

function T.party_keeps_dense_slots_revision_and_alive_lead()
  local catalog = CatalogFixture.makeCatalog()
  local context = CatalogFixture.domainContext(catalog)
  local Mon = require("libs.mons.src.Mon")
  local Party = require("libs.mons.src.Party")

  local party = Party.new()
  Assert.equal(party:count(), 0)
  Assert.isNil(party:leadSlot())
  Assert.isNil(party:leadAliveSlot())
  Assert.equal(party:revision(), 0)

  local mons = makePartyMons(catalog)
  for slot = 1, 6 do
    Assert.equal(party:add(mons[slot]), true)
  end
  Assert.equal(party:count(), 6)
  Assert.equal(party:revision(), 6)
  Assert.equal(party:add(mons[7]), false)
  Assert.equal(party:count(), 6)
  Assert.equal(party:revision(), 6)

  Assert.deepEqual(party:get(0), mons[1])
  Assert.throws(function()
    party:get(6)
  end)
  Assert.throws(function()
    party:get(-1)
  end)
  Assert.equal(party:leadSlot(), 0)
  Assert.equal(party:leadAliveSlot(), 0)

  local snapshot = party:capture()
  Assert.keySet(snapshot, "max,mons")
  Assert.equal(snapshot.max, 6)
  Assert.deepEqual(snapshot.mons, { mons[1], mons[2], mons[3], mons[4], mons[5], mons[6] })

  local revived = Party.restore(snapshot, context)
  Assert.equal(revived:count(), 6)
  Assert.deepEqual(revived:get(0), mons[1])
  Assert.equal(revived:leadSlot(), 0)
  Assert.isTrue(Party.validate(snapshot, context))

  local function isTotodile(mon)
    return mon.species == "TOTODILE"
  end
  Assert.equal(party:findFirst(isTotodile), 1)

  party:swap(0, 1)
  Assert.deepEqual(party:get(0), mons[2])
  Assert.deepEqual(party:get(1), mons[1])
  Assert.equal(party:revision(), 7)
  Assert.throws(function()
    party:swap(0, 6)
  end)
  Assert.throws(function()
    party:swap(-1, 0)
  end)
  Assert.equal(party:revision(), 7)

  local removed = party:remove(0)
  Assert.deepEqual(removed, mons[2])
  Assert.equal(party:count(), 5)
  Assert.equal(party:revision(), 8)
  Assert.throws(function()
    party:remove(5)
  end)

  -- A fully depleted lead yields to the next living companion.
  local fainted = copy(mons[1])
  fainted.condition.currentHp = 0
  local tired = Party.new()
  tired:add(Mon.validate(fainted, context))
  tired:add(mons[3])
  Assert.equal(tired:leadSlot(), 0)
  Assert.equal(tired:leadAliveSlot(), 1)
  Assert.equal(tired:revision(), 2)

  -- Eggs travel with the party but never lead it.
  local egg = copy(mons[1])
  egg.isEgg = true
  local brood = Party.new()
  brood:add(Mon.validate(egg, context))
  brood:add(mons[3])
  Assert.equal(brood:leadSlot(), 0)
  Assert.equal(brood:leadAliveSlot(), 1)
end

function T.save_bucket_round_trips_under_catalog_fingerprint()
  local catalog = CatalogFixture.makeCatalog()
  local context = CatalogFixture.domainContext(catalog)
  local Party = require("libs.mons.src.Party")
  local MonsSave = require("libs.mons.src.MonsSave")
  local MonFactory = require("libs.mons.src.gen4.MonFactory")
  local args = CatalogFixture.factoryArgs(0x12345678, catalog)
  local factory = MonFactory.new(args)

  local first = factory:createNormal(CatalogFixture.normalRequest({ level = 5 }))
  local second = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE", level = 6 }))
  local party = Party.new()
  party:add(first)
  party:add(second)

  local fingerprint = catalog:fingerprint()
  local rngCapture = args.rng:capture()
  Assert.deepEqual(rngCapture, { state = 0x05856380, calls = 8 })

  local bucket = MonsSave.capture(party:capture(), rngCapture, fingerprint)
  Assert.equal(bucket.schema, "g4-mons-save-v1")
  Assert.equal(bucket.catalogFingerprint, fingerprint)
  Assert.deepEqual(bucket.rng, rngCapture)
  Assert.deepEqual(bucket.party, party:capture())
  Assert.isTrue(MonsSave.validate(bucket, context))

  local restored = MonsSave.restore(bucket, context)
  Assert.equal(restored.party:count(), 2)
  Assert.equal(restored.party:leadSlot(), 0)
  Assert.deepEqual(restored.party:get(1), second)
  Assert.deepEqual(restored.rng:capture(), rngCapture)

  local again = MonsSave.capture(restored.party:capture(), restored.rng:capture(), fingerprint)
  Assert.deepEqual(again, bucket)

  -- The restored generator continues the exact sequence.
  Assert.equal(restored.rng:nextU16(), args.rng:nextU16())

  -- A bucket written against different generated content is rejected.
  local otherRoot = CatalogFixture.buildAssetRoot()
  otherRoot.species.BAYLEEF = copy(otherRoot.species.CHIKORITA)
  otherRoot.species.BAYLEEF.nativeId = 153
  otherRoot.species.BAYLEEF.name = "BAYLEEF"
  local OtherCatalog = require("libs.mons.src.MonCatalog")
  local otherCatalog = OtherCatalog.new(otherRoot)
  Assert.isTrue(otherCatalog:fingerprint() ~= fingerprint)
  local otherContext = CatalogFixture.domainContext(otherCatalog)
  throwsCode("MONS_SAVE_FINGERPRINT_MISMATCH", function()
    MonsSave.restore(bucket, otherContext)
  end)

  -- Malformed buckets fail with a structured save error.
  local missing = copy(bucket)
  missing.rng = nil
  throwsCode("MONS_SAVE_INVALID", function()
    MonsSave.validate(missing, context)
  end)
  local badRng = copy(bucket)
  badRng.rng = { state = "current", calls = 8 }
  throwsCode("MONS_SAVE_INVALID", function()
    MonsSave.validate(badRng, context)
  end)
  local overfull = copy(bucket)
  for _ = 1, 5 do
    overfull.party.mons[#overfull.party.mons + 1] = copy(first)
  end
  Assert.equal(#overfull.party.mons, 7)
  throwsCode("MONS_SAVE_INVALID", function()
    MonsSave.validate(overfull, context)
  end)
  local badMon = copy(bucket)
  badMon.party.mons[2].species = "BOGUS"
  local err = Assert.throws(function()
    MonsSave.restore(badMon, context)
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "MONS_SAVE_INVALID")
  Assert.equal(err.context.slot, 1)
end

return { tests = T }
