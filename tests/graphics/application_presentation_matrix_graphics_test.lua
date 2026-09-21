-- Integrated render matrix for the shared presentation boundary: exact
-- integer magnification, bounded cropping, DPI equivalence, translated
-- origins, fractional fallback visibility, and failure restoration through
-- one logical-surface contract; every migrated interface resolving its
-- real plans across representative hosts with matched geometry; real
-- party readability through the borrowed text renderer; and single
-- magnification for the hosted naming child. Per-application suites own
-- source-content depth (portraits, models, card art); this matrix proves
-- the common boundary uniformly. Only solid fills and measured fixture
-- ink are compared, with every painted edge on whole host pixels.

local Assert = require("tests.support.Assert")
local ApplicationLayout = require("game.hgss.src.ui.ApplicationLayout")
local ApplicationPresentation = require("game.hgss.src.ui.ApplicationPresentation")
local BagInterface = require("game.hgss.src.field.BagInterface")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local MainMenuInterface = require("game.hgss.src.menu.MainMenuInterface")
local MonCache = require("libs.assets.src.MonCache")
local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")
local NamingInterface = require("game.hgss.src.newgame.NamingInterface")
local PartyScreenInterface = require("game.hgss.src.field.PartyScreenInterface")
local PartyScreenRenderer = require("libs.hgss.src.ui.PartyScreenRenderer")
local PixelScale = require("libs.ui.src.PixelScale")
local PngWriter = require("libs.assets.src.PngWriter")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local StartMenuInterface = require("game.hgss.src.field.StartMenuInterface")
local StarterChoiceInterface = require("game.hgss.src.starters.StarterChoiceInterface")
local TrainerCardInterface = require("game.hgss.src.field.TrainerCardInterface")

local T = {}

local function measurement(width, height, topology, pixelRatio)
  return {
    width = width,
    height = height,
    topology = topology,
    pixelRatio = pixelRatio or 1,
    signature = "matrix:" .. width .. "x" .. height .. "@" .. (pixelRatio or 1),
  }
end

local function singleDisplay(width, height, pixelRatio, originX, originY)
  return measurement(
    width,
    height,
    ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = originX or 0, y = originY or 0, width = width, height = height },
      role = "world",
      touch = true,
    }),
    pixelRatio
  )
end

local function translatedPair()
  return measurement(
    800,
    600,
    ScreenTopology.dualDisplay({
      id = "world",
      rect = { x = 400, y = 100, width = 256, height = 192 },
      role = "world",
      touch = false,
    }, {
      id = "aux",
      rect = { x = 100, y = 300, width = 256, height = 192 },
      role = "auxiliary",
      touch = true,
    }),
    1
  )
end

local function contextFor(measured, configuration, interfaceTable)
  local selection = ApplicationLayout.selectSurfaces(measured)
  return {
    measurement = measured,
    configuration = configuration,
    primary = selection.primary,
    secondary = selection.secondary,
    nativeLikeInterface = interfaceTable.nativeLike,
  }
end

local function renderToCanvas(scope, width, height, paint)
  local lg = love.graphics
  local canvas = scope:own(lg.newCanvas(width, height))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  paint()
  lg.setCanvas()
  return canvas
end

local function assertPixelNear(data, x, y, r, g, b, a, label)
  local ar, ag, ab, aa = data:getPixel(x, y)
  Assert.near(ar, r, 1e-2, label .. " red")
  Assert.near(ag, g, 1e-2, label .. " green")
  Assert.near(ab, b, 1e-2, label .. " blue")
  Assert.near(aa, a, 1e-2, label .. " alpha")
end

local function captureState(lg)
  local r, g, b, a = lg.getColor()
  local sx, sy, sw, sh = lg.getScissor()
  return { color = { r, g, b, a }, scissor = { sx, sy, sw, sh }, canvas = lg.getCanvas() }
end

local function assertStateRestored(before, lg, label)
  local after = captureState(lg)
  Assert.deepEqual(after.color, before.color, label .. " color")
  Assert.deepEqual(after.scissor, before.scissor, label .. " scissor")
  Assert.isTrue(after.canvas == before.canvas, label .. " render target")
end

local function paintSolid(color, width, height)
  return function()
    local lg = love.graphics
    lg.setColor(color[1], color[2], color[3], color[4])
    lg.rectangle("fill", 0, 0, width, height)
  end
end

local function interactivePane(plan)
  for _, pane in ipairs(assert(plan.panes, "the plan must carry its panes")) do
    if pane.interactive then
      return assert(pane.placement, "the interactive pane carries its placement")
    end
  end
  error("the plan carries no interactive pane", 0)
end

-- Integer placements magnify logical blocks uniformly: every logical pixel
-- covers exactly scale x scale physical pixels with hard edges.
function T.integer_fits_magnify_blocks_uniformly(scope)
  local lg = love.graphics
  local placement = assert(
    PixelScale.placeFixed({ x = 0, y = 0, width = 640, height = 480 }, 256, 192),
    "640x480 must place its surface"
  )
  Assert.equal(placement.pixelScale, 2, "640x480 must fit at 2x")
  local canvas = renderToCanvas(scope, 640, 480, function()
    LogicalSurface.draw(lg, placement, paintSolid({ 1, 1, 1, 1 }, 256, 192))
  end)
  local data = scope:own(canvas:newImageData())
  -- Full frame at 2x from (64,48): the first logical pixel covers (64,48)
  -- through (65,49), and the edge to the next pixel is exact.
  assertPixelNear(data, 64, 48, 1, 1, 1, 1, "block origin paints")
  assertPixelNear(data, 65, 49, 1, 1, 1, 1, "block interior paints")
  assertPixelNear(data, 66, 48, 1, 1, 1, 1, "adjacent logical pixel starts exactly")
  assertPixelNear(data, 63, 48, 0, 0, 0, 0, "outside the frame stays clear")
  assertPixelNear(data, 64 + 512, 100, 0, 0, 0, 0, "past the frame edge stays clear")
end

-- The bounded 3x bump hides only its budgeted margins: the visible image
-- keeps integral pixels while the cropped edges stay clear.
function T.cropped_3x_hides_only_budgeted_margins(scope)
  local lg = love.graphics
  local placement = assert(
    PixelScale.placeFixed({ x = 0, y = 0, width = 750, height = 560 }, 256, 192),
    "750x560 must place its surface"
  )
  Assert.equal(placement.pixelScale, 3, "750x560 must bump to 3x")
  Assert.deepEqual(
    placement.crop,
    { left = 3, right = 3, top = 3, bottom = 3 },
    "the bump must spend exactly the default budget"
  )
  local canvas = renderToCanvas(scope, 750, 560, function()
    LogicalSurface.draw(lg, placement, paintSolid({ 0.5, 0.5, 0.5, 1 }, 256, 192))
  end)
  local data = scope:own(canvas:newImageData())
  for _, x in ipairs({ 0, 100, 375, 749 }) do
    assertPixelNear(data, x, 0, 0, 0, 0, 0, "cropped top margin stays clear at x=" .. x)
    assertPixelNear(data, x, 559, 0, 0, 0, 0, "cropped bottom margin stays clear at x=" .. x)
  end
  assertPixelNear(data, 375, 300, 0.5, 0.5, 0.5, 1, "visible content renders inside the clip")
  -- Cropped input inverts the full origin: the clip origin maps to the
  -- first visible logical pixel, never to zero.
  local lx, ly = LayoutGeometry.hostToLogical(placement, placement.clipRect.x, placement.clipRect.y)
  Assert.equal(lx, placement.visibleLogicalRect.x, "clip maps to its visible logical origin")
  Assert.equal(ly, placement.visibleLogicalRect.y, "clip maps to its visible logical origin")
end

-- The same physical bounds through different DPI ratios choose the same
-- pixel scale and crop: one explicit boundary conversion, never repeated
-- per widget.
function T.dpi2_matches_dpi1_physical_pixels(scope)
  local lg = love.graphics
  local one = assert(PixelScale.placeFixed({ x = 0, y = 0, width = 750, height = 560 }, 256, 192, { pixelRatio = 1 }))
  local two = assert(PixelScale.placeFixed({ x = 0, y = 0, width = 375, height = 280 }, 256, 192, { pixelRatio = 2 }))
  Assert.equal(two.pixelScale, one.pixelScale, "equal physical bounds must choose equal pixel scales")
  Assert.deepEqual(two.crop, one.crop, "equal physical bounds must crop equally")
  Assert.equal(two.scale, one.pixelScale / 2, "host-unit scale must divide out the pixel ratio")
  local first = renderToCanvas(scope, 750, 560, function()
    LogicalSurface.draw(lg, one, paintSolid({ 0.2, 0.6, 0.2, 1 }, 256, 192))
  end)
  local second = renderToCanvas(scope, 375, 280, function()
    LogicalSurface.draw(lg, two, paintSolid({ 0.2, 0.6, 0.2, 1 }, 256, 192))
  end)
  local firstData = scope:own(first:newImageData())
  local secondData = scope:own(second:newImageData())
  -- The same logical point lands on the same physical pixel in both.
  local p1x, p1y = LayoutGeometry.logicalToHost(one, 100, 100)
  local p2x, p2y = LayoutGeometry.logicalToHost(two, 100, 100)
  Assert.equal(p1x * 1, p2x * 2, "both ratios must address the same physical column")
  Assert.equal(p1y * 1, p2y * 2, "both ratios must address the same physical row")
  assertPixelNear(firstData, math.floor(p1x), math.floor(p1y), 0.2, 0.6, 0.2, 1, "ratio-1 paints")
  assertPixelNear(secondData, math.floor(p2x), math.floor(p2y), 0.2, 0.6, 0.2, 1, "ratio-2 paints")
end

-- Translated origins invert exactly: nonzero host origins never leak into
-- logical coordinates on either surface of a genuine pair.
function T.translated_origins_invert_exactly(scope)
  local lg = love.graphics
  local measured = translatedPair()
  local selection = ApplicationLayout.selectSurfaces(measured)
  local primary = assert(selection.primary, "the pair must select its primary surface")
  local secondary = assert(selection.secondary, "the pair must select its auxiliary surface")
  for _, surface in ipairs({ primary, secondary }) do
    local bounds = assert(surface.usableBounds, "each selected surface must expose usable bounds")
    local placement = assert(
      PixelScale.placeFixed({ x = bounds.x, y = bounds.y, width = bounds.width, height = bounds.height }, 256, 192),
      "each translated surface must place its pane"
    )
    -- The full frame origin inverts to the logical origin even though the
    -- host origin is nonzero; points outside the visible clip never hit.
    local ox, oy = LayoutGeometry.hostToLogical(placement, placement.frame.x, placement.frame.y)
    assert(ox ~= nil and oy ~= nil, "translated frame inverts to its logical origin")
    Assert.near(ox, 0, 1e-9, "translated frame inverts to its logical origin")
    Assert.near(oy, 0, 1e-9, "translated frame inverts to its logical origin")
    Assert.isNil(
      LayoutGeometry.hostToLogical(placement, bounds.x - 4, bounds.y - 4),
      "points outside the translated clip never hit"
    )
    local canvas = renderToCanvas(scope, 800, 600, function()
      LogicalSurface.draw(lg, placement, paintSolid({ 0.8, 0.1, 0.1, 1 }, 256, 192))
    end)
    local data = scope:own(canvas:newImageData())
    local fx, fy = math.floor(placement.frame.x), math.floor(placement.frame.y)
    if fx >= 0 and fy >= 0 and fx < 800 and fy < 600 then
      assertPixelNear(data, fx, fy, 0.8, 0.1, 0.1, 1, "translated frame paints")
    end
  end
end

-- A host smaller than any integer fit keeps every control reachable: the
-- fractional fallback draws the complete logical surface, never a subset.
function T.fractional_fallback_keeps_everything_visible(scope)
  local lg = love.graphics
  local placement = assert(
    PixelScale.placeFixed({ x = 0, y = 0, width = 200, height = 150 }, 256, 192),
    "a tiny host must still place its surface"
  )
  Assert.isTrue(placement.pixelScale < 1, "the tiny host must fall back below unit scale")
  Assert.deepEqual(placement.crop, { left = 0, right = 0, top = 0, bottom = 0 }, "the fallback must never crop")
  local canvas = renderToCanvas(scope, 200, 150, function()
    LogicalSurface.draw(lg, placement, paintSolid({ 0.9, 0.9, 0.1, 1 }, 256, 192))
  end)
  local data = scope:own(canvas:newImageData())
  assertPixelNear(data, 2, 2, 0.9, 0.9, 0.1, 1, "the near corner stays visible")
  assertPixelNear(data, 197, 147, 0.9, 0.9, 0.1, 1, "the far corner stays visible")
end

-- A failing draw callback unwinds the shared scope and rethrows the
-- original error; the next draw is unaffected.
function T.callback_failure_restores_scope_and_propagates(scope)
  local lg = love.graphics
  local placement = assert(
    PixelScale.placeFixed({ x = 0, y = 0, width = 640, height = 480 }, 256, 192),
    "640x480 must place its surface"
  )
  local marker = {}
  local before = captureState(lg)
  local canvas = scope:own(lg.newCanvas(640, 480))
  lg.setCanvas(canvas)
  local ok, err = pcall(function()
    LogicalSurface.draw(lg, placement, function()
      error(marker, 0)
    end)
  end)
  lg.setCanvas()
  Assert.isFalse(ok, "the callback failure must propagate")
  Assert.isTrue(err == marker, "the original error object must propagate unwrapped")
  assertStateRestored(before, lg, "failed draw")
  local repaint = renderToCanvas(scope, 640, 480, function()
    LogicalSurface.draw(lg, placement, paintSolid({ 0.3, 0.3, 0.9, 1 }, 256, 192))
  end)
  local data = scope:own(repaint:newImageData())
  assertPixelNear(data, 320, 240, 0.3, 0.3, 0.9, 1, "the next draw paints cleanly after failure")
end

-- Every migrated interface resolves its real plans across the matrix:
-- canonical single panes fullscreen or auxiliary, static frames on
-- wide/tall, matched input keys, and no window on fullscreen cases.
function T.all_interfaces_resolve_matched_geometry_across_matrix(scope)
  local _ = scope
  local startMenu = StartMenuInterface.withOverrides(nil)
  local party = PartyScreenInterface.withOverrides(nil)
  local card = TrainerCardInterface.withOverrides(nil)
  local partyView = { cancellable = true, cursorNode = 0 }
  local singleMeasured = singleDisplay(640, 480)
  local menuPlan = startMenu.nativeLike(contextFor(singleMeasured, "nativeLike", startMenu), {})
  Assert.equal(#menuPlan.panes, 1, "native-like start menu shows its single body")
  local untypedMenu = menuPlan --[[@as table<string, unknown>]]
  Assert.isNil(untypedMenu.fadeCoverage, "fullscreen names no transition region")

  local partyPlan = party.nativeLike(contextFor(singleMeasured, "nativeLike", party), partyView)
  Assert.equal(#partyPlan.panes, 1, "native-like party shows its single compact pane")
  Assert.equal(partyPlan.inputKey, "party", "the party plan names its input geometry")

  local cardPlan = card.nativeLike(contextFor(singleMeasured, "nativeLike", card), {})
  Assert.equal(#cardPlan.panes, 1, "native-like card shows its single surface")

  local wideMeasured = singleDisplay(1280, 720)
  local wideMenu = startMenu.wide(contextFor(wideMeasured, "wide", startMenu), {})
  Assert.equal(#wideMenu.frames, 1, "wide frames the start menu in a static box")
  local untypedWide = wideMenu --[[@as table<string, unknown>]]
  Assert.isNil(untypedWide.fadeCoverage, "a static frame owns no transition region")
  local wideParty = party.wide(contextFor(wideMeasured, "wide", party), partyView)
  Assert.equal(#wideParty.frames, 1, "wide frames the party in a static box")
  local wideCard = card.wide(contextFor(wideMeasured, "wide", card), {})
  Assert.equal(#wideCard.frames, 1, "wide frames the card in a static box")

  local tallMeasured = singleDisplay(390, 844)
  Assert.equal(
    #startMenu.tall(contextFor(tallMeasured, "tall", startMenu), {}).frames,
    1,
    "tall frames the start menu in a static box"
  )

  local dualMeasured = translatedPair()
  local dualMenu = startMenu.dualDisplay(contextFor(dualMeasured, "dualDisplay", startMenu), {})
  Assert.isTrue(#dualMenu.panes >= 1, "dual display resolves the start menu")
  local dualParty = party.dualDisplay(contextFor(dualMeasured, "dualDisplay", party), partyView)
  local dualFrame = dualParty.panes[1].placement.frame
  Assert.isTrue(
    dualFrame.x >= 100 and dualFrame.x + dualFrame.width <= 356,
    "the dual party must stay inside the auxiliary surface"
  )
end

-- The Bag pairs hero and interaction at one shared integer scale with no
-- synthetic gap and one frame around the common envelope; native-like
-- collapses to interaction with its description fallback content.
function T.bag_pairs_share_scale_with_no_gap(scope)
  local _ = scope
  local tabs = {}
  for index = 0, 7 do
    tabs[index + 1] = { x = index * 32, y = 0, width = 32, height = 32 }
  end
  local slots = {}
  for index = 1, 6 do
    slots[index] = { rect = { x = 0, y = 32 + (index - 1) * 24, width = 128, height = 22 } }
  end
  local manifest = {
    interactive = {
      pocketTabs = { rects = tabs },
      itemSlots = { slots = slots },
      cancel = { rect = { x = 192, y = 168, width = 64, height = 24 } },
      overlays = {
        descriptionFallback = {
          frame = { x = 0, y = 144, width = 256, height = 48 },
          textRect = { x = 20, y = 144, width = 236, height = 48 },
        },
        actionMenu = {
          buttons = {
            { x = 8, y = 136, width = 80, height = 16 },
            { x = 104, y = 136, width = 80, height = 16 },
            { x = 8, y = 168, width = 80, height = 16 },
            { x = 104, y = 168, width = 80, height = 16 },
          },
        },
      },
    },
  }
  local bag = BagInterface.withOverrides(nil, manifest)
  local wide = bag.wide(contextFor(singleDisplay(1280, 720), "wide", bag), {})
  Assert.equal(#wide.panes, 2, "wide pairs hero with interaction")
  Assert.equal(
    wide.panes[1].placement.pixelScale,
    wide.panes[2].placement.pixelScale,
    "paired bag panes must share one integer scale"
  )
  Assert.near(
    wide.panes[1].placement.frame.x + wide.panes[1].placement.frame.width,
    wide.panes[2].placement.frame.x,
    1e-6,
    "paired bag panes touch with no gap"
  )
  Assert.equal(#wide.frames, 1, "the pair carries one frame around its envelope")
  local tall = bag.tall(contextFor(singleDisplay(390, 844), "tall", bag), {})
  Assert.equal(#tall.panes, 2, "tall stacks hero above interaction")
  Assert.equal(
    tall.panes[1].placement.pixelScale,
    tall.panes[2].placement.pixelScale,
    "stacked bag panes must share one integer scale"
  )
  Assert.near(
    tall.panes[1].placement.frame.y + tall.panes[1].placement.frame.height,
    tall.panes[2].placement.frame.y,
    1e-6,
    "stacked bag panes touch with no gap"
  )
  Assert.equal(#tall.frames, 1, "the stacked pair carries one frame around its envelope")
  local native = bag.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike", bag), {})
  Assert.equal(#native.panes, 1, "native-like bag shows only interaction")
  Assert.notNil(native.content.descriptionFallback, "lower-only bag must carry its description fallback")
end

local function iconCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(MonCache.iconManifestPath(), {
    schema = MonCache.ICON_MANIFEST_SCHEMA,
    image = MonCache.iconImagePath(),
    entries = {
      ["MON0/f0"] = {
        x = 0,
        y = 0,
        width = 32,
        height = 32,
        frames = { { x = 0, y = 0, width = 32, height = 32, duration = 1 } },
      },
    },
    representative = { "MON0/f0" },
  })
  local pixels = {}
  for _ = 1, 64 * 64 do
    pixels[#pixels + 1] = string.char(200, 40, 40, 255)
  end
  cache:write(MonCache.iconImagePath(), PngWriter.encode(64, 64, table.concat(pixels)))
  return cache
end

-- Party readability through the real renderer and borrowed fixture text:
-- occupied cards carry name ink and the HP bar at 1x, and the doubled
-- density paints the same cards at exactly twice the frame.
function T.party_cards_stay_readable_across_densities(scope)
  local lg = love.graphics
  local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
  local provider = MonIconAssetProvider.new(iconCache())
  local renderer = PartyScreenRenderer.new({ graphics = lg, text = text })
  local function slots()
    local list = {}
    for slot0 = 0, 1 do
      list[#list + 1] = {
        slot = slot0,
        occupied = true,
        eligible = true,
        iconKey = "MON0/f0",
        displayName = "MON" .. slot0,
        level = 5,
        gender = "male",
        status = "ok",
        currentHp = 20,
        maxHp = 20,
        hpFraction = 1,
      }
    end
    for slot0 = 2, 5 do
      list[#list + 1] = { slot = slot0, occupied = false, eligible = false }
    end
    return list
  end
  local function presentation()
    return {
      open = true,
      mode = "view",
      action = "browsing",
      cursorNode = 0,
      switchSource = nil,
      actionSelection = nil,
      view = { revision = 1, slots = slots() },
      cancellable = true,
    }
  end
  local party = PartyScreenInterface.withOverrides(nil)
  local view = { cancellable = true, cursorNode = 0 }
  for _, host in ipairs({ { width = 320, height = 240 }, { width = 640, height = 480 } }) do
    local label = host.width .. "x" .. host.height
    local plan = party.nativeLike(contextFor(singleDisplay(host.width, host.height), "nativeLike", party), view)
    local placement = interactivePane(plan)
    local canvas = renderToCanvas(scope, host.width, host.height, function()
      LogicalSurface.draw(lg, placement, function()
        renderer:draw(presentation(), plan, provider)
      end)
    end)
    local data = scope:own(canvas:newImageData())
    local function inkCount(x0, y0, x1, y1)
      local count = 0
      for y = y0, y1 do
        for x = x0, x1 do
          local r, g, b, a = data:getPixel(x, y)
          if a > 0.5 and math.max(r, g, b) < 0.9 then
            count = count + 1
          end
        end
      end
      return count
    end
    -- First card origin (4,4) logical: name ink sits right of the icon
    -- and the HP bar paints at the card foot, at either density.
    local fx, fy = placement.frame.x, placement.frame.y
    local scale = placement.pixelScale
    Assert.isTrue(
      inkCount(
        math.floor(fx + 40 * scale),
        math.floor(fy + 6 * scale),
        math.floor(fx + 110 * scale),
        math.floor(fy + 22 * scale)
      ) > 0,
      label .. ": the occupied card must carry name ink"
    )
    Assert.isTrue(
      inkCount(
        math.floor(fx + 6 * scale),
        math.floor(fy + 54 * scale),
        math.floor(fx + 120 * scale),
        math.floor(fy + 56 * scale)
      ) > 0,
      label .. ": the occupied card must paint its HP bar"
    )
  end
  provider:release()
end

-- The compact starter regions land on whole host pixels through the
-- resolved placement: portraits and actions each paint inside their
-- locked logical rectangles and nowhere else.
function T.starter_compact_regions_match_locked_geometry(scope)
  local lg = love.graphics
  local starter = StarterChoiceInterface.withOverrides(nil)
  local view = { selection = 0, selectionState = "inspect", transition = "idle", done = false }
  local plan = starter.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike", starter), view)
  Assert.equal(#plan.panes, 1, "compact choice shows its single selector")
  Assert.equal(plan.inputKey, "starter-compact", "the compact plan names its input geometry")
  local placement = assert(plan.panes[1], "the compact plan carries its pane").placement
  local canvas = renderToCanvas(scope, 640, 480, function()
    LogicalSurface.draw(lg, placement, function()
      lg.setColor(0.9, 0.2, 0.2, 1)
      lg.rectangle("fill", 8, 60, 80, 80)
      lg.setColor(0.2, 0.9, 0.2, 1)
      lg.rectangle("fill", 8, 164, 112, 24)
    end)
  end)
  local data = scope:own(canvas:newImageData())
  local function hostOf(lx, ly)
    return LayoutGeometry.logicalToHost(placement, lx, ly)
  end
  local px, py = hostOf(8 + 40, 60 + 40)
  assertPixelNear(
    data,
    math.floor(px),
    math.floor(py),
    0.9,
    0.2,
    0.2,
    1,
    "the portrait region paints through the compact placement"
  )
  local ax, ay = hostOf(8 + 56, 164 + 12)
  assertPixelNear(
    data,
    math.floor(ax),
    math.floor(ay),
    0.2,
    0.9,
    0.2,
    1,
    "the primary action region paints through the compact placement"
  )
  -- Between the regions the canvas stays clear.
  local gx, gy = hostOf(120, 150)
  assertPixelNear(data, math.floor(gx), math.floor(gy), 0, 0, 0, 0, "between regions stays clear")
end

-- Hosted naming magnifies exactly once: the same canonical child through
-- 1x and 2x placements doubles its pixels with identical logical
-- content, and no parent scale multiplies the output.
function T.hosted_naming_magnifies_once_across_densities(scope)
  local lg = love.graphics
  local naming = NamingInterface.withOverrides(nil)
  local one = naming.nativeLike(contextFor(singleDisplay(320, 240), "nativeLike", naming), {})
  local two = naming.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike", naming), {})
  local onePlacement = assert(one.panes[1], "the 1x naming plan carries its pane").placement
  local twoPlacement = assert(two.panes[1], "the 2x naming plan carries its pane").placement
  Assert.equal(onePlacement.logicalWidth, 256, "the child stays canonical at 1x")
  Assert.equal(twoPlacement.logicalWidth, 256, "the child stays canonical at 2x")
  Assert.equal(twoPlacement.pixelScale, 2, "the denser host must use the doubled scale")
  Assert.deepEqual(one.frames, {}, "native-like naming publishes no outer frame")
  Assert.deepEqual(two.frames, {}, "denser native-like naming publishes no outer frame")
  local wideNaming = naming.wide(contextFor(singleDisplay(1280, 720), "wide", naming), {})
  Assert.equal(#wideNaming.panes, 1, "wide naming keeps one canonical pane")
  Assert.equal(wideNaming.panes[1].placement.logicalWidth, 256, "the wide naming child stays canonical")
  Assert.deepEqual(wideNaming.frames, {}, "wide naming publishes no outer frame")
  Assert.deepEqual(
    one.content.layout.surface,
    two.content.layout.surface,
    "both densities must share the identical canonical child"
  )
  local function drawAt(placement, width, height)
    return renderToCanvas(scope, width, height, function()
      LogicalSurface.draw(lg, placement, function()
        lg.setColor(0.7, 0.7, 0.1, 1)
        lg.rectangle("fill", 0, 0, 256, 192)
      end)
    end)
  end
  local firstData = scope:own(drawAt(onePlacement, 320, 240):newImageData())
  local secondData = scope:own(drawAt(twoPlacement, 640, 480):newImageData())
  local x1, y1 = LayoutGeometry.logicalToHost(onePlacement, 100, 100)
  local x2, y2 = LayoutGeometry.logicalToHost(twoPlacement, 100, 100)
  assertPixelNear(firstData, math.floor(x1), math.floor(y1), 0.7, 0.7, 0.1, 1, "1x child paints")
  assertPixelNear(secondData, math.floor(x2), math.floor(y2), 0.7, 0.7, 0.1, 1, "2x child paints")
  Assert.equal(math.floor(x2), math.floor(x1) * 2, "one output scale doubles the columns")
end

-- The Trainer Card near-fit bump protects its text: the guarded rect
-- stays fully inside the visible logical area at the cropped 3x.
function T.trainer_crop_protects_text_bounds(scope)
  local _ = scope
  local card = TrainerCardInterface.withOverrides(nil)
  local plan = card.nativeLike(contextFor(singleDisplay(750, 560), "nativeLike", card), {})
  local placement = assert(plan.panes[1], "the card plan carries its pane").placement
  Assert.equal(placement.pixelScale, 3, "750x560 must use the cropped 3x")
  local visible = assert(placement.visibleLogicalRect, "the cropped placement names its visible area")
  Assert.isTrue(visible.x <= 8 and visible.y <= 8, "the visible area must start at or before the protected rect")
  Assert.isTrue(
    visible.x + visible.width >= 248 and visible.y + visible.height >= 184,
    "the visible area must cover the protected rect"
  )
end

-- The responsive startup menu grows its logical viewport with density
-- instead of multiplying inner metrics: placements at 640x480 and
-- 1280x720 share one root transform each.
function T.main_menu_viewport_grows_with_density(scope)
  local _ = scope
  local menu = MainMenuInterface.withOverrides(nil)
  local view = {
    globalActions = { { id = "new-game", kind = "new_game" } },
    saves = { cards = {} },
    focus = { region = "global", actionId = "new-game" },
  }
  local small = menu.nativeLike(contextFor(singleDisplay(640, 480), "nativeLike", menu), view)
  local large = menu.nativeLike(contextFor(singleDisplay(1280, 720), "nativeLike", menu), view)
  local smallPlacement = assert(small.panes[1], "the small menu carries its pane").placement
  local largePlacement = assert(large.panes[1], "the large menu carries its pane").placement
  Assert.equal(smallPlacement.pixelScale, 2, "640x480 must use the doubled density")
  Assert.equal(largePlacement.pixelScale, 3, "1280x720 must respect the triple cap")
  Assert.isTrue(
    largePlacement.logicalWidth >= smallPlacement.logicalWidth,
    "a larger host must not shrink the logical viewport"
  )
  Assert.isNil(small.content.layout.uiScale, "the small layout must carry no presentation scale")
  Assert.isNil(large.content.layout.uiScale, "the large layout must carry no presentation scale")
end

-- Plan drawing through the shared dispatcher restores borrowed graphics
-- state and paints content through each migrated case.
function T.plan_draw_restores_state_for_every_case(scope)
  local lg = love.graphics
  local startMenu = StartMenuInterface.withOverrides(nil)
  local cases = {
    { name = "nativeLike", measured = singleDisplay(640, 480) },
    { name = "wide", measured = singleDisplay(1280, 720) },
  }
  for _, host in ipairs(cases) do
    local plan = startMenu[host.name](contextFor(host.measured, host.name, startMenu), {})
    local body = interactivePane(plan)
    plan.render = function()
      LogicalSurface.draw(lg, body, paintSolid({ 0.4, 0.4, 0.9, 1 }, 256, 192))
    end
    local before = captureState(lg)
    local canvas = renderToCanvas(scope, host.measured.width, host.measured.height, function()
      -- The dispatcher borrows resource records; an empty record proves
      -- no acquisition path hides inside the callback boundary.
      ApplicationPresentation.draw(lg, {}, {}, plan)
    end)
    assertStateRestored(before, lg, host.name .. " draw")
    local data = scope:own(canvas:newImageData())
    local hx, hy = LayoutGeometry.logicalToHost(body, 200, 100)
    assertPixelNear(
      data,
      math.floor(hx),
      math.floor(hy),
      0.4,
      0.4,
      0.9,
      1,
      host.name .. " content paints through its plan"
    )
  end
end

return GraphicsSmoke.suite(T)
