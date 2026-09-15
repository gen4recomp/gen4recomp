-- Mon page jobs reuse published prerequisites through the worker dispatcher:
-- layout planning happens once under the layout job, pages rasterize only
-- their bounded page from a durable handoff, and the summary reads published
-- results. Synthetic source data keeps pixel decoding real without a dump.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local MonCache = require("libs.assets.src.MonCache")
local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
local MonCatalogCompiler = require("romdump.src.digest.mons.MonCatalogCompiler")
local MonPresentationCompiler = require("romdump.src.digest.mons.MonPresentationCompiler")
local MonSources = require("romdump.src.config.MonSources")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")

local T = {}

local GENERATION = "test-generation"

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

local function iconCellBlock()
  local entries = u16(1) .. u16(0) .. u32(0) .. u16(1) .. u16(0) .. u32(6)
  local attrs = (u16(0) .. u16(0) .. u16(0)):rep(2)
  return block("CEBK", u16(2) .. u16(0) .. u32(0x18) .. u32(0) .. string.rep("\0", 12) .. entries .. attrs)
end

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

local function newCache()
  return CacheFs.forVersion("heartgold", FakeCache.new())
end

local function newArtifact(cache, kind, key, stageName)
  return PreparedArtifact.new({
    cacheFs = cache,
    generationId = GENERATION,
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
    generationId = GENERATION,
    epoch = 1,
    kind = kind,
    key = key,
    jobKey = kind .. ":" .. key,
  })
end

local function publishCatalogAndLayout(cache, catalog, planned)
  local catalogMarker = MonCacheWriter.catalogMarker("synthetic-rom-sha", catalog)
  local catalogStage = newArtifact(cache, "mon-catalog", "global", "reuse-catalog-stage")
  local stagedCatalog = MonCacheWriter.stageCatalog(catalogStage, { catalog = catalog, marker = catalogMarker })
  publishArtifact(catalogStage, "mon-catalog", "global", stagedCatalog)
  local layoutMarker = MonCacheWriter.layoutMarker("synthetic-rom-sha", planned.icons, planned.portraits)
  local layoutStage = newArtifact(cache, "mon-layout", "global", "reuse-layout-stage")
  local stagedLayout = MonCacheWriter.stageLayout(layoutStage, {
    icons = planned.icons,
    portraits = planned.portraits,
    marker = layoutMarker,
    pagePlans = { iconPages = planned.iconPages, portraitPages = planned.portraitPages },
    generationId = GENERATION,
  })
  publishArtifact(layoutStage, "mon-layout", "global", stagedLayout)
  return catalogMarker, stagedLayout
end

local function runAndPublish(job, context)
  local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
  local outcome = assert(ArtifactJobs.execute(job, context))
  local artifact = PreparedArtifact.open({
    cacheFs = context.cacheFs,
    generationId = job.generationId,
    epoch = job.epoch,
    kind = job.kind,
    key = job.key,
    jobKey = job.kind .. ":" .. job.key,
    stageName = job.stageName,
  })
  artifact:publish({
    generationId = job.generationId,
    epoch = job.epoch,
    kind = job.kind,
    key = job.key,
    jobKey = job.kind .. ":" .. job.key,
  })
  return outcome
end

local function trapHeavy(counts)
  local savedCatalog = MonCatalogCompiler.compileCatalog
  local savedPlan = MonPresentationCompiler.plan
  counts.catalogCalls = 0
  counts.planCalls = 0
  MonCatalogCompiler.compileCatalog = function()
    counts.catalogCalls = counts.catalogCalls + 1
    error("trapped catalog compilation", 0)
  end
  MonPresentationCompiler.plan = function()
    counts.planCalls = counts.planCalls + 1
    error("trapped layout planning", 0)
  end
  return savedCatalog, savedPlan
end

local function restoreHeavy(savedCatalog, savedPlan)
  MonCatalogCompiler.compileCatalog = savedCatalog
  MonPresentationCompiler.plan = savedPlan
end

function T.page_dispatch_produces_its_bounded_page_without_heavy_prerequisites()
  local romFs = syntheticRomFs()
  local cache = newCache()
  local catalog = assert(MonCatalogCompiler.compileCatalog(romFs, { versionId = "heartgold" }))
  local planned = assert(MonPresentationCompiler.plan(romFs, catalog))
  publishCatalogAndLayout(cache, catalog, planned)
  local expectedMarker = MonCacheWriter.pageMarker("synthetic-rom-sha", "icons", 0, planned.icons)
  local counts = {}
  local savedCatalog, savedPlan = trapHeavy(counts)
  local ok, outcome = pcall(
    runAndPublish,
    { kind = "mon-icon-page", key = "0", generationId = GENERATION, epoch = 1, stageName = "reuse-page-test" },
    { romFs = romFs, cacheFs = cache }
  )
  restoreHeavy(savedCatalog, savedPlan)
  Assert.isTrue(ok, "page dispatch must succeed from published prerequisites: " .. tostring(outcome))
  Assert.equal(counts.catalogCalls, 0, "page dispatch never compiles the catalog")
  Assert.equal(counts.planCalls, 0, "page dispatch never plans the whole layout")
  Assert.equal(outcome.result.marker, expectedMarker, "the staged page keeps its deterministic marker")
  Assert.isTrue(MonCache.isPageReady(cache, "icons", 0, expectedMarker), "the staged page reads ready")
end

function T.layout_dispatch_consumes_the_published_catalog_exactly_once()
  local romFs = syntheticRomFs()
  local cache = newCache()
  local catalog = assert(MonCatalogCompiler.compileCatalog(romFs, { versionId = "heartgold" }))
  local catalogMarker = MonCacheWriter.catalogMarker("synthetic-rom-sha", catalog)
  local catalogStage = newArtifact(cache, "mon-catalog", "global", "reuse-layout-catalog")
  publishArtifact(
    catalogStage,
    "mon-catalog",
    "global",
    MonCacheWriter.stageCatalog(catalogStage, { catalog = catalog, marker = catalogMarker })
  )
  local counts = { catalogCalls = 0, planCalls = 0 }
  local savedCatalog = MonCatalogCompiler.compileCatalog
  local savedPlan = MonPresentationCompiler.plan
  local realPlan = savedPlan
  MonCatalogCompiler.compileCatalog = function()
    counts.catalogCalls = counts.catalogCalls + 1
    error("trapped catalog compilation", 0)
  end
  MonPresentationCompiler.plan = function(...)
    counts.planCalls = counts.planCalls + 1
    return realPlan(...)
  end
  local ok, outcome = pcall(
    runAndPublish,
    { kind = "mon-layout", key = "global", generationId = GENERATION, epoch = 1, stageName = "reuse-layout-test" },
    { romFs = romFs, cacheFs = cache }
  )
  MonCatalogCompiler.compileCatalog = savedCatalog
  MonPresentationCompiler.plan = savedPlan
  Assert.isTrue(ok, "layout dispatch must succeed from the published catalog: " .. tostring(outcome))
  Assert.equal(counts.catalogCalls, 0, "layout dispatch never recompiles the catalog")
  Assert.equal(counts.planCalls, 1, "layout dispatch plans the whole layout exactly once")
  local marker = assert(outcome.result.marker)
  Assert.isTrue(MonCache.isLayoutReady(cache, marker), "the staged layout reads ready")
  local ready, _ = MonCacheWriter.isLayoutSourceReady(cache, GENERATION, marker)
  Assert.isTrue(ready, "layout publication carries its durable private handoff")
end

function T.missing_private_handoff_repairs_the_layout_before_the_page()
  local romFs = syntheticRomFs()
  local cache = newCache()
  local catalog = assert(MonCatalogCompiler.compileCatalog(romFs, { versionId = "heartgold" }))
  local planned = assert(MonPresentationCompiler.plan(romFs, catalog))
  local _, layoutMarker = publishCatalogAndLayout(cache, catalog, planned)
  local pageOutcome = runAndPublish(
    { kind = "mon-icon-page", key = "0", generationId = GENERATION, epoch = 1, stageName = "reuse-missing-page" },
    { romFs = romFs, cacheFs = cache }
  )
  local pageMarker = assert(pageOutcome.result.marker)
  local imageBefore = assert(cache:read(MonCache.pageImagePath("icons", 0)), "the page image is staged")
  cache:remove(MonCacheWriter.sourcePagePlanPath("icons", 0))
  local ready, _ = MonCacheWriter.isLayoutSourceReady(cache, GENERATION, layoutMarker)
  Assert.isFalse(ready, "a missing private page record makes the layout handoff not ready")
  local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
  local plans = { iconPageIds = planned.icons.pageIds, portraitPageIds = planned.portraits.pageIds }
  Assert.isFalse(
    ArtifactJobs.validate(cache, GENERATION, "mon-layout", "global", plans),
    "layout validation fails until the handoff is repaired"
  )
  local counts = {}
  local savedCatalog, savedPlan = trapHeavy(counts)
  local ok, pageErr = pcall(
    runAndPublish,
    { kind = "mon-icon-page", key = "0", generationId = GENERATION, epoch = 1, stageName = "reuse-missing-retry" },
    { romFs = romFs, cacheFs = cache }
  )
  restoreHeavy(savedCatalog, savedPlan)
  Assert.isFalse(ok, "a page without its handoff must not silently rebuild the layout: " .. tostring(pageErr))
  Assert.equal(
    cache:read(MonCache.pageImagePath("icons", 0)),
    imageBefore,
    "the failed page leaves existing page bytes untouched"
  )
  Assert.isTrue(MonCache.isPageReady(cache, "icons", 0, pageMarker), "the previous page stays ready")
end

function T.summary_dispatch_reads_published_results_without_recompiling()
  local romFs = syntheticRomFs()
  local cache = newCache()
  local zeroCurve = {}
  for level = 1, 100 do
    zeroCurve[level] = 0
  end
  local catalog = {
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
  local tinyIcons = manifestFor(MonCache.ICON_MANIFEST_SCHEMA, MonCache.iconPagePath(0), 256, 128, 32)
  local tinyPortraits = manifestFor(MonCache.PORTRAIT_MANIFEST_SCHEMA, MonCache.portraitPagePath(0), 640, 320, 80)
  local tinyPlans = {
    iconPages = {
      [0] = {
        pageId = 0,
        width = 256,
        height = 128,
        cell = 32,
        combos = { { naix = 1, palette = 2, selectors = { "K/f0" } } },
        representative = {},
      },
    },
    portraitPages = {
      [0] = {
        pageId = 0,
        width = 640,
        height = 320,
        cell = 80,
        combos = {
          { narc = "pokemon_graphics", charMemberId = 3, palMemberId = 4, selectors = { "K/f0/male/plain" } },
        },
        representative = {},
      },
    },
  }
  local catalogMarker = MonCacheWriter.catalogMarker("synthetic-rom-sha", catalog)
  local catalogStage = newArtifact(cache, "mon-catalog", "global", "reuse-summary-catalog")
  publishArtifact(
    catalogStage,
    "mon-catalog",
    "global",
    MonCacheWriter.stageCatalog(catalogStage, { catalog = catalog, marker = catalogMarker })
  )
  local layoutMarker = MonCacheWriter.layoutMarker("synthetic-rom-sha", tinyIcons, tinyPortraits)
  local layoutStage = newArtifact(cache, "mon-layout", "global", "reuse-summary-layout")
  publishArtifact(
    layoutStage,
    "mon-layout",
    "global",
    MonCacheWriter.stageLayout(layoutStage, {
      icons = tinyIcons,
      portraits = tinyPortraits,
      marker = layoutMarker,
      pagePlans = tinyPlans,
      generationId = GENERATION,
    })
  )
  local iconMarker = MonCacheWriter.pageMarker("synthetic-rom-sha", "icons", 0, tinyIcons)
  local iconStage = newArtifact(cache, "mon-icon-page", "0", "reuse-summary-icon")
  publishArtifact(
    iconStage,
    "mon-icon-page",
    "0",
    MonCacheWriter.stagePage(iconStage, {
      kind = "icons",
      pageId = 0,
      width = 256,
      height = 128,
      pixels = string.rep("\0", 256 * 128 * 4),
      marker = iconMarker,
    })
  )
  local portraitMarker = MonCacheWriter.pageMarker("synthetic-rom-sha", "portraits", 0, tinyPortraits)
  local portraitStage = newArtifact(cache, "mon-portrait-page", "0", "reuse-summary-portrait")
  publishArtifact(
    portraitStage,
    "mon-portrait-page",
    "0",
    MonCacheWriter.stagePage(portraitStage, {
      kind = "portraits",
      pageId = 0,
      width = 640,
      height = 320,
      pixels = string.rep("\0", 640 * 320 * 4),
      marker = portraitMarker,
    })
  )
  local counts = {}
  local savedCatalog, savedPlan = trapHeavy(counts)
  local ok, outcome = pcall(
    runAndPublish,
    { kind = "mon-summary", key = "global", generationId = GENERATION, epoch = 1, stageName = "reuse-summary-test" },
    { romFs = romFs, cacheFs = cache }
  )
  restoreHeavy(savedCatalog, savedPlan)
  Assert.isTrue(ok, "summary dispatch must succeed from published results: " .. tostring(outcome))
  Assert.equal(counts.catalogCalls, 0, "summary never recompiles the catalog")
  Assert.equal(counts.planCalls, 0, "summary never replans the layout")
  Assert.isTrue(MonCache.isReady(cache, outcome.result.marker), "the staged summary reads ready")
end

return { tests = T }
