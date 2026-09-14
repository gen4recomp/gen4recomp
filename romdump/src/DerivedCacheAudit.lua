-- Availability audit for the published derived cache. Without a generation
-- it checks completion markers only; dependency freshness remains the cache
-- builder's responsibility when a developer explicitly rebuilds, and
-- implementation freshness belongs to the producer fingerprint. With a
-- generation it additionally proves every expected receipt carries that
-- generation and passes its family validator, including every mon page
-- through the mon summary inventory and every cell through the published
-- index. Source-planned exclusions never appear here: the world manifest
-- lists only staged maps, so an excluded map is not a missing worker job.
-- A milestone marker alone is never accepted as proof of the entire
-- corpus. The attestation file itself is published only after this audit
-- passes, so it is never consulted here.

local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local AudioCache = require("libs.assets.src.audio.AudioCache")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local ScriptCache = require("libs.assets.src.ScriptCache")
local FieldCameraCache = require("libs.assets.src.field.FieldCameraCache")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local IntroAssetCache = require("libs.assets.src.newgame.IntroAssetCache")
local StarterChoiceAssetCache = require("libs.assets.src.StarterChoiceAssetCache")
local FieldWeatherCache = require("libs.assets.src.field.FieldWeatherCache")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local FieldEmoteAssetCache = require("libs.assets.src.field.FieldEmoteAssetCache")
local NewGameInitCache = require("libs.assets.src.newgame.NewGameInitCache")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local MonCache = require("libs.assets.src.MonCache")
local ItemCache = require("libs.assets.src.ItemCache")
local BagCache = require("libs.assets.src.BagCache")
local ArtifactState = require("romdump.src.build.ArtifactState")

local DerivedCacheAudit = {}

local REQUIRED_MARKERS = {
  FieldActorCache.markerPath(),
  MonCache.markerPath(),
  ItemCache.markerPath(),
  BagCache.markerPath(),
  AudioCache.markerPath(),
  FieldCameraCache.markerPath(),
  FieldFontCache.markerPath(),
  FieldMessageCache.markerPath(),
  FieldUiAssetCache.markerPath(),
  IntroAssetCache.markerPath(),
  StarterChoiceAssetCache.markerPath(),
  FieldWeatherCache.markerPath(),
  ScriptCache.markerPath(),
  FieldEffectAssetCache.markerPath(),
  FieldEmoteAssetCache.markerPath(),
  NewGameInitCache.markerPath(),
  FieldCellCache.indexMarkerPath(),
}

---@param cacheFs CacheFs
---@param generationId string
---@param kind string
---@param key string
---@param isReady fun(cacheFs: CacheFs, marker: string): boolean
---@return boolean
---@return string|nil
local function checkSummary(cacheFs, generationId, kind, key, isReady)
  local receipt, reason = ArtifactState.read(cacheFs, generationId, kind, key)
  if receipt == nil then
    return false, kind .. "/" .. key .. " has no current receipt: " .. tostring(reason)
  end
  if not isReady(cacheFs, receipt.marker) then
    return false, kind .. "/" .. key .. " fails its family validator"
  end
  return true
end

---@param cacheFs CacheFs
---@param generationId string|nil current generation when the whole corpus must be proved, nil for marker availability
---@return boolean, string|nil
function DerivedCacheAudit.isAvailable(cacheFs, generationId)
  assert(cacheFs and cacheFs.read and cacheFs.loadLua, "DerivedCacheAudit requires a CacheFs-shaped object")
  for _, path in ipairs(REQUIRED_MARKERS) do
    if cacheFs:read(path) == nil then
      return false, "missing completion marker " .. path
    end
  end

  local world = cacheFs:loadLua(MapAssetCache.worldPath())
  if type(world) ~= "table" or type(world.maps) ~= "table" then
    return false, "missing world manifest"
  end
  for _, map in ipairs(world.maps) do
    if type(map) ~= "table" or type(map.id) ~= "number" or map.id < 0 or map.id % 1 ~= 0 then
      return false, "world manifest has an invalid map entry"
    end
    if cacheFs:read(MapAssetCache.mapDir(map.id) .. "/complete") == nil then
      return false, "map " .. map.id .. " has no completion marker"
    end
    if cacheFs:read(FieldMapDataCache.markerPath(map.id)) == nil then
      return false, "field map " .. map.id .. " has no completion marker"
    end
  end
  if generationId == nil then
    return true
  end

  -- Generation-scoped proof over the published corpus: every expected
  -- receipt must carry this generation and pass its family validator. The
  -- attestation file itself is not consulted here; it is published only
  -- after this audit passes.
  local summaries = {
    { kind = "mon-summary", key = "global", isReady = MonCache.isReady },
    { kind = "message-summary", key = "global", isReady = FieldMessageCache.isReady },
    { kind = "audio-summary", key = "global", isReady = AudioCache.isReady },
    { kind = "script-summary", key = "global", isReady = ScriptCache.isReady },
  }
  for _, summary in ipairs(summaries) do
    local ok, reason = checkSummary(cacheFs, generationId, summary.kind, summary.key, summary.isReady)
    if not ok then
      return false, reason
    end
  end
  for _, map in ipairs(world.maps) do
    local mapReceipt, mapReason = ArtifactState.read(cacheFs, generationId, "map", tostring(map.id))
    if mapReceipt == nil then
      return false, "map " .. map.id .. " has no current receipt: " .. tostring(mapReason)
    end
    local dataReceipt, dataReason = ArtifactState.read(cacheFs, generationId, "map-data", tostring(map.id))
    if dataReceipt == nil then
      return false, "field map " .. map.id .. " has no current receipt: " .. tostring(dataReason)
    end
  end
  local indexReceipt, indexReason = ArtifactState.read(cacheFs, generationId, "field-cell-index", "global")
  if indexReceipt == nil then
    return false, "cell index has no current receipt: " .. tostring(indexReason)
  end
  local index = cacheFs:loadLua(FieldCellCache.indexPath())
  if index == nil then
    return false, "cell index is not published"
  end
  if not FieldCellCache.validateIndex(index) then
    return false, "cell index is not published"
  end
  local matrices = assert(index.matrices, "cell index carries no matrices")
  for _, matrix in ipairs(matrices) do
    for _, descriptor in ipairs(matrix.cells or {}) do
      local key = descriptor.matrixMemberId .. "-" .. descriptor.index
      local receipt, reason = ArtifactState.read(cacheFs, generationId, "field-cell", key)
      if receipt == nil then
        return false, "field cell " .. key .. " has no current receipt: " .. tostring(reason)
      end
      if not FieldCellCache.isCellReady(cacheFs, descriptor, receipt.marker) then
        return false, "field cell " .. key .. " fails its family validator"
      end
    end
  end
  return true
end

return DerivedCacheAudit
