-- NitroJointState: the composition step between a blended Nitro joint result
-- and the SRT record the SBC evaluator consumes.
--
-- Nsbca.sample / CompiledNsbcaSampler produce per-target results; several
-- attachments are combined per node by JointAnimBlend into one
-- NNSG3dAnmResult. That result still speaks Nitro fixed point: channels the
-- result leaves "from model" (the result's flag bits) must resolve against
-- the node's bind SRT, and the sampled channels are fx32 integers that must
-- become the float SRT the evaluator and NsbmdJointTransforms expect (one
-- unit = 0x1000, the same fixed-point step the model nodes are decoded
-- with).
--
-- The produced SRT record keeps the decoded-node shape (translation,
-- rotation, scale, inverseScale, transZero, rotZero, scaleOne,
-- matrixStackIndex) so a pose provider can hand it straight to
-- NsbmdSbcEvaluator; every component is emitted, since an animated channel
-- is never structurally absent. Pure domain module.

local JointAnimBlend = require("libs.nds.src.nitro.g3d.JointAnimBlend")

local NitroJointState = {}

-- One fixed-point unit: fx32 words are 1.M.12 (4096 per unit), the same
-- step the model nodes are decoded with.
local FX_UNIT = 4096

local F = JointAnimBlend.FROM_MODEL

local function fromModel(flags, bit)
  return math.floor(flags / bit) % 2 == 1
end

-- Result values are raw two's-complement fx32 words (the asm's wrapped
-- registers), so a negative value arrives as a large unsigned number.
local function wrap32(v)
  local p = v % 4294967296
  if p >= 2147483648 then
    p = p - 4294967296
  end
  return p
end

local function fxToFloat(v)
  return wrap32(v) / FX_UNIT
end

-- The SRT record a pose provider hands to the SBC evaluator (the decoded
-- Nsbmd node record shape: translation/rotation/scale, the zero flags, the
-- inverse scale, and the matrix-stack slot the evaluator stores into).
---@class SrtRecord
---@field translation { x: number, y: number, z: number }
---@field rotation number[] -- 9 cells, column-major
---@field scale { x: number, y: number, z: number }
---@field inverseScale { x: number, y: number, z: number }|nil
---@field transZero boolean
---@field rotZero boolean
---@field scaleOne boolean
---@field matrixStackIndex integer

-- Owner-held reusable composition storage: one persistent SRT record plus
-- a retained inverse-scale vector for calls where inverse scale is present.
---@return table<string, unknown>
function NitroJointState.newScratch()
  local scratch = {
    srt = {
      translation = { x = 0, y = 0, z = 0 },
      rotation = { 0, 0, 0, 0, 0, 0, 0, 0, 0 },
      scale = { x = 0, y = 0, z = 0 },
      inverseScale = nil,
      transZero = false,
      rotZero = false,
      scaleOne = false,
      matrixStackIndex = 0,
    },
    _inverseScale = { x = 0, y = 0, z = 0 },
  }
  return scratch
end

-- Compose the effective SRT record for a node into scratch-owned storage:
-- the same channel resolution as srtFromBlend, copying bind components into
-- persistent arrays instead of aliasing them. Returns the same `scratch.srt`
-- on every call. Toggling inverse-scale presence sets `srt.inverseScale` to
-- nil or the retained buffer without losing the buffer.
---@param scratch table<string, unknown>
---@param result JointAnimResult
---@param bindSrt SrtRecord
---@return SrtRecord
function NitroJointState.srtFromBlendInto(scratch, result, bindSrt)
  assert(
    type(scratch) == "table" and type(scratch.srt) == "table",
    "srtFromBlendInto requires joint composition scratch"
  )
  assert(type(result) == "table" and result.flags ~= nil, "srtFromBlendInto requires a blended joint result")
  assert(type(bindSrt) == "table" and bindSrt.matrixStackIndex ~= nil, "srtFromBlendInto requires the node's bind SRT")
  local srt = scratch.srt ---@type SrtRecord
  local inv = scratch._inverseScale ---@type { x: number, y: number, z: number }

  if fromModel(result.flags, F.trans) then
    srt.translation.x = bindSrt.translation.x
    srt.translation.y = bindSrt.translation.y
    srt.translation.z = bindSrt.translation.z
  else
    srt.translation.x = fxToFloat(result.trans[1])
    srt.translation.y = fxToFloat(result.trans[2])
    srt.translation.z = fxToFloat(result.trans[3])
  end

  if fromModel(result.flags, F.rot) then
    for i = 1, 9 do
      srt.rotation[i] = bindSrt.rotation[i]
    end
  else
    for i = 1, 9 do
      srt.rotation[i] = fxToFloat(result.rot[i])
    end
  end

  if fromModel(result.flags, F.scale) then
    srt.scale.x = bindSrt.scale.x
    srt.scale.y = bindSrt.scale.y
    srt.scale.z = bindSrt.scale.z
    if bindSrt.inverseScale then
      inv.x = bindSrt.inverseScale.x
      inv.y = bindSrt.inverseScale.y
      inv.z = bindSrt.inverseScale.z
      srt.inverseScale = inv
    else
      srt.inverseScale = nil
    end
  else
    srt.scale.x = fxToFloat(result.scale[1])
    srt.scale.y = fxToFloat(result.scale[2])
    srt.scale.z = fxToFloat(result.scale[3])
    if result.scaleEx then
      inv.x = fxToFloat(result.scaleEx[1])
      inv.y = fxToFloat(result.scaleEx[2])
      inv.z = fxToFloat(result.scaleEx[3])
      srt.inverseScale = inv
    else
      srt.inverseScale = nil
    end
  end

  srt.transZero = false
  srt.rotZero = false
  srt.scaleOne = false
  srt.matrixStackIndex = bindSrt.matrixStackIndex
  return srt
end

-- Compose the effective SRT record for a node:
--   result   a blended NNSG3dAnmResult (JointAnimBlend.blend output)
--   bindSrt  the node's bind SRT record (the program's node entry)
-- Channels the result leaves "from model" fall back to the bind values;
-- sampled channels convert from fx32. The zero flags are always false
-- (composition always emits every component), and matrixStackIndex is taken
-- from the bind record so the evaluator stores the world matrix in the
-- node's intended slot.
---@param result JointAnimResult
---@param bindSrt SrtRecord
---@return SrtRecord
function NitroJointState.srtFromBlend(result, bindSrt)
  return NitroJointState.srtFromBlendInto(NitroJointState.newScratch(), result, bindSrt)
end

return NitroJointState
