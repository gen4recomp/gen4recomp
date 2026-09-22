-- Semantics-free, member-local previews: an NCGR tile contact sheet and an
-- NCLR swatch grid, both built only from one already-decoded record (no
-- sibling resource is ever consulted). Every fixture is a hand-built decoded
-- G2dDecoder record; none of it encodes a particular game's resources.

local Assert = require("tests.support.Assert")
local PngReader = require("tests.support.PngReader")
local ResourcePreview = require("romdump.src.appdiscovery.ResourcePreview")

local T = {}

--------------------------------------------------------------------------
-- Fixture helpers: decoded G2dDecoder-shaped records, not raw ROM bytes.
--------------------------------------------------------------------------

-- One 4bpp tile filled with a single value (0..15), two pixels per byte,
-- low nibble first.
local function solidTile4(value)
  return string.rep(string.char(value + value * 16), 32)
end

local function charData(tiles, depth)
  return { depth = depth or 3, tiles = table.concat(tiles) }
end

local function paletteData(colors)
  return { colors = colors }
end

-- `n` distinct RGB555-range colors, deterministic and pairwise distinguishable.
local function distinctColors(n)
  local colors = {}
  for i = 0, n - 1 do
    colors[i + 1] = { r = i % 32, g = (i * 3) % 32, b = (i * 7) % 32 }
  end
  return colors
end

--------------------------------------------------------------------------
-- NCGR contact sheet
--------------------------------------------------------------------------

function T.ncgr_preview_is_byte_identical_across_two_runs_for_the_same_input()
  local tiles = {}
  for i = 0, 17 do
    tiles[#tiles + 1] = solidTile4(i % 16)
  end
  local data = charData(tiles)

  local first = assert(ResourcePreview.ncgr(data))
  local second = assert(ResourcePreview.ncgr(data))
  Assert.equal(first.png, second.png)
  Assert.equal(first.width, second.width)
  Assert.equal(first.height, second.height)
end

-- 18 tiles: not a multiple of 16, so the contact sheet spans two rows with
-- the final row only partly real. The minimal rectangle still covers a full
-- 16-tile-wide sheet.
function T.ncgr_preview_covers_the_minimal_rectangle_for_a_non_multiple_of_16_tile_count()
  local tiles = {}
  for i = 0, 17 do
    tiles[#tiles + 1] = solidTile4(i % 16)
  end
  local preview = assert(ResourcePreview.ncgr(charData(tiles)))
  Assert.equal(preview.width, 16 * 8)
  Assert.equal(preview.height, 16)
  Assert.isTrue(#preview.png > 0)
end

-- Sequential, unflipped tilemap order: two tiles filled with distinct 4bpp
-- values must decode to two distinct, but each internally uniform, colors --
-- proving tile 0 occupies the first 8x8 block and tile 1 the next one, with
-- no flip applied.
function T.ncgr_preview_places_tiles_sequentially_with_distinct_synthetic_colors()
  local preview = assert(ResourcePreview.ncgr(charData({ solidTile4(1), solidTile4(14) })))
  Assert.equal(preview.width, 16)
  Assert.equal(preview.height, 8)
  local width, height, rgba = PngReader.rgba(preview.png)
  Assert.equal(width, 16)
  Assert.equal(height, 8)

  local r0, g0, b0, a0 = PngReader.pixel(rgba, width, 0, 0)
  local r0b, g0b, b0b, a0b = PngReader.pixel(rgba, width, 7, 7)
  Assert.equal(r0, r0b)
  Assert.equal(g0, g0b)
  Assert.equal(b0, b0b)
  Assert.equal(a0, 255)
  Assert.equal(a0b, 255)

  local r1, g1, b1 = PngReader.pixel(rgba, width, 8, 0)
  local r1b, g1b, b1b = PngReader.pixel(rgba, width, 15, 7)
  Assert.equal(r1, r1b)
  Assert.equal(g1, g1b)
  Assert.equal(b1, b1b)

  Assert.isFalse(r0 == r1 and g0 == g1 and b0 == b1, "distinct tile values must render distinct colors")
end

function T.ncgr_preview_accepts_8bpp_tiles()
  local tiles = { string.rep(string.char(5), 64), string.rep(string.char(250), 64) }
  local preview = assert(ResourcePreview.ncgr(charData(tiles, 4)))
  Assert.equal(preview.width, 16)
  Assert.equal(preview.height, 8)
end

--------------------------------------------------------------------------
-- NCLR swatch grid
--------------------------------------------------------------------------

function T.nclr_preview_is_byte_identical_across_two_runs_for_the_same_input()
  local data = paletteData(distinctColors(20))
  local first = assert(ResourcePreview.nclr(data))
  local second = assert(ResourcePreview.nclr(data))
  Assert.equal(first.png, second.png)
  Assert.equal(first.width, second.width)
  Assert.equal(first.height, second.height)
end

-- 20 colors need two rows of up to 16 swatches; the sheet stays 16 columns
-- wide and covers every color.
function T.nclr_preview_covers_enough_rows_for_every_color()
  local preview = assert(ResourcePreview.nclr(paletteData(distinctColors(20))))
  Assert.equal(preview.width, 16 * 8)
  Assert.equal(preview.height, 16)
end

-- Color order is preserved: swatch (0,0) is color 1 and swatch (0,1) (start
-- of the second row) is color 17, expanded deterministically from the
-- decoder's 0..31 channel range to 8-bit with full alpha.
function T.nclr_preview_preserves_color_order_and_expands_channels_to_8bit()
  local colors = distinctColors(20)
  local preview = assert(ResourcePreview.nclr(paletteData(colors)))
  local width, _, rgba = PngReader.rgba(preview.png)

  local r, g, b, a = PngReader.pixel(rgba, width, 4, 4)
  local c1 = colors[1]
  Assert.equal(r, math.floor(c1.r * 255 / 31 + 0.5))
  Assert.equal(g, math.floor(c1.g * 255 / 31 + 0.5))
  Assert.equal(b, math.floor(c1.b * 255 / 31 + 0.5))
  Assert.equal(a, 255)

  local r17, g17, b17 = PngReader.pixel(rgba, width, 4, 12)
  local c17 = colors[17]
  Assert.equal(r17, math.floor(c17.r * 255 / 31 + 0.5))
  Assert.equal(g17, math.floor(c17.g * 255 / 31 + 0.5))
  Assert.equal(b17, math.floor(c17.b * 255 / 31 + 0.5))
end

-- An empty/invalid palette is a decoder failure, never a blank preview.
function T.nclr_preview_rejects_an_empty_palette()
  Assert.throws(function()
    ResourcePreview.nclr(paletteData({}))
  end)
end

return { tests = T }
