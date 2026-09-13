-- ROM-backed geometry compilation: representative map, neighbor, static-building,
-- and animated-building paths expose the same dense batch representation and
-- deterministic ordering to the downstream mesh writer.

local Assert = require("tests.support.Assert")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local RomSuite = require("tests.rom.support.RomSuite")
local CompiledAsset = require("tests.rom.support.CompiledAsset")

local T = {}

local function meshSnapshot(bundle)
  local snapshot = {}
  local meshCount = 0
  for meshKey, batch in pairs(bundle.meshes) do
    meshCount = meshCount + 1
    local decoded = CompiledAsset.mesh(batch)
    Assert.isTrue(decoded.vertexCount > 0, "ROM batch has emitted vertices")
    Assert.isTrue(decoded.indexCount > 0, "ROM batch has emitted indices")
    local record = {
      vertices = {},
      indices = {},
    }
    for _, vertex in ipairs(decoded.vertices) do
      record.vertices[#record.vertices + 1] = vertex
    end
    for _, index in ipairs(decoded.indices) do
      Assert.isTrue(index < decoded.vertexCount, "ROM batch indices remain local to the mesh")
      record.indices[#record.indices + 1] = index
    end
    snapshot[meshKey] = record
  end
  Assert.isTrue(meshCount > 0, "representative ROM map emits geometry batches")
  return snapshot
end

function T.representative_map_models_use_dense_geometry_deterministically(romFs)
  local first = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK"))
  local second = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK"))
  Assert.isTrue(#first.scene.mapBatches > 0, "the representative map emits map batches")
  Assert.isTrue(next(first.models) ~= nil, "the representative map emits building model descriptors")
  Assert.deepEqual(meshSnapshot(second), meshSnapshot(first), "representative model geometry is deterministic")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.tags = { "geometry", "model", "determinism" }
return suite
