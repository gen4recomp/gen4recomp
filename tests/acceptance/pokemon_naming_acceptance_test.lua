-- The production field scheduler runs a real script through GiveMon and
-- both Pokemon nickname task outcomes; only host audio and save storage are
-- deterministic acceptance boundaries.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local AcceptanceScripts = require("tests.acceptance.support.AcceptanceScripts")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local Personality = require("libs.mons.src.gen4.Personality")
local PlayTime = require("libs.hgss.src.save.PlayTime")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "pokemon", "naming", "acceptance" },
  },
  tests = {},
}

local VAR_GIVE_MON = FieldScriptSymbols.variablesByName.VAR_UNK_407C
local VAR_BLANK_NICKNAME = FieldScriptSymbols.variablesByName.VAR_UNK_407D
local VAR_CHANGED_NICKNAME = FieldScriptSymbols.variablesByName.VAR_UNK_407F

local function withGame(fn)
  local harness = AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      return {
        saveId = "save-00000001",
        versionId = versionId,
        location = { mapSymbol = map or "MAP_NEW_BARK", fieldX = 4, fieldZ = 10, facing = "south" },
        playerData = {
          profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
          options = { textSpeed = "fastest", textFrame = 0 },
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
    map = "MAP_NEW_BARK",
    save = "fresh",
    fieldOptions = { acceptanceScripts = AcceptanceScripts },
  })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "Pokemon naming acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function waitForNaming(game, label)
  game:advanceUntil(label, function()
    return game.runtime.pokemonNaming:isActive()
  end, 240)
end

local function submitAtOk(game)
  for _ = 1, 6 do
    local status = assert(game.runtime.pokemonNaming:status(), "the naming task remains active")
    if status.snapshot.cursor.row == 1 then
      break
    end
    game:move("north")
  end
  local status = assert(game.runtime.pokemonNaming:status(), "the naming task remains active")
  Assert.equal(status.snapshot.cursor.row, 1, "navigation reaches the naming home row")

  for _ = 1, 6 do
    status = assert(game.runtime.pokemonNaming:status(), "the naming task remains active")
    if status.snapshot.cursor.controlId == "ok" then
      break
    end
    game:move("east")
  end
  status = assert(game.runtime.pokemonNaming:status(), "the naming task remains active")
  Assert.equal(status.snapshot.cursor.controlId, "ok", "navigation reaches the naming OK control")
  game:pressAction()
end

function T.tests.real_nickname_script_preserves_subject_and_result_semantics()
  withGame(function(game)
    game:waitForFieldEntry()
    game:startScript("acceptance.pokemon_naming")

    waitForNaming(game, "the production nickname task opens after the script gives a mon")
    Assert.equal(game.runtime.monService:partyCount(), 1, "the script gives exactly one party mon")
    Assert.equal(game.runtime.scripts.worldState:getVar(VAR_GIVE_MON), 1, "the source give-mon result is true")

    local mon = game.runtime.monService:partyMon(0)
    local species = game.runtime.monService:catalog():species(mon.species)
    local expectedGender = Personality.gender(species.genderRatio, mon.personality)
    local opened = assert(game.runtime.pokemonNaming:status(), "the first nickname modal is active")
    Assert.equal(opened.snapshot.subject.kind, "pokemon", "the modal identifies its Pokemon subject")
    Assert.equal(opened.snapshot.subject.species, species.nativeId, "the subject preserves species identity")
    Assert.equal(opened.snapshot.subject.form, mon.form, "the subject preserves form identity")
    Assert.equal(opened.snapshot.subject.iconKey, game.runtime.monService:catalog():iconSelection(mon))
    Assert.equal(
      opened.snapshot.subject.gender,
      expectedGender,
      "the subject carries gender derived by the Generation IV personality rule"
    )

    -- Submitting the initial empty buffer follows the source unchanged-name
    -- result and leaves the live mon without a materialized nickname.
    submitAtOk(game)
    waitForNaming(game, "the same script reopens its second nickname task")
    Assert.equal(game.runtime.scripts.worldState:getVar(VAR_BLANK_NICKNAME), 1)
    Assert.isNil(game.runtime.monService:partyMon(0).nickname, "blank input does not write a nickname")

    -- The naming controller starts on A; move south to K and confirm through
    -- the actual keyboard controls. The completed task writes through the live mon service.
    Assert.equal(assert(game.runtime.pokemonNaming:status()).snapshot.grid[2][1].glyph, "A")
    game:move("south")
    Assert.equal(assert(game.runtime.pokemonNaming:status()).snapshot.grid[3][1].glyph, "K")
    game:pressAction()
    Assert.equal(assert(game.runtime.pokemonNaming:status()).text, "K", "the keyboard accepts a real glyph")
    submitAtOk(game)
    game:advanceUntil("the nickname script commits the changed name", function()
      return not game.runtime.pokemonNaming:isActive() and game.runtime.monService:partyMon(0).nickname == "K"
    end, 240)
    Assert.equal(game.runtime.scripts.worldState:getVar(VAR_CHANGED_NICKNAME), 0)
    Assert.equal(game.runtime.monService:partyMon(0).nickname, "K", "changed input commits to the live mon")
  end)
end

return T
