-- Deterministic content fingerprint of the romdump producer source tree:
-- every regular file under romdump/src hashed by relative path and content,
-- aggregated into one SHA-1. Any producer edit (content, add, remove, rename)
-- changes the fingerprint, so the derived cache invalidates without manual
-- compiler-version bookkeeping. mtimes, git state, tests, and docs are
-- deliberately absent. The source tree is injected as a backend so tests use
-- fake trees; appBackend wraps love.filesystem.

local Hashing = require("romdump.src.digest.Hashing")

local ProducerFingerprint = {}

---@class ProducerSourceTree
---@field list fun(root: string?): string[]
---@field read fun(path: string, root: string?): string
---@field getInfo fun(path: string): { type: string }|nil

local function normalizeRoot(root)
  root = root or "src"
  assert(type(root) == "string" and root ~= "", "producer source root is required")
  assert(root:sub(1, 1) ~= "/" and root:sub(-1) ~= "/", "producer source root must be relative")
  assert(not root:find("[%z\\]"), "producer source root contains an invalid separator")
  local components = {}
  for component in root:gmatch("[^/]+") do
    assert(component ~= "." and component ~= "..", "producer source root contains a traversal component")
    components[#components + 1] = component
  end
  assert(#components > 0 and table.concat(components, "/") == root, "producer source root is not normalized")
  return root
end

local function sortedFiles(root)
  local command = "find " .. string.format("%q", root) .. " -type f -print"
  local pipe = assert(io.popen(command, "r"), "cannot enumerate source checkout")
  local files = {}
  for line in pipe:lines() do
    files[#files + 1] = line
  end
  local ok = pipe:close()
  assert(ok ~= false, "source checkout enumeration failed")
  table.sort(files)
  return files
end

-- Unix-only source-checkout enumeration for explicit development tooling.
---@param repositoryRoot string
---@return ProducerSourceTree
function ProducerFingerprint.checkoutBackend(repositoryRoot)
  assert(type(repositoryRoot) == "string" and repositoryRoot ~= "", "development repository root is required")
  local sourceRoot = repositoryRoot .. "/romdump/src"
  local files = sortedFiles(sourceRoot)
  local byRelative = {}
  for _, path in ipairs(files) do
    assert(path:sub(1, #sourceRoot + 1) == sourceRoot .. "/", "source checkout path escaped root")
    byRelative[path:sub(#sourceRoot + 2)] = path
  end
  local function listFiles()
    local result = {}
    for path in pairs(byRelative) do
      result[#result + 1] = path
    end
    table.sort(result)
    return result
  end
  local function readFile(path)
    local full = assert(byRelative[path], "source checkout file is not indexed: " .. tostring(path))
    local file = assert(io.open(full, "rb"), "cannot read source checkout file: " .. full)
    local data = file:read("*a")
    file:close()
    return assert(data)
  end
  local function getFileInfo(path)
    if path == "romdump/src" then
      return { type = "directory" }
    end
    if byRelative[path] then
      return { type = "file" }
    end
    return nil
  end
  return {
    list = listFiles,
    read = readFile,
    getInfo = getFileInfo,
  }
end

-- Aggregate the fingerprint from an injected source-tree backend: list()
-- returns every regular file path relative to romdump/src in any order;
-- read(path) returns that file's contents. Paths are sorted internally, so
-- enumeration order never affects the result.
---@param backend ProducerSourceTree
---@param root string?
---@return string
function ProducerFingerprint.compute(backend, root)
  assert(
    backend and type(backend.list) == "function" and type(backend.read) == "function",
    "ProducerFingerprint.compute requires a source-tree backend"
  )
  root = normalizeRoot(root)
  local paths = backend.list(root)
  assert(type(paths) == "table", "source tree listing must be a table")
  table.sort(paths)
  local parts = {}
  for _, path in ipairs(paths) do
    assert(type(path) == "string", "source tree paths must be strings")
    local contents = backend.read(path, root)
    assert(type(contents) == "string", "source file must read as a string: " .. path)
    parts[#parts + 1] = path .. "\0" .. Hashing.sha1hex(contents)
  end
  return Hashing.sha1hex(table.concat(parts))
end

-- love.filesystem-backed enumeration of this app's own romdump/src tree; the
-- paths it returns are relative to romdump/src.
---@return ProducerSourceTree
function ProducerFingerprint.appBackend()
  assert(love and love.filesystem, "the app backend requires love.filesystem")
  local fs = love.filesystem
  local function list(root)
    root = root or "src"
    local files = {}
    local function walk(dir)
      for _, name in ipairs(fs.getDirectoryItems(dir)) do
        local path = dir .. "/" .. name
        local info = fs.getInfo(path)
        if info and info.type == "file" then
          files[#files + 1] = path
        elseif info and info.type == "directory" then
          walk(path)
        end
      end
    end
    walk(root)
    for index, path in ipairs(files) do
      files[index] = path:sub(#root + 2)
    end
    return files
  end
  local function read(path, root)
    return fs.read((root or "src") .. "/" .. path)
  end
  return {
    list = list,
    read = read,
    getInfo = fs.getInfo,
  }
end

return ProducerFingerprint
