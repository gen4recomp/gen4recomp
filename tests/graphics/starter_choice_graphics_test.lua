-- Retail starter application frame: the production chooser renders the
-- normalized tabletop, turntable, and three ball models under the
-- source camera-out pose, rotates the turntable on selection, dollies toward
-- the inside pose with ball motion and species/message layers on
-- confirmation, and resolves pointer input from rendered ball positions in
-- the 256x192 reference frame. No card rectangles or yes/no panel exist.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
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

local function assertPreparedSceneMessage(message, what)
  Assert.isTrue(type(message) == "table", "the scene carries " .. what .. " as a prepared record")
  Assert.keySet(message, "lines", "the scene carries " .. what .. " as prepared lines")
  local lines = assert(message.lines, "the scene carries " .. what .. " lines")
  Assert.isTrue(type(lines) == "table" and #lines >= 1 and #lines <= 2, "the scene carries " .. what .. " lines")
  for _, line in ipairs(lines) do
    Assert.isTrue(type(line) == "table" and #line >= 1, "the scene carries " .. what .. " glyphs")
    for _, glyph in ipairs(line) do
      Assert.equal(glyph.kind, "glyph", "the scene carries " .. what .. " as prepared glyphs")
    end
  end
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
  assertPreparedSceneMessage(manifest.messages.topInitial, "the initial top message")
  Assert.isTrue(
    type(manifest.messages.inspect) == "table" and #manifest.messages.inspect == 3,
    "the scene carries one inspect description per slot"
  )
  for index = 1, 3 do
    assertPreparedSceneMessage(manifest.messages.inspect[index], "inspect description " .. index)
  end
  assertPreparedSceneMessage(manifest.messages.bottom.normal, "the normal bottom prompt")
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
  bound = bound or 512
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
    drawLine = function() end,
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
    -- The source ring is symmetric under a settled slot step and the
    -- balls are small on the machine, so travel is proved two ways through
    -- the real update+draw path: the projected slot centers permute across
    -- the settled step and ride the interpolated yaw mid-rotation, while the
    -- mid-rotation frame still moves pixels through the live render path.
    -- Rotation lasts one source slot step at the source rate, not the
    -- camera window.
    local presentation = assert(host._presentation, versionId .. " owns its presentation while open")
    local turntable = assert(manifest.scene.turntable, versionId .. " scene carries the turntable facts")
    local expectedRotate = turntable.selectionStepDegrees / turntable.rotationDegreesPerTick
    local before = presentation:ballCenters(host._controller:snapshot())
    if type(host.update) == "function" then
      for _ = 1, expectedRotate / 2 do
        host:update(host)
      end
    end
    local midSnapshot = host._controller:snapshot()
    Assert.equal(midSnapshot.transition, "rotate", versionId .. " rotation is still travelling mid-step")
    Assert.near(
      presentation:yawForSnapshot(midSnapshot),
      -math.rad(turntable.selectionStepDegrees) / 2,
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
    -- presentation clock observes the turntable episode. Rotation lasts one
    -- source slot step at the source rate.
    scope:own(drawFrame(host, WIDE_WIDTH, WIDE_HEIGHT))
    moveHost(host, "right")
    for _ = 1, 512 do
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
    drawLine = function() end,
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

local function recordingLines()
  local lines = {}
  local markers = {}
  local provider = {
    drawLine = function(_, line, x, y)
      lines[#lines + 1] = { line = line, x = x, y = y }
    end,
    drawText = function(_, text, x, y)
      markers[#markers + 1] = { text = text, x = x, y = y }
    end,
    windowBackgroundColor = function()
      return { 0, 0, 0, 1 }
    end,
  }
  return lines, markers, provider
end

local function assertPreparedLineCall(call, versionId, what)
  Assert.isTrue(type(call.line) == "table" and #call.line >= 1, versionId .. " " .. what .. " draws a non-empty line")
  Assert.isTrue(
    type(call.x) == "number" and type(call.y) == "number",
    versionId .. " " .. what .. " draws at a position"
  )
  for _, glyph in ipairs(call.line) do
    Assert.equal(glyph.kind, "glyph", versionId .. " " .. what .. " draws prepared glyphs")
    Assert.isTrue(
      type(glyph.code) == "number" and glyph.code % 1 == 0 and glyph.code >= 0 and glyph.code <= 65535,
      versionId .. " " .. what .. " keeps field-font codes"
    )
    Assert.isTrue(
      type(glyph.colorIndex) == "number"
        and glyph.colorIndex % 1 == 0
        and glyph.colorIndex >= 0
        and glyph.colorIndex < FieldMessageText.COLOR_VARIANT_COUNT,
      versionId .. " " .. what .. " keeps palette color indices"
    )
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
    assertPreparedSceneMessage(messages.topInitial, "the initial top message")
    Assert.isTrue(
      type(messages.inspect) == "table" and #messages.inspect == 3,
      versionId .. " manifest carries one inspect description per slot"
    )
    for index = 1, 3 do
      assertPreparedSceneMessage(messages.inspect[index], "inspect description " .. index)
    end
    local bottom = assert(messages.bottom, versionId .. " manifest carries bottom prompt roles")
    assertPreparedSceneMessage(bottom.normal, "the normal bottom prompt")

    local host = openProductionChoice(versionId, cacheFs, manifest)
    local initialLines, initialMarkers, initialProvider = recordingLines()
    local initial = scope:own(drawRecorded(host, initialProvider, WIDE_WIDTH, WIDE_HEIGHT))
    Assert.isTrue(
      brightInRegion(initial, 0, 64, WIDE_HEIGHT) > 20,
      versionId .. " the owned backdrop fills the host outside the surfaces"
    )
    Assert.equal(#initialMarkers, 0, versionId .. " the initial state draws no marker string")
    local expectedInitial = {}
    for _, line in ipairs(bottom.normal.lines) do
      expectedInitial[#expectedInitial + 1] = line
    end
    for _, line in ipairs(messages.topInitial.lines) do
      expectedInitial[#expectedInitial + 1] = line
    end
    Assert.equal(#initialLines, #expectedInitial, versionId .. " the initial state draws every generated line once")
    for index, line in ipairs(expectedInitial) do
      Assert.deepEqual(initialLines[index].line, line, versionId .. " initial line " .. index .. " keeps its colors")
    end

    Assert.isNil(host:confirm(), versionId .. " first activation inspects instead of publishing")
    local slotKeys = {}
    for slot = 0, 2 do
      host:focus(slot)
      local drawn, markers, provider = recordingLines()
      scope:own(drawRecorded(host, provider, WIDE_WIDTH, WIDE_HEIGHT))
      Assert.equal(#markers, 0, versionId .. " the inspected state draws no marker string")
      local expected = {}
      for _, line in ipairs(bottom.normal.lines) do
        expected[#expected + 1] = line
      end
      for _, line in ipairs(messages.inspect[slot + 1].lines) do
        expected[#expected + 1] = line
      end
      Assert.equal(#drawn, #expected, versionId .. " inspected slot draws every generated line once")
      local key = {}
      for index, line in ipairs(expected) do
        Assert.deepEqual(drawn[index].line, line, versionId .. " inspected slot line " .. index .. " keeps its colors")
        for _, glyph in ipairs(line) do
          key[#key + 1] = tostring(glyph.code) .. ":" .. tostring(glyph.colorIndex)
        end
      end
      slotKeys[slot] = table.concat(key, ",")
    end
    Assert.isTrue(
      slotKeys[0] ~= slotKeys[1] and slotKeys[1] ~= slotKeys[2],
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

local function stepHostUntil(host, predicate, bound)
  for _ = 1, bound do
    host:update()
    if predicate() then
      return true
    end
  end
  return false
end

-- The live playback frame of one named clip on a realized model instance, or
-- nil when the clip is not attached. Reads the existing player progress, so
-- it observes real clip advancement rather than elapsed test ticks.
---@param instance table realized model instance
---@param clipName string
---@param AnimationClip table
---@return table?, number?
local function liveClipFrame(instance, clipName, AnimationClip)
  Assert.notNil(instance, "clip sampling requires the realized model instance")
  local unit = assert(AnimationClip.FRAME_UNIT, "animation clips own the frame unit")
  for _, category in ipairs({ "joint", "material" }) do
    local attachments = instance.animationState:attachments(category)
    for _, attachment in ipairs(attachments) do
      if attachment.clip.name == clipName or attachment.clip.id == clipName then
        return attachment, attachment.player.frameFx / unit
      end
    end
  end
  return nil, nil
end

local function selectedRockName(host, versionId)
  local presentation = presentationOf(host, versionId)
  local selection = snapshotOf(host, versionId).selection
  return presentation,
    selection,
    assert(presentation._clipNames.ballRock[selection + 1], versionId .. " resolves the selected ball rock clip")
end

-- Mean channel brightness over the interior of a host surface rectangle.
-- Coarse stride keeps full-frame sampling cheap; the inset avoids backdrop
-- bleed at the surface edges.
---@param image table love ImageData under test
---@param rect { x: number, y: number, width: number, height: number } host surface rectangle
---@param width number canvas width in host pixels
---@param height number canvas height in host pixels
---@return number mean channel brightness in 0..1
local function regionMean(image, rect, width, height)
  local x0 = math.max(0, math.floor(rect.x) + 6)
  local x1 = math.min(width, math.ceil(rect.x + rect.width) - 6)
  local y0 = math.max(0, math.floor(rect.y) + 6)
  local y1 = math.min(height, math.ceil(rect.y + rect.height) - 6)
  Assert.isTrue(x1 > x0 and y1 > y0, "fade sampling needs a non-degenerate surface region")
  local sum, count = 0, 0
  for y = y0, y1 - 1, 3 do
    for x = x0, x1 - 1, 3 do
      local red, green, blue = image:getPixel(x, y)
      sum = sum + (red + green + blue) / 3
      count = count + 1
    end
  end
  Assert.isTrue(count > 0, "fade sampling reads surface pixels")
  return sum / count
end

-- One realized frame without retaining the pixels: keeps every-tick
-- realization cheap while the test samples only selected ticks.
local function presentFrame(host, width, height)
  local canvas = love.graphics.newCanvas(width, height)
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 1)
  host:drawPresentation({
    drawLine = function() end,
    drawText = function() end,
    windowBackgroundColor = function()
      return { 0, 0, 0, 1 }
    end,
  }, width, height)
  love.graphics.setCanvas()
  canvas:release()
end

local function driveToConfirm(host, versionId, scope)
  moveHost(host, "right")
  Assert.isTrue(
    stepHostUntil(host, function()
      return snapshotOf(host, versionId).transition == "idle"
    end, 1024),
    versionId .. " rotation settles before inspection"
  )
  Assert.isNil(host:confirm(), versionId .. " first activation inspects instead of publishing")
  scope:own(drawFrame(host, REFERENCE_WIDTH, REFERENCE_HEIGHT))
  Assert.isNil(host:confirm(), versionId .. " second activation starts the zoom path, not the lock")
  Assert.isTrue(
    stepHostUntil(host, function()
      return snapshotOf(host, versionId).selectionState == "confirm"
    end, 1024),
    versionId .. " the zoom path reaches confirmation"
  )
end

function T.confirm_waits_for_small_wobble_frame_through_production_playback(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the retail scene needs a ready user-owned ROM with a derived cache")
  end
  local cacheModule = requireModule(CACHE_MODULE, "the starter cache owns the normalized scene")
  local AnimationClip = requireModule("libs.assets.src.model.AnimationClip", "animation clips own the frame unit")
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = loadManifest(cacheModule, cacheFs)
    local timing = assert(manifest.scene.timing, versionId .. " scene carries the source timing boundaries")
    local wobbleFrame = assert(timing.smallWobbleFrame, versionId .. " timing carries the small-wobble frame")
    local cameraTicks = assert(timing.cameraTicks, versionId .. " timing carries the camera boundary")
    local host = openProductionChoice(versionId, cacheFs, manifest)
    moveHost(host, "right")
    Assert.isTrue(
      stepHostUntil(host, function()
        return snapshotOf(host, versionId).transition == "idle"
      end, 1024),
      versionId .. " rotation settles before inspection"
    )
    Assert.isNil(host:confirm(), versionId .. " first activation inspects instead of publishing")
    scope:own(drawFrame(host, REFERENCE_WIDTH, REFERENCE_HEIGHT))
    Assert.isNil(host:confirm(), versionId .. " second activation starts the zoom path, not the lock")

    local presentation, selection, rockName = selectedRockName(host, versionId)
    local instance = assert(
      presentation._instances["ball" .. (selection + 1)],
      versionId .. " realizes the selected ball before the zoom path"
    )
    local maxFrame = -1.0
    local elapsed, entered = 0, false
    while elapsed < wobbleFrame + cameraTicks + 32 do
      local attachment, frame = liveClipFrame(instance, rockName, AnimationClip)
      if attachment ~= nil then
        Assert.isTrue(
          attachment.player.frameCount > wobbleFrame,
          versionId .. " the selected rock clip spans the small-wobble threshold"
        )
        if frame ~= nil and frame > maxFrame then
          maxFrame = frame
        end
      end
      host:update()
      elapsed = elapsed + 1
      if snapshotOf(host, versionId).selectionState == "confirm" then
        entered = true
        break
      end
    end
    Assert.isTrue(entered, versionId .. " the zoom path reaches confirmation")
    Assert.isTrue(maxFrame >= 0, versionId .. " the selected ball visibly rocks through the zoom path")
    local _, lastFrame = liveClipFrame(instance, rockName, AnimationClip)
    local entryFrame = lastFrame or maxFrame
    Assert.isTrue(
      entryFrame >= wobbleFrame,
      versionId
        .. string.format(
          " confirmation waits for the small-wobble phase (entered at frame %.1f, threshold %d)",
          entryFrame,
          wobbleFrame
        )
    )
    host:dispose()
  end
end

function T.selected_rock_continues_through_confirm_and_cancel_restores_outside(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the retail scene needs a ready user-owned ROM with a derived cache")
  end
  local cacheModule = requireModule(CACHE_MODULE, "the starter cache owns the normalized scene")
  local AnimationClip = requireModule("libs.assets.src.model.AnimationClip", "animation clips own the frame unit")
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = loadManifest(cacheModule, cacheFs)
    local messages = assert(manifest.messages, versionId .. " manifest carries decoded chooser messages")
    local host = openProductionChoice(versionId, cacheFs, manifest)
    moveHost(host, "right")
    Assert.isTrue(
      stepHostUntil(host, function()
        return snapshotOf(host, versionId).transition == "idle"
      end, 1024),
      versionId .. " rotation settles before inspection"
    )
    Assert.isNil(host:confirm(), versionId .. " first activation inspects instead of publishing")
    scope:own(drawFrame(host, REFERENCE_WIDTH, REFERENCE_HEIGHT))
    local presentation = presentationOf(host, versionId)
    local outsideCenters = presentation:ballCenters(snapshotOf(host, versionId))
    Assert.isNil(host:confirm(), versionId .. " second activation starts the zoom path, not the lock")
    Assert.isTrue(
      stepHostUntil(host, function()
        return snapshotOf(host, versionId).selectionState == "confirm"
      end, 1024),
      versionId .. " the zoom path reaches confirmation"
    )

    local selection = snapshotOf(host, versionId).selection
    local rockName =
      assert(presentation._clipNames.ballRock[selection + 1], versionId .. " resolves the selected ball rock clip")
    local selected =
      assert(presentation._instances["ball" .. (selection + 1)], versionId .. " realizes the confirmed ball")
    local _, first = liveClipFrame(selected, rockName, AnimationClip)
    Assert.equal(
      snapshotOf(host, versionId).transition,
      "idle",
      versionId .. " the rock sample is taken from settled confirmation"
    )
    Assert.notNil(first, versionId .. " the selected ball keeps rocking while confirmation idles")
    host:update()
    host:update()
    host:update()
    local _, later = liveClipFrame(selected, rockName, AnimationClip)
    Assert.notNil(later, versionId .. " confirmation never parks the selected rock")
    Assert.isTrue(later > first, versionId .. " selected rock frames keep advancing through confirmation")
    Assert.equal(
      snapshotOf(host, versionId).selectionState,
      "confirm",
      versionId .. " sampling never leaves confirmation"
    )
    for ball = 1, 3 do
      if ball ~= selection + 1 then
        local other = assert(presentation._instances["ball" .. ball], versionId .. " realizes ball " .. ball)
        local rockAttachment = liveClipFrame(other, presentation._clipNames.ballRock[ball], AnimationClip)
        local openAttachment = liveClipFrame(other, presentation._clipNames.ballOpen, AnimationClip)
        Assert.isNil(rockAttachment, versionId .. " non-selected ball " .. ball .. " stays at baseline")
        Assert.isNil(openAttachment, versionId .. " non-selected ball " .. ball .. " never opens")
      end
    end

    local inspectSnapshot = snapshotOf(host, versionId)
    Assert.equal(inspectSnapshot.transition, "idle", versionId .. " sampling starts from settled confirmation")
    host:cancel()
    Assert.isTrue(
      stepHostUntil(host, function()
        return snapshotOf(host, versionId).transition == "idle"
      end, 64),
      versionId .. " backing out settles to the normal chooser"
    )
    local backedOut = snapshotOf(host, versionId)
    Assert.equal(backedOut.selectionState, "inspect", versionId .. " backing out restores inspection")
    Assert.equal(backedOut.selection, selection, versionId .. " backing out preserves the inspected ball")
    Assert.isFalse(hostStatus(host).done, versionId .. " backing out never publishes")
    for ball = 1, 3 do
      local ballInstance = assert(presentation._instances["ball" .. ball], versionId .. " realizes ball " .. ball)
      Assert.isNil(
        (liveClipFrame(ballInstance, presentation._clipNames.ballOpen, AnimationClip)),
        versionId .. " backing out leaves no stale open playback on ball " .. ball
      )
    end
    local restoredCenters = presentation:ballCenters(backedOut)
    for index = 1, 3 do
      Assert.near(
        restoredCenters[index].x,
        outsideCenters[index].x,
        1e-9,
        versionId .. " backing out restores the outside ball column " .. index
      )
      Assert.near(
        restoredCenters[index].y,
        outsideCenters[index].y,
        1e-9,
        versionId .. " backing out restores the outside ball row " .. index
      )
    end
    local drawn, markers, provider = recordingLines()
    scope:own(drawRecorded(host, provider, WIDE_WIDTH, WIDE_HEIGHT))
    Assert.equal(#markers, 0, versionId .. " backing out draws no marker string")
    local expected = {}
    for _, line in ipairs(messages.bottom.normal.lines) do
      expected[#expected + 1] = line
    end
    for _, line in ipairs(messages.inspect[selection + 1].lines) do
      expected[#expected + 1] = line
    end
    Assert.equal(#drawn, #expected, versionId .. " backing out restores every inspect line once")
    for index, line in ipairs(expected) do
      Assert.deepEqual(drawn[index].line, line, versionId .. " restored inspect line " .. index .. " keeps its colors")
    end
    local confirmKeys = {}
    for _, line in ipairs(messages.confirm[selection + 1].lines) do
      confirmKeys[#confirmKeys + 1] = line
    end
    for _, call in ipairs(drawn) do
      for _, confirmLine in ipairs(confirmKeys) do
        local same = #call.line == #confirmLine
        if same then
          for glyphIndex, glyph in ipairs(call.line) do
            if glyph.code ~= confirmLine[glyphIndex].code or glyph.colorIndex ~= confirmLine[glyphIndex].colorIndex then
              same = false
              break
            end
          end
        end
        Assert.isFalse(same, versionId .. " backing out hides the confirm description")
      end
    end
    host:dispose()
  end
end

function T.final_lock_runs_open_effect_and_sequential_fades_before_result(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the retail scene needs a ready user-owned ROM with a derived cache")
  end
  local cacheModule = requireModule(CACHE_MODULE, "the starter cache owns the normalized scene")
  local AnimationClip = requireModule("libs.assets.src.model.AnimationClip", "animation clips own the frame unit")
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = loadManifest(cacheModule, cacheFs)
    local timing = assert(manifest.scene.timing, versionId .. " scene carries the source timing boundaries")
    local infoTicks = assert(timing.infoFadeTicks, versionId .. " timing carries the info fade boundary")
    local machineTicks = assert(timing.machineFadeTicks, versionId .. " timing carries the machine fade boundary")
    local host = openProductionChoice(versionId, cacheFs, manifest)
    driveToConfirm(host, versionId, scope)

    local presentation, selection = selectedRockName(host, versionId)
    local selected =
      assert(presentation._instances["ball" .. (selection + 1)], versionId .. " realizes the confirmed ball")
    local openName = assert(presentation._clipNames.ballOpen, versionId .. " resolves the ball-open clip")
    local effectName = assert(presentation._clipNames.ballEffect, versionId .. " resolves the ball-effect clip")
    local effect = assert(presentation._instances.ballEffect, versionId .. " realizes the ball effect")
    local _, baselineProvider = recordingText()
    local baseline = scope:own(drawRecorded(host, baselineProvider, WIDE_WIDTH, WIDE_HEIGHT))
    local machineSurface = assert(host._machine, versionId .. " lays out the machine surface before the lock")
    local machineRect = assert(machineSurface.rect, versionId .. " the machine surface carries its rectangle")
    local infoSurface = assert(host._info, versionId .. " lays out the info surface before the lock")
    local infoRect = assert(infoSurface.rect, versionId .. " the info surface carries its rectangle")
    local baseInfo = regionMean(baseline, infoRect, WIDE_WIDTH, WIDE_HEIGHT)
    local baseMachine = regionMean(baseline, machineRect, WIDE_WIDTH, WIDE_HEIGHT)
    Assert.isTrue(
      baseInfo < 0.6,
      versionId .. string.format(" the lock starts from the unfaded info surface (mean %.3f)", baseInfo)
    )

    Assert.isNil(host:confirm(), versionId .. " final activation starts the lock, not the report")
    Assert.isNil(
      (liveClipFrame(selected, openName, AnimationClip)),
      versionId .. " ball-open starts on the first exit tick, never synchronously"
    )
    local exitTicks, openHandle, openFrame, infoMeanAtInfoEnd, machineMeanAtInfoEnd = 0, nil, nil, nil, nil
    local finalImage, finalInfo, finalMachine = nil, nil, nil
    while exitTicks < infoTicks + machineTicks do
      host:update()
      exitTicks = exitTicks + 1
      local openAttachment, frame = liveClipFrame(selected, openName, AnimationClip)
      Assert.notNil(openAttachment, versionId .. " the lock opens the selected ball exactly once")
      if openHandle == nil then
        openHandle, openFrame = openAttachment, frame
      else
        Assert.isTrue(openAttachment == openHandle, versionId .. " repeated exit ticks never replay the ball-open clip")
        Assert.isTrue(frame >= openFrame, versionId .. " ball-open frames advance monotonically through the exit")
        openFrame = frame
      end
      local effectAttachment = liveClipFrame(effect, effectName, AnimationClip)
      Assert.notNil(effectAttachment, versionId .. " the lock effect stays active through the exit")
      if exitTicks < infoTicks + machineTicks then
        Assert.isFalse(hostStatus(host).done, versionId .. " the result waits for the final fade tick")
      end
      if exitTicks == infoTicks then
        local _, infoEndProvider = recordingText()
        local infoEnd = scope:own(drawRecorded(host, infoEndProvider, WIDE_WIDTH, WIDE_HEIGHT))
        infoMeanAtInfoEnd = regionMean(infoEnd, infoRect, WIDE_WIDTH, WIDE_HEIGHT)
        machineMeanAtInfoEnd = regionMean(infoEnd, machineRect, WIDE_WIDTH, WIDE_HEIGHT)
      end
    end
    Assert.isTrue(
      infoMeanAtInfoEnd ~= nil and infoMeanAtInfoEnd >= 0.6 and (infoMeanAtInfoEnd - baseInfo) > 0.4,
      versionId
        .. string.format(
          " the info surface fades white over exactly its window (end %.3f, base %.3f)",
          infoMeanAtInfoEnd or -1,
          baseInfo
        )
    )
    Assert.isTrue(
      machineMeanAtInfoEnd ~= nil and math.abs(machineMeanAtInfoEnd - baseMachine) < 0.3,
      versionId
        .. string.format(
          " the machine fade starts only after the info fade completes (machine %.3f, base %.3f)",
          machineMeanAtInfoEnd or -1,
          baseMachine
        )
    )
    local _, finalProvider = recordingText()
    finalImage = drawRecorded(host, finalProvider, WIDE_WIDTH, WIDE_HEIGHT)
    scope:own(finalImage)
    finalInfo = regionMean(finalImage, infoRect, WIDE_WIDTH, WIDE_HEIGHT)
    finalMachine = regionMean(finalImage, machineRect, WIDE_WIDTH, WIDE_HEIGHT)
    Assert.isTrue(
      finalMachine >= 0.6 and (finalMachine - baseMachine) > 0.4,
      versionId
        .. string.format(
          " the machine surface fades white over exactly its window (end %.3f, base %.3f)",
          finalMachine,
          baseMachine
        )
    )
    Assert.deepEqual(
      hostStatus(host),
      { done = true, index = snapshotOf(host, versionId).selection },
      versionId .. " the settled lock reports only after the final fade"
    )
    Assert.isTrue(finalInfo >= 0.6, versionId .. " the info fade holds through the machine fade")
    host:dispose()
  end
end

function T.headless_and_realized_paths_share_completion_boundaries(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the retail scene needs a ready user-owned ROM with a derived cache")
  end
  local cacheModule = requireModule(CACHE_MODULE, "the starter cache owns the normalized scene")
  local AnimationClip = requireModule("libs.assets.src.model.AnimationClip", "animation clips own the frame unit")
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = loadManifest(cacheModule, cacheFs)
    local timing = assert(manifest.scene.timing, versionId .. " scene carries the source timing boundaries")
    local turntable = assert(manifest.scene.turntable, versionId .. " scene carries the turntable facts")
    local wobbleFrame = assert(timing.smallWobbleFrame, versionId .. " timing carries the small-wobble frame")
    local expectedRotate = turntable.selectionStepDegrees / turntable.rotationDegreesPerTick
    Assert.equal(expectedRotate, math.floor(expectedRotate), versionId .. " the rotation spans whole ticks")
    local headless = openProductionChoice(versionId, cacheFs, manifest)
    local realized = openProductionChoice(versionId, cacheFs, manifest)
    moveHost(headless, "right")
    moveHost(realized, "right")

    local rotateTicks = 0
    local lateChecked = false
    while rotateTicks < 1024 do
      if snapshotOf(headless, versionId).transition == "idle" then
        break
      end
      headless:update()
      presentFrame(realized, REFERENCE_WIDTH, REFERENCE_HEIGHT)
      realized:update()
      rotateTicks = rotateTicks + 1
      if rotateTicks == 2 and not lateChecked then
        lateChecked = true
        local before = snapshotOf(headless, versionId)
        Assert.equal(before.transition, "rotate", versionId .. " rotation is still travelling mid-step")
        scope:own(drawFrame(headless, REFERENCE_WIDTH, REFERENCE_HEIGHT))
        local after = snapshotOf(headless, versionId)
        Assert.equal(after.transition, before.transition, versionId .. " late realization never restarts the step")
        Assert.equal(after.selection, before.selection, versionId .. " late realization never reselects")
        Assert.equal(
          after.selectionState,
          before.selectionState,
          versionId .. " late realization never changes the interaction state"
        )
      end
    end
    Assert.equal(
      snapshotOf(realized, versionId).transition,
      "idle",
      versionId .. " the realized path settles the same rotation"
    )
    Assert.equal(
      snapshotOf(headless, versionId).selection,
      snapshotOf(realized, versionId).selection,
      versionId .. " both paths settle on the same ball"
    )
    Assert.equal(
      rotateTicks,
      expectedRotate,
      versionId .. string.format(" rotation lasts one source slot step (%d ticks)", expectedRotate)
    )

    Assert.isNil(headless:confirm(), versionId .. " the headless path inspects instead of publishing")
    Assert.isNil(realized:confirm(), versionId .. " the realized path inspects instead of publishing")
    scope:own(drawFrame(realized, REFERENCE_WIDTH, REFERENCE_HEIGHT))
    Assert.isNil(headless:confirm(), versionId .. " the headless path starts its zoom path, not the lock")
    Assert.isNil(realized:confirm(), versionId .. " the realized path starts its zoom path, not the lock")
    local zoomTicks = 0
    while zoomTicks < wobbleFrame + timing.cameraTicks + 64 do
      if
        snapshotOf(headless, versionId).selectionState == "confirm"
        and snapshotOf(realized, versionId).selectionState == "confirm"
      then
        break
      end
      headless:update()
      presentFrame(realized, REFERENCE_WIDTH, REFERENCE_HEIGHT)
      realized:update()
      zoomTicks = zoomTicks + 1
    end
    Assert.equal(
      snapshotOf(headless, versionId).selectionState,
      "confirm",
      versionId .. " the headless path reaches confirmation without realization"
    )
    Assert.equal(
      snapshotOf(realized, versionId).selectionState,
      "confirm",
      versionId .. " the realized path reaches the same confirmation"
    )
    local realizedPresentation = presentationOf(realized, versionId)
    local realizedSelection = snapshotOf(realized, versionId).selection
    local _, entryFrame = liveClipFrame(
      assert(realizedPresentation._instances["ball" .. (realizedSelection + 1)], versionId .. " realizes its ball"),
      realizedPresentation._clipNames.ballRock[realizedSelection + 1],
      AnimationClip
    )
    Assert.isTrue((entryFrame or -1) >= wobbleFrame, versionId .. " both paths confirm only in the small-wobble phase")

    Assert.isNil(headless:confirm(), versionId .. " the headless path starts its lock, not the report")
    Assert.isNil(realized:confirm(), versionId .. " the realized path starts its lock, not the report")
    local exitTicks = 0
    while exitTicks < timing.infoFadeTicks + timing.machineFadeTicks + 32 do
      if hostStatus(headless).done and hostStatus(realized).done then
        break
      end
      headless:update()
      presentFrame(realized, REFERENCE_WIDTH, REFERENCE_HEIGHT)
      realized:update()
      exitTicks = exitTicks + 1
    end
    Assert.isTrue(hostStatus(headless).done, versionId .. " the headless path completes the lock")
    Assert.isTrue(hostStatus(realized).done, versionId .. " the realized path completes the same lock")
    Assert.equal(
      exitTicks,
      timing.infoFadeTicks + timing.machineFadeTicks,
      versionId .. " both paths publish only after the sequential fades"
    )
    Assert.deepEqual(hostStatus(headless), hostStatus(realized), versionId .. " both paths report the same result")
    headless:dispose()
    realized:dispose()
  end
end

function T.production_chooser_delegates_prepared_lines_to_the_field_renderer(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the retail scene needs a ready user-owned ROM with a derived cache")
  end
  local cacheModule = requireModule(CACHE_MODULE, "the starter cache owns the normalized scene")
  local FieldDialogueTheme =
    requireModule("libs.hgss.src.ui.FieldDialogueTheme", "the field theme owns the line spacing")
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = loadManifest(cacheModule, cacheFs)
    local host = openProductionChoice(versionId, cacheFs, manifest)

    local lines, markers, provider = recordingLines()
    scope:own(drawRecorded(host, provider, WIDE_WIDTH, WIDE_HEIGHT))
    Assert.equal(#markers, 0, versionId .. " draws no marker string")
    Assert.isTrue(#lines >= 2, versionId .. " the two-line message produces two line operations")
    for _, call in ipairs(lines) do
      assertPreparedLineCall(call, versionId, "the initial message")
    end
    local spaced = false
    for index = 2, #lines do
      if
        lines[index].x == lines[index - 1].x
        and math.abs((lines[index].y - lines[index - 1].y) - FieldDialogueTheme.lineHeight) < 1e-9
      then
        spaced = true
      end
    end
    Assert.isTrue(spaced, versionId .. " prepared lines advance one theme spacing")
    if type(manifest.messages.topInitial) == "table" and type(manifest.messages.bottom.normal) == "table" then
      local expected = {}
      for _, line in ipairs(manifest.messages.bottom.normal.lines) do
        expected[#expected + 1] = line
      end
      for _, line in ipairs(manifest.messages.topInitial.lines) do
        expected[#expected + 1] = line
      end
      Assert.equal(#lines, #expected, versionId .. " every generated line reaches the renderer once")
      for index, line in ipairs(expected) do
        Assert.deepEqual(lines[index].line, line, versionId .. " line " .. index .. " preserves its colors")
      end
    end

    Assert.isNil(host:confirm(), versionId .. " first activation inspects instead of publishing")
    local inspectedLines, inspectedMarkers, inspectedProvider = recordingLines()
    scope:own(drawRecorded(host, inspectedProvider, WIDE_WIDTH, WIDE_HEIGHT))
    Assert.equal(#inspectedMarkers, 0, versionId .. " the inspected message draws no marker string")
    Assert.isTrue(#inspectedLines >= 1, versionId .. " the inspected message reaches the renderer as lines")
    for _, call in ipairs(inspectedLines) do
      assertPreparedLineCall(call, versionId, "the inspected message")
    end
    host:dispose()
  end
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump", "derived_cache" }
return suite
