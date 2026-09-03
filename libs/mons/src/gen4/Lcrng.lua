-- Generation-IV linear-congruential generator. Canonical source:
-- pret/pokeheartgold, src/math_util.c (LCRandom). The state is an unsigned
-- 32-bit value; each draw advances state = state * 1103515245 + 24691
-- (mod 2^32) and returns the upper 16 bits. Multiplication goes through the
-- exact U32 helper because Lua numbers cannot represent every intermediate
-- product. This stream is independent of the script RNG and of the local
-- cipher state the boxed codec uses.

local U32 = require("libs.codec.src.U32")
local MonsErrors = require("libs.mons.src.errors")

---@class Gen4Lcrng
---@field private _state integer
---@field private _calls integer
local Lcrng = {}
Lcrng.__index = Lcrng

Lcrng.MULTIPLIER = 1103515245
Lcrng.INCREMENT = 24691

---@param state integer
---@param calls integer
---@return Gen4Lcrng
local function build(state, calls)
  return setmetatable({ _state = state, _calls = calls }, Lcrng)
end

---@param seedU32 integer
---@return Gen4Lcrng
function Lcrng.new(seedU32)
  assert(
    type(seedU32) == "number" and seedU32 % 1 == 0 and seedU32 >= 0 and seedU32 <= U32.MAX,
    "Lcrng seed must be an unsigned 32-bit integer"
  )
  return build(seedU32, 0)
end

---@param record table
---@return Gen4Lcrng
function Lcrng.restore(record)
  Lcrng.validate(record)
  return build(record.state, record.calls)
end

---@param record table
---@return boolean
function Lcrng.validate(record)
  if type(record) ~= "table" then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "generator record must be a table", {})
  end
  local state = record.state
  local calls = record.calls
  if
    type(state) ~= "number"
    or state % 1 ~= 0
    or state < 0
    or state > U32.MAX
    or type(calls) ~= "number"
    or calls % 1 ~= 0
    or calls < 0
  then
    MonsErrors.raise(
      MonsErrors.SAVE_INVALID,
      "generator record must carry a u32 state and a non-negative call count",
      {}
    )
  end
  return true
end

---@return integer
function Lcrng:nextU16()
  self._state = U32.add(U32.mul(self._state, Lcrng.MULTIPLIER), Lcrng.INCREMENT)
  self._calls = self._calls + 1
  return math.floor(self._state / 65536)
end

-- Creation order: the first draw occupies the low 16 bits, the second the
-- high 16 bits.
---@return integer
function Lcrng:nextU32FromTwoDraws()
  local low = self:nextU16()
  local high = self:nextU16()
  return low + high * 65536
end

---@return { state: integer, calls: integer }
function Lcrng:capture()
  return { state = self._state, calls = self._calls }
end

return Lcrng
