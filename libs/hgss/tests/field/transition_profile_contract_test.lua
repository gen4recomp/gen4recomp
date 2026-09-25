-- Pure transition-profile contracts. These fixtures isolate source-selected
-- door audio and the asymmetric HGSS door movement from ROM loading.

local Assert = require("tests.support.Assert")
local FieldTransition = require("libs.hgss.src.transition.FieldTransition")
local FieldTransitionProfile = require("libs.hgss.src.transition.FieldTransitionProfile")

local T = { tests = {} }

local function step(transition)
  local moved = transition:updateFixed()
  transition:updateSourceFrame()
  return moved
end

local function advanceTo(transition, phase, maxTicks)
  for _ = 1, maxTicks do
    if transition.phase == phase then
      return
    end
    step(transition)
  end
  Assert.equal(transition.phase, phase)
end

-- Environment-selected profiles use the generated semantic map matrix,
-- including an explicit failure for unsupported pairs.
function T.tests.environment_selection_matches_hgss_matrix()
  local expected = {
    { "cave", "cave", 6 },
    { "cave", "outdoors", 5 },
    { "cave", "building", 6 },
    { "outdoors", "cave", 4 },
    { "outdoors", "building", 6 },
    { "building", "building", 6 },
    { "building", "cave", 0 },
    { "building", "outdoors", 0 },
  }
  for _, pair in ipairs(expected) do
    Assert.equal(FieldTransitionProfile.selectEnvironment(pair[1], pair[2]), pair[3])
  end

  Assert.throws(function()
    FieldTransitionProfile.selectEnvironment("outdoors", "outdoors")
  end, "outdoors-to-outdoors must fail instead of defaulting to a profile")
end

function T.tests.vertical_profiles_return_from_staging_before_the_final_step()
  for _, profile in ipairs({ 7, 8 }) do
    local events = {}
    local stagedY
    local player = {
      motion = "idle",
      beginTransitionVerticalReturn = function(self, anchorY)
        events[#events + 1] = { "return", anchorY }
        self.motion = "transition"
        return true
      end,
      beginTransitionLadderExit = function(self)
        self.motion = "transition"
        return true
      end,
      beginTransitionLadderDownExit = function(self)
        self.motion = "transition"
        return true
      end,
      beginTransitionStep = function(self, direction)
        events[#events + 1] = { "step", direction }
        self.motion = "walking"
        return true
      end,
      updateFixed = function(self)
        self.motion = "idle"
        return true
      end,
    }
    local transition = FieldTransition.new({
      loader = {
        requestWarp = function()
          return true
        end,
      },
      player = player,
      resolveDestination = function()
        return {
          destinationMap = { mapId = 60 },
          destinationWarp = { x = 4, z = 4 },
          fieldX = 4,
          fieldZ = 4,
          surfaceId = 0,
          worldY = 10,
        }
      end,
      prepare = function(result)
        stagedY = result.worldY
        return result
      end,
      commit = function() end,
    })
    transition:start({ mapId = 61 }, {
      warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
      transition = { mode = "fixed", profile = profile },
    }, "south")
    advanceTo(transition, FieldTransition.PHASES.idle, 128)
    local expectedDirection = profile == 7 and "north" or "south"
    Assert.equal(stagedY, profile == 7 and 8 or 12)
    Assert.deepEqual(events, { { "return", 10 }, { "step", expectedDirection } })
  end
end

local function eventIndex(events, expected)
  for index, event in ipairs(events) do
    if event == expected then
      return index
    end
  end
  return nil
end

function T.tests.escalator_source_lifecycle_orders_effects_and_pause_ownership()
  local events = {}
  local stepCount = 0
  local propPlayCount = 0
  local sourcePropPolls = 0
  local prop = {
    play = function(self, animation)
      events[#events + 1] = "prop:" .. animation
      propPlayCount = propPlayCount + 1
      if propPlayCount == 1 then
        sourcePropPolls = 0
      end
      self.finished = false
    end,
    isFinished = function(_)
      if propPlayCount == 1 then
        sourcePropPolls = sourcePropPolls + 1
        return sourcePropPolls >= 3
      end
      return true
    end,
  }
  local player = {
    motion = "idle",
    animationPaused = false,
    pauseTransitionAnimation = function(self)
      events[#events + 1] = "pause"
      self.animationPaused = true
    end,
    resumeTransitionAnimation = function(self)
      events[#events + 1] = "resume"
      self.animationPaused = false
    end,
    beginTransitionStep = function(self, facing)
      events[#events + 1] = "horizontal:" .. facing
      self.motion = "walking"
      stepCount = 0
      return true
    end,
    updateFixed = function(self)
      stepCount = stepCount + 1
      if stepCount >= 2 then
        self.motion = "idle"
      end
      return true
    end,
  }
  local transition = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    player = player,
    escalatorAt = function()
      return prop
    end,
    playSound = function(sound)
      events[#events + 1] = "sound:" .. sound
    end,
    stopSound = function(sound)
      events[#events + 1] = "stop:" .. sound
    end,
    resolveDestination = function()
      events[#events + 1] = "resolve"
      return {
        destinationMap = { mapId = 60 },
        fieldX = 4,
        fieldZ = 4,
        surfaceId = 0,
        worldY = 0,
      }
    end,
    prepare = function(result)
      events[#events + 1] = "prepare"
      return result
    end,
    commit = function()
      events[#events + 1] = "commit"
    end,
  })
  transition:start({ mapId = 61 }, {
    warp = { index = 0, destinationMapId = 60, destinationWarpId = 0, x = 4, z = 4 },
    transition = { mode = "fixed", profile = FieldTransitionProfile.ESCALATOR },
  }, "east")
  Assert.deepEqual(events, {
    "prop:escalator",
    "pause",
    "horizontal:east",
    "sound:SEQ_SE_DP_ESUKA",
  })
  Assert.isTrue(player.animationPaused)
  Assert.isFalse(transition.fadeStarted)
  local sourceFrameStoppedBeforeMotion = not transition:updateSourceFrame()
  local coefficientStayedAtZero = transition:presentationStatus().coefficient == 0

  transition:updateFixed()
  Assert.equal(player.motion, "walking")
  Assert.isTrue(transition.fadeStarted)
  Assert.isTrue(transition:updateSourceFrame())
  Assert.isTrue(transition:presentationStatus().coefficient > 0)
  transition:updateFixed()
  Assert.equal(player.motion, "idle")

  while not transition.fade:status().completed do
    Assert.isTrue(transition:updateSourceFrame())
  end
  Assert.isTrue(transition.fade:status().completed)
  transition:updateFixed()
  Assert.equal(transition.phase, FieldTransition.PHASES.fade_out)
  Assert.isTrue(player.animationPaused)
  Assert.isNil(eventIndex(events, "stop:SEQ_SE_DP_ESUKA"))

  transition:updateFixed()
  Assert.equal(transition.phase, FieldTransition.PHASES.load_destination)
  Assert.isFalse(player.animationPaused)
  local sourceStopBeforeResolve = eventIndex(events, "stop:SEQ_SE_DP_ESUKA")

  transition:updateFixed()
  Assert.equal(transition.phase, FieldTransition.PHASES.swap_map)
  transition:updateFixed()
  Assert.equal(transition.phase, FieldTransition.PHASES.fade_in)

  advanceTo(transition, FieldTransition.PHASES.idle, 128)
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(player.animationPaused)
  Assert.isTrue(sourceFrameStoppedBeforeMotion, "source frames must not advance before source motion")
  Assert.isTrue(coefficientStayedAtZero, "source fade coefficient must remain zero before source motion")
  Assert.notNil(sourceStopBeforeResolve, "source sound must stop before destination resolution")
  Assert.equal(eventIndex(events, "sound:SEQ_SE_DP_ESUKA"), 4)
  Assert.equal(eventIndex(events, "stop:SEQ_SE_DP_ESUKA"), eventIndex(events, "resume") + 1)
  Assert.isTrue(
    sourceStopBeforeResolve < eventIndex(events, "resolve"),
    "source sound must stop before destination resolution"
  )
  Assert.isTrue(eventIndex(events, "resume") < eventIndex(events, "resolve"))
  Assert.isTrue(eventIndex(events, "stop:SEQ_SE_DP_ESUKA") < eventIndex(events, "resolve"))
end

function T.tests.escalator_step_failure_releases_owned_animation_pause()
  local player = {
    motion = "idle",
    animationPaused = false,
    pauseTransitionAnimation = function(self)
      self.animationPaused = true
    end,
    resumeTransitionAnimation = function(self)
      self.animationPaused = false
    end,
    beginTransitionStep = function()
      return false
    end,
  }
  local transition = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    player = player,
    escalatorAt = function()
      return {
        play = function() end,
        isFinished = function()
          return true
        end,
      }
    end,
    playSound = function() end,
    stopSound = function() end,
    resolveDestination = function()
      return { destinationMap = { mapId = 60 }, fieldX = 0, fieldZ = 0, surfaceId = 0, worldY = 0 }
    end,
    prepare = function(result)
      return result
    end,
    commit = function() end,
  })

  local err = Assert.throws(function()
    transition:start({ mapId = 61 }, {
      warp = { index = 0, destinationMapId = 60, destinationWarpId = 0, x = 4, z = 4 },
      transition = { mode = "fixed", profile = FieldTransitionProfile.ESCALATOR },
    }, "east")
  end)
  Assert.isTrue(string.find(tostring(err), "escalator transition step could not start", 1, true) ~= nil)
  Assert.equal(transition.phase, FieldTransition.PHASES.idle)
  Assert.isFalse(transition.locked)
  Assert.equal(transition.error, err)
  Assert.isFalse(player.animationPaused)
  Assert.isFalse(transition:updateSourceFrame())
end

T.tests.transition_profiles_preserve_source_semantics = function()
  Assert.equal(FieldTransitionProfile.fixed(1).profile, 1)
  Assert.equal(FieldTransitionProfile.fixed(3).profile, 3)
  Assert.equal(FieldTransitionProfile.selectEnvironment("building", "building"), 6)
  Assert.equal(FieldTransitionProfile.selectEnvironment("building", "outdoors"), 0)
end

function T.tests.all_fixed_profiles_are_explicit_and_panel_has_no_numeric_profile()
  for profile = 0, 8 do
    Assert.equal(FieldTransitionProfile.fixed(profile).profile, profile)
  end
  Assert.throws(function()
    FieldTransitionProfile.fixed(-1)
  end, "negative transition profiles are invalid")
  Assert.throws(function()
    FieldTransitionProfile.fixed(9)
  end, "unknown transition profiles are invalid")

  local transition = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    prepare = function() end,
    commit = function() end,
  })
  transition:start(
    { mapId = 61 },
    { warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 }, transition = { mode = "panel" } },
    "north"
  )
  Assert.isNil(transition.profileId)
  Assert.equal(transition.transitionMode, FieldTransitionProfile.MODE_PANEL)
end

function T.tests.ordinary_profiles_share_source_exit_audio_and_fade()
  local observations = {}
  for _, profile in ipairs({ FieldTransitionProfile.ORDINARY, FieldTransitionProfile.ORDINARY_INDOOR }) do
    local sounds = {}
    local transition = FieldTransition.new({
      loader = {
        requestWarp = function()
          return true
        end,
      },
      prepare = function() end,
      commit = function() end,
      playSound = function(sound)
        sounds[#sounds + 1] = sound
      end,
    })
    transition:start({ mapId = 61 }, {
      warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
      transition = { mode = "fixed", profile = profile },
    }, "north")
    observations[#observations + 1] = {
      profile = profile,
      sounds = sounds,
      fade = transition.fade:status(),
    }
    Assert.isTrue(transition:updateSourceFrame(), "ordinary source fade advances at start")
  end

  Assert.deepEqual(observations[1].sounds, { "SEQ_SE_DP_KAIDAN2" }, "profile 0 source exit audio")
  Assert.deepEqual(observations[2].sounds, observations[1].sounds, "profile 6 shares profile 0 source exit audio")
  Assert.equal(observations[2].fade.coefficient, observations[1].fade.coefficient)
end

local function ladderSourceFixture(profile)
  local sounds = {}
  local updates = 0
  local player = {
    motion = "idle",
    beginTransitionLadderExit = function(self)
      self.motion = "transition"
      return true
    end,
    beginTransitionLadderDownExit = function(self)
      self.motion = "transition"
      return true
    end,
    updateFixed = function(self)
      updates = updates + 1
      if updates == 16 then
        self.motion = "idle"
      end
      return true
    end,
  }
  local transition = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    player = player,
    resolveDestination = function()
      return {
        destinationMap = { mapId = 60 },
        fieldX = 4,
        fieldZ = 4,
        surfaceId = 0,
        worldY = 0,
      }
    end,
    prepare = function(result)
      return result
    end,
    commit = function() end,
    playSound = function(sound)
      sounds[#sounds + 1] = sound
    end,
  })
  transition:start({ mapId = 61 }, {
    warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
    transition = { mode = "fixed", profile = profile },
  }, "north")
  return transition, player, sounds
end

function T.tests.ladder_source_motion_finishes_before_sound_and_fade()
  for _, profile in ipairs({ FieldTransitionProfile.LADDER, FieldTransitionProfile.LADDER_DOWN }) do
    local transition, player, sounds = ladderSourceFixture(profile)
    Assert.equal(player.motion, "transition")
    Assert.deepEqual(sounds, {})
    Assert.isFalse(transition:updateSourceFrame())
    Assert.equal(transition:presentationStatus().coefficient, 0)

    for _ = 1, 15 do
      transition:updateFixed()
      Assert.equal(player.motion, "transition")
      Assert.deepEqual(sounds, {})
      Assert.isFalse(transition:updateSourceFrame())
      Assert.equal(transition:presentationStatus().coefficient, 0)
    end

    transition:updateFixed()
    Assert.equal(player.motion, "idle")
    Assert.deepEqual(sounds, { "SEQ_SE_DP_KAIDAN2" })
    Assert.equal(transition:presentationStatus().coefficient, 0)
    Assert.isTrue(transition:updateSourceFrame())
    Assert.equal(transition:presentationStatus().coefficient, 2)
  end
end

function T.tests.ordinary_profile_exit_audio_is_played_once()
  local sounds = {}
  local transition = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    resolveDestination = function()
      return { destinationMap = { mapId = 60 }, fieldX = 0, fieldZ = 0, surfaceId = 0, worldY = 0 }
    end,
    prepare = function() end,
    commit = function() end,
    playSound = function(sound)
      sounds[#sounds + 1] = sound
    end,
  })
  transition:start({ mapId = 61 }, {
    warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
    transition = { mode = "fixed", profile = FieldTransitionProfile.ORDINARY },
  }, "north")
  advanceTo(transition, "idle", 128)
  Assert.equal(transition.phase, "idle")
  Assert.deepEqual(sounds, { "SEQ_SE_DP_KAIDAN2" })
end

function T.tests.transition_motion_profiles_require_the_player_motion_contract()
  local transition = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    prepare = function() end,
    commit = function() end,
  })
  Assert.throws(function()
    transition:start({ mapId = 61 }, {
      warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
      transition = { mode = "fixed", profile = FieldTransitionProfile.ESCALATOR },
    }, "south")
  end, "transition movement profiles require semantic player motion")
end

function T.tests.field_transition_consumes_trigger_profile_before_ownership()
  local metadataCalls = 0
  local loader = {
    transitionEnvironment = function(_, mapId)
      metadataCalls = metadataCalls + 1
      Assert.equal(mapId, 60)
      return "building"
    end,
    load = function()
      error("profile selection must not load a destination map", 0)
    end,
    requestWarp = function()
      return true
    end,
  }
  local transition = FieldTransition.new({
    loader = loader,
    resolveDestination = function()
      return {
        destinationMap = { mapId = 60 },
        fieldX = 0,
        fieldZ = 0,
        surfaceId = 0,
        worldY = 0,
      }
    end,
    prepare = function() end,
    commit = function() end,
  })

  transition:start({ mapId = 61, fieldData = { transitionEnvironment = "outdoors" } }, {
    warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
    transition = { mode = "environment" },
  }, "east")
  Assert.equal(transition.profileId, 6)
  Assert.equal(metadataCalls, 1)
  Assert.isTrue(transition.locked)
end

function T.tests.field_transition_rejects_unsupported_environment_before_lock()
  local transition = FieldTransition.new({
    loader = {
      transitionEnvironment = function()
        return "outdoors"
      end,
      requestWarp = function()
        return true
      end,
    },
    prepare = function() end,
    commit = function() end,
  })

  local ok, err = pcall(function()
    transition:start({ mapId = 61, fieldData = { transitionEnvironment = "outdoors" } }, {
      warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
      transition = { mode = "environment" },
    }, "east")
  end)
  Assert.isFalse(ok)
  if type(err) ~= "table" then
    error("expected a structured transition profile error")
  end
  Assert.equal(err.code, "MAP_TRANSITION_PROFILE_UNSUPPORTED")
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
end

function T.tests.field_transition_uses_trigger_destination_facing()
  local receivedFacing
  local player = {
    motion = "idle",
    pauseTransitionAnimation = function() end,
    resumeTransitionAnimation = function() end,
    beginTransitionStep = function(self, facing)
      self.motion = "idle"
      self.facing = facing
      return true
    end,
    updateFixed = function() end,
  }
  local transition = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    resolveDestination = function()
      return { destinationMap = { mapId = 60 }, fieldX = 0, fieldZ = 0, surfaceId = 0, worldY = 0 }
    end,
    prepare = function(_, facing)
      receivedFacing = facing
    end,
    commit = function() end,
    player = player,
    escalatorAt = function()
      return {
        play = function() end,
        isFinished = function()
          return true
        end,
      }
    end,
  })
  transition:start({ mapId = 61 }, {
    warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
    transition = { mode = "fixed", profile = FieldTransitionProfile.ESCALATOR },
    destinationFacing = "west",
  }, "east")
  advanceTo(transition, "swap_map", 10)
  Assert.equal(receivedFacing, "west")
end

local function runTransition(options)
  local source = { mapId = 61 }
  local destination = { mapId = 60 }
  local player = options.player
    or {
      motion = "idle",
      scriptedStep = function()
        return true
      end,
      updateFixed = function() end,
    }
  local transition = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    resolveDestination = function()
      return {
        destinationMap = destination,
        destinationWarp = { x = 4, z = 14 },
        fieldX = 4,
        fieldZ = 13,
        surfaceId = 0,
        worldY = 0,
      }
    end,
    prepare = function() end,
    commit = function() end,
    doorAt = function(map)
      if map == source then
        if options.doorAt then
          return options.doorAt()
        end
        return options.sourceDoor
      end
      return options.destinationDoor or (options.doorAt and options.doorAt())
    end,
    playSound = options.playSound,
    player = player,
  })
  transition:start(source, {
    kind = "door",
    warp = { index = 0, x = 684, z = 393, destinationMapId = 60, destinationWarpId = 0 },
    destinationFacing = options.destinationFacing,
  }, "north")
  advanceTo(transition, "idle", 128)
  Assert.equal(transition.phase, "idle", "the pure transition fixture must complete")
end

local function instantDoor(soundType)
  local open = {
    [1] = "SEQ_SE_DP_DOOR_OPEN",
    [2] = "SEQ_SE_DP_DOOR10",
    [3] = "SEQ_SE_PL_DOOR_OPEN5",
    [4] = "SEQ_SE_GS_HIKIDO_OPEN",
  }
  local close = {
    [1] = "SEQ_SE_DP_DOOR_CLOSE2",
    [2] = nil,
    [3] = nil,
    [4] = "SEQ_SE_GS_HIKIDO_CLOSE",
  }
  return {
    soundType = soundType,
    open = function()
      return open[soundType]
    end,
    close = function()
      return close[soundType]
    end,
    isFinished = function()
      return true
    end,
  }
end

function T.tests.door_audio_comes_only_from_door_operations()
  local sounds = {}
  local door = {
    soundType = 1,
    open = function()
      return "SEQ_FROM_OPEN"
    end,
    close = function()
      return nil
    end,
    isFinished = function()
      return true
    end,
  }
  runTransition({
    doorAt = function()
      return door
    end,
    playSound = function(sound)
      sounds[#sounds + 1] = sound
    end,
  })
  Assert.deepEqual(sounds, { "SEQ_FROM_OPEN" })
end

function T.tests.door_sound_selector_emits_exact_open_and_close_sequences()
  local expected = {
    [1] = { "SEQ_SE_DP_DOOR_OPEN", "SEQ_SE_DP_DOOR_CLOSE2" },
    [2] = { "SEQ_SE_DP_DOOR10" },
    [3] = { "SEQ_SE_PL_DOOR_OPEN5" },
    [4] = { "SEQ_SE_GS_HIKIDO_OPEN", "SEQ_SE_GS_HIKIDO_CLOSE" },
  }
  for soundType = 1, 4 do
    local sounds = {}
    local door = instantDoor(soundType)
    runTransition({
      doorAt = function()
        return door
      end,
      playSound = function(sequence)
        sounds[#sounds + 1] = sequence
      end,
    })
    Assert.deepEqual(sounds, expected[soundType], "door sound selector " .. soundType)
  end
end

function T.tests.door_profile_uses_destination_door_and_facing_asymmetric_steps()
  local function runCase(destinationDoor, destinationFacing)
    local player = {
      motion = "idle",
      steps = {},
      scriptedStep = function(self, direction)
        self.steps[#self.steps + 1] = direction
        self.motion = "idle"
        return true
      end,
    }
    runTransition({
      sourceDoor = instantDoor(1),
      destinationDoor = destinationDoor and instantDoor(1) or nil,
      destinationFacing = destinationFacing,
      player = player,
    })
    return player.steps
  end

  Assert.deepEqual(runCase(false, "north"), { "north" })
  Assert.deepEqual(runCase(false, "south"), { "north", "south" })
  Assert.deepEqual(runCase(true, "north"), { "north", "south" })
end

function T.tests.nonordinary_profiles_dispatch_exit_enter_and_camera_families()
  local events = {}
  local player = {
    motion = "idle",
    facing = "south",
    pauseTransitionAnimation = function() end,
    resumeTransitionAnimation = function() end,
    beginTransitionStep = function(self, facing)
      events[#events + 1] = { phase = "movement", family = "step:" .. facing }
      self.motion = "transition"
      self.transitionTicks = 0
      self.facing = facing
      return true
    end,
    beginTransitionLadderExit = function(self, facing)
      events[#events + 1] = { phase = "movement", family = "ladder_exit:" .. facing }
      self.motion = "transition"
      self.transitionTicks = 0
      return true
    end,
    beginTransitionLadderDownExit = function(self, facing)
      events[#events + 1] = { phase = "movement", family = "ladder_down_exit:" .. facing }
      self.motion = "transition"
      self.transitionTicks = 0
      return true
    end,
    beginTransitionVerticalReturn = function(self)
      self.motion = "transition"
      self.transitionTicks = 0
      return true
    end,
    updateFixed = function(self)
      self.transitionTicks = self.transitionTicks + 1
      if self.transitionTicks == 1 then
        self.motion = "idle"
      end
      return true
    end,
  }
  local transition = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    resolveDestination = function()
      return { destinationMap = { mapId = 60 }, fieldX = 0, fieldZ = 0, surfaceId = 0, worldY = 0 }
    end,
    prepare = function() end,
    commit = function() end,
    player = player,
    onProfile = function(profile, phase, family, ...)
      events[#events + 1] = {
        profile = profile,
        phase = phase,
        family = family,
        argumentCount = select("#", profile, phase, family, ...),
      }
    end,
    cameraAdjust = function(profile, adjustment)
      events[#events + 1] = { profile = profile, phase = "camera", family = adjustment }
    end,
    escalatorAt = function()
      return {
        play = function() end,
        isFinished = function()
          return true
        end,
      }
    end,
  })

  for _, profile in ipairs({ 2, 4, 5, 7, 8 }) do
    events = {}
    transition:start({ mapId = 61 }, {
      warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
      transition = { mode = "fixed", profile = profile },
    }, "south")
    advanceTo(transition, "idle", 128)
    Assert.equal(transition.phase, "idle", "profile " .. profile .. " completes")
    Assert.equal(events[1].profile, profile)
    Assert.equal(events[1].phase, "exit")
    Assert.equal(events[1].family, FieldTransitionProfile.ROUTINE_FAMILIES[profile].exit)
    Assert.equal(events[1].argumentCount, 3)
    local enter
    for _, event in ipairs(events) do
      if event.phase == "enter" then
        enter = event
        break
      end
    end
    Assert.notNil(enter, "profile " .. profile .. " must dispatch its enter routine")
    Assert.equal(enter.profile, profile)
    Assert.equal(enter.family, FieldTransitionProfile.ROUTINE_FAMILIES[profile].enter)
    local camera = FieldTransitionProfile.ROUTINE_FAMILIES[profile].adjustment
    if camera then
      local cameraEvent
      for _, event in ipairs(events) do
        if event.phase == "camera" then
          cameraEvent = event
          break
        end
      end
      Assert.notNil(cameraEvent, "profile " .. profile .. " must adjust the camera")
      Assert.equal(cameraEvent.family, camera)
    else
      for _, event in ipairs(events) do
        Assert.isFalse(event.phase == "camera", "profile " .. profile .. " must not adjust the camera")
      end
    end
  end
end

function T.tests.panel_lifecycle_notifies_each_side_once_without_profile_dispatch()
  local panels = {}
  local profiles = {}
  local transition = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    resolveDestination = function()
      return { destinationMap = { mapId = 60 }, fieldX = 0, fieldZ = 0, surfaceId = 0, worldY = 0 }
    end,
    prepare = function() end,
    commit = function() end,
    onPanel = function(phase)
      panels[#panels + 1] = phase
    end,
    onProfile = function()
      profiles[#profiles + 1] = true
    end,
  })
  transition:start({ mapId = 61 }, {
    warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
    transition = { mode = "panel" },
  }, "south")
  for _ = 1, 10 do
    if transition.phase == "idle" then
      break
    end
    step(transition)
  end
  Assert.deepEqual(panels, { "exit", "enter" })
  Assert.deepEqual(profiles, {})
end

function T.tests.profile_hook_failure_aborts_before_commit_but_after_commit_propagates()
  local commits = 0
  local before = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    onProfile = function(_, phase)
      if phase == "exit" then
        error("exit failed", 0)
      end
    end,
    prepare = function() end,
    commit = function()
      commits = commits + 1
    end,
  })
  local ok, err = pcall(function()
    before:start({ mapId = 61 }, {
      warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
      transition = { mode = "fixed", profile = 4 },
    }, "south")
  end)
  Assert.isFalse(ok)
  Assert.equal(tostring(err), "exit failed")
  Assert.equal(before.phase, "idle")
  Assert.isFalse(before.locked)
  Assert.isNil(before.sourceMap)
  Assert.equal(tostring(before.error), "exit failed")
  Assert.equal(commits, 0)

  local after = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    resolveDestination = function()
      return { destinationMap = { mapId = 60 }, fieldX = 0, fieldZ = 0, surfaceId = 0, worldY = 0 }
    end,
    prepare = function() end,
    commit = function() end,
    onProfile = function(_, phase)
      if phase == "enter" then
        error("enter failed", 0)
      end
    end,
  })
  after:start({ mapId = 61 }, {
    warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
    transition = { mode = "fixed", profile = 4 },
  }, "south")
  advanceTo(after, "swap_map", 128)
  local enterOk, enterErr = pcall(after.updateFixed, after)
  Assert.isFalse(enterOk)
  Assert.equal(tostring(enterErr), "enter failed")
  Assert.equal(after.phase, "swap_map")
end

return T
