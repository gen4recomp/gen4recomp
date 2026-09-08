-- The one shared GPU-asset owner for scene loading: MapSceneLoader and
-- NeighborRing both need "read content-addressed cache bytes, decode/build a
-- persistent love Mesh, and build a persistent love Image per unique sampler
-- state", so this pool is that shared responsibility. It dedups meshes by
-- content-addressed path and images by path plus wrap X/Y (two materials
-- sharing pixels but sampling them differently never alias one mutable
-- sampler), and owns every object it creates. The mesh entry caches the
-- model-space bounding-box center and AABB of each unique geometry path,
-- computed once (pure SceneDescriptor math) so no loader rescan of the
-- decoded vertices happens per draw or placement. Failure has two scopes: a
-- construction wrapped in build() releases everything the construction
-- created (the loaders wrap their whole scene build in one, on a pool
-- created immediately before), while a single lazy acquire outside a build
-- releases only the object that failed acquisition itself created -- a
-- failed variant load during live draw evaluation never frees the resources
-- the scene is drawing. The filter is currently uniform (nearest), so it
-- stays out of the image key; if it ever varies, it belongs in the key too.
-- The pool knows nothing about maps, neighbors, materials, or transforms;
-- those stay in the loaders.

local SceneMesh = require("libs.hgss.src.presentation.SceneMesh")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")
local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")

---@class GpuAssetPool.Mesh
---@field release fun(self: GpuAssetPool.Mesh)
---@class GpuAssetPool.Image
---@field setFilter fun(self: GpuAssetPool.Image, min: string, mag: string)
---@field setWrap fun(self: GpuAssetPool.Image, wrapX: string, wrapY: string)
---@field release fun(self: GpuAssetPool.Image)
---@field getWidth fun(self: GpuAssetPool.Image): integer
---@field getHeight fun(self: GpuAssetPool.Image): integer
---@class GpuAssetPool.Graphics
---@field newImage fun(data: unknown): GpuAssetPool.Image
---@alias GpuAssetPool.MeshBuilder fun(decoded: table<string, unknown>): GpuAssetPool.Mesh
---@alias GpuAssetPool.ImageBuilder fun(path: string): GpuAssetPool.Image
---@class GpuAssetPool
---@field cacheFs table<string, unknown>
---@field graphics GpuAssetPool.Graphics|love.Graphics|love.graphics
---@field meshBuilder GpuAssetPool.MeshBuilder
---@field imageBuilder GpuAssetPool.ImageBuilder?
---@field meshes GpuAssetPool.Mesh[]
---@field images GpuAssetPool.Image[]
---@field triangles integer
local GpuAssetPool = {}
GpuAssetPool.__index = GpuAssetPool

-- LÖVE's real WrapMode vocabulary this pool configures Image:setWrap with;
-- SceneDescriptor.MIRRORED_REPEAT is SceneDescriptor.wrap's resolved DS
-- mirrored-repeat mode (a repeated axis whose NSBTX material sets the flip
-- bit).
local WRAP_MODES = { clamp = true, ["repeat"] = true, [SceneDescriptor.MIRRORED_REPEAT] = true }

-- Release the last object of an owned list -- the failed acquisition's own --
-- after `revert` undid its dedup-cache bookkeeping. The pop happens only when
-- a guarded body recorded an object before failing.
local function releaseLast(owned, revert)
  local object = owned[#owned]
  owned[#owned] = nil
  if revert then
    revert()
  end
  object:release()
end

-- Run an acquire under protection: any failure releases only the object the
-- failed acquisition itself created -- never objects from earlier acquisitions
-- or a live scene. The guarded body records at most one object (its owned-list
-- and dedup-cache entries) before any step that can fail; `revert` removes
-- that object's dedup-cache entry, and the owned-list pop plus the release
-- happen here. A body that fails before recording anything owns nothing.
local function guarded(pool, fn, revert)
  local imagesBefore = #pool.images
  local meshesBefore = #pool.meshes
  local ok, err = pcall(fn)
  if not ok then
    if #pool.images > imagesBefore then
      assert(#pool.meshes == meshesBefore, "a guarded acquire created a mesh and an image")
      releaseLast(pool.images, revert)
    elseif #pool.meshes > meshesBefore then
      releaseLast(pool.meshes, revert)
    end
    error(err)
  end
end

---@class GpuAssetPoolOptions
---@field graphics? unknown -- injectable graphics namespace (nil keeps love.graphics)
---@field meshBuilder? GpuAssetPool.MeshBuilder -- replaces SceneMesh.build (headless tests)
---@field imageBuilder? GpuAssetPool.ImageBuilder -- replaces graphics texture construction (headless tests)

-- cacheFs: a CacheFs-shaped reader (read(path) returns raw bytes or nil); see
-- GpuAssetPoolOptions for the injectable GPU seams. A builder image is
-- configured (filter/wrap) and owned exactly like a love-built one.
---@param cacheFs table<string, unknown>
---@param opts GpuAssetPoolOptions?
---@return GpuAssetPool
function GpuAssetPool.new(cacheFs, opts)
  assert(cacheFs and cacheFs.read, "GpuAssetPool requires a CacheFs-shaped object")
  opts = opts or {}
  ---@type GpuAssetPool.Graphics|love.Graphics|love.graphics|nil
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.newImage, "GpuAssetPool requires love.graphics")
  ---@cast graphics GpuAssetPool.Graphics|love.Graphics|love.graphics
  return setmetatable({
    cacheFs = cacheFs,
    graphics = graphics,
    meshBuilder = opts.meshBuilder or SceneMesh.build,
    imageBuilder = opts.imageBuilder,
    meshes = {},
    images = {},
    triangles = 0,
    _meshCache = {},
    _imageCache = {},
  }, GpuAssetPool)
end

-- Acquire (or fetch) the shared Mesh for a content-addressed geometry path.
-- Returns { mesh, triangles, center, bounds }: the model-space bounding-box
-- center and AABB are computed once per path (pure SceneDescriptor math over
-- the decoded vertices, which are otherwise discarded) and shared by every
-- consumer -- draw sort centers, descriptor bounds folds -- so no loader
-- rescan happens per draw/placement. The triangle count feeds loader stats
-- exactly once per mesh. All four fields are stable references across
-- repeated acquires of the same path.
---@param path string
---@return { mesh: GpuAssetPool.Mesh, triangles: integer, center: number[], bounds: { minX: number, maxX: number, minY: number, maxY: number, minZ: number, maxZ: number } }
function GpuAssetPool:meshFor(path)
  local entry = self._meshCache[path]
  if not entry then
    guarded(self, function()
      local decoded = SceneMesh.decode(assert(self.cacheFs:read(path), "missing mesh " .. path), path)
      local mesh = self.meshBuilder(decoded)
      -- Record ownership before the failure-capable geometry step: a later
      -- failure (e.g. an empty mesh) pops and releases exactly this mesh
      -- instead of orphaning it.
      self.meshes[#self.meshes + 1] = mesh
      local geometry = SceneDescriptor.meshGeometry(decoded.vertices)
      local triangleCount = decoded.indexCount / 3
      ---@cast triangleCount integer
      entry = { mesh = mesh, triangles = triangleCount, center = geometry.center, bounds = geometry.bounds }
      self._meshCache[path] = entry
      self.triangles = self.triangles + entry.triangles
    end)
  end
  return entry
end

-- Acquire (or fetch) the shared Image for a texture path under one immutable
-- sampler state (wrap X/Y). The image identity is the path plus the wrap
-- pair, so each distinct wrap pair owns its own configured Image. Unknown
-- wrap modes on a sampled material are malformed data and raise instead of
-- degrading to clamp; a nil path (untextured material, no sampler state)
-- yields no image. A failure here releases only the image this acquisition
-- itself created -- the pool's other objects stay owned. The image is
-- recorded before it is configured, so a configuration failure pops exactly
-- its own cache entry and owned-list slot.
---@param path string?
---@param wrapX string
---@param wrapY string
---@return GpuAssetPool.Image?
function GpuAssetPool:imageFor(path, wrapX, wrapY)
  if not path then
    return nil
  end
  local byWrap = self._imageCache[path]
  if not byWrap then
    byWrap = {}
    self._imageCache[path] = byWrap
  end
  local key = wrapX .. "|" .. wrapY
  local image = byWrap[key]
  if not image then
    guarded(self, function()
      if not WRAP_MODES[wrapX] or not WRAP_MODES[wrapY] then
        Errors.raise(
          FieldErrors.GPU_ASSET_UNKNOWN_WRAP,
          "unknown texture wrap mode " .. tostring(wrapX) .. "/" .. tostring(wrapY),
          { path = path, wrapX = wrapX, wrapY = wrapY }
        )
      end
      local created
      if self.imageBuilder then
        created = self.imageBuilder(path)
        assert(created, "imageBuilder returned no image for " .. path)
      else
        local bytes = assert(self.cacheFs:read(path), "missing texture " .. path)
        local data = love.filesystem.newFileData(bytes, "tex.png")
        created = self.graphics.newImage(data)
      end
      ---@cast created GpuAssetPool.Image
      byWrap[key] = created
      self.images[#self.images + 1] = created
      created:setFilter("nearest", "nearest")
      created:setWrap(wrapX, wrapY)
      image = created
    end, function()
      byWrap[key] = nil
    end)
  end
  return image
end

-- Release every owned GPU object exactly once. Idempotent: the owned lists,
-- the dedup caches, and the triangle count are cleared, so a repeat release
-- (or a cleanup after a failed acquire) never touches the same object twice.
function GpuAssetPool:release()
  for _, mesh in ipairs(self.meshes) do
    mesh:release()
  end
  for _, image in ipairs(self.images) do
    image:release()
  end
  self.meshes, self.images = {}, {}
  self._meshCache, self._imageCache = {}, {}
  self.triangles = 0
end

-- Run the scene construction against this (freshly created) pool: the
-- loaders create the pool and immediately wrap their whole build in build().
-- On failure everything the construction acquired is released (dedup caches
-- included) and the failure re-raises; on success everything stays owned and
-- fn's value is returned. The wrapper is exactly "construct a fresh scene
-- pool, release on failed construction" -- nothing more: it is not a generic
-- transaction API, and callers must not reuse a pool that already owns
-- objects (a failed inner construction would release them).
---@param fn fun(): unknown?
---@return unknown
function GpuAssetPool:build(fn)
  assert(type(fn) == "function", "GpuAssetPool:build requires a function")
  local ok, result = pcall(fn)
  if not ok then
    self:release()
    error(result)
  end
  return result
end

return GpuAssetPool
