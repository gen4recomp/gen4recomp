-- FakeCache wrapper that models a host rename primitive with no overwrite and
-- no cross-parent directory moves, while recording each attempted rename.

local FakeCache = require("tests.support.FakeCache")

local ConstrainedCache = {}
ConstrainedCache.__index = ConstrainedCache

local function parent(path)
  return path:match("^(.*)/[^/]+$") or ""
end

function ConstrainedCache.new()
  local inner = FakeCache.new()
  return setmetatable({
    inner = inner,
    files = inner.files,
    dirs = inner.dirs,
    renameLog = {},
    failSourcePath = nil,
  }, ConstrainedCache)
end

function ConstrainedCache:write(path, data)
  return self.inner:write(path, data)
end

function ConstrainedCache:read(path)
  return self.inner:read(path)
end

function ConstrainedCache:getInfo(path)
  return self.inner:getInfo(path)
end

function ConstrainedCache:createDirectory(path)
  return self.inner:createDirectory(path)
end

function ConstrainedCache:remove(path)
  return self.inner:remove(path)
end

function ConstrainedCache:getDirectoryItems(path)
  return self.inner:getDirectoryItems(path)
end

function ConstrainedCache:failNextRename(sourcePath)
  self.failSourcePath = sourcePath
end

function ConstrainedCache:replace(sourcePath, destinationPath)
  local sourceInfo = self.inner:getInfo(sourcePath)
  local destinationInfo = self.inner:getInfo(destinationPath)
  local entry = {
    source = sourcePath,
    destination = destinationPath,
    sourceType = sourceInfo and sourceInfo.type or nil,
    destinationExisted = destinationInfo ~= nil,
    sourceParent = parent(sourcePath),
    destinationParent = parent(destinationPath),
  }
  self.renameLog[#self.renameLog + 1] = entry

  if destinationInfo ~= nil then
    return false, "rename destination already exists"
  end
  if sourceInfo and sourceInfo.type == "directory" and entry.sourceParent ~= entry.destinationParent then
    return false, "directory rename crosses parents"
  end
  if self.failSourcePath == sourcePath then
    self.failSourcePath = nil
    return false, "injected rename failure"
  end
  return self.inner:replace(sourcePath, destinationPath)
end

return ConstrainedCache
