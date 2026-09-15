-- Published one-page handoffs keep byte and selector equivalence: a page
-- compiled from its durable record matches the direct leaf compilation in
-- pixels, manifest selectors, and frame rectangles, without whole-corpus
-- image work.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local MonCache = require("libs.assets.src.MonCache")
local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
local MonCatalogCompiler = require("romdump.src.digest.mons.MonCatalogCompiler")
local MonPresentationCompiler = require("romdump.src.digest.mons.MonPresentationCompiler")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")

local T = {}

local function subRect(pixels, width, x, y, w, h)
  local parts = {}
  for row = 0, h - 1 do
    local base = ((y + row) * width + x) * 4
    parts[#parts + 1] = pixels:sub(base + 1, base + w * 4)
  end
  return table.concat(parts)
end

local function selectorOnPage(manifest, pageId)
  for selector, entry in pairs(manifest.entries) do
    if entry.pageId == pageId then
      return selector
    end
  end
  return nil
end

function T.published_handoff_matches_direct_leaf_compilation(romFs, versionId)
  local catalog = assert(MonCatalogCompiler.compileCatalog(romFs, { versionId = versionId }))
  local planned = assert(MonPresentationCompiler.plan(romFs, catalog))
  local romSha1 = romFs:metadata().sha1
  local generation = "rom-equivalence-generation"
  local cache = CacheFs.forVersion(versionId, FakeCache.new())
  local layoutMarker = MonCacheWriter.layoutMarker(romSha1, planned.icons, planned.portraits)
  local layoutArtifact = PreparedArtifact.new({
    cacheFs = cache,
    generationId = generation,
    epoch = 1,
    kind = "mon-layout",
    key = "global",
    jobKey = "mon-layout:global",
    stageName = "equivalence-layout-stage",
  })
  MonCacheWriter.stageLayout(layoutArtifact, {
    icons = planned.icons,
    portraits = planned.portraits,
    marker = layoutMarker,
    pagePlans = { iconPages = planned.iconPages, portraitPages = planned.portraitPages },
    generationId = generation,
  })
  layoutArtifact:finishSuccess({ marker = layoutMarker })
  layoutArtifact:publish({
    generationId = generation,
    epoch = 1,
    kind = "mon-layout",
    key = "global",
    jobKey = "mon-layout:global",
  })
  Assert.equal(MonCacheWriter.sourcePlanIndexPath(), "data/generated/producer/mon-layout/index.lua")
  Assert.equal(
    MonCacheWriter.sourcePagePlanPath("portraits", 17),
    "data/generated/producer/mon-layout/portraits/17.lua"
  )
  local ready, _ = MonCacheWriter.isLayoutSourceReady(cache, generation, layoutMarker)
  Assert.isTrue(ready, "the staged layout carries a complete handoff")

  local shinySelector = MonCache.portraitSelector("TOTODILE", 0, "male", true)
  Assert.notNil(planned.portraits.entries[shinySelector], "the shiny portrait stays planned")
  local iconLast = planned.icons.pageIds[#planned.icons.pageIds]
  local portraitLast = planned.portraits.pageIds[#planned.portraits.pageIds]
  assert(type(iconLast) == "number" and type(portraitLast) == "number", "the manifests inventory their pages")

  local cases = {
    { kind = "icons", selector = "CHIKORITA/f0" },
    { kind = "icons", selector = "CHIKORITA/egg" },
    { kind = "portraits", selector = shinySelector },
    {
      kind = "icons",
      selector = assert(selectorOnPage(planned.icons, iconLast), "the final icon page has a selector"),
    },
    {
      kind = "portraits",
      selector = assert(selectorOnPage(planned.portraits, portraitLast), "the final portrait page has a selector"),
    },
  }
  for _, case in ipairs(cases) do
    local manifest = case.kind == "icons" and planned.icons or planned.portraits
    local pageField = case.kind == "icons" and "iconPages" or "portraitPages"
    local wanted = assert(manifest.entries[case.selector], case.selector .. " stays planned")
    local direct = assert(MonPresentationCompiler.compilePage(romFs, case.kind, planned[pageField][wanted.pageId]))
    local loaded, reason = MonCacheWriter.loadPagePlan(cache, generation, case.kind, wanted.pageId, layoutMarker)
    Assert.notNil(loaded, "the handoff loads its page record: " .. tostring(reason))
    assert(loaded ~= nil, "the page record is available")
    local savedChar = G2dDecoder.decodeChar
    local decodes = 0
    G2dDecoder.decodeChar = function(...)
      decodes = decodes + 1
      return savedChar(...)
    end
    local ok, handed = pcall(MonPresentationCompiler.compilePage, romFs, case.kind, loaded)
    G2dDecoder.decodeChar = savedChar
    Assert.isTrue(ok, "handoff compilation must succeed: " .. tostring(handed))
    handed = assert(handed)
    Assert.isTrue(decodes <= 16, case.selector .. " stays within one bounded page")
    Assert.equal(handed.width, direct.width, case.selector .. " keeps the page width")
    Assert.equal(handed.height, direct.height, case.selector .. " keeps the page height")
    Assert.equal(handed.pixels, direct.pixels, case.selector .. " keeps the page bytes")
    Assert.equal(loaded.pageId, wanted.pageId, case.selector .. " keeps its page identity")
    Assert.equal(
      subRect(handed.pixels, handed.width, wanted.x, wanted.y, wanted.width, wanted.height),
      subRect(direct.pixels, direct.width, wanted.x, wanted.y, wanted.width, wanted.height),
      case.selector .. " keeps its source pixels"
    )
    for index, frame in ipairs(wanted.frames) do
      local directFrames = manifest.entries[case.selector].frames
      Assert.equal(frame.x, directFrames[index].x, case.selector .. " keeps its frame order")
      Assert.equal(frame.y, directFrames[index].y, case.selector .. " keeps its frame order")
    end
  end
end

local suite = require("tests.rom.support.RomSuite").fromFacts(T)
return suite
