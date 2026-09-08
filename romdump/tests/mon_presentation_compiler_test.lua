-- Front-portrait producer contract: HGSS character payloads are stored scanned
-- (pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981,
-- src/pokepic.c UnscanPokepic_PtHGSS: 3200 little-endian words masked by the
-- 32-bit LCRNG seeded from word 0) and laid out as a 20x10-tile surface whose
-- left and right 10x10 halves are the two authored 80x80 frames
-- (src/unk_02013FDC.c portrait extraction; the second frame sits at an
-- 80-pixel horizontal offset). Fixtures below drive the real production
-- entrypoints with synthetic NCGR/NCLR containers served by a fake archive
-- pair, so the unscan seam and the frame geometry are proved without a
-- user-owned dump.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local MonCache = require("libs.assets.src.MonCache")
local MonSources = require("romdump.src.config.MonSources")
local MonPresentationCompiler = require("romdump.src.digest.mons.MonPresentationCompiler")

local bit = require("bit")

local T = {}

local PORTRAIT_CELL = 80
local FRONT_FACING = 2

local function u16(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end

local function u32(v)
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

local function container(magic, blocks)
  local body = {}
  local size = 0x10
  for _, blk in ipairs(blocks) do
    body[#body + 1] = blk
    size = size + #blk
  end
  return magic .. string.char(0xFF, 0xFE) .. u16(0x0100) .. u32(size) .. u16(0x10) .. u16(#blocks) .. table.concat(body)
end

local function block(magic, payload)
  return magic:reverse() .. u32(8 + #payload) .. payload
end

local function charContainer(tiles)
  local payload = u16(8) .. u16(0x20) .. u32(3) .. u16(0) .. u16(0) .. u32(0) .. u32(#tiles) .. u32(0x18) .. tiles
  return container("RGCN", { block("CHAR", payload) })
end

local function paletteContainer(words)
  local body = {}
  for _, word in ipairs(words) do
    body[#body + 1] = u16(word)
  end
  return container(
    "NCLR",
    { block("PLTT", string.char(3, 0) .. u16(#words) .. u32(0) .. u32(12) .. table.concat(body)) }
  )
end

-- Sixteen fixed palette words; index 0 is the reserved transparency slot.
local function paletteWords()
  return {
    0x0000,
    0x001F,
    0x03E0,
    0x7C00,
    0x7FFF,
    0x03FF,
    0x7C1F,
    0x7FE0,
    0x4210,
    0x0200,
    0x4000,
    0x0010,
    0x5294,
    0x1CE7,
    0x6318,
    0x0E73,
  }
end

-- A distinct alternate palette for shiny reachability: same shape, a
-- different index-1 color so shared geometry still resolves distinct pixels.
local function shinyPaletteWords()
  local words = paletteWords()
  words[2] = 0x7C00
  return words
end

local function wordsToBytes(words)
  local parts = {}
  for _, word in ipairs(words) do
    parts[#parts + 1] = string.char(word % 256, math.floor(word / 256) % 256)
  end
  return table.concat(parts)
end

local function bytesToWords(bytes)
  local words = {}
  for i = 1, #bytes, 2 do
    words[#words + 1] = string.byte(bytes, i) + string.byte(bytes, i + 1) * 256
  end
  return words
end

local function bytesFromTable(values)
  local parts = {}
  for i = 1, #values, 2048 do
    local chunk = {}
    for j = i, math.min(i + 2047, #values) do
      chunk[#chunk + 1] = string.char(values[j])
    end
    parts[#parts + 1] = table.concat(chunk)
  end
  return table.concat(parts)
end

-- Forward scan: the algebraic inverse of the retail unscan, written from the
-- recurrence directly. The seed word is free (the retail recurrence always
-- clears output word 0), every later scanned word masks its desired output.
local function scanWords(desired, seed0)
  local aLo, aHi = 20077, 16838
  local seed = seed0
  local out = {}
  for _, word in ipairs(desired) do
    out[#out + 1] = bit.bxor(word, seed % 65536)
    local sLo = seed % 65536
    local sHi = math.floor(seed / 65536)
    seed = (sLo * aLo + ((sLo * aHi + sHi * aLo) % 65536) * 65536 + 24691) % 4294967296
  end
  return out
end

-- The compiled producer representative set needs these species/forms present.
local function catalogWithRepresentatives()
  return {
    species = {
      CHIKORITA = { forms = { [0] = {} } },
      CYNDAQUIL = { forms = { [0] = {} } },
      TOTODILE = { forms = { [0] = {} } },
      UNOWN = { forms = { [5] = {} } },
      ROTOM = { forms = { [1] = {} } },
    },
  }
end

-- Serve synthetic members through the two production archive aliases, keyed
-- by each variant's own selected archive and member exactly as the producer
-- resolves them. charFor receives (speciesKey, gender, form) and palFor
-- receives (speciesKey, gender, shiny, form).
---@param catalog { species: table<string, { forms: table<integer, table> }> }
---@param charFor fun(speciesKey: string, gender: string, formId: integer): string
---@param palFor fun(speciesKey: string, gender: string, shiny: boolean, formId: integer): string
---@return table
local function romFsWith(catalog, charFor, palFor)
  local perNarc = {}
  for key, species in pairs(catalog.species) do
    local speciesId = assert(MonSources.speciesId(key), key .. " must be a known species")
    for formId in pairs(species.forms) do
      for _, gender in ipairs({ "male", "female" }) do
        local ids = MonSources.portraitIds(speciesId, gender, FRONT_FACING, false, formId)
        local charStore = perNarc[ids.narc] or {}
        perNarc[ids.narc] = charStore
        charStore[ids.charMemberId] = charFor(key, gender, formId)
        for _, shiny in ipairs({ false, true }) do
          local shinyIds = MonSources.portraitIds(speciesId, gender, FRONT_FACING, shiny, formId)
          local palStore = perNarc[shinyIds.narc] or {}
          perNarc[shinyIds.narc] = palStore
          palStore[shinyIds.palMemberId] = palFor(key, gender, shiny, formId)
        end
      end
    end
  end
  local fs = {}
  function fs:openNarc(alias)
    local members = perNarc[alias] or {}
    local archive = {}
    function archive:readMember(memberId)
      return members[memberId]
    end
    return archive
  end
  return fs
end

local function uniformFs(catalog, charTiles, plainWords, shinyWords)
  local plain = paletteContainer(plainWords or paletteWords())
  local shiny = paletteContainer(shinyWords or shinyPaletteWords())
  return romFsWith(catalog, function()
    return charTiles
  end, function(_, _, isShiny)
    if isShiny then
      return shiny
    end
    return plain
  end)
end

local function mustCompile(fs, catalog)
  local portraits, err = MonPresentationCompiler.compilePortraits(fs, catalog)
  if portraits == nil then
    error("portrait compilation failed: " .. tostring(err and err.code or err), 0)
  end
  return portraits
end

local function pixel(pixels, width, x, y)
  local base = (y * width + x) * 4
  return {
    string.byte(pixels, base + 1),
    string.byte(pixels, base + 2),
    string.byte(pixels, base + 3),
    string.byte(pixels, base + 4),
  }
end

local function assertPixel(pixels, width, x, y, expected, what)
  Assert.deepEqual(pixel(pixels, width, x, y), expected, what)
end

local TRANSPARENT = { 0, 0, 0, 0 }

-- The scanned fixture below carries five nontrivial words followed by zeros;
-- the independent recurrence values for its first words are
-- M0=0x0000 M1=0xEE88 M2=0x4480 M3=0xCC89 M4=0xF980 M5=0xEA60. Tile 0
-- (words 0..15) is the first tile under either frame layout, so these
-- assertions isolate the unscan from the frame geometry: row 0 reads M0/M1,
-- row 1 reads M2/M3, row 2 reads M4/M5.
function T.portrait_bytes_are_unscanned_before_palette_expansion()
  local scanned = { 0xABCD, 0x1234, 0x00FF, 0xF00F, 0x0001 }
  for _ = 1, 3200 - #scanned do
    scanned[#scanned + 1] = 0
  end
  local catalog = catalogWithRepresentatives()
  local portraits = mustCompile(uniformFs(catalog, charContainer(wordsToBytes(scanned))), catalog)
  local selector = MonCache.portraitSelector("CHIKORITA", 0, "male", false)
  local entry = assert(portraits.manifest.entries[selector], "male plain entry must resolve")
  local pixels, width = portraits.image.pixels, portraits.image.width
  -- M0 forces the first two pixels transparent; M1=0xEE88 paints 8,8,14,14.
  assertPixel(pixels, width, entry.x + 0, entry.y + 0, TRANSPARENT, "word0 low pixel stays transparent")
  assertPixel(pixels, width, entry.x + 2, entry.y + 0, TRANSPARENT, "word0 high pixel stays transparent")
  assertPixel(pixels, width, entry.x + 4, entry.y + 0, { 132, 132, 132, 255 }, "M1 low nibbles")
  assertPixel(pixels, width, entry.x + 5, entry.y + 0, { 132, 132, 132, 255 }, "M1 low nibbles")
  assertPixel(pixels, width, entry.x + 6, entry.y + 0, { 197, 197, 197, 255 }, "M1 high nibbles")
  assertPixel(pixels, width, entry.x + 7, entry.y + 0, { 197, 197, 197, 255 }, "M1 high nibbles")
  -- M2=0x4480: row 1 opens with transparent/8 then 4,4.
  assertPixel(pixels, width, entry.x + 0, entry.y + 1, TRANSPARENT, "M2 low nibble zero")
  assertPixel(pixels, width, entry.x + 1, entry.y + 1, { 132, 132, 132, 255 }, "M2 low nibble eight")
  assertPixel(pixels, width, entry.x + 2, entry.y + 1, { 255, 255, 255, 255 }, "M2 high nibbles")
  assertPixel(pixels, width, entry.x + 3, entry.y + 1, { 255, 255, 255, 255 }, "M2 high nibbles")
  -- M3=0xCC89: row 1 continues with 9,8 then 12,12.
  assertPixel(pixels, width, entry.x + 4, entry.y + 1, { 0, 132, 0, 255 }, "M3 low nibbles")
  assertPixel(pixels, width, entry.x + 5, entry.y + 1, { 132, 132, 132, 255 }, "M3 low nibbles")
  assertPixel(pixels, width, entry.x + 6, entry.y + 1, { 165, 165, 165, 255 }, "M3 high nibbles")
  assertPixel(pixels, width, entry.x + 7, entry.y + 1, { 165, 165, 165, 255 }, "M3 high nibbles")
  -- M4=0xF980 M5=0xEA60: row 2 reads 0,8,9,15 then 0,6,10,14.
  assertPixel(pixels, width, entry.x + 0, entry.y + 2, TRANSPARENT, "M4 low nibble zero")
  assertPixel(pixels, width, entry.x + 1, entry.y + 2, { 132, 132, 132, 255 }, "M4 low nibble eight")
  assertPixel(pixels, width, entry.x + 2, entry.y + 2, { 0, 132, 0, 255 }, "M4 high nibble nine")
  assertPixel(pixels, width, entry.x + 3, entry.y + 2, { 156, 156, 25, 255 }, "M4 high nibble fifteen")
  assertPixel(pixels, width, entry.x + 4, entry.y + 2, TRANSPARENT, "M5 low nibble zero")
  assertPixel(pixels, width, entry.x + 5, entry.y + 2, { 255, 0, 255, 255 }, "M5 low nibble six")
  assertPixel(pixels, width, entry.x + 6, entry.y + 2, { 0, 0, 132, 255 }, "M5 high nibble ten")
  assertPixel(pixels, width, entry.x + 7, entry.y + 2, { 197, 197, 197, 255 }, "M5 high nibble fourteen")
  -- Full-buffer determinism: the same scanned payload always yields the same atlas.
  local again = mustCompile(uniformFs(catalog, charContainer(wordsToBytes(scanned))), catalog)
  Assert.equal(again.image.pixels, portraits.image.pixels, "repeated compilation must be byte-identical")
end

local function paintTile(bytes, tileX, tileY, value)
  local tile = tileY * 20 + tileX
  for row = 0, 7 do
    for col = 0, 3 do
      bytes[tile * 32 + row * 4 + col + 1] = value
    end
  end
end

-- Desired post-unscan surface with one marker tile per frame corner plus a
-- second-row marker that only lands correctly with a 20-tile stride. Tile
-- (0,0) keeps word 0 at zero because the retail recurrence always clears it.
function T.portrait_frames_come_from_side_by_side_tile_regions()
  local surface = {}
  for _ = 1, 6400 do
    surface[#surface + 1] = 0
  end
  paintTile(surface, 0, 0, 0x55)
  surface[1], surface[2] = 0, 0
  paintTile(surface, 10, 0, 0x99)
  paintTile(surface, 0, 1, 0x33)
  paintTile(surface, 9, 9, 0x77)
  paintTile(surface, 19, 9, 0xCC)
  local scanned = charContainer(wordsToBytes(scanWords(bytesToWords(bytesFromTable(surface)), 0x1234)))
  local catalog = catalogWithRepresentatives()
  local portraits = mustCompile(uniformFs(catalog, scanned), catalog)
  local pixels, width = portraits.image.pixels, portraits.image.width
  local plain = assert(
    portraits.manifest.entries[MonCache.portraitSelector("CHIKORITA", 0, "male", false)],
    "male plain entry must resolve"
  )
  -- Frame 0 is the left 10 tile columns: tile (0,0) marker 5, tile (0,1) marker 3.
  assertPixel(pixels, width, plain.x + 0, plain.y + 0, TRANSPARENT, "frame0 keeps the cleared word")
  assertPixel(pixels, width, plain.x + 4, plain.y + 0, { 255, 255, 0, 255 }, "frame0 top-left marker")
  assertPixel(pixels, width, plain.x + 0, plain.y + 8, { 0, 0, 255, 255 }, "frame0 second-row marker")
  assertPixel(pixels, width, plain.x + 79, plain.y + 79, { 0, 255, 255, 255 }, "frame0 bottom-right marker")
  -- Frame 1 is the right 10 tile columns, addressed through the second frame rect.
  local second = assert(plain.frames[2], "plain entry must carry a second frame")
  Assert.equal(second.width, PORTRAIT_CELL, "second frame stays 80 wide")
  Assert.equal(second.height, PORTRAIT_CELL, "second frame stays 80 high")
  assertPixel(pixels, width, second.x + 0, second.y + 0, { 0, 132, 0, 255 }, "frame1 top-left marker")
  assertPixel(pixels, width, second.x + 4, second.y + 0, { 0, 132, 0, 255 }, "frame1 holds no left-frame marker")
  assertPixel(pixels, width, second.x + 79, second.y + 79, { 165, 165, 165, 255 }, "frame1 bottom-right marker")
end

function T.short_portrait_payload_fails_with_image_error()
  local catalog = catalogWithRepresentatives()
  local portraits, err =
    MonPresentationCompiler.compilePortraits(uniformFs(catalog, charContainer(string.rep("\0", 3200))), catalog)
  Assert.isNil(portraits, "short payload must not compile")
  Assert.isTrue(Errors.is(err), "short payload must fail structurally")
  Assert.equal(assert(err).code, "MON_IMAGE_TILE_COUNT", "short payload keeps the image-size error")
end

function T.shiny_variant_shares_geometry_with_own_palette()
  local scanned = {}
  for i = 1, 3200 do
    scanned[i] = (i * 257) % 65536
  end
  scanned[1] = 0x0102
  local catalog = catalogWithRepresentatives()
  local portraits = mustCompile(uniformFs(catalog, charContainer(wordsToBytes(scanned))), catalog)
  local plain = assert(
    portraits.manifest.entries[MonCache.portraitSelector("CHIKORITA", 0, "male", false)],
    "male plain entry must resolve"
  )
  local shiny = assert(
    portraits.manifest.entries[MonCache.portraitSelector("CHIKORITA", 0, "male", true)],
    "male shiny entry must resolve"
  )
  for _, entry in ipairs({ plain, shiny }) do
    Assert.equal(entry.width, PORTRAIT_CELL, "entry stays 80 wide")
    Assert.equal(entry.height, PORTRAIT_CELL, "entry stays 80 high")
    Assert.equal(#entry.frames, 2, "entry keeps two frames")
  end
  local function framePixels(entry)
    local out = {}
    for _, frame in ipairs(entry.frames) do
      for row = 0, PORTRAIT_CELL - 1 do
        local base = ((frame.y + row) * portraits.image.width + frame.x) * 4
        out[#out + 1] = portraits.image.pixels:sub(base + 1, base + PORTRAIT_CELL * 4)
      end
    end
    return table.concat(out)
  end
  Assert.isTrue(framePixels(plain) ~= framePixels(shiny), "distinct palettes resolve distinct pixels")
end

-- Gender reachability is owned by the variant selector: an empty female
-- member yields male-only variants, and a species with no reachable member
-- at all fails instead of manufacturing blank coverage.
function T.empty_gender_member_stays_unreachable()
  local scanned = {}
  for i = 1, 3200 do
    scanned[i] = (i * 257) % 65536
  end
  scanned[1] = 0x0102
  local tiles = charContainer(wordsToBytes(scanned))
  local catalog = catalogWithRepresentatives()
  local fs = romFsWith(catalog, function(key, gender)
    if key == "CHIKORITA" and gender == "female" then
      return ""
    end
    return tiles
  end, function(_, _, isShiny)
    if isShiny then
      return paletteContainer(shinyPaletteWords())
    end
    return paletteContainer(paletteWords())
  end)
  local variants, err = MonPresentationCompiler.portraitVariants(fs, assert(MonSources.speciesId("CHIKORITA")), 0)
  Assert.isNil(err, "male-only species still selects")
  local list = assert(variants, "male-only species still selects")
  Assert.equal(#list, 2, "male-only species keeps plain and shiny")
  for _, variant in ipairs(list) do
    Assert.equal(variant.gender, "male", "empty female member adds no variant")
  end
  local emptyFs = romFsWith(catalog, function()
    return ""
  end, function(_, _, isShiny)
    if isShiny then
      return paletteContainer(shinyPaletteWords())
    end
    return paletteContainer(paletteWords())
  end)
  local missing, missingErr =
    MonPresentationCompiler.portraitVariants(emptyFs, assert(MonSources.speciesId("CHIKORITA")), 0)
  Assert.isNil(missing, "species without portrait data selects nothing")
  Assert.isTrue(Errors.is(missingErr), "species without portrait data fails structurally")
  Assert.equal(assert(missingErr).code, "MON_PORTRAIT_NO_VARIANT", "species without portrait data keeps its error")
end

function T.portrait_manifest_keeps_entry_shape()
  local scanned = {}
  for i = 1, 3200 do
    scanned[i] = (i * 257) % 65536
  end
  scanned[1] = 0x0102
  local catalog = catalogWithRepresentatives()
  local portraits = mustCompile(uniformFs(catalog, charContainer(wordsToBytes(scanned))), catalog)
  Assert.equal(portraits.manifest.schema, MonCache.PORTRAIT_MANIFEST_SCHEMA, "manifest schema is unchanged")
  Assert.equal(portraits.manifest.image, MonCache.portraitImagePath(), "atlas path is unchanged")
  for selector, entry in pairs(portraits.manifest.entries) do
    Assert.equal(entry.width, PORTRAIT_CELL, selector .. " stays 80 wide")
    Assert.equal(entry.height, PORTRAIT_CELL, selector .. " stays 80 high")
    Assert.equal(#entry.frames, 2, selector .. " keeps two frames")
    for _, frame in ipairs(entry.frames) do
      Assert.equal(frame.width, PORTRAIT_CELL, selector .. " frame stays 80 wide")
      Assert.equal(frame.height, PORTRAIT_CELL, selector .. " frame stays 80 high")
      Assert.isTrue(frame.x + frame.width <= portraits.image.width, selector .. " frame stays in the atlas")
      Assert.isTrue(frame.y + frame.height <= portraits.image.height, selector .. " frame stays in the atlas")
    end
  end
end

return { tests = T }
