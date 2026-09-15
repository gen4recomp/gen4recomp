-- Persists compiled mon artifacts through the shared staged publication
-- primitive, one stage per level: the semantic catalog, the selector layout
-- manifests, one bounded page image at a time, and the family summary. Each
-- stage is written into a disposable staging root, read back and validated
-- there (schemas, pixel sizes, image dimensions, and page coverage), and
-- only then published with its marker last. A failure at any point leaves
-- the previous live output untouched; the stage is discarded. The raw ROM
-- dump and any other derived class are never touched. Page buffers live
-- only through their own staging; no whole-corpus pixel array is retained.

local Errors = require("libs.errors.src.Errors")
local PngWriter = require("libs.assets.src.PngWriter")
local MonCache = require("libs.assets.src.MonCache")
local MonAssetSchema = require("libs.assets.src.MonAssetSchema")
local Validate = require("libs.assets.src.Validate")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local Hashing = require("romdump.src.digest.Hashing")

---@class MonCacheWriter
local MonCacheWriter = {}

---@class MonFamilyIndex
---@field schema string
---@field version { id: string, language: string }
---@field catalogHash string 40-character hex digest of the semantic catalog
---@field catalog string cache-relative catalog path
---@field iconManifest string cache-relative icon manifest path
---@field portraitManifest string cache-relative portrait manifest path
---@field iconPages string[] one marker per icon page in ascending page order
---@field portraitPages string[] one marker per portrait page in ascending page order

function MonCacheWriter.isReady(cacheFs, marker)
  return MonCache.isReady(cacheFs, marker)
end

local function fail(code, message, context)
  Errors.raise(code, message, context or {})
end

-- Deterministic pre-pixel markers: the catalog marker binds the semantic
-- catalog, the layout marker binds both selector manifests, and each page
-- marker binds its kind, page id, and layout manifest. Pixel bytes stay
-- page-owned; markers bind the layout that staged them.
---@param romSha1 string
---@param catalog table<string, unknown>
---@return string
function MonCacheWriter.catalogMarker(romSha1, catalog)
  return MonCache.marker(romSha1, Hashing.hashLua(catalog))
end

---@param romSha1 string
---@param icons table<string, unknown> planned icon manifest
---@param portraits table<string, unknown> planned portrait manifest
---@return string
function MonCacheWriter.layoutMarker(romSha1, icons, portraits)
  return MonCache.marker(romSha1, Hashing.hashLua({ icons = icons, portraits = portraits }))
end

---@param romSha1 string
---@param kind "icons"|"portraits" presentation kind
---@param pageId integer zero-based page identity
---@param manifest table<string, unknown> planned manifest of the page kind
---@return string
function MonCacheWriter.pageMarker(romSha1, kind, pageId, manifest)
  assert(kind == "icons" or kind == "portraits", "mon page kind must be icons or portraits")
  return MonCache.marker(romSha1, Hashing.hashLua({ kind = kind, pageId = pageId, manifest = manifest }))
end

---@param version { id: string, language: string }
---@param catalogHash string
---@param iconPageMarkers string[]
---@param portraitPageMarkers string[]
---@return MonFamilyIndex
function MonCacheWriter.buildIndex(version, catalogHash, iconPageMarkers, portraitPageMarkers)
  local index = {
    schema = MonCache.INDEX_SCHEMA,
    version = version,
    catalogHash = catalogHash,
    catalog = MonCache.catalogPath(),
    iconManifest = MonCache.iconManifestPath(),
    portraitManifest = MonCache.portraitManifestPath(),
    iconPages = iconPageMarkers,
    portraitPages = portraitPageMarkers,
  }
  MonAssetSchema.assertIndex(index)
  return index
end

-- The deterministic completion marker for one covered family: the page
-- markers already bind each page's layout identity, so the summary binds
-- the index selection to those markers. The ROM identity is carried by the
-- page markers themselves.
---@param index MonFamilyIndex
---@return string
function MonCacheWriter.summaryMarker(index)
  MonAssetSchema.assertIndex(index)
  local firstMarker = index.iconPages[1]
  assert(type(firstMarker) == "string", "family index carries no icon page marker")
  local romSha1 = firstMarker:match("^[^:]+:([^:]+):.+$")
  assert(type(romSha1) == "string", "page markers carry no ROM identity")
  return MonCache.marker(romSha1, Hashing.hashLua(index))
end

---@param marker unknown
---@param what string
local function checkMarker(marker, what)
  if type(marker) ~= "string" or marker == "" then
    fail("MON_WRITER_BAD_MARKER", what .. " marker must be a non-empty string", {})
  end
end

local function persistCatalog(stage, catalog, marker)
  MonAssetSchema.assertCatalog(catalog)
  checkMarker(marker, "catalog")
  stage:writeLua(MonCache.catalogPath(), catalog)
  stage:write(MonCache.catalogMarkerPath(), marker)
  local readCatalog = stage:loadLua(MonCache.catalogPath())
  MonAssetSchema.assertCatalog(readCatalog)
  if stage:read(MonCache.catalogMarkerPath()) ~= marker then
    fail("MON_WRITER_MARKER_READBACK_FAILED", "catalog marker readback failed", {})
  end
  return marker
end

-- Stage the semantic catalog through a caller-owned prepared artifact: the
-- stage owns exactly the catalog payload and its marker, so no pixel
-- payload is touched. Publication stays with the caller.
---@param artifact PreparedArtifact
---@param args { catalog: table<string, unknown>, marker: string }
---@return string
function MonCacheWriter.stageCatalog(artifact, args)
  assert(artifact and artifact.stageFs, "catalog staging requires a PreparedArtifact")
  assert(type(args) == "table", "catalog staging requires its catalog and marker")
  artifact:addOwnedRoot(MonCache.catalogPath())
  artifact:addOwnedRoot(MonCache.catalogMarkerPath())
  return persistCatalog(artifact:stageFs(), args.catalog, args.marker)
end

function MonCacheWriter.writeCatalog(cacheFs, catalog, marker)
  local tx = ArtifactPublisher.begin(cacheFs, "mon-catalog", {
    MonCache.catalogPath(),
    MonCache.catalogMarkerPath(),
  })
  local ok, result = pcall(persistCatalog, tx.stage, catalog, marker)
  if not ok then
    tx:abort()
    error(result, 0)
  end
  tx:publish()
  return result
end

-- Durable producer handoff for bounded page jobs: the layout job plans once
-- and stages these private records atomically with the normalized manifests,
-- so page jobs in other worker VMs rasterize only their own page. The records
-- stay under the producer root and never enter the normalized runtime
-- manifests, which carry no source selectors.
local SOURCE_ROOT = "data/generated/producer/mon-layout"
local SOURCE_INDEX_SCHEMA = "g4-mon-source-layout-v1"
local SOURCE_PAGE_SCHEMA = "g4-mon-source-page-v1"

---@return string cache-relative private index path
function MonCacheWriter.sourcePlanIndexPath()
  return SOURCE_ROOT .. "/index.lua"
end

---@param kind "icons"|"portraits" presentation kind
---@param pageId integer zero-based page identity
---@return string cache-relative private page record path
function MonCacheWriter.sourcePagePlanPath(kind, pageId)
  assert(kind == "icons" or kind == "portraits", "mon page kind must be icons or portraits")
  assert(type(pageId) == "number" and pageId % 1 == 0 and pageId >= 0, "mon page id must be a non-negative integer")
  return SOURCE_ROOT .. "/" .. kind .. "/" .. tostring(pageId) .. ".lua"
end

local function checkSourceKeys(record, allowed, code, what)
  for key in pairs(record) do
    if allowed[key] == nil then
      fail(code, what .. " carries an unknown field " .. tostring(key), {})
    end
  end
end

local function checkPositiveDimension(value, what)
  if type(value) ~= "number" or value % 1 ~= 0 or value <= 0 or value >= math.huge then
    fail("MON_WRITER_BAD_PAGE_PLAN", what .. " must be a finite positive integer", {})
  end
end

---@param kind "icons"|"portraits" presentation kind
---@param combo table<string, unknown> one visual source record
local function assertCombo(kind, combo)
  if type(combo) ~= "table" then
    fail("MON_WRITER_BAD_PAGE_PLAN", "page combos must be records", { kind = kind })
  end
  if kind == "icons" then
    checkSourceKeys(
      combo,
      { naix = true, palette = true, key = true, selectors = true },
      "MON_WRITER_BAD_PAGE_PLAN",
      "icon combo"
    )
    if not Validate.isNonNegativeInteger(combo.naix) then
      fail("MON_WRITER_BAD_PAGE_PLAN", "icon combo needs its character identity", { kind = kind })
    end
    if not Validate.isNonNegativeInteger(combo.palette) then
      fail("MON_WRITER_BAD_PAGE_PLAN", "icon combo needs its palette identity", { kind = kind })
    end
  else
    checkSourceKeys(
      combo,
      { narc = true, charMemberId = true, palMemberId = true, key = true, selectors = true },
      "MON_WRITER_BAD_PAGE_PLAN",
      "portrait combo"
    )
    if type(combo.narc) ~= "string" or combo.narc == "" then
      fail("MON_WRITER_BAD_PAGE_PLAN", "portrait combo needs its archive alias", { kind = kind })
    end
    if not Validate.isNonNegativeInteger(combo.charMemberId) then
      fail("MON_WRITER_BAD_PAGE_PLAN", "portrait combo needs its character identity", { kind = kind })
    end
    if not Validate.isNonNegativeInteger(combo.palMemberId) then
      fail("MON_WRITER_BAD_PAGE_PLAN", "portrait combo needs its palette identity", { kind = kind })
    end
  end
  if combo.key ~= nil and type(combo.key) ~= "string" then
    fail("MON_WRITER_BAD_PAGE_PLAN", "page combo key must be a string", { kind = kind })
  end
  local selectors = combo.selectors
  if not Validate.isArray(selectors) or #selectors == 0 then
    fail("MON_WRITER_BAD_PAGE_PLAN", "page combos must carry their alias selectors", { kind = kind })
  end
  local seen = {}
  for _, selector in ipairs(selectors) do
    if type(selector) ~= "string" or selector == "" then
      fail("MON_WRITER_BAD_PAGE_PLAN", "page combo selectors must be non-empty strings", { kind = kind })
    end
    if seen[selector] then
      fail("MON_WRITER_BAD_PAGE_PLAN", "duplicate page combo selector " .. selector, { kind = kind })
    end
    seen[selector] = true
  end
end

---@param kind "icons"|"portraits" presentation kind
---@param pageId integer zero-based page identity
---@param plan table<string, unknown> one bounded page source record
local function assertPagePlan(kind, pageId, plan)
  if type(plan) ~= "table" then
    fail("MON_WRITER_BAD_PAGE_PLAN", "page source records must be tables", { kind = kind, pageId = pageId })
  end
  checkSourceKeys(
    plan,
    { pageId = true, width = true, height = true, cell = true, combos = true, representative = true },
    "MON_WRITER_BAD_PAGE_PLAN",
    "page source record"
  )
  if plan.pageId ~= pageId then
    fail("MON_WRITER_BAD_PAGE_PLAN", "page source record names another page", { kind = kind, pageId = pageId })
  end
  checkPositiveDimension(plan.width, "page width")
  checkPositiveDimension(plan.height, "page height")
  checkPositiveDimension(plan.cell, "page cell")
  local combos = plan.combos
  if not Validate.isArray(combos) or #combos == 0 or #combos > 16 then
    fail("MON_WRITER_BAD_PAGE_PLAN", "pages carry one to sixteen source visuals", { kind = kind, pageId = pageId })
  end
  for _, combo in ipairs(combos) do
    assertCombo(kind, combo)
  end
  local representative = plan.representative
  if type(representative) ~= "table" then
    fail("MON_WRITER_BAD_PAGE_PLAN", "page records carry their representative checks", { kind = kind, pageId = pageId })
  end
  if not Validate.isArray(representative) then
    fail("MON_WRITER_BAD_PAGE_PLAN", "page representative checks must be an array", { kind = kind, pageId = pageId })
  end
  for _, check in ipairs(representative) do
    if type(check) ~= "table" then
      fail("MON_WRITER_BAD_PAGE_PLAN", "page representative checks must be records", { kind = kind, pageId = pageId })
    end
    checkSourceKeys(
      check,
      { selector = true, x = true, y = true, width = true, height = true },
      "MON_WRITER_BAD_PAGE_PLAN",
      "page representative check"
    )
    if type(check.selector) ~= "string" or check.selector == "" then
      fail("MON_WRITER_BAD_PAGE_PLAN", "page representative checks need a selector", { kind = kind, pageId = pageId })
    end
    if not Validate.isNonNegativeInteger(check.x) or not Validate.isNonNegativeInteger(check.y) then
      fail("MON_WRITER_BAD_PAGE_PLAN", "page representative checks need an origin", { kind = kind, pageId = pageId })
    end
    checkPositiveDimension(check.width, "representative width")
    checkPositiveDimension(check.height, "representative height")
  end
end

---@param ids unknown candidate page identity list
---@param what string list label for diagnostics
---@return integer[] the checked ascending identities
local function assertPageIdList(ids, what)
  if not Validate.isArray(ids) or #ids == 0 then
    fail("MON_WRITER_BAD_SOURCE_INDEX", what .. " must inventory at least one page", {})
  end
  local previous = nil
  for _, pageId in ipairs(ids) do
    if not Validate.isNonNegativeInteger(pageId) then
      fail("MON_WRITER_BAD_SOURCE_INDEX", what .. " page ids must be non-negative integers", {})
    end
    if previous ~= nil and pageId <= previous then
      fail("MON_WRITER_BAD_SOURCE_INDEX", what .. " page ids must ascend without duplicates", {})
    end
    previous = pageId
  end
  return ids --[[@as integer[] ]]
end

---@param index unknown candidate private index record
---@return table<string, unknown> the checked index
local function assertSourceIndex(index)
  if type(index) ~= "table" then
    fail("MON_WRITER_BAD_SOURCE_INDEX", "private source index must be a record", {})
  end
  checkSourceKeys(
    index,
    { schema = true, generationId = true, layoutMarker = true, iconPageIds = true, portraitPageIds = true },
    "MON_WRITER_BAD_SOURCE_INDEX",
    "private source index"
  )
  if index.schema ~= SOURCE_INDEX_SCHEMA then
    fail("MON_WRITER_BAD_SOURCE_INDEX", "private source index schema mismatch", {})
  end
  if type(index.generationId) ~= "string" or index.generationId == "" then
    fail("MON_WRITER_BAD_SOURCE_INDEX", "private source index needs its generation", {})
  end
  checkMarker(index.layoutMarker, "source index layout")
  assertPageIdList(index.iconPageIds, "icon")
  assertPageIdList(index.portraitPageIds, "portrait")
  return index --[[@as table<string, unknown>]]
end

---@param record unknown candidate private page record
---@return table<string, unknown> the checked record
local function assertSourcePage(record)
  if type(record) ~= "table" then
    fail("MON_WRITER_BAD_SOURCE_PAGE", "private page records must be tables", {})
  end
  checkSourceKeys(
    record,
    { schema = true, generationId = true, layoutMarker = true, kind = true, pageId = true, plan = true },
    "MON_WRITER_BAD_SOURCE_PAGE",
    "private page record"
  )
  if record.schema ~= SOURCE_PAGE_SCHEMA then
    fail("MON_WRITER_BAD_SOURCE_PAGE", "private page record schema mismatch", {})
  end
  if type(record.generationId) ~= "string" or record.generationId == "" then
    fail("MON_WRITER_BAD_SOURCE_PAGE", "private page records need their generation", {})
  end
  checkMarker(record.layoutMarker, "source page layout")
  if record.kind ~= "icons" and record.kind ~= "portraits" then
    fail("MON_WRITER_BAD_SOURCE_PAGE", "private page records need their kind", {})
  end
  if not Validate.isNonNegativeInteger(record.pageId) then
    fail("MON_WRITER_BAD_SOURCE_PAGE", "private page records need their page identity", {})
  end
  assertPagePlan(record.kind, record.pageId, record.plan)
  return record --[[@as table<string, unknown>]]
end

---@param pageTables table<string, unknown> zero-based page records by page identity
---@param what string page family label for diagnostics
---@return integer[] the checked ascending identities
local function sortedPlanIds(pageTables, what)
  if type(pageTables) ~= "table" then
    fail("MON_WRITER_BAD_PAGE_PLAN", what .. " page records must be a table", {})
  end
  local ids = {}
  for pageId in pairs(pageTables) do
    if not Validate.isNonNegativeInteger(pageId) then
      fail("MON_WRITER_BAD_PAGE_PLAN", what .. " page identities must be non-negative integers", {})
    end
    ids[#ids + 1] = pageId
  end
  table.sort(ids)
  if #ids == 0 then
    fail("MON_WRITER_BAD_PAGE_PLAN", what .. " page records must not be empty", {})
  end
  for position, pageId in ipairs(ids) do
    if pageId ~= position - 1 then
      fail("MON_WRITER_BAD_PAGE_PLAN", what .. " page identities must be consecutive from zero", {})
    end
  end
  return ids
end

local function persistLayout(stage, icons, portraits, marker, pagePlans, generationId)
  MonAssetSchema.assertIconManifest(icons)
  MonAssetSchema.assertPortraitManifest(portraits)
  checkMarker(marker, "layout")
  if type(generationId) ~= "string" or generationId == "" then
    fail("MON_WRITER_BAD_SOURCE_INDEX", "layout staging needs its generation", {})
  end
  if type(pagePlans) ~= "table" then
    fail("MON_WRITER_BAD_PAGE_PLAN", "layout staging needs its page records", {})
  end
  local iconTables = pagePlans.iconPages
  local portraitTables = pagePlans.portraitPages
  if type(iconTables) ~= "table" or type(portraitTables) ~= "table" then
    fail("MON_WRITER_BAD_PAGE_PLAN", "layout staging needs both icon and portrait page records", {})
  end
  local iconIds = sortedPlanIds(iconTables, "icon")
  local portraitIds = sortedPlanIds(portraitTables, "portrait")
  if #iconIds ~= #icons.pageIds then
    fail("MON_WRITER_BAD_SOURCE_INDEX", "private icon records must cover every manifest page", {})
  end
  for position, pageId in ipairs(iconIds) do
    if icons.pageIds[position] ~= pageId then
      fail("MON_WRITER_BAD_SOURCE_INDEX", "private icon records must cover every manifest page", {})
    end
  end
  if #portraitIds ~= #portraits.pageIds then
    fail("MON_WRITER_BAD_SOURCE_INDEX", "private portrait records must cover every manifest page", {})
  end
  for position, pageId in ipairs(portraitIds) do
    if portraits.pageIds[position] ~= pageId then
      fail("MON_WRITER_BAD_SOURCE_INDEX", "private portrait records must cover every manifest page", {})
    end
  end
  for _, pageId in ipairs(iconIds) do
    assertPagePlan("icons", pageId, iconTables[pageId])
  end
  for _, pageId in ipairs(portraitIds) do
    assertPagePlan("portraits", pageId, portraitTables[pageId])
  end
  stage:writeLua(MonCache.iconManifestPath(), icons)
  stage:writeLua(MonCache.portraitManifestPath(), portraits)
  stage:write(MonCache.layoutMarkerPath(), marker)
  local index = {
    schema = SOURCE_INDEX_SCHEMA,
    generationId = generationId,
    layoutMarker = marker,
    iconPageIds = iconIds,
    portraitPageIds = portraitIds,
  }
  stage:writeLua(MonCacheWriter.sourcePlanIndexPath(), index)
  for _, pageId in ipairs(iconIds) do
    stage:writeLua(MonCacheWriter.sourcePagePlanPath("icons", pageId), {
      schema = SOURCE_PAGE_SCHEMA,
      generationId = generationId,
      layoutMarker = marker,
      kind = "icons",
      pageId = pageId,
      plan = iconTables[pageId],
    })
  end
  for _, pageId in ipairs(portraitIds) do
    stage:writeLua(MonCacheWriter.sourcePagePlanPath("portraits", pageId), {
      schema = SOURCE_PAGE_SCHEMA,
      generationId = generationId,
      layoutMarker = marker,
      kind = "portraits",
      pageId = pageId,
      plan = portraitTables[pageId],
    })
  end
  local readIcons = stage:loadLua(MonCache.iconManifestPath())
  MonAssetSchema.assertIconManifest(readIcons)
  local readPortraits = stage:loadLua(MonCache.portraitManifestPath())
  MonAssetSchema.assertPortraitManifest(readPortraits)
  if stage:read(MonCache.layoutMarkerPath()) ~= marker then
    fail("MON_WRITER_MARKER_READBACK_FAILED", "layout marker readback failed", {})
  end
  local readIndex = stage:loadLua(MonCacheWriter.sourcePlanIndexPath())
  local checkedIndex = assertSourceIndex(readIndex)
  if checkedIndex.generationId ~= generationId or checkedIndex.layoutMarker ~= marker then
    fail("MON_WRITER_MARKER_READBACK_FAILED", "private source index readback failed", {})
  end
  for _, pageId in ipairs(iconIds) do
    local record = assertSourcePage(stage:loadLua(MonCacheWriter.sourcePagePlanPath("icons", pageId)))
    if record.generationId ~= generationId or record.layoutMarker ~= marker or record.pageId ~= pageId then
      fail("MON_WRITER_MARKER_READBACK_FAILED", "private icon record readback failed", { pageId = pageId })
    end
  end
  for _, pageId in ipairs(portraitIds) do
    local record = assertSourcePage(stage:loadLua(MonCacheWriter.sourcePagePlanPath("portraits", pageId)))
    if record.generationId ~= generationId or record.layoutMarker ~= marker or record.pageId ~= pageId then
      fail("MON_WRITER_MARKER_READBACK_FAILED", "private portrait record readback failed", { pageId = pageId })
    end
  end
  return marker
end

-- Stage the selector layout through a caller-owned prepared artifact: the
-- stage owns the two normalized manifests, the layout marker, and the
-- private page-record root. Normalized manifests list every selector even
-- when no page image is staged yet. Publication stays with the caller.
---@param artifact PreparedArtifact
---@param args { icons: table<string, unknown>, portraits: table<string, unknown>, marker: string, pagePlans: { iconPages: table<integer, table<string, unknown>>, portraitPages: table<integer, table<string, unknown>> }, generationId: string }
---@return string
function MonCacheWriter.stageLayout(artifact, args)
  assert(artifact and artifact.stageFs, "layout staging requires a PreparedArtifact")
  assert(type(args) == "table", "layout staging requires its manifests and marker")
  artifact:addOwnedRoot(MonCache.iconManifestPath())
  artifact:addOwnedRoot(MonCache.portraitManifestPath())
  artifact:addOwnedRoot(MonCache.layoutMarkerPath())
  artifact:addOwnedRoot(SOURCE_ROOT)
  return persistLayout(artifact:stageFs(), args.icons, args.portraits, args.marker, args.pagePlans, args.generationId)
end

---@param cacheFs CacheFs
---@param icons table<string, unknown>
---@param portraits table<string, unknown>
---@param marker string
---@param pagePlans { iconPages: table<integer, table<string, unknown>>, portraitPages: table<integer, table<string, unknown>> }
---@param generationId string
---@return string
function MonCacheWriter.writeLayout(cacheFs, icons, portraits, marker, pagePlans, generationId)
  local tx = ArtifactPublisher.begin(cacheFs, "mon-layout", {
    MonCache.iconManifestPath(),
    MonCache.portraitManifestPath(),
    SOURCE_ROOT,
    MonCache.layoutMarkerPath(),
  })
  local ok, result = pcall(persistLayout, tx.stage, icons, portraits, marker, pagePlans, generationId)
  if not ok then
    tx:abort()
    error(result, 0)
  end
  tx:publish()
  return result
end

-- Load one durable page record for a worker: the generation, kind, page
-- identity, and layout marker must all agree. A missing or disagreeing
-- record is not-ready with a reason, never a reconstructed layout.
---@param cacheFs CacheFs
---@param generationId string selected generation identity
---@param kind "icons"|"portraits" presentation kind
---@param pageId integer zero-based page identity
---@param layoutMarker string live layout marker the record must bind
---@return table<string, unknown>|nil plan, string|nil reason
function MonCacheWriter.loadPagePlan(cacheFs, generationId, kind, pageId, layoutMarker)
  assert(cacheFs ~= nil, "page record loading requires a cache filesystem")
  assert(kind == "icons" or kind == "portraits", "mon page kind must be icons or portraits")
  assert(type(pageId) == "number" and pageId % 1 == 0 and pageId >= 0, "mon page id must be a non-negative integer")
  assert(type(generationId) == "string" and generationId ~= "", "page record loading needs its generation")
  assert(type(layoutMarker) == "string" and layoutMarker ~= "", "page record loading needs its layout marker")
  local path = MonCacheWriter.sourcePagePlanPath(kind, pageId)
  local ok, record = pcall(cacheFs.loadLua, cacheFs, path)
  if not ok or type(record) ~= "table" then
    return nil, "mon page " .. kind .. "/" .. tostring(pageId) .. " has no published source record"
  end
  local valid, checked = pcall(assertSourcePage, record)
  if not valid then
    return nil, "mon page " .. kind .. "/" .. tostring(pageId) .. " source record is invalid"
  end
  ---@cast checked table<string, unknown>
  if checked.generationId ~= generationId then
    return nil, "mon page " .. kind .. "/" .. tostring(pageId) .. " belongs to another generation"
  end
  if checked.layoutMarker ~= layoutMarker then
    return nil, "mon page " .. kind .. "/" .. tostring(pageId) .. " belongs to another layout"
  end
  if checked.kind ~= kind or checked.pageId ~= pageId then
    return nil, "mon page " .. kind .. "/" .. tostring(pageId) .. " record identity disagrees"
  end
  return checked.plan, --[[@as table<string, unknown>]]
    nil
end

-- True only when the private index and every page record it inventories are
-- present, well-formed, and pinned to the selected generation and layout
-- marker. Anything else is not-ready with a reason.
---@param cacheFs CacheFs
---@param generationId string selected generation identity
---@param layoutMarker string live layout marker the records must bind
---@return boolean, string|nil reason
function MonCacheWriter.isLayoutSourceReady(cacheFs, generationId, layoutMarker)
  assert(cacheFs ~= nil, "source readiness requires a cache filesystem")
  if type(generationId) ~= "string" or generationId == "" then
    return false, "source readiness needs its generation"
  end
  if type(layoutMarker) ~= "string" or layoutMarker == "" then
    return false, "source readiness needs its layout marker"
  end
  local ok, index = pcall(cacheFs.loadLua, cacheFs, MonCacheWriter.sourcePlanIndexPath())
  if not ok or type(index) ~= "table" then
    return false, "private source index is missing"
  end
  local valid, checked = pcall(assertSourceIndex, index)
  if not valid then
    return false, "private source index is invalid"
  end
  ---@cast checked table<string, unknown>
  if checked.generationId ~= generationId then
    return false, "private source index belongs to another generation"
  end
  if checked.layoutMarker ~= layoutMarker then
    return false, "private source index belongs to another layout"
  end
  local iconIds = checked.iconPageIds --[[@as integer[] ]]
  local portraitIds = checked.portraitPageIds --[[@as integer[] ]]
  for _, pageId in ipairs(iconIds) do
    local plan, _ = MonCacheWriter.loadPagePlan(cacheFs, generationId, "icons", pageId, layoutMarker)
    if plan == nil then
      return false, "private icon record " .. tostring(pageId) .. " is missing"
    end
  end
  for _, pageId in ipairs(portraitIds) do
    local plan, _ = MonCacheWriter.loadPagePlan(cacheFs, generationId, "portraits", pageId, layoutMarker)
    if plan == nil then
      return false, "private portrait record " .. tostring(pageId) .. " is missing"
    end
  end
  return true, nil
end

---@param bundle unknown
---@return { kind: "icons"|"portraits", pageId: integer, width: integer, height: integer, pixels: string, marker: string }
local function checkPageBundle(bundle)
  if type(bundle) ~= "table" then
    fail("MON_WRITER_BAD_BUNDLE", "mon page bundle must be a record", {})
  end
  ---@cast bundle table<string, unknown>
  if bundle.kind ~= "icons" and bundle.kind ~= "portraits" then
    fail("MON_WRITER_BAD_BUNDLE", "mon page bundle kind must be icons or portraits", {})
  end
  if type(bundle.pageId) ~= "number" or bundle.pageId % 1 ~= 0 or bundle.pageId < 0 then
    fail("MON_WRITER_BAD_BUNDLE", "mon page bundle pageId must be a non-negative integer", {})
  end
  if type(bundle.width) ~= "number" or bundle.width % 1 ~= 0 or bundle.width <= 0 then
    fail("MON_WRITER_BAD_BUNDLE", "mon page bundle width must be positive", {})
  end
  if type(bundle.height) ~= "number" or bundle.height % 1 ~= 0 or bundle.height <= 0 then
    fail("MON_WRITER_BAD_BUNDLE", "mon page bundle height must be positive", {})
  end
  if type(bundle.pixels) ~= "string" or #bundle.pixels ~= bundle.width * bundle.height * 4 then
    fail("MON_WRITER_BAD_BUNDLE", "mon page bundle pixels must be width*height*4 bytes", {})
  end
  checkMarker(bundle.marker, "page")
  return bundle --[[@as { kind: "icons"|"portraits", pageId: integer, width: integer, height: integer, pixels: string, marker: string }]]
end

-- Read one PNG's IHDR dimensions back without a PNG decoder: signature plus
-- the width/height words must match the staged image.
local function probePngDimensions(png, context)
  if #png < 33 or png:sub(1, 8) ~= "\137PNG\r\n\26\n" then
    fail("MON_WRITER_PNG_UNREADABLE", "staged page is not a PNG", context)
  end
  if png:sub(13, 16) ~= "IHDR" then
    fail("MON_WRITER_PNG_UNREADABLE", "staged page has no IHDR", context)
  end
  local width = 0
  for i = 17, 20 do
    width = width * 256 + string.byte(png, i)
  end
  local height = 0
  for i = 21, 24 do
    height = height * 256 + string.byte(png, i)
  end
  return width, height
end

local function persistPage(stage, bundle)
  local owned = checkPageBundle(bundle)
  local png = PngWriter.encode(owned.width, owned.height, owned.pixels)
  stage:write(MonCache.pageImagePath(owned.kind, owned.pageId), png)
  stage:write(MonCache.pageMarkerPath(owned.kind, owned.pageId), owned.marker)
  local width, height = probePngDimensions(assert(stage:read(MonCache.pageImagePath(owned.kind, owned.pageId))), {})
  if width ~= owned.width or height ~= owned.height then
    fail("MON_WRITER_PNG_UNREADABLE", "staged page dimensions mismatch", {})
  end
  if stage:read(MonCache.pageMarkerPath(owned.kind, owned.pageId)) ~= owned.marker then
    fail("MON_WRITER_MARKER_READBACK_FAILED", "page marker readback failed", {})
  end
  return owned.marker
end

-- Stage one compiled page through a caller-owned prepared artifact: the
-- stage owns exactly this page's image and marker, so per-page jobs never
-- overlap and no page buffer survives staging. Publication stays with the
-- caller; a stage failure leaves the previous live page untouched once the
-- caller aborts the disposable stage.
---@param artifact PreparedArtifact
---@param bundle { kind: "icons"|"portraits", pageId: integer, width: integer, height: integer, pixels: string, marker: string }
---@return string
function MonCacheWriter.stagePage(artifact, bundle)
  assert(artifact and artifact.stageFs, "page staging requires a PreparedArtifact")
  local owned = checkPageBundle(bundle)
  artifact:addOwnedRoot(MonCache.pageImagePath(owned.kind, owned.pageId))
  artifact:addOwnedRoot(MonCache.pageMarkerPath(owned.kind, owned.pageId))
  return persistPage(artifact:stageFs(), owned)
end

function MonCacheWriter.writePage(cacheFs, bundle)
  local owned = checkPageBundle(bundle)
  local tx = ArtifactPublisher.begin(cacheFs, "mon-page", {
    MonCache.pageImagePath(owned.kind, owned.pageId),
    MonCache.pageMarkerPath(owned.kind, owned.pageId),
  })
  local ok, result = pcall(persistPage, tx.stage, owned)
  if not ok then
    tx:abort()
    error(result, 0)
  end
  tx:publish()
  return result
end

-- The one staging step every summary entry point shares: prove every page
-- the index declares is ready in the live cache under its indexed marker,
-- then write only the index, the provenance, and the completion marker into
-- the stage. Page images are never staged here, so the summary cannot erase
-- independently published pages.
local function persistSummary(stage, liveFs, index, provenance)
  MonAssetSchema.assertIndex(index)
  assert(type(provenance) == "table", "summary staging requires the family provenance")
  local missing = {}
  for position, marker in ipairs(index.iconPages) do
    if not MonCache.isPageReady(liveFs, "icons", position - 1, marker) then
      missing[#missing + 1] = "icons:" .. (position - 1)
    end
  end
  for position, marker in ipairs(index.portraitPages) do
    if not MonCache.isPageReady(liveFs, "portraits", position - 1, marker) then
      missing[#missing + 1] = "portraits:" .. (position - 1)
    end
  end
  if #missing > 0 then
    fail("MON_SUMMARY_INCOMPLETE", "family summary refuses incomplete page coverage", { missing = missing })
  end
  local marker = MonCacheWriter.summaryMarker(index)
  stage:writeLua(MonCache.indexPath(), index)
  stage:writeLua(MonCache.provenancePath(), provenance)
  stage:write(MonCache.markerPath(), marker)
  local readIndex = stage:loadLua(MonCache.indexPath())
  MonAssetSchema.assertIndex(readIndex)
  if stage:read(MonCache.markerPath()) ~= marker then
    fail("MON_WRITER_MARKER_READBACK_FAILED", "summary marker readback failed", {})
  end
  return marker
end

-- Stage the family summary through a caller-owned prepared artifact: the
-- stage owns exactly the index, the provenance, and the completion marker,
-- never the page images. Publication stays with the caller.
---@param artifact PreparedArtifact
---@param index MonFamilyIndex
---@param provenance table<string, unknown> family provenance record
---@return string
function MonCacheWriter.stageSummary(artifact, index, provenance)
  assert(artifact and artifact.stageFs and artifact.cacheFs, "summary staging requires a PreparedArtifact")
  artifact:addOwnedRoot(MonCache.indexPath())
  artifact:addOwnedRoot(MonCache.provenancePath())
  artifact:addOwnedRoot(MonCache.markerPath())
  return persistSummary(artifact:stageFs(), artifact:cacheFs(), index, provenance)
end

function MonCacheWriter.writeSummary(cacheFs, index, provenance)
  local tx = ArtifactPublisher.begin(cacheFs, "mons", {
    MonCache.indexPath(),
    MonCache.provenancePath(),
    MonCache.markerPath(),
  })
  local ok, result = pcall(persistSummary, tx.stage, cacheFs, index, provenance)
  if not ok then
    tx:abort()
    error(result, 0)
  end
  tx:publish()
  return result
end

return MonCacheWriter
