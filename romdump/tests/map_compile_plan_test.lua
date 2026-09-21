-- Producer planning tests cover canonical prerequisites and aggregate maps.

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
  local romFs = MapRomFixture.build({ areaTypeRaw = 1 })
  local first = assert(MapCompilePlan.plan(romFs, indexFor(romFs), MapRomFixture.MAP_SYMBOL, "producer"))
  local second = assert(MapCompilePlan.plan(romFs, indexFor(romFs), MapRomFixture.MAP_SYMBOL, "producer"))
  Assert.equal(first.strategy, "canonical")
  Assert.equal(first.central.index, second.central.index)
  Assert.equal(#first.cellPlans, 1)
  Assert.equal(first.cellPlans[1].expectedMarker, second.cellPlans[1].expectedMarker)
  Assert.equal(first.expectedMarker, second.expectedMarker)
end

function T.rejects_a_missing_canonical_cell()
  local romFs = MapRomFixture.build({ areaTypeRaw = 1 })
  local empty = { schema = FieldCellCache.INDEX_SCHEMA, matrices = {} }
  local plan, err = MapCompilePlan.plan(romFs, empty, MapRomFixture.MAP_SYMBOL, "producer")
  Assert.isNil(plan)
  Assert.equal(assert(err).code, "MAP_CELL_PREREQUISITE_MISSING")
end

function T.indoor_maps_plan_as_aggregate_without_canonical_cells()
  local romFs = MapRomFixture.build({})
  local empty = { schema = FieldCellCache.INDEX_SCHEMA, matrices = {} }
  local plan, err = MapCompilePlan.plan(romFs, empty, MapRomFixture.MAP_SYMBOL, "producer")

  Assert.isNil(err, "indoor planning must not require canonical field cells")
  plan = assert(plan)
  Assert.equal(plan.strategy, "aggregate")
  Assert.equal(plan.resolved.map.id, MapRomFixture.MAP_ID)
  Assert.deepEqual(plan.cellPlans, {})
  Assert.isNil(plan.expectedMarker)
  Assert.equal(plan.romSha1, "rom-sha")
  Assert.equal(plan.producerFingerprint, "producer")
  Assert.equal(plan.jobIdentity, "map:" .. MapRomFixture.MAP_ID)
end

-- Roster enumeration lists canonical cell keys without leaf content
-- planning: the topology-only projection returns the same sorted unique
-- matrixMemberId:index keys as full planning while never invoking leaf
-- cell planning, hashing, or compilation. Aggregate maps carry no keys.
function T.roster_enumeration_lists_cell_keys_without_leaf_content_planning()
  Assert.equal(
    type(MapCompilePlan.cellKeys),
    "function",
    "roster enumeration must use the topology-only cell projection"
  )
  local FieldCellCompiler = require("romdump.src.digest.field.FieldCellCompiler")
  local romFs = MapRomFixture.build({ areaTypeRaw = 1 })
  local index = indexFor(romFs)
  local realPlanCell = FieldCellCompiler.planCell
  local leafCalls = 0
  FieldCellCompiler.planCell = function(...)
    leafCalls = leafCalls + 1
    return realPlanCell(...)
  end
  local ok, keys = pcall(MapCompilePlan.cellKeys, romFs, index, MapRomFixture.MAP_SYMBOL)
  FieldCellCompiler.planCell = realPlanCell
  if not ok then
    error(keys, 0)
  end
  Assert.equal(leafCalls, 0, "roster enumeration performs no leaf content planning")
  Assert.equal(type(keys), "table", "roster enumeration returns the key list")
  local full = assert(MapCompilePlan.plan(romFs, index, MapRomFixture.MAP_SYMBOL, "producer"))
  local expected = {}
  local seen = {}
  for _, cellPlan in ipairs(full.cellPlans) do
    local key = cellPlan.descriptor.matrixMemberId .. ":" .. cellPlan.descriptor.index
    if not seen[key] then
      seen[key] = true
      expected[#expected + 1] = key
    end
  end
  table.sort(expected)
  Assert.deepEqual(keys, expected, "topology keys match full planning keys")
  local indoorFs = MapRomFixture.build({})
  local indoorKeys = assert(MapCompilePlan.cellKeys(indoorFs, indexFor(indoorFs), MapRomFixture.MAP_SYMBOL))
  Assert.deepEqual(indoorKeys, {}, "an aggregate map carries no canonical cell keys")
end

return { tests = T }
