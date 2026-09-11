local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local LuaWriter = require("libs.codec.src.LuaWriter")
local Errors = require("libs.errors.src.Errors")
local StorageErrors = require("libs.storage.src.errors")
local FakeCache = require("tests.support.FakeCache")
local ConstrainedCache = require("tests.support.ConstrainedCache")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")

local function cache(versionId, backend)
  return CacheFs.forVersion(versionId, backend or FakeCache.new())
end

local T = {}

function T.prefix_reflects_version()
  Assert.equal(cache("heartgold"):prefix(), "heartgold/")
  Assert.equal(cache("soulsilver"):prefix(), "soulsilver/")
end

-- Version ids are structural path components, not ROM identities: any safe
-- component names its own namespace. Which ids exist is romdump's GameVersion
-- business; generic persistence must not depend on it.
function T.version_ids_are_structural_not_catalogued()
  Assert.equal(cache("custom"):prefix(), "custom/")
  Assert.equal(cache("hg-2"):prefix(), "hg-2/")
end

function T.rejects_unsafe_version_ids()
  Assert.throws(function()
    cache("../escape")
  end)
  Assert.throws(function()
    cache("a/b")
  end)
  Assert.throws(function()
    cache("")
  end)
  Assert.throws(function()
    cache("a\\b")
  end)
end

function T.staging_roots_reject_unsafe_version_ids()
  Assert.throws(function()
    CacheFs.forStaging("../escape")
  end)
  Assert.throws(function()
    CacheFs.forArtifactStage("a/b", "name")
  end)
end

function T.write_lands_under_version_prefix()
  local backend = FakeCache.new()
  cache("heartgold", backend):write("system/header.bin", "HDR")
  Assert.equal(backend.files["heartgold/system/header.bin"], "HDR")
end

function T.read_round_trips_written_bytes()
  local c = cache("heartgold")
  c:write("a/0/4/1", "matrix")
  Assert.equal(c:read("a/0/4/1"), "matrix")
end

-- CacheFs has one opaque write seam for strings and LÖVE Data. A Data value
-- must cross that seam unchanged; converting through getString would both add
-- an avoidable copy and violate the producer's final-allocation ownership.
function T.write_forwards_data_without_string_conversion()
  local payload = "G4M2\0\1\0\255"
  local data = {
    getSize = function()
      return #payload
    end,
    getFFIPointer = function()
      error("the storage path must not inspect the Data pointer")
    end,
    getString = function()
      error("the storage path must not convert Data to a string")
    end,
  }
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  c:write("geometry/mesh.g4mesh", data)
  Assert.isTrue(backend.files["heartgold/geometry/mesh.g4mesh"] == data, "Data reaches the backend by identity")
  Assert.isTrue(c:getInfo("geometry/mesh.g4mesh").size == #payload, "Data size remains available to storage")
end

function T.read_missing_returns_nil()
  Assert.isNil(cache("heartgold"):read("nope"))
end

function T.exists_checks_presence_and_type()
  local c = cache("heartgold")
  c:write("romfs/a/0/0/2", "x")
  Assert.isTrue(c:exists("romfs/a/0/0/2"))
  Assert.isTrue(c:exists("romfs/a/0/0/2", "file"))
  Assert.isFalse(c:exists("romfs/a/0/0/2", "directory"))
  Assert.isTrue(c:exists("romfs/a/0/0", "directory"))
  Assert.isFalse(c:exists("absent"))
end

-- write() must materialize the parent chain so the love backend (no implicit
-- mkdir) can land a deeply nested NitroFS file.
function T.write_creates_parent_directories()
  local backend = FakeCache.new()
  cache("heartgold", backend):write("romfs/a/0/0/0", "data")
  Assert.isTrue(backend.dirs["heartgold/romfs/a/0/0"], "parent directory must be created")
end

function T.remove_tree_recursively_clears_subtree()
  local c = cache("heartgold")
  c:write("romfs/a/0/0/0", "0")
  c:write("romfs/a/0/0/1", "1")
  c:write("romfs/data/x", "x")
  c:removeTree("romfs/a")
  Assert.isNil(c:read("romfs/a/0/0/0"))
  Assert.isNil(c:read("romfs/a/0/0/1"))
  Assert.equal(c:read("romfs/data/x"), "x")
end

-- One version's operations must never see or clear another's.
function T.versions_are_isolated()
  local backend = FakeCache.new()
  local hg = cache("heartgold", backend)
  local ss = cache("soulsilver", backend)
  hg:write("marker", "HG")
  ss:write("marker", "SS")
  Assert.equal(hg:read("marker"), "HG")
  Assert.equal(ss:read("marker"), "SS")
  ss:removeTree("")
  Assert.equal(hg:read("marker"), "HG")
  Assert.isNil(ss:read("marker"))
end

function T.rejects_absolute_paths()
  Assert.throws(function()
    cache("heartgold"):write("/etc/passwd", "x")
  end)
end

function T.rejects_drive_letters()
  Assert.throws(function()
    cache("heartgold"):write("C:/x", "x")
  end)
end

function T.rejects_parent_components()
  Assert.throws(function()
    cache("heartgold"):read("../soulsilver/marker")
  end)
  Assert.throws(function()
    cache("heartgold"):read("a/../../b")
  end)
end

function T.rejects_dot_and_nul_components()
  Assert.throws(function()
    cache("heartgold"):read("a/./b")
  end)
  Assert.throws(function()
    cache("heartgold"):read("a\0b")
  end)
end

function T.lua_round_trip_is_deterministic()
  local c = cache("heartgold")
  local value = { schema = 1, files = { [0] = { fileId = 0, size = 12 } } }
  c:writeLua("data/generated/x.lua", value)
  Assert.deepEqual(c:loadLua("data/generated/x.lua"), value)
end

function T.atomic_replace_moves_a_file_over_its_destination()
  local c = cache("heartgold")
  c:write("save/session.lua", "old")
  c:write("save/session.lua.tmp", "new")
  c:replace("save/session.lua.tmp", "save/session.lua")
  Assert.equal(c:read("save/session.lua"), "new")
  Assert.isNil(c:read("save/session.lua.tmp"))
end

function T.load_lua_missing_is_a_missing_file_error()
  local data, err = cache("heartgold"):loadLua("data/generated/absent.lua")
  Assert.isNil(data)
  Assert.isTrue(
    err ~= nil and err.code == StorageErrors.CACHE_FILE_MISSING,
    "expected " .. StorageErrors.CACHE_FILE_MISSING .. ", got " .. tostring(err)
  )
end

-- An actual backend read failure is not a missing cache file: the load
-- boundary must keep the two apart, or corruption of an existing generated
-- file would be silently treated as absence.
function T.load_lua_read_failure_is_not_reclassified_as_missing()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  c:write("data/generated/x.lua", "DATA")
  backend.read = function(_)
    return nil, "injected read failure"
  end
  local data, err = c:loadLua("data/generated/x.lua")
  Assert.isNil(data)
  Assert.isTrue(
    err ~= nil and err.code == StorageErrors.CACHE_READ_FAILED,
    "expected " .. StorageErrors.CACHE_READ_FAILED .. ", got " .. tostring(err)
  )
  Assert.isTrue(
    tostring(err):find("injected read failure", 1, true) ~= nil,
    "the backend read error must survive to the load boundary: " .. tostring(err)
  )
end

-- loadModule evaluates generated script modules under a restricted require
-- allowlist (gen4.script only, matching ScriptLoader's resource loader), not
-- the unrestricted global require/package. The allowlisted happy path is
-- pinned by ScriptCache's readiness tests (script_valid_artifact_is_ready).
function T.load_module_rejects_a_require_of_a_disallowed_module()
  local c = cache("heartgold")
  c:write("data/generated/script/a.b.lua", 'local X = require("libs.errors.src.Errors")\nreturn X\n')
  local data, err = c:loadModule("data/generated/script/a.b.lua")
  Assert.isNil(data, "a module requiring outside the allowlist must fail to load")
  Assert.notNil(err, "a disallowed require must surface as an error")
  Assert.isTrue(Errors.is(err), "the failure must be a structured cache error")
end

-- The package global must not be reachable from a generated module: at best
-- it is a permission hole, at worst a generated module can corrupt the
-- process-wide package tables the allowlist is meant to keep it away from.
function T.load_module_env_does_not_expose_package()
  local c = cache("heartgold")
  c:write("data/generated/script/a.b.lua", "local p = package\nreturn p.path\n")
  local data, err = c:loadModule("data/generated/script/a.b.lua")
  Assert.isNil(data, "the package global must not be reachable from a generated module")
  Assert.notNil(err)
  Assert.isTrue(Errors.is(err), "the failure must be a structured cache error")
end

local function staging(versionId, backend)
  return CacheFs.forStaging(versionId, backend)
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

function T.staging_prefix_is_a_sibling_namespace()
  Assert.equal(staging("heartgold"):prefix(), "heartgold.__g4next/")
  Assert.equal(staging("soulsilver"):prefix(), "soulsilver.__g4next/")
  local backend = FakeCache.new()
  staging("heartgold", backend):write("romfs/a/0/0/2", "STAGE-DATA")
  Assert.equal(backend.files["heartgold.__g4next/romfs/a/0/0/2"], "STAGE-DATA")
  Assert.isNil(backend.files["heartgold/romfs/a/0/0/2"], "live root must stay untouched")
end

function T.remove_staged_tree_clears_staging_and_orphaned_old()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local s = staging("heartgold", backend)
  c:write("romfs/a/0/0/2", "LIVE")
  s:write("romfs/a/0/0/2", "STAGE")
  backend.files["heartgold.__g4old/romfs/x"] = "ORPHAN"
  c:removeStagedTree(s)
  Assert.isNil(backend.files["heartgold.__g4next/romfs/a/0/0/2"], "staging must be cleared")
  Assert.isNil(backend.files["heartgold.__g4old/romfs/x"], "orphaned old root must be cleared")
  Assert.equal(backend.files["heartgold/romfs/a/0/0/2"], "LIVE", "live root must stay untouched")
end

function T.publish_from_stage_replaces_live_root()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local s = staging("heartgold", backend)
  c:write("romfs/a/0/0/2", "OLD")
  c:write("rom-dump.complete", "OLD-MARKER")
  s:write("romfs/a/0/0/2", "NEW")
  s:write("data/generated/rom_metadata.lua", "NEW-META")
  s:write("rom-dump.complete", "NEW-MARKER")
  c:publishFromStage(s)
  Assert.equal(backend.files["heartgold/romfs/a/0/0/2"], "NEW")
  Assert.equal(backend.files["heartgold/rom-dump.complete"], "NEW-MARKER")
  Assert.equal(backend.files["heartgold/data/generated/rom_metadata.lua"], "NEW-META")
  Assert.isNil(backend.files["heartgold.__g4next/romfs/a/0/0/2"], "staging root must be gone")
  Assert.isNil(backend.dirs["heartgold.__g4next"], "staging root must be gone")
  Assert.isNil(backend.files["heartgold.__g4old/romfs/a/0/0/2"], "previous root must be gone")
end

function T.publish_from_stage_handles_fresh_import()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local s = staging("heartgold", backend)
  s:write("romfs/a/0/0/2", "FIRST")
  s:write("rom-dump.complete", "MARKER")
  c:publishFromStage(s)
  Assert.equal(backend.files["heartgold/romfs/a/0/0/2"], "FIRST")
  Assert.isNil(backend.files["heartgold.__g4next/romfs/a/0/0/2"])
end

function T.whole_version_publication_respects_restricted_directory_renames()
  local backend = ConstrainedCache.new()
  local live = cache("heartgold", backend)
  local stage = staging("heartgold", backend)
  live:write("romfs/old.bin", "old")
  live:write("rom-dump.complete", "old-marker")
  stage:write("romfs/new.bin", "new")
  stage:write("rom-dump.complete", "new-marker")

  local ok, err = pcall(function()
    live:publishFromStage(stage)
  end)
  Assert.isTrue(ok, tostring(err))
  Assert.equal(live:read("romfs/new.bin"), "new")
  Assert.equal(live:read("rom-dump.complete"), "new-marker")
  Assert.isNil(backend:getInfo("heartgold.__g4next"))
  Assert.isNil(backend:getInfo("heartgold.__g4old"))
  Assert.isNil(backend:getInfo("staging/heartgold"))
  assertPortableRenames(backend)
end

function T.file_root_publication_moves_aside_existing_file_before_replacement()
  local backend = ConstrainedCache.new()
  local live = cache("heartgold", backend)
  local fileRoot = "data/generated/map-index.lua"
  local first = ArtifactPublisher.begin(live, "map-index", { fileRoot })
  live:write(fileRoot, "old-index")
  first.stage:write(fileRoot, "new-index")

  local ok, err = pcall(function()
    first:publish()
  end)
  Assert.isTrue(ok, tostring(err))
  Assert.equal(live:read(fileRoot), "new-index")
  Assert.isNil(backend:getInfo("heartgold/" .. fileRoot .. ".__g4next"))
  Assert.isNil(backend:getInfo("heartgold/" .. fileRoot .. ".__g4old"))

  local second = ArtifactPublisher.begin(live, "map-index", { fileRoot })
  second.stage:write(fileRoot, "replacement-index")
  backend:failNextRename("heartgold/" .. fileRoot .. ".__g4next")
  local publishErr = Assert.throws(function()
    second:publish()
  end)
  Assert.isTrue(Errors.is(publishErr))
  Assert.equal(publishErr.code, StorageErrors.CACHE_REPLACE_FAILED)
  Assert.equal(live:read(fileRoot), "new-index", "failed replacement restores the previous file")
  Assert.isNil(backend:getInfo("heartgold/" .. fileRoot .. ".__g4old"))
  assertPortableRenames(backend)
end

function T.candidate_copy_preserves_nested_files_and_empty_directories()
  local backend = ConstrainedCache.new()
  local live = cache("heartgold", backend)
  local root = "data/generated/field/maps"
  local payload = "persisted\0bytes"
  local tx = ArtifactPublisher.begin(live, "field-maps", { root })
  tx.stage:write(root .. "/nested/value.bin", payload)
  tx.stage:createDirectory(root .. "/empty")

  tx:publish()

  Assert.equal(live:read(root .. "/nested/value.bin"), payload)
  Assert.notNil(backend:getInfo("heartgold/" .. root .. "/empty"))
end

function T.candidate_copy_replaces_a_stale_candidate_tree()
  local backend = FakeCache.new()
  local live = cache("heartgold", backend)
  local root = "data/generated/field/maps"
  local tx = ArtifactPublisher.begin(live, "field-maps", { root })
  backend:write("heartgold/" .. root .. ".__g4next/stale.bin", "stale")
  tx.stage:write(root .. "/current.bin", "current")

  tx:publish()

  Assert.equal(live:read(root .. "/current.bin"), "current")
  Assert.isNil(live:read(root .. "/stale.bin"))
end

function T.candidate_copy_failure_cleans_partial_candidates_without_touching_live()
  local backend = FakeCache.new()
  local live = cache("heartgold", backend)
  local root = "data/generated/field/maps"
  live:write(root .. "/old.bin", "old")
  local tx = ArtifactPublisher.begin(live, "field-maps", { root })
  tx.stage:write(root .. "/first.bin", "first")
  tx.stage:write(root .. "/second.bin", "second")

  local originalWrite = backend.write
  backend.write = function(self, path, data)
    if path:find(".__g4next", 1, true) and path:find("second.bin", 1, true) then
      return false, "injected candidate write failure"
    end
    return originalWrite(self, path, data)
  end

  local err = Assert.throws(function()
    tx:publish()
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, StorageErrors.CACHE_WRITE_FAILED)
  Assert.equal(live:read(root .. "/old.bin"), "old")
  Assert.isNil(backend:getInfo("heartgold/" .. root .. ".__g4next"))
end

function T.interrupted_old_siblings_are_not_guessed_without_metadata()
  local backend = FakeCache.new()
  local live = cache("heartgold", backend)
  local firstRoot = "data/generated/field/maps"
  local secondRoot = "data/generated/field/cells"
  backend:write("heartgold/" .. firstRoot .. "/partial.bin", "partial")
  backend:write("heartgold/" .. firstRoot .. ".__g4old/previous.bin", "previous-map")
  backend:write("heartgold/" .. secondRoot .. ".__g4old/previous.bin", "previous-cell")

  local tx = ArtifactPublisher.begin(live, "field-world", { firstRoot, secondRoot })
  tx.stage:write(firstRoot .. "/replacement.bin", "replacement")
  tx.stage:write(secondRoot .. "/replacement.bin", "replacement")
  local originalWrite = backend.write
  backend.write = function(self, path, data)
    if path:find(".__g4next", 1, true) then
      return false, "injected candidate write failure"
    end
    return originalWrite(self, path, data)
  end

  local err = Assert.throws(function()
    tx:publish()
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, StorageErrors.CACHE_WRITE_FAILED)
  Assert.equal(live:read(firstRoot .. "/partial.bin"), "partial")
  Assert.equal(backend.files["heartgold/" .. firstRoot .. ".__g4old/previous.bin"], "previous-map")
  Assert.equal(backend.files["heartgold/" .. secondRoot .. ".__g4old/previous.bin"], "previous-cell")
end

function T.publish_from_stage_restores_previous_root_on_failure()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local s = staging("heartgold", backend)
  c:write("romfs/a/0/0/2", "OLD")
  c:write("rom-dump.complete", "OLD-MARKER")
  s:write("romfs/a/0/0/2", "NEW")
  s:write("rom-dump.complete", "NEW-MARKER")
  local originalReplace = backend.replace
  backend.replace = function(self, sourcePath, destinationPath)
    if sourcePath == "heartgold.__g4next" then
      error(Errors.new(StorageErrors.CACHE_REPLACE_FAILED, "injected publish failure", { sourcePath = sourcePath }))
    end
    return originalReplace(self, sourcePath, destinationPath)
  end
  local err = Assert.throws(function()
    c:publishFromStage(s)
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, StorageErrors.CACHE_REPLACE_FAILED)
  Assert.equal(backend.files["heartgold/romfs/a/0/0/2"], "OLD", "previous dump must be restored")
  Assert.equal(backend.files["heartgold/rom-dump.complete"], "OLD-MARKER")
  Assert.isNil(backend.files["heartgold.__g4old/romfs/a/0/0/2"], "no orphaned old root after rollback")
end

-- Every mutating operation must translate a backend-reported failure into
-- a structured cache error. Backends may report failure by returning falsy;
-- no wrapper may silently return true, and publication must never report
-- success while a mutation it depends on has failed.

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.equal(err.code, code, "expected " .. code .. ", got " .. tostring(err))
end

function T.write_reports_backend_failure()
  local backend = FakeCache.new()
  backend.write = function()
    return false, "injected write failure"
  end
  throwsCode(StorageErrors.CACHE_WRITE_FAILED, function()
    cache("heartgold", backend):write("romfs/a/0/0/2", "data")
  end)
end

function T.write_reports_parent_directory_failure()
  local backend = FakeCache.new()
  backend.createDirectory = function()
    return false, "injected mkdir failure"
  end
  throwsCode(StorageErrors.CACHE_MKDIR_FAILED, function()
    cache("heartgold", backend):write("romfs/a/0/0/2", "data")
  end)
end

function T.create_directory_reports_backend_failure()
  local backend = FakeCache.new()
  backend.createDirectory = function()
    return false, "injected mkdir failure"
  end
  throwsCode(StorageErrors.CACHE_MKDIR_FAILED, function()
    cache("heartgold", backend):createDirectory("romfs/a")
  end)
end

function T.remove_reports_backend_failure()
  local backend = FakeCache.new()
  cache("heartgold", backend):write("romfs/a/0/0/2", "data")
  backend.remove = function()
    return false, "injected remove failure"
  end
  throwsCode(StorageErrors.CACHE_REMOVE_FAILED, function()
    cache("heartgold", backend):remove("romfs/a/0/0/2")
  end)
end

-- Removing an absent path is a no-op, matching _removeTreeAt: the backend is
-- never asked to remove something that does not exist.
function T.remove_absent_path_is_a_noop()
  local backend = FakeCache.new()
  backend.remove = function()
    error("backend must not be asked to remove an absent path")
  end
  Assert.isTrue(cache("heartgold", backend):remove("absent"))
end

function T.remove_tree_reports_backend_failure()
  local backend = FakeCache.new()
  cache("heartgold", backend):write("romfs/a/0/0/2", "data")
  backend.remove = function()
    return false, "injected remove failure"
  end
  throwsCode(StorageErrors.CACHE_REMOVE_FAILED, function()
    cache("heartgold", backend):removeTree("romfs/a")
  end)
end

function T.replace_reports_backend_failure()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  c:write("save/session.lua", "old")
  c:write("save/session.lua.tmp", "new")
  backend.replace = function()
    return false, "injected replace failure"
  end
  throwsCode(StorageErrors.CACHE_REPLACE_FAILED, function()
    c:replace("save/session.lua.tmp", "save/session.lua")
  end)
end

-- A backend-reported failure (falsy return, not a raise) must abort the
-- publish; publication can never report success when a rename failed.
function T.publish_from_stage_reports_aside_failure()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local s = staging("heartgold", backend)
  c:write("romfs/a/0/0/2", "OLD")
  s:write("romfs/a/0/0/2", "NEW")
  backend.replace = function(self, sourcePath, destinationPath)
    if sourcePath == "heartgold" then
      return false, "injected replace failure"
    end
    return FakeCache.replace(self, sourcePath, destinationPath)
  end
  throwsCode(StorageErrors.CACHE_REPLACE_FAILED, function()
    c:publishFromStage(s)
  end)
  Assert.equal(backend.files["heartgold/romfs/a/0/0/2"], "OLD", "failed aside must leave the live dump in place")
  Assert.isNil(backend.files["heartgold.__g4old/romfs/a/0/0/2"], "nothing may land in the old root")
end

function T.publish_from_stage_restores_previous_root_when_replace_reports_failure()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local s = staging("heartgold", backend)
  c:write("romfs/a/0/0/2", "OLD")
  c:write("rom-dump.complete", "OLD-MARKER")
  s:write("romfs/a/0/0/2", "NEW")
  s:write("rom-dump.complete", "NEW-MARKER")
  backend.replace = function(self, sourcePath, destinationPath)
    if sourcePath == "heartgold.__g4next" then
      return false, "injected publish failure"
    end
    return FakeCache.replace(self, sourcePath, destinationPath)
  end
  throwsCode(StorageErrors.CACHE_REPLACE_FAILED, function()
    c:publishFromStage(s)
  end)
  Assert.equal(backend.files["heartgold/romfs/a/0/0/2"], "OLD", "previous dump must be restored")
  Assert.equal(backend.files["heartgold/rom-dump.complete"], "OLD-MARKER")
  Assert.isNil(backend.files["heartgold.__g4old/romfs/a/0/0/2"], "no orphaned old root after rollback")
end

-- When the aside restore fails too, the rollback is incomplete: the previous
-- dump stays at the aside root (the only remaining recovery material) and the
-- failure reports both the original publish error and the rollback error.
function T.publish_from_stage_reports_incomplete_rollback()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local s = staging("heartgold", backend)
  c:write("romfs/a/0/0/2", "OLD")
  c:write("rom-dump.complete", "OLD-MARKER")
  s:write("romfs/a/0/0/2", "NEW")
  s:write("rom-dump.complete", "NEW-MARKER")
  local originalReplace = backend.replace
  backend.replace = function(self, sourcePath, destinationPath)
    if sourcePath == "heartgold.__g4next" then
      return false, "injected publish failure"
    end
    if sourcePath == "heartgold.__g4old" then
      return false, "injected rollback failure"
    end
    return originalReplace(self, sourcePath, destinationPath)
  end
  local err = Assert.throws(function()
    c:publishFromStage(s)
  end)
  Assert.isTrue(Errors.is(err), "an incomplete rollback must surface as a structured error")
  Assert.equal(err.code, StorageErrors.CACHE_PUBLISH_ROLLBACK_INCOMPLETE)
  Assert.isTrue(
    tostring(err.context.cause):match(StorageErrors.CACHE_REPLACE_FAILED),
    "the original publish error is the cause"
  )
  Assert.isTrue(tostring(err.context.rollback):match("injected rollback failure"), "the rollback error is recorded")
  Assert.equal(backend.files["heartgold.__g4old/romfs/a/0/0/2"], "OLD", "the aside keeps the last-known-good dump")
  Assert.equal(backend.files["heartgold.__g4next/romfs/a/0/0/2"], "NEW", "the staged dump stays in place")
end

-- A backend-reported failure removing the previous root after the swap must
-- surface as the shared cleanup outcome: the new dump is live, so the failure
-- reports cleanup-failed rather than a failed publication, and the old root is
-- the only recovery material left.
function T.publish_from_stage_reports_cleanup_failure()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local s = staging("heartgold", backend)
  c:write("romfs/a/0/0/2", "OLD")
  s:write("romfs/a/0/0/2", "NEW")
  local originalRemove = backend.remove
  backend.remove = function(self, path)
    if path:find("heartgold.__g4old", 1, true) then
      return false, "injected cleanup failure"
    end
    return originalRemove(self, path)
  end
  local err = Assert.throws(function()
    c:publishFromStage(s)
  end)
  Assert.isTrue(Errors.is(err), "a cleanup failure must surface as a structured error")
  Assert.equal(err.code, StorageErrors.CACHE_PUBLISH_CLEANUP_FAILED)
  Assert.equal(backend.files["heartgold/romfs/a/0/0/2"], "NEW", "the new dump has landed before cleanup")
  Assert.equal(backend.files["heartgold.__g4old/romfs/a/0/0/2"], "OLD", "the old root is the only staging residue")
end

function T.remove_staged_tree_reports_backend_failure()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local s = staging("heartgold", backend)
  s:write("romfs/a/0/0/2", "STAGE")
  backend.remove = function()
    return false, "injected remove failure"
  end
  throwsCode(StorageErrors.CACHE_REMOVE_FAILED, function()
    c:removeStagedTree(s)
  end)
end

local PUBLISH_MANIFEST = "heartgold.__g4publish.lua"
local PUBLISH_NEXT = "heartgold.__g4publish.__g4next"
local PUBLISH_COMMIT = "heartgold.__g4published"

local function livePath(root)
  return "heartgold/" .. root
end

local function siblingRoot(root, suffix)
  return livePath(root) .. suffix
end

local function writePublicationRecord(backend, roots)
  backend:write(PUBLISH_MANIFEST, LuaWriter.encode({ schema = 1, roots = roots }))
end

local function assertPublicationResidueAbsent(backend, roots)
  Assert.isNil(backend:getInfo(PUBLISH_MANIFEST))
  Assert.isNil(backend:getInfo(PUBLISH_NEXT))
  Assert.isNil(backend:getInfo(PUBLISH_COMMIT))
  for _, root in ipairs(roots) do
    Assert.isNil(backend:getInfo(siblingRoot(root, ".__g4old")))
    Assert.isNil(backend:getInfo(siblingRoot(root, ".__g4next")))
  end
end

function T.partial_phase_one_recovery_preserves_untouched_live_root()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local roots = { "data/generated/alpha", "data/generated/beta" }
  backend:write(livePath(roots[1]) .. "/value", "alpha-original")
  backend:write(livePath(roots[2]) .. "/value", "beta-original")
  backend:write(siblingRoot(roots[1], ".__g4old") .. "/value", "alpha-original")
  backend:write(siblingRoot(roots[1], ".__g4next") .. "/value", "alpha-new")
  backend:write(siblingRoot(roots[2], ".__g4next") .. "/value", "beta-new")
  writePublicationRecord(backend, {
    { path = roots[1], hadLive = true },
    { path = roots[2], hadLive = true },
  })

  c:recoverPublication()

  Assert.equal(backend.files[livePath(roots[1]) .. "/value"], "alpha-original")
  Assert.equal(backend.files[livePath(roots[2]) .. "/value"], "beta-original")
  assertPublicationResidueAbsent(backend, roots)
end

function T.uncommitted_recovery_restores_original_root_presence()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local roots = { "data/generated/alpha", "data/generated/beta" }
  backend:write(siblingRoot(roots[1], ".__g4old") .. "/value", "alpha-original")
  backend:write(livePath(roots[1]) .. "/value", "alpha-new")
  backend:write(livePath(roots[2]) .. "/value", "beta-new")
  backend:write(siblingRoot(roots[1], ".__g4next") .. "/value", "alpha-new")
  backend:write(siblingRoot(roots[2], ".__g4next") .. "/value", "beta-new")
  writePublicationRecord(backend, {
    { path = roots[1], hadLive = true },
    { path = roots[2], hadLive = false },
  })

  c:recoverPublication()

  Assert.equal(backend.files[livePath(roots[1]) .. "/value"], "alpha-original")
  Assert.isNil(backend:getInfo(livePath(roots[2])))
  assertPublicationResidueAbsent(backend, roots)
end

function T.committed_recovery_preserves_new_roots_and_cleans_residue()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local roots = { "data/generated/alpha", "data/generated/beta" }
  backend:write(livePath(roots[1]) .. "/value", "alpha-new")
  backend:write(livePath(roots[2]) .. "/value", "beta-new")
  backend:write(siblingRoot(roots[1], ".__g4old") .. "/value", "alpha-original")
  backend:write(siblingRoot(roots[2], ".__g4old") .. "/value", "beta-original")
  backend:write(siblingRoot(roots[1], ".__g4next") .. "/value", "alpha-new")
  writePublicationRecord(backend, {
    { path = roots[1], hadLive = true },
    { path = roots[2], hadLive = true },
  })
  backend:write(PUBLISH_COMMIT, "g4-cache-publish-v1")

  c:recoverPublication()

  Assert.equal(backend.files[livePath(roots[1]) .. "/value"], "alpha-new")
  Assert.equal(backend.files[livePath(roots[2]) .. "/value"], "beta-new")
  assertPublicationResidueAbsent(backend, roots)
end

function T.malformed_publication_metadata_leaves_live_roots_untouched()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local roots = { "data/generated/alpha", "data/generated/beta" }
  c:write(roots[1] .. "/value", "alpha-original")
  c:write(roots[2] .. "/value", "beta-original")
  backend:write(PUBLISH_MANIFEST, LuaWriter.encode({ schema = 999, roots = {} }))
  local stage = CacheFs.forArtifactStage("heartgold", "recovery-check", backend)
  stage:write(roots[1] .. "/stale", "stale-stage")

  local ok, err = pcall(function()
    ArtifactPublisher.begin(c, "recovery-check", roots)
  end)

  Assert.isFalse(ok, "malformed publication metadata must stop stage initialization")
  Assert.notNil(err)
  Assert.isTrue(Errors.is(err), "malformed publication metadata must raise a structured storage error")
  Assert.equal(c:read(roots[1] .. "/value"), "alpha-original")
  Assert.equal(c:read(roots[2] .. "/value"), "beta-original")
  Assert.equal(backend.files["staging/heartgold/recovery-check/" .. roots[1] .. "/stale"], "stale-stage")
end

function T.empty_publication_manifest_is_structured_and_non_destructive()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local root = "data/generated/alpha"
  c:write(root .. "/value", "live-original")
  backend:write(siblingRoot(root, ".__g4old") .. "/value", "old-original")
  backend:write(PUBLISH_MANIFEST, "return nil\n")

  local ok, err = pcall(function()
    c:recoverPublication()
  end)

  Assert.isFalse(ok, "an empty publication manifest must stop recovery")
  Assert.notNil(err)
  Assert.isTrue(Errors.is(err), "an empty publication manifest must raise a structured error")
  Assert.equal(assert(err).code, StorageErrors.CACHE_PUBLISH_ROLLBACK_INCOMPLETE)
  Assert.equal(c:read(root .. "/value"), "live-original")
  Assert.equal(backend.files[siblingRoot(root, ".__g4old") .. "/value"], "old-original")
end

function T.recovery_is_safe_to_repeat()
  local uncommittedBackend = FakeCache.new()
  local uncommitted = cache("heartgold", uncommittedBackend)
  local uncommittedRoots = { "data/generated/alpha", "data/generated/beta" }
  uncommittedBackend:write(siblingRoot(uncommittedRoots[1], ".__g4old") .. "/value", "alpha-original")
  uncommittedBackend:write(livePath(uncommittedRoots[2]) .. "/value", "beta-original")
  writePublicationRecord(uncommittedBackend, {
    { path = uncommittedRoots[1], hadLive = true },
    { path = uncommittedRoots[2], hadLive = true },
  })

  uncommitted:recoverPublication()
  local replaceCalls = 0
  local removeCalls = 0
  local writeCalls = 0
  local originalReplace = uncommittedBackend.replace
  local originalRemove = uncommittedBackend.remove
  local originalWrite = uncommittedBackend.write
  uncommittedBackend.replace = function(self, sourcePath, destinationPath)
    replaceCalls = replaceCalls + 1
    return originalReplace(self, sourcePath, destinationPath)
  end
  uncommittedBackend.remove = function(self, path)
    removeCalls = removeCalls + 1
    return originalRemove(self, path)
  end
  uncommittedBackend.write = function(self, path, data)
    writeCalls = writeCalls + 1
    return originalWrite(self, path, data)
  end

  uncommitted:recoverPublication()

  Assert.equal(replaceCalls, 0)
  Assert.equal(removeCalls, 0)
  Assert.equal(writeCalls, 0)
  Assert.equal(uncommittedBackend.files[livePath(uncommittedRoots[1]) .. "/value"], "alpha-original")
  Assert.equal(uncommittedBackend.files[livePath(uncommittedRoots[2]) .. "/value"], "beta-original")

  local committedBackend = FakeCache.new()
  local committed = cache("heartgold", committedBackend)
  local committedRoots = { "data/generated/alpha", "data/generated/beta" }
  committedBackend:write(livePath(committedRoots[1]) .. "/value", "alpha-new")
  committedBackend:write(livePath(committedRoots[2]) .. "/value", "beta-new")
  writePublicationRecord(committedBackend, {
    { path = committedRoots[1], hadLive = true },
    { path = committedRoots[2], hadLive = true },
  })
  committedBackend:write(PUBLISH_COMMIT, "g4-cache-publish-v1")

  committed:recoverPublication()
  replaceCalls = 0
  removeCalls = 0
  writeCalls = 0
  originalReplace = committedBackend.replace
  originalRemove = committedBackend.remove
  originalWrite = committedBackend.write
  committedBackend.replace = function(self, sourcePath, destinationPath)
    replaceCalls = replaceCalls + 1
    return originalReplace(self, sourcePath, destinationPath)
  end
  committedBackend.remove = function(self, path)
    removeCalls = removeCalls + 1
    return originalRemove(self, path)
  end
  committedBackend.write = function(self, path, data)
    writeCalls = writeCalls + 1
    return originalWrite(self, path, data)
  end

  committed:recoverPublication()

  Assert.equal(replaceCalls, 0)
  Assert.equal(removeCalls, 0)
  Assert.equal(writeCalls, 0)
  Assert.equal(committedBackend.files[livePath(committedRoots[1]) .. "/value"], "alpha-new")
  Assert.equal(committedBackend.files[livePath(committedRoots[2]) .. "/value"], "beta-new")
end

function T.manifest_write_failure_does_not_touch_live_roots()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local root = "data/generated/alpha"
  c:write(root .. "/value", "old")
  local tx = ArtifactPublisher.begin(c, "manifest-write", { root })
  tx.stage:write(root .. "/value", "new")
  local originalWrite = backend.write
  backend.write = function(self, path, data)
    if path == PUBLISH_NEXT then
      return false, "injected manifest write failure"
    end
    return originalWrite(self, path, data)
  end

  local err = Assert.throws(function()
    tx:publish()
  end)

  Assert.equal(err.code, StorageErrors.CACHE_WRITE_FAILED)
  Assert.equal(c:read(root .. "/value"), "old")
  Assert.isNil(backend:getInfo(PUBLISH_MANIFEST))
  Assert.isNil(backend:getInfo(PUBLISH_NEXT))
  Assert.isNil(backend:getInfo(PUBLISH_COMMIT))
end

function T.manifest_promotion_failure_does_not_touch_live_roots()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local root = "data/generated/alpha"
  c:write(root .. "/value", "old")
  local tx = ArtifactPublisher.begin(c, "manifest-promotion", { root })
  tx.stage:write(root .. "/value", "new")
  local originalReplace = backend.replace
  backend.replace = function(self, sourcePath, destinationPath)
    if sourcePath == PUBLISH_NEXT then
      return false, "injected manifest promotion failure"
    end
    return originalReplace(self, sourcePath, destinationPath)
  end

  local err = Assert.throws(function()
    tx:publish()
  end)

  Assert.equal(err.code, StorageErrors.CACHE_REPLACE_FAILED)
  Assert.equal(c:read(root .. "/value"), "old")
  Assert.isNil(backend:getInfo(PUBLISH_MANIFEST))
  Assert.isNil(backend:getInfo(PUBLISH_NEXT))
end

function T.commit_write_failure_rolls_back_the_published_roots()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local root = "data/generated/alpha"
  c:write(root .. "/value", "old")
  local tx = ArtifactPublisher.begin(c, "commit-write", { root })
  tx.stage:write(root .. "/value", "new")
  local originalWrite = backend.write
  backend.write = function(self, path, data)
    if path == PUBLISH_COMMIT then
      return false, "injected commit write failure"
    end
    return originalWrite(self, path, data)
  end

  local err = Assert.throws(function()
    tx:publish()
  end)

  Assert.equal(err.code, StorageErrors.CACHE_WRITE_FAILED)
  Assert.equal(c:read(root .. "/value"), "old")
  Assert.isNil(backend:getInfo(siblingRoot(root, ".__g4old")))
  Assert.isNil(backend:getInfo(PUBLISH_MANIFEST))
end

function T.cleanup_failure_keeps_committed_metadata_recoverable()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local root = "data/generated/alpha"
  c:write(root .. "/value", "old")
  local tx = ArtifactPublisher.begin(c, "old-cleanup", { root })
  tx.stage:write(root .. "/value", "new")
  local originalRemove = backend.remove
  backend.remove = function(self, path)
    if path:find(".__g4old/", 1, true) then
      return false, "injected old cleanup failure"
    end
    return originalRemove(self, path)
  end

  local err = Assert.throws(function()
    tx:publish()
  end)

  Assert.equal(err.code, StorageErrors.CACHE_PUBLISH_CLEANUP_FAILED)
  Assert.equal(c:read(root .. "/value"), "new")
  Assert.notNil(backend:getInfo(PUBLISH_MANIFEST))
  Assert.notNil(backend:getInfo(PUBLISH_COMMIT))
  backend.remove = originalRemove
  c:recoverPublication()
  Assert.isNil(backend:getInfo(siblingRoot(root, ".__g4old")))
  Assert.isNil(backend:getInfo(PUBLISH_MANIFEST))
  Assert.isNil(backend:getInfo(PUBLISH_COMMIT))
end

function T.manifest_cleanup_failure_leaves_the_commit_boundary_intact()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local root = "data/generated/alpha"
  c:write(root .. "/value", "old")
  local tx = ArtifactPublisher.begin(c, "manifest-cleanup", { root })
  tx.stage:write(root .. "/value", "new")
  local originalRemove = backend.remove
  backend.remove = function(self, path)
    if path == PUBLISH_MANIFEST then
      return false, "injected manifest cleanup failure"
    end
    return originalRemove(self, path)
  end

  local err = Assert.throws(function()
    tx:publish()
  end)

  Assert.equal(err.code, StorageErrors.CACHE_PUBLISH_CLEANUP_FAILED)
  Assert.equal(c:read(root .. "/value"), "new")
  Assert.notNil(backend:getInfo(PUBLISH_MANIFEST))
  Assert.notNil(backend:getInfo(PUBLISH_COMMIT))
  backend.remove = originalRemove
  c:recoverPublication()
  Assert.isNil(backend:getInfo(PUBLISH_MANIFEST))
  Assert.isNil(backend:getInfo(PUBLISH_COMMIT))
end

function T.commit_cleanup_failure_leaves_commit_only_residue_safe()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local root = "data/generated/alpha"
  c:write(root .. "/value", "old")
  local tx = ArtifactPublisher.begin(c, "commit-cleanup", { root })
  tx.stage:write(root .. "/value", "new")
  local originalRemove = backend.remove
  backend.remove = function(self, path)
    if path == PUBLISH_COMMIT then
      return false, "injected commit cleanup failure"
    end
    return originalRemove(self, path)
  end

  local err = Assert.throws(function()
    tx:publish()
  end)

  Assert.equal(err.code, StorageErrors.CACHE_PUBLISH_CLEANUP_FAILED)
  Assert.equal(c:read(root .. "/value"), "new")
  Assert.isNil(backend:getInfo(PUBLISH_MANIFEST))
  Assert.notNil(backend:getInfo(PUBLISH_COMMIT))
  backend.remove = originalRemove
  c:recoverPublication()
  Assert.isNil(backend:getInfo(PUBLISH_COMMIT))
end

function T.contradictory_root_metadata_fails_before_live_mutation()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local root = "data/generated/alpha"
  c:write(root .. "/value", "live")
  backend:write(siblingRoot(root, ".__g4old") .. "/value", "old")
  writePublicationRecord(backend, { { path = root, hadLive = false } })

  local ok, err = pcall(function()
    c:recoverPublication()
  end)

  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(err))
  Assert.equal(assert(err).code, StorageErrors.CACHE_PUBLISH_ROLLBACK_INCOMPLETE)
  Assert.equal(c:read(root .. "/value"), "live")
  Assert.equal(backend.files[siblingRoot(root, ".__g4old") .. "/value"], "old")
end

return { tests = T }
