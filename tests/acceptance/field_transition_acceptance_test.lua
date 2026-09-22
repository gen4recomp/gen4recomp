-- Production-composed transition contracts: one ordinary door ingress and one
-- House stairs profile-3 path.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    derivedAssets = { "map:60", "map:61", "map:63", "map:64" },
    tags = { "field", "transition", "door", "profile" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"
local HOUSE_1F = "MAP_NEW_BARK_PLAYER_HOUSE_1F"
local HOUSE_2F = "MAP_NEW_BARK_PLAYER_HOUSE_2F"
local TOWN_DOOR_APPROACH = { fieldX = 684, fieldZ = 394 }
local HOUSE_WARP = { fieldX = 3, fieldZ = 3 }

-- Source facts for the two transitions; identical across ready versions.
local FACTS = {
  house2fArrival = { fieldX = 3, fieldZ = 4 },
  labFloor = { fieldX = 4, fieldZ = 13 },
  labDoorAnchor = { fieldX = 4, fieldZ = 14 },
}

local function withDefaultGame(map, fn, fieldOptions)
  local versionId = AcceptanceHarness.defaultVersion()
  local harness = AcceptanceHarness.new()
  local game = harness:boot({
    versionId = versionId,
    map = map,
    save = "fresh",
    fieldOptions = fieldOptions,
  })
  game:advanceDialogue()
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "transition acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function beginTownDoor(game)
  game:moveTo(TOWN_DOOR_APPROACH)
  game:move("north")
  Assert.equal(game.runtime.transition.phase, "fade_out", "the production door input must start a transition")
end

local function hasEffect(game, sequence)
  for _, effect in ipairs(game:hostEffects()) do
    if effect == "audio:" .. sequence then
      return true
    end
  end
  return false
end

local function stepOntoHouseStairs(game)
  game:moveTo(HOUSE_WARP)
  game:advanceUntil("player reaches the stair landing", function(snapshot)
    return snapshot.player.motion == "idle"
      and snapshot.player.fieldX == HOUSE_WARP.fieldX
      and snapshot.player.fieldZ == HOUSE_WARP.fieldZ
  end, 60)
  game:step({ direction = "west" })
end

function T.tests.door_fade_waits_for_source_ingress_and_preserves_anchor()
  withDefaultGame(TOWN, function(game)
    beginTownDoor(game)
    local transition = game.runtime.transition
    Assert.isTrue(hasEffect(game, "SEQ_SE_DP_DOOR_OPEN"), "door audio follows the selected source animation")
    Assert.notNil(transition.sourceDoor, "the production transition must resolve the source door")
    Assert.isNil(transition.resolution, "destination preparation waits for source door ingress")
    game:advanceUntil("source door ingress completes", function()
      return transition.resolution ~= nil
    end, 120)
    Assert.equal(transition.resolution.fieldX, FACTS.labDoorAnchor.fieldX)
    Assert.equal(transition.resolution.fieldZ, FACTS.labDoorAnchor.fieldZ)
    Assert.equal(transition:presentationStatus().entryAction, "step_down")
    local completed = game:waitForTransition()
    Assert.deepEqual(
      { completed.destination.player.fieldX, completed.destination.player.fieldZ },
      { FACTS.labFloor.fieldX, FACTS.labFloor.fieldZ }
    )
  end, { recordingScriptHosts = true })
end

function T.tests.player_house_stairs_remain_fixed_profile_three_indoors()
  local versionId = AcceptanceHarness.defaultVersion()
  local harness = AcceptanceHarness.new()
  local defaultFactory = harness.gameFactory
  harness.gameFactory = function(vId, map)
    local game = defaultFactory(vId, map)
    if map == HOUSE_1F then
      game.location.fieldX = 4
      game.location.fieldZ = 5
      game.location.facing = "south"
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
    stepOntoHouseStairs(game)
    Assert.isFalse(game.runtime.player.motion == "climbing", "horizontal stairs must not use an in-place climb")
    local staged = game:advanceUntil("destination stair staging", function(snapshot)
      return snapshot.mapSymbol == HOUSE_2F
    end, 120)
    Assert.deepEqual(
      { staged.player.fieldX, staged.player.fieldZ },
      { FACTS.house2fArrival.fieldX, FACTS.house2fArrival.fieldZ },
      "profile three must expose its adjacent arrival tile after the swap"
    )
    game:advanceUntil("destination stair transition completes", function(snapshot)
      return snapshot.mapSymbol == HOUSE_2F
        and snapshot.transition.phase == "idle"
        and snapshot.player.motion == "idle"
        and snapshot.player.fieldX == FACTS.house2fArrival.fieldX
        and snapshot.player.fieldZ == FACTS.house2fArrival.fieldZ
    end, 120)
    Assert.equal(game.runtime.transition.profileId, 3, "indoor stairs retain fixed profile 3")
    Assert.equal(game.runtime.transition.sourceKind, "stairs", "the trigger remains a stair transition")
    Assert.isTrue(hasEffect(game, "SEQ_SE_DP_KAIDAN2"), "the stair exit emits the source sequence")
    Assert.deepEqual(
      { game.runtime.player.fieldX, game.runtime.player.fieldZ },
      { FACTS.house2fArrival.fieldX, FACTS.house2fArrival.fieldZ },
      "profile three must finish on the real destination arrival tile"
    )
    Assert.equal(game:renderAttempts(), 0, "transition acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
