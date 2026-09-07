local Assert = require("tests.support.Assert")
local WorldManifest = require("romdump.src.digest.map.WorldManifest")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MapAssetCache = require("libs.assets.src.MapAssetCache")

local T = {}

-- The artifact staging root mirrors the live cache-relative layout, so the
-- staged manifest lives under `staging/<version>/world/` until publish.
local WORLD_ROOT = "staging/heartgold/world"
local WORLD_STAGE = WORLD_ROOT .. "/" .. MapAssetCache.worldPath()

local function sample()
  return {
    {
      id = 61,
      symbol = "MAP_NEW_BARK_ELMS_LAB_1F",
      mapSection = "NEW_BARK_TOWN",
      width = 1,
      height = 1,
      matrix = { memberId = 0, x = 0, z = 0 },
    },
    {
      id = 60,
      symbol = "MAP_NEW_BARK",
      mapSection = "NEW_BARK_TOWN",
      width = 3,
      height = 3,
      matrix = { memberId = 0, x = 21, z = 12 },
    },
  }
end

local function selectionExcluded()
  return {
    { id = 3, symbol = "MAP_NOTHING", reason = "no_matching_cell", matchCount = 0 },
    { id = 1, symbol = "MAP_ELSEWHERE", reason = "no_matching_cell", matchCount = 0 },
  }
end

local function compileExcluded()
  return {
    {
      id = 0,
      symbol = "MAP_EVERYWHERE",
      errorCode = "NSBMD_SBC_UNSUPPORTED_COMMAND",
      message = "BBY is unsupported",
      context = { model = "snap_came_in", opcode = 8 },
    },
  }
end

function T.build_sorts_by_id_and_indexes()
  local m = WorldManifest.build(sample(), selectionExcluded(), compileExcluded())
  Assert.equal(m.maps[1].id, 60)
  Assert.equal(m.maps[2].id, 61)
  Assert.equal(m.bySymbol["MAP_NEW_BARK"], 60)
  Assert.equal(m.byId[61], 2)
  Assert.equal(m.maps[1].matrix.x, 21)
  Assert.equal(m.analysis.mapHeaderCount, 5)
  Assert.equal(m.analysis.renderableCount, 2)
end

-- The two exclusion kinds mean different things, so they are separate
-- collections: an unresolved cell is a selection limit, a compile failure is an
-- asset-support gap with a code and context to act on.
function T.selection_and_compile_exclusions_are_separate_and_sorted()
  local m = WorldManifest.build(sample(), selectionExcluded(), compileExcluded())
  Assert.equal(#m.analysis.excluded, 2)
  Assert.equal(m.analysis.excluded[1].id, 1)
  Assert.equal(m.analysis.excluded[2].id, 3)
  Assert.equal(#m.analysis.compileExcluded, 1)
  Assert.equal(m.analysis.compileExcluded[1].symbol, "MAP_EVERYWHERE")
  Assert.equal(m.analysis.compileExcluded[1].errorCode, "NSBMD_SBC_UNSUPPORTED_COMMAND")
  Assert.equal(m.analysis.compileExcluded[1].context.model, "snap_came_in")
end

function T.build_defaults_both_exclusion_collections_to_empty()
  local m = WorldManifest.build(sample())
  Assert.deepEqual(m.analysis.excluded, {})
  Assert.deepEqual(m.analysis.compileExcluded, {})
  Assert.equal(m.analysis.mapHeaderCount, 2)
end

function T.a_map_cannot_be_excluded_twice_across_the_collections()
  Assert.throws(function()
    WorldManifest.build(
      sample(),
      { { id = 0, symbol = "MAP_EVERYWHERE", reason = "no_matching_cell" } },
      compileExcluded()
    )
  end)
end

function T.a_compile_excluded_map_cannot_also_be_renderable()
  Assert.throws(function()
    WorldManifest.build(sample(), {}, { { id = 60, symbol = "MAP_NEW_BARK", errorCode = "X", message = "y" } })
  end)
end

function T.build_rejects_duplicate_symbol()
  local dup = sample()
  dup[1].symbol = "MAP_NEW_BARK"
  Assert.throws(function()
    WorldManifest.build(dup)
  end)
end

function T.build_rejects_missing_map_section()
  local entries = sample()
  entries[1].mapSection = nil
  Assert.throws(function()
    WorldManifest.build(entries)
  end)
end

function T.build_rejects_duplicate_id()
  local dup = sample()
  dup[1].id = 60
  Assert.throws(function()
    WorldManifest.build(dup)
  end)
end

-- The staged manifest lives under the artifact staging root until publish, and
-- the live world.lua is never written directly.
function T.stage_leaves_live_world_untouched_until_publish()
  local backend = FakeCache.new()
  local c = CacheFs.forVersion("heartgold", backend)
  local world = WorldManifest.stage(c, sample(), selectionExcluded(), compileExcluded())
  Assert.isNil(c:getInfo(MapAssetCache.worldPath()), "live world.lua must not exist before publish")
  Assert.notNil(backend:getInfo(WORLD_STAGE), "the manifest is staged for the pending publication")
  world:publish()
  local live = assert(c:loadLua(MapAssetCache.worldPath()))
  Assert.equal(live.maps[1].id, 60)
  Assert.equal(live.bySymbol["MAP_NEW_BARK"], 60)
  Assert.equal(live.analysis.mapHeaderCount, 5)
  Assert.isNil(backend:getInfo(WORLD_ROOT), "the stage is removed after a successful publish")
end

-- A staged manifest that does not read back as a manifest fails the stage: the
-- stage is discarded and the previous live world stays the last-known-good.
function T.corrupted_staged_write_fails_without_touching_the_live_world()
  local backend = FakeCache.new()
  local c = CacheFs.forVersion("heartgold", backend)
  local first = WorldManifest.stage(c, sample())
  first:publish()
  local orig = backend.write
  backend.write = function(self, path, data)
    if path == WORLD_STAGE then
      return orig(self, path, "not a lua manifest")
    end
    return orig(self, path, data)
  end
  local err = Assert.throws(function()
    WorldManifest.stage(c, sample(), selectionExcluded(), compileExcluded())
  end)
  backend.write = orig
  Assert.equal(err.code, "WORLD_MANIFEST_READBACK_FAILED")
  Assert.isNil(backend:getInfo(WORLD_ROOT), "the failed stage is discarded")
  local live = assert(c:loadLua(MapAssetCache.worldPath()))
  Assert.equal(live.analysis.mapHeaderCount, 2, "the live world must stay the last-known-good")
end

-- A publish failure re-raises and leaves the last-known-good live world in
-- place: the single-file swap is atomic on the host rename.
function T.publish_failure_keeps_the_last_known_good_world_live()
  local backend = FakeCache.new()
  local c = CacheFs.forVersion("heartgold", backend)
  local first = WorldManifest.stage(c, sample())
  first:publish()
  local originalReplace = backend.replace
  backend.replace = function(self, sourcePath, destinationPath)
    if sourcePath:find(WORLD_ROOT, 1, true) then
      return false, "injected publish failure"
    end
    return originalReplace(self, sourcePath, destinationPath)
  end
  local second = WorldManifest.stage(c, sample(), selectionExcluded(), compileExcluded())
  local err = Assert.throws(function()
    second:publish()
  end)
  backend.replace = originalReplace
  Assert.equal(err.code, "CACHE_REPLACE_FAILED")
  local live = assert(c:loadLua(MapAssetCache.worldPath()))
  Assert.equal(live.analysis.mapHeaderCount, 2, "the last-known-good world stays live after a failed publish")
end

-- Abort discards the disposable stage; the live world is never touched.
function T.abort_discards_the_staged_manifest_without_touching_live()
  local backend = FakeCache.new()
  local c = CacheFs.forVersion("heartgold", backend)
  local world = WorldManifest.stage(c, sample(), selectionExcluded(), compileExcluded())
  world:abort()
  Assert.isNil(c:getInfo(MapAssetCache.worldPath()), "abort never touches the live world")
  Assert.isNil(backend:getInfo(WORLD_ROOT), "abort discards the staged manifest")
end

return { tests = T }
