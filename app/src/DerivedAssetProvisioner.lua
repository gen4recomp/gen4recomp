-- Semantic derived-asset host for one selected game. It wraps the selected
-- generation session on the injected process-owned compiler pool: fixed
-- milestone/field/cell/page/status operations propagate the session's
-- ready/pending/error distinctions with string urgencies, and disposal
-- retires the session without joining or destroying the shared pool.

local InteractiveCacheBuild = require("romdump.src.build.InteractiveCacheBuild")
local GameVersion = require("romdump.src.source.GameVersion")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local Errors = require("libs.errors.src.Errors")

---@class DerivedAssetProvisionerOptions
---@field versionId string selected game version
---@field producerFingerprint string release counter or development digest
---@field developmentRepositoryRoot string? present in development mode
---@field pool table<string, function> process-owned compiler pool, borrowed
---@field epoch integer selected source epoch, a positive integer

---@class DerivedAssetProvisioner
---@field session InteractiveCacheBuild
---@field pool table<string, function> process-owned compiler pool, borrowed
---@field retired boolean
---@field failure unknown|nil first latched infrastructure failure; stops further advancement
---@field host table<string, function>?
local DerivedAssetProvisioner = {}
DerivedAssetProvisioner.__index = DerivedAssetProvisioner

---@param options DerivedAssetProvisionerOptions
---@return table<string, unknown> generation identity for the selected source
local function sessionIdentity(options)
  assert(type(options.versionId) == "string" and options.versionId ~= "", "provisioner version is required")
  assert(
    type(options.producerFingerprint) == "string" and options.producerFingerprint ~= "",
    "provisioner producer fingerprint is required"
  )
  local info = GameVersion.info(options.versionId)
  assert(info ~= nil, "unsupported version: " .. tostring(options.versionId))
  return DerivedCacheState.currentForSelection({
    versionId = options.versionId,
    romSha1 = assert(info.sha1, "version has no ROM identity"),
    producerId = options.producerFingerprint,
    developmentRepositoryRoot = options.developmentRepositoryRoot,
  })
end

---@param options DerivedAssetProvisionerOptions
---@return DerivedAssetProvisioner
function DerivedAssetProvisioner.new(options)
  assert(type(options) == "table", "derived-asset provisioner options are required")
  assert(type(options.pool) == "table", "derived-asset provisioner requires the process-owned pool")
  assert(
    type(options.epoch) == "number" and options.epoch % 1 == 0 and options.epoch >= 1,
    "provisioner epoch must be a positive integer"
  )
  local session = InteractiveCacheBuild.new({
    identity = sessionIdentity(options),
    epoch = options.epoch,
    pool = options.pool,
    sweepEnabled = false,
  })
  local self = setmetatable(
    { session = session, pool = options.pool, retired = false, failure = nil, host = nil },
    DerivedAssetProvisioner
  )
  local function guard()
    if self.retired then
      Errors.raise("DERIVED_ASSETS_RETIRED", "derived-asset provisioner is retired", {})
    end
    return assert(self.session, "derived-asset session is unavailable")
  end
  local function checkFailure()
    if self.failure ~= nil then
      error(self.failure, 0)
    end
  end
  self.host = {
    requestMilestone = function(name, urgency)
      local active = guard()
      checkFailure()
      return active:requestMilestone(name, urgency)
    end,
    requestField = function(mapId, urgency)
      local active = guard()
      checkFailure()
      return active:requestField(mapId, urgency)
    end,
    ensureField = function(mapId)
      local active = guard()
      checkFailure()
      return active:ensureField(mapId)
    end,
    requestCell = function(descriptor, urgency)
      local active = guard()
      checkFailure()
      return active:requestCell(descriptor, urgency)
    end,
    ensureCell = function(descriptor)
      local active = guard()
      checkFailure()
      return active:ensureCell(descriptor)
    end,
    requestMonPortraitPage = function(pageId, urgency)
      local active = guard()
      checkFailure()
      return active:requestMonPortraitPage(pageId, urgency)
    end,
    status = function()
      local active = guard()
      checkFailure()
      return active:status()
    end,
  }
  return self
end

---@return table<string, function> borrowed semantic host for the selected game
function DerivedAssetProvisioner:gameHost()
  assert(not self.retired, "derived-asset provisioner is retired")
  return assert(self.host, "derived-asset host is unavailable")
end

---Authorizes exhaustive background warmup for the selected generation.
---Owner-only app lifecycle: call only after the menu game is installed.
---Idempotent; never part of the semantic game host.
function DerivedAssetProvisioner:startBackgroundWarmup()
  assert(not self.retired, "derived-asset provisioner is retired")
  if self.failure ~= nil then
    error(self.failure, 0)
  end
  assert(self.session, "derived-asset session is unavailable"):enableSweep()
end

function DerivedAssetProvisioner:update()
  if self.retired or self.failure ~= nil then
    return
  end
  local ok, err = pcall(function()
    self.session:update()
  end)
  if ok then
    return
  end
  -- A recorded pool infrastructure failure latches for the preparation view
  -- and stops further advancement. Anything else is a programming error and
  -- keeps propagating instead of becoming visible state.
  local pool = assert(self.pool, "derived-asset pool is unavailable")
  if type(pool.diagnostics) == "function" then
    local diagOk, diagnostics = pcall(pool.diagnostics, pool)
    if diagOk and type(diagnostics) == "table" and diagnostics.error ~= nil then
      self.failure = diagnostics.error
      return
    end
  end
  error(err, 0)
end

function DerivedAssetProvisioner:dispose()
  if self.retired then
    return
  end
  self.retired = true
  self.host = nil
  -- Retiring the session closes its source readers and drops its queued
  -- interest; physical workers keep their capacity until their actual
  -- completion, and the process pool itself is never touched here.
  self.session:retire()
end

return DerivedAssetProvisioner
