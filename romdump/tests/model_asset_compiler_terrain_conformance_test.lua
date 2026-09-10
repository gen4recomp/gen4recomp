-- ModelAssetCompiler terrain routing: cross-batch boundary repair applies to
-- the map and neighbor terrain roles only, and mesh hashes follow the
-- post-repair bytes.
--
-- The model compiler already knows whether a model is terrain
-- (context.role map/neighbor) or something else (placed buildings, actors,
-- indicators). These tests drive compileModel with a two-batch terrain
-- fixture whose batches form a T-seam, with the mesh-compilation step
-- substituted by canned compiled batches so the routing decision itself is
-- what the assertions observe. Texture/model fixtures mirror the standard
-- 8x8 map-texture shape, so UV normalization divides texel units by eight.

local Assert = require("tests.support.Assert")
local Hashing = require("romdump.src.digest.Hashing")
local MeshCompiler = require("romdump.src.digest.model.MeshCompiler")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local ModelAssetCompiler = require("romdump.src.digest.model.ModelAssetCompiler")
local GeometryBuffer = require("libs.nds.src.gx.GxGeometryBuffer")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local NsbmdFixture = require("tests.support.NsbmdFixture")
local Nsbtx = require("libs.nds.src.nitro.g3d.Nsbtx")
local TF = require("tests.support.TextureFixtures")
local Tex0Fixture = require("tests.support.Tex0Fixture")

local T = {}

local CONFORMER_MODULE = "romdump.src.digest.map.TerrainBoundaryConformer"

local function conformer()
  local ok, mod = pcall(require, CONFORMER_MODULE)
  Assert.isTrue(
    ok and type(mod) == "table" and type(mod.findTJunctions) == "function",
    "terrain boundary repair is missing: terrain roles are not routed through conformance"
  )
  return mod --[[@as table]]
end

local BASE_TEXEL = string.rep(string.char(0x11), 32)
local BASE_PALETTE = { TF.BLACK, TF.RED, TF.GREEN, TF.BLACK }

local function V(x, y, z, u, v)
  return {
    x = x,
    y = y,
    z = z,
    u = u or 0,
    v = v or 0,
    nx = 0,
    ny = 1,
    nz = 0,
    r = 255,
    g = 255,
    b = 255,
    a = 255,
    colorSource = 0,
  }
end

-- Two batches sharing the span x=0, z in [0,4]: the coarse side is one quad,
-- the fine side breaks the span at P=(0,1,2). UVs are normalized for the
-- 8x8 fixture texture, as they are at the MeshCompiler seam.
local function cannedBatches()
  local coarse = {
    nodeIndex = 0,
    materialIndex = 0,
    shapeIndex = 0,
    polygonAttrRaw = 0x001F00C1,
    transformMode = "static",
    vertices = { V(-4, 1, 0, 0, 0), V(0, 1, 0, 4, 0), V(0, 1, 4, 4, 4), V(-4, 1, 4, 0, 4) },
    indices = { 0, 1, 2, 0, 2, 3 },
  }
  local fine = {
    nodeIndex = 0,
    materialIndex = 0,
    shapeIndex = 0,
    polygonAttrRaw = 0x001F00C1,
    transformMode = "static",
    vertices = {
      V(4, 1, 0, 8, 0),
      V(0, 1, 0, 4, 0),
      V(4, 1, 2, 8, 2),
      V(0, 1, 2, 4, 2),
      V(4, 1, 4, 8, 4),
      V(0, 1, 4, 4, 4),
    },
    indices = { 1, 0, 2, 1, 2, 3, 3, 2, 4, 3, 4, 5 },
  }
  local arena = GeometryBuffer.new()
  local batches = {}
  for index, source in ipairs({ coarse, fine }) do
    arena:reserve(#source.vertices, #source.indices)
    local vertexOffset, indexOffset = arena.vertexCount, arena.indexCount
    for vertexIndex, vertex in ipairs(source.vertices) do
      local numeric = arena.numeric[vertexOffset + vertexIndex - 1]
      numeric.x, numeric.y, numeric.z = vertex.x, vertex.y, vertex.z
      numeric.u, numeric.v = vertex.u / 8, vertex.v / 8
      numeric.nx, numeric.ny, numeric.nz = vertex.nx, vertex.ny, vertex.nz
      local attrib = arena.attrib[vertexOffset + vertexIndex - 1]
      attrib.r, attrib.g, attrib.b, attrib.a = vertex.r, vertex.g, vertex.b, vertex.a
      attrib.colorSource = vertex.colorSource
    end
    for indexValue, value in ipairs(source.indices) do
      arena.indices[indexOffset + indexValue - 1] = value
    end
    arena.vertexCount = vertexOffset + #source.vertices
    arena.indexCount = indexOffset + #source.indices
    batches[index] = {
      nodeIndex = source.nodeIndex,
      materialIndex = source.materialIndex,
      shapeIndex = source.shapeIndex,
      polygonAttrRaw = source.polygonAttrRaw,
      transformMode = source.transformMode,
      arena = arena,
      vertexOffset = vertexOffset,
      vertexCount = #source.vertices,
      indexOffset = indexOffset,
      indexCount = #source.indices,
    }
  end
  return batches
end

local function fixtures()
  local modelBytes = NsbmdFixture.build({
    modelName = "map0",
    materialName = "m_grass",
    textureName = "flower01",
    paletteName = "map_pal",
    origWidth = 8,
    origHeight = 8,
    triangle = { { 0, 0, 0 }, { 2, 0, 0 }, { 0, 0, 3 } },
  })
  local model = assert(Nsbmd.decode(modelBytes, { alias = "land_data", memberId = 244 })).models[1]
  local packBytes = Tex0Fixture.btx0({
    textures = { { name = "flower01", texel = BASE_TEXEL } },
    palettes = { { name = "map_pal", palette = TF.palette(BASE_PALETTE) } },
  })
  local pack = assert(Nsbtx.decode(packBytes, { alias = "map_textures", memberId = 3 }))
  return model, pack
end

local function compileWithCannedBatches(model, pack, role)
  local saved = MeshCompiler.compile
  -- The routing decision is the contract under test, not mesh decoding: the
  -- mesh step is deliberately substituted with canned two-batch fixtures for
  -- the duration of one compile and restored immediately after.
  MeshCompiler.compile = function()
    return cannedBatches()
  end
  local meshes, textures = {}, {}
  local ok, result = pcall(ModelAssetCompiler.compileModel, model, pack, meshes, textures, {
    mapId = 61,
    role = role,
    textureArchive = "map_textures",
    textureMemberId = 3,
    modelArchive = "land_data",
    modelMemberId = 244,
    modelName = "map0",
  })
  MeshCompiler.compile = saved
  if not ok then
    error(result, 0)
  end
  return meshes
end

function T.rejects_table_backed_compiler_output()
  local model, pack = fixtures()
  local saved = MeshCompiler.compile
  MeshCompiler.compile = function()
    return {
      {
        nodeIndex = 0,
        materialIndex = 0,
        shapeIndex = 0,
        polygonAttrRaw = 0x001F00C1,
        transformMode = "static",
        vertices = { V(0, 0, 0), V(1, 0, 0), V(0, 0, 1) },
        indices = { 0, 1, 2 },
      },
    }
  end
  local ok = pcall(ModelAssetCompiler.compileModel, model, pack, {}, {}, {
    role = "building",
    modelArchive = "land_data",
    modelMemberId = 244,
    modelName = "map0",
  })
  MeshCompiler.compile = saved
  Assert.isFalse(ok, "model asset compilation requires dense geometry slices")
end

local function storedBatches(meshes)
  local out = {}
  for _, batch in pairs(meshes) do
    out[#out + 1] = batch
  end
  return out
end

local function hasVertexAt(batch, x, y, z)
  for offset = 0, batch.vertexCount - 1 do
    local v = batch.arena.numeric[batch.vertexOffset + offset]
    if v.x == x and v.y == y and v.z == z then
      return true
    end
  end
  return false
end

-- The stored batch covering the coarse corner A=(-4,1,0) is the coarse side.
local function coarseStored(meshes)
  for _, batch in pairs(meshes) do
    if hasVertexAt(batch, -4, 1, 0) then
      return batch
    end
  end
  error("no stored batch covers the coarse corner")
end

local function vertexAt(batch, x, y, z)
  for offset = 0, batch.vertexCount - 1 do
    local v = batch.arena.numeric[batch.vertexOffset + offset]
    if v.x == x and v.y == y and v.z == z then
      local attrib = batch.arena.attrib[batch.vertexOffset + offset]
      return {
        x = v.x,
        y = v.y,
        z = v.z,
        u = v.u,
        v = v.v,
        nx = v.nx,
        ny = v.ny,
        nz = v.nz,
        r = attrib.r,
        g = attrib.g,
        b = attrib.b,
        a = attrib.a,
        colorSource = attrib.colorSource,
      }
    end
  end
  return nil
end

function T.map_role_passes_terrain_through_conformance()
  local model, pack = fixtures()
  local meshes = compileWithCannedBatches(model, pack, "map")
  Assert.equal(#conformer().findTJunctions(storedBatches(meshes)), 0, "map-role batches leave no T-junction")
  Assert.isTrue(hasVertexAt(coarseStored(meshes), 0, 1, 2), "map-role repair splits the coarse edge at P")
  local inserted = assert(vertexAt(coarseStored(meshes), 0, 1, 2), "inserted breakpoint is readable")
  Assert.near(inserted.u, 0.5, 1e-12, "inserted u is interpolated then normalized by the texture width")
  Assert.near(inserted.v, 0.25, 1e-12, "inserted v is interpolated then normalized by the texture height")
end

function T.neighbor_role_passes_terrain_through_conformance()
  local model, pack = fixtures()
  local meshes = compileWithCannedBatches(model, pack, "neighbor")
  Assert.equal(#conformer().findTJunctions(storedBatches(meshes)), 0, "neighbor-role batches leave no T-junction")
  Assert.isTrue(hasVertexAt(coarseStored(meshes), 0, 1, 2), "neighbor-role repair splits the coarse edge at P")
end

function T.non_terrain_roles_bypass_conformance()
  local model, pack = fixtures()
  local meshes = compileWithCannedBatches(model, pack, "building")
  -- The canned compiler output is already normalized, so the expected bytes
  -- are the unchanged batches.
  local rawHashes = {}
  for _, raw in ipairs(cannedBatches()) do
    rawHashes[#rawHashes + 1] = Hashing.sha1hex(MeshWriter.encode(raw))
  end
  table.sort(rawHashes)
  local storedHashes = {}
  for sha1 in pairs(meshes) do
    storedHashes[#storedHashes + 1] = sha1
  end
  table.sort(storedHashes)
  Assert.deepEqual(storedHashes, rawHashes, "non-terrain batches serialize byte-identically")
  Assert.isFalse(hasVertexAt(coarseStored(meshes), 0, 1, 2), "non-terrain batches gain no breakpoint")
end

function T.mesh_hashes_follow_post_conformance_bytes()
  local model, pack = fixtures()
  local meshes = compileWithCannedBatches(model, pack, "map")
  for sha1, batch in pairs(meshes) do
    Assert.equal(sha1, Hashing.sha1hex(MeshWriter.encode(batch)), "every mesh key hashes the bytes actually stored")
  end
  local coarse = coarseStored(meshes)
  Assert.isTrue(hasVertexAt(coarse, 0, 1, 2), "the hashed content includes the inserted breakpoint")
  local rawCoarse = cannedBatches()[1]
  Assert.isFalse(hasVertexAt(rawCoarse, 0, 1, 2), "the pre-repair bytes lacked it, so hashes track post-repair output")
end

-- Invisible and wireframe batches cannot take part in filled-surface
-- boundary repair: they neither contribute breakpoints nor receive splits,
-- and they never trigger interpolation conflicts. Polygon state rides the
-- compiled batch's resolved POLYGON_ATTR word: bits 6/7 clear means the
-- batch renders neither surface (culled), and a zero polygon alpha means
-- the host draws wireframe instead of a filled surface.
local NORMAL_RAW = 0x001F00C1
local CULL_ALL_RAW = 0x001F0001
local WIREFRAME_RAW = 0x000000C1

local function compileCustom(model, pack, role, batches)
  local saved = MeshCompiler.compile
  MeshCompiler.compile = function()
    return batches
  end
  local meshes, textures = {}, {}
  local ok, result = pcall(ModelAssetCompiler.compileModel, model, pack, meshes, textures, {
    mapId = 61,
    role = role,
    textureArchive = "map_textures",
    textureMemberId = 3,
    modelArchive = "land_data",
    modelMemberId = 244,
    modelName = "map0",
  })
  MeshCompiler.compile = saved
  if not ok then
    error(result, 0)
  end
  return meshes
end

local function tryCompileCustom(model, pack, role, batches)
  local saved = MeshCompiler.compile
  MeshCompiler.compile = function()
    return batches
  end
  local meshes, textures = {}, {}
  local ok, result = pcall(ModelAssetCompiler.compileModel, model, pack, meshes, textures, {
    mapId = 61,
    role = role,
    textureArchive = "map_textures",
    textureMemberId = 3,
    modelArchive = "land_data",
    modelMemberId = 244,
    modelName = "map0",
  })
  MeshCompiler.compile = saved
  return ok, result, meshes
end

function T.culled_candidate_cannot_split_a_visible_neighbor()
  local model, pack = fixtures()
  local batches = cannedBatches()
  batches[1].polygonAttrRaw = NORMAL_RAW
  batches[2].polygonAttrRaw = CULL_ALL_RAW
  local meshes = compileCustom(model, pack, "map", batches)
  local coarse = coarseStored(meshes)
  Assert.isFalse(hasVertexAt(coarse, 0, 1, 2), "a culled candidate contributes no breakpoint")
  Assert.equal(coarse.vertexCount, 4, "the visible neighbor gains no vertices from a culled batch")
  Assert.equal(coarse.indexCount, 6, "the visible neighbor gains no indices from a culled batch")
end

function T.wireframe_candidate_cannot_split_a_filled_neighbor()
  local model, pack = fixtures()
  local batches = cannedBatches()
  batches[1].polygonAttrRaw = NORMAL_RAW
  batches[2].polygonAttrRaw = WIREFRAME_RAW
  local meshes = compileCustom(model, pack, "map", batches)
  local coarse = coarseStored(meshes)
  Assert.isFalse(hasVertexAt(coarse, 0, 1, 2), "a wireframe candidate contributes no breakpoint")
  Assert.equal(coarse.vertexCount, 4, "the filled neighbor gains no vertices from a wireframe batch")
  Assert.equal(coarse.indexCount, 6, "the filled neighbor gains no indices from a wireframe batch")
end

function T.wireframe_side_is_not_retriangulated()
  local model, pack = fixtures()
  local batches = cannedBatches()
  batches[1].polygonAttrRaw = WIREFRAME_RAW
  batches[2].polygonAttrRaw = NORMAL_RAW
  local meshes = compileCustom(model, pack, "map", batches)
  local coarse = coarseStored(meshes)
  Assert.isFalse(hasVertexAt(coarse, 0, 1, 2), "an ineligible side receives no breakpoint")
  Assert.equal(coarse.vertexCount, 4, "the wireframe batch keeps its vertices byte-for-byte")
  Assert.equal(coarse.indexCount, 6, "the wireframe batch keeps its indices byte-for-byte")
end

function T.culled_candidate_does_not_trigger_an_interpolation_conflict()
  local model, pack = fixtures()
  local batches = cannedBatches()
  batches[1].polygonAttrRaw = NORMAL_RAW
  batches[2].polygonAttrRaw = CULL_ALL_RAW
  batches[1].arena.attrib[batches[1].vertexOffset + 1].colorSource = 0
  batches[1].arena.attrib[batches[1].vertexOffset + 2].colorSource = 1
  local ok, result, meshes = tryCompileCustom(model, pack, "map", batches)
  Assert.isTrue(ok, "an ineligible breakpoint never reaches conflict analysis: " .. tostring(not ok and result or ""))
  ---@cast meshes table
  local coarse = coarseStored(meshes)
  Assert.isFalse(hasVertexAt(coarse, 0, 1, 2), "the visible neighbor is unchanged")
  Assert.equal(coarse.vertexCount, 4, "no vertex churn from an ineligible candidate")
  Assert.equal(coarse.indexCount, 6, "no index churn from an ineligible candidate")
end

return { tests = T }
