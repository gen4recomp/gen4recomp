-- Fixed-step session tests prove deterministic tick counts, catch-up capping,
-- and that the camera consumes the player's continuous 3D target.

local Assert = require("tests.support.Assert")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local FieldApplicationRegistry = require("libs.hgss.src.field.FieldApplicationRegistry")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldInput = require("libs.hgss.src.field.FieldInput")
local FieldPlayerModule = require("libs.hgss.src.actors.FieldPlayer")
local FieldPlayerVisual = require("libs.hgss.src.actors.FieldPlayerVisual")
local FieldSessionModule = require("libs.hgss.src.field.FieldSession")
local ScriptInteractionClient = require("libs.hgss.src.script.ScriptInteractionClient")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")
local TilePermissions = require("tests.support.TilePermissions")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local S = require("gen4.script")
local Registry = require("libs.script.src.Registry")
local Composition = require("libs.script.src.Composition")
local TaskRegistry = require("libs.script.src.TaskRegistry")
local Scheduler = require("libs.script.src.Scheduler")
local MovementTask = require("libs.hgss.src.script.tasks.MovementTask")
local WaitTicksTask = require("libs.script.src.tasks.WaitTicksTask")
local ScriptActorWorld = require("libs.hgss.src.script.ScriptActorWorld")
local FakeServices = require("tests.support.script.FakeServices")

local T = {}

---@class FieldSessionTest.Module : FieldSession
---@field FIXED_DT number
---@field FIXED_HZ integer
---@field MAX_CATCH_UP_TICKS integer
---@field new fun(options: table): FieldSession
local FieldSession = {
  FIXED_DT = FieldSessionModule.FIXED_DT,
  FIXED_HZ = FieldSessionModule.FIXED_HZ,
  MAX_CATCH_UP_TICKS = FieldSessionModule.MAX_CATCH_UP_TICKS,
}
function FieldSession.new(options)
  return FieldSessionModule.new(options --[[@as FieldSessionOptions]])
end

---@class FieldSessionTest.PlayerModule : FieldPlayer
---@field WALK_STEP_TICKS integer
---@field new fun(options: table): FieldPlayer
local FieldPlayer = {
  WALK_STEP_TICKS = FieldPlayerModule.WALK_STEP_TICKS,
}
function FieldPlayer.new(options)
  return FieldPlayerModule.new(options --[[@as FieldPlayerOptions]])
end

-- Complete fakes for the collaborators FieldSession requires at
-- construction: an idle transition (never completes, never locks, never
-- starts a warp), an input that snapshots nothing, and a manager that steps
-- no actors.
local function idleTransition()
  return {
    phase = "idle",
    locked = false,
    updateFixed = function() end,
    start = function()
      error("idle transition must never start a warp", 2)
    end,
  }
end

local function idleInput()
  return {
    snapshot = function()
      return {}
    end,
    uiSnapshot = function()
      return {}
    end,
    clearEdges = function() end,
  }
end

-- The application-host boundary the session steps: closed by default, with
-- the tick ownership and open/reopen surfaces the session calls.
local function applicationHostFake(overrides)
  local host = {
    active = false,
    openedTicks = {},
    reopenRequests = 0,
    updateCalls = 0,
    events = nil,
    activeWhileStepped = false,
  }
  function host:isActive()
    return self.active
  end
  function host:updateFixed(uiInput)
    self.updateCalls = self.updateCalls + 1
    self.events = uiInput
  end
  function host:requestOpen(tick)
    self.openedTicks[#self.openedTicks + 1] = tick
    self.active = true
    return true
  end
  function host:requestReopen()
    self.reopenRequests = self.reopenRequests + 1
  end
  function host:takeReopen(tick)
    if self.reopenRequests > 0 then
      self.reopenRequests = self.reopenRequests - 1
      self.openedTicks[#self.openedTicks + 1] = tick
      self.active = true
      return true
    end
    return false
  end
  for key, value in pairs(overrides or {}) do
    host[key] = value
  end
  return host
end

local function idleActors()
  return { step = function() end }
end

local function defaultPlayer()
  local stub = {
    fieldX = 4,
    fieldZ = 13,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "idle",
    updateFixed = function()
      return false
    end,
    collisionCandidates = function(self)
      return { { fieldX = self.fieldX, fieldZ = self.fieldZ, surfaceId = self.surfaceId } }
    end,
    clearGesturePresentation = function() end,
  }
  function stub:presentationState()
    local locomotionActive = self.motion == "walking" or self.motion == "turning" or self.motion == "jumping"
    return {
      locomotionActive = locomotionActive,
      gesturePose = nil,
      gestureTick = nil,
      gestureOffsetY = 0,
    }
  end
  return stub
end

-- Every collaborator the production runtime supplies is required at
-- construction; these defaults implement the full required interface so a
-- fixture overrides only the collaborators it exercises. The default map
-- carries empty warp events so a pressed direction reaches the warp check
-- safely.
local function baseOptions(overrides)
  local options = {
    versionId = "heartgold",
    currentMap = {
      mapId = 61,
      fieldData = { events = { warps = {} } },
      -- Mirrors the simulation-only aggregate: no presentation runtimes, so
      -- the map clock entry is a safe no-op.
      updateAnimated = function() end,
    },
    player = defaultPlayer(),
    camera = { updateFixed = function() end },
    transition = idleTransition(),
    actors = idleActors(),
    input = idleInput(),
    dialogue = {
      isModal = function()
        return false
      end,
    },
    scriptScheduler = {
      step = function() end,
      playerInputLocked = function()
        return false
      end,
      playerInputOwned = function()
        return false
      end,
      foregroundEnvironmentId = function()
        return nil
      end,
    },
    scriptClient = { consume = function() end },
    enterMapActors = function() end,
    menuHost = {
      isModal = function()
        return false
      end,
      advance = function() end,
    },
    contextChoice = {
      isActive = function()
        return false
      end,
    },
    signpost = {
      isModal = function()
        return false
      end,
    },
    applicationHost = applicationHostFake(),
    interactions = {
      resolve = function()
        return nil
      end,
    },
    bagUnlocked = function()
      return true
    end,
    fieldEntranceIndicator = { updateFixed = function() end },
    eventResolver = {
      resolveCoordinate = function()
        return nil
      end,
      resolvePassiveSign = function()
        return nil
      end,
    },
    eventState = { getVar = function() end },
  }
  for key, value in pairs(overrides) do
    rawset(options, key, value)
  end
  local scheduler = options.scriptScheduler
  scheduler.autonomousActorsLocked = scheduler.autonomousActorsLocked or function()
    return false
  end
  scheduler.autonomousActorLocked = scheduler.autonomousActorLocked or function()
    return false
  end
  local player = options.player
  player.collisionCandidates = player.collisionCandidates
    or function(self)
      return { { fieldX = self.fieldX, fieldZ = self.fieldZ, surfaceId = self.surfaceId } }
    end
  player.clearGesturePresentation = player.clearGesturePresentation or function() end
  player.presentationState = player.presentationState
    or function(self)
      local locomotionActive = self.motion == "walking" or self.motion == "turning" or self.motion == "jumping"
      return {
        locomotionActive = locomotionActive,
        gesturePose = nil,
        gestureTick = nil,
        gestureOffsetY = 0,
      }
    end
  return options
end

local function fixedSession()
  local targets = {}
  local camera = {
    updateFixed = function(_, target)
      targets[#targets + 1] = { x = target.x, y = target.y, z = target.z }
    end,
  }
  local player = {
    worldX = 1.25,
    worldY = 2.5,
    worldZ = 3.75,
    updateFixed = function()
      return false
    end,
  }
  return FieldSession.new(baseOptions({ player = player, camera = camera })), targets
end

-- This fixture keeps the complete actor-step seam intact: a real manager owns
-- the ordinary actor, a real scheduler owns the lock query, and the session
-- composes the callback that joins them for one fixed tick.
local function realActorStepSession()
  local map = {
    mapId = 61,
    coordinateOrigin = { x = 0, z = 0 },
    terrain = TerrainSurface.new({
      plates = {
        {
          id = 0,
          minX = 0,
          minZ = 0,
          maxX = 32,
          maxZ = 32,
          normal = { x = 0, y = 1, z = 0 },
          distance = 0,
          slopeClass = "flat",
        },
      },
    }),
    collision = {
      containsLocal = function(_, fieldX, fieldZ)
        return fieldX >= 0 and fieldX < 32 and fieldZ >= 0 and fieldZ < 32
      end,
    },
    fieldData = {
      events = {
        objects = {
          {
            index = 0,
            objectEventId = 0,
            spriteId = 99,
            movementType = "look_north",
            type = 0,
            eventFlag = 0,
            scriptId = 0,
            facingDirection = "south",
            facingDirectionRaw = 1,
            param0 = 0,
            param1 = 0,
            param2 = 0,
            xRange = 0,
            yRange = 0,
            x = 2,
            z = 3,
            y = 0,
          },
        },
        background = {},
        warps = {},
        coordinates = {},
      },
    },
    mapSymbol = "test-map",
    mapSection = "test-section",
    mapSectionNativeId = 7,
    followMode = "ALLOW",
    scene = {},
    cameraType = 0,
    release = function() end,
    updateAnimated = function() end,
  }
  local manager = FieldActorManager.new({
    assets = {
      knows = function(_, spriteId)
        return spriteId == 99
      end,
      acquire = function(_, spriteId)
        return { spriteId = spriteId, visual = FieldActorFixture.visual(spriteId), references = 1 }
      end,
      release = function() end,
    },
    policy = { variableSprites = { first = 101, last = 117, variableBase = 0x4020 } },
  })
  manager:enterMap(map, FieldEventState.new())

  local scheduler = Scheduler.new({ services = {}, taskRegistry = TaskRegistry.new() })
  local lockQueries = {}
  local schedulerLockQuery = scheduler.autonomousActorLocked
  function scheduler:autonomousActorLocked(actorId)
    lockQueries[#lockQueries + 1] = actorId
    return schedulerLockQuery(self, actorId)
  end

  local session = FieldSession.new(baseOptions({
    currentMap = map,
    actors = manager,
    scriptScheduler = scheduler,
  }))
  return session, manager, lockQueries
end

function T.real_field_session_actor_step_passes_the_stable_id_to_the_scheduler()
  local session, manager, lockQueries = realActorStepSession()
  local ok, err = pcall(function()
    session:updateFixed({})
  end)
  Assert.isTrue(ok, "a real actor step must not fail the scheduler lock query: " .. tostring(err))
  Assert.deepEqual(lockQueries, { "map:61:object:0" }, "the scheduler must receive the manager actor's stable ID")
  manager:dispose()
end

function T.fixed_tick_runs_the_major_arbitration_phases_in_order()
  local order = {}
  local function mark(phase)
    order[#order + 1] = phase
  end

  local options = baseOptions({
    terrainEffects = {
      updateFixed = function()
        mark("terrain")
      end,
    },
    transition = {
      phase = "idle",
      locked = false,
      updateFixed = function()
        mark("transition")
      end,
      start = function()
        mark("transition-start")
      end,
    },
    currentMap = {
      mapId = 61,
      fieldData = { events = { warps = {}, background = {}, coordinates = {} } },
      updateAnimated = function()
        mark("map-animation")
      end,
    },
    applicationHost = {
      isActive = function()
        mark("application-check")
        return false
      end,
      updateFixed = function()
        mark("application-update")
      end,
      requestOpen = function()
        mark("application-open")
      end,
      takeReopen = function()
        mark("application-reopen")
        return false
      end,
    },
    dialogue = {
      isModal = function()
        mark("dialogue-check")
        return false
      end,
    },
    scriptScheduler = {
      playerMovementLocked = function()
        mark("script-lock-check")
        return false
      end,
      step = function()
        mark("script-step")
      end,
    },
    menuHost = {
      isModal = function()
        mark("menu-check")
        return false
      end,
      advance = function()
        mark("menu-step")
      end,
    },
    contextChoice = {
      isActive = function()
        mark("context-check")
        return false
      end,
    },
    actors = {
      step = function()
        mark("actors")
      end,
    },
    interactions = {
      resolve = function()
        mark("interaction")
      end,
    },
    player = {
      fieldX = 4,
      fieldZ = 13,
      worldX = 0,
      worldY = 0,
      worldZ = 0,
      surfaceId = 0,
      facing = "south",
      motion = "idle",
      updateFixed = function()
        mark("player")
      end,
      collapseRenderInterpolation = function() end,
    },
    playerVisual = {
      updateFixed = function()
        mark("player-visual")
      end,
    },
    camera = {
      updateFixed = function()
        mark("camera")
      end,
      collapseRenderInterpolation = function() end,
    },
    fieldEntranceIndicator = {
      updateFixed = function()
        mark("tick-advance")
      end,
    },
  })
  local session = FieldSession.new(options)
  session:updateFixed({ actionPressed = true })

  local positions = {}
  for index, phase in ipairs(order) do
    positions[phase] = positions[phase] or index
  end
  local function before(first, second)
    Assert.isTrue(
      positions[first] < positions[second],
      first .. " must run before " .. second .. "; observed arbitration order was not preserved"
    )
  end

  before("terrain", "transition")
  before("transition", "application-check")
  before("application-check", "dialogue-check")
  before("dialogue-check", "map-animation")
  before("map-animation", "script-step")
  before("script-step", "actors")
  before("actors", "interaction")
  before("interaction", "player")
  before("player", "player-visual")
  before("player-visual", "camera")
  before("camera", "tick-advance")
  Assert.equal(session.tick, 1)
end

function T.actor_only_construction_is_rejected()
  local actor = { worldX = 1.25, worldY = 2.5, worldZ = 3.75 }
  local camera = { updateFixed = function() end }
  -- Intentional: the obsolete actor-only options shape must be rejected by the
  -- constructor's required-player contract.
  local options = {
    versionId = "heartgold",
    currentMap = { mapId = 61 },
    actor = actor,
    camera = camera,
  }
  ---@cast options FieldSessionOptions
  local ok, err = pcall(FieldSession.new, options)
  Assert.isFalse(ok, "a session must require the player, not fall back to an actor option: " .. tostring(err))
end

function T.player_is_used_as_the_session_player()
  local player = {
    worldX = 1.25,
    worldY = 2.5,
    worldZ = 3.75,
    updateFixed = function() end,
  }
  local camera = { updateFixed = function() end }
  local s = FieldSession.new(baseOptions({ player = player, camera = camera }))
  Assert.equal(s.player, player)
  Assert.deepEqual(s:actorTarget(), { x = 1.25, y = 2.5, z = 3.75 })
end

-- The transition, input, and actor manager are tick-path collaborators every
-- production session supplies; construction must require them instead of
-- letting a session run with half its tick machinery missing. The dialogue,
-- script scheduler/client, menu host, context choice, and interaction
-- resolver complete the production composition set and are required the same
-- way.
function T.required_collaborators_are_validated_at_construction()
  local required = {
    "versionId",
    "currentMap",
    "player",
    "camera",
    "transition",
    "actors",
    "input",
    "dialogue",
    "scriptScheduler",
    "scriptClient",
    "menuHost",
    "contextChoice",
    "signpost",
    "applicationHost",
    "interactions",
  }
  for _, missing in ipairs(required) do
    local partial = baseOptions({})
    partial[missing] = nil
    local ok, err = pcall(FieldSession.new, partial)
    Assert.isFalse(ok, "a session must require " .. missing .. ": " .. tostring(err))
  end
end

-- The session calls required collaborator operations unconditionally on its
-- tick paths, so a collaborator missing one of those methods is the same
-- composition fault as a missing collaborator.
function T.required_collaborator_methods_are_validated_at_construction()
  local cases = {
    { key = "transition", method = "start", label = "transition.start" },
    { key = "dialogue", method = "isModal", label = "dialogue.isModal" },
    { key = "currentMap", method = "updateAnimated", label = "currentMap.updateAnimated" },
    { key = "signpost", method = "isModal", label = "signpost.isModal" },
    { key = "applicationHost", method = "isActive", label = "applicationHost.isActive" },
    { key = "applicationHost", method = "updateFixed", label = "applicationHost.updateFixed" },
    { key = "applicationHost", method = "requestOpen", label = "applicationHost.requestOpen" },
    { key = "applicationHost", method = "takeReopen", label = "applicationHost.takeReopen" },
  }
  for _, case in ipairs(cases) do
    local options = baseOptions({})
    options[case.key][case.method] = nil
    local ok, err = pcall(FieldSession.new, options)
    Assert.isFalse(ok, "a session must require " .. case.label .. ": " .. tostring(err))
  end
end

-- A session with an audio collaborator requires the field-policy method it
-- actually invokes at construction. The save gate never consults a
-- save-stability predicate (transient audio is discarded on load and the
-- restored wait tasks complete against the fresh service), so a collaborator
-- that only provides field-policy work is complete. A session without audio
-- has no audio collaborator at all. The session must never require a separate
-- sound-frame method: FieldRuntime composes the post-field semantic audio
-- source-frame stage after each fixed field tick.
function T.audio_collaborator_requires_field_policy_and_effect_playback()
  local complete = { updateField = function() end, play = function() end }
  Assert.notNil(FieldSession.new(baseOptions({ audio = complete })))
  local ok, err = pcall(FieldSession.new, baseOptions({ audio = {} }))
  Assert.isFalse(ok, "a session with audio must require audio.updateField: " .. tostring(err))
  local missingPlay, missingPlayErr = pcall(
    FieldSession.new,
    baseOptions({
      audio = { updateField = function() end },
    })
  )
  Assert.isFalse(missingPlay, "a session with audio must require audio.play: " .. tostring(missingPlayErr))
  Assert.notNil(FieldSession.new(baseOptions({})))
end

function T.session_requires_player_presentation_state()
  local playerWithoutPresentation = {
    fieldX = 4,
    fieldZ = 13,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "idle",
    updateFixed = function()
      return false
    end,
    collisionCandidates = function(self)
      return { { fieldX = self.fieldX, fieldZ = self.fieldZ, surfaceId = self.surfaceId } }
    end,
  }
  local options = {
    versionId = "heartgold",
    currentMap = { mapId = 61, fieldData = { events = { warps = {} } }, updateAnimated = function() end },
    player = playerWithoutPresentation,
    camera = { updateFixed = function() end },
    transition = { phase = "idle", locked = false, updateFixed = function() end, start = function() end },
    actors = { step = function() end },
    input = {
      snapshot = function()
        return {}
      end,
      uiSnapshot = function()
        return {}
      end,
      clearEdges = function() end,
    },
    dialogue = {
      isModal = function()
        return false
      end,
    },
    scriptScheduler = {
      step = function() end,
      playerInputOwned = function()
        return false
      end,
      foregroundEnvironmentId = function()
        return nil
      end,
    },
    scriptClient = { consume = function() end },
    menuHost = {
      isModal = function()
        return false
      end,
      advance = function() end,
    },
    contextChoice = {
      isActive = function()
        return false
      end,
    },
    signpost = {
      isModal = function()
        return false
      end,
    },
    applicationHost = {
      isActive = function()
        return false
      end,
      updateFixed = function() end,
      requestOpen = function()
        return false
      end,
      takeReopen = function()
        return false
      end,
    },
    interactions = {
      resolve = function()
        return nil
      end,
    },
    fieldEntranceIndicator = { updateFixed = function() end },
    eventResolver = {
      resolveCoordinate = function()
        return nil
      end,
      resolvePassiveSign = function()
        return nil
      end,
    },
    eventState = { getVar = function() end },
  }
  local ok, err = pcall(FieldSession.new, options)
  Assert.isFalse(ok, "session must require player presentationState: " .. tostring(err))
end

function T.fixed_ticks_are_render_cadence_independent()
  local a = fixedSession()
  a:update(1 / 30)
  local b = fixedSession()
  b:update(1 / 60)
  b:update(1 / 60)
  Assert.equal(a.tick, 1)
  Assert.equal(b.tick, 1)
end

function T.excess_backlog_is_discarded_after_max_catch_up()
  local s = fixedSession()
  s:update(10 / 30)
  Assert.equal(s.tick, 5)
  -- The 5 excess ticks were dropped, not deferred to the next frame.
  s:update(1 / 30)
  Assert.equal(s.tick, 6)
end

function T.camera_follows_the_player_xyz_each_fixed_tick()
  local s, targets = fixedSession()
  s:update(1 / 30)
  Assert.deepEqual(targets[1], { x = 1.25, y = 2.5, z = 3.75 })
end

function T.map_init_claims_the_tick_before_scheduler_and_player_input()
  local order = {}
  local controller = {
    evaluate = function(_, tick)
      order[#order + 1] = "init:" .. tick
      return true
    end,
  }
  local scheduler = {
    step = function()
      order[#order + 1] = "scheduler"
    end,
    playerInputLocked = function()
      return false
    end,
    playerInputOwned = function()
      return false
    end,
    foregroundEnvironmentId = function()
      return nil
    end,
  }
  local input = idleInput()
  input.snapshot = function()
    return { pressedDirection = "south" }
  end
  local player = defaultPlayer()
  player.updateFixed = function()
    order[#order + 1] = "player"
    return false
  end
  local session = FieldSession.new(baseOptions({
    initController = controller,
    scriptScheduler = scheduler,
    input = input,
    player = player,
  }))

  session:updateFixed()

  Assert.deepEqual(order, { "init:1" })
end

function T.map_lifecycle_events_are_queued_and_drained_before_frame_checks()
  local order = {}
  local controller = {
    hasLifecycle = function(_, lifecycle)
      return lifecycle == "on_transition" or lifecycle == "on_load" or lifecycle == "on_resume"
    end,
    startLifecycle = function(_, lifecycle, tick)
      order[#order + 1] = lifecycle .. ":" .. tick
      return true
    end,
    evaluateFrame = function(_, tick)
      order[#order + 1] = "frame:" .. tick
      return true
    end,
  }
  local scheduler = {
    busy = false,
    step = function(self)
      order[#order + 1] = "scheduler"
      self.busy = false
    end,
    playerInputLocked = function(self)
      return self.busy
    end,
    playerInputOwned = function(self)
      return self.busy
    end,
    foregroundEnvironmentId = function(self)
      return self.busy and "foreground" or nil
    end,
  }
  local s = FieldSession.new(baseOptions({
    initController = controller,
    scriptScheduler = scheduler,
    autoAcknowledgePresentation = true,
    enterMapActors = function()
      order[#order + 1] = "actors"
    end,
  }))
  s:beginMapEntry()
  for _ = 1, 9 do
    s:updateFixed()
  end
  Assert.deepEqual(order, {
    "on_transition:1",
    "actors",
    "on_load:4",
    "on_resume:7",
    "scheduler",
    "frame:9",
  })
end

function T.map_entry_lifecycle_has_a_dedicated_session_owner()
  local session = FieldSession.new(baseOptions({
    initController = {
      hasLifecycle = function()
        return false
      end,
      startLifecycle = function()
        return false
      end,
    },
  }))

  Assert.notNil(session.mapEntryController, "map-entry phase state must have one explicit owner")
  Assert.equal(type(session.mapEntryController.advance), "function")
  Assert.equal(type(session.mapEntryController.begin), "function")
end

function T.destination_presentability_is_monotonic_through_map_entry()
  local controller = {
    hasLifecycle = function(_, lifecycle)
      return lifecycle == "on_transition" or lifecycle == "on_load" or lifecycle == "on_resume"
    end,
    startLifecycle = function()
      return true
    end,
  }
  local s = FieldSession.new(baseOptions({
    initController = controller,
    autoAcknowledgePresentation = false,
  }))

  s:beginMapEntry()
  Assert.isFalse(s:destinationWorldPresentable())
  s:updateFixed({})
  Assert.equal(s.mapEntryController:currentStage(), "transition_running")
  Assert.isFalse(s:destinationWorldPresentable())
  s:updateFixed({})
  Assert.equal(s.mapEntryController:currentStage(), "actors")
  Assert.isFalse(s:destinationWorldPresentable())
  s:updateFixed({})
  Assert.equal(s.mapEntryController:currentStage(), "load")
  Assert.isFalse(s:destinationWorldPresentable())
  s:updateFixed({})
  Assert.equal(s.mapEntryController:currentStage(), "load_running")
  Assert.isFalse(s:destinationWorldPresentable())
  s:updateFixed({})
  Assert.equal(s.mapEntryController:currentStage(), "await_presentation")
  Assert.isTrue(s:destinationWorldPresentable())

  s:acknowledgeDestinationPresentation()
  Assert.equal(s.mapEntryController:currentStage(), "resume")
  Assert.isTrue(s:destinationWorldPresentable())
  s:updateFixed({})
  Assert.equal(s.mapEntryController:currentStage(), "resume_running")
  Assert.isTrue(s:destinationWorldPresentable())
  s:updateFixed({})
  Assert.equal(s.mapEntryController:currentStage(), "ready")
  Assert.isTrue(s:destinationWorldPresentable())
  s:updateFixed({})
  Assert.isNil(s.mapEntryController:currentStage())
  Assert.isTrue(s:destinationWorldPresentable())
end

function T.blocked_lifecycle_stays_at_head_until_foreground_is_free()
  local starts = {}
  local scheduler = {
    busy = true,
    step = function() end,
    playerInputLocked = function(self)
      return self.busy
    end,
    playerInputOwned = function(self)
      return self.busy
    end,
    foregroundEnvironmentId = function(self)
      return self.busy and "busy" or nil
    end,
  }
  local controller = {
    hasLifecycle = function(_, lifecycle)
      return lifecycle == "on_transition"
    end,
    startLifecycle = function(_, lifecycle, tick)
      starts[#starts + 1] = { lifecycle = lifecycle, tick = tick }
      return not scheduler.busy
    end,
    evaluateFrame = function()
      error("frame lifecycle overtook pending work")
    end,
  }
  local s = FieldSession.new(baseOptions({ initController = controller, scriptScheduler = scheduler }))
  s:beginMapEntry()
  s:updateFixed({})
  Assert.deepEqual(starts, {})
  scheduler.busy = false
  s:updateFixed({})
  s:updateFixed({})
  Assert.deepEqual(starts, { { lifecycle = "on_transition", tick = 2 } })
end

function T.lifecycle_start_retry_keeps_the_entry_stage_pending()
  local starts = 0
  local controller = {
    hasLifecycle = function(_, lifecycle)
      return lifecycle == "on_transition"
    end,
    startLifecycle = function()
      starts = starts + 1
      return starts > 1
    end,
  }
  local entered = 0
  local s = FieldSession.new(baseOptions({
    initController = controller,
    enterMapActors = function()
      entered = entered + 1
    end,
  }))
  s:beginMapEntry()
  s:updateFixed({})
  Assert.equal(starts, 1)
  Assert.equal(entered, 0)
  Assert.equal(s.mapEntryController:currentStage(), "transition")
  s:updateFixed({})
  Assert.equal(starts, 2)
  Assert.equal(s.mapEntryController:currentStage(), "transition_running")
  Assert.equal(entered, 0)
end

function T.absent_lifecycle_falls_through_and_each_start_consumes_a_tick()
  local starts = {}
  local controller = {
    hasLifecycle = function(_, lifecycle)
      return lifecycle ~= "on_transition"
    end,
    startLifecycle = function(_, lifecycle, tick)
      starts[#starts + 1] = { lifecycle = lifecycle, tick = tick }
      return true
    end,
    evaluateFrame = function(_, tick)
      starts[#starts + 1] = { lifecycle = "frame", tick = tick }
      return true
    end,
  }
  local s = FieldSession.new(baseOptions({ initController = controller }))
  s:beginMapEntry()
  s:updateFixed({})
  Assert.deepEqual(starts, {})
  s:updateFixed({})
  s:updateFixed({})
  Assert.deepEqual(starts, { { lifecycle = "on_load", tick = 3 } })
end

function T.child_resume_appends_without_resetting_map_entry_queue()
  local s = FieldSession.new(baseOptions({
    initController = {
      hasLifecycle = function()
        return false
      end,
      startLifecycle = function()
        return false
      end,
    },
  }))
  s:onChildApplicationResume()
  Assert.isTrue(s.childResumePending)
end

function T.new_map_entry_discards_previous_generation_requests()
  local s = FieldSession.new(baseOptions({
    initController = {
      hasLifecycle = function()
        return true
      end,
      startLifecycle = function()
        return true
      end,
    },
  }))
  s:beginMapEntry()
  s:beginMapEntry()
  Assert.equal(s.mapEntryController:currentStage(), "transition")
end

function T.distinct_resume_requests_execute_separately()
  local starts = 0
  local s = FieldSession.new(baseOptions({
    initController = {
      hasLifecycle = function(_, lifecycle)
        return lifecycle == "on_resume"
      end,
      startLifecycle = function(_, lifecycle)
        Assert.equal(lifecycle, "on_resume")
        starts = starts + 1
        return true
      end,
    },
  }))
  s:onChildApplicationResume()
  s:onChildApplicationResume()
  s:updateFixed({})
  s:updateFixed({})
  Assert.equal(starts, 1)
end

function T.completed_transition_holds_the_arrival_tile_for_autosave()
  local updates = 0
  local player = {
    fieldX = 4,
    fieldZ = 14,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "idle",
    updateFixed = function()
      updates = updates + 1
    end,
    collapseRenderInterpolation = function() end,
  }
  local transition = {
    phase = "fade_in",
    locked = true,
    updateFixed = function(self)
      self.phase, self.locked = "idle", false
      self.completed = { destinationMapId = 61 }
    end,
    start = function()
      error("a completing transition never starts a warp", 2)
    end,
  }
  local map = { mapId = 61, cameraType = 4, updateAnimated = function() end }
  local camera = { updateFixed = function() end }
  local s = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    transition = transition,
  }))
  s:updateFixed({ heldDirection = "south" })
  Assert.equal(updates, 0)
  Assert.equal(player.fieldZ, 14)
  Assert.notNil(transition.completed)
end

function T.script_completion_consumes_its_final_action_edge()
  local resolved = 0
  local locked = true
  local scheduler = {
    step = function()
      locked = false
    end,
    playerInputLocked = function()
      return locked
    end,
    playerInputOwned = function()
      return locked
    end,
    foregroundEnvironmentId = function()
      return locked and "foreground" or nil
    end,
  }
  local player = {
    fieldX = 0,
    fieldZ = 0,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    motion = "idle",
    updateFixed = function() end,
  }
  local map = { mapId = 61, updateAnimated = function() end } --[[@as any]]
  local camera = { updateFixed = function() end } --[[@as any]]
  local interactions = {
    resolve = function()
      resolved = resolved + 1
    end,
  } --[[@as FieldSession.Interactions]]
  local client = {
    consume = function()
      error("the script client must not be reached while the scheduler owns the tick", 2)
    end,
  }
  local s = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    scriptScheduler = scheduler,
    interactions = interactions,
    scriptClient = client,
  }))
  s:updateFixed({ actionPressed = true })
  Assert.equal(resolved, 0)
end

-- The input snapshot vocabulary is actionPressed/cancelPressed; the
-- scheduler receives edges only through that vocabulary. Snapshot properties
-- outside it are ignored -- the scheduler's own step-input vocabulary
-- (pressedAction/pressedCancel) is a separate contract.
function T.scheduler_edges_come_only_from_current_snapshot_properties()
  local received
  local scheduler = {
    step = function(_, _, snapshot)
      received = snapshot
    end,
    playerInputLocked = function()
      return false
    end,
    playerInputOwned = function()
      return false
    end,
    foregroundEnvironmentId = function()
      return nil
    end,
  }
  local s = FieldSession.new(baseOptions({ scriptScheduler = scheduler }))
  s:updateFixed({ pressedAction = true, pressedCancel = true })
  Assert.isNil(received.pressedAction, "snapshot pressedAction is not scheduler input")
  Assert.isNil(received.pressedCancel, "snapshot pressedCancel is not scheduler input")
end

-- A modal menu receives normalized UI events through the scheduler input,
-- while its physical edge remains unavailable to field interaction handling.
function T.modal_menu_routes_ui_events_to_the_script_scheduler()
  local input = FieldInput.new()
  local received
  local menuHost = {
    isModal = function()
      return true
    end,
    inputEvents = function(_, events)
      received = events
      return events
    end,
    advance = function() end,
  }
  local scheduler = {
    step = function(_, _, snapshot)
      Assert.equal(snapshot.menuEvents[1].type, "navigate")
      Assert.equal(snapshot.menuEvents[1].direction, "down")
    end,
    playerInputLocked = function()
      return true
    end,
    playerInputOwned = function()
      return true
    end,
    foregroundEnvironmentId = function()
      return "foreground"
    end,
  }
  local player = {
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    updateFixed = function()
      return false
    end,
  }
  local map = { mapId = 61, updateAnimated = function() end }
  local camera = { updateFixed = function() end }
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    input = input,
    menuHost = menuHost,
    scriptScheduler = scheduler,
  }))

  input:pressDirection("south", "key:s")
  session:updateFixed()
  Assert.equal(received[1].type, "navigate")
end

function T.the_player_pose_clock_advances_once_per_tick_and_freezes_under_a_transition()
  local steps = 0
  local playerVisual = {
    updateFixed = function()
      steps = steps + 1
    end,
  }
  local player = {
    fieldX = 0,
    fieldZ = 0,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "idle",
    updateFixed = function()
      return false
    end,
    collapseRenderInterpolation = function() end,
  }
  local transition = {
    phase = "idle",
    updateFixed = function() end,
    start = function()
      error("idle transition must never start a warp", 2)
    end,
  }
  local map = { mapId = 61, cameraType = 4, updateAnimated = function() end }
  local camera = { updateFixed = function() end }
  local s = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    transition = transition,
    playerVisual = playerVisual,
  }))
  s:updateFixed({})
  s:updateFixed({})
  Assert.equal(steps, 2)

  transition.locked = true
  s:updateFixed({})
  Assert.equal(steps, 2, "a locked transition owns the tick, so no pose advances")
end

local function warpSession(options)
  local starts = {}
  local transition = {
    phase = "idle",
    locked = false,
    updateFixed = function() end,
    start = function(_, map, trigger, facing)
      starts[#starts + 1] = { map = map, warp = trigger.warp, facing = facing }
    end,
  }
  local warp = { index = 0, x = options.warpX, z = options.warpZ, destinationMapId = 60, destinationWarpId = 0, y = 0 }
  local map = {
    mapId = 61,
    cameraType = 4,
    coordinateOrigin = { x = 0, z = 0 },
    fieldData = { events = { warps = { warp } } },
    updateAnimated = function() end,
    collision = TilePermissions.new(options.tiles),
  }
  local player = {
    fieldX = options.fieldX,
    fieldZ = options.fieldZ,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "idle",
  }
  function player:updateFixed()
    if options.commit then
      self.fieldX, self.fieldZ = options.warpX, options.warpZ
      options.commit = false
      return true
    end
    return false
  end
  local camera = { updateFixed = function() end }
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    transition = transition,
  }))
  return session, transition, starts, warp
end

-- The facing-tile door: warp tile (4,14) is a blocked DOOR ahead of the idle
-- player at (4,13) facing south. Behavior bytes come from MetatileBehavior's
-- TILE_BEHAVIOR_* table (pokeheartgold metatile_behavior.h).
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")
local DOOR = MetatileBehavior.BEHAVIOR.DOOR
local ENTRANCE_SOUTH = MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_SOUTH
local ENTRANCE_NORTH = MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_NORTH

function T.door_warp_starts_before_player_collision()
  local session, _, starts, warp = warpSession({
    fieldX = 4,
    fieldZ = 13,
    warpX = 4,
    warpZ = 14,
    tiles = { ["4:14"] = { behavior = DOOR, blocked = true } },
  })
  session:updateFixed({ heldDirection = "south", pressedDirection = "south" })
  Assert.equal(#starts, 1)
  Assert.equal(starts[1].warp, warp)
  Assert.equal(starts[1].facing, "south")
  Assert.equal(session.player.fieldZ, 13)
end

function T.actor_on_a_blocked_door_cell_does_not_block_the_facing_warp()
  -- A permission-blocked cell with a door warp (the town door pattern)
  -- triggers the warp before a movement start is ever attempted, so occupancy
  -- must not interfere with it.
  local starts = {}
  local transition = {
    phase = "idle",
    locked = false,
    updateFixed = function() end,
    start = function(_, map, trigger, facing)
      starts[#starts + 1] = { map = map, warp = trigger.warp, facing = facing }
    end,
  }
  local warp = { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0, y = 0 }
  local map = {
    mapId = 61,
    cameraType = 4,
    coordinateOrigin = { x = 0, z = 0 },
    fieldData = { events = { warps = { warp } } },
    updateAnimated = function() end,
    collision = TilePermissions.new({ ["4:14"] = { behavior = DOOR, blocked = true } }),
    terrain = TerrainSurface.new({
      plates = {
        {
          id = 0,
          minX = 0,
          minZ = 0,
          maxX = 32,
          maxZ = 32,
          normal = { x = 0, y = 1, z = 0 },
          distance = 0,
          slopeClass = "flat",
        },
      },
    }),
  }
  local player = FieldPlayer.new({
    currentMap = map,
    fieldX = 4,
    fieldZ = 13,
    surfaceId = 0,
    facing = "south",
    occupancy = function(candidate)
      if candidate.fieldX == 4 and candidate.fieldZ == 14 and candidate.surfaceId == 0 then
        return "map:61:object:0"
      end
      return nil
    end,
  })
  local camera = { updateFixed = function() end }
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    transition = transition,
  }))
  session:updateFixed({ heldDirection = "south", pressedDirection = "south" })
  Assert.equal(#starts, 1)
  Assert.equal(starts[1].warp, warp)
  Assert.equal(player.fieldZ, 13)
  Assert.equal(player.motion, "idle")
end

function T.actor_on_an_open_warp_cell_blocks_the_walk_but_not_the_route()
  -- A walkable warp cell is entered by stepping in. An actor standing on it
  -- blocks that step -- the original engine's NPC-on-warp-tile behavior --
  -- and the facing path never fires because the tile ahead is walkable
  -- (no door), so no trigger precedes the blocked move.
  local starts = {}
  local transition = {
    phase = "idle",
    locked = false,
    updateFixed = function() end,
    start = function(_, map, trigger, facing)
      starts[#starts + 1] = { map = map, warp = trigger.warp, facing = facing }
    end,
  }
  local warp = { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0, y = 0 }
  local map = {
    mapId = 61,
    cameraType = 4,
    coordinateOrigin = { x = 0, z = 0 },
    fieldData = { events = { warps = { warp } } },
    updateAnimated = function() end,
    collision = TilePermissions.new(),
    terrain = TerrainSurface.new({
      plates = {
        {
          id = 0,
          minX = 0,
          minZ = 0,
          maxX = 32,
          maxZ = 32,
          normal = { x = 0, y = 1, z = 0 },
          distance = 0,
          slopeClass = "flat",
        },
      },
    }),
  }
  local player = FieldPlayer.new({
    currentMap = map,
    fieldX = 4,
    fieldZ = 13,
    surfaceId = 0,
    facing = "south",
    occupancy = function(candidate)
      if candidate.fieldX == 4 and candidate.fieldZ == 14 and candidate.surfaceId == 0 then
        return "map:61:object:0"
      end
      return nil
    end,
  })
  local camera = { updateFixed = function() end }
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    transition = transition,
  }))
  session:updateFixed({ heldDirection = "south", pressedDirection = "south" })
  Assert.equal(#starts, 0)
  Assert.equal(player.fieldZ, 13)
  Assert.equal(player.motion, "idle")
end

function T.standing_generic_warp_starts_when_a_step_commits()
  -- A step onto a north-entrance tile (the step-path generic kind) starts
  -- immediately on the committing tick, matching FieldSystem_CheckTransition.
  local session, _, starts, warp = warpSession({
    fieldX = 4,
    fieldZ = 13,
    warpX = 4,
    warpZ = 14,
    commit = true,
    tiles = { ["4:14"] = { behavior = ENTRANCE_NORTH } },
  })
  session:updateFixed({ heldDirection = "south" })
  Assert.equal(#starts, 1)
  Assert.equal(starts[1].warp, warp)
  Assert.equal(session.player.fieldZ, 14)
end

function T.entrance_south_warp_starts_on_the_facing_path_after_the_step()
  -- The Elm Lab door pattern: stepping onto the walkable WARP_ENTRANCE_SOUTH
  -- tile starts nothing (step path is generic-only); the trigger fires the
  -- next tick through the facing path, while the idle player holds south
  -- toward the blocked wall tile ahead.
  local session, _, starts, warp = warpSession({
    fieldX = 4,
    fieldZ = 13,
    warpX = 4,
    warpZ = 14,
    commit = true,
    tiles = {
      ["4:14"] = { behavior = ENTRANCE_SOUTH },
      ["4:15"] = { blocked = true },
    },
  })
  session:updateFixed({ heldDirection = "south" })
  Assert.equal(#starts, 0, "the step path must not fire a direction-gated warp")
  session:updateFixed({ heldDirection = "south" })
  Assert.equal(#starts, 1)
  Assert.equal(starts[1].warp, warp)
  Assert.equal(starts[1].facing, "south")
end

function T.entrance_south_warp_does_not_start_without_its_facing_direction()
  local session, _, starts = warpSession({
    fieldX = 4,
    fieldZ = 14,
    warpX = 4,
    warpZ = 14,
    tiles = {
      ["4:14"] = { behavior = ENTRANCE_SOUTH },
      ["4:15"] = { blocked = true },
    },
  })
  session:updateFixed({ heldDirection = "north" })
  Assert.equal(#starts, 0)
end

function T.arrival_suppression_prevents_immediate_standing_bounce()
  local session, transition, starts = warpSession({
    fieldX = 4,
    fieldZ = 14,
    warpX = 4,
    warpZ = 14,
    commit = true,
    tiles = { ["4:14"] = { behavior = ENTRANCE_NORTH } },
  })
  transition.suppression = { mapId = 61, fieldX = 4, fieldZ = 14 }
  session:updateFixed({ heldDirection = "south" })
  Assert.equal(#starts, 0)
  Assert.notNil(transition.suppression)
  session.player.fieldZ = 15
  session:updateFixed({})
  Assert.isNil(transition.suppression)
end

local function dialogueSession(opts)
  opts = opts or {}
  local worldSteps = { player = 0, actors = 0, camera = 0, visual = 0 }
  local dialogueSteps = 0
  local received
  local dialogue = {
    modal = opts.modal ~= false,
    isModal = function(self)
      return self.modal
    end,
    step = function(_, snapshot)
      dialogueSteps = dialogueSteps + 1
      received = snapshot
    end,
  }
  local player = {
    fieldX = 4,
    fieldZ = 13,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "idle",
    updateFixed = function()
      worldSteps.player = worldSteps.player + 1
      return false
    end,
  }
  local camera = {
    updateFixed = function()
      worldSteps.camera = worldSteps.camera + 1
    end,
  }
  local actors = {
    step = function()
      worldSteps.actors = worldSteps.actors + 1
    end,
  }
  local playerVisual = {
    updateFixed = function()
      worldSteps.visual = worldSteps.visual + 1
    end,
  }
  local transition = {
    phase = "idle",
    locked = false,
    updateFixed = function() end,
    start = function()
      error("dialogue fixture never starts a warp", 2)
    end,
  }
  local map = { mapId = 61, cameraType = 4, fieldData = { events = { warps = {} } }, updateAnimated = function() end }
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    transition = transition,
    actors = actors,
    playerVisual = playerVisual,
    dialogue = dialogue,
  }))
  return session, worldSteps, function()
    return dialogueSteps, received
  end, dialogue
end

function T.modal_dialogue_freezes_every_world_step_and_steps_the_dialogue()
  local session, worldSteps, dialogueState, _ = dialogueSession()
  session:updateFixed({ heldDirection = "south", actionDown = true })
  Assert.equal(worldSteps.player, 0, "player does not move")
  Assert.equal(worldSteps.actors, 0, "visibility changes do not apply")
  Assert.equal(worldSteps.camera, 0, "camera holds its target")
  Assert.equal(worldSteps.visual, 0, "pose clocks pause")
  local steps, received = dialogueState()
  Assert.equal(steps, 1)
  Assert.equal(received.actionDown, true)
  Assert.equal(received.heldDirection, "south")
end

function T.modal_dialogue_blocks_warp_evaluation()
  local session, _, _ = dialogueSession()
  local map = { mapId = 61, fieldData = { events = { warps = {} } }, updateAnimated = function() end }
  session.currentMap = map --[[@as RuntimeFieldMap]]
  session:updateFixed({ heldDirection = "south", pressedDirection = "south" })
  Assert.equal(session.player.fieldZ, 13, "no movement and no warp from the modal tick")
end

function T.world_resumes_once_the_dialogue_closes()
  local session, worldSteps, _, dialogue = dialogueSession()
  session:updateFixed({})
  Assert.equal(worldSteps.player, 0)
  -- The dialogue closes (its own step dispatches the completion); the next
  -- session tick runs the world again.
  dialogue.modal = false
  session:updateFixed({ heldDirection = "south" })
  Assert.equal(worldSteps.player, 1)
  Assert.equal(worldSteps.camera, 1)
end

function T.transition_commit_clears_stale_action_edges()
  local input = FieldInput.new()
  input:pressAction("key:space")
  local player = {
    fieldX = 4,
    fieldZ = 14,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "idle",
    updateFixed = function()
      return false
    end,
    collapseRenderInterpolation = function() end,
  }
  local transition = {
    phase = "fade_in",
    locked = true,
    updateFixed = function(self)
      self.phase, self.locked = "idle", false
      self.completed = { destinationMapId = 60 }
    end,
    start = function()
      error("a completing transition never starts a warp", 2)
    end,
  }
  local camera = { updateFixed = function() end }
  local map = { mapId = 61, cameraType = 4, updateAnimated = function() end }
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    transition = transition,
    input = input,
  }))
  session:updateFixed({ actionPressed = true })
  -- The commit tick consumed the snapshot edge and cleared the input object's
  -- pending edges, so a later tick cannot act on a stale action edge after
  -- the fade; held state legitimately survives.
  Assert.isFalse(input.actionPressed, "no stale pressed edge survives the commit")
  Assert.equal(input.actionDown, true, "held state survives the commit")
end

local function interactionSession(opts)
  opts = opts or {}
  local interactions
  interactions = {
    resolve = function(_, snapshot)
      interactions.resolveSnapshot = snapshot
      return opts.intent or nil
    end,
  }
  local client = {
    consume = function(_, intent, _)
      interactions.consumedIntent = intent
      return opts.result or ScriptInteractionClient.RESULTS.started
    end,
  }
  local steps = 0
  local player = {
    fieldX = 4,
    fieldZ = 14,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "north",
    motion = "idle",
    updateFixed = function()
      steps = steps + 1
      return false
    end,
    collapseRenderInterpolation = function() end,
  }
  local camera = { updateFixed = function() end }
  local actors = { step = function() end }
  local transition = {
    phase = "idle",
    locked = false,
    updateFixed = function() end,
    start = function()
      error("interaction fixture never starts a warp", 2)
    end,
  }
  local map = { mapId = 61, cameraType = 4, fieldData = { events = { warps = {} } }, updateAnimated = function() end }
  local dialogue = {
    isModal = function()
      return opts.modalDialogue == true
    end,
    step = function() end,
  }
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    transition = transition,
    actors = actors,
    interactions = interactions,
    scriptClient = client,
    dialogue = dialogue,
  }))
  return session, player, interactions, function()
    return steps
  end
end

function T.consumed_interaction_owns_the_tick()
  local session, player, interactions, steps = interactionSession({
    intent = { kind = "object", object = { actorId = "map:61:object:0" } },
  })
  session:updateFixed({ actionPressed = true, heldDirection = "north" })
  assert(interactions.resolveSnapshot, "the resolver must have been consulted")
  assert(interactions.consumedIntent, "the resolved intent must be dispatched")
  Assert.equal(steps(), 0, "a consumed interaction blocks movement on the same tick")
  Assert.equal(player.facing, "north", "the held direction did not start a step")
  Assert.equal(session.tick, 1)
end

function T.unresolved_interaction_falls_through_to_movement()
  local session, player, _, steps = interactionSession()
  session:updateFixed({ actionPressed = true, heldDirection = "north" })
  Assert.equal(steps(), 1, "a nil intent leaves the tick to movement")
  Assert.equal(player.facing, "north")
end

-- The binding audit guarantees every interactable event is bound; an
-- unmapped intent reaching the session is a composition fault that must fail
-- loudly, never a silently absorbed Action press.
function T.unmapped_interaction_is_a_composition_fault()
  local session, _, _, steps = interactionSession({
    intent = { kind = "object", object = { actorId = "map:61:object:0" } },
    result = ScriptInteractionClient.RESULTS.unmapped,
  })
  Assert.throws(function()
    session:updateFixed({ actionPressed = true, heldDirection = "north" })
  end)
  Assert.equal(steps(), 0, "a faulting interaction must not start movement")
end

-- A foreground script already owning the field blocks the new interaction;
-- the tick is still consumed.
function T.blocked_interaction_still_consumes_the_tick()
  local session, player, _, steps = interactionSession({
    intent = { kind = "background" },
    result = ScriptInteractionClient.RESULTS.blocked,
  })
  session:updateFixed({ actionPressed = true, heldDirection = "north" })
  Assert.equal(steps(), 0, "a blocked interaction consumes the tick")
  Assert.equal(player.facing, "north")
end

function T.interaction_resolve_snapshot_carries_the_player_state()
  local session, _, interactions = interactionSession({
    intent = { kind = "object", object = { actorId = "map:61:object:0" } },
  })
  session:updateFixed({ actionPressed = true })
  local snapshot = interactions.resolveSnapshot
  assert(snapshot, "the resolver must have been consulted")
  Assert.equal(snapshot.runtimeMap.mapId, 61)
  Assert.equal(snapshot.fieldX, 4)
  Assert.equal(snapshot.fieldZ, 14)
  Assert.equal(snapshot.facing, "north")
  Assert.equal(snapshot.tick, 1)
end

function T.interaction_never_resolves_while_walking()
  local session, _, interactions = interactionSession({
    intent = { kind = "object", object = { actorId = "map:61:object:0" } },
  })
  session.player.motion = "walking"
  session:updateFixed({ actionPressed = true })
  Assert.isNil(interactions.resolveSnapshot, "a moving player is never asked to interact")
end

function T.interaction_never_resolves_without_the_action_edge()
  local session, _, interactions = interactionSession({
    intent = { kind = "object", object = { actorId = "map:61:object:0" } },
  })
  session:updateFixed({ actionDown = true, heldDirection = "north" })
  Assert.isNil(interactions.resolveSnapshot, "held Action alone never resolves")
end

function T.interaction_never_resolves_under_a_locked_transition_or_modal()
  local session, _, interactions, steps = interactionSession({
    intent = { kind = "object", object = { actorId = "map:61:object:0" } },
  })
  session.transition.locked = true
  session:updateFixed({ actionPressed = true })
  Assert.isNil(interactions.resolveSnapshot, "a locked transition owns the tick")
  Assert.equal(steps(), 0)

  local modalSession, _, modalInteractions, modalSteps = interactionSession({
    intent = { kind = "object", object = { actorId = "map:61:object:0" } },
    modalDialogue = true,
  })
  modalSession:updateFixed({ actionPressed = true })
  Assert.isNil(modalInteractions.resolveSnapshot, "modal ownership blocks new interactions")
  Assert.equal(modalSteps(), 0)
end

function T.catch_up_ticks_do_not_replay_one_action_edge()
  local input = FieldInput.new()
  input:pressAction("key:space")
  local resolved = 0
  local interactions = {
    resolve = function()
      resolved = resolved + 1
      return { kind = "object", object = { actorId = "map:61:object:0" } }
    end,
  }
  local client = {
    consume = function()
      return ScriptInteractionClient.RESULTS.started
    end,
  }
  local player = {
    fieldX = 4,
    fieldZ = 14,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "north",
    motion = "idle",
    updateFixed = function()
      return false
    end,
  }
  local camera = { updateFixed = function() end }
  local actors = { step = function() end }
  local transition = {
    phase = "idle",
    locked = false,
    updateFixed = function() end,
    start = function()
      error("catch-up fixture never starts a warp", 2)
    end,
  }
  local map = { mapId = 61, cameraType = 4, updateAnimated = function() end }
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    transition = transition,
    actors = actors,
    input = input,
    interactions = interactions,
    scriptClient = client,
  }))
  -- A render delta spanning several fixed ticks: the one Action edge must be
  -- consumed by the first tick's snapshot and never replayed by catch-up.
  -- update() takes no snapshot of its own -- each fixed step samples the input,
  -- so even a stale snapshot passed along must be ignored.
  session:update(5 * FieldSession.FIXED_DT, { actionPressed = true })
  Assert.equal(session.tick, 5, "the full catch-up ran")
  Assert.equal(resolved, 1, "one Action edge must not be replayed over catch-up ticks")
  Assert.isFalse(input.actionPressed, "the first tick consumed the edge")
  Assert.equal(input.actionDown, true, "held state survives the edge")
end

-- renderAlpha is an interpolation factor the renderer forwards to the
-- camera; extreme render deltas must not push it out of [0, 1]. A huge delta
-- saturates the catch-up cap and drops the remainder, and a near-boundary
-- delta leaves a negative float residual in the drop branch, so the clamp is
-- a real invariant, not a formality.
function T.render_alpha_stays_in_unit_range_after_extreme_deltas()
  local session, _, _, _ = warpSession({
    fieldX = 4,
    fieldZ = 14,
    warpX = 4,
    warpZ = 14,
  })
  local function assertInRange(label)
    local alpha = session:renderAlpha()
    Assert.isTrue(alpha >= 0 and alpha <= 1, label .. " renderAlpha out of [0, 1]: " .. tostring(alpha))
  end
  -- A near-boundary delta leaves a negative float residual in the drop
  -- branch, so the clamp is a real invariant, not a formality.
  session:update(1.8)
  assertInRange("drop")
  -- A huge delta saturates the catch-up cap and drops the remainder.
  session:update(600)
  assertInRange("catch-up")
end

-- The session captures the player's walking state before the movement update
-- and hands it to the pose clock, so a two-tile walk (16 ticks, the ROM's full
-- gait range) keeps one continuous phase instead of restarting at each commit.
function T.a_two_tile_walk_keeps_one_phase_across_the_session_ticks()
  local map = {
    mapId = 61,
    cameraType = 4,
    coordinateOrigin = { x = 0, z = 0 },
    fieldData = { events = { warps = {} } },
    updateAnimated = function() end,
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      isBlockedLocal = function()
        return false
      end,
    },
    terrain = TerrainSurface.new({
      plates = {
        {
          id = 0,
          minX = 0,
          minZ = 0,
          maxX = 32,
          maxZ = 32,
          normal = { x = 0, y = 1, z = 0 },
          distance = 0,
          slopeClass = "flat",
        },
      },
    }),
  }
  local player = FieldPlayer.new({
    currentMap = map,
    fieldX = 4,
    fieldZ = 13,
    surfaceId = 0,
    facing = "east",
    occupancy = function()
      return nil
    end,
  })
  local visual = FieldPlayerVisual.new({
    player = player,
    spriteId = 0,
  })
  local camera = { updateFixed = function() end }
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    playerVisual = visual,
  }))

  session:updateFixed({ heldDirection = "east", pressedDirection = "east" })
  for _ = 2, 16 do
    session:updateFixed({ heldDirection = "east" })
  end

  Assert.equal(player.fieldX, 6, "two eight-tick steps committed")
  Assert.equal(player.motion, "idle")
  Assert.equal(visual.pose, "walk")
  Assert.equal(visual.poseTick, 16, "the session never lets the gait phase restart mid-walk")
end

function T.held_direction_walks_only_after_turn_completion_reenters_idle_arbitration()
  local map = {
    mapId = 61,
    cameraType = 4,
    coordinateOrigin = { x = 0, z = 0 },
    fieldData = { events = { warps = {} } },
    updateAnimated = function() end,
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      isBlockedLocal = function()
        return false
      end,
      getLocal = function()
        return { behavior = nil }
      end,
    },
    terrain = TerrainSurface.new({
      plates = {
        {
          id = 0,
          minX = 0,
          minZ = 0,
          maxX = 32,
          maxZ = 32,
          normal = { x = 0, y = 1, z = 0 },
          distance = 0,
          slopeClass = "flat",
        },
      },
    }),
  }
  local player = FieldPlayer.new({
    currentMap = map,
    fieldX = 4,
    fieldZ = 13,
    surfaceId = 0,
    facing = "east",
  })
  local session = FieldSession.new(baseOptions({ currentMap = map, player = player }))

  session:updateFixed({ heldDirection = "north", pressedDirection = "north" })
  Assert.equal(player.motion, "turning")
  Assert.equal(player.fieldZ, 13)

  session:updateFixed({ heldDirection = "north" })
  Assert.equal(player.motion, "idle")
  Assert.equal(player.fieldZ, 13)

  session:updateFixed({ heldDirection = "north" })
  Assert.equal(player.motion, "walking")
  Assert.equal(player.fieldZ, 13)
  Assert.equal(player.facing, "north")
end

-- A locked door transition reports whether the choreography moved the player
-- this tick; the session then advances the pose clock (only on moved ticks),
-- the camera (every locked tick, so interpolation pairs never replay), and
-- the scene's animated props -- the door opening/closing -- while everything
-- else stays frozen.
function T.door_transition_ticks_advance_the_world_while_locked()
  local visualSteps, cameraSteps, animatedSteps = 0, 0, 0
  local transition = {
    phase = "fade_out",
    locked = true,
    moved = false,
    updateFixed = function(self)
      return self.moved
    end,
    start = function() end,
  }
  local player = {
    fieldX = 4,
    fieldZ = 14,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "walking",
    updateFixed = function()
      return false
    end,
  }
  local camera = {
    updateFixed = function()
      cameraSteps = cameraSteps + 1
    end,
  }
  local playerVisual = {
    updateFixed = function(_, walking)
      Assert.isTrue(walking, "the pose clock hears the mid-step tick")
      visualSteps = visualSteps + 1
    end,
  }
  local map = {
    mapId = 61,
    cameraType = 4,
    sceneRuntime = {
      updateAnimated = function()
        animatedSteps = animatedSteps + 1
      end,
    },
    updateAnimated = function(self)
      if self.sceneRuntime then
        self.sceneRuntime:updateAnimated()
      end
    end,
  }
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    transition = transition,
    playerVisual = playerVisual,
  }))

  transition.moved = true
  session:updateFixed({ heldDirection = "south" })
  Assert.equal(visualSteps, 1, "the walk pose advances during the choreography")
  Assert.equal(cameraSteps, 1, "the camera follows the ingress/egress")
  Assert.equal(animatedSteps, 1, "the door animation advances under the locked transition")

  transition.moved = false
  session:updateFixed({ heldDirection = "south" })
  Assert.equal(visualSteps, 1, "a standing door tick does not advance the pose clock")
  Assert.equal(cameraSteps, 2, "the camera still samples the standing player (no replayed interpolation)")
  Assert.equal(animatedSteps, 2, "the door open/close keeps advancing while the player stands")
end

-- A locked stair transition advances the scene's animated props and samples
-- the camera each tick but never reports locomotion: the climb is in place,
-- so the pose clock stays frozen while the props keep animating.
function T.stair_transition_ticks_advance_props_but_not_the_pose_clock()
  local visualSteps, cameraSteps, animatedSteps = 0, 0, 0
  local transition = {
    phase = "fade_out",
    locked = true,
    updateFixed = function()
      return false
    end,
    start = function() end,
  }
  local player = {
    fieldX = 3,
    fieldZ = 3,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "west",
    motion = "idle",
    updateFixed = function()
      return false
    end,
    collapseRenderInterpolation = function() end,
  }
  local camera = {
    updateFixed = function()
      cameraSteps = cameraSteps + 1
    end,
  }
  local playerVisual = {
    updateFixed = function()
      visualSteps = visualSteps + 1
    end,
  }
  local map = {
    mapId = 63,
    cameraType = 4,
    sceneRuntime = {
      updateAnimated = function()
        animatedSteps = animatedSteps + 1
      end,
    },
    updateAnimated = function(self)
      if self.sceneRuntime then
        self.sceneRuntime:updateAnimated()
      end
    end,
  }
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    transition = transition,
    playerVisual = playerVisual,
  }))

  session:updateFixed({ heldDirection = "west" })
  Assert.equal(animatedSteps, 1, "the scene props advance under the stair climb")
  Assert.equal(visualSteps, 0, "the in-place climb does not advance the pose clock")
  Assert.equal(cameraSteps, 1, "the camera samples the standing player (zero delta)")
  session:updateFixed({ heldDirection = "west" })
  Assert.equal(animatedSteps, 2, "the props keep advancing while the player stands")
  Assert.equal(cameraSteps, 2)
end

-- A plain locked transition advances the scene's animated props and samples
-- the camera, but never the pose clock: the scene clock runs on every locked
-- tick, while locomotion-driven state stays frozen.
function T.plain_locked_transition_stays_frozen()
  local visualSteps, cameraSteps, animatedSteps = 0, 0, 0
  local transition = {
    phase = "fade_out",
    locked = true,
    updateFixed = function()
      return false
    end,
    start = function() end,
  }
  local player = {
    fieldX = 4,
    fieldZ = 14,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "walking",
    updateFixed = function()
      return false
    end,
  }
  local camera = {
    updateFixed = function()
      cameraSteps = cameraSteps + 1
    end,
  }
  local playerVisual = {
    updateFixed = function()
      visualSteps = visualSteps + 1
    end,
  }
  local map = {
    mapId = 61,
    cameraType = 4,
    sceneRuntime = {
      updateAnimated = function()
        animatedSteps = animatedSteps + 1
      end,
    },
    updateAnimated = function(self)
      if self.sceneRuntime then
        self.sceneRuntime:updateAnimated()
      end
    end,
  }
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    transition = transition,
    playerVisual = playerVisual,
  }))
  session:updateFixed({})
  Assert.equal(visualSteps, 0, "no locomotion: the pose clock stays frozen")
  Assert.equal(cameraSteps, 1, "the camera still samples every locked tick")
  Assert.equal(animatedSteps, 1, "the scene clock advances on every locked tick")
end

-- The visual shake regression: during choreo_hold there is no player step, so
-- both the camera and player sprite must collapse stale interpolation pairs.
-- Otherwise every render interval replays the final fraction of the egress
-- step while the door animation runs. This is most visible as vertical shake
-- for north/south doors, whose Z movement projects vertically on screen.
function T.choreo_hold_ticks_never_replay_camera_or_player_interpolation()
  local FieldCamera = require("libs.hgss.src.field.FieldCamera")
  local profile = {
    projectionType = "orthographic",
    distanceTiles = 10,
    angleXRaw = 0,
    angleYRaw = 0,
    halfFovRadians = math.rad(45),
    fullVerticalFovRadians = math.rad(45),
    nearTiles = 1,
    farTiles = 100,
    targetOffsetTiles = { x = 0, y = 0, z = 0 },
  }
  local function matrixEquals(a, b)
    for i = 1, 16 do
      if math.abs(a[i] - b[i]) > 1e-9 then
        return false
      end
    end
    return true
  end

  local function pointEquals(a, b)
    return math.abs(a.x - b.x) <= 1e-9 and math.abs(a.y - b.y) <= 1e-9 and math.abs(a.z - b.z) <= 1e-9
  end

  local function runDoorClose(withVisual)
    local camera = FieldCamera.new(profile, { initialTarget = { x = 0, y = 0, z = 0 } })
    local map = {
      mapId = 61,
      cameraType = 4,
      coordinateOrigin = { x = 0, z = 0 },
      updateAnimated = function() end,
      collision = TilePermissions.new(),
      terrain = TerrainSurface.new({
        plates = {
          {
            id = 0,
            minX = 0,
            minZ = 0,
            maxX = 32,
            maxZ = 32,
            normal = { x = 0, y = 1, z = 0 },
            distance = 0,
            slopeClass = "flat",
          },
        },
      }),
    }
    local player = FieldPlayer.new({ currentMap = map, fieldX = 4, fieldZ = 14, surfaceId = 0, facing = "south" })
    Assert.isTrue(player:scriptedStep("south"))
    for _ = 1, FieldPlayer.WALK_STEP_TICKS do
      player:updateFixed({})
    end
    Assert.isFalse(
      pointEquals(player:renderPosition(0), player:renderPosition(1)),
      "the completed egress leaves one real interpolation pair"
    )
    local playerVisual = withVisual and {
      updateFixed = function() end,
    } or nil
    local transition = {
      phase = "choreo_hold",
      locked = true,
      updateFixed = function()
        return false
      end,
      start = function() end,
    }
    local session = FieldSession.new(baseOptions({
      currentMap = map,
      player = player,
      camera = camera,
      transition = transition,
      playerVisual = playerVisual,
    }))
    -- Prime the interpolation pair with a real movement.
    camera:updateFixed({ x = 2, y = 0, z = 2 })
    Assert.isFalse(matrixEquals(camera:view(0), camera:view(1)), "the primed pair differs")
    -- The first stationary door-close tick collapses the player's final step;
    -- the second also collapses the camera pair after its last real target.
    session:updateFixed({})
    Assert.isTrue(
      pointEquals(player:renderPosition(0), player:renderPosition(1)),
      "the first door-close tick settles player interpolation"
    )
    session:updateFixed({})
    Assert.isTrue(matrixEquals(camera:view(0), camera:view(1)), "no replayed interpolation while the door closes")
    -- The completion tick also samples before the session consumes it.
    transition.completed = { destinationMapId = 60 }
    session:updateFixed({})
    Assert.isTrue(matrixEquals(camera:view(0), camera:view(1)), "the completion tick samples the camera too")
  end

  runDoorClose(true)
  runDoorClose(false)
end

-- The scene animation clock also runs on script-locked ticks: a script that
-- takes movement ownership freezes the player but not the world's props.
function T.script_locked_ticks_still_advance_the_scene_clock()
  local animatedSteps = 0
  local player = {
    fieldX = 4,
    fieldZ = 14,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "idle",
    updateFixed = function()
      return false
    end,
  }
  local camera = { updateFixed = function() end }
  local map = {
    mapId = 61,
    cameraType = 4,
    sceneRuntime = {
      updateAnimated = function()
        animatedSteps = animatedSteps + 1
      end,
    },
    updateAnimated = function(self)
      if self.sceneRuntime then
        self.sceneRuntime:updateAnimated()
      end
    end,
  }
  local scheduler = {
    step = function() end,
    playerInputLocked = function()
      return true
    end,
    playerInputOwned = function()
      return true
    end,
    foregroundEnvironmentId = function()
      return "foreground"
    end,
  }
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    scriptScheduler = scheduler,
  }))
  session:updateFixed({})
  Assert.equal(animatedSteps, 1, "a script-locked tick advances the scene clock once")
  Assert.equal(session.tick, 1)
end

-- The field clock contract: FieldSession steps one aggregate map entry point
-- per fixed tick; FieldMapLoader owns the fan-out to the central scene
-- runtime and the neighbor coverage runtime. This fake mirrors that
-- aggregate so a branch can only pass by going through the map clock.
local function clockMap()
  local calls = { aggregate = 0, scene = 0, coverage = 0 }
  local map = {
    mapId = 61,
    cameraType = 4,
    sceneRuntime = {
      updateAnimated = function()
        calls.scene = calls.scene + 1
      end,
    },
    coverageRuntime = {
      updateAnimated = function()
        calls.coverage = calls.coverage + 1
      end,
    },
    updateAnimated = function(self)
      calls.aggregate = calls.aggregate + 1
      if self.sceneRuntime then
        self.sceneRuntime:updateAnimated()
      end
      if self.coverageRuntime then
        self.coverageRuntime:updateAnimated()
      end
    end,
  }
  return map, calls
end

-- An ordinary tick advances the central scene runtime and the neighbor
-- coverage runtime exactly once each, through the aggregate map clock.
function T.normal_ticks_advance_scene_and_coverage_once_through_the_map_clock()
  local map, calls = clockMap()
  local session = FieldSession.new(baseOptions({ currentMap = map }))
  session:updateFixed({})
  Assert.equal(calls.aggregate, 1, "the normal tick advances the aggregate map clock exactly once")
  Assert.equal(calls.scene, 1, "the central scene runtime advances exactly once")
  Assert.equal(calls.coverage, 1, "the coverage runtime advances exactly once")
  session:updateFixed({})
  Assert.equal(calls.aggregate, 2, "each normal tick advances the aggregate map clock exactly once")
  Assert.equal(calls.scene, 2, "each normal tick advances the scene runtime exactly once")
  Assert.equal(calls.coverage, 2, "each normal tick advances the coverage runtime exactly once")
end

-- A locked transition tick advances both runtimes exactly once through the
-- aggregate map clock, alongside the camera sampling and pose freezing.
function T.locked_transition_ticks_advance_scene_and_coverage_once_through_the_map_clock()
  local player = defaultPlayer()
  player.collapseRenderInterpolation = function() end
  local transition = {
    phase = "fade_out",
    locked = true,
    updateFixed = function()
      return false
    end,
    start = function() end,
  }
  local map, calls = clockMap()
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    transition = transition,
  }))
  session:updateFixed({})
  Assert.equal(calls.aggregate, 1, "the locked transition tick advances the aggregate map clock exactly once")
  Assert.equal(calls.scene, 1, "the central scene runtime advances exactly once")
  Assert.equal(calls.coverage, 1, "the coverage runtime advances exactly once")
end

-- A modal-dialogue tick owns the field while the world steps freeze, but the
-- scene clock keeps running: both runtimes advance exactly once through the
-- aggregate map clock.
function T.modal_dialogue_ticks_advance_scene_and_coverage_once_through_the_map_clock()
  local dialogue = {
    isModal = function()
      return true
    end,
    step = function() end,
  }
  local map, calls = clockMap()
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    dialogue = dialogue,
  }))
  session:updateFixed({})
  Assert.equal(calls.aggregate, 1, "the modal-dialogue tick advances the aggregate map clock exactly once")
  Assert.equal(calls.scene, 1, "the central scene runtime advances exactly once")
  Assert.equal(calls.coverage, 1, "the coverage runtime advances exactly once")
end

-- The application host is the one application modal owner: while it is
-- active, the session steps only the host (once per fixed tick, with the
-- tick's UI event list plus the synthesized menu edge) and freezes world
-- simulation -- no player step, no actor step, no scheduler step, no
-- interaction, no movement.
function T.application_host_owns_the_tick_and_freezes_world_simulation()
  local stepped = { player = 0, actors = 0, scheduler = 0, map = 0 }
  local player = defaultPlayer()
  player.updateFixed = function()
    stepped.player = stepped.player + 1
    return false
  end
  local actors = {
    step = function()
      stepped.actors = stepped.actors + 1
    end,
  }
  local scheduler = {
    step = function()
      stepped.scheduler = stepped.scheduler + 1
    end,
    playerInputLocked = function()
      return false
    end,
    playerInputOwned = function()
      return false
    end,
    foregroundEnvironmentId = function()
      return nil
    end,
  }
  local map = {
    mapId = 61,
    fieldData = { events = { warps = {} } },
    updateAnimated = function()
      stepped.map = stepped.map + 1
    end,
  }
  local host = applicationHostFake({ active = true })
  local input = idleInput()
  input.uiSnapshot = function()
    return { { type = "navigate", direction = "down" } }
  end
  local session = FieldSession.new(baseOptions({
    player = player,
    actors = actors,
    scriptScheduler = scheduler,
    currentMap = map,
    applicationHost = host,
    input = input,
  }))
  session:updateFixed({ menuPressed = true })
  Assert.equal(host.updateCalls, 1, "the host is stepped exactly once per tick")
  Assert.equal(host.events[1].type, "navigate", "the host receives the tick's UI events")
  Assert.equal(host.events[2].type, "menu", "a menu edge while active closes through the synthesized menu event")
  Assert.equal(stepped.player, 0, "the player is not stepped while the host owns the tick")
  Assert.equal(stepped.actors, 0, "actors are not stepped while the host owns the tick")
  Assert.equal(stepped.scheduler, 0, "the script scheduler is not stepped while the host owns the tick")
  Assert.equal(stepped.map, 0, "the scene animation clock is frozen while the host owns the tick")
  Assert.equal(session.tick, 1)
end

function T.while_the_host_is_active_no_other_modal_may_own_the_tick()
  local dialogue = {
    isModal = function()
      return true
    end,
  }
  local host = applicationHostFake({ active = true })
  local session = FieldSession.new(baseOptions({
    dialogue = dialogue,
    applicationHost = host,
  }))
  Assert.throws(function()
    session:updateFixed({})
  end)
end

-- The menu edge is checked after the script-scheduler step and before
-- actor stepping/interaction/warps/movement; an eligible open consumes the
-- tick so the same edge cannot also start a move or interaction.
function T.an_eligible_menu_edge_opens_the_menu_and_consumes_the_tick()
  local stepped = { player = 0, actors = 0 }
  local player = defaultPlayer()
  player.updateFixed = function()
    stepped.player = stepped.player + 1
    return false
  end
  local actors = {
    step = function()
      stepped.actors = stepped.actors + 1
    end,
  }
  local host = applicationHostFake()
  local session = FieldSession.new(baseOptions({
    player = player,
    actors = actors,
    applicationHost = host,
  }))
  session:updateFixed({ menuPressed = true })
  Assert.equal(host.openedTicks[1], 1, "the eligible menu edge opens the menu at the session tick")
  Assert.equal(stepped.player, 0, "a successful open consumes the tick")
  Assert.equal(stepped.actors, 0, "a successful open consumes the tick before actor stepping")
  Assert.equal(session.tick, 1)
end

function T.menu_wins_over_a_simultaneous_action_edge_at_an_eligible_boundary()
  local interactions = 0
  local host = applicationHostFake()
  local session = FieldSession.new(baseOptions({
    applicationHost = host,
    interactions = {
      resolve = function()
        interactions = interactions + 1
        return {}
      end,
    },
  }))
  session:updateFixed({ menuPressed = true, actionPressed = true })
  Assert.equal(host.openedTicks[1], 1, "the menu edge wins at an eligible boundary")
  Assert.equal(interactions, 0, "the cleared Action edge must not trigger the facing interaction")
end

-- A zero-action menu open is a no-op at the session boundary too: when the
-- host reports that nothing opened (requestOpen false), the tick is not
-- consumed by the open and the field continues stepping normally.
function T.an_open_that_opens_nothing_leaves_the_tick_to_the_field()
  local stepped = { player = 0, actors = 0 }
  local player = defaultPlayer()
  player.updateFixed = function()
    stepped.player = stepped.player + 1
    return false
  end
  local actors = {
    step = function()
      stepped.actors = stepped.actors + 1
    end,
  }
  local host = applicationHostFake()
  host.requestOpen = function(_, tick)
    host.openedTicks[#host.openedTicks + 1] = tick
    return false
  end
  local session = FieldSession.new(baseOptions({
    player = player,
    actors = actors,
    applicationHost = host,
  }))
  session:updateFixed({ menuPressed = true })
  Assert.equal(host.openedTicks[1], 1, "the eligible edge still reaches the open gate")
  Assert.equal(stepped.player, 1, "a no-op open must not consume the tick from the field")
  Assert.equal(stepped.actors, 1, "a no-op open must leave the field stepping normally")
  Assert.equal(session.tick, 1)
end

function T.an_ineligible_menu_edge_acquires_nothing()
  local host = applicationHostFake()
  local player = defaultPlayer()
  player.motion = "walking"
  local session = FieldSession.new(baseOptions({
    player = player,
    applicationHost = host,
  }))
  session:updateFixed({ menuPressed = true })
  Assert.equal(host.openedTicks[1], nil, "an ineligible open edge must not open the menu")
  Assert.equal(session.tick, 1, "the tick still advances normally")
end

function T.a_movement_lock_blocks_the_menu_edge()
  local host = applicationHostFake()
  local scheduler = {
    step = function() end,
    playerInputLocked = function()
      return true
    end,
    playerInputOwned = function()
      return true
    end,
    foregroundEnvironmentId = function()
      return "foreground"
    end,
  }
  local session = FieldSession.new(baseOptions({
    applicationHost = host,
    scriptScheduler = scheduler,
  }))
  session:updateFixed({ menuPressed = true })
  Assert.equal(host.openedTicks[1], nil, "a foreground script lock must block the open")
end

-- The script-side reopen request (opcode 61) is consumed at the same
-- arbitration point, unconditionally: a pending reopen opens the menu and
-- consumes the tick.
function T.a_pending_reopen_opens_the_menu_at_the_arbitration_point()
  local stepped = { player = 0 }
  local player = defaultPlayer()
  player.updateFixed = function()
    stepped.player = stepped.player + 1
    return false
  end
  local host = applicationHostFake()
  host:requestReopen()
  local session = FieldSession.new(baseOptions({
    player = player,
    applicationHost = host,
  }))
  session:updateFixed({})
  Assert.equal(host.openedTicks[1], 1, "the pending reopen opens the menu")
  Assert.equal(host.reopenRequests, 0, "the reopen request is consumed once")
  Assert.equal(stepped.player, 0, "the reopen open consumes the tick")
end

-- The faulting-tick freeze contract, proven through the real
-- FieldApplicationHost: the host's open/reopen return value is the session's
-- arbitration signal, so the real composition boundary decides whether the
-- field continues or freezes on the tick that pressed the menu edge.
local function applicationCompositionFixture(menuFactory)
  local worldSteps = { player = 0, actors = 0, camera = 0, resolved = 0 }
  local player = defaultPlayer()
  player.updateFixed = function()
    worldSteps.player = worldSteps.player + 1
    return false
  end
  local actors = {
    step = function()
      worldSteps.actors = worldSteps.actors + 1
    end,
  }
  local camera = {
    updateFixed = function()
      worldSteps.camera = worldSteps.camera + 1
    end,
  }
  local input = idleInput()
  input.beginUiTicks = {}
  input.beginUi = function(_, tick)
    input.beginUiTicks[#input.beginUiTicks + 1] = tick
  end
  input.clearUiCalls = 0
  input.clearUi = function()
    input.clearUiCalls = input.clearUiCalls + 1
  end
  ---@cast input FieldInput
  local host = FieldApplicationHost.new({
    registry = FieldApplicationRegistry.new({}),
    menuFactory = menuFactory,
    input = input,
    fieldAction = function() end,
  })
  local session = FieldSession.new(baseOptions({
    player = player,
    actors = actors,
    camera = camera,
    input = input,
    applicationHost = host,
    interactions = {
      resolve = function()
        worldSteps.resolved = worldSteps.resolved + 1
        return nil
      end,
    },
  }))
  return session, host, input, worldSteps
end

-- A fatal Start Menu composition failure consumes the faulting tick: the
-- host enters its terminal failed state, and the session must not fall
-- through to actor stepping, interaction resolution, player movement, or
-- the camera on that same tick. The simultaneous Action edge must not reach
-- the interaction resolver either: the failed open still owns the tick.
function T.a_fatal_menu_composition_failure_freezes_the_faulting_tick()
  local session, host, _, world = applicationCompositionFixture(function()
    error("injected menu composition failure")
  end)
  session:updateFixed({ menuPressed = true, actionPressed = true })
  Assert.equal(host:status().phase, "failed", "the host enters its terminal failed state")
  Assert.equal(host:isActive(), true, "the failed host stays active so later ticks freeze")
  Assert.equal(world.player, 0, "the faulting tick must not step the player")
  Assert.equal(world.actors, 0, "the faulting tick must not step actors")
  Assert.equal(world.resolved, 0, "the faulting tick must not resolve interactions")
  Assert.equal(world.camera, 0, "the faulting tick must not move the camera")
  Assert.equal(session.tick, 1)
end

-- The pending script reopen path obeys the same contract: a throwing
-- menuFactory consumes the faulting tick and freezes every world step.
function T.a_failing_pending_reopen_freezes_the_faulting_tick()
  local session, host, _, world = applicationCompositionFixture(function()
    error("injected reopen composition failure")
  end)
  host:requestReopen()
  session:updateFixed({})
  Assert.equal(host:status().phase, "failed", "the failing reopen enters the terminal failed state")
  Assert.equal(world.player, 0, "the faulting reopen tick must not step the player")
  Assert.equal(world.actors, 0, "the faulting reopen tick must not step actors")
  Assert.equal(world.camera, 0, "the faulting reopen tick must not move the camera")
  Assert.equal(session.tick, 1)
end

-- An unavailable menu (nil factory result) stays a genuine no-op at the
-- session boundary: the host stays closed, no UI lifetime begins, and the
-- field continues stepping normally on the same tick.
function T.an_unavailable_menu_leaves_the_tick_to_the_field()
  local session, host, input, world = applicationCompositionFixture(function()
    return nil
  end)
  session:updateFixed({ menuPressed = true })
  Assert.equal(host:status().phase, "closed", "an unavailable menu is a no-op open")
  Assert.equal(host:isActive(), false)
  local beginUiTicks = assert(rawget(input, "beginUiTicks"))
  Assert.equal(beginUiTicks[1], nil, "an unavailable menu begins no UI lifetime")
  Assert.equal(world.player, 1, "an unavailable menu leaves the tick to the field")
  Assert.equal(world.actors, 1)
  Assert.equal(world.camera, 1)
end

-- A successful open keeps its existing contract: the host enters the menu
-- phase, beginUi happens exactly once on the opening tick, the opener tick
-- never steps the menu controller, and the world stays frozen.
function T.a_successful_open_consumes_the_tick_without_stepping_the_world()
  local menu = {
    updateFixedCalls = 0,
    disposeCount = 0,
  }
  function menu:updateFixed()
    self.updateFixedCalls = self.updateFixedCalls + 1
  end
  function menu:takeResult()
    return nil
  end
  function menu:status()
    return { open = true }
  end
  function menu:dispose()
    self.disposeCount = self.disposeCount + 1
  end
  function menu:cancelPointerCapture() end
  local session, host, input, world = applicationCompositionFixture(function()
    return menu
  end)
  session:updateFixed({ menuPressed = true })
  Assert.equal(host:status().phase, "menu", "the host enters the menu phase")
  Assert.equal(host:isActive(), true)
  local beginUiTicks = assert(rawget(input, "beginUiTicks"))
  Assert.equal(beginUiTicks[1], 1, "beginUi happens once on the opening tick")
  Assert.equal(menu.updateFixedCalls, 0, "the opener tick never steps the menu controller")
  Assert.equal(world.player, 0, "the successful open consumes the tick")
  Assert.equal(world.actors, 0)
  Assert.equal(world.camera, 0)
  Assert.equal(session.tick, 1)
end

-- The ordinary field-audio event is the completed step: only a committing
-- tick advances the soundplate selection (not every fixed tick, and not the
-- modal early-return ticks). While movement is stalled or locked the tick
-- carries no audio event.
function T.audio_update_field_runs_once_per_completed_step_before_early_returns()
  local audioCalls = 0
  local committed = false
  local state = { transitionLocked = false, dialogueModal = false, scriptLocked = false }
  local audio = {
    updateField = function()
      audioCalls = audioCalls + 1
    end,
    play = function() end,
  }
  local transition = {
    phase = "idle",
    locked = false,
    updateFixed = function(self)
      self.locked = state.transitionLocked
    end,
    start = function()
      error("idle transition must never start a warp", 2)
    end,
  }
  local map = {
    mapId = 61,
    fieldData = { events = { warps = {} } },
    updateAnimated = function() end,
  }
  local dialogue = {
    isModal = function()
      return state.dialogueModal
    end,
    step = function() end,
  }
  local scheduler = {
    step = function() end,
    playerInputLocked = function()
      return state.scriptLocked
    end,
    playerInputOwned = function()
      return state.scriptLocked
    end,
    foregroundEnvironmentId = function()
      return state.scriptLocked and "foreground" or nil
    end,
  }
  local player = {
    fieldX = 4,
    fieldZ = 13,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "idle",
    updateFixed = function()
      if committed then
        committed = false
        return true
      end
      return false
    end,
    collapseRenderInterpolation = function() end,
  }
  local camera = { updateFixed = function() end }
  local s = FieldSession.new(baseOptions({
    audio = audio,
    currentMap = map,
    player = player,
    camera = camera,
    transition = transition,
    dialogue = dialogue,
    scriptScheduler = scheduler,
  }))

  s:updateFixed({})
  Assert.equal(audioCalls, 0, "an idle tick with no completed step carries no audio event")
  committed = true
  s:updateFixed({})
  Assert.equal(audioCalls, 1, "a committing tick runs the field audio once")
  state.transitionLocked = true
  s:updateFixed({})
  Assert.equal(audioCalls, 1, "a locked transition tick carries no ordinary audio")
  state.transitionLocked = false
  state.dialogueModal = true
  s:updateFixed({})
  Assert.equal(audioCalls, 1, "a modal dialogue tick carries no ordinary audio")
  state.dialogueModal = false
  state.scriptLocked = true
  s:updateFixed({})
  Assert.equal(audioCalls, 1, "a script-locked tick carries no ordinary audio")
end

-- The session's audio work is limited to field policy and semantic effects: an
-- audio collaborator that records both calls and exposes no separate sound-frame
-- method proves the session does not step semantic audio. FieldRuntime
-- composes that stage after each fixed field tick. A completing-step tick runs
-- the field event once; idle/modal ticks do not.
function T.field_policy_runs_once_per_completed_step_without_stepping_semantic_audio()
  local fieldCalls = 0
  local audio = {
    updateField = function()
      fieldCalls = fieldCalls + 1
    end,
    play = function() end,
  }
  local transition = {
    phase = "idle",
    locked = false,
    updateFixed = function() end,
    start = function()
      error("idle transition must never start a warp", 2)
    end,
  }
  local map = {
    mapId = 61,
    fieldData = { events = { warps = {} } },
    updateAnimated = function() end,
  }
  local dialogue = {
    isModal = function()
      return false
    end,
    step = function() end,
  }
  local scheduler = {
    step = function() end,
    playerInputLocked = function()
      return false
    end,
    playerInputOwned = function()
      return false
    end,
    foregroundEnvironmentId = function()
      return nil
    end,
  }
  local committed = false
  local player = {
    fieldX = 4,
    fieldZ = 13,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "idle",
    updateFixed = function()
      if committed then
        committed = false
        return true
      end
      return false
    end,
    collapseRenderInterpolation = function() end,
  }
  local camera = { updateFixed = function() end }
  local s = FieldSession.new(baseOptions({
    audio = audio,
    currentMap = map,
    player = player,
    camera = camera,
    transition = transition,
    dialogue = dialogue,
    scriptScheduler = scheduler,
  }))

  s:updateFixed({})
  Assert.equal(fieldCalls, 0, "an idle tick carries no field-audio event")
  committed = true
  s:updateFixed({})
  Assert.equal(fieldCalls, 1, "a completing-step tick runs the field-audio event once")
  s:updateFixed({})
  Assert.equal(fieldCalls, 1, "an idle follow-up tick carries no further event")
end

function T.map_entry_waits_for_yielding_transition_before_entering_actors()
  local starts = {}
  local order = {}
  local scheduler = {
    busy = false,
    step = function(self)
      order[#order + 1] = "scheduler"
      self.busy = false
    end,
    playerInputLocked = function(self)
      return self.busy
    end,
    playerInputOwned = function(self)
      return self.busy
    end,
    foregroundEnvironmentId = function(self)
      return self.busy and "transition" or nil
    end,
  }
  local controller = {
    hasLifecycle = function(_, lifecycle)
      return lifecycle == "on_transition" or lifecycle == "on_load" or lifecycle == "on_resume"
    end,
    startLifecycle = function(_, lifecycle, tick)
      starts[#starts + 1] = { lifecycle = lifecycle, tick = tick }
      order[#order + 1] = lifecycle
      if lifecycle == "on_transition" then
        scheduler.busy = true
      end
      return true
    end,
    evaluateFrame = function(_, tick)
      order[#order + 1] = "frame:" .. tick
      return true
    end,
  }
  local entered = 0
  local session = FieldSession.new(baseOptions({
    initController = controller,
    scriptScheduler = scheduler,
    enterMapActors = function()
      entered = entered + 1
      order[#order + 1] = "actors"
    end,
  }))

  session:beginMapEntry()
  session:updateFixed({})
  Assert.equal(entered, 0, "yielding transition keeps destination actors out")
  session:updateFixed({})
  Assert.equal(entered, 0, "actors remain blocked on the scheduler completion tick")
  session:updateFixed({})
  Assert.equal(entered, 1, "actor entry follows transition completion")
  Assert.equal(order[1], "on_transition")
  Assert.equal(order[#order], "actors")
end

-- A seamless logical-zone change is a connection entry: it runs only the
-- destination's transition-init lifecycle, activates destination actors
-- exactly once, and defers the arrival tile's event until activation
-- completes. The arrival kind selects which event the destination tile
-- carries; everything else about the crossing is identical.
---@param arrivalKind "coordinate"|"passive"
---@return table
local function connectionSeamScenario(arrivalKind)
  local scenario = { order = {}, entered = 0, arrivalResolves = 0, consumedIntents = {} }
  local order = scenario.order
  local sourceMap = {
    mapId = 61,
    fieldData = { events = { warps = {}, background = {}, coordinates = {} } },
    updateAnimated = function() end,
  }
  local destinationMap = {
    mapId = 62,
    fieldData = { events = { warps = {}, background = {}, coordinates = {} } },
    updateAnimated = function() end,
  }
  scenario.destinationMap = destinationMap
  local scheduler = {
    busy = false,
    step = function(self)
      order[#order + 1] = "scheduler"
      self.busy = false
    end,
    playerInputLocked = function(self)
      return self.busy
    end,
    playerInputOwned = function(self)
      return self.busy
    end,
    foregroundEnvironmentId = function(self)
      return self.busy and "transition" or nil
    end,
  }
  local controller = {
    hasLifecycle = function(_, lifecycle)
      return lifecycle == "on_transition" or lifecycle == "on_load" or lifecycle == "on_resume"
    end,
    startLifecycle = function(_, lifecycle)
      order[#order + 1] = lifecycle
      if lifecycle == "on_transition" then
        scheduler.busy = true
      end
      return true
    end,
  }
  local stepCompletedOnce = false
  local player = defaultPlayer()
  player.updateFixed = function()
    if stepCompletedOnce then
      return false
    end
    stepCompletedOnce = true
    return true
  end
  player.collapseRenderInterpolation = function() end
  -- The destination tile carries exactly one arrival event; the other
  -- resolver answers nothing, as an ordinary tile would.
  local function resolveArrival(kind)
    if kind ~= arrivalKind then
      return nil
    end
    scenario.arrivalResolves = scenario.arrivalResolves + 1
    return { kind = kind }
  end
  scenario.session = FieldSession.new(baseOptions({
    currentMap = sourceMap,
    player = player,
    initController = controller,
    scriptScheduler = scheduler,
    navigationBoundary = {
      zoneController = { currentMap = destinationMap },
      afterCommittedMove = function()
        return { newMapId = destinationMap.mapId }
      end,
    },
    scriptClient = {
      consume = function(_, intent)
        scenario.consumedIntents[#scenario.consumedIntents + 1] = intent
        order[#order + 1] = "arrival"
        return ScriptInteractionClient.RESULTS.started
      end,
    },
    eventResolver = {
      resolveCoordinate = function()
        return resolveArrival("coordinate")
      end,
      resolvePassiveSign = function()
        return resolveArrival("passive")
      end,
    },
    enterMapActors = function()
      scenario.entered = scenario.entered + 1
      order[#order + 1] = "actors"
    end,
  }))
  return scenario
end

-- Runs destination transition init to completion, then actor entry, then the
-- deferred arrival event.
local function advanceUntilArrivalConsumed(scenario)
  for _ = 1, 8 do
    if scenario.entered > 0 and #scenario.consumedIntents > 0 then
      return
    end
    scenario.session:updateFixed({})
  end
end

-- Asserts the one ordering the connection lifecycle exists to guarantee:
-- transition init, then actor activation, then the arrival event -- and no
-- full-entry-only lifecycle in between.
local function assertDeferredArrivalOrder(scenario)
  local transitionIndex, actorsIndex, arrivalIndex
  for index, item in ipairs(scenario.order) do
    if item == "on_transition" and transitionIndex == nil then
      transitionIndex = index
    elseif item == "actors" and actorsIndex == nil then
      actorsIndex = index
    elseif item == "arrival" and arrivalIndex == nil then
      arrivalIndex = index
    end
    Assert.isFalse(item == "on_load", "a connection entry must never run on_load")
    Assert.isFalse(item == "on_resume", "a connection entry must never run on_resume")
  end
  Assert.isTrue(transitionIndex ~= nil, "destination on_transition must run")
  Assert.isTrue(actorsIndex ~= nil and transitionIndex < actorsIndex, "actor entry must follow transition init")
  Assert.isTrue(
    arrivalIndex ~= nil and actorsIndex < arrivalIndex,
    "the arrival event must be consumed only after actor entry"
  )
end

function T.seamless_zone_change_defers_the_arrival_coordinate_until_destination_activation_completes()
  local scenario = connectionSeamScenario("coordinate")
  local session = scenario.session

  -- The completed movement tick crosses the seam.
  session:updateFixed({})
  Assert.equal(session.currentMap, scenario.destinationMap, "the seam crossing must switch the active map")
  Assert.isTrue(
    session:destinationWorldPresentable(),
    "a seamless connection must remain presentable throughout its lifecycle"
  )
  Assert.equal(scenario.arrivalResolves, 0, "the destination coordinate must not resolve on the crossing tick itself")
  Assert.equal(scenario.entered, 0, "destination actors must not enter before destination transition init runs")

  advanceUntilArrivalConsumed(scenario)

  Assert.equal(scenario.entered, 1, "destination actors must enter exactly once")
  Assert.equal(#scenario.consumedIntents, 1, "the deferred landing coordinate must be consumed exactly once")
  Assert.equal(scenario.consumedIntents[1].kind, "coordinate")
  assertDeferredArrivalOrder(scenario)
end

-- A crossing that lands on a passive-sign tile defers the sign exactly as it
-- defers a landing coordinate, and the one-shot marker must never replay it.
function T.seamless_zone_change_defers_the_arrival_passive_sign_until_destination_activation_completes()
  local scenario = connectionSeamScenario("passive")
  local session = scenario.session

  session:updateFixed({})
  Assert.equal(scenario.arrivalResolves, 0, "the arrival passive sign must not resolve on the crossing tick itself")
  Assert.equal(scenario.entered, 0, "destination actors must not enter before destination transition init runs")

  advanceUntilArrivalConsumed(scenario)

  Assert.equal(scenario.entered, 1, "destination actors must enter exactly once")
  Assert.equal(#scenario.consumedIntents, 1, "the deferred arrival passive sign must be consumed exactly once")
  Assert.equal(scenario.consumedIntents[1].kind, "passive")
  assertDeferredArrivalOrder(scenario)

  session:updateFixed({})
  Assert.equal(#scenario.consumedIntents, 1, "the arrival passive sign must not replay on a later tick")
end

function T.zone_change_owns_crossing_audio_selection_while_same_zone_keeps_step_audio()
  local function run(zoneChanged)
    local events = {}
    local map = {
      mapId = 61,
      fieldData = { events = { warps = {}, background = {}, coordinates = {} } },
      updateAnimated = function() end,
    }
    local player = defaultPlayer()
    player.updateFixed = function()
      return true
    end
    local audio = {
      updateField = function()
        events[#events + 1] = "ordinary audio"
      end,
      play = function() end,
    }
    local boundary = {
      zoneController = { currentMap = map },
      afterCommittedMove = function()
        if zoneChanged then
          events[#events + 1] = "zone-entry audio"
          return { newMapId = 62 }
        end
        return nil
      end,
    }
    local session = FieldSession.new(baseOptions({
      audio = audio,
      currentMap = map,
      player = player,
      navigationBoundary = boundary,
      -- A seamless crossing starts a connection map entry, so the lifecycle
      -- controller production always supplies is required here too.
      initController = {
        hasLifecycle = function()
          return false
        end,
        startLifecycle = function()
          return true
        end,
      },
    }))
    session:updateFixed({})
    return events
  end

  Assert.deepEqual(
    run(true),
    { "zone-entry audio" },
    "a zone-changing completed step must not repeat ordinary field audio"
  )
  Assert.deepEqual(
    run(false),
    { "ordinary audio" },
    "a same-zone completed step must keep one ordinary field-audio update"
  )
end

-- These tests use the real player and session together over a small flat field.
-- Only the collision/event/audio seams are deterministic fixtures; movement
-- classification and fixed-duration motion remain production behavior.
local function movementMap(tiles)
  local permissions = TilePermissions.new(tiles)
  local getLocal = permissions.getLocal
  permissions.getLocal = function(self, localX, localZ)
    local record = getLocal(self, localX, localZ)
    return { behavior = record.behavior, blocked = record.hardBlocked == true }
  end
  return {
    mapId = 61,
    coordinateOrigin = { x = 0, z = 0 },
    fieldData = { events = { warps = {}, background = {}, coordinates = {} } },
    collision = permissions,
    terrain = TerrainSurface.new({
      plates = {
        {
          id = 0,
          minX = 0,
          minZ = 0,
          maxX = 32,
          maxZ = 32,
          normal = { x = 0, y = 1, z = 0 },
          distance = 0,
          slopeClass = "flat",
        },
      },
    }),
    updateAnimated = function() end,
  }
end

local function movementSession(options)
  options = options or {}
  local map = options.map or movementMap(options.tiles)
  local player = options.player
    or FieldPlayer.new({
      currentMap = map,
      fieldX = options.fieldX or 0,
      fieldZ = options.fieldZ or 4,
      surfaceId = 0,
      facing = options.facing or "east",
      occupancy = options.occupancy,
    })
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    audio = options.audio,
    transition = options.transition,
    scriptScheduler = options.scriptScheduler,
    scriptClient = options.scriptClient,
    eventResolver = options.eventResolver,
  }))
  return session, player, map
end

local function ledgeSession(options)
  options = options or {}
  local tiles = options.tiles or { ["1:4"] = { behavior = MetatileBehavior.BEHAVIOR.JUMP_EAST } }
  local map = movementMap(tiles)
  local played = {}
  local player = FieldPlayer.new({
    currentMap = map,
    fieldX = 0,
    fieldZ = 4,
    surfaceId = 0,
    facing = options.facing or "east",
    occupancy = options.occupancy,
  })
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    audio = {
      updateField = function() end,
      play = function(_, idOrSymbol)
        played[#played + 1] = idOrSymbol
      end,
    },
  }))
  return session, player, played
end

function T.accepted_ledge_starts_one_audio_effect_and_lands_silently()
  local session, player, played = ledgeSession()
  session:updateFixed({ heldDirection = "east", pressedDirection = "east" })
  Assert.equal(player.motion, "jumping", "an accepted ledge must enter jumping on its start tick")
  Assert.deepEqual(played, { "SEQ_SE_DP_DANSA" }, "the ledge start must emit its effect once")

  for _ = 1, 14 do
    session:updateFixed({ heldDirection = "east" })
    Assert.equal(player.motion, "jumping", "the ledge must remain in flight before its final tick")
  end
  session:updateFixed({ heldDirection = "east" })
  Assert.equal(player.motion, "idle", "the ledge must land on its sixteenth update")
  Assert.deepEqual(played, { "SEQ_SE_DP_DANSA" }, "landing must not emit a second ledge effect")
end

function T.rejected_ledge_attempts_and_ordinary_steps_stay_silent()
  local cases = {
    {
      name = "wrong direction",
      facing = "north",
      direction = "north",
    },
    {
      name = "blocked landing",
      tiles = {
        ["1:4"] = { behavior = MetatileBehavior.BEHAVIOR.JUMP_EAST },
        ["2:4"] = { blocked = true },
      },
      direction = "east",
    },
    {
      name = "occupied landing",
      occupancy = function(candidate)
        return candidate.fieldX == 2 and candidate.fieldZ == 4 and "map:61:object:0" or nil
      end,
      direction = "east",
    },
    {
      name = "ordinary floor",
      tiles = {},
      direction = "east",
    },
  }
  for _, case in ipairs(cases) do
    local session, player, played = ledgeSession(case)
    session:updateFixed({ heldDirection = case.direction, pressedDirection = case.direction })
    Assert.isFalse(player.motion == "jumping", case.name .. " must not start a jump")
    Assert.deepEqual(played, {}, case.name .. " must not emit a ledge effect")
  end
end

local function completeWalkWithBoundaryInput(session, direction)
  session:updateFixed({ heldDirection = "east", pressedDirection = "east" })
  for _ = 1, 6 do
    session:updateFixed({})
  end
  session:updateFixed({ heldDirection = direction, pressedDirection = direction })
end

function T.final_walk_tick_direction_survives_release_for_one_admission()
  local session, player = movementSession()
  completeWalkWithBoundaryInput(session, "north")
  Assert.equal(player.motion, "idle", "the completion tick must settle the walk")
  Assert.equal(player.fieldX, 1)

  session:updateFixed({ heldDirection = "south", pressedDirection = "south" })
  Assert.equal(player.motion, "turning", "the carried completion direction must outrank newer raw movement input")
  Assert.equal(player.facing, "north")
  session:updateFixed({})
  Assert.equal(player.motion, "idle")
  session:updateFixed({})
  Assert.equal(player.motion, "idle", "the one-boundary direction must not replay")
end

function T.released_precompletion_walk_tap_is_not_remembered()
  local session, player = movementSession()
  session:updateFixed({ heldDirection = "east", pressedDirection = "east" })
  session:updateFixed({ pressedDirection = "north" })
  for _ = 1, 6 do
    session:updateFixed({})
  end
  session:updateFixed({})
  Assert.equal(player.motion, "idle", "an earlier released tap must not start a turn")
  Assert.equal(player.facing, "east")
  Assert.equal(player.fieldX, 1)
end

function T.turn_completion_uses_the_same_one_boundary_direction()
  local session, player = movementSession({ facing = "south" })
  session:updateFixed({ heldDirection = "north", pressedDirection = "north" })
  Assert.equal(player.motion, "turning")
  session:updateFixed({ pressedDirection = "west" })
  Assert.equal(player.motion, "idle", "the turn must complete on its second update")
  Assert.equal(player.facing, "north")

  session:updateFixed({ heldDirection = "west" })
  Assert.equal(player.motion, "turning", "turn completion input must remain a fresh command")
  Assert.equal(player.facing, "west")
  session:updateFixed({})
  session:updateFixed({})
  Assert.equal(player.motion, "idle", "turn completion input must not replay")

  local absentSession, absentPlayer = movementSession({ facing = "south" })
  absentSession:updateFixed({ heldDirection = "north", pressedDirection = "north" })
  absentSession:updateFixed({})
  absentSession:updateFixed({})
  Assert.equal(absentPlayer.motion, "idle", "a direction absent on the turn boundary must not be remembered")
end

local function eventBoundarySession(kind)
  local tiles = {}
  local warps = {}
  if kind == "standing" then
    tiles["1:4"] = { behavior = MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_NORTH }
    warps[1] = { index = 0, x = 1, z = 4, destinationMapId = 60, destinationWarpId = 0, y = 0 }
  end
  local map = movementMap(tiles)
  map.fieldData.events.warps = warps
  local lockTicks = 0
  local consumed = 0
  local transitionStarts = 0
  local scheduler = {
    step = function()
      if lockTicks > 0 then
        lockTicks = lockTicks - 1
      end
    end,
    playerInputOwned = function()
      return lockTicks > 0
    end,
    foregroundEnvironmentId = function()
      return lockTicks > 0 and "script" or nil
    end,
  }
  local transition = {
    phase = "idle",
    locked = false,
    updateFixed = function(self)
      if self.locked then
        if self.holdTicks > 0 then
          self.holdTicks = self.holdTicks - 1
        else
          self.locked = false
          self.phase = "idle"
        end
      end
    end,
    start = function(self)
      transitionStarts = transitionStarts + 1
      self.locked = true
      self.phase = "fade_out"
      self.holdTicks = 2
    end,
  }
  local eventResolver = {
    resolveCoordinate = function()
      return kind == "coordinate" and { kind = "coordinate" } or nil
    end,
    resolvePassiveSign = function()
      return nil
    end,
  }
  local scriptClient = {
    consume = function()
      consumed = consumed + 1
      lockTicks = 2
      return ScriptInteractionClient.RESULTS.started
    end,
  }
  local session, player = movementSession({
    map = map,
    transition = transition,
    scriptScheduler = scheduler,
    scriptClient = scriptClient,
    eventResolver = eventResolver,
  })
  return session, player, function()
    return consumed, transitionStarts
  end
end

function T.step_owned_events_discard_completion_direction_after_ownership_ends()
  for _, kind in ipairs({ "coordinate", "standing" }) do
    local session, player, observations = eventBoundarySession(kind)
    completeWalkWithBoundaryInput(session, "north")
    local consumed, transitionStarts = observations()
    if kind == "coordinate" then
      Assert.equal(consumed, 1, "the coordinate event must own the completed-step boundary")
      Assert.equal(transitionStarts, 0)
    else
      Assert.equal(consumed, 0)
      Assert.equal(transitionStarts, 1, "the standing transition must own the completed-step boundary")
    end
    Assert.equal(player.fieldX, 1)
    Assert.equal(player.fieldZ, 4)

    for _ = 1, 3 do
      session:updateFixed({})
    end
    Assert.equal(player.motion, "idle", kind .. " ownership must release before the neutral check")
    Assert.equal(player.facing, "east", kind .. " ownership must discard the completion direction")
    Assert.equal(player.fieldX, 1)
    Assert.equal(player.fieldZ, 4)
  end
end

function T.warp_gestures_remain_idle_while_vertical_offset_progresses_through_composed_session()
  local function runWarp(gestureName, expectedOffsets)
    local map = movementMap()
    local player = FieldPlayer.new({ currentMap = map, fieldX = 2, fieldZ = 3, surfaceId = 0, facing = "south" })
    local visual = FieldPlayerVisual.new({ player = player, spriteId = 0 })
    local initialY = player.worldY
    local dummyManager = {
      getActor = function()
        return nil
      end,
      show = function() end,
      hide = function() end,
      setPosition = function() end,
      setFacing = function() end,
      setMovementType = function() end,
      setAnimationPaused = function() end,
      getPosition = function()
        error("unexpected manager getPosition")
      end,
      getFacing = function()
        error("unexpected manager getFacing")
      end,
      numericId = function()
        return nil
      end,
      actorIdForMapIndex = function()
        return nil
      end,
      cameraTargetId = function()
        return nil
      end,
      partnerId = function()
        return nil
      end,
      isVisible = function()
        return true
      end,
      setPresentationOffset = function() end,
      clearPresentationOffset = function() end,
    }
    local facade = {
      position = function()
        return { fieldX = player.fieldX, fieldZ = player.fieldZ, worldY = player.worldY }
      end,
      facing = function()
        return player.facing
      end,
      turn = function(_, dir)
        player:turn(dir)
      end,
      setPosition = function(_, pos)
        player:setScriptPosition(pos)
      end,
      beginScriptedAction = function(_, a)
        player:beginScriptedAction(a)
      end,
      advanceScriptedAction = function(_, p, d)
        player:advanceScriptedAction(p, d)
      end,
      commitScriptedAction = function(_)
        player:commitScriptedAction()
      end,
      cancelScriptedMovement = function(_)
        player:cancelScriptedMovement()
      end,
      isScriptedMoving = function(_)
        return player:isScriptedMoving()
      end,
      gender = function()
        return 0
      end,
      name = function()
        return "Gold"
      end,
    }
    local world = ScriptActorWorld.new(dummyManager --[[@as ScriptActorManager]], facade)
    local services = FakeServices.new()
    services.actors = world --[[@as unknown as ScriptActorManager]]
    services.player = facade --[[@as unknown as FieldPlayer]]
    local registry = Registry.new()
    local composition = Composition.new(registry)
    local taskRegistry = TaskRegistry.new()
    taskRegistry:register("wait_ticks", 1, WaitTicksTask --[[@as unknown as TaskImplementation]])
    taskRegistry:register("movement", 1, MovementTask --[[@as unknown as TaskImplementation]])
    local scheduler = Scheduler.new({
      services = services,
      taskRegistry = taskRegistry,
      semantics = require("libs.hgss.src.script.RuntimeValues"),
      resolveComposition = function(id)
        return composition:effective(id)
      end,
    })
    local resource = S.script({ api = 1, id = "test.warp_" .. gestureName, steps = { S.waitTicks({ ticks = 100 }) } })
    registry:installBase(resource.id, resource, "generated")
    local composed = assert(composition:effective(resource.id))
    local instanceId = scheduler:createForeground(composed, nil, 0, true)
    local instance = assert(scheduler:instance(instanceId))
    scheduler:createTask(
      "movement",
      { actor = "player", sequence = { { action = "gesture", name = gestureName } }, blocking = true },
      instance,
      0,
      nil
    )
    local camera = { updateFixed = function() end }
    local session = FieldSession.new(baseOptions({
      currentMap = map,
      player = player,
      camera = camera,
      playerVisual = visual,
      scriptScheduler = scheduler,
    }))
    for tick = 1, 20 do
      session:updateFixed({})
      local status = visual:status()
      Assert.equal(status.pose, "idle", gestureName .. " tick " .. tick .. " must stay idle through session")
      Assert.equal(status.poseTick, 0, gestureName .. " tick " .. tick .. " poseTick stays 0")
      local record = visual:drawRecord(0)
      Assert.isNil(record.gesturePose, gestureName .. " has no clip")
      Assert.isNil(record.gestureTick)
      local expectedOffset = expectedOffsets[tick]
      Assert.near(record.world.y, initialY + expectedOffset, 1e-9, gestureName .. " tick " .. tick .. " offset")
      Assert.equal(player.worldY, initialY, gestureName .. " logical Y unchanged")
      Assert.equal(player.fieldX, 2)
      Assert.equal(player.fieldZ, 3)
    end
    Assert.isNil(
      scheduler:activeMovementForActor(scheduler:foregroundEnvironmentId() or "", "player"),
      gestureName .. " movement should be done after 20 ticks"
    )
  end

  local warpOutOffsets = {}
  for i = 1, 20 do
    warpOutOffsets[i] = i
  end
  runWarp("warp_out", warpOutOffsets)
  local warpInOffsets = {}
  for i = 1, 20 do
    warpInOffsets[i] = 20 - i
  end
  runWarp("warp_in", warpInOffsets)
end

function T.supplied_avatar_state_advances_once_per_fixed_tick_in_every_branch()
  local function avatarFake()
    local fake = { updates = 0 }
    function fake:updateFixed()
      self.updates = self.updates + 1
    end
    return fake
  end
  local function sessionWithAvatar(overrides)
    local avatar = avatarFake()
    local options = baseOptions({ playerAvatar = avatar })
    for key, value in pairs(overrides or {}) do
      options[key] = value
    end
    -- baseOptions replaces the whole table entry, so re-attach the avatar
    -- after overrides are applied.
    options.playerAvatar = avatar
    return FieldSession.new(options), avatar
  end

  local ordinary, ordinaryAvatar = sessionWithAvatar()
  ordinary:updateFixed({})
  Assert.equal(ordinaryAvatar.updates, 1, "an ordinary tick advances the avatar presentation once")
  ordinary:updateFixed({})
  Assert.equal(ordinaryAvatar.updates, 2, "the next tick advances it exactly once more")

  local dialogue, dialogueAvatar = sessionWithAvatar({
    dialogue = {
      isModal = function()
        return true
      end,
      step = function() end,
    },
  })
  dialogue:updateFixed({})
  Assert.equal(dialogueAvatar.updates, 1, "a dialogue-owned tick still advances the surf phase")

  local application, applicationAvatar = sessionWithAvatar({
    applicationHost = applicationHostFake({ active = true }),
  })
  application:updateFixed({})
  Assert.equal(applicationAvatar.updates, 1, "an application-owned tick still advances the surf phase")

  local transition, transitionAvatar = sessionWithAvatar({
    player = {
      fieldX = 4,
      fieldZ = 13,
      worldX = 0,
      worldY = 0,
      worldZ = 0,
      surfaceId = 0,
      facing = "south",
      motion = "walking",
      updateFixed = function()
        return false
      end,
      collapseRenderInterpolation = function() end,
      collisionCandidates = function(self)
        return { { fieldX = self.fieldX, fieldZ = self.fieldZ, surfaceId = self.surfaceId } }
      end,
      clearGesturePresentation = function() end,
      presentationState = function(self)
        local locomotionActive = self.motion == "walking" or self.motion == "turning" or self.motion == "jumping"
        return {
          locomotionActive = locomotionActive,
          gesturePose = nil,
          gestureTick = nil,
          gestureOffsetY = 0,
        }
      end,
    },
    transition = {
      phase = "fade_in",
      locked = true,
      completed = nil,
      updateFixed = function()
        return false
      end,
      start = function()
        error("avatar fixture never starts a warp", 2)
      end,
    },
  })
  transition:updateFixed({})
  Assert.equal(transitionAvatar.updates, 1, "a transition-owned tick still advances the surf phase")
end

return { tests = T }
