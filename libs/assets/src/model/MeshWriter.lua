-- Direct encoder for the project's little-endian G4M2 indexed triangle format.

local ffi = require("ffi")
local Errors = require("libs.errors.src.Errors")
local Float32 = require("libs.codec.src.Float32")
local G4MeshFormat = require("libs.assets.src.model.G4MeshFormat")

local MeshWriter = {}

---@class MeshWriter.Vertex
---@field x number
---@field y number
---@field z number
---@field u number
---@field v number
---@field nx number
---@field ny number
---@field nz number
---@field r integer
---@field g integer
---@field b integer
---@field a integer
---@field colorSource integer

---@class MeshWriter.GeometryArena
---@field numeric ffi.cdata*
---@field attrib ffi.cdata*
---@field indices ffi.cdata*
---@field vertexCapacity integer|nil
---@field indexCapacity integer|nil

---@class MeshWriter.Batch
---@field vertices MeshWriter.Vertex[]|nil
---@field indices integer[]|nil
---@field arena MeshWriter.GeometryArena|nil
---@field vertexOffset integer|nil
---@field vertexCount integer|nil
---@field indexOffset integer|nil
---@field indexCount integer|nil

local function unsigned(value, bits, name)
  local max = 2 ^ bits - 1
  if type(value) ~= "number" or value ~= math.floor(value) or value < 0 or value > max then
    Errors.raise(
      "WRITE_OUT_OF_RANGE",
      string.format("%s value must be an integer in 0..%d, got %s", name, max, tostring(value)),
      { value = value }
    )
  end
  return value
end

---@param batch MeshWriter.Batch
---@return integer, integer
local function counts(batch)
  local vertexCount = batch.vertexCount or (batch.vertices and #batch.vertices)
  local indexCount = batch.indexCount or (batch.indices and #batch.indices)
  if not vertexCount or vertexCount == 0 or not indexCount or indexCount == 0 then
    Errors.raise("MESH_EMPTY", "mesh batch has no vertices or indices", {})
  end
  vertexCount = assert(vertexCount)
  indexCount = assert(indexCount)
  unsigned(vertexCount, 32, "vertex count")
  unsigned(indexCount, 32, "index count")
  if indexCount % 3 ~= 0 then
    Errors.raise(
      "MESH_BAD_INDEX_COUNT",
      "index count " .. indexCount .. " is not a multiple of 3",
      { count = indexCount }
    )
  end
  return vertexCount, indexCount
end

---@param vertexCount integer
---@param indexCount integer
---@return integer
function MeshWriter.encodedSize(vertexCount, indexCount)
  unsigned(vertexCount, 32, "vertex count")
  unsigned(indexCount, 32, "index count")
  local indexWidth = vertexCount <= 65535 and G4MeshFormat.indexWidths[1] or G4MeshFormat.indexWidths[2]
  return G4MeshFormat.HEADER_SIZE + vertexCount * G4MeshFormat.STRIDE + indexCount * indexWidth
end

local function writeU16LE(ptr, offset, value)
  ptr[offset] = value % 256
  ptr[offset + 1] = math.floor(value / 256)
end

local function writeU32LE(ptr, offset, value)
  ptr[offset] = value % 256
  ptr[offset + 1] = math.floor(value / 256) % 256
  ptr[offset + 2] = math.floor(value / 65536) % 256
  ptr[offset + 3] = math.floor(value / 16777216)
end

local function writeF32LE(ptr, offset, value)
  writeU32LE(ptr, offset, Float32.bits(value))
end

local function writeHeader(ptr, vertexCount, indexCount, indexWidth)
  ptr[0], ptr[1], ptr[2], ptr[3] = string.byte(G4MeshFormat.MAGIC, 1, 4)
  writeU16LE(ptr, 4, G4MeshFormat.VERSION)
  writeU16LE(ptr, 6, 0)
  writeU32LE(ptr, 8, vertexCount)
  writeU32LE(ptr, 12, indexCount)
  writeU16LE(ptr, 16, G4MeshFormat.STRIDE)
  writeU16LE(ptr, 18, indexWidth)
  writeU32LE(ptr, 20, 0)
end

local function vertexAt(batch, offset)
  if batch.arena then
    local vertexOffset = assert(batch.vertexOffset)
    local arena = assert(batch.arena)
    return assert(arena.numeric)[vertexOffset + offset], assert(arena.attrib)[vertexOffset + offset]
  end
  return assert(batch.vertices)[offset + 1], nil
end

local function indexAt(batch, offset)
  if batch.arena then
    return assert(batch.arena.indices)[assert(batch.indexOffset) + offset]
  end
  return assert(batch.indices)[offset + 1]
end

local function validateSlice(batch, vertexCount, indexCount)
  if batch.arena then
    local vertexOffset = assert(batch.vertexOffset)
    local indexOffset = assert(batch.indexOffset)
    local arena = assert(batch.arena)
    assert(vertexOffset >= 0, "mesh vertex offset is required")
    assert(indexOffset >= 0, "mesh index offset is required")
    assert(arena.numeric and arena.attrib and arena.indices, "mesh arena is incomplete")
    if arena.vertexCapacity ~= nil then
      assert(vertexOffset + vertexCount <= arena.vertexCapacity, "mesh vertex slice exceeds arena")
    end
    if arena.indexCapacity ~= nil then
      assert(indexOffset + indexCount <= arena.indexCapacity, "mesh index slice exceeds arena")
    end
  end
end

---@param batch MeshWriter.Batch
---@param outPtr ffi.cdata*
---@param outLength integer
---@return integer
function MeshWriter.encodeInto(batch, outPtr, outLength)
  assert(type(batch) == "table", "mesh batch is required")
  local vertexCount, indexCount = counts(batch)
  local size = MeshWriter.encodedSize(vertexCount, indexCount)
  assert(outPtr ~= nil, "mesh output pointer is required")
  assert(outLength == size, "mesh output length must equal encoded size")
  validateSlice(batch, vertexCount, indexCount)
  local ptr = ffi.cast("uint8_t *", outPtr)
  local indexWidth = vertexCount <= 65535 and G4MeshFormat.indexWidths[1] or G4MeshFormat.indexWidths[2]
  writeHeader(ptr, vertexCount, indexCount, indexWidth)

  local outputOffset = G4MeshFormat.HEADER_SIZE
  for offset = 0, vertexCount - 1 do
    local numeric, attrib = vertexAt(batch, offset)
    local x, y, z = numeric.x, numeric.y, numeric.z
    local u, v = numeric.u, numeric.v
    local nx, ny, nz = numeric.nx, numeric.ny, numeric.nz
    writeF32LE(ptr, outputOffset, x)
    writeF32LE(ptr, outputOffset + 4, y)
    writeF32LE(ptr, outputOffset + 8, z)
    writeF32LE(ptr, outputOffset + 12, u)
    writeF32LE(ptr, outputOffset + 16, v)
    writeF32LE(ptr, outputOffset + 20, nx)
    writeF32LE(ptr, outputOffset + 24, ny)
    writeF32LE(ptr, outputOffset + 28, nz)
    local red, green, blue, alpha, source
    if attrib then
      red, green, blue, alpha, source = attrib.r, attrib.g, attrib.b, attrib.a, attrib.colorSource
    else
      red, green, blue, alpha, source = numeric.r, numeric.g, numeric.b, numeric.a, numeric.colorSource
    end
    if type(source) ~= "number" or source ~= math.floor(source) or source < 0 or source > 2 then
      Errors.raise(
        "MESH_UNRESOLVED_COLOR_SOURCE",
        "vertex color source must be 0, 1, or 2, got " .. tostring(source),
        { vertex = offset + 1 }
      )
    end
    ptr[outputOffset + 32] = unsigned(red, 8, "r")
    ptr[outputOffset + 33] = unsigned(green, 8, "g")
    ptr[outputOffset + 34] = unsigned(blue, 8, "b")
    ptr[outputOffset + 35] = unsigned(alpha, 8, "a")
    ptr[outputOffset + 36] = source
    ptr[outputOffset + 37], ptr[outputOffset + 38], ptr[outputOffset + 39] = 0, 0, 0
    outputOffset = outputOffset + G4MeshFormat.STRIDE
  end

  for offset = 0, indexCount - 1 do
    local index = unsigned(indexAt(batch, offset), indexWidth * 8, "index")
    if indexWidth == 2 then
      writeU16LE(ptr, outputOffset, index)
    else
      writeU32LE(ptr, outputOffset, index)
    end
    outputOffset = outputOffset + indexWidth
  end
  assert(outputOffset == size, "mesh encoder wrote an unexpected size")
  return outputOffset
end

---@param batch MeshWriter.Batch
---@return string
function MeshWriter.encode(batch)
  local vertexCount, indexCount = counts(batch)
  local size = MeshWriter.encodedSize(vertexCount, indexCount)
  local output = ffi.new("uint8_t[?]", size)
  assert(MeshWriter.encodeInto(batch, output, size) == size)
  return ffi.string(output, size)
end

return MeshWriter
