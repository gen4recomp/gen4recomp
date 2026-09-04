-- Lowering coverage for the party-screen selection contract: the selection
-- launch and its result reading must lower to real semantic nodes. Opcode
-- 349 opens the shared party screen in selection mode and blocks; the
-- companion result command consumes the selected slot or the source
-- cancellation sentinel. Explicit unsupported nodes here mean the screen
-- contract is still missing.

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

function T.selection_launch_lowers_to_a_real_semantic_node()
  local select = lowerSingle(349, {})
  Assert.isTrue(
    select.op ~= "unsupported",
    "opcode 349 must lower to the party selection semantic, not an explicit unsupported node"
  )
end

function T.selection_result_lowers_to_a_real_semantic_node()
  local result = lowerSingle(351, { 0x800C })
  Assert.isTrue(
    result.op ~= "unsupported",
    "opcode 351 must lower to the party selection result semantic, not an explicit unsupported node"
  )
end

return { tests = T }
