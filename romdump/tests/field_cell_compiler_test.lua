-- Field-cell compilation must source terrain-animation selection from the
-- cell's decoded area-data record before compiling the terrain chunk. The
-- compiled cell carries the runtime texture-SRT clip while its persisted
-- dependency record stays limited to marker and descriptor identity.

local AnimationFixture = require("tests.support.AnimationFixture")
local Assert = require("tests.support.Assert")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local FieldCellCompiler = require("romdump.src.digest.field.FieldCellCompiler")
local MapRomFixture = require("tests.support.MapRomFixture")

local T = {}

local function descriptor()
  return {
    matrixMemberId = MapRomFixture.MATRIX_MEMBER_ID,
    index = 0,
    x = 0,
    z = 0,
    mapHeaderId = MapRomFixture.MAP_ID,
    altitude = 0,
    landDataMemberId = MapRomFixture.LAND_DATA_MEMBER_ID,
    areaDataMemberId = MapRomFixture.AREA_DATA_MEMBER_ID,
    file = FieldCellCache.cellPath(MapRomFixture.MATRIX_MEMBER_ID, 0),
  }
end

local function descriptorIdentity()
  return {
    matrixMemberId = MapRomFixture.MATRIX_MEMBER_ID,
    index = 0,
    x = 0,
    z = 0,
    mapHeaderId = MapRomFixture.MAP_ID,
    altitude = 0,
    landDataMemberId = MapRomFixture.LAND_DATA_MEMBER_ID,
    areaDataMemberId = MapRomFixture.AREA_DATA_MEMBER_ID,
  }
end

local function checkIdentityOnlyDependencies(compiled)
  local dependencies = assert(compiled.cell.dependencies, "the compiled cell carries a dependency record")
  Assert.isNil(dependencies.terrainAnimation, "the field-cell dependency record carries no terrain provenance")
  Assert.equal(
    dependencies.marker,
    compiled.cell.cellMarker,
    "the dependency record marker matches the published cell marker"
  )
  Assert.notNil(dependencies.dependencyHash, "the dependency record carries its descriptor hash")
  Assert.deepEqual(dependencies.descriptor, descriptorIdentity(), "the dependency record keeps descriptor identity")
  Assert.equal(dependencies.mapHeaderId, MapRomFixture.MAP_ID, "the dependency record keeps the map identity")
  Assert.equal(
    dependencies.landDataMemberId,
    MapRomFixture.LAND_DATA_MEMBER_ID,
    "the dependency record keeps the land identity"
  )
  Assert.equal(
    dependencies.areaDataMemberId,
    MapRomFixture.AREA_DATA_MEMBER_ID,
    "the dependency record keeps the area identity"
  )
end

function T.compiling_a_field_cell_reads_dynamic_texture_type_from_area_data()
  local romFs = MapRomFixture.build()
  local compiled = FieldCellCompiler.compileCell(romFs, descriptor(), {})
  Assert.notNil(compiled.cell)
  checkIdentityOnlyDependencies(compiled)
  Assert.notNil(compiled.cell.terrainAnimations, "the compiled cell carries its runtime animation block")
  Assert.equal(
    compiled.cell.terrainAnimations.textureSrt,
    false,
    "an area with no texture-coordinate selection publishes the explicit empty runtime clip"
  )
end

function T.a_selected_area_clip_reaches_the_cell_without_source_provenance()
  local srtBytes = AnimationFixture.srtWater()
  local romFs = MapRomFixture.build({
    dynamicTextureType = 0,
    fieldAreaTextureSrt = { [0] = srtBytes },
  })
  local compiled = FieldCellCompiler.compileCell(romFs, descriptor(), {})
  checkIdentityOnlyDependencies(compiled)
  local clip = compiled.cell.terrainAnimations.textureSrt
  Assert.isTrue(type(clip) == "table", "a selected area animation compiles into the runtime cell payload")
  ---@cast clip table
  Assert.equal(clip.name, "en_sp1", "the runtime clip keeps the selected animation identity")
  Assert.equal(clip.id, "en_sp1", "the runtime clip id matches the selected animation")
  Assert.equal(clip.kind, "texsrt", "the runtime clip keeps its texture-SRT kind")
end

return { tests = T }
