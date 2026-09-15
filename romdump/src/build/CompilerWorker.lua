-- Runs fixed producer jobs inside one persistent worker VM.
-- Each job carries its explicit source version, generation, and epoch. The
-- worker opens or switches its source context only at job boundaries, stages
-- one prepared artifact per job, releases transient scratch after heavy work,
-- and exits after jumbo work so the controller can recycle the VM.

local CacheFs = require("libs.storage.src.CacheFs")
local RomFs = require("romdump.src.source.RomFs")
local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local GxDisplayList = require("libs.nds.src.gx.GxDisplayList")
local GxGeometryBuffer = require("libs.nds.src.gx.GxGeometryBuffer")

local CompilerWorker = {}

local function wallSeconds()
  local host = rawget(_G, "love")
  if host ~= nil and host.timer == nil then
    -- Worker Lua states start without love.timer preloaded; require it on
    -- demand so job timings stay wall time rather than CPU time.
    pcall(require, "love.timer")
  end
  assert(host and host.timer and type(host.timer.getTime) == "function", "worker wall clock is required")
  return host.timer.getTime()
end

---@param context table<string, unknown>
local function closeContext(context)
  ArtifactJobs.closeSessions(context)
  if context.romFs ~= nil then
    local romFs = context.romFs
    context.romFs = nil
    context.cacheFs = nil
    context.versionId = nil
    pcall(romFs.close, romFs)
  else
    context.cacheFs = nil
    context.versionId = nil
  end
  context.terrainScratch = {}
  if context.fieldCellScratch ~= nil then
    context.fieldCellScratch.terrainScratch = context.terrainScratch
  end
end

---@param job table<string, unknown>
---@param context table<string, unknown>
local function switchContext(job, context)
  assert(type(job.versionId) == "string" and job.versionId ~= "", "worker job version is required")
  assert(type(job.generationId) == "string" and job.generationId ~= "", "worker job generation is required")
  assert(type(job.epoch) == "number" and job.epoch % 1 == 0, "worker job epoch must be an integer")
  if context.versionId ~= job.versionId then
    closeContext(context)
    local romFs, openError = RomFs.open(job.versionId)
    if not romFs then
      error(openError, 0)
    end
    context.romFs = romFs
    context.cacheFs = CacheFs.forVersion(job.versionId)
    context.versionId = job.versionId
  end
  assert(context.romFs and context.cacheFs, "worker context is incomplete")
end

---@param context table<string, unknown>
local function releaseHeavyScratch(context)
  context.terrainScratch = {}
  local scratch = context.fieldCellScratch
  if type(scratch) == "table" then
    scratch.terrainScratch = context.terrainScratch
    scratch.lastBundle = nil
    scratch.lastDescriptor = nil
  end
end

---@param job table<string, unknown>
---@param context table<string, unknown>
---@return table<string, unknown>
function CompilerWorker.execute(job, context)
  assert(type(job) == "table", "worker job must be a table")
  return ArtifactJobs.execute(job, context)
end

---@param workerId integer
---@param inputChannel table<string, function>
---@param resultChannel table<string, function>
function CompilerWorker.run(workerId, inputChannel, resultChannel)
  assert(type(workerId) == "number" and workerId % 1 == 0, "worker id must be an integer")
  local context = {
    workerId = workerId,
    terrainScratch = {},
    fieldCellScratch = {
      geometryArena = GxGeometryBuffer.new(),
      gxScratch = GxDisplayList.newScratch(),
    },
  }
  context.fieldCellScratch.terrainScratch = context.terrainScratch
  context.geometryArena = context.fieldCellScratch.geometryArena
  context.gxScratch = context.fieldCellScratch.gxScratch
  while true do
    local job = inputChannel:demand()
    assert(type(job) == "table", "worker received an invalid control message")
    if job.kind == "stop" then
      break
    end
    if job.kind == "close-context" then
      -- The barrier token is echoed only after the owned source context is
      -- closed. A failed close propagates with its original text and emits
      -- no acknowledgement, so the controller never mistakes it for closure.
      closeContext(context)
      resultChannel:push({ workerId = workerId, status = "context-closed", closeToken = job.closeToken })
    else
      local jobKey = assert(job.jobKey or job.key)
      local startedAt = wallSeconds()
      switchContext(job, context)
      local executeJob = {
        kind = job.kind,
        key = job.key or jobKey,
        generationId = job.generationId,
        epoch = job.epoch,
        producerFingerprint = job.producerFingerprint,
        stageName = job.stageName,
        payload = job.payload,
      }
      local retiring = job.sizeClass == "jumbo"
      local ok, result = xpcall(function()
        return CompilerWorker.execute(executeJob, context)
      end, function(failure)
        return failure
      end)
      local workSeconds = wallSeconds() - startedAt
      if job.sizeClass == "heavy" then
        releaseHeavyScratch(context)
      end
      if ok then
        resultChannel:push({
          workerId = workerId,
          epoch = job.epoch,
          generationId = job.generationId,
          kind = job.kind,
          key = executeJob.key,
          jobKey = jobKey,
          stageName = result.stageName,
          status = "prepared",
          compileSeconds = nil,
          stageSeconds = nil,
          workSeconds = workSeconds,
          stagedBytes = 0,
          timingReason = "interleaved",
          retiring = retiring,
        })
      else
        resultChannel:push({
          workerId = workerId,
          epoch = job.epoch,
          generationId = job.generationId,
          kind = job.kind,
          key = executeJob.key,
          jobKey = jobKey,
          stageName = job.stageName,
          status = "failed",
          compileSeconds = nil,
          stageSeconds = nil,
          workSeconds = workSeconds,
          stagedBytes = 0,
          timingReason = "interleaved",
          retiring = retiring,
        })
      end
      if retiring then
        break
      end
    end
  end
  ArtifactJobs.closeSessions(context)
  if context.romFs ~= nil then
    local romFs = context.romFs
    context.romFs = nil
    romFs:close()
  end
end

return CompilerWorker
