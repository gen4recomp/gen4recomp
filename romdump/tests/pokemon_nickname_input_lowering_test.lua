-- Opcode 173 lowers to the blocking Pokemon nickname semantic operation.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")

local function lower(operands)
  local widths = assert(CommandCatalog.widths(173))
  local raw = {}
  for index = 1, #widths do
    raw[index] = operands[index] or 0
  end
  return SemanticLowering.lowerScript(
    { instructions = { { opcode = 173, operands = raw, offset = 0x42 } } },
    { member = 12, scripts = {}, movements = {} },
    { stdCatalog = SourceCatalog.catalog() }
  )
end

local tests = {}

function tests.opcode_lowers_with_value_slot_result_and_provenance()
  local lowered = lower({ 0, 0x800C })
  Assert.equal(#lowered.items, 1)
  local node = lowered.items[1]
  Assert.equal(node.op, "pokemon_nickname_input")
  Assert.equal(node.slot, 0)
  Assert.deepEqual(node.result, { value = "var", id = 0x800C })
  Assert.deepEqual(node.provenance.offsets, { 0x42 })
  Assert.deepEqual(node.provenance.opcodes, { 173 })
  Assert.equal(#lowered.unsupported, 0)
end

return { tests = tests }
