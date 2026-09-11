-- SceneMesh.decode is the inverse of MeshWriter.encode: round-trip a known
-- batch and confirm every field survives, then exercise each validation guard.

local Assert = require("tests.support.Assert")
local ffi = require("ffi")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local SceneMesh = require("libs.hgss.src.presentation.SceneMesh")
local VertexFormat = require("libs.assets.src.model.VertexFormat")

-- The prepared vertex float count is derived from VertexFormat.LAYOUT (never
-- hand-copied), so a future layout change fails this test loudly instead of
-- silently packing the wrong stride.
local function componentsPerVertex()
  local total = 0
  for _, attribute in ipairs(VertexFormat.LAYOUT) do
    total = total + attribute[3]
  end
  return total
end

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected error " .. code)
  Assert.equal(type(err) == "table" and err.code or err, code)
end

-- Two triangles (a quad), colors chosen so /255 round-trips exactly.
local function sampleBatch()
  local vertices = {}
  for i = 0, 3 do
    vertices[i + 1] = {
      x = i,
      y = i * 2,
      z = -i,
      u = 0.5,
      v = 0.25,
      nx = 0,
      ny = 1,
      nz = 0,
      r = 255,
      g = 0,
      b = 128,
      a = 255,
      colorSource = i % 3,
    }
  end
  return { vertices = vertices, indices = { 0, 1, 2, 0, 2, 3 } }
end

-- Probe shape for the negative GPU-object assertions below: prepareUpload
-- returns the packed upload buffers only, so the love handles must be absent.
---@class SceneMeshPreparedProbe : SceneMesh.PreparedMesh
---@field mesh unknown?
---@field image unknown?

return {
  tests = {
    ["round-trips a batch through encode/decode"] = function()
      local decoded = SceneMesh.decode(MeshWriter.encode(sampleBatch()))
      Assert.equal(decoded.vertexCount, 4)
      Assert.equal(decoded.indexCount, 6)
      Assert.equal(decoded.indexWidth, 2)
      Assert.deepEqual(decoded.indices, { 0, 1, 2, 0, 2, 3 })
      local v = decoded.vertices[2]
      Assert.equal(v[1], 1) -- x
      Assert.equal(v[2], 2) -- y
      Assert.equal(v[3], -1) -- z
      Assert.equal(v[4], 0.5) -- u
      Assert.equal(v[6], 0) -- nx
      Assert.equal(v[7], 1) -- ny
      Assert.equal(v[9], 1) -- r 255/255
      Assert.equal(v[11], 128 / 255) -- b
      Assert.equal(v[12], 1) -- a
      Assert.equal(v[13], 1) -- colorSource (vertex 2 -> i=1)
    end,

    ["rejects a bad magic"] = function()
      local bytes = MeshWriter.encode(sampleBatch())
      throwsCode("MESH_BAD_MAGIC", function()
        SceneMesh.decode("XXXX" .. bytes:sub(5))
      end)
    end,

    ["rejects a truncated file"] = function()
      local bytes = MeshWriter.encode(sampleBatch())
      throwsCode("MESH_BAD_LENGTH", function()
        SceneMesh.decode(bytes:sub(1, #bytes - 4))
      end)
    end,

    ["rejects trailing bytes"] = function()
      throwsCode("MESH_BAD_LENGTH", function()
        SceneMesh.decode(MeshWriter.encode(sampleBatch()) .. "\0\0\0\0")
      end)
    end,

    ["rejects a header-only truncation"] = function()
      throwsCode("MESH_TOO_SMALL", function()
        SceneMesh.decode("G4M2")
      end)
    end,

    ["rejects a G4M1 file as a stale version"] = function()
      local bytes = MeshWriter.encode(sampleBatch())
      throwsCode("MESH_BAD_MAGIC", function()
        SceneMesh.decode("G4M1" .. bytes:sub(5))
      end)
    end,

    ["rejects a G4M3 file as an unknown magic"] = function()
      local bytes = MeshWriter.encode(sampleBatch())
      throwsCode("MESH_BAD_MAGIC", function()
        SceneMesh.decode("G4M3" .. bytes:sub(5))
      end)
    end,

    ["prepareUpload packs the same vertices/indices/geometry as decode, without a GPU object"] = function()
      local bytes = MeshWriter.encode(sampleBatch())
      local decoded = SceneMesh.decode(bytes)
      local prepared = SceneMesh.prepareUpload(bytes)
      ---@cast prepared SceneMeshPreparedProbe

      Assert.equal(prepared.vertexCount, decoded.vertexCount)
      Assert.equal(prepared.indexCount, decoded.indexCount)
      Assert.equal(prepared.indexType, "uint16", "a 2-byte decoded index width packs as uint16")
      Assert.isNil(prepared.mesh, "prepareUpload never creates a love Mesh")
      Assert.isNil(prepared.image, "prepareUpload never creates a love Image")

      local components = componentsPerVertex()
      Assert.equal(prepared.vertexData:getSize(), decoded.vertexCount * components * ffi.sizeof("float"))
      local floats = ffi.cast("float *", prepared.vertexData:getFFIPointer())
      for vertexIndex = 1, decoded.vertexCount do
        local vertex = decoded.vertices[vertexIndex]
        for component = 1, components do
          Assert.near(
            floats[(vertexIndex - 1) * components + (component - 1)],
            vertex[component],
            1e-6,
            "packed component " .. component .. " of vertex " .. vertexIndex .. " matches decode"
          )
        end
      end

      Assert.equal(prepared.indexData:getSize(), decoded.indexCount * 2)
      local indices = ffi.cast("uint16_t *", prepared.indexData:getFFIPointer())
      for i = 1, decoded.indexCount do
        Assert.equal(indices[i - 1], decoded.indices[i], "packed index " .. i .. " stays zero-based like decode")
      end

      Assert.deepEqual(
        { prepared.centerX, prepared.centerY, prepared.centerZ },
        { 1.5, 3, -1.5 },
        "prepared center matches the geometry fold over decode's vertices"
      )
      Assert.equal(prepared.minX, 0)
      Assert.equal(prepared.maxX, 3)
      Assert.equal(prepared.minY, 0)
      Assert.equal(prepared.maxY, 6)
      Assert.equal(prepared.minZ, -3)
      Assert.equal(prepared.maxZ, 0)
    end,

    ["prepareUpload packs a 32-bit index width as uint32"] = function()
      local vertices = {}
      -- A vertex count above the 16-bit index encoder ceiling forces
      -- MeshWriter to emit 4-byte indices.
      for i = 0, 70000 do
        vertices[i + 1] = {
          x = 0,
          y = 0,
          z = 0,
          u = 0,
          v = 0,
          nx = 0,
          ny = 1,
          nz = 0,
          r = 0,
          g = 0,
          b = 0,
          a = 0,
          colorSource = 0,
        }
      end
      local bytes = MeshWriter.encode({ vertices = vertices, indices = { 0, 70000, 1 } })
      local decoded = SceneMesh.decode(bytes)
      Assert.equal(decoded.indexWidth, 4, "the fixture forces a 32-bit index width")
      local prepared = SceneMesh.prepareUpload(bytes)
      Assert.equal(prepared.indexType, "uint32")
      Assert.equal(prepared.indexData:getSize(), decoded.indexCount * 4)
      local indices = ffi.cast("uint32_t *", prepared.indexData:getFFIPointer())
      for i = 1, decoded.indexCount do
        Assert.equal(indices[i - 1], decoded.indices[i])
      end
    end,

    ["prepareUpload rejects the same malformed input decode rejects"] = function()
      local bytes = MeshWriter.encode(sampleBatch())
      throwsCode("MESH_BAD_MAGIC", function()
        SceneMesh.prepareUpload("XXXX" .. bytes:sub(5))
      end)
    end,
  },
}
