-- Leaf adaptation for the field Bag: four display cases resolve complete
-- matched plans over canonical logical geometry. Dual maps the hero to
-- the world surface and interaction to auxiliary; wide pairs hero left of
-- interaction; tall stacks hero above; native-like shows only the
-- interaction pane with its description fallback. Single-display pairs
-- share one integer scale across an eight logical-pixel gap; a pair that
-- cannot fit 1x falls back to the native-like case.

local Assert = require("tests.support.Assert")
local ApplicationLayout = require("game.hgss.src.ui.ApplicationLayout")
local BagInterface = require("game.hgss.src.field.BagInterface")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = {}

local CASES = { "dualDisplay", "nativeLike", "wide", "tall" }

local function manifest()
  local tabs = {}
  for index = 0, 7 do
    tabs[index + 1] = { x = index * 32, y = 0, width = 32, height = 32 }
  end
  local slots = {}
  for index = 1, 6 do
    slots[index] = { rect = { x = 0, y = 32 + (index - 1) * 24, width = 128, height = 22 } }
  end
  return {
    interactive = {
      pocketTabs = { rects = tabs },
      itemSlots = { slots = slots },
      cancel = { rect = { x = 192, y = 168, width = 64, height = 24 } },
      overlays = {
        descriptionFallback = {
          frame = { x = 0, y = 144, width = 256, height = 48 },
          textRect = { x = 20, y = 144, width = 236, height = 48 },
        },
      },
    },
  }
end

local function measurement(width, height, topology, pixelRatio)
  return {
    width = width,
    height = height,
    topology = topology,
    pixelRatio = pixelRatio or 1,
    signature = "bag-interface-test:" .. width .. "x" .. height .. "@" .. (pixelRatio or 1),
  }
end

local function singleDisplay(width, height, pixelRatio)
  return measurement(
    width,
    height,
    ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = width, height = height },
      role = "world",
      touch = false,
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

---@param measured table<string, unknown>
---@param configuration string
---@param interfaceTable table<string, unknown>
---@return ApplicationLayout.Context
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

local function bagInterface()
  return BagInterface.withOverrides(nil, manifest())
end

local function interactivePane(plan)
  local found
  for _, pane in ipairs(plan.panes) do
    if pane.interactive then
      Assert.isNil(found, "the plan carries exactly one interactive pane")
      found = pane
    end
  end
  return assert(found, "the plan carries its interactive pane")
end

function T.every_display_case_resolves_through_its_own_function()
  local interface = bagInterface()
  for _, case in ipairs(CASES) do
    Assert.isTrue(type(interface[case]) == "function", "the " .. case .. " case is a resolver function")
  end
end

function T.native_like_shows_only_the_interaction_pane_with_zero_crop()
  local interface = bagInterface()
  local measured = singleDisplay(512, 384)
  local plan = interface.nativeLike(contextFor(measured, "nativeLike", interface), {})
  Assert.equal(#plan.panes, 1, "the native-like plan shows only its interactive pane")
  Assert.isTrue(plan.panes[1].interactive, "the single pane takes input")
  Assert.equal(plan.content.heroVisible, false, "the native-like plan hides the hero pane")
  Assert.isTrue(type(plan.content.descriptionFallback) == "table", "the lower-only plan keeps its fallback")
  local placement = plan.panes[1].placement
  Assert.equal(placement.crop.left, 0, "the edge-reaching lower pane takes no left crop")
  Assert.equal(placement.crop.right, 0, "the edge-reaching lower pane takes no right crop")
  Assert.equal(placement.crop.top, 0, "the edge-reaching lower pane takes no top crop")
  Assert.equal(placement.crop.bottom, 0, "the edge-reaching lower pane takes no bottom crop")
end

function T.wide_pairs_share_one_integer_scale_with_no_gap()
  local interface = bagInterface()
  local measured = singleDisplay(1280, 720)
  local plan = interface.wide(contextFor(measured, "wide", interface), {})
  Assert.equal(#plan.panes, 2, "the wide plan pairs both panes")
  local heroPane
  for _, pane in ipairs(plan.panes) do
    if not pane.interactive then
      heroPane = pane
    end
  end
  local interaction = interactivePane(plan)
  Assert.isTrue(heroPane ~= nil, "the wide pair carries its hero pane")
  local heroPlacement = heroPane.placement
  local interactivePlacement = interaction.placement
  Assert.equal(heroPlacement.pixelScale, interactivePlacement.pixelScale, "paired panes share one integer scale")
  Assert.equal(heroPlacement.pixelScale % 1, 0, "the shared paired scale stays integral")
  Assert.isTrue(
    heroPlacement.frame.x + heroPlacement.frame.width <= interactivePlacement.frame.x,
    "the hero pane sits left of the interaction pane"
  )
  Assert.near(
    interactivePlacement.frame.x - (heroPlacement.frame.x + heroPlacement.frame.width),
    0,
    1e-6,
    "paired panes touch with no synthetic gap"
  )
  Assert.equal(#plan.frames, 1, "the pair carries one frame around its envelope")
  Assert.equal(plan.content.heroVisible, true, "the paired plan shows the hero pane")
  Assert.isNil(plan.content.descriptionFallback, "the paired plan needs no description fallback")
end

function T.tall_stacks_the_hero_above_the_interaction_pane()
  local interface = bagInterface()
  local measured = singleDisplay(600, 1000)
  local plan = interface.tall(contextFor(measured, "tall", interface), {})
  Assert.equal(#plan.panes, 2, "the tall plan pairs both panes")
  local heroPane
  for _, pane in ipairs(plan.panes) do
    if not pane.interactive then
      heroPane = pane
    end
  end
  local interaction = interactivePane(plan)
  Assert.isTrue(heroPane ~= nil, "the tall pair carries its hero pane")
  Assert.equal(heroPane.placement.pixelScale, interaction.placement.pixelScale, "stacked panes share one integer scale")
  Assert.isTrue(
    heroPane.placement.frame.y + heroPane.placement.frame.height <= interaction.placement.frame.y,
    "the hero pane sits above the interaction pane"
  )
end

function T.dual_maps_roles_to_their_physical_surfaces()
  local interface = bagInterface()
  local measured = translatedPair()
  local plan = interface.dualDisplay(contextFor(measured, "dualDisplay", interface), {})
  Assert.equal(#plan.panes, 2, "the dual plan carries both panes")
  local heroPane
  for _, pane in ipairs(plan.panes) do
    if not pane.interactive then
      heroPane = pane
    end
  end
  local interaction = interactivePane(plan)
  Assert.isTrue(heroPane ~= nil, "the dual plan carries its hero pane")
  local heroFrame = heroPane.placement.frame
  Assert.isTrue(heroFrame.x >= 400 and heroFrame.y >= 100, "the hero pane stays inside the translated world surface")
  local interactiveFrame = interaction.placement.frame
  Assert.isTrue(
    interactiveFrame.x >= 100 and interactiveFrame.y >= 300,
    "the interaction pane stays inside the translated auxiliary surface"
  )
end

-- Chrome is fitted, not clipped: on the 1100x400 host the raw pair fits
-- 2x but its complete decoration does not, so the published frame is a
-- whole unclipped outer box around two contiguous panes that share one
-- integer scale, and neither body carries crop.
function T.wide_pair_frame_is_fitted_complete_chrome_around_contiguous_panes()
  local interface = bagInterface()
  local measured = singleDisplay(1100, 400)
  local plan = interface.wide(contextFor(measured, "wide", interface), {})
  Assert.equal(#plan.panes, 2, "the wide plan pairs both panes")
  local heroPane
  for _, pane in ipairs(plan.panes) do
    if not pane.interactive then
      heroPane = pane
    end
  end
  local interaction = interactivePane(plan)
  Assert.isTrue(heroPane ~= nil, "the wide pair carries its hero pane")
  local heroPlacement = assert(heroPane.placement, "the hero pane carries its placement")
  local interactionPlacement = assert(interaction.placement, "the interaction pane carries its placement")
  Assert.equal(heroPlacement.pixelScale, interactionPlacement.pixelScale, "paired panes share one integer scale")
  Assert.near(
    interactionPlacement.frame.x - (heroPlacement.frame.x + heroPlacement.frame.width),
    0,
    1e-6,
    "paired panes touch with no synthetic gap"
  )
  for _, placement in ipairs({ heroPlacement, interactionPlacement }) do
    Assert.deepEqual(
      placement.crop or { left = 0, right = 0, top = 0, bottom = 0 },
      { left = 0, right = 0, top = 0, bottom = 0 },
      "decorated pair bodies never crop"
    )
  end
  local frame = assert(plan.frames, "the wide pair owns its frame list")[1]
  Assert.notNil(frame, "one outer frame decorates the pair")
  local outer = assert(frame.placement, "the frame carries its outer placement")
  Assert.deepEqual(outer.clipRect, outer.frame, "pair chrome is fitted, never clipped")
  Assert.isTrue(
    outer.frame.x <= heroPlacement.frame.x
      and outer.frame.y <= heroPlacement.frame.y
      and outer.frame.x + outer.frame.width >= interactionPlacement.frame.x + interactionPlacement.frame.width
      and outer.frame.y + outer.frame.height >= interactionPlacement.frame.y + interactionPlacement.frame.height,
    "the complete outer frame contains both pane frames"
  )
end

-- Physical-dual panes fit their own targets: the world hero covers its
-- exact surface with no frame while the underfilled auxiliary interaction
-- refits as an uncropped decorated box with complete chrome room.
function T.dual_underfilled_pane_refits_with_complete_chrome_on_its_own_target()
  local interface = bagInterface()
  local measured = measurement(
    1024,
    816,
    ScreenTopology.dualDisplay({
      id = "world",
      rect = { x = 0, y = 0, width = 512, height = 384 },
      role = "world",
      touch = false,
    }, {
      id = "aux",
      rect = { x = 0, y = 384, width = 512, height = 432 },
      role = "auxiliary",
      touch = true,
    }),
    1
  )
  local plan = interface.dualDisplay(contextFor(measured, "dualDisplay", interface), {})
  Assert.equal(#plan.panes, 2, "the dual plan carries both panes")
  local heroPane
  for _, pane in ipairs(plan.panes) do
    if not pane.interactive then
      heroPane = pane
    end
  end
  local interaction = interactivePane(plan)
  Assert.isTrue(heroPane ~= nil, "the dual plan carries its hero pane")
  local interactionPlacement = assert(interaction.placement, "the interaction pane carries its placement")
  Assert.deepEqual(
    interactionPlacement.crop or { left = 0, right = 0, top = 0, bottom = 0 },
    { left = 0, right = 0, top = 0, bottom = 0 },
    "the decorated dual pane never crops"
  )
  Assert.equal(#plan.frames, 1, "only the underfilled pane carries a frame")
  local frame = assert(plan.frames, "the dual plan owns its frame list")[1]
  local outer = assert(frame.placement, "the frame carries its outer placement")
  local insets = FieldDialogueTheme.applicationFrameInsets()
  Assert.equal(outer.logicalWidth, 256 + insets.left + insets.right, "the dual frame adds outer side room")
  Assert.equal(outer.logicalHeight, 192 + insets.top + insets.bottom, "the dual frame reserves the cap rows")
  Assert.deepEqual(outer.clipRect, outer.frame, "dual chrome fits its own target unclipped")
  Assert.deepEqual(
    frame.contentBox,
    { x = insets.left, y = insets.top, width = 256, height = 192 },
    "the dual body starts inside the exterior insets"
  )
end

function T.a_pair_that_cannot_fit_falls_back_to_the_native_like_case()
  local interface = bagInterface()
  local measured = singleDisplay(300, 200)
  local plan = interface.wide(contextFor(measured, "wide", interface), {})
  Assert.equal(#plan.panes, 1, "the cramped wide host falls back to one pane")
  Assert.isTrue(plan.panes[1].interactive, "the fallback pane takes input")
  Assert.equal(plan.content.heroVisible, false, "the fallback hides the hero pane")
end

function T.dpi_two_keeps_integral_physical_magnification()
  local interface = bagInterface()
  local measured = singleDisplay(640, 480, 2)
  local plan = interface.nativeLike(contextFor(measured, "nativeLike", interface), {})
  local placement = interactivePane(plan).placement
  Assert.equal(placement.pixelScale % 1, 0, "the physical magnification stays integral at ratio 2")
  Assert.equal(placement.scale, placement.pixelScale / 2, "host units divide the physical scale by the ratio")
end

function T.equivalent_measurements_resolve_the_same_plan_shape()
  local interface = bagInterface()
  local view = {}
  local first = interface.wide(contextFor(singleDisplay(1280, 720), "wide", interface), view)
  local second = interface.wide(contextFor(singleDisplay(1280, 720), "wide", interface), view)
  Assert.equal(#first.panes, #second.panes, "a fresh equivalent measurement resolves the same pane count")
  Assert.equal(first.inputKey, second.inputKey, "a fresh equivalent measurement keeps its input key")
  Assert.equal(
    first.panes[1].placement.pixelScale,
    second.panes[1].placement.pixelScale,
    "a fresh equivalent measurement keeps its scale"
  )
end

function T.an_outside_press_maps_to_a_terminal_dismiss()
  local interface = bagInterface()
  local measured = singleDisplay(512, 384)
  local plan = interface.nativeLike(contextFor(measured, "nativeLike", interface), {})
  Assert.deepEqual(
    plan.mapInput({ type = "pointer_down", pointerId = "touch:0", outside = true }, {}, plan),
    { type = "dismiss" },
    "an outside tap dismisses instead of unwinding nested bag state"
  )
  local logical = { type = "pointer_down", pointerId = "touch:0", x = 10, y = 10 }
  Assert.deepEqual(
    plan.mapInput(logical, {}, plan),
    logical,
    "an interactive-pane pointer forwards with its logical coordinates"
  )
end

function T.a_case_override_replaces_only_its_own_case()
  local full = bagInterface()
  local measured = singleDisplay(1280, 720)
  local baseline = full.wide(contextFor(measured, "wide", full), {})
  local custom = {
    panes = baseline.panes,
    content = baseline.content,
    inputKey = "bag-wide-custom",
    render = function(_, _, _) end,
    mapInput = function(_, _, _)
      return nil
    end,
    frames = baseline.frames,
  }
  local interface = BagInterface.withOverrides({
    wide = function(_, _)
      return custom
    end,
  }, manifest())
  local widePlan = interface.wide(contextFor(measured, "wide", interface), {})
  Assert.equal(widePlan.inputKey, "bag-wide-custom", "the wide override supplies its own plan")
  local nativePlan = interface.nativeLike(contextFor(singleDisplay(512, 384), "nativeLike", interface), {})
  Assert.equal(nativePlan.inputKey, "bag", "the other cases keep their default plans")
end

function T.unknown_override_cases_fail_at_composition()
  Assert.throws(function()
    BagInterface.withOverrides({
      sideways = function(_, _)
        return nil
      end,
    }, manifest())
  end, "an unknown override case fails instead of hiding")
end

return { tests = T }
