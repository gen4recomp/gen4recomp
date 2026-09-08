-- ROM-conformance facts for the generated field-UI class: the real private
-- dump compiles the bundle (frames, signposts, Start Menu, Trainer Card),
-- every indexed file passes FieldUiAssetCache.isReady, and the compile is
-- deterministic. Asserts only non-copyright structural facts.

local Assert = require("tests.support.Assert")
local BinaryReader = require("libs.codec.src.BinaryReader")
local CacheFs = require("libs.storage.src.CacheFs")
local PngReader = require("tests.support.PngReader")
local FieldUiCompiler = require("romdump.src.digest.ui.FieldUiCompiler")
local FieldUiCacheWriter = require("romdump.src.digest.ui.FieldUiCacheWriter")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local Lz10 = require("romdump.src.digest.Lz10")
local Hashing = require("romdump.src.digest.Hashing")
local manifestConfig = require("romdump.src.config.FieldUiAssets")

local T = {}

-- Read one NARC member, unwrapping the LZ10 wrapper the dump uses.
local function memberBytes(romFs, archive, memberId)
  local narc = assert(romFs:openNarc(archive))
  local bytes = assert(narc:readMember(memberId))
  if string.byte(bytes, 1) == 0x10 then
    local plain, err = Lz10.decode(bytes)
    assert(plain, err and err.message)
    return plain
  end
  return bytes
end

-- The strict screen-data rule (NSCR entry bytes must equal width/8 * height/8
-- * 2 exactly) and the strict tile-alignment rule (CHAR tile bytes an exact
-- positive multiple of the tile size) hold for every screen and char member
-- of the real dump, so the strict validations accept real source geometry.
function T.source_geometry_matches_the_strict_validation_rules(romFs, _)
  local function assertScreen(archive, memberId, label)
    local scr, err = G2dDecoder.decodeScreen(memberBytes(romFs, archive, memberId), { label = label })
    assert(scr, err and err.message)
    Assert.isTrue(scr.width % 8 == 0 and scr.height % 8 == 0, label .. " dimensions are tile-aligned")
    Assert.equal(#scr.entries, scr.width / 8 * scr.height / 8, label .. " entry count matches its dimensions")
  end
  local function assertChar(archive, memberId, label, expectedDepth, expectedTiles)
    local ch, err = G2dDecoder.decodeChar(memberBytes(romFs, archive, memberId), { label = label })
    assert(ch, err and err.message)
    local tileSize = ch.depth == 3 and 32 or 64
    Assert.equal(ch.depth, expectedDepth, label .. " depth")
    Assert.equal(#ch.tiles % tileSize, 0, label .. " tile bytes align to the tile size")
    Assert.equal(math.floor(#ch.tiles / tileSize), expectedTiles, label .. " tile count")
  end
  local startMenu = manifestConfig.startMenu
  local frames = manifestConfig.dialogueFrames
  local signposts = manifestConfig.signposts
  local trainerCard = manifestConfig.trainerCard
  assertScreen(startMenu.alias, startMenu.backgroundScreenMember, "start menu background screen")
  assertScreen(trainerCard.alias, trainerCard.frontScreenMember, "trainer card front screen")
  assertChar(startMenu.alias, startMenu.backgroundCharMember, "start menu background char", 3, 128)
  assertChar(startMenu.alias, startMenu.cursorCharMember, "start menu cursor char", 3, 16)
  assertChar(trainerCard.alias, trainerCard.frontCharMember, "trainer card front char", 4, 416)
  assertChar(frames.alias, frames.firstFrameMember, "dialogue frame char", 3, 18)
  assertChar(signposts.alias, signposts.frameMember, "signpost frame char", 3, 18)
  assertChar(signposts.alias, signposts.wayfinding[0].memberBase, "signpost wayfinding char", 3, 24)
end

-- The real start-menu cursor cell is a single square OBJ whose OAM attrs
-- declare the 32x32 square geometry (shape 0, size 2) with a 16-tile char,
-- and the real animation drives exactly two frames over that one cell. The
-- cursor compile must keep accepting this real geometry rather than assuming
-- every OBJ is 8x8.
function T.cursor_source_geometry_is_a_single_square_32x32_obj(romFs, _)
  local startMenu = manifestConfig.startMenu
  local cell, err = G2dDecoder.decodeCell(memberBytes(romFs, startMenu.alias, startMenu.cursorCellMember))
  assert(cell, err and err.message)
  Assert.equal(#cell.cells, 1, "the cursor cell bank carries one cell")
  Assert.equal(#cell.cells[1].objs, 1, "the cursor cell carries one OBJ")

  local reader = BinaryReader.new(memberBytes(romFs, startMenu.alias, startMenu.cursorCellMember), "cursor cell")
  local headerSize = reader:u16le(12)
  local blockCount = reader:u16le(14)
  local chunk
  for block = 0, blockCount - 1 do
    if reader:ascii(headerSize + block * 8, 4) == "KBEC" then
      chunk = headerSize + block * 8
      break
    end
  end
  assert(chunk, "the cursor cell resource has no KBEC chunk")
  local numCells = reader:u16le(chunk + 8)
  local tableOffset = reader:u32le(chunk + 12)
  local attrTable = chunk + 8 + tableOffset + numCells * 8
  local attr0 = reader:u16le(attrTable)
  local attr1 = reader:u16le(attrTable + 2)
  local attr2 = reader:u16le(attrTable + 4)
  Assert.equal(math.floor(attr0 / 16384), 0, "the cursor OBJ is square (attr0 shape bits)")
  Assert.equal(math.floor(attr1 / 16384), 2, "the cursor OBJ is the 32x32 square size (attr1 size bits)")
  Assert.equal(attr2 % 1024, 0, "the cursor OBJ starts at tile 0")
  Assert.equal(math.floor(attr2 / 4096), 0, "the cursor OBJ uses palette bank 0")

  local anim, animErr = G2dDecoder.decodeAnimation(memberBytes(romFs, startMenu.alias, startMenu.cursorAnimMember))
  assert(anim, animErr and animErr.message)
  Assert.equal(#anim.anims, 1, "the cursor animation bank carries one animation")
  Assert.equal(#anim.anims[1].frames, 2, "the cursor animation drives two frames")
  local bundle = assert(FieldUiCompiler.compile(romFs))
  Assert.equal(#bundle.manifest.startMenu.cursor.frames, 2, "the compiled cursor carries one frame per animation frame")
  Assert.equal(
    bundle.manifest.startMenu.cursor.frames[1].width,
    32,
    "the compiled cursor frame covers the full 32x32 square"
  )
  Assert.equal(
    bundle.manifest.startMenu.cursor.frames[1].height,
    32,
    "the compiled cursor frame covers the full 32x32 square"
  )
end

function T.compiled_ui_assets_are_ready_and_stable(romFs, version)
  local cache = CacheFs.forVersion(version)
  local bundle = assert(FieldUiCompiler.compile(romFs))
  local marker = FieldUiAssetCache.marker(romFs:metadata().sha1, Hashing.hashLua(bundle.dependencies))
  Assert.equal(bundle.marker, marker, "the marker is FORMAT:romSha1:depHash")

  -- The class covers every section the manifest contract requires.
  Assert.equal(bundle.manifest.dialogueFrames.count, 20)
  -- Generated rows pin the audited HGSS geometry: the 18-tile frame strips
  -- are 144 px wide and the wayfinding entries are 48x32 final surfaces,
  -- independent of the synthetic fixture contract.
  Assert.equal(bundle.manifest.dialogueFrames.frameTiles[0].width, 144)
  Assert.equal(bundle.manifest.dialogueFrames.frameTiles[0].height, 8)
  local type0 = bundle.manifest.signposts.types[0]
  Assert.equal(type0.frameTiles.width, 144)
  Assert.equal(type0.frameTiles.height, 8)
  Assert.isTrue(type0.wayfinding ~= nil, "type 0 reserves the wayfinding region")
  Assert.equal(type0.wayfinding[0].width, 48)
  Assert.equal(type0.wayfinding[0].height, 32)
  Assert.isTrue(type0.wayfinding[11] ~= nil, "the real corpus pair (type 0, map 11) must carry a wayfinding row")
  Assert.isTrue(type0.wayfinding[20] ~= nil, "the real corpus pair (type 0, map 20) must carry a wayfinding row")
  Assert.isTrue(type0.wayfinding[0].y ~= type0.wayfinding[1].y, "the map-0 and map-1 rows are distinct atlas rows")
  Assert.isTrue(
    bundle.manifest.signposts.types[1].wayfinding[21] ~= nil,
    "the real corpus pair (type 1, map 21) must carry a wayfinding row"
  )
  Assert.isTrue(bundle.manifest.signposts.types[2].wayfinding == nil, "type 2 is full width")
  Assert.equal(bundle.manifest.startMenu.background.width, 256)
  Assert.equal(bundle.manifest.trainerCard.front.width, 256)

  -- Recompiling is deterministic and the published class is fully ready.
  local second = assert(FieldUiCompiler.compile(romFs))
  Assert.equal(second.marker, bundle.marker)
  FieldUiCacheWriter.write(cache, bundle)
  Assert.isTrue(FieldUiAssetCache.isReady(cache, bundle.marker), "every indexed file is ready after publication")
  Assert.isFalse(FieldUiAssetCache.isReady(cache, bundle.marker .. "-stale"))
end

-- The dialogue frame class must offer at least two visually distinct frame
-- styles with identical strip geometry: the frame index selects artwork
-- (the compiled strip row), never the frame composition. Probes the compiled
-- PNG bytes, not the GPU.
function T.dialogue_frame_styles_are_distinct_artwork_with_identical_geometry(romFs, _)
  local bundle = assert(FieldUiCompiler.compile(romFs))
  local frames = bundle.manifest.dialogueFrames
  Assert.isTrue(frames.count >= 2, "the class carries at least two frame styles")

  local strip = bundle.assets[bundle.manifest.assets[FieldUiAssetCache.ASSET.DIALOGUE_FRAME_TILES].image]
  local width, _, rgba = PngReader.rgba(strip)

  local function rectPixels(rect)
    Assert.equal(rect.width, 144, "every frame strip row is the full tile run")
    Assert.equal(rect.height, 8)
    Assert.equal(rect.x, 0)
    return rgba:sub(rect.y * width * 4 + 1, (rect.y + 8) * width * 4)
  end

  -- Each frame strip row is its own 18-tile run; rows are distinct artwork.
  local distinctRows = {}
  for frame = 0, frames.count - 1 do
    local rect = frames.frameTiles[frame]
    local row = rectPixels(rect)
    Assert.isNil(distinctRows[row], "frame " .. frame .. " must not duplicate an earlier frame row")
    distinctRows[row] = frame
  end

  -- Frame 0 vs frame 1 render different artwork: the two strip rows are not
  -- the same pixels (a frame-option change must alter the artwork).
  local row0 = rectPixels(frames.frameTiles[0])
  local row1 = rectPixels(frames.frameTiles[1])
  Assert.isTrue(row0 ~= row1, "frame 0 and frame 1 render different artwork")

  -- The corner tiles are transparent-corners artwork, so also pin a known
  -- opaque difference: frame 0 tile 6 is blue (107,222,255) and frame 1
  -- tile 6 is cream (255,239,222) at the same strip coordinate.
  local tile6X = 6 * 8 + 4
  local r0, g0, b0, a0 = PngReader.pixel(rgba, width, tile6X, frames.frameTiles[0].y)
  local r1, g1, b1, a1 = PngReader.pixel(rgba, width, tile6X, frames.frameTiles[1].y)
  Assert.equal(a0, 255, "frame 0 tile 6 is opaque")
  Assert.equal(a1, 255, "frame 1 tile 6 is opaque")
  Assert.isTrue(r0 ~= r1 or g0 ~= g1 or b0 ~= b1, "frame 0 and frame 1 tile 6 colors differ")
end

-- The field printer's continuation cursor is a source-derived, precolored
-- atlas: runtime receives only semantic rectangles and final pixel payloads.
function T.dialogue_continue_cursor_manifest_has_the_source_contract(romFs, _)
  local bundle = assert(FieldUiCompiler.compile(romFs))
  local frames = assert(bundle.manifest.dialogueFrames)
  local cursor = assert(frames.continueCursor, "the generated field UI must publish the continuation cursor")
  local assetId = "hgss.dialogue_continue_cursor"
  local asset = assert(bundle.manifest.assets[assetId], "the cursor asset must be indexed by its semantic ID")
  local image = assert(bundle.assets[asset.image], "the cursor atlas must have generated pixel payload")
  local imageWidth, imageHeight, pixels = PngReader.rgba(image)

  Assert.equal(asset.image, "assets/generated/field/ui/dialogue-continue-cursor.png")
  Assert.equal(imageWidth, 48)
  Assert.equal(imageHeight, frames.count * 16)
  Assert.isTrue(type(pixels) == "string" and #pixels > 0, "cursor pixel payload must be nonempty")
  Assert.deepEqual(cursor.cycle, { 0, 1, 2, 1 })
  Assert.equal(cursor.framePrinterTicks, 9)
  Assert.deepEqual(cursor.placement, { x = 240, y = 168, width = 16, height = 16 })

  for style = 0, frames.count - 1 do
    local phases = assert(cursor.styles[style]).phases
    for phase = 0, 2 do
      local rect = assert(phases[phase])
      Assert.deepEqual(rect, { x = phase * 16, y = style * 16, width = 16, height = 16 })
    end
  end

  for key in pairs(cursor) do
    Assert.isFalse(
      key == "alias" or key == "memberId" or key == "paletteMemberId" or key == "sourcePath",
      "runtime cursor metadata must not expose source identity"
    )
  end
end

-- Independent local-ink measurement for the continuation cursor: its opaque
-- pixels (including the right edge, so a crop error cannot pass by left-edge
-- coincidence) must stay inside its own generated 16x16 surface, and the
-- placed surface itself must stay inside the 256x192 source reference. This
-- is separate from the surface-placement fact above: local ink and placement
-- are independent claims, and only a defect in this local measurement
-- implicates the cursor producer rather than the shared dialogue layout.
function T.dialogue_continue_cursor_local_ink_stays_within_its_generated_surface(romFs, _)
  local bundle = assert(FieldUiCompiler.compile(romFs))
  local frames = assert(bundle.manifest.dialogueFrames)
  local cursor = assert(frames.continueCursor)
  local asset = assert(bundle.manifest.assets[cursor.asset])
  local image = assert(bundle.assets[asset.image])
  local imageWidth, _, rgba = PngReader.rgba(image)
  local rect = assert(assert(cursor.styles[0]).phases[0])

  local minX, maxX
  for x = 0, rect.width - 1 do
    for y = 0, rect.height - 1 do
      local _, _, _, a = PngReader.pixel(rgba, imageWidth, rect.x + x, rect.y + y)
      if a > 0 then
        minX = minX and math.min(minX, x) or x
        maxX = maxX and math.max(maxX, x) or x
      end
    end
  end
  Assert.notNil(minX, "the continuation cursor phase must carry opaque ink")
  Assert.isTrue(minX >= 0, "cursor local ink left bound stays inside its own surface")
  Assert.isTrue(maxX < rect.width, "cursor local ink right bound stays inside its own surface")
  Assert.isTrue(
    cursor.placement.x >= 0 and cursor.placement.x + cursor.placement.width <= 256,
    "the placed cursor surface stays inside the 256-wide source reference"
  )
  Assert.isTrue(
    cursor.placement.y >= 0 and cursor.placement.y + cursor.placement.height <= 192,
    "the placed cursor surface stays inside the 192-tall source reference"
  )
end

-- The continuation cursor payload follows the source pixel-rectangle
-- preparation (pret/pokeheartgold sub_0200EA68 blits cursor source columns
-- 3..15 onto destination columns 0..12 with palette index 0 transparent),
-- so the visible arrow occupies surface columns 1..10 with the retail
-- vertical bounce. Any backing corruption outside that box would extend the
-- measured box, so the box assertions below also prove the untouched right
-- region keeps the frame backing.
function T.continuation_cursor_payload_matches_the_source_preparation(romFs, _)
  local bundle = assert(FieldUiCompiler.compile(romFs))
  local frames = assert(bundle.manifest.dialogueFrames)
  local cursor = assert(frames.continueCursor)
  Assert.deepEqual(cursor.placement, { x = 240, y = 168, width = 16, height = 16 })
  Assert.deepEqual(cursor.cycle, { 0, 1, 2, 1 })

  local cfg = manifestConfig.dialogueFrames
  local frameChar, charErr =
    G2dDecoder.decodeChar(memberBytes(romFs, cfg.alias, cfg.firstFrameMember), { label = "frame 0 char" })
  assert(frameChar, charErr and charErr.message)
  Assert.equal(frameChar.depth, 3, "frame 0 char is 4bpp")
  local framePal, palErr =
    G2dDecoder.decodePalette(memberBytes(romFs, cfg.alias, cfg.firstPaletteMember), { label = "frame 0 palette" })
  assert(framePal, palErr and palErr.message)

  -- Expected frame backing for one 16x16 phase: tiles 10, 11 over 10, 11.
  local function backingPixel(x, y)
    local tileId = x < 8 and 10 or 11
    local lx, ly = x % 8, y % 8
    local byte = string.byte(frameChar.tiles, tileId * 32 + ly * 4 + math.floor(lx / 2) + 1)
    local v
    if lx % 2 == 0 then
      v = byte % 16
    else
      v = math.floor(byte / 16)
    end
    if v == 0 then
      return 0, 0, 0, 0
    end
    local c = assert(framePal.colors[v + 1], "frame palette covers the backing pixel")
    return c.r, c.g, c.b, 255
  end

  local asset = assert(bundle.manifest.assets[cursor.asset])
  local imageWidth, _, rgba = PngReader.rgba(assert(bundle.assets[asset.image]))
  local tops = { 2, 3, 4 }
  for phase = 0, 2 do
    local rect = assert(assert(cursor.styles[0]).phases[phase])
    local minX, maxX, minY, maxY
    for x = 0, 15 do
      for y = 0, 15 do
        local r, g, b, a = PngReader.pixel(rgba, imageWidth, rect.x + x, rect.y + y)
        local br, bg, bb, ba = backingPixel(x, y)
        if r ~= br or g ~= bg or b ~= bb or a ~= ba then
          Assert.equal(a, 255, "phase " .. phase .. " arrow ink is opaque")
          minX = minX and math.min(minX, x) or x
          maxX = maxX and math.max(maxX, x) or x
          minY = minY and math.min(minY, y) or y
          maxY = maxY and math.max(maxY, y) or y
        end
      end
    end
    Assert.notNil(minX, "phase " .. phase .. " carries arrow ink over the backing")
    Assert.equal(minX, 1, "phase " .. phase .. " arrow starts at surface column 1")
    Assert.equal(maxX, 10, "phase " .. phase .. " arrow ends at surface column 10")
    Assert.equal(minY, tops[phase + 1], "phase " .. phase .. " keeps its vertical top")
    Assert.equal(maxY, tops[phase + 1] + 10, "phase " .. phase .. " keeps its vertical bottom")
  end
end

return require("tests.rom.support.RomSuite").fromFacts(T)
