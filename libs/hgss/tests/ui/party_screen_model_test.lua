-- Party-screen view projection: one fresh immutable six-slot model per
-- party revision. Occupied slots carry the nickname-or-species display
-- name, derived level, derived gender, derived max HP, live current HP, HP
-- fraction, source status key, and catalog icon key; empty slots carry only
-- position and occupancy. Every derived value comes from the domain owners
-- (Mon, Personality, the service derivation seam, the catalog); the model
-- copies no formula.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PartyScreenModel = require("libs.hgss.src.ui.PartyScreenModel")

local T = {}

local function openService()
  local catalog = CatalogFixture.makeCatalog()
  return catalog,
    HgssMonService.new({
      catalog = catalog,
      bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0xAAAAAAAA):capture(), catalog:fingerprint()),
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

local function give(service, species)
  Assert.isTrue(
    service:giveMon({
      species = species,
      level = 5,
      heldItem = "NONE",
      form = 0,
      location = 7,
      date = CatalogFixture.metDate(),
    }),
    "setup gift must enter the party"
  )
end

local function store(service, slot, mutate)
  local mon = service:partyMon(slot)
  mutate(mon)
  service:removeMon(slot)
  Assert.isTrue(service:addMon(mon), "the mutated fixture mon must stay legal")
end

function T.mixed_party_projects_authoritative_display_values()
  local _, service = openService()
  give(service, "CHIKORITA")
  local maxHp = service:partyMonDerived(0).maxHp
  store(service, 0, function(mon)
    mon.nickname = "LEAFY"
    mon.condition = { status = 0x8, currentHp = maxHp - 2 }
  end)
  give(service, "SHEDINJA")

  local view = PartyScreenModel.build(service)
  Assert.equal(#view.slots, 6, "the projection always covers six slots")
  local lead = view.slots[1]
  Assert.isTrue(lead.occupied)
  Assert.equal(lead.slot, 0)
  Assert.equal(lead.displayName, "LEAFY", "nicknames win over species names")
  Assert.equal(lead.level, 5)
  Assert.isTrue(
    lead.gender == "male" or lead.gender == "female",
    "the starter gender derives, got " .. tostring(lead.gender)
  )
  Assert.equal(lead.status, "poison")
  Assert.equal(lead.currentHp, maxHp - 2)
  Assert.equal(lead.maxHp, maxHp)
  Assert.equal(lead.hpFraction, (maxHp - 2) / maxHp)
  Assert.equal(lead.iconKey, "CHIKORITA/f0")
  Assert.isTrue(lead.eligible, "the default policy admits occupied slots")

  local second = view.slots[2]
  Assert.equal(second.displayName, "SHEDINJA", "nickname falls back to the species name")
  Assert.equal(second.gender, "genderless")
  Assert.equal(second.status, "ok")
  Assert.equal(second.currentHp, second.maxHp)
  Assert.equal(second.maxHp, 1, "the service derivation owns the shedinja rule")
  Assert.equal(second.iconKey, "SHEDINJA/f0")

  for index = 3, 6 do
    local empty = view.slots[index]
    Assert.isFalse(empty.occupied, "trailing slots stay empty")
    Assert.equal(empty.slot, index - 1)
    Assert.isNil(empty.displayName)
    Assert.isNil(empty.iconKey)
    Assert.isNil(empty.level)
    Assert.isNil(empty.status)
    Assert.isFalse(empty.eligible)
  end
end

function T.eggs_project_the_egg_icon()
  local _, service = openService()
  give(service, "CHIKORITA")
  store(service, 0, function(mon)
    mon.isEgg = true
  end)
  local view = PartyScreenModel.build(service)
  Assert.equal(view.slots[1].iconKey, "CHIKORITA/egg")
end

function T.projection_refreshes_with_the_party_revision()
  local _, service = openService()
  give(service, "CHIKORITA")
  local before = PartyScreenModel.build(service)
  give(service, "TOTODILE")
  local after = PartyScreenModel.build(service)
  Assert.isTrue(after.revision ~= before.revision, "the model carries the live revision")
  Assert.isFalse(before.slots[2].occupied, "the earlier model keeps its snapshot")
  Assert.isTrue(after.slots[2].occupied, "the fresh model sees the new mon")
  Assert.isTrue(before.slots[1] ~= after.slots[1], "slot records are fresh tables per build")
end

function T.injected_eligibility_marks_slots_without_touching_values()
  local _, service = openService()
  give(service, "CHIKORITA")
  give(service, "TOTODILE")
  local view = PartyScreenModel.build(service, {
    isEligible = function(slot)
      return slot == 1
    end,
  })
  Assert.isFalse(view.slots[1].eligible)
  Assert.isTrue(view.slots[2].eligible)
  Assert.equal(view.slots[1].displayName, "CHIKORITA", "eligibility never rewrites display values")
end

return { tests = T }
