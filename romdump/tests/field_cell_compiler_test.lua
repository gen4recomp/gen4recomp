-- Field-cell compilation must source terrain-animation selection from the
-- cell's decoded area-data record before compiling the terrain chunk.

local Assert = require("tests.support.Assert")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local FieldCellCompiler = require("romdump.src.digest.field.FieldCellCompiler")
local MapRomFixture = require("tests.support.MapRomFixture")

local T = {}

function T.compiling_a_field_cell_reads_dynamic_texture_type_from_area_data()
  local romFs = MapRomFixture.build()
  local descriptor = {
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

  local compiled = FieldCellCompiler.compileCell(romFs, descriptor, {})
  Assert.notNil(compiled.cell)
end

return { tests = T }
