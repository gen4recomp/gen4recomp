-- Lowering coverage for the generic Bag/item script protocol: inventory
-- primitives lower to result-writing semantic nodes with the observed source
-- operand order (item, quantity, result last; single-item queries carry the
-- result second), native identities ride through for the service to resolve
-- once through the catalog, and the berry/indefinite/plural text forms lower
-- to exact buffer_text descriptors.

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

function T.inventory_primitives_keep_item_quantity_and_trailing_result()
  for _, row in ipairs({
    { opcode = 125, op = "bag_add_item" },
    { opcode = 126, op = "bag_take_item" },
    { opcode = 127, op = "bag_has_space" },
    { opcode = 128, op = "bag_has_item" },
  }) do
    local node = lowerSingle(row.opcode, { 23, 1, 0x800D })
    Assert.equal(node.op, row.op)
    Assert.equal(node.item, 23, "the native item identity rides through for the service")
    Assert.equal(node.quantity, 1)
    Assert.deepEqual(node.result, { value = "var", id = 0x800D }, "the result stays a trailing variable write")
  end
end

function T.single_item_queries_carry_the_result_second()
  local tmhm = lowerSingle(129, { 328, 0x800D })
  Assert.equal(tmhm.op, "item_is_tmhm")
  Assert.equal(tmhm.item, 328)
  Assert.deepEqual(tmhm.result, { value = "var", id = 0x800D })

  local pocket = lowerSingle(130, { 23, 0x800D })
  Assert.equal(pocket.op, "item_get_pocket")
  Assert.equal(pocket.item, 23)
  Assert.deepEqual(pocket.result, { value = "var", id = 0x800D })

  local quantity = lowerSingle(669, { 23, 0x800D })
  Assert.equal(quantity.op, "bag_get_quantity")
  Assert.equal(quantity.item, 23)
  Assert.deepEqual(quantity.result, { value = "var", id = 0x800D })
end

function T.berry_text_carries_item_and_quantity_references()
  local berry = lowerSingle(336, { 1, 149, 0x800E })
  Assert.equal(berry.op, "buffer_text")
  Assert.equal(berry.slot, 1)
  Assert.equal(berry.value.text, "berry_name")
  Assert.equal(berry.value.item, 149, "the native berry identity rides through for the catalog")
  Assert.deepEqual(berry.value.quantity, { value = "var", id = 0x800E }, "the quantity stays a variable reference")
end

function T.indefinite_and_plural_text_carry_the_item_reference()
  local indefinite = lowerSingle(843, { 2, 23 })
  Assert.equal(indefinite.op, "buffer_text")
  Assert.equal(indefinite.slot, 2)
  Assert.deepEqual(indefinite.value, { text = "item_name_indefinite", value = 23 })

  local plural = lowerSingle(844, { 2, 23 })
  Assert.equal(plural.op, "buffer_text")
  Assert.equal(plural.slot, 2)
  Assert.deepEqual(plural.value, { text = "item_name_plural", value = 23 })
end

function T.item_buffers_already_lower_without_source_opcode_operands()
  local itemName = lowerSingle(194, { 1, 0x8004 })
  Assert.equal(itemName.op, "buffer_text")
  Assert.deepEqual(itemName.value, { text = "item_name", value = { value = "var", id = 0x8004 } })
  Assert.isNil(itemName.command, "item text dispatches on the semantic name only")

  local pocketName = lowerSingle(195, { 2, 0x800D })
  Assert.deepEqual(pocketName.value, { text = "pocket_name", value = { value = "var", id = 0x800D } })

  local moveName = lowerSingle(196, { 3, 0x8004 })
  Assert.deepEqual(moveName.value, { text = "tmhm_move_name", value = { value = "var", id = 0x8004 } })
end

function T.owned_commands_carry_the_item_feature_and_same_tick_timing()
  for _, opcode in ipairs({ 125, 126, 127, 128, 129, 130, 194, 195, 196, 336, 669, 843, 844 }) do
    local entry = assert(ScriptCommands.byOpcode[opcode], "the catalog names opcode " .. opcode)
    Assert.equal(entry.feature, "items", "opcode " .. opcode .. " belongs to the item protocol")
    Assert.equal(entry.disposition, "supported", "opcode " .. opcode .. " is supported here")
    Assert.equal(entry.classification, "continue_same_tick", "opcode " .. opcode .. " keeps its source timing")
  end
end

return { tests = T }
