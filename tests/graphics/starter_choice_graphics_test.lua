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
  Assert.equal(manifest.scene.timing.cameraTicks, 8, "camera interpolation lasts eight source steps")
  Assert.isTrue(
    manifest.scene.camera.out.distance ~= manifest.scene.camera.inside.distance,
    "the outside and inside camera poses differ"
  )
  Assert.isTrue(
    type(manifest.messages.topInitial) == "string" and #manifest.messages.topInitial > 0,
    "the scene carries the initial top message"
  )
  Assert.isTrue(
    type(manifest.messages.inspect) == "table" and #manifest.messages.inspect == 3,
    "the scene carries one inspect description per slot"
  )
  Assert.isTrue(
    type(manifest.messages.bottom.normal) == "string" and #manifest.messages.bottom.normal > 0,
    "the scene carries the normal bottom prompt"
  )
  Assert.isNil(manifest.speciesSprites, "the scene carries no fixed species image catalog")
  local encoded = require("libs.codec.src.LuaWriter").encode(manifest)
  Assert.isNil(encoded:find("NARC_", 1, true), "the normalized manifest carries no source archive symbols")
end

local function openProductionChoice(versionId, cacheFs, manifest, speciesKeys)
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
  speciesKeys = speciesKeys or { "CHIKORITA", "CYNDAQUIL", "TOTODILE" }
  local candidates = {}
  for _, key in ipairs(speciesKeys) do
    candidates[#candidates + 1] = service:buildStarter(key)
  end
  host:open(0, candidates)
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
  host:drawPresentation({
    drawText = function() end,
    windowBackgroundColor = function()
      return { 0, 0, 0, 1 }
    end,
  }, width, height)
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
    -- The source ring is symmetric under a settled 120-degree step and the
    -- balls are small on the machine, so travel is proved two ways through
    -- the real update+draw path: the projected slot centers permute across
    -- the settled step and ride the interpolated yaw mid-rotation, while the
    -- mid-rotation frame still moves pixels through the live render path.
    local presentation = assert(host._presentation, versionId .. " owns its presentation while open")
    local before = presentation:ballCenters(host._controller:snapshot())
    if type(host.update) == "function" then
      for _ = 1, 4 do
        host:update(host)
      end
    end
    local midSnapshot = host._controller:snapshot()
    Assert.equal(midSnapshot.transition, "rotate", versionId .. " rotation is still travelling mid-step")
    Assert.near(
      presentation:yawForSnapshot(midSnapshot),
      -math.rad(120) / 2,
      1e-9,
      versionId .. " halfway rotation interpolates half the selection step"
    )
    local midRotation = scope:own(drawFrame(host, REFERENCE_WIDTH, REFERENCE_HEIGHT))
    Assert.isTrue(
      denseDistance(initial, midRotation, REFERENCE_WIDTH, REFERENCE_HEIGHT) > 10,
      versionId .. " turntable rotation moves pixels through the live render path"
    )
    settle(host)
    local rotated = scope:own(drawFrame(host, REFERENCE_WIDTH, REFERENCE_HEIGHT))
    local after = presentation:ballCenters(host._controller:snapshot())
    Assert.equal(#after, 3, versionId .. " settled rotation projects three centers")
    for _, moved in ipairs(after) do
      local matched = false
      for _, anchored in ipairs(before) do
        if math.abs(anchored.x - moved.x) < 2 and math.abs(anchored.y - moved.y) < 2 then
          matched = true
        end
      end
      Assert.isTrue(matched, versionId .. " one settled step permutes the ring slots")
    end

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

local WIDE_WIDTH = 512
local WIDE_HEIGHT = 192
local LEFT_GUTTER = 240
local RIGHT_GUTTER = 272

local function snapshotOf(host, versionId)
  local controller = assert(host._controller, versionId .. " owns its controller while open")
  return controller:snapshot()
end

local function presentationOf(host, versionId)
  return assert(host._presentation, versionId .. " owns its presentation while open")
end

local function assertThreeDistinctCenters(centers, versionId, what)
  Assert.equal(#centers, 3, versionId .. " " .. what .. " projects three centers")
  for index = 1, 3 do
    Assert.notNil(centers[index], versionId .. " " .. what .. " projects center " .. index)
  end
  for first = 1, 3 do
    for second = first + 1, 3 do
      local dx = centers[first].x - centers[second].x
      local dy = centers[first].y - centers[second].y
      Assert.isTrue(math.sqrt(dx * dx + dy * dy) > 1, versionId .. " " .. what .. " keeps slots apart")
    end
  end
end

local function assertSameSlotSet(first, second, versionId, what)
  for _, moved in ipairs(second) do
    local matched = false
    for _, anchored in ipairs(first) do
      if math.abs(anchored.x - moved.x) < 2 and math.abs(anchored.y - moved.y) < 2 then
        matched = true
      end
    end
    Assert.isTrue(matched, versionId .. " " .. what .. " keeps every rotated slot on a previous slot")
  end
end

local function touchCentroid(presentation, snapshot, index, versionId)
  local sumX, sumY, count = 0, 0, 0
  for y = 0, REFERENCE_HEIGHT - 1, 2 do
    for x = 0, REFERENCE_WIDTH - 1, 2 do
      if presentation:ballAt(x, y, snapshot) == index then
        sumX, sumY, count = sumX + x, sumY + y, count + 1
      end
    end
  end
  Assert.isTrue(count > 0, versionId .. " ball " .. index .. " owns a hit region")
  return { x = sumX / count, y = sumY / count }
end

local function assertTouchCentersTrackModelHeight(presentation, snapshot, versionId, what)
  local centers = presentation:ballCenters(snapshot)
  for index = 1, 3 do
    local center = assert(centers[index], versionId .. " " .. what .. " projects center " .. index)
    local centroid = touchCentroid(presentation, snapshot, index, versionId)
    Assert.isTrue(
      math.abs(centroid.x - center.x) < 6,
      versionId .. " " .. what .. " keeps touch region " .. index .. " in its model column"
    )
    Assert.isTrue(
      center.y - centroid.y > 1,
      versionId .. " " .. what .. " holds touch region " .. index .. " above its model origin"
    )
  end
end

local function assertBallHitsLiveOnOneSurface(host, versionId, what)
  local left, right = {}, {}
  for y = 0, WIDE_HEIGHT - 1, 8 do
    for x = 0, WIDE_WIDTH - 1, 8 do
      local hit = host:hitTest(x, y)
      if hit ~= nil and hit.kind == "ball" then
        if x < LEFT_GUTTER then
          left[hit.index] = true
        elseif x >= RIGHT_GUTTER then
          right[hit.index] = true
        end
      end
    end
  end
  local leftCount, rightCount = 0, 0
  for _ in pairs(left) do
    leftCount = leftCount + 1
  end
  for _ in pairs(right) do
    rightCount = rightCount + 1
  end
  Assert.isTrue(
    (leftCount == 3 and rightCount == 0) or (leftCount == 0 and rightCount == 3),
    versionId .. " " .. what .. " keeps ball hits on one surface"
  )
end

function T.balls_ride_the_source_ring_with_separate_touch_centers(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the retail scene needs a ready user-owned ROM with a derived cache")
  end
  local cacheModule = requireModule(CACHE_MODULE, "the starter cache owns the normalized scene")
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = loadManifest(cacheModule, cacheFs)
    local layout = manifest.scene and manifest.scene.ballLayout
    Assert.notNil(layout, versionId .. " scene carries the source ball ring layout")
    Assert.equal(layout.radius, 32, versionId .. " ring radius matches the source model")
    Assert.equal(layout.modelY, 14, versionId .. " model origins sit at the source height")
    Assert.equal(layout.touchYOffsetY, 13, versionId .. " touch centers sit above the model origins")
    Assert.deepEqual(layout.slotAnglesDegrees, { 0, 120, 240 }, versionId .. " slots are one step apart on the ring")

    local host = openProductionChoice(versionId, cacheFs, manifest)
    host:resize(WIDE_WIDTH, WIDE_HEIGHT)
    local presentation = presentationOf(host, versionId)
    local before = snapshotOf(host, versionId)
    Assert.equal(before.transition, "idle", versionId .. " opens settled")
    local centersBefore = presentation:ballCenters(before)
    assertThreeDistinctCenters(centersBefore, versionId, "outside pose")

    -- Drive the rotation through the real update+draw path so the
    -- presentation clock observes the turntable episode.
    scope:own(drawFrame(host, WIDE_WIDTH, WIDE_HEIGHT))
    moveHost(host, "right")
    for _ = 1, 32 do
      if type(host.update) == "function" then
        host:update(host)
      end
      scope:own(drawFrame(host, WIDE_WIDTH, WIDE_HEIGHT))
      if snapshotOf(host, versionId).transition == "idle" then
        break
      end
    end
    local after = snapshotOf(host, versionId)
    Assert.equal(after.transition, "idle", versionId .. " rotation settles before sampling")
    local centersAfter = presentation:ballCenters(after)
    assertThreeDistinctCenters(centersAfter, versionId, "rotated pose")
    assertSameSlotSet(centersBefore, centersAfter, versionId, "one step rotation")
    assertTouchCentersTrackModelHeight(presentation, after, versionId, "rotated pose")
    assertBallHitsLiveOnOneSurface(host, versionId, "rotated pose")
    host:dispose()
  end
end

local function recordingText()
  local texts = {}
  local provider = {
    drawText = function(first, second)
      texts[#texts + 1] = type(first) == "string" and first or second
    end,
    windowBackgroundColor = function()
      return { 0, 0, 0, 1 }
    end,
  }
  return texts, provider
end

local function drawRecorded(host, provider, width, height)
  local canvas = love.graphics.newCanvas(width, height)
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 1)
  host:drawPresentation(provider, width, height)
  love.graphics.setCanvas()
  return canvas:newImageData()
end

local function assertRecorded(texts, expected, versionId, what)
  for _, line in ipairs(texts) do
    if line == expected then
      return
    end
  end
  error(versionId .. " " .. what .. " is never drawn", 0)
end

local function assertNoRecordedName(texts, names, versionId, what)
  for _, line in ipairs(texts) do
    for _, name in ipairs(names) do
      Assert.isTrue(line ~= name, versionId .. " " .. what .. " draws no detached name label")
    end
  end
end

local function brightInRegion(image, x0, width, height)
  local found = 0
  for y = 0, height - 1, 2 do
    for x = x0, x0 + width - 1, 2 do
      local red, green, blue, alpha = image:getPixel(x, y)
      if alpha > 0.5 and math.max(red, green, blue) > 0.05 then
        found = found + 1
      end
    end
  end
  return found
end

function T.initial_and_inspected_states_render_on_separate_framed_surfaces(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the retail scene needs a ready user-owned ROM with a derived cache")
  end
  local cacheModule = requireModule(CACHE_MODULE, "the starter cache owns the normalized scene")
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = loadManifest(cacheModule, cacheFs)
    local messages = assert(manifest.messages, versionId .. " manifest carries decoded chooser messages")
    local topInitial = messages.topInitial
    Assert.isTrue(
      type(topInitial) == "string" and #topInitial > 0,
      versionId .. " manifest carries the initial top message"
    )
    Assert.isTrue(
      type(messages.inspect) == "table" and #messages.inspect == 3,
      versionId .. " manifest carries one inspect description per slot"
    )
    local bottom = assert(messages.bottom, versionId .. " manifest carries bottom prompt roles")
    Assert.isTrue(
      type(bottom.normal) == "string" and #bottom.normal > 0,
      versionId .. " manifest carries the normal bottom prompt"
    )

    local MonCatalog = requireModule(CATALOG_MODULE, "the mon catalog names the retail trio")
    local catalog =
      MonCatalog.new(requireModule(MON_CACHE_MODULE, "the mon cache owns the retail catalog").loadCatalog(cacheFs))
    local names = {}
    for _, key in ipairs({ "CHIKORITA", "CYNDAQUIL", "TOTODILE" }) do
      names[#names + 1] = catalog:species(key).name
    end

    local host = openProductionChoice(versionId, cacheFs, manifest)
    local initialTexts, initialProvider = recordingText()
    local initial = scope:own(drawRecorded(host, initialProvider, WIDE_WIDTH, WIDE_HEIGHT))
    Assert.isTrue(
      brightInRegion(initial, 0, 64, WIDE_HEIGHT) > 20,
      versionId .. " the owned backdrop fills the host outside the surfaces"
    )
    assertRecorded(initialTexts, topInitial, versionId, "the initial top message")
    assertRecorded(initialTexts, bottom.normal, versionId, "the normal bottom prompt")
    assertNoRecordedName(initialTexts, names, versionId, "the initial state")

    Assert.isNil(host:confirm(), versionId .. " first activation inspects instead of publishing")
    local slotTexts = {}
    for slot = 0, 2 do
      host:focus(slot)
      local texts, provider = recordingText()
      scope:own(drawRecorded(host, provider, WIDE_WIDTH, WIDE_HEIGHT))
      slotTexts[slot] = table.concat(texts, "\n")
      assertRecorded(texts, messages.inspect[slot + 1], versionId .. " inspected slot description")
      assertNoRecordedName(texts, names, versionId, "the inspected state")
    end
    Assert.isTrue(
      slotTexts[0] ~= slotTexts[1] and slotTexts[1] ~= slotTexts[2],
      versionId .. " neighbor slots describe different candidates"
    )

    host:focus(0)
    local _, inspectProvider = recordingText()
    local inspected = scope:own(drawRecorded(host, inspectProvider, WIDE_WIDTH, WIDE_HEIGHT))
    Assert.isTrue(
      frameDistance(initial, inspected, WIDE_WIDTH, WIDE_HEIGHT) > 10,
      versionId .. " inspecting presents the candidate portrait companion"
    )
    Assert.isFalse(hostStatus(host).done, versionId .. " inspecting keeps the chooser active")
    host:dispose()
  end
end

function T.non_trio_candidate_inspects_through_the_mon_portrait_contract(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the retail scene needs a ready user-owned ROM with a derived cache")
  end
  local cacheModule = requireModule(CACHE_MODULE, "the starter cache owns the normalized scene")
  local MonCache = requireModule(MON_CACHE_MODULE, "the generated mon cache owns the retail catalog")
  local MonCatalog = requireModule(CATALOG_MODULE, "the mon catalog names the retail species")
  local Personality = requireModule("libs.mons.src.gen4.Personality", "personality owns gender and shininess")
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = loadManifest(cacheModule, cacheFs)
    local catalog = MonCatalog.new(MonCache.loadCatalog(cacheFs))

    local host = openProductionChoice(versionId, cacheFs, manifest, { "CHIKORITA", "PIKACHU", "TOTODILE" })
    local middle = assert(host._candidates[2], versionId .. " borrows the middle candidate while open")
    local ratio = catalog:species(middle.species).genderRatio
    local gender = Personality.gender(ratio, middle.personality)
    Assert.isTrue(
      gender == "male" or gender == "female",
      versionId .. " the middle candidate resolves to a reachable portrait gender"
    )
    local shiny = Personality.shiny(middle.origin.trainerId, middle.personality)
    local selector = MonCache.portraitSelector(middle.species, middle.form, gender, shiny)
    local portraits =
      assert(cacheFs:loadLua(MonCache.portraitManifestPath()), versionId .. " the mon portrait manifest loads")
    Assert.notNil(portraits.entries[selector], versionId .. " the mon portrait contract carries the middle candidate")

    host:focus(1)
    host:confirm()
    local status = hostStatus(host)
    Assert.isFalse(status.done, versionId .. " inspecting keeps the chooser active")
    Assert.equal(status.cursor, 1, versionId .. " the middle slot stays selected")
    local middleFrame = scope:own(drawFrame(host, REFERENCE_WIDTH, REFERENCE_HEIGHT))
    Assert.isTrue(
      brightPixels(middleFrame, REFERENCE_WIDTH, REFERENCE_HEIGHT) > 0,
      versionId .. " the inspected candidate leaves visible pixels"
    )
    host:focus(0)
    local edgeFrame = scope:own(drawFrame(host, REFERENCE_WIDTH, REFERENCE_HEIGHT))
    Assert.isTrue(
      frameDistance(middleFrame, edgeFrame, REFERENCE_WIDTH, REFERENCE_HEIGHT) > 10,
      versionId .. " portraits follow the actual candidate"
    )
    host:dispose()
  end
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump", "derived_cache" }
return suite
