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
    local state, details = stateOf(self, jobKey)
    -- Like the production pool, request and status agree: an accepted
    -- submission without a staged reply reads queued, while a
    -- never-submitted identity reads unknown.
    if state == "unknown" and self.accepted ~= nil and self.accepted[jobKey] then
      return "queued", nil
    end
    return state, details
  end
  function pool:request(job)
    self.submitted[#self.submitted + 1] = job.jobKey
    -- Like the production pool, an accepted submission is at least
    -- queued: only an explicitly staged reply reads differently. A fresh
    -- submission never lingers as an unacknowledged unknown record.
    self.accepted = self.accepted or {}
    self.accepted[job.jobKey] = true
    local state, details = stateOf(self, job.jobKey)
    if state == "unknown" then
      return "queued", nil
    end
    return state, details
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

-- A published warm inventory: valid plan file plus its publication
-- receipt, so the source owner validates ready without worker work.
-- Membership mirrors the requested members so adopted closure does not
-- exclude them.
local function publishWarmSource(cacheFs, generation, firstMember, lastMember)
  local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
  local members = {}
  for memberId = firstMember or 1, lastMember or 0 do
    members[#members + 1] = { memberId = memberId }
  end
  cacheFs:writeLua(SourcePlan.PATH, {
    schema = SourcePlan.SCHEMA,
    versionId = "heartgold",
    romSha1 = string.rep("a", 40),
    generationId = generation,
    producerId = PRODUCER_ID,
    world = {
      maps = { { id = 7 }, { id = 9 } },
      analysis = { excluded = { { id = 3, reason = "placeholder header" } } },
    },
    fieldCellIndexBundle = { index = { matrices = {} }, indexMarker = "synthetic-index-marker" },
    scriptPlan = { members = members, generationKey = "synthetic-generation" },
    audioPlan = { index = { version = "heartgold" }, bankPlans = {} },
    audioIdentity = { romSha1 = string.rep("a", 40), sdatSha1 = string.rep("e", 40), sdatFileId = 11 },
    messageBankIds = FieldMessageCompiler.requiredBankIds(),
    mapDataIds = FieldMapDataCompiler.supportedMapIds(),
    mapCellKeys = { [7] = {}, [9] = {} },
  })
  cacheFs:writeLua(ArtifactState.path("source-plan", "global"), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = generation,
    kind = "source-plan",
    key = "global",
    marker = SourcePlan.marker(generation),
  })
end

local function openSession(generation, pool, epoch)
  return InteractiveCacheBuild.new({
    identity = identity(generation),
    epoch = epoch or 1,
    pool = pool,
  })
end

-- The scheduler trusts inventory membership that is internally coherent:
-- bank and record lists only need to ascend without duplicates so concrete
-- job enumeration stays deterministic. Re-proving the exact producer rule
-- inside validation would reject a coherent inventory for disagreeing with
-- the compiler that produced it.
function T.scheduler_accepts_internally_coherent_membership_without_reproving_its_producer()
  local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
  local generation = "coherent-membership-generation"
  local function warmPlan()
    return {
      schema = SourcePlan.SCHEMA,
      versionId = "heartgold",
      romSha1 = string.rep("a", 40),
      generationId = generation,
      producerId = PRODUCER_ID,
      world = {
        maps = { { id = 7 }, { id = 9 } },
        analysis = { excluded = { { id = 3, reason = "placeholder header" } } },
      },
      fieldCellIndexBundle = { index = { matrices = {} }, indexMarker = "synthetic-index-marker" },
      scriptPlan = { members = { { memberId = 1 } }, generationKey = "synthetic-generation" },
      audioPlan = { index = { version = "heartgold" }, bankPlans = {} },
      audioIdentity = { romSha1 = string.rep("a", 40), sdatSha1 = string.rep("e", 40), sdatFileId = 11 },
      messageBankIds = FieldMessageCompiler.requiredBankIds(),
      mapDataIds = FieldMapDataCompiler.supportedMapIds(),
      mapCellKeys = { [7] = {}, [9] = {} },
    }
  end
  local function trimmed(ids)
    local out = {}
    for index = 1, #ids - 1 do
      out[#out + 1] = ids[index]
    end
    return out
  end
  Assert.isTrue(SourcePlan.validate(warmPlan(), identity(generation)), "the producer inventory validates")
  local alteredBanks = warmPlan()
  alteredBanks.messageBankIds = trimmed(FieldMessageCompiler.requiredBankIds())
  Assert.isTrue(
    SourcePlan.validate(alteredBanks, identity(generation)),
    "the scheduler accepts coherent bank membership without re-proving its producer"
  )
  local alteredRecords = warmPlan()
  alteredRecords.mapDataIds = trimmed(FieldMapDataCompiler.supportedMapIds())
  Assert.isTrue(
    SourcePlan.validate(alteredRecords, identity(generation)),
    "the scheduler accepts coherent record membership without re-proving its producer"
  )
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
    local ready, failure = session:requestMilestone("new-game-intro", "required")
    session:update()
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
  Assert.isFalse(result.ready, "the intro stays pending until the inventory publishes")
  Assert.isNil(result.failure, "the intro reports no failure while the inventory is pending")
  Assert.isTrue(
    contains(result.submitted, "source-plan:global"),
    "intro demand schedules the persisted source inventory job"
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
    session:update()
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
  Assert.isFalse(contains(result.submitted, "source-plan:global"), "record demand carries no inventory prerequisite")
  Assert.isTrue(
    contains(result.submitted, "map-data:" .. tostring(eligible)),
    "the record dispatches its own dependency-local work"
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
  -- Members report readiness only after final dependencies: the source
  -- inventory is published upfront so the pass bounds measure planning,
  -- not missing membership.
  publishWarmSource(realForVersion("heartgold", backend), "bounded-planning-generation", 1, 41)
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
    replacement = function(...)
      if counting.enabled then
        counting.validate = counting.validate + 1
      end
      return realValidate(...)
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
    -- Staged ready replies stand in for worker reuse proof: the source
    -- inventory adopts, members admit to the pool, and each proves out
    -- on a later pass while the pool reports no real progress. Later
    -- passes must re-drive budget-parked entries until every demand
    -- settles through the pool.
    pool.states["source-plan:global"] = "ready"
    local passes = { first }
    local settled = false
    for _ = 1, 12 do
      for _, jobKey in ipairs(pool.submitted) do
        pool.states[jobKey] = "ready"
      end
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
  local requiredAt, sweepAt = nil, nil
  for index, pass in ipairs(result.passes) do
    for position, jobKey in ipairs(pass.order) do
      if jobKey == "script-member:41" and requiredAt == nil then
        requiredAt = { index, position }
      end
      if jobKey == "script-member:1" and sweepAt == nil then
        sweepAt = { index, position }
      end
    end
  end
  Assert.notNil(requiredAt, "the urgent demand is planned during the passes")
  Assert.notNil(sweepAt, "sweep demand is planned during the passes")
  assert(requiredAt ~= nil and sweepAt ~= nil, "planning order needs both demands")
  Assert.isTrue(
    requiredAt[1] < sweepAt[1] or (requiredAt[1] == sweepAt[1] and requiredAt[2] < sweepAt[2]),
    "urgent demand is planned before sweep work"
  )
  for index, pass in ipairs(result.passes) do
    Assert.isTrue(pass.nodes <= 32, "repeat pass " .. tostring(index) .. " stays bounded, got " .. tostring(pass.nodes))
  end
  Assert.isTrue(result.settled, "parked sweep work is re-driven until pool proof settles it")
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
  -- Members report readiness only after final dependencies: the source
  -- inventory is published upfront so the pass bounds measure planning,
  -- not missing membership.
  publishWarmSource(realForVersion("heartgold", backend), "large-sweep-generation", 1, 30000)
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
    replacement = function(...)
      if counting.enabled then
        counting.validate = counting.validate + 1
      end
      return realValidate(...)
    end,
  }
  local result = withPatched(patches, function()
    local pool = recordingPool()
    local session = openSession("large-sweep-generation", pool)
    -- Metadata owners are demanded first, as milestones do: a lazily
    -- registered owner behind thousands of waiters would only take its
    -- FIFO turn after them all. One staged pool reply adopts the
    -- published inventory.
    pool.states["source-plan:global"] = "ready"
    session:requestJob("source-plan", "global", "sweep")
    for _ = 1, 5 do
      session:update()
      if session.sourceLoaded then
        break
      end
    end
    Assert.isTrue(session.sourceLoaded, "the demanded inventory adopts first")
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
      -- Staged ready replies stand in for worker reuse proof so
      -- planning reach, not pool silence, is what the bounds measure.
      for _, jobKey in ipairs(pool.submitted) do
        pool.states[jobKey] = "ready"
      end
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
    local cold, coldFailure = session:requestJob("message-bank", tostring(bankId), "required")
    for _ = 1, 3 do
      session:update()
      for _, jobKey in ipairs(pool.submitted) do
        pool.states[jobKey] = "ready"
      end
    end
    local ready, failure = session:requestJob("message-bank", tostring(bankId), "required")
    local grammarOk = pcall(session.requestJob, session, "bogus-kind", "global", "required")
    return {
      bankId = bankId,
      snapshot = snapshot,
      cold = cold,
      coldFailure = coldFailure,
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
  Assert.isFalse(result.cold, "a newly registered warm interest answers pending until the pump admits it")
  Assert.isNil(result.coldFailure, "registration reports no failure")
  Assert.isTrue(result.ready, "a published bank answers ready once pool proof establishes it")
  Assert.isNil(result.failure, "a published bank reports no failure on the warm selection")
  for _, jobKey in ipairs(result.submitted) do
    Assert.isTrue(
      jobKey == "source-plan:global" or jobKey == "message-bank:" .. tostring(result.bankId),
      "warm demand reaches the pool for worker proof: " .. tostring(jobKey)
    )
  end
  Assert.isFalse(result.grammarOk, "an invalid target is still rejected immediately on the warm selection")
end

function T.demand_enrolls_only_its_roster_without_automatic_summaries()
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
    })
    local ready, failure = session:requestMilestone("bootstrap", "required")
    -- Enrollment is update-owned: the admitted roster drains through the
    -- shared pump slice behind the large static bank fan-out, so wait
    -- until every member is registered before staging readiness. The
    -- scheduling assertions below are unchanged.
    for _ = 1, 60 do
      local registered = true
      for _, job in ipairs(ArtifactJobs.bootstrapJobs()) do
        if session.byKey[job.kind .. ":" .. job.key] == nil then
          registered = false
          break
        end
      end
      if registered then
        break
      end
      session:update()
    end
    for _, job in ipairs(ArtifactJobs.bootstrapJobs()) do
      local entry = session.byKey[job.kind .. ":" .. job.key]
      Assert.notNil(entry, "admitted enrollment registers every bootstrap member")
      entry.ready = true
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
  for _, job in ipairs(ArtifactJobs.bootstrapJobs()) do
    Assert.equal(
      result.counts[job.kind .. ":" .. job.key],
      1,
      "demand enrolls its roster once: " .. job.kind .. ":" .. job.key
    )
  end
  Assert.isNil(result.counts["mon-summary:global"], "bootstrap enrolls no mon summary")
  Assert.isNil(result.counts["items:global"], "bootstrap enrolls no item catalog")
  Assert.isNil(result.counts["bag:global"], "bootstrap enrolls no bag presentation")
  Assert.isNil(result.counts["message-summary:global"], "bootstrap enrolls no message summary")
  Assert.isNil(result.counts["script-summary:global"], "bootstrap enrolls no script summary")
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
      name = "planSource",
      replacement = function()
        calls.audio = (calls.audio or 0) + 1
        return {
          plan = { index = { version = "heartgold" }, bankPlans = { { bankId = 2 }, { bankId = 5 } } },
          identity = { romSha1 = SYNTHETIC_SHA1, sdatSha1 = string.rep("d", 40), sdatFileId = 9 },
        }
      end,
    },
    -- Roster enumeration is topology only: the inventory consults the
    -- cell-key projection per loadable map and never runs full per-map
    -- content planning. The projection keys use the canonical
    -- matrixMemberId:index shape; the inventory keeps its dash-joined
    -- membership.
    {
      target = MapCompilePlan,
      name = "cellKeys",
      replacement = function(_, _, mapId)
        calls.mapKeys = (calls.mapKeys or 0) + 1
        if failingMapId ~= nil and mapId == failingMapId then
          error("synthetic planning failure for map " .. tostring(mapId), 0)
        end
        if mapId == 7 then
          return { "11:1", "11:0" }
        end
        return {}
      end,
    },
    {
      target = MapCompilePlan,
      name = "plan",
      replacement = function()
        error("roster enumeration must not run full per-map content planning", 0)
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

-- A staged inventory becomes adopted only through worker completion: the
-- plan file plus its publication receipt plus the pool reply that releases
-- validation. Fixtures that need adoption model all three facts instead of
-- relying on inventory polling.
local function publishStagedSource(cacheFs, pool, generation)
  cacheFs:writeLua(ArtifactState.path("source-plan", "global"), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = generation,
    kind = "source-plan",
    key = "global",
    marker = SourcePlan.marker(generation),
  })
  pool.states["source-plan:global"] = "ready"
end

function T.inventory_compiles_membership_without_pixel_or_geometry_work()
  local plan, calls = compileSynthetic("assembly-generation")
  Assert.equal(calls.world, 1, "the world catalog compiles once")
  Assert.equal(calls.index, 1, "the cell index compiles once")
  Assert.equal(calls.script, 1, "the script corpus plans once")
  Assert.equal(calls.audio, 1, "the audio closures plan once")
  Assert.equal(calls.mapKeys, 2, "every loadable map enumerates its topology once")
  local fields = 0
  for _ in pairs(plan) do
    fields = fields + 1
  end
  Assert.equal(fields, 13, "the persisted shape carries exactly its thirteen fields")
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
    local coldUnknownMap, coldUnknownMapFailure = session:requestJob("map", "99999", "required")
    local coldUnknownMember, coldUnknownMemberFailure = session:requestJob("script-member", "99999", "required")
    local readyUnknownPage, failureUnknownPage = session:requestJob("mon-icon-page", "999", "required")
    session:update()
    -- One staged pool reply adopts the published inventory; planner
    -- calls below must stay zero throughout.
    pool.states["source-plan:global"] = "ready"
    for _ = 1, 3 do
      session:update()
    end
    local readyUnknownMap, failureUnknownMap = session:requestJob("map", "99999", "required")
    local readyUnknownMember, failureUnknownMember = session:requestJob("script-member", "99999", "required")
    return {
      readyEligible = readyEligible,
      failureEligible = failureEligible,
      readyPlannedMember = readyPlannedMember,
      failurePlannedMember = failurePlannedMember,
      coldUnknownMap = coldUnknownMap,
      coldUnknownMapFailure = coldUnknownMapFailure,
      coldUnknownMember = coldUnknownMember,
      coldUnknownMemberFailure = coldUnknownMemberFailure,
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
  Assert.isFalse(result.coldUnknownMap, "an unknown map stays pending while membership is unknown")
  Assert.isNil(result.coldUnknownMapFailure, "an unknown map reports no failure while membership is unknown")
  Assert.isFalse(result.coldUnknownMember, "an unknown member stays pending while membership is unknown")
  Assert.isNil(result.coldUnknownMemberFailure, "an unknown member reports no failure while membership is unknown")
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

-- Minimal layout/page builders over the real mon writer and asset
-- validators. No commercial bytes are involved.
local function deepCopyPlan(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for field, entry in pairs(value) do
    out[deepCopyPlan(field)] = deepCopyPlan(entry)
  end
  return out
end

local function inventoryPlan(generation, scriptIds)
  local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
  local members = {}
  for _, memberId in ipairs(scriptIds) do
    members[#members + 1] = { memberId = memberId }
  end
  return {
    schema = SourcePlan.SCHEMA,
    versionId = "heartgold",
    romSha1 = string.rep("a", 40),
    generationId = generation,
    producerId = PRODUCER_ID,
    world = {
      maps = { { id = 7 }, { id = 9 } },
      analysis = { excluded = { { id = 3, reason = "placeholder header" } } },
    },
    fieldCellIndexBundle = { index = { matrices = {} }, indexMarker = "synthetic-index-marker" },
    scriptPlan = { members = members, generationKey = "synthetic-generation" },
    audioPlan = { index = { version = "heartgold" }, bankPlans = {} },
    audioIdentity = { romSha1 = string.rep("a", 40), sdatSha1 = string.rep("e", 40), sdatFileId = 11 },
    messageBankIds = FieldMessageCompiler.requiredBankIds(),
    mapDataIds = FieldMapDataCompiler.supportedMapIds(),
    mapCellKeys = { [7] = {}, [9] = {} },
  }
end

local function layoutManifest(schema, imagePath, width, height, cell)
  return {
    schema = schema,
    version = { id = "heartgold", language = "english" },
    pages = {
      [0] = { pageId = 0, image = imagePath, width = width, height = height },
    },
    pageIds = { 0 },
    entries = {
      ["K/f0"] = {
        x = 0,
        y = 0,
        width = cell,
        height = cell,
        frames = { { x = 0, y = 0, width = cell, height = cell, duration = 6 } },
        pageId = 0,
      },
    },
    representative = { "K/f0" },
  }
end

local function iconPagePlan(pageId)
  return {
    pageId = pageId,
    width = 256,
    height = 128,
    cell = 32,
    combos = { { naix = 0, palette = 0, key = "icons-" .. tostring(pageId), selectors = { "K/f0" } } },
    representative = { { selector = "K/f0", x = 0, y = 0, width = 32, height = 32 } },
  }
end

local function portraitPagePlan(pageId)
  return {
    pageId = pageId,
    width = 640,
    height = 320,
    cell = 80,
    combos = {
      {
        narc = "synthetic",
        charMemberId = 0,
        palMemberId = 0,
        key = "portraits-" .. tostring(pageId),
        selectors = { "K/f0" },
      },
    },
    representative = { { selector = "K/f0", x = 0, y = 0, width = 80, height = 80 } },
  }
end

local function minimalCatalog()
  local function zeroCurve()
    local curve = {}
    for level = 1, 100 do
      curve[level] = 0
    end
    return curve
  end
  return {
    schema = "g4-mon-catalog-v3",
    version = { id = "heartgold", language = "english" },
    species = {},
    moves = {},
    abilities = {},
    growthCurves = {
      medium_fast = zeroCurve(),
      erratic = zeroCurve(),
      fluctuating = zeroCurve(),
      medium_slow = zeroCurve(),
      fast = zeroCurve(),
      slow = zeroCurve(),
      unused_6 = zeroCurve(),
      unused_7 = zeroCurve(),
    },
  }
end

local function writeMonReceipt(cacheFs, generation, kind, key, marker)
  cacheFs:writeLua(ArtifactState.path(kind, key), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = generation,
    kind = kind,
    key = key,
    marker = marker,
  })
end

-- Failure to read old private layout data does not block a repaired
-- layout: the repaired membership is adopted once under its unchanged
-- deterministic marker, the waiting portrait exits pending without new
-- marker state, and no repeated layout repair is scheduled.
-- Page adoption is level-eligible, not edge-triggered: source and layout
-- arriving in either order schedule exactly the needed pages and reach the
-- same final closure without a repeat request.
function T.page_adoption_reaches_the_same_closure_in_either_arrival_order()
  local function runOrder(layoutFirst)
    local calls = freshCalls()
    local backend = FakeCache.new()
    local cacheFs = CacheFs.forVersion("heartgold", backend)
    local generation = layoutFirst and "order-layout-generation" or "order-source-generation"
    local realForVersion = CacheFs.forVersion
    local patches = plannerPatches(calls)
    patches[#patches + 1] = {
      target = CacheFs,
      name = "forVersion",
      replacement = function()
        return realForVersion("heartgold", backend)
      end,
    }
    return withPatched(patches, function()
      local MonCache = require("libs.assets.src.MonCache")
      local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
      local function stageLayout()
        local PngWriter = require("libs.assets.src.PngWriter")
        MonCacheWriter.writeCatalog(cacheFs, minimalCatalog(), "order-catalog-marker")
        writeMonReceipt(cacheFs, generation, "mon-catalog", "global", "order-catalog-marker")
        MonCacheWriter.writeLayout(
          cacheFs,
          layoutManifest(MonCache.ICON_MANIFEST_SCHEMA, MonCache.iconPagePath(0), 256, 128, 32),
          layoutManifest(MonCache.PORTRAIT_MANIFEST_SCHEMA, MonCache.portraitPagePath(0), 640, 320, 80),
          "order-layout-marker",
          { iconPages = { [0] = iconPagePlan(0) }, portraitPages = { [0] = portraitPagePlan(0) } },
          generation
        )
        writeMonReceipt(cacheFs, generation, "mon-layout", "global", "order-layout-marker")
        cacheFs:write(
          MonCache.pageImagePath("portraits", 0),
          PngWriter.encode(640, 320, string.rep("\0", 640 * 320 * 4))
        )
        cacheFs:write(MonCache.pageMarkerPath("portraits", 0), "order-portrait-marker-0")
        writeMonReceipt(cacheFs, generation, "mon-portrait-page", "0", "order-portrait-marker-0")
      end
      local pool = recordingPool()
      local session = openSession(generation, pool)
      if layoutFirst then
        stageLayout()
      else
        stageSynthetic(cacheFs, generation)
      end
      pool.states["source-plan:global"] = nil
      pool.states["mon-catalog:global"] = nil
      local ready, failure = session:requestJob("mon-portrait-page", "0", "required")
      Assert.isFalse(ready, "the page stays pending while membership is partial")
      Assert.isNil(failure, "the page reports no failure while membership is partial")
      for _ = 1, 3 do
        session:update()
      end
      Assert.isFalse(session.pagesKnown, "partial membership adopts nothing")
      if layoutFirst then
        stageSynthetic(cacheFs, generation)
      else
        stageLayout()
      end
      -- Worker replies land after staging: flipping a state the pool
      -- already reported would hide the transition the session waits for.
      pool.states["source-plan:global"] = "ready"
      pool.states["mon-catalog:global"] = "ready"
      pool.states["mon-layout:global"] = "ready"
      for _ = 1, 10 do
        session:update()
      end
      Assert.isTrue(session.pagesKnown, "both arrivals adopt page membership")
      Assert.isTrue(contains(session.portraitPageIds, 0), "both arrivals carry the portrait page")
      pool.states["mon-portrait-page:0"] = "ready"
      for _ = 1, 4 do
        session:update()
      end
      local finalReady, finalFailure = session:requestJob("mon-portrait-page", "0", "required")
      Assert.isTrue(finalReady, "both arrivals prove the page ready through the pool")
      Assert.isNil(finalFailure, "the proven page reports no failure")
      local submissions = 0
      for _, jobKey in ipairs(pool.submitted) do
        if jobKey == "mon-portrait-page:0" then
          submissions = submissions + 1
        end
      end
      Assert.equal(submissions, 1, "the adoption admits the waiting page exactly once")
      return { pagesKnown = session.pagesKnown, portraitPages = copyList(session.portraitPageIds) }
    end)
  end
  local sourceFirst = runOrder(false)
  local layoutFirst = runOrder(true)
  Assert.isTrue(sourceFirst.pagesKnown and layoutFirst.pagesKnown, "both orders adopt")
  Assert.deepEqual(sourceFirst.portraitPages, layoutFirst.portraitPages, "both orders reach the same closure")
end

-- A denied adoption step stays runnable: wide pending work cannot starve
-- it, no false scope completes first, and no fresh completion notice is
-- needed for the next update to adopt.
function T.denied_adoption_step_runs_next_update_without_new_notification()
  local calls = freshCalls()
  local backend = FakeCache.new()
  local cacheFs = CacheFs.forVersion("heartgold", backend)
  local generation = "budget-pause-generation"
  stageSynthetic(cacheFs, generation)
  local realForVersion = CacheFs.forVersion
  local patches = plannerPatches(calls)
  patches[#patches + 1] = {
    target = CacheFs,
    name = "forVersion",
    replacement = function()
      return realForVersion("heartgold", backend)
    end,
  }
  withPatched(patches, function()
    local MonCache = require("libs.assets.src.MonCache")
    local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
    local pool = recordingPool()
    local session = openSession(generation, pool)
    session:requestJob("message-summary", "global", "required")
    session:requestJob("mon-portrait-page", "0", "required")
    for _ = 1, 5 do
      session:update()
    end
    Assert.isFalse(session.pagesKnown, "wide work does not invent membership")
    MonCacheWriter.writeCatalog(cacheFs, minimalCatalog(), "pause-catalog-marker")
    writeMonReceipt(cacheFs, generation, "mon-catalog", "global", "pause-catalog-marker")
    pool.states["source-plan:global"] = "ready"
    MonCacheWriter.writeLayout(
      cacheFs,
      layoutManifest(MonCache.ICON_MANIFEST_SCHEMA, MonCache.iconPagePath(0), 256, 128, 32),
      layoutManifest(MonCache.PORTRAIT_MANIFEST_SCHEMA, MonCache.portraitPagePath(0), 640, 320, 80),
      "pause-layout-marker",
      { iconPages = { [0] = iconPagePlan(0) }, portraitPages = { [0] = portraitPagePlan(0) } },
      generation
    )
    writeMonReceipt(cacheFs, generation, "mon-layout", "global", "pause-layout-marker")
    pool.states["mon-catalog:global"] = "ready"
    pool.states["mon-layout:global"] = "ready"
    for _ = 1, 60 do
      session:update()
    end
    Assert.isTrue(session.pagesKnown, "adoption completes without a fresh completion notice")
    local submissions = 0
    for _, jobKey in ipairs(pool.submitted) do
      if jobKey == "mon-portrait-page:0" then
        submissions = submissions + 1
      end
    end
    Assert.equal(submissions, 1, "the adoption enrolls the waiting page exactly once")
    local ready, failure = session:requestJob("message-summary", "global", "required")
    Assert.isFalse(ready, "held banks keep the wide parent pending")
    Assert.isNil(failure, "held banks report no failure")
  end)
end

function T.repaired_layout_with_the_same_marker_is_adopted()
  local MonCache = require("libs.assets.src.MonCache")
  local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
  local generation = "same-marker-generation"
  local backend = FakeCache.new()
  local realForVersion = CacheFs.forVersion
  local cacheFs = realForVersion("heartgold", backend)
  stageSynthetic(cacheFs, generation)
  local catalogMarker = "synthetic-catalog-marker"
  MonCacheWriter.writeCatalog(cacheFs, minimalCatalog(), catalogMarker)
  writeMonReceipt(cacheFs, generation, "mon-catalog", "global", catalogMarker)
  local layoutMarker = "synthetic-layout-marker"
  MonCacheWriter.writeLayout(
    cacheFs,
    layoutManifest(MonCache.ICON_MANIFEST_SCHEMA, MonCache.iconPagePath(0), 256, 128, 32),
    layoutManifest(MonCache.PORTRAIT_MANIFEST_SCHEMA, MonCache.portraitPagePath(0), 640, 320, 80),
    layoutMarker,
    { iconPages = { [0] = iconPagePlan(0) }, portraitPages = { [0] = portraitPagePlan(0) } },
    generation
  )
  writeMonReceipt(cacheFs, generation, "mon-layout", "global", layoutMarker)
  local pagePlanPath = MonCacheWriter.sourcePagePlanPath("portraits", 0)
  local savedRecord = assert(cacheFs:loadLua(pagePlanPath), "the staged page record reads back")
  cacheFs:remove(pagePlanPath)
  local publishedCalls = 0
  local realPublishedPlans = ArtifactJobs.publishedPlans
  ArtifactJobs.publishedPlans = function(...)
    publishedCalls = publishedCalls + 1
    return realPublishedPlans(...)
  end
  local ok, failure = pcall(function()
    withPatched({
      {
        target = CacheFs,
        name = "forVersion",
        replacement = function()
          return realForVersion("heartgold", backend)
        end,
      },
    }, function()
      local pool = recordingPool()
      local session = openSession(generation, pool)
      local ready, err = session:requestJob("mon-portrait-page", "0", "required")
      Assert.isFalse(ready, "the portrait stays pending while its layout record is missing")
      Assert.isNil(err, "the portrait reports no failure while its layout is pending")
      pool.states["source-plan:global"] = "ready"
      pool.states["mon-catalog:global"] = "ready"
      session:update()
      session:update()
      Assert.isFalse(session.pagesKnown, "a layout with a missing page record is never adopted")
      local missing, reason = ArtifactJobs.publishedPlans(cacheFs, identity(generation))
      Assert.isNil(missing, "the damaged layout publishes no plans")
      Assert.notNil(reason, "the damaged layout names its pending state")
      cacheFs:writeLua(pagePlanPath, savedRecord)
      pool.states["mon-layout:global"] = "ready"
      local repaired, repairReason = ArtifactJobs.publishedPlans(cacheFs, identity(generation))
      Assert.notNil(repaired, "the repaired layout publishes plans: " .. tostring(repairReason))
      for _ = 1, 4 do
        session:update()
      end
      Assert.isTrue(session.pagesKnown, "the identical repaired marker is adopted once")
      Assert.isTrue(contains(session.portraitPageIds, 0), "the repaired membership carries its portrait page")
      Assert.equal(
        cacheFs:read(MonCache.layoutMarkerPath()),
        layoutMarker,
        "adoption never mutates the deterministic marker"
      )
      local layoutSubmissions = 0
      for _, jobKey in ipairs(pool.submitted) do
        if jobKey == "mon-layout:global" then
          layoutSubmissions = layoutSubmissions + 1
        end
      end
      Assert.isTrue(layoutSubmissions <= 1, "no repeated layout repair is scheduled")
      local again, againFailure = session:requestJob("mon-portrait-page", "0", "required")
      Assert.isFalse(again, "the portrait exits pending while its page payload is cold")
      Assert.isNil(againFailure, "the adopted portrait reports no failure")
    end)
  end)
  ArtifactJobs.publishedPlans = realPublishedPlans
  if not ok then
    error(failure, 0)
  end
end

-- No weak source-plan shortcut certifies a record the reader rejects:
-- every malformed staged record is rejected by both the authoritative
-- reader and the readiness dispatcher, exactly one normal repair becomes
-- eligible, and a valid record stays reusable without worker work.
function T.source_readiness_agrees_with_the_authoritative_reader()
  local generation = "agreement-generation"
  local valid = compileSynthetic(generation)
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  cacheFs:writeLua(SourcePlan.PATH, valid)
  cacheFs:writeLua(ArtifactState.path("source-plan", "global"), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = generation,
    kind = "source-plan",
    key = "global",
    marker = SourcePlan.marker(generation),
  })
  local cases = {
    missingWorld = function(record)
      record.world = nil
    end,
    wrongProducer = function(record)
      record.producerId = "d" .. string.rep("4", 64)
    end,
    wrongVersion = function(record)
      record.versionId = "soulsilver"
    end,
    scalarWorld = function(record)
      record.world = "not-a-table"
    end,
    scalarScript = function(record)
      record.scriptPlan = "not-a-table"
    end,
    audioWithoutBanks = function(record)
      record.audioPlan = { index = { version = "heartgold" } }
    end,
    audioWithoutIdentity = function(record)
      record.audioIdentity = nil
    end,
    audioScalarIdentity = function(record)
      record.audioIdentity = "not-a-table"
    end,
    audioIdentityExtraField = function(record)
      record.audioIdentity.extra = "unexpected"
    end,
    audioIdentityWrongRom = function(record)
      record.audioIdentity.romSha1 = string.rep("b", 40)
    end,
    audioIdentityBadDigest = function(record)
      record.audioIdentity.sdatSha1 = "too-short"
    end,
    audioIdentityBadFileId = function(record)
      record.audioIdentity.sdatFileId = -1
    end,
    duplicateWorldMap = function(record)
      record.world.maps = { { id = 7 }, { id = 7 } }
    end,
    nonCanonicalCellKey = function(record)
      record.mapCellKeys[7] = { "11-9" }
    end,
  }
  for name, tamper in pairs(cases) do
    local candidate = deepCopyPlan(valid)
    tamper(candidate)
    cacheFs:writeLua(SourcePlan.PATH, candidate)
    local readOk, reread, readReason = pcall(SourcePlan.read, cacheFs, identity(generation))
    Assert.isTrue(readOk, "a damaged record is rejected, never raises: " .. name)
    Assert.isNil(reread, "the reader rejects the damaged record: " .. name)
    Assert.notNil(readReason, "the reader names its rejection: " .. name)
    Assert.isFalse(
      ArtifactJobs.validate(cacheFs, generation, "source-plan", "global", {}, identity(generation)),
      "the dispatcher agrees with the reader: " .. name
    )
  end

  -- Exactly one normal source-plan repair becomes eligible for a damaged
  -- record, and a valid record stays reusable without worker work.
  local backend = FakeCache.new()
  local realForVersion = CacheFs.forVersion
  local sharedFs = realForVersion("heartgold", backend)
  sharedFs:writeLua(SourcePlan.PATH, deepCopyPlan(valid))
  local tampered = deepCopyPlan(valid)
  tampered.world = "not-a-table"
  sharedFs:writeLua(SourcePlan.PATH, tampered)
  sharedFs:writeLua(ArtifactState.path("source-plan", "global"), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = generation,
    kind = "source-plan",
    key = "global",
    marker = SourcePlan.marker(generation),
  })
  withPatched({
    {
      target = CacheFs,
      name = "forVersion",
      replacement = function()
        return realForVersion("heartgold", backend)
      end,
    },
  }, function()
    local pool = recordingPool()
    local session = openSession(generation, pool)
    session:requestJob("script-member", "4", "required")
    for _ = 1, 3 do
      session:update()
    end
    local repairs = 0
    for _, jobKey in ipairs(pool.submitted) do
      if jobKey == "source-plan:global" then
        repairs = repairs + 1
      end
    end
    Assert.equal(repairs, 1, "exactly one normal source-plan repair becomes eligible")
  end)
  sharedFs:writeLua(SourcePlan.PATH, valid)
  withPatched({
    {
      target = CacheFs,
      name = "forVersion",
      replacement = function()
        return realForVersion("heartgold", backend)
      end,
    },
  }, function()
    local pool = recordingPool()
    pool.states["source-plan:global"] = "ready"
    local session = openSession(generation, pool)
    session:requestJob("script-member", "4", "required")
    for _ = 1, 3 do
      session:update()
    end
    Assert.isTrue(session.sourceLoaded, "the valid record is adopted and reusable")
    local inventorySubmissions = 0
    for _, jobKey in ipairs(pool.submitted) do
      if jobKey == "source-plan:global" then
        inventorySubmissions = inventorySubmissions + 1
      end
    end
    Assert.equal(inventorySubmissions, 1, "adoption admits the inventory exactly once")
  end)
end

-- One budget covers request-originated and completion-originated work:
-- public requests admit no planning nodes, each update admits at most 32
-- nodes under a deterministic slice, work resumes without redoing an
-- unbounded prefix, required demand proceeds before sweep work, and an
-- idle pool never prevents warm settlement.
function T.one_budget_covers_request_and_completion_work()
  local backend = FakeCache.new()
  local realForVersion = CacheFs.forVersion
  local sharedFs = realForVersion("heartgold", backend)
  local generation = "shared-budget-generation"
  local members = {}
  for memberId = 1, 61 do
    members[#members + 1] = memberId
  end
  sharedFs:writeLua(SourcePlan.PATH, inventoryPlan(generation, members))
  sharedFs:writeLua(ArtifactState.path("source-plan", "global"), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = generation,
    kind = "source-plan",
    key = "global",
    marker = SourcePlan.marker(generation),
  })
  local realDependencies = ArtifactJobs.dependencies
  local realValidate = ArtifactJobs.validate
  local counting = { enabled = false, dependencies = 0, validate = 0, order = {} }
  local patches = {
    {
      target = CacheFs,
      name = "forVersion",
      replacement = function()
        return realForVersion("heartgold", backend)
      end,
    },
    {
      target = ArtifactJobs,
      name = "dependencies",
      replacement = function(kind, key, plans)
        if counting.enabled then
          counting.dependencies = counting.dependencies + 1
          counting.order[#counting.order + 1] = kind .. ":" .. key
        end
        return realDependencies(kind, key, plans)
      end,
    },
    {
      target = ArtifactJobs,
      name = "validate",
      replacement = function(...)
        if counting.enabled then
          counting.validate = counting.validate + 1
        end
        return realValidate(...)
      end,
    },
  }
  local realLove = rawget(_G, "love")
  local result = withPatched(patches, function()
    local ticks = 0
    rawset(_G, "love", {
      timer = {
        getTime = function()
          ticks = ticks + 1
          return ticks * 0.0001
        end,
      },
    })
    local ok, first = pcall(function()
      local pool = recordingPool()
      -- Staged ready replies stand in for worker reuse proof, so every
      -- admitted demand settles through the pool within the budget.
      pool.states["source-plan:global"] = "ready"
      for memberId = 1, 61 do
        pool.states["script-member:" .. tostring(memberId)] = "ready"
      end
      local session = openSession(generation, pool)
      counting.enabled = true
      for memberId = 1, 60 do
        session:requestJob("script-member", tostring(memberId), "sweep")
      end
      session:requestJob("script-member", "61", "required")
      local publicNodes = counting.dependencies + counting.validate
      counting.enabled = false
      Assert.equal(publicNodes, 0, "public requests admit no planning nodes")
      local passes = {}
      local firstSnapshot = nil
      for _ = 1, 12 do
        counting.dependencies, counting.validate, counting.order = 0, 0, {}
        counting.enabled = true
        session:update()
        counting.enabled = false
        passes[#passes + 1] = counting.dependencies + counting.validate
        if firstSnapshot == nil then
          local sweepPending = 0
          for memberId = 1, 60 do
            local entry = session.byKey["script-member:" .. tostring(memberId)]
            if entry == nil or not entry.ready then
              sweepPending = sweepPending + 1
            end
          end
          firstSnapshot = {
            requiredReady = session.byKey["script-member:61"] ~= nil
              and session.byKey["script-member:61"].ready == true,
            sweepPending = sweepPending,
          }
        end
      end
      local settled = 0
      for memberId = 1, 61 do
        local entry = session.byKey["script-member:" .. tostring(memberId)]
        if entry ~= nil and entry.ready then
          settled = settled + 1
        end
      end
      return { passes = passes, first = firstSnapshot, settled = settled }
    end)
    rawset(_G, "love", realLove)
    if not ok then
      error(first, 0)
    end
    return first
  end)
  for index, nodes in ipairs(result.passes) do
    Assert.isTrue(
      nodes <= 32,
      "budgeted pass " .. tostring(index) .. " admits at most 32 nodes, got " .. tostring(nodes)
    )
  end
  Assert.isTrue(result.first.requiredReady, "required demand settles first under the shared budget")
  Assert.isTrue(result.first.sweepPending > 0, "sweep work resumes across updates instead of finishing in one prefix")
  Assert.equal(result.settled, 61, "every demand settles with an idle pool")
end

-- A syntactically valid but unsupported member never becomes an invented
-- compile job: it stays pending while membership is unknown, then settles
-- with a source-exclusion disposition once the inventory is adopted.
function T.unknown_member_stays_pending_until_membership_is_known()
  local generation = "unknown-member-generation"
  local backend = FakeCache.new()
  local realForVersion = CacheFs.forVersion
  local cacheFs = realForVersion("heartgold", backend)
  local staged = compileSynthetic(generation)
  withPatched({
    {
      target = CacheFs,
      name = "forVersion",
      replacement = function()
        return realForVersion("heartgold", backend)
      end,
    },
  }, function()
    local pool = recordingPool()
    local session = openSession(generation, pool)
    local ready, failure = session:requestJob("script-member", "99999", "required")
    Assert.isFalse(ready, "an unknown member stays pending while membership is unknown")
    Assert.isNil(failure, "an unknown member reports no failure while membership is unknown")
    cacheFs:writeLua(SourcePlan.PATH, staged)
    publishStagedSource(cacheFs, pool, generation)
    for _ = 1, 3 do
      session:update()
    end
    Assert.isTrue(session.sourceLoaded, "the inventory is adopted")
    for _, jobKey in ipairs(pool.submitted) do
      Assert.isTrue(jobKey ~= "script-member:99999", "an unsupported member never becomes a compile job")
    end
    local excluded, excludedFailure = session:requestJob("script-member", "99999", "required")
    Assert.isFalse(excluded, "an unsupported member never answers ready")
    Assert.isTrue(
      tostring(excludedFailure):find("99999", 1, true) ~= nil,
      "the exclusion names its member: " .. tostring(excludedFailure)
    )
    local known, knownFailure = session:requestJob("script-member", "4", "required")
    Assert.isFalse(known, "an inventoried member stays pending while cold")
    Assert.isNil(knownFailure, "an inventoried member is accepted: " .. tostring(knownFailure))
  end)
end

-- Real session demand against a corrupted page with valid current
-- source/layout prerequisites: only that page is submitted for repair,
-- valid siblings stay reused, and the summary cannot answer ready until
-- the repaired page validates.
function T.corrupted_page_gets_targeted_repair_while_siblings_reuse()
  local MonCache = require("libs.assets.src.MonCache")
  local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
  local PngWriter = require("libs.assets.src.PngWriter")
  local generation = "corrupted-page-generation"
  local backend = FakeCache.new()
  local realForVersion = CacheFs.forVersion
  local cacheFs = realForVersion("heartgold", backend)
  local catalogMarker = "synthetic-catalog-marker"
  MonCacheWriter.writeCatalog(cacheFs, minimalCatalog(), catalogMarker)
  writeMonReceipt(cacheFs, generation, "mon-catalog", "global", catalogMarker)
  local layoutMarker = "synthetic-layout-marker"
  local icons = layoutManifest(MonCache.ICON_MANIFEST_SCHEMA, MonCache.iconPagePath(0), 256, 128, 32)
  icons.pages[1] = { pageId = 1, image = MonCache.iconPagePath(1), width = 256, height = 128 }
  icons.pageIds = { 0, 1 }
  MonCacheWriter.writeLayout(
    cacheFs,
    icons,
    layoutManifest(MonCache.PORTRAIT_MANIFEST_SCHEMA, MonCache.portraitPagePath(0), 640, 320, 80),
    layoutMarker,
    {
      iconPages = { [0] = iconPagePlan(0), [1] = iconPagePlan(1) },
      portraitPages = { [0] = portraitPagePlan(0) },
    },
    generation
  )
  writeMonReceipt(cacheFs, generation, "mon-layout", "global", layoutMarker)
  local function publishIconPage(pageId)
    local marker = "synthetic-icon-marker-" .. tostring(pageId)
    cacheFs:write(MonCache.pageImagePath("icons", pageId), PngWriter.encode(256, 128, string.rep("\0", 256 * 128 * 4)))
    cacheFs:write(MonCache.pageMarkerPath("icons", pageId), marker)
    writeMonReceipt(cacheFs, generation, "mon-icon-page", tostring(pageId), marker)
  end
  publishIconPage(0)
  publishIconPage(1)
  local portraitMarker = "synthetic-portrait-marker-0"
  cacheFs:write(MonCache.pageImagePath("portraits", 0), PngWriter.encode(640, 320, string.rep("\0", 640 * 320 * 4)))
  cacheFs:write(MonCache.pageMarkerPath("portraits", 0), portraitMarker)
  writeMonReceipt(cacheFs, generation, "mon-portrait-page", "0", portraitMarker)
  cacheFs:remove(MonCache.pageImagePath("icons", 1))
  withPatched({
    {
      target = CacheFs,
      name = "forVersion",
      replacement = function()
        return realForVersion("heartgold", backend)
      end,
    },
  }, function()
    local pool = recordingPool()
    local session = openSession(generation, pool)
    -- Mon prerequisites prove through staged pool replies; page
    -- adoption is already settled by the fixture.
    pool.states["mon-catalog:global"] = "ready"
    pool.states["mon-layout:global"] = "ready"
    pool.states["mon-portrait-page:0"] = "ready"
    session.sourceLoaded = true
    session.pagesKnown = true
    local adopted = {
      messageBankIds = {},
      audioBankIds = {},
      scriptMemberIds = {},
      iconPageIds = { 0, 1 },
      portraitPageIds = { 0 },
      mapDataIds = {},
      mapIds = {},
      mapCellKeys = {},
    }
    session.adopted = adopted
    session.messageBankIds = {}
    session.audioBankIds = {}
    session.scriptMemberIds = {}
    session.iconPageIds = { 0, 1 }
    session.portraitPageIds = { 0 }
    session.mapDataIds = {}
    session.mapIds = {}
    session.mapCellKeys = {}
    -- The fixture models a post-adoption session: source membership is
    -- settled, so the source inventory reads ready without worker work.
    local sourcePlanEntry = {
      kind = "source-plan",
      key = "global",
      jobKey = "source-plan:global",
      urgency = "sweep",
      priority = 100,
      submitted = false,
      ready = true,
      failure = nil,
      failureClass = nil,
      causeJobKey = nil,
      poolState = nil,
      phase = "ready",
      await = nil,
      finalDeps = {},
      depsFinal = true,
      depIndex = 1,
      pendingDeps = {},
      propagateIndex = nil,
      retryPending = false,
    }
    session.byKey["source-plan:global"] = sourcePlanEntry
    session.interest[#session.interest + 1] = sourcePlanEntry
    session:requestJob("mon-icon-page", "0", "required")
    session:requestJob("mon-icon-page", "1", "required")
    session:requestJob("mon-summary", "global", "required")
    local function submissions(jobKey)
      local count = 0
      for _, submitted in ipairs(pool.submitted) do
        if submitted == jobKey then
          count = count + 1
        end
      end
      return count
    end
    -- Both pages admit once each for worker reuse proof; the worker
    -- decides which needs repair, so admission is never the repair
    -- signal. A starved wall-clock slice may spend early pumps on
    -- roster construction, so poll boundedly for both admissions.
    for _ = 1, 25 do
      session:update()
      if submissions("mon-icon-page:0") >= 1 and submissions("mon-icon-page:1") >= 1 then
        break
      end
    end
    for _ = 1, 3 do
      session:update()
    end
    Assert.equal(submissions("mon-icon-page:0"), 1, "the valid sibling admits once for worker proof")
    Assert.equal(submissions("mon-icon-page:1"), 1, "the corrupted page admits once for worker proof")
    local summaryReady, summaryFailure = session:requestJob("mon-summary", "global", "required")
    Assert.isFalse(summaryReady, "the summary cannot answer ready while its page is unproven")
    Assert.isNil(summaryFailure, "the waiting summary reports no failure")
    -- The healthy sibling proves out while the corrupted page waits for
    -- its repair: targeted readiness, not targeted admission.
    pool.states["mon-icon-page:0"] = "ready"
    for _ = 1, 3 do
      session:update()
    end
    Assert.equal(submissions("mon-icon-page:0"), 1, "proof never rebuilds the healthy sibling")
    Assert.equal(submissions("mon-icon-page:1"), 1, "the unproven page waits for its repair")
    local stillWaiting, stillWaitingFailure = session:requestJob("mon-summary", "global", "required")
    Assert.isFalse(stillWaiting, "the summary waits for the corrupted page")
    Assert.isNil(stillWaitingFailure, "the waiting summary reports no failure")
    publishIconPage(1)
    pool.states["mon-icon-page:1"] = "ready"
    for _ = 1, 3 do
      session:update()
    end
    Assert.equal(submissions("mon-icon-page:0"), 1, "repair never rebuilds the healthy sibling")
    Assert.equal(submissions("mon-icon-page:1"), 1, "repair proves the corrupted page exactly once")
    Assert.equal(submissions("mon-summary:global"), 1, "the summary dispatches once its repaired page proves")
  end)
end

-- Registration must not certify an undiscovered roster: the intro answers
-- pending without failure before any source membership is known, and no
-- successful milestone record is published from that undiscovered set.
-- (Audio/bank membership finalizes only after source adoption, covered by
-- the adopted-plan tests.)
function T.new_game_intro_registration_certifies_nothing_while_source_is_unknown()
  local calls = freshCalls()
  local backend = FakeCache.new()
  local cacheFs = CacheFs.forVersion("heartgold", backend)
  stageSynthetic(cacheFs, "discovery-intro-generation")
  local realForVersion = CacheFs.forVersion
  local patches = plannerPatches(calls)
  patches[#patches + 1] = {
    target = CacheFs,
    name = "forVersion",
    replacement = function()
      return realForVersion("heartgold", backend)
    end,
  }
  withPatched(patches, function()
    local pool = recordingPool()
    local session = openSession("discovery-intro-generation", pool)
    local again, againFailure = session:requestMilestone("new-game-intro", "required")
    Assert.isFalse(again, "an undiscovered roster never answers ready")
    Assert.isNil(againFailure, "an undiscovered roster reports no failure")
    Assert.isFalse(session:status().settled, "an undiscovered scope never settles")
    Assert.isNil(session.recorded["new-game-intro"], "no successful milestone is recorded from an undiscovered roster")
  end)
end

-- Failed discovery terminates instead of waiting forever: a failed source
-- inventory ends the intro with the original prerequisite cause, never as
-- an unsupported-source claim.
function T.failed_source_discovery_ends_the_intro_with_its_cause()
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
  withPatched(patches, function()
    local pool = recordingPool()
    local session = openSession("failed-discovery-generation", pool)
    session:requestMilestone("new-game-intro", "required")
    -- Prerequisite submission is paced by the shared planning budget:
    -- a starved wall-clock slice may spend the first pump on roster
    -- construction, so poll boundedly for submission instead of
    -- assuming it lands on exactly one update.
    for _ = 1, 25 do
      session:update()
      if contains(pool.submitted, "source-plan:global") then
        break
      end
    end
    Assert.isTrue(contains(pool.submitted, "source-plan:global"), "intro demand schedules the source inventory")
    pool.states["source-plan:global"] = { state = "failed", details = { error = "synthetic inventory fault" } }
    for _ = 1, 5 do
      session:update()
    end
    local ready, failure = session:requestMilestone("new-game-intro", "required")
    Assert.isFalse(ready, "the intro never succeeds behind a failed inventory")
    Assert.notNil(failure, "the failed discovery terminates the scope instead of waiting")
    Assert.isTrue(
      tostring(failure):find("source-plan:global", 1, true) ~= nil,
      "the scope names its failed prerequisite: " .. tostring(failure)
    )
    Assert.isTrue(session:status().settled, "a failed discovery settles terminally")
  end)
end

-- Failed layout discovery also terminates: a failed mon-layout ends an
-- explicit layout request with the original prerequisite cause instead of
-- waiting, and the session settles terminally around it.
function T.failed_layout_discovery_ends_layout_demand_with_its_cause()
  local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
  local generation = "failed-layout-generation"
  local calls = freshCalls()
  local backend = FakeCache.new()
  local realForVersion = CacheFs.forVersion
  local cacheFs = realForVersion("heartgold", backend)
  stageSynthetic(cacheFs, generation)
  local catalogMarker = "synthetic-catalog-marker"
  MonCacheWriter.writeCatalog(cacheFs, minimalCatalog(), catalogMarker)
  writeMonReceipt(cacheFs, generation, "mon-catalog", "global", catalogMarker)
  local patches = plannerPatches(calls)
  patches[#patches + 1] = {
    target = CacheFs,
    name = "forVersion",
    replacement = function()
      return realForVersion("heartgold", backend)
    end,
  }
  withPatched(patches, function()
    local pool = recordingPool()
    local session = openSession(generation, pool)
    -- Layout demand schedules only after source adoption: the intro pulls
    -- the inventory first, then the layout is demanded explicitly.
    session:requestMilestone("new-game-intro", "required")
    pool.states["source-plan:global"] = "ready"
    for _ = 1, 25 do
      session:update()
      if session.sourceLoaded then
        break
      end
    end
    Assert.isTrue(session.sourceLoaded, "the staged inventory adopts first")
    -- The layout depends on the catalog: drive both explicitly.
    session:requestJob("mon-catalog", "global", "required")
    pool.states["mon-catalog:global"] = "ready"
    local cold, coldFailure = session:requestJob("mon-layout", "global", "required")
    Assert.isFalse(cold, "the layout starts pending")
    Assert.isNil(coldFailure, "the layout reports no failure while pending")
    for _ = 1, 25 do
      session:update()
      if contains(pool.submitted, "mon-layout:global") then
        break
      end
    end
    Assert.isTrue(contains(pool.submitted, "mon-layout:global"), "layout demand schedules layout work")
    pool.states["mon-layout:global"] = { state = "failed", details = { error = "synthetic layout fault" } }
    for _ = 1, 5 do
      session:update()
    end
    local ready, failure = session:requestJob("mon-layout", "global", "required")
    Assert.isFalse(ready, "the layout never succeeds behind a failed compile")
    Assert.notNil(failure, "the failed layout terminates the demand instead of waiting")
    Assert.isTrue(
      tostring(failure):find("mon-layout:global", 1, true) ~= nil,
      "the demand names its failed prerequisite: " .. tostring(failure)
    )
    Assert.isTrue(session:status().settled, "a failed discovery settles terminally")
  end)
end
-- One request suffices for deferred support: a syntactically valid map that
-- is absent from the later inventory settles to a source exclusion through
-- updates alone, without a second request and without worker dispatch.
function T.unsupported_map_is_excluded_by_updates_after_late_adoption()
  local generation = "late-map-generation"
  local backend = FakeCache.new()
  local realForVersion = CacheFs.forVersion
  local cacheFs = realForVersion("heartgold", backend)
  withPatched({
    {
      target = CacheFs,
      name = "forVersion",
      replacement = function()
        return realForVersion("heartgold", backend)
      end,
    },
  }, function()
    local pool = recordingPool()
    local session = openSession(generation, pool)
    local ready, failure = session:requestJob("map", "99999", "required")
    Assert.isFalse(ready, "an unknown map stays pending while membership is unknown")
    Assert.isNil(failure, "an unknown map reports no failure while membership is unknown")
    local staged = compileSynthetic(generation)
    cacheFs:writeLua(SourcePlan.PATH, staged)
    publishStagedSource(cacheFs, pool, generation)
    for _ = 1, 5 do
      session:update()
    end
    Assert.isTrue(session.sourceLoaded, "the late inventory is adopted")
    local row = nil
    for _, item in ipairs(session:outcomes()) do
      if item.jobKey == "map:99999" then
        row = item
      end
    end
    assert(row, "the deferred map keeps its canonical outcome row")
    Assert.equal(row.state, "failed", "the unsupported map settles instead of parking forever")
    Assert.equal(row.failureClass, "source-exclusion", "late absence is a source exclusion")
    Assert.isTrue(
      tostring(row.error):find("99999", 1, true) ~= nil,
      "the exclusion names its map: " .. tostring(row.error)
    )
    for _, jobKey in ipairs(pool.submitted) do
      Assert.isTrue(jobKey ~= "map:99999", "an unsupported map never reaches a worker")
    end
  end)
end

-- The same owner rule covers a missing canonical cell: it settles to a
-- source exclusion once the source inventory is known, without a second
-- request and without worker dispatch.
function T.unsupported_cell_is_excluded_by_updates_after_late_adoption()
  local generation = "late-cell-generation"
  local backend = FakeCache.new()
  local realForVersion = CacheFs.forVersion
  local cacheFs = realForVersion("heartgold", backend)
  withPatched({
    {
      target = CacheFs,
      name = "forVersion",
      replacement = function()
        return realForVersion("heartgold", backend)
      end,
    },
  }, function()
    local pool = recordingPool()
    local session = openSession(generation, pool)
    local ready, failure = session:requestJob("field-cell", "99-99", "required")
    Assert.isFalse(ready, "an unknown cell stays pending while membership is unknown")
    Assert.isNil(failure, "an unknown cell reports no failure while membership is unknown")
    local staged = compileSynthetic(generation)
    cacheFs:writeLua(SourcePlan.PATH, staged)
    publishStagedSource(cacheFs, pool, generation)
    for _ = 1, 5 do
      session:update()
    end
    Assert.isTrue(session.sourceLoaded, "the late inventory is adopted")
    local row = nil
    for _, item in ipairs(session:outcomes()) do
      if item.jobKey == "field-cell:99-99" then
        row = item
      end
    end
    assert(row, "the deferred cell keeps its canonical outcome row")
    Assert.equal(row.state, "failed", "the unsupported cell settles instead of parking forever")
    Assert.equal(row.failureClass, "source-exclusion", "late absence is a source exclusion")
    for _, jobKey in ipairs(pool.submitted) do
      Assert.isTrue(jobKey ~= "field-cell:99-99", "an unsupported cell never reaches a worker")
    end
  end)
end

-- The same owner rule covers a missing portrait page: it settles to a
-- source exclusion once the layout is known, without a second request
-- and without worker dispatch.
function T.unsupported_portrait_page_is_excluded_by_updates_after_adoption()
  local MonCache = require("libs.assets.src.MonCache")
  local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
  local generation = "late-page-generation"
  local backend = FakeCache.new()
  local realForVersion = CacheFs.forVersion
  local cacheFs = realForVersion("heartgold", backend)
  stageSynthetic(cacheFs, generation)
  local catalogMarker = "synthetic-catalog-marker"
  MonCacheWriter.writeCatalog(cacheFs, minimalCatalog(), catalogMarker)
  writeMonReceipt(cacheFs, generation, "mon-catalog", "global", catalogMarker)
  local layoutMarker = "synthetic-layout-marker"
  MonCacheWriter.writeLayout(
    cacheFs,
    layoutManifest(MonCache.ICON_MANIFEST_SCHEMA, MonCache.iconPagePath(0), 256, 128, 32),
    layoutManifest(MonCache.PORTRAIT_MANIFEST_SCHEMA, MonCache.portraitPagePath(0), 640, 320, 80),
    layoutMarker,
    { iconPages = { [0] = iconPagePlan(0) }, portraitPages = { [0] = portraitPagePlan(0) } },
    generation
  )
  writeMonReceipt(cacheFs, generation, "mon-layout", "global", layoutMarker)
  withPatched({
    {
      target = CacheFs,
      name = "forVersion",
      replacement = function()
        return realForVersion("heartgold", backend)
      end,
    },
  }, function()
    local pool = recordingPool()
    local session = openSession(generation, pool)
    local ready, failure = session:requestJob("mon-portrait-page", "7", "required")
    Assert.isFalse(ready, "an unknown page stays pending while membership is unknown")
    Assert.isNil(failure, "an unknown page reports no failure while membership is unknown")
    pool.states["source-plan:global"] = "ready"
    pool.states["mon-catalog:global"] = "ready"
    pool.states["mon-layout:global"] = "ready"
    for _ = 1, 6 do
      session:update()
    end
    Assert.isTrue(session.pagesKnown, "the staged layout is adopted")
    local row = nil
    for _, item in ipairs(session:outcomes()) do
      if item.jobKey == "mon-portrait-page:7" then
        row = item
      end
    end
    assert(row, "the deferred page keeps its canonical outcome row")
    Assert.equal(row.state, "failed", "the unsupported page settles instead of parking forever")
    Assert.equal(row.failureClass, "source-exclusion", "late absence is a source exclusion")
    for _, jobKey in ipairs(pool.submitted) do
      Assert.isTrue(jobKey ~= "mon-portrait-page:7", "an unsupported page never reaches a worker")
    end
  end)
end

-- Unknown is not prematurely excluded: a supported deferred map stays
-- pending until its membership is known, then follows its declared
-- dependencies without any invented exclusion.
function T.supported_deferred_map_runs_after_adoption_without_exclusion()
  local generation = "supported-late-map-generation"
  local backend = FakeCache.new()
  local realForVersion = CacheFs.forVersion
  local cacheFs = realForVersion("heartgold", backend)
  withPatched({
    {
      target = CacheFs,
      name = "forVersion",
      replacement = function()
        return realForVersion("heartgold", backend)
      end,
    },
  }, function()
    local pool = recordingPool()
    local session = openSession(generation, pool)
    local ready, failure = session:requestJob("map", "7", "required")
    Assert.isFalse(ready, "a deferred map stays pending while membership is unknown")
    Assert.isNil(failure, "a deferred map reports no failure while membership is unknown")
    local staged = compileSynthetic(generation)
    cacheFs:writeLua(SourcePlan.PATH, staged)
    for _ = 1, 5 do
      session:update()
      if contains(pool.submitted, "source-plan:global") then
        break
      end
    end
    Assert.isTrue(
      contains(pool.submitted, "source-plan:global"),
      "the supported map still schedules its declared inventory prerequisite"
    )
    publishStagedSource(cacheFs, pool, generation)
    for _ = 1, 5 do
      session:update()
    end
    Assert.isTrue(session.sourceLoaded, "the late inventory is adopted")
    local row = nil
    for _, item in ipairs(session:outcomes()) do
      if item.jobKey == "map:7" then
        row = item
      end
    end
    assert(row, "the deferred map keeps its canonical outcome row")
    Assert.isTrue(row.failureClass ~= "source-exclusion", "a supported map is never excluded")
    Assert.isTrue(row.state ~= "failed" or row.failureClass ~= "source-exclusion", "no invented exclusion")
  end)
end

-- An independent leaf keeps a small closure: a camera-only demand
-- dispatches the camera job without reading or scheduling the unrelated
-- source inventory.
function T.camera_leaf_schedules_no_inventory_work()
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
  withPatched(patches, function()
    local pool = recordingPool()
    local session = openSession("camera-closure-generation", pool)
    local ready, failure = session:requestJob("field-camera", "global", "required")
    Assert.isFalse(ready, "the cold camera stays pending")
    Assert.isNil(failure, "the cold camera reports no failure")
    for _ = 1, 3 do
      session:update()
    end
    Assert.isTrue(contains(pool.submitted, "field-camera:global"), "the independent leaf dispatches its own work")
    for _, jobKey in ipairs(pool.submitted) do
      Assert.isTrue(jobKey ~= "source-plan:global", "an independent leaf never schedules the inventory")
    end
    Assert.isFalse(session.sourceLoaded, "camera demand adopts no inventory")
  end)
end

-- Removing the blanket edge must not remove legitimate ones: a cold map
-- and a cold script member still schedule the source inventory, a cold
-- portrait page still schedules the layout, and no parent dispatches from
-- an incomplete plan.
function T.declared_metadata_edges_still_schedule_their_prerequisites()
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
  withPatched(patches, function()
    local pool = recordingPool()
    local session = openSession("declared-edge-generation", pool)
    session:requestJob("map", "7", "required")
    session:requestJob("script-member", "1", "required")
    session:requestJob("mon-portrait-page", "0", "required")
    for _ = 1, 3 do
      session:update()
    end
    local scriptDeps, scriptComplete = ArtifactJobs.dependencies("script-member", "1", {})
    local scriptNeedsInventory = false
    for _, dep in ipairs(scriptDeps) do
      if dep.kind == "source-plan" and dep.key == "global" then
        scriptNeedsInventory = true
      end
    end
    Assert.isTrue(scriptNeedsInventory, "a script member declares the inventory prerequisite")
    Assert.isTrue(scriptComplete, "a script member carries a known dependency list")
    Assert.isTrue(
      contains(pool.submitted, "source-plan:global"),
      "a cold map still schedules its declared inventory prerequisite"
    )
    Assert.isTrue(
      contains(pool.submitted, "mon-catalog:global"),
      "a cold page still traverses its declared layout prerequisite chain"
    )
    Assert.isFalse(contains(pool.submitted, "map:7"), "a map never dispatches from an incomplete plan")
    Assert.isFalse(
      contains(pool.submitted, "script-member:1"),
      "a script member never dispatches before its inventory is known"
    )
    Assert.isFalse(contains(pool.submitted, "mon-portrait-page:0"), "a page never dispatches from an incomplete plan")
  end)
end

-- Transition-driven adoption: metadata reads happen only under an admitted
-- planning step, newly adopted membership enrolls once at its retained
-- urgency, and a repaired payload earns exactly one fresh adoption attempt
-- instead of per-frame rereads.
function T.exhausted_budget_admits_layout_adoption_before_reading_plans()
  local MonCache = require("libs.assets.src.MonCache")
  local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
  local generation = "admitted-adoption-generation"
  local backend = FakeCache.new()
  local realForVersion = CacheFs.forVersion
  local cacheFs = realForVersion("heartgold", backend)
  stageSynthetic(cacheFs, generation)
  local catalogMarker = "synthetic-catalog-marker"
  MonCacheWriter.writeCatalog(cacheFs, minimalCatalog(), catalogMarker)
  writeMonReceipt(cacheFs, generation, "mon-catalog", "global", catalogMarker)
  local layoutMarker = "synthetic-layout-marker"
  MonCacheWriter.writeLayout(
    cacheFs,
    layoutManifest(MonCache.ICON_MANIFEST_SCHEMA, MonCache.iconPagePath(0), 256, 128, 32),
    layoutManifest(MonCache.PORTRAIT_MANIFEST_SCHEMA, MonCache.portraitPagePath(0), 640, 320, 80),
    layoutMarker,
    { iconPages = { [0] = iconPagePlan(0) }, portraitPages = { [0] = portraitPagePlan(0) } },
    generation
  )
  writeMonReceipt(cacheFs, generation, "mon-layout", "global", layoutMarker)
  local realPublishedPlans = ArtifactJobs.publishedPlans
  local realPlanRead = SourcePlan.read
  local publishedCalls, planReads = 0, 0
  ArtifactJobs.publishedPlans = function(...)
    publishedCalls = publishedCalls + 1
    return realPublishedPlans(...)
  end
  SourcePlan.read = function(...)
    planReads = planReads + 1
    return realPlanRead(...)
  end
  local realLove = rawget(_G, "love")
  local ok, failure = pcall(function()
    withPatched({
      {
        target = CacheFs,
        name = "forVersion",
        replacement = function()
          return realForVersion("heartgold", backend)
        end,
      },
    }, function()
      local pool = recordingPool()
      local session = openSession(generation, pool)
      session:requestMilestone("new-game-intro", "required")
      -- Page membership flows through explicit layout demand: the layout
      -- (and its catalog prerequisite) joins the intro-driven session here.
      session:requestJob("mon-catalog", "global", "required")
      session:requestJob("mon-layout", "global", "required")
      -- The first planning node sets the slice start; every later clock
      -- read observes an exhausted slice, so the layout adoption below
      -- cannot admit its planning node in this pass.
      local clockCalls = 0
      rawset(_G, "love", {
        timer = {
          getTime = function()
            clockCalls = clockCalls + 1
            if clockCalls <= 2 then
              return 1000.0
            end
            return 2000.0
          end,
        },
      })
      local updateOk, _ = pcall(session.update, session)
      Assert.isTrue(updateOk, "the exhausted pass still pumps without raising")
      -- A frozen slice admits a single planning node: dependency
      -- computation runs, but neither adoption reads its plans.
      Assert.isFalse(session.sourceLoaded, "one node cannot complete source adoption")
      Assert.isFalse(session.pagesKnown, "the unadmitted layout adoption waits for a fresh slice")
      Assert.equal(publishedCalls, 0, "an exhausted pass reads no published plans, got " .. tostring(publishedCalls))
      Assert.equal(planReads, 0, "an exhausted pass validates nothing, got " .. tostring(planReads))
      rawset(_G, "love", realLove)
      -- Admission order is structural: pages adoption needs source
      -- membership, so the source flip lands first. Staged pool replies
      -- stand in for worker proof. Track both flips.
      pool.states["source-plan:global"] = "ready"
      pool.states["mon-catalog:global"] = "ready"
      pool.states["mon-layout:global"] = "ready"
      local sourceAt, pagesAt = nil, nil
      for updateIndex = 1, 10 do
        session:update()
        if sourceAt == nil and session.sourceLoaded then
          sourceAt = updateIndex
        end
        if pagesAt == nil and session.pagesKnown then
          pagesAt = updateIndex
        end
        if sourceAt ~= nil and pagesAt ~= nil then
          break
        end
      end
      Assert.isTrue(sourceAt ~= nil, "the admitted source adoption completes")
      Assert.isTrue(pagesAt ~= nil, "the next admitted step adopts the layout")
      Assert.isTrue(sourceAt <= pagesAt, "source adoption precedes layout adoption")
      Assert.equal(publishedCalls, 1, "the admitted adoption reads plans exactly once")
      Assert.isTrue(contains(session.iconPageIds, 0), "adoption carries the declared icon page")
      Assert.isTrue(planReads >= 1, "the source inventory was read through its owner")
    end)
  end)
  ArtifactJobs.publishedPlans = realPublishedPlans
  SourcePlan.read = realPlanRead
  rawset(_G, "love", realLove)
  if not ok then
    error(failure, 0)
  end
end

function T.adopted_page_membership_enrolls_once_at_retained_urgency()
  local MonCache = require("libs.assets.src.MonCache")
  local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
  local generation = "delta-enrollment-generation"
  local backend = FakeCache.new()
  local realForVersion = CacheFs.forVersion
  local cacheFs = realForVersion("heartgold", backend)
  stageSynthetic(cacheFs, generation)
  local catalogMarker = "synthetic-catalog-marker"
  MonCacheWriter.writeCatalog(cacheFs, minimalCatalog(), catalogMarker)
  writeMonReceipt(cacheFs, generation, "mon-catalog", "global", catalogMarker)
  local layoutMarker = "synthetic-layout-marker"
  MonCacheWriter.writeLayout(
    cacheFs,
    layoutManifest(MonCache.ICON_MANIFEST_SCHEMA, MonCache.iconPagePath(0), 256, 128, 32),
    layoutManifest(MonCache.PORTRAIT_MANIFEST_SCHEMA, MonCache.portraitPagePath(0), 640, 320, 80),
    layoutMarker,
    { iconPages = { [0] = iconPagePlan(0) }, portraitPages = { [0] = portraitPagePlan(0) } },
    generation
  )
  writeMonReceipt(cacheFs, generation, "mon-layout", "global", layoutMarker)
  local realBootstrapJobs = ArtifactJobs.bootstrapJobs
  local realIntroJobs = ArtifactJobs.newGameIntroJobs
  local constructions = { bootstrap = 0, intro = 0 }
  ArtifactJobs.bootstrapJobs = function(...)
    constructions.bootstrap = constructions.bootstrap + 1
    return realBootstrapJobs(...)
  end
  ArtifactJobs.newGameIntroJobs = function(...)
    constructions.intro = constructions.intro + 1
    return realIntroJobs(...)
  end
  local realBackendRead = backend.read
  local backendReads = 0
  function backend.read(self, path)
    backendReads = backendReads + 1
    return realBackendRead(self, path)
  end
  local ok, failure = pcall(function()
    withPatched({
      {
        target = CacheFs,
        name = "forVersion",
        replacement = function()
          return realForVersion("heartgold", backend)
        end,
      },
    }, function()
      local pool = recordingPool()
      local session = InteractiveCacheBuild.new({
        identity = identity(generation),
        epoch = 1,
        pool = pool,
      })
      session:requestMilestone("new-game-intro", "near")
      -- Page membership flows through explicit layout demand: the staged
      -- layout adopts only once the test demands it directly.
      session:requestJob("mon-layout", "global", "near")
      pool.states["source-plan:global"] = "ready"
      pool.states["mon-catalog:global"] = "ready"
      pool.states["mon-layout:global"] = "ready"
      local adopted = false
      for _ = 1, 60 do
        session:update()
        if session.pagesKnown then
          adopted = true
          break
        end
      end
      Assert.isTrue(adopted, "the staged layout is adopted through the pump")
      -- Selective page demand enrolls the adopted page: blanket icon pages
      -- are never part of the intro roster, so the page joins only through
      -- the fixed demand path, once, at the retained urgency.
      session:requestIconPage(0, "near")
      -- Drain every other demand without touching the still-cold page, so
      -- later idle updates have no legitimate enrollment left to perform.
      -- The retained cursors drain one planning node per member under the
      -- shared per-update slice, so a full corpus needs many bounded passes.
      -- The budget matches the pre-selective-demand drain: dependency
      -- expansion order varies per process, and the exit condition (not
      -- the count) decides convergence.
      local drained = false
      for _ = 1, 1200 do
        for _, entry in pairs(session.byKey) do
          if type(entry) == "table" and entry.jobKey ~= "mon-icon-page:0" then
            if entry.failure == nil and not entry.ready then
              entry.ready = true
            end
          end
        end
        session:update()
        local outstanding = session.byKey["mon-icon-page:0"] == nil
        if not outstanding then
          for _, entry in pairs(session.byKey) do
            if type(entry) == "table" and entry.failure == nil and not entry.ready and not entry.submitted then
              outstanding = true
              break
            end
          end
        end
        if session.byKey["mon-icon-page:0"] ~= nil and session.enrollCursor == nil and not outstanding then
          drained = true
          break
        end
      end
      Assert.isTrue(drained, "adoption-triggered enrollment drains through bounded planning")
      local pageEntry = assert(session.byKey["mon-icon-page:0"], "the enrolled page keeps its entry")
      Assert.equal(pageEntry.urgency, "near", "the new member joins at the retained urgency")
      local submissions = {}
      for _, jobKey in ipairs(pool.submitted) do
        submissions[jobKey] = (submissions[jobKey] or 0) + 1
      end
      Assert.equal(submissions["mon-icon-page:0"], 1, "the adopted page dispatches exactly once")
      local seen = {}
      for _, entry in ipairs(session.interest) do
        Assert.isNil(seen[entry.jobKey], "adoption keeps one retained job: " .. entry.jobKey)
        seen[entry.jobKey] = true
      end
      -- The tail guards idle-steady-state invariants with no further
      -- demand: the intro already served its adoption role above.
      local before = {
        bootstrap = constructions.bootstrap,
        intro = constructions.intro,
        reads = backendReads,
        submitted = #pool.submitted,
      }
      for _ = 1, 5 do
        session:update()
      end
      Assert.equal(constructions.bootstrap, before.bootstrap, "idle updates rebuild no bootstrap roster")
      Assert.equal(constructions.intro, before.intro, "idle updates rebuild no intro roster")
      Assert.equal(backendReads, before.reads, "idle updates perform no readiness reads")
      Assert.equal(#pool.submitted, before.submitted, "idle updates submit no worker jobs")
      local duplicates = {}
      for _, jobKey in ipairs(pool.submitted) do
        duplicates[jobKey] = (duplicates[jobKey] or 0) + 1
      end
      for jobKey, count in pairs(duplicates) do
        Assert.equal(count, 1, "idle updates duplicate no physical job: " .. jobKey)
      end
    end)
  end)
  ArtifactJobs.bootstrapJobs = realBootstrapJobs
  ArtifactJobs.newGameIntroJobs = realIntroJobs
  if not ok then
    error(failure, 0)
  end
end

function T.repaired_layout_reads_plans_once_without_polling_failures()
  local MonCache = require("libs.assets.src.MonCache")
  local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
  local generation = "quiet-repair-generation"
  local backend = FakeCache.new()
  local realForVersion = CacheFs.forVersion
  local cacheFs = realForVersion("heartgold", backend)
  stageSynthetic(cacheFs, generation)
  local catalogMarker = "synthetic-catalog-marker"
  MonCacheWriter.writeCatalog(cacheFs, minimalCatalog(), catalogMarker)
  writeMonReceipt(cacheFs, generation, "mon-catalog", "global", catalogMarker)
  local layoutMarker = "synthetic-layout-marker"
  MonCacheWriter.writeLayout(
    cacheFs,
    layoutManifest(MonCache.ICON_MANIFEST_SCHEMA, MonCache.iconPagePath(0), 256, 128, 32),
    layoutManifest(MonCache.PORTRAIT_MANIFEST_SCHEMA, MonCache.portraitPagePath(0), 640, 320, 80),
    layoutMarker,
    { iconPages = { [0] = iconPagePlan(0) }, portraitPages = { [0] = portraitPagePlan(0) } },
    generation
  )
  writeMonReceipt(cacheFs, generation, "mon-layout", "global", layoutMarker)
  local pagePlanPath = MonCacheWriter.sourcePagePlanPath("portraits", 0)
  local savedRecord = assert(cacheFs:loadLua(pagePlanPath), "the staged page record reads back")
  cacheFs:remove(pagePlanPath)
  local realPublishedPlans = ArtifactJobs.publishedPlans
  local publishedCalls = 0
  ArtifactJobs.publishedPlans = function(...)
    publishedCalls = publishedCalls + 1
    return realPublishedPlans(...)
  end
  local ok, failure = pcall(function()
    withPatched({
      {
        target = CacheFs,
        name = "forVersion",
        replacement = function()
          return realForVersion("heartgold", backend)
        end,
      },
    }, function()
      local pool = recordingPool()
      local session = openSession(generation, pool)
      session:requestJob("mon-portrait-page", "0", "required")
      pool.states["source-plan:global"] = "ready"
      pool.states["mon-catalog:global"] = "ready"
      for _ = 1, 6 do
        session:update()
      end
      Assert.isFalse(session.pagesKnown, "a layout with a missing page record is never adopted")
      Assert.equal(
        publishedCalls,
        0,
        "unchanged damage earns no fruitless reader calls, got " .. tostring(publishedCalls)
      )
      cacheFs:writeLua(pagePlanPath, savedRecord)
      pool.states["mon-layout:global"] = "ready"
      local layoutEntry = session.byKey["mon-layout:global"]
      if layoutEntry ~= nil and layoutEntry.failure ~= nil then
        session:retry("mon-layout", "global", "required")
      end
      local readsBeforeRepair = publishedCalls
      local adopted = false
      for _ = 1, 20 do
        session:update()
        if session.pagesKnown then
          adopted = true
          break
        end
      end
      Assert.isTrue(adopted, "the repaired marker is adopted through its owner transition")
      Assert.equal(publishedCalls, readsBeforeRepair + 1, "the repair earns exactly one fresh adoption attempt")
      Assert.isTrue(contains(session.portraitPageIds, 0), "the repair restores page membership")
      Assert.equal(
        cacheFs:read(MonCache.layoutMarkerPath()),
        layoutMarker,
        "adoption never mutates the deterministic marker"
      )
      session:retire()
      local retiredOk = pcall(session.update, session)
      Assert.isFalse(retiredOk, "a retired session runs no further planning")
      Assert.equal(publishedCalls, readsBeforeRepair + 1, "a retired session retries no adoption")
    end)
  end)
  ArtifactJobs.publishedPlans = realPublishedPlans
  if not ok then
    error(failure, 0)
  end
end

-- A refused page handoff fails its ready owner exactly once: the layout
-- leaves readiness with the reader's cause, waiting pages fail causally,
-- the reader is not polled again, and an explicit same-marker repair
-- adopts without rebuilding the valid layout.
function T.refused_page_handoff_fails_the_ready_owner_once()
  local calls = freshCalls()
  local backend = FakeCache.new()
  local cacheFs = CacheFs.forVersion("heartgold", backend)
  local generation = "refused-handoff-generation"
  stageSynthetic(cacheFs, generation)
  local realForVersion = CacheFs.forVersion
  local patches = plannerPatches(calls)
  patches[#patches + 1] = {
    target = CacheFs,
    name = "forVersion",
    replacement = function()
      return realForVersion("heartgold", backend)
    end,
  }
  withPatched(patches, function()
    local MonCache = require("libs.assets.src.MonCache")
    local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
    local PngWriter = require("libs.assets.src.PngWriter")
    MonCacheWriter.writeCatalog(cacheFs, minimalCatalog(), "refused-catalog-marker")
    writeMonReceipt(cacheFs, generation, "mon-catalog", "global", "refused-catalog-marker")
    MonCacheWriter.writeLayout(
      cacheFs,
      layoutManifest(MonCache.ICON_MANIFEST_SCHEMA, MonCache.iconPagePath(0), 256, 128, 32),
      layoutManifest(MonCache.PORTRAIT_MANIFEST_SCHEMA, MonCache.portraitPagePath(0), 640, 320, 80),
      "refused-layout-marker",
      { iconPages = { [0] = iconPagePlan(0) }, portraitPages = { [0] = portraitPagePlan(0) } },
      generation
    )
    writeMonReceipt(cacheFs, generation, "mon-layout", "global", "refused-layout-marker")
    cacheFs:write(MonCache.pageImagePath("portraits", 0), PngWriter.encode(640, 320, string.rep("\0", 640 * 320 * 4)))
    cacheFs:write(MonCache.pageMarkerPath("portraits", 0), "refused-portrait-marker-0")
    writeMonReceipt(cacheFs, generation, "mon-portrait-page", "0", "refused-portrait-marker-0")
    local pool = recordingPool()
    local session = openSession(generation, pool)
    -- The refusal is injected before any update: adoption runs promptly
    -- once its owners validate, so a later patch would arrive after the
    -- handoff already succeeded.
    local realPublishedPlans = ArtifactJobs.publishedPlans
    local handoffCalls = 0
    ArtifactJobs.publishedPlans = function()
      handoffCalls = handoffCalls + 1
      return nil, "synthetic refused handoff"
    end
    local ready, failure = session:requestJob("mon-portrait-page", "0", "required")
    Assert.isFalse(ready, "the portrait starts pending")
    Assert.isNil(failure, "the portrait reports no failure")
    pool.states["source-plan:global"] = "ready"
    pool.states["mon-catalog:global"] = "ready"
    pool.states["mon-layout:global"] = "ready"
    local ok, err = pcall(function()
      for _ = 1, 10 do
        session:update()
      end
      local outcomes = {}
      for _, outcome in ipairs(session:outcomes()) do
        outcomes[outcome.jobKey] = outcome
      end
      local layout = assert(outcomes["mon-layout:global"], "the layout stays in the outcomes")
      Assert.equal(layout.state, "failed", "the refused handoff fails its ready owner")
      Assert.equal(layout.failureClass, "planning", "the handoff failure keeps its planning class")
      Assert.isTrue(
        tostring(layout.error):find("synthetic refused handoff", 1, true) ~= nil,
        "the owner keeps the reader cause: " .. tostring(layout.error)
      )
      local page = assert(outcomes["mon-portrait-page:0"], "the waiting page stays in the outcomes")
      Assert.equal(page.state, "failed", "the waiting page fails causally")
      Assert.equal(page.causeJobKey, "mon-layout:global", "the page names its layout cause")
      for _ = 1, 50 do
        session:update()
      end
      Assert.equal(handoffCalls, 1, "the refused reader is never polled again")
      local scopeReady, scopeFailure = session:requestJob("mon-portrait-page", "0", "required")
      Assert.isFalse(scopeReady, "no success is proven behind the refused handoff")
      Assert.isTrue(scopeFailure ~= nil, "the scope carries its cause")
    end)
    ArtifactJobs.publishedPlans = realPublishedPlans
    Assert.isTrue(ok, tostring(err))
    -- The explicit repair under the same deterministic marker adopts:
    -- no automatic retry resubmitted while failed, one explicit repair
    -- re-admits (the pool answers from its ready record), and no
    -- rebuild follows.
    local function layoutSubmissions()
      local count = 0
      for _, jobKey in ipairs(pool.submitted) do
        if jobKey == "mon-layout:global" then
          count = count + 1
        end
      end
      return count
    end
    Assert.equal(layoutSubmissions(), 1, "no automatic retry resubmits while failed")
    local repaired, repairFailure = session:retry("mon-layout", "global", "required")
    Assert.isFalse(repaired, "the repair starts pending")
    Assert.isNil(repairFailure, "the repair reports no failure")
    for _ = 1, 20 do
      session:update()
    end
    Assert.isTrue(session.pagesKnown, "the repaired handoff adopts page membership")
    Assert.isTrue(contains(session.portraitPageIds, 0), "the repair carries its portrait page")
    Assert.equal(layoutSubmissions(), 2, "the explicit repair re-admits exactly once")
    Assert.equal(
      cacheFs:read(MonCache.layoutMarkerPath()),
      "refused-layout-marker",
      "adoption never mutates the deterministic marker"
    )
  end)
end

-- Source inventory enumerates map cell keys through the topology-only
-- projection: building the roster performs no full per-map content
-- planning and no leaf cell planning, while membership stays sorted and
-- unique per map.
function T.inventory_lists_map_cells_without_full_content_planning()
  Assert.equal(
    type(MapCompilePlan.cellKeys),
    "function",
    "source inventory must enumerate cells through the topology-only projection"
  )
  local calls = { world = 0, index = 0, script = 0, audio = 0, plans = 0, leaves = 0 }
  local patches = {
    {
      target = WorldManifest,
      name = "compileCatalog",
      replacement = function()
        calls.world = calls.world + 1
        return syntheticWorld()
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
      target = FieldCellCompiler,
      name = "planCell",
      replacement = function()
        calls.leaves = calls.leaves + 1
        error("roster enumeration must not plan leaf cells", 0)
      end,
    },
    {
      target = ScriptCompiler,
      name = "plan",
      replacement = function()
        calls.script = calls.script + 1
        return { members = { { memberId = 4 } }, generationKey = "synthetic-generation" }
      end,
    },
    {
      target = AudioCompiler,
      name = "planSource",
      replacement = function()
        calls.audio = calls.audio + 1
        return {
          plan = { index = { version = "heartgold" }, bankPlans = {} },
          identity = { romSha1 = SYNTHETIC_SHA1, sdatSha1 = string.rep("d", 40), sdatFileId = 9 },
        }
      end,
    },
    {
      target = MapCompilePlan,
      name = "plan",
      replacement = function(_, _, mapId)
        calls.plans = calls.plans + 1
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
    {
      target = MapCompilePlan,
      name = "cellKeys",
      replacement = function(_, _, mapId)
        if mapId == 7 then
          return { "11:1", "11:0" }
        end
        return {}
      end,
    },
  }
  local plan = withPatched(patches, function()
    return SourcePlan.compile(syntheticRomFs(), identity("topology-generation"))
  end)
  Assert.equal(calls.world, 1, "the world catalog still compiles once")
  Assert.equal(calls.index, 1, "the cell index still compiles once")
  Assert.equal(calls.plans, 0, "source inventory performs no full per-map content planning")
  Assert.equal(calls.leaves, 0, "source inventory plans no leaf cells")
  Assert.deepEqual(plan.mapCellKeys[7], { "11-0", "11-1" }, "map cell keys stay sorted and unique")
  Assert.deepEqual(plan.mapCellKeys[9], {}, "a map without cells keeps its membership")
end

return { tests = T }
