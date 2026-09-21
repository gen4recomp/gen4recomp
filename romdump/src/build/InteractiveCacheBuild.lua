-- One generation session for explicitly demanded bootstrap, field core
-- and complete builds. Construction performs no source work: it validates
-- its identity, recovers publication, selects the epoch and starts from
-- empty retained state plus the two source-static membership lists. Public
-- requests only register canonical interest and report retained answers;
-- only update advances planning, validation, adoption, enrollment and
-- submission, required demand first. One worker-compiled inventory, adopted
-- once published, supplies every source-derived membership; mon page
-- membership follows once the layout publishes. Until then requests needing
-- those families stay pending, failed prerequisites settle their blocked
-- demand with their causal identity, and status and outcomes observe
-- retained facts without cache IO or validation. Idle updates with no
-- outstanding interest enroll, enumerate and submit nothing: only explicit
-- semantic requests and the explicit batch complete request own work here.

local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local ArtifactState = require("romdump.src.build.ArtifactState")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")

---@class InteractiveCacheBuild.EnrollCursor
---@field pending { milestone: string|nil, kind: string, key: string, urgency: string|nil }[]
---@field index integer

---@class InteractiveCacheBuild.Ticket
---@field kind string entry or control
---@field jobKey string|nil canonical identity for entry tickets
---@field priority integer urgency lane
---@field op string|nil control operation for control tickets
---@field milestone string|nil milestone scope for roster tickets

---@class InteractiveCacheBuild.Scope
---@field remaining integer enrolled members without a terminal state
---@field failed integer enrolled members with a terminal failure
---@field seen table<string, string> member identity to pending or settled
---@field failure string|nil first notified member failure when present

---@class InteractiveCacheBuild.Interest
---@field kind string
---@field key string
---@field jobKey string
---@field urgency string
---@field priority integer
---@field submitted boolean
---@field ready boolean
---@field failure string|nil
---@field failureClass string|nil source-exclusion, dependency, job, validation or planning on failed rows
---@field causeJobKey string|nil deepest failed leaf identity when a dependency failed
---@field poolState string|nil last observed pool state
---@field direct boolean|nil true once a public single-request method claims this entry; milestone enrollment never sets it
---@field chain string[] expansion ancestry from the requesting root, naming concrete back-edges
---@field phase string plan, expand, admit, waitMembership, waitDeps, waitPool, ready or failed
---@field await string|nil source, pages, deps, pool or capacity: the named external prerequisite while waiting
---@field finalDeps { kind: string, key: string }[]|nil authoritative dependency list for the current knowledge
---@field depsFinal boolean the retained list is final for the current knowledge
---@field depIndex integer resume position for bounded edge installation and urgency propagation
---@field pendingDeps table<string, boolean> unready children observed through reverse edges
---@field propagateIndex integer|nil resume position for bounded urgency propagation over retained edges
---@field retryPending boolean an explicit retry waits for admission

---@class InteractiveCacheBuild
---@field versionId string
---@field generationId string
---@field producerId string
---@field epoch integer
---@field pool CompilerPool
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
---@field queues table<integer, { items: InteractiveCacheBuild.Ticket[], head: integer }> runnable tickets by urgency lane
---@field ticketLive table<string, InteractiveCacheBuild.Ticket> one live ticket object per runnable entry or control operation
---@field dependents table<string, table<string, boolean>> dependency to parent identities
---@field depMemo table<string, { kind: string, key: string }[]> retained final dependency edges
---@field submittedPending table<string, InteractiveCacheBuild.Interest> submitted nonterminal pool work
---@field enrollCursor InteractiveCacheBuild.EnrollCursor|nil private incremental membership enrollment after adoption
---@field enrollChunk integer new members enrolled in the current update
---@field scopes table<string, InteractiveCacheBuild.Scope> cached per-scope terminal accounting
---@field roster table<string, { kind: string, key: string }[]> retained milestone membership per requested scope
---@field rosterFailure table<string, string> retained roster construction failures per scope
---@field completeUrgency string|nil retained explicit complete-build intent
---@field completeNext (fun(): { kind: string, key: string }|nil)|nil canonical complete enumerator once adopted
---@field completeExhausted boolean canonical complete enumeration reached its end
---@field completeScope InteractiveCacheBuild.Scope cached complete-build terminal accounting
---@field sweepAuthorized boolean background corpus completion authorized through the lifecycle seam
---@field sweepNext (fun(): { kind: string, key: string }|nil)|nil retained canonical corpus enumerator
---@field sweepCandidate string|nil current sweep-origin candidate awaiting settlement
---@field sweepExhausted boolean canonical corpus enumeration reached its end
---@field sweepFailure string|nil first background candidate failure when present
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
  ["new-game-intro"] = "data/generated/new-game-intro.lua",
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

  local cacheFs = CacheFs.forVersion(versionId)
  cacheFs:recoverPublication()
  assert(type(pool.selectGeneration) == "function", "generation session pool cannot select generations")
  pool:selectGeneration(identity, epoch)
  -- Only source-static membership is known here: required message banks and
  -- supported field records derive from frozen catalogs without opening the
  -- dump. Everything else arrives with the worker inventory.
  local queues = {}
  for _, priority in ipairs({ 0, 10, 100 }) do
    queues[priority] = { items = {}, head = 1 }
  end
  local session = setmetatable({
    versionId = versionId,
    generationId = generationId,
    producerId = producerId,
    epoch = epoch,
    pool = pool,
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
    queues = queues,
    ticketLive = {},
    dependents = {},
    depMemo = {},
    submittedPending = {},
    enrollCursor = nil,
    enrollChunk = 0,
    scopes = {},
    roster = {},
    rosterFailure = {},
    completeUrgency = nil,
    completeNext = nil,
    completeExhausted = false,
    completeScope = { remaining = 0, failed = 0, seen = {}, failure = nil },
    sweepAuthorized = false,
    sweepNext = nil,
    sweepCandidate = nil,
    sweepExhausted = false,
    sweepFailure = nil,
    planningPending = false,
    followerMemo = nil,
    followerChecked = false,
  }, InteractiveCacheBuild)
  return session
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
  -- Fixed per-update overhead (frontier pool polling, the admission ledger,
  -- fixed-lane selection) is bounded by active work and must never consume
  -- the slice.
  if budget.start == nil then
    budget.start = nowSeconds()
  end
  local elapsed = nowSeconds() - budget.start
  if elapsed > UPDATE_TIME_SLICE_SECONDS then
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
    local parents = self.dependents[dep.kind .. ":" .. dep.key]
    if parents == nil then
      parents = {}
      self.dependents[dep.kind .. ":" .. dep.key] = parents
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
  local results = { ArtifactJobs.validate(self.cacheFs, self.generationId, kind, key, self:_plans(), self:_identity()) }
  return results[1], results[2]
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

-- Complete ticket identity: entries by canonical job key, roster controls
-- by milestone scope, every other control by operation. Two milestone
-- rosters are distinct operations even though they share one op name.
---@param ticket InteractiveCacheBuild.Ticket
---@return string
local function ticketKey(ticket)
  if ticket.kind == "entry" then
    return assert(ticket.jobKey, "entry tickets carry their identity")
  end
  local op = assert(ticket.op, "control tickets name their operation")
  if op == "roster" then
    return "control:roster:" .. assert(ticket.milestone, "roster operations name their scope")
  end
  return "control:" .. op
end

-- Local-phase eligibility: a nonterminal entry owes the pump a turn while
-- it can execute plan, edge expansion, admission, or while a bounded
-- urgency-propagation continuation is pending. Admission covers both the
-- first submission and explicit retries: the worker decides reuse versus
-- compilation, so no local validation phase exists. Historical pool
-- submission never removes this obligation;
-- a named capacity/worker/metadata/dependency wait without such a
-- continuation owes nothing until its waker fires.
---@param entry InteractiveCacheBuild.Interest
---@return boolean
local function entryNeedsTurn(entry)
  if entry.ready or entry.failure ~= nil then
    return false
  end
  if entry.propagateIndex ~= nil then
    return true
  end
  return entry.phase == "plan" or entry.phase == "expand" or entry.phase == "admit"
end

-- One live FIFO ticket per advanceable entry or control operation at the
-- existing urgency lanes. FIFO order replaces repeatedly restarted
-- lexical iteration; promotion invalidates the old ticket object and
-- queues a new one, so two live executions never exist for the same work.
-- The live map holds the exact ticket object: a stale queue cell can never
-- clear a newer operation that reuses its key and priority.
---@param ticket InteractiveCacheBuild.Ticket
function InteractiveCacheBuild:_enqueueTicket(ticket)
  local key = ticketKey(ticket)
  if self.ticketLive[key] ~= nil then
    return
  end
  self.ticketLive[key] = ticket
  local queue = assert(self.queues[ticket.priority], "tickets run on the existing urgency lanes")
  queue.items[#queue.items + 1] = ticket
end

---@param entry InteractiveCacheBuild.Interest
function InteractiveCacheBuild:_enqueueEntry(entry)
  if not entryNeedsTurn(entry) then
    return
  end
  self:_enqueueTicket({ kind = "entry", jobKey = entry.jobKey, priority = entry.priority })
end

---@param op string
---@param priority integer
---@param milestone string|nil
function InteractiveCacheBuild:_enqueueControl(op, priority, milestone)
  self:_enqueueTicket({ kind = "control", priority = priority, op = op, milestone = milestone })
end

---@param key string
function InteractiveCacheBuild:_invalidateTicket(key)
  self.ticketLive[key] = nil
end

---@return InteractiveCacheBuild.Ticket|nil next runnable ticket or nil when idle
function InteractiveCacheBuild:_popTicket()
  for _, priority in ipairs({ 0, 10, 100 }) do
    local queue = self.queues[priority]
    while queue.head <= #queue.items do
      local ticket = queue.items[queue.head]
      queue.head = queue.head + 1
      if queue.head > #queue.items then
        queue.items = {}
        queue.head = 1
      elseif queue.head > 128 then
        local fresh = {}
        for index = queue.head, #queue.items do
          fresh[#fresh + 1] = queue.items[index]
        end
        queue.items = fresh
        queue.head = 1
      end
      if self:_ticketValid(ticket) then
        local key = ticketKey(ticket)
        if self.ticketLive[key] == ticket then
          self.ticketLive[key] = nil
        end
        return ticket
      end
      -- A ticket that is no longer needed releases its live marker only
      -- when it still owns it, so a stale cell can never erase a newer
      -- operation queued under the same key.
      local key = ticketKey(ticket)
      if self.ticketLive[key] == ticket then
        self.ticketLive[key] = nil
      end
    end
  end
  return nil
end

---@param ticket InteractiveCacheBuild.Ticket
---@return boolean
function InteractiveCacheBuild:_ticketValid(ticket)
  local key = ticketKey(ticket)
  if self.ticketLive[key] ~= ticket then
    return false
  end
  if ticket.kind == "entry" then
    local entry = self.byKey[assert(ticket.jobKey, "entry tickets carry their identity")]
    return entry ~= nil and entry.priority == ticket.priority and entryNeedsTurn(entry)
  end
  return self:_controlNeeded(ticket.op, ticket.milestone)
end

---@return boolean the combined page-plan handoff can run now
function InteractiveCacheBuild:_adoptPagesEligible()
  if self.pagesKnown or not self.sourceLoaded or not self:_needsPageDemand() then
    return false
  end
  local owner = self.byKey["mon-layout:global"]
  return owner ~= nil and owner.ready and owner.failure == nil
end

---@param op string|nil
---@param milestone string|nil
---@return boolean
function InteractiveCacheBuild:_controlNeeded(op, milestone)
  if op == "roster" then
    return milestone ~= nil and self.milestones[milestone] ~= nil and self.roster[milestone] == nil
  elseif op == "enroll" then
    return self.enrollCursor ~= nil
  elseif op == "adoptPages" then
    return self:_adoptPagesEligible()
  end
  return false
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
      failure = nil,
      failureClass = nil,
      causeJobKey = nil,
      poolState = nil,
      chain = { jobKey },
      phase = "plan",
      await = nil,
      finalDeps = nil,
      depsFinal = false,
      depIndex = 1,
      pendingDeps = {},
      propagateIndex = nil,
      retryPending = false,
    }
    self.byKey[jobKey] = entry
    self.interest[#self.interest + 1] = entry
    self:_enqueueEntry(entry)
  elseif priority < entry.priority then
    entry.urgency = urgency
    entry.priority = priority
    -- A stronger urgency changes the desired lane, never the kind of
    -- outstanding operation: validation, an accepted pool record, a
    -- pending retry, the dependency cursor and acknowledged credit keep
    -- their distinct ownership. The old ticket object is invalidated and
    -- exactly one ticket is queued when the current phase still owes the
    -- pump a turn, so a submitted validation survives at the stronger
    -- urgency and a retry stays a retry. Queued physical work is promoted
    -- through the pool at once; unsubmitted retained edges are revisited
    -- one per pump turn through the propagation cursor instead of
    -- recursing the family here.
    self:_invalidateTicket(entry.jobKey)
    if not entry.ready and entry.failure == nil then
      if entry.submitted then
        self:_promoteQueued(entry)
        if entryNeedsTurn(entry) then
          self:_enqueueEntry(entry)
        end
      else
        if entry.finalDeps ~= nil and entry.await ~= "pool" then
          entry.propagateIndex = 1
        end
        if entryNeedsTurn(entry) then
          self:_enqueueEntry(entry)
        end
      end
    end
  end
  return entry
end

-- One interpretation for every public pool acknowledgement, shared by
-- admission, queued promotion and submitted polling. It schedules
-- validation and failure notifications and reconciles already-held
-- credit; it never starts a worker, reads payload files or plans
-- dependencies. Pool API faults propagate to the existing outer recovery
-- boundary unchanged: they are never replanned or resubmitted here.
---@param entry InteractiveCacheBuild.Interest
---@param state string acknowledged pool record state
---@param details table<string, unknown>|nil
function InteractiveCacheBuild:_observePoolState(entry, state, details)
  entry.poolState = state
  if state == "queued" or state == "running" then
    entry.await = "pool"
    entry.phase = "waitPool"
    self.submittedPending[entry.jobKey] = entry
    return
  end
  if state == "prepared" then
    entry.await = "pool"
    entry.phase = "waitPool"
    self.submittedPending[entry.jobKey] = entry
    return
  end
  if state == "ready" then
    self.submittedPending[entry.jobKey] = nil
    -- A ready reply is worker proof, not a request for controller
    -- validation: the worker already validated warm output before
    -- reusing it, and fresh output carries staged readback proof
    -- through publication. Ordinary entries succeed at once. The
    -- source inventory is the one exception: its generation record is
    -- adopted here through one explicit validating read before source
    -- waiters wake, and a failed adoption is explicit.
    if entry.kind == "source-plan" and entry.key == "global" then
      local valid, plan = self:_validate(entry.kind, entry.key, nil)
      if valid then
        self:_succeedEntry(entry, plan)
      else
        self:_failEntry(
          entry,
          self.generationId .. " source-plan global: published inventory failed adoption",
          "planning",
          nil
        )
      end
    else
      self:_succeedEntry(entry, nil)
    end
    if entry.kind == "mon-layout" and entry.key == "global" and self:_adoptPagesEligible() then
      self:_enqueueControl("adoptPages", 0, nil)
    end
    return
  end
  if state == "failed" then
    self.submittedPending[entry.jobKey] = nil
    local message = (type(details) == "table" and details.error) or "compiler job failed"
    self:_failEntry(entry, entry.jobKey .. ": " .. tostring(message), "job", nil)
    return
  end
  self.submittedPending[entry.jobKey] = nil
  self:_failEntry(entry, entry.jobKey .. ": pool " .. state .. " active submitted work", "planning", nil)
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
  -- The pool owns physical queueing, so a stronger urgency must reach the
  -- queued record under its canonical identity; the lanes keep its FIFO sequence.
  -- A repeated identical intent is a no-op. The returned acknowledgement
  -- is interpreted through the shared observation path.
  local state, details = self.pool:request({
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
  self:_observePoolState(entry, state, details)
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

-- One cached accounting record per scope: enrolled member identities with
-- their terminal state. Reverse membership notifications settle each member
-- exactly once through _noteTerminal; enrollment-time reconciliation only
-- initializes members that already hold a terminal state.
---@param name string
---@return InteractiveCacheBuild.Scope
function InteractiveCacheBuild:_scope(name)
  local scope = self.scopes[name]
  if scope == nil then
    scope = { remaining = 0, failed = 0, seen = {}, failure = nil }
    self.scopes[name] = scope
  end
  return scope
end

---@param scope InteractiveCacheBuild.Scope
---@param entry InteractiveCacheBuild.Interest
function InteractiveCacheBuild:_accountScopeMember(scope, entry)
  if scope.seen[entry.jobKey] ~= nil then
    return
  end
  if entry.failure ~= nil then
    scope.seen[entry.jobKey] = "settled"
    scope.failed = scope.failed + 1
    if scope.failure == nil then
      scope.failure = entry.failure
    end
  elseif entry.ready then
    scope.seen[entry.jobKey] = "settled"
  else
    scope.seen[entry.jobKey] = "pending"
    scope.remaining = scope.remaining + 1
  end
end

---@param entry InteractiveCacheBuild.Interest
function InteractiveCacheBuild:_noteTerminal(entry)
  -- Every scope holding this member settles it exactly once: only a
  -- member still recorded pending moves the cached counters.
  for _, name in ipairs({ "bootstrap", "field-core", "new-game-intro" }) do
    local scope = self.scopes[name]
    if scope ~= nil and scope.seen[entry.jobKey] == "pending" then
      scope.seen[entry.jobKey] = "settled"
      scope.remaining = scope.remaining - 1
      if entry.failure ~= nil then
        scope.failed = scope.failed + 1
        if scope.failure == nil then
          scope.failure = entry.failure
        end
      end
    end
  end
  local complete = self.completeScope
  if complete.seen[entry.jobKey] == "pending" then
    complete.seen[entry.jobKey] = "settled"
    complete.remaining = complete.remaining - 1
    if entry.failure ~= nil then
      complete.failed = complete.failed + 1
      if complete.failure == nil then
        complete.failure = entry.failure
      end
    end
  end
end

---@param entry InteractiveCacheBuild.Interest
---@param message string
---@param failureClass string
---@param causeJobKey string|nil
function InteractiveCacheBuild:_failEntry(entry, message, failureClass, causeJobKey)
  if entry.failure ~= nil or entry.ready then
    return
  end
  entry.failure = message
  entry.failureClass = failureClass
  entry.causeJobKey = causeJobKey
  entry.phase = "failed"
  entry.await = nil
  entry.retryPending = false
  self:_invalidateTicket(entry.jobKey)
  self:_noteTerminal(entry)
  self:_notifyParents(entry.jobKey)
  -- A failed metadata owner fails its membership waiters with the causal
  -- dependency failure: waiters on the inventory hold no reverse edge yet,
  -- so the owner transition itself wakes them instead of leaving them
  -- behind unknown membership.
  if entry.jobKey == "source-plan:global" or entry.jobKey == "mon-layout:global" then
    local await = entry.jobKey == "source-plan:global" and "source" or "pages"
    for _, waiter in ipairs(self.interest) do
      if not waiter.ready and waiter.failure == nil and waiter.await == await then
        self:_failEntry(
          waiter,
          self.generationId
            .. " "
            .. waiter.kind
            .. " "
            .. waiter.key
            .. ": prerequisite "
            .. entry.jobKey
            .. " failed: "
            .. tostring(entry.failure),
          "dependency",
          entry.causeJobKey or entry.jobKey
        )
      end
    end
  end
end

---@param entry InteractiveCacheBuild.Interest
---@param plan table<string, unknown>|nil validated source plan for immediate adoption
function InteractiveCacheBuild:_succeedEntry(entry, plan)
  if entry.failure ~= nil or entry.ready then
    return
  end
  entry.ready = true
  entry.phase = "ready"
  entry.await = nil
  entry.retryPending = false
  self:_invalidateTicket(entry.jobKey)
  if plan ~= nil then
    self:_adoptValidated(plan)
  end
  if entry.kind == "mon-layout" and entry.key == "global" and self:_adoptPagesEligible() then
    -- Warm layout reuse never crosses the pool transition that queues
    -- adoption, so its own success transition owns the ticket.
    self:_enqueueControl("adoptPages", 0, nil)
  end
  self:_noteTerminal(entry)
  self:_notifyParents(entry.jobKey)
end

---@param jobKey string
function InteractiveCacheBuild:_notifyParents(jobKey)
  -- One terminal observation updates every affected parent once: a
  -- failed child fails its waiting parents with the deepest cause, a
  -- ready child releases its parents' dependency waits. A parent never
  -- executes a waiting child to ask whether it is ready.
  local parents = self.dependents[jobKey]
  if parents == nil then
    return
  end
  local child = self.byKey[jobKey]
  for parentKey in pairs(parents) do
    local parent = self.byKey[parentKey]
    if parent ~= nil and not parent.ready and parent.failure == nil then
      if child ~= nil and child.failure ~= nil then
        parent.pendingDeps[jobKey] = nil
        self:_failEntry(
          parent,
          self.generationId
            .. " "
            .. parent.kind
            .. " "
            .. parent.key
            .. ": prerequisite "
            .. jobKey
            .. " failed: "
            .. child.failure,
          "dependency",
          child.causeJobKey or jobKey
        )
      elseif child ~= nil and child.ready then
        parent.pendingDeps[jobKey] = nil
        if parent.await == "deps" and next(parent.pendingDeps) == nil then
          -- Re-resolve instead of jumping to validation: adopted
          -- membership may now disprove the parent, and only the plan
          -- phase applies the exclusion rule.
          parent.await = nil
          parent.phase = "plan"
          self:_enqueueEntry(parent)
        end
      end
    end
  end
end

---@param entry InteractiveCacheBuild.Interest
---@param budget InteractiveCacheBuild.Budget|nil
---@return boolean advanced into a wait or terminal state; false when the budget paused the attempt
function InteractiveCacheBuild:_submit(entry, budget)
  -- Admission for one entry: the worker decides reuse versus compile,
  -- so the scalar payload and the pool request follow under the shared
  -- budget. The pool owns physical queueing and execution capacity, so
  -- every dependency-ready entry submits; required and background lanes
  -- order dispatch at the pool.
  if entry.submitted then
    entry.await = "pool"
    entry.phase = "waitPool"
    return true
  end
  local payload = self:_payload(entry.kind, entry.key)
  if payload == nil then
    entry.await = "source"
    entry.phase = "waitMembership"
    return true
  end
  if not self:_spendNode(budget) then
    self:_enqueueEntry(entry)
    return false
  end
  -- The single admission point for new work and explicit retries under
  -- the same budget. Retried records already own their payload in the
  -- payload in the pool; retry intent clears only after the pool
  -- acknowledges it. Pool API faults propagate to the existing outer
  -- recovery boundary unchanged.
  if entry.retryPending then
    local state, details = self.pool:retry(entry.jobKey, entry.priority)
    entry.retryPending = false
    entry.submitted = true
    self:_observePoolState(entry, state, details)
    return true
  end
  local request = {
    versionId = self.versionId,
    generationId = self.generationId,
    epoch = self.epoch,
    kind = entry.kind,
    key = entry.key,
    jobKey = entry.jobKey,
    priority = entry.priority,
    sizeClass = ArtifactJobs.sizeClass(entry.kind),
    payload = payload,
  }
  -- A fresh submission speaks for pool ownership: epoch, shape and
  -- selection errors propagate to the caller instead of masquerading as
  -- job failures. Only the admitted record states below become waits.
  local requestState, requestDetails = self.pool:request(request)
  entry.submitted = true
  self:_observePoolState(entry, requestState, requestDetails)
  return true
end

---@param entry InteractiveCacheBuild.Interest
---@param dep { kind: string, key: string }
---@return string|nil concrete back-edge path when the dependency closes a loop
function InteractiveCacheBuild:_backEdgePath(entry, dep)
  -- Only a genuine expansion back-edge is a cycle: the dependency names
  -- an ancestor of the expanding record, so the concrete key path proves
  -- the loop. Unadmitted work, unexpanded inventory, running workers and
  -- missed bookkeeping are pending states, never evidence of a cycle.
  local target = dep.kind .. ":" .. dep.key
  for _, ancestor in ipairs(entry.chain) do
    if ancestor == target then
      local path = {}
      for _, link in ipairs(entry.chain) do
        path[#path + 1] = link
      end
      path[#path + 1] = target
      return table.concat(path, " -> ")
    end
  end
  return nil
end

---@param entry InteractiveCacheBuild.Interest
---@param budget InteractiveCacheBuild.Budget|nil
---@return boolean settled into a wait or terminal state; false when the budget paused the attempt
function InteractiveCacheBuild:_stepEntry(entry, budget)
  if entry.ready or entry.failure ~= nil then
    return true
  end
  -- Bounded urgency propagation first: one retained edge per turn carries
  -- the stronger urgency to already visited dependencies without recursing
  -- the family inside a public call.
  if entry.propagateIndex ~= nil then
    local deps = entry.finalDeps or {}
    if entry.propagateIndex > #deps then
      entry.propagateIndex = nil
    else
      if not self:_spendNode(budget) then
        self:_enqueueEntry(entry)
        return false
      end
      local dep = deps[entry.propagateIndex]
      entry.propagateIndex = entry.propagateIndex + 1
      self:_register(dep.kind, dep.key, entry.urgency)
      self:_enqueueEntry(entry)
      return true
    end
  end
  -- Runnable phases chain within one ticket pop: an entry that can keep
  -- advancing does so without yielding and requeueing between every
  -- phase. Only budget pauses, named waits, terminal states, and single
  -- installed edges (wide-parent fairness) return to the queue. Explicit
  -- retries rest in the admit phase with their flag intact until the
  -- single admission point performs the pool operation.
  while true do
    if entry.phase == "plan" then
      local exclusion = self:_deferredExclusion(entry)
      if exclusion ~= nil then
        self:_failEntry(entry, exclusion, "source-exclusion", nil)
        return true
      end
      local deps, depsStatus, complete = self:_dependencies(entry.kind, entry.key, self:_plans(), budget)
      if deps == nil then
        if depsStatus == "paused" then
          self:_enqueueEntry(entry)
          return false
        end
        self:_failEntry(
          entry,
          self.generationId
            .. " "
            .. entry.kind
            .. " "
            .. entry.key
            .. ": dependency plan failed: "
            .. tostring(depsStatus),
          "planning",
          nil
        )
        return true
      end
      entry.finalDeps = deps
      entry.depsFinal = complete ~= false
      entry.depIndex = 1
      entry.pendingDeps = {}
      entry.phase = "expand"
    elseif entry.phase == "expand" then
      local deps = entry.finalDeps or {}
      if entry.depIndex <= #deps then
        if not self:_spendNode(budget) then
          self:_enqueueEntry(entry)
          return false
        end
        local dep = deps[entry.depIndex]
        entry.depIndex = entry.depIndex + 1
        -- Attach-time terminal check: a completion that occurred before
        -- attachment is not lost, and a failure settles the parent at once
        -- with the deepest cause.
        local child = self:_register(dep.kind, dep.key, entry.urgency)
        if child.failure == nil and not child.ready then
          if #child.chain == 1 then
            local ancestry = {}
            for _, link in ipairs(entry.chain) do
              ancestry[#ancestry + 1] = link
            end
            ancestry[#ancestry + 1] = child.jobKey
            child.chain = ancestry
          end
          local backEdge = self:_backEdgePath(entry, dep)
          if backEdge ~= nil then
            self:_failEntry(
              entry,
              self.generationId .. " " .. entry.kind .. " " .. entry.key .. ": dependency cycle follows " .. backEdge,
              "planning",
              nil
            )
            return true
          end
        end
        if child.failure ~= nil then
          self:_failEntry(
            entry,
            self.generationId
              .. " "
              .. entry.kind
              .. " "
              .. entry.key
              .. ": prerequisite "
              .. child.jobKey
              .. " failed: "
              .. child.failure,
            "dependency",
            child.causeJobKey or child.jobKey
          )
          return true
        elseif not child.ready then
          entry.pendingDeps[child.jobKey] = true
        end
        if entry.depIndex <= #deps then
          -- A partially processed wide parent requeues at the tail with
          -- its cursor intact, allowing other ready work a turn. The
          -- final edge falls through instead of yielding pointlessly.
          self:_enqueueEntry(entry)
          return true
        end
      end
      if not entry.depsFinal then
        entry.await = (not self.sourceLoaded) and "source" or "pages"
        entry.phase = "waitMembership"
        return true
      end
      if next(entry.pendingDeps) == nil then
        entry.phase = "admit"
      else
        entry.await = "deps"
        entry.phase = "waitDeps"
        return true
      end
    elseif entry.phase == "admit" then
      return self:_submit(entry, budget)
    else
      -- Named wait states hold no ticket; reaching one here means a stale
      -- ticket survived its transition, so there is nothing to advance.
      return true
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
  -- Registration only: record canonical interest and queue one runnable
  -- planning ticket for the pump. Planning prerequisites are expressed as
  -- dependency edges and pulled by the pump itself, so no inventory,
  -- layout, validation or worker work happens here.
  local entry = self:_register(kind, key, urgency)
  self:_enqueueEntry(entry)
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

---@param name string bootstrap, field-core, or new-game-intro
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
  -- adopted source inventory and adopted page membership. A new-game-intro
  -- answer requires adopted source inventory for its final audio bank
  -- membership, but never page membership. Discovery-time readiness never
  -- certifies either scope; bootstrap answers from its own roster without
  -- a page-membership gate.
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
  -- A scope answer keeps unenrolled membership pending: every
  -- requested member must be enrolled, not merely listed, before the
  -- scope can certify readiness.
  if self:_enrollmentPending(name) then
    return false, nil
  end
  if name == "field-core" and (not self.sourceLoaded or not self.pagesKnown) then
    return false, nil
  end
  if name == "new-game-intro" and not self.sourceLoaded then
    return false, nil
  end
  -- Readiness is the cached scope accounting: the scope is ready exactly
  -- when its expansion is final and no enrolled member awaits a terminal
  -- state. Reverse membership notifications settle each member once, so
  -- the counters below never rescan the session.
  local scope = self.scopes[name]
  if scope == nil or scope.remaining > 0 then
    return false, nil
  end
  return true, nil
end

---@param name string
---@return boolean roster enrollment still owes this scope a visit
function InteractiveCacheBuild:_enrollmentPending(name)
  if self.roster[name] == nil then
    return false
  end
  local cursor = self.enrollCursor
  if cursor == nil then
    return false
  end
  for index = cursor.index, #cursor.pending do
    if cursor.pending[index].milestone == name then
      return true
    end
  end
  return false
end

---@param name string
---@return { kind: string, key: string }[]
function InteractiveCacheBuild:_milestoneMembers(name)
  -- The single membership construction site: only update and adoption
  -- transitions call it, never public requests, status or publication.
  assert(
    name == "bootstrap" or name == "field-core" or name == "new-game-intro",
    "milestones accept only bootstrap, field-core, or new-game-intro"
  )
  if name == "bootstrap" then
    return ArtifactJobs.bootstrapJobs()
  end
  if name == "new-game-intro" then
    local audioPlan = self.adopted ~= nil and self.adopted.audioPlan or nil
    local jobs = ArtifactJobs.newGameIntroJobs(audioPlan)
    return jobs
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
  -- A failed roster construction settles the scope with its cause.
  if self.rosterFailure[name] ~= nil then
    return false, self.rosterFailure[name]
  end
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
  -- always observes final membership without confusing the two. A
  -- membership planning failure (for example an adopted audio plan that
  -- cannot resolve a required semantic reference) settles the scope with
  -- its cause instead of crashing the pump; a later successful rebuild
  -- clears it.
  local rebuilt, members = pcall(function()
    return self:_milestoneMembers(name)
  end)
  if not rebuilt then
    self.rosterFailure[name] = tostring(members)
    return
  end
  self.rosterFailure[name] = nil
  self.roster[name] = members
  -- Rebuild resets the cached scope accounting and reconciles every
  -- member against its current retained state, so adoption-time
  -- membership changes never strand or duplicate a counter. Later
  -- terminal notifications settle each accounted member exactly once.
  local scope = self:_scope(name)
  scope.remaining = 0
  scope.failed = 0
  scope.seen = {}
  scope.failure = nil
  for _, member in ipairs(members) do
    local entry = self.byKey[member.kind .. ":" .. member.key]
    if entry ~= nil then
      self:_accountScopeMember(scope, entry)
    else
      scope.seen[member.kind .. ":" .. member.key] = "pending"
      scope.remaining = scope.remaining + 1
    end
  end
  if enroll then
    self:_enqueueRosterDelta(name)
  end
end

---@param name string
function InteractiveCacheBuild:_enqueueRosterDelta(name)
  -- Enroll the retained roster through the bounded cursor: absent keys
  -- register, weaker nonterminal entries strengthen in place, and entries
  -- already at least as urgent no-op inside register. The cursor visits
  -- every member including existing ones, so a first or stronger scope
  -- request reconciles urgency as well as missing membership.
  local members = self.roster[name]
  if members == nil then
    return
  end
  local cursor = self.enrollCursor
  if cursor == nil then
    cursor = { pending = {}, index = 1 }
    self.enrollCursor = cursor
  end
  for _, member in ipairs(members) do
    cursor.pending[#cursor.pending + 1] = {
      milestone = name,
      kind = member.kind,
      key = member.key,
      urgency = self.milestones[name],
    }
  end
  self:_enqueueControl("enroll", 0, nil)
end

function InteractiveCacheBuild:_buildPendingRosters()
  -- First construction for every requested scope is a bounded roster
  -- operation queued here, never work inside a public request. Later
  -- rebuilds happen synchronously inside adoption, so retained answers
  -- stay current. An unfinished enrollment keeps one live ticket so the
  -- per-update chunk resumes without a roster rebuild.
  for name, _ in pairs(self.milestones) do
    if self.roster[name] == nil then
      self:_enqueueControl("roster", 0, name)
    end
  end
  if self.enrollCursor ~= nil then
    self:_enqueueControl("enroll", 0, nil)
  end
end

---@param ticket InteractiveCacheBuild.Ticket
---@param budget InteractiveCacheBuild.Budget|nil
---@return boolean settled; false when the budget paused the operation
function InteractiveCacheBuild:_runControl(ticket, budget)
  if ticket.op == "roster" then
    return self:_runRosterOp(assert(ticket.milestone, "roster operations name their scope"), budget)
  elseif ticket.op == "enroll" then
    return self:_runEnrollOp(budget)
  elseif ticket.op == "adoptPages" then
    return self:_runAdoptPagesOp(budget)
  end
  return true
end

---@param name string
---@param budget InteractiveCacheBuild.Budget|nil
---@return boolean settled; false when the budget paused the operation
function InteractiveCacheBuild:_runRosterOp(name, budget)
  if self.roster[name] ~= nil then
    return true
  end
  if not self:_spendNode(budget) then
    self:_enqueueControl("roster", 0, name)
    return false
  end
  self:_refreshRoster(name, self.milestones[name] ~= nil)
  return true
end

-- Bounded roster enrollment advances a small chunk of new members per
-- update so entry work in the ticket queues keeps progressing alongside
-- it. Members the session already tracks only reconcile urgency in place
-- and cost no planning node. The per-update chunk is enforced by
-- enrollChunk, reset on every update; _buildPendingRosters keeps one live
-- enroll ticket while the cursor remains.
---@param budget InteractiveCacheBuild.Budget|nil
---@return boolean settled; false when the budget paused the operation
function InteractiveCacheBuild:_runEnrollOp(budget)
  local cursor = self.enrollCursor
  if cursor == nil then
    return true
  end
  if (self.enrollChunk or 0) >= 8 then
    return true
  end
  while cursor.index <= #cursor.pending do
    local item = cursor.pending[cursor.index]
    -- Enrollment follows the current strongest intent, so a promotion that
    -- lands mid-drain reaches members the cursor has not visited yet.
    local urgency = item.urgency
    if item.milestone ~= nil and self.milestones[item.milestone] ~= nil then
      urgency = self.milestones[item.milestone]
    end
    urgency = assert(urgency, "enrollment needs its urgency")
    if self.byKey[ArtifactJobs.jobKey(item.kind, item.key)] == nil then
      if not self:_spendNode(budget) then
        self:_enqueueControl("enroll", 0, nil)
        return false
      end
      self.enrollChunk = (self.enrollChunk or 0) + 1
      if self.enrollChunk >= 8 then
        cursor.index = cursor.index + 1
        self:_register(item.kind, item.key, urgency)
        self:_enqueueControl("enroll", 0, nil)
        return true
      end
    end
    cursor.index = cursor.index + 1
    self:_register(item.kind, item.key, urgency)
  end
  self.enrollCursor = nil
  return true
end

---@param budget InteractiveCacheBuild.Budget|nil
---@return boolean settled; false when the budget paused the operation
function InteractiveCacheBuild:_runAdoptPagesOp(budget)
  if not self:_adoptPagesEligible() then
    return true
  end
  local owner = assert(self.byKey["mon-layout:global"], "eligible adoption names its layout owner")
  if not self:_spendNode(budget) then
    self:_enqueueControl("adoptPages", 0, nil)
    return false
  end
  local plans, reason = ArtifactJobs.publishedPlans(self.cacheFs, self:_identity())
  if plans ~= nil then
    self:_adoptPublished(plans)
  else
    -- An owner that claims readiness but hands over no usable plans
    -- fails explicitly instead of pending forever; the failure wakes its
    -- dependents with the cause. This is the only transition that revokes
    -- a ready result: the handoff refusal proves the readiness was
    -- never usable. No automatic reread follows; only an explicit retry
    -- under the same marker may revalidate the repaired handoff.
    owner.ready = false
    owner.phase = "plan"
    self:_failEntry(
      owner,
      self.generationId .. " mon-layout global: adopted layout has no usable page plans: " .. tostring(reason),
      "planning",
      nil
    )
  end
  return true
end

---@return boolean some retained demand can use the worker inventory
function InteractiveCacheBuild:_needsSourceDemand()
  -- Only scope intent owns source discovery: milestone and explicit
  -- complete requests need membership they cannot name yet. Authorized
  -- background completion needs the same discovery prefix to enumerate
  -- the corpus. Ordinary artifacts initiate their source prerequisite
  -- through the authoritative dependency graph, never through a second
  -- kind table here. Bootstrap answers from the field font alone and
  -- never pulls the inventory; the intro closure needs source knowledge,
  -- field core needs source and pages.
  if self.completeUrgency ~= nil then
    return true
  end
  if self.sweepAuthorized then
    return true
  end
  if self.milestones["field-core"] ~= nil or self.milestones["new-game-intro"] ~= nil then
    return true
  end
  return false
end

---@return boolean some retained demand can use mon page membership
function InteractiveCacheBuild:_needsPageDemand()
  if self.completeUrgency ~= nil then
    return true
  end
  if self.sweepAuthorized then
    return true
  end
  if self.milestones["field-core"] ~= nil then
    return true
  end
  for _, entry in ipairs(self.interest) do
    -- The layout owner exists to deliver page membership: an explicit
    -- layout request is page demand even before any page is named.
    if needsPageMembership(entry.kind) or entry.kind == "mon-layout" then
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
  -- public polling never publishes, an unbuilt roster publishes nothing,
  -- and a failed roster construction publishes nothing.
  if self.recorded[name] then
    return
  end
  if self.rosterFailure[name] ~= nil then
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
  -- interest and settles at once with a source-exclusion disposition,
  -- waking any parents that already wait on it.
  self:_failEntry(entry, message, "source-exclusion", nil)
  return false, message
end

---@param name string
---@param urgency string
---@return boolean
---@return string|nil
function InteractiveCacheBuild:requestMilestone(name, urgency)
  assert(not self.retired, "generation session is retired")
  assert(
    name == "bootstrap" or name == "field-core" or name == "new-game-intro",
    "milestones accept only bootstrap, field-core, or new-game-intro"
  )
  ArtifactJobs.priorityFor(urgency)
  local current = self.milestones[name]
  local stronger = current ~= nil and ArtifactJobs.priorityFor(urgency) < ArtifactJobs.priorityFor(current)
  if current == nil or stronger then
    self.milestones[name] = urgency
  end
  -- Record new or stronger intent and answer from retained state: roster
  -- construction, enrollment, validation, submission and publication all
  -- belong to update. Metadata owners are scheduled once per new intent.
  -- A first request queues one bounded roster operation; a stronger
  -- request queues one bounded reconciliation pass over the retained
  -- roster that strengthens weaker members in place. An unchanged poll
  -- registers nothing and observes the retained answer.
  if current == nil then
    -- Bootstrap answers from the menu font alone and schedules no
    -- inventory; only the intro closure and field core pull source
    -- knowledge, and only field core pulls page membership.
    if not self.sourceLoaded and (name == "field-core" or name == "new-game-intro") then
      self:_request("source-plan", "global", urgency)
    end
    -- Only field core pulls page membership: bootstrap answers from its
    -- own roster and the New Game intro closure needs source knowledge
    -- but no mon pages.
    if name == "field-core" and not self.pagesKnown then
      self:_request("mon-layout", "global", urgency)
    end
    self:_enqueueControl("roster", 0, name)
  elseif stronger then
    self:_enqueueRosterDelta(name)
  end
  return self:_retainedMilestoneAnswer(name)
end

---@param urgency string
---@return boolean
---@return string|nil
function InteractiveCacheBuild:requestComplete(urgency)
  -- Explicit batch complete intent: the complete corpus enrolls through
  -- the same registration logic as any other demand once the adopted
  -- inventory can enumerate it. Registration only records the intent;
  -- enrollment advances under the update budget. Idempotent.
  assert(not self.retired, "generation session is retired")
  ArtifactJobs.priorityFor(urgency)
  if
    self.completeUrgency == nil or ArtifactJobs.priorityFor(urgency) < ArtifactJobs.priorityFor(self.completeUrgency)
  then
    self.completeUrgency = urgency
  end
  return self:_completeAnswer()
end

---@return boolean ready
---@return string|nil failure
function InteractiveCacheBuild:_completeAnswer()
  -- Retained observation only: an unrequested complete build is pending
  -- knowledge, never a vacuous success. No enumeration, IO or validation.
  if self.completeUrgency == nil then
    return false, nil
  end
  if self.completeScope.failure ~= nil then
    return false, self.completeScope.failure
  end
  if not self.completeExhausted or self.completeScope.remaining > 0 then
    return false, nil
  end
  return true, nil
end

-- Explicit complete enrollment advances a small chunk per update through
-- the canonical producer enumerator, so entry work in the ticket queues
-- keeps progressing alongside it. Creating and advancing the enumerator
-- never builds, sorts, or copies the corpus: one logical job per
-- enumerator call enrolls under the budget with no worker payloads
-- allocated for the entire corpus at once.
-- Owner-only lifecycle authorization for opportunistic background corpus
-- completion. The call itself is O(1): it records the authorization and
-- performs no enumeration, validation, filesystem IO, or submission.
-- Advancement happens in update through the same canonical registration
-- path as explicit demand. Idempotent. Never exposed through gameHost.
function InteractiveCacheBuild:enableSweep()
  assert(not self.retired, "generation session is retired")
  self.sweepAuthorized = true
end

---@param budget InteractiveCacheBuild.Budget|nil
function InteractiveCacheBuild:_expandComplete(budget)
  if self.completeUrgency == nil or self.completeExhausted then
    return
  end
  -- The complete corpus is unknowable before source and page adoption:
  -- enumeration waits for adopted membership instead of asserting on
  -- discovery-time knowledge.
  if not self.sourceLoaded or not self.pagesKnown then
    return
  end
  if self.completeNext == nil then
    if not self:_spendNode(budget) then
      return
    end
    self.completeNext =
      ArtifactJobs.completeIterator(assert(self.adopted, "complete enumeration needs its adopted inventory"))
  end
  local enrolled = 0
  while enrolled < 8 do
    local job = assert(self.completeNext, "complete enumeration owns its canonical enumerator")()
    if job == nil then
      self.completeExhausted = true
      self.completeNext = nil
      return
    end
    if not self:_spendNode(budget) then
      return
    end
    enrolled = enrolled + 1
    local entry = self:_register(job.kind, job.key, assert(self.completeUrgency, "complete intent owns its urgency"))
    self:_accountCompleteMember(entry)
  end
end

---@param budget InteractiveCacheBuild.Budget|nil
function InteractiveCacheBuild:_advanceSweep(budget)
  -- Opportunistic background completion through the canonical graph: at
  -- most one sweep-origin corpus candidate advances at a time, only
  -- while no required or near work is outstanding, and never by
  -- materializing the whole corpus. Ready and failed records settle
  -- through the same registration path as explicit demand; a failed
  -- candidate keeps its attributed failure without failing unrelated
  -- scopes and the cursor moves on without retrying it.
  if self.retired or not self.sweepAuthorized or self.sweepExhausted then
    return
  end
  local candidate = self.sweepCandidate ~= nil and self.byKey[self.sweepCandidate] or nil
  if candidate ~= nil then
    if candidate.failure ~= nil then
      if self.sweepFailure == nil then
        self.sweepFailure = candidate.failure
      end
      self.sweepCandidate = nil
    elseif candidate.ready then
      self.sweepCandidate = nil
    else
      return
    end
  end
  for _, entry in ipairs(self.interest) do
    if not entry.ready and entry.failure == nil and entry.priority < 100 then
      return
    end
  end
  if not self.sourceLoaded or not self.pagesKnown then
    return
  end
  if self.sweepNext == nil then
    if not self:_spendNode(budget) then
      return
    end
    self.sweepNext =
      ArtifactJobs.completeIterator(assert(self.adopted, "background enumeration needs its adopted inventory"))
  end
  while true do
    if not self:_spendNode(budget) then
      return
    end
    local job = assert(self.sweepNext, "background enumeration owns its canonical iterator")()
    if job == nil then
      self.sweepExhausted = true
      self.sweepNext = nil
      return
    end
    local entry = self:_register(job.kind, job.key, "sweep")
    if entry.failure ~= nil then
      if self.sweepFailure == nil then
        self.sweepFailure = entry.failure
      end
    elseif not entry.ready then
      self.sweepCandidate = entry.jobKey
      return
    end
  end
end

---@param entry InteractiveCacheBuild.Interest
function InteractiveCacheBuild:_accountCompleteMember(entry)
  local complete = self.completeScope
  if complete.seen[entry.jobKey] ~= nil then
    return
  end
  if entry.failure ~= nil then
    complete.seen[entry.jobKey] = "settled"
    complete.failed = complete.failed + 1
    if complete.failure == nil then
      complete.failure = entry.failure
    end
  elseif entry.ready then
    complete.seen[entry.jobKey] = "settled"
  else
    complete.seen[entry.jobKey] = "pending"
    complete.remaining = complete.remaining + 1
  end
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
    if not poolFailed and leaf.failureClass == "source-exclusion" then
      -- A permanent unsupported-member rejection stays explicit unless
      -- its failed producer leaf can be retried.
    else
      -- Every explicit retry enters through the one budgeted admission
      -- path: a genuinely failed pool leaf keeps a single retry flag and
      -- an admission continuation, so strengthening it before its first
      -- turn never turns it into an ordinary request against the failed
      -- record. Anything else revalidates the repaired output from
      -- ordinary planning. The pool is never touched here; urgency
      -- changes never clear the retry identity. Healthy siblings stay put.
      leaf.failure = nil
      leaf.failureClass = nil
      leaf.causeJobKey = nil
      leaf.ready = false
      leaf.poolState = nil
      leaf.finalDeps = nil
      leaf.depsFinal = false
      leaf.depIndex = 1
      leaf.pendingDeps = {}
      leaf.propagateIndex = nil
      leaf.await = nil
      leaf.submitted = false
      leaf.urgency = urgency
      leaf.priority = priority
      self:_invalidateTicket(leaf.jobKey)
      if poolFailed then
        leaf.retryPending = true
        leaf.phase = "admit"
      else
        leaf.retryPending = false
        leaf.phase = "plan"
      end
      self:_enqueueEntry(leaf)
      repaired = repaired + 1
    end
  end
  if repaired > 0 then
    for _, parent in ipairs(blocked) do
      parent.failure = nil
      parent.failureClass = nil
      parent.causeJobKey = nil
      parent.finalDeps = nil
      parent.depsFinal = false
      parent.depIndex = 1
      parent.pendingDeps = {}
      parent.propagateIndex = nil
      parent.await = nil
      if priority < parent.priority then
        parent.urgency = urgency
        parent.priority = priority
        self:_invalidateTicket(parent.jobKey)
      end
      if not parent.ready then
        parent.phase = "plan"
        self:_enqueueEntry(parent)
      end
    end
    self.followerChecked = false
    self.followerMemo = nil
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
  for jobKey, entry in pairs(self.submittedPending) do
    if entry == self.byKey[jobKey] and not entry.ready and entry.failure == nil and entry.submitted then
      local state = self.pool:status(entry.jobKey)
      if state == "queued" or state == "running" or state == "prepared" or state == "unknown" then
        return true
      end
    end
  end
  return false
end

-- Retained metadata demand without cache IO: explicit scope intent owns
-- its metadata owner entries, so adoption has a validated transition even
-- when no milestone requested them. Scopes that cannot use an inventory
-- never schedule it, keeping independent leaves small. No plans are read,
-- validated or enrolled here.
function InteractiveCacheBuild:_scheduleMetadataDemand()
  if not self.sourceLoaded and self:_needsSourceDemand() then
    local owner = self.byKey["source-plan:global"]
    if owner == nil then
      self:_request(
        "source-plan",
        "global",
        self.milestones["field-core"]
          or self.milestones["new-game-intro"]
          or self.completeUrgency
          or self.milestones["bootstrap"]
          or (self.sweepAuthorized and "sweep")
          or "near"
      )
    end
  end
  if self.sourceLoaded and not self.pagesKnown and self:_needsPageDemand() then
    local layoutEntry = self.byKey["mon-layout:global"]
    if
      layoutEntry == nil
      and (self.milestones["field-core"] ~= nil or self.completeUrgency ~= nil or self.sweepAuthorized)
    then
      layoutEntry = self:_request(
        "mon-layout",
        "global",
        self.milestones["field-core"] or self.completeUrgency or (self.sweepAuthorized and "sweep") or "near"
      )
    end
    if self:_adoptPagesEligible() then
      self:_enqueueControl("adoptPages", 0, nil)
    end
  end
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
  self:_wakeForSourceAdoption()
  if self:_adoptPagesEligible() then
    -- A ready layout must not wait for the next update's demand scan:
    -- queue the pages-adoption attempt now so waiters observe one
    -- continuous chain of progress within the same pump.
    self:_enqueueControl("adoptPages", 0, nil)
  end
  self:_refreshAdoptionRosters()
end

-- Source adoption wakes every entry without physical backing: waiters on
-- the source inventory, runnable entries, and dependency waiters whose
-- exclusion outcome membership may now decide. Waits backed by submitted
-- pool work or other inventories keep waiting, and enumeration restarts
-- against the fuller membership.

function InteractiveCacheBuild:_wakeForSourceAdoption()
  for _, entry in ipairs(self.interest) do
    if not entry.ready and entry.failure == nil and not entry.submitted then
      -- Adoption changes the knowledge base, so every unsubmitted entry
      -- without physical backing re-resolves: waiters, incomplete member
      -- lists,
      -- and dependency waiters whose exclusion outcome membership may now
      -- decide. Membership-gated waits on other inventories keep waiting.
      if entry.await == nil or entry.await == "source" or entry.await == "deps" then
        entry.await = nil
        entry.phase = "plan"
        entry.finalDeps = nil
        entry.depsFinal = false
        self:_enqueueEntry(entry)
      end
    end
  end
  -- Adoption replaces the enumeration basis: the complete enumerator
  -- rebuilds from the fuller membership below while already-enrolled
  -- members stay registered exactly once through the accounted set. The
  -- background enumerator restarts on the same basis; authorization and
  -- any recorded background failure survive the transition.
  self.completeNext = nil
  self.completeExhausted = false
  self.sweepNext = nil
  self.sweepCandidate = nil
  self.sweepExhausted = false
end
-- Adoption replaces retained rosters synchronously: answers observed after
-- this transition see final membership, and newly known members enroll
-- through the bounded cursor instead of a full re-enrollment loop.
function InteractiveCacheBuild:_refreshAdoptionRosters()
  for _, name in ipairs({ "bootstrap", "field-core", "new-game-intro" }) do
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
  self:_wakeForPagesAdoption()
  self:_refreshAdoptionRosters()
end

function InteractiveCacheBuild:_wakeForPagesAdoption()
  for _, entry in ipairs(self.interest) do
    if not entry.ready and entry.failure == nil and not entry.submitted then
      if entry.await == nil or entry.await == "pages" or entry.await == "deps" then
        entry.await = nil
        entry.phase = "plan"
        entry.finalDeps = nil
        entry.depsFinal = false
        self:_enqueueEntry(entry)
      end
    end
  end
  self.completeNext = nil
  self.completeExhausted = false
  self.sweepNext = nil
  self.sweepCandidate = nil
  self.sweepExhausted = false
end

-- Observes already-submitted work for pool transitions through the public
-- pool API: transitions are worker-driven facts. A ready owner queues its
-- family validation or page adoption; a failed one records its cause at
-- once; either reconciles the acknowledged frontier and wakes the affected
-- parents. Every current observation runs through the shared path, so a
-- ready reply is honored even when no later state edge will occur, while
-- an already-queued validation is never duplicated. Missing submitted
-- records and unexpected active-epoch cancellations are diagnosed, never
-- silently interpreted as ready.
function InteractiveCacheBuild:_pollSubmitted()
  -- Frontier-only polling: completed sweep history in retained interest
  -- can never produce a new pool transition, so normal updates never walk
  -- it. Terminal acknowledgements remove the entry from the frontier
  -- through the shared observation path before any downstream action.
  for jobKey, entry in pairs(self.submittedPending) do
    if entry == self.byKey[jobKey] and not entry.ready and entry.failure == nil and entry.submitted then
      local state, details = self.pool:status(entry.jobKey)
      if state ~= entry.poolState or state == "ready" or state == "failed" then
        self:_observePoolState(entry, state, details)
      end
    end
  end
end

-- Drains runnable tickets highest-urgency-first, FIFO within urgency,
-- under one shared budget. Each retained step advances or waits for a
-- named cause; a budget pause requeues the operation for the next update.
---@param budget InteractiveCacheBuild.Budget|nil
function InteractiveCacheBuild:_drainTickets(budget)
  while true do
    if budget ~= nil and budget.exhausted then
      return
    end
    local ticket = self:_popTicket()
    if ticket == nil then
      return
    end
    if ticket.kind == "entry" then
      local entry = self.byKey[assert(ticket.jobKey, "entry tickets carry their identity")]
      if entry ~= nil then
        self:_stepEntry(entry, budget)
      end
    else
      self:_runControl(ticket, budget)
    end
  end
end

function InteractiveCacheBuild:update()
  assert(not self.retired, "generation session is retired")
  -- One shared pump budget covers request-originated and
  -- completion-originated work: planning, warm validation, submitted-result
  -- validation, adoption, enrollment and submission. The pool's separately
  -- bounded publication operation is not charged here.
  local budget = { used = 0, start = nil, exhausted = false, worked = false }
  self.enrollChunk = 0
  -- Observe submitted state first, then derive newly eligible metadata and
  -- roster work, advance highest-urgency runnable operations, tick the
  -- physical pool once, observe its new facts, then use any remaining
  -- budget. Finalize eligible once-only milestone publication and compute
  -- retained status from the resulting state.
  self:_pollSubmitted()
  self:_scheduleMetadataDemand()
  self:_buildPendingRosters()
  self:_expandComplete(budget)
  self:_advanceSweep(budget)
  -- New submissions precede the single pool lifecycle tick so dispatched
  -- work is observable in the same update; completions observed below are
  -- validated and adopted under the remaining same budget.
  self:_drainTickets(budget)
  self.pool:update()
  self:_pollSubmitted()
  self:_drainTickets(budget)
  self:_publishMilestone("bootstrap")
  self:_publishMilestone("field-core")
  self:_publishMilestone("new-game-intro")
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

---@return boolean runnable local planning remains from retained state
function InteractiveCacheBuild:_hasRunnablePlanning()
  -- The worklist is the runnable authority: a live valid ticket means
  -- local work can advance now, and so does eligible complete expansion
  -- that owns no ticket. Blocked interest carries no ticket, so missing
  -- knowledge and held workers report idle.
  -- Phase and wait data describe why other interest is not runnable.
  -- Unticketed enrollment and complete expansion still count as runnable:
  -- their tickets are consumed across updates while the cursors remain.
  if self.enrollCursor ~= nil then
    return true
  end
  for _, priority in ipairs({ 0, 10, 100 }) do
    local queue = self.queues[priority]
    for index = queue.head, #queue.items do
      if self:_ticketValid(queue.items[index]) then
        return true
      end
    end
  end
  return self:_completeExpansionReady() or self:_sweepExpansionReady()
end

---@return boolean unexpanded background completion can advance now
function InteractiveCacheBuild:_sweepExpansionReady()
  return self.sweepAuthorized and not self.sweepExhausted and self.sourceLoaded and self.pagesKnown
end

---@return boolean unexpanded explicit complete demand can advance now
function InteractiveCacheBuild:_completeExpansionReady()
  return self.completeUrgency ~= nil and not self.completeExhausted and self.sourceLoaded and self.pagesKnown
end

---@return table<string, unknown>
function InteractiveCacheBuild:status()
  -- Read-only retained observation: no cache IO, no validation, no pool
  -- polling. Queued and running follow the last pump-observed pool states;
  -- settled and planningPending carry the exact readiness contract.
  local bootstrapState, fieldCoreState, newGameIntroState = "pending", "pending", "pending"
  local bootstrapFailed, fieldCoreFailed, newGameIntroFailed = false, false, false
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
    if self.milestones["new-game-intro"] ~= nil then
      if self.rosterFailure["new-game-intro"] ~= nil then
        newGameIntroState = "failed"
        newGameIntroFailed = true
      else
        local introMembers = self.roster["new-game-intro"]
        if introMembers ~= nil then
          local introReady, introFailure = self:_milestoneAnswer("new-game-intro", introMembers)
          if introReady then
            newGameIntroState = "ready"
          elseif introFailure ~= nil then
            newGameIntroState = "failed"
            newGameIntroFailed = true
          end
        end
      end
    end
  end
  -- Settlement is scope-relative: every retained milestone intent and
  -- every directly requested entry must be terminal, and successful
  -- settlement additionally needs the authorized enumeration exhausted.
  -- A terminally failed requested scope or metadata owner settles without
  -- waiting for successful sweep completion. Success never settles around
  -- running work.
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
    if self.milestones["new-game-intro"] ~= nil and newGameIntroState == "pending" then
      milestonesTerminal = false
    end
  end
  -- Settlement is scope-relative and truthful: successful settlement
  -- needs every requested scope ready, every direct root ready, every
  -- entry terminal and, when a complete build was requested, the canonical
  -- enumeration exhausted. Membership merely known never substitutes for
  -- the exhausted enumerator. A terminally failed milestone or metadata
  -- owner also settles without waiting for successful completion, but an
  -- unrelated failed job never settles around still-pending work.
  -- Success never settles around running work.
  local completeDone = self.completeUrgency == nil or self.completeExhausted
  local milestoneFailed = bootstrapFailed or fieldCoreFailed or newGameIntroFailed
  local metadataFailed = false
  if #failures > 0 then
    local sourceOwner = self.byKey["source-plan:global"]
    local layoutOwner = self.byKey["mon-layout:global"]
    if (sourceOwner ~= nil and sourceOwner.failure ~= nil) or (layoutOwner ~= nil and layoutOwner.failure ~= nil) then
      metadataFailed = true
    end
  end
  local settled = milestonesTerminal
    and directTerminal
    and (allTerminal or milestoneFailed or metadataFailed)
    and (completeDone or milestoneFailed or metadataFailed)
  table.sort(failures)
  -- Background completion is never part of a gameplay readiness
  -- predicate: the sweep observation below reports authorized warming,
  -- exhaustion, or the first background failure without entering any
  -- readiness gate above.
  local sweepState = "idle"
  if self.sweepAuthorized then
    if self.sweepExhausted then
      sweepState = self.sweepFailure ~= nil and "incomplete" or "exhausted"
    else
      sweepState = "warming"
    end
  end
  local complete = bootstrapState == "ready"
    and fieldCoreState == "ready"
    and #failures == 0
    and (ready + queued + running) > 0
    and queued == 0
    and running == 0
    and completeDone
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
    sweepState = sweepState,
    sweepFailure = self.sweepFailure,
  }
end

---@param name string bootstrap, field-core, or new-game-intro
---@return { state: string, ready: integer, total: integer|nil, failure: string|nil } read-only milestone-local progress snapshot
function InteractiveCacheBuild:milestoneStatus(name)
  -- Read-only milestone-local progress projection. It inspects only the
  -- retained roster for `name` and its referenced entries: no cache IO, no
  -- validation, no pool polling, no enrollment, no publication, and no
  -- whole-session scan, so unrelated background interest never affects the
  -- answer. A missing or not-yet-final roster reports pending without a
  -- denominator instead of inventing one.
  assert(
    name == "bootstrap" or name == "field-core" or name == "new-game-intro",
    "milestones accept only bootstrap, field-core, or new-game-intro"
  )
  local members = self.roster[name]
  local rosterFailure = self.rosterFailure[name]
  if members == nil then
    if rosterFailure ~= nil then
      return { state = "failed", ready = 0, total = nil, failure = rosterFailure }
    end
    return { state = "pending", ready = 0, total = nil, failure = nil }
  end
  local readyCount = 0
  ---@type string|nil
  local memberFailure = nil
  for _, member in ipairs(members) do
    local entry = self.byKey[member.kind .. ":" .. member.key]
    if entry ~= nil then
      if entry.failure ~= nil then
        if memberFailure == nil then
          memberFailure = entry.failure
        end
      elseif entry.ready then
        readyCount = readyCount + 1
      end
    end
  end
  ---@type string|nil
  local failure = rosterFailure or memberFailure
  if failure ~= nil then
    return { state = "failed", ready = readyCount, total = nil, failure = failure }
  end
  -- The denominator is authoritative only once adopted knowledge fixed
  -- the roster: bootstrap answers from its own roster, while the intro
  -- closure needs adopted source inventory and field core additionally
  -- needs adopted page membership. Adoption rebuilds retained rosters
  -- synchronously, so a retained roster observed after adoption is final.
  local final = name == "bootstrap"
    or (name == "new-game-intro" and self.sourceLoaded)
    or (name == "field-core" and self.sourceLoaded and self.pagesKnown)
  if not final then
    return { state = "pending", ready = readyCount, total = nil, failure = nil }
  end
  local total = #members
  if total > 0 and readyCount == total then
    return { state = "ready", ready = readyCount, total = total, failure = nil }
  end
  return { state = "pending", ready = readyCount, total = total, failure = nil }
end

function InteractiveCacheBuild:retire()
  if self.retired then
    return
  end
  self.retired = true
  -- Logical interest ends here; executing physical slots stay charged to the
  -- pool until their terminal reply or joined exit. Late old-epoch output
  -- can no longer publish through this session. The session owns no source
  -- reader, so retirement closes nothing itself. Background authorization
  -- and its cursor end with the other logical interest.
  self.pool:retireSelection(self.epoch)
  self.interest = {}
  self.byKey = {}
  local queues = {}
  for _, priority in ipairs({ 0, 10, 100 }) do
    queues[priority] = { items = {}, head = 1 }
  end
  self.queues = queues
  self.ticketLive = {}
  self.dependents = {}
  self.depMemo = {}
  self.submittedPending = {}
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
  self.scopes = {}
  self.roster = {}
  self.rosterFailure = {}
  self.completeUrgency = nil
  self.completeNext = nil
  self.completeExhausted = false
  self.completeScope = { remaining = 0, failed = 0, seen = {}, failure = nil }
  self.sweepAuthorized = false
  self.sweepNext = nil
  self.sweepCandidate = nil
  self.sweepExhausted = false
  self.sweepFailure = nil
  self.planningPending = false
end

return InteractiveCacheBuild
