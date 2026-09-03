-- Focused exact-arithmetic tests: the 32-bit helpers must stay exact where
-- naive floating-point multiplication loses integer precision.

local Assert = require("tests.support.Assert")
local U32 = require("libs.codec.src.U32")

local T = {}

function T.arithmetic_stays_within_unsigned_32_bits()
  Assert.equal(U32.add(0xFFFFFFFF, 1), 0)
  Assert.equal(U32.add(0xFFFFFFFF, 0xFFFFFFFF), 0xFFFFFFFE)
  Assert.equal(U32.mul(0xFFFFFFFF, 0xFFFFFFFF), 1)
  Assert.equal(U32.mul(0x80000000, 2), 0)
  Assert.equal(U32.mul(1103515245, 0xFFFFFFFF), 0xBE39B193)
  -- Products that overflow double precision stay exact through the halves.
  Assert.equal(U32.mul(0x12345678, 0x87654321), 0x70B88D78)
  Assert.throws(function()
    U32.mul(0x100000000, 1)
  end)
  Assert.throws(function()
    U32.add(-1, 0)
  end)
end

return { tests = T }
