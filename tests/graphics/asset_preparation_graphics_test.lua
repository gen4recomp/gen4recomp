-- The one real-thread/real-Data proof for the presentation preparation
-- worker: a real love.thread worker reads real save-directory cache bytes,
-- decodes/packs a mesh and decodes an image, and replies with LÖVE
-- Data/ImageData -- never a Mesh or Image. Every other queue behavior
-- (priority, cancellation, disposal) is covered deterministically with a
-- fake thread/channel in the component-layer queue tests; this suite proves
-- only that the real worker/Data path works and never touches love.graphics.
-- The real filesystem is required here (unlike the in-memory FakeCache used
-- elsewhere) because a worker Lua state cannot see this state's closures --
-- only the shared save directory and Channel-safe Variants cross the
-- boundary.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local PngWriter = require("libs.assets.src.PngWriter")

local T = {}

local VERSION_ID = "asset-preparation-worker-test"
local MESH_PATH = "geometry/prepared.g4mesh"
local TEXTURE_PATH = "textures/prepared.png"

local function requireQueue()
  local ok, AssetPreparationQueue = pcall(require, "libs.hgss.src.presentation.AssetPreparationQueue")
  Assert.isTrue(ok, "the production asset preparation queue boundary is missing: " .. tostring(AssetPreparationQueue))
  return AssetPreparationQueue --[[@as table]]
end

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

local function preparedCache()
  local cache = CacheFs.forVersion(VERSION_ID)
  cache:write(MESH_PATH, MeshWriter.encode(triangleBatch()))
  cache:write(TEXTURE_PATH, PngWriter.encode(2, 2, string.char(255, 0, 0, 255):rep(4)))
  return cache
end

function T.worker_prepares_mesh_and_image_payloads_without_touching_graphics()
  local AssetPreparationQueue = requireQueue()
  local cache = preparedCache()
  local statsBefore = love.graphics.getStats()

  local ok, err = pcall(function()
    local queue = AssetPreparationQueue.new(cache)
    local meshToken = queue:request("mesh", MESH_PATH, "demand")
    local imageToken = queue:request("image", TEXTURE_PATH, "demand")

    local mesh = queue:wait(meshToken)
    Assert.equal(mesh.vertexCount, 3)
    Assert.equal(mesh.indexCount, 3)
    Assert.equal(mesh.indexType, "uint16")
    Assert.isNil(mesh.mesh, "the worker never realizes a love Mesh")
    Assert.notNil(mesh.vertexData, "the worker replies with packed vertex Data")
    Assert.notNil(mesh.indexData, "the worker replies with packed index Data")

    local image = queue:wait(imageToken)
    Assert.isNil(image.image, "the worker never realizes a love Image")
    Assert.notNil(image.imageData, "the worker replies with decoded ImageData")
    Assert.equal(image.imageData:getWidth(), 2)
    Assert.equal(image.imageData:getHeight(), 2)

    queue:release()
  end)

  local statsAfter = love.graphics.getStats()
  cache:removeTree("")

  if not ok then
    error(err, 0)
  end
  Assert.equal(statsAfter.images, statsBefore.images, "preparation alone creates no GPU Image")
  Assert.equal(statsAfter.canvases, statsBefore.canvases, "preparation alone creates no GPU Canvas")
end

return {
  metadata = { capabilities = { "graphics" } },
  tests = T,
}
