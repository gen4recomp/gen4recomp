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
  -- any mon content change.
  local again = CatalogFixture.makeCatalog()
  Assert.equal(again:fingerprint(), catalog:fingerprint())
  local altered = CatalogFixture.buildAssetRoot()
  altered.species.BAYLEEF = copy(altered.species.CHIKORITA)
  altered.species.BAYLEEF.nativeId = 153
  altered.species.BAYLEEF.name = "BAYLEEF"
  local OtherCatalog = require("libs.mons.src.MonCatalog")
  Assert.isTrue(OtherCatalog.new(altered, CatalogFixture.makeItemCatalog()):fingerprint() ~= catalog:fingerprint())

  -- Later callers cannot replace the indexed maps through the input root.
  local root = CatalogFixture.buildAssetRoot()
  local frozen = OtherCatalog.new(root, CatalogFixture.makeItemCatalog())
  root.species.CHIKORITA = nil
  Assert.equal(frozen:species("CHIKORITA").nativeId, 152)

  -- Duplicate native identities fail at construction.
  local doubled = CatalogFixture.buildAssetRoot()
  doubled.species.FAKE = copy(doubled.species.CHIKORITA)
  doubled.species.FAKE.name = "FAKE"
  Assert.throws(function()
    OtherCatalog.new(doubled, CatalogFixture.makeItemCatalog())
  end)
end

function T.catalog_delegates_item_identities_to_the_shared_catalog()
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
  local itemErr = Assert.throws(function()
    catalog:item("BOGUS_ITEM")
  end)
  Assert.isTrue(Errors.is(itemErr), "unknown items raise structured item-domain errors")
  Assert.equal(itemErr.code, "ITEM_RECORD_INVALID")
  local nativeErr = Assert.throws(function()
    catalog:itemKeyByNativeId(9999)
  end)
  Assert.equal(nativeErr.code, "ITEM_RECORD_INVALID")
end

function T.catalog_fingerprint_excludes_the_external_item_catalog()
  local catalog = CatalogFixture.makeCatalog()
  local ItemFixture = require("libs.items.tests.item_fixture")
  local alteredRoot = ItemFixture.buildAssetRoot()
  alteredRoot.items.POTION.description = "a changed description"
  alteredRoot.items.POTION.nameIndefinite = "a changed Potion"
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  local alteredItems = ItemCatalog.new(alteredRoot)
  Assert.isTrue(alteredItems:fingerprint() ~= CatalogFixture.makeItemCatalog():fingerprint())
  local OtherCatalog = require("libs.mons.src.MonCatalog")
  local relinked = OtherCatalog.new(CatalogFixture.buildAssetRoot(), alteredItems)
  Assert.equal(relinked:fingerprint(), catalog:fingerprint())
end

return { tests = T }
