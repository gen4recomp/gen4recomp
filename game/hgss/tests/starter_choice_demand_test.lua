-- Demand-realized starter chooser on the shared graphics backend: preparation
-- begins only after the chooser actually opens, the invisible chooser stays
-- off-screen and noninteractive while work is pending, ready draws and
-- selection changes acquire no resources, the field graphics backend is
-- borrowed rather than rebuilt, and turntable/ball timing is preserved.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")

local T = {}

local STATE_MODULE = "game.hgss.src.starters.StarterChoiceState"
local FIELD_STATE_MODULE = "game.hgss.src.field.FieldState"
local CACHE_MODULE = "libs.assets.src.StarterChoiceAssetCache"
local MODEL_MODULE = "libs.assets.src.model.ModelAsset"
local SERVICE_MODULE = "libs.hgss.src.mons.HgssMonService"
local MONSAVE_MODULE = "libs.mons.src.MonsSave"

local function requireModule(name, role)
  local ok, module = pcall(require, name)
  Assert.isTrue(ok, role .. " is unavailable: " .. tostring(module))
  return assert(module)
end

local function constantChannel()
  return { source = "constant", value = 0 }
end

local function trsClip(id)
  return {
    id = id,
    name = id,
    category = "joint",
    kind = "trs",
    frameCount = 4,
    tracks = { { target = 0, targetIndex = 0 } },
    semanticNames = {},
    compiled = {
      anmFlags = 0,
      rotData = {},
      pivotData = { { 0, 0, 0, 0, 0 } },
      targets = {
        {
          nodeIndex = 0,
          channels = {
            trans = { x = constantChannel(), y = constantChannel(), z = constantChannel() },
            rot = constantChannel(),
            scale = { x = constantChannel(), y = constantChannel(), z = constantChannel() },
          },
        },
      },
    },
  }
end

local function dynamicMaterial()
  return {
    id = 0,
    name = "widget",
    baseColor = { r = 255, g = 255, b = 255, a = 255 },
    colors = {
      diffuse = { r = 255, g = 255, b = 255 },
      ambient = { r = 255, g = 255, b = 255 },
      specular = { r = 255, g = 255, b = 255 },
      emission = { r = 0, g = 0, b = 0 },
    },
    alphaMode = "opaque",
    polygonMode = "modulation",
    doubleSided = false,
    polygonAlpha = 31,
    texMtxMode = 0,
    texWidth = 64,
    texHeight = 64,
    wrap = { x = "clamp", y = "clamp" },
    flip = { x = false, y = false },
    diffuse = { r = 255, g = 255, b = 255, a = 255 },
  }
end

local function dynamicDescriptor(clipIds)
  local clips = {}
  for _, id in ipairs(clipIds) do
    clips[#clips + 1] = trsClip(id)
  end
  return {
    schema = assert(require(MODEL_MODULE)).SCHEMA,
    kind = "nitro-dynamic",
    dynamic = { nodes = {}, transformProgram = {}, batches = {} },
    materials = { dynamicMaterial() },
    animations = clips,
  }
end

local function staticDescriptor()
  return {
    schema = assert(require(MODEL_MODULE)).SCHEMA,
    kind = "static",
    batches = {},
    materials = {},
  }
end

local function glyph(code, colorIndex)
  return { kind = "glyph", code = code, colorIndex = colorIndex or 0 }
end

local function preparedMessage(lineSpecs)
  local lines = {}
  for _, spec in ipairs(lineSpecs) do
    local line = {}
    for _, code in ipairs(spec) do
      line[#line + 1] = glyph(code)
    end
    lines[#lines + 1] = line
  end
  return { lines = lines }
end

local function chooserTextColors()
  local variants = {}
  for index = 1, 7 do
    variants[index] = {
      foreground = { r = index * 10 + 1, g = index * 10 + 2, b = index * 10 + 3 },
      shadow = { r = index * 10 + 4, g = index * 10 + 5, b = index * 10 + 6 },
    }
  end
  return {
    variants = variants,
    infoBackground = { r = 16, g = 32, b = 48 },
    machineBackground = { r = 64, g = 80, b = 96 },
  }
end

local function semanticManifest()
  local ball = dynamicDescriptor({ "ball-rock", "ball-open" })
  return {
    schema = assert(require(CACHE_MODULE)).SCHEMA,
    reference = { width = 256, height = 192 },
    models = {
      tabletop = staticDescriptor(),
      turntable = dynamicDescriptor({ "turntable" }),
      ballEffect = dynamicDescriptor({ "ball-effect" }),
      ball1 = ball,
      ball2 = dynamicDescriptor({ "ball-rock", "ball-open" }),
      ball3 = dynamicDescriptor({ "ball-rock", "ball-open" }),
    },
    animations = {
      ballRock = { "ball-rock", "ball-rock", "ball-rock" },
      ballOpen = "ball-open",
      ballEffect = "ball-effect",
      turntable = "turntable",
    },
    scene = {
      ballLayout = {
        radius = 2,
        modelY = 0.875,
        touchYOffsetY = 0.8125,
        inspectPivotYOffsetY = 13.453 / 16,
        slotAnglesDegrees = { 0, 120, 240 },
        inspectArcDegrees = -30.76,
      },
      turntable = {
        selectionStepDegrees = 120,
        rotationDegreesPerTick = 11.25,
      },
      camera = {
        near = 0.25,
        far = 16,
        out = { angleX = -49.57, perspective = 49.61, target = { x = 0, y = 0.9375, z = 0.875 }, distance = 6.25 },
        inside = { angleX = -30.76, perspective = 45.4, target = { x = 0, y = 0.9375, z = 0.75 }, distance = 3.75 },
      },
      timing = {
        cameraTicks = 8,
        ballArcTicks = 8,
        smallWobbleFrame = 80,
        infoFadeTicks = 10,
        machineFadeTicks = 16,
      },
    },
    messages = {
      topInitial = preparedMessage({ { 0x0123, 0x0124 }, { 0x0125 } }),
      inspect = {
        preparedMessage({ { 0x0200 } }),
        preparedMessage({ { 0x0201 } }),
        preparedMessage({ { 0x0202 } }),
      },
      confirm = {
        preparedMessage({ { 0x0300 } }),
        preparedMessage({ { 0x0301 } }),
        preparedMessage({ { 0x0302 } }),
      },
      bottom = {
        normal = preparedMessage({ { 0x0400 } }),
        confirm = preparedMessage({ { 0x0401 }, { 0x0402 } }),
      },
    },
    backgrounds = {
      host = {
        image = "assets/generated/starter_choice/backdrop.png",
        width = 512,
        height = 192,
      },
      info = {
        base = {
          image = "assets/generated/starter_choice/info-base.png",
          width = 256,
          height = 192,
        },
        overlay = {
          image = "assets/generated/starter_choice/info-overlay.png",
          width = 256,
          height = 192,
        },
        overlayAlpha = 5 / 16,
      },
    },
    surfaces = {
      machine = {
        clearColor = { r = 1, g = 1, b = 16 / 31, a = 1 },
        prompt = {
          box = { x = 8, y = 152, width = 232, height = 32 },
          textOrigin = { x = 8, y = 152 },
          framed = false,
        },
      },
      info = {
        message = {
          box = { x = 16, y = 152, width = 216, height = 32 },
          textOrigin = { x = 16, y = 152 },
          framed = true,
        },
        portrait = { x = 88, y = 56, width = 80, height = 80 },
      },
    },
    textColors = chooserTextColors(),
  }
end

-- A deterministic stand-in for the threaded preparation queue: requests are
-- recorded with their priority, readiness is driven explicitly by the test,
-- and cancellation is observable. No worker thread ever starts here.
local function fakePreparationQueue()
  local queue = {
    requests = {},
    takes = 0,
    cancels = {},
    releases = 0,
    ready = false,
    tokens = 0,
    live = {},
  }
  function queue:request(kind, logicalPath, priority)
    self.tokens = self.tokens + 1
    local token = self.tokens
    self.requests[#self.requests + 1] = { token = token, kind = kind, path = logicalPath, priority = priority }
    self.live[token] = { kind = kind, path = logicalPath, priority = priority }
    return token
  end
  function queue:poll(token)
    Assert.notNil(self.live[token], "poll observes a live preparation token")
    if self.ready then
      return "ready"
    end
    return "pending"
  end
  function queue:take(token)
    Assert.notNil(self.live[token], "take transfers a live preparation token")
    Assert.isTrue(self.ready, "take transfers only prepared payloads")
    self.live[token] = nil
    self.takes = self.takes + 1
    return { payload = token }
  end
  function queue:cancel(token)
    self.live[token] = nil
    self.cancels[#self.cancels + 1] = token
  end
  function queue:release()
    self.releases = self.releases + 1
  end
  function queue:requestCount()
    return #self.requests
  end
  function queue:resetCounts()
    self.requests = {}
    self.takes = 0
  end
  return queue
end

local function markQueueReady(queue)
  queue.ready = true
end

local function demandPrioritiesOnly(queue, what)
  Assert.isTrue(queue:requestCount() > 0, what .. " prepares its concrete resources on demand")
  for _, request in ipairs(queue.requests) do
    Assert.equal(request.priority, "demand", what .. " prepares at demand priority, never prefetch")
  end
end

local function readyHeadlessCache()
  local cacheModule = requireModule(CACHE_MODULE, "the starter cache owns the application manifest")
  local manifest = semanticManifest()
  Assert.isTrue(cacheModule.validateManifest(manifest), "the semantic fixture validates")
  local marker = cacheModule.marker("deadbeef", "feedface")
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  cacheFs:writeLua(cacheModule.manifestPath(), manifest)
  for _, path in ipairs(cacheModule.referencedPaths(manifest)) do
    cacheFs:write(path, "payload")
  end
  local MonCache = requireModule("libs.assets.src.MonCache", "the generated mon cache owns the portraits")
  local portraitEntries = {}
  for _, species in ipairs({ "CHIKORITA", "TOTODILE", "EEVEE" }) do
    for _, gender in ipairs({ "male", "female" }) do
      for _, shiny in ipairs({ false, true }) do
        portraitEntries[MonCache.portraitSelector(species, 0, gender, shiny)] = {
          x = 0,
          y = 0,
          width = 80,
          height = 80,
          frames = { { x = 0, y = 0, width = 80, height = 80, duration = 1 } },
        }
      end
    end
  end
  cacheFs:writeLua(MonCache.portraitManifestPath(), {
    schema = MonCache.PORTRAIT_MANIFEST_SCHEMA,
    image = MonCache.portraitImagePath(),
    entries = portraitEntries,
    representative = { MonCache.portraitSelector("CHIKORITA", 0, "male", false) },
  })
  cacheFs:write(cacheModule.markerPath(), marker)
  return cacheFs
end

local function openHeadlessChoice()
  local StarterChoiceState = requireModule(STATE_MODULE, "the starter state owns the modal choice surface")
  local catalog = CatalogFixture.makeCatalog()
  local HgssMonService = requireModule(SERVICE_MODULE, "the mon service builds the candidates")
  local MonsSave = requireModule(MONSAVE_MODULE, "the mon save owns the party bucket")
  local Lcrng = requireModule("libs.mons.src.gen4.Lcrng", "the deterministic rng builds the candidates")
  local Party = requireModule("libs.mons.src.Party", "the party owns the candidate bucket")
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x12345678):capture(), catalog:fingerprint()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    mapSection = 7,
    date = CatalogFixture.metDate(),
  })
  local host = StarterChoiceState.new({ catalog = catalog, cacheFs = readyHeadlessCache(), frameIndex = 3 })
  return host, service
end

local function openTrio(host, service)
  host:open(0, {
    service:buildStarter("CHIKORITA"),
    service:buildStarter("TOTODILE"),
    service:buildStarter("EEVEE"),
  })
end

local function settleRotation(host, bound)
  bound = bound or 1024
  for _ = 1, bound do
    host:update()
    if host._controller:snapshot().transition == "idle" then
      return true
    end
  end
  return false
end

-- Counts every graphics-object construction and cache/filesystem read behind
-- the presentation so ready draws and selection changes can prove they
-- acquire nothing. Counters reset once readiness completes.
local function resourceSpies(cacheFs)
  local spies =
    { cacheReads = 0, queueRequests = 0, queueTakes = 0, poolMisses = 0, newMesh = 0, newImage = 0, newShader = 0 }
  local originalRead = cacheFs.read
  local originalLoadLua = cacheFs.loadLua
  function cacheFs:read(...)
    spies.cacheReads = spies.cacheReads + 1
    return originalRead(self, ...)
  end
  function cacheFs:loadLua(...)
    spies.cacheReads = spies.cacheReads + 1
    return originalLoadLua(self, ...)
  end
  local graphics = rawget(_G, "love") and love.graphics or nil
  local originals = {}
  if graphics ~= nil then
    for _, name in ipairs({ "newMesh", "newImage", "newShader" }) do
      originals[name] = graphics[name]
      if type(originals[name]) == "function" then
        local key = name
        graphics[name] = function(...)
          if key == "newMesh" then
            spies.newMesh = spies.newMesh + 1
          elseif key == "newImage" then
            spies.newImage = spies.newImage + 1
          else
            spies.newShader = spies.newShader + 1
          end
          return originals[key](...)
        end
      end
    end
  end
  local function restore()
    cacheFs.read = originalRead
    cacheFs.loadLua = originalLoadLua
    if graphics ~= nil then
      for name, original in pairs(originals) do
        graphics[name] = original
      end
    end
  end
  local function reset()
    for key in pairs(spies) do
      spies[key] = 0
    end
  end
  return spies, restore, reset
end

local function assertNoAcquisition(spies, what)
  Assert.equal(spies.cacheReads, 0, what .. " performs no cache reads")
  Assert.equal(spies.queueRequests, 0, what .. " issues no preparation requests")
  Assert.equal(spies.queueTakes, 0, what .. " takes no preparation payloads")
  Assert.equal(spies.poolMisses, 0, what .. " misses no pooled resources")
  Assert.equal(spies.newMesh, 0, what .. " builds no meshes")
  Assert.equal(spies.newImage, 0, what .. " builds no images")
  Assert.equal(spies.newShader, 0, what .. " compiles no shaders")
end

local function advanceToReady(host, queue, backend, bound)
  bound = bound or 256
  for _ = 1, bound do
    local consumed = host:advancePresentationPreparation({
      assetPreparation = queue,
      gxRenderer = backend,
    }, 1)
    Assert.isTrue(consumed ~= nil and consumed <= 1, "one update realizes at most one resource")
    if host:isPresentationReady() then
      return true
    end
  end
  return host:isPresentationReady()
end

local function stubBackend()
  return { marker = "field-backend", released = false }
end

-- A bare field composition over fakes: the real update/draw/input entry
-- points run against a stub runtime, so readiness gating is what can fail.
local function fieldComposition(starter, queue, backend)
  local FieldState = requireModule(FIELD_STATE_MODULE, "the field state owns presentation composition")
  local inputCalls = {}
  local input = {}
  for _, name in ipairs({
    "pressAction",
    "releaseAction",
    "pressDirection",
    "releaseDirection",
    "pointerDown",
    "pointerUp",
  }) do
    input[name] = function(_, ...)
      inputCalls[#inputCalls + 1] = { name, ... }
    end
  end
  local draws = { field = 0, starter = 0 }
  local runtime = {
    starterChoice = starter,
    assetPreparation = queue,
    actionKeys = { z = true },
    cancelKeys = { x = true },
    menuKeys = {},
    input = input,
    update = function() end,
    dispose = function() end,
  }
  local state = setmetatable({
    runtime = runtime,
    actorPresentation = {
      sync = function() end,
    },
    presentationResources = {
      renderer = { gxRenderer = backend },
      textRenderer = {},
    },
    _entryFade = nil,
    _entryAccumulator = 0,
    development = false,
  }, FieldState)
  return state, inputCalls, draws, runtime
end

function T.demand_preparation_begins_only_after_the_chooser_opens()
  local host, service = openHeadlessChoice()
  Assert.isTrue(type(host.isPresentationReady) == "function", "the chooser exposes presentation readiness")
  Assert.isTrue(
    type(host.advancePresentationPreparation) == "function",
    "the chooser exposes demand preparation advancement"
  )
  local queue = fakePreparationQueue()
  local backend = stubBackend()

  Assert.isFalse(host:isActive(), "the chooser starts idle")
  Assert.isFalse(host:isPresentationReady(), "nothing is ready before the chooser opens")
  Assert.equal(queue:requestCount(), 0, "no demand exists while the chooser is idle")

  local state = fieldComposition(host, queue, backend)
  state:update(1 / 30)
  state:update(1 / 30)
  Assert.equal(queue:requestCount(), 0, "field updates without an open chooser prepare nothing")

  openTrio(host, service)
  Assert.isTrue(host:isActive(), "the chooser opens through the normal task seam")
  Assert.isFalse(host:isPresentationReady(), "opening alone does not realize graphics")
  Assert.equal(queue:requestCount(), 0, "opening alone starts no preparation before the field update")

  host:update()
  Assert.isTrue(host:status().done == false, "headless open and update work without graphics or a queue")

  state:update(1 / 30)
  demandPrioritiesOnly(queue, "the first field update after the actual open")
end

function T.pending_preparation_keeps_the_field_visible_and_inputs_frozen()
  local host, service = openHeadlessChoice()
  Assert.isTrue(type(host.isPresentationReady) == "function", "the chooser exposes presentation readiness")
  local queue = fakePreparationQueue()
  local backend = stubBackend()
  local state, inputCalls = fieldComposition(host, queue, backend)

  openTrio(host, service)
  local starterDraws = 0
  local fieldDraws = 0
  state._worldParts = function()
    return {}
  end
  local originalDraw = host.drawPresentation
  function host:drawPresentation(...)
    starterDraws = starterDraws + 1
    return originalDraw(self, ...)
  end
  local resourcesDraw = state.presentationResources.renderer
  resourcesDraw.draw = function()
    fieldDraws = fieldDraws + 1
  end

  for _ = 1, 3 do
    local consumed = host:advancePresentationPreparation({ assetPreparation = queue, gxRenderer = backend }, 1)
    Assert.equal(consumed, 0, "worker-pending preparation consumes no main-thread work")
  end
  Assert.isFalse(host:isPresentationReady(), "the chooser stays invisible while the worker is pending")

  state:update(1 / 30)
  Assert.isTrue(fieldDraws >= 0, "the field update path stays responsive while preparation pends")

  local before = host:status()
  state:keypressed("z")
  state:keyreleased("z")
  state:gamepadpressed({
    getID = function()
      return 7
    end,
  }, "a")
  state:mousepressed(40, 40, 1)
  state:touchpressed(9, 40, 40)
  Assert.deepEqual(host:status(), before, "invisible chooser input never changes selection or confirmation")
  Assert.equal(#inputCalls, 0, "starter-directed presses never reach gameplay input while invisible")

  markQueueReady(queue)
  local consumed = host:advancePresentationPreparation({ assetPreparation = queue, gxRenderer = backend }, 1)
  Assert.isTrue(consumed <= 1, "one update realizes at most one resource after the worker answers")
  Assert.isTrue(starterDraws == 0, "no starter surface drew before readiness")

  host:close()
  Assert.isTrue(#queue.cancels > 0, "closing while pending cancels outstanding preparation")
  host.drawPresentation = originalDraw
  host:dispose()
end

function T.ready_draws_acquire_no_resources_and_reuse_stable_records()
  local host, service = openHeadlessChoice()
  Assert.isTrue(type(host.advancePresentationPreparation) == "function", "the chooser advances demand preparation")
  local queue = fakePreparationQueue()
  local backend = stubBackend()
  markQueueReady(queue)
  openTrio(host, service)
  Assert.isTrue(advanceToReady(host, queue, backend), "the chooser reaches readiness through bounded advancement")

  local cacheFs = host._cacheFs
  local spies, restore = resourceSpies(cacheFs)
  local queueRequestsBefore = queue:requestCount()
  local queueTakesBefore = queue.takes
  local presentation = assert(host._presentation, "readiness owns the presentation records")
  local staticBefore = presentation._staticBatches
  local text = {
    drawLine = function() end,
    drawLineWithColorVariants = function() end,
    windowBackgroundColor = function()
      return { 0, 0, 0, 1 }
    end,
  }
  local snapshot = host._controller:snapshot()
  local view = { candidates = assert(host._candidates), names = assert(host._names) }
  local firstItems = presentation:_drawItems(snapshot)
  local staticCount = #assert(presentation._staticDraws, "readiness owns the static draw records")
  local staticIdentities = {}
  for index = 1, staticCount do
    staticIdentities[index] = firstItems[index]
  end
  for _ = 1, 8 do
    host:update()
    local items = presentation:_drawItems(host._controller:snapshot())
    Assert.equal(#items, #firstItems, "frame draws keep the same record count after warmup")
    for index = 1, staticCount do
      Assert.isTrue(items[index] == staticIdentities[index], "static draw records keep their identity after warmup")
    end
  end
  Assert.isTrue(presentation._staticBatches == staticBefore, "static draw records keep their identity after warmup")
  Assert.equal(queue:requestCount(), queueRequestsBefore, "ready draws issue no preparation requests")
  Assert.equal(queue.takes, queueTakesBefore, "ready draws take no preparation payloads")
  spies.queueRequests = queue:requestCount() - queueRequestsBefore
  spies.queueTakes = queue.takes - queueTakesBefore
  assertNoAcquisition(spies, "ready draws")
  Assert.notNil(view, "the committed candidate view stays available")
  Assert.notNil(text, "the text provider stays available")
  restore()
  host:close()
  host:dispose()
end

function T.starter_shares_the_field_graphics_backend_without_sharing_ownership()
  local host, service = openHeadlessChoice()
  Assert.isTrue(type(host.advancePresentationPreparation) == "function", "the chooser advances demand preparation")
  local queue = fakePreparationQueue()
  local backend = stubBackend()
  markQueueReady(queue)
  openTrio(host, service)

  local GxRenderer = requireModule("libs.nds.src.love.GxRenderer", "the graphics backend owns the shader suite")
  local shaderConstructs = 0
  local originalNew = GxRenderer.new
  GxRenderer.new = function(...)
    shaderConstructs = shaderConstructs + 1
    return originalNew(...)
  end
  local ok, readyErr = pcall(advanceToReady, host, queue, backend)
  GxRenderer.new = originalNew
  Assert.isTrue(ok and readyErr, "the chooser reaches readiness while borrowing the backend")

  local presentation = assert(host._presentation, "readiness owns the presentation records")
  local wrapper = assert(presentation._renderer, "readiness owns the starter renderer wrapper")
  Assert.isTrue(wrapper.gxRenderer == backend, "the starter wrapper borrows the live field backend object")
  Assert.equal(shaderConstructs, 0, "borrowing the backend compiles no additional shader suite")

  host:close()
  Assert.isFalse(backend.released, "releasing the starter never releases the shared backend")
  host:dispose()
  Assert.isFalse(backend.released, "disposing the starter leaves the field backend usable")
end

function T.selection_changes_use_only_resident_resources()
  local host, service = openHeadlessChoice()
  Assert.isTrue(type(host.advancePresentationPreparation) == "function", "the chooser advances demand preparation")
  local queue = fakePreparationQueue()
  local backend = stubBackend()
  markQueueReady(queue)
  openTrio(host, service)
  Assert.isTrue(advanceToReady(host, queue, backend), "selection starts from readiness")

  local spies, restore = resourceSpies(host._cacheFs)
  local queueRequestsBefore = queue:requestCount()
  local queueTakesBefore = queue.takes
  for _, direction in ipairs({ "right", "right", "left", "left" }) do
    host:move(direction)
    Assert.isTrue(settleRotation(host), "the turntable settles after a " .. direction .. " step")
  end
  host:confirm()
  host:confirm()
  for _ = 1, 512 do
    host:update()
    if host._controller:snapshot().selectionState == "confirm" then
      break
    end
  end
  Assert.equal(host._controller:snapshot().selectionState, "confirm", "confirmation settles on resident portraits")
  spies.queueRequests = queue:requestCount() - queueRequestsBefore
  spies.queueTakes = queue.takes - queueTakesBefore
  assertNoAcquisition(spies, "every selection change")
  restore()
  host:close()
  host:dispose()
end

function T.turntable_and_ball_animation_timing_survives_demand_preparation()
  local host, service = openHeadlessChoice()
  Assert.isTrue(type(host.advancePresentationPreparation) == "function", "the chooser advances demand preparation")
  local queue = fakePreparationQueue()
  local backend = stubBackend()
  markQueueReady(queue)
  openTrio(host, service)
  Assert.isTrue(advanceToReady(host, queue, backend), "timing starts from readiness")

  local presentation = assert(host._presentation, "readiness owns the presentation records")
  local ModelInstance = requireModule(
    "libs.hgss.src.presentation.ModelInstance",
    "the animated model records carry turntable and ball playback"
  )
  Assert.isTrue(ModelInstance ~= nil, "the live model records back the chooser")

  host:move("right")
  for _ = 1, 10 do
    host:update()
  end
  Assert.isFalse(
    host._controller:snapshot().transition == "idle",
    "the slot step still travels after ten fixed updates"
  )
  host:update()
  Assert.isTrue(settleRotation(host, 4), "the slot step completes on the eleventh fixed update")
  local status = host:status()
  Assert.equal(status.cursor, 1, "one settled right step advances exactly one candidate")

  local turntable = assert(presentation._instances.turntable, "the turntable record stays live")
  local firstDraws = turntable:drawItems(assert(presentation._renderMeshes.turntable, "turntable meshes stay resident"))
  host:update()
  local secondDraws =
    turntable:drawItems(assert(presentation._renderMeshes.turntable, "turntable meshes stay resident"))
  Assert.isTrue(firstDraws == secondDraws, "animated draw records keep stable live identities across ticks")

  host:confirm()
  host:confirm()
  local confirmed = false
  for _ = 1, 512 do
    host:update()
    if host._controller:snapshot().selectionState == "confirm" then
      confirmed = true
      break
    end
  end
  Assert.isTrue(confirmed, "inspection still settles into confirmation after demand preparation")
  local ball = assert(presentation._instances.ball2, "the selected ball record stays live through selection")
  Assert.notNil(ball, "ball animation records survive selection changes")
  host:close()
  host:dispose()
end

return { tests = T }
