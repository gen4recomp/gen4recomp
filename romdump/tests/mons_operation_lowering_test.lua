-- Lowering coverage for the mon/party operations: source operands become
-- semantic DSL values with the observed source order (several query
-- commands carry the result first), native identities ride through for
-- the service to resolve once, and deferred loan commands lower to
-- explicit unsupported nodes.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")
local ScriptCommands = require("romdump.src.reference.hgss.script_commands")

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

function T.result_first_queries_keep_the_source_order()
  local hasMove = lowerSingle(140, { 0x800C, 29, 0x8000 })
  Assert.equal(hasMove.op, "mon_has_move")
  Assert.deepEqual(hasMove.result, { value = "var", id = 0x800C })
  Assert.equal(hasMove.move, 29)
  Assert.deepEqual(hasMove.slot, { value = "var", id = 0x8000 })

  local slotWithMove = lowerSingle(141, { 0x800C, 15 })
  Assert.equal(slotWithMove.op, "party_slot_with_move")
  Assert.deepEqual(slotWithMove.result, { value = "var", id = 0x800C })

  local alive = lowerSingle(357, { 0x8005, 6 })
  Assert.equal(alive.op, "count_alive_mons")
  Assert.deepEqual(alive.result, { value = "var", id = 0x8005 })
  Assert.equal(alive.excludeSlot, 6, "the party size excludes nothing")

  local friendship = lowerSingle(382, { 0x800C, 0x8000 })
  Assert.equal(friendship.op, "party_mon_friendship")
  Assert.deepEqual(friendship.result, { value = "var", id = 0x800C })

  local count = lowerSingle(396, { 0x800C, 0x8000 })
  Assert.equal(count.op, "count_mon_moves")
  Assert.deepEqual(count.result, { value = "var", id = 0x800C })

  local move = lowerSingle(398, { 0x800C, 0x8000, 0x8002 })
  Assert.equal(move.op, "mon_get_move")
  Assert.deepEqual(move.result, { value = "var", id = 0x800C })

  local species = lowerSingle(647, { 0x8000, 479 })
  Assert.equal(species.op, "party_slot_with_species")
  Assert.deepEqual(species.result, { value = "var", id = 0x8000 })
  Assert.equal(species.species, 479)
end

function T.direct_mon_commands_keep_their_source_operand_order()
  for _, opcode in ipairs({ 497, 535, 659, 701 }) do
    local entry = assert(ScriptCommands.byOpcode[opcode])
    Assert.equal(entry.feature, "mons")
    Assert.equal(entry.disposition, "supported")
    Assert.equal(entry.classification, "continue_same_tick")
  end

  local types = lowerSingle(497, { 0x8001, 0x8002, 0x8000 })
  Assert.equal(types.op, "party_mon_types")
  Assert.deepEqual(types.type1, { value = "var", id = 0x8001 })
  Assert.deepEqual(types.type2, { value = "var", id = 0x8002 })
  Assert.deepEqual(types.slot, { value = "var", id = 0x8000 })

  local level = lowerSingle(535, { 0x8001, 0x8000 })
  Assert.equal(level.op, "party_mon_level")
  Assert.deepEqual(level.result, { value = "var", id = 0x8001 })
  Assert.deepEqual(level.slot, { value = "var", id = 0x8000 })

  local form = lowerSingle(659, { 0x8000, 0x8001 })
  Assert.equal(form.op, "set_mon_form")
  Assert.deepEqual(form.slot, { value = "var", id = 0x8000 })
  Assert.deepEqual(form.form, { value = "var", id = 0x8001 })

  local item = lowerSingle(701, { 0x8000, 0x8001 })
  Assert.equal(item.op, "party_has_held_item")
  Assert.deepEqual(item.item, { value = "var", id = 0x8000 })
  Assert.deepEqual(item.result, { value = "var", id = 0x8001 })
end

function T.amount_first_friendship_keeps_the_source_order()
  local add = lowerSingle(383, { 10, 0x8004 })
  Assert.equal(add.op, "mon_add_friendship")
  Assert.equal(add.amount, 10, "the amount comes first")
  Assert.deepEqual(add.slot, { value = "var", id = 0x8004 })
end

function T.gift_ability_sentinels_keep_the_default_ability()
  local zero = lowerSingle(137, { 152, 5, 0, 0, 0, 0x800C })
  Assert.equal(zero.op, "give_mon")
  Assert.isNil(zero.ability, "zero keeps the PID-selected ability")
  local bits = lowerSingle(137, { 152, 5, 0, 0, 0xFFFF, 0x800C })
  Assert.isNil(bits.ability, "all-bits keeps the PID-selected ability")
  local named = lowerSingle(137, { 487, 1, 112, 1, 26, 0x800C })
  Assert.equal(named.ability, 26, "a nonzero ability rides through as a native identity")
  Assert.equal(named.heldItem, 112)
  Assert.equal(named.form, 1)
end

function T.contest_selector_rides_as_a_raw_immediate_byte()
  -- ScrCmd_MonAddContestValue (828) reads slot and modifier as variables
  -- but the contest selector as a raw byte (ScriptReadByte): the lowered
  -- node must carry the selector as an immediate number, never as a
  -- variable reference.
  local add = lowerSingle(828, { 0x8000, 3, 0x8001 })
  Assert.equal(add.op, "mon_add_contest_value")
  Assert.deepEqual(add.slot, { value = "var", id = 0x8000 })
  Assert.equal(add.contestType, 3, "the selector is an immediate byte")
  Assert.deepEqual(add.amount, { value = "var", id = 0x8001 })
  local widths = assert(ScriptCommands.byOpcode[828]).widths
  Assert.equal(widths[2], 1, "the selector operand stays one byte wide")
end

function T.loan_give_and_check_defer_to_the_trade_application()
  for _, opcode in ipairs({ 362, 363 }) do
    local tagged = assert(ScriptCommands.byOpcode[opcode])
    Assert.equal(tagged.disposition, "deferred")
    Assert.equal(tagged.deferredReason, "trade")
    local node = lowerSingle(opcode, { 6, 20, 75 })
    Assert.equal(node.op, "unsupported")
    Assert.equal(node.command, opcode)
  end
  local remove = lowerSingle(364, { 0x8000 })
  Assert.equal(remove.op, "return_loan_mon", "removal stays a real semantic operation")
end

return { tests = T }
