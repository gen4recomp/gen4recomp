-- Pure Thumb-1 16-bit instruction decoder plus ARMv5TE long BL/BLX pairs.
-- Classifies by architectural bit pattern only; reserved/unimplemented
-- encodings decode to an explicit unknown_instruction record rather than
-- raising or being treated as a NOP. Follows the Arm RealView Thumb
-- instruction summary; no application-specific opcode recognition.

local BinaryReader = require("libs.codec.src.BinaryReader")
local Errors = require("libs.errors.src.Errors")

---@class ThumbDecoder.Instruction
---@field address integer
---@field size integer
---@field raw integer[]
---@field mnemonic string
---@field operands table<string, unknown>
---@field flow table<string, unknown>

local ThumbDecoder = {}

local COND_NAMES = { [0] = "eq", "ne", "cs", "cc", "mi", "pl", "vs", "vc", "hi", "ls", "ge", "lt", "gt", "le" }
local ALU_MNEMONICS = {
  [0] = "and",
  "eor",
  "lsl",
  "lsr",
  "asr",
  "adc",
  "sbc",
  "ror",
  "tst",
  "neg",
  "cmp",
  "cmn",
  "orr",
  "mul",
  "bic",
  "mvn",
}
local SHIFT_MNEMONICS = { [0] = "lsl", "lsr", "asr" }

local function bits(value, hi, lo)
  local width = hi - lo + 1
  return math.floor(value / 2 ^ lo) % (2 ^ width)
end

local function signExtend(value, width)
  local half = 2 ^ (width - 1)
  if value >= half then
    return value - 2 ^ width
  end
  return value
end

local function wordAlignedPc(address)
  local pc = address + 4
  return pc - (pc % 4)
end

local function unknownInstruction(address, size, raw)
  return {
    address = address,
    size = size,
    raw = raw,
    mnemonic = "unknown_instruction",
    operands = {},
    flow = { kind = "unknown" },
  }
end

local function sequential(address, size, raw, mnemonic, operands)
  return {
    address = address,
    size = size,
    raw = raw,
    mnemonic = mnemonic,
    operands = operands,
    flow = { kind = "sequential" },
  }
end

-- Format 1: move shifted register.
local function decodeFormat1(address, raw, hw1)
  local op = bits(hw1, 12, 11)
  local offset5 = bits(hw1, 10, 6)
  local rs = bits(hw1, 5, 3)
  local rd = bits(hw1, 2, 0)
  return sequential(address, 2, raw, SHIFT_MNEMONICS[op], { rd = rd, rs = rs, immediate = offset5 })
end

-- Format 2: add/subtract register or 3-bit immediate.
local function decodeFormat2(address, raw, hw1)
  local isImmediate = bits(hw1, 10, 10) == 1
  local isSub = bits(hw1, 9, 9) == 1
  local operand = bits(hw1, 8, 6)
  local rs = bits(hw1, 5, 3)
  local rd = bits(hw1, 2, 0)
  local operands = { rd = rd, rs = rs }
  if isImmediate then
    operands.immediate = operand
  else
    operands.rn = operand
  end
  return sequential(address, 2, raw, isSub and "sub" or "add", operands)
end

-- Format 3: move/compare/add/subtract immediate.
local function decodeFormat3(address, raw, hw1)
  local op = bits(hw1, 12, 11)
  local rd = bits(hw1, 10, 8)
  local imm8 = bits(hw1, 7, 0)
  local mnemonic = ({ [0] = "mov", "cmp", "add", "sub" })[op]
  return sequential(address, 2, raw, mnemonic, { rd = rd, immediate = imm8 })
end

-- Format 4: ALU operations.
local function decodeFormat4(address, raw, hw1)
  local op = bits(hw1, 9, 6)
  local rs = bits(hw1, 5, 3)
  local rd = bits(hw1, 2, 0)
  return sequential(address, 2, raw, ALU_MNEMONICS[op], { rd = rd, rs = rs })
end

-- Format 5: hi-register operations/branch exchange.
local function decodeFormat5(address, raw, hw1)
  local op = bits(hw1, 9, 8)
  local h1 = bits(hw1, 7, 7)
  local h2 = bits(hw1, 6, 6)
  local rs = bits(hw1, 5, 3) + (h2 == 1 and 8 or 0)
  local rd = bits(hw1, 2, 0) + (h1 == 1 and 8 or 0)
  if op == 3 then
    local mnemonic = h1 == 1 and "blx" or "bx"
    return {
      address = address,
      size = 2,
      raw = raw,
      mnemonic = mnemonic,
      operands = { rs = rs },
      flow = { kind = h1 == 1 and "call" or "indirect" },
    }
  end
  local mnemonic = ({ [0] = "add", "cmp", "mov" })[op]
  local writesPc = rd == 15
  return {
    address = address,
    size = 2,
    raw = raw,
    mnemonic = mnemonic,
    operands = { rd = rd, rs = rs },
    flow = { kind = writesPc and "indirect" or "sequential" },
  }
end

-- Format 6: PC-relative literal load.
local function decodeFormat6(address, raw, hw1)
  local rd = bits(hw1, 10, 8)
  local word8 = bits(hw1, 7, 0)
  local literalAddress = wordAlignedPc(address) + word8 * 4
  return sequential(address, 2, raw, "ldr", { rd = rd, literalAddress = literalAddress })
end

-- Format 7: load/store with register offset.
local function decodeFormat7(address, raw, hw1)
  local l = bits(hw1, 11, 11)
  local b = bits(hw1, 10, 10)
  local ro = bits(hw1, 8, 6)
  local rb = bits(hw1, 5, 3)
  local rd = bits(hw1, 2, 0)
  local mnemonic
  if l == 0 and b == 0 then
    mnemonic = "str"
  elseif l == 1 and b == 0 then
    mnemonic = "ldr"
  elseif l == 0 and b == 1 then
    mnemonic = "strb"
  else
    mnemonic = "ldrb"
  end
  return sequential(address, 2, raw, mnemonic, { rd = rd, rb = rb, ro = ro })
end

-- Format 8: sign-extended byte/halfword load-store with register offset.
local function decodeFormat8(address, raw, hw1)
  local h = bits(hw1, 11, 11)
  local s = bits(hw1, 10, 10)
  local ro = bits(hw1, 8, 6)
  local rb = bits(hw1, 5, 3)
  local rd = bits(hw1, 2, 0)
  local mnemonic
  if s == 0 and h == 0 then
    mnemonic = "strh"
  elseif s == 0 and h == 1 then
    mnemonic = "ldrh"
  elseif s == 1 and h == 0 then
    mnemonic = "ldsb"
  else
    mnemonic = "ldsh"
  end
  return sequential(address, 2, raw, mnemonic, { rd = rd, rb = rb, ro = ro })
end

-- Format 9: load/store with immediate offset.
local function decodeFormat9(address, raw, hw1)
  local b = bits(hw1, 12, 12)
  local l = bits(hw1, 11, 11)
  local offset5 = bits(hw1, 10, 6)
  local rb = bits(hw1, 5, 3)
  local rd = bits(hw1, 2, 0)
  local mnemonic
  if l == 0 and b == 0 then
    mnemonic = "str"
  elseif l == 1 and b == 0 then
    mnemonic = "ldr"
  elseif l == 0 and b == 1 then
    mnemonic = "strb"
  else
    mnemonic = "ldrb"
  end
  local scale = b == 1 and 1 or 4
  return sequential(address, 2, raw, mnemonic, { rd = rd, rb = rb, immediate = offset5 * scale })
end

-- Format 10: load/store halfword.
local function decodeFormat10(address, raw, hw1)
  local l = bits(hw1, 11, 11)
  local offset5 = bits(hw1, 10, 6)
  local rb = bits(hw1, 5, 3)
  local rd = bits(hw1, 2, 0)
  return sequential(address, 2, raw, l == 1 and "ldrh" or "strh", { rd = rd, rb = rb, immediate = offset5 * 2 })
end

-- Format 11: SP-relative load/store.
local function decodeFormat11(address, raw, hw1)
  local l = bits(hw1, 11, 11)
  local rd = bits(hw1, 10, 8)
  local word8 = bits(hw1, 7, 0)
  return sequential(address, 2, raw, l == 1 and "ldr" or "str", { rd = rd, base = "sp", immediate = word8 * 4 })
end

-- Format 12: load address (ADR or ADD Rd, SP, #imm).
local function decodeFormat12(address, raw, hw1)
  local sp = bits(hw1, 11, 11)
  local rd = bits(hw1, 10, 8)
  local word8 = bits(hw1, 7, 0)
  if sp == 0 then
    return sequential(address, 2, raw, "adr", { rd = rd, address = wordAlignedPc(address) + word8 * 4 })
  end
  return sequential(address, 2, raw, "add", { rd = rd, base = "sp", immediate = word8 * 4 })
end

-- Format 13: adjust stack pointer.
local function decodeFormat13(address, raw, hw1)
  local s = bits(hw1, 7, 7)
  local sword7 = bits(hw1, 6, 0)
  return sequential(address, 2, raw, s == 1 and "sub" or "add", { base = "sp", immediate = sword7 * 4 })
end

-- Format 14: push/pop register list.
local function decodeFormat14(address, raw, hw1)
  local l = bits(hw1, 11, 11)
  local r = bits(hw1, 8, 8)
  local rlist = bits(hw1, 7, 0)
  local mnemonic = l == 1 and "pop" or "push"
  local isReturn = l == 1 and r == 1
  return {
    address = address,
    size = 2,
    raw = raw,
    mnemonic = mnemonic,
    operands = { registerList = rlist, includesPcOrLr = r == 1 },
    flow = { kind = isReturn and "return" or "sequential" },
  }
end

-- Format 15: load/store multiple.
local function decodeFormat15(address, raw, hw1)
  local l = bits(hw1, 11, 11)
  local rb = bits(hw1, 10, 8)
  local rlist = bits(hw1, 7, 0)
  local mnemonic = l == 1 and "ldmia" or "stmia"
  return {
    address = address,
    size = 2,
    raw = raw,
    mnemonic = mnemonic,
    operands = { rb = rb, registerList = rlist },
    flow = { kind = "sequential" },
  }
end

-- Format 16/17: conditional branch or software interrupt.
local function decodeFormat16(address, raw, hw1)
  local cond = bits(hw1, 11, 8)
  local offset8 = bits(hw1, 7, 0)
  if cond == 15 then
    return sequential(address, 2, raw, "swi", { immediate = offset8 })
  end
  if cond == 14 then
    return unknownInstruction(address, 2, raw)
  end
  local target = (address + 4) + signExtend(offset8, 8) * 2
  return {
    address = address,
    size = 2,
    raw = raw,
    mnemonic = "b",
    operands = {},
    flow = { kind = "branch", conditional = true, condition = COND_NAMES[cond], target = target },
  }
end

-- Format 18: unconditional branch.
local function decodeFormat18(address, raw, hw1)
  local offset11 = bits(hw1, 10, 0)
  local target = (address + 4) + signExtend(offset11, 11) * 2
  return {
    address = address,
    size = 2,
    raw = raw,
    mnemonic = "b",
    operands = {},
    flow = { kind = "branch", conditional = false, target = target },
  }
end

local function isLongBranchPrefix(hw)
  return bits(hw, 15, 11) == 0x1E
end

local function isLongBranchSuffix(hw)
  local top5 = bits(hw, 15, 11)
  return top5 == 0x1F or top5 == 0x1D
end

-- Format 19: long BL/BLX immediate pair.
local function decodeFormat19(address, hw1, hw2)
  local highOffset = signExtend(bits(hw1, 10, 0), 11)
  local lowOffset = bits(hw2, 10, 0)
  local offset = highOffset * 4096 + lowOffset * 2
  local target = (address + 4) + offset
  local isBlx = bits(hw2, 15, 11) == 0x1D
  if isBlx then
    target = target - (target % 4)
  end
  return {
    address = address,
    size = 4,
    raw = { hw1, hw2 },
    mnemonic = isBlx and "blx" or "bl",
    operands = {},
    flow = { kind = "call", target = target, targetState = isBlx and "arm" or "thumb" },
  }
end

local function classify(hw1)
  local top3 = bits(hw1, 15, 13)
  if top3 == 0 then
    if bits(hw1, 12, 11) == 3 then
      return decodeFormat2
    end
    return decodeFormat1
  end
  if top3 == 1 then
    return decodeFormat3
  end
  if top3 == 2 then
    local top6 = bits(hw1, 15, 10)
    if top6 == 0x10 then
      return decodeFormat4
    end
    if top6 == 0x11 then
      return decodeFormat5
    end
    if bits(hw1, 15, 11) == 0x09 then
      return decodeFormat6
    end
    local top4 = bits(hw1, 15, 12)
    if top4 == 0x5 then
      if bits(hw1, 9, 9) == 0 then
        return decodeFormat7
      end
      return decodeFormat8
    end
    return nil
  end
  if top3 == 3 then
    return decodeFormat9
  end
  local top4 = bits(hw1, 15, 12)
  if top4 == 0x8 then
    return decodeFormat10
  end
  if top4 == 0x9 then
    return decodeFormat11
  end
  if top4 == 0xA then
    return decodeFormat12
  end
  if top4 == 0xB then
    if bits(hw1, 10, 9) == 2 then
      return decodeFormat14
    end
    if bits(hw1, 11, 8) == 0 then
      return decodeFormat13
    end
    return nil
  end
  if top4 == 0xC then
    return decodeFormat15
  end
  if top4 == 0xD then
    return decodeFormat16
  end
  if bits(hw1, 15, 11) == 0x1C then
    return decodeFormat18
  end
  return nil
end

local function _decode(bytes, offset, ramAddress)
  local reader = BinaryReader.new(bytes, "thumb")
  local hw1 = reader:u16le(offset)
  local raw1 = { hw1 }
  local address = ramAddress

  if isLongBranchPrefix(hw1) then
    local ok, hw2 = pcall(function()
      return reader:u16le(offset + 2)
    end)
    if ok and isLongBranchSuffix(hw2) then
      return decodeFormat19(address, hw1, hw2)
    end
    return unknownInstruction(address, 2, raw1)
  end

  if isLongBranchSuffix(hw1) then
    return unknownInstruction(address, 2, raw1)
  end

  local decoder = classify(hw1)
  if not decoder then
    return unknownInstruction(address, 2, raw1)
  end
  return decoder(address, raw1, hw1)
end

---@param bytes string
---@param offset integer zero-based byte offset into bytes
---@param ramAddress integer RAM address of the instruction at offset
---@return ThumbDecoder.Instruction?
---@return Errors.Error?
function ThumbDecoder.decode(bytes, offset, ramAddress)
  local ok, result = pcall(_decode, bytes, offset, ramAddress)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return ThumbDecoder
