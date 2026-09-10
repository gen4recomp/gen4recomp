-- Immutable, bounded byte views backed by a rooted string or Data object.

local ffi = require("ffi")
local Errors = require("libs.errors.src.Errors")

local BinaryView = {}
BinaryView.__index = BinaryView

local function finiteInteger(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value == math.floor(value)
end

---@param owner string|BinaryDataLike|userdata
---@param pointer string|ffi.cdata*
---@param length integer
---@param label string?
---@return BinaryView
local function pointerView(owner, pointer, length, label)
  assert(owner ~= nil, "binary view requires a backing owner")
  assert(finiteInteger(length) and length >= 0, "binary view length must be a non-negative integer")
  local view = setmetatable({
    _owner = owner,
    _ptr = ffi.cast("const uint8_t *", pointer),
    _length = length,
    _label = label or "binary",
  }, BinaryView) ---@type BinaryView
  return view
end

---@class BinaryDataLike
---@field getFFIPointer fun(self: BinaryDataLike): ffi.cdata*
---@field getSize fun(self: BinaryDataLike): number

---@class BinaryView
---@field private _owner string|BinaryDataLike
---@field private _ptr ffi.cdata*
---@field private _length integer
---@field private _label string
---@field assertRange fun(self: BinaryView, offset: integer, length: integer, fieldName: string): boolean
---@field length fun(self: BinaryView): integer
---@field slice fun(self: BinaryView, offset: integer, length: integer, label: string?): BinaryView
---@field u8 fun(self: BinaryView, offset: integer): integer
---@field u16le fun(self: BinaryView, offset: integer): integer
---@field u32le fun(self: BinaryView, offset: integer): integer
---@field i8 fun(self: BinaryView, offset: integer): integer
---@field i16le fun(self: BinaryView, offset: integer): integer
---@field i32le fun(self: BinaryView, offset: integer): integer
---@field ascii fun(self: BinaryView, offset: integer, length: integer, trimNul: boolean?): string
---@field toString fun(self: BinaryView, offset: integer?, length: integer?): string

---@param bytes string
---@param label string?
---@return BinaryView
function BinaryView.fromString(bytes, label)
  assert(type(bytes) == "string", "BinaryView.fromString requires a string")
  return pointerView(bytes, bytes, #bytes, label)
end

---@param data BinaryDataLike|userdata
---@param label string?
---@return BinaryView
function BinaryView.fromData(data, label)
  assert(type(data) == "table" or type(data) == "userdata", "BinaryView.fromData requires a Data object")
  assert(type(data.getFFIPointer) == "function", "BinaryView.fromData requires getFFIPointer")
  assert(type(data.getSize) == "function", "BinaryView.fromData requires getSize")
  ---@cast data BinaryDataLike
  local size = data:getSize()
  assert(finiteInteger(size) and size >= 0, "Data size must be a non-negative integer")
  ---@cast size integer
  local pointer = data:getFFIPointer()
  assert(pointer ~= nil, "Data returned a nil FFI pointer")
  return pointerView(data, pointer, size, label)
end

---@param offset integer
---@param length integer
---@param fieldName string
---@return boolean
function BinaryView:assertRange(offset, length, fieldName)
  local field = fieldName or "read"
  if not finiteInteger(offset) or not finiteInteger(length) then
    Errors.raise(
      "READ_OUT_OF_BOUNDS",
      string.format(
        "%s: offset and length must be finite integers, got %s and %s",
        field,
        tostring(offset),
        tostring(length)
      ),
      { offset = offset, length = length, available = self._length, field = fieldName }
    )
  end
  if offset < 0 or length < 0 or offset + length > self._length then
    Errors.raise(
      "READ_OUT_OF_BOUNDS",
      string.format(
        "%s: read of %s bytes at offset %s exceeds %d-byte %s",
        field,
        tostring(length),
        tostring(offset),
        self._length,
        self._label
      ),
      { offset = offset, length = length, available = self._length, field = fieldName }
    )
  end
  return true
end

function BinaryView:length()
  return self._length
end

---@param offset integer
---@param length integer
---@param label string?
---@return BinaryView
function BinaryView:slice(offset, length, label)
  self:assertRange(offset, length, "slice")
  local view = setmetatable({
    _owner = self._owner,
    _ptr = self._ptr + offset,
    _length = length,
    _label = label or self._label,
  }, BinaryView) ---@type BinaryView
  return view
end

function BinaryView:u8(offset)
  self:assertRange(offset, 1, "u8")
  local p = self._ptr + offset
  return tonumber(p[0])
end

function BinaryView:u16le(offset)
  self:assertRange(offset, 2, "u16le")
  local p = self._ptr + offset
  return tonumber(p[0]) + tonumber(p[1]) * 0x100
end

function BinaryView:u32le(offset)
  self:assertRange(offset, 4, "u32le")
  local p = self._ptr + offset
  return tonumber(p[0]) + tonumber(p[1]) * 0x100 + tonumber(p[2]) * 0x10000 + tonumber(p[3]) * 0x1000000
end

function BinaryView:i8(offset)
  local value = self:u8(offset)
  return value >= 0x80 and value - 0x100 or value
end

function BinaryView:i16le(offset)
  local value = self:u16le(offset)
  return value >= 0x8000 and value - 0x10000 or value
end

function BinaryView:i32le(offset)
  local value = self:u32le(offset)
  return value >= 0x80000000 and value - 0x100000000 or value
end

---@param offset integer?
---@param length integer?
---@return string
function BinaryView:toString(offset, length)
  if offset == nil then
    offset = 0
  end
  self:assertRange(offset, 0, "toString")
  if length == nil then
    length = self._length - offset
  end
  self:assertRange(offset, length, "toString")
  if length == 0 then
    return ""
  end
  return ffi.string(self._ptr + offset, length)
end

function BinaryView:ascii(offset, length, trimNul)
  self:assertRange(offset, length, "ascii")
  if not trimNul then
    return self:toString(offset, length)
  end
  local p = self._ptr + offset
  local contentLength = length
  for i = 0, length - 1 do
    if p[i] == 0 then
      contentLength = i
      break
    end
  end
  if contentLength == 0 then
    return ""
  end
  return ffi.string(p, contentLength)
end

return BinaryView
