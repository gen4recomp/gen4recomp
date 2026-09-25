-- Durable attestation that the bounded first-play closure for one immutable
-- cache generation reached ready successfully. After raw ROM extraction the
-- app routes every selection through FirstPlayCachePreparation until this
-- attestation is current; once published, ordinary boots keep the fast
-- bootstrap/menu path without revalidating the closure.
--
-- The attestation means only that: the four first-play milestones plus the
-- exact initial requestLocation() closure were observed ready together. It
-- never vouches for the whole corpus; the strict whole-corpus attestation
-- stays solely at DerivedCacheState.path, which this module never reads or
-- writes.
--
-- The stored record is { schema, generationId } at data/generated/first-play.lua
-- below the version root. generationId is the interactive selection
-- generation token (DerivedCacheState.currentForSelection: ROM SHA-1,
-- producer identity/mode, asset revision, script API version), supplied by
-- the caller. The module never derives producer identity itself: release
-- callers use releaseGenerationId (pure constants, no scan), while the
-- development digest stays below the controller thread and reaches the
-- caller through the cache service. Any producer or contract change yields
-- a different token, so an older completion is automatically stale. publish
-- stages a temporary sibling and atomically replaces the live state; a
-- failed write or replace raises and leaves the previous state (or its
-- absence) in place.

local GameVersion = require("romdump.src.source.GameVersion")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local DerivedCacheVersions = require("romdump.src.config.DerivedCacheVersions")

local FirstPlayCompletion = {}

-- Schema of the persisted record itself; bump when its shape changes.
FirstPlayCompletion.schema = 1

-- Attestation path below the version root, kept out of every runtime asset
-- load and distinct from the whole-corpus build attestation.
FirstPlayCompletion.path = "data/generated/first-play.lua"

local RECORD_KEYS = { schema = true, generationId = true }

---@param cacheFs table<string, unknown>? injected version cache; defaults to the live version root
---@param versionId string
---@return table<string, unknown>
local function versionCache(versionId, cacheFs)
  if cacheFs ~= nil then
    return cacheFs
  end
  local CacheFs = require("libs.storage.src.CacheFs")
  return CacheFs.forVersion(versionId)
end

local function isRecord(value)
  return type(value) == "table"
end

-- The release generation token for the version, derived from pure
-- constants only (accepted ROM SHA-1, explicit per-game release counter,
-- asset revision, script API version): no producer scan, no cache IO, safe
-- on the game thread. Development identity is never derived here.
---@param versionId string
---@return string generation token for the current release generation
function FirstPlayCompletion.releaseGenerationId(versionId)
  local info = GameVersion.info(versionId)
  assert(type(info) == "table" and type(info.sha1) == "string", "unknown version: " .. tostring(versionId))
  local counter = DerivedCacheVersions[versionId]
  assert(
    type(counter) == "number" and counter % 1 == 0 and counter >= 1,
    "release counter must be a positive integer for version: " .. tostring(versionId)
  )
  local identity = DerivedCacheState.currentForSelection({
    versionId = versionId,
    romSha1 = info.sha1,
    producerId = "r" .. tostring(counter),
  })
  return assert(identity.generationId, "selection identity carries no generation token")
end

-- True when the stored record carries exactly this schema and generation
-- token. Missing, malformed, previous-schema, and extra-field records are
-- incomplete, never an error: the caller prepares again.
---@param versionId string
---@param generationId string?
---@param cacheFs table<string, unknown>? injected version cache for tests
---@return boolean
function FirstPlayCompletion.isCurrent(versionId, generationId, cacheFs)
  if type(versionId) ~= "string" or versionId == "" then
    return false
  end
  if type(generationId) ~= "string" or generationId == "" then
    return false
  end
  local ok, stored = pcall(function()
    return versionCache(versionId, cacheFs):loadLua(FirstPlayCompletion.path)
  end)
  if not ok or not isRecord(stored) then
    return false
  end
  local count = 0
  for key in pairs(stored) do
    if not RECORD_KEYS[key] then
      return false
    end
    count = count + 1
  end
  if count ~= 2 then
    return false
  end
  return stored.schema == FirstPlayCompletion.schema and stored.generationId == generationId
end

-- True when any attestation file exists for the version, current or stale.
-- Lets preparation wait for the controller-derived generation instead of
-- demanding the closure while currency is still unknown.
---@param versionId string
---@param cacheFs table<string, unknown>? injected version cache for tests
---@return boolean
function FirstPlayCompletion.hasStored(versionId, cacheFs)
  if type(versionId) ~= "string" or versionId == "" then
    return false
  end
  local ok, exists = pcall(function()
    return versionCache(versionId, cacheFs):exists(FirstPlayCompletion.path, "file")
  end)
  return ok and exists == true
end

-- Atomically persist the generation token: write a temporary sibling, then
-- replace the live state. A failed write or failed replace raises and
-- leaves the previous state (or its absence) in place. Call only after the
-- full first-play closure was observed ready; failure and cancellation
-- paths never call this.
---@param versionId string
---@param generationId string
---@param cacheFs table<string, unknown>? injected version cache for tests
function FirstPlayCompletion.publish(versionId, generationId, cacheFs)
  assert(type(versionId) == "string" and versionId ~= "", "first-play completion requires its version")
  assert(type(generationId) == "string" and generationId ~= "", "first-play completion requires its generation token")
  local cache = versionCache(versionId, cacheFs)
  local staged = FirstPlayCompletion.path .. ".new"
  cache:writeLua(staged, { schema = FirstPlayCompletion.schema, generationId = generationId })
  cache:replace(staged, FirstPlayCompletion.path)
end

return FirstPlayCompletion
