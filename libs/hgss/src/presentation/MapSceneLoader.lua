-- Turns the derived map cache into a visual runtime scene the renderer can
-- draw: it reads scene.lua, builds one persistent love Mesh per unique
-- `.g4mesh` path and one Image per unique (texture, wrap) sampler state (both
-- deduplicated through the shared GpuAssetPool, so repeated building models
-- and shared textures cost a single GPU object per sampler), wraps each
-- material's render state, resolves every placed building instance through
-- its model descriptor, and loads the scene's collision asset into a
-- CollisionGrid (the door-ownership pass resolves against it). A billboard
-- batch keeps its camera-independent base center and scale for the shader
-- instead of a baked camera-facing matrix. The build is the GPU-acquisition half
-- of scene loading: pure descriptor normalization (material wrap resolution,
-- the material-keyed sampler-wrap map, per-mesh centers/AABBs, model bounds
-- folds) lives in SceneDescriptor, and the pool mesh entry caches each
-- geometry path's center and AABB once, so no vertex rescan happens per draw
-- or placement.
-- All GPU construction happens here, once, never in draw; the pool releases
-- every owned mesh/image. A build task owns a fresh pool transactionally, so
-- any failure -- a missing descriptor, an unsupported transform mode --
-- releases every GPU object the construction acquired before the error
-- propagates. After load, a single lazy acquire failure (resolveImage during
-- live draw evaluation) releases only the object that acquisition itself
-- created, never the resources the live scene is drawing.
-- The runtime also exposes the scene's MapProps facade so field coordinates
-- resolve to placed doors and their semantic animations. The only ROM
-- knowledge that reaches this layer is the normalized scene descriptor; raw
-- Nitro formats stopped at the compiler.
--
-- The static and animated building draws are two independent runtime lists
-- (`staticBuildingDraws`, `animatedBuildingDraws`): the static list is built
-- once at load and never rebuilt, since nothing about a static placement
-- changes after load. The animated list is owned by the scene tick: every
-- fixed tick advances each attachment player and rebuilds ONLY the animated
-- items, unconditionally -- there is no dirty-forwarding layer, no
-- between-tick refresh, and no copying of the static list into the rebuild
-- (control ops like the door choreography run inside session ticks, so the
-- same or next tick's updateAnimated renders them). The renderer never
-- re-evaluates poses itself. Loading builds the frame-0 animated list
-- immediately, without advancing any animation clock, so the scene is
-- renderable the moment load returns.

local MapAssetCache = require("libs.assets.src.MapAssetCache")
local Matrix3 = require("libs.math.src.Matrix3")
local Matrix4 = require("libs.math.src.Matrix4")
local FixedPoint = require("libs.math.src.FixedPoint")
local FieldLightProfile = require("libs.assets.src.field.FieldLightProfile")
local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local PoseContract = require("libs.assets.src.model.PoseContract")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local MapProps = require("libs.hgss.src.world.MapProps")
local ModelDoorMetadata = require("libs.hgss.src.world.ModelDoorMetadata")
local TimeOfDayProps = require("libs.hgss.src.presentation.TimeOfDayProps")
local CollisionGridAsset = require("libs.assets.src.field.CollisionGridAsset")
local CollisionGrid = require("libs.hgss.src.world.CollisionGrid")
local DoorTiles = require("libs.hgss.src.transition.DoorTiles")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")
local TerrainMaterialAnimator = require("libs.hgss.src.presentation.TerrainMaterialAnimator")
local BillboardTransform = require("libs.hgss.src.presentation.BillboardTransform")

local MapSceneLoader = {}

-- Private staged-work sentinel: a build coroutine yields WAIT while its
-- preparation-queue resource is still pending. WAIT consumes no work budget;
-- only a checkpoint yield of 1 charges one unit.
local WAIT = {}

---@class MapSceneLoader.ModelDescriptor
---@field kind "static"|"nitro-dynamic"
---@field batches MapSceneLoader.Batch[]?
---@field dynamic { nodes: ModelDefinition.NodeSource[], transformProgram: table<string, unknown>, batches: MapSceneLoader.Batch[] }?
---@field materials table[]
---@field animations table[]?

---@class MapSceneLoader.Batch
---@field geometry string
---@field material string|integer
---@field cullMode string?
---@field polygonMode string?
---@field polygonId integer?
---@field translucentDepthWrite boolean?
---@field depthEqual boolean?
---@field lightMask integer?
---@field polygonAlpha number
---@field alphaClass string
---@field fogEnabled boolean
---@field transformMode string?
---@field baseTransform table<string, unknown>?

---@class MapSceneLoader.DescriptorCacheEntry
---@field descriptor MapSceneLoader.ModelDescriptor
---@field materials table<string, unknown>
---@field wrapByMaterial table<number, { x: string, y: string }>
---@field bounds table<string, unknown>

---@class MapSceneLoader.BuildTask
---@field state "active"|"ready"|"transferred"|"released"|"failed"
---@field pool GpuAssetPool
---@field poolReleased boolean
---@field thread thread?
---@field result MapSceneLoader.Runtime?
---@field _queue table<string, unknown>?
---@field _outstanding integer?
---@field _stashed table<integer, table<string, unknown>>?
---@field advance fun(self: MapSceneLoader.BuildTask, maxWorkUnits: integer): integer
---@field isReady fun(self: MapSceneLoader.BuildTask): boolean
---@field takeResult fun(self: MapSceneLoader.BuildTask): MapSceneLoader.Runtime
---@field finish fun(self: MapSceneLoader.BuildTask): MapSceneLoader.Runtime
---@field release fun(self: MapSceneLoader.BuildTask)

---@class MapSceneLoader.Runtime
---@field scene table<string, unknown>
---@field assetPool GpuAssetPool
---@field mapId integer
---@field cameraType integer
---@field collision CollisionGrid
---@field bounds table<string, unknown>
---@field mapDraws table[]
---@field staticBuildingDraws table[]
---@field runtimePropDraws table[] runtime-owned static prop draw lane
---@field animatedBuildingDraws table[]
---@field lighting table<string, unknown>
---@field edgeColors table<string, unknown>
---@field fog table<string, unknown>
---@field fieldTimeSeconds number
---@field timeBand "day"|"night"
---@field animatedInstances ModelInstance[]
---@field updateAnimated fun(self: MapSceneLoader.Runtime)
---@field setTimeBand fun(self: MapSceneLoader.Runtime, band: "day"|"night")
---@field mapProps MapProps
---@field stats table<string, unknown>
---@field release fun(self: MapSceneLoader.Runtime)

-- The identity UV-transform matrix every assembled material starts with:
-- the renderer sends u_texMatrix for every draw, so a material can never
-- lack a matrix. The terrain animator replaces scene terrain materials'
-- matrices at construction (the static srt, or the area clip's frame-0
-- sample); model descriptor materials are never animator bindings and keep
-- the identity seed.
local IDENTITY_TEX_MATRIX = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
local IDENTITY_MODEL_NORMAL = Matrix3.identity()

local function isTranslationOnly(transform)
  return transform[1] == 1
    and transform[2] == 0
    and transform[3] == 0
    and transform[5] == 0
    and transform[6] == 1
    and transform[7] == 0
    and transform[9] == 0
    and transform[10] == 0
    and transform[11] == 1
end

local VALID_BANDS = {}
for _, band in ipairs(TimeOfDayProps.BANDS) do
  VALID_BANDS[band] = true
end

-- Material assembly: acquire each normalized material record's image
-- under its resolved sampler wrap. The wrap pair is part of the image
-- identity, so materials with the same pixels but different wraps resolve to
-- independent images.
local function materialsById(list, acquireImage, checkpoint)
  local byId = {}
  for id, record in pairs(SceneDescriptor.materials(list)) do
    local wrap = SceneDescriptor.wrap(record)
    byId[id] = {
      id = record.id,
      name = record.name,
      image = acquireImage(record.texture, wrap.x, wrap.y),
      texMatrix = IDENTITY_TEX_MATRIX,
      wrap = wrap,
    }
    checkpoint()
  end
  return byId
end

-- Build the runtime scene against an already-created pool. Raises on any
-- failure; the owning build task releases the pool in that case. `opts.timeBand` seeds the time-of-day band
-- (default: the band of the default field time, noon = day); `opts.meshBuilder`
-- / `opts.imageBuilder` pass through to the pool (the GPU seams, injectable
-- in headless tests). `opts.assetPreparation` routes mesh/image acquisition
-- through a preparation queue: CPU work runs on the worker while this build
-- blocks at the first unprepared resource, and GPU realization still happens
-- here on the main thread. `task` carries the outstanding prepared token
-- across staged resumes when a queue is present.
---@param pool GpuAssetPool
---@param cacheFs CacheFs
---@param scene table<string, unknown>
---@param opts table<string, unknown>
---@param checkpoint fun()
---@param task MapSceneLoader.BuildTask
---@return table<string, unknown>
local function buildScene(pool, cacheFs, scene, opts, checkpoint, task)
  local queue = opts.assetPreparation
  -- Task-local realized entries: a repeated path/wrap within one scene
  -- reuses its entry instead of repeating worker preparation. Checkpoint
  -- accounting stays per acquisition site, exactly like the synchronous
  -- path, so staged work budgets are unchanged.
  local meshEntries = {}
  local imageEntries = {}
  -- Block at the first unprepared resource: request it, then poll until it
  -- is ready, yielding WAIT (zero work) while pending. The task owns the
  -- outstanding token so finish() can block-wait it and release() can
  -- cancel it.
  local function awaitPrepared(kind, path)
    local token = queue:request(kind, path, "prefetch")
    task._outstanding = token
    while true do
      if task._stashed ~= nil and task._stashed[token] ~= nil then
        local stashed = task._stashed[token]
        task._stashed[token] = nil
        task._outstanding = nil
        return stashed
      end
      local status, failure = queue:poll(token)
      if status == "ready" then
        task._outstanding = nil
        return queue:take(token)
      end
      if status == "failed" then
        task._outstanding = nil
        error("prepared asset " .. path .. " (" .. kind .. ") failed: " .. tostring(failure), 0)
      end
      coroutine["yield"](WAIT)
    end
  end
  local function acquireMesh(path)
    local entry = meshEntries[path]
    if entry == nil then
      if queue then
        entry = pool:meshFromPrepared(path, awaitPrepared("mesh", path))
      else
        entry = pool:meshFor(path)
      end
      meshEntries[path] = entry
    end
    return entry
  end
  local function acquireImage(path, wrapX, wrapY)
    if path == nil then
      return nil
    end
    local key = wrapX .. "|" .. wrapY .. "|" .. path
    local image = imageEntries[key]
    if image == nil then
      if queue then
        image = pool:imageFromPrepared(path, wrapX, wrapY, awaitPrepared("image", path))
      else
        image = pool:imageFor(path, wrapX, wrapY)
      end
      imageEntries[key] = image
    end
    return image
  end
  local timeBand = opts.timeBand or TimeOfDayProps.bandForSeconds(FieldLightProfile.DEFAULT_TIME_SECONDS)
  assert(VALID_BANDS[timeBand], "unknown time-of-day band " .. tostring(timeBand))
  local bounds = { min = { math.huge, math.huge, math.huge }, max = { -math.huge, -math.huge, -math.huge } }
  local modelNormals = {}

  -- A transform table is immutable scene data. Cache its model normal once
  -- for every static draw that shares it; translation-only transforms all
  -- share the module identity normal.
  local function modelNormalFor(transform)
    if isTranslationOnly(transform) then
      return IDENTITY_MODEL_NORMAL
    end
    local normal = modelNormals[transform]
    if not normal then
      normal = Matrix3.modelNormal(transform)
      modelNormals[transform] = normal
    end
    return normal
  end

  -- Grow the scene bounds by a model-space AABB under a placement transform
  -- (the image of the box is its eight transformed corners). The per-mesh
  -- AABBs come from the pool mesh entry (cached per geometry path), so the
  -- scene bounds are folds over cached boxes, never vertex rescans.
  local function growBoundsAabb(aabb, transform)
    for i = 0, 1 do
      for j = 0, 1 do
        for k = 0, 1 do
          local x, y, z = Matrix4.transformPoint(
            transform,
            i == 1 and aabb.maxX or aabb.minX,
            j == 1 and aabb.maxY or aabb.minY,
            k == 1 and aabb.maxZ or aabb.minZ
          )
          if x < bounds.min[1] then
            bounds.min[1] = x
          end
          if y < bounds.min[2] then
            bounds.min[2] = y
          end
          if z < bounds.min[3] then
            bounds.min[3] = z
          end
          if x > bounds.max[1] then
            bounds.max[1] = x
          end
          if y > bounds.max[2] then
            bounds.max[2] = y
          end
          if z > bounds.max[3] then
            bounds.max[3] = z
          end
        end
      end
    end
  end

  -- Per-batch draw state that lives on the draw item, not the material
  -- record: the shared PolygonState schema the compiler emits on every batch
  -- (lightMask included), with polygonAlpha normalized to the renderer's
  -- 0..1 unit and the batch's compiled alpha class carried as-is.
  local function batchDrawState(batch)
    return {
      cullMode = batch.cullMode,
      polygonMode = batch.polygonMode,
      polygonId = batch.polygonId,
      translucentDepthWrite = batch.translucentDepthWrite,
      depthEqual = batch.depthEqual,
      lightMask = batch.lightMask,
      polygonAlpha = batch.polygonAlpha / FixedPoint.RGB5_MAX,
      alphaClass = batch.alphaClass,
      fogEnabled = batch.fogEnabled,
    }
  end

  -- One draw item for one batch under `instanceTransform` (identity for terrain,
  -- the placement matrix for a building). A billboard batch's geometry is in
  -- billboard-local space and its orientation depends on the camera, so the
  -- composed base supplies the shader's world center and scale; its static
  -- equivalent seeds `transform` and the scene bounds. Draw items carry no
  -- submission numbers: final queue traversal orders every part and draw in
  -- source order, positionally.
  local function drawItem(batch, materials, instanceTransform, includeInBounds)
    local meshResource = acquireMesh(batch.geometry)
    checkpoint()
    local billboardBase, billboardCenter, billboardScale
    if batch.transformMode == PoseContract.BILLBOARD then
      billboardBase =
        Matrix4.multiply(instanceTransform, assert(batch.baseTransform, "billboard batch is missing baseTransform"))
      billboardCenter, billboardScale = BillboardTransform.components(billboardBase)
    elseif batch.transformMode ~= nil then
      Errors.raise(
        FieldErrors.MAP_SCENE_UNSUPPORTED_TRANSFORM_MODE,
        "unknown batch transform mode " .. tostring(batch.transformMode),
        { transformMode = batch.transformMode, geometry = batch.geometry }
      )
    end
    local transform = billboardBase or instanceTransform
    if includeInBounds ~= false then
      growBoundsAabb(meshResource.bounds, transform)
    end
    local state = batchDrawState(batch)
    return {
      mesh = meshResource.mesh,
      material = materials[batch.material],
      transform = transform,
      modelNormal = billboardBase and IDENTITY_MODEL_NORMAL or modelNormalFor(transform),
      billboardBase = billboardBase,
      billboardCenter = billboardCenter,
      billboardScale = billboardScale,
      alphaClass = state.alphaClass,
      cullMode = state.cullMode,
      polygonAlpha = state.polygonAlpha,
      polygonMode = state.polygonMode,
      lightMask = state.lightMask,
      polygonId = state.polygonId,
      translucentDepthWrite = state.translucentDepthWrite,
      depthEqual = state.depthEqual,
      fogEnabled = state.fogEnabled,
      center = meshResource.center,
    }
  end

  -- Map terrain draws: identity transform, materials from the scene list.
  local mapMaterials = materialsById(scene.materials, acquireImage, checkpoint)
  local identity = Matrix4.identity()
  local mapDraws = {}
  for _, batch in ipairs(scene.mapBatches) do
    mapDraws[#mapDraws + 1] = drawItem(batch, mapMaterials, identity)
  end

  -- The terrain animation playback state of this scene: one animator over
  -- the scene-form material records and the runtime tables the draw items
  -- reference, constructed UNCONDITIONALLY -- a fully static scene gets an
  -- animator with no groups and no area player whose construction still
  -- initializes every material's static texMatrix -- under the build task,
  -- so every replacement step image is acquired (through the pool,
  -- deduplicated per path/wrap) before the transaction commits and a
  -- construction failure releases everything acquired so far through the
  -- task's rollback. The draw items keep pointing at the same runtime
  -- tables, so the animator's in-place image and texMatrix swaps update
  -- future draws without rebuilding mapDraws. Construction samples frame 0
  -- and never advances a clock.
  local bindings = {}
  for _, record in ipairs(scene.materials) do
    bindings[#bindings + 1] = {
      record = record,
      runtime = assert(
        mapMaterials[record.id],
        "no runtime material table for scene material id " .. tostring(record.id)
      ),
    }
    checkpoint()
  end
  local terrainAnimator = TerrainMaterialAnimator.new(
    bindings,
    scene.terrainAnimations.textureSrt,
    function(path, wrapX, wrapY)
      return acquireImage(path, wrapX, wrapY)
    end,
    checkpoint
  )

  -- Placed building instances: resolve each modelKey's descriptor (batches +
  -- its own materials) and instance it at the placement transform. The
  -- descriptor cache entry also carries the model-space AABB of the model's
  -- geometry: the scene bounds grow it under each placement transform, and
  -- the placement records carry it for the scene's MapProps facade (the
  -- door index resolves by placement pivot, not by footprint).
  local descriptorCache ---@type table<string, MapSceneLoader.DescriptorCacheEntry>
  descriptorCache = {}
  ---@param modelKey string
  ---@return MapSceneLoader.DescriptorCacheEntry
  local function descriptorFor(modelKey)
    local cached = descriptorCache[modelKey]
    if not cached then
      local desc = assert(cacheFs:loadLua(MapAssetCache.modelPath(modelKey)), "missing model " .. modelKey)
      ---@cast desc MapSceneLoader.ModelDescriptor
      checkpoint()
      local mats = materialsById(desc.materials, acquireImage, checkpoint)
      -- Pattern-variant textures are resolved lazily at evaluation time; the
      -- sampler state is keyed by material (never by texture path -- two
      -- materials can share one texture under different wraps), so the
      -- variant always samples with its own material's wrap.
      local wrapByMaterial = SceneDescriptor.wrapByMaterial(desc.materials)
      local batches
      if desc.kind == "static" then
        batches = desc.batches
      elseif desc.kind == "nitro-dynamic" then
        batches = desc.dynamic.batches
      else
        Errors.raise(
          FieldErrors.MAP_SCENE_UNKNOWN_MODEL_KIND,
          "model descriptor " .. modelKey .. " has unknown kind " .. tostring(desc.kind),
          { modelKey = modelKey, kind = desc.kind }
        )
      end
      -- The model-space AABB is a pure fold over the per-mesh entry bounds
      -- (cached on the pool entry per geometry path), one table per model
      -- shared by every placement record.
      local meshBounds = {}
      for _, batch in ipairs(assert(batches)) do
        meshBounds[#meshBounds + 1] = acquireMesh(batch.geometry).bounds
        checkpoint()
      end
      cached = {
        descriptor = desc,
        materials = mats,
        wrapByMaterial = wrapByMaterial,
        bounds = SceneDescriptor.bounds(meshBounds),
      }
      descriptorCache[modelKey] = cached
      checkpoint()
    end
    return cached
  end

  local staticBuildingDraws = {}
  for _, inst in ipairs(scene.buildingInstances) do
    local desc = descriptorFor(inst.modelKey)
    -- Dynamic (animated) descriptors carry their geometry in the `dynamic`
    -- half; the static batches loop applies to baked descriptors only. The
    -- kind dispatch is explicit: a descriptor of an unknown kind is a
    -- generated-data failure, not a silent empty model.
    if desc.descriptor.kind == "static" then
      for _, batch in ipairs(desc.descriptor.batches) do
        staticBuildingDraws[#staticBuildingDraws + 1] = drawItem(batch, desc.materials, inst.transform)
      end
    elseif desc.descriptor.kind ~= "nitro-dynamic" then
      Errors.raise(
        FieldErrors.MAP_SCENE_UNKNOWN_MODEL_KIND,
        "model descriptor " .. inst.modelKey .. " has unknown kind " .. tostring(desc.descriptor.kind),
        { modelKey = inst.modelKey, kind = desc.descriptor.kind }
      )
    end
  end

  -- ---- animated building instances ----

  -- An animated model descriptor (kind "nitro-dynamic") becomes a ModelInstance
  -- per placement: the definition is assembled from the serialized descriptor
  -- and the referenced .g4mesh batches become render meshes ONCE per model
  -- key, then every placement of that model shares them (model resource
  -- sharing). Each instance owns its animation state, material state, and
  -- pose -- two placements of one model can animate at different frames --
  -- while the definition and clips are immutable and shared.
  --
  -- Ambient playback at load: the compiled playback policy decides -- a
  -- time-of-day banded model plays the current band's clip looping and swaps
  -- on runtime:setTimeBand (HGSS ov01_022047DC); every clip of an
  -- ordinary-policy anim-list record carries the compiled ambientLoop role
  -- and plays looping (the field effects -- wind, machine, spring); other
  -- policy records (door pairs, interaction props) stay scripted through
  -- the instance handles (MapDoor/SceneProp).
  local animatedInstances = {}
  local instanceByPlacement = {}
  local animatedModelCount = 0
  local animatedResourceCache = {}
  local liveImageResolvers = {}
  for _, inst in ipairs(scene.buildingInstances) do
    local desc = descriptorFor(inst.modelKey)
    if desc.descriptor.kind == "nitro-dynamic" then
      local modelResource = animatedResourceCache[inst.modelKey]
      if not modelResource then
        local descriptor = desc.descriptor --[[@as ModelDefinition.Descriptor]]
        local definition = ModelDefinition.fromNitroDescriptor(descriptor, { key = inst.modelKey })
        checkpoint()
        local renderMeshesById = {}
        for _, mesh in ipairs(definition.meshes) do
          local meshResource = acquireMesh(mesh.geometry)
          renderMeshesById[mesh.id] = meshResource.mesh
          mesh.center = meshResource.center
          checkpoint()
        end
        modelResource = { definition = definition, renderMeshesById = renderMeshesById }
        animatedResourceCache[inst.modelKey] = modelResource
        animatedModelCount = animatedModelCount + 1
      end
      local function resolveImage(key, materialId)
        local wrap = assert(desc.wrapByMaterial[materialId], "missing wrap for animated texture " .. key)
        return acquireImage(key, wrap.x, wrap.y)
      end
      local function resolveImageDuringConstruction(key, materialId)
        local image = resolveImage(key, materialId)
        checkpoint()
        return image
      end
      local instance = ModelInstance.new(modelResource.definition, {
        transform = inst.transform,
        resolveImage = resolveImageDuringConstruction,
      })
      liveImageResolvers[#liveImageResolvers + 1] = { instance = instance, resolveImage = resolveImage }
      checkpoint()
      instance.renderMeshesById = modelResource.renderMeshesById
      growBoundsAabb(desc.bounds, inst.transform)
      animatedInstances[#animatedInstances + 1] = instance
      instanceByPlacement[inst.placementIndex] = instance
      local timeBandClips = TimeOfDayProps.plan(modelResource.definition)
      instance.timeOfDayPlan = timeBandClips
      if timeBandClips then
        local clip = timeBandClips[timeBand]
        if clip then
          instance:play(clip.name, { loopMode = "loop" })
        end
      else
        for _, clip in ipairs(modelResource.definition.animations) do
          if clip.ambientLoop then
            instance:play(clip.name, { loopMode = "loop" })
          end
        end
      end
      checkpoint()
    end
  end

  local runtime = {}

  runtime.animatedBuildingDraws = {}
  -- Per-refresh scratch holding each instance's evaluated draw list until
  -- publication. Reused across ticks; cleared after every refresh.
  local pendingDraws = {}

  -- The per-instance refresh pass shared by the tick update and the initial
  -- build: it re-evaluates each pose from the current attachment frames. The
  -- static building list is built once and never touched again -- only the
  -- animated list is refreshed here, so a fixed tick's cost scales with the
  -- animated instance count, not the whole building set.
  --
  -- The aggregation reuses one outer array: ticks overwrite its entries
  -- with the instances' current live draw records and truncate the surplus,
  -- so the list keeps its identity. Evaluation runs to completion before
  -- publication, so a resolver failure raises without publishing a
  -- partially-updated list: the scene keeps its last good aggregation.
  local function refreshAnimatedItems(constructionCheckpoint)
    for index, instance in ipairs(animatedInstances) do
      instance:evaluatePose()
      pendingDraws[index] = instance:drawItems(instance.renderMeshesById)
      if constructionCheckpoint ~= nil then
        constructionCheckpoint()
      end
    end
    for index = #animatedInstances + 1, #pendingDraws do
      pendingDraws[index] = nil
    end
    local items = runtime.animatedBuildingDraws
    local count = 0
    for _, drawn in ipairs(pendingDraws) do
      for _, item in ipairs(drawn) do
        count = count + 1
        items[count] = item
      end
    end
    for i = count + 1, #items do
      items[i] = nil
    end
    for index = 1, #pendingDraws do
      pendingDraws[index] = nil
    end
  end

  -- Advance every animated instance by one fixed step, then refresh: the one
  -- authoritative animation-clock entry point of the scene. The terrain
  -- animator takes its one tick first (texture-swap step images and the
  -- area SRT sample), mutating the shared runtime material tables in place;
  -- the refresh is unconditional -- every tick rebuilds all animated items,
  -- so control ops never need to mark anything dirty. Terrain draws are
  -- never rebuilt: they reference the same material tables, so the swapped
  -- image and matrix show up on the next render.
  local function updateAnimated()
    terrainAnimator:updateFixed()
    for _, instance in ipairs(animatedInstances) do
      instance:updateFixed()
    end
    refreshAnimatedItems()
  end

  -- Switch the time-of-day band of every banded prop (HGSS ov01_022047DC):
  -- stop the previous band's clip, play the current band's clip looping.
  -- Re-setting the current band is a no-op. Unbanded instances are untouched.
  -- The swap does not mark the draw list dirty: the next scene tick rebuilds
  -- it unconditionally.
  ---@param band "day"|"night"
  local function setTimeBand(_, band)
    assert(VALID_BANDS[band], "unknown time-of-day band " .. tostring(band))
    if runtime.timeBand == band then
      return
    end
    local previous = runtime.timeBand
    runtime.timeBand = band
    for _, instance in ipairs(animatedInstances) do
      if instance.timeOfDayPlan then
        TimeOfDayProps.swap(instance, instance.timeOfDayPlan, previous, band)
      end
    end
  end

  -- Collision from the G4CL asset (CollisionGridAsset bytes), around the
  -- cell origin. Decoded through the same pure project-owned asset path the
  -- simulation-only loaders use, so the visual scene carries the grid the
  -- door-ownership pass resolves against.
  local collisionBytes = assert(cacheFs:read(scene.collision.file), "missing collision asset")
  local grid, decodeErr =
    CollisionGridAsset.decode(collisionBytes, { mapId = scene.mapId, path = scene.collision.file })
  assert(grid, decodeErr and decodeErr.message or "malformed collision asset")
  checkpoint()
  local collision = CollisionGrid.new(grid, {
    worldOriginX = scene.matrix.worldOriginX,
    worldOriginZ = scene.matrix.worldOriginZ,
  })

  -- The door tiles of this scene: every DOOR-kind (behavior 105) tile of
  -- the permission cell, as local indices. Door ownership is precomputed
  -- over exactly this list when the scene's MapProps is constructed --
  -- ambiguity and missing coverage are diagnosed once at load, never per
  -- lookup.
  local doorTiles = DoorTiles.fromGrid(collision)
  checkpoint()

  bounds.center = {
    (bounds.min[1] + bounds.max[1]) / 2,
    (bounds.min[2] + bounds.max[2]) / 2,
    (bounds.min[3] + bounds.max[3]) / 2,
  }

  runtime.scene = scene
  runtime.assetPool = pool
  runtime.mapId = scene.mapId
  runtime.cameraType = scene.cameraType
  runtime.collision = collision
  runtime.bounds = bounds
  runtime.mapDraws = mapDraws
  runtime.staticBuildingDraws = staticBuildingDraws
  runtime.runtimePropDraws = {}
  local runtimePropDrawsByOwner = {}
  runtime.runtimePropDrawsByOwner = runtimePropDrawsByOwner

  local function refreshRuntimePropDraws()
    local draws = {}
    for _, ownerDraws in pairs(runtimePropDrawsByOwner) do
      for _, draw in ipairs(ownerDraws) do
        draws[#draws + 1] = draw
      end
    end
    runtime.runtimePropDraws = draws
  end

  -- Runtime-owned static props replace one semantic owner lane atomically:
  -- all new GPU-backed draw records are assembled before the old lane is
  -- published. The descriptor and model resources remain owned by the scene
  -- pool, while the immutable authored building list is never rebuilt.
  function runtime:replaceRuntimeStaticProps(ownerKey, placements)
    assert(type(ownerKey) == "string" and #ownerKey > 0, "runtime prop owner key is required")
    assert(type(placements) == "table", "runtime prop placements are required")
    local runtimeProps = assert(self.scene.runtimeProps, "scene has no runtime props for owner " .. ownerKey)
    local group = assert(runtimeProps[ownerKey], "scene has no runtime props for owner " .. ownerKey)
    local desc = descriptorFor(group.model)
    if desc.descriptor.kind ~= "static" then
      Errors.raise(
        FieldErrors.MAP_SCENE_UNKNOWN_MODEL_KIND,
        "runtime prop model must be static for owner " .. ownerKey .. ": " .. group.model,
        { ownerKey = ownerKey, modelKey = group.model, kind = desc.descriptor.kind }
      )
    end
    local nextDraws = {}
    for _, placement in ipairs(placements) do
      assert(type(placement) == "table" and type(placement.transform) == "table")
      for _, batch in ipairs(desc.descriptor.batches) do
        nextDraws[#nextDraws + 1] = drawItem(batch, desc.materials, placement.transform, false)
      end
    end
    runtimePropDrawsByOwner[ownerKey] = nextDraws
    refreshRuntimePropDraws()
  end
  -- Build the frame-0 animated items inside the load build: the scene
  -- is renderable immediately after load, and the animation clocks never
  -- advanced (the first tick's updateAnimated starts them).
  refreshAnimatedItems(checkpoint)
  runtime.lighting = scene.lighting
  -- The compiled area's real HGSS edge-color table, forwarded as
  -- opaque scene state -- the concrete GX renderer decodes and sends it, with no ROM
  -- knowledge of its own.
  runtime.edgeColors = scene.edgeColors
  -- The compiled area's resolved global HGSS weather fog preset, forwarded
  -- as opaque scene state -- MapSceneLoader has no ROM/weather knowledge of
  -- its own. Every compiled scene carries this unconditionally.
  runtime.fog = assert(scene.fog, "scene runtime requires a fog preset")
  runtime.fieldTimeSeconds = FieldLightProfile.DEFAULT_TIME_SECONDS
  runtime.timeBand = timeBand
  runtime.animatedInstances = animatedInstances
  runtime.updateAnimated = updateAnimated
  runtime.setTimeBand = setTimeBand
  -- The door lookup: a MapProps facade over this scene's placements and
  -- instances resolves a field coordinate to the door of the building placed
  -- there -- nothing Nitro leaks into gameplay. `opts.mapProps` is the
  -- semantic resolver FieldMapLoader already built from generated data
  -- (headless-safe, same door census this presentation load would compute);
  -- this attaches the freshly-created live instances into it rather than
  -- building a second census. A caller that loads a scene standalone (tests
  -- exercising MapSceneLoader in isolation, without FieldMapLoader) gets the
  -- old self-contained construction.
  if opts.mapProps then
    opts.mapProps:attachInstances(instanceByPlacement)
    runtime.mapProps = opts.mapProps
  else
    local placements = {}
    for _, inst in ipairs(scene.buildingInstances) do
      local desc = descriptorFor(inst.modelKey)
      local doorMeta = ModelDoorMetadata.forDescriptor(desc.descriptor)
      placements[#placements + 1] = {
        placementIndex = inst.placementIndex,
        modelKey = inst.modelKey,
        transform = inst.transform,
        bounds = desc.bounds,
        doorSoundType = doorMeta and doorMeta.doorSoundType or nil,
        doorRoles = doorMeta and doorMeta.roles or nil,
      }
      checkpoint()
    end
    runtime.mapProps = MapProps.new({
      placements = placements,
      instances = instanceByPlacement,
      doorTiles = doorTiles,
    })
  end
  runtime.stats = {
    meshCount = #pool.meshes,
    textureCount = #pool.images,
    triangleCount = pool.triangles,
    buildingInstances = #scene.buildingInstances,
    animatedInstances = #animatedInstances,
    animatedModelCount = animatedModelCount,
    runtimePropDraws = #runtime.runtimePropDraws,
  }

  function runtime:release()
    pool:release()
  end

  for _, resolver in ipairs(liveImageResolvers) do
    resolver.instance.resolveImage = resolver.resolveImage
  end

  return runtime
end

local BuildTask = {}
BuildTask.__index = BuildTask

---@param task MapSceneLoader.BuildTask
---@param err unknown
local function failTask(task, err)
  if task.state == "active" then
    task.state = "failed"
    local token = task._outstanding
    task._outstanding = nil
    if token ~= nil and task._queue ~= nil then
      -- Cancellation must not mask the original failure (the queue may
      -- already be gone when unwinding through layered releases).
      pcall(task._queue.cancel, task._queue, token)
    end
    if not task.poolReleased then
      task.poolReleased = true
      task.pool:release()
    end
  end
  error(err, 0)
end

---@param maxWorkUnits integer
---@return integer
---@param self MapSceneLoader.BuildTask
function BuildTask:advance(maxWorkUnits)
  assert(self.state == "active" or self.state == "ready", "build task is no longer active")
  assert(type(maxWorkUnits) == "number" and maxWorkUnits >= 0 and maxWorkUnits % 1 == 0)
  if self.state == "ready" or maxWorkUnits == 0 then
    return 0
  end

  local consumed = 0
  while consumed < maxWorkUnits and self.state == "active" do
    local ok, yielded = coroutine.resume(self.thread)
    if not ok then
      failTask(self, yielded)
    end
    if coroutine.status(self.thread) == "dead" then
      self.result = assert(yielded, "scene build returned no runtime")
      self.state = "ready"
    else
      -- BuildTask semantics: 1 means one main-thread work unit; WAIT means worker pending.
      if yielded == WAIT then
        break
      end
      assert(yielded == 1, "scene build yielded an invalid work unit")
      consumed = consumed + 1
    end
  end
  return consumed
end

---@param self MapSceneLoader.BuildTask
---@return boolean
function BuildTask:isReady()
  return self.state == "ready"
end

---@return MapSceneLoader.Runtime
---@param self MapSceneLoader.BuildTask
function BuildTask:takeResult()
  assert(self.state == "ready", "build task result is not ready")
  local result = assert(self.result)
  self.result = nil
  self.state = "transferred"
  return result
end

---@return MapSceneLoader.Runtime
---@param self MapSceneLoader.BuildTask
function BuildTask:finish()
  while self.state == "active" do
    -- A coroutine suspended on worker preparation block-waits its
    -- outstanding token instead of polling in a tight loop; the waited
    -- payload is stashed for the resumed build to consume.
    local outstanding = self._outstanding
    if outstanding ~= nil and self._queue ~= nil then
      local ok, payload = pcall(self._queue.wait, self._queue, outstanding)
      if not ok then
        self._outstanding = nil
        failTask(self, payload)
      end
      self._stashed = self._stashed or {}
      self._stashed[outstanding] = payload
      self._outstanding = nil
    end
    self:advance(1)
  end
  return self:takeResult()
end

---@param self MapSceneLoader.BuildTask
function BuildTask:release()
  if self.state == "transferred" or self.state == "released" or self.state == "failed" then
    return
  end
  self.state = "released"
  self.result = nil
  local token = self._outstanding
  self._outstanding = nil
  if token ~= nil and self._queue ~= nil then
    -- Release stays infallible even if the queue is already gone.
    pcall(self._queue.cancel, self._queue, token)
  end
  if not self.poolReleased then
    self.poolReleased = true
    self.pool:release()
  end
end

local function validateScene(scene)
  if not scene or scene.schema ~= MapAssetCache.SCENE_SCHEMA then
    Errors.raise(
      FieldErrors.MAP_SCENE_UNSUPPORTED_SCHEMA,
      "expected " .. MapAssetCache.SCENE_SCHEMA .. ", got " .. tostring(scene and scene.schema or nil),
      { schema = scene and scene.schema or nil }
    )
  end
end

-- Begin one resumable scene build. The task owns the fresh pool until the
-- completed runtime is transferred or the task is cancelled/failed.
-- `opts.assetPreparation` routes mesh/image acquisition through a
-- preparation queue (worker preparation, bounded main-thread realization);
-- without it the build keeps the direct synchronous path.
---@param cacheFs CacheFs
---@param scene table<string, unknown>
---@param opts { graphics?: GpuAssetPool.Graphics, timeBand?: string, meshBuilder?: GpuAssetPool.MeshBuilder, imageBuilder?: GpuAssetPool.ImageBuilder, assetPreparation?: table<string, unknown> }?
---@return MapSceneLoader.BuildTask
function MapSceneLoader.begin(cacheFs, scene, opts)
  opts = opts or {}
  validateScene(scene)
  local pool = GpuAssetPool.new(cacheFs, opts)
  local function checkpoint()
    coroutine["yield"](1)
  end
  ---@type MapSceneLoader.BuildTask
  local task = {
    state = "active",
    pool = pool,
    poolReleased = false,
    _queue = opts.assetPreparation,
    _outstanding = nil,
    _stashed = nil,
    advance = BuildTask.advance,
    isReady = BuildTask.isReady,
    takeResult = BuildTask.takeResult,
    finish = BuildTask.finish,
    release = BuildTask.release,
  }
  setmetatable(task, BuildTask)
  task.thread = coroutine.create(function()
    return buildScene(pool, cacheFs, scene, opts, checkpoint, task)
  end)
  return task
end

-- Load an assembled scene synchronously by finishing the same task used by
-- background physical presentation prefetch.
---@param cacheFs CacheFs
---@param scene table<string, unknown>
---@param opts { graphics?: GpuAssetPool.Graphics, timeBand?: string, meshBuilder?: GpuAssetPool.MeshBuilder, imageBuilder?: GpuAssetPool.ImageBuilder }?
---@return table<string, unknown>
function MapSceneLoader.load(cacheFs, scene, opts)
  return MapSceneLoader.begin(cacheFs, scene, opts):finish()
end

-- Build the logical render environment without acquiring geometry or model
-- resources. Outdoor physical cells own all rendered geometry; the renderer
-- still needs the logical scene's lighting, edge colors, and fog state.
---@param scene table<string, unknown>
---@return table<string, unknown>
function MapSceneLoader.loadEnvironment(scene)
  assert(type(scene) == "table" and scene.schema == MapAssetCache.SCENE_SCHEMA, "field scene required")
  local function release() end
  return {
    scene = scene,
    lighting = scene.lighting,
    edgeColors = scene.edgeColors,
    fog = scene.fog,
    release = release,
  }
end

-- Build a presentation runtime for one generated physical cell. The cell uses
-- the same normalized scene and model descriptors as a full map scene, while
-- the physical-world owner supplies its translated render origin.
function MapSceneLoader.loadCell(cacheFs, cell, opts)
  return MapSceneLoader.beginCell(cacheFs, cell, opts):finish()
end

-- Build the synthetic scene used by one physical cell and expose it through
-- the same staged scene task as a full logical scene.
---@param cacheFs CacheFs
---@param cell table<string, unknown>
---@param opts table<string, unknown>?
---@return MapSceneLoader.BuildTask
function MapSceneLoader.beginCell(cacheFs, cell, opts)
  assert(type(cell) == "table", "field cell descriptor required")
  local scene = {
    schema = MapAssetCache.SCENE_SCHEMA,
    kind = "field-cell",
    mapId = cell.mapHeaderId,
    cameraType = 0,
    matrix = { worldOriginX = 0, worldOriginZ = 0 },
    mapBatches = cell.batches,
    materials = cell.materials,
    buildingInstances = cell.buildingInstances,
    terrainAnimations = cell.terrainAnimations,
    neighbors = {},
    collision = cell.collision,
    lighting = {},
    edgeColors = {},
    fog = {},
  }
  return MapSceneLoader.begin(cacheFs, scene, opts)
end

return MapSceneLoader
