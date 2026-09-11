-- Readiness and paths for the derived script cache. The translated script
-- corpus is one of the independently rebuildable derived classes (map
-- geometry, actor visuals, messages/font, scripts): changing the script
-- translator must not disturb the raw ROM dump or any compiled map.
-- The class is ready only when the completion marker matches exactly and
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

function ScriptCache.generationIndexPath(generation)
  return ScriptCache.generationDir(generation) .. "/index.lua"
end

function ScriptCache.generationProvenancePath(generation)
  return ScriptCache.generationDir(generation) .. "/provenance.lua"
end

function ScriptCache.generationCoverageJsonPath(generation)
  return ScriptCache.generationDir(generation) .. "/coverage.json"
end

function ScriptCache.generationCoverageMdPath(generation)
  return ScriptCache.generationDir(generation) .. "/coverage.md"
end

function ScriptCache.generationMarkerPath(generation)
  return ScriptCache.generationDir(generation) .. "/complete"
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

local function resourceFilesReady(cacheFs, generation, index)
  if not Validate.isArray(index.resources) then
    return false
  end
  for _, entry in ipairs(index.resources) do
    if type(entry) ~= "table" or type(entry.id) ~= "string" or entry.id == "" or type(entry.member) ~= "number" then
      return false
    end
    local script = cacheFs:loadModule(ScriptCache.scriptPath(generation, entry.member, entry.id))
    if type(script) ~= "table" or script.kind ~= "field_script" or script.id ~= entry.id then
      return false
    end
  end
  return true
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
