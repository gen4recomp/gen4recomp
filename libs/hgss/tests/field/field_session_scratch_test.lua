-- Proves the fixed-tick orchestration inputs FieldSession hands to its
-- collaborators reuse stable, owner-held storage across ordinary ticks
-- instead of allocating a fresh record/closure every tick, while every
-- reused record still carries only the current tick's values (no leaked
-- optional field from a prior tick or branch).

local Assert = require("tests.support.Assert")
local FieldSession = require("libs.hgss.src.field.FieldSession")

local T = {}

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

local function idleApplicationHost()
  return {
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
  }
end

-- A complete, minimal fixed-tick collaborator set, mirroring the production
-- required-collaborator contract, with spies wired only where a given test
-- needs to observe what a collaborator received.
local function sessionOptions(overrides)
  local options = {
    versionId = "heartgold",
    currentMap = {
      mapId = 61,
      fieldData = { events = { warps = {} } },
      updateAnimated = function() end,
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
        return false
      end,
      presentationState = function()
        return { locomotionActive = false, gesturePose = nil, gestureTick = nil, gestureOffsetY = 0 }
      end,
      presentationStateInto = function(_, out)
        out.locomotionActive = false
        out.gesturePose = nil
        out.gestureTick = nil
        out.gestureOffsetY = 0
        return out
      end,
      collisionCandidates = function(self)
        return { { fieldX = self.fieldX, fieldZ = self.fieldZ, surfaceId = self.surfaceId } }
      end,
      collisionCandidatesInto = function(self, out)
        local current = out[1]
        if current == nil then
          current = {}
          out[1] = current
        end
        current.fieldX = self.fieldX
        current.fieldZ = self.fieldZ
        current.surfaceId = self.surfaceId
        out[2] = nil
        return out
      end,
      clearGesturePresentation = function() end,
      collapseRenderInterpolation = function() end,
    },
    camera = { updateFixed = function() end },
    transition = idleTransition(),
    actors = { step = function() end },
    input = idleInput(),
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
      autonomousActorsLocked = function()
        return false
      end,
      autonomousActorLocked = function()
        return false
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
    applicationHost = idleApplicationHost(),
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
  for key, value in pairs(overrides or {}) do
    options[key] = value
  end
  return options
end

-- The scheduler-input record: assembled from the tick's input snapshot and
-- modal-host state, then handed to scriptScheduler:step. An ordinary tick's
-- session must hand the collaborator the same record identity every time.
function T.scheduler_input_record_identity_is_stable_across_ordinary_ticks()
  local received = {}
  local scheduler = {
    step = function(_, _, schedulerInput)
      received[#received + 1] = schedulerInput
    end,
    playerInputOwned = function()
      return false
    end,
    foregroundEnvironmentId = function()
      return nil
    end,
    autonomousActorsLocked = function()
      return false
    end,
    autonomousActorLocked = function()
      return false
    end,
  }
  local session = FieldSession.new(sessionOptions({ scriptScheduler = scheduler }))
  session:updateFixed({})
  session:updateFixed({})
  session:updateFixed({})
  Assert.equal(#received, 3)
  Assert.equal(received[1], received[2], "the scheduler-input record identity must be reused across ticks")
  Assert.equal(received[2], received[3], "the scheduler-input record identity must be reused across ticks")
end

-- A scheduler-input optional field (menuEvents) populated while a modal host
-- is active must not leak onto a later tick's record once no host is modal.
function T.scheduler_input_record_clears_stale_optional_fields_between_branches()
  local received = {}
  local menuModal = true
  local menuHost = {
    isModal = function()
      return menuModal
    end,
    advance = function() end,
    inputEvents = function(_, events)
      return events
    end,
  }
  local scheduler = {
    step = function(_, _, schedulerInput)
      received[#received + 1] = schedulerInput
    end,
    playerInputOwned = function()
      return menuModal
    end,
    foregroundEnvironmentId = function()
      return menuModal and "foreground" or nil
    end,
    autonomousActorsLocked = function()
      return false
    end,
    autonomousActorLocked = function()
      return false
    end,
  }
  local input = idleInput()
  input.uiSnapshot = function()
    return { { type = "navigate", direction = "down" } }
  end
  local session = FieldSession.new(sessionOptions({ scriptScheduler = scheduler, menuHost = menuHost, input = input }))
  session:updateFixed({})
  Assert.notNil(received[1].menuEvents, "a modal menu tick must populate menuEvents")

  menuModal = false
  session:updateFixed({})
  Assert.isNil(received[2].menuEvents, "a non-modal tick must not observe a prior tick's menuEvents")
end

-- The actor-step context (autonomousLocked/actorLocked/player/playerCandidates)
-- is handed to FieldActorManager once per tick. An ordinary tick's session
-- must reuse the same context record and player-facts sub-record identity,
-- and the actor-lock predicate must be one persistent closure rather than a
-- fresh closure constructed on every tick.
function T.actor_step_context_and_lock_predicate_identity_is_stable_across_ordinary_ticks()
  local receivedContexts = {}
  local actors = {
    step = function(_, _, context)
      receivedContexts[#receivedContexts + 1] = context
    end,
  }
  local session = FieldSession.new(sessionOptions({ actors = actors }))
  session:updateFixed({})
  session:updateFixed({})
  Assert.equal(#receivedContexts, 2)
  Assert.equal(receivedContexts[1], receivedContexts[2], "the actor-step context record identity must be reused")
  Assert.equal(
    receivedContexts[1].player,
    receivedContexts[2].player,
    "the player-facts sub-record identity must be reused"
  )
  Assert.equal(type(receivedContexts[1].actorLocked), "function")
  Assert.equal(
    receivedContexts[1].actorLocked,
    receivedContexts[2].actorLocked,
    "actorLocked must be one session-owned closure, not rebuilt every tick"
  )
end

-- actorLocked must read the scheduler's current lock state at invocation
-- time, not a value captured once at session construction.
function T.actor_locked_predicate_reads_current_scheduler_state_at_call_time()
  local locked = false
  local capturedPredicate
  local actors = {
    step = function(_, _, context)
      capturedPredicate = context.actorLocked
    end,
  }
  local scheduler = {
    step = function() end,
    playerInputOwned = function()
      return false
    end,
    foregroundEnvironmentId = function()
      return nil
    end,
    autonomousActorsLocked = function()
      return false
    end,
    autonomousActorLocked = function(_, _)
      return locked
    end,
  }
  local session = FieldSession.new(sessionOptions({ actors = actors, scriptScheduler = scheduler }))
  session:updateFixed({})
  Assert.isFalse(capturedPredicate("map:61:object:0"))
  locked = true
  Assert.isTrue(
    capturedPredicate("map:61:object:0"),
    "the persistent actorLocked closure must consult live scheduler state, not a snapshot taken at construction"
  )
end

-- The terrain-effect input record (fieldX/fieldZ/facing) is assembled once
-- per tick from live player state; an ordinary tick's session must hand the
-- collaborator the same record identity every time.
function T.terrain_effect_input_record_identity_is_stable_across_ordinary_ticks()
  local received = {}
  local terrainEffects = {
    updateFixed = function(_, input)
      received[#received + 1] = input
    end,
  }
  local session = FieldSession.new(sessionOptions({ terrainEffects = terrainEffects }))
  session:updateFixed({})
  session:updateFixed({})
  Assert.equal(#received, 2)
  Assert.equal(received[1], received[2], "the terrain-effect input record identity must be reused across ticks")
end

-- The interaction-resolver snapshot is assembled once per tick when the
-- player is idle and presses Action; an ordinary sequence of such ticks must
-- hand the collaborator the same record identity every time.
function T.interaction_resolver_snapshot_identity_is_stable_across_ordinary_ticks()
  local received = {}
  local interactions = {
    resolve = function(_, snapshot)
      received[#received + 1] = snapshot
      return nil
    end,
  }
  local session = FieldSession.new(sessionOptions({ interactions = interactions }))
  session:updateFixed({ actionPressed = true })
  session:updateFixed({ actionPressed = true })
  Assert.equal(#received, 2)
  Assert.equal(received[1], received[2], "the interaction-resolver snapshot identity must be reused across ticks")
end

-- The candidate list handed to the actor manager is session-owned storage:
-- the same list identity on every ordinary tick, overwritten with the
-- tick's values. The test retains the list deliberately to prove the values
-- move, which is why a collaborator must never retain it.
function T.actor_manager_candidate_storage_identity_is_stable_and_current_across_ticks()
  local receivedContexts = {}
  local actors = {
    step = function(_, _, context)
      receivedContexts[#receivedContexts + 1] = context
    end,
  }
  local options = sessionOptions({ actors = actors })
  local session = FieldSession.new(options)
  session:updateFixed({})
  options.player.fieldX = 9
  session:updateFixed({})
  Assert.equal(#receivedContexts, 2)
  local firstCandidates = receivedContexts[1].playerCandidates
  Assert.equal(
    firstCandidates,
    receivedContexts[2].playerCandidates,
    "the actor manager must receive the same candidate list identity every tick"
  )
  Assert.equal(
    firstCandidates[1].fieldX,
    9,
    "the reused candidate list must carry the current tick's values, not the tick it was captured on"
  )
end

return { tests = T }
