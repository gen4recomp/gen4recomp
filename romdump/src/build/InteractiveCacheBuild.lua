-- One generation session for bootstrap, field core and exhaustive warmup.
-- The session owns its source planning handle, its immutable source plans
-- and its interest records; the process-owned pool owns physical capacity
-- and publication. Milestones are generation-specific receipts over their
-- exact job sets. Demand outranks near/sweep work at the same pool
-- admission rules, and the sweep frontier stays bounded while every
-- canonical key is eventually accounted for.

local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local ArtifactState = require("romdump.src.build.ArtifactState")
local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldCellCompiler = require("romdump.src.digest.field.FieldCellCompiler")
local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local MapCompilePlan = require("romdump.src.digest.map.MapCompilePlan")
local MonCatalogCompiler = require("romdump.src.digest.mons.MonCatalogCompiler")
local MonPresentationCompiler = require("romdump.src.digest.mons.MonPresentationCompiler")
local RomFs = require("romdump.src.source.RomFs")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")

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

---@class InteractiveCacheBuild
---@field versionId string
---@field generationId string
---@field producerId string
---@field epoch integer
---@field pool CompilerPool
---@field sweepEnabled boolean
---@field cacheFs CacheFs
---@field romFs table<string, unknown>
---@field indexBundle table<string, unknown>
---@field scriptPlan table<string, unknown>
---@field audioPlan table<string, unknown>
---@field catalog table<string, unknown>
---@field presentation table<string, unknown>
---@field messageBankIds integer[]
---@field audioBankIds integer[]
---@field scriptMemberIds integer[]
---@field iconPageIds integer[]
---@field portraitPageIds integer[]
---@field mapCount integer
---@field mapDataIds integer[]|nil
---@field resolvedMapIds integer[]|nil
---@field mapPlans table<integer, table<string, unknown>|false>
---@field mapCellKeys table<integer, string[]>
---@field interest InteractiveCacheBuild.Interest[]
---@field byKey table<string, InteractiveCacheBuild.Interest>
---@field milestones table<string, string>
---@field recorded table<string, boolean>
---@field retired boolean
local InteractiveCacheBuild = {}
InteractiveCacheBuild.__index = InteractiveCacheBuild

local MILESTONE_FILES = {
  bootstrap = "data/generated/bootstrap.lua",
  ["field-core"] = "data/generated/field-core.lua",
}

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
  local romFs, openError = RomFs.open(versionId)
  assert(romFs, openError)
  local self = setmetatable({
    versionId = versionId,
    generationId = generationId,
    producerId = producerId,
    epoch = epoch,
    pool = pool,
    sweepEnabled = sweepEnabled,
    cacheFs = cacheFs,
    romFs = romFs,
    mapPlans = {},
    mapCellKeys = {},
    interest = {},
    byKey = {},
    milestones = {},
    recorded = {},
    retired = false,
  }, InteractiveCacheBuild)
  local ok, failure = pcall(function()
    self.indexBundle = assert(FieldCellCompiler.compileIndex(romFs, producerId))
    self.scriptPlan = ScriptCompiler.plan(romFs, producerId)
    local audioPlan, audioErr = AudioCompiler.plan(romFs)
    assert(audioPlan, audioErr)
    self.audioPlan = audioPlan
    local catalog, catalogErr = MonCatalogCompiler.compileCatalog(romFs)
    assert(catalog, catalogErr)
    self.catalog = catalog
    local presentation, presentationErr = MonPresentationCompiler.plan(romFs, self.catalog)
    assert(presentation, presentationErr)
    self.presentation = presentation
    self.messageBankIds = FieldMessageCompiler.requiredBankIds()
    local audioBankIds = {}
    for _, bankPlan in ipairs(self.audioPlan.bankPlans) do
      audioBankIds[#audioBankIds + 1] = assert(bankPlan.bankId, "audio closure needs its bank identity")
    end
    table.sort(audioBankIds)
    self.audioBankIds = audioBankIds
    local scriptMemberIds = {}
    for _, member in ipairs(self.scriptPlan.members) do
      scriptMemberIds[#scriptMemberIds + 1] = member.memberId
    end
    table.sort(scriptMemberIds)
    self.scriptMemberIds = scriptMemberIds
    local iconPageIds = {}
    for _, pageId in ipairs(self.presentation.icons.pageIds) do
      iconPageIds[#iconPageIds + 1] = pageId
    end
    table.sort(iconPageIds)
    self.iconPageIds = iconPageIds
    local portraitPageIds = {}
    for _, pageId in ipairs(self.presentation.portraits.pageIds) do
      portraitPageIds[#portraitPageIds + 1] = pageId
    end
    table.sort(portraitPageIds)
    self.portraitPageIds = portraitPageIds
    local mapCount = 0
    for _ in MapCatalog.all() do
      mapCount = mapCount + 1
    end
    self.mapCount = mapCount
  end)
  if not ok then
    pcall(romFs.close, romFs)
    error(failure, 0)
  end
  return self
end

---@return ArtifactJobs.Plans
function InteractiveCacheBuild:_plans()
  local selfRef = self
  local function resolveMapPlan(mapId)
    return selfRef:_mapPlanQuiet(mapId)
  end
  return {
    indexBundle = self.indexBundle,
    scriptPlan = self.scriptPlan,
    presentation = self.presentation,
    messageBankIds = self.messageBankIds,
    audioBankIds = self.audioBankIds,
    scriptMemberIds = self.scriptMemberIds,
    iconPageIds = self.iconPageIds,
    portraitPageIds = self.portraitPageIds,
    mapCellKeys = self.mapCellKeys,
    resolveMapPlan = resolveMapPlan,
  }
end

---@param mapId integer
---@return table<string, unknown>|nil
function InteractiveCacheBuild:_mapPlanQuiet(mapId)
  local cached = self.mapPlans[mapId]
  if cached ~= nil then
    if cached == false then
      return nil
    end
    return cached
  end
  local ok, plan = pcall(MapCompilePlan.plan, self.romFs, self.indexBundle.index, mapId, self.producerId)
  if not ok or plan == nil then
    self.mapPlans[mapId] = false
    return nil
  end
  self.mapPlans[mapId] = plan
  local cellKeys = {}
  for _, cellPlan in ipairs(plan.cellPlans or {}) do
    local descriptor = cellPlan.descriptor
    cellKeys[#cellKeys + 1] = descriptor.matrixMemberId .. "-" .. descriptor.index
  end
  table.sort(cellKeys)
  self.mapCellKeys[mapId] = cellKeys
  return plan
end

---@return integer[]
function InteractiveCacheBuild:_supportedMapDataIds()
  if self.mapDataIds == nil then
    local session = assert(FieldMapDataCompiler.newSession(self.romFs))
    local ids = {}
    local ok, failure = pcall(function()
      for mapId = 0, self.mapCount - 1 do
        if session:compile(mapId) ~= nil then
          ids[#ids + 1] = mapId
        end
      end
    end)
    session:close()
    if not ok then
      error(failure, 0)
    end
    table.sort(ids)
    self.mapDataIds = ids
  end
  return self.mapDataIds
end

---@return integer[]
function InteractiveCacheBuild:_resolvedMapIds()
  if self.resolvedMapIds == nil then
    local ids = {}
    for mapId = 0, self.mapCount - 1 do
      if self:_mapPlanQuiet(mapId) ~= nil then
        ids[#ids + 1] = mapId
      end
    end
    table.sort(ids)
    self.resolvedMapIds = ids
  end
  return self.resolvedMapIds
end

---@param kind string
---@param key string
---@return table<string, unknown>|nil descriptor
---@return string|nil failure
function InteractiveCacheBuild:_cellDescriptor(kind, key)
  assert(kind == "field-cell", "cell resolution requires the field-cell kind")
  local matrixMemberId, index = key:match("^([0-9]+)-([0-9]+)$")
  matrixMemberId, index = tonumber(matrixMemberId), tonumber(index)
  for _, matrix in ipairs(self.indexBundle.index.matrices) do
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
    payload = self:_payload(entry.kind, entry.key),
  })
end

---@param kind string
---@param key string
---@return table<string, unknown>
function InteractiveCacheBuild:_payload(kind, key)
  local payload = { producerFingerprint = self.producerId }
  if kind == "script-member" then
    payload.memberId = tonumber(key)
    payload.generationKey = self.scriptPlan.generationKey
  elseif kind == "field-cell" then
    local descriptor = assert(self:_cellDescriptor(kind, key))
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
function InteractiveCacheBuild:_submit(entry)
  if entry.ready or entry.failure ~= nil then
    return
  end
  if not entry.validated then
    entry.validated = true
    if ArtifactJobs.validate(self.cacheFs, self.generationId, entry.kind, entry.key, self:_plans()) then
      entry.ready = true
      return
    end
  end
  local state = self.pool:status(entry.jobKey)
  if state == "unknown" and not entry.submitted then
    if entry.priority == 100 and self:_outstandingSweep(self:_sweepBound()) >= self:_sweepBound() then
      return
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
      payload = self:_payload(entry.kind, entry.key),
    })
    entry.submitted = true
    if requestState == "failed" then
      local message = requestDetails and requestDetails.error or "compiler job failed"
      entry.failure = entry.jobKey .. ": " .. tostring(message)
    end
    return
  end
  entry.submitted = true
  if state == "ready" then
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
  elseif state == "failed" then
    local _, details = self.pool:status(entry.jobKey)
    local message = details and details.error or "compiler job failed"
    entry.failure = entry.jobKey .. ": " .. tostring(message)
  end
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

---@param entry InteractiveCacheBuild.Interest
---@param trail table<string, boolean>|nil canonical identities on the current descent
function InteractiveCacheBuild:_ensure(entry, trail)
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
    return
  end
  trail[entry.jobKey] = true
  local plansOk, depsOrCause = pcall(ArtifactJobs.dependencies, entry.kind, entry.key, self:_plans())
  if not plansOk then
    if entry.failure == nil then
      entry.failure = self.generationId
        .. " "
        .. entry.kind
        .. " "
        .. entry.key
        .. ": dependency plan failed: "
        .. tostring(depsOrCause)
    end
    trail[entry.jobKey] = nil
    return
  end
  local deps = depsOrCause
  for _, dep in ipairs(deps) do
    local depEntry = self:_register(dep.kind, dep.key, entry.urgency)
    self:_ensure(depEntry, trail)
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
      return
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
      return
    end
    if not depEntry.ready then
      trail[entry.jobKey] = nil
      return
    end
  end
  trail[entry.jobKey] = nil
  self:_submit(entry)
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
  self:_ensure(entry)
  if entry.failure ~= nil then
    return false, entry.failure
  end
  if entry.ready then
    return true, nil
  end
  return false, nil
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
    mapDataIds = self:_supportedMapDataIds(),
  })
end

---@return string|nil follower mismatch diagnostic
function InteractiveCacheBuild:_followerError()
  local actorIndex = self.cacheFs:loadLua(FieldActorCache.indexPath())
  if type(actorIndex) ~= "table" or type(actorIndex.spriteIds) ~= "table" then
    return "merged actor index is not staged"
  end
  local spriteIds = {}
  for _, spriteId in ipairs(actorIndex.spriteIds) do
    spriteIds[spriteId] = true
  end
  local followersOk, followersErr = ArtifactJobs.checkFollowers(self.catalog, spriteIds)
  if not followersOk then
    return followersErr
  end
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
  local current = self.milestones[name]
  if current == nil or ArtifactJobs.priorityFor(urgency) < ArtifactJobs.priorityFor(current) then
    self.milestones[name] = urgency
  end
  local members = self:_milestoneMembers(name)
  for _, member in ipairs(members) do
    self:_answer(self:_register(member.kind, member.key, self.milestones[name]))
  end
  local ready, failure = self:_milestoneAnswer(members)
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
---@param urgency string
---@return boolean
---@return string|nil
function InteractiveCacheBuild:requestField(mapId, urgency)
  assert(not self.retired, "generation session is retired")
  assert(isInteger(mapId) and mapId >= 0, "map ID must be a non-negative integer")
  ArtifactJobs.priorityFor(urgency)
  local plan = self:_mapPlanQuiet(mapId)
  if plan == nil then
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
---@param urgency string
---@return boolean
---@return string|nil
function InteractiveCacheBuild:requestJob(kind, key, urgency)
  assert(not self.retired, "generation session is retired")
  ArtifactJobs.jobKey(kind, key)
  ArtifactJobs.priorityFor(urgency)
  if kind == "map" then
    if self:_mapPlanQuiet(canonicalMapId(key)) == nil then
      return false, self.generationId .. " map " .. key .. ": source has no supported map"
    end
  elseif kind == "field-cell" then
    if self:_cellDescriptor(kind, key) == nil then
      return false, self.generationId .. " field-cell " .. key .. ": canonical index has no such cell"
    end
  elseif kind == "mon-portrait-page" then
    local supported = false
    for _, candidate in ipairs(self.portraitPageIds) do
      if candidate == tonumber(key) then
        supported = true
        break
      end
    end
    if not supported then
      return false, self.generationId .. " mon-portrait-page " .. key .. ": source has no such page"
    end
  elseif kind == "mon-icon-page" then
    local supported = false
    for _, candidate in ipairs(self.iconPageIds) do
      if candidate == tonumber(key) then
        supported = true
        break
      end
    end
    if not supported then
      return false, self.generationId .. " mon-icon-page " .. key .. ": source has no such page"
    end
  elseif kind == "message-bank" then
    local supported = false
    for _, candidate in ipairs(self.messageBankIds) do
      if candidate == tonumber(key) then
        supported = true
        break
      end
    end
    if not supported then
      return false, self.generationId .. " message-bank " .. key .. ": source has no such bank"
    end
  elseif kind == "audio-bank" then
    local supported = false
    for _, candidate in ipairs(self.audioBankIds) do
      if candidate == tonumber(key) then
        supported = true
        break
      end
    end
    if not supported then
      return false, self.generationId .. " audio-bank " .. key .. ": source has no such closure"
    end
  elseif kind == "script-member" then
    local supported = false
    for _, candidate in ipairs(self.scriptMemberIds) do
      if candidate == tonumber(key) then
        supported = true
        break
      end
    end
    if not supported then
      return false, self.generationId .. " script-member " .. key .. ": source has no nonempty member"
    end
  elseif kind == "map-data" then
    local supported = false
    for _, candidate in ipairs(self:_supportedMapDataIds()) do
      if candidate == tonumber(key) then
        supported = true
        break
      end
    end
    if not supported then
      return false, self.generationId .. " map-data " .. key .. ": source has no field record"
    end
  end
  return self:_answer(self:_register(kind, key, urgency))
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

function InteractiveCacheBuild:_fillSweep()
  local cells = {}
  for _, matrix in ipairs(self.indexBundle.index.matrices) do
    for _, descriptor in ipairs(matrix.cells) do
      cells[#cells + 1] = descriptor.matrixMemberId .. "-" .. descriptor.index
    end
  end
  table.sort(cells)
  for _, cellKey in ipairs(cells) do
    self:_answer(self:_register("field-cell", cellKey, "sweep"))
  end
  for _, mapId in ipairs(self:_resolvedMapIds()) do
    self:_answer(self:_register("map", tostring(mapId), "sweep"))
  end
  for _, pageId in ipairs(self.portraitPageIds) do
    self:_answer(self:_register("mon-portrait-page", tostring(pageId), "sweep"))
  end
end

function InteractiveCacheBuild:update()
  assert(not self.retired, "generation session is retired")
  self.pool:update()
  for _, entry in ipairs(self.interest) do
    if not entry.ready and entry.failure == nil then
      self:_ensure(entry)
    end
  end
  if self.sweepEnabled and self:_bootstrapReady() then
    if self.milestones["field-core"] == nil then
      self.milestones["field-core"] = "near"
    end
    for _, member in ipairs(self:_milestoneMembers("field-core")) do
      self:_answer(self:_register(member.kind, member.key, self.milestones["field-core"]))
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
          ready = ready + 1
        else
          entry.failure = self.generationId
            .. " "
            .. entry.kind
            .. " "
            .. entry.key
            .. ": published output fails its family validator"
          failures[#failures + 1] = entry.failure
        end
      elseif state == "failed" then
        local _, details = self.pool:status(entry.jobKey)
        entry.failure = entry.jobKey .. ": " .. tostring(details and details.error or "compiler job failed")
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
  }
end

function InteractiveCacheBuild:retire()
  if self.retired then
    return
  end
  self.retired = true
  -- Logical interest ends here; executing physical slots stay charged to the
  -- pool until their terminal reply or joined exit. Late old-epoch output
  -- can no longer publish through this session.
  self.pool:retireSelection(self.epoch)
  self.interest = {}
  self.byKey = {}
  if self.romFs ~= nil then
    local romFs = self.romFs
    pcall(romFs.close, romFs)
  end
end

return InteractiveCacheBuild
