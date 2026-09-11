-- ROM-backed producer regression: known physical field cells must compile
-- through the real field-cell and terrain-conformance path without exhausting
-- the geometry scratch allocator.

local Assert = require("tests.support.Assert")
local FieldCellCompiler = require("romdump.src.digest.field.FieldCellCompiler")
local GxDisplayList = require("libs.nds.src.gx.GxDisplayList")
local GxGeometryBuffer = require("libs.nds.src.gx.GxGeometryBuffer")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function descriptorFor(indexBundle, matrixMemberId)
  for _, matrix in ipairs(indexBundle.index.matrices) do
    if matrix.matrixMemberId == matrixMemberId then
      for _, descriptor in ipairs(matrix.cells) do
        if descriptor.index == 0 then
          return descriptor
        end
      end
    end
  end
  return nil
end

function T.known_physical_cells_compile_with_real_terrain_geometry(romFs)
  local indexBundle = assert(FieldCellCompiler.compileIndex(romFs))
  local scratch = {
    geometryArena = GxGeometryBuffer.new(),
    gxScratch = GxDisplayList.newScratch(),
    terrainScratch = {},
  }

  for _, matrixMemberId in ipairs({ 188, 283 }) do
    local descriptor = assert(descriptorFor(indexBundle, matrixMemberId), "known physical cell descriptor is indexed")
    local compiled = FieldCellCompiler.compileCell(romFs, descriptor, scratch)
    Assert.notNil(compiled.cell, "physical field cell compilation returns a cell")
    Assert.isTrue(#compiled.cell.batches > 0, "physical field cell contains terrain batches")
    Assert.isTrue(next(compiled.meshes) ~= nil, "physical field cell contains serialized mesh artifacts")
    Assert.isTrue(type(compiled.cell.collisionData) == "table", "physical field cell contains collision data")
    Assert.isTrue(type(compiled.cell.terrainData) == "table", "physical field cell contains terrain data")
  end
end

local suite = RomSuite.fromFacts(T)
suite.metadata.tags = { "producer", "terrain", "field-cell" }
return suite
