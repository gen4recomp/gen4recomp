-- ROM-backed producer equivalence: the direct New Bark map bundle and the
-- published field-cell/model output must agree on building descriptors and
-- placement. The field-cell side is read from the prepared derived cache, so
-- this suite performs one representative map compile and no whole-corpus
-- field-cell build. Runs only in the ROM-gated layer.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapResolver = require("romdump.src.digest.map.MapResolver")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

function T.map_and_field_cell_builders_preserve_shared_model_output(romFs, versionId)
  local mapBundle = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK"))
  local cache = CacheFs.forVersion(versionId)
  local index = FieldCellCache.loadIndex(cache)
  local resolved = assert(MapResolver.resolve(romFs, "MAP_NEW_BARK"))
  local descriptor = assert(FieldCellCache.find(index, resolved.matrixMemberId, resolved.matrixX, resolved.matrixZ))
  local cell = assert(cache:loadLua(descriptor.file))
  for modelKey, mapDescriptor in pairs(mapBundle.models) do
    local publishedDescriptor = assert(cache:loadLua(MapAssetCache.modelPath(modelKey)))
    Assert.deepEqual(
      publishedDescriptor,
      mapDescriptor,
      "map and physical-cell producers must share the same building descriptor: " .. modelKey
    )
  end
  Assert.deepEqual(
    cell.buildingInstances,
    mapBundle.scene.buildingInstances,
    "map and physical-cell producers must preserve building placement output"
  )
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump", "derived_cache" }
suite.metadata.tags = { "producer", "cache", "equivalence" }
return suite
