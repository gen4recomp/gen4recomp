-- Derives renderability, representative cells, and land members from a
-- canonical HGSS dump. Results are persisted with romdump's generated world;
-- no dump-derived resolution inventory is checked into the repository.

local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local MapCellSelector = require("romdump.src.digest.map.MapCellSelector")
local MapMatrix = require("romdump.src.digest.map.MapMatrix")

local MapAnalysis = {}

function MapAnalysis.analyzeRecord(record, matrix)
  local chosen, source, matchCount = MapCellSelector.choose(matrix, record)
  if not chosen then
    return {
      status = "excluded",
      reason = source,
      matchCount = matchCount,
    }
  end

  local landDataMemberId = matrix:cell(chosen.x, chosen.z).landDataMemberId
  if landDataMemberId == 0xFFFF then
    return {
      status = "excluded",
      reason = "no_land_data",
      matchCount = matchCount,
    }
  end
  return {
    status = "resolved",
    matchCount = matchCount,
    source = source,
    matrixX = chosen.x,
    matrixZ = chosen.z,
    matrixIndex = chosen.index,
    landDataMemberId = landDataMemberId,
  }
end

function MapAnalysis.analyze(romFs)
  assert(romFs and romFs.openNarc, "analyze requires a RomFs-shaped object")
  local narc = assert(romFs:openNarc("map_matrices"))
  local results = {}

  for record in MapCatalog.all() do
    local bytes = assert(narc:readMember(record.matrixMemberId))
    local matrix = assert(MapMatrix.decode(bytes, record.id))
    local result = MapAnalysis.analyzeRecord(record, matrix)
    result.id = record.id
    result.symbol = record.symbol
    result.mapCode = record.mapCode
    result.mapSection = record.mapSection
    result.mapSectionNativeId = assert(
      record.mapSectionNativeId,
      "HGSS map reference record " .. record.id .. " carries no native map-section identity"
    )
    result.followMode =
      assert(record.followMode, "HGSS map reference record " .. record.id .. " carries no source follow mode")
    result.matrixMemberId = record.matrixMemberId
    results[#results + 1] = result
  end
  return results
end

function MapAnalysis.lines(results)
  local lines = {}
  local counts = { resolved = 0, excluded = 0 }
  for _, result in ipairs(results) do
    counts[result.status] = counts[result.status] + 1
    if result.status == "resolved" then
      lines[#lines + 1] = string.format(
        "resolved\t%d\t%s\t%d\t%d\t%d\t%d\t%d\t%s\t%d",
        result.id,
        result.symbol,
        result.matrixMemberId,
        result.matrixX,
        result.matrixZ,
        result.matrixIndex,
        result.landDataMemberId,
        result.source,
        result.matchCount
      )
    else
      lines[#lines + 1] =
        string.format("%s\t%d\t%s\t%s\t%d", result.status, result.id, result.symbol, result.reason, result.matchCount)
    end
  end
  lines[#lines + 1] = string.format("summary\tresolved=%d\texcluded=%d", counts.resolved, counts.excluded)
  return lines
end

return MapAnalysis
