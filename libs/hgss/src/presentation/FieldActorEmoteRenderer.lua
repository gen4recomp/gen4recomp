-- Presentation adapter for the movement-emote billboard (currently
-- exclamation only; other decoded emote kinds draw nothing until a proven
-- source model is compiled for them). Mirrors the static field-effect
-- renderer's pool/material preparation, but its
-- "status" input is one entry per acting field actor instead of one player
-- state: every draw record whose activeEmoteKind names a compiled kind gets
-- one draw item, positioned at the actor's own world position (matching the
-- source spawn) plus the generated source anchor. The draw record is already
-- presentation-ready, so no actor offset is applied here.
--
-- The source model's SBC data marks its single batch `transformMode =
-- "billboard"` (Nitro's BB opcode) with a captured `baseTransform`; this
-- follows the same camera-independent billboard placement the static
-- building path uses (ModelInstance:drawItems / BillboardTransform), rather
-- than a fixed world-space rotation, so the badge always faces the camera
-- exactly like the source's NNSi_G3dFuncSbc_BB effect.

local Matrix3 = require("libs.math.src.Matrix3")
local Matrix4 = require("libs.math.src.Matrix4")
local FixedPoint = require("libs.math.src.FixedPoint")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")
local BillboardTransform = require("libs.hgss.src.presentation.BillboardTransform")
local FieldEmoteAssetCache = require("libs.assets.src.field.FieldEmoteAssetCache")
local PoseContract = require("libs.assets.src.model.PoseContract")

local IDENTITY_MODEL_NORMAL = Matrix3.identity()

---@class FieldActorEmoteRenderer
local FieldActorEmoteRenderer = {}
FieldActorEmoteRenderer.__index = FieldActorEmoteRenderer

-- kind -> field-emote descriptor. Only "exclamation" is proven/compiled today;
-- other schema-approved kinds stay unmapped until their own source model is
-- located, at which point they gain an entry here rather than reusing this
-- one's art.
local function materials(model, pool)
  local out = {}
  for _, record in ipairs(model.materials) do
    local wrap = SceneDescriptor.wrap(record)
    out[record.id] = {
      id = record.id,
      name = record.name,
      image = pool:imageFor(record.texture, wrap.x, wrap.y),
      texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
      wrap = wrap,
    }
  end
  return out
end

local function prepareModel(model, pool)
  return pool:build(function()
    local materialById = materials(model, pool)
    local batches = {}
    for _, batch in ipairs(model.batches) do
      local mesh = pool:meshFor(batch.geometry)
      batches[#batches + 1] = {
        mesh = mesh.mesh,
        material = materialById[batch.material],
        center = mesh.center,
        isBillboard = batch.transformMode == PoseContract.BILLBOARD,
        baseTransform = batch.baseTransform,
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
    return { model = model, batches = batches }
  end)
end

---@param modelsByKind table<string, table<string, unknown>> emote kind -> field-emote descriptor
---@param pool table<string, unknown> GpuAssetPool-shaped mesh/image pool
---@return FieldActorEmoteRenderer
function FieldActorEmoteRenderer.new(modelsByKind, pool)
  assert(type(modelsByKind) == "table", "field emote renderer requires its compiled models by kind")
  assert(pool and pool.meshFor and pool.imageFor and pool.build, "field emote renderer requires an asset pool")
  local prepared = {}
  for kind, descriptor in pairs(modelsByKind) do
    assert(
      descriptor
        and descriptor.schema == FieldEmoteAssetCache.SCHEMA
        and descriptor.anchorOffset
        and descriptor.model
        and descriptor.model.batches
        and descriptor.model.materials,
      "field emote descriptor for " .. tostring(kind) .. " is invalid"
    )
    local preparedModel = prepareModel(descriptor.model, pool)
    preparedModel.anchorOffset = descriptor.anchorOffset
    prepared[kind] = preparedModel
  end
  return setmetatable({ prepared = prepared }, FieldActorEmoteRenderer)
end

-- records: FieldActorManager:drawRecords() output. Returns one draw item per
-- (visible batch) of every record whose activeEmoteKind has a compiled
-- model.
function FieldActorEmoteRenderer:drawItems(records)
  local items = {}
  if not records then
    return items
  end
  for _, record in ipairs(records) do
    local kind = record.activeEmoteKind
    local prepared = kind and self.prepared[kind]
    if prepared and record.world then
      local anchor = prepared.anchorOffset
      local x = record.world.x + anchor.x
      local y = record.world.y + anchor.y
      local z = record.world.z + anchor.z
      local anchorTransform = Matrix4.translate(x, y, z)
      for _, batch in ipairs(prepared.batches) do
        local transform, modelNormal, billboardCenter, billboardScale
        if batch.isBillboard then
          transform = Matrix4.multiply(
            anchorTransform,
            assert(batch.baseTransform, "billboard batch needs a captured base transform")
          )
          billboardCenter, billboardScale = BillboardTransform.components(transform)
          modelNormal = IDENTITY_MODEL_NORMAL
        else
          transform = anchorTransform
          modelNormal = Matrix3.modelNormal(transform)
        end
        items[#items + 1] = {
          mesh = batch.mesh,
          material = batch.material,
          transform = transform,
          modelNormal = modelNormal,
          billboardCenter = billboardCenter,
          billboardScale = billboardScale,
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
          fieldEffect = "movement_emote",
          actorId = record.actorId,
        }
      end
    end
  end
  return items
end

function FieldActorEmoteRenderer:dispose()
  self.prepared = nil
end

return FieldActorEmoteRenderer
