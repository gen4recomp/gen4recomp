-- 3x3 column-major matrix math used by the renderer's normal-transform paths.
-- Keeps the same indexing convention as Matrix4 (m[col*3 + row + 1]) so the
-- two modules compose cleanly. Pure domain module: no love, arithmetic only.

---@alias Matrix3.Values number[]
---@class Matrix3
---@field identity fun(): Matrix3.Values
---@field from4x4 fun(m: Matrix4.Values): Matrix3.Values
---@field multiply fun(a: Matrix3.Values, b: Matrix3.Values): Matrix3.Values
---@field transpose fun(m: Matrix3.Values): Matrix3.Values
---@field inverse fun(m: Matrix3.Values): Matrix3.Values?
---@field transform fun(m: Matrix3.Values, x: number, y: number, z: number): number, number, number
---@field modelNormal fun(model: Matrix4.Values): Matrix3.Values
---@field modelNormalInto fun(out: Matrix3.Values, model: Matrix4.Values): Matrix3.Values
---@field normalMatrix fun(model: Matrix4.Values, view: Matrix4.Values): Matrix3.Values

local Matrix3 = {}

---@return Matrix3.Values
function Matrix3.identity()
  return { 1, 0, 0, 0, 1, 0, 0, 0, 1 } ---@type Matrix3.Values
end

-- Extract the upper-left 3x3 of a 4x4 column-major matrix.
---@param m Matrix4.Values
---@return Matrix3.Values
function Matrix3.from4x4(m)
  return {
    m[1],
    m[2],
    m[3],
    m[5],
    m[6],
    m[7],
    m[9],
    m[10],
    m[11],
  }
end

-- a * b, both 3x3 column-major.
---@param a Matrix3.Values
---@param b Matrix3.Values
---@return Matrix3.Values
function Matrix3.multiply(a, b)
  local m = {} ---@type Matrix3.Values
  for col = 0, 2 do
    for row = 0, 2 do
      local s = 0 ---@type number
      for k = 0, 2 do
        s = s + a[k * 3 + row + 1] * b[col * 3 + k + 1]
      end
      m[col * 3 + row + 1] = s
    end
  end
  return m
end

---@param m Matrix3.Values
---@return Matrix3.Values
function Matrix3.transpose(m)
  return {
    m[1],
    m[4],
    m[7],
    m[2],
    m[5],
    m[8],
    m[3],
    m[6],
    m[9],
  }
end

-- Determinant of a 3x3 matrix.
---@param m Matrix3.Values
---@return number
local function determinant(m)
  return m[1] * (m[5] * m[9] - m[6] * m[8]) - m[4] * (m[2] * m[9] - m[3] * m[8]) + m[7] * (m[2] * m[6] - m[3] * m[5])
end

-- Inverse of a 3x3 matrix, or nil if singular.
---@param m Matrix3.Values
---@return Matrix3.Values?
function Matrix3.inverse(m)
  local det = determinant(m) ---@type number
  if math.abs(det) < 1e-12 then
    return nil
  end
  local invDet = 1 / det ---@type number
  return {
    (m[5] * m[9] - m[6] * m[8]) * invDet,
    (m[3] * m[8] - m[2] * m[9]) * invDet,
    (m[2] * m[6] - m[3] * m[5]) * invDet,
    (m[6] * m[7] - m[4] * m[9]) * invDet,
    (m[1] * m[9] - m[3] * m[7]) * invDet,
    (m[3] * m[4] - m[1] * m[6]) * invDet,
    (m[4] * m[8] - m[5] * m[7]) * invDet,
    (m[2] * m[7] - m[1] * m[8]) * invDet,
    (m[1] * m[5] - m[2] * m[4]) * invDet,
  }
end

-- Transform a 3-vector by a 3x3 matrix.
---@param m Matrix3.Values
---@param x number
---@param y number
---@param z number
---@return number, number, number
function Matrix3.transform(m, x, y, z)
  return m[1] * x + m[4] * y + m[7] * z, m[2] * x + m[5] * y + m[8] * z, m[3] * x + m[6] * y + m[9] * z
end

-- Model normal transform: inverse-transpose of a 4x4 model matrix's linear
-- component. Translation has no effect. A singular model transform has no
-- normal transform and is invalid input.
---@param model Matrix4.Values -- 4x4 column-major model matrix
---@return Matrix3.Values -- 3x3 column-major inverse-transpose
function Matrix3.modelNormal(model)
  local out = { 0, 0, 0, 0, 0, 0, 0, 0, 0 } ---@type Matrix3.Values
  return Matrix3.modelNormalInto(out, model)
end

-- Model normal transform written into an existing 9-number table: the same
-- inverse-transpose of the 4x4 model matrix's linear component as
-- modelNormal, reusing the output. Translation has no effect; a singular
-- model transform is invalid input and fails loudly.
---@param out Matrix3.Values -- 9-number column-major output, overwritten
---@param model Matrix4.Values -- 4x4 column-major model matrix
---@return Matrix3.Values -- the same `out` table
function Matrix3.modelNormalInto(out, model)
  assert(type(out) == "table" and #out == 9, "modelNormalInto requires a 9-number output table")
  local m1, m2, m3 = model[1], model[2], model[3]
  local m4, m5, m6 = model[5], model[6], model[7]
  local m7, m8, m9 = model[9], model[10], model[11]
  local det = m1 * (m5 * m9 - m6 * m8) - m4 * (m2 * m9 - m3 * m8) + m7 * (m2 * m6 - m3 * m5)
  assert(math.abs(det) >= 1e-12, "singular model transform has no normal matrix")
  local invDet = 1 / det ---@type number
  out[1] = (m5 * m9 - m6 * m8) * invDet
  out[2] = (m6 * m7 - m4 * m9) * invDet
  out[3] = (m4 * m8 - m5 * m7) * invDet
  out[4] = (m3 * m8 - m2 * m9) * invDet
  out[5] = (m1 * m9 - m3 * m7) * invDet
  out[6] = (m2 * m7 - m1 * m8) * invDet
  out[7] = (m2 * m6 - m3 * m5) * invDet
  out[8] = (m3 * m4 - m1 * m6) * invDet
  out[9] = (m1 * m5 - m2 * m4) * invDet
  return out
end

-- Normal matrix: inverse-transpose of the upper 3x3 of (view * model).
-- `model` and `view` are 4x4 column-major matrices. Returns a 3x3 column-major
-- matrix suitable for sending to the vertex shader as a mat3 uniform.
-- A singular model-view transform has no normal matrix; that is invalid input
-- and fails loudly instead of degrading to identity.
---@param model Matrix4.Values
---@param view Matrix4.Values
---@return Matrix3.Values
function Matrix3.normalMatrix(model, view)
  local mv = Matrix3.multiply(Matrix3.from4x4(view), Matrix3.from4x4(model))
  local inv = Matrix3.inverse(mv)
  assert(inv, "singular model-view transform has no normal matrix")
  return Matrix3.transpose(inv)
end

return Matrix3
