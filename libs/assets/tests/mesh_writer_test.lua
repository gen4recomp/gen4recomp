-- MeshWriter G4M2 encoding: header fields, vertex/index payload layout, color
-- source byte, index width selection, and rejection of empty / malformed batches.

local Assert = require("tests.support.Assert")
local BinaryReader = require("libs.codec.src.BinaryReader")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local Errors = require("libs.errors.src.Errors")
local ffi = require("ffi")

ffi.cdef([[
  typedef struct {
    double x, y, z;
    double u, v;
    double nx, ny, nz;
  } MeshTestNumeric;
  typedef struct {
    uint8_t r, g, b, a;
    uint8_t colorSource;
    uint8_t pad[3];
  } MeshTestAttrib;
]])

local T = {}

local function c04Slice(vertices, indices)
  local vertexOffset = 2
  local indexOffset = 3
  local numeric = ffi.new("MeshTestNumeric[?]", vertexOffset + #vertices)
  local attrib = ffi.new("MeshTestAttrib[?]", vertexOffset + #vertices)
  local arenaIndices = ffi.new("uint32_t[?]", indexOffset + #indices)
  for index, vertex in ipairs(vertices) do
    local numericVertex = numeric[vertexOffset + index - 1]
    numericVertex.x = vertex.x
    numericVertex.y = vertex.y
    numericVertex.z = vertex.z
    numericVertex.u = vertex.u
    numericVertex.v = vertex.v
    numericVertex.nx = vertex.nx
    numericVertex.ny = vertex.ny
    numericVertex.nz = vertex.nz

    local attribVertex = attrib[vertexOffset + index - 1]
    attribVertex.r = vertex.r
    attribVertex.g = vertex.g
    attribVertex.b = vertex.b
    attribVertex.a = vertex.a
    attribVertex.colorSource = vertex.colorSource
  end
  for index, value in ipairs(indices) do
    arenaIndices[indexOffset + index - 1] = value
  end
  return {
    arena = { numeric = numeric, attrib = attrib, indices = arenaIndices },
    vertexOffset = vertexOffset,
    vertexCount = #vertices,
    indexOffset = indexOffset,
    indexCount = #indices,
  }
end

local function legacyBatch(vertices, indices)
  return { vertices = vertices, indices = indices }
end

local function byteDataOf(ptr, length)
  return ffi.string(ptr, length)
end

local function triangle()
  local function v(x, y, z, source)
    return {
      x = x,
      y = y,
      z = z,
      u = 0,
      v = 0,
      nx = 0,
      ny = 1,
      nz = 0,
      r = 255,
      g = 128,
      b = 0,
      a = 255,
      colorSource = source or 0,
    }
  end
  return { vertices = { v(0, 0, 0, 0), v(1, 0, 0, 1), v(0, 0, 1, 2) }, indices = { 0, 1, 2 } }
end

local function raisesCode(code, fn, ...)
  local ok, err = pcall(fn, ...)
  Assert.isTrue(not ok, "expected " .. code .. " to be raised")
  if not Errors.is(err) then
    error("expected " .. code .. " to be raised")
  end
  if type(err) ~= "table" then
    error("expected " .. code .. " to be raised")
  end
  Assert.equal(tostring(rawget(err, "code")), code)
end

function T.header_fields()
  local s = MeshWriter.encode(triangle())
  local r = BinaryReader.new(s, "mesh")
  Assert.equal(r:bytes(0, 4), "G4M2")
  Assert.equal(r:u16le(4), 2) -- version
  Assert.equal(r:u16le(6), 0) -- flags
  Assert.equal(r:u32le(8), 3) -- vertex count
  Assert.equal(r:u32le(12), 3) -- index count
  Assert.equal(r:u16le(16), 40) -- stride
  Assert.equal(r:u16le(18), 2) -- index width
  Assert.equal(r:u32le(20), 0) -- reserved (0x14)
  Assert.equal(#s, 24 + 3 * 40 + 3 * 2)
end

function T.vertex_and_index_payload()
  local r = BinaryReader.new(MeshWriter.encode(triangle()), "mesh")
  local base = 24 -- header is 24 bytes (reserved u32 at 0x14 ends at 0x18)
  Assert.isTrue(math.abs(r:f32le(base) - 0) < 1e-9, "v0.x")
  local r2 = base + 40
  Assert.isTrue(math.abs(r:f32le(r2) - 1) < 1e-9, "v1.x")
  -- color bytes start after 8 f32 (32 bytes): r@+32, g@+33, colorSource@+36.
  Assert.equal(r:u8(base + 32), 255)
  Assert.equal(r:u8(base + 33), 128)
  Assert.equal(r:u8(base + 36), 0) -- v0 colorSource
  Assert.equal(r:u8(base + 40 + 36), 1) -- v1 colorSource
  local idxBase = 24 + 3 * 40
  Assert.equal(r:u16le(idxBase), 0)
  Assert.equal(r:u16le(idxBase + 2), 1)
  Assert.equal(r:u16le(idxBase + 4), 2)
end

function T.rejects_unresolved_color_source()
  local b = triangle()
  b.vertices[1].colorSource = nil
  raisesCode("MESH_UNRESOLVED_COLOR_SOURCE", MeshWriter.encode, b)
end

function T.rejects_empty_batch()
  raisesCode("MESH_EMPTY", MeshWriter.encode, { vertices = {}, indices = {} })
end

function T.rejects_non_triangle_index_count()
  local b = triangle()
  b.indices = { 0, 1 }
  raisesCode("MESH_BAD_INDEX_COUNT", MeshWriter.encode, b)
end

-- The dense geometry path consumes the C04 lanes directly. The old wrapper is the byte oracle
-- for the unchanged G4M2 contract, including float32 edge rounding.
function T.direct_encoding_matches_the_legacy_bytes()
  local vertices = {
    {
      x = -0.0,
      y = 1.5,
      z = 2 ^ -149,
      u = -3.6234375,
      v = 0 / 0,
      nx = math.huge,
      ny = 0.0,
      nz = -math.huge,
      r = 0,
      g = 128,
      b = 255,
      a = 7,
      colorSource = 0,
    },
    {
      x = -0.25,
      y = -math.huge,
      z = 0.0,
      u = 0.125,
      v = -0.0,
      nx = 1.0,
      ny = 0.5,
      nz = 0 / 0,
      r = 255,
      g = 1,
      b = 2,
      a = 3,
      colorSource = 1,
    },
    {
      x = 4.0,
      y = 5.0,
      z = 6.0,
      u = 7.0,
      v = 8.0,
      nx = 0.0,
      ny = 1.0,
      nz = 0.0,
      r = 10,
      g = 20,
      b = 30,
      a = 40,
      colorSource = 2,
    },
  }
  local indices = { 0, 1, 2 }
  local slice = c04Slice(vertices, indices)
  local expected = MeshWriter.encode(legacyBatch(vertices, indices))
  local size = MeshWriter.encodedSize(slice.vertexCount, slice.indexCount)
  Assert.equal(size, #expected, "encodedSize matches the legacy byte length")

  local output = ffi.new("uint8_t[?]", size)
  Assert.equal(MeshWriter.encodeInto(slice, output, size), size)
  Assert.equal(byteDataOf(output, size), expected, "direct C04 encoding is byte-identical")
end

function T.direct_encoding_uses_u32_indices_above_the_u16_threshold()
  local vertexCount = 65536
  local indexCount = 3
  local numeric = ffi.new("MeshTestNumeric[?]", vertexCount)
  local attrib = ffi.new("MeshTestAttrib[?]", vertexCount)
  local indices = ffi.new("uint32_t[?]", indexCount)
  indices[0], indices[1], indices[2] = 0, 65535, 2
  local slice = {
    arena = { numeric = numeric, attrib = attrib, indices = indices },
    vertexOffset = 0,
    vertexCount = vertexCount,
    indexOffset = 0,
    indexCount = indexCount,
  }
  local size = MeshWriter.encodedSize(vertexCount, indexCount)
  Assert.equal(size, 24 + vertexCount * 40 + indexCount * 4)
  local output = ffi.new("uint8_t[?]", size)
  Assert.equal(MeshWriter.encodeInto(slice, output, size), size)
  local reader = BinaryReader.new(byteDataOf(output, size), "direct-u32-mesh")
  Assert.equal(reader:u16le(18), 4, "vertex count selects the u32 index width")
  Assert.equal(reader:u32le(24 + vertexCount * 40 + 4), 65535)
end

function T.direct_encoding_requires_the_exact_output_size()
  local vertices = triangle().vertices
  local indices = { 0, 1, 2 }
  local slice = c04Slice(vertices, indices)
  local size = MeshWriter.encodedSize(slice.vertexCount, slice.indexCount)
  local output = ffi.new("uint8_t[?]", size)
  Assert.throws(function()
    MeshWriter.encodeInto(slice, output, size - 1)
  end, "direct encoding rejects an undersized output buffer")
  Assert.throws(function()
    MeshWriter.encodeInto(slice, output, size + 1)
  end, "direct encoding rejects an oversized output buffer")
end

return { tests = T }
