-- Recursive discovery of test suites beneath every `tests` directory in the
-- project tree. Pure: the only filesystem access goes through the injected
-- `fs` (a love.filesystem-shaped table exposing `getDirectoryItems` and
-- `getInfo`), so the runner's own tests drive it with a fake corpus.
--
-- A file is a suite exactly when its name ends in `_test.lua`. The repository
-- controls every suite filename, so the former plural `_tests.lua` spelling
-- is not discovered. Results are sorted by module name so execution order
-- never depends on filesystem order, and a module name reachable twice is an
-- error rather than a silently doubled or dropped suite.

local Discovery = {}

local function isSuiteFile(name)
  return name:match("_test%.lua$") ~= nil
end

local COMPONENTS = { app = true, game = true, romdump = true }
local TEST_LAYERS = { graphics = true, rom = true, acceptance = true }
local IGNORED_PROJECT_DIRECTORIES = {
  [".agents"] = true,
  [".worktrees"] = true,
  [".cache"] = true,
  [".claude"] = true,
  [".codex"] = true,
  [".git"] = true,
  ["tmp"] = true,
}

local function modulePrefix(path)
  return path:gsub("/", ".")
end

local function layerForTestsDirectory(path)
  local parent = path:match("^(.-)/tests$")
  if parent == nil then
    return "unit"
  end
  if parent == "" then
    return "unit"
  end
  local topLevel = parent:match("^([^/]+)")
  if topLevel ~= nil and COMPONENTS[topLevel] then
    return "component"
  end
  return "unit"
end

local function walk(fs, path, prefix, layer, out)
  local entries = fs.getDirectoryItems(path)
  table.sort(entries)
  for _, entry in ipairs(entries) do
    local childPath = path .. "/" .. entry
    local info = fs.getInfo(childPath)
    if info ~= nil and info.type == "directory" then
      walk(fs, childPath, prefix .. "." .. entry, layer, out)
    elseif isSuiteFile(entry) then
      out[#out + 1] = { module = prefix .. "." .. entry:sub(1, -5), layer = layer, path = childPath }
    end
  end
end

local function walkProject(fs, path, out)
  local entries = fs.getDirectoryItems(path)
  table.sort(entries)
  for _, entry in ipairs(entries) do
    local childPath = path == "" and entry or path .. "/" .. entry
    local info = fs.getInfo(childPath)
    if info ~= nil and info.type == "directory" then
      if path == "" and IGNORED_PROJECT_DIRECTORIES[entry] then
        -- Workspace artifacts and reference checkouts are not project test
        -- sources, even when they contain directories named `tests`.
      elseif entry == "tests" then
        local layer = layerForTestsDirectory(childPath)
        local prefix = modulePrefix(childPath)
        if childPath == "tests" then
          -- The first directory below the project-level tests directory names
          -- its layer (tests/graphics, tests/rom, and so on).
          for _, child in ipairs(fs.getDirectoryItems(childPath)) do
            local childInfo = fs.getInfo(childPath .. "/" .. child)
            if childInfo ~= nil and childInfo.type == "directory" then
              walk(fs, childPath .. "/" .. child, prefix .. "." .. child, TEST_LAYERS[child] and child or "unit", out)
            end
          end
        else
          walk(fs, childPath, prefix, layer, out)
        end
      else
        walkProject(fs, childPath, out)
      end
    end
  end
end

-- Every suite beneath the project tree, sorted by module name.
---@param fs table love.filesystem-shaped reader
---@param roots table[]|nil focused roots for runner unit tests
---@return { module: string, layer: string, path: string }[]
function Discovery.suites(fs, roots)
  local found = {}
  if roots == nil then
    walkProject(fs, "", found)
  else
    for _, root in ipairs(roots) do
      assert(type(root.path) == "string", "root needs a path")
      assert(type(root.layer) == "string", "root needs a default layer: " .. root.path)
      walk(fs, root.path, modulePrefix(root.path), root.layer, found)
    end
  end

  local byModule = {}
  for _, suite in ipairs(found) do
    local previous = byModule[suite.module]
    if previous ~= nil then
      error("duplicate test module " .. suite.module .. " (" .. previous.path .. " and " .. suite.path .. ")", 0)
    end
    byModule[suite.module] = suite
  end

  table.sort(found, function(a, b)
    return a.module < b.module
  end)
  return found
end

return Discovery
