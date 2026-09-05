-- ROM-backed census of the static opcode-76 pattern operands in the field
-- script corpus. The source command passes its second operand to PlayCryEx's
-- cryPattern parameter; variable operands are kept distinct from literals.

local Assert = require("tests.support.Assert")
local FieldScripts = require("tests.rom.support.FieldScripts")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local CORPUS_PATTERNS = { 0, 11, 12 }
local FIXTURE_PATTERNS = { 0, 1, 11, 12 }
local PATTERN_FIXTURES = {
  [0] = "standard_cries_use_the_generic_sequence_and_species_bank",
  [1] = "pattern_1_runs_the_source_twenty_tick_cleanup",
  [11] = "pattern_11_applies_external_pitch_after_standard_admission",
  [12] = "pattern_12_combines_cleanup_with_source_pitch",
}

local function sortedKeys(values)
  local keys = {}
  for value in pairs(values) do
    keys[#keys + 1] = value
  end
  table.sort(keys)
  return keys
end

local function census(romFs)
  local archive, memberIrs = FieldScripts.decode(romFs)
  local literals = {}
  local variables = {}

  for member = 0, archive:memberCount() - 1 do
    local memberIr = memberIrs[member]
    if memberIr ~= nil then
      for scriptIndex, script in pairs(memberIr.scripts) do
        for instructionIndex, instruction in ipairs(script.instructions) do
          if instruction.opcode == 76 then
            local operand = instruction.operands[2]
            Assert.notNil(
              operand,
              ("opcode 76 at member %d script %d instruction %d has no second operand"):format(
                member,
                scriptIndex,
                instructionIndex
              )
            )
            local value = operand.raw
            if type(value) == "number" then
              literals[value] = true
            else
              variables[#variables + 1] = ("member %d script %d instruction %d = %s"):format(
                member,
                scriptIndex,
                instructionIndex,
                tostring(value)
              )
            end
          end
        end
      end
    end
  end

  return literals, variables
end

function T.opcode_76_static_patterns_match_the_hgss_corpus_and_have_fixtures(romFs)
  local literals, variables = census(romFs)
  Assert.equal(
    #variables,
    0,
    "opcode 76 has variable second operands; the static literal census is incomplete and requires source tracing: "
      .. table.concat(variables, ", ")
  )

  local observed = sortedKeys(literals)
  Assert.deepEqual(
    observed,
    CORPUS_PATTERNS,
    "the supplied field-script corpus uses exactly patterns 0, 11, and 12; observed " .. table.concat(observed, ",")
  )

  local cryPlayer = require("libs.hgss.tests.audio.cry_player_test")
  local fixtures = cryPlayer.tests or cryPlayer
  for _, pattern in ipairs(FIXTURE_PATTERNS) do
    local fixture = PATTERN_FIXTURES[pattern]
    Assert.notNil(fixture, "cry pattern " .. tostring(pattern) .. " has no behavior fixture mapping")
    Assert.equal(
      type(fixtures[fixture]),
      "function",
      "cry pattern " .. tostring(pattern) .. " must link to CryPlayer fixture " .. fixture
    )
  end

  for _, pattern in ipairs(observed) do
    Assert.notNil(PATTERN_FIXTURES[pattern], "observed opcode-76 pattern " .. tostring(pattern) .. " has no fixture")
  end
end

return RomSuite.fromFacts(T)
