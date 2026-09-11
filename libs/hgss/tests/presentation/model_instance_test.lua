-- ModelInstance: pose evaluation, semantic playback, and production draw
-- items over the nitro runtime. All math here is pure: the render smoke test
-- in model_instance_render_test exercises the actual FieldRenderer.

local Assert = require("tests.support.Assert")
local Matrix3 = require("libs.math.src.Matrix3")
local Matrix4 = require("libs.math.src.Matrix4")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local NitroModelFixture = require("tests.support.NitroModelFixture")

local T = {}

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected error " .. code)
  Assert.equal(type(err) == "table" and err.code or err, code)
end

local function newInstance(opts)
  return ModelInstance.new(NitroModelFixture.doorDefinition(), opts)
end

-- A door definition whose material carries a texture, so effectiveMaterial
-- exercises the resolveImage callback (untextured materials never call it).
local function texturedDoorDefinition()
  local def = NitroModelFixture.doorDefinition()
  def.materials[1] = {
    id = 0,
    name = "wall",
    baseColor = { r = 255, g = 255, b = 255, a = 255 },
    alphaMode = "opaque",
    doubleSided = false,
    polygonAlpha = 31,
    texMtxMode = 0,
    texture = "wall.png",
    texWidth = 64,
    texHeight = 64,
  }
  return def
end

local function rendersFor(def)
  local renders = {}
  for _, mesh in ipairs(def.meshes) do
    renders[mesh.id] = { id = mesh.id }
  end
  return renders
end

-- The swing clip's rotation cell [1] (row 0, col 0) of the door draw matrix.
local function swingCell(instance)
  local draw = instance.poseState.drawMatrices["draw0.seg0"]
  return draw.position[1]
end

-- ---- playback and pose ----

function T.play_resolves_semantic_names()
  local instance = newInstance()
  local handle = instance:play("door.open")
  Assert.equal(type(handle), "table", "play returns the attachment handle")
  Assert.equal(handle.clip.name, "DoorOpen")
  Assert.equal(#instance.animationState:attachments("joint"), 1)
  throwsCode("ANIM_INSTANCE_UNKNOWN_ANIMATION", function()
    return instance:play("no.such.clip")
  end)
end

function T.bind_pose_is_the_identity_draw()
  local instance = newInstance()
  local pose = instance:evaluatePose()
  Assert.near(pose.nodeMatrices[0][1], 1, 1e-9)
  Assert.isNil(pose.nodeVisible[0], "no visibility animation: the node stays visible")
  Assert.near(swingCell(instance), 1, 1e-9)
end

function T.rigid_node_animation_moves_the_draw()
  local instance = newInstance()
  instance:play("door.open")
  instance:updateFixed() -- frame 1
  instance:evaluatePose()
  local c1 = swingCell(instance)
  Assert.isTrue(c1 < 1, "the swinging door rotates away from the bind pose")

  for _ = 1, 6 do
    instance:updateFixed()
  end
  instance:evaluatePose()
  local c7 = swingCell(instance)
  Assert.isTrue(c7 < c1, "the swing continues toward the peak")
  -- The final frame's rotation differs from the bind pose.
  Assert.isTrue(math.abs(c7 - 1) > 0.01)
end

function T.two_instances_animate_independently()
  local a, b = newInstance(), newInstance()
  a:play("door.open")
  b:play("door.open")
  for _ = 1, 3 do
    a:updateFixed()
    b:updateFixed()
  end
  for _ = 1, 4 do
    a:updateFixed()
  end
  a:evaluatePose()
  b:evaluatePose()
  -- a at frame 7, b at frame 3: the shared clip cannot couple their
  -- playback; their rotation cells must differ from each other and from the
  -- bind pose.
  local ma, mb = swingCell(a), swingCell(b)
  Assert.isTrue(ma < 1 and mb < 1, "both instances rotated off the bind pose")
  Assert.isFalse(ma == mb, "per-instance playback state")
end

function T.stop_by_handle()
  local instance = newInstance()
  local handle = instance:play("door.open")
  Assert.equal(instance:stop(handle), 1)
  Assert.equal(#instance.animationState:attachments("joint"), 0)
end

function T.play_validates_loop_options()
  local instance = ModelInstance.new(NitroModelFixture.doorDefinition())
  local ok = pcall(instance.play, instance, "door.open", { loopMode = "bounce" })
  Assert.isFalse(ok, "unknown loop mode is a programming error")
  Assert.equal(#instance.animationState:attachments("joint"), 0, "failed plays attach nothing")
end

-- ---- draw items ----

function T.draw_items_carry_pose_transforms()
  local instance = newInstance()
  instance:play("door.open")
  instance:updateFixed()
  instance:evaluatePose()
  local items = instance:drawItems(rendersFor(instance.definition))
  Assert.equal(#items, 1)
  Assert.near(items[1].transform[1], swingCell(instance), 1e-9, "the draw transform carries the pose")
  Assert.deepEqual(
    items[1].modelNormal,
    Matrix3.modelNormal(items[1].transform),
    "the draw item carries the inverse-transpose of its produced transform"
  )
  -- The per-segment polygon state rides on the item.
  Assert.equal(items[1].cullMode, "back")
  Assert.equal(items[1].polygonMode, "modulation")
  Assert.equal(items[1].polygonId, 0)
  Assert.equal(items[1].translucentDepthWrite, false)
  Assert.equal(items[1].lightMask, 5)
end

-- Compiled source provenance does not alter the renderer-facing current
-- transform or ordinary normal calculation.
function T.straddle_origin_items_use_the_current_transform_and_normal()
  local def = NitroModelFixture.doorDefinition()
  local instance = ModelInstance.new(def)
  instance:evaluatePose()
  local draw = instance.poseState.drawMatrices["draw0.seg0"]
  local current = Matrix4.multiply(Matrix4.rotateY(math.pi / 3), Matrix4.scale(2, 1, 1))
  draw.position = current

  local residentMesh = {}
  local items = instance:drawItems({ [def.meshes[1].id] = residentMesh })
  Assert.equal(#items, 1)
  Assert.equal(items[1].mesh, residentMesh)
  Assert.deepEqual(items[1].transform, current)
  Assert.deepEqual(items[1].modelNormal, Matrix3.modelNormal(current))
  Assert.isNil(rawget(items[1], "straddle"), "renderer items do not carry the discarded split")
end

-- The effective material reads the record's optional colors block (the four
-- DS base-material registers the dynamic compiler emits) per component even
-- before any evaluation -- the initial material state carries the record's
-- channels, not a baseColor reconstruction; records without the block keep
-- the baseColor fallback.
function T.effective_material_reads_per_component_colors_before_evaluation()
  local def = NitroModelFixture.doorDefinition()
  def.materials[1].colors = {
    diffuse = { r = 255, g = 0, b = 0 },
    ambient = { r = 0, g = 255, b = 0 },
    specular = { r = 0, g = 0, b = 255 },
    emission = { r = 123, g = 123, b = 123 },
  }
  local instance = ModelInstance.new(def)
  local m = instance:effectiveMaterial(0)
  Assert.deepEqual(m.matDiffuse, { 1, 0, 0 })
  Assert.deepEqual(m.matAmbient, { 0, 1, 0 })
  Assert.deepEqual(m.matSpecular, { 0, 0, 1 })
  Assert.near(m.matEmission[1], 123 / 255, 1e-9)
  Assert.near(m.matEmission[2], 123 / 255, 1e-9)
  Assert.near(m.matEmission[3], 123 / 255, 1e-9)
end

-- A complete backend record is consulted, not defaulted: distinctive values
-- land on the item unchanged.
function T.draw_items_honor_the_backend_records_draw_values()
  local def = NitroModelFixture.doorDefinition()
  local draw = def.backend.meshes["draw0.seg0"]
  draw.polygonMode = "decal"
  draw.polygonId = 3
  draw.cullMode = "front"
  draw.translucentDepthWrite = true
  draw.depthEqual = true
  local instance = ModelInstance.new(def)
  instance:evaluatePose()
  local items = instance:drawItems(rendersFor(def))
  Assert.equal(items[1].polygonMode, "decal")
  Assert.equal(items[1].polygonId, 3)
  Assert.equal(items[1].cullMode, "front")
  Assert.equal(items[1].translucentDepthWrite, true)
  Assert.equal(items[1].depthEqual, true)
end

function T.draw_items_compose_the_instance_transform()
  local def = NitroModelFixture.doorDefinition()
  def.meshes[1].center = { 1, 1, 0 }
  local instance = ModelInstance.new(def, {
    transform = Matrix4.translate(10, 0, 20),
  })
  instance:evaluatePose()
  local items = instance:drawItems(rendersFor(instance.definition))
  Assert.equal(#items, 1)
  Assert.equal(items[1].transform[13], 10)
  Assert.equal(items[1].transform[15], 20)
  Assert.deepEqual(items[1].modelNormal, { 1, 0, 0, 0, 1, 0, 0, 0, 1 })
  local nextItems = instance:drawItems(rendersFor(instance.definition))
  Assert.equal(items[1].modelNormal, nextItems[1].modelNormal, "translation-only draws share one identity normal")
  -- The center stays model-local: the render queue transforms it once.
  Assert.deepEqual(items[1].center, { 1, 1, 0 })
end

-- A zero-scale item transform (hidden geometry) still yields a draw item
-- with identity normals instead of raising; an invertible non-uniform
-- scale still yields the computed inverse-transpose normal.
function T.singular_item_transform_yields_identity_normals()
  local def = NitroModelFixture.doorDefinition()
  local instance = ModelInstance.new(def)
  instance:evaluatePose()
  local draw = instance.poseState.drawMatrices["draw0.seg0"]

  draw.position = Matrix4.scale(2, 1, 1)
  local scaled = instance:drawItems(rendersFor(def))
  Assert.equal(#scaled, 1)
  Assert.deepEqual(scaled[1].modelNormal, Matrix3.modelNormal(Matrix4.scale(2, 1, 1)))
  Assert.isFalse(
    scaled[1].modelNormal[1] == 1
      and scaled[1].modelNormal[5] == 1
      and scaled[1].modelNormal[9] == 1
      and scaled[1].modelNormal[2] == 0,
    "a non-uniform scale computes a non-identity normal"
  )

  draw.position = Matrix4.multiply(Matrix4.translate(1, 2, 3), Matrix4.scale(0, 0, 0))
  local hidden = instance:drawItems(rendersFor(def))
  Assert.equal(#hidden, 1)
  Assert.deepEqual(hidden[1].modelNormal, { 1, 0, 0, 0, 1, 0, 0, 0, 1 })
end

function T.material_contract_maps_to_render_state()
  local instance = newInstance()
  local wall = instance:effectiveMaterial(0)
  Assert.equal(wall.alphaClass, "opaque")
  Assert.equal(wall.polygonAlpha, 1.0)
  -- Instance state overrides never touch the definition.
  instance.materialState[0].polygonAlpha = 16
  Assert.near(instance:effectiveMaterial(0).polygonAlpha, 16 / 31, 1e-9)
  Assert.equal(instance.definition.materials[1].baseColor.a, 255)
end

-- The resolveImage callback contract: effectiveMaterial invokes it with the
-- texture key and the material index (the sampler wrap is looked up by
-- material, never by texture path).
function T.resolve_image_receives_only_the_texture_key_and_material_index()
  local calls = {}
  local instance = ModelInstance.new(texturedDoorDefinition(), {
    resolveImage = function(...)
      calls[#calls + 1] = { ... }
    end,
  })
  local material = instance:effectiveMaterial(0)
  Assert.equal(#calls, 1, "the textured material resolves an image")
  Assert.equal(#calls[1], 2, "the resolveImage callback receives the texture key and the material index")
  Assert.equal(calls[1][1], "wall.png")
  Assert.equal(calls[1][2], 0, "the material index keys the sampler-wrap lookup")
  Assert.isNil(material.image, "the callback return value passes through")
end

-- ---- nitro backend contract ----

function T.nitro_backend_without_a_program_raises()
  local def = NitroModelFixture.doorDefinition()
  def.backend = { meshes = def.backend.meshes }
  local instance = ModelInstance.new(def)
  throwsCode("POSE_NITRO_NO_TRANSFORM_PROGRAM", function()
    return instance:evaluatePose()
  end)
  -- Without a pose the draw path falls back to bind placement rather than
  -- pretending to animate; the backend draw records still cover the meshes.
  local items = instance:drawItems(rendersFor(def))
  Assert.equal(#items, 1)
  Assert.equal(items[1].transform[1], 1)
end

function T.the_source_backend_key_is_rejected_at_construction()
  -- A definition spec that still carries the sourceBackend key is a
  -- stale-schema artifact: a definition is nitro by construction, and the
  -- key is rejected at the load boundary.
  throwsCode("MODEL_DEF_BAD_SOURCE_BACKEND", function()
    return ModelDefinition.new({
      key = "fixture:bad",
      sourceBackend = "nitro",
      nodes = {
        {
          index = 0,
          name = "root",
          translation = { x = 0, y = 0, z = 0 },
          rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
          scale = { x = 1, y = 1, z = 1 },
        },
      },
      meshes = { { id = "m", nodeIndex = 0, materialIndex = 0, geometry = "fixtures/m.g4mesh" } },
      materials = {
        {
          id = 0,
          name = "wall",
          baseColor = { r = 255, g = 255, b = 255, a = 255 },
          alphaMode = "opaque",
          doubleSided = false,
          polygonAlpha = 31,
          texMtxMode = 0,
          texWidth = 0,
          texHeight = 0,
        },
      },
      animations = {},
      backend = { program = nil, meshes = {} },
    })
  end)
end

return { tests = T }
