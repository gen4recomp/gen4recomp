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

---@param stage CacheFs
---@param bundle table<string, unknown>
---@param liveFs CacheFs|nil live filesystem hosting already-published shared blobs
---@param share (fun(path: string))|nil shared-file registrar for worker stages
local function stageBundle(stage, bundle, liveFs, share)
  for _, path in ipairs(StarterChoiceAssetCache.referencedPaths(bundle.manifest)) do
    if path:sub(1, #StarterChoiceAssetCache.assetDir()) == StarterChoiceAssetCache.assetDir() then
      stage:write(path, bundle.assets[path])
    elseif share ~= nil then
      stage:write(path, bundle.assets[path])
      share(path)
    else
      assert(liveFs, "starter-choice staging requires a live filesystem for shared blobs")
      liveFs:write(path, bundle.assets[path])
    end
  end
  stage:writeLua(StarterChoiceAssetCache.manifestPath(), bundle.manifest)
  local manifest = stage:loadLua(StarterChoiceAssetCache.manifestPath())
  if manifest == nil then
    Errors.raise(StarterChoiceAssetCacheWriter.ERROR.READBACK_FAILED, "starter-choice manifest readback is missing", {})
  end
  -- Errors.raise always throws but carries no noreturn annotation, so the
  -- missing guard alone does not narrow; reaching here proves a table.
  assert(manifest ~= nil, "starter-choice manifest readback is present after the missing guard")
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
    local present = stage:exists(path, "file") or (liveFs ~= nil and liveFs:exists(path, "file"))
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

---@param artifact PreparedArtifact
---@param bundle table<string, unknown>
---@return string
function StarterChoiceAssetCacheWriter.stage(artifact, bundle)
  assert(artifact and artifact.stageFs, "starter-choice staging requires a PreparedArtifact")
  assert(bundle, "starter-choice staging requires a bundle")
  validateBundle(bundle)
  artifact:addOwnedRoot(StarterChoiceAssetCache.assetDir())
  artifact:addOwnedRoot(StarterChoiceAssetCache.dir())
  stageBundle(artifact:stageFs(), bundle, artifact:cacheFs(), function(path)
    artifact:addSharedFile(path)
  end)
  return bundle.marker
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
  local ok, err = pcall(stageBundle, tx.stage, bundle, cacheFs, nil)
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
