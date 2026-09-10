-- Normalizes the shared field-actor model member into the geometry and polygon
-- draw state a compiled actor visual carries.
--
-- Every field actor in this class is drawn from one `mmodel` model member
-- (`mmdl_m32x32`): a single quad with a bottom-center origin, issued through the
-- Nitro `NNS_G3D_SBC_BB` full camera-facing billboard command. This module
-- replays that member through the same MeshCompiler the map and building models
-- use, so the actor quad's vertices, normal, vertex colour source, UVs, billboard
-- base transform, and effective POLYGON_ATTR state all come from the ROM rather
-- than from a hand-authored quad. The recovered facts are checked against the
-- manifest's placement invariants; a member that stops matching them fails loudly.
--
-- References: GBATEK "GX POLYGON_ATTR"; NitroSystem g3d res_struct.h for
-- `NNS_G3D_SBC_BB`; .agents/docs/adr/field-actor-visual-representation.md.
-- Pure domain module; no love dependency.

local Errors = require("libs.errors.src.Errors")
local AlphaClassifier = require("libs.nds.src.gx.AlphaClassifier")
local DsPolygonAttr = require("libs.nds.src.gx.DsPolygonAttr")
local MapUnits = require("romdump.src.digest.map.MapUnits")
local MeshCompiler = require("romdump.src.digest.model.MeshCompiler")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local PoseContract = require("libs.assets.src.model.PoseContract")

local FieldActorModel = {}

-- Model-space geometry is compared against the manifest placement in tiles.
local EPSILON = 1e-6

local function fail(code, message, context)
  Errors.raise(code, message, context)
end

local function near(a, b)
  return math.abs(a - b) <= EPSILON
end

local function extent(values)
  local min, max = math.huge, -math.huge
  for _, value in ipairs(values) do
    min, max = math.min(min, value), math.max(max, value)
  end
  return min, max
end

-- The quad must be the bottom-centered plane the actor loader positions by its
-- feet: symmetric in X, resting on Y=0, and flat in Z.
local function assertPlacement(vertices, placement, context)
  local xs, ys, zs = {}, {}, {}
  for _, vertex in ipairs(vertices) do
    xs[#xs + 1], ys[#ys + 1], zs[#zs + 1] = vertex.x, vertex.y, vertex.z
  end
  local minX, maxX = extent(xs)
  local minY, maxY = extent(ys)
  local minZ, maxZ = extent(zs)
  local width = placement.sourceSize.width / MapUnits.MODEL_UNITS_PER_TILE
  local height = placement.sourceSize.height / MapUnits.MODEL_UNITS_PER_TILE

  if
    not (
      near(minX, -width / 2)
      and near(maxX, width / 2)
      and near(minY, 0)
      and near(maxY, height)
      and near(minZ, 0)
      and near(maxZ, 0)
    )
  then
    fail(
      "FIELD_ACTOR_MODEL_PLACEMENT_UNEXPECTED",
      string.format(
        "actor quad spans x[%.4f,%.4f] y[%.4f,%.4f] z[%.4f,%.4f] tiles, expected"
          .. " a bottom-centered %.4fx%.4f plane",
        minX,
        maxX,
        minY,
        maxY,
        minZ,
        maxZ,
        width,
        height
      ),
      { context = context }
    )
  end
  return { width = maxX - minX, height = maxY - minY, depth = maxZ - minZ }
end

-- Source UVs are in texel units over the actor's own texture. Normalizing them
-- here keeps the runtime's per-frame atlas offset a pure `(frame + u) / frames`.
local function normalizeUvs(vertices, size, context)
  local us, vs = {}, {}
  for _, vertex in ipairs(vertices) do
    us[#us + 1], vs[#vs + 1] = vertex.u, vertex.v
  end
  local minU, maxU = extent(us)
  local minV, maxV = extent(vs)
  if not (near(minU, 0) and near(maxU, size.width) and near(minV, 0) and near(maxV, size.height)) then
    fail(
      "FIELD_ACTOR_MODEL_UV_UNEXPECTED",
      string.format(
        "actor quad UVs span [%.2f,%.2f]x[%.2f,%.2f] texels, expected the whole" .. " %dx%d texture",
        minU,
        maxU,
        minV,
        maxV,
        size.width,
        size.height
      ),
      { context = context }
    )
  end
  for _, vertex in ipairs(vertices) do
    vertex.u, vertex.v = vertex.u / size.width, vertex.v / size.height
  end
end

local function materializeBatch(batch)
  local vertices, indices = {}, {}
  local numeric = batch.arena.numeric
  local attrib = batch.arena.attrib
  for offset = 0, batch.vertexCount - 1 do
    local vertex = numeric[batch.vertexOffset + offset]
    local bytes = attrib[batch.vertexOffset + offset]
    vertices[#vertices + 1] = {
      x = vertex.x,
      y = vertex.y,
      z = vertex.z,
      u = vertex.u,
      v = vertex.v,
      nx = vertex.nx,
      ny = vertex.ny,
      nz = vertex.nz,
      r = bytes.r,
      g = bytes.g,
      b = bytes.b,
      a = bytes.a,
      colorSource = bytes.colorSource,
    }
  end
  for offset = 0, batch.indexCount - 1 do
    indices[#indices + 1] = batch.arena.indices[batch.indexOffset + offset]
  end
  return vertices, indices
end

-- modelBytes: the shared model member. opts.placement: the manifest placement
-- invariants. opts.textureFormat / opts.alphaUsage: the compiled atlas's source
-- texture facts, used for the same alpha classification map batches get.
function FieldActorModel.compile(modelBytes, opts)
  assert(type(modelBytes) == "string", "FieldActorModel needs the model member bytes")
  assert(type(opts) == "table" and opts.placement, "FieldActorModel needs the placement invariants")
  local context = opts.context

  local file = assert(Nsbmd.decode(modelBytes, context))
  if #file.models ~= 1 then
    fail(
      "FIELD_ACTOR_MODEL_SHAPE_UNEXPECTED",
      "shared actor model member holds " .. #file.models .. " models, expected exactly one",
      { context = context }
    )
  end
  local model = file.models[1]

  local batches = MeshCompiler.compile(model)
  if #batches ~= 1 then
    fail(
      "FIELD_ACTOR_MODEL_SHAPE_UNEXPECTED",
      "shared actor model draws " .. #batches .. " batches, expected exactly one quad",
      { context = context, modelName = model.name }
    )
  end
  local batch = batches[1]
  local vertices, indices = materializeBatch(batch)

  if batch.transformMode ~= PoseContract.BILLBOARD or not batch.baseTransform then
    fail(
      "FIELD_ACTOR_MODEL_NOT_BILLBOARD",
      "shared actor model draw is "
        .. tostring(batch.transformMode or PoseContract.STATIC)
        .. ", expected the Nitro full camera-facing billboard command",
      { context = context, modelName = model.name }
    )
  end
  if #vertices ~= 4 or #indices ~= 6 then
    fail(
      "FIELD_ACTOR_MODEL_SHAPE_UNEXPECTED",
      "shared actor model draws " .. #vertices .. " vertices and " .. #indices .. " indices, expected one 4-vertex quad",
      { context = context, modelName = model.name }
    )
  end

  local bounds = assertPlacement(vertices, opts.placement, context)
  normalizeUvs(vertices, opts.placement.sourceSize, context)

  local polygon = DsPolygonAttr.decode(batch.polygonAttrRaw)
  if polygon.cullMode == "all" then
    fail("FIELD_ACTOR_MODEL_INVISIBLE", "shared actor model renders neither polygon surface", { context = context })
  end
  -- Every alpha class the shared classifier can produce (opaque, cutout,
  -- translucent, mixed, wireframe) is ordinary shared render-queue geometry
  -- (see FieldRenderer/RenderQueue): actors carry no format-specific rendering
  -- restriction, matching the ROM's own polygon state exactly.
  local alphaClass =
    AlphaClassifier.classify(polygon.polygonAlpha, polygon.polygonMode, opts.textureFormat or 0, opts.alphaUsage)

  -- The actor loader adds a fixed Y offset in model units before installing the
  -- draw position. Converting it here keeps every runtime-facing number in tiles.
  local offset = opts.placement.modelOffset
  local anchorX, anchorY, anchorZ = MapUnits.toTiles(offset.x, offset.y, offset.z)

  return {
    modelName = model.name,
    vertices = vertices,
    indices = indices,
    baseTransform = batch.baseTransform,
    anchorTiles = { x = anchorX, y = anchorY, z = anchorZ },
    bounds = bounds,
    alphaClass = alphaClass,
    polygon = {
      polygonAttrRaw = polygon.polygonAttrRaw,
      polygonAlpha = polygon.polygonAlpha,
      polygonMode = polygon.polygonMode,
      polygonId = polygon.polygonId,
      lightMask = polygon.lightMask,
      cullMode = polygon.cullMode,
      translucentDepthWrite = polygon.translucentDepthWrite,
      depthEqual = polygon.depthEqual,
      farClipEnabled = polygon.farClipEnabled,
      oneDotEnabled = polygon.oneDotEnabled,
      fogEnabled = polygon.fogEnabled,
    },
  }
end

-- The single draw mode shared by every batch of the actor model
-- (TransformMode), or "mixed"/"unsupported" when it cannot be one.
---@param modelBytes string
---@param context Errors.Context
---@return TransformMode | "mixed" | "unsupported"
function FieldActorModel.drawMode(modelBytes, context)
  local file = assert(Nsbmd.decode(modelBytes, context))
  if #file.models ~= 1 then
    return "unsupported"
  end
  local batches = MeshCompiler.compile(file.models[1])
  local mode
  for _, batch in ipairs(batches) do
    mode = mode or batch.transformMode
    if batch.transformMode ~= mode then
      return "mixed"
    end
  end
  return mode or "unsupported"
end
return FieldActorModel
