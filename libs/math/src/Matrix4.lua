-- Column-major 4x4 matrix math for building placed-model and camera transforms.
-- Convention matches the DS geometry engine and this project's GxDisplayList
-- decoder: a matrix is a 16-element array indexed m[col*4 + row + 1], and
-- multiply(a, b) yields a*b so transforms compose left-to-right. Pure domain
-- module (no love, arithmetic only) so it is usable from both the asset
-- compiler and, later, the renderer.

---@alias Matrix4.Values number[]
---@class G4Mat4
---@field m ffi.cdata*
---@alias Matrix4.Buffer G4Mat4
---@class Matrix4
---@field newBuffer fun(): Matrix4.Buffer
---@field identityInto fun(out: Matrix4.Buffer): Matrix4.Buffer
---@field copyInto fun(out: Matrix4.Buffer, src: Matrix4.Buffer): Matrix4.Buffer
---@field multiplyInto fun(out: Matrix4.Buffer, a: Matrix4.Buffer, b: Matrix4.Buffer): Matrix4.Buffer
---@field translateInto fun(out: Matrix4.Buffer, tx: number, ty: number, tz: number): Matrix4.Buffer
---@field scaleInto fun(out: Matrix4.Buffer, sx: number, sy: number, sz: number): Matrix4.Buffer
---@field rotateXInto fun(out: Matrix4.Buffer, rad: number): Matrix4.Buffer
---@field rotateYInto fun(out: Matrix4.Buffer, rad: number): Matrix4.Buffer
---@field rotateZInto fun(out: Matrix4.Buffer, rad: number): Matrix4.Buffer
---@field linearInto fun(out: Matrix4.Buffer, src: Matrix4.Buffer): Matrix4.Buffer
---@field transformPointBuffer fun(m: Matrix4.Buffer, x: number, y: number, z: number): number, number, number
---@field toArrayBuffer fun(m: Matrix4.Buffer): Matrix4.Values
---@field identity fun(): Matrix4.Values
---@field multiply fun(a: Matrix4.Values, b: Matrix4.Values): Matrix4.Values
---@field transformPoint fun(m: Matrix4.Values, x: number, y: number, z: number): number, number, number
---@field scale fun(sx: number, sy: number, sz: number): Matrix4.Values
---@field translate fun(tx: number, ty: number, tz: number): Matrix4.Values
---@field rotateX fun(rad: number): Matrix4.Values
---@field rotateY fun(rad: number): Matrix4.Values
---@field rotateZ fun(rad: number): Matrix4.Values
---@field perspective fun(fovY: number, aspect: number, near: number, far: number): Matrix4.Values
---@field orthographic fun(left: number, right: number, bottom: number, top: number, near: number, far: number): Matrix4.Values
---@field lookAt fun(eye: number[], center: number[], up: number[]): Matrix4.Values
---@field linear fun(m: Matrix4.Values): Matrix4.Values
---@field toArray fun(m: Matrix4.Values): Matrix4.Values

local Matrix4 = {}

local ffi = require("ffi")

ffi.cdef([[
typedef struct {
  double m[16];
} G4Mat4;
]])

---@return Matrix4.Buffer
function Matrix4.newBuffer()
  return ffi.new("G4Mat4") --[[@as Matrix4.Buffer]]
end

---@param out Matrix4.Buffer
---@return Matrix4.Buffer
function Matrix4.identityInto(out)
  local m = out.m
  m[0], m[1], m[2], m[3] = 1, 0, 0, 0
  m[4], m[5], m[6], m[7] = 0, 1, 0, 0
  m[8], m[9], m[10], m[11] = 0, 0, 1, 0
  m[12], m[13], m[14], m[15] = 0, 0, 0, 1
  return out
end

---@param out Matrix4.Buffer
---@param src Matrix4.Buffer
---@return Matrix4.Buffer
function Matrix4.copyInto(out, src)
  ffi.copy(out.m, src.m, 128)
  return out
end

---@param out Matrix4.Buffer
---@param a Matrix4.Buffer
---@param b Matrix4.Buffer
---@return Matrix4.Buffer
function Matrix4.multiplyInto(out, a, b)
  assert(out ~= a and out ~= b, "multiplyInto output must not alias inputs")
  local am, bm, om = a.m, b.m, out.m
  for col = 0, 3 do
    local b0 = bm[col * 4]
    local b1 = bm[col * 4 + 1]
    local b2 = bm[col * 4 + 2]
    local b3 = bm[col * 4 + 3]
    om[col * 4] = am[0] * b0 + am[4] * b1 + am[8] * b2 + am[12] * b3
    om[col * 4 + 1] = am[1] * b0 + am[5] * b1 + am[9] * b2 + am[13] * b3
    om[col * 4 + 2] = am[2] * b0 + am[6] * b1 + am[10] * b2 + am[14] * b3
    om[col * 4 + 3] = am[3] * b0 + am[7] * b1 + am[11] * b2 + am[15] * b3
  end
  return out
end

---@param out Matrix4.Buffer
---@param tx number
---@param ty number
---@param tz number
---@return Matrix4.Buffer
function Matrix4.translateInto(out, tx, ty, tz)
  local m = out.m
  m[0], m[1], m[2], m[3] = 1, 0, 0, 0
  m[4], m[5], m[6], m[7] = 0, 1, 0, 0
  m[8], m[9], m[10], m[11] = 0, 0, 1, 0
  m[12], m[13], m[14], m[15] = tx, ty, tz, 1
  return out
end

---@param out Matrix4.Buffer
---@param sx number
---@param sy number
---@param sz number
---@return Matrix4.Buffer
function Matrix4.scaleInto(out, sx, sy, sz)
  local m = out.m
  m[0], m[1], m[2], m[3] = sx, 0, 0, 0
  m[4], m[5], m[6], m[7] = 0, sy, 0, 0
  m[8], m[9], m[10], m[11] = 0, 0, sz, 0
  m[12], m[13], m[14], m[15] = 0, 0, 0, 1
  return out
end

---@param out Matrix4.Buffer
---@param rad number
---@return Matrix4.Buffer
function Matrix4.rotateXInto(out, rad)
  local c, s = math.cos(rad), math.sin(rad)
  local m = out.m
  m[0], m[1], m[2], m[3] = 1, 0, 0, 0
  m[4], m[5], m[6], m[7] = 0, c, s, 0
  m[8], m[9], m[10], m[11] = 0, -s, c, 0
  m[12], m[13], m[14], m[15] = 0, 0, 0, 1
  return out
end

---@param out Matrix4.Buffer
---@param rad number
---@return Matrix4.Buffer
function Matrix4.rotateYInto(out, rad)
  local c, s = math.cos(rad), math.sin(rad)
  local m = out.m
  m[0], m[1], m[2], m[3] = c, 0, -s, 0
  m[4], m[5], m[6], m[7] = 0, 1, 0, 0
  m[8], m[9], m[10], m[11] = s, 0, c, 0
  m[12], m[13], m[14], m[15] = 0, 0, 0, 1
  return out
end

---@param out Matrix4.Buffer
---@param rad number
---@return Matrix4.Buffer
function Matrix4.rotateZInto(out, rad)
  local c, s = math.cos(rad), math.sin(rad)
  local m = out.m
  m[0], m[1], m[2], m[3] = c, s, 0, 0
  m[4], m[5], m[6], m[7] = -s, c, 0, 0
  m[8], m[9], m[10], m[11] = 0, 0, 1, 0
  m[12], m[13], m[14], m[15] = 0, 0, 0, 1
  return out
end

---@param out Matrix4.Buffer
---@param src Matrix4.Buffer
---@return Matrix4.Buffer
function Matrix4.linearInto(out, src)
  local sm, om = src.m, out.m
  om[0], om[1], om[2], om[3] = sm[0], sm[1], sm[2], 0
  om[4], om[5], om[6], om[7] = sm[4], sm[5], sm[6], 0
  om[8], om[9], om[10], om[11] = sm[8], sm[9], sm[10], 0
  om[12], om[13], om[14], om[15] = 0, 0, 0, 1
  return out
end

---@param m Matrix4.Buffer
---@param x number
---@param y number
---@param z number
---@return number, number, number
function Matrix4.transformPointBuffer(m, x, y, z)
  local a = m.m
  return a[0] * x + a[4] * y + a[8] * z + a[12],
    a[1] * x + a[5] * y + a[9] * z + a[13],
    a[2] * x + a[6] * y + a[10] * z + a[14]
end

---@param m Matrix4.Buffer
---@return Matrix4.Values
function Matrix4.toArrayBuffer(m)
  local a = {} ---@type Matrix4.Values
  local values = m.m
  for i = 0, 15 do
    a[i + 1] = values[i]
  end
  return a
end

---@return Matrix4.Values
function Matrix4.identity()
  return { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
end

-- a * b, column-major.
---@param a Matrix4.Values
---@param b Matrix4.Values
---@return Matrix4.Values
function Matrix4.multiply(a, b)
  local m = {} ---@type Matrix4.Values
  for col = 0, 3 do
    for row = 0, 3 do
      local s = 0 ---@type number
      for k = 0, 3 do
        s = s + a[k * 4 + row + 1] * b[col * 4 + k + 1]
      end
      m[col * 4 + row + 1] = s
    end
  end
  return m
end

-- Transform a point (implicit w = 1); returns the three transformed components.
---@param m Matrix4.Values
---@param x number
---@param y number
---@param z number
---@return number, number, number
function Matrix4.transformPoint(m, x, y, z)
  return m[1] * x + m[5] * y + m[9] * z + m[13],
    m[2] * x + m[6] * y + m[10] * z + m[14],
    m[3] * x + m[7] * y + m[11] * z + m[15]
end

---@param sx number
---@param sy number
---@param sz number
---@return Matrix4.Values
function Matrix4.scale(sx, sy, sz)
  return { sx, 0, 0, 0, 0, sy, 0, 0, 0, 0, sz, 0, 0, 0, 0, 1 }
end

---@param tx number
---@param ty number
---@param tz number
---@return Matrix4.Values
function Matrix4.translate(tx, ty, tz)
  return { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, tx, ty, tz, 1 }
end

---@param rad number
---@return Matrix4.Values
function Matrix4.rotateX(rad)
  local c, s = math.cos(rad), math.sin(rad)
  return { 1, 0, 0, 0, 0, c, s, 0, 0, -s, c, 0, 0, 0, 0, 1 }
end

---@param rad number
---@return Matrix4.Values
function Matrix4.rotateY(rad)
  local c, s = math.cos(rad), math.sin(rad)
  return { c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, 0, 0, 0, 1 }
end

---@param rad number
---@return Matrix4.Values
function Matrix4.rotateZ(rad)
  local c, s = math.cos(rad), math.sin(rad)
  return { c, s, 0, 0, -s, c, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
end

-- Right-handed OpenGL-style perspective projection (clip z in [-1, 1]).
-- fovY in radians, aspect = width/height. Column-major.
---@param fovY number
---@param aspect number
---@param near number
---@param far number
---@return Matrix4.Values
function Matrix4.perspective(fovY, aspect, near, far)
  local f = 1 / math.tan(fovY / 2)
  local m = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
  m[1] = f / aspect
  m[6] = f
  m[11] = (far + near) / (near - far)
  m[12] = -1
  m[15] = (2 * far * near) / (near - far)
  return m
end

-- Right-handed OpenGL-style orthographic projection (clip z in [-1, 1]).
-- Bounds are expressed in camera space. Column-major.
---@param left number
---@param right number
---@param bottom number
---@param top number
---@param near number
---@param far number
---@return Matrix4.Values
function Matrix4.orthographic(left, right, bottom, top, near, far)
  assert(right ~= left, "orthographic width must be non-zero")
  assert(top ~= bottom, "orthographic height must be non-zero")
  assert(far ~= near, "orthographic depth must be non-zero")
  return {
    2 / (right - left),
    0,
    0,
    0,
    0,
    2 / (top - bottom),
    0,
    0,
    0,
    0,
    -2 / (far - near),
    0,
    -(right + left) / (right - left),
    -(top + bottom) / (top - bottom),
    -(far + near) / (far - near),
    1,
  }
end

---@param a number[]
---@param b number[]
---@return Matrix4.Values
local function sub3(a, b)
  return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } ---@type Matrix4.Values
end
---@param a number[]
---@param b number[]
---@return number
local function dot3(a, b)
  return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end
---@param a number[]
---@param b number[]
---@return Matrix4.Values
local function cross3(a, b)
  return {
    a[2] * b[3] - a[3] * b[2],
    a[3] * b[1] - a[1] * b[3],
    a[1] * b[2] - a[2] * b[1],
  }
end
---@param v number[]
---@return Matrix4.Values
local function normalize3(v)
  local len = math.sqrt(dot3(v, v))
  assert(len > 0, "cannot normalize a zero-length vector")
  return { v[1] / len, v[2] / len, v[3] / len } ---@type Matrix4.Values
end

-- Right-handed lookAt (gluLookAt). eye/center/up are {x,y,z}. Column-major.
---@param eye number[]
---@param center number[]
---@param up number[]
---@return Matrix4.Values
function Matrix4.lookAt(eye, center, up)
  local f = normalize3(sub3(center, eye))
  local s = normalize3(cross3(f, up))
  local u = cross3(s, f)
  return {
    s[1],
    u[1],
    -f[1],
    0,
    s[2],
    u[2],
    -f[2],
    0,
    s[3],
    u[3],
    -f[3],
    0,
    -dot3(s, eye),
    -dot3(u, eye),
    dot3(f, eye),
    1,
  }
end

-- The linear part of a 4x4 as a 4x4 (translation zeroed): the matrix a
-- direction vector transforms by, since the DS vector matrix is 3x3 and
-- never picks up a translation.
---@param m Matrix4.Values
---@return Matrix4.Values
function Matrix4.linear(m)
  return {
    m[1],
    m[2],
    m[3],
    0,
    m[5],
    m[6],
    m[7],
    0,
    m[9],
    m[10],
    m[11],
    0,
    0,
    0,
    0,
    1,
  }
end

-- Serializable copy of the 16 components (column-major order).
---@param m Matrix4.Values
---@return Matrix4.Values
function Matrix4.toArray(m)
  local a = {} ---@type Matrix4.Values
  for i = 1, 16 do
    a[i] = m[i]
  end
  return a
end

return Matrix4
