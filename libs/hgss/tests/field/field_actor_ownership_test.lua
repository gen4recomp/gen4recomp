-- Field actor owner tests isolate identity, occupancy, and persistence seams.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local FieldActorOccupancy = require("libs.hgss.src.actors.FieldActorOccupancy")
local FieldActorPersistence = require("libs.hgss.src.actors.FieldActorPersistence")
local FieldActorStore = require("libs.hgss.src.actors.FieldActorStore")

local T = {}

local function map()
  local value = {
    mapId = 61,
    terrain = {
      plate = function(_, surfaceId)
        return { id = surfaceId, cellKey = "0:0", sourceSurfaceId = surfaceId }
      end,
    },
  }
  ---@cast value RuntimeFieldMap
  return value
end

local function actor(actorId, objectEventId)
  local value = { actorId = actorId, objectEventId = objectEventId }
  ---@cast value FieldActorManager.Actor
  return value
end

local function flagEvent(objectEventId, eventFlag)
  local value = { eventFlag = eventFlag, objectEventId = objectEventId }
  ---@cast value FieldActorEvent
  return value
end

local POLICY = {
  variableSprites = { first = 101, last = 117, variableBase = 0x4020 },
}

local function flatTerrain()
  return TerrainSurface.new({
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
  })
end

local function sourceObject(overrides)
  local event = {
    index = 0,
    objectEventId = 0,
    spriteId = 99,
    movementType = "stationary",
    type = 0,
    eventFlag = 500,
    scriptId = 1,
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
  }
  for key, value in pairs(overrides or {}) do
    rawset(event, key, value)
  end
  ---@cast event FieldActorEvent
  return event
end

local function testRuntimeMap(objects, mapId)
  local value = {
    mapId = mapId or 61,
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
    },
    terrain = flatTerrain(),
    fieldData = { events = { objects = objects, background = {}, warps = {}, coordinates = {} } },
  }
  ---@cast value RuntimeFieldMap
  return value
end

local function testAssets()
  local assets = {
    references = {},
    knows = function(_, spriteId)
      return spriteId == 99
    end,
    acquire = function(self, spriteId)
      self.references[spriteId] = (self.references[spriteId] or 0) + 1
      return { spriteId = spriteId, visual = FieldActorFixture.visual(spriteId) }
    end,
    release = function(self, spriteId)
      local count = self.references[spriteId] or 0
      assert(count > 0, "unbalanced release of spriteId " .. tostring(spriteId))
      self.references[spriteId] = count - 1
    end,
  }
  return assets
end

local function restoreRecord(overrides)
  local record = {
    actorId = "map:61:object:0",
    mapId = 61,
    objectEventId = 0,
    sourceMovementType = "stationary",
    movementType = "wander_north_south",
    fieldX = 2,
    fieldZ = 3,
    facing = "south",
    managerOrder = 0,
    controller = { kind = "wander", timer = 0 },
  }
  for key, value in pairs(overrides or {}) do
    record[key] = value
  end
  return record
end

local function restoreSnapshot(records)
  return {
    schema = "g4-field-objects-v1",
    rng = { state = 7, calls = 0 },
    actors = records,
  }
end

local function restoreResult(objects, eventState, snapshot)
  local assets = testAssets()
  local manager = FieldActorManager.new({ assets = assets, policy = POLICY })
  local ok, err = pcall(function()
    manager:enterMap(testRuntimeMap(objects), eventState, snapshot)
  end)
  return manager, ok, err
end

local function assertErrorCode(err, code)
  Assert.isTrue(Errors.is(err), "expected a structured restore error, got " .. tostring(err))
  local structuredError = err --[[@as Errors.Error]]
  Assert.equal(structuredError.code, code, "expected " .. code .. ", got " .. Errors.format(structuredError))
end

function T.direct_store_owns_identity_order_and_manager_slots()
  local store = FieldActorStore.new()
  local first = actor("first", 4)
  local second = actor("second", 9)

  store:indexEvent(flagEvent(4, 401))
  store:indexEvent(flagEvent(9, 401))
  Assert.equal(#store:eventsForFlag(401), 2)
  Assert.equal(#store:eventsForFlag(402), 0)

  store:addActor(first)
  store:addActor(second)
  Assert.equal(store:getActor("first"), first)
  Assert.equal(store:getActorByIndex(9), "second")
  Assert.deepEqual(store:orderedActors(), { first, second })

  local firstSlot = store:assignManagerSlot(first)
  local secondSlot = store:assignManagerSlot(second)
  Assert.equal(secondSlot, firstSlot + 1)
  Assert.equal(store:managerSlot(first), firstSlot)
  Assert.isTrue(store:hasManagerSlot("first"))
  Assert.deepEqual(store:actorsByManagerSlot(), { first, second })

  store:releaseManagerSlot(first)
  Assert.isFalse(store:hasManagerSlot("first"))
  store:assignManagerSlot(first, 0)
  Assert.equal(store:managerSlot(first), 0)

  store:replaceManagerSlots({ [0] = second, [1] = first })
  Assert.equal(store:managerSlot(second), 0)
  Assert.equal(store:managerSlot(first), 1)
  Assert.deepEqual(store:actorsByManagerSlot(), { second, first })

  store:removeActor(first)
  Assert.isNil(store:getActor("first"))
  Assert.deepEqual(store:orderedActors(), { second })
end

function T.direct_occupancy_orders_claims_and_reservations_through_a_slot_callback()
  local slots = { first = 0, second = 1 }
  local occupancy = FieldActorOccupancy.new({
    runtimeMap = map(),
    managerSlot = function(current)
      return slots[current.actorId]
    end,
  })
  local first = actor("first", 4)
  local second = actor("second", 9)
  first.fieldX, first.fieldZ, first.surfaceId, first.solid = 2, 3, 0, true
  second.fieldX, second.fieldZ, second.surfaceId, second.solid = 2, 3, 0, true
  local candidate = { fieldX = 2, fieldZ = 3, surfaceId = 0 }

  occupancy:claim(first, candidate)
  Assert.equal(occupancy:winner(candidate), first)
  occupancy:claim(second, candidate)
  Assert.equal(occupancy:winner(candidate), first)
  Assert.throws(function()
    occupancy:claimExclusive(second, candidate)
  end)
  occupancy:release(first, candidate)
  occupancy:release(second, candidate)
  occupancy:reserve("second", candidate)
  Assert.equal(occupancy:reservation(candidate).actorId, "second")
  Assert.throws(function()
    occupancy:reserve("first", candidate)
  end)
  occupancy:cancelReservation(candidate, "second")
  Assert.isNil(occupancy:reservation(candidate))
end

function T.persistence_translates_actor_state_to_the_existing_save_record()
  local persistence = FieldActorPersistence.new()
  local testActor = {
    actorId = "map:61:object:4",
    mapId = 61,
    objectEventId = 4,
    sourceEvent = { movementType = "wander_around" },
    movementType = "wander_around",
    fieldX = 12,
    fieldZ = 8,
    facing = "west",
    cellKey = "0:0",
    sourceSurfaceId = 12,
  }
  ---@cast testActor FieldActorManager.Actor
  local record = persistence:captureActor(testActor, 3, { phase = "wait" })
  Assert.deepEqual(record, {
    actorId = "map:61:object:4",
    mapId = 61,
    objectEventId = 4,
    sourceMovementType = "wander_around",
    movementType = "wander_around",
    fieldX = 12,
    fieldZ = 8,
    facing = "west",
    controller = { phase = "wait" },
    managerOrder = 3,
    cellKey = "0:0",
    sourceSurfaceId = 12,
  })
  Assert.isTrue(type(persistence.capture) == "function")
  Assert.isTrue(type(persistence.stageRestore) == "function")
end

function T.capture_omits_flagged_live_actor_before_queued_destruction_runs()
  local eventState = FieldEventState.new()
  local manager = FieldActorManager.new({ assets = testAssets(), policy = POLICY })
  manager:enterMap(testRuntimeMap({ sourceObject({ eventFlag = 500 }) }), eventState)
  local actorId = "map:61:object:0"
  Assert.notNil(manager:getById(actorId), "the source actor must be live while its flag is clear")

  eventState:setFlag(500)
  Assert.notNil(manager:getById(actorId), "queued flag application must not destroy the actor before the sync boundary")

  local captured = manager:captureObjects()
  Assert.isNil(
    captured.actors[actorId],
    "a live actor whose durable flag is already set must be omitted even before sync destroys it"
  )

  manager:syncEventStateChanges()
  Assert.isNil(manager:getById(actorId), "the pending flag sync must destroy the flagged actor as before")
  manager:dispose()
end

function T.capture_keeps_transiently_hidden_actor_with_clear_flag()
  local eventState = FieldEventState.new()
  local manager = FieldActorManager.new({ assets = testAssets(), policy = POLICY })
  manager:enterMap(testRuntimeMap({ sourceObject({ eventFlag = 500 }) }), eventState)
  local actorId = "map:61:object:0"
  Assert.notNil(manager:getById(actorId), "the source actor must be live while its flag is clear")

  manager:hide(actorId)
  Assert.isFalse(manager:isVisible(actorId), "the live hide path must mark the actor transiently hidden")
  Assert.isFalse(eventState:isFlagSet(500), "the durable flag must stay clear for a transient hide")

  local captured = manager:captureObjects()
  local record = captured.actors[actorId]
  Assert.notNil(record, "a hidden actor with a clear durable flag must still be captured")
  Assert.isNil(record.visible, "visibility itself must never enter the save record")
  manager:dispose()
end

function T.flagged_compatible_saved_actor_is_validated_then_filtered()
  local actorId = "map:61:object:0"
  local eventState = FieldEventState.new({ flags = { [500] = true } })
  local manager, ok, err =
    restoreResult({ sourceObject({ eventFlag = 500 }) }, eventState, restoreSnapshot({ [actorId] = restoreRecord() }))

  Assert.isTrue(ok, tostring(err))
  Assert.isNil(manager:getById(actorId), "a compatible flagged actor must remain filtered")
  manager:dispose()
end

function T.flagged_incompatible_source_movement_is_not_filtered_before_validation()
  local actorId = "map:61:object:0"
  local eventState = FieldEventState.new({ flags = { [500] = true } })
  local manager, ok, err = restoreResult(
    { sourceObject({ eventFlag = 500, movementType = "wander_around" }) },
    eventState,
    restoreSnapshot({ [actorId] = restoreRecord({ sourceMovementType = "stationary" }) })
  )

  Assert.isFalse(ok, "an incompatible flagged record must fail before the flag can drop it")
  assertErrorCode(err, "SCRIPT_TASK_UNSERIALIZABLE")
  manager:dispose()
end

function T.flagged_incompatible_object_event_identity_is_not_filtered_before_validation()
  local actorId = "map:61:object:0"
  local eventState = FieldEventState.new({ flags = { [500] = true } })
  local manager, ok, err = restoreResult({
    sourceObject({ objectEventId = 0, eventFlag = 0 }),
    sourceObject({ objectEventId = 1, eventFlag = 500 }),
  }, eventState, restoreSnapshot({ [actorId] = restoreRecord({ objectEventId = 1 }) }))

  Assert.isFalse(ok, "a record keyed to a different source actor must not be hidden by its flag")
  assertErrorCode(err, "SCRIPT_TASK_UNSERIALIZABLE")
  manager:dispose()
end

function T.removed_source_event_keeps_the_established_restore_failure()
  local actorId = "map:61:object:1"
  local eventState = FieldEventState.new({ flags = { [500] = true } })
  local manager, ok, err = restoreResult(
    { sourceObject({ objectEventId = 0, eventFlag = 0 }) },
    eventState,
    restoreSnapshot({ [actorId] = restoreRecord({ actorId = actorId, objectEventId = 1 }) })
  )

  Assert.isFalse(ok)
  assertErrorCode(err, "SCRIPT_ACTOR_NOT_FOUND")
  manager:dispose()
end

function T.unflagged_compatible_saved_actor_restores_normally()
  local actorId = "map:61:object:0"
  local manager, ok, err = restoreResult(
    { sourceObject({ eventFlag = 0 }) },
    FieldEventState.new(),
    restoreSnapshot({ [actorId] = restoreRecord({ fieldX = 10, facing = "north" }) })
  )

  Assert.isTrue(ok, tostring(err))
  local restoredActor = assert(manager:getById(actorId))
  Assert.equal(restoredActor.fieldX, 10)
  Assert.equal(restoredActor.facing, "north")
  manager:dispose()
end

function T.unflagged_incompatible_saved_actor_still_fails_source_validation()
  local actorId = "map:61:object:0"
  local manager, ok, err = restoreResult(
    { sourceObject({ eventFlag = 0, movementType = "wander_around" }) },
    FieldEventState.new(),
    restoreSnapshot({ [actorId] = restoreRecord({ sourceMovementType = "stationary" }) })
  )

  Assert.isFalse(ok)
  assertErrorCode(err, "SCRIPT_TASK_UNSERIALIZABLE")
  manager:dispose()
end

function T.flagged_later_invalid_record_fails_before_earlier_restore_is_published()
  local firstActorId = "map:60:object:0"
  local secondActorId = "map:61:object:1"
  local objects = {
    sourceObject({ objectEventId = 0, eventFlag = 0 }),
    sourceObject({ objectEventId = 1, eventFlag = 500, x = 4 }),
  }
  local eventState = FieldEventState.new({ flags = { [500] = true } })
  local manager = FieldActorManager.new({ assets = testAssets(), policy = POLICY })
  local initialMap = testRuntimeMap(objects, 60)
  manager:enterMap(initialMap, eventState)
  local original = assert(manager:getById(firstActorId))

  local replacementMap = testRuntimeMap(objects, 61)
  local snapshot = restoreSnapshot({
    ["map:61:object:0"] = restoreRecord({ fieldX = 10 }),
    [secondActorId] = restoreRecord({
      actorId = secondActorId,
      objectEventId = 1,
      sourceMovementType = "changed",
      managerOrder = 1,
    }),
  })
  local ok, err = pcall(function()
    manager:enterMap(replacementMap, eventState, snapshot)
  end)

  Assert.isFalse(ok, "a later flagged incompatibility must fail the whole staged restore")
  assertErrorCode(err, "SCRIPT_TASK_UNSERIALIZABLE")
  Assert.equal(manager:getById(firstActorId), original, "failed restore must keep the published actor world")
  Assert.equal(original.fieldX, 2, "failed restore must not publish earlier actor changes")
  Assert.isNil(manager:getById(secondActorId))
  manager:dispose()
end

return { tests = T }
