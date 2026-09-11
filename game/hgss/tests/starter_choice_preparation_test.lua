-- Preparation lifecycle below the field scenarios: drawing before the
-- scene is prepared fails loudly, reopening prepares the new presentation
-- again, every remaining input route stays suppressed while the chooser is
-- hidden, zoom controls stay live, and disposal ends preparation safely.

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

local function fakePreparationQueue()
  local queue = {
    requests = {},
    takes = 0,
    cancels = {},
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
  function queue:release() end
  return queue
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

local function stubBackend()
  return { marker = "field-backend", released = false }
end

local function fieldComposition(starter, queue, backend)
  local FieldState = requireModule(FIELD_STATE_MODULE, "the field state owns presentation composition")
  local inputCalls = {}
  local input = {}
  for _, name in ipairs({
    "pressAction",
    "releaseAction",
    "pressCancel",
    "releaseCancel",
    "pressMenu",
    "releaseMenu",
    "pressDirection",
    "releaseDirection",
    "setStickAxis",
    "pointerDown",
    "pointerUp",
    "pointerMove",
    "pointerScroll",
  }) do
    input[name] = function(_, ...)
      inputCalls[#inputCalls + 1] = { name, ... }
    end
  end
  local zoomCalls = { zoomIn = 0, zoomOut = 0, reset = 0, applied = 0 }
  local runtime = {
    starterChoice = starter,
    assetPreparation = queue,
    actionKeys = { z = true },
    cancelKeys = { x = true },
    menuKeys = {},
    input = input,
    zoom = {
      zoomIn = function()
        zoomCalls.zoomIn = zoomCalls.zoomIn + 1
      end,
      zoomOut = function()
        zoomCalls.zoomOut = zoomCalls.zoomOut + 1
      end,
      reset = function()
        zoomCalls.reset = zoomCalls.reset + 1
      end,
    },
    applyZoomChange = function()
      zoomCalls.applied = zoomCalls.applied + 1
    end,
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
  return state, inputCalls, zoomCalls
end

local function advanceToReady(host, queue, backend, bound)
  bound = bound or 256
  for _ = 1, bound do
    local consumed = host:advancePresentationPreparation({
      assetPreparation = queue,
      gxRenderer = backend,
    }, 1)
    Assert.isTrue(consumed == 0 or consumed == 1, "one update finishes at most one preparation step")
    if host:isPresentationReady() then
      return true
    end
  end
  return host:isPresentationReady()
end

local function idleSnapshot()
  return { selection = 0, selectionState = "null", transition = "idle", direction = nil }
end

function T.drawing_before_preparation_finishes_fails_loudly()
  local host, service = openHeadlessChoice()
  openTrio(host, service)
  local presentation = assert(host._presentation, "opening owns the presentation records")
  local view = { candidates = assert(host._candidates), names = assert(host._names) }
  local text = {
    drawLine = function() end,
    drawLineWithColorVariants = function() end,
    windowBackgroundColor = function()
      return { 0, 0, 0, 1 }
    end,
  }
  local presentationErr = Assert.throws(function()
    presentation:draw(idleSnapshot(), view, text)
  end, "drawing the unprepared scene fails instead of realizing it")
  Assert.isTrue(
    tostring(presentationErr):find("not prepared", 1, true) ~= nil,
    "the presentation names the missing preparation: " .. tostring(presentationErr)
  )
  local stateErr = Assert.throws(function()
    host:drawPresentation(text, 256, 192)
  end, "drawing the unprepared modal fails instead of realizing it")
  Assert.isTrue(
    tostring(stateErr):find("not prepared", 1, true) ~= nil,
    "the state names the missing preparation: " .. tostring(stateErr)
  )
  host:close()
  host:dispose()
end

function T.reopening_prepares_the_new_presentation_again()
  local host, service = openHeadlessChoice()
  local queue = fakePreparationQueue()
  local backend = stubBackend()
  openTrio(host, service)
  Assert.equal(
    host:advancePresentationPreparation({ assetPreparation = queue, gxRenderer = backend }, 1),
    0,
    "outstanding preparation consumes no step"
  )
  local firstRequests = #queue.requests
  Assert.isTrue(firstRequests > 0, "the first open requests its concrete resources")
  host:close()
  Assert.isTrue(#queue.cancels > 0, "closing cancels the outstanding requests")
  openTrio(host, service)
  Assert.isFalse(host:isPresentationReady(), "the reopened chooser starts unprepared")
  Assert.equal(
    host:advancePresentationPreparation({ assetPreparation = queue, gxRenderer = backend }, 1),
    0,
    "the reopened chooser waits on its own preparation"
  )
  Assert.isTrue(#queue.requests > firstRequests, "the reopened chooser requests its resources again")
  queue.ready = true
  Assert.isTrue(advanceToReady(host, queue, backend), "the reopened chooser prepares through bounded steps")
  host:close()
  host:dispose()
end

function T.remaining_input_routes_stay_suppressed_while_the_chooser_is_hidden()
  local host, service = openHeadlessChoice()
  local queue = fakePreparationQueue()
  local backend = stubBackend()
  local state, inputCalls = fieldComposition(host, queue, backend)
  openTrio(host, service)
  state:update(1 / 30)
  Assert.isFalse(host:isPresentationReady(), "the chooser stays hidden while preparation is outstanding")

  local before = host:status()
  local joystick = {
    getID = function()
      return 7
    end,
  }
  state:keypressed("w")
  state:keyreleased("w")
  state:gamepadreleased(joystick, "a")
  state:gamepadreleased(joystick, "b")
  state:gamepadaxis(joystick, "leftx", 0.5)
  state:gamepadaxis(joystick, "lefty", -0.5)
  state:mousemoved(40, 40, 0, 0, false)
  state:mousereleased(40, 40, 1)
  state:wheelmoved(0, 1)
  state:touchmoved(9, 40, 40)
  state:touchreleased(9, 40, 40)
  Assert.deepEqual(host:status(), before, "hidden chooser releases and pointer motion change nothing")
  Assert.equal(#inputCalls, 0, "no release, stick, or pointer route reaches gameplay input while hidden")
  host:close()
  host:dispose()
end

function T.zoom_controls_stay_live_while_the_chooser_is_hidden()
  local host, service = openHeadlessChoice()
  local queue = fakePreparationQueue()
  local backend = stubBackend()
  local state, inputCalls, zoomCalls = fieldComposition(host, queue, backend)
  openTrio(host, service)
  state:update(1 / 30)
  Assert.isFalse(host:isPresentationReady(), "the chooser stays hidden while preparation is outstanding")

  state:keypressed("=")
  state:keypressed("-")
  state:keypressed("0")
  Assert.equal(zoomCalls.zoomIn, 1, "zoom-in stays live while the chooser prepares")
  Assert.equal(zoomCalls.zoomOut, 1, "zoom-out stays live while the chooser prepares")
  Assert.equal(zoomCalls.reset, 1, "zoom reset stays live while the chooser prepares")
  Assert.equal(zoomCalls.applied, 3, "every zoom change applies while the chooser prepares")
  Assert.equal(#inputCalls, 0, "zoom keys never forward gameplay input")
  host:close()
  host:dispose()
end

function T.zero_budget_advances_nothing_and_disposal_ends_preparation()
  local host, service = openHeadlessChoice()
  local queue = fakePreparationQueue()
  local backend = stubBackend()
  openTrio(host, service)
  local context = { assetPreparation = queue, gxRenderer = backend }
  Assert.equal(host:advancePresentationPreparation(context, 0), 0, "a zero budget finishes nothing")
  Assert.equal(#queue.requests, 0, "a zero budget requests nothing")
  Assert.equal(host:advancePresentationPreparation(context, 1), 0, "outstanding preparation consumes no step")

  local presentation = assert(host._presentation, "opening owns the presentation records")
  host:close()
  Assert.isFalse(host:isPresentationReady(), "cancelling never marks the scene drawable")
  host:dispose()
  local disposedErr = Assert.throws(function()
    presentation:advancePreparation(context, 1)
  end, "advancing after disposal fails instead of reviving preparation")
  Assert.isTrue(
    tostring(disposedErr):find("disposed", 1, true) ~= nil,
    "disposal names itself: " .. tostring(disposedErr)
  )
  Assert.equal(host:advancePresentationPreparation(context, 1), 0, "the idle state stays quiet after disposal")
end

return { tests = T }
