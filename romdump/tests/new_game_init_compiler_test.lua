local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local Hashing = require("romdump.src.digest.Hashing")
local Narc = require("libs.nds.src.nitro.Narc")
local NarcBuilder = require("tests.support.NarcBuilder")
local NewGameInitCompiler = require("romdump.src.digest.newgame.NewGameInitCompiler")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local ScriptFixture = require("tests.support.ScriptFixture")

local PINNED_STD_INIT_SCRIPT = {
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ELMS_LAB_OFFICER" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROUTE_29_FRIEND" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROUTE_29_MARILL" } },
  { mnemonic = "SetFlag", operands = { "FLAG_UNK_1A0" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_NEW_BARK_FRIEND" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ELMS_LAB_FRIEND" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_CHERRYGROVE_RIVAL" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_AZALEA_SLOWPOKES" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ILEX_CUT_MASTER" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ILEX_APPRENTICE" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_FARFETCHD_1_LOST" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_FARFETCHD_2_LOST" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_FARFETCHD_1_FOUND" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_FARFETCHD_2_FOUND" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_GOLDENROD_FLOWERSHOP_GIRL" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_BURNED_TOWER_B1F_EUSINE" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_OLIVINE_RIVAL" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_JASMINE_IN_GYM" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_OLIVINE_GYM_GENTLEMAN" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_OLIVINE_GYM_GIRL" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_CIANWOOD_SUICUNE" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_CIANWOOD_EUSINE" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_LAKE_OF_RAGE_LANCE" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_MAHOGANY_SHOP_SALESWOMAN" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_MAHOGANY_SHOP_LANCE" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROUTE_43_GATE_GUARD" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROCKET_HIDEOUT_B2F_ARIANA" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROCKET_HIDEOUT_B3F_RIVAL" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_BLACKTHORN_GYM_GUARD_ASIDE" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_BLACKTHRON_DEN_GUARD_ASIDE" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ICE_PATH_BOULDER_1_FALLEN" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ICE_PATH_BOULDER_2_FALLEN" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ICE_PATH_BOULDER_3_FALLEN" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ICE_PATH_BOULDER_4_FALLEN" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_VICTORY_ROAD_CLAIR" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_VICTORY_ROAD_RIVAL" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_WILLS_ROOM_RETREAT" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_KOGAS_ROOM_RETREAT" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_BRUNOS_ROOM_RETREAT" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_KARENS_ROOM_RETREAT" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_CHAMPIONS_ROOM_RETREAT" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_PARK_SOUTH_GATE_POKEATHLON_ENTHUSIASTS_UNLOCKED" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_CHERRYGROVE_MART_SPECIAL_CLERK" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_POKEATHLON_RECEPTION_WHITNEY" } },
  { mnemonic = "SetFlag", operands = { "FLAG_UNK_229" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_RADIO_TOWER_RIVAL" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_RUINS_OF_ALPH_ASSISTANTS" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_BATTLE_TOWER_RECEPTIONIST" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_UNDERGROUND_KIMONO_GIRL" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_VIOLET_SHOP_LAB_AIDE" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_VIOLET_KIMONO_GIRL" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_DANCE_STUDIO_KIMONO_GIRLS" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_DANCE_STUDIO_LITTLE_GIRL" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_GOLDENROD_BILL" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ECRUTEAK_RIVAL" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_BELL_TOWER_HO_OH" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_WHIRL_ISLAND_LUGIA" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ECRUTEAK_OLD_MAN" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROCKET_HIDEOUT_B2F_MURKROW_1" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROCKET_HIDEOUT_B3F_MURKROW_2" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROCKET_HIDEOUT_B2F_MURKROW_2" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROCKET_HIDEOUT_B2F_MURKROW_3" } },
  { mnemonic = "LotoIDSet", operands = {} },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROUTE_30_APRICORN_MAN" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_INDIGO_PLATEAU_RIVAL" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_OLIVINE_PORT_OAK" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_CERULEAN_GYM_POPULATION" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_CERULEAN_GYM_ROCKET" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROUTE_24_ROCKET" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROUTE_25_MISTY" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROUTE_25_MISTYS_BOYFRIEND" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_CERULEAN_GYM_MACHINE_PART" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_LAVENDER_RADIO_TOWER_DIRECTOR" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_FUCHSIA_GYM_LASS_LINDA_REVEALED" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_FUCHSIA_GYM_CAMPER_BARRY_REVEALED" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_FUCHSIA_GYM_LASS_ALICE_REVEALED" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_FUCHSIA_GYM_PICNICKER_CINDY_REVEALED" } },
  { mnemonic = "SetFlag", operands = { "FLAG_AZALEA_ROCKET_HARASSING_CIVILIAN" } },
  { mnemonic = "SetFlag", operands = { "FLAG_AZALEA_HARASSED_CIVILIAN" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROCKET_HIDEOUT_B3F_PETREL" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_LAKE_OF_RAGE_ACE_TRAINER_LOIS" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_LAKE_OF_RAGE_FISHERMEN" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROUTE_10_LT_SURGE" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROUTE_10_ZAPDOS" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROUTE_19_WORKMEN_OPEN" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ILEX_FOREST_SPIKY_EAR_PICHU" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ILEX_FOREST_OLD_MAN" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROUTE_42_HIKER" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROUTE_42_SUICUNE" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROUTE_42_EUSINE" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_VERMILION_SUICUNE" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_VERMILION_EUSINE" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROUTE_14_SUICUNE" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROUTE_14_EUSINE" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROUTE_25_SUICUNE" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROUTE_25_EUSINE" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_NEW_BARK_MOM" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_PLAYERS_ROOM_BRONZE_TROPHY" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_PLAYERS_ROOM_SILVER_TROPHY" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_PLAYERS_ROOM_GOLD_TROPHY" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROUTE_14_EUSINE_2" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROUTE_25_EUSINE_2" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_POKEATHLON_SUPREME_CUP_RECEPTIONIST" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_VERMILION_EUSINE_2" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_RADIO_TOWER_5F_PETREL_REVEALED" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_GOLDENROD_UNDERGROUND_FRIEND" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_POKEATHLON_SHOES_SIGN" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_POKEATHLON_CLOTHES_SIGN" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_POKEATHLON_FLAG_SIGN" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_POKEATHLON_POKEGEAR_SIGN" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_POKEATHLON_BALL_SIGN" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_BELL_TOWER_SUMMIT_KIMONO_GIRLS" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_WHIRL_ISLANDS_BOTTOM_KIMONO_GIRLS" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_EARL_IN_SCHOOL" } },
  { mnemonic = "SetFlag", operands = { "FLAG_UNK_2DE" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_SINJOH_MYSTRI_SHRINE_CYNTHIA" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROUTE_47_CRASHER_WAKE" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROUTE_30_YOUNGSTER_JOEY" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_DRAGONS_DEN_RIVAL" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_VIOLET_GYM_GYM_GUY_BEFORE_SPROUT" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ALPH_OUTSIDE_ARCEUS_EVENT_SUIT" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ALPH_MAIN_CHAMBER_ARCEUS_EVENT_PEOPLE" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_NEW_BARK_FRIEND_2" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_VIRIDIAN_CITY_OLD_MAN_OUTSIDE_GYM_UNLOCKED" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_VERMILION_FAN_CLUB_LOST_ITEM" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_VERMILION_CITY_STEVEN" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_OAKS_LAB_BULBASAUR_BALL" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_OAKS_LAB_CHARMANDER_BALL" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_OAKS_LAB_SQUIRTLE_BALL" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROUTE_22_GIOVANNI_RIVAL" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_TOHJO_FALLS_GIOVANNI" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_PEWTER_CITY_STEVEN" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_PEWTER_CITY_LATIOS" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_PEWTER_CITY_LATIAS" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_BURNED_TOWER_STATIC_SUICUNE" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ILEX_FOREST_FRIEND" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROUTE_22_FRIEND" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_TOHJO_FALLS_FRIEND" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_LAKE_OF_RAGE_PRYCE" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_COMM_CLUB_RECEPTIONISTS" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_STEVEN_IN_HOUSE_AFTER_LATIS" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_STEVEN_IN_HOUSE_BEFORE_LATIS" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_SAFARI_ZONE_WORKERS" } },
  { mnemonic = "SetFlag", operands = { "FLAG_HIDE_ROUTE_12_SNORLAX" } },
  { mnemonic = "End", operands = {} },
}

local PINNED_SET_FLAG_COUNT = 143

local function copyScript(script)
  local out = {}
  for index, instruction in ipairs(script) do
    out[index] = { mnemonic = instruction.mnemonic, operands = instruction.operands }
  end
  return out
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured producer error")
  Assert.equal(err.code, code)
end

local T = {}

function T.compiles_the_real_standard_init_script_with_ordered_operations()
  local vars = FieldScriptSymbols.variablesByName

  local artifact = NewGameInitCompiler.compile({
    versionId = "heartgold",
    standardScriptMember = 149,
    instructions = PINNED_STD_INIT_SCRIPT,
    symbolTable = FieldScriptSymbols.flagsByName,
    variableSymbols = vars,
    sourceSha1 = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
  })
  Assert.equal(#artifact.operations, PINNED_SET_FLAG_COUNT + 1)
  Assert.isNil(artifact.eventOperations)
  Assert.isNil(artifact.nonFieldEffects)
  local lotoIndex
  for idx, op in ipairs(artifact.operations) do
    if op.op == "roll_loto_id" then
      lotoIndex = idx
      Assert.equal(op.lowVariableId, vars.VAR_LOTO_NUMBER_LO)
      Assert.equal(op.highVariableId, vars.VAR_LOTO_NUMBER_HI)
      Assert.equal(op.lowVariableSymbol, "VAR_LOTO_NUMBER_LO")
      Assert.equal(op.highVariableSymbol, "VAR_LOTO_NUMBER_HI")
    elseif op.op == "set_flag" then
      Assert.isTrue(type(op.id) == "number")
    else
      error("unexpected op " .. tostring(op.op))
    end
  end
  Assert.notNil(lotoIndex)
  -- Loto is between the two flag groups in source order (after index ~77, before next flag)
  local beforeSymbol = artifact.operations[lotoIndex - 1].symbol
  local afterSymbol = artifact.operations[lotoIndex + 1].symbol
  Assert.isTrue(beforeSymbol ~= nil and afterSymbol ~= nil, "loto must be between two flag ops")
  Assert.equal(artifact.schema, "g4-new-game-init-v3")

  local drifted = copyScript(PINNED_STD_INIT_SCRIPT)
  table.insert(drifted, #drifted, { mnemonic = "GivePokemon", operands = { "SPECIES_TOTODILE" } })
  throwsCode("NEW_GAME_INIT_UNSUPPORTED_SIDE_EFFECT", function()
    NewGameInitCompiler.compile({
      versionId = "heartgold",
      standardScriptMember = 149,
      instructions = drifted,
      symbolTable = FieldScriptSymbols.flagsByName,
      variableSymbols = vars,
    })
  end)
end

function T.compiled_artifact_carries_the_source_grounded_initial_location()
  local vars = FieldScriptSymbols.variablesByName

  local artifact = NewGameInitCompiler.compile({
    versionId = "heartgold",
    standardScriptMember = 149,
    instructions = PINNED_STD_INIT_SCRIPT,
    symbolTable = FieldScriptSymbols.flagsByName,
    variableSymbols = vars,
    sourceSha1 = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
  })
  Assert.deepEqual(artifact.initialLocation, {
    mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
    fieldX = 6,
    fieldZ = 6,
    facing = "south",
  })
  Assert.equal(MapCatalog.idForSymbol("MAP_NEW_BARK_PLAYER_HOUSE_2F"), 64)
  Assert.equal(MapCatalog.symbolForId(64), "MAP_NEW_BARK_PLAYER_HOUSE_2F")
end

function T.non_field_side_effect_is_explicit_and_bounded_to_loto_id_set()
  local vars = FieldScriptSymbols.variablesByName

  local artifact = NewGameInitCompiler.compile({
    versionId = "heartgold",
    standardScriptMember = 149,
    instructions = PINNED_STD_INIT_SCRIPT,
    symbolTable = FieldScriptSymbols.flagsByName,
    variableSymbols = vars,
    sourceSha1 = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
  })
  local lotoCount = 0
  for _, op in ipairs(artifact.operations) do
    if op.op == "roll_loto_id" then
      lotoCount = lotoCount + 1
    end
  end
  Assert.equal(lotoCount, 1)

  local mutated = copyScript(PINNED_STD_INIT_SCRIPT)
  for index, instruction in ipairs(mutated) do
    if instruction.mnemonic == "LotoIDSet" then
      mutated[index] = { mnemonic = "GiveEgg", operands = { "SPECIES_PICHU" } }
      break
    end
  end
  throwsCode("NEW_GAME_INIT_UNSUPPORTED_SIDE_EFFECT", function()
    NewGameInitCompiler.compile({
      versionId = "heartgold",
      standardScriptMember = 149,
      instructions = mutated,
      symbolTable = FieldScriptSymbols.flagsByName,
      variableSymbols = vars,
    })
  end)
end

function T.unknown_lottery_symbols_fail_explicitly()
  throwsCode("NEW_GAME_INIT_SOURCE_INVALID", function()
    NewGameInitCompiler.compile({
      versionId = "heartgold",
      standardScriptMember = 149,
      instructions = PINNED_STD_INIT_SCRIPT,
      symbolTable = FieldScriptSymbols.flagsByName,
      variableSymbols = {},
    })
  end)
end

function T.compile_from_rom_decodes_only_the_catalog_selected_member()
  local initMember = 149
  local firstFlag = 413
  local secondFlag = 420
  local initBytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 30, args = { { value = firstFlag, width = 2 } } },
          { op = 30, args = { { value = secondFlag, width = 2 } } },
          { op = 2, args = {} },
        },
      },
    },
  })
  local otherBytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = { { op = 2, args = {} } },
      },
    },
  })
  local members = {}
  for memberId = 0, initMember do
    members[#members + 1] = memberId == initMember and initBytes or otherBytes
  end
  local archive = assert(Narc.open(NarcBuilder.build(members), "synthetic scripts"))
  local viewed = {}
  local spy = {
    memberCount = function()
      return archive:memberCount()
    end,
    memberView = function(_, memberId)
      viewed[#viewed + 1] = memberId
      return archive:memberView(memberId)
    end,
    readMember = function(_, memberId)
      return archive:readMember(memberId)
    end,
  }
  local romFs = {
    read = function()
      error("initializer must read through the script archive")
    end,
    openNarc = function(_, alias)
      Assert.equal(alias, "field_scripts")
      return spy
    end,
    resolvedNarc = function(_, alias)
      Assert.equal(alias, "field_scripts")
      return { path = "synthetic/scr_seq.narc" }
    end,
    version = function()
      return "heartgold"
    end,
    metadata = function()
      return { sha1 = "synthetic-rom-sha" }
    end,
  }

  local compiled = assert(NewGameInitCompiler.compileFromRom(romFs))

  local selected = {}
  for _, memberId in ipairs(viewed) do
    selected[memberId] = true
  end
  local selectedList = {}
  for memberId in pairs(selected) do
    selectedList[#selectedList + 1] = memberId
  end
  Assert.deepEqual(selectedList, { initMember })
  Assert.equal(compiled.artifact.sourceDependency.standardScriptMember, initMember)
  Assert.equal(compiled.artifact.sourceDependency.sha1, Hashing.sha1hex(initBytes))
  Assert.equal(compiled.artifact.schema, "g4-new-game-init-v3")
  Assert.equal(#compiled.artifact.operations, 2)
  Assert.deepEqual(compiled.artifact.operations[1], {
    op = "set_flag",
    id = firstFlag,
    symbol = "FLAG_HIDE_ELMS_LAB_OFFICER",
  })
  Assert.deepEqual(compiled.artifact.operations[2], {
    op = "set_flag",
    id = secondFlag,
    symbol = "FLAG_HIDE_ROUTE_29_FRIEND",
  })
end

return { tests = T }
