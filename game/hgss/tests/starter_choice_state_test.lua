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
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

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

local function semanticManifest()
  local ball = dynamicDescriptor({ "ball-rock", "ball-open" })
  return {
    schema = "g4-starter-choice-v1",
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
      ballPositions = {
        { x = -16, y = 0, z = 0 },
        { x = 0, y = 0, z = 0 },
        { x = 16, y = 0, z = 0 },
      },
      camera = {
        out = { angleX = -49.57, perspective = 24.805, target = { x = 0, y = 0, z = 14 }, distance = 100 },
        inside = { angleX = -30.76, perspective = 22.7, target = { x = 0, y = 0, z = 12 }, distance = 60 },
        transitionTicks = 8,
      },
      ballYRotation = { out = 0, inside = 180 },
      wobble = { frameCount = 4 },
    },
    messages = {
      initial = "Professor Elm: Touch a Poké Ball to see what Pokémon is inside!",
      confirm = "Once you've decided, touch a Poké Ball!",
    },
    speciesSprites = {
      chikorita = { image = "assets/generated/starter_choice/chikorita.png", width = 32, height = 32 },
      cyndaquil = { image = "assets/generated/starter_choice/cyndaquil.png", width = 32, height = 32 },
      totodile = { image = "assets/generated/starter_choice/totodile.png", width = 32, height = 32 },
    },
  }
end

-- A ready semantic cache behind the headless host: the validated manifest,
-- every referenced payload, and the completion marker. The current host
-- ignores it outside draw; the retail host boots from it and fails loudly
-- without it.
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
  cacheFs:write(cacheModule.markerPath(), marker)
  return cacheFs
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

-- Advances any deterministic transition clock the host or its controller
-- exposes. Hosts without a clock settle immediately.
local function settle(host, bound)
  bound = bound or 64
  for _ = 1, bound do
    local advanced = false
    for _, name in ipairs({ "update", "updateFixed", "tick", "advance", "step" }) do
      if type(host[name]) == "function" then
        host[name](host)
        advanced = true
      end
    end
    local controller = host._controller
    if controller ~= nil then
      for _, name in ipairs({ "update", "tick", "updateFixed", "advance", "step" }) do
        if type(controller[name]) == "function" then
          controller[name](controller)
          advanced = true
        end
      end
    end
    if not advanced then
      return
    end
    local status = hostStatus(host)
    if status ~= nil and status.done == true then
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
  local host = StarterChoiceState.new({ catalog = catalog, cacheFs = readyCacheFs() })
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
  Assert.deepEqual(hostStatus(host), { done = true, index = 1 }, "the settled lock reports the second candidate")

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

function T.open_close_and_resize_follow_the_task_contract_without_gpu()
  local StarterChoiceState = requireState()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED)
  local host = StarterChoiceState.new({ catalog = catalog, cacheFs = readyCacheFs() })
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

  host:resize(390, 844)
  Assert.equal(statusSelection(hostStatus(host)), 0, "resizing preserves the cursor without reselecting")
  Assert.isNil(host:hitTest(100000, 100000), "far points hit nothing")

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
  local host = StarterChoiceState.new({ catalog = catalog, cacheFs = cacheFs })
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
  host:press(0)
  Assert.isNil(host:release(0), "tapping the current ball inspects instead of publishing")
  Assert.isFalse(hostStatus(host).done, "inspection still waits for confirmation")

  host:press(1)
  Assert.isNil(host:release(1), "tapping another ball rotates toward it, never publishes")
  Assert.equal(statusSelection(hostStatus(host)), 0, "rotation waits for its transition instead of jumping")
  settle(host)
  Assert.equal(statusSelection(hostStatus(host)), 1, "the settled tap selects the tapped ball")

  host:press(1)
  Assert.isNil(host:release(1), "tapping the current ball inspects it")
  host:press(1)
  Assert.isNil(host:release(1), "tapping the inspected ball starts confirmation, not the lock")
  settle(host)
  Assert.isFalse(hostStatus(host).done, "confirmation still waits for the final lock tap")

  host:press(nil)
  Assert.isNil(host:release(nil), "tapping outside backs out of confirmation")
  settle(host)
  Assert.isFalse(hostStatus(host).done, "backing out returns without publishing")
  Assert.equal(statusSelection(hostStatus(host)), 1, "backing out preserves the inspected ball")
  host:close()
  host:dispose()
end

function T.transition_timing_comes_from_the_generated_manifest()
  local StarterChoiceState = requireState()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED)
  local cacheFs = readyCacheFs()
  local cacheModule = assert(require(CACHE_MODULE))
  local manifest = assert(cacheFs:loadLua(cacheModule.manifestPath()))
  local ticks = manifest.scene.camera.transitionTicks
  Assert.isTrue(type(ticks) == "number" and ticks >= 1, "the manifest carries its transition timing")
  local host = openTrio(StarterChoiceState, catalog, service, cacheFs)
  Assert.equal(host._controller:snapshot().ticks, ticks, "the host boots the controller from manifest timing")

  moveHost(host, "right")
  local rotated = 0
  while statusSelection(hostStatus(host)) == 0 do
    host:update()
    rotated = rotated + 1
    Assert.isTrue(rotated <= ticks, "rotation settles within one manifest transition")
  end
  Assert.equal(rotated, ticks, "rotation lasts exactly the manifest transition")
  Assert.equal(statusSelection(hostStatus(host)), 1, "a settled right step advances one ball")

  host:confirm()
  host:confirm()
  local zoomed = 0
  while host._controller:snapshot().selectionState ~= "confirm" do
    host:update()
    zoomed = zoomed + 1
    Assert.isTrue(zoomed <= 2 * ticks, "the zoom path settles within two manifest transitions")
  end
  Assert.equal(zoomed, 2 * ticks, "zoom and wait last exactly two manifest transitions")

  host:confirm()
  local locked = 0
  while not hostStatus(host).done do
    host:update()
    locked = locked + 1
    Assert.isTrue(locked <= ticks, "the lock settles within one manifest transition")
  end
  Assert.equal(locked, ticks, "the lock lasts exactly the manifest transition")
  Assert.deepEqual(hostStatus(host), { done = true, index = 1 }, "the settled lock reports the second candidate")
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

function T.resize_reprojects_hit_testing_without_reselecting()
  local StarterChoiceState = requireState()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED)
  local host = openTrio(StarterChoiceState, catalog, service, readyCacheFs())

  host:resize(390, 844)
  Assert.equal(statusSelection(hostStatus(host)), 0, "resizing preserves the cursor without reselecting")
  local seen = {}
  for y = 0, 843, 12 do
    for x = 0, 389, 12 do
      local hit = host:hitTest(x, y)
      if hit ~= nil then
        Assert.equal(hit.kind, "ball", "resized hit testing resolves to a rendered ball")
        seen[hit.index] = true
      end
    end
  end
  local balls = 0
  for _ in pairs(seen) do
    balls = balls + 1
  end
  Assert.equal(balls, 3, "the resized scene exposes all three ball hit regions")
  host:close()
  host:dispose()
end

return { tests = T }
