-- Game-local retail starter-application presentation. It realizes one
-- validated starter-application manifest through the shared model stack
-- (ModelDefinition/ModelInstance over a GpuAssetPool, drawn through
-- FieldRenderer under the manifest's outside/inside camera poses), and maps
-- pointer input in the DS reference frame back onto the three rendered
-- balls. Owned exclusively by StarterChoiceState, which is its only caller:
-- this helper never decides the choice, publishes mons, mutates saves, or
-- polls input. GPU resources are acquired lazily on first draw so headless
-- compositions can open, drive, and close the choice without graphics, and
-- release exactly once on dispose.

local StarterChoiceAssetCache = require("libs.assets.src.StarterChoiceAssetCache")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local Matrix4 = require("libs.math.src.Matrix4")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")
local FixedPoint = require("libs.math.src.FixedPoint")

---@class StarterChoicePresentation
---@field _manifest table<string, unknown> immutable validated starter-application manifest
---@field _cacheFs table<string, unknown> generated-asset filesystem the model/texture bytes read through
---@field _viewport table<string, unknown> strict 4:3 scene viewport for the current drawable size
---@field _width number last drawable width
---@field _height number last drawable height
---@field _pool GpuAssetPool? GPU mesh/image owner once realized
---@field _renderer FieldRenderer? field renderer once realized
---@field _realized boolean
---@field _disposed boolean
---@field _definitions table<string, ModelDefinition> model definitions by scene role
---@field _renderMeshes table<string, table<string, unknown>> render meshes by role then mesh id
---@field _wraps table<string, table<string, unknown>> sampler wraps by role then zero-based material index
---@field _instances table<string, ModelInstance> model instances by scene role
---@field _staticBatches table[] prepared tabletop batches
---@field _speciesImages table<string, GpuAssetPool.Image> display sprite images by species id
---@field _clipNames { turntable: string, ballEffect: string, ballRock: string[], ballOpen: string } instance play names resolved from bindings
---@field _sceneRuntime table<string, unknown> minimal renderer scene state (edge colors, fog, flat lighting)
---@field _lastKey string? last snapshot key the playback state synced to
---@field _clockKey string? last snapshot key the platform clock synced to
---@field _clockTransition string? transition of the last clock sync
---@field _cameraKey string? last snapshot key the camera matrices were built for
---@field _cameraView number[]? cached view matrix for the camera key
---@field _cameraProjection number[]? cached projection matrix for the camera key
---@field _turntableYaw number accumulated turntable rotation in radians
---@field _rotateFrom number yaw at the active rotation's entry
---@field _rotateSign number rotation direction sign while rotating
local StarterChoicePresentation = {}
StarterChoicePresentation.__index = StarterChoicePresentation

local ROLES = { "tabletop", "turntable", "ballEffect", "ball1", "ball2", "ball3" }
local BALL_ROLES = { "ball1", "ball2", "ball3" }

-- One turntable step per rotated ball: three balls around the table.
local TURNTABLE_STEP = (2 * math.pi) / 3
-- Confirm state widens the inspected ball's hit region; the spacing-derived
-- base radius still comes from the projected scene.
local CONFIRM_RADIUS_SCALE = 1.5
-- Clipping planes around the manifest's camera distances: the DS depth
-- resolve quantizes over this range, so it stays tight on the tabletop
-- scene (fragments tens of units out) to keep balls resting just above the
-- table surface resolving against it instead of losing the depth test.
local CAMERA_NEAR = 20
local CAMERA_FAR = 250
-- White emissive register paint: the modal scene carries no field light
-- profile, so every material emits its texture (or its base color) flat
-- instead of resolving field lighting it was never given.
local EMISSIVE_WHITE = 31 + 32 * 31 + 1024 * 31

---@param value unknown
---@return boolean
local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Full homogeneous clip transform: Matrix4.transformPoint assumes an affine
-- matrix, while projection needs the w row for the perspective divide.
---@param matrix number[]
---@param x number
---@param y number
---@param z number
---@return number, number, number, number
local function clipPoint(matrix, x, y, z)
  return matrix[1] * x + matrix[5] * y + matrix[9] * z + matrix[13],
    matrix[2] * x + matrix[6] * y + matrix[10] * z + matrix[14],
    matrix[3] * x + matrix[7] * y + matrix[11] * z + matrix[15],
    matrix[4] * x + matrix[8] * y + matrix[12] * z + matrix[16]
end

---@class StarterChoicePresentation.Options
---@field manifest table<string, unknown> validated starter-application manifest
---@field cacheFs table<string, unknown> generated-asset filesystem

---@param opts StarterChoicePresentation.Options
---@return StarterChoicePresentation
function StarterChoicePresentation.new(opts)
  assert(type(opts) == "table", "starter presentation requires its composition")
  assert(type(opts.manifest) == "table", "starter presentation requires the application manifest")
  assert(
    opts.cacheFs ~= nil and type(opts.cacheFs.read) == "function",
    "starter presentation requires the asset filesystem"
  )
  assert(StarterChoiceAssetCache.validateManifest(opts.manifest), "starter presentation requires a valid manifest")
  local reference = opts.manifest.reference
  local self = setmetatable({
    _manifest = opts.manifest,
    _cacheFs = opts.cacheFs,
    _width = reference.width,
    _height = reference.height,
    _pool = nil,
    _renderer = nil,
    _realized = false,
    _disposed = false,
    _definitions = {},
    _renderMeshes = {},
    _wraps = {},
    _instances = {},
    _staticBatches = {},
    _speciesImages = {},
    _clipNames = { turntable = "", ballEffect = "", ballRock = {}, ballOpen = "" },
    _sceneRuntime = {},
    _lastKey = nil,
    _clockKey = nil,
    _clockTransition = nil,
    _cameraKey = nil,
    _cameraView = nil,
    _cameraProjection = nil,
    _turntableYaw = 0,
    _rotateFrom = 0,
    _rotateSign = 0,
  }, StarterChoicePresentation)
  self._viewport = FieldViewport.new(reference.width, reference.height, { mode = "strict" })
  return self
end

-- Clears transition/playback bookkeeping for a fresh open. Instances are
-- per-presentation, so a reset presentation starts with the camera outside
-- and no clip playing.
function StarterChoicePresentation:reset()
  self._lastKey = nil
  self._clockKey = nil
  self._clockTransition = nil
  self._turntableYaw = 0
  self._rotateFrom = 0
  self._rotateSign = 0
end

---@param width number
---@param height number
function StarterChoicePresentation:resize(width, height)
  assert(type(width) == "number" and width > 0, "starter presentation resize requires a positive width")
  assert(type(height) == "number" and height > 0, "starter presentation resize requires a positive height")
  self._width = width
  self._height = height
  self._viewport = FieldViewport.new(width, height, { mode = "strict" })
end

-- Display pixels into the DS reference frame through the strict scene fit;
-- nil when the point falls outside the presented scene.
---@param x number
---@param y number
---@return number?, number?
function StarterChoicePresentation:toReference(x, y)
  assert(type(x) == "number" and type(y) == "number", "starter pointer position must be numeric")
  local frame = self._viewport.referenceFrame
  if x < frame.x or x >= frame.x + frame.width or y < frame.y or y >= frame.y + frame.height then
    return nil, nil
  end
  local reference = self._manifest.reference
  return (x - frame.x) / frame.width * reference.width, (y - frame.y) / frame.height * reference.height
end

-- Interpolated camera pose for a controller snapshot: the zoom/wait path
-- dollies from the outside pose to the inside pose, reversal returns, and
-- the locking exit holds inside.
---@param snapshot StarterChoiceController.Snapshot
---@return number 0..1
local function cameraProgress(snapshot)
  local ticks = snapshot.ticks
  if snapshot.transition == "zoomIn" then
    return math.min(1, snapshot.progress / ticks)
  end
  if snapshot.transition == "waitZoom" then
    return 1
  end
  if snapshot.transition == "backOut" then
    return 1 - math.min(1, snapshot.progress / ticks)
  end
  if snapshot.selectionState == "confirm" then
    return 1
  end
  if snapshot.transition == "lockExit" or snapshot.transition == "done" then
    return 1
  end
  return 0
end

---@param out table<string, unknown> manifest camera pose
---@param inside table<string, unknown> manifest camera pose
---@param alpha number 0..1
---@return table<string, unknown> interpolated pose
local function interpolatePose(out, inside, alpha)
  local pose = {
    angleX = out.angleX + (inside.angleX - out.angleX) * alpha,
    perspective = out.perspective + (inside.perspective - out.perspective) * alpha,
    distance = out.distance + (inside.distance - out.distance) * alpha,
    target = {
      x = out.target.x + (inside.target.x - out.target.x) * alpha,
      y = out.target.y + (inside.target.y - out.target.y) * alpha,
      z = out.target.z + (inside.target.z - out.target.z) * alpha,
    },
  }
  return pose
end

-- View/projection matrices for a controller snapshot from the manifest's
-- camera poses: pitch around the look-at target at the posed distance with
-- the posed vertical field of view over the DS aspect. Pure in the snapshot
-- and memoized by it, so hit-region scans share one build per snapshot.
---@param snapshot StarterChoiceController.Snapshot
---@return number[] view, number[] projection
function StarterChoicePresentation:cameraMatrices(snapshot)
  local key = snapshot.transition
    .. "|"
    .. snapshot.selectionState
    .. "|"
    .. tostring(snapshot.selection)
    .. "|"
    .. tostring(snapshot.progress)
    .. "|"
    .. tostring(snapshot.ticks)
    .. "|"
    .. tostring(snapshot.direction)
  if key ~= self._cameraKey then
    local camera = self._manifest.scene.camera
    local pose = interpolatePose(camera.out, camera.inside, cameraProgress(snapshot))
    local pitch = math.rad(pose.angleX)
    local target = pose.target
    local eye = {
      target.x,
      target.y + math.sin(-pitch) * pose.distance,
      target.z + math.cos(pitch) * pose.distance,
    }
    local reference = self._manifest.reference
    self._cameraView = Matrix4.lookAt(eye, { target.x, target.y, target.z }, { 0, 1, 0 })
    self._cameraProjection =
      Matrix4.perspective(math.rad(pose.perspective), reference.width / reference.height, CAMERA_NEAR, CAMERA_FAR)
    self._cameraKey = key
  end
  return assert(self._cameraView, "starter camera has no view matrix"),
    assert(self._cameraProjection, "starter camera has no projection matrix")
end

-- Projected ball centers in the DS reference frame under the snapshot's
-- camera and platform rotation. Pure camera math over the manifest's ball
-- positions, shared by drawing alignment and hit testing.
---@param snapshot StarterChoiceController.Snapshot
---@return table[] { x, y } per ball, 1-based in ball order
function StarterChoicePresentation:ballCenters(snapshot)
  local yaw = self:yawForSnapshot(snapshot)
  local view, projection = self:cameraMatrices(snapshot)
  local combined = Matrix4.multiply(projection, Matrix4.multiply(view, Matrix4.rotateY(yaw)))
  local reference = self._manifest.reference
  local centers = {}
  for index, position in ipairs(self._manifest.scene.ballPositions) do
    local cx, cy, _, cw = clipPoint(combined, position.x, position.y, position.z)
    if cw ~= nil and cw > 0 and isFiniteNumber(cx / cw) and isFiniteNumber(cy / cw) then
      centers[index] = {
        x = (cx / cw * 0.5 + 0.5) * reference.width,
        y = (0.5 - cy / cw * 0.5) * reference.height,
      }
    else
      centers[index] = nil
    end
  end
  return centers
end

-- Hit region radii from the projected scene: half the nearest-neighbor ball
-- spacing, widened for the inspected ball while confirming.
---@param centers table[]
---@param snapshot StarterChoiceController.Snapshot
---@return table[] radii per ball
local function ballRadii(centers, snapshot)
  local spacing = math.huge
  for first = 1, #centers do
    for second = first + 1, #centers do
      local a, b = centers[first], centers[second]
      if a ~= nil and b ~= nil then
        local distance = math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y))
        if distance < spacing then
          spacing = distance
        end
      end
    end
  end
  if spacing == math.huge or spacing <= 0 then
    return {}
  end
  local radii = {}
  for index = 1, #centers do
    radii[index] = spacing * 0.45
    if snapshot.selectionState == "confirm" and index == snapshot.selection + 1 then
      radii[index] = radii[index] * CONFIRM_RADIUS_SCALE
    end
  end
  return radii
end

-- Reference-frame pointer position onto the rendered balls: 1|2|3 for the
-- nearest ball whose region covers the point, nil outside every region.
---@param x number
---@param y number
---@param snapshot StarterChoiceController.Snapshot
---@return integer?
function StarterChoicePresentation:ballAt(x, y, snapshot)
  assert(type(x) == "number" and type(y) == "number", "starter pointer position must be numeric")
  assert(type(snapshot) == "table", "starter hit testing requires the controller snapshot")
  local centers = self:ballCenters(snapshot)
  local radii = ballRadii(centers, snapshot)
  local best, bestDistance = nil, nil
  for index, center in ipairs(centers) do
    local radius = radii[index]
    if center ~= nil and radius ~= nil then
      local distance = math.sqrt((x - center.x) * (x - center.x) + (y - center.y) * (y - center.y))
      if distance <= radius and (bestDistance == nil or distance < bestDistance) then
        best, bestDistance = index, distance
      end
    end
  end
  return best
end

---@param descriptor table<string, unknown> static model descriptor
---@param pool GpuAssetPool
---@return table[] prepared batches
local function prepareStatic(descriptor, pool)
  assert(type(descriptor.materials) == "table", "starter static model requires its materials")
  assert(type(descriptor.batches) == "table", "starter static model requires its batches")
  local materialById = {}
  for listIndex, record in ipairs(descriptor.materials) do
    local wrap = SceneDescriptor.wrap(record)
    materialById[record.id] = {
      id = record.id,
      name = record.name,
      image = pool:imageFor(record.texture, wrap.x, wrap.y),
      texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
      wrap = wrap,
      listIndex = listIndex,
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
  return batches
end

-- Manifest animation bindings address clips by descriptor id or name
-- while the instance player resolves by clip name: map each binding to the
-- play name through the descriptor's own clip list. A binding that resolves
-- to no clip is malformed generated data and fails loudly.
---@param role string
---@param descriptor table<string, unknown>
---@param binding string|integer
---@return string clip name
local function clipNameFor(role, descriptor, binding)
  assert(type(descriptor.animations) == "table", "starter model " .. role .. " owns no clips")
  for _, clip in ipairs(descriptor.animations) do
    if clip.id == binding or clip.name == binding then
      assert(type(clip.name) == "string", "starter model " .. role .. " clip carries no name")
      return clip.name
    end
  end
  error("starter animation binding " .. tostring(binding) .. " resolves to no clip on " .. role, 0)
end

---@param role string
---@param descriptor table<string, unknown> dynamic model descriptor
---@param pool GpuAssetPool
---@param presentation StarterChoicePresentation
local function realizeDynamic(role, descriptor, pool, presentation)
  assert(type(descriptor.dynamic) == "table", "starter model " .. role .. " requires its dynamic batches")
  assert(type(descriptor.materials) == "table", "starter model " .. role .. " requires its materials")
  assert(type(descriptor.animations) == "table", "starter model " .. role .. " requires its clips")
  local nitroDescriptor = descriptor --[[@as ModelDefinition.Descriptor]]
  local definition = ModelDefinition.fromNitroDescriptor(nitroDescriptor, { key = "starter-choice:" .. role })
  local renderMeshes = {}
  for _, mesh in ipairs(definition.meshes) do
    local resource = pool:meshFor(mesh.geometry)
    renderMeshes[mesh.id] = resource.mesh
    mesh.center = resource.center
  end
  local wraps = {}
  for listIndex, record in ipairs(descriptor.materials) do
    wraps[listIndex - 1] = SceneDescriptor.wrap(record)
  end
  ---@param path string
  ---@param materialId integer
  ---@return GpuAssetPool.Image?
  local function resolveImage(path, materialId)
    local wrap = assert(wraps[materialId], "starter model " .. role .. " has no sampler wrap")
    return pool:imageFor(path, wrap.x, wrap.y)
  end
  local instance = ModelInstance.new(definition, {
    resolveImage = resolveImage,
  })
  presentation._definitions[role] = definition
  presentation._renderMeshes[role] = renderMeshes
  presentation._wraps[role] = wraps
  presentation._instances[role] = instance
end

-- Acquire every GPU/model resource for the manifest exactly once. Raises a
-- contextual error naming the role when a validated referenced asset cannot
-- be realized; never substitutes placeholder geometry.
function StarterChoicePresentation:_ensureRealized()
  if self._realized then
    return
  end
  assert(not self._disposed, "starter presentation is disposed")
  local graphics = love and love.graphics
  assert(graphics and graphics.newImage and graphics.newCanvas, "starter presentation requires the graphics namespace")
  local pool = GpuAssetPool.new(self._cacheFs)
  self._pool = pool
  local ok, err = pcall(function()
    pool:build(function()
      local models = self._manifest.models
      for _, role in ipairs(ROLES) do
        local descriptor = assert(models[role], "starter manifest is missing model role " .. role)
        local roleOk, roleErr = pcall(function()
          if descriptor.kind == "static" then
            self._staticBatches = prepareStatic(descriptor, pool)
          else
            realizeDynamic(role, descriptor, pool, self)
          end
        end)
        if not roleOk then
          error("starter presentation cannot realize " .. role .. ": " .. tostring(roleErr), 0)
        end
      end
      for id, entry in pairs(self._manifest.speciesSprites) do
        self._speciesImages[id] = pool:imageFor(entry.image, "clamp", "clamp")
      end
    end)
  end)
  if not ok then
    self:_releaseGpu()
    error(err, 0)
  end
  local fogTable = {}
  for index = 1, 32 do
    fogTable[index] = 0
  end
  self._sceneRuntime = {
    lighting = {
      diffuseRgb555 = 0,
      ambientRgb555 = 0,
      specularRgb555 = 0,
      emissionRgb555 = EMISSIVE_WHITE,
      lights = {},
    },
    edgeColors = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 },
    fog = { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = fogTable },
  }
  self._renderer = FieldRenderer.new()
  local animations = self._manifest.animations
  local models = self._manifest.models
  self._clipNames = {
    turntable = clipNameFor("turntable", models.turntable, animations.turntable),
    ballEffect = clipNameFor("ballEffect", models.ballEffect, animations.ballEffect),
    ballRock = {
      clipNameFor("ball1", models.ball1, animations.ballRock[1]),
      clipNameFor("ball2", models.ball2, animations.ballRock[2]),
      clipNameFor("ball3", models.ball3, animations.ballRock[3]),
    },
    ballOpen = clipNameFor("ball1", models.ball1, animations.ballOpen),
  }
  local turntable = assert(self._instances.turntable, "starter presentation is missing the turntable instance")
  turntable:play(self._clipNames.turntable, { loopMode = "loop" })
  self._realized = true
end

---@param instance ModelInstance
---@param presentation StarterChoicePresentation
local function stopBallClips(instance, presentation)
  instance:stop(presentation._clipNames.ballOpen)
  for _, binding in ipairs(presentation._clipNames.ballRock) do
    instance:stop(binding)
  end
end

-- Map the controller snapshot onto clip playback and the turntable clock.
-- The platform clock syncs from the snapshot alone (so drawing and hit
-- testing agree even before the next update), while clip edges fire only
-- from update/draw paths. Edges trigger once per entry: repeated updates
-- with an unchanged snapshot never replay a clip.
---@param snapshot StarterChoiceController.Snapshot
function StarterChoicePresentation:_syncPlayback(snapshot)
  self:_syncClock(snapshot)
  local key = snapshot.transition .. "|" .. snapshot.selectionState .. "|" .. tostring(snapshot.selection)
  if key ~= self._lastKey then
    self._lastKey = key
    if snapshot.transition == "zoomIn" then
      local ball = self._instances[BALL_ROLES[snapshot.selection + 1]]
      stopBallClips(ball, self)
      ball:play(self._clipNames.ballRock[snapshot.selection + 1], { loopMode = "loop" })
    elseif snapshot.transition == "lockExit" then
      local ball = self._instances[BALL_ROLES[snapshot.selection + 1]]
      stopBallClips(ball, self)
      ball:play(self._clipNames.ballOpen, { loopMode = "once" })
      local effect = self._instances.ballEffect
      effect:stop(self._clipNames.ballEffect)
      effect:play(self._clipNames.ballEffect, { loopMode = "once" })
    elseif snapshot.transition == "backOut" then
      for _, role in ipairs(BALL_ROLES) do
        stopBallClips(self._instances[role], self)
      end
    elseif snapshot.transition == "idle" and snapshot.selectionState == "confirm" then
      for _, role in ipairs(BALL_ROLES) do
        stopBallClips(self._instances[role], self)
      end
    end
  end
end

-- Platform clock: the turntable yaw the snapshot displays. Rotation entries
-- capture the current yaw and exits settle one full step, so the yaw is a
-- pure function of the snapshot sequence shared by drawing and hit testing.
---@param snapshot StarterChoiceController.Snapshot
function StarterChoicePresentation:_syncClock(snapshot)
  local key = snapshot.transition .. "|" .. snapshot.selectionState .. "|" .. tostring(snapshot.selection)
  if key == self._clockKey then
    return
  end
  if self._clockTransition == "rotate" and snapshot.transition ~= "rotate" then
    self._turntableYaw = self._rotateFrom + self._rotateSign * TURNTABLE_STEP
  end
  if snapshot.transition == "rotate" then
    self._rotateFrom = self._turntableYaw
    self._rotateSign = snapshot.direction == "left" and -1 or 1
  end
  self._clockKey = key
  self._clockTransition = snapshot.transition
end

-- Displayed platform yaw for a snapshot: interpolated through the active
-- rotation, settled otherwise. The balls ride the platform, so drawing and
-- hit testing apply this same yaw.
---@param snapshot StarterChoiceController.Snapshot
---@return number radians
function StarterChoicePresentation:yawForSnapshot(snapshot)
  self:_syncClock(snapshot)
  if snapshot.transition == "rotate" then
    return self._rotateFrom + self._rotateSign * (snapshot.progress / snapshot.ticks) * TURNTABLE_STEP
  end
  return self._turntableYaw
end

-- Advance every model clock one deterministic tick and sync clip playback to
-- the snapshot. A safe no-op before GPU realization so headless compositions
-- can settle transitions without graphics.
---@param snapshot StarterChoiceController.Snapshot
function StarterChoicePresentation:update(snapshot)
  assert(type(snapshot) == "table", "starter presentation update requires the controller snapshot")
  if not self._realized then
    return
  end
  self:_syncPlayback(snapshot)
  for _, role in ipairs({ "turntable", "ballEffect", "ball1", "ball2", "ball3" }) do
    self._instances[role]:updateFixed()
  end
end

---@param snapshot StarterChoiceController.Snapshot
---@return number[] items in source role order
function StarterChoicePresentation:_drawItems(snapshot)
  local items = {}
  local identity = Matrix4.identity()
  for _, batch in ipairs(self._staticBatches) do
    items[#items + 1] = {
      mesh = batch.mesh,
      material = batch.material,
      transform = identity,
      modelNormal = Matrix4.identity(),
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
    }
  end
  local scene = self._manifest.scene
  local progress = cameraProgress(snapshot)
  local ballYaw = math.rad(scene.ballYRotation.out + (scene.ballYRotation.inside - scene.ballYRotation.out) * progress)
  local selected = snapshot.selection + 1
  -- The balls ride the rotating platform: the platform yaw carries every
  -- slot position, and the inspected ball adds its own Y rotation on top.
  local platform = Matrix4.rotateY(self:yawForSnapshot(snapshot))
  local dynamicRoles = { "turntable", "ballEffect", "ball1", "ball2", "ball3" }
  for _, role in ipairs(dynamicRoles) do
    local instance = assert(self._instances[role], "starter presentation is missing " .. role)
    if role == "turntable" then
      instance.transform = platform
    elseif role == "ballEffect" then
      local position = scene.ballPositions[selected]
      instance.transform = Matrix4.multiply(platform, Matrix4.translate(position.x, position.y, position.z))
    else
      local ballIndex = (role == "ball1" and 1) or (role == "ball2" and 2) or 3
      local position = scene.ballPositions[ballIndex]
      local yaw = ballIndex == selected and ballYaw or 0
      instance.transform = Matrix4.multiply(
        platform,
        Matrix4.multiply(Matrix4.translate(position.x, position.y, position.z), Matrix4.rotateY(yaw))
      )
    end
    instance:evaluatePose()
  end
  -- Source role order: tabletop, turntable, effect, then the three balls.
  -- The effect only draws while the lock plays it.
  local ordered = { "turntable", "ball1", "ball2", "ball3" }
  for _, role in ipairs(ordered) do
    local instance = self._instances[role]
    for _, item in ipairs(instance:drawItems(assert(self._renderMeshes[role], "starter meshes missing for " .. role))) do
      items[#items + 1] = item
    end
  end
  if snapshot.transition == "lockExit" or snapshot.transition == "done" then
    local effect = self._instances.ballEffect
    for _, item in ipairs(effect:drawItems(assert(self._renderMeshes.ballEffect, "starter effect meshes are missing"))) do
      items[#items + 1] = item
    end
  end
  return items
end

---@param lines string[]
---@param text table<string, unknown>
---@param x number
---@param y number
local function drawLines(lines, text, x, y)
  for _, line in ipairs(lines) do
    text:drawText(line, x, y)
    y = y + 12
  end
end

---@param message string
---@return string[]
local function messageLines(message)
  local lines = {}
  for line in (message .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  return lines
end

-- Render one application frame: the opaque modal backdrop, the six scene
-- roles under the interpolated camera, then the source message and the
-- inspected species display in DS reference coordinates through the current
-- host viewport.
---@param snapshot StarterChoiceController.Snapshot controller snapshot
---@param view { candidates: table<string, unknown>[], names: string[] }
---@param text table<string, unknown> text provider ({ drawText })
function StarterChoicePresentation:draw(snapshot, view, text)
  assert(type(snapshot) == "table", "starter presentation draw requires the controller snapshot")
  assert(type(view) == "table" and type(view.candidates) == "table", "starter presentation requires its candidates")
  assert(type(view.names) == "table" and #view.names == 3, "starter presentation requires three candidate names")
  assert(text ~= nil and type(text.drawText) == "function", "starter presentation requires the text provider")
  self:_ensureRealized()
  self:_syncPlayback(snapshot)
  local graphics = assert(love and love.graphics, "starter presentation requires the graphics namespace")
  graphics.setColor(0, 0, 0, 1)
  graphics.rectangle("fill", 0, 0, self._width, self._height)
  local viewMatrix, projection = self:cameraMatrices(snapshot)
  ---@return number[]
  local function cameraView()
    return viewMatrix
  end
  ---@return number[]
  local function cameraProjection()
    return projection
  end
  ---@return number[]
  local function cameraBillboardProjection()
    return projection
  end
  local camera = {
    far = CAMERA_FAR,
    zoom = 1,
    view = cameraView,
    projection = cameraProjection,
    billboardProjection = cameraBillboardProjection,
  }
  assert(self._renderer, "starter presentation has no renderer")
  self._renderer:draw(self._sceneRuntime, camera, { self:_drawItems(snapshot) }, nil, self._viewport, 1)
  local frame = self._viewport.referenceFrame
  local scale = frame.height / self._manifest.reference.height
  graphics.push()
  graphics.translate(frame.x, frame.y)
  graphics.scale(scale, scale)
  graphics.setColor(1, 1, 1, 1)
  local messages = self._manifest.messages
  if snapshot.selectionState == "confirm" then
    drawLines(messageLines(messages.confirm), text, 16, 160)
  else
    drawLines(messageLines(messages.initial), text, 16, 148)
  end
  if snapshot.selectionState ~= "null" then
    local candidate = assert(view.candidates[snapshot.selection + 1], "starter presentation is missing its candidate")
    local spriteId = string.lower(assert(candidate.species, "starter candidate carries its species key"))
    local sprite = assert(
      self._speciesImages[spriteId],
      "starter application has no display sprite for " .. tostring(candidate.species)
    )
    graphics.setColor(1, 1, 1, 1)
    graphics.draw(sprite, 196, 24)
    text:drawText(view.names[snapshot.selection + 1], 184, 64)
  end
  graphics.setColor(1, 1, 1, 1)
  graphics.pop()
end

function StarterChoicePresentation:_releaseGpu()
  if self._renderer ~= nil then
    self._renderer:release()
    self._renderer = nil
  end
  if self._pool ~= nil then
    self._pool:release()
    self._pool = nil
  end
  self._definitions = {}
  self._renderMeshes = {}
  self._wraps = {}
  self._instances = {}
  self._staticBatches = {}
  self._speciesImages = {}
  self._clipNames = { turntable = "", ballEffect = "", ballRock = {}, ballOpen = "" }
  self._realized = false
end

-- Release every acquired GPU/model resource exactly once. Safe before
-- realization and safe to repeat: closing during a transition or disposing
-- twice never touches a live object.
function StarterChoicePresentation:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self:_releaseGpu()
end

return StarterChoicePresentation
