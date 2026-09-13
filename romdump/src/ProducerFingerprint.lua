-- Broad development digest of the producer source tree: every regular file
-- under a fixed set of source roots hashed by root-relative path and raw
-- bytes, aggregated into one SHA-256 manifest digest. Any producer edit
-- (content, add, remove, rename) changes the digest, so the derived cache
-- invalidates without manual compiler-version bookkeeping. mtimes, git state,
-- tests, and docs are deliberately absent. The source tree is injected as a
-- backend so tests use fake trees; checkoutBackend enumerates a development
-- checkout, appBackend wraps love.filesystem. Release cache identity never
-- consults this module: it uses an explicit per-game counter instead.

local Errors = require("libs.errors.src.Errors")
local Sha256 = require("libs.script.src.Sha256")

local ProducerFingerprint = {}

---@class ProducerSourceTree
---@field list fun(root: string?): string[]
---@field read fun(path: string, root: string?): string
---@field getInfo fun(path: string): { type: string }|nil

-- The fixed broad source-root set. Deliberately coarse: development edits
-- outside the semantic minimum still invalidate, rather than maintaining a
-- per-family dependency graph. Every configured root must exist; a missing
-- root is a structured failure, never a silent omission.
local DEFAULT_ROOTS = {
  "romdump/src",
  "libs/assets/src",
  "libs/codec/src",
  "libs/errors/src",
  "libs/math/src",
  "libs/nds/src",
  "libs/script/src",
  "libs/storage/src",
  "gen4",
  "data/manifests",
}

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

---@param roots string|string[]|nil
---@return string[]
local function resolveRoots(roots)
  if roots == nil then
    local copy = {}
    for index, root in ipairs(DEFAULT_ROOTS) do
      copy[index] = root
    end
    return copy
  end
  if type(roots) == "string" then
    return { normalizeRoot(roots) }
  end
  assert(type(roots) == "table", "producer source roots must be a root list")
  local resolved = {}
  for index, root in ipairs(roots) do
    resolved[index] = normalizeRoot(root)
  end
  return resolved
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

local function assertCheckoutDirectory(directory, root)
  local probe = assert(io.popen("test -d " .. string.format("%q", directory) .. " && echo present", "r"))
  local marker = probe:read("*l")
  probe:close()
  assert(marker == "present", "producer source root is missing: " .. root)
end

-- Unix-only source-checkout enumeration for explicit development tooling.
-- Each configured root is enumerated on demand under the repository root;
-- reads are confined to the enumerated index, so a path can never escape
-- its root.
---@param repositoryRoot string
---@return ProducerSourceTree
function ProducerFingerprint.checkoutBackend(repositoryRoot)
  assert(type(repositoryRoot) == "string" and repositoryRoot ~= "", "development repository root is required")
  local indexed = {}
  local function indexRoot(root)
    assert(type(root) == "string", "producer source root is required")
    local cached = indexed[root]
    if cached then
      return cached
    end
    root = normalizeRoot(root)
    local directory = repositoryRoot .. "/" .. root
    assertCheckoutDirectory(directory, root)
    local byRelative = {}
    for _, path in ipairs(sortedFiles(directory)) do
      assert(path:sub(1, #directory + 1) == directory .. "/", "source checkout path escaped root")
      byRelative[path:sub(#directory + 2)] = path
    end
    indexed[root] = byRelative
    return byRelative
  end
  local function listFiles(root)
    local byRelative = indexRoot(assert(type(root) == "string" and root, "producer source root is required"))
    local result = {}
    for path in pairs(byRelative) do
      result[#result + 1] = path
    end
    table.sort(result)
    return result
  end
  local function readFile(path, root)
    assert(type(path) == "string", "producer source path is required")
    local byRelative = indexRoot(assert(type(root) == "string" and root, "producer source root is required"))
    local full = assert(byRelative[path], "source checkout file is not indexed: " .. tostring(path))
    local file = assert(io.open(full, "rb"), "cannot read source checkout file: " .. full)
    local data = file:read("*a")
    file:close()
    return assert(data)
  end
  local function getFileInfo(path, root)
    if type(path) ~= "string" or type(root) ~= "string" then
      return nil
    end
    local ok, byRelative = pcall(indexRoot, root)
    if not ok then
      return nil
    end
    if path == root then
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

local function listRoot(backend, root)
  local ok, paths = pcall(backend.list, root)
  if ok then
    if type(paths) == "table" then
      return paths
    end
    Errors.raise("PRODUCER_SOURCE_UNAVAILABLE", "producer source listing must be a table: " .. root, { root = root })
  end
  if Errors.is(paths) then
    error(paths, 0)
  end
  Errors.raise("PRODUCER_SOURCE_UNAVAILABLE", "producer source root is unavailable: " .. root, { root = root })
end

local function readRoot(backend, root, path)
  local ok, contents = pcall(backend.read, path, root)
  if ok then
    if type(contents) == "string" then
      return contents
    end
    Errors.raise(
      "PRODUCER_SOURCE_UNREADABLE",
      "producer source file must read as a string: " .. root .. "/" .. path,
      { root = root, path = path }
    )
  end
  if Errors.is(contents) then
    error(contents, 0)
  end
  Errors.raise(
    "PRODUCER_SOURCE_UNREADABLE",
    "cannot read producer source file: " .. root .. "/" .. path,
    { root = root, path = path }
  )
end

local function manifestPath(root, path)
  assert(type(path) == "string", "source tree paths must be strings")
  local full = root .. "/" .. path:gsub("\\", "/")
  if full:find("\t", 1, true) ~= nil or full:find("\n", 1, true) ~= nil then
    Errors.raise(
      "PRODUCER_SOURCE_PATH_INVALID",
      "producer source path contains a tab or newline: " .. string.format("%q", full),
      { root = root, path = path }
    )
  end
  return full
end

-- Aggregate the development digest from an injected source-tree backend:
-- list(root) returns every regular file path relative to that root in any
-- order; read(path, root) returns that file's raw bytes. Without an explicit
-- root list every default root is enumerated. Paths sort in byte-string
-- order across all roots, so enumeration order never affects the result. The
-- manifest joins `path + TAB + SHA256(bytes) + LF` per file and hashes the
-- whole manifest with SHA-256; the returned token is `d` followed by 64
-- lowercase hex digits.
---@param backend ProducerSourceTree
---@param roots string|string[]|nil
---@return string
function ProducerFingerprint.compute(backend, roots)
  assert(
    backend and type(backend.list) == "function" and type(backend.read) == "function",
    "ProducerFingerprint.compute requires a source-tree backend"
  )
  local entries = {}
  for _, root in ipairs(resolveRoots(roots)) do
    for _, path in ipairs(listRoot(backend, root)) do
      local contents = readRoot(backend, root, path)
      entries[#entries + 1] = manifestPath(root, path) .. "\t" .. Sha256.hex(contents) .. "\n"
    end
  end
  table.sort(entries)
  return "d" .. Sha256.hex(table.concat(entries))
end

-- love.filesystem-backed enumeration of this app's own source trees; the
-- paths it returns are relative to the requested root.
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
