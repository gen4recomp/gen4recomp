-- Producer planning tests for canonical field-cell prerequisites.

local Assert = require("tests.support.Assert")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local MapCompilePlan = require("romdump.src.digest.map.MapCompilePlan")
local MapResolver = require("romdump.src.digest.map.MapResolver")
local MapRomFixture = require("tests.support.MapRomFixture")

local T = {}

local function indexFor(romFs)
  local resolved = assert(MapResolver.resolve(romFs, MapRomFixture.MAP_SYMBOL))
  return {
    schema = FieldCellCache.INDEX_SCHEMA,
    matrices = {
      {
        matrixMemberId = resolved.matrixMemberId,
        width = resolved.matrix.width,
        height = resolved.matrix.height,
        cells = {
          {
            matrixMemberId = resolved.matrixMemberId,
            index = resolved.matrixIndex,
            x = resolved.matrixX,
            z = resolved.matrixZ,
            mapHeaderId = MapRomFixture.MAP_ID,
            altitude = resolved.matrixAltitude,
            landDataMemberId = resolved.landDataMemberId,
            areaDataMemberId = resolved.areaDataMemberId,
            file = FieldCellCache.cellPath(resolved.matrixMemberId, resolved.matrixIndex),
          },
        },
      },
    },
  }
end

function T.plans_canonical_cells_in_stable_order()
  local romFs = MapRomFixture.build({})
  local first = assert(MapCompilePlan.plan(romFs, indexFor(romFs), MapRomFixture.MAP_SYMBOL, "producer"))
  local second = assert(MapCompilePlan.plan(romFs, indexFor(romFs), MapRomFixture.MAP_SYMBOL, "producer"))
  Assert.equal(first.central.index, second.central.index)
  Assert.equal(#first.cellPlans, 1)
  Assert.equal(first.cellPlans[1].expectedMarker, second.cellPlans[1].expectedMarker)
  Assert.equal(first.expectedMarker, second.expectedMarker)
end

function T.rejects_a_missing_canonical_cell()
  local romFs = MapRomFixture.build({})
  local empty = { schema = FieldCellCache.INDEX_SCHEMA, matrices = {} }
  local plan, err = MapCompilePlan.plan(romFs, empty, MapRomFixture.MAP_SYMBOL, "producer")
  Assert.isNil(plan)
  Assert.equal(assert(err).code, "MAP_CELL_PREREQUISITE_MISSING")
end

return { tests = T }
