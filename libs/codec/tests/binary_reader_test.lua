local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")
local BinaryView = require("libs.codec.src.BinaryView")

local T = {}

local function errorCode(fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured binary read error")
  return err.code
end

local function observations(data)
  local r = BinaryReader.new(data, "parity")
  return {
    length = r:length(),
    u8 = r:u8(0),
    u16le = r:u16le(1),
    u32le = r:u32le(0),
    f32le = r:f32le(4),
    bytes = r:bytes(9, 3),
    ascii = r:ascii(8, 4, false),
    trimmedAscii = r:ascii(8, 4, true),
    remaining = r:remaining(10),
    outOfBounds = errorCode(function()
      r:u32le(10)
    end),
  }
end

-- bytes: 0x01 0x02 0x03 0x04 0x05
local function reader()
  return BinaryReader.new("\1\2\3\4\5", "sample")
end

function T.length_reports_byte_count()
  Assert.equal(reader():length(), 5)
end

function T.u8_reads_first_and_last_offset()
  local r = reader()
  Assert.equal(r:u8(0), 1)
  Assert.equal(r:u8(4), 5)
end

function T.u16le_is_little_endian()
  -- 0x02,0x03 -> 0x0302
  Assert.equal(reader():u16le(1), 0x0302)
end

function T.u32le_is_little_endian()
  -- 0x01..0x04 -> 0x04030201
  Assert.equal(reader():u32le(0), 0x04030201)
end

function T.u32le_reads_high_values_without_sign_issues()
  local r = BinaryReader.new("\255\255\255\255")
  Assert.equal(r:u32le(0), 4294967295)
end

function T.bytes_returns_exact_slice_string()
  Assert.equal(reader():bytes(1, 3), "\2\3\4")
end

function T.ascii_trims_at_nul_when_requested()
  local r = BinaryReader.new("AB\0CD")
  Assert.equal(r:ascii(0, 5, true), "AB")
  Assert.equal(r:ascii(0, 5, false), "AB\0CD")
end

function T.slice_produces_independent_zero_based_reader()
  local s = reader():slice(2, 2, "child")
  Assert.equal(s:length(), 2)
  Assert.equal(s:u8(0), 3)
  Assert.equal(s:u8(1), 4)
end

function T.remaining_counts_bytes_from_offset()
  Assert.equal(reader():remaining(2), 3)
  Assert.equal(reader():remaining(5), 0)
end

local function assertRangeError(fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected an Errors object")
  Assert.equal(err.code, "READ_OUT_OF_BOUNDS")
end

function T.rejects_negative_offset()
  assertRangeError(function()
    reader():u8(-1)
  end)
end

function T.rejects_read_past_end()
  assertRangeError(function()
    reader():u8(5)
  end)
  assertRangeError(function()
    reader():u32le(2)
  end)
  assertRangeError(function()
    reader():bytes(3, 5)
  end)
end

function T.rejects_negative_length()
  assertRangeError(function()
    reader():bytes(0, -1)
  end)
end

function T.assertRange_passes_within_bounds()
  Assert.isTrue(reader():assertRange(0, 5, "probe"))
end

-- Binary positions must be finite integers: NaN offsets slip past every
-- comparison and in-range fractions reach the string primitives, so the
-- rejection must happen at this public boundary.
function T.rejects_nan_and_infinite_offsets()
  assertRangeError(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- test deliberately exercises an invalid call
    reader():u8(0 / 0)
  end)
  assertRangeError(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- test deliberately exercises an invalid call
    reader():u8(math.huge)
  end)
  assertRangeError(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- test deliberately exercises an invalid call
    reader():u8(-math.huge)
  end)
end

function T.rejects_fractional_offsets()
  assertRangeError(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- test deliberately exercises an invalid call
    reader():u8(1.5)
  end)
  assertRangeError(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- test deliberately exercises an invalid call
    reader():u32le(0.5)
  end)
  assertRangeError(function()
    reader():remaining(2.5)
  end)
end

function T.reader_preserves_binary_semantics_for_string_view_and_data_backing()
  local fixture = "\255\254\253\252\0\0\128\191A\0BC\0"
  local stringView = BinaryView.fromString(fixture, "string-view")
  local data = love.data.newByteData(fixture)

  Assert.deepEqual(observations(fixture), observations(stringView))
  Assert.deepEqual(observations(fixture), observations(data))
end

function T.rejects_invalid_view_ranges_with_structured_errors()
  local r = BinaryReader.new("\1\2\3", "truncated")
  local view = r:view(2, 1)

  Assert.equal(
    errorCode(function()
      view:u16le(0)
    end),
    "READ_OUT_OF_BOUNDS"
  )
  Assert.equal(
    errorCode(function()
      r:view(2, 2)
    end),
    "READ_OUT_OF_BOUNDS"
  )
end

function T.binary_view_accepts_empty_boundary_slices_only()
  local view = BinaryView.fromString("abc", "slice-boundaries")
  Assert.equal(view:slice(0, 0):length(), 0)
  Assert.equal(view:slice(3, 0):length(), 0)

  assertRangeError(function()
    view:slice(3, 1)
  end)
  assertRangeError(function()
    view:slice(-1, 0)
  end)
  assertRangeError(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- test deliberately exercises an invalid call
    view:slice(0, 1.5)
  end)
end

function T.copied_bytes_survive_data_release()
  local data = love.data.newByteData("AB\0CD")
  local bytes = BinaryReader.new(data, "copy"):bytes(0, 5)
  data:release()
  collectgarbage("collect")
  Assert.equal(bytes, "AB\0CD")
end

function T.rejects_nan_and_fractional_lengths()
  assertRangeError(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- test deliberately exercises an invalid call
    reader():bytes(0, 0 / 0)
  end)
  assertRangeError(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- test deliberately exercises an invalid call
    reader():bytes(0, 2.5)
  end)
  assertRangeError(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- test deliberately exercises an invalid call
    reader():ascii(1, math.huge)
  end)
  assertRangeError(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- test deliberately exercises an invalid call
    reader():slice(0, -0.5)
  end)
end

return { tests = T }
