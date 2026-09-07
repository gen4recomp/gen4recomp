-- Deterministic field-UI compilation and cache publication using synthetic
-- source archives: every decode path (char/screen/palette/cell/animation)
-- runs against hand-built members, malformed source and generated metadata
-- are rejected at the owning layer, and the publication matrix (stage write
-- failure, stage validation failure, first/second publish rename failure)
-- reuses ArtifactPublisher through a FakeCache so the previous ready class
-- stays readable and the marker never claims an incomplete class.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldUiCompiler = require("romdump.src.digest.ui.FieldUiCompiler")
local FieldUiCacheWriter = require("romdump.src.digest.ui.FieldUiCacheWriter")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.codec.src.LuaWriter")
local PngReader = require("tests.support.PngReader")
local Lz10 = require("romdump.src.digest.Lz10")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")

local T = {}

-- v5 schema: for testing, we use a limited manifest config with only types 0..3
-- to keep palette sizes within G2D limits (max 256 colors = 512 bytes).
-- This helper patches the loaded module temporarily during compilation.
local function compileWithTestConfig(romFs, sha1hex, hashLua)
  local manifestConfig = require("romdump.src.config.FieldUiAssets")
  local originalSourceTypes = manifestConfig.signposts.sourceTypes
  local originalWayfinding = manifestConfig.signposts.wayfinding

  -- Patch for test: limit to 4 source types with minimal wayfinding
  manifestConfig.signposts.sourceTypes = { 0, 1, 2, 3 }
  manifestConfig.signposts.wayfinding = {
    [0] = { memberBase = 0x21, maps = { 0, 1, 20 } },
    [1] = { memberBase = 2, maps = { 0, 21 } },
  }

  -- xpcall forwards every return value of a successful call; capture both
  -- `compile`'s bundle and its typed nil,err failure return so callers see
  -- the real error instead of a silently dropped second value.
  local ok, bundle, err = xpcall(FieldUiCompiler.compile, debug.traceback, romFs, sha1hex, hashLua)

  -- Restore original config
  manifestConfig.signposts.sourceTypes = originalSourceTypes
  manifestConfig.signposts.wayfinding = originalWayfinding

  if ok then
    return bundle, err
  end
  error(bundle, 0)
end

local function u16(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end
local function u32(v)
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end
local function swap4(s)
  return s:reverse()
end

local function lz10Wrap(data)
  local head = string.char(0x10, #data % 65536 % 256, math.floor(#data / 256) % 256, math.floor(#data / 65536) % 256)
  local flags = string.char(0)
  local chunks = {}
  for i = 1, #data, 8 do
    local chunk = data:sub(i, math.min(i + 7, #data))
    chunks[#chunks + 1] = flags .. chunk
  end
  return head .. table.concat(chunks)
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
  return swap4(magic) .. u32(8 + #payload) .. payload
end

-- 4bpp char data: `tiles` tiles, tile t all value ((t + base) % 15) + 1, so
-- members with different bases decode to visibly distinct tile runs.
local function charData(tiles, base)
  local payload = u16(8) .. u16(0x20) .. u32(3) .. u16(0) .. u16(0) .. u32(0) .. u32(tiles * 32) .. u32(0x18)
  local body = {}
  for t = 0, tiles - 1 do
    body[#body + 1] = string.rep(string.char((((t + (base or 0)) % 15) + 1) * 0x11), 32)
  end
  return container("RGCN", { block("CHAR", payload .. table.concat(body)) })
end

local function charDataWithTiles(tileBytes)
  local payload = u16(8) .. u16(0x20) .. u32(3) .. u16(0) .. u16(0) .. u32(0) .. u32(#tileBytes * 32) .. u32(0x18)
  return container("RGCN", { block("CHAR", payload .. table.concat(tileBytes)) })
end

local function screenData(entries)
  local body = {}
  for _, e in ipairs(entries) do
    body[#body + 1] = u16(e)
  end
  return container("RCSN", { block("SCRN", u16(256) .. u16(192) .. u32(0) .. u32(#entries * 2) .. table.concat(body)) })
end

-- A full 32x24-tile screen filled with one entry value.
local function fullScreen(entry)
  local entries = {}
  for i = 1, 768 do
    entries[i] = entry
  end
  return screenData(entries)
end

local function paletteData(colors)
  local body = {}
  for _, c in ipairs(colors) do
    body[#body + 1] = u16(c)
  end
  local bodyBytes = table.concat(body)
  -- RLCN-wrapped TTLP: the TTLP chunk is the magic+size header, the
  -- depth/unk/paletteBytes/dataOffset field area, then the colors; the data
  -- offset is 16 (the field area after the chunk header), so the exact chunk
  -- size is 24 + data bytes.
  local ttlp = "TTLP" .. u32(24 + #bodyBytes) .. u32(3) .. u32(0) .. u32(#colors * 2) .. u32(16) .. bodyBytes
  return "RLCN" .. string.char(0xFF, 0xFE) .. u16(0x0100) .. u32(0x10 + #ttlp) .. u16(0x10) .. u16(1) .. ttlp
end

local function cellData(objs)
  local metatile = u16(#objs) .. u16(0) .. u32(0)
  local attr = {}
  for _, o in ipairs(objs) do
    attr[#attr + 1] = u16((o.y % 256) + (o.shape or 0) * 16384)
      .. u16((o.x % 512) + (o.flipH and 4096 or 0) + (o.flipV and 8192 or 0) + (o.size or 0) * 16384)
      .. u16(o.tile + o.pal * 4096)
  end
  return container("RECN", {
    block("CEBK", u16(1) .. u16(0) .. u32(0x18) .. u32(0) .. string.rep("\0", 12) .. metatile .. table.concat(attr)),
  })
end

local function animData(frames)
  local anims = u16(1) .. u16(#frames) .. u32(0x18) .. u32(0x28) .. u32(0x28 + 8 * #frames) .. string.rep("\0", 8)
  local anim = u32(#frames) .. u16(0) .. u16(1) .. u32(1) .. u32(0)
  local frameBlocks = {}
  local frameData = {}
  for i, f in ipairs(frames) do
    frameBlocks[#frameBlocks + 1] = u32((i - 1) * 2) .. u16(f.duration) .. u16(0)
    frameData[#frameData + 1] = u16(f.cell)
  end
  return container("RNAN", { block("ABNK", anims .. anim .. table.concat(frameBlocks) .. table.concat(frameData)) })
end

local function narc(members)
  local btaf = u16(#members) .. u16(0)
  local offset = 0
  local sizes = {}
  for _, bytes in ipairs(members) do
    sizes[#sizes + 1] = #bytes
    offset = offset + #bytes
  end
  local running = 0
  for _, size in ipairs(sizes) do
    btaf = btaf .. u32(running) .. u32(running + size)
    running = running + size
  end
  local gmif = table.concat(members)
  local function narcBlock(magic, payload)
    return magic .. u32(8 + #payload) .. payload
  end
  local btafBlock = narcBlock("BTAF", btaf)
  local gmifBlock = narcBlock("GMIF", gmif)
  return "NARC"
    .. string.char(0xFF, 0xFE)
    .. u16(0x0100)
    .. u32(0x10 + #btafBlock + #gmifBlock)
    .. u16(0x10)
    .. u16(2)
    .. btafBlock
    .. gmifBlock
end

-- A palette to support test source types with 16 colors each.
-- v5 schema requires per-source-type palette banks. Tests use only types 0..3,
-- so we need 4 * 16 = 64 colors (well within the 256-color G2D palette limit).
-- Use the same pattern as the original to maintain compatibility with
-- existing pixel value assertions in tests.
local function palette16()
  local colors = {}
  -- First 16 colors: the original test pattern
  for i = 1, 16 do
    colors[i] = i * 0x39B
  end
  -- Additional 48 colors: repeat the pattern 3 more times for the 4 source types
  for i = 17, 64 do
    colors[i] = ((i - 1) % 16 + 1) * 0x39B
  end
  return paletteData(colors)
end

-- A fixture palette: explicit color arrays (for under-sized palette tests)
-- or the full 16-color ramp.
local function paletteOr16(colors)
  if colors then
    return paletteData(colors)
  end
  return palette16()
end

-- A signpost palette whose bank for type `t` slot `s` is an unmistakable
-- (r=t, g=s, b=0) RGB555 signature: with only 4 test types and 16 slots,
-- both fit their own 5-bit channel exactly, so no two (type, slot) pairs
-- ever share a signature and a bank mix-up is a visibly wrong color, never
-- a coincidentally-matching one.
local function distinctSignpostPalette(numTypes)
  local colors = {}
  for t = 0, numTypes - 1 do
    for s = 0, 15 do
      colors[t * 16 + s + 1] = t + s * 32
    end
  end
  return colors
end

-- A synthetic RomFs whose four UI NARCs carry minimal valid members matching
-- the audited HGSS geometry: 20 dialogue frames of 18 tiles, the signpost
-- frame of 18 tiles, the wayfinding members (2..0x35, the type-0 0x21+map
-- and type-1 2+map ranges the producer selects) of 24 tiles, the start menu
-- bg + cursor, and the card front. Palettes carry enough colors for test
-- source types (4 types * 16 colors = 64 colors) so every tile value and
-- palette bank the fixture chars emit is covered. `opts` allows per-test
-- source tampering: cursor OBJ geometry, the background screen entry, the
-- background palette colors, and a whole-member tamper hook.
--
-- v5 schema: compile uses a test-specific config with only types 0..3 instead
-- of the production config's 25 types, to keep palette sizes within G2D limits.
local function fixture(opts)
  opts = opts or {}
  local startMenuMembers = {}
  startMenuMembers[13] = lz10Wrap(charData(128))
  startMenuMembers[14] = lz10Wrap(fullScreen(opts.screenEntry or 0))
  startMenuMembers[16] = lz10Wrap(paletteOr16(opts.bgPalette))
  startMenuMembers[62] = lz10Wrap(palette16())
  startMenuMembers[63] = lz10Wrap(cellData(opts.cursor or { { x = 0, y = 0, tile = 0, pal = 0 } }))
  startMenuMembers[64] = lz10Wrap(animData({ { duration = 3, cell = 0 }, { duration = 3, cell = 0 } }))
  startMenuMembers[65] = lz10Wrap(charData(17))
  local startMenu = {}
  for i = 1, 65 do
    startMenu[i] = startMenuMembers[i] or string.rep("\0", 4)
  end

  local signpostMembers = {}
  signpostMembers[1] = charData(18)
  signpostMembers[2] = opts.signpostPalette and paletteData(opts.signpostPalette) or palette16()
  for memberId = 2, 0x35 do
    signpostMembers[memberId + 1] = charData(24, memberId % 16)
  end
  local signposts = {}
  for i = 1, 0x36 do
    signposts[i] = signpostMembers[i] or string.rep("\0", 4)
  end

  local card = {}
  for i = 1, 48 do
    card[i] = string.rep("\0", 4)
  end
  card[42] = charData(128)
  card[48] = fullScreen(0)
  card[12] = paletteData({ 0x7FFF, 0x001F })

  local function narcFile(alias)
    local members
    if alias == "start_menu" then
      members = startMenu
    elseif alias == "dialogue_frames" then
      members = {}
      for i = 1, 47 do
        members[i] = string.rep("\0", 4)
      end
      for i = 1, 20 do
        members[2 + i] = lz10Wrap(charData(18))
      end
      for i = 1, 20 do
        members[26 + i] = lz10Wrap(paletteOr16(opts.framePalette))
      end
      members[0x16 + 1] = lz10Wrap(opts.cursorChar or charData(12))
    elseif alias == "signpost_graphics" then
      members = signposts
    else
      members = card
    end
    if opts.tamper then
      members = opts.tamper(alias, members)
    end
    return narc(members)
  end
  local archives = {
    start_menu = { fileId = 10, narcId = 14, path = "a/0/1/4", symbol = "NARC_a_0_1_4", alias = "start_menu" },
    dialogue_frames = { fileId = 11, narcId = 38, path = "a/0/3/8", symbol = "NARC_a_0_3_8", alias = "dialogue_frames" },
    signpost_graphics = {
      fileId = 12,
      narcId = 36,
      path = "a/0/3/6",
      symbol = "NARC_a_0_3_6",
      alias = "signpost_graphics",
    },
    trainer_card_graphics = {
      fileId = 13,
      narcId = 49,
      path = "a/0/4/9",
      symbol = "NARC_a_0_4_9",
      alias = "trainer_card_graphics",
    },
  }
  local romFs = {
    resolvedNarc = function(_, alias)
      return archives[alias]
    end,
    read = function(_, fileId)
      if fileId == 10 then
        return narcFile("start_menu")
      end
      if fileId == 11 then
        return narcFile("dialogue_frames")
      end
      if fileId == 12 then
        return narcFile("signpost_graphics")
      end
      if fileId == 13 then
        return narcFile("trainer_card_graphics")
      end
      Assert.fail("unexpected read " .. tostring(fileId))
    end,
    openNarc = function(_, alias)
      local Narc = require("libs.nds.src.nitro.Narc")
      return assert(Narc.open(narcFile(alias), alias))
    end,
    metadata = function()
      return { sha1 = "rom-sha" }
    end,
    version = function()
      return "heartgold"
    end,
  }
  return romFs, function()
    return "member-sha"
  end, function()
    return "dependency-sha"
  end
end

function T.compiles_the_manifest_and_all_assets()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  Assert.equal(bundle.manifest.schema, FieldUiAssetCache.SCHEMA)
  Assert.equal(bundle.manifest.dialogueFrames.count, 20)
  local type0 = bundle.manifest.signposts.types[0]
  Assert.equal(type0.sourceType, 0)
  Assert.isTrue(type0.wayfinding[0] ~= nil, "type 0 map 0 carries a wayfinding row")
  Assert.isTrue(type0.wayfinding[20] ~= nil, "type 0 map 20 (the corpus maximum) carries a wayfinding row")
  Assert.isTrue(type0.wayfinding[0].y ~= type0.wayfinding[1].y, "the map-0 and map-1 rows are distinct atlas rows")
  Assert.isTrue(
    bundle.manifest.signposts.types[1].wayfinding[21] ~= nil,
    "type 1 map 21 (the corpus maximum) carries a wayfinding row"
  )
  Assert.isNil(bundle.manifest.signposts.types[2].wayfinding, "type 2 has no map graphic")
  Assert.equal(bundle.manifest.startMenu.slots[10].x, 128)
  local assetCount = 0
  for _ in pairs(bundle.assets) do
    assetCount = assetCount + 1
  end
  Assert.equal(assetCount, 7)
  for path, bytes in pairs(bundle.assets) do
    Assert.isTrue(path:find("^assets/generated/field/ui/") ~= nil)
    Assert.isTrue(#bytes > 0)
  end
  Assert.equal(bundle.marker, "field-ui-cache-v1:rom-sha:dependency-sha")
end

function T.compilation_is_deterministic()
  local romFs, sha1, hashLua = fixture()
  local a = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local b = assert(compileWithTestConfig(romFs, sha1, hashLua))
  Assert.equal(a.marker, b.marker)
  Assert.equal(LuaWriter.encode(a.manifest), LuaWriter.encode(b.manifest))
  for path, bytes in pairs(a.assets) do
    Assert.equal(bytes, b.assets[path])
  end
end

-- The manifest asset entries must describe the actual PNGs: pixel value v
-- maps to palette color v (the fixture's frame tiles carry value 1, which is
-- the fixture's second palette color 0x736 = (8,206,181), not the first
-- 0x39B), every tile value the fixture emits is covered by the 16-color
-- palette, and every declared atlas dimension matches the encoded image.
function T.atlas_pixels_and_dimensions_follow_the_source_mapping()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  for key, entry in pairs(bundle.manifest.assets) do
    local bytes = assert(bundle.assets[entry.image])
    local width, height = PngReader.rgba(bytes)
    Assert.equal(width, entry.width, key .. " width")
    Assert.equal(height, entry.height, key .. " height")
  end

  local frameWidth, _, frameRgba =
    PngReader.rgba(bundle.assets[bundle.manifest.assets[FieldUiAssetCache.ASSET.DIALOGUE_FRAME_TILES].image])
  local r, g, b, a = PngReader.pixel(frameRgba, frameWidth, 0, 0)
  -- Frame tile 0 carries pixel value 1; a 4bpp pixel value v selects the
  -- decoded bank's entry v (entry 0 is the reserved transparent slot), which
  -- is colors[v+1] in the 1-based decoded array: colors[2] = 2*0x39B = 0x736
  -- -> RGB555(r5=22, g5=25, b5=1).
  Assert.equal(r, 181)
  Assert.equal(g, 206)
  Assert.equal(b, 8)
  Assert.equal(a, 255)
  -- Tile 1 carries value 2 and tile 14 value 15; the 16-color palette covers
  -- both, each through its own distinct entry.
  local r2, g2, b2, a2 = PngReader.pixel(frameRgba, frameWidth, 8, 0)
  -- Frame tile 1 value 2 -> colors[3] = 3*0x39B = 0xAD1 -> RGB555(r5=17, g5=22, b5=2)
  Assert.equal(a2, 255)
  Assert.deepEqual({ r2, g2, b2 }, { 140, 181, 16 })
  local r3, g3, b3, a3 = PngReader.pixel(frameRgba, frameWidth, 14 * 8, 0)
  -- Frame tile 14 value 15 -> colors[16] = 16*0x39B = 0x39B0 -> RGB555(r5=16, g5=13, b5=14)
  Assert.equal(a3, 255)
  Assert.deepEqual({ r3, g3, b3 }, { 132, 107, 115 })

  -- The start menu background screen references tile 0 of palette bank 0,
  -- which the fixture palette covers: every pixel is the value-1 color.
  local bgWidth, _, bgRgba =
    PngReader.rgba(bundle.assets[bundle.manifest.assets[FieldUiAssetCache.ASSET.START_MENU_BACKGROUND].image])
  local rB, gB, bB, aB = PngReader.pixel(bgRgba, bgWidth, 10, 10)
  -- Same tile 0 / value 1 mapping as the dialogue frame above -> colors[2].
  Assert.equal(aB, 255)
  Assert.deepEqual({ rB, gB, bB }, { 181, 206, 8 })
end

function T.dialogue_cursor_phases_compose_frame_backing_and_payload()
  local cursorTiles = {}
  for phase = 0, 2 do
    cursorTiles[phase * 4 + 1] = string.rep("\0", 32)
    cursorTiles[phase * 4 + 2] = string.rep(string.char(0x22), 32)
    cursorTiles[phase * 4 + 3] = string.rep("\0", 32)
    cursorTiles[phase * 4 + 4] = string.rep("\0", 32)
  end
  local romFs, sha1, hashLua = fixture({ cursorChar = charDataWithTiles(cursorTiles) })
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local cursorEntry = bundle.manifest.assets[FieldUiAssetCache.ASSET.DIALOGUE_CONTINUE_CURSOR]
  local cursorWidth, _, cursorRgba = PngReader.rgba(bundle.assets[cursorEntry.image])
  local frameEntry = bundle.manifest.assets[FieldUiAssetCache.ASSET.DIALOGUE_FRAME_TILES]
  local frameWidth, _, frameRgba = PngReader.rgba(bundle.assets[frameEntry.image])

  for style = 0, bundle.manifest.dialogueFrames.count - 1 do
    local frameY = style * 8
    local backing = { PngReader.pixel(frameRgba, frameWidth, 10 * 8, frameY) }
    local payload = { PngReader.pixel(frameRgba, frameWidth, 8, frameY) }
    for phase = 0, 2 do
      local cursorX = phase * 16
      local backedPixel = { PngReader.pixel(cursorRgba, cursorWidth, cursorX + 1, style * 16 + 1) }
      local payloadPixel = { PngReader.pixel(cursorRgba, cursorWidth, cursorX + 8 + 1, style * 16 + 1) }
      Assert.deepEqual(backedPixel, backing, "phase " .. phase .. " keeps the frame backing for style " .. style)
      Assert.deepEqual(payloadPixel, payload, "phase " .. phase .. " keeps the cursor payload for style " .. style)
      Assert.deepEqual(
        bundle.manifest.dialogueFrames.continueCursor.styles[style].phases[phase],
        { x = cursorX, y = style * 16, width = 16, height = 16 },
        "phase " .. phase .. " keeps the generated placement for style " .. style
      )
    end
  end
end

-- Every (type, map) pair gets its own atlas row, and the map-0 and map-1
-- rows of the same type decode to different pixels, so a consumer sampling
-- the wrong map's row is a visible mismatch.
function T.wayfinding_map_rows_are_distinct_atlas_rows_with_distinct_pixels()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local atlas = bundle.assets[bundle.manifest.assets[FieldUiAssetCache.ASSET.SIGNPOST_WAYFINDING].image]
  local width, _, rgba = PngReader.rgba(atlas)
  local type0 = bundle.manifest.signposts.types[0]
  local rect0 = assert(type0.wayfinding[0], "type 0 map 0 row")
  local rect1 = assert(type0.wayfinding[1], "type 0 map 1 row")
  Assert.isTrue(rect0.y ~= rect1.y, "map 0 and map 1 must be separate atlas rows")
  local function rowPixels(rect)
    return rgba:sub(rect.y * width * 4 + 1, (rect.y + rect.height) * width * 4)
  end
  Assert.isTrue(rowPixels(rect0) ~= rowPixels(rect1), "map 0 and map 1 rows must decode to distinct pixels")
end

-- Every configured source type gets its own 16-entry palette bank, and slot
-- s of type n's bank is exactly the decoded palette color n*16+s: with the
-- (r=type, g=slot, b=0) signature palette, a bank built from the wrong
-- offset (e.g. always bank 0) would produce the wrong type's colors.
function T.every_type_gets_its_own_bank_at_the_correct_slot_offset()
  local Rgb555 = require("libs.codec.src.Rgb555")
  local romFs, sha1, hashLua = fixture({ signpostPalette = distinctSignpostPalette(4) })
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  for sourceType = 0, 3 do
    local typeEntry = assert(bundle.manifest.signposts.types[sourceType], "type " .. sourceType)
    local count = 0
    for slot = 0, 15 do
      local expected = Rgb555.decode(sourceType + slot * 32)
      Assert.deepEqual(
        typeEntry.palette[slot],
        expected,
        "type " .. sourceType .. " slot " .. slot .. " must be decoded color " .. (sourceType * 16 + slot)
      )
      count = count + 1
    end
    Assert.equal(count, 16, "type " .. sourceType .. " palette has exactly 16 slots")
  end
end

-- The frame strip row for source type t is rendered with bank t, not bank 0:
-- the frame char is shared across every type row (same tile values), so
-- comparing the same tile column across two rows isolates the palette.
function T.frame_row_pixels_use_the_row_s_own_source_type_palette()
  local Rgb555 = require("libs.codec.src.Rgb555")
  local romFs, sha1, hashLua = fixture({ signpostPalette = distinctSignpostPalette(4) })
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local atlas = bundle.assets[bundle.manifest.assets[FieldUiAssetCache.ASSET.SIGNPOST_TILES].image]
  local width, _, rgba = PngReader.rgba(atlas)
  -- The signpost frame char is charData(18) (base 0): tile 0 carries pixel
  -- value 1, which selects palette slot 1 (colors[base+v+1] = bank[v]).
  for sourceType = 0, 3 do
    local rect = assert(bundle.manifest.signposts.types[sourceType].frameTiles)
    local r, g, b, a = PngReader.pixel(rgba, width, 0, rect.y)
    local expected = Rgb555.decode(sourceType + 1 * 32)
    Assert.equal(a, 255)
    Assert.deepEqual({ r, g, b }, { expected.r, expected.g, expected.b }, "frame row " .. sourceType .. " tile 0 pixel")
  end
end

-- The wayfinding row for a (type, map) pair renders with its own source
-- type's bank, never a shared/default bank: type 0 and type 1 wayfinding
-- rows carry visibly different tile values (from the source member's
-- distinct base) and distinct palettes, so both the tile source and the
-- palette selection must agree with the row's own type.
function T.wayfinding_row_pixels_use_the_row_s_own_source_type_palette()
  local Rgb555 = require("libs.codec.src.Rgb555")
  local romFs, sha1, hashLua = fixture({ signpostPalette = distinctSignpostPalette(4) })
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local atlas = bundle.assets[bundle.manifest.assets[FieldUiAssetCache.ASSET.SIGNPOST_WAYFINDING].image]
  local width, _, rgba = PngReader.rgba(atlas)
  -- type 0 map 0 -> member 0x21, tile 0 value ((0 + 0x21 % 16) % 15) + 1 = 2.
  -- type 1 map 0 -> member 2, tile 0 value ((0 + 2 % 16) % 15) + 1 = 3.
  local rect0 = assert(bundle.manifest.signposts.types[0].wayfinding[0])
  local rect1 = assert(bundle.manifest.signposts.types[1].wayfinding[0])
  local r0, g0, b0, a0 = PngReader.pixel(rgba, width, 0, rect0.y)
  local r1, g1, b1, a1 = PngReader.pixel(rgba, width, 0, rect1.y)
  local expected0 = Rgb555.decode(0 + 2 * 32)
  local expected1 = Rgb555.decode(1 + 3 * 32)
  Assert.equal(a0, 255)
  Assert.equal(a1, 255)
  Assert.deepEqual({ r0, g0, b0 }, { expected0.r, expected0.g, expected0.b }, "type 0 map 0 uses type 0's bank")
  Assert.deepEqual({ r1, g1, b1 }, { expected1.r, expected1.g, expected1.b }, "type 1 map 0 uses type 1's bank")
end

-- A source type configured without a full 16-color bank in the palette
-- member is a stop-and-report source defect, not a silently-dropped type.
function T.missing_source_palette_bank_fails_with_source_invalid()
  -- 3 full banks (types 0..2) only; the config still requests type 3.
  local colors = distinctSignpostPalette(3)
  local romFs, sha1, hashLua = fixture({ signpostPalette = colors })
  local bundle, err = compileWithTestConfig(romFs, sha1, hashLua)
  Assert.isNil(bundle, "compilation must fail when a configured type has no palette bank")
  local typed = assert(err)
  Assert.equal(typed.code, FieldUiCompiler.ERROR.SOURCE_INVALID)
  Assert.equal(typed.context.sourceType, 3)
  Assert.equal(typed.context.slot, 0)
  Assert.equal(typed.context.requiredColorIndex, 48)
  Assert.equal(typed.context.availableColors, 48)
end

-- A source type without any wayfinding member selection still gets a real
-- frame row and a full palette bank: absence of wayfinding is not absence
-- of the type's other data.
function T.source_type_without_wayfinding_still_has_frame_and_palette()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local type2 = assert(bundle.manifest.signposts.types[2])
  Assert.isNil(type2.wayfinding, "type 2 has no wayfinding configured")
  Assert.isTrue(type2.palette ~= nil and type2.frameTiles ~= nil, "type 2 still carries a palette and frame row")
  local count = 0
  for _ in pairs(type2.palette) do
    count = count + 1
  end
  Assert.equal(count, 16, "type 2's palette is still the full 16-entry bank")
end

-- No source-archive detail (NARC alias, member id, palette member, byte
-- offset) may leak into the runtime manifest: only the normalized RGB
-- palette and pixel rects belong there.
function T.source_member_ids_do_not_leak_into_the_runtime_manifest()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local forbiddenKeys = { member = true, memberId = true, narcId = true, alias = true, fileId = true }
  local function scan(value, path)
    if type(value) ~= "table" then
      return
    end
    for k, v in pairs(value) do
      if type(k) == "string" and forbiddenKeys[k] then
        Assert.fail("manifest leaks source detail '" .. k .. "' at " .. path)
      end
      scan(v, path .. "." .. tostring(k))
    end
  end
  scan(bundle.manifest.signposts, "signposts")
end

-- cellBounds must span the actual objects: with strictly positive object
-- coordinates the zero-origin initialization would widen every extent.
function T.cell_bounds_cover_all_positive_object_coordinates()
  local romFs, sha1, hashLua = fixture({
    cursor = { { x = 8, y = 8, tile = 0, pal = 0 }, { x = 16, y = 16, tile = 1, pal = 0 } },
  })
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local frame = bundle.manifest.startMenu.cursor.frames[1]
  Assert.deepEqual({ frame.width, frame.height }, { 16, 16 }, "bounds span exactly x 8..24, y 8..24")
end

-- Same for negative-origin objects: with every extent below zero the
-- zero-origin initialization would inflate the bounds to the origin.
function T.cell_bounds_cover_negative_origin_object_coordinates()
  local romFs, sha1, hashLua = fixture({
    cursor = { { x = -16, y = -16, tile = 0, pal = 0 }, { x = -24, y = -24, tile = 1, pal = 0 } },
  })
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local frame = bundle.manifest.startMenu.cursor.frames[1]
  Assert.deepEqual({ frame.width, frame.height }, { 16, 16 }, "bounds span exactly x -24..-8, y -24..-8")
end

-- The real start-menu cursor is a 32x32 square OBJ (attr0 shape 0, attr1
-- size 2): all sixteen tiles must render into the compiled frame, not just
-- the first tile as an 8x8 fragment.
function T.square_32x32_cursor_objs_compile_all_sixteen_tiles()
  local romFs, sha1, hashLua = fixture({
    cursor = { { x = 8, y = 8, tile = 0, pal = 0, size = 2 } },
  })
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local frame = bundle.manifest.startMenu.cursor.frames[1]
  Assert.equal(frame.width, 32)
  Assert.equal(frame.height, 32)
  local path = bundle.manifest.assets[FieldUiAssetCache.ASSET.START_MENU_CURSOR].image
  local width, height, rgba = PngReader.rgba(bundle.assets[path])
  Assert.equal(width, 32)
  Assert.equal(height, 32)
  -- Tile 14 (row 3, col 2 of the 4x4 layout) carries value 15 -> colors[16]
  -- (entry 0 is the reserved transparent slot, so pixel value v selects the
  -- decoded array's colors[v+1]).
  local r, g, b, a = PngReader.pixel(rgba, width, 2 * 8 + 4, 3 * 8 + 4)
  -- value 15 -> colors[16] = 16*0x39B = 0x39B0 -> RGB555(r5=16, g5=13, b5=14)
  Assert.equal(a, 255)
  Assert.deepEqual({ r, g, b }, { 132, 107, 115 })
end

-- A flipped OBJ mirrors the whole object per the OAM layout: the tile grid
-- order must mirror as well as each tile. With flipH, tile 14 (value 15)
-- moves from grid (row 3, col 2) to (row 3, col 1), and tile 13 (value 14)
-- takes its place.
function T.flipped_cursor_objs_mirror_the_tile_grid()
  local romFs, sha1, hashLua = fixture({
    cursor = { { x = 8, y = 8, tile = 0, pal = 0, size = 2, flipH = true } },
  })
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local path = bundle.manifest.assets[FieldUiAssetCache.ASSET.START_MENU_CURSOR].image
  local width, _, rgba = PngReader.rgba(bundle.assets[path])
  local r, g, b, a = PngReader.pixel(rgba, width, 1 * 8 + 4, 3 * 8 + 4)
  Assert.equal(a, 255)
  -- Tile 14 value 15 -> colors[16] = 16*0x39B = 0x39B0 -> RGB555(r5=16, g5=13, b5=14)
  Assert.deepEqual({ r, g, b }, { 132, 107, 115 }, "tile 14 renders mirrored at grid column 1")
  local r2, g2, b2, a2 = PngReader.pixel(rgba, width, 2 * 8 + 4, 3 * 8 + 4)
  Assert.equal(a2, 255)
  -- Tile 13 value 14 -> colors[15] = 15*0x39B = 0x3615 -> RGB555(r5=21, g5=16, b5=13)
  Assert.deepEqual({ r2, g2, b2 }, { 173, 132, 107 }, "tile 13 renders at the mirrored tile 14 position")
end

-- A wide or tall OBJ is a geometry this compiler does not support: the
-- cursor must reject it with the typed source error and enough context to
-- name the asset, member, cell, object, and decoded dimensions.
function T.unsupported_cursor_obj_geometry_is_a_typed_source_error()
  local romFs, sha1, hashLua = fixture({
    cursor = { { x = 0, y = 0, tile = 0, pal = 0, shape = 1 } },
  })
  local bundle, err = compileWithTestConfig(romFs, sha1, hashLua)
  Assert.isNil(bundle)
  local typed = assert(err)
  Assert.equal(typed.code, FieldUiCompiler.ERROR.SOURCE_INVALID)
  Assert.equal(typed.context.width, 16)
  Assert.equal(typed.context.height, 8)
  local source = typed.context.source --[[@as table]]
  Assert.equal(source.member, 62)
  Assert.equal(source.cell, 0)
  Assert.equal(source.obj, 0)
end

-- A screen entry referencing a tile beyond the decoded char data is
-- malformed source, not a later nil-byte arithmetic failure.
function T.out_of_range_tile_references_are_typed_source_errors()
  local romFs, sha1, hashLua = fixture({ screenEntry = 500 })
  local bundle, err = compileWithTestConfig(romFs, sha1, hashLua)
  Assert.isNil(bundle)
  local typed = assert(err)
  Assert.equal(typed.code, FieldUiCompiler.ERROR.SOURCE_INVALID)
  Assert.equal(typed.context.tile, 500)
  Assert.equal(typed.context.available, 128)
end

-- A pixel value the decoded palette cannot cover is malformed source, never
-- accidental transparency: the two-color fixture palette cannot cover
-- palette bank 1.
function T.out_of_palette_pixel_values_are_typed_source_errors()
  local romFs, sha1, hashLua = fixture({
    bgPalette = { 0x7FFF, 0x001F },
    screenEntry = 0x1000,
  })
  local bundle, err = compileWithTestConfig(romFs, sha1, hashLua)
  Assert.isNil(bundle)
  local typed = assert(err)
  Assert.equal(typed.code, FieldUiCompiler.ERROR.SOURCE_INVALID)
  Assert.equal(typed.context.palette, 1)
  Assert.equal(typed.context.value, 1)
  Assert.equal(typed.context.available, 2)
end

-- A truncated LZ10 member in a real-shaped ROM is a typed stream error at
-- the compiler boundary, never a raw Lua exception.
function T.truncated_lz10_members_are_typed_stream_errors()
  local romFs, sha1, hashLua = fixture({
    tamper = function(alias, members)
      if alias == "start_menu" then
        members[13] = lz10Wrap(charData(128)):sub(1, 24)
      end
      return members
    end,
  })
  local bundle, err = compileWithTestConfig(romFs, sha1, hashLua)
  Assert.isNil(bundle)
  Assert.equal(assert(err).code, Lz10.ERROR.STREAM_INVALID)
end

-- A member whose container repeats a logical chunk id is a typed G2D
-- structural error at the compiler boundary, not a silent replacement.
function T.duplicate_g2d_chunks_in_members_are_typed_errors()
  local payload = u16(8)
    .. u16(0x20)
    .. u32(3)
    .. u16(0)
    .. u16(0)
    .. u32(0)
    .. u32(32)
    .. u32(0x18)
    .. string.rep("\1", 32)
  local romFs, sha1, hashLua = fixture({
    tamper = function(alias, members)
      if alias == "start_menu" then
        members[13] = container("RGCN", { block("CHAR", payload), block("CHAR", payload) })
      end
      return members
    end,
  })
  local bundle, err = compileWithTestConfig(romFs, sha1, hashLua)
  Assert.isNil(bundle)
  Assert.equal(assert(err).code, G2dDecoder.ERROR.CHUNK_DUPLICATE)
end

-- Every geometry class is pinned to the audited HGSS shape
-- (18 dialogue frame tiles, 18 signpost frame tiles, 24 wayfinding tiles),
-- not merely internally consistent. The tamper rewrites the whole class to
-- the wrong count: corrupting one dialogue/wayfinding member alone would be
-- caught by the cross-member consistency checks and would mask the
-- class-wide wrong geometry the renderer cannot consume.
local function compileWithTileCounts(geometry)
  local romFs, sha1, hashLua = fixture({
    tamper = function(alias, members)
      if alias == "dialogue_frames" and geometry.dialogueTiles then
        for i = 1, 20 do
          members[2 + i] = lz10Wrap(charData(geometry.dialogueTiles))
        end
      elseif alias == "signpost_graphics" then
        if geometry.signpostTiles then
          members[1] = charData(geometry.signpostTiles)
        end
        if geometry.wayfindingTiles then
          for memberId = 2, 0x35 do
            members[memberId + 1] = charData(geometry.wayfindingTiles, memberId % 16)
          end
        end
      end
      return members
    end,
  })
  return compileWithTestConfig(romFs, sha1, hashLua)
end

function T.dialogue_frame_tile_counts_must_be_exactly_eighteen()
  for _, tiles in ipairs({ 17, 19 }) do
    local bundle, err = compileWithTileCounts({ dialogueTiles = tiles })
    Assert.isNil(bundle, "a " .. tiles .. "-tile dialogue frame class must not compile")
    local typed = assert(err)
    Assert.equal(typed.code, FieldUiCompiler.ERROR.SOURCE_INVALID)
    Assert.equal(typed.context.frame, 0)
    Assert.equal(typed.context.member, 2)
    Assert.equal(typed.context.tiles, tiles)
  end
end

function T.signpost_frame_tile_counts_must_be_exactly_eighteen()
  for _, tiles in ipairs({ 17, 19 }) do
    local bundle, err = compileWithTileCounts({ signpostTiles = tiles })
    Assert.isNil(bundle, "a " .. tiles .. "-tile signpost frame must not compile")
    local typed = assert(err)
    Assert.equal(typed.code, FieldUiCompiler.ERROR.SOURCE_INVALID)
    Assert.equal(typed.context.member, 0)
    Assert.equal(typed.context.tiles, tiles)
  end
end

function T.wayfinding_tile_counts_must_be_exactly_twenty_four()
  for _, tiles in ipairs({ 23, 25 }) do
    local bundle, err = compileWithTileCounts({ wayfindingTiles = tiles })
    Assert.isNil(bundle, "a " .. tiles .. "-tile wayfinding class must not compile")
    local typed = assert(err)
    Assert.equal(typed.code, FieldUiCompiler.ERROR.SOURCE_INVALID)
    Assert.equal(typed.context.member, 0x21)
    Assert.equal(typed.context.tiles, tiles)
  end
end

function T.writer_commits_marker_last_and_reads_back()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldUiCacheWriter.write(cache, bundle)
  Assert.isTrue(FieldUiAssetCache.isReady(cache, bundle.marker))
  Assert.isFalse(FieldUiAssetCache.isReady(cache, bundle.marker .. "-stale"))
  local manifest = assert(cache:loadLua(FieldUiAssetCache.manifestPath()))
  Assert.equal(manifest.schema, FieldUiAssetCache.SCHEMA)
end

function T.failed_rebuild_preserves_the_previous_class()
  local romFs, sha1, hashLua = fixture()
  local first = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  FieldUiCacheWriter.write(cache, first)
  local originalWrite = backend.write
  backend.write = function(self, path, data)
    if path:find("start-menu.png", 1, true) then
      error("injected")
    end
    return originalWrite(self, path, data)
  end
  local second = assert(compileWithTestConfig(romFs, sha1, hashLua))
  second.marker = FieldUiAssetCache.marker(sha1, "new-dep-hash")
  Assert.throws(function()
    FieldUiCacheWriter.write(cache, second)
  end)
  Assert.isTrue(FieldUiAssetCache.isReady(cache, first.marker), "the previous class remains ready")
  Assert.equal(cache:read(FieldUiAssetCache.markerPath()), first.marker, "no new marker leaked")
  Assert.isNil(backend:getInfo("staging/heartgold/field-ui"), "the stage is cleaned on failure")
  backend.write = originalWrite
  FieldUiCacheWriter.write(cache, second)
  Assert.isTrue(FieldUiAssetCache.isReady(cache, second.marker), "a retry publishes the new class")
end

-- A stage-validation failure (the manifest fails strict validation after the
-- write) must surface as a typed failure and leave the previous class live.
function T.stage_validation_failure_is_typed_and_preserves_the_previous_class()
  local romFs, sha1, hashLua = fixture()
  local first = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldUiCacheWriter.write(cache, first)
  local second = assert(compileWithTestConfig(romFs, sha1, hashLua))
  second.manifest.startMenu.background.width = 999
  second.marker = FieldUiAssetCache.marker(sha1, "new-dep-hash")
  Assert.throws(function()
    FieldUiCacheWriter.write(cache, second)
  end)
  Assert.isTrue(FieldUiAssetCache.isReady(cache, first.marker), "the previous class remains ready")
  Assert.equal(cache:read(FieldUiAssetCache.markerPath()), first.marker)
end

-- A first publish rename failure (moving the live asset root aside) rolls
-- back and keeps the old class readable.
function T.first_publish_rename_failure_rolls_back()
  local romFs, sha1, hashLua = fixture()
  local first = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  FieldUiCacheWriter.write(cache, first)
  local originalReplace = backend.replace
  local calls = 0
  backend.replace = function(self, source, destination)
    calls = calls + 1
    if calls == 1 then
      error("injected rename failure")
    end
    return originalReplace(self, source, destination)
  end
  local second = assert(compileWithTestConfig(romFs, sha1, hashLua))
  second.marker = FieldUiAssetCache.marker(sha1, "new-dep-hash")
  Assert.throws(function()
    FieldUiCacheWriter.write(cache, second)
  end)
  backend.replace = originalReplace
  Assert.isTrue(FieldUiAssetCache.isReady(cache, first.marker), "the previous class remains ready after rollback")
  Assert.equal(cache:read(FieldUiAssetCache.markerPath()), first.marker)
end

-- A second publish rename failure (moving the data root into place after the
-- asset root landed) must also roll back the first move.
function T.second_publish_rename_failure_rolls_back_both_roots()
  local romFs, sha1, hashLua = fixture()
  local first = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  FieldUiCacheWriter.write(cache, first)
  local originalReplace = backend.replace
  local calls = 0
  backend.replace = function(self, source, destination)
    calls = calls + 1
    if calls == 2 then
      error("injected second rename failure")
    end
    return originalReplace(self, source, destination)
  end
  local second = assert(compileWithTestConfig(romFs, sha1, hashLua))
  second.marker = FieldUiAssetCache.marker(sha1, "new-dep-hash")
  Assert.throws(function()
    FieldUiCacheWriter.write(cache, second)
  end)
  backend.replace = originalReplace
  Assert.isTrue(FieldUiAssetCache.isReady(cache, first.marker), "the previous class remains ready after rollback")
  Assert.equal(cache:read(FieldUiAssetCache.markerPath()), first.marker)
end

function T.malformed_source_members_are_typed()
  local romFs, sha1, hashLua = fixture()
  romFs.openNarc = function(_, alias)
    local Narc = require("libs.nds.src.nitro.Narc")
    if alias == "start_menu" then
      -- A NARC whose background char member is not a G2D resource at all.
      local data = romFs.read(romFs, 10)
      -- keep the other members from the real fixture narc by splicing: the
      -- simplest deterministic corruption is replacing member 12 only.
      local real = assert(Narc.open(data, "start_menu"))
      local junk = {}
      for id = 0, real:memberCount() - 1 do
        local bytes = real:readMember(id)
        if id == 12 then
          bytes = "junk-member"
        end
        junk[#junk + 1] = bytes
      end
      return assert(Narc.open(narc(junk), "start_menu"))
    end
    return assert(
      Narc.open(
        romFs.read(
          romFs,
          ({ start_menu = 10, dialogue_frames = 11, signpost_graphics = 12, trainer_card_graphics = 13 })[alias]
        ),
        alias
      )
    )
  end
  local bundle, err = compileWithTestConfig(romFs, sha1, hashLua)
  Assert.isNil(bundle)
  Assert.isTrue(Errors.is(err))
end

-- RGB555 decoder integration: G2dDecoder correctly decodes palette colors using
-- the Nintendo DS RGB555 channel layout (red 0..4, green 5..9, blue 10..14).
-- The fixture palette16() uses values that would expose a red/blue swap.
-- A correct decoder produces the expected 8-bit RGBA; a swapped decoder
-- produces inverted R and B values.
function T.g2d_palette_decodes_rgb555_with_correct_channel_order()
  local function expand5(value)
    return math.floor((value * 255 + 15) / 31)
  end

  -- Build a fixture with a test palette containing known RGB555 values.
  -- colors[1] is unused padding: pixel value 0 is the reserved transparent
  -- slot and a 4bpp pixel value v otherwise selects the decoded bank's entry
  -- v, i.e. colors[v+1] in this 1-based array.
  -- Pair 0: r=0x1F (31, red max), g=0x00 (0), b=0x00 (0) -> pure red
  -- Pair 1: r=0x00 (0), g=0x1F (31), b=0x00 (0) -> pure green
  -- Pair 2: r=0x00 (0), g=0x00 (0), b=0x1F (31) -> pure blue
  -- Pair 3: r=0x1F (31), g=0x14 (20), b=0x00 (0) -> amber/gold (HGSS signpost)
  local testColors = {
    0x0000, -- padding: never referenced (value 0 is transparent)
    0x001F, -- red: r5=31, g5=0, b5=0
    0x03E0, -- green: r5=0, g5=31, b5=0
    0x7C00, -- blue: r5=0, g5=0, b5=31
    0x1F + (0x14 * 32), -- amber: r5=31, g5=20, b5=0
  }

  -- The background char's default tile t carries pixel value (t % 15) + 1, so
  -- tiles 0..3 carry values 1..4 -> colors[2..5]. Point screen columns 0..3
  -- at those tiles so each probed pixel samples a distinct test color; every
  -- other screen position stays tile 0.
  local entries = {}
  for i = 1, 768 do
    entries[i] = 0
  end
  for tile = 0, 3 do
    entries[tile + 1] = tile
  end

  local romFs, sha1, hashLua = fixture({
    bgPalette = testColors,
    tamper = function(alias, members)
      if alias == "start_menu" then
        members[14] = lz10Wrap(screenData(entries))
      end
      return members
    end,
  })

  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local manifest = bundle.manifest

  -- The manifest's start menu background palette comes from G2dDecoder
  -- applied to the test palette. Verify the decoded values are correct.
  local expectedColors = {
    { r = 255, g = 0, b = 0 }, -- red
    { r = 0, g = 255, b = 0 }, -- green
    { r = 0, g = 0, b = 255 }, -- blue
    { r = 255, g = expand5(20), b = 0 }, -- amber
  }

  -- The background palette was compiled through G2dDecoder. Extract it from
  -- the start menu asset to validate the color expansion.
  local bgAssetPath = manifest.assets[FieldUiAssetCache.ASSET.START_MENU_BACKGROUND].image
  local bgBytes = assert(bundle.assets[bgAssetPath])
  local width, _, rgba = PngReader.rgba(bgBytes)

  for tileIndex, expected in ipairs(expectedColors) do
    local pixelX = (tileIndex - 1) * 8
    local r, g, b, a = PngReader.pixel(rgba, width, pixelX, 0)
    Assert.equal(r, expected.r, "palette " .. tileIndex .. " red channel")
    Assert.equal(g, expected.g, "palette " .. tileIndex .. " green channel")
    Assert.equal(b, expected.b, "palette " .. tileIndex .. " blue channel")
    Assert.equal(a, 255, "palette " .. tileIndex .. " alpha")
  end
end

return { tests = T }
