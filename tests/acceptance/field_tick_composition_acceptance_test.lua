-- Production-composed fixed-tick field contracts. The harness supplies the
-- real generated maps, scripts, actors, and scheduler, and stops before draw.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local S = require("gen4.script")
local Registry = require("libs.script.src.Registry")
local Composition = require("libs.script.src.Composition")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "fixed-tick", "composition" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"
local LAB_1F = "MAP_NEW_BARK_ELMS_LAB_1F"
local ELM_ACTOR_ID = "map:61:object:0"
local FLAG_ELMS_LAB_PREVENT_PLAYER_ESCAPE = FieldScriptSymbols.flagsByName.FLAG_ELMS_LAB_PREVENT_PLAYER_ESCAPE

local function labHarness()
  return AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      local mons = nil
      local monBucketOk, monBucket = pcall(function()
        return require("tests.support.MonBucket").emptyForVersion(versionId)
      end)
      if monBucketOk then
        mons = monBucket
      end
      return {
        saveId = "save-00000001",
        versionId = versionId,
        location = { mapSymbol = map or LAB_1F, fieldX = 4, fieldZ = 13, facing = "north" },
        playerData = {
          profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        playTime = PlayTime.new(),
        worldState = FieldEventState.new(),
        mons = mons,
        bag = require("libs.hgss.src.save.BagSave").empty(),
      }
    end,
  })
end

local function withGame(harness, map, fn)
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = map,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "fixed-tick acceptance must stop before GPU rendering")
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

local function stepExactlyOnce(game, direction)
  local before = game:snapshot()
  local advanceDialogue = before.dialogue.modal
  if advanceDialogue then
    game.runtime:pressAction()
  end
  if direction ~= nil then
    game.runtime:press(direction)
  end
  local ok, after = pcall(function()
    return game:step()
  end)
  if direction ~= nil then
    game.runtime:release(direction)
  end
  if advanceDialogue then
    game.runtime:releaseAction()
  end
  if not ok then
    error(after, 0)
  end
  Assert.equal(after.tick, before.tick + 1, "one production harness step must execute one field tick")
  return before, after
end

local function assertActorMidpoint(actor, before, current, camera, label)
  local previous = actor:renderPosition(0)
  local midpoint = actor:renderPosition(0.5)
  Assert.near(previous.x, before.x, 1e-9, label .. " previous X endpoint")
  Assert.near(previous.y, before.y, 1e-9, label .. " previous Y endpoint")
  Assert.near(previous.z, before.z, 1e-9, label .. " previous Z endpoint")
  Assert.near(midpoint.x, (before.x + current.x) / 2, 1e-9, label .. " X midpoint")
  Assert.near(midpoint.y, (before.y + current.y) / 2, 1e-9, label .. " Y midpoint")
  Assert.near(midpoint.z, (before.z + current.z) / 2, 1e-9, label .. " Z midpoint")

  local cameraMidpoint = {
    x = (camera.previousTarget.x + camera.target.x) / 2,
    y = (camera.previousTarget.y + camera.target.y) / 2,
    z = (camera.previousTarget.z + camera.target.z) / 2,
  }
  Assert.near(
    midpoint.x - cameraMidpoint.x,
    ((before.x - camera.previousTarget.x) + (current.x - camera.target.x)) / 2,
    1e-9,
    label .. " camera-relative X midpoint"
  )
  Assert.near(
    midpoint.y - cameraMidpoint.y,
    ((before.y - camera.previousTarget.y) + (current.y - camera.target.y)) / 2,
    1e-9,
    label .. " camera-relative Y midpoint"
  )
  Assert.near(
    midpoint.z - cameraMidpoint.z,
    ((before.z - camera.previousTarget.z) + (current.z - camera.target.z)) / 2,
    1e-9,
    label .. " camera-relative Z midpoint"
  )
end

function T.tests.foreground_field_script_preserves_phase_ownership_and_tick_cadence()
  withGame(labHarness(), LAB_1F, function(game)
    game:waitForFieldEntry()
    local baselineStarts = #recordsNamed(game, "script.started")
    game:moveTo({ fieldX = 4, fieldZ = 10 })

    game:advanceUntil("the production lab welcome scene starts", function()
      return #recordsNamed(game, "script.started") > baselineStarts
    end, 60)
    local starts = recordsNamed(game, "script.started")
    Assert.equal(#starts, baselineStarts + 1, "the field-entry interaction must start one foreground script")
    -- The selected start pins the lab script's north walk: scripted movement
    -- keeps X at 4 while stepping Z from 10 to 7 under the field lock, so an
    -- injected ordinary east step would stand out as X drift.
    local startPlayer = game:snapshot().player
    Assert.equal(startPlayer.fieldX, 4, "the scene setup must select the north-walk start column")
    Assert.equal(startPlayer.fieldZ, 10, "the scene setup must select the north-walk start row")
    local sawScriptedPlayerMovement = false
    local sawActorMovement = false
    local sawInterpolatedActorMovement = false
    local completed = false

    for _ = 1, 600 do
      local before, after
      if game:snapshot().fieldLocked then
        before, after = stepExactlyOnce(game, "east")
      else
        before, after = stepExactlyOnce(game)
      end
      if after.fieldLocked then
        local elm = assert(after.actors[ELM_ACTOR_ID], "the foreground field script must retain its actor world")
        if before.actors[ELM_ACTOR_ID] then
          sawActorMovement = sawActorMovement
            or elm.fieldX ~= before.actors[ELM_ACTOR_ID].fieldX
            or elm.fieldZ ~= before.actors[ELM_ACTOR_ID].fieldZ
            or elm.facing ~= before.actors[ELM_ACTOR_ID].facing
        end
        Assert.equal(
          after.player.fieldX,
          startPlayer.fieldX,
          "ordinary east input must not move the player while the script owns input"
        )
        if after.player.fieldZ ~= startPlayer.fieldZ then
          sawScriptedPlayerMovement = true
        end
      end
      if not after.fieldLocked and after.foregroundScript == nil then
        completed = true
        break
      end
    end

    local scripts = assert(game.runtime.scripts, "the production field script runtime must remain available")
    local registry = Registry.new()
    local actorWalk = S.script({
      api = 1,
      id = "acceptance.scripted_actor_walk",
      steps = {
        S.applyMovement({
          actor = "player",
          movement = { S.m.walk({ direction = "north", speed = "normal", tiles = 1 }) },
        }),
        S.applyMovement({
          actor = ELM_ACTOR_ID,
          movement = { S.m.walk({ direction = "east", speed = "normal", tiles = 1 }) },
        }),
        S.waitMovement(),
        S.stop(),
      },
    })
    registry:installBase(actorWalk.id, actorWalk, "generated")
    local composedWalk = assert(Composition.new(registry):effective(actorWalk.id))
    assert(
      scripts.scheduler:createForeground(composedWalk, nil, assert(game.runtime.session).tick),
      "the production scheduler must accept concurrent scripted player and actor walks"
    )
    local sawMovingCameraScriptedActor = false
    for _ = 1, 40 do
      local actorBefore = assert(game.runtime.actors:getById(ELM_ACTOR_ID))
      local beforeWorldPosition = actorBefore:getWorldPosition()
      local beforeWorld = {
        x = beforeWorldPosition.x,
        y = beforeWorldPosition.y,
        z = beforeWorldPosition.z,
      }
      local beforeFieldPosition = actorBefore:getFieldPosition()
      local beforeFieldX, beforeFieldZ = beforeFieldPosition.fieldX, beforeFieldPosition.fieldZ
      local before = actorBefore:renderPosition(1)
      local beforeSnapshot, after = stepExactlyOnce(game)
      local actor = assert(game.runtime.actors:getById(ELM_ACTOR_ID))
      local currentWorld = actor:getWorldPosition()
      local currentField = actor:getFieldPosition()
      if
        beforeFieldX ~= currentField.fieldX
        or beforeFieldZ ~= currentField.fieldZ
        or beforeWorld.x ~= currentWorld.x
        or beforeWorld.y ~= currentWorld.y
        or beforeWorld.z ~= currentWorld.z
      then
        local current = actor:renderPosition(1)
        local camera = assert(after.camera, "the production field camera must remain available")
        local playerMoved = beforeSnapshot.player.worldX ~= after.player.worldX
          or beforeSnapshot.player.worldY ~= after.player.worldY
          or beforeSnapshot.player.worldZ ~= after.player.worldZ
        local cameraMoved = camera.previousTarget.x ~= camera.target.x
          or camera.previousTarget.y ~= camera.target.y
          or camera.previousTarget.z ~= camera.target.z
        if playerMoved then
          Assert.isTrue(cameraMoved, "the scripted player step must move the production camera target")
          assertActorMidpoint(actor, before, current, camera, "same-tick scripted actor and moving camera")
          sawMovingCameraScriptedActor = true
        end
        assertActorMidpoint(actor, before, current, camera, "scripted world translation")
        sawInterpolatedActorMovement = true
        if sawMovingCameraScriptedActor then
          break
        end
      end
      if scripts.scheduler:foregroundEnvironmentId() == nil then
        break
      end
    end

    Assert.isTrue(sawScriptedPlayerMovement, "the script-owned player walk must advance while the field is locked")
    Assert.isTrue(sawActorMovement, "the production script phase must still advance actor presentation")
    Assert.isTrue(
      sawMovingCameraScriptedActor,
      "a scripted NPC step and the scripted player-following camera must move on the same field tick"
    )
    local finalActor = assert(game.runtime.actors:getById(ELM_ACTOR_ID))
    local finalActorPosition = finalActor:getFieldPosition()
    local actorWalkEvents = {}
    for _, name in ipairs({ "script.started", "script.ended", "script.error" }) do
      for _, record in ipairs(recordsNamed(game, name)) do
        if record.payload.scriptId == actorWalk.id then
          actorWalkEvents[#actorWalkEvents + 1] = name
            .. ":"
            .. tostring(record.payload.completed)
            .. ":"
            .. tostring(record.payload.reason or record.payload.message)
        end
      end
    end
    Assert.isTrue(
      sawInterpolatedActorMovement,
      "a scripted NPC step must retain a fractional render midpoint; position="
        .. finalActorPosition.fieldX
        .. ","
        .. finalActorPosition.fieldZ
        .. " events="
        .. table.concat(actorWalkEvents, ",")
        .. " action="
        .. tostring(finalActor:currentAction())
        .. " foreground="
        .. tostring(scripts.scheduler:foregroundEnvironmentId())
    )
    Assert.isTrue(completed, "the foreground field script must reach its source completion boundary")
    Assert.isTrue(
      game.runtime.scripts.worldState:isFlagSet(FLAG_ELMS_LAB_PREVENT_PLAYER_ESCAPE),
      "the started script must set its durable completion flag before releasing the field"
    )
    local finalPlayer = game:snapshot().player
    Assert.equal(finalPlayer.fieldX, 4, "the scripted walk must keep the start column")
    Assert.equal(finalPlayer.fieldZ, 7, "the scripted walk must reach the end of the north path")
    Assert.isFalse(game:snapshot().fieldLocked, "script completion must release field ownership")
    Assert.equal(
      #recordsNamed(game, "script.started"),
      baselineStarts + 2,
      "the field-entry scene and scripted actor walk must each start one foreground script"
    )
  end)
end

function T.tests.ordinary_field_movement_keeps_one_tile_and_settled_transition_behavior()
  withGame(AcceptanceHarness.new(), TOWN, function(game)
    OpeningLifecycle.settleNewBarkFriendScene(game)
    game:waitForFieldReady()
    game:moveTo({ fieldX = 682, fieldZ = 394 })
    game:face("east")
    local before = game:snapshot()
    local tickBefore = before.tick
    game:step({ direction = "east" })
    local after = game:advanceUntil("ordinary production movement settles", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 60)

    Assert.equal(after.player.fieldX, before.player.fieldX + 1, "ordinary movement must commit one tile")
    Assert.equal(after.player.fieldZ, before.player.fieldZ, "ordinary movement must preserve the other axis")
    Assert.equal(after.transition.phase, "idle", "ordinary movement must not create a transition")
    Assert.isFalse(after.fieldLocked, "ordinary movement must leave the field available")
    Assert.isTrue(after.tick > tickBefore, "settling movement must advance semantic ticks")

    game:moveTo({ fieldX = 684, fieldZ = 394 })
    game:step({ direction = "north" })
    local transition = game:waitForTransition()
    Assert.equal(transition.destination.mapSymbol, LAB_1F, "the existing door route must compose")
    Assert.equal(transition.destination.transition.phase, "idle")
  end)
end

return T
