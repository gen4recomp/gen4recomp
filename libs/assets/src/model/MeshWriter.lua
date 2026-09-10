-- Encoder for the project's binary mesh batches: one indexed triangle list
-- for a single material/state group, kept compact so generated geometry is
-- not carried as huge Lua vertex tables. All values little-endian.
--
--   G4M2 — the static layout, used by the baked map/building path and the
--     dynamic (animated) segments alike: Nitro field batches are rigid
--     segments transformed by the pose program, so no vertex skinning
--     attributes exist:
--     header (24 bytes): G4M2 magic, u16 version(2), u16 flags, u32
--       vertexCount, u32 indexCount, u16 stride(40), u16 indexWidth(2|4),
--       u32 reserved(0)
--     vertices: f32 x,y,z,u,v,nx,ny,nz then u8 r,g,b,a, u8 colorSource,
--       u8 pad[3] (40 bytes each)
--     indices:  u16 (vertexCount <= 65535) or u32, zero-based
--
-- Pure domain module.

local Errors = require("libs.errors.src.Errors")
local BinaryWriter = require("libs.codec.src.BinaryWriter")
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

---@class MeshWriter.Batch
---@field vertices MeshWriter.Vertex[]|nil
---@field indices integer[]|nil
---@field arena MeshWriter.GeometryArena|nil
---@field vertexOffset integer|nil
---@field vertexCount integer|nil
---@field indexOffset integer|nil
---@field indexCount integer|nil

---@param batch MeshWriter.Batch
---@return string
function MeshWriter.encode(batch)
  local vertices, indices = batch.vertices, batch.indices
  local arena = batch.arena
  local vertexCount = vertices and #vertices or batch.vertexCount
  local indexCount = indices and #indices or batch.indexCount
  if not vertexCount or vertexCount == 0 or not indexCount or indexCount == 0 then
    Errors.raise("MESH_EMPTY", "mesh batch has no vertices or indices", {})
  end
  if indexCount % 3 ~= 0 then
    Errors.raise(
      "MESH_BAD_INDEX_COUNT",
      "index count " .. indexCount .. " is not a multiple of 3",
      { count = indexCount }
    )
  end
  local indexWidth = (vertexCount <= 65535) and G4MeshFormat.indexWidths[1] or G4MeshFormat.indexWidths[2]

  local w = BinaryWriter.new()
  w:bytes(G4MeshFormat.MAGIC)
    :u16(G4MeshFormat.VERSION)
    :u16(0)
    :u32(vertexCount)
    :u32(indexCount)
    :u16(G4MeshFormat.STRIDE)
    :u16(indexWidth)
    :u32(0)

  for offset = 0, vertexCount - 1 do
    local v
    local bytes
    if arena then
      v = arena.numeric[batch.vertexOffset + offset]
      bytes = arena.attrib[batch.vertexOffset + offset]
    else
      v = assert(vertices)[offset + 1]
    end
    local source = arena and bytes.colorSource or v.colorSource
    if source == nil or source < 0 or source > 2 then
      Errors.raise(
        "MESH_UNRESOLVED_COLOR_SOURCE",
        "vertex color source must be 0, 1, or 2, got " .. tostring(source),
        { vertex = offset + 1 }
      )
    end
    w:f32(v.x):f32(v.y):f32(v.z):f32(v.u):f32(v.v):f32(v.nx):f32(v.ny):f32(v.nz)
    if arena then
      w:u8(bytes.r):u8(bytes.g):u8(bytes.b):u8(bytes.a):u8(source):u8(0):u8(0):u8(0)
    else
      w:u8(v.r):u8(v.g):u8(v.b):u8(v.a):u8(source):u8(0):u8(0):u8(0)
    end
  end

  for offset = 0, indexCount - 1 do
    local i = arena and arena.indices[batch.indexOffset + offset] or assert(indices)[offset + 1]
    if indexWidth == 2 then
      w:u16(i)
    else
      w:u32(i)
    end
  end

  return w:tostring()
end

return MeshWriter
