-- Production-composed field item acquisition through the real generated
-- Lake of Rage shore item-ball routine (vanilla.hgss.scr_seq.0938.script_016,
-- the scr_seq member behind MAP_LAKE_OF_RAGE's script bank, source archive
-- member 938): the scenario prefills the same item to its exact stack
-- maximum through the live Bag service and proves the routine takes the
-- source failure branch and mutates nothing. The success-path grant,
-- browse, and persistence chain lives in the bag actions integration
-- journey; this scenario keeps the distinct generated-routine failure
-- boundary. The harness boots the non-rendering field runtime from the
-- ready ROM-derived caches with an isolated save root, spawns beside the
-- map's item-ball object bound to that generated script (object event 12,
-- raw script id 17, at tile 541,47), and presses Action through the
-- production interaction binding so the script runs with its real actor
-- trigger. Only host boundaries (save-root location, recording
-- audio/event adapters, render trap) stand in for production.
--
-- Distinct boundary this file protects: the generated-routine branch
-- selection on the same tick (exact-limit prefill takes the source failure
-- branch with its result codes and no mutation). The success-path grant,
-- browse, mutate, and persistence chain lives in the bag actions
-- integration journeys; this scenario keeps only the failure boundary.
--
-- Seeded precondition, stated plainly: the map's entry routine hides its
-- shore item balls until the mid-game Red-Scale progression, whose entry
-- path also needs phone/progression systems outside this scope. The scenario
-- therefore clears the ball's documented removal flag (652) once after
-- entry, which the production actor manager observes through the normal
-- flag subscription and uses to publish the ball; the test asserts the ball
-- is live before interacting, so any production change to that gating fails
-- loudly here instead of silently testing nothing. Everything downstream of
-- the seeded flag -- trigger, generated graph, Bag service, result codes --
-- is production composition.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local BagSave = require("libs.hgss.src.save.BagSave")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local PlayTime = require("libs.hgss.src.save.PlayTime")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "bag" },
  },
  tests = {},
}

-- Generated Lake of Rage item-ball routine: scr_seq member 938 (the Lake of
-- Rage script bank), script index 16, bound to the map's item-ball object
-- event 12 carrying raw script id 17. It grants native item 23 (one copy)
-- on the room-available branch and reports the source failure branch
-- otherwise.
local SCRIPT_ID = "vanilla.hgss.scr_seq.0938.script_016"
local MAP = "MAP_LAKE_OF_RAGE"
local BALL_ACTOR_ID = "map:88:object:12"
local BALL_REMOVAL_FLAG = 652
local ITEM_KEY = "FULL_RESTORE"
-- Medicine-pocket stack maximum from the source pocket table; the prefill
-- assertion below proves it rather than assuming it.
local STACK_MAXIMUM = 999
local FAILURE_RESULT = 0

local function harness()
  return AcceptanceHarness.new({
    gameFactory = function(versionId)
      return {
        saveId = "save-00000001",
        versionId = versionId,
        -- Factory coordinates are origin-relative: the Lake of Rage scene
        -- origin sits 512,32 ahead of the generated event frame, so local
        -- (30,15) places the player on the map-space tile (542,47),
        -- directly east of the item ball at (541,47).
        location = { mapSymbol = MAP, fieldX = 30, fieldZ = 15, facing = "west" },
        playerData = {
          profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        playTime = PlayTime.new(),
        worldState = FieldEventState.new(),
        mons = require("tests.support.MonBucket").emptyForVersion(versionId),
        bag = BagSave.empty(),
      }
    end,
  })
end

---@param game AcceptanceGame
local function enterField(game)
  game:waitForFieldEntry()
  game:advanceUntil("field ready for ordinary input", function(snapshot)
    return not snapshot.fieldLocked and not snapshot.dialogue.modal
  end, 480)
end

-- Establish the seeded ball precondition through production state: clear
-- the ball's removal flag, let the runtime flush the pending flag change,
-- and require the generated ball object to be live before any interaction.
---@param game AcceptanceGame
local function seedBallVisible(game)
  game.runtime.eventState:clearFlag(BALL_REMOVAL_FLAG)
  game:step()
  game:step()
  Assert.notNil(game.runtime.actors:getById(BALL_ACTOR_ID), "the seeded item ball must be live before interaction")
end

---@param game AcceptanceGame
local function triggerItemBall(game)
  game:face("west")
  game:pressAction()
  local interaction = game:interaction()
  local player = game:snapshot().player
  Assert.equal(
    interaction.scriptId,
    SCRIPT_ID,
    "Action beside the item ball must start the generated grant routine"
      .. " (player "
      .. tostring(player.fieldX)
      .. ","
      .. tostring(player.fieldZ)
      .. " facing "
      .. tostring(player.facing)
      .. "; interaction kind="
      .. tostring(interaction.kind)
      .. " actor="
      .. tostring(interaction.actorId)
      .. " script="
      .. tostring(interaction.scriptId)
      .. ")"
  )
end

---@param game AcceptanceGame
---@param scriptId string
---@return { ended: boolean, fault: string|nil, completed: boolean, reason: string|nil }
local function driveToEnd(game, scriptId)
  for _ = 1, 6000 do
    if game.runtime.errorText ~= nil then
      return { ended = false, fault = tostring(game.runtime.errorText), completed = false, reason = nil }
    end
    for _, record in ipairs(game:recordsNamed("script.ended")) do
      if record.payload.scriptId == scriptId then
        local completed = record.payload.completed == true
        return { ended = true, fault = nil, completed = completed, reason = record.payload.reason }
      end
    end
    local snapshot = game:snapshot()
    if snapshot.dialogue.modal or snapshot.fieldLocked then
      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
    else
      game:step()
    end
  end
  return {
    ended = false,
    fault = "the grant routine did not end within the tick bound",
    completed = false,
    reason = nil,
  }
end

---@param game AcceptanceGame
---@param scriptId string
local function assertNoUnsupportedHalt(game, scriptId)
  for _, record in ipairs(game:recordsNamed("script.ended")) do
    if record.payload.scriptId == scriptId then
      Assert.isFalse(
        record.payload.reason == "SCRIPT_UNSUPPORTED_REACHABLE",
        "the grant routine must never halt as unsupported"
      )
    end
  end
end

function T.tests.field_item_ball_at_the_exact_limit_takes_the_failure_branch()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harness():boot({
    versionId = versionId,
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    enterField(game)
    local bag = assert(game.runtime.bagService, "field runtime owns the live bag service")
    Assert.isTrue(
      bag:add(ITEM_KEY, STACK_MAXIMUM),
      "prefilling the exact stack maximum must succeed through the live service"
    )
    local revision = bag:revision()
    seedBallVisible(game)
    triggerItemBall(game)
    local outcome = driveToEnd(game, SCRIPT_ID)
    Assert.isNil(outcome.fault, "the failure routine must run without a runtime fault")
    Assert.isTrue(outcome.ended, "the failure routine must end")
    Assert.isTrue(outcome.completed, "the failure routine must reach its source End: " .. tostring(outcome.reason))
    assertNoUnsupportedHalt(game, SCRIPT_ID)
    Assert.equal(
      game.runtime.scripts.worldState:getVar("VAR_SPECIAL_RESULT"),
      FAILURE_RESULT,
      "the routine must leave the source failure result"
    )
    Assert.equal(bag:quantity(ITEM_KEY), STACK_MAXIMUM, "the failure branch must mutate nothing")
    Assert.equal(bag:revision(), revision, "the failure branch must not bump the service revision")
    Assert.equal(game:renderAttempts(), 0, "the failure branch must stop before GPU rendering")
  end, debug.traceback)
  local namespace = game.saveNamespace
  game:close()
  if not ok then
    error(err, 0)
  end
  Assert.isNil(love.filesystem.getInfo(namespace), "teardown removes the isolated save namespace")
end

return T
