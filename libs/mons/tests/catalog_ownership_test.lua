-- Catalog ownership: immutable indexed definitions with deterministic
-- fingerprints, native-identity lookups, and presentation selection through
-- the selected form.

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

function T.catalog_indexes_definitions_and_selects_presentations()
  local catalog = CatalogFixture.makeCatalog()

  Assert.equal(catalog:species("CHIKORITA").nativeId, 152)
  Assert.equal(catalog:speciesByNativeId(158).name, "TOTODILE")
  Assert.equal(catalog:move("TACKLE").nativeId, 33)
  Assert.equal(catalog:moveByNativeId(45).name, "Growl")
  Assert.equal(catalog:ability("OVERGROW").nativeId, 65)
  Assert.equal(catalog:abilityByNativeId(67).name, "Torrent")
  Assert.equal(catalog:speciesKeyByNativeId(133), "EEVEE")
  Assert.equal(catalog:moveKeyByNativeId(33), "TACKLE")
  Assert.equal(catalog:abilityKeyByNativeId(65), "OVERGROW")
  Assert.equal(#catalog:growthCurve("medium_slow"), 100)

  local form = catalog:form("CHIKORITA", 0)
  Assert.equal(form.baseStats.hp, 45)
  Assert.throws(function()
    catalog:form("CHIKORITA", 3)
  end)

  local mon = { species = "CHIKORITA", form = 0 }
  Assert.equal(catalog:iconSelection(mon), "CHIKORITA/f0")
  Assert.equal(catalog:portraitSelection(mon), "CHIKORITA/f0/male/plain")
  Assert.notNil(catalog:followerSelection(mon))
  Assert.isNil(catalog:followerSelection({ species = "EEVEE", form = 0 }))

  throwsCode("MON_RECORD_INVALID", function()
    catalog:species("BOGUS")
  end)
  throwsCode("MON_RECORD_INVALID", function()
    catalog:move("BOGUS")
  end)
  throwsCode("MON_RECORD_INVALID", function()
    catalog:speciesKeyByNativeId(9999)
  end)

  -- The fingerprint is deterministic for an unchanged root and moves with
  -- any content change.
  local again = CatalogFixture.makeCatalog()
  Assert.equal(again:fingerprint(), catalog:fingerprint())
  local altered = CatalogFixture.buildAssetRoot()
  altered.species.BAYLEEF = copy(altered.species.CHIKORITA)
  altered.species.BAYLEEF.nativeId = 153
  altered.species.BAYLEEF.name = "BAYLEEF"
  local OtherCatalog = require("libs.mons.src.MonCatalog")
  Assert.isTrue(OtherCatalog.new(altered):fingerprint() ~= catalog:fingerprint())

  -- Later callers cannot replace the indexed maps through the input root.
  local root = CatalogFixture.buildAssetRoot()
  local frozen = OtherCatalog.new(root)
  root.species.CHIKORITA = nil
  Assert.equal(frozen:species("CHIKORITA").nativeId, 152)

  -- Duplicate native identities fail at construction.
  local doubled = CatalogFixture.buildAssetRoot()
  doubled.species.FAKE = copy(doubled.species.CHIKORITA)
  doubled.species.FAKE.name = "FAKE"
  Assert.throws(function()
    OtherCatalog.new(doubled)
  end)
end

function T.catalog_resolves_item_identities_through_the_generated_collection()
  local catalog = CatalogFixture.makeCatalog()

  Assert.equal(catalog:itemKeyByNativeId(0), "NONE")
  Assert.equal(catalog:itemKeyByNativeId(4), "POKE_BALL")
  local ball = catalog:item("POKE_BALL")
  Assert.equal(ball.nativeId, 4)
  Assert.isTrue(ball.isBall)
  Assert.isFalse(ball.friendshipBoost)
  local plain = catalog:itemByNativeId(158)
  Assert.equal(plain.nativeId, 158)
  Assert.isFalse(plain.isBall)
  throwsCode("MON_RECORD_INVALID", function()
    catalog:item("BOGUS_ITEM")
  end)
  throwsCode("MON_RECORD_INVALID", function()
    catalog:itemKeyByNativeId(9999)
  end)

  -- The item index survives input-root mutation like every other index.
  local root = CatalogFixture.buildAssetRoot()
  local frozen = require("libs.mons.src.MonCatalog").new(root)
  root.items.POKE_BALL = nil
  Assert.equal(frozen:item("POKE_BALL").nativeId, 4)
end

return { tests = T }
