-- Contract tests for the real-filesystem adapter discovery runs against.
-- `love.filesystem` is rooted at `game/` and answers repo-relative directory
-- listings with an empty table, so an adapter that quietly indexes nothing
-- would report a fully green run over zero suites. Indexing an empty root is
-- therefore a hard error.

local Assert = require("tests.support.Assert")
local RepoFiles = require("tests.runner.RepoFiles")

local T = {}

local function base()
  return love.filesystem.getSourceBaseDirectory()
end

local function has(entries, name)
  for _, entry in ipairs(entries) do
    if entry == name then
      return true
    end
  end
  return false
end

function T.indexes_nested_directories_of_a_root()
  local files = RepoFiles.new(base(), { "libs/hgss/tests/field", "libs/script/tests/core" })

  local top = files.getDirectoryItems("libs/hgss/tests/field")
  Assert.isTrue(has(top, "field_session_test.lua"), "lists an immediate suite")
  Assert.isTrue(has(files.getDirectoryItems("libs/script/tests"), "core"), "lists the promoted script test package")
  Assert.isTrue(has(files.getDirectoryItems("libs/script/tests/core"), "scheduler_test.lua"), "lists a nested suite")
end

function T.reports_file_and_directory_types()
  local files = RepoFiles.new(base(), { "libs/hgss/tests/field", "libs/script/tests/core" })

  Assert.equal(files.getInfo("libs/script/tests/core").type, "directory")
  Assert.equal(files.getInfo("libs/script/tests/core/scheduler_test.lua").type, "file")
  Assert.isNil(files.getInfo("libs/hgss/tests/field/nope"))
  Assert.isNil(files.getInfo("libs/codec/tests"), "a directory outside the indexed roots is unknown")
end

function T.an_empty_root_is_a_hard_error()
  local err = Assert.throws(function()
    RepoFiles.new(base(), { "libs/script/tests/core/does-not-exist" })
  end)
  Assert.isTrue(
    tostring(err):find("indexed no Lua files", 1, true) ~= nil,
    "an empty root fails loudly: " .. tostring(err)
  )
end

return { tests = T }
