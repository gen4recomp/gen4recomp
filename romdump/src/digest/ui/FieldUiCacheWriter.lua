-- Persists a compiled field-UI bundle through the shared staged
-- publication primitive: provenance, the manifest, and every generated PNG
-- are written into a disposable staging root, readback-validated there, and
-- only then is the completed stage published with the marker last. Staging
-- and validation are one step; publication happens outside that step's
-- error handler, so a publish failure never triggers writer-level stage
-- cleanup that could delete the last remaining copy of the previous class.

local Errors = require("libs.errors.src.Errors")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")

local FieldUiCacheWriter = {}

function FieldUiCacheWriter.isReady(cacheFs, marker)
  return FieldUiAssetCache.isReady(cacheFs, marker)
end

local function stageBundle(stage, bundle)
  stage:writeLua(FieldUiAssetCache.provenancePath(), {
    schema = "g4-field-ui-provenance-v1",
    dependencies = bundle.dependencies,
  })
  for path, bytes in pairs(bundle.assets) do
    stage:write(path, bytes)
  end
  stage:writeLua(FieldUiAssetCache.manifestPath(), bundle.manifest)
  local manifest = stage:loadLua(FieldUiAssetCache.manifestPath())
  if type(manifest) ~= "table" or manifest.schema ~= FieldUiAssetCache.SCHEMA then
    Errors.raise("FIELD_UI_CACHE_READBACK_FAILED", "ui manifest readback failed", {})
  end
  local typedManifest = manifest --[[@as FieldUiAssetCache.Manifest]]
  local ok, err = FieldUiAssetCache.validateManifest(typedManifest)
  if not ok then
    Errors.raise("FIELD_UI_CACHE_READBACK_FAILED", "ui manifest readback is invalid", { cause = err and err.message })
  end
  for _, entry in pairs(typedManifest.assets) do
    if not stage:exists(entry.image, "file") then
      Errors.raise("FIELD_UI_CACHE_READBACK_FAILED", "ui asset missing after stage: " .. entry.image, {
        image = entry.image,
      })
    end
  end
  stage:write(FieldUiAssetCache.markerPath(), bundle.marker)
end

---@param artifact PreparedArtifact
---@param bundle table<string, unknown>
---@return string
function FieldUiCacheWriter.stage(artifact, bundle)
  assert(artifact and artifact.stageFs, "field-ui staging requires a PreparedArtifact")
  assert(bundle and bundle.marker and bundle.manifest and bundle.assets, "stage requires a UI bundle")
  assert(bundle.manifest.schema == FieldUiAssetCache.SCHEMA, "ui manifest schema mismatch")
  artifact:addOwnedRoot(FieldUiAssetCache.assetDir())
  artifact:addOwnedRoot(FieldUiAssetCache.dir())
  stageBundle(artifact:stageFs(), bundle)
  return bundle.marker
end

function FieldUiCacheWriter.write(cacheFs, bundle)
  assert(bundle and bundle.marker and bundle.manifest and bundle.assets, "write requires a UI bundle")
  assert(bundle.manifest.schema == FieldUiAssetCache.SCHEMA, "ui manifest schema mismatch")
  local tx = ArtifactPublisher.begin(cacheFs, "field-ui", {
    FieldUiAssetCache.assetDir(),
    FieldUiAssetCache.dir(),
  })
  local ok, err = pcall(stageBundle, tx.stage, bundle)
  if not ok then
    tx:abort()
    error(err, 0)
  end
  tx:publish()
  return true
end

return FieldUiCacheWriter
