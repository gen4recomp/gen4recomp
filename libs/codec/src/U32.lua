-- Exact unsigned 32-bit arithmetic on Lua numbers. LuaJIT doubles cannot
-- represent every product of two 32-bit values, so multiplication splits both
-- operands into 16-bit halves and reassembles the low 32 bits exactly. Only
-- addition and multiplication exist here; generation-specific transitions
-- belong to their own owners. Pure domain module.

---@class U32
local U32 = {}

U32.MOD = 4294967296
U32.MAX = 4294967295

local HALF_BASE = 65536

---@param value integer
---@param name string
local function requireU32(value, name)
  assert(
    type(value) == "number" and value % 1 == 0 and value >= 0 and value <= U32.MAX,
    name .. " must be an unsigned 32-bit integer"
  )
end

---@param a integer
---@param b integer
---@return integer
function U32.add(a, b)
  requireU32(a, "addend")
  requireU32(b, "addend")
  return (a + b) % U32.MOD
end

---@param a integer
---@param b integer
---@return integer
function U32.mul(a, b)
  requireU32(a, "factor")
  requireU32(b, "factor")
  local aLo = a % HALF_BASE
  local aHi = math.floor(a / HALF_BASE)
  local bLo = b % HALF_BASE
  local bHi = math.floor(b / HALF_BASE)
  local lo = aLo * bLo
  local mid = aLo * bHi + aHi * bLo
  return (lo + (mid % HALF_BASE) * HALF_BASE) % U32.MOD
end

return U32
