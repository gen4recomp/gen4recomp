-- Locks the FFI declaration order used by producer worker VMs.

local Assert = require("tests.support.Assert")
local ffi = require("ffi")

-- An earlier load may publish only the aliases before the geometry owner fills
-- in their layouts. The owner must complete these declarations before use.
ffi.cdef([[
  typedef struct G4GxVertexNumeric G4GxVertexNumeric;
  typedef struct G4GxVertexAttrib G4GxVertexAttrib;
]])

local T = {}

function T.predeclared_geometry_types_remain_allocatable()
  local GeometryBuffer = require("libs.nds.src.gx.GxGeometryBuffer")
  local arena = GeometryBuffer.new()
  Assert.equal(GeometryBuffer.vertexNumericSize, 64)
  Assert.equal(GeometryBuffer.vertexAttribSize, 8)
  Assert.notNil(arena.numeric)
  Assert.notNil(arena.attrib)
end

return { tests = T }
