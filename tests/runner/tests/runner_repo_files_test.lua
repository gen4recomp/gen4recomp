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

-- The root is passed to `find` through a shell, so a path containing an
-- apostrophe must be escaped: an unescaped quote turns the command into
-- garbage and discovery silently indexes nothing (the empty-root assert
-- above would then fire with a misleading cause).
--
-- The parent directory is acquired atomically per invocation; only that
-- owned parent and its children are ever created or removed.
local function shellQuote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function commandSucceeded(status)
  return status == 0 or status == true
end

local function acquireParentRoot()
  local pipe = assert(io.popen("mktemp -d"), "mktemp -d could not start")
  local path = (pipe:read("*l") or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local closed = pipe:close()
  assert(commandSucceeded(closed), "mktemp -d did not exit successfully")
  assert(path ~= "", "mktemp -d produced no path")
  return path
end

local function removeOwnedRoot(path)
  assert(path ~= "" and path ~= "/", "refusing to remove an unowned path")
  local status = os.execute("rm -rf -- " .. shellQuote(path))
  assert(commandSucceeded(status), "owned temporary cleanup failed: " .. path)
end

local function runShell(command)
  local status = os.execute(command)
  assert(commandSucceeded(status), "setup command failed: " .. command)
end

-- Runs fn(parent) with a fresh owned parent, always releasing exactly that
-- parent. A body failure keeps its original error; a cleanup failure
-- after a passing body fails the case.
local function withOwnedParent(fn)
  local parent = acquireParentRoot()
  local ok, err = pcall(fn, parent)
  if ok then
    removeOwnedRoot(parent)
    return
  end
  pcall(removeOwnedRoot, parent)
  error(err, 0)
end

function T.indexes_a_root_whose_path_contains_an_apostrophe()
  local seenParent = nil
  withOwnedParent(function(parent)
    seenParent = parent
    local root = "apostrophe'dir"
    local absoluteRoot = parent .. "/" .. root
    runShell("mkdir -p -- " .. shellQuote(absoluteRoot))
    local path = absoluteRoot .. "/quoted_suite_test.lua"
    local handle = assert(io.open(path, "w"), "cannot write fixture under " .. root)
    handle:write("return { tests = {} }\n")
    assert(handle:close())

    local files = RepoFiles.new(parent, { root })
    Assert.isTrue(
      has(files.getDirectoryItems(root), "quoted_suite_test.lua"),
      "indexes the suite under an apostrophe path"
    )
  end)
  assert(seenParent ~= nil, "the owned parent must have been acquired")
  Assert.isNil(
    io.open(seenParent .. "/apostrophe'dir/quoted_suite_test.lua", "r"),
    "the owned parent must not survive the case"
  )
end

-- Two independently acquired parents never share a root: releasing one
-- removes only its sentinel while the sibling root stays intact.
function T.independent_fixture_parents_do_not_share_state()
  local first = acquireParentRoot()
  local second = acquireParentRoot()
  local ok, err = pcall(function()
    Assert.isTrue(first ~= second, "independent acquisitions never share a root")
    local firstSentinel = first .. "/sentinel.txt"
    local secondSentinel = second .. "/sentinel.txt"
    local writer = assert(io.open(firstSentinel, "w"))
    writer:write("first")
    assert(writer:close())
    writer = assert(io.open(secondSentinel, "w"))
    writer:write("second")
    assert(writer:close())
    removeOwnedRoot(first)
    local leaked = io.open(firstSentinel, "r")
    if leaked ~= nil then
      leaked:close()
    end
    Assert.isNil(leaked, "the released parent is gone")
    local reader = assert(io.open(secondSentinel, "r"), "the sibling parent survives teardown")
    Assert.equal(reader:read("*a"), "second")
    reader:close()
  end)
  pcall(removeOwnedRoot, first)
  pcall(removeOwnedRoot, second)
  if not ok then
    error(err, 0)
  end
end

return { tests = T }
