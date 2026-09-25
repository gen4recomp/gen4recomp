-- Blocking starter publication through the production chooser: the task
-- pre-creates three candidates, the retail inspect/confirm/lock flow selects
-- one of them, and the task publishes that exact instance once before the
-- modal closes. Presentation resources release on close/dispose while the
-- candidate records stay owned by the task. Headless: no GPU assertions here.

local Assert = require("tests.support.Assert")
local BoxCodec = require("libs.mons.src.gen4.BoxCodec")
local CacheFs = require("libs.storage.src.CacheFs")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FakeCache = require("tests.support.FakeCache")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = {}

local STATE_MODULE = "game.hgss.src.starters.StarterChoiceState"
local SERVICE_MODULE = "libs.hgss.src.mons.HgssMonService"
local TASK_MODULE = "libs.hgss.src.script.tasks.ChooseStarterTask"
local CACHE_MODULE = "libs.assets.src.StarterChoiceAssetCache"
local MODEL_MODULE = "libs.assets.src.model.ModelAsset"

local TRIO = { "CHIKORITA", "TOTODILE", "EEVEE" }
local SEED = 0x12345678

local function requireState()
  local ok, state = pcall(require, STATE_MODULE)
  Assert.isTrue(ok, "the starter state owns the modal choice surface")
  return assert(state)
end

local function openService(catalog, seed)
  local HgssMonService = assert(require(SERVICE_MODULE))
  return HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(seed):capture(), catalog:fingerprint()),
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

-- A ready semantic cache behind the headless host: the validated manifest,
-- every referenced payload, the mon portrait entries for the fixture trio,
-- and the completion marker. The current host ignores it outside draw; the
-- retail host boots from it and fails loudly without it.
local function readyCacheFs()
  local cacheModule = assert(require(CACHE_MODULE))
  local manifest = semanticManifest()
  Assert.isTrue(cacheModule.validateManifest(manifest), "the semantic fixture validates")
  local marker = cacheModule.marker("deadbeef", "feedface")
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  cacheFs:writeLua(cacheModule.manifestPath(), manifest)
  for _, path in ipairs(cacheModule.referencedPaths(manifest)) do
    cacheFs:write(path, "payload")
  end
  local MonCache = assert(require("libs.assets.src.MonCache"))
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
          pageId = 0,
        }
      end
    end
  end
  cacheFs:writeLua(MonCache.portraitManifestPath(), {
    schema = MonCache.PORTRAIT_MANIFEST_SCHEMA,
    version = { id = "heartgold", language = "english" },
    pages = {
      [0] = { pageId = 0, image = MonCache.portraitPagePath(0), width = 640, height = 320 },
    },
    pageIds = { 0 },
    entries = portraitEntries,
    representative = { MonCache.portraitSelector("CHIKORITA", 0, "male", false) },
  })
  cacheFs:write(cacheModule.markerPath(), marker)
  return cacheFs
end

-- The required display collaborators every construction supplies: current
-- facts from a fixed single-display measurement plus caller-owned window
-- memory. Headless compositions never draw, but opening resolves the
-- shared plan through these facts.
local function defaultBox()
  return {
    width = 640,
    height = 400,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 640, height = 400 },
      role = "world",
      touch = false,
    }),
    pixelRatio = 1,
    signature = "starter-state-default",
  }
end

local function hostStatus(host)
  return host:status()
end

local function statusSelection(status)
  if status == nil then
    return nil
  end
  if type(status.cursor) == "number" then
    return status.cursor
  end
  if type(status.candidateIndex) == "number" then
    return status.candidateIndex
  end
  if type(status.selection) == "number" then
    return status.selection
  end
  return nil
end

-- Advances the host's single deterministic tick: presentation first for the
-- current snapshot, then the controller once with the resulting observation.
-- The host owns the full tick, so stepping the controller a second time
-- would double-advance transitions.
local function settle(host, bound)
  bound = bound or 1024
  for _ = 1, bound do
    if type(host.update) == "function" then
      host:update(host)
    else
      return
    end
    local status = hostStatus(host)
    if status ~= nil and status.done == true then
      return
    end
    local controller = host._controller
    if controller == nil then
      return
    end
    if controller:snapshot().transition == "idle" then
      return
    end
  end
end

local function moveHost(host, direction)
  if type(host.move) == "function" then
    host:move(direction)
    return
  end
  local status = hostStatus(host)
  local current = statusSelection(status) or 0
  local delta = direction == "right" and 1 or -1
  host:focus((current + delta) % 3)
end

local function providerFor(species)
  return {
    resolve = function()
      return { species[1], species[2], species[3] }
    end,
  }
end

local function taskCtx(service, species, host)
  return {
    services = {
      mons = service,
      starterProvider = providerFor(species),
      starterChoice = host,
      starterBalls = { placeStarterBalls = function() end },
    },
    input = { uiEvents = {} },
    instance = { scriptId = "starter-publication-fixture" },
  }
end

local function driveToChoose(task, state, ctx, host)
  for _ = 1, 8 do
    local outcome = task.poll(state, ctx)
    Assert.isFalse(outcome.complete, "generation and opening must not complete the task")
    if host:isActive() then
      return
    end
  end
  Assert.isTrue(host:isActive(), "the blocking task opens the production chooser")
end

function T.blocking_task_publishes_exactly_the_selected_candidate()
  local StarterChoiceState = requireState()
  local task = assert(require(TASK_MODULE))
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED)
  local host = StarterChoiceState.new({
    catalog = catalog,
    cacheFs = readyCacheFs(),
    frameIndex = 3,
    measureDisplay = defaultBox,
  })
  local ctx = taskCtx(service, TRIO, host)
  local state = task.create({ node = { op = "choose_starter" } }, ctx)

  driveToChoose(task, state, ctx, host)
  Assert.equal(service:partyCount(), 0, "generation must not publish into the party")

  moveHost(host, "right")
  settle(host)
  Assert.equal(statusSelection(hostStatus(host)), 1, "rotation settles on the second candidate")

  Assert.isNil(host:confirm(), "first activation inspects instead of publishing")
  Assert.isFalse(hostStatus(host).done, "inspection still waits for confirmation")
  Assert.isNil(host:confirm(), "second activation starts the zoom path, not the lock")
  Assert.isFalse(hostStatus(host).done, "the lock waits for the zoom transition to settle")
  Assert.isNil(hostStatus(host).confirmIndex, "the retail flow carries no yes/no cursor while confirming")
  settle(host)
  Assert.isFalse(hostStatus(host).done, "confirmation still waits for the final lock")

  local expected = state.candidates[2]
  Assert.notNil(expected, "the task pre-creates the second candidate")
  local expectedBytes = BoxCodec.encode(expected, CatalogFixture.domainContext(catalog))
  Assert.isNil(host:confirm(), "final activation starts the lock/exit, not the report")
  Assert.isFalse(hostStatus(host).done, "the report waits for the lock/exit to settle")
  settle(host)
  local settled = hostStatus(host)
  Assert.isTrue(settled.done, "the settled lock reports the second candidate")
  Assert.equal(settled.index, 1, "the settled lock names the second candidate")
  Assert.isTrue(type(settled.presentation) == "table", "the settled lock publishes its presentation plan")

  local outcome = task.poll(state, ctx)
  Assert.isTrue(outcome.complete, "semantic confirmation completes the task")
  Assert.equal(outcome.result.index, 1, "the task result names the confirmed candidate")
  Assert.equal(service:partyCount(), 1, "exactly the chosen mon enters the party")
  Assert.equal(
    BoxCodec.encode(service:partyMon(0), CatalogFixture.domainContext(catalog)),
    expectedBytes,
    "publication transfers the exact pre-created instance without rerolling"
  )
  Assert.equal(service:partyMon(0).species, "TOTODILE", "the party holds the confirmed species")
  Assert.isFalse(host:isActive(), "publication closes the modal")

  local again = task.poll(state, ctx)
  Assert.isTrue(again.complete, "a restored done phase stays complete")
  Assert.equal(service:partyCount(), 1, "re-polling never inserts twice")
end

function T.open_close_and_reresolve_follow_the_task_contract_without_gpu()
  local StarterChoiceState = requireState()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED)
  local host = StarterChoiceState.new({
    catalog = catalog,
    cacheFs = readyCacheFs(),
    frameIndex = 3,
    measureDisplay = defaultBox,
  })
  Assert.isFalse(host:isActive(), "the host starts idle")

  local first = service:buildStarter("CHIKORITA")
  local second = service:buildStarter("TOTODILE")
  local third = service:buildStarter("EEVEE")
  host:open(0, { first, second, third })
  Assert.isTrue(host:isActive(), "opening activates the modal surface")
  local waiting = hostStatus(host)
  Assert.equal(waiting.done, false, "the fresh choice waits for confirmation")
  Assert.equal(statusSelection(waiting), 0, "the choice opens on the task cursor")
  Assert.isNil(waiting.confirmIndex, "the fresh choice carries no yes/no cursor")

  host:handleInput({})
  Assert.equal(statusSelection(hostStatus(host)), 0, "re-resolving preserves the cursor without reselecting")
  Assert.isTrue(type(hostStatus(host).presentation) == "table", "re-resolving republishes the presentation plan")
  host:handleInput({
    { type = "pointer_down", pointerId = "touch:1", x = 100000, y = 100000 },
    { type = "pointer_up", pointerId = "touch:1", x = 100000, y = 100000 },
  })
  Assert.equal(statusSelection(hostStatus(host)), 0, "far points activate nothing")

  host:close()
  Assert.isFalse(host:isActive(), "closing releases the modal surface")
  Assert.isNil(hostStatus(host), "a closed host reports no status")
  host:dispose()
  Assert.isFalse(host:isActive(), "disposal stays idle and idempotent")
  Assert.equal(first.species, "CHIKORITA", "disposal never mutates the task-owned candidates")
  Assert.equal(second.species, "TOTODILE", "disposal never mutates the task-owned candidates")
  Assert.equal(third.species, "EEVEE", "disposal never mutates the task-owned candidates")
end

-- Scans the reference frame for the three rendered ball hit regions and
-- returns their centers keyed by ball number.
local function ballCenters(host)
  local found = {}
  for y = 0, 191 do
    for x = 0, 255 do
      local ball = host:ballAt(x, y)
      if ball ~= nil then
        local entry = found[ball]
        if entry == nil then
          entry = { count = 0, sumX = 0, sumY = 0 }
          found[ball] = entry
        end
        entry.count = entry.count + 1
        entry.sumX = entry.sumX + x
        entry.sumY = entry.sumY + y
      end
    end
  end
  local centers = {}
  for ball, entry in pairs(found) do
    centers[ball] = { x = entry.sumX / entry.count, y = entry.sumY / entry.count }
  end
  return centers
end

local function openTrio(StarterChoiceState, catalog, service, cacheFs)
  local host = StarterChoiceState.new({
    catalog = catalog,
    cacheFs = cacheFs,
    frameIndex = 3,
    measureDisplay = defaultBox,
  })
  host:open(0, {
    service:buildStarter("CHIKORITA"),
    service:buildStarter("TOTODILE"),
    service:buildStarter("EEVEE"),
  })
  return host
end

function T.pointer_follows_projected_balls_through_inspect_confirm_and_backout()
  local StarterChoiceState = requireState()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED)
  local host = openTrio(StarterChoiceState, catalog, service, readyCacheFs())

  local centers = ballCenters(host)
  local balls = 0
  for _ in pairs(centers) do
    balls = balls + 1
  end
  Assert.equal(balls, 3, "the unconfirmed scene exposes three projected ball regions")
  Assert.isNil(host:ballAt(-1, -1), "outside points hit no ball")

  local current = centers[1]
  Assert.notNil(current, "the first ball projects a hit region")
  Assert.isNil(host:tap(0), "tapping the current ball inspects instead of publishing")
  Assert.isFalse(hostStatus(host).done, "inspection still waits for confirmation")

  Assert.isNil(host:tap(1), "tapping another ball rotates toward it, never publishes")
  Assert.equal(statusSelection(hostStatus(host)), 0, "rotation waits for its transition instead of jumping")
  settle(host)
  Assert.equal(statusSelection(hostStatus(host)), 1, "the settled tap selects the tapped ball")

  Assert.isNil(host:tap(1), "tapping the current ball inspects it")
  Assert.isNil(host:tap(1), "tapping the inspected ball starts confirmation, not the lock")
  settle(host)
  Assert.isFalse(hostStatus(host).done, "confirmation still waits for the final lock tap")

  Assert.isNil(host:tap(nil), "tapping outside backs out of confirmation")
  settle(host)
  Assert.isFalse(hostStatus(host).done, "backing out returns without publishing")
  Assert.equal(statusSelection(hostStatus(host)), 1, "backing out preserves the inspected ball")
  host:close()
  host:dispose()
end

function T.hit_mapping_resolves_every_ball_without_reselecting()
  local StarterChoiceState = requireState()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED)
  local host = openTrio(StarterChoiceState, catalog, service, readyCacheFs())

  local centers = ballCenters(host)
  local balls = 0
  for _ in pairs(centers) do
    balls = balls + 1
  end
  Assert.equal(balls, 3, "the unconfirmed scene exposes three projected ball regions")
  for ball, center in pairs(centers) do
    Assert.equal(host:ballAt(center.x, center.y), ball, "each projected center resolves to its ball")
  end
  Assert.isNil(host:ballAt(-1, -1), "outside points hit no ball")
  Assert.isNil(host:ballAt(100000, 100000), "far reference points hit no ball")

  local seen = {}
  for y = 0, 191, 8 do
    for x = 0, 255, 8 do
      local ball = host:ballAt(x, y)
      if ball ~= nil then
        seen[ball - 1] = true
      end
    end
  end
  local resolved = 0
  for _ in pairs(seen) do
    resolved = resolved + 1
  end
  Assert.equal(resolved, 3, "the host surface exposes all three ball hit regions")
  Assert.equal(statusSelection(hostStatus(host)), 0, "hit queries never reselect")
  host:close()
  host:dispose()
end

function T.transitions_follow_source_semantic_boundaries()
  local StarterChoiceState = requireState()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED)
  local cacheFs = readyCacheFs()
  local cacheModule = assert(require(CACHE_MODULE))
  local manifest = assert(cacheFs:loadLua(cacheModule.manifestPath()))
  local timing = manifest.scene.timing
  local turntable = manifest.scene.turntable
  -- Pinned source derivation, never the manifest under test: one 120-degree
  -- slot step at 11.25 degrees per fixed update completes on update 11.
  Assert.equal(turntable.selectionStepDegrees, 120, "rotation spans one third of the ring")
  Assert.near(turntable.rotationDegreesPerTick, 11.25, 1e-9, "rotation advances at the normalized source rate")
  local expectedRotate = 11
  local function fieldTicksFor(sourceFrames)
    return math.ceil(sourceFrames / 2)
  end
  local host = openTrio(StarterChoiceState, catalog, service, cacheFs)

  moveHost(host, "right")
  local rotated = 0
  while statusSelection(hostStatus(host)) == 0 do
    host:update()
    rotated = rotated + 1
    Assert.isTrue(rotated <= expectedRotate, "rotation settles within one source slot step")
  end
  Assert.equal(rotated, fieldTicksFor(expectedRotate), "rotation consumes two ordered source frames per field tick")
  Assert.equal(statusSelection(hostStatus(host)), 1, "a settled right step advances one ball")

  host:confirm()
  host:confirm()
  local zoomed = 0
  while host._controller:snapshot().selectionState ~= "confirm" do
    host:update()
    zoomed = zoomed + 1
    Assert.isTrue(
      zoomed <= timing.smallWobbleFrame + timing.cameraTicks + 1,
      "the zoom path settles once the camera, arc, and wobble are ready"
    )
  end
  Assert.isTrue(zoomed > timing.cameraTicks, "camera and arc completion alone never confirm")

  host:cancel()
  local backedOut = 0
  while host._controller:snapshot().selectionState ~= "inspect" do
    host:update()
    backedOut = backedOut + 1
    Assert.isTrue(backedOut <= fieldTicksFor(timing.cameraTicks), "back-out settles within the source return steps")
  end
  Assert.equal(backedOut, fieldTicksFor(timing.cameraTicks), "back-out lasts exactly the source return steps")
  Assert.equal(statusSelection(hostStatus(host)), 1, "backing out preserves the inspected ball")

  host:confirm()
  local rezoomed = 0
  while host._controller:snapshot().selectionState ~= "confirm" do
    host:update()
    rezoomed = rezoomed + 1
    Assert.isTrue(rezoomed <= timing.smallWobbleFrame + timing.cameraTicks + 1, "the second zoom path settles")
  end

  host:confirm()
  local locked = 0
  while not hostStatus(host).done do
    host:update()
    locked = locked + 1
    Assert.isTrue(
      locked <= fieldTicksFor(timing.infoFadeTicks + timing.machineFadeTicks),
      "the lock settles within the sequential fade windows"
    )
  end
  Assert.equal(
    locked,
    fieldTicksFor(timing.infoFadeTicks + timing.machineFadeTicks),
    "the lock lasts exactly the info fade then the machine fade"
  )
  local transitioned = hostStatus(host)
  Assert.isTrue(transitioned.done, "the settled lock reports the second candidate")
  Assert.equal(transitioned.index, 1, "the settled lock names the second candidate")
  Assert.isTrue(type(transitioned.presentation) == "table", "the settled lock publishes its presentation plan")
  host:close()
  host:dispose()
end

-- The concrete state is the 30 Hz field-to-60 Hz application bridge: its
-- camera and ball-arc observations must settle after four field updates,
-- while the presentation still owns the eight source-frame clocks.
function T.zoom_uses_two_ordered_source_frames_per_field_update()
  local StarterChoiceState = requireState()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED)
  local host = openTrio(StarterChoiceState, catalog, service, readyCacheFs())

  host:confirm()
  host:confirm()
  for tick = 1, 3 do
    host:update()
    Assert.equal(host._controller:snapshot().transition, "zoomIn", "the zoom is active at field tick " .. tick)
  end
  host:update()
  Assert.equal(
    host._controller:snapshot().transition,
    "waitZoom",
    "eight source camera and arc frames settle on the fourth field tick"
  )

  host:close()
  host:dispose()
end

-- The source wobble gate remains frame 80, but the real state reaches it in
-- forty field updates and exposes confirmation immediately on that update.
function T.small_wobble_wait_uses_the_source_frame_threshold_without_extra_latency()
  local StarterChoiceState = requireState()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED)
  local cacheFs = readyCacheFs()
  local manifest = assert(cacheFs:loadLua(assert(require(CACHE_MODULE)).manifestPath()))
  Assert.equal(manifest.scene.timing.smallWobbleFrame, 80, "the generated source threshold remains frame 80")
  local host = openTrio(StarterChoiceState, catalog, service, cacheFs)

  host:confirm()
  host:confirm()
  for tick = 1, 39 do
    host:update()
    Assert.isFalse(host._controller:snapshot().selectionState == "confirm", "wobble is not ready at tick " .. tick)
  end
  host:update()
  Assert.equal(
    host._controller:snapshot().selectionState,
    "confirm",
    "the small-wobble gate settles on source frame 80 without an added field wait"
  )

  host:close()
  host:dispose()
end

function T.close_during_a_transition_and_repeated_dispose_stay_safe()
  local StarterChoiceState = requireState()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED)
  local host = openTrio(StarterChoiceState, catalog, service, readyCacheFs())

  moveHost(host, "right")
  host:confirm()
  host:close()
  Assert.isFalse(host:isActive(), "closing mid-transition releases the modal surface")
  Assert.isNil(hostStatus(host), "a closed host reports no status")
  host:dispose()
  host:dispose()
  Assert.isFalse(host:isActive(), "repeated disposal stays idle")

  host:open(0, {
    service:buildStarter("CHIKORITA"),
    service:buildStarter("TOTODILE"),
    service:buildStarter("EEVEE"),
  })
  Assert.isTrue(host:isActive(), "a disposed host reopens cleanly")
  Assert.equal(statusSelection(hostStatus(host)), 0, "reopening resets to the task cursor")
  host:close()
  host:dispose()
  Assert.isFalse(host:isActive(), "closing and disposing after reopen stays idle")
end

function T.remeasured_display_reprojects_hit_testing_without_reselecting()
  local StarterChoiceState = requireState()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED)
  local cell = { box = defaultBox() }
  local host = StarterChoiceState.new({
    catalog = catalog,
    cacheFs = readyCacheFs(),
    frameIndex = 3,
    measureDisplay = function()
      return cell.box
    end,
  })
  host:open(0, {
    service:buildStarter("CHIKORITA"),
    service:buildStarter("TOTODILE"),
    service:buildStarter("EEVEE"),
  })

  cell.box = (function()
    local box = defaultBox()
    box.width = 300
    box.height = 700
    box.topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 300, height = 700 },
      role = "world",
      touch = false,
    })
    box.signature = "starter-state-remeasured"
    return box
  end)()
  host:handleInput({})
  Assert.equal(statusSelection(hostStatus(host)), 0, "remeasuring preserves the cursor without reselecting")
  local machinePane = nil
  for _, pane in ipairs(assert(hostStatus(host).presentation, "remeasuring republishes the plan").panes) do
    if pane.id == "machine" then
      machinePane = pane
    end
  end
  local placement = assert(machinePane, "the tall plan carries its machine pane").placement
  local centers = ballCenters(host)
  local regions = 0
  for _ in pairs(centers) do
    regions = regions + 1
  end
  Assert.equal(regions, 3, "the remeasured scene keeps three projected ball regions")
  for index = 1, 2 do
    local center = assert(centers[index + 1], "ball region " .. index .. " projects a center")
    local hx, hy = LayoutGeometry.logicalToHost(placement, center.x, center.y)
    Assert.notNil(hx, "the tapped ball center stays inside the visible machine clip")
    Assert.notNil(hy, "the tapped ball center stays inside the visible machine clip")
    host:focus(0)
    settle(host)
    host:handleInput({
      { type = "pointer_down", pointerId = "touch:1", x = hx, y = hy },
      { type = "pointer_up", pointerId = "touch:1", x = hx, y = hy },
    })
    settle(host)
    Assert.equal(
      statusSelection(hostStatus(host)),
      index,
      "the remeasured machine pane taps its projected ball " .. index
    )
  end
  host:close()
  host:dispose()
end

function T.final_lock_publishes_result_only_after_sequential_fade_ticks()
  local StarterChoiceState = requireState()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED)
  local cacheFs = readyCacheFs()
  local timing = assert(cacheFs:loadLua(assert(require(CACHE_MODULE)).manifestPath())).scene.timing
  local infoTicks = assert(timing.infoFadeTicks, "the manifest carries the info fade boundary")
  local machineTicks = assert(timing.machineFadeTicks, "the manifest carries the machine fade boundary")
  local host = openTrio(StarterChoiceState, catalog, service, cacheFs)

  -- The host is the only stepper here: it advances two source transition
  -- clocks per fixed field tick, so stepping the controller again would
  -- double-advance transitions.
  local function stepUntil(predicate, bound)
    for _ = 1, bound do
      host:update()
      if predicate() then
        return true
      end
    end
    return false
  end

  moveHost(host, "right")
  Assert.isTrue(
    stepUntil(function()
      return statusSelection(hostStatus(host)) == 1
    end, 512),
    "rotation settles on the second candidate"
  )
  host:confirm()
  host:confirm()
  Assert.isTrue(
    stepUntil(function()
      return host._controller:snapshot().selectionState == "confirm"
    end, 512),
    "the zoom path settles into confirmation"
  )
  host:confirm()
  local exitTicks = 0
  while not hostStatus(host).done do
    host:update()
    exitTicks = exitTicks + 1
    Assert.isTrue(
      exitTicks <= math.ceil((infoTicks + machineTicks) / 2),
      "the lock reports within the sequential fade windows"
    )
  end
  Assert.equal(
    exitTicks,
    math.ceil((infoTicks + machineTicks) / 2),
    "the result publishes only after the info fade and the machine fade complete in sequence"
  )
  local faded = hostStatus(host)
  Assert.isTrue(faded.done, "the settled lock reports the second candidate")
  Assert.equal(faded.index, 1, "the settled lock names the second candidate")
  Assert.isTrue(type(faded.presentation) == "table", "the settled lock publishes its presentation plan")
  host:close()
  host:dispose()
end

function T.player_frame_choice_reaches_presentation_unchanged()
  local StarterChoiceState = requireState()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED)
  local host = StarterChoiceState.new({
    catalog = catalog,
    cacheFs = readyCacheFs(),
    frameIndex = 5,
    measureDisplay = defaultBox,
  })
  host:open(0, {
    service:buildStarter("CHIKORITA"),
    service:buildStarter("TOTODILE"),
    service:buildStarter("EEVEE"),
  })
  local presentation = assert(host._presentation, "opening realizes the presentation owner")
  Assert.equal(presentation._frameIndex, 5, "the state carries the player frame choice into the presentation")
  host:close()
  host:dispose()

  local ok = pcall(StarterChoiceState.new, { catalog = catalog, cacheFs = readyCacheFs() })
  Assert.isFalse(ok, "a missing frame index fails instead of hiding a wiring gap behind frame 0")
end

-- A complete caller-owned measurement for one drawable: host-unit bounds,
-- actual topology, uniform pixel ratio, and a stable signature.
local function wideMeasurement()
  return {
    width = 1280,
    height = 720,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 100, y = 50, width = 1280, height = 720 },
      role = "world",
      touch = false,
    }),
    pixelRatio = 1,
    signature = "starter-state-wide",
  }
end

local function compactMeasurement()
  return {
    width = 640,
    height = 480,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 640, height = 480 },
      role = "world",
      touch = false,
    }),
    pixelRatio = 1,
    signature = "starter-state-compact",
  }
end

local function tripleOf(host)
  local controller = assert(host._controller, "the open chooser owns its retail controller")
  local snapshot = controller:snapshot()
  return { snapshot.selection, snapshot.selectionState, snapshot.transition }
end

local function selectionStateOf(host)
  return tripleOf(host)[2]
end

-- Completion is independent of which interface is visible. Two
-- identically seeded choosers run in lockstep; one switches to the compact
-- interface mid-zoom. Clocks advance exactly once per tick on both, the
-- same observation settles both into confirmation, and the compact run
-- publishes exactly the pre-created candidate once.
function T.compact_display_preserves_clocks_observations_and_single_publication()
  local StarterChoiceState = requireState()
  local task = assert(require(TASK_MODULE))
  local catalog = CatalogFixture.makeCatalog()
  local wide = wideMeasurement()
  local compact = compactMeasurement()
  local cellA = { box = wide }
  local cellB = { box = wide }
  local serviceA = openService(catalog, SEED)
  local serviceB = openService(catalog, SEED)
  local hostA = StarterChoiceState.new({
    catalog = catalog,
    cacheFs = readyCacheFs(),
    frameIndex = 3,
    measureDisplay = function()
      return cellA.box
    end,
  })
  local hostB = StarterChoiceState.new({
    catalog = catalog,
    cacheFs = readyCacheFs(),
    frameIndex = 3,
    measureDisplay = function()
      return cellB.box
    end,
  })
  local ctxA = taskCtx(serviceA, TRIO, hostA)
  local stateA = task.create({ node = { op = "choose_starter" } }, ctxA)
  local ctxB = taskCtx(serviceB, TRIO, hostB)
  local stateB = task.create({ node = { op = "choose_starter" } }, ctxB)
  driveToChoose(task, stateA, ctxA, hostA)
  driveToChoose(task, stateB, ctxB, hostB)
  Assert.isTrue(type(hostB.handleInput) == "function", "the migrated host interprets its own input through handleInput")

  moveHost(hostA, "right")
  moveHost(hostB, "right")
  settle(hostA)
  settle(hostB)
  Assert.deepEqual(tripleOf(hostB), tripleOf(hostA), "rotation settles identically on both displays")
  Assert.equal(statusSelection(hostStatus(hostB)), 1, "rotation settles on the second candidate")
  hostA:confirm()
  hostB:confirm()
  settle(hostA)
  settle(hostB)
  Assert.deepEqual(tripleOf(hostB), tripleOf(hostA), "inspection matches across displays")

  cellB.box = compact
  hostA:confirm()
  hostB:confirm()
  for _ = 1, 512 do
    hostA:update()
    hostB:update()
    Assert.deepEqual(tripleOf(hostB), tripleOf(hostA), "hidden-model ticks advance the same observation stream")
    if tripleOf(hostA)[3] == "idle" then
      break
    end
  end
  Assert.equal(selectionStateOf(hostB), "confirm", "the compact run reaches confirmation on the same observation")
  local planB = hostB:status().presentation
  Assert.isTrue(type(planB) == "table", "the compact choice publishes its presentation plan")
  Assert.equal(#planB.panes, 1, "the compact interface is one complete pane")

  hostA:confirm()
  hostB:confirm()
  settle(hostA)
  settle(hostB)
  local doneB = hostStatus(hostB)
  Assert.isTrue(doneB.done, "the compact lock completes")
  Assert.equal(doneB.index, 1, "the compact lock reports the second candidate")

  local expected = stateB.candidates[2]
  Assert.notNil(expected, "the task pre-creates the second candidate")
  local expectedBytes = BoxCodec.encode(expected, CatalogFixture.domainContext(catalog))
  local outcome = task.poll(stateB, ctxB)
  Assert.isTrue(outcome.complete, "semantic confirmation completes the task")
  Assert.equal(serviceB:partyCount(), 1, "exactly the chosen mon enters the party")
  Assert.equal(
    BoxCodec.encode(serviceB:partyMon(0), CatalogFixture.domainContext(catalog)),
    expectedBytes,
    "publication transfers the exact pre-created instance without rerolling"
  )
  local again = task.poll(stateB, ctxB)
  Assert.isTrue(again.complete, "a restored done phase stays complete")
  Assert.equal(serviceB:partyCount(), 1, "re-polling never inserts twice")
end

-- The compact interface routes logical portrait,
-- primary, and Back regions to the unchanged controller. Presses outside
-- confirmation leave Back inert, and commands during an active transition
-- never alter the selection.
function T.compact_logical_input_dispatches_portrait_primary_and_guarded_back()
  local StarterChoiceState = requireState()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED)
  local cell = { box = compactMeasurement() }
  local host = StarterChoiceState.new({
    catalog = catalog,
    cacheFs = readyCacheFs(),
    frameIndex = 3,
    measureDisplay = function()
      return cell.box
    end,
  })
  local first = service:buildStarter("CHIKORITA")
  local second = service:buildStarter("TOTODILE")
  local third = service:buildStarter("EEVEE")
  host:open(0, { first, second, third })
  Assert.isTrue(type(host.handleInput) == "function", "the migrated host interprets its own input through handleInput")
  local plan = assert(host:status().presentation, "the compact choice publishes its presentation plan")
  local placement = assert(plan.panes[1].placement, "the compact plan carries its single placement")
  local function press(lx, ly)
    local hx, hy = LayoutGeometry.logicalToHost(placement, lx, ly)
    Assert.notNil(hx, "the compact target stays inside the visible clip")
    host:handleInput({
      { type = "pointer_down", pointerId = "touch:1", x = hx, y = hy },
      { type = "pointer_up", pointerId = "touch:1", x = hx, y = hy },
    })
  end
  press(128, 100)
  settle(host)
  Assert.equal(statusSelection(hostStatus(host)), 1, "a portrait press taps its candidate")
  press(64, 176)
  settle(host)
  Assert.equal(selectionStateOf(host), "inspect", "primary activates inspection from null")
  press(192, 176)
  Assert.deepEqual(tripleOf(host), { 1, "inspect", "idle" }, "Back outside confirmation changes nothing")
  press(64, 176)
  Assert.equal(tripleOf(host)[3], "zoomIn", "primary starts the zoom path from inspection")
  press(48, 100)
  Assert.deepEqual(tripleOf(host), { 1, "inspect", "zoomIn" }, "transition-conflicting commands do not alter selection")
  settle(host)
  Assert.equal(selectionStateOf(host), "confirm", "the zoom path settles into confirmation")
  press(192, 176)
  settle(host)
  Assert.equal(selectionStateOf(host), "inspect", "Back in confirmation returns to inspection")
  host:close()
  host:dispose()
end

-- A held press across a geometry change cannot activate a moved
-- target: the next batch carries pointer_cancel first and the stale
-- release never taps.
function T.reflow_with_a_held_press_cancels_before_release()
  local StarterChoiceState = requireState()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED)
  local cell = { box = defaultBox() }
  local host = StarterChoiceState.new({
    catalog = catalog,
    cacheFs = readyCacheFs(),
    frameIndex = 3,
    measureDisplay = function()
      return cell.box
    end,
  })
  host:open(0, {
    service:buildStarter("CHIKORITA"),
    service:buildStarter("TOTODILE"),
    service:buildStarter("EEVEE"),
  })
  local placement = assert(hostStatus(host).presentation, "the open choice publishes its plan").panes[2].placement
  local hx, hy = LayoutGeometry.logicalToHost(placement, 10, 10)
  Assert.notNil(hx, "the press starts inside the visible machine clip")
  host:handleInput({ { type = "pointer_down", pointerId = "touch:9", x = hx, y = hy } })
  cell.box = (function()
    local box = defaultBox()
    box.width = 700
    box.topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 700, height = 400 },
      role = "world",
      touch = false,
    })
    box.signature = "starter-state-reflowed"
    return box
  end)()
  local triple = tripleOf(host)
  host:handleInput({ { type = "pointer_up", pointerId = "touch:9", x = hx, y = hy } })
  Assert.deepEqual(tripleOf(host), triple, "the cancelled release changes no choice state")
  Assert.equal(statusSelection(hostStatus(host)), 0, "the cancelled release selects nothing")
  host:close()
  host:dispose()
end

-- A failing resolver publishes no partial plan: opening fails loudly
-- with no active choice and no status behind it.
function T.failing_resolvers_publish_no_partial_plan()
  local StarterChoiceState = requireState()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED)
  local host = StarterChoiceState.new({
    catalog = catalog,
    cacheFs = readyCacheFs(),
    frameIndex = 3,
    measureDisplay = defaultBox,
    overrides = {
      wide = function()
        error("starter resolver failure probe", 0)
      end,
    },
  })
  local ok = pcall(host.open, host, 0, {
    service:buildStarter("CHIKORITA"),
    service:buildStarter("TOTODILE"),
    service:buildStarter("EEVEE"),
  })
  Assert.isFalse(ok, "a failing resolver fails opening loudly")
  Assert.isFalse(host:isActive(), "a failed open leaves no active choice")
  Assert.isNil(host:status(), "a failed open publishes no status")
  host:dispose()
end

-- Input before opening is a programming error, never a silent no-op;
-- capture cancellation after close is safe.
function T.input_before_open_fails_and_cancel_after_close_is_safe()
  local StarterChoiceState = requireState()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED)
  local host = StarterChoiceState.new({
    catalog = catalog,
    cacheFs = readyCacheFs(),
    frameIndex = 3,
    measureDisplay = defaultBox,
  })
  Assert.isFalse(pcall(host.handleInput, host, {}), "input with no open choice fails instead of vanishing")
  host:open(0, {
    service:buildStarter("CHIKORITA"),
    service:buildStarter("TOTODILE"),
    service:buildStarter("EEVEE"),
  })
  host:close()
  host:cancelPointerCapture()
  host:dispose()
  host:cancelPointerCapture()
  Assert.isFalse(host:isActive(), "disposal after close stays idle")
end

-- Draw-time borrowing: the modal threads the field-owned window renderer
-- into the render resources untouched, and drawing without one fails
-- before any surface draws.
function T.drawing_borrows_the_field_window_renderer_through_render_resources()
  local StarterChoiceState = requireState()
  local state = StarterChoiceState.new({
    catalog = {},
    cacheFs = {},
    frameIndex = 2,
    measureDisplay = function()
      return {}
    end,
  })
  state._controller = {
    snapshot = function()
      return {
        selection = 0,
        selectionState = "null",
        transition = "idle",
        direction = nil,
        done = false,
        result = nil,
      }
    end,
  }
  state._presentation = {
    isReady = function()
      return true
    end,
  }
  state._candidates = {}
  state._names = {}
  local seen = {}
  local plan = {
    panes = {},
    frames = {},
    content = {},
    inputKey = "starter-borrow-probe",
    render = function(resources)
      seen[#seen + 1] = resources
    end,
    mapInput = function()
      return nil
    end,
  }
  state._session = {
    resolve = function() end,
    plan = function()
      return plan
    end,
  }
  local text = { drawLine = function() end }
  local previousLove = rawget(_G, "love")
  rawset(_G, "love", {
    graphics = {
      push = function() end,
      pop = function() end,
    },
  })
  local ok, err = pcall(function()
    local missingErr = Assert.throws(function()
      state:drawPresentation(text)
    end, "drawing without the field renderer fails instead of drawing")
    Assert.isTrue(
      tostring(missingErr):find("window renderer", 1, true) ~= nil,
      "the state names the missing borrower: " .. tostring(missingErr)
    )
    Assert.equal(#seen, 0, "no surface draws without the borrowed renderer")
    local borrowed = { drawApplicationFrame = function() end }
    state:drawPresentation(text, borrowed)
    Assert.equal(#seen, 1, "the borrowed draw reaches the render callback")
    Assert.isTrue(seen[1].windowRenderer == borrowed, "the render lends the field renderer untouched")
    Assert.isTrue(seen[1].text == text, "the render keeps its text provider beside the borrower")
  end)
  rawset(_G, "love", previousLove)
  if not ok then
    error(err, 0)
  end
end

return { tests = T }
