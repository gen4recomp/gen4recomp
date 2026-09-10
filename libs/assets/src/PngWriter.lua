-- Deterministic truecolor-alpha PNG encoding with filter-zero, stored-DEFLATE
-- output. The pointer API writes one caller-owned buffer; the string API is a
-- compatibility/reference wrapper.

local bit = require("bit")
local ffi = require("ffi")
local Errors = require("libs.errors.src.Errors")

local PngWriter = {}

---@class PngWriter
---@field encode fun(width: integer, height: integer, rgba: string): string
---@field encodedSize fun(width: integer, height: integer): integer
---@field encodeInto fun(width: integer, height: integer, rgbaPtr: ffi.cdata*, rgbaLength: integer, outPtr: ffi.cdata*, outLength: integer)

local CRC_TABLE = ffi.new("uint32_t[256]")
for n = 0, 255 do
  local c = n
  for _ = 1, 8 do
    if bit.band(c, 1) == 1 then
      c = bit.bxor(0xEDB88320, bit.rshift(c, 1))
    else
      c = bit.rshift(c, 1)
    end
  end
  CRC_TABLE[n] = c
end

local SIGNATURE = { 137, 80, 78, 71, 13, 10, 26, 10 }
local IDAT_TYPE = { 73, 68, 65, 84 }
local IHDR_TYPE = { 73, 72, 68, 82 }
local IEND_TYPE = { 73, 69, 78, 68 }

local function validateDimensions(width, height)
  if type(width) ~= "number" or width ~= math.floor(width) or width <= 0 then
    Errors.raise("PNG_BAD_DIMENSIONS", "PNG width must be a positive integer", { width = width })
  end
  if type(height) ~= "number" or height ~= math.floor(height) or height <= 0 then
    Errors.raise("PNG_BAD_DIMENSIONS", "PNG height must be a positive integer", { height = height })
  end
end

local function lengths(width, height)
  validateDimensions(width, height)
  local rawLength = height * (1 + width * 4)
  local blockCount = math.ceil(rawLength / 65535)
  local zlibLength = 2 + rawLength + blockCount * 5 + 4
  return rawLength, blockCount, zlibLength, 57 + zlibLength
end

function PngWriter.encodedSize(width, height)
  local _, _, _, total = lengths(width, height)
  return total
end

local function writeByte(out, position, value)
  out[position] = value
  return position + 1
end

local function writeU32(out, position, value)
  ---@cast value integer
  local byte = bit.band(bit.rshift(value, 24), 0xFF)
  position = writeByte(out, position, byte)
  byte = bit.band(bit.rshift(value, 16), 0xFF)
  position = writeByte(out, position, byte)
  byte = bit.band(bit.rshift(value, 8), 0xFF)
  position = writeByte(out, position, byte)
  byte = bit.band(value, 0xFF)
  return writeByte(out, position, byte)
end

local function updateCrc(crc, value)
  ---@cast crc integer
  ---@cast value integer
  local index = bit.band(bit.bxor(crc, value), 0xFF)
  local updated = bit.bxor(bit.rshift(crc, 8), CRC_TABLE[index])
  return updated
end

local function writeType(out, position, typ)
  local crc = bit.bnot(0)
  for index = 1, 4 do
    local value = typ[index]
    position = writeByte(out, position, value)
    crc = updateCrc(crc, value)
  end
  return position, crc
end

local function writeChunkCrc(out, position, crc)
  return writeU32(out, position, bit.bnot(crc))
end

local function rawByte(rgba, width, emitted)
  local stride = width * 4
  local lineLength = stride + 1
  local row = math.floor(emitted / lineLength)
  local columnByte = emitted % lineLength
  if columnByte == 0 then
    return 0
  end
  return tonumber(rgba[row * stride + columnByte - 1])
end

local function updateAdler(a, b, value)
  a = (a + value) % 65521
  b = (b + a) % 65521
  return a, b
end

---@param width integer
---@param height integer
---@param rgbaPtr ffi.cdata*
---@param rgbaLength integer
---@param outPtr ffi.cdata*
---@param outLength integer
function PngWriter.encodeInto(width, height, rgbaPtr, rgbaLength, outPtr, outLength)
  local rawLength, blockCount, zlibLength, expectedLength = lengths(width, height)
  assert(rgbaPtr ~= nil, "PngWriter.encodeInto requires an RGBA pointer")
  assert(outPtr ~= nil, "PngWriter.encodeInto requires an output pointer")
  if rgbaLength ~= width * height * 4 then
    Errors.raise(
      "PNG_BAD_RGBA_LENGTH",
      string.format("rgba is %d bytes, expected %d (%dx%d*4)", rgbaLength, width * height * 4, width, height),
      { width = width, height = height, length = rgbaLength }
    )
  end
  assert(outLength == expectedLength, "PngWriter.encodeInto output size mismatch")

  local rgba = ffi.cast("const uint8_t *", rgbaPtr)
  local out = ffi.cast("uint8_t *", outPtr)
  local position = 0
  for index = 1, #SIGNATURE do
    position = writeByte(out, position, SIGNATURE[index])
  end

  position = writeU32(out, position, 13)
  local crc
  position, crc = writeType(out, position, IHDR_TYPE)
  local ihdrStart = position
  position = writeU32(out, position, width)
  position = writeU32(out, position, height)
  local ihdrValues = { 8, 6, 0, 0, 0 }
  for index = 1, #ihdrValues do
    position = writeByte(out, position, ihdrValues[index])
  end
  for index = ihdrStart, position - 1 do
    crc = updateCrc(crc, tonumber(out[index]))
  end
  position = writeChunkCrc(out, position, crc)

  position = writeU32(out, position, zlibLength)
  position, crc = writeType(out, position, IDAT_TYPE)
  position = writeByte(out, position, 0x78)
  crc = updateCrc(crc, 0x78)
  position = writeByte(out, position, 0x01)
  crc = updateCrc(crc, 0x01)

  local adlerA, adlerB = 1, 0
  local emitted = 0
  local blockRemaining = rawLength
  for block = 1, blockCount do
    local blockLength = math.min(blockRemaining, 65535)
    blockRemaining = blockRemaining - blockLength
    local final = block == blockCount and 1 or 0
    local inverse = 65535 - blockLength
    position = writeByte(out, position, final)
    crc = updateCrc(crc, final)
    local low = blockLength % 256
    local high = math.floor(blockLength / 256)
    position = writeByte(out, position, low)
    crc = updateCrc(crc, low)
    position = writeByte(out, position, high)
    crc = updateCrc(crc, high)
    low = inverse % 256
    high = math.floor(inverse / 256)
    position = writeByte(out, position, low)
    crc = updateCrc(crc, low)
    position = writeByte(out, position, high)
    crc = updateCrc(crc, high)
    for _ = 1, blockLength do
      local value = rawByte(rgba, width, emitted)
      emitted = emitted + 1
      position = writeByte(out, position, value)
      crc = updateCrc(crc, value)
      adlerA, adlerB = updateAdler(adlerA, adlerB, value)
    end
  end
  assert(emitted == rawLength and blockRemaining == 0)
  local adler = adlerB * 65536 + adlerA
  position = writeU32(out, position, adler)
  for index = position - 4, position - 1 do
    crc = updateCrc(crc, tonumber(out[index]))
  end
  position = writeChunkCrc(out, position, crc)

  position = writeU32(out, position, 0)
  position, crc = writeType(out, position, IEND_TYPE)
  position = writeChunkCrc(out, position, crc)
  assert(position == expectedLength, "PngWriter.encodeInto wrote an unexpected size")
end

-- rgba: width*height*4 bytes, row-major, top-left origin, straight alpha.
function PngWriter.encode(width, height, rgba)
  assert(type(rgba) == "string", "PngWriter.encode requires an RGBA string")
  local expectedLength = width * height * 4
  if #rgba ~= expectedLength then
    Errors.raise(
      "PNG_BAD_RGBA_LENGTH",
      string.format("rgba is %d bytes, expected %d (%dx%d*4)", #rgba, expectedLength, width, height),
      { width = width, height = height, length = #rgba }
    )
  end
  local output = ffi.new("uint8_t[?]", PngWriter.encodedSize(width, height))
  PngWriter.encodeInto(
    width,
    height,
    ffi.cast("const uint8_t *", rgba),
    #rgba,
    output,
    PngWriter.encodedSize(width, height)
  )
  return ffi.string(output, PngWriter.encodedSize(width, height))
end

return PngWriter
