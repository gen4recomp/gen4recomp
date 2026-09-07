-- Publishes the compiled choose-starter application class through the shared
-- stage/validate/publish lifecycle. Shared content-addressed model blobs go
-- directly to the live shared roots (idempotent and inert on failure, like
-- map geometry); the starter-owned manifest, sprite images, and completion
-- marker stage under the family roots with the marker last, so a failed
-- publication leaves the previous ready family untouched.

local Errors = require("libs.errors.src.Errors")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local StarterChoiceAssetCache = require("libs.assets.src.StarterChoiceAssetCache")

local StarterChoiceAssetCacheWriter = {}

StarterChoiceAssetCacheWriter.ERROR = {
  BUNDLE_INVALID = "STARTER_CHOICE_CACHE_BUNDLE_INVALID",
  READBACK_FAILED = "STARTER_CHOICE_CACHE_READBACK_FAILED",
  PUBLICATION_FAILED = "STARTER_CHOICE_CACHE_PUBLICATION_FAILED",
}

function StarterChoiceAssetCacheWriter.isReady(cacheFs, marker)
  return StarterChoiceAssetCache.isReady(cacheFs, marker)
end

---@param bundle table<string, unknown>
local function validateBundle(bundle)
  if type(bundle) ~= "table" or type(bundle.marker) ~= "string" or bundle.marker == "" then
    Errors.raise(StarterChoiceAssetCacheWriter.ERROR.BUNDLE_INVALID, "starter-choice bundle carries no marker", {})
  end
  if type(bundle.manifest) ~= "table" or type(bundle.assets) ~= "table" then
    Errors.raise(
      StarterChoiceAssetCacheWriter.ERROR.BUNDLE_INVALID,
      "starter-choice bundle carries no manifest payload",
      {}
    )
  end
  local valid, err = StarterChoiceAssetCache.validateManifest(bundle.manifest)
  if not valid then
    assert(err)
    Errors.raise(
      StarterChoiceAssetCacheWriter.ERROR.BUNDLE_INVALID,
      "starter-choice manifest is invalid: " .. err.message,
      { cause = err.code }
    )
  end
  for _, role in ipairs({ "tabletop", "turntable", "ballEffect", "ball1", "ball2", "ball3" }) do
    local ok, modelErr = pcall(ModelAsset.validate, bundle.manifest.models[role])
    if not ok then
      Errors.raise(
        StarterChoiceAssetCacheWriter.ERROR.BUNDLE_INVALID,
        "starter-choice model role " .. role .. " is invalid: " .. tostring(modelErr),
        { role = role }
      )
    end
  end
  for _, path in ipairs(StarterChoiceAssetCache.referencedPaths(bundle.manifest)) do
    if bundle.assets[path] == nil then
      Errors.raise(
        StarterChoiceAssetCacheWriter.ERROR.BUNDLE_INVALID,
        "starter-choice bundle is missing referenced asset " .. path,
        { path = path }
      )
    end
  end
end

---@param tx table<string, unknown>
---@param bundle table<string, unknown>
---@param cacheFs CacheFs
local function stageBundle(tx, bundle, cacheFs)
  local stage = tx.stage
  for _, path in ipairs(StarterChoiceAssetCache.referencedPaths(bundle.manifest)) do
    if path:sub(1, #StarterChoiceAssetCache.assetDir()) == StarterChoiceAssetCache.assetDir() then
      stage:write(path, bundle.assets[path])
    else
      cacheFs:write(path, bundle.assets[path])
    end
  end
  stage:writeLua(StarterChoiceAssetCache.manifestPath(), bundle.manifest)
  local manifest = stage:loadLua(StarterChoiceAssetCache.manifestPath())
  local valid, err = StarterChoiceAssetCache.validateManifest(manifest)
  if not valid then
    assert(err)
    Errors.raise(
      StarterChoiceAssetCacheWriter.ERROR.READBACK_FAILED,
      "starter-choice manifest readback is invalid: " .. err.message,
      { cause = err.code }
    )
  end
  for _, path in ipairs(StarterChoiceAssetCache.referencedPaths(manifest)) do
    local present = stage:exists(path, "file") or cacheFs:exists(path, "file")
    if not present then
      Errors.raise(
        StarterChoiceAssetCacheWriter.ERROR.READBACK_FAILED,
        "starter-choice asset missing after stage: " .. path,
        { path = path }
      )
    end
  end
  stage:write(StarterChoiceAssetCache.markerPath(), bundle.marker)
end

---@param cacheFs CacheFs
---@param bundle table<string, unknown>
---@return boolean
function StarterChoiceAssetCacheWriter.write(cacheFs, bundle)
  assert(cacheFs and bundle, "starter-choice publication requires a cache and a bundle")
  validateBundle(bundle)
  local tx = ArtifactPublisher.begin(
    cacheFs,
    "starter-choice",
    { StarterChoiceAssetCache.assetDir(), StarterChoiceAssetCache.dir() }
  )
  local ok, err = pcall(stageBundle, tx, bundle, cacheFs)
  if not ok then
    tx:abort()
    error(err, 0)
  end
  local published, publishErr = pcall(tx.publish, tx)
  if not published then
    Errors.raise(
      StarterChoiceAssetCacheWriter.ERROR.PUBLICATION_FAILED,
      "starter-choice publication failed: " .. tostring(publishErr),
      { cause = tostring(publishErr) }
    )
  end
  return true
end

return StarterChoiceAssetCacheWriter
