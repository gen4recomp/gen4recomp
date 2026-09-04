-- Builds and persists the whole-ROM world manifest: the map index the game
-- boots and switches on. Pure build-side domain (no love); stage() takes a
-- CacheFs. Source of map identity is the compiled scenes, not the ROM.
--
-- The manifest follows the shared staged-publication lifecycle of every other
-- generated artifact: it is written into the disposable artifact stage, read
-- back and validated there, and only published over the live `world.lua` when
-- the caller has reached the success level that makes the new index
-- authoritative. The live path is never written directly.

local MapAssetCache = require("libs.assets.src.MapAssetCache")
local Errors = require("libs.errors.src.Errors")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")

local WorldManifest = {}

local function sortById(a, b)
  return a.id < b.id
end

local function sortedById(records)
  local out = {}
  for _, record in ipairs(records or {}) do
    out[#out + 1] = record
  end
  table.sort(out, sortById)
  return out
end

local function validateStagedManifest(tx, manifest)
  tx.stage:writeLua(MapAssetCache.worldPath(), manifest)
  local readBack = tx.stage:loadLua(MapAssetCache.worldPath())
  if type(readBack) ~= "table" or type(readBack.maps) ~= "table" then
    Errors.raise(
      "WORLD_MANIFEST_READBACK_FAILED",
      "world.lua did not read back as a manifest",
      { path = MapAssetCache.worldPath() }
    )
  end
end

---@param version string
---@param transaction ArtifactPublisher
---@return table<string, unknown>
local function newStagedWorld(version, transaction)
  local function publish()
    transaction:publish()
  end

  local function abort()
    transaction:abort()
  end

  return { version = version, publish = publish, abort = abort }
end

-- `excluded` holds maps whose matrix cell could not be selected; `compileExcluded`
-- holds resolved maps whose asset compilation raised a structured error. The two
-- are separate collections because they mean different things: the first is a
-- map-selection limit, the second an asset-support gap with an error code and
-- context to act on.
function WorldManifest.build(entries, excluded, compileExcluded)
  local maps = {}
  for _, e in ipairs(entries) do
    maps[#maps + 1] = e
  end
  table.sort(maps, sortById)

  -- The runtime map compatibility contract: every renderable entry carries
  -- its semantic section, the exact numeric MAPSEC_* identity, and the
  -- source follow mode. Stale or hand-built entries without them fail here
  -- instead of publishing a world the runtime would have to default.
  local FOLLOW_MODES = { ALLOW = true, HEIGHT_RESTRICT = true, PREVENT = true }
  for _, e in ipairs(maps) do
    if type(e.mapSection) ~= "string" or e.mapSection == "" then
      Errors.raise("WORLD_MANIFEST_MAP_SECTION_INVALID", "map section is missing", { id = e.id })
    end
    if
      type(e.mapSectionNativeId) ~= "number"
      or e.mapSectionNativeId % 1 ~= 0
      or e.mapSectionNativeId < 0
      or e.mapSectionNativeId > 65535
    then
      Errors.raise(
        "WORLD_MANIFEST_MAP_SECTION_ID_INVALID",
        "map section native identity must be a u16 integer",
        { id = e.id, mapSectionNativeId = e.mapSectionNativeId }
      )
    end
    if FOLLOW_MODES[e.followMode] ~= true then
      Errors.raise(
        "WORLD_MANIFEST_FOLLOW_MODE_INVALID",
        "map follow mode must be ALLOW, HEIGHT_RESTRICT, or PREVENT",
        { id = e.id, followMode = e.followMode }
      )
    end
  end

  local bySymbol, byId = {}, {}
  for index, e in ipairs(maps) do
    if byId[e.id] then
      Errors.raise("WORLD_MANIFEST_DUP_ID", "duplicate map id " .. e.id, { id = e.id })
    end
    if bySymbol[e.symbol] then
      Errors.raise("WORLD_MANIFEST_DUP_SYMBOL", "duplicate map symbol " .. e.symbol, { symbol = e.symbol })
    end
    bySymbol[e.symbol] = e.id
    byId[e.id] = index
  end
  local excludedMaps = sortedById(excluded)
  local compileExcludedMaps = sortedById(compileExcluded)

  -- Every map header appears exactly once across the three collections.
  local seenIds, seenSymbols = {}, {}
  for _, list in ipairs({ excludedMaps, compileExcludedMaps }) do
    for _, record in ipairs(list) do
      assert(not byId[record.id], "excluded map id is renderable: " .. record.id)
      assert(not seenIds[record.id], "duplicate excluded map id " .. record.id)
      assert(not bySymbol[record.symbol], "excluded map symbol is renderable: " .. record.symbol)
      assert(not seenSymbols[record.symbol], "duplicate excluded map symbol " .. record.symbol)
      seenIds[record.id] = true
      seenSymbols[record.symbol] = true
    end
  end
  return {
    maps = maps,
    bySymbol = bySymbol,
    byId = byId,
    analysis = {
      mapHeaderCount = #maps + #excludedMaps + #compileExcludedMaps,
      renderableCount = #maps,
      excluded = excludedMaps,
      compileExcluded = compileExcludedMaps,
    },
  }
end

-- Stage the current manifest for the version's cache: build it, write it into
-- the disposable artifact stage, and prove it reads back as a manifest. The
-- live world.lua is untouched. Returns a handle with `version`, `publish()`
-- (swap the staged manifest over the live path through the shared publication
-- lifecycle, after which the caller must not abort), and `abort()` (discard
-- the disposable stage). A staging/validation failure discards the stage and
-- re-raises.
function WorldManifest.stage(cacheFs, entries, excluded, compileExcluded)
  local manifest = WorldManifest.build(entries, excluded, compileExcluded)
  local tx = ArtifactPublisher.begin(cacheFs, "world", { MapAssetCache.worldPath() })
  local ok, result = pcall(validateStagedManifest, tx, manifest)
  if not ok then
    tx:abort()
    error(result, 0)
  end
  return newStagedWorld(cacheFs.versionId, tx)
end

return WorldManifest
