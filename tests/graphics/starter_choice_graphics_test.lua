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

-- A deterministic preparation queue over the ready cache: payloads are
-- computed from the same cache bytes the worker would have prepared, so
-- realization matches the production path without starting a thread.
local function preparationQueue(cacheFs)
  local SceneMesh =
    requireModule("libs.hgss.src.presentation.SceneMesh", "the mesh preparation packs upload buffers from cache bytes")
  local records = {}
  local nextToken = 0
  local queue = {}
  function queue:request(kind, path, priority)
    Assert.equal(priority, "demand", "the chooser prepares its concrete resources after opening")
    nextToken = nextToken + 1
    records[nextToken] = { kind = kind, path = path }
    return nextToken
  end
  function queue:poll(token)
    local record = assert(records[token], "unknown preparation token")
    if record.payload == nil then
      if record.kind == "mesh" then
        record.payload = SceneMesh.prepareUpload(assert(cacheFs:read(record.path), "missing mesh " .. record.path))
      else
        local bytes = assert(cacheFs:read(record.path), "missing texture " .. record.path)
        record.payload = { imageData = love.image.newImageData(love.filesystem.newFileData(bytes, "tex.png")) }
      end
    end
    return "ready"
  end
  function queue:take(token)
    local record = assert(records[token], "unknown preparation token")
    local payload = assert(record.payload, "preparation result is not ready")
    records[token] = nil
    return payload
  end
  function queue:cancel(token)
    records[token] = nil
  end
  function queue:release() end
  return queue
end

-- Prepares the production chooser through the field-owned composition seam:
-- concrete resources resolve through the queue while the renderer wrapper
-- borrows the live backend. Returns the borrowed backend for release.
local function prepareHost(host, cacheFs)
  local GxRenderer = requireModule("libs.nds.src.love.GxRenderer", "the field graphics backend owns the shader suite")
  local backend = GxRenderer.new()
  local queue = preparationQueue(cacheFs)
  for _ = 1, 4096 do
    host:advancePresentationPreparation({ assetPreparation = queue, gxRenderer = backend }, 1)
    if host:isPresentationReady() then
      return backend
    end
  end
  error("the starter presentation never prepared", 0)
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

    local backend = prepareHost(host, cacheFs)
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
    host:update()
    local rotating = drawFrame(scope, host, REFERENCE_WIDTH, REFERENCE_HEIGHT)
    Assert.isTrue(
      frameDistance(initial, rotating, REFERENCE_WIDTH, REFERENCE_HEIGHT) > 10,
      versionId .. " rotation realizes an intermediate scene"
    )
    Assert.isTrue(
      stepHostUntil(host, function()
        return snapshotOf(host, versionId).transition == "idle"
      end, 1024),
      versionId .. " rotation reaches its semantic boundary"
    )
    local rotated = drawFrame(scope, host, REFERENCE_WIDTH, REFERENCE_HEIGHT)
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
    backend:release()
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
    local backend = prepareHost(host, cacheFs)
    local middleFrame = drawFrame(scope, host, REFERENCE_WIDTH, REFERENCE_HEIGHT)
    Assert.isTrue(brightPixels(middleFrame, REFERENCE_WIDTH, REFERENCE_HEIGHT) > 0, versionId .. " portrait is visible")

    host:focus(0)
    local neighboringFrame = drawFrame(scope, host, REFERENCE_WIDTH, REFERENCE_HEIGHT)
    Assert.isTrue(
      frameDistance(middleFrame, neighboringFrame, REFERENCE_WIDTH, REFERENCE_HEIGHT) > 10,
      versionId .. " inspected portraits follow their generated candidates"
    )
    host:dispose()
    backend:release()
  end
end

-- Surface text owns no window of its own: an unframed prompt draws only its
-- line rect, so glyph background pixels leave the scene artwork behind the
-- text untouched, while a framed message fills its window with the opaque
-- chooser background first. The provider paints every line rect with the
-- background role it receives, so a surviving scene pixel proves the
-- transparent policy and a filled pixel proves the opaque one.
function T.surface_text_leaves_the_scene_visible_unframed_and_fills_framed(scope)
  local Presentation = requireModule(
    "game.hgss.src.starters.StarterChoicePresentation",
    "the starter presentation draws its surface messages"
  )
  local machineBackground = { r = 10, g = 20, b = 30 }
  local infoBackground = { r = 200, g = 210, b = 220 }
  local machineRect = { x = 0, y = 0, width = 256, height = 192 }
  local infoRect = { x = 0, y = 0, width = 256, height = 192 }
  local host = setmetatable({
    _manifest = {
      reference = { width = 256, height = 192 },
      textColors = { machineBackground = machineBackground, infoBackground = infoBackground, variants = {} },
    },
    _machine = machineRect,
    _info = infoRect,
    _frameIndex = 0,
    _window = {
      drawWindow = function(_, box, _, fill)
        love.graphics.setColor(fill[1], fill[2], fill[3], fill[4])
        love.graphics.rectangle("fill", box.x, box.y, box.width, box.height)
      end,
    },
  }, { __index = Presentation })
  local backgrounds = {}
  local provider = {}
  function provider:drawLineWithColorVariants(_, x, y, _, background)
    backgrounds[#backgrounds + 1] = background
    local alpha = background.a
    if alpha == nil then
      alpha = 1
    end
    love.graphics.setColor(background.r / 255, background.g / 255, background.b / 255, alpha)
    love.graphics.rectangle("fill", x, y, 40, 12)
  end
  local message = { lines = { { { kind = "glyph", code = 65 } } } }
  local unframed =
    { box = { x = 10, y = 10, width = 100, height = 40 }, textOrigin = { x = 12, y = 12 }, framed = false }
  local framed = { box = { x = 10, y = 60, width = 100, height = 40 }, textOrigin = { x = 12, y = 62 }, framed = true }
  local function quantize(v)
    return math.floor(v * 255 + 0.5)
  end
  local canvas = scope:own(love.graphics.newCanvas(REFERENCE_WIDTH, REFERENCE_HEIGHT))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0.1, 0.7, 0.5, 1)
  host:_drawSurfaceMessage(machineRect, unframed, message, provider)
  love.graphics.setCanvas()
  local unframedFrame = scope:own(canvas:newImageData())
  Assert.equal(#backgrounds, 1, "the unframed prompt draws its line")
  Assert.deepEqual(
    backgrounds[1],
    { r = machineBackground.r, g = machineBackground.g, b = machineBackground.b, a = 0 },
    "the unframed prompt keeps the machine colors with a transparent background"
  )
  local ur, ug, ub, ua = unframedFrame:getPixel(20, 15)
  for _, channel in ipairs({
    { actual = quantize(ur), expected = quantize(0.1) },
    { actual = quantize(ug), expected = quantize(0.7) },
    { actual = quantize(ub), expected = quantize(0.5) },
    { actual = quantize(ua), expected = 255 },
  }) do
    Assert.isTrue(
      math.abs(channel.actual - channel.expected) <= 1,
      "the unframed line rect leaves the scene artwork visible"
    )
  end
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0.1, 0.7, 0.5, 1)
  host:_drawSurfaceMessage(infoRect, framed, message, provider)
  love.graphics.setCanvas()
  local framedFrame = scope:own(canvas:newImageData())
  Assert.equal(#backgrounds, 2, "the framed message draws its line")
  Assert.deepEqual(backgrounds[2], infoBackground, "the framed message keeps the opaque info background")
  local fr, fg, fb, fa = framedFrame:getPixel(20, 70)
  Assert.deepEqual(
    { quantize(fr), quantize(fg), quantize(fb), quantize(fa) },
    { infoBackground.r, infoBackground.g, infoBackground.b, 255 },
    "the framed window fill stays opaque over the scene"
  )
  Assert.isNil(machineBackground.a, "the machine background table is not mutated")
  Assert.isNil(infoBackground.a, "the info background table is not mutated")
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump", "derived_cache" }
suite.metadata.derivedAssets = { "complete" }

return suite
