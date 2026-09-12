-- ArtifactPublisher: the shared staging/publication lifecycle for generated
-- cache artifacts. A writer stages every owned file under a disposable staging
-- root, validates the staged result, and only then publishes it; a failure at
-- any point must leave the previous live artifact untouched and readable, with
-- no staging marker ever visible and the stage cleaned.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local LuaWriter = require("libs.codec.src.LuaWriter")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local ConstrainedCache = require("tests.support.ConstrainedCache")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")

local T = {}

local DATA = "data/generated/field/actors"
local ASSET = "assets/generated/field/actors"
local STAGE_ROOT = "staging/heartgold/field-actors"

local function liveRoot(root)
  return "heartgold/" .. root
end

local function hasAttemptRoot(path, root, suffix)
  local prefix = liveRoot(root) .. suffix .. "."
  return path:sub(1, #prefix) == prefix
end

local function findAttemptFile(backend, root, suffix, file)
  for path, data in pairs(backend.files) do
    if hasAttemptRoot(path, root, suffix) and path:sub(-#file) == file then
      return data
    end
  end
  return nil
end

local function oldRoot(root)
  return liveRoot(root) .. ".__g4old"
end

local function cacheWith(backend)
  return CacheFs.forVersion("heartgold", backend or FakeCache.new())
end

local function beginActors(cacheFs)
  return ArtifactPublisher.begin(cacheFs, "field-actors", { DATA, ASSET })
end

local function seedOldArtifact(cacheFs)
  cacheFs:write(DATA .. "/complete", "old-marker")
  cacheFs:write(DATA .. "/index.lua", "old-index")
  cacheFs:write(ASSET .. "/0000.png", "old-png")
end

local function stageNewArtifact(tx)
  tx.stage:write(DATA .. "/complete", "new-marker")
  tx.stage:write(DATA .. "/index.lua", "new-index")
  tx.stage:write(ASSET .. "/0000.png", "new-png")
end

local function assertPortableRenames(backend)
  Assert.isTrue(#backend.renameLog > 0, "publication must use the backend rename seam")
  for _, entry in ipairs(backend.renameLog) do
    Assert.isFalse(entry.destinationExisted, "rename destination must be absent: " .. entry.destination)
    if entry.sourceType == "directory" then
      Assert.equal(
        entry.sourceParent,
        entry.destinationParent,
        "directory rename must stay within one parent: " .. entry.source .. " -> " .. entry.destination
      )
    end
  end
end

function T.staged_writes_never_touch_the_live_tree()
  local cache = cacheWith()
  seedOldArtifact(cache)
  local tx = beginActors(cache)
  tx.stage:write(DATA .. "/complete", "new-marker")
  tx.stage:write(DATA .. "/index.lua", "new-index")
  Assert.equal(cache:read(DATA .. "/complete"), "old-marker", "live tree untouched while staging")
  Assert.equal(cache:read(DATA .. "/index.lua"), "old-index")
  Assert.equal(cache:read(ASSET .. "/0000.png"), "old-png")
  Assert.isTrue(tx.stage:exists(DATA .. "/index.lua", "file"), "staged file is visible in the stage")
  Assert.equal(cache:read(DATA .. "/index.lua"), "old-index", "staged file never leaks into the live tree")
  tx:abort()
end

function T.publish_swaps_every_live_root_and_cleans_the_stage()
  local cache = cacheWith()
  seedOldArtifact(cache)
  local tx = beginActors(cache)
  stageNewArtifact(tx)
  tx:publish()
  Assert.equal(cache:read(DATA .. "/complete"), "new-marker")
  Assert.equal(cache:read(DATA .. "/index.lua"), "new-index")
  Assert.equal(cache:read(ASSET .. "/0000.png"), "new-png")
  Assert.isNil(cache.backend:getInfo(STAGE_ROOT), "stage root removed after a successful publish")
end

function T.publish_works_on_a_first_build_with_no_previous_artifact()
  local cache = cacheWith()
  local tx = beginActors(cache)
  stageNewArtifact(tx)
  tx:publish()
  Assert.equal(cache:read(DATA .. "/complete"), "new-marker")
  Assert.equal(cache:read(ASSET .. "/0000.png"), "new-png")
  Assert.isNil(cache.backend:getInfo(STAGE_ROOT))
end

function T.directory_publication_preserves_contents_and_rolls_back_under_restricted_renames()
  local backend = ConstrainedCache.new()
  local cache = cacheWith(backend)
  local root = "data/generated/field/maps"
  cache:write(root .. "/old.bin", "old")
  cache:createDirectory(root .. "/empty")

  local first = ArtifactPublisher.begin(cache, "field-maps", { root })
  first.stage:write(root .. "/index.lua", "new-index")
  first.stage:write(root .. "/nested/value.bin", "new-value")
  first.stage:createDirectory(root .. "/empty")
  first:publish()

  Assert.equal(cache:read(root .. "/index.lua"), "new-index")
  Assert.equal(cache:read(root .. "/nested/value.bin"), "new-value")
  Assert.notNil(backend:getInfo("heartgold/" .. root .. "/empty"))
  Assert.isNil(backend:getInfo("staging/heartgold/field-maps"))

  local second = ArtifactPublisher.begin(cache, "field-maps", { root })
  second.stage:write(root .. "/index.lua", "replacement-index")
  second.stage:write(root .. "/nested/value.bin", "replacement-value")
  second.stage:createDirectory(root .. "/empty")
  local originalReplace = backend.replace
  local failCandidate = true
  backend.replace = function(self, sourcePath, destinationPath)
    if failCandidate and hasAttemptRoot(sourcePath, root, ".__g4next") then
      failCandidate = false
      return false, "injected rename failure"
    end
    return originalReplace(self, sourcePath, destinationPath)
  end
  local err = Assert.throws(function()
    second:publish()
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "CACHE_REPLACE_FAILED")
  Assert.equal(cache:read(root .. "/index.lua"), "new-index", "failed replacement restores the prior file")
  Assert.equal(cache:read(root .. "/nested/value.bin"), "new-value")
  Assert.notNil(backend:getInfo("heartgold/" .. root .. "/empty"))
  assertPortableRenames(backend)
end

function T.a_staged_write_failure_preserves_the_previous_artifact()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  seedOldArtifact(cache)
  local originalWrite = backend.write
  backend.write = function(self, path, data)
    if path:find("index.lua", 1, true) then
      error("injected write failure")
    end
    return originalWrite(self, path, data)
  end
  local tx = beginActors(cache)
  tx.stage:write(DATA .. "/complete", "new-marker")
  Assert.throws(function()
    tx.stage:write(DATA .. "/index.lua", "new-index")
  end)
  Assert.equal(cache:read(DATA .. "/complete"), "old-marker", "the new marker never reached the live tree")
  Assert.equal(cache:read(DATA .. "/index.lua"), "old-index", "previous artifact remains ready")
  tx:abort()
  Assert.isNil(cache.backend:getInfo(STAGE_ROOT), "abort cleans the stage")
  Assert.equal(cache:read(DATA .. "/complete"), "old-marker", "abort leaves the previous artifact untouched")
end

function T.abort_cleans_the_stage_and_leaves_the_live_tree_untouched()
  local cache = cacheWith()
  seedOldArtifact(cache)
  local tx = beginActors(cache)
  stageNewArtifact(tx)
  tx:abort()
  Assert.equal(cache:read(DATA .. "/complete"), "old-marker")
  Assert.equal(cache:read(ASSET .. "/0000.png"), "old-png")
  Assert.isNil(cache.backend:getInfo(STAGE_ROOT), "stage root removed by abort")
end

function T.begin_removes_stale_stage_from_a_previous_attempt()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  backend:write(STAGE_ROOT .. "/" .. DATA .. "/complete", "stale-marker")
  backend:write(STAGE_ROOT .. "/" .. ASSET .. "/0000.png", "stale-png")
  backend:write(STAGE_ROOT .. "/" .. DATA .. ".old/index.lua", "orphaned-old")
  local tx = beginActors(cache)
  Assert.isNil(tx.stage:read(DATA .. "/complete"), "stale staged marker is gone")
  Assert.isNil(tx.stage:read(ASSET .. "/0000.png"), "stale staged file is gone")
  Assert.isNil(tx.stage:read(DATA .. ".old/index.lua"), "orphaned old root is gone")
  tx:abort()
end

function T.a_failed_publish_rolls_back_every_moved_root()
  local backend = FakeCache.new()
  local originalReplace = backend.replace
  backend.replace = function(self, sourcePath, destinationPath)
    -- Fail only the stage -> live rename of the second root; the rollback
    -- renames (which carry the ".old" suffix) must still succeed.
    if hasAttemptRoot(sourcePath, ASSET, ".__g4next") then
      error("injected replace failure")
    end
    return originalReplace(self, sourcePath, destinationPath)
  end
  local cache = CacheFs.forVersion("heartgold", backend)
  seedOldArtifact(cache)
  local tx = beginActors(cache)
  stageNewArtifact(tx)
  Assert.throws(function()
    tx:publish()
  end)
  Assert.equal(cache:read(DATA .. "/complete"), "old-marker", "first root restored after the failed publish")
  Assert.equal(cache:read(DATA .. "/index.lua"), "old-index")
  Assert.equal(cache:read(ASSET .. "/0000.png"), "old-png", "second root never left the stage")
end

function T.publish_restores_the_previous_artifact_when_an_aside_rename_fails()
  local backend = FakeCache.new()
  local originalReplace = backend.replace
  backend.replace = function(self, sourcePath, destinationPath)
    -- Fail the aside of the second root, after the first root was already
    -- moved aside; publish must roll the first aside back.
    if sourcePath == "heartgold/" .. ASSET then
      error("injected replace failure")
    end
    return originalReplace(self, sourcePath, destinationPath)
  end
  local cache = CacheFs.forVersion("heartgold", backend)
  seedOldArtifact(cache)
  local tx = beginActors(cache)
  stageNewArtifact(tx)
  Assert.throws(function()
    tx:publish()
  end)
  Assert.equal(cache:read(DATA .. "/complete"), "old-marker", "aside of the first root rolled back")
  Assert.equal(cache:read(ASSET .. "/0000.png"), "old-png")
end

function T.rejects_an_invalid_artifact_name()
  local cache = cacheWith()
  Assert.throws(function()
    ArtifactPublisher.begin(cache, "a/b", { DATA })
  end, "a name with a path separator must be rejected")
  Assert.throws(function()
    ArtifactPublisher.begin(cache, "..", { DATA })
  end, "a parent-traversal name must be rejected")
end

function T.rejects_an_empty_or_duplicate_root_list()
  local cache = cacheWith()
  Assert.throws(function()
    ArtifactPublisher.begin(cache, "field-actors", {})
  end)
  Assert.throws(function()
    ArtifactPublisher.begin(cache, "field-actors", { DATA, DATA })
  end)
end

-- A backend-reported failure (falsy return, not a raise) during any
-- publication rename must abort the publish; publication can never report
-- success when a rename failed.
function T.publish_cannot_report_success_when_a_rename_reports_failure()
  local backend = FakeCache.new()
  backend.replace = function(self, sourcePath, destinationPath)
    -- Report failure only for the stage -> live rename of the second root;
    -- the rollback renames (which carry the ".old" suffix) must still succeed.
    if hasAttemptRoot(sourcePath, ASSET, ".__g4next") then
      return false, "injected replace failure"
    end
    return FakeCache.replace(self, sourcePath, destinationPath)
  end
  local cache = CacheFs.forVersion("heartgold", backend)
  seedOldArtifact(cache)
  local tx = beginActors(cache)
  stageNewArtifact(tx)
  local err = Assert.throws(function()
    tx:publish()
  end)
  Assert.isTrue(Errors.is(err), "a backend-reported failure must surface as a structured error")
  Assert.equal(err.code, "CACHE_REPLACE_FAILED")
  Assert.equal(cache:read(DATA .. "/complete"), "old-marker", "previous artifact restored")
  Assert.equal(cache:read(DATA .. "/index.lua"), "old-index")
  Assert.equal(cache:read(ASSET .. "/0000.png"), "old-png")
end

function T.publish_reports_an_aside_failure_instead_of_success()
  local backend = FakeCache.new()
  backend.replace = function(self, sourcePath, destinationPath)
    -- Fail the aside of the second root, after the first root was already
    -- moved aside; publish must roll the first aside back.
    if sourcePath == "heartgold/" .. ASSET then
      return false, "injected aside failure"
    end
    return FakeCache.replace(self, sourcePath, destinationPath)
  end
  local cache = CacheFs.forVersion("heartgold", backend)
  seedOldArtifact(cache)
  local tx = beginActors(cache)
  stageNewArtifact(tx)
  local err = Assert.throws(function()
    tx:publish()
  end)
  Assert.isTrue(Errors.is(err), "a backend-reported aside failure must surface as a structured error")
  Assert.equal(err.code, "CACHE_REPLACE_FAILED")
  Assert.equal(cache:read(DATA .. "/complete"), "old-marker", "aside of the first root rolled back")
  Assert.equal(cache:read(ASSET .. "/0000.png"), "old-png")
end

-- A rollback rename that reports failure must surface as an incomplete
-- rollback: publish may never claim the previous artifact was restored when a
-- checked rollback rename failed, and the aside root (the remaining copy of
-- the last-known-good artifact) must stay in the stage as recovery material.
function T.publish_reports_an_incomplete_rollback_when_a_rollback_rename_fails()
  local backend = FakeCache.new()
  backend.replace = function(self, sourcePath, destinationPath)
    -- Fail the stage -> live rename of the second root AND the aside restore
    -- of the first root (stage .old -> live), so the rollback cannot restore
    -- the first root.
    if hasAttemptRoot(sourcePath, ASSET, ".__g4next") then
      return false, "injected replace failure"
    end
    if hasAttemptRoot(sourcePath, DATA, ".__g4old") then
      return false, "injected rollback failure"
    end
    return FakeCache.replace(self, sourcePath, destinationPath)
  end
  local cache = CacheFs.forVersion("heartgold", backend)
  seedOldArtifact(cache)
  local tx = beginActors(cache)
  stageNewArtifact(tx)
  local err = Assert.throws(function()
    tx:publish()
  end)
  Assert.isTrue(Errors.is(err), "an incomplete rollback must surface as a structured error")
  Assert.equal(err.code, "CACHE_PUBLISH_ROLLBACK_INCOMPLETE")
  Assert.isTrue(tostring(err.context.cause):match("CACHE_REPLACE_FAILED"), "the original publish error is the cause")
  Assert.isTrue(tostring(err.context.rollback):match("injected rollback failure"), "the rollback error is recorded")
  Assert.equal(
    findAttemptFile(backend, DATA, ".__g4old", "/index.lua"),
    "old-index",
    "the aside root stays in the stage as recovery material"
  )
end

-- A failing stage cleanup after every root was published is reported as
-- publish-succeeded-cleanup-failed: the new artifact is already live, so a
-- caller must not mistake this for a failed publication (retrying would be
-- unsafe).
function T.publish_reports_cleanup_failure_after_success()
  local backend = FakeCache.new()
  backend.remove = function(self, path)
    if path == STAGE_ROOT then
      return false, "injected cleanup failure"
    end
    return FakeCache.remove(self, path)
  end
  local cache = CacheFs.forVersion("heartgold", backend)
  seedOldArtifact(cache)
  local tx = beginActors(cache)
  stageNewArtifact(tx)
  local err = Assert.throws(function()
    tx:publish()
  end)
  Assert.isTrue(Errors.is(err), "a cleanup failure must surface as a structured error")
  Assert.equal(err.code, "CACHE_PUBLISH_CLEANUP_FAILED")
  Assert.equal(cache:read(DATA .. "/complete"), "new-marker", "the new artifact is live despite the cleanup failure")
  Assert.equal(cache:read(DATA .. "/index.lua"), "new-index")
  Assert.equal(cache:read(ASSET .. "/0000.png"), "new-png")
end

function T.begin_clears_only_its_private_stage()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local roots = { DATA, ASSET }
  backend:write(oldRoot(DATA) .. "/index.lua", "old-index")
  backend:write(liveRoot(ASSET) .. "/0000.png", "old-png")
  backend:write(
    "heartgold.__g4publish.lua",
    LuaWriter.encode({
      schema = 1,
      roots = {
        { path = DATA, hadLive = true },
        { path = ASSET, hadLive = true },
      },
    })
  )
  local stage = CacheFs.forArtifactStage("heartgold", "recovery-check", backend)
  stage:write(DATA .. "/stale", "stale-stage")

  local tx = ArtifactPublisher.begin(cache, "recovery-check", roots)

  Assert.isNil(cache:read(DATA .. "/index.lua"))
  Assert.equal(cache:read(ASSET .. "/0000.png"), "old-png")
  Assert.notNil(backend:getInfo("heartgold.__g4publish.lua"))
  Assert.isNil(tx.stage:read(DATA .. "/stale"))
end

return { tests = T }
