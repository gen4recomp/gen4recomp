-- Transactional writer for the normalized movement-emote billboard descriptor.

local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local FieldEmoteAssetCache = require("libs.assets.src.field.FieldEmoteAssetCache")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

local Writer = {}

---@param stage CacheFs
---@param bundle table<string, unknown>
local function persist(stage, bundle)
  for sha1, data in pairs(bundle.meshes) do
    stage:write(FieldEmoteAssetCache.geometryPath(sha1), data)
  end
  for sha1, texture in pairs(bundle.textures) do
    stage:write(
      FieldEmoteAssetCache.texturePath(sha1),
      assert(texture.data, "compiled texture is missing finalized PNG Data")
    )
  end
  stage:writeLua(FieldEmoteAssetCache.exclamationDescriptorPath(), bundle.model)
  local descriptor = assert(stage:loadLua(FieldEmoteAssetCache.exclamationDescriptorPath()))
  local valid, validationErr = FieldEmoteAssetCache.validateDescriptor(descriptor)
  if not valid then
    error(validationErr, 0)
  end
  for _, path in ipairs(ModelAsset.referencedPaths(descriptor.model)) do
    assert(stage:exists(path), "field-emote referenced asset is missing: " .. path)
  end
  stage:write(FieldEmoteAssetCache.markerPath(), bundle.marker)
end

---@param artifact PreparedArtifact
---@param bundle table<string, unknown>
---@return string
function Writer.stage(artifact, bundle)
  assert(artifact and artifact.stageFs, "field-emotes staging requires a PreparedArtifact")
  assert(type(bundle) == "table" and bundle.marker, "invalid field-emotes bundle")
  artifact:addOwnedRoot("assets/generated/field/emotes")
  artifact:addOwnedRoot("data/generated/field/emotes")
  persist(artifact:stageFs(), bundle)
  return bundle.marker
end

function Writer.write(cacheFs, bundle)
  local tx = ArtifactPublisher.begin(cacheFs, "field-emotes", {
    "assets/generated/field/emotes",
    "data/generated/field/emotes",
  })
  local ok, err = pcall(persist, tx.stage, bundle)
  if not ok then
    tx:abort()
    error(err, 0)
  end
  tx:publish()
end
return Writer
