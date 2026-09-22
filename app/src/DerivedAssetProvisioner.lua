-- Semantic derived-asset host for one selected game. It borrows an epoch
-- on the process-owned cache service: fixed milestone/field/cell/page
-- operations forward to epoch-qualified service requests and return the
-- cached ready/pending/error distinctions with string urgencies, and
-- disposal retires the epoch without joining the shared controller. The
-- provisioner constructs no session, owns no pool, and performs no
-- producer hashing, filesystem traversal, publication, or source-plan
-- parsing: all cache production lives below the controller thread.

local Errors = require("libs.errors.src.Errors")

---@class DerivedAssetProvisionerOptions
---@field service CacheService process-owned cache service, borrowed
---@field versionId string selected game version
---@field development boolean? development producer mode for the selection
---@field developmentRepositoryRoot string? present in development mode

---@class DerivedAssetProvisioner
---@field service CacheService process-owned cache service, borrowed
---@field epoch integer controller epoch borrowed for this selection
---@field retired boolean
---@field host table<string, function>?
local DerivedAssetProvisioner = {}
DerivedAssetProvisioner.__index = DerivedAssetProvisioner

local VALID_URGENCIES = { required = true, near = true, sweep = true }

---@param urgency unknown
local function checkUrgency(urgency)
  assert(VALID_URGENCIES[urgency], "unknown cache urgency: " .. tostring(urgency))
end

---@param options DerivedAssetProvisionerOptions
---@return DerivedAssetProvisioner
function DerivedAssetProvisioner.new(options)
  assert(type(options) == "table", "derived-asset provisioner options are required")
  assert(options.service ~= nil, "provisioner requires its cache service")
  local service = options.service
  assert(type(service.select) == "function", "provisioner service cannot select generations")
  assert(type(service.request) == "function", "provisioner service cannot request artifacts")
  assert(type(service.observe) == "function", "provisioner service cannot observe readiness")
  local selectOptions = { versionId = options.versionId, development = options.development == true }
  if options.developmentRepositoryRoot ~= nil then
    selectOptions.repositoryRoot = options.developmentRepositoryRoot
  end
  local epoch = service:select(selectOptions)
  assert(type(epoch) == "number" and epoch % 1 == 0 and epoch >= 1, "cache controller refused the selection")
  local self = setmetatable({ service = service, epoch = epoch, retired = false, host = nil }, DerivedAssetProvisioner)
  local function guard()
    if self.retired then
      Errors.raise("DERIVED_ASSETS_RETIRED", "derived-asset provisioner is retired", {})
    end
    return self
  end
  local function ask(kind, urgency, extra)
    checkUrgency(urgency)
    local selector = { requestKind = kind, urgency = urgency }
    if extra ~= nil then
      for key, value in pairs(extra) do
        selector[key] = value
      end
    end
    local active = guard()
    active.service:request(active.epoch, selector)
    return active.service:observe(active.epoch, selector)
  end
  local function assertion(kind, extra, label)
    local active = guard()
    local selector = { requestKind = kind, urgency = "required" }
    for key, value in pairs(extra) do
      selector[key] = value
    end
    active.service:request(active.epoch, selector)
    local ready, failure = active.service:observe(active.epoch, selector)
    if ready then
      return true
    end
    if failure ~= nil then
      error(failure, 0)
    end
    error(label .. " is not ready", 0)
  end
  self.host = {
    requestMilestone = function(name, urgency)
      assert(type(name) == "string" and name ~= "", "milestone request requires its name")
      return ask("milestone", urgency, { name = name })
    end,
    requestField = function(mapId, urgency)
      assert(type(mapId) == "number" and mapId % 1 == 0 and mapId >= 0, "field request requires its map")
      return ask("field", urgency, { mapId = mapId })
    end,
    ensureField = function(mapId)
      assert(type(mapId) == "number" and mapId % 1 == 0 and mapId >= 0, "field readiness requires its map")
      return assertion("field", { mapId = mapId }, "field " .. tostring(mapId))
    end,
    requestCell = function(descriptor, urgency)
      assert(type(descriptor) == "table", "cell request requires its descriptor")
      assert(
        type(descriptor.matrixMemberId) == "number" and descriptor.matrixMemberId % 1 == 0,
        "cell request requires its matrix member"
      )
      assert(type(descriptor.index) == "number" and descriptor.index % 1 == 0, "cell request requires its index")
      return ask("cell", urgency, { matrixMemberId = descriptor.matrixMemberId, index = descriptor.index })
    end,
    ensureCell = function(descriptor)
      assert(type(descriptor) == "table", "cell readiness requires its descriptor")
      return assertion("cell", {
        matrixMemberId = descriptor.matrixMemberId,
        index = descriptor.index,
      }, "cell " .. tostring(descriptor.matrixMemberId) .. ":" .. tostring(descriptor.index))
    end,
    requestMonPortraitPage = function(pageId, urgency)
      assert(type(pageId) == "number" and pageId % 1 == 0 and pageId >= 0, "portrait request requires its page")
      return ask("portrait", urgency, { pageId = pageId })
    end,
    requestIconPage = function(pageId, urgency)
      assert(type(pageId) == "number" and pageId % 1 == 0 and pageId >= 0, "icon request requires its page")
      return ask("icon-page", urgency, { pageId = pageId })
    end,
    milestoneStatus = function(name)
      assert(type(name) == "string" and name ~= "", "milestone progress requires its name")
      local active = guard()
      local ready, failure = active.service:observe(active.epoch, { requestKind = "milestone", name = name })
      if ready then
        return { state = "ready", ready = 1, total = 1, failure = nil }
      end
      if failure ~= nil then
        return { state = "failed", ready = 0, total = nil, failure = failure }
      end
      return { state = "pending", ready = 0, total = nil, failure = nil }
    end,
    status = function()
      local active = guard()
      local ready, failure = active.service:observe(active.epoch, { requestKind = "milestone", name = "bootstrap" })
      if ready then
        return { bootstrap = "ready" }
      end
      if failure ~= nil then
        return { bootstrap = "failed" }
      end
      return { bootstrap = "pending" }
    end,
  }
  return self
end

---@return table<string, function> borrowed semantic host for the selected game
function DerivedAssetProvisioner:gameHost()
  assert(not self.retired, "derived-asset provisioner is retired")
  return assert(self.host, "derived-asset host is unavailable")
end

-- Owner-only lifecycle authorization for background corpus completion.
-- Delegates to the epoch-qualified service authorization, which stays
-- idempotent and performs no cache work in the call itself. Never exposed
-- through gameHost: gameplay code requests concrete artifacts, never
-- corpus policy.
function DerivedAssetProvisioner:startBackgroundWarmup()
  assert(not self.retired, "derived-asset provisioner is retired")
  assert(self.service, "derived-asset service is unavailable")
  self.service:enableSweep(self.epoch)
end

-- Pump transport observations once. Production work, failure attribution,
-- and readiness all live below the controller; this call only moves
-- bounded request/status traffic.
function DerivedAssetProvisioner:update()
  if self.retired then
    return
  end
  self.service:update()
end

function DerivedAssetProvisioner:dispose()
  if self.retired then
    return
  end
  self.retired = true
  self.host = nil
  -- Retiring the epoch revokes observation rights immediately; physical
  -- controller work settles asynchronously under existing ownership, and
  -- the process service itself is never touched here.
  if self.service ~= nil and type(self.service.retire) == "function" then
    self.service:retire(self.epoch)
  end
  self.service = nil
end

return DerivedAssetProvisioner
