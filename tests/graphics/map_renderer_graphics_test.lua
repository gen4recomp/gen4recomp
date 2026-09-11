-- Graphics smoke tests for the DS lighting shader and the render pipeline.
-- These need a real offscreen context: the shaders go through the GLSL
-- compiler, the render targets are real canvases, and the state assertions read
-- back what the driver actually holds. Nothing here is skippable in the
-- supported environments — a host without the graphics capability skips the
-- whole suite explicitly through the runner.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local GxRenderer = require("libs.nds.src.love.GxRenderer")
local MapSceneLoader = require("libs.hgss.src.presentation.MapSceneLoader")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local CollisionGridAsset = require("libs.assets.src.field.CollisionGridAsset")
local LuaWriter = require("libs.codec.src.LuaWriter")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local FakeCache = require("tests.support.FakeCache")
local VertexFormat = require("libs.assets.src.model.VertexFormat")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local Matrix4 = require("libs.math.src.Matrix4")
local DsFog = require("tests.support.DsFog")
local FieldLightProfile = require("libs.assets.src.field.FieldLightProfile")
local RenderQueue = require("libs.hgss.src.presentation.RenderQueue")
local lg = love.graphics

local T = {}

local function exactRenderer(options)
  options = options or {}
  options.translucencyMode = GxRenderer.TRANSLUCENCY_EXACT
  return GxRenderer.new(options)
end

-- Spelled explicitly to keep these smokes independent of Matrix4.
local IDENTITY = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
local IDENTITY_NORMAL = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }

local function fixedCamera()
  local function identity(_)
    return IDENTITY
  end
  return { distance = 26, far = 400, view = identity, projection = identity, billboardProjection = identity }
end

local function zeroFogFixture()
  local table32 = {}
  for i = 1, 32 do
    table32[i] = 0
  end
  return { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = table32 }
end

local DRAW_ITEM_FIELDS = {
  "mesh",
  "material",
  "transform",
  "modelNormal",
  "billboardCenter",
  "billboardScale",
  "alphaClass",
  "cullMode",
  "fogEnabled",
  "lightMask",
  "polygonAlpha",
  "polygonId",
  "polygonMode",
}

local function normalizedItem(item, projection)
  local normalized = { projection = projection } ---@type table<string, unknown>
  for _, field in ipairs(DRAW_ITEM_FIELDS) do
    normalized[field] = item[field]
  end
  return normalized
end

local function normalizedQueue(queue, worldProjection, billboardProjection)
  local normalized = {
    opaque = {},
    cutout = {},
    mixedOpaque = {},
    wireframe = {},
    blended = {},
  }
  local function projectionFor(item)
    if item.billboardProjection == true or item.fieldEffect ~= nil then
      return billboardProjection
    end
    return worldProjection
  end
  for _, pass in ipairs({ "opaque", "cutout", "mixedOpaque", "wireframe" }) do
    for _, item in ipairs(queue[pass]) do
      normalized[pass][#normalized[pass] + 1] = normalizedItem(item, projectionFor(item))
    end
  end
  for _, entry in ipairs(queue.blended) do
    normalized.blended[#normalized.blended + 1] = {
      item = normalizedItem(entry.item, projectionFor(entry.item)),
      fragmentPass = entry.fragmentPass,
    }
  end
  return normalized
end

local function normalizedSprites(spriteItems, billboardProjection)
  if spriteItems == nil then
    return nil
  end
  local normalized = {}
  for _, item in ipairs(spriteItems) do
    normalized[#normalized + 1] = normalizedItem(item, billboardProjection)
  end
  return normalized
end

local function render(renderer, sceneRuntime, camera, worldParts, spriteItems, viewport)
  local viewMatrix = camera:view()
  local lighting = sceneRuntime.lighting
  if lighting and lighting.records then
    lighting =
      FieldLightProfile.select(lighting, sceneRuntime.fieldTimeSeconds or FieldLightProfile.DEFAULT_TIME_SECONDS)
  end
  local queue = RenderQueue.buildInto(worldParts or {}, viewMatrix, RenderQueue.newScratch())
  local worldProjection = camera:projection()
  local billboardProjection = camera:billboardProjection()
  return renderer:draw({
    lighting = lighting,
    edgeColors = sceneRuntime.edgeColors,
    fog = sceneRuntime.fog,
    viewMatrix = viewMatrix,
    cameraZoom = camera.zoom,
    worldProjection = worldProjection,
    billboardProjection = billboardProjection,
    queue = normalizedQueue(queue, worldProjection, billboardProjection),
    spriteItems = normalizedSprites(spriteItems, billboardProjection),
    viewport = viewport,
  })
end

-- The 32-entry fog density table is delivered as 8 groups of 4 raw entries,
-- one named uniform each (u_fogTable0..u_fogTable7): LÖVE 11.5 fills only
-- the first vec4 of a `vec4[N]` array uniform from a flat table, so a
-- single-array send could never reach entries past index 0 (see edge.glsl's
-- fogTableEntry and GxRenderer:_sendFog, which group the same way).
-- table32 is the 1-indexed 32-entry table; group i covers entries
-- 4*i+1 .. 4*i+4.
local function sendFogTableGroups(shader, table32)
  for group = 0, 7 do
    shader:send(
      "u_fogTable" .. group,
      { table32[group * 4 + 1], table32[group * 4 + 2], table32[group * 4 + 3], table32[group * 4 + 4] }
    )
  end
end

local function emptyRuntime()
  local result = {
    mapDraws = {},
    buildingDraws = {},
    stats = { triangleCount = 0, meshCount = 0, textureCount = 0 },
    edgeColors = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 },
    fog = zeroFogFixture(),
  }
  return result
end

-- A tiny mesh in the project's vertex layout, so the shader can be exercised
-- end-to-end without touching any compiled scene.
local function syntheticMesh(vertices)
  return love.graphics.newMesh(VertexFormat.LAYOUT, vertices, "triangles", "static")
end

-- Read one pixel from a renderState readback, resolving the driver's Y-mirror
-- while preserving rear-plane pixels when neither orientation contains draw state.
local function statePixelAt(renderer, stateImg, x, y)
  local a, b = { stateImg:getPixel(x, y) }, { stateImg:getPixel(x, renderer.stateH - 1 - y) }
  local function isRear(p)
    return p[1] >= 0.99 and p[4] <= 0.0005
  end
  if not isRear(a) then
    return a
  end
  if not isRear(b) then
    return b
  end
  return a[1] <= b[1] and a or b
end

function T.shader_compiles(scope)
  local renderer = scope:own(exactRenderer())

  Assert.notNil(renderer.shader)
end

function T.shader_has_required_lighting_uniforms(scope)
  local shader = scope:own(GxRenderer.new()).shader

  -- Presence is checked by sending a value; LÖVE errors for unknown names.
  -- The u_mat* uniforms carry the effective DS material registers (the
  -- field profile, overridden by any playing NSBMA color clip).
  shader:send("u_lightEnabled0", true)
  shader:send("u_lightVector0", { 0, 0, -1 })
  shader:send("u_lightColor0", { 1, 1, 1 })
  shader:send("u_matDiffuse", { 1, 1, 1 })
  shader:send("u_matAmbient", { 0, 0, 0 })
  shader:send("u_matSpecular", { 0, 0, 0 })
  shader:send("u_matEmission", { 0, 0, 0 })
end

function T.shader_has_model_normal_uniform(scope)
  local renderer = scope:own(exactRenderer())

  -- Sent as a 3x3 column-major matrix (nine values).
  renderer.shader:send("u_modelNormal", "column", IDENTITY_NORMAL)
end

function T.shader_has_billboard_uniforms(scope)
  local shader = scope:own(GxRenderer.new()).shader

  shader:send("u_billboard", true)
  shader:send("u_billboardCenter", { 3, 4, 5 })
  shader:send("u_billboardScale", { 2, 3, 4 })
end

function T.shader_has_polygon_light_mask_uniform(scope)
  local shader = scope:own(GxRenderer.new()).shader

  -- Presence is checked by sending a value; LÖVE errors for unknown names.
  shader:send("u_lightMask", { 1, 0, 0, 0 })
  shader:send("u_lightMask", { 0, 1, 0, 1 })
end

-- Fog is a DS final-pass operation (GBATEK "3D Display - Fog": edge marking,
-- then fog, over the whole composited scene), not a per-object color-path
-- effect -- so the geometry/fragment-combiner shader (map.glsl) must not own
-- the global fog gate, color, table, or offset. It still carries this draw's
-- own per-polygon fog gate (POLYGON_ATTR FOG_ENABLE) into renderState's blue
-- channel (see opaque_draw_writes_its_fog_gate_into_the_final_state_blue_channel
-- below); that per-item bit is not a "fog uniform" in the sense retired here.
-- Absence is checked the same way edge_shader_has_no_alpha_mix_uniform checks
-- it: LÖVE errors when a name is not a real uniform of the compiled shader.
function T.map_shader_has_no_global_fog_uniforms(scope)
  local shader = scope:own(GxRenderer.new()).shader

  Assert.throws(function()
    shader:send("u_fogEnabled", true)
  end)
  Assert.throws(function()
    shader:send("u_fogColor", { 0.5, 0.5, 0.5 })
  end)
  Assert.throws(function()
    shader:send("u_fogTable", { 0, 0, 0, 0 })
  end)
  Assert.throws(function()
    shader:send("u_fogOffset", 0)
  end)
end

-- The final full-screen pass (edgeShader/edge.glsl) is where fog now lives:
-- it owns the global gate, color, 32-entry density table, the shift/slope
-- field, and the offset already converted into the depth domain
-- (u_fogOffsetDepth = fogOffsetRaw * 0x200 -- GxRenderer's per-frame state
-- capture does this multiply once, not the shader per pixel; see
-- runFinalPass below for the exact contract every fog behavior test drives).
-- Presence is checked by sending a value; LÖVE errors for unknown names, so
-- this only passes once the final pass actually declares them.
function T.final_shader_has_fog_uniforms(scope)
  local shader = scope:own(GxRenderer.new()).edgeShader

  local zeroFogTable = {}
  for i = 1, 32 do
    zeroFogTable[i] = 0
  end

  shader:send("u_fogEnabled", true)
  shader:send("u_fogColor", { 0.5, 0.5, 0.5 })
  sendFogTableGroups(shader, zeroFogTable)
  shader:send("u_fogOffsetDepth", 0)
  shader:send("u_fogShift", 0)
  shader:send("u_fogAlpha", 31)
end

-- The DS composites edge color by RGB replacement, not an alpha-mix
-- scalar, so the fidelity shader carries no alpha-mix uniform to blend
-- against. Absence is checked the same way presence is checked elsewhere in
-- this suite: LÖVE errors when a name is not a real uniform of the compiled
-- shader.
function T.edge_shader_has_no_alpha_mix_uniform(scope)
  local edgeShader = scope:own(GxRenderer.new()).edgeShader

  Assert.throws(function()
    edgeShader:send("u_edgeAlpha", 0.5)
  end)
end

function T.field_viewport_sizes_and_rebuilds_render_targets(scope)
  local renderer = scope:own(GxRenderer.new())
  local camera, runtime = fixedCamera(), emptyRuntime()

  local viewport = FieldViewport.new(1280, 720, { mode = "strict" })
  render(renderer, runtime, camera, nil, nil, viewport)
  Assert.equal(renderer.colorW, 960)
  Assert.equal(renderer.colorH, 720)

  viewport = FieldViewport.new(1280, 720, { mode = "expanded" })
  for _ = 1, 10 do
    for _, size in ipairs({ { 960, 720 }, { 1280, 720 }, { 1680, 720 }, { 2560, 720 } }) do
      viewport:resize(size[1], size[2])
      render(renderer, runtime, camera, nil, nil, viewport)
    end
  end
  viewport:resize(1280, 720)
  render(renderer, runtime, camera, nil, nil, viewport)
  Assert.equal(renderer.colorW, 1280)
  Assert.equal(renderer.colorH, 720)
end

-- The color target always matches the display viewport exactly (no tunable
-- scale); the render-state target shares the color target's exact dimensions
-- at every host size (one-to-one screen coverage -- state classification is
-- never downsampled), and both sceneColor and renderState are nearest-filtered
-- on the real driver.
function T.color_and_state_targets_share_the_color_resolution_and_nearest_filter(scope)
  local renderer = scope:own(GxRenderer.new())
  local camera, runtime = fixedCamera(), emptyRuntime()

  local viewport = FieldViewport.new(1280, 720, { mode = "expanded" })
  render(renderer, runtime, camera, nil, nil, viewport)
  Assert.equal(renderer.colorW, 1280, "the color target matches the display viewport exactly")
  Assert.equal(renderer.colorH, 720)
  Assert.equal(renderer.stateW, 1280, "the state target shares the color width")
  Assert.equal(renderer.stateH, 720, "the state target shares the color height")
  local sceneMin, sceneMag = renderer.sceneColor:getFilter()
  Assert.equal(sceneMin, "nearest", "sceneColor is nearest-filtered")
  Assert.equal(sceneMag, "nearest")
  local stateMin, stateMag = renderer.renderState:getFilter()
  Assert.equal(stateMin, "nearest", "renderState is nearest-filtered")
  Assert.equal(stateMag, "nearest")

  local mrtTargets = renderer._colorTargets
  for _, size in ipairs({ { 1920, 1080 }, { 2560, 1440 } }) do
    viewport:resize(size[1], size[2])
    render(renderer, runtime, camera, nil, nil, viewport)
    Assert.equal(renderer.colorW, size[1], "the color target follows the new display size exactly")
    Assert.equal(renderer.colorH, size[2])
    Assert.equal(renderer.stateW, size[1], "the state target follows the new display size exactly")
    Assert.equal(renderer.stateH, size[2])
    Assert.isTrue(
      renderer._colorTargets ~= mrtTargets,
      "the renderer replaces the whole atomic target set on any dimension change"
    )
    mrtTargets = renderer._colorTargets
  end
end

-- An actor draw is a cutout billboard submitted as an overlay item, and it sets
-- per-item cull, depth, and alpha state. Nothing it touches may survive the
-- frame, or the 2D dialogue UI and the next map's draws inherit it.
function T.an_actor_billboard_draw_leaks_no_render_state(scope)
  local renderer = scope:own(GxRenderer.new())
  local mesh = scope:own(syntheticMesh({
    { -1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 1 },
    { 1, 0, 0, 1, 1, 0, 0, 1, 0, 0, 0, 1, 1 },
    { 1, 2, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1 },
  }))
  local actor = {
    mesh = mesh,
    material = { alphaClass = "cutout", texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
    transform = IDENTITY,
    modelNormal = IDENTITY_NORMAL,
    billboardBase = IDENTITY,
    billboardCenter = { 0, 0, 0 },
    billboardScale = { 1, 1, 1 },
    alphaClass = "cutout",
    cullMode = "back",
    polygonAlpha = 1.0,
    polygonMode = "modulation",
    polygonId = 0,
    lightMask = 1,
    alphaCutoff = 0.5 / 255,
    center = { 0, 1, 0 },
  }

  lg.setMeshCullMode("none")
  lg.setBlendMode("alpha")
  lg.setColor(1, 1, 1, 1)
  render(renderer, emptyRuntime(), fixedCamera(), { { actor } }, nil, FieldViewport.new(640, 480, { mode = "strict" }))

  Assert.isNil(lg.getCanvas(), "the scene canvas is unbound")
  Assert.isNil(lg.getShader(), "the map and edge shaders are unbound")
  Assert.equal(lg.getMeshCullMode(), "none")
  Assert.equal(lg.getBlendMode(), "alpha")
  Assert.isFalse(lg.isWireframe())
  local compare, depthWrite = lg.getDepthMode()
  Assert.equal(compare, "always", "depth testing is left disabled")
  Assert.isFalse(depthWrite)
end

function T.literal_color_triangle_ignores_light_direction(scope)
  local shader = scope:own(GxRenderer.new()).shader

  shader:send("u_proj", "column", IDENTITY)
  shader:send("u_view", "column", IDENTITY)
  shader:send("u_model", "column", IDENTITY)
  shader:send("u_modelNormal", "column", IDENTITY_NORMAL)

  -- Two light directions that would change a lit vertex, but must not affect a
  -- literal-color one.
  for _, vector in ipairs({ { 0, 0, -1 }, { 0, 0, 1 } }) do
    shader:send("u_lightEnabled0", true)
    shader:send("u_lightVector0", vector)
    shader:send("u_lightColor0", { 1, 0, 0 })
    shader:send("u_matDiffuse", { 1, 1, 1 })
    shader:send("u_matAmbient", { 0, 0, 0 })
    shader:send("u_matSpecular", { 0, 0, 0 })
    shader:send("u_matEmission", { 0, 0, 0 })
    shader:send("u_useTexture", false)
    shader:send("u_fragmentPass", 0)
    shader:send("u_polygonAlpha", 1.0)
    shader:send("u_polygonMode", 0)

    local mesh = scope:own(syntheticMesh({
      { 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0 },
      { 1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0 },
      { 0, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0 },
    }))
    love.graphics.setShader(shader)
    love.graphics.draw(mesh)
    love.graphics.setShader()
  end
end

-- A 1x1 solid-color texture at the given alpha (0-255 scale, matching this
-- file's other synthetic PNG helpers).
local function solidAlphaImage(scope, r, g, b, alpha)
  local data = love.image.newImageData(1, 1)
  data:setPixel(0, 0, r / 255, g / 255, b / 255, alpha / 255)
  return scope:own(love.graphics.newImage(data))
end

-- Presentation depth tests must exercise the same explicit depth attachment
-- used by the renderer on a real offscreen target, rather than relying on a
-- window-provided depth buffer.
local function presentationTarget(scope, width, height)
  local color = scope:own(love.graphics.newCanvas(width, height))
  local depth = scope:own(love.graphics.newCanvas(width, height, {
    format = "depth24stencil8",
    readable = false,
  }))
  local target = { color, depthstencil = depth }
  -- GxRenderer treats its presentation target as a Canvas when calculating
  -- viewport mapping, while LÖVE accepts the explicit color/depth descriptor
  -- for setCanvas. Keep both contracts on the same test-owned target.
  function target:getWidth()
    return color:getWidth()
  end
  function target:getHeight()
    return color:getHeight()
  end
  return target, color
end

-- A green literal-color triangle (colorSource 0) covering the same screen
-- area polygon_light_mask_changes_the_rendered_result samples: interior at
-- canvas (416, 384) or its Y-mirror (416, 95), whichever the driver's
-- readback lands on.
local function decalTriangle(scope)
  return scope:own(syntheticMesh({
    { 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0 },
    { 1, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 1, 0 },
    { 0, 1, 0, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0 },
  }))
end

local function decalItem(mesh, image)
  return {
    mesh = mesh,
    material = { alphaClass = "opaque", texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }, image = image },
    transform = IDENTITY,
    modelNormal = IDENTITY_NORMAL,
    alphaClass = "opaque",
    cullMode = "none",
    polygonAlpha = 1.0,
    polygonMode = "decal",
    polygonId = 0,
    lightMask = 0,
    alphaCutoff = 0.5 / 255,
    center = { 0.5, 0.5, 0 },
  }
end

-- The brighter of the two candidate interior samples (readbacks come back
-- Y-inverted on some GL drivers, so exactly one of (416,384)/(416,95) is
-- interior against the black clear color; the other reads pure background).
local function decalInteriorSample(renderer)
  local img = renderer.sceneColor:newImageData()
  local a, b = { img:getPixel(416, 384) }, { img:getPixel(416, 95) }
  local function sum(p)
    return p[1] + p[2] + p[3]
  end
  return sum(a) >= sum(b) and a or b
end

function T.wireframe_rasterizes_edges_without_filling_the_interior(scope)
  local renderer = scope:own(GxRenderer.new())
  local mesh = scope:own(syntheticMesh({
    { 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 0, 1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
  }))
  local item = {
    mesh = mesh,
    material = { alphaClass = "wireframe", texMatrix = IDENTITY_NORMAL },
    transform = IDENTITY,
    modelNormal = IDENTITY_NORMAL,
    alphaClass = "wireframe",
    cullMode = "none",
    polygonAlpha = 1,
    polygonMode = "modulation",
    polygonId = 1,
    lightMask = 0,
    alphaCutoff = 0.5 / 255,
    center = { 0.5, 0.5, 0 },
  }

  render(renderer, emptyRuntime(), fixedCamera(), { { item } }, nil, FieldViewport.new(640, 480, { mode = "strict" }))
  local image = renderer.sceneColor:newImageData()
  local function brightness(x, y)
    local a = { image:getPixel(x, y) }
    local b = { image:getPixel(x, renderer.colorH - 1 - y) }
    return math.max(a[1] + a[2] + a[3], b[1] + b[2] + b[3])
  end

  Assert.isTrue(brightness(480, 180) < 0.1, "wireframe interior preserves the underlying scene")
  Assert.isTrue(brightness(480, 120) > 0.5, "wireframe edge remains visible")
end

-- DS DECAL keeps the texture RGB only where the texel is fully opaque
-- (texture alpha 31/31); a fully transparent decal texel (alpha 0) must
-- render the vertex color untouched instead (GBATEK DECAL texel format).
function T.decal_zero_texture_alpha_renders_vertex_color(scope)
  local renderer = scope:own(GxRenderer.new())
  local image = solidAlphaImage(scope, 255, 0, 0, 0)
  local item = decalItem(decalTriangle(scope), image)

  render(renderer, emptyRuntime(), fixedCamera(), { { item } }, nil, FieldViewport.new(640, 480, { mode = "strict" }))

  local p = decalInteriorSample(renderer)
  local scale = p[2] > 1 and 255 or 1
  Assert.isTrue(p[2] >= 0.5 * scale, "a fully transparent decal texel must render the vertex color's green channel")
  Assert.isTrue(p[1] < 0.5 * scale, "a fully transparent decal texel must not render the texture's red channel")
end

-- A partially transparent DECAL texel (texture alpha strictly between 0 and
-- 31/31) must interpolate texture and vertex RGB with melonDS's exact
-- divide-by-32, not a divide-by-31: texture6=63 (a fully white, fully opaque
-- texel), vertex6=0 (a black literal vertex color), textureAlpha5=16 (alpha
-- byte 131 -> floor(131/255*31+0.5) = 16) must produce exactly
-- floor((63*16 + 0*15)/32) = 31, not the /31 formula's 32 (GBATEK DECAL
-- texel format). This numeric fixture replaces a prior broad "some green is
-- present" assertion that could not have caught the wrong divisor.
function T.decal_partial_texture_alpha_uses_the_exact_divide_by_32(scope)
  local renderer = scope:own(GxRenderer.new())
  local blackVertexTriangle = scope:own(syntheticMesh({
    { 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0 },
    { 1, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0 },
    { 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0 },
  }))
  local image = solidAlphaImage(scope, 255, 255, 255, 131)
  local item = decalItem(blackVertexTriangle, image)

  render(renderer, emptyRuntime(), fixedCamera(), { { item } }, nil, FieldViewport.new(640, 480, { mode = "strict" }))

  local p = decalInteriorSample(renderer)
  local scale = p[1] > 1 and 255 or 1
  -- Half a 6-bit combiner step, scaled to whichever readback domain the
  -- driver used: tight enough to separate 31/63 from the /31 formula's
  -- neighboring value 32/63, unlike a flat tolerance of 1 (which is wider
  -- than the entire 0..1 readback domain some drivers here return, and so
  -- can never fail).
  local tolerance = 0.5 * scale / 63
  Assert.near(p[1], 31 / 63 * scale, tolerance, "decal red: floor((63*16+0*15)/32) = 31, not the /31 formula's 32")
  Assert.near(p[2], 31 / 63 * scale, tolerance, "decal green: floor((63*16+0*15)/32) = 31")
  Assert.near(p[3], 31 / 63 * scale, tolerance, "decal blue: floor((63*16+0*15)/32) = 31")
end

-- A literal-color vertex triangle (colorSource 0) for the MODULATE test
-- below: r/g/b are set per call so a nontrivial, non-identity vertex color
-- can be paired with a nontrivial texture color.
local function modulateTriangle(scope, r, g, b)
  return scope:own(syntheticMesh({
    { 0, 0, 0, 0, 0, 0, 0, 1, r, g, b, 1, 0 },
    { 1, 0, 0, 1, 0, 0, 0, 1, r, g, b, 1, 0 },
    { 0, 1, 0, 0, 1, 0, 0, 1, r, g, b, 1, 0 },
  }))
end

-- MODULATE, the DS integer combiner (map.glsl's modulateRgb6/
-- modulateComponent6), at a nontrivial midrange value -- not an
-- identity/full-white or zero edge case. Both operands enter 5-bit
-- quantized then widened to 6-bit by melonDS's expand5to6 (0 -> 0, n ->
-- 2n+1) before combining:
--   modulateComponent6(t6, v6) = floor(((t6+1)*(v6+1)-1)/64)
-- Texture (200,100,50)/255 -> texture5 = floor(c*31+0.5) = (24,12,6) ->
-- texture6 = expand5to6 = (49,25,13). A literal vertex color (colorSource 0)
-- (128,64,200)/255 is truncated, not rounded, by the vertex stage's
-- quantizeRgb5 (floor(c*31), no +0.5) -> vertex5 = (15,7,24) -> vertex6 =
-- (31,15,49). Per channel: R floor((50*32-1)/64)=24, G
-- floor((26*16-1)/64)=6, B floor((14*50-1)/64)=10.
function T.modulate_combines_texture_and_vertex_color_at_a_nontrivial_midrange_value(scope)
  local renderer = scope:own(GxRenderer.new())
  local image = solidAlphaImage(scope, 200, 100, 50, 255)
  local item = decalItem(modulateTriangle(scope, 128 / 255, 64 / 255, 200 / 255), image)
  item.polygonMode = "modulation"

  render(renderer, emptyRuntime(), fixedCamera(), { { item } }, nil, FieldViewport.new(640, 480, { mode = "strict" }))

  local p = decalInteriorSample(renderer)
  local scale = p[1] > 1 and 255 or 1
  -- Half a 6-bit combiner step, scaled to the readback domain: a flat
  -- tolerance of 1 is wider than the entire 0..1 domain some drivers here
  -- return, and so could never fail.
  local tolerance = 0.5 * scale / 63
  Assert.near(p[1], 24 / 63 * scale, tolerance, "modulate red channel: floor((50*32-1)/64) = 24")
  Assert.near(p[2], 6 / 63 * scale, tolerance, "modulate green channel: floor((26*16-1)/64) = 6")
  Assert.near(p[3], 10 / 63 * scale, tolerance, "modulate blue channel: floor((14*50-1)/64) = 10")
end

-- The locked melonDS 5-bit-to-6-bit expansion table (map.glsl's
-- expand5to6): 0 stays 0, any non-zero n becomes 2n+1. The texture bytes
-- below are chosen so floor(byte/255*31+0.5) lands exactly on each locked
-- source value {0,1,4,15,16,31}. Vertex color is full white (literal,
-- colorSource 0), which quantizes to vertex5=31 -> vertex6=63 --
-- MODULATE's identity element (modulateComponent6(t6,63) = t6 exactly) --
-- so the readback isolates expand5to6's own output on the texture operand.
-- The previous floor(c5/16) expansion only disagrees with this table at
-- n in {1,4,15} (n=0, 16, and 31 happen to coincide under both formulas),
-- so this fixture must include at least one of those discriminating values.
local EXPAND5TO6_LOCKED_CASES = {
  { byte = 0, source5 = 0, expected6 = 0 },
  { byte = 8, source5 = 1, expected6 = 3 },
  { byte = 32, source5 = 4, expected6 = 9 },
  { byte = 123, source5 = 15, expected6 = 31 },
  { byte = 131, source5 = 16, expected6 = 33 },
  { byte = 255, source5 = 31, expected6 = 63 },
}

function T.expand5to6_matches_the_locked_melonds_table(scope)
  for _, case in ipairs(EXPAND5TO6_LOCKED_CASES) do
    local renderer = scope:own(GxRenderer.new())
    local image = solidAlphaImage(scope, case.byte, case.byte, case.byte, 255)
    local item = decalItem(modulateTriangle(scope, 1, 1, 1), image)
    item.polygonMode = "modulation"

    render(renderer, emptyRuntime(), fixedCamera(), { { item } }, nil, FieldViewport.new(640, 480, { mode = "strict" }))

    local p = decalInteriorSample(renderer)
    local scale = p[1] > 1 and 255 or 1
    -- Half a 6-bit combiner step, scaled to the readback domain: a flat
    -- tolerance of 1 is wider than the entire 0..1 domain some drivers here
    -- return, and so could never fail.
    local tolerance = 0.5 * scale / 63
    Assert.near(
      p[1],
      case.expected6 / 63 * scale,
      tolerance,
      string.format(
        "5-bit source %d must expand to 6-bit %d (melonDS: 0 -> 0, n -> 2n+1)",
        case.source5,
        case.expected6
      )
    )
  end
end

-- A cutout fragment whose combined alpha falls below alphaCutoff must
-- discard rather than write a below-threshold pixel: DS cutout draws
-- (grass, fences) render exactly two states, transparent or opaque, never a
-- partial blend (GBATEK POLYGON_ATTR alpha=0 -> transparent). A fully
-- transparent texel (textureAlpha5 = 0) makes the MODULATE alpha combiner
-- floor(((0+1)*(31+1)-1)/32) = 0, normalized alpha 0, below alphaCutoff --
-- the fragment must discard, leaving the injected clear color untouched
-- rather than blending toward it.
function T.cutout_zero_alpha_fragment_discards_instead_of_rendering(scope)
  local clearColor = { 0.1, 0.2, 0.3, 1 }
  local renderer = scope:own(GxRenderer.new({ clearColor = clearColor }))
  local image = solidAlphaImage(scope, 255, 0, 0, 0)
  local item = decalItem(decalTriangle(scope), image)
  item.polygonMode = "modulation"
  item.alphaClass = "cutout"

  render(renderer, emptyRuntime(), fixedCamera(), { { item } }, nil, FieldViewport.new(640, 480, { mode = "strict" }))

  local p = decalInteriorSample(renderer)
  local scale = p[1] > 1 and 255 or 1
  Assert.near(p[1], clearColor[1] * scale, 0.05 * scale, "a discarded cutout fragment leaves the clear color's red")
  Assert.near(p[2], clearColor[2] * scale, 0.05 * scale, "a discarded cutout fragment leaves the clear color's green")
  Assert.near(p[3], clearColor[3] * scale, 0.05 * scale, "a discarded cutout fragment leaves the clear color's blue")
end

-- Maps a color-space sample coordinate (chosen for convenient hand-picked
-- interior pixels against a 640x480 sceneColor canvas) to the corresponding
-- sample in the render-state canvas. The state raster shares the color
-- raster's dimensions (full-resolution contract), so the mapping is the
-- identity -- the renderer's own stateW/stateH fields are used so the helper
-- stays correct even if a future contract changes the size relationship.
local function statePixel(renderer, colorX, colorY)
  local x = math.min(renderer.stateW - 1, math.floor(colorX * renderer.stateW / renderer.colorW))
  local y = math.min(renderer.stateH - 1, math.floor(colorY * renderer.stateH / renderer.colorH))
  return x, y
end

-- A full unit-square quad (2 triangles, 6 vertices, no vertex map), UV
-- matching position exactly like decalTriangle's convention -- used by the
-- mixed-alpha fixtures below, which need five distinct horizontal texel
-- columns rather than decalTriangle's single right-triangle footprint.
local function unitSquareQuad(scope, r, g, b)
  return scope:own(syntheticMesh({
    { 0, 0, 0, 0, 0, 0, 0, 1, r, g, b, 1, 0 },
    { 1, 0, 0, 1, 0, 0, 0, 1, r, g, b, 1, 0 },
    { 1, 1, 0, 1, 1, 0, 0, 1, r, g, b, 1, 0 },
    { 0, 0, 0, 0, 0, 0, 0, 1, r, g, b, 1, 0 },
    { 1, 1, 0, 1, 1, 0, 0, 1, r, g, b, 1, 0 },
    { 0, 1, 0, 0, 1, 0, 0, 1, r, g, b, 1, 0 },
  }))
end

-- A 5x1 white texture whose bytes decode to the exact locked alpha5 values
-- 0, 1, 15, 30, 31 (see EXPAND5TO6_LOCKED_CASES above for the byte ->
-- floor(byte/255*31+0.5) derivation of the middle three).
local function mixedAlphaTexture(scope)
  local data = love.image.newImageData(5, 1)
  local bytes = { 0, 8, 123, 245, 255 }
  for i, byte in ipairs(bytes) do
    data:setPixel(i - 1, 0, 1, 1, 1, byte / 255)
  end
  local image = scope:own(love.graphics.newImage(data))
  image:setFilter("nearest", "nearest")
  return image
end

-- World/clip -> canvas pixel under the identity camera (projection.glsl's
-- clip.y negation), the same formula the straddle/terrain-animation fixtures
-- in this file already validate against real draws.
local function clipPixel(w, h, x, y)
  return math.floor((x + 1) / 2 * w + 0.5), math.floor((1 - y) / 2 * h + 0.5)
end

-- Sample the brighter (non-background) of a pixel and its Y-mirror, exactly
-- like decalInteriorSample -- generalized to an arbitrary image/coordinate so
-- the mixed-alpha fixtures can probe all five texel columns.
local function interiorSample(imageData, h, x, y)
  local a, b = { imageData:getPixel(x, y) }, { imageData:getPixel(x, h - 1 - y) }
  local function sum(p)
    return p[1] + p[2] + p[3]
  end
  return sum(a) >= sum(b) and a or b
end

local function mixedItem(mesh, image)
  return {
    mesh = mesh,
    material = { texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }, image = image },
    transform = IDENTITY,
    modelNormal = IDENTITY_NORMAL,
    alphaClass = "mixed",
    cullMode = "none",
    polygonAlpha = 1.0,
    polygonMode = "modulation",
    polygonId = 3,
    lightMask = 0,
    fogEnabled = true,
    alphaCutoff = 0.5 / 255,
    translucentDepthWrite = false,
    center = { 0.5, 0.5, 0 },
  }
end

-- The central regression (a MODULATE polygon at
-- polygon alpha 31 whose texture mixes fully opaque, fully transparent, and
-- partial texels must split into an opaque semantic/color subpass and a
-- translucent color-only subpass by the fragment's own exact final alpha5,
-- never by texture format alone). Five texture columns carry alpha5 = 0, 1,
-- 15, 30, 31.
function T.mixed_modulate_splits_opaque_and_translucent_by_exact_final_alpha5(scope)
  local renderer = scope:own(GxRenderer.new())
  local texture = mixedAlphaTexture(scope)
  local item = mixedItem(unitSquareQuad(scope, 1, 1, 1), texture)
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })

  render(renderer, emptyRuntime(), fixedCamera(), { { item } }, nil, viewport)

  local colorImg = renderer.sceneColor:newImageData()
  local stateImg = renderer.renderState:newImageData()
  local alphas5 = { 0, 1, 15, 30, 31 }

  for i, a5 in ipairs(alphas5) do
    local u = (i - 0.5) / 5
    local cx, cy = clipPixel(renderer.colorW, renderer.colorH, u, 0.5)
    local color = interiorSample(colorImg, renderer.colorH, cx, cy)
    local colorScale = color[1] > 1 and 255 or 1

    local sx, sy = statePixel(renderer, cx, cy)
    local mirrorX, mirrorY = statePixel(renderer, cx, renderer.colorH - 1 - cy)
    local statePixelValue = { stateImg:getPixel(sx, sy) }
    local stateMirrorValue = { stateImg:getPixel(mirrorX, mirrorY) }
    -- Whichever candidate is not the rear-plane clear (r == 1.0, id 63)
    -- carries this texel's own render state, if any was stamped.
    local stateValue = statePixelValue[1] < 0.99 and statePixelValue or stateMirrorValue
    local semanticStamped = stateValue[1] < 0.99

    if a5 == 0 then
      Assert.isTrue(
        color[1] <= 0.05 * colorScale and color[2] <= 0.05 * colorScale and color[3] <= 0.05 * colorScale,
        "alpha5=0 discards everywhere, leaving the black clear color"
      )
      Assert.isFalse(semanticStamped, "alpha5=0 never contributes semantic state")
    elseif a5 == 31 then
      Assert.isTrue(
        color[1] >= 0.9 * colorScale,
        "alpha5=31 is the only texel visible via the opaque mixed subpass, at full brightness"
      )
      Assert.isTrue(semanticStamped, "alpha5=31 is the only texel that stamps semantic state")
      Assert.near(stateValue[1], item.polygonId / 63, 1 / 255, "the stamped id is this item's own real polygon id")
    else
      -- A fully white fragment alpha-blended over the black clear color
      -- reads back exactly its own alpha fraction (src*alpha + dst*(1-alpha)
      -- == alpha here): a direct numeric check that this texel actually
      -- blended at its own exact final alpha, not merely "some visible
      -- change".
      Assert.near(
        color[1],
        (a5 / 31) * colorScale,
        0.08 * colorScale,
        "alpha5 in 1..30 blends translucently in color only, at its own exact alpha (a5=" .. a5 .. ")"
      )
      Assert.isFalse(semanticStamped, "a partial-alpha mixed texel never contributes opaque semantic state")
    end
  end
end

-- DECAL final alpha is polygon alpha unconditionally -- a polygon-alpha-31
-- DECAL material must be fully opaque, including a fully-transparent-texture
-- texel, and the classifier already returns OPAQUE for it (not MIXED): the
-- renderer must draw it through the ordinary opaque world pass, never
-- split it into an opaque/translucent pair.
function T.decal_polygon_alpha_31_is_opaque_regardless_of_texture_alpha(scope)
  local renderer = scope:own(GxRenderer.new())
  local image = solidAlphaImage(scope, 255, 0, 0, 0)
  local item = decalItem(decalTriangle(scope), image)
  item.polygonId = 9
  item.fogEnabled = false

  render(renderer, emptyRuntime(), fixedCamera(), { { item } }, nil, FieldViewport.new(640, 480, { mode = "strict" }))

  local p = decalInteriorSample(renderer)
  local scale = p[2] > 1 and 255 or 1
  Assert.isTrue(p[2] >= 0.5 * scale, "the fully transparent decal texel still renders opaque vertex-color green")

  local stateImg = renderer.renderState:newImageData()
  local ax, ay = statePixel(renderer, 416, 384)
  local bx, by = statePixel(renderer, 416, 95)
  local a, b = { stateImg:getPixel(ax, ay) }, { stateImg:getPixel(bx, by) }
  local stateValue = a[1] < 0.99 and a or b
  Assert.near(
    stateValue[1],
    item.polygonId / 63,
    1 / 255,
    "DECAL at alpha 31 stamps semantic state like any opaque draw"
  )
end

-- A DECAL polygon at a below-31 polygon alpha is translucent regardless of
-- texture alpha distribution (the classifier already returns TRANSLUCENT for
-- it): it must never contribute semantic state.
function T.decal_polygon_alpha_below_31_is_translucent_and_never_stamps_semantic_state(scope)
  local renderer = scope:own(GxRenderer.new())
  local image = solidAlphaImage(scope, 255, 0, 0, 255)
  local item = decalItem(decalTriangle(scope), image)
  item.alphaClass = "translucent"
  item.polygonAlpha = 20 / 31
  item.translucentDepthWrite = false

  render(renderer, emptyRuntime(), fixedCamera(), { { item } }, nil, FieldViewport.new(640, 480, { mode = "strict" }))

  local stateImg = renderer.renderState:newImageData()
  local ax, ay = statePixel(renderer, 416, 384)
  local bx, by = statePixel(renderer, 416, 95)
  local a, b = { stateImg:getPixel(ax, ay) }, { stateImg:getPixel(bx, by) }
  Assert.near(a[1], 1.0, 1 / 255, "a translucent DECAL draw never reaches the world MRT (rear-plane id survives)")
  Assert.near(b[1], 1.0, 1 / 255)
end

-- Exact caller-state restoration on a real driver: with non-default caller
-- state (a bound canvas, an active shader, add blending,
-- depth testing, wireframe, back-face culling, a tinted color) every modified
-- state must come back to the exact captured value -- the scene's cutout
-- actor and a wireframe item dirty cull mode and the wireframe state during
-- the draw -- and the scissor the renderer never touches must be left alone
-- -- or the 2D dialogue UI and the next map's draws inherit it. Colors
-- round-trip through float32 on some GL drivers, so they are compared within
-- a small tolerance.
function T.draw_restores_exact_caller_state_on_real_graphics(scope)
  local renderer = scope:own(GxRenderer.new())
  local camera, runtime = fixedCamera(), emptyRuntime()
  local mesh = scope:own(syntheticMesh({
    { -1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 1 },
    { 1, 0, 0, 1, 1, 0, 0, 1, 0, 0, 0, 1, 1 },
    { 1, 2, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1 },
  }))
  local actor = {
    mesh = mesh,
    material = { alphaClass = "cutout", texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
    transform = IDENTITY,
    modelNormal = IDENTITY_NORMAL,
    billboardBase = IDENTITY,
    billboardCenter = { 0, 0, 0 },
    billboardScale = { 1, 1, 1 },
    alphaClass = "cutout",
    cullMode = "back",
    polygonAlpha = 1.0,
    polygonMode = "modulation",
    polygonId = 0,
    lightMask = 1,
    alphaCutoff = 0.5 / 255,
    center = { 0, 1, 0 },
  }
  local wireframeItem = {
    mesh = mesh,
    alphaClass = "wireframe",
    transform = IDENTITY,
    modelNormal = IDENTITY_NORMAL,
    cullMode = "none",
    polygonAlpha = 1.0,
    polygonMode = "modulation",
    polygonId = 0,
    lightMask = 1,
    alphaCutoff = 0.5 / 255,
    center = { 0, 1, 0 },
  }

  local canvas = scope:own(lg.newCanvas(64, 64))
  local shader = renderer.edgeShader
  lg.setCanvas(canvas)
  lg.setShader(shader)
  lg.setBlendMode("add")
  lg.setDepthMode("lequal", true)
  lg.setWireframe(true)
  lg.setMeshCullMode("back")
  lg.setColor(0.2, 0.4, 0.6, 0.8)
  lg.setScissor(4, 8, 32, 16)

  render(renderer, runtime, camera, { { actor, wireframeItem } }, nil, FieldViewport.new(640, 480, { mode = "strict" }))

  Assert.equal(lg.getCanvas(), canvas, "the pre-draw canvas is re-bound")
  Assert.equal(lg.getShader(), shader, "the pre-draw shader is re-bound")
  local blend, alpha = lg.getBlendMode()
  Assert.equal(blend, "add")
  Assert.equal(alpha, "alphamultiply")
  local depthMode, depthWrite = lg.getDepthMode()
  Assert.equal(depthMode, "lequal")
  Assert.equal(depthWrite, true)
  Assert.equal(lg.isWireframe(), true)
  Assert.equal(lg.getMeshCullMode(), "back")
  local r, g, b, a = lg.getColor()
  Assert.near(r, 0.2, 1e-6)
  Assert.near(g, 0.4, 1e-6)
  Assert.near(b, 0.6, 1e-6)
  Assert.near(a, 0.8, 1e-6)
  local sx, sy, sw, sh = lg.getScissor()
  Assert.equal(sx, 4, "scissor x is untouched")
  Assert.equal(sy, 8, "scissor y is untouched")
  Assert.equal(sw, 32, "scissor width is untouched")
  Assert.equal(sh, 16, "scissor height is untouched")
end

-- End-to-end per-polygon light-mask behavior: the same triangle, material,
-- and profile render different colors under different polygon light masks. The
-- lit mask draws the head-on white light, the zero mask renders
-- emission-only (black). Canvas readbacks come back Y-inverted on some GL
-- drivers, so each triangle is sampled at both its canonical position and
-- its mirrored position; exactly one of the two is interior in any
-- environment. The readback scale is likewise driver-dependent (0..255 or
-- 0..1), so the brightness threshold is derived from an actual sample.
function T.polygon_light_mask_changes_the_rendered_result(scope)
  local renderer = scope:own(GxRenderer.new())
  local camera, runtime = fixedCamera(), emptyRuntime()
  local white = 31 + 31 * 32 + 31 * 1024
  runtime.lighting = {
    records = {
      {
        startHalfSeconds = 0,
        lights = {
          { enabled = true, colorRgb555 = white, vectorFx12 = { 0, 0, -4096 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
        },
        diffuseRgb555 = white,
        ambientRgb555 = 0,
        specularRgb555 = 0,
        emissionRgb555 = 0,
      },
    },
  }
  -- A lit vertex (color source 3) with a +Z normal, so the head-on light
  -- contributes full diffuse. With the identity camera the triangle covers
  -- the lower-right half of the viewport (the shader flips clip Y).
  local mesh = scope:own(syntheticMesh({
    { 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 0, 1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
  }))
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })
  local function sample(mask)
    render(renderer, runtime, camera, {
      {
        {
          mesh = mesh,
          material = { alphaClass = "opaque", texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
          transform = IDENTITY,
          modelNormal = IDENTITY_NORMAL,
          alphaClass = "opaque",
          cullMode = "back",
          polygonAlpha = 1.0,
          polygonMode = "modulation",
          polygonId = 0,
          lightMask = mask,
          alphaCutoff = 0.5 / 255,
          center = { 0.5, 0.5, 0 },
        },
      },
    }, nil, viewport)
    local img = renderer.sceneColor:newImageData()
    -- NDC (0.3, -0.6) is well inside the triangle; 95 is the Y-mirror of 384.
    local lit = { img:getPixel(416, 384) }
    local mirrored = { img:getPixel(416, 95) }
    return lit, mirrored
  end

  local lit, litMirrored = sample(1)
  local unlit, unlitMirrored = sample(0)

  local function brightest(a, b)
    return math.max(a[1], a[2], a[3], b[1], b[2], b[3])
  end
  local threshold = brightest(lit, litMirrored) / 2
  Assert.isTrue(threshold > 0, "the lit mask frame must have a sample to derive a threshold from")
  Assert.isTrue(
    lit[1] >= threshold and lit[2] >= threshold and lit[3] >= threshold
      or litMirrored[1] >= threshold and litMirrored[2] >= threshold and litMirrored[3] >= threshold,
    "the lit mask renders bright at the interior sample"
  )
  Assert.isTrue(unlit[1] < threshold and unlit[2] < threshold and unlit[3] < threshold, "mask 0 renders dark")
  Assert.isTrue(
    unlitMirrored[1] < threshold and unlitMirrored[2] < threshold and unlitMirrored[3] < threshold,
    "mask 0 renders dark at the mirrored sample"
  )
end

-- A static item (a material record without matEmission) must pass the
-- profile's emission through unchanged: the shader multiplies the emission
-- register by the identity u_matEmission default, so an emission-only scene
-- still renders. Regression: the emission multiplier defaulted to black,
-- blacking out every static item -- building sides and sprites were far too
-- dark vs the DS, whose field profile emission is a large part of their
-- brightness.
function T.emission_passes_through_for_static_materials(scope)
  local renderer = scope:own(GxRenderer.new())
  local camera, runtime = fixedCamera(), emptyRuntime()
  runtime.lighting = {
    records = {
      {
        startHalfSeconds = 0,
        lights = {
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
        },
        diffuseRgb555 = 0,
        ambientRgb555 = 0,
        specularRgb555 = 0,
        emissionRgb555 = 25 + 25 * 32 + 25 * 1024,
      },
    },
  }
  -- A NORMAL-lit vertex (color source 3) with a +Z normal; every light is
  -- disabled, so only the emission register can produce color.
  local mesh = scope:own(syntheticMesh({
    { 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 0, 1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
  }))
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })
  render(renderer, runtime, camera, {
    {
      {
        mesh = mesh,
        material = { alphaClass = "opaque", texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
        transform = IDENTITY,
        modelNormal = IDENTITY_NORMAL,
        alphaClass = "opaque",
        cullMode = "back",
        polygonAlpha = 1.0,
        polygonMode = "modulation",
        polygonId = 0,
        lightMask = 0,
        alphaCutoff = 0.5 / 255,
        center = { 0.5, 0.5, 0 },
      },
    },
  }, nil, viewport)
  local img = renderer.sceneColor:newImageData()
  -- Emission 25/31 renders at ~0.8 of full scale; the canvas Y-mirror is
  -- driver-dependent, so both the canonical and mirrored interior samples
  -- are read and the scale is derived from the readback itself.
  local function maxChannel(x, y)
    local r, g, b = img:getPixel(x, y)
    return math.max(r, g, b)
  end
  local a, b = maxChannel(416, 384), maxChannel(416, 95)
  local peak = math.max(a, b)
  local scale = peak > 1 and 255 or 1
  Assert.isTrue(peak >= 0.6 * scale, "the emission register renders bright for a static material")
end

-- A dynamic material's stored colors must never dim the field profile: the
-- HGSS field engine overrides every material's stored registers with the
-- profile values (the field-model policy clears all four color ownership
-- bits), so a material carrying a colors block -- but no playing NSBMA
-- color clip -- still renders with the profile's colors. Regression: the
-- stored colors multiplied the profile, so a stored diffuse of ~100/255
-- dimmed a lit surface to under half brightness.
function T.stored_material_colors_never_dim_the_profile(scope)
  local renderer = scope:own(GxRenderer.new())
  local camera, runtime = fixedCamera(), emptyRuntime()
  local white = 31 + 31 * 32 + 31 * 1024
  runtime.lighting = {
    records = {
      {
        startHalfSeconds = 0,
        lights = {
          { enabled = true, colorRgb555 = white, vectorFx12 = { 0, 0, -4096 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
        },
        diffuseRgb555 = white,
        ambientRgb555 = white,
        specularRgb555 = 0,
        emissionRgb555 = 0,
      },
    },
  }
  local mesh = scope:own(syntheticMesh({
    { 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 0, 1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
  }))
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })
  render(renderer, runtime, camera, {
    {
      {
        mesh = mesh,
        -- A dynamic material with the four DS registers stored, but no NSBMA
        -- clip driving them: the profile must win every channel.
        material = {
          alphaClass = "opaque",
          matDiffuse = { 100 / 255, 100 / 255, 100 / 255 },
          matAmbient = { 0, 0, 0 },
          matSpecular = { 0, 0, 0 },
          matEmission = { 0, 0, 0 },
          texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
        },
        transform = IDENTITY,
        modelNormal = IDENTITY_NORMAL,
        alphaClass = "opaque",
        cullMode = "back",
        polygonAlpha = 1.0,
        polygonMode = "modulation",
        polygonId = 0,
        lightMask = 15,
        alphaCutoff = 0.5 / 255,
        center = { 0.5, 0.5, 0 },
      },
    },
  }, nil, viewport)
  local img = renderer.sceneColor:newImageData()
  -- The profile's white ambient + head-on white diffuse saturate the vertex:
  -- full brightness, not the stored colors' ~0.4.
  local function maxChannel(x, y)
    local r, g, b = img:getPixel(x, y)
    return math.max(r, g, b)
  end
  local a, b = maxChannel(416, 384), maxChannel(416, 95)
  local peak = math.max(a, b)
  local scale = peak > 1 and 255 or 1
  Assert.isTrue(peak >= 0.6 * scale, "the profile colors render, not the stored material colors")
end

-- A playing NSBMA color clip replaces the field profile at the register
-- level: the animated diffuse must render at its own value, not at the
-- profile value multiplied by it. Regression: the animated colors
-- multiplied the profile, so a full-white animated diffuse over a dim
-- profile diffuse rendered at the profile's brightness.
function T.color_animated_materials_replace_the_profile(scope)
  local renderer = scope:own(GxRenderer.new())
  local camera, runtime = fixedCamera(), emptyRuntime()
  local white = 31 + 31 * 32 + 31 * 1024
  local dim = 10 + 10 * 32 + 10 * 1024
  runtime.lighting = {
    records = {
      {
        startHalfSeconds = 0,
        lights = {
          { enabled = true, colorRgb555 = white, vectorFx12 = { 0, 0, -4096 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
        },
        diffuseRgb555 = dim,
        ambientRgb555 = 0,
        specularRgb555 = 0,
        emissionRgb555 = 0,
      },
    },
  }
  local mesh = scope:own(syntheticMesh({
    { 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 0, 1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
  }))
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })
  render(renderer, runtime, camera, {
    {
      {
        mesh = mesh,
        -- A material whose colors an NSBMA clip drives: the clip's sampled
        -- colors are the registers, so a full-white animated diffuse renders
        -- full, never the dim profile diffuse.
        material = {
          alphaClass = "opaque",
          matDiffuse = { 1, 1, 1 },
          colorsAnimated = true,
          texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
        },
        transform = IDENTITY,
        modelNormal = IDENTITY_NORMAL,
        alphaClass = "opaque",
        cullMode = "back",
        polygonAlpha = 1.0,
        polygonMode = "modulation",
        polygonId = 0,
        lightMask = 15,
        alphaCutoff = 0.5 / 255,
        center = { 0.5, 0.5, 0 },
      },
    },
  }, nil, viewport)
  local img = renderer.sceneColor:newImageData()
  local function maxChannel(x, y)
    local r, g, b = img:getPixel(x, y)
    return math.max(r, g, b)
  end
  local a, b = maxChannel(416, 384), maxChannel(416, 95)
  local peak = math.max(a, b)
  local scale = peak > 1 and 255 or 1
  Assert.isTrue(peak >= 0.6 * scale, "the animated diffuse renders at its own value, not the profile's")
end

-- A scene with no lighting profile must not inherit the previous lit
-- scene's light/material uniforms: the profile-less draw explicitly sends
-- disabled lights and zero material colors, so a
-- NORMAL-lit vertex and a field-diffuse vertex both render dark after a
-- bright lit frame instead of the lit frame's values. Canvas readbacks come
-- back Y-inverted on some GL drivers, so each triangle is sampled at both
-- its canonical position and its mirrored position; exactly one of the two
-- is interior in any environment. The readback scale is likewise
-- driver-dependent (0..255 or 0..1), so the brightness threshold is derived
-- from an actual sample.
function T.lit_then_unlit_scene_does_not_inherit_lighting(scope)
  local renderer = scope:own(GxRenderer.new())
  local camera = fixedCamera()
  local white = 31 + 31 * 32 + 31 * 1024
  local litRuntime = emptyRuntime()
  litRuntime.lighting = {
    records = {
      {
        startHalfSeconds = 0,
        lights = {
          { enabled = true, colorRgb555 = white, vectorFx12 = { 0, 0, -4096 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
        },
        diffuseRgb555 = white,
        ambientRgb555 = white,
        specularRgb555 = 0,
        emissionRgb555 = white,
      },
    },
  }
  local unlitRuntime = emptyRuntime()
  -- Triangle 1 (right half) uses a NORMAL color source, so it is shaded by
  -- the light and material uniforms; triangle 2 (left half) uses the
  -- field-diffuse source and reads the effective material register
  -- (u_matDiffuse).
  local mesh = scope:own(syntheticMesh({
    { 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 0, 1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2 },
    { -1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2 },
    { 0, -1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2 },
  }))
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })
  local item = {
    mesh = mesh,
    material = { alphaClass = "opaque", texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
    transform = IDENTITY,
    modelNormal = IDENTITY_NORMAL,
    alphaClass = "opaque",
    cullMode = "back",
    polygonAlpha = 1.0,
    polygonMode = "modulation",
    polygonId = 0,
    lightMask = 15,
    alphaCutoff = 0.5 / 255,
    center = { 0.5, 0.5, 0 },
  }
  -- Interior points of the two triangles plus their Y-mirrored counterparts
  -- (the 640x480 canvas mirrors to a 480 pixel row 95/383).
  local normalSamples = { { 416, 384 }, { 416, 95 } }
  local diffuseSamples = { { 224, 96 }, { 224, 383 } }

  local function isBright(img, x, y, threshold)
    local r, g, b = img:getPixel(x, y)
    return r >= threshold and g >= threshold and b >= threshold
  end

  local function anyBright(img, samples, threshold)
    for _, p in ipairs(samples) do
      if isBright(img, p[1], p[2], threshold) then
        return true
      end
    end
    return false
  end

  -- The lit frame is bright at both triangles: the NORMAL triangle under a
  -- head-on light, the field-diffuse triangle from its effective material
  -- register (COLOR_DIFFUSE reads u_matDiffuse, which the profile supplies
  -- for a static item -- the field engine owns every channel).
  render(renderer, litRuntime, camera, { { item } }, nil, viewport)
  local litImg = renderer.sceneColor:newImageData()
  local sr, sg, sb = litImg:getPixel(0, 0)
  local threshold = (sr > 1 or sg > 1 or sb > 1) and 127 or 0.5
  Assert.isTrue(anyBright(litImg, normalSamples, threshold), "lit frame shades the NORMAL triangle")
  Assert.isTrue(anyBright(litImg, diffuseSamples, threshold), "lit frame shades the field-diffuse triangle")

  -- The profile-less frame must reset every lighting uniform: the NORMAL
  -- triangle may not stay bright from the lit frame's light values, and the
  -- field-diffuse triangle reads the effective material register (u_mat*),
  -- which the unlit frame resets to zero -- nothing supplies the registers
  -- without a profile, so the triangle renders dark instead of inheriting
  -- the previous frame's material colors.
  render(renderer, unlitRuntime, camera, { { item } }, nil, viewport)
  local unlitImg = renderer.sceneColor:newImageData()
  Assert.isFalse(anyBright(unlitImg, normalSamples, threshold), "unlit frame inherits the previous light state")
  Assert.isFalse(anyBright(unlitImg, diffuseSamples, threshold), "unlit frame inherits the previous material state")
end

function T.a_straddling_item_uses_its_current_transform_for_the_whole_mesh(scope)
  -- An arbitrary injected clear color distinguishable from the drawn
  -- triangles: this test asserts against it directly, not against
  -- GxRenderer's fallback default (the renderer carries no opinion about
  -- what color a game wants; only that it clears to whatever it is given).
  local clearColor = { 0.08, 0.09, 0.12, 1 }
  local renderer = scope:own(GxRenderer.new({ clearColor = clearColor }))

  -- Leading triangle (green) at y in [0.2, 0.5]; trailing triangle (red) at
  -- y in [-0.5, -0.2]. The current renderer presents the resident mesh as a
  -- whole under the item's current transform, so the straddle transform does
  -- not move the leading triangle.
  local mesh = scope:own(syntheticMesh({
    { -0.8, 0.2, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0 },
    { 0, 0.5, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0 },
    { 0.8, 0.2, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0 },
    { -0.8, -0.5, 0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0 },
    { 0, -0.2, 0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0 },
    { 0.8, -0.5, 0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0 },
  }))
  mesh:setVertexMap({ 4, 5, 6, 1, 2, 3 })
  local item = {
    mesh = mesh,
    material = { alphaClass = "opaque", texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
    transform = IDENTITY,
    modelNormal = IDENTITY_NORMAL,
    alphaClass = "opaque",
    cullMode = "none",
    polygonAlpha = 1.0,
    polygonMode = "modulation",
    polygonId = 0,
    lightMask = 0,
    alphaCutoff = 0.5 / 255,
    center = { 0, 0, 0 },
    straddle = {
      leading = 3,
      transform = Matrix4.translate(0, -1, 0),
    },
  }

  render(renderer, emptyRuntime(), fixedCamera(), { { item } }, nil, FieldViewport.new(640, 480, { mode = "strict" }))
  local data = scope:own(renderer.sceneColor:newImageData())
  local w, h = renderer.colorW, renderer.colorH
  -- Identity view/projection and the shader's clip-y negation map a world
  -- point (x, y) to canvas pixel ((1+x)/2 * w, (1-y)/2 * h) with row 0 at
  -- the top.
  local function pixelAt(worldX, worldY)
    local cx = math.floor((worldX + 1) / 2 * w + 0.5)
    local cy = math.floor((1 - worldY) / 2 * h + 0.5)
    return data:getPixel(cx, cy)
  end

  -- The leading triangle remains under the item's current transform (world y
  -- in [0.2, 0.5]): centroid green.
  local gr, gg, gb = pixelAt(0, 0.35)
  Assert.near(gr, 0, 0.05, "current leading red")
  Assert.near(gg, 1, 0.05, "current leading green")
  Assert.near(gb, 0, 0.05, "current leading blue")
  -- The trailing triangle (world y in [-0.5, -0.2]): centroid red.
  local rr, rg, rb = pixelAt(0, -0.35)
  Assert.near(rr, 1, 0.05, "trailing red")
  Assert.near(rg, 0, 0.05, "trailing green")
  Assert.near(rb, 0, 0.05, "trailing blue")
  -- The discarded exact split's translated position (world y in [-0.8,
  -- -0.5]) remains background because the whole mesh uses the current
  -- transform.
  local br, bg, bb = pixelAt(0, -0.65)
  Assert.near(br, clearColor[1], 0.05, "translated position red")
  Assert.near(bg, clearColor[2], 0.05, "translated position green")
  Assert.near(bb, clearColor[3], 0.05, "translated position blue")
end

-- A lighting profile with one white light and a specular-only material
-- (diffuse/ambient/emission zero), so any brightness in the frame is pure
-- specular. The two cos(2a) scenarios below share it.
local function specularOnlyRuntime(vectorFx12)
  local white = 31 + 31 * 32 + 31 * 1024
  local runtime = emptyRuntime()
  runtime.lighting = {
    records = {
      {
        startHalfSeconds = 0,
        lights = {
          { enabled = true, colorRgb555 = white, vectorFx12 = vectorFx12 },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
        },
        diffuseRgb555 = 0,
        ambientRgb555 = 0,
        specularRgb555 = 14 + 14 * 32 + 16 * 1024,
        emissionRgb555 = 0,
      },
    },
  }
  return runtime
end

-- A NORMAL-lit triangle (color source 3) with the given normal, covering the
-- lower-right half of the viewport under the identity camera (the shader
-- flips clip Y, exactly like polygon_light_mask_changes_the_rendered_result).
local function litMesh(scope, normal)
  local function vertex(x, y)
    return { x, y, 0, 0, 1, normal[1], normal[2], normal[3], 1, 1, 1, 1, 3 }
  end
  return scope:own(syntheticMesh({ vertex(0, 0), vertex(1, 0), vertex(0, 1) }))
end

-- Brightest channel over the two candidate interior samples of the scene
-- color canvas (readbacks come back Y-inverted on some drivers, so exactly
-- one of the two is interior; the scale is likewise driver-dependent, so
-- comparisons stay relative to a sample of the same frame).
local function brightestSample(renderer)
  local img = renderer.sceneColor:newImageData()
  local function maxOf(p)
    return math.max(p[1], p[2], p[3])
  end
  return math.max(maxOf({ img:getPixel(416, 384) }), maxOf({ img:getPixel(416, 95) }))
end

-- Draw one specular-only frame and return its brightest interior sample.
local function specularFrame(renderer, scope, normal, vectorFx12)
  render(renderer, specularOnlyRuntime(vectorFx12), fixedCamera(), {
    {
      {
        mesh = litMesh(scope, normal),
        material = { alphaClass = "opaque", texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
        transform = IDENTITY,
        modelNormal = IDENTITY_NORMAL,
        alphaClass = "opaque",
        cullMode = "back",
        polygonAlpha = 1.0,
        polygonMode = "modulation",
        polygonId = 0,
        lightMask = 1,
        alphaCutoff = 0.5 / 255,
        center = { 0.5, 0.5, 0 },
      },
    },
  }, nil, FieldViewport.new(640, 480, { mode = "strict" }))
  return brightestSample(renderer)
end

-- GPU3D::CalculateLighting's shinelevel sequence narrows off-axis: reusing
-- the diffuse dot plus the normal's Z, truncate-squaring it, and scaling by
-- the light's SpecRecip falls off sharply as the normal tilts away from the
-- light. (Nearly-but-not-exactly axis-aligned normal, {1,0,20}: an exactly
-- axis-aligned {0,0,1} normal against this light hits the literal 11-bit
-- sign-extension boundary of dot+normal.z == 1024 and wraps to a spurious
-- zero -- a genuine hardware edge case, not a bug in this shader -- so the
-- head-on reference frame here stays just off that exact boundary.) The
-- off-axis frame must come out well below half the head-on one.
function T.specular_cos2a_narrows_the_highlight_off_axis(scope)
  local renderer = scope:own(GxRenderer.new())
  local headOn = specularFrame(renderer, scope, { 1, 0, 20 }, { 0, 0, -4096 })
  local offAxis = specularFrame(renderer, scope, { 0.661438, 0, 0.75 }, { 0, 0, -4096 })

  Assert.isTrue(headOn > 0, "the head-on specular frame must have a sample to derive a threshold from")
  Assert.isTrue(offAxis < headOn / 2, "the off-axis specular must be far dimmer than head-on")
end

-- GPU3D::CalculateLighting's front-light gate ("if (dot > 0)"): a light whose
-- direction faces away from the surface contributes no specular (or diffuse)
-- term at all, regardless of where the reused dot/normal.z sum would
-- otherwise land; the gated shader must render (near-)black.
function T.behind_light_specular_stays_dark(scope)
  local renderer = scope:own(GxRenderer.new())
  local headOn = specularFrame(renderer, scope, { 1, 0, 20 }, { 0, 0, -4096 })
  local behind = specularFrame(renderer, scope, { 0.5, 0, 0.8660254037844386 }, { -3313, 0, 2407 })

  Assert.isTrue(headOn > 0, "the head-on specular frame must have a sample to derive a threshold from")
  Assert.isTrue(behind < headOn / 2, "a behind-the-surface light contributes no specular under the melonDS gate")
end

-- Required real-graphics fixture: a rendered triangle's lit vertex color
-- compared to a fixed expected RGB6 value hand-derived from melonDS's
-- CalculateLighting (GPU3D.cpp, see ds_lighting_test.lua's header and
-- ambient_only_midrange_light_color for the same derivation form) -- not
-- computed by calling DsLighting or any other production code. MatAmbient=27,
-- LightColor=20, MatDiffuse=MatSpecular=MatEmission=0 (so no light
-- direction/normal-transform concerns enter this fixture at all, only the
-- ambient accumulator):
--   vtxbuff = (27<<9)*20 = 13824*20 = 276480; vtxbuff>>14 = floor(276480/16384) = 16
-- The untextured MODULATE combiner is the identity on a lone vertex color
-- (texture6 = expand5to6(31) = 63 either way, since c5=31 is unaffected by
-- the separate 5->6 expansion fix), and 16 is deliberately in the [16,31]
-- band where the old and corrected expand5to6 rules already agree (2*16+1 =
-- 33 either way), so this fixture is sensitive only to vertex-lighting
-- arithmetic, never to the fragment combiner.
-- Expected normalized scene color: 33/63.
function T.ambient_lit_triangle_matches_the_hand_derived_melonds_rgb6(scope)
  local renderer = scope:own(GxRenderer.new())
  local camera, runtime = fixedCamera(), emptyRuntime()
  runtime.lighting = {
    records = {
      {
        startHalfSeconds = 0,
        lights = {
          { enabled = true, colorRgb555 = 20 + 20 * 32 + 20 * 1024, vectorFx12 = { 0, 0, -4096 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
        },
        diffuseRgb555 = 0,
        ambientRgb555 = 27 + 27 * 32 + 27 * 1024,
        specularRgb555 = 0,
        emissionRgb555 = 0,
      },
    },
  }
  local mesh = scope:own(syntheticMesh({
    { 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 0, 1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
  }))
  render(renderer, runtime, camera, {
    {
      {
        mesh = mesh,
        material = { alphaClass = "opaque", texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
        transform = IDENTITY,
        modelNormal = IDENTITY_NORMAL,
        alphaClass = "opaque",
        cullMode = "back",
        polygonAlpha = 1.0,
        polygonMode = "modulation",
        polygonId = 0,
        lightMask = 1,
        alphaCutoff = 0.5 / 255,
        center = { 0.5, 0.5, 0 },
      },
    },
  }, nil, FieldViewport.new(640, 480, { mode = "strict" }))

  local img = renderer.sceneColor:newImageData()
  local a, b = { img:getPixel(416, 384) }, { img:getPixel(416, 95) }
  local function sum(p)
    return p[1] + p[2] + p[3]
  end
  local p = sum(a) >= sum(b) and a or b
  local scale = p[1] > 1 and 255 or 1
  local expected = 33 / 63 * scale
  local tolerance = scale > 1 and 1 or (1 / 63)
  Assert.near(p[1], expected, tolerance, "hand-derived melonDS ambient RGB6: expand5to6(16) = 33, red")
  Assert.near(p[2], expected, tolerance, "hand-derived melonDS ambient RGB6: expand5to6(16) = 33, green")
  Assert.near(p[3], expected, tolerance, "hand-derived melonDS ambient RGB6: expand5to6(16) = 33, blue")
end

-- ---- terrain-animation offscreen fixtures ----

-- The New Bark flower replacement schedule: R0 for 18 ticks, R1 for 18, R0
-- for 18, R2 for 18, loop (the generated-contract record shape).
local function flowerSteps(flowerPaths)
  return {
    { texture = flowerPaths[1], durationTicks = 18 },
    { texture = flowerPaths[2], durationTicks = 18 },
    { texture = flowerPaths[1], durationTicks = 18 },
    { texture = flowerPaths[3], durationTicks = 18 },
  }
end

-- A compiled texsrt clip in the NsbtaClipCompiler payload shape: one target
-- whose transS curve moves 0x0800 fx32 units (half a texture width -- 8
-- texels on the 16-wide texture) between frame 0 and frame 1.
local function terrainSrtClip()
  return {
    id = "fixture:area00_ani",
    name = "area00_ani",
    category = "material",
    kind = "texsrt",
    frameCount = 2,
    tracks = { { target = "water", targetIndex = 0 } },
    semanticNames = {},
    compiled = {
      targets = {
        {
          index = 0,
          name = "water",
          channels = {
            scaleS = { source = "constant", value = 0x1000 },
            scaleT = { source = "constant", value = 0x1000 },
            rot = { source = "constant", value = 0x10000000 },
            transS = { source = "curve", rate = 1, limit = 2, storage = "fx32", keys = { 0x0, 0x0800 } },
            transT = { source = "constant", value = 0 },
          },
        },
      },
    },
  }
end

-- One solid-color PNG frame for the swap schedule.
local function solidPng(width, height, r, g, b)
  local data = love.image.newImageData(width, height)
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      data:setPixel(x, y, r, g, b, 255)
    end
  end
  return data:encode("png")
end

-- A two-tone PNG: left half red, right half blue, so a half-width texture
-- translation observably moves the sampled texel.
local function twoTonePng(width, height)
  local data = love.image.newImageData(width, height)
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      if x < width / 2 then
        data:setPixel(x, y, 255, 0, 0, 255)
      else
        data:setPixel(x, y, 0, 0, 255, 255)
      end
    end
  end
  return data:encode("png")
end

-- A full-screen-height quad in world space with UVs spanning [0,1].
local function uvQuad(x0, y0, x1, y1)
  local function v(x, y, u, uv)
    return {
      x = x,
      y = y,
      z = 0,
      u = u,
      v = uv,
      nx = 0,
      ny = 0,
      nz = 1,
      r = 255,
      g = 255,
      b = 255,
      a = 255,
      colorSource = 0,
    }
  end
  return {
    vertices = { v(x0, y0, 0, 0), v(x1, y0, 1, 0), v(x1, y1, 1, 1), v(x0, y1, 0, 1) },
    indices = { 0, 1, 2, 0, 2, 3 },
  }
end

-- A 32x32 all-plain collision grid (the scene cell).
local function collisionGridBytes()
  local cells = {}
  for index = 1, 32 * 32 do
    cells[index] = { behavior = 0, terrainResponseId = 0, blocked = false }
  end
  return CollisionGridAsset.encode({ width = 32, height = 32, cells = cells })
end

-- The in-memory cache facade over a FakeCache backend: loadLua reads and
-- evals in an empty environment, like CacheFs.loadLua.
local function luaCache(backend)
  local function loadLua(path)
    local data = assert(backend:read(path), "missing cache file " .. path)
    local chunk = assert(loadstring(data, path))
    setfenv(chunk, {})
    local ok, result = pcall(chunk)
    assert(ok, result)
    return result
  end
  local result = {
    read = function(_, path)
      return backend:read(path)
    end,
    loadLua = function(_, path)
      return loadLua(path)
    end,
  }
  ---@cast result CacheFs
  return result
end

-- A terrain scene with two materials: a texture-swap flower quad covering
-- the left half of the screen and a water quad covering the right half,
-- animated by the given SRT clip. Returns the cache facade.
local function terrainAnimationScene(flowerFrames, waterPng, srtClip)
  local mapId = 61
  local backend = FakeCache.new()
  local dir = MapAssetCache.mapDir(mapId)
  local flowerPaths = {}
  for i, png in ipairs(flowerFrames) do
    local path = MapAssetCache.texturePath("flower-f" .. i)
    backend:write(path, png)
    flowerPaths[i] = path
  end
  local waterPath = MapAssetCache.texturePath("water")
  backend:write(waterPath, waterPng)

  local flowerQuad = MapAssetCache.geometryPath("flower-quad")
  local waterQuad = MapAssetCache.geometryPath("water-quad")
  backend:write(flowerQuad, MeshWriter.encode(uvQuad(-1, -1, 0, 1)))
  backend:write(waterQuad, MeshWriter.encode(uvQuad(0, -1, 1, 1)))

  local scene = {
    schema = MapAssetCache.SCENE_SCHEMA,
    versionId = "heartgold",
    mapId = mapId,
    mapSymbol = "MAP_NEW_BARK",
    matrix = {
      memberId = 0,
      name = "map",
      width = 1,
      height = 1,
      x = 0,
      z = 0,
      index = 0,
      altitude = 0,
      worldOriginX = 0,
      worldOriginZ = 0,
    },
    area = {
      memberId = 2,
      type = "outdoor",
      mapTexturePackId = 0,
      buildingTexturePackId = 0,
      dynamicTextureType = 0,
      lightType = 0,
    },
    collision = { width = 32, height = 32, file = dir .. "/collision.g4collision" },
    mapBatches = {
      {
        geometry = flowerQuad,
        material = 0,
        cullMode = "none",
        polygonMode = "modulation",
        polygonId = 0,
        translucentDepthWrite = false,
        depthEqual = false,
        polygonAlpha = 31,
        lightMask = 0,
        alphaClass = "opaque",
      },
      {
        geometry = waterQuad,
        material = 1,
        cullMode = "none",
        polygonMode = "modulation",
        polygonId = 0,
        translucentDepthWrite = false,
        depthEqual = false,
        polygonAlpha = 31,
        lightMask = 0,
        alphaClass = "opaque",
      },
    },
    materials = {
      {
        id = 0,
        name = "flower01",
        texture = flowerPaths[1],
        wrap = { x = "repeat", y = "repeat" },
        texWidth = 16,
        texHeight = 16,
        texMtxMode = 0,
        textureSwap = {
          name = "flower01",
          steps = flowerSteps(flowerPaths),
        },
      },
      {
        id = 1,
        name = "water",
        texture = waterPath,
        wrap = { x = "repeat", y = "repeat" },
        texWidth = 16,
        texHeight = 16,
        texMtxMode = 0,
      },
    },
    buildingInstances = {},
    neighbors = {},
    lighting = nil,
    terrainAnimations = { textureSrt = srtClip },
    edgeColors = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 },
    fog = zeroFogFixture(),
  }
  backend:write(dir .. "/scene.lua", LuaWriter.encode(scene))
  backend:write(dir .. "/collision.g4collision", collisionGridBytes())
  return luaCache(backend)
end

-- One offscreen scenario for the terrain-animation proof: a single
-- renderer and a single loader boot draw (1) the terrain quad on its base
-- image, (2) the same quad after the clock crossed a texture-swap boundary,
-- asserting the selected pixel changed to the second step's image, and (3)
-- the SRT-targeted quad after a non-identity sample, asserting the sampling
-- moved to the expected texel. Production MapSceneLoader runtime material
-- tables (image + texMatrix, mutated by TerrainMaterialAnimator) drive the
-- draw; nothing here is a test-only shader.
function T.terrain_animation_offscreen_swap_and_srt(scope)
  local flowerFrames = {
    solidPng(16, 16, 255, 0, 0),
    solidPng(16, 16, 0, 0, 255),
    solidPng(16, 16, 0, 255, 0),
  }
  local cache = terrainAnimationScene(flowerFrames, twoTonePng(16, 16), terrainSrtClip())
  local scene = assert(cache:loadLua(MapAssetCache.mapDir(61) .. "/scene.lua"))
  local runtime = scope:own(MapSceneLoader.load(cache, scene))
  local renderer = scope:own(GxRenderer.new())
  local camera = fixedCamera()
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })

  -- World position -> canvas pixel under the identity camera (the shader
  -- flips clip Y). Both quads span the full canvas height, so the mirrored
  -- row (used on drivers whose readbacks come back Y-inverted) is interior
  -- too.
  local function pixelAt(w, h, x, y)
    return math.floor((x + 1) / 2 * w + 0.5), math.floor((1 - y) / 2 * h + 0.5)
  end
  local flowerX, flowerY = pixelAt(640, 480, -0.25, 0.25)
  local waterX, waterY = pixelAt(640, 480, 0.625, 0.125)
  local flowerMirrorY = 480 - 1 - flowerY
  local waterMirrorY = 480 - 1 - waterY

  local function draw()
    render(renderer, runtime, camera, { runtime.mapDraws }, nil, viewport)
    return renderer.sceneColor:newImageData()
  end

  -- The readback scale is driver-dependent (0..255 or 0..1), so channels
  -- are compared against a scale derived from the sampled pixel itself.
  local function isColor(pixel, r, g, b)
    local scale = pixel[1] > 1 and 255 or 1
    local function channel(value, want)
      return want == 0 and value <= 0.4 * scale or value >= 0.6 * scale
    end
    return channel(pixel[1], r) and channel(pixel[2], g) and channel(pixel[3], b)
  end

  local function assertPixel(img, x, y, r, g, b, label)
    local p = { img:getPixel(x, y) }
    Assert.isTrue(
      isColor(p, r, g, b),
      label .. " at (" .. x .. "," .. y .. "): got " .. p[1] .. "," .. p[2] .. "," .. p[3]
    )
  end

  -- The initial draw: the swap material binds its base image (red -- the
  -- fixture's replacement step 1 shares the path) and the SRT target
  -- samples its identity matrix (the water quad's u=0.625 samples the blue
  -- half). Loading established the base image without advancing.
  local img0 = draw()
  assertPixel(img0, flowerX, flowerY, 1, 0, 0, "flower frame 0 renders red")
  assertPixel(img0, flowerX, flowerMirrorY, 1, 0, 0, "flower frame 0 renders red (mirror row)")
  assertPixel(img0, waterX, waterY, 0, 0, 1, "water frame 0 samples the blue half")
  assertPixel(img0, waterX, waterMirrorY, 0, 0, 1, "water frame 0 samples the blue half (mirror row)")

  -- One fixed tick applies the first non-identity SRT sample (half a
  -- texture width -- 8 texels -- moves the sample from blue to red). The
  -- flower clock has not reached its first switch (tick 19), so the flower
  -- stays on the base image.
  runtime:updateAnimated()
  local img1 = draw()
  assertPixel(img1, waterX, waterY, 1, 0, 0, "water frame 1 samples the red half after the SRT move")
  assertPixel(img1, waterX, waterMirrorY, 1, 0, 0, "water frame 1 samples the red half (mirror row)")
  assertPixel(img1, flowerX, flowerY, 1, 0, 0, "flower stays on the base image before the swap boundary")

  -- Crossing the texture-swap boundary (18 more ticks, first switch at tick
  -- 19): the runtime material image switches to the second step's image and
  -- the quad renders blue. The 2-frame SRT clip is at frame 19 mod 2 = 1,
  -- so the water sample stays shifted.
  for _ = 1, 18 do
    runtime:updateAnimated()
  end
  local img2 = draw()
  assertPixel(img2, flowerX, flowerY, 0, 0, 1, "flower switched to the second step image at the swap boundary")
  assertPixel(img2, flowerX, flowerMirrorY, 0, 0, 1, "flower switched to the second step image (mirror row)")
  assertPixel(img2, waterX, waterY, 1, 0, 0, "water keeps the shifted sample")
end

-- The renderState target contract: an opaque (or cutout/wireframe -- they
-- share this exact fragment shader code path) fragment must write its own
-- POLYGON_ATTR FOG_ENABLE bit (item.fogEnabled, already threaded to the
-- shader as u_polygonFogEnabled for fog blending) into renderState's blue
-- channel, not the retired translucent-identity flag. An opaque item is never
-- translucent, so today's blue channel (u_translucentAttribute) is always 0
-- regardless of fogEnabled -- this is the exact numeric divergence that proves
-- the channel's meaning changed, not merely its uniform source.
function T.opaque_draw_writes_its_fog_gate_into_the_final_state_blue_channel(scope)
  local renderer = scope:own(GxRenderer.new())
  local image = solidAlphaImage(scope, 255, 255, 255, 255)
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })

  local function stateInterior(item)
    render(renderer, emptyRuntime(), fixedCamera(), { { item } }, nil, viewport)
    local img = renderer.renderState:newImageData()
    local ax, ay = statePixel(renderer, 416, 384)
    local bx, by = statePixel(renderer, 416, 95)
    local a, b = { img:getPixel(ax, ay) }, { img:getPixel(bx, by) }
    return a[1] < 0.5 and a or b
  end

  local fogGated = decalItem(decalTriangle(scope), image)
  fogGated.fogEnabled = true
  local sampleGated = stateInterior(fogGated)
  Assert.near(sampleGated[3], 1.0, 1 / 255, "a fog-enabled opaque fragment's fog gate reaches the blue channel")

  local fogUngated = decalItem(decalTriangle(scope), image)
  fogUngated.fogEnabled = false
  local sampleUngated = stateInterior(fogUngated)
  Assert.near(sampleUngated[3], 0.0, 1 / 255, "a fog-disabled opaque fragment's fog gate stays 0")
end

-- A single opaque triangle writes its visible combiner result and its
-- polygon state atomically through the shared MRT submission.
function T.opaque_world_geometry_writes_color_and_state_in_one_submission(scope)
  local renderer = scope:own(GxRenderer.new())
  local image = solidAlphaImage(scope, 255, 0, 0, 255)
  local item = decalItem(decalTriangle(scope), image)
  item.polygonId = 17
  item.fogEnabled = true
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })

  render(renderer, emptyRuntime(), fixedCamera(), { { item } }, nil, viewport)

  Assert.equal(renderer.stats.drawCalls, 1, "one opaque triangle produces one mesh draw")
  local color = decalInteriorSample(renderer)
  local colorScale = color[1] > 1 and 255 or 1
  Assert.isTrue(color[1] > 0.8 * colorScale, "the shared pass writes the current red combiner result")
  Assert.isTrue(color[2] < 0.2 * colorScale, "the shared pass preserves the combiner green channel")

  local state = renderer.renderState:newImageData()
  local ax, ay = statePixel(renderer, 416, 384)
  local bx, by = statePixel(renderer, 416, 95)
  local a, b = { state:getPixel(ax, ay) }, { state:getPixel(bx, by) }
  local sample = a[1] < 0.5 and a or b
  Assert.near(sample[1], 17 / 63, 1 / 255, "the shared pass writes the polygon id")
  Assert.near(sample[3], 1, 1 / 255, "the shared pass writes the polygon fog gate")
end

-- Shared 3x1 fixture for the edge-predicate anchors below: pixel 1 is
-- always the center under test, pixels 0/2 its left/right neighbors (the
-- edge shader always samples exactly one state texel in each direction).
-- Drives edge.glsl directly (not through GxRenderer's full draw path) so the
-- neighbor/center ID and depth values are exact and independent of any
-- particular mesh/camera geometry. Ids are encoded by the real domain
-- maximum (63, GxRenderer.CLEAR_POLYGON_ID), the same normalization every
-- real GxRenderer draw applies -- not the retired 255-wide sentinel domain.
-- Returns the center pixel's rendered RGB. Both the scene and state
-- textures share the same dimensions here, so the state size IS the
-- per-pixel scene size -- this fixture does not exercise the dual-resolution
-- case (see the mixed-alpha/state-vs-color graphics tests for that).
--
-- Shared by every edge-predicate fixture in this section, including the
-- diagonal-neighbor fixture below, which needs a 3x3 grid (a 3x1 strip can
-- only ever exercise left/right neighbors) but otherwise drives the same
-- shader/canvas boilerplate.
local function runEdgeShaderPass(scope, width, height, fillId, fillScene, edgeColors)
  local edgeShader = scope:own(GxRenderer.new()).edgeShader

  local idData = love.image.newImageData(width, height, "rgba32f")
  fillId(idData)
  local idImage = scope:own(love.graphics.newImage(idData))
  idImage:setFilter("nearest", "nearest")

  local sceneData = love.image.newImageData(width, height)
  fillScene(sceneData)
  local sceneImage = scope:own(love.graphics.newImage(sceneData))
  sceneImage:setFilter("nearest", "nearest")

  local target = scope:own(love.graphics.newCanvas(width, height))
  love.graphics.setCanvas(target)
  love.graphics.clear(0, 0, 0, 1)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setShader(edgeShader)
  edgeShader:send("u_renderState", idImage)
  edgeShader:send("u_stateSize", { width, height })
  -- The state texture shares the scene texture's dimensions in this fixture
  -- (same-resolution contract), so a radius of 1 samples the immediately
  -- adjacent state pixels -- the exact neighbor distance these predicate
  -- fixtures assert.
  edgeShader:send("u_edgeRadiusPx", 1)
  -- Coverage is a separate concern (see the AA graphics tests below); these
  -- predicate fixtures assert the raw edge-replacement color.
  edgeShader:send("u_antialiasEnabled", false)
  edgeShader:send("u_edgeColors", unpack(edgeColors))
  love.graphics.draw(sceneImage, 0, 0)
  love.graphics.setShader()
  love.graphics.setCanvas()

  return target:newImageData()
end

-- A 3x3 grid (not 3x1): every row is identical, so the vertical neighbors
-- are always real same-id/same-depth samples rather than an out-of-bounds
-- rear-plane fallback (see edge.glsl's stateSample) -- a genuinely 1-line-
-- tall state target never occurs in production, and relying on
-- texture-clamp behavior to paper over a degenerate fixture would defeat the
-- exact rear-plane boundary check these fixtures are not meant to exercise
-- (see the dedicated rear-plane boundary test below for that).
local function runEdgePass(scope, pixels, edgeColors)
  local out = runEdgeShaderPass(scope, 3, 3, function(idData)
    -- The blue (fog-gate) and alpha (validity) channels are irrelevant to
    -- edge.glsl's predicate (it reads only R/id and G/depth), so this
    -- fixture fills them with fixed placeholder values rather than
    -- per-pixel fields.
    for i, p in ipairs(pixels) do
      for row = 0, 2 do
        idData:setPixel(i - 1, row, p.id / 63, p.depth, 0, 1)
      end
    end
  end, function(sceneData)
    -- A center scene color distinct from every u_edgeColors entry below, so
    -- "no edge" (unmodified scene) is distinguishable from "edge" (a table
    -- entry) or a garbage/out-of-range read.
    for row = 0, 2 do
      sceneData:setPixel(0, row, 0.2, 0.2, 0.2, 1)
      sceneData:setPixel(1, row, 200 / 255, 210 / 255, 220 / 255, 1)
      sceneData:setPixel(2, row, 0.2, 0.2, 0.2, 1)
    end
  end, edgeColors)
  return { out:getPixel(1, 1) }
end

-- Eight distinct, non-uniform edge colors, shared by every anchor below:
-- entry i is (i/10, i/10, i/10), so an edge render is distinguishable from
-- every other entry and from the scene color.
local function eightEdgeColors()
  local colors = {}
  for i = 0, 7 do
    colors[i + 1] = { i / 10, i / 10, i / 10 }
  end
  return colors
end

-- D.6: the domain maximum, 63 (HGSS's real clear/rear-plane id --
-- GxRenderer.CLEAR_POLYGON_ID) is a genuine, reachable DS polygon id
-- (GBATEK POLYGON_ATTR polygon id is 6 bits wide), not an out-of-domain
-- sentinel to special-case. A center legitimately carrying id 63 must
-- participate in ordinary edge marking exactly like any other id --
-- correctly indexing u_edgeColors[63/8] = entry 7 -- never rejected as
-- invalid data merely because it equals the domain's largest value. This
-- replaces the retired REAR_PLANE_ID (255) sentinel-guard fixture: that
-- out-of-domain value no longer occurs anywhere in this domain, so a guard
-- that special-cased it would now incorrectly reject a real polygon 63
-- (see this suite's clear_polygon_id_is_the_hgss_rear_plane_value and
-- a_real_polygon_63_encodes_the_same_id_value_as_the_clear_background for the
-- companion unit-layer proof that a real polygon 63 and the clear background
-- encode to the identical id/depth-target value).
function T.edge_shader_marks_a_real_polygon_id_63_like_any_other_id(scope)
  local out = runEdgePass(scope, {
    { id = 10, depth = 1000 },
    { id = 63, depth = 500 },
    { id = 63, depth = 500 },
  }, eightEdgeColors())
  Assert.near(out[1], 0.7, 1 / 255, "id 63 marks and indexes u_edgeColors[63/8] (entry 7, 0.7,0.7,0.7)")
  Assert.near(out[2], 0.7, 1 / 255)
  Assert.near(out[3], 0.7, 1 / 255)
end

-- Edge behavior anchor 1: a real, differently-id'd neighbor strictly
-- farther than the center (the center is "in front") marks an edge,
-- rendering u_edgeColors[centerId/8] -- id 20 -> entry 20/8 = 2 -> (0.2,
-- 0.2, 0.2).
function T.edge_shader_marks_a_differently_id_neighbor_when_center_is_in_front(scope)
  local out = runEdgePass(scope, {
    { id = 10, depth = 1000 },
    { id = 20, depth = 500 },
    { id = 20, depth = 500 },
  }, eightEdgeColors())
  Assert.near(out[1], 0.2, 1 / 255, "a marked edge renders u_edgeColors[centerId/8] (entry 2, 0.2,0.2,0.2)")
  Assert.near(out[2], 0.2, 1 / 255)
  Assert.near(out[3], 0.2, 1 / 255)
end

-- Edge behavior anchor 2: a differently-id'd neighbor at the SAME depth as
-- the center is not strictly "in front" (the comparison has no tolerance),
-- so no edge fires even though the id differs -- this is what suppresses
-- coplanar boundaries between adjacent same-depth batches.
function T.edge_shader_does_not_mark_a_differently_id_neighbor_at_equal_depth(scope)
  local out = runEdgePass(scope, {
    { id = 10, depth = 500 },
    { id = 20, depth = 500 },
    { id = 20, depth = 500 },
  }, eightEdgeColors())
  Assert.near(out[1], 200 / 255, 1 / 255, "equal depth must not mark: unmodified scene color")
  Assert.near(out[2], 210 / 255, 1 / 255)
  Assert.near(out[3], 220 / 255, 1 / 255)
end

-- Edge behavior anchor 3: a neighbor sharing the center's own polygon id
-- never marks, regardless of depth -- a same-id boundary is never a real
-- silhouette.
function T.edge_shader_does_not_mark_a_same_id_neighbor(scope)
  local out = runEdgePass(scope, {
    { id = 20, depth = 1000 },
    { id = 20, depth = 500 },
    { id = 20, depth = 500 },
  }, eightEdgeColors())
  Assert.near(out[1], 200 / 255, 1 / 255, "same polygon id must not mark: unmodified scene color")
  Assert.near(out[2], 210 / 255, 1 / 255)
  Assert.near(out[3], 220 / 255, 1 / 255)
end

-- DS edge marking samples only the four orthogonal neighbors (left, right,
-- up, down) -- never diagonals. Every existing edge-predicate test
-- above drives a 3x1 strip, which can only ever exercise left/right; this
-- fixture uses a 3x3 grid so a genuine up/down/diagonal distinction exists.
-- The center's four orthogonal neighbors all share its own id/depth (never
-- marking), while the top-left diagonal neighbor is differently-id'd and
-- strictly nearer than the center -- exactly the predicate that would mark
-- if (and only if) diagonals were sampled. If this ever regressed to an
-- eight-neighbor scan, this is the only test in the suite that would catch
-- it: every other fixture's grid is too small to have a diagonal at all.
function T.edge_shader_never_marks_from_a_diagonal_neighbor(scope)
  local out = runEdgeShaderPass(scope, 3, 3, function(idData)
    for x = 0, 2 do
      for y = 0, 2 do
        idData:setPixel(x, y, 20 / 63, 500, 0, 1)
      end
    end
    idData:setPixel(0, 0, 10 / 63, 1000, 0, 1)
  end, function(sceneData)
    for x = 0, 2 do
      for y = 0, 2 do
        sceneData:setPixel(x, y, 200 / 255, 210 / 255, 220 / 255, 1)
      end
    end
  end, eightEdgeColors())

  local r, g, b = out:getPixel(1, 1)
  Assert.near(r, 200 / 255, 1 / 255, "a diagonal-only differently-id'd, nearer neighbor must not mark")
  Assert.near(g, 210 / 255, 1 / 255)
  Assert.near(b, 220 / 255, 1 / 255)
end

-- HGSS field rendering enables 3D anti-aliasing (G3X_AntiAlias(TRUE)), which
-- melonDS's software renderer approximates as 50% coverage at a marked edge.
-- With scene(1,1,1) and edge(0,0,0), AA enabled must read exactly (0.5,0.5,
-- 0.5) pre-fog; AA disabled must read exactly (0,0,0) -- the flat replacement.
function T.edge_aa_coverage_mixes_scene_and_edge_at_exactly_half(scope)
  local function run(antialiasEnabled)
    local edgeShader = scope:own(GxRenderer.new()).edgeShader
    -- Center id 0 indexes u_edgeColors[0] == (0,0,0) (eightEdgeColors' entry
    -- i is (i/10,i/10,i/10)), so the marked pixel's own edge color is exactly
    -- black -- giving an unambiguous expected mix with the white scene.
    local idData = love.image.newImageData(3, 3, "rgba32f")
    for x = 0, 2 do
      for y = 0, 2 do
        idData:setPixel(x, y, 0 / 63, 500, 0, 1)
      end
    end
    for y = 0, 2 do
      idData:setPixel(0, y, 10 / 63, 1000, 0, 1)
    end
    local idImage = scope:own(love.graphics.newImage(idData))
    idImage:setFilter("nearest", "nearest")

    local sceneData = love.image.newImageData(3, 3)
    for x = 0, 2 do
      for y = 0, 2 do
        sceneData:setPixel(x, y, 1, 1, 1, 1)
      end
    end
    local sceneImage = scope:own(love.graphics.newImage(sceneData))
    sceneImage:setFilter("nearest", "nearest")

    local target = scope:own(love.graphics.newCanvas(3, 3))
    love.graphics.setCanvas(target)
    love.graphics.clear(0, 0, 0, 1)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setShader(edgeShader)
    edgeShader:send("u_renderState", idImage)
    edgeShader:send("u_stateSize", { 3, 3 })
    edgeShader:send("u_edgeRadiusPx", 1)
    edgeShader:send("u_antialiasEnabled", antialiasEnabled)
    edgeShader:send("u_edgeColors", unpack(eightEdgeColors()))
    local zeroFogTable = {}
    for i = 1, 32 do
      zeroFogTable[i] = 0
    end
    edgeShader:send("u_fogEnabled", false)
    edgeShader:send("u_fogColor", { 0, 0, 0 })
    sendFogTableGroups(edgeShader, zeroFogTable)
    edgeShader:send("u_fogOffsetDepth", 0)
    edgeShader:send("u_fogShift", 0)
    edgeShader:send("u_fogAlpha", 31)
    love.graphics.draw(sceneImage, 0, 0)
    love.graphics.setShader()
    love.graphics.setCanvas()

    return { target:newImageData():getPixel(1, 1) }
  end

  local enabled = run(true)
  Assert.near(enabled[1], 0.5, 1 / 255, "AA enabled mixes scene(1) and edge(0) to exactly 0.5")
  Assert.near(enabled[2], 0.5, 1 / 255)
  Assert.near(enabled[3], 0.5, 1 / 255)

  local disabled = run(false)
  Assert.near(disabled[1], 0.0, 1 / 255, "AA disabled replaces outright with the edge color")
  Assert.near(disabled[2], 0.0, 1 / 255)
  Assert.near(disabled[3], 0.0, 1 / 255)
end

-- A foreground pixel at the state screen's logical edge must be marked
-- against the rear-plane state (id 63, farthest depth), not a clamped copy
-- of its own row/column -- edge.glsl's stateSample never relies on
-- texture-clamp behavior for this. The rightmost column here has no real
-- neighbor to its right; the shader must still treat that missing neighbor
-- as the rear plane and mark the boundary.
function T.rear_plane_boundary_marks_at_the_state_screen_edge(scope)
  local out = runEdgeShaderPass(scope, 3, 3, function(idData)
    for x = 0, 2 do
      for y = 0, 2 do
        -- A real polygon id/depth that is NOT the rear plane's own encoding,
        -- so a genuine rear-plane fallback is numerically distinguishable
        -- from "reads the same column again".
        idData:setPixel(x, y, 20 / 63, 100, 0, 1)
      end
    end
  end, function(sceneData)
    for x = 0, 2 do
      for y = 0, 2 do
        sceneData:setPixel(x, y, 200 / 255, 210 / 255, 220 / 255, 1)
      end
    end
  end, eightEdgeColors())

  -- Column 2 (rightmost) has no real neighbor to its right; the rear plane
  -- (depth 0xFFFFFF) is always farther than the real depth 100, so this must
  -- mark.
  local r, g, b = out:getPixel(2, 1)
  Assert.near(r, 0.2, 1 / 255, "the rightmost column marks against the rear plane at the screen's logical edge")
  Assert.near(g, 0.2, 1 / 255)
  Assert.near(b, 0.2, 1 / 255)
end

-- The retired "translucent center never marks" fixture (blue-channel
-- translucent-attribute flag) is deliberately not replaced by another
-- shader-level fixture -- edge.glsl no longer reads a translucent identity
-- at all. Its actual behavioral successor is the state-preservation
-- test below, which proves the same real-world invariant (a translucent
-- fragment cannot become a spurious edge center) at its true production
-- boundary: the translucent pass's canvas binding, not a shader flag.

-- A real perspective camera (unlike this suite's usual `fixedCamera`, whose
-- identity projection makes every item's window depth 1.0 regardless of
-- vertex z). The state-preservation
-- test below needs the opaque and translucent triangles to carry genuinely
-- different depth values, so a translucent overwrite of the state depth
-- channel is numerically distinguishable from the opaque value it should
-- have left alone.
local function perspectiveCamera()
  local far = 400
  local projection = Matrix4.perspective(math.rad(60), 640 / 480, 0.1, far)
  return {
    distance = 26,
    far = far,
    view = function()
      return IDENTITY
    end,
    projection = function()
      return projection
    end,
    billboardProjection = function()
      return projection
    end,
  }
end

-- A literal-color triangle at world/eye-space depth `z` (camera looks down
-- -Z, so a more negative `z` is farther away). `scale` shrinks the triangle
-- proportionally to `-z` so that, under the perspective camera above, two
-- triangles at different depths but matching scale/`-z` ratios project to
-- the identical screen-space footprint -- letting the two draws below share
-- one sample pixel while differing only in depth.
local function literalTriangleAtDepth(scope, z, scale)
  return scope:own(syntheticMesh({
    { 0, 0, z, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { scale, 0, z, 1, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 0, scale, z, 0, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
  }))
end

local function opaqueFinalStateItem(mesh, polygonId, fogEnabled)
  return {
    mesh = mesh,
    material = { alphaClass = "opaque", texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
    transform = IDENTITY,
    modelNormal = IDENTITY_NORMAL,
    alphaClass = "opaque",
    cullMode = "none",
    polygonAlpha = 1.0,
    polygonMode = "modulation",
    polygonId = polygonId,
    lightMask = 0,
    alphaCutoff = 0.5 / 255,
    fogEnabled = fogEnabled,
    center = { 0.5, 0.5, 0 },
  }
end

-- `translucentDepthWrite = false` is the only value the real HGSS field
-- corpus ever emits (0 of 10246 censused materials set it true), so this is
-- the exact target-corpus shape, not a hypothetical.
local function nonDepthWritingTranslucentItem(mesh, polygonId, fogEnabled)
  return {
    mesh = mesh,
    material = { alphaClass = "translucent", texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
    transform = IDENTITY,
    modelNormal = IDENTITY_NORMAL,
    alphaClass = "translucent",
    cullMode = "none",
    polygonAlpha = 0.5,
    polygonMode = "modulation",
    polygonId = polygonId,
    translucentDepthWrite = false,
    depthEqual = false,
    lightMask = 0,
    alphaCutoff = 0.5 / 255,
    fogEnabled = fogEnabled,
    center = { 0.5, 0.5, 0 },
  }
end

-- The renderState render-target contract's core translucent-preservation
-- rule: an opaque draw authors renderState's edge id/depth/fog-gate for a
-- pixel; an ordinary non-depth-writing translucent draw covering that same
-- pixel must not replace those values with its own, a blend of the two, or
-- a zeroed value -- because the real DS never updates its depth/attribute
-- buffers for a non-depth-writing translucent fragment, so nothing
-- downstream of it (edge marking, fog gating) may observe it at all.
--
-- Proven by comparing two independent draws through the real GxRenderer
-- pipeline: one with only the opaque triangle, one with the identical opaque
-- triangle plus a translucent triangle in front of it covering the same
-- pixel. The two readbacks must be identical.
function T.translucent_draw_does_not_overwrite_final_state_established_by_opaque_geometry(scope)
  local camera = perspectiveCamera()
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })

  -- Sample pixels are this fixture's own projected footprint (hand-derived
  -- from the perspective matrix above for the triangle centroid at world
  -- (0.3, 0.3, -2) / (0.15, 0.15, -1), both of which project to the same
  -- NDC point by construction), not the identity-camera pixels other tests
  -- in this file use.
  local function stateInterior(renderer, parts)
    render(renderer, emptyRuntime(), camera, parts, nil, viewport)
    local img = renderer.renderState:newImageData()
    local ax, ay = statePixel(renderer, 382, 178)
    local bx, by = statePixel(renderer, 382, 302)
    local a, b = { img:getPixel(ax, ay) }, { img:getPixel(bx, by) }
    -- Whichever sample is not the rear-plane clear (r == 1.0, id 63) carries
    -- the drawn geometry's own renderState value.
    return a[1] < 0.99 and a or b
  end

  local renderer = scope:own(exactRenderer())

  local opaqueOnly = opaqueFinalStateItem(literalTriangleAtDepth(scope, -2, 1), 20, true)
  local baseline = stateInterior(renderer, { { opaqueOnly } })

  -- The translucent triangle sits strictly in front of the opaque one (a
  -- smaller eye-space distance passes the renderer's "less" depth test) and,
  -- scaled to match, shares the same screen-space footprint, so it is
  -- guaranteed to shade the sampled pixel with a genuinely different own
  -- depth value.
  local opaqueUnder = opaqueFinalStateItem(literalTriangleAtDepth(scope, -2, 1), 20, true)
  local translucentOver = nonDepthWritingTranslucentItem(literalTriangleAtDepth(scope, -1, 0.5), 5, false)
  local withTranslucentOnTop = stateInterior(renderer, { { opaqueUnder, translucentOver } })

  Assert.near(
    withTranslucentOnTop[1],
    baseline[1],
    1 / 255,
    "a non-depth-writing translucent draw must not replace the opaque edge polygon id underneath it"
  )
  Assert.near(
    withTranslucentOnTop[2],
    baseline[2],
    1,
    "a non-depth-writing translucent draw must not replace the opaque depth value underneath it"
  )
  -- The fog gate is NOT preserved: the compositor ANDs the destination gate
  -- with the source's own fog flag (the modeled DS rule). The translucent
  -- source here has fog disabled, so the combined gate becomes 0 even though
  -- the opaque destination's gate was 1.
  Assert.near(
    withTranslucentOnTop[3],
    0.0,
    1 / 255,
    "a fog-disabled translucent draw ANDs the destination fog gate to 0"
  )
  -- The last-translucent-ID encoding records the accepted source's polygon id.
  Assert.near(
    withTranslucentOnTop[4],
    6 / 64,
    1 / 255,
    "the accepted translucent source records its polygon id 5 as (5+1)/64 in state A"
  )
end

-- A 32-entry density table whose every raw byte is 64: with both
-- interpolation endpoints always equal, the exact melonDS interpolation
-- (see tests/support/DsFog.lua) collapses to a constant density of 64
-- regardless of depth/offset/shift/densityFrac -- letting these fixtures
-- isolate the fog gate/enable/RGB/ordering questions from the density
-- interpolation math, which ds_fog_test.lua already locks independently.
local function constantDensityTable(byte)
  local t = {}
  for i = 1, 32 do
    t[i] = byte
  end
  return t
end

-- Drives the final full-screen pass (edgeShader/edge.glsl) directly with a
-- synthetic renderState/sceneColor pair and a fog preset -- the same
-- real-GLSL, real-canvas, no-GxRenderer:draw technique runEdgePass above
-- uses for the pure edge-predicate anchors, extended with the fog inputs
-- These fog cases exercise the final pass. `pixels` is the same 3-wide
-- (left/center/right) fixture shape runEdgePass uses, each entry optionally
-- carrying `fogGate` (renderState's blue channel, default 0) and `scene` (the
-- pixel's pre-fog RGB, default opaque white -- RGB6 63/63/63, so an unfogged
-- center reads exactly (1,1,1)). `fog` supplies `enabled`, `color` (packed
-- RGB555), `offsetRaw` (the raw G3X FOG_OFFSET field, not yet *0x200 --
-- u_fogOffsetDepth's own conversion is exercised here, matching how
-- GxRenderer's real per-frame state capture will compute it), `shift`
-- (used directly as u_fogShift, matching HgssFieldFog's `slope` field),
-- `alpha` (0..31, defaults to 31 -- opaque -- matching a steady preset that
-- does not attenuate alpha, used as u_fogAlpha), and `table32` (32 raw
-- density bytes, 0..255). Draws through "replace"/"premultiplied" blend,
-- matching GxRenderer's own final composite, so the readback reflects the
-- shader's computed RGB/alpha directly rather than the host's default alpha
-- compositing against the (irrelevant) black-cleared target. Returns the
-- center pixel's rendered RGBA.
-- A 3x3 grid (not 3x1); see runEdgePass's header for why a genuinely 1-line-
-- tall state target would spuriously exercise the rear-plane fallback on
-- every vertical neighbor probe instead of the real (identical) row data
-- these fixtures intend.
local function runFinalPass(scope, pixels, fog, edgeColors, antialiasEnabled)
  local edgeShader = scope:own(GxRenderer.new()).edgeShader

  local idData = love.image.newImageData(3, 3, "rgba32f")
  for i, p in ipairs(pixels) do
    for row = 0, 2 do
      idData:setPixel(i - 1, row, p.id / 63, p.depth, p.fogGate or 0, 1)
    end
  end
  local idImage = scope:own(love.graphics.newImage(idData))
  idImage:setFilter("nearest", "nearest")

  local sceneData = love.image.newImageData(3, 3)
  for i, p in ipairs(pixels) do
    local c = p.scene or { 1, 1, 1 }
    for row = 0, 2 do
      sceneData:setPixel(i - 1, row, c[1], c[2], c[3], c[4] or 1)
    end
  end
  local sceneImage = scope:own(love.graphics.newImage(sceneData))
  sceneImage:setFilter("nearest", "nearest")

  local target = scope:own(love.graphics.newCanvas(3, 3))
  love.graphics.setCanvas(target)
  love.graphics.clear(0, 0, 0, 1)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setShader(edgeShader)
  edgeShader:send("u_renderState", idImage)
  edgeShader:send("u_stateSize", { 3, 3 })
  edgeShader:send("u_edgeRadiusPx", 1)
  -- Coverage defaults off so these fog fixtures assert the raw
  -- edge-replacement/fog result; the fog-ordering test below is the one
  -- caller that opts into AA coverage to distinguish all three candidate
  -- orderings numerically.
  edgeShader:send("u_antialiasEnabled", antialiasEnabled == true)
  edgeShader:send("u_edgeColors", unpack(edgeColors or eightEdgeColors()))
  edgeShader:send("u_fogEnabled", fog.enabled)
  -- Decoded the same way GxRenderer:_sendFog already decodes fog.color for
  -- the (retired) per-object path: component/31, normalized 5-bit.
  local fogColorNormalized = {
    (fog.color % 32) / 31,
    (math.floor(fog.color / 32) % 32) / 31,
    (math.floor(fog.color / 1024) % 32) / 31,
  }
  edgeShader:send("u_fogColor", fogColorNormalized)
  sendFogTableGroups(edgeShader, fog.table32)
  edgeShader:send("u_fogOffsetDepth", fog.offsetRaw * 0x200)
  edgeShader:send("u_fogShift", fog.shift)
  edgeShader:send("u_fogAlpha", fog.alpha or 31)
  love.graphics.setBlendMode("replace", "premultiplied")
  love.graphics.draw(sceneImage, 0, 0)
  love.graphics.setShader()
  love.graphics.setCanvas()

  local out = target:newImageData()
  return { out:getPixel(1, 1) }
end

-- Fog visibly changes an opaque fragment at a
-- known synthetic depth. A constant density-64 table makes the exact
-- expected output independent of the depth value itself (see
-- constantDensityTable): outRgb6 = floor((63*64 + 0*64)/128) = 31 against a
-- black (rgb555=0) fog color and a fully white (RGB6 63) scene fragment, so
-- the fragment must read 31/63, not 1.0 (unfogged) or the old /127 or
-- DS_DEPTH_MAX/32-derived value.
function T.fog_visibly_changes_an_opaque_fragment_at_a_known_synthetic_depth(scope)
  local out = runFinalPass(scope, {
    { id = 20, depth = 12345, fogGate = 1 },
    { id = 20, depth = 12345, fogGate = 1 },
    { id = 20, depth = 12345, fogGate = 1 },
  }, { enabled = true, color = 0, offsetRaw = 0, shift = 0, table32 = constantDensityTable(64) })
  Assert.near(out[1], 31 / 63, 1 / 255, "half-density black fog over a white fragment must read 31/63")
  Assert.near(out[2], 31 / 63, 1 / 255)
  Assert.near(out[3], 31 / 63, 1 / 255)
end

-- Disabling the global fog gate leaves the
-- identical fragment/depth/polygon-gate setup entirely unchanged (the scene
-- color, 1.0 white, passes through untouched).
function T.disabled_global_fog_leaves_the_fragment_unchanged(scope)
  local out = runFinalPass(scope, {
    { id = 20, depth = 12345, fogGate = 1 },
    { id = 20, depth = 12345, fogGate = 1 },
    { id = 20, depth = 12345, fogGate = 1 },
  }, { enabled = false, color = 0, offsetRaw = 0, shift = 0, table32 = constantDensityTable(64) })
  Assert.near(out[1], 1.0, 1 / 255, "u_fogEnabled=false must leave the fragment at its unfogged scene color")
  Assert.near(out[2], 1.0, 1 / 255)
  Assert.near(out[3], 1.0, 1 / 255)
end

-- The global gate alone is not sufficient --
-- this draw's own polygon fog gate (renderState's blue channel,
-- also be set. With the
-- global gate enabled but this pixel's own gate 0, the fragment must stay
-- unchanged, exactly like GBATEK's two-gate fog rule the retired per-object
-- map.glsl path already enforced.
function T.polygon_fog_gate_false_leaves_the_fragment_unchanged(scope)
  local out = runFinalPass(scope, {
    { id = 20, depth = 12345, fogGate = 0 },
    { id = 20, depth = 12345, fogGate = 0 },
    { id = 20, depth = 12345, fogGate = 0 },
  }, { enabled = true, color = 0, offsetRaw = 0, shift = 0, table32 = constantDensityTable(64) })
  Assert.near(out[1], 1.0, 1 / 255, "a fog-disabled polygon must stay unfogged even with the global gate enabled")
  Assert.near(out[2], 1.0, 1 / 255)
  Assert.near(out[3], 1.0, 1 / 255)
end

-- An edge-marked pixel is fogged AFTER edge RGB
-- replacement, not fogged-then-overwritten. The center (id 20, depth 500,
-- fog-gated) sits strictly in front of its differently-id'd left neighbor
-- (id 10, depth 1000, farther), so it marks and its RGB is first replaced by
-- u_edgeColors[20/8] = entry 2 = (0.2, 0.2, 0.2) -- 6-bit floor(0.2*63+0.5) =
-- 13. Fog then blends *that* value, not the pre-edge scene color: outRgb6 =
-- floor((13*64 + 0*64)/128) = 6, i.e. 6/63. If fog ran before edge
-- replacement (or not at all after it), the result would instead be the
-- unfogged edge color itself (13/63 = 0.2063, matching the input exactly) --
-- a numerically distinct, easily distinguished wrong answer.
function T.edge_marked_pixel_is_fogged_after_edge_rgb_replacement(scope)
  local out = runFinalPass(scope, {
    { id = 10, depth = 1000, fogGate = 0 },
    { id = 20, depth = 500, fogGate = 1 },
    { id = 20, depth = 500, fogGate = 1 },
  }, { enabled = true, color = 0, offsetRaw = 0, shift = 0, table32 = constantDensityTable(64) }, eightEdgeColors())
  Assert.near(out[1], 6 / 63, 1 / 255, "the edge color must be fogged, not the pre-edge scene color")
  Assert.near(out[2], 6 / 63, 1 / 255)
  Assert.near(out[3], 6 / 63, 1 / 255)
end

-- The exact ordering contract (fog(mix(scene, edge, coverage)), never
-- mix(fog(scene), edge, coverage) or mix(scene, fog(edge), coverage)) needs
-- AA coverage enabled (a real 0.5 mix, not a flat replacement) and three
-- mutually distinct scene/edge/fog colors to tell all three candidate
-- formulas apart numerically. Center: white scene (RGB6=63), black edge
-- color (RGB6=0, u_edgeColors[0]), fog RGB555 (16,16,16) -> RGB6=33,
-- constant density 64:
--   correct:  fog(mix(1, 0, 0.5))     = fog(0.5)      -> floor((33*64+32*64)/128) = 32 -> 32/63
--   wrong (fog before edge): mix(fog(scene), edge, 0.5)
--             fog(scene=63)           = floor((33*64+63*64)/128) = 48
--             mix(48/63, 0, 0.5)                                  = 24/63
--   wrong (fog only the edge operand): mix(scene, fog(edge), 0.5)
--             fog(edge=0)             = floor((33*64+0*64)/128)  = 16
--             mix(63/63, 16/63, 0.5)                              = 39.5/63
-- All three are separated by more than 0.09 (23/63), far wider than the
-- readback tolerance, so only the correct ordering can pass.
function T.fog_composites_over_the_edge_mixed_result_not_before_or_only_the_edge_operand(scope)
  local fogRgb555 = 16 + 16 * 32 + 16 * 1024
  local out = runFinalPass(
    scope,
    {
      { id = 10, depth = 1000, fogGate = 0 },
      { id = 0, depth = 500, fogGate = 1, scene = { 1, 1, 1 } },
      { id = 0, depth = 500, fogGate = 1, scene = { 1, 1, 1 } },
    },
    { enabled = true, color = fogRgb555, offsetRaw = 0, shift = 0, table32 = constantDensityTable(64) },
    eightEdgeColors(),
    true
  )
  Assert.near(
    out[1],
    32 / 63,
    1 / 255,
    "fog must apply to the already edge-mixed color, not before or one operand alone"
  )
  Assert.near(out[2], 32 / 63, 1 / 255)
  Assert.near(out[3], 32 / 63, 1 / 255)
end

-- Edge marking replaces only RGB -- the prior scene alpha survives
-- untouched (`vec4(edgeColor, scene.a)`), never stamped to a fixed/opaque
-- value. Fog is disabled here so this is isolated from fog's own (separate,
-- already-covered) alpha blend: a marked pixel with a non-trivial scene
-- alpha (0.5, not this suite's usual opaque 1.0) must keep that exact alpha.
function T.edge_marking_preserves_scene_alpha_unchanged(scope)
  local out = runFinalPass(scope, {
    { id = 10, depth = 1000, fogGate = 0, scene = { 1, 1, 1, 0.5 } },
    { id = 20, depth = 500, fogGate = 0, scene = { 1, 1, 1, 0.5 } },
    { id = 20, depth = 500, fogGate = 0, scene = { 1, 1, 1, 0.5 } },
  }, { enabled = false, color = 0, offsetRaw = 0, shift = 0, table32 = constantDensityTable(64) })
  Assert.near(out[1], 0.2, 1 / 255, "the marked pixel's RGB is replaced by u_edgeColors[20/8] (entry 2)")
  Assert.near(out[4], 0.5, 1 / 255, "edge marking must not modify alpha -- it stays the prior scene alpha")
end

-- Changing the scene's fog preset changes the
-- final pass's output between two draws with identical geometry/depth/gate
-- state, proving the uniforms are actually resent and consumed each frame,
-- not cached from the first draw. Preset A (black fog, as fixture 1) reads
-- 31/63; preset B (white fog, rgb555 (31,31,31)) blends white with white and
-- must stay 1.0 -- a wide, unambiguous divergence.
function T.scene_change_between_two_fog_presets_updates_the_final_output(scope)
  local pixels = {
    { id = 20, depth = 12345, fogGate = 1 },
    { id = 20, depth = 12345, fogGate = 1 },
    { id = 20, depth = 12345, fogGate = 1 },
  }
  local blackFogOut = runFinalPass(
    scope,
    pixels,
    { enabled = true, color = 0, offsetRaw = 0, shift = 0, table32 = constantDensityTable(64) }
  )
  local whiteRgb555 = 31 + 31 * 32 + 31 * 1024
  local whiteFogOut = runFinalPass(
    scope,
    pixels,
    { enabled = true, color = whiteRgb555, offsetRaw = 0, shift = 0, table32 = constantDensityTable(64) }
  )

  Assert.near(blackFogOut[1], 31 / 63, 1 / 255, "the first preset's black fog must blend to 31/63")
  Assert.near(whiteFogOut[1], 1.0, 1 / 255, "the second preset's white fog over a white fragment must stay 1.0")
  Assert.isTrue(
    math.abs(blackFogOut[1] - whiteFogOut[1]) > 0.1,
    "changing the scene's fog preset between draws must change the final pass's output"
  )
end

-- Fog alpha blends the same way as RGB, in the 5-bit domain, and this
-- draw's own "replace"/"premultiplied" blend mode (see GxRenderer.lua's
-- doDraw) must write that computed alpha as data rather than let the host's
-- default alpha compositing consume it. A fully opaque white scene fragment
-- (srcAlpha5 = 31) fogged at density 64 against a preset whose fog alpha is
-- 0 (matching the real Flash preset) must read back alpha = floor((0*64 +
-- 31*64)/128)/31 = 15/31, not 1.0 (alpha untouched) and not a value
-- indicating the RGB was additionally darkened by host alpha compositing
-- (which, at alpha 15/31 over this test's black-cleared target, would read
-- roughly half of the expected RGB instead of the exact value).
function T.fog_alpha_blends_and_is_not_additionally_composited_by_the_host(scope)
  local out = runFinalPass(scope, {
    { id = 20, depth = 12345, fogGate = 1 },
    { id = 20, depth = 12345, fogGate = 1 },
    { id = 20, depth = 12345, fogGate = 1 },
  }, { enabled = true, color = 0, offsetRaw = 0, shift = 0, table32 = constantDensityTable(64), alpha = 0 })
  Assert.near(
    out[1],
    31 / 63,
    1 / 255,
    "RGB must be the exact fog blend, not additionally darkened by host alpha compositing"
  )
  Assert.near(out[4], 15 / 31, 1 / 255, "alpha must reflect the melonDS fog-alpha blend, not stay unfogged at 1.0")
end

-- ---- full-resolution state + zoom-aware edge scale fixtures ----

-- The composite harness: redirects only the final resolve's default-framebuffer
-- binding (setCanvas(nil)) into a readable canvas at the same dimensions, so
-- the post-edge/fog output is observable. Every internal target binding still
-- goes to the real implementation; the renderer's caller-state restore re-binds
-- the pre-draw canvas at the end.
local function compositeReadback(scope, _, viewport)
  local width = math.max(1, math.floor(viewport.worldViewport.width + 0.5))
  local height = math.max(1, math.floor(viewport.worldViewport.height + 0.5))
  local out = scope:own(lg.newCanvas(width, height))
  out:setFilter("nearest", "nearest")
  local realSetCanvas = lg.setCanvas
  local patched = true
  lg.setCanvas = function(c, ...)
    if c == nil then
      realSetCanvas(out)
    else
      realSetCanvas(c, ...)
    end
  end
  return {
    canvas = out,
    restore = function()
      if patched then
        lg.setCanvas = realSetCanvas
        patched = false
      end
    end,
  }
end

local function opaqueItem(mesh, polygonId)
  return {
    mesh = mesh,
    material = { alphaClass = "opaque", texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
    transform = IDENTITY,
    modelNormal = IDENTITY_NORMAL,
    alphaClass = "opaque",
    cullMode = "none",
    polygonAlpha = 1.0,
    polygonMode = "modulation",
    polygonId = polygonId,
    lightMask = 0,
    alphaCutoff = 0.5 / 255,
    fogEnabled = false,
    center = { 0.5, 0.5, 0 },
  }
end

-- Observable boundary: the renderer-owned state targets are exactly the
-- color targets' dimensions at every host size. 1280x720 must not allocate a
-- 341x192 state raster; 2560x1440 stays one-to-one as well. This reads the
-- real canvas objects on the real driver, so it is the honest boundary the
-- acceptance scenario names -- not a fake-graphics approximation.
function T.state_canvas_dimensions_equal_color_dimensions_at_every_host_size(scope)
  local renderer = scope:own(GxRenderer.new())
  local camera, runtime = fixedCamera(), emptyRuntime()
  local viewport = FieldViewport.new(1280, 720, { mode = "expanded" })
  render(renderer, runtime, camera, nil, nil, viewport)
  Assert.equal(renderer.colorW, 1280, "color target width matches the expanded viewport")
  Assert.equal(renderer.colorH, 720)
  Assert.equal(renderer.stateW, renderer.colorW, "state width equals color width at 1280x720")
  Assert.equal(renderer.stateH, renderer.colorH, "state height equals color height at 1280x720")
  Assert.isTrue(renderer.stateW ~= 341, "1280x720 must not allocate the fixed 341-wide semantic raster")
  Assert.isTrue(renderer.stateH ~= 192, "1280x720 must not allocate the fixed 192-line semantic raster")
  local stateCanvas, worldDepth = renderer.renderState, renderer.colorDepth
  Assert.notNil(stateCanvas, "the state canvas is published under its durable name")
  Assert.notNil(worldDepth, "the shared world depth target is published under its durable name")
  Assert.equal(stateCanvas:getWidth(), renderer.colorW)
  Assert.equal(stateCanvas:getHeight(), renderer.colorH)
  Assert.equal(worldDepth:getWidth(), renderer.colorW)
  Assert.equal(worldDepth:getHeight(), renderer.colorH)

  viewport:resize(2560, 1440)
  render(renderer, runtime, camera, nil, nil, viewport)
  Assert.equal(renderer.colorW, 2560)
  Assert.equal(renderer.colorH, 1440)
  Assert.equal(renderer.stateW, renderer.colorW, "state width equals color width at 2560x1440")
  Assert.equal(renderer.stateH, renderer.colorH, "state height equals color height at 2560x1440")
  Assert.equal(renderer.renderState:getWidth(), 2560)
  Assert.equal(renderer.renderState:getHeight(), 1440)
end

-- Shader contract: the final pass declares the full-resolution state
-- uniforms (u_renderState/u_stateSize) and the integer edge-radius uniform
-- (u_edgeRadiusPx). Presence is asserted by sending values; LÖVE errors for
-- unknown names, exactly like the file's other uniform-presence tests.
function T.final_shader_has_full_resolution_state_and_edge_radius_uniforms(scope)
  local edgeShader = scope:own(GxRenderer.new()).edgeShader
  local size = love.image.newImageData(8, 8, "rgba32f")
  local stateImage = scope:own(love.graphics.newImage(size))
  stateImage:setFilter("nearest", "nearest")
  edgeShader:send("u_renderState", stateImage)
  edgeShader:send("u_stateSize", { 8, 8 })
  edgeShader:send("u_edgeRadiusPx", 4)
end

-- Fixture: a 2-host-pixel-wide vertical white bar (polygonId 20) drawn in
-- front of the clear rear plane through the real world MRT and resolve passes, plus
-- a diagonal blade crossing the same rows. Identity camera at z=0 gives the
-- drawn state depth 41943 < clear 16777215 (depth ordering only, never an
-- absolute value). Every edge-colored output pixel must lie within the
-- configured radius (4 at 1280x720) of a visibly present object pixel, and
-- the bar must not lose state over stretches that are visibly present.
--
local function thinBarParts(scope)
  local function v(x, y)
    return { x, y, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 }
  end
  -- Vertical bar: 2 host px wide (0.003125 world) centered at x = -0.08,
  -- spanning y in [-0.5, 0.5] (the full 720p height).
  local bar = scope:own(syntheticMesh({
    v(-0.0815625, -0.5),
    v(-0.0784375, -0.5),
    v(-0.0784375, 0.5),
    v(-0.0815625, -0.5),
    v(-0.0784375, 0.5),
    v(-0.0815625, 0.5),
  }))
  -- Diagonal blade: 2 px wide, running from (0.31, -0.5) to (0.6, 0.5).
  local blade = scope:own(syntheticMesh({
    v(0.31, -0.5),
    v(0.312, -0.5),
    v(0.6, 0.5),
    v(0.31, -0.5),
    v(0.6, 0.5),
    v(0.598, 0.5),
  }))
  return { { opaqueItem(bar, 20) }, { opaqueItem(blade, 20) } }
end

function T.thin_bar_and_blade_keep_their_attached_edge_state(scope)
  local renderer = scope:own(GxRenderer.new())
  local runtime = emptyRuntime()
  -- id 20 -> u_edgeColors[20/8] = entry 2: a distinguishable pure blue
  -- (RGB555 packed: blue channel 31).
  runtime.edgeColors = { [0] = 0, 0, 31, 0, 0, 0, 0, 0 }
  local viewport = FieldViewport.new(1280, 720, { mode = "expanded" })
  local harness = compositeReadback(scope, renderer, viewport)

  render(renderer, runtime, fixedCamera(), thinBarParts(scope), nil, viewport)
  harness.restore()
  love.graphics.setCanvas()

  local color = renderer.sceneColor:newImageData()
  local state = renderer.renderState:newImageData()
  local final = harness.canvas:newImageData()

  -- Sample a middle row of the bar (color row 360).
  local colorScale = color:getPixel(0, 0)
  local scale = colorScale > 1 and 255 or 1
  local barCols = {}
  for x = 0, 1279 do
    local r, g, b = color:getPixel(x, 360)
    if r >= 0.9 * scale and g >= 0.9 * scale and b >= 0.9 * scale then
      barCols[#barCols + 1] = x
    end
  end
  Assert.isTrue(#barCols >= 1, "the bar is visibly present on the sampled row")
  Assert.isTrue(#barCols <= 8, "the sampled row is a thin structure, not a large quad")

  -- State coverage: for the sampled row, every color column that is part of
  -- the visible bar must carry this item's own state at the same screen
  -- location (state reads map through the renderer's own state dimensions,
  -- which are one-to-one with the color dimensions).
  local function stateAt(colorX, colorY)
    local sx = math.min(renderer.stateW - 1, math.floor(colorX * renderer.stateW / renderer.colorW))
    local sy = math.min(renderer.stateH - 1, math.floor(colorY * renderer.stateH / renderer.colorH))
    return state:getPixel(sx, sy)
  end
  local stateHits = 0
  for _, x in ipairs(barCols) do
    local sr = stateAt(x, 360)
    if sr < 0.9 * scale then
      stateHits = stateHits + 1
    end
  end
  Assert.equal(stateHits, #barCols, "the visible bar's pixels carry their own state at the same screen location")

  -- Every edge-colored pixel lies within the configured radius (4) of a
  -- visible object pixel, and no edge pixel exists where there is no object.
  local function isObjectColor(p)
    return p[1] >= 0.9 * scale and p[2] >= 0.9 * scale and p[3] >= 0.9 * scale
  end
  for x = 0, 1279 do
    local r, g, b = final:getPixel(x, 360)
    if r >= 0.9 * scale and g < 0.6 * scale and b < 0.6 * scale then
      local nearObject = false
      for d = -4, 4 do
        local nx = x + d
        if nx >= 0 and nx < 1280 then
          local pr, pg, pb = color:getPixel(nx, 360)
          if isObjectColor({ pr, pg, pb }) then
            nearObject = true
            break
          end
        end
      end
      Assert.isTrue(nearObject, "every edge-colored pixel lies within the radius of a visible object pixel")
    end
  end

  -- The bar's state must not be lost over visibly-present stretches: every
  -- state row the bar actually covers (the identity camera maps the bar's
  -- world y in [-0.5, 0.5] to rows 180..539 of the 720-row state raster)
  -- must carry id-20 state at the bar's columns. Rows outside that footprint
  -- legitimately have no state -- the bar never reaches them.
  local rowTop = math.floor((1 - 0.5) / 2 * renderer.stateH + 0.5)
  local rowBottom = math.floor((1 + 0.5) / 2 * renderer.stateH + 0.5) - 1
  local lostRows = 0
  for sy = rowTop, rowBottom do
    local stamped = false
    for sx = 0, renderer.stateW - 1 do
      local sr = state:getPixel(sx, sy)
      if sr < 0.9 * scale then
        stamped = true
        break
      end
    end
    if not stamped then
      lostRows = lostRows + 1
    end
  end
  Assert.equal(lostRows, 0, "no state row the visible bar crosses loses its state")
end

-- Mixed-alpha motion: a 5x1 texture (alpha5 0,1,15,30,31) on a ground
-- quad (id 3, fog-gated) rendered at two offsets whose visible 30->31
-- boundary is essentially stationary while the old 192-line state raster's
-- stamp cell flips. State changes must be confined to full-resolution opaque
-- texel coverage, and no final edge-colored pixel may appear whose support
-- exists only because one coarse state cell changed.
function T.moving_mixed_alpha_coverage_does_not_create_coarse_state_edges(scope)
  local renderer = scope:own(GxRenderer.new())
  local runtime = emptyRuntime()
  -- id 3 -> u_edgeColors[3/8] = entry 0: pure red.
  runtime.edgeColors = { [0] = 31, 0, 0, 0, 0, 0, 0, 0 }
  local viewport = FieldViewport.new(1280, 720, { mode = "expanded" })

  local data = love.image.newImageData(5, 1)
  local bytes = { 0, 8, 123, 245, 255 }
  for i, byte in ipairs(bytes) do
    data:setPixel(i - 1, 0, 1, 1, 1, byte / 255)
  end
  local image = scope:own(love.graphics.newImage(data))
  image:setFilter("nearest", "nearest")

  -- Quad spans y in [-0.3, 0.7] (sample row 360 is interior) and x in
  -- [dx, 1+dx]; u runs [0,1] across x so the five texel columns sweep.
  local function mixedQuad(dxWorld)
    local function v(x, y, u)
      return { x, y, 0, u, y, 0, 0, 1, 1, 1, 1, 1, 0 }
    end
    return scope:own(syntheticMesh({
      v(dxWorld, -0.3, 0),
      v(1 + dxWorld, -0.3, 1),
      v(1 + dxWorld, 0.7, 1),
      v(dxWorld, -0.3, 0),
      v(1 + dxWorld, 0.7, 1),
      v(dxWorld, 0.7, 0),
    }))
  end
  local function transformedMixedItem(m)
    return {
      mesh = m,
      material = { texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }, image = image },
      transform = IDENTITY,
      modelNormal = IDENTITY_NORMAL,
      alphaClass = "mixed",
      cullMode = "none",
      polygonAlpha = 1.0,
      polygonMode = "modulation",
      polygonId = 3,
      lightMask = 0,
      fogEnabled = true,
      alphaCutoff = 0.5 / 255,
      translucentDepthWrite = false,
      center = { 0.5, 0.5, 0 },
    }
  end

  local function scan(offsetPx)
    local harness = compositeReadback(scope, renderer, viewport)
    local dx = offsetPx * 2 / 1280
    render(renderer, runtime, fixedCamera(), { { transformedMixedItem(mixedQuad(dx)) } }, nil, viewport)
    harness.restore()
    love.graphics.setCanvas()
    local color = renderer.sceneColor:newImageData()
    local state = renderer.renderState:newImageData()
    local final = harness.canvas:newImageData()
    local colorScale = color:getPixel(0, 0)
    local scale = colorScale > 1 and 255 or 1

    -- Visible 30->31 boundary: first fully opaque (alpha-31) column.
    local visibleBoundary = nil
    for x = 0, 1279 do
      local r, g, b = color:getPixel(x, 360)
      if r >= 0.99 * scale and g >= 0.99 * scale and b >= 0.99 * scale then
        visibleBoundary = x
        break
      end
    end
    -- State stamp edge: first state column carrying id 3 on the sampled row.
    -- Read both canvas Y orientations because ImageData readback orientation
    -- is driver-dependent.
    local stateStampLeft = nil
    for sx = 0, renderer.stateW - 1 do
      local sy = math.min(renderer.stateH - 1, math.floor(360 * renderer.stateH / renderer.colorH))
      local sample = statePixelAt(renderer, state, sx, sy)
      if sample[1] < 0.9 * scale then
        stateStampLeft = sx
        break
      end
    end
    local stateStampColor = stateStampLeft and math.floor((stateStampLeft + 0.5) * renderer.colorW / renderer.stateW)
      or nil
    -- Final edge-colored columns on the sampled row.
    local edgeCols = {}
    for x = 0, 1279 do
      local r, g, b = final:getPixel(x, 360)
      if r >= 0.9 * scale and g < 0.6 * scale and b < 0.6 * scale then
        edgeCols[#edgeCols + 1] = x
      end
    end
    return {
      visibleBoundary = visibleBoundary,
      stateStampLeft = stateStampLeft,
      stateStampColor = stateStampColor,
      edgeCols = edgeCols,
    }
  end

  local a = scan(0.75)
  local b = scan(2.75)
  Assert.notNil(a.visibleBoundary, "the mixed quad is visible at the first offset")
  Assert.notNil(b.visibleBoundary, "the mixed quad is visible at the second offset")

  -- The visible 30->31 boundary moves by at most a couple of host pixels.
  Assert.isTrue(math.abs(b.visibleBoundary - a.visibleBoundary) <= 2, "the visible boundary is nearly stationary")

  -- The state stamp edge may not drift more than one host pixel per host
  -- pixel of visible movement: state changes are confined to full-resolution
  -- opaque texel coverage.
  local stateJump = b.stateStampColor - a.stateStampColor
  Assert.isTrue(
    stateJump <= math.abs(b.visibleBoundary - a.visibleBoundary) + 1,
    "the state stamp edge stays within the visible opaque texel coverage"
  )

  -- No edge-colored pixel appears whose support exists only because one
  -- coarse state cell changed: every edge pixel must be adjacent to a visible
  -- opaque texel at BOTH offsets.
  local function everyEdgeNearVisible(sample)
    for _, x in ipairs(sample.edgeCols) do
      local near = false
      for d = -1, 1 do
        local nx = x + d
        if nx >= sample.visibleBoundary then
          near = true
          break
        end
      end
      Assert.isTrue(near, "no edge-colored pixel appears without visible opaque texel support")
    end
  end
  everyEdgeNearVisible(a)
  everyEdgeNearVisible(b)
end

-- ---- field depth-domain fixtures (map.glsl's G-channel conversion) ----

-- The field camera selects DS Z buffering (GX_BUFFERMODE_Z), so the render
-- state's green channel is the DS 24-bit Z-domain value derived from the host
-- fragment's normalized window depth (the non-W path of the pinned
-- GPU3D::SubmitPolygon), not a linear-eye-depth proxy normalized by the
-- camera's far plane. This section's fixtures drive that conversion and its
-- consumers. Expected values below are hand-derived from the normative
-- conversion -- signed 14-bit scale, +0x3FFF, *0x200, clamp to 0..0xFFFFFF --
-- never computed by calling production code.

-- The exact conversion the state shader models, re-derived independently in
-- test arithmetic: windowZ in [0,1] -> ndcZ = 2*windowZ - 1, ndcZ scaled by
-- 0x4000 with truncation toward zero (GLSL int() truncates, so a fractional
-- negative NDC must not floor), offset by 0x3FFF, scaled by 0x200, clamped
-- to the 24-bit domain.
local function truncTowardZero(x)
  return x >= 0 and math.floor(x) or math.ceil(x)
end

local function expectedDsDepth(windowZ)
  local ndc = windowZ * 2 - 1
  local ndc14 = truncTowardZero(ndc * 0x4000)
  local depth = (ndc14 + 0x3FFF) * 0x200
  if depth < 0 then
    depth = 0
  elseif depth > 0xFFFFFF then
    depth = 0xFFFFFF
  end
  return depth
end

-- The windowZ value the fragment shader sees for an eye-space depth `z`
-- under Matrix4.perspective(math.rad(60), 640/480, 0.1, 400) with an
-- identity view (the exact camera the perspective fixtures in this file
-- use): clipZ = z*(far+near)/(near-far) + (2*far*near)/(near-far),
-- clipW = -z, ndcZ = clipZ/clipW, windowZ = (ndcZ+1)/2.
local function projectedWindowZ(z)
  return (z * 400.1 + 80) / (z * 399.9) / 2 + 0.5
end

-- Renders one fullscreen quad through the real world-MRT shader with a fixed
-- normalized device depth, then reads the renderState G channel back.
-- Driving the world-MRT shader directly (rather than through GxRenderer:draw) fixes
-- the fragment's NDC depth exactly, so the window-depth anchors are exact
-- rather than dependent on rasterization. The MRT state output is the
-- renderer-owned rgba32f canvas, so the readback is the real acceptance
-- boundary (the state raster's green channel), not a fake: the same
-- worldShader/renderState pair GxRenderer's world pass binds is driven
-- here directly, with the projection pinned so every fragment lands at the
-- requested NDC depth (GxRenderer:draw would overwrite a custom u_proj with
-- the camera's own projection on every draw item). Depth testing is disabled
-- so the far anchor (windowZ == 1) is not rejected by the strict "less"
-- test against the depth-cleared rear plane.
local function stateDepthReadback(scope, ndcZ)
  local renderer = scope:own(GxRenderer.new())
  local mesh = scope:own(syntheticMesh({
    { -1, -1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 3, -1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 3, 3, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { -1, -1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 3, 3, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { -1, 3, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
  }))
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })
  -- Establish the real renderState canvas (and its dimensions) through one
  -- ordinary GxRenderer:draw, then drive the same canvas directly below.
  render(renderer, emptyRuntime(), fixedCamera(), { { opaqueFinalStateItem(mesh, 20, false) } }, nil, viewport)

  -- Rewrite the world shader's projection so every fragment lands at the
  -- requested normalized depth: a clip matrix mapping [x,y] to the unit
  -- square and every z to the chosen NDC depth. LÖVE's projection matrix
  -- uses row-vector convention, so this orthographic form's rows are the
  -- clip components.
  local proj = {
    2,
    0,
    0,
    0,
    0,
    2,
    0,
    0,
    0,
    0,
    0,
    0,
    -1,
    -1,
    ndcZ,
    1,
  }
  lg.setCanvas(renderer._colorTargets)
  -- Clear to the normalized id-63 sentinel (CLEAR_POLYGON_ID -> 1.0), not
  -- black: the readback below tells a drawn pixel (id 20 -> 20/63) from the
  -- untouched background by its red channel, and black would be
  -- indistinguishable from the drawn value.
  lg.clear(1, 0, 0, 1)
  lg.setShader(renderer.worldShader)
  lg.setDepthMode("always", false)
  lg.setBlendMode("replace", "premultiplied")
  renderer.worldShader:send("u_view", "column", IDENTITY)
  renderer:_sendLighting(emptyRuntime(), renderer.worldShader)
  renderer._activeShader = renderer.worldShader
  renderer:_drawItem(opaqueFinalStateItem(mesh, 20, false), proj, 0, IDENTITY)
  renderer._activeShader = nil
  lg.setMeshCullMode("none")
  lg.setShader()
  lg.setCanvas()

  local img = renderer.renderState:newImageData()
  local x, y = statePixel(renderer, 320, 240)
  local sample = { img:getPixel(x, y) }
  -- The state target was cleared to the id-63 sentinel (1.0), so the sample
  -- whose red channel is the drawn id (20/63) is the real fragment on every
  -- driver: canvas readback is Y-inverted on some drivers, so probe the
  -- Y-mirror too and pick whichever carries the drawn id.
  local mirrored = { img:getPixel(x, renderer.stateH - 1 - y) }
  return sample[1] < 0.5 and sample or mirrored
end

-- The canonical window-depth anchors of the DS Z conversion: 0 -> 0 (the
-- near plane, clamped from the signed formula), 0.5 -> 0x7FFE00 (the exact
-- mid depth, matching the +0x3FFF offset), and 1 -> 0xFFFE00 (the far plane
-- -- the DS formula's far value, distinct from the 0xFFFFFF clear/rear
-- plane that keeps marking against the background working). All three are
-- observed through the real state shader's renderState readback.
function T.state_depth_maps_the_canonical_window_depth_anchors(scope)
  Assert.near(stateDepthReadback(scope, -1)[2], expectedDsDepth(0), 1, "windowZ=0 must map to DS depth 0")
  Assert.near(stateDepthReadback(scope, 0)[2], expectedDsDepth(0.5), 1, "windowZ=0.5 must map to DS depth 0x7FFE00")
  Assert.near(stateDepthReadback(scope, 1)[2], expectedDsDepth(1), 1, "windowZ=1 must map to DS depth 0xFFFE00")
end

-- WindowZ 0.4: ndcZ = -0.2, ndcZ*0x4000 = -3276.8 -- a fractional negative
-- value where truncation toward zero and floor diverge. Truncation gives
-- ndc14 = -3276 -> DS depth 0x666600; floor would give -3277 ->
-- 0x665E00. The state shader must read the truncation value, so a
-- floor-based conversion is caught by the readback, not merely by code
-- review.
function T.state_depth_truncates_negative_ndc_toward_zero(scope)
  local truncDepth = expectedDsDepth(0.4)
  local floorNdc14 = math.floor((0.4 * 2 - 1) * 0x4000)
  local floorDepth = math.max(0, math.min(0xFFFFFF, (floorNdc14 + 0x3FFF) * 0x200))
  Assert.isTrue(floorDepth ~= truncDepth, "the fixture's floor/trunc candidates must differ to discriminate")

  local sample = stateDepthReadback(scope, -0.2)
  Assert.near(sample[2], truncDepth, 1, "negative NDC must use truncation toward zero, not floor")
  Assert.isTrue(math.abs(sample[2] - floorDepth) > 1, "the readback must not match the floor-based conversion")
end

-- The deprecated camera-far depth normalization is gone from the world MRT
-- shader: its uniform must not exist after the change, so sending it must
-- fail (the same presence/absence convention as this file's other shader
-- uniform tests).
function T.world_mrt_shader_has_no_depth_w_max_uniform(scope)
  local worldShader = scope:own(GxRenderer.new()).worldShader
  Assert.throws(function()
    worldShader:send("u_depthWMax", 400)
  end)
end

-- A 32-entry fog density table with a sharp transition at exactly one
-- density interval: entries 1..11 are 0, entries 12..32 are 64. The 34-entry
-- interpolation domain duplicates the endpoints, so any depth whose
-- (depth - offset) >> 2 has densityId <= 11 (all 131072-wide intervals from
-- 0 through 11) reads density 0, and any depth reaching densityId 12 reads
-- density 64 -- a boundary at exactly one quantized depth step.
local function stepDensityTable()
  local t = {}
  for i = 1, 32 do
    t[i] = i < 12 and 0 or 64
  end
  return t
end

-- The final pass's density lookup consumes the state G channel's DS Z value
-- directly, with no camera-far rescaling: the hand-computed DS Z depth for a
-- fragment at eye-space -0.2 (0x800600, from the perspective matrix's
-- windowZ and the signed conversion) sits at densityId 12 of a 0x1000-offset
-- step table -- density 64 -- while the retired linear-eye-depth proxy for
-- the same fragment (the old far-normalized dsWbufferDepth) is only a few
-- 0x200 quanta, which reads density 0. The fogged RGB (63 -> 31 at density
-- 64, unchanged at density 0) discriminates the two depth sources, and the
-- state G readback is asserted at the same boundary depth. DsFog.density is
-- the independent pure-Lua oracle for both expectations.
function T.fog_boundary_consumes_the_ds_z_depth_without_camera_far_rescaling(scope)
  local renderer = scope:own(GxRenderer.new())
  -- The quad's vertices sit at z = 0; the eye-space depth comes solely from
  -- the item's world transform below (z = -0.2), so the fragment lands at
  -- exactly eye-space -0.2 -- the depth the hand-derived expectations use.
  local mesh = scope:own(syntheticMesh({
    { -1, -1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 3, -1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 3, 3, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { -1, -1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 3, 3, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { -1, 3, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
  }))
  local item = opaqueFinalStateItem(mesh, 20, true)
  item.transform = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, -0.2, 1 }
  local camera = perspectiveCamera()
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })
  local runtime = emptyRuntime()
  runtime.fog = { enabled = true, color = 0, offset = 0x1000, slope = 0, alpha = 31, table = stepDensityTable() }

  local harness = compositeReadback(scope, renderer, viewport)
  render(renderer, runtime, camera, { { item } }, nil, viewport)
  harness.restore()
  love.graphics.setCanvas()

  local expectedDepth = expectedDsDepth(projectedWindowZ(-0.2))
  local expectedDensity = DsFog.density(expectedDepth, 0x1000, 0, stepDensityTable())
  local expectedRgb = DsFog.blend(63, 0, expectedDensity) / 63

  -- State G readback: the drawn fragment's green channel must be the DS Z
  -- value of the real projection, with the depth test confirming the mesh
  -- actually reached the state target.
  local state = renderer.renderState:newImageData()
  local sx, sy = statePixel(renderer, 320, 240)
  local sample = { state:getPixel(sx, sy) }
  local mirrored = { state:getPixel(sx, renderer.stateH - 1 - sy) }
  local depthSample = sample[1] < 0.5 and sample or mirrored
  Assert.near(depthSample[2], expectedDepth, 1, "the fragment's state G must be the DS Z depth of its real projection")

  -- Final pixel readback: fog density must follow the oracle at the DS Z
  -- depth.
  local final = harness.canvas:newImageData()
  local fx, fy = 320, math.min(479, math.floor(240 * 480 / viewport.worldViewport.height))
  local fSample = { final:getPixel(fx, fy) }
  local fMirror = { final:getPixel(fx, 479 - fy) }
  local finalSample = fSample[1] < 0.5 and fSample or fMirror
  Assert.near(finalSample[1], expectedRgb, 1 / 255, "the fogged RGB must follow DsFog at the DS Z depth")
  Assert.near(finalSample[2], expectedRgb, 1 / 255)
  Assert.near(finalSample[3], expectedRgb, 1 / 255)
end

-- ---------------------------------------------------------------------------
-- Exact translucent compositor scenarios cover the DS integer RGB6/alpha5
-- blend, max destination alpha, same-ID rejection, fog-gate AND,
-- last-translucent-ID state, and depth preservation. Every fixture drives the
-- real GxRenderer:draw at a 640x480 identity-camera viewport and reads back
-- the real sceneColor/renderState canvases.
--
-- Expected integers below are hand-derived from the compositor's equations,
-- never computed by calling production code:
--    rgb6    = floor(channel * 63 + 0.5)
--    alpha5  = floor(alpha  * 31 + 0.5)
--    dstA5==0            -> out = src (replace)
--    else w = srcA5 + 1  -> out = ((src*w) + (dst*(32-w))) >> 5
--    outA5  = max(srcA5, dstA5)
-- with state A = (id + 1)/64 (0 = none), B = destFogGate AND srcFogEnabled.

local ALPHA5_BYTE = {}
for a5 = 0, 31 do
  ALPHA5_BYTE[a5] = math.floor(a5 / 31 * 255 + 0.5)
end

-- The DS final alpha5 of a MODULATE fragment: texture alpha5 and polygon
-- alpha5 combine as floor(((t+1)*(p+1)-1)/32) (map.glsl's outputAlpha5; the
-- quantizer). Deriving the fixture's own alpha5 here keeps the
-- source byte and the resulting alpha5 in one independent place.
-- The DS integer translucent blend on one RGB6 channel.
local function dsBlend6(src6, dst6, srcA5)
  return math.floor((src6 * (srcA5 + 1) + dst6 * (32 - (srcA5 + 1))) / 32)
end

-- A fullscreen quad carrying one solid-color texel in front of the opaque
-- depth plane used by the compositor fixtures. Keeping the default away from
-- the camera's near plane makes the shared strict-less depth contract
-- observable instead of relying on coplanar depth behavior.
-- whose byte decodes to texture alpha5 `alpha5Byte`. The item is a translucent
-- MODULATE draw at polygon alpha 31, so the fragment's final alpha5 is exactly
-- the texture's alpha5 (floor(((t+1)*(31+1)-1)/32) == t) and its source RGB6
-- is the texture RGB6. `polygonId` defaults to 7; `fogEnabled` defaults to
-- false; `translucentDepthWrite` defaults to false (the ordinary HGSS field
-- shape). Returns the item; callers may override fields afterward.
local function translucentQuad(scope, alpha5Byte, r6, g6, b6, polygonId, fogEnabled, z)
  z = z or -1
  local mesh = scope:own(syntheticMesh({
    { -1, -1, z, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 3, -1, z, 1, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 3, 3, z, 1, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
    { -1, -1, z, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 3, 3, z, 1, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
    { -1, 3, z, 0, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
  }))
  local image = solidAlphaImage(
    scope,
    math.floor(r6 / 63 * 255 + 0.5),
    math.floor(g6 / 63 * 255 + 0.5),
    math.floor(b6 / 63 * 255 + 0.5),
    alpha5Byte
  )
  return {
    mesh = mesh,
    material = { alphaClass = "translucent", texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }, image = image },
    transform = IDENTITY,
    modelNormal = IDENTITY_NORMAL,
    alphaClass = "translucent",
    cullMode = "none",
    polygonAlpha = 1.0,
    polygonMode = "modulation",
    polygonId = polygonId or 7,
    translucentDepthWrite = false,
    depthEqual = false,
    lightMask = 0,
    alphaCutoff = 0.5 / 255,
    fogEnabled = fogEnabled == true,
    center = { 0.5, 0.5, 0 },
  }
end

local centerReadback

local function normalLitTranslucentQuad(scope)
  local mesh = scope:own(syntheticMesh({
    { -1, -1, -1, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 3, -1, -1, 1, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 3, 3, -1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 3 },
    { -1, -1, -1, 0, 0, 0, 0, 1, 1, 1, 1, 1, 3 },
    { 3, 3, -1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 3 },
    { -1, 3, -1, 0, 1, 0, 0, 1, 1, 1, 1, 1, 3 },
  }))
  return {
    mesh = mesh,
    material = {
      alphaClass = "translucent",
      texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
      image = solidAlphaImage(scope, 255, 255, 255, 255),
    },
    transform = IDENTITY,
    modelNormal = IDENTITY_NORMAL,
    alphaClass = "translucent",
    cullMode = "none",
    polygonAlpha = 0.5,
    polygonMode = "modulation",
    polygonId = 7,
    translucentDepthWrite = false,
    depthEqual = false,
    lightMask = 1,
    alphaCutoff = 0.5 / 255,
    fogEnabled = false,
    center = { 0.5, 0.5, -1 },
  }
end

local function litRuntimeForRenderer()
  local white = 31 + 31 * 32 + 31 * 1024
  local runtime = emptyRuntime()
  runtime.lighting = {
    records = {
      {
        startHalfSeconds = 0,
        lights = {
          { enabled = true, colorRgb555 = white, vectorFx12 = { 0, 0, -4096 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
          { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
        },
        diffuseRgb555 = white,
        ambientRgb555 = 0,
        specularRgb555 = 0,
        emissionRgb555 = 0,
      },
    },
  }
  return runtime
end

function T.approximate_translucent_normal_lighting_reaches_the_color_shader(scope)
  local renderer = scope:own(GxRenderer.new({ translucencyMode = GxRenderer.TRANSLUCENCY_APPROXIMATE }))
  local item = normalLitTranslucentQuad(scope)
  local result = centerReadback(scope, renderer, fixedCamera(), litRuntimeForRenderer(), { { item } })
  Assert.isTrue(result.color[1] > 0.1, "approximate translucent NORMAL lighting is visible")
end

function T.approximate_translucent_draw_preserves_non_black_world_color(scope)
  local clearColor = { 0.2, 0.7, 0.9, 1 }
  local renderer = scope:own(GxRenderer.new({
    clearColor = clearColor,
    translucencyMode = GxRenderer.TRANSLUCENCY_APPROXIMATE,
  }))
  local item = normalLitTranslucentQuad(scope)
  local result = centerReadback(scope, renderer, fixedCamera(), litRuntimeForRenderer(), { { item } })

  Assert.isTrue(result.color[1] > clearColor[1], "translucent color must compose over the non-black world color")
  Assert.isTrue(result.color[2] > clearColor[2], "translucent color must compose over the non-black world color")
  Assert.isTrue(result.color[3] > clearColor[3], "translucent color must compose over the non-black world color")
end

function T.exact_translucent_normal_lighting_reaches_source_color_rasterization(scope)
  local renderer = scope:own(GxRenderer.new({ translucencyMode = GxRenderer.TRANSLUCENCY_EXACT }))
  local item = normalLitTranslucentQuad(scope)
  local result = centerReadback(scope, renderer, fixedCamera(), litRuntimeForRenderer(), { { item } })
  Assert.isTrue(result.color[1] > 0.1, "exact translucent NORMAL lighting is visible")
end

local function depthQuadMesh(scope, z)
  return scope:own(syntheticMesh({
    { -1, -1, z, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 3, -1, z, 1, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 3, 3, z, 1, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
    { -1, -1, z, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 3, 3, z, 1, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
    { -1, 3, z, 0, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
  }))
end

local function depthTranslucentQuad(scope, z, alpha5Byte, r6, g6, b6, polygonId, fogEnabled)
  return {
    mesh = depthQuadMesh(scope, z),
    material = {
      alphaClass = "translucent",
      texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
      image = solidAlphaImage(
        scope,
        math.floor(r6 / 63 * 255 + 0.5),
        math.floor(g6 / 63 * 255 + 0.5),
        math.floor(b6 / 63 * 255 + 0.5),
        alpha5Byte
      ),
    },
    transform = IDENTITY,
    modelNormal = IDENTITY_NORMAL,
    alphaClass = "translucent",
    cullMode = "none",
    polygonAlpha = 1.0,
    polygonMode = "modulation",
    polygonId = polygonId or 7,
    translucentDepthWrite = false,
    depthEqual = false,
    lightMask = 0,
    alphaCutoff = 0.5 / 255,
    fogEnabled = fogEnabled == true,
    center = { 0.5, 0.5, 0 },
  }
end

local function depthOpaqueQuad(scope, z, r, g, b, polygonId, fogEnabled)
  local item = opaqueFinalStateItem(depthQuadMesh(scope, z), polygonId, fogEnabled)
  item.material.image = solidAlphaImage(scope, r, g, b, 255)
  return item
end

-- Read one pixel from a sceneColor readback, resolving the driver's Y-mirror
-- by taking the brighter (non-black-clear) of the pixel and its mirror.
local function scenePixel(renderer, colorImg, x, y)
  local a, b = { colorImg:getPixel(x, y) }, { colorImg:getPixel(x, renderer.colorH - 1 - y) }
  local function sum(p)
    return p[1] + p[2] + p[3]
  end
  return sum(a) >= sum(b) and a or b
end

-- Read one pixel from a renderState readback, resolving the driver's Y-mirror
-- while preserving rear-plane pixels when neither orientation contains draw state.
-- Read one pixel from a renderState readback: the sample whose red channel is
-- not the rear-plane clear (id 63 -> 1.0) is the drawn pixel; when neither
-- candidate is drawn state, the sample with the lower red channel (the
-- clear's id-63 red == 1.0) is returned so callers can still detect "no state".
local function sceneScale(color)
  return color[1] > 1 and 255 or 1
end

-- Draw one parts list and return { color = {r,g,b,a}, state = {r,g,b,a} } at
-- the 640x480 canvas center through the real GxRenderer. `runtime` may carry
-- edge/fog overrides.
centerReadback = function(_, renderer, camera, runtime, parts)
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })
  render(renderer, runtime, camera, parts, nil, viewport)
  local colorImg = renderer.sceneColor:newImageData()
  local stateImg = renderer.renderState:newImageData()
  local color = scenePixel(renderer, colorImg, 320, 240)
  local sx, sy = statePixel(renderer, 320, 240)
  local state = statePixelAt(renderer, stateImg, sx, sy)
  return { color = color, state = state }
end

-- The fixture-specific hard-coded expected integer results for the DS-weight
-- scenario. The destination is a fully opaque MODULATE quad (alpha byte 255,
-- so the framebuffer destination is exactly its texture color) carrying the
-- RGB6 values below; the source is a translucent MODULATE quad. Both quads
-- are white-vertexed, so each channel's framebuffer RGB6 is the texture
-- byte's expand5to6 decode: byte b -> texture5 = floor(b/255*31+0.5) ->
-- rgb6 = 0 if 0 else 2*texture5+1. The expected DS blend is then
-- ((src*(srcA+1)) + (dst*(31-srcA))) >> 5 with those actual framebuffer
-- values.
local function byteToRgb6(byte)
  local c5 = math.floor(byte / 255 * 31 + 0.5)
  if c5 <= 0 then
    return 0
  end
  return c5 * 2 + 1
end
local DS_BLEND_DST6 = { 52, 41, 28 }
local DS_BLEND_DST_A5 = 31
local DS_BLEND_SRC6 = { 13, 26, 39 }
local DS_BLEND_SRC_A5 = 10
-- The actual framebuffer RGB6 after MODULATE's 5->6 expansion.
local DS_BLEND_DST6_ACTUAL = {
  byteToRgb6(math.floor(52 / 63 * 255 + 0.5)),
  byteToRgb6(math.floor(41 / 63 * 255 + 0.5)),
  byteToRgb6(math.floor(28 / 63 * 255 + 0.5)),
}
local DS_BLEND_SRC6_ACTUAL = {
  byteToRgb6(math.floor(13 / 63 * 255 + 0.5)),
  byteToRgb6(math.floor(26 / 63 * 255 + 0.5)),
  byteToRgb6(math.floor(39 / 63 * 255 + 0.5)),
}
local DS_BLEND_EXPECTED6 = {
  dsBlend6(DS_BLEND_SRC6_ACTUAL[1], DS_BLEND_DST6_ACTUAL[1], DS_BLEND_SRC_A5),
  dsBlend6(DS_BLEND_SRC6_ACTUAL[2], DS_BLEND_DST6_ACTUAL[2], DS_BLEND_SRC_A5),
  dsBlend6(DS_BLEND_SRC6_ACTUAL[3], DS_BLEND_DST6_ACTUAL[3], DS_BLEND_SRC_A5),
}
local DS_BLEND_HOST6 = {
  math.floor(
    DS_BLEND_DST6_ACTUAL[1] + (DS_BLEND_SRC6_ACTUAL[1] - DS_BLEND_DST6_ACTUAL[1]) * DS_BLEND_SRC_A5 / 31 + 0.5
  ),
  math.floor(
    DS_BLEND_DST6_ACTUAL[2] + (DS_BLEND_SRC6_ACTUAL[2] - DS_BLEND_DST6_ACTUAL[2]) * DS_BLEND_SRC_A5 / 31 + 0.5
  ),
  math.floor(
    DS_BLEND_DST6_ACTUAL[3] + (DS_BLEND_SRC6_ACTUAL[3] - DS_BLEND_DST6_ACTUAL[3]) * DS_BLEND_SRC_A5 / 31 + 0.5
  ),
}

-- The exact DS RGB6 weight scenario: accepted translucency uses the DS
-- integer weights
-- ((src*(srcA+1) + dst*(32-srcA-1)) >> 5), not the host float srcAlpha. The
-- destination is an opaque MODULATE quad with a known mid-range RGB6 and
-- alpha5; the single translucent source carries a source alpha5 whose host
-- `srcAlpha = a5/31` value produces a distinguishable result. Every channel
-- equals the hand-computed integer above.
function T.exact_ds_rgb_weight(scope)
  local function opaqueItem6(mesh, r6, g6, b6, alphaByte, id, fogEnabled)
    local image = solidAlphaImage(
      scope,
      math.floor(r6 / 63 * 255 + 0.5),
      math.floor(g6 / 63 * 255 + 0.5),
      math.floor(b6 / 63 * 255 + 0.5),
      alphaByte
    )
    local item = opaqueFinalStateItem(mesh, id, fogEnabled)
    item.material.image = image
    return item
  end

  local opaqueMesh = scope:own(syntheticMesh({
    { -1, -1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 3, -1, 0, 1, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 3, 3, 0, 1, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
    { -1, -1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 3, 3, 0, 1, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
    { -1, 3, 0, 0, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
  }))
  local renderer = scope:own(exactRenderer())
  -- Self-check: the fixture must actually discriminate the DS integer blend
  -- from the host float blend on at least one channel, or it can never be red.
  local discriminating = false
  for i = 1, 3 do
    if DS_BLEND_EXPECTED6[i] ~= DS_BLEND_HOST6[i] then
      discriminating = true
    end
  end
  Assert.isTrue(discriminating, "fixture must discriminate DS integer from host float blending")

  local opaque = opaqueItem6(
    opaqueMesh,
    DS_BLEND_DST6[1],
    DS_BLEND_DST6[2],
    DS_BLEND_DST6[3],
    ALPHA5_BYTE[DS_BLEND_DST_A5],
    20,
    true
  )
  local translucent =
    translucentQuad(scope, ALPHA5_BYTE[DS_BLEND_SRC_A5], DS_BLEND_SRC6[1], DS_BLEND_SRC6[2], DS_BLEND_SRC6[3])
  local read = centerReadback(scope, renderer, fixedCamera(), emptyRuntime(), { { opaque, translucent } })
  local scale = sceneScale(read.color)
  local function assert6(channel, expected6, label)
    Assert.near(
      read.color[channel],
      expected6 / 63 * scale,
      0.5 * scale / 63,
      label
        .. " must be the DS integer blend ("
        .. expected6
        .. "/63), not the host float blend ("
        .. DS_BLEND_HOST6[channel]
        .. "/63)"
    )
  end
  assert6(1, DS_BLEND_EXPECTED6[1], "red channel")
  assert6(2, DS_BLEND_EXPECTED6[2], "green channel")
  assert6(3, DS_BLEND_EXPECTED6[3], "blue channel")
end

-- The max-destination-alpha scenario: the destination alpha5 is the max of
-- source and destination
-- alpha5 -- never a source-over accumulation. The destination alpha5 is
-- established by a first accepted translucent fragment (a semi-transparent
-- draw over the alpha-1.0 clear leaves the framebuffer at alpha 1, so the
-- opaque path cannot produce a sub-31 destination alpha); the second
-- translucent fragment (different polygon ID, so it is not rejected) must
-- leave the combined alpha at max. Setup: (dstA5 high 30,
-- srcA5 low 1) and (dstA5 low 1, srcA5 high 30); expected output alpha5 = max
-- in both cases (30).
function T.destination_alpha_is_max(scope)
  -- The color canvas clears to alpha 0 (not the default opaque 1.0) so the
  -- first translucent fragment's destination alpha5 is 0 and it REPLACES the
  -- destination (rule 2), establishing the fixture's known destination
  -- alpha5; the second fragment then composites with max.
  local renderer = scope:own(exactRenderer({ clearColor = { 0, 0, 0, 0 } }))
  local function readAlpha(targetRenderer, dstA5, srcA5)
    local first = translucentQuad(scope, ALPHA5_BYTE[dstA5], 51, 17, 17)
    first.polygonId = 7
    local second = translucentQuad(scope, ALPHA5_BYTE[srcA5], 17, 51, 17)
    second.polygonId = 9
    local read = centerReadback(scope, targetRenderer, fixedCamera(), emptyRuntime(), { { first, second } })
    return read.color[4]
  end

  -- Case 1: destination alpha5 high (30), source alpha5 low (1) -> max 30.
  local highDst = readAlpha(renderer, 30, 1)
  -- Case 2: destination alpha5 low (1), source alpha5 high (30) -> max 30.
  local lowDst = readAlpha(renderer, 1, 30)

  local scale = highDst > 1 and 255 or 1
  Assert.near(highDst, 30 / 31 * scale, 0.5 * scale / 31, "high destination alpha5 must win: output alpha5 = 30")
  Assert.near(lowDst, 30 / 31 * scale, 0.5 * scale / 31, "high source alpha5 must win: output alpha5 = 30")
  Assert.isTrue(math.abs(highDst - lowDst) <= 0.5 * scale / 31, "both orderings must reach the same max alpha5 (30)")
end

-- Shared fixture for the same-ID / different-ID rejection scenarios: an
-- opaque mid-gray background quad
-- (id 20) plus two overlapping fullscreen translucent quads with identical
-- white UVs. RenderQueue sorts blended entries back-to-front by view-space Z
-- then submission position; the two translucent items live in one parts list
-- with the same center Z (0), so submission order is their deterministic
-- order (first item drawn last / nearest). `ids` is {idFirst, idSecond};
-- returns the center color/state readback. All RGB6 values are ODD so the
-- MODULATE 5->6 expansion (0 -> 0, n -> 2n+1) reproduces them exactly in the
-- framebuffer (an even value like 16 would land on 17).
local function twoTranslucentOverOpaque(scope, renderer, ids, firstRgb6, secondRgb6)
  local opaqueMesh = scope:own(syntheticMesh({
    { -1, -1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 3, -1, 0, 1, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 3, 3, 0, 1, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
    { -1, -1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 3, 3, 0, 1, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
    { -1, 3, 0, 0, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
  }))
  -- Byte 123 -> texture5 15 -> RGB6 31 (an exactly-representable odd value).
  local opaqueImage = solidAlphaImage(scope, 123, 123, 123, 255)
  local opaque = opaqueFinalStateItem(opaqueMesh, 20, true)
  opaque.material.image = opaqueImage

  local first = translucentQuad(scope, ALPHA5_BYTE[8], firstRgb6[1], firstRgb6[2], firstRgb6[3])
  first.polygonId = ids[1]
  local second = translucentQuad(scope, ALPHA5_BYTE[8], secondRgb6[1], secondRgb6[2], secondRgb6[3])
  second.polygonId = ids[2]

  return centerReadback(scope, renderer, fixedCamera(), emptyRuntime(), { { opaque, first, second } })
end

-- The same-ID rejection scenario: two overlapping translucent draws with the
-- SAME polygon ID must
-- blend only once -- the first accepted fragment -- and the state A channel
-- must encode that ID. Expected color: opaque id-20 (RGB6 31,31,31) blended
-- once with the first (red 51,17,17 at alpha5 8) = RGB6 (21,25,25); state A
-- = (7+1)/64.
function T.same_translucent_id_rejects_the_second_blend(scope)
  local renderer = scope:own(exactRenderer())
  local first6, second6 = { 51, 17, 17 }, { 17, 51, 17 }
  local read = twoTranslucentOverOpaque(scope, renderer, { 7, 7 }, first6, second6)

  local expected6 = {
    dsBlend6(first6[1], 31, 8),
    dsBlend6(first6[2], 31, 8),
    dsBlend6(first6[3], 31, 8),
  }
  local scale = sceneScale(read.color)
  Assert.near(
    read.color[1],
    expected6[1] / 63 * scale,
    0.5 * scale / 63,
    "same-ID: red must be the background blended once (first fragment only)"
  )
  Assert.near(
    read.color[2],
    expected6[2] / 63 * scale,
    0.5 * scale / 63,
    "same-ID: green must be the background blended once"
  )
  Assert.near(
    read.color[3],
    expected6[3] / 63 * scale,
    0.5 * scale / 63,
    "same-ID: blue must be the background blended once"
  )
  Assert.isTrue(
    math.abs(read.color[2] - read.color[3]) <= 0.5 * scale / 63,
    "the second (green-tinted) fragment must not blend: the result must show no green tint"
  )

  -- State A: the accepted source polygon ID, encoded (id + 1)/64.
  Assert.near(read.state[4], 8 / 64, 1 / 255, "state A must encode the accepted first polygon id 7 as (7+1)/64")
end

-- The different-ID scenario: the self-rejection is keyed to ID equality, not
-- a blanket
-- one-translucent-fragment rule: with DIFFERENT polygon IDs both fragments
-- blend, in the deterministic order (second fragment drawn last), and state A
-- encodes the second accepted ID. Expected color: bg blended with first
-- (RGB6 51,17,17 at a5 8) then with second (RGB6 17,51,17 at a5 8); state A
-- = (9+1)/64.
function T.different_translucent_ids_both_blend(scope)
  local renderer = scope:own(exactRenderer())
  local first6, second6 = { 51, 17, 17 }, { 17, 51, 17 }
  local read = twoTranslucentOverOpaque(scope, renderer, { 7, 9 }, first6, second6)

  local step1 = {
    dsBlend6(first6[1], 31, 8),
    dsBlend6(first6[2], 31, 8),
    dsBlend6(first6[3], 31, 8),
  }
  local step2 = {
    dsBlend6(second6[1], step1[1], 8),
    dsBlend6(second6[2], step1[2], 8),
    dsBlend6(second6[3], step1[3], 8),
  }
  local scale = sceneScale(read.color)
  Assert.near(
    read.color[1],
    step2[1] / 63 * scale,
    0.5 * scale / 63,
    "different-ID: red must show both blends in order"
  )
  Assert.near(
    read.color[2],
    step2[2] / 63 * scale,
    0.5 * scale / 63,
    "different-ID: green must show both blends in order"
  )
  Assert.near(
    read.color[3],
    step2[3] / 63 * scale,
    0.5 * scale / 63,
    "different-ID: blue must show both blends in order"
  )

  Assert.near(read.state[4], 10 / 64, 1 / 255, "state A must encode the second accepted polygon id 9 as (9+1)/64")
end

-- The non-depth-writing scenario: ordinary (depth-write false) translucency
-- changes color/alpha and
-- the translucent/fog attributes without replacing the opaque edge ID/depth
-- ownership. Setup: opaque destination with known ID/depth/fog gate true,
-- translucent source with a different ID, depth-write false, fog false.
-- Expected: R/G stay the opaque values, B = dest AND src fog = 0, A encodes
-- the source translucent ID. Repeat with the source fog true (B = 1).
function T.non_depth_writing_preserves_opaque_id_and_depth_and_ands_fog(scope)
  local function drawCase(renderer, srcFogEnabled)
    local opaqueMesh = scope:own(syntheticMesh({
      { -1, -1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
      { 3, -1, 0, 1, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
      { 3, 3, 0, 1, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
      { -1, -1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
      { 3, 3, 0, 1, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
      { -1, 3, 0, 0, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
    }))
    local opaqueImage = solidAlphaImage(scope, 128, 128, 128, 255)
    local opaque = opaqueFinalStateItem(opaqueMesh, 20, true)
    opaque.material.image = opaqueImage
    local translucent = translucentQuad(scope, ALPHA5_BYTE[8], 51, 16, 16)
    translucent.fogEnabled = srcFogEnabled
    return centerReadback(scope, renderer, fixedCamera(), emptyRuntime(), { { opaque, translucent } })
  end

  local renderer = scope:own(exactRenderer())
  local fogFalse = drawCase(renderer, false)
  local fogTrue = drawCase(renderer, true)

  Assert.near(
    fogFalse.state[1],
    20 / 63,
    1 / 255,
    string.format(
      "the opaque polygon id must survive a non-depth-writing translucent draw (got %.6f)",
      fogFalse.state[1]
    )
  )
  Assert.near(
    fogTrue.state[1],
    20 / 63,
    1 / 255,
    string.format(
      "the opaque polygon id must survive in both fog cases (got false %.6f/%.6f/%.6f/%.6f, true %.6f/%.6f/%.6f/%.6f)",
      fogFalse.state[1],
      fogFalse.state[2],
      fogFalse.state[3],
      fogFalse.state[4],
      fogTrue.state[1],
      fogTrue.state[2],
      fogTrue.state[3],
      fogTrue.state[4]
    )
  )
  Assert.near(fogFalse.state[3], 0.0, 1 / 255, "B must be dest fog (1) AND src fog (0) = 0")
  Assert.near(fogTrue.state[3], 1.0, 1 / 255, "B must be dest fog (1) AND src fog (1) = 1")
  Assert.near(fogFalse.state[4], 8 / 64, 1 / 255, "A must encode the source translucent id 7 in the fog-false case")
  Assert.near(fogTrue.state[4], 8 / 64, 1 / 255, "A must encode the source translucent id 7 in the fog-true case")
  Assert.near(fogFalse.state[2], fogTrue.state[2], 1, "the DS Z depth must be preserved identically in both cases")
end

function T.final_resolve_uses_the_state_paired_with_an_odd_composite_result(scope)
  local renderer = scope:own(exactRenderer())
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })
  local runtime = emptyRuntime()
  local fogTable = {}
  for i = 1, 32 do
    fogTable[i] = 64
  end
  runtime.fog = { enabled = true, color = 0, offset = 0x4000, slope = 0, alpha = 31, table = fogTable }

  local opaque = opaqueFinalStateItem(depthQuadMesh(scope, 0), 20, true)
  opaque.material.image = solidAlphaImage(scope, 255, 255, 255, 255)
  local translucent = translucentQuad(scope, ALPHA5_BYTE[15], 63, 63, 63, 7, true)
  translucent.fogEnabled = false
  translucent.center = { 0.5, 0.5, 0 }

  local harness = compositeReadback(scope, renderer, viewport)
  render(renderer, runtime, fixedCamera(), { { opaque, translucent } }, nil, viewport)
  local scene = scenePixel(renderer, renderer.sceneColor:newImageData(), 320, 240)
  local sx, sy = statePixel(renderer, 320, 240)
  local state = statePixelAt(renderer, renderer.renderState:newImageData(), sx, sy)
  harness.restore()
  love.graphics.setCanvas()

  local final = scenePixel(renderer, harness.canvas:newImageData(), 320, 240)
  local scale = sceneScale(scene)
  local scene6 = math.floor(scene[1] / scale * 63 + 0.5)
  local density = DsFog.density(state[2], runtime.fog.offset, runtime.fog.slope, fogTable)
  local fogged = DsFog.blend(scene6, 0, density) / 63 * scale

  Assert.near(state[3], 0, 1 / 255, "accepted translucency ANDs the destination and source fog gates")
  Assert.near(final[1], scene[1], 1 / 255 * scale, "final resolve uses the active post-composite fog state")
  Assert.near(final[2], scene[2], 1 / 255 * scale)
  Assert.near(final[3], scene[3], 1 / 255 * scale)
  Assert.isTrue(
    math.abs(fogged - scene[1]) > 0.1 * scale,
    "the selected fog density would visibly change the scene if stale state enabled fog"
  )
end

function T.translucent_geometry_behind_opaque_geometry_is_rejected_by_shared_depth(scope)
  local renderer = scope:own(exactRenderer())
  local camera = perspectiveCamera()
  local opaque = depthOpaqueQuad(scope, -0.2, 0, 128, 255, 20, true)
  local translucent = depthTranslucentQuad(scope, -0.5, ALPHA5_BYTE[15], 255, 0, 0, 7, true)

  local opaqueOnly = centerReadback(scope, renderer, camera, emptyRuntime(), { { opaque } })
  local withFarTranslucency = centerReadback(scope, renderer, camera, emptyRuntime(), { { opaque, translucent } })

  for channel = 1, 3 do
    Assert.near(
      withFarTranslucency.color[channel],
      opaqueOnly.color[channel],
      1 / 255,
      "farther translucent geometry must not contribute to the opaque center color"
    )
  end
  Assert.near(withFarTranslucency.state[4], 0, 1 / 255, "rejected translucency must not record a translucent ID")
  Assert.near(
    withFarTranslucency.state[2],
    opaqueOnly.state[2],
    1,
    "rejected translucency must not change the opaque DS depth"
  )
end

-- Mixed-alpha compositor contract: a mixed
-- material's partial-alpha texels must go through the compositor (they
-- therefore become translucent state: state A records the source ID) while
-- its fully-opaque texels keep the opaque state path (state A stays 0 -- no
-- translucent overlay -- and the opaque ID/depth/fog-gate are stamped). This
-- extends the existing mixed_modulate_splits_opaque_and_translucent test
-- without weakening it: the partial texels' new state-A encoding is the
-- compositor
-- delta, asserted per column.
function T.mixed_partial_texels_use_the_compositor_and_opaque_texels_do_not(scope)
  local renderer = scope:own(exactRenderer())
  local texture = mixedAlphaTexture(scope)
  local item = mixedItem(unitSquareQuad(scope, 1, 1, 1), texture)
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })

  render(renderer, emptyRuntime(), fixedCamera(), { { item } }, nil, viewport)

  local colorImg = renderer.sceneColor:newImageData()
  local stateImg = renderer.renderState:newImageData()
  local alphas5 = { 0, 1, 15, 30, 31 }

  for i, a5 in ipairs(alphas5) do
    local u = (i - 0.5) / 5
    local cx, cy = clipPixel(renderer.colorW, renderer.colorH, u, 0.5)
    local color = interiorSample(colorImg, renderer.colorH, cx, cy)
    local colorScale = color[1] > 1 and 255 or 1

    local sx, sy = statePixel(renderer, cx, cy)
    local mirrorX, mirrorY = statePixel(renderer, cx, renderer.colorH - 1 - cy)
    local a = { stateImg:getPixel(sx, sy) }
    local b = { stateImg:getPixel(mirrorX, mirrorY) }
    -- The partial texel columns carry the rear-plane opaque R (1.0 -- a
    -- translucent source never replaces it), so the R channel cannot
    -- discriminate the drawn sample from its Y-mirror; prefer the sample that
    -- is not the rear plane in R or A (the opaque column stamps R, the
    -- partial columns stamp A). If both are rear-plane (a fully transparent
    -- column), either is fine.
    local function isRear(p)
      return p[1] >= 0.99 and p[4] <= 0.0005
    end
    local stateValue
    if not isRear(a) then
      stateValue = a
    elseif not isRear(b) then
      stateValue = b
    else
      stateValue = a
    end
    local isOpaqueColumn = a5 == 31

    if isOpaqueColumn then
      -- Opaque texel: opaque state path only -- the existing contract.
      Assert.near(color[1], 1.0 * colorScale, 0.08 * colorScale, "alpha5=31 texel stays fully opaque")
      Assert.isTrue(stateValue[1] < 0.99, "alpha5=31 texel stamps opaque state (id " .. item.polygonId .. ")")
      Assert.near(stateValue[4], 0.0, 1 / 255, "an opaque texel's state A must stay 0 (no translucent overlay)")
    elseif a5 == 0 then
      -- Fully transparent texel: discarded by the translucent predicate --
      -- no color and no state A (it never reaches the compositor).
      Assert.isTrue(color[1] <= 0.05 * colorScale, "alpha5=0 texel discards (black clear)")
      Assert.near(stateValue[4], 0.0, 1 / 255, "a discarded texel's state A stays 0 (never accepted)")
    else
      -- Partial texel: compositor path -- state A must record this source
      -- ID, exactly like any accepted translucent source.
      Assert.near(
        stateValue[4],
        (item.polygonId + 1) / 64,
        1 / 255,
        "a partial-alpha mixed texel must record its translucent id in state A (a5=" .. a5 .. ")"
      )
    end
  end
end

-- Final-pass ordering: fog must apply to each candidate before the 50% mix.
-- The center is edge-marked (different id and strictly nearer depth) with known
-- scene and edge RGB6 values, a fog color and alpha, and a constant density
-- chosen so integer fog truncation makes fog-before-AA differ from AA-before-fog.
function T.final_pass_fogs_candidates_before_mixing(scope)
  local scene6 = 19
  local edge6 = 49
  local fog6 = 29 -- 14 expanded (2*14+1)
  local fogC5 = 14
  local density = 64
  local sceneNorm = scene6 / 63
  local edgeNorm = edge6 / 63
  local fogPacked = fogC5 + fogC5 * 32 + fogC5 * 1024 -- 14798
  local sceneAlpha = 1.0
  local fogAlpha = 0

  local Sf = DsFog.blend(scene6, fog6, density) -- 24
  local Ef = DsFog.blend(edge6, fog6, density) -- 39
  local mixed6 = math.floor((scene6 + edge6) / 2 + 0.5) -- 34
  local wrong6 = DsFog.blend(mixed6, fog6, density) -- 31
  local correctMix6 = (Sf + Ef) / 2 -- 31.5
  local correctAlpha5 = DsFog.blend(31, fogAlpha, density) -- 15

  local edgeColors = {}
  for i = 1, 8 do
    edgeColors[i] = { 0, 0, 0 }
  end
  edgeColors[1] = { edgeNorm, edgeNorm, edgeNorm }

  local out = runFinalPass(scope, {
    { id = 10, depth = 1000, fogGate = 0, scene = { sceneNorm, sceneNorm, sceneNorm, sceneAlpha } },
    { id = 0, depth = 500, fogGate = 1, scene = { sceneNorm, sceneNorm, sceneNorm, sceneAlpha } },
    { id = 0, depth = 500, fogGate = 1, scene = { sceneNorm, sceneNorm, sceneNorm, sceneAlpha } },
  }, {
    enabled = true,
    color = fogPacked,
    offsetRaw = 0,
    shift = 0,
    table32 = constantDensityTable(density),
    alpha = fogAlpha,
  }, edgeColors, true)

  local rgbScale = out[1] > 1 and 255 or 1
  local alphaScale = out[4] > 1 and 255 or 1
  local correctNorm = correctMix6 / 63
  local wrongNorm = wrong6 / 63
  Assert.near(
    out[1],
    correctNorm * rgbScale,
    1.2 / 255 * rgbScale,
    "fog must be applied to each candidate before mixing: red"
  )
  Assert.near(
    out[2],
    correctNorm * rgbScale,
    1.2 / 255 * rgbScale,
    "fog must be applied to each candidate before mixing: green"
  )
  Assert.near(
    out[3],
    correctNorm * rgbScale,
    1.2 / 255 * rgbScale,
    "fog must be applied to each candidate before mixing: blue"
  )
  Assert.isTrue(
    math.abs(out[1] - wrongNorm * rgbScale) > 1.5 / 255 * rgbScale,
    "result must differ from AA-before-fog (integer truncation discriminates)"
  )
  Assert.near(out[4], correctAlpha5 / 31 * alphaScale, 1.5 / 255 * alphaScale, "fog alpha is applied before AA")
end

-- Disabled-path identities: fog disabled, edge absent, and AA toggles must
-- compose without side effects. Table-driven direct final-pass fixtures.
function T.final_pass_disabled_paths_preserve_identities(scope)
  local function customEdgeColors(edgeNorm)
    local c = {}
    for i = 1, 8 do
      c[i] = { 0, 0, 0 }
    end
    c[1] = { edgeNorm, edgeNorm, edgeNorm }
    return c
  end

  local scene6 = 19
  local edge6 = 49
  local fog6 = 29
  local fogC5 = 14
  local density = 64
  local sceneNorm = scene6 / 63
  local edgeNorm = edge6 / 63
  local fogPacked = fogC5 + fogC5 * 32 + fogC5 * 1024
  local Sf = DsFog.blend(scene6, fog6, density)
  local Ef = DsFog.blend(edge6, fog6, density)
  local sceneFoggedNorm = Sf / 63
  local edgeFoggedNorm = Ef / 63
  local mixNoFogNorm = (sceneNorm + edgeNorm) / 2
  local mixFoggedNorm = (Sf + Ef) / 2 / 63

  -- Fog disabled + edge marked + AA off => edge candidate (no fog)
  do
    local out = runFinalPass(scope, {
      { id = 10, depth = 1000, fogGate = 0, scene = { sceneNorm, sceneNorm, sceneNorm, 1 } },
      { id = 0, depth = 500, fogGate = 1, scene = { sceneNorm, sceneNorm, sceneNorm, 1 } },
      { id = 0, depth = 500, fogGate = 1, scene = { sceneNorm, sceneNorm, sceneNorm, 1 } },
    }, {
      enabled = false,
      color = fogPacked,
      offsetRaw = 0,
      shift = 0,
      table32 = constantDensityTable(density),
      alpha = 31,
    }, customEdgeColors(edgeNorm), false)
    local scale = out[1] > 1 and 255 or 1
    Assert.near(
      out[1],
      edgeNorm * scale,
      1 / 255 * scale,
      "fog disabled + edge marked + AA off: fogged edge equals edge candidate: red"
    )
    Assert.near(
      out[2],
      edgeNorm * scale,
      1 / 255 * scale,
      "fog disabled + edge marked + AA off: fogged edge equals edge candidate: green"
    )
  end

  -- Fog disabled + edge marked + AA on => 50/50 mix without fog
  do
    local out = runFinalPass(scope, {
      { id = 10, depth = 1000, fogGate = 0, scene = { sceneNorm, sceneNorm, sceneNorm, 1 } },
      { id = 0, depth = 500, fogGate = 1, scene = { sceneNorm, sceneNorm, sceneNorm, 1 } },
      { id = 0, depth = 500, fogGate = 1, scene = { sceneNorm, sceneNorm, sceneNorm, 1 } },
    }, {
      enabled = false,
      color = fogPacked,
      offsetRaw = 0,
      shift = 0,
      table32 = constantDensityTable(density),
      alpha = 31,
    }, customEdgeColors(edgeNorm), true)
    local scale = out[1] > 1 and 255 or 1
    Assert.near(
      out[1],
      mixNoFogNorm * scale,
      1 / 255 * scale,
      "fog disabled + edge marked + AA on: 50/50 mix without fog: red"
    )
    Assert.near(
      out[4],
      1 * (out[4] > 1 and 255 or 1),
      1 / 255 * (out[4] > 1 and 255 or 1),
      "fog disabled preserves alpha"
    )
  end

  -- Fog enabled + no edge + AA off => fogged scene
  do
    local outOff = runFinalPass(scope, {
      { id = 0, depth = 500, fogGate = 1, scene = { sceneNorm, sceneNorm, sceneNorm, 1 } },
      { id = 0, depth = 500, fogGate = 1, scene = { sceneNorm, sceneNorm, sceneNorm, 1 } },
      { id = 0, depth = 500, fogGate = 1, scene = { sceneNorm, sceneNorm, sceneNorm, 1 } },
    }, {
      enabled = true,
      color = fogPacked,
      offsetRaw = 0,
      shift = 0,
      table32 = constantDensityTable(density),
      alpha = 31,
    }, customEdgeColors(edgeNorm), false)
    local outOn = runFinalPass(scope, {
      { id = 0, depth = 500, fogGate = 1, scene = { sceneNorm, sceneNorm, sceneNorm, 1 } },
      { id = 0, depth = 500, fogGate = 1, scene = { sceneNorm, sceneNorm, sceneNorm, 1 } },
      { id = 0, depth = 500, fogGate = 1, scene = { sceneNorm, sceneNorm, sceneNorm, 1 } },
    }, {
      enabled = true,
      color = fogPacked,
      offsetRaw = 0,
      shift = 0,
      table32 = constantDensityTable(density),
      alpha = 31,
    }, customEdgeColors(edgeNorm), true)
    local scaleOff = outOff[1] > 1 and 255 or 1
    local scaleOn = outOn[1] > 1 and 255 or 1
    Assert.near(
      outOff[1],
      sceneFoggedNorm * scaleOff,
      1 / 255 * scaleOff,
      "fog enabled + no edge: fogged scene regardless of AA off: red"
    )
    Assert.near(
      outOn[1],
      sceneFoggedNorm * scaleOn,
      1 / 255 * scaleOn,
      "fog enabled + no edge: AA has no effect when no edge: red"
    )
    Assert.isTrue(math.abs(outOff[1] - outOn[1]) <= 1 / 255 * scaleOff, "edge absent => AA has no effect")
  end

  -- Fog disabled + no edge => scene unchanged
  do
    local out = runFinalPass(scope, {
      { id = 0, depth = 500, fogGate = 0, scene = { sceneNorm, sceneNorm, sceneNorm, 1 } },
      { id = 0, depth = 500, fogGate = 0, scene = { sceneNorm, sceneNorm, sceneNorm, 1 } },
      { id = 0, depth = 500, fogGate = 0, scene = { sceneNorm, sceneNorm, sceneNorm, 1 } },
    }, {
      enabled = false,
      color = fogPacked,
      offsetRaw = 0,
      shift = 0,
      table32 = constantDensityTable(density),
      alpha = 31,
    }, customEdgeColors(edgeNorm), true)
    local scale = out[1] > 1 and 255 or 1
    Assert.near(out[1], sceneNorm * scale, 1 / 255 * scale, "fog disabled + no edge: scene unchanged: red")
  end

  -- Fog enabled + edge marked + AA off => fogged edge (not fogged scene)
  do
    local out = runFinalPass(scope, {
      { id = 10, depth = 1000, fogGate = 0, scene = { sceneNorm, sceneNorm, sceneNorm, 1 } },
      { id = 0, depth = 500, fogGate = 1, scene = { sceneNorm, sceneNorm, sceneNorm, 1 } },
      { id = 0, depth = 500, fogGate = 1, scene = { sceneNorm, sceneNorm, sceneNorm, 1 } },
    }, {
      enabled = true,
      color = fogPacked,
      offsetRaw = 0,
      shift = 0,
      table32 = constantDensityTable(density),
      alpha = 0,
    }, customEdgeColors(edgeNorm), false)
    local scale = out[1] > 1 and 255 or 1
    local aScale = out[4] > 1 and 255 or 1
    Assert.near(out[1], edgeFoggedNorm * scale, 1 / 255 * scale, "fog enabled + edge marked + AA off: fogged edge: red")
    Assert.near(
      out[4],
      15 / 31 * aScale,
      1.2 / 255 * aScale,
      "fog alpha applies before AA: alpha fogged even when AA off"
    )
  end

  -- Fog enabled + edge marked + AA on => fogged mix, fog alpha before AA
  do
    local out = runFinalPass(scope, {
      { id = 10, depth = 1000, fogGate = 0, scene = { sceneNorm, sceneNorm, sceneNorm, 1 } },
      { id = 0, depth = 500, fogGate = 1, scene = { sceneNorm, sceneNorm, sceneNorm, 1 } },
      { id = 0, depth = 500, fogGate = 1, scene = { sceneNorm, sceneNorm, sceneNorm, 1 } },
    }, {
      enabled = true,
      color = fogPacked,
      offsetRaw = 0,
      shift = 0,
      table32 = constantDensityTable(density),
      alpha = 0,
    }, customEdgeColors(edgeNorm), true)
    local scale = out[1] > 1 and 255 or 1
    local aScale = out[4] > 1 and 255 or 1
    Assert.near(out[1], mixFoggedNorm * scale, 1.2 / 255 * scale, "fog enabled + edge marked + AA on: fogged mix: red")
    Assert.near(out[4], 15 / 31 * aScale, 1.2 / 255 * aScale, "fog alpha before AA mix: alpha is fogged before mixing")
  end
end

function T.presentation_world_depth_rejects_behind_sprite(scope)
  local renderer = scope:own(GxRenderer.new({ worldRasterScale = 2 }))
  local world = depthOpaqueQuad(scope, -0.5, 220, 20, 20, 3, false)
  local behind = depthOpaqueQuad(scope, -1.0, 20, 220, 20, 4, false)
  behind.billboardProjection = true

  local target, color = presentationTarget(scope, 640, 480)
  love.graphics.setCanvas(target)
  love.graphics.clear(0, 0, 0, 1)
  render(
    renderer,
    emptyRuntime(),
    perspectiveCamera(),
    { { world } },
    { behind },
    FieldViewport.new(640, 480, { mode = "strict" })
  )
  love.graphics.setCanvas()

  local r, g, b = color:newImageData():getPixel(320, 240)
  Assert.isTrue(r > g and r > b, "world geometry remains visible over the behind sprite")
  Assert.isTrue(g < 0.2 and b < 0.2, "the behind sprite does not leak through world depth")
end

function T.presentation_host_depth_keeps_near_sprite_when_far_submitted_later(scope)
  local renderer = scope:own(GxRenderer.new({ worldRasterScale = 2 }))
  local near = depthOpaqueQuad(scope, -0.25, 20, 20, 220, 5, false)
  local far = depthOpaqueQuad(scope, -0.75, 220, 20, 20, 6, false)
  near.billboardProjection = true
  far.billboardProjection = true

  local target, color = presentationTarget(scope, 640, 480)
  love.graphics.setCanvas(target)
  love.graphics.clear(0, 0, 0, 1)
  render(
    renderer,
    emptyRuntime(),
    perspectiveCamera(),
    {},
    { near, far },
    FieldViewport.new(640, 480, { mode = "strict" })
  )
  love.graphics.setCanvas()

  local r, g, b = color:newImageData():getPixel(320, 240)
  Assert.isTrue(b > r and b > g, "near sprite remains visible after the far sprite")
  Assert.isTrue(r < 0.2 and g < 0.2, "the later far sprite does not replace the near sprite")
end

function T.presentation_host_depth_is_cleared_between_frames(scope)
  local renderer = scope:own(GxRenderer.new({ worldRasterScale = 2 }))
  local near = depthOpaqueQuad(scope, -0.25, 20, 20, 220, 5, false)
  local far = depthOpaqueQuad(scope, -0.75, 220, 20, 20, 6, false)
  near.billboardProjection = true
  far.billboardProjection = true

  local target, color = presentationTarget(scope, 640, 480)
  love.graphics.setCanvas(target)
  love.graphics.clear(0, 0, 0, 1)
  render(renderer, emptyRuntime(), perspectiveCamera(), {}, { near }, FieldViewport.new(640, 480, { mode = "strict" }))
  render(renderer, emptyRuntime(), perspectiveCamera(), {}, { far }, FieldViewport.new(640, 480, { mode = "strict" }))
  love.graphics.setCanvas()

  local r, g, b = color:newImageData():getPixel(320, 240)
  Assert.isTrue(r > g and r > b, "the next frame can draw through the prior frame's host depth")
end

function T.presentation_sprites_use_native_resolution_fog_and_no_edge_pass(scope)
  local renderer = scope:own(GxRenderer.new({ worldRasterScale = 2 }))
  local sprite = depthOpaqueQuad(scope, -0.5, 180, 180, 180, 6, true)
  sprite.billboardProjection = true
  local runtime = emptyRuntime()
  runtime.edgeColors[1] = 0x7fff
  runtime.fog = {
    enabled = true,
    color = 31 + 31 * 32 + 31 * 1024,
    offset = 0,
    slope = 0,
    alpha = 31,
    table = (function()
      local values = {}
      for index = 1, 32 do
        values[index] = 31
      end
      return values
    end)(),
  }
  local target, color = presentationTarget(scope, 640, 480)
  love.graphics.setCanvas(target)
  love.graphics.clear(0, 0, 0, 1)
  render(renderer, runtime, perspectiveCamera(), {}, { sprite }, FieldViewport.new(640, 480, { mode = "strict" }))
  love.graphics.setCanvas()

  Assert.equal(renderer.colorW, 512, "world target remains independent of presentation sprite resolution")
  local r, g, b = color:newImageData():getPixel(320, 240)
  Assert.isTrue(r < 1 and g < 1 and b < 1, "sprite color is fogged at its own depth")
  Assert.isTrue(math.abs(r - g) < 1 / 255 and math.abs(g - b) < 1 / 255, "sprite has no edge-color outline")
end

local function presentationQuadMesh(scope, z)
  return scope:own(syntheticMesh({
    { -1, -1, z, 0, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 1, -1, z, 1, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 1, 1, z, 1, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { -1, -1, z, 0, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 1, 1, z, 1, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { -1, 1, z, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
  }))
end

local function presentationSprite(_, mesh, image)
  return {
    mesh = mesh,
    material = { alphaClass = "cutout", texMatrix = IDENTITY_NORMAL, image = image },
    transform = IDENTITY,
    modelNormal = IDENTITY_NORMAL,
    billboardProjection = true,
    billboardCenter = { 0, 0, 0 },
    billboardScale = { 1, 1, 1 },
    alphaClass = "cutout",
    cullMode = "none",
    polygonAlpha = 1,
    polygonMode = "modulation",
    polygonId = 0,
    lightMask = 0,
    alphaCutoff = 0.5 / 255,
    fogEnabled = false,
    center = { 0, 0, 0 },
  }
end

local function registrationCamera(width, height)
  local far = 400
  local projection = Matrix4.perspective(math.rad(60), width / height, 0.1, far)
  return {
    distance = 26,
    far = far,
    view = function()
      return IDENTITY
    end,
    projection = function()
      return projection
    end,
    billboardProjection = function()
      return projection
    end,
  }
end

local function projectedCenter(projection, center)
  local clipX = projection[1] * center[1] + projection[5] * center[2] + projection[9] * center[3] + projection[13]
  local clipY = projection[2] * center[1] + projection[6] * center[2] + projection[10] * center[3] + projection[14]
  local clipW = projection[4] * center[1] + projection[8] * center[2] + projection[12] * center[3] + projection[16]
  return { x = clipX / clipW, y = clipY / clipW, w = clipW }
end

local function projectedHostCenter(viewport, camera, center, targetWidth, targetHeight)
  local projected = projectedCenter(camera.billboardProjection(), center)
  Assert.isTrue(projected.w > 1.5, "the registration fixture keeps perspective clip.w materially above one")
  local rectangle = viewport.worldViewport
  local scaleX = rectangle.width / targetWidth
  local scaleY = -rectangle.height / targetHeight
  local offsetX = (2 * rectangle.x + rectangle.width) / targetWidth - 1
  local offsetY = -(1 - (2 * rectangle.y + rectangle.height) / targetHeight)
  return {
    continuousX = (projected.x * scaleX + offsetX + 1) * targetWidth / 2,
    continuousY = (1 - (projected.y * scaleY + offsetY)) * targetHeight / 2,
    homogeneousWrongX = (projected.x * scaleX + offsetX / projected.w + 1) * targetWidth / 2,
  }
end

local function presentationCenter(image, width, height)
  local sumX, sumY, count = 0, 0, 0
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local r, g, b = image:getPixel(x, y)
      if r > 0.75 and g < 0.1 and b < 0.1 then
        sumX, sumY, count = sumX + x, sumY + y, count + 1
      end
    end
  end
  Assert.isTrue(count >= 4, "the diagnostic sprite leaves a readable red center region")
  return sumX / count, sumY / count
end

local function renderRegistration(scope, renderer, width, height, center, viewport)
  local target, color = presentationTarget(scope, width, height)
  local sprite = presentationSprite(scope, presentationQuadMesh(scope, 0), solidAlphaImage(scope, 255, 0, 0, 255))
  sprite.billboardCenter = center
  sprite.billboardScale = { 0.06, 0.06, 1 }
  love.graphics.setCanvas(target)
  love.graphics.clear(0, 0, 0, 1)
  local camera = registrationCamera(width, height)
  render(renderer, emptyRuntime(), camera, {}, { sprite }, viewport)
  love.graphics.setCanvas()
  local image = color:newImageData()
  local actualX, actualY = presentationCenter(image, width, height)
  return camera, actualX, actualY
end

local function worldLandmark(scope, image)
  local mesh = scope:own(syntheticMesh({
    { 0.12, -0.12, -3, 0, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 0.36, -0.12, -3, 1, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 0.36, 0.12, -3, 1, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 0.12, -0.12, -3, 0, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 0.36, 0.12, -3, 1, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 0.12, 0.12, -3, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
  }))
  local item = presentationSprite(scope, mesh, image)
  item.billboardProjection = false
  item.billboardCenter = nil
  item.billboardScale = nil
  item.center = { 0.24, 0, -3 }
  return item
end

local function colorCenter(image, color)
  local sumX, sumY, count = 0, 0, 0
  for y = 0, image:getHeight() - 1 do
    for x = 0, image:getWidth() - 1 do
      local r, g, b = image:getPixel(x, y)
      if color == "red" and r > 0.75 and g < 0.1 and b < 0.1 then
        sumX, sumY, count = sumX + x, sumY + y, count + 1
      elseif color == "green" and g > 0.75 and r < 0.1 and b < 0.1 then
        sumX, sumY, count = sumX + x, sumY + y, count + 1
      end
    end
  end
  Assert.isTrue(count >= 4, color .. " diagnostic remains visible")
  return sumX / count, sumY / count
end

function T.world_landmark_and_presentation_sprite_keep_relative_registration_on_round_trip(scope)
  local renderer = scope:own(GxRenderer.new({ worldRasterScale = 2 }))
  local observations = {}
  for _, size in ipairs({ { 320, 240 }, { 1280, 720 }, { 320, 240 } }) do
    local width, height = size[1], size[2]
    local target, color = presentationTarget(scope, width, height)
    local landmark = worldLandmark(scope, solidAlphaImage(scope, 0, 255, 0, 255))
    local sprite = presentationSprite(scope, presentationQuadMesh(scope, 0), solidAlphaImage(scope, 255, 0, 0, 255))
    sprite.billboardCenter = { 0.48, 0, -3 }
    sprite.billboardScale = { 0.06, 0.06, 1 }
    local viewport = FieldViewport.new(width, height, { mode = "expanded" })
    love.graphics.setCanvas(target)
    love.graphics.clear(0, 0, 0, 1)
    render(renderer, emptyRuntime(), registrationCamera(width, height), { { landmark } }, { sprite }, viewport)
    love.graphics.setCanvas()
    local image = color:newImageData()
    local greenX, greenY = colorCenter(image, "green")
    local redX, redY = colorCenter(image, "red")
    observations[#observations + 1] = { x = redX - greenX, y = redY - greenY }
  end
  Assert.near(observations[3].x, observations[1].x, 2, "round-trip restores the world/sprite X relationship")
  Assert.near(observations[3].y, observations[1].y, 2, "round-trip restores the world/sprite Y relationship")
  Assert.isTrue(math.abs(observations[2].x) > 2, "diagnostics have a measurable world-space separation")
end

function T.presentation_billboard_registration_uses_homogeneous_offset_and_state_position(scope)
  local width, height = 1280, 720
  local renderer = scope:own(GxRenderer.new({ worldRasterScale = 2 }))
  local viewport = FieldViewport.new(width, height, { mode = "strict", x = 50, y = 30 })
  local center = { 0.3683, 0.17, -3.0 }
  local camera, actualX, actualY = renderRegistration(scope, renderer, width, height, center, viewport)
  local expected = projectedHostCenter(viewport, camera, center, width, height)

  Assert.isTrue(
    math.abs(expected.continuousX - expected.homogeneousWrongX) >= 10,
    "the non-centered offset fixture is homogeneous-diagnostic"
  )
  Assert.near(actualX, expected.continuousX, 1.5, "non-centered presentation placement uses homogeneous offset")
  Assert.isTrue(
    math.abs(actualX - expected.homogeneousWrongX) > 10,
    "non-centered placement does not use raw clip-space offset"
  )
  Assert.isTrue(
    math.abs(actualY - expected.continuousY) <= 2 or math.abs(actualY - (height - 1 - expected.continuousY)) <= 2,
    "non-centered Y placement remains visible"
  )
end

local function flashFogRuntime()
  local values = {}
  for index = 1, 32 do
    values[index] = 255
  end
  local runtime = emptyRuntime()
  runtime.fog = {
    enabled = true,
    color = 31 * 1024,
    offset = 0,
    slope = 0,
    alpha = 0,
    table = values,
  }
  return runtime
end

local function renderPresentationCase(scope, renderer, runtime, worldParts, spriteItems)
  local target, color = presentationTarget(scope, 640, 480)
  love.graphics.setCanvas(target)
  love.graphics.clear(0, 220 / 255, 0, 1)
  render(
    renderer,
    runtime,
    perspectiveCamera(),
    worldParts,
    spriteItems,
    FieldViewport.new(640, 480, { mode = "strict" })
  )
  love.graphics.setCanvas()
  return color:newImageData()
end

function T.presentation_sprites_stay_inside_a_wide_strict_world_viewport(scope)
  local renderer = scope:own(GxRenderer.new())
  local target, color = presentationTarget(scope, 1280, 720)
  local image = solidAlphaImage(scope, 255, 0, 0, 255)
  local sprite = presentationSprite(scope, presentationQuadMesh(scope, 0), image)
  local viewport = FieldViewport.new(1280, 720, { mode = "strict" })

  love.graphics.setCanvas(target)
  love.graphics.clear(0, 0, 0, 1)
  render(renderer, emptyRuntime(), fixedCamera(), {}, { sprite }, viewport)
  love.graphics.setCanvas()

  local pixels = color:newImageData()
  local center = { pixels:getPixel(640, 360) }
  local bar = { pixels:getPixel(32, 360) }
  Assert.isTrue(center[1] > 0.5, "the centered actor remains visible")
  Assert.isTrue(bar[1] < 0.05 and bar[2] < 0.05 and bar[3] < 0.05, "pillarbox bars remain untouched")
end

function T.presentation_sprites_stay_inside_a_narrow_expanded_viewport_fallback(scope)
  local renderer = scope:own(GxRenderer.new())
  local target, color = presentationTarget(scope, 600, 720)
  local image = solidAlphaImage(scope, 0, 255, 0, 255)
  local sprite = presentationSprite(scope, presentationQuadMesh(scope, 0), image)
  local viewport = FieldViewport.new(600, 720, { mode = "expanded" })

  love.graphics.setCanvas(target)
  love.graphics.clear(0, 0, 0, 1)
  render(renderer, emptyRuntime(), fixedCamera(), {}, { sprite }, viewport)
  love.graphics.setCanvas()

  local pixels = color:newImageData()
  local center = { pixels:getPixel(300, 360) }
  local bar = { pixels:getPixel(300, 32) }
  Assert.isTrue(center[2] > 0.5, "the centered actor remains visible in the fitted world")
  Assert.isTrue(bar[1] < 0.05 and bar[2] < 0.05 and bar[3] < 0.05, "top/bottom bars remain untouched")
end

function T.presentation_sprite_fog_uses_the_world_endpoint_density_rules(scope)
  local renderer = scope:own(GxRenderer.new())
  local target, color = presentationTarget(scope, 640, 480)
  local image = solidAlphaImage(scope, 255, 0, 0, 255)
  local sprite = presentationSprite(scope, presentationQuadMesh(scope, -300), image)
  sprite.billboardCenter = nil
  sprite.billboardScale = nil
  sprite.fogEnabled = true
  local normalRamp = {}
  local saturatingRamp = {}
  for index = 1, 31 do
    normalRamp[index] = (index - 1) * 4
    saturatingRamp[index] = (index - 1) * 4
  end
  normalRamp[32] = 124
  saturatingRamp[32] = 255
  local function runtime(table32)
    local value = emptyRuntime()
    value.fog = {
      enabled = true,
      color = 31 + 31 * 32 + 31 * 1024,
      offset = -0x10000,
      slope = 0,
      alpha = 31,
      table = table32,
    }
    return value
  end
  local function renderSprite(table32)
    love.graphics.setCanvas(target)
    love.graphics.clear(0, 0, 0, 1)
    render(
      renderer,
      runtime(table32),
      perspectiveCamera(),
      {},
      { sprite },
      FieldViewport.new(640, 480, { mode = "strict" })
    )
    love.graphics.setCanvas()
    return { color:newImageData():getPixel(320, 240) }
  end

  local normal = renderSprite(normalRamp)
  local saturating = renderSprite(saturatingRamp)
  Assert.isTrue(normal[2] < 0.99, "the ordinary fog ramp preserves its final density of 124")
  Assert.isTrue(saturating[2] > 0.99, "a final raw density at or above 127 saturates to 128")
end

function T.presentation_orientation_is_exact_at_an_off_center_coordinate(scope)
  local renderer = scope:own(GxRenderer.new())
  local target, color = presentationTarget(scope, 640, 480)
  local sprite = presentationSprite(scope, presentationQuadMesh(scope, 0), solidAlphaImage(scope, 255, 0, 0, 255))
  sprite.billboardCenter = { 0, 0.5, 0 }
  sprite.billboardScale = { 0.25, 0.25, 1 }

  love.graphics.setCanvas(target)
  love.graphics.clear(0, 0, 0, 1)
  render(renderer, emptyRuntime(), fixedCamera(), {}, { sprite }, FieldViewport.new(640, 480, { mode = "strict" }))
  love.graphics.setCanvas()

  local pixels = color:newImageData()
  local expected = { pixels:getPixel(320, 120) }
  local mirrored = { pixels:getPixel(320, 359) }
  Assert.isTrue(
    expected[1] > 0.5 and expected[2] < 0.1 and expected[3] < 0.1,
    "off-center actor has the expected vertical orientation"
  )
  Assert.isTrue(
    mirrored[1] < 0.05 and mirrored[2] < 0.05 and mirrored[3] < 0.05,
    "the mirrored coordinate remains background"
  )
end

function T.fogged_presentation_rgb_survives_zero_result_alpha(scope)
  local renderer = scope:own(GxRenderer.new({ worldRasterScale = 2 }))
  local world = depthOpaqueQuad(scope, -0.5, 0, 220, 0, 3, false)
  local sprite = presentationSprite(scope, depthQuadMesh(scope, -0.25), solidAlphaImage(scope, 255, 0, 0, 255))
  sprite.fogEnabled = true

  local pixel =
    { renderPresentationCase(scope, renderer, flashFogRuntime(), { { world } }, { sprite }):getPixel(320, 240) }
  Assert.near(pixel[1], 0, 1 / 255, "full fog removes the source red channel")
  Assert.near(pixel[2], 0, 1 / 255, "full fog leaves no source green channel")
  Assert.near(pixel[3], 1, 1 / 255, "full fog stores the blue fog RGB")
  Assert.near(pixel[4], 0, 1 / 255, "the DS fog result alpha remains zero")
end

function T.presentation_depth_writes_keep_the_near_fogged_sprite_visible(scope)
  local renderer = scope:own(GxRenderer.new({ worldRasterScale = 2 }))
  local near = presentationSprite(scope, depthQuadMesh(scope, -0.25), solidAlphaImage(scope, 255, 0, 0, 255))
  near.fogEnabled = true
  local far = presentationSprite(scope, depthQuadMesh(scope, -0.75), solidAlphaImage(scope, 255, 255, 0, 255))

  local pixels = renderPresentationCase(scope, renderer, flashFogRuntime(), {}, { near, far })
  local pixel = { pixels:getPixel(320, 240) }
  Assert.near(pixel[1], 0, 1 / 255, "the near fogged sprite has no red")
  Assert.near(pixel[2], 0, 1 / 255, "the far sprite cannot overwrite the near depth")
  Assert.near(pixel[3], 1, 1 / 255, "the near fogged sprite remains blue despite zero alpha")
  Assert.near(pixel[4], 0, 1 / 255, "the near fog result alpha is preserved")
end

function T.presentation_cutout_holes_remain_world_pixels_under_direct_replace(scope)
  local renderer = scope:own(GxRenderer.new({ worldRasterScale = 2 }))
  local backdrop = presentationSprite(scope, presentationQuadMesh(scope, -0.75), solidAlphaImage(scope, 0, 220, 0, 255))
  local mesh = scope:own(syntheticMesh({
    { -1, -1, -0.25, 0, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 1, -1, -0.25, 1, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 1, 1, -0.25, 1, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { -1, -1, -0.25, 0, 1, 0, 0, 1, 1, 1, 1, 1, 0 },
    { 1, 1, -0.25, 1, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
    { -1, 1, -0.25, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0 },
  }))
  local data = love.image.newImageData(2, 1)
  data:setPixel(0, 0, 1, 0, 0, 0)
  data:setPixel(1, 0, 1, 0, 0, 1)
  local image = scope:own(love.graphics.newImage(data))
  image:setFilter("nearest", "nearest")
  local sprite = presentationSprite(scope, mesh, image)

  local pixels = renderPresentationCase(scope, renderer, emptyRuntime(), {}, { backdrop, sprite })
  local holeR, holeG = pixels:getPixel(300, 240)
  local solidR, solidG = pixels:getPixel(340, 240)
  Assert.isTrue(holeG > 0.7 and holeR < 0.1, "an alpha5-zero cutout texel leaves the world untouched")
  Assert.isTrue(solidR > 0.7 and solidG < 0.1, "an accepted cutout texel replaces the world")
end

return GraphicsSmoke.suite(T)
