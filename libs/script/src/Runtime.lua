-- Internal graph node execution: the runtime executes compiled graphs, never
-- authoring tables. Every node handler returns exactly one outcome:
-- `continue`, `yield_tick`, `block`, or `stop`. Attributed faults (missing
-- actors, background-forbidden operations, lock violations, task failures)
-- raise Errors objects that the scheduler's run loop converts into faulted
-- instances. Value and condition evaluation are supplied by the owning
-- runtime package, while this module owns graph execution. Pure domain
-- module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local ScriptEnvironment = require("libs.script.src.ScriptEnvironment")

local Runtime = {}

-- Game meaning is supplied by the owning runtime package. The core executor
-- only knows the evaluator contract and never constructs HGSS services.
---@param run table<string, unknown>
---@return table<string, unknown>
local function semanticsFor(run)
  local semantics = run.semantics
  if semantics == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "script semantics are unavailable",
      { scriptId = run.instance.scriptId }
    )
  end
  return semantics --[[@as table]]
end

Runtime.OUTCOME_CONTINUE = "continue"
Runtime.OUTCOME_YIELD_TICK = "yield_tick"
Runtime.OUTCOME_BLOCK = "block"
Runtime.OUTCOME_STOP = "stop"

-- The opposite facing, for `facePlayer` (the actor turns toward the player).
local OPPOSITE_FACING = { north = "south", south = "north", west = "east", east = "west" }

-- Background-mode restriction: background scripts may never lock player
-- input, open foreground dialogue, warp, or move the player.
---@param run table<string, unknown>
---@param op string
local function requireForeground(run, op)
  if run.instance.mode == "background" then
    Errors.raise(
      ScriptErrors.SCRIPT_BACKGROUND_FORBIDDEN,
      op .. " is not allowed in a background script",
      { scriptId = run.instance.scriptId, op = op, instanceId = run.instance.instanceId }
    )
  end
end

-- The player is never a script-controlled actor in a background script.
---@param run table<string, unknown>
---@param actorId string
local function requireForegroundPlayer(run, actorId)
  if actorId == "player" and run.instance.mode == "background" then
    Errors.raise(
      ScriptErrors.SCRIPT_BACKGROUND_FORBIDDEN,
      "background scripts may not move the player",
      { scriptId = run.instance.scriptId, instanceId = run.instance.instanceId }
    )
  end
end

local function requireScriptMenu(run)
  local host = run.services.scriptMenu
  if host == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "scriptMenu service is unavailable",
      { scriptId = run.instance.scriptId }
    )
  end
  return host
end

-- Create a blocking task through the scheduler and return the block outcome.
-- The blocking node's `result` ref (ask_yes_no) rides along so the
-- scheduler can write the completed task result on continuation.
---@param run table<string, unknown>
---@param taskType string
---@param spec table<string, unknown>
---@param resultRef table<string, unknown>|nil
---@return string outcome
local function blockOnTask(run, taskType, spec, resultRef)
  local taskId = run.scheduler:createTask(taskType, spec, run.instance, run.tick, run.input)
  run.blockTaskId = taskId
  run.blockResultRef = resultRef or (run.node and run.node.result or nil)
  return Runtime.OUTCOME_BLOCK
end

-- Advance the composition chain: pop the current chain frame and push the
-- next entry's frame. With no next entry, return to the caller or complete.
-- Used by the `next` node and by falling off a linear tail.
---@param run table<string, unknown>
---@param frame table<string, unknown>
---@return string outcome
local function advanceChain(run, frame)
  local entries = frame.chain
  -- entryIndex is zero-based; the chain is a 1-based Lua array.
  local nextIndex = frame.composition.entryIndex + 1
  if nextIndex < #entries then
    local popped = run.instance:popFrame()
    local entry = entries[nextIndex + 1]
    run.instance:pushFrame(run.instance:makeFrame(entry.graph, entry.graph.entry, {
      returnNodeId = popped.returnNodeId,
      resultRef = popped.resultRef,
      args = frame.args,
      chain = entries,
      chainScriptId = frame.chainScriptId,
      chainRevision = frame.chainRevision,
      composition = {
        entryIndex = nextIndex,
        operation = entry.operation,
        owner = entry.owner,
      },
    }))
    return Runtime.OUTCOME_CONTINUE
  end
  local popped = run.instance:popFrame()
  if run.instance:topFrame() ~= nil then
    run.instance:resumeCaller(popped)
    return Runtime.OUTCOME_CONTINUE
  end
  return Runtime.OUTCOME_STOP
end

-- Evaluate a call's args against the current frame and store them on a fresh
-- frame (values are evaluated at call time).
---@param node table<string, unknown>
---@param run table<string, unknown>
---@return table<string, unknown>
local function evaluatedArgs(node, run)
  local args = {}
  for name, ref in pairs(node.args or {}) do
    args[name] = semanticsFor(run).evaluateValue(ref, run)
  end
  return args
end

-- Push the entry frame of a composed script (the first chain entry),
-- entering at `nodeId` when given (a label inside the entry graph) or at
-- the composed entry otherwise.
---@param run table<string, unknown>
---@param composed table<string, unknown>
---@param args table<string, unknown>
---@param returnNodeId string|nil
---@param nodeId string|nil
local function pushComposedFrame(run, composed, args, returnNodeId, nodeId)
  local entries = composed.entries
  assert(#entries > 0, "composed script has no entries")
  local entry = entries[1]
  run.instance:pushFrame(run.instance:makeFrame(entry.graph, nodeId or entry.graph.entry, {
    returnNodeId = returnNodeId,
    resultRef = returnNodeId ~= nil and run.node.result or nil,
    args = args,
    chain = entries,
    chainScriptId = composed.scriptId,
    chainRevision = composed.revision,
    composition = {
      entryIndex = 0,
      operation = entry.operation,
      owner = entry.owner,
    },
  }))
end

-- The graph and entry node id of a composed script, entering at `label`
-- when given (a label inside the composed entry graph) or at the entry
-- otherwise. A missing label is an attributed label error.
---@param _ table<string, unknown>
---@param composed table<string, unknown>
---@param label string|nil
---@return table<string, unknown> graph, string nodeId
local function composedEntryAt(_, composed, label)
  local entries = composed.entries
  assert(#entries > 0, "composed script has no entries")
  local entry = entries[1]
  if label == nil then
    return entry.graph, entry.graph.entry
  end
  local nodeId = entry.graph.labels[label]
  if nodeId == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_LABEL_MISSING,
      "composed script has no label " .. label,
      { scriptId = composed.scriptId, label = label }
    )
  end
  return entry.graph, nodeId --[[@as string]]
end

-- Resolve a call target through the scheduler's composition resolver; a
-- missing target is an attributed call error.
---@param run table<string, unknown>
---@param target string
---@return table<string, unknown> composed
local function resolveCallTarget(run, target)
  local composed = run.scheduler:resolveComposition(target)
  if composed == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_CALL_TARGET_MISSING,
      "no composed script for call target " .. target,
      { scriptId = run.instance.scriptId, target = target }
    )
  end
  return composed --[[@as table]]
end

-- --- Node handlers ------------------------------------------------------------

-- Same-tick audio, camera, dialogue-primitive, and open/close operations:
-- they apply their side effect and continue. A missing service is an
-- attributed fault, never a silent skip: the platform must not count an
-- unsupported operation as successfully executed.
local function requireService(run, name)
  local service = run.services[name]
  if service == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      name .. " service is unavailable",
      { scriptId = run.instance.scriptId }
    )
  end
  return service
end

local HANDLERS = {}

-- The step budget consumes one unit per continue outcome; handlers below that
-- continue set the frame's pc or push frames themselves.

local function handleNoop(_, _)
  return Runtime.OUTCOME_CONTINUE
end

local function handleLabel(_, _)
  return Runtime.OUTCOME_CONTINUE
end

local function handleStop(_, _)
  return Runtime.OUTCOME_STOP
end

-- ScrCmd_061 (std_signpost's hide-branch tail): no operands. The source
-- installs the Start Menu reopen end callback (sub_0204031C ->
-- sub_0203BD64) and returns FALSE, ending the script context. The reopen
-- request routes through the startMenuReopen service, which the Start Menu
-- application host consumes when the environment ends; a missing
-- service is an attributed fault, never a silent close. The STOP outcome
-- ends this script context (a child context ending resumes the caller
-- through the child-slot mechanics).
local function handleRequestStartMenu(_, run)
  requireService(run, "startMenuReopen"):request()
  return Runtime.OUTCOME_STOP
end

local function handleYieldTick(_, _)
  return Runtime.OUTCOME_YIELD_TICK
end

local function handleSetAuxiliaryUiVisible(node, run)
  requireForeground(run, "set_auxiliary_ui_visible")
  local auxiliary = run.services.auxiliaryUi
  if auxiliary == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "auxiliaryUi service is unavailable",
      { scriptId = run.instance.scriptId }
    )
  end
  assert(auxiliary, "auxiliaryUi service is unavailable")
  if not node.visible and auxiliary:status().state == "hidden" then
    return Runtime.OUTCOME_CONTINUE
  end
  return blockOnTask(run, "auxiliary_ui", { node = node })
end

local function handleContextChoice(node, run)
  requireForeground(run, "context_choice")
  if run.services.contextChoice == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "contextChoice service is unavailable",
      { scriptId = run.instance.scriptId }
    )
  end
  return blockOnTask(run, "context_choice", { node = node })
end

local function handleIf(node, run)
  local frame = run.instance:topFrame()
  if semanticsFor(run).evaluateCondition(node.condition, run) then
    frame.nodeId = node.yes
  else
    frame.nodeId = node.no
  end
  return Runtime.OUTCOME_CONTINUE
end

local function handleSwitch(node, run)
  local frame = run.instance:topFrame()
  local value = semanticsFor(run).evaluateValue(node.value, run)
  frame.nodeId = node.cases[value] or node.default
  return Runtime.OUTCOME_CONTINUE
end

local function handleGoto(node, run)
  run.instance:topFrame().nodeId = node.targetNode
  return Runtime.OUTCOME_CONTINUE
end

local function handleGotoIf(node, run)
  local frame = run.instance:topFrame()
  if semanticsFor(run).evaluateCondition(node.condition, run) then
    frame.nodeId = node.targetNode
  else
    frame.nodeId = node.next
  end
  return Runtime.OUTCOME_CONTINUE
end

local function handleCompare(node, run)
  run.instance.compare = {
    left = semanticsFor(run).evaluateValue(node.left, run),
    right = semanticsFor(run).evaluateValue(node.right, run),
  }
  return Runtime.OUTCOME_CONTINUE
end

local function compareLessThan(left, right)
  return left < right
end

local function compareEqual(left, right)
  return left == right
end

local function compareGreaterThan(left, right)
  return left > right
end

local function compareLessThanOrEqual(left, right)
  return left <= right
end

local function compareGreaterThanOrEqual(left, right)
  return left >= right
end

local function compareNotEqual(left, right)
  return left ~= right
end

local COMPARE_OPS = {
  lt = compareLessThan,
  eq = compareEqual,
  gt = compareGreaterThan,
  le = compareLessThanOrEqual,
  ge = compareGreaterThanOrEqual,
  ne = compareNotEqual,
}

-- Evaluate the low-level compare state against an operator.
---@param operator string
---@param run table<string, unknown>
---@return boolean
local function compared(operator, run)
  local compare = run.instance.compare
  if compare == nil then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "compare state is unset", { scriptId = run.instance.scriptId })
  end
  local fn = assert(COMPARE_OPS[operator], "unknown compare operator " .. tostring(operator))
  local cmp = compare --[[@as { left: unknown, right: unknown }]]
  return fn(cmp.left, cmp.right)
end

-- Switch the top frame onto a composed target at its entry (or a label
-- inside it), replacing the frame's graph identity and chain attribution so
-- save pinning and ownership follow the target. Shared by the cross-script
-- compare-state jump and `goto_script`; the jump continues in the same tick,
-- matching the source `ScriptJump` semantics.
---@param _ table<string, unknown>
---@param frame table<string, unknown>
---@param composed table<string, unknown>
---@param nodeId string
local function switchFrameToComposed(_, frame, composed, nodeId)
  local entries = composed.entries
  local entry = entries[1]
  frame.graph = entry.graph
  frame.graphRevision = entry.graph.revision
  frame.nodeId = nodeId
  frame.chain = entries
  frame.chainScriptId = composed.scriptId
  frame.chainRevision = composed.revision
  frame.composition = {
    entryIndex = 0,
    operation = entry.operation,
    owner = entry.owner,
  }
end

local function handleGotoCompared(node, run)
  local frame = run.instance:topFrame()
  if compared(node.operator, run) then
    if node.script ~= nil then
      -- Cross-script compare-state jump (shared script tails): resolve the
      -- composed target and switch the frame, consuming the compare state
      -- exactly as the source engine does.
      local composed = resolveCallTarget(run, node.script)
      local _, nodeId = composedEntryAt(run, composed, node.label)
      switchFrameToComposed(run, frame, composed, nodeId)
    else
      frame.nodeId = node.targetNode
    end
  else
    frame.nodeId = node.next
  end
  return Runtime.OUTCOME_CONTINUE
end

local function handleCallCompared(node, run)
  if compared(node.operator, run) then
    return HANDLERS.call(node, run)
  end
  return Runtime.OUTCOME_CONTINUE
end

local function handleCall(node, run)
  local frame = run.instance:topFrame()
  local args = evaluatedArgs(node, run)
  local returnNodeId = node.returnNode
  if node.targetNode ~= nil then
    run.instance:pushFrame(run.instance:makeFrame(frame.graph, node.targetNode, {
      returnNodeId = returnNodeId,
      resultRef = node.result,
      args = args,
      chain = frame.chain,
      chainScriptId = frame.chainScriptId,
      chainRevision = frame.chainRevision,
      composition = frame.composition,
    }))
    return Runtime.OUTCOME_CONTINUE
  end
  local composed = resolveCallTarget(run, node.target or node.script)
  local _, nodeId = composedEntryAt(run, composed, node.label)
  pushComposedFrame(run, composed, args, returnNodeId, nodeId)
  return Runtime.OUTCOME_CONTINUE
end

-- A cross-script same-context jump (shared script tails): switches the top
-- frame to the composed target at its label (or its entry) and continues in
-- the same tick, matching the source `ScriptJump` semantics.
local function handleGotoScript(node, run)
  local composed = resolveCallTarget(run, node.script)
  local _, nodeId = composedEntryAt(run, composed, node.label)
  switchFrameToComposed(run, run.instance:topFrame(), composed, nodeId)
  return Runtime.OUTCOME_CONTINUE
end

local function handleReturn(node, run)
  -- The value is evaluated against the callee frame (its own args), so it
  -- must be resolved before the frame is popped.
  local value
  if node.value ~= nil then
    value = semanticsFor(run).evaluateValue(node.value, run)
  end
  local frame = run.instance:popFrame()
  assert(frame ~= nil, "return with an empty frame stack")
  if value ~= nil then
    if frame.resultRef ~= nil then
      semanticsFor(run).writeRef(frame.resultRef, value, run)
    end
  end
  if run.instance:topFrame() ~= nil then
    run.instance:resumeCaller(frame)
    return Runtime.OUTCOME_CONTINUE
  end
  return Runtime.OUTCOME_STOP
end

local function handleNext(_, run)
  local frame = run.instance:topFrame()
  if frame.chain == nil or frame.composition == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_WRAPPER_INVALID,
      "next outside a wrapper composition",
      { scriptId = run.instance.scriptId }
    )
  end
  return advanceChain(run, frame)
end

-- The source `ScrCmd_RestartCurrentScript` (opcode 21) clears the caller
-- signal bit and returns FALSE to its interpreter loop. The common child
-- therefore continues through its following command; the caller's
-- child_script task observes the cleared signal on its next poll.
local function handleSignalCaller(_, run)
  local slot = run.instance.contextSlot
  if slot <= 0 then
    Errors.raise(
      ScriptErrors.SCRIPT_CALLER_SIGNAL_INVALID,
      "signal_caller is only valid inside a common-script child context",
      { scriptId = run.instance.scriptId, contextSlot = slot }
    )
  end
  run.environment:setCallerSignal(slot - 1, false)
  return Runtime.OUTCOME_CONTINUE
end

local function handleCallCommon(node, run)
  local composed = resolveCallTarget(run, node.target)
  local args = evaluatedArgs(node, run)
  local child, slot, parentSlot = run.scheduler:createCommonChild(composed, args, run)
  local taskId = run.scheduler:createTask("child_script", {
    childInstanceId = child.instanceId,
    childSlot = slot,
    parentSlot = parentSlot,
  }, run.instance, run.tick, run.input)
  run.blockTaskId = taskId
  return Runtime.OUTCOME_BLOCK
end

local function handleSetFlag(node, run)
  local flagId = semanticsFor(run).resolveIdOperand(node.flag, run)
  run.services.world:setFlag(flagId)
  if run.services.actors and run.services.actors.syncPresence then
    run.services.actors:syncPresence()
  end
  return Runtime.OUTCOME_CONTINUE
end

local function handleClearFlag(node, run)
  local flagId = semanticsFor(run).resolveIdOperand(node.flag, run)
  run.services.world:clearFlag(flagId)
  if run.services.actors and run.services.actors.syncPresence then
    run.services.actors:syncPresence()
  end
  return Runtime.OUTCOME_CONTINUE
end

local function handleChangeWeather(node, run)
  requireService(run, "weather"):change(node.weatherId)
  return Runtime.OUTCOME_CONTINUE
end

local function handleSetVar(node, run)
  local variableId = semanticsFor(run).resolveIdOperand(node.variable, run)
  local value = semanticsFor(run).evaluateValue(node.value, run)
  run.services.world:setVar(variableId, value)
  return Runtime.OUTCOME_CONTINUE
end

local function handleCopyVar(node, run)
  local destination = semanticsFor(run).resolveIdOperand(node.destination, run)
  local source = semanticsFor(run).resolveIdOperand(node.source, run)
  run.services.world:setVar(destination, run.services.world:getVar(source))
  return Runtime.OUTCOME_CONTINUE
end

local function handleAddVar(node, run)
  local variableId = semanticsFor(run).resolveIdOperand(node.variable, run)
  local amount = semanticsFor(run).evaluateValue(node.amount, run)
  run.services.world:addVar(variableId, amount)
  return Runtime.OUTCOME_CONTINUE
end

local function handleSubVar(node, run)
  local variableId = semanticsFor(run).resolveIdOperand(node.variable, run)
  local amount = semanticsFor(run).evaluateValue(node.amount, run)
  run.services.world:subVar(variableId, amount)
  return Runtime.OUTCOME_CONTINUE
end

local function handleSetLocal(node, run)
  run.instance.locals[node.name] = node.value
  return Runtime.OUTCOME_CONTINUE
end

local function handleCopyLocal(node, run)
  run.instance.locals[node.destination] = run.instance.locals[node.source]
  return Runtime.OUTCOME_CONTINUE
end

local function handleAddLocal(node, run)
  run.instance.locals[node.name] = (run.instance.locals[node.name] or 0) + node.amount
  return Runtime.OUTCOME_CONTINUE
end

local function handleSubLocal(node, run)
  run.instance.locals[node.name] = (run.instance.locals[node.name] or 0) - node.amount
  return Runtime.OUTCOME_CONTINUE
end

local function handleBufferText(node, run)
  run.instance.textArgs[node.slot] = node.value
  return Runtime.OUTCOME_CONTINUE
end

-- Mon and party operations. Each handler evaluates its semantic operands
-- through the run semantics, calls exactly one named operation on the
-- injected mons service, and writes the source result convention to the
-- result reference: 1 or 0 for booleans, an exact script integer for the
-- source-shaped queries (whose sentinels differ by command: move search
-- leaves the party size 6, nature/species search leaves 255, nature lookup
-- reads 0), and the zero-based slot or 6 for the remaining searches and
-- leads. No handler dispatches on a source opcode; the node op already
-- names the behavior.
local function monsFor(run)
  return requireService(run, "mons")
end

local function evalField(node, run, name)
  return semanticsFor(run).evaluateValue(node[name], run)
end

local function evalOptional(node, run, name)
  if node[name] == nil then
    return nil
  end
  return semanticsFor(run).evaluateValue(node[name], run)
end

local function writeMonsResult(node, run, value)
  semanticsFor(run).writeRef(node.result, value, run)
end

local function writeMonsBool(node, run, value)
  writeMonsResult(node, run, value and 1 or 0)
end

local function writeMonsSlot(node, run, slot)
  writeMonsResult(node, run, slot == nil and 6 or slot)
end

local function handleGiveMon(node, run)
  local added = monsFor(run):giveMon({
    species = evalField(node, run, "species"),
    level = evalField(node, run, "level"),
    heldItem = evalOptional(node, run, "heldItem"),
    form = evalOptional(node, run, "form"),
    ability = evalOptional(node, run, "ability"),
  })
  writeMonsBool(node, run, added)
  return Runtime.OUTCOME_CONTINUE
end

-- Blocking starter selection: the foreground script owns the field until
-- the starter task publishes the confirmed candidate and restores the
-- field presentation. The task carries no result ref; the party holds the
-- published mon and the resumed script owns its story flags.
local function handleChooseStarter(node, run)
  requireForeground(run, "choose_starter")
  return blockOnTask(run, "choose_starter", { node = node })
end

local function handleReturnLoanMon(node, run)
  monsFor(run):returnLoanMon(evalField(node, run, "slot"))
  if node.result ~= nil then
    writeMonsBool(node, run, true)
  end
  return Runtime.OUTCOME_CONTINUE
end

local function handleSetMonMove(node, run)
  monsFor(run):setMove(evalField(node, run, "slot"), evalField(node, run, "moveSlot"), evalField(node, run, "move"))
  return Runtime.OUTCOME_CONTINUE
end

local function handleMonHasMove(node, run)
  writeMonsBool(node, run, monsFor(run):scriptMonHasMove(evalField(node, run, "slot"), evalField(node, run, "move")))
  return Runtime.OUTCOME_CONTINUE
end

local function handlePartySlotWithMove(node, run)
  writeMonsResult(node, run, monsFor(run):scriptSlotWithMove(evalField(node, run, "move")))
  return Runtime.OUTCOME_CONTINUE
end

local function handleCountMonMoves(node, run)
  writeMonsResult(node, run, monsFor(run):countMonMoves(evalField(node, run, "slot")))
  return Runtime.OUTCOME_CONTINUE
end

local function handleMonForgetMove(node, run)
  monsFor(run):deleteMove(evalField(node, run, "slot"), evalField(node, run, "moveSlot"))
  return Runtime.OUTCOME_CONTINUE
end

local function handleMonGetMove(node, run)
  writeMonsResult(node, run, monsFor(run):monMove(evalField(node, run, "slot"), evalField(node, run, "moveSlot")))
  return Runtime.OUTCOME_CONTINUE
end

local function handlePartyCount(node, run)
  writeMonsResult(node, run, monsFor(run):partyCount())
  return Runtime.OUTCOME_CONTINUE
end

local function handlePartyCountNotEgg(node, run)
  writeMonsResult(node, run, monsFor(run):partyCountNotEgg())
  return Runtime.OUTCOME_CONTINUE
end

local function handlePartyCountEgg(node, run)
  writeMonsResult(node, run, monsFor(run):partyCountEgg())
  return Runtime.OUTCOME_CONTINUE
end

local function handleCountAliveMons(node, run)
  writeMonsResult(node, run, monsFor(run):countAliveMons(evalOptional(node, run, "excludeSlot")))
  return Runtime.OUTCOME_CONTINUE
end

local function handlePartyCountAtOrBelowLevel(node, run)
  writeMonsResult(node, run, monsFor(run):scriptCountAtOrBelowLevel(evalField(node, run, "level")))
  return Runtime.OUTCOME_CONTINUE
end

local function handleCountSpecies(node, run)
  writeMonsResult(node, run, monsFor(run):scriptCountSpecies(evalField(node, run, "species")))
  return Runtime.OUTCOME_CONTINUE
end

local function handlePartySlotWithSpecies(node, run)
  writeMonsResult(node, run, monsFor(run):scriptSlotWithSpecies(evalField(node, run, "species")))
  return Runtime.OUTCOME_CONTINUE
end

local function handlePartySlotWithNature(node, run)
  writeMonsResult(node, run, monsFor(run):scriptSlotWithNature(evalField(node, run, "nature")))
  return Runtime.OUTCOME_CONTINUE
end

local function handlePartySlotWithFatefulEncounter(node, run)
  writeMonsSlot(node, run, monsFor(run):partySlotWithFatefulEncounter(evalOptional(node, run, "species")))
  return Runtime.OUTCOME_CONTINUE
end

local function handlePartyMonSpecies(node, run)
  writeMonsResult(node, run, monsFor(run):scriptPartyMonSpecies(evalField(node, run, "slot")))
  return Runtime.OUTCOME_CONTINUE
end

local function handlePartyMonTypes(node, run)
  local type1, type2 = monsFor(run):monTypes(evalField(node, run, "slot"))
  semanticsFor(run).writeRef(node.type1, type1, run)
  semanticsFor(run).writeRef(node.type2, type2, run)
  return Runtime.OUTCOME_CONTINUE
end

local function handlePartyMonLevel(node, run)
  writeMonsResult(node, run, monsFor(run):scriptMonLevel(evalField(node, run, "slot")))
  return Runtime.OUTCOME_CONTINUE
end

local function handlePartyMonIsMine(node, run)
  writeMonsResult(node, run, monsFor(run):scriptPartyMonOwnershipResult(evalField(node, run, "slot")))
  return Runtime.OUTCOME_CONTINUE
end

local function handlePartyMonNature(node, run)
  writeMonsResult(node, run, monsFor(run):scriptMonNature(evalField(node, run, "slot")))
  return Runtime.OUTCOME_CONTINUE
end

local function handlePartyMonFriendship(node, run)
  writeMonsResult(node, run, monsFor(run):monFriendship(evalField(node, run, "slot")))
  return Runtime.OUTCOME_CONTINUE
end

local function handleMonAddFriendship(node, run)
  monsFor(run):scriptAddFriendship(evalField(node, run, "slot"), evalField(node, run, "amount"))
  return Runtime.OUTCOME_CONTINUE
end

local function handleMonSubFriendship(node, run)
  monsFor(run):monSubFriendship(evalField(node, run, "slot"), evalField(node, run, "amount"))
  return Runtime.OUTCOME_CONTINUE
end

local function handlePartyMonGender(node, run)
  writeMonsResult(node, run, monsFor(run):monGender(evalField(node, run, "slot")))
  return Runtime.OUTCOME_CONTINUE
end

local function handlePartyMonContestValue(node, run)
  writeMonsResult(
    node,
    run,
    monsFor(run):monContestValue(evalField(node, run, "slot"), evalField(node, run, "contestType"))
  )
  return Runtime.OUTCOME_CONTINUE
end

local function handleMonAddContestValue(node, run)
  monsFor(run):scriptAddContestValue(
    evalField(node, run, "slot"),
    evalField(node, run, "contestType"),
    evalField(node, run, "amount")
  )
  return Runtime.OUTCOME_CONTINUE
end

local function handlePartyMonForm(node, run)
  writeMonsResult(node, run, monsFor(run):monForm(evalField(node, run, "slot")))
  return Runtime.OUTCOME_CONTINUE
end

local function handleSetMonForm(node, run)
  monsFor(run):setMonForm(evalField(node, run, "slot"), evalField(node, run, "form"))
  return Runtime.OUTCOME_CONTINUE
end

local function handlePartyMonRibbonCount(node, run)
  writeMonsResult(node, run, monsFor(run):monRibbonCount(evalField(node, run, "slot")))
  return Runtime.OUTCOME_CONTINUE
end

local function handlePartyRibbonCount(node, run)
  writeMonsResult(node, run, monsFor(run):scriptPartyRibbonCount())
  return Runtime.OUTCOME_CONTINUE
end

local function handlePartyHasPokerus(node, run)
  writeMonsBool(node, run, monsFor(run):partyHasPokerus())
  return Runtime.OUTCOME_CONTINUE
end

local function handlePartyHasHeldItem(node, run)
  writeMonsBool(node, run, monsFor(run):partyHasHeldItem(evalField(node, run, "item")))
  return Runtime.OUTCOME_CONTINUE
end

local function handlePartyLead(node, run)
  writeMonsSlot(node, run, monsFor(run):leadSlot())
  return Runtime.OUTCOME_CONTINUE
end

local function handlePartyLeadAlive(node, run)
  writeMonsSlot(node, run, monsFor(run):leadAliveSlot())
  return Runtime.OUTCOME_CONTINUE
end

local function handlePartyLegalCheck(node, run)
  writeMonsResult(node, run, monsFor(run):scriptPartyLegalResult())
  return Runtime.OUTCOME_CONTINUE
end

local function handleCheckKyogreGroudon(node, run)
  writeMonsBool(node, run, monsFor(run):hasKyogreGroudon())
  return Runtime.OUTCOME_CONTINUE
end

local function handleHealParty(_, run)
  monsFor(run):healParty()
  return Runtime.OUTCOME_CONTINUE
end

-- Bag and item operations. Each handler evaluates its item/quantity
-- operands through the run semantics, calls exactly one named operation on
-- the injected Bag service with native identities, and writes the numeric
-- source result to the declared result variable: 1 or 0 for the boolean
-- commands, the native pocket id for the pocket query, and the exact owned
-- count for the quantity query. Every node continues in the same tick and
-- never mutates world variables other than its result. No handler switches
-- on a source opcode; the node op already names the behavior. An unknown
-- native identity fails through the catalog's structured record validation
-- instead of reading as an absent item.
local function itemsFor(run)
  return requireService(run, "items")
end

local function writeItemsBool(node, run, value)
  semanticsFor(run).writeRef(node.result, value and 1 or 0, run)
end

local function handleBagAddItem(node, run)
  writeItemsBool(node, run, itemsFor(run):addNative(evalField(node, run, "item"), evalField(node, run, "quantity")))
  return Runtime.OUTCOME_CONTINUE
end

local function handleBagTakeItem(node, run)
  writeItemsBool(node, run, itemsFor(run):takeNative(evalField(node, run, "item"), evalField(node, run, "quantity")))
  return Runtime.OUTCOME_CONTINUE
end

local function handleBagHasSpace(node, run)
  writeItemsBool(
    node,
    run,
    itemsFor(run):hasSpaceNative(evalField(node, run, "item"), evalField(node, run, "quantity"))
  )
  return Runtime.OUTCOME_CONTINUE
end

local function handleBagHasItem(node, run)
  writeItemsBool(node, run, itemsFor(run):hasNative(evalField(node, run, "item"), evalField(node, run, "quantity")))
  return Runtime.OUTCOME_CONTINUE
end

local function handleItemIsTmhm(node, run)
  writeItemsBool(node, run, itemsFor(run):isTMHMNative(evalField(node, run, "item")))
  return Runtime.OUTCOME_CONTINUE
end

local function handleItemGetPocket(node, run)
  semanticsFor(run).writeRef(node.result, itemsFor(run):pocketNativeIdNative(evalField(node, run, "item")), run)
  return Runtime.OUTCOME_CONTINUE
end

local function handleBagGetQuantity(node, run)
  semanticsFor(run).writeRef(node.result, itemsFor(run):quantityNative(evalField(node, run, "item")), run)
  return Runtime.OUTCOME_CONTINUE
end

local function handlePartySelect(_, run)
  requireForeground(run, "party_select")
  monsFor(run)
  -- The source selection context (PARTY_MENU_CONTEXT_3): every occupied
  -- slot is eligible and B cancels. The completed slot parks on the
  -- script instance for the companion result node; no game variable is
  -- touched here.
  return blockOnTask(run, "party_select", {
    request = {
      mode = "select",
      initialSlot = 0,
      eligibility = { policy = "occupied" },
      allowCancel = true,
    },
  })
end
local function handlePartySelectResult(node, run)
  requireForeground(run, "party_select_result")
  -- The instance-scoped handoff the selection task parked: a completed
  -- zero-based slot or the source cancellation value. Anything else means
  -- the result command ran without its launch, and raw args sentinels
  -- never reach script variables.
  local value = run.instance.locals.__party_selection
  if type(value) ~= "number" or value % 1 ~= 0 or (value > 5 and value ~= 255) or value < 0 then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "party selection holds no completed slot",
      { scriptId = run.instance.scriptId, value = value }
    )
  end
  semanticsFor(run).writeRef(node.result, value, run)
  return Runtime.OUTCOME_CONTINUE
end

-- Follower operations. Each handler calls exactly one named operation on
-- the injected following-mon collaborator (the field controller behind the
-- `followingMon` service) and writes its source-shaped result. No handler
-- switches on a source opcode; the node op already names the behavior.
local function followingMonFor(run)
  return requireService(run, "followingMon")
end

local function handleFollowerIsActive(node, run)
  writeMonsBool(node, run, followingMonFor(run):isActive())
  return Runtime.OUTCOME_CONTINUE
end

local function handleFollowerPartnerState(node, run)
  writeMonsResult(node, run, followingMonFor(run):partnerSourceState())
  return Runtime.OUTCOME_CONTINUE
end

local function handleFollowerFacePlayer(_, run)
  followingMonFor(run):facePlayer()
  return Runtime.OUTCOME_CONTINUE
end

local function handleFollowerSetPaused(node, run)
  assert(node.paused ~= nil, "follower pause requires its source operand")
  local paused = semanticsFor(run).evaluateValue(node.paused, run)
  followingMonFor(run):setMovementPaused(paused ~= 0 and paused ~= false)
  return Runtime.OUTCOME_CONTINUE
end

local function handleFollowerWait(node, run)
  return blockOnTask(run, "follower_wait", { node = node })
end

local function handleFollowerSetMovementType(node, run)
  if not followingMonFor(run):isSourceActive() then
    return Runtime.OUTCOME_CONTINUE
  end
  followingMonFor(run):setMovementType(node.movementType)
  return Runtime.OUTCOME_CONTINUE
end

local function handleFollowerReposition(node, run)
  local offset = semanticsFor(run).evaluateValue(node.a, run)
  local direction = semanticsFor(run).evaluateValue(node.b, run)
  followingMonFor(run):repositionRelativeToPlayer(offset, direction)
  return Runtime.OUTCOME_CONTINUE
end

local function handleFollowerIsEventTrigger(node, run)
  local kind = semanticsFor(run).evaluateValue(node.kind, run)
  local param = node.param ~= nil and semanticsFor(run).evaluateValue(node.param, run) or nil
  writeMonsBool(node, run, followingMonFor(run):isEventTrigger(kind, param))
  return Runtime.OUTCOME_CONTINUE
end

local function handleFollowerTransition(_, run)
  if not followingMonFor(run):isSourceActive() then
    return Runtime.OUTCOME_CONTINUE
  end
  requireService(run, "followerTransition"):start()
  return Runtime.OUTCOME_CONTINUE
end

local function handlePlaceStarterBalls(_, run)
  requireService(run, "starterBalls"):placeStarterBalls()
  return Runtime.OUTCOME_CONTINUE
end

local function handleLockPlayer(_, run)
  requireForeground(run, "lock_player")
  run.environment:acquireLock(ScriptEnvironment.LOCK_PLAYER, nil, run.instance.instanceId)
  return Runtime.OUTCOME_CONTINUE
end

local function handleReleasePlayer(_, run)
  run.environment:releaseLock(ScriptEnvironment.LOCK_PLAYER, nil, run.instance.instanceId)
  return Runtime.OUTCOME_CONTINUE
end

local function handleLockAll(_, run)
  requireForeground(run, "lock_all")
  local followingMon = run.services.followingMon
  if followingMon ~= nil then
    followingMon:setMovementPaused(true)
  end
  run.environment:acquireLock(ScriptEnvironment.LOCK_PLAYER, nil, run.instance.instanceId)
  run.environment:acquireLock(ScriptEnvironment.LOCK_AUTONOMOUS, nil, run.instance.instanceId)
  assert(run.services.actors and type(run.services.actors.allPausable) == "function", "actor pause service required")
  local followerSettled = followingMon == nil or followingMon:isMovementSettled()
  if run.environment:hasOutstandingMovement() or not run.services.actors:allPausable() or not followerSettled then
    return blockOnTask(run, "movement_pause", {})
  end
  return Runtime.OUTCOME_YIELD_TICK
end

local function handleReleaseAll(_, run)
  local followingMon = run.services.followingMon
  if followingMon ~= nil then
    followingMon:setMovementPaused(false)
  end
  run.environment:releaseLock(ScriptEnvironment.LOCK_PLAYER, nil, run.instance.instanceId)
  run.environment:releaseLock(ScriptEnvironment.LOCK_AUTONOMOUS, nil, run.instance.instanceId)
  return Runtime.OUTCOME_CONTINUE
end

local function handleLockActor(node, run)
  local actorId = semanticsFor(run).requireActor(node.actor, run)
  run.environment:acquireLock(ScriptEnvironment.LOCK_ACTOR_PREFIX .. actorId, actorId, run.instance.instanceId)
  if node.waitUntilPausable then
    -- The pause task watches the actor's movement and completes when the
    -- actor is at a pausable boundary (or is not moving at all).
    return blockOnTask(run, "actor_pause", { actor = actorId })
  end
  return Runtime.OUTCOME_CONTINUE
end

local function handleReleaseActor(node, run)
  local actorId = semanticsFor(run).requireActor(node.actor, run)
  run.environment:releaseLock(ScriptEnvironment.LOCK_ACTOR_PREFIX .. actorId, actorId, run.instance.instanceId)
  return Runtime.OUTCOME_CONTINUE
end

local function handleFacePlayer(node, run)
  -- An interaction without an object (background and coordinate triggers)
  -- has nothing to turn toward the player: the default self-facing is a
  -- no-op instead of a missing-actor fault. An explicit actor reference
  -- still resolves strictly below.
  local actorRef = node.actor
  local trigger = run.instance and run.instance.trigger
  if
    (actorRef == nil or actorRef == "self" or (type(actorRef) == "table" and actorRef.special == "self"))
    and (trigger == nil or trigger.selfActor == nil)
  then
    return Runtime.OUTCOME_CONTINUE
  end
  local actorId = semanticsFor(run).requireActor(node.actor, run)
  local facing = run.services.player:facing()
  run.services.actors:setFacing(actorId, OPPOSITE_FACING[facing])
  return Runtime.OUTCOME_CONTINUE
end

local function handleFace(node, run)
  local actorId = semanticsFor(run).requireActor(node.actor, run)
  run.services.actors:setFacing(actorId, node.direction)
  return Runtime.OUTCOME_CONTINUE
end

local function handleShowObject(node, run)
  local actorId = semanticsFor(run).requireActor(node.actor, run)
  run.services.actors:show(actorId)
  return Runtime.OUTCOME_CONTINUE
end

local function handleHideObject(node, run)
  local actorId = semanticsFor(run).requireActor(node.actor, run)
  run.services.actors:hide(actorId)
  return Runtime.OUTCOME_CONTINUE
end

local function handleSetObjectPosition(node, run)
  local actorId = semanticsFor(run).requireActor(node.actor, run)
  run.services.actors:setPosition(actorId, {
    fieldX = semanticsFor(run).evaluateValue(node.fieldX, run),
    fieldZ = semanticsFor(run).evaluateValue(node.fieldZ, run),
    worldY = semanticsFor(run).evaluateValue(node.worldY, run),
  })
  return Runtime.OUTCOME_CONTINUE
end

local function handleSetObjectFacing(node, run)
  local actorId = semanticsFor(run).requireActor(node.actor, run)
  run.services.actors:setFacing(actorId, node.direction)
  return Runtime.OUTCOME_CONTINUE
end

local function handleSetObjectMovementType(node, run)
  local actorId = semanticsFor(run).requireActor(node.actor, run)
  run.services.actors:setMovementType(actorId, node.movementType)
  return Runtime.OUTCOME_CONTINUE
end

local function handleGetPlayerCoords(node, run)
  local position = run.services.player:position()
  semanticsFor(run).writeRef(node.x, position.fieldX, run)
  semanticsFor(run).writeRef(node.z, position.fieldZ, run)
  return Runtime.OUTCOME_CONTINUE
end

local function handleGetObjectCoords(node, run)
  local actorId = semanticsFor(run).requireActor(node.actor, run)
  local position = run.services.actors:getPosition(actorId)
  semanticsFor(run).writeRef(node.x, position.fieldX, run)
  semanticsFor(run).writeRef(node.z, position.fieldZ, run)
  return Runtime.OUTCOME_CONTINUE
end

local function handleGetPlayerFacing(node, run)
  semanticsFor(run).writeRef(node.result, run.services.player:facing(), run)
  return Runtime.OUTCOME_CONTINUE
end

-- The avatar-transition carriers delegate opaque semantic names to the
-- injected player service without learning any game transition vocabulary.
-- Both require foreground execution like every other player-mutating op.
---@param run table<string, unknown>
---@param op string
---@return table<string, unknown> player
local function requireAvatarPlayer(run, op)
  requireForeground(run, op)
  local player = run.services.player
  if player == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "player service is unavailable",
      { scriptId = run.instance.scriptId }
    )
  end
  return player --[[@as table]]
end

local function handleQueueAvatarTransition(node, run)
  requireAvatarPlayer(run, "queue_avatar_transition"):queueAvatarTransition(node.transition)
  return Runtime.OUTCOME_CONTINUE
end

local function handleApplyAvatarTransitions(_, run)
  requireAvatarPlayer(run, "apply_avatar_transitions"):applyAvatarTransitions()
  return Runtime.OUTCOME_CONTINUE
end

local function handleRandom(node, run)
  local roll = run.services.world.rng:nextInt(node.maxExclusive)
  semanticsFor(run).writeRef(node.result, roll, run)
  return Runtime.OUTCOME_CONTINUE
end

-- The single movement-start path shared by the asynchronous
-- (`apply_movement`) and blocking (`move`) forms: resolve the actor,
-- enforce foreground-player and actor-busy ownership, create the task, and
-- register it in the environment's movement generation so barriers and
-- pause logic observe it. The blocking form records the task id and returns
-- the block outcome. Completion cleanup for both forms lives in the task's
-- poll: the nonblocking form completes through the scheduler, the blocking
-- form unregisters before reporting its completion result.
---@param run table<string, unknown>
---@param node table<string, unknown>
---@param blocking boolean
---@return string outcome
local function startMovement(run, node, blocking)
  local actorId = semanticsFor(run).requireActor(node.actor, run)
  requireForegroundPlayer(run, actorId)
  -- The actor-busy check and the movement-generation registration are owned
  -- by the task-creation boundary (MovementTask.create + Scheduler:createTask),
  -- so both the blocking and nonblocking move forms share them.
  local taskId = run.scheduler:createTask("movement", {
    actor = actorId,
    sequence = node.movement,
    movementId = node.movementId,
    blocking = blocking,
  }, run.instance, run.tick, run.input)
  if blocking then
    run.blockTaskId = taskId
    return Runtime.OUTCOME_BLOCK
  end
  return Runtime.OUTCOME_CONTINUE
end

local function handleApplyMovement(node, run)
  return startMovement(run, node, false)
end

-- Generic blocking ops: dispatch through the task registry. The task types
-- and their implementations land with their owning task modules (dialogue,
-- movement, audio, fade, warp); an unregistered type is an attributed fault.
local function handleWaitSound(node, run)
  return blockOnTask(run, "sound_wait", { node = node })
end

local function handleWaitCry(node, run)
  return blockOnTask(run, "sound_wait", { node = node })
end

local function handleWaitFanfare(node, run)
  return blockOnTask(run, "sound_wait", { node = node })
end

local function handleWaitFade(node, run)
  return blockOnTask(run, "fade", { node = node })
end

local function handleWaitTicks(node, run)
  if node.countdownVariable ~= nil then
    -- Observable countdown mirror: the source command writes the frame count
    -- into the destination variable at execution time (ScrCmd_Wait); write it
    -- now and let the task decrement it on each poll so later reads see the
    -- live countdown.
    local id = semanticsFor(run).resolveIdOperand(node.countdownVariable, run)
    run.services.world:setVar(id, node.ticks)
    return blockOnTask(run, "wait_ticks", { node = node, countdownVariable = id })
  end
  return blockOnTask(run, "wait_ticks", { node = node })
end
local function handleWaitInput(node, run)
  return blockOnTask(run, "wait_input", { node = node })
end
local function handleWaitInputOrTicks(node, run)
  return blockOnTask(run, "wait_input_or_ticks", { node = node })
end
local function handleSay(node, run)
  requireForeground(run, "say")
  return blockOnTask(run, "dialogue", { node = node })
end
local function handleMessage(node, run)
  requireForeground(run, "message")
  if node.waitForPrint == false then
    -- Nonblocking print: open and start the printer same tick, then continue.
    -- A missing dialogue service is an attributed fault, never a silent skip,
    -- and the instance's buffered text args ride alongside node bindings
    -- exactly as on the blocking DialogueTask path.
    local host = requireService(run, "dialogue")
    -- LuaLS cannot see through Errors.raise; requireService never returns nil.
    ---@cast host table<string, unknown>
    host:openMessage(node)
    host:startPrint(node.message, node.bindings or {}, run.instance.textArgs or {})
    return Runtime.OUTCOME_CONTINUE
  end
  return blockOnTask(run, "dialogue", { node = node })
end
local function handleAskYesNo(node, run)
  requireForeground(run, "ask_yes_no")
  return blockOnTask(run, "ask_yes_no", { node = node })
end
local function handleChoose(node, run)
  requireForeground(run, "choose")
  local items = {}
  for luaIndex, item in ipairs(node.items) do
    items[luaIndex] = {
      text = semanticsFor(run).evaluateMessage(item.text, run),
      value = semanticsFor(run).evaluateValue(item.value, run),
      metadata = item.metadata,
    }
  end
  local cancelValue = nil
  if node.cancelValue ~= nil then
    cancelValue = semanticsFor(run).evaluateValue(node.cancelValue, run)
  end
  local request = requireScriptMenu(run):choose({
    items = items,
    cancellable = node.cancellable,
    cancelValue = cancelValue,
    initialCursor = node.initialCursor,
    placement = node.placement,
    result = node.result,
  })
  assert(type(request) == "table" and type(request.items) == "table", "script menu host returned an invalid request")
  return blockOnTask(run, "menu", { menu = request }, request.result)
end
local function handleMenuBegin(node, run)
  requireForeground(run, "menu_begin")
  if run.instance.menuBuilder ~= nil then
    Errors.raise(ScriptErrors.SCRIPT_MENU_ALREADY_BUILDING, "a script menu is already being built")
  end
  run.instance.menuBuilder = requireScriptMenu(run):beginMenu({
    messageSource = node.messageSource,
    sourcePlacement = node.sourcePlacement,
    initialCursor = node.initialCursor,
    cancellable = node.cancellable,
    result = node.result,
  })
  return Runtime.OUTCOME_YIELD_TICK
end
local function handleMenuAdd(node, run)
  requireForeground(run, "menu_add")
  requireScriptMenu(run):addItem(run.instance.menuBuilder, {
    messageId = semanticsFor(run).evaluateValue(node.messageId, run),
    vanillaMetadata = semanticsFor(run).evaluateValue(node.vanillaMetadata, run),
    value = semanticsFor(run).evaluateValue(node.value, run),
  })
  return Runtime.OUTCOME_CONTINUE
end
local function handleMenuExec(_, run)
  requireForeground(run, "menu_exec")
  local request = requireScriptMenu(run):execute(run.instance.menuBuilder)
  assert(type(request) == "table" and type(request.items) == "table", "script menu host returned an invalid request")
  run.instance.menuBuilder = nil
  return blockOnTask(run, "menu", { menu = request }, request.result)
end
local function handleWaitMovement(node, run)
  return blockOnTask(run, "movement_barrier", { node = node })
end
local function handleMove(node, run)
  return startMovement(run, node, true)
end
local function handleWarp(node, run)
  requireForeground(run, "warp")
  return blockOnTask(run, "warp", { node = node })
end

local function handleActorOscillate(node, run)
  local actorId = semanticsFor(run).requireActor(node.actor, run)
  local cycles = semanticsFor(run).evaluateValue(node.cycles, run)
  local degreesPerTick = semanticsFor(run).evaluateValue(node.degreesPerTick, run)
  local amplitudeX = semanticsFor(run).evaluateValue(node.amplitudeX, run)
  local amplitudeZ = semanticsFor(run).evaluateValue(node.amplitudeZ, run)
  return blockOnTask(run, "actor_oscillation", {
    actor = actorId,
    cycles = cycles,
    degreesPerTick = degreesPerTick,
    amplitudeX = amplitudeX,
    amplitudeZ = amplitudeZ,
  })
end

local function handleUnsupported(node, run)
  Errors.raise(ScriptErrors.SCRIPT_UNSUPPORTED_REACHABLE, "reachable unsupported node", {
    scriptId = run.instance.scriptId,
    command = node.command,
    originalName = node.originalName,
    sourceOffset = node.sourceOffset,
  })
end

local function handlePlaySound(node, run)
  requireService(run, "audio"):play(semanticsFor(run).evaluateValue(node.sound, run))
  return Runtime.OUTCOME_CONTINUE
end
local function handleStopSound(node, run)
  requireService(run, "audio"):stop(semanticsFor(run).evaluateValue(node.sound, run))
  return Runtime.OUTCOME_CONTINUE
end
local function handlePlayMusic(node, run)
  requireService(run, "audio"):playMusic(node.music)
  return Runtime.OUTCOME_CONTINUE
end
local function handleStopMusic(_, run)
  -- The semantic stop_music operation takes no operand (the StopBGM
  -- operand is an erasure at lowering); the currently playing BGM stops.
  requireService(run, "audio"):stopMusic()
  return Runtime.OUTCOME_CONTINUE
end
local function handleResetMusic(_, run)
  requireService(run, "audio"):resetMusic()
  return Runtime.OUTCOME_CONTINUE
end
local function handleTemporaryMusic(node, run)
  requireService(run, "audio"):temporaryMusic(node.music)
  return Runtime.OUTCOME_CONTINUE
end
local function handlePlayCry(node, run)
  requireService(run, "audio"):playCry(
    semanticsFor(run).evaluateValue(node.species, run),
    semanticsFor(run).evaluateValue(node.pattern, run)
  )
  return Runtime.OUTCOME_CONTINUE
end
local function handlePlayFanfare(node, run)
  requireService(run, "audio"):playFanfare(semanticsFor(run).evaluateValue(node.fanfare, run))
  return Runtime.OUTCOME_CONTINUE
end
local function handleFadeScreen(node, run)
  requireService(run, "screen"):startFade({
    duration = node.duration,
    speed = node.speed,
    direction = node.direction,
    color = node.color,
  })
  return Runtime.OUTCOME_CONTINUE
end
local function handleFadeMusicOut(node, run)
  -- The fade node starts the fade in its execution tick and blocks until
  -- the audio service reports the global music fade inactive (the source
  -- command's combined start-and-native-wait semantics).
  return blockOnTask(run, "music_fade", { node = node })
end
local function handleFadeMusicIn(node, run)
  return blockOnTask(run, "music_fade", { node = node })
end
local function handleProcessSoundplate(_, run)
  requireService(run, "audio"):processSoundplate()
  return Runtime.OUTCOME_CONTINUE
end
local function handleShakeCamera(node, run)
  requireService(run, "camera"):startShake(node)
  return Runtime.OUTCOME_CONTINUE
end
local function handleSetSpawn(node, run)
  requireService(run, "maps"):setSpawn(node.spawn)
  return Runtime.OUTCOME_CONTINUE
end
local function handleSetSpecialSpawn(node, run)
  requireService(run, "maps"):setSpecialSpawn({
    map = semanticsFor(run).evaluateValue(node.map, run),
    fieldX = semanticsFor(run).evaluateValue(node.fieldX, run),
    fieldZ = semanticsFor(run).evaluateValue(node.fieldZ, run),
    warpId = node.warpId,
    direction = node.direction,
  })
  return Runtime.OUTCOME_CONTINUE
end
local function handleOpenMessage(node, run)
  requireService(run, "dialogue"):openMessage(node)
  return Runtime.OUTCOME_CONTINUE
end

-- DirectionSignpost (55): store the source appearance, select SHOW and
-- execute it in-handler exactly like the source command's inline
-- Signpost_DoCurrentCommand call, then read/expand and print the message
-- instantly in the signpost window. The unused out operand is never written.
-- Yields one tick (the source returns TRUE without installing a waiter).
local function handleSignpostDirection(node, run)
  requireForeground(run, "signpost_direction")
  local host = requireService(run, "signpost")
  -- LuaLS cannot see through Errors.raise; requireService never returns nil.
  ---@cast host ScriptSignpostHost
  host:setSourceAppearance(node.sourceAppearance)
  host:setCommand("show")
  host:advance()
  host:printInstant(node.message, nil, run.instance.textArgs or {})
  return Runtime.OUTCOME_YIELD_TICK
end

-- SetSignpostMap (56): store the source appearance and queue SHOW without
-- executing it (the field signpost update runs the queued command later).
-- Yields one tick.
local function handleSignpostSet(node, run)
  requireForeground(run, "signpost_set")
  local host = requireService(run, "signpost")
  ---@cast host ScriptSignpostHost
  host:setSourceAppearance(node.sourceAppearance)
  host:setCommand("show")
  return Runtime.OUTCOME_YIELD_TICK
end

-- SetSignpostAction (57): assign the semantic command to the signpost
-- window. Signpost_SetCommand is a bare assignment with no busy guard, so a
-- running action is superseded; the fixed-tick controller executes it at the
-- next field update (never in-handler) and returns the command to nop when
-- the action completes. Yields one tick.
local function handleSignpostCommand(node, run)
  requireForeground(run, "signpost_command")
  local host = requireService(run, "signpost")
  ---@cast host ScriptSignpostHost
  host:setCommand(node.command)
  return Runtime.OUTCOME_YIELD_TICK
end

-- WaitSignpostAction (58): block until the signpost command is idle. On
-- entry the command may already be idle (the source returns immediately), in
-- which case the script continues in the same tick; otherwise a registered
-- task polls the host's semantic idle query each tick and completes only
-- when the command is idle again. Opcode 58 has no result operand, so no
-- result reference rides along.
local function handleWaitSignpostAction(_, run)
  requireForeground(run, "wait_signpost_action")
  local host = requireService(run, "signpost")
  ---@cast host ScriptSignpostHost
  if host:isCommandIdle() then
    return Runtime.OUTCOME_CONTINUE
  end
  return blockOnTask(run, "wait_signpost_action", {})
end

-- TrainerTips (59): print the resolved message into the existing signpost
-- window at the player's configured text speed and block on the registered
-- task. The task owns the source input semantics (directional interrupt
-- stops the printer, turns the player, and completes 0; A/B fills the
-- print and completes 2; normal completion writes 2 through the scheduler
-- result reference) and never writes world variables directly.
local function handleTrainerTipsPrint(node, run)
  requireForeground(run, "trainer_tips_print")
  requireService(run, "signpost")
  return blockOnTask(run, "trainer_tips_print", { node = node })
end

-- WaitSignpost (60): always install a waiter for the A/B/directional
-- dismissal of the presented signpost window. The task completes 0 through
-- the scheduler result reference on any dismissal edge.
local function handleWaitSignpost(node, run)
  requireForeground(run, "wait_signpost")
  requireService(run, "signpost")
  return blockOnTask(run, "wait_signpost", { node = node })
end

-- The high-level sign ops route their requested appearance (a semantic
-- value or a catalogued style id) through the window style catalogue
-- service: the style id is stamped into the controller, and a style that
-- does not exist is an attributed script fault, never a presentation crash
-- at draw time.
---@param run table<string, unknown>
---@param appearance string
---@return string styleId
local function resolveSignpostStyle(run, appearance)
  local styles = requireService(run, "windowStyles")
  ---@cast styles table<string, unknown>
  -- LuaLS cannot see through Errors.raise; requireService never returns nil.
  local styleId = semanticsFor(run).semanticStyleId(appearance) or appearance
  if styles:resolve(styleId) == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_STYLE_UNKNOWN,
      "window style is not registered: " .. tostring(styleId),
      { scriptId = run.instance.scriptId, styleId = styleId }
    )
  end
  return styleId
end

-- The high-level S.sign operation: present the signpost window with the
-- requested style id (no source type/map data), print the message
-- instantly, and block on the registered sign task until an A/B or
-- directional dismissal closes the window. The open composes the same
-- host/controller primitives the imported operations use; the sign task
-- owns the complete open -> dismiss -> close lifecycle, so the sign is
-- always blocking.
local function handleSign(node, run)
  requireForeground(run, "sign")
  local host = requireService(run, "signpost")
  ---@cast host ScriptSignpostHost
  host:setStyleId(resolveSignpostStyle(run, node.appearance))
  host:setCommand("show")
  host:advance()
  host:printInstant(node.message, nil, run.instance.textArgs or {})
  return blockOnTask(run, "sign", { node = node })
end

-- The high-level S.trainerTip operation: present the signpost window with
-- the requested style id, type the message at the player's configured text
-- speed, and block on the registered sign task. The task waits for the
-- print and then for an A/B/directional dismissal; a direction pressed
-- while the print is live is the source interruption (printer stops, player
-- turns, window closes).
local function handleTrainerTip(node, run)
  requireForeground(run, "trainer_tip")
  local host = requireService(run, "signpost")
  ---@cast host ScriptSignpostHost
  host:setStyleId(resolveSignpostStyle(run, node.appearance))
  host:setCommand("show")
  host:advance()
  host:printTyped(node.message, nil, run.instance.textArgs or {})
  return blockOnTask(run, "sign", { node = node })
end
local function handleCloseMessage(node, run)
  requireService(run, "dialogue"):close(node.erase ~= false)
  return Runtime.OUTCOME_CONTINUE
end
local function handleHoldMessage(_, run)
  requireService(run, "dialogue"):hold()
  return Runtime.OUTCOME_CONTINUE
end
local function handleShowWaitingIcon(_, run)
  requireService(run, "dialogue"):showWaitingIcon()
  return Runtime.OUTCOME_CONTINUE
end
local function handleHideWaitingIcon(_, run)
  requireService(run, "dialogue"):hideWaitingIcon()
  return Runtime.OUTCOME_CONTINUE
end

HANDLERS.noop = handleNoop
HANDLERS.label = handleLabel
HANDLERS.stop = handleStop
HANDLERS.request_start_menu = handleRequestStartMenu
HANDLERS.yield_tick = handleYieldTick
HANDLERS.set_auxiliary_ui_visible = handleSetAuxiliaryUiVisible
HANDLERS.context_choice = handleContextChoice
HANDLERS["if"] = handleIf
HANDLERS.switch = handleSwitch
HANDLERS["goto"] = handleGoto
HANDLERS.goto_if = handleGotoIf
HANDLERS.compare = handleCompare
HANDLERS.goto_compared = handleGotoCompared
HANDLERS.call_compared = handleCallCompared
HANDLERS.call = handleCall
HANDLERS.goto_script = handleGotoScript
HANDLERS["return"] = handleReturn
HANDLERS.next = handleNext
HANDLERS.signal_caller = handleSignalCaller
HANDLERS.call_common = handleCallCommon
HANDLERS.set_flag = handleSetFlag
HANDLERS.clear_flag = handleClearFlag
HANDLERS.change_weather = handleChangeWeather
HANDLERS.set_var = handleSetVar
HANDLERS.copy_var = handleCopyVar
HANDLERS.add_var = handleAddVar
HANDLERS.sub_var = handleSubVar
HANDLERS.set_local = handleSetLocal
HANDLERS.copy_local = handleCopyLocal
HANDLERS.add_local = handleAddLocal
HANDLERS.sub_local = handleSubLocal
HANDLERS.buffer_text = handleBufferText
HANDLERS.give_mon = handleGiveMon
HANDLERS.choose_starter = handleChooseStarter
HANDLERS.return_loan_mon = handleReturnLoanMon
HANDLERS.set_mon_move = handleSetMonMove
HANDLERS.mon_has_move = handleMonHasMove
HANDLERS.party_slot_with_move = handlePartySlotWithMove
HANDLERS.count_mon_moves = handleCountMonMoves
HANDLERS.mon_forget_move = handleMonForgetMove
HANDLERS.mon_get_move = handleMonGetMove
HANDLERS.party_count = handlePartyCount
HANDLERS.party_count_not_egg = handlePartyCountNotEgg
HANDLERS.party_count_egg = handlePartyCountEgg
HANDLERS.count_alive_mons = handleCountAliveMons
HANDLERS.party_count_at_or_below_level = handlePartyCountAtOrBelowLevel
HANDLERS.count_species = handleCountSpecies
HANDLERS.party_slot_with_species = handlePartySlotWithSpecies
HANDLERS.party_slot_with_nature = handlePartySlotWithNature
HANDLERS.party_slot_with_fateful_encounter = handlePartySlotWithFatefulEncounter
HANDLERS.party_mon_species = handlePartyMonSpecies
HANDLERS.party_mon_types = handlePartyMonTypes
HANDLERS.party_mon_level = handlePartyMonLevel
HANDLERS.party_mon_is_mine = handlePartyMonIsMine
HANDLERS.party_mon_nature = handlePartyMonNature
HANDLERS.party_mon_friendship = handlePartyMonFriendship
HANDLERS.mon_add_friendship = handleMonAddFriendship
HANDLERS.mon_sub_friendship = handleMonSubFriendship
HANDLERS.party_mon_gender = handlePartyMonGender
HANDLERS.party_mon_contest_value = handlePartyMonContestValue
HANDLERS.mon_add_contest_value = handleMonAddContestValue
HANDLERS.party_mon_form = handlePartyMonForm
HANDLERS.set_mon_form = handleSetMonForm
HANDLERS.party_mon_ribbon_count = handlePartyMonRibbonCount
HANDLERS.party_ribbon_count = handlePartyRibbonCount
HANDLERS.party_has_pokerus = handlePartyHasPokerus
HANDLERS.party_has_held_item = handlePartyHasHeldItem
HANDLERS.party_lead = handlePartyLead
HANDLERS.party_lead_alive = handlePartyLeadAlive
HANDLERS.party_legal_check = handlePartyLegalCheck
HANDLERS.check_kyogre_groudon = handleCheckKyogreGroudon
HANDLERS.heal_party = handleHealParty
HANDLERS.bag_add_item = handleBagAddItem
HANDLERS.bag_take_item = handleBagTakeItem
HANDLERS.bag_has_space = handleBagHasSpace
HANDLERS.bag_has_item = handleBagHasItem
HANDLERS.item_is_tmhm = handleItemIsTmhm
HANDLERS.item_get_pocket = handleItemGetPocket
HANDLERS.bag_get_quantity = handleBagGetQuantity
HANDLERS.party_select = handlePartySelect
HANDLERS.party_select_result = handlePartySelectResult
HANDLERS.follower_is_active = handleFollowerIsActive
HANDLERS.follower_partner_state = handleFollowerPartnerState
HANDLERS.follower_face_player = handleFollowerFacePlayer
HANDLERS.follower_set_paused = handleFollowerSetPaused
HANDLERS.follower_wait = handleFollowerWait
HANDLERS.follower_set_movement_type = handleFollowerSetMovementType
HANDLERS.follower_reposition = handleFollowerReposition
HANDLERS.follower_is_event_trigger = handleFollowerIsEventTrigger
HANDLERS.follower_transition = handleFollowerTransition
HANDLERS.place_starter_balls = handlePlaceStarterBalls
HANDLERS.lock_player = handleLockPlayer
HANDLERS.release_player = handleReleasePlayer
HANDLERS.lock_all = handleLockAll
HANDLERS.release_all = handleReleaseAll
HANDLERS.lock_actor = handleLockActor
HANDLERS.release_actor = handleReleaseActor
HANDLERS.face_player = handleFacePlayer
HANDLERS.face = handleFace
HANDLERS.show_object = handleShowObject
HANDLERS.hide_object = handleHideObject
HANDLERS.set_object_position = handleSetObjectPosition
HANDLERS.set_object_facing = handleSetObjectFacing
HANDLERS.set_object_movement_type = handleSetObjectMovementType
HANDLERS.get_player_coords = handleGetPlayerCoords
HANDLERS.get_object_coords = handleGetObjectCoords
HANDLERS.get_player_facing = handleGetPlayerFacing
HANDLERS.queue_avatar_transition = handleQueueAvatarTransition
HANDLERS.apply_avatar_transitions = handleApplyAvatarTransitions
HANDLERS.random = handleRandom
HANDLERS.apply_movement = handleApplyMovement
HANDLERS.wait_ticks = handleWaitTicks
HANDLERS.wait_input = handleWaitInput
HANDLERS.wait_input_or_ticks = handleWaitInputOrTicks
HANDLERS.say = handleSay
HANDLERS.message = handleMessage
HANDLERS.ask_yes_no = handleAskYesNo
HANDLERS.choose = handleChoose
HANDLERS.menu_begin = handleMenuBegin
HANDLERS.menu_add = handleMenuAdd
HANDLERS.menu_exec = handleMenuExec
HANDLERS.wait_movement = handleWaitMovement
HANDLERS.move = handleMove
HANDLERS.wait_sound = handleWaitSound
HANDLERS.wait_cry = handleWaitCry
HANDLERS.wait_fanfare = handleWaitFanfare
HANDLERS.wait_fade = handleWaitFade
HANDLERS.warp = handleWarp
HANDLERS.unsupported = handleUnsupported
HANDLERS.play_sound = handlePlaySound
HANDLERS.stop_sound = handleStopSound
HANDLERS.play_music = handlePlayMusic
HANDLERS.stop_music = handleStopMusic
HANDLERS.reset_music = handleResetMusic
HANDLERS.temporary_music = handleTemporaryMusic
HANDLERS.play_cry = handlePlayCry
HANDLERS.play_fanfare = handlePlayFanfare
HANDLERS.fade_screen = handleFadeScreen
HANDLERS.fade_music_out = handleFadeMusicOut
HANDLERS.fade_music_in = handleFadeMusicIn
HANDLERS.process_soundplate = handleProcessSoundplate
HANDLERS.shake_camera = handleShakeCamera
HANDLERS.set_spawn = handleSetSpawn
HANDLERS.set_special_spawn = handleSetSpecialSpawn
HANDLERS.open_message = handleOpenMessage
HANDLERS.signpost_direction = handleSignpostDirection
HANDLERS.signpost_set = handleSignpostSet
HANDLERS.signpost_command = handleSignpostCommand
HANDLERS.wait_signpost_action = handleWaitSignpostAction
HANDLERS.trainer_tips_print = handleTrainerTipsPrint
HANDLERS.wait_signpost = handleWaitSignpost
HANDLERS.sign = handleSign
HANDLERS.trainer_tip = handleTrainerTip
HANDLERS.actor_oscillate = handleActorOscillate
HANDLERS.close_message = handleCloseMessage
HANDLERS.hold_message = handleHoldMessage
HANDLERS.show_waiting_icon = handleShowWaitingIcon
HANDLERS.hide_waiting_icon = handleHideWaitingIcon

-- Execute one graph node against the run state. The outcome is one of the
-- outcome constants; a blocking node records its task id in run.blockTaskId.
---@param node table<string, unknown>
---@param run table<string, unknown>
---@return string
function Runtime.executeNode(node, run)
  run.node = node
  local handler = assert(HANDLERS[node.op], "no runtime handler for op " .. tostring(node.op))
  return handler(node, run)
end

-- The run loop calls this when a linear tail has no successor node: a
-- composition frame advances to the next chain entry, a call frame behaves
-- like `return`, and a plain script tail completes the instance.
---@param run table<string, unknown>
---@return string
function Runtime.fallOffEnd(run)
  local instance = run.instance
  local frame = instance:topFrame()
  if frame.composition ~= nil and frame.chain ~= nil then
    return advanceChain(run, frame)
  end
  if frame.returnNodeId ~= nil then
    local popped = instance:popFrame()
    instance:resumeCaller(popped)
    return Runtime.OUTCOME_CONTINUE
  end
  return Runtime.OUTCOME_STOP
end

return Runtime
