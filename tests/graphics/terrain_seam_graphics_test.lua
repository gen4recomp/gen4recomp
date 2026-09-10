-- Graphics regression for terrain T-seams through the real world-MRT path.
--
-- Two opaque adjacent batches share a ground-plane span at x=0: the left
-- batch breaks the span at P while the right batch spans it unbroken. The
-- deterministic producer contract (a diagnosed cross-batch T-junction before
-- repair, zero after, with preserved area/winding and deterministic
-- serialization) pairs with the backend-portable render postcondition: the
-- repaired pair leaves zero isolated enclosed rear-plane samples through
-- GxRenderer's world MRT across a subpixel sweep at world-raster scales 1
-- and 3. Correctness never requires a particular GPU backend to reproduce a
-- hole for the broken input.

local Assert = require("tests.support.Assert")
local ffi = require("ffi")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local GxRenderer = require("libs.nds.src.love.GxRenderer")
local Matrix4 = require("libs.math.src.Matrix4")
local RenderQueue = require("libs.hgss.src.presentation.RenderQueue")
local VertexFormat = require("libs.assets.src.model.VertexFormat")
local GeometryBuffer = require("libs.nds.src.gx.GxGeometryBuffer")

local T = {}

local CONFORMER_MODULE = "romdump.src.digest.map.TerrainBoundaryConformer"

local function conformer()
  local ok, mod = pcall(require, CONFORMER_MODULE)
  Assert.isTrue(
    ok and type(mod) == "table" and type(mod.conform) == "function",
    "terrain boundary repair is missing: the conformed seam cannot be produced"
  )
  return mod --[[@as table]]
end

local IDENTITY = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
local IDENTITY_NORMAL = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }

local function zeroFog()
  local table32 = {}
  for i = 1, 32 do
    table32[i] = 0
  end
  return { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = table32 }
end

local function V(x, y, z)
  return {
    x = x,
    y = y,
    z = z,
    u = 0,
    v = 0,
    nx = 0,
    ny = 0,
    nz = 1,
    r = 255,
    g = 255,
    b = 255,
    a = 255,
    colorSource = 0,
  }
end

local function batch(vertices, indices, materialIndex)
  return {
    nodeIndex = 0,
    materialIndex = materialIndex,
    shapeIndex = 0,
    polygonAttrRaw = 0x001F00C1,
    transformMode = "static",
    vertices = vertices,
    indices = indices,
  }
end

-- The deliberate T-seam on the y=0 ground plane in tile units: the left
-- batch breaks the shared span x=0 at P=(0,0,0.5) while the right batch
-- spans it whole. Rendered under a tilted perspective camera, the span
-- projects to a long near-vertical screen line, so differently segmented but
-- collinear edges can disagree at isolated sample centers.
local function seamBatches()
  local left = batch({
    V(-8, 0, -4),
    V(0, 0, -4),
    V(0, 0, 0.5),
    V(-8, 0, 0.5),
    V(0, 0, 4),
    V(-8, 0, 4),
  }, { 0, 1, 2, 0, 2, 3, 3, 2, 4, 3, 4, 5 }, 0)
  local right = batch({
    V(0, 0, -4),
    V(8, 0, -4),
    V(8, 0, 4),
    V(0, 0, 4),
  }, { 0, 1, 2, 0, 2, 3 }, 1)
  local arena = GeometryBuffer.new()
  local batches = {}
  for index, source in ipairs({ left, right }) do
    arena:reserve(#source.vertices, #source.indices)
    local vertexOffset, indexOffset = arena.vertexCount, arena.indexCount
    for vertexIndex, vertex in ipairs(source.vertices) do
      local numeric = arena.numeric[vertexOffset + vertexIndex - 1]
      numeric.x, numeric.y, numeric.z = vertex.x, vertex.y, vertex.z
      numeric.u, numeric.v = vertex.u, vertex.v
      numeric.nx, numeric.ny, numeric.nz = vertex.nx, vertex.ny, vertex.nz
      local attrib = arena.attrib[vertexOffset + vertexIndex - 1]
      attrib.r, attrib.g, attrib.b, attrib.a = vertex.r, vertex.g, vertex.b, vertex.a
      attrib.colorSource = vertex.colorSource
    end
    for indexValue, value in ipairs(source.indices) do
      arena.indices[indexOffset + indexValue - 1] = value
    end
    arena.vertexCount = vertexOffset + #source.vertices
    arena.indexCount = indexOffset + #source.indices
    batches[index] = {
      nodeIndex = source.nodeIndex,
      materialIndex = source.materialIndex,
      shapeIndex = source.shapeIndex,
      polygonAttrRaw = source.polygonAttrRaw,
      transformMode = source.transformMode,
      arena = arena,
      vertexOffset = vertexOffset,
      vertexCount = #source.vertices,
      indexOffset = indexOffset,
      indexCount = #source.indices,
    }
  end
  return batches
end

local function cloneBatches(batches)
  local arena = GeometryBuffer.new()
  local clones = {}
  for index, source in ipairs(batches) do
    arena:reserve(source.vertexCount, source.indexCount)
    local vertexOffset, indexOffset = arena.vertexCount, arena.indexCount
    ffi.copy(
      arena.numeric[vertexOffset],
      source.arena.numeric[source.vertexOffset],
      source.vertexCount * GeometryBuffer.vertexNumericSize
    )
    ffi.copy(
      arena.attrib[vertexOffset],
      source.arena.attrib[source.vertexOffset],
      source.vertexCount * GeometryBuffer.vertexAttribSize
    )
    for offset = 0, source.indexCount - 1 do
      arena.indices[indexOffset + offset] = source.arena.indices[source.indexOffset + offset]
    end
    arena.vertexCount, arena.indexCount = vertexOffset + source.vertexCount, indexOffset + source.indexCount
    clones[index] = {
      nodeIndex = source.nodeIndex,
      materialIndex = source.materialIndex,
      shapeIndex = source.shapeIndex,
      polygonAttrRaw = source.polygonAttrRaw,
      transformMode = source.transformMode,
      arena = arena,
      vertexOffset = vertexOffset,
      vertexCount = source.vertexCount,
      indexOffset = indexOffset,
      indexCount = source.indexCount,
    }
  end
  return clones
end

local function loveVertices(compiled)
  local flat = {}
  for offset = 0, compiled.indexCount - 1 do
    local i = compiled.arena.indices[compiled.indexOffset + offset]
    local v = compiled.arena.numeric[compiled.vertexOffset + i]
    local bytes = compiled.arena.attrib[compiled.vertexOffset + i]
    flat[#flat + 1] = {
      v.x,
      v.y,
      v.z,
      v.u,
      v.v,
      v.nx,
      v.ny,
      v.nz,
      bytes.r / 255,
      bytes.g / 255,
      bytes.b / 255,
      bytes.a / 255,
      bytes.colorSource,
    }
  end
  return flat
end

local function drawItem(mesh)
  return {
    mesh = mesh,
    material = { texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
    transform = IDENTITY,
    modelNormal = IDENTITY_NORMAL,
    center = { 0, 0, 0 },
    alphaClass = "opaque",
    cullMode = "none",
    polygonAlpha = 1.0,
    polygonMode = "modulation",
    polygonId = 0,
    lightMask = 1,
    fogEnabled = false,
    projection = nil, -- filled per frame below
  }
end

local function isRear(r)
  return r >= 0.99
end

-- Counts rear-plane samples fully enclosed in drawn terrain inside a band
-- around the seam column, staying clear of the screen borders.
local function countEnclosedRear(stateImg, w, h)
  local count = 0
  local cx = math.floor(w / 2)
  for x = cx - 14, cx + 14 do
    for y = 24, h - 25 do
      local r = stateImg:getPixel(x, y)
      if isRear(r) then
        local enclosed = true
        for ox = -1, 1 do
          for oy = -1, 1 do
            if (ox ~= 0 or oy ~= 0) and isRear(stateImg:getPixel(x + ox, y + oy)) then
              enclosed = false
              break
            end
          end
          if not enclosed then
            break
          end
        end
        if enclosed then
          count = count + 1
        end
      end
    end
  end
  return count
end

-- Renders the batch pair across a subpixel camera sweep and totals the
-- enclosed rear-plane samples. Returns the total plus per-scale totals.
local function sweep(scope, batches, scale)
  local renderer = scope:own(GxRenderer.new({ worldRasterScale = scale }))
  local meshes = {}
  for _, compiled in ipairs(batches) do
    meshes[#meshes + 1] =
      scope:own(love.graphics.newMesh(VertexFormat.LAYOUT, loveVertices(compiled), "triangles", "static"))
  end
  local viewport = FieldViewport.new(1280, 720, { mode = "expanded" })
  local scratch = { opaque = {}, cutout = {}, mixedOpaque = {}, wireframe = {}, blended = {} }
  local projection = Matrix4.perspective(math.rad(30), 1280 / 720, 1, 100)

  local items = {}
  for _, mesh in ipairs(meshes) do
    local item = drawItem(mesh)
    item.projection = projection
    items[#items + 1] = item
  end

  local function frame(dx, dz)
    local eye = { 0 + dx, 9, 13 + dz }
    local target = { 0 + dx, 0, -1 + dz }
    local view = Matrix4.lookAt(eye, target, { 0, 1, 0 })
    local queue = RenderQueue.buildInto({ items }, view, scratch)
    renderer:draw({
      edgeColors = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 },
      fog = zeroFog(),
      viewMatrix = view,
      cameraZoom = 1,
      worldProjection = projection,
      billboardProjection = projection,
      queue = queue,
      viewport = viewport,
    })
  end

  frame(0, 0)
  local total = 0
  for kx = -4, 4 do
    for _, kz in ipairs({ -0.5, 0, 0.5 }) do
      frame(kx * 0.012, kz * 0.012)
      local stateImg = renderer.renderState:newImageData()
      total = total + countEnclosedRear(stateImg, renderer.stateW, renderer.stateH)
      stateImg:release()
    end
  end
  return total
end

-- Each batch alone is internally watertight, so seam holes come from the
-- cross-batch segmentation disagreement rather than degenerate single
-- geometry.
function T.single_batches_cover_without_holes(scope)
  local batches = seamBatches()
  for index, single in ipairs(batches) do
    Assert.equal(sweep(scope, { single }, 1), 0, "batch " .. index .. " alone leaves no hole at scale 1")
    Assert.equal(sweep(scope, { single }, 3), 0, "batch " .. index .. " alone leaves no hole at scale 3")
  end
end

local function countAt(batches, x, y, z)
  local n = 0
  for _, candidate in ipairs(batches) do
    for offset = 0, candidate.vertexCount - 1 do
      local v = candidate.arena.numeric[candidate.vertexOffset + offset]
      if v.x == x and v.y == y and v.z == z then
        n = n + 1
      end
    end
  end
  return n
end

local function signedAreaXZ(a, b, c)
  return 0.5 * ((b.x - a.x) * (c.z - a.z) - (c.x - a.x) * (b.z - a.z))
end

local function totalArea(target)
  local total = 0
  for offset = 0, target.indexCount - 1, 3 do
    local indices = target.arena.indices
    local a = target.arena.numeric[target.vertexOffset + indices[target.indexOffset + offset]]
    local b = target.arena.numeric[target.vertexOffset + indices[target.indexOffset + offset + 1]]
    local c = target.arena.numeric[target.vertexOffset + indices[target.indexOffset + offset + 2]]
    total = total + signedAreaXZ(a, b, c)
  end
  return total
end

function T.conformed_seam_leaves_no_holes(scope)
  local before = seamBatches()
  Assert.isTrue(
    #conformer().findTJunctions(before) >= 1,
    "the deliberate cross-batch T-junction is diagnosed before repair"
  )
  local beforeAreas = { totalArea(before[1]), totalArea(before[2]) }
  local repaired = conformer().conform(cloneBatches(before), { role = "map", modelName = "seam_fixture" }) or before
  Assert.equal(#conformer().findTJunctions(repaired), 0, "no unmatched boundary T-junction remains after repair")
  Assert.equal(countAt({ repaired[2] }, 0, 0, 0.5), 1, "the spanning side expresses the shared breakpoint")
  Assert.equal(countAt(repaired, 0, 0, 0.5), 2, "both sides express the shared breakpoint after repair")
  for index, side in ipairs(repaired) do
    for offset = 0, side.indexCount - 1, 3 do
      local indices = side.arena.indices
      local a = side.arena.numeric[side.vertexOffset + indices[side.indexOffset + offset]]
      local b = side.arena.numeric[side.vertexOffset + indices[side.indexOffset + offset + 1]]
      local c = side.arena.numeric[side.vertexOffset + indices[side.indexOffset + offset + 2]]
      local area = signedAreaXZ(a, b, c)
      Assert.isTrue(math.abs(area) > 1e-12, "retriangulation emits no zero-area triangle in batch " .. index)
    end
    Assert.near(totalArea(side), beforeAreas[index], 1e-9, "repair preserves area in batch " .. index)
  end
  local again = conformer().conform(cloneBatches(before), { role = "map", modelName = "seam_fixture" }) or before
  Assert.deepEqual(
    loveVertices(again[1]),
    loveVertices(repaired[1]),
    "the same seam conforms byte-identically across runs"
  )
  Assert.deepEqual(
    loveVertices(again[2]),
    loveVertices(repaired[2]),
    "the same seam conforms byte-identically across runs"
  )
  local holes1 = sweep(scope, repaired, 1)
  local holes3 = sweep(scope, repaired, 3)
  Assert.equal(holes1, 0, "conformed seam leaves no enclosed rear-plane sample at scale 1")
  Assert.equal(holes3, 0, "conformed seam leaves no enclosed rear-plane sample at scale 3")
end

return GraphicsSmoke.suite(T)
