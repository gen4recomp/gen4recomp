-- FieldActorAutonomy tests cover semantic controller timing without field I/O.

local Assert = require("tests.support.Assert")
local FieldActorAutonomy = require("libs.hgss.src.actors.FieldActorAutonomy")
local ScriptRng = require("libs.hgss.src.script.ScriptRng")

local T = {}

local function rng(values)
  local index = 0
  return {
    nextInt = function(_, maximum)
      index = index + 1
      local value = values[index] or 0
      Assert.isTrue(value >= 0 and value < maximum, "deterministic roll must fit its bound")
      return value
    end,
  }
end

local function actorEvent(movementType, overrides)
  local event = {
    x = 4,
    z = 5,
    y = 0,
    facingDirection = "south",
    movementType = movementType,
    type = 0,
    param0 = 0,
  }
  for key, value in pairs(overrides or {}) do
    event[key] = value
  end
  return event
end

local function capability(overrides)
  local calls = { facing = {}, walks = {}, patternSteps = {} }
  local result = {
    fieldX = 4,
    fieldZ = 5,
    positionYBand = 0,
    setFacing = function(_, actorId, direction)
      calls.facing[#calls.facing + 1] = { actorId = actorId, direction = direction }
    end,
    walk = function(_, actorId, direction)
      calls.walks[#calls.walks + 1] = { actorId = actorId, direction = direction }
      return true
    end,
    patternStep = function(_, actorId, direction)
      calls.patternSteps[#calls.patternSteps + 1] = { actorId = actorId, direction = direction }
      return true
    end,
  }
  for key, value in pairs(overrides or {}) do
    rawset(result, key, value)
  end
  result.calls = calls
  return result
end

function T.random_profiles_use_profile_directions_and_source_waits()
  local autonomy = FieldActorAutonomy.new({ rng = rng({ 0, 3 }) })
  autonomy:attach("actor", "look_north_west", actorEvent("look_north_west"))
  local look = capability()
  autonomy:step("actor", look)
  Assert.equal(look.calls.facing[1].direction, "north")
  Assert.equal(autonomy:state("actor").timer, 64)

  autonomy = FieldActorAutonomy.new({ rng = rng({ 1, 0 }) })
  autonomy:attach("walker", "wander_west_east", actorEvent("wander_west_east"))
  local walk = capability()
  autonomy:step("walker", walk)
  Assert.equal(walk.calls.facing[1].direction, "east")
  Assert.equal(walk.calls.walks[1].direction, "east")
  Assert.equal(autonomy:state("walker").timer, 16)
end

function T.fixed_rotation_and_spin_profiles_do_not_translate()
  local autonomy = FieldActorAutonomy.new({ rng = rng({ 0, 0 }) })
  autonomy:attach("fixed", "look_west", actorEvent("look_west"))
  local fixed = capability()
  autonomy:step("fixed", fixed)
  Assert.equal(fixed.calls.facing[1].direction, "west")
  Assert.equal(#fixed.calls.walks, 0)

  autonomy:attach("spin", "vs_seeker_spin", actorEvent("vs_seeker_spin"))
  local spin = capability()
  Assert.equal(#spin.calls.walks, 0)
  for _ = 1, 23 do
    autonomy:step("spin", spin)
  end
  Assert.equal(#spin.calls.facing, 0)
  autonomy:step("spin", spin)
  Assert.equal(spin.calls.facing[1].direction, "west")
  Assert.equal(autonomy:state("spin").timer, 24)
end

function T.rotation_and_sequence_profiles_preserve_order_and_pattern_requests_one_direction()
  local autonomy = FieldActorAutonomy.new({ rng = rng({ 0 }) })
  autonomy:attach("rotate", "rotate_clockwise", actorEvent("rotate_clockwise"))
  local rotate = capability()
  autonomy:step("rotate", rotate)
  Assert.equal(rotate.calls.facing[1].direction, "west")
  Assert.equal(autonomy:state("rotate").timer, 24)

  autonomy:attach(
    "pattern",
    "walk_north_east_west_south",
    actorEvent("walk_north_east_west_south", { facingDirection = "north" })
  )
  local pattern
  pattern = capability({
    patternStep = function(_, actorId, direction)
      pattern.calls.patternSteps[#pattern.calls.patternSteps + 1] = { actorId = actorId, direction = direction }
      return true
    end,
  })
  autonomy:step("pattern", pattern)
  Assert.equal(#pattern.calls.patternSteps, 1)
  Assert.equal(pattern.calls.patternSteps[1].direction, "north")
  Assert.equal(autonomy:state("pattern").sequenceIndex, 2)

  local rejected
  rejected = capability({
    patternStep = function(_, actorId, direction)
      rejected.calls.patternSteps[#rejected.calls.patternSteps + 1] = { actorId = actorId, direction = direction }
      return false
    end,
  })
  autonomy:step("pattern", rejected)
  Assert.equal(#rejected.calls.patternSteps, 1)
  Assert.equal(rejected.calls.patternSteps[1].direction, "east")
  Assert.equal(autonomy:state("pattern").sequenceIndex, 2, "sequence advances only after an action starts")

  autonomy:attach("shuttle", "walk_back_and_forth", actorEvent("walk_back_and_forth"))
  local shuttle
  shuttle = capability({
    walk = function(_, actorId, direction)
      shuttle.calls.walks[#shuttle.calls.walks + 1] = { actorId = actorId, direction = direction }
      return false
    end,
  })
  autonomy:step("shuttle", shuttle)
  Assert.equal(shuttle.calls.walks[1].direction, "south")
  Assert.equal(shuttle.calls.walks[2].direction, "north")
end

function T.nearby_player_facing_requires_source_gates_and_allowed_direction()
  local autonomy = FieldActorAutonomy.new({ rng = rng({ 1, 1, 1, 1 }) })
  autonomy:attach("actor", "look_north_south", actorEvent("look_north_south", { type = 1, param0 = 2 }))
  local near = capability({ player = { fieldX = 4, fieldZ = 4, positionYBand = 0, surfaceId = 2 } })
  autonomy:step("actor", near)
  Assert.equal(near.calls.facing[1].direction, "north")

  local far = capability({ player = { fieldX = 4, fieldZ = 8, positionYBand = 0, surfaceId = 1 } })
  autonomy:setMovementType("actor", "look_north_south")
  autonomy:step("actor", far)
  Assert.equal(far.calls.facing[1].direction, "south")

  local wrongBand = capability({ player = { fieldX = 4, fieldZ = 4, positionYBand = 1, surfaceId = 1 } })
  autonomy:setMovementType("actor", "look_north_south")
  autonomy:step("actor", wrongBand)
  Assert.equal(wrongBand.calls.facing[1].direction, "south")
end

function T.vs_seeker_spin_turnaround_dwells_before_reversal()
  local cases = {
    {
      initialFacing = "north",
      directions = { "east", "south", "west", "north", "west" },
      turnaroundIndex = 1,
    },
    {
      initialFacing = "east",
      directions = { "south", "west", "north", "east", "north" },
      turnaroundIndex = 4,
    },
  }

  for _, testCase in ipairs(cases) do
    local autonomy = FieldActorAutonomy.new({ rng = rng({ 0 }) })
    autonomy:attach(
      "spin",
      "vs_seeker_spin",
      actorEvent("vs_seeker_spin", {
        facingDirection = testCase.initialFacing,
      })
    )
    local spin = capability()

    for expiry, direction in ipairs(testCase.directions) do
      for _ = 1, 23 do
        autonomy:step("spin", spin)
      end
      Assert.equal(#spin.calls.facing, expiry - 1)

      autonomy:step("spin", spin)
      Assert.equal(#spin.calls.facing, expiry)
      Assert.equal(spin.calls.facing[expiry].direction, direction)
      Assert.equal(autonomy:state("spin").timer, 24)

      if expiry == 4 then
        local state = autonomy:state("spin")
        Assert.equal(state.spinMode, "counterclockwise")
        Assert.equal(state.spinIndex, testCase.turnaroundIndex)
      end
    end
  end
end

function T.vs_seeker_spin_turnaround_capture_restores_next_turn()
  local autonomy = FieldActorAutonomy.new({ rng = rng({ 0 }) })
  autonomy:attach("spin", "vs_seeker_spin", actorEvent("vs_seeker_spin", { facingDirection = "east" }))
  local uninterrupted = capability()
  for _ = 1, 96 do
    autonomy:step("spin", uninterrupted)
  end

  local controller = autonomy:capture("spin")
  Assert.deepEqual(controller, {
    kind = "spin",
    timer = 24,
    spinMode = "counterclockwise",
    spinIndex = 4,
  })

  local restored = FieldActorAutonomy.new({ rng = rng({ 0 }) })
  restored:attach("spin", "vs_seeker_spin", actorEvent("vs_seeker_spin", { facingDirection = "east" }))
  restored:restore("spin", "vs_seeker_spin", controller)
  local resumed = capability()

  for _ = 1, 23 do
    autonomy:step("spin", uninterrupted)
    restored:step("spin", resumed)
  end
  Assert.equal(#uninterrupted.calls.facing, 4)
  Assert.equal(#resumed.calls.facing, 0)

  autonomy:step("spin", uninterrupted)
  restored:step("spin", resumed)
  Assert.equal(uninterrupted.calls.facing[5].direction, "north")
  Assert.equal(resumed.calls.facing[1].direction, "north")
end

function T.special_profiles_suspend_and_type_changes_reset_or_defer_state()
  local autonomy = FieldActorAutonomy.new({ rng = rng({ 0, 0 }) })
  autonomy:attach("actor", "follow_player", actorEvent("follow_player"))
  local special = capability()
  autonomy:step("actor", special)
  Assert.equal(#special.calls.facing, 0)
  Assert.equal(#special.calls.walks, 0)

  autonomy:setMovementType("actor", "look_east")
  local fixed = capability()
  autonomy:step("actor", fixed)
  Assert.equal(fixed.calls.facing[1].direction, "east")

  autonomy:setMovementType("actor", "wander_north_south", true)
  Assert.equal(autonomy:state("actor").movementType, "look_east")
  autonomy:applyPendingMovementType("actor")
  Assert.equal(autonomy:state("actor").movementType, "wander_north_south")
  autonomy:detach("actor")
  Assert.throws(function()
    autonomy:state("actor")
  end)
end

function T.controller_and_rng_state_round_trip_without_rerolling()
  local autonomy = FieldActorAutonomy.new({ rng = ScriptRng.new(17) })
  autonomy:attach("actor", "wander_north_south", actorEvent("wander_north_south"))
  autonomy:step("actor", capability())
  local controller = autonomy:capture("actor")
  local rngRecord = autonomy:captureRng()

  local restored = FieldActorAutonomy.new({ rng = ScriptRng.new(99) })
  restored:attach("actor", "wander_north_south", actorEvent("wander_north_south"))
  restored:restoreRng(rngRecord)
  restored:restore("actor", "wander_north_south", controller)
  Assert.deepEqual(controller, restored:capture("actor"))
  Assert.deepEqual(rngRecord, restored:captureRng())
end

return { tests = T }
