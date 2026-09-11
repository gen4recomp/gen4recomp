-- Decoder for the project's binary mesh batches (see libs/assets/src/MeshWriter),
-- the inverse of that encoder. Splits cleanly: decode() is pure and validates a
-- batch into plain vertex/index arrays (usable under bare LuaJIT and testable
-- without love); build() turns a decoded batch into a persistent love Mesh and
-- is the only love-coupled entry point.
--
-- Vertices come out in the render vertex layout order (x,y,z, u,v, nx,ny,nz,
-- r,g,b,a, colorSource) with colors normalized to 0..1 and colorSource kept
-- as a raw 0/1/2 float. Indices stay zero-based as stored, and build()
-- rebases them to love's 1-based vertex map.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local BinaryReader = require("libs.codec.src.BinaryReader")
local G4MeshFormat = require("libs.assets.src.model.G4MeshFormat")
local VertexFormat = require("libs.assets.src.model.VertexFormat")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")
local ffi = require("ffi")

local SceneMesh = {}

local HEADER = G4MeshFormat.HEADER_SIZE -- magic, u16 ver, u16 flags, u32 vcount, u32 icount, u16 stride, u16 iwidth, u32 reserved
local MAGIC = G4MeshFormat.MAGIC
local VERSION = G4MeshFormat.VERSION
local STRIDE = G4MeshFormat.STRIDE

local function isFinite(n)
  return n == n and n ~= math.huge and n ~= -math.huge
end

-- Validate and unpack a G4M2 batch into { format, vertexCount, indexCount,
-- vertices, indices }. Raises a structured error on any malformed field. Pure.
function SceneMesh.decode(bytes, context)
  assert(type(bytes) == "string", "SceneMesh.decode requires a string")
  if #bytes < HEADER then
    Errors.raise(FieldErrors.MESH_TOO_SMALL, "mesh shorter than header", { size = #bytes, source = context })
  end
  local r = BinaryReader.new(bytes, "g4mesh")
  local magic = r:ascii(0, 4)
  if magic ~= MAGIC then
    Errors.raise(FieldErrors.MESH_BAD_MAGIC, "expected " .. MAGIC .. " magic, got " .. magic, { source = context })
  end
  local version = r:u16le(4)
  if version ~= VERSION then
    Errors.raise(FieldErrors.MESH_BAD_VERSION, "unsupported mesh version " .. version, { source = context })
  end
  local vertexCount = r:u32le(8)
  local indexCount = r:u32le(12)
  local stride = r:u16le(16)
  local indexWidth = r:u16le(18)
  if stride ~= STRIDE then
    Errors.raise(FieldErrors.MESH_BAD_STRIDE, "expected stride " .. STRIDE .. ", got " .. stride, { source = context })
  end
  if indexWidth ~= G4MeshFormat.indexWidths[1] and indexWidth ~= G4MeshFormat.indexWidths[2] then
    Errors.raise(
      FieldErrors.MESH_BAD_INDEX_WIDTH,
      "index width must be 2 or 4, got " .. indexWidth,
      { source = context }
    )
  end
  if indexCount % 3 ~= 0 then
    Errors.raise(
      FieldErrors.MESH_BAD_INDEX_COUNT,
      "index count not a multiple of 3: " .. indexCount,
      { source = context }
    )
  end

  local expected = HEADER + vertexCount * STRIDE + indexCount * indexWidth
  if expected ~= #bytes then
    Errors.raise(FieldErrors.MESH_BAD_LENGTH, "expected " .. expected .. " bytes, got " .. #bytes, { source = context })
  end

  local vertices = {}
  local off = HEADER
  for i = 1, vertexCount do
    local x, y, z = r:f32le(off), r:f32le(off + 4), r:f32le(off + 8)
    local u, v = r:f32le(off + 12), r:f32le(off + 16)
    local nx, ny, nz = r:f32le(off + 20), r:f32le(off + 24), r:f32le(off + 28)
    for _, n in ipairs({ x, y, z, u, v, nx, ny, nz }) do
      if not isFinite(n) then
        Errors.raise(FieldErrors.MESH_NONFINITE, "non-finite vertex component at vertex " .. i, { source = context })
      end
    end
    local red = r:u8(off + 32) / 255
    local green = r:u8(off + 33) / 255
    local blue = r:u8(off + 34) / 255
    local alpha = r:u8(off + 35) / 255
    local colorSource = r:u8(off + 36)
    if colorSource > 2 then
      Errors.raise(FieldErrors.MESH_BAD_COLOR_SOURCE, "color source out of range at vertex " .. i, { source = context })
    end
    vertices[i] = { x, y, z, u, v, nx, ny, nz, red, green, blue, alpha, colorSource }
    off = off + STRIDE
  end

  local indices = {}
  for i = 1, indexCount do
    local value = (indexWidth == 2) and r:u16le(off) or r:u32le(off)
    if value >= vertexCount then
      Errors.raise(
        FieldErrors.MESH_INDEX_OUT_OF_RANGE,
        "index " .. value .. " >= vertex count " .. vertexCount,
        { source = context }
      )
    end
    indices[i] = value
    off = off + indexWidth
  end

  return {
    format = "g4m2",
    vertexCount = vertexCount,
    indexCount = indexCount,
    indexWidth = indexWidth,
    vertices = vertices,
    indices = indices,
  }
end

-- Build a persistent, static love Mesh from a decoded batch. Rebases the
-- zero-based file indices to love's 1-based vertex map. love-coupled.
function SceneMesh.build(decoded)
  local mesh = love.graphics.newMesh(VertexFormat.LAYOUT, decoded.vertices, "triangles", "static")
  local map = {}
  for i = 1, decoded.indexCount do
    map[i] = decoded.indices[i] + 1
  end
  mesh:setVertexMap(map)
  return mesh
end

-- The packed float count of one render vertex, derived from the authoritative
-- vertex layout so a layout change fails loudly at the pack assertion below
-- instead of silently writing the wrong stride.
local function layoutComponents()
  local total = 0
  for _, attribute in ipairs(VertexFormat.LAYOUT) do
    total = total + attribute[3]
  end
  return total
end

---@class SceneMesh.PreparedMesh
---@field vertexData love.ByteData contiguous float upload buffer in VertexFormat.LAYOUT order
---@field indexData love.ByteData zero-based index upload buffer
---@field vertexCount integer
---@field indexCount integer
---@field indexType "uint16"|"uint32"
---@field centerX number
---@field centerY number
---@field centerZ number
---@field minX number
---@field maxX number
---@field minY number
---@field maxY number
---@field minZ number
---@field maxZ number

-- Decode a G4M2 batch and pack it into Data upload buffers without creating
-- any GPU object: vertices as contiguous floats in VertexFormat.LAYOUT order
-- and indices zero-based at the decoded 16/32-bit width, plus the same
-- model-space center/AABB the GPU pool caches per geometry path. Pure apart
-- from the Data allocation, so it runs on a worker thread.
---@param bytes string
---@param context unknown?
---@return SceneMesh.PreparedMesh
function SceneMesh.prepareUpload(bytes, context)
  local decoded = SceneMesh.decode(bytes, context)
  local components = layoutComponents()
  for index, vertex in ipairs(decoded.vertices) do
    assert(#vertex == components, "decoded vertex " .. index .. " does not match the render vertex layout")
  end
  local vertexData = love.data.newByteData(decoded.vertexCount * components * ffi.sizeof("float"))
  local floats = ffi.cast("float *", vertexData:getFFIPointer())
  for vertexIndex = 1, decoded.vertexCount do
    local vertex = decoded.vertices[vertexIndex]
    for component = 1, components do
      floats[(vertexIndex - 1) * components + (component - 1)] = vertex[component]
    end
  end
  local indexData = love.data.newByteData(decoded.indexCount * decoded.indexWidth)
  if decoded.indexWidth == 2 then
    local indices = ffi.cast("uint16_t *", indexData:getFFIPointer())
    for i = 1, decoded.indexCount do
      indices[i - 1] = decoded.indices[i]
    end
  else
    local indices = ffi.cast("uint32_t *", indexData:getFFIPointer())
    for i = 1, decoded.indexCount do
      indices[i - 1] = decoded.indices[i]
    end
  end
  local geometry = SceneDescriptor.meshGeometry(decoded.vertices)
  return {
    vertexData = vertexData,
    indexData = indexData,
    vertexCount = decoded.vertexCount,
    indexCount = decoded.indexCount,
    indexType = decoded.indexWidth == 2 and "uint16" or "uint32",
    centerX = geometry.center[1],
    centerY = geometry.center[2],
    centerZ = geometry.center[3],
    minX = geometry.bounds.minX,
    maxX = geometry.bounds.maxX,
    minY = geometry.bounds.minY,
    maxY = geometry.bounds.maxY,
    minZ = geometry.bounds.minZ,
    maxZ = geometry.bounds.maxZ,
  }
end

return SceneMesh
