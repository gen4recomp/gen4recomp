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

local SLOT_SHAPES = {
  { rect = { x = 0, y = 32, width = 128, height = 42 }, center = { x = 48, y = 56 } },
  { rect = { x = 128, y = 32, width = 128, height = 42 }, center = { x = 176, y = 56 } },
  { rect = { x = 0, y = 74, width = 128, height = 44 }, center = { x = 48, y = 96 } },
  { rect = { x = 128, y = 74, width = 128, height = 44 }, center = { x = 176, y = 96 } },
  { rect = { x = 0, y = 118, width = 128, height = 36 }, center = { x = 48, y = 136 } },
  { rect = { x = 128, y = 118, width = 128, height = 36 }, center = { x = 176, y = 136 } },
}

local function manifest()
  local tabs = {}
  for index, rect in ipairs(TAB_RECTS) do
    tabs[index] = { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
  end
  local slots = {}
  for _, shape in ipairs(SLOT_SHAPES) do
    slots[#slots + 1] = {
      rect = { x = shape.rect.x, y = shape.rect.y, width = shape.rect.width, height = shape.rect.height },
      iconCenter = { x = shape.center.x, y = shape.center.y },
    }
  end
  return {
    interactive = {
      pocketTabs = { rects = tabs },
      itemSlots = { slots = slots },
      pageIndicator = { rect = { x = 80, y = 168, width = 56, height = 16 }, textAt = { x = 0, y = 0 } },
      cancel = {
        rect = { x = 192, y = 168, width = 64, height = 24 },
        textRect = { x = 192, y = 168, width = 56, height = 16 },
      },
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
  local emptyCell = assert(resolved.interactiveHitTest(x, y, emptyState), "empty browse cells carry a pointer target")
  Assert.equal(emptyCell.kind, "item")
  Assert.equal(emptyCell.visibleIndex, 1)
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

function T.fractional_scale_hit_tests_cover_the_cancel_center_and_far_edge()
  local layoutManifest = manifest()
  local resolved = BagLayout.resolve({ topology = oneDisplay(960, 540, false), manifest = layoutManifest })
  Assert.equal(resolved.mode, "horizontal")
  local interactive = resolved.interactive
  Assert.isTrue(interactive.scale ~= math.floor(interactive.scale), "the wide composition uses a fractional scale")
  local cancel = layoutManifest.interactive.cancel.rect
  local function hostAt(logicalX, logicalY)
    return interactive.frame.x + logicalX * interactive.scale, interactive.frame.y + logicalY * interactive.scale
  end
  local state = browsing()
  local centerX, centerY = hostAt(cancel.x + cancel.width / 2, cancel.y + cancel.height / 2)
  local center = assert(resolved.interactiveHitTest(centerX, centerY, state), "the cancel center resolves")
  Assert.equal(center.kind, "cancel")
  local edgeX, edgeY = hostAt(cancel.x + cancel.width - 0.25, cancel.y + cancel.height - 0.25)
  local edge = assert(resolved.interactiveHitTest(edgeX, edgeY, state), "the cancel far edge resolves")
  Assert.equal(edge.kind, "cancel")
  local outsideX, outsideY = hostAt(cancel.x + cancel.width + 0.5, cancel.y + cancel.height / 2)
  Assert.isNil(resolved.interactiveHitTest(outsideX, outsideY, state), "points past the cancel edge carry no target")
end

function T.full_item_and_cancel_regions_are_interactive()
  local resolved = BagLayout.resolve({ topology = oneDisplay(512, 384, false), manifest = manifest() })
  Assert.equal(resolved.mode, "horizontal")
  local interactive = resolved.interactive
  local function hostAt(logicalX, logicalY)
    return interactive.frame.x + logicalX * interactive.scale, interactive.frame.y + logicalY * interactive.scale
  end
  local state = browsing()
  -- Points use the full source control geometry: the first cell's left edge
  -- outside the legacy text window, the second cell's right edge, a gap
  -- point that must not bleed, an empty cell, and the rightmost Cancel strip.
  local x, y = hostAt(8, 40)
  local edge = assert(resolved.interactiveHitTest(x, y, state), "the full first-cell region resolves")
  Assert.equal(edge.kind, "item")
  Assert.equal(edge.visibleIndex, 0)
  x, y = hostAt(250, 60)
  local right = assert(resolved.interactiveHitTest(x, y, state), "the full second-cell region resolves")
  Assert.equal(right.kind, "item")
  Assert.equal(right.visibleIndex, 1)
  x, y = hostAt(8, 160)
  Assert.isNil(resolved.interactiveHitTest(x, y, state), "gaps between control regions carry no target")
  local emptyState = browsing({ true, true, false, true, true, true })
  x, y = hostAt(40, 90)
  local emptyCell = assert(resolved.interactiveHitTest(x, y, emptyState), "the full region targets empty cells too")
  Assert.equal(emptyCell.kind, "item")
  Assert.equal(emptyCell.visibleIndex, 2)
  x, y = hostAt(250, 176)
  local cancel = assert(resolved.interactiveHitTest(x, y, state), "the full Cancel region resolves")
  Assert.equal(cancel.kind, "cancel")
  x, y = hostAt(48, 16)
  local tab = assert(resolved.interactiveHitTest(x, y, state), "tab targets are unchanged")
  Assert.equal(tab.kind, "pocket")
  Assert.equal(tab.pocket, "medicine")
end

function T.browse_hit_testing_targets_every_visible_cell_including_empties()
  local resolved = BagLayout.resolve({ topology = oneDisplay(512, 384, false), manifest = manifest() })
  local interactive = resolved.interactive
  local function hostAt(logicalX, logicalY)
    return interactive.frame.x + logicalX * interactive.scale, interactive.frame.y + logicalY * interactive.scale
  end
  local centers = { { 64, 53 }, { 192, 53 }, { 64, 96 }, { 192, 96 }, { 64, 136 }, { 192, 136 } }
  local state = browsing({ true, false, false, true, false, true })
  for index, center in ipairs(centers) do
    local x, y = hostAt(center[1], center[2])
    local hit = assert(resolved.interactiveHitTest(x, y, state), "every browse cell resolves a target")
    Assert.equal(hit.kind, "item", "an empty browse cell is still an item target")
    Assert.equal(fieldOf(hit, "visibleIndex"), index - 1)
  end
end

function T.move_target_selection_stays_occupied_only()
  local resolved = BagLayout.resolve({ topology = oneDisplay(512, 384, false), manifest = manifest() })
  local interactive = resolved.interactive
  local function hostAt(logicalX, logicalY)
    return interactive.frame.x + logicalX * interactive.scale, interactive.frame.y + logicalY * interactive.scale
  end
  local visibleSlots = {}
  for index = 1, 6 do
    visibleSlots[index] = { item = "ITEM_" .. index }
  end
  visibleSlots[2] = { empty = true, visibleIndex = 1 }
  local state = { state = "move_select", visibleSlots = visibleSlots }
  local x, y = hostAt(64, 53)
  local occupied = assert(resolved.interactiveHitTest(x, y, state), "an occupied move cell resolves")
  Assert.equal(occupied.kind, "item")
  Assert.equal(fieldOf(occupied, "visibleIndex"), 0)
  x, y = hostAt(192, 53)
  Assert.isNil(resolved.interactiveHitTest(x, y, state), "an empty cell never becomes a move destination")
end

return { tests = T }
