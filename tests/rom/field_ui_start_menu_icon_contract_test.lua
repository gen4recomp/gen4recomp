-- ROM conformance for the generated Start Menu icon contract: the real dump
-- compiles the thirteen-row retail icon table (sprite rows with label-bank
-- ids, text-only rows, the external poke-icon row) over eleven non-blank
-- icon chars sharing one cell bank, one animation bank, and one palette
-- image, plus main chrome transparent above its panel boundary with art in
-- the band, the invariant SUB background set, one label window per
-- destination slot, and a non-blank cursor. Asserts only structural facts
-- and pixel alpha behavior, never copied source bytes or text. Member
-- selection stays producer-side: every archive member below is read through
-- the producer config, never as a literal.

local Assert = require("tests.support.Assert")
local PngReader = require("tests.support.PngReader")
local FieldUiCompiler = require("romdump.src.digest.ui.FieldUiCompiler")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local Lz10 = require("romdump.src.digest.Lz10")

local T = {}

local function selection()
  local config = require("romdump.src.config.FieldUiAssets")
  return assert(config.startMenu, "the field-UI producer must select start menu source art")
end

-- Read one NARC member, unwrapping the LZ10 wrapper the dump uses for
-- compressed members (palette images travel raw).
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

local function compiledStartMenu(romFs)
  local bundle = assert(FieldUiCompiler.compile(romFs))
  local startMenu = assert(bundle.manifest.startMenu, "the compiled field UI must publish the start menu section")
  return bundle, startMenu
end

local function assetBytes(bundle, assetId)
  local asset = assert(bundle.manifest.assets[assetId], "the generated class must index asset " .. assetId)
  local bytes = assert(bundle.assets[assert(asset.image)], "the generated image must have pixels: " .. assetId)
  return asset, bytes
end

local function opaqueCount(bytes)
  local width, _, rgba = PngReader.rgba(bytes)
  local opaque = 0
  local total = math.floor(#rgba / 4)
  for index = 0, total - 1 do
    local _, _, _, a = PngReader.pixel(rgba, width, index % width, math.floor(index / width))
    if a > 0 then
      opaque = opaque + 1
    end
  end
  return opaque, total
end

-- Every icon char is a 4bpp twenty-tile sprite bank with no blank tile, so
-- the shared atlas the producer rasterizes from them is real entry art.
function T.icon_chars_compile_from_eleven_non_blank_sprite_banks(romFs, version)
  local startMenu = selection()
  for position, memberId in ipairs(startMenu.iconCharMembers) do
    local char, err =
      G2dDecoder.decodeChar(memberBytes(romFs, startMenu.alias, memberId), { label = "start menu icon char" })
    assert(char, err and err.message)
    Assert.equal(char.depth, 3, version .. " icon char at bank position " .. position .. " is 4bpp")
    local tileCount = math.floor(#char.tiles / 32)
    Assert.equal(tileCount, 20, version .. " icon char at bank position " .. position .. " carries twenty tiles")
    for tile = 0, tileCount - 1 do
      local blank = true
      for byte = 1, 32 do
        if string.byte(char.tiles, tile * 32 + byte) ~= 0 then
          blank = false
          break
        end
      end
      Assert.isTrue(not blank, version .. " icon char tile " .. tile .. " at bank position " .. position .. " is art")
    end
  end

  local bundle, compiled = compiledStartMenu(romFs)
  local iconTable = assert(compiled.iconTable, "the start menu section must carry the retail icon table")
  Assert.equal(#iconTable, 13, "the icon table carries all thirteen retail rows")
  for _, index in ipairs({ 1, 2, 3, 4, 5, 6, 7, 8, 12, 13 }) do
    Assert.equal((iconTable[index] or {}).art, "sprite", version .. " icon row " .. index .. " is a sprite")
  end
  Assert.equal((iconTable[9] or {}).art, "text", version .. " icon row 9 is text-only")
  Assert.equal((iconTable[10] or {}).art, "text", version .. " icon row 10 is text-only")
  Assert.equal((iconTable[11] or {}).art, "poke_icon", version .. " icon row 11 is the poke-icon path")
  local labels = { [1] = 0, [2] = 1, [3] = 2, [4] = 14, [6] = 4, [7] = 5, [8] = 8, [12] = 34, [13] = 35 }
  for index, label in pairs(labels) do
    Assert.equal(iconTable[index].label, label, version .. " icon row " .. index .. " labels from its bank id")
  end
  Assert.equal(iconTable[5].labelKind, "player_name", "the trainer-card row expands the live player name")
  local variants = assert(iconTable[3].variants, "the bag row carries its gender-conditional variant")
  Assert.isNil(variants.default, "the bag row carries no default variant: its own visual is the default art")
  local female = assert(variants.female, "the bag row carries the female art as a first-class variant")
  Assert.notNil(female.normal, "the female variant carries the normal visual record")
  Assert.notNil(female.selected, "the female variant carries the selected visual record")

  local _, iconBytes = assetBytes(bundle, FieldUiAssetCache.ASSET.START_MENU_ICONS)
  local opaque = opaqueCount(iconBytes)
  Assert.isTrue(opaque > 0, version .. " shared icon atlas must contain art")

  local contexts = assert(compiled.contexts, "the start menu section must carry the retail context rows")
  Assert.equal(#contexts, 7, "the contract carries all seven retail context rows")
  Assert.deepEqual(contexts[1], { 0, 1, 2, 3, 4, 5, 6 }, "the normal context maps icons 0-6")
  Assert.deepEqual(contexts[2], { 7, 0, 1, 2, 3, 4, 6 }, "context row 2 transcribes the retail row's first seven icons")
  Assert.deepEqual(
    contexts[3],
    { 7, 0, 1, 3, 4, 6, 10 },
    "context row 3 transcribes the retail row's first seven icons"
  )
  Assert.deepEqual(contexts[4], { 7, 0, 1, 3, 4, 6, 9 }, "context row 4 transcribes the retail row's first seven icons")
  Assert.deepEqual(
    contexts[5],
    { 11, 0, 1, 2, 12, 4, 6 },
    "context row 5 transcribes the retail row's first seven icons"
  )
  for _, row in ipairs(contexts) do
    Assert.equal(#row, 7, "every context row maps one icon per sprite slot")
  end
end

-- The icon sprites share one cell bank, one animation bank, and one palette
-- image; the producer fingerprint pins exactly that shared set plus the
-- chrome members, and the compiled section leaks no source identities.
function T.icon_sprites_share_one_cell_anim_and_palette_bank(romFs, version)
  local startMenu = selection()
  local cell, cellErr =
    G2dDecoder.decodeCell(memberBytes(romFs, startMenu.alias, startMenu.iconCellMember), { label = "icon cell" })
  assert(cell, cellErr and cellErr.message)
  Assert.equal(#cell.cells, 10, version .. " icon cell bank carries ten cells")
  local anim, animErr = G2dDecoder.decodeAnimation(
    memberBytes(romFs, startMenu.alias, startMenu.iconAnimMember),
    { label = "icon animation" }
  )
  assert(anim, animErr and animErr.message)
  Assert.equal(#anim.anims, 7, version .. " icon animation bank carries seven animations")
  local palette, paletteErr = G2dDecoder.decodePalette(
    memberBytes(romFs, startMenu.alias, startMenu.iconPaletteMember),
    { label = "icon palette" }
  )
  assert(palette, paletteErr and paletteErr.message)
  Assert.equal(#palette.colors, 256, version .. " shared icon palette image carries 256 colors")

  local bundle, compiled = compiledStartMenu(romFs)
  local iconPalette = assert(compiled.iconPalette, "the start menu section must carry its palette record")
  Assert.equal(iconPalette.banks, 2, "the palette record carries both color banks")
  Assert.equal(iconPalette.selectionBank, 2, "selection highlights through the second bank")

  local names = {}
  for _, dep in ipairs(bundle.dependencies) do
    names[dep.name] = true
  end
  local required = {
    startMenu.backgroundCharMember,
    startMenu.backgroundScreenMember,
    startMenu.backgroundPaletteMember,
    startMenu.subBackgroundCharMember,
    startMenu.subBackgroundScreenMember,
    startMenu.subBackgroundPaletteMember,
    startMenu.iconCellMember,
    startMenu.iconAnimMember,
    startMenu.iconPaletteMember,
    startMenu.cursorCharMember,
    startMenu.cursorPaletteMember,
    startMenu.cursorCellMember,
    startMenu.cursorAnimMember,
  }
  for _, memberId in ipairs(startMenu.iconCharMembers) do
    required[#required + 1] = memberId
  end
  for _, memberId in ipairs(required) do
    Assert.isTrue(
      names[startMenu.alias .. ":member:" .. memberId] or names[startMenu.alias .. ":palette:" .. memberId],
      version .. " fingerprint must pin start menu member " .. memberId
    )
  end

  local forbidden = { member = true, memberId = true, narcId = true, alias = true, fileId = true }
  local function scan(value, path)
    if type(value) ~= "table" then
      return
    end
    for key, nested in pairs(value) do
      if type(key) == "string" and forbidden[key] then
        Assert.isTrue(false, "compiled start menu leaks source detail '" .. key .. "' at " .. path)
      end
      scan(nested, path .. "." .. tostring(key))
    end
  end
  scan(compiled, "startMenu")
  Assert.isTrue(FieldUiAssetCache.validateManifest(bundle.manifest))
end

-- Main chrome is transparent above the panel boundary with art in the band;
-- the SUB set behind the entry windows is context-invariant; every
-- destination slot carries its own label window; the cursor is real art.
function T.chrome_carries_the_panel_boundary_and_the_sub_window_set(romFs, version)
  local bundle, compiled = compiledStartMenu(romFs)
  local chrome = assert(compiled.chrome, "the start menu section must carry its chrome")
  Assert.equal(chrome.main.transparentAboveY, 136, "the main panel boundary sits at px 136")
  local _, chromeBytes = assetBytes(bundle, assert(chrome.main.asset))
  local width, height, rgba = PngReader.rgba(chromeBytes)
  local _, _, _, topAlpha = PngReader.pixel(rgba, width, 0, 0)
  Assert.equal(topAlpha, 0, version .. " main chrome is transparent above the panel band")
  local aboveOpaque = 0
  for y = 0, 135 do
    for x = 0, width - 1 do
      local _, _, _, a = PngReader.pixel(rgba, width, x, y)
      if a > 0 then
        aboveOpaque = aboveOpaque + 1
      end
    end
  end
  Assert.equal(aboveOpaque, 0, version .. " main chrome rows above px 136 are empty")
  local bandOpaque = 0
  for y = 136, height - 1 do
    for x = 0, width - 1 do
      local _, _, _, a = PngReader.pixel(rgba, width, x, y)
      if a > 0 then
        bandOpaque = bandOpaque + 1
      end
    end
  end
  Assert.isTrue(bandOpaque > 0, version .. " main chrome panel band must contain art")
  Assert.notNil(chrome.sub, "the chrome carries the sub background set")
  assetBytes(bundle, assert(chrome.sub.asset))

  local startMenu = selection()
  local subScreen, screenErr =
    G2dDecoder.decodeScreen(memberBytes(romFs, startMenu.alias, startMenu.subBackgroundScreenMember), {
      label = "sub background screen",
    })
  assert(subScreen, screenErr and screenErr.message)
  Assert.isTrue(
    subScreen.width % 8 == 0 and subScreen.height % 8 == 0,
    version .. " sub background screen is tile-aligned"
  )
  Assert.equal(
    #subScreen.entries,
    subScreen.width / 8 * subScreen.height / 8,
    version .. " sub screen entry count matches its dimensions"
  )

  local positions = assert(compiled.interactive, "the start menu section must carry its position records").positions
  local positionCount = 0
  for _ in pairs(positions) do
    positionCount = positionCount + 1
  end
  Assert.equal(positionCount, 7, "seven normal positions carry one label window each")
  for position = 0, 6 do
    Assert.notNil(
      positions[position] and positions[position].labelWindow,
      version .. " normal position " .. position .. " carries its own label window"
    )
  end

  local _, cursorBytes = assetBytes(bundle, FieldUiAssetCache.ASSET.START_MENU_CURSOR)
  local cursorOpaque = opaqueCount(cursorBytes)
  Assert.isTrue(cursorOpaque > 0, version .. " cursor must contain art")
end

-- The normal selector contract on the real dump: the seven source-position
-- records (anchors, label windows, touch bounds, ordered directional
-- candidates, cancel rectangle) with no synthetic slot grid, and
-- source-composed icon visuals (normal/selected frame offsets plus the Bag
-- gender variant) instead of fixed crop rects. Asserts only structural facts
-- and pixel alpha behavior, never copied source bytes or text.
function T.normal_selector_carries_positions_and_composed_visuals(romFs, version)
  local bundle, compiled = compiledStartMenu(romFs)
  Assert.deepEqual(
    assert(compiled.interactive, version .. " start menu section must publish its interactive position records"),
    FieldUiFixture.startMenuInteractive(),
    version .. " publishes the seven source positions"
  )
  Assert.isNil(compiled.slots, version .. " normal selector publishes no synthetic slot grid")

  local function visualPixels(visual)
    local asset = assert(bundle.manifest.assets[assert(visual.asset)], "the visual asset must be indexed")
    local bytes = assert(bundle.assets[assert(asset.image)], "the visual atlas must have pixels")
    local width, _, rgba = PngReader.rgba(bytes)
    local rect = visual.rect
    Assert.isTrue(
      rect.x >= 0 and rect.y >= 0 and rect.x + rect.width <= asset.width and rect.y + rect.height <= asset.height,
      version .. " visual rect stays inside its atlas"
    )
    local region = {}
    for y = 0, rect.height - 1 do
      local rowStart = (rect.y + y) * width * 4
      region[#region + 1] = rgba:sub(rowStart + rect.x * 4 + 1, rowStart + (rect.x + rect.width) * 4)
    end
    return table.concat(region)
  end

  local function assertVisualStates(visual, what)
    for _, key in ipairs({ "normal", "selected" }) do
      local state = assert(visual[key], version .. " " .. what .. " carries its " .. key .. " state")
      for _, field in ipairs({ "x", "y" }) do
        local v = assert(state.offset, version .. " " .. what .. " " .. key .. " carries its frame offset")[field]
        Assert.isTrue(type(v) == "number" and v % 1 == 0, version .. " " .. what .. " offset stays integral")
      end
    end
    return visual
  end

  local function assertVisual(row, what)
    local visual = assert(row.visual, version .. " " .. what .. " must carry its source-composed visual")
    Assert.isNil(row.rect, version .. " " .. what .. " carries no fixed crop rect")
    return assertVisualStates(visual, what)
  end

  for _, index in ipairs({ 1, 2, 3, 4, 5, 6, 7, 8, 12, 13 }) do
    local row = assert(compiled.iconTable[index], "icon row " .. index .. " must exist")
    local visual = assertVisual(row, "icon row " .. index)
    Assert.isTrue(
      visualPixels(visual.selected) ~= visualPixels(visual.normal),
      version .. " icon row " .. index .. " selected state renders through the selection palette"
    )
  end
  local bag = assert(compiled.iconTable[3], "the bag row must exist")
  local female = assert(bag.variants and bag.variants.female, version .. " bag row carries its female variant")
  local femaleVisual = assertVisualStates(female, "bag female variant")
  Assert.isTrue(
    visualPixels(femaleVisual.normal) ~= visualPixels(assert(bag.visual, "the bag row carries its visual").normal),
    version .. " female art renders its own composed frame"
  )
  Assert.isTrue(FieldUiAssetCache.validateManifest(bundle.manifest))
end

return require("tests.rom.support.RomSuite").fromFacts(T)
