-- Little-endian byte builder for generated binary assets (the G4M2 mesh format).
-- The mirror of BinaryReader: integers are assembled arithmetically and 32-bit
-- floats are encoded to IEEE-754 single precision by hand, since LuaJIT/5.1 has
-- no string.pack. Keeping the encoder pure (no love, no bit ops) makes generated
-- output deterministic across platforms. Integer encoders reject values outside
-- their representable unsigned width instead of wrapping. Pure domain module.

local Errors = require("libs.errors.src.Errors")
local Float32 = require("libs.codec.src.Float32")

---@class BinaryWriter
---@field _chunks string[]
---@field _len integer
local BinaryWriter = {}
BinaryWriter.__index = BinaryWriter

local function requireUnsigned(value, bits, name)
  local max = 2 ^ bits - 1
  if type(value) ~= "number" or value ~= math.floor(value) or value < 0 or value > max then
    Errors.raise(
      "WRITE_OUT_OF_RANGE",
      string.format("%s value must be an integer in 0..%d, got %s", name, max, tostring(value)),
      { value = value }
    )
  end
  return value
end

function BinaryWriter.new()
  return setmetatable({ _chunks = {}, _len = 0 }, BinaryWriter) ---@type BinaryWriter
end

---@param self BinaryWriter
---@param s string
---@return BinaryWriter
local function push(self, s)
  self._chunks[#self._chunks + 1] = s
  self._len = self._len + #s
  return self
end

function BinaryWriter:u8(v)
  return push(self, string.char(requireUnsigned(v, 8, "u8")))
end

function BinaryWriter:u16(v)
  requireUnsigned(v, 16, "u16")
  return push(self, string.char(v % 256, math.floor(v / 256)))
end

function BinaryWriter:u32(v)
  requireUnsigned(v, 32, "u32")
  return push(
    self,
    string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216))
  )
end

-- IEEE-754 binary32, little-endian. Handles zero, infinity, NaN, and normals;
-- subnormal inputs are rounded to the nearest representable value.
function BinaryWriter:f32(v)
  return self:u32(Float32.bits(v))
end

function BinaryWriter:bytes(s)
  return push(self, s)
end

function BinaryWriter:length()
  return self._len
end

function BinaryWriter:tostring()
  return table.concat(self._chunks)
end

return BinaryWriter
