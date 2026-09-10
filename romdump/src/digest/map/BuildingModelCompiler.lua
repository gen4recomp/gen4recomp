-- Compiles placed building models, animations, placements, and dependencies.

local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local Nsbtx = require("libs.nds.src.nitro.g3d.Nsbtx")
local BuildingTransform = require("romdump.src.digest.map.BuildingTransform")
local Matrix4 = require("libs.math.src.Matrix4")
local Hashing = require("romdump.src.digest.Hashing")
local ModelAssetCompiler = require("romdump.src.digest.model.ModelAssetCompiler")
local DynamicModelCompiler = require("romdump.src.digest.model.DynamicModelCompiler")
local MapPropAnimCompiler = require("romdump.src.digest.model.MapPropAnimCompiler")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local Errors = require("libs.errors.src.Errors")

local BuildingModelCompiler = {}

local function readMember(narc, alias, memberId)
  local count = narc:memberCount()
  assert(
    memberId >= 0 and memberId < count,
    string.format("%s member %d out of range (count %d)", alias, memberId, count)
  )
  return assert(narc:readMember(memberId))
end

local function sortedNumbers(set)
  local out = {}
  for value in pairs(set) do
    out[#out + 1] = value
  end
  table.sort(out)
  return out
end

local function archiveForArea(area)
  if area.areaType == "indoor" then
    return "interior_build_models"
  end
  if area.areaType == "outdoor" then
    return "exterior_build_models"
  end
  Errors.raise(
    "MAP_COMPILE_UNSUPPORTED_AREA",
    "unsupported area type for building model selection: " .. tostring(area.areaTypeRaw),
    { areaTypeRaw = area.areaTypeRaw }
  )
end

local function animListAliasForArea(area)
  if area.areaType == "indoor" then
    return "interior_build_anim_list"
  end
  if area.areaType == "outdoor" then
    return "exterior_build_anim_list"
  end
  Errors.raise(
    "MAP_COMPILE_UNSUPPORTED_AREA",
    "unsupported area type for building animation selection: " .. tostring(area.areaTypeRaw),
    { areaTypeRaw = area.areaTypeRaw }
  )
end

local function appendUnresolved(target, source)
  for _, entry in ipairs(source.unresolved) do
    target[#target + 1] = entry
  end
end

local function modelContext(opts, area, archiveAlias, memberId, buildingNsbmd, buildingModel, placementIndices)
  return {
    mapId = opts.mapId,
    mapSymbol = opts.mapSymbol,
    role = "building",
    areaDataMemberId = opts.areaDataMemberId,
    landDataMemberId = opts.landDataMemberId,
    textureArchive = "building_textures",
    textureMemberId = area.buildingTexturePackId,
    modelArchive = archiveAlias,
    modelMemberId = memberId,
    modelName = buildingModel.name,
    embeddedTex0Present = buildingNsbmd.embeddedTextures ~= nil,
    placementIndices = placementIndices,
    finalizeMeshes = opts.finalizeMeshes,
  }
end

---@param romFs RomFs
---@param area table<string, unknown>
---@param land table<string, unknown>
---@param opts table<string, unknown>
---@return table<string, unknown>
function BuildingModelCompiler.compile(romFs, area, land, opts)
  assert(type(opts) == "table" and opts.meshes and opts.textures, "building compilation requires accumulators")
  local archiveAlias = archiveForArea(area)
  local uniqueMembers, placementIndicesByMember = {}, {}
  for _, placement in ipairs(land.buildings) do
    uniqueMembers[placement.modelMemberId] = true
    local indices = placementIndicesByMember[placement.modelMemberId] or {}
    indices[#indices + 1] = placement.index
    placementIndicesByMember[placement.modelMemberId] = indices
  end
  for _, memberId in ipairs(opts.requiredModelMembers or {}) do
    uniqueMembers[memberId] = true
  end
  local memberIds = sortedNumbers(uniqueMembers)

  local bldNarc, bldTexPack, bldTexSha1
  if #memberIds > 0 then
    bldNarc = assert(romFs:openNarc(archiveAlias))
    local bldTexBytes =
      readMember(assert(romFs:openNarc("building_textures")), "building_textures", area.buildingTexturePackId)
    bldTexSha1 = Hashing.sha1hex(bldTexBytes)
    bldTexPack =
      assert(Nsbtx.decode(bldTexBytes, { alias = "building_textures", memberId = area.buildingTexturePackId }))
  end

  local animListNarc, animResNarc
  if #memberIds > 0 then
    animListNarc = assert(romFs:openNarc(animListAliasForArea(area)))
    animResNarc = assert(romFs:openNarc("build_anim"))
  end

  local models, modelKeyOf, memberShaOf = {}, {}, {}
  local unresolvedMaterials, animDeps = {}, {}
  for _, memberId in ipairs(memberIds) do
    local modelBytes = readMember(bldNarc, archiveAlias, memberId)
    local modelSha1 = Hashing.sha1hex(modelBytes)
    local buildingNsbmd = assert(Nsbmd.decode(modelBytes, { alias = archiveAlias, memberId = memberId }))
    local buildingModel = buildingNsbmd.models[1]
    local context =
      modelContext(opts, area, archiveAlias, memberId, buildingNsbmd, buildingModel, placementIndicesByMember[memberId])
    local modelDescriptor
    local animated = false
    if memberId < animListNarc:memberCount() then
      local listBytes = assert(animListNarc:readMember(memberId))
      animDeps[#animDeps + 1] = { memberId = memberId, sha1 = Hashing.sha1hex(listBytes) }
      local animResult = MapPropAnimCompiler.compile(listBytes, animResNarc, {
        archiveAlias = animListAliasForArea(area),
        memberId = memberId,
        resourceCache = opts.resourceCache,
      })
      for _, clip in ipairs(animResult.clips) do
        animDeps[#animDeps + 1] = { resourceId = clip.source.memberId, sha1 = clip.source.sha1 }
      end
      if #animResult.clips > 0 then
        local descriptor, unresolved = DynamicModelCompiler.compile(
          buildingModel,
          buildingNsbmd,
          bldTexPack,
          animResult,
          context,
          memberId,
          opts.textures,
          opts.meshes
        )
        for _, entry in ipairs(unresolved) do
          unresolvedMaterials[#unresolvedMaterials + 1] = entry
        end
        modelDescriptor, animated = descriptor, true
      end
    end
    if not animated then
      local compiled = ModelAssetCompiler.compileModel(buildingModel, bldTexPack, opts.meshes, opts.textures, context)
      appendUnresolved(unresolvedMaterials, compiled)
      modelDescriptor = {
        schema = ModelAsset.SCHEMA,
        memberId = memberId,
        kind = "static",
        batches = compiled.batches,
        materials = compiled.materials,
      }
    end
    local descriptorSha = Hashing.hashLua(modelDescriptor)
    local modelKey =
      string.format("%s:%d:%s", area.areaType == "indoor" and "indoor" or "outdoor", memberId, descriptorSha:sub(1, 12))
    modelDescriptor.key = modelKey
    models[modelKey] = modelDescriptor
    modelKeyOf[memberId] = modelKey
    memberShaOf[memberId] = modelSha1
  end

  local buildingInstances = {}
  for _, placement in ipairs(land.buildings) do
    buildingInstances[#buildingInstances + 1] = {
      placementIndex = placement.index,
      modelKey = modelKeyOf[placement.modelMemberId],
      transform = Matrix4.toArray(BuildingTransform.build(placement)),
    }
  end
  local buildingModelShas = {}
  for _, memberId in ipairs(memberIds) do
    buildingModelShas[#buildingModelShas + 1] = { memberId = memberId, sha1 = memberShaOf[memberId] }
  end
  return {
    buildingInstances = buildingInstances,
    models = models,
    unresolvedMaterials = unresolvedMaterials,
    buildingModelShas = buildingModelShas,
    animationListMemberSha1s = animDeps,
    archiveAlias = archiveAlias,
    buildingTextureMemberId = #memberIds > 0 and area.buildingTexturePackId or nil,
    buildingTextureMemberSha1 = bldTexSha1,
    modelKeyOf = modelKeyOf,
  }
end

return BuildingModelCompiler
