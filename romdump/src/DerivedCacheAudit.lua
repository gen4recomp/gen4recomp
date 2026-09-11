-- Lightweight availability audit for the published derived cache. It checks
-- completion markers only; dependency freshness remains the cache builder's
-- responsibility when a developer explicitly rebuilds, and implementation
-- freshness belongs to the producer fingerprint.

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
  FieldCellCache.markerPath(),
}

---@param cacheFs CacheFs
---@return boolean, string|nil
function DerivedCacheAudit.isAvailable(cacheFs)
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
  return true
end

return DerivedCacheAudit
