-- Exact-pixel tests for every implemented Nitro texture format, plus the
-- color-zero and unsupported/none-format error paths.

local Assert = require("tests.support.Assert")
local ffi = require("ffi")
local TextureDecoder = require("libs.nds.src.gx.TextureDecoder")
local TF = require("tests.support.TextureFixtures")

local T = {}

local RED = { 255, 0, 0, 255 }
local GREEN = { 0, 255, 0, 255 }
local BLUE = { 0, 0, 255, 255 }

local function px(result, x, y)
  return { TF.pixel(result.pixels, result.width, x, y) }
end

function T.format2_four_color_row()
  local r = TextureDecoder.decode({
    format = 2,
    width = 4,
    height = 1,
    palette = TF.primaryPalette(),
    texel = TF.pack2({ 0, 1, 2, 3 }),
  })
  Assert.deepEqual(px(r, 0, 0), { 0, 0, 0, 255 })
  Assert.deepEqual(px(r, 1, 0), RED)
  Assert.deepEqual(px(r, 2, 0), GREEN)
  Assert.deepEqual(px(r, 3, 0), BLUE)
end

function T.format2_color0_transparent()
  local r = TextureDecoder.decode({
    format = 2,
    width = 4,
    height = 1,
    palette = TF.primaryPalette(),
    color0Transparent = true,
    texel = TF.pack2({ 0, 1, 2, 3 }),
  })
  Assert.deepEqual(px(r, 0, 0), { 0, 0, 0, 0 })
  Assert.deepEqual(px(r, 1, 0), RED)
end

function T.format3_sixteen_color()
  local r = TextureDecoder.decode({
    format = 3,
    width = 4,
    height = 1,
    palette = TF.primaryPalette(),
    texel = TF.pack4({ 0, 1, 2, 3 }),
  })
  Assert.deepEqual(px(r, 1, 0), RED)
  Assert.deepEqual(px(r, 3, 0), BLUE)
end

function T.format4_256_color()
  local r = TextureDecoder.decode({
    format = 4,
    width = 4,
    height = 1,
    palette = TF.primaryPalette(),
    texel = string.char(0, 1, 2, 3),
  })
  Assert.deepEqual(px(r, 2, 0), GREEN)
end

function T.format7_direct_alpha_bit()
  local r = TextureDecoder.decode({
    format = 7,
    width = 2,
    height = 1,
    texel = TF.u16(0x8000 + TF.RED) .. TF.u16(TF.GREEN),
  })
  Assert.deepEqual(px(r, 0, 0), { 255, 0, 0, 255 }) -- alpha bit set
  Assert.deepEqual(px(r, 1, 0), { 0, 255, 0, 0 }) -- alpha bit clear, rgb preserved
end

function T.format1_a3i5()
  local r = TextureDecoder.decode({
    format = 1,
    width = 2,
    height = 1,
    palette = TF.primaryPalette(),
    texel = string.char(1 + 7 * 32, 2 + 0 * 32), -- idx1 a=7, idx2 a=0
  })
  Assert.deepEqual(px(r, 0, 0), { 255, 0, 0, 255 })
  Assert.deepEqual(px(r, 1, 0), { 0, 255, 0, 0 })
end

function T.format6_a5i3()
  local r = TextureDecoder.decode({
    format = 6,
    width = 2,
    height = 1,
    palette = TF.primaryPalette(),
    texel = string.char(1 + 31 * 8, 2 + 0 * 8), -- idx1 a=31, idx2 a=0
  })
  Assert.deepEqual(px(r, 0, 0), { 255, 0, 0, 255 })
  Assert.deepEqual(px(r, 1, 0), { 0, 255, 0, 0 })
end

function T.format5_mode2_explicit()
  -- One 4x4 block, mode 2 (all four indices explicit), base 0.
  local texel = string.char(0xE4, 0, 0, 0) -- row0 = indices 0,1,2,3; rows 1-3 = 0
  local r = TextureDecoder.decode({
    format = 5,
    width = 4,
    height = 4,
    palette = TF.primaryPalette(),
    texel = texel,
    indexData = TF.u16(0x8000), -- mode 2, base units 0
  })
  Assert.deepEqual(px(r, 0, 0), { 0, 0, 0, 255 })
  Assert.deepEqual(px(r, 1, 0), RED)
  Assert.deepEqual(px(r, 2, 0), GREEN)
  Assert.deepEqual(px(r, 3, 0), BLUE)
  Assert.deepEqual(px(r, 0, 1), { 0, 0, 0, 255 }) -- row 1 all index 0
end

function T.format5_mode0_index3_transparent()
  local r = TextureDecoder.decode({
    format = 5,
    width = 4,
    height = 4,
    palette = TF.primaryPalette(),
    texel = string.char(0xE4, 0, 0, 0),
    indexData = TF.u16(0x0000), -- mode 0
  })
  Assert.deepEqual(px(r, 3, 0), { 0, 0, 0, 0 }) -- index 3 transparent in mode 0
  Assert.deepEqual(px(r, 2, 0), GREEN)
end

function T.format5_mode1_mean()
  -- base 0: index0 black(0,0,0), index1 blue(0,0,255). index2 = mean -> (0,0,128).
  local r = TextureDecoder.decode({
    format = 5,
    width = 4,
    height = 4,
    palette = TF.palette({ TF.BLACK, TF.BLUE }),
    texel = string.char(0xE4, 0, 0, 0),
    indexData = TF.u16(0x4000), -- mode 1
  })
  Assert.deepEqual(px(r, 2, 0), { 0, 0, 128, 255 })
  Assert.deepEqual(px(r, 3, 0), { 0, 0, 0, 0 })
end

function T.rejects_unsupported_and_none()
  local ok, err = pcall(TextureDecoder.decode, { format = 8, width = 1, height = 1 })
  Assert.isFalse(ok)
  Assert.equal(err.code, "NSBTX_UNSUPPORTED_FORMAT")
  local ok0, err0 = pcall(TextureDecoder.decode, { format = 0, width = 1, height = 1 })
  Assert.isFalse(ok0)
  Assert.equal(err0.code, "NSBTX_FORMAT_NONE")
end

function T.reports_alpha_usage()
  local r = TextureDecoder.decode({
    format = 2,
    width = 4,
    height = 1,
    palette = TF.primaryPalette(),
    color0Transparent = true,
    texel = TF.pack2({ 0, 1, 2, 3 }),
  })
  Assert.isTrue(r.alphaUsage.hasZero)
  Assert.isFalse(r.alphaUsage.hasPartial)
  Assert.isTrue(r.alphaUsage.hasOpaque)
end

function T.partial_alpha_usage_for_a5i3()
  local r = TextureDecoder.decode({
    format = 6,
    width = 2,
    height = 1,
    palette = TF.primaryPalette(),
    texel = string.char(1 + 15 * 8, 2 + 0 * 8), -- alpha 15 and 0
  })
  Assert.isTrue(r.alphaUsage.hasZero)
  Assert.isTrue(r.alphaUsage.hasPartial)
  Assert.isFalse(r.alphaUsage.hasOpaque)
end

function T.direct_decode_matches_the_reference_for_all_formats()
  Assert.isTrue(
    type(TextureDecoder.newScratch) == "function" and type(TextureDecoder.decodeInto) == "function",
    "the direct texture decode API is required"
  )

  local cases = {
    {
      name = "a3i5",
      format = 1,
      width = 2,
      height = 1,
      palette = TF.primaryPalette(),
      texel = string.char(1 + 7 * 32, 2 + 3 * 32),
    },
    {
      name = "four-color-transparent",
      format = 2,
      width = 4,
      height = 1,
      palette = TF.primaryPalette(),
      color0Transparent = true,
      texel = TF.pack2({ 0, 1, 2, 3 }),
    },
    {
      name = "sixteen-color",
      format = 3,
      width = 4,
      height = 1,
      palette = TF.primaryPalette(),
      texel = TF.pack4({ 0, 1, 2, 3 }),
    },
    {
      name = "256-color",
      format = 4,
      width = 4,
      height = 1,
      palette = TF.primaryPalette(),
      texel = string.char(0, 1, 2, 3),
    },
    {
      name = "compressed-interpolated",
      format = 5,
      width = 4,
      height = 4,
      palette = TF.palette({ TF.BLACK, TF.BLUE }),
      texel = string.char(0xE4, 0, 0, 0),
      indexData = TF.u16(0x4000),
    },
    {
      name = "a5i3",
      format = 6,
      width = 2,
      height = 1,
      palette = TF.primaryPalette(),
      texel = string.char(1 + 31 * 8, 2 + 15 * 8),
    },
    {
      name = "direct-color",
      format = 7,
      width = 2,
      height = 1,
      texel = TF.u16(0x8000 + TF.RED) .. TF.u16(TF.GREEN),
    },
  }

  local scratch = TextureDecoder.newScratch()
  for _, opts in ipairs(cases) do
    local reference = TextureDecoder.decode(opts, { name = opts.name })
    local output = love.data.newByteData(#reference.pixels)
    local alphaUsage =
      TextureDecoder.decodeInto(opts, output:getFFIPointer(), #reference.pixels, scratch, { name = opts.name })
    Assert.equal(ffi.string(output:getFFIPointer(), #reference.pixels), reference.pixels, opts.name .. " pixels")
    Assert.deepEqual(alphaUsage, reference.alphaUsage, opts.name .. " alpha usage")
  end
end

function T.compressed_modes_keep_block_local_palette_and_transparency_rules()
  local texel = string.char(0xE4, 0, 0, 0)
  local palette = TF.primaryPalette()
  for _, control in ipairs({ 0x0000, 0x4000, 0x8000, 0xC000 }) do
    local result = TextureDecoder.decode({
      format = 5,
      width = 4,
      height = 4,
      palette = palette,
      texel = texel,
      indexData = TF.u16(control),
    })
    local expectedAlpha = (control == 0x0000 or control == 0x4000) and 0 or 255
    Assert.equal(string.byte(result.pixels, 16), expectedAlpha)
    Assert.isTrue(result.alphaUsage.hasOpaque)
    if control == 0x0000 or control == 0x4000 then
      Assert.isTrue(result.alphaUsage.hasZero)
    end
  end
end

function T.compressed_palette_scratch_grows_and_reuses_high_water_capacity()
  local scratch = TextureDecoder.newScratch()
  local opts = {
    format = 5,
    width = 4,
    height = 4,
    palette = string.rep("\0\0", 404),
    texel = string.char(0, 0, 0, 0),
    indexData = TF.u16(0x8000 + 200),
  }
  local output = love.data.newByteData(64)
  TextureDecoder.decodeInto(opts, output:getFFIPointer(), 64, scratch)
  local capacity = scratch.paletteCapacity
  Assert.isTrue(capacity >= 404, "compressed base palette grows the scratch lane")
  local smallOutput = love.data.newByteData(4)
  TextureDecoder.decodeInto(
    { format = 2, width = 1, height = 1, palette = TF.primaryPalette(), texel = string.char(0) },
    smallOutput:getFFIPointer(),
    4,
    scratch
  )
  Assert.equal(scratch.paletteCapacity, capacity, "scratch retains high-water capacity")
end

function T.odd_packed_rows_do_not_emit_unused_texels()
  local result = TextureDecoder.decode({
    format = 2,
    width = 3,
    height = 1,
    palette = TF.primaryPalette(),
    texel = string.char(0xE4),
  })
  Assert.equal(#result.pixels, 12)
  Assert.deepEqual({ TF.pixel(result.pixels, 3, 2, 0) }, GREEN)
end

return { tests = T }
