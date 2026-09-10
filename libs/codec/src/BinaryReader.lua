-- Bounds-checked, zero-based reader over an immutable binary view. Pure domain module:
-- no love dependency. Little-endian integers are assembled arithmetically,
-- which is exact for 8/16/32-bit values under LuaJIT doubles. Binary
-- positions (offsets/lengths) must be finite integers.

local BinaryView = require("libs.codec.src.BinaryView")

---@class BinaryReader
---@field private _view BinaryView
---@field data string
---@field label string?
---@field length fun(self: BinaryReader): integer
---@field assertRange fun(self: BinaryReader, offset: integer, length: integer, fieldName: string): boolean
---@field u8 fun(self: BinaryReader, offset: integer): integer
---@field u16le fun(self: BinaryReader, offset: integer): integer
---@field u32le fun(self: BinaryReader, offset: integer): integer
---@field f32le fun(self: BinaryReader, offset: integer): number
---@field bytes fun(self: BinaryReader, offset: integer, length: integer): string
---@field ascii fun(self: BinaryReader, offset: integer, length: integer, trimNul: boolean?): string
---@field view fun(self: BinaryReader, offset: integer, length: integer, label: string?): BinaryView
---@field slice fun(self: BinaryReader, offset: integer, length: integer, label: string?): BinaryReader
local BinaryReader = {}
BinaryReader.__index = BinaryReader

function BinaryReader.new(data, label)
  local binaryView
  if type(data) == "string" then
    binaryView = BinaryView.fromString(data, label or "binary")
  elseif type(data) == "table" and getmetatable(data) == BinaryView then
    binaryView = data
  else
    binaryView = BinaryView.fromData(data, label or "binary")
  end
  return setmetatable({
    _view = binaryView,
    data = type(data) == "string" and data or nil,
    label = label or "binary",
  }, BinaryReader)
end

function BinaryReader:length()
  return self._view:length()
end

function BinaryReader:assertRange(offset, length, fieldName)
  return self._view:assertRange(offset, length, fieldName)
end

function BinaryReader:u8(offset)
  self:assertRange(offset, 1, "u8")
  return self._view:u8(offset)
end

function BinaryReader:u16le(offset)
  self:assertRange(offset, 2, "u16le")
  return self._view:u16le(offset)
end

function BinaryReader:u32le(offset)
  self:assertRange(offset, 4, "u32le")
  return self._view:u32le(offset)
end

-- IEEE-754 binary32, little-endian (mirror of BinaryWriter:f32).
function BinaryReader:f32le(offset)
  self:assertRange(offset, 4, "f32le")
  local word = self._view:u32le(offset)
  local sign = math.floor(word / 2147483648) % 2
  local biased = math.floor(word / 8388608) % 256
  local mantissa = word % 8388608
  local value = 0
  if biased == 0 then
    value = mantissa == 0 and 0 or (mantissa / 8388608) * 2 ^ -126
  elseif biased == 255 then
    value = mantissa == 0 and math.huge or (0 / 0)
  else
    value = (1 + mantissa / 8388608) * 2 ^ (biased - 127)
  end
  if sign == 1 then
    value = -value
  end
  return value
end

function BinaryReader:bytes(offset, length)
  self:assertRange(offset, length, "bytes")
  return self._view:toString(offset, length)
end

function BinaryReader:ascii(offset, length, trimNul)
  self:assertRange(offset, length, "ascii")
  return self._view:ascii(offset, length, trimNul)
end

function BinaryReader:view(offset, length, label)
  self:assertRange(offset, length, "view")
  return self._view:slice(offset, length, label or self.label)
end

function BinaryReader:slice(offset, length, label)
  return BinaryReader.new(self:bytes(offset, length), label or self.label)
end

function BinaryReader:remaining(offset)
  self:assertRange(offset, 0, "remaining")
  return self:length() - offset
end

return BinaryReader
