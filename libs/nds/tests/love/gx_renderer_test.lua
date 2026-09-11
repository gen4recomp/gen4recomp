-- Pure GxRenderer contracts that need no graphics context: the per-draw
-- light-mask encoding and the scene-schema gate.
-- Everything that compiles a shader, allocates a render target, or reads
-- back driver state lives in map_renderer_graphics_test.lua. (The state
-- target's color-resolution sizing and the transactional rollback contract
-- are pinned by state_target_dimensions_equal_color_dimensions and
-- state_target_recreation_failure_releases_partials_and_keeps_previous_set
-- below, both driven through the fake graphics context.)

local Assert = require("tests.support.Assert")
local GxRenderer = require("libs.nds.src.love.GxRenderer")
local MapSceneLoader = require("libs.hgss.src.presentation.MapSceneLoader")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local Matrix3 = require("libs.math.src.Matrix3")
local Matrix4 = require("libs.math.src.Matrix4")
local BillboardTransform = require("libs.hgss.src.presentation.BillboardTransform")
local FieldActorDraw = require("libs.hgss.src.presentation.FieldActorDraw")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local FieldLightProfile = require("libs.assets.src.field.FieldLightProfile")
local RenderQueue = require("libs.hgss.src.presentation.RenderQueue")

local T = {}

---@class GxRendererTest.Shader : GxRenderer.Shader
---@field source string
---@field releaseCount integer
---@field sends { name: string, values: table }[]
---@field uniforms table<string, unknown>
---@field send fun(self: GxRendererTest.Shader, name: string, ...)
---@field release fun(self: GxRendererTest.Shader)
---@class GxRendererTest.Canvas : GxRenderer.Canvas
---@field releaseCount integer
---@field w integer
---@field h integer
---@field canvasOpts GxRendererTest.CanvasOptions?
---@field filter { [1]: string, [2]: string }|nil
---@field setFilter fun(self: GxRendererTest.Canvas, min: string, mag: string)
---@field release fun(self: GxRendererTest.Canvas)
---@class GxRendererTest.CanvasOptions
---@field format string?
---@class GxRendererTest.TargetDescriptor : GxRenderer.TargetDescriptor
---@field [1] GxRendererTest.Canvas
---@field [2] GxRendererTest.Canvas
---@field depthstencil GxRendererTest.Canvas
---@class GxRendererTest.GraphicsCalls
---@field canvas table[]
---@field blend table[]
---@field depth table[]
---@field wireframe table[]
---@field clear table[]
---@field draw table[]
---@class GxRendererTest.Graphics : GxRenderer.Graphics
---@field shaders GxRendererTest.Shader[]
---@field canvases GxRendererTest.Canvas[]
---@field calls GxRendererTest.GraphicsCalls
---@field setFailOnSend fun(value: table|nil)
---@field setFailOnNewCanvas fun(value: integer|nil)
---@field getDrawCalls fun(): integer
---@field getDimensions fun(): integer, integer
---@field newShader fun(source: string): GxRendererTest.Shader
---@field newCanvas fun(width: integer, height: integer, opts: GxRendererTest.CanvasOptions?): GxRendererTest.Canvas
---@field getCanvas fun(): table?
---@field setCanvas fun(canvas: table?)
---@field getShader fun(): table?
---@field setShader fun(shader: table?)
---@field getBlendMode fun(): string?, string?
---@field setBlendMode fun(mode: string, alpha: string)
---@field getDepthMode fun(): string?, boolean?
---@field setDepthMode fun(mode: string, write: boolean)
---@field isWireframe fun(): boolean
---@field setWireframe fun(enabled: boolean)
---@field getMeshCullMode fun(): string?
---@field setMeshCullMode fun(mode: string)
---@field getColor fun(): number, number, number, number
---@field setColor fun(r: number, g: number, b: number, a: number)
---@field draw fun(mesh: table, ...)
---@field clear fun(...)

-- Eight zero-based RGB555-packed edge colors, the shape
-- MapAssetCompiler now emits (HgssFieldEdgeColors.TABLE_A/TABLE_B) and
-- GxRenderer decodes at draw time -- distinct, arbitrary packed values so a
-- decode bug (wrong channel, wrong index) cannot hide behind a uniform grey
-- fixture.
local function edgeColorsFixture()
  return { [0] = 0, 1 + 2 * 32 + 3 * 1024, 4, 5 * 32, 6 * 1024, 7, 8 + 8 * 32, 9 }
end

-- A disabled fog fixture (HgssFieldFog.runtimePreset's shape for a disabled
-- weather): the default for tests not exercising fog wiring itself.
local function disabledFogFixture()
  local table32 = {}
  for i = 1, 32 do
    table32[i] = 0
  end
  return { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = table32 }
end

-- The raw 5-bit RGB555 decode (each channel normalized /31, no six-bit
-- expansion): still the correct expected domain for material/light color
-- registers and the fog color this file's fog-preset tests assert against.
local function decodeRgb555Float(packed)
  return {
    (packed % 32) / 31,
    (math.floor(packed / 32) % 32) / 31,
    (math.floor(packed / 1024) % 32) / 31,
  }
end

-- The exact decode GxRenderer must apply to a packed RGB555 edge-color
-- entry before it reaches the final shader: each 5-bit channel expanded to
-- the DS six-bit framebuffer domain (melonDS's rule -- 0 stays 0, any
-- non-zero n becomes 2n+1 -- the same expansion map.glsl's expand5to6
-- applies to texture/vertex colors), then normalized by 63, not 31. Edge
-- color composites directly into the six-bit scene RGB (edge.glsl replaces
-- scene.rgb outright), so a raw /31 RGB555 value is the wrong domain, not
-- merely an unrounded one. This is an independently hand-derived expected
-- function, not a copy of GxRenderer's private decoder.
local function expand5to6(c5)
  if c5 <= 0 then
    return 0
  end
  return c5 * 2 + 1
end

local function decodeRgb555ToRgb6Float(packed)
  local r = packed % 32
  local g = math.floor(packed / 32) % 32
  local b = math.floor(packed / 1024) % 32
  return {
    expand5to6(r) / 63,
    expand5to6(g) / 63,
    expand5to6(b) / 63,
  }
end

-- An empty scene and camera for the restoration-contract tests: the renderer
-- draws nothing but still binds/unbinds canvases, shaders, and state.
---@return { camera: FieldCamera, runtime: table }
local function emptySceneCamera()
  local identity = Matrix4.identity()
  return {
    camera = {
      distance = 26,
      far = 400,
      view = function()
        return identity
      end,
      projection = function()
        return identity
      end,
      billboardProjection = function()
        return identity
      end,
    }, --[[@as FieldCamera]]
    runtime = {
      mapDraws = {},
      buildingDraws = {},
      stats = { triangleCount = 0, meshCount = 0, textureCount = 0 },
      -- Edge colors are scene state fed from the compiled area's
      -- real HGSS table, never a GxRenderer constructor invariant.
      edgeColors = edgeColorsFixture(),
      -- Likewise fog: the resolved global weather preset, disabled by
      -- default here so tests unrelated to fog wiring do not need their own
      -- fixture.
      fog = disabledFogFixture(),
    },
  }
end

-- Injected graphics for the headless contract tests: a full settable state
-- surface (canvas, shader, blend, depth, wireframe, cull, color) that the
-- renderer must restore exactly, stub shaders/canvases for construction, and
-- failOnNewShader/failOnNewCanvas/failOnDrawCall injection on the Nth call so
-- the construction and draw error paths run without a GL context.
---@param opts table|nil
---@return GxRendererTest.Graphics
local function fakeGraphics(opts)
  opts = opts or {}
  local shaders, canvases = {}, {}
  local shaderCount, canvasCount, drawCalls = 0, 0, 0
  local calls = {
    canvas = {},
    blend = {},
    depth = {},
    wireframe = {},
    clear = {},
    draw = {},
  }
  local state = {
    canvas = opts.canvas,
    shader = opts.shader,
    blendMode = opts.blendMode,
    blendAlpha = opts.blendAlpha,
    depthMode = opts.depthMode,
    depthWrite = opts.depthWrite,
    wireframe = opts.wireframe,
    cullMode = opts.cullMode,
    color = opts.color or { 1, 1, 1, 1 },
  }
  local graphics = {
    shaders = shaders,
    canvases = canvases,
    calls = calls,
    setFailOnSend = function(value)
      opts.failSend = value
    end,
    setFailOnNewCanvas = function(value)
      opts.failOnNewCanvas = value
    end,
    getDrawCalls = function()
      return drawCalls
    end,
    getDimensions = function()
      return 256, 192
    end,
    newShader = function(source)
      shaderCount = shaderCount + 1
      if opts.failOnNewShader == shaderCount then
        error("injected shader failure")
      end
      local shader = { source = source, releaseCount = 0, sends = {}, uniforms = {} }
      --[[@as GxRendererTest.Shader]]
      shader.send = function(_, name, ...)
        if opts.failSend and opts.failSend.shader == shader and opts.failSend.name == name then
          opts.failSend = nil
          error("injected shader send failure")
        end
        shader.sends[#shader.sends + 1] = { name = name, values = { ... } }
        shader.uniforms[name] = select(1, ...)
      end
      shader.release = function()
        shader.releaseCount = shader.releaseCount + 1
      end
      shaders[#shaders + 1] = shader
      return shader --[[@as GxRendererTest.Shader]]
    end,
    newCanvas = function(w, h, canvasOpts)
      canvasCount = canvasCount + 1
      if opts.failOnNewCanvas == canvasCount then
        error("injected canvas failure")
      end
      -- Records the requested size/format and every setFilter call so raster
      -- target-sizing and nearest-filter contracts can be asserted headlessly.
      local canvas = { releaseCount = 0, w = w, h = h, canvasOpts = canvasOpts }
      --[[@as GxRendererTest.Canvas]]
      canvas.setFilter = function(_, min, mag)
        canvas.filter = { min, mag }
      end
      canvas.release = function()
        canvas.releaseCount = canvas.releaseCount + 1
      end
      canvases[#canvases + 1] = canvas
      return canvas --[[@as GxRendererTest.Canvas]]
    end,
    getCanvas = function()
      return state.canvas
    end,
    setCanvas = function(canvas)
      state.canvas = canvas
      calls.canvas[#calls.canvas + 1] = canvas
    end,
    getShader = function()
      return state.shader
    end,
    setShader = function(shader)
      state.shader = shader
    end,
    getBlendMode = function()
      return state.blendMode, state.blendAlpha
    end,
    setBlendMode = function(mode, alpha)
      state.blendMode, state.blendAlpha = mode, alpha
      calls.blend[#calls.blend + 1] = { mode = mode, alpha = alpha }
    end,
    getDepthMode = function()
      return state.depthMode, state.depthWrite
    end,
    setDepthMode = function(mode, write)
      state.depthMode, state.depthWrite = mode, write
      calls.depth[#calls.depth + 1] = { mode = mode, write = write }
    end,
    isWireframe = function()
      return state.wireframe
    end,
    setWireframe = function(wireframe)
      state.wireframe = wireframe
      calls.wireframe[#calls.wireframe + 1] = wireframe
    end,
    getMeshCullMode = function()
      return state.cullMode
    end,
    setMeshCullMode = function(mode)
      state.cullMode = mode
    end,
    getColor = function()
      return state.color[1], state.color[2], state.color[3], state.color[4]
    end,
    setColor = function(r, g, b, a)
      state.color = { r, g, b, a }
    end,
    draw = function(mesh, ...)
      drawCalls = drawCalls + 1
      calls.draw[#calls.draw + 1] = {
        mesh = mesh,
        args = { ... },
        wireframe = state.wireframe,
        depthMode = state.depthMode,
        depthWrite = state.depthWrite,
        blendMode = state.blendMode,
        blendAlpha = state.blendAlpha,
      }
      if opts.failOnDrawCall == drawCalls then
        error("injected draw failure")
      end
    end,
    clear = function(...)
      calls.clear[#calls.clear + 1] = { ... }
    end,
  } --[[@as GxRendererTest.Graphics]]
  return graphics
end

local function render(renderer, sceneRuntime, camera, worldParts, spriteItems, viewport, alpha, clearColor)
  local viewMatrix = camera:view(alpha)
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
    queue = queue,
    spriteItems = spriteItems,
    viewport = viewport,
    clearColor = clearColor,
  })
end

---@param shader table
---@param name string
---@return integer
local function shaderSendCount(shader, name)
  local typedShader = shader --[[@as GxRendererTest.Shader]]
  local count = 0
  for _, send in ipairs(typedShader.sends) do
    if send.name == name then
      count = count + 1
    end
  end
  return count
end

---@param calls table[]
---@param expected table
---@return integer
local function callCount(calls, expected)
  local count = 0
  for _, call in ipairs(calls) do
    local matches = true
    for key, value in pairs(expected) do
      if call[key] ~= value then
        matches = false
      end
    end
    if matches then
      count = count + 1
    end
  end
  return count
end

-- The exact restoration contract: every captured state (canvas, shader,
-- blend, depth, wireframe, cull, color) equals the pre-draw value, never a
-- hard-coded default. The seeded values differ from what the renderer sets
-- (the renderer binds its own canvas/shader, "less"/"alpha" depth and blend,
-- white, and enables wireframe only during a wireframe pass), so each
-- assertion fails unless the restore block runs. Colors round-trip through
-- float32 on some GL drivers, so they are compared within a small tolerance.
---@param lg GxRendererTest.Graphics
---@param canvas table
---@param shader table
local function assertRestoredState(lg, canvas, shader)
  Assert.equal(lg.getCanvas(), canvas)
  Assert.equal(lg.getShader(), shader)
  local blend, alpha = lg.getBlendMode()
  Assert.equal(blend, "add")
  Assert.equal(alpha, "alphamultiply")
  local depthMode, depthWrite = lg.getDepthMode()
  Assert.equal(depthMode, "lequal")
  Assert.equal(depthWrite, true)
  Assert.equal(lg.isWireframe(), false)
  Assert.equal(lg.getMeshCullMode(), "back")
  local r, g, b, a = lg.getColor()
  Assert.near(r, 0.2, 1e-6)
  Assert.near(g, 0.4, 1e-6)
  Assert.near(b, 0.6, 1e-6)
  Assert.near(a, 0.8, 1e-6)
end

-- The renderer owns everything it created through the injected graphics: every
-- shader and canvas it built must be released when the renderer is released.
---@param lg GxRendererTest.Graphics
---@param renderer GxRenderer
---@param extraShaderCount integer|nil
local function assertResourcesReleased(lg, renderer, extraShaderCount)
  for _, shader in ipairs(lg.shaders) do
    Assert.equal(shader.releaseCount, 1, "renderer released every created shader exactly once")
  end
  for _, canvas in ipairs(lg.canvases) do
    Assert.equal(canvas.releaseCount, 1, "renderer released every created canvas exactly once")
  end
  local expectedShaderCount = renderer.translucencyMode == GxRenderer.TRANSLUCENCY_EXACT and 5 or 3
  expectedShaderCount = expectedShaderCount + (extraShaderCount or 0)
  Assert.equal(#lg.shaders, expectedShaderCount, "shader ownership matches the renderer translucency mode")
end

---@param renderer GxRenderer
---@return table<string, GxRendererTest.Canvas?>
local function rendererCanvasRoles(renderer)
  local roles = {
    sceneColor = renderer.sceneColor --[[@as GxRendererTest.Canvas?]],
    colorDepth = renderer.colorDepth --[[@as GxRendererTest.Canvas?]],
    renderState = renderer.renderState --[[@as GxRendererTest.Canvas?]],
    spareColor = renderer._spareColor --[[@as GxRendererTest.Canvas?]],
    spareState = renderer._spareState --[[@as GxRendererTest.Canvas?]],
    sourceColor = renderer._sourceColor --[[@as GxRendererTest.Canvas?]],
    sourceMeta = renderer._sourceMeta --[[@as GxRendererTest.Canvas?]],
  } --[[@as table<string, GxRendererTest.Canvas?>]]
  return roles
end

---@param value table
---@return GxRendererTest.TargetDescriptor
local function targetDescriptor(value)
  return value --[[@as GxRendererTest.TargetDescriptor]]
end

---@param renderer GxRenderer
---@param lg GxRendererTest.Graphics
---@return table<string, GxRendererTest.Canvas?>, integer
local function assertPublishedCanvasRoles(renderer, lg)
  local roles = rendererCanvasRoles(renderer)
  local roleNames = {
    "sceneColor",
    "colorDepth",
    "renderState",
    "spareColor",
    "spareState",
    "sourceColor",
    "sourceMeta",
  }
  local seen = {}
  for _, role in ipairs(roleNames) do
    local canvas = roles[role]
    Assert.notNil(canvas, "renderer publishes the " .. role .. " canvas role")
    Assert.isNil(seen[canvas], "each published canvas has exactly one renderer role")
    seen[assert(canvas)] = role
  end
  local roleCount = #roleNames
  Assert.equal(#lg.canvases, roleCount, "every created canvas belongs to one live renderer role")
  return roles, roleCount
end

function T.rejects_stale_scene_schema()
  local ok, err = pcall(MapSceneLoader.load, nil, { schema = "g4-map-scene-v1" })
  Assert.isTrue(
    not ok and err.code == "MAP_SCENE_UNSUPPORTED_SCHEMA",
    "rejects old scene schema: " .. tostring(err.code)
  )
end

-- State coverage is one-to-one with color coverage, so the renderer's state
-- dimensions equal the color dimensions after any draw.
function T.state_target_dimensions_equal_color_dimensions()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg, translucencyMode = GxRenderer.TRANSLUCENCY_EXACT })
  local scene = emptySceneCamera()
  local viewport = { worldViewport = { x = 0, y = 0, width = 1280, height = 720 } }
  render(renderer, scene.runtime, scene.camera, nil, nil, viewport, 0)
  Assert.equal(renderer.colorW, 1280)
  Assert.equal(renderer.colorH, 720)
  Assert.equal(renderer.stateW, renderer.colorW, "state width equals the color width, not a fixed semantic raster")
  Assert.equal(renderer.stateH, renderer.colorH, "state height equals the color height, not a fixed semantic raster")
  Assert.equal(renderer.stateW, 1280)
  Assert.equal(renderer.stateH, 720)
  renderer:release()
end

function T.world_raster_scale_bounds_only_the_world_targets()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg, worldRasterScale = 2 })
  local scene = emptySceneCamera()
  local sizes = {
    { width = 640, height = 480, expectedW = 512, expectedH = 384 },
    { width = 1280, height = 720, expectedW = 683, expectedH = 384 },
    { width = 1920, height = 1080, expectedW = 683, expectedH = 384 },
    { width = 2560, height = 1440, expectedW = 683, expectedH = 384 },
    { width = 3440, height = 1440, expectedW = 917, expectedH = 384 },
    { width = 800, height = 300, expectedW = 800, expectedH = 300 },
  }
  for _, size in ipairs(sizes) do
    render(
      renderer,
      scene.runtime,
      scene.camera,
      nil,
      nil,
      { worldViewport = { x = 0, y = 0, width = size.width, height = size.height } },
      0
    )
    Assert.equal(renderer.colorW, size.expectedW, "world raster width is DS-relative")
    Assert.equal(renderer.colorH, size.expectedH, "world raster height is DS-relative")
    local sceneCanvas = assert(renderer.sceneColor) --[[@as GxRendererTest.Canvas]]
    Assert.equal(sceneCanvas.w, size.expectedW)
    Assert.equal(sceneCanvas.h, size.expectedH)
  end
  renderer:release()
end

function T.world_raster_scale_rejects_non_positive_and_non_finite_values()
  local lg = fakeGraphics()
  for _, scale in ipairs({ 0, -1, math.huge, -math.huge, 0 / 0 }) do
    local ok, renderer = pcall(GxRenderer.new, { graphics = lg, worldRasterScale = scale })
    if ok then
      renderer:release()
    end
    Assert.isFalse(ok, "invalid world raster scale is rejected")
  end
end

-- Target recreation is transactional: a failure while building any staged
-- role leaves the previous complete generation usable, and every partial new
-- canvas is released.
function T.state_target_recreation_failure_releases_partials_and_keeps_previous_set()
  local probeGraphics = fakeGraphics()
  local probeRenderer = GxRenderer.new({ graphics = probeGraphics, translucencyMode = GxRenderer.TRANSLUCENCY_EXACT })
  local scene = emptySceneCamera()
  render(probeRenderer, scene.runtime, scene.camera, nil, nil, FieldViewport.new(640, 480, { mode = "strict" }), 0)
  local _, generationSize = assertPublishedCanvasRoles(probeRenderer, probeGraphics)
  probeRenderer:release()

  for failureOffset = 1, generationSize do
    local lg = fakeGraphics()
    local renderer = GxRenderer.new({ graphics = lg, translucencyMode = GxRenderer.TRANSLUCENCY_EXACT })
    render(renderer, scene.runtime, scene.camera, nil, nil, FieldViewport.new(640, 480, { mode = "strict" }), 0)
    local oldColorW, oldColorH, oldStateW, oldStateH =
      renderer.colorW, renderer.colorH, renderer.stateW, renderer.stateH
    local oldColorTargets = renderer._colorTargets
    local oldRoles = rendererCanvasRoles(renderer)
    local _, oldGenerationSize = assertPublishedCanvasRoles(renderer, lg)
    Assert.equal(oldGenerationSize, generationSize, "target generations use the same renderer roles")
    lg.setFailOnNewCanvas(generationSize + failureOffset)

    local err = Assert.throws(function()
      render(renderer, scene.runtime, scene.camera, nil, nil, FieldViewport.new(1280, 720, { mode = "expanded" }), 0)
    end)
    Assert.isTrue(tostring(err):find("injected canvas failure", 1, true) ~= nil, "rethrows the canvas failure")

    for i = generationSize + 1, #lg.canvases do
      Assert.equal(lg.canvases[i].releaseCount, 1, "partial canvas " .. i .. " was released")
    end
    for role, canvas in pairs(oldRoles) do
      Assert.equal(rendererCanvasRoles(renderer)[role], canvas, "the previous " .. role .. " remains published")
    end
    Assert.equal(renderer.colorW, oldColorW, "the recorded color size survives")
    Assert.equal(renderer.colorH, oldColorH, "the recorded color size survives")
    Assert.equal(renderer.stateW, oldStateW, "the recorded state width survives")
    Assert.equal(renderer.stateH, oldStateH, "the recorded state height survives")
    Assert.equal(renderer._colorTargets, oldColorTargets, "the previous color target descriptor survives")
    for role, canvas in pairs(oldRoles) do
      Assert.equal(canvas.releaseCount, 0, "the previous " .. role .. " remains owned")
    end

    renderer:release()
    for _, canvas in ipairs(lg.canvases) do
      Assert.equal(canvas.releaseCount, 1, "release cleans up every canvas exactly once")
    end
  end
end

-- The fixed-DS-density semantic-size helper is deleted, not left as a dead
-- compatibility wrapper: no production, test, or doc may still derive a
-- 192-line state raster from the display size.
function T.no_fixed_semantic_size_helper_remains()
  Assert.isNil(rawget(GxRenderer, "semanticTargetSize"), "the fixed-192 semantic-size helper is removed")
end

-- The renderer sends the edge radius on the real draw
-- path is the nearest integer of the viewport's field-pixel scale
-- (referenceFrame.height / 192 * zoom), minimum 1. At 1280x720 expanded
-- (referenceFrame.height 720) with zoom 1, the scale is 720/192 = 3.75, so
-- the radius is floor(3.75 + 0.5) = 4; the same viewport at zoom 0.5 gives
-- floor(1.875 + 0.5) = 2; a 2560x1440 viewport at zoom 1 gives
-- floor(7.5 + 0.5) = 8; a 480p viewport at zoom 1 gives floor(2.5 + 0.5) = 3.
function T.draw_sends_the_rounded_field_pixel_scale_as_the_edge_radius()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg, translucencyMode = GxRenderer.TRANSLUCENCY_EXACT })
  local scene = emptySceneCamera()
  local edgeShader = lg.shaders[2]

  local function radiusSentFor(viewport, zoom)
    scene.camera.zoom = zoom
    render(renderer, scene.runtime, scene.camera, nil, nil, viewport, 0)
    local last
    for _, send in ipairs(edgeShader.sends) do
      if send.name == "u_edgeRadiusPx" then
        last = send.values[1]
      end
    end
    return last
  end

  Assert.equal(radiusSentFor(FieldViewport.new(1280, 720, { mode = "expanded" }), 1.0), 4, "radius 4 at 720p zoom 1")
  Assert.equal(radiusSentFor(FieldViewport.new(1280, 720, { mode = "expanded" }), 0.5), 2, "radius 2 at 720p zoom 0.5")
  Assert.equal(radiusSentFor(FieldViewport.new(2560, 1440, { mode = "expanded" }), 1.0), 8, "radius 8 at 1440p zoom 1")
  Assert.equal(radiusSentFor(FieldViewport.new(640, 480, { mode = "strict" }), 1.0), 3, "radius 3 at 480p zoom 1")
  renderer:release()
end

-- Exact caller-state restoration: every captured caller state comes back
-- equal to its pre-draw value, never a hard-coded default.
-- The empty scene draws nothing, so canvas, shader, blend, depth, and color
-- are the states the renderer actually dirtied here; the wireframe/cull
-- restore is exercised in the failing-draw test, where the wireframe pass
-- dirties them before the injected failure.
function T.draw_restores_exact_caller_state()
  local canvas, shader = {}, {}
  local lg = fakeGraphics({
    canvas = canvas,
    shader = shader,
    blendMode = "add",
    blendAlpha = "alphamultiply",
    depthMode = "lequal",
    depthWrite = true,
    wireframe = false,
    cullMode = "back",
    color = { 0.2, 0.4, 0.6, 0.8 },
  })
  local renderer = GxRenderer.new({ graphics = lg, translucencyMode = GxRenderer.TRANSLUCENCY_EXACT })
  local scene = emptySceneCamera()
  render(renderer, scene.runtime, scene.camera, nil, nil, FieldViewport.new(640, 480, { mode = "strict" }), 0)
  assertRestoredState(lg, canvas, shader)
  renderer:release()
  assertResourcesReleased(lg, renderer)
end

function T.invalid_presentation_descriptor_restores_exact_caller_state()
  local canvas, shader = { [1] = {} }, {}
  local lg = fakeGraphics({
    canvas = canvas,
    shader = shader,
    blendMode = "add",
    blendAlpha = "alphamultiply",
    depthMode = "lequal",
    depthWrite = true,
    wireframe = false,
    cullMode = "back",
    color = { 0.2, 0.4, 0.6, 0.8 },
  })
  local renderer = GxRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local err = Assert.throws(function()
    render(renderer, scene.runtime, scene.camera, nil, nil, FieldViewport.new(640, 480, { mode = "strict" }), 0)
  end)
  Assert.isTrue(tostring(err):find("color presentation target", 1, true) ~= nil)
  assertRestoredState(lg, canvas, shader)
  renderer:release()
  assertResourcesReleased(lg, renderer)
end

function T.presentation_sprites_use_direct_replace_with_depth_writes()
  local canvas, shader = {}, {}
  canvas.getWidth = function()
    return 640
  end
  canvas.getHeight = function()
    return 480
  end
  local lg = fakeGraphics({
    canvas = canvas,
    shader = shader,
    blendMode = "add",
    blendAlpha = "alphamultiply",
    depthMode = "lequal",
    depthWrite = true,
    wireframe = false,
    cullMode = "back",
    color = { 0.2, 0.4, 0.6, 0.8 },
  })
  local renderer = GxRenderer.new({ graphics = lg })
  local item = {
    mesh = { setTexture = function() end },
    material = { texMatrix = Matrix4.identity() },
    transform = Matrix4.identity(),
    modelNormal = Matrix3.identity(),
    billboardProjection = true,
    alphaClass = "opaque",
    cullMode = "back",
    polygonAlpha = 1,
    polygonMode = "modulation",
    polygonId = 0,
    lightMask = 0,
    alphaCutoff = 0.5 / 255,
    center = { 0, 0, 0 },
  }
  local scene = emptySceneCamera()
  render(renderer, scene.runtime, scene.camera, nil, { item }, FieldViewport.new(640, 480, { mode = "strict" }), 0)
  local spriteDraw
  for _, draw in ipairs(lg.calls.draw) do
    if draw.mesh == item.mesh then
      spriteDraw = draw
      break
    end
  end
  Assert.notNil(spriteDraw, "the presentation item reaches the renderer draw boundary")
  Assert.equal(spriteDraw.blendMode, "replace")
  Assert.equal(spriteDraw.blendAlpha, "premultiplied")
  Assert.equal(spriteDraw.depthMode, "less")
  Assert.equal(spriteDraw.depthWrite, true)
  assertRestoredState(lg, canvas, shader)
  renderer:release()
  assertResourcesReleased(lg, renderer, 1)
end

-- libs/nds must not import a game-level config, so the game's background
-- color is injected as opts.clearColor rather than hardcoded: the renderer
-- clears the scene canvas to exactly the table it was given, and falls back
-- to its own default when the caller (e.g. a test uninterested in
-- background color) omits it. The render-state attachment clears first (its own
-- DS_STATE_CLEAR rear-plane value, not the scene color), so the color clear
-- is the draw's second clear call.
function T.draw_clears_the_scene_canvas_to_the_injected_color()
  local lg = fakeGraphics()
  local injected = { 0.5, 0.6, 0.7, 1 }
  local renderer = GxRenderer.new({ graphics = lg, clearColor = injected })
  local scene = emptySceneCamera()
  render(renderer, scene.runtime, scene.camera, nil, nil, FieldViewport.new(640, 480, { mode = "strict" }), 0)
  Assert.equal(lg.calls.clear[2][1], injected, "scene canvas clears to the injected color")
end

function T.draw_without_an_injected_color_uses_a_renderer_default()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg, translucencyMode = GxRenderer.TRANSLUCENCY_EXACT })
  local scene = emptySceneCamera()
  render(renderer, scene.runtime, scene.camera, nil, nil, FieldViewport.new(640, 480, { mode = "strict" }), 0)
  Assert.isTrue(lg.calls.clear[2][1] ~= nil, "scene canvas still clears when no color is injected")
end

-- A caller-supplied frame-level clear color overrides the constructor default
-- for that draw only; the constructor color is never mutated, so a later draw
-- without a frame override falls back to it again. This lets multiple
-- lightweight presentation wrappers share one GX backend safely (each
-- supplies its own clear color per frame) without backend-global mutable
-- clear state.
function T.draw_uses_frame_clear_color_override_when_supplied()
  local lg = fakeGraphics()
  local constructorColor = { 0.1, 0.1, 0.1, 1 }
  local frameColor = { 0.9, 0.2, 0.2, 1 }
  local renderer = GxRenderer.new({ graphics = lg, clearColor = constructorColor })
  local scene = emptySceneCamera()
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })

  render(renderer, scene.runtime, scene.camera, nil, nil, viewport, 0, frameColor)
  Assert.equal(lg.calls.clear[2][1], frameColor, "the frame-level clear color overrides the constructor default")

  render(renderer, scene.runtime, scene.camera, nil, nil, viewport, 0)
  Assert.equal(
    lg.calls.clear[4][1],
    constructorColor,
    "a later draw without a frame override falls back to the constructor color"
  )
  renderer:release()
end

-- A draw failure must not leak the scene's state either: the wireframe item
-- dirties cull mode and wireframe before the injected draw failure, so the
-- captured caller state (including those two) is restored exactly and the
-- original draw error is rethrown. The item's first draw call is the
-- world MRT's own wireframe pass (which never touches host wireframe/cull
-- state), so the failure is injected on the second draw call -- the color
-- pass's wireframe draw, issued after setWireframe(true)/setMeshCullMode.
function T.draw_failure_restores_exact_state_and_rethrows()
  local canvas, shader = {}, {}
  local lg = fakeGraphics({
    canvas = canvas,
    shader = shader,
    blendMode = "add",
    blendAlpha = "alphamultiply",
    depthMode = "lequal",
    depthWrite = true,
    wireframe = false,
    cullMode = "back",
    color = { 0.2, 0.4, 0.6, 0.8 },
    failOnDrawCall = 1,
  })
  local renderer = GxRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local identity = Matrix4.identity()
  local err = Assert.throws(function()
    render(renderer, scene.runtime, scene.camera, {
      {
        {
          mesh = { setTexture = function() end },
          alphaClass = "wireframe",
          cullMode = "none",
          lightMask = 0,
          polygonId = 0,
          transform = identity,
          modelNormal = Matrix3.identity(),
          center = { 0, 0, 0 },
        },
      },
    }, nil, FieldViewport.new(640, 480, { mode = "strict" }), 0)
  end)
  Assert.isTrue(tostring(err):find("injected draw failure", 1, true) ~= nil, "rethrows the draw failure")
  assertRestoredState(lg, canvas, shader)
  renderer:release()
  assertResourcesReleased(lg, renderer)
end

-- Construction is transactional: when the Nth shader fails, the previous ones
-- must be released and the failure must reach the caller. The renderer owns
-- five shaders (color, resolve, world MRT, source, composite).
function T.new_releases_first_shader_when_second_shader_fails()
  local lg = fakeGraphics({ failOnNewShader = 2 })
  local err = Assert.throws(function()
    GxRenderer.new({ graphics = lg, translucencyMode = GxRenderer.TRANSLUCENCY_EXACT })
  end)
  Assert.isTrue(tostring(err):find("injected shader failure", 1, true) ~= nil, "rethrows the shader failure")
  Assert.equal(#lg.shaders, 1, "only the first shader was created")
  Assert.equal(lg.shaders[1].releaseCount, 1, "the first shader is released when the second fails")
end

-- A failure while creating the very first shader creates nothing to leak and
-- still reaches the caller.
function T.new_first_shader_failure_leaks_nothing()
  local lg = fakeGraphics({ failOnNewShader = 1 })
  local err = Assert.throws(function()
    GxRenderer.new({ graphics = lg, translucencyMode = GxRenderer.TRANSLUCENCY_EXACT })
  end)
  Assert.isTrue(tostring(err):find("injected shader failure", 1, true) ~= nil, "rethrows the shader failure")
  Assert.equal(#lg.shaders, 0, "no shader was created")
end

function T.new_releases_prior_shaders_when_compositor_shader_fails()
  for _, failAt in ipairs({ 4, 5 }) do
    local lg = fakeGraphics({ failOnNewShader = failAt })
    local err = Assert.throws(function()
      GxRenderer.new({ graphics = lg, translucencyMode = GxRenderer.TRANSLUCENCY_EXACT })
    end)
    Assert.isTrue(
      tostring(err):find("injected shader failure", 1, true) ~= nil,
      "rethrows the shader failure at " .. failAt
    )
    local created = failAt - 1
    Assert.equal(#lg.shaders, created, "only the prior shaders were created before failure at " .. failAt)
    for i = 1, created do
      Assert.equal(lg.shaders[i].releaseCount, 1, "shader " .. i .. " is released when shader " .. failAt .. " fails")
    end
  end
end

-- The renderer builds its shaders from the injected source reader -- the
-- engine-resource boundary -- never from host paths: the reader is called
-- with exactly the engine-owned shader paths, in construction order, and each
-- newShader receives that path's source.
function T.new_reads_shader_sources_through_the_injected_reader()
  local lg = fakeGraphics()
  local calls = {}
  local renderer = GxRenderer.new({
    graphics = lg,
    translucencyMode = GxRenderer.TRANSLUCENCY_EXACT,
    readSource = function(path)
      calls[#calls + 1] = path
      return "source:" .. path
    end,
  })
  Assert.deepEqual(calls, {
    "libs/nds/src/love/shaders/map.glsl",
    "libs/nds/src/love/shaders/edge.glsl",
    "libs/nds/src/love/shaders/source.glsl",
    "libs/nds/src/love/shaders/composite.glsl",
  })
  Assert.equal(lg.shaders[1].source, "source:libs/nds/src/love/shaders/map.glsl")
  Assert.equal(lg.shaders[2].source, "source:libs/nds/src/love/shaders/edge.glsl")
  Assert.equal(lg.shaders[3].source, "#define WORLD_MRT\nsource:libs/nds/src/love/shaders/map.glsl")
  Assert.equal(lg.shaders[4].source, "source:libs/nds/src/love/shaders/source.glsl")
  Assert.equal(lg.shaders[5].source, "source:libs/nds/src/love/shaders/composite.glsl")
  renderer:release()
end

-- Without an injected reader, the default resolves the engine shader paths in
-- the actual runtime environments: through love.filesystem from the packaged
-- archive, or -- in the repo checkout where the app runs as `love app/` and
-- the library tree sits outside the source mount -- from the host file under
-- the LÖVE source base directory. Both real sources must reach newShader.
function T.new_reads_real_shader_sources_by_default()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  Assert.isTrue(lg.shaders[1].source:find("uniform", 1, true) ~= nil, "map shader source is real GLSL")
  Assert.isTrue(lg.shaders[2].source:find("uniform", 1, true) ~= nil, "edge shader source is real GLSL")
  Assert.isTrue(lg.shaders[3].source:find("uniform", 1, true) ~= nil, "MRT world shader source is real GLSL")
  renderer:release()
end

-- A source-read failure is a construction failure like any other: when the
-- reader fails for the Nth shader, the prior ones are released and the error
-- propagates (the transactional construction holds through the new boundary).
function T.new_second_shader_source_failure_releases_first_shader()
  local lg = fakeGraphics()
  local reads = 0
  local err = Assert.throws(function()
    GxRenderer.new({
      graphics = lg,
      readSource = function()
        reads = reads + 1
        if reads == 2 then
          error("injected read failure")
        end
        return "source"
      end,
    })
  end)
  Assert.isTrue(tostring(err):find("injected read failure", 1, true) ~= nil, "rethrows the read failure")
  Assert.equal(#lg.shaders, 1, "only the first shader was created")
  Assert.equal(lg.shaders[1].releaseCount, 1, "the first shader is released when the second source read fails")
end

function T.new_compositor_source_read_failure_releases_prior_shaders()
  for _, failAt in ipairs({ 3, 4 }) do
    local lg = fakeGraphics()
    local reads = 0
    local err = Assert.throws(function()
      GxRenderer.new({
        graphics = lg,
        translucencyMode = GxRenderer.TRANSLUCENCY_EXACT,
        readSource = function()
          reads = reads + 1
          if reads == failAt then
            error("injected read failure")
          end
          return "source"
        end,
      })
    end)
    Assert.isTrue(
      tostring(err):find("injected read failure", 1, true) ~= nil,
      "rethrows the read failure at " .. failAt
    )
    local created = failAt
    Assert.equal(#lg.shaders, created, "only the prior shaders were created before failure at " .. failAt)
    for i = 1, created do
      Assert.equal(
        lg.shaders[i].releaseCount,
        1,
        "shader " .. i .. " is released when source read " .. failAt .. " fails"
      )
    end
  end
end

-- The very first source read failing creates nothing and still reaches the
-- caller.
function T.new_first_shader_source_failure_leaks_nothing()
  local lg = fakeGraphics()
  local err = Assert.throws(function()
    GxRenderer.new({
      graphics = lg,
      readSource = function()
        error("injected read failure")
      end,
    })
  end)
  Assert.isTrue(tostring(err):find("injected read failure", 1, true) ~= nil, "rethrows the read failure")
  Assert.equal(#lg.shaders, 0, "no shader was created")
end

-- Color targets always match the display size directly; the render-state
-- targets share the exact same dimensions (state coverage is one-to-one with
-- color coverage -- there is no separate semantic-size derivation any more).
-- sceneColor and renderState are both nearest-filtered.
function T.new_derives_equal_color_and_state_target_sizes_and_nearest_filters_scene_color_and_render_state()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local viewport = { worldViewport = { x = 0, y = 0, width = 1280, height = 720 } }
  render(renderer, scene.runtime, scene.camera, nil, nil, viewport, 0)
  Assert.equal(renderer.colorW, 1280, "the color target matches the display viewport width exactly")
  Assert.equal(renderer.colorH, 720, "the color target matches the display viewport height exactly")
  Assert.equal(renderer.stateW, 1280, "the state target matches the color target width exactly")
  Assert.equal(renderer.stateH, 720, "the state target matches the color target height exactly")
  local sceneColor = renderer.sceneColor --[[@as GxRendererTest.Canvas]]
  local renderState = renderer.renderState --[[@as GxRendererTest.Canvas]]
  Assert.deepEqual(sceneColor.filter, { "nearest", "nearest" }, "sceneColor is nearest-filtered")
  Assert.deepEqual(renderState.filter, { "nearest", "nearest" }, "renderState is nearest-filtered")
  renderer:release()
end

-- Target reallocation builds the full replacement set before releasing the
-- live one: when any new-canvas allocation fails, every partial new canvas is
-- released, the previous targets and their recorded size survive, and the
-- failure reaches the caller. Each failure position is derived from the live
-- role count, so this test protects ownership without encoding an allocation
-- count as an implementation detail.
function T.canvas_recreation_failure_releases_partial_new_canvases()
  local probeGraphics = fakeGraphics()
  local probeRenderer = GxRenderer.new({ graphics = probeGraphics, translucencyMode = GxRenderer.TRANSLUCENCY_EXACT })
  local scene = emptySceneCamera()
  render(probeRenderer, scene.runtime, scene.camera, nil, nil, FieldViewport.new(640, 480, { mode = "strict" }), 0)
  local _, generationSize = assertPublishedCanvasRoles(probeRenderer, probeGraphics)
  probeRenderer:release()

  for failureOffset = 1, generationSize do
    local lg = fakeGraphics()
    local renderer = GxRenderer.new({ graphics = lg, translucencyMode = GxRenderer.TRANSLUCENCY_EXACT })
    render(renderer, scene.runtime, scene.camera, nil, nil, FieldViewport.new(640, 480, { mode = "strict" }), 0)
    local oldRoles = rendererCanvasRoles(renderer)
    Assert.equal(#lg.canvases, generationSize, "the first target set was created")
    lg.setFailOnNewCanvas(generationSize + failureOffset)
    local oldColorW, oldColorH, oldStateW, oldStateH =
      renderer.colorW, renderer.colorH, renderer.stateW, renderer.stateH
    local oldColorTargets = renderer._colorTargets

    local err = Assert.throws(function()
      render(renderer, scene.runtime, scene.camera, nil, nil, FieldViewport.new(1280, 720, { mode = "expanded" }), 0)
    end)
    Assert.isTrue(tostring(err):find("injected canvas failure", 1, true) ~= nil, "rethrows the canvas failure")

    for i = generationSize + 1, #lg.canvases do
      Assert.equal(lg.canvases[i].releaseCount, 1, "partial canvas " .. i .. " was released")
    end
    -- The previous target set survives untouched, at its recorded size.
    for role, canvas in pairs(oldRoles) do
      Assert.equal(rendererCanvasRoles(renderer)[role], canvas, "the previous " .. role .. " survives")
    end
    Assert.equal(renderer.colorW, oldColorW, "the recorded color size survives")
    Assert.equal(renderer.colorH, oldColorH, "the recorded color size survives")
    Assert.equal(renderer.stateW, oldStateW, "the recorded state size survives")
    Assert.equal(renderer.stateH, oldStateH, "the recorded state size survives")
    Assert.equal(renderer._colorTargets, oldColorTargets, "the previous color target descriptor survives")
    for role, canvas in pairs(oldRoles) do
      Assert.equal(canvas.releaseCount, 0, "the previous " .. role .. " is still owned")
    end

    renderer:release()
    for _, canvas in ipairs(lg.canvases) do
      Assert.equal(canvas.releaseCount, 1, "release cleans up every canvas exactly once")
    end
  end
end

-- Renderer-owned frame storage is stable while its contents reset. The
-- target descriptors remain stable while dimensions are unchanged. The final
-- resolve rebinds its state texture every frame, including after compositing.
function T.draw_reuses_frame_storage_and_configures_edges_at_change_boundaries()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })
  local stats = renderer.stats
  local edgeShader = renderer.edgeShader
  local recordedEdgeShader = edgeShader --[[@as GxRendererTest.Shader]]

  -- Edge colors are scene state, not a value the constructor sends
  -- before any scene exists.
  Assert.equal(shaderSendCount(edgeShader, "u_edgeColors"), 0, "construction sends no scene-derived edge colors")

  render(renderer, scene.runtime, scene.camera, nil, nil, viewport, 0)
  local colorTargets = assert(renderer._colorTargets, "successful canvas creation publishes the MRT descriptor")
  Assert.equal(colorTargets[1], renderer.sceneColor)
  Assert.equal(colorTargets.depthstencil, renderer.colorDepth)
  Assert.equal(colorTargets[2], renderer.renderState)
  Assert.equal(renderer.stats, stats, "draw reuses the public stats table")
  Assert.equal(shaderSendCount(edgeShader, "u_renderState"), 1)
  Assert.equal(shaderSendCount(edgeShader, "u_stateSize"), 1)
  Assert.equal(
    recordedEdgeShader.uniforms.u_renderState,
    renderer.renderState,
    "final resolve samples the published state"
  )
  Assert.deepEqual(recordedEdgeShader.uniforms.u_stateSize, { renderer.stateW, renderer.stateH })
  Assert.equal(shaderSendCount(edgeShader, "u_edgeColors"), 1, "the first draw establishes the scene edge table")

  render(renderer, scene.runtime, scene.camera, nil, nil, viewport, 0)
  Assert.equal(renderer._colorTargets, colorTargets, "unchanged dimensions reuse the color descriptor")
  Assert.equal(renderer._colorTargets, colorTargets, "unchanged dimensions reuse the MRT descriptor")
  Assert.equal(renderer.stats, stats, "later draws retain stats identity")
  Assert.equal(shaderSendCount(edgeShader, "u_renderState"), 2, "each final resolve binds its current state texture")
  Assert.equal(shaderSendCount(edgeShader, "u_stateSize"), 2, "each final resolve sends its current state size")
  Assert.equal(
    recordedEdgeShader.uniforms.u_renderState,
    renderer.renderState,
    "the second resolve samples the published state"
  )
  Assert.equal(shaderSendCount(edgeShader, "u_edgeColors"), 1, "the same edge table reference is not resent")

  viewport:resize(1280, 800)
  render(renderer, scene.runtime, scene.camera, nil, nil, viewport, 0)
  Assert.isTrue(renderer._colorTargets ~= colorTargets, "replacement publishes a new color descriptor")
  Assert.isTrue(renderer._colorTargets ~= colorTargets, "replacement publishes a new MRT descriptor")
  Assert.equal(shaderSendCount(edgeShader, "u_renderState"), 3)
  Assert.equal(shaderSendCount(edgeShader, "u_stateSize"), 3)
  Assert.equal(
    recordedEdgeShader.uniforms.u_renderState,
    renderer.renderState,
    "resize resolve samples the published state"
  )
  Assert.equal(shaderSendCount(edgeShader, "u_edgeColors"), 1, "a target resize alone does not resend the edge table")

  -- A different edge table (a new area's scene profile) resends, even though
  -- the raster size and target descriptors are unchanged.
  scene.runtime.edgeColors = edgeColorsFixture()
  render(renderer, scene.runtime, scene.camera, nil, nil, viewport, 0)
  Assert.equal(shaderSendCount(edgeShader, "u_edgeColors"), 2, "a changed edge table resends")

  -- The DS composites edge color by RGB replacement, not an
  -- alpha-mix scalar; the fidelity path carries no alpha uniform to blend
  -- with.
  Assert.equal(shaderSendCount(edgeShader, "u_edgeAlpha"), 0, "no alpha-mix uniform exists on the fidelity path")

  renderer:release()
  Assert.isNil(renderer._colorTargets, "release clears the color descriptor")
  Assert.isNil(renderer._colorTargets, "release clears the MRT descriptor")
end

-- The decoded values GxRenderer sends for u_edgeColors are the scene's edge
-- table RGB555 entries expanded into the six-bit combiner domain (0 -> 0,
-- n -> 2n+1, normalized /63) -- not a raw /31 RGB555 float, a placeholder
-- grey, or the wrong index/channel.
function T.draw_sends_the_scene_edge_table_decoded_to_normalized_rgb6()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local edgeShader = renderer.edgeShader --[[@as GxRendererTest.Shader]]

  render(renderer, scene.runtime, scene.camera, nil, nil, FieldViewport.new(640, 480, { mode = "strict" }), 0)

  local sent
  for _, send in ipairs(edgeShader.sends) do
    if send.name == "u_edgeColors" then
      sent = send.values
    end
  end
  assert(sent, "u_edgeColors was sent")
  local fixture = edgeColorsFixture()
  for i = 0, 7 do
    Assert.deepEqual(sent[i + 1], decodeRgb555ToRgb6Float(fixture[i]), "edge color entry " .. i)
  end
  renderer:release()
end

-- The locked A.5 fixture: RGB555(4,4,4) (packed 4 + 4*32 + 4*1024) must
-- reach the final shader as (9/63, 9/63, 9/63) -- melonDS's expand5to6(4) =
-- 2*4+1 = 9 in the six-bit domain, not 4/31 (the raw RGB555 float) and not
-- 8/63 (the old floor(c5/16) expansion's result for 4).
function T.edge_color_rgb555_4_4_4_expands_to_rgb6_9_63()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local edgeShader = renderer.edgeShader --[[@as GxRendererTest.Shader]]
  local packed444 = 4 + 4 * 32 + 4 * 1024
  scene.runtime.edgeColors = { [0] = packed444, 0, 0, 0, 0, 0, 0, 0 }

  render(renderer, scene.runtime, scene.camera, nil, nil, FieldViewport.new(640, 480, { mode = "strict" }), 0)

  local sent
  for _, send in ipairs(edgeShader.sends) do
    if send.name == "u_edgeColors" then
      sent = send.values
    end
  end
  assert(sent, "u_edgeColors was sent")
  Assert.deepEqual(sent[1], { 9 / 63, 9 / 63, 9 / 63 }, "RGB555(4,4,4) expands to RGB6(9,9,9), normalized /63")
  renderer:release()
end

-- A scene with no edge-color table is a required production collaborator
-- gone missing (every compiled HGSS field scene carries one -- field edge
-- marking is unconditionally enabled), not a case GxRenderer papers over
-- with an invented default.
function T.draw_requires_the_scenes_edge_color_table()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  scene.runtime.edgeColors = nil

  Assert.throws(function()
    render(renderer, scene.runtime, scene.camera, nil, nil, FieldViewport.new(640, 480, { mode = "strict" }), 0)
  end)
  renderer:release()
end

-- A camera missing a usable far plane is a malformed collaborator, not a case
-- to silently default around: the camera's far plane still feeds its own
-- projection matrices (camera:projection()/camera:billboardProjection()),
-- which both passes draw through, so GxRenderer must fail loudly rather
-- than render against an invented projection bound.
function T.draw_requires_normalized_projection_matrices()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })

  Assert.throws(function()
    renderer:draw({
      viewport = viewport,
      viewMatrix = Matrix4.identity(),
      billboardProjection = Matrix4.identity(),
      queue = { opaque = {}, cutout = {}, mixedOpaque = {}, wireframe = {}, blended = {} },
    })
  end)
  renderer:release()
end

-- The resolved HgssFieldFog.runtimePreset shape a compiled scene carries:
-- enabled, packed RGB555 color, raw offset, slope, alpha, and a 32-entry
-- density table -- distinct, non-placeholder values (not the renderer's own
-- idle-default zero/black/false) so a hardcoded-disabled bug cannot hide
-- behind a coincidentally-zero fixture.
local function fogFixture(enabled)
  local table32 = {}
  for i = 1, 32 do
    table32[i] = enabled and ((i - 1) * 4) or 255
  end
  return {
    enabled = enabled,
    color = enabled and (26 + 26 * 32 + 26 * 1024) or (1 + 2 * 32 + 3 * 1024),
    offset = enabled and 0x726F or 17,
    slope = enabled and 3 or 6,
    alpha = enabled and 31 or 0,
    table = table32,
  }
end

-- GxRenderer must send the scene's own resolved fog preset to the final
-- pass shader (edgeShader), not the permanently-disabled idle default and
-- not map.glsl (which owns no fog uniform -- see
-- map_shader_has_no_global_fog_uniforms in the graphics-smoke suite): enable,
-- the RGB555-decoded color, the offset converted into the depth domain
-- (fogOffsetRaw * 0x200), the slope (sent verbatim as the density shift), the
-- alpha (sent verbatim, 0..31, the same 5-bit domain the final shader's
-- fogAlpha5/srcAlpha5 blend operates in -- not normalized, unlike the fog
-- color), and the 32-entry table all reach edgeShader unconditionally
-- (per-frame, like u_view), whether the resolved preset is enabled or
-- disabled -- disabled is data on the preset, never a GxRenderer special
-- case.
function T.draw_sends_the_scenes_resolved_fog_preset_when_enabled()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  scene.runtime.fog = fogFixture(true)
  local shader = lg.shaders[2]

  render(renderer, scene.runtime, scene.camera, nil, nil, FieldViewport.new(640, 480, { mode = "strict" }), 0)

  Assert.equal(shader.uniforms.u_fogEnabled, true, "the resolved preset's enable reaches the final pass shader")
  Assert.deepEqual(
    shader.uniforms.u_fogColor,
    decodeRgb555Float(scene.runtime.fog.color),
    "fog color decodes like edge colors"
  )
  Assert.equal(shader.uniforms.u_fogOffsetDepth, 0x726F * 0x200, "the raw offset is converted into the depth domain")
  Assert.equal(shader.uniforms.u_fogShift, 3, "the preset's slope reaches the shader as the density shift verbatim")
  Assert.equal(shader.uniforms.u_fogAlpha, 31, "the preset's alpha reaches the shader verbatim, 0..31")
  local table32 = scene.runtime.fog.table
  for group = 0, 7 do
    Assert.deepEqual(
      shader.uniforms["u_fogTable" .. group],
      { table32[group * 4 + 1], table32[group * 4 + 2], table32[group * 4 + 3], table32[group * 4 + 4] },
      "each 4-entry density-table group reaches its own named uniform"
    )
  end
  renderer:release()
end

function T.draw_sends_the_scenes_resolved_fog_preset_when_disabled()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  scene.runtime.fog = fogFixture(false)
  local shader = lg.shaders[2]

  render(renderer, scene.runtime, scene.camera, nil, nil, FieldViewport.new(640, 480, { mode = "strict" }), 0)

  Assert.equal(shader.uniforms.u_fogEnabled, false)
  Assert.deepEqual(shader.uniforms.u_fogColor, decodeRgb555Float(scene.runtime.fog.color))
  Assert.equal(shader.uniforms.u_fogOffsetDepth, 17 * 0x200)
  Assert.equal(shader.uniforms.u_fogShift, 6)
  Assert.equal(shader.uniforms.u_fogAlpha, 0)
  local disabledTable32 = scene.runtime.fog.table
  for group = 0, 7 do
    Assert.deepEqual(shader.uniforms["u_fogTable" .. group], {
      disabledTable32[group * 4 + 1],
      disabledTable32[group * 4 + 2],
      disabledTable32[group * 4 + 3],
      disabledTable32[group * 4 + 4],
    }, "each 4-entry density-table group reaches its own named uniform")
  end
  renderer:release()
end

-- Every compiled HGSS field scene carries a resolved fog preset (global fog
-- is unconditionally resolved per map); a scene missing it is a required
-- collaborator gone missing, not a case GxRenderer defaults around.
function T.draw_requires_the_scenes_fog_preset()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  scene.runtime.fog = nil

  Assert.throws(function()
    render(renderer, scene.runtime, scene.camera, nil, nil, FieldViewport.new(640, 480, { mode = "strict" }), 0)
  end)
  renderer:release()
end

-- Fog is delivered to both consumers through their normal renderer send
-- boundaries. Repeating the same resolved preset must not repeat either
-- consumer's payload delivery.
function T.stable_fog_reference_sends_once_to_each_consumer()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  renderer:_ensureSpriteShader()
  local scene = emptySceneCamera()
  scene.runtime.fog = fogFixture(true)

  for _ = 1, 3 do
    renderer:_sendFog(scene.runtime)
    renderer._activeShader = renderer.spriteShader
    renderer:_sendSpriteFog(scene.runtime)
    renderer._activeShader = nil
  end

  local fogNames = { "u_fogEnabled", "u_fogColor", "u_fogOffsetDepth", "u_fogShift", "u_fogAlpha" }
  for _, name in ipairs(fogNames) do
    Assert.equal(shaderSendCount(renderer.edgeShader, name), 1, "stable fog sends once to the final consumer: " .. name)
    Assert.equal(
      shaderSendCount(renderer.spriteShader, name),
      1,
      "stable fog sends once to the sprite consumer: " .. name
    )
  end
  for group = 0, 7 do
    local name = "u_fogTable" .. group
    Assert.equal(
      shaderSendCount(renderer.edgeShader, name),
      1,
      "stable fog sends table group once to the final consumer"
    )
    Assert.equal(
      shaderSendCount(renderer.spriteShader, name),
      1,
      "stable fog sends table group once to the sprite consumer"
    )
  end
  renderer:release()
end

-- A preset change is published only after both consumers accept the complete
-- payload. A failed second consumer therefore retries the changed preset, and
-- the next unchanged frame is again a no-op.
function T.changed_fog_reference_retries_after_partial_sync_failure()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  renderer:_ensureSpriteShader()
  local scene = emptySceneCamera()
  local presetA = fogFixture(false)
  local presetB = fogFixture(true)
  scene.runtime.fog = presetA

  renderer:_sendFog(scene.runtime)
  renderer._activeShader = renderer.spriteShader
  renderer:_sendSpriteFog(scene.runtime)
  renderer._activeShader = nil

  scene.runtime.fog = presetB
  lg.setFailOnSend({ shader = renderer.spriteShader, name = "u_fogEnabled" })
  renderer:_sendFog(scene.runtime)
  renderer._activeShader = renderer.spriteShader
  local err = Assert.throws(function()
    renderer:_sendSpriteFog(scene.runtime)
  end)
  renderer._activeShader = nil
  Assert.isTrue(tostring(err):find("injected shader send failure", 1, true) ~= nil)

  renderer:_sendFog(scene.runtime)
  renderer._activeShader = renderer.spriteShader
  renderer:_sendSpriteFog(scene.runtime)
  renderer._activeShader = nil
  renderer:_sendFog(scene.runtime)
  renderer._activeShader = renderer.spriteShader
  renderer:_sendSpriteFog(scene.runtime)
  renderer._activeShader = nil

  Assert.equal(shaderSendCount(renderer.edgeShader, "u_fogEnabled"), 2, "the successful edge consumer does not resend")
  Assert.equal(
    shaderSendCount(renderer.spriteShader, "u_fogEnabled"),
    2,
    "the sprite consumer retries after its failed send"
  )
  local edgeShader = lg.shaders[2]
  Assert.deepEqual(edgeShader.uniforms.u_fogColor, decodeRgb555Float(presetB.color))
  Assert.equal(edgeShader.uniforms.u_fogOffsetDepth, presetB.offset * 0x200)
  Assert.equal(edgeShader.uniforms.u_fogShift, presetB.slope)
  Assert.equal(edgeShader.uniforms.u_fogAlpha, presetB.alpha)
  for group = 0, 7 do
    Assert.deepEqual(edgeShader.uniforms["u_fogTable" .. group], {
      presetB.table[group * 4 + 1],
      presetB.table[group * 4 + 2],
      presetB.table[group * 4 + 3],
      presetB.table[group * 4 + 4],
    })
  end
  renderer:release()
end

-- The renderer draws exactly the ordered world parts it is given; it never
-- reads scene draws out of the runtime itself. Its queue scratch and every
-- pass array retain identity across frames, while a smaller later frame does
-- not draw stale items retained from an earlier build.
function T.draw_renders_only_given_parts_into_persistent_scratch()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local identity = Matrix4.identity()
  local function drawItem(id)
    return {
      id = id,
      mesh = { setTexture = function() end },
      material = { alphaClass = "opaque" },
      transform = identity,
      modelNormal = Matrix3.identity(),
      alphaClass = "opaque",
      cullMode = "back",
      polygonAlpha = 1.0,
      polygonMode = "modulation",
      polygonId = 0,
      lightMask = 0,
      center = { 0, 0, 0 },
    }
  end
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })
  scene.runtime.mapDraws = { drawItem("map") }
  scene.runtime.buildingDraws = { drawItem("building") }

  -- Every draw() issues its own composite blit. Empty parts draw nothing
  -- beyond it, and each item in the given parts draws exactly twice -- once
  -- into the world MRT pass, once into the translucent color path.
  render(renderer, scene.runtime, scene.camera, nil, nil, viewport, 0)
  local emptyFrame = lg.getDrawCalls()
  render(renderer, scene.runtime, scene.camera, {
    { drawItem("a") },
    { drawItem("b") },
  }, nil, viewport, 0)
  local itemFrame = lg.getDrawCalls() - emptyFrame
  Assert.equal(itemFrame - emptyFrame, 2, "each given world item draws once through the MRT pass")

  render(renderer, scene.runtime, scene.camera, { { drawItem("next") } }, nil, viewport, 0)
  Assert.equal(renderer.stats.drawCalls, 1, "a smaller frame retains no stale draw items")

  renderer:release()
end

-- Per-polygon light-mask encoding: one vec4 of 0/1 floats, bit i = light i
-- of the polygon's 4-bit mask. Different masks decode to different uniforms
-- and mask 0 to all-off.
function T.light_mask_uniforms_decode_polygon_bits()
  Assert.deepEqual(GxRenderer.lightMaskUniforms(0), { 0, 0, 0, 0 })
  Assert.deepEqual(GxRenderer.lightMaskUniforms(1), { 1, 0, 0, 0 })
  Assert.deepEqual(GxRenderer.lightMaskUniforms(2), { 0, 1, 0, 0 })
  Assert.deepEqual(GxRenderer.lightMaskUniforms(5), { 1, 0, 1, 0 })
  Assert.deepEqual(GxRenderer.lightMaskUniforms(15), { 1, 1, 1, 1 })
  -- Masks outside the 4-bit polygon field are malformed data.
  Assert.throws(function()
    GxRenderer.lightMaskUniforms(16)
  end)
  Assert.throws(function()
    GxRenderer.lightMaskUniforms(-1)
  end)
end

function T.light_mask_uniforms_returns_caller_owned_values()
  local exposed = GxRenderer.lightMaskUniforms(5)
  exposed[1], exposed[3] = 0, 0

  Assert.deepEqual(GxRenderer.lightMaskUniforms(5), { 1, 0, 1, 0 }, "callers cannot mutate the cached lookup")
end

local function lightingRecord(startHalfSeconds, diffuseRgb555, vectorX)
  local lights = {}
  for i = 1, 4 do
    lights[i] = {
      enabled = i == 1,
      colorRgb555 = diffuseRgb555,
      vectorFx12 = { vectorX, 0, -4096 },
    }
  end
  return {
    startHalfSeconds = startHalfSeconds,
    lights = lights,
    diffuseRgb555 = diffuseRgb555,
    ambientRgb555 = diffuseRgb555,
    specularRgb555 = diffuseRgb555,
    emissionRgb555 = diffuseRgb555,
  }
end

-- Lighting uniforms are change-driven by selected-record identity. Decoded
-- material arrays retain identity while their values track record changes, and
-- a lit/unlit transition clears the record exactly once.
function T.lighting_cache_tracks_record_and_unlit_transitions()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  local shader = lg.shaders[1]
  local red, green = 31, 31 * 32
  local morning = lightingRecord(0, red, 0)
  local evening = lightingRecord(10, green, 4096)
  local runtime = { lighting = morning }

  renderer:_sendLighting(runtime, shader)
  Assert.equal(#shader.sends, 12, "first lit record sends four light uniform groups")
  local colors = renderer._lightMaterialColors
  local diffuse = colors.diffuse
  Assert.deepEqual(diffuse, { 1, 0, 0 })

  renderer:_sendLighting(runtime, shader)
  Assert.equal(#shader.sends, 12, "same profile and record sends nothing")
  Assert.equal(renderer._lightMaterialColors, colors)
  Assert.equal(renderer._lightMaterialColors.diffuse, diffuse)

  runtime.lighting = evening
  renderer:_sendLighting(runtime, shader)
  Assert.equal(#shader.sends, 24, "time selection moving records resends lighting")
  Assert.equal(renderer._lightMaterialColors, colors, "decoded material storage is persistent")
  Assert.equal(renderer._lightMaterialColors.diffuse, diffuse)
  Assert.deepEqual(diffuse, { 0, 1, 0 })

  runtime.lighting = lightingRecord(10, green, 4096)
  renderer:_sendLighting(runtime, shader)
  Assert.equal(#shader.sends, 36, "profile identity participates in the cache key")

  runtime.lighting = nil
  renderer:_sendLighting(runtime, shader)
  Assert.equal(#shader.sends, 48, "lit to unlit clears every light uniform once")
  Assert.isNil(renderer._lightMaterialColors, "unlit scenes expose no profile material colors")
  renderer:_sendLighting(runtime, shader)
  Assert.equal(#shader.sends, 48, "stable unlit state sends nothing")

  runtime.lighting = morning
  renderer:_sendLighting(runtime, shader)
  Assert.equal(#shader.sends, 60, "unlit to lit restores the selected record")
  Assert.equal(renderer._lightMaterialColors, colors)
  Assert.deepEqual(renderer._lightMaterialColors.diffuse, { 1, 0, 0 })
  renderer:release()
end

local function litRuntime()
  local white = 31 + 31 * 32 + 31 * 1024
  return {
    mapDraws = {},
    buildingDraws = {},
    stats = { triangleCount = 0, meshCount = 0, textureCount = 0 },
    edgeColors = edgeColorsFixture(),
    fog = disabledFogFixture(),
    lighting = lightingRecord(0, white, 0),
    fieldTimeSeconds = 0,
  }
end

function T.lighting_delivery_retries_only_the_shader_that_failed()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  local runtime = litRuntime()
  local colorShader, worldShader = lg.shaders[1], lg.shaders[3]

  renderer:_sendLighting(runtime, colorShader)
  lg.setFailOnSend({ shader = worldShader, name = "u_lightEnabled0" })
  Assert.throws(function()
    renderer:_sendLighting(runtime, worldShader)
  end, "a failed light upload propagates")

  renderer:_sendLighting(runtime, worldShader)
  Assert.equal(#colorShader.sends, 12, "a different shader remains cached after the failure")
  Assert.equal(#worldShader.sends, 12, "the failed shader retries its complete payload")
  renderer:release()
end

function T.lighting_cache_hit_restores_material_colors_after_another_shader_unlights()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  local runtime = litRuntime()
  local colorShader, worldShader = lg.shaders[1], lg.shaders[3]

  renderer:_sendLighting(runtime, colorShader)
  renderer:_sendLighting({ lighting = nil }, worldShader)
  Assert.isNil(renderer._lightMaterialColors)

  renderer:_sendLighting(runtime, colorShader)
  Assert.equal(renderer._lightMaterialColors, renderer._lightMaterialColorCache)
  renderer:release()
end

local function passItem(alphaClass, z, opts)
  opts = opts or {}
  return {
    mesh = { setTexture = function() end },
    material = { texMatrix = Matrix4.identity() },
    transform = Matrix4.identity(),
    modelNormal = Matrix3.identity(),
    alphaClass = alphaClass,
    cullMode = "back",
    polygonAlpha = 1.0,
    polygonMode = "modulation",
    polygonId = 0,
    lightMask = 0,
    alphaCutoff = 0.5 / 255,
    center = { 0, 0, z },
    depthEqual = opts.depthEqual or false,
    translucentDepthWrite = opts.translucentDepthWrite or false,
  }
end

function T.exact_compositor_sends_invariant_bindings_once_per_blended_frame()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg, translucencyMode = GxRenderer.TRANSLUCENCY_EXACT })
  local scene = emptySceneCamera()
  local parts = {
    { passItem("translucent", 0) },
    { passItem("translucent", 1) },
  }

  render(renderer, litRuntime(), scene.camera, parts, nil, FieldViewport.new(640, 480, { mode = "strict" }), 0)

  local compositeShader = renderer.compositeShader
  Assert.equal(shaderSendCount(compositeShader, "u_sourceColor"), 1)
  Assert.equal(shaderSendCount(compositeShader, "u_sourceMeta"), 1)
  Assert.equal(shaderSendCount(compositeShader, "u_size"), 1)
  Assert.equal(shaderSendCount(compositeShader, "u_activeColor"), 2)
  Assert.equal(shaderSendCount(compositeShader, "u_activeState"), 2)
  renderer:release()
end

function T.target_descriptors_retain_identity_through_steady_draws_and_exact_swaps()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg, translucencyMode = GxRenderer.TRANSLUCENCY_EXACT })
  local scene = emptySceneCamera()
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })
  local oneBlended = { { passItem("translucent", 0) } }
  local twoBlended = {
    { passItem("translucent", 0) },
    { passItem("translucent", 1) },
  }

  render(renderer, scene.runtime, scene.camera, oneBlended, nil, viewport, 0)
  local colorTargets = assert(renderer._colorTargets)
  local stateClearTargets = assert(renderer._stateClearTargets)
  local colorClearTargets = assert(renderer._colorClearTargets)
  local sourceColorTargets = assert(renderer._sourceColorTargets)
  local sourceMetaTargets = assert(renderer._sourceMetaTargets)
  render(renderer, scene.runtime, scene.camera, oneBlended, nil, viewport, 0)
  Assert.equal(renderer._colorTargets, colorTargets)
  Assert.equal(renderer._stateClearTargets, stateClearTargets)
  Assert.equal(renderer._colorClearTargets, colorClearTargets)
  Assert.equal(renderer._sourceColorTargets, sourceColorTargets)
  Assert.equal(renderer._sourceMetaTargets, sourceMetaTargets)
  local startingSceneColor = renderer.sceneColor
  local startingRenderState = renderer.renderState

  render(renderer, scene.runtime, scene.camera, twoBlended, nil, viewport, 0)
  Assert.equal(renderer._colorTargets, colorTargets)
  Assert.equal(renderer._stateClearTargets, stateClearTargets)
  Assert.equal(renderer._colorClearTargets, colorClearTargets)
  Assert.equal(renderer._sourceColorTargets, sourceColorTargets)
  Assert.equal(renderer._sourceMetaTargets, sourceMetaTargets)
  Assert.equal(renderer._colorTargets[1], renderer.sceneColor)
  Assert.equal(renderer._colorTargets[2], renderer.renderState)
  Assert.equal(targetDescriptor(renderer._colorTargets).depthstencil, renderer.colorDepth)
  Assert.equal(renderer.sceneColor, startingSceneColor, "an even exact swap preserves the active color canvas")
  Assert.equal(renderer.renderState, startingRenderState, "an even exact swap preserves the active state canvas")
  Assert.equal(stateClearTargets[1], renderer.renderState)
  Assert.equal(colorClearTargets[1], renderer.sceneColor)
  Assert.equal(sourceColorTargets[1], renderer._sourceColor)
  Assert.equal(sourceMetaTargets[1], renderer._sourceMeta)
  renderer:release()
end

function T.wireframe_is_submitted_once_with_edge_only_state()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  local item = passItem("wireframe", 0)

  render(
    renderer,
    litRuntime(),
    emptySceneCamera().camera,
    { { item } },
    nil,
    FieldViewport.new(640, 480, { mode = "strict" }),
    0
  )

  Assert.equal(renderer.stats.drawCalls, 1, "one wireframe item produces one mesh submission")
  Assert.equal(#lg.calls.draw, 2, "one mesh submission plus the final resolve")
  local meshDraw = lg.calls.draw[1]
  Assert.equal(meshDraw.mesh, item.mesh)
  Assert.isTrue(meshDraw.wireframe, "wireframe rasterization is enabled for the mesh")
  Assert.equal(meshDraw.depthMode, "less")
  Assert.equal(meshDraw.depthWrite, true)
  Assert.equal(meshDraw.blendMode, "replace")
  Assert.equal(meshDraw.blendAlpha, "premultiplied")
  renderer:release()
end

function T.lighting_delivery_is_independent_for_approximate_world_and_color_shaders()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  render(
    renderer,
    litRuntime(),
    emptySceneCamera().camera,
    { { passItem("translucent", 0) } },
    nil,
    FieldViewport.new(640, 480, { mode = "strict" }),
    0
  )

  Assert.equal(shaderSendCount(lg.shaders[3], "u_lightEnabled0"), 1, "world shader receives the lit profile")
  Assert.equal(shaderSendCount(lg.shaders[1], "u_lightEnabled0"), 1, "color shader receives the lit profile")
  renderer:release()
end

function T.lighting_delivery_is_independent_for_exact_source_color_shader()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg, translucencyMode = GxRenderer.TRANSLUCENCY_EXACT })
  render(
    renderer,
    litRuntime(),
    emptySceneCamera().camera,
    { { passItem("translucent", 0) } },
    nil,
    FieldViewport.new(640, 480, { mode = "strict" }),
    0
  )

  Assert.equal(shaderSendCount(lg.shaders[3], "u_lightEnabled0"), 1, "world shader receives the lit profile")
  Assert.equal(
    shaderSendCount(lg.shaders[1], "u_lightEnabled0"),
    1,
    "exact source-color shader receives the lit profile"
  )
  renderer:release()
end

function T.lighting_delivery_clears_each_shader_on_lit_to_unlit_transition()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  local runtime = litRuntime()
  local camera = emptySceneCamera().camera
  local parts = { { passItem("translucent", 0) } }
  local viewport = FieldViewport.new(640, 480, { mode = "strict" })

  render(renderer, runtime, camera, parts, nil, viewport, 0)
  runtime.lighting = nil
  render(renderer, runtime, camera, parts, nil, viewport, 0)

  Assert.equal(shaderSendCount(lg.shaders[3], "u_lightEnabled0"), 2, "world shader receives its unlit clear")
  Assert.equal(shaderSendCount(lg.shaders[1], "u_lightEnabled0"), 2, "color shader receives its unlit clear")
  renderer:release()
end

-- One opaque world item is submitted once to the shared MRT target. The
-- target's second color attachment carries render state, and the same depth
-- attachment governs both outputs.
function T.one_opaque_world_item_submits_once_to_the_shared_color_state_target()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  local item = passItem("opaque", 0)
  local scene = emptySceneCamera()

  render(renderer, scene.runtime, scene.camera, { { item } }, nil, {
    worldViewport = { x = 0, y = 0, width = 640, height = 480 },
  }, 0)

  Assert.equal(renderer.stats.drawCalls, 1, "one opaque item produces one geometry submission")
  Assert.isNil(rawget(renderer.stats, "stateDrawCalls"), "state replay is not a separate draw counter")
  Assert.equal(renderer._colorTargets[1], renderer.sceneColor, "MRT target 0 is scene color")
  Assert.equal(renderer._colorTargets[2], renderer.renderState, "MRT target 1 is render state")
  Assert.equal(
    targetDescriptor(renderer._colorTargets).depthstencil,
    renderer.colorDepth,
    "MRT uses one shared depth attachment"
  )
  renderer:release()
end

function T.mrt_target_ownership_has_no_state_shader_or_state_depth_and_rolls_back_resize_failure()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  Assert.isNil(rawget(renderer, "stateShader"), "the dedicated state shader is not owned")

  local scene = emptySceneCamera()
  local viewport = { worldViewport = { x = 0, y = 0, width = 640, height = 480 } }
  render(renderer, scene.runtime, scene.camera, nil, nil, viewport, 0)
  local previousTargets = renderer._colorTargets
  local previousColor = renderer.sceneColor
  local previousCanvasCount = #lg.canvases

  lg.setFailOnNewCanvas(#lg.canvases + 1)
  viewport.worldViewport.width = 1280
  viewport.worldViewport.height = 720
  local err = Assert.throws(function()
    render(renderer, scene.runtime, scene.camera, nil, nil, viewport, 0)
  end)
  Assert.isTrue(tostring(err):find("injected canvas failure", 1, true) ~= nil, "resize failure reaches the caller")
  Assert.equal(renderer._colorTargets, previousTargets, "the previous MRT target set remains published")
  Assert.equal(renderer.sceneColor, previousColor, "the previous scene color remains usable")
  for index = previousCanvasCount + 1, #lg.canvases do
    Assert.equal(lg.canvases[index].releaseCount, 1, "every staged canvas is released")
  end
  renderer:release()
end

-- HGSS initializes the clear/rear-plane polygon ID to the real, reachable DS
-- polygon-id value 0x3F (63) -- it is not a value carved out of the 0..63
-- domain (pokeheartgold: the field renderer's clear-buffer setup; GBATEK
-- POLYGON_ATTR polygon ID is 6 bits wide, so 63 is the largest real id, not a
-- sentinel outside it). GxRenderer must expose this as a named constant, not
-- an invented out-of-domain value like the retired REAR_PLANE_ID (255).
function T.clear_polygon_id_is_the_hgss_rear_plane_value()
  Assert.equal(GxRenderer.CLEAR_POLYGON_ID, 63, "HGSS's real clear polygon id is 0x3F (63), a reachable DS id")
end

-- The root of the "invented 255 sentinel" bug: because opaque/cutout/
-- translucent draws normalized their real polygon id by 255 while the
-- clear/rear-plane entry stamped a fixed value representing 255 in that same
-- domain, a real polygon legitimately using id 63 (the same id as the clear
-- plane) encoded to a completely different id/depth-target value than the
-- clear background -- so it always looked like a different polygon to the
-- edge predicate and spuriously outlined against empty space. Once both are
-- normalized by the true domain maximum (CLEAR_POLYGON_ID == 63), a real
-- polygon 63 and the clear background must encode to exactly the same value,
-- so the edge predicate's "different id" check correctly sees them as the
-- same polygon.
function T.a_real_polygon_63_encodes_the_same_id_value_as_the_clear_background()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local item = passItem("opaque", 0)
  item.polygonId = 63

  render(renderer, scene.runtime, scene.camera, { { item } }, nil, FieldViewport.new(640, 480, { mode = "strict" }), 0)

  -- Only the world MRT shader (shaders[3]) carries a polygon-ID uniform.
  local sentPolygonId
  for _, send in ipairs(lg.shaders[3].sends) do
    if send.name == "u_polygonId" then
      sentPolygonId = send.values[1]
    end
  end
  -- The state target's own clear call is the draw's first clear.
  local clearIdChannel = lg.calls.clear[1][1][1]
  Assert.equal(
    sentPolygonId,
    clearIdChannel,
    "a real polygon using HGSS's real clear id (63) must encode to exactly the same id/depth-target value "
      .. "as the clear background, or it spuriously edges against empty space"
  )
  renderer:release()
end

-- The opaque polygon-ID field survives translucent drawing rather
-- than being replaced by an invented sentinel (melonDS: the ID/depth
-- attribute the edge pass reads is not one value overloaded to also mean
-- "translucent"). A translucent item's own polygon ID is a distinct,
-- independent attribute -- it must send exactly the same normalization every
-- opaque/cutout item sends, by the real domain maximum (63), never a value
-- carved out of the polygon-ID domain to signal translucency.
-- An ordinary translucent item never reaches the world MRT pass at all (only
-- opaque/cutout/mixed-opaque/wireframe touch renderState -- see
-- GxRenderer:draw), so it sends no u_polygonId anywhere; this locks that it
-- is not, for example, routed through the state pass with an invented
-- sentinel ID merely because it is translucent.
function T.translucent_draws_send_their_own_polygon_id_not_an_invented_sentinel()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local item = passItem("translucent", -1)
  item.polygonId = 7

  render(renderer, scene.runtime, scene.camera, { { item } }, nil, FieldViewport.new(640, 480, { mode = "strict" }), 0)

  Assert.equal(
    shaderSendCount(lg.shaders[3], "u_polygonId"),
    0,
    "an ordinary translucent item never draws into the state pass"
  )
  renderer:release()
end

-- An ordinary field actor is not a separate sprite renderer -- FieldActorDraw.item builds the
-- exact same render-item shape terrain/building queueing does, so it must
-- reach GxRenderer's one shared _drawMesh path and send the same uniform
-- contract, carrying the ROM's own actor polygon state (modulation,
-- lightMask 1, polygonId 0, cutout alpha) rather than a hard-coded/actor-only
-- substitute. Built through the real production FieldActorDraw/
-- FieldActorFixture path, not a hand-authored item table.
function T.actor_draw_item_reaches_the_shared_world_pipeline_with_its_rom_polygon_state()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()

  local function stubMesh()
    return { setTexture = function() end }
  end
  local visual = FieldActorFixture.visual(99)
  local entry = {
    visual = visual,
    image = { id = 99 },
    meshes = { stubMesh(), stubMesh(), stubMesh(), stubMesh(), stubMesh() },
    billboardScales = { [visual.render.geometry] = { 1, 1, 1 } },
  }
  local record = {
    actorId = "map:1:object:0",
    spriteId = 99,
    world = { x = 2, y = 0, z = -6 },
    facing = "south",
    pose = "idle",
    poseTick = 0,
    visible = true,
  }
  local item = FieldActorDraw.item(record, entry)
  Assert.equal(item.alphaClass, "cutout", "the fixture's actor material is the ROM's cutout class")

  render(renderer, scene.runtime, scene.camera, { { item } }, nil, FieldViewport.new(640, 480, { mode = "strict" }), 0)

  local worldShader = lg.shaders[3]
  local sent = {}
  for _, send in ipairs(worldShader.sends) do
    sent[send.name] = send.values[1]
  end
  Assert.equal(sent.u_polygonMode, 0, "the actor's modulation material sends the modulation combiner id")
  Assert.equal(sent.u_polygonId, 0 / 63, "the actor's polygon id 0 rides the real id channel in the world MRT")
  Assert.equal(sent.u_fragmentPass, 1, "the actor's cutout class sends the color-pass cutout fragment-pass id")
  Assert.equal(sent.u_fragmentPass, 1, "the actor's cutout class sends the world MRT cutout fragment-pass id")
  Assert.deepEqual(sent.u_lightMask, GxRenderer.lightMaskUniforms(1), "light mask 1 decodes to bit 0 only")
  Assert.notNil(
    sent.u_billboardCenter,
    "the actor's billboard projection selection reaches the shared billboard branch"
  )
  Assert.equal(
    #lg.shaders,
    3,
    "the actor drew through the shared color/state shaders, no separate sprite shader was created"
  )
  renderer:release()
end

function T.billboard_draw_sends_change_driven_data_for_nonuniform_scale()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg, translucencyMode = GxRenderer.TRANSLUCENCY_EXACT })
  local scene = emptySceneCamera()
  local viewMatrix = Matrix4.multiply(Matrix4.rotateX(0.37), Matrix4.rotateY(-0.61))
  scene.camera.view = function()
    return viewMatrix
  end
  local item = passItem("opaque", 0)
  item.billboardBase = Matrix4.multiply(Matrix4.rotateZ(0.7), Matrix4.scale(2, 3, 4))
  item.transform = item.billboardBase
  item.billboardCenter, item.billboardScale = BillboardTransform.components(item.billboardBase)
  local originalTransform = item.transform

  render(renderer, scene.runtime, scene.camera, { { item } }, nil, FieldViewport.new(640, 480, { mode = "strict" }), 0)

  local sentCenter, sentScale, sentModel
  for _, send in ipairs(lg.shaders[3].sends) do
    if send.name == "u_billboardCenter" then
      sentCenter = send.values[1]
    elseif send.name == "u_billboardScale" then
      sentScale = send.values[1]
    elseif send.name == "u_model" then
      sentModel = send.values[2]
    end
  end
  Assert.equal(sentCenter, item.billboardCenter)
  Assert.equal(sentScale, item.billboardScale)
  Assert.isNil(sentModel, "ordinary billboard draws do not bind a camera-facing model matrix")
  Assert.equal(item.transform, originalTransform, "billboard drawing does not mutate the item")
  renderer:release()
end

function T.ordinary_draw_sends_the_items_precomputed_model_normal()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  local item = passItem("opaque", 0)
  item.modelNormal = { 0.5, 0, 0, 0, 1 / 3, 0, 0, 0, 0.25 }

  renderer:_drawItem(item, Matrix4.identity(), "opaque")

  local sent
  for _, send in ipairs(lg.shaders[1].sends) do
    if send.name == "u_modelNormal" then
      sent = send.values[2]
    end
  end
  Assert.equal(sent, item.modelNormal, "ordinary draws send the precomputed item field without rebuilding it")
  renderer:release()
end

function T.ordinary_draw_requires_an_explicit_model_normal()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  local item = passItem("opaque", 0)
  item.modelNormal = nil

  Assert.throws(function()
    renderer:_drawItem(item, Matrix4.identity(), "opaque")
  end)
  renderer:release()
end

-- Pass-invariant state is established once. Translucent depth mode changes
-- only when its write toggle changes in sorted order.
--
-- The corpus census found zero HGSS field materials resolving depth-equal
-- (see tests/rom/specular_shininess_census_test.lua), and the compiler-time
-- rejection contract (libs/assets/tests/polygon_state_test.lua) means a
-- compiled item can never carry depthEqual = true. The translucent pass
-- itself always compares "less", regardless of an item's depthEqual field (a
-- defensive item here still sets it, to prove the renderer no longer
-- branches on it -- not merely that the compiler happens not to produce it).
-- Host `lequal` is retired, not merely unused.
function T.draw_sets_wireframe_and_translucent_state_once_per_run()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg, translucencyMode = GxRenderer.TRANSLUCENCY_EXACT })
  local scene = emptySceneCamera()
  local items = {
    passItem("translucent", -4),
    passItem("translucent", -3),
    passItem("translucent", -2, { depthEqual = true }),
    passItem("translucent", -1, { depthEqual = true }),
    passItem("wireframe", 0),
    passItem("wireframe", 1),
  }

  render(renderer, scene.runtime, scene.camera, { items }, nil, FieldViewport.new(640, 480, { mode = "strict" }), 0)

  -- The programmable ping-pong compositor uses replace semantics for both
  -- source rasterization and composite use replace semantics. Every depth
  -- test compares "less".
  Assert.equal(callCount(lg.calls.blend, { alpha = "alphamultiply" }), 0, "compositor is the only translucent path")
  Assert.equal(
    callCount(lg.calls.blend, { mode = "alpha", alpha = "alphamultiply" }),
    0,
    "compositor is the only translucent path"
  )
  Assert.isTrue(callCount(lg.calls.blend, { mode = "replace" }) > 0, "compositor uses replace")
  Assert.isTrue(callCount(lg.calls.blend, { mode = "replace", alpha = "premultiplied" }) > 0, "compositor uses replace")
  Assert.equal(callCount(lg.calls.depth, { mode = "lequal", write = false }), 0, "lequal is retired, not merely unused")
  Assert.equal(callCount(lg.calls.depth, { mode = "lequal", write = true }), 0, "lequal is retired, not merely unused")
  Assert.equal(callCount(lg.calls.depth, { mode = "lequal" }), 0, "lequal is retired, not merely unused")
  local wireframeEnables = 0
  for _, enabled in ipairs(lg.calls.wireframe) do
    if enabled then
      wireframeEnables = wireframeEnables + 1
    end
  end
  Assert.equal(wireframeEnables, 1, "wireframe mode is enabled once for the pass")
  renderer:release()
end

-- ---- straddle resident-mesh contract (injected graphics, no love needed) ----

-- The fake makes the removed hot path observable: source vertex readback and
-- temporary mesh creation both fail immediately if a draw still performs them.
local function straddleGraphics()
  local drawCalls, shaders = {}, {}
  return {
    drawCalls = drawCalls,
    shaders = shaders,
    newShader = function()
      local shader = { sends = {} }
      shader.send = function(_, name, ...)
        shader.sends[#shader.sends + 1] = { name = name, values = { ... } }
      end
      shaders[#shaders + 1] = shader
      return shader
    end,
    newMesh = function()
      error("straddle draw must not allocate a temporary mesh")
    end,
    newCanvas = function()
      local canvas = {}
      canvas.setFilter = function() end
      canvas.release = function() end
      return canvas
    end,
    setCanvas = function() end,
    setShader = function() end,
    setDepthMode = function() end,
    setBlendMode = function() end,
    setWireframe = function() end,
    setMeshCullMode = function() end,
    clear = function() end,
    draw = function(mesh)
      drawCalls[#drawCalls + 1] = mesh
    end,
  }
end

-- A source mesh whose forbidden readback methods fail if reached.
local function sourceMesh()
  return {
    getVertexCount = function()
      error("straddle draw must not inspect source vertices")
    end,
    getVertex = function()
      error("straddle draw must not read source vertices")
    end,
    setTexture = function() end,
  }
end

local function straddleDrawItem(mesh)
  return {
    mesh = mesh,
    material = { alphaClass = "opaque", texMatrix = Matrix3.identity() },
    transform = Matrix4.identity(),
    modelNormal = { 2, 0, 0, 0, 3, 0, 0, 0, 4 },
    alphaClass = "opaque",
    cullMode = "back",
    polygonAlpha = 1.0,
    polygonMode = "modulation",
    polygonId = 0,
    lightMask = 0,
    center = { 0, 0, 0 },
    straddle = { leading = 2, transform = Matrix4.translate(10, 0, 0) },
  }
end

function T.straddle_filled_draw_uses_resident_mesh_without_readback_or_allocation()
  local fake = straddleGraphics()
  local renderer = GxRenderer.new({ graphics = fake })
  local resident = sourceMesh()
  renderer:_drawItem(straddleDrawItem(resident), Matrix4.identity(), 0)
  Assert.equal(fake.drawCalls[1], resident)
end

function T.straddle_wireframe_draw_uses_resident_mesh_without_readback_or_allocation()
  local fake = straddleGraphics()
  local renderer = GxRenderer.new({ graphics = fake })
  local resident = sourceMesh()
  renderer._activeShader = renderer.worldShader
  renderer:_drawWireframe(straddleDrawItem(resident), Matrix4.identity())
  renderer._activeShader = nil
  Assert.equal(fake.drawCalls[1], resident)
end

function T.exact_source_meta_straddle_draw_uses_resident_mesh_without_readback_or_allocation()
  local fake = straddleGraphics()
  local renderer = GxRenderer.new({ graphics = fake, translucencyMode = GxRenderer.TRANSLUCENCY_EXACT })
  local resident = sourceMesh()
  local item = straddleDrawItem(resident)
  item.material.alphaClass = "translucent"
  renderer:_ensureTargets(1, 1)

  renderer:_drawSourceItem(item, Matrix4.identity(), 1, Matrix4.identity(), 0, 1, 1)
  Assert.equal(fake.drawCalls[1], resident)
  Assert.equal(fake.drawCalls[2], resident)
end

-- ---- wireframe polygon-id/opaque-classification semantics ----
--
-- The DS draws polygon alpha zero (wireframe) as ordinary opaque geometry
-- with its own real POLYGON_ATTR polygon id -- there is no separate
-- "wireframe id" register on real hardware. The renderer must send that same
-- real id, never a value invented to mean "this is a wireframe/rear-plane
-- draw" (see GxRenderer.CLEAR_POLYGON_ID for the one real DS sentinel value,
-- which is a legitimate polygon id, not a wireframe-specific one). Only the
-- world MRT wireframe draw carries a polygon-ID uniform -- the color shader
-- does not own any ID/fog-gate output.
function T.wireframe_draw_sends_its_own_real_polygon_id_not_an_invented_sentinel()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  local item = passItem("wireframe", 0)
  item.polygonId = 37

  renderer._activeShader = renderer.worldShader
  renderer:_drawWireframe(item, Matrix4.identity())
  renderer._activeShader = nil

  local sent
  for _, send in ipairs(lg.shaders[3].sends) do
    if send.name == "u_polygonId" then
      sent = send.values[1]
    end
  end
  Assert.equal(sent, item.polygonId / 63, "a wireframe draw sends its own real polygon id, never a sentinel")
  renderer:release()
end

-- GBATEK: "Edge Marking is applied ONLY to opaque polygons (including
-- wire-frames)" -- a wireframe draw must be classified as opaque for the
-- fragment-pass uniform the edge/fog final pass keys on (never the
-- cutout/mixed-opaque discard branches). This locks a contract the renderer
-- already satisfies structurally so a later refactor cannot regress it
-- silently. Both the color and state wireframe draw bodies always send the
-- opaque fragment-pass id.
function T.wireframe_draw_is_opaque_classified_for_edge_marking()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  local item = passItem("wireframe", 0)

  renderer:_drawWireframe(item, Matrix4.identity())
  local colorSent = {}
  for _, send in ipairs(lg.shaders[1].sends) do
    colorSent[send.name] = send.values[1]
  end
  Assert.equal(colorSent.u_fragmentPass, 0, "a color-pass wireframe draw sends the opaque fragment-pass id")
  renderer:release()
end

-- The renderState render-target contract's blue channel is the per-polygon
-- fog gate (item.fogEnabled), not a separate "translucent identity" flag --
-- the old u_translucentAttribute uniform is retired outright, not merely
-- unread, for every draw kind (opaque, cutout, translucent, wireframe
-- alike). A stray send of the retired uniform is exactly the kind of silent
-- regression this locks: a shader still reading it would compile and render,
-- so only an explicit "never sent" assertion catches its reintroduction.
function T.draws_never_send_the_retired_translucent_attribute_uniform()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local opaqueItem = passItem("opaque", 0)
  local cutoutItem = passItem("cutout", 0)
  local translucentItem = passItem("translucent", -1)
  local wireframeItem = passItem("wireframe", 0)

  render(
    renderer,
    scene.runtime,
    scene.camera,
    { { opaqueItem, cutoutItem, translucentItem, wireframeItem } },
    nil,
    FieldViewport.new(640, 480, { mode = "strict" }),
    0
  )

  Assert.equal(
    shaderSendCount(lg.shaders[1], "u_translucentAttribute"),
    0,
    "the map shader is never sent the retired translucent-attribute uniform"
  )
  renderer:release()
end

-- World items, actor billboards, and field effects share one projection
-- selection boundary. The single MRT pass records each output with that
-- projection.
function T.field_effects_share_the_depth_biased_projection_with_billboards()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  local worldProjection = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
  local billboardProjection = { 2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2 }
  scene.camera.projection = function()
    return worldProjection
  end
  scene.camera.billboardProjection = function()
    return billboardProjection
  end

  local ordinary = passItem("opaque", 0)
  local billboard = passItem("opaque", 0)
  billboard.billboardCenter = { 0, 0, -5 }
  billboard.billboardScale = { 1, 1, 1 }
  billboard.billboardProjection = true
  local entrance = passItem("opaque", 0)
  entrance.worldSpace = true
  entrance.fieldEffect = "warp_entrance"

  render(
    renderer,
    scene.runtime,
    scene.camera,
    { { ordinary, billboard, entrance } },
    nil,
    FieldViewport.new(640, 480, { mode = "strict" }),
    0
  )

  local function projectionsSentBy(shader)
    local sent = {}
    for _, send in ipairs(shader.sends) do
      if send.name == "u_proj" then
        sent[#sent + 1] = send.values[2]
      end
    end
    return sent
  end

  local worldProjections = projectionsSentBy(lg.shaders[3])
  Assert.deepEqual(
    worldProjections,
    { worldProjection, billboardProjection, billboardProjection },
    "MRT world pass: ordinary, billboard, then field effect"
  )
  renderer:release()
end

-- The field camera selects DS Z buffering (GX_BUFFERMODE_Z), so the world MRT
-- shader derives depth from the fragment's normalized window depth; the
-- retired camera-far depth-normalization uniform must not be sent to the
-- world MRT (or any pass) anymore. The world shader is lg.shaders[3] (the
-- color/resolve shaders are shaders[1]/shaders[2]).
function T.draw_never_sends_the_retired_depth_normalization_uniform()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg })
  local scene = emptySceneCamera()
  scene.camera.far = 123.5

  render(renderer, scene.runtime, scene.camera, nil, nil, FieldViewport.new(640, 480, { mode = "strict" }), 0)

  Assert.equal(shaderSendCount(lg.shaders[1], "u_depthWMax"), 0, "the color shader never receives the retired uniform")
  Assert.equal(
    shaderSendCount(lg.shaders[2], "u_depthWMax"),
    0,
    "the final-pass shader never receives the retired uniform"
  )
  Assert.equal(
    shaderSendCount(lg.shaders[3], "u_depthWMax"),
    0,
    "the state shader derives depth from window depth, not a far-plane normalization"
  )
  renderer:release()
end

-- The DS Z conversion -- windowZ -> ndcZ = 2*windowZ - 1, ndcZ scaled by
-- 0x4000 with truncation toward zero (GLSL int() truncates, so a fractional
-- negative NDC must not floor), offset by 0x3FFF, scaled by 0x200, clamped
-- to 0..0xFFFFFF -- as a pure table, independently hand-computed (never
-- calling the production shader). Anchors: the near plane clamps to 0; the
-- exact midpoint 0.5 maps to 0x7FFE00 (the +0x3FFF offset); the far plane 1
-- maps to 0xFFFE00, distinct from the 0xFFFFFF clear/rear-plane value; the
-- negative-NDC fractional case 0.4 truncates -3276.8 to -3276 (0x666600),
-- not floor's -3277 (0x665E00).
function T.field_depth_conversion_table_matches_the_ds_z_formula()
  local function trunc(x)
    return x >= 0 and math.floor(x) or math.ceil(x)
  end
  local function dsZ(windowZ)
    local ndc = windowZ * 2 - 1
    local ndc14 = trunc(ndc * 0x4000)
    local depth = (ndc14 + 0x3FFF) * 0x200
    if depth < 0 then
      depth = 0
    elseif depth > 0xFFFFFF then
      depth = 0xFFFFFF
    end
    return depth
  end

  Assert.equal(dsZ(0), 0, "windowZ=0 maps to DS depth 0 after clamping the signed formula")
  Assert.equal(dsZ(0.5), 0x7FFE00, "windowZ=0.5 maps to the exact midpoint depth 0x7FFE00")
  Assert.equal(dsZ(1), 0xFFFE00, "windowZ=1 maps to 0xFFFE00 -- the DS far value, below the 0xFFFFFF clear/rear plane")
  Assert.equal(dsZ(0.4), 0x666600, "windowZ=0.4 (ndc*0x4000 = -3276.8) truncates to -3276 -> 0x666600")
  Assert.equal(dsZ(0) < dsZ(0.5) and dsZ(0.5) < dsZ(1), true, "the mapping is monotonic across the anchors")
end

-- Translucency mode contracts are exercised through GxRenderer:draw with the
-- same fake graphics boundary used by the production renderer tests. These
-- scenarios intentionally observe resource roles and draw sequencing, not
-- private helper calls.
local function translucentItems(count)
  local items = {}
  for index = 1, count do
    items[index] = passItem("translucent", -index)
  end
  return items
end

local function drawTranslucentFrame(renderer, scene, items)
  render(renderer, scene.runtime, scene.camera, { items }, nil, FieldViewport.new(1920, 1080, { mode = "expanded" }), 0)
end

function T.default_translucency_uses_direct_alpha_and_no_exact_resources()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg, worldRasterScale = 2 })
  local scene = emptySceneCamera()

  Assert.equal(renderer.translucencyMode, GxRenderer.TRANSLUCENCY_APPROXIMATE)
  Assert.isNil(renderer.sourceShader, "default mode does not construct the exact source shader")
  Assert.isNil(renderer.compositeShader, "default mode does not construct the exact composite shader")
  drawTranslucentFrame(renderer, scene, translucentItems(1))
  Assert.equal(callCount(lg.calls.blend, { mode = "alpha", alpha = "alphamultiply" }), 1)
  Assert.isNil(renderer._sourceColor, "default mode does not allocate source color")
  Assert.isNil(renderer._sourceMeta, "default mode does not allocate source metadata")
  renderer:release()
end

-- The approximate blended pass must bind the renderer-owned single-color and
-- depth descriptor, not an equivalent frame-local setup table. The third-from-
-- last canvas bind is the blended pass; the final two binds restore the
-- presentation target and the caller's canvas.
function T.approximate_blended_pass_binds_the_renderer_owned_descriptor()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg, worldRasterScale = 2 })
  local scene = emptySceneCamera()

  drawTranslucentFrame(renderer, scene, translucentItems(1))

  local approximateTargets = lg.calls.canvas[#lg.calls.canvas - 2]
  Assert.equal(approximateTargets, renderer._colorClearTargets, "approximate pass uses the persistent descriptor")
  Assert.equal(approximateTargets[1], renderer.sceneColor, "descriptor color follows the active scene color")
  Assert.equal(
    targetDescriptor(approximateTargets).depthstencil,
    renderer.colorDepth,
    "descriptor depth follows the color depth"
  )
  renderer:release()
end

-- The descriptor lifetime follows target generations: repeated same-size
-- blended frames reuse it, while a raster-size change publishes one replacement.
function T.approximate_blended_frames_reuse_descriptor_until_resize()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg, worldRasterScale = 2 })
  local scene = emptySceneCamera()
  local viewport = FieldViewport.new(1920, 1080, { mode = "expanded" })
  local function drawAndRecord()
    render(renderer, scene.runtime, scene.camera, { translucentItems(1) }, nil, viewport, 0)
    return lg.calls.canvas[#lg.calls.canvas - 2]
  end

  local firstDescriptor = drawAndRecord()
  Assert.equal(firstDescriptor, renderer._colorClearTargets, "first blended frame uses its generation descriptor")
  local secondDescriptor = drawAndRecord()
  local thirdDescriptor = drawAndRecord()
  Assert.equal(secondDescriptor, firstDescriptor, "same-size second frame reuses the descriptor")
  Assert.equal(thirdDescriptor, firstDescriptor, "same-size third frame reuses the descriptor")

  local resizedViewport = FieldViewport.new(1280, 800, { mode = "expanded" })
  local function drawResizedAndRecord()
    render(renderer, scene.runtime, scene.camera, { translucentItems(1) }, nil, resizedViewport, 0)
    return lg.calls.canvas[#lg.calls.canvas - 2]
  end
  local resizedDescriptor = drawResizedAndRecord()
  Assert.isTrue(resizedDescriptor ~= firstDescriptor, "resize publishes a new generation descriptor")
  Assert.equal(resizedDescriptor, renderer._colorClearTargets, "resized frame uses the new persistent descriptor")
  Assert.equal(resizedDescriptor[1], renderer.sceneColor, "resized descriptor color follows the new scene color")
  Assert.equal(
    targetDescriptor(resizedDescriptor).depthstencil,
    renderer.colorDepth,
    "resized descriptor depth follows the new color depth"
  )
  Assert.equal(drawResizedAndRecord(), resizedDescriptor, "same-size frame after resize reuses the replacement")
  renderer:release()
end

function T.unknown_translucency_mode_is_rejected()
  local lg = fakeGraphics()
  Assert.throws(function()
    GxRenderer.new({ graphics = lg, translucencyMode = "unsupported" })
  end)
  Assert.equal(#lg.shaders, 0, "invalid mode fails before acquiring shaders")
end

function T.approximate_full_screen_work_is_constant_as_blended_count_grows()
  local function drawCount(itemCount)
    local lg = fakeGraphics()
    local renderer = GxRenderer.new({ graphics = lg, worldRasterScale = 2 })
    local scene = emptySceneCamera()
    drawTranslucentFrame(renderer, scene, translucentItems(itemCount))
    local count = lg.getDrawCalls()
    renderer:release()
    return count
  end

  local one = drawCount(1)
  local many = drawCount(32)
  Assert.equal(many - one, 31, "additional approximate entries add geometry only")
end

function T.explicit_exact_mode_preserves_the_programmable_translucency_path()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg, translucencyMode = GxRenderer.TRANSLUCENCY_EXACT })
  local scene = emptySceneCamera()

  Assert.equal(renderer.translucencyMode, GxRenderer.TRANSLUCENCY_EXACT)
  Assert.notNil(renderer.sourceShader)
  Assert.notNil(renderer.compositeShader)
  drawTranslucentFrame(renderer, scene, translucentItems(1))
  Assert.equal(callCount(lg.calls.blend, { mode = "replace", alpha = "premultiplied" }) > 0, true)
  Assert.equal(callCount(lg.calls.blend, { mode = "alpha", alpha = "alphamultiply" }), 0)
  renderer:release()
end

function T.exact_mode_is_selected_through_normal_construction_and_retains_resources()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg, translucencyMode = GxRenderer.TRANSLUCENCY_EXACT })

  Assert.equal(renderer.translucencyMode, GxRenderer.TRANSLUCENCY_EXACT)
  Assert.notNil(renderer.sourceShader, "exact source shader is live runtime code")
  Assert.notNil(renderer.compositeShader, "exact composite shader is live runtime code")
  local scene = emptySceneCamera()
  drawTranslucentFrame(renderer, scene, translucentItems(1))
  Assert.notNil(renderer._sourceColor)
  Assert.notNil(renderer._sourceMeta)
  renderer:release()
end

function T.exact_mode_uses_compact_metadata_without_source_color_clear()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg, translucencyMode = GxRenderer.TRANSLUCENCY_EXACT })
  local scene = emptySceneCamera()

  drawTranslucentFrame(renderer, scene, translucentItems(1))
  local sourceMeta = assert(renderer._sourceMeta) --[[@as GxRendererTest.Canvas]]
  local sourceColor = assert(renderer._sourceColor) --[[@as GxRendererTest.Canvas]]
  local sourceMetaOptions = assert(sourceMeta.canvasOpts)
  Assert.equal(sourceMetaOptions.format, "rgba8", "source metadata is normalized 8-bit storage")
  Assert.equal(sourceColor.canvasOpts and sourceColor.canvasOpts.format, nil)
  Assert.equal(callCount(lg.calls.clear, {}), 3, "one state clear, one color clear, and one source metadata clear")
  renderer:release()
end

function T.integrated_default_cost_shape_stays_bounded_at_1080p()
  local lg = fakeGraphics()
  local renderer = GxRenderer.new({ graphics = lg, worldRasterScale = 2 })
  local scene = emptySceneCamera()
  local items = { passItem("opaque", 0) }
  for _, item in ipairs(translucentItems(32)) do
    items[#items + 1] = item
  end

  drawTranslucentFrame(renderer, scene, items)
  Assert.equal(renderer.colorW, 683)
  Assert.equal(renderer.colorH, 384)
  Assert.isNil(renderer._sourceColor)
  Assert.isNil(renderer._sourceMeta)
  Assert.equal(renderer.stats.drawCalls, 33, "one opaque and one direct translucent submission per item")
  renderer:release()
end

return { tests = T }
