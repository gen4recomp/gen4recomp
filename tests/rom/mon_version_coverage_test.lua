-- Per-version gate: every ready dump builds a valid version-keyed catalog,
-- creates a legal starter through the production factory, and carries the
-- Elm starter path with its follow-up tail. Runs once per ready version;
-- with only one dump available that single version is the recorded
-- evidence. Catalog compilation itself is owned by the coverage suite;
-- this gate consumes the production cache the field runtime boots from.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldFontLoader = require("libs.hgss.src.ui.FieldFontLoader")
local FieldScripts = require("tests.rom.support.FieldScripts")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonCache = require("libs.assets.src.MonCache")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonFactory = require("libs.mons.src.gen4.MonFactory")
local MapResolver = require("romdump.src.digest.MapResolver")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local TRIO = { "CHIKORITA", "CYNDAQUIL", "TOTODILE" }

local function productionContext(catalog, cacheFs)
  local fontDef = FieldFontLoader.load(cacheFs)
  return {
    catalog = catalog,
    charmap = assert(fontDef.charmap, "production font carries the encoding charmap"),
    games = HgssMonService.GAMES,
    languages = HgssMonService.LANGUAGES,
    items = HgssMonService.ITEMS,
    balls = HgssMonService.BALLS,
  }
end

function T.ready_versions_build_valid_starter_capable_catalogs(romFs, versionId)
  local cacheFs = CacheFs.forVersion(versionId)
  local root = MonCache.loadCatalog(cacheFs)
  Assert.equal(root.version.id, versionId, "the cache catalog is keyed to its version, never a shared fallback")
  local catalog = MonCatalog.new(root)
  local fingerprint = catalog:fingerprint()
  Assert.isTrue(type(fingerprint) == "string" and fingerprint ~= "", "the catalog carries a usable fingerprint")

  local labId =
    assert(MapResolver.resolve(romFs, "MAP_NEW_BARK_ELMS_LAB_1F").map.id, "the lab map resolves in this version")
  local context = productionContext(catalog, cacheFs)
  local factory = MonFactory.new({
    catalog = catalog,
    rng = Lcrng.new(7),
    charmap = context.charmap,
    games = context.games,
    languages = context.languages,
    items = context.items,
    balls = context.balls,
    game = versionId,
    language = root.version.language,
  })
  local profile = { name = "GOLD", gender = 0, trainerId = 1 }
  local seen = {}
  for _, speciesKey in ipairs(TRIO) do
    catalog:form(speciesKey, 0)
    local descriptor = assert(
      catalog:followerSelection({ species = speciesKey, form = 0 }),
      speciesKey .. " carries a follower descriptor"
    )
    Assert.isTrue(
      type(descriptor.visualId) == "number" and descriptor.visualId > 0,
      speciesKey .. " follower resolves to a real visual"
    )
    local mon = factory:createStarter({
      species = speciesKey,
      profile = profile,
      location = labId,
      date = { year = 2000, month = 1, day = 1 },
    })
    Assert.equal(mon.species, speciesKey, "creation preserves the requested species")
    Assert.isTrue(#mon.moves > 0, speciesKey .. " learns its level-5 moves")
    Assert.isNil(seen[mon.personality], speciesKey .. " draws a distinct source record")
    seen[mon.personality] = true
    local BoxCodec = require("libs.mons.src.gen4.BoxCodec")
    local bytes = BoxCodec.encode(mon, context)
    Assert.equal(#bytes, BoxCodec.SIZE, speciesKey .. " encodes to the exact native size")
    local decoded = BoxCodec.decode(bytes, context)
    Assert.equal(decoded.species, speciesKey, "the native projection keeps its identity")
    Assert.equal(decoded.personality, mon.personality, "the native projection keeps its personality")
  end

  -- The Elm starter path and its follow-up tail exist in this version's
  -- own script corpus: the choice opcode and the state operation lower
  -- through the production pipeline, never to silent fallbacks.
  local archive, memberIrs = FieldScripts.decode(romFs)
  local ops = {}
  FieldScripts.eachScript(archive, memberIrs, function(member, index, _, lowered)
    if member == 843 and index == 12 then
      for _, item in ipairs(lowered.items) do
        ops[item.op] = true
      end
    end
  end)
  Assert.isTrue(ops.choose_starter == true, versionId .. " lab script reaches the starter choice")
  Assert.isTrue(ops.follower_set_param == true, versionId .. " lab script carries the follow-up tail")
end

return RomSuite.fromFacts(T)
