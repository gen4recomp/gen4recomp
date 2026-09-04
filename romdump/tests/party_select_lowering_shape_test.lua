-- Exact lowering for the party-screen selection pair: opcode 349 opens
-- the shared screen in selection mode and blocks, while opcode 351 reads
-- the instance-scoped selection handoff into its result variable.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")

local T = {}

local function lowerSingle(opcode, operands)
  local widths = CommandCatalog.widths(opcode) or {}
  local raw = {}
  for index = 1, #widths do
    raw[index] = operands[index] ~= nil and operands[index] or 0
  end
  local lowered = SemanticLowering.lowerScript(
    { instructions = { { opcode = opcode, operands = raw, offset = 0 } } },
    { member = 12, scripts = {}, movements = {} },
    { stdCatalog = SourceCatalog.catalog() }
  )
  Assert.equal(#lowered.items, 1, "opcode " .. opcode .. " lowers to one step")
  return lowered.items[1]
end

function T.launch_parks_the_outcome_in_the_synthesized_carrier()
  local select = lowerSingle(349, {})
  Assert.deepEqual(select, {
    op = "party_select",
    provenance = select.provenance,
  })
end

function T.result_consumes_the_carrier_into_its_variable()
  local result = lowerSingle(351, { 0x800C })
  Assert.equal(result.op, "party_select_result")
  Assert.deepEqual(result.result, { value = "var", id = 0x800C })
end

return { tests = T }
