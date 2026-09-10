-- Decodes Nitro texture formats into row-major straight-alpha RGBA8 bytes.
-- Format rules follow GBATEK's "DS Video Texture Data" description.

local ffi = require("ffi")
local Errors = require("libs.errors.src.Errors")
local FixedPoint = require("libs.math.src.FixedPoint")

ffi.cdef([[typedef struct { uint8_t r, g, b, a; } G4Rgba8;]])

local TextureDecoder = {}
local PALETTE_INITIAL_CAPACITY = 256

---@class TextureDecoder.Scratch
---@field palette ffi.cdata*
---@field paletteCapacity integer

local function finiteInteger(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value == math.floor(value)
end

local function sourcePointer(source, label)
  if type(source) == "string" then
    return ffi.cast("const uint8_t *", source), #source, source
  end
  assert(type(source) == "table", label .. " must be a string or BinaryView")
  assert(type(source.pointer) == "function" and type(source.length) == "function", label .. " must be a BinaryView")
  -- Keep the view rooted while its pointer is consumed by the decoder.
  return source:pointer(), source:length(), source
end

local function validateDimensions(opts)
  if not finiteInteger(opts.width) or not finiteInteger(opts.height) or opts.width <= 0 or opts.height <= 0 then
    Errors.raise(
      "NSBTX_BAD_DIMENSIONS",
      "texture dimensions must be positive integers",
      { width = opts.width, height = opts.height }
    )
  end
end

local function badLength(code, label, actual, expected, context)
  Errors.raise(
    code,
    string.format("%s is %d bytes, expected %d", label, actual, expected),
    { actual = actual, expected = expected, source = context }
  )
end

local function requiredTexelLength(format, pixelCount)
  if format == 1 or format == 4 or format == 6 then
    return pixelCount
  elseif format == 2 then
    return math.floor((pixelCount + 3) / 4)
  elseif format == 3 then
    return math.floor((pixelCount + 1) / 2)
  elseif format == 7 then
    return pixelCount * 2
  end
  return nil
end

local function compressedInfo(opts, texelLength, indexLength)
  if opts.width % 4 ~= 0 or opts.height % 4 ~= 0 then
    Errors.raise(
      "NSBTX_BAD_DIMENSIONS",
      "compressed textures must have dimensions divisible by four",
      { width = opts.width, height = opts.height }
    )
  end
  local blockCount = (opts.width / 4) * (opts.height / 4)
  local expectedTexelLength = blockCount * 4
  local expectedIndexLength = blockCount * 2
  if texelLength ~= expectedTexelLength then
    badLength("NSBTX_BAD_TEXEL_LENGTH", "texel data", texelLength, expectedTexelLength)
  end
  if indexLength ~= expectedIndexLength then
    badLength("NSBTX_BAD_INDEX_LENGTH", "compressed index data", indexLength, expectedIndexLength)
  end
  return blockCount
end

local function ensurePaletteCapacity(scratch, required)
  assert(required >= 0 and finiteInteger(required), "palette capacity must be a non-negative integer")
  if required <= scratch.paletteCapacity then
    return
  end
  local capacity = scratch.paletteCapacity
  while capacity < required do
    capacity = capacity * 2
  end
  scratch.palette = ffi.new("G4Rgba8[?]", capacity)
  scratch.paletteCapacity = capacity
end

---@return TextureDecoder.Scratch
function TextureDecoder.newScratch()
  return {
    palette = ffi.new("G4Rgba8[?]", PALETTE_INITIAL_CAPACITY),
    paletteCapacity = PALETTE_INITIAL_CAPACITY,
  }
end

local function paletteColor(palette, index)
  local color = palette[index]
  return tonumber(color.r), tonumber(color.g), tonumber(color.b)
end

local function mixChannel(ca, cb, numA, numB, den)
  return math.floor((ca * numA + cb * numB) / den + 0.5)
end

local function blend(palette, a, b, numA, den)
  local ra, ga, ba = paletteColor(palette, a)
  local rb, gb, bb = paletteColor(palette, b)
  local numB = den - numA
  return mixChannel(ra, rb, numA, numB, den), mixChannel(ga, gb, numA, numB, den), mixChannel(ba, bb, numA, numB, den)
end

local function decodePalette(palettePtr, paletteLength, paletteCount, scratch, context)
  if paletteLength < paletteCount * 2 then
    badLength("NSBTX_BAD_PALETTE_LENGTH", "palette data", paletteLength, paletteCount * 2, context)
  end
  ensurePaletteCapacity(scratch, paletteCount)
  local palette = scratch.palette
  for index = 0, paletteCount - 1 do
    local offset = index * 2
    local value = tonumber(palettePtr[offset]) + tonumber(palettePtr[offset + 1]) * 256
    local r, g, b = FixedPoint.rgb555(value)
    local color = palette[index]
    color.r, color.g, color.b, color.a = r, g, b, 255
  end
  return palette
end

local function requiredPaletteCount(format, texel, texelLength, indexData, indexLength, pixelCount)
  local required = 0
  if format == 1 then
    for offset = 0, texelLength - 1 do
      required = math.max(required, tonumber(texel[offset]) % 32 + 1)
    end
  elseif format == 2 then
    for pixel = 0, pixelCount - 1 do
      local packed = tonumber(texel[math.floor(pixel / 4)])
      required = math.max(required, math.floor(packed / 2 ^ ((pixel % 4) * 2)) % 4 + 1)
    end
  elseif format == 3 then
    for pixel = 0, pixelCount - 1 do
      local packed = tonumber(texel[math.floor(pixel / 2)])
      required = math.max(required, math.floor(packed / 2 ^ ((pixel % 2) * 4)) % 16 + 1)
    end
  elseif format == 4 then
    for offset = 0, texelLength - 1 do
      required = math.max(required, tonumber(texel[offset]) + 1)
    end
  elseif format == 5 then
    for offset = 0, indexLength - 2, 2 do
      local control = tonumber(indexData[offset]) + tonumber(indexData[offset + 1]) * 256
      local mode = math.floor(control / 0x4000)
      local entries = mode == 2 and 4 or mode == 0 and 3 or 2
      required = math.max(required, (control % 0x4000) * 2 + entries)
    end
  elseif format == 6 then
    for offset = 0, texelLength - 1 do
      required = math.max(required, tonumber(texel[offset]) % 8 + 1)
    end
  end
  return required
end

local function alphaFlags(hasZero, hasPartial, hasOpaque, alpha)
  if alpha == 0 then
    hasZero = true
  elseif alpha == 255 then
    hasOpaque = true
  else
    hasPartial = true
  end
  return hasZero, hasPartial, hasOpaque
end

local function finishAlpha(hasZero, hasPartial, hasOpaque)
  return { hasZero = hasZero, hasPartial = hasPartial, hasOpaque = hasOpaque }
end

local function decodeA3I5(opts, texel, out, palette)
  local hasZero, hasPartial, hasOpaque = false, false, false
  local pixelCount = opts.width * opts.height
  for pixel = 0, pixelCount - 1 do
    local value = tonumber(texel[pixel])
    local color = palette[value % 32]
    local alpha = math.floor(math.floor(value / 32) * 255 / 7 + 0.5)
    local offset = pixel * 4
    out[offset], out[offset + 1], out[offset + 2], out[offset + 3] = color.r, color.g, color.b, alpha
    hasZero, hasPartial, hasOpaque = alphaFlags(hasZero, hasPartial, hasOpaque, alpha)
  end
  return finishAlpha(hasZero, hasPartial, hasOpaque)
end

local function decode4Color(opts, texel, out, palette)
  local hasZero, hasPartial, hasOpaque = false, false, false
  local pixelCount = opts.width * opts.height
  local written = 0
  for source = 0, math.floor((pixelCount + 3) / 4) - 1 do
    local packed = tonumber(texel[source])
    for shift = 0, 6, 2 do
      if written < pixelCount then
        local index = math.floor(packed / 2 ^ shift) % 4
        local color = palette[index]
        local alpha = (opts.color0Transparent and index == 0) and 0 or 255
        local offset = written * 4
        out[offset], out[offset + 1], out[offset + 2], out[offset + 3] = color.r, color.g, color.b, alpha
        hasZero, hasPartial, hasOpaque = alphaFlags(hasZero, hasPartial, hasOpaque, alpha)
        written = written + 1
      end
    end
  end
  return finishAlpha(hasZero, hasPartial, hasOpaque)
end

local function decode16Color(opts, texel, out, palette)
  local hasZero, hasPartial, hasOpaque = false, false, false
  local pixelCount = opts.width * opts.height
  local written = 0
  for source = 0, math.floor((pixelCount + 1) / 2) - 1 do
    local packed = tonumber(texel[source])
    for shift = 0, 4, 4 do
      if written < pixelCount then
        local index = math.floor(packed / 2 ^ shift) % 16
        local color = palette[index]
        local alpha = (opts.color0Transparent and index == 0) and 0 or 255
        local offset = written * 4
        out[offset], out[offset + 1], out[offset + 2], out[offset + 3] = color.r, color.g, color.b, alpha
        hasZero, hasPartial, hasOpaque = alphaFlags(hasZero, hasPartial, hasOpaque, alpha)
        written = written + 1
      end
    end
  end
  return finishAlpha(hasZero, hasPartial, hasOpaque)
end

local function decode256Color(opts, texel, out, palette)
  local hasZero, hasPartial, hasOpaque = false, false, false
  local pixelCount = opts.width * opts.height
  for pixel = 0, pixelCount - 1 do
    local index = tonumber(texel[pixel])
    local color = palette[index]
    local alpha = (opts.color0Transparent and index == 0) and 0 or 255
    local offset = pixel * 4
    out[offset], out[offset + 1], out[offset + 2], out[offset + 3] = color.r, color.g, color.b, alpha
    hasZero, hasPartial, hasOpaque = alphaFlags(hasZero, hasPartial, hasOpaque, alpha)
  end
  return finishAlpha(hasZero, hasPartial, hasOpaque)
end

local function decodeA5I3(opts, texel, out, palette)
  local hasZero, hasPartial, hasOpaque = false, false, false
  local pixelCount = opts.width * opts.height
  for pixel = 0, pixelCount - 1 do
    local value = tonumber(texel[pixel])
    local color = palette[value % 8]
    local alpha = math.floor(math.floor(value / 8) * 255 / 31 + 0.5)
    local offset = pixel * 4
    out[offset], out[offset + 1], out[offset + 2], out[offset + 3] = color.r, color.g, color.b, alpha
    hasZero, hasPartial, hasOpaque = alphaFlags(hasZero, hasPartial, hasOpaque, alpha)
  end
  return finishAlpha(hasZero, hasPartial, hasOpaque)
end

local function decodeDirectColor(opts, texel, out)
  local hasZero, hasPartial, hasOpaque = false, false, false
  local pixelCount = opts.width * opts.height
  for pixel = 0, pixelCount - 1 do
    local source = pixel * 2
    local value = tonumber(texel[source]) + tonumber(texel[source + 1]) * 256
    local r, g, b = FixedPoint.rgb555(value)
    local alpha = value >= 0x8000 and 255 or 0
    local offset = pixel * 4
    out[offset], out[offset + 1], out[offset + 2], out[offset + 3] = r, g, b, alpha
    hasZero, hasPartial, hasOpaque = alphaFlags(hasZero, hasPartial, hasOpaque, alpha)
  end
  return finishAlpha(hasZero, hasPartial, hasOpaque)
end

local function decodeCompressed(opts, texel, out, palette, indexData)
  local hasZero, hasPartial, hasOpaque = false, false, false
  local blocksPerRow = opts.width / 4
  for by = 0, opts.height / 4 - 1 do
    for bx = 0, blocksPerRow - 1 do
      local block = by * blocksPerRow + bx
      local controlOffset = block * 2
      local control = tonumber(indexData[controlOffset]) + tonumber(indexData[controlOffset + 1]) * 256
      local base = (control % 0x4000) * 2
      local mode = math.floor(control / 0x4000)

      local r0, g0, b0 = paletteColor(palette, base)
      local r1, g1, b1 = paletteColor(palette, base + 1)
      local r2, g2, b2, r3, g3, b3
      local a2, a3 = 255, 255
      if mode == 0 then
        r2, g2, b2 = paletteColor(palette, base + 2)
        r3, g3, b3, a3 = 0, 0, 0, 0
      elseif mode == 1 then
        r2, g2, b2 = blend(palette, base, base + 1, 1, 2)
        r3, g3, b3, a3 = 0, 0, 0, 0
      elseif mode == 2 then
        r2, g2, b2 = paletteColor(palette, base + 2)
        r3, g3, b3 = paletteColor(palette, base + 3)
      else
        r2, g2, b2 = blend(palette, base, base + 1, 5, 8)
        r3, g3, b3 = blend(palette, base, base + 1, 3, 8)
      end

      for row = 0, 3 do
        local packed = tonumber(texel[block * 4 + row])
        for column = 0, 3 do
          local index = math.floor(packed / 2 ^ (column * 2)) % 4
          local r, g, b, alpha
          if index == 0 then
            r, g, b, alpha = r0, g0, b0, 255
          elseif index == 1 then
            r, g, b, alpha = r1, g1, b1, 255
          elseif index == 2 then
            r, g, b, alpha = r2, g2, b2, a2
          else
            r, g, b, alpha = r3, g3, b3, a3
          end
          local offset = ((by * 4 + row) * opts.width + bx * 4 + column) * 4
          out[offset], out[offset + 1], out[offset + 2], out[offset + 3] = r, g, b, alpha
          hasZero, hasPartial, hasOpaque = alphaFlags(hasZero, hasPartial, hasOpaque, alpha)
        end
      end
    end
  end
  return finishAlpha(hasZero, hasPartial, hasOpaque)
end

local DECODERS = {
  [1] = decodeA3I5,
  [2] = decode4Color,
  [3] = decode16Color,
  [4] = decode256Color,
  [6] = decodeA5I3,
  [7] = decodeDirectColor,
}

local function validateAndSources(opts, context)
  assert(type(opts) == "table", "TextureDecoder.decodeInto requires an options table")
  validateDimensions(opts)
  local format = opts.format
  if not TextureDecoder.SUPPORTED[format] then
    if format == 0 then
      error(
        Errors.new(
          "NSBTX_FORMAT_NONE",
          "format 0 is 'no texture' and cannot be decoded",
          { format = 0, source = context }
        )
      )
    end
    error(
      Errors.new(
        "NSBTX_UNSUPPORTED_FORMAT",
        "unsupported texture format " .. tostring(format),
        { format = format, name = context and context.name, source = context }
      )
    )
  end

  local texel, texelLength, texelOwner = sourcePointer(opts.texel, "texel")
  local palette, paletteLength, paletteOwner
  if format ~= 7 then
    palette, paletteLength, paletteOwner = sourcePointer(opts.palette, "palette")
  end
  local indexData, indexLength, indexOwner
  if format == 5 then
    indexData, indexLength, indexOwner = sourcePointer(opts.indexData, "compressed index data")
  end
  local pixelCount = opts.width * opts.height
  local expectedTexelLength = requiredTexelLength(format, pixelCount)
  if expectedTexelLength and texelLength ~= expectedTexelLength then
    badLength("NSBTX_BAD_TEXEL_LENGTH", "texel data", texelLength, expectedTexelLength, context)
  end
  if format == 5 then
    compressedInfo(opts, texelLength, indexLength)
  end
  return texel, texelLength, texelOwner, palette, paletteLength, paletteOwner, indexData, indexLength, indexOwner
end

---@param opts table<string, unknown>
---@param outPtr ffi.cdata*
---@param outLength integer
---@param scratch TextureDecoder.Scratch
---@param context table<string, unknown>?
---@return table<string, boolean>
function TextureDecoder.decodeInto(opts, outPtr, outLength, scratch, context)
  assert(outPtr ~= nil, "TextureDecoder.decodeInto requires an output pointer")
  assert(type(scratch) == "table", "TextureDecoder.decodeInto requires scratch")
  local texel, texelLength, texelOwner, palette, paletteLength, paletteOwner, indexData, indexLength, indexOwner =
    validateAndSources(opts, context)
  local expectedOutputLength = opts.width * opts.height * 4
  if outLength ~= expectedOutputLength then
    badLength("NSBTX_BAD_OUTPUT_LENGTH", "output buffer", outLength, expectedOutputLength, context)
  end
  local out = ffi.cast("uint8_t *", outPtr)
  local paletteStorage
  if opts.format ~= 7 then
    local paletteCount =
      requiredPaletteCount(opts.format, texel, texelLength, indexData, indexLength, opts.width * opts.height)
    paletteStorage = decodePalette(palette, paletteLength, paletteCount, scratch, context)
  end

  local alphaUsage
  if opts.format == 5 then
    alphaUsage = decodeCompressed(opts, texel, out, paletteStorage, indexData)
  elseif opts.format == 7 then
    alphaUsage = decodeDirectColor(opts, texel, out)
  else
    alphaUsage = DECODERS[opts.format](opts, texel, out, paletteStorage)
  end
  assert(texelOwner ~= nil and (opts.format == 7 or paletteOwner ~= nil) and (opts.format ~= 5 or indexOwner ~= nil))
  return alphaUsage
end

-- The string result remains a compatibility/reference API; production
-- producers use decodeInto with a caller-owned ByteData destination.
function TextureDecoder.decode(opts, context)
  assert(type(opts) == "table", "TextureDecoder.decode requires an options table")
  local output = ffi.new("uint8_t[?]", opts.width * opts.height * 4)
  local scratch = context and context.textureScratch or TextureDecoder.newScratch()
  local alphaUsage = TextureDecoder.decodeInto(opts, output, opts.width * opts.height * 4, scratch, context)
  return {
    width = opts.width,
    height = opts.height,
    pixels = ffi.string(output, opts.width * opts.height * 4),
    alphaUsage = alphaUsage,
  }
end

TextureDecoder.SUPPORTED = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true, [7] = true }

return TextureDecoder
