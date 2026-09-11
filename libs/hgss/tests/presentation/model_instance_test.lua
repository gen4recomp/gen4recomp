-- ModelInstance: pose evaluation, semantic playback, and production draw
-- items over the nitro runtime. All math here is pure: the render smoke test
-- in model_instance_render_test exercises the actual FieldRenderer.

local Assert = require("tests.support.Assert")
local Matrix3 = require("libs.math.src.Matrix3")
local Matrix4 = require("libs.math.src.Matrix4")
local BillboardTransform = require("libs.hgss.src.presentation.BillboardTransform")
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

-- Repeated evaluation mutates owner-held records instead of rebuilding the
-- object graph: the outer draw list, the per-mesh item records, the
-- effective material records with their color arrays, and the
-- renderer-facing transform/normal arrays keep their identities while their
-- contents track the current frame. Hiding a node truncates the live list
-- without destroying records; reappearing reuses them.
function T.draw_records_keep_stable_identities_across_evaluations()
  local instance = newInstance()
  local renders = rendersFor(instance.definition)
  instance:evaluatePose()
  instance:drawItems(renders) -- warmup establishes the stable storage
  instance:play("door.open")
  instance:updateFixed()
  instance:evaluatePose()
  local first = instance:drawItems(renders)
  Assert.equal(#first, 1)
  local record = first[1]
  local material = record.material
  local diffuse = material.matDiffuse
  local ambient = material.matAmbient
  local specular = material.matSpecular
  local emission = material.matEmission
  local transform = record.transform
  local normal = record.modelNormal
  Assert.equal(#transform, 16)
  Assert.equal(#normal, 9)
  local cellBefore = transform[1]

  for _ = 1, 6 do
    instance:updateFixed()
  end
  instance:evaluatePose()
  local second = instance:drawItems(renders)
  Assert.isTrue(second == first, "the draw list is a reused live view")
  Assert.isTrue(second[1] == record, "each visible mesh maps to a stable record slot")
  Assert.isTrue(second[1].material == material, "effective material records are stable")
  Assert.isTrue(material.matDiffuse == diffuse, "material diffuse arrays are stable")
  Assert.isTrue(material.matAmbient == ambient, "material ambient arrays are stable")
  Assert.isTrue(material.matSpecular == specular, "material specular arrays are stable")
  Assert.isTrue(material.matEmission == emission, "material emission arrays are stable")
  Assert.isTrue(second[1].transform == transform, "renderer-facing transform arrays are stable")
  Assert.isTrue(second[1].modelNormal == normal, "model-normal arrays are stable")
  Assert.isFalse(transform[1] == cellBefore, "reused records carry the current frame")
  Assert.deepEqual(normal, Matrix3.modelNormal(transform), "the reused normal tracks the current transform")

  local nodeCommand = instance.definition.backend.program.commands[2]
  Assert.equal(nodeCommand.opcode, 0x02, "the door program gates its draw on a NODE command")
  nodeCommand.visible = false
  instance:evaluatePose()
  local hidden = instance:drawItems(renders)
  Assert.isTrue(hidden == first, "hiding keeps the same outer list")
  Assert.equal(#hidden, 0, "hiding a node shrinks the visible list")
  Assert.isNil(hidden[1], "surplus entries are cleared when hidden")
  nodeCommand.visible = true
  instance:evaluatePose()
  local reshown = instance:drawItems(renders)
  Assert.equal(#reshown, 1)
  Assert.isTrue(reshown[1] == record, "reappearing reuses the established record")
end

-- A two-draw program: one static mesh and one billboard mesh over the same
-- joint, sharing one material. The joint clip moves the shared transform;
-- the color clip drives the shared material registers.
local function mixedStaticBillboardDefinition(clips)
  local statState = NitroModelFixture.drawState()
  local billboardState = NitroModelFixture.drawState()
  billboardState.drawIndex = 1
  billboardState.positionSource = nil
  billboardState.transformMode = "billboard"
  return ModelDefinition.new({
    key = "fixture:mixed-billboard",
    nodes = {
      {
        index = 0,
        name = "root",
        translation = { x = 0, y = 0, z = 0 },
        rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
        scale = { x = 1, y = 1, z = 1 },
      },
    },
    meshes = {
      { id = "stat", nodeIndex = 0, materialIndex = 0, geometry = "fixtures/stat.g4mesh", center = { 1, 0, 1 } },
      { id = "bb", nodeIndex = 0, materialIndex = 0, geometry = "fixtures/bb.g4mesh", center = { 0, 1, 0 } },
    },
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
    animations = clips,
    backend = {
      program = {
        name = "mixed",
        scalingRule = 0,
        posScale = 1,
        invPosScale = 1,
        tileScale = 1 / 16,
        nodes = {
          {
            index = 0,
            matrixStackIndex = 0,
            translation = { x = 32, y = 16, z = 0 },
            rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
            scale = { x = 2, y = 1, z = 1 },
            transZero = false,
            rotZero = true,
            scaleOne = false,
          },
        },
        commands = {
          { opcode = 0x06, nodeIndex = 0, parentIndex = 0, flags = 0 },
          { opcode = 0x02, nodeIndex = 0, visible = true },
          { opcode = 0x04, materialIndex = 0 },
          { opcode = 0x05, shapeIndex = 0 },
          { opcode = 0x07, option = 0, optionBits = 0 },
          { opcode = 0x04, materialIndex = 0 },
          { opcode = 0x05, shapeIndex = 1 },
          { opcode = 0x01 },
        },
        evpMatrices = nil,
      },
      meshes = {
        stat = statState,
        bb = billboardState,
      },
    },
  })
end

-- A color clip: constant registers with alpha fading 31 -> 0 over the frames.
local function fadeClip(frames)
  local alphaKeys = {}
  for f = 0, frames - 1 do
    alphaKeys[f + 1] = math.max(0, 31 - f)
  end
  return {
    id = "fixture:fade",
    name = "fade",
    category = "material",
    kind = "color",
    frameCount = frames,
    tracks = { { target = "wall", targetIndex = 0 } },
    semanticNames = {},
    source = { type = "nitro", format = "NSBMA" },
    compiled = {
      targets = {
        {
          index = 0,
          name = "wall",
          channels = {
            diffuse = { source = "constant", value = 0x7FFF },
            ambient = { source = "constant", value = 0x4210 },
            specular = { source = "constant", value = 0x0000 },
            emission = { source = "constant", value = 0x001F },
            alpha = { source = "curve", rate = 1, limit = frames - 1, isAlpha = true, keys = alphaKeys },
          },
        },
      },
    },
  }
end

-- Reused record slots must reset every optional field each evaluation: the
-- static slot carries no billboard residue, the billboard slot matches the
-- reference component extraction, and stopping the color clip restores the
-- base material registers instead of retaining animated values.
function T.reused_slots_reset_stale_billboard_and_material_state()
  local instance = ModelInstance.new(mixedStaticBillboardDefinition({ NitroModelFixture.doorOpenClip(), fadeClip(8) }))
  local renders = { stat = {}, bb = {} }
  instance:evaluatePose()
  local warmed = instance:drawItems(renders) -- warmup establishes the stable storage
  local bindCell = warmed[1].transform[1]
  -- The bind pose is rotation-free, so snapshot its billboard components
  -- now: later evaluations overwrite the same live records.
  local bindCenter = { warmed[2].billboardCenter[1], warmed[2].billboardCenter[2], warmed[2].billboardCenter[3] }
  local bindScale = { warmed[2].billboardScale[1], warmed[2].billboardScale[2], warmed[2].billboardScale[3] }
  Assert.deepEqual(bindCenter, { 2, 1, 0 }, "the bind base carries the joint translation in tiles")
  Assert.deepEqual(bindScale, { 2, 1, 1 }, "the bind base carries the joint scale")
  instance:play("DoorOpen")
  instance:play("fade")
  for _ = 1, 3 do
    instance:updateFixed()
  end
  instance:evaluatePose()
  local items = instance:drawItems(renders)
  Assert.isTrue(items == warmed, "evaluation reuses the warmed live list")
  Assert.equal(#items, 2)
  local stat, bb = items[1], items[2]

  Assert.isNil(stat.billboardBase, "the static slot carries no billboard base")
  Assert.isNil(stat.billboardCenter, "the static slot carries no billboard center")
  Assert.isNil(stat.billboardScale, "the static slot carries no billboard scale")
  Assert.deepEqual(stat.modelNormal, Matrix3.modelNormal(stat.transform), "the static normal tracks its transform")
  Assert.isFalse(stat.transform[1] == bindCell, "the joint clip moves the shared transform")

  local refCenter, refScale = BillboardTransform.components(bb.billboardBase)
  Assert.deepEqual(bb.billboardCenter, refCenter, "the billboard center matches the reference extraction")
  Assert.deepEqual(bb.billboardScale, refScale, "the billboard scale matches the reference extraction")
  Assert.deepEqual(refCenter, { 2, 1, 0 }, "the captured base carries the joint translation in tiles")
  Assert.deepEqual(bb.modelNormal, { 1, 0, 0, 0, 1, 0, 0, 0, 1 }, "billboard draws keep the identity normal")

  Assert.isTrue(stat.material.colorsAnimated, "the color clip drives the shared material")
  Assert.isTrue(math.abs(stat.material.matAmbient[1] - 1) > 0.1, "the color clip drives the ambient register")
  Assert.isTrue(stat.material.polygonAlpha < 1.0, "the color clip fades the polygon alpha")

  instance:stop("fade")
  instance:evaluatePose()
  local reset = instance:drawItems(renders)
  Assert.isTrue(reset == items, "the material reset reuses the same live list")
  Assert.isFalse(reset[1].material.colorsAnimated, "stopping the clip clears the animation marker")
  Assert.deepEqual(reset[1].material.matDiffuse, { 1, 1, 1 }, "diffuse returns to the base register")
  Assert.deepEqual(reset[1].material.matAmbient, { 1, 1, 1 }, "ambient returns to the base register")
  Assert.near(reset[1].material.polygonAlpha, 1.0, 1e-9, "polygon alpha returns to the base value")
  Assert.isNil(reset[1].billboardCenter, "the static slot still carries no billboard state")
  local resetCenter, resetScale = BillboardTransform.components(reset[2].billboardBase)
  Assert.deepEqual(reset[2].billboardCenter, resetCenter, "the billboard center survives the material reset")
  Assert.deepEqual(reset[2].billboardScale, resetScale, "the billboard scale survives the material reset")
end

return { tests = T }
