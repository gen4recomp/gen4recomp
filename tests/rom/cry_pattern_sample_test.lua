-- Bounded cry-pattern sample: one known static opcode-76 callsite for each
-- currently observed literal pattern (0, 11, 12) is decoded through the
-- explicit-member helper and must still carry its expected static operand.
-- The callsites below were recorded once from the whole-corpus census; they
-- are literal test data, never discovered at runtime. This is the fast
-- analogue of the closed-pattern-set census, not corpus evidence: it asserts
-- nothing about patterns outside the sample.

local Assert = require("tests.support.Assert")
local FieldScripts = require("tests.rom.support.FieldScripts")

local T = {}

-- One recorded static callsite per observed literal pattern.
local CALLSITES = {
  { member = 10, scriptIndex = 2, expectedPattern = 0 },
  { member = 251, scriptIndex = 2, expectedPattern = 11 },
  { member = 66, scriptIndex = 0, expectedPattern = 12 },
}

function T.recorded_cry_callsites_keep_their_static_pattern(romFs)
  local memberIds = {}
  local seenMember = {}
  for _, site in ipairs(CALLSITES) do
    if not seenMember[site.member] then
      seenMember[site.member] = true
      memberIds[#memberIds + 1] = site.member
    end
  end
  local archive, memberIrs = FieldScripts.decodeMembers(romFs, memberIds)
  for _, site in ipairs(CALLSITES) do
    local ir = assert(
      memberIrs[site.member],
      "member " .. site.member .. " decodes for the pattern-" .. site.expectedPattern .. " callsite"
    )
    local script =
      assert(ir.scripts[site.scriptIndex], "member " .. site.member .. " still carries script " .. site.scriptIndex)
    local patterns = {}
    for instructionIndex, instruction in ipairs(script.instructions) do
      if instruction.opcode == 76 then
        local operand = assert(
          instruction.operands[2],
          ("member %d script %d instruction %d carries the pattern operand"):format(
            site.member,
            site.scriptIndex,
            instructionIndex
          )
        )
        Assert.equal(
          type(operand.raw),
          "number",
          ("member %d script %d instruction %d keeps a static pattern"):format(
            site.member,
            site.scriptIndex,
            instructionIndex
          )
        )
        patterns[#patterns + 1] = operand.raw
      end
    end
    Assert.isTrue(
      #patterns > 0,
      "member " .. site.member .. " script " .. site.scriptIndex .. " reaches the cry command"
    )
    local matched = false
    for _, pattern in ipairs(patterns) do
      if pattern == site.expectedPattern then
        matched = true
      end
    end
    Assert.isTrue(
      matched,
      "member " .. site.member .. " script " .. site.scriptIndex .. " still uses pattern " .. site.expectedPattern
    )
  end
  Assert.notNil(archive, "the subset decode returns its archive")
end

return require("tests.rom.support.RomSuite").fromFacts(T)
