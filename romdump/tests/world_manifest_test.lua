local Assert = require("tests.support.Assert")
local WorldManifest = require("romdump.src.digest.map.WorldManifest")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local MapMatrix = require("romdump.src.digest.map.MapMatrix")
local MapResolver = require("romdump.src.digest.map.MapResolver")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local FieldCellCompiler = require("romdump.src.digest.field.FieldCellCompiler")
local FieldMapDataFixture = require("tests.support.FieldMapDataFixture")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local GameVersion = require("romdump.src.source.GameVersion")
local Schema = require("libs.script.src.Schema")
local Sha256 = require("libs.script.src.Sha256")
local Errors = require("libs.errors.src.Errors")

local T = {}

-- The artifact staging root mirrors the live cache-relative layout, so the
-- staged manifest lives under `staging/<version>/world/` until publish.
local WORLD_ROOT = "staging/heartgold/world"
local WORLD_STAGE = WORLD_ROOT .. "/" .. MapAssetCache.worldPath()

local function sample()
  return {
    {
      id = 61,
      symbol = "MAP_NEW_BARK_ELMS_LAB_1F",
      mapSection = "NEW_BARK_TOWN",
      mapSectionNativeId = 126,
      followMode = "HEIGHT_RESTRICT",
      width = 1,
      height = 1,
      matrix = { memberId = 0, x = 0, z = 0 },
    },
    {
      id = 60,
      symbol = "MAP_NEW_BARK",
      mapSection = "NEW_BARK_TOWN",
      mapSectionNativeId = 126,
      followMode = "ALLOW",
      width = 3,
      height = 3,
      matrix = { memberId = 0, x = 21, z = 12 },
    },
  }
end

local function selectionExcluded()
  return {
    { id = 3, symbol = "MAP_NOTHING", reason = "no_matching_cell", matchCount = 0 },
    { id = 1, symbol = "MAP_ELSEWHERE", reason = "no_matching_cell", matchCount = 0 },
  }
end

local function compileExcluded()
  return {
    {
      id = 0,
      symbol = "MAP_EVERYWHERE",
      errorCode = "NSBMD_SBC_UNSUPPORTED_COMMAND",
      message = "BBY is unsupported",
      context = { model = "snap_came_in", opcode = 8 },
    },
  }
end

function T.build_sorts_by_id_and_indexes()
  local m = WorldManifest.build(sample(), selectionExcluded(), compileExcluded())
  Assert.equal(m.maps[1].id, 60)
  Assert.equal(m.maps[2].id, 61)
  Assert.equal(m.bySymbol["MAP_NEW_BARK"], 60)
  Assert.equal(m.byId[61], 2)
  Assert.equal(m.maps[1].matrix.x, 21)
  Assert.equal(m.analysis.mapHeaderCount, 5)
  Assert.equal(m.analysis.renderableCount, 2)
end

-- The two exclusion kinds mean different things, so they are separate
-- collections: an unresolved cell is a selection limit, a compile failure is an
-- asset-support gap with a code and context to act on.
function T.selection_and_compile_exclusions_are_separate_and_sorted()
  local m = WorldManifest.build(sample(), selectionExcluded(), compileExcluded())
  Assert.equal(#m.analysis.excluded, 2)
  Assert.equal(m.analysis.excluded[1].id, 1)
  Assert.equal(m.analysis.excluded[2].id, 3)
  Assert.equal(#m.analysis.compileExcluded, 1)
  Assert.equal(m.analysis.compileExcluded[1].symbol, "MAP_EVERYWHERE")
  Assert.equal(m.analysis.compileExcluded[1].errorCode, "NSBMD_SBC_UNSUPPORTED_COMMAND")
  Assert.equal(m.analysis.compileExcluded[1].context.model, "snap_came_in")
end

function T.build_defaults_both_exclusion_collections_to_empty()
  local m = WorldManifest.build(sample())
  Assert.deepEqual(m.analysis.excluded, {})
  Assert.deepEqual(m.analysis.compileExcluded, {})
  Assert.equal(m.analysis.mapHeaderCount, 2)
end

function T.a_map_cannot_be_excluded_twice_across_the_collections()
  Assert.throws(function()
    WorldManifest.build(
      sample(),
      { { id = 0, symbol = "MAP_EVERYWHERE", reason = "no_matching_cell" } },
      compileExcluded()
    )
  end)
end

function T.a_compile_excluded_map_cannot_also_be_renderable()
  Assert.throws(function()
    WorldManifest.build(sample(), {}, { { id = 60, symbol = "MAP_NEW_BARK", errorCode = "X", message = "y" } })
  end)
end

function T.build_rejects_duplicate_symbol()
  local dup = sample()
  dup[1].symbol = "MAP_NEW_BARK"
  Assert.throws(function()
    WorldManifest.build(dup)
  end)
end

function T.build_rejects_missing_map_section()
  local entries = sample()
  entries[1].mapSection = nil
  Assert.throws(function()
    WorldManifest.build(entries)
  end)
end

function T.build_rejects_duplicate_id()
  local dup = sample()
  dup[1].id = 60
  Assert.throws(function()
    WorldManifest.build(dup)
  end)
end

-- The staged manifest lives under the artifact staging root until publish, and
-- the live world.lua is never written directly.
function T.stage_leaves_live_world_untouched_until_publish()
  local backend = FakeCache.new()
  local c = CacheFs.forVersion("heartgold", backend)
  local world = WorldManifest.stage(c, sample(), selectionExcluded(), compileExcluded())
  Assert.isNil(c:getInfo(MapAssetCache.worldPath()), "live world.lua must not exist before publish")
  Assert.notNil(backend:getInfo(WORLD_STAGE), "the manifest is staged for the pending publication")
  world:publish()
  local live = assert(c:loadLua(MapAssetCache.worldPath()))
  Assert.equal(live.maps[1].id, 60)
  Assert.equal(live.bySymbol["MAP_NEW_BARK"], 60)
  Assert.equal(live.analysis.mapHeaderCount, 5)
  Assert.isNil(backend:getInfo(WORLD_ROOT), "the stage is removed after a successful publish")
end

-- A staged manifest that does not read back as a manifest fails the stage: the
-- stage is discarded and the previous live world stays the last-known-good.
function T.corrupted_staged_write_fails_without_touching_the_live_world()
  local backend = FakeCache.new()
  local c = CacheFs.forVersion("heartgold", backend)
  local first = WorldManifest.stage(c, sample())
  first:publish()
  local orig = backend.write
  backend.write = function(self, path, data)
    if path == WORLD_STAGE then
      return orig(self, path, "not a lua manifest")
    end
    return orig(self, path, data)
  end
  local err = Assert.throws(function()
    WorldManifest.stage(c, sample(), selectionExcluded(), compileExcluded())
  end)
  backend.write = orig
  Assert.equal(err.code, "WORLD_MANIFEST_READBACK_FAILED")
  Assert.isNil(backend:getInfo(WORLD_ROOT), "the failed stage is discarded")
  local live = assert(c:loadLua(MapAssetCache.worldPath()))
  Assert.equal(live.analysis.mapHeaderCount, 2, "the live world must stay the last-known-good")
end

-- A publish failure re-raises and leaves the last-known-good live world in
-- place: the single-file swap is atomic on the host rename.
function T.publish_failure_keeps_the_last_known_good_world_live()
  local backend = FakeCache.new()
  local c = CacheFs.forVersion("heartgold", backend)
  local first = WorldManifest.stage(c, sample())
  first:publish()
  local originalReplace = backend.replace
  backend.replace = function(self, sourcePath, destinationPath)
    local candidatePrefix = "heartgold/" .. MapAssetCache.worldPath() .. ".__g4next."
    if sourcePath:sub(1, #candidatePrefix) == candidatePrefix then
      return false, "injected publish failure"
    end
    return originalReplace(self, sourcePath, destinationPath)
  end
  local second = WorldManifest.stage(c, sample(), selectionExcluded(), compileExcluded())
  local err = Assert.throws(function()
    second:publish()
  end)
  backend.replace = originalReplace
  Assert.equal(err.code, "CACHE_REPLACE_FAILED")
  local live = assert(c:loadLua(MapAssetCache.worldPath()))
  Assert.equal(live.analysis.mapHeaderCount, 2, "the last-known-good world stays live after a failed publish")
end

-- Abort discards the disposable stage; the live world is never touched.
function T.abort_discards_the_staged_manifest_without_touching_live()
  local backend = FakeCache.new()
  local c = CacheFs.forVersion("heartgold", backend)
  local world = WorldManifest.stage(c, sample(), selectionExcluded(), compileExcluded())
  world:abort()
  Assert.isNil(c:getInfo(MapAssetCache.worldPath()), "abort never touches the live world")
  Assert.isNil(backend:getInfo(WORLD_ROOT), "abort discards the staged manifest")
end

local HEARTGOLD_SHA1 = GameVersion.VERSIONS.heartgold.sha1

local function generationIdFor(producerBody)
  local identity = DerivedCacheState.current({
    versionId = "heartgold",
    romSha1 = HEARTGOLD_SHA1,
    mode = "development",
    producerId = "d" .. producerBody,
    assetRevision = DerivedAssetContract.revision,
    scriptApi = Schema.API_VERSION,
  })
  return assert(identity.generationId)
end

local function catalogCensus()
  local count = 0
  for _ in MapCatalog.all() do
    count = count + 1
  end
  return count
end

-- The structural catalog is derived from source analysis alone: with the map
-- and cell geometry compilers trapped to fail, catalog compilation still
-- succeeds, keeps the established index meanings, and carries the resolver
-- normalized origins on every record.
function T.world_catalog_compiles_from_source_without_geometry()
  Assert.equal(type(WorldManifest.compileCatalog), "function", "the structural catalog compiles from source")
  local romFs = FieldMapDataFixture.build()
  local savedMapCompile, savedCellCompile = MapAssetCompiler.compile, FieldCellCompiler.compileCell
  MapAssetCompiler.compile = function()
    error("geometry lowering must not run during catalog compilation")
  end
  FieldCellCompiler.compileCell = function()
    error("cell geometry must not run during catalog compilation")
  end
  local ok, bundle = pcall(WorldManifest.compileCatalog, romFs)
  MapAssetCompiler.compile = savedMapCompile
  FieldCellCompiler.compileCell = savedCellCompile
  assert(ok, bundle)
  local catalog = assert(bundle, "catalog compilation must produce a bundle")
  Assert.equal(type(catalog.maps), "table")
  Assert.isTrue(#catalog.maps > 0, "the source catalog is non-empty")
  for index, record in ipairs(catalog.maps) do
    if index > 1 then
      Assert.isTrue(catalog.maps[index - 1].id < record.id, "catalog maps are ordered by id")
    end
    Assert.equal(catalog.byId[record.id], index, "byId maps an id to its array position")
    Assert.equal(catalog.bySymbol[record.symbol], record.id, "bySymbol maps a symbol to its id")
    Assert.equal(type(record.mapSection), "string")
    Assert.equal(type(record.mapSectionNativeId), "number")
    Assert.notNil(record.followMode)
    local resolved = assert(MapResolver.resolve(romFs, record.id))
    Assert.equal(record.worldOriginX, resolved.worldOriginX, "origin follows the resolver rule")
    Assert.equal(record.worldOriginZ, resolved.worldOriginZ, "origin follows the resolver rule")
  end
  Assert.equal(catalog.analysis.mapHeaderCount, catalogCensus(), "counts come from the catalog enumerator")
  Assert.equal(#catalog.maps + #catalog.analysis.excluded, catalogCensus())
  Assert.equal(type(catalog.marker), "string")
end

-- A geometry compilation failure is a job diagnostic, not a namespace edit:
-- the failed map stays addressable in a freshly derived catalog with the
-- failure reported against the map instead of reclassifying it as absent.
function T.world_catalog_keeps_a_map_whose_geometry_job_fails()
  Assert.equal(type(WorldManifest.compileCatalog), "function", "the structural catalog compiles from source")
  local romFs = FieldMapDataFixture.build()
  local targetId = 60
  local before = assert(WorldManifest.compileCatalog(romFs))
  Assert.equal(before.bySymbol["MAP_NEW_BARK"], targetId)
  local savedCompile = MapAssetCompiler.compile
  MapAssetCompiler.compile = function()
    Errors.raise("MAP_CACHE_BAD_COLLISION", "injected geometry failure", { mapId = targetId })
  end
  local ok, err = pcall(MapAssetCompiler.compile, romFs, targetId)
  MapAssetCompiler.compile = savedCompile
  Assert.isFalse(ok, "the geometry job reports its failure")
  err = assert(err)
  Assert.equal(err.code, "MAP_CACHE_BAD_COLLISION")
  Assert.equal(err.context.mapId, targetId)
  local after = assert(WorldManifest.compileCatalog(romFs))
  Assert.equal(after.bySymbol["MAP_NEW_BARK"], targetId, "the map remains addressable after its geometry fails")
  Assert.notNil(after.byId[targetId], "the map keeps its index after its geometry fails")
  local resolved = assert(MapResolver.resolve(romFs, targetId))
  for _, record in ipairs(after.maps) do
    if record.id == targetId then
      Assert.equal(record.worldOriginX, resolved.worldOriginX)
      Assert.equal(record.worldOriginZ, resolved.worldOriginZ)
    end
  end
  Assert.deepEqual(after.byId, before.byId, "the failure rewrites no namespace")
end

-- The canonical cell index is authoritative: every physical descriptor keeps
-- its exact matrix/index identity in row-major order, and two descriptors
-- that share one land payload stay distinct instead of being deduplicated.
function T.world_catalog_cells_keep_canonical_matrix_identities_without_payload_dedup()
  local romFs = FieldMapDataFixture.build()
  local bundle = assert(FieldCellCompiler.compileIndex(romFs))
  local seen = {}
  local landCounts = {}
  for _, matrix in ipairs(bundle.index.matrices) do
    for position, descriptor in ipairs(matrix.cells) do
      if position > 1 then
        Assert.isTrue(
          matrix.cells[position - 1].index < descriptor.index,
          "cells within one matrix are ordered by index"
        )
      end
      Assert.equal(descriptor.index, descriptor.z * matrix.width + descriptor.x, "row-major cell identity")
      Assert.equal(descriptor.file, FieldCellCache.cellPath(descriptor.matrixMemberId, descriptor.index))
      local key = descriptor.matrixMemberId .. ":" .. descriptor.index
      Assert.isNil(seen[key], "no descriptor is enumerated twice")
      seen[key] = true
      landCounts[descriptor.landDataMemberId] = (landCounts[descriptor.landDataMemberId] or 0) + 1
    end
  end
  Assert.isTrue(
    (landCounts[FieldMapDataFixture.LAND_MEMBER_ID] or 0) > 1,
    "descriptors sharing one land payload are preserved, not deduplicated"
  )
end

-- Source-excluded headers are accounted exclusions with reasons, never silent
-- holes: every catalog header appears exactly once across the renderable and
-- excluded collections, and the totals come from the catalog enumerator.
function T.world_catalog_reports_source_exclusions_with_reasons_and_enumerator_counts()
  Assert.equal(type(WorldManifest.compileCatalog), "function", "the structural catalog compiles from source")
  local romFs = FieldMapDataFixture.build()
  local catalog = assert(WorldManifest.compileCatalog(romFs))
  local expected = catalogCensus()
  Assert.equal(catalog.analysis.mapHeaderCount, expected)
  Assert.equal(#catalog.maps + #catalog.analysis.excluded, expected)
  local membership = {}
  for _, record in ipairs(catalog.maps) do
    Assert.isNil(membership[record.id], "a renderable map is listed once")
    membership[record.id] = "renderable"
  end
  local fillerReason = nil
  for _, record in ipairs(catalog.analysis.excluded) do
    Assert.isNil(membership[record.id], "an excluded map is never also renderable")
    membership[record.id] = "excluded"
    Assert.equal(type(record.reason), "string", "every exclusion carries its reason")
    Assert.equal(type(record.symbol), "string")
    if record.id == 0 then
      fillerReason = record.reason
    end
  end
  Assert.notNil(fillerReason, "the default header filler is an accounted exclusion")
  local enumerated = 0
  for record in MapCatalog.all() do
    enumerated = enumerated + 1
    Assert.notNil(membership[record.id], "every catalog header is accounted exactly once")
  end
  Assert.equal(enumerated, expected)
end

-- Publishing the structural world replaces only the world file: a previously
-- compiled child subtree keeps its exact bytes and readiness stays a
-- per-artifact property rather than following the index.
function T.world_catalog_replacement_leaves_compiled_children_untouched()
  Assert.equal(type(WorldManifest.compileCatalog), "function", "the structural catalog compiles from source")
  Assert.equal(type(WorldManifest.stageCatalog), "function", "the world file stages on its own")
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local previous = WorldManifest.stage(cache, sample())
  previous:publish()
  local childDir = MapAssetCache.mapDir(60)
  cache:write(childDir .. "/complete", "child-marker")
  cache:write(childDir .. "/dependencies.lua", "return { marker = 'child-marker' }")
  local childMarker = cache:read(childDir .. "/complete")
  local childDependencies = cache:read(childDir .. "/dependencies.lua")
  local catalog = assert(WorldManifest.compileCatalog(FieldMapDataFixture.build()))
  local generation = generationIdFor(Sha256.hex("world catalog child preservation"))
  local artifact = PreparedArtifact.new({
    cacheFs = cache,
    generationId = generation,
    epoch = 1,
    kind = "world-catalog",
    key = "global",
    jobKey = "world-catalog:global",
    stageName = "world-catalog",
  })
  WorldManifest.stageCatalog(artifact, catalog)
  local stage = artifact:stageFs()
  Assert.notNil(stage:loadLua(MapAssetCache.worldPath()), "the stage carries the new world file")
  Assert.isFalse(stage:exists(childDir), "the stage owns the world file only")
  artifact:finishSuccess({ marker = catalog.marker })
  artifact:publish({
    generationId = generation,
    epoch = 1,
    kind = "world-catalog",
    key = "global",
    jobKey = "world-catalog:global",
  })
  local live = assert(cache:loadLua(MapAssetCache.worldPath()))
  Assert.equal(live.bySymbol["MAP_NEW_BARK"], 60, "the structural catalog is live")
  Assert.equal(live.analysis.mapHeaderCount, catalogCensus())
  Assert.equal(cache:read(childDir .. "/complete"), childMarker, "the child marker is untouched")
  Assert.equal(cache:read(childDir .. "/dependencies.lua"), childDependencies, "the child payload is untouched")
end

-- A catalog stage that does not read back as a structural catalog fails the
-- stage: the disposable stage is aborted and the previous live world stays
-- the last-known-good.
function T.world_catalog_stage_failure_preserves_the_previous_world()
  Assert.equal(type(WorldManifest.stageCatalog), "function", "the world file stages on its own")
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local previous = WorldManifest.stage(cache, sample())
  previous:publish()
  local catalog = assert(WorldManifest.compileCatalog(FieldMapDataFixture.build()))
  catalog.maps[1].worldOriginX = nil
  local generation = generationIdFor(Sha256.hex("world catalog stage failure"))
  local artifact = PreparedArtifact.new({
    cacheFs = cache,
    generationId = generation,
    epoch = 1,
    kind = "world-catalog",
    key = "global",
    jobKey = "world-catalog:global",
    stageName = "world-catalog",
  })
  local err = Assert.throws(function()
    WorldManifest.stageCatalog(artifact, catalog)
  end)
  Assert.equal(err.code, "WORLD_MANIFEST_READBACK_FAILED")
  artifact:abort()
  local live = assert(cache:loadLua(MapAssetCache.worldPath()))
  Assert.equal(live.analysis.mapHeaderCount, 2, "the live world must stay the last-known-good")
end

-- Row-major cell identity and normalized origins at nonzero matrix
-- coordinates: the top-left field tile owned by cell (x, z) follows the fixed
-- tiles-per-cell rule, and out-of-range coordinates fail instead of wrapping.
function T.matrix_cell_identity_and_origin_arithmetic_at_nonzero_coordinates()
  local member = string.char(3, 2, 1, 0, 0)
    .. string.char(0x0A, 0, 0x14, 0, 0x1E, 0, 0x28, 0, 0x32, 0, 0x3C, 0)
    .. string.char(7, 0, 7, 0, 7, 0, 7, 0, 7, 0, 7, 0)
  local matrix = assert(MapMatrix.decode(member, 99))
  Assert.equal(matrix:index(2, 1), 5, "row-major index arithmetic")
  local originX, originZ = matrix:worldOrigin(2, 1)
  Assert.equal(originX, 64, "nonzero x origin follows the tiles-per-cell rule")
  Assert.equal(originZ, 32, "nonzero z origin follows the tiles-per-cell rule")
  local found = matrix:findCellsByMapHeaderId(0x0A)
  Assert.equal(#found, 1)
  Assert.equal(found[1].index, 0)
  Assert.throws(function()
    matrix:worldOrigin(3, 1)
  end)
end

return { tests = T }
