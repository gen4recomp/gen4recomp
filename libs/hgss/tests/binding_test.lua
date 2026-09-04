-- Interaction binding tests: mechanical script identity derivation, trigger
-- descriptors, interaction client outcomes, actor-world adaptation, and the
-- session-level script phase.

local Assert = require("tests.support.Assert")
local S = require("gen4.script")
local Registry = require("libs.script.src.Registry")
local Composition = require("libs.script.src.Composition")
local TaskRegistry = require("libs.script.src.TaskRegistry")
local Scheduler = require("libs.script.src.Scheduler")
local WaitTicksTask = require("libs.script.src.tasks.WaitTicksTask")
---@cast WaitTicksTask TaskImplementation
local Bindings = require("libs.hgss.src.script.Bindings")
local ScriptActorWorld = require("libs.hgss.src.script.ScriptActorWorld")
local ScriptInteractionClient = require("libs.hgss.src.script.ScriptInteractionClient")
local FakeServices = require("tests.support.script.FakeServices")
local FieldSession = require("libs.hgss.src.field.FieldSession")

local T = {}

local function objectIntent(mapId, actorId, playerFacing, rawScriptId)
  local result = {
    kind = "object",
    mapId = mapId,
    sourceFieldX = 4,
    sourceFieldZ = 6,
    targetFieldX = 4,
    targetFieldZ = 5,
    playerFacing = playerFacing or "north",
    scriptBankId = 842,
    scriptId = rawScriptId == nil and 2 or rawScriptId,
    object = { actorId = actorId, objectEventId = 3, spriteId = 1 },
  }
  ---@cast result InteractionIntent
  return result
end

local function backgroundIntent(mapId, eventIndex, playerFacing, rawScriptId)
  return {
    kind = "background",
    mapId = mapId,
    sourceFieldX = 4,
    sourceFieldZ = 6,
    targetFieldX = 6,
    targetFieldZ = 3,
    playerFacing = playerFacing or "south",
    scriptBankId = 842,
    scriptId = rawScriptId == nil and 2 or rawScriptId,
    background = { eventIndex = eventIndex, type = 1, direction = 4 },
  }
end

local function platform()
  local services = FakeServices.new()
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local taskRegistry = TaskRegistry.new()
  taskRegistry:register("wait_ticks", 1, WaitTicksTask)
  local scheduler = Scheduler.new({
    semantics = require("libs.hgss.src.script.RuntimeValues"),
    services = services,
    taskRegistry = taskRegistry,
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  return { services = services, registry = registry, composition = composition, scheduler = scheduler }
end

local function script(id, steps)
  return S.script({ api = 1, id = id, steps = steps })
end

-- Object binding derives the stable public script id from the raw source
-- identity carried by the intent.
T["object binding and trigger"] = function()
  local bindings = Bindings.new()
  local hit = bindings:resolveIntent(objectIntent(57, "obj_T20_gswoman1", "north"), "north")
  local trigger = assert(hit).trigger
  Assert.equal(trigger.kind, "object")
  Assert.equal(trigger.mapId, 57)
  Assert.equal(trigger.objectId, "obj_T20_gswoman1")
  Assert.equal(trigger.scriptId, "vanilla.hgss.scr_seq.0842.script_001")
  Assert.equal(trigger.selfActor, "obj_T20_gswoman1")
  Assert.equal(trigger.playerFacing, "north")
end

-- Background binding uses the same mechanical identity rule.
T["background binding and trigger"] = function()
  local bindings = Bindings.new()
  local hit = bindings:resolveIntent(backgroundIntent(58, 9, "south"), "south")
  local trigger = assert(hit).trigger
  Assert.equal(trigger.kind, "background")
  Assert.equal(trigger.backgroundId, 9)
  Assert.equal(trigger.selfActor, nil)
  Assert.equal(trigger.scriptId, "vanilla.hgss.scr_seq.0842.script_001")
end

-- Raw script id zero uses the runtime-owned inert script.
T["zero raw script id resolves to the inert script"] = function()
  local bindings = Bindings.new()
  local resolved = assert(bindings:resolveIntent(objectIntent(57, "obj_unknown", "north", 0), "north"))
  Assert.equal(resolved.scriptId, Bindings.CANONICAL_INERT_SCRIPT)
end

-- 10. The interaction client starts a bound script in the trigger tick.
T["client starts script in trigger tick"] = function()
  local p = platform()
  local resource = script("vanilla.hgss.scr_seq.0842.script_001", {
    S.setVar({ variable = "VAR_SCENE", value = 1 }),
    S.waitTicks({ ticks = 1 }),
    S.stop(),
  })
  p.registry:installBase(resource.id, resource, "generated")
  local client = ScriptInteractionClient.new({
    bindings = Bindings.new(),
    compose = function(id)
      return p.composition:effective(id)
    end,
    scheduler = p.scheduler,
  })
  local result = client:consume(objectIntent(57, "obj_T20_gswoman1", "north"), 100)
  Assert.equal(result, ScriptInteractionClient.RESULTS.started)
  Assert.equal(
    p.services.world:getVar("VAR_SCENE"),
    1,
    "a newly resolved interaction may execute during its trigger tick"
  )
  local instance = assert(p.scheduler:instances()[1])
  Assert.equal(instance.trigger.scriptId, "vanilla.hgss.scr_seq.0842.script_001")
  Assert.equal(instance.trigger.selfActor, "obj_T20_gswoman1")
end

-- 11. A second interaction while a foreground root owns the field is blocked.
T["interaction while locked"] = function()
  local p = platform()
  local resource = script("vanilla.hgss.scr_seq.0842.script_001", {
    S.waitTicks({ ticks = 5 }),
    S.stop(),
  })
  p.registry:installBase(resource.id, resource, "generated")
  local client = ScriptInteractionClient.new({
    bindings = Bindings.new(),
    compose = function(id)
      return p.composition:effective(id)
    end,
    scheduler = p.scheduler,
  })
  Assert.equal(
    client:consume(objectIntent(57, "obj_T20_gswoman1", "north"), 100),
    ScriptInteractionClient.RESULTS.started
  )
  Assert.equal(
    client:consume(objectIntent(57, "obj_T20_gswoman1", "north"), 101),
    ScriptInteractionClient.RESULTS.blocked
  )
end

-- 12. Unmapped intents report "unmapped" so the caller can fall through to a
-- fallback client.
T["unmapped intent falls through"] = function()
  local p = platform()
  local client = ScriptInteractionClient.new({
    bindings = Bindings.new(),
    compose = function(id)
      return p.composition:effective(id)
    end,
    scheduler = p.scheduler,
  })
  Assert.equal(client:consume(objectIntent(57, "obj_unmapped", "north"), 100), ScriptInteractionClient.RESULTS.unmapped)
  Assert.isNil(p.scheduler:foregroundEnvironmentId())
end

-- 13. Actor world adapter: the player is always present; snapshots are
-- read-only records; mutation operations reach the manager.
T["actor world adapter"] = function()
  local actors = {}
  actors.elm = { id = "elm", fieldX = 4, fieldZ = 5, facing = "north", visible = true, mapId = 61 }
  local manager = {
    getActor = function(_, id)
      return actors[id]
    end,
    getPosition = function(_, id)
      return { fieldX = actors[id].fieldX, fieldZ = actors[id].fieldZ, worldY = 0 }
    end,
    getFacing = function(_, id)
      return actors[id].facing
    end,
    show = function(_, id)
      actors[id].visible = true
    end,
    hide = function(_, id)
      actors[id].visible = false
    end,
    setPosition = function(_, id, position)
      actors[id].fieldX = position.fieldX
      actors[id].fieldZ = position.fieldZ
    end,
    setFacing = function(_, id, direction)
      actors[id].facing = direction
    end,
    setMovementType = function(_, id, movementType)
      actors[id].movementType = movementType
    end,
    setAnimationPaused = function(_, id, paused)
      actors[id].animationPaused = paused
    end,
    numericId = function(_, id)
      return actors[id] and 7 or nil
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
    isVisible = function(_, id)
      return actors[id].visible ~= false
    end,
    setPresentationOffset = function(_, id, offset)
      actors[id].presentationOffset = { x = offset.x, y = offset.y, z = offset.z }
    end,
    clearPresentationOffset = function(_, id)
      actors[id].presentationOffset = { x = 0, y = 0, z = 0 }
    end,
  }
  local player = {
    position = function()
      return { fieldX = 10, fieldZ = 10, worldY = 0 }
    end,
    facing = function()
      return "south"
    end,
    gender = function()
      return 0
    end,
    name = function()
      return "Gold"
    end,
    collisionCandidates = function()
      return { { fieldX = 10, fieldZ = 10, surfaceId = 0 } }
    end,
  }
  local world = ScriptActorWorld.new(manager --[[@as ScriptActorManager]], player)
  Assert.isTrue(world:exists("player"))
  Assert.isTrue(world:exists("elm"))
  Assert.isFalse(world:exists("ghost"))
  local snapshot = world:snapshot("elm")
  ---@cast snapshot table
  Assert.equal(snapshot.actorId, "elm")
  Assert.equal(snapshot.mapId, 61, "the snapshot carries the actor's map id")
  Assert.equal(snapshot.facing, "north")
  world:setFacing("elm", "east")
  world:hide("elm")
  Assert.equal(actors.elm.facing, "east")
  Assert.isFalse(actors.elm.visible)
  Assert.equal(world:getPosition("player").fieldX, 10)
end

-- Actor visibility and presentation offsets are public delegated capabilities:
-- the adapter requires them at construction and routes NPC queries to the
-- manager instead of reading records or probing for optional methods.
T["actor visibility and presentation offsets delegate through the required contract"] = function()
  local Errors = require("libs.errors.src.Errors")
  local actors = {}
  actors.elm = { id = "elm", fieldX = 4, fieldZ = 5, facing = "north", visible = true, mapId = 61 }
  local forcedVisible = { elm = false }
  local calls = { isVisible = 0, set = 0, clear = 0 }
  local lastOffset = nil
  local function baseManager()
    return {
      getActor = function(_, id)
        return actors[id]
      end,
      getPosition = function(_, id)
        return { fieldX = actors[id].fieldX, fieldZ = actors[id].fieldZ, worldY = 0 }
      end,
      getFacing = function(_, id)
        return actors[id].facing
      end,
      show = function(_, id)
        actors[id].visible = true
      end,
      hide = function(_, id)
        actors[id].visible = false
      end,
      setPosition = function(_, id, position)
        actors[id].fieldX = position.fieldX
        actors[id].fieldZ = position.fieldZ
      end,
      setFacing = function(_, id, direction)
        actors[id].facing = direction
      end,
      setMovementType = function(_, id, movementType)
        actors[id].movementType = movementType
      end,
      setAnimationPaused = function(_, id, paused)
        actors[id].animationPaused = paused
      end,
      numericId = function(_, id)
        return actors[id] and 7 or nil
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
      isVisible = function(_, id)
        calls.isVisible = calls.isVisible + 1
        local actor = actors[id]
        if actor == nil then
          Errors.raise("SCRIPT_ACTOR_NOT_FOUND", "no live actor " .. tostring(id), { actor = id })
        end
        assert(actor ~= nil)
        if forcedVisible[id] ~= nil then
          return forcedVisible[id]
        end
        return actor.visible ~= false
      end,
      setPresentationOffset = function(_, id, offset)
        calls.set = calls.set + 1
        lastOffset = { x = offset.x, y = offset.y, z = offset.z }
        actors[id].presentationOffset = { x = offset.x, y = offset.y, z = offset.z }
      end,
      clearPresentationOffset = function(_, id)
        calls.clear = calls.clear + 1
        actors[id].presentationOffset = { x = 0, y = 0, z = 0 }
        lastOffset = { x = 0, y = 0, z = 0 }
      end,
    }
  end
  local player = {
    position = function()
      return { fieldX = 10, fieldZ = 10, worldY = 0 }
    end,
    facing = function()
      return "south"
    end,
  }
  local world = ScriptActorWorld.new(baseManager() --[[@as ScriptActorManager]], player)
  Assert.isFalse(world:isVisible("elm"), "visibility must come from the manager, not the actor record")
  Assert.equal(calls.isVisible, 1)
  world:setPresentationOffset("elm", { x = 1, y = 2, z = 3 })
  Assert.equal(calls.set, 1)
  Assert.deepEqual(lastOffset, { x = 1, y = 2, z = 3 })
  world:clearPresentationOffset("elm")
  Assert.equal(calls.clear, 1)
  Assert.deepEqual(lastOffset, { x = 0, y = 0, z = 0 })
  Assert.isTrue(world:isVisible("player"), "the player stays visible")
  local setPlayerErr = Assert.throws(function()
    world:setPresentationOffset("player", { x = 0, y = 0, z = 0 })
  end)
  Assert.isTrue(Errors.is(setPlayerErr), "player offsets stay rejected")
  local clearPlayerErr = Assert.throws(function()
    world:clearPresentationOffset("player")
  end)
  Assert.isTrue(Errors.is(clearPlayerErr), "player offsets stay rejected")
  local missingErr = Assert.throws(function()
    world:isVisible("ghost")
  end)
  Assert.isTrue(Errors.is(missingErr), "a missing actor must fail, never read as visible")
  Assert.equal(assert(missingErr).code, "SCRIPT_ACTOR_NOT_FOUND")
  for _, method in ipairs({ "isVisible", "setPresentationOffset", "clearPresentationOffset" }) do
    local incomplete = baseManager()
    incomplete[method] = nil
    local err = Assert.throws(function()
      ScriptActorWorld.new(incomplete --[[@as ScriptActorManager]], player)
    end, "construction must require " .. method)
    Assert.notNil(err)
  end
end

-- 15. Missing actors through the runtime are attributed errors.
T["missing actor fault through binding path"] = function()
  local p = platform()
  local manager = {
    getActor = function()
      return nil
    end,
    getPosition = function()
      return nil
    end,
    getFacing = function()
      return nil
    end,
    show = function() end,
    hide = function() end,
    setPosition = function() end,
    setFacing = function() end,
    setMovementType = function() end,
    setAnimationPaused = function() end,
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
      return false
    end,
    setPresentationOffset = function() end,
    clearPresentationOffset = function() end,
  }
  p.services.actors = ScriptActorWorld.new(manager --[[@as ScriptActorManager]], p.services.player) --[[@as FakeActors]]
  local resource = script("elms_lab.elm", {
    S.facePlayer({ actor = "self" }),
    S.stop(),
  })
  p.registry:installBase(resource.id, resource, "generated")
  local composed = assert(p.composition:effective(resource.id))
  local trigger = {
    kind = "object",
    mapId = 58,
    objectId = "obj_T20R0101_doctor",
    scriptId = resource.id,
    selfActor = "obj_T20R0101_doctor",
    playerFacing = "north",
  }
  p.scheduler:createForeground(composed, trigger, 100)
  p.scheduler:step(100, nil)
  local fault = assert(p.services.events:eventFor("script.error", "script-00000001"))
  Assert.equal(fault.code, "SCRIPT_ACTOR_NOT_FOUND")
end

-- 15b. An interaction without an object has nothing to turn toward the
-- player: the default self-facing continues instead of faulting, while an
-- explicit missing actor still fails through the binding path above.
T["background trigger self-facing continues without an actor"] = function()
  local p = platform()
  local resource = script("vanilla.hgss.scr_seq.0843.script_012", {
    S.facePlayer({}),
    S.stop(),
  })
  p.registry:installBase(resource.id, resource, "generated")
  local composed = assert(p.composition:effective(resource.id))
  local trigger = {
    kind = "background",
    mapId = 61,
    backgroundId = 9,
    scriptId = resource.id,
    selfActor = nil,
    playerFacing = "north",
  }
  p.scheduler:createForeground(composed, trigger, 100)
  p.scheduler:step(100, nil)
  p.scheduler:step(101, nil)
  Assert.isNil(p.services.events:eventFor("script.error", "script-00000001"), "actorless facing is a no-op")
  local ended = assert(p.services.events:eventFor("script.ended", "script-00000001"))
  Assert.isTrue(ended.completed, "the background script runs past facing to its stop")
end

-- 16. Map transition cancellation: a warp cancels the foreground environment,
-- releasing locks and tasks.
T["map transition cancels scripts"] = function()
  local p = platform()
  local resource = script("vanilla.hgss.scr_seq.0842.script_001", {
    S.lockAll(),
    S.waitTicks({ ticks = 5 }),
    S.stop(),
  })
  p.registry:installBase(resource.id, resource, "generated")
  local composed = assert(p.composition:effective(resource.id))
  local instanceId = p.scheduler:createForeground(composed, {
    kind = "object",
    mapId = 57,
    scriptId = resource.id,
    selfActor = "obj_T20_gswoman1",
  }, 100)
  p.scheduler:step(100, nil)
  local envId = assert(p.scheduler:foregroundEnvironmentId())
  p.scheduler:cancelEnvironment(envId, "map transition")
  Assert.isNil(p.scheduler:foregroundEnvironmentId())
  local ended = assert(p.services.events:eventFor("script.ended", instanceId))
  Assert.isFalse(ended.completed)
  Assert.equal(ended.reason, "map transition")
  Assert.equal(#p.scheduler:tasks(), 0)
end

-- 17. Session-level integration: with a script scheduler attached, the
-- session steps the script phase each tick and consumes the tick while a
-- foreground script owns the field (player movement suppressed).
T["session script phase"] = function()
  local p = platform()
  local resource = script("vanilla.hgss.scr_seq.0842.script_001", {
    S.setVar({ variable = "VAR_SCENE", value = 1 }),
    S.waitTicks({ ticks = 1 }),
    S.stop(),
  })
  p.registry:installBase(resource.id, resource, "generated")
  local client = ScriptInteractionClient.new({
    bindings = Bindings.new(),
    compose = function(id)
      return p.composition:effective(id)
    end,
    scheduler = p.scheduler,
  })
  local moved = 0
  local player = {
    fieldX = 4,
    fieldZ = 6,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "idle",
    updateFixed = function(self)
      moved = moved + 1
      self.motion = "idle"
      return false
    end,
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
  }
  local runtimeMap = {
    mapId = 57,
    -- Mirrors the simulation-only aggregate: no presentation runtimes, so the
    -- map clock entry is a safe no-op.
    updateAnimated = function() end,
  }
  ---@cast runtimeMap RuntimeFieldMap
  ---@cast player FieldPlayer
  local camera = { updateFixed = function() end }
  ---@cast camera FieldCamera
  local transition = {
    phase = "idle",
    locked = false,
    updateFixed = function() end,
    start = function()
      error("binding fixture never starts a warp", 2)
    end,
  }
  ---@cast transition FieldTransition
  local input = {
    snapshot = function()
      return {}
    end,
    clearEdges = function() end,
  }
  ---@cast input FieldInput
  local actors = { step = function() end }
  ---@cast actors FieldActorManager
  local dialogue = {
    isModal = function()
      return false
    end,
  }
  ---@cast dialogue FieldDialogueController
  local menuHost = {
    isModal = function()
      return false
    end,
    advance = function() end,
  }
  ---@cast menuHost FieldMenuHost
  local contextChoice = {
    isActive = function()
      return false
    end,
  }
  local session = FieldSession.new({
    versionId = "heartgold",
    currentMap = runtimeMap,
    player = player,
    camera = camera,
    transition = transition,
    input = input,
    actors = actors,
    scriptScheduler = p.scheduler,
    scriptClient = client,
    interactions = {
      resolve = function(_, _)
        return objectIntent(57, "obj_T20_gswoman1", "north")
      end,
    },
    dialogue = dialogue,
    menuHost = menuHost,
    contextChoice = contextChoice,
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
      requestOpen = function() end,
      takeReopen = function()
        return false
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
    eventState = p.services.world,
  })
  -- The script client starts the interaction and the tick is consumed: the
  -- player does not move while the foreground root owns the field.
  session:updateFixed({ actionPressed = true, heldDirection = "south" })
  Assert.equal(p.services.world:getVar("VAR_SCENE"), 1)
  Assert.equal(moved, 0, "player movement is suppressed while a script owns the field")
  Assert.equal(session.tick, 1)
  -- Once the script completes, the field is free again.
  session:updateFixed({})
  session:updateFixed({})
  Assert.isNil(p.scheduler:foregroundEnvironmentId())
end

-- 18. A live foreground root is execution ownership, not an implicit player lock.
T["foreground root locks movement without an explicit lock"] = function()
  local p = platform()
  local resource = script("vanilla.hgss.scr_seq.0842.script_001", {
    S.waitTicks({ ticks = 2 }),
    S.stop(),
  })
  p.registry:installBase(resource.id, resource, "generated")
  local composed = assert(p.composition:effective(resource.id))
  p.scheduler:createForeground(composed, nil, 100)
  Assert.notNil(p.scheduler:foregroundEnvironmentId(), "foreground ownership is active on creation")
  Assert.isFalse(
    p.scheduler:explicitPlayerLocked(),
    "foreground without explicit lock must not report player input locked"
  )
  p.scheduler:step(100, nil)
  p.scheduler:step(101, nil)
  p.scheduler:step(102, nil)
  p.scheduler:step(103, nil)
  Assert.isNil(p.scheduler:foregroundEnvironmentId())
  Assert.isFalse(p.scheduler:explicitPlayerLocked(), "the field unlocks when the foreground root ends")
end

return { tests = T }
