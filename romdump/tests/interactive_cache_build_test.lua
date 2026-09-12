-- Interactive producer tests use cache readiness seams to verify deterministic
-- orchestration without opening a ROM or starting worker threads.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local FakeCache = require("tests.support.FakeCache")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptCacheWriter = require("romdump.src.digest.script.ScriptCacheWriter")
local InteractiveCacheBuild = require("romdump.src.build.InteractiveCacheBuild")
local CompilerPool = require("romdump.src.build.CompilerPool")
local FieldCellCompiler = require("romdump.src.digest.field.FieldCellCompiler")
local FieldCellCacheWriter = require("romdump.src.digest.field.FieldCellCacheWriter")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local MapCacheWriter = require("romdump.src.digest.map.MapCacheWriter")
local MapCompilePlan = require("romdump.src.digest.map.MapCompilePlan")
local MapRomFixture = require("tests.support.MapRomFixture")
local ProducerFingerprint = require("romdump.src.ProducerFingerprint")
local RomFs = require("romdump.src.source.RomFs")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")

local T = {}

local GENERATION = string.rep("a", 40)

local function scriptResource(id, generation, memberId)
  return {
    api = 1,
    id = id,
    metadata = {
      generated = true,
      source = {
        repository = "g4recomp",
        romSha1 = generation,
        member = memberId,
        scriptIndex = 0,
      },
      coverage = { complete = true, unsupportedCount = 0 },
    },
    steps = { { op = "stop" } },
  }
end

local function scriptMember(memberId, id, generation)
  return {
    memberId = memberId,
    marker = generation .. ":member:" .. tostring(memberId),
    coverage = {
      source = { repository = "g4recomp", romSha1 = generation },
      totals = {
        members = 1,
        scripts = 1,
        reachableInstructions = 1,
        supportedInstructions = 1,
        unsupportedInstructions = 0,
        malformedInstructions = 0,
      },
      opcodes = {},
      scripts = {
        {
          sourceId = string.format("hgss.scr_seq.%04d.%03d", memberId, 0),
          publicId = id,
          status = "complete",
          unsupported = {},
        },
      },
    },
    resources = {
      {
        id = id,
        member = memberId,
        scriptIndex = 0,
        sourceHash = generation,
        resource = scriptResource(id, generation, memberId),
        report = { complete = true, unsupportedCount = 0 },
      },
    },
  }
end

local function scriptPlan(marker)
  local resources = {
    { id = "script.one", member = 0, scriptIndex = 0 },
    { id = "script.two", member = 1, scriptIndex = 0 },
  }
  return {
    generationKey = GENERATION,
    marker = marker,
    version = "heartgold",
    sourcePath = "romfs/field_scripts.narc",
    romSha1 = "rom-sha",
    memberCount = 2,
    members = {
      { memberId = 0, marker = GENERATION .. ":member:0", scripts = { { scriptIndex = 0, id = "script.one" } } },
      { memberId = 1, marker = GENERATION .. ":member:1", scripts = { { scriptIndex = 0, id = "script.two" } } },
    },
    resources = resources,
    index = {
      schema = ScriptCache.INDEX_SCHEMA,
      version = "heartgold",
      generation = GENERATION,
      marker = marker,
      memberCount = 2,
      scriptMemberCount = 2,
      skippedMemberCount = 0,
      scriptCount = 2,
      resourceCount = 2,
      resources = resources,
    },
  }
end

local function stageMember(cache, plan, memberId)
  local id = memberId == 0 and "script.one" or "script.two"
  Assert.isTrue(ScriptCacheWriter.stageMember(cache, plan, scriptMember(memberId, id, GENERATION)))
end

local function fakeRomFs()
  return {
    close = function(self)
      self.closed = true
    end,
  }
end

function T.pending_maps_advance_in_map_id_order()
  local oldCellReady = FieldCellCache.isCellReady
  local oldMapReady = MapCompilePlan.isReady
  local requests = {}
  local ready = {}
  local function plan(mapId)
    return {
      strategy = "canonical",
      expectedMarker = "map-marker-" .. mapId,
      resolved = { map = { id = mapId } },
      cellPlans = { { descriptor = {}, expectedMarker = "cell-marker" } },
      jobIdentity = "map:" .. mapId,
    }
  end

  FieldCellCache.isCellReady = function()
    return true
  end
  MapCompilePlan.isReady = function(_, mapPlan)
    return ready[mapPlan.resolved.map.id] == true
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
  MapCompilePlan.isReady = oldMapReady
  if not ok then
    error(err, 0)
  end
  Assert.deepEqual(requests, { 2, 1000000003, 1000000007 })
end

function T.indoor_map_ensure_uses_aggregate_readiness_and_job_identity()
  local romFs = MapRomFixture.build({})
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  local producerFingerprint = "synthetic-producer"
  local bundle = assert(MapAssetCompiler.compile(romFs, MapRomFixture.MAP_SYMBOL, {
    producerFingerprint = producerFingerprint,
  }))
  local plan = assert(
    MapCompilePlan.plan(
      romFs,
      { schema = FieldCellCache.INDEX_SCHEMA, matrices = {} },
      MapRomFixture.MAP_SYMBOL,
      producerFingerprint
    )
  )
  local requested = {}
  local waitKey
  local build = setmetatable({
    cacheFs = cacheFs,
    romFs = romFs,
    producerFingerprint = producerFingerprint,
    world = { byId = { [bundle.mapId] = {} } },
    mapPlans = { [bundle.mapId] = plan },
    closed = false,
    pool = {
      request = function(_, job)
        requested[#requested + 1] = job
        MapCacheWriter.write(cacheFs, bundle)
        return "queued"
      end,
      wait = function(_, key)
        waitKey = key
        return "ready", { result = { marker = bundle.marker } }
      end,
    },
  }, InteractiveCacheBuild)

  local ok, err = pcall(function()
    return build:ensureField(bundle.mapId)
  end)
  Assert.isTrue(ok, tostring(err))
  Assert.equal(#requested, 1)
  Assert.equal(requested[1].kind, "map")
  Assert.equal(requested[1].key, "field-map:" .. plan.jobIdentity)
  Assert.equal(requested[1].payload.mapId, bundle.mapId)
  Assert.equal(waitKey, requested[1].key)
end

function T.disposal_publishes_the_final_member_before_activation()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local plan = scriptPlan("script-marker")
  stageMember(cache, plan, 0)
  local shutdowns = 0
  local build = setmetatable({
    cacheFs = cache,
    pool = {
      shutdown = function()
        shutdowns = shutdowns + 1
        stageMember(cache, plan, 1)
      end,
    },
    romFs = fakeRomFs(),
    scriptPlan = plan,
    closed = false,
  }, InteractiveCacheBuild)

  build:dispose()

  Assert.equal(shutdowns, 1)
  Assert.equal(cache:read(ScriptCache.generationMarkerPath(GENERATION)), plan.marker)
  Assert.equal(cache:read(ScriptCache.markerPath()), plan.marker)
  local active = assert(cache:loadLua(ScriptCache.activeIndexPath()))
  Assert.equal(active.generation, GENERATION)
end

function T.startup_activates_a_complete_inactive_generation_without_rewriting_members()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local plan = scriptPlan("script-marker")
  stageMember(cache, plan, 0)
  stageMember(cache, plan, 1)
  Assert.isTrue(ScriptCacheWriter.finalizeGeneration(cache, plan))
  local originalMember = assert(cache:read(ScriptCache.scriptPath(GENERATION, 0, "script.one")))
  local activationCount = 0

  local originalCacheForVersion = CacheFs.forVersion
  local originalRomFsOpen = RomFs.open
  local originalProducerBackend = ProducerFingerprint.appBackend
  local originalProducerCompute = ProducerFingerprint.compute
  local originalCompileIndex = FieldCellCompiler.compileIndex
  local originalWriteIndex = FieldCellCacheWriter.writeIndex
  local originalLoadIndex = FieldCellCache.loadIndex
  local originalScriptPlan = ScriptCompiler.plan
  local originalPoolNew = CompilerPool.new
  local originalActivate = ScriptCacheWriter.activateGeneration

  CacheFs.forVersion = function()
    return cache
  end
  RomFs.open = function()
    return fakeRomFs()
  end
  ProducerFingerprint.appBackend = function()
    return {
      getInfo = function()
        return { type = "directory" }
      end,
    }
  end
  ProducerFingerprint.compute = function()
    return "producer-fingerprint"
  end
  FieldCellCompiler.compileIndex = function()
    return { indexMarker = "current-index" }
  end
  FieldCellCacheWriter.writeIndex = function() end
  FieldCellCache.loadIndex = function()
    return { matrices = {} }
  end
  ScriptCompiler.plan = function()
    return plan
  end
  CompilerPool.new = function()
    return { shutdown = function() end }
  end
  ScriptCacheWriter.activateGeneration = function(cacheFs, generation)
    activationCount = activationCount + 1
    return originalActivate(cacheFs, generation)
  end
  cache:writeLua(MapAssetCache.worldPath(), { byId = {}, maps = {} })

  local ok, buildOrError = pcall(InteractiveCacheBuild.new, {
    versionId = "heartgold",
    producerFingerprint = "producer-fingerprint",
  })

  CacheFs.forVersion = originalCacheForVersion
  RomFs.open = originalRomFsOpen
  ProducerFingerprint.appBackend = originalProducerBackend
  ProducerFingerprint.compute = originalProducerCompute
  FieldCellCompiler.compileIndex = originalCompileIndex
  FieldCellCacheWriter.writeIndex = originalWriteIndex
  FieldCellCache.loadIndex = originalLoadIndex
  ScriptCompiler.plan = originalScriptPlan
  CompilerPool.new = originalPoolNew
  ScriptCacheWriter.activateGeneration = originalActivate

  if not ok then
    error(buildOrError, 0)
  end
  local build = assert(buildOrError)
  local active = assert(cache:loadLua(ScriptCache.activeIndexPath()))
  Assert.equal(activationCount, 1)
  Assert.equal(active.generation, GENERATION)
  Assert.equal(cache:read(ScriptCache.scriptPath(GENERATION, 0, "script.one")), originalMember)
  build.romFs:close()
end

function T.missing_or_empty_producer_fingerprint_fails_before_opening_dependencies()
  local originalCacheForVersion = CacheFs.forVersion
  local originalRomFsOpen = RomFs.open
  local originalPoolNew = CompilerPool.new
  local function unexpectedCall()
    error("producer fingerprint validation must precede dependency construction")
  end

  CacheFs.forVersion = unexpectedCall
  RomFs.open = unexpectedCall
  CompilerPool.new = unexpectedCall
  local ok, err = pcall(function()
    local function assertInvalid(producerFingerprint)
      local success, failure = pcall(InteractiveCacheBuild.new, {
        versionId = "heartgold",
        producerFingerprint = producerFingerprint,
      })
      Assert.isFalse(success)
      Assert.isTrue(tostring(failure):find("producer fingerprint is required", 1, true) ~= nil)
    end
    assertInvalid(nil)
    assertInvalid("")
  end)
  CacheFs.forVersion = originalCacheForVersion
  RomFs.open = originalRomFsOpen
  CompilerPool.new = originalPoolNew
  if not ok then
    error(err, 0)
  end
end

function T.incomplete_target_remains_inert_after_shutdown()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local plan = scriptPlan("script-marker")
  stageMember(cache, plan, 0)
  local romFs = fakeRomFs()
  local build = setmetatable({
    cacheFs = cache,
    pool = { shutdown = function() end },
    romFs = romFs,
    scriptPlan = plan,
    closed = false,
  }, InteractiveCacheBuild)

  build:dispose()

  Assert.isNil(cache:read(ScriptCache.generationMarkerPath(GENERATION)))
  Assert.isNil(cache:read(ScriptCache.markerPath()))
  Assert.equal(cache:read(ScriptCache.memberMarkerPath(GENERATION, 0)), plan.members[1].marker)
  Assert.isTrue(romFs.closed)
end

function T.shutdown_failure_closes_rom_without_mutating_script_selection()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local plan = scriptPlan("script-marker")
  stageMember(cache, plan, 0)
  local romFs = fakeRomFs()
  local build = setmetatable({
    cacheFs = cache,
    pool = {
      shutdown = function()
        error("shutdown failed")
      end,
    },
    romFs = romFs,
    scriptPlan = plan,
    closed = false,
  }, InteractiveCacheBuild)

  local failure = Assert.throws(function()
    build:dispose()
  end)
  Assert.isTrue(tostring(failure):find("shutdown failed", 1, true) ~= nil)
  Assert.isNil(cache:read(ScriptCache.generationMarkerPath(GENERATION)))
  Assert.isNil(cache:read(ScriptCache.markerPath()))
  Assert.equal(cache:read(ScriptCache.memberMarkerPath(GENERATION, 0)), plan.members[1].marker)
  Assert.isTrue(romFs.closed)
end

return { metadata = { capabilities = {} }, tests = T }
