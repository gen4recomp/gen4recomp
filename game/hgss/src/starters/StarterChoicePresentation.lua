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
---@field _lastKey string? last snapshot key the playback state synced to
---@field _clockKey string? last snapshot key the platform clock synced to
---@field _clockTransition string? transition of the last clock sync
---@field _cameraKey string? last snapshot key the camera matrices were built for
---@field _cameraView number[]? cached view matrix for the camera key
---@field _cameraProjection number[]? cached projection matrix for the camera key
---@field _turntableYaw number transitional turntable rotation, zero at rest
---@field _rotateFrom number yaw at the active rotation's entry
---@field _rotateSign number rotation direction sign while rotating
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

-- One turntable step per rotated ball: the manifest selection step spans a
-- third of the ring.
---@return number radians
function StarterChoicePresentation:turntableStep()
  return math.rad(self._manifest.scene.turntable.selectionStepDegrees)
end

-- Platform clock: the transitional turntable yaw the snapshot displays.
-- Slots are selection-relative, so the settled yaw is always zero: rotation
-- entries start from zero, exits snap back to zero together with the slot
-- reassignment, and the yaw purely carries the visual travel between
-- assignments. The sign mirrors the source base rotation for the equivalent
-- selection change. Pure in the snapshot sequence, shared by drawing and
-- hit testing.
---@param snapshot StarterChoiceController.Snapshot
function StarterChoicePresentation:_syncClock(snapshot)
  local key = snapshot.transition
    .. "|"
    .. snapshot.selectionState
    .. "|"
    .. tostring(snapshot.selection)
    .. "|"
    .. tostring(snapshot.progress)
    .. "|"
    .. tostring(snapshot.ticks)
  if key == self._clockKey then
    return
  end
  if self._clockTransition == "rotate" and snapshot.transition ~= "rotate" then
    self._turntableYaw = 0
  end
  if snapshot.transition == "rotate" then
    self._rotateFrom = 0
    self._rotateSign = snapshot.direction == "left" and 1 or -1
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
    return self._rotateFrom + self._rotateSign * (snapshot.progress / snapshot.ticks) * self:turntableStep()
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
  local arc = math.rad(layout.inspectArcDegrees * cameraProgress(snapshot))
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
  self:_syncPlayback(snapshot)
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
