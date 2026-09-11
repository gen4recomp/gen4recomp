-- Bag hero 3D realization for the field bag: the GPU/model collaborator
-- behind the hero pane. The presenter owns pocket selection and the semantic
-- frame; this renderer only materializes that semantic time into animation
-- players through the shared model stack (GpuAssetPool, ModelDefinition,
-- ModelInstance, FieldRenderer), then composes the result through one private
-- canonical transparent target. Each gender realizes lazily on first draw,
-- animation catch-up is idempotent for one semantic frame, realization failure
-- unwinds the resources its own attempt acquired, and release is exactly-once.
-- No gameplay state is stored here: pocket and frame stay with the presenter.

local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local FieldDrawState = require("libs.hgss.src.presentation.FieldDrawState")
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local Matrix4 = require("libs.math.src.Matrix4")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")

---@class BagHeroSync
---@field pocket string
---@field pose string
---@field pattern string
---@field frame integer
---@field attachments table[]

---@class BagHeroRealization
---@field definition ModelDefinition
---@field instance ModelInstance
---@field renderMeshes table<string, unknown>

---@class BagHeroRenderer
---@field _cacheFs table<string, unknown>
---@field _manifest table<string, unknown>
---@field _graphics unknown?
---@field _modelCanvas unknown?
---@field _view number[]
---@field _projection number[]
---@field _modelTransform number[]
---@field _sceneRuntime table<string, unknown>
---@field _cameraFar number
---@field _pool GpuAssetPool?
---@field _renderer FieldRenderer?
---@field _realized table<string, BagHeroRealization>
---@field _sync table<string, BagHeroSync>
---@field _released boolean
local BagHeroRenderer = {}
BagHeroRenderer.__index = BagHeroRenderer

---@param value unknown
---@param what string
---@return number
local function finiteNumber(value, what)
  assert(type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge, what)
  return value --[[@as number]]
end

-- Immutable view/projection from the generated camera facts. Angles arrive in
-- degrees; the eye follows the repository camera convention (pitch around the
-- target for X, yaw for Y). The perspective angle is the source half-angle
-- index over the full circle, doubled to the full vertical field of view like
-- the field camera table. Only perspective type 0 is mapped; any other
-- validated type fails instead of guessing an orthographic mapping.
---@param camera table<string, unknown>
---@param logicalSize table<string, unknown>?
---@return { far: number, view: number[], projection: number[] }
local function buildCamera(camera, logicalSize)
  local target = assert(camera.target, "the hero camera must carry its target")
  local targetX = finiteNumber(target.x, "the hero camera target x must be finite")
  local targetY = finiteNumber(target.y, "the hero camera target y must be finite")
  local targetZ = finiteNumber(target.z, "the hero camera target z must be finite")
  local distance = finiteNumber(camera.distance, "the hero camera distance must be finite")
  assert(distance > 0, "the hero camera distance must be positive")
  local angleX = finiteNumber(camera.angleXDegrees, "the hero camera pitch must be finite")
  local angleY = finiteNumber(camera.angleYDegrees, "the hero camera yaw must be finite")
  local perspectiveType = assert(camera.perspectiveType, "the hero camera must carry its perspective type")
  assert(perspectiveType == 0, "the bag hero supports only perspective projection")
  local perspectiveAngle = assert(camera.perspectiveAngle, "the hero camera must carry its perspective angle")
  assert(
    type(perspectiveAngle) == "number" and perspectiveAngle % 1 == 0 and perspectiveAngle > 0,
    "the hero camera needs a positive perspective angle"
  )
  local clipNear = finiteNumber(camera.clipNear, "the hero camera near plane must be finite")
  local clipFar = finiteNumber(camera.clipFar, "the hero camera far plane must be finite")
  assert(clipNear > 0 and clipFar > clipNear, "the hero camera clipping range is invalid")
  local halfFov = perspectiveAngle * 2 * math.pi / 65536
  local pitch = math.rad(angleX)
  local yaw = math.rad(angleY)
  local horizontal = distance * math.cos(pitch)
  local eye = {
    targetX + math.sin(yaw) * horizontal,
    targetY + math.sin(-pitch) * distance,
    targetZ + math.cos(yaw) * horizontal,
  }
  local aspect = 4 / 3
  if
    type(logicalSize) == "table"
    and type(logicalSize.width) == "number"
    and type(logicalSize.height) == "number"
    and logicalSize.height > 0
  then
    aspect = logicalSize.width / logicalSize.height
  end
  return {
    far = clipFar,
    view = Matrix4.lookAt(eye, { targetX, targetY, targetZ }, { 0, 1, 0 }),
    projection = Matrix4.perspective(halfFov * 2, aspect, clipNear, clipFar),
  }
end

-- Immutable model matrix from the generated transform facts: uniform or
-- non-uniform scale first, then the source rotation, then translation. The
-- nine rotation entries read in row-major order.
---@param transform table<string, unknown>
---@return number[]
local function buildModelTransform(transform)
  local translation = assert(transform.translation, "the hero transform must carry its translation")
  local rotation = assert(transform.rotation, "the hero transform must carry its rotation")
  assert(type(rotation) == "table" and #rotation == 9, "the hero rotation must carry nine matrix entries")
  local scale = assert(transform.scale, "the hero transform must carry its scale")
  local linear = {
    finiteNumber(rotation[1], "hero rotation entries must be finite"),
    finiteNumber(rotation[4], "hero rotation entries must be finite"),
    finiteNumber(rotation[7], "hero rotation entries must be finite"),
    0,
    finiteNumber(rotation[2], "hero rotation entries must be finite"),
    finiteNumber(rotation[5], "hero rotation entries must be finite"),
    finiteNumber(rotation[8], "hero rotation entries must be finite"),
    0,
    finiteNumber(rotation[3], "hero rotation entries must be finite"),
    finiteNumber(rotation[6], "hero rotation entries must be finite"),
    finiteNumber(rotation[9], "hero rotation entries must be finite"),
    0,
    0,
    0,
    0,
    1,
  }
  return Matrix4.multiply(
    Matrix4.translate(
      finiteNumber(translation.x, "hero translation entries must be finite"),
      finiteNumber(translation.y, "hero translation entries must be finite"),
      finiteNumber(translation.z, "hero translation entries must be finite")
    ),
    Matrix4.multiply(
      linear,
      Matrix4.scale(
        finiteNumber(scale.x, "hero scale entries must be finite"),
        finiteNumber(scale.y, "hero scale entries must be finite"),
        finiteNumber(scale.z, "hero scale entries must be finite")
      )
    )
  )
end

-- Immutable scene record for the shared GX path. The generated lights carry
-- the four static retail direction vectors plus their white color, so the
-- scene selects a single field-lighting record with one enabled directional
-- slot per generated vector with the generated color. The material registers
-- are the generated retail setup values (mid-gray diffuse/specular/emission,
-- dimmer gray ambient) rather than an unlit white/zero assumption, so static
-- materials render lit the way the source global registers light them.
-- Manifest floats convert to the fx12 directional domain the GX record
-- shares with the field profiles; register colors pack to RGB555.
local FX12_SCALE = 4096

---@param value unknown
---@param what string
---@return integer
local function toFx12(value, what)
  local float = finiteNumber(value, what)
  return math.floor(float * FX12_SCALE + 0.5)
end

---@param register unknown
---@param what string
---@return integer
local function toRgb555(register, what)
  assert(type(register) == "table", what .. " must be a record")
  local channels = {}
  for _, channel in ipairs({ "r", "g", "b" }) do
    local value = register[channel]
    assert(
      type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 31,
      what .. " channel " .. channel .. " must be 0..31"
    )
    channels[#channels + 1] = value
  end
  return channels[1] + 32 * channels[2] + 1024 * channels[3]
end

---@param lights table<string, unknown>
---@param materials table<string, unknown>
---@return table<string, unknown>
local function buildSceneRuntime(lights, materials)
  local count = assert(lights.count, "the hero presentation must carry its light count")
  assert(count == 4, "the hero light count must be exactly four")
  local color = assert(lights.color, "the hero presentation must carry its light color")
  local red = finiteNumber(color.r, "hero light channels must be finite")
  local green = finiteNumber(color.g, "hero light channels must be finite")
  local blue = finiteNumber(color.b, "hero light channels must be finite")
  local packedColor = red + 32 * green + 1024 * blue
  local vectors = assert(lights.vectors, "the hero presentation must carry its light vectors")
  assert(type(vectors) == "table" and #vectors == 4, "the hero presentation must carry four light vectors")
  local slots = {}
  for index = 1, 4 do
    local vector = assert(vectors[index], "the hero presentation must carry light vector " .. index)
    slots[index] = {
      enabled = true,
      colorRgb555 = packedColor,
      vectorFx12 = {
        toFx12(vector.x, "hero light vectors must be finite"),
        toFx12(vector.y, "hero light vectors must be finite"),
        toFx12(vector.z, "hero light vectors must be finite"),
      },
    }
  end
  local fogTable = {}
  for index = 1, 32 do
    fogTable[index] = 0
  end
  return {
    lighting = {
      records = {
        {
          startHalfSeconds = 0,
          lights = slots,
          diffuseRgb555 = toRgb555(materials.diffuse, "the hero material diffuse register"),
          ambientRgb555 = toRgb555(materials.ambient, "the hero material ambient register"),
          specularRgb555 = toRgb555(materials.specular, "the hero material specular register"),
          emissionRgb555 = toRgb555(materials.emission, "the hero material emission register"),
        },
      },
    },
    edgeColors = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 },
    fog = { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = fogTable },
  }
end

---@class BagHeroRenderer.Options
---@field cacheFs table<string, unknown> generated-asset filesystem the model/texture bytes read through
---@field manifest table<string, unknown> the validated bag manifest carrying hero models and presentation
---@field graphics unknown? injectable graphics namespace (nil keeps love.graphics at realization)

---@param opts BagHeroRenderer.Options
---@return BagHeroRenderer
function BagHeroRenderer.new(opts)
  assert(type(opts) == "table", "the bag hero renderer requires options")
  local cacheFs = assert(opts.cacheFs, "the bag hero renderer requires the asset filesystem")
  assert(type(cacheFs.read) == "function", "the bag hero renderer requires a readable asset filesystem")
  local manifest = assert(opts.manifest, "the bag hero renderer requires the bag manifest")
  assert(manifest.schema == "g4-bag-assets-v3", "the bag hero renderer requires the v3 bag manifest")
  local hero = assert(manifest.hero, "the bag manifest must carry its hero pane")
  local model = assert(hero.model, "the hero pane must carry its gender models")
  assert(type(model.male) == "table", "the hero pane must carry its male model")
  assert(type(model.female) == "table", "the hero pane must carry its female model")
  local animations = assert(hero.animations, "the hero pane must carry its animation states")
  assert(type(animations.states) == "table", "the hero pane must carry its pocket states")
  assert(type(animations.material) == "table", "the hero pane must carry its material bindings")
  local presentation = assert(hero.presentation, "the hero pane must carry its presentation facts")
  local cameraFacts = assert(presentation.camera, "the hero presentation must carry its camera")
  local transformFacts = assert(presentation.transform, "the hero presentation must carry its transform")
  local lightFacts = assert(presentation.lights, "the hero presentation must carry its lights")
  local materialFacts = assert(presentation.materials, "the hero presentation must carry its material registers")
  local camera = buildCamera(cameraFacts, manifest.logicalSize)
  return setmetatable({
    _cacheFs = cacheFs,
    _manifest = manifest,
    _graphics = opts.graphics,
    _modelCanvas = nil,
    _view = camera.view,
    _projection = camera.projection,
    _modelTransform = buildModelTransform(transformFacts),
    _sceneRuntime = buildSceneRuntime(lightFacts, materialFacts),
    _cameraFar = camera.far,
    _pool = nil,
    _renderer = nil,
    _realized = {},
    _sync = {},
    _released = false,
  }, BagHeroRenderer)
end

---@param self BagHeroRenderer
---@return love.Graphics|love.graphics
local function graphicsFor(self)
  local graphics = self._graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  return assert(graphics, "the bag hero renderer requires love.graphics")
end

---@param self BagHeroRenderer
local function ensureModelCanvas(self)
  if self._modelCanvas ~= nil then
    return
  end
  local graphics = graphicsFor(self)
  assert(type(graphics.newCanvas) == "function", "the bag hero renderer requires canvas creation")
  local canvas
  local ok, err = pcall(function()
    canvas = graphics.newCanvas(256, 192, { format = "rgba8", readable = true })
    canvas:setFilter("nearest", "nearest")
  end)
  if not ok then
    if canvas ~= nil then
      pcall(canvas.release, canvas)
    end
    error(err, 0)
  end
  self._modelCanvas = assert(canvas, "the bag hero renderer failed to create its model target")
end

---@param gender string
---@return table<string, unknown> gender model descriptor
local function genderDescriptor(self, gender)
  local hero = self._manifest.hero
  local descriptor = hero.model[gender]
  assert(type(descriptor) == "table", "the hero has no model for gender " .. tostring(gender))
  return descriptor
end

-- Realize one gender exactly once: definition, render meshes retained by mesh
-- id, sampler wraps, and the model instance. Only the resources this attempt
-- creates are unwound on failure; a shared pool already owned for the other
-- gender is never released here.
---@param gender string
function BagHeroRenderer:_ensureGender(gender)
  if self._realized[gender] ~= nil then
    return
  end
  assert(not self._released, "the bag hero renderer is released")
  local poolWasOwned = self._pool ~= nil
  local rendererWasOwned = self._renderer ~= nil
  local ok, err = pcall(function()
    local pool = self._pool
    if pool == nil then
      local graphics = graphicsFor(self)
      pool = GpuAssetPool.new(self._cacheFs, { graphics = graphics })
      self._pool = pool
    end
    local descriptor = genderDescriptor(self, gender)
    local nitroDescriptor = descriptor --[[@as ModelDefinition.Descriptor]]
    local definition = ModelDefinition.fromNitroDescriptor(nitroDescriptor, { key = "bag-hero:" .. gender })
    local renderMeshes = {}
    -- Production definitions always carry meshes (the model gate requires a
    -- non-empty mesh list); recording doubles omit the list, so there is
    -- nothing to resolve for them.
    for _, mesh in ipairs(definition.meshes or {}) do
      local resource = pool:meshFor(mesh.geometry)
      renderMeshes[mesh.id] = resource.mesh
      mesh.center = resource.center
    end
    if next(renderMeshes) == nil then
      -- Mesh-less fixtures still exercise the pool failure seam so a broken
      -- pool surfaces through the unwind path instead of succeeding silently.
      -- Unreachable with valid manifests: the model gate requires meshes, so
      -- production always resolves at least one render mesh above.
      pool:meshFor("bag-hero:unmeshed")
    end
    local materials = assert(descriptor.materials, "the hero model must carry its materials")
    local wrapsByMaterial = {}
    for _, record in ipairs(materials) do
      wrapsByMaterial[record.id] = SceneDescriptor.wrap(record)
    end
    ---@param path string
    ---@param materialId integer
    ---@return unknown
    local function resolveImage(path, materialId)
      local wrap = assert(wrapsByMaterial[materialId], "the hero model has no sampler wrap")
      return pool:imageFor(path, wrap.x, wrap.y)
    end
    local instance = ModelInstance.new(definition, { resolveImage = resolveImage })
    instance.transform = self._modelTransform
    if self._renderer == nil then
      local graphics = graphicsFor(self)
      self._renderer = FieldRenderer.new({ clearColor = { 0, 0, 0, 0 }, graphics = graphics })
    end
    self._realized[gender] = { definition = definition, instance = instance, renderMeshes = renderMeshes }
  end)
  if not ok then
    if not rendererWasOwned and self._renderer ~= nil then
      self._renderer:release()
      self._renderer = nil
    end
    if not poolWasOwned and self._pool ~= nil then
      self._pool:release()
      self._pool = nil
    end
    error(err, 0)
  end
end

---@param graphics love.Graphics|love.graphics
---@param scissor number[]?
local function restoreScissor(graphics, scissor)
  if scissor ~= nil then
    graphics.setScissor(scissor[1], scissor[2], scissor[3], scissor[4])
  else
    graphics.setScissor()
  end
end

---@param self BagHeroRenderer
---@param realized BagHeroRealization
---@param viewport table<string, number>
local function drawCanonicalModel(self, realized, viewport)
  local graphics = graphicsFor(self)
  local target = assert(self._modelCanvas)
  local state = FieldDrawState.save(graphics)
  local ok, err = pcall(function()
    graphics.setCanvas(target)
    graphics.setScissor()
    graphics.setShader()
    graphics.setDepthMode()
    graphics.setColor(1, 1, 1, 1)
    graphics.clear(0, 0, 0, 0)
    local view = self._view
    local projection = self._projection
    ---@return number[]
    local function cameraView()
      return view
    end
    ---@return number[]
    local function cameraProjection()
      return projection
    end
    ---@return number[]
    local function cameraBillboardProjection()
      return projection
    end
    assert(self._renderer, "the hero renderer is realized before drawing"):draw(
      self._sceneRuntime,
      {
        far = self._cameraFar,
        zoom = 1,
        view = cameraView,
        projection = cameraProjection,
        billboardProjection = cameraBillboardProjection,
      },
      { realized.instance:drawItems(realized.renderMeshes) },
      nil,
      {
        worldViewport = { x = 0, y = 0, width = 256, height = 192 },
        referenceFrame = { x = 0, y = 0, width = 256, height = 192 },
      },
      1
    )

    graphics.setCanvas(state.canvas)
    graphics.setShader()
    graphics.setDepthMode()
    graphics.setWireframe(false)
    graphics.setBlendMode("alpha", "alphamultiply")
    graphics.setColor(1, 1, 1, 1)
    restoreScissor(graphics, state.scissor --[[@as number[]?]])
    graphics.draw(target, viewport.x, viewport.y, 0, viewport.width / 256, viewport.height / 192)
  end)
  FieldDrawState.restore(graphics, state)
  if not ok then
    error(err, 0)
  end
end

-- Restart the active clips for a new semantic state (or a backward frame):
-- resolve every clip first so a malformed binding leaves the previous
-- attachments playing, then stop the old clips, play pose, pattern, and the
-- gender material clip in looping mode, and reset the synchronized frame.
---@param realized BagHeroRealization
---@param gender string
---@param pocket string
---@param pose string
---@param pattern string
---@param materialId string
local function restartClips(self, realized, gender, pocket, pose, pattern, materialId)
  local instance = realized.instance
  local definition = realized.definition
  local poseClip = definition:animation(pose)
  assert(poseClip ~= nil, "the hero has no pose clip " .. tostring(pose))
  local patternClip = definition:animation(pattern)
  assert(patternClip ~= nil, "the hero has no pattern clip " .. tostring(pattern))
  local materialClip = definition:animation(materialId)
  assert(materialClip ~= nil, "the hero has no material clip " .. tostring(materialId))
  local previous = self._sync[gender]
  if previous ~= nil then
    for _, attachment in ipairs(previous.attachments) do
      instance:stop(attachment)
    end
  end
  local attachments = {}
  local ok, err = pcall(function()
    attachments[1] = instance:play(pose, { loopMode = "loop" })
    attachments[2] = instance:play(pattern, { loopMode = "loop" })
    attachments[3] = instance:play(materialId, { loopMode = "loop" })
  end)
  if not ok then
    for _, attachment in ipairs(attachments) do
      instance:stop(attachment)
    end
    self._sync[gender] = nil
    error(err, 0)
  end
  self._sync[gender] = { pocket = pocket, pose = pose, pattern = pattern, frame = 0, attachments = attachments }
end

-- Catch up the active players by exactly the outstanding fixed steps: every
-- attached clip advances by the full delta, matching ModelInstance:updateFixed
-- semantics. A repeated draw at the synchronized frame advances nothing.
---@param realized BagHeroRealization
---@param steps integer
local function advancePlayers(realized, steps)
  for _ = 1, steps do
    realized.instance:updateFixed()
  end
end

-- Draws the gender hero for one presenter status inside one hero placement.
-- The status record is only read: draws never advance the semantic frame or
-- reselect the pocket. The placement frame is in host coordinates; the model
-- itself always renders at canonical size before that frame scales it.
---@param gender string
---@param heroStatus { pocket: string, pose: string, pattern: string, frame: integer }
---@param heroPlacement table<string, unknown>
function BagHeroRenderer:draw(gender, heroStatus, heroPlacement)
  assert(not self._released, "the bag hero renderer is released")
  assert(gender == "male" or gender == "female", "the hero gender selects its model")
  assert(type(heroStatus) == "table", "the hero draw requires its presenter status")
  local pocket = heroStatus.pocket
  assert(type(pocket) == "string" and pocket ~= "", "the hero status names its pocket")
  local pose = heroStatus.pose
  assert(type(pose) == "string" and pose ~= "", "the hero status names its pose clip")
  local pattern = heroStatus.pattern
  assert(type(pattern) == "string" and pattern ~= "", "the hero status names its pattern clip")
  local frame = heroStatus.frame
  assert(type(frame) == "number" and frame % 1 == 0 and frame >= 0, "the hero status carries its frame")
  assert(type(heroPlacement) == "table", "the hero draw requires its placement")
  local viewport = assert(heroPlacement.frame, "the hero placement carries its frame")
  assert(
    type(viewport.x) == "number"
      and type(viewport.y) == "number"
      and type(viewport.width) == "number"
      and viewport.width > 0
      and type(viewport.height) == "number"
      and viewport.height > 0,
    "the hero placement frame must be a positive host rectangle"
  )
  self:_ensureGender(gender)
  ensureModelCanvas(self)
  local realized = assert(self._realized[gender], "the hero model is realized before drawing")
  local hero = self._manifest.hero
  local materialId = hero.animations.material[gender]
  assert(type(materialId) == "string" and materialId ~= "", "the hero carries its gender material binding")
  local sync = self._sync[gender]
  if sync == nil or sync.pocket ~= pocket or sync.pose ~= pose or sync.pattern ~= pattern or frame < sync.frame then
    restartClips(self, realized, gender, pocket, pose, pattern, materialId)
    sync = assert(self._sync[gender], "the hero restart synchronizes its clips")
  end
  if frame > sync.frame then
    advancePlayers(realized, frame - sync.frame)
    sync.frame = frame
  end
  realized.instance:evaluatePose()
  drawCanonicalModel(self, realized, viewport)
end

-- Idempotent release of the owned pool and renderer. Borrowed manifest data
-- and per-gender instances (whose GPU objects the pool owns) need no further
-- disposal; a release after a failed realization stays a safe no-op.
function BagHeroRenderer:release()
  if self._released then
    return
  end
  self._released = true
  self._realized = {}
  self._sync = {}
  if self._renderer ~= nil then
    self._renderer:release()
    self._renderer = nil
  end
  if self._pool ~= nil then
    self._pool:release()
    self._pool = nil
  end
  if self._modelCanvas ~= nil then
    self._modelCanvas:release()
    self._modelCanvas = nil
  end
end

return BagHeroRenderer
