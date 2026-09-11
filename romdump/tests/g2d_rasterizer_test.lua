-- Decoded-G2D screen raster contract: already-decoded CHAR/SCRN/PLTT records
-- become source-independent RGBA pixels with the tile/palette/flip semantics
-- the field-UI producer has always used. Fixtures are hand-built decoded
-- records (no ROM bytes); error cases assert the typed producer failure.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")

local T = {}

local function rasterizer()
  local ok, module = pcall(require, "romdump.src.digest.ui.G2dRasterizer")
  if not ok then
    error("the decoded-G2D rasterizer is missing: " .. tostring(module), 0)
  end
  return module
end

-- 64 pixel values in row-major order -> one 4bpp tile (low nibble first).
local function tile4(values)
  local bytes = {}
  for y = 0, 7 do
    for x = 0, 3 do
      local lo = values[y * 8 + x * 2 + 1]
      local hi = values[y * 8 + x * 2 + 2]
      bytes[#bytes + 1] = string.char(lo + hi * 16)
    end
  end
  return table.concat(bytes)
end

local function solidTile4(value)
  local values = {}
  for _ = 1, 64 do
    values[#values + 1] = value
  end
  return tile4(values)
end

local function gradientTile4()
  local values = {}
  for y = 0, 7 do
    for x = 0, 7 do
      values[#values + 1] = (y * 8 + x) % 16
    end
  end
  return tile4(values)
end

local function charData(tiles, depth)
  return { depth = depth or 3, tiles = table.concat(tiles) }
end

local function paletteData(count, base)
  local colors = {}
  for i = 1, count do
    colors[i] = { r = ((base or 0) + i * 11) % 256, g = ((base or 0) + i * 37) % 256, b = ((base or 0) + i * 53) % 256 }
  end
  return { colors = colors }
end

local function screenData(width, height, entries)
  return { width = width, height = height, entries = entries }
end

local function entry(tile, palette, flipH, flipV)
  return { tile = tile, palette = palette or 0, flipH = flipH or false, flipV = flipV or false }
end

local function cell(tile)
  return { objs = { { x = 0, y = 0, tile = tile, palette = 0, width = 8, height = 8 } } }
end

local function animation(frames)
  return { frames = frames }
end

local function pixelAt(pixels, width, x, y)
  local base = (y * width + x) * 4
  return string.byte(pixels, base + 1, base + 4)
end

function T.opaque_pixels_resolve_through_the_entry_palette_bank()
  local colors = paletteData(32)
  local result = rasterizer().renderScreen(charData({ solidTile4(1) }), colors, screenData(8, 8, { entry(0, 1) }))
  Assert.equal(result.width, 8)
  Assert.equal(result.height, 8)
  Assert.equal(#result.pixels, 8 * 8 * 4)
  -- Value 1 in bank 1 selects the decoded array's colors[1*16+1+1].
  local expected = colors.colors[18]
  local r, g, b, a = pixelAt(result.pixels, 8, 3, 5)
  Assert.equal(r, expected.r)
  Assert.equal(g, expected.g)
  Assert.equal(b, expected.b)
  Assert.equal(a, 255)
end

function T.palette_index_zero_stays_transparent()
  local result =
    rasterizer().renderScreen(charData({ solidTile4(0) }), paletteData(16), screenData(8, 8, { entry(0, 0) }))
  local r, g, b, a = pixelAt(result.pixels, 8, 0, 0)
  Assert.equal(r, 0)
  Assert.equal(g, 0)
  Assert.equal(b, 0)
  Assert.equal(a, 0)
end

function T.horizontal_flip_mirrors_tile_columns()
  local module = rasterizer()
  local tiles = charData({ gradientTile4() })
  local palette = paletteData(16)
  local plain = module.renderScreen(tiles, palette, screenData(8, 8, { entry(0, 0) }))
  local flipped = module.renderScreen(tiles, palette, screenData(8, 8, { entry(0, 0, true, false) }))
  for y = 0, 7 do
    for x = 0, 7 do
      local r1, g1, b1, a1 = pixelAt(plain.pixels, 8, x, y)
      local r2, g2, b2, a2 = pixelAt(flipped.pixels, 8, 7 - x, y)
      Assert.equal(r1, r2)
      Assert.equal(g1, g2)
      Assert.equal(b1, b2)
      Assert.equal(a1, a2)
    end
  end
end

function T.vertical_flip_mirrors_tile_rows()
  local module = rasterizer()
  local tiles = charData({ gradientTile4() })
  local palette = paletteData(16)
  local plain = module.renderScreen(tiles, palette, screenData(8, 8, { entry(0, 0) }))
  local flipped = module.renderScreen(tiles, palette, screenData(8, 8, { entry(0, 0, false, true) }))
  for y = 0, 7 do
    for x = 0, 7 do
      local r1, g1, b1, a1 = pixelAt(plain.pixels, 8, x, y)
      local r2, g2, b2, a2 = pixelAt(flipped.pixels, 8, x, 7 - y)
      Assert.equal(r1, r2)
      Assert.equal(g1, g2)
      Assert.equal(b1, b2)
      Assert.equal(a1, a2)
    end
  end
end

function T.multi_tile_screens_cover_the_declared_dimensions()
  local result = rasterizer().renderScreen(
    charData({ solidTile4(2), solidTile4(3) }),
    paletteData(16),
    screenData(16, 8, { entry(0, 0), entry(1, 0) })
  )
  Assert.equal(result.width, 16)
  Assert.equal(result.height, 8)
  Assert.equal(#result.pixels, 16 * 8 * 4)
end

function T.eight_bpp_tiles_read_one_byte_per_pixel()
  local bytes = {}
  for _ = 1, 64 do
    bytes[#bytes + 1] = string.char(5)
  end
  local colors = paletteData(16)
  local result =
    rasterizer().renderScreen(charData({ table.concat(bytes) }, 4), colors, screenData(8, 8, { entry(0, 0) }))
  local expected = colors.colors[6]
  local r, g, b, a = pixelAt(result.pixels, 8, 7, 7)
  Assert.equal(r, expected.r)
  Assert.equal(g, expected.g)
  Assert.equal(b, expected.b)
  Assert.equal(a, 255)
end

function T.tile_references_past_the_decoded_chars_are_typed_errors()
  local module = rasterizer()
  local ok, err =
    pcall(module.renderScreen, charData({ solidTile4(1) }), paletteData(16), screenData(8, 8, { entry(4, 0) }))
  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(err), "expected a structured raster failure")
  local failure = err ---@cast failure Errors.Error
  Assert.equal(failure.code, module.ERROR.SOURCE_INVALID)
  Assert.equal(failure.context.tile, 4)
  Assert.equal(failure.context.available, 1)
end

function T.pixel_values_past_the_decoded_palette_are_typed_errors()
  local module = rasterizer()
  local colors = { colors = { { r = 1, g = 2, b = 3 }, { r = 4, g = 5, b = 6 } } }
  local ok, err = pcall(module.renderScreen, charData({ solidTile4(1) }), colors, screenData(8, 8, { entry(0, 1) }))
  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(err), "expected a structured raster failure")
  local failure = err ---@cast failure Errors.Error
  Assert.equal(failure.code, module.ERROR.SOURCE_INVALID)
  Assert.equal(failure.context.palette, 1)
  Assert.equal(failure.context.value, 1)
  Assert.equal(failure.context.available, 2)
end

function T.entry_counts_that_contradict_the_dimensions_are_typed_errors()
  local module = rasterizer()
  local ok, err =
    pcall(module.renderScreen, charData({ solidTile4(1) }), paletteData(16), screenData(16, 8, { entry(0, 0) }))
  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(err), "expected a structured raster failure")
  local failure = err ---@cast failure Errors.Error
  Assert.equal(failure.code, module.ERROR.SOURCE_INVALID)
end

function T.animation_frame_selects_its_cell_instead_of_the_sequence_position()
  local module = rasterizer()
  local result = module.renderAnimationFrame(
    charData({ solidTile4(1), solidTile4(2) }),
    paletteData(16),
    { cells = { cell(0), cell(1) } },
    animation({
      {
        cell = 1,
        duration = 4,
        element = "none",
        translateX = 0,
        translateY = 0,
        scaleX = 1,
        scaleY = 1,
        rotation = 0,
      },
    }),
    1
  )
  local expected = paletteData(16).colors[3]
  local r, g, b, a = pixelAt(result.pixels, result.width, 2, 2)
  Assert.equal(r, expected.r)
  Assert.equal(g, expected.g)
  Assert.equal(b, expected.b)
  Assert.equal(a, 255)
end

function T.animation_frame_without_an_element_preserves_the_cell_origin()
  local module = rasterizer()
  local result = module.renderAnimationFrame(
    charData({ solidTile4(1) }),
    paletteData(16),
    { cells = { { objs = { { x = -4, y = -2, tile = 0, palette = 0, width = 8, height = 8 } } } } },
    animation({
      {
        cell = 0,
        duration = 4,
        element = "none",
        translateX = 0,
        translateY = 0,
        scaleX = 1,
        scaleY = 1,
        rotation = 0,
      },
    }),
    1
  )
  Assert.deepEqual(result.offset, { x = -4, y = -2 }, "an untransformed frame preserves its cell origin")
end

function T.animation_frame_palette_override_changes_realized_pixels()
  local module = rasterizer()
  local palette = paletteData(32)
  local result = module.renderAnimationFrame(
    charData({ solidTile4(1) }),
    palette,
    { cells = { cell(0) } },
    animation({
      {
        cell = 0,
        duration = 4,
        element = "none",
        translateX = 0,
        translateY = 0,
        scaleX = 1,
        scaleY = 1,
        rotation = 0,
      },
    }),
    1,
    nil,
    1
  )
  local expected = palette.colors[18]
  local r, g, b, a = pixelAt(result.pixels, result.width, 2, 2)
  Assert.equal(r, expected.r)
  Assert.equal(g, expected.g)
  Assert.equal(b, expected.b)
  Assert.equal(a, 255)
end

function T.animation_frame_transform_changes_the_realized_extent()
  local module = rasterizer()
  local result = module.renderAnimationFrame(
    charData({ solidTile4(1) }),
    paletteData(16),
    { cells = { cell(0) } },
    animation({
      {
        cell = 0,
        duration = 4,
        element = "translate",
        translateX = 3,
        translateY = 2,
        scaleX = 1,
        scaleY = 1,
        rotation = 0,
      },
    }),
    1
  )
  Assert.equal(result.width, 8)
  Assert.equal(result.height, 8)
  Assert.deepEqual(result.offset, { x = 3, y = 2 }, "the realized visual preserves frame translation")
end

function T.animation_frame_transform_preserves_the_cell_origin()
  local module = rasterizer()
  local result = module.renderAnimationFrame(
    charData({ solidTile4(1) }),
    paletteData(16),
    { cells = { { objs = { { x = -4, y = -2, tile = 0, palette = 0, width = 8, height = 8 } } } } },
    animation({
      {
        cell = 0,
        duration = 4,
        element = "translate",
        translateX = 3,
        translateY = 2,
        scaleX = 1,
        scaleY = 1,
        rotation = 0,
      },
    }),
    1
  )
  Assert.deepEqual(result.offset, { x = -1, y = 0 }, "translation must apply to the source cell origin")
end

return { tests = T }
