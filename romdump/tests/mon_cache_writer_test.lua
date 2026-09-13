-- Staged publication tests for the mon cache writer, against an in-memory
-- cache and synthetic artifacts. Covers catalog/layout/page/summary
-- staging through caller-owned prepared artifacts and the direct writers,
-- staged readiness levels, rejection of a malformed page, failed-rebuild
-- preservation of the previous page, and summary refusal of partial
-- coverage.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MonCache = require("libs.assets.src.MonCache")
local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")

local T = {}

local function catalog()
  local zeroCurve = {}
  for level = 1, 100 do
    zeroCurve[level] = 0
  end
  return {
    schema = "g4-mon-catalog-v3",
    version = { id = "heartgold", language = "english" },
    species = {},
    moves = {},
    abilities = {},
    growthCurves = {
      medium_fast = zeroCurve,
      erratic = zeroCurve,
      fluctuating = zeroCurve,
      medium_slow = zeroCurve,
      fast = zeroCurve,
      slow = zeroCurve,
      unused_6 = zeroCurve,
      unused_7 = zeroCurve,
    },
  }
end

local function manifestFor(schema, pageImage, pageWidth, pageHeight, cell)
  return {
    schema = schema,
    version = { id = "heartgold", language = "english" },
    pages = {
      [0] = { pageId = 0, image = pageImage, width = pageWidth, height = pageHeight },
    },
    pageIds = { 0 },
    entries = {
      ["K/f0"] = {
        x = 0,
        y = 0,
        width = cell,
        height = cell,
        frames = { { x = 0, y = 0, width = cell, height = cell, duration = 6 } },
        pageId = 0,
      },
    },
    representative = { "K/f0" },
  }
end

local function icons()
  return manifestFor(MonCache.ICON_MANIFEST_SCHEMA, MonCache.iconPagePath(0), 256, 128, 32)
end

local function portraits()
  return manifestFor(MonCache.PORTRAIT_MANIFEST_SCHEMA, MonCache.portraitPagePath(0), 640, 320, 80)
end

local function pageBundle(kind, pageId, width, height, marker)
  return {
    kind = kind,
    pageId = pageId,
    width = width,
    height = height,
    pixels = string.rep("\0", width * height * 4),
    marker = marker,
  }
end

local function provenance()
  return { schema = "g4-mon-provenance-v1", source = "test-source", rom = { version = "heartgold", sha1 = "abc" } }
end

local function newArtifact(cache, kind, key, stageName)
  return PreparedArtifact.new({
    cacheFs = cache,
    generationId = "test-generation",
    epoch = 1,
    kind = kind,
    key = key,
    jobKey = kind .. ":" .. key,
    stageName = stageName,
  })
end

local function publishArtifact(artifact, kind, key, marker)
  artifact:finishSuccess({ marker = marker })
  artifact:publish({
    generationId = "test-generation",
    epoch = 1,
    kind = kind,
    key = key,
    jobKey = kind .. ":" .. key,
  })
end

function T.writes_each_stage_and_reports_staged_readiness()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local catalogMarker = MonCacheWriter.catalogMarker("abc", catalog())
  Assert.equal(MonCacheWriter.writeCatalog(cache, catalog(), catalogMarker), catalogMarker)
  Assert.isTrue(MonCache.isCatalogReady(cache, catalogMarker), "catalog reads ready after its own stage")
  Assert.isFalse(MonCache.isLayoutReady(cache, "no-layout"), "layout stays unread before its own stage")
  local layoutMarker = MonCacheWriter.layoutMarker("abc", icons(), portraits())
  Assert.equal(MonCacheWriter.writeLayout(cache, icons(), portraits(), layoutMarker), layoutMarker)
  Assert.isTrue(MonCache.isLayoutReady(cache, layoutMarker), "layout reads ready after its own stage")
  local iconMarker = MonCacheWriter.pageMarker("abc", "icons", 0, icons())
  Assert.equal(MonCacheWriter.writePage(cache, pageBundle("icons", 0, 256, 128, iconMarker)), iconMarker)
  Assert.isTrue(MonCache.isPageReady(cache, "icons", 0, iconMarker), "the staged icon page reads ready")
  Assert.isFalse(MonCache.isIconSetReady(cache, {}), "an empty marker selection never reads as the icon set")
  Assert.isTrue(MonCache.isIconSetReady(cache, { [0] = iconMarker }), "the staged icon set reads ready")
  Assert.isFalse(MonCache.isReady(cache, "no-summary"), "icons without portraits never read as a complete family")
  local portraitMarker = MonCacheWriter.pageMarker("abc", "portraits", 0, portraits())
  Assert.equal(MonCacheWriter.writePage(cache, pageBundle("portraits", 0, 640, 320, portraitMarker)), portraitMarker)
  local index = MonCacheWriter.buildIndex(
    { id = "heartgold", language = "english" },
    string.rep("a", 40),
    { iconMarker },
    { portraitMarker }
  )
  local summaryMarker = MonCacheWriter.summaryMarker(index)
  Assert.equal(MonCacheWriter.writeSummary(cache, index, provenance()), summaryMarker)
  Assert.isTrue(MonCache.isReady(cache, summaryMarker), "the covered family reads ready after its summary")
end

function T.stages_through_prepared_artifacts_without_touching_live_before_publish()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local catalogMarker = MonCacheWriter.catalogMarker("abc", catalog())
  local catalogStage = newArtifact(cache, "mon-catalog", "global", "mon-catalog-stage")
  Assert.equal(
    MonCacheWriter.stageCatalog(catalogStage, { catalog = catalog(), marker = catalogMarker }),
    catalogMarker
  )
  Assert.isFalse(MonCache.isCatalogReady(cache, catalogMarker), "staging alone never reads ready before publication")
  publishArtifact(catalogStage, "mon-catalog", "global", catalogMarker)
  Assert.isTrue(MonCache.isCatalogReady(cache, catalogMarker), "the published catalog reads ready")
  local layoutMarker = MonCacheWriter.layoutMarker("abc", icons(), portraits())
  local layoutStage = newArtifact(cache, "mon-layout", "global", "mon-layout-stage")
  Assert.equal(
    MonCacheWriter.stageLayout(layoutStage, { icons = icons(), portraits = portraits(), marker = layoutMarker }),
    layoutMarker
  )
  publishArtifact(layoutStage, "mon-layout", "global", layoutMarker)
  local iconMarker = MonCacheWriter.pageMarker("abc", "icons", 0, icons())
  local pageStage = newArtifact(cache, "mon-icon-page", "0", "mon-icon-page-stage")
  Assert.equal(MonCacheWriter.stagePage(pageStage, pageBundle("icons", 0, 256, 128, iconMarker)), iconMarker)
  publishArtifact(pageStage, "mon-icon-page", "0", iconMarker)
  Assert.isTrue(MonCache.isPageReady(cache, "icons", 0, iconMarker), "the published page reads ready")
  local portraitMarker = MonCacheWriter.pageMarker("abc", "portraits", 0, portraits())
  local portraitStage = newArtifact(cache, "mon-portrait-page", "0", "mon-portrait-page-stage")
  Assert.equal(
    MonCacheWriter.stagePage(portraitStage, pageBundle("portraits", 0, 640, 320, portraitMarker)),
    portraitMarker
  )
  publishArtifact(portraitStage, "mon-portrait-page", "0", portraitMarker)
  local index = MonCacheWriter.buildIndex(
    { id = "heartgold", language = "english" },
    string.rep("a", 40),
    { iconMarker },
    { portraitMarker }
  )
  local summaryStage = newArtifact(cache, "mon-summary", "global", "mon-summary-stage")
  local summaryMarker = MonCacheWriter.stageSummary(summaryStage, index, provenance())
  Assert.equal(summaryMarker, MonCacheWriter.summaryMarker(index), "the summary marker binds the staged index")
  publishArtifact(summaryStage, "mon-summary", "global", summaryMarker)
  Assert.isTrue(MonCache.isReady(cache, summaryMarker), "the published family reads ready")
end

function T.rejects_a_malformed_page_without_publishing()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local broken = pageBundle("icons", 0, 256, 128, "broken-marker")
  broken.pixels = "short"
  local artifact = newArtifact(cache, "mon-icon-page", "0", "mon-icon-page-broken")
  local err = Assert.throws(function()
    MonCacheWriter.stagePage(artifact, broken)
  end)
  Assert.isTrue(Errors.is(err), "a truncated page buffer must fail structurally")
  artifact:abort()
  Assert.isFalse(MonCache.isPageReady(cache, "icons", 0, "broken-marker"), "a rejected page never reads ready")
  local badKind = pageBundle("icons", 0, 256, 128, "bad-kind-marker")
  badKind.kind = "sprites"
  Assert.throws(function()
    MonCacheWriter.writePage(cache, badKind)
  end)
  Assert.isFalse(MonCache.isPageReady(cache, "icons", 0, "bad-kind-marker"), "a mislabeled page never stages")
end

-- Malformed or truncated stage data cannot replace ready content: the
-- rebuild fails structurally and the prior ready page stays unchanged with
-- no new ready marker.
function T.failed_rebuild_preserves_the_previous_artifact()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local firstMarker = MonCacheWriter.pageMarker("abc", "icons", 0, icons())
  MonCacheWriter.writePage(cache, pageBundle("icons", 0, 256, 128, firstMarker))
  local broken = pageBundle("icons", 0, 256, 128, MonCacheWriter.pageMarker("abc", "icons", 0, icons()))
  broken.catalog = nil
  broken.pixels = "short"
  Assert.throws(function()
    MonCacheWriter.writePage(cache, broken)
  end)
  Assert.isTrue(MonCache.isPageReady(cache, "icons", 0, firstMarker), "the previous page remains ready")
  Assert.equal(
    cache:read(MonCache.pageMarkerPath("icons", 0)),
    firstMarker,
    "the new marker never reached the live tree"
  )
  Assert.isNil(backend:getInfo("staging/heartgold/mons"), "the stage is cleaned on failure")
end

function T.summary_refuses_incomplete_page_coverage()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local iconMarker = MonCacheWriter.pageMarker("abc", "icons", 0, icons())
  MonCacheWriter.writePage(cache, pageBundle("icons", 0, 256, 128, iconMarker))
  local index = MonCacheWriter.buildIndex(
    { id = "heartgold", language = "english" },
    string.rep("a", 40),
    { iconMarker },
    { "stale-portrait-marker" }
  )
  local complete = newArtifact(cache, "mon-summary", "global", "mon-summary-incomplete")
  local ok, summaryErr = pcall(MonCacheWriter.stageSummary, complete, index, provenance())
  Assert.isFalse(ok, "a summary without every declared page must not stage")
  Assert.isTrue(Errors.is(summaryErr), "the refusal stays diagnosable")
  complete:abort()
  Assert.isFalse(MonCache.isReady(cache, "no-summary"), "a refused summary never reads ready")
end

return { tests = T }
