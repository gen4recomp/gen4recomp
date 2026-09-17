-- One generation session for bootstrap, field core and exhaustive warmup.
-- Construction performs no source work: it validates its identity, recovers
-- publication, selects the epoch and starts from empty retained state plus
-- the two source-static membership lists. Public requests only register
-- canonical interest and report retained answers; only update advances
-- planning, validation, adoption, enrollment and submission under one
-- shared 32-node/2ms pump, required demand first. One worker-compiled
-- inventory, adopted once published, supplies every source-derived
-- membership; mon page membership follows once the layout publishes. Until
-- then requests needing those families stay pending, failed prerequisites
-- settle their blocked demand with their causal identity, and status and
-- outcomes observe retained facts without cache IO or validation.

local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local ArtifactState = require("romdump.src.build.ArtifactState")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
local SourcePlan = require("romdump.src.build.SourcePlan")

---@class InteractiveCacheBuild.DependencyCursor
---@field deps { kind: string, key: string }[]
---@field complete boolean
---@field index integer

---@class InteractiveCacheBuild.EnrollCursor
---@field pending { milestone: string|nil, kind: string, key: string, urgency: string|nil }[]
---@field index integer

---@class InteractiveCacheBuild.SweepCursor
---@field jobs { kind: string, key: string }[]
---@field index integer

---@class InteractiveCacheBuild.Interest
---@field kind string
---@field key string
---@field jobKey string
---@field urgency string
---@field priority integer
---@field submitted boolean
---@field ready boolean
---@field validated boolean
---@field validationPending boolean pool reports ready, family validation queued under the pump budget
---@field failure string|nil
---@field failureClass string|nil source-exclusion, dependency, job, validation or planning on failed rows
---@field causeJobKey string|nil deepest failed leaf identity when a dependency failed
---@field poolState string|nil last observed pool state
---@field cursor InteractiveCacheBuild.DependencyCursor|nil private resume position for bounded dependency traversal
---@field direct boolean|nil true once a public single-request method claims this entry; milestone enrollment never sets it

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
---@field depMemo table<string, { kind: string, key: string }[]> retained final dependency edges
---@field pendingFillDone boolean
---@field loadedFillDone boolean
---@field enrollCursor InteractiveCacheBuild.EnrollCursor|nil private incremental membership enrollment after adoption
---@field roster table<string, { kind: string, key: string }[]> retained milestone membership per requested scope
---@field autoCoreNearDone boolean automatic field-core near intent already registered once
---@field layoutAttemptConsumed boolean a layout adoption attempt already ran against the current owner state
---@field sweepCursor InteractiveCacheBuild.SweepCursor|nil private incremental sweep enumeration after adoption
---@field planningPending boolean runnable local planning remains from the last pump
---@field followerMemo string|nil retained follower diagnostic
---@field followerChecked boolean
local InteractiveCacheBuild = {}
InteractiveCacheBuild.__index = InteractiveCacheBuild

---@class InteractiveCacheBuild.Budget
---@field used integer
---@field start number|nil slice starts at the first planning node
---@field exhausted boolean
---@field worked boolean an admitted planning node ran during this pump

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
    enrollCursor = nil,
    roster = {},
    autoCoreNearDone = false,
    layoutAttemptConsumed = false,
    sweepCursor = nil,
    planningPending = false,
    followerMemo = nil,
    followerChecked = false,
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
  -- Unknown dynamic membership is absent, never an empty final list.
  -- Source-static selections are always known; source-derived selections
  -- appear once the worker inventory is adopted and page selections once
  -- the layout is adopted. Known-empty lists stay present empty arrays.
  local plans = {
    messageBankIds = self.messageBankIds,
    mapDataIds = self.mapDataIds,
  }
  if self.sourceLoaded then
    plans.audioBankIds = self.audioBankIds
    plans.scriptMemberIds = self.scriptMemberIds
    plans.mapIds = self.mapIds
    plans.mapCellKeys = self.mapCellKeys
  end
  if self.pagesKnown then
    plans.iconPageIds = self.iconPageIds
    plans.portraitPageIds = self.portraitPageIds
  end
  return plans
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
  budget.worked = true
  return true
end

---@param kind string
---@param key string
---@param plans ArtifactJobs.Plans
---@param budget InteractiveCacheBuild.Budget|nil
---@return { kind: string, key: string }[]|nil
---@return string|nil status settled, paused or the planning failure
---@return boolean|nil complete final only when settled
function InteractiveCacheBuild:_dependencies(kind, key, plans, budget)
  -- Retained final edges cost no planning work to re-read: charging the
  -- per-pass budget for a memo hit lets a large pending family shadow every
  -- entry sorted after it, starving ready parents indefinitely. Only
  -- uncached planning calls consume the slice.
  local cached = self.depMemo[kind .. ":" .. key]
  if cached ~= nil then
    return cached, "settled", true
  end
  if not self:_spendNode(budget) then
    return nil, "paused", nil
  end
  local plansOk, depsOrCause, complete = pcall(ArtifactJobs.dependencies, kind, key, plans)
  if not plansOk then
    return nil, tostring(depsOrCause), nil
  end
  for _, dep in ipairs(depsOrCause) do
    local parents = self.edges[dep.kind .. ":" .. dep.key]
    if parents == nil then
      parents = {}
      self.edges[dep.kind .. ":" .. dep.key] = parents
    end
    parents[kind .. ":" .. key] = true
  end
  -- Only a final list is memoized: incomplete edges still wake their
  -- parents through the reverse map above, but the list is recomputed
  -- once adoption can complete it.
  if complete then
    self.depMemo[kind .. ":" .. key] = depsOrCause
  end
  return depsOrCause, "settled", complete ~= false
end

---@param kind string
---@param key string
---@param budget InteractiveCacheBuild.Budget|nil
---@return boolean|nil valid nil when the pump budget denies the call
---@return table<string, unknown>|nil validated source plan for immediate adoption
function InteractiveCacheBuild:_validate(kind, key, budget)
  if not self:_spendNode(budget) then
    return nil, nil
  end
  return ArtifactJobs.validate(self.cacheFs, self.generationId, kind, key, self:_plans(), self:_identity())
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
      validationPending = false,
      failure = nil,
      failureClass = nil,
      causeJobKey = nil,
      poolState = nil,
      cursor = nil,
    }
    self.byKey[jobKey] = entry
    self.interest[#self.interest + 1] = entry
  elseif priority < entry.priority then
    entry.urgency = urgency
    entry.priority = priority
    -- A stronger urgency revisits already traversed prerequisite edges:
    -- rewinding the private cursor re-registers visited dependencies under
    -- the new urgency without duplicating jobs or losing physical slots.
    -- Upgrades strictly decrease priority, so the rewind cannot oscillate.
    entry.cursor = nil
    if not entry.ready and entry.failure == nil then
      self.dirty[entry.jobKey] = true
    end
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
---@return string outcome terminal, waiting, parked or paused
function InteractiveCacheBuild:_submit(entry, budget, ledger)
  if entry.ready or entry.failure ~= nil then
    return "terminal"
  end
  -- A pool-reported ready mark never settles here: the scheduled family
  -- validator runs under the shared pump budget and only its success marks
  -- readiness. A rejection after execution is a validation failure.
  if entry.validationPending then
    local valid, plan = self:_validate(entry.kind, entry.key, budget)
    if valid == nil then
      return "paused"
    end
    entry.validationPending = false
    entry.validated = true
    if valid then
      entry.ready = true
      if plan ~= nil then
        self:_adoptValidated(plan)
      end
      self:_dirtyParents(entry.jobKey)
      return "terminal"
    end
    entry.failure = self.generationId
      .. " "
      .. entry.kind
      .. " "
      .. entry.key
      .. ": published output fails its family validator"
    entry.failureClass = "validation"
    entry.causeJobKey = nil
    self:_dirtyParents(entry.jobKey)
    return "terminal"
  end
  if not entry.validated then
    local valid, plan = self:_validate(entry.kind, entry.key, budget)
    if valid == nil then
      return "paused"
    end
    entry.validated = true
    if valid then
      entry.ready = true
      if plan ~= nil then
        self:_adoptValidated(plan)
      end
      self:_dirtyParents(entry.jobKey)
      return "terminal"
    end
  end
  if not entry.submitted then
    local payload = self:_payload(entry.kind, entry.key)
    if payload == nil then
      return "parked"
    end
    if entry.priority == 100 then
      local bound, outstanding = self:_sweepBound(), self:_outstandingSweep()
      if ledger ~= nil then
        bound, outstanding = ledger.bound, ledger.outstanding
      end
      if outstanding >= bound then
        return "parked"
      end
    end
    if not self:_spendNode(budget) then
      return "paused"
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
      entry.failureClass = "job"
      entry.causeJobKey = nil
      self:_dirtyParents(entry.jobKey)
      return "terminal"
    end
    return "waiting"
  end
  local state, details = self.pool:status(entry.jobKey)
  entry.poolState = state
  if state == "ready" then
    entry.validationPending = true
    self.dirty[entry.jobKey] = true
    return "waiting"
  elseif state == "failed" then
    local message = details and details.error or "compiler job failed"
    entry.failure = entry.jobKey .. ": " .. tostring(message)
    entry.failureClass = "job"
    entry.causeJobKey = nil
    self:_dirtyParents(entry.jobKey)
    return "terminal"
  end
  return "waiting"
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
---@return string|nil exclusion failure once authoritative membership disproves the entry
function InteractiveCacheBuild:_deferredExclusion(entry)
  -- Pump-side supportedness: the same membership rule the public methods
  -- apply, resolved here once the authoritative roster is known so one
  -- request plus updates suffices. Unknown membership never excludes;
  -- failed metadata is a dependency failure, never an exclusion. Only
  -- families whose membership arrives with adopted metadata resolve here:
  -- source-static membership (message banks, field records) is known at
  -- construction and decided at request time, so the pump leaves enrolled
  -- static members to their retained answers.
  local kind, key = entry.kind, entry.key
  if kind == "map" then
    if not self.sourceLoaded then
      return nil
    end
    if self:_knownMap(canonicalMapId(key)) then
      return nil
    end
    return self.generationId .. " map " .. key .. ": source has no supported map"
  elseif kind == "field-cell" then
    if not self.sourceLoaded then
      return nil
    end
    if self:_cellDescriptor(kind, key) ~= nil then
      return nil
    end
    return self.generationId .. " field-cell " .. key .. ": canonical index has no such cell"
  elseif kind == "audio-bank" or kind == "script-member" then
    if not self.sourceLoaded then
      return nil
    end
    if self:_knownMember(kind, key) then
      return nil
    end
    return assert(self:_unsupported(kind, key), "member rejection needs its cause")
  elseif kind == "mon-icon-page" or kind == "mon-portrait-page" then
    if not self.pagesKnown then
      return nil
    end
    if self:_knownMember(kind, key) then
      return nil
    end
    return assert(self:_unsupported(kind, key), "member rejection needs its cause")
  end
  return nil
end

---@param entry InteractiveCacheBuild.Interest
---@param trail table<string, boolean>|nil canonical identities on the current descent
---@param budget InteractiveCacheBuild.Budget|nil
---@param ledger { bound: integer, outstanding: integer }|nil per-pass sweep admission account
---@return string outcome terminal, waiting, parked or paused
function InteractiveCacheBuild:_ensure(entry, trail, budget, ledger)
  if entry.ready or entry.failure ~= nil then
    return "terminal"
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
      entry.failureClass = "planning"
      entry.causeJobKey = nil
      self:_dirtyParents(entry.jobKey)
    end
    return "terminal"
  end
  trail[entry.jobKey] = true
  local exclusion = self:_deferredExclusion(entry)
  if exclusion ~= nil then
    self:_exclude(entry, exclusion)
    self:_dirtyParents(entry.jobKey)
    trail[entry.jobKey] = nil
    return "terminal"
  end
  local cursor = entry.cursor
  if cursor == nil then
    local deps, depsStatus, complete = self:_dependencies(entry.kind, entry.key, self:_plans(), budget)
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
        entry.failureClass = "planning"
        entry.causeJobKey = nil
        self:_dirtyParents(entry.jobKey)
      end
      return "terminal"
    end
    assert(complete ~= nil, "settled dependencies carry their completeness")
    cursor = { deps = deps, complete = complete, index = 1 }
    entry.cursor = cursor
  end
  while cursor.index <= #cursor.deps do
    local dep = cursor.deps[cursor.index]
    local depEntry = self:_register(dep.kind, dep.key, entry.urgency)
    if not depEntry.ready and depEntry.failure == nil then
      self.dirty[depEntry.jobKey] = true
    end
    local child = self:_ensure(depEntry, trail, budget, ledger)
    if child == "paused" then
      trail[entry.jobKey] = nil
      return "paused"
    end
    if depEntry.failure ~= nil and entry.failure == nil then
      entry.cursor = nil
      entry.failure = self.generationId
        .. " "
        .. entry.kind
        .. " "
        .. entry.key
        .. ": prerequisite "
        .. depEntry.jobKey
        .. " failed: "
        .. depEntry.failure
      entry.failureClass = "dependency"
      entry.causeJobKey = depEntry.causeJobKey or depEntry.jobKey
      self:_dirtyParents(entry.jobKey)
      trail[entry.jobKey] = nil
      return "terminal"
    end
    cursor.index = cursor.index + 1
  end
  -- A resumed traversal restarts past settled children, so re-scan for
  -- failures recorded while this entry waited: the deepest causal leaf
  -- settles the blocked parent with a dependency disposition.
  for _, dep in ipairs(cursor.deps) do
    local depEntry = self.byKey[dep.kind .. ":" .. dep.key]
    if depEntry ~= nil and depEntry.failure ~= nil and entry.failure == nil then
      entry.cursor = nil
      entry.failure = self.generationId
        .. " "
        .. entry.kind
        .. " "
        .. entry.key
        .. ": prerequisite "
        .. depEntry.jobKey
        .. " failed: "
        .. depEntry.failure
      entry.failureClass = "dependency"
      entry.causeJobKey = depEntry.causeJobKey or depEntry.jobKey
      self:_dirtyParents(entry.jobKey)
      trail[entry.jobKey] = nil
      return "terminal"
    end
  end
  -- Warm reuse never occupies a worker: an entry whose family validator
  -- already accepts its published output settles ready without dispatch,
  -- even while planning prerequisites are still incomplete. Validation
  -- failure simply continues to the completeness and dispatch gates below.
  if not entry.validated and not entry.validationPending then
    local valid, plan = self:_validate(entry.kind, entry.key, budget)
    if valid == nil then
      trail[entry.jobKey] = nil
      return "paused"
    end
    entry.validated = true
    if valid then
      entry.cursor = nil
      entry.ready = true
      if plan ~= nil then
        self:_adoptValidated(plan)
      end
      self:_dirtyParents(entry.jobKey)
      trail[entry.jobKey] = nil
      return "terminal"
    end
  end
  -- An incomplete list never dispatches its parent: the entry waits until
  -- adoption completes the membership and the reverse edges wake it.
  if not cursor.complete then
    trail[entry.jobKey] = nil
    return "waiting"
  end
  entry.cursor = nil
  -- A parent never occupies a worker while its children are still pending:
  -- summary and map workers read published children, so dispatch waits until
  -- every dependency is ready. Settled children wake the parent through the
  -- reverse edges; the next update re-drives pending parents.
  for _, dep in ipairs(cursor.deps) do
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
        entry.failureClass = "planning"
        entry.causeJobKey = dep.kind .. ":" .. dep.key
        self:_dirtyParents(entry.jobKey)
      end
      trail[entry.jobKey] = nil
      return "terminal"
    end
    if not depEntry.ready then
      trail[entry.jobKey] = nil
      return "waiting"
    end
  end
  trail[entry.jobKey] = nil
  return self:_submit(entry, budget, ledger)
end

---@param entry InteractiveCacheBuild.Interest
---@return boolean
---@return string|nil
function InteractiveCacheBuild:_answer(entry)
  -- Retained observation only: registration reports pending until the pump
  -- establishes ready or failure. No cache IO, planning or validation here.
  if entry.failure ~= nil then
    return false, entry.failure
  end
  if entry.ready then
    return true, nil
  end
  return false, nil
end

---@param kind string
---@param key string
---@param urgency string
---@return InteractiveCacheBuild.Interest entry
function InteractiveCacheBuild:_request(kind, key, urgency)
  -- Registration only: record canonical interest for the pump. Planning
  -- prerequisites are expressed as dependency edges and pulled by the pump
  -- itself, so no inventory, layout, validation or worker work happens here.
  local entry = self:_register(kind, key, urgency)
  if not entry.ready and entry.failure == nil then
    self.dirty[entry.jobKey] = true
  end
  return entry
end

---@param kind string
---@param key string
---@param urgency string
---@return InteractiveCacheBuild.Interest entry
function InteractiveCacheBuild:_requestDirect(kind, key, urgency)
  -- A public single-request claim: registration plus retained direct
  -- interest, so settlement can tell requested work from enrolled members
  -- and dependency-discovered prerequisites.
  local entry = self:_request(kind, key, urgency)
  entry.direct = true
  return entry
end

---@param name string bootstrap or field-core
---@param members { kind: string, key: string }[]
---@return boolean ready
---@return string|nil failure
function InteractiveCacheBuild:_milestoneAnswer(name, members)
  -- Terminal failure takes precedence over pending siblings: every member
  -- is inspected for a failure before a pending aggregate is claimed, and
  -- readiness additionally requires complete enrollment and membership.
  -- Broken build work outranks absent membership in the aggregate; the
  -- per-member answer still carries its own exact exclusion.
  -- A field-core answer additionally requires its final scope knowledge:
  -- adopted source inventory and adopted page membership. Discovery-time
  -- readiness never certifies the scope; bootstrap answers from its own
  -- roster without a page-membership gate.
  local failure, exclusion = nil, nil
  for _, member in ipairs(members) do
    local entry = self.byKey[member.kind .. ":" .. member.key]
    if entry ~= nil and entry.failure ~= nil then
      if entry.failureClass == "source-exclusion" then
        if exclusion == nil then
          exclusion = entry.failure
        end
      elseif failure == nil then
        failure = entry.failure
      end
    end
  end
  if failure ~= nil then
    return false, failure
  end
  if exclusion ~= nil then
    return false, exclusion
  end
  if name == "field-core" and (not self.sourceLoaded or not self.pagesKnown) then
    return false, nil
  end
  for _, member in ipairs(members) do
    local entry = self.byKey[member.kind .. ":" .. member.key]
    if entry == nil or not entry.ready then
      return false, nil
    end
  end
  return true, nil
end

---@param name string
---@return { kind: string, key: string }[]
function InteractiveCacheBuild:_milestoneMembers(name)
  -- The single membership construction site: only update and adoption
  -- transitions call it, never public requests, status or publication.
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

---@param name string
---@return boolean ready
---@return string|nil failure
function InteractiveCacheBuild:_retainedMilestoneAnswer(name)
  -- Retained observation only: an unbuilt roster is pending knowledge,
  -- never a vacuous success. No construction, IO or validation here.
  local members = self.roster[name]
  if members == nil then
    return false, nil
  end
  return self:_milestoneAnswer(name, members)
end

---@param name string
---@param enroll boolean queue unknown members for pump enrollment
function InteractiveCacheBuild:_refreshRoster(name, enroll)
  -- Rebuild one retained roster from current adopted knowledge: the new
  -- array replaces its discovery-time predecessor, so the scope predicate
  -- always observes final membership without confusing the two.
  self.roster[name] = self:_milestoneMembers(name)
  if enroll then
    self:_enqueueRosterDelta(name)
  end
end

---@param name string
function InteractiveCacheBuild:_enqueueRosterDelta(name)
  -- Enroll only members the session has never seen: previously enrolled
  -- work keeps its entry, urgency and physical slot through adoption.
  local members = self.roster[name]
  if members == nil then
    return
  end
  local pending = {}
  for _, member in ipairs(members) do
    if self.byKey[member.kind .. ":" .. member.key] == nil then
      pending[#pending + 1] = {
        milestone = name,
        kind = member.kind,
        key = member.key,
        urgency = self.milestones[name],
      }
    end
  end
  if #pending == 0 then
    return
  end
  local cursor = self.enrollCursor
  if cursor == nil then
    cursor = { pending = {}, index = 1 }
    self.enrollCursor = cursor
  end
  for _, item in ipairs(pending) do
    cursor.pending[#cursor.pending + 1] = item
  end
end

---@param budget InteractiveCacheBuild.Budget|nil
function InteractiveCacheBuild:_buildPendingRosters(budget)
  -- First construction for every requested scope runs here under one
  -- admitted update step, never in a public request. Later rebuilds happen
  -- synchronously inside adoption, so retained answers stay current.
  local pending = {}
  for name, _ in pairs(self.milestones) do
    if self.roster[name] == nil then
      pending[#pending + 1] = name
    end
  end
  if self.sweepEnabled and self.milestones["bootstrap"] == nil and self.roster["bootstrap"] == nil then
    pending[#pending + 1] = "bootstrap"
  end
  if #pending == 0 then
    return
  end
  if not self:_spendNode(budget) then
    return
  end
  for _, name in ipairs(pending) do
    self:_refreshRoster(name, self.milestones[name] ~= nil)
  end
end

---@return boolean some retained demand can use the worker inventory
function InteractiveCacheBuild:_needsSourceDemand()
  if self.sweepEnabled then
    return true
  end
  if self.milestones["bootstrap"] ~= nil or self.milestones["field-core"] ~= nil then
    return true
  end
  for _, entry in ipairs(self.interest) do
    local kind = entry.kind
    if needsSourceInventory(kind) or needsPageMembership(kind) then
      return true
    end
    if kind == "source-plan" or kind == "mon-layout" or kind == "mon-catalog" or kind == "mon-summary" then
      return true
    end
  end
  return false
end

---@return boolean some retained demand can use mon page membership
function InteractiveCacheBuild:_needsPageDemand()
  if self.sweepEnabled then
    return true
  end
  if self.milestones["field-core"] ~= nil then
    return true
  end
  for _, entry in ipairs(self.interest) do
    if needsPageMembership(entry.kind) then
      return true
    end
  end
  return false
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
  -- Update-owned once-only publication from retained final membership:
  -- public polling never publishes, and an unbuilt roster publishes nothing.
  if self.recorded[name] then
    return
  end
  local members = self.roster[name]
  if members == nil then
    return
  end
  local ready, _ = self:_milestoneAnswer(name, members)
  if not ready then
    return
  end
  if name == "field-core" then
    local followersErr = self:_followerError()
    if followersErr ~= nil then
      local entry = self.byKey["actors:global"]
      if entry ~= nil then
        entry.failure = self.generationId .. " actors global: " .. tostring(followersErr)
        entry.failureClass = "validation"
        entry.causeJobKey = nil
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

---@param entry InteractiveCacheBuild.Interest
---@param message string
---@return boolean
---@return string
function InteractiveCacheBuild:_exclude(entry, message)
  -- A syntactically valid but unsupported member keeps its retained
  -- interest and settles at once with a source-exclusion disposition.
  entry.failure = message
  entry.failureClass = "source-exclusion"
  entry.causeJobKey = nil
  return false, message
end

---@param name string
---@param urgency string
---@return boolean
---@return string|nil
function InteractiveCacheBuild:requestMilestone(name, urgency)
  assert(not self.retired, "generation session is retired")
  assert(name == "bootstrap" or name == "field-core", "milestones accept only bootstrap or field-core")
  ArtifactJobs.priorityFor(urgency)
  local current = self.milestones[name]
  local stronger = current ~= nil and ArtifactJobs.priorityFor(urgency) < ArtifactJobs.priorityFor(current)
  if current == nil or stronger then
    self.milestones[name] = urgency
  end
  -- Record new or stronger intent and answer from retained state: roster
  -- construction, enrollment, validation, submission and publication all
  -- belong to update. Metadata owners are scheduled once per new intent;
  -- stronger demand upgrades registered members in place while pending
  -- roster members enroll at the current urgency through the pump. An
  -- unchanged poll registers nothing and observes the retained answer.
  if current == nil then
    if not self.sourceLoaded then
      self:_request("source-plan", "global", urgency)
    end
    if not self.pagesKnown then
      self:_request("mon-layout", "global", urgency)
    end
  elseif stronger then
    local members = self.roster[name]
    if members ~= nil then
      for _, member in ipairs(members) do
        self:_register(member.kind, member.key, urgency)
      end
    end
  end
  return self:_retainedMilestoneAnswer(name)
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
  if not self.sourceLoaded then
    return self:_answer(self:_requestDirect("map", tostring(mapId), urgency))
  end
  if not self:_knownMap(mapId) then
    return self:_exclude(
      self:_requestDirect("map", tostring(mapId), urgency),
      self.generationId .. " map " .. tostring(mapId) .. ": source has no supported map"
    )
  end
  for _, cellKey in ipairs(self.mapCellKeys[mapId]) do
    self:_request("field-cell", cellKey, urgency)
  end
  return self:_answer(self:_requestDirect("map", tostring(mapId), urgency))
end

---@param descriptor table<string, unknown>
---@param urgency string
---@return boolean
---@return string|nil
function InteractiveCacheBuild:requestCell(descriptor, urgency)
  assert(not self.retired, "generation session is retired")
  assert(type(descriptor) == "table", "field cell descriptor is required")
  ArtifactJobs.priorityFor(urgency)
  if not self.sourceLoaded then
    if not (isInteger(descriptor.matrixMemberId) and isInteger(descriptor.index)) then
      error("field cell descriptor needs its canonical matrix and index", 0)
    end
    local key = descriptor.matrixMemberId .. "-" .. descriptor.index
    return self:_answer(self:_requestDirect("field-cell", key, urgency))
  end
  assert(
    isInteger(descriptor.matrixMemberId) and isInteger(descriptor.index),
    "field cell descriptor needs its canonical matrix and index"
  )
  local key = descriptor.matrixMemberId .. "-" .. descriptor.index
  local authoritative = self:_cellDescriptor("field-cell", key)
  if authoritative == nil then
    return self:_exclude(
      self:_requestDirect("field-cell", key, urgency),
      assert(self:_unsupported("field-cell", key), "member rejection needs its cause")
    )
  end
  return self:_answer(self:_requestDirect("field-cell", key, urgency))
end

---@param pageId integer
---@param urgency string
---@return boolean
---@return string|nil
function InteractiveCacheBuild:requestMonPortraitPage(pageId, urgency)
  assert(not self.retired, "generation session is retired")
  assert(isInteger(pageId) and pageId >= 0, "portrait page ID must be a non-negative integer")
  ArtifactJobs.priorityFor(urgency)
  if not self.pagesKnown then
    return self:_answer(self:_requestDirect("mon-portrait-page", tostring(pageId), urgency))
  end
  local supported = false
  for _, candidate in ipairs(self.portraitPageIds) do
    if candidate == pageId then
      supported = true
      break
    end
  end
  if not supported then
    return self:_exclude(
      self:_requestDirect("mon-portrait-page", tostring(pageId), urgency),
      self.generationId .. " mon-portrait-page " .. tostring(pageId) .. ": source has no such page"
    )
  end
  return self:_answer(self:_requestDirect("mon-portrait-page", tostring(pageId), urgency))
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
  if kind == "map" then
    local mapId = canonicalMapId(key)
    if not self.sourceLoaded then
      return self:_answer(self:_requestDirect(kind, key, urgency))
    end
    if not self:_knownMap(mapId) then
      return self:_exclude(
        self:_requestDirect(kind, key, urgency),
        self.generationId .. " map " .. key .. ": source has no supported map"
      )
    end
  elseif kind == "field-cell" then
    if not self.sourceLoaded then
      if key:match("^[0-9]+-[0-9]+$") == nil then
        error("field-cell key is not canonical: " .. key, 0)
      end
      return self:_answer(self:_requestDirect(kind, key, urgency))
    end
    if self:_cellDescriptor(kind, key) == nil then
      return self:_exclude(
        self:_requestDirect(kind, key, urgency),
        self.generationId .. " field-cell " .. key .. ": canonical index has no such cell"
      )
    end
  elseif
    kind == "message-bank"
    or kind == "audio-bank"
    or kind == "script-member"
    or kind == "map-data"
    or kind == "mon-icon-page"
    or kind == "mon-portrait-page"
  then
    local membershipKnown = true
    if needsSourceInventory(kind) and not self.sourceLoaded then
      membershipKnown = false
    end
    if needsPageMembership(kind) and not self.pagesKnown then
      membershipKnown = false
    end
    if not membershipKnown then
      return self:_answer(self:_requestDirect(kind, key, urgency))
    end
    if not self:_knownMember(kind, key) then
      return self:_exclude(
        self:_requestDirect(kind, key, urgency),
        assert(self:_unsupported(kind, key), "member rejection needs its cause")
      )
    end
  end
  return self:_answer(self:_requestDirect(kind, key, urgency))
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
  -- A blocked parent was never submitted, so only actually failed producer
  -- leaves go back to the pool; the blocked annotations clear and healthy
  -- siblings stay put. A permanent unsupported-member rejection stays
  -- explicit unless a failed producer leaf can be retried.
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
  local repaired = 0
  for _, leaf in ipairs(leaves) do
    local poolFailed = self.pool:status(leaf.jobKey) == "failed"
    if poolFailed then
      self.pool:retry(leaf.jobKey, priority)
      leaf.submitted = true
    end
    if poolFailed or leaf.failureClass ~= "source-exclusion" then
      -- Failed producer leaves go back to the pool; other derived
      -- failures requeue for pump revalidation. A permanent
      -- unsupported-member rejection stays explicit.
      leaf.failure = nil
      leaf.failureClass = nil
      leaf.causeJobKey = nil
      leaf.ready = false
      leaf.validated = false
      leaf.validationPending = false
      leaf.poolState = nil
      leaf.cursor = nil
      leaf.urgency = urgency
      leaf.priority = priority
      self.dirty[leaf.jobKey] = true
      repaired = repaired + 1
    end
  end
  if repaired > 0 then
    for _, parent in ipairs(blocked) do
      parent.failure = nil
      parent.failureClass = nil
      parent.causeJobKey = nil
      parent.cursor = nil
      if priority < parent.priority then
        parent.urgency = urgency
        parent.priority = priority
        self:_promoteQueued(parent)
      end
      if not parent.ready then
        self.dirty[parent.jobKey] = true
      end
    end
    self.followerChecked = false
    self.followerMemo = nil
  end
  if kind == "mon-layout" then
    -- Explicit repair re-arms layout adoption even when the deterministic
    -- marker is unchanged: failure is never latched by marker string.
    self.layoutAttemptConsumed = false
  end
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
    -- Local planning with an idle pool is progress still available: repump
    -- instead of waiting on nonexistent physical work. Only unfinished
    -- physical work earns a bounded wait; anything else is diagnosable.
    local status = self:status()
    if status.planningPending then
      -- Repump: the next update advances the remaining local work.
    elseif self:_awaitingPoolWork() then
      -- The parent itself is never named to the pool here: the wait only
      -- advances already-dispatched dependency work until it publishes.
      self.pool:waitForProgress()
    else
      error(jobKey .. ": blocking wait made no progress", 0)
    end
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

---@return boolean retained bootstrap scope is ready, never constructed here
function InteractiveCacheBuild:_retainedBootstrapReady()
  local members = self.roster["bootstrap"]
  if members == nil then
    return false
  end
  local ready, _ = self:_milestoneAnswer("bootstrap", members)
  return ready
end

-- Reads the published inventory into retained state. The source leg needs
-- only the staged inventory; the page leg additionally needs the published
-- layout plans. Adoption dirties unsubmitted work once; later updates reuse
-- the retained record instead of re-reading it.
---@param budget InteractiveCacheBuild.Budget|nil
function InteractiveCacheBuild:_ensureInventoryLoaded(budget)
  if not self.sourceLoaded then
    -- Scopes that cannot use the inventory never read it: an independent
    -- leaf stays small even when unrelated metadata happens to be cached.
    if self:_needsSourceDemand() then
      -- The adoption charge precedes the read: an exhausted slice defers
      -- without IO, and the next admitted step performs the single read.
      -- A fruitless poll leaves the slice clock unstarted: the admitted
      -- node stays charged, but the work clock still starts at the first
      -- spend below that transfers data or advances enrollment, so a
      -- missing inventory never starves the same update's sweep fill.
      local clockStarted = budget == nil or budget.start ~= nil
      if not self:_spendNode(budget) then
        return
      end
      local plan, _ = SourcePlan.read(self.cacheFs, self:_identity())
      if plan ~= nil then
        self:_adoptSource(plan)
      elseif not clockStarted and budget ~= nil then
        budget.start = nil
      end
    end
  end
  if self.sourceLoaded and not self.pagesKnown then
    local layoutEntry = self.byKey["mon-layout:global"]
    if layoutEntry ~= nil and layoutEntry.failure ~= nil then
      return
    end
    if not self:_needsPageDemand() then
      return
    end
    -- Automatic demand owns its metadata entry: sweep and automatic
    -- field-core intent schedule the layout owner exactly like an explicit
    -- milestone request does, so adoption has a validated transition.
    if layoutEntry == nil and (self.milestones["field-core"] ~= nil or self.sweepEnabled) then
      layoutEntry = self:_request("mon-layout", "global", self.milestones["field-core"] or "near")
    end
    -- No repeated rereads while layout work is still physically pending.
    if layoutEntry ~= nil and layoutEntry.submitted then
      local state = self.pool:status(layoutEntry.jobKey)
      if state == "queued" or state == "running" or state == "prepared" then
        return
      end
    end
    -- A ready owner always earns its adoption read: success adopts, and a
    -- still-unreadable plan set is an explicit planning failure on an
    -- owner that claims readiness, never an eternal pending state. The
    -- failure itself suppresses repeats until explicit repair.
    if layoutEntry ~= nil and layoutEntry.ready then
      -- The adoption charge precedes the read: an exhausted slice defers
      -- without IO, and the next admitted step performs the single read.
      if not self:_spendNode(budget) then
        return
      end
      local plans, reason = ArtifactJobs.publishedPlans(self.cacheFs, self:_identity())
      if plans ~= nil then
        self:_adoptPublished(plans)
      else
        layoutEntry.failure = self.generationId
          .. " mon-layout global: adopted layout has no usable page plans: "
          .. tostring(reason)
        layoutEntry.failureClass = "planning"
        layoutEntry.causeJobKey = nil
        self:_dirtyParents(layoutEntry.jobKey)
      end
      return
    end
    if layoutEntry == nil or not layoutEntry.validated or self.layoutAttemptConsumed then
      if layoutEntry ~= nil and not layoutEntry.submitted and layoutEntry.validated then
        -- A rejected pre-repair layout validation schedules ordinary repair
        -- through the normal pump: the entry stays dirty for submission.
        self.dirty[layoutEntry.jobKey] = true
      end
      if self.layoutAttemptConsumed and layoutEntry ~= nil then
        -- A consumed damaged attempt keeps its owner driven: clearing the
        -- stale validation forces the pump to re-read the owner, so repair
        -- surfaces as readiness and earns a fresh adoption read above.
        -- Plans themselves never poll.
        layoutEntry.validated = false
        layoutEntry.cursor = nil
        self.dirty[layoutEntry.jobKey] = true
      end
      return
    end
    -- A validated but unready owner attempts once against its staged
    -- receipt: a damaged plan set consumes the attempt without failing
    -- the still-compiling owner, so repair can surface through the drive
    -- above. No receipt, no attempt: cold compilation stays quiet. The
    -- adoption charge precedes the staged check, so an exhausted slice
    -- defers without IO.
    if not self:_spendNode(budget) then
      return
    end
    if not self:_layoutReceiptStaged() then
      return
    end
    local plans, _ = ArtifactJobs.publishedPlans(self.cacheFs, self:_identity())
    if plans ~= nil then
      self:_adoptPublished(plans)
    else
      self.layoutAttemptConsumed = true
      self.dirty[layoutEntry.jobKey] = true
    end
  end
end

---@return boolean the published layout receipt names the staged marker
function InteractiveCacheBuild:_layoutReceiptStaged()
  local MonCache = require("libs.assets.src.MonCache")
  local cacheFs = self.cacheFs
  local markerOk, marker = pcall(function()
    return cacheFs:read(MonCache.layoutMarkerPath())
  end)
  if not markerOk or type(marker) ~= "string" or marker == "" then
    return false
  end
  local receiptOk, receipt = pcall(function()
    return cacheFs:loadLua(ArtifactState.path("mon-layout", "global"))
  end)
  return receiptOk and type(receipt) == "table" and receipt.marker == marker
end

---@param plan table<string, unknown>
function InteractiveCacheBuild:_adoptValidated(plan)
  -- Immediate adoption of a just-validated source record. Published plans
  -- already carry page membership and must never be overwritten by the
  -- source leg.
  if not self.sourceLoaded then
    self:_adoptSource(plan)
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
  for _, entry in ipairs(self.interest) do
    entry.cursor = nil
  end
  self:_replanUnsubmitted()
  self:_refreshAdoptionRosters()
end

-- Adoption replaces retained rosters synchronously: answers observed after
-- this transition see final membership, and newly known members enroll
-- through the bounded cursor instead of a full re-enrollment loop.
function InteractiveCacheBuild:_refreshAdoptionRosters()
  for _, name in ipairs({ "bootstrap", "field-core" }) do
    if self.roster[name] ~= nil then
      self:_refreshRoster(name, self.milestones[name] ~= nil)
    end
  end
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
  for _, entry in ipairs(self.interest) do
    entry.cursor = nil
  end
  self:_replanUnsubmitted()
  self:_refreshAdoptionRosters()
end

-- Newly adopted membership can only add answers, so unsubmitted work plans
-- again from scratch while submitted work keeps its pool lifecycle.
-- Milestone members that were unknowable before adoption enroll
-- incrementally under the pump budget instead of one unbounded loop.
function InteractiveCacheBuild:_replanUnsubmitted()
  for _, entry in ipairs(self.interest) do
    if not entry.ready and entry.failure == nil and not entry.submitted then
      entry.validated = false
      entry.cursor = nil
      self.dirty[entry.jobKey] = true
    end
  end
  self.parked = {}
  self.sweepCursor = nil
  self.pendingFillDone = false
  self.loadedFillDone = false
  self.followerChecked = false
  self.followerMemo = nil
end

---@param budget InteractiveCacheBuild.Budget|nil
function InteractiveCacheBuild:_drainEnroll(budget)
  local cursor = self.enrollCursor
  if cursor == nil then
    return
  end
  while cursor.index <= #cursor.pending do
    if not self:_spendNode(budget) then
      return
    end
    local item = cursor.pending[cursor.index]
    cursor.index = cursor.index + 1
    -- Enrollment follows the current strongest intent, so a promotion that
    -- lands mid-drain reaches members the cursor has not visited yet.
    local urgency = item.urgency
    if item.milestone ~= nil and self.milestones[item.milestone] ~= nil then
      urgency = self.milestones[item.milestone]
    end
    local entry = self:_register(item.kind, item.key, assert(urgency, "enrollment needs its urgency"))
    if not entry.ready and entry.failure == nil then
      self.dirty[entry.jobKey] = true
    end
  end
  self.enrollCursor = nil
end

-- Observes already-submitted work for terminal transitions: transitions are
-- worker-driven facts, naturally bounded per update by physical
-- completions, while the budget paces planning. A ready transition only
-- queues family validation under the shared pump budget; a failed one
-- records its cause at once. Either wakes the affected parents.
function InteractiveCacheBuild:_pollSubmitted()
  for _, entry in ipairs(self.interest) do
    if not entry.ready and entry.failure == nil and entry.submitted and not entry.validationPending then
      local state, details = self.pool:status(entry.jobKey)
      if state ~= entry.poolState then
        entry.poolState = state
        if state == "ready" then
          entry.validationPending = true
          self.dirty[entry.jobKey] = true
        elseif state == "failed" then
          local message = details and details.error or "compiler job failed"
          entry.failure = entry.jobKey .. ": " .. tostring(message)
          entry.failureClass = "job"
          entry.causeJobKey = nil
          self:_dirtyParents(entry.jobKey)
        end
      end
    end
  end
end

---@param budget InteractiveCacheBuild.Budget|nil
---@param allowSweep boolean
function InteractiveCacheBuild:_pumpPlanning(budget, allowSweep)
  -- A budget pause lasts exactly one pass, so paused sweep work rejoins
  -- planning on the next pump even when workers report no new progress.
  -- Entries that still cannot run re-park; adoption and pool progress keep
  -- their existing reopen paths.
  for jobKey in pairs(self.parked) do
    self.dirty[jobKey] = true
  end
  self.parked = {}
  local ledger = { bound = self:_sweepBound(), outstanding = self:_outstandingSweep() }
  while true do
    if budget ~= nil and budget.exhausted then
      return
    end
    local pending = {}
    for jobKey in pairs(self.dirty) do
      local entry = self.byKey[jobKey]
      if entry ~= nil and not entry.ready and entry.failure == nil then
        pending[#pending + 1] = entry
      else
        self.dirty[jobKey] = nil
      end
    end
    if #pending == 0 then
      local before = 0
      for _ in pairs(self.dirty) do
        before = before + 1
      end
      if self.enrollCursor ~= nil then
        self:_drainEnroll(budget)
      elseif allowSweep then
        self:_fillSweepStep(budget)
      else
        return
      end
      local after = 0
      for _ in pairs(self.dirty) do
        after = after + 1
      end
      if after == before then
        return
      end
    else
      table.sort(pending, function(left, right)
        if left.priority == right.priority then
          return left.jobKey < right.jobKey
        end
        return left.priority < right.priority
      end)
      for _, entry in ipairs(pending) do
        if budget ~= nil and budget.exhausted then
          if entry.priority == 100 then
            self.parked[entry.jobKey] = true
            self.dirty[entry.jobKey] = nil
          end
        else
          local outcome = self:_ensure(entry, nil, budget, ledger)
          if outcome == "terminal" or outcome == "waiting" then
            self.dirty[entry.jobKey] = nil
          elseif outcome == "parked" then
            self.parked[entry.jobKey] = true
            self.dirty[entry.jobKey] = nil
          elseif outcome == "paused" then
            if entry.priority == 100 then
              self.parked[entry.jobKey] = true
              self.dirty[entry.jobKey] = nil
            end
          end
        end
      end
    end
  end
end

---@param budget InteractiveCacheBuild.Budget|nil
function InteractiveCacheBuild:_fillSweepStep(budget)
  if not self.sourceLoaded then
    if self.pendingFillDone then
      return
    end
    self.pendingFillDone = true
    -- Page, cell and map membership is still unknown, so only the fixed
    -- global families join the sweep until the inventory publishes.
    self.sweepCursor = {
      jobs = {
        { kind = "items", key = "global" },
        { kind = "bag", key = "global" },
        { kind = "message-summary", key = "global" },
        { kind = "script-summary", key = "global" },
        { kind = "audio-summary", key = "global" },
        { kind = "mon-summary", key = "global" },
      },
      index = 1,
    }
  else
    if not self.loadedFillDone then
      -- The full corpus is unknowable before layout adoption, and its
      -- enumerator rejects a source-only inventory: wait for page
      -- membership instead of asserting on discovery-time knowledge.
      if not self.pagesKnown then
        return
      end
      self.loadedFillDone = true
      local jobs = ArtifactJobs.completeJobs(assert(self.adopted, "sweep needs its adopted inventory"))
      local enums = {}
      for _, job in ipairs(jobs) do
        enums[#enums + 1] = { kind = job.kind, key = job.key }
      end
      self.sweepCursor = { jobs = enums, index = 1 }
    end
    if self.sweepCursor == nil then
      return
    end
    -- Required demand outranks sweep enrollment: the corpus drains only
    -- while no planning remains.
    if next(self.dirty) ~= nil then
      return
    end
  end
  local cursor = assert(self.sweepCursor, "sweep enrollment needs its cursor")
  while cursor.index <= #cursor.jobs do
    if not self:_spendNode(budget) then
      return
    end
    local job = cursor.jobs[cursor.index]
    cursor.index = cursor.index + 1
    local entry = self:_register(job.kind, job.key, "sweep")
    if not entry.ready and entry.failure == nil then
      self.dirty[entry.jobKey] = true
    end
  end
  self.sweepCursor = nil
end

function InteractiveCacheBuild:update()
  assert(not self.retired, "generation session is retired")
  -- One shared pump budget covers request-originated and
  -- completion-originated work: planning, warm validation, submitted-result
  -- validation, adoption, enrollment and submission. The pool's separately
  -- bounded publication operation is not charged here.
  local budget = { used = 0, start = nil, exhausted = false, worked = false }
  self:_ensureInventoryLoaded(budget)
  self:_pollSubmitted()
  -- Sweep enrollment precedes validation-heavy planning so fixed
  -- membership work is not starved by one-time validator load costs; the
  -- pump still processes required demand first under the same budget.
  -- Automatic field-core warming registers its near intent exactly once:
  -- later updates advance the retained roster through adoption deltas and
  -- the bounded cursor instead of re-enrolling the whole scope per frame.
  local allowSweep = false
  if self.sweepEnabled then
    if not self.autoCoreNearDone and self:_retainedBootstrapReady() then
      self.autoCoreNearDone = true
      if self.milestones["field-core"] == nil then
        self.milestones["field-core"] = "near"
      end
    end
    self:_fillSweepStep(budget)
    allowSweep = true
  end
  -- First roster construction for requested scopes runs here under the
  -- shared budget; adoption rebuilds run synchronously in their transition.
  self:_buildPendingRosters(budget)
  -- New submissions precede the single pool lifecycle tick so dispatched
  -- work is observable in the same update; completions observed below are
  -- validated and adopted under the remaining same budget.
  self:_pumpPlanning(budget, allowSweep)
  self.pool:update()
  self:_pollSubmitted()
  self:_pumpPlanning(budget, allowSweep)
  self:_publishMilestone("bootstrap")
  self:_publishMilestone("field-core")
  -- Runnable local work remains when retained planning state is
  -- non-empty or a requested scope still awaits its necessary membership;
  -- a pump that merely consumed budget without leaving work ahead reports none.
  self.planningPending = self:_hasRunnablePlanning()
end

---@return { kind: string, key: string, jobKey: string, state: string, reused: boolean, error: string|nil, causeJobKey: string|nil, failureClass: string|nil }[]
function InteractiveCacheBuild:outcomes()
  -- Read-only retained snapshot: scalar copies for command finalization,
  -- never persisted metadata. No cache IO or validation here.
  local list = {}
  for _, entry in ipairs(self.interest) do
    local state
    if entry.failure ~= nil then
      state = "failed"
    elseif entry.ready then
      state = "successful"
    else
      state = "pending"
    end
    list[#list + 1] = {
      kind = entry.kind,
      key = entry.key,
      jobKey = entry.jobKey,
      state = state,
      reused = entry.ready and not entry.submitted,
      error = entry.failure,
      causeJobKey = entry.causeJobKey,
      failureClass = entry.failureClass,
    }
  end
  table.sort(list, function(left, right)
    return left.jobKey < right.jobKey
  end)
  return list
end

---@return boolean a retained milestone awaits its necessary membership while discovery stays live
function InteractiveCacheBuild:_scopeKnowledgePending()
  if self.retired then
    return false
  end
  -- Retained observation only: an unbuilt roster is pending knowledge, so
  -- local work remains until the admitted construction step runs.
  if self.milestones["bootstrap"] ~= nil and not self.sourceLoaded then
    local members = self.roster["bootstrap"]
    if members == nil then
      return true
    end
    local ready, failure = self:_milestoneAnswer("bootstrap", members)
    if not ready and failure == nil then
      return true
    end
  end
  if self.milestones["field-core"] ~= nil and (not self.sourceLoaded or not self.pagesKnown) then
    local members = self.roster["field-core"]
    if members == nil then
      return true
    end
    local ready, failure = self:_milestoneAnswer("field-core", members)
    if not ready and failure == nil then
      return true
    end
  end
  return false
end

---@return boolean runnable local planning remains from retained state
function InteractiveCacheBuild:_hasRunnablePlanning()
  if next(self.dirty) ~= nil or next(self.parked) ~= nil then
    return true
  end
  if self.enrollCursor ~= nil or self.sweepCursor ~= nil then
    return true
  end
  return self:_scopeKnowledgePending()
end

---@return table<string, unknown>
function InteractiveCacheBuild:status()
  -- Read-only retained observation: no cache IO, no validation, no pool
  -- polling. Queued and running follow the last pump-observed pool states;
  -- settled and planningPending carry the exact readiness contract.
  local bootstrapState, fieldCoreState = "pending", "pending"
  local bootstrapFailed, fieldCoreFailed = false, false
  if not self.retired then
    local bootstrapMembers = self.roster["bootstrap"]
    if bootstrapMembers ~= nil then
      local bootstrapReady, bootstrapFailure = self:_milestoneAnswer("bootstrap", bootstrapMembers)
      if bootstrapReady then
        bootstrapState = "ready"
      elseif bootstrapFailure ~= nil then
        bootstrapState = "failed"
        bootstrapFailed = self.milestones["bootstrap"] ~= nil
      end
    end
    if self.milestones["field-core"] ~= nil then
      local coreMembers = self.roster["field-core"]
      if coreMembers ~= nil then
        local coreReady, coreFailure = self:_milestoneAnswer("field-core", coreMembers)
        if coreReady then
          fieldCoreState = "ready"
        elseif coreFailure ~= nil then
          fieldCoreState = "failed"
          fieldCoreFailed = true
        end
      end
    end
  end
  -- Settlement is scope-relative: every retained milestone intent and
  -- every directly requested entry must be terminal. A fully terminal
  -- corpus always settles; a terminally failed requested scope also
  -- settles despite undiscovered downstream corpus, whose pending rows
  -- finalize as cancelled. Success never settles around running work.
  local ready, queued, running = 0, 0, 0
  local failures = {}
  local allTerminal, directTerminal = true, true
  for _, entry in ipairs(self.interest) do
    if entry.failure ~= nil then
      failures[#failures + 1] = entry.failure
    elseif entry.ready then
      ready = ready + 1
    else
      allTerminal = false
      if entry.direct then
        directTerminal = false
      end
      if entry.submitted and (entry.poolState == "running" or entry.poolState == "prepared") then
        running = running + 1
      else
        queued = queued + 1
      end
    end
  end
  local milestonesTerminal = true
  if not self.retired then
    if self.milestones["bootstrap"] ~= nil and bootstrapState == "pending" then
      milestonesTerminal = false
    end
    if self.milestones["field-core"] ~= nil and fieldCoreState == "pending" then
      milestonesTerminal = false
    end
  end
  local settled = milestonesTerminal and directTerminal and (allTerminal or bootstrapFailed or fieldCoreFailed)
  table.sort(failures)
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
    settled = settled,
    planningPending = self.planningPending,
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
  self.enrollCursor = nil
  self.roster = {}
  self.autoCoreNearDone = false
  self.layoutAttemptConsumed = false
  self.sweepCursor = nil
  self.planningPending = false
end

return InteractiveCacheBuild
