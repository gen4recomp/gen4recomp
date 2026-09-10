-- Runs fixed producer jobs inside one persistent LÖVE worker VM.

local CacheFs = require("libs.storage.src.CacheFs")
local RomFs = require("romdump.src.source.RomFs")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local MapCacheWriter = require("romdump.src.digest.map.MapCacheWriter")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")

local CompilerWorker = {}

local function failArtifact(artifact, failure, traceback)
  local ok, finalizeError = pcall(artifact.finishFailure, artifact, failure, traceback)
  if not ok then
    error(finalizeError, 0)
  end
end

local function mapResult(bundle)
  return {
    mapId = bundle.mapId,
    marker = bundle.marker,
    mapSymbol = bundle.scene.mapSymbol,
    width = bundle.scene.matrix.width,
    height = bundle.scene.matrix.height,
    unresolvedMaterials = bundle.unresolvedMaterials,
  }
end

---@param job table<string, unknown>
---@param context table<string, unknown>
---@return table<string, unknown>
function CompilerWorker.execute(job, context)
  assert(type(job) == "table", "worker job must be a table")
  assert(job.kind == "map", "unsupported compiler job kind: " .. tostring(job.kind))
  assert(type(job.key) == "string" and job.key ~= "", "worker job key is required")
  assert(type(job.mapId) == "number" and job.mapId % 1 == 0, "map job requires an integer mapId")
  assert(context and context.romFs and context.cacheFs, "worker context is incomplete")
  assert(type(job.stageName) == "string", "worker job stage name is required")

  local artifact = PreparedArtifact.new({
    cacheFs = context.cacheFs,
    kind = job.kind,
    jobKey = job.key,
    stageName = job.stageName,
  })

  local ok, bundle, compileError = xpcall(function()
    return MapAssetCompiler.compile(context.romFs, job.mapId)
  end, function(failure)
    return { failure = failure, traceback = debug.traceback("", 2) }
  end)
  if not ok then
    local errorInfo = assert(bundle)
    local failure = errorInfo.failure
    local traceback = errorInfo.traceback
    failArtifact(artifact, failure, traceback)
    error(failure, 0)
  end
  if not bundle then
    failArtifact(artifact, compileError)
    error(compileError, 0)
  end

  local result = mapResult(bundle)
  local stageOk, stageError = xpcall(function()
    MapCacheWriter.stage(artifact, bundle)
    artifact:finishSuccess(result)
  end, function(failure)
    return { failure = failure, traceback = debug.traceback("", 2) }
  end)
  if not stageOk then
    local errorInfo = assert(stageError)
    local failure = errorInfo.failure
    local traceback = errorInfo.traceback
    failArtifact(artifact, failure, traceback)
    error(failure, 0)
  end
  return { stageName = job.stageName, result = result }
end

---@param workerId integer
---@param versionId string
---@param inputChannel table<string, function>
---@param resultChannel table<string, function>
function CompilerWorker.run(workerId, versionId, inputChannel, resultChannel)
  assert(type(workerId) == "number" and workerId % 1 == 0, "worker id must be an integer")
  assert(type(versionId) == "string", "worker version is required")
  local romFs, openError = RomFs.open(versionId)
  if not romFs then
    error(openError, 0)
  end
  local cacheFs = CacheFs.forVersion(versionId)
  local context = { romFs = romFs, cacheFs = cacheFs, workerId = workerId }
  while true do
    local job = inputChannel:demand()
    assert(type(job) == "table", "worker received an invalid control message")
    if job.kind == "stop" then
      break
    end
    local jobKey = assert(job.jobKey or job.key)
    local executeJob = {
      kind = job.kind,
      key = jobKey,
      mapId = job.mapId,
      stageName = job.stageName,
    }
    local ok, result = xpcall(function()
      return CompilerWorker.execute(executeJob, context)
    end, function(failure)
      return failure
    end)
    if ok then
      resultChannel:push({
        workerId = workerId,
        jobKey = jobKey,
        stageName = result.stageName,
        status = "prepared",
      })
    else
      resultChannel:push({
        workerId = workerId,
        jobKey = jobKey,
        stageName = job.stageName,
        status = "failed",
      })
    end
  end
  romFs:close()
end

return CompilerWorker
