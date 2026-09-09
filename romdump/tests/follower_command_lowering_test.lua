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
  local advance = lowerSingle(604, { 48 })
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

-- Opcode 604 carries a persistent map-object movement selector, not a
-- one-shot movement-script command: raw 55 selects the Elm transition
-- controller, so it must lower to that semantic mode rather than the
-- unrelated near/fast jump the movement-script namespace decodes it to.
function T.follower_movement_type_55_lowers_to_a_transition_mode_not_a_jump()
  local node = lowerSingle(604, { 55 })
  Assert.equal(node.op, "follower_set_movement_type", "604 must lower to the persistent mode setter")
  Assert.equal(node.movementType, "follow_transition_a", "raw 55 must keep its transition identity")
  Assert.isNil(node.movement, "a movement mode carries no decoded movement action")
  Assert.isNil(node.action, "a movement mode is state, not a movement task")
  Assert.isNil(node.direction, "a movement mode carries no direction")
  Assert.isNil(node.distance, "a movement mode carries no jump distance")
  Assert.isNil(node.speed, "a movement mode carries no speed")
  Assert.isNil(node.count, "a movement mode carries no repetition count")
end

-- The three source-observed follower modes keep their exact semantic
-- identity through lowering; runtime never sees the raw selectors.
function T.follower_movement_modes_preserve_semantic_identity()
  local cases = {
    [48] = "follow_player",
    [55] = "follow_transition_a",
    [56] = "follow_transition_b",
  }
  for raw, expected in pairs(cases) do
    local node = lowerSingle(604, { raw })
    Assert.equal(node.op, "follower_set_movement_type", "raw " .. raw .. " must lower to the mode setter")
    Assert.equal(node.movementType, expected, "raw " .. raw .. " must keep its semantic identity")
  end
end

-- A 604 selector outside the follower trio is malformed source for this
-- opcode: it takes the attributed unsupported-source path rather than
-- silently defaulting or being reinterpreted as a movement action.
function T.non_follower_selector_is_an_attributed_unsupported_source()
  local node = lowerSingle(604, { 0 })
  Assert.equal(node.op, "unsupported", "a stationary selector is not a follower mode")
  Assert.equal(node.command, 604, "the failure stays attributed to opcode 604")
  Assert.deepEqual(node.arguments, { 0 }, "the failure stays attributed to the source value")
  Assert.isNil(node.movementType, "an unsupported selector defaults to no follower mode")
  Assert.isNil(node.movement, "an unsupported selector decodes no movement action")
end

-- Opcode 604 remains a supported same-tick command under the mode contract.
function T.follower_movement_mode_command_stays_supported_same_tick()
  Assert.equal(CommandCatalog.disposition(604), "supported", "the movement-mode command must be supported")
  Assert.equal(
    CommandCatalog.classification(604),
    CommandCatalog.CONTINUE,
    "the movement-mode command must continue in the same tick"
  )
  Assert.deepEqual(CommandCatalog.widths(604), { [1] = 2 }, "the movement-mode command carries one halfword")
end

return { tests = T }
