-- Compiles the generated HGSS field-UI class: the Start Menu background and
-- cursor, the twenty user dialogue frames, the corpus signpost frame and
-- wayfinding graphics, and the Trainer Card front — all as decoded PNG
-- atlases and the strict manifest. Wayfinding members are precomposed
-- into final 48x32 surfaces (6 by 4 tiles) at build time so runtime draws
-- a single rect. Source member selection lives in
-- romdump/src/config/FieldUiAssets.lua; this module owns the HGSS decode
-- and the normalized bundle. The runtime consumes only the manifest and
-- the generated files, never this module. Pure module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local PngWriter = require("libs.assets.src.PngWriter")
local Lz10 = require("romdump.src.digest.Lz10")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local manifestConfig = require("romdump.src.config.FieldUiAssets")

local FieldUiCompiler = {}

---@alias FieldUiCompiler.CharData { depth: integer, tiles: string }
---@alias FieldUiCompiler.PaletteData { colors: { r: integer, g: integer, b: integer }[] }
---@alias FieldUiCompiler.ScreenData { width: integer, height: integer, entries: table[] }
---@alias FieldUiCompiler.CellData { cells: table[] }
---@alias FieldUiCompiler.AnimationData { anims: table[] }

-- Named ownership of the compiler protocol error codes; tests assert the
-- constant, never the raw string.
FieldUiCompiler.ERROR = {
  SOURCE_INVALID = "FIELD_UI_SOURCE_INVALID",
}

---@generic T
---@param value T?
---@param err unknown?
---@return T
local function must(value, err)
  if value == nil then
    error(err or "expected a value", 0)
  end
  return value
end

local function concatChars(chars)
  -- string.char/unpack are limited by the Lua stack; build in row chunks.
  local out = {}
  for i = 1, #chars, 4096 do
    out[#out + 1] = string.char(unpack(chars, i, math.min(i + 4095, #chars)))
  end
  return table.concat(out)
end

-- Decode a member that may be LZ10-wrapped.
---@param archive Narc
---@param memberId integer
---@param label string
---@return string
local function decodeMember(archive, memberId, label)
  local bytes = must(archive:readMember(memberId), "missing member " .. memberId .. " (" .. label .. ")")
  if string.byte(bytes, 1) == 0x10 then
    local plain, lzErr = Lz10.decode(bytes)
    if not plain then
      error(lzErr, 0)
    end
    bytes = plain
  end
  return bytes
end

-- Blit one tile's pixels into an RGBA buffer. 4bpp tiles hold two pixel
-- values per byte (low nibble first); 8bpp tiles hold one. Pixel value 0 is
-- the reserved transparency slot: the HGSS UI palettes fill it with a pink
-- chroma color that the DS window/OBJ presentation never displays. Values
-- >= 1 map to palette color `value` — colors is 1-based (colors[i] = color
-- i-1), so the lookup is value + 1 within the tile's palette bank. A tile
-- index beyond the decoded tiles, or a palette entry the decoded palette
-- cannot cover, is malformed source, never silent transparency.
-- `source` names the asset/member/cell/obj that produced the reference for
-- the typed error context.
local function blitTile(rgba, atlasWidth, destX, destY, charData, tileIndex, palIndex, colors, flipH, flipV, source)
  local depth = charData.depth
  local tileBytes = depth == 3 and 32 or 64
  local tileCount = math.floor(#charData.tiles / tileBytes)
  if tileIndex < 0 or tileIndex >= tileCount then
    Errors.raise(
      FieldUiCompiler.ERROR.SOURCE_INVALID,
      "tile reference exceeds the decoded char data",
      { tile = tileIndex, available = tileCount, source = source }
    )
  end
  local palBase = depth == 3 and palIndex * 16 or palIndex * 256
  local function put(x, y, v)
    if v == 0 then
      return
    end
    local c = colors[palBase + v + 1]
    if not c then
      Errors.raise(
        FieldUiCompiler.ERROR.SOURCE_INVALID,
        "pixel references a palette entry the decoded palette cannot cover",
        { value = v, palette = palIndex, available = #colors, source = source }
      )
    end
    if flipH then
      x = 7 - x
    end
    if flipV then
      y = 7 - y
    end
    local px = ((destY + y) * atlasWidth + destX + x) * 4
    rgba[px + 1], rgba[px + 2], rgba[px + 3], rgba[px + 4] = c.r, c.g, c.b, 255
  end
  local base = tileIndex * tileBytes
  if depth == 3 then
    for y = 0, 7 do
      for x = 0, 3 do
        local byte = string.byte(charData.tiles, base + y * 4 + x + 1)
        put(x * 2, y, byte % 16)
        put(x * 2 + 1, y, math.floor(byte / 16))
      end
    end
  else
    for y = 0, 7 do
      for x = 0, 7 do
        put(x, y, string.byte(charData.tiles, base + y * 8 + x + 1))
      end
    end
  end
end

local function newRgba(width, height)
  local rgba = {}
  for i = 1, width * height * 4 do
    rgba[i] = 0
  end
  return rgba
end

-- Compose the 16x16 continuation surface exactly as the source window code
-- does: the cursor member supplies the phase payload, while frame tiles 10
-- and 11 provide the backing that surrounds that payload.
local function composeCursorPhase(rgba, atlasWidth, destX, destY, frameChar, framePalette, cursorChar, phase, source)
  for row = 0, 1 do
    blitTile(rgba, atlasWidth, destX, destY + row * 8, frameChar, 10, 0, framePalette, false, false, source)
    blitTile(rgba, atlasWidth, destX + 8, destY + row * 8, frameChar, 11, 0, framePalette, false, false, source)
  end
  for tile = 0, 3 do
    blitTile(
      rgba,
      atlasWidth,
      destX + (tile % 2) * 8,
      destY + math.floor(tile / 2) * 8,
      cursorChar,
      phase * 4 + tile,
      0,
      framePalette,
      false,
      false,
      source
    )
  end
end

-- Render a screen (BG tilemap with flips) into a PNG. Generic decoded-tile
-- raster mechanics live in G2dRasterizer; this wrapper only feeds its pixels
-- into the existing PNG/publication path unchanged.
local function renderScreen(charData, palette, screen, source)
  local image = G2dRasterizer.renderScreen(charData, { colors = palette }, screen, source)
  return PngWriter.encode(image.width, image.height, image.pixels)
end

local function cellBounds(cell)
  local first = assert(cell.objs[1], "cell bounds require at least one object")
  local minX, minY, maxX, maxY = first.x, first.y, first.x + first.width, first.y + first.height
  for i = 2, #cell.objs do
    local obj = cell.objs[i]
    if obj.x < minX then
      minX = obj.x
    end
    if obj.y < minY then
      minY = obj.y
    end
    if obj.x + obj.width > maxX then
      maxX = obj.x + obj.width
    end
    if obj.y + obj.height > maxY then
      maxY = obj.y + obj.height
    end
  end
  return { x = minX, y = minY, width = maxX - minX, height = maxY - minY }
end

-- Blit one cell OBJ into the cursor atlas. The compiler supports the two
-- square geometries the cursor sources actually use (8x8 and the real
-- 32x32); any other shape/size is malformed source. Square OBJs lay their
-- tiles out row-major from the base tile. A flipped OBJ mirrors the whole
-- object per the OAM layout: the tile grid order is mirrored as well, and
-- each tile is flipped in place by blitTile.
local function blitObj(rgba, atlasWidth, row, obj, charData, palette, source)
  if obj.shape ~= 0 or (obj.size ~= 0 and obj.size ~= 2) then
    Errors.raise(
      FieldUiCompiler.ERROR.SOURCE_INVALID,
      "unsupported OBJ geometry in the start menu cursor",
      { width = obj.width, height = obj.height, shape = obj.shape, size = obj.size, source = source }
    )
  end
  local tilesPerRow = obj.width / 8
  local rowsPerObj = obj.height / 8
  for tileRow = 0, rowsPerObj - 1 do
    for tileCol = 0, tilesPerRow - 1 do
      local destCol = obj.flipH and (tilesPerRow - 1 - tileCol) or tileCol
      local destRow = obj.flipV and (rowsPerObj - 1 - tileRow) or tileRow
      blitTile(
        rgba,
        atlasWidth,
        obj.x - row.minX + destCol * 8,
        obj.y - row.minY + row.y + destRow * 8,
        charData,
        obj.tile + tileRow * tilesPerRow + tileCol,
        obj.palette,
        palette,
        obj.flipH,
        obj.flipV,
        source
      )
    end
  end
end

---@param romFs RomFs
---@param alias string
---@return Narc, string
local function loadArchive(romFs, alias)
  local info = must(romFs:resolvedNarc(alias), "unresolved NARC alias " .. alias)
  local archive = must(romFs:openNarc(alias), "failed to open " .. alias)
  return archive, must(romFs:read(info.fileId), "missing archive bytes " .. alias)
end

local function compileStartMenu(romFs, sha1hex, deps, assets, manifestAssets)
  local archive, archiveBytes = loadArchive(romFs, manifestConfig.startMenu.alias)
  local cfg = manifestConfig.startMenu
  local memberBytes = {}
  local function g2d(kind, memberId, label)
    memberBytes[memberId] = decodeMember(archive, memberId, label)
    local decoded, err =
      G2dDecoder[kind](memberBytes[memberId], { label = manifestConfig.startMenu.alias .. ":" .. memberId })
    return must(decoded, err)
  end
  local charData = g2d("decodeChar", cfg.backgroundCharMember, "start menu background char") --[[@as FieldUiCompiler.CharData]]
  local screen = g2d("decodeScreen", cfg.backgroundScreenMember, "start menu background screen") --[[@as FieldUiCompiler.ScreenData]]
  local pal = g2d("decodePalette", cfg.backgroundPaletteMember, "start menu background palette") --[[@as FieldUiCompiler.PaletteData]]
  local backgroundPath = FieldUiAssetCache.assetDir() .. "/start-menu.png"
  assets[backgroundPath] = renderScreen(charData, pal.colors, screen, {
    asset = "start menu background",
    member = cfg.backgroundScreenMember,
  })
  manifestAssets[FieldUiAssetCache.ASSET.START_MENU_BACKGROUND] = {
    image = backgroundPath,
    width = screen.width,
    height = screen.height,
  }

  local cursorChar = g2d("decodeChar", cfg.cursorCharMember, "start menu cursor char") --[[@as FieldUiCompiler.CharData]]
  local cursorPal = g2d("decodePalette", cfg.cursorPaletteMember, "start menu cursor palette") --[[@as FieldUiCompiler.PaletteData]]
  local cursorCell = g2d("decodeCell", cfg.cursorCellMember, "start menu cursor cell") --[[@as FieldUiCompiler.CellData]]
  local cursorAnim = g2d("decodeAnimation", cfg.cursorAnimMember, "start menu cursor animation") --[[@as FieldUiCompiler.AnimationData]]
  local anim = cursorAnim.anims[1]
  -- Stack every distinct cell the animation references; each frame points at
  -- its cell's row so a multi-cell cursor animates rather than repeating the
  -- first cell's sprite.
  local cellRows = {}
  local cursorFrames = {}
  local atlasWidth = 0
  local atlasHeight = 0
  for i, frame in ipairs(anim.frames) do
    local cell = cursorCell.cells[frame.cell + 1]
    if not cell then
      Errors.raise(FieldUiCompiler.ERROR.SOURCE_INVALID, "start menu cursor animation references a missing cell", {
        cell = frame.cell,
      })
    end
    local row = cellRows[frame.cell]
    if not row then
      local bounds = cellBounds(cell)
      row = { minX = bounds.x, minY = bounds.y, y = atlasHeight, width = bounds.width, height = bounds.height }
      atlasHeight = atlasHeight + row.height
      atlasWidth = math.max(atlasWidth, row.width)
      cellRows[frame.cell] = row
    end
    cursorFrames[i] = {
      x = 0,
      y = row.y,
      width = row.width,
      height = row.height,
      duration = frame.duration,
    }
  end
  local cursorPath = FieldUiAssetCache.assetDir() .. "/start-menu-cursor.png"
  local rgba = newRgba(atlasWidth, atlasHeight)
  for cellIndex, row in pairs(cellRows) do
    local objs = cursorCell.cells[cellIndex + 1].objs
    for objIndex, obj in ipairs(objs) do
      blitObj(rgba, atlasWidth, row, obj, cursorChar, cursorPal.colors, {
        asset = "start menu cursor",
        member = cfg.cursorCellMember,
        cell = cellIndex,
        obj = objIndex - 1,
      })
    end
  end
  assets[cursorPath] = PngWriter.encode(atlasWidth, atlasHeight, concatChars(rgba))
  manifestAssets[FieldUiAssetCache.ASSET.START_MENU_CURSOR] =
    { image = cursorPath, width = atlasWidth, height = atlasHeight }

  for _, memberId in ipairs({
    cfg.backgroundCharMember,
    cfg.backgroundScreenMember,
    cfg.backgroundPaletteMember,
    cfg.cursorPaletteMember,
    cfg.cursorCellMember,
    cfg.cursorAnimMember,
    cfg.cursorCharMember,
  }) do
    deps[#deps + 1] =
      { name = manifestConfig.startMenu.alias .. ":member:" .. memberId, sha1 = sha1hex(memberBytes[memberId]) }
  end
  deps[#deps + 1] = { name = manifestConfig.startMenu.alias .. ":narc", sha1 = sha1hex(archiveBytes) }

  return {
    background = { x = 0, y = 0, width = screen.width, height = screen.height },
    cursor = { frames = cursorFrames },
    slots = {
      [1] = { x = 0, y = 0, width = 128, height = 38 },
      [2] = { x = 128, y = 0, width = 128, height = 38 },
      [3] = { x = 0, y = 38, width = 128, height = 38 },
      [4] = { x = 128, y = 38, width = 128, height = 38 },
      [5] = { x = 0, y = 76, width = 128, height = 38 },
      [6] = { x = 128, y = 76, width = 128, height = 38 },
      [7] = { x = 0, y = 114, width = 128, height = 38 },
      [8] = { x = 128, y = 114, width = 128, height = 38 },
      [9] = { x = 0, y = 152, width = 128, height = 38 },
      [10] = { x = 128, y = 152, width = 128, height = 38 },
    },
    actionSurfaces = {
      ["vanilla.pokedex"] = { x = 0, y = 0, width = 128, height = 38 },
      ["vanilla.pokemon"] = { x = 128, y = 0, width = 128, height = 38 },
      ["vanilla.bag"] = { x = 0, y = 38, width = 128, height = 38 },
      ["vanilla.pokegear"] = { x = 128, y = 38, width = 128, height = 38 },
      ["vanilla.trainer_card"] = { x = 0, y = 76, width = 128, height = 38 },
      ["vanilla.save"] = { x = 128, y = 76, width = 128, height = 38 },
      ["vanilla.options"] = { x = 0, y = 114, width = 128, height = 38 },
    },
  }
end

local function compileDialogueFrames(romFs, sha1hex, deps, assets, manifestAssets)
  local archive, archiveBytes = loadArchive(romFs, manifestConfig.dialogueFrames.alias)
  local cfg = manifestConfig.dialogueFrames
  local tilesPath = FieldUiAssetCache.assetDir() .. "/dialogue-frame-tiles.png"
  -- Pack all frames: each frame's tiles in a row, frames stacked, each frame
  -- rendered with its own palette. The strip width is the fixed generated
  -- contract (18 tiles per frame in the real dump); a frame carrying any
  -- other count is malformed source the renderer could never place.
  local atlasWidth = FieldUiAssetCache.GEOMETRY.FRAME_TILES * 8
  local atlasHeight = cfg.frameCount * 8
  local rgba = newRgba(atlasWidth, atlasHeight)
  local frameTiles = {}
  local cursorCharBytes = decodeMember(archive, cfg.continueCursorMember, "dialogue continuation cursor")
  local cursorChar, cursorErr = G2dDecoder.decodeChar(cursorCharBytes, { label = "dialogue continuation cursor" })
  cursorChar = must(cursorChar, cursorErr)
  local cursorWidth = 48
  local cursorHeight = cfg.frameCount * 16
  local cursorRgba = newRgba(cursorWidth, cursorHeight)
  for frame = 0, cfg.frameCount - 1 do
    local frameCharBytes = decodeMember(archive, cfg.firstFrameMember + frame, "frame " .. frame .. " char")
    local framePalBytes = decodeMember(archive, cfg.firstPaletteMember + frame, "frame " .. frame .. " palette")
    local frameChar, charErr = G2dDecoder.decodeChar(frameCharBytes, { label = "frame " .. frame .. " char" })
    local framePal, palErr = G2dDecoder.decodePalette(framePalBytes, { label = "frame " .. frame .. " palette" })
    frameChar = must(frameChar, charErr)
    framePal = must(framePal, palErr)
    local tiles = math.floor(#frameChar.tiles / (frameChar.depth == 3 and 32 or 64))
    if tiles ~= FieldUiAssetCache.GEOMETRY.FRAME_TILES then
      Errors.raise(
        FieldUiCompiler.ERROR.SOURCE_INVALID,
        "dialogue frame " .. frame .. " must carry exactly " .. FieldUiAssetCache.GEOMETRY.FRAME_TILES .. " tiles",
        {
          frame = frame,
          member = cfg.firstFrameMember + frame,
          tiles = tiles,
        }
      )
    end
    for tile = 0, tiles - 1 do
      blitTile(rgba, atlasWidth, tile * 8, frame * 8, frameChar, tile, 0, framePal.colors, false, false, {
        asset = "dialogue frame " .. frame,
        member = cfg.firstFrameMember + frame,
      })
    end
    for phase = 0, 2 do
      composeCursorPhase(
        cursorRgba,
        cursorWidth,
        phase * 16,
        frame * 16,
        frameChar,
        framePal.colors,
        cursorChar,
        phase,
        { asset = "dialogue continuation cursor", member = cfg.continueCursorMember, frame = frame, phase = phase }
      )
    end
    frameTiles[frame] = { x = 0, y = frame * 8, width = atlasWidth, height = 8 }
    deps[#deps + 1] = {
      name = manifestConfig.dialogueFrames.alias .. ":member:" .. (cfg.firstFrameMember + frame),
      sha1 = sha1hex(frameCharBytes),
    }
    deps[#deps + 1] = {
      name = manifestConfig.dialogueFrames.alias .. ":palette:" .. (cfg.firstPaletteMember + frame),
      sha1 = sha1hex(framePalBytes),
    }
  end
  assets[tilesPath] = PngWriter.encode(atlasWidth, atlasHeight, concatChars(rgba))
  manifestAssets[FieldUiAssetCache.ASSET.DIALOGUE_FRAME_TILES] =
    { image = tilesPath, width = atlasWidth, height = atlasHeight }
  local cursorPath = FieldUiAssetCache.assetDir() .. "/dialogue-continue-cursor.png"
  assets[cursorPath] = PngWriter.encode(cursorWidth, cursorHeight, concatChars(cursorRgba))
  manifestAssets[FieldUiAssetCache.ASSET.DIALOGUE_CONTINUE_CURSOR] =
    { image = cursorPath, width = cursorWidth, height = cursorHeight }
  deps[#deps + 1] = { name = manifestConfig.dialogueFrames.alias .. ":narc", sha1 = sha1hex(archiveBytes) }
  deps[#deps + 1] = {
    name = manifestConfig.dialogueFrames.alias .. ":member:" .. cfg.continueCursorMember,
    sha1 = sha1hex(cursorCharBytes),
  }
  return {
    count = cfg.frameCount,
    frameTiles = frameTiles,
    continueCursor = {
      asset = FieldUiAssetCache.ASSET.DIALOGUE_CONTINUE_CURSOR,
      cycle = { 0, 1, 2, 1 },
      framePrinterTicks = 9,
      placement = { x = 240, y = 168, width = 16, height = 16 },
      styles = (function()
        local styles = {}
        for style = 0, cfg.frameCount - 1 do
          styles[style] = { phases = {} }
          for phase = 0, 2 do
            styles[style].phases[phase] = { x = phase * 16, y = style * 16, width = 16, height = 16 }
          end
        end
        return styles
      end)(),
    },
  }
end

local function compileSignposts(romFs, sha1hex, deps, assets, manifestAssets)
  local archive, archiveBytes = loadArchive(romFs, manifestConfig.signposts.alias)
  local cfg = manifestConfig.signposts
  local frameCharBytes = decodeMember(archive, cfg.frameMember, "signpost frame char")
  local framePalBytes = decodeMember(archive, cfg.paletteMember, "signpost frame palette")
  local frameChar, charErr = G2dDecoder.decodeChar(frameCharBytes, { label = "signpost frame char" })
  local framePal, palErr = G2dDecoder.decodePalette(framePalBytes, { label = "signpost frame palette" })
  frameChar = must(frameChar, charErr)
  framePal = must(framePal, palErr)
  local frameTiles = math.floor(#frameChar.tiles / (frameChar.depth == 3 and 32 or 64))
  if frameTiles ~= FieldUiAssetCache.GEOMETRY.FRAME_TILES then
    Errors.raise(
      FieldUiCompiler.ERROR.SOURCE_INVALID,
      "the signpost frame must carry exactly " .. FieldUiAssetCache.GEOMETRY.FRAME_TILES .. " tiles",
      {
        member = cfg.frameMember,
        tiles = frameTiles,
      }
    )
  end

  -- v5: extract per-source-type 16-color palette banks from the palette member.
  local function signPaletteBank(colors, sourceType)
    local base = sourceType * 16
    local bank = {}

    for slot = 0, 15 do
      local color = colors[base + slot + 1]
      if not color then
        Errors.raise(FieldUiCompiler.ERROR.SOURCE_INVALID, "signpost palette does not contain the source type bank", {
          sourceType = sourceType,
          slot = slot,
          requiredColorIndex = base + slot,
          availableColors = #colors,
        })
      end

      bank[slot] = {
        r = color.r,
        g = color.g,
        b = color.b,
      }
    end

    return bank
  end

  -- blitTile's palette argument is a 1-based array; the generated manifest
  -- keeps the clear zero-based slot map, so callers convert at the point of
  -- use.
  local function paletteAsOneBasedArray(bank)
    local array = {}
    for slot = 0, 15 do
      array[slot + 1] = bank[slot]
    end
    return array
  end

  -- v5: render one frame strip row per source type using its own palette.
  local frameRowYs = {}
  local frameAtlasHeight = #cfg.sourceTypes * 8
  local frameAtlasWidth = frameTiles * 8
  local frameRgba = newRgba(frameAtlasWidth, frameAtlasHeight)

  for rowIndex, sourceType in ipairs(cfg.sourceTypes) do
    local paletteOneBasedArray = paletteAsOneBasedArray(signPaletteBank(framePal.colors, sourceType))

    for tile = 0, frameTiles - 1 do
      blitTile(
        frameRgba,
        frameAtlasWidth,
        tile * 8,
        (rowIndex - 1) * 8,
        frameChar,
        tile,
        0,
        paletteOneBasedArray,
        false,
        false,
        {
          asset = "signpost frame",
          member = cfg.frameMember,
          sourceType = sourceType,
        }
      )
    end

    frameRowYs[sourceType] = (rowIndex - 1) * 8
  end

  local framePath = FieldUiAssetCache.assetDir() .. "/signpost-tiles.png"
  assets[framePath] = PngWriter.encode(frameAtlasWidth, frameAtlasHeight, concatChars(frameRgba))
  manifestAssets[FieldUiAssetCache.ASSET.SIGNPOST_TILES] =
    { image = framePath, width = frameAtlasWidth, height = frameAtlasHeight }

  -- The whole-archive hash intentionally invalidates on any signpost member
  -- change; the per-wayfinding-member hashes below additionally pin each
  -- selected (type, map) row individually.
  deps[#deps + 1] = { name = manifestConfig.signposts.alias .. ":narc", sha1 = sha1hex(archiveBytes) }

  -- Wayfinding: each selected (type, map) member precomposed into a
  -- final 48x32 surface (6 columns x 4 rows, 8px per tile). Every member
  -- is pinned to the fixed 24-tile contract, so the final geometry is
  -- fixed and the atlas stacks one 48x32 entry per pair.
  local wayfindingPath = FieldUiAssetCache.assetDir() .. "/wayfinding-tiles.png"
  local wayfinding = {}
  local rows = {}
  local wayfindingTypes = {}
  for sourceType in pairs(cfg.wayfinding) do
    wayfindingTypes[#wayfindingTypes + 1] = sourceType
  end
  table.sort(wayfindingTypes)
  for _, sourceType in ipairs(wayfindingTypes) do
    local spec = cfg.wayfinding[sourceType]
    for _, map in ipairs(spec.maps) do
      local member = spec.memberBase + map
      local key = sourceType .. "." .. map
      local wfBytes = decodeMember(archive, member, "wayfinding " .. key)
      local wfChar, wfErr = G2dDecoder.decodeChar(wfBytes, { label = "wayfinding " .. key })
      wfChar = must(wfChar, wfErr)
      local tiles = math.floor(#wfChar.tiles / (wfChar.depth == 3 and 32 or 64))
      if tiles ~= FieldUiAssetCache.GEOMETRY.WAYFINDING_TILES then
        Errors.raise(
          FieldUiCompiler.ERROR.SOURCE_INVALID,
          "wayfinding member "
            .. member
            .. " must carry exactly "
            .. FieldUiAssetCache.GEOMETRY.WAYFINDING_TILES
            .. " tiles",
          {
            member = member,
            tiles = tiles,
          }
        )
      end
      rows[#rows + 1] = { key = key, sourceType = sourceType, member = member, bytes = wfBytes, char = wfChar }
    end
  end
  local finalWidth = FieldUiAssetCache.GEOMETRY.WAYFINDING_WIDTH
  local finalHeight = FieldUiAssetCache.GEOMETRY.WAYFINDING_HEIGHT
  local atlasHeight = #rows * finalHeight
  local rgba = newRgba(finalWidth, atlasHeight)
  for index, row in ipairs(rows) do
    local wfChar = row.char
    local paletteOneBasedArray = paletteAsOneBasedArray(signPaletteBank(framePal.colors, row.sourceType))

    for tile = 0, FieldUiAssetCache.GEOMETRY.WAYFINDING_TILES - 1 do
      local destCol = tile % FieldUiAssetCache.GEOMETRY.WAYFINDING_COLUMNS
      local destRow = math.floor(tile / FieldUiAssetCache.GEOMETRY.WAYFINDING_COLUMNS)
      blitTile(
        rgba,
        finalWidth,
        destCol * 8,
        (index - 1) * finalHeight + destRow * 8,
        wfChar,
        tile,
        0,
        paletteOneBasedArray,
        false,
        false,
        {
          asset = "wayfinding " .. row.key,
          member = row.member,
        }
      )
    end
    wayfinding[row.key] = { x = 0, y = (index - 1) * finalHeight, width = finalWidth, height = finalHeight }
    deps[#deps + 1] = {
      name = manifestConfig.signposts.alias .. ":wayfinding:" .. row.key,
      sha1 = sha1hex(row.bytes),
    }
  end
  assets[wayfindingPath] = PngWriter.encode(finalWidth, atlasHeight, concatChars(rgba))
  manifestAssets[FieldUiAssetCache.ASSET.SIGNPOST_WAYFINDING] =
    { image = wayfindingPath, width = finalWidth, height = atlasHeight }

  local types = {}
  for _, sourceType in ipairs(cfg.sourceTypes) do
    local typeEntry = { sourceType = sourceType }

    -- v5: include per-type palette bank.
    typeEntry.palette = signPaletteBank(framePal.colors, sourceType)

    -- v5: include per-type frameTiles.
    typeEntry.frameTiles = {
      x = 0,
      y = frameRowYs[sourceType],
      width = frameAtlasWidth,
      height = 8,
    }

    local spec = cfg.wayfinding[sourceType]
    if spec then
      local mapRects = {}
      for _, map in ipairs(spec.maps) do
        mapRects[map] = wayfinding[sourceType .. "." .. map]
      end
      typeEntry.wayfinding = mapRects
    end
    types[sourceType] = typeEntry
  end
  return {
    textColors = { foreground = 2, shadow = 10, background = 15 },
    types = types,
  }
end

local function compileTrainerCard(romFs, sha1hex, deps, assets, manifestAssets)
  local archive, archiveBytes = loadArchive(romFs, manifestConfig.trainerCard.alias)
  local cfg = manifestConfig.trainerCard
  local charBytes = decodeMember(archive, cfg.frontCharMember, "card char")
  local charData, charErr = G2dDecoder.decodeChar(charBytes, { label = "card char" })
  charData = must(charData, charErr)
  local screenBytes = decodeMember(archive, cfg.frontScreenMember, "card screen")
  local screen, screenErr = G2dDecoder.decodeScreen(screenBytes, { label = "card screen" })
  screen = must(screen, screenErr)
  local palBytes = decodeMember(archive, cfg.frontPaletteMember, "card palette")
  local pal, palErr = G2dDecoder.decodePalette(palBytes, { label = "card palette" })
  pal = must(pal, palErr)
  local path = FieldUiAssetCache.assetDir() .. "/trainer-card.png"
  assets[path] = renderScreen(charData, pal.colors, screen, {
    asset = "trainer card front",
    member = cfg.frontScreenMember,
  })
  manifestAssets[FieldUiAssetCache.ASSET.TRAINER_CARD_FRONT] =
    { image = path, width = screen.width, height = screen.height }
  deps[#deps + 1] = { name = manifestConfig.trainerCard.alias .. ":narc", sha1 = sha1hex(archiveBytes) }
  return {
    front = { x = 0, y = 0, width = screen.width, height = screen.height },
  }
end

local function compileAll(romFs, sha1hex, hashLua)
  local assets = {}
  local manifestAssets = {}
  local deps = {
    { name = "assetContract", sha1 = FieldUiAssetCache.FORMAT .. ":" .. FieldUiAssetCache.SCHEMA },
  }
  local startMenu = compileStartMenu(romFs, sha1hex, deps, assets, manifestAssets)
  local dialogueFrames = compileDialogueFrames(romFs, sha1hex, deps, assets, manifestAssets)
  local signposts = compileSignposts(romFs, sha1hex, deps, assets, manifestAssets)
  local trainerCard = compileTrainerCard(romFs, sha1hex, deps, assets, manifestAssets)

  local manifest = {
    schema = FieldUiAssetCache.SCHEMA,
    reference = { width = 256, height = 192 },
    assets = manifestAssets,
    dialogueFrames = dialogueFrames,
    signposts = signposts,
    startMenu = startMenu,
    trainerCard = trainerCard,
  }
  local ok, err = FieldUiAssetCache.validateManifest(manifest)
  if not ok then
    error(err, 0)
  end
  local marker = FieldUiAssetCache.marker(romFs:metadata().sha1, hashLua(deps))
  return {
    marker = marker,
    manifest = manifest,
    assets = assets,
    dependencies = deps,
  }
end

---@param romFs RomFs
---@param sha1hex? fun(bytes: string): string|nil
---@param hashLua? fun(value: unknown): string|nil
---@return table<string, unknown>|nil bundle
---@return Errors.Error?
function FieldUiCompiler.compile(romFs, sha1hex, hashLua)
  assert(romFs and romFs.read and romFs.openNarc and romFs.resolvedNarc, "compile requires a RomFs-shaped object")
  sha1hex = sha1hex or Hashing.sha1hex
  hashLua = hashLua or Hashing.hashLua
  local ok, result = xpcall(compileAll, function(e)
    if Errors.is(e) then
      return e
    end
    return { raw = e, trace = debug.traceback("", 2) }
  end, romFs, sha1hex, hashLua)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  if type(result) == "table" and result.trace then
    error(result.raw, 0)
  end
  error(result, 0)
end

return FieldUiCompiler
