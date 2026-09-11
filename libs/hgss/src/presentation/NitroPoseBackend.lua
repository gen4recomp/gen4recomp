-- NitroPoseBackend: the pose evaluator for models whose source is a Nitro
-- NSBMD (the "Nitro backend" of the pose contract). The effective transform
-- of a Nitro model comes from replaying its SBC draw stream -- NODEDESC
-- joint matrices, POSSCALE, MTX slot restores, NODEMIX, billboards -- over
-- the animated joint results, so the runtime cannot evaluate it from the
-- neutral IR alone; the digest side compiles that stream into the model's
-- transform program (NsbmdTransformProgram) and this backend executes it
-- with the pose provider built from the instance's joint attachments.
--
-- Sampling the attachments runs through CompiledNsbcaSampler over the
-- clips' compiled payloads (NsbcaClipCompiler, digest side) -- the runtime
-- never touches NSBCA bytes -- then the per-node results blend through
-- JointAnimBlend and compose into SRT records via NitroJointState, the
-- same steps the digest-side NsbcaPoseProvider follows over raw decodes.
--
-- The output is the PoseState: per-node matrices and visibility plus
-- per-mesh draw transforms -- a Nitro draw is not one node matrix, so every
-- dynamic mesh carries the matrix its transform source resolves to.
--
-- Geometry is compiled once; only these matrices change per frame. Pure
-- domain module.

---@class PoseState
---@field nodeMatrices { [integer]: number[] } -- [nodeIndex] = world matrix (model space)
---@field nodeVisible { [integer]: boolean } -- absent means visible
---@field drawMatrices { [string]: PoseDrawMatrix } -- per mesh id
---@field matrixSlots { [integer]: number[] } -- the matrix-stack slots as of
--  the end of the replay, tile space (engine units)

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local ErrorCodes = require("libs.assets.src.ErrorCodes")
local FixedPoint = require("libs.math.src.FixedPoint")
local AnimationClip = require("libs.assets.src.model.AnimationClip")
local JointAnimBlend = require("libs.nds.src.nitro.g3d.JointAnimBlend")
local NitroJointState = require("libs.nds.src.nitro.g3d.NitroJointState")
local CompiledNsbcaSampler = require("libs.nds.src.nitro.g3d.CompiledNsbcaSampler")
local NsbmdSbcEvaluator = require("libs.assets.src.model.NsbmdSbcEvaluator")
local PoseContract = require("libs.assets.src.model.PoseContract")
local Matrix4 = require("libs.math.src.Matrix4")

local NitroPoseBackend = {}

---@class NitroPoseBackend.Scratch
---@field program table<string, unknown> -- the compiled transform program this scratch is sized from
---@field tileScale number
---@field sbc NsbmdSbcEvaluator.Scratch -- evaluator-owned replay storage
---@field pose PoseState -- the live pose, aliasing only scratch-owned tables
---@field provider NsbmdSbcEvaluator.PoseProvider -- stable provider reading the current sample table
---@field _srt table<integer, table<string, unknown>> -- the current sampled node records
---@field _nodePool table<integer, number[]> -- retained node-matrix tables
---@field _slotPool table<integer, number[]> -- retained matrix-slot tables
---@field _bases table<string, number[]> -- retained billboard-base tables by mesh id
---@field _nodeByMesh table<string, integer> -- mesh id to node index, fixed by the definition

-- Convert a draw matrix to engine units into an existing 16-number table:
-- only the translation column divides by the tile size (the uniform model-to-tile scale).
---@param out number[]
---@param m number[]
---@param tileScale number
---@return number[]
local function toTilesInto(out, m, tileScale)
  for i = 1, 12 do
    out[i] = m[i]
  end
  out[13], out[14], out[15] = m[13] * tileScale, m[14] * tileScale, m[15] * tileScale
  out[16] = m[16]
  return out
end

-- The linear part of a 4x4 into an existing 16-number table (translation
-- zeroed): the matrix a direction vector transforms by.
---@param out number[]
---@param m number[]
---@return number[]
local function linearInto(out, m)
  out[1], out[2], out[3], out[4] = m[1], m[2], m[3], 0
  out[5], out[6], out[7], out[8] = m[5], m[6], m[7], 0
  out[9], out[10], out[11], out[12] = m[9], m[10], m[11], 0
  out[13], out[14], out[15], out[16] = 0, 0, 0, 1
  return out
end

---@param pool table<integer, number[]>
---@param live table<integer, number[]>
---@param key integer
---@return number[]
local function reusablePooled(pool, live, key)
  local m = pool[key]
  if not m then
    m = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
    pool[key] = m
  end
  live[key] = m
  return m
end

-- The effective per-node SRT records from the instance's joint attachments:
-- sampling + blending per node, with channels the clips leave to the model
-- resolved against the program's bind SRTs. Attach rejects a second
-- same-kind clip, so at most one joint clip plays; the blend still runs
-- through JointAnimBlend with the full default ratio (the multi-attachment
-- blend was cut with same-kind stacking, so it always takes its
-- single-contributor shortcut).
local function nodeSrt(program, attachments, out)
  for key in pairs(out) do
    out[key] = nil
  end
  for _, attachment in ipairs(attachments) do
    local clip = attachment.clip
    if not clip.compiled then
      Errors.raise(
        FieldErrors.POSE_NITRO_JOINT_CLIP_NOT_COMPILED,
        "joint clip "
          .. clip.id
          .. " on model "
          .. program.name
          .. " is not a compiled NSBCA clip; the Nitro backend cannot sample it",
        { clip = clip.id, model = program.name }
      )
    end
    for _, track in ipairs(clip.tracks) do
      local nodeIndex = attachment.binding.map[track.target]
      -- Targets that name nodes the program does not carry are ignored,
      -- like the digest-side provider's permissive binding.
      if nodeIndex ~= nil and program.nodes[nodeIndex + 1] then
        local result = assert(CompiledNsbcaSampler.sample(clip, track.targetIndex, attachment.player.frameFx))
        local blended = assert(JointAnimBlend.blend({ { ratio = FixedPoint.FX32_SCALE, result = result } }))
        out[nodeIndex] = NitroJointState.srtFromBlend(blended, program.nodes[nodeIndex + 1])
      end
    end
  end
  return out
end

-- The identity matrix shared as a read-only conversion source (never mutated).
local IDENTITY_MATRIX = Matrix4.identity()

-- Resolve one mesh's position matrix against its draw record into `out`. A nil source
-- (baked billboard segments) resolves to identity; a source naming a
-- matrix-stack slot the draw's restore-stack snapshot does not hold is a
-- broken compiled transform program and raises (drawing identity instead
-- would silently misplace the geometry).
---@param draw SbcDraw
---@param source DrawSource|nil
---@param tileScale number
---@param modelKey string
---@param out number[]
---@return number[] -- 16-element column-major matrix, engine units
local function resolvePositionInto(draw, source, tileScale, modelKey, out)
  if source == PoseContract.DRAW then
    return toTilesInto(out, draw.matrix, tileScale)
  end
  if source == nil then
    return toTilesInto(out, IDENTITY_MATRIX, tileScale)
  end
  local slot = draw.restoreStack[source.slot]
  if not slot then
    Errors.raise(
      ErrorCodes.POSE_NITRO_SLOT_NOT_FOUND,
      "mesh transform source names matrix-stack slot " .. tostring(source.slot) .. " the draw does not hold",
      { slot = source.slot, model = modelKey }
    )
  end
  return toTilesInto(out, slot, tileScale)
end

-- The definition's program, or raise the missing-program diagnostic.
---@param definition table<string, unknown>
---@return table<string, unknown>
local function requireProgram(definition)
  local backend = definition.backend
  if not backend or not backend.program then
    Errors.raise(
      FieldErrors.POSE_NITRO_NO_TRANSFORM_PROGRAM,
      "model " .. definition.key .. " has no compiled transform program in its backend payload",
      { modelKey = definition.key }
    )
  end
  return backend.program
end

-- Owner-held reusable pose storage for one model definition: the evaluator
-- scratch plus the live pose tables. Warmed evaluations only overwrite
-- numbers, so repeated frames reuse every pose container.
---@param definition table<string, unknown>
---@return NitroPoseBackend.Scratch
function NitroPoseBackend.newScratch(definition)
  assert(
    type(definition) == "table" and definition.key ~= nil,
    "NitroPoseBackend.newScratch requires a model definition"
  )
  local program = requireProgram(definition)
  local backend = definition.backend
  local scratch = {
    program = program,
    tileScale = program.tileScale,
    sbc = NsbmdSbcEvaluator.newScratch(program),
    pose = {
      nodeMatrices = {},
      nodeVisible = {},
      drawMatrices = {},
      matrixSlots = {},
    },
    provider = {},
    _srt = {},
    _nodePool = {},
    _slotPool = {},
    _bases = {},
    _nodeByMesh = {},
  }
  local function nodeSRT(nodeIndex)
    return scratch._srt[nodeIndex]
  end
  scratch.provider = {
    nodeSRT = nodeSRT,
  }
  for _, mesh in ipairs(definition.meshes or {}) do
    scratch._nodeByMesh[mesh.id] = mesh.nodeIndex
  end
  for meshId, mesh in pairs(backend.meshes or {}) do
    scratch.pose.drawMatrices[meshId] = {
      position = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
      direction = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
      transformMode = mesh.transformMode,
      baseTransform = nil,
    }
  end
  return scratch
end

-- Evaluate `instance` into its scratch-owned live pose. Joint attachments
-- drive the program; material attachments do not affect the pose. Every
-- optional field is overwritten or cleared each evaluation, so no previous
-- frame contribution survives an animation stopping. Returns the same pose
-- containers on every call while the mesh set is unchanged.
---@param instance table<string, unknown>
---@param scratch NitroPoseBackend.Scratch
---@return PoseState
function NitroPoseBackend.evaluateInto(instance, scratch)
  assert(
    type(instance) == "table" and instance.definition ~= nil,
    "NitroPoseBackend.evaluateInto requires a model instance"
  )
  assert(type(scratch) == "table" and scratch.pose ~= nil, "NitroPoseBackend.evaluateInto requires pose scratch")
  local def = instance.definition
  local program = requireProgram(def)
  local tileScale = program.tileScale

  nodeSrt(program, instance.animationState:attachments(AnimationClip.CATEGORIES.joint), scratch._srt)
  local result = NsbmdSbcEvaluator.evaluateInto(program, scratch.provider, scratch.sbc)

  local pose = scratch.pose
  for key in pairs(pose.nodeVisible) do
    pose.nodeVisible[key] = nil
  end
  for nodeIndex, visible in pairs(result.nodeVisibility) do
    if visible == false then
      pose.nodeVisible[nodeIndex] = false
    end
  end

  for key in pairs(pose.nodeMatrices) do
    pose.nodeMatrices[key] = nil
  end
  for nodeIndex, m in pairs(result.nodeMatrices) do
    local cell = reusablePooled(scratch._nodePool, pose.nodeMatrices, nodeIndex)
    for i = 1, 16 do
      cell[i] = m[i]
    end
  end

  local backend = def.backend
  local nodeByMesh = scratch._nodeByMesh
  for meshId, mesh in pairs(backend.meshes or {}) do
    local draw = result.draws[mesh.drawIndex + 1]
    if not draw then
      -- A mesh whose node is hidden this frame has no draw in the filtered
      -- list even though the program produces it: it carries an identity
      -- placeholder the draw path skips over (hidden meshes are never
      -- drawn). A missing draw on a visible node is a broken compiled
      -- program and still raises.
      if result.nodeVisibility[nodeByMesh[meshId]] ~= false then
        Errors.raise(
          FieldErrors.POSE_NITRO_DRAW_MISSING,
          "dynamic mesh "
            .. meshId
            .. " references draw "
            .. tostring(mesh.drawIndex)
            .. " which the program does not produce",
          { meshId = meshId, drawIndex = mesh.drawIndex, model = def.key }
        )
      end
    end
    local record = pose.drawMatrices[meshId]
    if not record then
      record = {
        position = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
        direction = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
        transformMode = mesh.transformMode,
        baseTransform = nil,
      }
      pose.drawMatrices[meshId] = record
    end
    if draw then
      resolvePositionInto(draw, mesh.positionSource, tileScale, def.key, record.position)
      linearInto(record.direction, record.position)
    else
      toTilesInto(record.position, IDENTITY_MATRIX, tileScale)
      linearInto(record.direction, record.position)
    end
    record.transformMode = mesh.transformMode
    if record.transformMode == PoseContract.BILLBOARD then
      if draw then
        local base = scratch._bases[meshId]
        if not base then
          base = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
          scratch._bases[meshId] = base
        end
        record.baseTransform =
          toTilesInto(base, assert(draw.baseTransform, "billboard draw carries no captured base transform"), tileScale)
      else
        record.baseTransform = nil
      end
    else
      record.baseTransform = nil
    end
  end

  for key in pairs(pose.matrixSlots) do
    pose.matrixSlots[key] = nil
  end
  for slot, m in pairs(result.matrixSlots or {}) do
    toTilesInto(reusablePooled(scratch._slotPool, pose.matrixSlots, slot), m, tileScale)
  end

  return pose
end

-- Evaluate `instance` into an independent PoseState snapshot: later
-- evaluations never mutate it. See evaluateInto for the reused-storage path.
-- The definition is nitro by construction (there is no sourceBackend abstraction;
-- this backend IS the direct pose path).
---@param instance table<string, unknown>
---@return PoseState
function NitroPoseBackend.evaluate(instance)
  local scratch = NitroPoseBackend.newScratch(instance.definition)
  local live = NitroPoseBackend.evaluateInto(instance, scratch)
  local function snapshotMatrix(m)
    local out = {}
    for i = 1, 16 do
      out[i] = m[i]
    end
    return out
  end
  local nodeVisible = {}
  for nodeIndex, visible in pairs(live.nodeVisible) do
    nodeVisible[nodeIndex] = visible
  end
  local nodeMatrices = {}
  for nodeIndex, m in pairs(live.nodeMatrices) do
    nodeMatrices[nodeIndex] = snapshotMatrix(m)
  end
  local drawMatrices = {}
  for meshId, record in pairs(live.drawMatrices) do
    drawMatrices[meshId] = {
      position = snapshotMatrix(record.position),
      direction = snapshotMatrix(record.direction),
      transformMode = record.transformMode,
      baseTransform = record.baseTransform and snapshotMatrix(record.baseTransform) or nil,
    }
  end
  local matrixSlots = {}
  for slot, m in pairs(live.matrixSlots) do
    matrixSlots[slot] = snapshotMatrix(m)
  end
  return {
    nodeMatrices = nodeMatrices,
    nodeVisible = nodeVisible,
    drawMatrices = drawMatrices,
    matrixSlots = matrixSlots,
  }
end

return NitroPoseBackend
