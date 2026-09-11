-- FieldActorStateBuffer owns the contiguous cdata numeric/boolean record for
-- one FieldActorStore's actors: capacity, slot allocate/release, default
-- initialization, and geometric growth that preserves every active slot's
-- storage-slot identity and values.

local Assert = require("tests.support.Assert")
local FieldActorStateBuffer = require("libs.hgss.src.actors.FieldActorStateBuffer")

local T = {}

function T.a_fresh_slot_has_zeroed_numeric_fields_and_cleared_presence_flags()
  local buffer = FieldActorStateBuffer.new()
  local slot = buffer:allocate()
  Assert.equal(slot, 0, "the first allocated slot is zero-based")
  local state = buffer:at(slot)
  Assert.equal(state.fieldX, 0)
  Assert.equal(state.fieldZ, 0)
  Assert.equal(state.worldX, 0)
  Assert.equal(state.worldY, 0)
  Assert.equal(state.worldZ, 0)
  Assert.equal(state.hasWorldPosition, 0, "a fresh slot has no world position presence")
  Assert.equal(state.hasPreviousWorldPosition, 0, "a fresh slot has no previous world position presence")
  Assert.equal(state.hasSourceSurfaceId, 0, "a fresh slot has no source surface presence")
  Assert.equal(state.hasSurfaceId, 0, "a fresh slot has no surface presence")
  Assert.equal(state.hasGestureTick, 0, "a fresh slot has no gesture tick presence")
  Assert.equal(state.resident, 0)
  Assert.equal(state.visible, 0)
  Assert.equal(state.solid, 0)
  Assert.equal(state.animationPaused, 0)
  Assert.equal(state.scriptedPresentationAdvanced, 0)
end

function T.allocate_returns_sequential_zero_based_slots()
  local buffer = FieldActorStateBuffer.new()
  Assert.equal(buffer:allocate(), 0)
  Assert.equal(buffer:allocate(), 1)
  Assert.equal(buffer:allocate(), 2)
end

function T.writes_through_at_persist_until_read_back()
  local buffer = FieldActorStateBuffer.new()
  local slot = buffer:allocate()
  local state = buffer:at(slot)
  state.fieldX = 12
  state.worldY = 4.5
  state.hasWorldPosition = 1
  local reread = buffer:at(slot)
  Assert.equal(reread.fieldX, 12)
  Assert.equal(reread.worldY, 4.5)
  Assert.equal(reread.hasWorldPosition, 1)
end

function T.releasing_an_unallocated_or_already_released_slot_fails_loudly()
  local buffer = FieldActorStateBuffer.new()
  Assert.throws(function()
    buffer:release(0)
  end, "releasing a never-allocated slot must fail")
  local slot = buffer:allocate()
  buffer:release(slot)
  Assert.throws(function()
    buffer:release(slot)
  end, "double release must fail")
end

function T.accessing_a_released_or_out_of_range_slot_fails_loudly()
  local buffer = FieldActorStateBuffer.new()
  local slot = buffer:allocate()
  buffer:release(slot)
  Assert.throws(function()
    buffer:at(slot)
  end, "reading a released slot must fail")
  Assert.throws(function()
    buffer:at(-1)
  end, "reading a negative slot must fail")
  Assert.throws(function()
    buffer:at(999)
  end, "reading an out-of-range slot must fail")
end

function T.a_released_slot_is_reused_and_reinitialized_without_leaking_the_previous_occupant()
  local buffer = FieldActorStateBuffer.new()
  local first = buffer:allocate()
  local state = buffer:at(first)
  state.fieldX = 42
  state.hasSurfaceId = 1
  state.surfaceId = 7
  state.visible = 1
  buffer:release(first)

  local second = buffer:allocate()
  Assert.equal(second, first, "a freed slot is reused before growing capacity")
  local reused = buffer:at(second)
  Assert.equal(reused.fieldX, 0, "a reused slot must not leak the previous occupant's numeric state")
  Assert.equal(reused.hasSurfaceId, 0, "a reused slot must not leak the previous occupant's presence flags")
  Assert.equal(reused.surfaceId, 0, "a reused slot must not leak the previous occupant's numeric state")
  Assert.equal(reused.visible, 0, "a reused slot must not leak the previous occupant's boolean state")
end

function T.growth_preserves_every_active_slots_values_and_identity()
  local buffer = FieldActorStateBuffer.new(2)
  local slots = {}
  for i = 1, 40 do
    slots[i] = buffer:allocate()
    local state = buffer:at(slots[i])
    state.fieldX = i
    state.worldX = i * 1.25
    state.hasWorldPosition = 1
    state.poseTick = i * 2
  end
  for i = 1, 40 do
    Assert.equal(slots[i], i - 1, "growth must not renumber a previously allocated slot")
    local state = buffer:at(slots[i])
    Assert.equal(state.fieldX, i, "growth must preserve a slot's numeric state")
    Assert.equal(state.worldX, i * 1.25, "growth must preserve a slot's numeric state")
    Assert.equal(state.hasWorldPosition, 1, "growth must preserve a slot's presence flags")
    Assert.equal(state.poseTick, i * 2, "growth must preserve a slot's numeric state")
  end
end

-- Cycles allocate/mutate/release/grow across many actors and cross-checks
-- every live slot against a pure Lua expected-state map, so growth, free-list
-- reuse, and slot stability all hold together under churn.
function T.allocate_release_and_growth_cycle_matches_an_independent_expected_state_map()
  local buffer = FieldActorStateBuffer.new(4)
  local expected = {}
  local live = {}

  local function spawn(tag)
    local slot = buffer:allocate()
    local state = buffer:at(slot)
    state.fieldX = tag
    state.fieldZ = tag * 3
    state.hasSurfaceId = 1
    state.surfaceId = tag % 5
    expected[slot] = { fieldX = tag, fieldZ = tag * 3, surfaceId = tag % 5 }
    live[#live + 1] = slot
  end

  local function despawn(index)
    local slot = table.remove(live, index)
    buffer:release(slot)
    expected[slot] = nil
  end

  local tag = 0
  for round = 1, 60 do
    tag = tag + 1
    spawn(tag)
    if round % 3 == 0 and #live > 1 then
      despawn(1)
    end
  end

  for slot, want in pairs(expected) do
    local state = buffer:at(slot)
    Assert.equal(state.fieldX, want.fieldX, "slot " .. slot .. " must keep its own fieldX through churn")
    Assert.equal(state.fieldZ, want.fieldZ, "slot " .. slot .. " must keep its own fieldZ through churn")
    Assert.equal(state.surfaceId, want.surfaceId, "slot " .. slot .. " must keep its own surfaceId through churn")
  end
end

return { tests = T }
