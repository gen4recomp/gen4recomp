-- SaveFs tests: the persistent save namespace is version-scoped, confined to
-- its own root, and structurally unreachable by any cache-clearing operation
-- (version-root removal, ROM re-extraction). Cache rebuilding must never be
-- able to delete a save. Test isolation is backend-level (a remapping
-- backend wrapper), never a production rooting mode.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local SaveFs = require("libs.storage.src.SaveFs")
local StorageErrors = require("libs.storage.src.errors")
local FakeCache = require("tests.support.FakeCache")
local RemapBackend = require("tests.support.RemapBackend")

local T = {}

local SAVE_PATH = "field-session.lua"

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.equal(err.code, code, "expected " .. code .. ", got " .. tostring(err))
end

-- Real-backend construction would write into the production save namespace
-- (saves/<versionId>/) under the g4recomp identity, so every test injects the
-- in-memory fake.
local function save(versionId, backend)
  return SaveFs.forVersion(versionId, backend or FakeCache.new())
end

function T.prefix_roots_at_the_user_data_namespace()
  Assert.equal(save("heartgold"):prefix(), "saves/heartgold/")
  Assert.equal(save("soulsilver"):prefix(), "saves/soulsilver/")
end

function T.global_root_contains_catalog_and_game_namespaces()
  local backend = FakeCache.new()
  local global = SaveFs.global(backend)
  Assert.equal(global:prefix(), "saves/")
  global:write("catalog.lua", "CATALOG")
  global:write("games/save-00000001.lua", "GAME")
  Assert.equal(backend.files["saves/catalog.lua"], "CATALOG")
  Assert.equal(backend.files["saves/games/save-00000001.lua"], "GAME")
end

function T.global_root_rejects_escape_paths()
  throwsCode(StorageErrors.SAVE_PATH_INVALID, function()
    SaveFs.global(FakeCache.new()):write("games/../catalog.lua", "x")
  end)
end

-- Version ids are structural path components, not ROM identities: any safe
-- component names its own namespace. Which ids exist is romdump's GameVersion
-- business; generic persistence must not depend on it.
function T.version_ids_are_structural_not_catalogued()
  Assert.equal(save("custom"):prefix(), "saves/custom/")
  Assert.equal(save("hg-2"):prefix(), "saves/hg-2/")
end

function T.rejects_unsafe_version_ids()
  Assert.throws(function()
    save("../escape")
  end)
  Assert.throws(function()
    save("a/b")
  end)
  Assert.throws(function()
    save("")
  end)
  Assert.throws(function()
    save("a\\b")
  end)
end

-- Test isolation is backend-level: the production constructor has one
-- rooting rule (saves/<versionId>/), and a test that needs a different
-- physical namespace remaps the backend into it.
function T.test_isolation_remaps_the_save_root_into_a_namespace()
  local backend = FakeCache.new()
  local remapped = RemapBackend.new(backend, function(path)
    return (path:gsub("^saves/heartgold/", "acceptance/heartgold/1/"))
  end)
  local s = SaveFs.forVersion("heartgold", remapped)
  Assert.equal(s:prefix(), "saves/heartgold/", "the production root is the only rooting rule")
  s:write(SAVE_PATH, "SAVE-DATA")
  Assert.isNil(backend.files["saves/heartgold/" .. SAVE_PATH], "the real save root must stay untouched")
  Assert.equal(backend.files["acceptance/heartgold/1/" .. SAVE_PATH], "SAVE-DATA")
end

function T.write_lands_below_the_save_root()
  local backend = FakeCache.new()
  save("heartgold", backend):write(SAVE_PATH, "SAVE-DATA")
  Assert.equal(backend.files["saves/heartgold/" .. SAVE_PATH], "SAVE-DATA")
  Assert.isNil(backend.files["heartgold/" .. SAVE_PATH], "a save must never land in the cache root")
end

function T.read_round_trips_written_bytes()
  local s = save("heartgold")
  s:write(SAVE_PATH, "SAVE-DATA")
  Assert.equal(s:read(SAVE_PATH), "SAVE-DATA")
end

-- One version's saves must never be visible to or cleared by another's.
function T.versions_are_isolated()
  local backend = FakeCache.new()
  local hg = save("heartgold", backend)
  local ss = save("soulsilver", backend)
  hg:write(SAVE_PATH, "HG")
  ss:write(SAVE_PATH, "SS")
  Assert.equal(hg:read(SAVE_PATH), "HG")
  Assert.equal(ss:read(SAVE_PATH), "SS")
  ss:remove(SAVE_PATH)
  Assert.equal(hg:read(SAVE_PATH), "HG")
  Assert.isNil(ss:read(SAVE_PATH))
end

function T.rejects_absolute_paths()
  throwsCode(StorageErrors.SAVE_PATH_INVALID, function()
    save("heartgold"):write("/etc/passwd", "x")
  end)
end

function T.rejects_drive_letters()
  throwsCode(StorageErrors.SAVE_PATH_INVALID, function()
    save("heartgold"):write("C:/x", "x")
  end)
end

function T.rejects_parent_components()
  throwsCode(StorageErrors.SAVE_PATH_INVALID, function()
    save("heartgold"):read("../soulsilver/" .. SAVE_PATH)
  end)
  throwsCode(StorageErrors.SAVE_PATH_INVALID, function()
    save("heartgold"):read("a/../../b")
  end)
end

function T.rejects_dot_and_nul_components()
  throwsCode(StorageErrors.SAVE_PATH_INVALID, function()
    save("heartgold"):read("a/./b")
  end)
  throwsCode(StorageErrors.SAVE_PATH_INVALID, function()
    save("heartgold"):read("a\0b")
  end)
end

function T.lua_round_trip_is_deterministic()
  local s = save("heartgold")
  local value = { schema = "g4-field-save-v1", events = { flags = {}, vars = {} } }
  s:writeLua(SAVE_PATH, value)
  Assert.deepEqual(s:loadLua(SAVE_PATH), value)
end

function T.atomic_replace_moves_a_file_over_its_destination()
  local s = save("heartgold")
  s:write(SAVE_PATH, "old")
  s:write(SAVE_PATH .. ".tmp", "new")
  s:replace(SAVE_PATH .. ".tmp", SAVE_PATH)
  Assert.equal(s:read(SAVE_PATH), "new")
  Assert.isNil(s:read(SAVE_PATH .. ".tmp"))
end

function T.load_lua_missing_is_a_missing_file_error()
  local data, err = save("heartgold"):loadLua("absent.lua")
  Assert.isNil(data)
  Assert.isTrue(
    err ~= nil and err.code == StorageErrors.SAVE_FILE_MISSING,
    "expected " .. StorageErrors.SAVE_FILE_MISSING .. ", got " .. tostring(err)
  )
end

-- An actual backend read failure is not a missing save: the load boundary
-- must keep the two apart, or a save that exists but cannot be read would be
-- silently treated as absent (and the session restarted fresh). The backend
-- shape (a file getInfo reports present, read returns nil + an error string)
-- is exactly what the LÖVE filesystem backend produces.
function T.load_lua_read_failure_is_not_reclassified_as_missing()
  local backend = FakeCache.new()
  local s = save("heartgold", backend)
  s:write(SAVE_PATH, "SAVE-DATA")
  backend.read = function(_, _)
    return nil, "injected read failure"
  end
  local data, err = s:loadLua(SAVE_PATH)
  Assert.isNil(data)
  Assert.isTrue(
    err ~= nil and err.code == StorageErrors.SAVE_READ_FAILED,
    "expected " .. StorageErrors.SAVE_READ_FAILED .. ", got " .. tostring(err)
  )
  Assert.isTrue(
    tostring(err):find("injected read failure", 1, true) ~= nil,
    "the backend read error must survive to the load boundary: " .. tostring(err)
  )
end

-- The two scoped types remain separate public surfaces: the shared
-- mechanics must never leak cache-only capabilities (tree deletion, staged
-- publication, module loading) into the save type, or a save-carrying
-- object could gain a cache-clearing operation.
function T.save_surface_has_no_cache_capabilities()
  local s = save("heartgold")
  local c = CacheFs.forVersion("heartgold", FakeCache.new())
  for _, name in ipairs({ "removeTree", "removeStagedTree", "publishStaged", "publishFromStage", "loadModule" }) do
    Assert.isNil(s[name], "SaveFs must not expose " .. name)
    Assert.notNil(c[name], "CacheFs must expose " .. name)
  end
end

-- The umbrella structural invariant: the disposable version cache root and the
-- persistent save root are sibling namespaces, so wiping a version cache can
-- never delete a save.
function T.removing_the_version_cache_root_cannot_reach_saves()
  local backend = FakeCache.new()
  local saveFs = SaveFs.forVersion("heartgold", backend)
  local cacheFs = CacheFs.forVersion("heartgold", backend)
  saveFs:write(SAVE_PATH, "SAVE-DATA")
  cacheFs:write("rom-dump.complete", "MARKER")
  cacheFs:write("romfs/a/0/0/2", "DATA")
  cacheFs:removeTree("")
  Assert.equal(backend.files["saves/heartgold/" .. SAVE_PATH], "SAVE-DATA")
  Assert.isNil(backend.files["heartgold/rom-dump.complete"])
  Assert.isNil(backend.files["heartgold/romfs/a/0/0/2"])
end

-- Mutating save operations must translate a backend-reported failure into
-- a structured save error instead of silently returning true.
function T.write_reports_backend_failure()
  local backend = FakeCache.new()
  backend.write = function()
    return false, "injected write failure"
  end
  throwsCode(StorageErrors.SAVE_WRITE_FAILED, function()
    save("heartgold", backend):write(SAVE_PATH, "x")
  end)
end

function T.write_reports_parent_directory_failure()
  local backend = FakeCache.new()
  backend.createDirectory = function()
    return false, "injected mkdir failure"
  end
  throwsCode(StorageErrors.SAVE_MKDIR_FAILED, function()
    save("heartgold", backend):write("dir/" .. SAVE_PATH, "x")
  end)
end

function T.remove_reports_backend_failure()
  local backend = FakeCache.new()
  local s = save("heartgold", backend)
  s:write(SAVE_PATH, "x")
  backend.remove = function()
    return false, "injected remove failure"
  end
  throwsCode(StorageErrors.SAVE_REMOVE_FAILED, function()
    s:remove(SAVE_PATH)
  end)
end

-- A missing save file is not a failure: reset must be able to run before the
-- first save exists, so absent paths are an explicit no-op.
function T.remove_absent_path_is_a_noop()
  local backend = FakeCache.new()
  backend.remove = function()
    error("backend must not be asked to remove an absent path")
  end
  Assert.isTrue(save("heartgold", backend):remove("absent.lua"))
end

function T.replace_reports_backend_failure()
  local backend = FakeCache.new()
  local s = save("heartgold", backend)
  s:write(SAVE_PATH .. ".tmp", "new")
  backend.replace = function()
    return false, "injected replace failure"
  end
  throwsCode(StorageErrors.SAVE_REPLACE_FAILED, function()
    s:replace(SAVE_PATH .. ".tmp", SAVE_PATH)
  end)
end

return { tests = T }
