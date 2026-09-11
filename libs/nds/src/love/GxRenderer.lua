-- Draws a loaded runtime scene through a bounded world-raster pass and a
-- native-resolution presentation billboard stage.
-- The world color/state/depth targets share bounded dimensions; ordinary
-- opaque/cutout actor billboards resolve the world first and draw directly to
-- the host window without writing world renderState or receiving world edges.
--
-- The HGSS presentation owner builds the world render queue exactly once per
-- frame and supplies it here. The world MRT pass consumes it. Opaque, cutout, and mixed-opaque
-- fragments stamp the active color and renderState MRT atomically:
-- ID, DS-quantized depth, and per-polygon fog gate. Ordinary translucent and
-- mixed-translucent fragments never touch the state target directly in the
-- exact compositor. Approximate mode changes world color only with host
-- alpha blending; exact mode additionally maintains last translucent ID,
-- fog-gate AND, and the retained state semantics. The final
-- resolve (edge.glsl) samples sceneColor as its own
-- texture and the same bounded-resolution renderState through explicit
-- snap/clamp to render-state pixel centers (never texture-clamp reliance),
-- probing the four orthogonal neighbors at a distance of one integer edge
-- radius computed from the world target height and camera zoom, and
-- applies, in order: edge marking, fog, then the project's current antialias
-- approximation (50% mix of fogged candidates -- not exact hardware
-- lower-pixel coverage). Both candidates share the center state's single
-- depth/fog state; fog alpha is resolved before the mix.
--
-- A straddling draw is presented as a whole resident mesh under its current
-- transform. Resource
-- construction is transactional: a failed shader,
-- canvas allocation, or target configuration releases everything already
-- created, and a canvas recreation keeps the previous target set usable until
-- the replacement is complete. It restores the exact caller state it changed
-- (canvas, shader, depth, cull, blend, wireframe, color) even when drawing
-- raises, so the diagnostic UI drawn afterwards is unaffected. It builds no
-- persistent meshes or textures and reads no ROM/NARC data -- those belong to
-- the loader and compiler; here everything is already resident.

local Matrix3 = require("libs.math.src.Matrix3")
local AlphaClassifier = require("libs.nds.src.gx.AlphaClassifier")
local FixedPoint = require("libs.math.src.FixedPoint")

---@class GxRenderer.Canvas : love.Canvas
---@field setFilter fun(self: GxRenderer.Canvas, min: string, mag: string)
---@field release fun(self: GxRenderer.Canvas)
---@field getWidth fun(self: GxRenderer.Canvas): integer
---@field getHeight fun(self: GxRenderer.Canvas): integer
---@class GxRenderer.Shader
---@field send fun(self: GxRenderer.Shader, name: string, ...)
---@field release fun(self: GxRenderer.Shader)
---@class GxRenderer.TargetDescriptor
---@field [1] GxRenderer.Canvas
---@field [2]? GxRenderer.Canvas
---@field depthstencil GxRenderer.Canvas
---@alias GxRenderer.RenderTarget GxRenderer.Canvas|GxRenderer.TargetDescriptor
---@class GxRenderer.Graphics
---@field newShader fun(source: string): GxRenderer.Shader
---@field newCanvas fun(width: integer, height: integer, opts?: table<string, unknown>): GxRenderer.Canvas
---@field setCanvas fun(...: GxRenderer.RenderTarget?)
---@field getCanvas fun(): GxRenderer.RenderTarget?
---@field setShader fun(shader?: GxRenderer.Shader|love.Shader)
---@field setDepthMode fun(mode?: string, write?: boolean)
---@field setBlendMode fun(mode?: string, alpha?: string)
---@field setColor fun(red: number, green: number, blue: number, alpha: number)
---@field draw fun(drawable: table<string, unknown>, ...)
---@field clear fun(...)
---@field getDimensions fun(): integer, integer
---@field getBlendMode fun(): string?, string?
---@field getDepthMode fun(): string?, boolean?
---@field getShader fun(): (GxRenderer.Shader|love.Shader)?
---@field getColor fun(): number, number, number, number
---@field getMeshCullMode fun(): string?
---@field setMeshCullMode fun(mode?: string)
---@field isWireframe fun(): boolean
---@field setWireframe fun(enabled: boolean)
---@class GxRenderer
---@field _graphics GxRenderer.Graphics
---@field clearColor number[]
---@field shader GxRenderer.Shader|love.Shader
---@field spriteShader GxRenderer.Shader|love.Shader
---@field _spriteShaderSource string
---@field worldShader GxRenderer.Shader|love.Shader
---@field edgeShader GxRenderer.Shader|love.Shader
---@field _edgeColorsCache number[][]
---@field _edgeColorsProfile table<integer, integer>?
---@field _fogColorCache number[]
---@field _fogTableCache number[][]
---@field _fogFinalReference table<string, unknown>?
---@field _fogSpriteReference table<string, unknown>?
---@field stats { drawCalls: integer, colorDrawCalls: integer, triangles: integer, meshCount: integer, textureCount: integer }
---@field sceneColor GxRenderer.Canvas?
---@field colorDepth GxRenderer.Canvas?
---@field renderState GxRenderer.Canvas?
---@field _spareColor GxRenderer.Canvas?
---@field _spareState GxRenderer.Canvas?
---@field _sourceColor GxRenderer.Canvas?
---@field _sourceMeta GxRenderer.Canvas?
---@field colorW integer?
---@field colorH integer?
---@field stateW integer?
---@field stateH integer?
---@field _colorTargets GxRenderer.TargetDescriptor?
---@field _stateClearTargets GxRenderer.TargetDescriptor?
---@field _colorClearTargets GxRenderer.TargetDescriptor?
---@field _sourceColorTargets GxRenderer.TargetDescriptor?
---@field _sourceMetaTargets GxRenderer.TargetDescriptor?
---@field _lightMaterialColorCache { diffuse: number[], ambient: number[], specular: number[], emission: number[] }
---@field _lightVectorCache number[][]
---@field _lightColorCache number[][]
---@field _lightingDelivery table<GxRenderer.Shader, { lit: boolean, profile: table<string, unknown>?, record: table<string, unknown>? }>
---@field _presentationScale number[]
---@field _presentationOffset number[]
---@field worldRasterScale number?
---@field translucencyMode "approximate"|"exact"
local GxRenderer = {}
GxRenderer.__index = GxRenderer

GxRenderer.TRANSLUCENCY_APPROXIMATE = "approximate"
GxRenderer.TRANSLUCENCY_EXACT = "exact"

-- Shader sources are NDS LÖVE assets colocated with this module, addressed by
-- repo-relative path -- the same namespace as every `require`. They are read
-- through the LÖVE resource boundary: love.filesystem resolves the paths from
-- the archive root when the game ships as a .love or fused executable, and
-- in the repo checkout, where the app runs as `love app/` and the library
-- tree sits outside that source mount, from the host file under the source
-- base directory. `opts.readSource` injects the reader so construction is
-- testable headless without any filesystem.
local SHADER_SOURCE_PATHS = {
  color = "libs/nds/src/love/shaders/map.glsl",
  resolve = "libs/nds/src/love/shaders/edge.glsl",
  source = "libs/nds/src/love/shaders/source.glsl",
  composite = "libs/nds/src/love/shaders/composite.glsl",
}

---@param path string
---@return string
local function defaultReadSource(path)
  if love and love.filesystem then
    local source = love.filesystem.read(path)
    if source then
      return source
    end
    local base = love.filesystem.getSourceBaseDirectory()
    local f = io.open(base .. "/" .. path, "rb")
    if f then
      local src = f:read("*a")
      f:close()
      return src
    end
  end
  error("cannot read shader source: " .. path)
end

-- Fallback scene clear color for callers that do not inject one (e.g. unit
-- tests exercising draw behavior unrelated to background color). Production
-- always injects the game's own color (see GxRenderer.new opts.clearColor);
-- the NDS renderer must not import game-level config, so this default is its
-- own and intentionally distinct from any game-chosen value.
local DEFAULT_CLEAR_COLOR = { 0, 0, 0, 1 }
local IDENTITY_MODEL_NORMAL = Matrix3.identity()

-- 24-bit rear-plane depth: the maximum value the shader's quantized
-- depth domain can represent.
local DS_DEPTH_MAX = 0xFFFFFF

-- melonDS's RenderFogOffset latch (src/GPU3D.cpp): the raw G3X FOG_OFFSET
-- register is multiplied by this scale once per frame, not per pixel, before
-- reaching the final pass's density calculation (edge.glsl's u_fogOffsetDepth).
local FOG_OFFSET_TO_DEPTH_SCALE = 0x200

-- Rear-plane entry for the renderState target: HGSS's real clear polygon ID
-- (GxRenderer.CLEAR_POLYGON_ID, 63) at the farthest quantized depth
-- (DS_DEPTH_MAX), with its fog gate false -- HGSS's rear plane is not itself
-- fog-gated. Clearing depth to the maximum makes background neighbours read
-- as farther than any real geometry -- that is what outlines silhouettes
-- against the background (GBATEK: at the screen borders edges are resolved
-- against the rear plane's polygon_id). Normalized by the same
-- CLEAR_POLYGON_ID domain maximum every real draw uses (63/63 == 1.0), so a
-- real id-63 polygon is indistinguishable from the background, exactly as
-- GBATEK specifies. This exact table is also edge.glsl's rearPlaneState
-- constant, hand-mirrored there (GLSL has no cross-source include). The alpha
-- channel is the last-translucent-ID encoding: 0 means no accepted translucent
-- overlay yet (the clear/rear plane never has one).
local DS_STATE_CLEAR = { 1, DS_DEPTH_MAX, 0, 0 }

-- Polygon-ID domain (GBATEK POLYGON_ATTR polygon ID, 6-bit 0..63). HGSS
-- initializes the rear/clear plane's polygon ID to 0x3F (63) -- a real,
-- reachable id, not a sentinel outside the domain. Every draw (opaque,
-- cutout, mixed, and wireframe alike) sends its own real polygon ID,
-- normalized by this same domain maximum (id/63; map.glsl and edge.glsl
-- document the encoding/decoding). PolygonState already validates that
-- source polygon ids are integers in 0..63, so this module does not
-- duplicate that validation with its own MAX_POLYGON_ID constant.
GxRenderer.CLEAR_POLYGON_ID = 63

-- Color-pass fragment-pass ids (map.glsl's u_fragmentPass): exact alpha5
-- discard predicates, never a float-epsilon comparison.
local FRAGMENT_PASS_OPAQUE = 0
local FRAGMENT_PASS_CUTOUT = 1
local FRAGMENT_PASS_TRANSLUCENT = 2
local FRAGMENT_PASS_MIXED_OPAQUE = 3
local FRAGMENT_PASS_MIXED_TRANSLUCENT = 4

-- World MRT uses the same fragment-pass ids as the color-only shader.
local function validateWorldRasterScale(scale)
  assert(
    scale == nil
      or (type(scale) == "number" and scale > 0 and scale == scale and scale ~= math.huge and scale ~= -math.huge),
    "world raster scale must be finite and > 0, got " .. tostring(scale)
  )
  return scale
end

---@param displayWidth number
---@param displayHeight number
---@param scale number?
---@return integer, integer
function GxRenderer.worldRasterDimensions(displayWidth, displayHeight, scale)
  assert(displayWidth > 0 and displayHeight > 0)
  validateWorldRasterScale(scale)
  if scale == nil then
    return math.max(1, math.floor(displayWidth + 0.5)), math.max(1, math.floor(displayHeight + 0.5))
  end
  local worldH = math.min(displayHeight, scale * 192)
  local worldW = math.min(displayWidth, math.floor(displayWidth * worldH / displayHeight + 0.5))
  return math.max(1, worldW), math.max(1, math.floor(worldH + 0.5))
end

---@param opts table<string, unknown>?
---@return GxRenderer
function GxRenderer.new(opts)
  opts = opts or {}
  ---@type GxRenderer.Graphics|love.Graphics|love.graphics|nil
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics, "GxRenderer requires a graphics context")
  local translucencyMode = opts.translucencyMode or GxRenderer.TRANSLUCENCY_APPROXIMATE
  assert(
    translucencyMode == GxRenderer.TRANSLUCENCY_APPROXIMATE or translucencyMode == GxRenderer.TRANSLUCENCY_EXACT,
    "invalid translucency mode: " .. tostring(translucencyMode)
  )
  local worldRasterScale = validateWorldRasterScale(opts.worldRasterScale)
  local readSource = opts.readSource or defaultReadSource
  local renderer = setmetatable({
    _graphics = graphics,
    translucencyMode = translucencyMode,
    worldRasterScale = worldRasterScale,
    clearColor = opts.clearColor or DEFAULT_CLEAR_COLOR,
    _edgeColorsCache = {
      { 0, 0, 0 },
      { 0, 0, 0 },
      { 0, 0, 0 },
      { 0, 0, 0 },
      { 0, 0, 0 },
      { 0, 0, 0 },
      { 0, 0, 0 },
      { 0, 0, 0 },
    },
    _edgeColorsProfile = nil,
    _fogColorCache = { 0, 0, 0 },
    _fogTableCache = {
      { 0, 0, 0, 0 },
      { 0, 0, 0, 0 },
      { 0, 0, 0, 0 },
      { 0, 0, 0, 0 },
      { 0, 0, 0, 0 },
      { 0, 0, 0, 0 },
      { 0, 0, 0, 0 },
      { 0, 0, 0, 0 },
    },
    _fogFinalReference = nil,
    _fogSpriteReference = nil,
    stats = { drawCalls = 0, colorDrawCalls = 0, triangles = 0, meshCount = 0, textureCount = 0 },
    _lightMaterialColorCache = {
      diffuse = { 0, 0, 0 },
      ambient = { 0, 0, 0 },
      specular = { 0, 0, 0 },
      emission = { 0, 0, 0 },
    },
    _lightVectorCache = {
      { 0, 0, 0 },
      { 0, 0, 0 },
      { 0, 0, 0 },
      { 0, 0, 0 },
    },
    _lightColorCache = {
      { 0, 0, 0 },
      { 0, 0, 0 },
      { 0, 0, 0 },
      { 0, 0, 0 },
    },
    _lightingDelivery = {},
    _presentationScale = { 1, 1 },
    _presentationOffset = { 0, 0 },
  }, GxRenderer)
  -- Shader construction is transactional: a failure while creating a later
  -- shader (or reading its source) releases every one already created before
  -- the error propagates, so a failed renderer never leaks GPU resources.
  local ok, err = pcall(function()
    local colorSource = readSource(SHADER_SOURCE_PATHS.color)
    renderer.shader = graphics.newShader(colorSource)
    renderer._spriteShaderSource = "#define PRESENTATION_SPRITE\n" .. colorSource
    renderer.edgeShader = graphics.newShader(readSource(SHADER_SOURCE_PATHS.resolve))
    renderer.worldShader = graphics.newShader("#define WORLD_MRT\n" .. colorSource)
    if translucencyMode == GxRenderer.TRANSLUCENCY_EXACT then
      renderer.sourceShader = graphics.newShader(readSource(SHADER_SOURCE_PATHS.source))
      renderer.compositeShader = graphics.newShader(readSource(SHADER_SOURCE_PATHS.composite))
    end
  end)
  if not ok then
    renderer:release()
    error(err)
  end
  return renderer
end

function GxRenderer:_ensureSpriteShader()
  if self.spriteShader then
    return self.spriteShader
  end
  local shader = self._graphics.newShader(self._spriteShaderSource)
  self.spriteShader = shader
  return shader
end

function GxRenderer:_releaseTargets()
  if self.sceneColor then
    self.sceneColor:release()
  end
  if self.colorDepth then
    self.colorDepth:release()
  end
  if self.renderState then
    self.renderState:release()
  end
  if self._spareColor then
    self._spareColor:release()
  end
  if self._spareState then
    self._spareState:release()
  end
  if self._sourceColor then
    self._sourceColor:release()
  end
  if self._sourceMeta then
    self._sourceMeta:release()
  end
  self.sceneColor, self.colorDepth, self.renderState = nil, nil, nil
  self._spareColor, self._spareState = nil, nil
  self._sourceColor, self._sourceMeta = nil, nil
  self.colorW, self.colorH, self.stateW, self.stateH = nil, nil, nil, nil
  self._colorTargets = nil
  self._stateClearTargets = nil
  self._colorClearTargets = nil
  self._sourceColorTargets = nil
  self._sourceMetaTargets = nil
end

local function sendStateUniforms(shader, renderState, stateW, stateH)
  shader:send("u_renderState", renderState)
  shader:send("u_stateSize", { stateW, stateH })
end

-- Recreate every render target at new dimensions. All canvases are allocated
-- and configured into local staged variables before anything published is
-- touched. A failure releases only that incomplete generation and leaves the
-- previous target set and its recorded dimensions untouched.
function GxRenderer:_ensureTargets(colorW, colorH)
  if
    self.sceneColor
    and self.colorW == colorW
    and self.colorH == colorH
    and self.stateW == colorW
    and self.stateH == colorH
  then
    return
  end
  local lg = assert(self._graphics)
  local sceneColor, colorDepth, renderState
  local spareColor, spareState, sourceColor, sourceMeta
  local colorTargets, stateClearTargets, colorClearTargets
  local sourceColorTargets, sourceMetaTargets
  local ok, err = pcall(function()
    sceneColor = lg.newCanvas(colorW, colorH)
    -- Nearest sampling keeps the final composite draw (a 1:1 blit at
    -- presentation resolution) from introducing interpolation of its own.
    sceneColor:setFilter("nearest", "nearest")
    colorDepth = lg.newCanvas(colorW, colorH, { format = "depth24stencil8", readable = false })

    -- renderState: red the normalized opaque edge polygon ID, green the
    -- DS Z-buffer depth (a 24-bit integer domain, stored as a
    -- float -- see dsZbufferDepth in map.glsl), blue the per-polygon fog
    -- gate, alpha the last-translucent-ID encoding (0 = none, (id+1)/64).
    -- The state canvas shares the color canvas's exact dimensions: state
    -- classification is never deliberately downsampled, and the final resolve
    -- probes this same-resolution state at a sampling distance of one integer
    -- edge radius. The format must be 32-bit float: the quantized depth spans
    -- the full 24-bit domain, which 16-bit floats cannot resolve exactly.
    renderState = lg.newCanvas(colorW, colorH, { format = "rgba32f" })
    renderState:setFilter("nearest", "nearest")
    colorTargets = { sceneColor, renderState, depthstencil = colorDepth }
    stateClearTargets = { renderState, depthstencil = colorDepth }
    colorClearTargets = { sceneColor, depthstencil = colorDepth }

    if self.translucencyMode == GxRenderer.TRANSLUCENCY_EXACT then
      -- Exact mode alternates one spare destination pair with the active pair.
      spareColor = lg.newCanvas(colorW, colorH)
      spareColor:setFilter("nearest", "nearest")
      spareState = lg.newCanvas(colorW, colorH, { format = "rgba32f" })
      spareState:setFilter("nearest", "nearest")

      -- Exact source metadata uses rgba8. The ID encoding in source.glsl is
      -- (id + 1) / 64, so every 6-bit ID survives normalized storage.
      sourceColor = lg.newCanvas(colorW, colorH)
      sourceColor:setFilter("nearest", "nearest")
      sourceMeta = lg.newCanvas(colorW, colorH, { format = "rgba8" })
      sourceMeta:setFilter("nearest", "nearest")
      sourceColorTargets = { sourceColor, depthstencil = colorDepth }
      sourceMetaTargets = { sourceMeta, depthstencil = colorDepth }
    end
  end)
  if not ok then
    for _, canvas in ipairs({
      sceneColor,
      colorDepth,
      renderState,
      spareColor,
      spareState,
      sourceColor,
      sourceMeta,
    }) do
      if canvas then
        pcall(canvas.release, canvas)
      end
    end
    error(err)
  end
  self:_releaseTargets()
  self.sceneColor, self.colorDepth, self.renderState = sceneColor, colorDepth, renderState
  self._spareColor, self._spareState = spareColor, spareState
  self._sourceColor, self._sourceMeta = sourceColor, sourceMeta
  self.colorW, self.colorH, self.stateW, self.stateH = colorW, colorH, colorW, colorH
  self._colorTargets = colorTargets
  self._stateClearTargets = stateClearTargets
  self._colorClearTargets = colorClearTargets
  self._sourceColorTargets = sourceColorTargets
  self._sourceMetaTargets = sourceMetaTargets
end

-- Decode every polygon 4-bit light mask (GBATEK POLYGON_ATTR bits 0-3) once.
-- The shader gates each profile light with one component, and the renderer
-- treats these shared values as immutable.
local LIGHT_MASK_UNIFORMS = {}
for mask = 0, 15 do
  LIGHT_MASK_UNIFORMS[mask] = {
    mask % 2 >= 1 and 1.0 or 0.0,
    mask % 4 >= 2 and 1.0 or 0.0,
    mask % 8 >= 4 and 1.0 or 0.0,
    mask % 16 >= 8 and 1.0 or 0.0,
  }
end

-- Public validation helper for test-facing/item-construction code. Draw paths
-- index the immutable precomputed mask directly and allocate nothing; callers
-- receive their own copy and cannot mutate that render-path cache.
---@param m integer
---@return number[]
function GxRenderer.lightMaskUniforms(m)
  local uniform = type(m) == "number" and LIGHT_MASK_UNIFORMS[m]
  assert(uniform, "light mask must be a 4-bit integer, got " .. tostring(m))
  return { uniform[1], uniform[2], uniform[3], uniform[4] }
end

local function decodeRgb555(target, packed)
  target[1] = (packed % 32) / FixedPoint.RGB5_MAX
  target[2] = (math.floor(packed / 32) % 32) / FixedPoint.RGB5_MAX
  target[3] = (math.floor(packed / 1024) % 32) / FixedPoint.RGB5_MAX
end

-- 5-bit (0-31) RGB555 component -> the DS six-bit framebuffer domain
-- (melonDS GPU3D_Soft.cpp color conversion): 0 stays 0, any non-zero n
-- becomes 2n+1, normalized by 63. Used only for edge colors, which composite
-- directly into the six-bit scene RGB; material/light registers stay 5-bit
-- and must keep using decodeRgb555 above.
local function expand5to6(c5)
  if c5 <= 0 then
    return 0
  end
  return c5 * 2 + 1
end

local function decodeRgb555ToRgb6Normalized(target, packed)
  target[1] = expand5to6(packed % 32) / 63
  target[2] = expand5to6(math.floor(packed / 32) % 32) / 63
  target[3] = expand5to6(math.floor(packed / 1024) % 32) / 63
end

local function decodeFx12(target, vec)
  target[1] = vec[1] / FixedPoint.FX32_SCALE
  target[2] = vec[2] / FixedPoint.FX32_SCALE
  target[3] = vec[3] / FixedPoint.FX32_SCALE
end

local ZERO_COLOR = { 0, 0, 0 }

-- Select the active profile record, bind the light uniforms, and keep the
-- profile's material registers for the per-item composition in _drawMesh /
-- _drawWireframe: the field engine owns every material color channel, so a
-- static item's effective registers are the profile's. A runtime with no
-- lighting profile clears the light uniforms and drops the registers (the
-- per-draw u_mat* sends then reset to zero), so an unlit scene cannot
-- inherit lights or material colors from a lit scene drawn earlier with the
-- same renderer. (u_lightMask needs no reset: every draw path sends it
-- before drawing.)
function GxRenderer:_sendLighting(sceneRuntime, targetShader)
  assert(targetShader, "lighting delivery requires an explicit shader")
  assert(
    targetShader == self.shader or targetShader == self.worldShader or targetShader == self.spriteShader,
    "lighting target is not owned by this renderer"
  )
  local shader = targetShader
  local record = sceneRuntime.lighting
  if not record then
    local delivery = self._lightingDelivery[shader]
    if delivery and not delivery.lit and delivery.profile == nil and delivery.record == nil then
      self._lightMaterialColors = nil
      return
    end
    for i = 0, 3 do
      shader:send("u_lightEnabled" .. i, false)
      shader:send("u_lightVector" .. i, ZERO_COLOR)
      shader:send("u_lightColor" .. i, ZERO_COLOR)
    end
    self._lightingDelivery[shader] = { lit = false, profile = nil, record = nil }
    self._lightMaterialColors = nil
    return
  end

  local delivery = self._lightingDelivery[shader]
  if delivery and delivery.lit and delivery.record == record then
    self._lightMaterialColors = self._lightMaterialColorCache
    return
  end

  local materialColors = self._lightMaterialColorCache
  decodeRgb555(materialColors.diffuse, record.diffuseRgb555)
  decodeRgb555(materialColors.ambient, record.ambientRgb555)
  decodeRgb555(materialColors.specular, record.specularRgb555)
  decodeRgb555(materialColors.emission, record.emissionRgb555)

  for i = 1, 4 do
    local light = record.lights[i]
    local vector = self._lightVectorCache[i]
    local color = self._lightColorCache[i]
    shader:send("u_lightEnabled" .. (i - 1), light and light.enabled or false)
    if light then
      decodeFx12(vector, light.vectorFx12)
      decodeRgb555(color, light.colorRgb555)
    else
      vector[1], vector[2], vector[3] = 0, 0, 0
      color[1], color[2], color[3] = 0, 0, 0
    end
    shader:send("u_lightVector" .. (i - 1), vector)
    shader:send("u_lightColor" .. (i - 1), color)
  end
  self._lightingDelivery[shader] = { lit = true, profile = record, record = record }
  self._lightMaterialColors = materialColors
end

-- Edge colors are scene state, never a constructor invariant: the
-- compiled area's real HGSS eight-entry RGB555 table (HgssFieldEdgeColors),
-- decoded into the persistent cache and resent only when the scene supplies a
-- different table reference -- the same reference-equality cache pattern as
-- _sendLighting's profile/record tracking. Every compiled HGSS field scene
-- carries this table unconditionally (edge marking is always enabled), so a
-- missing table is a collaborator gone missing, not a case to default around.
function GxRenderer:_sendEdgeColors(sceneRuntime)
  local edgeColors = assert(sceneRuntime.edgeColors, "scene runtime requires an edgeColors table")
  if self._edgeColorsProfile == edgeColors then
    return
  end
  local decoded = self._edgeColorsCache
  for i = 0, 7 do
    decodeRgb555ToRgb6Normalized(decoded[i + 1], edgeColors[i])
  end
  self.edgeShader:send("u_edgeColors", unpack(decoded))
  self._edgeColorsProfile = edgeColors
end

-- The scene's resolved global HGSS weather fog preset is delivered to each
-- consumer only when that consumer's reference changes. Each reference is
-- advanced only after that consumer accepts the complete payload.
local function sendFogPayload(renderer, shader, fog)
  decodeRgb555(renderer._fogColorCache, fog.color)
  local groups = renderer._fogTableCache
  for group = 0, 7 do
    local values = groups[group + 1]
    local first = group * 4 + 1
    values[1], values[2], values[3], values[4] =
      fog.table[first], fog.table[first + 1], fog.table[first + 2], fog.table[first + 3]
  end

  local fogOffsetDepth = fog.offset * FOG_OFFSET_TO_DEPTH_SCALE
  shader:send("u_fogEnabled", fog.enabled)
  shader:send("u_fogColor", renderer._fogColorCache)
  -- The 32-entry density table is delivered as 8 groups of 4 raw entries,
  -- one named uniform each: LÖVE 11.5 fills only the first vec4 of a
  -- `vec4[N]` array uniform from a flat table, so a single-array send could
  -- never reach entries past index 0 (see edge.glsl's fogTableEntry). fog.table
  -- is the 1-indexed 32-entry preset table; group i covers entries
  -- 4*i+1 .. 4*i+4.
  for group = 0, 7 do
    shader:send("u_fogTable" .. group, groups[group + 1])
  end
  shader:send("u_fogOffsetDepth", fogOffsetDepth)
  shader:send("u_fogShift", fog.slope)
  shader:send("u_fogAlpha", fog.alpha)
end

function GxRenderer:_sendFog(sceneRuntime)
  local fog = assert(sceneRuntime.fog, "scene runtime requires a fog preset")
  if self._fogFinalReference == fog then
    return
  end
  sendFogPayload(self, self.edgeShader, fog)
  self._fogFinalReference = fog
end

-- Presentation sprites use the same fog payload and DS depth conversion as
-- the resolved world, but evaluate fog from their own host fragment depth.
function GxRenderer:_sendSpriteFog(sceneRuntime)
  local fog = assert(sceneRuntime.fog, "scene runtime requires a fog preset")
  local shader = self._activeShader or self.shader
  if self._fogSpriteReference == fog then
    return
  end
  local ok, err = pcall(sendFogPayload, self, shader, fog)
  if not ok then
    error(err, 0)
  end
  self._fogSpriteReference = fog
end

-- The effective DS material register for one channel of one draw item: the
-- field profile supplies every channel (the HGSS field policy clears the
-- materials' color ownership, so stored colors alone never reach the DS),
-- except channels a playing NSBMA color clip drives -- the clip replaces
-- the register. With no profile the register resets to zero so a later lit
-- scene cannot inherit stale material colors.
local function effectiveMaterialColor(value, colorsAnimated, profileColor)
  if value ~= nil and colorsAnimated then
    return value
  end
  return profileColor or ZERO_COLOR
end

-- Bind the model/normal matrices or billboard placement common to both the
-- filled and wireframe draw bodies (_drawMesh, _drawWireframeMesh).
local function sendTransformUniforms(shader, projection, modelMatrix, modelNormal, billboardCenter, billboardScale)
  shader:send("u_proj", "column", projection)
  local isBillboard = billboardCenter ~= nil
  shader:send("u_billboard", isBillboard)
  if isBillboard then
    assert(billboardScale, "billboard draw requires billboardScale")
    shader:send("u_billboardCenter", billboardCenter)
    shader:send("u_billboardScale", billboardScale)
  else
    shader:send("u_model", "column", modelMatrix)
    shader:send("u_modelNormal", "column", modelNormal)
  end
end

-- Bind placement for metadata shaders that do not perform vertex lighting.
local function sendPlacementUniforms(shader, projection, modelMatrix, billboardCenter, billboardScale)
  shader:send("u_proj", "column", projection)
  local isBillboard = billboardCenter ~= nil
  shader:send("u_billboard", isBillboard)
  if isBillboard then
    assert(billboardScale, "billboard draw requires billboardScale")
    shader:send("u_billboardCenter", billboardCenter)
    shader:send("u_billboardScale", billboardScale)
  else
    shader:send("u_model", "column", modelMatrix)
  end
end

-- Bind a material's uniforms/texture/cull state, then draw the mesh.
-- `projection` is per item: billboard actors draw through the camera's
-- field-billboard projection, everything else through the world projection.
-- `modelMatrix`/`modelNormal` are the item's current placement. `fragmentPass`
-- was selected by the caller and is sent as-is.
function GxRenderer:_drawItem(item, projection, fragmentPass)
  self:_drawMesh(
    item,
    projection,
    item.transform,
    item.billboardCenter and IDENTITY_MODEL_NORMAL or assert(item.modelNormal, "render item requires modelNormal"),
    item.mesh,
    fragmentPass,
    item.billboardCenter,
    item.billboardScale
  )
end

-- The common draw body: bind the model/normal matrices or billboard placement,
-- the material's
-- uniforms/texture/cull state, draw the mesh, and count the call.
function GxRenderer:_drawMesh(
  item,
  projection,
  modelMatrix,
  modelNormal,
  mesh,
  fragmentPass,
  billboardCenter,
  billboardScale
)
  local lg = assert(self._graphics)
  local mat = item.material
  local shader = self._activeShader or self.shader

  sendTransformUniforms(shader, projection, modelMatrix, modelNormal, billboardCenter, billboardScale)

  -- The effective DS material registers: the field profile's colors, with
  -- any playing NSBMA color clip's sampled colors replacing them (see
  -- effectiveMaterialColor). Static items (no material colors) always get
  -- the profile.
  local profileColors = self._lightMaterialColors
  shader:send(
    "u_matDiffuse",
    effectiveMaterialColor(mat and mat.matDiffuse, mat and mat.colorsAnimated, profileColors and profileColors.diffuse)
  )
  shader:send(
    "u_matAmbient",
    effectiveMaterialColor(mat and mat.matAmbient, mat and mat.colorsAnimated, profileColors and profileColors.ambient)
  )
  shader:send(
    "u_matSpecular",
    effectiveMaterialColor(
      mat and mat.matSpecular,
      mat and mat.colorsAnimated,
      profileColors and profileColors.specular
    )
  )
  shader:send(
    "u_matEmission",
    effectiveMaterialColor(
      mat and mat.matEmission,
      mat and mat.colorsAnimated,
      profileColors and profileColors.emission
    )
  )
  shader:send("u_texMatrix", "column", mat.texMatrix)

  if mat and mat.image then
    shader:send("u_useTexture", true)
    mesh:setTexture(mat.image)
  else
    shader:send("u_useTexture", false)
    mesh:setTexture()
  end

  shader:send("u_fragmentPass", fragmentPass)
  shader:send("u_polygonAlpha", item.polygonAlpha)
  shader:send("u_polygonMode", item.polygonMode == "decal" and 1 or 0)
  shader:send("u_lightMask", LIGHT_MASK_UNIFORMS[item.lightMask])
  if shader == self.worldShader then
    shader:send("u_polygonId", item.polygonId / GxRenderer.CLEAR_POLYGON_ID)
    shader:send("u_polygonFogEnabled", item.fogEnabled == true)
  end
  lg.setMeshCullMode(item.cullMode)
  lg.draw(mesh)
  self.stats.drawCalls = self.stats.drawCalls + 1
  self.stats.colorDrawCalls = self.stats.colorDrawCalls + 1
end

-- Draw the edges of a wireframe batch through the same projection path as
-- filled geometry. The DS draws polygon alpha zero as wireframe edges rather
-- than an invisible filled polygon.
function GxRenderer:_drawWireframe(item, projection)
  self:_drawWireframeMesh(
    item,
    projection,
    item.transform,
    item.billboardCenter and IDENTITY_MODEL_NORMAL or assert(item.modelNormal, "render item requires modelNormal"),
    item.mesh,
    item.billboardCenter,
    item.billboardScale
  )
end

-- The common wireframe draw body: bind the model/normal matrices, the
-- profile registers, and draw the mesh. The active wireframe pass owns shader,
-- depth, blend, and wireframe state outside the item loop. It writes color and
-- polygon state together to the active MRT pair, using shared depth and
-- replace semantics; wireframe items are opaque for edge marking.
function GxRenderer:_drawWireframeMesh(
  item,
  projection,
  modelMatrix,
  modelNormal,
  mesh,
  billboardCenter,
  billboardScale
)
  local lg = assert(self._graphics)
  local shader = self._activeShader or self.shader

  sendTransformUniforms(shader, projection, modelMatrix, modelNormal, billboardCenter, billboardScale)
  -- Wireframe polygons are static field geometry: the effective registers
  -- are the field profile's.
  local profileColors = self._lightMaterialColors
  shader:send("u_matDiffuse", profileColors and profileColors.diffuse or ZERO_COLOR)
  shader:send("u_matAmbient", profileColors and profileColors.ambient or ZERO_COLOR)
  shader:send("u_matSpecular", profileColors and profileColors.specular or ZERO_COLOR)
  shader:send("u_matEmission", profileColors and profileColors.emission or ZERO_COLOR)
  shader:send("u_texMatrix", "column", { 1, 0, 0, 0, 1, 0, 0, 0, 1 })
  shader:send("u_useTexture", false)
  shader:send("u_fragmentPass", FRAGMENT_PASS_OPAQUE)
  shader:send("u_polygonAlpha", 1.0)
  shader:send("u_polygonMode", 0)
  shader:send("u_lightMask", LIGHT_MASK_UNIFORMS[item.lightMask])
  if shader == self.worldShader then
    shader:send("u_polygonId", item.polygonId / GxRenderer.CLEAR_POLYGON_ID)
    shader:send("u_polygonFogEnabled", item.fogEnabled == true)
  end
  mesh:setTexture()
  lg.setMeshCullMode(item.cullMode)
  lg.draw(mesh)
  self.stats.drawCalls = self.stats.drawCalls + 1
  self.stats.colorDrawCalls = self.stats.colorDrawCalls + 1
end

-- Rasterize ONE blended item's partial-alpha fragments into the temporary
-- source buffers for the compositor. Two passes over the same geometry:
--   1. the ordinary color shader (map.glsl) with the translucent fragment
--      pass renders the item's partial-alpha fragments into sourceColor --
--      the exact combiner/lighting color, no duplication;
--   2. source.glsl renders the same fragments into sourceMeta -- the
--      valid/fog/id metadata -- applying the DS same-ID rejection against the
--      ACTIVE destination state. Both passes depth-test against the current
--      opaque host depth attachment and use replace semantics without writing
--      it.
function GxRenderer:_drawSourceItem(item, projection, fragmentPass, viewMatrix, activeState, stateW, stateH)
  local lg = assert(self._graphics)
  local mat = item.material

  -- Pass 1: source color through the ordinary color shader.
  local sourceColorTargets = assert(self._sourceColorTargets)
  lg.setCanvas(sourceColorTargets)
  lg.setShader(self.shader)
  lg.setDepthMode("less", false)
  lg.setBlendMode("replace", "premultiplied")
  self.shader:send("u_view", "column", viewMatrix)
  self:_drawItem(item, projection, fragmentPass)

  -- Pass 2: source metadata through source.glsl (same-ID rejection + fog flag
  -- + id).
  local sourceMetaTargets = assert(self._sourceMetaTargets)
  lg.setCanvas(sourceMetaTargets)
  lg.clear(0, 0, 0, 0, false, false)
  lg.setShader(self.sourceShader)
  lg.setDepthMode("less", false)
  lg.setBlendMode("replace", "premultiplied")
  self.sourceShader:send("u_view", "column", viewMatrix)

  sendPlacementUniforms(self.sourceShader, projection, item.transform, item.billboardCenter, item.billboardScale)
  self.sourceShader:send("u_texMatrix", "column", mat.texMatrix)
  if mat and mat.image then
    self.sourceShader:send("u_useTexture", true)
    item.mesh:setTexture(mat.image)
  else
    self.sourceShader:send("u_useTexture", false)
    item.mesh:setTexture()
  end
  self.sourceShader:send("u_fragmentPass", fragmentPass)
  self.sourceShader:send("u_polygonAlpha", item.polygonAlpha)
  self.sourceShader:send("u_polygonMode", item.polygonMode == "decal" and 1 or 0)
  self.sourceShader:send("u_polygonId", item.polygonId / GxRenderer.CLEAR_POLYGON_ID)
  self.sourceShader:send("u_polygonFogEnabled", item.fogEnabled == true)
  self.sourceShader:send("u_activeState", activeState)
  self.sourceShader:send("u_stateSize", { stateW, stateH })
  lg.setMeshCullMode(item.cullMode)
  lg.draw(item.mesh)
  self.stats.drawCalls = self.stats.drawCalls + 2
  self.stats.colorDrawCalls = self.stats.colorDrawCalls + 2
end

-- The normalized queue contains ordered map geometry, building batches, the
-- neighbour ring, and actors. Its traversal position is the deterministic
-- tie-breaker already resolved by HGSS presentation. FieldViewport limits the
-- render-target size and places the result inside the host drawable.
---@param frame table<string, unknown> DS frame
function GxRenderer:draw(frame)
  assert(type(frame) == "table", "GxRenderer requires a normalized frame")
  local spriteItems = frame.spriteItems
  local viewport = frame.viewport
  assert(viewport and viewport.worldViewport, "GxRenderer requires a render viewport")
  local viewMatrix = assert(frame.viewMatrix, "GxRenderer requires a view matrix")
  assert(frame.worldProjection, "GxRenderer requires a world projection")
  assert(frame.billboardProjection, "GxRenderer requires a billboard projection")
  -- The world MRT shader derives its depth from the host fragment's normalized
  -- window depth (map.glsl's dsZbufferDepth, the DS field Z-buffer domain).
  local lg = assert(self._graphics)
  self.stats.drawCalls = 0
  self.stats.colorDrawCalls = 0

  local rectangle = viewport.worldViewport
  local colorW, colorH = GxRenderer.worldRasterDimensions(rectangle.width, rectangle.height, self.worldRasterScale)
  self:_ensureTargets(colorW, colorH)

  -- The HGSS presentation owner computes these projections once per frame.
  -- Both the state and color passes select projection identically per item.
  local function projectionFor(item, frameState)
    if item.billboardProjection == true or item.fieldEffect ~= nil then
      return frameState.billboardProjection
    end
    return frameState.worldProjection
  end

  local colorTargets = assert(self._colorTargets)

  -- The final pass samples neighbors in world-raster pixels, so edge width
  -- remains tied to the DS-relative world rather than host resolution.
  local edgeRadiusPx = 1
  local cameraZoom = frame.cameraZoom
  if cameraZoom == nil then
    cameraZoom = 1
  end
  if type(cameraZoom) == "number" and cameraZoom > 0 then
    edgeRadiusPx = math.max(1, math.floor((colorH / 192) * cameraZoom + 0.5))
  end

  local presentationCanvas = lg.getCanvas()
  local function doDraw()
    ---@type GxRenderer.Canvas?
    local presentationColorCanvas
    if presentationCanvas ~= nil and type(presentationCanvas) == "table" and presentationCanvas[1] ~= nil then
      presentationColorCanvas = presentationCanvas[1]
      if type(presentationColorCanvas) == "table" then
        presentationColorCanvas = presentationColorCanvas[1]
      end
      assert(
        presentationColorCanvas and presentationColorCanvas.getWidth and presentationColorCanvas.getHeight,
        "GxRenderer requires a color presentation target"
      )
      ---@cast presentationColorCanvas GxRenderer.Canvas
    else
      ---@cast presentationCanvas GxRenderer.Canvas?
      presentationColorCanvas = presentationCanvas
    end

    -- The HGSS presentation owner builds the render queue exactly once per frame.
    local queue = assert(frame.queue, "GxRenderer requires a normalized render queue")

    -- ---- world MRT pass: color and polygon state ----
    local stateClearTargets = assert(self._stateClearTargets)
    lg.setCanvas(stateClearTargets)
    lg.clear(DS_STATE_CLEAR, false, true)
    local colorClearTargets = assert(self._colorClearTargets)
    lg.setCanvas(colorClearTargets)
    local clearColor = frame.clearColor or self.clearColor
    lg.clear(clearColor, false, false)
    lg.setCanvas(colorTargets)
    lg.setShader(self.worldShader)
    lg.setDepthMode("less", true)
    lg.setBlendMode("replace", "premultiplied")
    self._activeShader = self.worldShader
    self.worldShader:send("u_view", "column", viewMatrix)
    self:_sendLighting(frame, self.worldShader)

    for _, d in ipairs(queue.opaque) do
      self:_drawItem(d, projectionFor(d, frame), FRAGMENT_PASS_OPAQUE)
    end
    for _, d in ipairs(queue.cutout) do
      self:_drawItem(d, projectionFor(d, frame), FRAGMENT_PASS_CUTOUT)
    end
    for _, d in ipairs(queue.mixedOpaque) do
      self:_drawItem(d, projectionFor(d, frame), FRAGMENT_PASS_MIXED_OPAQUE)
    end
    self._activeShader = nil

    -- ---- translucent compositor ----
    -- The DS translucent path needs per-pixel state that fixed-function host
    -- blending cannot express: same-ID rejection against the pixel's last
    -- translucent ID, max destination alpha, fog-gate AND, and
    -- last-translucent-ID state mutation. The pipeline is a ping-pong
    -- read-modify-write: each blended item's partial-alpha fragments are
    -- rasterized into temporary source buffers (depth-tested against the
    -- current host depth, same-ID-rejected against the active destination
    -- state), then a full-screen composite applies the exact integer DS
    -- blend/state equations into the INACTIVE destination pair, then the
    -- pairs swap. No pass samples and writes the same target.
    --
    -- The active destination starts as the opaque color/state canvases
    -- (sceneColor/renderState); after every blended item the composite output
    -- is the new active pair, so wireframe and the final resolve below see the
    -- fully composited color and state.
    local activeColor, activeState = assert(self.sceneColor), assert(self.renderState)
    if self.translucencyMode == GxRenderer.TRANSLUCENCY_APPROXIMATE then
      if #queue.blended > 0 then
        self:_sendLighting(frame, self.shader)
        local approximateClearTargets = assert(self._colorClearTargets)
        lg.setCanvas(approximateClearTargets)
        lg.setShader(self.shader)
        lg.setDepthMode("less", false)
        lg.setBlendMode("alpha", "alphamultiply")
        self.shader:send("u_view", "column", viewMatrix)
        for _, entry in ipairs(queue.blended) do
          local fragmentPass = entry.fragmentPass == AlphaClassifier.MIXED and FRAGMENT_PASS_MIXED_TRANSLUCENT
            or FRAGMENT_PASS_TRANSLUCENT
          self:_drawItem(entry.item, projectionFor(entry.item, frame), fragmentPass)
        end
      end
    elseif #queue.blended > 0 then
      self:_sendLighting(frame, self.shader)
      local inactiveColor, inactiveState = assert(self._spareColor), assert(self._spareState)
      local function swap()
        activeColor, activeState, inactiveColor, inactiveState = inactiveColor, inactiveState, activeColor, activeState
      end
      self.compositeShader:send("u_sourceColor", self._sourceColor)
      self.compositeShader:send("u_sourceMeta", self._sourceMeta)
      self.compositeShader:send("u_size", { colorW, colorH })
      for _, entry in ipairs(queue.blended) do
        local d = entry.item
        -- Depth-equal is a corpus-provable-absent DS state (see
        -- PolygonState.validate's POLYGON_STATE_DEPTH_EQUAL_UNSUPPORTED
        -- rejection): the renderer never branches on d.depthEqual and always
        -- compares "less", even if a defensively-constructed item still
        -- carries the field. Host `lequal` is retired, not merely unused.
        local fragmentPass = entry.fragmentPass == AlphaClassifier.MIXED and FRAGMENT_PASS_MIXED_TRANSLUCENT
          or FRAGMENT_PASS_TRANSLUCENT
        self:_drawSourceItem(d, projectionFor(d, frame), fragmentPass, viewMatrix, activeState, colorW, colorH)

        -- Full-screen composite from the source buffers + active pair into
        -- the inactive pair, with replace semantics (no second host blend).
        lg.setCanvas(inactiveColor, inactiveState)
        lg.setDepthMode()
        lg.setBlendMode("replace", "premultiplied")
        lg.setColor(1, 1, 1, 1)
        lg.setShader(self.compositeShader)
        self.compositeShader:send("u_activeColor", activeColor)
        self.compositeShader:send("u_activeState", activeState)
        lg.draw(self._sourceColor, 0, 0)
        lg.setShader()
        swap()
      end
      -- Publish the composited pair as the renderer's public sceneColor/
      -- renderState fields and make the former active pair the spare. The
      -- next frame's composite reads the active pair and copies invalid
      -- source pixels directly from it.
      self.sceneColor, self.renderState = activeColor, activeState
      local publishedTargets = assert(self._colorTargets)
      publishedTargets[1], publishedTargets[2] = activeColor, activeState
      assert(self._stateClearTargets)[1] = activeState
      assert(self._colorClearTargets)[1] = activeColor
      self._spareColor, self._spareState = inactiveColor, inactiveState
    end

    -- Wireframe edges (polygon alpha zero): these count as opaque for edge
    -- marking; the color pass draws them for their own visible RGB. They
    -- target the ACTIVE color/state pair so the final resolve sees them
    -- composited with any translucent overlays.
    if #queue.wireframe > 0 then
      local wireframeTargets = assert(self._colorTargets)
      lg.setCanvas(wireframeTargets)
      lg.setShader(self.worldShader)
      self._activeShader = self.worldShader
      lg.setDepthMode("less", true)
      lg.setBlendMode("replace", "premultiplied")
      lg.setWireframe(true)
      for _, d in ipairs(queue.wireframe) do
        self:_drawWireframe(d, projectionFor(d, frame))
      end
      self._activeShader = nil
      lg.setWireframe(false)
    end

    -- ---- final resolve: edge marking, fog, then the current AA approximation ----
    self:_sendEdgeColors(frame)
    self:_sendFog(frame)
    self.edgeShader:send("u_antialiasEnabled", true)
    self.edgeShader:send("u_edgeRadiusPx", edgeRadiusPx)
    lg.setCanvas(presentationCanvas)
    if spriteItems and #spriteItems > 0 then
      -- Clear the presentation depth before resolving the world. The resolve
      -- must remain the first color write on the target.
      lg.clear(false, false, true)
    end
    lg.setDepthMode()
    lg.setBlendMode("replace", "premultiplied")
    lg.setColor(1, 1, 1, 1)
    lg.setShader(self.edgeShader)
    sendStateUniforms(self.edgeShader, activeState, self.stateW, self.stateH)
    lg.draw(activeColor, rectangle.x, rectangle.y, 0, rectangle.width / colorW, rectangle.height / colorH)
    lg.setShader()

    -- The world is now present at presentation resolution. The host depth
    -- buffer is borrowed for sprite-vs-sprite ordering; presentation sprites
    -- sample world DS depth for world-vs-sprite occlusion and draw directly to
    -- the window. Their fogged RGB and DS result alpha are written directly
    -- with replace/premultiplied semantics; no sprite color or state canvas is
    -- allocated.
    if spriteItems and #spriteItems > 0 then
      self._activeShader = self:_ensureSpriteShader()
      local spriteShader = assert(self._activeShader)
      spriteShader:send("u_presentationSprite", true)
      local targetWidth, targetHeight
      if presentationCanvas then
        local colorCanvas = assert(presentationColorCanvas)
        targetWidth, targetHeight = colorCanvas:getWidth(), colorCanvas:getHeight()
      else
        targetWidth, targetHeight = lg.getDimensions()
      end
      assert(targetWidth > 0 and targetHeight > 0, "GxRenderer requires positive presentation target dimensions")
      local scale = self._presentationScale
      local offset = self._presentationOffset
      scale[1] = rectangle.width / targetWidth
      scale[2] = rectangle.height / targetHeight
      offset[1] = (2 * rectangle.x + rectangle.width) / targetWidth - 1
      offset[2] = 1 - (2 * rectangle.y + rectangle.height) / targetHeight
      if presentationCanvas then
        scale[2] = -scale[2]
        offset[2] = -offset[2]
      end
      spriteShader:send("u_presentationScale", scale)
      spriteShader:send("u_presentationOffset", offset)
      spriteShader:send("u_view", "column", viewMatrix)
      spriteShader:send("u_renderState", activeState)
      spriteShader:send("u_stateSize", { self.stateW, self.stateH })
      self:_sendSpriteFog(frame)
      self:_sendLighting(frame, spriteShader)
      lg.setShader(spriteShader)
      lg.setBlendMode("replace", "premultiplied")

      local function drawSprite(item, fragmentPass)
        spriteShader:send("u_spriteFogEnabled", item.fogEnabled == true)
        lg.setDepthMode("less", true)
        self:_drawItem(item, frame.billboardProjection, fragmentPass)
      end
      for _, item in ipairs(spriteItems) do
        local fragmentPass
        if item.alphaClass == AlphaClassifier.OPAQUE then
          fragmentPass = FRAGMENT_PASS_OPAQUE
        elseif item.alphaClass == AlphaClassifier.CUTOUT then
          fragmentPass = FRAGMENT_PASS_CUTOUT
        else
          error("ordinary billboard has unsupported alpha class: " .. tostring(item.alphaClass))
        end
        drawSprite(item, fragmentPass)
      end
      self._activeShader = nil
    end
  end

  -- Capture every caller state the draw modifies, restore the captured values
  -- afterwards -- on success and error alike -- and rethrow the original draw
  -- error. The 2D diagnostic UI after the scene must never inherit the
  -- scene's canvas, shader, depth, cull, blend, wireframe, or color state.
  local canvas = lg.getCanvas()
  local shader = lg.getShader()
  local blendMode, blendAlpha = lg.getBlendMode()
  local depthMode, depthWrite = lg.getDepthMode()
  local cullMode = lg.getMeshCullMode()
  local wireframe = lg.isWireframe()
  local color = { lg.getColor() }

  local ok, err = pcall(doDraw)

  self._activeShader = nil
  lg.setCanvas(canvas)
  lg.setShader(shader)
  lg.setBlendMode(blendMode, blendAlpha)
  lg.setDepthMode(depthMode, depthWrite)
  lg.setWireframe(wireframe)
  lg.setMeshCullMode(cullMode)
  lg.setColor(color[1], color[2], color[3], color[4])

  if not ok then
    error(err)
  end
end

function GxRenderer:release()
  if self.shader then
    self.shader:release()
  end
  if self.edgeShader then
    self.edgeShader:release()
  end
  if self.worldShader then
    self.worldShader:release()
  end
  if self.sourceShader then
    self.sourceShader:release()
  end
  if self.compositeShader then
    self.compositeShader:release()
  end
  if self.spriteShader then
    self.spriteShader:release()
  end
  self.shader, self.worldShader, self.spriteShader, self.edgeShader = nil, nil, nil, nil
  self.sourceShader, self.compositeShader = nil, nil
  self:_releaseTargets()
end

return GxRenderer
