-- Production-composed field-cell/map boundaries. The harness boots the
-- real generated world and stops before presentation reaches GPU drawing.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local DerivedCacheAudit = require("romdump.src.DerivedCacheAudit")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "field-cell", "map", "canonical-cache" },
  },
  tests = {},
}

local OUTDOOR_MAP = "MAP_NEW_BARK"

local function withOutdoor(fn)
  local harness = AcceptanceHarness.new()
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = OUTDOOR_MAP,
    save = "fresh",
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    fn(game)
    Assert.isNil(game.runtime.errorText, "the production field must remain healthy")
    Assert.equal(game:renderAttempts(), 0, "field-cell acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function centralCell(game)
  local coverage = assert(game.runtime.physicalCoverage, "outdoor production must own physical coverage")
  local cellKey = string.format("%d:%d", coverage.anchorX, coverage.anchorZ)
  local runtime = assert(coverage.cells[cellKey], "the committed physical window has a central cell")
  return coverage, runtime, assert(runtime.descriptor, "the physical cell publishes its cache descriptor")
end

local function assertBatchReferences(left, right, label)
  Assert.equal(#left, #right, label .. " batch count")
  for index, batch in ipairs(left) do
    local other = assert(right[index], label .. " batch " .. index)
    Assert.equal(batch.geometry, other.geometry, label .. " batch " .. index .. " geometry")
    Assert.equal(batch.material, other.material, label .. " batch " .. index .. " material")
  end
end

T.tests["canonical cell is independently ready"] = function()
  withOutdoor(function(game)
    local cacheFs = game.runtime.cacheFs
    local _, _, descriptor = centralCell(game)
    Assert.equal(type(FieldCellCache.cellMarkerPath), "function", "per-cell completion owns a marker path")
    Assert.equal(type(FieldCellCache.isCellReady), "function", "per-cell readiness is a cache boundary")
    local markerPath = FieldCellCache.cellMarkerPath(descriptor.matrixMemberId, descriptor.index)
    local marker = assert(cacheFs:read(markerPath), "the committed central cell has its own completion marker")
    Assert.isTrue(
      FieldCellCache.isCellReady(cacheFs, descriptor, marker),
      "the production-loaded central cell is independently ready"
    )
    Assert.isFalse(
      FieldCellCache.isReady(cacheFs, marker),
      "a cell marker must not be accepted as the complete-corpus marker"
    )
  end)
end

T.tests["map scene reuses canonical central assets"] = function()
  withOutdoor(function(game)
    local _, _, descriptor = centralCell(game)
    local scene =
      assert(game.runtime.runtimeMap and game.runtime.runtimeMap.scene, "the production map scene is loaded")
    assertBatchReferences(scene.mapBatches, descriptor.batches, "central map/cell")
    Assert.equal(scene.collision.file, descriptor.collision.file, "map collision comes from the canonical cell")
    Assert.equal(scene.terrain.file, descriptor.terrain.file, "map terrain comes from the canonical cell")
    Assert.equal(#scene.materials, #descriptor.materials, "map/cell material count")
    Assert.equal(
      #scene.buildingInstances,
      #descriptor.buildingInstances,
      "map/cell placed-building count comes from the canonical cell"
    )
  end)
end

T.tests["physical cell and logical map presentation agree"] = function()
  withOutdoor(function(game)
    local _, runtime, descriptor = centralCell(game)
    local logicalScene = assert(game.runtime.runtimeMap and game.runtime.runtimeMap.scene, "logical scene is loaded")
    local cellPresentation = assert(runtime.presentation, "the physical cell has a production presentation")
    local cellScene = assert(cellPresentation.scene, "the physical presentation retains its normalized scene")
    assertBatchReferences(logicalScene.mapBatches, cellScene.mapBatches, "logical/physical map")
    Assert.equal(#logicalScene.materials, #cellScene.materials, "logical/physical material count")
    Assert.equal(#logicalScene.buildingInstances, #cellScene.buildingInstances, "logical/physical building count")
    Assert.deepEqual(
      logicalScene.calibration,
      descriptor.calibration,
      "logical scene uses the canonical cell calibration"
    )
    Assert.deepEqual(
      cellScene.calibration,
      descriptor.calibration,
      "physical cell presentation uses the canonical cell calibration"
    )
  end)
end

T.tests["complete-corpus attestation remains strict"] = function()
  withOutdoor(function(game)
    local cacheFs = game.runtime.cacheFs
    local corpusMarker =
      assert(cacheFs:read(FieldCellCache.markerPath()), "the generated corpus has a completion marker")
    Assert.isTrue(FieldCellCache.isReady(cacheFs, corpusMarker), "the complete-corpus marker attests every cell")
    Assert.isTrue(DerivedCacheAudit.isAvailable(cacheFs), "the derived-cache audit remains available")
    Assert.equal(type(FieldCellCache.isCellReady), "function", "granular readiness does not replace corpus readiness")
  end)
end

return T
