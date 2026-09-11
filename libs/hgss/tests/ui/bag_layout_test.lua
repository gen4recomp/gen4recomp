-- Topology-aware placement for the field bag: two canonical 256x192 panes
-- recomposed by geometry only. Covers the five representative topologies,
-- safe-area offsets, dual-display touch routing, the exact-tie rule, scale
-- thresholds, pane containment, and host-to-canonical hit mapping shared
-- with rendering. Pure geometry; no love, no GPU.

local Assert = require("tests.support.Assert")
local BagLayout = require("libs.hgss.src.ui.BagLayout")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = {}

local TAB_RECTS = {
  { x = 0, y = 0, width = 32, height = 32 },
  { x = 32, y = 0, width = 32, height = 32 },
  { x = 64, y = 0, width = 32, height = 32 },
  { x = 96, y = 0, width = 32, height = 32 },
  { x = 128, y = 0, width = 32, height = 32 },
  { x = 160, y = 0, width = 32, height = 32 },
  { x = 192, y = 0, width = 32, height = 32 },
  { x = 224, y = 0, width = 32, height = 32 },
}

local SLOT_RECTS = {
  { x = 32, y = 40, width = 88, height = 32 },
  { x = 160, y = 40, width = 88, height = 32 },
  { x = 32, y = 80, width = 88, height = 32 },
  { x = 160, y = 80, width = 88, height = 32 },
  { x = 32, y = 120, width = 88, height = 32 },
  { x = 160, y = 120, width = 88, height = 32 },
}

local function manifest()
  local tabs = {}
  for index, rect in ipairs(TAB_RECTS) do
    tabs[index] = { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
  end
  local slots = {}
  for index, rect in ipairs(SLOT_RECTS) do
    slots[index] = {
      rect = { x = rect.x, y = rect.y, width = rect.width, height = rect.height },
      iconCenter = { x = rect.x + 16, y = rect.y + 16 },
    }
  end
  return {
    interactive = {
      pocketTabs = { tabs = tabs },
      itemSlots = { slots = slots },
      pageIndicator = { rect = { x = 80, y = 168, width = 56, height = 16 } },
      cancel = { x = 192, y = 168, width = 56, height = 16 },
      overlays = {
        descriptionFallback = { frame = { x = 0, y = 144, width = 256, height = 48 } },
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
end

local function oneDisplay(width, height, touch, safeRect)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    safeRect = safeRect,
    touch = touch == true,
    role = "world",
  })
end

local function dualDisplay(worldTouch, auxTouch)
  return ScreenTopology.dualDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = worldTouch,
    role = "world",
  }, {
    id = "sub",
    rect = { x = 256, y = 0, width = 256, height = 192 },
    touch = auxTouch,
    role = "auxiliary",
  })
end

local BUTTON_RECTS = {
  { x = 8, y = 136, width = 80, height = 16 },
  { x = 104, y = 136, width = 80, height = 16 },
  { x = 8, y = 168, width = 80, height = 16 },
  { x = 104, y = 168, width = 80, height = 16 },
}

local function manifestWithButtons()
  local layoutManifest = manifest()
  local buttons = {}
  for index, rect in ipairs(BUTTON_RECTS) do
    buttons[index] = { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
  end
  layoutManifest.interactive.overlays.actionMenu = { buttons = buttons }
  return layoutManifest
end

---@param record table<string, unknown>
---@param key string
---@return unknown
local function fieldOf(record, key)
  return record[key]
end

local function browsing(occupied)
  occupied = occupied or { true, true, true, true, true, true }
  local visibleSlots = {}
  for index = 1, 6 do
    if occupied[index] then
      visibleSlots[index] = { item = "ITEM_" .. index }
    else
      visibleSlots[index] = { empty = true, visibleIndex = index - 1 }
    end
  end
  return { state = "browsing", visibleSlots = visibleSlots }
end

local function assertPlacement(placement, surfaceId)
  Assert.equal(placement.logicalWidth, 256)
  Assert.equal(placement.logicalHeight, 192)
  Assert.equal(placement.surfaceId, surfaceId)
  Assert.isTrue(placement.scale > 0, "pane scale stays positive")
end

function T.physical_dual_display_splits_hero_and_interactive()
  local resolved = BagLayout.resolve({ topology = dualDisplay(false, true), manifest = manifest() })
  Assert.equal(resolved.mode, "dual")
  assertPlacement(assert(resolved.hero, "dual mode places the hero pane"), "main")
  assertPlacement(resolved.interactive, "sub")
  Assert.isNil(resolved.descriptionFallback, "two-pane modes need no description fallback")
  Assert.isTrue(
    LayoutGeometry.contains({ x = 0, y = 0, width = 256, height = 192 }, resolved.hero.frame),
    "the hero pane stays inside the world surface"
  )
  Assert.isTrue(
    LayoutGeometry.contains({ x = 256, y = 0, width = 256, height = 192 }, resolved.interactive.frame),
    "the interactive pane stays inside the auxiliary surface"
  )
end

function T.dual_display_keeps_interactive_on_auxiliary_without_touch()
  local resolved = BagLayout.resolve({ topology = dualDisplay(true, false), manifest = manifest() })
  Assert.equal(resolved.mode, "dual")
  Assert.equal(resolved.interactive.surfaceId, "sub", "the lower pane remains the interactive target")
end

function T.wide_single_display_prefers_horizontal()
  local resolved = BagLayout.resolve({ topology = oneDisplay(1920, 1080, false), manifest = manifest() })
  Assert.equal(resolved.mode, "horizontal")
  assertPlacement(assert(resolved.hero, "horizontal mode places the hero pane"), "main")
  assertPlacement(resolved.interactive, "main")
  Assert.isTrue(resolved.interactive.scale >= 1.0, "two-pane candidates need at least unit scale")
  Assert.equal(resolved.hero.scale, resolved.interactive.scale, "two-pane modes share one common scale")
  Assert.isTrue(
    LayoutGeometry.contains({ x = 0, y = 0, width = 1920, height = 1080 }, resolved.hero.frame),
    "the hero pane stays inside the safe area"
  )
  Assert.isTrue(
    LayoutGeometry.contains({ x = 0, y = 0, width = 1920, height = 1080 }, resolved.interactive.frame),
    "the interactive pane stays inside the safe area"
  )
end

function T.tall_single_displays_prefer_vertical()
  for _, size in ipairs({ { 1080, 1920 }, { 390, 844 } }) do
    local resolved = BagLayout.resolve({
      topology = oneDisplay(size[1], size[2], size[1] == 390),
      manifest = manifest(),
    })
    Assert.equal(resolved.mode, "vertical", size[1] .. "x" .. size[2] .. " stacks the panes")
    assertPlacement(assert(resolved.hero, "vertical mode places the hero pane"), "main")
    assertPlacement(resolved.interactive, "main")
    Assert.isTrue(resolved.interactive.scale >= 1.0)
    Assert.isTrue(resolved.hero.frame.y + resolved.hero.frame.height <= resolved.interactive.frame.y + 1)
  end
end

function T.exact_tie_prefers_horizontal_on_wide_safe_areas()
  local resolved = BagLayout.resolve({ topology = oneDisplay(512, 384, false), manifest = manifest() })
  Assert.equal(resolved.mode, "horizontal", "an exact scale tie prefers horizontal when width dominates")
end

function T.square_safe_area_with_only_vertical_usable_stacks()
  local resolved = BagLayout.resolve({ topology = oneDisplay(500, 500, false), manifest = manifest() })
  Assert.equal(resolved.mode, "vertical", "a square host fits the vertical candidate only")
end

function T.constrained_surface_falls_back_to_interactive_only()
  local resolved = BagLayout.resolve({ topology = oneDisplay(256, 192, false), manifest = manifest() })
  Assert.equal(resolved.mode, "interactive_only")
  Assert.isNil(resolved.hero, "the fallback hides the hero pane")
  assertPlacement(resolved.interactive, "main")
  Assert.isTrue(resolved.descriptionFallback ~= nil, "the fallback keeps a description path")
  Assert.deepEqual(
    resolved.descriptionFallback,
    { x = 0, y = 144, width = 256, height = 48 },
    "the fallback frame matches the canonical overlay geometry"
  )
end

function T.safe_area_offsets_contain_both_panes()
  local safe = { x = 100, y = 50, width = 640, height = 480 }
  local resolved = BagLayout.resolve({ topology = oneDisplay(800, 600, false, safe), manifest = manifest() })
  Assert.equal(resolved.mode, "horizontal")
  Assert.isTrue(LayoutGeometry.contains(safe, assert(resolved.hero).frame))
  Assert.isTrue(LayoutGeometry.contains(safe, resolved.interactive.frame))
end

function T.hit_testing_resolves_tabs_slots_and_cancel_through_the_record()
  local resolved = BagLayout.resolve({ topology = oneDisplay(512, 384, false), manifest = manifest() })
  Assert.equal(resolved.mode, "horizontal")
  local interactive = resolved.interactive
  local function hostAt(logicalX, logicalY)
    return interactive.frame.x + logicalX * interactive.scale, interactive.frame.y + logicalY * interactive.scale
  end
  local state = browsing()
  local x, y = hostAt(48, 16)
  local tab = assert(resolved.interactiveHitTest(x, y, state), "a tab hit resolves")
  Assert.equal(tab.kind, "pocket")
  Assert.equal(tab.pocket, "medicine")
  x, y = hostAt(76, 56)
  local cell = assert(resolved.interactiveHitTest(x, y, state), "a slot hit resolves")
  Assert.equal(cell.kind, "item")
  Assert.equal(cell.visibleIndex, 0)
  x, y = hostAt(220, 176)
  local cancel = assert(resolved.interactiveHitTest(x, y, state), "a cancel hit resolves")
  Assert.equal(cancel.kind, "cancel")
  Assert.isNil(resolved.interactiveHitTest(interactive.frame.x - 4, interactive.frame.y - 4, state))
  local emptyState = browsing({ true, false, true, true, true, true })
  x, y = hostAt(204, 56)
  Assert.isNil(resolved.interactiveHitTest(x, y, emptyState), "empty cells carry no pointer target")
end

function T.overlay_open_routes_fallback_taps_to_description()
  local resolved = BagLayout.resolve({ topology = oneDisplay(256, 192, false), manifest = manifest() })
  Assert.equal(resolved.mode, "interactive_only")
  local interactive = resolved.interactive
  local state = browsing()
  state.state = "description_overlay"
  local x = interactive.frame.x + 200 * interactive.scale
  local y = interactive.frame.y + 150 * interactive.scale
  local target = assert(resolved.interactiveHitTest(x, y, state), "a fallback tap resolves while open")
  Assert.equal(target.kind, "description")
  local plain = browsing()
  local tab = assert(resolved.interactiveHitTest(x, y, plain), "the same point still hits content when closed")
  Assert.isTrue(tab.kind == "item" or tab.kind == "cancel", "closed taps resolve to pane content")
end

function T.resolve_rejects_a_missing_manifest()
  -- The missing manifest is the invalid input under test: build the spec
  -- through an open record so the call stays a runtime rejection probe
  -- instead of a static missing-fields diagnostic.
  ---@type table<string, any>
  local spec = { topology = oneDisplay(512, 384, false) }
  Assert.throws(function()
    ---@diagnostic disable-next-line: param-type-mismatch
    BagLayout.resolve(spec)
  end, "hit testing without canonical geometry is a composition error")
end

function T.nested_states_offer_responsive_controls_from_the_generated_buttons()
  local resolved = BagLayout.resolve({ topology = oneDisplay(512, 384, false), manifest = manifestWithButtons() })
  local interactive = resolved.interactive
  local function hostAt(logicalX, logicalY)
    return interactive.frame.x + logicalX * interactive.scale, interactive.frame.y + logicalY * interactive.scale
  end
  local function stateFor(state)
    local visibleSlots = {}
    for index = 1, 6 do
      visibleSlots[index] = { item = "ITEM_" .. index }
    end
    return { state = state, visibleSlots = visibleSlots }
  end
  local x, y = hostAt(48, 144)
  local decrement = assert(resolved.interactiveHitTest(x, y, stateFor("toss_quantity")), "the first button decrements")
  Assert.equal(decrement.kind, "quantity_delta")
  Assert.equal(fieldOf(decrement, "delta"), -1)
  x, y = hostAt(144, 144)
  local increment = assert(resolved.interactiveHitTest(x, y, stateFor("toss_quantity")), "the second button increments")
  Assert.equal(increment.kind, "quantity_delta")
  Assert.equal(fieldOf(increment, "delta"), 1)
  x, y = hostAt(48, 176)
  local quantityConfirm =
    assert(resolved.interactiveHitTest(x, y, stateFor("toss_quantity")), "the third button confirms the quantity")
  Assert.equal(quantityConfirm.kind, "confirm")
  x, y = hostAt(48, 176)
  local tossConfirm =
    assert(resolved.interactiveHitTest(x, y, stateFor("toss_confirm")), "the confirmation state confirms")
  Assert.equal(tossConfirm.kind, "confirm")
  x, y = hostAt(76, 56)
  local cell = assert(resolved.interactiveHitTest(x, y, stateFor("move_select")), "move keeps its cell targets")
  Assert.equal(cell.kind, "item")
  Assert.equal(cell.visibleIndex, 0)
  x, y = hostAt(48, 176)
  local moveConfirm =
    assert(resolved.interactiveHitTest(x, y, stateFor("move_select")), "move confirms through its own button")
  Assert.equal(moveConfirm.kind, "confirm")
end

function T.toss_states_hide_the_browsing_targets_underneath()
  local resolved = BagLayout.resolve({ topology = oneDisplay(512, 384, false), manifest = manifestWithButtons() })
  local interactive = resolved.interactive
  local function hostAt(logicalX, logicalY)
    return interactive.frame.x + logicalX * interactive.scale, interactive.frame.y + logicalY * interactive.scale
  end
  for _, state in ipairs({ "toss_quantity", "toss_confirm" }) do
    local visibleSlots = {}
    for index = 1, 6 do
      visibleSlots[index] = { item = "ITEM_" .. index }
    end
    local modal = { state = state, visibleSlots = visibleSlots }
    local x, y = hostAt(48, 16)
    Assert.isNil(resolved.interactiveHitTest(x, y, modal), state .. " exposes no pocket target")
    x, y = hostAt(76, 56)
    Assert.isNil(resolved.interactiveHitTest(x, y, modal), state .. " exposes no item target underneath")
    x, y = hostAt(220, 176)
    local cancel = assert(resolved.interactiveHitTest(x, y, modal), state .. " keeps its cancel target")
    Assert.equal(cancel.kind, "cancel")
  end
end

return { tests = T }
