-- Committed player anchors: one movement revision per committed tile step,
-- never for interpolation ticks, turns, or blocked input. The following
-- controller replays these anchors, so phantom revisions would walk the
-- partner into walls.

local Assert = require("tests.support.Assert")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local MovementCalibration = require("libs.hgss.src.script.tasks.MovementCalibration")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")

local T = {}

local function terrain()
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

local function playerAt(fieldX, fieldZ, facing)
  local map = {
    mapId = 61,
    mapSymbol = "test-map",
    mapSection = "test-section",
    mapSectionNativeId = 7,
    followMode = "ALLOW",
    coordinateOrigin = { x = 0, z = 0 },
    scene = {},
    fieldData = {},
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      isBlockedLocal = function(_, x, z)
        return x == 0 and z == 1
      end,
      getLocal = function(_, x, z)
        return { blocked = x == 0 and z == 1, behavior = 0 }
      end,
    },
    terrain = terrain(),
    terrainDependencyHash = "test-terrain",
    fieldRegion = {},
    cameraType = 0,
    release = function() end,
    updateAnimated = function() end,
  } --[[@as RuntimeFieldMap]]
  return FieldPlayer.new({
    currentMap = map,
    fieldX = fieldX or 5,
    fieldZ = fieldZ or 5,
    surfaceId = 0,
    facing = facing or "south",
  })
end

local function settle(player)
  for _ = 1, 16 do
    if player.motion == "idle" then
      return
    end
    player:updateFixed({})
  end
  Assert.equal(player.motion, "idle", "the step must settle within its duration")
end

function T.committed_steps_bump_the_revision_once_each()
  local player = playerAt(5, 5, "south")
  Assert.equal(player:movementRevision(), 0, "a fresh player has committed nothing")
  local first = player:committedAnchor()
  Assert.equal(first.fieldX, 5, "the anchor starts on the player tile")
  Assert.equal(first.fieldZ, 5, "the anchor starts on the player tile")
  Assert.equal(first.facing, "south", "the anchor carries the player facing")
  Assert.equal(first.mapId, 61, "the anchor carries the map identity")
  Assert.isTrue(first.surfaceId ~= nil, "the anchor carries a surface identity")
  Assert.isTrue(first.worldY ~= nil, "the anchor carries a height")

  Assert.isTrue(player:tryStep("south"), "the south step must commit")
  settle(player)
  Assert.equal(player:movementRevision(), 1, "one committed tile is one revision")
  local second = player:committedAnchor()
  Assert.equal(second.fieldX, 5, "the anchor follows the commit")
  Assert.equal(second.fieldZ, 6, "the anchor follows the commit")

  Assert.isTrue(player:tryStep("south"), "the second step must commit")
  settle(player)
  Assert.equal(player:movementRevision(), 2, "each committed tile bumps once")
end

function T.interpolation_turns_and_blocked_input_bump_nothing()
  local player = playerAt(5, 5, "south")
  Assert.isTrue(player:tryStep("south"), "the step must start")
  Assert.equal(player:movementRevision(), 0, "starting a step commits nothing")
  player:updateFixed({})
  player:updateFixed({})
  Assert.equal(player:movementRevision(), 0, "interpolation ticks commit nothing")
  settle(player)
  Assert.equal(player:movementRevision(), 1, "only the commit bumps")

  -- A turn in place faces north without moving.
  player:updateFixed({ pressedDirection = "north" })
  settle(player)
  Assert.equal(player:movementRevision(), 1, "turning in place commits no tile")
  Assert.equal(player:committedAnchor().facing, "north", "the anchor still tracks facing")

  -- West from (5,6) is open; walk back then face the wall tile at local
  -- (0,1)... instead probe a directly blocked step: teleport-free check via
  -- a second player facing the blocked cell.
  local blocked = playerAt(1, 1, "west")
  Assert.isFalse(blocked:tryStep("west"), "the wall step must not start")
  Assert.equal(blocked:movementRevision(), 0, "blocked input commits nothing")
end

function T.scripted_commits_carry_their_own_traversal_kind()
  local player = playerAt(5, 5, "south")
  player:beginScriptedAction({ action = "walk", direction = "south", speed = "normal" })
  for _ = 1, 8 do
    player:advanceScriptedAction(1, 8)
  end
  player:commitScriptedAction()
  Assert.equal(player:movementRevision(), 1, "a scripted tile commit bumps once")
  Assert.equal(player:committedAnchor().traversalKind, "scripted", "scripted commits are marked")
  Assert.equal(player:committedAnchor().fieldZ, 6, "the anchor follows the scripted commit")
end

-- A resolved tile translation is observable at movement start, while the
-- committed anchor still describes the source tile. The snapshot carries
-- the final source/destination anchors, direction, traversal kind, and the
-- semantic normal-walk duration; blocked steps and facing-only turns
-- publish nothing.
function T.movement_start_snapshot_precedes_commit()
  local player = playerAt(5, 5, "south")
  Assert.isTrue(type(player.movementTransaction) == "function", "the player publishes a movement-start transaction")
  Assert.isNil(player:movementTransaction(), "no transaction exists before any step")

  Assert.isTrue(player:tryStep("south"), "the south step must start")
  local started = player:movementTransaction()
  Assert.notNil(started, "starting a step publishes a transaction")
  assert(started ~= nil, "starting a step publishes a transaction")
  Assert.equal(started.revision, 1, "the first started step is revision one")
  Assert.equal(started.mapId, 61, "the transaction carries the map identity")
  Assert.equal(started.from.fieldX, 5, "the transaction source is the vacated tile")
  Assert.equal(started.from.fieldZ, 5, "the transaction source is the vacated tile")
  Assert.equal(started.to.fieldX, 5, "the transaction destination is resolved at start")
  Assert.equal(started.to.fieldZ, 6, "the transaction destination is resolved at start")
  Assert.equal(started.direction, "south", "the transaction carries the step direction")
  Assert.equal(started.traversalKind, "walk", "an ordinary step is an ordinary walk")
  Assert.equal(started.durationTicks, FieldPlayer.WALK_STEP_TICKS, "the transaction carries the normal walk duration")
  Assert.equal(
    started.durationTicks,
    MovementCalibration.SPEED_TICKS.normal,
    "the transaction duration matches the actor normal calibration"
  )
  Assert.equal(player:movementRevision(), 0, "starting a step commits nothing")
  Assert.equal(player:committedAnchor().fieldZ, 5, "the committed anchor still describes the source tile")

  Assert.equal(player:movementTransaction().revision, 1, "repeated reads observe the same revision")
  player:updateFixed({})
  player:updateFixed({})
  Assert.equal(player:movementTransaction().revision, 1, "the revision is stable while the step is in flight")
  Assert.equal(player:movementRevision(), 0, "interpolation ticks commit nothing")
  settle(player)
  Assert.equal(player:movementRevision(), 1, "only the commit bumps the commit revision")
  Assert.equal(player:committedAnchor().fieldZ, 6, "the anchor follows the commit")
  Assert.equal(
    player:movementTransaction().revision,
    1,
    "the transaction stays readable after commit until the next step"
  )

  local blocked = playerAt(1, 1, "west")
  Assert.isFalse(blocked:tryStep("west"), "the wall step must not start")
  Assert.isNil(blocked:movementTransaction(), "a blocked step publishes no transaction")
  Assert.equal(blocked:movementRevision(), 0, "a blocked step commits nothing")

  local turner = playerAt(5, 5, "south")
  turner:updateFixed({ pressedDirection = "north" })
  settle(turner)
  Assert.equal(turner.facing, "north", "the turn in place applies")
  Assert.isNil(turner:movementTransaction(), "a facing-only turn publishes no transaction")
  Assert.equal(turner:movementRevision(), 0, "a facing-only turn commits nothing")
end

-- A scripted one-tile walk publishes the same movement-start shape as an
-- ordinary walk before its first presentation tick: revisioned, carrying
-- the committed source tile, the resolved adjacent destination, the walk
-- direction, and the action's own calibrated duration. Each repeated tile
-- publishes again with a fresh revision.
function T.scripted_walk_publishes_a_movement_start_per_repeated_tile()
  local player = playerAt(5, 5, "south")
  Assert.isNil(player:movementTransaction(), "no transaction exists before any scripted walk")

  player:beginScriptedAction({ action = "walk", direction = "south", speed = "normal" })
  local first = player:movementTransaction()
  Assert.notNil(first, "beginning a scripted walk publishes a transaction")
  assert(first ~= nil, "beginning a scripted walk publishes a transaction")
  Assert.equal(first.revision, 1, "the first scripted tile is revision one")
  Assert.equal(first.mapId, 61, "the transaction carries the map identity")
  Assert.equal(first.from.fieldX, 5, "the transaction source is the committed tile")
  Assert.equal(first.from.fieldZ, 5, "the transaction source is the committed tile")
  Assert.equal(first.to.fieldX, 5, "the transaction destination is the resolved adjacent tile")
  Assert.equal(first.to.fieldZ, 6, "the transaction destination is the resolved adjacent tile")
  Assert.equal(first.direction, "south", "the transaction carries the scripted walk direction")
  Assert.equal(first.traversalKind, "walk", "a scripted translational walk is an ordinary walk")
  Assert.equal(
    first.durationTicks,
    MovementCalibration.actionTicks({ action = "walk", direction = "south", speed = "normal" }),
    "the transaction carries the scripted action's own calibrated duration"
  )
  Assert.equal(player:movementRevision(), 0, "beginning a scripted walk commits nothing")

  for progress = 1, 8 do
    player:advanceScriptedAction(progress, 8)
  end
  player:commitScriptedAction()
  Assert.equal(player:movementRevision(), 1, "the scripted tile commit bumps once")

  player:beginScriptedAction({ action = "walk", direction = "south", speed = "normal" })
  local second = player:movementTransaction()
  Assert.notNil(second, "the repeated scripted tile publishes again")
  assert(second ~= nil, "the repeated scripted tile publishes again")
  Assert.equal(second.revision, 2, "each repeated tile advances the revision")
  Assert.equal(second.from.fieldZ, 6, "the repeated tile sources from the committed tile")
  Assert.equal(second.to.fieldZ, 7, "the repeated tile resolves its own adjacent destination")
  Assert.equal(second.traversalKind, "walk", "every repeated tile stays an ordinary walk")
end

-- Presentation-only and non-translational scripted actions never publish a
-- walk start: staying on the spot, jumping, facing, and waiting carry no
-- vacated tile for a follower to trail. A walk rejected before motion
-- begins publishes nothing either.
function T.scripted_non_walk_actions_publish_no_movement_start()
  local stepper = playerAt(5, 5, "south")
  stepper:beginScriptedAction({ action = "walk_in_place", direction = "south", speed = "normal" })
  Assert.isNil(stepper:movementTransaction(), "an on-spot scripted walk publishes no transaction")

  local jumper = playerAt(5, 5, "south")
  jumper:beginScriptedAction({ action = "jump", direction = "south", distance = "near", speed = "fast" })
  Assert.isNil(jumper:movementTransaction(), "a scripted jump publishes no transaction")

  local facer = playerAt(5, 5, "south")
  facer:beginScriptedAction({ action = "face", direction = "north" })
  Assert.isNil(facer:movementTransaction(), "an instantaneous scripted face publishes no transaction")

  local waiter = playerAt(5, 5, "south")
  waiter:beginScriptedAction({ action = "delay", ticks = 4 })
  Assert.isNil(waiter:movementTransaction(), "a scripted delay publishes no transaction")

  local emoter = playerAt(5, 5, "south")
  emoter:beginScriptedAction({ action = "emote", name = "exclamation" })
  Assert.isNil(emoter:movementTransaction(), "a scripted emote publishes no transaction")

  local blocked = playerAt(0, 4, "west")
  local ok = pcall(function()
    blocked:beginScriptedAction({ action = "walk", direction = "west", speed = "normal" })
  end)
  Assert.isFalse(ok, "a scripted walk without a destination surface must fail")
  Assert.isNil(blocked:movementTransaction(), "a rejected scripted walk publishes no transaction")
  Assert.equal(blocked:movementRevision(), 0, "a rejected scripted walk commits nothing")
end

return { tests = T }
