-- Translation-verifier unit tests: the classification checks that pin the
-- caller-signal fallthrough protocol (opcode 21) and the surrounding
-- stop/continue accounting on synthetic members. No ROM and no decomp
-- checkout required.

local Assert = require("tests.support.Assert")
local ScriptFixture = require("tests.support.ScriptFixture")
local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local Structurer = require("romdump.src.digest.script.Structurer")
local Verifier = require("romdump.src.digest.script.Verifier")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")

local T = {}

local CATALOG = {
  sounds = {},
  flags = {},
  vars = {},
  maps = {},
}

local function verify(bytes)
  local ir = assert(ScriptBinaryDecoder.parseMember(bytes, 5, "synthetic", { msgBank = 543, catalog = CATALOG }))
  local lowered = SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
  local steps = Structurer.structure(lowered, 0)
  local report = Verifier.verifyScript(steps, ir.scripts[0], ir, lowered.omissions)
  return steps, report
end

-- The catalog itself owns the same-tick fallthrough classification.
function T.opcode_21_is_continue_classified_in_the_catalog()
  Assert.equal(CommandCatalog.classification(21), CommandCatalog.CONTINUE)
  Assert.equal(CommandCatalog.name(21), "ScrCmd_RestartCurrentScript")
end

-- A signal followed by End remains a complete translation while the signal
-- itself is classified as ordinary same-tick fallthrough.
function T.signal_caller_fallthrough_verifies_as_complete_translation()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 21, args = {} },
          { op = 2, args = {} },
        },
      },
    },
  })
  local _, report = verify(bytes)
  Assert.isTrue(report.ok, report.problems[1] and report.problems[1].message or "signal_caller must verify")
  Assert.isTrue(report.complete)
end

-- The post-signal instructions of a context are ordinary covered source:
-- the verifier treats them as reachable fallthrough material and requires
-- them to stay covered, exactly like any other instruction.
function T.post_signal_instructions_stay_covered()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 21, args = {} },
          { op = 30, args = { { value = 3, width = 2 } } },
          { op = 2, args = {} },
        },
      },
    },
  })
  local _, report = verify(bytes)
  Assert.isTrue(report.ok, report.problems[1] and report.problems[1].message or "post-signal code must verify")
  Assert.isTrue(report.complete)
end

return { tests = T }
