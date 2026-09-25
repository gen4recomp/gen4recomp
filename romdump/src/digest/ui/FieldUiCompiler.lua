-- Compiles the generated HGSS field-UI class: the Start Menu icon-sprite
-- contract (one shared icon atlas with normal/selected visuals, palette
-- record, icon table, contexts, chrome, and the seven interactive position
-- records) and cursor, the twenty user dialogue frames, the corpus
-- signpost frame and wayfinding graphics, the Trainer Card front, the
-- compact two-row choice prompt buttons, and the
-- normal naming screen chrome (one opaque base, the three transparent page
-- overlays, static controls/slots, full generated subject/cursor animations
-- with entry-29 pulse masks) — all as decoded PNG atlases and the strict manifest. Wayfinding members are precomposed
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
---@alias FieldUiCompiler.SourceRef { asset: string, member: integer }
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

-- Authoritative raw source-pixel reader: one interpretation of 4bpp/8bpp
-- tile data shared by ordinary blits. 4bpp
-- tiles hold two pixel values per byte (low nibble first); 8bpp tiles hold
-- one. A tile index beyond the decoded tiles is malformed source, never
-- silent transparency. `source` names the asset/member/cell/obj that
-- produced the reference for the typed error context.
---@param charData FieldUiCompiler.CharData
---@param tileIndex integer
---@param x integer
---@param y integer
---@param source FieldUiCompiler.SourceRef
---@return integer
local function tilePixelIndex(charData, tileIndex, x, y, source)
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
  local base = tileIndex * tileBytes
  if depth == 3 then
    local byte = string.byte(charData.tiles, base + y * 4 + math.floor(x / 2) + 1)
    if x % 2 == 0 then
      return byte % 16
    end
    return math.floor(byte / 16)
  end
  return string.byte(charData.tiles, base + y * 8 + x + 1)
end

-- Blit one tile's pixels into an RGBA buffer. Pixel value 0 is
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
  for y = 0, 7 do
    for x = 0, 7 do
      put(x, y, tilePixelIndex(charData, tileIndex, x, y, source))
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

-- Compose one 16x16 continuation phase the way the source window code
-- does (pret/pokeheartgold sub_0200EA68 -> sub_0200EA24 ->
-- BlitBitmapRect4Bit): frame tiles 10 and 11 supply the backing, then the
-- cursor payload is blitted from source columns 3..15 onto destination
-- columns 0..12 with palette index 0 transparent. The phase block holds
-- its 2x2 tiles row-major, so source column 3 starts mid-tile.
local function blitCursorPayload(rgba, atlasWidth, destX, destY, cursorChar, phase, palIndex, colors, source)
  local depth = cursorChar.depth
  local tileBytes = depth == 3 and 32 or 64
  local tileCount = math.floor(#cursorChar.tiles / tileBytes)
  local baseTile = phase * 4
  if baseTile < 0 or baseTile + 3 >= tileCount then
    Errors.raise(
      FieldUiCompiler.ERROR.SOURCE_INVALID,
      "cursor phase references tiles beyond the decoded char data",
      { phase = phase, available = tileCount, source = source }
    )
  end
  local palBase = depth == 3 and palIndex * 16 or palIndex * 256
  for y = 0, 15 do
    for dx = 0, 12 do
      local sx = dx + 3
      local tile = baseTile + math.floor(y / 8) * 2 + math.floor(sx / 8)
      local lx, ly = sx % 8, y % 8
      local base = tile * tileBytes
      local v
      if depth == 3 then
        local byte = string.byte(cursorChar.tiles, base + ly * 4 + math.floor(lx / 2) + 1)
        if lx % 2 == 0 then
          v = byte % 16
        else
          v = math.floor(byte / 16)
        end
      else
        v = string.byte(cursorChar.tiles, base + ly * 8 + lx + 1)
      end
      if v ~= 0 then
        local c = colors[palBase + v + 1]
        if not c then
          Errors.raise(
            FieldUiCompiler.ERROR.SOURCE_INVALID,
            "pixel references a palette entry the decoded palette cannot cover",
            { value = v, palette = palIndex, available = #colors, source = source }
          )
        end
        local px = ((destY + y) * atlasWidth + destX + dx) * 4
        rgba[px + 1], rgba[px + 2], rgba[px + 3], rgba[px + 4] = c.r, c.g, c.b, 255
      end
    end
  end
end

-- Compose the 16x16 continuation surface exactly as the source window code
-- does: the cursor member supplies the phase payload, while frame tiles 10
-- and 11 provide the backing that surrounds that payload.
local function composeCursorPhase(rgba, atlasWidth, destX, destY, frameChar, framePalette, cursorChar, phase, source)
  for row = 0, 1 do
    blitTile(rgba, atlasWidth, destX, destY + row * 8, frameChar, 10, 0, framePalette, false, false, source)
    blitTile(rgba, atlasWidth, destX + 8, destY + row * 8, frameChar, 11, 0, framePalette, false, false, source)
  end
  blitCursorPayload(rgba, atlasWidth, destX, destY, cursorChar, phase, 0, framePalette, source)
end

-- Render a screen (BG tilemap with flips) into a PNG. Generic decoded-tile
-- raster mechanics live in G2dRasterizer; this wrapper only feeds its pixels
-- into the existing PNG/publication path unchanged.
local function renderScreen(charData, palette, screen, source, options)
  local image = G2dRasterizer.renderScreen(charData, { colors = palette }, screen, source, options)
  return PngWriter.encode(image.width, image.height, image.pixels)
end

-- Paint the retail keyboard fill into one rasterized naming page: the
-- page-local window first takes the page frame slot over its full extent,
-- then the grid cells take the companion slot wherever (row + column)
-- parity is odd. Both slots resolve through palette bank 1: retail opens
-- the keyboard windows with palette 1 (AddWindowParameterized ... 1 ...)
-- and NamingScreen_DrawKeyboardOnWindow fills raw 4bpp values
-- (sKeyboardFrameColors/sKeyboardFillValues) into that window, so value v
-- displays as bank-1 slot v. The window holds five row-height rows inside
-- its full height, so the final bottom pixel row keeps the frame slot. A
-- window that leaves the page, or frame/companion slots the palette cannot
-- serve, is corrupt source, never a silent clip or substitute color.
---@param image { width: integer, height: integer, pixels: string }
---@param window { x: integer, y: integer, width: integer, height: integer, columns: integer, rows: integer, cellWidth: integer, rowHeight: integer, textInsetY: integer }
---@param role { base: integer, alternate: integer }
---@param colors { r: integer, g: integer, b: integer }[]
---@param pageKey string
---@return string PNG bytes for the composed page
local function composeNamingPageWindow(image, window, role, colors, pageKey)
  if
    window.x < 0
    or window.y < 0
    or window.x + window.width > image.width
    or window.y + window.height > image.height
  then
    Errors.raise(
      FieldUiCompiler.ERROR.SOURCE_INVALID,
      "the naming keyboard window must fit its page raster",
      { page = pageKey, width = image.width, height = image.height }
    )
  end
  -- The keyboard window carries palette bank 1 (retail opens both keyboard
  -- windows with palette param 1), so frame/fill values resolve at
  -- bank-1 slot v (colors[16 + v + 1]), never bank 0.
  local bankBase = 16
  local base = colors[bankBase + role.base + 1]
  local alternate = colors[bankBase + role.alternate + 1]
  if base == nil or alternate == nil then
    Errors.raise(FieldUiCompiler.ERROR.SOURCE_INVALID, "the naming palette must serve the keyboard window slots", {
      page = pageKey,
      bank = 1,
      base = role.base,
      alternate = role.alternate,
      available = #colors,
    })
  end
  assert(base ~= nil and alternate ~= nil, "missing keyboard window slots fail above")
  local bytes = {}
  do
    local raw = image.pixels
    for i = 1, #raw, 4096 do
      local chunk = { string.byte(raw, i, math.min(i + 4095, #raw)) }
      for j = 1, #chunk do
        bytes[#bytes + 1] = chunk[j]
      end
    end
  end
  local function setPixel(x, y, color)
    local offset = (y * image.width + x) * 4
    bytes[offset + 1], bytes[offset + 2], bytes[offset + 3], bytes[offset + 4] = color.r, color.g, color.b, 255
  end
  for y = window.y, window.y + window.height - 1 do
    for x = window.x, window.x + window.width - 1 do
      setPixel(x, y, base)
    end
  end
  for row = 0, window.rows - 1 do
    for column = 0, window.columns - 1 do
      if (row + column) % 2 == 1 then
        for y = window.y + row * window.rowHeight, window.y + (row + 1) * window.rowHeight - 1 do
          for x = window.x + column * window.cellWidth, window.x + (column + 1) * window.cellWidth - 1 do
            setPixel(x, y, alternate)
          end
        end
      end
    end
  end
  return PngWriter.encode(image.width, image.height, concatChars(bytes))
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

-- The Start Menu MAIN BG triple is chrome, not entry art: source-zero
-- pixels stay transparent, so only the bottom-panel band survives into the
-- generated main-chrome image.
local function compileStartMenuMain(sha1hex, deps, assets, manifestAssets, archive, memberBytes)
  local cfg = manifestConfig.startMenu
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
  for _, memberId in ipairs({ cfg.backgroundCharMember, cfg.backgroundScreenMember, cfg.backgroundPaletteMember }) do
    deps[#deps + 1] =
      { name = manifestConfig.startMenu.alias .. ":member:" .. memberId, sha1 = sha1hex(memberBytes[memberId]) }
  end
  return { x = 0, y = 0, width = screen.width, height = screen.height }
end

-- The SUB background set behind the entry windows, compiled like any other
-- source screen with source-zero transparency.
local function compileStartMenuSub(sha1hex, deps, assets, manifestAssets, archive, memberBytes)
  local cfg = manifestConfig.startMenu
  local function g2d(kind, memberId, label)
    memberBytes[memberId] = decodeMember(archive, memberId, label)
    local decoded, err =
      G2dDecoder[kind](memberBytes[memberId], { label = manifestConfig.startMenu.alias .. ":" .. memberId })
    return must(decoded, err)
  end
  local charData = g2d("decodeChar", cfg.subBackgroundCharMember, "start menu sub background char") --[[@as FieldUiCompiler.CharData]]
  local screen = g2d("decodeScreen", cfg.subBackgroundScreenMember, "start menu sub background screen") --[[@as FieldUiCompiler.ScreenData]]
  local pal = g2d("decodePalette", cfg.subBackgroundPaletteMember, "start menu sub background palette") --[[@as FieldUiCompiler.PaletteData]]
  local subPath = FieldUiAssetCache.assetDir() .. "/start-menu-chrome-sub.png"
  assets[subPath] = renderScreen(charData, pal.colors, screen, {
    asset = "start menu sub background",
    member = cfg.subBackgroundScreenMember,
  })
  manifestAssets[FieldUiAssetCache.ASSET.START_MENU_CHROME_SUB] =
    { image = subPath, width = screen.width, height = screen.height }
  for _, memberId in ipairs({
    cfg.subBackgroundCharMember,
    cfg.subBackgroundScreenMember,
    cfg.subBackgroundPaletteMember,
  }) do
    deps[#deps + 1] =
      { name = manifestConfig.startMenu.alias .. ":member:" .. memberId, sha1 = sha1hex(memberBytes[memberId]) }
  end
  return pal
end

-- The shared icon atlas: every sprite char the icon rows (and the Bag
-- female variant) reference, composed through the shared cell/animation
-- rasterizer. Each char contributes its stable normal frame plus the same
-- frame through the selection palette bank; the returned map carries each
-- char's atlas rects with the rasterizer's source-relative offsets. Frames
-- pack deterministically left to right in icon-row order (normal, selected,
-- then the female normal/selected pair), so the manifest boundary is stable
-- for a fixed source.
local function compileStartMenuIcons(sha1hex, deps, assets, manifestAssets, archive, memberBytes)
  local cfg = manifestConfig.startMenu
  local function g2d(kind, memberId, label)
    memberBytes[memberId] = decodeMember(archive, memberId, label)
    local decoded, err =
      G2dDecoder[kind](memberBytes[memberId], { label = manifestConfig.startMenu.alias .. ":" .. memberId })
    return must(decoded, err)
  end
  local iconCell = g2d("decodeCell", cfg.iconCellMember, "start menu icon cell") --[[@as FieldUiCompiler.CellData]]
  local iconAnim = g2d("decodeAnimation", cfg.iconAnimMember, "start menu icon animation") --[[@as FieldUiCompiler.AnimationData]]
  local iconPal = g2d("decodePalette", cfg.iconPaletteMember, "start menu icon palette") --[[@as FieldUiCompiler.PaletteData]]
  local animation = iconAnim.anims[cfg.iconAnim + 1]
  if animation == nil then
    Errors.raise(FieldUiCompiler.ERROR.SOURCE_INVALID, "start menu icon animation bank has no animation", {
      anim = cfg.iconAnim,
      available = #iconAnim.anims,
    })
  end
  assert(animation ~= nil, "missing icon animations fail above")
  if animation.frames[1] == nil then
    Errors.raise(FieldUiCompiler.ERROR.SOURCE_INVALID, "start menu icon animation carries no stable frame", {
      anim = cfg.iconAnim,
    })
  end

  local composed = {}
  for _, memberId in ipairs(cfg.iconCharMembers) do
    local charData = g2d("decodeChar", memberId, "start menu icon char") --[[@as FieldUiCompiler.CharData]]
    local tileBytes = charData.depth == 3 and 32 or 64
    local tiles = math.floor(#charData.tiles / tileBytes)
    if tiles ~= 20 then
      Errors.raise(FieldUiCompiler.ERROR.SOURCE_INVALID, "start menu icon char must carry exactly 20 tiles", {
        member = memberId,
        tiles = tiles,
      })
    end
    local source = { asset = "start menu icon", member = memberId }
    local normal =
      G2dRasterizer.renderAnimationFrame(charData, { colors = iconPal.colors }, iconCell, animation, 1, source)
    local selected = G2dRasterizer.renderAnimationFrame(
      charData,
      { colors = iconPal.colors },
      iconCell,
      animation,
      1,
      source,
      cfg.iconSelectedPalette
    )
    for _, frame in ipairs({ normal, selected }) do
      assert(
        type(frame.offset.x) == "number"
          and frame.offset.x % 1 == 0
          and type(frame.offset.y) == "number"
          and frame.offset.y % 1 == 0,
        "the icon compositor must return an integral source-relative offset"
      )
    end
    composed[memberId] = { normal = normal, selected = selected }
  end

  -- Deterministic packing in icon-row order: each sprite row's normal then
  -- selected frame, followed by the female variant pair when the row carries
  -- one. Every frame keeps its compositor size and offset; the atlas is the
  -- tight row of those frames.
  local ordered = {}
  local visuals = {}
  for _, row in ipairs(cfg.iconRows) do
    if row.art == "sprite" then
      local frames = assert(composed[row.char], "icon row references an uncompiled char")
      local visual = { normal = { frame = frames.normal }, selected = { frame = frames.selected } }
      ordered[#ordered + 1] = visual.normal
      ordered[#ordered + 1] = visual.selected
      visuals[row.char] = visual
      if row.femaleChar then
        local female = assert(composed[row.femaleChar], "icon row references an uncompiled female char")
        local variant = { normal = { frame = female.normal }, selected = { frame = female.selected } }
        ordered[#ordered + 1] = variant.normal
        ordered[#ordered + 1] = variant.selected
        visuals[row.femaleChar] = variant
      end
    end
  end
  local atlasWidth, atlasHeight = 0, 0
  for _, entry in ipairs(ordered) do
    atlasWidth = atlasWidth + entry.frame.width
    atlasHeight = math.max(atlasHeight, entry.frame.height)
  end
  do
    local x = 0
    for _, entry in ipairs(ordered) do
      local frame = entry.frame
      entry.rect = { x = x, y = 0, width = frame.width, height = frame.height }
      entry.offset = { x = frame.offset.x, y = frame.offset.y }
      x = x + frame.width
    end
  end
  local rows = {}
  for y = 0, atlasHeight - 1 do
    for _, entry in ipairs(ordered) do
      local frame = entry.frame
      if y < frame.height then
        rows[#rows + 1] = frame.pixels:sub(y * frame.width * 4 + 1, (y + 1) * frame.width * 4)
      else
        rows[#rows + 1] = string.rep(string.char(0, 0, 0, 0), frame.width * 4)
      end
    end
  end
  for _, entry in ipairs(ordered) do
    entry.frame = nil
  end

  local iconsPath = FieldUiAssetCache.assetDir() .. "/start-menu-icons.png"
  assets[iconsPath] = PngWriter.encode(atlasWidth, atlasHeight, table.concat(rows))
  manifestAssets[FieldUiAssetCache.ASSET.START_MENU_ICONS] =
    { image = iconsPath, width = atlasWidth, height = atlasHeight }
  for _, entry in ipairs(ordered) do
    entry.asset = FieldUiAssetCache.ASSET.START_MENU_ICONS
  end

  -- The shared palette record as pixels: bank 0 and the selection bank 1 in
  -- two 16-color rows, so the generated class carries the exact highlight
  -- source the visuals were rendered through. A palette member short of
  -- both banks is malformed source, never a truncated record.
  for _, bank in ipairs({ 0, 1 }) do
    if iconPal.colors[bank * 16 + 16] == nil then
      Errors.raise(FieldUiCompiler.ERROR.SOURCE_INVALID, "start menu icon palette does not contain the bank", {
        member = cfg.iconPaletteMember,
        bank = bank,
        available = #iconPal.colors,
      })
    end
  end
  local paletteRgba = {}
  for bank = 0, 1 do
    for slot = 0, 15 do
      local color = iconPal.colors[bank * 16 + slot + 1]
      paletteRgba[#paletteRgba + 1] = string.char(color.r, color.g, color.b, 255)
    end
  end
  local palettePath = FieldUiAssetCache.assetDir() .. "/start-menu-icon-palette.png"
  assets[palettePath] = PngWriter.encode(16, 2, table.concat(paletteRgba))
  manifestAssets[FieldUiAssetCache.ASSET.START_MENU_ICON_PALETTE] = { image = palettePath, width = 16, height = 2 }

  for _, memberId in ipairs(cfg.iconCharMembers) do
    deps[#deps + 1] =
      { name = manifestConfig.startMenu.alias .. ":member:" .. memberId, sha1 = sha1hex(memberBytes[memberId]) }
  end
  for _, memberId in ipairs({ cfg.iconCellMember, cfg.iconAnimMember, cfg.iconPaletteMember }) do
    deps[#deps + 1] =
      { name = manifestConfig.startMenu.alias .. ":member:" .. memberId, sha1 = sha1hex(memberBytes[memberId]) }
  end
  return visuals
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
  local background = compileStartMenuMain(sha1hex, deps, assets, manifestAssets, archive, memberBytes)
  local subPalette = compileStartMenuSub(sha1hex, deps, assets, manifestAssets, archive, memberBytes)
  local iconVisuals = compileStartMenuIcons(sha1hex, deps, assets, manifestAssets, archive, memberBytes)

  -- The label roles are source palette slots, not font colors: the label
  -- windows live on the SUB background's palette bank 4, so foreground 14,
  -- shadow 2, and background 0 resolve through that bank of the SUB palette
  -- resource (colors is 1-based, so bank b slot s sits at b*16+s+1). The
  -- background keeps its source RGB but carries zero alpha: at runtime the
  -- glyph background-class pixels reveal the already-rendered chrome
  -- instead of repainting it.
  local function labelSlot(slot)
    local color = subPalette.colors[4 * 16 + slot + 1]
    if color == nil then
      Errors.raise(FieldUiCompiler.ERROR.SOURCE_INVALID, "start menu SUB palette does not contain the label bank", {
        member = cfg.subBackgroundPaletteMember,
        bank = 4,
        slot = slot,
        available = #subPalette.colors,
      })
    end
    return assert(color)
  end
  local labelForeground = labelSlot(14)
  local labelShadow = labelSlot(2)
  local labelBackground = labelSlot(0)
  local labelPalette = {
    foreground = { r = labelForeground.r, g = labelForeground.g, b = labelForeground.b, a = 1 },
    shadow = { r = labelShadow.r, g = labelShadow.g, b = labelShadow.b, a = 1 },
    background = { r = labelBackground.r, g = labelBackground.g, b = labelBackground.b, a = 0 },
  }

  -- The thirteen retail icon rows as source-independent data: sprite rows
  -- carry the composed normal/selected visual records (the Bag row carries
  -- the conditional female pair as a first-class variant), text and
  -- poke-icon rows carry no art. Labels are bank ids; the trainer-card row
  -- is the live player name placeholder, never baked text.
  local iconTable = {}
  for index, row in ipairs(cfg.iconRows) do
    local entry = { art = row.art, label = row.label, labelKind = row.labelKind }
    if row.art == "sprite" then
      entry.visual = assert(iconVisuals[row.char], "icon row " .. index .. " references an uncompiled char")
      if row.femaleChar then
        entry.variants = {
          female = assert(iconVisuals[row.femaleChar], "icon row " .. index .. " references an uncompiled char"),
        }
      end
    end
    iconTable[index] = entry
  end

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
    cfg.cursorPaletteMember,
    cfg.cursorCellMember,
    cfg.cursorAnimMember,
    cfg.cursorCharMember,
  }) do
    deps[#deps + 1] =
      { name = manifestConfig.startMenu.alias .. ":member:" .. memberId, sha1 = sha1hex(memberBytes[memberId]) }
  end
  deps[#deps + 1] = { name = manifestConfig.startMenu.alias .. ":narc", sha1 = sha1hex(archiveBytes) }

  local contexts = {}
  for index, row in ipairs(cfg.contexts) do
    local entries = {}
    for slot, icon in ipairs(row) do
      entries[slot] = icon
    end
    contexts[index] = entries
  end

  -- The seven normal selector positions as source-independent records: the
  -- action anchor, label window, touch region, and ordered directional
  -- candidates per display position, plus the cancel/header touch bound.
  local positions = {}
  for position = 0, 6 do
    local anchor = assert(cfg.actionAnchors[position], "the start menu config must anchor position " .. position)
    local labelWindow = assert(cfg.labelWindows[position], "the start menu config must label position " .. position)
    local hitRect = assert(cfg.touchRegions[position], "the start menu config must bound position " .. position)
    local navigation =
      assert(cfg.navigationCandidates[position], "the start menu config must navigate position " .. position)
    positions[position] = {
      anchor = { x = anchor.x, y = anchor.y },
      labelWindow = { x = labelWindow.x, y = labelWindow.y, width = labelWindow.width, height = labelWindow.height },
      hitRect = { x = hitRect.x, y = hitRect.y, width = hitRect.width, height = hitRect.height },
      navigation = {
        up = { navigation.up[1], navigation.up[2], navigation.up[3] },
        down = { navigation.down[1], navigation.down[2], navigation.down[3] },
        left = { navigation.left[1], navigation.left[2], navigation.left[3] },
        right = { navigation.right[1], navigation.right[2], navigation.right[3] },
      },
    }
  end

  local actionIcons = {}
  for actionId, icon in pairs(cfg.actionIcons) do
    actionIcons[actionId] = icon
  end

  return {
    background = background,
    cursor = { frames = cursorFrames },
    interactive = {
      cancelHitRect = {
        x = cfg.cancelTouchRegion.x,
        y = cfg.cancelTouchRegion.y,
        width = cfg.cancelTouchRegion.width,
        height = cfg.cancelTouchRegion.height,
      },
      positions = positions,
    },
    iconTable = iconTable,
    contexts = contexts,
    actionIcons = actionIcons,
    iconPalette = {
      asset = FieldUiAssetCache.ASSET.START_MENU_ICON_PALETTE,
      banks = 2,
      selectionBank = 2,
    },
    labelPalette = labelPalette,
    chrome = {
      main = { asset = FieldUiAssetCache.ASSET.START_MENU_BACKGROUND, transparentAboveY = 136 },
      sub = { asset = FieldUiAssetCache.ASSET.START_MENU_CHROME_SUB },
    },
  }
end

-- Dialogue frames use the fixed 18-tile HGSS frame grid: six conceptual
-- columns by three rows, blitted once into the single dialogue strip.
local function compileDialogueFrames(romFs, sha1hex, deps, assets, manifestAssets)
  local archive, archiveBytes = loadArchive(romFs, manifestConfig.dialogueFrames.alias)
  local cfg = manifestConfig.dialogueFrames
  local tilesPath = FieldUiAssetCache.assetDir() .. "/dialogue-frame-tiles.png"
  -- Pack all frames: each frame's tiles in a row, frames stacked, each frame
  -- rendered with its own palette. The strip width is the fixed generated
  -- contract (18 tiles per frame in the real dump); a frame carrying any
  -- other count is malformed source the renderer could never place.
  local atlasWidth = FieldUiAssetCache.GEOMETRY.FRAME_TILES * 8
  local atlasHeight = (cfg.frameCount + 1) * 8
  local rgba = newRgba(atlasWidth, atlasHeight)
  local frameTiles = {}
  local palettes = {}
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
    if #framePal.colors < 16 then
      Errors.raise(
        FieldUiCompiler.ERROR.SOURCE_INVALID,
        "dialogue frame " .. frame .. " palette must contain 16 colors",
        { frame = frame, colors = #framePal.colors }
      )
    end
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
    local palette = {}
    for slot = 0, 15 do
      palette[slot] = framePal.colors[slot + 1]
    end
    palettes[frame] = palette
    deps[#deps + 1] = {
      name = manifestConfig.dialogueFrames.alias .. ":member:" .. (cfg.firstFrameMember + frame),
      sha1 = sha1hex(frameCharBytes),
    }
    deps[#deps + 1] = {
      name = manifestConfig.dialogueFrames.alias .. ":palette:" .. (cfg.firstPaletteMember + frame),
      sha1 = sha1hex(framePalBytes),
    }
  end
  local standardCharBytes = decodeMember(archive, cfg.standardFrameMember, "standard Yes/No frame char")
  local standardPaletteBytes = decodeMember(archive, cfg.standardPaletteMember, "standard Yes/No frame palette")
  local standardChar, standardCharErr = G2dDecoder.decodeChar(standardCharBytes, {
    label = "standard Yes/No frame char",
  })
  local standardPalette, standardPaletteErr = G2dDecoder.decodePalette(standardPaletteBytes, {
    label = "standard Yes/No frame palette",
  })
  standardChar = must(standardChar, standardCharErr)
  standardPalette = must(standardPalette, standardPaletteErr)
  if standardChar.depth ~= 3 then
    Errors.raise(
      FieldUiCompiler.ERROR.SOURCE_INVALID,
      "standard Yes/No frame must use 4bpp tiles",
      { member = cfg.standardFrameMember, depth = standardChar.depth }
    )
  end
  local standardTileCount = math.floor(#standardChar.tiles / (standardChar.depth == 3 and 32 or 64))
  if standardTileCount ~= 9 then
    Errors.raise(
      FieldUiCompiler.ERROR.SOURCE_INVALID,
      "standard Yes/No frame must carry exactly 9 tiles",
      { member = cfg.standardFrameMember, tiles = standardTileCount }
    )
  end
  if #standardPalette.colors < 16 then
    Errors.raise(
      FieldUiCompiler.ERROR.SOURCE_INVALID,
      "standard Yes/No frame palette must contain 16 colors",
      { member = cfg.standardPaletteMember, colors = #standardPalette.colors }
    )
  end
  local standardY = cfg.frameCount * 8
  for tile = 0, standardTileCount - 1 do
    blitTile(rgba, atlasWidth, tile * 8, standardY, standardChar, tile, 0, standardPalette.colors, false, false, {
      asset = "standard Yes/No frame",
      member = cfg.standardFrameMember,
    })
  end
  local standardFramePalette = {}
  for slot = 0, 15 do
    standardFramePalette[slot] = standardPalette.colors[slot + 1]
  end
  deps[#deps + 1] = {
    name = manifestConfig.dialogueFrames.alias .. ":member:" .. cfg.standardFrameMember,
    sha1 = sha1hex(standardCharBytes),
  }
  deps[#deps + 1] = {
    name = manifestConfig.dialogueFrames.alias .. ":palette:" .. cfg.standardPaletteMember,
    sha1 = sha1hex(standardPaletteBytes),
  }
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
    palettes = palettes,
    standardFrame = {
      frameTiles = { x = 0, y = standardY, width = 72, height = 8 },
      palette = standardFramePalette,
    },
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

-- The compact two-row choice prompt: the four shape-0 button screens
-- rendered from the shared char bank, the confirmation row through the
-- first prompt palette bank and the rejection row through the second. Each
-- state publishes its own 48x32 surface under a semantic asset id; the
-- manifest section carries the compact shape record alone, never the source
-- archive, member, tile, palette, or background identities.
local function compileYesNoPrompt(romFs, sha1hex, deps, assets, manifestAssets)
  local archive, archiveBytes = loadArchive(romFs, manifestConfig.yesNoPrompt.alias)
  local cfg = manifestConfig.yesNoPrompt
  local memberBytes = {}
  local function g2d(kind, memberId, label)
    memberBytes[memberId] = decodeMember(archive, memberId, label)
    local decoded, err =
      G2dDecoder[kind](memberBytes[memberId], { label = manifestConfig.yesNoPrompt.alias .. ":" .. memberId })
    return must(decoded, err)
  end
  local palette = g2d("decodePalette", cfg.paletteMember, "two-row prompt palette") --[[@as FieldUiCompiler.PaletteData]]
  local charData = g2d("decodeChar", cfg.charMember, "two-row prompt char") --[[@as FieldUiCompiler.CharData]]
  if #palette.colors < 32 then
    Errors.raise(
      FieldUiCompiler.ERROR.SOURCE_INVALID,
      "the two-row prompt palette must cover both button banks",
      { member = cfg.paletteMember, available = #palette.colors }
    )
  end
  local states = {
    {
      key = "yes.normal",
      member = cfg.yesNormalScreen,
      bank = 0,
      asset = FieldUiAssetCache.ASSET.YES_NO_PROMPT_YES_NORMAL,
      file = "yes-no-prompt-yes-normal.png",
    },
    {
      key = "yes.selected",
      member = cfg.yesSelectedScreen,
      bank = 0,
      asset = FieldUiAssetCache.ASSET.YES_NO_PROMPT_YES_SELECTED,
      file = "yes-no-prompt-yes-selected.png",
    },
    {
      key = "no.normal",
      member = cfg.noNormalScreen,
      bank = 1,
      asset = FieldUiAssetCache.ASSET.YES_NO_PROMPT_NO_NORMAL,
      file = "yes-no-prompt-no-normal.png",
    },
    {
      key = "no.selected",
      member = cfg.noSelectedScreen,
      bank = 1,
      asset = FieldUiAssetCache.ASSET.YES_NO_PROMPT_NO_SELECTED,
      file = "yes-no-prompt-no-selected.png",
    },
  }
  local compact = {
    width = FieldUiAssetCache.GEOMETRY.PROMPT_BUTTON_WIDTH,
    height = FieldUiAssetCache.GEOMETRY.PROMPT_BUTTON_HEIGHT,
    yes = {},
    no = {},
  }
  for _, state in ipairs(states) do
    local screen = g2d("decodeScreen", state.member, "two-row prompt " .. state.key) --[[@as FieldUiCompiler.ScreenData]]
    if
      screen.width ~= FieldUiAssetCache.GEOMETRY.PROMPT_BUTTON_WIDTH
      or screen.height ~= FieldUiAssetCache.GEOMETRY.PROMPT_BUTTON_HEIGHT
    then
      Errors.raise(
        FieldUiCompiler.ERROR.SOURCE_INVALID,
        "the two-row prompt " .. state.key .. " screen must be the compact 48x32 surface",
        { member = state.member, width = screen.width, height = screen.height }
      )
    end
    -- The source selects the button bank per row at presentation time, so
    -- the producer pins each screen's entries to its row bank before
    -- rasterizing; the physical bank numbers never leave this module.
    local entries = {}
    for index, entry in ipairs(screen.entries) do
      entries[index] = { tile = entry.tile, palette = state.bank, flipH = entry.flipH, flipV = entry.flipV }
    end
    local path = FieldUiAssetCache.assetDir() .. "/" .. state.file
    assets[path] = renderScreen(charData, palette.colors, {
      width = screen.width,
      height = screen.height,
      entries = entries,
    }, {
      asset = "two-row prompt " .. state.key,
      member = state.member,
    })
    manifestAssets[state.asset] = { image = path, width = screen.width, height = screen.height }
    deps[#deps + 1] = {
      name = manifestConfig.yesNoPrompt.alias .. ":prompt:" .. state.key,
      sha1 = sha1hex(memberBytes[state.member]),
    }
  end
  deps[#deps + 1] = { name = manifestConfig.yesNoPrompt.alias .. ":narc", sha1 = sha1hex(archiveBytes) }
  local function visual(assetId)
    return {
      asset = assetId,
      rect = {
        x = 0,
        y = 0,
        width = FieldUiAssetCache.GEOMETRY.PROMPT_BUTTON_WIDTH,
        height = FieldUiAssetCache.GEOMETRY.PROMPT_BUTTON_HEIGHT,
      },
    }
  end
  compact.yes = {
    normal = visual(FieldUiAssetCache.ASSET.YES_NO_PROMPT_YES_NORMAL),
    selected = visual(FieldUiAssetCache.ASSET.YES_NO_PROMPT_YES_SELECTED),
  }
  compact.no = {
    normal = visual(FieldUiAssetCache.ASSET.YES_NO_PROMPT_NO_NORMAL),
    selected = visual(FieldUiAssetCache.ASSET.YES_NO_PROMPT_NO_SELECTED),
  }
  return {
    shapes = {
      compact = compact,
    },
  }
end

local function compileNamingScreen(romFs, sha1hex, deps, assets, manifestAssets)
  local archive, archiveBytes = loadArchive(romFs, manifestConfig.namingScreen.alias)
  local cfg = manifestConfig.namingScreen
  local memberBytes = {}
  local function g2d(kind, memberId, label)
    memberBytes[memberId] = decodeMember(archive, memberId, label)
    local decoded, err =
      G2dDecoder[kind](memberBytes[memberId], { label = manifestConfig.namingScreen.alias .. ":" .. memberId })
    return must(decoded, err)
  end
  local palette = g2d("decodePalette", cfg.paletteMember, "naming screen palette") --[[@as FieldUiCompiler.PaletteData]]
  local charData = g2d("decodeChar", cfg.charMember, "naming screen char") --[[@as FieldUiCompiler.CharData]]
  local baseScreen = g2d("decodeScreen", cfg.baseScreenMember, "naming screen base") --[[@as FieldUiCompiler.ScreenData]]
  if baseScreen.width ~= 256 or baseScreen.height ~= 192 then
    Errors.raise(
      FieldUiCompiler.ERROR.SOURCE_INVALID,
      "the normal naming base must be the 256x192 source surface",
      { member = cfg.baseScreenMember, width = baseScreen.width, height = baseScreen.height }
    )
  end
  -- The base is the opaque backdrop: palette-zero pixels render as source
  -- art, never as transparency.
  local basePath = FieldUiAssetCache.assetDir() .. "/naming-screen-base.png"
  assets[basePath] = renderScreen(charData, palette.colors, baseScreen, {
    asset = "naming screen base",
    member = cfg.baseScreenMember,
  }, { transparentZero = false })
  manifestAssets[FieldUiAssetCache.ASSET.NAMING_SCREEN_BASE] =
    { image = basePath, width = baseScreen.width, height = baseScreen.height }

  -- The pages are transparent overlays: palette-zero holes stay transparent
  -- so the base shows through at runtime.
  local pageOrder = { "upper", "lower", "symbols" }
  local pageAssetIds = {
    upper = FieldUiAssetCache.ASSET.NAMING_SCREEN_PAGE_UPPER,
    lower = FieldUiAssetCache.ASSET.NAMING_SCREEN_PAGE_LOWER,
    symbols = FieldUiAssetCache.ASSET.NAMING_SCREEN_PAGE_SYMBOLS,
  }
  local pages = {}
  for _, key in ipairs(pageOrder) do
    local screenMember = cfg.pageScreenMembers[key]
    local screen = g2d("decodeScreen", screenMember, "naming screen " .. key .. " page") --[[@as FieldUiCompiler.ScreenData]]
    if screen.width ~= 256 or screen.height ~= 112 then
      Errors.raise(
        FieldUiCompiler.ERROR.SOURCE_INVALID,
        "the normal naming " .. key .. " page must be the 256x112 source overlay",
        { member = screenMember, width = screen.width, height = screen.height }
      )
    end
    local path = FieldUiAssetCache.assetDir() .. "/naming-screen-page-" .. key .. ".png"
    local pageImage = G2dRasterizer.renderScreen(charData, { colors = palette.colors }, screen, {
      asset = "naming screen " .. key .. " page",
      member = screenMember,
    })
    assets[path] =
      composeNamingPageWindow(pageImage, cfg.keyboardWindow, cfg.keyboardWindow.pages[key], palette.colors, key)
    manifestAssets[pageAssetIds[key]] = { image = path, width = screen.width, height = screen.height }
    pages[key] = { asset = pageAssetIds[key], width = screen.width, height = screen.height }
  end

  deps[#deps + 1] = {
    name = manifestConfig.namingScreen.alias .. ":palette:" .. cfg.paletteMember,
    sha1 = sha1hex(memberBytes[cfg.paletteMember]),
  }
  deps[#deps + 1] = {
    name = manifestConfig.namingScreen.alias .. ":member:" .. cfg.charMember,
    sha1 = sha1hex(memberBytes[cfg.charMember]),
  }
  deps[#deps + 1] = {
    name = manifestConfig.namingScreen.alias .. ":member:" .. cfg.baseScreenMember,
    sha1 = sha1hex(memberBytes[cfg.baseScreenMember]),
  }
  for _, key in ipairs(pageOrder) do
    local screenMember = cfg.pageScreenMembers[key]
    deps[#deps + 1] = {
      name = manifestConfig.namingScreen.alias .. ":member:" .. screenMember,
      sha1 = sha1hex(memberBytes[screenMember]),
    }
  end
  deps[#deps + 1] = { name = manifestConfig.namingScreen.alias .. ":narc", sha1 = sha1hex(archiveBytes) }

  -- The normal OBJ stack: char 10, all nine palette-1 banks, NCER 12, and
  -- NANR 14, decoded once. Each OAM object keeps its own palette bank; no
  -- palette override is ever applied.
  local objChar = g2d("decodeChar", cfg.objCharMember, "naming screen obj char") --[[@as FieldUiCompiler.CharData]]
  local objPalette = g2d("decodePalette", cfg.objPaletteMember, "naming screen obj palette") --[[@as FieldUiCompiler.PaletteData]]
  local objCell = g2d("decodeCell", cfg.objCellMember, "naming screen obj cell") --[[@as FieldUiCompiler.CellData]]
  local objAnim = g2d("decodeAnimation", cfg.objAnimMember, "naming screen obj animation") --[[@as FieldUiCompiler.AnimationData]]
  -- The palette-transfer count for this resource is nine 16-color banks; a
  -- shorter palette cannot serve every OAM bank the cells select.
  if #objPalette.colors < 9 * 16 then
    Errors.raise(FieldUiCompiler.ERROR.SOURCE_INVALID, "the naming OBJ palette must carry all nine banks", {
      member = cfg.objPaletteMember,
      available = #objPalette.colors,
    })
  end

  -- Render one static semantic visual through the shared OAM compositor
  -- and register it as a generated image carrying the rasterizer's frame
  -- offset. Controls and entry slots keep this one-frame shape; subjects
  -- and cursors use the animation publisher below.
  local function semanticSprite(role, animId)
    local animation = objAnim.anims[animId + 1]
    if animation == nil then
      Errors.raise(FieldUiCompiler.ERROR.SOURCE_INVALID, "the naming OBJ animation bank has no animation", {
        anim = animId,
        available = #objAnim.anims,
      })
    end
    assert(animation ~= nil, "missing naming animations fail above")
    local frame = G2dRasterizer.renderAnimationFrame(objChar, { colors = objPalette.colors }, objCell, animation, 1, {
      asset = "naming screen " .. role,
      member = cfg.objAnimMember,
    })
    local path = FieldUiAssetCache.assetDir() .. "/naming-screen-" .. role .. ".png"
    assets[path] = PngWriter.encode(frame.width, frame.height, frame.pixels)
    return path, frame
  end

  local function publish(role, assetId, animId, anchor)
    local path, frame = semanticSprite(role, animId)
    manifestAssets[assetId] = { image = path, width = frame.width, height = frame.height }
    local record = {
      asset = assetId,
      image = path,
      width = frame.width,
      height = frame.height,
      anchor = { x = anchor.x, y = anchor.y },
      offset = { x = frame.offset.x, y = frame.offset.y },
    }
    return record
  end

  -- Pack rendered frames deterministically left to right in one atlas row;
  -- every frame keeps its compositor size and offset, so the manifest
  -- boundary is stable for a fixed source.
  local function packAtlasRow(frames)
    local atlasWidth, atlasHeight = 0, 0
    for _, frame in ipairs(frames) do
      atlasWidth = atlasWidth + frame.width
      atlasHeight = math.max(atlasHeight, frame.height)
    end
    local rows = {}
    for y = 0, atlasHeight - 1 do
      for _, frame in ipairs(frames) do
        if y < frame.height then
          rows[#rows + 1] = frame.pixels:sub(y * frame.width * 4 + 1, (y + 1) * frame.width * 4)
        else
          rows[#rows + 1] = string.rep(string.char(0, 0, 0, 0), frame.width)
        end
      end
    end
    return PngWriter.encode(atlasWidth, atlasHeight, table.concat(rows)), atlasWidth, atlasHeight
  end

  -- The synthetic pulse palette: absolute source palette entry 29 renders
  -- as the unique white marker while every other entry renders black, so
  -- post-processing keeps only the marker pixels as the opaque pulse mask.
  local function pulseMarkerPalette()
    local colors = {}
    for index = 1, 9 * 16 do
      colors[index] = { r = 0, g = 0, b = 0 }
    end
    colors[29 + 1] = { r = 255, g = 255, b = 255 }
    return { colors = colors }
  end

  local function maskPixels(pixels)
    local out = {}
    for index = 1, #pixels, 4 do
      local r, g, b, a = string.byte(pixels, index, index + 3)
      if r == 255 and g == 255 and b == 255 and a == 255 then
        out[#out + 1] = string.char(255, 255, 255, 255)
      else
        out[#out + 1] = string.char(0, 0, 0, 0)
      end
    end
    return table.concat(out)
  end

  -- Publish one full semantic animation: every decoded source frame in
  -- source order through the shared OAM compositor with its decoded
  -- duration and compositor offset, packed into one deterministic atlas,
  -- plus the runtime playback mode and zero-based loop start. Cursor roles
  -- additionally publish the entry-29 pulse-mask atlas whose frames match
  -- the normal frames in order and size.
  local function publishAnimation(role, assetId, maskAssetId, animId)
    local animation = objAnim.anims[animId + 1]
    if animation == nil then
      Errors.raise(FieldUiCompiler.ERROR.SOURCE_INVALID, "the naming OBJ animation bank has no animation", {
        anim = animId,
        available = #objAnim.anims,
      })
    end
    assert(animation ~= nil, "missing naming animations fail above")
    if #animation.frames == 0 then
      Errors.raise(FieldUiCompiler.ERROR.SOURCE_INVALID, "the naming animation carries no frames", {
        anim = animId,
      })
    end
    local source = { asset = "naming screen " .. role, member = cfg.objAnimMember }
    local normalFrames = {}
    local maskFrames = {}
    local markerPalette = nil
    if maskAssetId ~= nil then
      markerPalette = pulseMarkerPalette()
    end
    for frameIndex = 1, #animation.frames do
      local decoded = animation.frames[frameIndex]
      local frame = G2dRasterizer.renderAnimationFrame(
        objChar,
        { colors = objPalette.colors },
        objCell,
        animation,
        frameIndex,
        source
      )
      normalFrames[#normalFrames + 1] = {
        width = frame.width,
        height = frame.height,
        pixels = frame.pixels,
        offset = { x = frame.offset.x, y = frame.offset.y },
        duration = decoded.duration,
      }
      if markerPalette ~= nil then
        local mask = G2dRasterizer.renderAnimationFrame(objChar, markerPalette, objCell, animation, frameIndex, source)
        assert(
          mask.width == frame.width and mask.height == frame.height,
          "the pulse mask must match its frame geometry"
        )
        maskFrames[#maskFrames + 1] = {
          width = mask.width,
          height = mask.height,
          pixels = maskPixels(mask.pixels),
        }
      end
    end
    local normalPath = FieldUiAssetCache.assetDir() .. "/naming-screen-" .. role .. ".png"
    local normalBytes, atlasWidth, atlasHeight = packAtlasRow(normalFrames)
    assets[normalPath] = normalBytes
    manifestAssets[assetId] = { image = normalPath, width = atlasWidth, height = atlasHeight }
    local record = {
      playMode = animation.playMode,
      loopStartFrameIdx = animation.loopStartFrameIdx,
      frames = {},
    }
    local maskPath = nil
    if maskAssetId ~= nil then
      maskPath = FieldUiAssetCache.assetDir() .. "/naming-screen-" .. role .. "-mask.png"
      local maskBytes, maskWidth, maskHeight = packAtlasRow(maskFrames)
      assets[maskPath] = maskBytes
      manifestAssets[maskAssetId] = { image = maskPath, width = maskWidth, height = maskHeight }
      record.pulseAsset = maskAssetId
    end
    local x = 0
    for index, frame in ipairs(normalFrames) do
      local entry = {
        asset = assetId,
        rect = { x = x, y = 0, width = frame.width, height = frame.height },
        offset = { x = frame.offset.x, y = frame.offset.y },
        duration = frame.duration,
      }
      if maskAssetId ~= nil then
        entry.pulseRect = { x = x, y = 0, width = frame.width, height = frame.height }
      end
      record.frames[index] = entry
      x = x + frame.width
    end
    return record
  end

  local controls = {}
  for _, id in ipairs({ "upper", "lower", "symbols", "back", "ok", "backing" }) do
    local assetId = FieldUiAssetCache.ASSET["NAMING_SCREEN_CONTROL_" .. id:upper()]
    controls[id] = publish("control-" .. id, assetId, cfg.objAnims[id], cfg.objAnchors[id])
  end

  local keyboardCursor = publishAnimation(
    "cursor-keyboard",
    FieldUiAssetCache.ASSET.NAMING_SCREEN_CURSOR_KEYBOARD,
    FieldUiAssetCache.ASSET.NAMING_SCREEN_CURSOR_KEYBOARD_MASK,
    cfg.objAnims.cursorKeyboard
  )
  keyboardCursor.origin = { x = cfg.cursorOrigin.x, y = cfg.cursorOrigin.y }
  keyboardCursor.stepX = cfg.cursorStepX
  keyboardCursor.stepY = cfg.cursorStepY

  local homeCursor = {}
  for _, id in ipairs({ "upper", "lower", "symbols", "back", "ok" }) do
    local animId = (id == "back" or id == "ok") and cfg.objAnims.cursorHomeConfirm or cfg.objAnims.cursorHomePage
    local record = publishAnimation(
      "cursor-home-" .. id,
      FieldUiAssetCache.ASSET["NAMING_SCREEN_CURSOR_HOME_" .. id:upper()],
      FieldUiAssetCache.ASSET["NAMING_SCREEN_CURSOR_HOME_" .. id:upper() .. "_MASK"],
      animId
    )
    record.anchor = { x = cfg.homeCursorAnchors[id].x, y = cfg.homeCursorAnchors[id].y }
    homeCursor[id] = record
  end

  local slotNormal =
    publish("slot-normal", FieldUiAssetCache.ASSET.NAMING_SCREEN_SLOT_NORMAL, cfg.objAnims.slotNormal, cfg.entryOrigin)
  local slotSelected = publishAnimation(
    "slot-selected",
    FieldUiAssetCache.ASSET.NAMING_SCREEN_SLOT_SELECTED,
    nil,
    cfg.objAnims.slotSelected
  )
  local subjectMale =
    publishAnimation("subject-male", FieldUiAssetCache.ASSET.NAMING_SCREEN_SUBJECT_MALE, nil, cfg.objAnims.subjectMale)
  subjectMale.anchor = { x = cfg.objAnchors.subject.x, y = cfg.objAnchors.subject.y }
  local subjectFemale = publishAnimation(
    "subject-female",
    FieldUiAssetCache.ASSET.NAMING_SCREEN_SUBJECT_FEMALE,
    nil,
    cfg.objAnims.subjectFemale
  )
  subjectFemale.anchor = { x = cfg.objAnchors.subject.x, y = cfg.objAnchors.subject.y }

  -- pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36,
  -- src/naming_screen.c::NamingScreen_LoadMonIcon uploads 0x200 bytes at
  -- OBJ address 0x57E0: one 32x32 icon at tile 703. Sequence 50's NCER
  -- cells both reference that tile; they animate the icon's placement, not
  -- its image frame.
  local pokemonIconTile = 0x57E0 / 32
  local pokemonAnimation = objAnim.anims[cfg.objAnims.pokemonSubject + 1]
  if pokemonAnimation == nil or #pokemonAnimation.frames == 0 then
    Errors.raise(FieldUiCompiler.ERROR.SOURCE_INVALID, "the naming Pokémon animation is missing frames", {
      anim = cfg.objAnims.pokemonSubject,
    })
  end
  assert(pokemonAnimation ~= nil, "the naming Pokémon animation is present")
  local pokemonSubjectFrames = {}
  for index, frame in ipairs(pokemonAnimation.frames) do
    if cfg.pokemonSubjectCells[index] ~= frame.cell then
      Errors.raise(FieldUiCompiler.ERROR.SOURCE_INVALID, "the naming Pokémon animation selects an unsupported cell", {
        anim = cfg.objAnims.pokemonSubject,
        cell = frame.cell,
      })
    end
    local cell = objCell.cells[frame.cell + 1]
    if cell == nil or #cell.objs ~= 2 then
      Errors.raise(FieldUiCompiler.ERROR.SOURCE_INVALID, "the naming Pokémon cell is malformed", {
        anim = cfg.objAnims.pokemonSubject,
        cell = frame.cell,
      })
    end
    assert(cell ~= nil, "the naming Pokémon cell is present")
    local minX, minY = math.huge, math.huge
    for _, obj in ipairs(cell.objs) do
      if obj.tile ~= pokemonIconTile or obj.width ~= 32 or obj.height ~= 32 then
        Errors.raise(
          FieldUiCompiler.ERROR.SOURCE_INVALID,
          "the naming Pokémon cell does not use the loaded icon frame",
          {
            anim = cfg.objAnims.pokemonSubject,
            cell = frame.cell,
          }
        )
      end
      minX, minY = math.min(minX, obj.x), math.min(minY, obj.y)
    end
    if frame.element ~= "none" and frame.element ~= "translate" then
      Errors.raise(FieldUiCompiler.ERROR.SOURCE_INVALID, "the naming Pokémon animation transform is unsupported", {
        anim = cfg.objAnims.pokemonSubject,
        element = frame.element,
      })
    end
    pokemonSubjectFrames[index] = {
      iconFrame = 1,
      offset = { x = minX + frame.translateX, y = minY + frame.translateY },
      duration = frame.duration,
    }
  end
  local pokemonSubject = {
    playMode = pokemonAnimation.playMode,
    loopStartFrameIdx = pokemonAnimation.loopStartFrameIdx,
    anchor = { x = cfg.objAnchors.subject.x, y = cfg.objAnchors.subject.y },
    frames = pokemonSubjectFrames,
  }

  -- Keyboard text cells in final canonical coordinates: page placement
  -- plus the keyboard window origin plus the glyph inset below each row top.
  local keyboardWindow = cfg.keyboardWindow
  local keyboardCells = {}
  for row = 1, keyboardWindow.rows do
    keyboardCells[row] = {}
    for column = 1, keyboardWindow.columns do
      keyboardCells[row][column] = {
        x = cfg.pagePlacement.x + keyboardWindow.x + (column - 1) * keyboardWindow.cellWidth,
        y = cfg.pagePlacement.y + keyboardWindow.y + keyboardWindow.textInsetY + (row - 1) * keyboardWindow.rowHeight,
        width = keyboardWindow.cellWidth,
      }
    end
  end

  for _, memberId in ipairs({ cfg.objCharMember, cfg.objPaletteMember, cfg.objCellMember, cfg.objAnimMember }) do
    deps[#deps + 1] = {
      name = manifestConfig.namingScreen.alias .. ":member:" .. memberId,
      sha1 = sha1hex(memberBytes[memberId]),
    }
  end
  return {
    base = {
      asset = FieldUiAssetCache.ASSET.NAMING_SCREEN_BASE,
      width = baseScreen.width,
      height = baseScreen.height,
    },
    pages = pages,
    placement = {
      x = cfg.pagePlacement.x,
      y = cfg.pagePlacement.y,
      width = cfg.pagePlacement.width,
      height = cfg.pagePlacement.height,
    },
    text = {
      name = { x = cfg.nameOrigin.x, y = cfg.nameOrigin.y, advanceX = cfg.nameAdvanceX },
      keyboard = { cells = keyboardCells },
    },
    controls = controls,
    cursor = {
      keyboard = keyboardCursor,
      home = homeCursor,
    },
    entrySlots = {
      origin = { x = cfg.entryOrigin.x, y = cfg.entryOrigin.y },
      stepX = cfg.entryStepX,
      normal = slotNormal,
      selected = slotSelected,
    },
    playerSubjects = {
      male = subjectMale,
      female = subjectFemale,
    },
    pokemonSubject = pokemonSubject,
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
  local yesNoPrompt = compileYesNoPrompt(romFs, sha1hex, deps, assets, manifestAssets)
  local namingScreen = compileNamingScreen(romFs, sha1hex, deps, assets, manifestAssets)

  local manifest = {
    schema = FieldUiAssetCache.SCHEMA,
    reference = { width = 256, height = 192 },
    assets = manifestAssets,
    dialogueFrames = dialogueFrames,
    signposts = signposts,
    startMenu = startMenu,
    trainerCard = trainerCard,
    yesNoPrompt = yesNoPrompt,
    namingScreen = namingScreen,
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
