-- Opcode 621 lowers to the zero-operand starter-ball semantic operation.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")

local T = {}

function T.command_is_supported_with_zero_operands_and_same_tick_timing()
  Assert.equal(CommandCatalog.disposition(621), "supported")
  Assert.equal(CommandCatalog.classification(621), CommandCatalog.CONTINUE)
  Assert.deepEqual(CommandCatalog.widths(621), {})
end

function T.command_lowers_without_source_opcode_runtime_operands()
  local lowered = SemanticLowering.lowerScript(
    { instructions = { { opcode = 621, operands = {}, offset = 0 } } },
    { member = 12, scripts = {}, movements = {} },
    { stdCatalog = SourceCatalog.catalog() }
  )
  Assert.equal(#lowered.items, 1)
  Assert.equal(lowered.items[1].op, "place_starter_balls")
  Assert.isNil(lowered.items[1].command)
end

return { tests = T }
