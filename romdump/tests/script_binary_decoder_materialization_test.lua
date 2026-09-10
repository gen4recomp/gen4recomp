-- Decoder allocation contract: discovery may revisit a member, but final
-- RawIr is materialized once after the discovery counters reach a fixpoint.

local Assert = require("tests.support.Assert")
local ScriptFixture = require("tests.support.ScriptFixture")
local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")

local T = {}

local CATALOG = {
  sounds = { [1500] = "SEQ_SE_DP_SELECT" },
  flags = { [0x6A] = "FLAG_GOT_STARTER" },
  vars = { [0x4000] = "VAR_TEMP_x4000", [0x8008] = "VAR_SPECIAL_x8008" },
  maps = { [61] = { mapCode = "MAP_NEW_BARK_ELMS_LAB_1F" } },
}

function T.discovery_revisits_without_rebuilding_final_ir()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 94, args = { { value = 0, width = 2 }, { target = 0x30, width = 4 } } },
          { op = 95, args = {} },
          { op = 2, args = {} },
        },
      },
    },
    movements = {
      {
        offset = 0x30,
        actions = {
          { code = 12, args = { 2 } },
          { code = 254, args = { 0 } },
        },
      },
    },
  })
  local stats = { materializations = 0, discoveryPasses = 0, finalInstructionRecords = 0 }
  local member = assert(ScriptBinaryDecoder.parseMember(bytes, 5, "synthetic", {
    msgBank = 543,
    catalog = CATALOG,
    instrumentation = stats,
  }))

  Assert.equal(stats.materializations, 1, "final RawIr must be materialized exactly once")
  Assert.isTrue(stats.discoveryPasses > 1, "the fixture must exercise more than one discovery pass")
  Assert.equal(stats.finalInstructionRecords, 3, "only final instruction records count as materialized IR")
  Assert.equal(#member.scripts[0].instructions, 3, "single materialization must preserve decoder semantics")
  Assert.equal(#member.movements[0x30].actions, 1, "single materialization must preserve movement semantics")
end

return { tests = T }
