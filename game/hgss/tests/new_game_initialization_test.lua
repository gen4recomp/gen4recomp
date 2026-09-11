local Assert = require("tests.support.Assert")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local MonsSave = require("libs.mons.src.MonsSave")
local BagSave = require("libs.hgss.src.save.BagSave")
local PlayerData = require("libs.hgss.src.save.PlayerData")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local WorldState = require("libs.hgss.src.script.WorldState")
local GameSave = require("libs.hgss.src.save.GameSave")

local T = {}

local flags = FieldScriptSymbols.flagsByName
local vars = FieldScriptSymbols.variablesByName

local function v2Artifact(overrides)
  local base = {
    schema = "g4-new-game-init-v2",
    versionId = "heartgold",
    operations = {
      {
        op = "set_flag",
        id = flags.FLAG_HIDE_PLAYERS_ROOM_BRONZE_TROPHY,
        symbol = "FLAG_HIDE_PLAYERS_ROOM_BRONZE_TROPHY",
      },
      {
        op = "roll_loto_id",
        lowVariableId = vars.VAR_LOTO_NUMBER_LO,
        lowVariableSymbol = "VAR_LOTO_NUMBER_LO",
        highVariableId = vars.VAR_LOTO_NUMBER_HI,
        highVariableSymbol = "VAR_LOTO_NUMBER_HI",
      },
      {
        op = "set_flag",
        id = flags.FLAG_HIDE_PLAYERS_ROOM_SILVER_TROPHY,
        symbol = "FLAG_HIDE_PLAYERS_ROOM_SILVER_TROPHY",
      },
      { op = "set_flag", id = flags.FLAG_HIDE_NEW_BARK_FRIEND, symbol = "FLAG_HIDE_NEW_BARK_FRIEND" },
    },
    sourceDependency = { standardScriptMember = 149, sha1 = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" },
  }
  if overrides then
    for k, v in pairs(overrides) do
      base[k] = v
    end
  end
  return base
end

local function finalizedCandidate()
  local eventState = FieldEventState.new()
  eventState:setFlag(flags.FLAG_UNK_960)
  local playerData = assert(PlayerData.validate({
    profile = { name = "GOLD", gender = 0, trainerId = 1234, money = 3000 },
    options = PlayerData.defaultOptions(),
  }, { charmap = { G = 1, O = 2, L = 3, D = 4 }, frameIndexes = { [0] = true } }))
  return {
    saveId = "save-00000001",
    versionId = "heartgold",
    location = { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6, facing = "south" },
    profileDraft = { money = 3000 },
    options = PlayerData.defaultOptions(),
    playTime = PlayTime.new(),
    worldState = eventState,
    surfaceId = nil,
    playerData = playerData,
  }
end

local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, child in pairs(value) do
    copy[key] = deepCopy(child)
  end
  return copy
end

function T.applying_startup_flags_preserves_finalized_player_and_fast_options()
  local NewGameInitialization = require("game.hgss.src.newgame.NewGameInitialization")
  local candidate = finalizedCandidate()
  local playerDataBefore = deepCopy(candidate.playerData)
  local optionsBefore = deepCopy(candidate.options)

  local seq = { 0x1111, 0x2222 }
  local idx = 0
  local result = NewGameInitialization.apply(candidate, {
    artifact = v2Artifact(),
    randomU16 = function()
      idx = idx + 1
      return seq[idx]
    end,
  })

  Assert.deepEqual(result.playerData, playerDataBefore)
  Assert.deepEqual(result.options, optionsBefore)
  Assert.equal(result.playerData.options.textSpeed, "fastest")
  Assert.isTrue(result.worldState:isFlagSet(flags.FLAG_UNK_960), "the opening flag must survive startup initialization")
  Assert.isTrue(result.worldState:isFlagSet(flags.FLAG_HIDE_PLAYERS_ROOM_BRONZE_TROPHY))
  Assert.isTrue(result.worldState:isFlagSet(flags.FLAG_HIDE_PLAYERS_ROOM_SILVER_TROPHY))
  Assert.isTrue(result.worldState:isFlagSet(flags.FLAG_HIDE_NEW_BARK_FRIEND))
end

function T.applying_an_already_set_flag_is_idempotent()
  local NewGameInitialization = require("game.hgss.src.newgame.NewGameInitialization")
  local candidate = finalizedCandidate()
  candidate.worldState:setFlag(flags.FLAG_HIDE_PLAYERS_ROOM_BRONZE_TROPHY)

  local seq = { 0x1234, 0x5678 }
  local i = 0
  local result = NewGameInitialization.apply(candidate, {
    artifact = v2Artifact(),
    randomU16 = function()
      i = i + 1
      return seq[i]
    end,
  })

  Assert.isTrue(result.worldState:isFlagSet(flags.FLAG_HIDE_PLAYERS_ROOM_BRONZE_TROPHY))
end

function T.lottery_draws_twice_writes_low_twice_and_leaves_high_untouched()
  local NewGameInitialization = require("game.hgss.src.newgame.NewGameInitialization")
  local candidate = finalizedCandidate()
  candidate.worldState:setVar(vars.VAR_LOTO_NUMBER_HI, 0xABCD)
  local draws = { 0x1234, 0x5678 }
  local calls = 0
  local writes = {}
  local originalSetVar = candidate.worldState.setVar
  candidate.worldState.setVar = function(self, id, value)
    if id == vars.VAR_LOTO_NUMBER_LO then
      writes[#writes + 1] = value
    end
    return originalSetVar(self, id, value)
  end
  NewGameInitialization.apply(candidate, {
    artifact = v2Artifact(),
    randomU16 = function()
      calls = calls + 1
      if calls > 2 then
        error("randomU16 called more than twice")
      end
      return draws[calls]
    end,
  })
  Assert.equal(calls, 2)
  Assert.deepEqual(writes, { 0x1234, 0x5678 })
  Assert.equal(candidate.worldState:getVar(vars.VAR_LOTO_NUMBER_LO), 0x5678)
  Assert.equal(candidate.worldState:getVar(vars.VAR_LOTO_NUMBER_HI), 0xABCD)
end

function T.invalid_random_returns_fail_before_state_write()
  local NewGameInitialization = require("game.hgss.src.newgame.NewGameInitialization")
  local function checkInvalid(value)
    local candidate = finalizedCandidate()
    local ok = pcall(NewGameInitialization.apply, candidate, {
      artifact = v2Artifact(),
      randomU16 = function()
        return value
      end,
    })
    Assert.isFalse(ok)
  end
  checkInvalid(-1)
  checkInvalid(0x10000)
  checkInvalid(3.14)
  checkInvalid("x")
end

function T.operations_execute_in_order()
  local NewGameInitialization = require("game.hgss.src.newgame.NewGameInitialization")
  local candidate = finalizedCandidate()
  local beforeFlag = flags.FLAG_HIDE_PLAYERS_ROOM_BRONZE_TROPHY
  local afterFlag = flags.FLAG_HIDE_PLAYERS_ROOM_SILVER_TROPHY
  local artifact = v2Artifact({
    operations = {
      { op = "set_flag", id = beforeFlag, symbol = "FLAG_HIDE_PLAYERS_ROOM_BRONZE_TROPHY" },
      {
        op = "roll_loto_id",
        lowVariableId = vars.VAR_LOTO_NUMBER_LO,
        lowVariableSymbol = "VAR_LOTO_NUMBER_LO",
        highVariableId = vars.VAR_LOTO_NUMBER_HI,
        highVariableSymbol = "VAR_LOTO_NUMBER_HI",
      },
      { op = "set_flag", id = afterFlag, symbol = "FLAG_HIDE_PLAYERS_ROOM_SILVER_TROPHY" },
    },
  })
  local observed = {}
  NewGameInitialization.apply(candidate, {
    artifact = artifact,
    randomU16 = function()
      observed.beforeSet = candidate.worldState:isFlagSet(beforeFlag)
      observed.afterSet = candidate.worldState:isFlagSet(afterFlag)
      if observed.calls == nil then
        observed.calls = 1
        return 0x1111
      else
        observed.calls = observed.calls + 1
        return 0x2222
      end
    end,
  })
  Assert.isTrue(observed.beforeSet)
  Assert.isFalse(observed.afterSet)
end

function T.candidate_non_world_data_unchanged()
  local NewGameInitialization = require("game.hgss.src.newgame.NewGameInitialization")
  local candidate = finalizedCandidate()
  local saveIdBefore = candidate.saveId
  local locationBefore = deepCopy(candidate.location)
  local seq = { 0x0001, 0x0002 }
  local i = 0
  NewGameInitialization.apply(candidate, {
    artifact = v2Artifact(),
    randomU16 = function()
      i = i + 1
      return seq[i]
    end,
  })
  Assert.equal(candidate.saveId, saveIdBefore)
  Assert.deepEqual(candidate.location, locationBefore)
end

function T.lottery_persists_through_world_capture_and_game_save()
  local NewGameInitialization = require("game.hgss.src.newgame.NewGameInitialization")
  local candidate = finalizedCandidate()
  local seq = { 0x1234, 0x5678 }
  local i = 0
  NewGameInitialization.apply(candidate, {
    artifact = v2Artifact(),
    randomU16 = function()
      i = i + 1
      return seq[i]
    end,
  })
  local ws = WorldState.new({ eventState = candidate.worldState })
  local captured = ws:capture()
  Assert.equal(captured.variables[vars.VAR_LOTO_NUMBER_LO], 0x5678)
  Assert.isNil(captured.variables[vars.VAR_LOTO_NUMBER_HI])
  local record = {
    schema = GameSave.SCHEMA,
    saveId = candidate.saveId,
    versionId = candidate.versionId,
    mapId = 1,
    fieldX = 0,
    fieldZ = 0,
    worldY = 0,
    surfaceId = 0,
    facing = "south",
    terrainDependencyHash = "hash",
    playTimeSeconds = 0,
    playerData = candidate.playerData,
    world = captured,
    scripts = { tasks = {} },
    auxiliaryUi = {},
    audio = {},
    mons = MonsSave.empty("test-catalog-fingerprint", 7),
    bag = BagSave.empty(),
  }
  local validated = assert(GameSave.validate(record))
  Assert.equal(validated.world.variables[vars.VAR_LOTO_NUMBER_LO], 0x5678)
  local restored = WorldState.restore(validated.world)
  Assert.equal(restored:getVar(vars.VAR_LOTO_NUMBER_LO), 0x5678)
  Assert.equal(restored:getVar(vars.VAR_LOTO_NUMBER_HI), 0)
end

return { tests = T }
