-- FieldRuntime adapts the injectable local civil clock independently for
-- weather dates and map-music day/night policy.

local Assert = require("tests.support.Assert")
local FieldAudio = require("game.hgss.src.audio.FieldAudio")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local LocalClock = require("game.src.LocalClock")

local T = { tests = {} }

function T.tests.weather_and_map_music_use_the_injected_local_clock()
  local originalLoad = FieldRuntime._load
  local originalCompose = FieldAudio.compose
  local originalDate = os.date
  local calls = 0
  local composition
  local clock = LocalClock.new(function()
    calls = calls + 1
    return { year = 2024, month = 2, day = 29, hour = 12, minute = 34, second = 56 }
  end)

  FieldRuntime._load = function() end
  FieldAudio.compose = function(options)
    composition = options
    return {
      service = { enterMap = function() end },
      sink = nil,
    }
  end
  os.date = function()
    error("FieldRuntime must not read os.date directly")
  end

  local ok, err = xpcall(function()
    local runtime = FieldRuntime.new({
      saveId = "test-save",
      versionId = "heartgold",
      location = { mapSymbol = "MAP_NEW_BARK_ELMS_LAB_1F", fieldX = 6, fieldZ = 6, facing = "south" },
      playerData = {
        profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
        options = { textSpeed = "mid", textFrame = 0 },
      },
      worldState = {
        serialize = function()
          return {}
        end,
      },
    }, { localClock = clock })
    Assert.deepEqual(runtime.weatherClock:today(), { month = 2, day = 29 })
    runtime:_composeAudio({
      loadLua = function()
        return {}
      end,
    }, nil)
    Assert.equal(composition.dayNight(), "day")
    Assert.equal(calls, 2, "weather and map music each sample the shared clock boundary")
  end, debug.traceback)

  FieldRuntime._load = originalLoad
  FieldAudio.compose = originalCompose
  os.date = originalDate
  if not ok then
    error(err, 0)
  end
end

return T
