-- Binary scr_seq member decoder : decodes a retail scr_seq
-- NARC member straight from the ROM dump. The retail member layout is a table
-- of relative u32 entries (entry[i] = scriptOffset - entryPos - 4) followed by
-- a u16 0xFD13 (SCRDEF_END) sentinel, with script bodies and movement blocks
-- interleaved at arbitrary four-aligned offsets. Branch/Call/ApplyMovement
-- operands are relative word offsets from the end of the instruction; message
-- operands are indices into the map's message bank (resolved by the compiler
-- through the pinned member-bank map). Header members (scriptHeaderBank) carry
-- no script table and return nil. Pure domain module: no love dependency.

local RawIr = require("romdump.src.digest.script.RawIr")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local MovementCommands = require("romdump.src.reference.hgss.movement_commands")
local BinaryView = require("libs.codec.src.BinaryView")
local ffi = require("ffi")

local ScriptBinaryDecoder = {}

local SCRDEF_END = 0xFD13
local MOVEMENT_END = 254

-- Opcodes whose word operand is a relative target from the end of the
-- instruction (operand index, 1-based).
local RELATIVE_OPERANDS = {
  [22] = 1, -- GoTo
  [23] = 2, -- ObjectGoTo
  [24] = 2, -- BGGoTo
  [25] = 2, -- DirectionGoTo
  [26] = 1, -- Call
  [28] = 2, -- GoToIf
  [29] = 2, -- CallIf
  [94] = 2, -- ApplyMovement (movement-block offset)
}

-- Message-printing opcodes: operand indices carrying a message index in the
-- map's bank (the bank itself never appears in the member).
local MESSAGE_OPERANDS = {
  [44] = { 1 }, -- NonNPCMsg
  [45] = { 1 }, -- NPCMsg
  [132] = { 1, 2 }, -- GenderMsgBox
}

-- Message-or-variable operands: ScrCmd_NonNPCMsgVar/NPCMsgVar read the
-- operand as a message id directly when it lies below VAR_BASE (0x4000,
-- GetVarPointer returns NULL there and VarGet yields the operand itself) and
-- as a variable reference otherwise.
local MESSAGE_VALUE_OPERANDS = {
  [46] = { 1 }, -- NonNPCMsgVar
  [47] = { 1 }, -- NPCMsgVar
}

-- Sound-sequence operands (SEQ_* names from sndseq.h).
local SOUND_OPERANDS = {
  [73] = { 1 }, -- PlaySE
  [74] = { 1 }, -- StopSE
  [75] = { 1 }, -- WaitSE
  [78] = { 1 }, -- PlayFanfare
  [80] = { 1 }, -- PlayBGM
  [81] = { 1 }, -- StopBGM
  [87] = { 1 }, -- TempBGM
}

-- Sound operands the pinned source reads through ScriptGetVar
-- (scrcmd_sound.c): a var-range operand names through the vars catalog, not
-- the sound catalog, so lowering can produce a value reference.
local VAR_SOUND_OPERANDS = {
  [73] = { 1 }, -- PlaySE
  [74] = { 1 }, -- StopSE
  [75] = { 1 }, -- WaitSE
  [78] = { 1 }, -- PlayFanfare
}

-- Flag operands (FLAG_* names from flags.h).
local FLAG_OPERANDS = {
  [30] = { 1 }, -- SetFlag
  [31] = { 1 }, -- ClearFlag
  [32] = { 1 }, -- CheckFlag
}

-- Variable ranges (vars.h): VARS [0x4000, 0x4400), SPECIAL_VARS [0x8000,
-- 0x8100). Operand numbers inside a range are variable references and are
-- named through the pinned vars catalog.
local VAR_RANGES = {
  { start = 0x4000, finish = 0x4400 },
  { start = 0x8000, finish = 0x8100 },
}

-- The warp map operand (maps.lua mapCode names).
local MAP_OPERANDS = {
  [176] = { 1 }, -- Warp
}

-- Respawn operands (SPAWN_* names from spawns.h).
local SPAWN_OPERANDS = {
  [280] = { 1 }, -- SetSpawn
}

---@param bytes string|BinaryView
---@return BinaryView
local function asView(bytes)
  if type(bytes) == "string" then
    return BinaryView.fromString(bytes, "script member")
  end
  return bytes
end

---@param view BinaryView
---@param oneBasedOffset integer
---@return integer
local function byte(view, oneBasedOffset)
  return view:u8(oneBasedOffset - 1)
end

-- Scan the entry table: `{ pos, entry, label }` per script in index order.
-- Returns an empty list when the member carries no script table (a header
-- member, or garbage).
---@param bytes string|BinaryView
---@return table[] entries
function ScriptBinaryDecoder.scanEntries(bytes)
  bytes = asView(bytes)
  local entries = {}
  local pos = 0
  while pos + 3 < bytes:length() do
    local low = byte(bytes, pos + 1) + byte(bytes, pos + 2) * 256
    if low == SCRDEF_END then
      break
    end
    local entry = byte(bytes, pos + 1)
      + byte(bytes, pos + 2) * 256
      + byte(bytes, pos + 3) * 65536
      + byte(bytes, pos + 4) * 16777216
    local label = pos + 4 + entry
    -- A real entry points forward into the script region, never back into
    -- the table itself.
    if label < pos + 4 or label + 1 > bytes:length() then
      break
    end
    entries[#entries + 1] = { pos = pos, entry = entry, label = label }
    pos = pos + 4
  end
  return entries
end

-- Decode one movement block at `offset`: u16 code + u16 args per action,
-- terminated by MOVEMENT_STEP_END (254) plus its zero arg.
---@param bytes BinaryView
---@param offset integer
---@param materialize boolean
---@return table<string, unknown>|nil block { offset, actions, terminated, size }
local function decodeMovement(bytes, offset, materialize)
  local actions = {}
  local cursor = offset
  local terminated = false
  while cursor + 1 < bytes:length() do
    local code = byte(bytes, cursor + 1) + byte(bytes, cursor + 2) * 256
    if code == MOVEMENT_END then
      cursor = cursor + 4
      terminated = true
      break
    end
    local entry = MovementCommands.byCode[code]
    if entry == nil then
      -- Unknown movement code: stop the block (the verifier flags it); the
      -- walk still skips the two bytes read so far.
      cursor = cursor + 2
      break
    end
    local size = 2 + 2 * entry.args
    local count = cursor + 2 < bytes:length() and byte(bytes, cursor + 3) or 0
    if entry.args >= 1 and cursor + 4 <= bytes:length() then
      count = count + byte(bytes, cursor + 4) * 256
    end
    if materialize then
      actions[#actions + 1] = RawIr.movementAction(cursor, code, entry.name, count)
    end
    cursor = cursor + size
  end
  return {
    offset = offset,
    actions = actions,
    terminated = terminated,
    size = cursor - offset,
  }
end

local function scanMovement(bytes, offset)
  local cursor = offset
  local terminated = false
  while cursor + 1 < bytes:length() do
    local code = byte(bytes, cursor + 1) + byte(bytes, cursor + 2) * 256
    if code == MOVEMENT_END then
      cursor = cursor + 4
      terminated = true
      break
    end
    local entry = MovementCommands.byCode[code]
    if entry == nil then
      cursor = cursor + 2
      break
    end
    cursor = cursor + 2 + 2 * entry.args
  end
  return cursor - offset, terminated
end

-- Resolve a message operand to its bank-qualified symbol; the bank comes
-- from the pinned member-bank map (the member carries indices only).
---@param index number
---@param msgBank integer|nil
---@return string
local function messageSymbol(index, msgBank)
  return string.format("msg_%04d_x_%05d", msgBank or 0, index)
end

-- Resolve a relative word operand (label-.-4 semantics: signed offset from
-- the end of the instruction) to an absolute member offset.
---@param ins table<string, unknown>
---@param operand table<string, unknown>
---@return integer
local function resolveRelative(ins, operand)
  local raw = operand.raw
  if raw >= 0x80000000 then
    raw = raw - 0x100000000
  end
  return ins.offset + ins.size + raw
end

-- Decode state keeps discovery and fixpoint bookkeeping call-local and explicit.
local function newDecodeState(bytes, member, entries)
  bytes = asView(bytes)
  local length = bytes:length()
  local scriptStarts = ffi.new("int32_t[?]", length)
  ffi.fill(scriptStarts, assert(ffi.sizeof(scriptStarts)), 0xff)
  for index, entry in ipairs(entries) do
    if entry.label < length then
      scriptStarts[entry.label] = index - 1
    end
  end
  return {
    bytes = bytes,
    member = member,
    entries = entries,
    scriptStarts = scriptStarts,
    justified = ffi.new("uint8_t[?]", length),
    movementRegistered = ffi.new("uint8_t[?]", length),
    movementSpanEnd = ffi.new("uint32_t[?]", length),
    operandValues = ffi.new("uint32_t[?]", CommandCatalog.MAX_OPERANDS),
    registeredCount = 0,
    justifiedCount = 0,
    movements = {},
    materialize = false,
    instrumentation = nil,
  }
end

local function registerMovement(state, offset)
  local length = state.bytes:length()
  if offset >= 0 and offset + 1 <= length and state.movementRegistered[offset] == 0 then
    state.movementRegistered[offset] = 1
    state.registeredCount = state.registeredCount + 1
    return true
  end
  return false
end

local function registerMovementSpan(state, offset, size)
  local endOffset = math.min(state.bytes:length(), offset + size)
  for cursor = offset, endOffset - 1 do
    state.movementSpanEnd[cursor] = endOffset
  end
end

-- Dead movement data is recognized only where the script walk has no other
-- justification for continuing.
local function movementShapeAt(state, cursor)
  for back = 0, 3 do
    local candidate = cursor - back
    if candidate >= 0 then
      local size, terminated = scanMovement(state.bytes, candidate)
      if terminated and size <= 64 then
        return candidate, size
      end
    end
  end
  return nil
end

local function spanningMovementAt(state, cursor)
  local endOffset = state.movementSpanEnd[cursor]
  if endOffset ~= nil and endOffset > cursor then
    return endOffset
  end
  return nil
end

local function skipTerminatedRegion(state, cursor)
  for lookahead = 1, 4 do
    if state.justified[cursor + lookahead] ~= 0 then
      return cursor + lookahead, true
    end
  end
  local candidate, shapeSize = movementShapeAt(state, cursor)
  if candidate == nil then
    return nil, false
  end
  registerMovement(state, candidate)
  registerMovementSpan(state, candidate, shapeSize)
  return candidate + shapeSize, false
end

---@param bytes BinaryView
---@param operands table[]
---@param cursor integer
---@param width integer
---@return integer nextCursor, integer size, boolean truncated
local function readOperand(bytes, operands, cursor, width)
  if cursor + width > bytes:length() then
    return cursor, 0, true
  end
  local value
  if width == 1 then
    value = byte(bytes, cursor + 1)
  elseif width == 2 then
    value = byte(bytes, cursor + 1) + byte(bytes, cursor + 2) * 256
  else
    value = byte(bytes, cursor + 1)
      + byte(bytes, cursor + 2) * 256
      + byte(bytes, cursor + 3) * 65536
      + byte(bytes, cursor + 4) * 16777216
  end
  operands[#operands + 1] = { raw = value, width = width }
  return cursor + width, width, false
end

---@param bytes BinaryView
---@param operands table[]
---@param cursor integer
---@param widths integer[]
---@return integer nextCursor, integer size, boolean truncated
local function readOperandWidths(bytes, operands, cursor, widths)
  local size = 0
  local truncated = false
  for _, width in ipairs(widths) do
    local nextCursor, operandSize, operandTruncated = readOperand(bytes, operands, cursor, width)
    if operandTruncated then
      truncated = true
    else
      cursor = nextCursor
      size = size + operandSize
    end
  end
  return cursor, size, truncated
end

local function readDiscoveryOperands(state, opcode, cursor, widths)
  local values = state.operandValues
  local count = 0
  local argCursor = cursor + 2
  local truncated = false
  for _, width in ipairs(widths) do
    count = count + 1
    assert(count <= CommandCatalog.MAX_OPERANDS, "script instruction exceeds the operand scratch capacity")
    if argCursor + width > state.bytes:length() then
      truncated = true
      break
    end
    values[count - 1] = width == 1 and byte(state.bytes, argCursor + 1)
      or width == 2 and (byte(state.bytes, argCursor + 1) + byte(state.bytes, argCursor + 2) * 256)
      or (
        byte(state.bytes, argCursor + 1)
        + byte(state.bytes, argCursor + 2) * 256
        + byte(state.bytes, argCursor + 3) * 65536
        + byte(state.bytes, argCursor + 4) * 16777216
      )
    argCursor = argCursor + width
  end
  local extraWidths = CommandCatalog.variantExtraWidths(opcode, {
    { raw = values[0] },
  })
  if extraWidths ~= nil and not truncated then
    for _, width in ipairs(extraWidths) do
      count = count + 1
      assert(count <= CommandCatalog.MAX_OPERANDS, "script instruction exceeds the operand scratch capacity")
      if argCursor + width > state.bytes:length() then
        truncated = true
        break
      end
      values[count - 1] = width == 1 and byte(state.bytes, argCursor + 1)
        or width == 2 and (byte(state.bytes, argCursor + 1) + byte(state.bytes, argCursor + 2) * 256)
        or (
          byte(state.bytes, argCursor + 1)
          + byte(state.bytes, argCursor + 2) * 256
          + byte(state.bytes, argCursor + 3) * 65536
          + byte(state.bytes, argCursor + 4) * 16777216
        )
      argCursor = argCursor + width
    end
  end
  return argCursor, argCursor - cursor - 2, truncated, count
end

local function readInstructionOperands(state, opcode, cursor, widths)
  if not state.materialize then
    local nextCursor, operandSize, truncated = readDiscoveryOperands(state, opcode, cursor, widths)
    return nil, operandSize + 2, truncated, nextCursor
  end
  local operands = {}
  local size = 2
  local argCursor = cursor + 2
  local nextCursor, operandSize, truncated = readOperandWidths(state.bytes, operands, argCursor, widths)
  argCursor = nextCursor
  size = size + operandSize
  local extraWidths = CommandCatalog.variantExtraWidths(opcode, operands)
  if extraWidths ~= nil then
    argCursor, operandSize, truncated = readOperandWidths(state.bytes, operands, argCursor, extraWidths)
    size = size + operandSize
  end
  return operands, size, truncated, argCursor
end

local function decodeUnknownOpcode(state, script, cursor, opcode)
  local candidate, shapeSize = movementShapeAt(state, cursor)
  if candidate == nil then
    if state.materialize then
      script.decodeNote = { offset = cursor, opcode = opcode }
    end
    return nil
  end
  registerMovement(state, candidate)
  registerMovementSpan(state, candidate, shapeSize)
  return candidate + shapeSize, false, true
end

local function decodeKnownInstruction(state, script, cursor, opcode, widths)
  local operands, size, truncated, _ = readInstructionOperands(state, opcode, cursor, widths)
  if truncated then
    if state.materialize then
      script.decodeNote = { offset = cursor, opcode = opcode }
    end
    return nil
  end

  if opcode == 94 then
    -- ApplyMovement arg1: relative movement-block offset.
    local raw
    if state.materialize then
      local materializedOperands = assert(operands)
      local operand = materializedOperands[2]
      raw = operand and operand.raw
    else
      raw = state.operandValues[1]
    end
    if type(raw) == "number" then
      if raw >= 0x80000000 then
        raw = raw - 0x100000000
      end
      local target = cursor + size + raw
      if registerMovement(state, target) then
        local movementSize, movementTerminated = scanMovement(state.bytes, target)
        if movementTerminated then
          registerMovementSpan(state, target, movementSize)
        end
      end
    end
  end

  local relIndex = RELATIVE_OPERANDS[opcode]
  local raw
  if relIndex ~= nil and state.materialize then
    local materializedOperands = assert(operands)
    local operand = materializedOperands[relIndex]
    raw = operand and operand.raw
  elseif relIndex ~= nil then
    raw = state.operandValues[relIndex - 1]
  end
  if relIndex ~= nil and type(raw) == "number" then
    if raw >= 0x80000000 then
      raw = raw - 0x100000000
    end
    local target = cursor + size + raw
    if target >= 0 and target < state.bytes:length() and state.justified[target] == 0 then
      state.justified[target] = 1
      state.justifiedCount = state.justifiedCount + 1
    end
  end
  if state.materialize then
    local materializedOperands = assert(operands)
    script.instructions[#script.instructions + 1] =
      RawIr.instruction(cursor, opcode, CommandCatalog.name(opcode), materializedOperands, size, nil)
  end
  return cursor + size, opcode == 2 or opcode == 21 or opcode == 27
end

local function decodeInstruction(state, script, cursor)
  local opcode = byte(state.bytes, cursor + 1) + byte(state.bytes, cursor + 2) * 256
  local widths = CommandCatalog.widths(opcode)
  if widths == nil then
    return decodeUnknownOpcode(state, script, cursor, opcode)
  end
  return decodeKnownInstruction(state, script, cursor, opcode, widths)
end

local function decodeCursor(state, script, cursor, terminated, tailRun)
  local block = state.movements[cursor]
  if block ~= nil then
    return cursor + block.size, terminated, false
  end
  if state.movementRegistered[cursor] ~= 0 then
    if state.materialize then
      local movement = decodeMovement(state.bytes, cursor, true)
      if movement ~= nil then
        state.movements[cursor] = movement
        return cursor + movement.size, terminated, false
      end
    else
      local movementEnd = state.movementSpanEnd[cursor]
      if movementEnd > cursor then
        return movementEnd, terminated, false
      end
    end
  end

  local spanning = spanningMovementAt(state, cursor)
  if spanning ~= nil then
    return spanning, terminated, false
  end

  if terminated and not tailRun and state.justified[cursor] == 0 then
    local nextCursor, nextTailRun = skipTerminatedRegion(state, cursor)
    if nextCursor == nil then
      return nil, false, false
    end
    return nextCursor, terminated, nextTailRun
  end

  if terminated and not tailRun and state.justified[cursor] ~= 0 then
    tailRun = true
  end
  local nextCursor, endsRun, resetsTail = decodeInstruction(state, script, cursor)
  if nextCursor == nil then
    return nil, false, false
  end
  if endsRun then
    return nextCursor, true, false
  end
  if resetsTail then
    tailRun = false
  end
  return nextCursor, terminated, tailRun
end

local function decodeScriptPass(state)
  local scripts = {}
  for scriptIndex, entry in ipairs(state.entries) do
    local script = {
      label = ("scr_seq_%04d_%03d"):format(state.member, scriptIndex - 1),
      index = scriptIndex - 1,
      instructions = {},
    }
    local cursor = entry.label
    local terminated = false
    local tailRun = false
    while cursor + 1 < state.bytes:length() do
      local owner = state.scriptStarts[cursor]
      if owner ~= nil and owner >= 0 and owner ~= scriptIndex - 1 then
        break
      end
      local nextCursor, nextTerminated, nextTailRun = decodeCursor(state, script, cursor, terminated, tailRun)
      if nextCursor == nil then
        break
      end
      cursor = nextCursor
      terminated = nextTerminated --[[@as boolean]]
      tailRun = nextTailRun --[[@as boolean]]
    end
    scripts[scriptIndex] = script
  end
  return scripts
end

local function decodeUntilFixpoint(state)
  local passes = 0
  repeat
    local beforeRegistered = state.registeredCount
    local beforeJustified = state.justifiedCount
    state.materialize = false
    decodeScriptPass(state)
    passes = passes + 1
    if state.registeredCount == beforeRegistered and state.justifiedCount == beforeJustified then
      break
    end
  until false
  return passes
end

local function materializeMember(state)
  state.materialize = true
  state.movements = {}
  local scripts = decodeScriptPass(state)
  if state.instrumentation ~= nil then
    state.instrumentation.materializations = (state.instrumentation.materializations or 0) + 1
    local instructionCount = 0
    for _, script in ipairs(scripts) do
      instructionCount = instructionCount + #script.instructions
    end
    state.instrumentation.finalInstructionRecords = instructionCount
    -- instrumentation is intentionally limited to the final pass; callers
    -- use it to assert the materialization boundary, not decoder internals.
    state.instrumentation.discoveryPasses = state.instrumentation.discoveryPasses or 0
  end
  return scripts
end

local function canonicalizeLabels(state, scripts)
  local targets = {}
  for _, script in ipairs(scripts) do
    for _, ins in ipairs(script.instructions) do
      local relIndex = RELATIVE_OPERANDS[ins.opcode]
      if relIndex ~= nil then
        local operand = ins.operands[relIndex]
        if operand ~= nil and type(operand.raw) == "number" then
          targets[resolveRelative(ins, operand)] = true
        end
      end
    end
  end

  local labelAt = {}
  for target in pairs(targets) do
    labelAt[target] = ("_%04X"):format(target)
  end
  for _, script in ipairs(scripts) do
    for _, ins in ipairs(script.instructions) do
      local label = labelAt[ins.offset]
      if label ~= nil then
        ins.label = label
      end
    end
  end
  for _, script in ipairs(scripts) do
    for _, ins in ipairs(script.instructions) do
      local relIndex = RELATIVE_OPERANDS[ins.opcode]
      if relIndex ~= nil then
        local operand = ins.operands[relIndex]
        local raw = operand and operand.raw
        if type(raw) == "number" then
          local target = resolveRelative(ins, operand)
          local label = labelAt[target]
          if label ~= nil then
            operand.raw = label
          else
            local owner = state.scriptStarts[target]
            if owner ~= nil and owner >= 0 then
              operand.raw = ("scr_seq_%04d_%03d"):format(state.member, owner)
            end
          end
        end
      end
    end
  end
end

local function canonicalizeMessageOperands(scripts, msgBank)
  if msgBank == nil then
    return
  end
  for _, script in ipairs(scripts) do
    for _, ins in ipairs(script.instructions) do
      local indices = MESSAGE_OPERANDS[ins.opcode]
      if indices ~= nil then
        for _, operandIndex in ipairs(indices) do
          local operand = ins.operands[operandIndex]
          if operand ~= nil then
            local raw = operand.raw
            if type(raw) == "number" then
              operand.raw = messageSymbol(raw, msgBank)
            end
          end
        end
      end
      -- NonNPCMsgVar/NPCMsgVar: a direct message id below VAR_BASE, a
      -- variable reference otherwise (var resolution runs below). The
      -- direct id emits the resolvable message ref form (the varRef
      -- handlers pass strings through).
      local valueIndices = MESSAGE_VALUE_OPERANDS[ins.opcode]
      if valueIndices ~= nil then
        for _, operandIndex in ipairs(valueIndices) do
          local operand = ins.operands[operandIndex]
          if operand ~= nil and type(operand.raw) == "number" and operand.raw < 0x4000 then
            operand.raw = string.format("msg.hgss.%04d.%05d", msgBank, operand.raw)
          end
        end
      end
    end
  end
end

local function canonicalizeCatalogOperands(scripts, catalog)
  if catalog == nil then
    return
  end
  local sounds = catalog.sounds
  local flags = catalog.flags
  local vars = catalog.vars
  local maps = catalog.maps
  local spawns = catalog.spawns
  local function nameFor(value, values, prefix)
    local name = values[value]
    if name ~= nil then
      return name
    end
    return ("%s_0x%04X"):format(prefix, value)
  end

  for _, script in ipairs(scripts) do
    for _, ins in ipairs(script.instructions) do
      for operandIndex, operand in ipairs(ins.operands) do
        local raw = operand.raw
        if type(raw) == "number" then
          local named = false
          if vars ~= nil and VAR_SOUND_OPERANDS[ins.opcode] and VAR_SOUND_OPERANDS[ins.opcode][operandIndex] then
            for _, range in ipairs(VAR_RANGES) do
              if raw >= range.start and raw < range.finish then
                operand.raw = nameFor(raw, vars, "VAR")
                named = true
                break
              end
            end
          end
          if
            not named
            and sounds ~= nil
            and SOUND_OPERANDS[ins.opcode]
            and SOUND_OPERANDS[ins.opcode][operandIndex]
          then
            operand.raw = nameFor(raw, sounds, "SEQ")
            named = true
          elseif flags ~= nil and FLAG_OPERANDS[ins.opcode] and FLAG_OPERANDS[ins.opcode][operandIndex] then
            operand.raw = nameFor(raw, flags, "FLAG")
            named = true
          elseif
            maps ~= nil
            and MAP_OPERANDS[ins.opcode]
            and MAP_OPERANDS[ins.opcode][operandIndex]
            and maps[raw] ~= nil
          then
            operand.raw = maps[raw].mapCode
            named = true
          elseif spawns ~= nil and SPAWN_OPERANDS[ins.opcode] and SPAWN_OPERANDS[ins.opcode][operandIndex] then
            operand.raw = nameFor(raw, spawns, "SPAWN")
            named = true
          end
          if not named and vars ~= nil then
            for _, range in ipairs(VAR_RANGES) do
              if raw >= range.start and raw < range.finish then
                operand.raw = nameFor(raw, vars, "VAR")
                break
              end
            end
          end
        end
      end
    end
  end
end

local function markPreludeScripts(scripts)
  for _, script in ipairs(scripts) do
    -- A table entry that lands on a shared-subroutine body (returns without
    -- any call: the callers live in other scripts) is a prelude-shaped
    -- library; the verifier's prelude tolerance applies to its balance.
    local hasCall = false
    local hasReturn = false
    for _, ins in ipairs(script.instructions) do
      if ins.opcode == 26 or ins.opcode == 29 then
        hasCall = true
      end
      if ins.opcode == 27 then
        hasReturn = true
      end
    end
    if hasReturn and not hasCall then
      script.prelude = true
    end
  end
end

-- Decode one member's scripts. `opts.msgBank` names the map message bank for
-- message operands. Returns nil for header members (no script table).
---@param bytes string
---@param member integer
---@param sourcePath string
---@param opts table<string, unknown> { msgBank: integer|nil }
---@return table<string, unknown>|nil memberIr
function ScriptBinaryDecoder.parseMember(bytes, member, sourcePath, opts)
  opts = opts or {}
  local view = asView(bytes)
  local entries = ScriptBinaryDecoder.scanEntries(view)
  if #entries == 0 then
    return nil
  end
  local state = newDecodeState(view, member, entries)
  state.instrumentation = opts.instrumentation
  local passes = decodeUntilFixpoint(state)
  if state.instrumentation ~= nil then
    state.instrumentation.discoveryPasses = (state.instrumentation.discoveryPasses or 0) + passes
  end
  local scripts = materializeMember(state)
  canonicalizeLabels(state, scripts)
  canonicalizeMessageOperands(scripts, opts.msgBank)
  canonicalizeCatalogOperands(scripts, opts.catalog)
  markPreludeScripts(scripts)
  local out = RawIr.member(member, sourcePath, nil, opts.msgBank)
  for _, script in ipairs(scripts) do
    out.scripts[script.index] = script
  end
  for offset, block in pairs(state.movements) do
    out.movements[offset] = block
  end
  return out
end

-- Decode every script member of the scr_seq archive. Header members return
-- nil and are reported as `skipped`; script members keep their decode notes.
---@param archive table<string, unknown> Narc-shaped
---@param banks table<integer, integer>
---@param sourcePath string
---@param catalog table<string, unknown>|nil { sounds, flags, vars, maps }
---@return table<string, unknown> memberIrs table<integer, table<string, unknown>|nil>
function ScriptBinaryDecoder.decodeArchive(archive, banks, sourcePath, catalog)
  local memberIrs = {}
  for member = 0, archive:memberCount() - 1 do
    local bytes = assert(archive:memberView(member))
    local ok, memberIr =
      pcall(ScriptBinaryDecoder.parseMember, bytes, member, sourcePath, { msgBank = banks[member], catalog = catalog })
    if not ok then
      error(memberIr, 0)
    end
    memberIrs[member] = memberIr
  end
  return memberIrs
end

return ScriptBinaryDecoder
