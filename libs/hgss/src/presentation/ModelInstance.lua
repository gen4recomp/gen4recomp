-- ModelInstance: the per-model runtime object above the pose backend. An
-- instance owns the placement transform, the animation state
-- (ModelAnimationState), the per-instance material state, and the last
-- evaluated pose; it is the only animation-facing API gameplay touches.
-- Nothing here knows NSBCA, NARC, SBC, matrix slots, or Nitro animation
-- resource indices -- those live in the compiled transform program behind
-- NitroPoseBackend.
--
-- Usage per frame: instance:updateFixed() advances every attachment player,
-- instance:evaluatePose() recomputes the pose state through the nitro
-- backend, then drawItems(renderMeshesById) produces draw items in the
-- production renderer's shape (the same item contract the field renderer consumes
-- for map/building draws). drawItems also re-evaluates the effective material
-- state from the material attachments -- UV transforms, pattern variants,
-- animated colors, and the recomputed render classification -- so the item
-- contract always reflects the current frame. `renderMeshesById` supplies
-- the built mesh per mesh id (the caller builds love meshes from the
-- definition's referenced .g4mesh geometry); drawItems itself stays pure so
-- pose and item math are testable without graphics. An optional
-- `resolveImage` callback (opts.resolveImage) maps a texture key to the
-- caller's image object; without one items draw untextured.
--
-- The definition and its clips are immutable and shared; materialState is
-- the instance's own map, so two instances of one model can animate at
-- different frames and with different material overrides. Pure domain module.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FixedPoint = require("libs.math.src.FixedPoint")
local Matrix3 = require("libs.math.src.Matrix3")
local Matrix4 = require("libs.math.src.Matrix4")
local ModelAnimationState = require("libs.hgss.src.presentation.ModelAnimationState")
local AnimationPlayer = require("libs.hgss.src.presentation.AnimationPlayer")
local NitroPoseBackend = require("libs.hgss.src.presentation.NitroPoseBackend")
local PoseContract = require("libs.assets.src.model.PoseContract")
local MaterialEvaluator = require("libs.hgss.src.presentation.MaterialEvaluator")
local AlphaClassifier = require("libs.nds.src.gx.AlphaClassifier")
local PolygonState = require("libs.assets.src.model.PolygonState")
local AnimationClip = require("libs.assets.src.model.AnimationClip")
local BillboardTransform = require("libs.hgss.src.presentation.BillboardTransform")

---@class MaterialRGB
---@field r integer
---@field g integer
---@field b integer

---@class MaterialInstanceState
---@field texture string|nil
---@field texWidth integer|nil
---@field texHeight integer|nil
---@field colors MaterialColorComponents
---@field colorAnimated boolean -- a playing NSBMA clip drives the colors
---@field polygonAlpha integer
---@field texMatrix number[]
---@field alphaClass string|nil

---@class ModelInstance.Material : MaterialEvaluator.Material
---@field id integer
---@field alphaMode string

---@class ModelInstance
---@field definition table<string, unknown>
---@field transform number[]
---@field animationState table<string, unknown>
---@field materialState { [integer]: MaterialInstanceState }
---@field poseState PoseState|nil
---@field renderMeshesById table<string, unknown>|nil -- caller-built render meshes per mesh id
---@field resolveImage fun(key: string, materialId: integer): unknown|nil
---@field timeOfDayPlan table<string, unknown>|nil -- band plan the scene loader attaches (TimeOfDayProps.plan)
---@field play fun(self: ModelInstance, nameOrSemantic: string, opts: table<string, unknown>?): table<string, unknown>
---@field stop fun(self: ModelInstance, nameOrHandle: string|table<string, unknown>): integer
local ModelInstance = {}
ModelInstance.__index = ModelInstance

---@class ModelInstance.Options
---@field transform number[]?
---@field resolveImage? fun(key: string, materialId: integer): unknown|nil
---@field timeOfDayPlan table<string, unknown>|nil

-- The polygon draw fields the draw path consumes from a nitro backend mesh
-- record: the shared PolygonState schema minus polygonAlpha, which rides on
-- the effective material (it can be animated) rather than the batch record.
-- The descriptor gate guarantees the full field set on every batch, and
-- fromNitroDescriptor copies it onto the backend record, so the draw path
-- reads the fields directly -- never a default.
local DRAW_STATE_FIELDS = {}
for _, field in ipairs(PolygonState.FIELDS) do
  if field ~= "polygonAlpha" then
    DRAW_STATE_FIELDS[#DRAW_STATE_FIELDS + 1] = field
  end
end

-- alphaMode -> the renderer's render-pass class (the material contract). The
-- descriptor gate restricts alphaMode to this vocabulary, so a lookup can
-- never miss.
local ALPHA_CLASS = {
  opaque = AlphaClassifier.OPAQUE,
  mask = AlphaClassifier.CUTOUT,
  blend = AlphaClassifier.TRANSLUCENT,
}

local function identityMatrix()
  return Matrix4.identity()
end

local IDENTITY_TEX_MATRIX = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
local IDENTITY_MODEL_NORMAL = Matrix3.identity()

local function isTranslationOnly(transform)
  return transform[1] == 1
    and transform[2] == 0
    and transform[3] == 0
    and transform[5] == 0
    and transform[6] == 1
    and transform[7] == 0
    and transform[9] == 0
    and transform[10] == 0
    and transform[11] == 1
end

-- The base material state with no animation: the definition's texture and
-- the per-register base colors (MaterialEvaluator.baseColors), the static
-- SRT matrix (the evaluator builds it), and the alpha class from the
-- texture's alpha usage when the record carries texture metadata, else the
-- model contract's alphaMode.
local function baseMaterialState(material)
  local state = {
    texture = material.texture,
    texWidth = material.texWidth,
    texHeight = material.texHeight,
    colors = MaterialEvaluator.baseColors(material),
    polygonAlpha = material.polygonAlpha,
    texMatrix = IDENTITY_TEX_MATRIX,
  }
  if material.textureFormat ~= nil then
    state.alphaClass =
      AlphaClassifier.classify(state.polygonAlpha, material.polygonMode, material.textureFormat, material.alphaUsage)
  else
    state.alphaClass = ALPHA_CLASS[material.alphaMode]
  end
  return state
end

---@param definition ModelDefinition
---@param opts ModelInstance.Options?
---@return ModelInstance
function ModelInstance.new(definition, opts)
  assert(type(definition) == "table" and definition.key ~= nil, "ModelInstance.new requires a ModelDefinition")
  opts = opts or {}
  local transform = opts.transform or identityMatrix()
  assert(type(transform) == "table" and #transform == 16, "instance transform must be a 16-element column-major matrix")

  local materialState = {}
  for _, material in ipairs(definition.materials) do
    ---@cast material ModelInstance.Material
    materialState[material.id] = baseMaterialState(material)
  end

  return setmetatable({
    definition = definition,
    transform = transform,
    animationState = ModelAnimationState.new(definition),
    materialState = materialState,
    poseState = nil,
    resolveImage = opts.resolveImage,
  }, ModelInstance)
end

-- Advance every attachment player by one fixed step.
function ModelInstance:updateFixed()
  self.animationState:updateFixed()
end

-- Recompute the pose state from the current animation state through the
-- definition's nitro pose backend. Returns the PoseState. Raises a
-- structured error when the backend cannot evaluate (no silent fallback).
---@return PoseState
function ModelInstance:evaluatePose()
  self.poseState = NitroPoseBackend.evaluate(self)
  return self.poseState
end

-- Start playing a clip, resolved by name or semantic role (e.g.
-- "door.open"). The binding comes from the definition's precomputed record;
-- player setup happens here, once per play, never per frame. `opts` passes
-- the player and loopMode through to the attachment. There is no
-- direction option; a one-shot always plays forward from 0. Returns the LIVE
-- attachment as the handle (a plain table carrying
-- clip/binding/player) for stop() -- there is no token
-- layer. Every play attaches an independent player, so several clips of
-- different kinds can run simultaneously; a second clip of a kind that is
-- already playing raises ANIM_STATE_SAME_KIND_IN_USE. A clip that binds no
-- model element raises ANIM_STATE_ZERO_BINDING and attaches nothing.
function ModelInstance:play(nameOrSemantic, opts)
  local clip = self.definition:animation(nameOrSemantic)
  if not clip then
    Errors.raise(
      FieldErrors.ANIM_INSTANCE_UNKNOWN_ANIMATION,
      "model " .. self.definition.key .. " has no clip named " .. tostring(nameOrSemantic),
      { modelKey = self.definition.key, name = nameOrSemantic }
    )
  end
  opts = opts or {}
  if opts.loopMode then
    assert(AnimationPlayer.LOOP_MODES[opts.loopMode], "loopMode must be loop or once")
  end
  assert(opts.direction == nil, "direction is not a play option: reverse playback is cut")

  local player = opts.player or AnimationPlayer.new(clip)
  if opts.loopMode then
    player.loopMode = opts.loopMode
  end

  return self.animationState:attach(clip, { player = player })
end

-- Stop playing clips: by attachment handle (exactly that attachment), or by
-- name/semantic role (every play of the matching clip). Returns the number
-- of attachments removed.
function ModelInstance:stop(nameOrHandle)
  if type(nameOrHandle) == "table" then
    return self.animationState:detach(nameOrHandle)
  end
  local removed = 0
  local state = self.animationState
  for _, category in ipairs(ModelAnimationState.GROUPS) do
    for _, attachment in ipairs(state:attachments(category)) do
      local clip = attachment.clip
      local matchesName = clip.name == nameOrHandle or clip.id == nameOrHandle
      for _, semantic in ipairs(clip.semanticNames) do
        if semantic == nameOrHandle then
          matchesName = true
        end
      end
      if matchesName then
        state:detach(attachment)
        removed = removed + 1
      end
    end
  end
  return removed
end

-- Recompute the effective material state from the material attachments.
-- Runs inside drawItems; call it directly to inspect the state without
-- drawing. With no attachments the evaluator still runs: the static SRT
-- matrix and the base texture's alpha classification are part of the
-- effective state.
function ModelInstance:evaluateMaterials()
  local definition = self.definition
  ---@cast definition MaterialEvaluator.Definition
  MaterialEvaluator.evaluate(
    definition,
    self.animationState:attachments(AnimationClip.CATEGORIES.material),
    self.materialState
  )
end

-- The effective render material record for a material index: definition
-- properties plus this instance's evaluated state. Never mutates the
-- definition. The texture image is resolved through the instance's
-- resolveImage callback (nil without one); the UV transform matrix is the
-- evaluator's normalized 3x3. The polygon draw state (cull mode, polygon
-- mode/id, depth flags) is per draw segment and lives on the mesh records,
-- not here.
function ModelInstance:effectiveMaterial(materialIndex)
  local material = assert(
    self.definition.materials[materialIndex + 1],
    "material index " .. tostring(materialIndex) .. " out of range"
  )
  local state = self.materialState[materialIndex]
  local colors = state and state.colors
  local function component(name)
    local c = colors and colors[name]
    if c then
      return { c.r / 255, c.g / 255, c.b / 255 }
    end
    local base = material.baseColor
    return { base.r / 255, base.g / 255, base.b / 255 }
  end
  local image
  if state and state.texture and self.resolveImage then
    image = self.resolveImage(state.texture, materialIndex)
  end
  local alphaClass = state and state.alphaClass or ALPHA_CLASS[material.alphaMode]
  return {
    image = image,
    texMatrix = state and state.texMatrix or IDENTITY_TEX_MATRIX,
    matDiffuse = component("diffuse"),
    matAmbient = component("ambient"),
    matSpecular = component("specular"),
    matEmission = component("emission"),
    -- A playing NSBMA color clip replaces the field profile at the register:
    -- the renderer uses the material's colors directly when this is set, and
    -- the field profile otherwise (the HGSS field policy clears all four
    -- color ownership bits, so the stored colors alone never reach the DS).
    colorsAnimated = state and state.colorAnimated or false,
    alphaClass = alphaClass,
    polygonAlpha = state.polygonAlpha / FixedPoint.RGB5_MAX,
  }
end

-- A draw item in the field renderer item shape (the contract the field renderer
-- consumes for map/building draws).
---@class ModelDrawItem
---@field mesh table<string, unknown> -- built render mesh for the item's mesh id
---@field material table<string, unknown> -- effective material record
---@field transform number[] -- 16-element column-major matrix
---@field modelNormal number[] -- inverse-transpose model linear transform
---@field alphaClass string
---@field polygonAlpha number
---@field polygonMode string
---@field polygonId integer
---@field lightMask integer
---@field cullMode string
---@field translucentDepthWrite boolean
---@field depthEqual boolean
---@field center number[] -- model-space center, transformed by the render queue
---@field billboardBase number[]|nil
---@field billboardCenter number[]|nil
---@field billboardScale number[]|nil

-- Draw items in the field renderer item shape, one per definition mesh, with
-- the current pose. `renderMeshesById` maps mesh id -> built render mesh
-- (love Mesh in production; any object in pure tests). A mesh whose node is
-- hidden by the current pose is omitted. Before the first pose evaluation
-- meshes render at their bind placement under the instance transform.
--
-- Nitro-backed definitions carry per-mesh draw records in the pose
-- (PoseState.drawMatrices): a Nitro draw is not one node matrix, so those
-- records -- resolved from the transform program -- replace the node-matrix
-- path, and the polygon draw state compiled per segment (cull mode, polygon
-- mode/id, depth flags) rides on the item. A billboard draw keeps the
-- camera-independent center and scale derived from its captured base; the
-- shader supplies the view-facing axes, exactly like the static building path.
-- The remaining center is the mesh's model-space bounding-box center (stamped
-- by the loader); the
-- render queue transforms it once by the item transform.
---@param renderMeshesById table<string, unknown>
---@return ModelDrawItem[]
function ModelInstance:drawItems(renderMeshesById)
  assert(type(renderMeshesById) == "table", "drawItems requires a mesh render table")
  self:evaluateMaterials()
  local items = {}
  local pose = self.poseState
  local backendMeshes = self.definition.backend and self.definition.backend.meshes or {}
  for _, mesh in ipairs(self.definition.meshes) do
    if not (pose and pose.nodeVisible[mesh.nodeIndex] == false) then
      ---@type PoseDrawMatrix|nil
      local draw = pose and pose.drawMatrices and pose.drawMatrices[mesh.id]
      local transform, billboardBase, billboardCenter, billboardScale
      if draw then
        if draw.transformMode == PoseContract.BILLBOARD then
          billboardBase = Matrix4.multiply(self.transform, draw.baseTransform)
          billboardCenter, billboardScale = BillboardTransform.components(billboardBase)
          transform = billboardBase
        else
          transform = Matrix4.multiply(self.transform, draw.position)
        end
      else
        local nodeMatrix = identityMatrix()
        if pose and pose.nodeMatrices[mesh.nodeIndex] then
          nodeMatrix = pose.nodeMatrices[mesh.nodeIndex]
        end
        transform = Matrix4.multiply(self.transform, nodeMatrix)
      end
      local meshState = assert(
        backendMeshes[mesh.id],
        "backend mesh record missing for " .. mesh.id .. " (a nitro definition must cover every mesh)"
      )
      local material = self:effectiveMaterial(mesh.materialIndex)
      local modelNormal = IDENTITY_MODEL_NORMAL
      if not billboardBase and not isTranslationOnly(transform) then
        modelNormal = Matrix3.modelNormal(transform)
      end
      local item = {
        mesh = renderMeshesById[mesh.id],
        material = material,
        transform = transform,
        modelNormal = modelNormal,
        billboardBase = billboardBase,
        billboardCenter = billboardCenter,
        billboardScale = billboardScale,
        alphaClass = material.alphaClass,
        polygonAlpha = material.polygonAlpha,
        -- The loader stamps each mesh's model-space center from the decoded
        -- geometry; a definition mesh without one cannot be sorted.
        center = assert(mesh.center, "mesh " .. mesh.id .. " has no stamped model-space center"),
      }
      -- The shared draw-state set rides on the item from the backend record
      -- (complete by contract: the descriptor gate requires every field on
      -- every batch, and fromNitroDescriptor copies the batch records).
      for _, field in ipairs(DRAW_STATE_FIELDS) do
        item[field] = meshState[field]
      end
      items[#items + 1] = item
    end
  end
  return items
end

return ModelInstance
