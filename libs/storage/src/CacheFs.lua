-- Version-scoped private cache. Every path is normalized and confined below the
-- version prefix; absolute paths, drive letters, NUL, and "."/".." components
-- are rejected so no operation can escape its version subtree. Roots are
-- structural (`<versionId>/`, `staging/<versionId>/`): a version id is any safe
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
---@field write fun(self: CacheFs, relativePath: string, data: string): boolean
---@field read fun(self: CacheFs, relativePath: string): string?
---@field getInfo fun(self: CacheFs, relativePath: string): table<string, unknown>?
---@field exists fun(self: CacheFs, relativePath: string, expectedType?: string): boolean
---@field createDirectory fun(self: CacheFs, relativePath: string): boolean
---@field remove fun(self: CacheFs, relativePath: string): boolean
---@field replace fun(self: CacheFs, sourceRelativePath: string, destinationRelativePath: string): boolean
---@field replaceAt fun(self: CacheFs, sourcePath: string, destinationPath: string): boolean
---@field removeTree fun(self: CacheFs, relativePath: string): boolean
---@field removeStagedTree fun(self: CacheFs, stagingCache: CacheFs): boolean
---@field publishStaged fun(self: CacheFs, stageCache: CacheFs, roots: string[], cleanup: fun()): boolean
---@field publishFromStage fun(self: CacheFs, stagingCache: CacheFs): boolean
---@field writeLua fun(self: CacheFs, relativePath: string, value: table<string, unknown>): boolean
---@field loadLua fun(self: CacheFs, relativePath: string): table<string, unknown>?, Errors.Error?
local CacheFs = {}
CacheFs.__index = CacheFs

-- The sibling path a completed live root is moved to before a staged tree is
-- renamed into place; a crash between the two renames leaves the previous dump
-- here for removeStagedTree to discard at the next import. The shared
-- move-aside / move-in / rollback lifecycle (publishStagedRoots) uses the same
-- suffix for whole-version asides (`staging/<versionId>.old`) and for
-- per-artifact asides inside an artifact stage.
CacheFs.STAGING_OLD_SUFFIX = ".old"

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

-- A CacheFs rooted at the disposable `staging/<versionId>/` namespace, a
-- sibling of the live version root. A completed staging tree is published over
-- the live root with publishFromStage; stale staging is discarded at the next
-- import.
---@param versionId string
---@param backend table<string, unknown>|nil
---@return CacheFs
function CacheFs.forStaging(versionId, backend)
  ScopedFs.validateVersionId(versionId)
  local prefix = "staging/" .. versionId .. "/"
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

-- Discard every staged output for this version: the staging root and any
-- orphaned previous root (`staging/<versionId>.old`) a crash mid-publish left
-- behind. Staging is disposable generated data; a fresh extraction rebuilds it
-- from the validated ROM. The live root is never touched.
function CacheFs:removeStagedTree(stagingCache)
  self:_removeTreeAt(stagingCache:resolve(""))
  self:_removeTreeAt(stagingCache:resolve("") .. CacheFs.STAGING_OLD_SUFFIX)
  return true
end

-- Restore every aside a failed publish left behind, using the checked rename
-- path (a falsy backend result becomes CACHE_REPLACE_FAILED). Returns the
-- first rollback error, or nil when every aside was restored.
---@param cacheFs CacheFs
---@param stageCache CacheFs
---@param roots string[]
---@param asides table<string, boolean>
---@return unknown|nil
local function rollbackAsides(cacheFs, stageCache, roots, asides)
  local firstError
  for _, root in ipairs(roots) do
    if asides[root] then
      local ok, err =
        pcall(cacheFs.replaceAt, cacheFs, stageCache:resolve(root) .. CacheFs.STAGING_OLD_SUFFIX, cacheFs:resolve(root))
      if not ok and firstError == nil then
        firstError = err
      end
    end
  end
  return firstError
end

-- Restore the already-published roots back to the stage, then every aside
-- root, with the checked rename path. Returns the first rollback error, or
-- nil when the previous artifact was fully restored.
---@param cacheFs CacheFs
---@param stageCache CacheFs
---@param movedIn string[]
---@param roots string[]
---@param asides table<string, boolean>
---@return unknown|nil
local function rollbackPublished(cacheFs, stageCache, movedIn, roots, asides)
  local firstError
  for index = #movedIn, 1, -1 do
    local root = movedIn[index]
    local ok, err = pcall(cacheFs.replaceAt, cacheFs, cacheFs:resolve(root), stageCache:resolve(root))
    if not ok and firstError == nil then
      firstError = err
    end
  end
  local asideErr = rollbackAsides(cacheFs, stageCache, roots, asides)
  if firstError == nil then
    firstError = asideErr
  end
  return firstError
end

-- One move-aside / move-in / rollback lifecycle shared by whole-version
-- publication (publishFromStage) and per-artifact publication
-- (ArtifactPublisher). `roots` are the cache-relative roots to swap; every
-- existing live root is first moved aside to its staged-root `.old` sibling,
-- then the staged roots are renamed into place in order (the marker root
-- last), and `cleanup` (which may assume every staged root is live) discards
-- the recovery material. A failed rename restores every root already moved;
-- if the rollback itself fails, all remaining recovery material is preserved
-- and CACHE_PUBLISH_ROLLBACK_INCOMPLETE raises with both failures. `cleanup`
-- failing raises CACHE_PUBLISH_CLEANUP_FAILED: the new artifact is already
-- live and must not be rolled back.
---@param cacheFs CacheFs
---@param stageCache CacheFs
---@param roots string[]
---@param cleanup fun()
---@return boolean
local function publishStagedRoots(cacheFs, stageCache, roots, cleanup)
  -- Phase 1: move every existing live root aside. A failure (backend raise or
  -- backend-reported failure, which replaceAt translates into
  -- CACHE_REPLACE_FAILED) rolls back every aside already made and re-raises.
  local asides = {}
  local phase1Ok, phase1Err = pcall(function()
    for _, root in ipairs(roots) do
      if cacheFs:exists(root, "directory") then
        cacheFs:replaceAt(cacheFs:resolve(root), stageCache:resolve(root) .. CacheFs.STAGING_OLD_SUFFIX)
        asides[root] = true
      end
    end
  end)
  if not phase1Ok then
    local rollbackErr = rollbackAsides(cacheFs, stageCache, roots, asides)
    if rollbackErr ~= nil then
      Errors.raise(StorageErrors.CACHE_PUBLISH_ROLLBACK_INCOMPLETE, "publish failed and the rollback was incomplete", {
        cause = tostring(phase1Err),
        rollback = tostring(rollbackErr),
      })
    end
    error(phase1Err, 0)
  end
  -- Phase 2: rename the staged roots into place, in the given order (the
  -- marker root last).
  local movedIn = {}
  local phase2Ok, phase2Err = pcall(function()
    for _, root in ipairs(roots) do
      cacheFs:replaceAt(stageCache:resolve(root), cacheFs:resolve(root))
      movedIn[#movedIn + 1] = root
    end
  end)
  if not phase2Ok then
    local rollbackErr = rollbackPublished(cacheFs, stageCache, movedIn, roots, asides)
    if rollbackErr ~= nil then
      Errors.raise(StorageErrors.CACHE_PUBLISH_ROLLBACK_INCOMPLETE, "publish failed and the rollback was incomplete", {
        cause = tostring(phase2Err),
        rollback = tostring(rollbackErr),
      })
    end
    error(phase2Err, 0)
  end
  -- Phase 3: discard the recovery material. The new artifact is already live;
  -- a failing cleanup is a distinct outcome, never a failed publication.
  local cleanupOk, cleanupErr = pcall(cleanup)
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

-- Publish a completed staging tree as the new live version root. The live root
-- is first moved aside to the staging sibling `<stagingRoot>.old`, the staging
-- root is then renamed into place, and only after it lands is the previous root
-- removed. If the staging root cannot land, the previous root is renamed back
-- and the failure re-raised, so a failed publish leaves the prior dump intact;
-- if that rollback also fails, the recovery material stays at `<stagingRoot>
-- .old` and CACHE_PUBLISH_ROLLBACK_INCOMPLETE raises with both failures.
-- Both moves are single backend renames; a process crash between them leaves
-- the previous dump at `<stagingRoot>.old`, which removeStagedTree discards at
-- the next import.
function CacheFs:publishFromStage(stagingCache)
  local oldRoot = stagingCache:resolve("") .. CacheFs.STAGING_OLD_SUFFIX
  self:_removeTreeAt(oldRoot)
  return self:publishStaged(stagingCache, { "" }, function()
    self:_removeTreeAt(oldRoot)
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
