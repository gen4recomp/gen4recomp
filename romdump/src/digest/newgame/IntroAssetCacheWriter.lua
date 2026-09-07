-- Publishes the generated Professor Oak/profile visual class through the
-- shared stage/validate/publish lifecycle. The marker is written last in the
-- staged data root, and a failed replacement leaves the previous ready class.

local Errors = require("libs.errors.src.Errors")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local IntroAssetCache = require("libs.assets.src.newgame.IntroAssetCache")

local IntroAssetCacheWriter = {}

function IntroAssetCacheWriter.isReady(cacheFs, marker)
  return IntroAssetCache.isReady(cacheFs, marker)
end

local function stageBundle(tx, bundle)
  local stage = tx.stage
  stage:writeLua(IntroAssetCache.provenancePath(), bundle.dependencies)
  for path, bytes in pairs(bundle.assets) do
    stage:write(path, bytes)
  end
  stage:writeLua(IntroAssetCache.manifestPath(), bundle.manifest)
  local manifest = stage:loadLua(IntroAssetCache.manifestPath())
  local valid, err = IntroAssetCache.validateManifest(manifest)
  if not valid then
    assert(err)
    Errors.raise("INTRO_CACHE_READBACK_FAILED", "intro manifest readback is invalid", { cause = err.message })
  end
  local provenance = stage:loadLua(IntroAssetCache.provenancePath())
  local provenanceValid, provenanceErr = IntroAssetCache.validateProvenance(provenance)
  if not provenanceValid then
    assert(provenanceErr)
    Errors.raise("INTRO_CACHE_READBACK_FAILED", "intro provenance readback is invalid", {
      cause = provenanceErr.message,
    })
  end
  if not stage:exists(manifest.background.image, "file") then
    Errors.raise(
      "INTRO_CACHE_READBACK_FAILED",
      "intro background missing after stage",
      { image = manifest.background.image }
    )
  end
  for _, widget in pairs(manifest.widgets) do
    for _, frame in ipairs(widget.frames) do
      if not stage:exists(frame.image, "file") then
        Errors.raise("INTRO_CACHE_READBACK_FAILED", "intro widget missing after stage", { image = frame.image })
      end
    end
  end
  stage:write(IntroAssetCache.markerPath(), bundle.marker)
end

---@param cacheFs CacheFs
---@param bundle table<string, unknown>
---@return boolean
function IntroAssetCacheWriter.write(cacheFs, bundle)
  assert(cacheFs and bundle and bundle.marker and bundle.manifest and bundle.dependencies and bundle.assets)
  assert(bundle.manifest.schemaVersion == 11, "intro manifest schema mismatch")
  local tx = ArtifactPublisher.begin(cacheFs, "intro", { IntroAssetCache.assetDir(), IntroAssetCache.dir() })
  local ok, err = pcall(stageBundle, tx, bundle)
  if not ok then
    tx:abort()
    error(err, 0)
  end
  local published, publishErr = pcall(tx.publish, tx)
  if not published then
    Errors.raise("INTRO_CACHE_PUBLICATION_FAILED", "intro publication failed: " .. tostring(publishErr), {
      cause = tostring(publishErr),
    })
  end
  return true
end

return IntroAssetCacheWriter
