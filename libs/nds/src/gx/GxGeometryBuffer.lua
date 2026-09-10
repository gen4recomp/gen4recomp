-- Owns transient, contiguous geometry storage used while compiling DS GX data.

local ffi = require("ffi")

local function hasCompleteType(name)
  local ok, size = pcall(ffi.sizeof, name)
  return ok and size ~= nil
end

if not hasCompleteType("G4GxVertexNumeric") or not hasCompleteType("G4GxVertexAttrib") then
  ffi.cdef([[
    typedef struct G4GxVertexNumeric {
      double x, y, z;
      double u, v;
      double nx, ny, nz;
    } G4GxVertexNumeric;

    typedef struct G4GxVertexAttrib {
      uint8_t r, g, b, a;
      uint8_t colorSource;
      uint8_t pad[3];
    } G4GxVertexAttrib;
  ]])
end

local GxGeometryBuffer = {}
GxGeometryBuffer.__index = GxGeometryBuffer

local UINT32_MAX = 0xFFFFFFFF
local INITIAL_VERTEX_CAPACITY = 256
local INITIAL_INDEX_CAPACITY = 768

local function finiteInteger(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value == math.floor(value)
end

local function nextPowerOfTwo(value)
  local capacity = 1
  while capacity < value do
    capacity = capacity * 2
  end
  return capacity
end

local function validateAmount(value, name)
  assert(finiteInteger(value) and value >= 0, name .. " must be a non-negative integer")
  assert(value <= UINT32_MAX, name .. " exceeds uint32_t capacity")
end

local function allocate(self, vertexCapacity, indexCapacity)
  local numeric = ffi.new("G4GxVertexNumeric[?]", vertexCapacity)
  local attrib = ffi.new("G4GxVertexAttrib[?]", vertexCapacity)
  local indices = ffi.new("uint32_t[?]", indexCapacity)
  if self.numeric ~= nil then
    ffi.copy(numeric, self.numeric, self.vertexCount * ffi.sizeof("G4GxVertexNumeric"))
    ffi.copy(attrib, self.attrib, self.vertexCount * ffi.sizeof("G4GxVertexAttrib"))
    ffi.copy(indices, self.indices, self.indexCount * ffi.sizeof("uint32_t"))
  end
  self.numeric = numeric
  self.attrib = attrib
  self.indices = indices
  self.vertexCapacity = vertexCapacity
  self.indexCapacity = indexCapacity
end

---@class G4GxGeometrySlice
---@field arena GxGeometryBuffer
---@field vertexOffset integer
---@field vertexCount integer
---@field indexOffset integer
---@field indexCount integer

---@class GxGeometryBuffer
---@field numeric ffi.cdata*
---@field attrib ffi.cdata*
---@field indices ffi.cdata*
---@field vertexCount integer
---@field vertexCapacity integer
---@field indexCount integer
---@field indexCapacity integer
---@field reserve fun(self: GxGeometryBuffer, addVertices: integer, addIndices: integer)
---@field beginSlice fun(self: GxGeometryBuffer): G4GxGeometrySlice
---@field finishSlice fun(self: GxGeometryBuffer, slice: G4GxGeometrySlice): G4GxGeometrySlice
---@field reset fun(self: GxGeometryBuffer)

---@return GxGeometryBuffer
function GxGeometryBuffer.new()
  local self = setmetatable({
    numeric = ffi.new("G4GxVertexNumeric[?]", INITIAL_VERTEX_CAPACITY),
    attrib = ffi.new("G4GxVertexAttrib[?]", INITIAL_VERTEX_CAPACITY),
    indices = ffi.new("uint32_t[?]", INITIAL_INDEX_CAPACITY),
    vertexCount = 0,
    vertexCapacity = INITIAL_VERTEX_CAPACITY,
    indexCount = 0,
    indexCapacity = INITIAL_INDEX_CAPACITY,
  }, GxGeometryBuffer)
  ---@cast self GxGeometryBuffer
  return self
end

---@param addVertices integer
---@param addIndices integer
function GxGeometryBuffer:reserve(addVertices, addIndices)
  validateAmount(addVertices, "addVertices")
  validateAmount(addIndices, "addIndices")
  local requiredVertices = self.vertexCount + addVertices
  local requiredIndices = self.indexCount + addIndices
  assert(requiredVertices <= UINT32_MAX, "geometry vertex count exceeds uint32_t capacity")
  assert(requiredIndices <= UINT32_MAX, "geometry index count exceeds uint32_t capacity")

  local vertexCapacity = self.vertexCapacity
  local indexCapacity = self.indexCapacity
  if requiredVertices > vertexCapacity then
    vertexCapacity = nextPowerOfTwo(requiredVertices)
  end
  if requiredIndices > indexCapacity then
    indexCapacity = nextPowerOfTwo(requiredIndices)
  end
  if vertexCapacity ~= self.vertexCapacity or indexCapacity ~= self.indexCapacity then
    allocate(self, vertexCapacity, indexCapacity)
  end
end

---@return G4GxGeometrySlice
function GxGeometryBuffer:beginSlice()
  local slice = {
    arena = self,
    vertexOffset = self.vertexCount,
    vertexCount = 0,
    indexOffset = self.indexCount,
    indexCount = 0,
  }
  ---@cast slice G4GxGeometrySlice
  return slice
end

---@param slice G4GxGeometrySlice
---@return G4GxGeometrySlice
function GxGeometryBuffer:finishSlice(slice)
  assert(slice.arena == self, "geometry slice belongs to a different arena")
  assert(slice.vertexOffset <= self.vertexCount, "geometry slice vertex offset is past the arena")
  assert(slice.indexOffset <= self.indexCount, "geometry slice index offset is past the arena")
  slice.vertexCount = self.vertexCount - slice.vertexOffset
  slice.indexCount = self.indexCount - slice.indexOffset
  return slice
end

function GxGeometryBuffer:reset()
  self.vertexCount = 0
  self.indexCount = 0
end

GxGeometryBuffer.INITIAL_VERTEX_CAPACITY = INITIAL_VERTEX_CAPACITY
GxGeometryBuffer.INITIAL_INDEX_CAPACITY = INITIAL_INDEX_CAPACITY
GxGeometryBuffer.vertexNumericSize = ffi.sizeof("G4GxVertexNumeric")
GxGeometryBuffer.vertexAttribSize = ffi.sizeof("G4GxVertexAttrib")

assert(GxGeometryBuffer.vertexNumericSize == 64, "G4GxVertexNumeric must remain 64 bytes")
assert(GxGeometryBuffer.vertexAttribSize == 8, "G4GxVertexAttrib must remain 8 bytes")

return GxGeometryBuffer
