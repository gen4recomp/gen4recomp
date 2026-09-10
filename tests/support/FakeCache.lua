-- In-memory CacheFs backend for tests. Operates on save-directory-relative
-- full paths (already version-prefixed by CacheFs). Directories are implied by
-- file paths, plus any explicitly created empty directories.

local FakeCache = {}
FakeCache.__index = FakeCache

function FakeCache.new()
  return setmetatable({ files = {}, dirs = {} }, FakeCache)
end

function FakeCache:write(path, data)
  self.files[path] = data
  return true
end

function FakeCache:read(path)
  local value = self.files[path]
  if value ~= nil and type(value) ~= "string" and type(value.getString) == "function" then
    return value:getString()
  end
  return value
end

local function hasChildren(self, path)
  local prefix = path .. "/"
  for k in pairs(self.files) do
    if k:sub(1, #prefix) == prefix then
      return true
    end
  end
  for k in pairs(self.dirs) do
    if k:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

function FakeCache:getInfo(path)
  if self.files[path] ~= nil then
    local value = self.files[path]
    local size
    if type(value) == "string" then
      size = #value
    elseif type(value.getSize) == "function" then
      size = value:getSize()
    else
      size = 0
    end
    return { type = "file", size = size }
  end
  if self.dirs[path] or hasChildren(self, path) then
    return { type = "directory" }
  end
  return nil
end

function FakeCache:createDirectory(path)
  self.dirs[path] = true
  return true
end

function FakeCache:remove(path)
  self.files[path] = nil
  self.dirs[path] = nil
  return true
end

-- Moves a single file or a whole directory subtree to a sibling path (the
-- in-memory analogue of the host `os.rename` the real backend uses for atomic
-- replacement and staged-tree publication). Two-phase: all matching entries are
-- collected first, then applied, so the tables are never written while being
-- traversed.
function FakeCache:replace(sourcePath, destinationPath)
  if self.files[sourcePath] ~= nil then
    self.files[destinationPath] = self.files[sourcePath]
    self.files[sourcePath] = nil
    return true
  end
  local info = self:getInfo(sourcePath)
  assert(info and info.type == "directory", "replacement source is missing")
  local prefix = sourcePath .. "/"
  local movedFiles = {}
  for k, v in pairs(self.files) do
    if k:sub(1, #prefix) == prefix then
      movedFiles[#movedFiles + 1] = { k, destinationPath .. "/" .. k:sub(#prefix + 1), v }
    end
  end
  for _, entry in ipairs(movedFiles) do
    self.files[entry[2]] = entry[3]
  end
  for _, entry in ipairs(movedFiles) do
    self.files[entry[1]] = nil
  end
  local movedDirs = {}
  for k in pairs(self.dirs) do
    if k == sourcePath or k:sub(1, #prefix) == prefix then
      movedDirs[#movedDirs + 1] = k
    end
  end
  for _, k in ipairs(movedDirs) do
    local rest = k == sourcePath and "" or k:sub(#prefix + 1)
    local dest = destinationPath .. (rest ~= "" and ("/" .. rest) or "")
    self.dirs[dest] = true
    self.dirs[k] = nil
  end
  self.dirs[destinationPath] = true
  return true
end

function FakeCache:getDirectoryItems(path)
  local prefix = path .. "/"
  local seen, names = {}, {}
  local function consider(k)
    if k:sub(1, #prefix) == prefix then
      local rest = k:sub(#prefix + 1)
      local name = rest:match("^([^/]+)")
      if name and not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
  end
  for k in pairs(self.files) do
    consider(k)
  end
  for k in pairs(self.dirs) do
    consider(k)
  end
  table.sort(names)
  return names
end

return FakeCache
