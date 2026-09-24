-- Production-composed field Yes/No flow: the real script task, dialogue host,
-- message provider, and field runtime remain the owners of the journey.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local AcceptanceScripts = require("tests.acceptance.support.AcceptanceScripts")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "dialogue", "yes-no", "acceptance" },
  },
  tests = {},
}

local VAR_FIRST_RESULT = FieldScriptSymbols.variablesByName.VAR_UNK_407C
local VAR_SECOND_RESULT = FieldScriptSymbols.variablesByName.VAR_UNK_407D
local VAR_THIRD_RESULT = FieldScriptSymbols.variablesByName.VAR_UNK_407F

local function singleDisplay(width, height)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    role = "world",
    touch = false,
  })
end

local function withGame(topology, fn)
  local harness = AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      return {
        saveId = "save-00000001",
        versionId = versionId,
        location = { mapSymbol = map, fieldX = 10, fieldZ = 10, facing = "south" },
        playerData = {
          profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
          options = { textSpeed = "fastest", textFrame = 1 },
        },
        playTime = PlayTime.new(),
        worldState = FieldEventState.new(),
        mons = require("tests.support.MonBucket").emptyForVersion(versionId),
        bag = require("libs.hgss.src.save.BagSave").empty(),
      }
    end,
  })
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
    fieldOptions = {
      acceptanceScripts = AcceptanceScripts,
      screenTopology = topology,
    },
  })
  local ok, err = xpcall(function()
    fn(game)
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function pressDirection(game, direction)
  game.runtime:press(direction, "acceptance")
  game:step()
  game.runtime:release(direction, "acceptance")
end

local function pressAction(game)
  game.runtime:pressAction("acceptance")
  local snapshot = game:step()
  game.runtime:releaseAction("acceptance")
  return snapshot
end

local function pressCancel(game)
  game.runtime:pressCancel("acceptance")
  local snapshot = game:step()
  game.runtime:releaseCancel("acceptance")
  return snapshot
end

-- A field script reaches the production Yes/No owner and writes source-shaped
-- values through the scheduler. The selected frame and ordinary dialogue
-- remain live until the script's explicit close_message operation.
function T.tests.field_script_yes_no_is_interactive_and_preserves_dialogue()
  local function exercise(game)
    game:waitForFieldEntry()
    game:startScript("acceptance.field_yes_no")
    local opened = game:advanceUntil("field Yes/No choice opens", function()
      return game.runtime.scripts.dialogueHost:yesNoPresentation() ~= nil
    end, 480)
    Assert.equal(opened.dialogue.frameIndex, 1, "the choice must inherit the selected dialogue frame")

    pressAction(game)
    game:advanceUntil("second field Yes/No choice opens", function()
      return game.runtime.scripts.dialogueHost:yesNoPresentation() ~= nil
    end, 120)
    Assert.equal(game.runtime.scripts.worldState:getVar(VAR_FIRST_RESULT), 0, "Yes writes source value 0")
    pressDirection(game, "south")
    local afterConfirm = pressAction(game)
    Assert.isTrue(afterConfirm.dialogue.modal, "answering must not close the ordinary dialogue")

    game:advanceUntil("third field Yes/No choice opens", function()
      return game.runtime.scripts.dialogueHost:yesNoPresentation() ~= nil
    end, 120)
    Assert.equal(game.runtime.scripts.worldState:getVar(VAR_SECOND_RESULT), 1, "No writes source value 1")
    pressCancel(game)
    game:advanceUntil("field question script closes its dialogue", function(snapshot)
      return snapshot.foregroundScript == nil and not snapshot.dialogue.modal
    end, 120)
    Assert.equal(game.runtime.scripts.worldState:getVar(VAR_THIRD_RESULT), 1, "B writes source value 1")
  end

  withGame(singleDisplay(640, 480), exercise)
  withGame(singleDisplay(360, 640), exercise)
end

function T.tests.cancelling_active_field_yes_no_releases_only_the_choice()
  withGame(singleDisplay(640, 480), function(game)
    game:waitForFieldEntry()
    game:startScript("acceptance.field_yes_no_cancel")
    game:advanceUntil("field Yes/No choice opens for cancellation", function(snapshot)
      return snapshot.dialogue.modal and game.runtime.scripts.dialogueHost:yesNoPresentation() ~= nil
    end, 480)

    local dialogueHost = game.runtime.scripts.dialogueHost
    Assert.isTrue(game:snapshot().dialogue.modal, "ordinary dialogue is open before cancellation")
    local scheduler = game.runtime.scripts.scheduler
    local environmentId = assert(scheduler:foregroundEnvironmentId(), "the choice script owns the foreground")
    scheduler:cancelEnvironment(environmentId, "acceptance choice cleanup")

    Assert.isNil(dialogueHost:yesNoPresentation(), "cancelling the task removes the choice surface")
    Assert.isTrue(game:snapshot().dialogue.modal, "cancelling the task leaves ordinary dialogue open")
    scheduler:cancelEnvironment(environmentId, "repeat cleanup")
    Assert.isNil(dialogueHost:yesNoPresentation(), "repeated cleanup keeps the choice closed")
    Assert.isTrue(game:snapshot().dialogue.modal, "repeated cleanup still preserves ordinary dialogue")
  end)
end

return T
