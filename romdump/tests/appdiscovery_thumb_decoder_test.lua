-- Pure Thumb-1 instruction-boundary/flow decoding: one representative per
-- ordinary 16-bit encoding class, the long BL pair, PC-relative address
-- math, and malformed/reserved-encoding boundaries. All fixtures are
-- hand-assembled machine code; none of it is game-specific.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local ThumbDecoder = require("romdump.src.appdiscovery.ThumbDecoder")

local T = {}

local function u16le(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end

local function bytesOf(...)
  local parts = {}
  for _, v in ipairs({ ... }) do
    parts[#parts + 1] = u16le(v)
  end
  return table.concat(parts)
end

local BASE = 0x02100000

-- Format 1: move shifted register. LSLS R0, R1, #2 = 0x0088.
function T.decodes_move_shifted_register()
  local instr = assert(ThumbDecoder.decode(bytesOf(0x0088), 0, BASE))
  Assert.equal(instr.address, BASE)
  Assert.equal(instr.size, 2)
  Assert.deepEqual(instr.raw, { 0x0088 })
  Assert.equal(instr.mnemonic, "lsl")
  Assert.equal(instr.flow.kind, "sequential")
end

-- Format 2: add/subtract register. ADDS R0, R1, R2 = 0x1888.
function T.decodes_add_subtract_register()
  local instr = assert(ThumbDecoder.decode(bytesOf(0x1888), 0, BASE))
  Assert.equal(instr.size, 2)
  Assert.equal(instr.mnemonic, "add")
  Assert.equal(instr.flow.kind, "sequential")
end

-- Format 3: move/compare/add/subtract immediate. MOVS R0, #5 = 0x2005.
function T.decodes_immediate_move_compare_add_subtract()
  local instr = assert(ThumbDecoder.decode(bytesOf(0x2005), 0, BASE))
  Assert.equal(instr.mnemonic, "mov")
  Assert.equal(instr.operands.immediate, 5)
  Assert.equal(instr.flow.kind, "sequential")
end

-- Format 4: ALU operation. ANDS R0, R1 = 0x4008.
function T.decodes_alu_operation()
  local instr = assert(ThumbDecoder.decode(bytesOf(0x4008), 0, BASE))
  Assert.equal(instr.mnemonic, "and")
  Assert.equal(instr.flow.kind, "sequential")
end

-- Format 5: hi-register operation. BX LR = 0x4770 is an indirect return; the
-- register value is not known at decode time, so the target is a gap.
function T.decodes_hi_register_branch_exchange_as_indirect()
  local instr = assert(ThumbDecoder.decode(bytesOf(0x4770), 0, BASE))
  Assert.equal(instr.mnemonic, "bx")
  Assert.equal(instr.flow.kind, "indirect")
  Assert.isNil(instr.flow.target)
end

-- Format 6: PC-relative literal load. LDR R0, [PC, #4] at a word-aligned
-- address: PC reads as address+4, already word-aligned.
function T.decodes_pc_relative_literal_load_word_aligned()
  local instr = assert(ThumbDecoder.decode(bytesOf(0x4801), 0, BASE))
  Assert.equal(instr.mnemonic, "ldr")
  Assert.equal(instr.operands.literalAddress, BASE + 4 + 4)
  Assert.equal(instr.flow.kind, "sequential")
end

-- Same encoding at a halfword-aligned (not word-aligned) address: PC must be
-- masked to the word boundary before the literal offset is added.
function T.pc_relative_literal_load_rounds_pc_to_word_boundary()
  local address = BASE + 2
  local instr = assert(ThumbDecoder.decode(bytesOf(0x4801), 0, address))
  local roundedPc = address + 4 - ((address + 4) % 4)
  Assert.equal(instr.operands.literalAddress, roundedPc + 4)
end

-- Format 7: load/store with register offset. STR R0, [R1, R2] = 0x5088.
function T.decodes_load_store_register_offset()
  local instr = assert(ThumbDecoder.decode(bytesOf(0x5088), 0, BASE))
  Assert.equal(instr.mnemonic, "str")
  Assert.equal(instr.flow.kind, "sequential")
end

-- Format 8: sign-extended/halfword load-store with register offset.
-- LDRH R0, [R1, R2] = 0x5A88.
function T.decodes_sign_extended_load_store_register_offset()
  local instr = assert(ThumbDecoder.decode(bytesOf(0x5A88), 0, BASE))
  Assert.equal(instr.mnemonic, "ldrh")
  Assert.equal(instr.flow.kind, "sequential")
end

-- Format 9: load/store with immediate offset. STR R0, [R1, #4] = 0x6048.
function T.decodes_load_store_immediate_offset()
  local instr = assert(ThumbDecoder.decode(bytesOf(0x6048), 0, BASE))
  Assert.equal(instr.mnemonic, "str")
  Assert.equal(instr.operands.immediate, 4)
end

-- Format 10: load/store halfword. STRH R0, [R1, #2] = 0x8048.
function T.decodes_load_store_halfword()
  local instr = assert(ThumbDecoder.decode(bytesOf(0x8048), 0, BASE))
  Assert.equal(instr.mnemonic, "strh")
  Assert.equal(instr.operands.immediate, 2)
end

-- Format 11: SP-relative load/store. STR R0, [SP, #4] = 0x9001.
function T.decodes_sp_relative_load_store()
  local instr = assert(ThumbDecoder.decode(bytesOf(0x9001), 0, BASE))
  Assert.equal(instr.mnemonic, "str")
  Assert.equal(instr.operands.immediate, 4)
end

-- Format 12: load address, ADR form. ADD R0, PC, #4 = 0xA001.
function T.decodes_load_address_from_pc_as_adr()
  local instr = assert(ThumbDecoder.decode(bytesOf(0xA001), 0, BASE))
  Assert.equal(instr.mnemonic, "adr")
  Assert.equal(instr.operands.address, BASE + 4 + 4)
end

-- Format 12: load address, SP form. ADD R0, SP, #4 = 0xA801.
function T.decodes_load_address_from_sp()
  local instr = assert(ThumbDecoder.decode(bytesOf(0xA801), 0, BASE))
  Assert.equal(instr.mnemonic, "add")
  Assert.equal(instr.operands.base, "sp")
end

-- Format 13: adjust SP. SUB SP, #4 = 0xB081.
function T.decodes_adjust_stack_pointer()
  local instr = assert(ThumbDecoder.decode(bytesOf(0xB081), 0, BASE))
  Assert.equal(instr.mnemonic, "sub")
  Assert.equal(instr.operands.immediate, 4)
end

-- Format 14: push/pop register list. POP {R0, PC} = 0xBD01 is a return.
function T.decodes_pop_including_pc_as_return()
  local instr = assert(ThumbDecoder.decode(bytesOf(0xBD01), 0, BASE))
  Assert.equal(instr.mnemonic, "pop")
  Assert.equal(instr.flow.kind, "return")
end

-- PUSH {R0, LR} = 0xB501 falls through normally.
function T.decodes_push_including_lr()
  local instr = assert(ThumbDecoder.decode(bytesOf(0xB501), 0, BASE))
  Assert.equal(instr.mnemonic, "push")
  Assert.equal(instr.flow.kind, "sequential")
end

-- Format 15: load/store multiple. STMIA R0!, {R1} = 0xC002.
function T.decodes_store_multiple()
  local instr = assert(ThumbDecoder.decode(bytesOf(0xC002), 0, BASE))
  Assert.equal(instr.mnemonic, "stmia")
  Assert.equal(instr.flow.kind, "sequential")
end

-- Format 16: conditional branch. BEQ with SOffset8=2 -> target = PC+4+4.
function T.decodes_conditional_branch_with_exact_target()
  local instr = assert(ThumbDecoder.decode(bytesOf(0xD002), 0, BASE))
  Assert.equal(instr.mnemonic, "b")
  Assert.equal(instr.flow.kind, "branch")
  Assert.isTrue(instr.flow.conditional)
  Assert.equal(instr.flow.condition, "eq")
  Assert.equal(instr.flow.target, BASE + 4 + 4)
end

-- Format 18: unconditional branch. Offset11=2 -> target = PC+4+4.
function T.decodes_unconditional_branch_with_exact_target()
  local instr = assert(ThumbDecoder.decode(bytesOf(0xE002), 0, BASE))
  Assert.equal(instr.mnemonic, "b")
  Assert.equal(instr.flow.kind, "branch")
  Assert.isFalse(instr.flow.conditional)
  Assert.equal(instr.flow.target, BASE + 4 + 4)
end

-- Format 19: long BL pair. high=0, low=5 -> offset=10, target=addr+4+10.
function T.decodes_long_branch_with_link_pair_with_exact_target()
  local bytes = bytesOf(0xF000, 0xF805)
  local instr = assert(ThumbDecoder.decode(bytes, 0, BASE))
  Assert.equal(instr.size, 4)
  Assert.deepEqual(instr.raw, { 0xF000, 0xF805 })
  Assert.equal(instr.mnemonic, "bl")
  Assert.equal(instr.flow.kind, "call")
  Assert.equal(instr.flow.target, BASE + 4 + 10)
end

-- A valid first halfword with no matching second halfword (an ordinary
-- instruction instead of a 11111/11101-prefixed continuation) never invents
-- a pairing; it becomes an explicit unknown instruction.
function T.long_branch_first_half_without_matching_second_half_is_unknown()
  local bytes = bytesOf(0xF000, 0x0088)
  local instr = assert(ThumbDecoder.decode(bytes, 0, BASE))
  Assert.equal(instr.mnemonic, "unknown_instruction")
  Assert.equal(instr.flow.kind, "unknown")
end

-- A lone second-half-only pattern with no preceding first half is reserved:
-- it never decodes as an ordinary instruction on its own.
function T.orphaned_long_branch_second_half_is_unknown()
  local instr = assert(ThumbDecoder.decode(bytesOf(0xF800), 0, BASE))
  Assert.equal(instr.mnemonic, "unknown_instruction")
  Assert.equal(instr.flow.kind, "unknown")
  Assert.equal(instr.size, 2)
end

-- Malformed caller range (fewer bytes than the instruction needs) is a
-- structured decoder failure, never a raw Lua indexing error.
function T.malformed_range_returns_structured_error()
  local instr, err = ThumbDecoder.decode("\1", 0, BASE)
  Assert.isNil(instr)
  Assert.isTrue(Errors.is(err), "expected a structured Errors.Error")
end

function T.out_of_range_offset_returns_structured_error()
  local instr, err = ThumbDecoder.decode(bytesOf(0x0088), 4, BASE)
  Assert.isNil(instr)
  Assert.isTrue(Errors.is(err), "expected a structured Errors.Error")
end

return { tests = T }
