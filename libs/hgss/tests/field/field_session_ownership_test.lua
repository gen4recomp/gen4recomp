local Assert = require("tests.support.Assert")
local FieldSession = require("libs.hgss.src.field.FieldSession")
local TilePermissions = require("tests.support.TilePermissions")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")

local function idleTransition()
  return {
    phase = "idle",
    locked = false,
    updateFixed = function() end,
    start = function()
      error("no warp")
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

local function basePlayer(overrides)
  local p = {
    fieldX = 4,
    fieldZ = 13,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "idle",
    updateFixed = function(_)
      return false
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
    collapseRenderInterpolation = function() end,
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
    presentationStateInto = function(self, out)
      out.locomotionActive = self.motion == "walking" or self.motion == "turning" or self.motion == "jumping"
      out.gesturePose = nil
      out.gestureTick = nil
      out.gestureOffsetY = 0
      return out
    end,
  }
  for k, v in pairs(overrides or {}) do
    p[k] = v
  end
  return p
end

local function makeSession(opts)
  opts = opts or {}
  local player = (opts.player or basePlayer()) --[[@as FieldPlayer]]
  local camera = (opts.camera or { updateFixed = function() end }) --[[@as FieldCamera]]
  local actors = (opts.actors or { step = function() end, syncEventStateChanges = opts.syncFn }) --[[@as FieldActorManager]]
  local scheduler = opts.scheduler
    or {
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
      autonomousActorsLocked = function()
        return false
      end,
      autonomousActorLocked = function()
        return false
      end,
    }
  local currentMap = (
    opts.currentMap or { mapId = 61, fieldData = { events = { warps = {} } }, updateAnimated = function() end }
  ) --[[@as RuntimeFieldMap]]
  local input = (opts.input or idleInput()) --[[@as FieldInput]]
  local transition = (opts.transition or idleTransition()) --[[@as FieldTransition]]
  local dialogue = (opts.dialogue or {
    isModal = function()
      return false
    end,
  }) --[[@as FieldDialogueController]]
  local menuHost = (
    opts.menuHost or {
      isModal = function()
        return false
      end,
      advance = function() end,
    }
  ) --[[@as FieldMenuHost]]
  local signpost = (opts.signpost or {
    isModal = function()
      return false
    end,
  }) --[[@as FieldSignpostController]]
  local applicationHost = (
    opts.applicationHost
    or {
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
  ) --[[@as FieldApplicationHost]]
  return FieldSession.new({
    versionId = "heartgold",
    currentMap = currentMap,
    player = player,
    camera = camera,
    transition = transition,
    actors = actors,
    input = input,
    dialogue = dialogue,
    scriptScheduler = scheduler --[[@as Scheduler]],
    scriptClient = (opts.scriptClient or {
      consume = function()
        return require("libs.hgss.src.script.ScriptInteractionClient").RESULTS.blocked
      end,
    }) --[[@as ScriptInteractionClient]],
    menuHost = menuHost,
    contextChoice = opts.contextChoice or {
      isActive = function()
        return false
      end,
    },
    signpost = signpost,
    applicationHost = applicationHost,
    interactions = opts.interactions or {
      resolve = function()
        return nil
      end,
    },
    fieldEntranceIndicator = opts.fieldEntranceIndicator or { updateFixed = function() end },
    eventResolver = opts.eventResolver or {
      resolveCoordinate = function()
        return nil
      end,
      resolvePassiveSign = function()
        return nil
      end,
    },
    eventState = opts.eventState or { getVar = function() end },
    playerVisual = opts.playerVisual,
  })
end

local T = {}

function T.foreground_without_player_lock_permits_movement_but_blocks_menu_and_interaction()
  local opens = 0
  local playerMoves = 0

  local scheduler = {
    foreground = "env-foreground",
    playerLocked = false,
    step = function() end,
    playerInputLocked = function(self)
      return self.playerLocked
    end,
    playerInputOwned = function(self)
      return self.playerLocked
    end,
    foregroundEnvironmentId = function(self)
      return self.foreground
    end,
    autonomousActorsLocked = function()
      return false
    end,
    autonomousActorLocked = function()
      return false
    end,
  }

  local player = basePlayer({
    updateFixed = function(_)
      playerMoves = playerMoves + 1
      return false
    end,
  })

  local interactionsResolved = 0
  local interactions = {
    resolve = function()
      interactionsResolved = interactionsResolved + 1
      return { kind = "object", object = { actorId = "map:61:object:0" } }
    end,
  }

  local session = makeSession({
    player = player,
    scheduler = scheduler,
    interactions = interactions,
    applicationHost = {
      isActive = function()
        return false
      end,
      updateFixed = function() end,
      requestOpen = function()
        opens = opens + 1
        return true
      end,
      takeReopen = function()
        return false
      end,
    },
  })

  -- With a live foreground but no player lock, movement must not be suppressed.
  -- A held direction should reach the player movement path.
  session:updateFixed({ heldDirection = "south", pressedDirection = "south", menuPressed = true, actionPressed = true })
  Assert.equal(playerMoves, 1, "movement must not be blocked solely by foreground ownership")
  Assert.equal(opens, 0, "Start Menu must remain blocked while any foreground owns the field")
  Assert.equal(
    interactionsResolved,
    0,
    "new foreground interactions must remain blocked while a foreground owns the field"
  )
end

function T.actor_world_continues_while_foreground_holds_the_field_and_release_tick_stays_suppressed()
  local poseAdvances = 0
  local actors = {
    step = function(_, _)
      poseAdvances = poseAdvances + 1
      -- Synchronously apply any queued presence if present; keep as plain step for this scenario.
    end,
  }

  local scheduler = {
    playerLocked = true,
    foreground = "env-foreground",
    step = function(self)
      -- Release the player lock in the same tick the session sampled input.
      self.playerLocked = false
    end,
    playerInputLocked = function(self)
      return self.playerLocked
    end,
    playerInputOwned = function(self)
      return self.playerLocked
    end,
    foregroundEnvironmentId = function(self)
      return self.foreground
    end,
    autonomousActorsLocked = function()
      return false
    end,
    autonomousActorLocked = function()
      return false
    end,
  }

  -- The session samples input before stepping the scheduler. Even though the
  -- scheduler releases the lock later in the same tick, that tick's held
  -- direction must remain suppressed.
  local playerMoves = 0
  local player = basePlayer({
    updateFixed = function(_)
      playerMoves = playerMoves + 1
      return false
    end,
  })

  local session = makeSession({
    player = player,
    scheduler = scheduler,
    actors = actors,
  })

  -- Tick 1: locked at start; scheduler releases inside the tick. Actor step must still occur.
  session:updateFixed({ heldDirection = "south", pressedDirection = "south" })
  Assert.equal(poseAdvances, 1, "actor fixed-time progression must continue even while foreground is locked")
  Assert.equal(playerMoves, 0, "player input sampled while locked must not leak through on release tick")

  -- Tick 2: both start and end are unlocked, so movement may proceed.
  session:updateFixed({ heldDirection = "south", pressedDirection = "south" })
  Assert.equal(poseAdvances, 2, "actor step must occur on every world-advancing tick")
  Assert.equal(playerMoves, 1, "fresh input on the next tick must be allowed once unlocked")
end

-- A root that is owned only through the field-interaction claim (no
-- explicit LOCK_PLAYER/LockAll) must still suppress manual player input for
-- its whole environment lifetime, including the tick it completes on. The
-- production scheduler collaborator FieldSession requires today only
-- exposes explicit-lock state through `playerInputLocked`; once the
-- combined ownership query exists, FieldSession must sample it (before and
-- after the scheduler step, ORed) instead of the explicit-only fact. This
-- fixture models an interaction-only-owned root through `playerInputOwned`
-- and proves FieldSession does not yet consult it.
function T.interaction_only_ownership_must_suppress_input_including_the_completion_tick()
  local playerMoves = 0
  local player = basePlayer({
    updateFixed = function(_)
      playerMoves = playerMoves + 1
      return false
    end,
  })

  local claimed = true
  local scheduler = {
    foreground = "env-interaction",
    step = function(self)
      -- The interaction root completes during this tick's scheduler step.
      claimed = false
      self.foreground = nil
    end,
    -- No explicit LOCK_PLAYER/LockAll ever ran for this root; the only
    -- ownership fact is the field-interaction claim.
    playerInputLocked = function()
      return false
    end,
    foregroundEnvironmentId = function(self)
      return self.foreground
    end,
    playerInputOwned = function()
      return claimed
    end,
    autonomousActorsLocked = function()
      return false
    end,
    autonomousActorLocked = function()
      return false
    end,
  }

  local session = makeSession({ player = player, scheduler = scheduler })

  -- The completion tick: the claim is true at tick start and false after the
  -- scheduler step, so the pre/post OR must still suppress this tick's held
  -- input.
  session:updateFixed({ heldDirection = "south", pressedDirection = "south" })
  Assert.equal(playerMoves, 0, "an interaction-only-owned root must suppress input through its own completion tick")

  -- The next tick has no owner at all; movement may proceed.
  session:updateFixed({ heldDirection = "south", pressedDirection = "south" })
  Assert.equal(playerMoves, 1, "movement must be allowed once no ownership fact remains")
end

-- A valid movement-driven traversal (a facing-tile door warp here) and a
-- passive north-facing directional sign are simultaneously eligible from the
-- same idle tick; the traversal must win and the passive sign must not be
-- consumed on that physical step.
function T.same_tick_traversal_candidate_outranks_passive_directional_sign()
  local DOOR = MetatileBehavior.BEHAVIOR.DOOR
  local warp = { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0, y = 0 }
  local currentMap = {
    mapId = 61,
    cameraType = 4,
    coordinateOrigin = { x = 0, z = 0 },
    fieldData = { events = { warps = { warp }, coordinates = {} } },
    updateAnimated = function() end,
    collision = TilePermissions.new({ ["4:14"] = { behavior = DOOR, blocked = true } }),
  }
  local starts = {}
  local transition = {
    phase = "idle",
    locked = false,
    updateFixed = function() end,
    start = function(_, _, trigger, facing)
      starts[#starts + 1] = { warp = trigger.warp, facing = facing }
    end,
  }
  local consumed = {}
  local scriptClient = {
    consume = function(_, intent)
      consumed[#consumed + 1] = intent
      return require("libs.hgss.src.script.ScriptInteractionClient").RESULTS.started
    end,
  }
  local player = basePlayer({ fieldX = 4, fieldZ = 13, facing = "south" })
  local eventResolver = {
    resolveCoordinate = function()
      return nil
    end,
    resolvePassiveSign = function()
      return { kind = "background", background = { eventIndex = 0 } }
    end,
  }
  local session = makeSession({
    currentMap = currentMap,
    transition = transition,
    scriptClient = scriptClient,
    player = player,
    eventResolver = eventResolver,
  })

  session:updateFixed({ heldDirection = "south", pressedDirection = "south" })

  Assert.equal(#starts, 1, "the valid facing-trigger warp must start")
  Assert.equal(#consumed, 0, "the passive sign must not be consumed on the same physical step as a valid traversal")
end

return { tests = T, metadata = {} }
