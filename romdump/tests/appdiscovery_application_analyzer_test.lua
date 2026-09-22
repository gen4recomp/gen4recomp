-- Structural application analysis: template/root discovery, conservative
-- Thumb reachability with exact-value joins and call-argument capture, and
-- generic recovery of a bounded signed-halfword PC-relative switch. Every
-- fixture is hand-assembled synthetic Thumb code; none of it encodes any
-- particular game's addresses or constants.

local Assert = require("tests.support.Assert")
local NdsRom = require("romdump.src.source.NdsRom")
local RomSource = require("romdump.src.source.RomSource")
local NdsBuilder = require("tests.support.NdsBuilder")
local RomImage = require("romdump.src.appdiscovery.RomImage")
local ApplicationAnalyzer = require("romdump.src.appdiscovery.ApplicationAnalyzer")

local T = {}

local OVERLAY_ID = 0
local OVERLAY_RAM = 0x02100000

local function u16le(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end

local function u32le(v)
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

local function hw(...)
  local parts = {}
  for _, v in ipairs({ ... }) do
    parts[#parts + 1] = u16le(v)
  end
  return table.concat(parts)
end

local function padTo(bytes, alignment)
  local remainder = #bytes % alignment
  if remainder == 0 then
    return bytes
  end
  return bytes .. string.rep("\0", alignment - remainder)
end

local function matchingVersions(data, gameCode)
  local info = { sha1 = RomSource.fromString(data):sha1(), gameCode = gameCode, expectedSize = #data }
  return {
    forSha1 = function(h)
      return h == info.sha1 and info or nil
    end,
    forGameCode = function(c)
      return c == gameCode and info or nil
    end,
  }
end

-- Builds a single-overlay ROM (overlayId 0) from raw overlay bytes and
-- returns its RomImage plus the overlay id to analyze.
local function buildImage(overlayId, content)
  local spec = {
    gameCode = "IPKE",
    title = "TESTHG",
    overlays9 = { { content = content, ramAddress = OVERLAY_RAM, ramSize = #content, flags = 0 } },
  }
  local data = NdsBuilder.build(spec)
  local rom = assert(NdsRom.open(RomSource.fromString(data), matchingVersions(data, "IPKE")))
  return RomImage.new(rom), overlayId
end

local function buildMultiOverlayImage(overlays, overlayId)
  local data = NdsBuilder.build({
    gameCode = "IPKE",
    title = "TESTHG",
    overlays9 = overlays,
  })
  local rom = assert(NdsRom.open(RomSource.fromString(data), matchingVersions(data, "IPKE")))
  return RomImage.new(rom), overlayId
end

local function template(initAddr, mainAddr, exitAddr, overlayId)
  return u32le(initAddr) .. u32le(mainAddr) .. u32le(exitAddr) .. u32le(overlayId)
end

local function findByAddress(list, address)
  for _, item in ipairs(list) do
    if item.address == address then
      return item
    end
  end
  return nil
end

local function findCallBySite(calls, site)
  for _, call in ipairs(calls) do
    if call.site == site then
      return call
    end
  end
  return nil
end

---@param evidence ApplicationAnalyzer.Evidence
---@param entry integer
---@return ApplicationAnalyzer.FunctionEvidence|nil
local function findFunctionByEntry(evidence, entry)
  for _, fn in ipairs(evidence.functions) do
    if fn.entry == entry then
      return fn
    end
  end
  return nil
end

---@param disassembly ApplicationAnalyzer.Disassembly
---@param entry integer
---@return ApplicationAnalyzer.DisassemblyFunction|nil
local function findDisassemblyFunctionByEntry(disassembly, entry)
  disassembly = assert(disassembly, "analyzer must return transient disassembly as its second value")
  for _, fn in ipairs(disassembly.functions) do
    if fn.entry == entry then
      return fn
    end
  end
  return nil
end

--------------------------------------------------------------------------
-- Candidate/template discovery
--------------------------------------------------------------------------

function T.discovers_a_launcher_template_in_a_sibling_arm9_overlay()
  local sourceOverlayId = 0
  local targetOverlayId = 1
  local targetRam = 0x02200000
  local targetContent = padTo(hw(0x4770, 0x4770, 0x4770), 4)
  local sourceContent = template(targetRam + 0 + 1, targetRam + 2 + 1, targetRam + 4 + 1, targetOverlayId)
  local image, overlayId = buildMultiOverlayImage({
    { content = sourceContent, ramAddress = 0x02100000, ramSize = #sourceContent, flags = 0 },
    { content = targetContent, ramAddress = targetRam, ramSize = #targetContent, flags = 0 },
  }, targetOverlayId)
  local evidence, _ = ApplicationAnalyzer.analyze(image, overlayId)

  Assert.equal(#evidence.entrypointCandidates, 1)
  local candidate = evidence.entrypointCandidates[1]
  Assert.equal(candidate.sourceRegion, "arm9-overlay:" .. tostring(sourceOverlayId))
  Assert.equal(candidate.initTarget, targetRam + 1)
  Assert.equal(candidate.mainTarget, targetRam + 3)
  Assert.equal(candidate.exitTarget, targetRam + 5)
  for _, fn in ipairs(evidence.functions) do
    Assert.isTrue(fn.entry >= targetRam and fn.entry < targetRam + #targetContent)
  end
end

function T.mixed_state_template_decodes_only_thumb_roots_and_reports_arm_root_gap()
  local content = padTo(hw(0x4770, 0x4770, 0x4770), 4)
  content = content .. template(OVERLAY_RAM + 0 + 1, OVERLAY_RAM + 2, OVERLAY_RAM + 4 + 1, OVERLAY_ID)

  local image, overlayId = buildImage(OVERLAY_ID, content)
  local evidence, _ = ApplicationAnalyzer.analyze(image, overlayId)

  Assert.equal(#evidence.entrypointCandidates, 1)
  local candidate = evidence.entrypointCandidates[1]
  Assert.equal(candidate.initState, "thumb")
  Assert.equal(candidate.mainState, "arm")
  Assert.equal(candidate.exitState, "thumb")
  Assert.isNil(candidate.state)
  Assert.equal(evidence.coverage.candidateCount, 1)
  Assert.equal(evidence.coverage.thumbRootCount, 2)
  Assert.equal(evidence.coverage.armRootCount, 1)
  local sawInit, sawExit, sawArm = false, false, false
  for _, fn in ipairs(evidence.functions) do
    sawInit = sawInit or fn.entry == OVERLAY_RAM
    sawExit = sawExit or fn.entry == OVERLAY_RAM + 4
    sawArm = sawArm or fn.entry == OVERLAY_RAM + 2
  end
  Assert.isTrue(sawInit)
  Assert.isTrue(sawExit)
  Assert.isFalse(sawArm)
  local armGap = assert(findByAddress(evidence.gaps, OVERLAY_RAM + 2))
  Assert.equal(armGap.kind, "arm_root_unsupported")
end

function T.reports_no_entrypoint_candidate_gap_when_none_is_structurally_valid()
  local content = string.rep("\0", 16)
  local image, overlayId = buildImage(OVERLAY_ID, content)
  local evidence, _ = ApplicationAnalyzer.analyze(image, overlayId)

  Assert.equal(#evidence.entrypointCandidates, 0)
  Assert.equal(#evidence.functions, 0)
  local gap = nil
  for _, g in ipairs(evidence.gaps) do
    if g.kind == "no_entrypoint_candidate" then
      gap = g
    end
  end
  Assert.notNil(gap, "expected a no_entrypoint_candidate gap")
end

--------------------------------------------------------------------------
-- Conservative reachability: exact joins, direct calls, stack argument,
-- callee-saved survival, indirect flow, and a reserved encoding.
--------------------------------------------------------------------------

function T.recovers_direct_calls_stack_argument_and_conservative_joins()
  -- 0:  MOVS R4, #5          callee-saved constant, set before any call
  -- 2:  MOVS R0, #42         caller-saved constant
  -- 4:  CMP R0, #42
  -- 6:  BEQ pathA
  -- 8:  MOVS R2, #9          pathB: differs from pathA
  -- 10: MOVS R3, #7          pathB: same as pathA
  -- 12: B merge
  -- 14: pathA: MOVS R2, #7   differs from pathB
  -- 16: MOVS R3, #7          same as pathB
  -- 18: merge: STR R0, [SP, #0]   provable outgoing stack word
  -- 20: BL callee1 (4 bytes)
  -- 24: ADDS R0, R4, #0      copy the callee-saved value back into r0
  -- 26: BL callee2 (4 bytes)
  -- 30: BX R5                unknown target: computed-flow gap
  local flowFn = hw(
    0x2405,
    0x202A,
    0x282A,
    0xD002,
    0x2209,
    0x2307,
    0xE001,
    0x2207,
    0x2307,
    0x9000,
    0xF000,
    0xF804,
    0x1C20,
    0xF000,
    0xF802,
    0x4728
  )
  Assert.equal(#flowFn, 32)

  local callee1Offset = #flowFn
  local calleesBytes = hw(0x4770, 0x4770) -- callee1 then callee2, 2 bytes each
  local callee2Offset = callee1Offset + 2

  local content = flowFn .. calleesBytes
  local initOffset = #content
  content = content .. hw(0x4770) -- trivial Init stub
  content = padTo(content, 4)
  local exitOffset = #content
  content = content .. hw(0xF800) -- reserved encoding as the Exit root
  content = padTo(content, 4)
  content = content
    .. template(OVERLAY_RAM + initOffset + 1, OVERLAY_RAM + 0 + 1, OVERLAY_RAM + exitOffset + 1, OVERLAY_ID)

  local image, overlayId = buildImage(OVERLAY_ID, content)
  local evidence, _ = ApplicationAnalyzer.analyze(image, overlayId)

  local mainFn = nil
  for _, fn in ipairs(evidence.functions) do
    if fn.entry == OVERLAY_RAM + 0 then
      mainFn = fn
    end
  end
  assert(mainFn, "expected a decoded function rooted at the Main entrypoint")

  local call1 = assert(findCallBySite(evidence.calls, OVERLAY_RAM + 20), "missing call at the first BL site")
  Assert.equal(call1.target, OVERLAY_RAM + callee1Offset)
  Assert.equal(call1.knownArgs.registers.r0, 42)
  Assert.equal(call1.knownArgs.registers.r3, 7)
  Assert.isNil(call1.knownArgs.registers.r2, "differing join must not carry an exact value")
  assert(call1.knownArgs.stack, "the SP-relative store must be recorded as a provable stack word")

  local call2 = assert(findCallBySite(evidence.calls, OVERLAY_RAM + 26), "missing call at the second BL site")
  Assert.equal(call2.target, OVERLAY_RAM + callee2Offset)
  Assert.equal(call2.knownArgs.registers.r0, 5, "r4 must survive the first call and be observable via r0")
  Assert.isNil(call2.knownArgs.registers.r2, "r2 remains clobbered after the first call")
  Assert.isNil(call2.knownArgs.registers.r3, "r3 remains clobbered after the first call")

  local indirectGap = findByAddress(evidence.gaps, OVERLAY_RAM + 30)
  Assert.notNil(indirectGap, "expected a computed-flow gap at the indirect bx")

  local reservedGap = findByAddress(evidence.gaps, OVERLAY_RAM + exitOffset)
  Assert.notNil(reservedGap, "expected a gap at the reserved-encoding root")
end

function T.immediate_blx_records_arm_target_without_decoding_it_as_thumb()
  local content = hw(0xF000, 0xE806, 0x2001, 0x4770) .. string.rep("\0", 8) .. hw(0x4770)
  content = padTo(content, 4)
  content = content .. template(OVERLAY_RAM + 1, OVERLAY_RAM + 1, OVERLAY_RAM + 1, OVERLAY_ID)

  local image, overlayId = buildImage(OVERLAY_ID, content)
  local evidence, disassembly = ApplicationAnalyzer.analyze(image, overlayId)
  disassembly = assert(disassembly, "analyzer must return transient disassembly as its second value")
  local call = assert(findCallBySite(evidence.calls, OVERLAY_RAM), "missing immediate BLX call")
  Assert.equal(call.target, OVERLAY_RAM + 16)
  Assert.equal(call.targetState, "arm")
  local gap = assert(findByAddress(evidence.gaps, OVERLAY_RAM), "missing unsupported ARM call gap")
  Assert.equal(gap.kind, "arm_call_target_unsupported")
  Assert.equal(gap.target, OVERLAY_RAM + 16)
  Assert.equal(gap.region, "target")
  local caller = nil
  for _, fn in ipairs(evidence.functions) do
    Assert.isFalse(fn.entry == OVERLAY_RAM + 16, "ARM target must not become a Thumb function root")
    if fn.entry == OVERLAY_RAM then
      caller = fn
    end
  end
  caller = assert(caller, "missing BLX caller function")
  local callerDisassembly = assert(findDisassemblyFunctionByEntry(disassembly, caller.entry))
  local sawFallthrough = false
  for _, instruction in ipairs(callerDisassembly.instructions) do
    if instruction.address == OVERLAY_RAM + 4 then
      sawFallthrough = true
    end
  end
  Assert.isTrue(sawFallthrough, "Thumb fallthrough after BLX must remain reachable")
end

function T.sub_sp_rebases_exact_stack_argument_offsets()
  local content = hw(
    0x202A, -- MOVS R0, #42
    0x9000, -- STR R0, [SP, #0]
    0xB081, -- SUB SP, #4
    0xF000,
    0xF801, -- BL local callee
    0x4770,
    0x4770
  )
  content = padTo(content, 4)
  local callSite = OVERLAY_RAM + 6
  local callee = OVERLAY_RAM + 12
  content = content .. template(OVERLAY_RAM + 1, OVERLAY_RAM + 1, OVERLAY_RAM + 1, OVERLAY_ID)

  local image, overlayId = buildImage(OVERLAY_ID, content)
  local evidence = ApplicationAnalyzer.analyze(image, overlayId)
  local call = assert(findCallBySite(evidence.calls, callSite), "missing call after SUB SP")
  Assert.equal(call.target, callee)
  local stack = assert(call.knownArgs.stack)
  Assert.equal(stack[4], 42)
  Assert.isNil(stack[0])
end

function T.push_pop_preserves_provable_values_without_leaking_unknown_words()
  local content = hw(
    0x2007, -- MOVS R0, #7
    0xB505, -- PUSH {R0, R2, LR}; R2 and LR are unknown
    0xF000,
    0xF805, -- BL local callee 1
    0xBC05, -- POP {R0, R2}
    0xB001, -- ADD SP, #4
    0xF000,
    0xF802, -- BL local callee 2
    0x4770,
    0x4770,
    0x4770
  )
  content = padTo(content, 4)
  content = content .. template(OVERLAY_RAM + 1, OVERLAY_RAM + 1, OVERLAY_RAM + 1, OVERLAY_ID)

  local image, overlayId = buildImage(OVERLAY_ID, content)
  local evidence = ApplicationAnalyzer.analyze(image, overlayId)
  local call1 = assert(findCallBySite(evidence.calls, OVERLAY_RAM + 4), "missing call while pushed values are live")
  local call1Stack = assert(call1.knownArgs.stack)
  Assert.equal(call1Stack[0], 7)
  Assert.isNil(call1Stack[4])
  Assert.isNil(call1Stack[8])

  local call2 = assert(findCallBySite(evidence.calls, OVERLAY_RAM + 12), "missing call after POP")
  Assert.equal(call2.knownArgs.registers.r0, 7)
  Assert.isNil(call2.knownArgs.registers.r2)
  local stack = assert(call2.knownArgs.stack)
  Assert.isNil(next(stack), "popped words below the restored SP must not be outgoing arguments")
end

function T.ldmia_with_r7_reaches_the_sequential_fallthrough()
  local content = hw(0xC880, 0x4770) -- LDMIA R0!, {R7}; BX LR
  content = content .. template(OVERLAY_RAM + 1, OVERLAY_RAM + 1, OVERLAY_RAM + 1, OVERLAY_ID)

  local image, overlayId = buildImage(OVERLAY_ID, content)
  local evidence, disassembly = ApplicationAnalyzer.analyze(image, overlayId)
  assert(findFunctionByEntry(evidence, OVERLAY_RAM), "expected LDMIA root function")
  local disassemblyFn = assert(findDisassemblyFunctionByEntry(disassembly, OVERLAY_RAM))
  Assert.equal(#disassemblyFn.instructions, 2)
  Assert.equal(disassemblyFn.instructions[2].address, OVERLAY_RAM + 2)
  Assert.isNil(findByAddress(evidence.gaps, OVERLAY_RAM))
end

function T.late_state_widening_does_not_duplicate_function_membership()
  local content = hw(
    0x2001, -- MOVS R0, #1
    0xD000, -- BEQ target
    0xE001, -- B merge (short path)
    0x2002, -- target: MOVS R0, #2
    0xE7FF, -- B merge (long path)
    0x2103, -- merge: MOVS R1, #3
    0x4770 -- BX LR
  )
  content = padTo(content, 4)
  content = content .. template(OVERLAY_RAM + 1, OVERLAY_RAM + 1, OVERLAY_RAM + 1, OVERLAY_ID)

  local image, overlayId = buildImage(OVERLAY_ID, content)
  local evidence, disassembly = ApplicationAnalyzer.analyze(image, overlayId)
  local fn = assert(findFunctionByEntry(evidence, OVERLAY_RAM), "expected widened merge function")
  local disassemblyFn = assert(findDisassemblyFunctionByEntry(disassembly, OVERLAY_RAM))
  Assert.keySet(fn, "blocks,entry,instructionCount", "compact function evidence must be structural")
  Assert.equal(fn.instructionCount, #disassemblyFn.instructions)
  Assert.isNil(rawget(fn, "instructions"))
  local instructionAddresses = {}
  for _, instr in ipairs(disassemblyFn.instructions) do
    Assert.isNil(instructionAddresses[instr.address], "function instruction membership must be unique")
    instructionAddresses[instr.address] = true
  end
  local blockStarts = {}
  for _, block in ipairs(fn.blocks) do
    Assert.isNil(rawget(block, "instructions"))
    Assert.keySet(block, "endExclusive,instructionCount,start", "compact block evidence must be structural")
    Assert.isNil(blockStarts[block.start], "basic-block membership must be unique")
    blockStarts[block.start] = true
  end
  Assert.equal(disassemblyFn.instructions[#disassemblyFn.instructions].address, OVERLAY_RAM + 12)
  Assert.equal(evidence.coverage.instructionCount, fn.instructionCount)
  Assert.equal(evidence.coverage.blockCount, #fn.blocks)
end

function T.compact_function_and_block_evidence_has_one_matching_disassembly_owner()
  local content = hw(
    0x2001, -- MOVS R0, #1
    0xD000, -- BEQ target
    0xE001, -- B merge (short path)
    0x2002, -- target: MOVS R0, #2
    0xE7FF, -- B merge (long path)
    0x2103, -- merge: MOVS R1, #3
    0x4770 -- BX LR
  )
  content = padTo(content, 4)
  content = content .. template(OVERLAY_RAM + 1, OVERLAY_RAM + 1, OVERLAY_RAM + 1, OVERLAY_ID)

  local image, overlayId = buildImage(OVERLAY_ID, content)
  local evidence, disassembly = ApplicationAnalyzer.analyze(image, overlayId)
  disassembly = assert(disassembly, "analyzer must return transient disassembly as its second value")

  Assert.equal(#evidence.functions, #disassembly.functions)
  for i, fn in ipairs(evidence.functions) do
    local disassemblyFn = assert(disassembly.functions[i])
    Assert.equal(fn.entry, disassemblyFn.entry)
    Assert.equal(fn.instructionCount, #disassemblyFn.instructions)
    Assert.isNil(rawget(fn, "instructions"))
    Assert.keySet(fn, "blocks,entry,instructionCount", "compact function evidence must be structural")
    local blockInstructionCount = 0
    for _, block in ipairs(fn.blocks) do
      Assert.isNil(rawget(block, "instructions"))
      Assert.keySet(block, "endExclusive,instructionCount,start", "compact block evidence must be structural")
      blockInstructionCount = blockInstructionCount + block.instructionCount
    end
    Assert.equal(blockInstructionCount, fn.instructionCount)
  end
  local totalInstructionCount = 0
  for _, disassemblyFn in ipairs(disassembly.functions) do
    totalInstructionCount = totalInstructionCount + #disassemblyFn.instructions
  end
  Assert.equal(evidence.coverage.instructionCount, totalInstructionCount)
end

-- A direct (non-computed) branch whose statically known target lies outside
-- every recognized executable image must still retain that absolute target
-- and an "unknown" region on its gap record, rather than only noting where
-- the branch itself sits.
function T.direct_branch_outside_known_images_retains_absolute_target()
  local content = hw(0xE3FF) -- B with offset11 = 0x3FF: target = addr+4+2046
  content = padTo(content, 4)
  local initOffset = #content
  content = content .. hw(0x4770) -- trivial Init stub
  content = padTo(content, 4)
  local exitOffset = #content
  content = content .. hw(0x4770) -- trivial Exit stub
  content = padTo(content, 4)
  content = content
    .. template(OVERLAY_RAM + initOffset + 1, OVERLAY_RAM + 0 + 1, OVERLAY_RAM + exitOffset + 1, OVERLAY_ID)

  local image, overlayId = buildImage(OVERLAY_ID, content)
  local evidence, _ = ApplicationAnalyzer.analyze(image, overlayId)

  local gap = findByAddress(evidence.gaps, OVERLAY_RAM + 0)
  Assert.notNil(gap, "expected a gap at the out-of-region branch")
  ---@cast gap table
  Assert.equal(gap.kind, "branch_target_unknown_region")
  Assert.equal(gap.target, OVERLAY_RAM + 4 + 2046)
  Assert.equal(gap.region, "unknown")
end

--------------------------------------------------------------------------
-- Generic bounded signed-halfword switch recovery (structural, no hard-coded
-- case count or address).
--------------------------------------------------------------------------

local CASE_COUNT = 38

-- Builds the Bag-style dispatcher structural idiom at overlay offset
-- `dispatcherOffset` (must be a multiple of 4): bounds check, doubled
-- selector, PC-relative table load, and PC += table[selector]. Table entries
-- are optionally overridden (for the corrupted fixture). `idiom` selects the
-- concrete instruction shape the compiler uses to prepare/load the table
-- entry:
--   "ldsh"   a distinct table-base register from `ADR`, register-offset
--            `LDRSH rd, [rb, ro]` sign-extending the load in one instruction
--            (the idiom this repository originally recognized).
--   "pcfold" the doubled selector folded directly into the PC-relative table
--            base via a two-operand hi-register `ADD rd, rd, PC` (no `ADR`),
--            then an immediate-offset `LDRH rd, [rd, #imm]` reusing that same
--            register as both base and destination, sign-extended via
--            `LSL #16` / `ASR #16` (the real Bag_Main compiler output).
local function buildSwitchOverlay(corruptEntryIndex, idiom)
  idiom = idiom or "ldsh"
  local dispatcherOffset = 32
  assert(dispatcherOffset % 4 == 0)

  local preamble, addPcOffset
  if idiom == "ldsh" then
    preamble = hw(
      0x2825, -- CMP R0, #37
      0xD875, -- BHI default (offset8 = 117)
      0x0040, -- LSL R0, R0, #1
      0xA101, -- ADR R1, table (word8 = 1)
      0x5E08, -- LDRSH R0, [R1, R0]
      0x4487 -- ADD PC, PC, R0
    )
    Assert.equal(#preamble, 12)
    addPcOffset = dispatcherOffset + 10
  elseif idiom == "pcfold" then
    preamble = hw(
      0x2825, -- CMP R0, #37
      0xD877, -- BHI default (offset8 = 119)
      0x1800, -- ADD R0, R0, R0 (double selector via self-add)
      0x4478, -- ADD R0, R0, PC (fold doubled selector into PC-relative base)
      0x88C0, -- LDRH R0, [R0, #6] (immediate-offset load, R0 as base and dest)
      0x0400, -- LSL R0, R0, #16
      0x1400, -- ASR R0, R0, #16
      0x4487 -- ADD PC, PC, R0
    )
    Assert.equal(#preamble, 16)
    addPcOffset = dispatcherOffset + 14
  else
    error("unknown idiom " .. tostring(idiom))
  end

  local tableOffset = dispatcherOffset + #preamble
  local casesOffset = tableOffset + CASE_COUNT * 2
  local tableEntries = {}
  for i = 0, CASE_COUNT - 1 do
    local caseAddress = OVERLAY_RAM + casesOffset + i * 4
    local addPcAddress = OVERLAY_RAM + addPcOffset
    tableEntries[#tableEntries + 1] = caseAddress - (addPcAddress + 4)
  end
  if corruptEntryIndex ~= nil then
    tableEntries[corruptEntryIndex + 1] = 0x7FFE -- points far outside the overlay
  end
  local table_ = hw(unpack(tableEntries))

  local cases = {}
  for i = 0, CASE_COUNT - 1 do
    cases[#cases + 1] = hw(0x2200 + i, 0x4770) -- MOVS R2, #i ; BX LR
  end
  local casesBytes = table.concat(cases)

  local defaultOffset = casesOffset + CASE_COUNT * 4
  local defaultBytes = hw(0x4770) -- BX LR

  local content = string.rep("\0", dispatcherOffset) .. preamble .. table_ .. casesBytes .. defaultBytes
  content = padTo(content, 4)
  local exitOffset = #content
  content = content .. hw(0x4770) -- trivial Exit stub
  content = padTo(content, 4)
  content = content
    .. template(
      OVERLAY_RAM + exitOffset + 1,
      OVERLAY_RAM + dispatcherOffset + 1,
      OVERLAY_RAM + exitOffset + 1,
      OVERLAY_ID
    )

  return content, dispatcherOffset, defaultOffset
end

function T.recognizes_generic_bounded_switch_with_ordered_cases()
  local content = buildSwitchOverlay(nil)
  local image, overlayId = buildImage(OVERLAY_ID, content)
  local evidence, disassembly = ApplicationAnalyzer.analyze(image, overlayId)
  disassembly = assert(disassembly, "analyzer must return transient disassembly as its second value")

  Assert.equal(#evidence.switches, 1)
  local switch = evidence.switches[1]
  Assert.equal(#switch.cases, CASE_COUNT)
  for i, case in ipairs(switch.cases) do
    Assert.equal(case.value, i - 1)
  end

  -- The table bytes are claimed as data: no instruction may be decoded at
  -- any table address.
  local dispatcherOffset = 32
  local tableStart = OVERLAY_RAM + dispatcherOffset + 12
  local tableEnd = tableStart + CASE_COUNT * 2
  for _, fn in ipairs(disassembly.functions) do
    for _, instr in ipairs(fn.instructions) do
      Assert.isTrue(
        instr.address < tableStart or instr.address >= tableEnd,
        "table bytes must never be decoded as instructions"
      )
    end
  end
end

function T.recognizes_generic_bounded_switch_with_pc_folded_immediate_ldrh_sign_extend()
  local content = buildSwitchOverlay(nil, "pcfold")
  local image, overlayId = buildImage(OVERLAY_ID, content)
  local evidence, disassembly = ApplicationAnalyzer.analyze(image, overlayId)
  disassembly = assert(disassembly, "analyzer must return transient disassembly as its second value")

  Assert.equal(#evidence.switches, 1)
  local switch = evidence.switches[1]
  Assert.equal(#switch.cases, CASE_COUNT)
  for i, case in ipairs(switch.cases) do
    Assert.equal(case.value, i - 1)
  end

  -- The table bytes are claimed as data: no instruction may be decoded at
  -- any table address.
  local dispatcherOffset = 32
  local tableStart = OVERLAY_RAM + dispatcherOffset + 16
  local tableEnd = tableStart + CASE_COUNT * 2
  for _, fn in ipairs(disassembly.functions) do
    for _, instr in ipairs(fn.instructions) do
      Assert.isTrue(
        instr.address < tableStart or instr.address >= tableEnd,
        "table bytes must never be decoded as instructions"
      )
    end
  end
end

function T.rejects_switch_with_corrupted_table_target()
  local content = buildSwitchOverlay(0)
  local image, overlayId = buildImage(OVERLAY_ID, content)
  local evidence = ApplicationAnalyzer.analyze(image, overlayId)

  Assert.equal(#evidence.switches, 0)
  local dispatcherOffset = 32
  local addPcAddress = OVERLAY_RAM + dispatcherOffset + 10
  local gap = findByAddress(evidence.gaps, addPcAddress)
  Assert.notNil(gap, "an invalidated switch must retain computed-flow evidence instead")
end

--------------------------------------------------------------------------
-- Determinism
--------------------------------------------------------------------------

function T.analysis_is_deterministic_for_identical_input()
  local content = buildSwitchOverlay(nil)
  local image1, overlayId1 = buildImage(OVERLAY_ID, content)
  local evidence1, disassembly1 = ApplicationAnalyzer.analyze(image1, overlayId1)
  local image2, overlayId2 = buildImage(OVERLAY_ID, content)
  local evidence2, disassembly2 = ApplicationAnalyzer.analyze(image2, overlayId2)
  Assert.deepEqual(evidence1, evidence2)
  Assert.deepEqual(disassembly1, disassembly2)
end

return { tests = T }
