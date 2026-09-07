-- Game-local retail starter-application presentation. It realizes one
-- validated starter-application manifest through the shared model stack
-- (ModelDefinition/ModelInstance over a GpuAssetPool, drawn through
-- FieldRenderer under the manifest's outside/inside camera poses), the
-- chooser-owned backdrop, the three candidate portraits borrowed from the
-- mon portrait atlas, and the shared HGSS window primitive for the framed
-- message surfaces. Two logical 256x192 surfaces share one host drawable:
-- the machine surface carries the 3D machine/balls plus the bottom prompt,
-- and the info surface carries the semantic message plus the inspected
-- portrait companion. Pointer input resolves in the machine surface only.
-- Owned exclusively by StarterChoiceState, which is its only caller: this
-- helper never decides the choice, publishes mons, mutates saves, or polls
-- input. GPU resources are acquired lazily on first draw so headless
-- compositions can open, drive, and close the choice without graphics, and
-- release exactly once on dispose.

local StarterChoiceAssetCache = require("libs.assets.src.StarterChoiceAssetCache")
local MonCache = require("libs.assets.src.MonCache")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local FieldWindowRenderer = require("libs.hgss.src.ui.FieldWindowRenderer")
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local Matrix4 = require("libs.math.src.Matrix4")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")
local FixedPoint = require("libs.math.src.FixedPoint")

---@class StarterChoicePresentation
---@field _manifest table<string, unknown> immutable validated starter-application manifest
---@field _cacheFs table<string, unknown> generated-asset filesystem the model/texture bytes read through
---@field _portraits table[] per-candidate portrait descriptors ({ selector }) borrowed from state
---@field _machine table<string, unknown> host rectangle of the machine surface
---@field _info table<string, unknown> host rectangle of the info surface
---@field _width number last drawable width
---@field _height number last drawable height
---@field _pool GpuAssetPool? GPU mesh/image owner once realized
---@field _renderer FieldRenderer? field renderer once realized
---@field _window table<string, unknown>? shared HGSS window primitive once realized
---@field _realized boolean
---@field _disposed boolean
---@field _definitions table<string, ModelDefinition> model definitions by scene role
---@field _renderMeshes table<string, table<string, unknown>> render meshes by role then mesh id
---@field _wraps table<string, table<string, unknown>> sampler wraps by role then zero-based material index
---@field _instances table<string, ModelInstance> model instances by scene role
---@field _staticBatches table[] prepared tabletop batches
---@field _backdropImage GpuAssetPool.Image? chooser backdrop image once realized
---@field _portraitImage GpuAssetPool.Image? mon portrait atlas image once realized
---@field _portraitQuads table[] portrait atlas quads per candidate slot once realized
---@field _clipNames { turntable: string, ballEffect: string, ballRock: string[], ballOpen: string } instance play names resolved from bindings
---@field _sceneRuntime table<string, unknown> minimal renderer scene state (edge colors, fog, flat lighting)
---@field _entryTransition string? transition of the last semantic clock sync
---@field _cameraKey string? last snapshot key the camera matrices were built for
---@field _cameraView number[]? cached view matrix for the camera key
---@field _cameraProjection number[]? cached projection matrix for the camera key
---@field _rotateSign number rotation direction sign while rotating
---@field _rotationAccum number turntable degrees accumulated in the active rotation
---@field _cameraStep integer camera interpolation steps taken in the active zoom path
---@field _arcStep integer selected ball arc steps taken in the active zoom path
---@field _lockCameraStep integer camera-out steps taken in the active lock exit
---@field _rockFrame integer selected ball rock frames advanced since inspect entry
---@field _rockSelection integer? selection the rock frame belongs to, nil while rock is inactive
---@field _infoFade integer info-surface white fade ticks in the active lock exit
---@field _machineFade integer machine-surface white fade ticks after the info fade
---@field _openFrame integer selected ball-open frames advanced in the active lock exit
---@field _effectFrame integer ball-effect frames advanced in the active lock exit
---@field _rockPlayingFor integer? selection the realized rock clip plays for, nil when unrealized/inactive
---@field _exitPlaying boolean the realized open/effect clips play for the active lock exit
local StarterChoicePresentation = {}
StarterChoicePresentation.__index = StarterChoicePresentation

local ROLES = { "tabletop", "turntable", "ballEffect", "ball1", "ball2", "ball3" }
local BALL_ROLES = { "ball1", "ball2", "ball3" }

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

-- Surface-local geometry in each 256x192 logical surface: the bottom prompt
-- window on the machine surface, and the message window plus the portrait
-- companion slot on the info surface.
local PROMPT_BOX = { x = 16, y = 152, width = 216, height = 32 }
local INFO_BOX = { x = 16, y = 12, width = 224, height = 56 }
local PORTRAIT_SLOT = { x = 88, y = 84, width = 80, height = 80 }

-- Host gap between the machine and info surfaces; placement only, never a
-- semantic coordinate. Matches StarterChoiceState.
local SURFACE_GAP = 8

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

---@param width number
---@param height number
---@return table<string, unknown> machineRect, table<string, unknown> infoRect
local function layoutSurfaces(width, height)
  local scale = math.min(height / 192, (width - SURFACE_GAP) / 512)
  assert(scale > 0, "starter presentation resize requires a non-degenerate drawable size")
  local surfaceWidth, surfaceHeight = 256 * scale, 192 * scale
  local originX = (width - (surfaceWidth * 2 + SURFACE_GAP)) / 2
  local originY = (height - surfaceHeight) / 2
  return { x = originX, y = originY, width = surfaceWidth, height = surfaceHeight }, {
    x = originX + surfaceWidth + SURFACE_GAP,
    y = originY,
    width = surfaceWidth,
    height = surfaceHeight,
  }
end

---@class StarterChoicePresentation.Options
---@field manifest table<string, unknown> validated starter-application manifest
---@field cacheFs table<string, unknown> generated-asset filesystem
---@field portraits table[] per-candidate portrait descriptors ({ selector: string })

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
  assert(
    type(opts.portraits) == "table" and #opts.portraits == 3,
    "starter presentation requires three portrait descriptors"
  )
  for index, descriptor in ipairs(opts.portraits) do
    assert(
      type(descriptor) == "table" and type(descriptor.selector) == "string",
      "starter portrait descriptor " .. index .. " carries its atlas selector"
    )
  end
  local reference = opts.manifest.reference
  local machine, info = layoutSurfaces(reference.width * 2, reference.height)
  local self = setmetatable({
    _manifest = opts.manifest,
    _cacheFs = opts.cacheFs,
    _portraits = opts.portraits,
    _machine = machine,
    _info = info,
    _width = reference.width * 2,
    _height = reference.height,
    _pool = nil,
    _renderer = nil,
    _window = nil,
    _realized = false,
    _disposed = false,
    _definitions = {},
    _renderMeshes = {},
    _wraps = {},
    _instances = {},
    _staticBatches = {},
    _backdropImage = nil,
    _portraitImage = nil,
    _portraitQuads = {},
    _clipNames = { turntable = "", ballEffect = "", ballRock = {}, ballOpen = "" },
    _sceneRuntime = {},
    _entryTransition = nil,
    _cameraKey = nil,
    _cameraView = nil,
    _cameraProjection = nil,
    _rotateSign = 0,
    _rotationAccum = 0,
    _cameraStep = 0,
    _arcStep = 0,
    _lockCameraStep = 0,
    _rockFrame = 0,
    _rockSelection = nil,
    _infoFade = 0,
    _machineFade = 0,
    _openFrame = 0,
    _effectFrame = 0,
    _rockPlayingFor = nil,
    _exitPlaying = false,
  }, StarterChoicePresentation)
  return self
end

-- Clears every semantic playback clock for a fresh open. Instances are
-- per-presentation, so a reset presentation starts with the camera outside,
-- no clip playing, and no fade covering either surface.
function StarterChoicePresentation:reset()
  self._entryTransition = nil
  self._cameraKey = nil
  self._cameraView = nil
  self._cameraProjection = nil
  self._rotateSign = 0
  self._rotationAccum = 0
  self._cameraStep = 0
  self._arcStep = 0
  self._lockCameraStep = 0
  self._rockFrame = 0
  self._rockSelection = nil
  self._infoFade = 0
  self._machineFade = 0
  self._openFrame = 0
  self._effectFrame = 0
  self._rockPlayingFor = nil
  self._exitPlaying = false
end

---@param width number
---@param height number
---@param machineRect table<string, unknown>? host rectangle of the machine surface
---@param infoRect table<string, unknown>? host rectangle of the info surface
function StarterChoicePresentation:resize(width, height, machineRect, infoRect)
  assert(type(width) == "number" and width > 0, "starter presentation resize requires a positive width")
  assert(type(height) == "number" and height > 0, "starter presentation resize requires a positive height")
  self._width = width
  self._height = height
  if machineRect ~= nil and infoRect ~= nil then
    self._machine = {
      x = machineRect.x,
      y = machineRect.y,
      width = machineRect.width,
      height = machineRect.height,
    }
    self._info = { x = infoRect.x, y = infoRect.y, width = infoRect.width, height = infoRect.height }
  else
    self._machine, self._info = layoutSurfaces(width, height)
  end
end

-- Host pixels into the machine surface's DS reference frame; nil when the
-- point falls outside the machine surface. Info-surface and backdrop points
-- never map onto the balls.
---@param x number
---@param y number
---@return number?, number?
function StarterChoicePresentation:toMachineReference(x, y)
  assert(type(x) == "number" and type(y) == "number", "starter pointer position must be numeric")
  local machine = self._machine
  if x < machine.x or x >= machine.x + machine.width or y < machine.y or y >= machine.y + machine.height then
    return nil, nil
  end
  local reference = self._manifest.reference
  return (x - machine.x) / machine.width * reference.width, (y - machine.y) / machine.height * reference.height
end

-- Interpolated camera pose for the current semantic clocks: the zoom path
-- dollies from the outside pose to the inside pose over the source camera
-- steps, reversal returns over the same steps, confirmation holds inside,
-- and the locking exit dollies back out over its own camera-out steps.
---@param snapshot StarterChoiceController.Snapshot
---@return number 0..1
function StarterChoicePresentation:_cameraAlpha(snapshot)
  local cameraTicks = self._manifest.scene.timing.cameraTicks
  if snapshot.transition == "zoomIn" then
    return math.min(1, self._cameraStep / cameraTicks)
  end
  if snapshot.transition == "waitZoom" then
    return 1
  end
  if snapshot.transition == "backOut" then
    return 1 - math.min(1, self._cameraStep / cameraTicks)
  end
  if snapshot.transition == "lockExit" or snapshot.transition == "done" then
    return 1 - math.min(1, self._lockCameraStep / cameraTicks)
  end
  if snapshot.selectionState == "confirm" then
    return 1
  end
  return 0
end

-- Selected ball X-arc for the current semantic clocks: in over the source
-- ball-arc steps with the camera, held inside through confirmation and the
-- lock exit, and back out with reversal.
---@param snapshot StarterChoiceController.Snapshot
---@return number 0..1
function StarterChoicePresentation:_arcAlpha(snapshot)
  local ballArcTicks = self._manifest.scene.timing.ballArcTicks
  if snapshot.transition == "zoomIn" then
    return math.min(1, self._arcStep / ballArcTicks)
  end
  if snapshot.transition == "waitZoom" then
    return 1
  end
  if snapshot.transition == "backOut" then
    return 1 - math.min(1, self._arcStep / ballArcTicks)
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
    .. tostring(self._cameraStep)
    .. "|"
    .. tostring(self._lockCameraStep)
    .. "|"
    .. tostring(snapshot.direction)
  if key ~= self._cameraKey then
    local camera = self._manifest.scene.camera
    local pose = interpolatePose(camera.out, camera.inside, self:_cameraAlpha(snapshot))
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

-- Ring slot origins in turntable-local space: the source radius around Y at
-- the source model height, one slot angle per ball starting from the
-- selected ball, which always rests at the front of the ring. Rotation
-- reassigns the slots from the new selection while the platform yaw carries
-- the visual travel between assignments.
---@param snapshot StarterChoiceController.Snapshot controller snapshot carrying the selection
---@return table[] { x, y, z } per ball, 1-based in ball order
function StarterChoicePresentation:modelOrigins(snapshot)
  local layout = self._manifest.scene.ballLayout
  local origins = {}
  for ball = 1, 3 do
    local relative = (ball - 1 - snapshot.selection) % 3
    local angle = math.rad(layout.slotAnglesDegrees[relative + 1])
    origins[ball] = { x = layout.radius * math.sin(angle), y = layout.modelY, z = layout.radius * math.cos(angle) }
  end
  return origins
end

-- Touch centers in turntable-local space: the same rotated X/Z point as the
-- model origins, held above them by the source touch offset. Model and touch
-- centers are never interchangeable.
---@param snapshot StarterChoiceController.Snapshot controller snapshot carrying the selection
---@return table[] { x, y, z } per ball, 1-based in ball order
function StarterChoicePresentation:touchOrigins(snapshot)
  local layout = self._manifest.scene.ballLayout
  local origins = {}
  for ball = 1, 3 do
    local relative = (ball - 1 - snapshot.selection) % 3
    local angle = math.rad(layout.slotAnglesDegrees[relative + 1])
    origins[ball] = {
      x = layout.radius * math.sin(angle),
      y = layout.modelY + layout.touchYOffsetY,
      z = layout.radius * math.cos(angle),
    }
  end
  return origins
end

-- Projects turntable-local origins through the platform yaw and the
-- snapshot camera into the DS reference frame.
---@param origins table[]
---@param snapshot StarterChoiceController.Snapshot
---@return table[] { x, y } per ball, 1-based in ball order
function StarterChoicePresentation:projectOrigins(origins, snapshot)
  local yaw = self:yawForSnapshot(snapshot)
  local view, projection = self:cameraMatrices(snapshot)
  local combined = Matrix4.multiply(projection, Matrix4.multiply(view, Matrix4.rotateY(yaw)))
  local reference = self._manifest.reference
  local centers = {}
  for index, position in ipairs(origins) do
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

-- Projected model origins in the DS reference frame under the snapshot's
-- camera and platform rotation. Pure camera math over the manifest's ring
-- layout, shared by drawing alignment.
---@param snapshot StarterChoiceController.Snapshot
---@return table[] { x, y } per ball, 1-based in ball order
function StarterChoicePresentation:ballCenters(snapshot)
  return self:projectOrigins(self:modelOrigins(snapshot), snapshot)
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
-- Points outside the 256x192 reference frame never hit. Hit testing
-- projects the separate touch centers held above the model origins.
---@param x number
---@param y number
---@param snapshot StarterChoiceController.Snapshot
---@return integer?
function StarterChoicePresentation:ballAt(x, y, snapshot)
  assert(type(x) == "number" and type(y) == "number", "starter pointer position must be numeric")
  assert(type(snapshot) == "table", "starter hit testing requires the controller snapshot")
  local reference = self._manifest.reference
  if x < 0 or x >= reference.width or y < 0 or y >= reference.height then
    return nil
  end
  local centers = self:projectOrigins(self:touchOrigins(snapshot), snapshot)
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
      local background = self._manifest.background
      local backdropPath = background.image or assert(background.horizontal).image
      self._backdropImage = pool:imageFor(backdropPath, "clamp", "clamp")
      self._portraitImage = pool:imageFor(MonCache.portraitImagePath(), "clamp", "clamp")
    end)
    local uiManifest = self._cacheFs:loadLua(FieldUiAssetCache.manifestPath())
    assert(uiManifest ~= nil, "starter presentation requires the generated field-UI manifest")
    assert(FieldUiAssetCache.validateManifest(uiManifest), "starter field-UI manifest is invalid")
    self._window = FieldWindowRenderer.new({ cacheFs = self._cacheFs, manifest = uiManifest, graphics = graphics })
    local portraitManifest = self._cacheFs:loadLua(MonCache.portraitManifestPath())
    assert(portraitManifest ~= nil, "starter presentation requires the mon portrait entries")
    local entries = assert(portraitManifest.entries, "starter presentation requires the mon portrait entries")
    local atlas = assert(self._portraitImage, "starter presentation owns no portrait atlas")
    local atlasWidth, atlasHeight = atlas:getWidth(), atlas:getHeight()
    for index, descriptor in ipairs(self._portraits) do
      local entry = assert(
        entries[descriptor.selector],
        "starter candidate has no portrait entry for " .. tostring(descriptor.selector)
      )
      self._portraitQuads[index] =
        graphics.newQuad(entry.x, entry.y, entry.width, entry.height, atlasWidth, atlasHeight)
    end
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

-- Whether the selected ball rocks under a snapshot: throughout inspection
-- (idle, rotating, zooming, waiting) and while confirmation idles. Reversal,
-- the lock exit, and the uninspected chooser park every ball at baseline.
---@param snapshot StarterChoiceController.Snapshot
---@return boolean
local function rockActive(snapshot)
  if snapshot.selectionState == "inspect" then
    return snapshot.transition ~= "backOut" and snapshot.transition ~= "lockExit" and snapshot.transition ~= "done"
  end
  return snapshot.selectionState == "confirm" and snapshot.transition == "idle"
end

---@param attachment table<string, unknown>|nil live clip attachment
---@param frames integer semantic frames to catch up
local function fastForward(attachment, frames)
  local player = attachment ~= nil and attachment.player or nil
  if player == nil or type(frames) ~= "number" or frames <= 0 then
    return
  end
  for _ = 1, frames do
    if player.completed then
      return
    end
    player:updateFixed()
  end
end

-- Starts the clips a snapshot needs on the realized instances, exactly once
-- per entry, without touching any semantic clock. Late realization
-- fast-forwards each new player to the current semantic frame so headless
-- progress and realized playback agree without replaying entry effects.
---@param snapshot StarterChoiceController.Snapshot
function StarterChoicePresentation:_syncRealized(snapshot)
  if not self._realized then
    return
  end
  if self._instances.ball1 == nil then
    return
  end
  if rockActive(snapshot) then
    if self._rockPlayingFor ~= snapshot.selection then
      local selected = snapshot.selection + 1
      for index, role in ipairs(BALL_ROLES) do
        local instance = self._instances[role]
        if instance ~= nil then
          stopBallClips(instance, self)
          if index == selected then
            fastForward(instance:play(self._clipNames.ballRock[index], { loopMode = "loop" }), self._rockFrame)
          end
        end
      end
      local effect = self._instances.ballEffect
      if effect ~= nil then
        effect:stop(self._clipNames.ballEffect)
      end
      self._rockPlayingFor = snapshot.selection
      self._exitPlaying = false
    end
    return
  end
  if snapshot.transition == "lockExit" or snapshot.transition == "done" then
    if not self._exitPlaying then
      local selected = snapshot.selection + 1
      for index, role in ipairs(BALL_ROLES) do
        local instance = self._instances[role]
        if instance ~= nil then
          stopBallClips(instance, self)
          if index == selected then
            fastForward(instance:play(self._clipNames.ballOpen, { loopMode = "once" }), self._openFrame)
          end
        end
      end
      local effect = self._instances.ballEffect
      if effect ~= nil then
        effect:stop(self._clipNames.ballEffect)
        fastForward(effect:play(self._clipNames.ballEffect, { loopMode = "once" }), self._effectFrame)
      end
      self._exitPlaying = true
      self._rockPlayingFor = nil
    end
    return
  end
  if self._rockPlayingFor ~= nil or self._exitPlaying then
    for _, role in ipairs(BALL_ROLES) do
      local instance = self._instances[role]
      if instance ~= nil then
        stopBallClips(instance, self)
      end
    end
    local effect = self._instances.ballEffect
    if effect ~= nil then
      effect:stop(self._clipNames.ballEffect)
    end
    self._rockPlayingFor = nil
    self._exitPlaying = false
  end
end

-- Resets the clocks a newly entered transition owns. Selection and
-- interaction-state changes inside one transition are left to the advance
-- step, which restarts the rock frame when the inspected ball changes.
---@param snapshot StarterChoiceController.Snapshot
function StarterChoicePresentation:_detectEntry(snapshot)
  if snapshot.transition == self._entryTransition then
    return
  end
  if snapshot.transition == "rotate" then
    self._rotationAccum = 0
    self._rotateSign = snapshot.direction == "left" and 1 or -1
  elseif snapshot.transition == "zoomIn" then
    self._cameraStep = 0
    self._arcStep = 0
  elseif snapshot.transition == "backOut" then
    self._cameraStep = 0
    self._arcStep = 0
  elseif snapshot.transition == "lockExit" then
    self._lockCameraStep = 0
    self._infoFade = 0
    self._machineFade = 0
    self._openFrame = 0
    self._effectFrame = 0
  end
  if self._entryTransition == "rotate" and snapshot.transition ~= "rotate" then
    self._rotationAccum = 0
  end
  self._entryTransition = snapshot.transition
  self._cameraKey = nil
end

-- Advances every semantic clock one deterministic source tick for the
-- snapshot that opened the tick. Rotation accumulates its source degrees,
-- the zoom paths step their independent camera/arc clocks, the selected
-- rock frame runs whenever the ball visibly rocks, and the lock exit steps
-- ball-open/effect, the camera-out path, and the sequential surface fades.
---@param snapshot StarterChoiceController.Snapshot
function StarterChoicePresentation:_advance(snapshot)
  local timing = self._manifest.scene.timing
  local turntable = self._manifest.scene.turntable
  local transition = snapshot.transition
  if transition == "rotate" then
    self._rotationAccum =
      math.min(turntable.selectionStepDegrees, self._rotationAccum + turntable.rotationDegreesPerTick)
  elseif transition == "zoomIn" then
    self._cameraStep = math.min(timing.cameraTicks, self._cameraStep + 1)
    self._arcStep = math.min(timing.ballArcTicks, self._arcStep + 1)
  elseif transition == "backOut" then
    self._cameraStep = math.min(timing.cameraTicks, self._cameraStep + 1)
    self._arcStep = math.min(timing.ballArcTicks, self._arcStep + 1)
  elseif transition == "lockExit" then
    self._lockCameraStep = math.min(timing.cameraTicks, self._lockCameraStep + 1)
    self._openFrame = self._openFrame + 1
    self._effectFrame = self._effectFrame + 1
    if self._infoFade < timing.infoFadeTicks then
      self._infoFade = self._infoFade + 1
    else
      self._machineFade = math.min(timing.machineFadeTicks, self._machineFade + 1)
    end
  end
  if rockActive(snapshot) then
    if self._rockSelection ~= snapshot.selection then
      self._rockFrame = 0
      self._rockSelection = snapshot.selection
    end
    self._rockFrame = self._rockFrame + 1
  else
    self._rockFrame = 0
    self._rockSelection = nil
  end
end

-- Completion observation for the snapshot that opened the tick, from the
-- clocks the advance step just settled. Fields the controller's current
-- transition does not read are still populated; an all-false observation
-- never completes any transition.
---@param snapshot StarterChoiceController.Snapshot
---@return { rotationComplete: boolean, cameraComplete: boolean, ballArcComplete: boolean, smallWobbleReady: boolean, infoFadeComplete: boolean, machineFadeComplete: boolean } observation
function StarterChoicePresentation:_observation(snapshot)
  local timing = self._manifest.scene.timing
  local turntable = self._manifest.scene.turntable
  local inZoomPath = snapshot.transition == "zoomIn" or snapshot.transition == "backOut"
  return {
    rotationComplete = snapshot.transition == "rotate" and self._rotationAccum >= turntable.selectionStepDegrees - 1e-9,
    cameraComplete = inZoomPath and self._cameraStep >= timing.cameraTicks,
    ballArcComplete = inZoomPath and self._arcStep >= timing.ballArcTicks,
    smallWobbleReady = self._rockFrame >= timing.smallWobbleFrame,
    infoFadeComplete = self._infoFade >= timing.infoFadeTicks,
    machineFadeComplete = self._machineFade >= timing.machineFadeTicks,
  }
end

-- Displayed platform yaw: the accumulated source rotation while the
-- turntable travels, settled to zero otherwise. Slots are
-- selection-relative, so the settled yaw is always zero: rotation exits snap
-- back together with the slot reassignment, and the yaw purely carries the
-- visual travel between assignments. Pure in the semantic clocks, shared by
-- drawing and hit testing; it never advances a clock.
---@param snapshot StarterChoiceController.Snapshot
---@return number radians
function StarterChoicePresentation:yawForSnapshot(snapshot)
  if snapshot.transition == "rotate" then
    return self._rotateSign * math.rad(self._rotationAccum)
  end
  return 0
end

-- Advances every semantic clock one deterministic tick for the snapshot that
-- opened the tick, synchronizes realized model/fade objects to those clocks,
-- and returns the completion observation for the controller. A safe,
-- deterministic progression before GPU realization so headless compositions
-- settle transitions without graphics; realized clips catch up to the same
-- clocks without replaying entry effects.
---@param snapshot StarterChoiceController.Snapshot
---@return { rotationComplete: boolean, cameraComplete: boolean, ballArcComplete: boolean, smallWobbleReady: boolean, infoFadeComplete: boolean, machineFadeComplete: boolean } observation
function StarterChoicePresentation:update(snapshot)
  assert(type(snapshot) == "table", "starter presentation update requires the controller snapshot")
  self:_detectEntry(snapshot)
  self:_advance(snapshot)
  if self._realized then
    for _, role in ipairs({ "turntable", "ballEffect", "ball1", "ball2", "ball3" }) do
      local instance = self._instances[role]
      if instance ~= nil then
        instance:updateFixed()
      end
    end
  end
  self:_syncRealized(snapshot)
  return self:_observation(snapshot)
end

-- Arcs a turntable-local point around the X axis by the inspect arc about
-- the selected touch point. The source names this path after Y, but the
-- implementation arcs the selected translation around X pivoted at the
-- touch height and records the same angle as the ball X rotation.
---@param point table<string, unknown> { x, y, z }
---@param pivot table<string, unknown> { x, y, z }
---@param arc number radians
---@return table<string, unknown> { x, y, z }
local function arcPoint(point, pivot, arc)
  local cosine, sine = math.cos(arc), math.sin(arc)
  local y, z = point.y - pivot.y, point.z - pivot.z
  return { x = point.x, y = y * cosine - z * sine + pivot.y, z = y * sine + z * cosine + pivot.z }
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
      polygonAlpha = batch.polygonAlpha / FixedPoint.RGB5_MAX,
      polygonMode = batch.polygonMode,
      polygonId = batch.polygonId,
      translucentDepthWrite = batch.translucentDepthWrite,
      depthEqual = batch.depthEqual,
      lightMask = batch.lightMask,
      fogEnabled = batch.fogEnabled,
    }
  end
  local layout = self._manifest.scene.ballLayout
  local arc = math.rad(layout.inspectArcDegrees * self:_arcAlpha(snapshot))
  local selected = snapshot.selection + 1
  -- The balls ride the rotating platform: the platform yaw carries every
  -- slot origin, each ball keeps its slot Y orientation, and the inspected
  -- ball adds its own X-axis arc about its touch point on top.
  local platform = Matrix4.rotateY(self:yawForSnapshot(snapshot))
  local origins = self:modelOrigins(snapshot)
  local touches = self:touchOrigins(snapshot)
  local dynamicRoles = { "turntable", "ballEffect", "ball1", "ball2", "ball3" }
  for _, role in ipairs(dynamicRoles) do
    local instance = assert(self._instances[role], "starter presentation is missing " .. role)
    if role == "turntable" then
      instance.transform = platform
    elseif role == "ballEffect" then
      local position = arcPoint(origins[selected], touches[selected], arc)
      instance.transform = Matrix4.multiply(platform, Matrix4.translate(position.x, position.y, position.z))
    else
      local ballIndex = (role == "ball1" and 1) or (role == "ball2" and 2) or 3
      local relative = (ballIndex - 1 - snapshot.selection) % 3
      local slotYaw = Matrix4.rotateY(math.rad(layout.slotAnglesDegrees[relative + 1]))
      local position = origins[ballIndex]
      if ballIndex == selected then
        local arced = arcPoint(position, touches[ballIndex], arc)
        instance.transform = Matrix4.multiply(
          platform,
          Matrix4.multiply(
            Matrix4.translate(arced.x, arced.y, arced.z),
            Matrix4.multiply(Matrix4.rotateX(arc), slotYaw)
          )
        )
      else
        instance.transform =
          Matrix4.multiply(platform, Matrix4.multiply(Matrix4.translate(position.x, position.y, position.z), slotYaw))
      end
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

-- Draws one framed window with its semantic message inside one logical
-- surface. The message goes out through one text call carrying the full
-- semantic string; the surface transform maps the 256x192 reference frame
-- onto the host rectangle and the shared window primitive owns the frame
-- artwork.
---@param surface table<string, unknown> host rectangle of the logical surface
---@param box table<string, unknown> content box in surface-local reference coordinates
---@param message string semantic message for the window
---@param text table<string, unknown> text provider ({ drawText, windowBackgroundColor })
function StarterChoicePresentation:_drawSurfaceWindow(surface, box, message, text)
  local graphics = assert(love and love.graphics, "starter presentation requires the graphics namespace")
  local reference = self._manifest.reference
  graphics.push()
  graphics.translate(surface.x, surface.y)
  graphics.scale(surface.width / reference.width, surface.height / reference.height)
  assert(self._window, "starter presentation owns no window primitive"):drawWindow(box, 0, text:windowBackgroundColor())
  text:drawText(message, box.x + 8, box.y + 8)
  graphics.pop()
end

-- Draws the sequential source white fade over one semantic surface from
-- its fade clock. The info surface fades first, then the machine surface;
-- either overlay is absent while its clock has not started. A read-only
-- cover: it never advances a clock.
---@param surface table<string, unknown> host rectangle of the logical surface
---@param alpha number 0..1 white coverage
function StarterChoicePresentation:_drawSurfaceFade(surface, alpha)
  if alpha <= 0 then
    return
  end
  if alpha > 1 then
    alpha = 1
  end
  local graphics = assert(love and love.graphics, "starter presentation requires the graphics namespace")
  graphics.setColor(1, 1, 1, alpha)
  graphics.rectangle("fill", surface.x, surface.y, surface.width, surface.height)
end

-- Render one application frame: the chooser-owned host backdrop, the 3D
-- machine under the interpolated camera on the machine surface with the
-- bottom prompt beneath it, and the semantic message plus the inspected
-- portrait companion on the info surface.
---@param snapshot StarterChoiceController.Snapshot controller snapshot
---@param view { candidates: table<string, unknown>[], names: string[] }
---@param text table<string, unknown> text provider ({ drawText, windowBackgroundColor })
function StarterChoicePresentation:draw(snapshot, view, text)
  assert(type(snapshot) == "table", "starter presentation draw requires the controller snapshot")
  assert(type(view) == "table" and type(view.candidates) == "table", "starter presentation requires its candidates")
  assert(type(view.names) == "table" and #view.names == 3, "starter presentation requires three candidate names")
  assert(text ~= nil and type(text.drawText) == "function", "starter presentation requires the text provider")
  assert(
    text ~= nil and type(text.windowBackgroundColor) == "function",
    "starter presentation requires the window background color"
  )
  self:_ensureRealized()
  self:_syncRealized(snapshot)
  local graphics = assert(love and love.graphics, "starter presentation requires the graphics namespace")
  graphics.setColor(1, 1, 1, 1)
  local backdrop = assert(self._backdropImage, "starter presentation owns no backdrop")
  graphics.draw(backdrop, 0, 0, 0, self._width / backdrop:getWidth(), self._height / backdrop:getHeight())
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
  local machine = self._machine
  self._renderer:draw(
    self._sceneRuntime,
    camera,
    { self:_drawItems(snapshot) },
    nil,
    { worldViewport = machine, referenceFrame = machine },
    1
  )
  local messages = self._manifest.messages
  local infoText, promptText
  if snapshot.selectionState == "confirm" then
    infoText = messages.confirm[snapshot.selection + 1]
    promptText = messages.bottom.confirm
  elseif snapshot.selectionState == "inspect" then
    infoText = messages.inspect[snapshot.selection + 1]
    promptText = messages.bottom.normal
  else
    infoText = messages.topInitial
    promptText = messages.bottom.normal
  end
  self:_drawSurfaceWindow(machine, PROMPT_BOX, promptText, text)
  self:_drawSurfaceWindow(self._info, INFO_BOX, infoText, text)
  if snapshot.selectionState ~= "null" then
    local quad = assert(
      self._portraitQuads[snapshot.selection + 1],
      "starter presentation owns no portrait for the inspected candidate"
    )
    local atlas = assert(self._portraitImage, "starter presentation owns no portrait atlas")
    local reference = self._manifest.reference
    local info = self._info
    graphics.push()
    graphics.translate(info.x, info.y)
    graphics.scale(info.width / reference.width, info.height / reference.height)
    graphics.setColor(1, 1, 1, 1)
    graphics.draw(atlas, quad, PORTRAIT_SLOT.x, PORTRAIT_SLOT.y)
    graphics.pop()
  end
  local timing = self._manifest.scene.timing
  self:_drawSurfaceFade(self._info, self._infoFade / timing.infoFadeTicks)
  self:_drawSurfaceFade(self._machine, self._machineFade / timing.machineFadeTicks)
  graphics.setColor(1, 1, 1, 1)
end

function StarterChoicePresentation:_releaseGpu()
  if self._window ~= nil then
    self._window:release()
    self._window = nil
  end
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
  self._backdropImage = nil
  self._portraitImage = nil
  self._portraitQuads = {}
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
