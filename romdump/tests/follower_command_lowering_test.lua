-- Lowering coverage for the follower commands: movement/pause/wait and
-- the partner-state/event operations lower to real semantic nodes rather
-- than explicit unsupported fallbacks, and the active-state query carries
-- its result variable into a live controller read instead of a constant.

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

function T.follower_movement_commands_lower_to_real_semantics()
  local face = lowerSingle(601, {})
  Assert.isTrue(face.op ~= "unsupported", "face-player must lower to controller semantics")
  local toggle = lowerSingle(602, { 0 })
  Assert.isTrue(toggle.op ~= "unsupported", "movement pause/unpause must lower to controller semantics")
  local wait = lowerSingle(603, {})
  Assert.isTrue(wait.op ~= "unsupported", "movement wait must lower to controller settlement")
  local advance = lowerSingle(604, { 0 })
  Assert.isTrue(advance.op ~= "unsupported", "explicit follower movement must lower to controller semantics")
  local partnerState = lowerSingle(596, { 0 })
  Assert.isTrue(partnerState.op ~= "unsupported", "the partner-state query must lower to controller semantics")
  local trigger = lowerSingle(698, { 0, 0, 0 })
  Assert.isTrue(trigger.op ~= "unsupported", "the event-trigger check must lower to controller semantics")
end

function T.follower_active_query_reads_live_controller_state()
  local active = lowerSingle(729, { 0x800C })
  Assert.equal(active.op, "follower_is_active", "the active query must read live follower state")
  Assert.deepEqual(active.result, { value = "var", id = 0x800C }, "the source result variable rides through")
end

function T.follower_transition_command_lowers_to_a_no_operand_same_tick_node()
  Assert.equal(CommandCatalog.disposition(608), "supported", "the transition command must be supported")
  Assert.equal(
    CommandCatalog.classification(608),
    CommandCatalog.CONTINUE,
    "the transition command must continue in the same tick"
  )
  Assert.deepEqual(CommandCatalog.widths(608), {}, "the transition command carries no operands")
  local node = lowerSingle(608, {})
  Assert.equal(node.op, "follower_transition", "the transition must lower to transition semantics")
  Assert.isNil(node.command, "transition semantics dispatch no source opcode number")
end

return { tests = T }
