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
---@field publishStaged fun(self: CacheFs, stageCache: CacheFs, roots: string[], cleanup: fun()): boolean
---@field publishFromStage fun(self: CacheFs, stagingCache: CacheFs): boolean
---@field writeLua fun(self: CacheFs, relativePath: string, value: table<string, unknown>): boolean
---@field loadLua fun(self: CacheFs, relativePath: string): table<string, unknown>?, Errors.Error?
local CacheFs = {}
CacheFs.__index = CacheFs

local NEXT_SUFFIX = ".__g4next"
local OLD_SUFFIX = ".__g4old"

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

-- Discard every staged output for this version and any orphaned previous root a
-- crash mid-publish left behind. Staging is disposable generated data; a fresh
-- extraction rebuilds it from the validated ROM. The live root is never touched.
function CacheFs:removeStagedTree(stagingCache)
  self:_removeTreeAt(stagingCache:resolve(""))
  self:_removeTreeAt(siblingPath(self:resolve(""), OLD_SUFFIX))
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
  for index, root in ipairs(roots) do
    assert(type(root) == "string", "publish roots must be strings")
    assert(not hasSuffix(root, NEXT_SUFFIX), "publish roots may not use the next suffix")
    assert(not hasSuffix(root, OLD_SUFFIX), "publish roots may not use the old suffix")
    cacheFs:resolve(root)
    stageCache:resolve(root)
    for previousIndex = 1, index - 1 do
      assert(not rootsOverlap(root, roots[previousIndex]), "publish roots may not overlap")
    end
  end
end

local function recoverTransientRoots(cacheFs, stageCache, roots)
  local states = {}
  local allLive = true
  local anyOld = false
  for _, root in ipairs(roots) do
    local livePath = cacheFs:resolve(root)
    local oldPath = siblingPath(livePath, OLD_SUFFIX)
    local liveExists = cacheFs.backend:getInfo(livePath) ~= nil
    local oldExists = cacheFs.backend:getInfo(oldPath) ~= nil
    states[root] = { livePath = livePath, oldPath = oldPath, liveExists = liveExists, oldExists = oldExists }
    allLive = allLive and liveExists
    anyOld = anyOld or oldExists
  end

  if anyOld then
    if allLive then
      for _, root in ipairs(roots) do
        local state = states[root]
        if state.oldExists then
          cacheFs:_removeTreeAt(state.oldPath)
        end
      end
    else
      for _, root in ipairs(roots) do
        local state = states[root]
        if state.liveExists then
          cacheFs:_removeTreeAt(state.livePath)
        end
      end
      for _, root in ipairs(roots) do
        local state = states[root]
        if state.oldExists then
          renamePath(cacheFs, state.oldPath, state.livePath)
        end
      end
    end
  end

  for _, root in ipairs(roots) do
    local state = states[root]
    local nextPath = siblingPath(state.livePath, NEXT_SUFFIX)
    if nextPath ~= stageCache:resolve(root) and cacheFs.backend:getInfo(nextPath) then
      cacheFs:_removeTreeAt(nextPath)
    end
  end
end

local function rollbackAsides(cacheFs, roots, asides)
  local firstError
  for index = #roots, 1, -1 do
    local root = roots[index]
    if asides[root] then
      local livePath = cacheFs:resolve(root)
      local oldPath = siblingPath(livePath, OLD_SUFFIX)
      local ok, err = pcall(renamePath, cacheFs, oldPath, livePath)
      if not ok and firstError == nil then
        firstError = err
      end
    end
  end
  return firstError
end

local function rollbackPublished(cacheFs, movedIn, roots, asides)
  local firstError
  for index = #movedIn, 1, -1 do
    local root = movedIn[index]
    local livePath = cacheFs:resolve(root)
    local nextPath = siblingPath(livePath, NEXT_SUFFIX)
    local ok, err = pcall(renamePath, cacheFs, livePath, nextPath)
    if not ok and firstError == nil then
      firstError = err
    end
  end
  local asideErr = rollbackAsides(cacheFs, roots, asides)
  if firstError == nil then
    firstError = asideErr
  end
  return firstError
end

local function rollbackIncomplete(cause, rollback)
  Errors.raise(StorageErrors.CACHE_PUBLISH_ROLLBACK_INCOMPLETE, "publish failed and the rollback was incomplete", {
    cause = tostring(cause),
    rollback = tostring(rollback),
  })
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
  validateRoots(cacheFs, stageCache, roots)
  recoverTransientRoots(cacheFs, stageCache, roots)

  local candidates = {}
  local candidateOk, candidateErr = pcall(function()
    for _, root in ipairs(roots) do
      local livePath = cacheFs:resolve(root)
      local nextPath = siblingPath(livePath, NEXT_SUFFIX)
      local sourcePath = stageCache:resolve(root)
      local sourceInfo = stageCache.backend:getInfo(sourcePath)
      if not sourceInfo then
        Errors.raise(CACHE_ERRORS.FILE_MISSING, "staged root is missing", { path = sourcePath })
      end
      assert(sourceInfo, "staged root info must be available")
      if sourcePath ~= nextPath then
        candidates[#candidates + 1] = nextPath
        copyTree(cacheFs, sourcePath, nextPath)
      end
      local candidateInfo = cacheFs.backend:getInfo(nextPath)
      assert(candidateInfo, "staged candidate info must be available")
      assert(candidateInfo.type == sourceInfo.type, "staged candidate type changed")
    end
  end)
  if not candidateOk then
    local cleanupOk, cleanupErr = pcall(removeCandidates, cacheFs, candidates)
    if not cleanupOk then
      rollbackIncomplete(candidateErr, cleanupErr)
    end
    error(candidateErr, 0)
  end

  -- Phase 1: move every existing live root aside. A failure rolls back every
  -- aside already made and re-raises.
  local asides = {}
  local phase1Ok, phase1Err = pcall(function()
    for _, root in ipairs(roots) do
      local livePath = cacheFs:resolve(root)
      if cacheFs:exists(root) then
        renamePath(cacheFs, livePath, siblingPath(livePath, OLD_SUFFIX))
        asides[root] = true
      end
    end
  end)
  if not phase1Ok then
    local rollbackErr = rollbackAsides(cacheFs, roots, asides)
    if rollbackErr ~= nil then
      rollbackIncomplete(phase1Err, rollbackErr)
    end
    local cleanupOk, cleanupErr = pcall(removeCandidates, cacheFs, candidates)
    if not cleanupOk then
      rollbackIncomplete(phase1Err, cleanupErr)
    end
    error(phase1Err, 0)
  end

  -- Phase 2: rename the adjacent candidates into place, in the given order.
  local movedIn = {}
  local phase2Ok, phase2Err = pcall(function()
    for _, root in ipairs(roots) do
      local livePath = cacheFs:resolve(root)
      renamePath(cacheFs, siblingPath(livePath, NEXT_SUFFIX), livePath)
      movedIn[#movedIn + 1] = root
    end
  end)
  if not phase2Ok then
    local rollbackErr = rollbackPublished(cacheFs, movedIn, roots, asides)
    if rollbackErr ~= nil then
      rollbackIncomplete(phase2Err, rollbackErr)
    end
    local cleanupOk, cleanupErr = pcall(removeCandidates, cacheFs, candidates)
    if not cleanupOk then
      rollbackIncomplete(phase2Err, cleanupErr)
    end
    error(phase2Err, 0)
  end

  -- Phase 3: discard recovery material. The new artifact is already live; a
  -- failing cleanup is a distinct outcome, never a failed publication.
  local cleanupOk, cleanupErr = pcall(function()
    for _, root in ipairs(roots) do
      local livePath = cacheFs:resolve(root)
      cacheFs:_removeTreeAt(siblingPath(livePath, OLD_SUFFIX))
    end
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
