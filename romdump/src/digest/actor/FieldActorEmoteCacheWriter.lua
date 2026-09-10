-- Transactional writer for the normalized movement-emote billboard descriptor.

local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local FieldEmoteAssetCache = require("libs.assets.src.field.FieldEmoteAssetCache")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

local Writer = {}
function Writer.write(cacheFs, bundle)
  local tx = ArtifactPublisher.begin(cacheFs, "field-emotes", {
    "assets/generated/field/emotes",
    "data/generated/field/emotes",
  })
  local ok, err = pcall(function()
    for sha1, mesh in pairs(bundle.meshes) do
      tx.stage:write(FieldEmoteAssetCache.geometryPath(sha1), MeshWriter.encode(mesh))
    end
    for sha1, texture in pairs(bundle.textures) do
      tx.stage:write(
        FieldEmoteAssetCache.texturePath(sha1),
        assert(texture.data, "compiled texture is missing finalized PNG Data")
      )
    end
    tx.stage:writeLua(FieldEmoteAssetCache.exclamationDescriptorPath(), bundle.model)
    local descriptor = assert(tx.stage:loadLua(FieldEmoteAssetCache.exclamationDescriptorPath()))
    local valid, validationErr = FieldEmoteAssetCache.validateDescriptor(descriptor)
    if not valid then
      error(validationErr, 0)
    end
    for _, path in ipairs(ModelAsset.referencedPaths(descriptor.model)) do
      assert(tx.stage:exists(path), "field-emote referenced asset is missing: " .. path)
    end
    tx.stage:write(FieldEmoteAssetCache.markerPath(), bundle.marker)
  end)
  if not ok then
    tx:abort()
    error(err, 0)
  end
  tx:publish()
end
return Writer
