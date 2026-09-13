-- Persists normalized field-camera profiles through the shared staged
-- publication primitive: both deterministic Lua artifacts are written into a
-- disposable staging root, read back there, and only then is the completed
-- stage published with the completion marker last. Staging and validation are
-- one step; publication happens outside that step's error handler, so a
-- publish failure never triggers writer-level stage cleanup that could delete
-- the last remaining copy of the previous artifact.

local Errors = require("libs.errors.src.Errors")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local FieldCameraCache = require("libs.assets.src.field.FieldCameraCache")

local FieldCameraCacheWriter = {}

function FieldCameraCacheWriter.isReady(cacheFs, marker)
  return FieldCameraCache.isReady(cacheFs, marker)
end

local function persist(stage, bundle)
  stage:writeLua(FieldCameraCache.profilesPath(), bundle.profiles)
  stage:writeLua(FieldCameraCache.provenancePath(), bundle.provenance)
  local profiles, profileErr = stage:loadLua(FieldCameraCache.profilesPath())
  local provenance, provenanceErr = stage:loadLua(FieldCameraCache.provenancePath())
  if not profiles or not provenance then
    Errors.raise(
      "FIELD_CAMERA_CACHE_STALE",
      "camera artifacts failed readback: " .. tostring(profileErr or provenanceErr),
      {}
    )
  end
  assert(profiles.schema == FieldCameraCache.SCHEMA)
  assert(profiles.recordCount == bundle.profiles.recordCount)
  stage:write(FieldCameraCache.markerPath(), bundle.marker)
  return bundle.marker
end

---@param artifact PreparedArtifact
---@param bundle table<string, unknown>
---@return string
function FieldCameraCacheWriter.stage(artifact, bundle)
  assert(artifact and artifact.stageFs, "camera staging requires a PreparedArtifact")
  assert(type(bundle) == "table" and bundle.marker, "invalid camera bundle")
  artifact:addOwnedRoot(FieldCameraCache.dir())
  return persist(artifact:stageFs(), bundle)
end

function FieldCameraCacheWriter.write(cacheFs, bundle)
  assert(cacheFs and type(bundle) == "table" and bundle.marker, "invalid camera bundle")
  local tx = ArtifactPublisher.begin(cacheFs, "field-cameras", { FieldCameraCache.dir() })
  local ok, result = pcall(persist, tx.stage, bundle)
  if not ok then
    tx:abort()
    error(result, 0)
  end
  tx:publish()
  return result
end

return FieldCameraCacheWriter
