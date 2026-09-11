-- Publishes the compiled field-bag presentation class through the shared
-- stage/validate/publish lifecycle. Shared content-addressed model blobs go
-- directly to the live shared roots (idempotent and inert on failure, like
-- map geometry); the bag-owned manifest, pane/sprite images, and completion
-- marker stage under the family roots with the marker last, so a failed
-- publication leaves the previous ready family untouched.

local Errors = require("libs.errors.src.Errors")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local BagAssetSchema = require("libs.assets.src.BagAssetSchema")
local BagCache = require("libs.assets.src.BagCache")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

local BagCacheWriter = {}

BagCacheWriter.ERROR = {
  BUNDLE_INVALID = "BAG_CACHE_BUNDLE_INVALID",
  READBACK_FAILED = "BAG_CACHE_READBACK_FAILED",
  PUBLICATION_FAILED = "BAG_CACHE_PUBLICATION_FAILED",
}

function BagCacheWriter.isReady(cacheFs, marker)
  return BagCache.isReady(cacheFs, marker)
end

---@param bundle table<string, unknown>
local function validateBundle(bundle)
  if type(bundle) ~= "table" or type(bundle.marker) ~= "string" or bundle.marker == "" then
    Errors.raise(BagCacheWriter.ERROR.BUNDLE_INVALID, "bag bundle carries no marker", {})
  end
  if type(bundle.manifest) ~= "table" or type(bundle.assets) ~= "table" then
    Errors.raise(BagCacheWriter.ERROR.BUNDLE_INVALID, "bag bundle carries no manifest payload", {})
  end
  if type(bundle.dependencies) ~= "table" then
    Errors.raise(BagCacheWriter.ERROR.BUNDLE_INVALID, "bag bundle carries no dependency record", {})
  end
  if bundle.dependencies.cacheFormat ~= BagCache.FORMAT or bundle.dependencies.schema ~= BagCache.SCHEMA then
    Errors.raise(BagCacheWriter.ERROR.BUNDLE_INVALID, "bag bundle dependencies identify the wrong cache", {})
  end
  local ok, err = pcall(BagAssetSchema.assertManifest, bundle.manifest)
  if not ok then
    Errors.raise(BagCacheWriter.ERROR.BUNDLE_INVALID, "bag manifest is invalid: " .. Errors.format(err), {})
  end
  for _, gender in ipairs({ "male", "female" }) do
    local valid, modelErr = pcall(ModelAsset.validate, bundle.manifest.hero.model[gender])
    if not valid then
      Errors.raise(
        BagCacheWriter.ERROR.BUNDLE_INVALID,
        "bag hero model " .. gender .. " is invalid: " .. tostring(modelErr),
        { gender = gender }
      )
    end
  end
  for _, path in ipairs(BagCache.referencedPaths(bundle.manifest)) do
    if bundle.assets[path] == nil then
      Errors.raise(
        BagCacheWriter.ERROR.BUNDLE_INVALID,
        "bag bundle is missing referenced asset " .. path,
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
  for _, path in ipairs(BagCache.referencedPaths(bundle.manifest)) do
    if path:sub(1, #BagCache.assetDir()) == BagCache.assetDir() then
      stage:write(path, bundle.assets[path])
    else
      cacheFs:write(path, bundle.assets[path])
    end
  end
  stage:writeLua(BagCache.provenancePath(), bundle.dependencies)
  stage:writeLua(BagCache.manifestPath(), bundle.manifest)
  local dependencies = stage:loadLua(BagCache.provenancePath())
  if
    type(dependencies) ~= "table"
    or dependencies.cacheFormat ~= BagCache.FORMAT
    or dependencies.schema ~= BagCache.SCHEMA
  then
    Errors.raise(BagCacheWriter.ERROR.READBACK_FAILED, "bag dependencies readback is invalid", {})
  end
  local manifest = stage:loadLua(BagCache.manifestPath())
  local ok, err = pcall(BagAssetSchema.assertManifest, manifest)
  if not ok then
    Errors.raise(BagCacheWriter.ERROR.READBACK_FAILED, "bag manifest readback is invalid: " .. Errors.format(err), {})
  end
  for _, path in ipairs(BagCache.referencedPaths(manifest)) do
    local present = stage:exists(path, "file") or cacheFs:exists(path, "file")
    if not present then
      Errors.raise(BagCacheWriter.ERROR.READBACK_FAILED, "bag asset missing after stage: " .. path, { path = path })
    end
  end
  stage:write(BagCache.markerPath(), bundle.marker)
end

---@param cacheFs CacheFs
---@param bundle table<string, unknown>
---@return boolean
function BagCacheWriter.write(cacheFs, bundle)
  assert(cacheFs and bundle, "bag publication requires a cache and a bundle")
  validateBundle(bundle)
  local tx = ArtifactPublisher.begin(cacheFs, "bag", { BagCache.assetDir(), BagCache.dir() })
  local ok, err = pcall(stageBundle, tx, bundle, cacheFs)
  if not ok then
    tx:abort()
    error(err, 0)
  end
  local published, publishErr = pcall(tx.publish, tx)
  if not published then
    Errors.raise(
      BagCacheWriter.ERROR.PUBLICATION_FAILED,
      "bag publication failed: " .. tostring(publishErr),
      { cause = tostring(publishErr) }
    )
  end
  return true
end

return BagCacheWriter
