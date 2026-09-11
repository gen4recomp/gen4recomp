-- Coverage tests use CPU-only cell runtimes and count ownership transitions.

local Assert = require("tests.support.Assert")
local FieldCoverage = require("libs.hgss.src.world.FieldCoverage")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local CollisionFixture = require("tests.support.CollisionFixture")

local T = {}

---@class PhysicalProbeCoverage
---@field probe fun(self: PhysicalProbeCoverage, fieldX: integer, fieldZ: integer, context: PhysicalProbeContext): table?

local function makeIndex(width, height)
  width, height = width or 5, height or 3
  local cells = {}
  for z = 0, height - 1 do
    for x = 0, width - 1 do
      local index = z * width + x
      cells[#cells + 1] = {
        matrixMemberId = 1,
        index = index,
        x = x,
        z = z,
        origin = { x = x * 32, y = ((x + z) % 2) * 0.5, z = z * 32 },
        mapHeaderId = 60,
        altitude = (x + z) % 2,
        landDataMemberId = 1,
        areaDataMemberId = 1,
        file = "cell/" .. index,
      }
    end
  end
  return {
    schema = "g4-field-cell-index-v2",
    matrices = { { matrixMemberId = 1, width = width, height = height, cells = cells } },
  }
end

local function runtimeFactory(releases)
  return function(descriptor)
    local plates = {
      {
        id = 0,
        minX = 0,
        maxX = 32,
        minZ = 0,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = descriptor.altitude * 0.5,
      },
    }
    return {
      key = string.format("%d:%d", descriptor.x, descriptor.z),
      x = descriptor.x,
      z = descriptor.z,
      altitude = descriptor.altitude,
      collision = {
        containsLocal = function(_, x, z)
          return x >= 0 and x < 32 and z >= 0 and z < 32
        end,
        isBlockedLocal = function()
          return false
        end,
        getLocal = function()
          return { blocked = false }
        end,
      },
      terrain = { plates = plates, artifact = { source = { bdhcSha1 = descriptor.file } } },
      release = function()
        releases[descriptor.x .. ":" .. descriptor.z] = (releases[descriptor.x .. ":" .. descriptor.z] or 0) + 1
      end,
    }
  end
end

local function stagedPresentationFactory(taskLogRef)
  return function(runtime)
    local task = {
      progress = 0,
      required = 3,
      advances = 0,
      finishCalls = 0,
      takeResultCalls = 0,
      releaseCalls = 0,
      state = "active",
    }
    taskLogRef.current[#taskLogRef.current + 1] = task
    function task:advance(workUnits)
      Assert.isTrue(workUnits >= 0 and workUnits % 1 == 0, "presentation work budget must be integral")
      local consumed = math.min(workUnits, self.required - self.progress)
      self.progress = self.progress + consumed
      self.advances = self.advances + consumed
      return consumed
    end
    function task:isReady()
      return self.progress == self.required
    end
    function task:takeResult()
      Assert.isTrue(self:isReady(), "presentation result requires a completed task")
      Assert.equal(self.state, "active", "presentation result transfers ownership once")
      self.takeResultCalls = self.takeResultCalls + 1
      self.state = "transferred"
      return {
        cellKey = runtime.key,
        release = function()
          task.presentationReleaseCalls = (task.presentationReleaseCalls or 0) + 1
        end,
      }
    end
    function task:finish()
      self.finishCalls = self.finishCalls + 1
      self.progress = self.required
      return self:takeResult()
    end
    function task:release()
      if self.state == "active" then
        self.releaseCalls = self.releaseCalls + 1
        self.state = "released"
      end
    end
    return task
  end
end

local function pendingHaloCoverage()
  local taskLogRef = { current = {} }
  local releases = {}
  local coverage = FieldCoverage.new({
    matrixMemberId = 1,
    index = makeIndex(5, 5),
    anchorX = 2,
    anchorZ = 2,
    loadCell = function(descriptor)
      return runtimeFactory(releases)(descriptor)
    end,
    presentationTaskFactory = stagedPresentationFactory(taskLogRef),
  })
  taskLogRef.current = {}
  coverage:queuePrefetch(2, 2)
  coverage:updatePrefetch(1)
  coverage:updatePrefetch(1)
  local pending = assert(coverage.pendingPrefetch)
  local task = assert(taskLogRef.current[1])
  Assert.equal(pending.cellKey, "0:0")
  Assert.equal(pending.presentationTask, task)
  Assert.isFalse(task:isReady())
  return coverage, taskLogRef, pending, task, releases
end

local function countTaskReferences(taskLog, target)
  local count = 0
  for _, task in ipairs(taskLog) do
    if task == target then
      count = count + 1
    end
  end
  return count
end

local function cacheCoverage(loads)
  local cells = {}
  local cellFiles = {}
  local terrainFiles = {}
  local collision = CollisionFixture.asset(32, 32)
  for z = 0, 2 do
    for x = 0, 2 do
      local index = z * 3 + x
      local cellPath = FieldCellCache.cellPath(1, index)
      local collisionPath = FieldCellCache.collisionPath(1, index)
      local terrainPath = FieldCellCache.terrainPath(1, index)
      local cell = {
        schema = FieldCellCache.CELL_SCHEMA,
        matrixMemberId = 1,
        index = index,
        x = x,
        z = z,
        mapHeaderId = 60,
        altitude = 0,
        origin = { x = x * 32, y = 0, z = z * 32 },
        landDataMemberId = 1,
        areaDataMemberId = 1,
        file = cellPath,
        collision = { file = collisionPath },
        terrain = { schema = "g4-terrain-surfaces-v1", file = terrainPath },
        batches = {},
        materials = {},
        buildingInstances = {},
        terrainAnimations = { textureSrt = false },
      }
      cells[#cells + 1] = cell
      cellFiles[cellPath] = cell
      terrainFiles[terrainPath] = {
        schema = "g4-terrain-surfaces-v1",
        source = { bdhcSha1 = "cache-" .. index },
        plates = {},
      }
    end
  end
  local index = {
    schema = FieldCellCache.INDEX_SCHEMA,
    matrices = { { matrixMemberId = 1, width = 3, height = 3, cells = cells } },
  }
  return FieldCoverage.new({
    matrixMemberId = 1,
    cacheFs = {
      loadLua = function(_, path)
        if path == FieldCellCache.indexPath() then
          return index
        end
        if cellFiles[path] then
          loads.count = loads.count + 1
          return cellFiles[path]
        end
        return terrainFiles[path]
      end,
      read = function()
        return collision
      end,
    },
    anchorX = 1,
    anchorZ = 1,
  })
end

local function identityCoverage(sourceHash, changedCellKey, reverse, releaseCounter)
  local cells = {}
  for z = 0, 2 do
    for x = 0, 2 do
      local cellKey = string.format("%d:%d", x, z)
      cells[#cells + 1] = {
        matrixMemberId = 1,
        index = z * 3 + x,
        x = x,
        z = z,
        origin = { x = x * 32, y = cellKey == changedCellKey and 0.5 or 0, z = z * 32 },
        terrain = { file = "data/generated/field/cells/shared/terrain.lua" },
      }
    end
  end
  if reverse then
    for index = 1, math.floor(#cells / 2) do
      local other = #cells - index + 1
      cells[index], cells[other] = cells[other], cells[index]
    end
  end
  return FieldCoverage.new({
    matrixMemberId = 1,
    index = {
      schema = "g4-field-cell-index-v2",
      matrices = { { matrixMemberId = 1, width = 3, height = 3, cells = cells } },
    },
    anchorX = 1,
    anchorZ = 1,
    loadCell = function(descriptor)
      return {
        key = string.format("%d:%d", descriptor.x, descriptor.z),
        x = descriptor.x,
        z = descriptor.z,
        origin = descriptor.origin,
        descriptor = descriptor,
        collision = {
          containsLocal = function()
            return true
          end,
        },
        terrain = TerrainSurface.new({
          source = { bdhcSha1 = sourceHash },
          plates = {},
        }),
        release = function()
          if releaseCounter then
            releaseCounter.count = releaseCounter.count + 1
          end
        end,
      }
    end,
  })
end

function T.identity_rejects_missing_source_hash_and_releases_staged_cells()
  local releaseCounter = { count = 0 }
  local err = Assert.throws(function()
    identityCoverage(nil, nil, nil, releaseCounter)
  end)
  Assert.isTrue(tostring(err):find("bdhcSha1", 1, true) ~= nil)
  Assert.equal(releaseCounter.count, 9, "failed identity construction releases staged cells")
end

function T.identity_tracks_terrain_content_and_cell_placement_deterministically()
  local baseline = identityCoverage("bdhc-a")
  local baselineHash = baseline:status().terrainDependencyHash
  Assert.equal(baselineHash, baseline:_dependencyIdentity())

  local changedContent = identityCoverage("bdhc-b")
  Assert.isFalse(baselineHash == changedContent:status().terrainDependencyHash)

  local changedOrigin = identityCoverage("bdhc-a", "1:1")
  Assert.isFalse(baselineHash == changedOrigin:status().terrainDependencyHash)

  local reordered = identityCoverage("bdhc-a", nil, true)
  Assert.equal(baselineHash, reordered:status().terrainDependencyHash)
  Assert.isTrue(baselineHash:find("g4%-coverage%-v2") ~= nil)

  baseline:release()
  changedContent:release()
  changedOrigin:release()
  reordered:release()
end

function T.recenters_reusing_overlap_and_releases_departures()
  local releases = {}
  local coverage = FieldCoverage.new({
    matrixMemberId = 1,
    index = makeIndex(),
    anchorX = 1,
    anchorZ = 1,
    loadCell = runtimeFactory(releases),
  })
  Assert.equal(coverage:status().residentCount, 9)
  coverage:recenter(2, 1)
  local status = coverage:status()
  Assert.equal(status.residentCount, 9)
  Assert.isNil(releases["0:0"], "overlap cells are demoted into the ready halo")
  Assert.isNil(releases["0:1"], "overlap cells are demoted into the ready halo")
  Assert.isNil(releases["0:2"], "overlap cells are demoted into the ready halo")
  coverage:recenter(4, 1)
  Assert.equal(releases["0:0"], 1, "cells release after leaving the 5x5 footprint")
  Assert.equal(releases["0:1"], 1, "cells release after leaving the 5x5 footprint")
  Assert.equal(releases["0:2"], 1, "cells release after leaving the 5x5 footprint")
  coverage:release()
  Assert.equal(releases["1:1"], 1)
end

function T.failed_acquisition_keeps_active_anchor()
  local fail = false
  local coverage = FieldCoverage.new({
    matrixMemberId = 1,
    index = makeIndex(),
    anchorX = 1,
    anchorZ = 1,
    loadCell = function(descriptor)
      if fail and descriptor.x == 3 then
        error("injected acquisition failure")
      end
      return runtimeFactory({})(descriptor)
    end,
  })
  fail = true
  Assert.throws(function()
    coverage:recenter(3, 1)
  end)
  Assert.equal(coverage:status().anchorX, 1)
  Assert.equal(coverage:status().anchorZ, 1)
end

function T.failed_runtime_normalization_releases_acquired_cell()
  local releases = 0
  Assert.throws(function()
    FieldCoverage.new({
      matrixMemberId = 1,
      index = makeIndex(),
      anchorX = 1,
      anchorZ = 1,
      loadCell = function(descriptor)
        return {
          key = string.format("%d:%d", descriptor.x, descriptor.z),
          origin = { x = descriptor.origin.x, y = descriptor.origin.y },
          release = function()
            releases = releases + 1
          end,
        }
      end,
    })
  end)
  Assert.equal(releases, 1, "normalization failure releases the acquired cell")
end

function T.constructor_requires_both_index_and_cell_sources_before_acquisition()
  local explicitLoads = { count = 0 }
  local explicitCoverage = FieldCoverage.new({
    matrixMemberId = 1,
    index = makeIndex(),
    anchorX = 1,
    anchorZ = 1,
    loadCell = function(descriptor)
      explicitLoads.count = explicitLoads.count + 1
      return runtimeFactory({})(descriptor)
    end,
  })
  Assert.equal(explicitCoverage:status().residentCount, 9)
  Assert.equal(explicitLoads.count, 9)
  explicitCoverage:release()

  local cacheLoads = { count = 0 }
  local cacheCoverageInstance = cacheCoverage(cacheLoads)
  Assert.equal(cacheCoverageInstance:status().residentCount, 9)
  Assert.equal(cacheLoads.count, 9)
  cacheCoverageInstance:release()

  local indexOnlyError = Assert.throws(function()
    FieldCoverage.new({
      matrixMemberId = 1,
      index = makeIndex(),
      anchorX = 1,
      anchorZ = 1,
    })
  end)
  Assert.isTrue(tostring(indexOnlyError):find("field coverage requires loadCell or cacheFs", 1, true) ~= nil)

  local loadCellOnlyLoads = { count = 0 }
  local loadCellOnlyError = Assert.throws(function()
    FieldCoverage.new({
      matrixMemberId = 1,
      anchorX = 1,
      anchorZ = 1,
      loadCell = function(descriptor)
        loadCellOnlyLoads.count = loadCellOnlyLoads.count + 1
        return runtimeFactory({})(descriptor)
      end,
    })
  end)
  Assert.isTrue(tostring(loadCellOnlyError):find("field coverage requires index or cacheFs", 1, true) ~= nil)
  Assert.equal(loadCellOnlyLoads.count, 0)
end

local function projectionCoverage()
  local cells = {}
  local index = 0
  for z = -1, 1 do
    for x = -1, 1 do
      cells[#cells + 1] = {
        matrixMemberId = 1,
        index = index,
        x = x,
        z = z,
        origin = { x = x * 32, y = 0, z = z * 32 },
        terrain = { file = "data/generated/field/cells/projection/terrain.lua" },
      }
      index = index + 1
    end
  end
  return FieldCoverage.new({
    matrixMemberId = 1,
    index = {
      schema = "g4-field-cell-index-v2",
      matrices = { { matrixMemberId = 1, width = 3, height = 3, cells = cells } },
    },
    anchorX = 0,
    anchorZ = 0,
    loadCell = function(descriptor)
      return {
        key = string.format("%d:%d", descriptor.x, descriptor.z),
        x = descriptor.x,
        z = descriptor.z,
        origin = descriptor.origin,
        collision = {
          containsLocal = function()
            return true
          end,
        },
        terrain = TerrainSurface.new({
          source = { bdhcSha1 = "projection-" .. descriptor.x .. ":" .. descriptor.z },
          plates = {
            {
              id = 7,
              minX = 0,
              minZ = 0,
              maxX = 32,
              maxZ = 32,
              normal = { x = 0, y = 1, z = 0 },
              distance = 3,
            },
          },
        }),
        release = function() end,
      }
    end,
  })
end

function T.projects_tiles_in_the_centered_render_frame()
  local coverage = projectionCoverage()
  local ok, result = pcall(function()
    return coverage:project(2, 5, "0:0", 7)
  end)
  coverage:release()
  Assert.isTrue(ok, tostring(result))
  local projection = assert(result)

  Assert.equal(projection.localX, 2)
  Assert.equal(projection.localZ, 5)
  Assert.equal(projection.worldX, -13.5)
  Assert.equal(projection.worldZ, -10.5)
  Assert.equal(projection.worldY, 3)
  Assert.equal(projection.cellKey, "0:0")
  Assert.equal(projection.sourceSurfaceId, 7)
end

local function adjacentIndex(reverse)
  local destinationPlates = {
    {
      id = 10,
      minX = 0,
      minZ = 0,
      maxX = 32,
      maxZ = 32,
      normal = { x = 0, y = 1, z = 0 },
      distance = 2,
    },
    {
      id = 11,
      minX = 0,
      minZ = 0,
      maxX = 32,
      maxZ = 32,
      normal = { x = 0, y = 1, z = 0 },
      distance = 0,
    },
  }
  if reverse then
    destinationPlates[1], destinationPlates[2] = destinationPlates[2], destinationPlates[1]
  end
  return {
    schema = "g4-field-cell-index-v2",
    matrices = {
      {
        matrixMemberId = 1,
        width = 2,
        height = 1,
        cells = {
          { matrixMemberId = 1, index = 0, x = 0, z = 0, origin = { x = 0, y = 0, z = 0 } },
          { matrixMemberId = 1, index = 1, x = 1, z = 0, origin = { x = 32, y = 0, z = 0 } },
        },
      },
    },
  },
    destinationPlates
end

local function adjacentCoverage(reverse, plates)
  local index, destinationPlates = adjacentIndex(reverse)
  destinationPlates = plates or destinationPlates
  return FieldCoverage.new({
    matrixMemberId = 1,
    index = index,
    anchorX = 0,
    anchorZ = 0,
    loadCell = function(descriptor)
      local cellPlates = descriptor.x == 1 and destinationPlates
        or {
          {
            id = 0,
            minX = 0,
            minZ = 0,
            maxX = 32,
            maxZ = 32,
            normal = { x = 0, y = 1, z = 0 },
            distance = 0,
          },
        }
      return {
        key = string.format("%d:%d", descriptor.x, descriptor.z),
        x = descriptor.x,
        z = descriptor.z,
        origin = descriptor.origin,
        collision = {
          containsLocal = function(_, x, z)
            return x >= 0 and x < 32 and z >= 0 and z < 32
          end,
          getLocal = function()
            return { blocked = false }
          end,
        },
        terrain = TerrainSurface.new({
          source = { bdhcSha1 = "cell-" .. descriptor.x .. ":" .. descriptor.z },
          plates = cellPlates,
        }),
        release = function() end,
      }
    end,
  })
end

function T.destination_resolution_uses_continuity_not_source_order()
  local function resolve(reverse)
    local coverage = adjacentCoverage(reverse)
    local probeCoverage = coverage --[[@as PhysicalProbeCoverage]]
    local result = probeCoverage:probe(32, 0, {
      currentCellKey = "0:0",
      currentSourceSurfaceId = 0,
      currentY = 0,
      fromFieldX = 31,
      fromFieldZ = 0,
    })
    coverage:release()
    return result
  end

  local forward = assert(resolve(false))
  local reversed = assert(resolve(true))
  Assert.equal(forward.sourceSurfaceId, 11)
  Assert.equal(reversed.sourceSurfaceId, 11)
  Assert.equal(forward.worldY, 0)
  Assert.equal(reversed.worldY, 0)

  local blocked = adjacentCoverage(false, {
    {
      id = 12,
      minX = 0,
      minZ = 0,
      maxX = 32,
      maxZ = 32,
      normal = { x = 0, y = 1, z = 0 },
      distance = 2,
    },
  })
  local probeCoverage = blocked --[[@as PhysicalProbeCoverage]]
  Assert.isNil(probeCoverage:probe(32, 0, {
    currentCellKey = "0:0",
    currentSourceSurfaceId = 0,
    currentY = 0,
    fromFieldX = 31,
    fromFieldZ = 0,
  }))
  blocked:release()
end

local function temporaryProbeCoverage(destinationX, destinationDistance, releases, loadErrorX)
  local cells = {}
  for x = 0, destinationX do
    cells[#cells + 1] = {
      matrixMemberId = 1,
      index = x,
      x = x,
      z = 0,
      origin = { x = x * 32, y = 0, z = 0 },
    }
  end
  return FieldCoverage.new({
    matrixMemberId = 1,
    index = {
      schema = "g4-field-cell-index-v2",
      matrices = { { matrixMemberId = 1, width = destinationX + 1, height = 1, cells = cells } },
    },
    anchorX = 0,
    anchorZ = 0,
    loadCell = function(descriptor)
      if descriptor.x == loadErrorX then
        error("destination cell failure", 0)
      end
      local cellKey = string.format("%d:%d", descriptor.x, descriptor.z)
      return {
        key = cellKey,
        x = descriptor.x,
        z = descriptor.z,
        origin = descriptor.origin,
        collision = {
          containsLocal = function(_, x, z)
            return x >= 0 and x < 32 and z >= 0 and z < 32
          end,
          getLocal = function()
            return { blocked = false }
          end,
        },
        terrain = TerrainSurface.new({
          source = { bdhcSha1 = "cell-" .. cellKey },
          plates = {
            {
              id = 0,
              minX = 0,
              minZ = 0,
              maxX = 32,
              maxZ = 32,
              normal = { x = 0, y = 1, z = 0 },
              distance = descriptor.x == destinationX and destinationDistance or 0,
            },
          },
        }),
        release = function()
          releases[cellKey] = (releases[cellKey] or 0) + 1
        end,
      }
    end,
  })
end

function T.temporary_probe_releases_its_cell_on_success_and_rejection()
  local releases = {}
  local coverage = temporaryProbeCoverage(2, 0, releases)
  local result = coverage:probe(64, 0, {
    currentCellKey = "1:0",
    currentSourceSurfaceId = 0,
    currentY = 0,
    fromFieldX = 63,
    fromFieldZ = 0,
  })
  Assert.equal(assert(result).sourceSurfaceId, 0)
  Assert.equal(releases["2:0"], 1)
  coverage:release()

  releases = {}
  coverage = temporaryProbeCoverage(2, 2, releases)
  Assert.isNil(coverage:probe(64, 0, {
    currentCellKey = "1:0",
    currentSourceSurfaceId = 0,
    currentY = 0,
    fromFieldX = 63,
    fromFieldZ = 0,
  }))
  Assert.equal(releases["2:0"], 1)
  coverage:release()

  releases = {}
  coverage = temporaryProbeCoverage(3, 0, releases)
  result = coverage:probe(96, 0, {
    currentCellKey = "2:0",
    currentSourceSurfaceId = 0,
    currentY = 0,
    fromFieldX = 95,
    fromFieldZ = 0,
  })
  Assert.equal(assert(result).sourceSurfaceId, 0)
  Assert.equal(releases["2:0"], 1)
  Assert.equal(releases["3:0"], 1)
  coverage:release()

  releases = {}
  coverage = temporaryProbeCoverage(2, 0, releases)
  result = coverage:probe(65, 0, {
    currentCellKey = "2:0",
    currentSourceSurfaceId = 0,
    currentY = 0,
    fromFieldX = 64,
    fromFieldZ = 0,
  })
  Assert.equal(assert(result).sourceSurfaceId, 0)
  Assert.equal(releases["2:0"], 1)
  coverage:release()
end

function T.failed_probe_preserves_the_original_cell_load_error()
  local coverage = temporaryProbeCoverage(2, 0, {}, 2)

  local ok, err = pcall(function()
    coverage:probe(64, 0, {
      currentCellKey = "1:0",
      currentSourceSurfaceId = 0,
      currentY = 0,
      fromFieldX = 63,
      fromFieldZ = 0,
    })
  end)

  Assert.isFalse(ok)
  Assert.equal(tostring(err), "destination cell failure")
  coverage:release()
end

function T.ready_halo_cells_promote_without_boundary_acquisition()
  local loads = { count = 0 }
  local coverage = FieldCoverage.new({
    matrixMemberId = 1,
    index = makeIndex(),
    anchorX = 1,
    anchorZ = 1,
    loadCell = function(descriptor)
      loads.count = loads.count + 1
      return runtimeFactory({})(descriptor)
    end,
  })

  local initialLoads = loads.count
  Assert.isTrue(type(coverage.queuePrefetch) == "function", "coverage must expose halo prefetching")
  Assert.isTrue(type(coverage.updatePrefetch) == "function", "coverage must expose bounded prefetch work")
  coverage:queuePrefetch(1, 1)
  local queued = coverage:status().queuedPrefetchCount
  local availableHalo = #coverage:prefetchDescriptors(1, 1) - #coverage:descriptorsFor(1, 1)
  Assert.equal(queued, availableHalo)
  Assert.equal(queued, 3, "the available 5x3 matrix has three cells in the one-cell halo")

  for _ = 1, queued do
    coverage:updatePrefetch(1)
  end
  Assert.equal(loads.count, initialLoads + queued)
  Assert.equal(coverage:status().readyPrefetchCount, queued)

  coverage:recenter(2, 1)
  local status = coverage:status()
  Assert.equal(loads.count, initialLoads + queued, "a ready one-cell promotion must not load a physical cell")
  Assert.equal(status.synchronousPhysicalFallbackLoads, 0)
  Assert.equal(status.committedCount, 9)
  Assert.equal(status.readyPrefetchCount, 3)
  Assert.equal(status.queuedPrefetchCount, 3)
  coverage:release()
end

function T.partial_prefetch_is_not_ready_until_presentation_finishes_and_promotes_without_acquisition()
  local loads = { count = 0 }
  local taskLogRef = { current = {} }
  local coverage = FieldCoverage.new({
    matrixMemberId = 1,
    index = makeIndex(),
    anchorX = 1,
    anchorZ = 1,
    loadCell = function(descriptor)
      loads.count = loads.count + 1
      return runtimeFactory({})(descriptor)
    end,
    presentationTaskFactory = stagedPresentationFactory(taskLogRef),
  })
  taskLogRef.current = {}
  local initialLoads = loads.count
  coverage:queuePrefetch(1, 1)
  local queued = coverage:status().queuedPrefetchCount
  Assert.equal(queued, 3)

  coverage:updatePrefetch(1)
  Assert.equal(coverage:status().readyPrefetchCount, 0, "partial physical work must not be published ready")

  local guard = 0
  while coverage:status().readyPrefetchCount < queued do
    local consumed = coverage:updatePrefetch(1)
    Assert.isTrue(consumed <= 1, "physical prefetch must consume at most one work unit per update")
    guard = guard + 1
    Assert.isTrue(guard <= 64, "staged physical prefetch did not complete its queued cells")
  end
  Assert.equal(#taskLogRef.current, queued, "each queued cell must own one staged presentation task")
  for _, task in ipairs(taskLogRef.current) do
    Assert.equal(task.takeResultCalls, 1, "a ready cell transfers its presentation exactly once")
  end

  local loadsBeforePromotion = loads.count
  local taskCountBeforePromotion = #taskLogRef.current
  coverage:recenter(2, 1)
  Assert.equal(loads.count, loadsBeforePromotion, "ready promotion must not reacquire cell artifacts")
  Assert.equal(#taskLogRef.current, taskCountBeforePromotion, "ready promotion must not create presentation work")
  Assert.equal(coverage:status().committedCount, 9)
  coverage:release()
  for _, task in ipairs(taskLogRef.current) do
    Assert.equal(task.presentationReleaseCalls, 1, "cell release must release transferred presentation once")
  end
  Assert.equal(loads.count, initialLoads + queued)
end

function T.halo_pending_work_survives_recentering_without_synchronous_progress()
  local coverage, taskLogRef, pending, task = pendingHaloCoverage()
  local beforeAdvances = task.advances
  local beforeFinishCalls = task.finishCalls
  local beforeTakeResultCalls = task.takeResultCalls
  local beforeFallbacks = coverage:status().synchronousPhysicalFallbackLoads

  coverage:recenter(1, 2)

  local status = coverage:status()
  Assert.equal(coverage.pendingPrefetch, pending, "the halo task remains owned by coverage")
  Assert.equal(pending.presentationTask, task, "the same presentation task remains pending")
  Assert.equal(status.pendingPrefetchCellKey, "0:0")
  Assert.equal(task.advances, beforeAdvances, "recentering does not advance halo-only work")
  Assert.equal(task.finishCalls, beforeFinishCalls, "recentering does not finish halo-only work")
  Assert.equal(task.takeResultCalls, beforeTakeResultCalls, "recentering does not transfer a partial result")
  Assert.equal(
    status.synchronousPhysicalFallbackLoads,
    beforeFallbacks + 3,
    "recenter finishes the three newly committed cells"
  )
  Assert.isNil(coverage.prefetched["0:0"], "partial halo work is not ready-prefetched")
  Assert.equal(#taskLogRef.current, 4, "recenter accounts for three new committed tasks")
  Assert.equal(countTaskReferences(taskLogRef.current, task), 1, "the retained task is not duplicated")
  coverage:release()
end

function T.retained_halo_work_resumes_with_bounded_updates_and_publishes_once()
  local coverage, taskLogRef, pending, task = pendingHaloCoverage()
  coverage:recenter(1, 2)
  local beforeAdvances = task.advances
  local guard = 0
  while coverage.pendingPrefetch do
    local consumed = coverage:updatePrefetch(1)
    Assert.isTrue(consumed <= 1, "prefetch must consume at most one work unit per update")
    Assert.equal(coverage.pendingPrefetch and coverage.pendingPrefetch.presentationTask or task, task)
    guard = guard + 1
    Assert.isTrue(guard <= 8, "retained halo work did not complete")
  end

  local status = coverage:status()
  Assert.equal(task.advances, beforeAdvances + 2, "the retained task resumes its remaining work")
  Assert.equal(task.finishCalls, 0, "bounded completion does not use synchronous finish")
  Assert.equal(task.takeResultCalls, 1, "the retained result transfers once")
  Assert.notNil(coverage.prefetched[pending.cellKey])
  Assert.equal(status.pendingPrefetchCellKey, nil)
  Assert.equal(#taskLogRef.current, 4, "completion accounts for three new committed tasks")
  Assert.equal(countTaskReferences(taskLogRef.current, task), 1, "the retained task is not duplicated")
  coverage:release()
  Assert.equal(task.presentationReleaseCalls, 1, "published presentation releases once")
end

function T.retained_pending_work_releases_once_when_coverage_is_released()
  local coverage, _, _, task, releases = pendingHaloCoverage()
  coverage:recenter(1, 2)
  coverage:release()
  Assert.equal(task.releaseCalls, 1, "releasing coverage cancels the pending task once")
  Assert.equal(releases["0:0"], 1, "releasing coverage releases the pending runtime once")
end

function T.pending_work_outside_the_footprint_is_cancelled_once()
  local coverage, _, _, task, releases = pendingHaloCoverage()
  coverage:recenter(4, 2)
  Assert.isNil(coverage.pendingPrefetch)
  Assert.equal(task.releaseCalls, 1, "leaving the footprint cancels the pending task once")
  Assert.equal(releases["0:0"], 1, "leaving the footprint releases the pending runtime once")
  coverage:release()
end

function T.recenter_finishes_the_existing_pending_cell_without_duplicate_acquisition()
  local loads = { count = 0 }
  local taskLogRef = { current = {} }
  local coverage = FieldCoverage.new({
    matrixMemberId = 1,
    index = makeIndex(4, 1),
    anchorX = 1,
    anchorZ = 0,
    loadCell = function(descriptor)
      loads.count = loads.count + 1
      return runtimeFactory({})(descriptor)
    end,
    presentationTaskFactory = stagedPresentationFactory(taskLogRef),
  })
  taskLogRef.current = {}
  coverage:queuePrefetch(1, 0)

  coverage:updatePrefetch(1)
  Assert.equal(coverage:status().readyPrefetchCount, 0, "the target cell must still be pending")
  local guard = 0
  while #taskLogRef.current == 0 do
    coverage:updatePrefetch(1)
    guard = guard + 1
    Assert.isTrue(guard <= 8, "prefetch did not start a staged presentation task")
  end
  local task = assert(taskLogRef.current[1])
  Assert.isFalse(task:isReady(), "the pending presentation must remain unfinished")
  local loadsBeforeFallback = loads.count

  coverage:recenter(2, 0)
  local status = coverage:status()
  Assert.equal(status.synchronousPhysicalFallbackLoads, 1, "outrunning prefetch counts one synchronous fallback")
  Assert.equal(status.committedCount, 3)
  Assert.equal(loads.count, loadsBeforeFallback, "fallback must finish the pending cell instead of reacquiring it")
  Assert.equal(#taskLogRef.current, 1, "fallback must not create a duplicate task")
  Assert.equal(task.finishCalls, 1, "fallback must finish the existing task synchronously")
  Assert.equal(task.takeResultCalls, 1, "fallback must transfer the existing task result once")
  coverage:release()
  Assert.equal(task.presentationReleaseCalls, 1, "fallback-owned presentation releases through the cell")
end

function T.failed_pending_fallback_clears_its_owner_after_task_failure()
  local releases = { count = 0 }
  local taskReleases = { count = 0 }
  local taskCount = 0
  local coverage = FieldCoverage.new({
    matrixMemberId = 1,
    index = makeIndex(4, 1),
    anchorX = 1,
    anchorZ = 0,
    loadCell = function(descriptor)
      return runtimeFactory(releases)(descriptor)
    end,
    presentationTaskFactory = function()
      taskCount = taskCount + 1
      if taskCount <= 3 then
        return {
          advance = function()
            return 0
          end,
          isReady = function()
            return true
          end,
          takeResult = function()
            return { release = function() end }
          end,
          finish = function()
            return { release = function() end }
          end,
          release = function() end,
        }
      end
      return {
        advance = function()
          return 1
        end,
        isReady = function()
          return false
        end,
        finish = function()
          error("staged presentation failed", 0)
        end,
        release = function()
          taskReleases.count = taskReleases.count + 1
        end,
      }
    end,
  })
  coverage:queuePrefetch(1, 0)
  coverage:updatePrefetch(1)

  local ok, err = pcall(function()
    coverage:recenter(2, 0)
  end)
  Assert.isFalse(ok)
  Assert.equal(tostring(err), "staged presentation failed")
  Assert.isNil(coverage.pendingPrefetch)
  Assert.equal(releases["3:0"], 1)
  Assert.equal(taskReleases.count, 1)
  coverage:release()
end

function T.recenter_ensures_all_required_cells_before_acquiring_any_runtime()
  local events = {}
  local coverage = FieldCoverage.new({
    matrixMemberId = 1,
    index = makeIndex(5, 5),
    anchorX = 2,
    anchorZ = 2,
    derivedAssets = {
      ensureCell = function(descriptor)
        events[#events + 1] = "ensure:" .. descriptor.x .. ":" .. descriptor.z
      end,
      requestCell = function()
        return false
      end,
    },
    loadCell = function(descriptor)
      events[#events + 1] = "load:" .. descriptor.x .. ":" .. descriptor.z
      return runtimeFactory({})(descriptor)
    end,
  })
  events = {}
  coverage:recenter(1, 2)

  local firstLoad
  for index, event in ipairs(events) do
    if event:sub(1, 5) == "load:" then
      firstLoad = index
      break
    end
  end
  Assert.equal(firstLoad, 4, "runtime acquisition starts only after all missing barriers")
  for index = 1, 3 do
    Assert.equal(events[index]:sub(1, 7), "ensure:", "every required cell is ensured before acquisition")
  end
  coverage:release()
end

return { metadata = { capabilities = {} }, tests = T }
