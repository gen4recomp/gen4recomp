-- Starter acquisition reveals the follower through the pending transition:
-- party mutation, a pre-publication transition command through production
-- script dispatch, hidden partner publication, reveal, then one ordinary
-- player step with synchronized visible following. Real ROM-derived maps,
-- the real field runtime, and the real mon service stay in the path; only
-- host boundaries (audio, saves, clock) are faked by the harness. Party
-- setup calls the production mon service directly and the transition command
-- runs through the production script runtime handler with the live
-- following-mon and transition owners; both intentionally bypass script
-- decoding to isolate reconciliation and transition/follow integration.
-- Script decoding is exercised elsewhere. The scenario never shows the actor
-- by hand and never installs a pre-visible partner.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "following-mon", "partner" },
  },
  tests = {},
}

local HOUSE_1F = "MAP_NEW_BARK_PLAYER_HOUSE_1F"
local HOUSE_SPAWN = { fieldX = 4, fieldZ = 5, facing = "south" }

local DIRECTIONS = { "south", "east", "north", "west" }

local function playerTile(snapshot)
  return { fieldX = snapshot.player.fieldX, fieldZ = snapshot.player.fieldZ }
end

local function sameTile(a, b)
  return a.fieldX == b.fieldX and a.fieldZ == b.fieldZ
end

function T.tests.direct_mon_service_gift_reveals_through_the_pending_transition_then_follows_in_step()
  local versionId = AcceptanceHarness.defaultVersion()
  local harness = AcceptanceHarness.new()
  local defaultFactory = harness.gameFactory
  harness.gameFactory = function(versionIdOverride, map)
    local game = defaultFactory(versionIdOverride, map)
    if map == HOUSE_1F then
      game.location.fieldX = HOUSE_SPAWN.fieldX
      game.location.fieldZ = HOUSE_SPAWN.fieldZ
      game.location.facing = HOUSE_SPAWN.facing
    end
    return game
  end
  local game = harness:boot({
    versionId = versionId,
    map = HOUSE_1F,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  OpeningLifecycle.seedPostOpeningHouseState(game)
  game:waitForFieldReady()
  local ok, err = xpcall(function()
    Assert.isNil(game.runtime.actors:partnerId(), "an empty party installs no partner")
    local added = game.runtime.monService:giveMon({ species = "CHIKORITA", level = 5, form = 0 })
    Assert.isTrue(added, "setup gift must enter the party")

    -- The script transition command runs through production dispatch before
    -- follower reconciliation has published the new partner actor later in
    -- the same update flow. Live party state already holds the gifted lead,
    -- so the command must be accepted even though no actor exists yet.
    Assert.isNil(game.runtime.actors:partnerId(), "no partner exists before reconciliation")
    Assert.isTrue(
      game.runtime.followingMon:isSourceActive(),
      "the live party already holds the gifted lead before reconciliation"
    )
    local dispatchRun = {
      instance = { scriptId = "test.starter-follower", locals = {}, textArgs = {} },
      services = {
        followingMon = game.runtime.followingMon,
        followerTransition = game.runtime.followingMonTransition,
      },
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
      Runtime.executeNode({ op = "follower_transition" }, dispatchRun),
      Runtime.OUTCOME_CONTINUE,
      "the pre-publication transition command continues instead of dropping"
    )
    Assert.equal(
      #game.runtime.followingMonTransition:status().instances,
      0,
      "no transition instance binds before publication"
    )

    -- Follower reconciliation publishes the new lead hidden through the
    -- normal runtime order; the reveal must come from the transition.
    game:advanceUntil("follower installation after party gift", function()
      return game.runtime.actors:partnerId() ~= nil
    end, 120)
    Assert.isNil(
      game.runtime.errorText,
      "field runtime faulted while installing the follower: " .. tostring(game.runtime.errorText)
    )
    local id = assert(game.runtime.actors:partnerId(), "the lead gift must install one partner actor")
    Assert.equal(id, "field:partner", "the partner keeps its stable actor identity")
    Assert.isFalse(
      game.runtime.actors:isVisible(id),
      "a newly acquired mid-map follower is published hidden before its reveal"
    )

    game:advanceUntil("pending transition reveals the published follower", function()
      return game.runtime.actors:isVisible(id)
    end, 120)
    Assert.isNil(
      game.runtime.errorText,
      "field runtime faulted while revealing the follower: " .. tostring(game.runtime.errorText)
    )
    Assert.isTrue(game.runtime.monService:partyCount() == 1, "the party still holds exactly the gifted lead")

    -- One ordinary player step: the visible follower starts its existing
    -- synchronized follow action while the player step is still in flight,
    -- then settles onto the vacated tile.
    local stepped = false
    for _, direction in ipairs(DIRECTIONS) do
      game:face(direction)
      local before = playerTile(game:snapshot())
      game:move(direction)
      local mid = game:snapshot()
      if mid.player.motion ~= "idle" then
        Assert.isFalse(
          game.runtime.followingMon:isMovementSettled(),
          "the follower starts while the player step is still in flight"
        )
        local actor = assert(game.runtime.actors:getById(id), "the partner survives the step start")
        Assert.equal(actor.pose, "walk", "the follower walks while the player step is in flight")
        Assert.isTrue(game.runtime.actors:isVisible(id), "the follower stays visible while stepping")
        game:advanceUntil("player step resolves", function(snapshot)
          return snapshot.player.motion == "idle"
        end, 120)
        local after = game:snapshot()
        Assert.isFalse(sameTile(playerTile(after), before), "the probe step must commit to a new tile")
        local partner = assert(game.runtime.actors:getById(id), "the partner survives the committed step")
        Assert.equal(partner:getFieldPosition().fieldX, before.fieldX, "the follower settles onto the vacated tile")
        Assert.equal(partner:getFieldPosition().fieldZ, before.fieldZ, "the follower settles onto the vacated tile")
        Assert.isTrue(game.runtime.followingMon:isMovementSettled(), "the ordinary follow settles after the step")
        Assert.isTrue(game.runtime.actors:isVisible(id), "the follower stays visible after the step")
        stepped = true
        break
      end
      game:advanceUntil("blocked movement resolves", function(snapshot)
        return snapshot.player.motion == "idle"
      end, 120)
      if not sameTile(playerTile(game:snapshot()), before) then
        local partner = assert(game.runtime.actors:getById(id), "the partner survives the committed step")
        Assert.equal(partner:getFieldPosition().fieldX, before.fieldX, "the follower settles onto the vacated tile")
        Assert.equal(partner:getFieldPosition().fieldZ, before.fieldZ, "the follower settles onto the vacated tile")
        Assert.isTrue(game.runtime.actors:isVisible(id), "the follower stays visible after the step")
        stepped = true
        break
      end
    end
    Assert.isTrue(stepped, "the fixture room must supply one committed step")
    Assert.isNil(
      game.runtime.errorText,
      "field runtime faulted while trailing the player: " .. tostring(game.runtime.errorText)
    )
    Assert.equal(game:renderAttempts(), 0, "following-mon acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
