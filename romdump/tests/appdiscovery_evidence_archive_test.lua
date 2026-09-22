-- Deterministic local ZIP32/store encoder: byte-identical output for
-- identical input, standard interoperability through LOVE's own zip mount,
-- and structured rejection of unsafe paths, non-string content, and
-- entry-count limits. No compression, Zip64, or timestamp variance is
-- involved: every produced archive uses a fixed DOS epoch timestamp.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local EvidenceArchive = require("romdump.src.appdiscovery.EvidenceArchive")

local T = {}

local MOUNT_POINT = "g4-evidence-archive-test"

-- Mounts `bytes` as a zip and runs `fn(basePath)`, always unmounting
-- afterwards even when `fn` raises.
local function withMounted(bytes, fn)
  local fd = love.filesystem.newFileData(bytes, "evidence.zip")
  love.filesystem.unmount(fd:getFilename())
  local mounted = love.filesystem.mount(fd, MOUNT_POINT)
  Assert.isTrue(mounted, "could not mount produced archive bytes")
  local ok, err = pcall(fn, MOUNT_POINT)
  love.filesystem.unmount(fd:getFilename())
  if not ok then
    error(err, 0)
  end
end

local SMALL_FILES = {
  ["manifest.lua"] = 'return { schema = "g4-app-evidence-1" }\n',
  ["README.md"] = "evidence bundle\n",
  ["resources/narcs/file-0.lua"] = "return {}\n",
}

function T.encode_is_byte_identical_for_the_same_content_regardless_of_table_construction_order()
  local a = {}
  a["manifest.lua"] = SMALL_FILES["manifest.lua"]
  a["README.md"] = SMALL_FILES["README.md"]
  a["resources/narcs/file-0.lua"] = SMALL_FILES["resources/narcs/file-0.lua"]

  local b = {}
  b["resources/narcs/file-0.lua"] = SMALL_FILES["resources/narcs/file-0.lua"]
  b["README.md"] = SMALL_FILES["README.md"]
  b["manifest.lua"] = SMALL_FILES["manifest.lua"]

  local bytesA = assert(EvidenceArchive.encode(a))
  local bytesB = assert(EvidenceArchive.encode(b))
  Assert.equal(bytesA, bytesB, "identical member sets must encode to identical bytes regardless of map order")

  local bytesA2 = assert(EvidenceArchive.encode(a))
  Assert.equal(bytesA, bytesA2, "encoding the same map twice must be byte-identical")
end

function T.mounted_archive_exposes_every_member_with_exact_content_and_no_extras()
  local bytes = assert(EvidenceArchive.encode(SMALL_FILES))
  withMounted(bytes, function(base)
    for path, content in pairs(SMALL_FILES) do
      local full = base .. "/" .. path
      Assert.notNil(love.filesystem.getInfo(full), "missing archived member " .. path)
      Assert.equal(love.filesystem.read(full), content, "content mismatch for " .. path)
    end

    local function countFiles(dir)
      local count = 0
      for _, item in ipairs(love.filesystem.getDirectoryItems(dir)) do
        local full = dir .. "/" .. item
        local info = love.filesystem.getInfo(full)
        if info.type == "directory" then
          count = count + countFiles(full)
        else
          count = count + 1
        end
      end
      return count
    end
    Assert.equal(countFiles(base), 3, "archive must contain exactly the given members, no extras")
  end)
end

function T.rejects_absolute_paths()
  local err = Assert.throws(function()
    EvidenceArchive.encode({ ["/manifest.lua"] = "x" })
  end)
  Assert.isTrue(Errors.is(err), "expected a structured Errors.Error")
  Assert.equal(err.code, "APPDISCOVERY_ARCHIVE_PATH_INVALID")
end

function T.rejects_backslash_paths()
  local err = Assert.throws(function()
    EvidenceArchive.encode({ ["resources\\narcs\\file-0.lua"] = "x" })
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "APPDISCOVERY_ARCHIVE_PATH_INVALID")
end

function T.rejects_empty_path_components()
  local err = Assert.throws(function()
    EvidenceArchive.encode({ ["resources//file-0.lua"] = "x" })
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "APPDISCOVERY_ARCHIVE_PATH_INVALID")
end

function T.rejects_dot_and_dot_dot_path_components()
  local dotErr = Assert.throws(function()
    EvidenceArchive.encode({ ["resources/./file-0.lua"] = "x" })
  end)
  Assert.isTrue(Errors.is(dotErr))
  Assert.equal(dotErr.code, "APPDISCOVERY_ARCHIVE_PATH_INVALID")

  local dotDotErr = Assert.throws(function()
    EvidenceArchive.encode({ ["resources/../file-0.lua"] = "x" })
  end)
  Assert.isTrue(Errors.is(dotDotErr))
  Assert.equal(dotDotErr.code, "APPDISCOVERY_ARCHIVE_PATH_INVALID")
end

function T.rejects_empty_paths()
  local err = Assert.throws(function()
    EvidenceArchive.encode({ [""] = "x" })
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "APPDISCOVERY_ARCHIVE_PATH_INVALID")
end

function T.rejects_non_string_content()
  local err = Assert.throws(function()
    EvidenceArchive.encode({ ["manifest.lua"] = 12345 } --[[@as any]])
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "APPDISCOVERY_ARCHIVE_CONTENT_INVALID")
end

-- ZIP32 caps entries at 65,535; the fixture stays small (empty-string
-- members) so the boundary is proven without allocating large data.
function T.rejects_more_than_the_zip32_entry_limit()
  local files = {}
  for i = 1, 65536 do
    files[string.format("f/%06d", i)] = ""
  end
  local err = Assert.throws(function()
    EvidenceArchive.encode(files)
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "APPDISCOVERY_ARCHIVE_LIMIT_EXCEEDED")
end

function T.accepts_exactly_the_zip32_entry_limit()
  local files = {}
  for i = 1, 65535 do
    files[string.format("f/%06d", i)] = ""
  end
  local bytes = assert(EvidenceArchive.encode(files))
  Assert.isTrue(#bytes > 0)
end

function T.empty_archive_encodes_to_a_valid_zip_with_no_members()
  local bytes = assert(EvidenceArchive.encode({}))
  withMounted(bytes, function(base)
    Assert.equal(#love.filesystem.getDirectoryItems(base), 0)
  end)
end

return { tests = T }
