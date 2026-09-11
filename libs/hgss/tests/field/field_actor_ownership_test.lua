-- Field actor owner tests isolate identity, occupancy, and persistence seams.

local Assert = require("tests.support.Assert")
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

-- Test-only actor shape: the occupancy/store seams under test read the
-- placement fields below, which are not part of the production Actor contract.
---@class TestOwnerActor : FieldActorManager.Actor
---@field fieldX integer
---@field fieldZ integer
---@field surfaceId integer
---@field solid boolean

local function actor(actorId, objectEventId)
  local value = { actorId = actorId, objectEventId = objectEventId }
  ---@cast value TestOwnerActor
  return value
end

local function flagEvent(objectEventId, eventFlag)
  local value = { eventFlag = eventFlag, objectEventId = objectEventId }
  ---@cast value FieldActorEvent
  return value
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

-- A storage-slot integer is a physical cdata identity distinct from the
-- semantic manager slot: it must survive both buffer growth and a full
-- manager-slot reassignment.
function T.numeric_storage_slots_survive_growth_and_manager_slot_reassignment()
  local store = FieldActorStore.new()
  local actors = {}
  local numericSlots = {}
  for i = 1, 40 do
    actors[i] = actor("a" .. i, i)
    store:addActor(actors[i])
    numericSlots[i] = store:allocateNumericState()
    local state = store:numericState(numericSlots[i])
    state.fieldX = i
    state.worldX = i * 1.5
    state.hasWorldPosition = 1
  end

  for i = 1, 40 do
    local state = store:numericState(numericSlots[i])
    Assert.equal(state.fieldX, i, "a storage slot must keep its value across buffer growth")
    Assert.equal(state.worldX, i * 1.5, "a storage slot must keep its value across buffer growth")
  end

  for i = 1, 40 do
    store:assignManagerSlot(actors[i])
  end
  store:replaceManagerSlots({ [0] = actors[40], [1] = actors[1] })

  Assert.equal(store:numericState(numericSlots[1]).fieldX, 1, "manager-slot reassignment must not move numeric storage")
  Assert.equal(
    store:numericState(numericSlots[40]).fieldX,
    40,
    "manager-slot reassignment must not move numeric storage"
  )
end

function T.releasing_a_numeric_slot_frees_it_for_reuse_without_touching_other_actors()
  local store = FieldActorStore.new()
  local first = actor("first", 4)
  local second = actor("second", 9)
  store:addActor(first)
  store:addActor(second)
  local firstSlot = store:allocateNumericState()
  local secondSlot = store:allocateNumericState()
  store:numericState(secondSlot).fieldX = 55

  store:releaseNumericState(firstSlot)
  local reused = store:allocateNumericState()
  Assert.equal(reused, firstSlot, "a released numeric slot must be reused before growing")
  Assert.equal(
    store:numericState(secondSlot).fieldX,
    55,
    "releasing one actor's numeric slot must not disturb another actor's storage"
  )
end

function T.persistence_translates_actor_state_to_the_existing_save_record()
  local persistence = FieldActorPersistence.new()
  local FieldObjectActor = require("libs.hgss.src.actors.FieldObjectActor")
  local FieldActorFixture = require("tests.support.FieldActorFixture")
  local visual = FieldActorFixture.visual(99)
  local numericStore = FieldActorStore.new()
  local testActor = FieldObjectActor.new({
    mapId = 61,
    sourceEvent = {
      objectEventId = 4,
      movementType = "wander_around",
      facingDirection = "west",
      facingDirectionRaw = 2,
    },
    fieldX = 12,
    fieldZ = 8,
    cellKey = "0:0",
    sourceSurfaceId = 12,
    visual = visual,
    idlePresentation = visual.idlePresentation,
    numericStore = numericStore,
    numericSlot = numericStore:allocateNumericState(),
  })
  testActor:setFacing("west")
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

return { tests = T }
