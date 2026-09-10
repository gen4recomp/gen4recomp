-- ROM-conformance test: New Bark Town (map 60) generated physical cells read
-- from the prepared derived cache. These are the publication/runtime facts
-- for the shared EVERYWHERE matrix cell and its neighbors: source identity,
-- published assets, area animation selection, and headless coverage. The
-- whole-corpus field-cell build belongs to cache preparation; this suite only
-- reads the current generated output. Runs only in the ROM-gated layer.

local Assert = require("tests.support.Assert")
local MapResolver = require("romdump.src.digest.map.MapResolver")
local CacheFs = require("libs.storage.src.CacheFs")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local NeighborPlan = require("romdump.src.digest.map.NeighborPlan")
local FieldCoverage = require("libs.hgss.src.world.FieldCoverage")

local T = {}

local function resolve(romFs)
  return assert(MapResolver.resolve(romFs, "MAP_NEW_BARK"))
end

function T.new_bark_physical_cell_is_complete_without_map_scene(_, versionId)
  local cache = CacheFs.forVersion(versionId)
  local index = FieldCellCache.loadIndex(cache)
  local descriptor = assert(FieldCellCache.find(index, 0, 21, 12))
  local cell = assert(cache:loadLua(descriptor.file))

  Assert.isTrue(#cell.batches > 0, "New Bark physical cell has terrain batches")
  local laboratory
  for _, instance in ipairs(cell.buildingInstances) do
    if type(instance.modelKey) == "string" and instance.modelKey:find("^outdoor:21:") then
      laboratory = instance
      break
    end
  end
  Assert.notNil(laboratory, "New Bark physical cell places the laboratory exterior")
  Assert.deepEqual(cell.origin, { x = 672, y = 0, z = 384 })

  for _, batch in ipairs(cell.batches) do
    Assert.isTrue(cache:exists(batch.geometry, "file"), "physical terrain geometry is published")
  end
  for _, material in ipairs(cell.materials) do
    if material.texture ~= nil then
      Assert.isTrue(cache:exists(material.texture, "file"), "physical terrain texture is published")
    end
    if material.textureSwap ~= nil then
      for _, step in ipairs(material.textureSwap.steps) do
        Assert.isTrue(cache:exists(step.texture, "file"), "terrain replacement texture is published")
      end
    end
  end

  local modelPath = MapAssetCache.modelPath(laboratory.modelKey)
  Assert.isTrue(cache:exists(modelPath, "file"), "laboratory model descriptor is published")
  local model = assert(cache:loadLua(modelPath))
  ModelAsset.validate(model)
  for _, path in ipairs(ModelAsset.referencedPaths(model)) do
    Assert.isTrue(cache:exists(path, "file"), "building presentation asset is published")
  end
  Assert.isTrue(cache:exists(cell.collision.file, "file"), "physical collision is published")
  Assert.isTrue(cache:exists(cell.terrain.file, "file"), "physical terrain is published")
  Assert.isTrue(FieldCellCache.validateCell(cache, cell), "physical cell readback validates")
end

function T.new_bark_physical_cell_carries_area_texture_animation(romFs, versionId)
  local cache = CacheFs.forVersion(versionId)
  local index = FieldCellCache.loadIndex(cache)
  local descriptor = assert(FieldCellCache.find(index, 0, 21, 12))
  local cell = assert(cache:loadLua(descriptor.file))
  local mapBundle = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK"))
  local expected = mapBundle.scene.terrainAnimations.textureSrt
  local actual = cell.terrainAnimations.textureSrt

  Assert.isTrue(type(actual) == "table", "New Bark physical cell carries a texture-SRT clip")
  Assert.deepEqual(actual, expected, "physical cell selects the area animation")
  for _, material in ipairs(cell.materials) do
    local swap = material.textureSwap
    if swap ~= nil then
      for _, step in ipairs(swap.steps) do
        Assert.isTrue(cache:exists(step.texture, "file"), "physical cell publishes texture-swap images")
      end
    end
  end
end

-- The shared EVERYWHERE matrix filler (map header 0) is a valid physical
-- cell: header 0 resolves through the catalog and its land member is real
-- data, so the published physical index must contain every valid matrix
-- neighbor of New Bark -- in particular the north/south filler cells -- with
-- source identity preserved, loadable cells, non-empty terrain, and existing
-- referenced assets. Expected ids come from the decoded matrix/neighbor plan,
-- not copied literals.
function T.physical_cell_index_publishes_everywhere_neighbors(romFs, versionId)
  local r = resolve(romFs)
  local plan = NeighborPlan.plan(r.matrix, r.matrixX, r.matrixZ, function(headerId)
    local rec = MapCatalog.areaForMapHeader(headerId)
    return rec and rec.areaDataMemberId or nil
  end)

  local cache = CacheFs.forVersion(versionId)
  local index = FieldCellCache.loadIndex(cache)
  for _, expected in ipairs(plan.cells) do
    local label = string.format("neighbor (%d,%d)", expected.x, expected.z)
    local descriptor = assert(
      FieldCellCache.find(index, r.matrixMemberId, expected.x, expected.z),
      label .. " is published as a physical cell"
    )
    Assert.equal(descriptor.mapHeaderId, expected.mapHeaderId, label .. " keeps its matrix header")
    Assert.equal(descriptor.landDataMemberId, expected.landDataMemberId, label .. " keeps its land member")
    Assert.equal(descriptor.areaDataMemberId, expected.areaDataMemberId, label .. " keeps its area member")
    local cell = assert(cache:loadLua(descriptor.file), label .. " cell loads")
    Assert.isTrue(#cell.batches > 0, label .. " has terrain batches")
    for _, batch in ipairs(cell.batches) do
      Assert.isTrue(cache:exists(batch.geometry, "file"), label .. " terrain geometry is published")
    end
    Assert.isTrue(FieldCellCache.validateCell(cache, cell, descriptor), label .. " cell readback validates")
  end

  -- Pin the north/south pair explicitly: the matrix filler around New Bark is
  -- the valid header-0 EVERYWHERE map, and its descriptors must preserve it.
  for _, dz in ipairs({ -1, 1 }) do
    local x, z = r.matrixX, r.matrixZ + dz
    local source = r.matrix:cell(x, z)
    Assert.equal(source.mapHeaderId, 0, string.format("matrix (%d,%d) is EVERYWHERE filler", x, z))
    Assert.isTrue(source.landDataMemberId ~= 0xFFFF, string.format("matrix (%d,%d) has real land data", x, z))
    local descriptor = assert(
      FieldCellCache.find(index, r.matrixMemberId, x, z),
      string.format("EVERYWHERE cell (%d,%d) is published", x, z)
    )
    Assert.equal(descriptor.mapHeaderId, 0, string.format("cell (%d,%d) preserves header 0", x, z))
    Assert.equal(
      descriptor.landDataMemberId,
      source.landDataMemberId,
      string.format("cell (%d,%d) preserves its land member", x, z)
    )
  end
end

-- Headless runtime coverage centered on New Bark must commit the EVERYWHERE
-- north/south cells as ordinary resident physical cells. Coverage already
-- tolerates genuinely missing descriptors by skipping them, so this asserts
-- the committed window actually contains the valid header-0 neighbors: it
-- fails when the producer index omits them instead of passing on a smaller
-- incomplete window.
function T.committed_coverage_includes_everywhere_neighbors(romFs, versionId)
  local r = resolve(romFs)
  local plan = NeighborPlan.plan(r.matrix, r.matrixX, r.matrixZ, function(headerId)
    local rec = MapCatalog.areaForMapHeader(headerId)
    return rec and rec.areaDataMemberId or nil
  end)

  local cache = CacheFs.forVersion(versionId)
  local coverage = FieldCoverage.new({
    cacheFs = cache,
    index = FieldCellCache.loadIndex(cache),
    matrixMemberId = r.matrixMemberId,
    anchorX = r.matrixX,
    anchorZ = r.matrixZ,
  })
  local ok, err = pcall(function()
    local status = coverage:status()
    Assert.equal(status.anchorX, r.matrixX, "coverage is centered on New Bark")
    Assert.equal(status.anchorZ, r.matrixZ, "coverage is centered on New Bark")
    Assert.equal(status.residentCount, 1 + #plan.cells, "the committed window contains every valid neighbor")
    local resident = {}
    for _, cellKey in ipairs(status.residentCellKeys) do
      resident[cellKey] = true
    end
    local headerZero = 0
    for _, expected in ipairs(plan.cells) do
      local cellKey = string.format("%d:%d", expected.x, expected.z)
      Assert.isTrue(resident[cellKey] == true, "committed coverage includes neighbor " .. cellKey)
      local header = coverage:mapHeaderAt(expected.x * 32 + 1, expected.z * 32 + 1)
      Assert.equal(header, expected.mapHeaderId, "committed cell " .. cellKey .. " keeps its matrix header")
      if expected.mapHeaderId == 0 then
        headerZero = headerZero + 1
      end
    end
    Assert.isTrue(headerZero > 0, "the committed window includes EVERYWHERE header-0 cells")
  end)
  coverage:release()
  if not ok then
    error(err, 0)
  end
end

local suite = require("tests.rom.support.RomSuite").fromFacts(T)
suite.metadata.capabilities = { "rom_dump", "derived_cache" }
return suite
