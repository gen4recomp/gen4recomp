-- Tests for NitroPoseBackend: executing the compiled transform program with
-- the pose provider built from compiled NSBCA clips. Programs and clips are
-- hand-built plain data (no NSBMD/NSBCA bytes), so the backend is exercised
-- at the engine boundary; the digest side compiles the same shapes from
-- decoded assets (NsbmdDynamicModel / NsbcaClipCompiler) and the
-- cross-check tests keep the samplers bit-identical.

local Assert = require("tests.support.Assert")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local NitroPoseBackend = require("libs.hgss.src.presentation.NitroPoseBackend")
local ErrorCodes = require("libs.assets.src.ErrorCodes")

local T = {}

local EPS = 1e-9

local function identity9()
  return { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
end

-- ---- fixtures ----

local function bindNode(index, opts)
  opts = opts or {}
  return {
    index = index,
    matrixStackIndex = opts.matrixStackIndex or 0,
    translation = opts.translation or { x = 0, y = 0, z = 0 },
    rotation = opts.rotation or identity9(),
    scale = opts.scale or { x = 1, y = 1, z = 1 },
    inverseScale = opts.inverseScale,
    transZero = opts.transZero ~= false,
    rotZero = opts.rotZero ~= false,
    scaleOne = opts.scaleOne ~= false,
  }
end

local function program(nodes, commands)
  return {
    name = "test",
    scalingRule = 0,
    posScale = 1,
    invPosScale = 1,
    tileScale = 1 / 16,
    nodes = nodes,
    commands = commands,
    evpMatrices = nil,
  }
end

local function drawCommands()
  return {
    { opcode = 0x06, nodeIndex = 0, parentIndex = 0, flags = 0 },
    { opcode = 0x02, nodeIndex = 0, visible = true },
    { opcode = 0x04, materialIndex = 0 },
    { opcode = 0x05, shapeIndex = 0 },
    { opcode = 0x01 },
  }
end

-- A compiled clip: constant translation (160, 0, 0) in fx32 words (10,0,0
-- model units), rotation and scale from the model.
local function transConstClip()
  return {
    id = "fixture:trans",
    name = "trans",
    category = "joint",
    kind = "trs",
    frameCount = 8,
    tracks = { { target = 0, targetIndex = 0 } },
    semanticNames = {},
    source = { type = "nitro", format = "NSBCA" },
    compiled = {
      anmFlags = 0,
      rotData = {},
      pivotData = {},
      targets = {
        {
          nodeIndex = 0,
          channels = {
            trans = {
              x = { source = "constant", value = 10 * 4096 },
              y = { source = "constant", value = 0 },
              z = { source = "constant", value = 0 },
            },
            rot = { source = "model" },
            scale = {
              x = { source = "model" },
              y = { source = "model" },
              z = { source = "model" },
            },
          },
        },
      },
    },
  }
end

local function singleMeshDefinition(overrides)
  overrides = overrides or {}
  local def = ModelDefinition.new({
    key = "fixture:nitro",
    nodes = {
      {
        index = 0,
        name = "root",
        translation = { x = 0, y = 0, z = 0 },
        rotation = identity9(),
        scale = { x = 1, y = 1, z = 1 },
      },
    },
    meshes = {
      {
        id = "draw0.seg0",
        nodeIndex = 0,
        materialIndex = 0,
        geometry = "fixtures/draw0.seg0.g4mesh",
        center = { 1, 0, 1 },
      },
    },
    materials = {
      {
        id = 0,
        name = "mat0",
        baseColor = { r = 255, g = 255, b = 255, a = 255 },
        alphaMode = "opaque",
        doubleSided = false,
        polygonAlpha = 31,
        texMtxMode = 0,
        texWidth = 0,
        texHeight = 0,
      },
    },
    skins = {},
    animations = overrides.animations or { transConstClip() },
    backend = {
      program = overrides.program or program({ bindNode(0) }, drawCommands()),
      meshes = overrides.meshes or {
        ["draw0.seg0"] = {
          drawIndex = 0,
          positionSource = "draw",
          transformMode = "static",
          cullMode = "back",
          polygonMode = "modulation",
          polygonId = 0,
          lightMask = 5,
          translucentDepthWrite = false,
          depthEqual = false,
          polygonAlpha = 31,
        },
      },
    },
  })
  return def
end

local function newInstance(def)
  local instance = ModelInstance.new(def)
  return instance
end

-- ---- evaluation ----

function T.animated_translation_reaches_the_draw_matrix()
  local instance = newInstance(singleMeshDefinition())
  instance:play("trans")
  instance:updateFixed() -- frame 1
  instance:evaluatePose()
  local draw = instance.poseState.drawMatrices["draw0.seg0"]
  Assert.notNil(draw)
  Assert.equal(draw.transformMode, "static")
  -- The clip's constant translation is 10 model units; the draw matrix is
  -- in engine units (tile scale 1/16).
  Assert.equal(draw.position[13], 10 / 16)
  Assert.equal(draw.direction[1], 1)
  -- The definition's single mesh item composes the instance transform.
  local items = instance:drawItems({ ["draw0.seg0"] = {} })
  Assert.equal(items[1].transform[13], 10 / 16)
end

-- A rotation clip (pivot form, A = 1, B = 0 at key 0; A = 15/16, B = 1/16
-- at key 1) over two frames.
local function rotationClip()
  return {
    id = "fixture:rot",
    name = "rot",
    category = "joint",
    kind = "trs",
    frameCount = 3,
    tracks = { { target = 0, targetIndex = 0 } },
    semanticNames = {},
    source = { type = "nitro", format = "NSBCA" },
    compiled = {
      anmFlags = 0,
      rotData = {
        { control = 0x0024, a = 4096, b = 0 },
        { control = 0x0024, a = 3840, b = 256 },
        { control = 0x0024, a = 3584, b = 512 },
      },
      pivotData = {},
      targets = {
        {
          nodeIndex = 0,
          channels = {
            trans = {
              x = { source = "model" },
              y = { source = "model" },
              z = { source = "model" },
            },
            rot = {
              source = "curve",
              rate = 1,
              limit = 3,
              storage = "fx16",
              keys = { 0x8000, 0x8001, 0x8002 },
            },
            scale = {
              x = { source = "model" },
              y = { source = "model" },
              z = { source = "model" },
            },
          },
        },
      },
    },
  }
end

function T.pose_scrubs_with_the_player()
  local instance = newInstance(singleMeshDefinition({
    animations = { rotationClip() },
  }))
  instance:play("rot")
  instance:updateFixed() -- frame 1
  instance:evaluatePose()
  -- The pose is a live view overwritten by each evaluation, so capture the
  -- number before advancing: retaining the table would observe frame 2.
  local frame1 = instance.poseState.drawMatrices["draw0.seg0"].position[1]
  instance:updateFixed() -- frame 2
  instance:evaluatePose()
  local frame2 = instance.poseState.drawMatrices["draw0.seg0"].position[1]
  -- The rotation cells differ between the two frames (A = 15/16 vs 14/16).
  Assert.isTrue(math.abs(frame1 - frame2) > EPS, "different frames resolve different draws")
end

function T.rotation_clip_changes_the_draw_matrix()
  local instance = newInstance(singleMeshDefinition({
    animations = { rotationClip() },
  }))
  instance:play("rot")
  instance:updateFixed() -- frame 1
  instance:evaluatePose()
  local draw = instance.poseState.drawMatrices["draw0.seg0"]
  -- Frame 1: A = 15/16, B = 1/16 -> the matrix maps (1,0,0) toward z.
  Assert.isTrue(math.abs(draw.position[1] - 15 / 16) < EPS, "A in the draw matrix")
  Assert.isTrue(math.abs(draw.position[3] - 1 / 16) < EPS, "B in the draw matrix")
end

function T.from_model_channels_fall_back_to_the_bind_srt()
  local bind = bindNode(0, { translation = { x = 3, y = 0, z = 0 } })
  local instance = newInstance(singleMeshDefinition({
    program = program({ bind }, drawCommands()),
    animations = { rotationClip() }, -- trans from the model
  }))
  instance:play("rot")
  instance:updateFixed()
  instance:evaluatePose()
  local draw = instance.poseState.drawMatrices["draw0.seg0"]
  -- Bind translation (3,0,0) survives the pose (tile scale 1/16).
  Assert.equal(draw.position[13], 3 / 16)
end

function T.billboard_draws_report_the_captured_base()
  local commands = {
    { opcode = 0x06, nodeIndex = 0, parentIndex = 0, flags = 0 },
    { opcode = 0x02, nodeIndex = 0, visible = true },
    { opcode = 0x07, option = 0, optionBits = 0 },
    { opcode = 0x04, materialIndex = 0 },
    { opcode = 0x05, shapeIndex = 0 },
    { opcode = 0x01 },
  }
  local bind = bindNode(0, { translation = { x = 160, y = 0, z = 0 }, transZero = false })
  local instance = newInstance(singleMeshDefinition({
    program = program({ bind }, commands),
    meshes = {
      ["draw0.seg0"] = {
        drawIndex = 0,
        positionSource = nil,
        transformMode = "billboard",
        cullMode = "back",
        polygonMode = "modulation",
        polygonId = 0,
        lightMask = 5,
        translucentDepthWrite = false,
        depthEqual = false,
        polygonAlpha = 31,
      },
    },
  }))
  instance:evaluatePose()
  local draw = instance.poseState.drawMatrices["draw0.seg0"]
  Assert.equal(draw.transformMode, "billboard")
  -- The captured base is the node matrix (160,0,0) model units -> tiles.
  Assert.equal(draw.baseTransform[13], 160 / 16)
  local items = instance:drawItems({ ["draw0.seg0"] = {} })
  Assert.notNil(items[1].billboardBase)
  Assert.equal(items[1].billboardBase[13], 160 / 16)
  Assert.deepEqual(items[1].billboardCenter, { 160 / 16, 0, 0 })
  Assert.deepEqual(items[1].billboardScale, { 1, 1, 1 })
  Assert.deepEqual(items[1].modelNormal, identity9())
  local nextItems = instance:drawItems({ ["draw0.seg0"] = {} })
  Assert.equal(items[1].modelNormal, nextItems[1].modelNormal, "billboards share one identity normal")
end

function T.restore_slot_sources_resolve_from_the_draw_snapshot()
  -- Two nodes; the second draw restores slot 1 (node 1's matrix).
  local commands = {
    { opcode = 0x06, nodeIndex = 0, parentIndex = 0, flags = 0 },
    { opcode = 0x06, nodeIndex = 1, parentIndex = 1, flags = 0 },
    { opcode = 0x03, matrixSlot = 1 },
    { opcode = 0x04, materialIndex = 0 },
    { opcode = 0x05, shapeIndex = 0 },
    { opcode = 0x01 },
  }
  local p = program({
    bindNode(0, { matrixStackIndex = 0, translation = { x = 16, y = 0, z = 0 }, transZero = false }),
    bindNode(1, { matrixStackIndex = 1, translation = { x = 0, y = 32, z = 0 }, transZero = false }),
  }, commands)
  local def = ModelDefinition.new({
    key = "fixture:nitro-slot",
    nodes = {
      {
        index = 0,
        name = "a",
        translation = { x = 0, y = 0, z = 0 },
        rotation = identity9(),
        scale = { x = 1, y = 1, z = 1 },
      },
      {
        index = 1,
        name = "b",
        translation = { x = 0, y = 0, z = 0 },
        rotation = identity9(),
        scale = { x = 1, y = 1, z = 1 },
      },
    },
    meshes = {
      {
        id = "m",
        nodeIndex = 1,
        materialIndex = 0,
        geometry = "fixtures/draw0.seg0.g4mesh",
      },
    },
    materials = {
      {
        id = 0,
        name = "mat0",
        baseColor = { r = 255, g = 255, b = 255, a = 255 },
        alphaMode = "opaque",
        doubleSided = false,
      },
    },
    skins = {},
    animations = {},
    backend = {
      program = p,
      meshes = {
        m = {
          drawIndex = 0,
          positionSource = { slot = 1 },
          transformMode = "static",
          cullMode = "back",
          polygonMode = "modulation",
          polygonId = 0,
          lightMask = 5,
          translucentDepthWrite = false,
          depthEqual = false,
          polygonAlpha = 31,
        },
      },
    },
  })
  local instance = newInstance(def)
  instance:evaluatePose()
  local draw = instance.poseState.drawMatrices["m"]
  -- Slot 1 holds node 1's matrix (0,32,0) model units -> (0,2,0) tiles.
  Assert.equal(draw.position[14], 2)
end

-- Compiled straddle provenance is dormant presentation data. Evaluation must
-- not resolve it when the current draw source is valid.
function T.dormant_straddle_source_is_not_resolved()
  -- Draw 0 carries node 0's matrix (16,0,0 model units -> 1,0,0 tiles) via
  -- the MTX slot reselect, and the restoreStack snapshot keeps node 1's
  -- matrix in slot 1 (0,32,0 -> 0,2,0 tiles).
  local commands = {
    { opcode = 0x06, nodeIndex = 0, parentIndex = 0, flags = 0 },
    { opcode = 0x06, nodeIndex = 1, parentIndex = 1, flags = 0 },
    { opcode = 0x03, matrixSlot = 0 },
    { opcode = 0x04, materialIndex = 0 },
    { opcode = 0x05, shapeIndex = 0 },
    { opcode = 0x01 },
  }
  local p = program({
    bindNode(0, { matrixStackIndex = 0, translation = { x = 16, y = 0, z = 0 }, transZero = false }),
    bindNode(1, { matrixStackIndex = 1, translation = { x = 0, y = 32, z = 0 }, transZero = false }),
  }, commands)
  local def = ModelDefinition.new({
    key = "fixture:nitro-straddle",
    nodes = {
      {
        index = 0,
        name = "a",
        translation = { x = 0, y = 0, z = 0 },
        rotation = identity9(),
        scale = { x = 1, y = 1, z = 1 },
      },
      {
        index = 1,
        name = "b",
        translation = { x = 0, y = 0, z = 0 },
        rotation = identity9(),
        scale = { x = 1, y = 1, z = 1 },
      },
    },
    meshes = {
      {
        id = "m",
        nodeIndex = 0,
        materialIndex = 0,
        geometry = "fixtures/draw0.seg0.g4mesh",
        center = { 1, 0, 1 },
      },
    },
    materials = {
      {
        id = 0,
        name = "mat0",
        baseColor = { r = 255, g = 255, b = 255, a = 255 },
        alphaMode = "opaque",
        doubleSided = false,
        polygonAlpha = 31,
        texMtxMode = 0,
        texWidth = 0,
        texHeight = 0,
      },
    },
    skins = {},
    animations = {},
    backend = {
      program = p,
      meshes = {
        m = {
          drawIndex = 0,
          positionSource = "draw",
          straddle = { leading = 2, source = { slot = 9 } },
          transformMode = "static",
          cullMode = "back",
          polygonMode = "modulation",
          polygonId = 0,
          lightMask = 5,
          translucentDepthWrite = false,
          depthEqual = false,
          polygonAlpha = 31,
        },
      },
    },
  })
  local instance = newInstance(def)
  instance:evaluatePose()
  local draw = instance.poseState.drawMatrices["m"]
  -- The mesh's own source resolves the draw matrix (node 0: 16,0,0 -> 1,0,0
  -- tiles).
  Assert.equal(draw.position[13], 1)
  Assert.isNil(rawget(draw, "straddle"))
  Assert.isTrue(def.backend.meshes.m.straddle ~= nil, "compiled provenance remains")
  local items = instance:drawItems({ m = {} })
  Assert.equal(items[1].transform[13], 1)
  Assert.deepEqual(items[1].modelNormal, identity9())
  local nextItems = instance:drawItems({ m = {} })
  Assert.equal(items[1].modelNormal, nextItems[1].modelNormal, "translation-only draws share the identity normal")

  -- With valid dormant provenance, the evaluated contract remains the same:
  -- current pose data is present, but no per-frame split is published.
  def.backend.meshes.m.straddle.source = { slot = 1 }
  local validInstance = newInstance(def)
  validInstance:evaluatePose()
  local validDraw = validInstance.poseState.drawMatrices["m"]
  Assert.equal(validDraw.position[13], 1)
  Assert.isNil(rawget(validDraw, "straddle"))
  Assert.isTrue(def.backend.meshes.m.straddle ~= nil, "compiled provenance remains")
end

-- The pose guard is defense in depth: the artifact gate rejects a serialized
-- clip without a compiled payload, but a definition assembled directly (a
-- hand-built IR record) can still carry one, so the pose backend raises
-- instead of pretending to animate it.
function T.uncompiled_joint_clips_raise()
  local clip = {
    id = "generic",
    name = "generic",
    category = "joint",
    kind = "trs",
    frameCount = 2,
    tracks = { { target = 0 } },
    semanticNames = {},
    source = { type = "nitro", format = "NSBCA" },
  }
  local def = singleMeshDefinition({ animations = { clip } })
  local instance = newInstance(def)
  instance.animationState:attach(clip)
  local err = Assert.throws(function()
    instance:evaluatePose()
  end)
  Assert.equal(err.code, "POSE_NITRO_JOINT_CLIP_NOT_COMPILED")
end

-- A slot-source mesh naming a slot the program never wrote is a broken
-- compiled transform program: the draw's restore-stack snapshot cannot
-- resolve it, and drawing identity instead would silently misplace the
-- geometry. Only a nil source (baked billboard segments) resolves to
-- identity.
function T.slot_source_naming_an_unproduced_slot_raises()
  local def = singleMeshDefinition({
    meshes = {
      ["draw0.seg0"] = {
        drawIndex = 0,
        positionSource = { slot = 5 },
        transformMode = "static",
        cullMode = "back",
        polygonMode = "modulation",
        polygonId = 0,
        translucentDepthWrite = false,
        depthEqual = false,
        polygonAlpha = 31,
      },
    },
  })
  local instance = newInstance(def)
  local err = Assert.throws(function()
    instance:evaluatePose()
  end)
  Assert.equal(err.code, ErrorCodes.POSE_NITRO_SLOT_NOT_FOUND)
  Assert.equal(err.context.slot, 5)
end

function T.mesh_referencing_an_absent_draw_raises()
  local def = singleMeshDefinition({
    meshes = {
      ["draw0.seg0"] = {
        drawIndex = 7,
        positionSource = "draw",
        transformMode = "static",
        cullMode = "back",
        polygonMode = "modulation",
        polygonId = 0,
        translucentDepthWrite = false,
        depthEqual = false,
        polygonAlpha = 31,
      },
    },
  })
  local instance = newInstance(def)
  local err = Assert.throws(function()
    instance:evaluatePose()
  end)
  Assert.equal(err.code, "POSE_NITRO_DRAW_MISSING")
end

function T.clip_targets_without_definition_nodes_are_ignored()
  -- A clip that binds no definition node is rejected at play() time
  -- (ANIM_STATE_ZERO_BINDING), so the backend's permissive binding never
  -- sees an unmapped target: the play guard is the contract.
  local clip = transConstClip()
  clip.tracks = { { target = 1, targetIndex = 0 } }
  local instance = newInstance(singleMeshDefinition({ animations = { clip } }))
  local err = Assert.throws(function()
    instance:play("trans")
  end)
  Assert.equal(err.code, "ANIM_STATE_ZERO_BINDING")
end

function T.two_instances_animate_independently()
  local def = singleMeshDefinition()
  local a, b = newInstance(def), newInstance(def)
  a:play("trans")
  a:updateFixed()
  a:updateFixed() -- frame 2
  a:evaluatePose()
  b:evaluatePose()
  Assert.equal(a.poseState.drawMatrices["draw0.seg0"].position[13], 10 / 16)
  Assert.equal(b.poseState.drawMatrices["draw0.seg0"].position[13], 0)
end

-- The pose exposes the matrix-stack slots as of the end of the replay, in
-- engine units like the draw matrices (the matrix-slot visualization reads
-- them).
function T.pose_reports_the_matrix_slot_stack_in_tiles()
  local commands = {
    { opcode = 0x06, nodeIndex = 0, parentIndex = 0, flags = 0 },
    { opcode = 0x06, nodeIndex = 1, parentIndex = 1, flags = 0 },
    { opcode = 0x04, materialIndex = 0 },
    { opcode = 0x05, shapeIndex = 0 },
    { opcode = 0x01 },
  }
  local p = program({
    bindNode(0, { matrixStackIndex = 0, translation = { x = 16, y = 0, z = 0 }, transZero = false }),
    bindNode(1, { matrixStackIndex = 1, translation = { x = 0, y = 32, z = 0 }, transZero = false }),
  }, commands)
  local def = singleMeshDefinition({ program = p, animations = {} })
  local instance = newInstance(def)
  instance:evaluatePose()
  -- Slot 1 holds node 1's matrix (0,32,0) model units -> (0,2,0) tiles.
  Assert.equal(instance.poseState.matrixSlots[1][14], 2)
  Assert.equal(instance.poseState.matrixSlots[1][13], 0)
  Assert.equal(instance.poseState.matrixSlots[0][13], 1, "slot 0 holds node 0 at (1,0,0) tiles")
end

local function snapshotNumbers(m)
  local out = {}
  for i = 1, #m do
    out[i] = m[i]
  end
  return out
end

-- The in-place pose path reuses caller-owned storage with identical values:
-- repeated evaluations keep the same pose/draw containers while their
-- contents track the current frame, and stopping the clip resets the pose
-- to the bind state instead of retaining animated values.
function T.evaluate_into_reuses_pose_storage_with_identical_values()
  Assert.equal(type(NitroPoseBackend.newScratch), "function", "the backend owns reusable pose storage")
  Assert.equal(type(NitroPoseBackend.evaluateInto), "function", "the backend evaluates into caller scratch")
  local def = singleMeshDefinition()
  local instance = newInstance(def)
  instance:play("trans")
  instance:updateFixed()
  local scratch = NitroPoseBackend.newScratch(def)
  local live = NitroPoseBackend.evaluateInto(instance, scratch)
  local draw = assert(live.drawMatrices["draw0.seg0"])
  Assert.equal(draw.position[13], 10 / 16)

  local reference = NitroPoseBackend.evaluate(instance)
  local refDraw = assert(reference.drawMatrices["draw0.seg0"])
  Assert.deepEqual(snapshotNumbers(draw.position), snapshotNumbers(refDraw.position))
  Assert.deepEqual(snapshotNumbers(draw.direction), snapshotNumbers(refDraw.direction))
  Assert.deepEqual(snapshotNumbers(live.nodeMatrices[0]), snapshotNumbers(reference.nodeMatrices[0]))
  Assert.deepEqual(snapshotNumbers(live.matrixSlots[0]), snapshotNumbers(reference.matrixSlots[0]))

  local position = draw.position
  instance:updateFixed()
  local again = NitroPoseBackend.evaluateInto(instance, scratch)
  Assert.isTrue(again == live, "repeated evaluation reuses the same pose containers")
  Assert.isTrue(again.drawMatrices["draw0.seg0"] == draw, "draw records keep their identity")
  Assert.isTrue(draw.position == position, "draw matrices keep their identity")

  instance:stop("trans")
  local reset = NitroPoseBackend.evaluateInto(instance, scratch)
  Assert.isTrue(reset == live, "the reset reuses the same pose containers")
  Assert.equal(reset.drawMatrices["draw0.seg0"].position[13], 0, "stopping the clip restores the bind pose")
  Assert.isNil(reset.nodeVisible[0], "no stale visibility survives the reset")
end

return { tests = T }
