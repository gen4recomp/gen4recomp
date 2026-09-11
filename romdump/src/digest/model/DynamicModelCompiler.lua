-- Compiles animated model descriptors and their content-addressed geometry.

local MaterialCompiler = require("romdump.src.digest.model.MaterialCompiler")
local ffi = require("ffi")
local DsPolygonAttr = require("libs.nds.src.gx.DsPolygonAttr")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local Hashing = require("romdump.src.digest.Hashing")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local AnimationClip = require("libs.assets.src.model.AnimationClip")
local NsbmdDynamicModel = require("romdump.src.digest.model.NsbmdDynamicModel")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local PolygonState = require("libs.assets.src.model.PolygonState")

local DynamicModelCompiler = {}

local function finalizeMesh(batch)
  local vertexCount = assert(batch.vertexCount or (batch.vertices and #batch.vertices))
  local indexCount = assert(batch.indexCount or (batch.indices and #batch.indices))
  local size = MeshWriter.encodedSize(vertexCount, indexCount)
  local data = love.data.newByteData(size)
  local pointer = ffi.cast("uint8_t *", assert(data:getFFIPointer()))
  assert(MeshWriter.encodeInto(batch, pointer, size) == size)
  return data
end

local function patternVariants(clips)
  local byMaterial = {}
  for _, clip in ipairs(clips) do
    if clip.kind == AnimationClip.KINDS.PATTERN then
      local names = clip.compiled.textureNames
      local pltts = clip.compiled.paletteNames
      for _, target in ipairs(clip.compiled.targets) do
        local set = byMaterial[target.name] or {}
        for _, key in ipairs(target.keys) do
          local texName = names[key.texIdx + 1]
          local plttName
          if key.plttIdx ~= 0xFF then
            plttName = pltts[key.plttIdx + 1]
          end
          local variantName = plttName and (texName .. "+" .. plttName) or texName
          if not set[variantName] then
            set[variantName] = { texName = texName, plttName = plttName }
          end
        end
        byMaterial[target.name] = set
      end
    end
  end
  return byMaterial
end

local function resolvePatternVariants(embeddedTex, variantSets, textures, unresolved, context)
  local byMaterial = {}
  for materialName, set in pairs(variantSets) do
    local variants = {}
    for variantName, pair in pairs(set) do
      local fakeMat = { name = variantName, textureName = pair.texName, paletteName = pair.plttName }
      local resolved =
        MaterialCompiler.resolveTexture(fakeMat, embeddedTex, textures, unresolved, { context = context })
      local variant = { name = variantName }
      if resolved.texture then
        variant.texture = MapAssetCache.texturePath(resolved.texture)
        variant.width = resolved.texWidth
        variant.height = resolved.texHeight
        variant.textureFormat = resolved.textureFormat
        variant.alphaUsage = textures[resolved.texture].alphaUsage
      end
      variants[variantName] = variant
    end
    byMaterial[materialName] = variants
  end
  return byMaterial
end

local function dynamicMaterials(dynamicModel, matCompiled, textures, variantsByName)
  local out = {}
  for _, base in ipairs(dynamicModel.materials) do
    local merged = {}
    for k, v in pairs(base) do
      merged[k] = v
    end
    local m = matCompiled.materials[base.id + 1]
    if m then
      if m.texture then
        merged.texture = MapAssetCache.texturePath(m.texture)
        merged.textureFormat = m.textureFormat
        merged.alphaUsage = textures[m.texture].alphaUsage
      end
      merged.wrap = m.wrap
      merged.flip = m.flip
      merged.diffuse = m.diffuse
    end
    local variants = variantsByName[base.name]
    if variants then
      local list = {}
      for _, variant in pairs(variants) do
        list[#list + 1] = variant
      end
      table.sort(list, function(a, b)
        return a.name < b.name
      end)
      merged.variants = list
    end
    out[#out + 1] = merged
  end
  return out
end

local function dynamicBatches(dynamicModel, meshes, context)
  local out = {}
  for _, mesh in ipairs(dynamicModel.meshes) do
    local poly = DsPolygonAttr.decode(mesh.polygonAttrRaw)
    if poly.polygonMode ~= "modulation" and poly.polygonMode ~= "decal" then
      require("libs.errors.src.Errors").raise(
        "MAP_COMPILE_UNSUPPORTED_POLYGON_MODE",
        "polygon mode " .. poly.polygonMode .. " is not supported",
        { polygonMode = poly.polygonMode, meshId = mesh.id }
      )
    end
    if poly.cullMode ~= "all" then
      local batch = mesh.batch --[[@as MeshWriter.Batch]]
      local data = context.finalizeMeshes and finalizeMesh(batch) or nil
      local sha1 = Hashing.sha1hex(data or MeshWriter.encode(batch))
      meshes[sha1] = data or batch
      local record = {
        id = mesh.id,
        drawIndex = mesh.drawIndex,
        segmentIndex = mesh.segmentIndex,
        nodeIndex = mesh.nodeIndex,
        materialIndex = mesh.materialIndex,
        transformMode = mesh.transformMode,
        positionSource = mesh.positionSource,
        geometry = MapAssetCache.geometryPath(sha1),
      }
      for _, field in ipairs(PolygonState.FIELDS) do
        record[field] = poly[field]
      end
      if mesh.straddle then
        record.straddle = mesh.straddle
      end
      out[#out + 1] = record
    end
  end
  return out
end

---@param buildingModel table<string, unknown>
---@param buildingNsbmd table<string, unknown>
---@param texPack table<string, unknown>
---@param animResult table<string, unknown>
---@param context table<string, unknown>
---@param memberId integer
---@param textures table<string, table<string, unknown>>
---@param meshes table<string, table<string, unknown>>
---@return table<string, unknown>, table[]
function DynamicModelCompiler.compile(
  buildingModel,
  buildingNsbmd,
  texPack,
  animResult,
  context,
  memberId,
  textures,
  meshes
)
  if context.finalizeMeshes and context.geometryArena then
    context.geometryArena:reset()
  end
  local dynamicModel = NsbmdDynamicModel.compile(buildingModel, context)
  local base = MaterialCompiler.compile(buildingModel.materials, texPack, { context = context })
  for sha1, tex in pairs(base.textures) do
    textures[sha1] = tex
  end

  local unresolved = {}
  local variantsByName = {}
  local embeddedTex = buildingNsbmd.embeddedTextures
  local variants = patternVariants(animResult.clips)
  if embeddedTex then
    variantsByName = resolvePatternVariants(embeddedTex, variants, textures, unresolved, context)
  elseif next(variants) then
    unresolved[#unresolved + 1] = {
      material = buildingModel.name,
      kind = "texture",
      name = "<pattern variants>",
      source = "model has no embedded TEX0",
    }
  end

  local wrapped = {}
  for _, entry in ipairs(unresolved) do
    wrapped[#wrapped + 1] = {
      role = context.role,
      modelArchive = context.modelArchive,
      modelMemberId = context.modelMemberId,
      modelName = context.modelName,
      material = entry.material,
      kind = entry.kind,
      name = entry.name,
      source = entry.source,
    }
  end

  return {
    schema = ModelAsset.SCHEMA,
    memberId = memberId,
    kind = "nitro-dynamic",
    dynamic = {
      nodes = dynamicModel.program.nodes,
      transformProgram = dynamicModel.program,
      batches = dynamicBatches(dynamicModel, meshes, context),
    },
    materials = dynamicMaterials(dynamicModel, base, textures, variantsByName),
    animations = animResult.clips,
    doorSoundType = animResult.doorSoundType,
  },
    wrapped
end

return DynamicModelCompiler
