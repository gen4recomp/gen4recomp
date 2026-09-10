-- Terrain boundary conformance: cross-batch topology repair for separately
-- rendered terrain batches.
--
-- Outdoor terrain is drawn as one batch per material. When a coarse batch
-- carries boundary edge A-B while the same batch or a touching batch breaks
-- the same span at interior vertices P1..Pn, host point-sampling can disagree along the two
-- differently segmented but collinear edges and leave an isolated sample
-- owned by neither batch. The producer repair splits the coarse boundary
-- topology so both sides express the same breakpoints, without merging
-- materials, batches, or render state. These tests pin that contract against
-- the pure producer module using hand-built compiled-batch fixtures in tile
-- units on the y=1 plane; no ROM data is involved.

local Assert = require("tests.support.Assert")
local ffi = require("ffi")
local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local GeometryBuffer = require("libs.nds.src.gx.GxGeometryBuffer")

local CONFORMER_MODULE = "romdump.src.digest.map.TerrainBoundaryConformer"

local T = {}

-- The producer module under test. Every case requires it lazily so the suite
-- loads even before the repair exists and each failure names the missing
-- behavior rather than a load error.
local function conformer()
  local ok, mod = pcall(require, CONFORMER_MODULE)
  Assert.isTrue(
    ok and type(mod) == "table",
    "terrain boundary repair is missing: a coarse boundary edge is not split at touching-batch breakpoints"
  )
  Assert.equal(type(mod.conform), "function", "terrain boundary repair must expose conform(batches, context)")
  Assert.equal(
    type(mod.findTJunctions),
    "function",
    "terrain boundary repair must expose a findTJunctions(batches) inspection helper"
  )
  return mod --[[@as table]]
end

local function context()
  return {
    role = "map",
    mapSymbol = "MAP_FIXTURE",
    modelArchive = "land_data",
    modelMemberId = 0,
    modelName = "fixture",
  }
end

-- Conform, tolerating an in-place repair: the contract is the returned batch
-- list, whether it is a fresh list or the input mutated in place.
local function conform(batches)
  local out = conformer().conform(batches, context())
  return out or batches
end

local function junctions(batches)
  return conformer().findTJunctions(batches) or {}
end

local function V(x, y, z, o)
  o = o or {}
  return {
    x = x,
    y = y,
    z = z,
    u = o.u or 0,
    v = o.v or 0,
    nx = o.nx or 0,
    ny = o.ny or 1,
    nz = o.nz or 0,
    r = o.r or 255,
    g = o.g or 255,
    b = o.b or 255,
    a = o.a or 255,
    colorSource = o.colorSource or 0,
  }
end

local function B(vertices, indices, materialIndex)
  return {
    nodeIndex = 0,
    materialIndex = materialIndex or 0,
    shapeIndex = 0,
    polygonAttrRaw = 0x001F00C1,
    transformMode = "static",
    vertices = vertices,
    indices = indices,
  }
end

-- How many vertices sit exactly at (x, y, z).
local function countAt(batches, x, y, z)
  local n = 0
  for _, batch in ipairs(batches) do
    for offset = 0, batch.vertexCount - 1 do
      local v = batch.arena.numeric[batch.vertexOffset + offset]
      if v.x == x and v.y == y and v.z == z then
        n = n + 1
      end
    end
  end
  return n
end

local function vertexAt(batch, x, y, z)
  for offset = 0, batch.vertexCount - 1 do
    local v = batch.arena.numeric[batch.vertexOffset + offset]
    if v.x == x and v.y == y and v.z == z then
      local bytes = batch.arena.attrib[batch.vertexOffset + offset]
      return {
        x = v.x,
        y = v.y,
        z = v.z,
        u = v.u,
        v = v.v,
        nx = v.nx,
        ny = v.ny,
        nz = v.nz,
        r = bytes.r,
        g = bytes.g,
        b = bytes.b,
        a = bytes.a,
        colorSource = bytes.colorSource,
      }
    end
  end
  return nil
end

-- Signed triangle area in the y=1 plane (the x/z projection), for winding and
-- degeneracy checks on output triangles.
local function signedArea(a, b, c)
  return 0.5 * ((b.x - a.x) * (c.z - a.z) - (c.x - a.x) * (b.z - a.z))
end

local function triangleAreas(batch)
  local areas = {}
  for offset = 0, batch.indexCount - 1, 3 do
    local indices = batch.arena.indices
    local a = batch.arena.numeric[batch.vertexOffset + indices[batch.indexOffset + offset]]
    local b = batch.arena.numeric[batch.vertexOffset + indices[batch.indexOffset + offset + 1]]
    local c = batch.arena.numeric[batch.vertexOffset + indices[batch.indexOffset + offset + 2]]
    areas[#areas + 1] = signedArea(a, b, c)
  end
  return areas
end

local function geometryArena()
  return GeometryBuffer.new()
end

local function denseBatches(source)
  local arena = geometryArena()
  local batches = {}
  for batchIndex, sourceBatch in ipairs(source) do
    arena:reserve(#sourceBatch.vertices, #sourceBatch.indices)
    local vertexOffset = arena.vertexCount
    local indexOffset = arena.indexCount
    local numeric = arena.numeric
    local attrib = arena.attrib
    local indices = arena.indices
    for vertexIndex, vertex in ipairs(sourceBatch.vertices) do
      local numericVertex = numeric[vertexOffset + vertexIndex - 1]
      numericVertex.x = vertex.x
      numericVertex.y = vertex.y
      numericVertex.z = vertex.z
      numericVertex.u = vertex.u
      numericVertex.v = vertex.v
      numericVertex.nx = vertex.nx
      numericVertex.ny = vertex.ny
      numericVertex.nz = vertex.nz
      local attributeVertex = attrib[vertexOffset + vertexIndex - 1]
      attributeVertex.r = vertex.r
      attributeVertex.g = vertex.g
      attributeVertex.b = vertex.b
      attributeVertex.a = vertex.a
      attributeVertex.colorSource = vertex.colorSource
    end
    for index, value in ipairs(sourceBatch.indices) do
      indices[indexOffset + index - 1] = value
    end
    arena.vertexCount = vertexOffset + #sourceBatch.vertices
    arena.indexCount = indexOffset + #sourceBatch.indices
    batches[batchIndex] = {
      arena = arena,
      vertexOffset = vertexOffset,
      vertexCount = #sourceBatch.vertices,
      indexOffset = indexOffset,
      indexCount = #sourceBatch.indices,
      nodeIndex = sourceBatch.nodeIndex,
      materialIndex = sourceBatch.materialIndex,
      shapeIndex = sourceBatch.shapeIndex,
      polygonAttrRaw = sourceBatch.polygonAttrRaw,
      transformMode = sourceBatch.transformMode,
    }
  end
  return batches
end

local function cloneBatches(batches)
  local arena = geometryArena()
  local clones = {}
  for batchIndex, source in ipairs(batches) do
    arena:reserve(source.vertexCount, source.indexCount)
    local vertexOffset, indexOffset = arena.vertexCount, arena.indexCount
    ffi.copy(
      arena.numeric[vertexOffset],
      source.arena.numeric[source.vertexOffset],
      source.vertexCount * GeometryBuffer.vertexNumericSize
    )
    ffi.copy(
      arena.attrib[vertexOffset],
      source.arena.attrib[source.vertexOffset],
      source.vertexCount * GeometryBuffer.vertexAttribSize
    )
    for offset = 0, source.indexCount - 1 do
      arena.indices[indexOffset + offset] = source.arena.indices[source.indexOffset + offset]
    end
    arena.vertexCount, arena.indexCount = vertexOffset + source.vertexCount, indexOffset + source.indexCount
    clones[batchIndex] = {
      arena = arena,
      vertexOffset = vertexOffset,
      vertexCount = source.vertexCount,
      indexOffset = indexOffset,
      indexCount = source.indexCount,
      nodeIndex = source.nodeIndex,
      materialIndex = source.materialIndex,
      shapeIndex = source.shapeIndex,
      polygonAttrRaw = source.polygonAttrRaw,
      transformMode = source.transformMode,
    }
  end
  return clones
end

function T.uses_the_locked_topology_layouts()
  Assert.equal(ffi.sizeof("G4PositionSlot"), 32, "position hash slots stay fixed-width")
  Assert.equal(ffi.sizeof("G4EdgeSlot"), 32, "edge hash slots stay fixed-width")
  Assert.equal(ffi.sizeof("G4TriangleSlot"), 16, "triangle hash slots stay fixed-width")
  Assert.equal(ffi.sizeof("G4SplitEvent"), 32, "split events stay fixed-width")
end

function T.normalizes_signed_zero_position_identity()
  local coarse = B({ V(-4, 1, 0), V(0, 1, 0), V(0, 1, 4), V(-4, 1, 4) }, { 0, 1, 2, 0, 2, 3 })
  local fine = B(
    { V(4, 1, 0), V(0, 1, 0), V(4, 1, 2), V(0, 1, 2), V(4, 1, 4), V(0, 1, 4) },
    { 1, 0, 2, 1, 2, 3, 3, 2, 4, 3, 4, 5 }
  )
  local batches = denseBatches({ coarse, fine })
  local point = batches[2].arena.numeric[batches[2].vertexOffset + 3]
  point.x = -0.0
  local repaired = conform(cloneBatches(batches))
  Assert.equal(#junctions(repaired), 0, "signed-zero coordinates share one position identity")
end

function T.rejects_non_finite_position_identity_values()
  local batches = denseBatches({
    B({ V(0, 1, 0), V(0, 1, 4), V(-4, 1, 0) }, { 0, 1, 2 }),
  })
  batches[1].arena.numeric[batches[1].vertexOffset].x = 0 / 0
  Assert.throws(function()
    junctions(batches)
  end)
end

local function denseSnapshot(batches)
  local snapshot = {}
  for batchIndex, batch in ipairs(batches) do
    local numeric = batch.arena.numeric
    local attrib = batch.arena.attrib
    local indices = batch.arena.indices
    local record = {
      metadata = {
        nodeIndex = batch.nodeIndex,
        materialIndex = batch.materialIndex,
        shapeIndex = batch.shapeIndex,
        polygonAttrRaw = batch.polygonAttrRaw,
        transformMode = batch.transformMode,
      },
      vertices = {},
      indices = {},
    }
    for offset = 0, batch.vertexCount - 1 do
      local vertex = numeric[batch.vertexOffset + offset]
      local bytes = attrib[batch.vertexOffset + offset]
      record.vertices[#record.vertices + 1] = {
        vertex.x,
        vertex.y,
        vertex.z,
        vertex.u,
        vertex.v,
        vertex.nx,
        vertex.ny,
        vertex.nz,
        bytes.r,
        bytes.g,
        bytes.b,
        bytes.a,
        bytes.colorSource,
      }
    end
    for offset = 0, batch.indexCount - 1 do
      record.indices[#record.indices + 1] = indices[batch.indexOffset + offset]
    end
    snapshot[batchIndex] = record
  end
  return snapshot
end

-- A coarse quad x in [-4,0], z in [0,4] with one unbroken boundary edge along
-- x=0, plus a fine neighbor x in [0,4] breaking that span at P=(0,1,2).
local function singleSeam(materialIndex)
  local coarse = B({
    V(-4, 1, 0),
    V(0, 1, 0),
    V(0, 1, 4),
    V(-4, 1, 4),
  }, { 0, 1, 2, 0, 2, 3 }, materialIndex)
  local fine = B({
    V(4, 1, 0),
    V(0, 1, 0),
    V(4, 1, 2),
    V(0, 1, 2),
    V(4, 1, 4),
    V(0, 1, 4),
  }, { 1, 0, 2, 1, 2, 3, 3, 2, 4, 3, 4, 5 }, materialIndex)
  return denseBatches({ coarse, fine })
end

function T.splits_a_single_t_junction_and_reports_no_remaining_junctions()
  local before = singleSeam()
  Assert.isTrue(#junctions(before) >= 1, "the deliberate T-seam must be diagnosed before repair")

  local after = conform(cloneBatches(before))
  Assert.equal(#junctions(after), 0, "no unmatched boundary T-junction may remain after repair")
  Assert.equal(countAt({ after[1] }, 0, 1, 2), 1, "the coarse side expresses the shared breakpoint exactly once")
  Assert.equal(after[1].indexCount, 9, "the one split triangle becomes two; its neighbor is untouched")
  Assert.equal(after[2].indexCount, 12, "the fine side keeps its four triangles")
end

-- One coarse span z in [0,6] met by breakpoints at z=2 and z=4.
local function multiSplit()
  local coarse = B({
    V(-4, 1, 0),
    V(0, 1, 0),
    V(0, 1, 6),
    V(-4, 1, 6),
  }, { 0, 1, 2, 0, 2, 3 })
  local fine = B({
    V(4, 1, 0),
    V(0, 1, 0),
    V(4, 1, 2),
    V(0, 1, 2),
    V(4, 1, 4),
    V(0, 1, 4),
    V(4, 1, 6),
    V(0, 1, 6),
  }, { 1, 0, 2, 1, 2, 3, 3, 2, 4, 3, 4, 5, 5, 4, 6, 5, 6, 7 })
  return denseBatches({ coarse, fine })
end

function T.inserts_multiple_split_points_deterministically()
  local first = conform(cloneBatches(multiSplit()))
  Assert.equal(#junctions(first), 0, "no unmatched boundary T-junction may remain after repair")
  Assert.equal(countAt({ first[1] }, 0, 1, 2), 1, "the first breakpoint is expressed on the coarse side")
  Assert.equal(countAt({ first[1] }, 0, 1, 4), 1, "the second breakpoint is expressed on the coarse side")

  local second = conform(cloneBatches(multiSplit()))
  Assert.deepEqual(denseSnapshot(second), denseSnapshot(first), "the same input conforms byte-identically across runs")
end

-- Side A breaks the shared span at z=2, side B at z=1: both must finish with
-- the union {0,1,2,4}.
local function unionSeam()
  local a = B({
    V(-4, 1, 0),
    V(0, 1, 0),
    V(-4, 1, 2),
    V(0, 1, 2),
    V(-4, 1, 4),
    V(0, 1, 4),
  }, { 0, 1, 3, 0, 3, 2, 2, 3, 5, 2, 5, 4 })
  local b = B({
    V(0, 1, 0),
    V(4, 1, 0),
    V(0, 1, 1),
    V(4, 1, 1),
    V(0, 1, 4),
    V(4, 1, 4),
  }, { 0, 1, 3, 0, 3, 2, 2, 3, 5, 2, 5, 4 })
  return denseBatches({ a, b })
end

function T.conforms_both_sides_to_the_union_of_breakpoints()
  local after = conform(cloneBatches(unionSeam()))
  Assert.equal(#junctions(after), 0, "no unmatched boundary T-junction may remain after repair")
  Assert.equal(countAt({ after[1] }, 0, 1, 1), 1, "side A adopts side B's breakpoint")
  Assert.equal(countAt({ after[2] }, 0, 1, 2), 1, "side B adopts side A's breakpoint")
end

-- Both sides already break the span at z=2: identical segmentation.
local function conformingSeam()
  local a = B({
    V(-4, 1, 0),
    V(0, 1, 0),
    V(-4, 1, 2),
    V(0, 1, 2),
    V(-4, 1, 4),
    V(0, 1, 4),
  }, { 0, 1, 3, 0, 3, 2, 2, 3, 5, 2, 5, 4 })
  local b = B({
    V(0, 1, 0),
    V(4, 1, 0),
    V(0, 1, 2),
    V(4, 1, 2),
    V(0, 1, 4),
    V(4, 1, 4),
  }, { 0, 1, 3, 0, 3, 2, 2, 3, 5, 2, 5, 4 })
  return denseBatches({ a, b })
end

function T.leaves_already_conforming_boundaries_unchanged()
  local input = conformingSeam()
  Assert.equal(#junctions(input), 0, "matching segmentation starts clean")
  local after = conform(cloneBatches(input))
  Assert.equal(after[1].vertexCount, 6, "no vertex churn on side A")
  Assert.equal(after[1].indexCount, 12, "no index churn on side A")
  Assert.equal(after[2].vertexCount, 6, "no vertex churn on side B")
  Assert.equal(after[2].indexCount, 12, "no index churn on side B")
  Assert.deepEqual(denseSnapshot(after), denseSnapshot(input), "conforming input round-trips exactly")
end

-- A vertex collinear with the seam but interior to its own batch (a triangle
-- fan center) must not trigger a split: only boundary vertices of other
-- batches are candidates.
local function interiorVertexFixture()
  local coarse = B({
    V(-4, 1, 0),
    V(0, 1, 0),
    V(0, 1, 4),
    V(-4, 1, 4),
  }, { 0, 1, 2, 0, 2, 3 })
  local center = V(0, 1, 2)
  local r1, r2, r3, r4 = V(-2, 1, -2), V(4, 1, -2), V(4, 1, 6), V(-2, 1, 6)
  local fan = B({ center, r1, r2, r3, r4 }, { 0, 1, 2, 0, 2, 3, 0, 3, 4, 0, 4, 1 })
  return denseBatches({ coarse, fan })
end

function T.ignores_interior_vertices_of_other_batches()
  local after = conform(cloneBatches(interiorVertexFixture()))
  Assert.equal(after[1].vertexCount, 4, "an interior vertex of another batch splits nothing")
  Assert.equal(after[1].indexCount, 6, "an interior vertex of another batch splits nothing")
  Assert.equal(#junctions(after), 0, "interior vertices are not boundary T-junctions")
end

-- A boundary vertex 1e-3 tiles off the edge exceeds any sane producer
-- collinearity tolerance (orders around 1e-9 tile units) by orders of
-- magnitude, so it must be rejected, never snapped.
local function nearMissFixture()
  local coarse = B({
    V(-4, 1, 0),
    V(0, 1, 0),
    V(0, 1, 4),
    V(-4, 1, 4),
  }, { 0, 1, 2, 0, 2, 3 })
  local fine = B({
    V(4, 1, 0),
    V(0.001, 1, 0),
    V(4, 1, 2),
    V(0.001, 1, 2),
    V(4, 1, 4),
    V(0.001, 1, 4),
  }, { 1, 0, 2, 1, 2, 3, 3, 2, 4, 3, 4, 5 })
  return denseBatches({ coarse, fine })
end

function T.rejects_near_miss_points_beyond_tolerance()
  local after = conform(cloneBatches(nearMissFixture()))
  Assert.equal(after[1].vertexCount, 4, "a near-miss point must not split the edge")
  Assert.equal(after[1].indexCount, 6, "a near-miss point must not split the edge")
  Assert.equal(countAt(after, 0.001, 1, 2), 1, "the off-edge vertex stays on its own side only")
  Assert.equal(#junctions(after), 0, "a rejected near-miss is not a remaining T-junction")
end

function T.does_not_duplicate_existing_endpoints()
  local a = B({
    V(-4, 1, 0),
    V(0, 1, 0),
    V(0, 1, 4),
    V(-4, 1, 4),
  }, { 0, 1, 2, 0, 2, 3 })
  -- The neighbor shares the span endpoints exactly and adds no interior break.
  local b = B({
    V(0, 1, 0),
    V(4, 1, 0),
    V(4, 1, 4),
    V(0, 1, 4),
  }, { 0, 1, 2, 0, 2, 3 })
  local after = conform(denseBatches({ a, b }))
  Assert.equal(after[1].vertexCount, 4, "shared endpoints create no zero-length segment")
  Assert.equal(after[1].indexCount, 6, "shared endpoints create no zero-length segment")
  for _, batch in ipairs(after) do
    for _, area in ipairs(triangleAreas(batch)) do
      Assert.isTrue(area > 1e-12, "no degenerate triangle may appear")
    end
  end
  Assert.equal(#junctions(after), 0, "shared endpoints are already conforming")
end

-- One triangle carrying a split point on two of its boundary edges.
local function twoEdgeSplit()
  local single = B({ V(0, 1, 0), V(0, 1, 4), V(4, 1, 2) }, { 0, 1, 2 })
  local other = B({ V(0, 1, 1), V(2, 1, 3), V(0, 1, 4) }, { 0, 1, 2 })
  return denseBatches({ single, other })
end

function T.retriangulates_a_triangle_split_on_two_edges()
  local input = twoEdgeSplit()
  local originalArea = triangleAreas(input[1])[1]
  local after = conform(cloneBatches(input))
  Assert.equal(#junctions(after), 0, "no unmatched boundary T-junction may remain after repair")
  Assert.equal(after[1].indexCount, 9, "one triangle split on two edges becomes three")
  local areas = triangleAreas(after[1])
  local total = 0
  for _, area in ipairs(areas) do
    Assert.isTrue(math.abs(area) > 1e-12, "retriangulation emits no zero-area triangle")
    Assert.isTrue(area * originalArea > 0, "retriangulation preserves the original winding")
    total = total + area
  end
  Assert.isTrue(math.abs(total - originalArea) < 1e-9, "retriangulation covers exactly the original area")
  Assert.equal(after[2].indexCount, 3, "the fine triangle needs no repair of its own")
end

-- Attribute interpolation at t=0.25 along B->C: position is copied exactly
-- from the shared breakpoint; uv/normal/color interpolate in the coarse
-- batch's stored domains; the categorical colorSource is preserved.
local function attributeFixture(colorSourceA, colorSourceB)
  local coarse = B({
    V(-4, 1, 0),
    V(0, 1, 0, { u = 0, v = 8, nx = 10, r = 10, g = 20, b = 30, a = 40, colorSource = colorSourceA }),
    V(0, 1, 4, { u = 8, v = 0, nx = 30, r = 50, g = 60, b = 70, a = 200, colorSource = colorSourceB }),
    V(-4, 1, 4),
  }, { 0, 1, 2, 0, 2, 3 })
  local fine = B({
    V(4, 1, 0),
    V(0, 1, 0),
    V(4, 1, 1),
    V(0, 1, 1),
    V(4, 1, 4),
    V(0, 1, 4),
  }, { 1, 0, 2, 1, 2, 3, 3, 2, 4, 3, 4, 5 })
  return denseBatches({ coarse, fine })
end

function T.interpolates_inserted_vertex_attributes_in_the_coarse_domain()
  local after = conform(attributeFixture(2, 2))
  local inserted = vertexAt(after[1], 0, 1, 1)
  Assert.notNil(inserted, "the coarse side gains the shared breakpoint")
  ---@cast inserted table
  Assert.equal(inserted.u, 2, "u interpolates from the coarse edge endpoints")
  Assert.equal(inserted.v, 6, "v interpolates from the coarse edge endpoints")
  Assert.equal(inserted.nx, 15, "normals interpolate in the stored raw domain")
  Assert.equal(inserted.r, 20, "byte color interpolates deterministically")
  Assert.equal(inserted.g, 30, "byte color interpolates deterministically")
  Assert.equal(inserted.b, 40, "byte color interpolates deterministically")
  Assert.equal(inserted.a, 80, "byte alpha interpolates deterministically")
  Assert.equal(inserted.colorSource, 2, "the categorical color source is preserved, never averaged")
end

function T.fails_loudly_on_categorical_color_source_conflict()
  local err = Assert.throws(function()
    conform(attributeFixture(0, 1))
  end, "mismatched endpoint color sources must fail instead of silently choosing one")
  Assert.isTrue(Errors.is(err), "the conflict is a structured producer error")
  Assert.isTrue(type(err.message) == "string" and #err.message > 0, "the conflict carries a message")
  Assert.isTrue(type(err.context) == "table", "the conflict carries source context")
end

-- One batch whose own boundary turns at P=(0,1,1) while its spanning edge
-- A-B passes straight through: the spanning edge splits at the shared
-- breakpoint exactly as for a touching batch, because host sampling
-- disagrees along differently segmented collinear edges wherever the
-- breakpoint lives.
function T.repairs_a_same_batch_t_junction_and_preserves_area_and_winding()
  local batch = B({
    V(0, 1, 0),
    V(0, 1, 4),
    V(4, 1, 2),
    V(0, 1, 1),
    V(-4, 1, 2),
  }, { 0, 1, 2, 3, 1, 4 })
  local input = denseBatches({ batch })
  Assert.isTrue(#junctions(input) >= 1, "the same-batch T arrangement must be diagnosed before repair")
  local beforeAreas = triangleAreas(input[1])
  local beforeTotal = beforeAreas[1] + beforeAreas[2]
  local after = conform(cloneBatches(input))
  Assert.equal(#junctions(after), 0, "no unmatched boundary T-junction may remain after repair")
  Assert.equal(after[1].vertexCount, 6, "the spanning edge gains the shared breakpoint")
  Assert.equal(after[1].indexCount, 9, "the split triangle becomes two; its neighbor is untouched")
  Assert.equal(countAt(after, 0, 1, 1), 2, "the shared breakpoint is expressed on both sides of the split")
  local areas = triangleAreas(after[1])
  local total = 0
  for _, area in ipairs(areas) do
    Assert.isTrue(math.abs(area) > 1e-12, "retriangulation emits no zero-area triangle")
    total = total + area
  end
  Assert.isTrue(math.abs(total - beforeTotal) < 1e-9, "retriangulation covers exactly the original area")
  Assert.isTrue(
    areas[1] * beforeAreas[1] > 0 and areas[2] * beforeAreas[1] > 0,
    "the split preserves the original winding"
  )
  Assert.equal(areas[3], beforeAreas[2], "the untouched triangle keeps its exact area")
  Assert.deepEqual(
    denseSnapshot(conform(cloneBatches(input))),
    denseSnapshot(after),
    "the same input conforms byte-identically across runs"
  )
  local again = conformer().conform(cloneBatches(after), context()) or after
  Assert.deepEqual(denseSnapshot(again), denseSnapshot(after), "repair is idempotent")
end

-- Two crossing boundary spans: batch one owns the breakpoint P=(-2,1,14)
-- as a boundary corner while batch two spans straight through it along
-- z=14, and batch one's own edge U0-U1 spans straight through P along
-- x=-2. Both breakpoints are visible before repair -- one same-batch, one
-- across batches -- so one closure pass splits both spans; the split
-- diagonals are internal tessellation edges, so no further breakpoint
-- appears and a second conform changes nothing.
function T.repairs_same_and_cross_batch_breakpoints_to_closure()
  local first = B({
    V(-2, 1, 16),
    V(-2, 1, 12),
    V(2, 1, 14),
    V(-2, 1, 14),
    V(-6, 1, 15),
  }, { 0, 1, 2, 0, 3, 4 })
  local second = B({
    V(-7, 1, 14),
    V(-1, 1, 14),
    V(-4, 1, 18),
  }, { 0, 1, 2 })
  local before = denseBatches({ first, second })
  Assert.equal(#junctions(before), 2, "the same-batch span and the other batch's span are both unmatched before repair")
  local after = conform(cloneBatches(before))
  Assert.equal(#junctions(after), 0, "both spans are repaired to closure")
  Assert.equal(countAt({ after[1] }, -2, 1, 14), 2, "the first batch expresses the shared breakpoint twice")
  Assert.equal(countAt({ after[2] }, -2, 1, 14), 1, "the second batch expresses the shared breakpoint once")
  Assert.equal(after[1].indexCount, 9, "the first batch splits one triangle in two")
  Assert.equal(after[2].indexCount, 6, "the second batch splits one triangle in two")
  for index, batch in ipairs(after) do
    for _, area in ipairs(triangleAreas(batch)) do
      Assert.isTrue(math.abs(area) > 1e-12, "retriangulation emits no zero-area triangle in batch " .. index)
    end
  end
  Assert.deepEqual(
    denseSnapshot(conform(cloneBatches(before))),
    denseSnapshot(after),
    "the same crossing seam conforms identically across runs"
  )
end

-- Three triangles sharing one geometric edge A-B: a count-3 edge is never
-- a spanning edge, so repair tolerates it and leaves the batch untouched,
-- and diagnostics report no spurious junction for it.
local function tripleEdgeFixture()
  return denseBatches({
    B({
      V(0, 1, 0),
      V(0, 1, 4),
      V(4, 1, 2),
      V(-4, 1, 2),
      V(4, 1, 6),
    }, { 0, 1, 2, 0, 1, 3, 0, 1, 4 }),
  })
end

function T.leaves_a_triple_shared_edge_untouched()
  local input = tripleEdgeFixture()
  local snapshot = denseSnapshot(input)
  local after = conform(input)
  Assert.deepEqual(denseSnapshot(after), snapshot, "an overused edge is tolerated: the batch is unchanged")
  Assert.deepEqual(denseSnapshot(input), snapshot, "conformance leaves the tolerated input untouched")
end

function T.diagnostics_report_no_spurious_junction_for_a_triple_shared_edge()
  local input = tripleEdgeFixture()
  local snapshot = denseSnapshot(input)
  Assert.equal(#junctions(input), 0, "an overused edge is not a spanning edge: no junction is reported")
  Assert.deepEqual(denseSnapshot(input), snapshot, "diagnostics leave the tolerated input unchanged")
end

function T.conforming_twice_changes_nothing()
  local once = conform(cloneBatches(singleSeam()))
  local twice = conformer().conform(cloneBatches(once), context()) or once
  Assert.equal(twice[1].vertexCount, once[1].vertexCount, "a second conform adds no vertices")
  Assert.equal(twice[1].indexCount, once[1].indexCount, "a second conform adds no indices")
  Assert.equal(twice[2].vertexCount, once[2].vertexCount, "a second conform adds no vertices")
  Assert.equal(twice[2].indexCount, once[2].indexCount, "a second conform adds no indices")
  Assert.equal(#junctions(twice), 0, "the conformed result stays clean")
end

function T.repeated_runs_serialize_identically()
  local first = conform(cloneBatches(unionSeam()))
  local second = conform(cloneBatches(unionSeam()))
  Assert.deepEqual(denseSnapshot(second), denseSnapshot(first), "repeated runs produce identical batch slices")
  for i, batch in ipairs(first) do
    Assert.equal(
      Hashing.sha1hex(MeshWriter.encode(batch)),
      Hashing.sha1hex(MeshWriter.encode(second[i])),
      "repeated runs hash identically per batch"
    )
  end
end

-- The repair is driven by boundary topology alone: unusual material labels
-- must not change the outcome. This locks that production takes no
-- per-material branch for any particular map or exemplar.
function T.repairs_regardless_of_material_identity()
  local input = singleSeam(9)
  input[2].materialIndex = 5
  local after = conform(input)
  Assert.equal(#junctions(after), 0, "repair applies independent of material labels")
  Assert.equal(countAt(after, 0, 1, 2), 2, "the shared breakpoint is expressed on both sides")
end

-- Duplicate-owner convergence: one batch carries three exact geometric copies
-- of triangle A-B-C plus a supplier triangle P-D-E whose boundary corner P
-- lies strictly inside edge A-B. Analysis collapses the three copies to one
-- geometric span, while repair refines only one physical owner per pass, so
-- closure legitimately needs three mutation passes plus the final empty pass.
-- A single batch means the old `#batches + 1` allowance was two passes: this
-- fixture structurally exceeds it and must still converge.
local function duplicateOwnersFixture()
  local vertices = {
    V(0, 1, 0),
    V(0, 1, 4),
    V(4, 1, 2),
    V(0, 1, 2),
    V(-4, 1, 2),
    V(-4, 1, 6),
  }
  local indices = { 0, 1, 2, 0, 1, 2, 0, 1, 2, 3, 4, 5 }
  return denseBatches({ B(vertices, indices) })
end

local function spansEdge(batch, ax, ay, az, bx, by, bz)
  local count = 0
  for offset = 0, batch.indexCount - 1, 3 do
    local hasA = false
    local hasB = false
    for k = 0, 2 do
      local index = batch.arena.indices[batch.indexOffset + offset + k]
      local v = batch.arena.numeric[batch.vertexOffset + index]
      if v.x == ax and v.y == ay and v.z == az then
        hasA = true
      end
      if v.x == bx and v.y == by and v.z == bz then
        hasB = true
      end
    end
    if hasA and hasB then
      count = count + 1
    end
  end
  return count
end

function T.converges_every_duplicate_physical_owner_beyond_the_old_batch_bound()
  local input = duplicateOwnersFixture()
  Assert.equal(#input, 1, "the regression fixture is a single batch, so the old two-pass allowance applies")
  Assert.isTrue(#junctions(input) >= 1, "the geometric T-junction is diagnosed before repair")

  local beforeTotal = 0
  for _, area in ipairs(triangleAreas(input[1])) do
    beforeTotal = beforeTotal + area
  end

  local after = conform(cloneBatches(input))
  Assert.equal(#junctions(after), 0, "no repairable T-junction remains at P")
  Assert.equal(#after, 1, "the single batch stays a single batch")
  Assert.equal(
    math.floor(after[1].indexCount / 3),
    7,
    "each of the three duplicate owners splits in two; the supplier is untouched"
  )
  Assert.equal(after[1].vertexCount, 9, "each duplicate split inserts one breakpoint vertex")
  Assert.equal(countAt(after, 0, 1, 2), 4, "every physical duplicate owner expresses P, plus the supplier corner")
  Assert.equal(spansEdge(after[1], 0, 1, 0, 0, 1, 4), 0, "no physical triangle still spans the full A-B edge")
  local areas = triangleAreas(after[1])
  local total = 0
  for _, area in ipairs(areas) do
    Assert.isTrue(math.abs(area) > 1e-12, "retriangulation emits no zero-area triangle")
    Assert.isTrue(area * beforeTotal > 0, "every refined triangle keeps the original winding")
    total = total + area
  end
  Assert.isTrue(math.abs(total - beforeTotal) < 1e-9, "retriangulation covers exactly the original area")

  local again = conformer().conform(cloneBatches(after), context()) or after
  Assert.deepEqual(denseSnapshot(again), denseSnapshot(after), "repair is idempotent on the duplicate-owner result")
  Assert.deepEqual(
    denseSnapshot(conform(cloneBatches(input))),
    denseSnapshot(after),
    "the same duplicate input conforms byte-identically across runs"
  )
  Assert.equal(
    Hashing.sha1hex(MeshWriter.encode(conform(cloneBatches(input))[1])),
    Hashing.sha1hex(MeshWriter.encode(after[1])),
    "repeated runs hash identically"
  )
end

-- Transactional failure: a categorical conflict on a later pass must leave
-- the caller's batches exactly as they were. This exercises the same
-- entry-snapshot restore that every conformance failure path (including the
-- did-not-converge producer error) shares.
function T.failed_conformance_restores_pristine_input()
  local input = attributeFixture(0, 1)
  local snapshot = denseSnapshot(input)
  local ok, err = pcall(conformer().conform, input, context())
  Assert.isFalse(ok, "the color-source conflict must fail")
  Assert.isTrue(Errors.is(err), "the failure is a structured producer error")
  ---@cast err table
  Assert.isTrue(type(err.code) == "string" and #err.code > 0, "the failure carries a stable error code")
  Assert.isTrue(type(err.context) == "table", "the failure carries source context")
  Assert.deepEqual(denseSnapshot(input), snapshot, "a failed conformance restores every batch to its pristine state")
end

function T.repairs_dense_slices_deterministically()
  local fixtures = { singleSeam(), multiSplit(), unionSeam(), duplicateOwnersFixture(), attributeFixture(2, 2) }
  for _, fixture in ipairs(fixtures) do
    local first = cloneBatches(fixture)
    local second = cloneBatches(fixture)
    local repair = conformer()
    repair.conform(first, context())
    repair.conform(second, context())
    Assert.equal(#repair.findTJunctions(first), 0, "dense repair leaves no repairable T-junction")
    Assert.equal(#repair.findTJunctions(second), 0, "repeated dense repair leaves no repairable T-junction")
    Assert.deepEqual(denseSnapshot(second), denseSnapshot(first), "dense repair is deterministic")
  end
end

function T.keeps_reusable_scratch_off_the_caller_owned_arena()
  local batches = singleSeam()
  local arena = batches[1].arena
  local first = denseSnapshot(conform(batches))

  Assert.isNil(arena._terrainBoundaryScratch, "conformance must not attach private scratch to the geometry arena")

  local second = denseSnapshot(conform(batches))
  Assert.deepEqual(second, first, "repeated conformance on one arena remains deterministic")
  Assert.isNil(arena._terrainBoundaryScratch, "repeated conformance must leave the geometry arena unchanged")
end

function T.keeps_conformance_scratch_independent_per_context()
  local repair = conformer()
  local firstContext, secondContext = context(), context()
  local first, second = singleSeam(), singleSeam()

  repair.conform(first, firstContext)
  repair.conform(second, secondContext)

  Assert.isTrue(firstContext.terrainScratch ~= nil, "conformance retains scratch on its explicit context")
  Assert.isTrue(secondContext.terrainScratch ~= nil, "each conformance context retains its own scratch")
  Assert.isTrue(
    firstContext.terrainScratch ~= secondContext.terrainScratch,
    "independent conformance contexts must not share scratch"
  )

  local firstScratch = firstContext.terrainScratch
  repair.conform(first, firstContext)
  Assert.equal(firstContext.terrainScratch, firstScratch, "a context reuses its scratch across conformance calls")
end

return { tests = T }
