-- Item icon selection plus deterministic atlas inputs. Icon graphics
-- selection follows the ITEMNARC_NCGR/ITEMNARC_NCLR columns of src/item.c
-- sItemNarcIds at the pinned pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981
-- commit: each icon is one 32x32 4bpp NCGR addressed with the shared NCER
-- cell (member 1: one 32x32 OBJ at origin, palette slot 0) and the single
-- NANR animation (member 0). Character and palette members decode through
-- the existing G2dDecoder primitives; this module only rasterizes
-- palette-resolved RGBA and packs deterministic atlases. Returns raw image
-- buffers and manifest values; ItemCacheWriter owns PNG encoding and
-- publication.

local Errors = require("libs.errors.src.Errors")
local ItemSources = require("romdump.src.config.ItemSources")
local ItemCache = require("libs.assets.src.ItemCache")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")

---@class ItemPresentationCompiler
local ItemPresentationCompiler = {}

local ICON_CELL = 32
local ICON_TILES_WIDE = 4
local ICON_TILES_HIGH = 4
local ICON_PALETTE_SLOT = 0

---@generic T
---@param value T?
---@param err unknown?
---@return T
local function must(value, err)
  if value == nil then
    error(err, 0)
  end
  return value
end

local function openArchive(romFs, alias)
  local archive, err = romFs:openNarc(alias)
  if not archive then
    if Errors.is(err) then
      return nil, err
    end
    return nil, Errors.new("ITEM_ARCHIVE_UNAVAILABLE", "item archive " .. alias .. " is unavailable", { alias = alias })
  end
  return archive
end

local function readMember(archive, memberId, alias)
  local member, err = archive:readMember(memberId)
  if not member then
    if Errors.is(err) then
      return nil, err
    end
    return nil,
      Errors.new(
        "ITEM_MEMBER_MISSING",
        alias .. " member " .. memberId .. " is absent",
        { alias = alias, memberId = memberId }
      )
  end
  return member
end

-- Expand one 4bpp byte into two RGBA pixels through the 16-color palette.
-- Pixel value 0 is the reserved transparency slot; anything else indexes
-- the palette. The expansion table is built once per palette so frame
-- assembly stays a tight concat loop.
local function byteExpansions(colors, label)
  local expansions = {}
  for byte = 0, 255 do
    local lo, hi = byte % 16, math.floor(byte / 16)
    local out = {}
    for _, value in ipairs({ lo, hi }) do
      if value == 0 then
        out[#out + 1] = "\0\0\0\0"
      else
        local color = colors[value + 1]
        if color == nil then
          return nil,
            Errors.new(
              "ITEM_IMAGE_BAD_PALETTE",
              label .. " references palette entry " .. value .. " beyond " .. #colors,
              {
                value = value,
                available = #colors,
              }
            )
        end
        out[#out + 1] = string.char(color.r, color.g, color.b, 255)
      end
    end
    expansions[byte] = table.concat(out)
  end
  return expansions
end

-- Rasterize one 4x4-tile 32x32 frame into an RGBA string. Tiles run
-- row-major; any other tile count fails instead of rasterizing garbage.
local function rasterizeIcon(charTiles, expansions, label)
  local expected = ICON_TILES_WIDE * ICON_TILES_HIGH * 32
  if #charTiles ~= expected then
    return nil,
      Errors.new(
        "ITEM_IMAGE_TILE_COUNT",
        label .. " carries " .. (#charTiles / 32) .. " tiles, expected " .. (expected / 32),
        {
          tiles = #charTiles / 32,
          expected = expected / 32,
        }
      )
  end
  local rows = {}
  for y = 0, ICON_TILES_HIGH * 8 - 1 do
    local tileRow = math.floor(y / 8)
    local rowInTile = y % 8
    local parts = {}
    for tx = 0, ICON_TILES_WIDE - 1 do
      local tile = tileRow * ICON_TILES_WIDE + tx
      local base = tile * 32 + rowInTile * 4
      for col = 0, 3 do
        local byte = string.byte(charTiles, base + col + 1)
        if byte == nil then
          return nil, Errors.new("ITEM_IMAGE_SHORT_TILES", label .. " tile data ends mid-frame", {})
        end
        parts[#parts + 1] = expansions[byte]
      end
    end
    rows[#rows + 1] = table.concat(parts)
  end
  return table.concat(rows)
end

-- Pack cells into one deterministic grid atlas. Cells are ICON_CELL square;
-- order is the caller's deterministic selection order.
local function packAtlas(cells)
  local count = #cells
  local cols = math.max(1, math.ceil(math.sqrt(count)))
  local rows = math.max(1, math.ceil(count / cols))
  local width, height = cols * ICON_CELL, rows * ICON_CELL
  local pixels = {}
  for row = 0, rows - 1 do
    for y = 0, ICON_CELL - 1 do
      local parts = {}
      for col = 0, cols - 1 do
        local index = row * cols + col + 1
        local cell = cells[index]
        if cell == nil then
          parts[#parts + 1] = string.rep("\0", ICON_CELL * 4)
        else
          parts[#parts + 1] = cell:sub(y * ICON_CELL * 4 + 1, (y + 1) * ICON_CELL * 4)
        end
      end
      pixels[#pixels + 1] = table.concat(parts)
    end
  end
  return {
    width = width,
    height = height,
    pixels = table.concat(pixels),
    cols = cols,
  }
end

local function opaquePixelCount(rgba)
  local count = 0
  for index = 4, #rgba, 4 do
    if string.byte(rgba, index) > 0 then
      count = count + 1
    end
  end
  return count
end

-- Compile every item icon: one atlas cell per unique (ncgr, nclr) pixel
-- blob, one manifest entry per semantic item key, with shared source
-- graphics pointing at the same compiled atlas region. Selection order is
-- semantic-key order so recompilation is deterministic.
function ItemPresentationCompiler.compileIcons(romFs)
  local archive, err = openArchive(romFs, "item_icons")
  if not archive then
    return nil, err
  end
  local ok, result = pcall(function()
    local cellMember = must(readMember(archive, 1, "item_icons"))
    local iconCells = must(G2dDecoder.decodeCell(cellMember, { label = "item icon cells" }))
    if #iconCells.cells ~= 1 or #iconCells.cells[1].objs ~= 1 then
      error(
        Errors.new(
          "ITEM_IMAGE_BAD_CELLS",
          "item icon cells carry " .. #iconCells.cells .. " cells, expected the single shared cell",
          {}
        ),
        0
      )
    end
    local shared = iconCells.cells[1].objs[1]
    if shared.width ~= ICON_CELL or shared.height ~= ICON_CELL or shared.palette ~= ICON_PALETTE_SLOT then
      error(
        Errors.new("ITEM_IMAGE_BAD_CELLS", "the shared item icon cell is not the 32x32 palette-0 OBJ", {
          width = shared.width,
          height = shared.height,
          palette = shared.palette,
        }),
        0
      )
    end
    local selections = {}
    for nativeId = 0, 536 do
      local key = must(ItemSources.itemKeys[nativeId])
      local graphics = must(ItemSources.iconGraphics[nativeId])
      selections[#selections + 1] = { selector = key, ncgr = graphics.ncgr, nclr = graphics.nclr }
    end
    table.sort(selections, function(a, b)
      return a.selector < b.selector
    end)
    local combos, comboIndex = {}, {}
    for _, selection in ipairs(selections) do
      local comboKey = selection.ncgr .. ":" .. selection.nclr
      if comboIndex[comboKey] == nil then
        comboIndex[comboKey] = #combos + 1
        combos[#combos + 1] = { ncgr = selection.ncgr, nclr = selection.nclr }
      end
      selection.combo = comboIndex[comboKey]
    end
    local pixelsByCombo = {}
    for index, combo in ipairs(combos) do
      local charMember = must(readMember(archive, combo.ncgr, "item_icons"))
      local char = must(G2dDecoder.decodeChar(charMember, { label = "item icon " .. combo.ncgr }))
      if char.depth ~= 3 then
        error(
          Errors.new("ITEM_IMAGE_BAD_DEPTH", "item icon " .. combo.ncgr .. " is not 4bpp", { depth = char.depth }),
          0
        )
      end
      local palMember = must(readMember(archive, combo.nclr, "item_icons"))
      local palette = must(G2dDecoder.decodePalette(palMember, { label = "item icon palette " .. combo.nclr }))
      if #palette.colors < 16 then
        error(
          Errors.new(
            "ITEM_IMAGE_BAD_PALETTE",
            "item icon palette " .. combo.nclr .. " carries " .. #palette.colors .. " colors, expected at least 16",
            {
              available = #palette.colors,
            }
          ),
          0
        )
      end
      local slice = {}
      for i = 1, 16 do
        slice[i] = palette.colors[ICON_PALETTE_SLOT * 16 + i]
      end
      local expansions = must(byteExpansions(slice, "item icon " .. combo.ncgr))
      pixelsByCombo[index] = must(rasterizeIcon(char.tiles, expansions, "item icon " .. combo.ncgr))
    end
    -- Deduplicate genuinely identical pixel blobs so shared source graphics
    -- compile once; every manifest entry still names its own selector.
    local cells, cellOfPixels = {}, {}
    local cellOfSelector = {}
    for _, selection in ipairs(selections) do
      local pixels = pixelsByCombo[selection.combo]
      local cellNumber = cellOfPixels[pixels]
      if cellNumber == nil then
        cells[#cells + 1] = pixels
        cellNumber = #cells
        cellOfPixels[pixels] = cellNumber
      end
      selection.cell = cellNumber
      cellOfSelector[selection.selector] = cellNumber
    end
    local atlas = packAtlas(cells)
    local entries = {}
    for _, selection in ipairs(selections) do
      local col = (selection.cell - 1) % atlas.cols
      local row = math.floor((selection.cell - 1) / atlas.cols)
      entries[selection.selector] = {
        x = col * ICON_CELL,
        y = row * ICON_CELL,
        width = ICON_CELL,
        height = ICON_CELL,
      }
    end
    if opaquePixelCount(table.concat(cells, "")) == 0 then
      error(Errors.new("ITEM_IMAGE_BLANK_ATLAS", "the compiled item icon atlas carries no visible pixels", {}), 0)
    end
    local representative = { "POKE_BALL", "POTION", "CHERI_BERRY" }
    for _, selector in ipairs(representative) do
      local entry = entries[selector]
      if entry == nil then
        error(
          Errors.new("ITEM_MANIFEST_MISSING_REPRESENTATIVE", "icon representative has no entry: " .. selector, {
            selector = selector,
          }),
          0
        )
      end
      local cellNumber = cellOfSelector[selector]
      if cellNumber == nil or opaquePixelCount(cells[cellNumber]) == 0 then
        error(
          Errors.new(
            "ITEM_MANIFEST_BLANK_REPRESENTATIVE",
            "icon representative addresses no visible pixels: " .. selector,
            {
              selector = selector,
            }
          ),
          0
        )
      end
    end
    return {
      image = { width = atlas.width, height = atlas.height, pixels = atlas.pixels },
      manifest = {
        schema = ItemCache.ICON_MANIFEST_SCHEMA,
        atlas = ItemCache.iconImagePath(),
        entries = entries,
        representative = representative,
      },
    }
  end)
  if not ok then
    if Errors.is(result) then
      return nil, result
    end
    error(result, 0)
  end
  return result
end

return ItemPresentationCompiler
