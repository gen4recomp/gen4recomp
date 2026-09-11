-- Tests for GxDisplayList's transform-preserving (dynamic) mode: display
-- lists decode into segments whose vertices are baked only through the
-- display-list-local matrix ops, with the pose-dependent transform deferred
-- to per-segment sources. Static mode must remain bit-for-bit unchanged.

local Assert = require("tests.support.Assert")
local GxDisplayList = require("libs.nds.src.gx.GxDisplayList")
local GxGeometryBuffer = require("libs.nds.src.gx.GxGeometryBuffer")
local NB = require("tests.support.NitroBuilder")

local T = {}

-- Pack a display list: an array of command groups, each { {opcodes...}, {paramWords...} }.
local pack = NB.gxPack

-- A VTX_16 parameter word: x in low 16 bits (1.3.12), y in high 16.
local vtx16xy = NB.vtx16xy

-- One triangle: BEGIN + three VTX_16 in one command group, then END.
local function triangle(vertices)
  local ops = { 0x40, 0x23, 0x23, 0x23 }
  local words = { 0 }
  for _, v in ipairs(vertices) do
    words[#words + 1] = vtx16xy(v[1], v[2])
    words[#words + 1] = v[3]
  end
  return pack({ { ops, words } }) .. pack({ { { 0x41 } } })
end

local function decode(bytes, opts)
  opts = opts or {}
  if opts.requireColorSource and opts.initialState == nil then
    opts.initialState = { colorSource = 0 }
  end
  local result, err = GxDisplayList.decode(bytes, opts)
  if not result then
    error(err)
  end
  return result
end

local function assertVertex(segment, index, x, y, z)
  local v = segment.arena.numeric[segment.vertexOffset + index]
  if math.abs(v.x - x) > 1e-9 or math.abs(v.y - y) > 1e-9 or math.abs(v.z - z) > 1e-9 then
    error(
      "vertex "
        .. index
        .. ": expected ("
        .. x
        .. ","
        .. y
        .. ","
        .. z
        .. "), got ("
        .. v.x
        .. ","
        .. v.y
        .. ","
        .. v.z
        .. ")"
    )
  end
end

local function indexValues(segment)
  local out = {}
  for offset = 0, segment.indexCount - 1 do
    out[#out + 1] = segment.arena.indices[segment.indexOffset + offset]
  end
  return out
end

-- ---- basic behavior ----

function T.one_segment_with_the_draw_source()
  local dl = triangle({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } })
  local geom = decode(dl, { dynamic = true, requireColorSource = true })
  Assert.equal(#geom.segments, 1)
  local segment = geom.segments[1]
  Assert.equal(segment.positionSource, "draw")
  Assert.equal(segment.vertexCount, 3)
  Assert.equal(segment.indexCount, 3)
  -- Vertices stay in pre-draw space: identity local ops bake nothing.
  assertVertex(segment, 0, 0, 0, 0)
  assertVertex(segment, 1, 1, 0, 0)
  assertVertex(segment, 2, 0, 1, 0)
end

function T.post_multiply_ops_bake_into_the_vertices()
  -- MTX_MULT_3x3 scale (2,2,2) then the triangle: the local scale is baked.
  local dl = pack({
    { { 0x1A }, { 2 * 4096, 0, 0, 0, 2 * 4096, 0, 0, 0, 2 * 4096 } },
  }) .. triangle({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } })
  local geom = decode(dl, { dynamic = true })
  Assert.equal(#geom.segments, 1)
  Assert.equal(geom.segments[1].positionSource, "draw")
  assertVertex(geom.segments[1], 1, 2, 0, 0)
  assertVertex(geom.segments[1], 2, 0, 2, 0)
end

function T.literal_load_bakes_into_the_vertices()
  -- MTX_LOAD_4x3 with a +10 x translation: the loaded matrix replaces the
  -- draw matrix, so its effect is constant and bakes into the vertices.
  local dl = pack({
    { { 0x17 }, { 4096, 0, 0, 0, 4096, 0, 0, 0, 4096, 10 * 4096, 0, 0 } },
  }) .. triangle({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } })
  local geom = decode(dl, { dynamic = true })
  Assert.equal(#geom.segments, 1)
  assertVertex(geom.segments[1], 0, 10, 0, 0)
  assertVertex(geom.segments[1], 1, 11, 0, 0)
end

-- ---- segment boundaries ----

local MTX_RESTORE = { { 0x14 }, { 3 } }

function T.matrix_restore_splits_a_segment_with_a_slot_source()
  -- Triangle, MTX_RESTORE slot 3, second triangle: two segments, the second
  -- carrying the slot source.
  local dl = triangle({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } })
    .. pack({ MTX_RESTORE })
    .. triangle({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } })
  local geom = decode(dl, { dynamic = true })
  Assert.equal(#geom.segments, 2)
  local first, second = geom.segments[1], geom.segments[2]
  Assert.equal(first.positionSource, "draw")
  Assert.equal(second.positionSource.slot, 3)
  Assert.equal(first.vertexCount, 3)
  Assert.equal(second.vertexCount, 3)
  assertVertex(second, 0, 0, 0, 0)
end

function T.matrix_push_pop_restores_the_prior_source()
  -- Push (draw), restore slot 3 (slot source), pop: back to the draw source,
  -- so a third triangle forms its own "draw" segment.
  local dl = triangle({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } })
    .. pack({ { { 0x11 } }, MTX_RESTORE })
    .. triangle({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } })
    .. pack({ { { 0x12 }, { 0 } } })
    .. triangle({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } })
  local geom = decode(dl, { dynamic = true })
  Assert.equal(#geom.segments, 3)
  Assert.equal(geom.segments[1].positionSource, "draw")
  Assert.equal(geom.segments[2].positionSource.slot, 3)
  Assert.equal(geom.segments[3].positionSource, "draw")
end

function T.segment_indices_are_local_to_each_segment()
  local dl = triangle({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } })
    .. pack({ MTX_RESTORE })
    .. triangle({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } })
  local geom = decode(dl, { dynamic = true })
  local first, second = geom.segments[1], geom.segments[2]
  Assert.equal(first.indexCount, 3)
  Assert.equal(second.indexCount, 3)
  -- Both segments index their own vertices from zero.
  for _, i in ipairs(indexValues(second)) do
    Assert.isTrue(i < 3, "second segment indices are local")
  end
end

-- ---- rejected edges ----

function T.rejects_matrix_store_inside_the_list()
  local dl = triangle({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } }) .. pack({ { { 0x13 }, { 5 } } })
  local err = Assert.throws(function()
    decode(dl, { dynamic = true })
  end)
  Assert.equal(err.code, "GX_DYNAMIC_MATRIX_STORE_UNSUPPORTED")
end

function T.rejects_matrix_ops_under_position_only_mode()
  -- MTX_MODE POSITION (1), then a scale op: the position and direction
  -- matrices would diverge.
  local dl = pack({ { { 0x10 }, { 1 } }, { { 0x1B }, { 2 * 4096, 2 * 4096, 2 * 4096 } } })
  local err = Assert.throws(function()
    decode(dl, { dynamic = true })
  end)
  Assert.equal(err.code, "GX_DYNAMIC_POSITION_ONLY_MATRIX_OP_UNSUPPORTED")
end

function T.splits_a_run_at_a_matrix_boundary()
  -- BEGIN, VTX, RESTORE, VTX x2, END: the hardware re-homes the transform at
  -- submission, so the run is split at the boundary; the straddling
  -- triangle's leading vertex is carried into the next segment, where it
  -- keeps the PRE-boundary source. The DS transforms each vertex at
  -- submission under the then-current matrix, so the carried leading vertex
  -- resolves under "draw" and only the trailing two under the slot.
  local dl = pack({
    { { 0x40, 0x23 }, { 0, vtx16xy(0, 0), 0 } },
    MTX_RESTORE,
    { { 0x23, 0x23 }, { vtx16xy(1, 0), 0, vtx16xy(0, 1), 0 } },
    { { 0x41 } },
  })
  local geom = decode(dl, { dynamic = true })
  Assert.equal(#geom.segments, 2)
  Assert.equal(geom.segments[1].positionSource, "draw")
  Assert.equal(geom.segments[2].positionSource.slot, 3)
  -- The old segment keeps the lone leading vertex (no indices); the new
  -- segment carries a copy and attributes it to the pre-boundary source.
  Assert.equal(geom.segments[1].vertexCount, 1)
  Assert.equal(geom.segments[1].indexCount, 0)
  Assert.equal(geom.segments[2].vertexCount, 3)
  Assert.equal(geom.segments[2].indexCount, 3)
  assertVertex(geom.segments[2], 0, 0, 0, 0)
  Assert.deepEqual(geom.segments[2].straddle, { leading = 1, source = "draw" })
  Assert.equal(geom.straddlingPrimitives, 1)
end

function T.boundary_before_any_vertex_keeps_the_run_whole()
  -- BEGIN, RESTORE, then vertices: the run has no vertices at the boundary,
  -- so nothing straddles; the whole run lands in the new segment.
  local dl = pack({
    { { 0x40 }, { 0 } },
    MTX_RESTORE,
    { { 0x23, 0x23, 0x23 }, { vtx16xy(0, 0), 0, vtx16xy(1, 0), 0, vtx16xy(0, 1), 0 } },
    { { 0x41 } },
  })
  local geom = decode(dl, { dynamic = true })
  Assert.equal(#geom.segments, 1)
  local segment = geom.segments[1]
  Assert.equal(segment.positionSource.slot, 3)
  Assert.equal(segment.vertexCount, 3)
  Assert.equal(segment.indexCount, 3)
  Assert.equal(geom.straddlingPrimitives, 0)
  Assert.isNil(segment.straddle, "an empty-run boundary carries no straddle record")
end

function T.straddle_source_is_the_prior_source_under_a_pop_boundary()
  -- BEGIN(tris), VTX, PUSH, RESTORE slot 3, VTX x3, POP (back to the pushed
  -- draw source), VTX x2, END: the pop boundary's straddling triangle keeps
  -- the SLOT source (the source active at its leading vertex's submission),
  -- and the segment after the pop resolves under the popped "draw" source.
  local dl = pack({
    { { 0x40, 0x23 }, { 0, vtx16xy(0, 0), 0 } },
    { { 0x11 } },
    MTX_RESTORE,
    { { 0x23, 0x23, 0x23 }, { vtx16xy(1, 0), 0, vtx16xy(0, 1), 0, vtx16xy(1, 1), 0 } },
    { { 0x12 }, { 0 } },
    { { 0x23, 0x23 }, { vtx16xy(2, 0), 0, vtx16xy(2, 1), 0 } },
    { { 0x41 } },
  })
  local geom = decode(dl, { dynamic = true })
  Assert.equal(#geom.segments, 3)
  Assert.equal(geom.segments[1].positionSource, "draw")
  Assert.equal(geom.segments[2].positionSource.slot, 3)
  -- Segment 2 emitted its complete triangle before the pop; the pop's
  -- straddling triangle keeps the slot as the leading source, and the
  -- segment after the pop resolves under the popped "draw" source.
  Assert.equal(geom.segments[2].indexCount, 3)
  Assert.deepEqual(geom.segments[2].straddle, { leading = 1, source = "draw" })
  Assert.equal(geom.segments[3].positionSource, "draw")
  Assert.deepEqual(geom.segments[3].straddle, { leading = 1, source = { slot = 3 } })
  Assert.equal(geom.straddlingPrimitives, 2)
end

function T.reused_scratch_preserves_dynamic_segments_and_straddles()
  local dl = pack({
    { { 0x40, 0x23 }, { 0, vtx16xy(0, 0), 0 } },
    MTX_RESTORE,
    { { 0x23, 0x23 }, { vtx16xy(1, 0), 0, vtx16xy(0, 1), 0 } },
    { { 0x41 } },
  })
  local scratch = GxDisplayList.newScratch()
  local arena = GxGeometryBuffer.new()
  local reused = decode(dl, { dynamic = true, requireColorSource = true, arena = arena, scratch = scratch })
  local fresh = decode(dl, { dynamic = true, requireColorSource = true })
  Assert.equal(#reused.segments, #fresh.segments)
  Assert.equal(reused.straddlingPrimitives, fresh.straddlingPrimitives)
  for index, segment in ipairs(reused.segments) do
    local expected = fresh.segments[index]
    Assert.deepEqual(segment.positionSource, expected.positionSource)
    Assert.deepEqual(segment.straddle, expected.straddle)
    Assert.equal(segment.vertexCount, expected.vertexCount)
    Assert.equal(segment.indexCount, expected.indexCount)
    Assert.deepEqual(indexValues(segment), indexValues(expected))
  end
end

function T.each_boundary_of_a_multi_split_run_carries_its_own_straddle()
  -- BEGIN(quads), VTX x2, RESTORE slot 3, VTX x4, RESTORE slot 4, VTX x2,
  -- END: a run with two mid-run boundaries. The first boundary splits after
  -- two leading vertices (straddle source "draw"); the second splits after
  -- six (one complete quad emitted in the slot-3 segment, then two more
  -- leading vertices carried with the slot-3 source).
  local dl = pack({
    { { 0x40, 0x23, 0x23 }, { 1, vtx16xy(0, 0), 0, vtx16xy(1, 0), 0 } },
    MTX_RESTORE,
    { { 0x23, 0x23 }, { vtx16xy(0, 1), 0, vtx16xy(1, 1), 0 } },
    { { 0x23, 0x23 }, { vtx16xy(2, 0), 0, vtx16xy(2, 1), 0 } },
    { { 0x14 }, { 4 } },
    { { 0x23, 0x23 }, { vtx16xy(3, 0), 0, vtx16xy(3, 1), 0 } },
    { { 0x41 } },
  })
  local geom = decode(dl, { dynamic = true })
  Assert.equal(#geom.segments, 3)
  Assert.equal(geom.segments[1].positionSource, "draw")
  Assert.equal(geom.segments[2].positionSource.slot, 3)
  Assert.equal(geom.segments[3].positionSource.slot, 4)
  -- Segment 2 emitted its complete quad (6 indices) before the second
  -- boundary and carries the first straddle's leading pair.
  Assert.equal(geom.segments[2].indexCount, 6)
  Assert.deepEqual(geom.segments[2].straddle, { leading = 2, source = "draw" })
  Assert.deepEqual(geom.segments[3].straddle, { leading = 2, source = { slot = 3 } })
  Assert.equal(geom.straddlingPrimitives, 2)
end

function T.straddling_quads_are_carried_into_the_new_segment()
  -- BEGIN(separate quads), two quads, RESTORE, one quad, END: the first
  -- segment keeps its complete quad; the quad spanning the boundary has its
  -- leading vertices carried so they keep the pre-boundary source ("draw")
  -- while the trailing two resolve under the slot.
  local dl = pack({
    { { 0x40, 0x23, 0x23 }, { 1, vtx16xy(0, 0), 0, vtx16xy(1, 0), 0 } },
    { { 0x23, 0x23 }, { vtx16xy(1, 1), 0, vtx16xy(0, 1), 0 } },
    { { 0x23, 0x23 }, { vtx16xy(2, 0), 0, vtx16xy(3, 0), 0 } },
    MTX_RESTORE,
    { { 0x23, 0x23 }, { vtx16xy(4, 1), 0, vtx16xy(3, 1), 0 } },
    { { 0x41 } },
  })
  local geom = decode(dl, { dynamic = true })
  Assert.equal(#geom.segments, 2)
  local first, second = geom.segments[1], geom.segments[2]
  Assert.equal(first.vertexCount, 6)
  Assert.equal(first.indexCount, 6)
  Assert.equal(second.positionSource.slot, 3)
  -- The carried leading vertices (copies of the old segment's v4/v5) plus
  -- the two trailing vertices form the straddling quad, with the leading
  -- half attributed to the pre-boundary source.
  Assert.equal(second.vertexCount, 4)
  Assert.equal(second.indexCount, 6)
  assertVertex(second, 0, 2, 0, 0)
  assertVertex(second, 1, 3, 0, 0)
  Assert.deepEqual(second.straddle, { leading = 2, source = "draw" })
  Assert.equal(geom.straddlingPrimitives, 1)
end

function T.triangle_strip_winding_continues_across_a_boundary()
  -- A triangle strip split after its first triangle: the carried vertices
  -- keep the strip's alternating winding (the DS computes it from the
  -- running vertex index, which the split must carry).
  local dl = pack({
    { { 0x40, 0x23, 0x23 }, { 2, vtx16xy(0, 0), 0, vtx16xy(1, 0), 0 } },
    { { 0x23 }, { vtx16xy(0, 1), 0 } },
    MTX_RESTORE,
    { { 0x23, 0x23, 0x23 }, { vtx16xy(1, 1), 0, vtx16xy(2, 1), 0, vtx16xy(2, 0), 0 } },
    { { 0x41 } },
  })
  local geom = decode(dl, { dynamic = true })
  Assert.equal(#geom.segments, 2)
  local first, second = geom.segments[1], geom.segments[2]
  Assert.equal(first.vertexCount, 3)
  -- First strip triangle: (0,1,2) with the even winding.
  Assert.deepEqual(indexValues(first), { 0, 1, 2 })
  -- The second segment carries copies of the last two vertices and
  -- continues the strip: local (1,0,2) for the triangle ending at global
  -- vertex 3, matching the DS's alternating winding. The carried pair keeps
  -- the pre-boundary source; the trailing vertices resolve under the slot.
  Assert.equal(second.vertexCount, 5)
  Assert.deepEqual(indexValues(second), { 1, 0, 2, 1, 2, 3, 3, 2, 4 })
  Assert.deepEqual(second.straddle, { leading = 2, source = "draw" })
  Assert.equal(geom.straddlingPrimitives, 1)
end

-- ---- static mode is unchanged ----

function T.static_mode_still_bakes_the_supplied_matrix()
  local dl = triangle({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } })
  local matrix = { 2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2, 0, 10, 0, 0, 1 }
  local geom = decode(dl, { matrix = matrix })
  Assert.equal(geom.slice.arena.numeric[geom.slice.vertexOffset + 1].x, 12)
  Assert.equal(geom.segments, nil)
end

function T.static_and_dynamic_decode_agree_on_color_state()
  local dl = pack({ { { 0x20 }, { 0x7C00 } } }) .. triangle({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } })
  local static = decode(dl, { requireColorSource = true })
  local dynamic = decode(dl, { dynamic = true, requireColorSource = true })
  local sa = static.slice.arena.attrib[static.slice.vertexOffset]
  local da = dynamic.segments[1].arena.attrib[dynamic.segments[1].vertexOffset]
  Assert.equal(da.r, sa.r)
  Assert.equal(da.g, sa.g)
  Assert.equal(da.b, sa.b)
  Assert.equal(da.colorSource, sa.colorSource)
end

return { tests = T }
