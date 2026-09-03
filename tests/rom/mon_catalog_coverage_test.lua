-- ROM-conformance test: a supported user-owned dump produces the complete,
-- strictly validated mon catalog graph. Runs only in the ROM-gated layer and
-- never checks in decoded commercial data: assertions are coverage
-- relationships and cross-reference validity, not catalog snapshots.

local Assert = require("tests.support.Assert")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

-- Every source-resolved species/form, move, ability, growth curve, learnset,
-- evolution, icon, portrait, and follower reference validates, and no source
-- personal member is silently dropped from the semantic catalog. The
-- personal archive carries 508 members: species 0..493, the EGG/BAD_EGG
-- identities 494/495, and 12 alternate-form pseudo-members, so the catalog
-- holds exactly the 496 species identities and every member is reachable as
-- a species base form or a parented alternate form.
function T.complete_native_catalog_compiles_and_validates(romFs, versionId)
  local MonCatalogCompiler = require("romdump.src.digest.MonCatalogCompiler")
  local MonAssetSchema = require("libs.assets.src.MonAssetSchema")
  local MonSources = require("romdump.src.config.MonSources")
  local catalog = assert(MonCatalogCompiler.compileCatalog(romFs, { versionId = versionId }))
  Assert.isTrue(MonAssetSchema.isValidCatalog(catalog), "compiled catalog must pass the shared schema")

  local personal = assert(romFs:openNarc("personal"))
  local memberCount = personal.memberCount and personal:memberCount() or #personal
  Assert.equal(memberCount, 508, "personal member census anchors the coverage invariant")
  local speciesCount = 0
  for _ in pairs(catalog.species) do
    speciesCount = speciesCount + 1
  end
  Assert.equal(speciesCount, 496, "catalog must carry NONE..BAD_EGG as species identities")
  local covered = {}
  for key, species in pairs(catalog.species) do
    local speciesId = assert(MonSources.speciesId(key), key .. " must be a known species identity")
    Assert.notNil(species.forms[0], key .. " must carry its base form")
    for formId, form in pairs(species.forms) do
      Assert.isTrue(
        MonAssetSchema.isValidForm(form, { species = key, form = formId }),
        key .. " form " .. tostring(formId) .. " must validate"
      )
      covered[MonSources.resolvePersonalMember(speciesId, formId)] = true
    end
  end
  for memberId = 0, memberCount - 1 do
    Assert.isTrue(covered[memberId] == true, "personal member " .. memberId .. " must be reachable from the catalog")
  end

  local moveCount = 0
  for _ in pairs(catalog.moves) do
    moveCount = moveCount + 1
  end
  Assert.isTrue(moveCount > 0, "catalog must carry moves")
  local abilityCount = 0
  for _ in pairs(catalog.abilities) do
    abilityCount = abilityCount + 1
  end
  Assert.isTrue(abilityCount > 0, "catalog must carry abilities")
  Assert.equal(#catalog.growthCurves, 0, "growth curves are keyed records, not an array")
end

-- Growth curves cover exact cumulative experience for levels 1 through 100, so
-- runtime creation never evaluates source growth formulas.
function T.growth_curves_cover_levels_1_through_100(romFs, versionId)
  local MonCatalogCompiler = require("romdump.src.digest.MonCatalogCompiler")
  local catalog = assert(MonCatalogCompiler.compileCatalog(romFs, { versionId = versionId }))
  local curveCount = 0
  for _, curve in pairs(catalog.growthCurves) do
    curveCount = curveCount + 1
    Assert.equal(#curve, 100, "each curve must carry levels 1..100")
    Assert.equal(curve[1], 0, "level 1 experience must be zero")
    for level = 2, 100 do
      Assert.isTrue(curve[level] >= curve[level - 1], "experience must be non-decreasing")
    end
  end
  Assert.isTrue(curveCount > 0, "catalog must carry growth curves")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump", "derived_cache" }
return suite
