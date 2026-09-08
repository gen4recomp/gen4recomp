-- Presents the transient follower-transition effect through the engine's
-- model stack. The controller owns each mutable part instance; this adapter
-- owns immutable definitions and pooled meshes/images. The companion part is
-- a static model drawn from prepared batches, the animated part a dynamic
-- model drawn through its mutable ModelInstance.

local Matrix3 = require("libs.math.src.Matrix3")
local Matrix4 = require("libs.math.src.Matrix4")
local FixedPoint = require("libs.math.src.FixedPoint")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")

---@class FollowingMonTransitionRenderer
---@field resources table<string, unknown> prepared static/dynamic part resources
---@field placementOffset table<string, unknown> source placement offset axes
---@field pool table<string, unknown> mesh/image pool backing part instances
---@field new fun(options: FollowingMonTransitionRendererOptions, pool: table<string, unknown>): FollowingMonTransitionRenderer
---@field newInstance fun(self: FollowingMonTransitionRenderer, part: string): table<string, unknown>
---@field drawItems fun(self: FollowingMonTransitionRenderer, status: table<string, unknown>, runtimeMap: table<string, unknown>): table<string, unknown>[]
---@field dispose fun(self: FollowingMonTransitionRenderer)
local FollowingMonTransitionRenderer = {}
FollowingMonTransitionRenderer.__index = FollowingMonTransitionRenderer

local EFFECT_TAG = "follower_transition"

---@class FollowingMonTransitionPartInstance : ModelInstance
---@field isComplete fun(self: FollowingMonTransitionPartInstance): boolean
---@field reset fun(self: FollowingMonTransitionPartInstance)
---@field dispose fun(self: FollowingMonTransitionPartInstance)
---@field renderMeshesById table<string, unknown>|nil

-- Resolve the companion and animated descriptors from the compiled
-- definition. Compiled definitions carry the two models as an array split by
-- kind, matching the producer and cache validation.
---@param definition table<string, unknown>
---@return table<string, unknown> initialDescriptor, table<string, unknown> animatedDescriptor
local function partDescriptors(definition)
  assert(type(definition) == "table", "transition definition is required")
  local models = definition.models
  assert(type(models) == "table", "transition definition requires its models")
  local initialDescriptor, animatedDescriptor = nil, nil
  for _, descriptor in ipairs(models) do
    assert(type(descriptor) == "table", "transition model descriptor is required")
    if descriptor.kind == "static" then
      assert(initialDescriptor == nil, "transition definition carries two companion models")
      initialDescriptor = descriptor
    elseif descriptor.kind == "nitro-dynamic" then
      assert(animatedDescriptor == nil, "transition definition carries two animated models")
      animatedDescriptor = descriptor
    else
      error("unknown transition model kind " .. tostring(descriptor.kind))
    end
  end
  assert(initialDescriptor ~= nil, "transition definition requires its companion model")
  return initialDescriptor, assert(animatedDescriptor, "transition definition requires its animated model")
end

---@param descriptor table<string, unknown>
---@param pool table<string, unknown>
---@return table<string, unknown>
local function prepareStatic(descriptor, pool)
  assert(type(descriptor.materials) == "table", "transition companion model requires its materials")
  assert(type(descriptor.batches) == "table", "transition companion model requires its batches")
  local materialById = {}
  for _, record in ipairs(descriptor.materials) do
    local wrap = SceneDescriptor.wrap(record)
    materialById[record.id] = {
      id = record.id,
      name = record.name,
      image = pool:imageFor(record.texture, wrap.x, wrap.y),
      texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
      wrap = wrap,
    }
  end
  local batches = {}
  for _, batch in ipairs(descriptor.batches) do
    local mesh = pool:meshFor(batch.geometry)
    batches[#batches + 1] = {
      mesh = mesh.mesh,
      material = materialById[batch.material],
      center = mesh.center,
      alphaClass = batch.alphaClass,
      cullMode = batch.cullMode,
      polygonAlpha = batch.polygonAlpha / FixedPoint.RGB5_MAX,
      polygonMode = batch.polygonMode,
      polygonId = batch.polygonId,
      translucentDepthWrite = batch.translucentDepthWrite,
      depthEqual = batch.depthEqual,
      lightMask = batch.lightMask,
      fogEnabled = batch.fogEnabled,
    }
  end
  return { staticBatches = batches }
end

---@param descriptor table<string, unknown>
---@param part string
---@param pool table<string, unknown>
---@return table<string, unknown>
local function prepareDynamic(descriptor, part, pool)
  local nitroDescriptor = descriptor --[[@as ModelDefinition.Descriptor]]
  local definition = ModelDefinition.fromNitroDescriptor(nitroDescriptor, { key = EFFECT_TAG .. ":" .. part })
  local renderMeshesById = {}
  for _, mesh in ipairs(definition.meshes) do
    local resource = pool:meshFor(mesh.geometry)
    renderMeshesById[mesh.id] = resource.mesh
    mesh.center = resource.center
  end
  return {
    definition = definition,
    descriptor = descriptor,
    renderMeshesById = renderMeshesById,
    wraps = SceneDescriptor.wrapByMaterial(descriptor.materials),
  }
end

---@param descriptor table<string, unknown>
---@return boolean
local function isStatic(descriptor)
  return descriptor.kind == "static"
end

---@class FollowingMonTransitionRendererOptions
---@field transition table<string, unknown> the compiled transition definition
---@param options FollowingMonTransitionRendererOptions
---@param pool table<string, unknown> GpuAssetPool-shaped mesh/image pool
---@return FollowingMonTransitionRenderer
function FollowingMonTransitionRenderer.new(options, pool)
  assert(type(options) == "table" and type(options.transition) == "table", "transition definition is required")
  assert(pool and pool.meshFor and pool.imageFor and pool.build, "transition asset pool is required")
  local transition = options.transition
  local placementOffset = assert(
    type(transition.placementOffset) == "table" and transition.placementOffset,
    "transition definition requires its placement offset"
  )
  local initialDescriptor, animatedDescriptor = partDescriptors(transition)
  local resources = {}
  pool:build(function()
    resources.initial = isStatic(initialDescriptor) and prepareStatic(initialDescriptor, pool)
      or prepareDynamic(initialDescriptor, "initial", pool)
    resources.animated = isStatic(animatedDescriptor) and prepareStatic(animatedDescriptor, pool)
      or prepareDynamic(animatedDescriptor, "animated", pool)
    return resources
  end)
  return setmetatable(
    { resources = resources, placementOffset = placementOffset, pool = pool },
    FollowingMonTransitionRenderer
  )
end

-- Builds one mutable part instance. The animated instance plays its source
-- clip from frame zero on the first reset and reports completion through the
-- fixed-point player; the companion handle carries no animation state.
---@param part string
---@return table<string, unknown>
function FollowingMonTransitionRenderer:newInstance(part)
  local resource = assert(self.resources[part], "transition renderer is missing " .. tostring(part))
  if resource.staticBatches ~= nil then
    local handle = {}
    function handle:dispose() end
    return handle
  end
  local function resolveImage(path, materialId)
    local wrap = assert(resource.wraps[materialId], "missing transition material wrap")
    return self.pool:imageFor(path, wrap.x, wrap.y)
  end
  local instance = ModelInstance.new(resource.definition, {
    resolveImage = resolveImage,
  })
  ---@cast instance FollowingMonTransitionPartInstance
  instance.renderMeshesById = resource.renderMeshesById
  local descriptor = resource.descriptor
  local handle = nil
  local function ensureHandle()
    if handle == nil then
      local animations = descriptor.animations
      assert(type(animations) == "table", "transition animated part requires its clip")
      local clip = animations[1]
      assert(type(clip) == "table" and type(clip.name) == "string", "transition animated part requires its clip")
      handle = instance:play(clip.name, { loopMode = "once" })
    end
    return assert(handle)
  end
  function instance:reset()
    local player = ensureHandle().player
    player.frameFx = 0
    player.completed = false
  end
  function instance:isComplete()
    return handle ~= nil and handle.player:isComplete()
  end
  function instance:dispose() end
  return instance
end

---@param resource table<string, unknown>
---@param transform number[]
---@param part string
---@param items table<string, unknown>
local function drawStatic(resource, transform, part, items)
  for _, batch in ipairs(assert(resource.staticBatches, "transition companion batches are missing")) do
    items[#items + 1] = {
      mesh = batch.mesh,
      material = batch.material,
      transform = transform,
      modelNormal = Matrix3.modelNormal(transform),
      center = batch.center,
      alphaClass = batch.alphaClass,
      cullMode = batch.cullMode,
      polygonAlpha = batch.polygonAlpha,
      polygonMode = batch.polygonMode,
      polygonId = batch.polygonId,
      translucentDepthWrite = batch.translucentDepthWrite,
      depthEqual = batch.depthEqual,
      lightMask = batch.lightMask,
      fogEnabled = batch.fogEnabled,
      worldSpace = true,
      fieldEffect = EFFECT_TAG,
      transitionPart = part,
    }
  end
end

---@param resource table<string, unknown>
---@param modelInstance table<string, unknown>
---@param transform number[]
---@param part string
---@param items table<string, unknown>
local function drawDynamic(resource, modelInstance, transform, part, items)
  local instance = assert(modelInstance, "transition model instance is missing")
  instance.transform = transform
  instance:evaluatePose()
  for _, item in ipairs(instance:drawItems(assert(resource.renderMeshesById, "transition render meshes are missing"))) do
    item.worldSpace = true
    item.fieldEffect = EFFECT_TAG
    item.transitionPart = part
    items[#items + 1] = item
  end
end

-- Draws only the currently active part of every live instance at the
-- normalized partner anchor. Draw never advances lifecycle state.
---@param status table<string, unknown> controller status carrying live instances
---@param runtimeMap table<string, unknown>
---@return table<string, unknown>[]
function FollowingMonTransitionRenderer:drawItems(status, runtimeMap)
  assert(status and type(status.instances) == "table", "transition status instances are required")
  if #status.instances == 0 then
    return {}
  end
  assert(type(runtimeMap) == "table", "transition runtime map is required")
  local offset = assert(self.placementOffset, "transition placement offset is required")
  local items = {}
  for _, effect in ipairs(status.instances) do
    local point = FieldCoordinates.fieldToWorld(runtimeMap, effect.fieldX, effect.fieldZ, effect.worldY)
    local transform = Matrix4.translate(point.x + offset.x, point.y + offset.y, point.z + offset.z)
    local part
    if effect.phase == "prelude" then
      part = "initial"
    elseif effect.phase == "animated" then
      part = "animated"
    else
      error("unknown transition phase " .. tostring(effect.phase))
    end
    local resource = assert(self.resources[part], "transition renderer is missing " .. part)
    if resource.staticBatches ~= nil then
      drawStatic(resource, transform, part, items)
    else
      local modelInstance = part == "initial" and effect.initialInstance or effect.animatedInstance
      drawDynamic(resource, modelInstance, transform, part, items)
    end
  end
  return items
end

function FollowingMonTransitionRenderer:dispose()
  self.resources = nil
  self.pool = nil
end

return FollowingMonTransitionRenderer
