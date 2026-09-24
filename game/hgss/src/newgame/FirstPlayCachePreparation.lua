-- Fresh-import first-play demand coordinator. After raw ROM extraction the
-- menu must wait until the existing bounded global milestones plus the
-- exact initial bedroom closure are current under one provisioner epoch.
-- This object composes those existing semantic requests but owns no
-- production mechanism: milestone membership stays with the milestone
-- owners, bedroom dependency policy stays with FieldMapLoader, and the
-- generated start location stays with NewGameInitialization. Created
-- through HgssGame.newFirstPlayCachePreparation and polled by the
-- launcher first-play state; the same provisioner epoch then hands the
-- compiled output to the game.

local CacheFs = require("libs.storage.src.CacheFs")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local FieldMapLoader = require("libs.hgss.src.world.FieldMapLoader")
local NewGameInitialization = require("game.hgss.src.newgame.NewGameInitialization")

-- The existing semantic milestones that constitute the first-play global
-- set. Requested by name every poll; never replaced with duplicated
-- artifact membership.
local milestoneNames = {
  "bootstrap",
  "new-game-intro",
  "field-planning",
  "field-runtime",
}

---@class FirstPlayCachePreparation
---@field versionId string selected game version, carried for diagnostics
---@field derivedAssets table<string, function>? borrowed semantic host, cleared on disposal
---@field loader table<string, unknown>? retained metadata-only planning loader, built once
---@field target { symbol: string, x: integer, z: integer }? retained globalized bedroom target
---@field failure unknown? latched terminal failure for this selection
---@field disposed boolean
local FirstPlayCachePreparation = {}
FirstPlayCachePreparation.__index = FirstPlayCachePreparation

---@param options { versionId: string, derivedAssets: table<string, function> }
---@return FirstPlayCachePreparation
function FirstPlayCachePreparation.new(options)
  assert(type(options) == "table", "first-play preparation requires its composition")
  local versionId = options.versionId
  assert(type(versionId) == "string" and versionId ~= "", "first-play preparation requires its selected version")
  local derivedAssets = options.derivedAssets
  assert(
    type(derivedAssets) == "table" and type(derivedAssets.requestMilestone) == "function",
    "first-play preparation requires its borrowed derived host"
  )
  return setmetatable({
    versionId = versionId,
    derivedAssets = derivedAssets,
    loader = nil,
    target = nil,
    failure = nil,
    disposed = false,
  }, FirstPlayCachePreparation)
end

---@param name string milestone interest to observe
---@return boolean observed ready
local function pollMilestone(self, name)
  -- The semantic host is a plain function table (dot calls, no self).
  -- Repeating the required interest re-affirms it; independent required
  -- work overlaps below the controller instead of serializing here.
  local host = assert(self.derivedAssets, "first-play preparation requires its borrowed derived host")
  local ok, ready, failure = pcall(host.requestMilestone, name, "required")
  if not ok then
    self.failure = ready
    return false
  end
  if failure ~= nil then
    self.failure = failure
    return false
  end
  return ready == true
end

---@return boolean built, unknown? failure
function FirstPlayCachePreparation:_buildTarget()
  -- The generated start location is current only once new-game-intro is
  -- ready, and the structural world only once field-planning is ready;
  -- the caller observes both before building. Everything below converts
  -- a loud cache/preparation defect into a visible failure, never a
  -- default location or a retried probe.
  local okFs, cacheFsOrError = pcall(CacheFs.forVersion, self.versionId)
  if not okFs then
    return false, cacheFsOrError
  end
  local cacheFs = cacheFsOrError
  local okWorld, worldOrError = pcall(function()
    return assert(
      cacheFs:loadLua(MapAssetCache.worldPath()),
      "field world metadata is unavailable although entry planning is ready"
    )
  end)
  if not okWorld then
    return false, worldOrError
  end
  local host = assert(self.derivedAssets, "first-play preparation requires its borrowed derived host")
  local okLoader, loaderOrError = pcall(FieldMapLoader.new, cacheFs, worldOrError, { derivedAssets = host })
  if not okLoader then
    return false, loaderOrError
  end
  local loader = loaderOrError
  local okLocation, locationOrError = pcall(NewGameInitialization.initialLocation, self.versionId)
  if not okLocation then
    return false, locationOrError
  end
  local location = locationOrError
  if type(location) ~= "table" then
    return false, "generated initial location is malformed"
  end
  local mapSymbol = location.mapSymbol
  local fieldX = location.fieldX
  local fieldZ = location.fieldZ
  if type(mapSymbol) ~= "string" then
    return false, "generated initial location is malformed"
  end
  if type(fieldX) ~= "number" or fieldX % 1 ~= 0 then
    return false, "generated initial location is malformed"
  end
  if type(fieldZ) ~= "number" or fieldZ % 1 ~= 0 then
    return false, "generated initial location is malformed"
  end
  -- The start coordinates are local to their map; the loader converts
  -- them to the same global domain normal loading uses.
  local okPosition, positionOrError = pcall(function()
    return loader:globalPosition(mapSymbol, fieldX, fieldZ)
  end)
  if not okPosition then
    return false, positionOrError
  end
  local position = positionOrError
  self.loader = loader
  self.target = { symbol = mapSymbol, x = position.x, z = position.z }
  return true, nil
end

---@return boolean observed ready, unknown? failure
local function pollLocation(self)
  local target = assert(self.target, "bedroom demand requires its globalized target")
  local loader = assert(self.loader, "bedroom demand requires the retained planning loader")
  local ok, ready, failure = pcall(function()
    return loader:requestLocation(target.symbol, target.x, target.z, "required")
  end)
  if not ok then
    self.failure = ready
    return false
  end
  if failure ~= nil then
    self.failure = failure
    return false
  end
  return ready == true
end

---@return boolean ready, unknown? failure
function FirstPlayCachePreparation:poll()
  if self.disposed then
    return false, "first-play preparation is disposed"
  end
  if self.failure ~= nil then
    return false, self.failure
  end
  local introReady = false
  local planningReady = false
  local allReady = true
  for _, name in ipairs(milestoneNames) do
    local ready = pollMilestone(self, name)
    if self.failure ~= nil then
      return false, self.failure
    end
    if name == "new-game-intro" then
      introReady = ready
    elseif name == "field-planning" then
      planningReady = ready
    end
    if not ready then
      allReady = false
    end
  end
  if self.target == nil and introReady and planningReady then
    local built, buildFailure = self:_buildTarget()
    if not built then
      self.failure = buildFailure
      return false, self.failure
    end
  end
  local locationReady = false
  if self.target ~= nil then
    locationReady = pollLocation(self)
    if self.failure ~= nil then
      return false, self.failure
    end
  end
  if allReady and locationReady then
    return true, nil
  end
  return false, nil
end

function FirstPlayCachePreparation:dispose()
  -- The borrowed host stays with App, which owns the provisioner epoch;
  -- only the retained planning loader is released here, exactly once.
  -- Game launch never reuses this temporary loader, only the compiled
  -- provisioner output it demanded.
  if self.disposed then
    return
  end
  self.disposed = true
  local loader = self.loader
  self.loader = nil
  self.target = nil
  self.derivedAssets = nil
  if loader ~= nil then
    pcall(function()
      loader:release()
    end)
  end
end

return FirstPlayCachePreparation
