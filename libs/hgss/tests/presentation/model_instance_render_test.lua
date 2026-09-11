-- Renderer smoke tests for the nitro-backed ModelInstance: the door fixture
-- renders through the production FieldRenderer and scrubbing frames reuses the
-- built meshes. The suite builds real GPU resources, so it declares the
-- graphics layer and the runner skips it explicitly on hosts without one.

local Assert = require("tests.support.Assert")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local SceneMesh = require("libs.hgss.src.presentation.SceneMesh")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local NitroModelFixture = require("tests.support.NitroModelFixture")

local T = {}

local ZERO_FOG_TABLE = {}
for i = 1, 32 do
  ZERO_FOG_TABLE[i] = 0
end

-- Build love meshes for every definition mesh through the production mesh
-- path (G4M2 encode -> decode -> build), keyed by mesh id like the loader's
-- renderMeshesById. The fixture mesh references the .g4mesh path shape; the
-- bytes come from the shared door quad.
local function buildRenders(def)
  local renderMeshesById = {}
  for _, mesh in ipairs(def.meshes) do
    local bytes = MeshWriter.encode(NitroModelFixture.doorQuad())
    renderMeshesById[mesh.id] = SceneMesh.build(SceneMesh.decode(bytes))
  end
  return renderMeshesById
end

-- Test-only camera shape: the fake supplies the gameplay-visible fields
-- the renderer reads; the constructor-owned matrix buffers stay absent.
---@class ModelInstanceRenderTestCamera : FieldCamera
---@field _projectionCache number[]|nil
---@field _billboardProjectionCache number[]|nil
---@field _viewBuffer Matrix4.Buffer|nil
---@field _projectionBuffer Matrix4.Buffer|nil
---@field _billboardProjectionBuffer Matrix4.Buffer|nil
---@field _viewArray number[]|nil
---@field _projectionArray number[]|nil
---@field _billboardProjectionArray number[]|nil

---@return ModelInstanceRenderTestCamera
local function identityCamera()
  local identity = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
  return {
    cameraSourceY = 0,
    cameraAppliedY = 0,
    zoom = 1,
    projectionType = "orthographic",
    profile = {},
    distance = 26,
    near = 0.1,
    far = 400,
    sourceTarget = { x = 0, y = 0, z = 0 },
    target = { x = 0, y = 0, z = 0 },
    previousTarget = { x = 0, y = 0, z = 0 },
    eye = { x = 0, y = 0, z = 0 },
    previousEye = { x = 0, y = 0, z = 0 },
    up = { x = 0, y = 1, z = 0 },
    history = {},
    historyEnabled = false,
    canonicalAspect = 1,
    projectionAspect = 1,
    _billboardDepthOffset = 0,
    _projectionDirty = false,
    view = function()
      return identity
    end,
    projection = function()
      return identity
    end,
    billboardProjection = function()
      return identity
    end,
  } --[[@as ModelInstanceRenderTestCamera]]
end

local function drawInstance(renderer, runtime, instance, alpha)
  local items = instance:drawItems(instance.renderMeshesById)
  runtime.mapDraws = items
  renderer:draw(runtime, identityCamera(), { items }, nil, FieldViewport.new(320, 240, { mode = "strict" }), alpha)
end

function T.nitro_animated_fixture_renders_through_field_renderer()
  local lg = love.graphics
  local renderer = FieldRenderer.new()
  local def = NitroModelFixture.doorDefinition()
  local instance = ModelInstance.new(def)
  instance.renderMeshesById = buildRenders(def)
  local runtime = {
    mapDraws = {},
    buildingDraws = {},
    stats = { triangleCount = 0, meshCount = 0, textureCount = 0 },
    lighting = nil,
    edgeColors = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 },
    fog = { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = ZERO_FOG_TABLE },
  }

  instance:play("door.open")
  instance:updateFixed()
  instance:evaluatePose()
  drawInstance(renderer, runtime, instance, 1)
  local firstDrawCalls = renderer.stats.drawCalls
  Assert.isTrue(firstDrawCalls >= 1, "the door mesh draws")

  -- Scrubbing to another frame reuses the same built meshes (no geometry
  -- recompilation per frame) and still draws.
  instance:updateFixed()
  instance:updateFixed()
  instance:evaluatePose()
  local rendersBefore = instance.renderMeshesById
  drawInstance(renderer, runtime, instance, 1)
  Assert.isTrue(renderer.stats.drawCalls >= 1)
  Assert.equal(instance.renderMeshesById, rendersBefore, "meshes are built once, not per frame")

  -- No render state leaks into the next frame.
  Assert.isNil(lg.getCanvas(), "the scene canvas is unbound")
  Assert.isNil(lg.getShader(), "the map and edge shaders are unbound")
  Assert.equal(lg.getMeshCullMode(), "none")
  Assert.isFalse(lg.isWireframe())

  for _, mesh in pairs(instance.renderMeshesById) do
    mesh:release()
  end
  renderer:release()
end

return {
  metadata = { capabilities = { "graphics" } },
  tests = T,
}
