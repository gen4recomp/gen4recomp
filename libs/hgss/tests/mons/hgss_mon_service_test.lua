-- HGSS mon-service mutation semantics: form changes are validated and isolated.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Errors = require("libs.errors.src.Errors")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

local function withoutForm(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, item in pairs(value) do
    if key ~= "form" then
      copy[key] = withoutForm(item)
    end
  end
  return copy
end

local function newService()
  local root = CatalogFixture.buildAssetRoot()
  root.species.EEVEE.forms[1].types = { "fire", "dark" }
  local catalog = MonCatalog.new(root)
  local service = HgssMonService.new({
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
    mapSection = 7,
    date = CatalogFixture.metDate(),
  })
  local factory = CatalogFixture.makeFactory(0x12345678, catalog)
  local mon = factory:createNormal(CatalogFixture.normalRequest({ species = "EEVEE", form = 0 }))
  Assert.isTrue(service:addMon(mon), "the multi-form mon must enter the party")
  return service
end

local T = {}

function T.set_mon_form_validates_and_mutates_only_form()
  local service = newService()
  local before = service:partyMon(0)
  local revision = service:partyRevision()

  service:setMonForm(0, 1)
  local changed = service:partyMon(0)
  Assert.equal(changed.form, 1, "a valid form persists")
  Assert.deepEqual(withoutForm(changed), withoutForm(before), "a form change preserves every other mon field")
  Assert.equal(service:partyRevision(), revision + 1, "a valid form publishes one mutation")

  local invalidBefore = service:partyMon(0)
  local invalidCapture = service:capture()
  local invalidRevision = service:partyRevision()
  local err = Assert.throws(function()
    service:setMonForm(0, 2)
  end)
  Assert.isTrue(Errors.is(err), "an invalid form is a structured service error")
  Assert.deepEqual(service:partyMon(0), invalidBefore, "an invalid form preserves the mon")
  Assert.deepEqual(service:capture(), invalidCapture, "an invalid form preserves the save capture")
  Assert.equal(service:partyRevision(), invalidRevision, "an invalid form publishes no mutation")
end

return { tests = T }
