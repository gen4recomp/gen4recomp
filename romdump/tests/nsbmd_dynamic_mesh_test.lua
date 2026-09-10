-- Bind-pose invariant for the transform-preserving mesh path: the dynamic
-- compile (segments in pre-draw space + transform sources) resolved at the
-- bind pose must reproduce the static compile's baked batches -- vertex
-- positions, normals, and per-draw structure -- within numeric tolerance.
-- The runtime pose resolution is exercised exactly as the engine backend
-- will perform it: evaluate the program, resolve each mesh's sources,
-- transform the segment vertices.

local Assert = require("tests.support.Assert")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local MeshCompiler = require("romdump.src.digest.model.MeshCompiler")
local NsbmdDynamicModel = require("romdump.src.digest.model.NsbmdDynamicModel")
local NsbmdSbcEvaluator = require("libs.assets.src.model.NsbmdSbcEvaluator")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local GxRenderer = require("libs.nds.src.love.GxRenderer")
local ModelFixture = require("tests.support.NsbmdModelFixture")
local NsbmdFixture = require("tests.support.NsbmdFixture")
local Matrix4 = require("libs.math.src.Matrix4")
local NB = require("tests.support.NitroBuilder")
local DsPolygonAttr = require("libs.nds.src.gx.DsPolygonAttr")

local T = {}

local function u32(v)
  return NB.u32(v)
end

local TOL = 1e-6

-- The bind-pose provider the static path uses (folded out of its own module
-- into NsbmdStaticTransforms; tests rebuild the same shape for the shipped
-- descriptor's program).
local function bindPose(model)
  local nodes = model.nodes
  return {
    nodeSRT = function(nodeIndex)
      assert(type(nodeIndex) == "number", "nodeSRT requires a numeric node index")
      return nodes[nodeIndex + 1]
    end,
  }
end

-- The engine-side resolution: convert a draw matrix to tile space (only the
-- translation column divides by the tile size).
local function toTiles(m)
  local out = {}
  for i = 1, 12 do
    out[i] = m[i]
  end
  out[13], out[14], out[15] = m[13] / 16, m[14] / 16, m[15] / 16
  out[16] = m[16]
  return out
end

local function identity()
  return Matrix4.identity()
end

-- Resolve one mesh's position matrix against its draw record.
local function resolvePosition(draw, mesh)
  if mesh.positionSource == "draw" then
    return toTiles(draw.matrix)
  end
  local slot = draw.restoreStack[mesh.positionSource.slot]
  return toTiles(slot or identity())
end

local function vertex(batch, index)
  local numeric = batch.arena.numeric[batch.vertexOffset + index]
  local attrib = batch.arena.attrib[batch.vertexOffset + index]
  return {
    x = numeric.x,
    y = numeric.y,
    z = numeric.z,
    u = numeric.u,
    v = numeric.v,
    nx = numeric.nx,
    ny = numeric.ny,
    nz = numeric.nz,
    r = attrib.r,
    g = attrib.g,
    b = attrib.b,
    a = attrib.a,
    colorSource = attrib.colorSource,
  }
end

local function vertices(batch)
  local out = {}
  for index = 0, batch.vertexCount - 1 do
    out[#out + 1] = vertex(batch, index)
  end
  return out
end

-- Resolve the descriptor at the bind pose and compare every segment vertex
-- against the static compile's batch for the same draw.
local function assertBindPoseEquivalence(model)
  local staticBatches = MeshCompiler.compile(model)
  local descriptor = NsbmdDynamicModel.compile(model)
  local program = descriptor.program
  local draws = NsbmdSbcEvaluator.evaluate(program --[[@as NsbmdSbcEvaluator.Program]], bindPose(model)).draws

  -- Static batches are one per draw, in order; dynamic meshes are one per
  -- draw segment, also in order.
  Assert.equal(#descriptor.meshes, #staticBatches, model.name .. ": segment count equals static draw count")
  for meshIndex, mesh in ipairs(descriptor.meshes) do
    local batch = staticBatches[meshIndex]
    local draw = draws[mesh.drawIndex + 1]
    local label = string.format("%s mesh %s", model.name, mesh.id)
    Assert.equal(mesh.nodeIndex, batch.nodeIndex, label .. " nodeIndex")
    Assert.equal(mesh.materialIndex, batch.materialIndex, label .. " materialIndex")
    Assert.equal(mesh.transformMode, batch.transformMode, label .. " transformMode")

    local position = resolvePosition(draw, mesh)
    local direction = Matrix4.linear(position)

    Assert.equal(mesh.batch.vertexCount, batch.vertexCount, label .. " vertex count")
    for i, v in ipairs(vertices(mesh.batch)) do
      local s = vertex(batch, i - 1)
      local x = position[1] * v.x + position[5] * v.y + position[9] * v.z + position[13]
      local y = position[2] * v.x + position[6] * v.y + position[10] * v.z + position[14]
      local z = position[3] * v.x + position[7] * v.y + position[11] * v.z + position[15]
      if math.abs(x - s.x) > TOL or math.abs(y - s.y) > TOL or math.abs(z - s.z) > TOL then
        error(
          label
            .. " vertex "
            .. (i - 1)
            .. " position: static ("
            .. s.x
            .. ","
            .. s.y
            .. ","
            .. s.z
            .. ") vs resolved ("
            .. x
            .. ","
            .. y
            .. ","
            .. z
            .. ")"
        )
      end
      -- The static path renormalizes direction-transformed normals; the
      -- dynamic resolution does the same, so compare normalized directions.
      local nx = direction[1] * v.nx + direction[5] * v.ny + direction[9] * v.nz
      local ny = direction[2] * v.nx + direction[6] * v.ny + direction[10] * v.nz
      local nz = direction[3] * v.nx + direction[7] * v.ny + direction[11] * v.nz
      local length = math.sqrt(nx * nx + ny * ny + nz * nz)
      if length > 0 then
        nx, ny, nz = nx / length, ny / length, nz / length
      end
      if math.abs(nx - s.nx) > TOL or math.abs(ny - s.ny) > TOL or math.abs(nz - s.nz) > TOL then
        error(
          label
            .. " vertex "
            .. (i - 1)
            .. " normal: static ("
            .. s.nx
            .. ","
            .. s.ny
            .. ","
            .. s.nz
            .. ") vs resolved ("
            .. nx
            .. ","
            .. ny
            .. ","
            .. nz
            .. ")"
        )
      end
    end
    Assert.equal(mesh.batch.indexCount, batch.indexCount, label .. " index count")
  end
end

-- ---- corpus ----

function T.identity_node_posscale_model()
  local m = assert(Nsbmd.decode(NsbmdFixture.build())).models[1]
  assertBindPoseEquivalence(m)
end

function T.transformed_node_model()
  local m = assert(Nsbmd.decode(NsbmdFixture.buildTransformed())).models[1]
  assertBindPoseEquivalence(m)
end

function T.static_quad_model()
  local m = assert(Nsbmd.decode(NsbmdFixture.buildStaticQuad())).models[1]
  assertBindPoseEquivalence(m)
end

function T.billboard_quad_model()
  local m = assert(Nsbmd.decode(NsbmdFixture.buildBillboardQuad())).models[1]
  local descriptor = NsbmdDynamicModel.compile(m)
  local draws = NsbmdSbcEvaluator.evaluate(descriptor.program --[[@as NsbmdSbcEvaluator.Program]], bindPose(m)).draws
  Assert.equal(#descriptor.meshes, 1)
  Assert.equal(descriptor.meshes[1].transformMode, "billboard")
  -- The billboard's post-BB matrix is baked at compile, so the segment
  -- vertices match the static batch exactly; only the captured base remains
  -- runtime-resolved.
  Assert.isNil(descriptor.meshes[1].positionSource)
  local batch = MeshCompiler.compile(m)[1]
  for i, v in ipairs(vertices(descriptor.meshes[1].batch)) do
    local s = vertex(batch, i - 1)
    if math.abs(v.x - s.x) > TOL or math.abs(v.y - s.y) > TOL or math.abs(v.z - s.z) > TOL then
      error("billboard vertex " .. (i - 1) .. " differs from the static bake")
    end
  end
  Assert.notNil(draws[1].baseTransform)
end

-- The billboard bake is a per-segment loop invariant: the linear part of the
-- draw matrix feeds the normal transform of every vertex in the segment, so
-- it must be computed once per segment, not once per vertex. Observed through
-- a counting wrapper on the public Matrix4.linear entry point: the billboard
-- quad compiles into one segment of four vertices, so a per-segment
-- computation yields exactly one buffer operation while a per-vertex one
-- yields four.
function T.billboard_bake_linear_part_is_computed_once_per_segment()
  local m = assert(Nsbmd.decode(NsbmdFixture.buildBillboardQuad())).models[1]
  local originalLinearInto = Matrix4.linearInto
  local calls = 0
  Matrix4.linearInto = function(out, bake)
    calls = calls + 1
    return originalLinearInto(out, bake)
  end
  local ok, err = pcall(MeshCompiler.compileDynamic, m)
  Matrix4.linearInto = originalLinearInto
  assert(ok, tostring(err))
  Assert.equal(calls, 1, "billboard bake linear part computed once per segment (4 vertices, got " .. calls .. " calls)")
end

function T.matrix_slot_restore_two_nodes()
  local node0 = ModelFixture.transformedNodeData(10, 0, 0, 1, 1, 1, 0)
  local node1 = ModelFixture.transformedNodeData(0, 20, 0, 1, 1, 1, 1)
  local nodeData = node0 .. node1
  local nodeDict0 = NB.dict({
    { name = "a", data = u32(0) },
    { name = "b", data = u32(#node0) },
  })
  local nodeDict = NB.dict({
    { name = "a", data = u32(#nodeDict0) },
    { name = "b", data = u32(#nodeDict0 + #node0) },
  })
  local sbc = string.char(0x06, 0, 0, 0)
    .. string.char(0x06, 1, 1, 0)
    .. string.char(0x03, 0)
    .. string.char(0x05, 0)
    .. string.char(0x03, 1)
    .. string.char(0x05, 0)
    .. string.char(0x04, 0)
    .. string.char(0x01)
  local m = ModelFixture.decodeModel(nodeDict, nodeData, sbc, { numNode = 2 })
  assertBindPoseEquivalence(m)
end

-- NODEMIX: storeSlot 2, two terms of ratio 128 (half each) over slots 0 and 1.
local EVEN_BLEND = string.char(0x09, 2, 2, 0, 0, 128, 1, 1, 128) .. string.char(0x05, 0) .. string.char(0x01)

function T.nodemix_model()
  local m = ModelFixture.nodemixModel(EVEN_BLEND, ModelFixture.evpEntry(0, 0, 0) .. ModelFixture.evpEntry(0, 0, 0))
  assertBindPoseEquivalence(m)
end

-- A display list that restores a matrix mid-list: the shape decodes into two
-- segments; the second resolves from the draw's restore stack. The static
-- compile bakes the restore through GxDisplayList's SBC-supplied slots, so
-- the bind-pose invariant must hold across the boundary.
function T.display_list_matrix_restore_segments()
  -- The default NsbmdFixture SBC stream draws the shape twice (two SHP
  -- commands over one node), so the two segment meshes appear in both draws.
  local m = assert(Nsbmd.decode(NsbmdFixture.build())).models[1]
  -- Overwrite the shape's display list with: triangle (0,0,0)(1,0,0)(0,1,0),
  -- MTX_RESTORE slot 3, then the same triangle again.
  local function vtx16(x, y, z)
    local function raw(c)
      return math.floor(c * 4096) % 0x10000
    end
    return NB.u32(raw(x) + raw(y) * 0x10000) .. NB.u32(raw(z))
  end
  local triangleList = string.char(0x40, 0x23, 0x23, 0x23)
    .. NB.u32(0)
    .. vtx16(0, 0, 0)
    .. vtx16(1, 0, 0)
    .. vtx16(0, 1, 0)
    .. string.char(0x41, 0, 0, 0)
  local restore = string.char(0x14, 0, 0, 0) .. NB.u32(3) -- MTX_RESTORE slot 3
  local newDl = triangleList .. restore .. triangleList
  m.shapes[1].displayListBytes = newDl

  local staticBatches = MeshCompiler.compile(m)
  -- Both static batches (two SBC draws of one shape) now carry 6 vertices.
  Assert.equal(staticBatches[1].vertexCount, 6)

  local descriptor = NsbmdDynamicModel.compile(m)
  local draws = NsbmdSbcEvaluator.evaluate(descriptor.program --[[@as NsbmdSbcEvaluator.Program]], bindPose(m)).draws
  -- Two SBC draws, each split into two segments by the restore boundary: the
  -- first segment sources the draw matrix, the second restores slot 3.
  Assert.equal(#descriptor.meshes, 4)
  Assert.equal(descriptor.meshes[1].positionSource, "draw")
  Assert.equal(descriptor.meshes[2].positionSource.slot, 3)
  Assert.equal(descriptor.meshes[2].drawIndex, 0)
  Assert.equal(descriptor.meshes[3].drawIndex, 1)
  Assert.equal(descriptor.meshes[4].positionSource.slot, 3)
  Assert.equal(descriptor.meshes[1].batch.vertexCount, 3)
  Assert.equal(descriptor.meshes[2].batch.vertexCount, 3)

  -- Draw 0's restoreStack at bind pose has no slot 3 entry (NODEDESC stores
  -- into slot 0 only), so the second segment resolves to identity.
  local draw = draws[1]
  local slot = draw.restoreStack[3] or Matrix4.identity()
  local v = vertex(descriptor.meshes[2].batch, 1)
  local x = slot[1] * v.x + slot[5] * v.y + slot[9] * v.z + slot[13] / 16
  local y = slot[2] * v.x + slot[6] * v.y + slot[10] * v.z + slot[14] / 16
  Assert.isTrue(math.abs(x - 1 / 16) < TOL, "restored slot places the vertex")
  Assert.isTrue(math.abs(y) < TOL, "restored slot places the vertex")
end

-- A display list whose run straddles a mid-run matrix restore: the DS
-- transforms each vertex at submission under the then-current matrix, so the
-- straddling quad's leading vertices resolve under the PRE-restore source
-- ("draw") and its trailing vertices under the restored slot. The dynamic
-- mesh record must carry that per-vertex provenance (straddle), and
-- resolving it per-vertex at the bind pose must reproduce the static compile
-- (which bakes each vertex under the matrix current at its submission). The
-- transformed node makes the two sources differ, so a one-source resolution
-- cannot match the static bake.
function T.straddling_quad_carries_per_vertex_sources_and_matches_the_static_bake()
  local m = assert(Nsbmd.decode(NsbmdFixture.buildTransformed())).models[1]
  -- Overwrite the shape's display list with a straddling quad: BEGIN(quads),
  -- two vertices, MTX_RESTORE slot 3, two more vertices, END. The draw
  -- matrix (node (2,0,0), scale 2) differs from the empty slot 3 (identity),
  -- so the leading and trailing halves resolve differently.
  local vtx16xy = NB.vtx16xy
  local pack = NB.gxPack
  local straddlingQuad = pack({
    { { 0x40, 0x23, 0x23 }, { 1, vtx16xy(0, 0), 0, vtx16xy(1, 0), 0 } }, -- BEGIN(quads), 2 verts
    { { 0x14 }, { 3 } }, -- MTX_RESTORE slot 3
    { { 0x23, 0x23, 0x41 }, { vtx16xy(1, 1), 0, vtx16xy(0, 1), 0 } }, -- 2 verts, END
  })
  m.shapes[1].displayListBytes = straddlingQuad

  local staticBatches = MeshCompiler.compile(m)
  local descriptor = NsbmdDynamicModel.compile(m)
  local draws = NsbmdSbcEvaluator.evaluate(descriptor.program --[[@as NsbmdSbcEvaluator.Program]], bindPose(m)).draws
  -- One SBC draw, one straddle mesh (the leading-only segment is dropped: no
  -- indices to draw).
  Assert.equal(#descriptor.meshes, 1)
  ---@type { positionSource: table|string, drawIndex: integer, straddle?: { leading: integer, source: table|string }, batch: G4GxGeometrySlice }
  local mesh = descriptor.meshes[1]
  Assert.equal(mesh.positionSource.slot, 3)
  -- The per-vertex provenance: the first two vertices resolve under the
  -- pre-restore "draw" source, the trailing two under the slot.
  Assert.deepEqual(mesh.straddle, { leading = 2, source = "draw" })
  Assert.equal(mesh.batch.vertexCount, 4)

  -- Bind-pose oracle: resolve each vertex under the source active at its
  -- submission (leading under "draw", trailing under slot 3) and compare
  -- against the static compile, which baked the same per-vertex transforms.
  local staticBatch = staticBatches[mesh.drawIndex + 1]
  Assert.equal(staticBatch.vertexCount, 4)
  local function toTilesForStraddle(mat)
    local out = {}
    for i = 1, 12 do
      out[i] = mat[i]
    end
    out[13], out[14], out[15] = mat[13] / 16, mat[14] / 16, mat[15] / 16
    out[16] = mat[16]
    return out
  end
  local function resolveSource(src, draw)
    if src == "draw" then
      return toTilesForStraddle(draw.matrix)
    end
    return toTilesForStraddle(draw.restoreStack[src.slot] or Matrix4.identity())
  end
  local draw = draws[mesh.drawIndex + 1]
  for i, v in ipairs(vertices(mesh.batch)) do
    local src = i <= mesh.straddle.leading and mesh.straddle.source or mesh.positionSource
    local position = resolveSource(src, draw)
    local x = position[1] * v.x + position[5] * v.y + position[9] * v.z + position[13]
    local y = position[2] * v.x + position[6] * v.y + position[10] * v.z + position[14]
    local z = position[3] * v.x + position[7] * v.y + position[11] * v.z + position[15]
    local s = vertex(staticBatch, i - 1)
    if math.abs(x - s.x) > TOL or math.abs(y - s.y) > TOL or math.abs(z - s.z) > TOL then
      error(
        string.format(
          "straddle vertex %d: static (%.6f, %.6f, %.6f) vs resolved (%.6f, %.6f, %.6f)",
          i - 1,
          s.x,
          s.y,
          s.z,
          x,
          y,
          z
        )
      )
    end
  end
end

-- ---- ModelDefinition assembly ----

-- Convert the digest intermediate records (raw batches + polygonAttrRaw) into
-- the serialized descriptor shape MapAssetCompiler.dynamicBatches writes:
-- .g4mesh geometry paths and the decoded per-segment polygon draw state --
-- the polygon light mask included, exactly like the static path's batch
-- records (the strict descriptor boundary requires it).
local function serializeBatches(meshes)
  local out = {}
  for _, mesh in ipairs(meshes) do
    local poly = DsPolygonAttr.decode(mesh.polygonAttrRaw)
    out[#out + 1] = {
      id = mesh.id,
      drawIndex = mesh.drawIndex,
      segmentIndex = mesh.segmentIndex,
      nodeIndex = mesh.nodeIndex,
      materialIndex = mesh.materialIndex,
      transformMode = mesh.transformMode,
      positionSource = mesh.positionSource,
      geometry = "fixtures/" .. mesh.id .. ".g4mesh",
      cullMode = poly.cullMode,
      polygonMode = poly.polygonMode,
      polygonId = poly.polygonId,
      translucentDepthWrite = poly.translucentDepthWrite,
      depthEqual = poly.depthEqual,
      polygonAlpha = poly.polygonAlpha,
      lightMask = poly.lightMask,
    }
  end
  return out
end

function T.to_definition_builds_a_valid_nitro_model()
  local m = assert(Nsbmd.decode(NsbmdFixture.buildTransformed())).models[1]
  local descriptor = NsbmdDynamicModel.compile(m)
  local def = ModelDefinition.fromNitroDescriptor({
    key = "fixture:door",
    dynamic = {
      nodes = descriptor.program.nodes,
      transformProgram = descriptor.program,
      batches = serializeBatches(descriptor.meshes),
    },
    materials = descriptor.materials,
    animations = {
      {
        id = "fixture:anim",
        name = "anim",
        category = "joint",
        kind = "trs",
        frameCount = 2,
        tracks = { { target = 0, targetIndex = 0 } },
        semanticNames = {},
        source = { type = "nitro", format = "NSBCA", archive = "build_anim", memberId = 1 },
        compiled = {},
      },
    },
  }, { key = "fixture:door" })
  Assert.equal(def.key, "fixture:door")
  Assert.equal(#def.nodes, 1)
  Assert.equal(def.nodes[1].translation.x, 2)
  Assert.equal(#def.meshes, 1)
  Assert.equal(def.meshes[1].geometry, "fixtures/draw0.seg0.g4mesh")
  Assert.equal(def.materials[1].alphaMode, "opaque")
  Assert.equal(def.backend.program, descriptor.program)
  Assert.equal(def.backend.meshes[def.meshes[1].id].drawIndex, 0)
  Assert.equal(def.backend.meshes[def.meshes[1].id].positionSource, "draw")
  Assert.equal(def.backend.meshes[def.meshes[1].id].cullMode, "none")
  Assert.equal(def.backend.meshes[def.meshes[1].id].polygonMode, "modulation")
  -- The definition is a valid engine IR object (validation ran in new).
  Assert.equal(def:animation("door.open"), nil)
end

-- The compiler-to-runtime contract: a compiled dynamic descriptor with
-- deliberately distinctive values -- a polygon light mask of 0b0101 and
-- four distinct DS base-material colors -- preserves both exactly through
-- ModelDefinition.fromNitroDescriptor -> ModelInstance:drawItems, and the
-- renderer's per-draw mask decode matches the shader's per-light gating.
-- The fixture NSBMD material carries distinct RGB555 values per register
-- (diffuse 31,0,0 / ambient 0,31,0 / specular 0,0,31 / emission 15,15,15) and
-- a polygon-attr word whose light-mask field is 0b0101.
function T.compiled_descriptor_preserves_light_mask_and_four_material_colors()
  local m = assert(Nsbmd.decode(NsbmdFixture.buildStaticQuad({ polyAttr = 0x001F00C5 }))).models[1]
  local descriptor = NsbmdDynamicModel.compile(m)

  -- The compiler emits each DS material register per channel, 5-bit -> 8-bit.
  Assert.deepEqual(descriptor.materials[1].colors, {
    diffuse = { r = 255, g = 0, b = 0 },
    ambient = { r = 0, g = 255, b = 0 },
    specular = { r = 0, g = 0, b = 255 },
    emission = { r = 123, g = 123, b = 123 },
  })

  local def = ModelDefinition.fromNitroDescriptor({
    key = "fixture:contract",
    dynamic = {
      nodes = descriptor.program.nodes,
      transformProgram = descriptor.program,
      batches = serializeBatches(descriptor.meshes),
    },
    materials = descriptor.materials,
    animations = {
      {
        id = "fixture:anim",
        name = "anim",
        category = "joint",
        kind = "trs",
        frameCount = 2,
        tracks = { { target = 0, targetIndex = 0 } },
        semanticNames = {},
        source = { type = "nitro", format = "NSBCA", archive = "build_anim", memberId = 1 },
        compiled = {},
      },
    },
  }, { key = "fixture:contract" })
  -- The loader stamps each mesh's model-space center after assembly; the
  -- draw path requires it.
  for _, mesh in ipairs(def.meshes) do
    mesh.center = { 1, 0, 1 }
  end
  local items = ModelInstance.new(def):drawItems({ ["draw0.seg0"] = "stub" })
  local item = items[1]
  Assert.equal(item.lightMask, 5, "the polygon light mask survives to the draw item")
  Assert.deepEqual(item.material.matDiffuse, { 1, 0, 0 }, "diffuse survives to the draw item")
  Assert.deepEqual(item.material.matAmbient, { 0, 1, 0 }, "ambient survives to the draw item")
  Assert.deepEqual(item.material.matSpecular, { 0, 0, 1 }, "specular survives to the draw item")
  Assert.near(item.material.matEmission[1], 123 / 255, 1e-9, "emission survives to the draw item")
  Assert.near(item.material.matEmission[2], 123 / 255, 1e-9)
  Assert.near(item.material.matEmission[3], 123 / 255, 1e-9)

  -- The renderer decodes mask 0b0101 into the per-light 0/1 uniform the
  -- shader gates each light with; the assertion pins the exact decode.
  Assert.deepEqual(GxRenderer.lightMaskUniforms(5), { 1, 0, 1, 0 })
end

-- ---- static/dynamic render-state parity ----

-- Every model the dynamic path compiles carries the same polygon draw state
-- per draw as the static path: the polygon-attr word comes from the same
-- resolved material state, and both decode to identical cull/mode/id/depth/
-- alpha fields. A static and an animated placement of one NSBMD therefore
-- render with the same polygon state.
function T.polygon_draw_state_matches_the_static_path()
  local fixtures = {
    NsbmdFixture.buildTransformed(),
    NsbmdFixture.buildStaticQuad(),
    NsbmdFixture.buildBillboardQuad(),
  }
  for _, bytes in ipairs(fixtures) do
    local model = assert(Nsbmd.decode(bytes)).models[1]
    local staticBatches = MeshCompiler.compile(model)
    local descriptor = NsbmdDynamicModel.compile(model)
    Assert.equal(#descriptor.meshes, #staticBatches, model.name .. ": one dynamic mesh per static batch")
    for meshIndex, mesh in ipairs(descriptor.meshes) do
      local batch = staticBatches[meshIndex]
      local label = string.format("%s mesh %s", model.name, mesh.id)
      Assert.equal(mesh.polygonAttrRaw, batch.polygonAttrRaw, label .. " polygon-attr word")
      local dynamicState = DsPolygonAttr.decode(mesh.polygonAttrRaw)
      local staticState = DsPolygonAttr.decode(batch.polygonAttrRaw)
      for _, field in ipairs({
        "cullMode",
        "polygonMode",
        "polygonId",
        "translucentDepthWrite",
        "depthEqual",
        "polygonAlpha",
        "lightMask",
      }) do
        Assert.equal(dynamicState[field], staticState[field], label .. " " .. field)
      end
    end
  end
end

return { tests = T }
