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

---@param stage CacheFs
---@param bundle table<string, unknown>
local function persist(stage, bundle)
  for sha1, mesh in pairs(bundle.meshes) do
    stage:write(FieldEffectAssetCache.geometryPath(sha1), meshData(mesh))
  end
  for sha1, texture in pairs(bundle.textures) do
    stage:write(
      FieldEffectAssetCache.texturePath(sha1),
      assert(texture.data, "compiled texture is missing finalized PNG Data")
    )
  end
  for kind, definition in pairs(bundle.effects) do
    stage:writeLua(FieldEffectAssetCache.definitionPath(kind), definition)
    local descriptors = definition.models
    if descriptors == nil then
      local single = assert(definition.model, "field-effect definition has no model")
      descriptors = { single }
    end
    assert(#descriptors >= 1, "field-effect definition carries no model")
    for _, descriptor in ipairs(descriptors) do
      ModelAsset.validate(descriptor)
      for _, path in ipairs(ModelAsset.referencedPaths(descriptor)) do
        assert(stage:exists(path), "field-effect referenced asset is missing: " .. path)
      end
    end
  end
  stage:writeLua(FieldEffectAssetCache.indexPath(), bundle.index)
  stage:write(FieldEffectAssetCache.markerPath(), bundle.marker)
end

---@param artifact PreparedArtifact
---@param bundle table<string, unknown>
---@return string
function Writer.stage(artifact, bundle)
  assert(artifact and artifact.stageFs, "field-effects staging requires a PreparedArtifact")
  assert(type(bundle) == "table" and bundle.marker, "invalid field-effects bundle")
  artifact:addOwnedRoot("assets/generated/field/effects")
  artifact:addOwnedRoot("data/generated/field/effects")
  persist(artifact:stageFs(), bundle)
  return bundle.marker
end

function Writer.write(cacheFs, bundle)
  local tx = ArtifactPublisher.begin(cacheFs, "field-effects", {
    "assets/generated/field/effects",
    "data/generated/field/effects",
  })
  local ok, err = pcall(persist, tx.stage, bundle)
  if not ok then
    tx:abort()
    error(err, 0)
  end
  tx:publish()
end
return Writer
