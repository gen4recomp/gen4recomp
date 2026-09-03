-- Semantic lowering : classifies every raw
-- instruction from the pinned implementations and folds supported opcodes
-- into DSL steps with attached provenance. Execution classifications
-- (continue_same_tick / yield_next_tick / native_wait / stop / unsupported)
-- come from the command catalog; folding (Compare+GoToIf -> condition,
-- NPCMsg+WaitButton+CloseMsg -> say) never erases an unmodeled yield
-- boundary. Every instruction keeps source offsets and opcodes in
-- provenance. Pure domain module: no love dependency.

local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local ScriptIdentity = require("libs.assets.src.ScriptIdentity")
local Operands = require("romdump.src.digest.script.lowering.Operands")
local ControlHandlers = require("romdump.src.digest.script.lowering.ControlHandlers")
local FieldHandlers = require("romdump.src.digest.script.lowering.FieldHandlers")
local AudioHandlers = require("romdump.src.digest.script.lowering.AudioHandlers")

local SemanticLowering = {}

-- HGSS GoToIf condition codes.
local CONDITION_OPERATORS = { [0] = "lt", [1] = "eq", [2] = "gt", [3] = "le", [4] = "ge", [5] = "ne" }

-- The explicit unsupported node for one instruction. Commands the
-- authoritative catalog marks deferred keep their dependency category and
-- source-backed explanation on the node; anything else keeps the generic
-- lowering reason. The runtime fails only if a script reaches the node.
---@param ins table<string, unknown>
---@param reason string
---@return table<string, unknown>
local function unsupportedStep(ins, reason)
  local arguments = {}
  for index, operand in ipairs(ins.operands) do
    arguments[index] = Operands.operandValue(operand)
  end
  local deferral = CommandCatalog.deferredReason(ins.opcode)
  if CommandCatalog.disposition(ins.opcode) == "deferred" and deferral ~= nil then
    reason = "deferred (" .. deferral .. ")"
    local note = CommandCatalog.deferredNote(ins.opcode)
    if note ~= nil then
      reason = reason .. ": " .. note
    end
  end
  return {
    op = "unsupported",
    command = ins.opcode,
    originalName = CommandCatalog.name(ins.opcode),
    arguments = arguments,
    sourceOffset = ins.offset,
    reason = reason,
  }
end

-- One step with provenance.
---@param step table<string, unknown>
---@param offsets integer[]
---@param opcodes integer[]
---@return table<string, unknown>
local function withProvenance(step, offsets, opcodes)
  step.provenance = { offsets = offsets, opcodes = opcodes }
  return step
end

-- Compose the source-semantic handler families once, rejecting duplicate opcodes.
local function mergeHandlerRegistry(target, sourceRegistry)
  for opcode, handler in pairs(sourceRegistry) do
    assert(target[opcode] == nil, "duplicate script lowering handler for opcode " .. tostring(opcode))
    target[opcode] = handler
  end
end

local function buildHandlers()
  local handlers = {}
  mergeHandlerRegistry(handlers, ControlHandlers)
  mergeHandlerRegistry(handlers, FieldHandlers)
  mergeHandlerRegistry(handlers, AudioHandlers)
  return handlers
end

local HANDLERS = buildHandlers()

-- Fold a compare/flag instruction with a following GoToIf/CallIf into one
-- conditional item, or nil when the pattern does not apply (the compare
-- result is consumed by the immediately following branch).
---@param ins table<string, unknown>
---@param branch table<string, unknown>
---@return table<string, unknown>|nil item
local function foldConditional(ins, branch)
  local conditionCode = Operands.operandValue(branch.operands[1])
  local operator = CONDITION_OPERATORS[conditionCode]
  if operator == nil then
    return nil
  end
  local target = Operands.operandValue(branch.operands[2])
  local condition
  if ins.opcode == 17 or ins.opcode == 18 then
    condition = {
      condition = "compare",
      operator = operator,
      left = Operands.varRef(ins.operands[1]),
      right = Operands.varRef(ins.operands[2]),
    }
  elseif ins.opcode == 32 then
    local expected
    if conditionCode == 1 then
      expected = true
    elseif conditionCode == 0 or conditionCode == 5 then
      expected = false
    else
      return nil
    end
    condition = { condition = "flag", id = Operands.operandValue(ins.operands[1]), expected = expected }
  else
    return nil
  end
  return {
    op = branch.opcode == 29 and "call_if" or "if_cond",
    condition = condition,
    target = target,
    provenance = {
      offsets = { ins.offset, branch.offset },
      opcodes = { ins.opcode, branch.opcode },
    },
  }
end

-- The NPCMsg + WaitButton + CloseMsg triplet folds into `say` with the hgss
-- timing profile. Returns the say item plus the
-- number of instructions consumed (3), or nil.
---@param messageStep table<string, unknown>
---@param waitIns table<string, unknown>
---@param closeIns table<string, unknown>
---@return table<string, unknown>|nil say
local function foldSay(messageStep, waitIns, closeIns)
  if waitIns.opcode ~= 50 then
    return nil
  end
  if closeIns.opcode ~= 53 then
    return nil
  end
  return {
    op = "say",
    message = messageStep.message,
    provenance = {
      offsets = { messageStep.provenance.offsets[1], waitIns.offset, closeIns.offset },
      opcodes = { messageStep.provenance.opcodes[1], waitIns.opcode, closeIns.opcode },
    },
  }
end

-- An unconsumed NPCMsg/GenderMsgBox becomes the primitive `message` op with
-- the native print wait (opcodes 45 and 132).
---@param step table<string, unknown>
---@return table<string, unknown>
local function toMessageStep(step)
  local message = step.message
  return {
    op = "message",
    message = message,
    waitForPrint = true,
  }
end

-- Lower one script's instruction list into semantic items. `memberIr` holds
-- the movement blocks. Folding never erases an unmodeled yield boundary.
-- `opts.stdCatalog` (SourceCatalog) resolves CallStd targets; without it
-- targets stay mechanical `common.std_<id>`. The returned table carries the
-- `omissions` (Nop/Dummy erasures) for the verifier.
---@param script table<string, unknown>
---@param memberIr table<string, unknown>
---@param opts table<string, unknown>
---@return table<string, unknown> lowered
function SemanticLowering.lowerScript(script, memberIr, opts)
  local items = {}
  local unsupported = {}
  local omissions = {}
  local index = 1
  local instructions = script.instructions

  local ctx = {
    stdCatalog = opts.stdCatalog,
  }

  -- Script-local labels: branch and call targets must resolve inside the
  -- script. The pinned sources share tails across scripts: a branch may
  -- jump into another script's label region or into another script's entry.
  -- Such a branch becomes a runtime-resolved cross-script reference
  -- (`goto_script`, or `call` with a label) naming the target script by its
  -- public id, resolved through the composition registry at runtime like
  -- the raw-Lua escape hatch. A target that resolves to no script in the
  -- member stays an explicit unsupported node.
  local scriptLabels = {}
  for _, ins in ipairs(instructions) do
    if ins.label ~= nil then
      scriptLabels[ins.label] = true
    end
  end
  local memberLabels = {}
  local memberBodyLabels = {}
  for memberIndex, memberScript in pairs(memberIr.scripts) do
    memberBodyLabels[memberScript.label] = memberIndex
    for _, ins in ipairs(memberScript.instructions) do
      if ins.label ~= nil then
        memberLabels[ins.label] = memberIndex
      end
    end
  end
  local function publicIdFor(ownerIndex)
    if opts.publicIdFor ~= nil then
      return opts.publicIdFor(memberIr.member, ownerIndex)
    end
    return ScriptIdentity.formatVanilla(memberIr.member, ownerIndex)
  end
  local CONTROL_TARGET_OPS = {
    ["goto"] = true,
    goto_if = true,
    if_cond = true,
    call_if = true,
    call = true,
    goto_compared = true,
    call_compared = true,
  }
  local function resolveControlTargets(list)
    for i, item in ipairs(list) do
      if item.target ~= nil and CONTROL_TARGET_OPS[item.op] then
        local target = item.target
        local owner
        if type(target) == "string" and not scriptLabels[target] then
          owner = memberLabels[target] or memberBodyLabels[target]
        end
        if owner ~= nil then
          local scriptId = publicIdFor(owner)
          local label = memberLabels[target] ~= nil and target or nil
          local provenance = item.provenance
          if item.op == "goto" then
            local step = { op = "goto_script", script = scriptId, provenance = provenance }
            if label ~= nil then
              step.label = label
            end
            list[i] = step
          elseif item.op == "call" then
            local step = { op = "call", target = scriptId, provenance = provenance }
            if label ~= nil then
              step.label = label
            end
            list[i] = step
          elseif item.op == "call_if" then
            list[i] = {
              op = "if",
              condition = item.condition,
              yes = { { op = "call", target = scriptId, label = label } },
              no = {},
              provenance = provenance,
            }
          elseif item.op == "goto_if" or item.op == "if_cond" then
            -- A conditional cross-script jump.
            local jump = { op = "goto_script", script = scriptId }
            if label ~= nil then
              jump.label = label
            end
            list[i] = {
              op = "if",
              condition = item.condition,
              yes = { jump },
              no = {},
              provenance = provenance,
            }
          else
            -- The compare-state fallback forms preserve the source compare
            -- state; a cross-script target rides the same runtime state via
            -- the additive script/label fields.
            local step = {
              op = item.op,
              operator = item.operator,
              script = scriptId,
              provenance = provenance,
            }
            if label ~= nil then
              step.label = label
            end
            list[i] = step
          end
        elseif type(target) ~= "string" or not scriptLabels[target] then
          local provenance = item.provenance
          local branchOffset = provenance and provenance.offsets[#provenance.offsets]
          local branchOpcode = provenance and provenance.opcodes[#provenance.opcodes]
          local step = {
            op = "unsupported",
            command = branchOpcode or 0,
            originalName = CommandCatalog.name(branchOpcode or 0),
            arguments = {},
            sourceOffset = branchOffset or 0,
            reason = "branch target does not exist in this member",
            provenance = provenance,
          }
          list[i] = step
          unsupported[#unsupported + 1] = step
        end
      end
    end
  end

  -- Label markers: the first instruction after an offset label carries it;
  -- the emitted item (or the fold consuming that instruction) receives a
  -- preceding label step so the structurer can resolve branch targets.
  local function pushLabel(ins)
    if ins.label ~= nil then
      items[#items + 1] = { op = "label", name = ins.label, offset = ins.offset }
    end
  end

  while index <= #instructions do
    local ins = instructions[index]
    local nextIns = instructions[index + 1]
    local handler = HANDLERS[ins.opcode]
    local foldedAhead = false

    -- Compare/flag + GoToIf/CallIf fold (both remain same-tick). The fold
    -- never spans a labeled instruction: a branch target landing on the
    -- second instruction must enter at the branch (with the caller's
    -- compare state), not at the folded operation's start.
    if
      handler ~= nil
      and nextIns ~= nil
      and (nextIns.opcode == 28 or nextIns.opcode == 29)
      and (ins.opcode == 17 or ins.opcode == 18 or ins.opcode == 32)
      and nextIns.label == nil
    then
      local folded = foldConditional(ins, nextIns)
      if folded ~= nil then
        pushLabel(ins)
        pushLabel(nextIns)
        items[#items + 1] = folded
        index = index + 1
        foldedAhead = true
      end
    end

    -- NPCMsg/GenderMsgBox + WaitButton + CloseMsg -> say. Same labeled-entry
    -- rule: an entry point on the wait or close instruction keeps the three
    -- instructions separate.
    if
      not foldedAhead
      and handler ~= nil
      and nextIns ~= nil
      and instructions[index + 2] ~= nil
      and (ins.opcode == 45 or ins.opcode == 132 or ins.opcode == 47)
      and nextIns.label == nil
      and instructions[index + 2].label == nil
    then
      local step = handler(ins, memberIr, {}, ctx)
      if type(step) == "table" and (step.op == "npc_msg" or step.op == "npc_msg_var") then
        step = withProvenance(step, { ins.offset }, { ins.opcode })
        local say = foldSay(step, nextIns, instructions[index + 2])
        if say ~= nil then
          pushLabel(ins)
          pushLabel(nextIns)
          pushLabel(instructions[index + 2])
          items[#items + 1] = say
          index = index + 2
          foldedAhead = true
        end
      end
    end

    if foldedAhead then
      -- consumed by a fold
    elseif handler == nil then
      local step = unsupportedStep(ins, "opcode has no semantic lowering")
      step = withProvenance(step, { ins.offset }, { ins.opcode })
      pushLabel(ins)
      items[#items + 1] = step
      unsupported[#unsupported + 1] = step
    else
      local step = handler(ins, memberIr, { offsets = { ins.offset }, opcodes = { ins.opcode } }, ctx)
      if step == nil then
        -- An explicitly erased implementation-detail instruction (Nop and
        -- Dummy, rows 0-1): record the omission for the
        -- verifier's no-disappearing-command check.
        omissions[#omissions + 1] = { offset = ins.offset, opcode = ins.opcode }
      elseif step == "unfolded" then
        -- An unconsumed fold participant becomes its primitive step.
        local primitive
        if ins.opcode == 53 then
          primitive = { op = "close_message", erase = true }
        elseif ins.opcode == 28 or ins.opcode == 29 then
          local operator = CONDITION_OPERATORS[Operands.operandValue(ins.operands[1])] or "eq"
          primitive = {
            op = ins.opcode == 29 and "call_compared" or "goto_compared",
            operator = operator,
            target = Operands.operandValue(ins.operands[2]),
          }
        end
        if primitive ~= nil then
          primitive = withProvenance(primitive, { ins.offset }, { ins.opcode })
          pushLabel(ins)
          items[#items + 1] = primitive
        else
          local fallbackStep = {
            op = "unsupported",
            command = ins.opcode,
            originalName = CommandCatalog.name(ins.opcode),
            arguments = {},
            sourceOffset = ins.offset,
            reason = "unconsumed compare-state op without a DSL carrier",
          }
          fallbackStep = withProvenance(fallbackStep, { ins.offset }, { ins.opcode })
          pushLabel(ins)
          items[#items + 1] = fallbackStep
          unsupported[#unsupported + 1] = fallbackStep
        end
      elseif step ~= nil then
        local handled = false
        if type(step) == "table" and type(step.steps) == "table" then
          -- One instruction lowering to several canonical operations (e.g.
          -- MovePersonFacing: position then facing); all steps share the
          -- instruction's provenance.
          pushLabel(ins)
          for _, subStep in ipairs(step.steps) do
            if subStep.op == "yield_tick" then
              items[#items + 1] = subStep
            else
              items[#items + 1] = withProvenance(subStep, { ins.offset }, { ins.opcode })
            end
          end
          handled = true
        elseif step.op == "release_all" then
          -- The source command unconditionally yields one frame after
          -- unpausing. The synthesized yield has
          -- no source instruction of its own, so it carries no provenance
          -- (its node id is structural, avoiding a duplicate with the
          -- release node's src: id).
          pushLabel(ins)
          items[#items + 1] = withProvenance(step, { ins.offset }, { ins.opcode })
          items[#items + 1] = { op = "yield_tick" }
          handled = true
        elseif step.op == "npc_msg" or step.op == "npc_msg_var" then
          step = toMessageStep(step)
        end
        if not handled then
          step = withProvenance(step, { ins.offset }, { ins.opcode })
          pushLabel(ins)
          items[#items + 1] = step
          if step.op == "unsupported" then
            unsupported[#unsupported + 1] = step
          end
        end
      end
    end
    index = index + 1
  end
  resolveControlTargets(items)
  return { items = items, unsupported = unsupported, omissions = omissions }
end

return SemanticLowering
