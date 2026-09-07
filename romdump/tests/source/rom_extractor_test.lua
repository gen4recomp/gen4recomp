local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local RomExtractor = require("romdump.src.source.RomExtractor")
local RomImporter = require("romdump.src.source.RomImporter")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local DumpFixture = require("tests.support.DumpFixture")

local T = {}

local HG = "heartgold/"

local function extractOk(opts)
  local r = DumpFixture.extract(opts)
  Assert.notNil(r.report, "expected extraction to succeed: " .. tostring(r.err))
  return r
end

function T.writes_every_fat_entry_once()
  local r = extractOk()
  local files = r.backend.files
  -- One overlay, one unmapped, five named NitroFS files.
  Assert.notNil(files[HG .. "system/overlay9/overlay_0.bin"])
  Assert.notNil(files[HG .. "system/unmapped/file_1.bin"])
  Assert.equal(files[HG .. "romfs/a/0/0/2"], require("tests.support.NarcBuilder").build({ "P0", "P1" }))
  Assert.notNil(files[HG .. "romfs/a/0/4/1"])
  Assert.equal(files[HG .. "romfs/data/sound/gs_sound_data.sdat"], "SDAT-STUB")
  Assert.equal(r.report.fatEntryCount, 7)
  Assert.equal(r.report.unmappedFileCount, 1)
end

function T.writes_raw_system_sections()
  local r = extractOk()
  local files = r.backend.files
  Assert.equal(#files[HG .. "system/header.bin"], 0x200)
  Assert.notNil(files[HG .. "system/fnt.bin"])
  Assert.notNil(files[HG .. "system/fat.bin"])
  Assert.notNil(files[HG .. "system/arm9.bin"])
  Assert.notNil(files[HG .. "system/arm9_overlay_table.bin"])
end

function T.writes_marker_last_with_exact_content()
  local RawDumpContract = require("romdump.src.source.RawDumpContract")
  local r = extractOk()
  local marker = r.backend.files[HG .. RawDumpContract.MARKER_PATH]
  local info = require("romdump.src.source.GameVersion").info("heartgold")
  Assert.equal(marker, RomExtractor.markerContent("heartgold", info.sha1))
end

function T.resolves_required_narcs_and_smoke_decodes()
  local r = extractOk()
  Assert.equal(r.report.resolvedRequiredNarcCount, 4)
  Assert.equal(r.report.matrix.width, 2)
  Assert.equal(r.report.matrix.height, 2)
  Assert.equal(r.report.matrix.name, "MM")
  Assert.equal(r.report.matrix.modelCellCount, 4)
  Assert.isNil(r.report.parserWarnings, "the always-empty parserWarnings field must be gone")
  Assert.isTrue(type(r.report.narcWarnings) == "table", "narcWarnings must remain the populated warning field")
end

-- A required NARC path missing from the FNT aborts before the marker is written.
function T.no_marker_on_required_narc_failure()
  local spec = DumpFixture.spec()
  local aZero = spec.tree.dirs[1].dirs[1].dirs -- a/0/{0,1,2,4}
  table.remove(aZero, 4) -- drop a/0/4 (map_matrices)
  local r = DumpFixture.extract({ spec = spec })
  Assert.isNil(r.report, "expected extraction to fail")
  Assert.isTrue(Errors.is(r.err))
  Assert.equal(r.err.code, "EXTRACT_REQUIRED_NARC_MISSING")
  Assert.isNil(r.backend.files["heartgold/rom-dump.complete"], "marker must be absent")
end

function T.generated_indexes_are_deterministic()
  local a = extractOk()
  local b = extractOk()
  for _, name in ipairs({ "rom_metadata", "romfs_index", "overlay_index" }) do
    local path = HG .. "data/generated/" .. name .. ".lua"
    Assert.equal(a.backend.files[path], b.backend.files[path], name .. " must be byte-identical")
  end
end

-- romfs_index round-trips: zero-based fileId keys and named source paths survive.
function T.romfs_index_preserves_zero_based_ids()
  local r = extractOk()
  local index = assert(r.cache:loadLua("data/generated/romfs_index.lua"))
  Assert.equal(index.files[0].kind, "overlay9")
  Assert.equal(index.files[1].kind, "unmapped")
  Assert.equal(index.files[2].sourcePath, "a/0/0/2")
  Assert.equal(index.files[5].sourcePath, "a/0/4/1")
  Assert.equal(index.fileCount, 7)
end

function T.does_not_touch_another_version_prefix()
  local backend = FakeCache.new()
  backend.files["soulsilver/rom-dump.complete"] = "SS-MARKER"
  backend.files["soulsilver/romfs/a/0/0/2"] = "SS-DATA"
  extractOk({ backend = backend })
  Assert.equal(backend.files["soulsilver/rom-dump.complete"], "SS-MARKER")
  Assert.equal(backend.files["soulsilver/romfs/a/0/0/2"], "SS-DATA")
end

function T.progress_is_monotonic_and_reaches_one()
  local last, sawPublish = -1, false
  extractOk({
    progress = function(p)
      Assert.isTrue(p.overall >= last, "overall regressed at stage " .. p.stage)
      last = p.overall
      if p.stage == "publish" then
        sawPublish = true
      end
    end,
  })
  Assert.isTrue(sawPublish, "publish stage must report")
  Assert.equal(last, 1)
end

-- Deep-copy the live-version portion of a FakeCache backend so byte-for-byte
-- preservation can be asserted across a failed extraction.
local function snapshotLive(backend)
  local files, dirs = {}, {}
  for k, v in pairs(backend.files) do
    if k:sub(1, #HG) == HG then
      files[k] = v
    end
  end
  for k in pairs(backend.dirs) do
    if k:sub(1, #HG) == HG then
      dirs[k] = true
    end
  end
  return files, dirs
end

local function assertLiveUnchanged(backend, files, dirs)
  for k, v in pairs(files) do
    Assert.equal(backend.files[k], v, "live file changed: " .. k)
  end
  for k in pairs(dirs) do
    Assert.isTrue(backend.dirs[k], "live dir removed: " .. k)
  end
  for k, v in pairs(backend.files) do
    if k:sub(1, #HG) == HG then
      Assert.equal(files[k], v, "live file changed: " .. k)
    end
  end
  for k in pairs(backend.dirs) do
    if k:sub(1, #HG) == HG then
      Assert.isTrue(dirs[k], "unexpected live dir: " .. k)
    end
  end
end

-- A failed extraction must leave a previously ready dump untouched and ready:
-- nothing is written to the live root until the staged dump is published, and
-- the failed staging tree is removed immediately rather than lingering until
-- the next import.
function T.failed_extraction_preserves_ready_dump()
  local backend = FakeCache.new()
  extractOk({ backend = backend })
  local files, dirs = snapshotLive(backend)

  local spec = DumpFixture.spec()
  local aZero = spec.tree.dirs[1].dirs[1].dirs -- a/0/{0,1,2,4}
  table.remove(aZero, 4) -- drop a/0/4 (map_matrices)
  local r = DumpFixture.extract({ spec = spec, backend = backend })

  Assert.isNil(r.report, "expected extraction to fail")
  Assert.equal(r.err.code, "EXTRACT_REQUIRED_NARC_MISSING")
  assertLiveUnchanged(backend, files, dirs)
  local cache = CacheFs.forVersion("heartgold", backend)
  Assert.isTrue(RomImporter.isReady("heartgold", cache), "previous dump must remain ready after a failed extraction")
  Assert.isNil(
    backend.files["staging/heartgold/rom-dump.complete"],
    "a partial staged dump must never expose its marker"
  )
  local stagingPrefix = "staging/heartgold/"
  Assert.isNil(backend.dirs["staging/heartgold"], "the failed staging root must be removed immediately")
  for k in pairs(backend.files) do
    Assert.isFalse(k:sub(1, #stagingPrefix) == stagingPrefix, "no staging file may survive a failed extraction: " .. k)
  end
end

-- A successful extraction replaces the previous dump: the old tree is dropped
-- only after the staged tree lands, and no staging residue survives.
function T.successful_extraction_replaces_dump_and_cleans_staging()
  local backend = FakeCache.new()
  extractOk({ backend = backend })
  backend.files[HG .. "stray.txt"] = "OLD-STRAY"

  local spec = DumpFixture.spec()
  spec.tree.dirs[2].dirs[1].files[1].content = "SDAT-STUB-2"
  extractOk({ spec = spec, backend = backend })

  Assert.equal(backend.files[HG .. "romfs/data/sound/gs_sound_data.sdat"], "SDAT-STUB-2")
  Assert.isNil(backend.files[HG .. "stray.txt"], "previous dump contents must be gone")
  Assert.isTrue(RomImporter.isReady("heartgold", CacheFs.forVersion("heartgold", backend)))
  Assert.isNil(backend.files["staging/heartgold/rom-dump.complete"], "no staging residue")
  Assert.isNil(backend.dirs["staging/heartgold"], "no staging residue")
  Assert.isNil(backend.files["staging/heartgold.old/romfs/a/0/0/2"], "no orphaned old root")
end

-- Stale staging output (including a plausible-looking staging marker) must
-- never make the live version ready, and the next import discards it.
function T.stale_staging_does_not_make_ready_and_is_cleaned()
  local backend = FakeCache.new()
  backend.files["staging/heartgold/rom-dump.complete"] = "STALE-MARKER"
  backend.files["staging/heartgold/romfs/a/0/0/2"] = "STALE-DATA"
  local cache = CacheFs.forVersion("heartgold", backend)
  Assert.isFalse(RomImporter.isReady("heartgold", cache), "staging must never imply readiness")

  extractOk({ backend = backend })
  Assert.isNil(backend.files["staging/heartgold/romfs/a/0/0/2"], "stale staging must be cleaned")
end

-- A failure while the staged tree is being moved into place restores the
-- previous live root and re-raises the original failure, so a failed publish
-- keeps the old dump ready. From the moment publish begins the staged tree is
-- recovery material: run() must not remove it, and the next import discards it.
function T.failed_publish_restores_previous_dump()
  local backend = FakeCache.new()
  extractOk({ backend = backend })
  local files, dirs = snapshotLive(backend)

  local originalReplace = backend.replace
  backend.replace = function(self, sourcePath, destinationPath)
    if sourcePath == "staging/heartgold" then
      error(Errors.new("CACHE_REPLACE_FAILED", "injected publish failure", { sourcePath = sourcePath }))
    end
    return originalReplace(self, sourcePath, destinationPath)
  end
  local r = DumpFixture.extract({ backend = backend })

  Assert.isNil(r.report, "expected extraction to fail")
  Assert.equal(r.err.code, "CACHE_REPLACE_FAILED")
  assertLiveUnchanged(backend, files, dirs)
  Assert.isTrue(RomImporter.isReady("heartgold", CacheFs.forVersion("heartgold", backend)))
  Assert.isNil(backend.files["staging/heartgold.old/romfs/a/0/0/2"], "no orphaned old root after rollback")
  Assert.notNil(
    backend.files["staging/heartgold/rom-dump.complete"],
    "run() must not remove the staged tree once publish has begun"
  )
end

-- Once publish has begun, run() must not remove the staging tree or the
-- recovery material: an incomplete rollback leaves the previous dump at the
-- aside root, the only remaining copy of the last-known-good artifact.
function T.failed_publish_keeps_recovery_material_in_staging()
  local backend = FakeCache.new()
  extractOk({ backend = backend })
  local oldPersonal = backend.files[HG .. "romfs/a/0/0/2"]
  local newPersonal = require("tests.support.NarcBuilder").build({ "P0", "P1", "P2" })
  local originalReplace = backend.replace
  backend.replace = function(self, sourcePath, destinationPath)
    if sourcePath == "staging/heartgold" or sourcePath == "staging/heartgold.old" then
      return false, "injected publish failure"
    end
    return originalReplace(self, sourcePath, destinationPath)
  end
  local spec = DumpFixture.spec()
  spec.tree.dirs[1].dirs[1].dirs[1].files[1].content = newPersonal
  local r = DumpFixture.extract({ spec = spec, backend = backend })

  Assert.isNil(r.report, "expected extraction to fail")
  Assert.equal(r.err.code, "CACHE_PUBLISH_ROLLBACK_INCOMPLETE")
  Assert.equal(
    backend.files["staging/heartgold.old/romfs/a/0/0/2"],
    oldPersonal,
    "the last-known-good dump stays in the aside root"
  )
  Assert.equal(backend.files["staging/heartgold/romfs/a/0/0/2"], newPersonal, "the staged dump stays in place")
end

return { tests = T }
