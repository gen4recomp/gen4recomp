-- One generation session for bootstrap, field core and exhaustive warmup.
-- Construction performs no source work: it validates its identity, recovers
-- publication, selects the epoch and starts from empty retained state plus
-- the two source-static membership lists. One worker-compiled inventory,
-- adopted once published, supplies every source-derived membership; mon page
-- membership follows once the layout publishes. Until then requests needing
-- those families stay pending, fixed roots and statically known families
-- answer immediately, and each update advances at most a small bounded
-- amount of retained dependency work with required demand first.

local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local ArtifactState = require("romdump.src.build.ArtifactState")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
local SourcePlan = require("romdump.src.build.SourcePlan")

---@class InteractiveCacheBuild.Interest
---@field kind string
---@field key string
---@field jobKey string
---@field urgency string
---@field priority integer
---@field submitted boolean
---@field ready boolean
---@field validated boolean
---@field failure string|nil
---@field poolState string|nil last observed pool state

---@class InteractiveCacheBuild
---@field versionId string
---@field generationId string
---@field producerId string
---@field epoch integer
---@field pool CompilerPool
---@field sweepEnabled boolean
---@field cacheFs CacheFs
---@field messageBankIds integer[]
---@field audioBankIds integer[]
---@field scriptMemberIds integer[]
---@field iconPageIds integer[]
---@field portraitPageIds integer[]
---@field mapDataIds integer[]
---@field mapIds integer[]
---@field mapCellKeys table<integer, string[]>
---@field interest InteractiveCacheBuild.Interest[]
---@field byKey table<string, InteractiveCacheBuild.Interest>
---@field milestones table<string, string>
---@field recorded table<string, boolean>
---@field retired boolean
---@field sourceLoaded boolean worker inventory adopted
---@field pagesKnown boolean mon page membership adopted
---@field adopted ArtifactJobs.Plans|nil retained published inventory
---@field dirty table<string, boolean> canonical identities needing planning
---@field edges table<string, table<string, boolean>> dependency to parent identities
---@field parked table<string, boolean> sweep identities paused by the planning budget or admission
---@field depMemo table<string, { kind: string, key: string }[]> retained dependency edges
---@field pendingFillDone boolean
---@field loadedFillDone boolean
---@field followerMemo string|nil retained follower diagnostic
---@field followerChecked boolean
---@field layoutMarkerSeen string|nil last layout marker probed for page adoption
local InteractiveCacheBuild = {}
InteractiveCacheBuild.__index = InteractiveCacheBuild

---@class InteractiveCacheBuild.Budget
---@field used integer
---@field start number|nil slice starts at the first planning node
---@field exhausted boolean

local MILESTONE_FILES = {
  bootstrap = "data/generated/bootstrap.lua",
  ["field-core"] = "data/generated/field-core.lua",
}

-- One update advances at most this many dependency/validation nodes, Urgent
-- demand first; the remainder waits for the next update. A single metadata
-- read is indivisible and never preempted by the slice below.
local UPDATE_NODE_BUDGET = 32
local UPDATE_TIME_SLICE_SECONDS = 0.002

local function isInteger(value)
  return type(value) == "number" and value % 1 == 0
end

---@param key string canonical decimal map key
---@return integer
local function canonicalMapId(key)
  local id = assert(tonumber(key), "map key is not canonical")
  assert(isInteger(id), "map key is not canonical")
  return id --[[@as integer]]
end

local function nowSeconds()
  local host = rawget(_G, "love")
  if host ~= nil and host.timer ~= nil and type(host.timer.getTime) == "function" then
    return host.timer.getTime()
  end
  return os.clock()
end

-- Families whose membership arrives with the worker inventory. While it is
-- unpublished the session cannot tell an unknown member from a
-- not-yet-known one, so requests defer instead of failing.
---@param kind string
---@return boolean
local function needsSourceInventory(kind)
  return kind == "map"
    or kind == "field-cell"
    or kind == "script-member"
    or kind == "script-summary"
    or kind == "audio-bank"
    or kind == "audio-summary"
end

---@param kind string
---@return boolean
local function needsPageMembership(kind)
  return kind == "mon-icon-page" or kind == "mon-portrait-page" or kind == "mon-summary"
end

-- Families whose planning call would raise or misfire without its data.
-- Script members and audio banks plan safely against an empty inventory
-- (their calls simply report not-ready), so only these skip until adoption.
---@param kind string
---@return boolean
local function planningWaitsForSource(kind)
  return kind == "map" or kind == "field-cell" or kind == "script-summary" or kind == "audio-summary"
end

---@param options table<string, unknown>
---@return InteractiveCacheBuild
function InteractiveCacheBuild.new(options)
  assert(type(options) == "table", "generation session options are required")
  local identity = assert(options.identity, "generation session identity is required")
  assert(type(identity) == "table", "generation session identity must be a record")
  local versionId = identity.versionId
  assert(type(versionId) == "string" and versionId ~= "", "generation session version is required")
  local generationId = identity.generationId
  assert(type(generationId) == "string" and generationId ~= "", "generation session generation is required")
  local producerId = identity.producerId
  assert(type(producerId) == "string" and producerId ~= "", "generation session producer is required")
  local epoch = options.epoch
  assert(isInteger(epoch) and epoch >= 1, "generation session epoch must be a positive integer")
  local pool = options.pool
  assert(type(pool) == "table", "generation session requires the process-owned pool")
  local sweepEnabled = options.sweepEnabled
  if sweepEnabled == nil then
    sweepEnabled = false
  end
  assert(type(sweepEnabled) == "boolean", "generation session sweep choice must be a boolean")

  local cacheFs = CacheFs.forVersion(versionId)
  cacheFs:recoverPublication()
  assert(type(pool.selectGeneration) == "function", "generation session pool cannot select generations")
  pool:selectGeneration(identity, epoch)
  -- Only source-static membership is known here: required message banks and
  -- supported field records derive from frozen catalogs without opening the
  -- dump. Everything else arrives with the worker inventory.
  return setmetatable({
    versionId = versionId,
    generationId = generationId,
    producerId = producerId,
    epoch = epoch,
    pool = pool,
    sweepEnabled = sweepEnabled,
    cacheFs = cacheFs,
    messageBankIds = FieldMessageCompiler.requiredBankIds(),
    audioBankIds = {},
    scriptMemberIds = {},
    iconPageIds = {},
    portraitPageIds = {},
    mapDataIds = FieldMapDataCompiler.supportedMapIds(),
    mapIds = {},
    mapCellKeys = {},
    interest = {},
    byKey = {},
    milestones = {},
    recorded = {},
    retired = false,
    sourceLoaded = false,
    pagesKnown = false,
    adopted = nil,
    dirty = {},
    edges = {},
    parked = {},
    depMemo = {},
    pendingFillDone = false,
    loadedFillDone = false,
    followerMemo = nil,
    followerChecked = false,
    layoutMarkerSeen = nil,
  }, InteractiveCacheBuild)
end

---@return { versionId: string, generationId: string, producerId: string }
function InteractiveCacheBuild:_identity()
  return { versionId = self.versionId, generationId = self.generationId, producerId = self.producerId }
end

---@return ArtifactJobs.Plans
function InteractiveCacheBuild:_plans()
  if self.adopted ~= nil then
    return self.adopted
  end
  return {
    messageBankIds = self.messageBankIds,
    audioBankIds = self.audioBankIds,
    scriptMemberIds = self.scriptMemberIds,
    iconPageIds = self.iconPageIds,
    portraitPageIds = self.portraitPageIds,
    mapDataIds = self.mapDataIds,
    mapIds = self.mapIds,
    mapCellKeys = self.mapCellKeys,
  }
end

---@param budget InteractiveCacheBuild.Budget|nil
---@return boolean
function InteractiveCacheBuild:_spendNode(budget)
  if budget == nil then
    return true
  end
  if budget.used >= UPDATE_NODE_BUDGET then
    budget.exhausted = true
    return false
  end
  -- Fixed per-update overhead (pool polling, the admission ledger, the
  -- scheduling sort) grows with the corpus and must never consume the slice.
  if budget.start == nil then
    budget.start = nowSeconds()
  end
  if nowSeconds() - budget.start > UPDATE_TIME_SLICE_SECONDS then
    budget.exhausted = true
    return false
  end
  budget.used = budget.used + 1
  return true
end

---@param kind string
---@param key string
---@param plans ArtifactJobs.Plans
---@param budget InteractiveCacheBuild.Budget|nil
---@return { kind: string, key: string }[]|nil
---@return string|nil status
function InteractiveCacheBuild:_dependencies(kind, key, plans, budget)
  -- Retained edges cost no planning work to re-read: charging the per-pass
  -- budget for a memo hit lets a large pending family shadow every entry
  -- sorted after it, starving ready parents indefinitely. Only uncached
  -- planning calls consume the slice.
  local cached = self.depMemo[kind .. ":" .. key]
  if cached ~= nil then
    return cached, "settled"
  end
  if not self:_spendNode(budget) then
    return nil, "paused"
  end
  local plansOk, depsOrCause = pcall(ArtifactJobs.dependencies, kind, key, plans)
  if not plansOk then
    return nil, tostring(depsOrCause)
  end
  self.depMemo[kind .. ":" .. key] = depsOrCause
  for _, dep in ipairs(depsOrCause) do
    local parents = self.edges[dep.kind .. ":" .. dep.key]
    if parents == nil then
      parents = {}
      self.edges[dep.kind .. ":" .. dep.key] = parents
    end
    parents[kind .. ":" .. key] = true
  end
  return depsOrCause, "settled"
end

---@param kind string
---@param key string
---@param budget InteractiveCacheBuild.Budget|nil
---@return boolean
function InteractiveCacheBuild:_validate(kind, key, budget)
  if not self:_spendNode(budget) then
    return false
  end
  return ArtifactJobs.validate(self.cacheFs, self.generationId, kind, key, self:_plans())
end

---@param kind string
---@param key string
---@return table<string, unknown>|nil descriptor
---@return string|nil failure
function InteractiveCacheBuild:_cellDescriptor(kind, key)
  assert(kind == "field-cell", "cell resolution requires the field-cell kind")
  local matrixMemberId, index = key:match("^([0-9]+)-([0-9]+)$")
  matrixMemberId, index = tonumber(matrixMemberId), tonumber(index)
  local adopted = self.adopted
  if adopted == nil or adopted.indexBundle == nil then
    return nil, "field cell " .. key .. " is not in the canonical index"
  end
  for _, matrix in ipairs(adopted.indexBundle.index.matrices) do
    if matrix.matrixMemberId == matrixMemberId then
      for _, descriptor in ipairs(matrix.cells) do
        if descriptor.index == index then
          return descriptor
        end
      end
    end
  end
  return nil, "field cell " .. key .. " is not in the canonical index"
end

---@param kind string
---@param key string
---@param urgency string
---@return InteractiveCacheBuild.Interest
function InteractiveCacheBuild:_register(kind, key, urgency)
  local jobKey = ArtifactJobs.jobKey(kind, key)
  local priority = ArtifactJobs.priorityFor(urgency)
  local entry = self.byKey[jobKey]
  if entry == nil then
    entry = {
      kind = kind,
      key = key,
      jobKey = jobKey,
      urgency = urgency,
      priority = priority,
      submitted = false,
      ready = false,
      validated = false,
      failure = nil,
      poolState = nil,
    }
    self.byKey[jobKey] = entry
    self.interest[#self.interest + 1] = entry
  elseif priority < entry.priority then
    entry.urgency = urgency
    entry.priority = priority
    self:_promoteQueued(entry)
  end
  return entry
end

---@param entry InteractiveCacheBuild.Interest
function InteractiveCacheBuild:_promoteQueued(entry)
  if self.retired then
    return
  end
  if self.pool:status(entry.jobKey) ~= "queued" then
    return
  end
  local payload = self:_payload(entry.kind, entry.key)
  if payload == nil then
    return
  end
  -- The pool owns the heap, so a stronger urgency must reach the queued
  -- record under its canonical identity; the heap keeps its FIFO sequence.
  self.pool:request({
    versionId = self.versionId,
    generationId = self.generationId,
    epoch = self.epoch,
    kind = entry.kind,
    key = entry.key,
    jobKey = entry.jobKey,
    priority = entry.priority,
    sizeClass = ArtifactJobs.sizeClass(entry.kind),
    payload = payload,
  })
end

---@param kind string
---@param key string
---@return table<string, unknown>|nil
function InteractiveCacheBuild:_payload(kind, key)
  local payload = { producerFingerprint = self.producerId }
  if kind == "script-member" then
    local adopted = self.adopted
    if adopted == nil or adopted.scriptPlan == nil then
      return nil
    end
    payload.memberId = tonumber(key)
    payload.generationKey = adopted.scriptPlan.generationKey
  elseif kind == "field-cell" then
    local descriptor = self:_cellDescriptor(kind, key)
    if descriptor == nil then
      return nil
    end
    payload.matrixMemberId = descriptor.matrixMemberId
    payload.index = descriptor.index
    payload.x = descriptor.x
    payload.z = descriptor.z
    payload.mapHeaderId = descriptor.mapHeaderId
    payload.altitude = descriptor.altitude
    payload.landDataMemberId = descriptor.landDataMemberId
    payload.areaDataMemberId = descriptor.areaDataMemberId
  elseif kind == "map" or kind == "message-bank" or kind == "audio-bank" then
    if kind == "map" then
      payload.mapId = tonumber(key)
    else
      payload.bankId = tonumber(key)
    end
  elseif kind == "mon-icon-page" then
    payload.pageKind = "icons"
    payload.pageId = tonumber(key)
  elseif kind == "mon-portrait-page" then
    payload.pageKind = "portraits"
    payload.pageId = tonumber(key)
  end
  return payload
end

---@param limit integer|nil stop counting once this many are outstanding
---@return integer
function InteractiveCacheBuild:_outstandingSweep(limit)
  local count = 0
  for _, entry in ipairs(self.interest) do
    if entry.priority == 100 and entry.submitted and not entry.ready and entry.failure == nil then
      local state = self.pool:status(entry.jobKey)
      if state == "queued" or state == "running" then
        count = count + 1
        if limit ~= nil and count >= limit then
          return count
        end
      end
    end
  end
  return count
end

---@param entry InteractiveCacheBuild.Interest
---@param budget InteractiveCacheBuild.Budget|nil
---@param ledger { bound: integer, outstanding: integer }|nil per-pass sweep admission account
---@return string outcome
function InteractiveCacheBuild:_submit(entry, budget, ledger)
  if entry.ready or entry.failure ~= nil then
    return "settled"
  end
  if not entry.validated then
    entry.validated = true
    if self:_validate(entry.kind, entry.key, budget) then
      entry.ready = true
      return "settled"
    end
    if budget ~= nil and budget.exhausted then
      entry.validated = false
      return "paused"
    end
  end
  local payload = self:_payload(entry.kind, entry.key)
  if payload == nil then
    return "parked"
  end
  local state = self.pool:status(entry.jobKey)
  if state == "unknown" and not entry.submitted then
    if entry.priority == 100 then
      local bound, outstanding = self:_sweepBound(), self:_outstandingSweep()
      if ledger ~= nil then
        bound, outstanding = ledger.bound, ledger.outstanding
      end
      if outstanding >= bound then
        return "parked"
      end
    end
    local requestState, requestDetails = self.pool:request({
      versionId = self.versionId,
      generationId = self.generationId,
      epoch = self.epoch,
      kind = entry.kind,
      key = entry.key,
      jobKey = entry.jobKey,
      priority = entry.priority,
      sizeClass = ArtifactJobs.sizeClass(entry.kind),
      payload = payload,
    })
    entry.submitted = true
    entry.poolState = requestState
    if ledger ~= nil and entry.priority == 100 and (requestState == "queued" or requestState == "running") then
      ledger.outstanding = ledger.outstanding + 1
    end
    if requestState == "failed" then
      local message = requestDetails and requestDetails.error or "compiler job failed"
      entry.failure = entry.jobKey .. ": " .. tostring(message)
    end
    return "settled"
  end
  entry.submitted = true
  if state == "ready" then
    if self:_validate(entry.kind, entry.key, budget) then
      entry.ready = true
    else
      if budget ~= nil and budget.exhausted then
        return "paused"
      end
      entry.failure = self.generationId
        .. " "
        .. entry.kind
        .. " "
        .. entry.key
        .. ": published output fails its family validator"
    end
  elseif state == "failed" then
    local _, details = self.pool:status(entry.jobKey)
    local message = details and details.error or "compiler job failed"
    entry.failure = entry.jobKey .. ": " .. tostring(message)
  end
  return "settled"
end

---@return integer
function InteractiveCacheBuild:_workerCount()
  if type(self.pool.diagnostics) == "function" then
    local ok, diagnostics = pcall(self.pool.diagnostics, self.pool)
    if ok and type(diagnostics) == "table" and isInteger(diagnostics.workerCount) then
      return math.max(1, diagnostics.workerCount)
    end
  end
  local count = 1
  local host = rawget(_G, "love")
  if host and host.system and type(host.system.getProcessorCount) == "function" then
    local processors = host.system.getProcessorCount()
    if type(processors) == "number" and processors >= 1 then
      count = math.floor(processors)
    end
  end
  return math.max(1, math.min(4, math.floor((count - 1) / 2)))
end

---@return integer
function InteractiveCacheBuild:_sweepBound()
  return 2 * self:_workerCount()
end

---@param jobKey string
function InteractiveCacheBuild:_dirtyParents(jobKey)
  local parents = self.edges[jobKey]
  if parents == nil then
    return
  end
  for parentKey in pairs(parents) do
    local parent = self.byKey[parentKey]
    if parent ~= nil and not parent.ready and parent.failure == nil then
      self.dirty[parentKey] = true
    end
  end
end

---@param entry InteractiveCacheBuild.Interest
---@param trail table<string, boolean>|nil canonical identities on the current descent
---@param budget InteractiveCacheBuild.Budget|nil
---@param ledger { bound: integer, outstanding: integer }|nil per-pass sweep admission account
---@return string outcome
function InteractiveCacheBuild:_ensure(entry, trail, budget, ledger)
  if entry.ready or entry.failure ~= nil then
    return "settled"
  end
  if planningWaitsForSource(entry.kind) and not self.sourceLoaded then
    return "deferred"
  end
  if needsPageMembership(entry.kind) and not self.pagesKnown then
    return "deferred"
  end
  trail = trail or {}
  if trail[entry.jobKey] then
    if entry.failure == nil then
      entry.failure = self.generationId
        .. " "
        .. entry.kind
        .. " "
        .. entry.key
        .. ": dependency cycle involves "
        .. entry.jobKey
    end
    return "settled"
  end
  trail[entry.jobKey] = true
  local deps, depsStatus = self:_dependencies(entry.kind, entry.key, self:_plans(), budget)
  if deps == nil then
    trail[entry.jobKey] = nil
    if depsStatus == "paused" then
      return "paused"
    end
    if entry.failure == nil then
      entry.failure = self.generationId
        .. " "
        .. entry.kind
        .. " "
        .. entry.key
        .. ": dependency plan failed: "
        .. tostring(depsStatus)
    end
    return "settled"
  end
  for _, dep in ipairs(deps) do
    local depEntry = self:_register(dep.kind, dep.key, entry.urgency)
    local child = self:_ensure(depEntry, trail, budget, ledger)
    if child == "paused" then
      trail[entry.jobKey] = nil
      return "paused"
    end
    if depEntry.failure ~= nil and entry.failure == nil then
      entry.failure = self.generationId
        .. " "
        .. entry.kind
        .. " "
        .. entry.key
        .. ": prerequisite "
        .. depEntry.jobKey
        .. " failed: "
        .. depEntry.failure
      trail[entry.jobKey] = nil
      return "settled"
    end
  end
  -- A parent never occupies a worker while its children are still pending:
  -- summary and map workers read published children, so dispatch waits until
  -- every dependency is ready. The next update re-drives pending parents.
  for _, dep in ipairs(deps) do
    local depEntry = self.byKey[dep.kind .. ":" .. dep.key]
    if depEntry == nil then
      if entry.failure == nil then
        entry.failure = self.generationId
          .. " "
          .. entry.kind
          .. " "
          .. entry.key
          .. ": prerequisite "
          .. dep.kind
          .. ":"
          .. dep.key
          .. " is missing"
      end
      trail[entry.jobKey] = nil
      return "settled"
    end
    if not depEntry.ready then
      trail[entry.jobKey] = nil
      return "settled"
    end
  end
  trail[entry.jobKey] = nil
  local outcome = self:_submit(entry, budget, ledger)
  if outcome == "paused" then
    return "paused"
  end
  if outcome == "parked" then
    return "parked"
  end
  return "settled"
end

---@param entry InteractiveCacheBuild.Interest
---@return boolean
---@return string|nil
function InteractiveCacheBuild:_answer(entry)
  if entry.failure ~= nil then
    return false, entry.failure
  end
  if entry.ready then
    return true, nil
  end
  if planningWaitsForSource(entry.kind) and not self.sourceLoaded then
    return false, nil
  end
  if needsPageMembership(entry.kind) and not self.pagesKnown then
    return false, nil
  end
  self:_ensure(entry)
  if entry.failure ~= nil then
    return false, entry.failure
  end
  if entry.ready then
    return true, nil
  end
  return false, nil
end

-- Schedules the worker inventory the first time source membership is
-- needed and submits it immediately so workers start while the caller
-- keeps its pending answer. Once the inventory is adopted there is nothing
-- left to schedule.
---@param urgency string
function InteractiveCacheBuild:_needInventory(urgency)
  if self.sourceLoaded then
    return
  end
  local entry = self:_register("source-plan", "global", urgency)
  if not entry.submitted and entry.failure == nil and not entry.ready then
    self:_answer(entry)
  end
end

-- Schedules the mon layout the first time page membership is needed. Page
-- jobs wait on the layout, so demand for pages must pull it even when the
-- caller never named it. Registration answers idempotently.
---@param urgency string
function InteractiveCacheBuild:_needLayout(urgency)
  self:_answer(self:_register("mon-layout", "global", urgency))
end

---@param kind string
---@return boolean answerable now
function InteractiveCacheBuild:_answerable(kind)
  if needsSourceInventory(kind) and not self.sourceLoaded then
    return false
  end
  if needsPageMembership(kind) and not self.pagesKnown then
    return false
  end
  return true
end

---@param kind string
---@param key string
---@param urgency string
---@return InteractiveCacheBuild.Interest entry
---@return boolean deferred
function InteractiveCacheBuild:_request(kind, key, urgency)
  local entry = self:_register(kind, key, urgency)
  if not self:_answerable(kind) then
    self.dirty[entry.jobKey] = true
    self:_needInventory(urgency)
    return entry, true
  end
  return entry, false
end

---@param members { kind: string, key: string }[]
---@return boolean ready
---@return string|nil failure
function InteractiveCacheBuild:_milestoneAnswer(members)
  local failure = nil
  for _, member in ipairs(members) do
    local entry = self.byKey[member.kind .. ":" .. member.key]
    local ready = entry ~= nil and entry.ready
    local failed = entry ~= nil and entry.failure
    if not ready and failed == nil then
      return false, nil
    end
    if failed ~= nil and failure == nil then
      failure = failed
    end
  end
  if failure ~= nil then
    return false, failure
  end
  return true, nil
end

---@param name string
---@return { kind: string, key: string }[]
function InteractiveCacheBuild:_milestoneMembers(name)
  assert(name == "bootstrap" or name == "field-core", "milestones accept only bootstrap or field-core")
  if name == "bootstrap" then
    return ArtifactJobs.bootstrapJobs(self.audioBankIds)
  end
  return ArtifactJobs.fieldCoreJobs({
    audioBankIds = self.audioBankIds,
    messageBankIds = self.messageBankIds,
    scriptMemberIds = self.scriptMemberIds,
    iconPageIds = self.iconPageIds,
    mapDataIds = self.mapDataIds,
  })
end

---@return string|nil follower mismatch diagnostic
function InteractiveCacheBuild:_followerError()
  if self.followerChecked then
    return self.followerMemo
  end
  self.followerChecked = true
  local MonCache = require("libs.assets.src.MonCache")
  local catalogOk, catalog = pcall(MonCache.loadCatalog, self.cacheFs)
  if not catalogOk or type(catalog) ~= "table" then
    self.followerMemo = "mon catalog is not staged"
    return self.followerMemo
  end
  local actorIndex = self.cacheFs:loadLua(FieldActorCache.indexPath())
  if type(actorIndex) ~= "table" or type(actorIndex.spriteIds) ~= "table" then
    self.followerMemo = "merged actor index is not staged"
    return self.followerMemo
  end
  local spriteIds = {}
  for _, spriteId in ipairs(actorIndex.spriteIds) do
    spriteIds[spriteId] = true
  end
  local followersOk, followersErr = ArtifactJobs.checkFollowers(catalog, spriteIds)
  if not followersOk then
    self.followerMemo = followersErr
    return self.followerMemo
  end
  self.followerMemo = nil
  return nil
end

---@param name string
function InteractiveCacheBuild:_publishMilestone(name)
  if self.recorded[name] then
    return
  end
  local members = self:_milestoneMembers(name)
  local ready, _ = self:_milestoneAnswer(members)
  if not ready then
    return
  end
  if name == "field-core" then
    local followersErr = self:_followerError()
    if followersErr ~= nil then
      local entry = self.byKey["actors:global"]
      if entry ~= nil then
        entry.failure = self.generationId .. " actors global: " .. tostring(followersErr)
      end
      return
    end
  end
  local jobs = {}
  for _, member in ipairs(members) do
    local receipt = self.cacheFs:loadLua(ArtifactState.path(member.kind, member.key))
    if type(receipt) ~= "table" or type(receipt.marker) ~= "string" then
      return
    end
    jobs[#jobs + 1] = { identity = member.kind .. ":" .. member.key, marker = receipt.marker }
  end
  table.sort(jobs, function(left, right)
    return left.identity < right.identity
  end)
  local record = {
    schema = ArtifactJobs.MILESTONE_SCHEMA,
    generationId = self.generationId,
    name = name,
    jobs = jobs,
  }
  local path = assert(MILESTONE_FILES[name], "milestone has no file: " .. name)
  self.cacheFs:writeLua(path .. ".new", record)
  self.cacheFs:replace(path .. ".new", path)
  self.recorded[name] = true
end

---@param name string
---@param urgency string
---@return boolean
---@return string|nil
function InteractiveCacheBuild:requestMilestone(name, urgency)
  assert(not self.retired, "generation session is retired")
  assert(name == "bootstrap" or name == "field-core", "milestones accept only bootstrap or field-core")
  ArtifactJobs.priorityFor(urgency)
  self:_ensureInventoryLoaded()
  local current = self.milestones[name]
  if current == nil or ArtifactJobs.priorityFor(urgency) < ArtifactJobs.priorityFor(current) then
    self.milestones[name] = urgency
  end
  local members = self:_milestoneMembers(name)
  for _, member in ipairs(members) do
    local entry, deferred = self:_request(member.kind, member.key, self.milestones[name])
    if deferred then
      if needsPageMembership(member.kind) then
        self:_needLayout(self.milestones[name])
      end
    else
      self:_answer(entry)
    end
  end
  local ready, failure = self:_milestoneAnswer(members)
  if not ready and failure == nil and not self.sourceLoaded then
    self:_needInventory(urgency)
  end
  if ready and name == "field-core" then
    local followersErr = self:_followerError()
    if followersErr ~= nil then
      local actorsEntry = self.byKey["actors:global"]
      local diagnostic = self.generationId .. " actors global: " .. tostring(followersErr)
      if actorsEntry ~= nil then
        actorsEntry.failure = diagnostic
      end
      return false, diagnostic
    end
  end
  if ready then
    self:_publishMilestone(name)
  end
  return ready, failure
end

---@param mapId integer
---@return boolean known
function InteractiveCacheBuild:_knownMap(mapId)
  for _, known in ipairs(self.mapIds) do
    if known == mapId then
      return true
    end
  end
  return self.mapCellKeys[mapId] ~= nil
end

---@param mapId integer
---@param urgency string
---@return boolean
---@return string|nil
function InteractiveCacheBuild:requestField(mapId, urgency)
  assert(not self.retired, "generation session is retired")
  assert(isInteger(mapId) and mapId >= 0, "map ID must be a non-negative integer")
  ArtifactJobs.priorityFor(urgency)
  self:_ensureInventoryLoaded()
  if not self.sourceLoaded then
    self:_request("map", tostring(mapId), urgency)
    return false, nil
  end
  if not self:_knownMap(mapId) then
    return false, self.generationId .. " map " .. tostring(mapId) .. ": source has no supported map"
  end
  for _, cellKey in ipairs(self.mapCellKeys[mapId]) do
    self:_answer(self:_register("field-cell", cellKey, urgency))
  end
  return self:_answer(self:_register("map", tostring(mapId), urgency))
end

---@param descriptor table<string, unknown>
---@param urgency string
---@return boolean
---@return string|nil
function InteractiveCacheBuild:requestCell(descriptor, urgency)
  assert(not self.retired, "generation session is retired")
  assert(type(descriptor) == "table", "field cell descriptor is required")
  ArtifactJobs.priorityFor(urgency)
  self:_ensureInventoryLoaded()
  if not self.sourceLoaded then
    if not (isInteger(descriptor.matrixMemberId) and isInteger(descriptor.index)) then
      error("field cell descriptor needs its canonical matrix and index", 0)
    end
    local key = descriptor.matrixMemberId .. "-" .. descriptor.index
    self:_request("field-cell", key, urgency)
    return false, nil
  end
  assert(
    isInteger(descriptor.matrixMemberId) and isInteger(descriptor.index),
    "field cell descriptor needs its canonical matrix and index"
  )
  local key = descriptor.matrixMemberId .. "-" .. descriptor.index
  local authoritative, failure = self:_cellDescriptor("field-cell", key)
  if authoritative == nil then
    return false, self.generationId .. " field-cell " .. key .. ": " .. tostring(failure)
  end
  return self:_answer(self:_register("field-cell", key, urgency))
end

---@param pageId integer
---@param urgency string
---@return boolean
---@return string|nil
function InteractiveCacheBuild:requestMonPortraitPage(pageId, urgency)
  assert(not self.retired, "generation session is retired")
  assert(isInteger(pageId) and pageId >= 0, "portrait page ID must be a non-negative integer")
  ArtifactJobs.priorityFor(urgency)
  self:_ensureInventoryLoaded()
  if not self.pagesKnown then
    self:_request("mon-portrait-page", tostring(pageId), urgency)
    self:_needLayout(urgency)
    return false, nil
  end
  local supported = false
  for _, candidate in ipairs(self.portraitPageIds) do
    if candidate == pageId then
      supported = true
      break
    end
  end
  if not supported then
    return false, self.generationId .. " mon-portrait-page " .. tostring(pageId) .. ": source has no such page"
  end
  return self:_answer(self:_register("mon-portrait-page", tostring(pageId), urgency))
end

---@param kind string
---@param key string
---@return boolean supported
function InteractiveCacheBuild:_knownMember(kind, key)
  local numeric = tonumber(key)
  if kind == "message-bank" then
    for _, candidate in ipairs(self.messageBankIds) do
      if candidate == numeric then
        return true
      end
    end
  elseif kind == "audio-bank" then
    for _, candidate in ipairs(self.audioBankIds) do
      if candidate == numeric then
        return true
      end
    end
  elseif kind == "script-member" then
    for _, candidate in ipairs(self.scriptMemberIds) do
      if candidate == numeric then
        return true
      end
    end
  elseif kind == "map-data" then
    for _, candidate in ipairs(self.mapDataIds) do
      if candidate == numeric then
        return true
      end
    end
  elseif kind == "mon-icon-page" then
    for _, candidate in ipairs(self.iconPageIds) do
      if candidate == numeric then
        return true
      end
    end
  elseif kind == "mon-portrait-page" then
    for _, candidate in ipairs(self.portraitPageIds) do
      if candidate == numeric then
        return true
      end
    end
  end
  return false
end

---@param kind string
---@param key string
---@return string|nil unsupported failure
function InteractiveCacheBuild:_unsupported(kind, key)
  if kind == "map" then
    return self.generationId .. " map " .. key .. ": source has no supported map"
  elseif kind == "field-cell" then
    return self.generationId .. " field-cell " .. key .. ": canonical index has no such cell"
  elseif kind == "mon-portrait-page" or kind == "mon-icon-page" then
    return self.generationId .. " " .. kind .. " " .. key .. ": source has no such page"
  elseif kind == "message-bank" then
    return self.generationId .. " message-bank " .. key .. ": source has no such bank"
  elseif kind == "audio-bank" then
    return self.generationId .. " audio-bank " .. key .. ": source has no such closure"
  elseif kind == "script-member" then
    return self.generationId .. " script-member " .. key .. ": source has no nonempty member"
  elseif kind == "map-data" then
    return self.generationId .. " map-data " .. key .. ": source has no field record"
  end
  return nil
end

---@param kind string
---@param key string
---@param urgency string
---@return boolean
---@return string|nil
function InteractiveCacheBuild:requestJob(kind, key, urgency)
  assert(not self.retired, "generation session is retired")
  ArtifactJobs.jobKey(kind, key)
  ArtifactJobs.priorityFor(urgency)
  self:_ensureInventoryLoaded()
  if kind == "map" then
    local mapId = canonicalMapId(key)
    if not self.sourceLoaded then
      self:_request(kind, key, urgency)
      return false, nil
    end
    if not self:_knownMap(mapId) then
      return false, self.generationId .. " map " .. key .. ": source has no supported map"
    end
  elseif kind == "field-cell" then
    if not self.sourceLoaded then
      if key:match("^[0-9]+-[0-9]+$") == nil then
        error("field-cell key is not canonical: " .. key, 0)
      end
      self:_request(kind, key, urgency)
      return false, nil
    end
    if self:_cellDescriptor(kind, key) == nil then
      return false, self.generationId .. " field-cell " .. key .. ": canonical index has no such cell"
    end
  elseif
    kind == "message-bank"
    or kind == "audio-bank"
    or kind == "script-member"
    or kind == "map-data"
    or kind == "mon-icon-page"
    or kind == "mon-portrait-page"
  then
    if not self:_answerable(kind) then
      self:_request(kind, key, urgency)
      if needsPageMembership(kind) then
        self:_needLayout(urgency)
      end
      return false, nil
    end
    if not self:_knownMember(kind, key) then
      return false, assert(self:_unsupported(kind, key), "member rejection needs its cause")
    end
  end
  local entry, deferred = self:_request(kind, key, urgency)
  if deferred then
    if needsPageMembership(kind) then
      self:_needLayout(urgency)
    end
    return false, nil
  end
  local ready, failure = self:_answer(entry)
  if not ready and failure == nil and not self.sourceLoaded then
    self:_needInventory(urgency)
  end
  return ready, failure
end

---@param kind string
---@param key string
---@param urgency string
---@return boolean
---@return string|nil
function InteractiveCacheBuild:retry(kind, key, urgency)
  assert(not self.retired, "generation session is retired")
  ArtifactJobs.jobKey(kind, key)
  local priority = ArtifactJobs.priorityFor(urgency)
  local entry = self.byKey[kind .. ":" .. key]
  if entry == nil or entry.failure == nil then
    error("only failed session jobs can be retried: " .. kind .. ":" .. key, 0)
  end
  -- A blocked parent was never submitted, so only its failed leaves go back
  -- to the pool; the blocked annotations clear and healthy siblings stay put.
  local leaves = {}
  local blocked = {}
  local seen = {}
  local function collect(target)
    if seen[target.jobKey] then
      return
    end
    seen[target.jobKey] = true
    if target.failure == nil then
      return
    end
    local plansOk, depsOrCause = pcall(ArtifactJobs.dependencies, target.kind, target.key, self:_plans())
    if not plansOk then
      leaves[#leaves + 1] = target
      return
    end
    local failedChild = false
    for _, dep in ipairs(depsOrCause) do
      local depEntry = self.byKey[dep.kind .. ":" .. dep.key]
      if depEntry ~= nil and depEntry.failure ~= nil then
        failedChild = true
        collect(depEntry)
      elseif depEntry == nil then
        failedChild = true
      end
    end
    if failedChild then
      blocked[#blocked + 1] = target
    else
      leaves[#leaves + 1] = target
    end
  end
  collect(entry)
  for _, leaf in ipairs(leaves) do
    if self.pool:status(leaf.jobKey) == "failed" then
      self.pool:retry(leaf.jobKey, priority)
      leaf.submitted = true
    end
    leaf.failure = nil
    leaf.ready = false
    leaf.validated = false
    leaf.poolState = nil
    leaf.urgency = urgency
    leaf.priority = priority
  end
  for _, parent in ipairs(blocked) do
    parent.failure = nil
    if priority < parent.priority then
      parent.urgency = urgency
      parent.priority = priority
      self:_promoteQueued(parent)
    end
  end
  self.followerChecked = false
  self.followerMemo = nil
  return self:_answer(entry)
end

---@param mapId integer
---@return boolean
function InteractiveCacheBuild:ensureField(mapId)
  assert(not self.retired, "generation session is retired")
  local ready, failure = self:requestField(mapId, "required")
  if ready then
    return true
  end
  if failure ~= nil then
    error(failure, 0)
  end
  return self:_blockOn("map", tostring(mapId))
end

---@param descriptor table<string, unknown>
---@return boolean
function InteractiveCacheBuild:ensureCell(descriptor)
  assert(not self.retired, "generation session is retired")
  local ready, failure = self:requestCell(descriptor, "required")
  if ready then
    return true
  end
  if failure ~= nil then
    error(failure, 0)
  end
  assert(isInteger(descriptor.matrixMemberId) and isInteger(descriptor.index), "field cell descriptor is required")
  return self:_blockOn("field-cell", descriptor.matrixMemberId .. "-" .. descriptor.index)
end

---@param kind string
---@param key string
---@return boolean
function InteractiveCacheBuild:_blockOn(kind, key)
  local jobKey = kind .. ":" .. key
  local rounds = 0
  while rounds < 10000 do
    rounds = rounds + 1
    if self.retired then
      error("generation session is retired: " .. jobKey, 0)
    end
    self:update()
    local entry = self.byKey[jobKey]
    if entry == nil then
      error(jobKey .. ": blocking wait has no registered interest", 0)
    end
    if entry.ready then
      return true
    end
    if entry.failure ~= nil then
      error(entry.failure, 0)
    end
    if not self:_awaitingPoolWork() then
      error(jobKey .. ": blocking wait made no progress", 0)
    end
    -- The parent itself is never named to the pool here: the wait only
    -- advances already-dispatched dependency work until it publishes.
    self.pool:waitForProgress()
  end
  error(jobKey .. ": blocking wait timed out", 0)
end

---@return boolean
function InteractiveCacheBuild:_awaitingPoolWork()
  for _, entry in ipairs(self.interest) do
    if not entry.ready and entry.failure == nil and entry.submitted then
      local state = self.pool:status(entry.jobKey)
      if state == "queued" or state == "running" or state == "prepared" then
        return true
      end
    end
  end
  return false
end

---@return boolean
function InteractiveCacheBuild:_bootstrapReady()
  local members = ArtifactJobs.bootstrapJobs(self.audioBankIds)
  local ready, _ = self:_milestoneAnswer(members)
  return ready
end

-- Reads the published inventory into retained state. The source leg needs
-- only the staged inventory; the page leg additionally needs a ready layout
-- so page membership is exact. Adoption dirties unsubmitted work once; later
-- updates reuse the retained record instead of re-reading it.
function InteractiveCacheBuild:_ensureInventoryLoaded()
  if not self.sourceLoaded then
    local plan, _ = SourcePlan.read(self.cacheFs, self:_identity())
    if plan ~= nil then
      self:_adoptSource(plan)
    end
  end
  if self.sourceLoaded and not self.pagesKnown then
    -- Page membership is exact only once the layout publishes; the receipt
    -- marker gates the attempt so the full inventory is not revalidated on
    -- every update while layout work is still running.
    local receipt = ArtifactState.read(self.cacheFs, self.generationId, "mon-layout", "global")
    local marker = type(receipt) == "table" and receipt.marker or nil
    if marker ~= nil and marker ~= self._layoutMarkerSeen then
      self._layoutMarkerSeen = marker
      local plans, _ = ArtifactJobs.publishedPlans(self.cacheFs, self:_identity())
      if plans ~= nil then
        self:_adoptPublished(plans)
      end
    end
  end
end

---@param plan table<string, unknown>
function InteractiveCacheBuild:_adoptSource(plan)
  ---@cast plan table<string, unknown>
  local audioBankIds = {}
  for _, bankPlan in ipairs(plan.audioPlan.bankPlans) do
    audioBankIds[#audioBankIds + 1] = bankPlan.bankId
  end
  table.sort(audioBankIds)
  local scriptMemberIds = {}
  for _, member in ipairs(plan.scriptPlan.members) do
    scriptMemberIds[#scriptMemberIds + 1] = member.memberId
  end
  table.sort(scriptMemberIds)
  local mapIds = {}
  for _, record in ipairs(plan.world.maps) do
    mapIds[#mapIds + 1] = record.id
  end
  table.sort(mapIds)
  self.messageBankIds = plan.messageBankIds
  self.audioBankIds = audioBankIds
  self.scriptMemberIds = scriptMemberIds
  self.mapDataIds = plan.mapDataIds
  self.mapIds = mapIds
  self.mapCellKeys = plan.mapCellKeys
  self.adopted = {
    indexBundle = plan.fieldCellIndexBundle,
    scriptPlan = plan.scriptPlan,
    audioPlan = plan.audioPlan,
    messageBankIds = plan.messageBankIds,
    audioBankIds = audioBankIds,
    scriptMemberIds = scriptMemberIds,
    mapDataIds = plan.mapDataIds,
    mapIds = mapIds,
    mapCellKeys = plan.mapCellKeys,
    world = plan.world,
  }
  self.sourceLoaded = true
  self.depMemo = {}
  self:_replanUnsubmitted()
end

---@param plans ArtifactJobs.Plans
function InteractiveCacheBuild:_adoptPublished(plans)
  local function copyList(values)
    local out = {}
    for _, value in ipairs(values or {}) do
      out[#out + 1] = value
    end
    return out
  end
  self.messageBankIds = copyList(plans.messageBankIds)
  self.audioBankIds = copyList(plans.audioBankIds)
  self.scriptMemberIds = copyList(plans.scriptMemberIds)
  self.iconPageIds = copyList(plans.iconPageIds)
  self.portraitPageIds = copyList(plans.portraitPageIds)
  self.mapDataIds = copyList(plans.mapDataIds)
  self.mapIds = copyList(plans.mapIds)
  self.mapCellKeys = plans.mapCellKeys
  self.adopted = plans
  self.sourceLoaded = true
  self.pagesKnown = true
  self.depMemo = {}
  self:_replanUnsubmitted()
end

-- Newly adopted membership can only add answers, so unsubmitted work plans
-- again from scratch while submitted work keeps its pool lifecycle.
-- Milestone members that were unknowable before adoption register now under
-- their recorded urgency and join the same bounded planning.
function InteractiveCacheBuild:_replanUnsubmitted()
  for _, entry in ipairs(self.interest) do
    if not entry.ready and entry.failure == nil and not entry.submitted then
      entry.validated = false
      self.dirty[entry.jobKey] = true
    end
  end
  for name, urgency in pairs(self.milestones) do
    for _, member in ipairs(self:_milestoneMembers(name)) do
      local entry = self:_register(member.kind, member.key, urgency)
      if not entry.ready and entry.failure == nil and not entry.submitted then
        self.dirty[entry.jobKey] = true
      end
    end
  end
  self.parked = {}
  self.followerChecked = false
  self.followerMemo = nil
end

-- Observes already-submitted work for terminal transitions outside the
-- planning budget: transitions are worker-driven facts, naturally bounded
-- per update by physical completions, while the budget paces planning.
-- A ready transition validates immediately; a failed one records its cause.
-- Either dirties the affected parents and reopens parked sweep work.
function InteractiveCacheBuild:_pollSubmitted()
  local progress = false
  for _, entry in ipairs(self.interest) do
    if not entry.ready and entry.failure == nil and entry.submitted then
      local state, details = self.pool:status(entry.jobKey)
      if state ~= entry.poolState then
        entry.poolState = state
        if state == "ready" then
          progress = true
          if ArtifactJobs.validate(self.cacheFs, self.generationId, entry.kind, entry.key, self:_plans()) then
            entry.ready = true
          else
            entry.failure = self.generationId
              .. " "
              .. entry.kind
              .. " "
              .. entry.key
              .. ": published output fails its family validator"
          end
          self:_dirtyParents(entry.jobKey)
        elseif state == "failed" then
          progress = true
          local message = details and details.error or "compiler job failed"
          entry.failure = entry.jobKey .. ": " .. tostring(message)
          self:_dirtyParents(entry.jobKey)
        end
      end
    end
  end
  if progress then
    for jobKey in pairs(self.parked) do
      self.dirty[jobKey] = true
    end
    self.parked = {}
  end
  return progress
end

---@param budget InteractiveCacheBuild.Budget|nil
function InteractiveCacheBuild:_processDirty(budget)
  -- A budget pause lasts exactly one pass, so parked sweep work rejoins
  -- planning on the next pass even when workers report no new progress.
  -- Entries that still cannot run re-park; adoption and pool progress keep
  -- their existing reopen paths.
  for jobKey in pairs(self.parked) do
    self.dirty[jobKey] = true
  end
  self.parked = {}
  local ledger = { bound = self:_sweepBound(), outstanding = self:_outstandingSweep() }
  local pending = {}
  for jobKey in pairs(self.dirty) do
    local entry = self.byKey[jobKey]
    if entry ~= nil and not entry.ready and entry.failure == nil then
      pending[#pending + 1] = entry
    end
  end
  table.sort(pending, function(left, right)
    if left.priority == right.priority then
      return left.jobKey < right.jobKey
    end
    return left.priority < right.priority
  end)
  local paused = false
  for _, entry in ipairs(pending) do
    if paused or (budget ~= nil and budget.exhausted) then
      paused = true
      if entry.priority == 100 then
        self.parked[entry.jobKey] = true
        self.dirty[entry.jobKey] = nil
      end
    else
      local outcome = self:_ensure(entry, nil, budget, ledger)
      if outcome == "settled" then
        self.dirty[entry.jobKey] = nil
      elseif outcome == "parked" then
        self.parked[entry.jobKey] = true
        self.dirty[entry.jobKey] = nil
      elseif outcome == "paused" then
        paused = true
        if entry.priority == 100 then
          self.parked[entry.jobKey] = true
          self.dirty[entry.jobKey] = nil
        end
      end
    end
  end
end

function InteractiveCacheBuild:_fillSweep()
  if not self.sourceLoaded then
    if self.pendingFillDone then
      return
    end
    self.pendingFillDone = true
    -- Page, cell and map membership is still unknown, so only the fixed
    -- global families join the sweep until the inventory publishes.
    for _, kind in ipairs({ "items", "bag", "message-summary", "script-summary", "audio-summary", "mon-summary" }) do
      local entry = self:_register(kind, "global", "sweep")
      if not entry.ready and entry.failure == nil then
        self.dirty[entry.jobKey] = true
      end
    end
    return
  end
  if self.loadedFillDone then
    return
  end
  self.loadedFillDone = true
  for _, job in ipairs(ArtifactJobs.completeJobs(assert(self.adopted, "sweep needs its adopted inventory"))) do
    local entry = self:_register(job.kind, job.key, "sweep")
    if not entry.ready and entry.failure == nil then
      self.dirty[entry.jobKey] = true
    end
  end
end

function InteractiveCacheBuild:update()
  assert(not self.retired, "generation session is retired")
  self.pool:update()
  self:_ensureInventoryLoaded()
  local budget = { used = 0, start = nil, exhausted = false }
  self:_pollSubmitted()
  self:_processDirty(budget)
  if self.sweepEnabled and self:_bootstrapReady() then
    if self.milestones["field-core"] == nil then
      self.milestones["field-core"] = "near"
    end
    for _, member in ipairs(self:_milestoneMembers("field-core")) do
      local entry, deferred = self:_request(member.kind, member.key, self.milestones["field-core"])
      if not deferred then
        self.dirty[entry.jobKey] = true
      end
    end
    self:_fillSweep()
  end
  self:_publishMilestone("bootstrap")
  self:_publishMilestone("field-core")
end

---@return table<string, unknown>
function InteractiveCacheBuild:status()
  local ready, queued, running = 0, 0, 0
  local failures = {}
  for _, entry in ipairs(self.interest) do
    if entry.failure ~= nil then
      failures[#failures + 1] = entry.failure
    elseif entry.ready then
      ready = ready + 1
    elseif entry.submitted then
      local state = self.pool:status(entry.jobKey)
      if state == "ready" then
        if ArtifactJobs.validate(self.cacheFs, self.generationId, entry.kind, entry.key, self:_plans()) then
          entry.ready = true
          -- A ready mark must wake waiting parents no matter which path
          -- observes it first; the poller below maintains the same rule, so
          -- an observation here cannot silently strand them instead.
          self:_dirtyParents(entry.jobKey)
          ready = ready + 1
        else
          entry.failure = self.generationId
            .. " "
            .. entry.kind
            .. " "
            .. entry.key
            .. ": published output fails its family validator"
          self:_dirtyParents(entry.jobKey)
          failures[#failures + 1] = entry.failure
        end
      elseif state == "failed" then
        local _, details = self.pool:status(entry.jobKey)
        entry.failure = entry.jobKey .. ": " .. tostring(details and details.error or "compiler job failed")
        self:_dirtyParents(entry.jobKey)
        failures[#failures + 1] = entry.failure
      elseif state == "running" or state == "prepared" then
        running = running + 1
      else
        queued = queued + 1
      end
    else
      queued = queued + 1
    end
  end
  table.sort(failures)
  local bootstrapState, fieldCoreState = "pending", "pending"
  if not self.retired then
    local bootstrapMembers = ArtifactJobs.bootstrapJobs(self.audioBankIds)
    local bootstrapReady, bootstrapFailure = self:_milestoneAnswer(bootstrapMembers)
    if bootstrapReady then
      bootstrapState = "ready"
    elseif bootstrapFailure ~= nil then
      bootstrapState = "failed"
    end
    if self.milestones["field-core"] ~= nil then
      local coreReady, coreFailure = self:_milestoneAnswer(self:_milestoneMembers("field-core"))
      if coreReady then
        fieldCoreState = "ready"
      elseif coreFailure ~= nil then
        fieldCoreState = "failed"
      end
    end
  end
  local complete = bootstrapState == "ready"
    and fieldCoreState == "ready"
    and #failures == 0
    and (ready + queued + running) > 0
    and queued == 0
    and running == 0
  return {
    generationId = self.generationId,
    epoch = self.epoch,
    bootstrap = bootstrapState,
    fieldCore = fieldCoreState,
    enumerated = #self.interest,
    ready = ready,
    queued = queued,
    running = running,
    failed = #failures,
    failures = failures,
    complete = complete,
    enumerationComplete = self.sourceLoaded and self.pagesKnown or false,
  }
end

function InteractiveCacheBuild:retire()
  if self.retired then
    return
  end
  self.retired = true
  -- Logical interest ends here; executing physical slots stay charged to the
  -- pool until their terminal reply or joined exit. Late old-epoch output
  -- can no longer publish through this session. The session owns no source
  -- reader, so retirement closes nothing itself.
  self.pool:retireSelection(self.epoch)
  self.interest = {}
  self.byKey = {}
  self.dirty = {}
  self.edges = {}
  self.parked = {}
  self.depMemo = {}
  self.adopted = nil
  self.sourceLoaded = false
  self.pagesKnown = false
  self.audioBankIds = {}
  self.scriptMemberIds = {}
  self.iconPageIds = {}
  self.portraitPageIds = {}
  self.mapIds = {}
  self.mapCellKeys = {}
  self.followerChecked = false
  self.followerMemo = nil
  self.layoutMarkerSeen = nil
end

return InteractiveCacheBuild
