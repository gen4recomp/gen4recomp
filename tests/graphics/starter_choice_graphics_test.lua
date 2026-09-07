-- Retail starter application frame: the production chooser renders the
-- normalized tabletop, turntable, and three ball models under the
-- source camera-out pose, rotates the turntable on selection, dollies toward
-- the inside pose with ball motion and species/message layers on
-- confirmation, and resolves pointer input from rendered ball positions in
-- the 256x192 reference frame. No card rectangles or yes/no panel exist.

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
  return manifest
end

local function assertSceneContract(manifest)
  Assert.equal(manifest.reference.width, REFERENCE_WIDTH, "the scene reference is the DS viewport width")
  Assert.equal(manifest.reference.height, REFERENCE_HEIGHT, "the scene reference is the DS viewport height")
  for _, role in ipairs({ "tabletop", "turntable", "ballEffect", "ball1", "ball2", "ball3" }) do
    Assert.notNil(manifest.models[role], "the scene realizes " .. role)
  end
  Assert.equal(manifest.scene.camera.transitionTicks, 8, "camera interpolation lasts eight source ticks")
  Assert.isTrue(
    manifest.scene.camera.out.distance ~= manifest.scene.camera.inside.distance,
    "the outside and inside camera poses differ"
  )
  Assert.isTrue(
    type(manifest.messages.initial) == "string" and #manifest.messages.initial > 0,
    "the scene carries the initial source message"
  )
  Assert.isTrue(
    type(manifest.messages.confirm) == "string" and #manifest.messages.confirm > 0,
    "the scene carries the confirmation source message"
  )
  for _, id in ipairs({ "chikorita", "cyndaquil", "totodile" }) do
    Assert.notNil(manifest.speciesSprites[id], "the scene carries the " .. id .. " display sprite")
  end
  local encoded = require("libs.codec.src.LuaWriter").encode(manifest)
  Assert.isNil(encoded:find("NARC_", 1, true), "the normalized manifest carries no source archive symbols")
end

local function openProductionChoice(versionId, cacheFs, manifest)
  local StarterChoiceState = requireModule(STATE_MODULE, "the starter state owns the production chooser")
  local MonCache = requireModule(MON_CACHE_MODULE, "the generated mon cache owns the retail catalog")
  local MonCatalog = requireModule(CATALOG_MODULE, "the mon catalog names the retail trio")
  local HgssMonService = requireModule(SERVICE_MODULE, "the mon service builds the retail candidates")
  local MonsSave = requireModule(MONSAVE_MODULE, "the mon save owns the headless party bucket")
  local FieldFontLoader = requireModule(FONT_MODULE, "the field font owns the service charmap")

  local catalog = MonCatalog.new(MonCache.loadCatalog(cacheFs))
  local fontDef = FieldFontLoader.load(cacheFs)
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.empty(catalog:fingerprint(), 7),
    profile = { name = "GOLD", gender = 0, trainerId = 1 },
    game = versionId,
    language = MonCache.loadCatalog(cacheFs).version.language,
    charmap = assert(fontDef.charmap, "production font carries the charmap"),
    mapSection = function()
      return 7
    end,
    date = { year = 2000, month = 1, day = 1 },
  })
  local host = StarterChoiceState.new({ catalog = catalog, cacheFs = cacheFs })
  host:open(0, {
    service:buildStarter("CHIKORITA"),
    service:buildStarter("CYNDAQUIL"),
    service:buildStarter("TOTODILE"),
  })
  return host, manifest
end

local function hostStatus(host)
  return host:status()
end

local function settle(host, bound)
  bound = bound or 64
  for _ = 1, bound do
    -- The production host owns the full tick: it advances the controller
    -- transition clocks and the presentation clocks together. Stepping the
    -- controller a second time here would double-advance transitions, so the
    -- host update is the only step.
    if type(host.update) == "function" then
      host:update(host)
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
  local current = status.cursor or status.candidateIndex or status.selection or 0
  local delta = direction == "right" and 1 or -1
  host:focus((current + delta) % 3)
end

local function hitAt(host, x, y)
  if type(host.ballAt) == "function" then
    return host:ballAt(x, y)
  end
  return host:hitTest(x, y)
end

local function isBallHit(hit)
  if hit == nil then
    return false
  end
  if type(hit) == "number" then
    return hit == 1 or hit == 2 or hit == 3
  end
  if type(hit) == "table" then
    if hit.ball == 1 or hit.ball == 2 or hit.ball == 3 then
      return true
    end
    if hit.kind == "ball" and (hit.index == 0 or hit.index == 1 or hit.index == 2) then
      return true
    end
  end
  return false
end

local function drawFrame(host, width, height)
  local canvas = love.graphics.newCanvas(width, height)
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 1)
  host:drawPresentation({ drawText = function() end }, width, height)
  love.graphics.setCanvas()
  return canvas:newImageData()
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

-- Every-pixel motion count. The balls cover few reference pixels each, so a
-- coarse grid aliases their travel across the table; counting every changed
-- pixel measures the motion the scene actually makes. A settled scene with
-- no rotation changes nothing.
local function denseDistance(first, second, width, height)
  local changed = 0
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local r1, g1, b1 = first:getPixel(x, y)
      local r2, g2, b2 = second:getPixel(x, y)
      if math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2) > 0.03 then
        changed = changed + 1
      end
    end
  end
  return changed
end

function T.retail_scene_renders_rotates_and_confirms_through_production_composition(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the retail scene needs a ready user-owned ROM with a derived cache")
  end
  local cacheModule = requireModule(CACHE_MODULE, "the starter cache owns the normalized scene")

  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local marker = cacheFs:read(cacheModule.markerPath())
    Assert.notNil(marker, versionId .. " publishes the starter application marker")
    Assert.isTrue(
      cacheModule.isReady(cacheFs, marker),
      versionId .. " starter application cache reads ready atomically"
    )
    local manifest = loadManifest(cacheModule, cacheFs)
    assertSceneContract(manifest)

    local host = openProductionChoice(versionId, cacheFs, manifest)
    local opening = hostStatus(host)
    Assert.equal(opening.done, false, versionId .. " opens waiting on the first ball")
    Assert.isNil(opening.confirmIndex, versionId .. " carries no yes/no cursor")

    local initial = scope:own(drawFrame(host, REFERENCE_WIDTH, REFERENCE_HEIGHT))
    Assert.isTrue(
      brightPixels(initial, REFERENCE_WIDTH, REFERENCE_HEIGHT) > 20,
      versionId .. " initial tabletop, turntable, and balls leave visible pixels"
    )

    -- Pointer resolution follows rendered balls in DS reference space, never
    -- card rectangles: three distinct ball regions plus empty space outside.
    local seen = {}
    for y = 0, REFERENCE_HEIGHT - 1, 8 do
      for x = 0, REFERENCE_WIDTH - 1, 8 do
        local hit = hitAt(host, x, y)
        if hit ~= nil then
          Assert.isTrue(isBallHit(hit), versionId .. " hit testing resolves to a rendered ball, never a card region")
          local key = type(hit) == "number" and hit or (hit.ball or hit.index)
          seen[key] = true
        end
      end
    end
    local balls = 0
    for _ in pairs(seen) do
      balls = balls + 1
    end
    Assert.equal(balls, 3, versionId .. " exposes all three rendered ball hit regions")
    Assert.isTrue(not isBallHit(hitAt(host, -1, -1)), versionId .. " outside points hit no ball")

    moveHost(host, "right")
    settle(host)
    local rotated = scope:own(drawFrame(host, REFERENCE_WIDTH, REFERENCE_HEIGHT))
    Assert.isTrue(
      denseDistance(initial, rotated, REFERENCE_WIDTH, REFERENCE_HEIGHT) > 50,
      versionId .. " turntable rotation visibly moves the selection"
    )

    Assert.isNil(host:confirm(), versionId .. " first activation inspects instead of publishing")
    Assert.isNil(host:confirm(), versionId .. " second activation starts the zoom path, not the lock")
    Assert.isFalse(hostStatus(host).done, versionId .. " waits for the zoom transition before confirming")
    settle(host)
    local confirming = hostStatus(host)
    Assert.isFalse(confirming.done, versionId .. " confirmation still waits for the final lock")
    Assert.isNil(confirming.confirmIndex, versionId .. " confirms without a yes/no panel")
    local zoomed = scope:own(drawFrame(host, REFERENCE_WIDTH, REFERENCE_HEIGHT))
    Assert.isTrue(
      frameDistance(rotated, zoomed, REFERENCE_WIDTH, REFERENCE_HEIGHT) > 10,
      versionId .. " confirmation dollies the camera and presents the selected ball"
    )

    Assert.isNil(host:confirm(), versionId .. " final activation starts the lock, not the report")
    Assert.isFalse(hostStatus(host).done, versionId .. " waits for the lock/exit before reporting")
    settle(host)
    Assert.deepEqual(
      hostStatus(host),
      { done = true, index = 1 },
      versionId .. " settled lock reports the rotated candidate"
    )
    local locked = scope:own(drawFrame(host, REFERENCE_WIDTH, REFERENCE_HEIGHT))
    Assert.isTrue(
      brightPixels(locked, REFERENCE_WIDTH, REFERENCE_HEIGHT) > 0,
      versionId .. " lock/exit frame keeps presenting the scene"
    )
    host:dispose()
  end
end

function T.presentation_lifecycle_releases_exactly_once_and_reopens(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the retail scene needs a ready user-owned ROM with a derived cache")
  end
  local cacheModule = requireModule(CACHE_MODULE, "the starter cache owns the normalized scene")
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = loadManifest(cacheModule, cacheFs)
    local host = openProductionChoice(versionId, cacheFs, manifest)
    Assert.isTrue(host:isActive(), versionId .. " opens its presentation surface")
    scope:own(drawFrame(host, REFERENCE_WIDTH, REFERENCE_HEIGHT))

    host:dispose()
    Assert.isFalse(host:isActive(), versionId .. " disposal releases the modal surface")
    host:dispose()
    Assert.isFalse(host:isActive(), versionId .. " repeated disposal stays idle")

    local reopened = openProductionChoice(versionId, cacheFs, manifest)
    scope:own(drawFrame(reopened, REFERENCE_WIDTH, REFERENCE_HEIGHT))
    Assert.isTrue(hostStatus(reopened).done == false, versionId .. " reopening starts a fresh choice")
    reopened:close()
    Assert.isFalse(reopened:isActive(), versionId .. " closing releases presentation resources")
    reopened:dispose()
  end
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump", "derived_cache" }
return suite
