-- ROM-backed geometry compilation: representative map, neighbor, static-building,
-- and animated-building paths expose the same dense batch representation and
-- deterministic ordering to the downstream mesh writer.

local Assert = require("tests.support.Assert")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function meshSnapshot(bundle)
  local snapshot = {}
  local meshCount = 0
  for meshKey, batch in pairs(bundle.meshes) do
    meshCount = meshCount + 1
    Assert.isNil(batch.vertices, "ROM model batches do not materialize Lua vertex tables")
    Assert.isNil(batch.indices, "ROM model batches do not materialize Lua index tables")
    local arena = assert(batch.arena, "ROM model batch borrows its compiler geometry arena")
    Assert.equal(type(batch.vertexOffset), "number", "ROM batch vertex offset")
    Assert.equal(type(batch.vertexCount), "number", "ROM batch vertex count")
    Assert.equal(type(batch.indexOffset), "number", "ROM batch index offset")
    Assert.equal(type(batch.indexCount), "number", "ROM batch index count")
    Assert.isTrue(batch.vertexCount > 0, "ROM batch has emitted vertices")
    Assert.isTrue(batch.indexCount > 0, "ROM batch has emitted indices")

    local numeric = arena.numeric
    local attrib = arena.attrib
    local indices = arena.indices
    local record = {
      materialIndex = batch.materialIndex,
      nodeIndex = batch.nodeIndex,
      shapeIndex = batch.shapeIndex,
      polygonAttrRaw = batch.polygonAttrRaw,
      transformMode = batch.transformMode,
      vertices = {},
      indices = {},
    }
    for offset = 0, batch.vertexCount - 1 do
      local vertex = numeric[batch.vertexOffset + offset]
      local bytes = attrib[batch.vertexOffset + offset]
      record.vertices[#record.vertices + 1] = {
        vertex.x,
        vertex.y,
        vertex.z,
        vertex.u,
        vertex.v,
        vertex.nx,
        vertex.ny,
        vertex.nz,
        bytes.r,
        bytes.g,
        bytes.b,
        bytes.a,
        bytes.colorSource,
      }
    end
    for offset = 0, batch.indexCount - 1 do
      local index = indices[batch.indexOffset + offset]
      Assert.isTrue(index < batch.vertexCount, "ROM batch indices remain local to the slice")
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
