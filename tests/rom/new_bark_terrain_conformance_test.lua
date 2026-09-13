-- ROM conformance: the compiled New Bark central map and its neighbor models
-- carry no unmatched cross-batch boundary T-junctions.
--
-- Separately rendered terrain batches of one model can segment a shared
-- boundary span differently; the producer repair makes every coarse span
-- express the union of breakpoints before mesh serialization. This suite
-- compiles the real New Bark map through the production compiler and checks
-- the invariant over the central scene batches and over each compiled
-- neighbor model. Material names identify the known grass02_r/grass01
-- exemplar only; production behavior takes no per-material branch.

local Assert = require("tests.support.Assert")
local CompiledAsset = require("tests.rom.support.CompiledAsset")
local GxGeometryBuffer = require("libs.nds.src.gx.GxGeometryBuffer")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")

local T = {}

---@class NewBarkGeometrySlice: G4GxGeometrySlice
---@field materialIndex integer

local CONFORMER_MODULE = "romdump.src.digest.map.TerrainBoundaryConformer"

local function conformer()
  local ok, mod = pcall(require, CONFORMER_MODULE)
  Assert.isTrue(
    ok and type(mod) == "table" and type(mod.findTJunctions) == "function",
    "terrain boundary repair is missing: compiled New Bark batches keep unmatched T-junctions"
  )
  return mod --[[@as table]]
end

local bundles = {}

local function bundleFor(romFs, versionId)
  if bundles[versionId] == nil then
    bundles[versionId] = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK"))
  end
  return bundles[versionId]
end

local function meshBatches(bundle, records)
  local arena = GxGeometryBuffer.new()
  local out = {}
  for _, record in ipairs(records) do
    local sha1 = record.geometry:match("(%x+)%.g4mesh$")
    Assert.notNil(sha1, "terrain batch geometry is a content-addressed .g4mesh path")
    ---@cast sha1 string
    local decoded = CompiledAsset.mesh(assert(bundle.meshes[sha1], "the shared mesh pool holds " .. sha1))
    arena:reserve(decoded.vertexCount, decoded.indexCount)
    local slice = arena:beginSlice()
    ---@cast slice NewBarkGeometrySlice
    for _, vertex in ipairs(decoded.vertices) do
      local numeric = arena.numeric[arena.vertexCount]
      local attrib = arena.attrib[arena.vertexCount]
      numeric.x, numeric.y, numeric.z = vertex[1], vertex[2], vertex[3]
      numeric.u, numeric.v = vertex[4], vertex[5]
      numeric.nx, numeric.ny, numeric.nz = vertex[6], vertex[7], vertex[8]
      attrib.r = vertex[9] * 255
      attrib.g = vertex[10] * 255
      attrib.b = vertex[11] * 255
      attrib.a = vertex[12] * 255
      attrib.colorSource = vertex[13]
      arena.vertexCount = arena.vertexCount + 1
    end
    for _, index in ipairs(decoded.indices) do
      arena.indices[arena.indexCount] = index
      arena.indexCount = arena.indexCount + 1
    end
    slice.materialIndex = record.material
    out[#out + 1] = arena:finishSlice(slice)
  end
  return out
end

function T.grass_exemplar_seam_has_matching_breakpoints(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  local wanted = { grass02_r = false, grass01 = false }
  local ids = {}
  for _, material in ipairs(bundle.scene.materials) do
    if wanted[material.name] ~= nil then
      wanted[material.name] = true
      ids[material.id] = true
    end
  end
  Assert.isTrue(wanted.grass02_r and wanted.grass01, "both exemplar materials are present in the scene")
  local pair = {}
  for _, record in ipairs(bundle.scene.mapBatches) do
    if ids[record.material] then
      pair[#pair + 1] = record
    end
  end
  Assert.isTrue(#pair > 0, "the exemplar materials draw batches")
  Assert.equal(
    #conformer().findTJunctions(meshBatches(bundle, pair)),
    0,
    "the grass02_r/grass01 seam shares matching breakpoints after compilation"
  )
end

function T.production_map_batches_have_no_unmatched_t_junctions(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  Assert.isTrue(#bundle.scene.mapBatches > 0, "the central scene draws terrain batches")
  Assert.equal(
    #conformer().findTJunctions(meshBatches(bundle, bundle.scene.mapBatches)),
    0,
    "zero unmatched cross-batch T-junctions in the production map batches"
  )
end

function T.compiled_neighbor_models_have_no_unmatched_t_junctions(romFs, versionId)
  local bundle = bundleFor(romFs, versionId)
  Assert.isTrue(#bundle.scene.neighbors > 0, "the central scene carries compiled neighbors")
  for index, neighbor in ipairs(bundle.scene.neighbors) do
    Assert.equal(
      #conformer().findTJunctions(meshBatches(bundle, neighbor.batches)),
      0,
      "neighbor descriptor " .. index .. " has zero unmatched cross-batch T-junctions"
    )
  end
end

return require("tests.rom.support.RomSuite").fromFacts(T)
