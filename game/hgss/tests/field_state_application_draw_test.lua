-- FieldState's draw order: world, field/application fade, dialogue or
-- signpost attached to the world surface, the one active Start Menu or
-- Trainer Card application surface, then the developer HUD. Only the one
-- active modal surface is drawn: a menu phase never draws the card surface
-- or the world-attached dialogue/signpost, and an application phase never
-- draws the menu. The application fade covers the surface being transitioned
-- (the world viewport plus the Start Menu placement frame), so an auxiliary
-- menu surface can never stay visible while only the world viewport goes
-- black. The Start Menu surface renders through the runtime-owned placement
-- record -- the same record the host maps hit-test points through.

local Assert = require("tests.support.Assert")
local FieldState = require("game.hgss.src.field.FieldState")
local DialoguePresentationLayout = require("libs.hgss.src.ui.DialoguePresentationLayout")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local StartMenuLayout = require("libs.hgss.src.field.StartMenuLayout")

local T = {}

-- One 640x480 world display: the placement record this topology resolves is
-- { frame = {0,0,640,480}, scale = 2.5 }, mirroring the component window.
local function worldTopology()
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 640, height = 480 },
    touch = false,
    role = "world",
  })
end

-- A dual-display topology (world left, auxiliary right) whose placement
-- record lies outside the world viewport, so the application fade's union
-- coverage is observable.
local function dualTopology()
  return ScreenTopology.dualDisplay({
    id = "primary",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = false,
    role = "world",
  }, {
    id = "auxiliary",
    rect = { x = 256, y = 0, width = 256, height = 192 },
    touch = false,
    role = "auxiliary",
  })
end

-- A recording fake renderer: every draw appends its label and arguments.
local function recordingRenderer(label, sink)
  return {
    draw = function(_, ...)
      sink[#sink + 1] = { label, ... }
    end,
  }
end

-- Spies on the real love.graphics rectangle/print/setColor calls so the
-- fade and HUD primitives are observable in call order with their colors.
local function spyGraphics(sink)
  local realRectangle, realPrint, realSetColor = love.graphics.rectangle, love.graphics.print, love.graphics.setColor
  local color = { 1, 1, 1, 1 }
  rawset(love.graphics, "setColor", function(r, g, b, a)
    color = { r, g, b, a }
    realSetColor(r, g, b, a)
  end)
  rawset(love.graphics, "rectangle", function(mode, x, y, w, h)
    sink[#sink + 1] = { "rect", color[1], color[2], color[3], color[4], mode, x, y, w, h }
    realRectangle(mode, x, y, w, h)
  end)
  rawset(love.graphics, "print", function(text, ...)
    sink[#sink + 1] = { "print", color[1], color[2], color[3], color[4], text }
    realPrint(text, ...)
  end)
  return function()
    rawset(love.graphics, "rectangle", realRectangle)
    rawset(love.graphics, "print", realPrint)
    rawset(love.graphics, "setColor", realSetColor)
  end
end

-- A bare FieldState shaped like a live presentation state: fake renderers
-- recording into the sink, a fake runtime carrying every field draw touches,
-- and the topology provider under test. The player visual record is
-- invisible, so the actor assembly never touches a real asset provider.
---@param options { hostStatus: table, dialogueModal?: boolean, signpostModal?: boolean, development?: boolean, topology?: ScreenTopology, worldViewport?: table }
---@return FieldState state
---@return table[] sink
local function drawableState(options)
  local sink = {}
  local topology = options.topology or worldTopology()
  local worldViewport = options.worldViewport or { x = 0, y = 0, width = 640, height = 480 }
  -- The runtime owns the one Start Menu placement record the draw path
  -- consumes; the fake supplies it exactly like the production runtime does.
  local placement = StartMenuLayout.resolve(topology, { x = 0, y = 0, width = 640, height = 480 })
  local viewport = FieldViewport.new(640, 480, { mode = "expanded" })
  viewport.worldViewport = worldViewport
  local runtime = {
    errorText = nil,
    uiManifest = {
      dialogueFrames = { continueCursor = { placement = { x = 240, y = 168, width = 16, height = 16 } } },
    },
    runtimeMap = {
      mapId = 61,
      mapSymbol = "MAP_NEW_BARK",
      sceneRuntime = { mapDraws = {}, staticBuildingDraws = {}, animatedBuildingDraws = {} },
    },
    player = { fieldX = 3, fieldZ = 7, worldY = 1.5, surfaceId = 0, facing = "east", motion = "idle" },
    playerVisual = {
      drawRecord = function()
        return { visible = false }
      end,
    },
    actors = {
      drawRecords = function()
        return {}
      end,
    },
    session = {
      renderAlpha = function()
        return 0.5
      end,
    },
    destinationWorldPresentable = function()
      return true
    end,
    acknowledgeDestinationPresentation = function() end,
    viewport = viewport,
    camera = { zoom = 1 },
    transition = { fadeAlpha = 0 },
    fieldEntranceIndicator = {
      status = function()
        return { visible = false }
      end,
    },
    dialogue = {
      isModal = function()
        return options.dialogueModal == true
      end,
    },
    signpost = {
      isModal = function()
        return options.signpostModal == true
      end,
    },
    applicationHost = {
      status = function()
        return options.hostStatus
      end,
    },
    menuHost = {
      presentation = function()
        return nil
      end,
    },
    startMenuPlacement = placement,
    resizePresentation = function() end,
  }
  local state = setmetatable({
    development = options.development == true,
    runtime = runtime,
    topologyProvider = function()
      return topology
    end,
    worldParts = {},
    worldActorItems = {},
    spriteItems = {},
    presentationResources = {
      renderer = recordingRenderer("world", sink),
      dialogueRenderer = recordingRenderer("dialogue", sink),
      signpostRenderer = recordingRenderer("signpost", sink),
      startMenuRenderer = recordingRenderer("menu", sink),
      trainerCardRenderer = recordingRenderer("card", sink),
      menuRenderer = recordingRenderer("script-menu", sink),
      fieldEntranceIndicatorRenderer = {
        drawItems = function()
          return {}
        end,
      },
      fieldEmoteRenderer = {
        drawItems = function()
          return {}
        end,
      },
    },
    actorPresentation = {
      drawItems = function()
        return {}
      end,
      records = function()
        return {}
      end,
    },
  }, FieldState)
  return state, sink
end

local function labels(sink)
  local out = {}
  for _, call in ipairs(sink) do
    out[#out + 1] = call[1]
  end
  return out
end

-- Idle field: the world draws first, then the open dialogue attached to the
-- world surface, then the developer HUD. No fade, no application surface.
function T.draw_orders_world_then_dialogue_then_hud_when_the_field_is_idle()
  local state, sink =
    drawableState({ hostStatus = { phase = "closed", fadeAlpha = 0 }, dialogueModal = true, development = true })
  local restore = spyGraphics(sink)
  local ok, err = pcall(function()
    state:draw()
  end)
  restore()
  if not ok then
    error(err, 0)
  end

  Assert.deepEqual(labels(sink), {
    "world",
    "dialogue",
    "rect",
    "print",
    "print",
    "print",
    "print",
  })
  local dialogueCall = sink[2]
  Assert.equal(dialogueCall[2], state.runtime.dialogue, "the dialogue renderer receives the dialogue controller")
  local presentation = dialogueCall[3]
  DialoguePresentationLayout.validate(presentation)
  Assert.deepEqual(
    presentation.bounds,
    state.runtime.viewport.worldViewport,
    "the dialogue draws from a presentation resolved against the real world viewport"
  )
  Assert.isNil(dialogueCall[4], "the dialogue renders from one resolved presentation")
  Assert.equal(#sink, 7, "no signpost, menu, card, or fade draws on an idle field")
end

-- The signpost is the world-attached surface when it owns the modal slot:
-- drawn after the world, before the HUD, with the session render alpha for
-- wipe interpolation.
function T.draw_orders_world_then_signpost_then_hud_when_the_signpost_is_modal()
  local state, sink = drawableState({ hostStatus = { phase = "closed", fadeAlpha = 0 }, signpostModal = true })
  local restore = spyGraphics(sink)
  local ok, err = pcall(function()
    state:draw()
  end)
  restore()
  if not ok then
    error(err, 0)
  end

  Assert.deepEqual(labels(sink), { "world", "signpost" })
  local signpostCall = sink[2]
  Assert.equal(signpostCall[2], state.runtime.signpost, "the signpost renderer receives the signpost controller")
  Assert.equal(signpostCall[3], state.runtime.viewport, "the signpost draws into the viewport")
  Assert.equal(signpostCall[4], 0.5, "the signpost renderer receives the session render alpha")
end

-- Menu phase: only the Start Menu surface is drawn, through the placement
-- record resolved for the current topology. The world-attached dialogue and
-- signpost are not drawn even if they report modal (the session's
-- at-most-one-owner assert guarantees they cannot be, so the draw path must
-- never composite them underneath the menu).
function T.menu_phase_draws_only_the_start_menu_surface_through_the_placement_record()
  local menuStatus = { cursorSlotId = 1, cursorFrameIndex = 0 }
  local state, sink = drawableState({
    hostStatus = { phase = "menu", fadeAlpha = 0, menu = menuStatus },
    dialogueModal = true,
    signpostModal = true,
  })
  local restore = spyGraphics(sink)
  local ok, err = pcall(function()
    state:draw()
  end)
  restore()
  if not ok then
    error(err, 0)
  end

  Assert.deepEqual(labels(sink), { "world", "menu" })
  local menuCall = sink[2]
  Assert.equal(menuCall[2], menuStatus, "the start menu renderer receives the host's menu presentation")
  local expectedLayout = StartMenuLayout.resolve(worldTopology(), { x = 0, y = 0, width = 640, height = 480 })
  Assert.deepEqual(menuCall[3], expectedLayout, "the menu draws through the runtime's placement record")
  Assert.equal(menuCall[3].surfaceId, "main")
  Assert.deepEqual(menuCall[3].frame, { x = 0, y = 0, width = 640, height = 480 })
  Assert.equal(menuCall[3].scale, 2.5)
end

-- Application phase: the world stays fully faded (fadeAlpha 1) and only the
-- Trainer Card surface draws on top; the menu, dialogue, and signpost are
-- never drawn underneath the application.
function T.application_phase_draws_only_the_card_surface_and_keeps_the_world_faded()
  local applicationStatus = { name = "GOLD", trainerId = 0 }
  local state, sink = drawableState({
    hostStatus = { phase = "application", fadeAlpha = 1, application = applicationStatus },
    signpostModal = true,
  })
  local restore = spyGraphics(sink)
  local ok, err = pcall(function()
    state:draw()
  end)
  restore()
  if not ok then
    error(err, 0)
  end

  Assert.deepEqual(labels(sink), { "world", "rect", "card" })
  local fadeCall = sink[2]
  Assert.deepEqual(
    { fadeCall[2], fadeCall[3], fadeCall[4], fadeCall[5] },
    { 0, 0, 0, 1 },
    "the application fade runs at the host fade alpha"
  )
  Assert.deepEqual(
    { fadeCall[6], fadeCall[7], fadeCall[8], fadeCall[9], fadeCall[10] },
    { "fill", 0, 0, 640, 480 },
    "the fade covers the world viewport"
  )
  local cardCall = sink[3]
  Assert.equal(cardCall[2], applicationStatus, "the trainer card renderer receives the host's application presentation")
  Assert.equal(cardCall[3], state.runtime.viewport, "the card draws into the viewport")
end

-- The application fade covers the actual union of the world viewport and the
-- Start Menu placement frame: disjoint surfaces are painted as separate
-- rectangles, so the gap between them is never covered and no region is
-- painted twice (a bounding box would paint the gap; blindly drawing both
-- rects would double the alpha where they overlap).
function T.the_application_fade_paints_disjoint_surfaces_separately_and_never_the_gap()
  local state, sink = drawableState({
    hostStatus = { phase = "fading_out", fadeAlpha = 0.5 },
    topology = dualTopology(),
    worldViewport = { x = 0, y = 0, width = 256, height = 192 },
  })
  -- Separate the menu surface from the world with a real gap: the placement
  -- record is runtime-owned, but the draw path must follow it exactly.
  state.runtime.startMenuPlacement.frame = { x = 320, y = 0, width = 256, height = 192 }
  local restore = spyGraphics(sink)
  local ok, err = pcall(function()
    state:draw()
  end)
  restore()
  if not ok then
    error(err, 0)
  end

  Assert.deepEqual(labels(sink), { "rect", "rect", "world", "rect", "rect" })
  -- The field backdrop paints the host letterbox (window minus world
  -- viewport) opaque black before the world; the fade paints after it.
  Assert.deepEqual(
    { sink[1][2], sink[1][3], sink[1][4], sink[1][5], sink[1][6], sink[1][7], sink[1][8], sink[1][9], sink[1][10] },
    { 0, 0, 0, 1, "fill", 0, 192, 640, 288 },
    "the backdrop covers the letterbox below the world viewport"
  )
  Assert.deepEqual(
    { sink[2][2], sink[2][3], sink[2][4], sink[2][5], sink[2][6], sink[2][7], sink[2][8], sink[2][9], sink[2][10] },
    { 0, 0, 0, 1, "fill", 256, 0, 384, 192 },
    "the backdrop covers the letterbox right of the world viewport"
  )
  local rects = {}
  for i = 4, #sink do
    rects[#rects + 1] = { sink[i][5], sink[i][6], sink[i][7], sink[i][8], sink[i][9], sink[i][10] }
  end
  Assert.deepEqual(rects[1], { 0.5, "fill", 0, 0, 256, 192 }, "the world viewport is painted in full at the fade alpha")
  Assert.deepEqual(rects[2], { 0.5, "fill", 320, 0, 256, 192 }, "the disjoint menu frame is painted separately")
  -- The gap between the surfaces (256..320) is never covered by the fade:
  -- every fade rectangle stays inside one of the two surfaces. (The opaque
  -- backdrop behind them covers the letterbox, including the gap.)
  for _, rect in ipairs(rects) do
    local x, _, w, _ = rect[3], rect[4], rect[5], rect[6]
    local covered = (x < 256 and x + w <= 256) or (x >= 320)
    Assert.isTrue(covered, "no fade rectangle may span the gap between surfaces")
  end
  Assert.equal(#sink, 5, "backdrop, world, and fade draw; no modal surface is drawn during the fade")
end

-- A menu frame fully inside (or equal to) the world viewport adds nothing:
-- the union is exactly the world rect, so no region is alpha-doubled.
function T.the_application_fade_never_doubles_alpha_for_a_contained_menu_frame()
  local state, sink = drawableState({
    hostStatus = { phase = "fading_out", fadeAlpha = 0.5 },
    topology = worldTopology(),
  })
  state.runtime.startMenuPlacement.frame = { x = 64, y = 48, width = 320, height = 240 }
  local restore = spyGraphics(sink)
  local ok, err = pcall(function()
    state:draw()
  end)
  restore()
  if not ok then
    error(err, 0)
  end

  Assert.deepEqual(labels(sink), { "world", "rect" })
  local fadeCall = sink[2]
  Assert.deepEqual(
    { fadeCall[6], fadeCall[7], fadeCall[8], fadeCall[9], fadeCall[10] },
    { "fill", 0, 0, 640, 480 },
    "a contained menu frame adds no rectangle: the world rect alone is the union"
  )
end

-- A menu frame to the right of the world viewport with a partial overlap
-- contributes only its non-overlapping strip: the overlap region is painted
-- once (by the world rect) and the strip covers the rest.
function T.the_application_fade_paints_only_the_non_overlapping_strip_of_a_partial_overlap()
  local state, sink = drawableState({
    hostStatus = { phase = "fading_out", fadeAlpha = 0.5 },
    topology = worldTopology(),
    worldViewport = { x = 0, y = 0, width = 256, height = 192 },
  })
  state.runtime.startMenuPlacement.frame = { x = 128, y = 0, width = 384, height = 192 }
  local restore = spyGraphics(sink)
  local ok, err = pcall(function()
    state:draw()
  end)
  restore()
  if not ok then
    error(err, 0)
  end

  Assert.deepEqual(labels(sink), { "rect", "rect", "world", "rect", "rect" })
  Assert.deepEqual(
    { sink[1][6], sink[1][7], sink[1][8], sink[1][9], sink[1][10] },
    { "fill", 0, 192, 640, 288 },
    "the backdrop covers the letterbox below the world viewport"
  )
  Assert.deepEqual(
    { sink[2][6], sink[2][7], sink[2][8], sink[2][9], sink[2][10] },
    { "fill", 256, 0, 384, 192 },
    "the backdrop covers the letterbox right of the world viewport"
  )
  Assert.deepEqual(
    { sink[4][6], sink[4][7], sink[4][8], sink[4][9], sink[4][10] },
    { "fill", 0, 0, 256, 192 },
    "the world viewport is painted in full"
  )
  Assert.deepEqual(
    { sink[5][6], sink[5][7], sink[5][8], sink[5][9], sink[5][10] },
    { "fill", 256, 0, 256, 192 },
    "only the non-overlapping right strip of the menu frame is painted"
  )
  Assert.equal(#sink, 5, "backdrop, world, and fade draw; the overlapping band is painted exactly once")
end

-- The same partial overlap extending past the world top and bottom paints
-- the right strip plus the two vertical strips: every strip stays outside
-- the intersection, so no region receives alpha twice.
function T.the_application_fade_paints_the_strips_around_a_corner_overlap()
  local state, sink = drawableState({
    hostStatus = { phase = "fading_out", fadeAlpha = 0.5 },
    topology = worldTopology(),
    worldViewport = { x = 0, y = 0, width = 256, height = 192 },
  })
  state.runtime.startMenuPlacement.frame = { x = 128, y = -64, width = 384, height = 320 }
  local restore = spyGraphics(sink)
  local ok, err = pcall(function()
    state:draw()
  end)
  restore()
  if not ok then
    error(err, 0)
  end

  Assert.deepEqual(labels(sink), { "rect", "rect", "world", "rect", "rect", "rect", "rect" })
  Assert.deepEqual(
    { sink[1][6], sink[1][7], sink[1][8], sink[1][9], sink[1][10] },
    { "fill", 0, 192, 640, 288 },
    "the backdrop covers the letterbox below the world viewport"
  )
  Assert.deepEqual(
    { sink[2][6], sink[2][7], sink[2][8], sink[2][9], sink[2][10] },
    { "fill", 256, 0, 384, 192 },
    "the backdrop covers the letterbox right of the world viewport"
  )
  Assert.deepEqual(
    { sink[4][6], sink[4][7], sink[4][8], sink[4][9], sink[4][10] },
    { "fill", 0, 0, 256, 192 },
    "the world viewport is painted in full"
  )
  Assert.deepEqual(
    { sink[5][6], sink[5][7], sink[5][8], sink[5][9], sink[5][10] },
    { "fill", 256, -64, 256, 320 },
    "the right strip covers the menu frame outside the world width"
  )
  Assert.deepEqual(
    { sink[6][6], sink[6][7], sink[6][8], sink[6][9], sink[6][10] },
    { "fill", 128, -64, 128, 64 },
    "the top strip covers the menu frame above the world"
  )
  Assert.deepEqual(
    { sink[7][6], sink[7][7], sink[7][8], sink[7][9], sink[7][10] },
    { "fill", 128, 192, 128, 64 },
    "the bottom strip covers the menu frame below the world"
  )
  Assert.equal(
    #sink,
    7,
    "backdrop, world, and fade draw; the overlap region is painted exactly once (by the world rect)"
  )
end

return { tests = T }
