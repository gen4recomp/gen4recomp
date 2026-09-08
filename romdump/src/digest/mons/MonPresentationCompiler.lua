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

local Errors = require("libs.errors.src.Errors")
local U32 = require("libs.codec.src.U32")
local MonSources = require("romdump.src.config.MonSources")
local MonCache = require("libs.assets.src.MonCache")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")

local bit = require("bit")

---@class MonPresentationCompiler
local MonPresentationCompiler = {}

local ICON_CELL = 32
local PORTRAIT_CELL = 80
local ICON_FRAMES = 2
local PORTRAIT_FRAMES = 2
local FRONT_FACING = 2

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

-- Pack sorted frame cells into one deterministic grid atlas. Each cell is
-- cellSize square; every visual contributes frameCount cells in order.
-- Returns the image buffer plus the grid width for rect assignment.
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
    local palMember = must(readMember(archive, 0, "pokemon_icons"))
    local palette = must(G2dDecoder.decodePalette(palMember, { label = "icon palettes" }))
    if #palette.colors ~= 256 then
      error(
        Errors.new(
          "MON_IMAGE_BAD_PALETTE",
          "icon palette bank carries " .. #palette.colors .. " colors, expected 256",
          {
            available = #palette.colors,
          }
        ),
        0
      )
    end
    local animMember = must(readMember(archive, 1, "pokemon_icons"))
    local anim = must(G2dDecoder.decodeAnimation(animMember, { label = "icon animation" }))
    if #anim.anims == 0 or #anim.anims[1].frames == 0 then
      error(Errors.new("MON_IMAGE_BAD_ANIM", "icon animation carries no frames", {}), 0)
    end
    -- The icon animation is one single-frame anim per cell: collect each
    -- cell's first-seen duration across all anims.
    local durations = {}
    for _, animation in ipairs(anim.anims) do
      for _, frame in ipairs(animation.frames) do
        if frame.cell ~= 0 and frame.cell ~= 1 then
          error(
            Errors.new("MON_IMAGE_BAD_ANIM", "icon animation references cell " .. frame.cell, { cell = frame.cell }),
            0
          )
        end
        if durations[frame.cell] == nil then
          durations[frame.cell] = frame.duration
        end
      end
    end
    if durations[0] == nil or durations[1] == nil then
      error(Errors.new("MON_IMAGE_BAD_ANIM", "icon animation never shows a frame", {}), 0)
    end
    local cellMember = must(readMember(archive, 2, "pokemon_icons"))
    local iconCells = must(G2dDecoder.decodeCell(cellMember, { label = "icon cells" }))
    if #iconCells.cells ~= 2 then
      error(
        Errors.new("MON_IMAGE_BAD_CELLS", "icon cells carry " .. #iconCells.cells .. " cells, expected 2", {
          count = #iconCells.cells,
        }),
        0
      )
    end
    -- Reachable selections: every catalog form plus the per-species egg.
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
    local combos, comboIndex = {}, {}
    for _, selection in ipairs(selections) do
      local key = selection.naix .. ":" .. selection.palette
      if comboIndex[key] == nil then
        comboIndex[key] = #combos + 1
        combos[#combos + 1] = { naix = selection.naix, palette = selection.palette }
      end
      selection.combo = comboIndex[key]
    end
    local framesByCombo = {}
    for index, combo in ipairs(combos) do
      local charMember = must(readMember(archive, combo.naix, "pokemon_icons"))
      local char = must(G2dDecoder.decodeChar(charMember, { label = "icon " .. combo.naix }))
      if char.depth ~= 3 then
        error(Errors.new("MON_IMAGE_BAD_DEPTH", "icon " .. combo.naix .. " is not 4bpp", { depth = char.depth }), 0)
      end
      local slice = {}
      for i = 1, 16 do
        slice[i] = palette.colors[combo.palette * 16 + i]
      end
      local expansions = must(byteExpansions(slice, "icon " .. combo.naix))
      framesByCombo[index] = must(rasterizeFrames(char.tiles, expansions, 4, 4, ICON_FRAMES, "icon " .. combo.naix))
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
    local representative = {
      MonCache.iconSelector("CHIKORITA", 0, false),
      MonCache.iconSelector("CYNDAQUIL", 0, false),
      MonCache.iconSelector("TOTODILE", 0, false),
      MonCache.iconSelector("CHIKORITA", 0, true),
      MonCache.iconSelector("UNOWN", 1, false),
      MonCache.iconSelector("ROTOM", 5, false),
    }
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
    local selections = {}
    for speciesKey, species in pairs(catalog.species) do
      local speciesId = must(MonSources.speciesId(speciesKey))
      for formId in pairs(species.forms) do
        local variants = must(MonPresentationCompiler.portraitVariants(romFs, speciesId, formId))
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
    local combos, comboIndex = {}, {}
    for _, selection in ipairs(selections) do
      local key = selection.narc .. ":" .. selection.charMemberId .. ":" .. selection.palMemberId
      if comboIndex[key] == nil then
        comboIndex[key] = #combos + 1
        combos[#combos + 1] =
          { narc = selection.narc, charMemberId = selection.charMemberId, palMemberId = selection.palMemberId }
      end
      selection.combo = comboIndex[key]
    end
    local framesByCombo = {}
    for index, combo in ipairs(combos) do
      local archive = must(archives[combo.narc])
      local label = combo.narc .. " char " .. combo.charMemberId
      local charMember = must(readMember(archive, combo.charMemberId, combo.narc))
      local char = must(G2dDecoder.decodeChar(charMember, { label = label }))
      if char.depth ~= 3 then
        error(Errors.new("MON_IMAGE_BAD_DEPTH", label .. " is not 4bpp", { depth = char.depth }), 0)
      end
      local palMember = must(readMember(archive, combo.palMemberId, combo.narc))
      local pal = must(G2dDecoder.decodePalette(palMember, { label = combo.narc .. " pal " .. combo.palMemberId }))
      if #pal.colors ~= 16 then
        error(
          Errors.new("MON_IMAGE_BAD_PALETTE", label .. " palette carries " .. #pal.colors .. " colors, expected 16", {
            available = #pal.colors,
          }),
          0
        )
      end
      local expansions = must(byteExpansions(pal.colors, label))
      local unscanned = must(unscanPortraitBytes(char.tiles, label))
      framesByCombo[index] = rasterizePortraitFrames(unscanned, expansions, label)
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
    local representative = {
      MonCache.portraitSelector("CHIKORITA", 0, "male", false),
      MonCache.portraitSelector("CYNDAQUIL", 0, "male", false),
      MonCache.portraitSelector("TOTODILE", 0, "male", false),
      MonCache.portraitSelector("CHIKORITA", 0, "female", false),
      MonCache.portraitSelector("TOTODILE", 0, "male", true),
      MonCache.portraitSelector("UNOWN", 5, "male", false),
      MonCache.portraitSelector("ROTOM", 1, "female", false),
    }
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

return MonPresentationCompiler
