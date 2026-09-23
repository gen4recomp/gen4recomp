-- Readiness and paths for the derived script cache. The translated script
-- corpus is one of the independently rebuildable derived classes (map
-- geometry, actor visuals, messages/font, scripts): changing the script
-- translator must not disturb the raw ROM dump or any compiled map.
-- Each immutable generation keeps its summary (index, provenance, coverage,
-- marker) under a `metadata/` child and its member payloads under
-- `members/`, so the summary can be published without replacing member
-- artifacts. The class is ready only when the completion marker matches exactly and
-- every indexed script file is present, so a partial build never reads as
-- complete. Paths are cache-relative; all IO goes through a CacheFs.

local ScriptCache = {}

---@class ScriptCache.Index
---@field schema string
---@field resources table[]

local Validate = require("libs.assets.src.Validate")
local Contract = require("libs.assets.src.DerivedAssetContract")

ScriptCache.FORMAT = Contract.scripts.cacheFormat
ScriptCache.INDEX_SCHEMA = Contract.scripts.indexSchema
ScriptCache.PROVENANCE_SCHEMA = Contract.scripts.provenanceSchema

local DATA_DIR = "data/generated/script"
local ACTIVE_DIR = DATA_DIR .. "/active"
local GENERATIONS_DIR = DATA_DIR .. "/generations"

local function isSafeGeneration(value)
  return type(value) == "string" and value:match("^[0-9a-f]+$") ~= nil and #value == 40
end

local function memberName(memberId)
  assert(type(memberId) == "number" and memberId % 1 == 0 and memberId >= 0, "member id must be a non-negative integer")
  return string.format("%04d", memberId)
end

function ScriptCache.dir()
  return DATA_DIR
end

function ScriptCache.activeDir()
  return ACTIVE_DIR
end

function ScriptCache.generationsDir()
  return GENERATIONS_DIR
end

function ScriptCache.activeIndexPath()
  return ACTIVE_DIR .. "/index.lua"
end

function ScriptCache.indexPath()
  return ScriptCache.activeIndexPath()
end
function ScriptCache.provenancePath()
  return ACTIVE_DIR .. "/provenance.lua"
end
function ScriptCache.markerPath()
  return ACTIVE_DIR .. "/complete"
end
function ScriptCache.coverageJsonPath()
  return ACTIVE_DIR .. "/coverage.json"
end
function ScriptCache.coverageMdPath()
  return ACTIVE_DIR .. "/coverage.md"
end

function ScriptCache.generationDir(generation)
  assert(isSafeGeneration(generation), "generation key must be lowercase hexadecimal")
  return GENERATIONS_DIR .. "/" .. generation
end

function ScriptCache.generationMetadataDir(generation)
  return ScriptCache.generationDir(generation) .. "/metadata"
end

function ScriptCache.generationIndexPath(generation)
  return ScriptCache.generationMetadataDir(generation) .. "/index.lua"
end

function ScriptCache.generationProvenancePath(generation)
  return ScriptCache.generationMetadataDir(generation) .. "/provenance.lua"
end

function ScriptCache.generationCoverageJsonPath(generation)
  return ScriptCache.generationMetadataDir(generation) .. "/coverage.json"
end

function ScriptCache.generationCoverageMdPath(generation)
  return ScriptCache.generationMetadataDir(generation) .. "/coverage.md"
end

function ScriptCache.generationMarkerPath(generation)
  return ScriptCache.generationMetadataDir(generation) .. "/complete"
end

function ScriptCache.memberDir(generation, memberId)
  return ScriptCache.generationDir(generation) .. "/members/" .. memberName(memberId)
end

function ScriptCache.memberCoveragePath(generation, memberId)
  return ScriptCache.memberDir(generation, memberId) .. "/coverage.lua"
end

function ScriptCache.memberMarkerPath(generation, memberId)
  return ScriptCache.memberDir(generation, memberId) .. "/complete"
end

-- Canonical per-resource hashes published alongside one member: the writer
-- stages this sidecar (validated there) before the member marker lands, so
-- a member without it is an incompatible older artifact, never a ready one.
ScriptCache.HASHES_SCHEMA = "g4-script-resource-hashes-v2"

function ScriptCache.memberHashesPath(generation, memberId)
  assert(isSafeGeneration(generation), "generation key must be lowercase hexadecimal")
  assert(type(memberId) == "number" and memberId % 1 == 0 and memberId >= 0, "member id must be a non-negative integer")
  return ScriptCache.memberDir(generation, memberId) .. "/resource-hashes.lua"
end

function ScriptCache.scriptPath(generation, memberId, id)
  assert(isSafeGeneration(generation), "generation key must be lowercase hexadecimal")
  assert(type(memberId) == "number" and memberId % 1 == 0 and memberId >= 0, "member id must be a non-negative integer")
  assert(type(id) == "string" and id ~= "", "script id must be a non-empty string")
  return string.format("%s/scripts/%s.lua", ScriptCache.memberDir(generation, memberId), id)
end

function ScriptCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", ScriptCache.FORMAT, romSha1, depHash)
end

function ScriptCache.loadActive(cacheFs)
  local marker = cacheFs:read(ScriptCache.markerPath())
  local active = cacheFs:loadLua(ScriptCache.activeIndexPath())
  if type(active) ~= "table" or active.schema ~= ScriptCache.INDEX_SCHEMA then
    return nil, "active script selection is malformed"
  end
  if not isSafeGeneration(active.generation) or type(active.marker) ~= "string" or active.marker == "" then
    return nil, "active script selection is incomplete"
  end
  if marker ~= active.marker then
    return nil, "active script marker does not match its index"
  end
  local generation = cacheFs:loadLua(ScriptCache.generationIndexPath(active.generation))
  if type(generation) ~= "table" or generation.schema ~= ScriptCache.INDEX_SCHEMA then
    return nil, "active script generation index is malformed"
  end
  if cacheFs:read(ScriptCache.generationMarkerPath(active.generation)) ~= active.marker then
    return nil, "active script generation is incomplete"
  end
  if generation.generation ~= active.generation or generation.marker ~= active.marker then
    return nil, "active script generation does not match its selector"
  end
  return { generation = active.generation, marker = active.marker, index = generation }
end

function ScriptCache.loadGenerationIndex(cacheFs, generation)
  local index = cacheFs:loadLua(ScriptCache.generationIndexPath(generation))
  if type(index) ~= "table" or index.schema ~= ScriptCache.INDEX_SCHEMA then
    return nil, "script generation index is malformed"
  end
  return index
end

local function isSortedUniqueStrings(value)
  if not Validate.isArray(value) then
    return false
  end
  local previous
  for _, entry in ipairs(value) do
    if type(entry) ~= "string" or entry == "" then
      return false
    end
    if previous ~= nil and previous >= entry then
      return false
    end
    previous = entry
  end
  return true
end

-- True when the value is a well-formed per-member audio closure mapping:
-- decimal member-id keys to sorted unique canonical sequence arrays.
local function isMemberAudioMapping(value)
  if type(value) ~= "table" then
    return false
  end
  for key, list in pairs(value) do
    if type(key) ~= "string" or key == "" or tostring(tonumber(key)) ~= key then
      return false
    end
    local memberId = tonumber(key)
    if memberId == nil or memberId < 0 or memberId % 1 ~= 0 then
      return false
    end
    if not isSortedUniqueStrings(list) then
      return false
    end
  end
  return true
end

local function resourceFilesReady(cacheFs, generation, index)
  if not Validate.isArray(index.resources) then
    return false
  end
  -- Every planned member carries its transitive audio closure (possibly
  -- empty) under its decimal id; a mapping without it belongs to an
  -- incompatible older index, and a malformed list can never attest audio.
  if not isMemberAudioMapping(index.memberAudioSequences) then
    return false
  end
  local seenIds = {}
  local seenMembers = {}
  for _, entry in ipairs(index.resources) do
    if type(entry) ~= "table" or type(entry.id) ~= "string" or entry.id == "" or type(entry.member) ~= "number" then
      return false
    end
    -- Every indexed resource carries its published canonical hash; a
    -- hashless entry belongs to an incompatible older index, and a repeated
    -- id would attest the same resource twice.
    if not Validate.isSha256Key(entry.resourceHash) then
      return false
    end
    if seenIds[entry.id] then
      return false
    end
    seenIds[entry.id] = true
    seenMembers[entry.member] = true
    local script = cacheFs:loadModule(ScriptCache.scriptPath(generation, entry.member, entry.id))
    if type(script) ~= "table" or script.kind ~= "field_script" or script.id ~= entry.id then
      return false
    end
  end
  for member in pairs(seenMembers) do
    local closure = index.memberAudioSequences[tostring(member)]
    if not isSortedUniqueStrings(closure) then
      return false
    end
  end
  return true
end

-- The transitive audio closure for one script member: sorted unique
-- canonical sequence symbols, possibly empty. Returns the list, or nil plus
-- a cause when the index carries no usable closure for the member. No IO.
---@param index table<string, unknown>
---@param memberId integer
---@return string[]|nil, string|nil
function ScriptCache.audioSequencesForMember(index, memberId)
  if type(index) ~= "table" or not isMemberAudioMapping(index.memberAudioSequences) then
    return nil, "script member audio metadata is malformed"
  end
  if type(memberId) ~= "number" or memberId < 0 or memberId % 1 ~= 0 then
    return nil, "script member identity is invalid: " .. tostring(memberId)
  end
  local closure = index.memberAudioSequences[tostring(memberId)]
  if closure == nil then
    return nil, "script member " .. tostring(memberId) .. " has no published audio closure"
  end
  if not isSortedUniqueStrings(closure) then
    return nil, "script member " .. tostring(memberId) .. " audio closure is malformed"
  end
  return closure
end

-- True only if the marker is exact, the index loads with the expected schema,
-- resources is the required array of entries, and every indexed script's file
-- loads as a field_script resource whose id matches its index entry.
---@param cacheFs CacheFs
---@param generation string
---@param expectedMarker string
---@return boolean
function ScriptCache.isGenerationReady(cacheFs, generation, expectedMarker)
  local ok, ready = pcall(function()
    if not isSafeGeneration(generation) or type(expectedMarker) ~= "string" or expectedMarker == "" then
      return false
    end
    local index = assert(ScriptCache.loadGenerationIndex(cacheFs, generation))
    if index.generation ~= generation or index.marker ~= expectedMarker then
      return false
    end
    if cacheFs:read(ScriptCache.generationMarkerPath(generation)) ~= expectedMarker then
      return false
    end
    return resourceFilesReady(cacheFs, generation, index)
  end)
  return ok and ready == true
end

function ScriptCache.isReady(cacheFs, expectedMarker)
  local ok, ready = pcall(function()
    if type(expectedMarker) ~= "string" or expectedMarker == "" then
      return false
    end
    local active = assert(ScriptCache.loadActive(cacheFs))
    return active.marker == expectedMarker and ScriptCache.isGenerationReady(cacheFs, active.generation, expectedMarker)
  end)
  return ok and ready == true
end

return ScriptCache
