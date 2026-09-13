-- Icon and portrait selection plus deterministic atlas inputs. Party-icon
-- selection follows src/pokemon_icon_idx.c GetMonIconNaixEx (naix member) and
-- GetMonIconPaletteEx (palette bank member 0) at the pinned
-- pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981 commit: each
-- icon is a 32x32 two-frame NCGR addressed with the shared NCER cells and
-- NANR frame timing. Front portraits follow src/pokemon.c
-- GetMonSpriteCharAndPlttNarcIdsEx: base species read the pokegra archive,
-- alternate forms and eggs read the otherpoke archive, and each character
-- member carries two 80x80 frames. Front-picture character payloads are
-- stored scanned: src/pokepic.c UnscanPokepic_PtHGSS masks 3200
-- little-endian words with the 32-bit LCRNG seeded from word 0 before pixels
-- are used, and the decoded surface is 80 rows of 80 bytes whose left and
-- right 40-byte halves are the two authored frames
-- (src/pokepic.c UnscanPokepic_PtHGSS row addressing
-- pRawCharData[j * 80 + k]; src/unk_02013FDC.c portrait extraction; the
-- second frame sits at an 80-pixel horizontal offset).
-- Tiles, palettes, cells, and animations
-- decode through the existing G2dDecoder primitives; this module only
-- rasterizes palette-resolved RGBA and packs deterministic atlases. Returns
-- raw image buffers and manifest values; MonCacheWriter owns PNG
-- encoding and publication.
--
-- Bounded pages are the production path: plan enumerates every reachable
-- selector and assigns consecutive pages without decoding pixel payloads,
-- and compilePage rasterizes exactly one page from its assigned source
-- records. compileIcons/compilePortraits below remain as the whole-corpus
-- reference builders the page-equivalence tests compare against; no
-- production build routes through them.

local Errors = require("libs.errors.src.Errors")
local U32 = require("libs.codec.src.U32")
local MonSources = require("romdump.src.config.MonSources")
local MonCache = require("libs.assets.src.MonCache")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")

local bit = require("bit")

---@class MonPresentationCompiler
local MonPresentationCompiler = {}

-- Representative selectors proving each layout resolves and addresses
-- visible pixels. Icons cover the default and egg starters plus distinct
-- alternate forms; portraits cover the starters, a shiny, and distinct
-- alternate forms.
local ICON_REPRESENTATIVES = {
  MonCache.iconSelector("CHIKORITA", 0, false),
  MonCache.iconSelector("CYNDAQUIL", 0, false),
  MonCache.iconSelector("TOTODILE", 0, false),
  MonCache.iconSelector("CHIKORITA", 0, true),
  MonCache.iconSelector("UNOWN", 1, false),
  MonCache.iconSelector("ROTOM", 5, false),
}

local PORTRAIT_REPRESENTATIVES = {
  MonCache.portraitSelector("CHIKORITA", 0, "male", false),
  MonCache.portraitSelector("CYNDAQUIL", 0, "male", false),
  MonCache.portraitSelector("TOTODILE", 0, "male", false),
  MonCache.portraitSelector("CHIKORITA", 0, "female", false),
  MonCache.portraitSelector("TOTODILE", 0, "male", true),
  MonCache.portraitSelector("UNOWN", 5, "male", false),
  MonCache.portraitSelector("ROTOM", 1, "female", false),
}

local ICON_CELL = 32
local PORTRAIT_CELL = 80
local ICON_FRAMES = 2
local PORTRAIT_FRAMES = 2
local FRONT_FACING = 2

-- Bounded presentation pages: at most sixteen distinct two-frame visuals
-- share one page, laid out in eight columns by four rows of frame cells.
-- Icons use 32x32 frame cells (256x128 pages); portraits use 80x80 frame
-- cells (640x320 pages). A final partial page keeps the same dimensions
-- with unused cells transparent.
local VISUALS_PER_PAGE = 16
local PAGE_COLUMNS = 8
local ICON_PAGE_WIDTH = 256
local ICON_PAGE_HEIGHT = 128
local PORTRAIT_PAGE_WIDTH = 640
local PORTRAIT_PAGE_HEIGHT = 320

-- Retail front-picture geometry: the scanned payload is exactly the two
-- authored 80x80 4bpp frames, and the decoded surface is 80 rows of 80
-- bytes with one frame per 40-byte row half.
local PORTRAIT_BYTES = 6400
local PORTRAIT_WORDS = 3200
local UNSCAN_MULTIPLIER = 1103515245
local UNSCAN_INCREMENT = 24691
local PORTRAIT_ROW_BYTES = 80
local PORTRAIT_FRAME_ROW_BYTES = 40

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
    return nil, Errors.new("MON_ARCHIVE_UNAVAILABLE", "mon archive " .. alias .. " is unavailable", { alias = alias })
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
        "MON_MEMBER_MISSING",
        alias .. " member " .. memberId .. " is absent",
        { alias = alias, memberId = memberId }
      )
  end
  return member
end

-- Reachable icon selections: every catalog form plus the per-species egg,
-- sorted by canonical selector so every later grouping is enumeration
-- independent. The egg aliases the shared egg source tuple exactly as the
-- source selection does.
---@param catalog table<string, unknown>
---@return table<integer, table<string, unknown>>
local function collectIconSelections(catalog)
  local selections = {}
  for speciesKey, species in pairs(catalog.species) do
    local speciesId = must(MonSources.speciesId(speciesKey))
    for formId in pairs(species.forms) do
      selections[#selections + 1] = {
        selector = MonCache.iconSelector(speciesKey, formId, false),
        naix = MonSources.iconNaix(speciesId, false, formId),
        palette = MonSources.iconPalette(speciesId, formId, false),
      }
    end
    if speciesId >= 1 and speciesId <= MonSources.MAX_SPECIES then
      selections[#selections + 1] = {
        selector = MonCache.iconSelector(speciesKey, 0, true),
        naix = MonSources.iconNaix(speciesId, true, 0),
        palette = MonSources.iconPalette(speciesId, 0, true),
      }
    end
  end
  table.sort(selections, function(a, b)
    return a.selector < b.selector
  end)
  return selections
end

-- Reachable portrait selections: every gender/shiny variant the source
-- ships members for, sorted by canonical selector. Variant existence is a
-- source-member fact, never a label guess; reading members here selects
-- variants without decoding any pixels.
---@param romFs RomFs
---@param catalog table<string, unknown>
---@return table<integer, table<string, unknown>>|nil, Errors.Error|nil
local function collectPortraitSelections(romFs, catalog)
  local selections = {}
  for speciesKey, species in pairs(catalog.species) do
    local speciesId = must(MonSources.speciesId(speciesKey))
    for formId in pairs(species.forms) do
      local variants, variantsErr = MonPresentationCompiler.portraitVariants(romFs, speciesId, formId)
      if not variants then
        return nil, variantsErr
      end
      for _, variant in ipairs(variants) do
        selections[#selections + 1] = {
          selector = MonCache.portraitSelector(speciesKey, formId, variant.gender, variant.shiny),
          narc = variant.narc,
          charMemberId = variant.charMemberId,
          palMemberId = variant.palMemberId,
        }
      end
    end
  end
  table.sort(selections, function(a, b)
    return a.selector < b.selector
  end)
  return selections
end

-- Group sorted selections by their immutable visual source tuple. Combos
-- emerge in first-seen order over selector-sorted selections, so each
-- combo's first selector is its lexicographic minimum and the combo order
-- itself is the deterministic group order. Aliases sharing a tuple share
-- one combo and never allocate additional slots.
---@param selections table<integer, table<string, unknown>>
---@param keyOf fun(selection: table<string, unknown>): string
---@param tupleOf fun(selection: table<string, unknown>): table<string, unknown>
---@return table<integer, table<string, unknown>> combos in group order
local function assignCombos(selections, keyOf, tupleOf)
  local combos, comboIndex = {}, {}
  for _, selection in ipairs(selections) do
    local key = keyOf(selection)
    if comboIndex[key] == nil then
      comboIndex[key] = #combos + 1
      local combo = tupleOf(selection)
      combo.key = key
      combo.selectors = {}
      combos[#combos + 1] = combo
    end
    local combo = combos[comboIndex[key]]
    selection.combo = comboIndex[key]
    combo.selectors[#combo.selectors + 1] = selection.selector
  end
  return combos
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
              "MON_IMAGE_BAD_PALETTE",
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

-- Undo the retail HGSS front-picture scan on a private copy of the decoded
-- payload: the seed starts at the first original little-endian word, every
-- word is masked with the low 16 seed bits in order, and the seed advances
-- through the exact 32-bit recurrence (exact U32 arithmetic because Lua
-- numbers cannot represent every intermediate product). The decoded member
-- bytes are never mutated. A payload that is not the exact two-frame shape
-- keeps the existing image-size error.
local function unscanPortraitBytes(charTiles, label)
  if #charTiles ~= PORTRAIT_BYTES then
    return nil,
      Errors.new(
        "MON_IMAGE_TILE_COUNT",
        label .. " carries " .. (#charTiles / 32) .. " tiles, expected " .. (PORTRAIT_BYTES / 32),
        {
          tiles = #charTiles / 32,
          expected = PORTRAIT_BYTES / 32,
        }
      )
  end
  local seed = string.byte(charTiles, 1) + string.byte(charTiles, 2) * 256
  local parts = {}
  for i = 0, PORTRAIT_WORDS - 1 do
    local word = string.byte(charTiles, i * 2 + 1) + string.byte(charTiles, i * 2 + 2) * 256
    local plain = bit.bxor(word, seed % 65536)
    parts[#parts + 1] = string.char(plain % 256, math.floor(plain / 256) % 256)
    seed = U32.add(U32.mul(seed, UNSCAN_MULTIPLIER), UNSCAN_INCREMENT)
  end
  return table.concat(parts)
end

-- Raster the two authored 80x80 frames from the unscanned row-major
-- surface: each of the 80 rows carries 80 bytes, frame 0 reads bytes 0..39
-- of the row and frame 1 reads bytes 40..79. Each packed byte expands low
-- nibble then high nibble into two horizontally adjacent pixels. Palette
-- resolution (including index-0 transparency) still owns the expansions
-- table built by the caller.
local function rasterizePortraitFrames(unscanned, expansions, label)
  assert(#unscanned == PORTRAIT_BYTES, label .. " portrait bytes must be unscanned before rastering")
  local frames = {}
  for frame = 0, PORTRAIT_FRAMES - 1 do
    local rows = {}
    for y = 0, PORTRAIT_CELL - 1 do
      local frameBase = y * PORTRAIT_ROW_BYTES + frame * PORTRAIT_FRAME_ROW_BYTES
      local parts = {}
      for byteX = 0, PORTRAIT_FRAME_ROW_BYTES - 1 do
        parts[#parts + 1] = expansions[string.byte(unscanned, frameBase + byteX + 1)]
      end
      rows[#rows + 1] = table.concat(parts)
    end
    frames[#frames + 1] = table.concat(rows)
  end
  return frames
end

-- Rasterize frameCount frames of tilesWide x tilesHigh 8x8 tiles into RGBA
-- strings. Tiles within a frame run row-major; frames run back to back.
local function rasterizeFrames(charTiles, expansions, tilesWide, tilesHigh, frameCount, label)
  local tilesPerFrame = tilesWide * tilesHigh
  local expected = tilesPerFrame * frameCount * 32
  if #charTiles ~= expected then
    return nil,
      Errors.new(
        "MON_IMAGE_TILE_COUNT",
        label .. " carries " .. (#charTiles / 32) .. " tiles, expected " .. (expected / 32),
        {
          tiles = #charTiles / 32,
          expected = expected / 32,
        }
      )
  end
  local frames = {}
  for frame = 0, frameCount - 1 do
    local rows = {}
    for y = 0, tilesHigh * 8 - 1 do
      local tileRow = math.floor(y / 8)
      local rowInTile = y % 8
      local parts = {}
      for tx = 0, tilesWide - 1 do
        local tile = frame * tilesPerFrame + tileRow * tilesWide + tx
        local base = tile * 32 + rowInTile * 4
        for col = 0, 3 do
          local byte = string.byte(charTiles, base + col + 1)
          if byte == nil then
            return nil,
              Errors.new("MON_IMAGE_SHORT_TILES", label .. " tile data ends mid-frame", { frame = frame, tile = tile })
          end
          parts[#parts + 1] = expansions[byte]
        end
      end
      rows[#rows + 1] = table.concat(parts)
    end
    frames[#frames + 1] = table.concat(rows)
  end
  return frames
end

-- Pack frame cells into one fixed grid page: eight columns by four rows
-- of frame cells. Missing cells (a final partial page) stay transparent.
-- Returns the image buffer; every rect assignment elsewhere derives from
-- the same column-major cell numbering.
local function packPage(cells, cellSize)
  local cols = PAGE_COLUMNS
  local rows = (VISUALS_PER_PAGE * 2) / cols
  local width, height = cols * cellSize, rows * cellSize
  local pixels = {}
  for row = 0, rows - 1 do
    for y = 0, cellSize - 1 do
      local parts = {}
      for col = 0, cols - 1 do
        local index = row * cols + col + 1
        local cell = cells[index]
        if cell == nil then
          parts[#parts + 1] = string.rep("\0", cellSize * 4)
        else
          parts[#parts + 1] = cell:sub(y * cellSize * 4 + 1, (y + 1) * cellSize * 4)
        end
      end
      pixels[#pixels + 1] = table.concat(parts)
    end
  end
  return { width = width, height = height, pixels = table.concat(pixels) }
end

-- Page-local origin of one frame cell: visual slot s (zero-based within
-- the page) contributes its frames in order, so frame f of slot s is cell
-- s*2+f in row-major order.
---@param slot integer zero-based visual slot within the page
---@param frame integer zero-based frame within the visual
---@param cellSize integer frame cell edge in pixels
---@return integer x, integer y page-local origin
local function frameCellOrigin(slot, frame, cellSize)
  local cellNumber = slot * 2 + frame
  local col = cellNumber % PAGE_COLUMNS
  local row = math.floor(cellNumber / PAGE_COLUMNS)
  return col * cellSize, row * cellSize
end
-- Pack sorted frame cells into one deterministic grid atlas. Each cell is
-- cellSize square; every visual contributes frameCount cells in order.
-- Returns the image buffer plus the grid width for rect assignment. The
-- whole-atlas reference builders below use this; bounded page compilation
-- uses packPage instead and never routes through this layout.
local function packAtlas(cells, cellSize)
  local count = #cells
  local cols = math.max(1, math.ceil(math.sqrt(count)))
  local rows = math.max(1, math.ceil(count / cols))
  local width, height = cols * cellSize, rows * cellSize
  local pixels = {}
  for row = 0, rows - 1 do
    for y = 0, cellSize - 1 do
      local parts = {}
      for col = 0, cols - 1 do
        local index = row * cols + col + 1
        local cell = cells[index]
        if cell == nil then
          parts[#parts + 1] = string.rep("\0", cellSize * 4)
        else
          parts[#parts + 1] = cell:sub(y * cellSize * 4 + 1, (y + 1) * cellSize * 4)
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

local function opaquePixelCount(rgba, width, x, y, cellSize)
  local count = 0
  for row = 0, cellSize - 1 do
    for col = 0, cellSize - 1 do
      local alpha = string.byte(rgba, ((y + row) * width + x + col) * 4 + 4)
      if alpha ~= nil and alpha > 0 then
        count = count + 1
      end
    end
  end
  return count
end

-- Decode the shared icon NANR animation into per-cell frame durations.
-- The animation is one single-frame anim per cell: each cell's first-seen
-- duration wins across all anims. Planning reads only this one small
-- member; no character or palette payload is decoded here.
---@param archive Narc
---@return table<integer, integer>|nil, Errors.Error|nil
local function decodeIconDurations(archive)
  local animMember, animErr = readMember(archive, 1, "pokemon_icons")
  if not animMember then
    return nil, animErr
  end
  local anim, decodeErr = G2dDecoder.decodeAnimation(animMember, { label = "icon animation" })
  if not anim then
    return nil, decodeErr
  end
  if #anim.anims == 0 or #anim.anims[1].frames == 0 then
    return nil, Errors.new("MON_IMAGE_BAD_ANIM", "icon animation carries no frames", {})
  end
  local durations = {}
  for _, animation in ipairs(anim.anims) do
    for _, frame in ipairs(animation.frames) do
      if frame.cell ~= 0 and frame.cell ~= 1 then
        return nil,
          Errors.new("MON_IMAGE_BAD_ANIM", "icon animation references cell " .. frame.cell, { cell = frame.cell })
      end
      if durations[frame.cell] == nil then
        durations[frame.cell] = frame.duration
      end
    end
  end
  if durations[0] == nil or durations[1] == nil then
    return nil, Errors.new("MON_IMAGE_BAD_ANIM", "icon animation never shows a frame", {})
  end
  return durations
end

-- Decode the shared icon inputs: the 256-color palette bank plus the frame
-- durations and the two shared cells. Per-visual character payloads stay
-- with the combo raster step below.
---@param archive Narc
---@return { colors: table<integer, table<string, integer>>, durations: table<integer, integer> }|nil, Errors.Error|nil
local function decodeIconShared(archive)
  local palMember, palErr = readMember(archive, 0, "pokemon_icons")
  if not palMember then
    return nil, palErr
  end
  local palette, decodeErr = G2dDecoder.decodePalette(palMember, { label = "icon palettes" })
  if not palette then
    return nil, decodeErr
  end
  if #palette.colors ~= 256 then
    return nil,
      Errors.new("MON_IMAGE_BAD_PALETTE", "icon palette bank carries " .. #palette.colors .. " colors, expected 256", {
        available = #palette.colors,
      })
  end
  local durations, durationsErr = decodeIconDurations(archive)
  if not durations then
    return nil, durationsErr
  end
  local cellMember, cellErr = readMember(archive, 2, "pokemon_icons")
  if not cellMember then
    return nil, cellErr
  end
  local iconCells, cellsErr = G2dDecoder.decodeCell(cellMember, { label = "icon cells" })
  if not iconCells then
    return nil, cellsErr
  end
  if #iconCells.cells ~= 2 then
    return nil,
      Errors.new("MON_IMAGE_BAD_CELLS", "icon cells carry " .. #iconCells.cells .. " cells, expected 2", {
        count = #iconCells.cells,
      })
  end
  return { colors = palette.colors, durations = durations }
end

-- Raster one icon visual's two frames: the naix character member through
-- the visual's 16-color palette slice. Shared by whole-atlas reference
-- builds and bounded page compilation so one decode owns the pixels.
---@param archive Narc
---@param colors table<integer, table<string, integer>> shared 256-color bank
---@param naix integer character member identity
---@param palette integer palette slot identity
---@return table<integer, string>|nil, Errors.Error|nil
local function rasterIconCombo(archive, colors, naix, palette)
  local charMember, charErr = readMember(archive, naix, "pokemon_icons")
  if not charMember then
    return nil, charErr
  end
  local char, decodeErr = G2dDecoder.decodeChar(charMember, { label = "icon " .. naix })
  if not char then
    return nil, decodeErr
  end
  if char.depth ~= 3 then
    return nil, Errors.new("MON_IMAGE_BAD_DEPTH", "icon " .. naix .. " is not 4bpp", { depth = char.depth })
  end
  local slice = {}
  for i = 1, 16 do
    slice[i] = colors[palette * 16 + i]
  end
  local expansions, expansionsErr = byteExpansions(slice, "icon " .. naix)
  if not expansions then
    return nil, expansionsErr
  end
  return rasterizeFrames(char.tiles, expansions, 4, 4, ICON_FRAMES, "icon " .. naix)
end

-- Raster one portrait visual's two frames: the character member unscanned
-- through the visual's 16-color palette. Shared by whole-atlas reference
-- builds and bounded page compilation so one decode owns the pixels.
---@param archives table<string, Narc>
---@param combo { narc: string, charMemberId: integer, palMemberId: integer }
---@return table<integer, string>|nil, Errors.Error|nil
local function rasterPortraitCombo(archives, combo)
  local archive = archives[combo.narc]
  if archive == nil then
    return nil,
      Errors.new("MON_ARCHIVE_UNAVAILABLE", "mon archive " .. combo.narc .. " is unavailable", {
        alias = combo.narc,
      })
  end
  local label = combo.narc .. " char " .. combo.charMemberId
  local charMember, charErr = readMember(archive, combo.charMemberId, combo.narc)
  if not charMember then
    return nil, charErr
  end
  local char, decodeErr = G2dDecoder.decodeChar(charMember, { label = label })
  if not char then
    return nil, decodeErr
  end
  if char.depth ~= 3 then
    return nil, Errors.new("MON_IMAGE_BAD_DEPTH", label .. " is not 4bpp", { depth = char.depth })
  end
  local palMember, palErr = readMember(archive, combo.palMemberId, combo.narc)
  if not palMember then
    return nil, palErr
  end
  local pal, palErr2 = G2dDecoder.decodePalette(palMember, { label = combo.narc .. " pal " .. combo.palMemberId })
  if not pal then
    return nil, palErr2
  end
  if #pal.colors ~= 16 then
    return nil,
      Errors.new("MON_IMAGE_BAD_PALETTE", label .. " palette carries " .. #pal.colors .. " colors, expected 16", {
        available = #pal.colors,
      })
  end
  local expansions, expansionsErr = byteExpansions(pal.colors, label)
  if not expansions then
    return nil, expansionsErr
  end
  local unscanned, unscanErr = unscanPortraitBytes(char.tiles, label)
  if not unscanned then
    return nil, unscanErr
  end
  return rasterizePortraitFrames(unscanned, expansions, label)
end

-- Compile every reachable party icon: one atlas entry per unique
-- (naix, palette) pair, one manifest entry per semantic selector, with
-- egg selectors aliasing the shared egg entries exactly as the source
-- selection does. Durations come from the icon NANR animation.
function MonPresentationCompiler.compileIcons(romFs, catalog)
  local archive, err = openArchive(romFs, "pokemon_icons")
  if not archive then
    return nil, err
  end
  local ok, result = pcall(function()
    local shared = must(decodeIconShared(archive))
    local palette, durations = shared.colors, shared.durations
    local selections = collectIconSelections(catalog)
    local combos = assignCombos(selections, function(selection)
      return selection.naix .. ":" .. selection.palette
    end, function(selection)
      return { naix = selection.naix, palette = selection.palette }
    end)
    local framesByCombo = {}
    for index, combo in ipairs(combos) do
      framesByCombo[index] = must(rasterIconCombo(archive, palette, combo.naix, combo.palette))
    end
    local atlasCells = {}
    for index in ipairs(combos) do
      for frame = 1, ICON_FRAMES do
        atlasCells[#atlasCells + 1] = framesByCombo[index][frame]
      end
    end
    local atlas = packAtlas(atlasCells, ICON_CELL)
    local entries = {}
    for _, selection in ipairs(selections) do
      local frames = {}
      for frame = 0, ICON_FRAMES - 1 do
        local cellNumber = (selection.combo - 1) * ICON_FRAMES + frame
        local col = cellNumber % atlas.cols
        local row = math.floor(cellNumber / atlas.cols)
        frames[#frames + 1] = {
          x = col * ICON_CELL,
          y = row * ICON_CELL,
          width = ICON_CELL,
          height = ICON_CELL,
          duration = durations[frame],
        }
      end
      local first = frames[1]
      entries[selection.selector] =
        { x = first.x, y = first.y, width = first.width, height = first.height, frames = frames }
    end
    local representative = ICON_REPRESENTATIVES
    for _, selector in ipairs(representative) do
      local entry = entries[selector]
      if entry == nil then
        error(
          Errors.new("MON_MANIFEST_MISSING_REPRESENTATIVE", "icon representative has no entry: " .. selector, {
            selector = selector,
          }),
          0
        )
      end
      if opaquePixelCount(atlas.pixels, atlas.width, entry.x, entry.y, ICON_CELL) == 0 then
        error(
          Errors.new(
            "MON_MANIFEST_BLANK_REPRESENTATIVE",
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
        schema = MonCache.ICON_MANIFEST_SCHEMA,
        image = MonCache.iconImagePath(),
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

-- Front-portrait variants with source data for one species/form. A gender
-- variant exists exactly when its character member is non-empty: male-only,
-- female-only, and genderless species ship only the reachable members, and
-- the source provides no portrait variant beyond them. Shiny variants always
-- exist (palettes are per-species and never empty). Male variants sort
-- first so the catalog default is deterministic.
function MonPresentationCompiler.portraitVariants(romFs, speciesId, form)
  local baseArchive, err = openArchive(romFs, "pokemon_graphics")
  if not baseArchive then
    return nil, err
  end
  local otherArchive
  otherArchive, err = openArchive(romFs, "pokemon_graphics_other")
  if not otherArchive then
    return nil, err
  end
  local archives = { pokemon_graphics = baseArchive, pokemon_graphics_other = otherArchive }
  local ok, result = pcall(function()
    local variants = {}
    for _, gender in ipairs({ "male", "female" }) do
      local ids = MonSources.portraitIds(speciesId, gender, FRONT_FACING, false, form)
      local archive = must(archives[ids.narc])
      local charMember = must(readMember(archive, ids.charMemberId, ids.narc))
      if #charMember > 0 then
        for _, shiny in ipairs({ false, true }) do
          local shinyIds = MonSources.portraitIds(speciesId, gender, FRONT_FACING, shiny, form)
          variants[#variants + 1] = {
            gender = gender,
            shiny = shiny,
            narc = shinyIds.narc,
            charMemberId = shinyIds.charMemberId,
            palMemberId = shinyIds.palMemberId,
          }
        end
      end
    end
    if #variants == 0 then
      error(
        Errors.new("MON_PORTRAIT_NO_VARIANT", "species " .. speciesId .. " form " .. form .. " has no portrait data", {
          speciesId = speciesId,
          form = form,
        }),
        0
      )
    end
    return variants
  end)
  if not ok then
    if Errors.is(result) then
      return nil, result
    end
    error(result, 0)
  end
  return result
end

-- Compile every reachable front portrait: one atlas entry per unique
-- (archive, character, palette) triple, one manifest entry per semantic
-- selector, with gender/shiny aliases sharing entries exactly where the
-- source lookup yields identical members. Portraits carry no per-mon frame
-- timing (the starter screen animates through its own UI resources), so
-- frames address atlas rectangles without durations.
function MonPresentationCompiler.compilePortraits(romFs, catalog)
  local baseArchive, err = openArchive(romFs, "pokemon_graphics")
  if not baseArchive then
    return nil, err
  end
  local otherArchive
  otherArchive, err = openArchive(romFs, "pokemon_graphics_other")
  if not otherArchive then
    return nil, err
  end
  local archives = { pokemon_graphics = baseArchive, pokemon_graphics_other = otherArchive }
  local ok, result = pcall(function()
    local selections = must(collectPortraitSelections(romFs, catalog))
    local combos = assignCombos(selections, function(selection)
      return selection.narc .. ":" .. selection.charMemberId .. ":" .. selection.palMemberId
    end, function(selection)
      return { narc = selection.narc, charMemberId = selection.charMemberId, palMemberId = selection.palMemberId }
    end)
    local framesByCombo = {}
    for index, combo in ipairs(combos) do
      framesByCombo[index] = must(rasterPortraitCombo(archives, combo))
    end
    local atlasCells = {}
    for index in ipairs(combos) do
      for frame = 1, PORTRAIT_FRAMES do
        atlasCells[#atlasCells + 1] = framesByCombo[index][frame]
      end
    end
    local atlas = packAtlas(atlasCells, PORTRAIT_CELL)
    local entries = {}
    for _, selection in ipairs(selections) do
      local frames = {}
      for frame = 0, PORTRAIT_FRAMES - 1 do
        local cellNumber = (selection.combo - 1) * PORTRAIT_FRAMES + frame
        local col = cellNumber % atlas.cols
        local row = math.floor(cellNumber / atlas.cols)
        frames[#frames + 1] = {
          x = col * PORTRAIT_CELL,
          y = row * PORTRAIT_CELL,
          width = PORTRAIT_CELL,
          height = PORTRAIT_CELL,
        }
      end
      local first = frames[1]
      entries[selection.selector] =
        { x = first.x, y = first.y, width = first.width, height = first.height, frames = frames }
    end
    local representative = PORTRAIT_REPRESENTATIVES
    for _, selector in ipairs(representative) do
      local entry = entries[selector]
      if entry == nil then
        error(
          Errors.new("MON_MANIFEST_MISSING_REPRESENTATIVE", "portrait representative has no entry: " .. selector, {
            selector = selector,
          }),
          0
        )
      end
      if opaquePixelCount(atlas.pixels, atlas.width, entry.x, entry.y, PORTRAIT_CELL) == 0 then
        error(
          Errors.new(
            "MON_MANIFEST_BLANK_REPRESENTATIVE",
            "portrait representative addresses no visible pixels: " .. selector,
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
        schema = MonCache.PORTRAIT_MANIFEST_SCHEMA,
        image = MonCache.portraitImagePath(),
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

-- Assign consecutive zero-based page ids over group-ordered combos and
-- build the normalized v2 manifest: every selector entry carries its page
-- id with page-local rectangles, and pages inventory the fixed page images.
-- frameOf builds one frame record from a page-local origin; representative
-- carries the layout's global representative selectors for the per-page
-- blank checks compilePage performs.
---@param catalog table<string, unknown>
---@param combos table<integer, table<string, unknown>>
---@param schema string
---@param pagePathOf fun(pageId: integer): string
---@param pageWidth integer
---@param pageHeight integer
---@param cellSize integer
---@param frameOf fun(x: integer, y: integer, frame: integer): table<string, unknown>
---@param representative string[]
---@return table<string, unknown> manifest, table<integer, table<string, unknown>> pagePlans by zero-based page id
local function buildLayout(
  catalog,
  combos,
  schema,
  pagePathOf,
  pageWidth,
  pageHeight,
  cellSize,
  frameOf,
  representative
)
  assert(type(catalog.version) == "table", "page layout requires the catalog version")
  local version = catalog.version --[[@as { id: string, language: string }]]
  assert(type(version.id) == "string" and type(version.language) == "string", "page layout requires a version identity")
  if #combos == 0 then
    error(Errors.new("MON_MANIFEST_NO_VISUALS", "page layout selected no visuals", {}), 0)
  end
  local entries = {}
  local pagePlans = {}
  for comboIndex, combo in ipairs(combos) do
    local pageId = math.floor((comboIndex - 1) / VISUALS_PER_PAGE)
    local slot = (comboIndex - 1) % VISUALS_PER_PAGE
    local pagePlan = pagePlans[pageId]
    if pagePlan == nil then
      pagePlan = {
        pageId = pageId,
        width = pageWidth,
        height = pageHeight,
        cell = cellSize,
        combos = {},
        representative = {},
      }
      pagePlans[pageId] = pagePlan
    end
    pagePlan.combos[#pagePlan.combos + 1] = combo
    for _, selector in ipairs(combo.selectors) do
      local frames = {}
      for frame = 0, 1 do
        local x, y = frameCellOrigin(slot, frame, cellSize)
        frames[#frames + 1] = frameOf(x, y, frame)
      end
      local first = frames[1]
      entries[selector] = {
        x = first.x,
        y = first.y,
        width = cellSize,
        height = cellSize,
        frames = frames,
        pageId = pageId,
      }
    end
  end
  for _, selector in ipairs(representative) do
    local entry = entries[selector]
    if entry == nil then
      error(
        Errors.new("MON_MANIFEST_MISSING_REPRESENTATIVE", "page layout representative has no entry: " .. selector, {
          selector = selector,
        }),
        0
      )
    end
    local pagePlan = assert(pagePlans[entry.pageId], "representative entry names a planned page")
    pagePlan.representative[#pagePlan.representative + 1] =
      { selector = selector, x = entry.x, y = entry.y, width = entry.width, height = entry.height }
  end
  local pages = {}
  local pageIds = {}
  local pageCount = 0
  for _ in pairs(pagePlans) do
    pageCount = pageCount + 1
  end
  for pageId = 0, pageCount - 1 do
    assert(pagePlans[pageId] ~= nil, "page plans are consecutive from zero")
    pages[pageId] = { pageId = pageId, image = pagePathOf(pageId), width = pageWidth, height = pageHeight }
    pageIds[#pageIds + 1] = pageId
  end
  return {
    schema = schema,
    version = { id = version.id, language = version.language },
    pages = pages,
    pageIds = pageIds,
    entries = entries,
    representative = representative,
  },
    pagePlans
end

-- Plan the complete selector layout without decoding pixel payloads:
-- group aliases by visual source tuple, order groups by representative
-- selector, and assign the fixed sixteen-visual pages. The returned
-- manifests are normalized runtime metadata; the page plans are
-- producer-private source selections compilePage consumes. Only the one
-- shared icon animation member is decoded, for frame timing; no character
-- or palette payload is touched.
---@param romFs RomFs
---@param catalog table<string, unknown>
---@return { icons: table<string, unknown>, portraits: table<string, unknown>, iconPages: table<integer, table<string, unknown>>, portraitPages: table<integer, table<string, unknown>> }|nil, Errors.Error|string|nil
function MonPresentationCompiler.plan(romFs, catalog)
  local ok, result = pcall(function()
    local iconSelections = collectIconSelections(catalog)
    local iconArchive = must(openArchive(romFs, "pokemon_icons"))
    local durations = must(decodeIconDurations(iconArchive))
    local iconCombos = assignCombos(iconSelections, function(selection)
      return selection.naix .. ":" .. selection.palette
    end, function(selection)
      return { naix = selection.naix, palette = selection.palette }
    end)
    local icons, iconPages = buildLayout(
      catalog,
      iconCombos,
      MonCache.ICON_MANIFEST_SCHEMA,
      MonCache.iconPagePath,
      ICON_PAGE_WIDTH,
      ICON_PAGE_HEIGHT,
      ICON_CELL,
      function(x, y, frame)
        return { x = x, y = y, width = ICON_CELL, height = ICON_CELL, duration = durations[frame] }
      end,
      ICON_REPRESENTATIVES
    )
    local portraitSelections = must(collectPortraitSelections(romFs, catalog))
    local portraitCombos = assignCombos(portraitSelections, function(selection)
      return selection.narc .. ":" .. selection.charMemberId .. ":" .. selection.palMemberId
    end, function(selection)
      return { narc = selection.narc, charMemberId = selection.charMemberId, palMemberId = selection.palMemberId }
    end)
    local portraits, portraitPages = buildLayout(
      catalog,
      portraitCombos,
      MonCache.PORTRAIT_MANIFEST_SCHEMA,
      MonCache.portraitPagePath,
      PORTRAIT_PAGE_WIDTH,
      PORTRAIT_PAGE_HEIGHT,
      PORTRAIT_CELL,
      function(x, y, _)
        return { x = x, y = y, width = PORTRAIT_CELL, height = PORTRAIT_CELL }
      end,
      PORTRAIT_REPRESENTATIVES
    )
    return { icons = icons, portraits = portraits, iconPages = iconPages, portraitPages = portraitPages }
  end)
  if not ok then
    if Errors.is(result) then
      return nil, result
    end
    error(result, 0)
  end
  return result
end

-- Compile exactly one bounded page from its assigned source records: read
-- only this page's character and palette members into one page-sized RGBA
-- buffer, encode nothing here, and drop the buffer once the caller stages
-- it. At most sixteen visuals are decoded per call; the full-corpus image
-- is never constructed. Representative selectors on this page must address
-- visible pixels, exactly as the reference builds require.
---@param romFs RomFs
---@param kind "icons"|"portraits" presentation kind
---@param pagePlan table<string, unknown> producer-private page source plan from plan
---@return { kind: string, pageId: integer, width: integer, height: integer, pixels: string }|nil, Errors.Error|string|nil
function MonPresentationCompiler.compilePage(romFs, kind, pagePlan)
  if kind ~= "icons" and kind ~= "portraits" then
    return nil, Errors.new("MON_PAGE_BAD_KIND", "mon page kind must be icons or portraits", { kind = kind })
  end
  if type(pagePlan) ~= "table" then
    return nil, Errors.new("MON_PAGE_BAD_PLAN", "mon page compilation requires its page plan", { kind = kind })
  end
  if kind == "icons" then
    local archive, err = openArchive(romFs, "pokemon_icons")
    if not archive then
      return nil, err
    end
    local ok, result = pcall(function()
      local pageId = must(pagePlan.pageId)
      local combos = must(pagePlan.combos)
      if #combos > VISUALS_PER_PAGE then
        error(Errors.new("MON_PAGE_TOO_LARGE", "icon page plans carry at most sixteen visuals", { pageId = pageId }), 0)
      end
      local shared = must(decodeIconShared(archive))
      local cells = {}
      for _, combo in ipairs(combos) do
        local frames = must(rasterIconCombo(archive, shared.colors, combo.naix, combo.palette))
        cells[#cells + 1] = frames[1]
        cells[#cells + 1] = frames[2]
      end
      local page = packPage(cells, ICON_CELL)
      for _, check in ipairs(pagePlan.representative or {}) do
        if opaquePixelCount(page.pixels, page.width, check.x, check.y, check.width) == 0 then
          error(
            Errors.new(
              "MON_MANIFEST_BLANK_REPRESENTATIVE",
              "icon representative addresses no visible pixels: " .. check.selector,
              {
                selector = check.selector,
              }
            ),
            0
          )
        end
      end
      return { kind = "icons", pageId = pageId, width = page.width, height = page.height, pixels = page.pixels }
    end)
    if not ok then
      if Errors.is(result) then
        return nil, result
      end
      error(result, 0)
    end
    return result
  end
  local baseArchive, err = openArchive(romFs, "pokemon_graphics")
  if not baseArchive then
    return nil, err
  end
  local otherArchive
  otherArchive, err = openArchive(romFs, "pokemon_graphics_other")
  if not otherArchive then
    return nil, err
  end
  local archives = { pokemon_graphics = baseArchive, pokemon_graphics_other = otherArchive }
  local ok, result = pcall(function()
    local pageId = must(pagePlan.pageId)
    local combos = must(pagePlan.combos)
    if #combos > VISUALS_PER_PAGE then
      error(
        Errors.new("MON_PAGE_TOO_LARGE", "portrait page plans carry at most sixteen visuals", { pageId = pageId }),
        0
      )
    end
    local cells = {}
    for _, combo in ipairs(combos) do
      local frames = must(rasterPortraitCombo(archives, combo))
      cells[#cells + 1] = frames[1]
      cells[#cells + 1] = frames[2]
    end
    local page = packPage(cells, PORTRAIT_CELL)
    for _, check in ipairs(pagePlan.representative or {}) do
      if opaquePixelCount(page.pixels, page.width, check.x, check.y, check.width) == 0 then
        error(
          Errors.new(
            "MON_MANIFEST_BLANK_REPRESENTATIVE",
            "portrait representative addresses no visible pixels: " .. check.selector,
            {
              selector = check.selector,
            }
          ),
          0
        )
      end
    end
    return { kind = "portraits", pageId = pageId, width = page.width, height = page.height, pixels = page.pixels }
  end)
  if not ok then
    if Errors.is(result) then
      return nil, result
    end
    error(result, 0)
  end
  return result
end

return MonPresentationCompiler
