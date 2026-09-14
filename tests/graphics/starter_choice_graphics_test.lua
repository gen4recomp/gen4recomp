-- Graphics smoke for the production starter chooser.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldWindowRenderer = require("libs.hgss.src.ui.FieldWindowRenderer")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local RomImporter = require("romdump.src.source.RomImporter")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

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

-- The draw-time frame borrower: a real field window renderer built from
-- the generated field-UI manifest, mirroring the production field
-- composition seam. Test-local owner; the caller releases it.
local function openWindowBorrower(cacheFs, versionId)
  local manifest =
    assert(cacheFs:loadLua(FieldUiAssetCache.manifestPath()), versionId .. " the generated field-UI manifest loads")
  Assert.isTrue(FieldUiAssetCache.validateManifest(manifest), versionId .. " the field-UI manifest validates read-only")
  return FieldWindowRenderer.new({ cacheFs = cacheFs, manifest = manifest })
end

-- The default measured facts for the migrated native scene tests: one
-- 536x240 display resolving the native wide pair at 1x with its complete
-- fitted frame, so drawn frames fill the capture canvas exactly. Built
-- inline (rather than through the graphicsBox helper below) so the
-- declaration precedes its callers.
local function nativeWideBox()
  return {
    width = 536,
    height = 240,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 536, height = 240 },
      role = "world",
      touch = false,
    }),
    pixelRatio = 1,
    signature = "starter-graphics-native-wide",
  }
end

-- Complete caller-owned measurements: translated host-unit bounds, actual
-- topology, uniform pixel ratio, and stable signatures.
local function graphicsBox(width, height, topology, pixelRatio, signature)
  return {
    width = width,
    height = height,
    topology = topology,
    pixelRatio = pixelRatio,
    signature = signature,
  }
end

local WORLD_RECT = { x = 400, y = 100, width = 256, height = 192 }
local AUX_RECT = { x = 100, y = 300, width = 256, height = 192 }

local function dualBox()
  return graphicsBox(
    656,
    492,
    ScreenTopology.dualDisplay({
      id = "world",
      rect = WORLD_RECT,
      role = "world",
      touch = false,
    }, {
      id = "aux",
      rect = AUX_RECT,
      role = "auxiliary",
      touch = true,
    }),
    1,
    "starter-graphics-dual"
  )
end

local function compactBox()
  return graphicsBox(
    640,
    480,
    ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 640, height = 480 },
      role = "world",
      touch = false,
    }),
    1,
    "starter-graphics-compact"
  )
end

local function openProductionChoice(versionId, cacheFs, speciesKeys, measureDisplay)
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
  local opts = {
    catalog = catalog,
    cacheFs = cacheFs,
    frameIndex = 1,
    measureDisplay = assert(measureDisplay, "the production choice resolves through measured display facts"),
  }
  local host = StarterChoiceState.new(opts)
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

local function drawFrame(scope, host, window, width, height)
  local canvas = love.graphics.newCanvas(width, height)
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 1)
  host:drawPresentation({
    drawLine = function() end,
    drawLineWithColorVariants = function() end,
    drawText = function() end,
    -- The stub draws no glyphs, so measured advances are zero; the
    -- production contract still requires the metrics entrypoint.
    textWidth = function()
      return 0
    end,
    -- Starter content keeps its text provider shaped like production; the
    -- stub carries the generated font base height alongside its metrics.
    fontDef = { maxLetterHeight = 16 },
    windowBackgroundColor = function()
      return { 0, 0, 0, 1 }
    end,
  }, window)
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

local function assertBallHit(ball, versionId)
  Assert.notNil(ball, versionId .. " hit testing finds a rendered ball")
  Assert.isTrue(ball >= 1 and ball <= 3, versionId .. " hit testing returns a valid ball region")
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

    local host = openProductionChoice(versionId, cacheFs, nil, function()
      return nativeWideBox()
    end)
    Assert.isFalse(host:status().done, versionId .. " opens an active chooser")

    local backend = prepareHost(host, cacheFs)
    local window = openWindowBorrower(cacheFs, versionId)
    local initial = drawFrame(scope, host, window, 536, 240)
    Assert.isTrue(brightPixels(initial, 536, 240) > 20, versionId .. " initial chooser state leaves visible pixels")

    local seen = {}
    for y = 0, REFERENCE_HEIGHT - 1, 8 do
      for x = 0, REFERENCE_WIDTH - 1, 8 do
        local ball = host:ballAt(x, y)
        if ball ~= nil then
          assertBallHit(ball, versionId)
          seen[ball] = true
        end
      end
    end
    local ballCount = 0
    for _ in pairs(seen) do
      ballCount = ballCount + 1
    end
    Assert.equal(ballCount, 3, versionId .. " realizes all three ball hit regions")
    Assert.isNil(host:ballAt(-1, -1), versionId .. " outside coordinates hit no ball")

    host:move("right")
    host:update()
    local rotating = drawFrame(scope, host, window, 536, 240)
    Assert.isTrue(
      frameDistance(initial, rotating, 536, 240) > 10,
      versionId .. " rotation realizes an intermediate scene"
    )
    Assert.isTrue(
      stepHostUntil(host, function()
        return snapshotOf(host, versionId).transition == "idle"
      end, 1024),
      versionId .. " rotation reaches its semantic boundary"
    )
    local rotated = drawFrame(scope, host, window, 536, 240)
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
    local zoomed = drawFrame(scope, host, window, 536, 240)
    Assert.isTrue(
      frameDistance(rotated, zoomed, 536, 240) > 10,
      versionId .. " confirmation view changes the realized scene"
    )
    host:dispose()
    window:release()
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
    local host = openProductionChoice(versionId, cacheFs, { "CHIKORITA", "PIKACHU", "TOTODILE" }, function()
      return nativeWideBox()
    end)
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
    local window = openWindowBorrower(cacheFs, versionId)
    local middleFrame = drawFrame(scope, host, window, 536, 240)
    Assert.isTrue(brightPixels(middleFrame, 536, 240) > 0, versionId .. " portrait is visible")

    host:focus(0)
    local neighboringFrame = drawFrame(scope, host, window, 536, 240)
    Assert.isTrue(
      frameDistance(middleFrame, neighboringFrame, 536, 240) > 10,
      versionId .. " inspected portraits follow their generated candidates"
    )
    host:dispose()
    window:release()
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
  host:_drawMessageLines(unframed, message, provider, {
    r = machineBackground.r,
    g = machineBackground.g,
    b = machineBackground.b,
    a = 0,
  }, host._window)
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
  host:_drawMessageLines(framed, message, provider, infoBackground, host._window)
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

local function wideBox()
  return graphicsBox(
    1280,
    720,
    ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 100, y = 50, width = 1280, height = 720 },
      role = "world",
      touch = false,
    }),
    1,
    "starter-graphics-wide"
  )
end

local function tallBox()
  return graphicsBox(
    390,
    844,
    ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 20, y = 30, width = 390, height = 844 },
      role = "world",
      touch = false,
    }),
    1,
    "starter-graphics-tall"
  )
end

local function planOf(host, versionId, what)
  local status = host:status()
  Assert.isTrue(type(status) == "table", versionId .. " keeps an active chooser " .. what)
  local plan = status.presentation
  Assert.isTrue(type(plan) == "table", versionId .. " publishes its presentation plan " .. what)
  return plan
end

local function frameOf(pane, versionId, what)
  local placement = assert(pane.placement, versionId .. " interface pane carries its placement " .. what)
  return assert(placement.frame, versionId .. " interface placement carries its host frame " .. what)
end

local function centerIn(frame, rect)
  local cx = frame.x + frame.width / 2
  local cy = frame.y + frame.height / 2
  return cx >= rect.x and cx <= rect.x + rect.width and cy >= rect.y and cy <= rect.y + rect.height
end

-- The chooser follows actual display cases instead of always
-- manufacturing side-by-side surfaces. Wide pairs info left of the
-- machine, tall stacks info above the machine, a genuine pair keeps info
-- on world with the machine on auxiliary, and nativeLike resolves one
-- usable compact portrait/action/message interface. A full inspect/confirm
-- flow on wide still publishes the confirmed candidate identity.
function T.actual_topology_replaces_fabricated_screens_with_usable_compact(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the starter topology needs a ready user-owned ROM with a derived cache")
  end
  local cacheModule = requireModule(CACHE_MODULE, "the starter cache owns the normalized scene")

  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    Assert.isTrue(
      cacheModule.isReady(cacheFs, cacheFs:read(cacheModule.markerPath())),
      versionId .. " starter cache is ready"
    )
    local cell = { box = wideBox() }
    local function measure()
      return cell.box
    end

    local wide = openProductionChoice(versionId, cacheFs, nil, measure)
    local widePlan = planOf(wide, versionId, "wide")
    Assert.equal(#widePlan.panes, 2, versionId .. " wide pairs exactly two panes")
    local wideLeft = frameOf(widePlan.panes[1], versionId, "wide")
    local wideRight = frameOf(widePlan.panes[2], versionId, "wide")
    Assert.isTrue(wideLeft.x + wideLeft.width <= wideRight.x, versionId .. " wide keeps info left of the machine")
    local wideScale = assert(widePlan.panes[1].placement.scale, versionId .. " wide pane carries its scale")
    Assert.equal(widePlan.panes[2].placement.scale, wideScale, versionId .. " wide shares one presentation scale")
    Assert.equal(
      wideRight.x - (wideLeft.x + wideLeft.width),
      0,
      versionId .. " wide pairs info and machine edge-adjacent with no gap"
    )
    wide:move("right")
    Assert.isTrue(
      stepHostUntil(wide, function()
        return snapshotOf(wide, versionId).transition == "idle"
      end, 1024),
      versionId .. " wide rotation settles"
    )
    Assert.isNil(wide:confirm(), versionId .. " wide first activation inspects")
    Assert.isTrue(
      stepHostUntil(wide, function()
        return snapshotOf(wide, versionId).selectionState == "inspect"
      end, 1024),
      versionId .. " wide enters inspection"
    )
    Assert.isNil(wide:confirm(), versionId .. " wide second activation starts confirmation")
    Assert.isTrue(
      stepHostUntil(wide, function()
        return snapshotOf(wide, versionId).selectionState == "confirm"
      end, 1024),
      versionId .. " wide reaches confirmation"
    )
    Assert.isNil(wide:confirm(), versionId .. " wide final activation starts the lock")
    Assert.isTrue(
      stepHostUntil(wide, function()
        return snapshotOf(wide, versionId).done
      end, 1024),
      versionId .. " wide lock completes"
    )
    Assert.equal(wide:status().index, 1, versionId .. " wide confirms the rotated candidate identity")
    wide:dispose()

    cell.box = tallBox()
    local tall = openProductionChoice(versionId, cacheFs, nil, measure)
    local tallPlan = planOf(tall, versionId, "tall")
    Assert.equal(#tallPlan.panes, 2, versionId .. " tall pairs exactly two panes")
    local tallUpper = frameOf(tallPlan.panes[1], versionId, "tall")
    local tallLower = frameOf(tallPlan.panes[2], versionId, "tall")
    Assert.isTrue(tallUpper.y + tallUpper.height <= tallLower.y, versionId .. " tall keeps info above the machine")
    Assert.equal(
      tallPlan.panes[1].placement.scale,
      tallPlan.panes[2].placement.scale,
      versionId .. " tall shares one presentation scale"
    )
    tall:dispose()

    cell.box = dualBox()
    local dual = openProductionChoice(versionId, cacheFs, nil, measure)
    local dualPlan = planOf(dual, versionId, "dual")
    Assert.equal(#dualPlan.panes, 2, versionId .. " dual keeps both physical surfaces")
    local dualWorld = 0
    local dualAux = 0
    for _, pane in ipairs(dualPlan.panes) do
      local frame = frameOf(pane, versionId, "dual")
      if centerIn(frame, WORLD_RECT) then
        dualWorld = dualWorld + 1
      end
      if centerIn(frame, AUX_RECT) then
        dualAux = dualAux + 1
      end
    end
    Assert.equal(dualWorld, 1, versionId .. " dual keeps info on the world surface")
    Assert.equal(dualAux, 1, versionId .. " dual keeps the machine on the auxiliary surface")
    dual:dispose()

    cell.box = compactBox()
    local compact = openProductionChoice(versionId, cacheFs, nil, measure)
    local compactPlan = planOf(compact, versionId, "compact")
    Assert.equal(#compactPlan.panes, 1, versionId .. " compact is one complete interface")
    local compactPlacement = assert(compactPlan.panes[1].placement, versionId .. " compact pane carries its placement")
    Assert.equal(compactPlacement.logicalWidth, 256, versionId .. " compact keeps native logical width")
    Assert.equal(compactPlacement.logicalHeight, 192, versionId .. " compact keeps native logical height")
    local backend = prepareHost(compact, cacheFs)
    local window = openWindowBorrower(cacheFs, versionId)
    local before = snapshotOf(compact, versionId)
    drawFrame(scope, compact, window, 640, 480)
    local second = drawFrame(scope, compact, window, 640, 480)
    local after = snapshotOf(compact, versionId)
    Assert.equal(after.selection, before.selection, versionId .. " repeated draws never reselect")
    Assert.equal(after.selectionState, before.selectionState, versionId .. " repeated draws never transition")
    local regions = {
      { x = 8, y = 8, width = 240, height = 48 },
      { x = 8, y = 60, width = 240, height = 80 },
      { x = 8, y = 164, width = 240, height = 24 },
    }
    for _, region in ipairs(regions) do
      local bright = 0
      for ly = region.y, region.y + region.height - 1, 2 do
        for lx = region.x, region.x + region.width - 1, 2 do
          local hx, hy = LayoutGeometry.logicalToHost(compactPlacement, lx, ly)
          local red, green, blue, alpha = second:getPixel(math.floor(hx), math.floor(hy))
          if alpha > 0.5 and math.max(red, green, blue) > 0.05 then
            bright = bright + 1
          end
        end
      end
      Assert.isTrue(bright > 20, versionId .. " compact paints its message, portrait, and action regions")
    end
    compact:dispose()
    window:release()
    backend:release()
  end
end

-- Native machine hit testing agrees with source projection
-- through one placement. At a translated DPI-2 auxiliary pane, each
-- projected ball centre round-trips to its own index, and a backdrop
-- point outside every clip inverts to nothing.
function T.translated_dpi2_machine_placement_agrees_with_source_projection(_, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the starter projection needs a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local worldRect = { x = 400, y = 100, width = 512, height = 384 }
    local auxRect = { x = 100, y = 300, width = 512, height = 384 }
    local box = graphicsBox(
      1024,
      768,
      ScreenTopology.dualDisplay({
        id = "world",
        rect = worldRect,
        role = "world",
        touch = true,
      }, {
        id = "aux",
        rect = auxRect,
        role = "auxiliary",
        touch = false,
      }),
      2,
      "starter-graphics-dpi2-dual"
    )
    local host = openProductionChoice(versionId, cacheFs, nil, function()
      return box
    end)
    local plan = planOf(host, versionId, "dpi2 dual")
    Assert.equal(#plan.panes, 2, versionId .. " dpi2 dual keeps both physical surfaces")
    local machinePlacement = nil
    for _, pane in ipairs(plan.panes) do
      if centerIn(frameOf(pane, versionId, "dpi2 dual"), auxRect) then
        machinePlacement = pane.placement
      end
    end
    local machine = assert(machinePlacement, versionId .. " the machine interaction lives on the auxiliary surface")
    local sums = {}
    for y = 0, 191 do
      for x = 0, 255 do
        local ball = host:ballAt(x, y)
        if ball ~= nil then
          local entry = sums[ball]
          if entry == nil then
            entry = { count = 0, sumX = 0, sumY = 0 }
            sums[ball] = entry
          end
          entry.count = entry.count + 1
          entry.sumX = entry.sumX + x
          entry.sumY = entry.sumY + y
        end
      end
    end
    local probed = 0
    for index = 1, 3 do
      local entry = assert(sums[index], versionId .. " realizes ball region " .. index)
      local cx = entry.sumX / entry.count
      local cy = entry.sumY / entry.count
      local hx, hy = LayoutGeometry.logicalToHost(machine, cx, cy)
      local frame = assert(machine.frame, versionId .. " machine placement carries its frame")
      Assert.isTrue(
        hx >= frame.x and hx <= frame.x + frame.width and hy >= frame.y and hy <= frame.y + frame.height,
        versionId .. " the projected ball centre lands inside the machine frame"
      )
      local sx, sy = LayoutGeometry.hostToLogical(machine, hx, hy)
      sx = assert(sx, versionId .. " the forward-mapped ball stays inside the visible clip")
      sy = assert(sy, versionId .. " the forward-mapped ball stays inside the visible clip")
      Assert.near(sx, cx, 0.001, versionId .. " host inversion restores the source x exactly")
      Assert.near(sy, cy, 0.001, versionId .. " host inversion restores the source y exactly")
      Assert.equal(
        host:ballAt(math.floor(sx + 0.5), math.floor(sy + 0.5)),
        index,
        versionId .. " source projection and placement inversion agree on ball " .. index
      )
      probed = probed + 1
    end
    Assert.equal(probed, 3, versionId .. " all three ball regions round-trip")
    local backdrop, _ = LayoutGeometry.hostToLogical(machine, 0, 0)
    Assert.isNil(backdrop, versionId .. " a backdrop point outside every clip inverts to nothing")
    host:dispose()
  end
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump", "derived_cache" }
suite.metadata.derivedAssets = { "complete" }

return suite
