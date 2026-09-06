-- FieldObjectActor tests freeze the immutable-source / mutable-runtime split,
-- the stable actor identity, and the tokenized temporary facing override.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldObjectActor = require("libs.hgss.src.actors.FieldObjectActor")
local FieldActorFixture = require("tests.support.FieldActorFixture")

local T = {}

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(err.code, code, "expected " .. code .. ", got " .. Errors.format(err))
  return err
end

local function sourceEvent(overrides)
  local event = {
    index = 0,
    objectEventId = 0,
    spriteId = 99,
    movementType = "stationary",
    type = 0,
    eventFlag = 401,
    scriptId = 1,
    facingDirection = "south",
    facingDirectionRaw = 1,
    param0 = 0,
    param1 = 0,
    param2 = 0,
    xRange = 0,
    yRange = 0,
    x = 6,
    z = 5,
    y = 0,
  }
  for key, value in pairs(overrides or {}) do
    event[key] = value
  end
  return event
end

local function actor(overrides, optsOverrides)
  local visual = FieldActorFixture.visual(99)
  local opts = {
    mapId = 61,
    sourceEvent = sourceEvent(overrides),
    fieldX = 6,
    fieldZ = 5,
    surfaceId = 0,
    worldX = 6.5,
    worldY = 0,
    worldZ = 5.5,
    visual = visual,
    idlePresentation = visual.idlePresentation,
  }
  for key, value in pairs(optsOverrides or {}) do
    rawset(opts, key, value)
  end
  return FieldObjectActor.new(opts)
end

function T.actor_id_is_map_and_object_identity()
  Assert.equal(FieldObjectActor.actorId(61, 3), "map:61:object:3")
  Assert.equal(actor().actorId, "map:61:object:0")
end

function T.runtime_state_starts_from_the_source_record()
  local a = actor()
  Assert.equal(a.spriteId, 99)
  Assert.equal(a.initialFacing, "south")
  Assert.equal(a.facing, "south")
  Assert.equal(a.pose, "idle")
  Assert.equal(a.poseTick, 0)
  Assert.isTrue(a.visible)
  Assert.isTrue(a.solid)
  Assert.equal(a.movementType, "stationary")
  Assert.isNil(a.interactionFacingOverride)
end

-- A zero interaction script is the source's inert map-object marker for
-- A-button interaction, not a solidity signal: a visible zero-script actor
-- still follows source collision semantics unless the event explicitly opts
-- out.
function T.zero_script_actors_remain_solid_by_default()
  Assert.isTrue(actor({ scriptId = 0 }).solid)
end

function T.explicit_non_solid_semantic_is_honored_regardless_of_script_id()
  Assert.isFalse(actor({ scriptId = 0 }, { solid = false }).solid)
  Assert.isFalse(actor({ scriptId = 5 }, { solid = false }).solid)
end

function T.unknown_source_facing_is_rejected()
  throwsCode("ACTOR_FACING_INVALID", function()
    actor({ facingDirection = "unknown", facingDirectionRaw = 9 })
  end)
end

function T.facing_override_applies_and_restores()
  local a = actor()
  local token = a:pushFacingOverride({ owner = "pre-script-dialogue", facing = "north" })
  Assert.equal(a.facing, "north")
  Assert.equal(a.initialFacing, "south")
  a:releaseFacingOverride(token)
  Assert.equal(a.facing, "south")
  Assert.isNil(a.interactionFacingOverride)
end

function T.override_restores_the_facing_it_replaced_not_the_source_facing()
  local a = actor()
  a.facing = "east"
  local token = a:pushFacingOverride({ owner = "pre-script-dialogue", facing = "north" })
  a:releaseFacingOverride(token)
  Assert.equal(a.facing, "east")
end

function T.nested_overrides_are_rejected()
  local a = actor()
  a:pushFacingOverride({ owner = "pre-script-dialogue", facing = "north" })
  throwsCode("ACTOR_OVERRIDE_OWNER_MISMATCH", function()
    a:pushFacingOverride({ owner = "someone-else", facing = "west" })
  end)
end

function T.releasing_a_foreign_token_is_rejected()
  local a = actor()
  a:pushFacingOverride({ owner = "pre-script-dialogue", facing = "north" })
  throwsCode("ACTOR_OVERRIDE_OWNER_MISMATCH", function()
    a:releaseFacingOverride({})
  end)
  Assert.equal(a.facing, "north")
end

function T.releasing_twice_is_rejected()
  local a = actor()
  local token = a:pushFacingOverride({ owner = "pre-script-dialogue", facing = "north" })
  a:releaseFacingOverride(token)
  throwsCode("ACTOR_OVERRIDE_OWNER_MISMATCH", function()
    a:releaseFacingOverride(token)
  end)
end

function T.clear_facing_override_is_unconditional_and_idempotent()
  local a = actor()
  a:pushFacingOverride({ owner = "pre-script-dialogue", facing = "north" })
  a:clearFacingOverride()
  a:clearFacingOverride()
  Assert.equal(a.facing, "south")
end

-- Rebasing an active action re-anchors its physical endpoints at unchanged
-- progress: the interpolated world position follows the new frame while
-- pose, gesture, and render-offset clocks do not advance.
function T.reproject_active_action_rebases_world_position_without_advancing_presentation()
  local a = actor()
  a:beginAction({
    action = "walk",
    direction = "east",
    distance = "near",
    speed = "normal",
    start = {
      fieldX = 6,
      fieldZ = 5,
      worldX = 10,
      worldY = 0,
      worldZ = 20,
      surfaceId = 0,
      resident = true,
    },
    dest = {
      fieldX = 7,
      fieldZ = 5,
      worldX = 11,
      worldY = 0,
      worldZ = 20,
      surfaceId = 0,
      resident = true,
    },
    durationTicks = 8,
  }, "autonomous")
  a:advanceAction(2, 8)
  Assert.isTrue(a.poseTick > 0, "the test must observe a nonzero presentation clock")
  local poseBefore, poseTickBefore = a.pose, a.poseTick
  local presentationBefore = a:presentationState()
  local offsetYBefore = a.presentationOffset.y

  a:reprojectActiveAction(
    { fieldX = 6, fieldZ = 5, worldX = 110, worldY = 0, worldZ = 120, surfaceId = 0, resident = true },
    { fieldX = 7, fieldZ = 5, worldX = 111, worldY = 0, worldZ = 120, surfaceId = 0, resident = true }
  )

  Assert.equal(a.pose, poseBefore, "reprojection must not advance the pose clock")
  Assert.equal(a.poseTick, poseTickBefore, "reprojection must not advance the pose clock")
  local presentationAfter = a:presentationState()
  Assert.equal(presentationAfter.gesturePose, presentationBefore.gesturePose, "reprojection must not touch gestures")
  Assert.equal(presentationAfter.gestureTick, presentationBefore.gestureTick, "reprojection must not touch gestures")
  Assert.equal(
    presentationAfter.gestureOffsetY,
    presentationBefore.gestureOffsetY,
    "reprojection must not touch gestures"
  )
  Assert.equal(a.presentationOffset.y, offsetYBefore, "reprojection must not double-apply render offsets")
  Assert.equal(a.worldX, 110.25, "reprojection recomputes the world position at unchanged progress")
  Assert.equal(a.worldZ, 120, "reprojection recomputes the world position at unchanged progress")
  Assert.equal(a.worldY, 0, "reprojection recomputes the world position at unchanged progress")
  local motion = assert(a:scriptedMotionState(), "reprojection must keep the action active")
  Assert.equal(motion.progressTicks, 2, "reprojection must not advance action progress")

  Assert.throws(function()
    a:reprojectActiveAction({ fieldX = 999, fieldZ = 5 }, { fieldX = 7, fieldZ = 5 })
  end, "reprojection must reject endpoints that disagree with the active action")
end

return { tests = T }
