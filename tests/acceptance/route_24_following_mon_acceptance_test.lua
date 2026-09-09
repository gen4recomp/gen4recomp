-- Production-composed contract for Route 24's Rocket cutscene program shape:
-- the follower movement mode switches to the transition mode through the
-- real script-command dispatch, a fast scripted player walk carries the
-- follower at the remembered fast pace, the follower wait observes real
-- settlement, and the mode restores to ordinary free following. Real
-- ROM-derived Route 24 map data, the real field runtime, and the real mon
-- service stay in the path; only host boundaries (audio, saves, clock) are
-- faked by the harness. The partner is stacked on the tile the probe step
-- vacates so command replay and previous-tile steering observably diverge;
-- the cutscene script bytes themselves are pinned at the ROM layer.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "following-mon", "route-24" },
  },
  tests = {},
}

local MAP = "MAP_R24"

-- Select the follower movement mode through the production script-command
-- dispatch, the same handler the generated cutscene reaches. The command
-- continues in the same tick instead of dropping.
local function dispatchMovementMode(game, movementType)
  local run = {
    instance = { scriptId = "test.route-24-follower", locals = {}, textArgs = {} },
    services = { followingMon = game.runtime.followingMon },
    semantics = RuntimeValues,
    scheduler = {
      createTask = function(_, taskType)
        return "task:" .. taskType
      end,
    },
    tick = 1,
    input = {},
  }
  Assert.equal(
    Runtime.executeNode({ op = "follower_set_movement_type", movementType = movementType }, run),
    Runtime.OUTCOME_CONTINUE,
    "the movement-mode command continues instead of dropping"
  )
end

-- Drive one scripted player walk through the production runtime and settle
-- both actors. Returns the vacated player tile and the follower tile before
-- the step.
local function driveScriptedWalk(game, partnerId, direction, speed)
  local before = game:snapshot()
  local vacated = { fieldX = before.player.fieldX, fieldZ = before.player.fieldZ }
  local followerBefore = assert(before.actors[partnerId], "the partner must be installed before the step")
  game.runtime.player:beginScriptedAction({ action = "walk", direction = direction, speed = speed })
  game:advanceUntil("scripted player walk resolves", function(snapshot)
    return snapshot.player.motion == "idle"
  end, 120)
  game:advanceUntil("follower trail settles", function()
    return game.runtime.followingMon:isMovementSettled()
  end, 180)
  Assert.isNil(game.runtime.errorText, "field runtime faulted while driving the " .. direction .. " step")
  return vacated, { fieldX = followerBefore.fieldX, fieldZ = followerBefore.fieldZ }
end

function T.tests.transition_mode_replays_the_follower_command_through_the_fast_cutscene_program()
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local added = game.runtime.monService:giveMon({ species = "CHIKORITA", level = 5, form = 0 })
    Assert.isTrue(added, "setup gift must enter the party")
    game:advanceUntil("follower installation after party gift", function()
      return game.runtime.actors:partnerId() ~= nil
    end, 120)
    local id = assert(game.runtime.actors:partnerId(), "the gifted lead must install one partner actor")
    Assert.isNil(game.runtime.errorText, "field runtime faulted while installing the follower")

    -- Seed a remembered east/fast follower command with two real scripted
    -- walks at the cutscene's own fast pace: east trails south, then west
    -- trails east.
    local vacatedEast = driveScriptedWalk(game, id, "east", "fast")
    do
      local snap = game:snapshot()
      local partner = assert(snap.actors[id], "the partner survives the fast east step")
      Assert.equal(partner.fieldX, vacatedEast.fieldX, "the fast east trail settles onto the vacated tile")
      Assert.equal(partner.fieldZ, vacatedEast.fieldZ, "the fast east trail settles onto the vacated tile")
    end
    local vacatedWest = driveScriptedWalk(game, id, "west", "fast")
    do
      local snap = game:snapshot()
      local partner = assert(snap.actors[id], "the partner survives the fast west step")
      Assert.equal(partner.fieldX, vacatedWest.fieldX, "the fast west trail settles onto the vacated tile")
      Assert.equal(partner.fieldZ, vacatedWest.fieldZ, "the fast west trail settles onto the vacated tile")
    end

    -- The cutscene program selects the transition mode through production
    -- dispatch, then moves the player while the follower replays.
    dispatchMovementMode(game, "follow_transition_b")
    Assert.equal(
      game.runtime.followingMon._movementType,
      "follow_transition_b",
      "the dispatched transition mode stores"
    )

    -- Stack the partner on the tile the probe step vacates: previous-tile
    -- steering would hold still there, while command replay steps east at
    -- the remembered fast pace.
    local stacked = game:snapshot().player
    game.runtime.actors:setPosition(id, { fieldX = stacked.fieldX, fieldZ = stacked.fieldZ })
    do
      local partner = assert(game:snapshot().actors[id], "the partner survives the arrangement")
      Assert.equal(partner.fieldX, stacked.fieldX, "the arrangement stacks the partner on the player tile")
      Assert.equal(partner.fieldZ, stacked.fieldZ, "the arrangement stacks the partner on the player tile")
    end

    game.runtime.player:beginScriptedAction({ action = "walk", direction = "north", speed = "fast" })
    game:step()
    Assert.isNil(game.runtime.errorText, "field runtime faulted on the transition step")
    Assert.isFalse(
      game.runtime.followingMon:isMovementSettled(),
      "the follower replays its remembered command while the player step is still in flight"
    )
    do
      local actor = assert(game.runtime.actors:getById(id), "the partner survives the transition step start")
      Assert.equal(actor.pose, "walk", "the replay walks while the player step is in flight")
      Assert.equal(actor.facing, "east", "the replay faces the remembered direction, not the vacated tile")
      local motion = assert(actor:scriptedMotionState(), "the replay has an active presentation")
      Assert.equal(motion.speed, "fast", "the replay keeps the remembered fast pace")
    end
    game:advanceUntil("fast transition step resolves", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 120)
    game:advanceUntil("replay settles", function()
      return game.runtime.followingMon:isMovementSettled()
    end, 180)
    Assert.isNil(game.runtime.errorText, "field runtime faulted while settling the replay")
    do
      local snap = game:snapshot()
      local partner = assert(snap.actors[id], "the partner survives the replay")
      Assert.equal(partner.fieldX, stacked.fieldX + 1, "the replay steps east instead of holding the vacated tile")
      Assert.equal(partner.fieldZ, stacked.fieldZ, "the replay holds its row while stepping east")
      Assert.equal(partner.facing, "east", "the replay keeps the remembered facing after settling")
    end

    -- The cutscene close restores ordinary free following with no
    -- transition obligation left behind.
    dispatchMovementMode(game, "follow_player")
    Assert.equal(
      game.runtime.followingMon._movementType,
      "follow_player",
      "the dispatched restoration returns ordinary free following"
    )
    Assert.isTrue(game.runtime.followingMon:isMovementSettled(), "restoration leaves no transition obligation behind")
    Assert.equal(game:renderAttempts(), 0, "route-24 acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
