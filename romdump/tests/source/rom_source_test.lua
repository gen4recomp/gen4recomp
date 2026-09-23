local Assert = require("tests.support.Assert")
local RomSource = require("romdump.src.source.RomSource")
local ZipBuilder = require("tests.support.ZipBuilder")
local NdsBuilder = require("tests.support.NdsBuilder")
local DumpFixture = require("tests.support.DumpFixture")

-- SHA-1("abc") — the canonical test vector.
local ABC_SHA1 = "a9993e364706816aba3e25717850c26c9cd0d89d"

local T = {}

-- A version catalog that recognizes exactly the given SHA-1 (as DumpFixture does).
local function versionsFor(sha1)
  return {
    forSha1 = function(h)
      return h == sha1 and {} or nil
    end,
  }
end

-- The mount point RomSource mounts zip archives at (exported by RomSource so
-- a leaked mount is directly observable).
local MOUNT_POINT = RomSource.MOUNT_POINT

-- Run fn with target[field] temporarily replaced by makePatched(original),
-- restoring the original in all cases so a failed assertion cannot leak the
-- patch into later tests.
local function withPatched(target, field, makePatched, fn)
  local original = target[field]
  target[field] = makePatched(original)
  local ok, err = pcall(fn)
  target[field] = original
  if not ok then
    error(err, 0)
  end
end

function T.from_string_reports_size_and_name()
  local s = RomSource.fromString("abcdef", "sample.nds")
  Assert.equal(s:size(), 6)
  Assert.equal(s:displayName(), "sample.nds")
end

function T.read_is_zero_based()
  local s = RomSource.fromString("abcdef")
  Assert.equal(s:read(0, 3), "abc")
  Assert.equal(s:read(3, 3), "def")
end

function T.read_out_of_range_returns_nil_err()
  local s = RomSource.fromString("abc")
  local data, err = s:read(2, 5)
  Assert.isNil(data)
  Assert.notNil(err)
  local d2, e2 = s:read(-1, 1)
  Assert.isNil(d2)
  Assert.notNil(e2)
end

function T.sha1_is_lowercase_hex_and_cached()
  local s = RomSource.fromString("abc")
  local first = s:sha1()
  Assert.equal(first, ABC_SHA1)
  Assert.equal(s:sha1(), first)
end

function T.release_is_idempotent_and_frees_reads()
  local s = RomSource.fromString("abc")
  s:release()
  s:release()
  local data, err = s:read(0, 1)
  Assert.isNil(data)
  Assert.notNil(err)
end

function T.from_path_missing_returns_nil_err()
  local s, err = RomSource.fromPath("/no/such/file.nds")
  Assert.isNil(s)
  Assert.notNil(err)
end

-- Walks a zip (including nested dirs), skips non-.nds junk, and returns the
-- compatible ROM's bytes.
function T.from_zip_finds_compatible_nds()
  local nds = NdsBuilder.build(DumpFixture.spec())
  local sha1 = RomSource.fromString(nds):sha1()
  local zip = ZipBuilder.build({
    { name = "Vimm's Lair.txt", data = "junk" },
    { name = "roms/Pokemon - HeartGold (USA).nds", data = nds },
  })
  local s, err = RomSource.fromZipData(zip, "rom.zip", versionsFor(sha1))
  Assert.notNil(s, err and tostring(err))
  assert(s)
  Assert.equal(s:size(), #nds)
  Assert.equal(s:sha1(), sha1)
  Assert.isTrue(s:read(0, #nds) == nds, "zip-extracted bytes must match the .nds")
end

-- When several .nds are present, the SHA-1-supported one wins.
function T.from_zip_prefers_supported_nds()
  local good = NdsBuilder.build(DumpFixture.spec())
  local goodSha = RomSource.fromString(good):sha1()
  local zip = ZipBuilder.build({
    { name = "patched.nds", data = "not a real rom" },
    { name = "good.nds", data = good },
  })
  local s = assert(RomSource.fromZipData(zip, "rom.zip", versionsFor(goodSha)))
  Assert.equal(s:sha1(), goodSha)
end

-- No .nds inside → a structured error, not a crash.
function T.from_zip_without_nds_errors()
  local zip = ZipBuilder.build({ { name = "a.txt", data = "x" }, { name = "b.sav", data = "y" } })
  local s, err = RomSource.fromZipData(zip, "rom.zip", versionsFor("none"))
  Assert.isNil(s)
  Assert.equal(assert(err).code, "ZIP_NO_NDS")
end

-- A single unsupported .nds is still returned so NdsRom.open can report its hash.
function T.from_zip_falls_back_to_first_nds()
  local zip = ZipBuilder.build({ { name = "only.nds", data = "unsupported bytes" } })
  local s = assert(RomSource.fromZipData(zip, "rom.zip", versionsFor("none")))
  Assert.equal(s:read(0, 17), "unsupported bytes")
end

-- Dropped files arrive as LÖVE File objects; verify the wiring against a stub.
function T.from_dropped_file_reads_contents()
  local stub = {
    open = function()
      return true
    end,
    read = function()
      return "abc"
    end,
    close = function()
      return true
    end,
    getFilename = function()
      return "dropped.nds"
    end,
  }
  local s = assert(RomSource.fromDroppedFile(stub))
  Assert.equal(s:displayName(), "dropped.nds")
  Assert.equal(s:read(0, 3), "abc")
end

-- A failed read of the dropped file is a structured read error, not an assert
-- from constructing a source with nil bytes.
function T.from_dropped_file_read_failure_returns_structured_error()
  local stub = {
    open = function()
      return true
    end,
    read = function()
      return nil
    end,
    close = function()
      return true
    end,
    getFilename = function()
      return "dropped.nds"
    end,
  }
  local s, err = RomSource.fromDroppedFile(stub)
  Assert.isNil(s)
  Assert.equal(assert(err).code, "ROM_READ_FAILED")
end

-- read() requires finite integer offsets and lengths: fractions, NaN,
-- infinities, negatives, and out-of-range values all return a structured read
-- error instead of reaching string.sub.
function T.read_rejects_fractional_nan_infinite_and_negative_arguments()
  local s = RomSource.fromString("abcdef")
  local invalid = {
    { 0.5, 1 },
    { 0, 0.5 },
    { math.huge, 0 },
    { 0, math.huge },
    { -math.huge, 0 },
    { 0, -math.huge },
    { 0 / 0, 1 },
    { 1, 0 / 0 },
    { -1, 1 },
    { 0, -1 },
    { 3, 4 },
  }
  for _, bad in ipairs(invalid) do
    local label = string.format("offset %s length %s", tostring(bad[1]), tostring(bad[2]))
    local data, err = s:read(bad[1], bad[2])
    Assert.isNil(data, label .. " must not return data")
    Assert.equal(assert(err).code, "ROM_READ_OUT_OF_BOUNDS", label)
  end
  Assert.equal(s:read(0, 6), "abcdef")
  Assert.equal(s:read(4, 2), "ef")
end

-- A failed .nds read inside the zip is a structured error, and the archive is
-- unmounted before the error is returned.
function T.zip_read_failure_returns_structured_error_and_unmounts()
  local zip = ZipBuilder.build({ { name = "only.nds", data = "x" } })
  local s, err
  withPatched(love.filesystem, "read", function()
    return function()
      return nil
    end
  end, function()
    s, err = RomSource.fromZipData(zip, "rom.zip", versionsFor("none"))
  end)
  Assert.isNil(s)
  Assert.equal(assert(err).code, "ZIP_READ_FAILED")
  Assert.isNil(love.filesystem.getInfo(MOUNT_POINT), "mount must be unmounted after the read failure")
end

-- When the recursive traversal itself throws, the archive is still unmounted,
-- and the next import sees only its own zip: a leaked mount would otherwise
-- shadow the new archive and silently serve stale bytes.
function T.zip_traversal_failure_unmounts_the_archive()
  local staleZip = ZipBuilder.build({ { name = "stale.nds", data = "stale bytes" } })
  local good = NdsBuilder.build(DumpFixture.spec())
  local goodSha = RomSource.fromString(good):sha1()
  local goodZip = ZipBuilder.build({ { name = "roms/good.nds", data = good } })

  local ok, err
  withPatched(love.filesystem, "read", function()
    return function()
      error("boom: injected traversal failure")
    end
  end, function()
    ok, err = pcall(RomSource.fromZipData, staleZip, "stale.zip", versionsFor("none"))
  end)
  Assert.isFalse(ok, "the traversal error must propagate")
  Assert.isTrue(tostring(err):match("boom"), "the original error must be rethrown")
  Assert.isNil(love.filesystem.getInfo(MOUNT_POINT), "mount must be unmounted after the thrown traversal")

  local s, err2 = RomSource.fromZipData(goodZip, "good.zip", versionsFor(goodSha))
  Assert.notNil(s, err2 and tostring(err2))
  assert(s)
  Assert.equal(s:sha1(), goodSha, "a leaked mount must not shadow the next import")
end

-- Scanning stops at the first supported candidate: entries after it are never
-- read, so a poisoned later entry cannot fail an import that already matched.
-- (love.filesystem lists zip entries in its own deterministic order; for this
-- exact name pair "good.nds" is listed before "poison.nds".)
function T.zip_scan_stops_at_the_first_supported_candidate()
  local good = NdsBuilder.build(DumpFixture.spec())
  local goodSha = RomSource.fromString(good):sha1()
  local zip = ZipBuilder.build({
    { name = "good.nds", data = good },
    { name = "poison.nds", data = "unsupported" },
  })
  local s, err
  withPatched(love.filesystem, "read", function(read)
    return function(path)
      if path:match("poison") then
        error("must not read entries after the first supported candidate")
      end
      return read(path)
    end
  end, function()
    s, err = RomSource.fromZipData(zip, "rom.zip", versionsFor(goodSha))
  end)
  Assert.notNil(s, err and tostring(err))
  assert(s)
  Assert.equal(s:sha1(), goodSha)
end

-- Only the candidates up to the first supported match are read at all; the
-- rest of the archive is never pulled into memory. ("good.nds" is listed
-- first among these names, so exactly one .nds is read.)
function T.zip_scan_reads_only_candidates_up_to_the_first_supported()
  local good = NdsBuilder.build(DumpFixture.spec())
  local goodSha = RomSource.fromString(good):sha1()
  local zip = ZipBuilder.build({
    { name = "good.nds", data = good },
    { name = "u1.nds", data = "one" },
    { name = "u2.nds", data = "two" },
    { name = "u3.nds", data = "three" },
  })
  local reads = 0
  local s, err
  withPatched(love.filesystem, "read", function(read)
    return function(path)
      reads = reads + 1
      return read(path)
    end
  end, function()
    s, err = RomSource.fromZipData(zip, "rom.zip", versionsFor(goodSha))
  end)
  Assert.notNil(s, err and tostring(err))
  assert(s)
  Assert.equal(reads, 1, "only the matching candidate may be read")
  Assert.equal(s:sha1(), goodSha)
end

-- Unsupported candidates are released as they are replaced; at most the
-- current candidate and the first fallback are retained.
function T.zip_scan_releases_replaced_candidates_and_keeps_one_fallback()
  local created, released = 0, 0
  local zip = ZipBuilder.build({
    { name = "u1.nds", data = "one" },
    { name = "u2.nds", data = "two" },
    { name = "u3.nds", data = "three" },
  })
  local s, err
  withPatched(RomSource, "fromString", function(original)
    return function(data, name)
      created = created + 1
      local source = original(data, name)
      local originalRelease = source.release
      source.release = function(self)
        released = released + 1
        return originalRelease(self)
      end
      return source
    end
  end, function()
    s, err = RomSource.fromZipData(zip, "rom.zip", versionsFor("none"))
  end)
  Assert.notNil(s, err and tostring(err))
  assert(s)
  Assert.equal(created, 3)
  Assert.equal(released, 2, "replaced candidates must be released")
  -- "u1.nds" lists first among these names, so it is the retained fallback.
  Assert.equal(s:read(0, 3), "one", "the first .nds is the retained fallback")
end

-- The fallback itself is released when a later supported candidate wins, so
-- only the winning source survives the scan. ("a1.nds" lists before
-- "good.nds" for these names, so the unsupported candidate becomes the
-- fallback before the match.)
function T.zip_scan_releases_the_fallback_when_a_supported_candidate_wins()
  local good = NdsBuilder.build(DumpFixture.spec())
  local goodSha = RomSource.fromString(good):sha1()
  local created, released = 0, 0
  local zip = ZipBuilder.build({
    { name = "a1.nds", data = "one" },
    { name = "good.nds", data = good },
  })
  local s, err
  withPatched(RomSource, "fromString", function(original)
    return function(data, name)
      created = created + 1
      local source = original(data, name)
      local originalRelease = source.release
      source.release = function(self)
        released = released + 1
        return originalRelease(self)
      end
      return source
    end
  end, function()
    s, err = RomSource.fromZipData(zip, "rom.zip", versionsFor(goodSha))
  end)
  Assert.notNil(s, err and tostring(err))
  assert(s)
  Assert.equal(created, 2)
  Assert.equal(released, 1, "the fallback must be released when a supported candidate wins")
  Assert.equal(s:sha1(), goodSha)
end

return { tests = T }
