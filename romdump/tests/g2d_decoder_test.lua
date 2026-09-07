-- G2D container decoding contract: the byte-swapped "RGCN/RCSN/RECN/RNAN"
-- containers and their RAHC (char), NRCS (screen), TTLP/PLTT (palette), KBEC
-- (cell) and KNBA (animation) chunks. Fixtures are built by hand from the
-- GBATEK "Nitro Character Tiles / BG Maps Screens / OBJ Animations /
-- OBJ Metatile Cells" layouts; the real ROM gated the same layouts. Strict
-- structural validation: duplicate logical chunks, screen data sizes that
-- contradict the dimensions, char tile runs that are not exact tile
-- multiples, animation byte offsets normalized to frame units, and OAM shape/size
-- decoded from attr0/attr1 with flips read from attr1 bits 12/13.

local Assert = require("tests.support.Assert")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")

local T = {}

local function u16(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end
local function u32(v)
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end
local function swap4(s)
  return s:reverse()
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

local function charBlock(tiles, depth)
  local payload = u16(8) .. u16(0x20) .. u32(depth) .. u16(0) .. u16(0) .. u32(0) .. u32(#tiles) .. u32(0x18) .. tiles
  return block("CHAR", payload)
end

local function screenBlock(entries, width, height)
  local body = {}
  for _, e in ipairs(entries) do
    body[#body + 1] = u16(e)
  end
  return block("SCRN", u16(width) .. u16(height) .. u32(0) .. u32(#entries * 2) .. table.concat(body))
end

local function paletteBlock(colors)
  local body = {}
  for _, c in ipairs(colors) do
    body[#body + 1] = u16(c)
  end
  -- PLTT: depth(1), unk(1), nColors(2), unk(4), dataOffset(4), colors
  return block("PLTT", string.char(3, 0) .. u16(#colors) .. u32(0) .. u32(12) .. table.concat(body))
end

-- Two 4bpp tiles: tile 0 all value 1, tile 1 all value 2.
local function twoTiles()
  return string.rep(string.char(0x11), 32) .. string.rep(string.char(0x22), 32)
end

function T.char_chunk_reports_depth_and_tiles()
  local data = container("RGCN", { charBlock(twoTiles(), 3) })
  local ch = assert(G2dDecoder.decodeChar(data))
  Assert.equal(ch.depth, 3)
  Assert.equal(#ch.tiles, 64)
end

function T.char_chunk_accepts_8bpp()
  local data = container("RGCN", { charBlock(string.rep("\1", 64), 4) })
  local ch = assert(G2dDecoder.decodeChar(data))
  Assert.equal(ch.depth, 4)
end

function T.screen_chunk_reports_size_and_entries()
  -- 16x8 pixels = 2x1 tiles: entry 0 = tile 3, entry 1 = tile 0x0400
  -- (flipH) | 0x0800 (flipV) | 5 << 12 (palette 5).
  local data = container("RCSN", { screenBlock({ 3, 0x0400 + 0x0800 + 5 * 4096 }, 16, 8) })
  local scr = assert(G2dDecoder.decodeScreen(data))
  Assert.equal(scr.width, 16)
  Assert.equal(scr.height, 8)
  Assert.equal(#scr.entries, 2)
  Assert.deepEqual(scr.entries[1], { tile = 3, flipH = false, flipV = false, palette = 0 })
  Assert.deepEqual(scr.entries[2], { tile = 0, flipH = true, flipV = true, palette = 5 })
end

function T.palette_chunk_decodes_15bit_colors()
  local data = container("NCLR", { paletteBlock({ 0x7FFF, 0x0000, 0x001F }) })
  local pal = assert(G2dDecoder.decodePalette(data))
  Assert.equal(#pal.colors, 3)
  Assert.deepEqual(pal.colors[1], { r = 255, g = 255, b = 255 })
  Assert.deepEqual(pal.colors[2], { r = 0, g = 0, b = 0 })
  Assert.deepEqual(pal.colors[3], { r = 255, g = 0, b = 0 })
end

-- KBEC: one metatile with two OBJs. Payload: numCells(2), entrySize(2),
-- metatileOffset(4) = 0x18, boundary(4), 12 zero bytes, then the metatile
-- table (8 bytes each) and the OBJ attribute table. attr0 = y + shape << 14,
-- attr1 = x + flipH << 12 + flipV << 13 + size << 14, attr2 = tile + palette
-- << 12 (flips are attr1 bits 12/13 per the OAM layout, not attr2 10/11).
local function cellBlock(objs)
  local metatile = u16(#objs) .. u16(0) .. u32(0)
  local attr = {}
  for _, o in ipairs(objs) do
    attr[#attr + 1] = u16((o.y % 256) + (o.shape or 0) * 16384)
      .. u16((o.x % 512) + (o.flipH and 4096 or 0) + (o.flipV and 8192 or 0) + (o.size or 0) * 16384)
      .. u16(o.tile + o.pal * 4096)
  end
  return block(
    "CEBK",
    u16(1) .. u16(0) .. u32(0x18) .. u32(0) .. string.rep("\0", 12) .. metatile .. table.concat(attr)
  )
end

function T.cell_chunk_reports_objs_per_cell()
  local data = container("RECN", {
    cellBlock({
      { x = 2, y = 3, tile = 7, flipH = false, flipV = false, pal = 0 },
      { x = -4, y = 5, tile = 9, flipH = true, flipV = false, pal = 1 },
    }),
  })
  local cell = assert(G2dDecoder.decodeCell(data))
  Assert.equal(#cell.cells, 1)
  Assert.equal(#cell.cells[1].objs, 2)
  Assert.deepEqual(cell.cells[1].objs[1], {
    x = 2,
    y = 3,
    tile = 7,
    flipH = false,
    flipV = false,
    palette = 0,
    shape = 0,
    size = 0,
    width = 8,
    height = 8,
  })
  Assert.deepEqual(cell.cells[1].objs[2], {
    x = -4,
    y = 5,
    tile = 9,
    flipH = true,
    flipV = false,
    palette = 1,
    shape = 0,
    size = 0,
    width = 8,
    height = 8,
  })
end

-- A wide OBJ (shape 1, size 1) decodes to 32x8 pixels: the decoder must
-- derive real dimensions from the OAM shape/size bits rather than assuming
-- every object is 8x8.
function T.cell_chunk_decodes_oam_shape_and_size_into_dimensions()
  local data = container("RECN", {
    cellBlock({ { x = 0, y = 0, tile = 0, pal = 0, shape = 1, size = 1 } }),
  })
  local cell = assert(G2dDecoder.decodeCell(data))
  local obj = cell.cells[1].objs[1]
  Assert.equal(obj.shape, 1)
  Assert.equal(obj.size, 1)
  Assert.equal(obj.width, 32)
  Assert.equal(obj.height, 8)
end

-- attr0 shape bits 3 are reserved by the OAM layout: a cell carrying them is
-- malformed source, not a raw indexing failure.
function T.cell_chunk_rejects_the_reserved_oam_shape()
  local data = container("RECN", {
    cellBlock({ { x = 0, y = 0, tile = 0, pal = 0, shape = 3 } }),
  })
  local out, err = G2dDecoder.decodeCell(data)
  Assert.isNil(out)
  Assert.equal(assert(err).code, G2dDecoder.ERROR.CHUNK_INVALID)
end

-- KNBA: one animation of two frames. Payload: numAnims(2), numFrames(2),
-- animsOffset(4) = 0x18, framesOffset(4), frameDataOffset(4), 8 zero bytes,
-- then 16-byte anim blocks, 8-byte frame blocks, and u16 frame data.
-- firstFrame defaults to 0; the source field is a byte offset into that table.
local function animBlock(frames, firstFrame, animationFrameCount)
  local anims = u16(1)
    .. u16(#frames)
    .. u32(0x18)
    .. u32(0x18 + 16)
    .. u32(0x18 + 16 + 8 * #frames)
    .. string.rep("\0", 8)
  -- The 16-byte animation entry: u16 frame count, u16 loop start, u32
  -- animation type, u32 play mode, then the u32 first-frame byte offset.
  local anim = u32(animationFrameCount or #frames) .. u16(0) .. u16(1) .. u32(1) .. u32(firstFrame or 0)
  local frameBlocks = {}
  local frameData = {}
  for i, f in ipairs(frames) do
    frameBlocks[#frameBlocks + 1] = u32((i - 1) * 2) .. u16(f.duration) .. u16(0)
    frameData[#frameData + 1] = u16(f.cell)
  end
  return block("ABNK", anims .. anim .. table.concat(frameBlocks) .. table.concat(frameData))
end

-- A sequence entry with explicit header semantics: u16 frame count, u16
-- loop start, u32 animation type, u32 play mode, u32 first-frame byte
-- offset. A nonzero loop start shares its first word with the frame count
-- under a naive u32 read, so it distinguishes a correct header parse from
-- one that conflates the two halfwords.
local function sequenceBlock(numFrames, loopStart, playMode, frames, firstFrame)
  local total = #frames
  local header = u16(1)
    .. u16(total)
    .. u32(0x18)
    .. u32(0x18 + 16)
    .. u32(0x18 + 16 + 8 * total)
    .. string.rep("\0", 8)
  local entry = u16(numFrames) .. u16(loopStart) .. u16(0) .. u16(1) .. u32(playMode) .. u32(firstFrame or 0)
  local frameBlocks = {}
  local frameData = {}
  for i, f in ipairs(frames) do
    frameBlocks[#frameBlocks + 1] = u32((i - 1) * 2) .. u16(f.duration) .. u16(0)
    frameData[#frameData + 1] = u16(f.cell)
  end
  return block("ABNK", header .. entry .. table.concat(frameBlocks) .. table.concat(frameData))
end

function T.animation_chunk_reports_frames_with_durations()
  local data = container("RNAN", {
    animBlock({ { duration = 12, cell = 0 }, { duration = 3, cell = 1 } }),
  })
  local anim = assert(G2dDecoder.decodeAnimation(data))
  Assert.equal(#anim.anims, 1)
  Assert.equal(#anim.anims[1].frames, 2)
  Assert.deepEqual(anim.anims[1].frames[1], {
    cell = 0,
    duration = 12,
    element = "none",
    translateX = 0,
    translateY = 0,
    scaleX = 1,
    scaleY = 1,
    rotation = 0,
  })
  Assert.deepEqual(anim.anims[1].frames[2], {
    cell = 1,
    duration = 3,
    element = "none",
    translateX = 0,
    translateY = 0,
    scaleX = 1,
    scaleY = 1,
    rotation = 0,
  })
end

-- Loop start and play mode are independent sequence header fields: the frame
-- count stays exact when loop start is nonzero, and the numeric mode is
-- normalized to its source-independent meaning. Frame payloads decode exactly
-- as before. An unknown numeric mode is malformed source, not a silent
-- default.
function T.animation_sequence_preserves_loop_start_and_play_mode()
  local frames = {
    { duration = 5, cell = 0 },
    { duration = 7, cell = 1 },
    { duration = 9, cell = 0 },
  }
  local data = container("RNAN", { sequenceBlock(3, 1, 2, frames) })
  local anim = assert(G2dDecoder.decodeAnimation(data))
  Assert.equal(#anim.anims, 1)
  local seq = anim.anims[1]
  Assert.equal(#seq.frames, 3)
  Assert.equal(seq.loopStartFrameIdx, 1)
  Assert.equal(seq.playMode, "forward_loop")
  Assert.equal(seq.frames[1].duration, 5)
  Assert.equal(seq.frames[1].cell, 0)
  Assert.equal(seq.frames[2].duration, 7)
  Assert.equal(seq.frames[2].cell, 1)
  Assert.equal(seq.frames[3].duration, 9)
  Assert.equal(seq.frames[3].cell, 0)

  local bad = container("RNAN", { sequenceBlock(1, 0, 99, { { duration = 4, cell = 0 } }) })
  local out, err = G2dDecoder.decodeAnimation(bad)
  Assert.isNil(out)
  Assert.equal(assert(err).code, G2dDecoder.ERROR.CHUNK_INVALID)
end

-- firstFrame is a byte offset and numFrames a frame count: the normalized range
-- must fit the frame table total, not some byte-sized measure of the chunk.
function T.animation_frame_range_is_validated_in_frame_units()
  -- frameCount = 2 but the animation claims frames [1, 3): out of range.
  local data = container("RNAN", {
    animBlock({ { duration = 12, cell = 0 }, { duration = 3, cell = 1 } }, 8, 2),
  })
  local out, err = G2dDecoder.decodeAnimation(data)
  Assert.isNil(out)
  Assert.equal(assert(err).code, G2dDecoder.ERROR.CHUNK_INVALID)
end

function T.source_animation_frame_offsets_are_decoded_in_frame_units()
  local frames = {}
  for cell = 0, 15 do
    frames[#frames + 1] = { duration = cell + 1, cell = cell }
  end
  local data = container("RNAN", {
    animBlock(frames, 8, 1),
  })
  local anim = assert(G2dDecoder.decodeAnimation(data))
  Assert.equal(#anim.anims[1].frames, 1)
  Assert.deepEqual(anim.anims[1].frames[1], {
    cell = 1,
    duration = 2,
    element = "none",
    translateX = 0,
    translateY = 0,
    scaleX = 1,
    scaleY = 1,
    rotation = 0,
  })
end

-- The frame data offset must point inside the chunk before the cell index is
-- read: an animation referencing beyond its frame-data table is malformed.
function T.animation_cell_read_is_bounds_checked()
  -- One animation, one frame whose frameData (16) escapes the 2-byte cell
  -- table at dataOffset 0x30.
  local anims = u16(1) .. u16(1) .. u32(0x18) .. u32(0x28) .. u32(0x30) .. string.rep("\0", 8)
  local anim = u32(1) .. u16(0) .. u16(1) .. u32(1) .. u32(0)
  local frameBlock = u32(16) .. u16(12) .. u16(0)
  local data = container("RNAN", { block("ABNK", anims .. anim .. frameBlock .. u16(0)) })
  local out, err = G2dDecoder.decodeAnimation(data)
  Assert.isNil(out)
  Assert.equal(assert(err).code, G2dDecoder.ERROR.CHUNK_INVALID)
end

function T.bad_magic_and_truncated_chunks_are_typed()
  local out, err = G2dDecoder.decodeChar("not-a-g2d")
  Assert.isNil(out)
  Assert.equal(assert(err).code, G2dDecoder.ERROR.MAGIC_INVALID)
  -- A header declaring two blocks but carrying only one: the second block
  -- header extends past the declared size.
  local data = container("RGCN", { charBlock(twoTiles(), 3) })
  local broken = data:sub(1, 12) .. string.char(2, 0) .. data:sub(15)
  local out2, err2 = G2dDecoder.decodeScreen(broken)
  Assert.isNil(out2)
  Assert.equal(assert(err2).code, G2dDecoder.ERROR.BLOCK_INVALID)
end

function T.unknown_chunk_is_rejected()
  local data = container("RGCN", { block("SOPC", u32(0) .. u16(0x20) .. u16(8)) })
  local out, err = G2dDecoder.decodeChar(data)
  Assert.isNil(out)
  Assert.equal(assert(err).code, G2dDecoder.ERROR.CHUNK_MISSING)
end

-- A repeated logical chunk id is malformed container structure: the second
-- CHAR must not silently replace the first.
function T.duplicate_chunks_are_rejected()
  local data = container("RGCN", { charBlock(twoTiles(), 3), charBlock(twoTiles(), 3) })
  local out, err = G2dDecoder.decodeChar(data)
  Assert.isNil(out)
  Assert.equal(assert(err).code, G2dDecoder.ERROR.CHUNK_DUPLICATE)
end

-- The screen entry bytes must equal the tile count times two exactly:
-- metadata describing one geometry while supplying another amount of map
-- data is malformed source.
function T.screen_data_size_must_match_the_dimensions()
  -- 16x8 = 2 tiles needs 4 bytes; supply three entries.
  local data = container("RCSN", { screenBlock({ 3, 0, 5 }, 16, 8) })
  local out, err = G2dDecoder.decodeScreen(data)
  Assert.isNil(out)
  Assert.equal(assert(err).code, G2dDecoder.ERROR.CHUNK_INVALID)
end

-- The char tile region must be an exact positive multiple of the tile size:
-- a 33-byte 4bpp run cannot be floored into tiles.
function T.char_tile_bytes_must_be_an_exact_tile_multiple()
  local data = container("RGCN", { charBlock(string.rep("\1", 33), 3) })
  local out, err = G2dDecoder.decodeChar(data)
  Assert.isNil(out)
  Assert.equal(assert(err).code, G2dDecoder.ERROR.CHUNK_INVALID)
end

return { tests = T }
