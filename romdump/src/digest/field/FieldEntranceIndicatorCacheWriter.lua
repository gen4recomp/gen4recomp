-- Transactional writer for the normalized directional entrance field effect.

local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local ModelAsset = require("libs.assets.src.model.ModelAsset")

local Writer = {}

---@param mesh MeshWriter.Batch|love.Data
---@return string|love.Data
local function meshData(mesh)
  if type(mesh) ~= "table" or type(mesh.getSize) == "function" then
    ---@cast mesh love.Data
    return mesh
  end
  ---@cast mesh MeshWriter.Batch
  return MeshWriter.encode(mesh)
end

function Writer.write(cacheFs, bundle)
  local tx = ArtifactPublisher.begin(cacheFs, "field-effects", {
    "assets/generated/field/effects",
    "data/generated/field/effects",
  })
  local ok, err = pcall(function()
    for sha1, mesh in pairs(bundle.meshes) do
      tx.stage:write(FieldEffectAssetCache.geometryPath(sha1), meshData(mesh))
    end
    for sha1, texture in pairs(bundle.textures) do
      tx.stage:write(
        FieldEffectAssetCache.texturePath(sha1),
        assert(texture.data, "compiled texture is missing finalized PNG Data")
      )
    end
    for kind, definition in pairs(bundle.effects) do
      tx.stage:writeLua(FieldEffectAssetCache.definitionPath(kind), definition)
      local descriptors = definition.models
      if descriptors == nil then
        local single = assert(definition.model, "field-effect definition has no model")
        descriptors = { single }
      end
      assert(#descriptors >= 1, "field-effect definition carries no model")
      for _, descriptor in ipairs(descriptors) do
        ModelAsset.validate(descriptor)
        for _, path in ipairs(ModelAsset.referencedPaths(descriptor)) do
          assert(tx.stage:exists(path), "field-effect referenced asset is missing: " .. path)
        end
      end
    end
    tx.stage:writeLua(FieldEffectAssetCache.indexPath(), bundle.index)
    tx.stage:write(FieldEffectAssetCache.markerPath(), bundle.marker)
  end)
  if not ok then
    tx:abort()
    error(err, 0)
  end
  tx:publish()
end
return Writer
