-- Page rectangles keep source semantics: selected icon and portrait page
-- rectangles match the per-visual decode results exactly (RGBA bytes, frame
-- order, and durations) across ordinary, shiny, genderless, alternate-form,
-- and egg cases, and each page compiles directly from its own source records
-- without decoding the whole corpus.

local Assert = require("tests.support.Assert")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local MonCache = require("libs.assets.src.MonCache")
local MonCatalogCompiler = require("romdump.src.digest.mons.MonCatalogCompiler")
local MonPresentationCompiler = require("romdump.src.digest.mons.MonPresentationCompiler")

local T = {}

local ICON_PAGE_WIDTH = 256
local ICON_PAGE_HEIGHT = 128
local PORTRAIT_PAGE_WIDTH = 640
local PORTRAIT_PAGE_HEIGHT = 320
local PORTRAIT_PAYLOAD_BOUND = 819200

local function subRect(pixels, width, x, y, w, h)
  local parts = {}
  for row = 0, h - 1 do
    local base = ((y + row) * width + x) * 4
    parts[#parts + 1] = pixels:sub(base + 1, base + w * 4)
  end
  return table.concat(parts)
end

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

function T.selected_page_rectangles_match_per_visual_decodes(romFs, versionId)
  Assert.equal(type(MonPresentationCompiler.plan), "function", "selector layout plans without pixels")
  Assert.equal(type(MonPresentationCompiler.compilePage), "function", "pages compile one at a time")
  local catalog = assert(MonCatalogCompiler.compileCatalog(romFs, { versionId = versionId }))
  local ditto = assert(catalog.species.DITTO, "DITTO stays in the catalog")
  local dittoPortrait = assert(ditto.forms[0].portrait, "the genderless default portrait stays catalogued")
  local dittoShiny = dittoPortrait:gsub("/plain$", "/shiny")
  Assert.isTrue(dittoShiny ~= dittoPortrait, "the genderless shiny selector stays distinct")
  local iconCases = { "CHIKORITA/f0", "CHIKORITA/egg", "UNOWN/f1" }
  local portraitCases = {
    MonCache.portraitSelector("CHIKORITA", 0, "male", false),
    MonCache.portraitSelector("TOTODILE", 0, "male", true),
    dittoPortrait,
    dittoShiny,
    MonCache.portraitSelector("ROTOM", 1, "female", false),
  }
  local planCounts = { decodeChar = 0 }
  local savedChar = G2dDecoder.decodeChar
  G2dDecoder.decodeChar = function(...)
    planCounts.decodeChar = planCounts.decodeChar + 1
    return savedChar(...)
  end
  local planOk, planned = pcall(MonPresentationCompiler.plan, romFs, catalog)
  G2dDecoder.decodeChar = savedChar
  Assert.isTrue(planOk, "layout planning must succeed: " .. tostring(planned))
  planned = assert(planned)
  Assert.equal(planCounts.decodeChar, 0, "layout planning decodes no pixel payloads")
  local wholeIcons = assert(MonPresentationCompiler.compileIcons(romFs, catalog))
  local wholePortraits = assert(MonPresentationCompiler.compilePortraits(romFs, catalog))
  local function checkIconCase(selector)
    local wanted = assert(planned.icons.entries[selector], selector .. " stays planned")
    local expected = assert(wholeIcons.manifest.entries[selector], selector .. " keeps its per-visual entry")
    local counts = { decodeChar = 0, decodePalette = 0 }
    local saved = { char = G2dDecoder.decodeChar, palette = G2dDecoder.decodePalette }
    G2dDecoder.decodeChar = function(...)
      counts.decodeChar = counts.decodeChar + 1
      return saved.char(...)
    end
    G2dDecoder.decodePalette = function(...)
      counts.decodePalette = counts.decodePalette + 1
      return saved.palette(...)
    end
    local ok, bundle =
      pcall(MonPresentationCompiler.compilePage, romFs, "icons", pagePlanFor(planned, "icons", wanted.pageId))
    G2dDecoder.decodeChar = saved.char
    G2dDecoder.decodePalette = saved.palette
    Assert.isTrue(ok, "icon page compilation must succeed for " .. selector .. ": " .. tostring(bundle))
    bundle = assert(bundle)
    Assert.isTrue(counts.decodeChar <= 16, selector .. " compiles from at most sixteen decoded visuals")
    Assert.isTrue(counts.decodePalette <= 16, selector .. " compiles from at most sixteen decoded palettes")
    Assert.equal(bundle.width, ICON_PAGE_WIDTH, "icon pages keep their fixed width")
    Assert.equal(bundle.height, ICON_PAGE_HEIGHT, "icon pages keep their fixed height")
    Assert.equal(wanted.width, expected.width, selector .. " keeps its width")
    Assert.equal(wanted.height, expected.height, selector .. " keeps its height")
    Assert.equal(#wanted.frames, #expected.frames, selector .. " keeps its frame count")
    for index, frame in ipairs(wanted.frames) do
      Assert.equal(frame.duration, expected.frames[index].duration, selector .. " keeps its frame timing")
    end
    Assert.equal(
      subRect(bundle.pixels, bundle.width, wanted.x, wanted.y, wanted.width, wanted.height),
      subRect(wholeIcons.image.pixels, wholeIcons.image.width, expected.x, expected.y, expected.width, expected.height),
      selector .. " keeps its source pixels"
    )
  end
  local function checkPortraitCase(selector)
    local wanted = assert(planned.portraits.entries[selector], selector .. " stays planned")
    local expected = assert(wholePortraits.manifest.entries[selector], selector .. " keeps its per-visual entry")
    local counts = { decodeChar = 0, decodePalette = 0 }
    local saved = { char = G2dDecoder.decodeChar, palette = G2dDecoder.decodePalette }
    G2dDecoder.decodeChar = function(...)
      counts.decodeChar = counts.decodeChar + 1
      return saved.char(...)
    end
    G2dDecoder.decodePalette = function(...)
      counts.decodePalette = counts.decodePalette + 1
      return saved.palette(...)
    end
    local ok, bundle =
      pcall(MonPresentationCompiler.compilePage, romFs, "portraits", pagePlanFor(planned, "portraits", wanted.pageId))
    G2dDecoder.decodeChar = saved.char
    G2dDecoder.decodePalette = saved.palette
    Assert.isTrue(ok, "portrait page compilation must succeed for " .. selector .. ": " .. tostring(bundle))
    bundle = assert(bundle)
    Assert.isTrue(counts.decodeChar <= 16, selector .. " compiles from at most sixteen decoded visuals")
    Assert.isTrue(counts.decodePalette <= 16, selector .. " compiles from at most sixteen decoded palettes")
    Assert.equal(bundle.width, PORTRAIT_PAGE_WIDTH, "portrait pages keep their fixed width")
    Assert.equal(bundle.height, PORTRAIT_PAGE_HEIGHT, "portrait pages keep their fixed height")
    Assert.isTrue(#bundle.pixels <= PORTRAIT_PAYLOAD_BOUND, "portrait pages stay within their fixed payload bound")
    Assert.equal(wanted.width, expected.width, selector .. " keeps its width")
    Assert.equal(wanted.height, expected.height, selector .. " keeps its height")
    Assert.equal(#wanted.frames, #expected.frames, selector .. " keeps its frame count")
    Assert.equal(
      subRect(bundle.pixels, bundle.width, wanted.x, wanted.y, wanted.width, wanted.height),
      subRect(
        wholePortraits.image.pixels,
        wholePortraits.image.width,
        expected.x,
        expected.y,
        expected.width,
        expected.height
      ),
      selector .. " keeps its source pixels"
    )
  end
  for _, selector in ipairs(iconCases) do
    checkIconCase(selector)
  end
  for _, selector in ipairs(portraitCases) do
    checkPortraitCase(selector)
  end
end

local suite = require("tests.rom.support.RomSuite").fromFacts(T)
return suite
