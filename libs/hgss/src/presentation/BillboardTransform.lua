-- Describes the camera-independent placement data of a billboard draw and
-- rebuilds the model matrix against the live camera. A BB shape cannot be
-- baked at compile time, so MapAssetCompiler ships
-- its geometry in billboard-local space plus the position matrix the SBC command
-- captured (`baseTransform`).
--
-- NitroSystem g3d/src/sbc.c NNSi_G3dFuncSbc_BB reads the matrix in force, then
-- loads the position matrix with the translation of that matrix expressed in view
-- space and scales it by the magnitude of each of its three basis vectors. The
-- captured rotation is discarded, and no lookAt is involved: in view space the
-- billboard's orientation is simply the identity. Undoing the view rotation gives
-- the world-space equivalent
--
--   translate(base translation) * inverse(view rotation) * scale(base scale)
--
-- Non-uniform base scale therefore stretches along camera axes, exactly as the DS
-- MTX_SCALE that follows the load does. Pure domain module: no love dependency.

local BillboardTransform = {}

local function columnMagnitude(m, col)
  local a, b, c = m[col * 4 + 1], m[col * 4 + 2], m[col * 4 + 3]
  return math.sqrt(a * a + b * b + c * c)
end

-- Extract the camera-independent data the renderer needs for an ordinary full
-- billboard into existing 3-number tables: the same translation and
-- basis-column magnitudes as components, reusing the outputs.
---@param centerOut number[] -- 3-number output, overwritten with the base translation
---@param scaleOut number[] -- 3-number output, overwritten with the per-axis scale
---@param base number[] -- 16-element column-major base matrix
---@return number[] center, number[] scale -- the same `centerOut`/`scaleOut` tables
function BillboardTransform.componentsInto(centerOut, scaleOut, base)
  assert(#base == 16, "billboard base needs a 4x4 matrix")
  assert(type(centerOut) == "table" and #centerOut == 3, "billboard center needs a 3-number output")
  assert(type(scaleOut) == "table" and #scaleOut == 3, "billboard scale needs a 3-number output")
  scaleOut[1] = columnMagnitude(base, 0)
  scaleOut[2] = columnMagnitude(base, 1)
  scaleOut[3] = columnMagnitude(base, 2)
  assert(scaleOut[1] > 0 and scaleOut[2] > 0 and scaleOut[3] > 0, "billboard scale must be non-zero")
  centerOut[1], centerOut[2], centerOut[3] = base[13], base[14], base[15]
  return centerOut, scaleOut
end

-- Extract the camera-independent data the renderer needs for an ordinary full
-- billboard. The base rotation is deliberately discarded by Nitro BB semantics;
-- only its translation and basis-column magnitudes survive.
---@param base number[]
---@return number[] center
---@return number[] scale
function BillboardTransform.components(base)
  return BillboardTransform.componentsInto({ 0, 0, 0 }, { 0, 0, 0 }, base)
end

-- `base` and `viewMatrix` are 16-element column-major matrices; the view matrix's
-- linear part must be a rotation, which is true of every field camera, so its
-- inverse is its transpose. Returns the resolved 4x4 model matrix and its 3x3
-- inverse-transpose model linear transform.
function BillboardTransform.resolve(base, viewMatrix)
  assert(#base == 16 and #viewMatrix == 16, "resolve needs two 4x4 matrices")
  local center, scale = BillboardTransform.components(base)
  local sx, sy, sz = scale[1], scale[2], scale[3]

  -- transpose(view rotation) scaled per column, then the base translation. Column
  -- j of the rotation transpose is row j of the rotation, i.e. viewMatrix[j+1],
  -- viewMatrix[j+5], viewMatrix[j+9].
  local model = {
    viewMatrix[1] * sx,
    viewMatrix[5] * sx,
    viewMatrix[9] * sx,
    0,
    viewMatrix[2] * sy,
    viewMatrix[6] * sy,
    viewMatrix[10] * sy,
    0,
    viewMatrix[3] * sz,
    viewMatrix[7] * sz,
    viewMatrix[11] * sz,
    0,
    center[1],
    center[2],
    center[3],
    1,
  }
  local modelNormal = {
    viewMatrix[1] / sx,
    viewMatrix[5] / sx,
    viewMatrix[9] / sx,
    viewMatrix[2] / sy,
    viewMatrix[6] / sy,
    viewMatrix[10] / sy,
    viewMatrix[3] / sz,
    viewMatrix[7] / sz,
    viewMatrix[11] / sz,
  }
  return model, modelNormal
end

return BillboardTransform
