-- Tests for the shared GPU asset pool used by MapSceneLoader and NeighborRing:
-- content-addressed mesh/image dedup, sampler-aware image identity (the wrap
-- pair is part of the key, so two materials sharing pixels but sampling them
-- differently never alias one mutable sampler), unknown wrap rejection, and
-- exactly-once ownership release. Failure handling has two scopes, mirroring
-- the two production failure classes: a build wrapper rolls back every
-- object created inside a failed construction (the whole scene build), while
-- a single post-construction acquire failure rolls back only the object that
-- acquisition itself created -- the live scene keeps the resources it is
-- drawing. The image side runs headless through an injected fake graphics
-- namespace; mesh construction needs a real graphics context, so this is a
-- graphics suite.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local PngWriter = require("libs.assets.src.PngWriter")
local BinaryWriter = require("libs.codec.src.BinaryWriter")
local ErrorCodes = require("libs.assets.src.ErrorCodes")
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local SceneMesh = require("libs.hgss.src.presentation.SceneMesh")

local T = {}

local GEOM_PATH = MapAssetCache.geometryPath("aaaa")
local EMPTY_GEOM_PATH = MapAssetCache.geometryPath("empty")
local TEX_PATH = MapAssetCache.texturePath("bbbb")

-- One-triangle batch in the MeshWriter vertex layout.
local function triangleBatch()
  local function v(x, z)
    return {
      x = x,
      y = 0,
      z = z,
      u = 0,
      v = 0,
      nx = 0,
      ny = 1,
      nz = 0,
      r = 255,
      g = 255,
      b = 255,
      a = 255,
      colorSource = 0,
    }
  end
  return { vertices = { v(0, 0), v(2, 0), v(0, 2) }, indices = { 0, 1, 2 } }
end

-- A syntactically valid G4M2 batch with zero vertices: MeshWriter refuses
-- to encode an empty batch, so this is the hand-crafted malformed-data shape
-- that must fail loudly at the geometry step, not decode or fold into a
-- NaN box.
local function emptyMeshBytes()
  return BinaryWriter.new():bytes("G4M2"):u16(2):u16(0):u32(0):u32(0):u16(40):u16(2):u32(0):tostring()
end

-- A CacheFs whose :read(path) serves canned bytes for the known paths,
-- mirroring CacheFs:read's string-or-nil contract.
local function fakeCacheFs()
  local blob = {
    [GEOM_PATH] = MeshWriter.encode(triangleBatch()),
    [EMPTY_GEOM_PATH] = emptyMeshBytes(),
    [TEX_PATH] = PngWriter.encode(1, 1, string.char(255, 0, 0, 255)),
  }
  return {
    read = function(_, path)
      return blob[path]
    end,
  }
end

-- Injected graphics namespace: tracks created images, the wrap pair each image
-- was configured with, and release calls. failOnNewImage makes the Nth
-- newImage call raise; failSetWrapOn makes the Nth created image's setWrap
-- raise after creation -- together they exercise failed-acquire cleanup both
-- before and after the failed acquisition created its own object, headless.
local function fakeGraphics(opts)
  opts = opts or {}
  local images = {}
  local wraps = {}
  local newImageCalls = 0
  return {
    images = images,
    wraps = wraps,
    newImage = function()
      newImageCalls = newImageCalls + 1
      if opts.failOnNewImage == newImageCalls then
        error("injected newImage failure")
      end
      local image = { released = false, releaseCount = 0, index = newImageCalls }
      image.setFilter = function() end
      image.setWrap = function(_, wx, wy)
        if opts.failSetWrapOn == image.index then
          error("injected setWrap failure")
        end
        wraps[#wraps + 1] = { wx, wy }
      end
      image.release = function()
        image.released = true
        image.releaseCount = image.releaseCount + 1
      end
      images[#images + 1] = image
      return image
    end,
  }
end

function T.rejects_a_missing_graphics_namespace()
  local err = Assert.throws(function()
    GpuAssetPool.new(fakeCacheFs(), { graphics = false })
  end)
  Assert.isTrue(tostring(err):find("GpuAssetPool requires love.graphics", 1, true) ~= nil)
end

function T.unknown_wrap_modes_are_rejected()
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = fakeGraphics() })
  local err = Assert.throws(function()
    pool:imageFor(TEX_PATH, "mirror", "clamp")
  end)
  Assert.isTrue(Errors.is(err) and err.code == "GPU_ASSET_UNKNOWN_WRAP", "raises GPU_ASSET_UNKNOWN_WRAP")
  Assert.equal(#pool.images, 0, "no image was created")
end

function T.image_identity_includes_the_wrap_pair()
  local graphics = fakeGraphics()
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = graphics })
  local repeatX = pool:imageFor(TEX_PATH, "repeat", "clamp")
  local clampX = pool:imageFor(TEX_PATH, "clamp", "clamp")
  Assert.isTrue(repeatX ~= clampX, "different wrap pairs must not alias one image")
  Assert.deepEqual(graphics.wraps[1], { "repeat", "clamp" })
  Assert.deepEqual(graphics.wraps[2], { "clamp", "clamp" })
  Assert.equal(#pool.images, 2)
end

function T.same_path_and_wrap_dedup_to_one_owned_image()
  local graphics = fakeGraphics()
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = graphics })
  local first = pool:imageFor(TEX_PATH, "repeat", "clamp")
  local second = pool:imageFor(TEX_PATH, "repeat", "clamp")
  Assert.equal(first, second)
  Assert.equal(#pool.images, 1)
  Assert.equal(#graphics.images, 1, "the underlying love image is built once")
end

function T.untextured_materials_get_no_image()
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = fakeGraphics() })
  Assert.isNil(pool:imageFor(nil, "clamp", "clamp"))
  Assert.equal(#pool.images, 0)
end

-- Construction rollback: the whole scene build runs inside the build
-- wrapper (MapSceneLoader.load and the NeighborRing load path), so the Nth
-- acquire failing must roll back every object created inside the build -- a
-- partially failed construction never leaks GPU objects.
function T.build_releases_everything_when_the_second_acquire_fails()
  local graphics = fakeGraphics({ failOnNewImage = 2 })
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = graphics })
  local err = Assert.throws(function()
    pool:build(function()
      pool:imageFor(TEX_PATH, "clamp", "clamp")
      pool:imageFor(TEX_PATH, "repeat", "repeat")
    end)
  end)
  Assert.isTrue(tostring(err):find("injected newImage failure", 1, true) ~= nil, "rethrows the image build failure")
  Assert.equal(graphics.images[1].released, true, "the build rolls back the first image")
  Assert.equal(#pool.images, 0, "the pool owns nothing after the failed construction")
  local retry = pool:imageFor(TEX_PATH, "clamp", "clamp")
  Assert.isTrue(retry ~= nil, "the pool is usable after the rollback")
  Assert.equal(#pool.images, 1)
  Assert.equal(graphics.images[2].released, false, "the rebuilt image is owned, not a released leftover")
end

-- The build wrapper is not a release-everything-on-exit path: a successful
-- construction keeps its objects owned and returns the builder's value.
function T.build_keeps_objects_and_returns_the_value_on_success()
  local graphics = fakeGraphics()
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = graphics })
  local result = pool:build(function()
    pool:imageFor(TEX_PATH, "clamp", "clamp")
    return "built"
  end)
  Assert.equal(result, "built", "the build returns the builder's value")
  Assert.equal(graphics.images[1].released, false, "a successful construction keeps its objects")
  Assert.equal(#pool.images, 1)
end

-- The guarded acquire and the build rollback interact: when the Nth acquire
-- fails AFTER recording its own object (a setWrap failure), the guarded
-- acquire pops and releases that object, and the build rollback releases the
-- earlier ones -- every created object is released exactly once, never twice,
-- and nothing stays owned. This is the failure-sequence contract the loaders
-- rely on when an alternate-image creation fails inside a scene build.
function T.build_releases_everything_exactly_once_when_the_failed_acquire_created_its_object()
  local graphics = fakeGraphics({ failSetWrapOn = 3 })
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = graphics })
  local err = Assert.throws(function()
    pool:build(function()
      pool:imageFor(TEX_PATH, "clamp", "clamp")
      pool:imageFor(TEX_PATH, "repeat", "repeat")
      pool:imageFor(TEX_PATH, "repeat", "clamp")
    end)
  end)
  Assert.isTrue(tostring(err):find("injected setWrap failure", 1, true) ~= nil, "rethrows the configuration failure")
  Assert.equal(#graphics.images, 3, "the base and two alternates were all created")
  for _, image in ipairs(graphics.images) do
    Assert.equal(image.releaseCount, 1, "every created image is released exactly once")
  end
  Assert.equal(#pool.images, 0, "the pool owns nothing after the failed construction")
end

-- Post-construction failure: a single lazy acquire failing while the live
-- scene draws must release only the object that failed acquisition itself
-- created -- never the earlier resources the scene is using. The failure is
-- injected after the second image was created (setWrap), so the failed
-- acquisition does own an object to roll back.
function T.failed_single_acquire_releases_only_its_own_object()
  local graphics = fakeGraphics({ failSetWrapOn = 2 })
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = graphics })
  local first = pool:imageFor(TEX_PATH, "clamp", "clamp")
  local err = Assert.throws(function()
    pool:imageFor(TEX_PATH, "repeat", "repeat")
  end)
  Assert.isTrue(tostring(err):find("injected setWrap failure", 1, true) ~= nil, "rethrows the configuration failure")
  Assert.equal(graphics.images[1].released, false, "the earlier image stays alive after a single failed acquire")
  Assert.equal(graphics.images[2].released, true, "the failed acquire's own object is released")
  Assert.equal(#pool.images, 1, "the pool still owns only the earlier image")
  Assert.equal(first, graphics.images[1])
  local retry = pool:imageFor(TEX_PATH, "repeat", "repeat")
  Assert.isTrue(retry ~= nil, "the failed sampler state is acquirable again")
  Assert.equal(graphics.images[3].released, false, "the rebuilt image is owned, not a released cache leftover")
  Assert.equal(#pool.images, 2)
end

function T.release_is_exactly_once_and_repeat_safe()
  local graphics = fakeGraphics()
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = graphics })
  pool:imageFor(TEX_PATH, "clamp", "clamp")
  pool:imageFor(TEX_PATH, "repeat", "clamp")
  pool:release()
  pool:release()
  Assert.equal(graphics.images[1].released, true)
  Assert.equal(graphics.images[2].released, true)
  Assert.equal(#pool.images, 0)
  Assert.equal(#pool.meshes, 0)
end

function T.mesh_entries_dedup_and_accumulate_triangles_once()
  local pool = GpuAssetPool.new(fakeCacheFs())
  local first = pool:meshFor(GEOM_PATH)
  local second = pool:meshFor(GEOM_PATH)
  Assert.equal(first.mesh, second.mesh)
  Assert.equal(first.triangles, 1)
  Assert.equal(pool.triangles, 1, "shared geometry is counted once")
  Assert.equal(#pool.meshes, 1)
  pool:release()
end

-- A mesh file that decodes to zero vertices is malformed data: the geometry
-- math raises SCENE_DESC_EMPTY_MESH instead of folding inf/nan seeds. The
-- mesh object the builder created before that step must already be owned by
-- the pool, so the guarded acquire pops and releases it exactly once --
-- never an orphaned love Mesh.
function T.empty_mesh_fails_and_releases_the_created_mesh()
  local created = {}
  local pool = GpuAssetPool.new(fakeCacheFs(), {
    graphics = fakeGraphics(),
    meshBuilder = function()
      local mesh = { released = false }
      mesh.release = function()
        mesh.released = true
      end
      created[#created + 1] = mesh
      return mesh --[[@as GpuAssetPool.Mesh]]
    end,
  })
  local err = Assert.throws(function()
    pool:meshFor(EMPTY_GEOM_PATH)
  end)
  Assert.isTrue(Errors.is(err) and err.code == ErrorCodes.SCENE_DESC_EMPTY_MESH, "raises SCENE_DESC_EMPTY_MESH")
  Assert.equal(#created, 1, "the builder created the mesh before the geometry step")
  Assert.equal(created[1].released, true, "the failed acquisition's own mesh is released")
  Assert.equal(#pool.meshes, 0, "the pool owns no mesh after the failed acquire")
end

-- The per-mesh geometry cache: the entry exposes the model-space
-- bounding-box center and AABB, computed ONCE per content-addressed path and
-- shared by every consumer (draw items, descriptor folds, sort centers) --
-- consumers read the cached values instead of rescanning the same vertices
-- per draw/placement. The values live on the shared entry, so repeated
-- acquires return the same precomputed tables.
function T.mesh_entries_expose_cached_center_and_aabb()
  local pool = GpuAssetPool.new(fakeCacheFs())
  local entry = pool:meshFor(GEOM_PATH)
  -- The triangle fixture spans x[0,2], y=0, z[0,2].
  Assert.deepEqual(entry.center, { 1, 0, 1 }, "the pool mesh entry exposes the cached model-space center")
  Assert.deepEqual(
    entry.bounds,
    { minX = 0, maxX = 2, minY = 0, maxY = 0, minZ = 0, maxZ = 2 },
    "the pool mesh entry exposes the cached model-space AABB"
  )
  local again = pool:meshFor(GEOM_PATH)
  Assert.equal(again, entry, "the entry is the shared per-path object")
  Assert.equal(again.center, entry.center, "the cached center is computed once per content-addressed path")
  Assert.equal(again.bounds, entry.bounds, "the cached AABB is computed once per content-addressed path")
  pool:release()
end

-- Injected graphics namespace for prepared-mesh realization: newMesh is
-- called by vertex count/layout (never a decoded vertex table), and
-- setVertices/setVertexMap can be made to fail after the Mesh object exists,
-- to exercise the transactional rollback the prepared path must share with
-- the synchronous path.
local function fakeMeshGraphics(opts)
  opts = opts or {}
  local created = {}
  return {
    created = created,
    newImage = fakeGraphics().newImage,
    newMesh = function(_, _, _)
      local mesh = { released = false, vertexData = nil, vertexMapData = nil, indexType = nil }
      mesh.setVertices = function(_, data)
        if opts.failSetVertices then
          error("injected setVertices failure")
        end
        mesh.vertexData = data
      end
      mesh.setVertexMap = function(_, data, datatype)
        if opts.failSetVertexMap then
          error("injected setVertexMap failure")
        end
        mesh.vertexMapData = data
        mesh.indexType = datatype
      end
      mesh.release = function()
        mesh.released = true
      end
      created[#created + 1] = mesh
      return mesh
    end,
  }
end

local function preparedMeshPayload()
  return SceneMesh.prepareUpload(MeshWriter.encode(triangleBatch()))
end

-- Equivalence: a prepared realization must dedup, geometry-fold, and stat
-- exactly like the synchronous path for the same content-addressed path.
function T.meshFromPrepared_matches_meshFor_geometry_for_equivalent_content()
  local syncPool = GpuAssetPool.new(fakeCacheFs())
  local syncEntry = syncPool:meshFor(GEOM_PATH)

  local graphics = fakeMeshGraphics()
  local preparedPool = GpuAssetPool.new(fakeCacheFs(), { graphics = graphics })
  local preparedEntry = preparedPool:meshFromPrepared(GEOM_PATH, preparedMeshPayload())

  Assert.equal(preparedEntry.triangles, syncEntry.triangles)
  Assert.deepEqual(preparedEntry.center, syncEntry.center)
  Assert.deepEqual(preparedEntry.bounds, syncEntry.bounds)
  Assert.notNil(graphics.created[1].vertexMapData, "prepared realization uploads a zero-based vertex map Data")
  Assert.equal(#preparedPool.meshes, 1)

  syncPool:release()
  preparedPool:release()
end

-- Dedup across entry points: a path already realized through one entry
-- point must not be rebuilt through the other.
function T.meshFromPrepared_dedups_with_a_prior_synchronous_acquire()
  local graphics = fakeMeshGraphics()
  local pool = GpuAssetPool.new(fakeCacheFs(), {
    graphics = graphics,
    meshBuilder = function()
      return { release = function() end }
    end,
  })
  local synchronous = pool:meshFor(GEOM_PATH)
  local prepared = pool:meshFromPrepared(GEOM_PATH, preparedMeshPayload())
  Assert.equal(prepared, synchronous, "the prepared path returns the already-realized entry, never a duplicate")
  Assert.equal(#pool.meshes, 1, "no second Mesh object is created for an already-realized path")
end

-- Transactional realization: a failure between Mesh creation and
-- publication must release the partial object and leave the pool's cache
-- tables/counters exactly as before the failed call.
function T.meshFromPrepared_rolls_back_the_partial_mesh_on_publish_failure()
  local graphics = fakeMeshGraphics({ failSetVertexMap = true })
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = graphics })
  local err = Assert.throws(function()
    pool:meshFromPrepared(GEOM_PATH, preparedMeshPayload())
  end)
  Assert.isTrue(tostring(err):find("injected setVertexMap failure", 1, true) ~= nil)
  Assert.equal(#pool.meshes, 0, "no mesh is published before every upload step succeeds")
  Assert.equal(pool.triangles, 0, "the triangle stat is not updated for an unpublished mesh")
  Assert.equal(graphics.created[1].released, true, "the partially-constructed mesh is released")

  local retryGraphics = fakeMeshGraphics()
  local retryPool = GpuAssetPool.new(fakeCacheFs(), { graphics = retryGraphics })
  local retried = retryPool:meshFromPrepared(GEOM_PATH, preparedMeshPayload())
  Assert.notNil(retried, "the prepared path is usable again after a rolled-back failure")
  retryPool:release()
end

-- imageFromPrepared shares GpuAssetPool's image identity/dedup/rollback
-- authority with imageFor: same content-addressed path plus wrap pair
-- realized through either entry point must resolve to one owned Image.
function T.imageFromPrepared_dedups_with_imageFor_by_path_and_wrap()
  local graphics = fakeGraphics()
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = graphics })
  local prepared = { imageData = { fakeImageData = true } }
  local fromPrepared = pool:imageFromPrepared(TEX_PATH, "clamp", "clamp", prepared)
  local fromSync = pool:imageFor(TEX_PATH, "clamp", "clamp")
  Assert.equal(fromPrepared, fromSync, "prepared and synchronous realization share one dedup key")
  Assert.equal(#pool.images, 1)
end

function T.imageFromPrepared_rolls_back_on_publish_failure_and_stays_usable()
  local graphics = fakeGraphics({ failSetWrapOn = 1 })
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = graphics })
  local prepared = { imageData = { fakeImageData = true } }
  local err = Assert.throws(function()
    pool:imageFromPrepared(TEX_PATH, "clamp", "clamp", prepared)
  end)
  Assert.isTrue(tostring(err):find("injected setWrap failure", 1, true) ~= nil)
  Assert.equal(#pool.images, 0, "no image is published before every configuration step succeeds")
  Assert.equal(graphics.images[1].released, true, "the failed prepared image is released")

  local retried = pool:imageFromPrepared(TEX_PATH, "clamp", "clamp", prepared)
  Assert.notNil(retried, "the pool is usable again after a rolled-back prepared realization")
  Assert.equal(#pool.images, 1)
end

return {
  metadata = { capabilities = { "graphics" } },
  tests = T,
}
