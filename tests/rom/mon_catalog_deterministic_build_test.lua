-- ROM-conformance test: identical raw dump and producer tree produce
-- byte-identical mon class output across two independent staging roots.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function sortedKeys(files)
  local keys = {}
  for key in pairs(files) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

-- Two full builds into isolated backends agree on every sorted relative path
-- and byte, for both Lua resources and atlas PNGs; the ready/index hash is
-- stable without reserializing image bytes.
function T.identical_inputs_produce_byte_identical_class_output(romFs, versionId)
  local MonCatalogCompiler = require("romdump.src.digest.MonCatalogCompiler")
  local MonCacheWriter = require("romdump.src.digest.MonCacheWriter")

  local firstBackend = FakeCache.new()
  local secondBackend = FakeCache.new()
  local first = CacheFs.forVersion(versionId, firstBackend)
  local second = CacheFs.forVersion(versionId, secondBackend)
  local firstBundle = assert(MonCatalogCompiler.compileAll(romFs, { versionId = versionId }))
  local secondBundle = assert(MonCatalogCompiler.compileAll(romFs, { versionId = versionId }))
  local firstMarker = MonCacheWriter.write(first, firstBundle)
  local secondMarker = MonCacheWriter.write(second, secondBundle)
  Assert.equal(firstMarker, secondMarker, "ready marker must be stable")

  local firstKeys = sortedKeys(firstBackend.files)
  local secondKeys = sortedKeys(secondBackend.files)
  Assert.deepEqual(firstKeys, secondKeys, "both builds must emit the same relative paths")
  Assert.isTrue(#firstKeys > 0, "a build must emit class output")
  for _, key in ipairs(firstKeys) do
    Assert.equal(secondBackend.files[key], firstBackend.files[key], "byte-identical output at " .. key)
  end
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump", "derived_cache" }
return suite
