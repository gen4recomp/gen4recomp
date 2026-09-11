-- Production-composed Elm's Lab item handoff: the real scene-1 coordinate
-- script calls the generated common obtain-item routine, whose caller signal
-- must hand back to the parent through the source-defined final button wait
-- alone. One trigger starts one foreground root and one common child, plays
-- one item fanfare, grants five Potions once, prints each obtain message
-- once, arms exactly one explicit button wait, and resumes the parent tail
-- (close, scene update, remaining dialogue, release) with no replay and no
-- modal/input ownership left behind.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local BagSave = require("libs.hgss.src.save.BagSave")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local PlayTime = require("libs.hgss.src.save.PlayTime")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "script", "elm" },
  },
  tests = {},
}

local MAP = "MAP_NEW_BARK_ELMS_LAB_1F"
local AIDE_SCRIPT_ID = "vanilla.hgss.scr_seq.0843.script_003"
local COMMON_SCRIPT_ID = "common.obtain_item_verbose"
local VAR_SCENE_ELMS_LAB = FieldScriptSymbols.variablesByName.VAR_SCENE_ELMS_LAB
local POTION_QUANTITY = 5
local OBTAIN_BANK_ID = 40
local FIRST_MESSAGE_ID = 25
local FINAL_MESSAGE_ID = 31
local ITEM_FANFARE = "SEQ_ME_ITEM"

local function harness()
  return AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      return {
        saveId = "save-00000001",
        versionId = versionId,
        -- Scene value 1 is the source precondition after the lab opening;
        -- (4,12) starts one tile south of the scene-1 trigger at (4,11).
        location = { mapSymbol = map or MAP, fieldX = 4, fieldZ = 12, facing = "north" },
        playerData = {
          profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        playTime = PlayTime.new(),
        worldState = FieldEventState.new({ vars = { [VAR_SCENE_ELMS_LAB] = 1 } }),
        mons = require("tests.support.MonBucket").emptyForVersion(versionId),
        bag = BagSave.empty(),
      }
    end,
  })
end

local function withGame(fn)
  local game = harness():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "Elm aide acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function scriptStarts(game, scriptId)
  return game:recordsForScript(scriptId, "script.started")
end

local function taskRecords(game, name, taskType, instanceId)
  local kept = {}
  for _, record in ipairs(game:recordsNamed(name)) do
    local payload = record.payload or {}
    if payload.taskType == taskType and (instanceId == nil or payload.instanceId == instanceId) then
      kept[#kept + 1] = record
    end
  end
  return kept
end

local function scriptEnded(game, scriptId, instanceId)
  for _, record in ipairs(game:recordsForScript(scriptId, "script.ended")) do
    if record.payload.instanceId == instanceId then
      return record.payload
    end
  end
  return nil
end

local function fanfareEffects(game)
  local kept = {}
  for _, effect in ipairs(game:hostEffects()) do
    if effect == "fanfare:" .. ITEM_FANFARE then
      kept[#kept + 1] = effect
    end
  end
  return kept
end

local function scriptFaults(game)
  local faults = {}
  for _, record in ipairs(game:recordsNamed("script.error")) do
    faults[#faults + 1] = record
  end
  return faults
end

function T.tests.elm_aide_obtain_item_hands_back_exactly_once()
  withGame(function(game)
    local world = assert(game.runtime.scripts.worldState, "the production script world state is required")
    local bag = assert(game.runtime.bagService, "the production field runtime must own the live bag service")
    Assert.equal(
      world:getVar(VAR_SCENE_ELMS_LAB),
      1,
      "the lab scene must start after the opening and before the aide gift"
    )
    Assert.equal(bag:quantity("POTION"), 0, "the fresh bag must not already contain the aide's Potion")

    game:moveTo({ fieldX = 4, fieldZ = 11 })
    game:advanceUntil("the aide script starts", function(_)
      return #scriptStarts(game, AIDE_SCRIPT_ID) == 1
    end, 60)
    local rootStarts = scriptStarts(game, AIDE_SCRIPT_ID)
    Assert.equal(#rootStarts, 1, "one aide trigger must start exactly one foreground root")
    local rootInstanceId = assert(rootStarts[1].payload.instanceId, "the root start must carry instance identity")

    -- Per-message open counts, keyed by generated bank/message identity (never
    -- copied text). A reopened identity counts again, so a replayed pocket
    -- message cannot hide behind first-seen bookkeeping.
    local opens = {}
    local previousKey = nil
    local function noteDialogue(snapshot)
      local dialogue = snapshot.dialogue
      if dialogue.modal and dialogue.bankId ~= nil and dialogue.messageId ~= nil then
        local key = dialogue.bankId .. ":" .. dialogue.messageId
        if key ~= previousKey then
          opens[key] = (opens[key] or 0) + 1
        end
        previousKey = key
      else
        previousKey = nil
      end
    end

    local maxPotion = 0
    local finalPresses = 0
    local otherPresses = 0
    local completed = false
    local lastSnapshot = nil
    local childInstanceId = nil
    for _ = 1, 1500 do
      local snapshot = game:snapshot()
      lastSnapshot = snapshot
      noteDialogue(snapshot)
      maxPotion = math.max(maxPotion, bag:quantity("POTION"))
      local commonStarts = scriptStarts(game, COMMON_SCRIPT_ID)
      if childInstanceId == nil and #commonStarts >= 1 then
        childInstanceId = commonStarts[1].payload.instanceId
      end
      -- The single dismissal edge may only satisfy an armed wait: the
      -- fully printed final message predates the child's explicit button
      -- wait by the generic task handoff, and an earlier edge would be lost
      -- to its tick snapshot instead of dismissing anything.
      local waitArmed = childInstanceId ~= nil
        and #taskRecords(game, "script.task_started", "wait_input", childInstanceId) >= 1
        and #taskRecords(game, "script.task_ended", "wait_input", childInstanceId) == 0
      local rootEnd = scriptEnded(game, AIDE_SCRIPT_ID, rootInstanceId)
      if
        world:getVar(VAR_SCENE_ELMS_LAB) == 2
        and rootEnd ~= nil
        and rootEnd.completed == true
        and not snapshot.fieldLocked
        and not snapshot.dialogue.modal
      then
        completed = true
        break
      end
      Assert.isTrue(snapshot.fieldLocked, "the foreground aide script must retain field ownership until it completes")
      local dialogue = snapshot.dialogue
      if dialogue.modal then
        local bankId, messageId = dialogue.bankId, dialogue.messageId
        if bankId == OBTAIN_BANK_ID and (messageId == FIRST_MESSAGE_ID or messageId == FINAL_MESSAGE_ID) then
          -- The obtain messages own no input: the first stays open through
          -- the fanfare wait, and the final dismisses through its explicit
          -- button wait. Exactly one edge is ever sent, for the fully
          -- printed final message once its wait is armed.
          if
            messageId == FINAL_MESSAGE_ID
            and dialogue.state == "WAITING_CLOSE"
            and finalPresses == 0
            and waitArmed
          then
            game.runtime:pressAction()
            game:step()
            game.runtime:releaseAction()
            finalPresses = finalPresses + 1
          else
            game:step()
          end
        else
          game.runtime:pressAction()
          game:step()
          game.runtime:releaseAction()
          otherPresses = otherPresses + 1
        end
      else
        game:step()
      end
    end
    if not completed then
      local faults = scriptFaults(game)
      local faultText = "none"
      if #faults > 0 then
        faultText = tostring(faults[1].payload.code) .. ": " .. tostring(faults[1].payload.message)
      end
      error(
        "one dismissal of the final obtain message must resume the parent aide tail (scene 2, clean teardown); "
          .. "last tick dialogue modal="
          .. tostring(lastSnapshot and lastSnapshot.dialogue.modal)
          .. " bank/message="
          .. tostring(lastSnapshot and lastSnapshot.dialogue.bankId)
          .. "/"
          .. tostring(lastSnapshot and lastSnapshot.dialogue.messageId)
          .. " scene="
          .. tostring(world:getVar(VAR_SCENE_ELMS_LAB))
          .. " potion="
          .. tostring(bag:quantity("POTION"))
          .. " script faults="
          .. faultText,
        0
      )
    end
    Assert.equal(finalPresses, 1, "the final obtain message must dismiss through exactly one action edge")

    -- Quiet ticks with no input: nothing may replay once the parent is done.
    for _ = 1, 30 do
      game:step()
      noteDialogue(game:snapshot())
    end

    Assert.equal(#scriptStarts(game, AIDE_SCRIPT_ID), 1, "no second aide root may start")
    local commonStarts = scriptStarts(game, COMMON_SCRIPT_ID)
    Assert.equal(#commonStarts, 1, "one CallStd must create exactly one common obtain-item child")
    childInstanceId = assert(commonStarts[1].payload.instanceId, "the child start must carry instance identity")
    Assert.isTrue(childInstanceId ~= rootInstanceId, "the common child must be a distinct later context")
    local childEnd = assert(scriptEnded(game, COMMON_SCRIPT_ID, childInstanceId), "the common child must terminate")
    Assert.isTrue(childEnd.completed, "the common child must complete after its handoff")

    Assert.equal(#fanfareEffects(game), 1, "the item jingle must play exactly once")
    Assert.equal(maxPotion, POTION_QUANTITY, "the grant must add exactly five Potions, never more")
    Assert.equal(bag:quantity("POTION"), POTION_QUANTITY, "the aide must grant exactly five Potions")
    Assert.equal(
      opens[OBTAIN_BANK_ID .. ":" .. FIRST_MESSAGE_ID],
      1,
      "the first obtain message must print exactly once without requiring a button"
    )
    Assert.equal(
      opens[OBTAIN_BANK_ID .. ":" .. FINAL_MESSAGE_ID],
      1,
      "the final pocket message must print exactly once"
    )

    local waitStarts = taskRecords(game, "script.task_started", "wait_input", childInstanceId)
    Assert.equal(#waitStarts, 1, "exactly one explicit button wait must arm for the final obtain message")
    local waitEnds = taskRecords(game, "script.task_ended", "wait_input", childInstanceId)
    Assert.equal(#waitEnds, 1, "the explicit button wait must complete exactly once")
    local handoffStarts = taskRecords(game, "script.task_started", "child_script", rootInstanceId)
    Assert.equal(#handoffStarts, 1, "the parent must block on exactly one child handoff")
    local handoffEnds = taskRecords(game, "script.task_ended", "child_script", rootInstanceId)
    Assert.equal(#handoffEnds, 1, "the child handoff must complete exactly once")

    Assert.equal(#scriptFaults(game), 0, "the handoff must complete without script faults")
    Assert.equal(world:getVar(VAR_SCENE_ELMS_LAB), 2, "the parent tail must set the lab scene exactly once")

    -- Cleanup: no modal or lock remains, and one normal Start Menu input
    -- opens the menu, so no field-control/menu ownership leaked.
    local closing = game:snapshot()
    Assert.isFalse(closing.dialogue.modal, "no dialogue may remain modal after the aide script completes")
    Assert.isFalse(closing.fieldLocked, "the field must be free for ordinary input after the aide script completes")
    game.runtime:pressMenu()
    game:step()
    game.runtime:releaseMenu()
    game:advanceUntil("the start menu opens after clean aide completion", function()
      return game.runtime.applicationHost:status().phase == FieldApplicationHost.PHASES.menu
    end, 120)
    game.runtime:pressMenu()
    game:step()
    game.runtime:releaseMenu()
    game:advanceUntil("the start menu closes", function(snapshot)
      return game.runtime.applicationHost:status().phase == FieldApplicationHost.PHASES.closed
        and not snapshot.fieldLocked
    end, 120)
  end)
end

return T
