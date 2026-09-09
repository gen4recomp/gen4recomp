-- FieldRuntime scheduling coverage uses recording collaborators at the
-- coordinator boundary, without constructing a cache-backed field session.

local Assert = require("tests.support.Assert")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local FieldSession = require("libs.hgss.src.field.FieldSession")
local PlayTime = require("libs.hgss.src.save.PlayTime")

local T = {
  metadata = {
    tags = { "field", "transition", "scheduler" },
  },
  tests = {},
}

-- The production script screen-fade controller is always composed and
-- advances from the same post-field source-frame stage as the ordinary
-- transition fade; this fake records its own call marker so tests can prove
-- its timeline is identical regardless of audio composition.
local function screenFadeFake(calls)
  return {
    fadeDone = function()
      return true
    end,
    updateSourceFrame = function()
      calls[#calls + 1] = "screen_fade"
    end,
  }
end

local function runtimeWithAudio(calls, options)
  options = options or {}
  local transition = {
    phase = "idle",
    error = nil,
    updateSourceFrame = function()
      calls[#calls + 1] = "presentation"
    end,
    consumeCompleted = function() end,
  }
  local audio = {
    updateSoundFrame = function()
      calls[#calls + 1] = "audio"
    end,
  }
  local runtime = setmetatable({
    audio = audio,
    audioSink = options.audioSink,
    session = {
      accumulator = options.accumulator == nil and FieldSession.FIXED_DT - 1 / 60 or options.accumulator,
      updateFixed = function()
        calls[#calls + 1] = "field"
        transition.phase = "fade_out"
      end,
    },
    transition = transition,
    screenFade = screenFadeFake(calls),
    scripts = {},
    applicationHost = {
      error = function()
        return nil
      end,
    },
  }, FieldRuntime)
  return runtime
end

local function runtimeWithoutAudio(calls)
  local transition = {
    phase = "idle",
    error = nil,
    updateSourceFrame = function()
      calls[#calls + 1] = "presentation"
    end,
    consumeCompleted = function() end,
  }
  local runtime = setmetatable({
    session = {
      accumulator = FieldSession.FIXED_DT - 1 / 60,
      updateFixed = function()
        calls[#calls + 1] = "field"
        transition.phase = "fade_out"
      end,
    },
    transition = transition,
    screenFade = screenFadeFake(calls),
    scripts = {},
    applicationHost = {
      error = function()
        return nil
      end,
    },
  }, FieldRuntime)
  return runtime
end

local function runtimeForSemanticCatchUp(counters)
  local playTime = PlayTime.new(0.9)
  playTime:start()
  return setmetatable({
    audio = {
      updateSoundFrame = function()
        counters.audio = counters.audio + 1
      end,
    },
    playTime = playTime,
    session = {
      accumulator = 0,
      updateFixed = function()
        counters.field = counters.field + 1
      end,
    },
    transition = {
      phase = "idle",
      error = nil,
      updateSourceFrame = function()
        counters.presentation = counters.presentation + 1
      end,
      consumeCompleted = function() end,
    },
    screenFade = {
      fadeDone = function()
        return true
      end,
      updateSourceFrame = function()
        counters.screenFade = counters.screenFade + 1
      end,
    },
    scripts = {},
    applicationHost = {
      error = function()
        return nil
      end,
    },
  }, FieldRuntime)
end

function T.tests.large_host_delta_is_bounded_to_fixed_source_frames()
  local counters = { field = 0, presentation = 0, screenFade = 0, audio = 0 }
  local runtime = runtimeForSemanticCatchUp(counters)

  runtime:update(10)

  Assert.equal(counters.field, FieldSession.MAX_CATCH_UP_TICKS)
  Assert.equal(counters.presentation, FieldSession.MAX_CATCH_UP_TICKS)
  Assert.equal(counters.screenFade, FieldSession.MAX_CATCH_UP_TICKS)
  Assert.equal(counters.audio, FieldSession.MAX_CATCH_UP_TICKS)
  Assert.equal(runtime.playTime:seconds(), 1)
  Assert.isTrue(runtime.session.accumulator < FieldSession.FIXED_DT)
end

function T.tests.discarded_host_lag_is_not_replayed_on_the_next_update()
  local counters = { field = 0, presentation = 0, screenFade = 0, audio = 0 }
  local runtime = runtimeForSemanticCatchUp(counters)

  runtime:update(10)
  counters.field = 0
  counters.presentation = 0
  counters.screenFade = 0
  counters.audio = 0

  runtime:update(1 / 60)

  Assert.equal(counters.field, 0)
  Assert.equal(counters.presentation, 0)
  Assert.equal(counters.screenFade, 0)
  Assert.equal(counters.audio, 0)
  Assert.isTrue(runtime.session.accumulator < FieldSession.FIXED_DT)
end

function T.tests.transition_start_receives_post_field_source_frame()
  local calls = {}
  local runtime = runtimeWithoutAudio(calls)

  runtime:update(1 / 60)
  Assert.deepEqual(calls, { "field", "presentation", "screen_fade" })
  Assert.equal(runtime.transition.phase, "fade_out")

  runtime:update(1 / 60)
  Assert.deepEqual(calls, { "field", "presentation", "screen_fade" })
end

function T.tests.audio_follows_post_field_presentation_stage()
  local calls = {}
  local runtime = runtimeWithAudio(calls)

  runtime:update(1 / 60)
  Assert.deepEqual(
    calls,
    { "field", "presentation", "screen_fade", "audio" },
    "post-field source-frame stages must run in source order"
  )

  runtime:update(1 / 60)
  Assert.deepEqual(calls, { "field", "presentation", "screen_fade", "audio" })
end

function T.tests.semantic_audio_tracks_field_ticks_while_sink_tracks_host_updates()
  local combinedCalls = {}
  local combinedSinkUpdates = 0
  local combined = runtimeWithAudio(combinedCalls, {
    accumulator = 0,
    audioSink = {
      update = function()
        combinedSinkUpdates = combinedSinkUpdates + 1
      end,
    },
  })
  local splitCalls = {}
  local splitSinkUpdates = 0
  local split = runtimeWithAudio(splitCalls, {
    accumulator = 0,
    audioSink = {
      update = function()
        splitSinkUpdates = splitSinkUpdates + 1
      end,
    },
  })

  combined:update(2 * FieldSession.FIXED_DT)
  split:update(FieldSession.FIXED_DT)
  split:update(FieldSession.FIXED_DT)

  Assert.deepEqual(combinedCalls, splitCalls, "dt chunking must not change semantic audio state")
  Assert.deepEqual(combinedCalls, {
    "field",
    "presentation",
    "screen_fade",
    "audio",
    "field",
    "presentation",
    "screen_fade",
    "audio",
  })
  Assert.equal(combinedSinkUpdates, 1, "the output sink pumps once for the combined host update")
  Assert.equal(splitSinkUpdates, 2, "the output sink still follows host update calls")
end

-- The script screen-fade source-frame cadence must not depend on whether an
-- audio service is composed: strip the interleaved "audio" markers from the
-- audio-present run and the two timelines must be identical.
function T.tests.screen_fade_source_frame_timeline_is_identical_with_and_without_audio()
  local withAudioCalls = {}
  local withoutAudioCalls = {}
  local withAudio = runtimeWithAudio(withAudioCalls)
  local withoutAudio = runtimeWithoutAudio(withoutAudioCalls)

  for _ = 1, 4 do
    withAudio:update(1 / 60)
    withoutAudio:update(1 / 60)
  end

  local filteredWithAudio = {}
  for _, call in ipairs(withAudioCalls) do
    if call ~= "audio" then
      filteredWithAudio[#filteredWithAudio + 1] = call
    end
  end
  Assert.deepEqual(
    filteredWithAudio,
    withoutAudioCalls,
    "the screen-fade/transition presentation timeline must not depend on audio composition"
  )
end

function T.tests.zero_delta_does_not_advance_any_clock()
  local calls = {}
  local runtime = setmetatable({
    session = {
      accumulator = 0,
      updateFixed = function()
        calls[#calls + 1] = "field"
      end,
    },
    transition = {
      phase = "idle",
      error = nil,
      updateSourceFrame = function()
        calls[#calls + 1] = "presentation"
      end,
      consumeCompleted = function() end,
    },
    screenFade = screenFadeFake(calls),
    scripts = {},
    applicationHost = {
      error = function()
        return nil
      end,
    },
  }, FieldRuntime)

  runtime:update(0)
  Assert.deepEqual(calls, {})
  Assert.equal(runtime.session.accumulator, 0)
end

-- The fixed-tick composition drives the follower controller with no
-- presentation policy: stationary animation is owned by the actor visuals,
-- so the coordinator passes no idle-presentation option at all, regardless
-- of dialogue state. A missing dialogue controller changes nothing.
local function runtimeWithFollowerPresentation(updateOptions, modal)
  local runtime = setmetatable({
    session = {
      accumulator = 0,
      updateFixed = function() end,
    },
    transition = {
      phase = "idle",
      error = nil,
      updateSourceFrame = function() end,
      consumeCompleted = function() end,
    },
    screenFade = {
      fadeDone = function()
        return true
      end,
      updateSourceFrame = function() end,
    },
    scripts = {},
    applicationHost = {
      error = function()
        return nil
      end,
    },
    followingMon = {
      update = function(_, options)
        updateOptions.calls = updateOptions.calls + 1
        updateOptions.last = options
        updateOptions.seenNil = updateOptions.seenNil or options == nil
      end,
    },
    dialogue = modal == nil and nil or {
      isModal = function()
        return modal
      end,
    },
  }, FieldRuntime)
  return runtime
end

function T.tests.follower_update_carries_no_presentation_policy()
  local openOptions = { calls = 0 }
  runtimeWithFollowerPresentation(openOptions, false):update(FieldSession.FIXED_DT)
  Assert.equal(openOptions.calls, 1, "an open field still ticks the follower once")
  Assert.isNil(openOptions.last, "the follower update carries no presentation option on an open field")

  local modalOptions = { calls = 0 }
  runtimeWithFollowerPresentation(modalOptions, true):update(FieldSession.FIXED_DT)
  Assert.equal(modalOptions.calls, 1, "modal dialogue still ticks the follower once")
  Assert.isNil(modalOptions.last, "modal dialogue adds no presentation option to the follower update")

  local missingOptions = { calls = 0 }
  runtimeWithFollowerPresentation(missingOptions, nil):update(FieldSession.FIXED_DT)
  Assert.equal(missingOptions.calls, 1, "a missing dialogue controller still ticks the follower once")
  Assert.isNil(missingOptions.last, "a missing dialogue controller adds no presentation option")
end

return T
