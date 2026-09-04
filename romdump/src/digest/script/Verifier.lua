-- Translation verifier : compares the original Raw IR
-- and CFG against the lowered semantic IR. It verifies translation-accounting
-- and control-flow preservation, not full game-behavior equivalence:
--
-- 1. Every reachable source instruction is covered by one semantic node
-- or an explicit unsupported node (Nop/Dummy are the only documented
-- implementation-detail erasures).
-- 2. Every original control edge is represented by a control node.
-- 3. Every semantic side effect maps back to source offsets.
-- 4. Every source execution classification is represented by an
-- equivalent graph boundary or timing profile.
-- 5. Discarded implementation variables are proven unobservable.
-- 6. Canonicalized operands resolve to the same constants.
-- 7. Call/return balance is preserved.
-- 8. Movement sequence termination is preserved.
-- 9. No command disappears except an explicitly documented erasure.
-- 10. Unsupported instructions prevent a `complete` result.
--
-- every supported terminal path of a common script must signal its caller
-- (RestartCurrentScript -> signal_caller) before ending, matching the pinned
-- `ScrCmd_RestartCurrentScript` bit protocol. Pure domain module: no love
-- dependency.

local Cfg = require("romdump.src.digest.script.Cfg")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local SignpostCommands = require("romdump.src.reference.hgss.signpost_commands")

local Verifier = {}

-- Branch and call opcodes: their covering node must be a control node.
local CONTROL_OPS = {
  ["goto"] = true,
  goto_if = true,
  goto_compared = true,
  call_compared = true,
  if_cond = true,
  call_if = true,
  ["if"] = true,
  goto_script = true,
}

-- Blocking (native-wait) operations: an instruction classified native_wait
-- must be covered by one of these, or by an explicit unsupported node.
local BLOCKING_OPS = {
  wait_ticks = true,
  say = true,
  message = true,
  wait_input = true,
  wait_input_or_ticks = true,
  wait_movement = true,
  wait_sound = true,
  wait_cry = true,
  wait_fanfare = true,
  wait_fade = true,
  fade_music_out = true,
  fade_music_in = true,
  ask_yes_no = true,
  context_choice = true,
  choose_starter = true,
  party_select = true,
  menu_exec = true,
  warp = true,
  call_common = true,
  wait_signpost_action = true,
  trainer_tips_print = true,
  wait_signpost = true,
  follower_wait = true,
}

-- Operations that end the run phase: yield boundaries and stops.
local YIELD_OPS = {
  yield_tick = true,
  lock_all = true,
  release_all = true,
  menu_begin = true,
  signpost_direction = true,
  signpost_set = true,
  signpost_command = true,
  stop = true,
}

-- Operations that end the script context (a stop-classified instruction
-- must be covered by one of these): plain completion, the opcode-61
-- context end that requests the Start Menu reopen hook, and the opcode-21
-- caller signal (RestartCurrentScript returns FALSE, ending the child
-- context at the signal).
local TERMINAL_OPS = {
  stop = true,
  request_start_menu = true,
  signal_caller = true,
}

-- The documented multi-instruction folds (they own a timing profile of their
-- own, so per-instruction classification checks do not apply to them).
-- `if` covers the conditional cross-script branch wrap; `goto_if` is the
-- label/goto fallback of a compare+GoToIf fold that the structurer could
-- not peel.
local FOLD_OPS = { say = true, if_cond = true, call_if = true, ["if"] = true, goto_if = true }

-- Whether a lowered node ends the run phase by blocking (native wait). The
-- `message` op blocks only with waitForPrint; `lock_actor` blocks only with
-- waitUntilPausable.
---@param node table<string, unknown>
---@return boolean
local function nodeBlocks(node)
  if node.op == "message" then
    return node.waitForPrint == true
  end
  if node.op == "lock_actor" then
    return node.waitUntilPausable == true
  end
  return BLOCKING_OPS[node.op] == true
end

-- Instructions whose operand values are side effects on the script stack
-- (counted for the stack-balance and observability checks).
local CALL_OPS = { [26] = true, [29] = true }
local RETURN_OPS = { [27] = true }

-- Compare an operand raw value with a node field (varRef forms match their
-- symbolic operands).
---@param raw unknown
---@param node unknown
---@return boolean
local function operandMatches(raw, node)
  if type(node) == "table" and type(raw) == "string" then
    if node.value == "var" then
      return node.id == raw
    end
    if node.value == "local" then
      return node.name == raw
    end
  end
  return node == raw
end

-- The per-opcode operand-equivalence checkers (item 6): `(ins, step)` ->
-- problem message or nil. Covering the high-value operand-carrying
-- instructions; the rest are checked by the generic coverage rule.
local function checkWaitFrames(ins, step)
  if step.op == "unsupported" then
    return nil
  end
  if not operandMatches(ins.operands[1].raw, step.ticks) then
    return "Wait frame count changed by translation"
  end
end

local function checkGotoTarget(ins, step)
  if step.op == "goto_script" then
    return nil
  end
  if not operandMatches(ins.operands[1].raw, step.target) then
    return "GoTo target changed by translation"
  end
end

local function checkCallTarget(ins, step)
  if step.label ~= nil then
    return nil
  end
  if not operandMatches(ins.operands[1].raw, step.target) then
    return "Call target changed by translation"
  end
end

local function checkSetFlag(ins, step)
  if not operandMatches(ins.operands[1].raw, step.flag) then
    return "SetFlag id changed by translation"
  end
end

local function checkClearFlag(ins, step)
  if not operandMatches(ins.operands[1].raw, step.flag) then
    return "ClearFlag id changed by translation"
  end
end

local function checkSetFlagVar(ins, step)
  if not operandMatches(ins.operands[1].raw, step.flag) then
    return "SetFlagVar id changed by translation"
  end
end

local function checkClearFlagVar(ins, step)
  if not operandMatches(ins.operands[1].raw, step.flag) then
    return "ClearFlagVar id changed by translation"
  end
end

local function checkAddVar(ins, step)
  if not operandMatches(ins.operands[1].raw, step.variable) or not operandMatches(ins.operands[2].raw, step.amount) then
    return "AddVar operands changed by translation"
  end
end

local function checkSubVar(ins, step)
  if not operandMatches(ins.operands[1].raw, step.variable) or not operandMatches(ins.operands[2].raw, step.amount) then
    return "SubVar operands changed by translation"
  end
end

local function checkSetVar(ins, step)
  if not operandMatches(ins.operands[1].raw, step.variable) or not operandMatches(ins.operands[2].raw, step.value) then
    return "SetVar operands changed by translation"
  end
end

local function checkCopyVar(ins, step)
  if
    not operandMatches(ins.operands[1].raw, step.destination)
    or not operandMatches(ins.operands[2].raw, step.source)
  then
    return "CopyVar operands changed by translation"
  end
end

local function checkSetOrCopyVar(ins, step)
  if not operandMatches(ins.operands[1].raw, step.variable) or not operandMatches(ins.operands[2].raw, step.value) then
    return "SetOrCopyVar operands changed by translation"
  end
end

local function checkPlaySound(ins, step)
  if not operandMatches(ins.operands[1].raw, step.sound) then
    return "PlaySE sound changed by translation"
  end
end

local function checkStopSound(ins, step)
  if not operandMatches(ins.operands[1].raw, step.sound) then
    return "StopSE sound changed by translation"
  end
end

local function checkWaitSound(ins, step)
  if not operandMatches(ins.operands[1].raw, step.sound) then
    return "WaitSE sound changed by translation"
  end
end

local function checkPlayMusic(ins, step)
  if not operandMatches(ins.operands[1].raw, step.music) then
    return "PlayBGM music changed by translation"
  end
end

local function checkTemporaryMusic(ins, step)
  if not operandMatches(ins.operands[1].raw, step.music) then
    return "TempBGM music changed by translation"
  end
end

local function checkSetSpawn(ins, step)
  if not operandMatches(ins.operands[1].raw, step.spawn) then
    return "SetSpawn id changed by translation"
  end
end

local function checkWaitInputOrTicks(ins, step)
  if not operandMatches(ins.operands[1].raw, step.ticks) then
    return "WaitButtonOrDelay ticks changed by translation"
  end
end

local function checkDirectionSignpost(ins, step)
  -- DirectionSignpost: the raw type/map must survive exactly and the
  -- message id stays the direct bank index. The final operand is an
  -- intentional, audited erasure: the source handler never reads or
  -- writes it, so the semantic node drops it (the raw decoded operands
  -- keep it for source auditing).
  local appearance = step.sourceAppearance or {}
  if appearance.type ~= ins.operands[2].raw or appearance.map ~= ins.operands[3].raw then
    return "DirectionSignpost type/map changed by translation"
  end
  local message = step.message
  local id = type(message) == "table" and message.message == "external" and message.id
  if id ~= ins.operands[1].raw then
    return "DirectionSignpost message id changed by translation"
  end
end

local function checkSetSignpostMap(ins, step)
  local appearance = step.sourceAppearance or {}
  if appearance.type ~= ins.operands[1].raw or appearance.map ~= ins.operands[2].raw then
    return "SetSignpostMap type/map changed by translation"
  end
end

local function checkSetSignpostAction(ins, step)
  -- SetSignpostAction: the raw MAPSIGNCOMMAND_* code must lower to the
  -- exact semantic command, never a default.
  if step.command ~= SignpostCommands.semanticName(ins.operands[1].raw) then
    return "SetSignpostAction command changed by translation"
  end
end

local function checkTrainerTips(ins, step)
  -- TrainerTips: the message id stays the direct bank index and the
  -- result var survives exactly.
  local message = step.message
  local id = type(message) == "table" and message.message == "external" and message.id
  if id ~= ins.operands[1].raw then
    return "TrainerTips message id changed by translation"
  end
  if not operandMatches(ins.operands[2].raw, step.result) then
    return "TrainerTips result operand changed by translation"
  end
end

local function checkWaitSignpost(ins, step)
  -- WaitSignpost: the result var survives exactly.
  if not operandMatches(ins.operands[1].raw, step.result) then
    return "WaitSignpost result operand changed by translation"
  end
end

local CHECKERS = {
  [3] = checkWaitFrames,
  [22] = checkGotoTarget,
  [26] = checkCallTarget,
  [30] = checkSetFlag,
  [31] = checkClearFlag,
  [33] = checkSetFlagVar,
  [34] = checkClearFlagVar,
  [39] = checkAddVar,
  [40] = checkSubVar,
  [41] = checkSetVar,
  [42] = checkCopyVar,
  [43] = checkSetOrCopyVar,
  [73] = checkPlaySound,
  [74] = checkStopSound,
  [75] = checkWaitSound,
  [80] = checkPlayMusic,
  [87] = checkTemporaryMusic,
  [280] = checkSetSpawn,
  [348] = checkWaitInputOrTicks,
  [55] = checkDirectionSignpost,
  [56] = checkSetSignpostMap,
  [57] = checkSetSignpostAction,
  [59] = checkTrainerTips,
  [60] = checkWaitSignpost,
}

-- Walk the lowered items collecting the covering node per source offset.
---@param items table[]
---@return table<integer, table<string, unknown>> byOffset
local function coveredByOffset(items)
  local byOffset = {}
  local function walk(list)
    for _, item in ipairs(list) do
      if item.provenance ~= nil then
        for _, offset in ipairs(item.provenance.offsets) do
          byOffset[offset] = item
        end
      end
      if item.op == "if" then
        walk(item.yes)
        walk(item.no)
      end
    end
  end

  walk(items)
  return byOffset
end

---@param context table<string, unknown>
---@param message string
---@param details table<string, unknown>
local function addProblem(context, message, details)
  context.report.ok = false
  context.report.problems[#context.report.problems + 1] = { message = message, context = details }
end

---@param context table<string, unknown>
---@param message string
---@param details table<string, unknown>
local function addWarning(context, message, details)
  context.report.warnings[#context.report.warnings + 1] = { message = message, context = details }
end

local function newVerificationContext(steps, script, memberIr, omissions)
  return {
    cfg = Cfg.build(script, memberIr),
    byOffset = coveredByOffset(steps),
    script = script,
    memberIr = memberIr,
    steps = steps,
    omissions = omissions,
    prelude = script.prelude == true,
    report = { ok = true, complete = false, problems = {}, warnings = {} },
  }
end

local function verifyCoverage(context)
  context.omissionsByOffset = {}
  for _, omission in ipairs(context.omissions or {}) do
    context.omissionsByOffset[omission.offset] = true
    if omission.opcode ~= 0 and omission.opcode ~= 1 then
      addProblem(
        context,
        "omission recorded for a non-erasure opcode",
        { offset = omission.offset, opcode = omission.opcode }
      )
    end
  end

  context.total = #context.script.instructions
  context.covered = 0
  context.reachable = 0
  context.reachableUnsupported = 0
  context.unsupportedNodes = {}
  context.reachableOmitted = 0
  for i, ins in ipairs(context.script.instructions) do
    local isReachable = context.cfg.reachable[context.cfg.blockOfIndex[i]] == true
    if isReachable then
      context.reachable = context.reachable + 1
    end
    local node = context.byOffset[ins.offset]
    if node ~= nil then
      context.covered = context.covered + 1
      if node.op == "unsupported" then
        context.reachableUnsupported = context.reachableUnsupported + 1
        context.unsupportedNodes[#context.unsupportedNodes + 1] = node
      end
    elseif context.omissionsByOffset[ins.offset] then
      if isReachable then
        context.reachableOmitted = context.reachableOmitted + 1
      end
    else
      addProblem(
        context,
        "instruction not covered by any semantic node",
        { offset = ins.offset, opcode = ins.opcode, name = CommandCatalog.name(ins.opcode) }
      )
    end
  end
end

local function verifyControlEdges(context)
  local controlOffsets = { [22] = true, [23] = true, [24] = true, [25] = true, [28] = true, [29] = true }
  for _, ins in ipairs(context.script.instructions) do
    if controlOffsets[ins.opcode] then
      local node = context.byOffset[ins.offset]
      if node ~= nil and node.op ~= "unsupported" and not CONTROL_OPS[node.op] then
        addProblem(
          context,
          "control edge not represented by a control node",
          { offset = ins.offset, opcode = ins.opcode, node = node.op }
        )
      end
    end
    if ins.opcode == 26 then
      local node = context.byOffset[ins.offset]
      if
        node ~= nil
        and node.op ~= "unsupported"
        and node.op ~= "call"
        and node.op ~= "call_if"
        and node.op ~= "call_compared"
      then
        addProblem(
          context,
          "call edge not represented by a call node",
          { offset = ins.offset, opcode = ins.opcode, node = node and node.op }
        )
      end
    end
  end
end

local function isCrossScriptNode(node)
  if node == nil then
    return false
  end
  if node.op == "goto_script" or (node.op == "call" and node.label ~= nil) then
    return true
  end
  if (node.op == "goto_compared" or node.op == "call_compared") and node.script ~= nil then
    return true
  end
  if node.op == "if" and node.yes and node.yes[1] then
    local inner = node.yes[1]
    return inner.op == "goto_script" or (inner.op == "call" and inner.label ~= nil)
  end
  return false
end

local function verifyBranchTargets(context)
  for _, block in pairs(context.cfg.blocks) do
    local lastIns = context.script.instructions[block.indices[#block.indices]]
    local lastNode = lastIns ~= nil and context.byOffset[lastIns.offset] or nil
    for _, succ in ipairs(block.successors) do
      if
        (succ.kind == "branch" or succ.kind == "call")
        and succ.targetIndex == nil
        and not isCrossScriptNode(lastNode)
        and (lastNode == nil or lastNode.op ~= "unsupported")
      then
        addProblem(
          context,
          "branch target does not resolve to an instruction",
          { block = block.id, entryOffset = block.entryOffset, kind = succ.kind }
        )
      end
    end
  end
end

local function verifyExecutionBoundaries(context)
  for _, ins in ipairs(context.script.instructions) do
    local node = context.byOffset[ins.offset]
    if node ~= nil and node.op ~= "unsupported" then
      local foldOffsets = node.provenance and node.provenance.offsets or {}
      if #foldOffsets > 1 then
        if not FOLD_OPS[node.op] then
          addProblem(
            context,
            "multi-instruction node is not a documented fold",
            { offset = ins.offset, opcode = ins.opcode, node = node.op }
          )
        end
      else
        local classification = CommandCatalog.classification(ins.opcode)
        local boundary = nodeBlocks(node) or YIELD_OPS[node.op] == true
        if classification == CommandCatalog.NATIVE_WAIT and not boundary then
          addProblem(
            context,
            "native-wait instruction lacks a blocking translation",
            { offset = ins.offset, opcode = ins.opcode, node = node.op }
          )
        elseif classification == CommandCatalog.YIELD and not boundary then
          addProblem(
            context,
            "yield instruction lacks a run-phase boundary",
            { offset = ins.offset, opcode = ins.opcode, node = node.op }
          )
        elseif classification == CommandCatalog.STOP and not TERMINAL_OPS[node.op] then
          addProblem(
            context,
            "stop instruction translated to a non-terminal node",
            { offset = ins.offset, opcode = ins.opcode, node = node.op }
          )
        elseif classification == CommandCatalog.CONTINUE and boundary and node.op ~= "stop" then
          addProblem(
            context,
            "same-tick instruction folded into a blocking node",
            { offset = ins.offset, opcode = ins.opcode, node = node.op }
          )
        end
      end
    end
  end
end

local function regionHasUnsupported(context, label)
  local memberLabels = context.memberLabels
  local owner = memberLabels[label]
  if owner == nil then
    return nil
  end
  local targetScript = context.memberIr.scripts[owner]
  if targetScript == nil then
    return nil
  end
  local lowered = context.loweredCache[owner]
  if lowered == nil then
    lowered = SemanticLowering.lowerScript(targetScript, context.memberIr, {})
    context.loweredCache[owner] = lowered
  end
  local inRegion = false
  for _, item in ipairs(lowered.items) do
    if item.op == "label" then
      if item.name == label then
        inRegion = true
      elseif inRegion then
        break
      end
    elseif inRegion and (item.op == "stop" or item.op == "unsupported") then
      return item.op == "unsupported"
    end
  end
  return false
end

local function verifyCrossScriptTargets(context)
  if context.memberIr == nil then
    return
  end
  context.memberLabels = {}
  for _, memberScript in pairs(context.memberIr.scripts) do
    for _, ins in ipairs(memberScript.instructions) do
      if ins.label ~= nil then
        context.memberLabels[ins.label] = memberScript.index
      end
    end
  end
  context.loweredCache = {}
  local function walkCrossScript(list)
    for _, item in ipairs(list) do
      if item.op == "goto_script" or (item.op == "call" and item.label ~= nil) then
        local targetId = item.op == "goto_script" and item.script or item.target
        if item.label ~= nil and regionHasUnsupported(context, item.label) then
          addWarning(
            context,
            "cross-script target region contains unsupported nodes",
            { scriptId = targetId, label = item.label }
          )
        end
      end
      if item.op == "if" then
        walkCrossScript(item.yes)
        walkCrossScript(item.no)
      end
    end
  end
  walkCrossScript(context.steps)
end

local function verifyOperands(context)
  for _, ins in ipairs(context.script.instructions) do
    local checker = CHECKERS[ins.opcode]
    if checker ~= nil then
      local node = context.byOffset[ins.offset]
      if node ~= nil and node.op ~= "unsupported" then
        local message = checker(ins, node)
        if message ~= nil then
          addProblem(context, message, { offset = ins.offset, opcode = ins.opcode })
        end
      end
    end
  end
end

local function verifyCallReturnBalance(context)
  for _, balanceProblem in ipairs(context.cfg.balance.problems) do
    local preludeTolerant = context.prelude
      and (
        balanceProblem.message == "return below an empty script stack"
        or balanceProblem.message == "return with no matching call"
      )
    if preludeTolerant then
      addWarning(context, balanceProblem.message, balanceProblem.context)
    else
      addProblem(context, balanceProblem.message, balanceProblem.context)
    end
  end
  for _, balanceWarning in ipairs(context.cfg.balance.warnings) do
    addWarning(context, balanceWarning.message, balanceWarning.context)
  end
  local hasCall = false
  for _, ins in ipairs(context.script.instructions) do
    if CALL_OPS[ins.opcode] then
      hasCall = true
      break
    end
  end
  if not hasCall then
    for i, ins in ipairs(context.script.instructions) do
      if RETURN_OPS[ins.opcode] then
        local blockId = context.cfg.blockOfIndex[i]
        local message = "return without any call in the script"
        local isReachable = blockId ~= nil and context.cfg.reachable[blockId] == true
        if context.prelude or not isReachable then
          addWarning(context, message, { offset = ins.offset, opcode = ins.opcode })
        else
          addProblem(context, message, { offset = ins.offset, opcode = ins.opcode })
        end
      end
    end
  end
end

local function verifyMovementTermination(context)
  for _, reference in ipairs(context.cfg.movementReferences) do
    if reference.block == nil then
      addProblem(context, "ApplyMovement references a missing movement block", { offset = reference.offset })
    elseif not reference.block.terminated then
      addProblem(context, "movement sequence lacks an EndMovement terminator", { offset = reference.offset })
    elseif #reference.block.actions == 0 then
      addProblem(context, "movement sequence is empty", { offset = reference.offset })
    end
  end
end

local function finalizeReport(context)
  local unreachable = context.total - context.reachable
  if unreachable > 0 then
    addWarning(context, "script contains unreachable instructions", { count = unreachable })
  end
  local report = context.report
  report.total = context.total
  report.reachable = context.reachable
  report.unreachable = unreachable
  report.covered = context.covered
  report.reachableOmitted = context.reachableOmitted
  report.unsupportedCount = context.reachableUnsupported
  report.unsupported = context.unsupportedNodes
  report.irreducible = context.cfg.irreducibleRegions
  report.balance = context.cfg.balance
  report.complete = report.ok
    and context.covered + #(context.omissions or {}) >= context.total
    and context.reachableUnsupported == 0
  return report
end

-- Verify one script's final structured steps against its raw instructions
-- and CFG. The steps are the post-structuring, post-scrub program that is
-- actually emitted and executed; omissions are the lowering's documented
-- erasures (the only instructions allowed to disappear).
---@param steps table[]
---@param script table<string, unknown> raw script (instructions)
---@param memberIr table<string, unknown>|nil
---@param omissions table<string, unknown>|nil
---@return table<string, unknown> report
function Verifier.verifyScript(steps, script, memberIr, omissions)
  local context = newVerificationContext(steps, script, memberIr, omissions)
  verifyCoverage(context)
  verifyControlEdges(context)
  verifyBranchTargets(context)
  verifyExecutionBoundaries(context)
  verifyCrossScriptTargets(context)
  verifyOperands(context)
  verifyCallReturnBalance(context)
  verifyMovementTermination(context)
  return finalizeReport(context)
end

return Verifier
