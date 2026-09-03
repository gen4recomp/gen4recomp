-- ROM-conformance test: selected source edge cases in the compiled mon
-- catalog match decomp/ROM facts. Assertions are relationships and known
-- source facts (native identities, form counts, representative stats), never
-- whole-catalog snapshots. Expected stat values below are verified against
-- the personal NARC on supported dumps (Chikorita special attack is 49,
-- Totodile special attack/defense are 44/48).

local Assert = require("tests.support.Assert")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function compile(romFs, versionId)
  local MonCatalogCompiler = require("romdump.src.digest.MonCatalogCompiler")
  return assert(MonCatalogCompiler.compileCatalog(romFs, { versionId = versionId }))
end

-- The three starter species resolve with their native identities and
-- well-known base stats.
function T.starter_species_carry_native_identity_and_base_stats(romFs, versionId)
  local catalog = compile(romFs, versionId)
  local expected = {
    CHIKORITA = { nativeId = 152, stats = { 45, 49, 65, 45, 49, 65 } },
    CYNDAQUIL = { nativeId = 155, stats = { 39, 52, 43, 65, 60, 50 } },
    TOTODILE = { nativeId = 158, stats = { 50, 65, 64, 43, 44, 48 } },
  }
  for key, wanted in pairs(expected) do
    local species = assert(catalog.species[key], key .. " must be present")
    Assert.equal(species.nativeId, wanted.nativeId, key .. " native id")
    local form = assert(species.forms[0], key .. " must carry base form")
    local stats = form.baseStats
    Assert.equal(stats.hp, wanted.stats[1], key .. " hp")
    Assert.equal(stats.attack, wanted.stats[2], key .. " attack")
    Assert.equal(stats.defense, wanted.stats[3], key .. " defense")
    Assert.equal(stats.speed, wanted.stats[4], key .. " speed")
    Assert.equal(stats.specialAttack, wanted.stats[5], key .. " special attack")
    Assert.equal(stats.specialDefense, wanted.stats[6], key .. " special defense")
    Assert.isTrue(#form.levelUpMoves > 0, key .. " must carry a learnset")
  end
end

-- Alternate-form resolution covers the known multi-form species, and the
-- single-HP species keeps its defining stat.
function T.alternate_forms_and_single_hp_species_match_source(romFs, versionId)
  local catalog = compile(romFs, versionId)
  local formCounts = {
    UNOWN = 28,
    DEOXYS = 4,
    ROTOM = 6,
    GIRATINA = 2,
    SHAYMIN = 2,
  }
  for key, count in pairs(formCounts) do
    local species = assert(catalog.species[key], key .. " must be present")
    local forms = 0
    for _ in pairs(species.forms) do
      forms = forms + 1
    end
    Assert.equal(forms, count, key .. " form count")
  end
  local shedinja = assert(catalog.species.SHEDINJA, "SHEDINJA must be present")
  Assert.equal(shedinja.forms[0].baseStats.hp, 1, "Shedinja base HP is 1")
end

-- Dual-ability species expose both abilities, and every catalog selection for
-- icons, portraits, and followers resolves to a manifest entry. Bulbasaur is
-- single-ability on supported dumps (personal abilities 65/0), so the
-- two-ability representative is Abra (Synchronize/Inner Focus, 28/39).
function T.abilities_and_presentation_selectors_resolve(romFs, versionId)
  local catalog = compile(romFs, versionId)
  local MonCache = require("libs.assets.src.MonCache")
  local CacheFs = require("libs.storage.src.CacheFs")
  local abra = assert(catalog.species.ABRA, "ABRA must be present")
  local abilities = assert(abra.forms[0].abilities, "Abra must carry abilities")
  Assert.equal(#abilities, 2, "a two-ability species exposes both slots")
  Assert.equal(abilities[1], "SYNCHRONIZE")
  Assert.equal(abilities[2], "INNER_FOCUS")

  local cache = CacheFs.forVersion(versionId)
  local icons = assert(cache:loadLua(MonCache.iconManifestPath()), "icon manifest must load")
  local portraits = assert(cache:loadLua(MonCache.portraitManifestPath()), "portrait manifest must load")
  for _, key in ipairs({ "CHIKORITA", "CYNDAQUIL", "TOTODILE" }) do
    local form = assert(catalog.species[key].forms[0], key .. " base form")
    Assert.notNil(icons.entries[form.icon], key .. " icon selector must resolve")
    Assert.notNil(portraits.entries[form.portrait], key .. " portrait selector must resolve")
    local follower = form.follower
    if follower ~= nil then
      Assert.notNil(follower.visualId, key .. " follower must reference a field-actor visual")
    end
  end
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump", "derived_cache" }
return suite
