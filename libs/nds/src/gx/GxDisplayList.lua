-- Decoder for the DS geometry-engine display list embedded in an MDL0 shape.
-- The stream is in GX "packed" form: a u32 of four command bytes, then the
-- parameter words for those four commands in order (a 0x00 byte is a NOP with
-- no params). Command semantics follow GBATEK "DS Video Geometry Commands".
--
-- The decoder keeps persistent attribute state (position, normal, texcoord,
-- color) exactly as the hardware does -- partial vertex commands reuse the
-- previous coordinates -- and an internal 4x4 matrix stack so a self-contained
-- list transforms correctly. Node matrices selected via MTX_RESTORE default to
-- identity here; the model compiler supplies them through the SBC stream. DS
-- primitives are converted to indexed triangles. Unknown opcodes are fatal
-- with a byte offset. Pure domain module; arithmetic only.
--
-- `options.dynamic` selects the transform-preserving mode: the SBC
-- draw matrix is not applied -- vertices come out in pre-draw space with only
-- display-list-local matrix ops baked in -- and each vertex run is split into
-- segments at the matrix operations whose result depends on runtime pose
-- state (MTX_RESTORE slot contents, MTX_PUSH/POP source changes). A segment
-- carries the source that resolves its transform at draw time:
--
--   positionSource = "draw" | { slot = k }
--
--   "draw"        the SBC draw's position matrix
--   { slot = k }  matrix-stack slot k as of that draw (the evaluator's
--                 per-draw restoreStack snapshot)
--
-- Under the supported op set the direction matrix always mirrors the
-- position matrix (POSITION_VECTOR mode throughout), so the runtime derives
-- the direction as the linear part of the resolved position matrix.
-- Display-list-local MTX_STORE and matrix ops under MTX_MODE POSITION are
-- rejected loudly: no field asset exercises them and the segment contract
-- cannot express their per-vertex state. A matrix change inside an open
-- BEGIN..END run is split at the boundary exactly where the hardware re-homes
-- the transform at vertex submission: the complete primitives before it keep
-- their segment, and the primitive that would straddle the two transforms has
-- its leading vertices carried into the next segment. The receiving segment
-- records the per-vertex provenance -- `straddle = { leading, source }` with
-- the pre-boundary source -- so the runtime resolves the leading vertices
-- under the old matrix and the trailing ones under the segment's own source,
-- reproducing the DS's per-vertex bend (the count is reported for the
-- caller). Static decode (the default) is unchanged.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")
local FixedPoint = require("libs.math.src.FixedPoint")
local Matrix4 = require("libs.math.src.Matrix4")
local ffi = require("ffi")
local GxGeometryBuffer = require("libs.nds.src.gx.GxGeometryBuffer")

local GxDisplayList = {}

-- Per-vertex color provenance carried into the mesh (matches the G4M2 field):
-- 0 literal RGB (COLOR or a snapshotted diffuse), 1 produced by NORMAL lighting,
-- 2 sourced from the field-profile diffuse via the material's set-vertex-color.
local COLOR_SOURCE = { LITERAL = 0, NORMAL_LIT = 1, FIELD_DIFFUSE = 2 }
local DRAW_SOURCE = "draw"

-- Parameter word count per opcode. Absent = unknown/unsupported (fatal).
local PARAM_WORDS = {
  [0x00] = 0, -- NOP
  [0x10] = 1,
  [0x11] = 0,
  [0x12] = 1,
  [0x13] = 1,
  [0x14] = 1,
  [0x15] = 0,
  [0x16] = 16,
  [0x17] = 12,
  [0x18] = 16,
  [0x19] = 12,
  [0x1A] = 9,
  [0x1B] = 3,
  [0x1C] = 3,
  [0x20] = 1,
  [0x21] = 1,
  [0x22] = 1,
  [0x23] = 2,
  [0x24] = 1,
  [0x25] = 1,
  [0x26] = 1,
  [0x27] = 1,
  [0x28] = 1,
  [0x29] = 1,
  [0x2A] = 1,
  [0x2B] = 1,
  [0x30] = 1,
  [0x31] = 1,
  [0x32] = 1,
  [0x33] = 1,
  [0x34] = 32,
  [0x40] = 1,
  [0x41] = 0,
}

local OPCODE_NAMES = {
  [0x10] = "MTX_MODE",
  [0x11] = "MTX_PUSH",
  [0x12] = "MTX_POP",
  [0x13] = "MTX_STORE",
  [0x14] = "MTX_RESTORE",
  [0x15] = "MTX_IDENTITY",
  [0x16] = "MTX_LOAD_4x4",
  [0x17] = "MTX_LOAD_4x3",
  [0x18] = "MTX_MULT_4x4",
  [0x19] = "MTX_MULT_4x3",
  [0x1A] = "MTX_MULT_3x3",
  [0x1B] = "MTX_SCALE",
  [0x1C] = "MTX_TRANS",
  [0x20] = "COLOR",
  [0x21] = "NORMAL",
  [0x22] = "TEXCOORD",
  [0x23] = "VTX_16",
  [0x24] = "VTX_10",
  [0x25] = "VTX_XY",
  [0x26] = "VTX_XZ",
  [0x27] = "VTX_YZ",
  [0x28] = "VTX_DIFF",
  [0x29] = "POLYGON_ATTR",
  [0x2A] = "TEXIMAGE_PARAM",
  [0x2B] = "PLTT_BASE",
  [0x30] = "DIF_AMB",
  [0x31] = "SPE_EMI",
  [0x32] = "LIGHT_VECTOR",
  [0x33] = "LIGHT_COLOR",
  [0x34] = "SHININESS",
  [0x40] = "BEGIN_VTXS",
  [0x41] = "END_VTXS",
}

-- ---- minimal column-major 4x4 matrix math (DS convention) ----

local function identity()
  return { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
end

local function multiply(a, b) -- a * b, column-major
  local m = {}
  for col = 0, 3 do
    for row = 0, 3 do
      local s = 0
      for k = 0, 3 do
        s = s + a[k * 4 + row + 1] * b[col * 4 + k + 1]
      end
      m[col * 4 + row + 1] = s
    end
  end
  return m
end

local function transformPoint(m, x, y, z)
  return m[1] * x + m[5] * y + m[9] * z + m[13],
    m[2] * x + m[6] * y + m[10] * z + m[14],
    m[3] * x + m[7] * y + m[11] * z + m[15]
end

-- A direction is transformed by the matrix's linear part only, matching the DS
-- vector matrix, which is 3x3 and so never picks up a translation.
local function transformDirection(m, x, y, z)
  return m[1] * x + m[5] * y + m[9] * z, m[2] * x + m[6] * y + m[10] * z, m[3] * x + m[7] * y + m[11] * z
end

-- The linear part of a 4x4, as the 4x4 a direction matrix accumulates.
local linear = Matrix4.linear

-- 12 fx32 params (column-major 4x3) -> 4x4 with implicit (0,0,0,1) last row.
local function mat4x3(p)
  local f = FixedPoint.fx32
  return {
    f(p[1]),
    f(p[2]),
    f(p[3]),
    0,
    f(p[4]),
    f(p[5]),
    f(p[6]),
    0,
    f(p[7]),
    f(p[8]),
    f(p[9]),
    0,
    f(p[10]),
    f(p[11]),
    f(p[12]),
    1,
  }
end

local function mat4x4(p)
  local m = {}
  for i = 1, 16 do
    m[i] = FixedPoint.fx32(p[i])
  end
  return m
end

-- ---- decoder state ----

local Decoder = {}
Decoder.__index = Decoder

-- GX_MTXMODE_*: which of the geometry engine's matrices the matrix commands act
-- on. The SBC stream leaves POSITION_VECTOR active before calling a shape's
-- display list (NitroSystem sbc.c restores it after every path that changes it),
-- so that is the mode a list starts in.
local MTXMODE = { PROJECTION = 0, POSITION = 1, POSITION_VECTOR = 2, TEXTURE = 3 }

local function newDecoder(arena, runCapacity)
  return setmetatable({
    arena = arena,
    matrix = identity(),
    -- The vector matrix, which transforms normals. It tracks the position
    -- matrix's linear part except where MTX_MODE selects the position matrix
    -- alone, which is the only way the two can diverge.
    directionMatrix = identity(),
    pushStack = {},
    restoreStack = {}, -- MTX_RESTORE slots, default identity
    directionRestoreStack = {},
    posX = 0,
    posY = 0,
    posZ = 0,
    normalX = 0,
    normalY = 1,
    normalZ = 0,
    uvU = 0,
    uvV = 0,
    colorR = 255,
    colorG = 255,
    colorB = 255,
    colorSource = nil, -- resolved by COLOR/NORMAL or seeded from material state
    mtxMode = MTXMODE.POSITION_VECTOR,
    run = ffi.new("uint32_t[?]", math.max(1, runCapacity)),
    runCount = 0,
    runOpen = false,
    primType = nil,
    opcodeCounts = {},
    polygonAttrs = {}, -- set of distinct POLYGON_ATTR words issued in-list
    -- Dynamic (transform-preserving) mode state: the display-list-local
    -- matrix baked into vertices, the transform source of the current
    -- segment, and the segments themselves. Unused in static mode.
    dynamic = false,
    baked = identity(),
    bakedDirection = identity(),
    positionSource = DRAW_SOURCE,
    segments = {},
    currentSegment = nil,
    runParity = 0, -- triangle-strip winding parity of the open run's first vertex
    runSplit = false, -- the open run was split at a mid-run matrix boundary
    carry = ffi.new("uint32_t[?]", math.max(1, runCapacity)),
    carryCount = 0,
    straddlingPrimitives = 0, -- straddling primitives, reported to the caller
  }, Decoder)
end

-- A fresh segment record; `positionSource` describes how the runtime
-- resolves the segment's draw matrix.
---@class GxDynamicGeometrySlice: G4GxGeometrySlice
---@field positionSource DrawSource
---@field straddle { leading: integer, source: DrawSource }?

---@param arena GxGeometryBuffer
---@param positionSource DrawSource
---@return GxDynamicGeometrySlice
local function newSegment(arena, positionSource)
  return {
    arena = arena,
    vertexOffset = arena.vertexCount,
    vertexCount = 0,
    indexOffset = arena.indexCount,
    indexCount = 0,
    positionSource = positionSource,
  }
end

---@param d { arena: GxGeometryBuffer }
---@param segment { vertexOffset: integer, indexOffset: integer, vertexCount: integer, indexCount: integer }
local function finishSegment(d, segment)
  segment.vertexCount = d.arena.vertexCount - segment.vertexOffset
  segment.indexCount = d.arena.indexCount - segment.indexOffset
end

local function appendTriangle(d, run, a, b, c)
  assert(a < d.runCount and b < d.runCount and c < d.runCount, "primitive references a missing vertex")
  local indices = d.arena.indices
  local indexCount = d.arena.indexCount
  indices[indexCount] = run[a]
  indices[indexCount + 1] = run[b]
  indices[indexCount + 2] = run[c]
  d.arena.indexCount = indexCount + 3
end

local function convertTriangleList(d, run, offset, lenient)
  local n = d.runCount
  local complete = n - n % 3
  local tail = 0
  if n % 3 ~= 0 then
    if not lenient then
      error(
        Errors.new(
          "GX_INCOMPLETE_PRIMITIVE",
          string.format("triangle list has %d vertices (not a multiple of 3)", n),
          { offset = offset }
        )
      )
    end
    tail = n % 3
  end
  for i = 0, complete - 1, 3 do
    appendTriangle(d, run, i, i + 1, i + 2)
  end
  return tail
end

local function convertQuadList(d, run, offset, lenient)
  local n = d.runCount
  local complete = n - n % 4
  local tail = 0
  if n % 4 ~= 0 then
    if not lenient then
      error(
        Errors.new(
          "GX_INCOMPLETE_PRIMITIVE",
          string.format("quad list has %d vertices (not a multiple of 4)", n),
          { offset = offset }
        )
      )
    end
    tail = n % 4
  end
  for i = 0, complete - 1, 4 do
    appendTriangle(d, run, i, i + 1, i + 2)
    appendTriangle(d, run, i, i + 2, i + 3)
  end
  return tail
end

local function convertTriangleStrip(d, run, offset, lenient)
  local n = d.runCount
  if n < 3 then
    if not lenient then
      error(Errors.new("GX_INCOMPLETE_PRIMITIVE", "triangle strip has fewer than 3 vertices", { offset = offset }))
    end
    return n
  end
  local parity = d.runParity
  for i = 2, n - 1 do
    if (i + parity) % 2 == 0 then
      appendTriangle(d, run, i - 2, i - 1, i)
    else
      appendTriangle(d, run, i - 1, i - 2, i)
    end
  end
  -- The next triangle would cross the boundary into the new segment.
  return lenient and 2 or 0
end

local function convertQuadStrip(d, run, offset, lenient)
  local n = d.runCount
  if n < 4 then
    if not lenient then
      error(Errors.new("GX_INCOMPLETE_PRIMITIVE", string.format("quad strip has %d vertices", n), { offset = offset }))
    end
    return n
  end
  for i = 0, n - 4, 2 do
    appendTriangle(d, run, i, i + 1, i + 3)
    appendTriangle(d, run, i, i + 3, i + 2)
  end
  if n % 2 ~= 0 and not lenient then
    error(Errors.new("GX_INCOMPLETE_PRIMITIVE", string.format("quad strip has %d vertices", n), { offset = offset }))
  end
  -- The next quad would cross the boundary into the new segment; its
  -- leading vertices are the last (n % 2 == 0 and 2 or 3) of this run.
  return lenient and math.min(n, n % 2 == 0 and 2 or 3) or 0
end

local PRIMITIVE_CONVERTERS = {
  convertTriangleList,
  convertQuadList,
  convertTriangleStrip,
  convertQuadStrip,
}

-- Convert the open vertex run into triangles. Strict mode (END_VTXS) rejects
-- incomplete primitives as malformed. Lenient mode (a mid-run matrix
-- boundary) emits complete primitives and returns the trailing vertices that
-- belong to the primitive straddling the boundary.
local function convertRun(d, offset, lenient)
  local run, primitiveType = d.run, d.primType
  if primitiveType == nil then
    error("primitive run is missing")
  end
  return PRIMITIVE_CONVERTERS[primitiveType + 1](d, run, offset, lenient)
end

-- End the current dynamic segment and start the next one under `positionSource`.
-- A matrix change inside an open BEGIN..END run re-homes the transform for
-- the vertices after it, exactly as the geometry engine applies it at vertex
-- submission. The run is split at the boundary: complete primitives before it
-- stay in the current segment, the primitive that would straddle the two
-- transforms has its leading vertices carried into the next segment, and the
-- trailing vertices continue the run in the new segment. The receiving
-- segment records `straddle = { leading, source = <the pre-boundary source> }`
-- so the runtime resolves the leading vertices under the matrix active at
-- their submission and the rest under the segment's own source -- the DS's
-- per-vertex bend, not a rigid re-home (counted for the caller to report).
-- Triangle strips carry the winding parity across the split so the sequence
-- stays continuous.
---@param positionSource DrawSource
---@param offset integer
function Decoder:dynamicBoundary(positionSource, offset)
  assert(self.dynamic, "dynamicBoundary outside dynamic mode")
  local previousSource = self.positionSource
  local carried = 0
  if self.runOpen then
    local count = self.runCount
    local tail = convertRun(self, offset, true)
    carried = tail
    self.straddlingPrimitives = self.straddlingPrimitives + (tail > 0 and 1 or 0)
    self.carryCount = tail
    for i = 0, tail - 1 do
      self.carry[i] = self.run[count - tail + i]
    end
    self.runCount = 0
    for i = 1, tail do
      self.run[i - 1] = i - 1
    end
    self.runCount = tail
    self.runParity = self.runParity + count - tail
    self.runSplit = true
  end
  local oldSegment = self.currentSegment
  if self.arena.vertexCount > oldSegment.vertexOffset then
    finishSegment(self, oldSegment)
    self.segments[#self.segments + 1] = self.currentSegment
  end
  self.baked = identity()
  self.bakedDirection = identity()
  self.positionSource = positionSource
  self.currentSegment = newSegment(self.arena, positionSource)
  if carried > 0 then
    local numeric = self.arena.numeric
    local attrib = self.arena.attrib
    for i = 0, self.carryCount - 1 do
      local source = oldSegment.vertexOffset + self.carry[i]
      local destination = self.arena.vertexCount
      ffi.copy(numeric[destination], numeric[source], GxGeometryBuffer.vertexNumericSize)
      ffi.copy(attrib[destination], attrib[source], GxGeometryBuffer.vertexAttribSize)
      self.arena.vertexCount = destination + 1
      self.run[i] = i
    end
  end
  if carried > 0 then
    self.currentSegment.straddle = { leading = carried, source = previousSource }
  end
end

-- Reject matrix ops under MTX_MODE POSITION in dynamic mode: the position
-- matrix would change while the direction matrix keeps its old value, a
-- divergence the segment sources (always mirroring position) cannot carry.
-- No field asset exercises it.
function Decoder:dynamicMatrixGuard(offset)
  if self.dynamic and self.mtxMode == MTXMODE.POSITION then
    error(
      Errors.new(
        "GX_DYNAMIC_POSITION_ONLY_MATRIX_OP_UNSUPPORTED",
        "a matrix command under MTX_MODE POSITION would separate the position "
          .. "from the direction transform, which the transform-preserving "
          .. "contract does not support",
        { offset = offset }
      )
    )
  end
end

function Decoder:restoreSlot(idx)
  return self.restoreStack[idx] or identity()
end

function Decoder:directionRestoreSlot(idx)
  return self.directionRestoreStack[idx] or linear(self:restoreSlot(idx))
end

-- Which matrices the current MTX_MODE selects.
function Decoder:touchesPosition()
  return self.mtxMode == MTXMODE.POSITION or self.mtxMode == MTXMODE.POSITION_VECTOR
end

function Decoder:touchesDirection()
  return self.mtxMode == MTXMODE.POSITION_VECTOR
end

function Decoder:emitVertex()
  local wx, wy, wz, nx, ny, nz
  if self.dynamic then
    -- Transform-preserving mode: only the display-list-local matrix is
    -- baked; the SBC draw matrix (and its linear part for normals) applies
    -- at draw time through the segment's sources.
    wx, wy, wz = transformPoint(self.baked, self.posX, self.posY, self.posZ)
    nx, ny, nz = transformDirection(self.bakedDirection, self.normalX, self.normalY, self.normalZ)
  else
    wx, wy, wz = transformPoint(self.matrix, self.posX, self.posY, self.posZ)
    nx, ny, nz = transformDirection(self.directionMatrix, self.normalX, self.normalY, self.normalZ)
  end
  -- The DS feeds the raw transformed normal to its lighting unit, where a joint
  -- or posScale magnification just saturates the result. This pipeline instead
  -- bakes a normal for the engine's own shader to light, so the direction is
  -- what carries meaning and the magnitude is renormalized away.
  local length = math.sqrt(nx * nx + ny * ny + nz * nz)
  if length > 0 then
    nx, ny, nz = nx / length, ny / length, nz / length
  end
  assert(self.runOpen, "GX vertex emitted outside a primitive run")
  assert(self.runCount < 0xFFFFFFFF, "GX primitive run exceeds uint32_t capacity")
  local arena = self.arena
  local numeric = arena.numeric
  local attrib = arena.attrib
  local vertexIndex = arena.vertexCount
  local numericVertex = numeric[vertexIndex]
  numericVertex.x = wx
  numericVertex.y = wy
  numericVertex.z = wz
  numericVertex.u = self.uvU
  numericVertex.v = self.uvV
  numericVertex.nx = nx
  numericVertex.ny = ny
  numericVertex.nz = nz
  local attributeVertex = attrib[vertexIndex]
  attributeVertex.r = self.colorR
  attributeVertex.g = self.colorG
  attributeVertex.b = self.colorB
  attributeVertex.a = 255
  if self.requireColorSource and self.colorSource == nil then
    error(
      Errors.new(
        "GX_UNRESOLVED_VERTEX_COLOR_SOURCE",
        "vertex has no resolved color source (no COLOR/NORMAL and no material seed)",
        {}
      )
    )
  end
  attributeVertex.colorSource = self.colorSource or COLOR_SOURCE.LITERAL
  arena.vertexCount = vertexIndex + 1
  self.run[self.runCount] = (
    vertexIndex - (self.dynamic and self.currentSegment.vertexOffset or self.slice.vertexOffset)
  )
  self.runCount = self.runCount + 1
end

local function s16(word)
  if word >= 0x8000 then
    return word - 0x10000
  end
  return word
end
local function s10(v)
  return FixedPoint.s10(v)
end

-- Apply a matrix op to whichever matrices the current MTX_MODE selects.
-- Texture-matrix ops are consumed but not applied, since they do not affect
-- vertex bounds; the direction matrix takes only the op's linear part.
function Decoder:applyMatrix(m)
  if self:touchesPosition() then
    self.matrix = multiply(self.matrix, m)
  end
  if self:touchesDirection() then
    self.directionMatrix = multiply(self.directionMatrix, linear(m))
  end
end

function Decoder:loadMatrix(m)
  if self:touchesPosition() then
    self.matrix = m
  end
  if self:touchesDirection() then
    self.directionMatrix = linear(m)
  end
end

local EXEC = {}

local function executeMtxMode(d, p, offset, context)
  local mode = p[1] % 4
  -- Projection-matrix ops would have to be replayed against a projection this
  -- decoder never sees; no target shape selects it.
  if mode == MTXMODE.PROJECTION then
    error(
      Errors.new(
        "GX_PROJECTION_MATRIX_MODE_UNSUPPORTED",
        "display list selects the projection matrix, which the shape decoder cannot replay",
        { offset = offset, source = context }
      )
    )
  end
  d.mtxMode = mode
end
EXEC[0x10] = executeMtxMode

local function executeMtxPush(d)
  if d.dynamic then
    d:dynamicMatrixGuard(d.currentOffset)
    d.pushStack[#d.pushStack + 1] = { d.baked, d.bakedDirection, d.positionSource }
  else
    d.pushStack[#d.pushStack + 1] = { d.matrix, d.directionMatrix }
  end
end
EXEC[0x11] = executeMtxPush

local function executeMtxPop(d)
  local top = d.pushStack[#d.pushStack]
  if top then
    if d.dynamic then
      d:dynamicMatrixGuard(d.currentOffset)
      -- A popped source change is a transform change: split the segment.
      if top[3] ~= d.positionSource then
        d:dynamicBoundary(top[3], d.currentOffset)
      end
      d.baked, d.bakedDirection = top[1], top[2]
    else
      if d:touchesPosition() then
        d.matrix = top[1]
      end
      if d:touchesDirection() then
        d.directionMatrix = top[2]
      end
    end
    d.pushStack[#d.pushStack] = nil
  end
end
EXEC[0x12] = executeMtxPop

local function executeMtxStore(d, p, offset)
  local slot = p[1] % 32
  if d.dynamic then
    -- A slot write captures the *unresolved* draw matrix (baked x draw), so
    -- a later restore of it would need a runtime composition the segment
    -- contract cannot express. No field asset stores inside a display list.
    error(
      Errors.new(
        "GX_DYNAMIC_MATRIX_STORE_UNSUPPORTED",
        "MTX_STORE inside a display list captures the unresolved draw matrix, "
          .. "which the transform-preserving contract does not support",
        { offset = offset }
      )
    )
  end
  if d:touchesPosition() then
    d.restoreStack[slot] = d.matrix
  end
  if d:touchesDirection() then
    d.directionRestoreStack[slot] = d.directionMatrix
  end
end
EXEC[0x13] = executeMtxStore

local function executeMtxRestore(d, p, offset)
  local slot = p[1] % 32
  if d.dynamic and d:touchesPosition() then
    -- The slot's contents are pose-dependent: the segment defers the matrix
    -- to the draw-time restoreStack snapshot.
    d:dynamicMatrixGuard(offset)
    d:dynamicBoundary({ slot = slot }, offset)
    return
  end
  -- Read the direction slot before the position one: an SBC-supplied slot has
  -- no stored direction, so it is derived from the position matrix it replaces.
  local direction = d:directionRestoreSlot(slot)
  if d:touchesPosition() then
    d.matrix = d:restoreSlot(slot)
  end
  if d:touchesDirection() then
    d.directionMatrix = direction
  end
end
EXEC[0x14] = executeMtxRestore

local function executeMtxIdentity(d, _, offset)
  d:dynamicMatrixGuard(offset)
  if d.dynamic then
    if d:touchesPosition() then
      d.baked = identity()
    end
    if d:touchesDirection() then
      d.bakedDirection = identity()
    end
    return
  end
  d:loadMatrix(identity())
end
EXEC[0x15] = executeMtxIdentity

local function executeMtxLoad4x4(d, p, offset)
  d:dynamicMatrixGuard(offset)
  if d.dynamic then
    if d:touchesPosition() then
      d.baked = mat4x4(p)
    end
    if d:touchesDirection() then
      d.bakedDirection = linear(mat4x4(p))
    end
    return
  end
  d:loadMatrix(mat4x4(p))
end
EXEC[0x16] = executeMtxLoad4x4

local function executeMtxLoad4x3(d, p, offset)
  d:dynamicMatrixGuard(offset)
  if d.dynamic then
    if d:touchesPosition() then
      d.baked = mat4x3(p)
    end
    if d:touchesDirection() then
      d.bakedDirection = linear(mat4x3(p))
    end
    return
  end
  d:loadMatrix(mat4x3(p))
end
EXEC[0x17] = executeMtxLoad4x3

local function executeMtxMult4x4(d, p, offset)
  d:dynamicMatrixGuard(offset)
  if d.dynamic then
    if d:touchesPosition() then
      d.baked = multiply(d.baked, mat4x4(p))
    end
    if d:touchesDirection() then
      d.bakedDirection = multiply(d.bakedDirection, linear(mat4x4(p)))
    end
    return
  end
  d:applyMatrix(mat4x4(p))
end
EXEC[0x18] = executeMtxMult4x4

local function executeMtxMult4x3(d, p, offset)
  d:dynamicMatrixGuard(offset)
  if d.dynamic then
    if d:touchesPosition() then
      d.baked = multiply(d.baked, mat4x3(p))
    end
    if d:touchesDirection() then
      d.bakedDirection = multiply(d.bakedDirection, linear(mat4x3(p)))
    end
    return
  end
  d:applyMatrix(mat4x3(p))
end
EXEC[0x19] = executeMtxMult4x3

local function executeMtxMult3x3(d, p, offset)
  d:dynamicMatrixGuard(offset)
  local f = FixedPoint.fx32
  local m = {
    f(p[1]),
    f(p[2]),
    f(p[3]),
    0,
    f(p[4]),
    f(p[5]),
    f(p[6]),
    0,
    f(p[7]),
    f(p[8]),
    f(p[9]),
    0,
    0,
    0,
    0,
    1,
  }
  if d.dynamic then
    if d:touchesPosition() then
      d.baked = multiply(d.baked, m)
    end
    if d:touchesDirection() then
      d.bakedDirection = multiply(d.bakedDirection, linear(m))
    end
    return
  end
  d:applyMatrix(m)
end
EXEC[0x1A] = executeMtxMult3x3

local function executeMtxScale(d, p, offset)
  d:dynamicMatrixGuard(offset)
  local f = FixedPoint.fx32
  local m = { f(p[1]), 0, 0, 0, 0, f(p[2]), 0, 0, 0, 0, f(p[3]), 0, 0, 0, 0, 1 }
  if d.dynamic then
    if d:touchesPosition() then
      d.baked = multiply(d.baked, m)
    end
    if d:touchesDirection() then
      d.bakedDirection = multiply(d.bakedDirection, linear(m))
    end
    return
  end
  d:applyMatrix(m)
end
EXEC[0x1B] = executeMtxScale

local function executeMtxTranslate(d, p, offset)
  d:dynamicMatrixGuard(offset)
  local f = FixedPoint.fx32
  local m = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, f(p[1]), f(p[2]), f(p[3]), 1 }
  if d.dynamic then
    if d:touchesPosition() then
      d.baked = multiply(d.baked, m)
    end
    if d:touchesDirection() then
      d.bakedDirection = multiply(d.bakedDirection, linear(m))
    end
    return
  end
  d:applyMatrix(m)
end
EXEC[0x1C] = executeMtxTranslate

local function executeColor(d, p) -- COLOR (BGR555) -> literal vertex color
  d.colorR, d.colorG, d.colorB = FixedPoint.rgb555(p[1] % 0x8000)
  d.colorSource = COLOR_SOURCE.LITERAL
end
EXEC[0x20] = executeColor

local function executeNormal(d, p) -- NORMAL -> vertex color produced by lighting
  local nx, ny, nz = FixedPoint.normal10(p[1])
  d.normalX, d.normalY, d.normalZ = nx, ny, nz
  d.colorSource = COLOR_SOURCE.NORMAL_LIT
end
EXEC[0x21] = executeNormal

local function executeTexcoord(d, p) -- TEXCOORD (1.11.4 -> texel units)
  d.uvU = s16(p[1] % 0x10000) / 16
  d.uvV = s16(math.floor(p[1] / 0x10000) % 0x10000) / 16
end
EXEC[0x22] = executeTexcoord

local function executeVtx16(d, p) -- VTX_16 (fx16 1.3.12)
  d.posX = s16(p[1] % 0x10000) / 4096
  d.posY = s16(math.floor(p[1] / 0x10000) % 0x10000) / 4096
  d.posZ = s16(p[2] % 0x10000) / 4096
  d:emitVertex()
end
EXEC[0x23] = executeVtx16

local function executeVtx10(d, p) -- VTX_10 (10-bit, high bits of 1.3.12 -> /64)
  local w = p[1]
  d.posX = s10(w % 1024) / 64
  d.posY = s10(math.floor(w / 1024) % 1024) / 64
  d.posZ = s10(math.floor(w / 1048576) % 1024) / 64
  d:emitVertex()
end
EXEC[0x24] = executeVtx10

local function executeVtxXy(d, p) -- VTX_XY
  d.posX = s16(p[1] % 0x10000) / 4096
  d.posY = s16(math.floor(p[1] / 0x10000) % 0x10000) / 4096
  d:emitVertex()
end
EXEC[0x25] = executeVtxXy

local function executeVtxXz(d, p) -- VTX_XZ
  d.posX = s16(p[1] % 0x10000) / 4096
  d.posZ = s16(math.floor(p[1] / 0x10000) % 0x10000) / 4096
  d:emitVertex()
end
EXEC[0x26] = executeVtxXz

local function executeVtxYz(d, p) -- VTX_YZ
  d.posY = s16(p[1] % 0x10000) / 4096
  d.posZ = s16(math.floor(p[1] / 0x10000) % 0x10000) / 4096
  d:emitVertex()
end
EXEC[0x27] = executeVtxYz

local function executeVtxDiff(d, p) -- VTX_DIFF (10-bit signed low bits of 1.3.12)
  local w = p[1]
  d.posX = d.posX + s10(w % 1024) / 4096
  d.posY = d.posY + s10(math.floor(w / 1024) % 1024) / 4096
  d.posZ = d.posZ + s10(math.floor(w / 1048576) % 1024) / 4096
  d:emitVertex()
end
EXEC[0x28] = executeVtxDiff

local function executePolygonAttr(d, p)
  d.polygonAttr = p[1]
  d.polygonAttrs[p[1]] = true
end
EXEC[0x29] = executePolygonAttr

local function executeTeximageParam(d, p)
  d.texParam = p[1]
end
EXEC[0x2A] = executeTeximageParam

local function executePlttBase(d, p)
  d.paletteBase = p[1]
end
EXEC[0x2B] = executePlttBase

local function ignoreLightingCommand() end

EXEC[0x30] = ignoreLightingCommand
EXEC[0x31] = ignoreLightingCommand
EXEC[0x32] = ignoreLightingCommand
EXEC[0x33] = ignoreLightingCommand
EXEC[0x34] = ignoreLightingCommand

local function executeBeginVertices(d, p) -- BEGIN_VTXS
  d.primType = p[1] % 4
  d.runCount = 0
  d.runOpen = true
  d.runParity = 0
  d.runSplit = false
end
EXEC[0x40] = executeBeginVertices

local function unpackCommandWord(cmdWord)
  return {
    cmdWord % 256,
    math.floor(cmdWord / 256) % 256,
    math.floor(cmdWord / 65536) % 256,
    math.floor(cmdWord / 16777216) % 256,
  }
end

local function readCommandParameters(r, pos, count)
  local params = {}
  for k = 0, count - 1 do
    params[k + 1] = r:u32le(pos + k * 4)
  end
  return params
end

local function applyCommand(d, op, params, offset, context, lenientEnd, commandOffset)
  if op == 0x41 then
    -- A split run's trailing group is the other half of the straddling
    -- primitive already dropped and counted at the boundary, so it is
    -- dropped too rather than reported as malformed; an unsplit run keeps
    -- rejecting incomplete primitives.
    convertRun(d, commandOffset, lenientEnd)
    d.runCount, d.runOpen, d.primType, d.runSplit = 0, false, nil, false
    return
  end
  d.currentOffset = offset
  EXEC[op](d, params, offset, context)
end

function GxDisplayList.opcodeName(op)
  return OPCODE_NAMES[op]
end

GxDisplayList.COLOR_SOURCE = COLOR_SOURCE

local function scanCommandStream(r, len, options)
  local vertexCount = 0
  local dynamicBoundaryCount = 0
  local pos = 0
  while pos + 4 <= len do
    local cmdWord = r:u32le(pos)
    local cmdBytes = unpackCommandWord(cmdWord)
    local cmdOffset = pos
    pos = pos + 4
    for i = 1, 4 do
      local op = cmdBytes[i]
      local n = PARAM_WORDS[op]
      if n == nil then
        error(
          Errors.new(
            "GX_UNKNOWN_OPCODE",
            string.format("unknown geometry opcode 0x%02X at offset 0x%X", op, cmdOffset + i - 1),
            { opcode = op, offset = cmdOffset + i - 1, source = options.context }
          )
        )
      end
      if op ~= 0x00 then
        pos = pos + n * 4
      end
      if op >= 0x23 and op <= 0x28 then
        vertexCount = vertexCount + 1
      elseif options.dynamic and (op == 0x12 or op == 0x14) then
        -- A dynamic boundary can carry at most three trailing vertices.
        dynamicBoundaryCount = dynamicBoundaryCount + 1
      end
    end
  end
  return vertexCount, dynamicBoundaryCount
end

local function _decode(bytes, options)
  options = options or {}
  local r = BinaryReader.new(bytes, "gx-dl")
  local len = r:length()
  local vertexCount, dynamicBoundaryCount = scanCommandStream(r, len, options)
  local reserveVertices = vertexCount + dynamicBoundaryCount * 3
  local arena = assert(options.arena or GxGeometryBuffer.new())
  arena:reserve(reserveVertices, reserveVertices * 3)
  local d = newDecoder(arena, reserveVertices)
  d.requireColorSource = options.requireColorSource == true
  d.slice = arena:beginSlice()
  -- The SBC evaluator supplies position matrices only; their direction
  -- counterparts are the linear parts, derived on demand.
  if options.restoreStack then
    d.restoreStack = options.restoreStack
  end
  if options.matrix then
    d.matrix = options.matrix
    d.directionMatrix = linear(options.matrix)
  end
  -- Transform-preserving mode: the draw matrix is deferred to the segment
  -- sources; vertices decode in pre-draw space with only local ops baked.
  if options.dynamic then
    d.dynamic = true
    d.segments = {}
    d.currentSegment = newSegment(arena, DRAW_SOURCE)
    d.slice = nil
  end
  -- Seed the persistent color/normal/source state from the SBC draw's material
  -- (the geometry engine keeps this across a display-list call). Positions and
  -- matrices are not seeded: each shape decodes in model space as before.
  local seed = options.initialState
  if seed then
    if seed.color then
      d.colorR, d.colorG, d.colorB = seed.color[1], seed.color[2], seed.color[3]
    end
    if seed.normal then
      d.normalX, d.normalY, d.normalZ = seed.normal[1], seed.normal[2], seed.normal[3]
    end
    d.colorSource = seed.colorSource
  end
  local pos = 0
  local commands = {}

  while pos + 4 <= len do
    local cmdWord = r:u32le(pos)
    local cmdBytes = unpackCommandWord(cmdWord)
    local cmdOffset = pos
    pos = pos + 4
    for i = 1, 4 do
      local op = cmdBytes[i]
      local n = PARAM_WORDS[op]
      if n == nil then
        error(
          Errors.new(
            "GX_UNKNOWN_OPCODE",
            string.format("unknown geometry opcode 0x%02X at offset 0x%X", op, cmdOffset + i - 1),
            { opcode = op, offset = cmdOffset + i - 1, source = options.context }
          )
        )
      end
      if op ~= 0x00 then
        local params = readCommandParameters(r, pos, n)
        pos = pos + n * 4
        commands[#commands + 1] = { opcode = op, offset = cmdOffset + i - 1 }
        d.opcodeCounts[op] = (d.opcodeCounts[op] or 0) + 1
        applyCommand(d, op, params, cmdOffset + i - 1, options.context, d.runSplit, cmdOffset)
      end
    end
  end

  if d.runOpen then
    error(
      Errors.new(
        "GX_UNTERMINATED_PRIMITIVE",
        "display list ended inside a BEGIN_VTXS block",
        { source = options.context }
      )
    )
  end

  -- In the compile path every emitted vertex must carry a resolved color source;
  -- a nil source would otherwise render as an unintended default color.
  if options.requireColorSource then
    ---@param slice G4GxGeometrySlice
    local function check(slice)
      local attrib = arena.attrib
      for offset = 0, slice.vertexCount - 1 do
        if attrib[slice.vertexOffset + offset].colorSource == nil then
          error(
            Errors.new(
              "GX_UNRESOLVED_VERTEX_COLOR_SOURCE",
              string.format("vertex has no resolved color source (no COLOR/NORMAL and no material seed)"),
              { source = options.context }
            )
          )
        end
      end
    end
    if d.dynamic then
      for _, segment in ipairs(d.segments) do
        check(segment)
      end
      if arena.vertexCount > d.currentSegment.vertexOffset then
        finishSegment(d, d.currentSegment)
        check(d.currentSegment)
      end
    else
      local slice = assert(d.slice)
      finishSegment(d, slice)
      check(slice)
    end
  end

  if not d.dynamic then
    local slice = assert(d.slice)
    finishSegment(d, slice)
  end
  local bounds
  if not d.dynamic then
    local numeric = arena.numeric
    local slice = assert(d.slice)
    for offset = 0, slice.vertexCount - 1 do
      local v = numeric[slice.vertexOffset + offset]
      if not bounds then
        bounds = { min = { v.x, v.y, v.z }, max = { v.x, v.y, v.z } }
      else
        bounds.min[1] = math.min(bounds.min[1], v.x)
        bounds.max[1] = math.max(bounds.max[1], v.x)
        bounds.min[2] = math.min(bounds.min[2], v.y)
        bounds.max[2] = math.max(bounds.max[2], v.y)
        bounds.min[3] = math.min(bounds.min[3], v.z)
        bounds.max[3] = math.max(bounds.max[3], v.z)
      end
    end
  end

  local polygonAttrs = {}
  for word in pairs(d.polygonAttrs) do
    polygonAttrs[#polygonAttrs + 1] = word
  end
  table.sort(polygonAttrs)

  if d.dynamic then
    -- Finalize the last segment (an empty tail is dropped).
    if arena.vertexCount > d.currentSegment.vertexOffset then
      finishSegment(d, d.currentSegment)
      d.segments[#d.segments + 1] = d.currentSegment
    end
    return {
      segments = d.segments,
      bounds = nil, -- pre-draw-space bounds carry no scene meaning
      commands = commands,
      opcodeCounts = d.opcodeCounts,
      polygonAttrs = polygonAttrs,
      straddlingPrimitives = d.straddlingPrimitives,
      finalState = {
        color = { d.colorR, d.colorG, d.colorB },
        normal = { d.normalX, d.normalY, d.normalZ },
        colorSource = d.colorSource,
      },
    }
  end

  local slice = assert(d.slice)
  finishSegment(d, slice)
  return {
    slice = slice,
    bounds = bounds,
    commands = commands,
    opcodeCounts = d.opcodeCounts,
    polygonAttrs = polygonAttrs,
    finalState = {
      color = { d.colorR, d.colorG, d.colorB },
      normal = { d.normalX, d.normalY, d.normalZ },
      colorSource = d.colorSource,
    },
  }
end

function GxDisplayList.decode(bytes, options)
  local ok, result = pcall(_decode, bytes, options)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return GxDisplayList
