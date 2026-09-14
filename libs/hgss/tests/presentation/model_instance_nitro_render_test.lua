-- Renderer smoke tests for the Nitro dynamic path: a nitro-backed
-- ModelInstance (compiled transform program + compiled clip) renders through
-- the production FieldRenderer, scrubs frames without recompiling geometry, and
-- follows the same item contract as the generic fixture. The suite builds
-- real GPU resources, so it declares the graphics layer and the runner skips
-- it explicitly on hosts without one.

local Assert = require("tests.support.Assert")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local SceneMesh = require("libs.hgss.src.presentation.SceneMesh")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")

local T = {}

local ZERO_FOG_TABLE = {}
for i = 1, 32 do
  ZERO_FOG_TABLE[i] = 0
end

local function identity9()
  return { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
end

-- A compiled rotation clip over 8 frames (pivot A = 1 - i/16, B = i/16,
-- like the real `door_op`).
local function doorClip()
  local rotData = {}
  for i = 0, 7 do
    rotData[i + 1] = { control = 0x0024, a = 4096 - i * 256, b = i * 256 }
  end
  local keys = {}
  for i = 0, 7 do
    keys[i + 1] = 0x8000 + i
  end
  return {
    id = "fixture:nitro-door",
    name = "door_op",
    category = "joint",
    kind = "trs",
    frameCount = 8,
    tracks = { { target = 0, targetIndex = 0 } },
    semanticNames = { "door.open" },
    source = { type = "nitro", format = "NSBCA", archive = "a106", memberId = 1 },
    compiled = {
      anmFlags = 0,
      rotData = rotData,
      pivotData = {},
      targets = {
        {
          nodeIndex = 0,
          channels = {
            trans = { x = { source = "model" }, y = { source = "model" }, z = { source = "model" } },
            rot = { source = "curve", rate = 1, limit = 8, storage = "fx16", keys = keys },
            scale = { x = { source = "model" }, y = { source = "model" }, z = { source = "model" } },
          },
        },
      },
    },
  }
end

-- A one-door nitro model: a single node, one SBC draw, one segment mesh
-- (a 2x2-tile quad at the origin in tile space). The vertices use the
-- NORMAL_LIT color source (the compiled vocabulary: 0 literal, 1 normal-lit,
-- 2 field-diffuse) so the polygon light mask governs the rendered result (a
-- literal-color vertex bypasses the lighting stage entirely).
local function doorQuad()
  return {
    vertices = {
      {
        x = 0,
        y = 0,
        z = 0,
        u = 0,
        v = 0,
        nx = 0,
        ny = 1,
        nz = 0,
        r = 255,
        g = 255,
        b = 255,
        a = 255,
        colorSource = 1,
      },
      {
        x = 2,
        y = 0,
        z = 0,
        u = 1,
        v = 0,
        nx = 0,
        ny = 1,
        nz = 0,
        r = 255,
        g = 255,
        b = 255,
        a = 255,
        colorSource = 1,
      },
      {
        x = 2,
        y = 2,
        z = 0,
        u = 1,
        v = 1,
        nx = 0,
        ny = 1,
        nz = 0,
        r = 255,
        g = 255,
        b = 255,
        a = 255,
        colorSource = 1,
      },
      {
        x = 0,
        y = 2,
        z = 0,
        u = 0,
        v = 1,
        nx = 0,
        ny = 1,
        nz = 0,
        r = 255,
        g = 255,
        b = 255,
        a = 255,
        colorSource = 1,
      },
    },
    indices = { 0, 1, 2, 0, 2, 3 },
  }
end

local function doorDefinition()
  local program = {
    name = "door",
    scalingRule = 0,
    posScale = 1,
    invPosScale = 1,
    tileScale = 1 / 16,
    nodes = {
      {
        index = 0,
        matrixStackIndex = 0,
        translation = { x = 0, y = 0, z = 0 },
        rotation = identity9(),
        scale = { x = 1, y = 1, z = 1 },
        transZero = true,
        rotZero = true,
        scaleOne = true,
      },
    },
    commands = {
      { opcode = 0x06, nodeIndex = 0, parentIndex = 0, flags = 0 },
      { opcode = 0x02, nodeIndex = 0, visible = true },
      { opcode = 0x04, materialIndex = 0 },
      { opcode = 0x05, shapeIndex = 0 },
      { opcode = 0x01 },
    },
    evpMatrices = nil,
  }
  return ModelDefinition.new({
    key = "fixture:nitro-door",
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
        name = "wall",
        baseColor = { r = 255, g = 255, b = 255, a = 255 },
        alphaMode = "opaque",
        doubleSided = false,
        polygonAlpha = 31,
        texMtxMode = 0,
        texWidth = 0,
        texHeight = 0,
        -- The four DS base-material registers, distinct per channel (the
        -- shape NsbmdDynamicModel.baseMaterial compiles them into).
        colors = {
          diffuse = { r = 255, g = 0, b = 0 },
          ambient = { r = 0, g = 255, b = 0 },
          specular = { r = 0, g = 0, b = 255 },
          emission = { r = 123, g = 123, b = 123 },
        },
      },
    },
    skins = {},
    animations = { doorClip() },
    backend = {
      program = program,
      meshes = {
        ["draw0.seg0"] = {
          drawIndex = 0,
          positionSource = "draw",
          transformMode = "static",
          cullMode = "back",
          polygonMode = "modulation",
          polygonId = 0,
          translucentDepthWrite = false,
          depthEqual = false,
          polygonAlpha = 31,
          lightMask = 5,
        },
      },
    },
  })
end

local function buildRenders(def)
  local renderMeshesById = {}
  for _, mesh in ipairs(def.meshes) do
    local bytes = MeshWriter.encode(doorQuad())
    renderMeshesById[mesh.id] = SceneMesh.build(SceneMesh.decode(bytes))
  end
  return renderMeshesById
end

-- Test-only camera shape: the fake supplies the gameplay-visible fields
-- the renderer reads; the constructor-owned matrix buffers stay absent.
---@class ModelInstanceNitroRenderTestCamera : FieldCamera
---@field _projectionCache number[]|nil
---@field _billboardProjectionCache number[]|nil
---@field _viewBuffer Matrix4.Buffer|nil
---@field _projectionBuffer Matrix4.Buffer|nil
---@field _billboardProjectionBuffer Matrix4.Buffer|nil
---@field _viewArray number[]|nil
---@field _projectionArray number[]|nil
---@field _billboardProjectionArray number[]|nil

---@return ModelInstanceNitroRenderTestCamera
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
  } --[[@as ModelInstanceNitroRenderTestCamera]]
end

-- A runtime with a lit field-light profile: lights 0 and 2 enabled (the
-- polygon's 0b0101 mask admits exactly those two), white, head-on to the
-- quad's +Y normals, with zero ambient/specular/emission so an unlit polygon
-- renders black.
local function litRuntime()
  local white = 31 + 31 * 32 + 31 * 1024
  return {
    mapDraws = {},
    buildingDraws = {},
    stats = { triangleCount = 0, meshCount = 0, textureCount = 0 },
    edgeColors = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 },
    fog = { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = ZERO_FOG_TABLE },
    lighting = {
      records = {
        {
          startHalfSeconds = 0,
          lights = {
            { enabled = true, colorRgb555 = white, vectorFx12 = { 0, -4096, 0 } },
            { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
            { enabled = true, colorRgb555 = white, vectorFx12 = { 0, -4096, 0 } },
            { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          },
          diffuseRgb555 = white,
          ambientRgb555 = 0,
          specularRgb555 = 0,
          emissionRgb555 = 0,
        },
      },
    },
  }
end

local function drawInstance(renderer, rt, instance, alpha)
  local items = instance:drawItems(instance.renderMeshesById)
  rt.mapDraws = items
  renderer:draw(rt, identityCamera(), { items }, nil, FieldViewport.new(640, 480, { mode = "strict" }), alpha)
  return items
end

function T.nitro_animated_model_renders_and_scrubs_without_recompiling()
  local renderer = FieldRenderer.new()
  local def = doorDefinition()
  local instance = ModelInstance.new(def)
  instance.renderMeshesById = buildRenders(def)
  local rt = litRuntime()

  -- Bind pose first: the draw matrix is identity, so the quad renders at
  -- its tile-space placement.
  instance:evaluatePose()
  local items = drawInstance(renderer, rt, instance, 1)
  Assert.isTrue(renderer.stats.drawCalls >= 1, "the nitro mesh draws")

  -- The draw item carries the shader-consumed polygon state: the compiled
  -- light mask and the four DS material color registers survive to the item
  -- the renderer sends uniforms from -- never just "a draw happened".
  local item = items[1]
  Assert.equal(item.lightMask, 5, "the draw item carries the polygon light mask")
  Assert.deepEqual(item.material.matDiffuse, { 1, 0, 0 }, "the draw item carries the diffuse color")
  Assert.deepEqual(item.material.matAmbient, { 0, 1, 0 }, "the draw item carries the ambient color")
  Assert.deepEqual(item.material.matSpecular, { 0, 0, 1 }, "the draw item carries the specular color")
  Assert.near(item.material.matEmission[1], 123 / 255, 1e-9, "the draw item carries the emission color")
  Assert.near(item.material.matEmission[2], 123 / 255, 1e-9)
  Assert.near(item.material.matEmission[3], 123 / 255, 1e-9)

  -- The "draw happened but black" class: a NORMAL-lit vertex under the lit
  -- profile must render non-black -- the polygon's mask admits lights 0 and 2
  -- and both are enabled. A dropped light mask (all bits gated off) renders
  -- the frame black while drawCalls still counts. The quad spans world x,y in
  -- [0,2], so world (0.5, 0.5) is interior (canonical pixel 480,360); canvas
  -- readbacks come back Y-inverted on some drivers, so sample the pixel and
  -- its Y-mirror and require the lit half.
  local img = renderer.sceneColor:newImageData()
  local function bright(pixel)
    return pixel[1] > 0.5 or pixel[2] > 0.5 or pixel[3] > 0.5
  end
  local interior = { img:getPixel(480, 360) }
  local mirrored = { img:getPixel(480, 119) }
  Assert.isTrue(bright(interior) or bright(mirrored), "the lit masked polygon renders non-black")

  -- Scrub through several frames; the same built meshes serve every frame.
  local rendersBefore = instance.renderMeshesById
  instance:play("door.open")
  for _ = 1, 7 do
    instance:updateFixed()
    instance:evaluatePose()
    drawInstance(renderer, rt, instance, 1)
    Assert.equal(#items, 1, "one mesh per frame")
  end
  Assert.equal(instance.renderMeshesById, rendersBefore, "meshes are built once, not per frame")
  -- The final frame's rotation cells differ from the bind pose.
  Assert.isTrue(
    math.abs(instance.poseState.drawMatrices["draw0.seg0"].position[1] - 1) > 0.01,
    "scrubbed rotation reached the pose"
  )

  Assert.isNil(love.graphics.getCanvas(), "the scene canvas is unbound")
  Assert.isNil(love.graphics.getShader(), "the map and edge shaders are unbound")
  for _, mesh in pairs(instance.renderMeshesById) do
    mesh:release()
  end
  renderer:release()
end

return {
  metadata = { capabilities = { "graphics" } },
  tests = T,
}
