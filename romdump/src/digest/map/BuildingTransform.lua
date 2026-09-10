-- Builds the runtime world transform for a placed building instance. The model's
-- own posScale is already folded into its compiled mesh (MeshCompiler via
-- MapUnits), so the mesh arrives in field-tile units, and the land record's
-- position is likewise in field tiles. The instance transform is therefore a
-- plain TRS in tile space: per-instance stretch (the record's scale w/h/l,
-- where 0x1000 encodes 1.0), then the encoded Z/Y/X rotations, then the tile
-- translation. Composed as translate * rotZ * rotY * rotX * scale, so a vertex
-- is stretched, rotated about the model origin, then placed. Pure domain module.
--
-- This deliberately does NOT use the field tool's raw-geometry factors
-- (modelScale/1024 and 256/modelScale): those position un-prescaled model
-- vertices, and applying them on top of the already-tile-scaled mesh collapsed
-- every building into a sub-tile pile at the origin.

local Matrix4 = require("libs.math.src.Matrix4")

local BuildingTransform = {}

-- placement: a BuildingPlacement record (position in tiles, scale where
-- 0x1000 == 1.0, rotation in radians).
function BuildingTransform.build(placement)
  local s = assert(placement.scale, "placement.scale is required")
  local p, r = placement.position, placement.rotation

  local result = Matrix4.translateInto(Matrix4.newBuffer(), p.x, p.y, p.z)
  local operand = Matrix4.newBuffer()
  local scratch = Matrix4.newBuffer()

  local function compose(fill)
    fill(operand)
    Matrix4.multiplyInto(scratch, result, operand)
    result, scratch = scratch, result
  end

  compose(function(out)
    Matrix4.rotateZInto(out, r.z)
  end)
  compose(function(out)
    Matrix4.rotateYInto(out, r.y)
  end)
  compose(function(out)
    Matrix4.rotateXInto(out, r.x)
  end)
  compose(function(out)
    Matrix4.scaleInto(out, s.width, s.height, s.length)
  end)
  return Matrix4.toArrayBuffer(result)
end

return BuildingTransform
