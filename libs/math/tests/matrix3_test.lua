-- Tests for Matrix3: extraction, multiplication, inverse-transpose normal
-- matrix under rotation and nonuniform scale, vector transformation, and
-- rejection of singular transforms.

local Assert = require("tests.support.Assert")
local Matrix3 = require("libs.math.src.Matrix3")
local Matrix4 = require("libs.math.src.Matrix4")

local T = {}

---@param a number
---@param b number
---@return boolean
local function approx(a, b)
  return math.abs(a - b) < 1e-9
end
---@param a number[]
---@param b number[]
---@return boolean
local function approxVec(a, b)
  return approx(a[1], b[1]) and approx(a[2], b[2]) and approx(a[3], b[3])
end

local function assertModelNormalEquivalent(model, label)
  local view = Matrix4.multiply(Matrix4.rotateX(0.37), Matrix4.rotateY(-0.61))
  local x, y, z = 0.31, -0.47, 0.82
  local legacyX, legacyY, legacyZ = Matrix3.transform(Matrix3.normalMatrix(model, view), x, y, z)
  local modelX, modelY, modelZ = Matrix3.transform(Matrix3.modelNormal(model), x, y, z)
  local actualX, actualY, actualZ = Matrix3.transform(Matrix3.from4x4(view), modelX, modelY, modelZ)
  Assert.isTrue(
    approxVec({ actualX, actualY, actualZ }, { legacyX, legacyY, legacyZ }),
    label .. " model normal must compose numerically with the view rotation"
  )
end

function T.extracts_upper_3x3()
  local m4 = Matrix4.scale(2, 3, 4)
  local m3 = Matrix3.from4x4(m4)
  Assert.deepEqual(m3, { 2, 0, 0, 0, 3, 0, 0, 0, 4 })
end

function T.identity_is_neutral()
  local x, y, z = Matrix3.transform(Matrix3.identity(), 5, 6, 7)
  Assert.isTrue(approx(x, 5) and approx(y, 6) and approx(z, 7))
end

function T.transpose_swaps_rows_and_columns()
  local m = { 1, 2, 3, 4, 5, 6, 7, 8, 9 }
  Assert.deepEqual(Matrix3.transpose(m), { 1, 4, 7, 2, 5, 8, 3, 6, 9 })
end

function T.rotation_normal_matrix_is_transpose()
  -- For pure rotation the inverse is the transpose, so inverse-transpose is the
  -- original rotation matrix.
  local model = Matrix4.rotateY(math.pi / 4)
  local view = Matrix4.identity()
  local n = Matrix3.normalMatrix(model, view)
  local expected = Matrix3.from4x4(model)
  Assert.isTrue(approxVec({ n[1], n[2], n[3] }, { expected[1], expected[2], expected[3] }))
  Assert.isTrue(approxVec({ n[4], n[5], n[6] }, { expected[4], expected[5], expected[6] }))
  Assert.isTrue(approxVec({ n[7], n[8], n[9] }, { expected[7], expected[8], expected[9] }))
end

function T.nonuniform_scale_cancels_with_inverse_transpose()
  -- Scale (2,3,4) followed by its normal matrix should leave a normal unchanged.
  local model = Matrix4.scale(2, 3, 4)
  local view = Matrix4.identity()
  local n = Matrix3.normalMatrix(model, view)
  local tx, ty, tz = Matrix3.transform(n, 1, 1, 1)
  -- The normal matrix for this diagonal scale is diag(1/2, 1/3, 1/4) transposed,
  -- which is the same diagonal matrix.
  Assert.isTrue(approx(tx, 0.5) and approx(ty, 1 / 3) and approx(tz, 0.25))
end

function T.singular_normal_matrix_fails()
  -- A singular model-view transform has no inverse, so no normal matrix
  -- exists. It must fail loudly rather than silently degrade to identity.
  local zeroScale = Matrix4.scale(0, 1, 1)
  Assert.throws(function()
    Matrix3.normalMatrix(zeroScale, Matrix4.identity())
  end)
end

function T.singular_view_matrix_fails()
  -- Singularity in the view (camera) side must fail the same way.
  local singularView = Matrix4.scale(1, 0, 1)
  Assert.throws(function()
    Matrix3.normalMatrix(Matrix4.identity(), singularView)
  end)
end

function T.composes_view_and_model()
  -- view * model: rotate model then view. The normal matrix tracks both.
  local model = Matrix4.rotateZ(math.pi / 2)
  local view = Matrix4.rotateX(math.pi / 2)
  local n = Matrix3.normalMatrix(model, view)
  local x, y, z = Matrix3.transform(n, 1, 0, 0)
  -- A model-space +X normal maps to world +Y, then view +Z.
  Assert.isTrue(approxVec({ x, y, z }, { 0, 0, 1 }), "got " .. x .. "," .. y .. "," .. z)
end

function T.model_normal_composes_with_view_for_identity()
  assertModelNormalEquivalent(Matrix4.identity(), "identity")
end

function T.model_normal_composes_with_view_for_translation()
  assertModelNormalEquivalent(Matrix4.translate(7, -3, 11), "translation")
end

function T.model_normal_composes_with_view_for_rotation()
  assertModelNormalEquivalent(Matrix4.rotateZ(0.83), "rotation")
end

function T.model_normal_composes_with_view_for_uniform_scale()
  assertModelNormalEquivalent(Matrix4.scale(2.5, 2.5, 2.5), "uniform scale")
end

function T.model_normal_composes_with_view_for_nonuniform_scale()
  assertModelNormalEquivalent(Matrix4.scale(2, 3, 4), "nonuniform scale")
end

function T.model_normal_composes_with_view_for_rotation_and_nonuniform_scale()
  local model = Matrix4.multiply(Matrix4.rotateY(-0.58), Matrix4.scale(2, 3, 4))
  assertModelNormalEquivalent(model, "rotation and nonuniform scale")
end

function T.model_normal_into_matches_model_normal()
  local models = {
    Matrix4.identity(),
    Matrix4.translate(7, -3, 11),
    Matrix4.scale(2, 3, 4),
    Matrix4.rotateY(math.pi / 4),
    Matrix4.multiply(Matrix4.rotateY(-0.58), Matrix4.scale(2, 3, 4)),
  }
  for _, model in ipairs(models) do
    local out = { 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    local returned = Matrix3.modelNormalInto(out, model)
    Assert.isTrue(returned == out, "modelNormalInto reuses the output array")
    Assert.deepEqual(out, Matrix3.modelNormal(model))
  end
end

function T.model_normal_into_rejects_a_singular_transform()
  local out = { 0, 0, 0, 0, 0, 0, 0, 0, 0 }
  Assert.throws(function()
    Matrix3.modelNormalInto(out, Matrix4.scale(0, 1, 1))
  end)
end

return { tests = T }
