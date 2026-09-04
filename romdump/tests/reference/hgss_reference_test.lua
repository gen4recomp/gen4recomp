-- Public invariants for the frozen HGSS reference catalogs. These tests ensure
-- snapshot structure and representative records remain intact without a ROM.

local Assert = require("tests.support.Assert")
local maps = require("romdump.src.reference.hgss.maps")
local narcs = require("romdump.src.reference.hgss.narcs")
local playerAvatar = require("romdump.src.reference.hgss.player_avatar")
local signpostCommands = require("romdump.src.reference.hgss.signpost_commands")

local T = {}

local BOOLEAN_FIELDS = {
  "bikeAllowed",
  "runningAllowedUnused",
  "escapeRopeAllowed",
  "flyAllowed",
  "outgoingCalls",
  "incomingCalls",
  "radioSignal",
}

local MEMBER_ID_FIELDS = {
  "wildEncounterMemberId",
  "areaDataMemberId",
  "matrixMemberId",
  "scriptsMemberId",
  "scriptHeaderMemberId",
  "messageMemberId",
  "eventMemberId",
}

function T.narc_catalog_is_complete_and_unique()
  Assert.equal(narcs.schema, 1)
  Assert.equal(narcs.count, 267)
  local ids, symbols, paths, count = {}, {}, {}, 0
  for symbol, entry in pairs(narcs.entries) do
    Assert.isTrue(symbol ~= "")
    Assert.isTrue(entry.path ~= "")
    Assert.isNil(ids[entry.narcId])
    Assert.isNil(symbols[symbol])
    Assert.isNil(paths[entry.path])
    ids[entry.narcId], symbols[symbol], paths[entry.path] = true, true, true
    count = count + 1
  end
  Assert.equal(count, 267)
  for narcId = 0, 266 do
    Assert.isTrue(ids[narcId])
  end
end

-- Regression: a source NARC ID quoted in decompiled ARM assembly is a hex
-- literal (e.g. `0x67`), but this catalog's narcId field is decimal. Reading
-- a hex source ID as though it were already decimal previously misresolved
-- NARC 0x67 (=103, field_static_models / a/1/0/3) to path a/0/6/7 -- an
-- unrelated 2D sprite archive -- and cost a full research pass to catch.
function T.hex_narc_id_from_disassembly_resolves_through_decimal_conversion_not_digit_reuse()
  Assert.equal(tonumber("0x67"), 103, "0x67 is decimal 103, not a path built from its own hex digits")
  Assert.equal(narcs.entries.NARC_a_1_0_3.narcId, 103)
  Assert.equal(narcs.entries.NARC_a_1_0_3.path, "a/1/0/3")
  -- The decimal-67 archive is a real, different NARC (a/0/6/7). Its path
  -- happening to spell out 0x67's own digits is exactly what makes it a
  -- tempting but wrong resolution for the hex literal 0x67.
  Assert.equal(narcs.entries.NARC_a_0_6_7.narcId, 67)
  Assert.equal(narcs.entries.NARC_a_0_6_7.path, "a/0/6/7")
  Assert.isTrue(
    narcs.entries.NARC_a_1_0_3.path ~= narcs.entries.NARC_a_0_6_7.path,
    "hex 0x67 (narcId 103) must not resolve to the decimal-67 archive's path"
  )
end

function T.map_catalog_is_complete_and_well_typed()
  Assert.equal(maps.schema, 2)
  Assert.equal(maps.count, 540)
  local symbols = {}
  for id = 0, 539 do
    local record = assert(maps.byId[id])
    Assert.equal(record.id, id)
    Assert.isTrue(record.symbol ~= "")
    Assert.isNil(symbols[record.symbol])
    symbols[record.symbol] = true
    for _, field in ipairs(BOOLEAN_FIELDS) do
      Assert.equal(type(record[field]), "boolean")
    end
    for _, field in ipairs(MEMBER_ID_FIELDS) do
      Assert.equal(type(record[field]), "number")
    end
  end
end

function T.map_catalog_boundaries_are_stable()
  Assert.equal(maps.byId[0].symbol, "MAP_EVERYWHERE")
  Assert.equal(maps.byId[539].symbol, "MAP_POKEMON_LEAGUE_ENTRANCE_WIFI_ROOM")
end

function T.new_bark_records_are_stable()
  local town = maps.byId[60]
  Assert.equal(town.symbol, "MAP_NEW_BARK")
  Assert.deepEqual({
    town.matrixMemberId,
    town.areaDataMemberId,
    town.scriptsMemberId,
    town.scriptHeaderMemberId,
    town.messageMemberId,
    town.eventMemberId,
  }, { 0, 2, 842, 615, 542, 57 })

  local lab = maps.byId[61]
  Assert.equal(lab.symbol, "MAP_NEW_BARK_ELMS_LAB_1F")
  Assert.deepEqual({
    lab.matrixMemberId,
    lab.areaDataMemberId,
    lab.scriptsMemberId,
    lab.scriptHeaderMemberId,
    lab.messageMemberId,
    lab.eventMemberId,
  }, { 100, 25, 843, 616, 543, 58 })
end

function T.map_compat_identities_are_source_exact()
  local town = maps.byId[60]
  local lab = maps.byId[61]
  Assert.equal(town.mapSection, "NEW_BARK_TOWN")
  Assert.equal(town.mapSectionNativeId, 126)
  Assert.equal(town.followMode, "ALLOW")
  Assert.equal(lab.mapSection, "NEW_BARK_TOWN")
  Assert.equal(lab.mapSectionNativeId, 126)
  Assert.equal(lab.followMode, "HEIGHT_RESTRICT")
  for id = 0, 539 do
    local record = assert(maps.byId[id])
    Assert.isTrue(
      type(record.mapSectionNativeId) == "number"
        and record.mapSectionNativeId % 1 == 0
        and record.mapSectionNativeId >= 0,
      "map " .. id .. " carries an exact native map-section identity"
    )
    Assert.isTrue(
      record.followMode == "ALLOW" or record.followMode == "HEIGHT_RESTRICT" or record.followMode == "PREVENT",
      "map " .. id .. " carries a source follow mode"
    )
  end
end

-- The five signpost window commands (MAPSIGNCOMMAND_*) are the source-faithful
-- command contract opcodes 57/58 decode: exactly 0..4, complete, and uniquely
-- named. The catalog encodes each code's source name and its semantic command
-- explicitly (never a runtime prefix-strip), and semanticName resolves the
-- exact mapping. The corpus and std_signpost scripts carry real command
-- values, so the mapping is pinned here once.
function T.signpost_command_constants_are_complete()
  Assert.equal(signpostCommands.schema, 1)
  local expected = {
    { 0, "MAPSIGNCOMMAND_NOP", "nop" },
    { 1, "MAPSIGNCOMMAND_SHOW", "show" },
    { 2, "MAPSIGNCOMMAND_WIPE_OUT", "wipe_out" },
    { 3, "MAPSIGNCOMMAND_WIPE_IN", "wipe_in" },
    { 4, "MAPSIGNCOMMAND_HIDE", "hide" },
  }
  local seen = {}
  for _, entry in ipairs(expected) do
    local record = assert(signpostCommands.byCode[entry[1]], "command " .. entry[1] .. " recorded")
    Assert.equal(record.sourceName, entry[2])
    Assert.equal(record.semantic, entry[3])
    Assert.equal(signpostCommands.semanticName(entry[1]), entry[3])
    Assert.isNil(seen[record.sourceName])
    seen[record.sourceName] = true
  end
  local count = 0
  for _ in pairs(signpostCommands.byCode) do
    count = count + 1
  end
  Assert.equal(count, 5)
  Assert.isNil(signpostCommands.semanticName(5), "a code outside the pinned 0..4 range resolves to nothing")
  Assert.isNil(signpostCommands.semanticName("2"), "a non-numeric code resolves to nothing")
end

function T.player_avatar_transition_order_covers_all_supported_visual_bits()
  Assert.deepEqual(playerAvatar.transitionOrder, {
    "walking",
    "cycling",
    "surfing",
    "watering",
    "fishing",
    "poketch",
    "saving",
    "heal",
    "ladder",
    "rocket",
    "rocket_heal",
    "pokeathlon",
    "apricorn_shake",
    "rocket_saving",
  })
end

function T.player_avatar_visual_states_cover_both_genders()
  Assert.deepEqual(playerAvatar.visualStates, {
    "walking",
    "cycling",
    "surfing",
    "watering",
    "fishing",
    "poketch",
    "saving",
    "heal",
    "ladder",
    "rocket",
    "rocket_heal",
    "pokeathlon",
    "apricorn_shake",
    "rocket_saving",
  })
  Assert.deepEqual(playerAvatar.durableStates, {
    walking = true,
    cycling = true,
    surfing = true,
    rocket = true,
  })
  local visualSet = {}
  for _, state in ipairs(playerAvatar.visualStates) do
    visualSet[state] = true
  end
  for _, gender in ipairs({ 0, 1 }) do
    local states = playerAvatar.statesForGender(gender)
    local count = 0
    for state, spriteId in pairs(states) do
      count = count + 1
      Assert.isTrue(visualSet[state] == true, "gender " .. gender .. " state " .. state .. " is a known visual")
      Assert.isTrue(
        type(spriteId) == "number" and spriteId >= 0 and spriteId % 1 == 0,
        "gender " .. gender .. " state " .. state .. " selects a compiled sprite"
      )
    end
    Assert.equal(count, 14, "gender " .. gender .. " maps every visual state")
  end
  Assert.equal(playerAvatar.statesForGender(0).walking, 0, "male default visual")
  Assert.equal(playerAvatar.statesForGender(1).walking, 97, "female default visual")
  Assert.equal(playerAvatar.statesForGender(0).heal, 200, "male heal visual")
  Assert.equal(playerAvatar.statesForGender(1).heal, 201, "female heal visual")
  Assert.isTrue(playerAvatar.isDurable("walking"), "walking persists")
  Assert.isFalse(playerAvatar.isDurable("heal"), "heal is temporary")
end

T["producer distinguishes unsupported bit 3 from supported transitions"] = function()
  local transitions, unsupportedBits = playerAvatar.transitionsForMask(0)
  Assert.deepEqual(transitions, {})
  Assert.deepEqual(unsupportedBits, {})

  transitions, unsupportedBits = playerAvatar.transitionsForMask(2 ^ 0 + 2 ^ 8)
  Assert.deepEqual(transitions, { "walking", "heal" })
  Assert.deepEqual(unsupportedBits, {})

  transitions, unsupportedBits = playerAvatar.transitionsForMask(2 ^ 3)
  Assert.deepEqual(transitions, {})
  Assert.deepEqual(unsupportedBits, { 3 })

  transitions, unsupportedBits = playerAvatar.transitionsForMask(2 ^ 0 + 2 ^ 3 + 2 ^ 8)
  Assert.deepEqual(transitions, { "walking", "heal" })
  Assert.deepEqual(unsupportedBits, { 3 })

  transitions, unsupportedBits = playerAvatar.transitionsForMask(2 ^ 15)
  Assert.deepEqual(transitions, {}, "bit 15 queues no transition")
  Assert.deepEqual(unsupportedBits, {}, "bit 15 is ignored, not unsupported")
end

return { tests = T }
