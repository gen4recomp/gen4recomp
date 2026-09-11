-- Owns interactive derived-asset production for one running game.

local InteractiveCacheBuild = require("romdump.src.build.InteractiveCacheBuild")

---@class DerivedAssetProvisioner
---@field build InteractiveCacheBuild
---@field closed boolean
---@field host table<string, function>|nil
local DerivedAssetProvisioner = {}
DerivedAssetProvisioner.__index = DerivedAssetProvisioner

---@param options table<string, unknown>
---@return DerivedAssetProvisioner
function DerivedAssetProvisioner.new(options)
  local build = InteractiveCacheBuild.new(options)
  local self = setmetatable({ build = build, closed = false, host = nil }, DerivedAssetProvisioner)
  self.host = {
    requestField = function(mapId)
      assert(not self.closed, "derived-asset provisioner is disposed")
      return build:requestField(mapId, 10)
    end,
    ensureField = function(mapId)
      assert(not self.closed, "derived-asset provisioner is disposed")
      return build:ensureField(mapId)
    end,
    requestCell = function(descriptor)
      assert(not self.closed, "derived-asset provisioner is disposed")
      return build:requestCell(descriptor, 20)
    end,
    ensureCell = function(descriptor)
      assert(not self.closed, "derived-asset provisioner is disposed")
      return build:ensureCell(descriptor)
    end,
  }
  return self
end

function DerivedAssetProvisioner:gameHost()
  assert(not self.closed, "derived-asset provisioner is disposed")
  return self.host
end

function DerivedAssetProvisioner:update()
  if not self.closed then
    self.build:update()
  end
end

function DerivedAssetProvisioner:dispose()
  if self.closed then
    return
  end
  self.closed = true
  self.host = nil
  self.build:dispose()
end

return DerivedAssetProvisioner
