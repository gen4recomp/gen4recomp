-- Production audio composition contract. The core and field paths use the
-- generated cache and the same non-rendering audio-output boundary.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    derivedAssets = { "field-core", "map:7" },
    tags = { "audio", "composition" },
  },
  tests = {},
}

local function loadCore()
  local ok, core = pcall(require, "game.hgss.src.audio.GameAudio")
  Assert.isTrue(ok, "shared audio core composition is unavailable; non-field game states cannot own GameSound")
  Assert.isTrue(type(core) == "table" and type(core.compose) == "function", "audio core must expose compose")
  return core
end

local function runFrames(core, output, limit)
  for _ = 1, limit do
    core.sound:updateSoundFrame()
    core.sink:update()
    if output:anyNonSilent() then
      return
    end
  end
end

function T.tests.core_and_field_audio_share_the_production_stack()
  local versionId = AcceptanceHarness.defaultVersion()
  local harness = AcceptanceHarness.new()
  local fieldOutput = FakeAudioOutput.new()
  local coreOutput = FakeAudioOutput.new()
  local game = harness:boot({
    versionId = versionId,
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
    fieldOptions = {
      audioHost = "production",
      audioOutput = fieldOutput,
      dayNight = function()
        return "day"
      end,
    },
  })
  local core
  local ok, err = xpcall(function()
    local GameAudio = loadCore()
    core = GameAudio.compose({
      cacheFs = game.runtime.cacheFs,
      outputRate = 32768,
      outputHost = { audio = coreOutput.audio, sound = coreOutput.sound },
    })
    Assert.notNil(core.sound, "core composition must provide GameSound")
    Assert.notNil(core.renderer, "core composition must provide the shared audio renderer")
    Assert.notNil(core.sink, "core composition must provide the optional output sink when requested")

    core.sound:playMusic("SEQ_GS_T_WAKABA")
    core.sound:play("SEQ_SE_DP_SELECT")
    core.sound:playFanfare("SEQ_ME_ITEM")
    runFrames(core, coreOutput, 240)
    Assert.isTrue(coreOutput:anyNonSilent(), "the shared core must render music/effect/fanfare PCM")

    game:advanceUntil("field audio reaches the output host", function()
      return fieldOutput:anyNonSilent()
    end, 120)
    Assert.notNil(game.runtime.audio, "field audio must retain its field-policy service")
    Assert.equal(game:renderAttempts(), 0, "audio acceptance must stop before GPU rendering")
  end, debug.traceback)
  if core and core.sink then
    core.sink:release()
  end
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
