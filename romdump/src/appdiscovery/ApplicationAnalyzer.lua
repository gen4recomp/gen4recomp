-- Converts normalized executable images into conservative application
-- behavior evidence: structural OverlayManagerTemplate candidate discovery,
-- reachable Thumb control-flow/exact-value analysis, the generic bounded
-- signed-halfword switch idiom, and pointer/literal census. No decomp/config
-- input; every fact is derived from the target ROM's own bytes.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")
local ThumbDecoder = require("romdump.src.appdiscovery.ThumbDecoder")

local ApplicationAnalyzer = {}

---@class ApplicationAnalyzer.BlockEvidence
---@field start integer
---@field endExclusive integer
---@field instructionCount integer

---@class ApplicationAnalyzer.FunctionEvidence
---@field entry integer
---@field instructionCount integer
---@field blocks ApplicationAnalyzer.BlockEvidence[]

---@class ApplicationAnalyzer.DisassemblyFunction
---@field entry integer
---@field instructions ThumbDecoder.Instruction[]

---@class ApplicationAnalyzer.Disassembly
---@field functions ApplicationAnalyzer.DisassemblyFunction[]

---@class ApplicationAnalyzer.Evidence
---@field schema "g4-app-analysis-1"
---@field target table<string, unknown>
---@field entrypointCandidates table[]
---@field functions ApplicationAnalyzer.FunctionEvidence[]
---@field switches table[]
---@field calls table[]
---@field literals table[]
---@field pointers table[]
---@field gaps table[]
---@field coverage table<string, integer>

local CALL_CLOBBER_REGISTERS = { 0, 1, 2, 3, 12 }

local function maskThumb(value)
  return value - (value % 2)
end

local function isThumbPointer(value)
  return value % 2 == 1
end

local function cloneState(state)
  local registers = {}
  for r, v in pairs(state.registers) do
    registers[r] = v
  end
  local stack = {}
  for k, v in pairs(state.stack) do
    stack[k] = v
  end
  return { registers = registers, stack = stack, spDelta = state.spDelta }
end

local function statesEqual(a, b)
  if a.spDelta ~= b.spDelta then
    return false
  end
  for r = 0, 12 do
    if a.registers[r] ~= b.registers[r] then
      return false
    end
  end
  for k, v in pairs(a.stack) do
    if b.stack[k] ~= v then
      return false
    end
  end
  for k, v in pairs(b.stack) do
    if a.stack[k] ~= v then
      return false
    end
  end
  return true
end

local function joinStates(a, b)
  local result = { registers = {}, stack = {}, spDelta = a.spDelta == b.spDelta and a.spDelta or nil }
  for r = 0, 12 do
    if a.registers[r] ~= nil and a.registers[r] == b.registers[r] then
      result.registers[r] = a.registers[r]
    end
  end
  for k, v in pairs(a.stack) do
    if b.stack[k] == v then
      result.stack[k] = v
    end
  end
  return result
end

-- Exact-value transfer for ordinary register/stack-affecting Thumb
-- operations. Any operation not explicitly modeled invalidates only the
-- destination register it can modify.
local function transfer(instr, stateIn)
  local operands = instr.operands
  local newState = cloneState(stateIn)
  local m = instr.mnemonic

  local function setReg(r, v)
    if r == nil or r > 12 then
      return
    end
    newState.registers[r] = v
  end
  local function getReg(r)
    if r == nil or r > 12 then
      return nil
    end
    return stateIn.registers[r]
  end

  local function stableStackOffset(immediate)
    if newState.spDelta == nil then
      return nil
    end
    return newState.spDelta + immediate
  end

  if m == "mov" then
    if operands.rs ~= nil then
      setReg(operands.rd, getReg(operands.rs))
    elseif operands.immediate ~= nil then
      setReg(operands.rd, operands.immediate)
    end
  elseif m == "add" or m == "sub" then
    if operands.base == "sp" then
      if operands.rd == nil then
        if newState.spDelta ~= nil then
          local amount = operands.immediate
          newState.spDelta = m == "add" and newState.spDelta + amount or newState.spDelta - amount
        end
      else
        setReg(operands.rd, nil)
      end
    elseif operands.rs ~= nil then
      local rsVal = getReg(operands.rs)
      local rhs = operands.immediate
      if rhs == nil and operands.rn ~= nil then
        rhs = getReg(operands.rn)
      end
      if rsVal ~= nil and rhs ~= nil then
        setReg(operands.rd, m == "add" and (rsVal + rhs) or (rsVal - rhs))
      else
        setReg(operands.rd, nil)
      end
    elseif operands.rd ~= nil then
      local rdVal = getReg(operands.rd)
      if rdVal ~= nil and operands.immediate ~= nil then
        setReg(operands.rd, m == "add" and (rdVal + operands.immediate) or (rdVal - operands.immediate))
      else
        setReg(operands.rd, nil)
      end
    end
  elseif m == "cmp" or m == "cmn" or m == "tst" then
    -- flag-only: no register write
  elseif m == "lsl" or m == "lsr" or m == "asr" then
    local rsVal = getReg(operands.rs)
    if rsVal ~= nil and operands.immediate ~= nil then
      local scale = 2 ^ operands.immediate
      if m == "lsl" then
        setReg(operands.rd, rsVal * scale)
      else
        setReg(operands.rd, math.floor(rsVal / scale))
      end
    else
      setReg(operands.rd, nil)
    end
  elseif m == "adr" then
    setReg(operands.rd, operands.address)
  elseif (m == "ldr" or m == "str") and operands.base == "sp" then
    local stableOffset = stableStackOffset(operands.immediate)
    if stableOffset == nil then
      if m == "ldr" then
        setReg(operands.rd, nil)
      else
        newState.stack = {}
      end
    elseif m == "ldr" then
      setReg(operands.rd, newState.stack[stableOffset])
    else
      newState.stack[stableOffset] = getReg(operands.rd)
    end
  elseif m == "push" then
    local rlist = operands.registerList or 0
    local wordCount = 0
    for r = 0, 7 do
      if math.floor(rlist / 2 ^ r) % 2 == 1 then
        wordCount = wordCount + 1
      end
    end
    if operands.includesPcOrLr then
      wordCount = wordCount + 1
    end
    if newState.spDelta == nil then
      newState.stack = {}
    else
      newState.spDelta = newState.spDelta - wordCount * 4
      local wordIndex = 0
      for r = 0, 7 do
        if math.floor(rlist / 2 ^ r) % 2 == 1 then
          newState.stack[newState.spDelta + wordIndex * 4] = getReg(r)
          wordIndex = wordIndex + 1
        end
      end
      if operands.includesPcOrLr then
        newState.stack[newState.spDelta + wordIndex * 4] = nil
      end
    end
  elseif m == "pop" then
    local rlist = operands.registerList or 0
    if newState.spDelta == nil then
      for r = 0, 7 do
        if math.floor(rlist / 2 ^ r) % 2 == 1 then
          setReg(r, nil)
        end
      end
      newState.stack = {}
    else
      local wordIndex = 0
      for r = 0, 7 do
        if math.floor(rlist / 2 ^ r) % 2 == 1 then
          setReg(r, stateIn.stack[stateIn.spDelta + wordIndex * 4])
          wordIndex = wordIndex + 1
        end
      end
      newState.spDelta = newState.spDelta + wordIndex * 4
    end
  elseif m == "ldmia" then
    local rlist = operands.registerList or 0
    for r = 0, 7 do
      if math.floor(rlist / 2 ^ r) % 2 == 1 then
        setReg(r, nil)
      end
    end
  elseif m == "stmia" then
    -- source registers unaffected; memory writes are not tracked
  else
    if operands.rd ~= nil then
      setReg(operands.rd, nil)
    end
  end
  return newState
end

---@param romImage RomImage
---@param overlayId integer
---@return ApplicationAnalyzer.Evidence
---@return ApplicationAnalyzer.Disassembly
function ApplicationAnalyzer.analyze(romImage, overlayId)
  assert(type(overlayId) == "number", "overlayId must be a number")

  local targetImage = romImage:overlay("arm9", overlayId)
  local mainImage = romImage:mainArm9()

  local readers = {}
  local function imageReader(image)
    local reader = readers[image.id]
    if not reader then
      reader = BinaryReader.new(image.bytes, image.id)
      readers[image.id] = reader
    end
    return reader
  end

  local function withinImage(image, address)
    return address >= image.ramAddress and address < image.ramAddress + #image.bytes
  end

  local function regionOf(address)
    if withinImage(targetImage, address) then
      return "target", targetImage
    end
    if withinImage(mainImage, address) then
      return "main", mainImage
    end
    return "unknown", nil
  end

  local decoded = {}
  local claimedRanges = {}

  local function isClaimed(address)
    for _, range in ipairs(claimedRanges) do
      if address >= range.startAddr and address < range.endAddr then
        return true
      end
    end
    return false
  end

  local function getOrDecode(image, address)
    local existing = decoded[address]
    if existing then
      return existing
    end
    if isClaimed(address) then
      return nil
    end
    local byteOffset = address - image.ramAddress
    local instr, err = ThumbDecoder.decode(image.bytes, byteOffset, address)
    if not instr then
      Errors.raise(
        "APPDISCOVERY_CODE_RANGE_INVALID",
        "cannot decode instruction at " .. tostring(address),
        { address = address, cause = err and err.code }
      )
    end
    decoded[address] = instr
    return instr
  end

  local gaps = {}
  local gapKeys = {}
  local function addGap(kind, address, extra)
    local key = kind .. "@" .. tostring(address)
    if gapKeys[key] then
      return
    end
    gapKeys[key] = true
    local gap = { kind = kind }
    if address ~= nil then
      gap.address = address
    end
    if extra ~= nil then
      for k, v in pairs(extra) do
        gap[k] = v
      end
    end
    gaps[#gaps + 1] = gap
  end

  local literals = {}
  local literalsSeen = {}
  local function readU32(image, byteOffset)
    return imageReader(image):u32le(byteOffset)
  end

  local calls = {}
  local switches = {}
  local joinTargets = {}

  local functionQueue = {}
  local functionPending = {}
  local functionVisited = {}
  local function enqueueFunction(address)
    if functionVisited[address] or functionPending[address] then
      return
    end
    functionPending[address] = true
    functionQueue[#functionQueue + 1] = address
  end

  local function clobberForCall(state)
    local newState = cloneState(state)
    for _, r in ipairs(CALL_CLOBBER_REGISTERS) do
      newState.registers[r] = nil
    end
    return newState
  end

  -- Resolves the sign-extended table-index load feeding `add pc, pc, rsReg`,
  -- immediately before `addPcAddress`. Accepts either of the two idioms the
  -- compiler emits to sign-extend a 16-bit table entry into a full register:
  -- a single `ldsh rsReg, [rb, ro]`, or `ldrh rsReg, [rb, ro]` followed by
  -- `lsl rsReg, rsReg, #16` and `asr rsReg, rsReg, #16`. Returns the base/
  -- offset registers of the load and the address of its first instruction,
  -- or nil if neither form matches.
  local function resolveTableIndexLoad(addPcAddress, rsReg)
    local ldsh = decoded[addPcAddress - 2]
    if ldsh and ldsh.mnemonic == "ldsh" and ldsh.operands.rd == rsReg then
      return { rb = ldsh.operands.rb, ro = ldsh.operands.ro, startAddress = addPcAddress - 2 }
    end
    local asr = decoded[addPcAddress - 2]
    local lsl16 = decoded[addPcAddress - 4]
    local ldrh = decoded[addPcAddress - 6]
    if
      asr
      and asr.mnemonic == "asr"
      and asr.operands.immediate == 16
      and asr.operands.rd == rsReg
      and asr.operands.rs == rsReg
      and lsl16
      and lsl16.mnemonic == "lsl"
      and lsl16.operands.immediate == 16
      and lsl16.operands.rd == rsReg
      and lsl16.operands.rs == rsReg
      and ldrh
      and ldrh.mnemonic == "ldrh"
      and ldrh.operands.rd == rsReg
    then
      return { rb = ldrh.operands.rb, ro = ldrh.operands.ro, startAddress = addPcAddress - 6 }
    end
    return nil
  end

  -- Resolves the register that carries the doubled selector into the
  -- table-index load, given the load's base register `load.rb`. The
  -- compiler prepares that base register in one of two structurally
  -- distinct ways, immediately preceding the load:
  --   - a separate `ADR rb, table` computing the table base into its own
  --     register, paired with a register-offset load whose `ro` operand is
  --     the doubled-selector register (a different register from `rb`).
  --   - a two-operand hi-register `ADD rb, rb, PC` folding the doubled
  --     selector directly into the PC-relative table base in place, paired
  --     with an immediate-offset load that reuses `rb` as both base and
  --     destination (no `ro` operand).
  -- Returns the doubled-selector register, or nil if neither shape matches.
  local function resolveSelectorRegister(load)
    local base = decoded[load.startAddress - 2]
    if not base then
      return nil
    end
    if base.mnemonic == "adr" and base.operands.rd == load.rb and load.ro ~= nil then
      return load.ro
    end
    if
      base.mnemonic == "add"
      and base.flow.kind == "sequential"
      and base.operands.rs == 15
      and base.operands.rd == load.rb
      and load.ro == nil
    then
      return load.rb
    end
    return nil
  end

  local recognizedSwitches = {}

  local function tryRecognizeSwitch(addPcAddress, addPcInstr)
    local cached = recognizedSwitches[addPcAddress]
    if cached then
      return cached
    end
    local rsReg = addPcInstr.operands.rs
    local load = resolveTableIndexLoad(addPcAddress, rsReg)
    if not load then
      return nil
    end
    local selectorReg = resolveSelectorRegister(load)
    if not selectorReg then
      return nil
    end
    local doubling = decoded[load.startAddress - 4]
    local isShiftDouble = doubling
      and doubling.mnemonic == "lsl"
      and doubling.operands.immediate == 1
      and doubling.operands.rd == selectorReg
      and doubling.operands.rs == selectorReg
    local isSelfAddDouble = doubling
      and doubling.mnemonic == "add"
      and doubling.operands.rd == selectorReg
      and doubling.operands.rs == selectorReg
      and doubling.operands.rn == selectorReg
    if not (isShiftDouble or isSelfAddDouble) then
      return nil
    end
    local branch = decoded[load.startAddress - 6]
    if not (branch and branch.flow.kind == "branch" and branch.flow.conditional and branch.flow.condition == "hi") then
      return nil
    end
    local cmp = decoded[load.startAddress - 8]
    if not (cmp and cmp.mnemonic == "cmp" and cmp.operands.rd == selectorReg) then
      return nil
    end

    local caseCount = cmp.operands.immediate + 1
    -- The Thumb assembler always places the inline data table immediately
    -- after the dispatch instruction, regardless of which register
    -- allocation the compiler chose to prepare the load above.
    local tableBase = addPcAddress + addPcInstr.size
    local region, image = regionOf(tableBase)
    if region ~= "target" or not image then
      return nil
    end
    local tableByteOffset = tableBase - image.ramAddress
    if tableByteOffset < 0 or tableByteOffset + caseCount * 2 > #image.bytes then
      return nil
    end
    for i = 0, caseCount - 1 do
      if decoded[tableBase + i * 2] ~= nil then
        return nil
      end
    end

    local reader = imageReader(image)
    local cases, targets = {}, {}
    for i = 0, caseCount - 1 do
      local raw16 = reader:u16le(tableByteOffset + i * 2)
      local signed = raw16 >= 0x8000 and raw16 - 0x10000 or raw16
      local target = (addPcAddress + 4) + signed
      if target % 2 ~= 0 or not withinImage(targetImage, target) then
        return nil
      end
      cases[#cases + 1] = { value = i, target = target }
      targets[#targets + 1] = target
    end

    claimedRanges[#claimedRanges + 1] = { startAddr = tableBase, endAddr = tableBase + caseCount * 2 }
    switches[#switches + 1] = {
      address = addPcAddress,
      tableAddress = tableBase,
      caseCount = caseCount,
      cases = cases,
    }

    local successors = {}
    for _, target in ipairs(targets) do
      joinTargets[target] = true
      successors[#successors + 1] = { addr = target, state = { registers = {}, stack = {}, spDelta = nil } }
    end
    recognizedSwitches[addPcAddress] = successors
    return successors
  end

  local function handleBranch(address, instr, state)
    local successors = {}
    if instr.flow.conditional then
      successors[#successors + 1] = { addr = address + instr.size, state = state }
    end
    local target = instr.flow.target
    local region = regionOf(target)
    if region == "target" then
      joinTargets[target] = true
      successors[#successors + 1] = { addr = target, state = state }
    else
      addGap("branch_target_unknown_region", address, { target = target, region = region })
    end
    return successors
  end

  local function handleCall(address, instr, state)
    local target = instr.flow.target
    if target == nil then
      addGap("computed_pc_gap", address)
      return { { addr = address + instr.size, state = clobberForCall(state) } }
    end
    local region = regionOf(target)
    local registersSnapshot = {}
    for r = 0, 3 do
      if state.registers[r] ~= nil then
        registersSnapshot["r" .. r] = state.registers[r]
      end
    end
    local stackSnapshot = {}
    if state.spDelta ~= nil then
      for stableOffset, value in pairs(state.stack) do
        local currentOffset = stableOffset - state.spDelta
        if currentOffset >= 0 then
          stackSnapshot[currentOffset] = value
        end
      end
    end
    local targetState = instr.flow.targetState
    calls[address] = {
      site = address,
      target = target,
      targetRegion = region,
      knownArgs = { registers = registersSnapshot, stack = stackSnapshot },
    }
    if targetState ~= nil then
      calls[address].targetState = targetState
    end
    if region == "target" and targetState ~= "arm" then
      joinTargets[target] = true
      enqueueFunction(target)
    end
    if targetState == "arm" then
      addGap("arm_call_target_unsupported", address, { target = target, region = region })
    end
    return { { addr = address + instr.size, state = clobberForCall(state) } }
  end

  local function processInstruction(address, instr, state)
    if instr.mnemonic == "unknown_instruction" then
      addGap("unknown_instruction", address)
      return {}
    end

    if instr.mnemonic == "ldr" and instr.operands.literalAddress ~= nil then
      local literalAddr = instr.operands.literalAddress
      local _, image = regionOf(literalAddr)
      local value = nil
      if image then
        local byteOffset = literalAddr - image.ramAddress
        if byteOffset >= 0 and byteOffset + 4 <= #image.bytes then
          value = readU32(image, byteOffset)
        end
      end
      if not literalsSeen[address] then
        literalsSeen[address] = true
        literals[#literals + 1] = { address = address, literalAddress = literalAddr, value = value }
      end
      if value == nil then
        addGap("literal_read_gap", address)
      end
      local outState = cloneState(state)
      outState.registers[instr.operands.rd] = value
      return { { addr = address + instr.size, state = outState } }
    end

    local kind = instr.flow.kind
    if kind == "return" then
      return {}
    end
    if kind == "call" then
      return handleCall(address, instr, state)
    end
    if kind == "branch" then
      return handleBranch(address, instr, state)
    end
    if kind == "indirect" then
      if instr.mnemonic == "add" then
        local switchSuccessors = tryRecognizeSwitch(address, instr)
        if switchSuccessors then
          return switchSuccessors
        end
      end
      addGap("computed_pc_gap", address)
      return {}
    end
    return { { addr = address + instr.size, state = transfer(instr, state) } }
  end

  local function analyzeFunction(rootAddress)
    local entryState = { [rootAddress] = { registers = {}, stack = {}, spDelta = 0 } }
    local pending = { [rootAddress] = true }
    local queue = { rootAddress }
    local functionAddrs = {}
    local functionMembers = {}
    while #queue > 0 do
      local address = table.remove(queue, 1)
      pending[address] = nil
      local region, image = regionOf(address)
      if region == "target" then
        local instr = getOrDecode(image, address)
        if instr then
          if not functionMembers[address] then
            functionMembers[address] = true
            functionAddrs[#functionAddrs + 1] = address
          end
          local successors = processInstruction(address, instr, entryState[address])
          for _, successor in ipairs(successors) do
            local existing = entryState[successor.addr]
            local nextState, changed
            if existing == nil then
              nextState, changed = successor.state, true
            else
              nextState = joinStates(existing, successor.state)
              changed = not statesEqual(existing, nextState)
            end
            entryState[successor.addr] = nextState
            if changed and not pending[successor.addr] then
              pending[successor.addr] = true
              queue[#queue + 1] = successor.addr
            end
          end
        end
      end
    end
    return functionAddrs
  end

  local BLOCK_TERMINAL_FLOW = { branch = true, ["return"] = true, unknown = true, indirect = true }

  local function buildBlocks(addrs)
    local blocks = {}
    ---@type ApplicationAnalyzer.BlockEvidence|nil
    local current = nil
    local prevAddr, prevInstr = nil, nil
    for _, addr in ipairs(addrs) do
      local instr = decoded[addr]
      local startNew = true
      if current ~= nil and not joinTargets[addr] and prevAddr ~= nil and prevInstr ~= nil then
        startNew = (prevAddr + prevInstr.size ~= addr) or BLOCK_TERMINAL_FLOW[prevInstr.flow.kind] == true
      end
      if startNew then
        current = { start = addr, endExclusive = addr + instr.size, instructionCount = 1 }
        blocks[#blocks + 1] = current
      else
        assert(current ~= nil)
        current.endExclusive = addr + instr.size
        current.instructionCount = current.instructionCount + 1
      end
      prevAddr, prevInstr = addr, instr
    end
    return blocks
  end

  local function scanCandidates(image)
    local reader = imageReader(image)
    local len = #image.bytes
    local found = {}
    local offset = 0
    while offset + 16 <= len do
      local w1 = reader:u32le(offset)
      local w2 = reader:u32le(offset + 4)
      local w3 = reader:u32le(offset + 8)
      local w4 = reader:u32le(offset + 12)
      if w4 == overlayId and w1 ~= 0 and w2 ~= 0 and w3 ~= 0 then
        local m1, m2, m3 = maskThumb(w1), maskThumb(w2), maskThumb(w3)
        if withinImage(targetImage, m1) and withinImage(targetImage, m2) and withinImage(targetImage, m3) then
          found[#found + 1] = {
            sourceRegion = image.id,
            sourceOffset = offset,
            ramAddress = image.ramAddress + offset,
            initTarget = w1,
            mainTarget = w2,
            exitTarget = w3,
            overlayId = w4,
            initState = isThumbPointer(w1) and "thumb" or "arm",
            mainState = isThumbPointer(w2) and "thumb" or "arm",
            exitState = isThumbPointer(w3) and "thumb" or "arm",
          }
        end
      end
      offset = offset + 4
    end
    return found
  end

  local entrypointCandidates = {}
  for _, candidate in ipairs(scanCandidates(mainImage)) do
    entrypointCandidates[#entrypointCandidates + 1] = candidate
  end
  for _, image in ipairs(romImage:arm9Overlays()) do
    for _, candidate in ipairs(scanCandidates(image)) do
      entrypointCandidates[#entrypointCandidates + 1] = candidate
    end
  end
  table.sort(entrypointCandidates, function(a, b)
    if a.sourceRegion ~= b.sourceRegion then
      return a.sourceRegion < b.sourceRegion
    end
    return a.ramAddress < b.ramAddress
  end)

  if #entrypointCandidates == 0 then
    addGap("no_entrypoint_candidate", nil)
  end

  local armRootCount, thumbRootCount = 0, 0
  for _, candidate in ipairs(entrypointCandidates) do
    for _, root in ipairs({
      { target = candidate.initTarget, state = candidate.initState },
      { target = candidate.mainTarget, state = candidate.mainState },
      { target = candidate.exitTarget, state = candidate.exitState },
    }) do
      local address = maskThumb(root.target)
      if root.state == "arm" then
        armRootCount = armRootCount + 1
        addGap("arm_root_unsupported", address)
      else
        thumbRootCount = thumbRootCount + 1
        enqueueFunction(address)
      end
    end
  end

  local functions = {}
  local disassemblyFunctions = {}
  while #functionQueue > 0 do
    local address = table.remove(functionQueue, 1)
    functionPending[address] = nil
    if not functionVisited[address] then
      functionVisited[address] = true
      local addrs = analyzeFunction(address)
      table.sort(addrs)
      local instructions = {}
      for _, addr in ipairs(addrs) do
        instructions[#instructions + 1] = decoded[addr]
      end
      functions[#functions + 1] = {
        entry = address,
        instructionCount = #instructions,
        blocks = buildBlocks(addrs),
      }
      disassemblyFunctions[#disassemblyFunctions + 1] = { entry = address, instructions = instructions }
    end
  end
  table.sort(functions, function(a, b)
    return a.entry < b.entry
  end)
  table.sort(disassemblyFunctions, function(a, b)
    return a.entry < b.entry
  end)

  local pointers = {}
  do
    local reader = imageReader(targetImage)
    local len = #targetImage.bytes
    local offset = 0
    while offset + 4 <= len do
      local address = targetImage.ramAddress + offset
      if not decoded[address] and not isClaimed(address) then
        local raw = reader:u32le(offset)
        local region = regionOf(raw)
        if region == "unknown" then
          region = regionOf(maskThumb(raw))
        end
        if region ~= "unknown" then
          pointers[#pointers + 1] = { address = address, value = raw, targetRegion = region }
        end
      end
      offset = offset + 4
    end
  end

  local callList = {}
  for _, call in pairs(calls) do
    callList[#callList + 1] = call
  end
  table.sort(callList, function(a, b)
    return a.site < b.site
  end)

  table.sort(literals, function(a, b)
    return a.address < b.address
  end)
  table.sort(switches, function(a, b)
    return a.address < b.address
  end)
  table.sort(gaps, function(a, b)
    return (a.address or -1) < (b.address or -1)
  end)

  local unknownInstructionCount, computedFlowGapCount = 0, 0
  for _, gap in ipairs(gaps) do
    if gap.kind == "unknown_instruction" then
      unknownInstructionCount = unknownInstructionCount + 1
    elseif gap.kind == "computed_pc_gap" then
      computedFlowGapCount = computedFlowGapCount + 1
    end
  end

  local instructionCount, blockCount = 0, 0
  for _, fn in ipairs(functions) do
    instructionCount = instructionCount + fn.instructionCount
    blockCount = blockCount + #fn.blocks
  end

  local evidence = {
    schema = "g4-app-analysis-1",
    target = { overlayId = overlayId, ramAddress = targetImage.ramAddress, size = #targetImage.bytes },
    entrypointCandidates = entrypointCandidates,
    functions = functions,
    switches = switches,
    calls = callList,
    literals = literals,
    pointers = pointers,
    gaps = gaps,
    coverage = {
      candidateCount = #entrypointCandidates,
      thumbRootCount = thumbRootCount,
      armRootCount = armRootCount,
      functionCount = #functions,
      blockCount = blockCount,
      instructionCount = instructionCount,
      unknownInstructionCount = unknownInstructionCount,
      computedFlowGapCount = computedFlowGapCount,
    },
  }
  return evidence, { functions = disassemblyFunctions }
end

return ApplicationAnalyzer
