-- The one model-compilation core producing content-addressed batches, meshes,
-- and textures for one decoded model bound to one texture pack. MapAssetCompiler
-- (map and placed-building models) and NeighborChunkCompiler (terrain models)
-- both call compileModel; each caller owns its bundle accumulators and
-- continues from the returned batches/materials/unresolved records. The batch
-- record's polygon draw state rides the shared PolygonState schema and the
-- transform-mode vocabulary comes from PoseContract, so the serialized model
-- descriptor has exactly one authority.

local MeshCompiler = require("romdump.src.digest.model.MeshCompiler")
local ffi = require("ffi")
local TerrainBoundaryConformer = require("romdump.src.digest.map.TerrainBoundaryConformer")
local MaterialCompiler = require("romdump.src.digest.model.MaterialCompiler")
local AlphaClassifier = require("libs.nds.src.gx.AlphaClassifier")
local DsPolygonAttr = require("libs.nds.src.gx.DsPolygonAttr")
local Errors = require("libs.errors.src.Errors")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local Hashing = require("romdump.src.digest.Hashing")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local PoseContract = require("libs.assets.src.model.PoseContract")
local PolygonState = require("libs.assets.src.model.PolygonState")
local TextureMatrixState = require("romdump.src.digest.model.TextureMatrixState")

local ModelAssetCompiler = {}

---@param batch MeshWriter.Batch
---@return love.Data
local function finalizeMesh(batch)
  local vertexCount = assert(batch.vertexCount or (batch.vertices and #batch.vertices))
  local indexCount = assert(batch.indexCount or (batch.indices and #batch.indices))
  local size = MeshWriter.encodedSize(vertexCount, indexCount)
  local data = love.data.newByteData(size)
  local pointer = ffi.cast("uint8_t *", assert(data:getFFIPointer()))
  assert(MeshWriter.encodeInto(batch, pointer, size) == size)
  return data
end

-- A compiled batch takes part in terrain boundary conformance only when it
-- is drawn as a filled surface: culled batches render nothing and
-- polygon-alpha-zero batches render as host wireframe, so neither can own
-- the filled-surface sampling disagreement repair addresses.
local function isConformable(poly)
  return poly.cullMode ~= "all" and poly.polygonAlpha ~= 0
end

-- Conform the eligible filled-surface batches of one terrain model in place,
-- leaving ineligible batches byte-identical. The conformer works on the same
-- batch tables in original order, so production batch positions and material
-- identity never shift; only a compacted error batch index is remapped to
-- its original position before the failure propagates.
local function conformEligible(compiled, polyByBatch, context)
  local eligible = {}
  local originalIndex = {}
  for i, batch in ipairs(compiled) do
    if isConformable(polyByBatch[i]) then
      eligible[#eligible + 1] = batch
      originalIndex[#eligible] = i
    end
  end
  if #eligible == 0 then
    return
  end
  local ok, err = pcall(TerrainBoundaryConformer.conform, eligible, context)
  if not ok then
    if Errors.is(err) then
      ---@cast err Errors.Error
      local failed = err.context.batchIndex
      if type(failed) == "number" then
        local original = originalIndex[failed]
        if original ~= nil then
          err.context.batchIndex = original
        end
      end
    end
    error(err, 0)
  end
end

-- Convert MaterialCompiler records (texture = sha1 key) into scene material
-- records (texture = cache-relative PNG path). Polygon state (alpha class,
-- cull mode, polygon alpha/mode) lives on the batch, not the material.
-- `terrainStateById` supplies the shared decoded-material texture-matrix
-- fields (texWidth/texHeight/texMtxMode and the normalized static srt) for
-- terrain scene materials; building models compile without it.
local function sceneMaterials(records, terrainStateById)
  local out = {}
  for _, m in ipairs(records) do
    local record = {
      id = m.id,
      name = m.name,
      texture = m.texture and MapAssetCache.texturePath(m.texture) or nil,
      textureFormat = m.textureFormat,
      wrap = m.wrap,
      flip = m.flip,
      diffuse = m.diffuse,
    }
    local terrain = terrainStateById and terrainStateById[m.id]
    if terrain then
      record.texWidth = terrain.texWidth
      record.texHeight = terrain.texHeight
      record.texMtxMode = terrain.texMtxMode
      record.srt = terrain.srt
    end
    out[#out + 1] = record
  end
  return out
end

-- Compile one model into batches; append meshes/textures to the shared bundle
-- accumulators; return { batches (scene refs), materials, unresolved } -- the
-- last being the materials whose names the bound pack does not define, tagged
-- with the model they came from so a caller can report them. When the caller
-- passes a map-scoped terrain-animation compiler in
-- `context.terrainAnimationCompiler` and the role is a terrain role (map or
-- neighbor), every material whose texture name an fldtanime record names gets
-- a textureSwap record and its alternate frames join the shared texture
-- accumulator; other roles never gain terrain annotation.
---@param model table<string, unknown>
---@param texturePack table<string, unknown>
---@param meshes table<string, unknown>
---@param textures table<string, table<string, unknown>>
---@param context table<string, unknown>
---@return { batches: table[], materials: table[], unresolved: table[] }
local function compileModel(model, texturePack, meshes, textures, context)
  local mat = MaterialCompiler.compile(model.materials, texturePack, { context = context })
  for sha1, tex in pairs(mat.textures) do
    textures[sha1] = tex
  end

  local unresolved = {}
  for _, entry in ipairs(mat.unresolved) do
    unresolved[#unresolved + 1] = {
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

  -- Per-material texture info needed for batch classification and UV normalization.
  local matInfoById = {}
  local textureSizes = {}
  for _, m in ipairs(mat.materials) do
    matInfoById[m.id] = {
      texWidth = m.texWidth,
      texHeight = m.texHeight,
      textureFormat = m.textureFormat or 0,
      alphaUsage = m.texture and textures[m.texture] and textures[m.texture].alphaUsage or nil,
    }
    if m.texWidth then
      textureSizes[m.id] = { width = m.texWidth, height = m.texHeight }
    end
  end

  -- Terrain scene materials (map and neighbor roles) carry the decoded
  -- texture-matrix fields, the same conversion the dynamic model base
  -- materials use; placed-building models never gain them.
  local isTerrain = context.role == "map" or context.role == "neighbor"

  local terrainStateById
  if isTerrain then
    terrainStateById = {}
    for _, material in ipairs(model.materials) do
      terrainStateById[material.index] = TextureMatrixState.fromMaterial(material, model.info.texMtxMode)
    end
  end

  local materials = sceneMaterials(mat.materials, terrainStateById)
  if isTerrain and context.terrainAnimationCompiler then
    for i, m in ipairs(mat.materials) do
      -- A matched record yields a textureSwap record; an unmatched material
      -- or one that failed texture binding leaves the field omitted.
      local swap = context.terrainAnimationCompiler:annotateMaterial(model.materials[i], m, texturePack, textures)
      if swap then
        materials[i].textureSwap = swap
      end
    end
  end

  -- Terrain roles share one compiled batch set whose material boundaries
  -- must agree on segmentation before serialization; other roles bypass
  -- boundary repair. Polygon state is decoded once per batch here and
  -- reused for conformance eligibility, alpha classification, and
  -- serialization below.
  local compiled = MeshCompiler.compile(model, { geometryArena = context.geometryArena, textureSizes = textureSizes })
  local polyByBatch = {}
  for i, batch in ipairs(compiled) do
    polyByBatch[i] = DsPolygonAttr.decode(batch.polygonAttrRaw)
  end
  if isTerrain then
    conformEligible(compiled, polyByBatch, context)
  end

  local batches = {}
  for index, batch in ipairs(compiled) do
    assert(batch.arena ~= nil, "model asset compilation requires dense geometry slices")
    local info = matInfoById[batch.materialIndex]

    local poly = polyByBatch[index]
    if poly.cullMode ~= "all" then
      local fmt = info and info.textureFormat or 0
      local alphaClass =
        AlphaClassifier.classify(poly.polygonAlpha, poly.polygonMode, fmt, info and info.alphaUsage or nil)
      local mesh = context.finalizeMeshes and finalizeMesh(batch --[[@as MeshWriter.Batch]]) or batch
      local sha1 =
        Hashing.sha1hex(context.finalizeMeshes and mesh or MeshWriter.encode(batch --[[@as MeshWriter.Batch]]))
      meshes[sha1] = mesh
      local record = {
        geometry = MapAssetCache.geometryPath(sha1),
        material = batch.materialIndex,
        node = batch.nodeIndex,
        -- A billboard batch's geometry is in billboard-local space and its
        -- matrix is only resolvable against a live camera; the runtime rebuilds
        -- it from baseTransform every frame. The static mode is the default and
        -- is left off, so it does not repeat on every batch of every scene.
        transformMode = batch.transformMode ~= PoseContract.STATIC and batch.transformMode or nil,
        baseTransform = batch.baseTransform,
        alphaClass = alphaClass,
      }
      -- The shared polygon draw-state field set (PolygonState.FIELDS).
      for _, field in ipairs(PolygonState.FIELDS) do
        record[field] = poly[field]
      end
      -- The static-only extras stay outside the shared draw-state schema:
      -- they are authoring metadata the runtime does not consume.
      record.farClipEnabled = poly.farClipEnabled
      record.oneDotEnabled = poly.oneDotEnabled
      batches[#batches + 1] = record
    end
  end
  return { batches = batches, materials = materials, unresolved = unresolved }
end

ModelAssetCompiler.compileModel = compileModel

return ModelAssetCompiler
