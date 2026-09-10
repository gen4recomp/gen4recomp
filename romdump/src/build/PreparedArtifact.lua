-- Owns a worker-private artifact stage and its controller-side publication.

local Errors = require("libs.errors.src.Errors")
local CacheFs = require("libs.storage.src.CacheFs")

---@class PreparedArtifact.Manifest
---@field schema string
---@field versionId string
---@field kind string
---@field jobKey string
---@field stageName string
---@field status "success"|"failure"
---@field ownedRoots string[]
---@field sharedFiles string[]
---@field result table<string, unknown>?
---@field error table<string, unknown>?
---@class PreparedArtifact
---@field private _cacheFs CacheFs
---@field private _stageFs CacheFs
---@field private _kind string
---@field private _jobKey string
---@field private _stageName string
---@field private _ownedRoots table<string, boolean>
---@field private _sharedFiles table<string, boolean>
---@field private _status string
---@field private _manifest PreparedArtifact.Manifest?
local PreparedArtifact = {}
PreparedArtifact.__index = PreparedArtifact

local MANIFEST_PATH = "_prepared/result.lua"
local MANIFEST_SCHEMA = "g4-prepared-artifact-v1"

local function assertSafePath(cacheFs, path, label)
  assert(type(path) == "string" and path ~= "", label .. " must be a non-empty path")
  cacheFs:resolve(path)
  assert(not path:match("/$"), label .. " must not end with a slash")
end

local function sortedKeys(set)
  local result = {}
  for path in pairs(set) do
    result[#result + 1] = path
  end
  table.sort(result)
  return result
end

local function serializedError(value)
  if Errors.is(value) then
    return {
      code = value.code,
      message = value.message,
      context = value.context,
    }
  end
  return { message = tostring(value) }
end

---@param manifest unknown
---@param expected { versionId: string, kind: string, jobKey: string, stageName: string }
---@return PreparedArtifact.Manifest
local function validateManifest(manifest, expected)
  assert(type(manifest) == "table", "prepared artifact manifest must be a table")
  assert(manifest.schema == MANIFEST_SCHEMA, "prepared artifact manifest schema mismatch")
  assert(manifest.versionId == expected.versionId, "prepared artifact version mismatch")
  assert(manifest.kind == expected.kind, "prepared artifact kind mismatch")
  assert(manifest.jobKey == expected.jobKey, "prepared artifact job mismatch")
  assert(manifest.stageName == expected.stageName, "prepared artifact stage mismatch")
  assert(manifest.status == "success" or manifest.status == "failure", "prepared artifact status is invalid")
  assert(type(manifest.ownedRoots) == "table", "prepared artifact owned roots are missing")
  assert(type(manifest.sharedFiles) == "table", "prepared artifact shared files are missing")
  if manifest.status == "success" then
    assert(#manifest.ownedRoots > 0, "prepared artifact has no owned roots")
  end
  return manifest --[[@as PreparedArtifact.Manifest]]
end

---@param options table<string, unknown>
---@param clearStage boolean
---@return PreparedArtifact
local function newInstance(options, clearStage)
  assert(type(options) == "table", "prepared artifact options are required")
  assert(options.cacheFs and options.cacheFs.versionId, "prepared artifact requires a cache filesystem")
  assert(type(options.kind) == "string" and options.kind ~= "", "prepared artifact kind is required")
  assert(type(options.jobKey) == "string" and options.jobKey ~= "", "prepared artifact job key is required")
  assert(type(options.stageName) == "string", "prepared artifact stage name is required")
  assert(options.stageName:match("^[%w%-_]+$"), "prepared artifact stage name is unsafe")

  local stageFs = CacheFs.forArtifactStage(options.cacheFs.versionId, options.stageName, options.cacheFs.backend)
  if clearStage then
    stageFs:removeTree("")
  end
  return setmetatable({
    _cacheFs = options.cacheFs,
    _stageFs = stageFs,
    _kind = options.kind,
    _jobKey = options.jobKey,
    _stageName = options.stageName,
    _ownedRoots = {},
    _sharedFiles = {},
    _status = "open",
  }, PreparedArtifact)
end

---@param options table<string, unknown>
---@return PreparedArtifact
function PreparedArtifact.new(options)
  return newInstance(options, true)
end

---@param options table<string, unknown>
---@return PreparedArtifact
function PreparedArtifact.open(options)
  local artifact = newInstance(options, false)
  local manifest = artifact._stageFs:loadLua(MANIFEST_PATH)
  local validated = validateManifest(manifest, {
    versionId = artifact._cacheFs.versionId,
    kind = artifact._kind,
    jobKey = artifact._jobKey,
    stageName = artifact._stageName,
  })
  for _, path in ipairs(validated.ownedRoots) do
    assertSafePath(artifact._cacheFs, path, "owned root")
    artifact._ownedRoots[path] = true
  end
  for _, path in ipairs(validated.sharedFiles) do
    assertSafePath(artifact._cacheFs, path, "shared file")
    assert(not artifact._ownedRoots[path], "prepared artifact path is both owned and shared")
    artifact._sharedFiles[path] = true
  end
  artifact._status = validated.status == "success" and "finished" or "failed"
  artifact._manifest = validated
  return artifact
end

function PreparedArtifact:stageFs()
  return self._stageFs
end

function PreparedArtifact:cacheFs()
  return self._cacheFs
end

---@return PreparedArtifact.Manifest
function PreparedArtifact:manifest()
  assert(self._manifest, "prepared artifact has not been finalized")
  return self._manifest
end

function PreparedArtifact:addOwnedRoot(path)
  assert(self._status == "open", "prepared artifact is already finalized")
  assertSafePath(self._cacheFs, path, "owned root")
  assert(not self._sharedFiles[path], "prepared artifact path is both owned and shared")
  self._ownedRoots[path] = true
end

function PreparedArtifact:addSharedFile(path)
  assert(self._status == "open", "prepared artifact is already finalized")
  assertSafePath(self._cacheFs, path, "shared file")
  assert(not self._ownedRoots[path], "prepared artifact path is both owned and shared")
  self._sharedFiles[path] = true
end

function PreparedArtifact:_finish(status, result, failure)
  assert(self._status == "open", "prepared artifact is already finalized")
  if status == "success" then
    assert(next(self._ownedRoots) ~= nil, "prepared artifact has no owned roots")
  end
  local manifest = {
    schema = MANIFEST_SCHEMA,
    versionId = self._cacheFs.versionId,
    kind = self._kind,
    jobKey = self._jobKey,
    stageName = self._stageName,
    status = status,
    ownedRoots = sortedKeys(self._ownedRoots),
    sharedFiles = sortedKeys(self._sharedFiles),
    result = result,
    error = failure,
  }
  self._stageFs:writeLua(MANIFEST_PATH, manifest)
  self._manifest = manifest
  self._status = status == "success" and "finished" or "failed"
  return true
end

function PreparedArtifact:finishSuccess(result)
  assert(result == nil or type(result) == "table", "prepared artifact result must be a table")
  return self:_finish("success", result, nil)
end

function PreparedArtifact:finishFailure(failure, traceback)
  local errorRecord = serializedError(failure)
  if traceback then
    errorRecord.traceback = traceback
  end
  return self:_finish("failure", nil, errorRecord)
end

function PreparedArtifact:publish()
  assert(self._status == "finished", "prepared artifact is not a successful result")
  local manifest = validateManifest(self._stageFs:loadLua(MANIFEST_PATH), {
    versionId = self._cacheFs.versionId,
    kind = self._kind,
    jobKey = self._jobKey,
    stageName = self._stageName,
  })
  assert(manifest.status == "success", "failed prepared artifact cannot publish")

  for _, path in ipairs(manifest.sharedFiles) do
    assert(self._stageFs:exists(path, "file"), "prepared shared file is missing: " .. path)
    if not self._cacheFs:exists(path) then
      local parent = path:match("^(.*)/[^/]+$")
      if parent then
        self._cacheFs:createDirectory(parent)
      end
      self._cacheFs:replaceAt(self._stageFs:resolve(path), self._cacheFs:resolve(path))
    end
  end

  for _, root in ipairs(manifest.ownedRoots) do
    assert(self._stageFs:exists(root, "directory"), "prepared owned root is missing: " .. root)
    local parent = root:match("^(.*)/[^/]+$")
    if parent then
      self._cacheFs:createDirectory(parent)
      self._stageFs:createDirectory(parent)
    end
  end
  self._status = "publishing"
  local result = self._cacheFs:publishStaged(self._stageFs, manifest.ownedRoots, function()
    self._stageFs:removeTree("")
  end)
  self._status = "published"
  return result
end

function PreparedArtifact:abort()
  assert(self._status ~= "publishing" and self._status ~= "published", "cannot abort after publication begins")
  self._stageFs:removeTree("")
  self._status = "aborted"
  return true
end

function PreparedArtifact:isAbortable()
  return self._status ~= "publishing" and self._status ~= "published" and self._status ~= "aborted"
end

return PreparedArtifact
