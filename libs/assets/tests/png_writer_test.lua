-- PngWriter: signature/chunk framing, determinism, length validation, and a
-- LÖVE image decode round-trip proving the pixels survive.

local Assert = require("tests.support.Assert")
local ffi = require("ffi")
local PngWriter = require("libs.assets.src.PngWriter")
local Errors = require("libs.errors.src.Errors")

local T = {}

local function px(r, g, b, a)
  return string.char(r, g, b, a)
end

local function rgba(width, height)
  local rows = {}
  for y = 0, height - 1 do
    local row = {}
    for x = 0, width - 1 do
      row[#row + 1] = px((x + y) % 256, (x * 3 + y) % 256, (x + y * 5) % 256, (x * 7 + y) % 256)
    end
    rows[#rows + 1] = table.concat(row)
  end
  return table.concat(rows)
end

local function directEncode(width, height, pixels)
  local output = love.data.newByteData(PngWriter.encodedSize(width, height))
  local outputSize = output:getSize()
  ---@cast outputSize integer
  PngWriter.encodeInto(width, height, ffi.cast("const uint8_t *", pixels), #pixels, output:getFFIPointer(), outputSize)
  return ffi.string(output:getFFIPointer(), outputSize)
end

function T.starts_with_signature_and_has_ihdr_idat_iend()
  local png = PngWriter.encode(1, 1, px(10, 20, 30, 255))
  Assert.equal(png:sub(1, 8), string.char(137, 80, 78, 71, 13, 10, 26, 10))
  Assert.equal(png:sub(13, 16), "IHDR")
  Assert.isTrue(png:find("IDAT", 1, true) ~= nil, "has IDAT")
  Assert.equal(png:sub(#png - 7, #png - 4), "IEND") -- type precedes its 4-byte CRC
end

function T.is_deterministic()
  local pixels = px(1, 2, 3, 4) .. px(5, 6, 7, 8)
  Assert.equal(PngWriter.encode(2, 1, pixels), PngWriter.encode(2, 1, pixels))
end

function T.rejects_wrong_length()
  local ok, err = pcall(PngWriter.encode, 2, 2, "short")
  Assert.isTrue(not ok, "raises")
  if not Errors.is(err) then
    error("raises")
  end
  if type(err) ~= "table" then
    error("raises")
  end
  Assert.equal(tostring(rawget(err, "code")), "PNG_BAD_RGBA_LENGTH")
end

function T.decodes_back_to_the_same_pixels()
  local pixels = px(10, 20, 30, 255) .. px(200, 150, 100, 128)
  local png = PngWriter.encode(2, 1, pixels)
  local data = love.image.newImageData(love.filesystem.newFileData(png, "t.png"))
  Assert.equal(data:getWidth(), 2)
  local r, g, _, a = data:getPixel(0, 0)
  Assert.equal(math.floor(r * 255 + 0.5), 10)
  Assert.equal(math.floor(g * 255 + 0.5), 20)
  Assert.equal(math.floor(a * 255 + 0.5), 255)
  local r2 = data:getPixel(1, 0)
  Assert.equal(math.floor(r2 * 255 + 0.5), 200)
end

function T.direct_stream_matches_reference_across_stored_block_boundaries()
  Assert.isTrue(
    type(PngWriter.encodedSize) == "function" and type(PngWriter.encodeInto) == "function",
    "the direct PNG encode API is required"
  )

  local cases = {
    { width = 2, height = 1 },
    -- The 65535-byte stored-block boundary lands in the middle of a row.
    { width = 257, height = 65 },
  }
  for _, case in ipairs(cases) do
    local pixels = rgba(case.width, case.height)
    local reference = PngWriter.encode(case.width, case.height, pixels)
    local direct = directEncode(case.width, case.height, pixels)
    Assert.equal(#direct, PngWriter.encodedSize(case.width, case.height), "exact output size")
    Assert.equal(direct, reference, "byte-identical PNG")

    local image = love.image.newImageData(love.filesystem.newFileData(direct, "direct.png"))
    Assert.equal(image:getWidth(), case.width, "decoded width")
    Assert.equal(image:getHeight(), case.height, "decoded height")
  end
end

function T.encoded_size_matches_stored_stream_formula()
  local function expected(width, height)
    local raw = height * (1 + width * 4)
    local blocks = math.ceil(raw / 65535)
    return 57 + 2 + raw + blocks * 5 + 4
  end
  for _, case in ipairs({ { 1, 1 }, { 1, 16383 }, { 257, 65 } }) do
    Assert.equal(PngWriter.encodedSize(case[1], case[2]), expected(case[1], case[2]))
  end
end

return { tests = T }
