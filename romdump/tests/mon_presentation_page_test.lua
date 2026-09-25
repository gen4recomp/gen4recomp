-- Bounded mon presentation pages: the semantic catalog stages without touching
-- pixel decoders, selector layout packs at most sixteen two-frame visuals per
-- fixed page with aliases sharing one slot, the layout is deterministic, page
-- repacking leaves the semantic fingerprint and saved-mon legality alone, and
-- partial page sets report staged readiness levels without reading as a
-- complete family. Fixtures below drive the real production entry points with
-- a synthetic source filesystem, so planning, paging, and staging are proved
-- without a user-owned dump.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local GameVersion = require("romdump.src.source.GameVersion")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local Hashing = require("romdump.src.digest.Hashing")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local LuaWriter = require("libs.codec.src.LuaWriter")
local MonAssetSchema = require("libs.assets.src.MonAssetSchema")
local MonCache = require("libs.assets.src.MonCache")
local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonCatalogCompiler = require("romdump.src.digest.mons.MonCatalogCompiler")
local MonPresentationCompiler = require("romdump.src.digest.mons.MonPresentationCompiler")
local MonSources = require("romdump.src.config.MonSources")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PngWriter = require("libs.assets.src.PngWriter")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local Schema = require("libs.script.src.Schema")
local Sha256 = require("libs.script.src.Sha256")

local T = {}

local ICON_PAGE_WIDTH = 256
local ICON_PAGE_HEIGHT = 128
local PORTRAIT_PAGE_WIDTH = 640
local PORTRAIT_PAGE_HEIGHT = 320
local VISUALS_PER_PAGE = 16

local function u16(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end

local function u32(v)
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
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
  return magic:reverse() .. u32(8 + #payload) .. payload
end

local function charBlock(tiles, depth)
  local payload = u16(8) .. u16(0x20) .. u32(depth) .. u16(0) .. u16(0) .. u32(0) .. u32(#tiles) .. u32(0x18) .. tiles
  return block("CHAR", payload)
end

local function paletteBlock(colors)
  local body = {}
  for _, c in ipairs(colors) do
    body[#body + 1] = u16(c)
  end
  return block("PLTT", string.char(3, 0) .. u16(#colors) .. u32(0) .. u32(12) .. table.concat(body))
end

-- Icon shared cells: exactly two cells so the two animation frames resolve.
-- Payload: cell count, entry size 0 (8-byte entries), metatile table offset,
-- boundary word, twelve reserved bytes, then one 8-byte metatile entry per
-- cell (object count, reserved halfword, object-table byte offset) followed
-- by the 6-byte OAM attributes.
local function iconCellBlock()
  local entries = u16(1) .. u16(0) .. u32(0) .. u16(1) .. u16(0) .. u32(6)
  local attrs = (u16(0) .. u16(0) .. u16(0)):rep(2)
  return block("CEBK", u16(2) .. u16(0) .. u32(0x18) .. u32(0) .. string.rep("\0", 12) .. entries .. attrs)
end

-- Icon animation: one animation of two frames showing cell 0 then cell 1.
local function iconAnimBlock()
  local frames = { { duration = 6, cell = 0 }, { duration = 6, cell = 1 } }
  local header = u16(1)
    .. u16(#frames)
    .. u32(0x18)
    .. u32(0x18 + 16)
    .. u32(0x18 + 16 + 8 * #frames)
    .. string.rep("\0", 8)
  local entry = u32(#frames) .. u16(0) .. u16(1) .. u32(1) .. u32(0)
  local frameBlocks, frameData = {}, {}
  for i, f in ipairs(frames) do
    frameBlocks[#frameBlocks + 1] = u32((i - 1) * 2) .. u16(f.duration) .. u16(0)
    frameData[#frameData + 1] = u16(f.cell)
  end
  return block("ABNK", header .. entry .. table.concat(frameBlocks) .. table.concat(frameData))
end

local function iconTiles()
  return string.rep(string.char(0x11), 1024)
end

local function iconPaletteWords()
  local words = { 0x0000 }
  for _ = 2, 256 do
    words[#words + 1] = 0x7FFF
  end
  return words
end

local function portraitPaletteWords()
  return {
    0x0000,
    0x001F,
    0x03E0,
    0x7C00,
    0x7FFF,
    0x03FF,
    0x7C1F,
    0x7FE0,
    0x4210,
    0x0200,
    0x4000,
    0x0010,
    0x5294,
    0x1CE7,
    0x6318,
    0x0E73,
  }
end

local function portraitTiles()
  local words = {}
  for i = 1, 3200 do
    words[i] = (i * 257) % 65536
  end
  words[1] = 0x0102
  local parts = {}
  for _, word in ipairs(words) do
    parts[#parts + 1] = string.char(word % 256, math.floor(word / 256) % 256)
  end
  return table.concat(parts)
end

local function allZero(size)
  return string.rep("\0", size)
end

local function messageBank(count)
  local messages = {}
  for _ = 1, count do
    messages[#messages + 1] = { 0x012F, 0xFFFF }
  end
  return messages
end

-- Every portrait character/palette member id the source selection can name
-- for the reachable species and forms, so the fixture serves character
-- payloads exactly where the producer resolves them and palettes elsewhere.
local function portraitMemberRoles()
  local charIds, palIds = {}, {}
  for speciesId = 0, MonSources.BAD_EGG_SPECIES do
    for _, form in ipairs(MonSources.runtimeForms(speciesId)) do
      for _, gender in ipairs({ "male", "female" }) do
        for _, shiny in ipairs({ false, true }) do
          local ids = MonSources.portraitIds(speciesId, gender, 2, shiny, form)
          if ids.narc == "pokemon_graphics" or ids.narc == "pokemon_graphics_other" then
            charIds[ids.narc] = charIds[ids.narc] or {}
            palIds[ids.narc] = palIds[ids.narc] or {}
            charIds[ids.narc][ids.charMemberId] = true
            palIds[ids.narc][ids.palMemberId] = true
          end
        end
      end
    end
  end
  return charIds, palIds
end

local function fixedArchive(count, fn)
  return {
    memberCount = function()
      return count
    end,
    readMember = function(_, memberId)
      return fn(memberId)
    end,
  }
end

local function syntheticRomFs()
  local charIds, palIds = portraitMemberRoles()
  local portraitChars = container("RGCN", { charBlock(portraitTiles(), 3) })
  local portraitPal = container("NCLR", { paletteBlock(portraitPaletteWords()) })
  local banks = {
    [237] = FieldMessageBank.encodeForTests(messageBank(496), 0x1237),
    [750] = FieldMessageBank.encodeForTests(messageBank(468), 0x1750),
    [749] = FieldMessageBank.encodeForTests(messageBank(468), 0x1749),
    [720] = FieldMessageBank.encodeForTests(messageBank(124), 0x1720),
    [722] = FieldMessageBank.encodeForTests(messageBank(124), 0x1722),
  }
  local iconPalette = container("NCLR", { paletteBlock(iconPaletteWords()) })
  local iconAnim = container("RNAN", { iconAnimBlock() })
  local iconCells = container("RECN", { iconCellBlock() })
  local iconChar = container("RGCN", { charBlock(iconTiles(), 3) })
  local archives = {
    personal = fixedArchive(508, function(memberId)
      if memberId == 132 then
        return allZero(16) .. "\255" .. allZero(27)
      end
      return allZero(44)
    end),
    growth_tables = fixedArchive(8, function()
      return allZero(404)
    end),
    level_up_moves = fixedArchive(508, function()
      return "\255\255"
    end),
    evolutions = fixedArchive(508, function()
      return allZero(44)
    end),
    moves = fixedArchive(468, function()
      return allZero(16)
    end),
    messages = fixedArchive(3000, function(memberId)
      local member = banks[memberId]
      assert(member ~= nil, "unexpected message bank " .. tostring(memberId))
      return member
    end),
    follower_params = fixedArchive(4096, function()
      return allZero(4)
    end),
    item_data = fixedArchive(537, function()
      return allZero(34)
    end),
    pokemon_icons = fixedArchive(2048, function(memberId)
      if memberId == 0 then
        return iconPalette
      end
      if memberId == 1 then
        return iconAnim
      end
      if memberId == 2 then
        return iconCells
      end
      return iconChar
    end),
  }
  for _, alias in ipairs({ "pokemon_graphics", "pokemon_graphics_other" }) do
    archives[alias] = fixedArchive(4096, function(memberId)
      if charIds[alias] ~= nil and charIds[alias][memberId] then
        return portraitChars
      end
      if palIds[alias] ~= nil and palIds[alias][memberId] then
        return portraitPal
      end
      assert(
        charIds[alias] == nil or charIds[alias][memberId] == nil,
        "unreachable portrait member " .. tostring(memberId)
      )
      return portraitPal
    end)
  end
  local fs = {}
  function fs:openNarc(alias)
    local archive = archives[alias]
    assert(archive ~= nil, "unexpected archive " .. tostring(alias))
    return archive
  end
  function fs:version()
    return "heartgold"
  end
  function fs:metadata()
    return { sha1 = "synthetic-rom-sha" }
  end
  return fs
end

local function compileCatalog()
  local romFs = syntheticRomFs()
  local catalog, err = MonCatalogCompiler.compileCatalog(romFs, { versionId = "heartgold" })
  if catalog == nil then
    error("synthetic catalog failed: " .. tostring(err and err.code or err), 0)
  end
  return catalog, romFs
end

local HEARTGOLD_SHA1 = GameVersion.VERSIONS.heartgold.sha1

local function generationIdFor(producerBody)
  local identity = DerivedCacheState.current({
    versionId = "heartgold",
    romSha1 = HEARTGOLD_SHA1,
    mode = "development",
    producerId = "d" .. producerBody,
    assetRevision = DerivedAssetContract.revision,
    scriptApi = Schema.API_VERSION,
  })
  return assert(identity.generationId)
end

local function newArtifact(cache, generation, kind, key, stageName)
  return PreparedArtifact.new({
    cacheFs = cache,
    generationId = generation,
    epoch = 1,
    kind = kind,
    key = key,
    jobKey = kind .. ":" .. key,
    stageName = stageName,
  })
end

local function publishArtifact(artifact, generation, kind, key, marker)
  artifact:finishSuccess({ marker = marker })
  artifact:publish({
    generationId = generation,
    epoch = 1,
    kind = kind,
    key = key,
    jobKey = kind .. ":" .. key,
  })
end

-- Locate one page source plan without assuming the container shape: page-id
-- keyed tables and consecutive arrays are both accepted.
local function pagePlanFor(planned, kind, pageId)
  local field = kind == "icons" and "iconPages" or "portraitPages"
  local pages = assert(planned[field], kind .. " planning carries its page plans")
  if pages[pageId] ~= nil then
    return pages[pageId]
  end
  if pages[pageId + 1] ~= nil then
    return pages[pageId + 1]
  end
  error("no " .. kind .. " page plan for page " .. tostring(pageId), 0)
end

local function compilePageForSelector(romFs, planned, kind, selector)
  local manifestField = kind == "icons" and "icons" or "portraits"
  local entry = assert(planned[manifestField].entries[selector], selector .. " must be planned")
  local bundle, err = MonPresentationCompiler.compilePage(romFs, kind, pagePlanFor(planned, kind, entry.pageId))
  if bundle == nil then
    error("page compilation failed for " .. selector .. ": " .. tostring(err and err.code or err), 0)
  end
  return bundle, entry
end

local function subRect(pixels, width, x, y, w, h)
  local parts = {}
  for row = 0, h - 1 do
    local base = ((y + row) * width + x) * 4
    parts[#parts + 1] = pixels:sub(base + 1, base + w * 4)
  end
  return table.concat(parts)
end

-- Group manifest entries by their shared visual slot: aliases resolve to one
-- source visual exactly when they share page and rectangles.
local function pageGroups(manifest)
  local groups = {}
  for selector, entry in pairs(manifest.entries) do
    local key = entry.pageId .. ":" .. entry.x .. ":" .. entry.y
    local group = groups[key]
    if group == nil then
      group = { pageId = entry.pageId, selectors = {} }
      groups[key] = group
    end
    group.selectors[#group.selectors + 1] = selector
  end
  local list = {}
  for _, group in pairs(groups) do
    table.sort(group.selectors)
    group.rep = group.selectors[1]
    list[#list + 1] = group
  end
  table.sort(list, function(a, b)
    if a.pageId ~= b.pageId then
      return a.pageId < b.pageId
    end
    return a.rep < b.rep
  end)
  return list
end

local function assertPagedManifest(manifest, pageWidth, pageHeight, what)
  Assert.notNil(manifest.pages, what .. " manifest carries its pages")
  Assert.notNil(manifest.pageIds, what .. " manifest carries its page inventory")
  local pageCount = 0
  for pageId, page in pairs(manifest.pages) do
    Assert.equal(page.pageId, pageId, what .. " page carries its own id")
    Assert.equal(page.width, pageWidth, what .. " page keeps its width")
    Assert.equal(page.height, pageHeight, what .. " page keeps its height")
    pageCount = pageCount + 1
  end
  Assert.isTrue(pageCount > 1, what .. " planning spans more than one page")
  for position, pageId in ipairs(manifest.pageIds) do
    Assert.equal(pageId, position - 1, what .. " page ids are consecutive from zero")
    Assert.notNil(manifest.pages[pageId], what .. " inventory names a declared page")
  end
  Assert.equal(#manifest.pageIds, pageCount, what .. " inventory covers every page")
  local groups = pageGroups(manifest)
  Assert.isTrue(#groups > VISUALS_PER_PAGE, what .. " planning carries more than one page of visuals")
  local perPage = {}
  local lastRep = nil
  for _, group in ipairs(groups) do
    perPage[group.pageId] = (perPage[group.pageId] or 0) + 1
    if lastRep ~= nil then
      Assert.isTrue(
        lastRep < group.rep,
        what .. " groups stay in representative order (" .. lastRep .. " before " .. group.rep .. ")"
      )
    end
    lastRep = group.rep
    for _, selector in ipairs(group.selectors) do
      local entry = manifest.entries[selector]
      local page = assert(manifest.pages[entry.pageId], what .. " entry " .. selector .. " names a declared page")
      Assert.isTrue(
        entry.x + entry.width <= page.width and entry.y + entry.height <= page.height,
        what .. " entry " .. selector .. " stays inside its page bounds"
      )
      for _, frame in ipairs(entry.frames) do
        Assert.isTrue(
          frame.x + frame.width <= page.width and frame.y + frame.height <= page.height,
          what .. " entry " .. selector .. " keeps every frame inside its page bounds"
        )
      end
    end
  end
  for pageId, count in pairs(perPage) do
    Assert.isTrue(count <= VISUALS_PER_PAGE, what .. " page " .. pageId .. " holds at most sixteen visuals")
  end
  return groups
end

local function trapPixelDecoders(counts)
  local saved = {}
  local function trap(module, name)
    saved[name] = module[name]
    module[name] = function(...)
      counts[name] = (counts[name] or 0) + 1
      if counts.failOn ~= nil and counts.failOn[name] then
        error("trapped " .. name, 0)
      end
      return saved[name](...)
    end
  end
  trap(G2dDecoder, "decodeChar")
  trap(G2dDecoder, "decodePalette")
  trap(G2dDecoder, "decodeAnimation")
  trap(G2dDecoder, "decodeCell")
  return saved
end

local function restorePixelDecoders(saved)
  G2dDecoder.decodeChar = saved.decodeChar
  G2dDecoder.decodePalette = saved.decodePalette
  G2dDecoder.decodeAnimation = saved.decodeAnimation
  G2dDecoder.decodeCell = saved.decodeCell
end

function T.catalog_stages_without_rasterizing_any_pixels()
  Assert.equal(type(MonCacheWriter.stageCatalog), "function", "semantic catalogs stage apart from pixels")
  Assert.equal(type(MonCache.isCatalogReady), "function", "catalog readiness is separate from page readiness")
  Assert.equal(type(MonCache.iconPagePath), "function", "icon pages have their own path constructor")
  local counts = { failOn = { decodeChar = true, decodePalette = true, decodeAnimation = true, decodeCell = true } }
  local saved = trapPixelDecoders(counts)
  local pngEncode = PngWriter.encode
  PngWriter.encode = function()
    error("catalog staging must not encode pixels", 0)
  end
  local ok, err = pcall(function()
    local catalog = compileCatalog()
    local cache = CacheFs.forVersion("heartgold", FakeCache.new())
    local generation = generationIdFor(Sha256.hex("mon catalog stage"))
    local marker = MonCache.marker("synthetic-rom-sha", Hashing.hashLua(catalog))
    local artifact = newArtifact(cache, generation, "mon-catalog", "global", "mon-catalog-stage")
    local staged = MonCacheWriter.stageCatalog(artifact, { catalog = catalog, marker = marker })
    if type(staged) ~= "string" then
      staged = marker
    end
    publishArtifact(artifact, generation, "mon-catalog", "global", staged)
    Assert.isTrue(MonCache.isCatalogReady(cache, staged), "the staged catalog reads ready")
    Assert.isFalse(cache:exists(MonCache.iconImagePath(), "file"), "catalog staging writes no icon atlas")
    Assert.isFalse(cache:exists(MonCache.portraitImagePath(), "file"), "catalog staging writes no portrait atlas")
    Assert.isFalse(cache:exists(MonCache.iconPagePath(0), "file"), "catalog staging writes no icon pages")
    Assert.equal(type(MonCache.portraitPagePath), "function", "portrait pages have their own path constructor")
    Assert.isFalse(cache:exists(MonCache.portraitPagePath(0), "file"), "catalog staging writes no portrait pages")
  end)
  PngWriter.encode = pngEncode
  restorePixelDecoders(saved)
  if not ok then
    error(err, 0)
  end
  Assert.equal(counts.decodeChar or 0, 0, "catalog compilation decodes no character tiles")
  Assert.equal(counts.decodePalette or 0, 0, "catalog compilation decodes no palettes")
end

function T.pages_hold_at_most_sixteen_visuals_with_shared_alias_slots()
  Assert.equal(type(MonPresentationCompiler.plan), "function", "selector layout plans without pixels")
  Assert.equal(type(MonPresentationCompiler.compilePage), "function", "pages compile one at a time")
  local catalog, romFs = compileCatalog()
  local planned = assert(MonPresentationCompiler.plan(romFs, catalog))
  MonAssetSchema.assertIconManifest(planned.icons)
  MonAssetSchema.assertPortraitManifest(planned.portraits)
  assertPagedManifest(planned.icons, ICON_PAGE_WIDTH, ICON_PAGE_HEIGHT, "icon")
  assertPagedManifest(planned.portraits, PORTRAIT_PAGE_WIDTH, PORTRAIT_PAGE_HEIGHT, "portrait")
  local icons = planned.icons.entries
  local chikoritaEgg = assert(icons["CHIKORITA/egg"], "egg selectors stay planned")
  local bulbasaurEgg = assert(icons["BULBASAUR/egg"], "egg selectors stay planned")
  Assert.deepEqual(
    { chikoritaEgg.pageId, chikoritaEgg.x, chikoritaEgg.y },
    { bulbasaurEgg.pageId, bulbasaurEgg.x, bulbasaurEgg.y },
    "egg selectors aliasing one source visual share one page slot"
  )
  local unownOne = assert(icons["UNOWN/f1"], "alternate forms stay planned")
  local unownTwo = assert(icons["UNOWN/f2"], "alternate forms stay planned")
  Assert.isTrue(
    unownOne.pageId ~= unownTwo.pageId or unownOne.x ~= unownTwo.x or unownOne.y ~= unownTwo.y,
    "distinct alternate forms keep distinct page slots"
  )
  local counts = {}
  local saved = trapPixelDecoders(counts)
  local bundle
  local ok, err = pcall(function()
    bundle = compilePageForSelector(romFs, planned, "icons", "CHIKORITA/f0")
    Assert.equal(bundle.width, ICON_PAGE_WIDTH, "icon pages keep their fixed width")
    Assert.equal(bundle.height, ICON_PAGE_HEIGHT, "icon pages keep their fixed height")
    Assert.equal(#bundle.pixels, ICON_PAGE_WIDTH * ICON_PAGE_HEIGHT * 4, "icon pages carry exactly one page buffer")
  end)
  restorePixelDecoders(saved)
  if not ok then
    error(err, 0)
  end
  Assert.isTrue((counts.decodeChar or 0) <= VISUALS_PER_PAGE, "one page decodes at most sixteen visuals")
  Assert.isTrue((counts.decodeChar or 0) > 0, "page compilation decodes its own visuals")
  local whole = assert(MonPresentationCompiler.compileIcons(romFs, catalog))
  for _, selector in ipairs({ "CHIKORITA/f0", "CHIKORITA/egg" }) do
    local wanted = assert(planned.icons.entries[selector], selector .. " stays planned")
    -- Distinct visuals live on their own pages by construction (aliases
    -- share one slot, nothing else shares); each selector proves its pixels
    -- from the page its own entry names.
    local own =
      assert(MonPresentationCompiler.compilePage(romFs, "icons", pagePlanFor(planned, "icons", wanted.pageId)))
    local wholeEntry = assert(whole.manifest.entries[selector], selector .. " keeps its baseline entry")
    Assert.equal(#wanted.frames, #wholeEntry.frames, selector .. " keeps its frame count")
    for index, frame in ipairs(wanted.frames) do
      Assert.equal(frame.duration, wholeEntry.frames[index].duration, selector .. " keeps its frame timing")
    end
    Assert.equal(
      subRect(own.pixels, own.width, wanted.x, wanted.y, wanted.width, wanted.height),
      subRect(whole.image.pixels, whole.image.width, wholeEntry.x, wholeEntry.y, wholeEntry.width, wholeEntry.height),
      selector .. " keeps its source pixels"
    )
  end

  -- A final partial page keeps its full dimensions with transparent unused
  -- cells. Covered cells come from the manifest itself, so no packing order
  -- is assumed: any grid cell no frame addresses must read fully transparent.
  local function assertPartialTransparency(kind, width, height, cell)
    local manifest = kind == "icons" and planned.icons or planned.portraits
    local lastPage = manifest.pageIds[#manifest.pageIds]
    local covered = {}
    for _, entry in pairs(manifest.entries) do
      if entry.pageId == lastPage then
        for _, frame in ipairs(entry.frames) do
          covered[frame.x .. ":" .. frame.y] = true
        end
      end
    end
    local freeX, freeY = nil, nil
    for cy = 0, (height / cell) - 1 do
      for cx = 0, (width / cell) - 1 do
        if not covered[(cx * cell) .. ":" .. (cy * cell)] then
          freeX, freeY = cx * cell, cy * cell
        end
      end
    end
    if freeX == nil then
      return
    end
    local lastBundle = assert(MonPresentationCompiler.compilePage(romFs, kind, pagePlanFor(planned, kind, lastPage)))
    Assert.equal(lastBundle.width, width, kind .. " final pages keep their fixed width")
    Assert.equal(lastBundle.height, height, kind .. " final pages keep their fixed height")
    local pixels = subRect(lastBundle.pixels, lastBundle.width, freeX, freeY, cell, cell)
    for i = 4, #pixels, 4 do
      Assert.equal(string.byte(pixels, i), 0, kind .. " page " .. lastPage .. " leaves unused cells transparent")
    end
  end
  assertPartialTransparency("icons", ICON_PAGE_WIDTH, ICON_PAGE_HEIGHT, 32)
  assertPartialTransparency("portraits", PORTRAIT_PAGE_WIDTH, PORTRAIT_PAGE_HEIGHT, 80)
end

function T.page_layout_is_deterministic_across_enumeration_orders()
  Assert.equal(type(MonPresentationCompiler.plan), "function", "selector layout plans without pixels")
  local catalog, romFs = compileCatalog()
  local reversed = {
    schema = catalog.schema,
    version = catalog.version,
    species = {},
    moves = catalog.moves,
    abilities = catalog.abilities,
    growthCurves = catalog.growthCurves,
    items = catalog.items,
  }
  local keys = {}
  for key in pairs(catalog.species) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return a > b
  end)
  for _, key in ipairs(keys) do
    reversed.species[key] = catalog.species[key]
  end
  local first = assert(MonPresentationCompiler.plan(romFs, catalog))
  local second = assert(MonPresentationCompiler.plan(romFs, reversed))
  Assert.equal(LuaWriter.encode(first.icons), LuaWriter.encode(second.icons), "icon layout is enumeration independent")
  Assert.equal(
    LuaWriter.encode(first.portraits),
    LuaWriter.encode(second.portraits),
    "portrait layout is enumeration independent"
  )
  assertPagedManifest(first.icons, ICON_PAGE_WIDTH, ICON_PAGE_HEIGHT, "icon")
  assertPagedManifest(first.portraits, PORTRAIT_PAGE_WIDTH, PORTRAIT_PAGE_HEIGHT, "portrait")
end

function T.semantic_fingerprint_and_save_legality_survive_repacking()
  Assert.equal(type(MonPresentationCompiler.plan), "function", "selector layout plans without pixels")
  local catalog, romFs = compileCatalog()
  local planned = assert(MonPresentationCompiler.plan(romFs, catalog))
  MonAssetSchema.assertIconManifest(planned.icons)
  local function repack(manifest, pathFor)
    local repacked = { schema = manifest.schema, version = manifest.version, pages = {}, pageIds = {}, entries = {} }
    local maxId = manifest.pageIds[#manifest.pageIds]
    for _, pageId in ipairs(manifest.pageIds) do
      local flipped = maxId - pageId
      local page = manifest.pages[pageId]
      repacked.pages[flipped] = { pageId = flipped, image = pathFor(flipped), width = page.width, height = page.height }
      repacked.pageIds[#repacked.pageIds + 1] = flipped
    end
    table.sort(repacked.pageIds)
    for selector, entry in pairs(manifest.entries) do
      local frames = {}
      for _, frame in ipairs(entry.frames) do
        frames[#frames + 1] = {
          x = frame.x,
          y = frame.y,
          width = frame.width,
          height = frame.height,
          duration = frame.duration,
        }
      end
      repacked.entries[selector] = {
        x = entry.x,
        y = entry.y,
        width = entry.width,
        height = entry.height,
        frames = frames,
        pageId = maxId - entry.pageId,
      }
    end
    repacked.representative = manifest.representative
    return repacked
  end
  local repacked = repack(planned.icons, MonCache.iconPagePath)
  MonAssetSchema.assertIconManifest(repacked)
  Assert.isTrue(#repacked.pageIds > 1, "the repack keeps more than one page")
  local ItemFixture = require("libs.items.tests.item_fixture")
  local first = MonCatalog.new(catalog, ItemFixture.makeCatalog())
  local second = MonCatalog.new(catalog, ItemFixture.makeCatalog())
  Assert.equal(first:fingerprint(), second:fingerprint(), "the semantic fingerprint ignores page packing")
  Assert.isTrue(
    LuaWriter.encode(catalog):find("pageId") == nil,
    "page packing lives outside the fingerprinted semantic serialization"
  )
  local bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x12345678):capture(), first:fingerprint())
  local ok, failure = pcall(MonsSave.validate, bucket, { catalog = second })
  Assert.isTrue(ok, "saved-mon legality survives a page repacking: " .. tostring(failure))
end

function T.partial_page_sets_report_staged_readiness_levels()
  Assert.equal(type(MonCacheWriter.stageCatalog), "function", "semantic catalogs stage apart from pixels")
  Assert.equal(type(MonCacheWriter.stageLayout), "function", "selector layouts stage apart from pixels")
  Assert.equal(type(MonCacheWriter.stagePage), "function", "pages stage one at a time")
  Assert.equal(type(MonCache.isCatalogReady), "function", "catalog readiness is separate from page readiness")
  Assert.equal(type(MonCache.isLayoutReady), "function", "layout readiness is separate from page readiness")
  Assert.equal(type(MonCache.isIconSetReady), "function", "icon-set readiness is separate from full readiness")
  Assert.equal(type(MonCache.isPageReady), "function", "page readiness is separate from full readiness")
  local catalog, romFs = compileCatalog()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local generation = generationIdFor(Sha256.hex("mon partial readiness"))
  local catalogMarker = MonCache.marker("synthetic-rom-sha", Hashing.hashLua(catalog))
  local catalogStage = newArtifact(cache, generation, "mon-catalog", "global", "mon-catalog-partial")
  local stagedCatalog = MonCacheWriter.stageCatalog(catalogStage, { catalog = catalog, marker = catalogMarker })
  if type(stagedCatalog) ~= "string" then
    stagedCatalog = catalogMarker
  end
  publishArtifact(catalogStage, generation, "mon-catalog", "global", stagedCatalog)
  Assert.isTrue(MonCache.isCatalogReady(cache, stagedCatalog), "the staged catalog reads ready")
  Assert.isFalse(MonCache.isLayoutReady(cache, "no-layout-published"), "layout stays unread before its own stage")
  local planned = assert(MonPresentationCompiler.plan(romFs, catalog))
  local layoutMarker = MonCache.marker("synthetic-rom-sha", Hashing.hashLua({ planned.icons, planned.portraits }))
  local layoutStage = newArtifact(cache, generation, "mon-layout", "global", "mon-layout-partial")
  local stagedLayout = MonCacheWriter.stageLayout(layoutStage, {
    icons = planned.icons,
    portraits = planned.portraits,
    marker = layoutMarker,
    pagePlans = { iconPages = planned.iconPages, portraitPages = planned.portraitPages },
    generationId = generation,
  })
  if type(stagedLayout) ~= "string" then
    stagedLayout = layoutMarker
  end
  publishArtifact(layoutStage, generation, "mon-layout", "global", stagedLayout)
  Assert.isTrue(MonCache.isLayoutReady(cache, stagedLayout), "the staged layout reads ready")
  Assert.isFalse(
    MonCache.isPageReady(cache, "icons", 0, "no-page-published"),
    "icon pages stay unread before their own stages"
  )
  local iconMarkers = {}
  local iconCount = 0
  for _ in pairs(planned.iconPages) do
    iconCount = iconCount + 1
  end
  local staged = 0
  for _, pagePlan in pairs(planned.iconPages) do
    local page = assert(MonPresentationCompiler.compilePage(romFs, "icons", pagePlan))
    -- compilePage returns pixels without a marker; the staged bundle pairs
    -- the compiled page with its marker explicitly.
    local bundle = {
      kind = "icons",
      pageId = page.pageId,
      width = page.width,
      height = page.height,
      pixels = page.pixels,
      marker = MonCache.marker("synthetic-rom-sha", "icon-page-" .. staged),
    }
    local pageId = bundle.pageId
    if pageId == nil then
      pageId = staged
    end
    local artifact = newArtifact(cache, generation, "mon-icon-page", tostring(pageId), "mon-icon-page-" .. staged)
    local marker = MonCacheWriter.stagePage(artifact, bundle)
    if type(marker) ~= "string" then
      marker = bundle.marker
    end
    publishArtifact(artifact, generation, "mon-icon-page", tostring(pageId), marker)
    iconMarkers[pageId] = marker
    staged = staged + 1
  end
  Assert.equal(staged, iconCount, "every planned icon page stages")
  Assert.isTrue(MonCache.isIconSetReady(cache, iconMarkers), "the complete icon set reads ready")
  local portraitPlan = pagePlanFor(planned, "portraits", 0)
  local portraitPage = assert(MonPresentationCompiler.compilePage(romFs, "portraits", portraitPlan))
  local portraitBundle = {
    kind = "portraits",
    pageId = portraitPage.pageId,
    width = portraitPage.width,
    height = portraitPage.height,
    pixels = portraitPage.pixels,
    marker = MonCache.marker("synthetic-rom-sha", "portrait-page-0"),
  }
  local portraitPageId = portraitBundle.pageId or 0
  local portraitArtifact =
    newArtifact(cache, generation, "mon-portrait-page", tostring(portraitPageId), "mon-portrait-page-0")
  local portraitMarker = MonCacheWriter.stagePage(portraitArtifact, portraitBundle)
  if type(portraitMarker) ~= "string" then
    portraitMarker = portraitBundle.marker
  end
  publishArtifact(portraitArtifact, generation, "mon-portrait-page", tostring(portraitPageId), portraitMarker)
  Assert.isTrue(
    MonCache.isPageReady(cache, "icons", 0, iconMarkers[0]),
    "a staged icon page reads ready under its own marker"
  )
  Assert.isTrue(
    MonCache.isPageReady(cache, "portraits", portraitPageId, portraitMarker),
    "a staged portrait page reads ready under its own marker"
  )
  Assert.isFalse(
    MonCache.isPageReady(cache, "portraits", portraitPageId + 1000000, "no-such-page"),
    "an unstaged portrait page never reads ready"
  )
  Assert.isFalse(
    MonCache.isReady(cache, "no-summary-published"),
    "catalog, layout, icons, and one portrait page never read as a complete family"
  )
end

function T.malformed_pages_and_selectors_fail_before_publishing()
  Assert.equal(type(MonPresentationCompiler.plan), "function", "selector layout plans without pixels")
  Assert.equal(type(MonPresentationCompiler.compilePage), "function", "pages compile one at a time")
  Assert.equal(type(MonCacheWriter.stagePage), "function", "pages stage one at a time")
  local catalog, romFs = compileCatalog()
  local planned = assert(MonPresentationCompiler.plan(romFs, catalog))
  local bundle = assert(MonPresentationCompiler.compilePage(romFs, "icons", pagePlanFor(planned, "icons", 0)))
  local broken = {
    kind = bundle.kind,
    pageId = bundle.pageId,
    width = bundle.width,
    height = bundle.height,
    pixels = "short",
    marker = "broken-marker",
  }
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local generation = generationIdFor(Sha256.hex("mon malformed page"))
  local artifact = newArtifact(cache, generation, "mon-icon-page", "0", "mon-icon-page-broken")
  local ok, stageErr = pcall(MonCacheWriter.stagePage, artifact, broken)
  Assert.isFalse(ok, "a truncated page buffer must not stage: " .. tostring(stageErr))
  artifact:abort()
  Assert.isFalse(MonCache.isPageReady(cache, "icons", 0, "broken-marker"), "a rejected page never reads ready")
  local escaped = {
    schema = planned.icons.schema,
    version = planned.icons.version,
    pages = planned.icons.pages,
    pageIds = planned.icons.pageIds,
    entries = {},
    representative = planned.icons.representative,
  }
  for selector, entry in pairs(planned.icons.entries) do
    escaped.entries[selector] = entry
  end
  escaped.entries["CHIKORITA/f0"] = {
    x = 10000,
    y = 10000,
    width = 32,
    height = 32,
    frames = { { x = 10000, y = 10000, width = 32, height = 32, duration = 6 } },
    pageId = 0,
  }
  local valid, manifestErr = pcall(MonAssetSchema.assertIconManifest, escaped)
  Assert.isFalse(valid, "a page-local rectangle escaping its page must not validate: " .. tostring(manifestErr))
  Assert.isTrue(Errors.is(manifestErr) or type(manifestErr) == "string", "the rejection stays diagnosable")
end

return { tests = T }
