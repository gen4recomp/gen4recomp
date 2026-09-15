-- Generation-session source-inventory contract: selecting a generation must
-- schedule one persisted producer inventory instead of compiling aggregate
-- sources on the controller thread. Membership follows explicit source rules
-- rather than compile luck, a planning failure for a loadable map keeps its
-- map identity instead of vanishing into absent membership, each scheduling
-- pass does bounded planning work with urgent demand first, a warm selection
-- performs no aggregate compilation, and exhaustive scheduling covers every
-- current family exactly once. Map identities come from the frozen
-- pokeheartgold map-header reference; no commercial bytes are involved.

local Assert = require("tests.support.Assert")
local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local ArtifactState = require("romdump.src.build.ArtifactState")
local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldCellCompiler = require("romdump.src.digest.field.FieldCellCompiler")
local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local InteractiveCacheBuild = require("romdump.src.build.InteractiveCacheBuild")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local MapCompilePlan = require("romdump.src.digest.map.MapCompilePlan")
local MonCatalogCompiler = require("romdump.src.digest.mons.MonCatalogCompiler")
local MonPresentationCompiler = require("romdump.src.digest.mons.MonPresentationCompiler")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local RomFs = require("romdump.src.source.RomFs")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
local SourcePlan = require("romdump.src.build.SourcePlan")
local WorldManifest = require("romdump.src.digest.map.WorldManifest")

local T = {}

local PRODUCER_ID = "d" .. string.rep("3", 64)

local function identity(generation)
  return { versionId = "heartgold", generationId = generation, producerId = PRODUCER_ID }
end

local function freshCalls()
  return { romFs = 0, index = 0, script = 0, audio = 0, catalog = 0, presentation = 0 }
end

local function cellDescriptor(matrixMemberId, index)
  return {
    matrixMemberId = matrixMemberId,
    index = index,
    x = 0,
    z = 0,
    mapHeaderId = 0,
    altitude = 0,
    landDataMemberId = 1,
    areaDataMemberId = 2,
  }
end

local function syntheticIndexBundle()
  return {
    index = {
      matrices = {
        { matrixMemberId = 11, cells = { cellDescriptor(11, 0), cellDescriptor(11, 1) } },
      },
    },
    indexMarker = "synthetic-index-marker",
  }
end

local function scriptMembers(first, last)
  local members = {}
  for memberId = first, last do
    members[#members + 1] = { memberId = memberId }
  end
  return members
end

-- Aggregate source planners answer synthetic data while recording that the
-- controller invoked them. Any controller call is the defect under test: the
-- session must schedule worker-side inventory work instead.
local function plannerPatches(calls, options)
  options = options or {}
  return {
    {
      target = RomFs,
      name = "open",
      replacement = function()
        calls.romFs = calls.romFs + 1
        return { close = function() end }
      end,
    },
    {
      target = FieldCellCompiler,
      name = "compileIndex",
      replacement = function()
        calls.index = calls.index + 1
        return syntheticIndexBundle()
      end,
    },
    {
      target = ScriptCompiler,
      name = "plan",
      replacement = function()
        calls.script = calls.script + 1
        return { members = options.members or scriptMembers(1, 2), generationKey = "synthetic-script-generation" }
      end,
    },
    {
      target = AudioCompiler,
      name = "plan",
      replacement = function()
        calls.audio = calls.audio + 1
        return { bankPlans = options.bankPlans or {} }
      end,
    },
    {
      target = MonCatalogCompiler,
      name = "compileCatalog",
      replacement = function()
        calls.catalog = calls.catalog + 1
        return { species = {} }
      end,
    },
    {
      target = MonPresentationCompiler,
      name = "plan",
      replacement = function()
        calls.presentation = calls.presentation + 1
        return { icons = { pageIds = options.icons or {} }, portraits = { pageIds = options.portraits or {} } }
      end,
    },
  }
end

local function recordingPool()
  local pool = { submitted = {}, states = {}, selects = 0 }
  function pool:selectGeneration(selection, epoch)
    self.selects = self.selects + 1
    self.selection = selection
    self.epoch = epoch
  end
  function pool:update() end
  local function stateOf(self, jobKey)
    local state = self.states[jobKey]
    if type(state) == "table" then
      return state.state, state.details
    end
    return state or "unknown", nil
  end
  function pool:status(jobKey)
    return stateOf(self, jobKey)
  end
  function pool:request(job)
    self.submitted[#self.submitted + 1] = job.jobKey
    return stateOf(self, job.jobKey)
  end
  function pool:retireSelection(epoch)
    self.retiredEpoch = epoch
    return true
  end
  return pool
end

local function withPatched(patches, fn)
  local originals = {}
  for index, patch in ipairs(patches) do
    originals[index] = patch.target[patch.name]
    patch.target[patch.name] = patch.replacement
  end
  local ok, first, second, third = pcall(fn)
  for index, patch in ipairs(patches) do
    patch.target[patch.name] = originals[index]
  end
  if not ok then
    error(first, 0)
  end
  return first, second, third
end

local function copyList(list)
  local copy = {}
  for index, value in ipairs(list) do
    copy[index] = value
  end
  return copy
end

local function contains(list, value)
  for _, entry in ipairs(list) do
    if entry == value then
      return true
    end
  end
  return false
end

local function openSession(generation, pool, epoch)
  return InteractiveCacheBuild.new({
    identity = identity(generation),
    epoch = epoch or 1,
    pool = pool,
    sweepEnabled = false,
  })
end

local function firstOrdinaryMapId()
  local eligible = nil
  for map in MapCatalog.all() do
    if map.symbol ~= "MAP_NOTHING" and map.symbol ~= "MAP_UNDERGROUND" then
      eligible = map.id
      break
    end
  end
  return assert(eligible, "the frozen map reference carries an ordinary field map")
end

local function excludedMapId()
  for map in MapCatalog.all() do
    if map.symbol == "MAP_NOTHING" or map.symbol == "MAP_UNDERGROUND" then
      return map.id
    end
  end
  error("the frozen map reference carries an explicitly excluded header", 0)
end

function T.construction_schedules_the_source_inventory_without_compiling_sources()
  local calls = freshCalls()
  local backend = FakeCache.new()
  local realForVersion = CacheFs.forVersion
  local patches = plannerPatches(calls)
  patches[#patches + 1] = {
    target = CacheFs,
    name = "forVersion",
    replacement = function()
      return realForVersion("heartgold", backend)
    end,
  }
  local result = withPatched(patches, function()
    local pool = recordingPool()
    local session = openSession("construction-generation", pool)
    local snapshot = {
      romFs = calls.romFs,
      index = calls.index,
      script = calls.script,
      audio = calls.audio,
      catalog = calls.catalog,
      presentation = calls.presentation,
    }
    local ready, failure = session:requestMilestone("bootstrap", "required")
    return {
      snapshot = snapshot,
      ready = ready,
      failure = failure,
      submitted = copyList(pool.submitted),
      enumerationComplete = session:status().enumerationComplete,
    }
  end)
  Assert.equal(result.snapshot.romFs, 0, "selecting a generation opens no source reader")
  Assert.equal(result.snapshot.index, 0, "selecting a generation compiles no cell index")
  Assert.equal(result.snapshot.script, 0, "selecting a generation plans no scripts")
  Assert.equal(result.snapshot.audio, 0, "selecting a generation plans no audio")
  Assert.equal(result.snapshot.catalog, 0, "selecting a generation compiles no mon catalog")
  Assert.equal(result.snapshot.presentation, 0, "selecting a generation plans no mon presentation")
  Assert.isFalse(result.ready, "bootstrap stays pending until the inventory publishes")
  Assert.isNil(result.failure, "bootstrap reports no failure while the inventory is pending")
  Assert.isTrue(
    contains(result.submitted, "source-plan:global"),
    "bootstrap demand schedules the persisted source inventory job"
  )
  Assert.isTrue(result.enumerationComplete == false, "enumeration is not complete before the inventory publishes")
end

function T.field_record_membership_follows_the_source_rule_without_compiling_records()
  local calls = freshCalls()
  local backend = FakeCache.new()
  local realForVersion = CacheFs.forVersion
  local eligible = firstOrdinaryMapId()
  local excluded = excludedMapId()
  local compileCalls = 0
  local patches = plannerPatches(calls)
  patches[#patches + 1] = {
    target = CacheFs,
    name = "forVersion",
    replacement = function()
      return realForVersion("heartgold", backend)
    end,
  }
  patches[#patches + 1] = {
    target = FieldMapDataCompiler,
    name = "newSession",
    replacement = function()
      return {
        compile = function(_, mapId)
          compileCalls = compileCalls + 1
          if mapId == eligible then
            return nil, { code = "SYNTHETIC_RECORD_FAULT", message = "synthetic record fault" }
          end
          return {}
        end,
        close = function() end,
      }
    end,
  }
  local result = withPatched(patches, function()
    local pool = recordingPool()
    local session = openSession("membership-generation", pool)
    local readyEligible, failureEligible = session:requestJob("map-data", tostring(eligible), "required")
    local readyExcluded, failureExcluded = session:requestJob("map-data", tostring(excluded), "required")
    return {
      readyEligible = readyEligible,
      failureEligible = failureEligible,
      readyExcluded = readyExcluded,
      failureExcluded = failureExcluded,
      submitted = copyList(pool.submitted),
      compileCalls = compileCalls,
    }
  end)
  Assert.isFalse(result.readyEligible, "a source-eligible record is not answered ready while cold")
  Assert.isNil(
    result.failureEligible,
    "a source-eligible record stays pending instead of rejected: " .. tostring(result.failureEligible)
  )
  Assert.isTrue(
    contains(result.submitted, "source-plan:global"),
    "record demand schedules the persisted source inventory job"
  )
  Assert.equal(result.compileCalls, 0, "membership follows the source rule without compiling records")
  Assert.isFalse(result.readyExcluded, "an explicitly excluded header is never answered ready")
  Assert.notNil(result.failureExcluded, "an explicitly excluded header is rejected as unsupported")
  Assert.isFalse(
    contains(result.submitted, "map-data:" .. tostring(excluded)),
    "an explicitly excluded header never dispatches record work"
  )
end

function T.loadable_map_planning_failure_surfaces_with_its_identity()
  local calls = freshCalls()
  local backend = FakeCache.new()
  local realForVersion = CacheFs.forVersion
  local failingMapId = firstOrdinaryMapId()
  local patches = plannerPatches(calls)
  patches[#patches + 1] = {
    target = CacheFs,
    name = "forVersion",
    replacement = function()
      return realForVersion("heartgold", backend)
    end,
  }
  patches[#patches + 1] = {
    target = MapCompilePlan,
    name = "plan",
    replacement = function(...)
      if select(3, ...) == failingMapId then
        error("synthetic planning failure for map " .. tostring(failingMapId), 0)
      end
      return { cellPlans = {} }
    end,
  }
  patches[#patches + 1] = {
    target = FieldMapDataCompiler,
    name = "newSession",
    replacement = function()
      return {
        compile = function()
          return {}
        end,
        close = function() end,
      }
    end,
  }
  local result = withPatched(patches, function()
    local _, plannerError = pcall(MapCompilePlan.plan, nil, nil, failingMapId, nil)
    local pool = recordingPool()
    local session = openSession("planning-failure-generation", pool)
    local ready, failure = session:requestField(failingMapId, "required")
    pool.states["source-plan:global"] = { state = "failed", details = { error = plannerError } }
    session:update()
    local status = session:status()
    return {
      ready = ready,
      failure = failure,
      failures = status.failures,
      complete = status.complete,
      enumerationComplete = status.enumerationComplete,
    }
  end)
  local namesMap = false
  for _, failure in ipairs(result.failures) do
    if tostring(failure):find(tostring(failingMapId), 1, true) ~= nil then
      namesMap = true
    end
    Assert.isNil(
      tostring(failure):find("no supported map", 1, true),
      "a planning failure is never converted to absent membership: " .. tostring(failure)
    )
    Assert.isNil(
      tostring(failure):find("no field record", 1, true),
      "a planning failure is never converted to absent membership: " .. tostring(failure)
    )
  end
  Assert.isTrue(namesMap, "a loadable map planning failure surfaces with its map identity")
  Assert.isTrue(result.enumerationComplete == false, "enumeration is not complete after a failed inventory")
  Assert.isFalse(result.complete, "no complete attestation follows a failed inventory")
end

function T.repeated_scheduling_passes_do_bounded_work_with_urgent_demand_first()
  local calls = freshCalls()
  local backend = FakeCache.new()
  local realForVersion = CacheFs.forVersion
  local realDependencies = ArtifactJobs.dependencies
  local realValidate = ArtifactJobs.validate
  local counting = { enabled = false, dependencies = 0, validate = 0, order = {} }
  local patches = plannerPatches(calls, { members = scriptMembers(1, 41) })
  patches[#patches + 1] = {
    target = CacheFs,
    name = "forVersion",
    replacement = function()
      return realForVersion("heartgold", backend)
    end,
  }
  patches[#patches + 1] = {
    target = ArtifactJobs,
    name = "dependencies",
    replacement = function(kind, key, plans)
      if counting.enabled then
        counting.dependencies = counting.dependencies + 1
        counting.order[#counting.order + 1] = kind .. ":" .. key
      end
      return realDependencies(kind, key, plans)
    end,
  }
  patches[#patches + 1] = {
    target = ArtifactJobs,
    name = "validate",
    replacement = function(cacheFs, generationId, kind, key, plans)
      if counting.enabled then
        counting.validate = counting.validate + 1
      end
      -- Sweep members that need no worker execution settle ready here, so a
      -- later pass must re-drive budget-parked entries while the pool is idle.
      if kind == "script-member" then
        return true
      end
      return realValidate(cacheFs, generationId, kind, key, plans)
    end,
  }
  patches[#patches + 1] = {
    target = FieldMapDataCompiler,
    name = "newSession",
    replacement = function()
      return {
        compile = function()
          return {}
        end,
        close = function() end,
      }
    end,
  }
  local result = withPatched(patches, function()
    local pool = recordingPool()
    local session = openSession("bounded-planning-generation", pool)
    for memberId = 1, 40 do
      session:requestJob("script-member", tostring(memberId), "sweep")
    end
    session:requestJob("script-member", "41", "required")
    local function measuredUpdate()
      counting.enabled = true
      session:update()
      counting.enabled = false
      local snapshot = {
        nodes = counting.dependencies + counting.validate,
        order = copyList(counting.order),
      }
      counting.dependencies = 0
      counting.validate = 0
      counting.order = {}
      return snapshot
    end
    local first = measuredUpdate()
    -- Budget-parked sweep work rejoins planning on later passes even though
    -- the pool reports no progress, until every demand settles worker-free.
    local passes = { first }
    local settled = false
    for _ = 1, 10 do
      settled = true
      for memberId = 1, 41 do
        local entry = session.byKey["script-member:" .. tostring(memberId)]
        if entry == nil or not entry.ready then
          settled = false
          break
        end
      end
      if settled then
        break
      end
      passes[#passes + 1] = measuredUpdate()
    end
    return { first = first, passes = passes, settled = settled }
  end)
  Assert.isTrue(
    result.first.nodes <= 32,
    "one scheduling pass advances at most 32 planning nodes, got " .. tostring(result.first.nodes)
  )
  local sweepPosition, requiredPosition = nil, nil
  for position, jobKey in ipairs(result.first.order) do
    if jobKey == "script-member:1" then
      sweepPosition = position
    end
    if jobKey == "script-member:41" then
      requiredPosition = position
    end
  end
  Assert.notNil(requiredPosition, "the urgent demand is planned during the pass")
  Assert.notNil(sweepPosition, "sweep demand is planned during the pass")
  Assert.isTrue(requiredPosition < sweepPosition, "urgent demand is planned before sweep work")
  for index, pass in ipairs(result.passes) do
    Assert.isTrue(pass.nodes <= 32, "repeat pass " .. tostring(index) .. " stays bounded, got " .. tostring(pass.nodes))
  end
  Assert.isTrue(result.settled, "parked sweep work is re-driven without worker progress")
end

function T.large_sweep_corpus_keeps_settling_worker_free_demand()
  local calls = freshCalls()
  local backend = FakeCache.new()
  local realForVersion = CacheFs.forVersion
  local realDependencies = ArtifactJobs.dependencies
  local realValidate = ArtifactJobs.validate
  -- A corpus this large carries more fixed per-pass overhead (pool polling,
  -- the admission ledger, the scheduling sort) than the planning slice, so a
  -- slice measured from the update entry expires before the first planning
  -- node and planning would stall with an idle pool.
  local corpusSize = 30000
  local counting = { enabled = false, dependencies = 0, validate = 0 }
  local patches = plannerPatches(calls, { members = scriptMembers(1, 2) })
  patches[#patches + 1] = {
    target = CacheFs,
    name = "forVersion",
    replacement = function()
      return realForVersion("heartgold", backend)
    end,
  }
  patches[#patches + 1] = {
    target = ArtifactJobs,
    name = "dependencies",
    replacement = function(kind, key, plans)
      if counting.enabled then
        counting.dependencies = counting.dependencies + 1
      end
      return realDependencies(kind, key, plans)
    end,
  }
  patches[#patches + 1] = {
    target = ArtifactJobs,
    name = "validate",
    replacement = function(cacheFs, generationId, kind, key, plans)
      if counting.enabled then
        counting.validate = counting.validate + 1
      end
      -- Every sweep member settles without worker execution, so progress
      -- depends only on planning reaching it.
      if kind == "script-member" then
        return true
      end
      return realValidate(cacheFs, generationId, kind, key, plans)
    end,
  }
  local result = withPatched(patches, function()
    local pool = recordingPool()
    local session = openSession("large-sweep-generation", pool)
    for memberId = 1, corpusSize do
      session:requestJob("script-member", tostring(memberId), "sweep")
    end
    local passes = {}
    for _ = 1, 6 do
      counting.enabled = true
      session:update()
      counting.enabled = false
      passes[#passes + 1] = counting.dependencies + counting.validate
      counting.dependencies = 0
      counting.validate = 0
    end
    local settled = 0
    for memberId = 1, corpusSize do
      local entry = session.byKey["script-member:" .. tostring(memberId)]
      if entry ~= nil and entry.ready then
        settled = settled + 1
      end
    end
    return { passes = passes, settled = settled }
  end)
  for index, nodes in ipairs(result.passes) do
    Assert.isTrue(nodes <= 32, "large-corpus pass " .. tostring(index) .. " stays bounded, got " .. tostring(nodes))
  end
  Assert.isTrue(
    result.settled >= 16,
    "planning reaches sweep demand past fixed per-pass overhead, settled " .. tostring(result.settled)
  )
end

function T.warm_selection_reuses_published_plans_without_compiling_sources()
  local calls = freshCalls()
  local backend = FakeCache.new()
  local realForVersion = CacheFs.forVersion
  local generation = "warm-selection-generation"
  local patches = plannerPatches(calls)
  patches[#patches + 1] = {
    target = CacheFs,
    name = "forVersion",
    replacement = function()
      return realForVersion("heartgold", backend)
    end,
  }
  local result = withPatched(patches, function()
    local messageBankIds = require("romdump.src.digest.ui.FieldMessageCompiler").requiredBankIds()
    local bankId = assert(messageBankIds[1], "the frozen message bank list is not empty")
    local marker = "synthetic-warm-bank-marker"
    local cacheFs = realForVersion("heartgold", backend)
    cacheFs:writeLua(ArtifactState.path("message-bank", tostring(bankId)), {
      schema = ArtifactState.RECEIPT_SCHEMA,
      generationId = generation,
      kind = "message-bank",
      key = tostring(bankId),
      marker = marker,
    })
    cacheFs:write(FieldMessageCache.bankMarkerPath(bankId), marker)
    cacheFs:writeLua(FieldMessageCache.bankPath(bankId), {
      schema = FieldMessageCache.SCHEMA,
      bankId = bankId,
    })
    local firstPool = recordingPool()
    openSession(generation, firstPool)
    for field in pairs(calls) do
      calls[field] = 0
    end
    local pool = recordingPool()
    local session = openSession(generation, pool, 2)
    local snapshot = {
      romFs = calls.romFs,
      index = calls.index,
      script = calls.script,
      audio = calls.audio,
      catalog = calls.catalog,
      presentation = calls.presentation,
    }
    local ready, failure = session:requestJob("message-bank", tostring(bankId), "required")
    local grammarOk = pcall(session.requestJob, session, "bogus-kind", "global", "required")
    return {
      bankId = bankId,
      snapshot = snapshot,
      ready = ready,
      failure = failure,
      submitted = copyList(pool.submitted),
      grammarOk = grammarOk,
    }
  end)
  Assert.notNil(result.bankId, "the warm request targets a genuine required bank")
  Assert.equal(result.snapshot.romFs, 0, "a warm selection opens no source reader")
  Assert.equal(result.snapshot.index, 0, "a warm selection compiles no cell index")
  Assert.equal(result.snapshot.script, 0, "a warm selection plans no scripts")
  Assert.equal(result.snapshot.audio, 0, "a warm selection plans no audio")
  Assert.equal(result.snapshot.catalog, 0, "a warm selection compiles no mon catalog")
  Assert.equal(result.snapshot.presentation, 0, "a warm selection plans no mon presentation")
  Assert.isTrue(result.ready, "a published bank answers ready on the warm selection")
  Assert.isNil(result.failure, "a published bank reports no failure on the warm selection")
  Assert.equal(#result.submitted, 0, "a warm ready answer dispatches no worker job")
  Assert.isFalse(result.grammarOk, "an invalid target is still rejected immediately on the warm selection")
end

function T.exhaustive_scheduling_covers_every_current_family_exactly_once()
  local calls = freshCalls()
  local backend = FakeCache.new()
  local realForVersion = CacheFs.forVersion
  local patches = plannerPatches(calls, { members = scriptMembers(149, 149), icons = { 3 }, portraits = { 12 } })
  patches[#patches + 1] = {
    target = CacheFs,
    name = "forVersion",
    replacement = function()
      return realForVersion("heartgold", backend)
    end,
  }
  patches[#patches + 1] = {
    target = FieldMapDataCompiler,
    name = "newSession",
    replacement = function()
      return {
        compile = function()
          return {}
        end,
        close = function() end,
      }
    end,
  }
  patches[#patches + 1] = {
    target = MapCompilePlan,
    name = "plan",
    replacement = function()
      return { cellPlans = {} }
    end,
  }
  local result = withPatched(patches, function()
    local pool = recordingPool()
    local session = InteractiveCacheBuild.new({
      identity = identity("exhaustive-generation"),
      epoch = 1,
      pool = pool,
      sweepEnabled = true,
    })
    local ready, failure = session:requestMilestone("bootstrap", "required")
    for _, job in ipairs(ArtifactJobs.bootstrapJobs({})) do
      session.byKey[job.kind .. ":" .. job.key].ready = true
    end
    session:update()
    local counts = {}
    for _, entry in ipairs(session.interest) do
      counts[entry.jobKey] = (counts[entry.jobKey] or 0) + 1
    end
    local status = session:status()
    return {
      ready = ready,
      failure = failure,
      counts = counts,
      complete = status.complete,
      enumerationComplete = status.enumerationComplete,
    }
  end)
  Assert.isFalse(result.ready, "bootstrap stays pending until its jobs publish")
  Assert.isNil(result.failure, "bootstrap reports no failure while its jobs are pending")
  Assert.equal(result.counts["mon-summary:global"], 1, "exhaustive scheduling covers the mon summary once")
  Assert.equal(result.counts["items:global"], 1, "exhaustive scheduling covers the item catalog once")
  Assert.equal(result.counts["bag:global"], 1, "exhaustive scheduling covers the bag presentation once")
  Assert.equal(result.counts["message-summary:global"], 1, "exhaustive scheduling covers the message summary once")
  Assert.equal(result.counts["script-summary:global"], 1, "exhaustive scheduling covers the script summary once")
  Assert.isFalse(result.complete, "no complete attestation precedes published output")
  Assert.isTrue(result.enumerationComplete == false, "enumeration is not complete before plans publish")
end

-- Lower-level inventory behavior below: the worker-side assembly over
-- synthetic owners, its persisted round trip, and the closed job-set shape
-- the session and the audit share. Owner planners stay stubbed so no ROM is
-- needed; the frozen map/symbol references and the pure bank/record rules
-- run for real as the independent anchors.

local SYNTHETIC_SHA1 = string.rep("a", 40)

local function syntheticRomFs()
  return {
    metadata = function()
      return { sha1 = SYNTHETIC_SHA1 }
    end,
    version = function()
      return "heartgold"
    end,
    openNarc = function()
      error("synthetic inventory performs no source reads itself", 0)
    end,
    read = function()
      error("synthetic inventory performs no source reads itself", 0)
    end,
    resolvedNarc = function()
      error("synthetic inventory performs no source reads itself", 0)
    end,
  }
end

local function syntheticWorld()
  return {
    maps = { { id = 7 }, { id = 9 } },
    bySymbol = { MAP_SEVEN = 7, MAP_NINE = 9 },
    byId = { [7] = 1, [9] = 2 },
    analysis = {
      mapHeaderCount = 3,
      renderableCount = 2,
      excluded = { { id = 3, symbol = "MAP_NOTHING", reason = "placeholder header" } },
    },
  }
end

local function inventoryPatches(calls, failingMapId)
  local patches = {
    {
      target = WorldManifest,
      name = "compileCatalog",
      replacement = function()
        calls.world = (calls.world or 0) + 1
        return syntheticWorld()
      end,
    },
    {
      target = FieldCellCompiler,
      name = "compileIndex",
      replacement = function()
        calls.index = (calls.index or 0) + 1
        return syntheticIndexBundle()
      end,
    },
    {
      target = ScriptCompiler,
      name = "plan",
      replacement = function()
        calls.script = (calls.script or 0) + 1
        return { members = { { memberId = 4 }, { memberId = 6 } }, generationKey = "synthetic-generation" }
      end,
    },
    {
      target = AudioCompiler,
      name = "plan",
      replacement = function()
        calls.audio = (calls.audio or 0) + 1
        return { index = { version = "heartgold" }, bankPlans = { { bankId = 2 }, { bankId = 5 } } }
      end,
    },
    {
      target = MapCompilePlan,
      name = "plan",
      replacement = function(_, _, mapId)
        calls.mapPlans = (calls.mapPlans or 0) + 1
        if failingMapId ~= nil and mapId == failingMapId then
          error("synthetic planning failure for map " .. tostring(mapId), 0)
        end
        if mapId == 7 then
          return {
            cellPlans = {
              { descriptor = { matrixMemberId = 11, index = 1 } },
              { descriptor = { matrixMemberId = 11, index = 0 } },
            },
          }
        end
        return { cellPlans = {} }
      end,
    },
  }
  return patches
end

local function compileSynthetic(generation, failingMapId)
  local calls = {}
  return withPatched(inventoryPatches(calls, failingMapId), function()
    return SourcePlan.compile(syntheticRomFs(), identity(generation)), calls
  end)
end

function T.inventory_compiles_membership_without_pixel_or_geometry_work()
  local plan, calls = compileSynthetic("assembly-generation")
  Assert.equal(calls.world, 1, "the world catalog compiles once")
  Assert.equal(calls.index, 1, "the cell index compiles once")
  Assert.equal(calls.script, 1, "the script corpus plans once")
  Assert.equal(calls.audio, 1, "the audio closures plan once")
  Assert.equal(calls.mapPlans, 2, "every loadable map plans once")
  local fields = 0
  for _ in pairs(plan) do
    fields = fields + 1
  end
  Assert.equal(fields, 12, "the persisted shape carries exactly its twelve fields")
  Assert.equal(plan.schema, SourcePlan.SCHEMA, "the inventory carries its schema")
  Assert.equal(plan.generationId, "assembly-generation", "the inventory carries its generation")
  Assert.equal(plan.romSha1, SYNTHETIC_SHA1, "the inventory carries its source identity")
  Assert.deepEqual(plan.mapCellKeys[7], { "11-0", "11-1" }, "map cell keys are sorted and unique")
  Assert.deepEqual(plan.mapCellKeys[9], {}, "a map without cells keeps its membership")
  Assert.equal(
    plan.world.analysis.excluded[1].reason,
    "placeholder header",
    "explicit source exclusions keep their reasons"
  )
  Assert.isTrue(SourcePlan.validate(plan, identity("assembly-generation")), "the assembled inventory validates")
end

function T.loadable_map_planning_failure_keeps_its_map_identity()
  local ok, failure = pcall(compileSynthetic, "failure-assembly-generation", 7)
  Assert.isFalse(ok, "a loadable map planning failure fails the inventory")
  Assert.isTrue(tostring(failure):find("7", 1, true) ~= nil, "the failure names its map: " .. tostring(failure))
end

local function stageSynthetic(cacheFs, generation)
  local plan = compileSynthetic(generation)
  local artifact = PreparedArtifact.new({
    cacheFs = cacheFs,
    generationId = generation,
    epoch = 1,
    kind = "source-plan",
    key = "global",
    jobKey = "source-plan:global",
    stageName = "inventory-stage",
  })
  local marker = SourcePlan.stage(artifact, plan)
  Assert.equal(marker, SourcePlan.marker(generation), "staging returns the generation marker")
  artifact:finishSuccess({ marker = marker })
  artifact:publish({
    generationId = generation,
    epoch = 1,
    kind = "source-plan",
    key = "global",
    jobKey = "source-plan:global",
  })
  return plan
end

function T.staged_inventory_reads_back_and_rejects_tampering()
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  local generation = "staged-generation"
  local plan = stageSynthetic(cacheFs, generation)
  local reread = assert(SourcePlan.read(cacheFs, identity(generation)), "the staged inventory reads back")
  Assert.deepEqual(reread.mapCellKeys[7], plan.mapCellKeys[7], "the round trip preserves map membership")
  Assert.deepEqual(reread.messageBankIds, plan.messageBankIds, "the round trip preserves bank membership")
  cacheFs:writeLua(SourcePlan.PATH, { bogus = true })
  local tampered, reason = SourcePlan.read(cacheFs, identity(generation))
  Assert.isNil(tampered, "a tampered inventory is not read as current")
  Assert.notNil(reason, "a tampered inventory names its rejection")
  local foreign, foreignReason = SourcePlan.read(cacheFs, identity("another-generation"))
  Assert.isNil(foreign, "another generation never borrows this inventory")
  Assert.notNil(foreignReason, "a foreign generation names its rejection")
  local missing, missingReason = SourcePlan.read(CacheFs.forVersion("heartgold", FakeCache.new()), identity(generation))
  Assert.isNil(missing, "an empty cache publishes no inventory")
  Assert.notNil(missingReason, "an empty cache names its pending state")
end

function T.field_record_membership_uses_the_source_rule()
  local ids = FieldMapDataCompiler.supportedMapIds()
  Assert.isTrue(#ids > 0, "the source rule keeps supported records")
  local previous = nil
  local seen = {}
  for _, mapId in ipairs(ids) do
    Assert.isTrue(previous == nil or mapId > previous, "supported records ascend without duplicates")
    previous = mapId
    seen[mapId] = true
  end
  Assert.isTrue(seen[firstOrdinaryMapId()] == true, "an ordinary header is supported")
  Assert.isNil(seen[excludedMapId()], "an explicitly excluded header is not supported")
  Assert.equal(ArtifactJobs.sizeClass("source-plan"), "heavy", "the inventory job admits as heavy work")
  Assert.deepEqual(
    ArtifactJobs.dependencies("source-plan", "global", {}),
    {},
    "the inventory job plans no prerequisite"
  )
  Assert.equal(
    ArtifactState.path("source-plan", "global"),
    "data/generated/jobs/source-plan/global.lua",
    "the inventory receipt is namespaced"
  )
end

function T.complete_inventory_covers_every_family_once()
  local plans = {
    messageBankIds = { 219 },
    audioBankIds = { 7 },
    scriptMemberIds = { 149 },
    iconPageIds = { 3 },
    portraitPageIds = { 12 },
    mapDataIds = { 7 },
    mapIds = { 7 },
    mapCellKeys = { [7] = { "12-5" } },
    indexBundle = {
      index = {
        matrices = {
          {
            matrixMemberId = 12,
            cells = {
              { matrixMemberId = 12, index = 5 },
              { matrixMemberId = 12, index = 6 },
            },
          },
        },
      },
    },
  }
  local jobs = ArtifactJobs.completeJobs(plans)
  local counts = {}
  for _, job in ipairs(jobs) do
    counts[job.jobKey] = (counts[job.jobKey] or 0) + 1
    Assert.equal(job.jobKey, job.kind .. ":" .. job.key, "every job carries its canonical identity")
  end
  for _, jobKey in ipairs({
    "source-plan:global",
    "items:global",
    "bag:global",
    "mon-summary:global",
    "message-summary:global",
    "script-summary:global",
    "audio-summary:global",
    "message-bank:219",
    "audio-bank:7",
    "script-member:149",
    "mon-icon-page:3",
    "mon-portrait-page:12",
    "map-data:7",
    "map:7",
    "field-cell:12-5",
    "field-cell:12-6",
  }) do
    Assert.equal(counts[jobKey], 1, "the canonical inventory covers " .. jobKey .. " once")
  end
  local previous = nil
  for _, job in ipairs(jobs) do
    if previous ~= nil then
      Assert.isTrue(
        previous.kind < job.kind or (previous.kind == job.kind and previous.key <= job.key),
        "the canonical inventory is sorted"
      )
    end
    previous = job
  end
end

function T.published_plans_wait_for_mon_layout()
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  local generation = "unlaid-generation"
  local plans, reason = ArtifactJobs.publishedPlans(cacheFs, identity(generation))
  Assert.isNil(plans, "an empty cache publishes no plans")
  Assert.notNil(reason, "an empty cache names its pending state")
  stageSynthetic(cacheFs, generation)
  local partial, partialReason = ArtifactJobs.publishedPlans(cacheFs, identity(generation))
  Assert.isNil(partial, "an inventory without mon layout publishes no plans")
  Assert.notNil(partialReason, "a missing layout names its pending state")
end

function T.loaded_inventory_answers_known_members_and_rejects_unknown_ones()
  local calls = freshCalls()
  local backend = FakeCache.new()
  local cacheFs = CacheFs.forVersion("heartgold", backend)
  stageSynthetic(cacheFs, "loaded-member-generation")
  local realForVersion = CacheFs.forVersion
  local patches = plannerPatches(calls)
  patches[#patches + 1] = {
    target = CacheFs,
    name = "forVersion",
    replacement = function()
      return realForVersion("heartgold", backend)
    end,
  }
  local result = withPatched(patches, function()
    local pool = recordingPool()
    local session = openSession("loaded-member-generation", pool)
    local eligible = firstOrdinaryMapId()
    local readyEligible, failureEligible = session:requestJob("map-data", tostring(eligible), "required")
    local readyPlannedMember, failurePlannedMember = session:requestJob("script-member", "4", "required")
    local readyUnknownMap, failureUnknownMap = session:requestJob("map", "99999", "required")
    local readyUnknownMember, failureUnknownMember = session:requestJob("script-member", "99999", "required")
    local readyUnknownPage, failureUnknownPage = session:requestJob("mon-icon-page", "999", "required")
    return {
      readyEligible = readyEligible,
      failureEligible = failureEligible,
      readyPlannedMember = readyPlannedMember,
      failurePlannedMember = failurePlannedMember,
      readyUnknownMap = readyUnknownMap,
      failureUnknownMap = failureUnknownMap,
      readyUnknownMember = readyUnknownMember,
      failureUnknownMember = failureUnknownMember,
      readyUnknownPage = readyUnknownPage,
      failureUnknownPage = failureUnknownPage,
      enumerationComplete = session:status().enumerationComplete,
      snapshot = {
        romFs = calls.romFs,
        index = calls.index,
        script = calls.script,
        audio = calls.audio,
        catalog = calls.catalog,
        presentation = calls.presentation,
      },
    }
  end)
  Assert.isFalse(result.readyEligible, "a cold record stays pending after adoption")
  Assert.isNil(result.failureEligible, "a cold record reports no failure after adoption")
  Assert.isFalse(result.readyPlannedMember, "an inventoried member stays pending while cold")
  Assert.isNil(result.failurePlannedMember, "an inventoried member is accepted even when the stubbed planner disagrees")
  Assert.isFalse(result.readyUnknownMap, "an unknown map never answers ready")
  Assert.notNil(result.failureUnknownMap, "an unknown map is rejected with its cause")
  Assert.isFalse(result.readyUnknownMember, "an unknown member never answers ready")
  Assert.notNil(result.failureUnknownMember, "an unknown member is rejected with its cause")
  Assert.isFalse(result.readyUnknownPage, "a page without layout membership stays pending")
  Assert.isNil(result.failureUnknownPage, "a page without layout membership reports no failure")
  Assert.isTrue(result.enumerationComplete == false, "enumeration waits for mon page membership")
  Assert.equal(result.snapshot.romFs, 0, "adoption opens no source reader")
  Assert.equal(result.snapshot.index, 0, "adoption compiles no cell index")
  Assert.equal(result.snapshot.script, 0, "adoption plans no scripts")
  Assert.equal(result.snapshot.audio, 0, "adoption plans no audio")
  Assert.equal(result.snapshot.catalog, 0, "adoption compiles no mon catalog")
  Assert.equal(result.snapshot.presentation, 0, "adoption plans no mon presentation")
end

return { tests = T }
