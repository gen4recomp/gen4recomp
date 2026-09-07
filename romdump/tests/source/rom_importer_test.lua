local Assert = require("tests.support.Assert")
local RomImporter = require("romdump.src.source.RomImporter")
local RomSource = require("romdump.src.source.RomSource")
local NdsBuilder = require("tests.support.NdsBuilder")
local DumpFixture = require("tests.support.DumpFixture")
local CacheFs = require("libs.storage.src.CacheFs")
local SaveFs = require("libs.storage.src.SaveFs")
local FakeCache = require("tests.support.FakeCache")

local T = {}

local HG = "heartgold/"

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.equal(err.code, code, "expected " .. code .. ", got " .. tostring(err))
end

-- Build a synthetic HGSS ROM plus a version catalog that accepts exactly it under
-- the real "heartgold" identity, so the importer's marker/readiness logic aligns.
-- `now` is static, which disables yielding: a single update() runs to completion.
local function harness(spec)
  local data = NdsBuilder.build(spec or DumpFixture.spec())
  local sha1 = RomSource.fromString(data):sha1()
  local info = {
    id = "heartgold",
    label = "HeartGold",
    displayName = "Pokemon HeartGold",
    sha1 = sha1,
    gameCode = "IPKE",
    expectedSize = #data,
    cachePrefix = "heartgold/",
  }
  local versions = {
    info = function(id)
      return id == "heartgold" and info or nil
    end,
    forSha1 = function(h)
      return h == sha1 and info or nil
    end,
    forGameCode = function(c)
      return c == "IPKE" and info or nil
    end,
  }
  local backend = FakeCache.new()
  local events = {}
  local importer = RomImporter.new({
    versions = versions,
    now = function()
      return 0
    end,
    cacheFactory = function(id)
      return CacheFs.forVersion(id, backend)
    end,
    onComplete = function(id)
      events[#events + 1] = id
    end,
  })
  return { data = data, info = info, versions = versions, backend = backend, importer = importer, events = events }
end

-- Drive update() until the importer reaches a terminal state (or a step cap).
local function runToTerminal(importer)
  for _ = 1, 10000 do
    importer:update()
    if importer.state == "complete" or importer.state == "error" then
      return
    end
  end
  error("importer did not terminate")
end

-- An ever-advancing clock forces a yield at every progress tick, exercising the
-- coroutine-yield-across-pcall path the real import relies on under LuaJIT.
function T.yields_and_still_completes_across_pcall()
  local h = harness()
  local t = 0
  local importer = RomImporter.new({
    versions = h.versions,
    now = function()
      t = t + 1
      return t
    end,
    cacheFactory = function(id)
      return CacheFs.forVersion(id, h.backend)
    end,
  })
  importer:startSource(RomSource.fromString(h.data))
  local ticks = 0
  for _ = 1, 10000 do
    importer:update()
    ticks = ticks + 1
    if importer.state == "complete" or importer.state == "error" then
      break
    end
  end
  Assert.equal(importer.state, "complete")
  Assert.isTrue(ticks > 1, "expected the import to span multiple update() slices")
end

function T.imports_synthetic_rom_to_completion()
  local h = harness()
  h.importer:startSource(RomSource.fromString(h.data, "hg.nds"))
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, "complete")
  Assert.equal(h.importer:status().versionId, "heartgold")
  Assert.equal(h.importer.progress, 1)
  Assert.isTrue(RomImporter.isReady("heartgold", CacheFs.forVersion("heartgold", h.backend), h.versions))
  Assert.equal(h.events[1], "heartgold")
end

-- Validation (SHA-1/header) must fully precede any cache write (E8-S1), and
-- nothing in the import lifecycle may touch the persistent save namespace.
function T.validation_precedes_cache_cleanup()
  local h = harness()
  -- Pre-seed a marker, a stray file, and a save; an unknown ROM must leave all
  -- of them intact.
  h.backend.files[HG .. "rom-dump.complete"] = "STALE"
  h.backend.files[HG .. "stray"] = "KEEP"
  h.backend.files["saves/heartgold/field-session.lua"] = "SAVE-DATA"
  -- A version catalog that recognizes nothing => NdsRom.open rejects by SHA-1.
  local blind = { info = function() end, forSha1 = function() end, forGameCode = function() end }
  local importer = RomImporter.new({
    versions = blind,
    now = function()
      return 0
    end,
    cacheFactory = function(id)
      return CacheFs.forVersion(id, h.backend)
    end,
  })
  importer:startSource(RomSource.fromString(h.data))
  runToTerminal(importer)
  Assert.equal(importer.state, "error")
  Assert.equal(importer:status().errorCode, "NDS_UNKNOWN_ROM")
  Assert.equal(h.backend.files[HG .. "rom-dump.complete"], "STALE")
  Assert.equal(h.backend.files[HG .. "stray"], "KEEP")
  Assert.equal(h.backend.files["saves/heartgold/field-session.lua"], "SAVE-DATA")
end

-- A dropped non-.nds file is rejected with a friendly error before any read,
-- leaving caches untouched (E8-S3).
function T.rejects_non_nds_drop()
  local importer = RomImporter.new({
    now = function()
      return 0
    end,
  })
  local stub = {
    getFilename = function()
      return "photo.png"
    end,
  }
  importer:filedropped(stub)
  Assert.equal(importer.state, "error")
  Assert.equal(importer:status().errorCode, "IMPORT_NOT_NDS")
end

function T.releases_rom_on_completion()
  local h = harness()
  local source = RomSource.fromString(h.data)
  h.importer:startSource(source)
  runToTerminal(h.importer)
  -- Source is released: further reads fail predictably.
  local bytes, err = source:read(0, 4)
  Assert.isNil(bytes)
  Assert.equal(assert(err).code, "ROM_RELEASED")
end

function T.progress_is_monotonic()
  local h = harness()
  local last = -1
  -- Wrap onProgress by observing status each update.
  h.importer:startSource(RomSource.fromString(h.data))
  for _ = 1, 10000 do
    h.importer:update()
    local p = h.importer.progress or 0
    Assert.isTrue(p >= last, "progress regressed: " .. p .. " < " .. last)
    last = p
    if h.importer.state == "complete" or h.importer.state == "error" then
      break
    end
  end
  Assert.equal(h.importer.state, "complete")
  Assert.equal(last, 1)
end

-- An explicitly supplied ROM is always dumped fresh: re-importing a ready
-- version re-extracts rather than skipping.
function T.reimport_always_extracts()
  local h = harness()
  h.importer:startSource(RomSource.fromString(h.data))
  runToTerminal(h.importer)
  Assert.notNil(h.importer:status().report)

  local again = RomImporter.new({
    versions = h.versions,
    now = function()
      return 0
    end,
    cacheFactory = function(id)
      return CacheFs.forVersion(id, h.backend)
    end,
  })
  again:startSource(RomSource.fromString(h.data))
  runToTerminal(again)
  Assert.equal(again.state, "complete")
  Assert.notNil(again:status().report, "a fresh extraction is always performed")
end

-- The extraction rebuild wipes the version cache root; a persisted save in the
-- sibling user-data namespace must survive the full production re-import --
-- including a save of another version, which shares the save root but never the
-- disposable cache root.
function T.reimport_preserves_saves()
  local h = harness()
  SaveFs.forVersion("heartgold", h.backend):write("field-session.lua", "SAVE-DATA")
  SaveFs.forVersion("soulsilver", h.backend):write("field-session.lua", "SS-SAVE")
  h.importer:startSource(RomSource.fromString(h.data))
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, "complete")
  Assert.equal(h.backend.files["saves/heartgold/field-session.lua"], "SAVE-DATA")
  Assert.equal(h.backend.files["saves/soulsilver/field-session.lua"], "SS-SAVE")
  Assert.isTrue(RomImporter.isReady("heartgold", CacheFs.forVersion("heartgold", h.backend), h.versions))
end

-- A re-import that fails mid-extraction must leave the previous ready dump
-- byte-for-byte intact and ready, with the save untouched.
function T.failed_reimport_preserves_previous_dump_and_saves()
  local h = harness()
  SaveFs.forVersion("heartgold", h.backend):write("field-session.lua", "SAVE-DATA")
  h.importer:startSource(RomSource.fromString(h.data))
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, "complete")
  local snapshot = {}
  for k, v in pairs(h.backend.files) do
    snapshot[k] = v
  end

  local originalWrite = h.backend.write
  h.backend.write = function(self, path, data)
    if path:find("romfs/data/sound", 1, true) then
      error("injected write failure")
    end
    return originalWrite(self, path, data)
  end
  local again = RomImporter.new({
    versions = h.versions,
    now = function()
      return 0
    end,
    cacheFactory = function(id)
      return CacheFs.forVersion(id, h.backend)
    end,
  })
  again:startSource(RomSource.fromString(h.data))
  runToTerminal(again)
  h.backend.write = originalWrite

  Assert.equal(again.state, "error", "injected failure must fail the import")
  for k, v in pairs(snapshot) do
    Assert.equal(h.backend.files[k], v, "live state changed: " .. k)
  end
  Assert.equal(h.backend.files["saves/heartgold/field-session.lua"], "SAVE-DATA")
  Assert.isTrue(RomImporter.isReady("heartgold", CacheFs.forVersion("heartgold", h.backend), h.versions))
  Assert.isNil(h.backend.dirs["staging/heartgold"], "a failed re-import must remove its staging tree immediately")
  Assert.isNil(
    h.backend.files["staging/heartgold/romfs/a/0/0/2"],
    "a failed re-import must leave no partial staging files"
  )
end

-- A successful import leaves no staging residue: the staged tree is moved into
-- the live root and the staging namespace is gone.
function T.import_leaves_no_staging_residue()
  local h = harness()
  h.importer:startSource(RomSource.fromString(h.data))
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, "complete")
  Assert.isNil(h.backend.files["staging/heartgold/rom-dump.complete"], "staging marker must not survive")
  Assert.isNil(h.backend.dirs["staging/heartgold"], "staging root must be gone")
  Assert.isNil(h.backend.files["staging/heartgold.old/romfs/a/0/0/2"], "no orphaned old root")
end

-- An import that has started but is still running. The active source and
-- coroutine identity are the state the busy rejection must leave untouched.
local function busyImporter()
  local h = harness()
  h.importer:startSource(RomSource.fromString(h.data, "first.nds"))
  Assert.equal(h.importer.state, "reading")
  return h
end

-- While busy, every start API rejects the new request with a structured
-- IMPORT_BUSY error and leaves the active import untouched.
function T.busy_rejects_all_start_apis_unchanged()
  local h = busyImporter()
  local source, co = h.importer._source, h.importer._co
  throwsCode("IMPORT_BUSY", function()
    h.importer:startSource(RomSource.fromString(h.data, "second.nds"))
  end)
  throwsCode("IMPORT_BUSY", function()
    h.importer:startPath("second.nds")
  end)
  throwsCode("IMPORT_BUSY", function()
    h.importer:startDroppedFile({
      getFilename = function()
        return "second.nds"
      end,
    })
  end)
  Assert.equal(h.importer._source, source, "active source must be unchanged")
  Assert.equal(h.importer._co, co, "active coroutine must be unchanged")
  Assert.equal(h.importer.state, "reading")
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, "complete")
  Assert.equal(h.events[1], "heartgold")
end

-- An invalid drop while busy is rejected with IMPORT_BUSY and must NOT route
-- the active importer through _fail (which would release the active source).
function T.busy_invalid_drop_leaves_active_import_unchanged()
  local h = busyImporter()
  throwsCode("IMPORT_BUSY", function()
    h.importer:filedropped({
      getFilename = function()
        return "photo.png"
      end,
    })
  end)
  Assert.equal(h.importer.state, "reading", "busy rejection must not fail the active import")
  Assert.isNil(h.importer._errorCode)
  Assert.notNil(h.importer._source, "active source must remain held")
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, "complete")
  Assert.equal(h.importer:status().versionId, "heartgold")
end

-- Busy rejection never releases the active source; the terminal transition
-- releases it exactly once.
function T.busy_rejection_never_releases_and_terminal_release_is_exactly_once()
  local h = harness()
  local first = RomSource.fromString(h.data, "first.nds")
  local releases = 0
  local baseRelease = first.release
  first.release = function(self)
    releases = releases + 1
    return baseRelease(self)
  end
  h.importer:startSource(first)
  throwsCode("IMPORT_BUSY", function()
    h.importer:startSource(RomSource.fromString(h.data, "second.nds"))
  end)
  throwsCode("IMPORT_BUSY", function()
    h.importer:filedropped({
      getFilename = function()
        return "photo.png"
      end,
    })
  end)
  Assert.equal(releases, 0, "busy rejection must not release the active source")
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, "complete")
  Assert.equal(releases, 1, "the terminal transition must release the source exactly once")
  local bytes, err = first:read(0, 4)
  Assert.isNil(bytes)
  Assert.equal(assert(err).code, "ROM_RELEASED")
end

-- The busy guard must not lock the importer after a terminal state: a
-- completed or failed importer accepts a fresh start (App no longer exercises
-- this — it starts a fresh importer per session — but the restart capability
-- is the importer's own contract).
function T.terminal_importer_accepts_a_fresh_start()
  local h = harness()
  h.importer:startSource(RomSource.fromString(h.data))
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, "complete")
  h.importer:startSource(RomSource.fromString(h.data, "again.nds"))
  Assert.equal(h.importer.state, "reading")
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, "complete")
  Assert.equal(h.events[1], "heartgold")
  Assert.equal(h.events[2], "heartgold")

  h.importer:filedropped({
    getFilename = function()
      return "photo.png"
    end,
  })
  Assert.equal(h.importer.state, "error")
  h.importer:startSource(RomSource.fromString(h.data, "third.nds"))
  Assert.equal(h.importer.state, "reading")
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, "complete")
  Assert.equal(h.events[3], "heartgold")
end

-- The importer's state strings are one named vocabulary: every state the
-- production consumers (App, the import screen, the CLI runner) compare
-- against is exposed as a RomImporter.STATES constant, and every transition
-- lands on one of those named states.
function T.importer_states_are_named_constants()
  for _, name in ipairs({ "IDLE", "READING", "VERIFYING", "EXTRACTING", "COMPLETE", "ERROR" }) do
    Assert.equal("string", type(RomImporter.STATES[name]), "RomImporter.STATES." .. name .. " must be a named state")
  end
  local fresh = RomImporter.new({
    now = function()
      return 0
    end,
  })
  Assert.equal(fresh.state, RomImporter.STATES.IDLE)
  fresh:filedropped({
    getFilename = function()
      return "photo.png"
    end,
  })
  Assert.equal(fresh.state, RomImporter.STATES.ERROR)
  local h = harness()
  h.importer:startSource(RomSource.fromString(h.data))
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, RomImporter.STATES.COMPLETE)
end

return { tests = T }
