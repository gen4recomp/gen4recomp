-- Behavior: compiler arranges wayfinding tiles into final 48x32 surface 6x4 grid.
-- Each tile distinguishable; rect 48x32, palette per source type.

local Assert = require("tests.support.Assert")
local FieldUiCompiler = require("romdump.src.digest.ui.FieldUiCompiler")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local PngReader = require("tests.support.PngReader")

local T = {}

local function compileWithTestConfig(romFs, sha1hex, hashLua)
  local manifestConfig = require("romdump.src.config.FieldUiAssets")
  local originalSourceTypes = manifestConfig.signposts.sourceTypes
  local originalWayfinding = manifestConfig.signposts.wayfinding
  manifestConfig.signposts.sourceTypes = { 0, 1, 2, 3 }
  manifestConfig.signposts.wayfinding = {
    [0] = { memberBase = 0x21, maps = { 0, 1 } },
    [1] = { memberBase = 2, maps = { 0, 1 } },
  }
  local ok, bundle, err = xpcall(FieldUiCompiler.compile, debug.traceback, romFs, sha1hex, hashLua)
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
    chunks[#chunks + 1] = flags .. data:sub(i, math.min(i + 7, #data))
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
local function charData(tiles, base)
  local payload = u16(8) .. u16(0x20) .. u32(3) .. u16(0) .. u16(0) .. u32(0) .. u32(tiles * 32) .. u32(0x18)
  local body = {}
  for t = 0, tiles - 1 do
    body[#body + 1] = string.rep(string.char((((t + (base or 0)) % 15) + 1) * 0x11), 32)
  end
  return container("RGCN", { block("CHAR", payload .. table.concat(body)) })
end
local function screenData(entries)
  local body = {}
  for _, e in ipairs(entries) do
    body[#body + 1] = u16(e)
  end
  return container("RCSN", { block("SCRN", u16(256) .. u16(192) .. u32(0) .. u32(#entries * 2) .. table.concat(body)) })
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
  local ttlp = "TTLP" .. u32(24 + #bodyBytes) .. u32(3) .. u32(0) .. u32(#colors * 2) .. u32(16) .. bodyBytes
  return "RLCN" .. string.char(0xFF, 0xFE) .. u16(0x0100) .. u32(0x10 + #ttlp) .. u16(0x10) .. u16(1) .. ttlp
end
local function cellData(objs)
  local metatile = u16(#objs) .. u16(0) .. u32(0)
  local attr = {}
  for _, o in ipairs(objs) do
    attr[#attr + 1] = u16((o.y % 256) + (o.shape or 0) * 16384)
      .. u16((o.x % 512) + (o.size or 0) * 16384)
      .. u16(o.tile + o.pal * 4096)
  end
  return container(
    "RECN",
    { block("CEBK", u16(1) .. u16(0) .. u32(0x18) .. u32(0) .. string.rep("\0", 12) .. metatile .. table.concat(attr)) }
  )
end
local function animData(frames)
  local anims = u16(1) .. u16(#frames) .. u32(0x18) .. u32(0x28) .. u32(0x28 + 8 * #frames) .. string.rep("\0", 8)
  local anim = u32(#frames) .. u16(0) .. u16(1) .. u32(1) .. u32(0)
  local frameBlocks, frameData = {}, {}
  for i, f in ipairs(frames) do
    frameBlocks[#frameBlocks + 1] = u32((i - 1) * 2) .. u16(f.duration) .. u16(0)
    frameData[#frameData + 1] = u16(f.cell)
  end
  return container("RNAN", { block("ABNK", anims .. anim .. table.concat(frameBlocks) .. table.concat(frameData)) })
end

-- Multi-cell/multi-animation banks for the naming OBJ stack: fifty cells
-- and animations cover the semantic animation table (subjects at 48 and 49);
-- cell i references tile i % 16 through palette bank i % 9 of the nine-bank
-- palette below.
local function namingCellBank(cellObjs)
  local meta, attr = {}, {}
  local offset = 0
  for _, objs in ipairs(cellObjs) do
    meta[#meta + 1] = u16(#objs) .. u16(0) .. u32(offset)
    offset = offset + #objs * 6
  end
  for _, objs in ipairs(cellObjs) do
    for _, o in ipairs(objs) do
      attr[#attr + 1] = u16((o.y % 256) + (o.shape or 0) * 16384)
        .. u16((o.x % 512) + (o.size or 0) * 16384)
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

local function namingAnimBank(animCells)
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

local function namingNineBankPalette()
  local colors = {}
  for bank = 0, 8 do
    for slot = 0, 15 do
      colors[bank * 16 + slot + 1] = bank + slot * 32
    end
  end
  return paletteData(colors)
end

local function narc(members)
  local btaf = u16(#members) .. u16(0)
  local running = 0
  local sizes = {}
  for _, bytes in ipairs(members) do
    sizes[#sizes + 1] = #bytes
  end
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
local function palette16()
  local colors = {}
  for i = 1, 16 do
    colors[i] = i * 0x39B
  end
  for i = 17, 64 do
    colors[i] = ((i - 1) % 16 + 1) * 0x39B
  end
  return paletteData(colors)
end
-- The Start Menu SUB palette fixture: five 16-color banks so label bank 4
-- (colors 64..79) resolves the label roles. The first four banks repeat
-- the shared 64-color pattern, so SUB chrome pixels compiled through the
-- lower banks are unchanged.
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
local function distinctSignpostPalette(numTypes)
  local colors = {}
  for t = 0, numTypes - 1 do
    for s = 0, 15 do
      colors[t * 16 + s + 1] = t + s * 32
    end
  end
  return colors
end

local function fixture(opts)
  opts = opts or {}
  local startMenuMembers = {}
  startMenuMembers[13] = lz10Wrap(charData(128))
  startMenuMembers[14] = lz10Wrap(fullScreen(0))
  startMenuMembers[16] = lz10Wrap(palette16())
  startMenuMembers[62] = lz10Wrap(palette16())
  startMenuMembers[63] = lz10Wrap(cellData({ { x = 0, y = 0, tile = 0, pal = 0 } }))
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
  -- The naming archive the v8 contract requires: palette 0, char 2, base
  -- screen 4, and page screens 6/7/8. Tile 0 of the char bank stays blank so
  -- page holes remain transparent.
  local function namingPage(width, height, tile)
    local entries = {}
    for i = 1, width / 8 * (height / 8) do
      entries[i] = tile
    end
    entries[1] = 0
    return screenDataWH(width, height, entries)
  end
  local namingTiles = { string.rep("\0", 32) }
  for t = 1, 7 do
    namingTiles[#namingTiles + 1] = string.rep(string.char((((t - 1) % 15) + 1) * 0x11), 32)
  end
  local namingCharPayload = u16(8)
    .. u16(0x20)
    .. u32(3)
    .. u16(0)
    .. u16(0)
    .. u32(0)
    .. u32(#namingTiles * 32)
    .. u32(0x18)
  local namingChar = container("RGCN", { block("CHAR", namingCharPayload .. table.concat(namingTiles)) })
  local namein = {}
  for i = 1, 15 do
    namein[i] = string.rep("\0", 4)
  end
  namein[1] = palette16()
  namein[3] = namingChar
  namein[5] = lz10Wrap(fullScreen(1))
  namein[7] = lz10Wrap(namingPage(256, 112, 2))
  namein[8] = lz10Wrap(namingPage(256, 112, 3))
  namein[9] = lz10Wrap(namingPage(256, 112, 4))
  -- The normal naming OBJ stack the semantic contract requires: palette 1
  -- with nine banks, char 10, cell 12, anim 14.
  namein[2] = namingNineBankPalette()
  namein[11] = charData(16, 3)
  do
    local cells, animCells = {}, {}
    for index = 0, 49 do
      cells[index + 1] = { { x = 0, y = 0, tile = index % 16, pal = index % 9 } }
      animCells[index + 1] = index
    end
    namein[13] = namingCellBank(cells)
    namein[15] = namingAnimBank(animCells)
  end
  -- The synthetic two-row prompt archive the current field-UI class
  -- requires: palette member 0, the shared char bank member 1, and one
  -- 48x32 screen per button state (members 2..5).
  local prompt = {}
  for i = 1, 6 do
    prompt[i] = string.rep("\0", 4)
  end
  prompt[1] = palette16()
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
      members[1] = lz10Wrap(charData(9))
      members[26] = lz10Wrap(palette16())
      for i = 1, 20 do
        members[2 + i] = lz10Wrap(charData(18))
      end
      for i = 1, 20 do
        members[26 + i] = lz10Wrap(palette16())
      end
      -- The v7 cursor atlas is sourced from the dedicated member after the
      -- twenty dialogue frame members.
      members[0x16 + 1] = lz10Wrap(charData(12))
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

function T.compiled_wayfinding_is_48x32_with_6x4_tile_arrangement()
  local romFs, sha1, hashLua = fixture({ signpostPalette = distinctSignpostPalette(4) })
  local bundle = assert(compileWithTestConfig(romFs, sha1, hashLua))
  local wayfindingAsset = assert(bundle.manifest.assets[FieldUiAssetCache.ASSET.SIGNPOST_WAYFINDING])
  -- Must be final surface atlas: each entry 48x32, check type 0 map 0
  local rect = assert(bundle.manifest.signposts.types[0].wayfinding[0])
  Assert.equal(rect.width, 48, "final surface width must be 48")
  Assert.equal(rect.height, 32, "final surface height must be 32")

  -- Atlas dimensions: stacked 48x32 surfaces
  -- With 4 rows (2 maps * 2 types with wayfinding), height = 4*32 = 128, width = 48
  Assert.equal(wayfindingAsset.width, 48, "atlas width must be 48 for final surfaces")
  Assert.equal(wayfindingAsset.height, 128, "atlas height must be 4 * 32 for 4 wayfinding entries")

  -- Pixel equivalence: tile r*6+c at (c*8,r*8) with per-source-type palette
  local Rgb555 = require("libs.codec.src.Rgb555")
  local pngBytes = assert(bundle.assets[wayfindingAsset.image])
  local width, height, rgba = PngReader.rgba(pngBytes)
  Assert.equal(width, 48)
  Assert.equal(height, 128)
  -- Check a few positions for type 0 map 0 (first rect at y=0, sourceType 0)
  -- Tile layout: source tile index tile maps to destination (col=tile%6, row=tile/6)
  -- For type 0, wayfinding member 0x21, tile values are ((t + 0x21%16)%15)+1
  -- Palette bank 0, slot = value -> Rgb555 decode of (0 + value*32)
  -- Verify tile 0 at (0,0) and tile 6 at (0,8) etc.
  local function expectedColor(sourceType, tileIndex)
    local base = 0x21 % 16 -- for type 0 map 0
    -- Actually map selection: type 0 maps 0,1 use memberBase 0x21 + map
    -- So tile value = ((tile + base)%15)+1, slot = value
    -- Use correct base per map
    local value = ((tileIndex + base) % 15) + 1
    return Rgb555.decode(sourceType + value * 32)
  end
  -- test tile 0 at (4,4) within first surface
  local r, g, b, a = PngReader.pixel(rgba, width, 4, 4)
  local exp = expectedColor(0, 0)
  Assert.equal(a, 255)
  Assert.deepEqual({ r, g, b }, { exp.r, exp.g, exp.b }, "tile 0 at (0,0) in final surface")
  -- tile 1 at (12,4)
  local r1, g1, b1 = PngReader.pixel(rgba, width, 12, 4)
  local exp1 = expectedColor(0, 1)
  Assert.deepEqual({ r1, g1, b1 }, { exp1.r, exp1.g, exp1.b }, "tile 1 at (8,0)")
  -- tile 6 should be at (0,8) second row
  local r2, g2, b2 = PngReader.pixel(rgba, width, 4, 12)
  local exp2 = expectedColor(0, 6)
  Assert.deepEqual({ r2, g2, b2 }, { exp2.r, exp2.g, exp2.b }, "tile 6 at (0,8) second row")
end

return { tests = T }
