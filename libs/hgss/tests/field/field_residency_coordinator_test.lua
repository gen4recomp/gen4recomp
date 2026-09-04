-- Field residency tests use counting owner doubles to observe logical map
-- preparation, promotion, eviction, and fallback ownership. Object-actor
-- construction, publication, and activation belong to FieldActorManager
-- alone, so the actor double here answers nothing but physical reprojection.

local Assert = require("tests.support.Assert")
local FieldAudioController = require("libs.hgss.src.audio.FieldAudioController")

local function coordinatorClass()
  local ok, loaded = pcall(require, "libs.hgss.src.world.FieldResidencyCoordinator")
  Assert.isTrue(ok, "field residency coordinator production boundary is required")
  return assert(loaded)
end

---@param mapId integer
---@return RuntimeFieldMap
local function map(mapId)
  return {
    mapId = mapId,
    mapSymbol = "map-" .. mapId,
    mapSection = "section-" .. mapId,
    mapSectionNativeId = mapId,
    followMode = "ALLOW",
    scene = {},
    fieldData = {},
    cameraType = 0,
    coordinateOrigin = { x = 0, z = 0 },
    release = function() end,
    updateAnimated = function() end,
  }
end

local function ids(descriptors)
  local result = {}
  local seen = {}
  for _, descriptor in ipairs(descriptors) do
    if not seen[descriptor.mapHeaderId] then
      seen[descriptor.mapHeaderId] = true
      result[#result + 1] = descriptor.mapHeaderId
    end
  end
  table.sort(result)
  return result
end

local function hasId(values, expected)
  for _, value in ipairs(values) do
    if value == expected then
      return true
    end
  end
  return false
end

local function coverageFixture()
  local coverage = {
    anchorX = 0,
    anchorZ = 0,
    committed = {
      { cellKey = "0:0", mapHeaderId = 10 },
      { cellKey = "1:0", mapHeaderId = 20 },
    },
    footprint = {
      { cellKey = "0:0", mapHeaderId = 10 },
      { cellKey = "1:0", mapHeaderId = 20 },
      { cellKey = "2:0", mapHeaderId = 30 },
    },
    destinationMapId = 10,
    physicalFallbacks = 0,
    queued = 0,
    prefetchError = nil,
    prefetchCalls = 0,
  }

  function coverage:committedDescriptors()
    return self.committed
  end

  function coverage:prefetchDescriptors()
    return self.footprint
  end

  function coverage:committedMapIds()
    return ids(self.committed)
  end

  function coverage:prefetchMapIds()
    return ids(self.footprint)
  end

  function coverage:mapHeaderAt(_, _)
    return self.destinationMapId
  end

  function coverage:recenter(anchorX, anchorZ)
    self.anchorX, self.anchorZ = anchorX, anchorZ
    self.physicalFallbacks = self.physicalFallbacks + 1
  end

  function coverage:queuePrefetch()
    self.queued = 1
  end

  function coverage:updatePrefetch()
    self.prefetchCalls = self.prefetchCalls + 1
    if self.prefetchError then
      return 0
    end
    self.queued = 0
    return 0
  end

  function coverage:status()
    return {
      anchorX = self.anchorX,
      anchorZ = self.anchorZ,
      committedCount = #self.committed,
      readyPrefetchCount = math.max(0, #self.footprint - #self.committed),
      queuedPrefetchCount = self.queued,
      synchronousPhysicalFallbackLoads = self.physicalFallbacks,
      prefetchError = self.prefetchError,
    }
  end

  return coverage
end

-- The actor double answers only `reconcilePhysicalWorld`, the one legitimate
-- residency collaboration (physical reprojection of the already-active
-- entry). Reaching any other actor operation from logical residency fails
-- every test in this file rather than one dedicated assertion.
local function logicalOwners(coverage)
  local maps = { [10] = map(10), [20] = map(20), [30] = map(30), [40] = map(40) }
  local loader = {
    maps = maps,
    loads = 0,
    loadCounts = {},
    protections = {},
    protectionCalls = {},
    events = {},
  }
  function loader:load(mapId)
    self.loads = self.loads + 1
    self.loadCounts[mapId] = (self.loadCounts[mapId] or 0) + 1
    return assert(self.maps[mapId])
  end
  function loader:definesMap(mapId)
    return self.maps[mapId] ~= nil
  end
  function loader:protectMap(mapId, protected)
    self.protectionCalls[mapId] = (self.protectionCalls[mapId] or 0) + 1
    self.protections[mapId] = protected and true or nil
    self.events[#self.events + 1] = (protected and "protect:" or "unprotect:") .. mapId
  end

  local actors = setmetatable({ reconciles = 0 }, {
    __index = function(_, key)
      error("logical residency must not reach FieldActorManager." .. tostring(key), 0)
    end,
  })
  function actors:reconcilePhysicalWorld()
    self.reconciles = self.reconciles + 1
  end

  local zoneCalls = {}
  local zone = {
    currentMap = maps[10],
  }
  function zone:afterCoverageCommit(_, player)
    local mapId = coverage:mapHeaderAt(player.fieldX, player.fieldZ)
    local destination = assert(loader.maps[mapId])
    if destination == self.currentMap then
      return nil
    end
    self.currentMap = destination
    zoneCalls[#zoneCalls + 1] = "activate:" .. mapId
    return { oldMapId = self.currentMap.mapId, newMapId = mapId }
  end

  return loader, actors, zone, zoneCalls
end

local coordinatorFixture

local function halo_map_survives_same_anchor_movement()
  local coordinator, _, loader = coordinatorFixture()
  coordinator:initialize()
  coordinator:updatePrefetch(1)
  local loads = loader.loads
  local protectionCalls = loader.protectionCalls[30]

  coordinator:afterCommittedMove({ fieldX = 1, fieldZ = 1, currentMap = map(10) })

  Assert.deepEqual(coordinator:status().residentMapIds, { 10, 20, 30 })
  Assert.equal(loader.loads, loads, "same-anchor movement must not reload the halo map")
  Assert.equal(loader.protectionCalls[30], protectionCalls, "same-anchor movement must not churn halo protection")
  Assert.isTrue(loader.protections[30], "the halo map must remain protected")
  coordinator:dispose()
end

local function prefetched_logical_map_is_reused_on_boundary_promotion()
  local coordinator, coverage, loader, _, zone = coordinatorFixture()
  coordinator:initialize()
  coordinator:updatePrefetch(1)
  local destinationLogicalMap = assert(coordinator:mapForId(30), "the ready map must already be a logical resident")
  local loads = loader.loads

  coordinator:afterCommittedMove({ fieldX = 1, fieldZ = 1, currentMap = zone.currentMap })

  coverage.committed = {
    { cellKey = "1:0", mapHeaderId = 20 },
    { cellKey = "2:0", mapHeaderId = 30 },
  }
  coverage.footprint = coverage.committed
  coverage.destinationMapId = 30
  coordinator:afterCommittedMove({ fieldX = 64, fieldZ = 0, currentMap = zone.currentMap })

  Assert.equal(coordinator:status().synchronousLogicalFallbackLoads, 0)
  Assert.equal(loader.loads, loads, "a ready logical map must not be loaded again")
  Assert.equal(
    coordinator:mapForId(30),
    destinationLogicalMap,
    "boundary promotion must reuse the logical map identity"
  )
  Assert.equal(zone.currentMap.mapId, 30, "the destination logical map must activate")
  Assert.notNil(coordinator:mapForId(20), "the overlapping source map must remain resident")
  coordinator:dispose()
end

local function physical_prefetch_error_does_not_block_logical_readiness()
  local coordinator, coverage = coordinatorFixture()
  coordinator:initialize()
  coverage.prefetchError = "physical prefetch failed"
  local prefetchCalls = coverage.prefetchCalls

  coordinator:updatePrefetch(1)

  Assert.equal(coverage.prefetchCalls, prefetchCalls + 1, "the physical side must receive its bounded opportunity")
  Assert.isTrue(
    hasId(coordinator:status().residentMapIds, 30),
    "logical readiness must progress after a physical error"
  )
  Assert.isTrue(coordinator:status().physical.prefetchError ~= nil)
  coordinator:dispose()
end

coordinatorFixture = function()
  local coverage = coverageFixture()
  local loader, actors, zone, zoneCalls = logicalOwners(coverage)
  local coordinator = coordinatorClass().new({
    coverage = coverage,
    mapLoader = loader,
    actors = actors,
    zoneController = zone,
  })
  return coordinator, coverage, loader, actors, zone, zoneCalls
end

local function preparedMusicAudio()
  local calls = { sequences = {}, banks = {}, sound = 0 }
  local provider = {}
  function provider:sequence(id)
    calls.sequences[#calls.sequences + 1] = id
    return { id = id, bankId = 7 }
  end
  function provider:bank(id)
    calls.banks[#calls.banks + 1] = id
    return { id = id }
  end

  local sound = {}
  local function record()
    calls.sound = calls.sound + 1
  end
  function sound:currentMusic()
    record()
    return 10
  end
  function sound:playMusic()
    record()
  end
  function sound:queueMusicReplacement()
    record()
  end
  function sound:stopMusic()
    record()
  end

  local controller = FieldAudioController.new({
    sound = sound --[[@as GameSound]],
    provider = provider --[[@as AudioAssetProvider]],
    eventState = {
      isFlagSet = function()
        return false
      end,
    },
    fieldPosition = function()
      return 0, 0
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return nil
    end,
  })
  return controller, calls
end

-- The zone controller keeps active logical identity and side effects; this
-- is preserved and unrelated to actor ownership. The resident set for the
-- map the player leaves must be released exactly once, and the only actor
-- collaboration in the whole move is reprojecting the already-active entry
-- onto the recentered physical coverage.
local function active_zone_switches_while_the_overlapping_resident_stays_until_its_last_cell_leaves()
  local coordinator, coverage, _, actors, zone, zoneCalls = coordinatorFixture()
  coordinator:initialize()
  Assert.deepEqual(coordinator:status().residentMapIds, { 10, 20 })
  Assert.equal(actors.reconciles, 0, "logical residency must not touch actors before a physical recenter")

  coverage.destinationMapId = 20
  coordinator:afterCommittedMove({ fieldX = 32, fieldZ = 0, currentMap = zone.currentMap })
  Assert.notNil(coordinator:mapForId(10), "the source resident remains while its cell is committed")
  Assert.equal(zone.currentMap.mapId, 20)
  Assert.deepEqual(zoneCalls, { "activate:20" })
  Assert.equal(actors.reconciles, 1, "a committed recenter reprojects the active actor entry exactly once")

  coverage.committed = { { cellKey = "1:0", mapHeaderId = 20 }, { cellKey = "2:0", mapHeaderId = 30 } }
  coverage.footprint = coverage.committed
  coverage.destinationMapId = 20
  coordinator:afterCommittedMove({ fieldX = 64, fieldZ = 0, currentMap = map(10) })
  Assert.isNil(coordinator:mapForId(10), "the resident releases after its last committed cell leaves")
  coordinator:dispose()
end

local function eviction_tracks_committed_map_headers_and_releases_protection_once()
  local coordinator, coverage, loader = coordinatorFixture()
  coordinator:initialize()
  coordinator:updatePrefetch(1)
  Assert.isTrue(hasId(coordinator:status().residentMapIds, 30))
  Assert.isTrue(loader.protections[10])
  Assert.isTrue(loader.protections[20])

  coverage.committed = { { cellKey = "1:0", mapHeaderId = 20 } }
  coverage.footprint = {
    { cellKey = "1:0", mapHeaderId = 20 },
    { cellKey = "3:0", mapHeaderId = 40 },
  }
  coverage.destinationMapId = 20
  coordinator:afterCommittedMove({ fieldX = 64, fieldZ = 0, currentMap = map(10) })

  local status = coordinator:status()
  Assert.deepEqual(status.residentMapIds, { 20 })
  Assert.isNil(coordinator:mapForId(10))
  Assert.isNil(loader.protections[10])
  Assert.isNil(coordinator:mapForId(30))
  Assert.isNil(loader.protections[30])
  coordinator:dispose()
end

local function physical_prefetch_error_still_allows_logical_progress()
  local coordinator, coverage = coordinatorFixture()
  coordinator:initialize()
  coverage.prefetchError = "physical prefetch failed"

  Assert.equal(coordinator:updatePrefetch(1), 1)
  Assert.isTrue(hasId(coordinator:status().residentMapIds, 30))
  coordinator:dispose()
end

local function shared_headers_have_one_resident_and_one_protection()
  local coordinator, coverage, loader = coordinatorFixture()
  coverage.committed = {
    { cellKey = "0:0", mapHeaderId = 10 },
    { cellKey = "1:0", mapHeaderId = 10 },
  }
  coverage.footprint = coverage.committed
  coordinator:initialize()

  Assert.deepEqual(coordinator:status().residentMapIds, { 10 })
  Assert.equal(loader.loadCounts[10], 1)
  Assert.equal(loader.protectionCalls[10], 1)
  coordinator:dispose()
end

local function resident_removal_is_paired_once()
  local coordinator, coverage, loader = coordinatorFixture()
  coordinator:initialize()
  coverage.committed = { { cellKey = "3:0", mapHeaderId = 40 } }
  coverage.footprint = coverage.committed
  coverage.destinationMapId = 40
  coordinator:afterCommittedMove({ fieldX = 64, fieldZ = 0, currentMap = map(10) })

  Assert.equal(loader.protectionCalls[10], 2)
  Assert.isNil(loader.protections[10])
  coordinator:dispose()
  Assert.equal(loader.protectionCalls[10], 2)
end

local function resident_lookup_does_not_borrow_nonresident_maps()
  local coordinator, _, loader = coordinatorFixture()
  coordinator:initialize()
  local beforeLoads = loader.loads

  Assert.isNil(coordinator:mapForId(30))
  local borrowed = coordinator:mapForPreflight(30)
  Assert.equal(borrowed.mapId, 30)
  Assert.equal(loader.loads, beforeLoads + 1)
  Assert.isNil(loader.protections[30])
  coordinator:dispose()
end

local function overlapping_anchor_moves_do_not_churn_retained_residents()
  local coordinator, coverage, loader = coordinatorFixture()
  coordinator:initialize()
  coordinator:updatePrefetch(1)
  local loads = loader.loads
  local map20ProtectionCalls = loader.protectionCalls[20]

  coverage.committed = {
    { cellKey = "1:0", mapHeaderId = 20 },
    { cellKey = "2:0", mapHeaderId = 30 },
  }
  coverage.footprint = {
    { cellKey = "0:0", mapHeaderId = 10 },
    { cellKey = "1:0", mapHeaderId = 20 },
    { cellKey = "2:0", mapHeaderId = 30 },
    { cellKey = "3:0", mapHeaderId = 40 },
  }
  coverage.destinationMapId = 20
  coordinator:afterCommittedMove({ fieldX = 32, fieldZ = 0, currentMap = map(10) })

  coverage.committed = {
    { cellKey = "0:0", mapHeaderId = 10 },
    { cellKey = "1:0", mapHeaderId = 20 },
  }
  coverage.footprint = {
    { cellKey = "0:0", mapHeaderId = 10 },
    { cellKey = "1:0", mapHeaderId = 20 },
    { cellKey = "2:0", mapHeaderId = 30 },
  }
  coverage.destinationMapId = 10
  coordinator:afterCommittedMove({ fieldX = 0, fieldZ = 0, currentMap = map(20) })
  coordinator:afterCommittedMove({ fieldX = 0, fieldZ = 0, currentMap = map(20) })

  Assert.equal(loader.loads, loads)
  Assert.equal(loader.protectionCalls[20], map20ProtectionCalls)
  coordinator:dispose()
end

local function prepared_hook_failure_releases_map_ownership()
  local coverage = coverageFixture()
  local loader, actors, zone = logicalOwners(coverage)
  local coordinator = coordinatorClass().new({
    coverage = coverage,
    mapLoader = loader,
    actors = actors,
    zoneController = zone,
    onPreparedMap = function()
      error("preparation hook failed", 0)
    end,
  })

  local ok, err = pcall(function()
    coordinator:initialize()
  end)
  Assert.isFalse(ok)
  Assert.equal(err, "preparation hook failed")
  Assert.isNil(loader.protections[10])
  coordinator:dispose()
end

local function outrunning_prefetch_keeps_the_world_coherent_and_counts_fallbacks()
  local coordinator, coverage, loader, _, zone = coordinatorFixture()
  coverage.committed = { { cellKey = "0:0", mapHeaderId = 10 } }
  coverage.footprint = coverage.committed
  coordinator:initialize()
  local beforeLoads = loader.loads
  coverage.committed = { { cellKey = "1:0", mapHeaderId = 20 } }
  coverage.footprint = coverage.committed
  coverage.destinationMapId = 20
  coordinator:afterCommittedMove({ fieldX = 32, fieldZ = 0, currentMap = zone.currentMap })

  local status = coordinator:status()
  Assert.equal(loader.loads, beforeLoads + 1, "a missing logical map is acquired synchronously")
  Assert.equal(status.synchronousLogicalFallbackLoads, 1)
  Assert.equal(status.physical.synchronousPhysicalFallbackLoads, 1)
  Assert.equal(zone.currentMap.mapId, 20)
  Assert.notNil(coordinator:mapForId(20))
  coordinator:dispose()
end

local function prepared_map_hook_warms_music_before_publication()
  local coverage = coverageFixture()
  local loader, actors, zone = logicalOwners(coverage)
  loader.maps[30].fieldData = {
    music = { day = 20, night = 20, flagOverrides = {}, traversalOverrides = {} },
  }
  local audio, calls = preparedMusicAudio()
  local coordinator = coordinatorClass().new({
    coverage = coverage,
    mapLoader = loader,
    actors = actors,
    zoneController = zone,
    onPreparedMap = function(runtimeMap)
      if runtimeMap.mapId == 30 then
        local prewarmMapMusic = audio.prewarmMapMusic
        Assert.isTrue(
          type(prewarmMapMusic) == "function",
          "prepared map lifecycle must expose non-playing music metadata warmup"
        )
        prewarmMapMusic(audio, runtimeMap)
      end
    end,
  })

  coordinator:initialize()
  Assert.equal(coordinator:updatePrefetch(1), 1)

  Assert.deepEqual(calls.sequences, { 20 }, "prepared map hook must warm the map-header sequence")
  Assert.deepEqual(calls.banks, { 7 }, "prepared map hook must warm the sequence bank")
  Assert.equal(calls.sound, 0, "prepared-map warmup must not enter playback")
  Assert.deepEqual(coordinator:status().residentMapIds, { 10, 20, 30 })
  Assert.notNil(coordinator:mapForId(30), "a ready map must become logically resident after publication")
  Assert.equal(zone.currentMap.mapId, 10, "preparing a map must not switch the active zone")
  coordinator:dispose()
end

-- The discontinuous warp transaction
-- publishes/reuses/rolls back logical residents and coverage without ever
-- preparing, committing, rebinding, or selecting an actor map.
local function transition_lifecycle_stages_and_commits_logical_residents_only()
  local coordinator, _, loader = coordinatorFixture()
  coordinator:initialize()
  local destinationCoverage = coverageFixture()
  destinationCoverage.committed = { { cellKey = "1:0", mapHeaderId = 20 } }
  destinationCoverage.footprint = {
    { cellKey = "1:0", mapHeaderId = 20 },
    { cellKey = "2:0", mapHeaderId = 30 },
    { cellKey = "3:0", mapHeaderId = 20 },
  }
  local destination = map(20)
  local map20Loads = loader.loadCounts[20]
  local map20ProtectionCalls = loader.protectionCalls[20]

  local transaction = coordinator:prepareTransition(destination, destinationCoverage --[[@as FieldCoverage]])
  Assert.deepEqual(coordinator:status().residentMapIds, { 10, 20 })
  Assert.notNil(coordinator:mapForId(20))
  Assert.notNil(coordinator:mapForId(10))
  Assert.isTrue(loader.protections[20])
  Assert.isTrue(loader.protections[30])

  coordinator:discardTransition(transaction)
  coordinator:discardTransition(transaction)
  Assert.deepEqual(coordinator:status().residentMapIds, { 10, 20 })
  Assert.isNil(coordinator:mapForId(30))
  Assert.isNil(loader.protections[30])
  Assert.isTrue(loader.protections[20])
  Assert.equal(loader.loadCounts[20], map20Loads, "reused target headers must not reload")
  Assert.equal(loader.protectionCalls[20], map20ProtectionCalls, "reused protection must not churn")

  local committed = coordinator:prepareTransition(destination, destinationCoverage --[[@as FieldCoverage]])
  coordinator:commitTransition(committed)
  coordinator:discardTransition(committed)
  Assert.deepEqual(coordinator:status().residentMapIds, { 20, 30 })
  Assert.isNil(coordinator:mapForId(10))

  coordinator:dispose()
end

local function filler_headers_without_a_logical_map_are_never_acquired()
  local coordinator, coverage, loader = coordinatorFixture()
  coverage.committed = {
    { cellKey = "0:0", mapHeaderId = 10 },
    { cellKey = "0:1", mapHeaderId = 0 },
  }
  coverage.footprint = coverage.committed
  coordinator:initialize()

  Assert.deepEqual(coordinator:status().residentMapIds, { 10 })
  Assert.isNil(loader.loadCounts[0], "a filler header without a logical map must never reach map loading")
  Assert.isNil(coordinator:mapForId(0))
  coordinator:dispose()
end

return {
  metadata = { capabilities = {} },
  tests = {
    halo_map_survives_same_anchor_movement = halo_map_survives_same_anchor_movement,
    prefetched_logical_map_is_reused_on_boundary_promotion = prefetched_logical_map_is_reused_on_boundary_promotion,
    physical_prefetch_error_does_not_block_logical_readiness = physical_prefetch_error_does_not_block_logical_readiness,
    active_zone_switches_while_the_overlapping_resident_stays_until_its_last_cell_leaves = active_zone_switches_while_the_overlapping_resident_stays_until_its_last_cell_leaves,
    eviction_tracks_committed_map_headers_and_releases_protection_once = eviction_tracks_committed_map_headers_and_releases_protection_once,
    physical_prefetch_error_still_allows_logical_progress = physical_prefetch_error_still_allows_logical_progress,
    shared_headers_have_one_resident_and_one_protection = shared_headers_have_one_resident_and_one_protection,
    resident_removal_is_paired_once = resident_removal_is_paired_once,
    resident_lookup_does_not_borrow_nonresident_maps = resident_lookup_does_not_borrow_nonresident_maps,
    overlapping_anchor_moves_do_not_churn_retained_residents = overlapping_anchor_moves_do_not_churn_retained_residents,
    prepared_hook_failure_releases_map_ownership = prepared_hook_failure_releases_map_ownership,
    outrunning_prefetch_keeps_the_world_coherent_and_counts_fallbacks = outrunning_prefetch_keeps_the_world_coherent_and_counts_fallbacks,
    prepared_map_hook_warms_music_before_publication = prepared_map_hook_warms_music_before_publication,
    transition_lifecycle_stages_and_commits_logical_residents_only = transition_lifecycle_stages_and_commits_logical_residents_only,
    filler_headers_without_a_logical_map_are_never_acquired = filler_headers_without_a_logical_map_are_never_acquired,
  },
}
