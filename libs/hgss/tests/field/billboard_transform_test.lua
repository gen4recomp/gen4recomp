-- BillboardTransform: rebuilding a BB draw's model matrix from its compiled base
-- transform and the frame's view matrix. The contract under test is the one
-- NitroSystem sbc.c implements: keep the base translation and per-axis scale,
-- discard the base rotation, and face the camera by undoing the view rotation.

local Assert = require("tests.support.Assert")
local BillboardTransform = require("libs.hgss.src.presentation.BillboardTransform")
local Matrix3 = require("libs.math.src.Matrix3")
local Matrix4 = require("libs.math.src.Matrix4")

local T = {}

local EPS = 1e-9

local function assertPoint(m, x, y, z, ex, ey, ez, msg)
  local ax, ay, az = Matrix4.transformPoint(m, x, y, z)
  if math.abs(ax - ex) > 1e-6 or math.abs(ay - ey) > 1e-6 or math.abs(az - ez) > 1e-6 then
    error(string.format("%s: expected (%g,%g,%g), got (%g,%g,%g)", msg or "point mismatch", ex, ey, ez, ax, ay, az))
  end
end

-- A camera at `eye` looking at the origin, as FieldCamera produces.
local function view(eye)
  return Matrix4.lookAt(eye, { 0, 0, 0 }, { 0, 1, 0 })
end

function T.camera_in_front_leaves_local_axes_alone()
  local base = Matrix4.translate(3, 1, 0)
  local m = BillboardTransform.resolve(base, view({ 0, 0, 10 }))
  -- Looking down -Z from +Z: view rotation is the identity, so is its inverse.
  assertPoint(m, 0, 0, 0, 3, 1, 0, "billboard sits at the base translation")
  assertPoint(m, 1, 0, 0, 4, 1, 0, "local +x stays world +x")
  assertPoint(m, 0, 1, 0, 3, 2, 0, "local +y stays world +y")
end

function T.quarter_orbit_turns_the_billboard_to_face_the_camera()
  local m = BillboardTransform.resolve(Matrix4.translate(0, 0, 0), view({ 10, 0, 0 }))
  -- The camera is now on +X, so the billboard's local +x must point along -Z and
  -- its local +z (the facing normal) along +X, toward the camera.
  assertPoint(m, 1, 0, 0, 0, 0, -1, "local +x turned to world -z")
  assertPoint(m, 0, 0, 1, 1, 0, 0, "local +z faces the camera")
  assertPoint(m, 0, 1, 0, 0, 1, 0, "up is preserved by a yaw-only camera")
end

function T.elevated_camera_pitches_the_billboard()
  local eye = { 0, 10, 10 }
  local m = BillboardTransform.resolve(Matrix4.translate(0, 0, 0), view(eye))
  -- Full BB responds to pitch: the facing normal points back along the view
  -- direction, so local +z lands on the normalized eye direction.
  local len = math.sqrt(eye[1] ^ 2 + eye[2] ^ 2 + eye[3] ^ 2)
  assertPoint(m, 0, 0, 1, eye[1] / len, eye[2] / len, eye[3] / len, "local +z points at an elevated camera")
  assertPoint(m, 1, 0, 0, 1, 0, 0, "x stays horizontal under pure pitch")
end

function T.translation_survives_a_rotated_base()
  -- Base rotation is discarded, base translation is not.
  local base = Matrix4.multiply(Matrix4.translate(4, 2, -6), Matrix4.rotateY(1.1))
  local m = BillboardTransform.resolve(base, view({ 10, 0, 0 }))
  assertPoint(m, 0, 0, 0, 4, 2, -6, "base translation kept")
  assertPoint(m, 0, 0, 1, 5, 2, -6, "base rotation discarded: local +z faces the camera on +x")
end

function T.non_uniform_base_scale_stretches_along_camera_axes()
  local base = Matrix4.multiply(Matrix4.translate(0, 0, 0), Matrix4.scale(2, 3, 1))
  local m = BillboardTransform.resolve(base, view({ 10, 0, 0 }))
  assertPoint(m, 1, 0, 0, 0, 0, -2, "x stretched by 2 along the camera's right axis")
  assertPoint(m, 0, 1, 0, 0, 3, 0, "y stretched by 3 along the camera's up axis")
end

function T.resolved_model_normal_composes_with_view_like_the_legacy_normal_matrix()
  local base = Matrix4.multiply(Matrix4.rotateZ(0.7), Matrix4.scale(2, 3, 4))
  local viewMatrix = Matrix4.multiply(Matrix4.rotateX(0.37), Matrix4.rotateY(-0.61))
  local model, modelNormal = BillboardTransform.resolve(base, viewMatrix)
  Assert.notNil(modelNormal, "billboard resolution returns the matching model normal")

  local nx, ny, nz = 0.31, -0.47, 0.82
  local legacyX, legacyY, legacyZ = Matrix3.transform(Matrix3.normalMatrix(model, viewMatrix), nx, ny, nz)
  local modelX, modelY, modelZ = Matrix3.transform(modelNormal, nx, ny, nz)
  local actualX, actualY, actualZ = Matrix3.transform(Matrix3.from4x4(viewMatrix), modelX, modelY, modelZ)
  Assert.near(actualX, legacyX, 1e-9)
  Assert.near(actualY, legacyY, 1e-9)
  Assert.near(actualZ, legacyZ, 1e-9)
end

function T.view_space_billboard_normals_match_the_legacy_world_matrix()
  local base = Matrix4.multiply(Matrix4.rotateZ(0.7), Matrix4.scale(2, 3, 4))
  local viewMatrix = Matrix4.multiply(Matrix4.rotateX(0.37), Matrix4.rotateY(-0.61))
  local _, modelNormal = BillboardTransform.resolve(base, viewMatrix)
  local _, scale = BillboardTransform.components(base)

  local nx, ny, nz = 0.31, -0.47, 0.82
  local modelX, modelY, modelZ = Matrix3.transform(modelNormal, nx, ny, nz)
  local legacyX, legacyY, legacyZ = Matrix3.transform(Matrix3.from4x4(viewMatrix), modelX, modelY, modelZ)
  local newX, newY, newZ = nx / scale[1], ny / scale[2], nz / scale[3]
  Assert.near(legacyX, newX, 1e-9)
  Assert.near(legacyY, newY, 1e-9)
  Assert.near(legacyZ, newZ, 1e-9)
end

-- A rotated base's scale is the magnitude of each basis vector, not a matrix
-- element, so rotation must not leak into it.
function T.scale_is_read_from_basis_magnitudes()
  local base = Matrix4.multiply(Matrix4.rotateY(0.7), Matrix4.scale(2, 1, 1))
  local m = BillboardTransform.resolve(base, view({ 0, 0, 10 }))
  assertPoint(m, 1, 0, 0, 2, 0, 0, "scale recovered through the rotation")
end

function T.components_keep_translation_and_discard_base_rotation()
  local base =
    Matrix4.multiply(Matrix4.translate(4, 2, -6), Matrix4.multiply(Matrix4.rotateZ(0.7), Matrix4.scale(2, 3, 4)))
  local center, scale = BillboardTransform.components(base)
  Assert.deepEqual(center, { 4, 2, -6 })
  Assert.near(scale[1], 2, EPS)
  Assert.near(scale[2], 3, EPS)
  Assert.near(scale[3], 4, EPS)
end

function T.view_space_billboard_positions_match_the_legacy_world_matrix()
  local views = {
    Matrix4.identity(),
    Matrix4.multiply(Matrix4.rotateX(0.37), Matrix4.rotateY(-0.61)),
    Matrix4.lookAt({ 10, 4, 6 }, { 0, 0, 0 }, { 0, 1, 0 }),
  }
  local bases = {
    Matrix4.multiply(Matrix4.translate(3, 1, -4), Matrix4.scale(2, 3, 4)),
    Matrix4.multiply(
      Matrix4.translate(-2, 5, 7),
      Matrix4.multiply(Matrix4.rotateZ(0.7), Matrix4.scale(1.5, 2.5, 0.75))
    ),
  }
  local vertices = {
    { 0, 0, 0 },
    { 1, -2, 0.5 },
    { -0.25, 0.75, 2 },
  }

  for _, viewMatrix in ipairs(views) do
    for _, base in ipairs(bases) do
      local legacy = BillboardTransform.resolve(base, viewMatrix)
      local center, scale = BillboardTransform.components(base)
      local viewCenterX, viewCenterY, viewCenterZ = Matrix4.transformPoint(viewMatrix, center[1], center[2], center[3])
      for _, vertex in ipairs(vertices) do
        local worldX, worldY, worldZ = Matrix4.transformPoint(legacy, vertex[1], vertex[2], vertex[3])
        local oldX, oldY, oldZ = Matrix4.transformPoint(viewMatrix, worldX, worldY, worldZ)
        Assert.near(oldX, viewCenterX + vertex[1] * scale[1], 1e-9)
        Assert.near(oldY, viewCenterY + vertex[2] * scale[2], 1e-9)
        Assert.near(oldZ, viewCenterZ + vertex[3] * scale[3], 1e-9)
      end
    end
  end
end

function T.rejects_a_matrix_of_the_wrong_size()
  Assert.throws(function()
    BillboardTransform.resolve({ 1, 0, 0 }, Matrix4.identity())
  end)
end

function T.rejects_a_zero_billboard_scale_before_shader_use()
  Assert.throws(function()
    BillboardTransform.components(Matrix4.scale(0, 1, 1))
  end)
end

function T.result_is_a_fresh_matrix()
  local base = Matrix4.translate(1, 2, 3)
  local m = BillboardTransform.resolve(base, Matrix4.identity())
  Assert.isTrue(m ~= base, "does not alias its input")
  Assert.equal(#m, 16)
  Assert.isTrue(math.abs(m[16] - 1) < EPS, "w row is affine")
end

function T.components_into_matches_components()
  local bases = {
    Matrix4.translate(4, 2, -6),
    Matrix4.multiply(Matrix4.translate(4, 2, -6), Matrix4.multiply(Matrix4.rotateZ(0.7), Matrix4.scale(2, 3, 4))),
    Matrix4.multiply(Matrix4.rotateY(0.7), Matrix4.scale(2, 1, 1)),
  }
  for _, base in ipairs(bases) do
    local centerOut, scaleOut = { 0, 0, 0 }, { 0, 0, 0 }
    local centerReturned, scaleReturned = BillboardTransform.componentsInto(centerOut, scaleOut, base)
    Assert.isTrue(centerReturned == centerOut, "componentsInto reuses the center array")
    Assert.isTrue(scaleReturned == scaleOut, "componentsInto reuses the scale array")
    local center, scale = BillboardTransform.components(base)
    Assert.deepEqual(centerOut, center)
    Assert.deepEqual(scaleOut, scale)
  end
end

function T.components_into_rejects_a_zero_billboard_scale()
  Assert.throws(function()
    BillboardTransform.componentsInto({ 0, 0, 0 }, { 0, 0, 0 }, Matrix4.scale(0, 1, 1))
  end)
end

return { tests = T }
