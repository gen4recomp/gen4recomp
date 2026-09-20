-- Owns a worker-private artifact stage and its controller-side publication.
-- A stage is sealed at construction with its generation, epoch, and canonical
-- job identity. A successful finish stages the family output together with
-- its generation receipt in one transaction; the controller publishes only
-- after the stage identity matches the current expectation. Owned roots may
-- be exact files or directories, but they may never overlap each other or
-- swallow a shared file. A staged shared file that contradicts live bytes is
-- a conflict, never a silent reuse.

local ArtifactState = require("romdump.src.build.ArtifactState")
local Errors = require("libs.errors.src.Errors")
local CacheFs = require("libs.storage.src.CacheFs")

---@class PreparedArtifact.Manifest
---@field schema string
---@field versionId string
---@field generationId string
---@field epoch integer
---@field kind string
---@field key string
---@field jobKey string
---@field stageName string
---@field status "success"|"failure"
---@field ownedRoots string[]
---@field sharedFiles string[]
---@field sharedInstall string[] worker-resolved shared paths the controller must install
---@field sharedReused string[] worker-resolved shared paths already live and byte-identical
---@field result table<string, unknown>?
---@field error table<string, unknown>?
---@class PreparedArtifact
---@field private _cacheFs CacheFs
---@field private _stageFs CacheFs
---@field private _generationId string
---@field private _epoch integer
---@field private _kind string
---@field private _key string
---@field private _jobKey string
---@field private _stageName string
---@field private _ownedRoots table<string, boolean>
---@field private _sharedFiles table<string, boolean>
---@field private _sharedInstall string[]
---@field private _sharedReused string[]
---@field private _status string
---@field private _manifest PreparedArtifact.Manifest?
local PreparedArtifact = {}
PreparedArtifact.__index = PreparedArtifact

local MANIFEST_PATH = "_prepared/result.lua"
local MANIFEST_SCHEMA = "g4-prepared-artifact-v3"

local function assertSafePath(cacheFs, path, label)
  assert(type(path) == "string" and path ~= "", label .. " must be a non-empty path")
  cacheFs:resolve(path)
  assert(not path:match("/$"), label .. " must not end with a slash")
end

local function isPathUnder(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function pathsOverlap(first, second)
  return isPathUnder(first, second) or isPathUnder(second, first)
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
---@param expected { versionId: string, generationId: string, epoch: integer, kind: string, key: string, jobKey: string, stageName: string }
---@return PreparedArtifact.Manifest
local function validateManifest(manifest, expected)
  assert(type(manifest) == "table", "prepared artifact manifest must be a table")
  assert(manifest.schema == MANIFEST_SCHEMA, "prepared artifact manifest schema mismatch")
  assert(manifest.versionId == expected.versionId, "prepared artifact version mismatch")
  assert(manifest.generationId == expected.generationId, "prepared artifact generation mismatch")
  assert(manifest.epoch == expected.epoch, "prepared artifact epoch mismatch")
  assert(manifest.kind == expected.kind, "prepared artifact kind mismatch")
  assert(manifest.key == expected.key, "prepared artifact key mismatch")
  assert(manifest.jobKey == expected.jobKey, "prepared artifact job mismatch")
  assert(manifest.stageName == expected.stageName, "prepared artifact stage mismatch")
  assert(manifest.status == "success" or manifest.status == "failure", "prepared artifact status is invalid")
  assert(type(manifest.ownedRoots) == "table", "prepared artifact owned roots are missing")
  assert(type(manifest.sharedFiles) == "table", "prepared artifact shared files are missing")
  assert(type(manifest.sharedInstall) == "table", "prepared artifact shared installs are missing")
  assert(type(manifest.sharedReused) == "table", "prepared artifact shared reuses are missing")
  local classified = {}
  for _, path in ipairs(manifest.sharedInstall) do
    assert(type(path) == "string" and classified[path] == nil, "prepared artifact shared decision is invalid")
    classified[path] = true
  end
  for _, path in ipairs(manifest.sharedReused) do
    assert(type(path) == "string" and classified[path] == nil, "prepared artifact shared decision is invalid")
    classified[path] = true
  end
  if manifest.status == "failure" then
    assert(
      #manifest.sharedInstall == 0 and #manifest.sharedReused == 0,
      "failed prepared artifact carries shared decisions"
    )
  else
    for _, path in ipairs(manifest.sharedFiles) do
      assert(classified[path] == true, "prepared artifact shared file has no publication decision: " .. tostring(path))
    end
  end
  if manifest.status == "success" then
    assert(#manifest.ownedRoots > 0, "prepared artifact has no owned roots")
    assert(
      type(manifest.result) == "table" and type(manifest.result.marker) == "string" and manifest.result.marker ~= "",
      "prepared artifact result marker is required"
    )
    local receiptPath = ArtifactState.path(manifest.kind, manifest.key)
    local ownsReceipt = false
    for _, root in ipairs(manifest.ownedRoots) do
      if root == receiptPath then
        ownsReceipt = true
      end
    end
    assert(ownsReceipt, "prepared artifact transaction is missing its receipt")
  end
  return manifest --[[@as PreparedArtifact.Manifest]]
end

---@param options table<string, unknown>
---@return PreparedArtifact
local function newInstance(options)
  assert(type(options) == "table", "prepared artifact options are required")
  assert(options.cacheFs and options.cacheFs.versionId, "prepared artifact requires a cache filesystem")
  local generationId = options.generationId
  assert(type(generationId) == "string" and generationId ~= "", "prepared artifact generation is required")
  local epoch = options.epoch
  assert(type(epoch) == "number" and epoch % 1 == 0, "prepared artifact epoch must be an integer")
  local kind = options.kind
  assert(type(kind) == "string" and kind ~= "", "prepared artifact kind is required")
  local key = options.key
  assert(type(key) == "string" and key ~= "", "prepared artifact key is required")
  local jobKey = options.jobKey
  assert(type(jobKey) == "string" and jobKey ~= "", "prepared artifact job key is required")
  assert(jobKey == kind .. ":" .. key, "prepared artifact job identity must match its kind and key")
  local stageName = options.stageName
  assert(type(stageName) == "string", "prepared artifact stage name is required")
  assert(stageName:match("^[%w%-_]+$"), "prepared artifact stage name is unsafe")
  ArtifactState.path(kind, key)

  local stageFs = CacheFs.forArtifactStage(options.cacheFs.versionId, stageName, options.cacheFs.backend)
  return setmetatable({
    _cacheFs = options.cacheFs,
    _stageFs = stageFs,
    _generationId = generationId,
    _epoch = epoch,
    _kind = kind,
    _key = key,
    _jobKey = jobKey,
    _stageName = stageName,
    _ownedRoots = {},
    _sharedFiles = {},
    _sharedInstall = {},
    _sharedReused = {},
    _status = "open",
  }, PreparedArtifact)
end

---@param options table<string, unknown>
---@return PreparedArtifact
function PreparedArtifact.new(options)
  local artifact = newInstance(options)
  assert(not artifact._stageFs:exists(""), "prepared artifact stage already exists: " .. artifact._stageName)
  return artifact
end

---@param options table<string, unknown>
---@return PreparedArtifact
function PreparedArtifact.open(options)
  local artifact = newInstance(options)
  local manifest = artifact._stageFs:loadLua(MANIFEST_PATH)
  local validated = validateManifest(manifest, {
    versionId = artifact._cacheFs.versionId,
    generationId = artifact._generationId,
    epoch = artifact._epoch,
    kind = artifact._kind,
    key = artifact._key,
    jobKey = artifact._jobKey,
    stageName = artifact._stageName,
  })
  for _, path in ipairs(validated.ownedRoots) do
    artifact:addOwnedRoot(path)
  end
  for _, path in ipairs(validated.sharedFiles) do
    artifact:addSharedFile(path)
  end
  artifact._sharedInstall = validated.sharedInstall
  artifact._sharedReused = validated.sharedReused
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
  if self._ownedRoots[path] then
    return
  end
  for existing in pairs(self._ownedRoots) do
    assert(not pathsOverlap(path, existing), "prepared artifact owned roots overlap: " .. path)
  end
  for shared in pairs(self._sharedFiles) do
    assert(not isPathUnder(shared, path), "prepared artifact owned root contains a shared file: " .. path)
  end
  assert(not self._sharedFiles[path], "prepared artifact path is both owned and shared")
  self._ownedRoots[path] = true
end

function PreparedArtifact:addSharedFile(path)
  assert(self._status == "open", "prepared artifact is already finalized")
  assertSafePath(self._cacheFs, path, "shared file")
  if self._sharedFiles[path] then
    return
  end
  assert(not self._ownedRoots[path], "prepared artifact path is both owned and shared")
  for root in pairs(self._ownedRoots) do
    assert(not isPathUnder(path, root), "prepared artifact shared file is owned: " .. path)
  end
  self._sharedFiles[path] = true
end

-- Worker-side shared-file proof, sealed before success: every staged
-- shared path must exist; a path absent from the live tree becomes an
-- install candidate, a byte-identical live path is marked reused and its
-- redundant staged copy removed, and a contradiction fails before any
-- success is sealed. The controller later installs or reuses from this
-- classification without reading payload bytes. Shared paths must be
-- deterministic derivations of the generation source: the same path always
-- carries the same bytes, so concurrent producers cannot genuinely
-- conflict; a mismatch fails here and serialized controller publication
-- never overwrites live bytes on a race.
function PreparedArtifact:_reconcileShared()
  assert(self._status == "open", "prepared artifact is already finalized")
  local install, reused = {}, {}
  for path in pairs(self._sharedFiles) do
    assert(self._stageFs:exists(path, "file"), "prepared shared file is missing: " .. path)
    local live = self._cacheFs:read(path)
    if live == nil then
      install[#install + 1] = path
    elseif live == self._stageFs:read(path) then
      reused[#reused + 1] = path
      self._stageFs:remove(path)
    else
      Errors.raise("PREPARED_SHARED_CONFLICT", "staged shared file contradicts the live artifact", { path = path })
    end
  end
  table.sort(install)
  table.sort(reused)
  self._sharedInstall = install
  self._sharedReused = reused
end

function PreparedArtifact:_finish(status, result, failure)
  assert(self._status == "open", "prepared artifact is already finalized")
  if status == "success" then
    self:_reconcileShared()
  else
    self._sharedInstall = {}
    self._sharedReused = {}
  end
  local ownedRoots = sortedKeys(self._ownedRoots)
  if status == "success" then
    assert(type(result) == "table", "prepared artifact result must be a table")
    assert(type(result.marker) == "string" and result.marker ~= "", "prepared artifact result marker is required")
    assert(next(self._ownedRoots) ~= nil, "prepared artifact has no owned roots")
    local receiptPath = ArtifactState.path(self._kind, self._key)
    for existing in pairs(self._ownedRoots) do
      assert(not pathsOverlap(existing, receiptPath), "prepared artifact family root swallows its receipt")
    end
    self._stageFs:writeLua(receiptPath, {
      schema = ArtifactState.RECEIPT_SCHEMA,
      generationId = self._generationId,
      kind = self._kind,
      key = self._key,
      marker = result.marker,
    })
    self._ownedRoots[receiptPath] = true
    local familyRoots = sortedKeys(self._ownedRoots)
    local orderedRoots = {}
    for _, root in ipairs(familyRoots) do
      if root ~= receiptPath then
        orderedRoots[#orderedRoots + 1] = root
      end
    end
    orderedRoots[#orderedRoots + 1] = receiptPath
    ownedRoots = orderedRoots
  end
  local manifest = {
    schema = MANIFEST_SCHEMA,
    versionId = self._cacheFs.versionId,
    generationId = self._generationId,
    epoch = self._epoch,
    kind = self._kind,
    key = self._key,
    jobKey = self._jobKey,
    stageName = self._stageName,
    status = status,
    ownedRoots = ownedRoots,
    sharedFiles = sortedKeys(self._sharedFiles),
    sharedInstall = self._sharedInstall,
    sharedReused = self._sharedReused,
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

---@param expected { generationId: string, epoch: integer, kind: string, key: string, jobKey: string, stageName?: string }
---@return boolean
function PreparedArtifact:publish(expected)
  assert(self._status == "finished", "prepared artifact is not a successful result")
  assert(type(expected) == "table", "publish requires the controller-supplied expected identity")
  assert(expected.generationId == self._generationId, "prepared artifact generation mismatch")
  assert(expected.epoch == self._epoch, "prepared artifact epoch mismatch")
  assert(expected.kind == self._kind, "prepared artifact kind mismatch")
  assert(expected.key == self._key, "prepared artifact key mismatch")
  assert(expected.jobKey == self._jobKey, "prepared artifact job mismatch")
  if expected.stageName ~= nil then
    assert(expected.stageName == self._stageName, "prepared artifact stage mismatch")
  end
  local manifest = validateManifest(self._stageFs:loadLua(MANIFEST_PATH), {
    versionId = self._cacheFs.versionId,
    generationId = self._generationId,
    epoch = self._epoch,
    kind = self._kind,
    key = self._key,
    jobKey = self._jobKey,
    stageName = self._stageName,
  })
  assert(manifest.status == "success", "failed prepared artifact cannot publish")

  -- Shared publication follows the worker-resolved classification with
  -- metadata checks and renames only: installs move the staged copy
  -- into the live tree, reuses only require the live path to still
  -- exist. No payload byte is read or copied here.
  for _, path in ipairs(manifest.sharedInstall) do
    assert(self._stageFs:exists(path, "file"), "prepared shared file is missing: " .. path)
    local parent = path:match("^(.*)/[^/]+$")
    if parent then
      self._cacheFs:createDirectory(parent)
    end
    self._cacheFs:replaceAt(self._stageFs:resolve(path), self._cacheFs:resolve(path))
  end
  for _, path in ipairs(manifest.sharedReused) do
    if not self._cacheFs:exists(path) then
      Errors.raise("PREPARED_SHARED_CONFLICT", "reused shared file changed before publication", { path = path })
    end
  end

  for _, root in ipairs(manifest.ownedRoots) do
    assert(
      self._stageFs:exists(root, "file") or self._stageFs:exists(root, "directory"),
      "prepared owned root is missing: " .. root
    )
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
