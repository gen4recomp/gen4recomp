-- Deferred commands fail loudly: lowering keeps the source identity and
-- the deferral dependency, and reaching the node at runtime raises a
-- structured error before any party state can change.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local Errors = require("libs.errors.src.Errors")
local Runtime = require("libs.script.src.Runtime")
local ScriptCommands = require("romdump.src.reference.hgss.script_commands")
local ScriptErrors = require("libs.script.src.errors")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")

local T = {}

local function lowerSingle(opcode)
  local widths = CommandCatalog.widths(opcode) or {}
  local operands = {}
  for index = 1, #widths do
    operands[index] = 0
  end
  local lowered = SemanticLowering.lowerScript(
    { instructions = { { opcode = opcode, operands = operands, offset = 16 } } },
    { member = 12, scripts = {}, movements = {} },
    { stdCatalog = SourceCatalog.catalog() }
  )
  Assert.equal(#lowered.items, 1, "the deferred command lowers to one step")
  return lowered.items[1]
end

local function reachError(node)
  local ok, result = pcall(Runtime.executeNode, node, {
    instance = { scriptId = "vanilla.012.0000" },
    services = {},
  })
  Assert.isFalse(ok, "reaching a deferred command must fail")
  local failure = result --[[@as Errors.Error]]
  Assert.isTrue(Errors.is(failure), "the failure uses the structured script-error path")
  return failure
end

function T.egg_command_defers_with_its_dependency_and_fails_at_runtime()
  local tagged = assert(ScriptCommands.byOpcode[138])
  Assert.equal(tagged.disposition, "deferred", "the egg command waits for its owner")
  Assert.equal(tagged.deferredReason, "egg_daycare", "the egg command names its dependency")
  local node = lowerSingle(138)
  Assert.equal(node.op, "unsupported", "the deferred command lowers explicitly")
  Assert.equal(node.command, 138, "the node keeps the source opcode")
  Assert.equal(node.originalName, "ScrCmd_GiveEgg", "the node keeps the source name")
  local failure = reachError(node)
  Assert.equal(failure.code, ScriptErrors.SCRIPT_UNSUPPORTED_REACHABLE, "the runtime names the reach")
  Assert.equal(failure.context.command, 138, "the error names the source command")
end

function T.trade_command_defers_with_its_dependency_and_fails_at_runtime()
  local tagged = assert(ScriptCommands.byOpcode[473])
  Assert.equal(tagged.disposition, "deferred", "the trade command waits for its owner")
  Assert.equal(tagged.deferredReason, "trade", "the trade command names its dependency")
  local node = lowerSingle(473)
  Assert.equal(node.op, "unsupported", "the deferred command lowers explicitly")
  local failure = reachError(node)
  Assert.equal(failure.code, ScriptErrors.SCRIPT_UNSUPPORTED_REACHABLE, "the runtime names the reach")
  Assert.equal(failure.context.command, 473, "the error names the source command")
end

return { tests = T }
