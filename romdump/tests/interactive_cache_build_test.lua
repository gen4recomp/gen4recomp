-- Interactive producer tests use cache readiness seams to verify deterministic
-- orchestration without opening a ROM or starting worker threads.

local Assert = require("tests.support.Assert")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local InteractiveCacheBuild = require("romdump.src.build.InteractiveCacheBuild")

local T = {}

function T.pending_maps_advance_in_map_id_order()
  local oldCellReady = FieldCellCache.isCellReady
  local oldMapReady = MapAssetCache.isReady
  local requests = {}
  local ready = {}
  local function plan(mapId)
    return {
      expectedMarker = "map-marker-" .. mapId,
      resolved = { map = { id = mapId } },
      cellPlans = { { descriptor = {}, expectedMarker = "cell-marker" } },
    }
  end

  FieldCellCache.isCellReady = function()
    return true
  end
  MapAssetCache.isReady = function(_, mapId)
    return ready[mapId] == true
  end
  local ok, err = pcall(function()
    local build = setmetatable({
      cacheFs = {},
      pendingMaps = {
        late = plan(1000000007),
        first = plan(2),
        middle = plan(1000000003),
      },
      pool = {
        request = function(_, job)
          requests[#requests + 1] = job.payload.mapId
          return "queued"
        end,
      },
    }, InteractiveCacheBuild)
    build:_advancePendingMaps()
  end)
  FieldCellCache.isCellReady = oldCellReady
  MapAssetCache.isReady = oldMapReady
  if not ok then
    error(err, 0)
  end
  Assert.deepEqual(requests, { 2, 1000000003, 1000000007 })
end

return { metadata = { capabilities = {} }, tests = T }
