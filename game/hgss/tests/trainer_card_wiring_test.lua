-- Production Trainer Card composition contract: the runtime itself registers
-- the trainer_card application at catalogue construction (no boot-config
-- descriptor), its factory passes the authoritative player profile and the
-- controller copies the immutable fields at construction, the host snapshot
-- presents the card with exactly the implemented profile fields during the
-- application phase, and the production save -> resume round trip proves the
-- restored player-data bucket drives the card (never a re-read of the
-- initial manifest).

local Assert = require("tests.support.Assert")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "trainer-card", "persistence", "profile" },
  },
  tests = {},
}

local function hostStatus(game)
  local host = game.runtime.applicationHost
  return host:status()
end

local function pressMenuEdge(game)
  game.runtime:pressMenu()
  game:step()
  game.runtime:releaseMenu()
end

local function advanceToPhase(game, phase, maxTicks)
  return game:advanceUntil("start menu reaches " .. phase, function()
    return hostStatus(game).phase == phase
  end, maxTicks)
end

local function openCard(game)
  pressMenuEdge(game)
  advanceToPhase(game, "menu", 16)
  game.runtime:pressAction()
  game:step()
  game.runtime:releaseAction()
  advanceToPhase(game, "application", 64)
end

local function cardStatus(game)
  return hostStatus(game).application
end

-- The production factory registers the card without a boot-config descriptor
-- and the application phase presents the authoritative profile; the fresh ->
-- save -> resume round trip proves the restored player-data bucket drives the
-- card after a resume.
function T.tests.production_factory_registers_the_card_and_resume_drives_the_presentation()
  local game = AcceptanceHarness.new({ versions = { "heartgold" } }):boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
  })
  game:waitForFieldEntry()
  local ok, err = xpcall(function()
    local runtime = game.runtime
    local applications = runtime.applications
    Assert.isTrue(type(applications) == "table", "the runtime must expose the application registry")
    Assert.equal(
      applications:has("trainer_card"),
      true,
      "the production runtime must register the trainer_card application itself"
    )

    -- The vanilla trainer_card action becomes interactive exactly because
    -- its unlock flag is set and the production destination exists.
    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_TRAINER_CARD })

    openCard(game)
    local status = cardStatus(game)
    Assert.isTrue(type(status) == "table", "the host must present the card application")
    Assert.equal(status.name, runtime.playerData.profile.name)
    Assert.equal(status.trainerId, runtime.playerData.profile.trainerId)
    Assert.keySet(
      status,
      "money,name,open,playTimeSeconds,presentation,trainerId,visibleTrainerId",
      "the card exposes the implemented profile fields plus its presentation plan"
    )

    -- The saved bucket wins over the initial manifest after a resume: return
    -- to the field (the settled boundary allows the disposal save), mutate
    -- the runtime's own player-data record, let the restart save it, and the
    -- resumed card must present the restored values.
    game.runtime:pressCancel()
    game:step()
    game.runtime:releaseCancel()
    advanceToPhase(game, "menu", 64)
    pressMenuEdge(game)
    advanceToPhase(game, "closed", 16)
    runtime.playerData.profile.name = "HIKARI"
    runtime.playerData.profile.trainerId = 54321
    local resumed = game:restart({ save = "resume" })
    Assert.equal(resumed.runtime.playerData.profile.name, "HIKARI")
    resumed:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_TRAINER_CARD })
    resumed:advanceUntil("resumed field reaches ready", function(snapshot)
      return resumed.runtime.session.mapEntryStage == nil and not snapshot.fieldLocked
    end, 240)
    openCard(resumed)
    local resumedStatus = cardStatus(resumed)
    Assert.equal(resumedStatus.name, "HIKARI", "the resumed card presents the saved name, not the manifest")
    Assert.equal(resumedStatus.trainerId, 54321)
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
  Assert.equal(game:renderAttempts(), 0, "the card composition must not render")
end

return T
