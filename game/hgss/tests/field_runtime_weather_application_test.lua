-- Runtime weather tests exercise activation-time sampling and fog selection
-- through FieldRuntime methods without constructing a cache-backed session.

local Assert = require("tests.support.Assert")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local FieldWorldSwapCoordinator = require("game.hgss.src.field.FieldWorldSwapCoordinator")
local FieldWeatherCache = require("libs.assets.src.field.FieldWeatherCache")

local T = {}
local WEATHER_MAP = 999
local BASE_MAP = 1000

local function rampTable()
  local values = {}
  for i = 1, 32 do
    values[i] = (i - 1) * 4
  end
  return values
end

local function validCatalog()
  local presets = {}
  for id = 0, 13 do
    local enabled = id ~= 0 and id ~= 7
    presets[id] =
      { enabled = enabled, color = 0, offset = 0, slope = 0, alpha = enabled and 31 or 0, table = rampTable() }
  end
  return {
    schema = FieldWeatherCache.SCHEMA,
    presets = presets,
    rules = {
      {
        kind = "calendar_map_override",
        mapId = WEATHER_MAP,
        weatherId = 8,
        requireNoPenalty = true,
        dates = { { month = 1, day = 1 } },
      },
      { kind = "map_var_equals", mapId = BASE_MAP, varId = 0x4037, value = 0xF229, weatherId = 0 },
      { kind = "weather_flag_override", fromWeatherId = 9, flagId = 2420, weatherId = 0 },
      { kind = "weather_flag_override", fromWeatherId = 11, flagId = 2419, weatherId = 12 },
    },
  }
end

local function cameraProfile()
  return {
    projectionType = "perspective",
    distanceTiles = 10,
    angleXRaw = 4096,
    angleYRaw = 0,
    halfFovRadians = math.pi / 6,
    fullVerticalFovRadians = math.pi / 3,
    nearTiles = 0.1,
    farTiles = 100,
    targetOffsetTiles = { x = 0, y = 0, z = 0 },
  }
end

local function terrain()
  local plate = { id = 0 }
  return {
    candidatesAt = function()
      return { plate }
    end,
    contains = function(_, surfaceId)
      return surfaceId == 0
    end,
    plate = function(_, surfaceId)
      return surfaceId == 0 and plate or nil
    end,
    sample = function(_, surfaceId)
      return { worldY = 0, surfaceId = surfaceId }
    end,
    sampleHeight = function()
      return 0
    end,
  }
end

local function destinationMap(mapId, weatherId, fog)
  return {
    mapId = mapId,
    cameraType = "field",
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function()
        return true
      end,
    },
    terrain = terrain(),
    scene = { weatherId = weatherId, fog = fog },
    sceneRuntime = {},
  }
end

local function runtimeWithClock(catalog, calls, currentMap)
  local clock = {
    today = function()
      calls.today = calls.today + 1
      return { month = 1, day = 1 }
    end,
    hasPenalty = function()
      calls.penalty = calls.penalty + 1
      return false
    end,
  }
  local runtime = setmetatable({
    weatherCatalog = catalog,
    weatherClock = clock,
    eventState = FieldEventState.new(),
    runtimeMap = currentMap,
    cameraProfiles = { field = cameraProfile() },
    viewport = {
      worldAspect = function()
        return 4 / 3
      end,
    },
    zoom = {
      effectiveZoom = function()
        return 1
      end,
    },
    avatar = { spriteId = 1 },
    playerAvatar = {
      currentSpriteId = function()
        return 1
      end,
    },
    actors = {
      getAt = function()
        return nil
      end,
    },
    residency = {
      prepareTransition = function(_, runtimeMap)
        calls.prepareTransition = calls.prepareTransition + 1
        return { runtimeMap = runtimeMap }
      end,
      updatePrefetch = function() end,
    },
    scripts = {},
    session = { accumulator = 0, update = function() end, updateFixed = function() end },
    applicationHost = {
      error = function()
        return nil
      end,
    },
    transition = {
      error = nil,
      fadeAlpha = 1,
      consumeCompleted = function()
        return false
      end,
      updateSourceFrame = function() end,
      updateFixed = function() end,
    },
    screenFade = {
      fadeDone = function()
        return true
      end,
      updateSourceFrame = function() end,
    },
    fieldEntranceIndicator = { updateFixed = function() end },
  }, FieldRuntime)
  runtime.worldSwapCoordinator = FieldWorldSwapCoordinator.new(runtime)
  return runtime
end

function T.runtime_samples_weather_on_activation_and_selects_the_matching_fog()
  local catalog = validCatalog()
  local valid, err = FieldWeatherCache.validateCatalog(catalog)
  Assert.isTrue(valid, tostring(err))
  local calls = { today = 0, penalty = 0, prepareTransition = 0 }
  local runtime = runtimeWithClock(catalog, calls, destinationMap(1, 5, {}))
  local overrideMap = destinationMap(WEATHER_MAP, 5, {})
  local baseFog = { name = "compiled base fog" }
  local baseMap = destinationMap(BASE_MAP, 5, baseFog)
  local prepared =
    runtime:_prepareSwap({ destinationMap = overrideMap, fieldX = 0, fieldZ = 0, surfaceId = 0 }, "south")
  Assert.notNil(prepared)
  Assert.equal(calls.today, 1)
  Assert.equal(calls.penalty, 1)
  Assert.equal(overrideMap.effectiveWeatherId, 8)
  Assert.equal(overrideMap.sceneRuntime.fog, catalog.presets[8])
  Assert.equal(calls.prepareTransition, 1)
  runtime:update(1 / 30)
  runtime:update(1 / 30)
  runtime:update(1 / 30)
  Assert.equal(calls.today, 1, "ordinary updates must not resample the weather date")
  Assert.equal(calls.penalty, 1, "ordinary updates must not resample the penalty state")
  local preparedAgain =
    runtime:_prepareSwap({ destinationMap = baseMap, fieldX = 0, fieldZ = 0, surfaceId = 0 }, "south")
  Assert.notNil(preparedAgain)
  Assert.equal(calls.today, 2)
  Assert.equal(calls.penalty, 2)
  Assert.equal(baseMap.effectiveWeatherId, 5)
  Assert.equal(baseMap.sceneRuntime.fog, baseFog, "unchanged weather must preserve compiled base fog")
  Assert.equal(calls.prepareTransition, 2)
end

function T.live_assignment_updates_id_and_fog_without_activation_resolution()
  local catalog = validCatalog()
  local calls = { today = 0, penalty = 0, prepareTransition = 0 }
  local field = runtimeWithClock(catalog, calls, destinationMap(1, 11, {}))
  field:_setLiveWeather(field.runtimeMap, 12)
  Assert.equal(field.runtimeMap.effectiveWeatherId, 12)
  Assert.equal(field.runtimeMap.sceneRuntime.fog, catalog.presets[12])
  Assert.equal(calls.today, 0)
  Assert.equal(calls.penalty, 0)
end

function T.live_assignment_rejects_missing_catalog_entries_before_mutation()
  local catalog = validCatalog()
  local calls = { today = 0, penalty = 0, prepareTransition = 0 }
  local field = runtimeWithClock(catalog, calls, destinationMap(1, 11, {}))
  local previousFog = field.runtimeMap.sceneRuntime.fog
  field.runtimeMap.effectiveWeatherId = 11
  local ok = pcall(function()
    field:_setLiveWeather(field.runtimeMap, 14)
  end)
  Assert.isFalse(ok)
  Assert.equal(field.runtimeMap.effectiveWeatherId, 11)
  Assert.equal(field.runtimeMap.sceneRuntime.fog, previousFog)
end

return { tests = T, metadata = { tags = { "field", "weather" } } }
