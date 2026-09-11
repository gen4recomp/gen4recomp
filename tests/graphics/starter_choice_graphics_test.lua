-- Graphics smoke for the production starter chooser.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local RomImporter = require("romdump.src.source.RomImporter")

local T = {}

local CACHE_MODULE = "libs.assets.src.StarterChoiceAssetCache"
local STATE_MODULE = "game.hgss.src.starters.StarterChoiceState"
local SERVICE_MODULE = "libs.hgss.src.mons.HgssMonService"
local CATALOG_MODULE = "libs.mons.src.MonCatalog"
local MON_CACHE_MODULE = "libs.assets.src.MonCache"
local MONSAVE_MODULE = "libs.mons.src.MonsSave"
local FONT_MODULE = "libs.hgss.src.ui.FieldFontLoader"

local REFERENCE_WIDTH = 256
local REFERENCE_HEIGHT = 192

local function requireModule(name, role)
  local ok, module = pcall(require, name)
  Assert.isTrue(ok, role)
  return assert(module)
end

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  return versions
end

local function loadManifest(cacheModule, cacheFs)
  local manifest =
    assert(cacheFs:loadLua(cacheModule.manifestPath()), "the starter application cache carries its normalized manifest")
  Assert.isTrue(cacheModule.validateManifest(manifest), "the starter manifest validates read-only")
end

local function openProductionChoice(versionId, cacheFs, speciesKeys)
  local StarterChoiceState = requireModule(STATE_MODULE, "the starter state owns the production chooser")
  local MonCache = requireModule(MON_CACHE_MODULE, "the generated mon cache owns the catalog")
  local MonCatalog = requireModule(CATALOG_MODULE, "the mon catalog names the candidates")
  local ItemCache = requireModule("libs.assets.src.ItemCache", "the generated item cache owns the catalog")
  local ItemCatalog = requireModule("libs.items.src.ItemCatalog", "the item catalog names the items")
  local HgssMonService = requireModule(SERVICE_MODULE, "the mon service builds the candidates")
  local MonsSave = requireModule(MONSAVE_MODULE, "the mon save owns the party bucket")
  local FieldFontLoader = requireModule(FONT_MODULE, "the field font owns the service charmap")

  local monRoot = MonCache.loadCatalog(cacheFs)
  local catalog = MonCatalog.new(monRoot, ItemCatalog.new(ItemCache.loadCatalog(cacheFs)))
  local fontDef = FieldFontLoader.load(cacheFs)
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.empty(catalog:fingerprint(), 7),
    profile = { name = "GOLD", gender = 0, trainerId = 1 },
    game = versionId,
    language = monRoot.version.language,
    charmap = assert(fontDef.charmap, "production font carries the charmap"),
    mapSection = function()
      return 7
    end,
    date = { year = 2000, month = 1, day = 1 },
  })
  local host = StarterChoiceState.new({ catalog = catalog, cacheFs = cacheFs, frameIndex = 1 })
  speciesKeys = speciesKeys or { "CHIKORITA", "CYNDAQUIL", "TOTODILE" }
  local candidates = {}
  for _, key in ipairs(speciesKeys) do
    candidates[#candidates + 1] = service:buildStarter(key)
  end
  host:open(0, candidates)
  return host
end

local function snapshotOf(host, versionId)
  return assert(host._controller, versionId .. " owns its controller while open"):snapshot()
end

local function stepHostUntil(host, predicate, bound)
  for _ = 1, bound do
    host:update()
    if predicate() then
      return true
    end
  end
  return false
end

local function drawFrame(scope, host, width, height)
  local canvas = love.graphics.newCanvas(width, height)
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 1)
  host:drawPresentation({
    drawLine = function() end,
    drawLineWithColorVariants = function() end,
    drawText = function() end,
    windowBackgroundColor = function()
      return { 0, 0, 0, 1 }
    end,
  }, width, height)
  love.graphics.setCanvas()
  local image = scope:own(canvas:newImageData())
  canvas:release()
  return image
end

local function brightPixels(image, width, height)
  local found = 0
  for y = 0, height - 1, 4 do
    for x = 0, width - 1, 4 do
      local red, green, blue, alpha = image:getPixel(x, y)
      if alpha > 0.5 and math.max(red, green, blue) > 0.05 then
        found = found + 1
      end
    end
  end
  return found
end

local function frameDistance(first, second, width, height)
  local changed = 0
  for y = 0, height - 1, 4 do
    for x = 0, width - 1, 4 do
      local r1, g1, b1 = first:getPixel(x, y)
      local r2, g2, b2 = second:getPixel(x, y)
      if math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2) > 0.03 then
        changed = changed + 1
      end
    end
  end
  return changed
end

local function assertBallHit(hit, versionId)
  Assert.notNil(hit, versionId .. " hit testing finds a rendered ball")
  Assert.equal(hit.kind, "ball", versionId .. " hit testing resolves a ball region")
  Assert.isTrue(hit.index >= 0 and hit.index <= 2, versionId .. " hit testing returns a valid ball index")
end

function T.retail_scene_realizes_generated_assets_and_changes_across_choice_flow(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the retail scene needs a ready user-owned ROM with a derived cache")
  end
  local cacheModule = requireModule(CACHE_MODULE, "the starter cache owns the normalized scene")

  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local marker = cacheFs:read(cacheModule.markerPath())
    Assert.notNil(marker, versionId .. " publishes the starter application marker")
    Assert.isTrue(cacheModule.isReady(cacheFs, marker), versionId .. " starter cache is ready")
    loadManifest(cacheModule, cacheFs)

    local host = openProductionChoice(versionId, cacheFs)
    Assert.isFalse(host:status().done, versionId .. " opens an active chooser")

    local initial = drawFrame(scope, host, REFERENCE_WIDTH, REFERENCE_HEIGHT)
    Assert.isTrue(
      brightPixels(initial, REFERENCE_WIDTH, REFERENCE_HEIGHT) > 20,
      versionId .. " initial chooser state leaves visible pixels"
    )

    local seen = {}
    for y = 0, REFERENCE_HEIGHT - 1, 8 do
      for x = 0, REFERENCE_WIDTH - 1, 8 do
        local hit = host:hitTest(x, y)
        if hit ~= nil then
          assertBallHit(hit, versionId)
          seen[hit.index] = true
        end
      end
    end
    local ballCount = 0
    for _ in pairs(seen) do
      ballCount = ballCount + 1
    end
    Assert.equal(ballCount, 3, versionId .. " realizes all three ball hit regions")
    Assert.isNil(host:hitTest(-1, -1), versionId .. " outside coordinates hit no ball")

    host:move("right")
    Assert.isTrue(
      stepHostUntil(host, function()
        return snapshotOf(host, versionId).transition == "idle"
      end, 1024),
      versionId .. " rotation reaches its semantic boundary"
    )
    local rotated = drawFrame(scope, host, REFERENCE_WIDTH, REFERENCE_HEIGHT)
    Assert.isTrue(
      frameDistance(initial, rotated, REFERENCE_WIDTH, REFERENCE_HEIGHT) > 10,
      versionId .. " rotation changes the realized scene"
    )

    Assert.isNil(host:confirm(), versionId .. " first activation enters inspection")
    Assert.equal(snapshotOf(host, versionId).selectionState, "inspect", versionId .. " enters inspection state")
    Assert.isNil(host:confirm(), versionId .. " second activation starts the confirmation view")
    Assert.isTrue(
      stepHostUntil(host, function()
        return snapshotOf(host, versionId).selectionState == "confirm"
      end, 1024),
      versionId .. " confirmation view reaches its semantic boundary"
    )
    Assert.isFalse(host:status().done, versionId .. " confirmation view does not complete early")
    local zoomed = drawFrame(scope, host, REFERENCE_WIDTH, REFERENCE_HEIGHT)
    Assert.isTrue(
      frameDistance(rotated, zoomed, REFERENCE_WIDTH, REFERENCE_HEIGHT) > 10,
      versionId .. " confirmation view changes the realized scene"
    )
    host:dispose()
  end
end

function T.non_trio_candidate_inspects_through_the_mon_portrait_contract(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the portrait scene needs a ready user-owned ROM with a derived cache")
  end
  local cacheModule = requireModule(CACHE_MODULE, "the starter cache owns the normalized scene")
  local MonCache = requireModule(MON_CACHE_MODULE, "the generated mon cache owns the portraits")
  local MonCatalog = requireModule(CATALOG_MODULE, "the mon catalog names the portrait species")
  local ItemCache = requireModule("libs.assets.src.ItemCache", "the generated item cache owns the catalog")
  local ItemCatalog = requireModule("libs.items.src.ItemCatalog", "the item catalog names the items")
  local Personality = requireModule("libs.mons.src.gen4.Personality", "personality owns gender and shininess")

  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    loadManifest(cacheModule, cacheFs)
    local catalog = MonCatalog.new(MonCache.loadCatalog(cacheFs), ItemCatalog.new(ItemCache.loadCatalog(cacheFs)))
    local host = openProductionChoice(versionId, cacheFs, { "CHIKORITA", "PIKACHU", "TOTODILE" })
    local middle = assert(host._candidates[2], versionId .. " retains the middle candidate")
    local species = catalog:species(middle.species)
    local gender = Personality.gender(species.genderRatio, middle.personality)
    local shiny = Personality.shiny(middle.origin.trainerId, middle.personality)
    local selector = MonCache.portraitSelector(middle.species, middle.form, gender, shiny)
    local portraits =
      assert(cacheFs:loadLua(MonCache.portraitManifestPath()), versionId .. " the mon portrait manifest loads")
    Assert.notNil(portraits.entries[selector], versionId .. " the generated portrait selector exists")

    host:focus(1)
    Assert.isNil(host:confirm(), versionId .. " middle candidate enters inspection")
    local status = host:status()
    Assert.isFalse(status.done, versionId .. " inspecting keeps the chooser active")
    Assert.equal(status.cursor, 1, versionId .. " the middle candidate remains selected")
    local middleFrame = drawFrame(scope, host, REFERENCE_WIDTH, REFERENCE_HEIGHT)
    Assert.isTrue(brightPixels(middleFrame, REFERENCE_WIDTH, REFERENCE_HEIGHT) > 0, versionId .. " portrait is visible")

    host:focus(0)
    local neighboringFrame = drawFrame(scope, host, REFERENCE_WIDTH, REFERENCE_HEIGHT)
    Assert.isTrue(
      frameDistance(middleFrame, neighboringFrame, REFERENCE_WIDTH, REFERENCE_HEIGHT) > 10,
      versionId .. " inspected portraits follow their generated candidates"
    )
    host:dispose()
  end
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump", "derived_cache" }

return suite
