-- Production-composed contracts for the Player House 1F Mom opening scene
-- and its New Bark friend/Marill follow-up. Real ROM-derived maps, scripts,
-- and the scheduler stay in the path; only host boundaries (audio, script
-- effect/event recording) are faked.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local SurfaceResolver = require("libs.hgss.src.world.SurfaceResolver")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "lifecycle", "opening" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"
local HOUSE_1F = "MAP_NEW_BARK_PLAYER_HOUSE_1F"
local TOWN_HOUSE_DOOR_APPROACH = { fieldX = 695, fieldZ = 397 }
local VAR_SCENE_PLAYERS_HOUSE_1F = OpeningLifecycle.VAR_SCENE_PLAYERS_HOUSE_1F
local FLAG_HIDE_NEW_BARK_FRIEND = FieldScriptSymbols.flagsByName.FLAG_HIDE_NEW_BARK_FRIEND
local FLAG_HIDE_NEW_BARK_MARILL = FieldScriptSymbols.flagsByName.FLAG_HIDE_NEW_BARK_MARILL

local function withGame(map, fn, fieldOptions)
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = map,
    save = "fresh",
    fieldOptions = fieldOptions,
  })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "opening-lifecycle acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function recordsNamed(game, name)
  local records = {}
  for _, record in ipairs(game:hostEvents().records) do
    if record.name == name then
      records[#records + 1] = record
    end
  end
  return records
end

-- Enter Player House 1F through the real production town door, exactly as
-- an ordinary player would.
local function enterHouse(game)
  game:moveTo(TOWN_HOUSE_DOOR_APPROACH)
  game:step({ direction = "north" })
  local transition = game:waitForTransition()
  Assert.equal(transition.destination.mapSymbol, HOUSE_1F)
end

function T.tests.house_mom_scene_advances_the_opening_state()
  withGame(TOWN, function(game)
    local world = game.runtime.scripts.worldState
    Assert.equal(world:getVar(VAR_SCENE_PLAYERS_HOUSE_1F), 0, "a genuinely fresh world starts at scene value 0")

    -- Let TOWN's own unconditional on_transition/on_resume lifecycle settle
    -- first; only script activity from here on belongs to the House 1F
    -- opening scene under test.
    game:waitForFieldEntry()
    local baselineStarts = #recordsNamed(game, "script.started")

    enterHouse(game)
    local expectedSceneScriptId = assert(
      OpeningLifecycle.frameRuleScriptId(game.runtime, VAR_SCENE_PLAYERS_HOUSE_1F, 0),
      "generated House 1F rules must have a script for scene value 0"
    )

    -- The generated on-frame lifecycle rule must start the source scene
    -- script before normal player movement can proceed; exactly one
    -- foreground script owns the field during the sequence.
    game:advanceUntil("the opening scene starts", function()
      return #recordsNamed(game, "script.started") > baselineStarts
    end, 30)
    local starts = recordsNamed(game, "script.started")
    Assert.equal(#starts - baselineStarts, 1, "the opening scene must start exactly one foreground script")
    Assert.equal(
      starts[baselineStarts + 1].payload.scriptId,
      expectedSceneScriptId,
      "the generated scene-0 script must own the field"
    )
    Assert.isTrue(
      game.runtime.scripts.scheduler:foregroundEnvironmentId() ~= nil,
      "the scene script must own the field"
    )

    OpeningLifecycle.completeOpeningHouseScene(game)

    for _, flag in ipairs(OpeningLifecycle.MOM_GRANTED_FLAGS) do
      Assert.isTrue(world:isFlagSet(flag), "the Mom scene must grant every early progression flag")
    end
    Assert.equal(world:getVar(VAR_SCENE_PLAYERS_HOUSE_1F), 1, "the Mom scene must advance the scene variable")
    Assert.isNil(game.runtime.scripts.scheduler:foregroundEnvironmentId(), "ReleaseAll must return field ownership")

    -- The root scene script also runs CallStd children (play/fade the Mom
    -- music); filter to the scene script's own end record, not its children.
    local sceneEnds = {}
    for _, record in ipairs(recordsNamed(game, "script.ended")) do
      if record.payload.scriptId == expectedSceneScriptId then
        sceneEnds[#sceneEnds + 1] = record
      end
    end
    Assert.equal(#sceneEnds, 1, "the scene script must end exactly once")
    Assert.isTrue(sceneEnds[1].payload.completed, "the scene script must end by normal completion, not a fault")

    -- The predicate is no longer true (scene value is now 1, not 0), so the
    -- same frame rule must not restart on subsequent idle ticks.
    for _ = 1, 30 do
      game:step()
    end
    local sceneStartsAfterCompletion = 0
    for _, record in ipairs(recordsNamed(game, "script.started")) do
      if record.payload.scriptId == expectedSceneScriptId then
        sceneStartsAfterCompletion = sceneStartsAfterCompletion + 1
      end
    end
    Assert.equal(sceneStartsAfterCompletion, 1, "the completed opening scene must not restart")
  end, { recordingScriptHosts = true })
end

function T.tests.new_bark_friend_and_marill_scene_follows_the_house_scene()
  withGame(TOWN, function(game)
    -- Documented post-opening precondition: the House 1F Mom scene reaching
    -- this state through real script execution is covered separately above.
    -- This scenario is about New Bark's own on_transition/on_frame_eq
    -- handoff, so it seeds the same source scene value the Mom scene
    -- produces, before the very first tick (map lifecycle is still fully
    -- evaluated).
    OpeningLifecycle.seedPostOpeningHouseState(game)

    local expectedTransitionScriptId = assert(
      OpeningLifecycle.lifecycleScriptId(game.runtime, "on_transition"),
      "New Bark must declare an on_transition lifecycle script"
    )
    local expectedSceneScriptId = assert(
      OpeningLifecycle.frameRuleScriptId(game.runtime, VAR_SCENE_PLAYERS_HOUSE_1F, 1),
      "generated New Bark rules must have a script for scene value 1"
    )

    -- New Bark's on_transition lifecycle is allowed to run before ordinary
    -- frame-rule ownership.
    game:advanceUntil("New Bark's on_transition lifecycle starts", function()
      return #recordsNamed(game, "script.started") > 0
    end, 30)
    local starts = recordsNamed(game, "script.started")
    Assert.equal(
      starts[1].payload.scriptId,
      expectedTransitionScriptId,
      "on_transition must start before the frame rule"
    )

    -- Only once that lifecycle ownership settles does the frame rule for
    -- house scene value 1 start the friend/Marill scene, exactly once.
    game:advanceUntil("the friend/Marill scene starts", function(_)
      for _, record in ipairs(recordsNamed(game, "script.started")) do
        if record.payload.scriptId == expectedSceneScriptId then
          return true
        end
      end
      return false
    end, 120)
    local sceneStarts = {}
    for _, record in ipairs(recordsNamed(game, "script.started")) do
      if record.payload.scriptId == expectedSceneScriptId then
        sceneStarts[#sceneStarts + 1] = record
      end
    end
    Assert.equal(#sceneStarts, 1, "the friend/Marill scene must start exactly once")

    local transitionEnds = {}
    for _, record in ipairs(recordsNamed(game, "script.ended")) do
      if record.payload.scriptId == expectedTransitionScriptId then
        transitionEnds[#transitionEnds + 1] = record
      end
    end
    Assert.equal(#transitionEnds, 1, "the on_transition lifecycle must end before the frame rule owns the field")

    -- Advance until its source state mutation/hide-show sequence settles:
    -- the source scene sets the house scene variable to 2 and hides both
    -- the friend and Marill.
    local world = game.runtime.scripts.worldState
    game:advanceUntil("the friend/Marill scene settles", function(snapshot)
      return world:getVar(VAR_SCENE_PLAYERS_HOUSE_1F) == 2
        and world:isFlagSet(FLAG_HIDE_NEW_BARK_FRIEND)
        and world:isFlagSet(FLAG_HIDE_NEW_BARK_MARILL)
        and not snapshot.fieldLocked
        and game.runtime.scripts.scheduler:foregroundEnvironmentId() == nil
    end, 900)

    local runtimeMap = game.runtime.runtimeMap
    local hiddenFlags = {
      [FLAG_HIDE_NEW_BARK_FRIEND] = true,
      [FLAG_HIDE_NEW_BARK_MARILL] = true,
    }
    local hiddenEventsChecked = 0
    for _, event in ipairs(runtimeMap.fieldData.events.objects) do
      if hiddenFlags[event.eventFlag] then
        hiddenEventsChecked = hiddenEventsChecked + 1
        local actorId = "map:" .. runtimeMap.mapId .. ":object:" .. event.objectEventId
        Assert.isNil(game.runtime.actors:getById(actorId), "a hidden New Bark actor must not remain live: " .. actorId)
        local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, event.x, event.z)
        local surface = SurfaceResolver.new(runtimeMap.terrain):resolve({
          localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
          localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
          currentY = event.y / (16 * 4096),
        })
        Assert.isNil(
          game.runtime.actors:getAt(runtimeMap.mapId, {
            fieldX = event.x,
            fieldZ = event.z,
            surfaceId = surface.surfaceId,
          }),
          "a hidden New Bark actor's source cell must have no occupant: " .. actorId
        )
      end
    end
    Assert.equal(hiddenEventsChecked, 2, "New Bark must declare both hidden friend and Marill object events")
    for actorId in pairs(hiddenFlags) do
      for _, record in ipairs(game.runtime.actors:drawRecords()) do
        Assert.isFalse(record.actorId == actorId, "a hidden actor must not remain in the production draw records")
      end
    end
    Assert.isNil(game.runtime.scripts.scheduler:foregroundEnvironmentId(), "ReleaseAll must return field ownership")

    -- The scene variable no longer satisfies the same one-shot trigger
    -- (value 1), so it must not restart.
    for _ = 1, 30 do
      game:step()
    end
    local sceneStartsAfter = 0
    for _, record in ipairs(recordsNamed(game, "script.started")) do
      if record.payload.scriptId == expectedSceneScriptId then
        sceneStartsAfter = sceneStartsAfter + 1
      end
    end
    Assert.equal(sceneStartsAfter, 1, "the settled friend/Marill scene must not restart")
  end, { recordingScriptHosts = true })
end

function T.tests.friend_marill_animates_while_staying_on_its_tile()
  withGame(TOWN, function(game)
    -- No post-opening seeding here: with the house scene variable still at
    -- its fresh value the friend/Marill hide scene never triggers, so the
    -- Marill event stays visible for the whole scenario.
    game:waitForFieldEntry()
    game:advanceUntil("field settles without the hide scene", function(snapshot)
      return not snapshot.fieldLocked and game.runtime.scripts.scheduler:foregroundEnvironmentId() == nil
    end, 120)
    local world = game.runtime.scripts.worldState
    Assert.equal(world:getVar(VAR_SCENE_PLAYERS_HOUSE_1F), 0, "the hide scene must not have run")
    Assert.isFalse(world:isFlagSet(FLAG_HIDE_NEW_BARK_MARILL), "marill must still be visible")

    local runtimeMap = game.runtime.runtimeMap
    local marillEvent
    for _, event in ipairs(runtimeMap.fieldData.events.objects) do
      if event.eventFlag == FLAG_HIDE_NEW_BARK_MARILL then
        marillEvent = event
      end
    end
    Assert.notNil(marillEvent, "New Bark must declare the marill object event")
    local actorId = "map:" .. runtimeMap.mapId .. ":object:" .. marillEvent.objectEventId
    local actor = assert(game.runtime.actors:getById(actorId), "the marill actor must be live while visible")
    Assert.equal(actor.movementType, "stationary", "the friend marill never roams")
    Assert.equal(actor.pose, "idle", "the stationary marill presents idle, never locomotion")
    Assert.isNil(actor:scriptedMotionState(), "no scripted or autonomous movement owns the stationary marill")
    local home = actor:getFieldPosition()
    local homeX, homeZ = home.fieldX, home.fieldZ
    local homeWorld = actor:getWorldPosition()
    local firstTick = actor:getPoseTick()

    -- Enough fixed ticks to cross at least two source idle segments without
    -- issuing any movement to the marill.
    for _ = 1, 25 do
      game:step()
    end

    actor = assert(game.runtime.actors:getById(actorId), "the marill actor must survive idle sampling")
    Assert.equal(actor:getFieldPosition().fieldX, homeX, "idle animation never claims a new logical tile")
    Assert.equal(actor:getFieldPosition().fieldZ, homeZ, "idle animation never claims a new logical tile")
    Assert.near(actor:getWorldPosition().x, homeWorld.x, 1e-9, "idle animation never moves the world anchor")
    Assert.near(actor:getWorldPosition().y, homeWorld.y, 1e-9, "idle animation never moves the world anchor")
    Assert.near(actor:getWorldPosition().z, homeWorld.z, 1e-9, "idle animation never moves the world anchor")
    Assert.equal(actor.movementType, "stationary", "sampling issues no movement to the marill")
    Assert.isNil(actor:scriptedMotionState(), "sampling starts no movement task on the marill")
    Assert.equal(actor.pose, "idle", "the marill stays on its semantic idle pose throughout")
    Assert.isTrue(
      actor:getPoseTick() > firstTick,
      "the stationary marill advances its idle clock instead of holding frame zero"
    )
  end, { recordingScriptHosts = true })
end

return T
