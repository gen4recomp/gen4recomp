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
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local FieldUiFixture = require("tests.support.FieldUiFixture")

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
local function charData(tiles, base, depth)
  depth = depth or 3
  local tileBytes = depth == 3 and 32 or 64
  local payload = u16(8) .. u16(0x20) .. u32(depth) .. u16(0) .. u16(0) .. u32(0) .. u32(tiles * tileBytes) .. u32(0x18)
  local body = {}
  for t = 0, tiles - 1 do
    body[#body + 1] = string.rep(string.char((((t + (base or 0)) % 15) + 1) * 0x11), tileBytes)
  end
  return container("RGCN", { block("CHAR", payload .. table.concat(body)) })
end

local function charDataWithTiles(tileBytes)
  local payload = u16(8) .. u16(0x20) .. u32(3) .. u16(0) .. u16(0) .. u32(0) .. u32(#tileBytes * 32) .. u32(0x18)
  return container("RGCN", { block("CHAR", payload .. table.concat(tileBytes)) })
end

local function screenDataWH(width, height, entries)
  local body = {}
  for _, e in ipairs(entries) do
    body[#body + 1] = u16(e)
  end
  return container(
    "RCSN",
    { block("SCRN", u16(width) .. u16(height) .. u32(0) .. u32(#entries * 2) .. table.concat(body)) }
  )
end

local function screenData(entries)
  local body = {}
  for _, e in ipairs(entries) do
    body[#body + 1] = u16(e)
  end
  return screenDataWH(256, 192, entries)
end

-- A full 32x24-tile screen filled with one entry value.
local function fullScreen(entry)
  local entries = {}
  for i = 1, 768 do
    entries[i] = entry
  end
  return screenData(entries)
end

-- The synthetic naming archive: palette 0, the shared char bank 2 (tile 0
-- left blank so page holes stay transparent), the opaque base screen 4, and
-- the three page screens 6/7/8 (each page's first tile references blank tile
-- 0, every other tile its own page tile). Member 5 is present but unread,
-- proving the normal path never requires it.
local function namingScreenData(width, height, tile)
  local entries = {}
  local count = width / 8 * (height / 8)
  for i = 1, count do
    entries[i] = tile
  end
  entries[1] = 0
  return screenDataWH(width, height, entries)
end

local function namingCharData()
  local tiles = { string.rep("\0", 32) }
  for t = 1, 7 do
    tiles[#tiles + 1] = string.rep(string.char((((t - 1) % 15) + 1) * 0x11), 32)
  end
  return charDataWithTiles(tiles)
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

-- The two-row prompt palette fixture: bank 0 carries the shared 16-color
-- ramp while bank 1 uses a distinct family, so a state rendered through
-- the wrong bank is a visibly wrong color instead of a coincidentally
-- matching one.
local function promptPaletteData()
  local colors = {}
  for i = 1, 16 do
    colors[i] = i * 0x39B
  end
  for i = 17, 32 do
    colors[i] = 0x4000 + (i - 16) * 0x123
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

-- The Start Menu SUB palette fixture: five 16-color banks so label bank 4
-- (colors 64..79) resolves the label roles. The first four banks repeat
-- the shared 64-color pattern, so SUB chrome pixels compiled through the
-- lower banks are unchanged; bank 4 uses a distinct family so a bank
-- mix-up renders visibly wrong colors instead of coincidentally matching.
local function subPaletteData()
  local colors = {}
  for i = 1, 16 do
    colors[i] = i * 0x39B
  end
  for i = 17, 64 do
    colors[i] = ((i - 1) % 16 + 1) * 0x39B
  end
  for i = 65, 80 do
    colors[i] = 0x4000 + (i - 64) * 0x123
  end
  return paletteData(colors)
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
-- main triple (char 12, screen 13, palette 15) and cursor (palette 61, cell
-- 62, anim 63, char 64), the start menu icon bank (eleven 20-tile sprite
-- chars 18/21/24/27/30/33/36/39/42/45/48, shared cell 16, anim 17, and OBJ
-- palette image 14), the start menu SUB set (palette 7, char 8 of 192 tiles,
-- 256x256 screen 9), and the card front. The naming archive carries palette
-- 0, char 2, base 4, pages 6/7/8, plus the normal OBJ stack (palette 1 with
-- nine banks, char 10, cell 12, anim 14) installed by namingObjMembers.
-- Palettes carry enough colors for test
-- source types (4 types * 16 colors = 64 colors) so every tile value and
-- palette bank the fixture chars emit is covered. `opts` allows per-test
-- source tampering: cursor OBJ geometry, the background screen entry, the
-- background palette colors, and a whole-member tamper hook.
--
-- A multi-cell OBJ bank for the naming-screen fixture: each entry is one
-- cell carrying its own object list, with per-cell object offsets laid out
-- exactly like the single-cell helper above.
local function cellBank(cellObjs)
  local meta, attr = {}, {}
  local offset = 0
  for _, objs in ipairs(cellObjs) do
    meta[#meta + 1] = u16(#objs) .. u16(0) .. u32(offset)
    offset = offset + #objs * 6
  end
  for _, objs in ipairs(cellObjs) do
    for _, o in ipairs(objs) do
      attr[#attr + 1] = u16((o.y % 256) + (o.shape or 0) * 16384)
        .. u16((o.x % 512) + (o.flipH and 4096 or 0) + (o.flipV and 8192 or 0) + (o.size or 0) * 16384)
        .. u16(o.tile + o.pal * 4096)
    end
  end
  return container("RECN", {
    block(
      "CEBK",
      u16(#cellObjs)
        .. u16(0)
        .. u32(0x18)
        .. u32(0)
        .. string.rep("\0", 12)
        .. table.concat(meta)
        .. table.concat(attr)
    ),
  })
end

-- A multi-animation bank: animation a drives one frame selecting cell
-- animCells[a]. Mirrors the single-animation helper's header layout.
local function animBank(animCells)
  local count = #animCells
  local anims, frames, data = {}, {}, {}
  for a, cell in ipairs(animCells) do
    anims[#anims + 1] = u32(1) .. u16(0) .. u16(1) .. u32(1) .. u32((a - 1) * 8)
    frames[#frames + 1] = u32((a - 1) * 2) .. u16(3) .. u16(0)
    data[#data + 1] = u16(cell)
  end
  local animsOffset = 0x18
  local framesOffset = animsOffset + 16 * count
  local dataOffset = framesOffset + 8 * count
  return container("RNAN", {
    block(
      "ABNK",
      u16(count)
        .. u16(count)
        .. u32(animsOffset)
        .. u32(framesOffset)
        .. u32(dataOffset)
        .. string.rep("\0", 8)
        .. table.concat(anims)
        .. table.concat(frames)
        .. table.concat(data)
    ),
  })
end

-- Nine distinct 16-color OBJ palette banks: bank b slot s decodes word
-- b + s*32, so no two (bank, slot) pairs share a color and a bank mix-up is
-- always visible. Nine banks also prove the palette-count argument is a
-- count: a producer that mistakes the count for bank 9 would read past these
-- 144 colors into a typed source error.
local function nineBankPalette()
  local colors = {}
  for bank = 0, 8 do
    for slot = 0, 15 do
      colors[bank * 16 + slot + 1] = bank + slot * 32
    end
  end
  return paletteData(colors)
end

-- The normal naming OBJ stack in producer-side member numbers (this is the
-- romdump-side test): char 10, palette 1, cell 12, anim 14. Fifty cells and
-- animations cover the transcribed semantic animation table (subjects at 48
-- and 49); cell i references tile i % 16 of the 16-tile char through palette
-- bank i % 9, so every bank the nine-bank palette carries is exercised and
-- neighboring roles render distinct art.
local function namingObjMembers(members)
  members[2] = nineBankPalette()
  members[11] = charData(16, 3)
  local cells = {}
  local animCells = {}
  for index = 0, 49 do
    cells[index + 1] = { { x = 0, y = 0, tile = index % 16, pal = index % 9 } }
    animCells[index + 1] = index
  end
  members[13] = cellBank(cells)
  members[15] = animBank(animCells)
  return members
end

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
  for _, memberId in ipairs({ 18, 21, 24, 27, 30, 33, 36, 39, 42, 45, 48 }) do
    startMenuMembers[memberId + 1] = lz10Wrap(charData(20, memberId % 16))
  end
  startMenuMembers[15] = lz10Wrap(palette16())
  startMenuMembers[17] = lz10Wrap(cellData({ { x = 0, y = 0, tile = 0, pal = 0 } }))
  startMenuMembers[18] = lz10Wrap(animData({ { duration = 3, cell = 0 }, { duration = 3, cell = 0 } }))
  startMenuMembers[8] = lz10Wrap(subPaletteData())
  startMenuMembers[9] = lz10Wrap(charData(192))
  do
    local entries = {}
    for i = 1, 1024 do
      entries[i] = 0
    end
    startMenuMembers[10] = lz10Wrap(screenDataWH(256, 256, entries))
  end
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

  local namein = {}
  for i = 1, 15 do
    namein[i] = string.rep("\0", 4)
  end
  namein[1] = palette16()
  namein[3] = namingCharData()
  namein[5] = lz10Wrap(fullScreen(1))
  namein[7] = lz10Wrap(namingScreenData(256, 112, 2))
  namein[8] = lz10Wrap(namingScreenData(256, 112, 3))
  namein[9] = lz10Wrap(namingScreenData(256, 112, 4))
  namingObjMembers(namein)

  -- The synthetic two-row prompt archive: palette member 0 (two 16-color
  -- banks), the shared char bank member 1, and one 48x32 (6x4-tile) screen
  -- per button state (members 2..5), each screen referencing its own tile
  -- so the four states decode to distinct pixels.
  local prompt = {}
  for i = 1, 6 do
    prompt[i] = string.rep("\0", 4)
  end
  prompt[1] = promptPaletteData()
  prompt[2] = charData(8)
  for member = 2, 5 do
    local entries = {}
    for i = 1, 24 do
      entries[i] = member
    end
    prompt[member + 1] = screenDataWH(48, 32, entries)
  end

  local function narcFile(alias)
    local members
    if alias == "start_menu" then
      members = startMenu
    elseif alias == "dialogue_frames" then
      members = {}
      for i = 1, 47 do
        members[i] = string.rep("\0", 4)
      end
      members[1] = lz10Wrap(opts.standardFrame or charData(9, 6))
      for i = 1, 20 do
        members[2 + i] = lz10Wrap(charData(18))
      end
      members[26] = lz10Wrap(paletteOr16(opts.standardPalette))
      for i = 1, 20 do
        members[26 + i] = lz10Wrap(paletteOr16(opts.framePalette))
      end
      members[0x16 + 1] = lz10Wrap(opts.cursorChar or charData(12))
    elseif alias == "signpost_graphics" then
      members = signposts
    elseif alias == "naming_screen" then
      members = namein
    elseif alias == "touch_subwindow" then
      members = prompt
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
    naming_screen = {
      fileId = 14,
      narcId = 31,
      path = "a/0/3/1",
      symbol = "NARC_data_namein",
      alias = "naming_screen",
    },
    touch_subwindow = {
      fileId = 15,
      narcId = 99,
      path = "a/9/9/9",
      symbol = "NARC_a_9_9_9",
      alias = "touch_subwindow",
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
      if fileId == 14 then
        return narcFile("naming_screen")
      end
      if fileId == 15 then
        return narcFile("touch_subwindow")
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
  Assert.isNil(bundle.manifest.startMenu.slots, "the normal selector publishes no synthetic slot grid")
  local assetCount = 0
  for _ in pairs(bundle.assets) do
    assetCount = assetCount + 1
  end
  -- Eleven base assets plus the three start-menu icon-contract images (the
  -- shared icon atlas, the palette record, SUB chrome) plus the sixteen
  -- naming OBJ visuals (six controls, keyboard cursor, five home cursor
  -- variants, two entry slots, two player subjects) plus the six cursor
  -- pulse-mask atlases, plus the single dialogue frame strip beside the
  -- continuation cursor, plus the four two-row prompt button states.
  Assert.equal(assetCount, 40)
  for path, bytes in pairs(bundle.assets) do
    Assert.isTrue(path:find("^assets/generated/field/ui/") ~= nil)
    Assert.isTrue(#bytes > 0)
  end
  Assert.equal(bundle.marker, "field-ui-cache-v1:rom-sha:dependency-sha")
end

-- The normal naming chrome compiles from the producer-selected members: one
-- opaque 256x192 base and three 256x112 page overlays keyed upper, lower,
-- and symbols at the canonical y=80 placement, every image indexed by its
-- semantic asset id with PNG bytes matching the declared dimensions.
function T.naming_chrome_compiles_the_normal_base_and_pages()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local naming = assert(bundle.manifest.namingScreen, "the compiled field UI must publish normal naming chrome")
  Assert.deepEqual(naming.placement, { x = 11, y = 80, width = 256, height = 112 })
  Assert.equal(naming.base.asset, FieldUiAssetCache.ASSET.NAMING_SCREEN_BASE)
  Assert.equal(naming.base.width, 256)
  Assert.equal(naming.base.height, 192)
  local expectedPages = {
    upper = FieldUiAssetCache.ASSET.NAMING_SCREEN_PAGE_UPPER,
    lower = FieldUiAssetCache.ASSET.NAMING_SCREEN_PAGE_LOWER,
    symbols = FieldUiAssetCache.ASSET.NAMING_SCREEN_PAGE_SYMBOLS,
  }
  local pageCount = 0
  for key, page in pairs(naming.pages) do
    Assert.equal(page.asset, expectedPages[key], "page " .. tostring(key) .. " carries its semantic asset id")
    Assert.equal(page.width, 256, "page " .. tostring(key) .. " width")
    Assert.equal(page.height, 112, "page " .. tostring(key) .. " height")
    pageCount = pageCount + 1
  end
  Assert.equal(pageCount, 3, "normal naming carries exactly three pages")
  for key, assetId in pairs(expectedPages) do
    local entry = assert(bundle.manifest.assets[assetId], "the " .. key .. " page asset is indexed")
    local width, height = PngReader.rgba(assert(bundle.assets[entry.image]))
    Assert.equal(width, entry.width, key .. " png width")
    Assert.equal(height, entry.height, key .. " png height")
  end
  local baseEntry = assert(bundle.manifest.assets[naming.base.asset], "the naming base asset is indexed")
  local baseWidth, baseHeight = PngReader.rgba(assert(bundle.assets[baseEntry.image]))
  Assert.equal(baseWidth, 256)
  Assert.equal(baseHeight, 192)
end

-- The base renders palette-zero as opaque source art while every page keeps
-- a transparent hole where its screen references the blank tile, so the base
-- shows through at runtime.
function T.naming_base_is_opaque_while_pages_keep_transparency_holes()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local naming = assert(bundle.manifest.namingScreen)
  local function transparentPixels(entry)
    local width, _, rgba = PngReader.rgba(assert(bundle.assets[assert(bundle.manifest.assets[entry.asset]).image]))
    local transparent, total = 0, math.floor(#rgba / 4)
    for index = 0, total - 1 do
      local _, _, _, a = PngReader.pixel(rgba, width, index % width, math.floor(index / width))
      if a == 0 then
        transparent = transparent + 1
      end
    end
    return transparent, total
  end
  local baseTransparent = transparentPixels(naming.base)
  Assert.equal(baseTransparent, 0, "the base is fully opaque source art")
  for _, key in ipairs({ "upper", "lower", "symbols" }) do
    local transparent, total = transparentPixels(naming.pages[key])
    Assert.isTrue(transparent > 0, "the " .. key .. " overlay keeps transparent source-zero holes")
    Assert.isTrue(transparent < total, "the " .. key .. " overlay still carries opaque artwork")
  end
end

-- The producer fingerprint pins exactly the normal naming members: palette
-- 0, char 2, base 4, pages 6/7/8, and the normal OBJ stack (palette 1, char
-- 10, cell 12, anim 14). Members 5, 9, 17, and 18 never appear, so the normal
-- path cannot accidentally depend on the special numpad page or the unmapped
-- members.
function T.naming_dependencies_pin_exactly_the_normal_members()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local names = {}
  for _, dep in ipairs(bundle.dependencies) do
    names[dep.name] = true
  end
  for _, member in ipairs({ 0, 1, 2, 4, 6, 7, 8, 10, 12, 14 }) do
    Assert.isTrue(
      names["naming_screen:member:" .. member] or names["naming_screen:palette:" .. member],
      "the fingerprint pins naming member " .. member
    )
  end
  for _, excluded in ipairs({ 5, 9, 17, 18 }) do
    Assert.isNil(names["naming_screen:member:" .. excluded], "member " .. excluded .. " is not fingerprinted")
    Assert.isNil(names["naming_screen:palette:" .. excluded], "member " .. excluded .. " is not fingerprinted")
  end
end

-- The palette-count argument is a count of nine banks, never bank 9: the OBJ
-- palette member decodes to exactly nine 16-color banks, the highest OAM bank
-- (8) resolves inside them, and a cell reaching past the ninth bank is a
-- typed source defect instead of a silent miscolor.
function T.naming_obj_palette_count_is_nine_banks_not_bank_nine()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local naming = assert(bundle.manifest.namingScreen, "the compiled field UI must publish normal naming chrome")
  Assert.notNil(naming.playerSubjects.female, "bank 8 (the highest OAM bank) resolves inside the nine banks")
  local pastBankCells = {}
  for index = 0, 49 do
    pastBankCells[index + 1] = { { x = 0, y = 0, tile = index % 16, pal = index == 3 and 9 or index % 9 } }
  end
  local pastBankAnimCells = {}
  for index = 0, 49 do
    pastBankAnimCells[index + 1] = index
  end
  local overFs, overSha1, overHashLua = fixture({
    tamper = function(alias, members)
      if alias == "naming_screen" then
        namingObjMembers(members)
        members[13] = cellBank(pastBankCells)
        members[15] = animBank(pastBankAnimCells)
      end
      return members
    end,
  })
  local overBundle, overErr = compileWithTestConfig(overFs, overSha1, overHashLua)
  Assert.isNil(overBundle, "an OAM object past the ninth bank must not compile")
  Assert.equal(assert(overErr).code, FieldUiCompiler.ERROR.SOURCE_INVALID)
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

-- The main chrome is source art with holes, not an opaque backdrop: the
-- retail MAIN BG carries entry chrome only in the bottom panel band
-- (tile rows 17-23, from px 136), so source-zero pixels above it must stay
-- transparent in the generated main-chrome image.
function T.start_menu_source_zero_pixels_compile_transparent()
  local romFs, sha1, hashLua = fixture({
    tamper = function(alias, members)
      if alias == "start_menu" then
        members[13] = lz10Wrap(charDataWithTiles({ string.rep("\0", 32) }))
      end
      return members
    end,
  })
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local path = bundle.manifest.assets[FieldUiAssetCache.ASSET.START_MENU_BACKGROUND].image
  local width, _, rgba = PngReader.rgba(bundle.assets[path])
  local _, _, _, alpha = PngReader.pixel(rgba, width, 0, 0)
  Assert.equal(alpha, 0, "source-zero pixels must stay transparent in the generated main chrome")
end

-- The retail start-menu icon bank for the icon-sprite path: eleven
-- 20-tile sprite chars, the shared icon cell/anim banks, and the shared OBJ
-- palette image. Member numbers below are the producer-side selection (this
-- is the romdump-side test); the manifest itself must carry them only as
-- the source-independent 13-row icon table the runtime consumes.
local ICON_CHAR_MEMBERS = { 18, 21, 24, 27, 30, 33, 36, 39, 42, 45, 48 }

local function withIconBank(members)
  for _, memberId in ipairs(ICON_CHAR_MEMBERS) do
    members[memberId + 1] = lz10Wrap(charData(20, memberId % 16))
  end
  -- The icon palette carries distinct banks (bank b slot s decodes b + s*32,
  -- so no two banks share a color): the OAM bank proves per-object palette
  -- selection while the selection bank proves the selected-state render.
  members[15] = lz10Wrap(paletteData(distinctSignpostPalette(4)))
  members[17] = lz10Wrap(cellData({ { x = 0, y = 0, tile = 0, pal = 0 } }))
  members[18] = lz10Wrap(animData({ { duration = 3, cell = 0 }, { duration = 3, cell = 0 } }))
  return members
end

local function fixtureWithIconBank()
  return fixture({
    tamper = function(alias, members)
      if alias == "start_menu" then
        return withIconBank(members)
      end
      return members
    end,
  })
end

-- The compiled manifest publishes the thirteen retail icon rows as data:
-- sprite rows carry art, rows 9-10 are text-only, row 11 is the external
-- poke-icon path. The per-icon cell/anim members (19/20...) have no traced
-- retail consumer and stay out of the contract.
function T.start_menu_icon_table_compiles_the_retail_icon_bank()
  local romFs, sha1, hashLua = fixtureWithIconBank()
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local startMenu = assert(bundle.manifest.startMenu, "the manifest must carry the start menu section")
  local iconTable = assert(startMenu.iconTable, "the start menu section must carry the retail icon table")
  Assert.equal(#iconTable, 13, "the icon table carries all thirteen retail rows")
  for _, index in ipairs({ 1, 2, 3, 4, 5, 6, 7, 8, 12, 13 }) do
    Assert.equal((iconTable[index] or {}).art, "sprite", "icon row " .. index .. " carries sprite art")
  end
  Assert.equal((iconTable[9] or {}).art, "text", "icon row 9 is text-only")
  Assert.equal((iconTable[10] or {}).art, "text", "icon row 10 is text-only")
  Assert.equal((iconTable[11] or {}).art, "poke_icon", "icon row 11 is the external poke-icon path")
end

-- The seven retail context rows map menu contexts to icon indices as data
-- (Lua index = retail row + 1, `false` marks the none holes). Only the
-- normal row's assignment is pinned; the remaining row-to-context names
-- stay open until the init-arg trace lands.
function T.start_menu_context_rows_compile_as_retail_data()
  local romFs, sha1, hashLua = fixtureWithIconBank()
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local startMenu = assert(bundle.manifest.startMenu, "the manifest must carry the start menu section")
  local contexts = assert(startMenu.contexts, "the start menu section must carry the retail context rows")
  Assert.equal(#contexts, 7, "the contract carries all seven retail context rows")
  Assert.deepEqual(contexts[1], { 0, 1, 2, 3, 4, 5, 6 }, "the normal context maps icons 0-6")
  local seen = {}
  for _, row in ipairs(contexts) do
    Assert.equal(#row, 7, "every context row maps one icon per sprite slot")
    for _, icon in ipairs(row) do
      if icon ~= false then
        seen[icon] = true
      end
    end
  end
  Assert.isTrue(seen[9], "a context row addresses text-only row 9")
  Assert.isTrue(seen[10], "a context row addresses the poke-icon row 10")
end

-- Every icon row carries its label-bank id; the trainer-card row is the
-- player-name placeholder the runtime expands per save, never baked text.
function T.start_menu_icon_rows_carry_label_ids_with_the_trainer_card_placeholder()
  local romFs, sha1, hashLua = fixtureWithIconBank()
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local startMenu = assert(bundle.manifest.startMenu, "the manifest must carry the start menu section")
  local iconTable = assert(startMenu.iconTable, "the start menu section must carry the retail icon table")
  local function row(index)
    return assert(iconTable[index], "icon row " .. index .. " must exist")
  end
  Assert.equal(row(1).label, 0, "pokedex labels from bank id 0")
  Assert.equal(row(4).label, 14, "pokegear labels from bank id 14")
  Assert.equal(row(5).label, 3, "the trainer-card row references the name placeholder id")
  Assert.equal(row(5).labelKind, "player_name", "the trainer-card label expands the live player name")
  Assert.equal(row(8).label, 8, "retire labels from bank id 8")
  Assert.equal(row(9).label, 32, "text-only rows label from bank id 32")
  Assert.equal(row(12).label, 34, "union rows label from bank ids 34/35")
  Assert.equal(row(13).label, 35)
  local variants = assert(row(3).variants, "the bag row carries its gender-conditional variant")
  Assert.isNil(variants.default, "the bag row carries no default variant: its own visual is the default art")
  local female = assert(variants.female, "the bag row carries the female art as a first-class variant")
  Assert.notNil(female.normal, "the female variant carries the normal visual record")
  Assert.notNil(female.selected, "the female variant carries the selected visual record")
end

-- The SUB chrome set compiles alongside the main triple: the background set
-- plus the entry-window grid the runtime places labels through. Member
-- selection is zero-based (index = member id + 1, like the base fixture):
-- char 8, palette 7, screen 9.
function T.start_menu_sub_chrome_compiles_the_window_grid()
  local romFs, sha1, hashLua = fixture({
    tamper = function(alias, members)
      if alias == "start_menu" then
        withIconBank(members)
        members[8] = lz10Wrap(subPaletteData())
        members[9] = lz10Wrap(charData(192))
        local entries = {}
        for i = 1, 1024 do
          entries[i] = 0
        end
        members[10] = lz10Wrap(screenDataWH(256, 256, entries))
      end
      return members
    end,
  })
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local startMenu = assert(bundle.manifest.startMenu, "the manifest must carry the start menu section")
  local chrome = assert(startMenu.chrome, "the start menu section must carry its chrome")
  Assert.notNil(chrome.main, "the chrome carries the transparent main panel")
  Assert.notNil(chrome.sub, "the chrome carries the sub background set")
  local interactive =
    assert(startMenu.interactive, "the start menu section must carry its interactive position records")
  local positionCount = 0
  for _ in pairs(interactive.positions) do
    positionCount = positionCount + 1
  end
  Assert.equal(positionCount, 7, "seven normal positions carry one label window each")
  for position = 0, 6 do
    Assert.notNil(
      interactive.positions[position] and interactive.positions[position].labelWindow,
      "normal position " .. position .. " carries its own label window"
    )
  end
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
  scan(bundle.manifest.namingScreen, "namingScreen")
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

function T.standard_yes_no_frame_is_published_after_user_rows()
  local standardPalette = { 0, 0x001F, 0x03E0, 0x7C00 }
  for i = 5, 16 do
    standardPalette[i] = i * 0x39B
  end
  local romFs, sha1, hashLua = fixture({ standardPalette = standardPalette })
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local frames = bundle.manifest.dialogueFrames
  local standard = assert(frames.standardFrame)
  Assert.equal(frames.count, 20, "the fixed frame does not change selectable user-frame count")
  Assert.equal(frames.frameTiles[0].y, 0, "user frame 0 keeps its row")
  Assert.equal(standard.frameTiles.x, 0)
  Assert.equal(standard.frameTiles.y, frames.count * 8, "the fixed frame follows all user rows")
  Assert.equal(standard.frameTiles.width, 72)
  Assert.equal(standard.frameTiles.height, 8)
  Assert.isNil(standard.member, "source member identity is not published")

  local path = bundle.manifest.assets[FieldUiAssetCache.ASSET.DIALOGUE_FRAME_TILES].image
  local width, height, rgba = PngReader.rgba(bundle.assets[path])
  Assert.equal(width, 144)
  Assert.equal(height, (frames.count + 1) * 8)
  local userPixel = { PngReader.pixel(rgba, width, 0, frames.frameTiles[0].y) }
  local standardPixel = { PngReader.pixel(rgba, width, 0, standard.frameTiles.y) }
  Assert.isTrue(
    userPixel[1] ~= standardPixel[1] or userPixel[2] ~= standardPixel[2],
    "the fixed row has distinct pixels"
  )
  Assert.equal(standard.palette[0].r, 0, "palette slot 0 is included")
  Assert.equal(standard.palette[1].r, 255, "palette bytes decode independently from user frame 0")
  Assert.equal(standard.palette[1].g, 0)
end

function T.standard_yes_no_frame_source_defects_are_rejected()
  local cases = {
    { opts = { standardFrame = charData(8, 6) }, tiles = 8 },
    { opts = { standardFrame = charData(10, 6) }, tiles = 10 },
  }
  for _, case in ipairs(cases) do
    local romFs, sha1, hashLua = fixture(case.opts)
    local bundle, err = compileWithTestConfig(romFs, sha1, hashLua)
    Assert.isNil(bundle, "a non-18-tile standard frame must fail")
    local typed = assert(err)
    Assert.equal(typed.code, FieldUiCompiler.ERROR.SOURCE_INVALID)
    Assert.equal(typed.context.member, 0)
    Assert.equal(typed.context.tiles, case.tiles)
  end

  local romFs8bpp, sha18bpp, hashLua8bpp = fixture({ standardFrame = charData(9, 6, 4) })
  local bundle8bpp, err8bpp = compileWithTestConfig(romFs8bpp, sha18bpp, hashLua8bpp)
  Assert.isNil(bundle8bpp, "the standard source frame must use 4bpp tiles")
  Assert.equal(assert(err8bpp).code, FieldUiCompiler.ERROR.SOURCE_INVALID)
  Assert.equal(assert(err8bpp).context.member, 0)

  local romFs, sha1, hashLua = fixture({ standardPalette = { 0x7FFF } })
  local bundle, err = compileWithTestConfig(romFs, sha1, hashLua)
  Assert.isNil(bundle, "a short standard palette must fail")
  Assert.equal(assert(err).code, FieldUiCompiler.ERROR.SOURCE_INVALID)
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

-- The normal naming manifest keeps its proven base/page chrome and
-- additionally publishes the source text and OBJ geometry the reusable
-- renderer consumes. Member numbers below are the producer-side selection
-- (this is the romdump-side test); the manifest itself must carry them only
-- as source-independent anchors, steps, and origins.
function T.naming_manifest_publishes_source_text_and_object_geometry_beside_the_proven_chrome()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local naming = assert(bundle.manifest.namingScreen, "the compiled field UI must publish normal naming chrome")
  Assert.deepEqual(naming.placement, { x = 11, y = 80, width = 256, height = 112 })
  local pageCount = 0
  for _ in pairs(naming.pages) do
    pageCount = pageCount + 1
  end
  Assert.equal(pageCount, 3, "normal naming still carries exactly three pages")

  local text = assert(naming.text, "the compiled naming must publish its source text geometry")
  Assert.deepEqual(text.name, { x = 80, y = 24, advanceX = 12 })
  local keyboardCells =
    assert(text.keyboard and text.keyboard.cells, "the compiled naming must publish its five keyboard text rows")
  local rowCount = 0
  for _ in pairs(keyboardCells) do
    rowCount = rowCount + 1
  end
  Assert.equal(rowCount, 5, "the keyboard text carries five source rows")
  for row = 1, 5 do
    local cells = assert(keyboardCells[row], "keyboard text row " .. row .. " is required")
    local columnCount = 0
    for _ in pairs(cells) do
      columnCount = columnCount + 1
    end
    Assert.equal(columnCount, 13, "keyboard text row " .. row .. " carries thirteen cells")
    for column = 1, 13 do
      local cell = assert(cells[column], "keyboard text row " .. row .. " column " .. column .. " is required")
      Assert.equal(cell.width, 16, "keyboard text cells are the 16px source columns")
    end
    for column = 2, 13 do
      Assert.equal(cells[column].x - cells[column - 1].x, 16, "text row " .. row .. " advances one 16px column")
    end
  end
  for row = 2, 5 do
    Assert.isTrue(keyboardCells[row][1].y > keyboardCells[row - 1][1].y, "keyboard text rows run top to bottom")
  end

  Assert.equal(keyboardCells[1][1].x, 27, "the first keyboard cell rests at screen x 27")
  Assert.equal(keyboardCells[1][1].y, 92, "the first keyboard cell rests at screen y 92")

  local controls = assert(naming.controls, "the compiled naming must publish its source controls")
  Assert.deepEqual(controls.upper.anchor, { x = 26, y = 68 })
  Assert.deepEqual(controls.lower.anchor, { x = 58, y = 68 })
  Assert.deepEqual(controls.symbols.anchor, { x = 90, y = 68 })
  Assert.deepEqual(controls.back.anchor, { x = 158, y = 68 })
  Assert.deepEqual(controls.ok.anchor, { x = 198, y = 68 })
  Assert.deepEqual(controls.backing.anchor, { x = 22, y = 56 })

  local cursor = assert(naming.cursor, "the compiled naming must publish its source cursor")
  Assert.deepEqual(cursor.keyboard.origin, { x = 26, y = 91 })
  Assert.equal(cursor.keyboard.stepX, 16)
  Assert.equal(cursor.keyboard.stepY, 19)
  for _, id in ipairs({ "upper", "lower", "symbols", "back", "ok" }) do
    Assert.notNil(cursor.home and cursor.home[id], "the home cursor carries the " .. id .. " variant")
  end

  local slots = assert(naming.entrySlots, "the compiled naming must publish its entry slots")
  Assert.deepEqual(slots.origin, { x = 80, y = 39 })
  Assert.equal(slots.stepX, 12)
  Assert.notNil(slots.normal, "the entry slots carry the normal visual")
  Assert.notNil(slots.selected, "the entry slots carry the selected visual")

  local subjects = assert(naming.playerSubjects, "the compiled naming must publish its player subjects")
  Assert.deepEqual(subjects.male.anchor, { x = 24, y = 8 })
  Assert.deepEqual(subjects.female.anchor, { x = 24, y = 8 })
end

-- The naming OBJ visuals honor each OAM object's own palette bank: the
-- fixture palette carries nine distinct banks while its cells spread objects
-- across all nine banks, so every compiled sprite must resolve its own bank
-- and the male/female subjects must render distinct art.
function T.naming_object_visuals_honor_per_oam_palette_selection()
  local romFs, sha1, hashLua = fixture({
    tamper = function(alias, members)
      if alias == "naming_screen" then
        namingObjMembers(members)
      end
      return members
    end,
  })
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local naming = assert(bundle.manifest.namingScreen, "the compiled field UI must publish normal naming chrome")
  local records = {}
  for _, record in pairs(assert(naming.controls, "the compiled naming must publish its source controls")) do
    records[#records + 1] = record
  end
  local cursor = assert(naming.cursor, "the compiled naming must publish its source cursor")
  records[#records + 1] = cursor.keyboard
  for _, record in pairs(assert(cursor.home, "the home cursor carries per-control variants")) do
    records[#records + 1] = record
  end
  local slots = assert(naming.entrySlots, "the compiled naming must publish its entry slots")
  records[#records + 1] = slots.normal
  records[#records + 1] = slots.selected
  local subjects = assert(naming.playerSubjects, "the compiled naming must publish its player subjects")
  records[#records + 1] = subjects.male
  records[#records + 1] = subjects.female
  Assert.isTrue(#records >= 8, "the naming visuals cover controls, cursor, slots, and both subjects")
  local function imageBytes(record)
    local path = record.image
    if path == nil and type(record.asset) == "string" then
      local entry = assert(bundle.manifest.assets[record.asset], "the sprite asset is indexed: " .. record.asset)
      path = entry.image
    end
    local bytes = assert(bundle.assets[assert(path, "the sprite record names its image")])
    Assert.isTrue(#bytes > 0, "the sprite image carries generated pixels")
    return path, bytes
  end
  local function recordImages(record)
    if type(record.frames) ~= "table" then
      local _, bytes = imageBytes(record)
      return { bytes }
    end
    local images = {}
    local seen = {}
    for _, frame in ipairs(record.frames) do
      if not seen[frame.asset] then
        seen[frame.asset] = true
        local entry = assert(bundle.manifest.assets[frame.asset], "the sprite asset is indexed: " .. frame.asset)
        images[#images + 1] = assert(bundle.assets[entry.image])
      end
    end
    if record.pulseAsset ~= nil then
      local entry =
        assert(bundle.manifest.assets[record.pulseAsset], "the pulse asset is indexed: " .. record.pulseAsset)
      images[#images + 1] = assert(bundle.assets[entry.image])
    end
    return images
  end
  local opaquePixels = 0
  for _, record in ipairs(records) do
    for _, bytes in ipairs(recordImages(record)) do
      local width, _, rgba = PngReader.rgba(bytes)
      local total = math.floor(#rgba / 4)
      for index = 0, total - 1 do
        local _, _, _, a = PngReader.pixel(rgba, width, index % width, math.floor(index / width))
        if a ~= 0 then
          opaquePixels = opaquePixels + 1
          break
        end
      end
    end
    for key in pairs(record) do
      Assert.isFalse(
        key == "member" or key == "memberId" or key == "cell" or key == "anim" or key == "narcId" or key == "alias",
        "the sprite record must not leak source identities through '" .. tostring(key) .. "'"
      )
    end
  end
  Assert.isTrue(opaquePixels > 0, "the compiled naming visuals carry opaque source art")
  Assert.isTrue(
    recordImages(subjects.male)[1] ~= recordImages(subjects.female)[1],
    "the male and female subjects render distinct art"
  )
end

-- A multi-frame animation bank for the naming producer: animation 48 packs
-- three frames (durations 2/1/4, looping from frame 1) while every other
-- animation keeps one frame, so frame order, durations, mode, and loop
-- start are observable in the generated subject record.
local function multiFrameNamingAnim()
  local animCount = 50
  local specs = {}
  for index = 0, animCount - 1 do
    specs[index + 1] = { playMode = 1, loopStart = 0, frames = { { cell = index, duration = 3 } } }
  end
  specs[49] = {
    playMode = 2,
    loopStart = 1,
    frames = {
      { cell = 10, duration = 2 },
      { cell = 11, duration = 1 },
      { cell = 12, duration = 4 },
    },
  }
  local totalFrames = 0
  for _, spec in ipairs(specs) do
    totalFrames = totalFrames + #spec.frames
  end
  local animsOffset = 0x18
  local framesOffset = animsOffset + 16 * animCount
  local dataOffset = framesOffset + 8 * totalFrames
  local animEntries, frameEntries, dataEntries = {}, {}, {}
  local frameCursor, dataCursor = 0, 0
  for _, spec in ipairs(specs) do
    animEntries[#animEntries + 1] = u16(#spec.frames)
      .. u16(spec.loopStart)
      .. u32(0x00010000)
      .. u32(spec.playMode)
      .. u32(frameCursor * 8)
    for _, frame in ipairs(spec.frames) do
      frameEntries[#frameEntries + 1] = u32(dataCursor * 2) .. u16(frame.duration) .. u16(0)
      dataEntries[#dataEntries + 1] = u16(frame.cell)
      frameCursor = frameCursor + 1
      dataCursor = dataCursor + 1
    end
  end
  return container("RNAN", {
    block(
      "ABNK",
      u16(animCount)
        .. u16(totalFrames)
        .. u32(animsOffset)
        .. u32(framesOffset)
        .. u32(dataOffset)
        .. string.rep("\0", 8)
        .. table.concat(animEntries)
        .. table.concat(frameEntries)
        .. table.concat(dataEntries)
    ),
  })
end

-- Subject animations publish every decoded frame in source order with its
-- decoded duration, playback mode, and loop start, packed left to right in
-- one deterministic atlas.
function T.naming_subject_animations_pack_every_decoded_frame_in_order()
  local romFs, sha1, hashLua = fixture({
    tamper = function(alias, members)
      if alias == "naming_screen" then
        namingObjMembers(members)
        members[15] = multiFrameNamingAnim()
      end
      return members
    end,
  })
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local naming = assert(bundle.manifest.namingScreen)
  local male = assert(naming.playerSubjects.male)
  Assert.equal(male.playMode, "forward_loop")
  Assert.equal(male.loopStartFrameIdx, 1)
  Assert.equal(#male.frames, 3, "every decoded subject frame is represented once")
  local durations = {}
  for _, frame in ipairs(male.frames) do
    durations[#durations + 1] = frame.duration
  end
  Assert.deepEqual(durations, { 2, 1, 4 }, "frame durations follow the decoded source order")
  Assert.isNil(male.pulseAsset, "player subjects carry no pulse-mask role")
  local entry = assert(bundle.manifest.assets[male.frames[1].asset])
  local atlasWidth, atlasHeight = PngReader.rgba(assert(bundle.assets[entry.image]))
  Assert.equal(entry.width, atlasWidth)
  Assert.equal(entry.height, atlasHeight)
  local x = 0
  for index, frame in ipairs(male.frames) do
    Assert.equal(frame.asset, male.frames[1].asset, "subject frames share one packed atlas")
    Assert.equal(frame.rect.x, x, "frame " .. index .. " packs left to right")
    Assert.equal(frame.rect.y, 0)
    Assert.isNil(frame.pulseRect, "player subject frames carry no pulse rect")
    x = x + frame.rect.width
  end
  Assert.equal(atlasWidth, x, "the atlas is exactly the packed frame row")
  local female = assert(naming.playerSubjects.female)
  Assert.equal(#female.frames, 1, "untampered animations keep their single frame")
end

-- Cursor animations publish the same frame packing plus the entry-29
-- pulse-mask atlas whose rects match the normal frames in order and size,
-- with only marker pixels opaque.
function T.naming_cursor_masks_match_their_frames_and_hide_other_pixels()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local naming = assert(bundle.manifest.namingScreen)
  local keyboard = assert(naming.cursor.keyboard)
  Assert.isTrue(#keyboard.frames >= 1, "the keyboard cursor carries generated frames")
  local maskEntry = assert(
    bundle.manifest.assets[assert(keyboard.pulseAsset, "the keyboard cursor names its pulse atlas")],
    "the pulse-mask atlas is indexed"
  )
  local maskWidth, maskHeight, maskRgba = PngReader.rgba(assert(bundle.assets[maskEntry.image]))
  Assert.equal(maskEntry.width, maskWidth)
  Assert.equal(maskEntry.height, maskHeight)
  for index, frame in ipairs(keyboard.frames) do
    local pulseRect = assert(frame.pulseRect, "cursor frame " .. index .. " carries its mask rect")
    Assert.equal(pulseRect.width, frame.rect.width, "mask frame " .. index .. " matches its frame width")
    Assert.equal(pulseRect.height, frame.rect.height, "mask frame " .. index .. " matches its frame height")
  end
  local total = math.floor(#maskRgba / 4)
  for index = 0, total - 1 do
    local r, g, b, a = PngReader.pixel(maskRgba, maskWidth, index % maskWidth, math.floor(index / maskWidth))
    local opaque = a ~= 0
    if opaque then
      Assert.deepEqual({ r, g, b, a }, { 255, 255, 255, 255 }, "opaque mask pixels are the white marker")
    end
  end
end

-- The normal start-menu icon visuals are source-composed sprite frames, not
-- fixed CHAR crops: every sprite row carries the shared cell/animation
-- compositor's pixels with its source-relative offset, and the manifest
-- publishes the seven source-position records the runtime selector consumes.
-- The tampered icon cell below carries two objects with a negative local
-- origin, a horizontal flip, and a non-zero palette bank, so a fixed 32x40
-- crop at a zero origin cannot accidentally reproduce it. Member numbers are
-- the producer-side selection (this is the romdump-side test).
local TAMPERED_ICON_CELL = {
  { x = -8, y = 4, tile = 0, pal = 2, flipH = true },
  { x = 0, y = 4, tile = 1, pal = 2 },
}

local function iconComposedFixture()
  return fixture({
    tamper = function(alias, members)
      if alias == "start_menu" then
        withIconBank(members)
        members[17] = lz10Wrap(cellData(TAMPERED_ICON_CELL))
      end
      return members
    end,
  })
end

-- The shared compositor's own answer for one icon char bank over the tampered
-- cell: the exact pixels and source-relative offset the compiled visual must
-- pack and record.
---@param charBase integer the icon char bank base the fixture builds per member
---@return { width: integer, height: integer, pixels: string, offset: { x: number, y: number } }
local function expectedIconFrame(charBase)
  local char = assert(G2dDecoder.decodeChar(charData(20, charBase)))
  local palette = assert(G2dDecoder.decodePalette(paletteData(distinctSignpostPalette(4))))
  local cell = assert(G2dDecoder.decodeCell(cellData(TAMPERED_ICON_CELL)))
  local anim = assert(G2dDecoder.decodeAnimation(animData({ { duration = 3, cell = 0 }, { duration = 3, cell = 0 } })))
  return G2dRasterizer.renderAnimationFrame(char, { colors = palette.colors }, cell, anim.anims[1], 1, {
    asset = "start menu icon expectation",
  })
end

---@param bundle table
---@param assetId string
---@return integer, integer, string
local function atlasRgba(bundle, assetId)
  local entry = assert(bundle.manifest.assets[assetId], "the generated class must index asset " .. assetId)
  return PngReader.rgba(assert(bundle.assets[entry.image]))
end

---@param rgba string
---@param atlasWidth integer
---@param rect table
---@return string
local function regionPixels(rgba, atlasWidth, rect)
  local region = {}
  for y = 0, rect.height - 1 do
    local rowStart = (rect.y + y) * atlasWidth * 4
    region[#region + 1] = rgba:sub(rowStart + rect.x * 4 + 1, rowStart + (rect.x + rect.width) * 4)
  end
  return table.concat(region)
end

function T.start_menu_compiles_the_seven_source_position_records()
  local romFs, sha1, hashLua = iconComposedFixture()
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local startMenu = assert(bundle.manifest.startMenu, "the manifest must carry the start menu section")
  local interactive =
    assert(startMenu.interactive, "the start menu section must publish its interactive position records")
  Assert.deepEqual(interactive, FieldUiFixture.startMenuInteractive())
  Assert.isNil(startMenu.slots, "the normal selector publishes no synthetic slot grid")
end

-- The start menu label roles compile as source-independent colors with a
-- compositing-transparent background: labels resolve without runtime
-- palette-bank knowledge and glyph background pixels reveal chrome.
function T.start_menu_compiles_label_roles_with_transparent_background()
  local romFs, sha1, hashLua = iconComposedFixture()
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local startMenu = assert(bundle.manifest.startMenu, "the manifest must carry the start menu section")
  local labelPalette = assert(startMenu.labelPalette, "the start menu section must publish its generated label palette")
  for _, role in ipairs({ "foreground", "shadow", "background" }) do
    local color = assert(labelPalette[role], "the label palette must carry " .. role)
    Assert.isTrue(type(color.r) == "number", "the " .. role .. " role carries red")
    Assert.isTrue(type(color.g) == "number", "the " .. role .. " role carries green")
    Assert.isTrue(type(color.b) == "number", "the " .. role .. " role carries blue")
  end
  Assert.equal(labelPalette.foreground.a, 1, "the label foreground stays opaque")
  Assert.equal(labelPalette.shadow.a, 1, "the label shadow stays opaque")
  Assert.equal(labelPalette.background.a, 0, "the label background stays transparent over chrome")
end

function T.start_menu_icon_visuals_match_the_shared_animation_composition()
  local romFs, sha1, hashLua = iconComposedFixture()
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local startMenu = assert(bundle.manifest.startMenu, "the manifest must carry the start menu section")
  -- Retail icon 0 compiles from char member 18, whose fixture bank base is 2.
  local expected = expectedIconFrame(18 % 16)
  Assert.isTrue(expected.width ~= 32 or expected.height ~= 40, "the probe cell is not the fixed 32x40 crop")
  local row = assert(startMenu.iconTable[1], "icon row 1 must exist")
  local visual = assert(row.visual, "icon row 1 must carry its source-composed visual, not a fixed crop rect")
  local normal = assert(visual.normal, "the icon visual carries its normal state")
  local selected = assert(visual.selected, "the icon visual carries its selected state")
  Assert.equal(normal.asset, FieldUiAssetCache.ASSET.START_MENU_ICONS, "the normal visual names the shared atlas")
  Assert.equal(selected.asset, FieldUiAssetCache.ASSET.START_MENU_ICONS, "the selected visual names the shared atlas")
  Assert.deepEqual(normal.offset, expected.offset, "the normal visual keeps the compositor source-relative offset")
  Assert.equal(normal.rect.width, expected.width, "the normal visual keeps the compositor frame width")
  Assert.equal(normal.rect.height, expected.height, "the normal visual keeps the compositor frame height")
  local width, _, rgba = atlasRgba(bundle, normal.asset)
  Assert.equal(regionPixels(rgba, width, normal.rect), expected.pixels, "the normal visual packs the compositor pixels")
  local selectedPixels = regionPixels(rgba, width, selected.rect)
  Assert.isTrue(selectedPixels ~= expected.pixels, "the selected state renders through the selection palette")
end

function T.bag_female_variant_carries_its_own_composed_frame()
  local romFs, sha1, hashLua = iconComposedFixture()
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local startMenu = assert(bundle.manifest.startMenu, "the manifest must carry the start menu section")
  -- The Bag female art compiles from char member 27, whose fixture bank base
  -- is 11: same cell geometry as the default art, distinct pixels.
  local expectedFemale = expectedIconFrame(27 % 16)
  local expectedDefault = expectedIconFrame(18 % 16)
  Assert.isTrue(expectedFemale.pixels ~= expectedDefault.pixels, "the probe banks render distinct art")
  local row = assert(startMenu.iconTable[3], "the bag row must exist")
  local variants = assert(row.variants, "the bag row carries its gender-conditional variant")
  local female = assert(variants.female, "the bag row carries the female art as a first-class variant")
  local femaleNormal = assert(female.normal, "the female variant carries the same normal/selected record shape")
  local femaleSelected = assert(female.selected, "the female variant carries the same normal/selected record shape")
  Assert.deepEqual(
    femaleNormal.offset,
    expectedFemale.offset,
    "the female visual keeps its own compositor source-relative offset"
  )
  local width, _, rgba = atlasRgba(bundle, femaleNormal.asset)
  Assert.equal(
    regionPixels(rgba, width, femaleNormal.rect),
    expectedFemale.pixels,
    "the female visual packs its own compositor pixels"
  )
  Assert.isTrue(
    regionPixels(rgba, width, femaleSelected.rect) ~= regionPixels(rgba, width, femaleNormal.rect),
    "the female selected state renders through the selection palette"
  )
end

-- The expected keyboard-window pixel colors come from bank 1 of the
-- fixture BG palette: retail opens the keyboard windows with palette 1,
-- so value v displays as bank-1 slot v (colors is 1-based, hence
-- colors[16 + v + 1]). The shared fixture repeats its pattern across
-- banks, so this helper resolves the bank-1 index explicitly while the
-- real-palette ROM test below is the guard that distinguishes the banks.
local function namingSlotPalette()
  local decoded = assert(G2dDecoder.decodePalette(palette16(), { label = "naming window test palette" }))
  return decoded.colors
end

local function namingPagePixels(bundle, assetId)
  local entry = assert(bundle.manifest.assets[assetId], "the naming page asset is indexed: " .. assetId)
  local bytes = assert(bundle.assets[entry.image], "the naming page has generated pixels: " .. entry.image)
  local width, height, rgba = PngReader.rgba(bytes)
  Assert.equal(width, 256, "the naming page stays 256 wide")
  Assert.equal(height, 112, "the naming page stays 112 tall")
  return width, rgba
end

local function assertNamingPixel(width, rgba, x, y, colors, slot, what)
  local expected = assert(colors[16 + slot + 1], "the fixture palette covers bank-1 slot " .. slot)
  local r, g, b, a = PngReader.pixel(rgba, width, x, y)
  local where = what .. " at (" .. x .. "," .. y .. ")"
  Assert.equal(a, 255, where .. " is opaque window art")
  Assert.equal(r, expected.r, where .. " red")
  Assert.equal(g, expected.g, where .. " green")
  Assert.equal(b, expected.b, where .. " blue")
end

-- Every normal page carries the retail keyboard window the original game
-- fills dynamically before printing letters: the page-local 208x96 window at
-- (16,8) in the page base slot, resolved through palette bank 1, partitioned into 13x5 16x19 cells whose
-- color alternates with (row + column) parity exactly like the source fill
-- loops (row 0 colors odd columns alternate, row 1 colors even columns, and
-- so on). The final bottom pixel row of the 96px window stays the base
-- color. Cell centers plus the row/column boundary pixels pin the 16x19
-- geometry so an inverted checkerboard or a shifted grid fails.
function T.naming_pages_compose_the_source_keyboard_window()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local naming = assert(bundle.manifest.namingScreen, "the compiled field UI must publish normal naming chrome")
  local colors = namingSlotPalette()
  local roles = {
    upper = { base = 4, alternate = 3 },
    lower = { base = 7, alternate = 6 },
    symbols = { base = 13, alternate = 12 },
  }
  for _, key in ipairs({ "upper", "lower", "symbols" }) do
    local page = assert(naming.pages[key], "the normal " .. key .. " page is required")
    local width, rgba = namingPagePixels(bundle, page.asset)
    local role = roles[key]
    for row = 0, 4 do
      for column = 0, 12 do
        local slot = role.base
        if (row + column) % 2 == 1 then
          slot = role.alternate
        end
        assertNamingPixel(
          width,
          rgba,
          16 + column * 16 + 8,
          8 + row * 19 + 9,
          colors,
          slot,
          "the " .. key .. " window cell row " .. row .. " column " .. column
        )
      end
    end
    for column = 0, 12 do
      assertNamingPixel(
        width,
        rgba,
        16 + column * 16 + 8,
        8 + 95,
        colors,
        role.base,
        "the " .. key .. " window bottom remainder"
      )
    end
    assertNamingPixel(width, rgba, 16 + 15, 8 + 9, colors, role.base, "the " .. key .. " column 0 edge")
    assertNamingPixel(width, rgba, 16 + 16, 8 + 9, colors, role.alternate, "the " .. key .. " column 1 edge")
    assertNamingPixel(width, rgba, 16 + 8, 8 + 18, colors, role.base, "the " .. key .. " row 0 edge")
    assertNamingPixel(width, rgba, 16 + 8, 8 + 19, colors, role.alternate, "the " .. key .. " row 1 edge")
  end
end

-- The generated backing rows and the published runtime text cells share one
-- geometry: backing tops at page-local 8/27/46 (screen 88/107/126) on the
-- 19px pitch, and glyph tops exactly 4px below at 92/111/130. The text
-- values alone already match source; this scenario fails until the backing
-- rows the text sits over exist in the generated page.
function T.naming_backing_rows_lock_runtime_text_geometry()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local naming = assert(bundle.manifest.namingScreen, "the compiled field UI must publish normal naming chrome")
  local colors = namingSlotPalette()
  local upper = assert(naming.pages.upper, "the normal upper page is required")
  local width, rgba = namingPagePixels(bundle, upper.asset)
  assertNamingPixel(width, rgba, 16 + 8, 8 + 9, colors, 4, "the upper backing row 0")
  assertNamingPixel(width, rgba, 16 + 8, 27 + 9, colors, 3, "the upper backing row 1")
  assertNamingPixel(width, rgba, 16 + 8, 46 + 9, colors, 4, "the upper backing row 2")
  local cells = assert(naming.text.keyboard.cells, "the keyboard text cells are published")
  local expectedTops = { 92, 111, 130 }
  for row = 1, 3 do
    local cell = assert(cells[row][1], "keyboard text row " .. row .. " column 1 is required")
    Assert.equal(cell.x, 27, "keyboard text row " .. row .. " starts at screen x 27")
    Assert.equal(cell.y, expectedTops[row], "keyboard text row " .. row .. " top")
    Assert.equal(cell.width, 16, "keyboard text cells stay 16px wide")
    Assert.equal(
      cell.y - (80 + (8 + (row - 1) * 19)),
      4,
      "keyboard text row " .. row .. " sits 4px below its backing top"
    )
  end
  Assert.equal(cells[2][1].y - cells[1][1].y, 19, "backing and text advance 19px per row")
  Assert.equal(cells[3][1].y - cells[2][1].y, 19, "backing and text advance 19px per row")
end

-- A keyboard window that does not fit the 256x112 page raster is corrupt
-- source configuration, never a silent clip.
function T.naming_keyboard_window_outside_the_page_is_a_source_defect()
  local manifestConfig = require("romdump.src.config.FieldUiAssets")
  local original = manifestConfig.namingScreen.keyboardWindow
  manifestConfig.namingScreen.keyboardWindow = {
    x = 200,
    y = 8,
    width = 208,
    height = 96,
    columns = 13,
    rows = 5,
    cellWidth = 16,
    rowHeight = 19,
    textInsetY = 4,
    pages = {
      upper = { base = 4, alternate = 3 },
      lower = { base = 7, alternate = 6 },
      symbols = { base = 13, alternate = 12 },
    },
  }
  local romFs, sha1, hashLua = fixture()
  local ok, bundle, err = xpcall(compileWithTestConfig, debug.traceback, romFs, sha1, hashLua)
  manifestConfig.namingScreen.keyboardWindow = original
  Assert.isTrue(ok, "overriding the keyboard window must not raise outside the compiler: " .. tostring(bundle))
  Assert.isNil(bundle, "a keyboard window outside the 256x112 page must not compile")
  Assert.equal(
    assert(err, "the compiler reports the defect").code,
    FieldUiCompiler.ERROR.SOURCE_INVALID,
    "the window overflow is a typed source defect"
  )
end

-- The three normal pages need their bank-1 base/alternate palette slots to
-- exist; a palette too short to serve them is malformed source, never a
-- silent substitute color. Eight colors still cover every pre-window pixel value
-- the fixture rasterizes, so only the missing window slots can fail this.
function T.naming_keyboard_window_with_a_missing_palette_slot_is_a_source_defect()
  local short = {}
  for i = 1, 8 do
    short[i] = i * 0x39B
  end
  local romFs, sha1, hashLua = fixture({
    tamper = function(alias, members)
      if alias == "naming_screen" then
        members[1] = paletteOr16(short)
      end
      return members
    end,
  })
  local bundle, err = compileWithTestConfig(romFs, sha1, hashLua)
  Assert.isNil(bundle, "a naming palette missing the window slots must not compile")
  Assert.equal(
    assert(err, "the compiler reports the defect").code,
    FieldUiCompiler.ERROR.SOURCE_INVALID,
    "the missing palette slot is a typed source defect"
  )
end

-- The compiled dialogue frames publish no application record: one RGBA
-- frame atlas beside the continuation cursor, with no second PNG payload.
function T.compiled_dialogue_frames_publish_no_application_record()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local frames = assert(bundle.manifest.dialogueFrames)
  Assert.isNil(frames.application, "the compiled field UI carries no application frame record")
  for _, entry in pairs(bundle.manifest.assets) do
    Assert.isFalse(
      (entry.image or ""):find("application-frame-tiles", 1, true) ~= nil,
      "no indexed asset points at an application frame strip"
    )
  end
  for path in pairs(bundle.assets) do
    Assert.isFalse(
      path:find("application-frame-tiles", 1, true) ~= nil,
      "no generated payload is an application frame strip"
    )
  end
end

-- The two-row prompt producer contract: the selected prompt members
-- decode into four semantic 48x32 button states published without source
-- archive/member identities. The test installs its own prompt member
-- selection around compilation (mirroring the signpost test-config patch),
-- so the production member-selection shape is exercised without freezing
-- unrelated producer internals. Frozen test-side selection field names are
-- alias, paletteMember, charMember, yesNormalScreen, yesSelectedScreen,
-- noNormalScreen, and noSelectedScreen.
local function compileWithPromptSelection(romFs, sha1hex, hashLua)
  local manifestConfig = require("romdump.src.config.FieldUiAssets")
  local savedSourceTypes = manifestConfig.signposts.sourceTypes
  local savedWayfinding = manifestConfig.signposts.wayfinding
  local savedPrompt = manifestConfig.yesNoPrompt
  manifestConfig.signposts.sourceTypes = { 0, 1, 2, 3 }
  manifestConfig.signposts.wayfinding = {
    [0] = { memberBase = 0x21, maps = { 0, 1, 20 } },
    [1] = { memberBase = 2, maps = { 0, 21 } },
  }
  manifestConfig.yesNoPrompt = {
    alias = "touch_subwindow",
    paletteMember = 0,
    charMember = 1,
    yesNormalScreen = 2,
    yesSelectedScreen = 3,
    noNormalScreen = 4,
    noSelectedScreen = 5,
  }
  -- xpcall forwards every return value of a successful call; capture both
  -- `compile`'s bundle and its typed nil,err failure return so callers see
  -- the real error instead of a silently dropped second value.
  local ok, bundle, err = xpcall(FieldUiCompiler.compile, debug.traceback, romFs, sha1hex, hashLua)
  manifestConfig.signposts.sourceTypes = savedSourceTypes
  manifestConfig.signposts.wayfinding = savedWayfinding
  manifestConfig.yesNoPrompt = savedPrompt
  if ok then
    return bundle, err
  end
  error(bundle, 0)
end

function T.two_row_prompt_compiles_four_semantic_button_states()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compileWithPromptSelection(romFs, sha1, hashLua))
  local prompt = assert(bundle.manifest.yesNoPrompt, "the compiled field UI must publish the two-row prompt") --[[@as FieldUiAssetCache.PromptSection]]
  local compact = assert(prompt.shapes ~= nil and prompt.shapes.compact, "the prompt carries its compact shape record") --[[@as FieldUiAssetCache.PromptShape]]
  Assert.equal(compact.width, 48)
  Assert.equal(compact.height, 32)
  local states = { compact.yes.normal, compact.yes.selected, compact.no.normal, compact.no.selected }
  local pixels = {}
  for index, state in ipairs(states) do
    Assert.equal(type(state.asset), "string", "prompt state " .. index .. " resolves through a semantic asset")
    local entry = assert(bundle.manifest.assets[state.asset], "prompt state " .. index .. " asset is indexed")
    local rect = assert(state.rect, "prompt state " .. index .. " carries its visual rect")
    Assert.equal(rect.width, 48, "prompt state " .. index .. " rect width")
    Assert.equal(rect.height, 32, "prompt state " .. index .. " rect height")
    Assert.isTrue(
      rect.x + rect.width <= entry.width and rect.y + rect.height <= entry.height,
      "prompt state " .. index .. " rect stays inside its indexed image"
    )
    local bytes = assert(bundle.assets[entry.image], "prompt state " .. index .. " image has payload")
    local width, height, rgba = PngReader.rgba(bytes)
    Assert.equal(width, entry.width, "prompt state " .. index .. " png width")
    Assert.equal(height, entry.height, "prompt state " .. index .. " png height")
    pixels[#pixels + 1] = rgba
  end
  for i = 1, #pixels do
    for j = i + 1, #pixels do
      Assert.isTrue(pixels[i] ~= pixels[j], "prompt states " .. i .. " and " .. j .. " are distinct art")
    end
  end
  local forbiddenKeys = {
    member = true,
    memberId = true,
    narc = true,
    narcId = true,
    alias = true,
    fileId = true,
    bgId = true,
    tileStart = true,
    plttSlot = true,
    paletteSlot = true,
    sourcePath = true,
  }
  local function scan(value, path)
    if type(value) ~= "table" then
      return
    end
    for k, v in pairs(value) do
      if type(k) == "string" and forbiddenKeys[k] then
        Assert.fail("the prompt manifest leaks source detail '" .. k .. "' at " .. path)
      end
      scan(v, path .. "." .. tostring(k))
    end
  end
  scan(prompt, "yesNoPrompt")
  local second = assert(compileWithPromptSelection(romFs, sha1, hashLua))
  Assert.equal(second.marker, bundle.marker, "the prompt publication is deterministic")
  Assert.equal(LuaWriter.encode(second.manifest), LuaWriter.encode(bundle.manifest))
end

-- The confirmation row renders through the first prompt palette bank and
-- the rejection row through the second: the fixture banks are distinct
-- families, so a state rendered through the wrong bank is a visibly wrong
-- color, never a coincidentally matching one.
function T.prompt_rows_render_through_their_own_palette_banks()
  local Rgb555 = require("libs.codec.src.Rgb555")
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(compileWithPromptSelection(romFs, sha1, hashLua))
  local prompt = assert(bundle.manifest.yesNoPrompt, "the compiled field UI must publish the two-row prompt") --[[@as FieldUiAssetCache.PromptSection]]
  local compact = assert(prompt.shapes ~= nil and prompt.shapes.compact) --[[@as FieldUiAssetCache.PromptShape]]
  local function topLeftPixel(state)
    local entry = assert(bundle.manifest.assets[assert(state.asset)])
    local width, _, rgba = PngReader.rgba(assert(bundle.assets[entry.image]))
    local rect = assert(state.rect)
    return PngReader.pixel(rgba, width, rect.x, rect.y)
  end
  -- The fixture char tiles carry value ((tile + 0) % 15) + 1: the YES
  -- normal screen references tile 2 (value 3) and the NO normal screen
  -- references tile 4 (value 5). Value v selects bank slot v, which is
  -- colors[bank * 16 + v + 1] in the 1-based decoded array, so value 3
  -- through bank 0 is the fourth palette word and value 5 through bank 1
  -- is the twenty-second palette word.
  local expectedYes = Rgb555.decode(4 * 0x39B)
  local rYes, gYes, bYes, aYes = topLeftPixel(compact.yes.normal)
  Assert.equal(aYes, 255)
  Assert.deepEqual(
    { rYes, gYes, bYes },
    { expectedYes.r, expectedYes.g, expectedYes.b },
    "the YES row renders through the first palette bank"
  )
  local expectedNo = Rgb555.decode(0x4000 + 6 * 0x123)
  local rNo, gNo, bNo, aNo = topLeftPixel(compact.no.normal)
  Assert.equal(aNo, 255)
  Assert.deepEqual(
    { rNo, gNo, bNo },
    { expectedNo.r, expectedNo.g, expectedNo.b },
    "the NO row renders through the second palette bank"
  )
end

return { tests = T }
