-- Version-scoped private cache. Every path is normalized and confined below the
-- version prefix; absolute paths, drive letters, NUL, and "."/".." components
-- are rejected so no operation can escape its version subtree. Roots are
-- structural (`<versionId>/`, `<versionId>.__g4next/`, and artifact staging): a version id is any safe
-- path component, and which ids exist is the ROM catalog's business, not this
-- package's. Confinement, backend handling, parent creation, and Lua loading
-- share the internal ScopedFs mechanics with SaveFs; the cache root, allowed
-- mutations (tree deletion, staged publication, module loading), and CACHE_*
-- error namespace stay its own. The backend is injectable: the default wraps
-- love.filesystem; tests inject an in-memory fake. Path/security logic is
-- love-free and testable under bare LuaJIT.
--
-- Failure convention: every mutating operation reports success only if the
-- backend did; a falsy backend result is translated into a structured CACHE_*
-- error that reaches the caller, and a backend that raises propagates. No
-- mutating method may silently return true after a backend failure, so
-- publication logic can rely on a raise meaning "nothing happened" (or, for
-- cleanup, "the failure surfaced").

local Errors = require("libs.errors.src.Errors")
local LuaWriter = require("libs.codec.src.LuaWriter")
local ScopedFs = require("libs.storage.src.ScopedFs")
local StorageErrors = require("libs.storage.src.errors")

-- The CACHE_* codes this type raises through the shared mechanics.
local CACHE_ERRORS = {
  PATH_INVALID = StorageErrors.CACHE_PATH_INVALID,
  FILE_MISSING = StorageErrors.CACHE_FILE_MISSING,
  READ_FAILED = StorageErrors.CACHE_READ_FAILED,
  LUA_PARSE_FAILED = StorageErrors.CACHE_LUA_PARSE_FAILED,
  LUA_EVAL_FAILED = StorageErrors.CACHE_LUA_EVAL_FAILED,
  MKDIR_FAILED = StorageErrors.CACHE_MKDIR_FAILED,
  WRITE_FAILED = StorageErrors.CACHE_WRITE_FAILED,
  REMOVE_FAILED = StorageErrors.CACHE_REMOVE_FAILED,
  REPLACE_FAILED = StorageErrors.CACHE_REPLACE_FAILED,
}

---@class CacheFs
---@field versionId string
---@field private _prefix string
---@field private _root string
---@field backend ScopedFs.Backend
---@field prefix fun(self: CacheFs): string
---@field resolve fun(self: CacheFs, relativePath: string): string
---@field write fun(self: CacheFs, relativePath: string, data: string|love.Data): boolean
---@field read fun(self: CacheFs, relativePath: string): string?
---@field getInfo fun(self: CacheFs, relativePath: string): table<string, unknown>?
---@field exists fun(self: CacheFs, relativePath: string, expectedType?: string): boolean
---@field createDirectory fun(self: CacheFs, relativePath: string): boolean
---@field remove fun(self: CacheFs, relativePath: string): boolean
---@field replace fun(self: CacheFs, sourceRelativePath: string, destinationRelativePath: string): boolean
---@field replaceAt fun(self: CacheFs, sourcePath: string, destinationPath: string): boolean
---@field removeTree fun(self: CacheFs, relativePath: string): boolean
---@field removeStagedTree fun(self: CacheFs, stagingCache: CacheFs): boolean
---@field recoverPublication fun(self: CacheFs): boolean
---@field publishStaged fun(self: CacheFs, stageCache: CacheFs, roots: string[], cleanup: fun()): boolean
---@field publishFromStage fun(self: CacheFs, stagingCache: CacheFs): boolean
---@field writeLua fun(self: CacheFs, relativePath: string, value: table<string, unknown>): boolean
---@field loadLua fun(self: CacheFs, relativePath: string): table<string, unknown>?, Errors.Error?
local CacheFs = {}
CacheFs.__index = CacheFs

local NEXT_SUFFIX = ".__g4next"
local OLD_SUFFIX = ".__g4old"
local PUBLICATION_MANIFEST_SUFFIX = ".__g4publish.lua"
local PUBLICATION_MANIFEST_TEMP_SUFFIX = ".__g4publish.__g4next"
local PUBLICATION_COMMIT_SUFFIX = ".__g4published"
local PUBLICATION_MANIFEST_TEMP_PREFIX = ".__g4publish."
local PUBLICATION_MANIFEST_TEMP_ATTEMPT_SUFFIX = ".__g4next"
local PUBLICATION_SCHEMA = 2
local LEGACY_PUBLICATION_SCHEMA = 1
local PUBLICATION_COMMIT_CONTENT = "g4-cache-publish-v1"
local PUBLICATION_COMMIT_PREFIX = "g4-cache-publish-v2:"

local nextAttemptNumber = 0
local activeAttempts = setmetatable({}, { __mode = "k" })

local function siblingPath(fullPath, suffix)
  local parent, name = fullPath:match("^(.*)/([^/]+)$")
  if parent then
    return parent .. "/" .. name .. suffix
  end
  return fullPath .. suffix
end

---@param versionId string
---@param backend table<string, unknown>|nil
---@return CacheFs
function CacheFs.forVersion(versionId, backend)
  ScopedFs.validateVersionId(versionId)
  return setmetatable({
    versionId = versionId,
    _prefix = versionId .. "/",
    _root = versionId,
    backend = backend or ScopedFs.loveBackend(),
  }, CacheFs)
end

-- A CacheFs rooted at the disposable next sibling of the live version root.
-- Whole-version import writes here so publication can rename the completed tree
-- without copying it or crossing directory parents.
---@param versionId string
---@param backend table<string, unknown>|nil
---@return CacheFs
function CacheFs.forStaging(versionId, backend)
  ScopedFs.validateVersionId(versionId)
  local prefix = versionId .. NEXT_SUFFIX .. "/"
  return setmetatable({
    versionId = versionId,
    _prefix = prefix,
    _root = prefix:gsub("/$", ""),
    backend = backend or ScopedFs.loveBackend(),
  }, CacheFs)
end

-- A CacheFs rooted at the disposable `staging/<versionId>/<name>/` namespace,
-- mirroring the live cache-relative layout for one generated artifact. Used by
-- ArtifactPublisher for the staged publication of derived caches; like the ROM
-- staging root it is swept with the rest of `staging/<versionId>/` at the next
-- import. `name` must be a single safe path component.
---@param versionId string
---@param name string
---@param backend table<string, unknown>|nil
---@return CacheFs
function CacheFs.forArtifactStage(versionId, name, backend)
  ScopedFs.validateVersionId(versionId)
  assert(name:match("^[%w%-_]+$"), "artifact name must be a single safe path component")
  local prefix = "staging/" .. versionId .. "/" .. name .. "/"
  return setmetatable({
    versionId = versionId,
    _prefix = prefix,
    _root = prefix:gsub("/$", ""),
    backend = backend or ScopedFs.loveBackend(),
  }, CacheFs)
end

function CacheFs:prefix()
  return self._prefix
end

-- Normalize and confine a relative path, returning the full save-dir path.
-- Raises a structured error on any escape attempt. "" means the version root.
function CacheFs:resolve(relativePath)
  return ScopedFs.resolve(self._root, relativePath, CACHE_ERRORS)
end

function CacheFs:write(relativePath, data)
  return ScopedFs.write(self.backend, self:resolve(relativePath), data, CACHE_ERRORS)
end

function CacheFs:read(relativePath)
  return self.backend:read(self:resolve(relativePath))
end

function CacheFs:getInfo(relativePath)
  return self.backend:getInfo(self:resolve(relativePath))
end

-- Lists one directory and raises when the backend cannot answer. Cleanup code
-- must distinguish an empty directory from a failed listing.
function CacheFs:getDirectoryItems(relativePath)
  local full = self:resolve(relativePath)
  local items, err = self.backend:getDirectoryItems(full)
  if items == nil then
    Errors.raise(CACHE_ERRORS.READ_FAILED, err or "could not list directory", { path = full })
  end
  return items
end

function CacheFs:exists(relativePath, expectedType)
  local info = self.backend:getInfo(self:resolve(relativePath))
  if not info then
    return false
  end
  if expectedType then
    return info.type == expectedType
  end
  return true
end

function CacheFs:createDirectory(relativePath)
  local full = self:resolve(relativePath)
  local ok, err = self.backend:createDirectory(full)
  return ScopedFs.ensureBackend(ok, err, CACHE_ERRORS.MKDIR_FAILED, "could not create directory", { path = full })
end

-- Removing an absent path is a no-op; removing an existing path that the
-- backend cannot remove raises CACHE_REMOVE_FAILED.
function CacheFs:remove(relativePath)
  return ScopedFs.remove(self.backend, self:resolve(relativePath), CACHE_ERRORS)
end

-- Atomically replaces destination with an already-written sibling file. The
-- default backend uses the host rename primitive inside LÖVE's save directory.
function CacheFs:replace(sourceRelativePath, destinationRelativePath)
  local source = self:resolve(sourceRelativePath)
  local destination = self:resolve(destinationRelativePath)
  return self:replaceAt(source, destination)
end

-- Backend rename at save-directory-absolute paths with the standard failure
-- convention (CACHE_REPLACE_FAILED on a falsy backend result). Used by
-- replace() and by the publish/rollback logic in this module and
-- ArtifactPublisher, so a backend that reports failure can never make
-- publication report success.
function CacheFs:replaceAt(sourcePath, destinationPath)
  return ScopedFs.replace(self.backend, sourcePath, destinationPath, CACHE_ERRORS)
end

function CacheFs:removeTree(relativePath)
  self:_removeTreeAt(self:resolve(relativePath))
  return true
end

-- Recursively remove a save-directory-absolute path; a no-op when absent.
-- Any backend-reported removal or enumeration failure raises
-- CACHE_REMOVE_FAILED instead of silently reporting success.
function CacheFs:_removeTreeAt(fullPath)
  local function rec(path)
    local info = self.backend:getInfo(path)
    if not info then
      return
    end
    if info.type == "directory" then
      local items = self.backend:getDirectoryItems(path)
      if not items then
        Errors.raise(CACHE_ERRORS.REMOVE_FAILED, "could not list directory", { path = path })
      end
      for _, name in ipairs(items) do
        rec(path .. "/" .. name)
      end
    end
    local ok, err = self.backend:remove(path)
    ScopedFs.ensureBackend(ok, err, CACHE_ERRORS.REMOVE_FAILED, "could not remove", { path = path })
  end
  rec(fullPath)
end

-- Discard staged output after recovering any journaled publication. An
-- unjournaled old sibling is removed only when the live root exists; otherwise
-- it may be the only last-known-good copy. The live root is never touched.
function CacheFs:removeStagedTree(stagingCache)
  self:recoverPublication()
  self:_removeTreeAt(stagingCache:resolve(""))
  local liveRoot = self:resolve("")
  local oldRoot = siblingPath(liveRoot, OLD_SUFFIX)
  if self.backend:getInfo(liveRoot) then
    self:_removeTreeAt(oldRoot)
  end
  return true
end

local function renamePath(cacheFs, sourcePath, destinationPath)
  assert(not cacheFs.backend:getInfo(destinationPath), "rename destination must be absent")
  return cacheFs:replaceAt(sourcePath, destinationPath)
end

local function removeCandidates(cacheFs, candidates)
  for _, path in ipairs(candidates) do
    cacheFs:_removeTreeAt(path)
  end
end

local function copyTree(cacheFs, sourcePath, destinationPath)
  local backend = cacheFs.backend
  local info = backend:getInfo(sourcePath)
  if not info then
    Errors.raise(CACHE_ERRORS.FILE_MISSING, "staged root is missing", { path = sourcePath })
  end
  assert(info, "staged root info must be available")
  if info.type == "directory" then
    local ok, err = backend:createDirectory(destinationPath)
    ScopedFs.ensureBackend(ok, err, CACHE_ERRORS.MKDIR_FAILED, "could not create directory", {
      path = destinationPath,
    })
    local items, listErr = backend:getDirectoryItems(sourcePath)
    if not items then
      Errors.raise(CACHE_ERRORS.READ_FAILED, listErr or "could not list directory", { path = sourcePath })
    end
    for _, name in ipairs(items) do
      copyTree(cacheFs, sourcePath .. "/" .. name, destinationPath .. "/" .. name)
    end
    return info.type
  end
  if info.type ~= "file" then
    Errors.raise(CACHE_ERRORS.READ_FAILED, "unsupported staged entry type", {
      path = sourcePath,
      type = info.type,
    })
  end
  local data, readErr = backend:read(sourcePath)
  if data == nil then
    local message = type(readErr) == "string" and readErr or "could not read staged file"
    Errors.raise(CACHE_ERRORS.READ_FAILED, message, { path = sourcePath })
  end
  assert(data, "staged file data must be available")
  local ok, err = backend:write(destinationPath, data)
  ScopedFs.ensureBackend(ok, err, CACHE_ERRORS.WRITE_FAILED, "could not copy staged file", {
    path = destinationPath,
  })
  return info.type
end

local function hasSuffix(path, suffix)
  return path:sub(-#suffix) == suffix
end

local function rootsOverlap(first, second)
  if first == "" or second == "" then
    return true
  end
  return first == second or first:sub(1, #second + 1) == second .. "/" or second:sub(1, #first + 1) == first .. "/"
end

local function validateRoots(cacheFs, stageCache, roots)
  assert(stageCache.versionId == cacheFs.versionId, "publish caches must use the same version")
  local normalizedRoots = {}
  for index, root in ipairs(roots) do
    assert(type(root) == "string", "publish roots must be strings")
    local normalizedRoot = root:gsub("\\", "/")
    assert(not hasSuffix(normalizedRoot, NEXT_SUFFIX), "publish roots may not use the next suffix")
    assert(not hasSuffix(normalizedRoot, OLD_SUFFIX), "publish roots may not use the old suffix")
    cacheFs:resolve(normalizedRoot)
    stageCache:resolve(normalizedRoot)
    for previousIndex = 1, index - 1 do
      assert(not rootsOverlap(normalizedRoot, normalizedRoots[previousIndex]), "publish roots may not overlap")
    end
    normalizedRoots[index] = normalizedRoot
  end
  return normalizedRoots
end

local function rollbackIncomplete(cause, rollback)
  Errors.raise(StorageErrors.CACHE_PUBLISH_ROLLBACK_INCOMPLETE, "publish failed and the rollback was incomplete", {
    cause = tostring(cause),
    rollback = tostring(rollback),
  })
end

local function publicationPath(cacheFs, suffix)
  return cacheFs.versionId .. suffix
end

local function publicationManifestTempPath(cacheFs, attemptId)
  return publicationPath(
    cacheFs,
    PUBLICATION_MANIFEST_TEMP_PREFIX .. attemptId .. PUBLICATION_MANIFEST_TEMP_ATTEMPT_SUFFIX
  )
end

local function isSafeAttemptId(attemptId)
  return type(attemptId) == "string" and attemptId ~= "" and attemptId:match("^[%w%-_]+$") ~= nil
end

local function attemptRootPath(cacheFs, root, suffix, attemptId)
  local livePath = cacheFs:resolve(root)
  return siblingPath(livePath, suffix .. "." .. attemptId)
end

local function candidateRootPath(cacheFs, root, attemptId)
  if root == "" then
    return siblingPath(cacheFs:resolve(""), NEXT_SUFFIX)
  end
  return attemptRootPath(cacheFs, root, NEXT_SUFFIX, attemptId)
end

local function legacyRootPath(cacheFs, root, suffix)
  return siblingPath(cacheFs:resolve(root), suffix)
end

local function rootScratchPaths(cacheFs, manifest, entry)
  if manifest.schema == PUBLICATION_SCHEMA then
    return candidateRootPath(cacheFs, entry.path, manifest.attemptId),
      attemptRootPath(cacheFs, entry.path, OLD_SUFFIX, manifest.attemptId)
  end
  return legacyRootPath(cacheFs, entry.path, NEXT_SUFFIX), legacyRootPath(cacheFs, entry.path, OLD_SUFFIX)
end

local function manifestTempPath(cacheFs, manifest)
  if manifest.schema == PUBLICATION_SCHEMA then
    return publicationManifestTempPath(cacheFs, manifest.attemptId)
  end
  return publicationPath(cacheFs, PUBLICATION_MANIFEST_TEMP_SUFFIX)
end

local function activeAttempt(cacheFs)
  local versions = activeAttempts[cacheFs.backend]
  return versions and versions[cacheFs.versionId]
end

local function registerAttempt(cacheFs, attemptId)
  assert(not activeAttempt(cacheFs), "a publication is already active for this cache version")
  local versions = activeAttempts[cacheFs.backend]
  if not versions then
    versions = {}
    activeAttempts[cacheFs.backend] = versions
  end
  versions[cacheFs.versionId] = attemptId
end

local function releaseAttempt(cacheFs, attemptId)
  local versions = activeAttempts[cacheFs.backend]
  assert(versions and versions[cacheFs.versionId] == attemptId, "publication attempt ownership changed")
  versions[cacheFs.versionId] = nil
  if next(versions) == nil then
    activeAttempts[cacheFs.backend] = nil
  end
end

local function allocateAttemptId(cacheFs)
  while true do
    nextAttemptNumber = nextAttemptNumber + 1
    local attemptId = "a" .. tostring(nextAttemptNumber)
    if not cacheFs.backend:getInfo(publicationManifestTempPath(cacheFs, attemptId)) then
      return attemptId
    end
  end
end

local function publicationMetadataError(message, context)
  Errors.raise(StorageErrors.CACHE_PUBLISH_ROLLBACK_INCOMPLETE, message, context)
end

local function validateManifestRoot(cacheFs, root, index)
  if type(root) ~= "table" then
    publicationMetadataError("publication manifest root must be a table", { index = index })
  end
  local allowed = { path = true, hadLive = true }
  for key in pairs(root) do
    if not allowed[key] then
      publicationMetadataError("publication manifest root has an unexpected field", { index = index })
    end
  end
  if type(root.path) ~= "string" or root.path:gsub("\\", "/") ~= root.path then
    publicationMetadataError("publication manifest root path is not normalized", { index = index })
  end
  if type(root.hadLive) ~= "boolean" then
    publicationMetadataError("publication manifest root existence is not boolean", { index = index })
  end
  if hasSuffix(root.path, NEXT_SUFFIX) or hasSuffix(root.path, OLD_SUFFIX) then
    publicationMetadataError("publication manifest root uses a reserved suffix", { index = index })
  end
  cacheFs:resolve(root.path)
end

local function validateManifest(cacheFs, manifest)
  if type(manifest) ~= "table" then
    publicationMetadataError("publication manifest must be a table")
  end
  local schema = manifest.schema
  local allowed
  if schema == LEGACY_PUBLICATION_SCHEMA then
    allowed = { schema = true, roots = true }
  elseif schema == PUBLICATION_SCHEMA then
    allowed = { schema = true, attemptId = true, roots = true }
    if not isSafeAttemptId(manifest.attemptId) then
      publicationMetadataError("publication manifest attempt identity is invalid")
    end
  else
    publicationMetadataError("publication manifest schema is invalid")
  end
  for key in pairs(manifest) do
    if not allowed[key] then
      publicationMetadataError("publication manifest has an unexpected field")
    end
  end
  if type(manifest.roots) ~= "table" or #manifest.roots < 1 then
    publicationMetadataError("publication manifest schema is invalid")
  end
  local seen = {}
  local count = 0
  for key in pairs(manifest.roots) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
      publicationMetadataError("publication manifest roots must be an ordered array")
    end
    count = count + 1
  end
  if count ~= #manifest.roots then
    publicationMetadataError("publication manifest roots must be contiguous")
  end
  for index, root in ipairs(manifest.roots) do
    validateManifestRoot(cacheFs, root, index)
    if seen[root.path] then
      publicationMetadataError("publication manifest roots must be unique", { path = root.path })
    end
    for previousIndex = 1, index - 1 do
      if rootsOverlap(root.path, manifest.roots[previousIndex].path) then
        publicationMetadataError("publication manifest roots may not overlap", { path = root.path })
      end
    end
    seen[root.path] = true
  end
end

local function readPublicationManifestAt(cacheFs, path)
  if not cacheFs.backend:getInfo(path) then
    return nil
  end
  local manifest, err = ScopedFs.loadChunk(cacheFs.backend, path, path, CACHE_ERRORS)
  if not manifest then
    if err then
      error(err, 0)
    end
    publicationMetadataError("publication manifest must return a table")
  end
  validateManifest(cacheFs, manifest)
  return manifest
end

local function readPublicationManifest(cacheFs)
  return readPublicationManifestAt(cacheFs, publicationPath(cacheFs, PUBLICATION_MANIFEST_SUFFIX))
end

local function writePublicationManifest(cacheFs, manifest)
  validateManifest(cacheFs, manifest)
  local tempPath = manifestTempPath(cacheFs, manifest)
  local manifestPath = publicationPath(cacheFs, PUBLICATION_MANIFEST_SUFFIX)
  local data = LuaWriter.encode(manifest)
  local ok, err = cacheFs.backend:write(tempPath, data)
  ScopedFs.ensureBackend(ok, err, CACHE_ERRORS.WRITE_FAILED, "could not write publication manifest", {
    path = tempPath,
  })
  renamePath(cacheFs, tempPath, manifestPath)
end

local function writePublicationCommit(cacheFs, manifest)
  local path = publicationPath(cacheFs, PUBLICATION_COMMIT_SUFFIX)
  local content = manifest.schema == PUBLICATION_SCHEMA and PUBLICATION_COMMIT_PREFIX .. manifest.attemptId
    or PUBLICATION_COMMIT_CONTENT
  local ok, err = cacheFs.backend:write(path, content)
  return ScopedFs.ensureBackend(ok, err, CACHE_ERRORS.WRITE_FAILED, "could not write publication commit marker", {
    path = path,
  })
end

local function removeNextRoots(cacheFs, manifest, preservedNextPath)
  for _, entry in ipairs(manifest.roots) do
    local nextPath = rootScratchPaths(cacheFs, manifest, entry)
    if nextPath ~= preservedNextPath then
      cacheFs:_removeTreeAt(nextPath)
    end
  end
end

local function validateRecoveryState(cacheFs, manifest, committed)
  for _, entry in ipairs(manifest.roots) do
    local livePath = cacheFs:resolve(entry.path)
    local _, oldPath = rootScratchPaths(cacheFs, manifest, entry)
    local liveExists = cacheFs.backend:getInfo(livePath) ~= nil
    local oldExists = cacheFs.backend:getInfo(oldPath) ~= nil
    if oldExists and not entry.hadLive then
      publicationMetadataError("publication state contradicts the original root set", { path = entry.path })
    end
    if committed and not liveExists then
      publicationMetadataError("committed publication root is missing", { path = entry.path })
    end
    if not committed and entry.hadLive and not liveExists and not oldExists then
      rollbackIncomplete("original live root is missing", "no backup is available for " .. entry.path)
    end
  end
end

local function rollbackPublication(cacheFs, manifest, preservedNextPath)
  validateRecoveryState(cacheFs, manifest, false)
  for index = #manifest.roots, 1, -1 do
    local entry = manifest.roots[index]
    local livePath = cacheFs:resolve(entry.path)
    local nextPath, oldPath = rootScratchPaths(cacheFs, manifest, entry)
    if entry.hadLive then
      if cacheFs.backend:getInfo(oldPath) then
        if cacheFs.backend:getInfo(livePath) then
          if nextPath == preservedNextPath then
            renamePath(cacheFs, livePath, nextPath)
          else
            cacheFs:_removeTreeAt(livePath)
          end
        end
        renamePath(cacheFs, oldPath, livePath)
      end
    elseif cacheFs.backend:getInfo(livePath) then
      if nextPath == preservedNextPath then
        renamePath(cacheFs, livePath, nextPath)
      else
        cacheFs:_removeTreeAt(livePath)
      end
    end
  end
  removeNextRoots(cacheFs, manifest, preservedNextPath)
  cacheFs:_removeTreeAt(manifestTempPath(cacheFs, manifest))
  cacheFs:_removeTreeAt(publicationPath(cacheFs, PUBLICATION_MANIFEST_SUFFIX))
  return true
end

local function finishCommittedPublication(cacheFs, manifest)
  validateRecoveryState(cacheFs, manifest, true)
  for _, entry in ipairs(manifest.roots) do
    local _, oldPath = rootScratchPaths(cacheFs, manifest, entry)
    cacheFs:_removeTreeAt(oldPath)
  end
  removeNextRoots(cacheFs, manifest)
  cacheFs:_removeTreeAt(manifestTempPath(cacheFs, manifest))
  cacheFs:_removeTreeAt(publicationPath(cacheFs, PUBLICATION_MANIFEST_SUFFIX))
  cacheFs:_removeTreeAt(publicationPath(cacheFs, PUBLICATION_COMMIT_SUFFIX))
  return true
end

local function validatePublicationCommit(cacheFs, manifest)
  if manifest.schema == LEGACY_PUBLICATION_SCHEMA then
    return true
  end
  local path = publicationPath(cacheFs, PUBLICATION_COMMIT_SUFFIX)
  local content, err = cacheFs.backend:read(path)
  if content == nil then
    publicationMetadataError("publication commit marker could not be read", { path = path, cause = tostring(err) })
  end
  if content ~= PUBLICATION_COMMIT_PREFIX .. manifest.attemptId then
    publicationMetadataError("publication commit marker does not match the publication manifest", { path = path })
  end
  return true
end

local function recoverOrphanManifestTemps(cacheFs)
  local items, err = cacheFs.backend:getDirectoryItems("")
  if items == nil then
    Errors.raise(CACHE_ERRORS.READ_FAILED, err or "could not list publication metadata", { path = "" })
  end
  assert(items, "publication metadata directory listing must be available")
  local prefix = cacheFs.versionId .. PUBLICATION_MANIFEST_TEMP_PREFIX
  local suffix = PUBLICATION_MANIFEST_TEMP_ATTEMPT_SUFFIX
  for _, name in ipairs(items) do
    if name == cacheFs.versionId .. PUBLICATION_MANIFEST_TEMP_SUFFIX then
      cacheFs:_removeTreeAt(name)
    elseif name:sub(1, #prefix) == prefix and name:sub(-#suffix) == suffix then
      local attemptId = name:sub(#prefix + 1, -#suffix - 1)
      if isSafeAttemptId(attemptId) then
        local tempPath = publicationPath(cacheFs, PUBLICATION_MANIFEST_TEMP_PREFIX .. attemptId .. suffix)
        local manifest = readPublicationManifestAt(cacheFs, tempPath)
        if not manifest or manifest.schema ~= PUBLICATION_SCHEMA or manifest.attemptId ~= attemptId then
          publicationMetadataError("publication temp manifest identity is invalid", { path = tempPath })
        end
        assert(manifest, "validated publication temp manifest must be available")
        local roots = manifest.roots
        assert(type(roots) == "table", "validated publication manifest roots must be a table")
        for _, entry in ipairs(roots) do
          if entry.path ~= "" then
            local nextPath = rootScratchPaths(cacheFs, manifest, entry)
            cacheFs:_removeTreeAt(nextPath)
          end
        end
        cacheFs:_removeTreeAt(tempPath)
      end
    end
  end
end

local function recoverPublicationState(cacheFs, preservedNextPath)
  local manifest = readPublicationManifest(cacheFs)
  local commitPath = publicationPath(cacheFs, PUBLICATION_COMMIT_SUFFIX)
  local hasCommit = cacheFs.backend:getInfo(commitPath) ~= nil
  if not manifest then
    recoverOrphanManifestTemps(cacheFs)
    if hasCommit then
      cacheFs:_removeTreeAt(commitPath)
    end
    return true
  end
  if hasCommit then
    validatePublicationCommit(cacheFs, manifest)
    return finishCommittedPublication(cacheFs, manifest)
  end
  return rollbackPublication(cacheFs, manifest, preservedNextPath)
end

function CacheFs:recoverPublication()
  if activeAttempt(self) then
    return true
  end
  return recoverPublicationState(self, nil)
end

-- Prepare adjacent next siblings, then perform same-parent move-aside and
-- move-in transitions. The caller's root order is preserved so completion
-- markers remain the final publication step.
---@param cacheFs CacheFs
---@param stageCache CacheFs
---@param roots string[]
---@param cleanup fun()
---@return boolean
local function publishStagedRoots(cacheFs, stageCache, roots, cleanup)
  local normalizedRoots = validateRoots(cacheFs, stageCache, roots)
  cacheFs:recoverPublication()
  local attemptId = allocateAttemptId(cacheFs)
  registerAttempt(cacheFs, attemptId)

  local ok, result = pcall(function()
    local manifest = { schema = PUBLICATION_SCHEMA, attemptId = attemptId, roots = {} }
    local candidates = {}
    local candidateOk, candidateErr = pcall(function()
      for _, root in ipairs(normalizedRoots) do
        local sourcePath = stageCache:resolve(root)
        local sourceInfo = stageCache.backend:getInfo(sourcePath)
        if not sourceInfo then
          Errors.raise(CACHE_ERRORS.FILE_MISSING, "staged root is missing", { path = sourcePath })
        end
        assert(sourceInfo, "staged root info must be available")
        local nextPath = candidateRootPath(cacheFs, root, attemptId)
        if sourcePath ~= nextPath then
          candidates[#candidates + 1] = nextPath
          if cacheFs.backend:getInfo(nextPath) then
            cacheFs:_removeTreeAt(nextPath)
          end
          copyTree(cacheFs, sourcePath, nextPath)
        end
        local candidateInfo = cacheFs.backend:getInfo(nextPath)
        assert(candidateInfo, "staged candidate info must be available")
        assert(candidateInfo.type == sourceInfo.type, "staged candidate type changed")
        manifest.roots[#manifest.roots + 1] = {
          path = root,
          hadLive = cacheFs.backend:getInfo(cacheFs:resolve(root)) ~= nil,
        }
      end
    end)
    if not candidateOk then
      local cleanupOk, cleanupErr = pcall(function()
        removeCandidates(cacheFs, candidates)
      end)
      if not cleanupOk then
        rollbackIncomplete(candidateErr, cleanupErr)
      end
      error(candidateErr, 0)
    end

    local manifestOk, manifestErr = pcall(writePublicationManifest, cacheFs, manifest)
    if not manifestOk then
      local cleanupOk, cleanupErr = pcall(function()
        removeCandidates(cacheFs, candidates)
        cacheFs:_removeTreeAt(manifestTempPath(cacheFs, manifest))
      end)
      if not cleanupOk then
        rollbackIncomplete(manifestErr, cleanupErr)
      end
      error(manifestErr, 0)
    end

    local phase1Ok, phase1Err = pcall(function()
      for _, entry in ipairs(manifest.roots) do
        if entry.hadLive then
          local _, oldPath = rootScratchPaths(cacheFs, manifest, entry)
          renamePath(cacheFs, cacheFs:resolve(entry.path), oldPath)
        end
      end
    end)
    if not phase1Ok then
      local rollbackOk, rollbackErr = pcall(rollbackPublication, cacheFs, manifest, stageCache:resolve(""))
      if not rollbackOk then
        rollbackIncomplete(phase1Err, rollbackErr)
      end
      error(phase1Err, 0)
    end

    -- Phase 2: rename the adjacent candidates into place, in the given order.
    local phase2Ok, phase2Err = pcall(function()
      for _, entry in ipairs(manifest.roots) do
        local nextPath = rootScratchPaths(cacheFs, manifest, entry)
        renamePath(cacheFs, nextPath, cacheFs:resolve(entry.path))
      end
    end)
    if not phase2Ok then
      local rollbackOk, rollbackErr = pcall(rollbackPublication, cacheFs, manifest, stageCache:resolve(""))
      if not rollbackOk then
        rollbackIncomplete(phase2Err, rollbackErr)
      end
      error(phase2Err, 0)
    end

    local commitOk, commitErr = pcall(writePublicationCommit, cacheFs, manifest)
    if not commitOk then
      local rollbackOk, rollbackErr = pcall(rollbackPublication, cacheFs, manifest, stageCache:resolve(""))
      if not rollbackOk then
        rollbackIncomplete(commitErr, rollbackErr)
      end
      error(commitErr, 0)
    end

    -- The new artifact is already live; cleanup is a distinct outcome, never a
    -- failed publication. The journal remains until every cleanup step succeeds.
    local cleanupOk, cleanupErr = pcall(function()
      finishCommittedPublication(cacheFs, manifest)
      cleanup()
    end)
    if not cleanupOk then
      Errors.raise(
        StorageErrors.CACHE_PUBLISH_CLEANUP_FAILED,
        "the new artifact is live but its stage could not be removed",
        {
          cause = tostring(cleanupErr),
        }
      )
    end
    return true
  end)

  releaseAttempt(cacheFs, attemptId)
  if not ok then
    error(result, 0)
  end
  return result
end

-- Publish a set of staged roots (cache-relative paths mirrored under
-- `stageCache`) over the same live roots, with the shared move-aside /
-- move-in / rollback lifecycle. `cleanup` discards the recovery material once
-- every staged root is live. ArtifactPublisher uses this for per-artifact
-- staged publication; publishFromStage wraps it for the whole-version root.
-- The failure outcomes are those of the shared lifecycle.
function CacheFs:publishStaged(stageCache, roots, cleanup)
  assert(stageCache and stageCache.versionId, "publishStaged requires a staging CacheFs")
  assert(type(roots) == "table" and #roots >= 1, "publishStaged requires at least one root")
  assert(type(cleanup) == "function", "publishStaged requires a cleanup function")
  return publishStagedRoots(self, stageCache, roots, cleanup)
end

-- Publish a completed whole-version tree. Its staging root is already the
-- adjacent next sibling, so publication only moves that sibling into the live
-- root after moving any previous root to its adjacent old sibling.
function CacheFs:publishFromStage(stagingCache)
  return self:publishStaged(stagingCache, { "" }, function()
    stagingCache:_removeTreeAt(stagingCache:resolve(""))
  end)
end

function CacheFs:writeLua(relativePath, value)
  return self:write(relativePath, LuaWriter.encode(value))
end

-- Loads a generated/checked-in Lua data file in an empty environment. Must
-- never be pointed at raw ROM file contents.
function CacheFs:loadLua(relativePath)
  return ScopedFs.loadChunk(self.backend, self:resolve(relativePath), relativePath, CACHE_ERRORS)
end

-- The one module a generated chunk may require: the gen4 script DSL emitted
-- by the script cache generator. Mirrors ScriptLoader's resource-loader
-- allowlist; anything wider would let generated cache content reach (and
-- corrupt) process-wide package state.
local ALLOWED_MODULES = { ["gen4.script"] = true }

local function moduleRequire(name)
  assert(ALLOWED_MODULES[name], "generated modules may only require gen4.script")
  return require(name)
end

-- Loads a generated Lua module (a file that `require`s other modules) in an
-- environment whose only entry is a require restricted to the gen4.script
-- allowlist. Used by the script-cache readback and by runtime loaders that
-- consume generated DSL modules. Must never be pointed at raw ROM file
-- contents. A module requiring outside the allowlist fails to load.
function CacheFs:loadModule(relativePath)
  return ScopedFs.loadChunk(self.backend, self:resolve(relativePath), relativePath, CACHE_ERRORS, {
    require = moduleRequire,
  })
end

return CacheFs
