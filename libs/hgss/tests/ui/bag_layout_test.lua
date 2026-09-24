-- Canonical logical geometry for the field bag: the generated tab, slot,
-- cancel, and fallback rectangles with one logical hit test. Covers the
-- hero-visibility contract, canonical fallback geometry, manifest
-- validation, and the full hit precedence shared with the controller:
-- overlay fallback, action buttons, toss/move modal targets, tabs, cells,
-- and cancel. Host composition lives in the leaf interface; this suite
-- never builds a topology. Pure geometry; no love, no GPU.

local Assert = require("tests.support.Assert")
local BagLayout = require("libs.hgss.src.ui.BagLayout")

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
        descriptionFallback = {
          frame = { x = 0, y = 144, width = 256, height = 48 },
          textRect = { x = 20, y = 144, width = 236, height = 48 },
        },
        actionMenu = {
          slots = {
            { hitRect = { x = 8, y = 136, width = 80, height = 16 } },
            { hitRect = { x = 104, y = 136, width = 80, height = 16 } },
            { hitRect = { x = 8, y = 168, width = 80, height = 16 } },
            { hitRect = { x = 104, y = 168, width = 80, height = 16 } },
          },
        },
        quantity = {
          controls = {
            { delta = 100, role = "increment", hitRect = { x = 0, y = 128, width = 32, height = 32 } },
            { delta = 10, role = "increment", hitRect = { x = 32, y = 128, width = 32, height = 32 } },
            { delta = 1, role = "increment", hitRect = { x = 64, y = 128, width = 32, height = 32 } },
            { delta = -100, role = "decrement", hitRect = { x = 0, y = 160, width = 32, height = 32 } },
            { delta = -10, role = "decrement", hitRect = { x = 32, y = 160, width = 32, height = 32 } },
            { delta = -1, role = "decrement", hitRect = { x = 64, y = 160, width = 32, height = 32 } },
          },
          pressTicks = 2,
          cancelHitRect = { x = 178, y = 168, width = 78, height = 24 },
          confirm = { hitRect = { x = 112, y = 160, width = 64, height = 32 } },
        },
      },
    },
  }
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

function T.visible_hero_composition_carries_no_fallback()
  local resolved = BagLayout.resolve({ manifest = manifest(), heroVisible = true })
  Assert.equal(resolved.heroVisible, true, "the paired composition shows its hero pane")
  Assert.isNil(resolved.descriptionFallback, "two-pane compositions need no description fallback")
  Assert.equal(type(resolved.hitTest), "function", "the composition carries its logical hit test")
end

function T.hidden_hero_composition_carries_the_canonical_fallback()
  local resolved = BagLayout.resolve({ manifest = manifest(), heroVisible = false })
  Assert.equal(resolved.heroVisible, false, "the lower-only composition hides its hero pane")
  Assert.deepEqual(
    resolved.descriptionFallback,
    { x = 0, y = 144, width = 256, height = 48 },
    "the fallback frame matches the canonical overlay geometry"
  )
  Assert.equal(type(resolved.hitTest), "function", "the composition carries its logical hit test")
end

function T.hit_testing_resolves_tabs_slots_and_cancel_through_logical_coordinates()
  local resolved = BagLayout.resolve({ manifest = manifest(), heroVisible = true })
  local state = browsing()
  local tab = assert(resolved.hitTest(48, 16, state), "a tab hit resolves")
  Assert.equal(tab.kind, "pocket")
  Assert.equal(tab.pocket, "medicine")
  local cell = assert(resolved.hitTest(76, 56, state), "a slot hit resolves")
  Assert.equal(cell.kind, "item")
  Assert.equal(cell.visibleIndex, 0)
  local cancel = assert(resolved.hitTest(220, 176, state), "a cancel hit resolves")
  Assert.equal(cancel.kind, "cancel")
  Assert.isNil(resolved.hitTest(-4, -4, state), "points outside the canonical surface carry no target")
  local emptyState = browsing({ true, false, true, true, true, true })
  local emptyCell = assert(resolved.hitTest(204, 56, emptyState), "empty browse cells carry a pointer target")
  Assert.equal(emptyCell.kind, "item")
  Assert.equal(emptyCell.visibleIndex, 1)
end

function T.overlay_open_routes_fallback_taps_to_description()
  local resolved = BagLayout.resolve({ manifest = manifest(), heroVisible = false })
  local state = browsing()
  state.state = "description_overlay"
  local target = assert(resolved.hitTest(200, 150, state), "a fallback tap resolves while open")
  Assert.equal(target.kind, "description")
  local plain = browsing()
  local tab = assert(resolved.hitTest(200, 150, plain), "the same point still hits content when closed")
  Assert.isTrue(tab.kind == "item" or tab.kind == "cancel", "closed taps resolve to pane content")
end

function T.resolve_rejects_a_missing_manifest()
  -- The missing manifest is the invalid input under test: build the spec
  -- through an open record so the call stays a runtime rejection probe
  -- instead of a static missing-fields diagnostic.
  ---@type table<string, any>
  local spec = { heroVisible = true }
  Assert.throws(function()
    ---@diagnostic disable-next-line: param-type-mismatch
    BagLayout.resolve(spec)
  end, "hit testing without canonical geometry is a composition error")
end

function T.resolve_rejects_a_missing_hero_visibility()
  ---@type table<string, any>
  local spec = { manifest = manifest() }
  Assert.throws(function()
    ---@diagnostic disable-next-line: param-type-mismatch
    BagLayout.resolve(spec)
  end, "geometry without its hero visibility is a composition error")
end

function T.nested_states_offer_responsive_controls_from_the_generated_buttons()
  local resolved = BagLayout.resolve({ manifest = manifest(), heroVisible = true })
  local function stateFor(state)
    local visibleSlots = {}
    for index = 1, 6 do
      visibleSlots[index] = { item = "ITEM_" .. index }
    end
    return { state = state, visibleSlots = visibleSlots }
  end
  local decrement = assert(resolved.hitTest(16, 176, stateFor("toss_quantity")), "the -100 control decrements")
  Assert.equal(decrement.kind, "quantity_delta")
  Assert.equal(fieldOf(decrement, "delta"), -100)
  local increment = assert(resolved.hitTest(80, 144, stateFor("toss_quantity")), "the +1 control increments")
  Assert.equal(increment.kind, "quantity_delta")
  Assert.equal(fieldOf(increment, "delta"), 1)
  local quantityConfirm =
    assert(resolved.hitTest(144, 176, stateFor("toss_quantity")), "the quantity confirm control confirms")
  Assert.equal(quantityConfirm.kind, "confirm")
  -- Toss confirmation is a modal Yes/No prompt owned outside the Bag
  -- layout: neither the retired action-slot coordinate nor the normal
  -- cancel control resolves a Toss choice, and the quantity-picker confirm
  -- rectangle stays out of this state.
  Assert.isNil(
    resolved.hitTest(48, 176, stateFor("toss_confirm")),
    "the retired slot coordinate never confirms the toss"
  )
  Assert.isNil(
    resolved.hitTest(144, 176, stateFor("toss_confirm")),
    "the quantity-only confirm region never confirms the toss"
  )
  Assert.isNil(resolved.hitTest(220, 176, stateFor("toss_confirm")), "the normal cancel control never cancels the toss")
  Assert.isNil(
    resolved.hitTest(185, 176, stateFor("toss_confirm")),
    "the quantity-only cancel extension never cancels the toss"
  )
  Assert.isNil(resolved.hitTest(224, 64, stateFor("toss_confirm")), "the prompt YES row carries no Bag-owned target")
  Assert.isNil(resolved.hitTest(224, 96, stateFor("toss_confirm")), "the prompt NO row carries no Bag-owned target")
  Assert.isNil(resolved.hitTest(224, 64, stateFor("toss_ack")), "the acknowledgement state carries no Bag-owned target")
  local cell = assert(resolved.hitTest(76, 56, stateFor("move_select")), "move keeps its cell targets")
  Assert.equal(cell.kind, "item")
  Assert.equal(cell.visibleIndex, 0)
  local moveConfirm = assert(resolved.hitTest(48, 176, stateFor("move_select")), "move confirms through its own button")
  Assert.equal(moveConfirm.kind, "confirm")
end

function T.physical_action_and_quantity_targets_resolve_through_generated_geometry()
  local layoutManifest = manifest()
  layoutManifest.interactive.overlays.actionMenu.slots = {
    {
      center = { x = 48, y = 144 },
      textRect = { x = 32, y = 140, width = 32, height = 16 },
      hitRect = { x = 0, y = 128, width = 96, height = 32 },
    },
    {
      center = { x = 144, y = 144 },
      textRect = { x = 128, y = 140, width = 32, height = 16 },
      hitRect = { x = 96, y = 128, width = 96, height = 32 },
    },
    {
      center = { x = 48, y = 176 },
      textRect = { x = 32, y = 172, width = 32, height = 16 },
      hitRect = { x = 0, y = 160, width = 96, height = 32 },
    },
    {
      center = { x = 144, y = 176 },
      textRect = { x = 128, y = 172, width = 32, height = 16 },
      hitRect = { x = 96, y = 160, width = 96, height = 32 },
    },
  }
  layoutManifest.interactive.overlays.quantity = {
    pressTicks = 2,
    digits = {
      { x = 128, y = 112, width = 16, height = 24 },
      { x = 160, y = 112, width = 16, height = 24 },
      { x = 192, y = 112, width = 16, height = 24 },
    },
    controls = {
      {
        delta = 100,
        role = "increment",
        center = { x = 32, y = 144 },
        hitRect = { x = 0, y = 128, width = 32, height = 32 },
      },
      {
        delta = 10,
        role = "increment",
        center = { x = 64, y = 144 },
        hitRect = { x = 32, y = 128, width = 32, height = 32 },
      },
      {
        delta = 1,
        role = "increment",
        center = { x = 96, y = 144 },
        hitRect = { x = 64, y = 128, width = 32, height = 32 },
      },
      {
        delta = -100,
        role = "decrement",
        center = { x = 32, y = 176 },
        hitRect = { x = 0, y = 160, width = 32, height = 32 },
      },
      {
        delta = -10,
        role = "decrement",
        center = { x = 64, y = 176 },
        hitRect = { x = 32, y = 160, width = 32, height = 32 },
      },
      {
        delta = -1,
        role = "decrement",
        center = { x = 96, y = 176 },
        hitRect = { x = 64, y = 160, width = 32, height = 32 },
      },
    },
    cancelHitRect = { x = 178, y = 168, width = 78, height = 24 },
    confirm = {
      visual = { image = "bag/confirm.png", width = 64, height = 24 },
      center = { x = 144, y = 176 },
      hitRect = { x = 112, y = 160, width = 64, height = 32 },
    },
  }
  local resolved = BagLayout.resolve({ manifest = layoutManifest, heroVisible = true })
  local action = assert(resolved.hitTest(120, 144, { state = "action_menu", visibleSlots = {} }))
  Assert.equal(action.kind, "action")
  Assert.equal(action.actionNode, 1, "action hit identity is the physical node")
  local quantity = assert(resolved.hitTest(16, 176, { state = "toss_quantity", visibleSlots = {} }))
  Assert.equal(quantity.kind, "quantity_delta")
  Assert.equal(quantity.quantityControlIndex, 3)
  Assert.equal(quantity.delta, -100)
  local cancel = assert(resolved.hitTest(200, 176, { state = "toss_quantity", visibleSlots = {} }))
  Assert.equal(cancel.kind, "cancel", "quantity Cancel uses its dedicated hit rectangle")
end

function T.toss_states_hide_the_browsing_targets_underneath()
  local resolved = BagLayout.resolve({ manifest = manifest(), heroVisible = true })
  for _, state in ipairs({ "toss_quantity", "toss_confirm", "toss_ack" }) do
    local visibleSlots = {}
    for index = 1, 6 do
      visibleSlots[index] = { item = "ITEM_" .. index }
    end
    local modal = { state = state, visibleSlots = visibleSlots }
    Assert.isNil(resolved.hitTest(48, 16, modal), state .. " exposes no pocket target")
    Assert.isNil(resolved.hitTest(76, 56, modal), state .. " exposes no item target underneath")
    if state == "toss_quantity" then
      local cancel = assert(resolved.hitTest(220, 176, modal), state .. " keeps its cancel target")
      Assert.equal(cancel.kind, "cancel")
    else
      Assert.isNil(resolved.hitTest(220, 176, modal), state .. " exposes no Bag-owned cancel target")
      Assert.isNil(resolved.hitTest(48, 176, modal), state .. " exposes no Bag-owned confirm target")
    end
  end
end

function T.cancel_region_center_and_edges_resolve()
  local layoutManifest = manifest()
  local resolved = BagLayout.resolve({ manifest = layoutManifest, heroVisible = true })
  local cancel = layoutManifest.interactive.cancel.rect
  local state = browsing()
  local center = assert(
    resolved.hitTest(cancel.x + cancel.width / 2, cancel.y + cancel.height / 2, state),
    "the cancel center resolves"
  )
  Assert.equal(center.kind, "cancel")
  local edge = assert(
    resolved.hitTest(cancel.x + cancel.width - 0.25, cancel.y + cancel.height - 0.25, state),
    "the cancel far edge resolves"
  )
  Assert.equal(edge.kind, "cancel")
  Assert.isNil(
    resolved.hitTest(cancel.x + cancel.width + 0.5, cancel.y + cancel.height / 2, state),
    "points past the cancel edge carry no target"
  )
end

function T.full_item_and_cancel_regions_are_interactive()
  local resolved = BagLayout.resolve({ manifest = manifest(), heroVisible = true })
  local state = browsing()
  -- Points use the full source control geometry: the first cell's left edge
  -- outside the legacy text window, the second cell's right edge, a gap
  -- point that must not bleed, an empty cell, and the rightmost Cancel strip.
  local edge = assert(resolved.hitTest(8, 40, state), "the full first-cell region resolves")
  Assert.equal(edge.kind, "item")
  Assert.equal(edge.visibleIndex, 0)
  local right = assert(resolved.hitTest(250, 60, state), "the full second-cell region resolves")
  Assert.equal(right.kind, "item")
  Assert.equal(right.visibleIndex, 1)
  Assert.isNil(resolved.hitTest(8, 160, state), "gaps between control regions carry no target")
  local emptyState = browsing({ true, true, false, true, true, true })
  local emptyCell = assert(resolved.hitTest(40, 90, emptyState), "the full region targets empty cells too")
  Assert.equal(emptyCell.kind, "item")
  Assert.equal(emptyCell.visibleIndex, 2)
  local cancel = assert(resolved.hitTest(250, 176, state), "the full Cancel region resolves")
  Assert.equal(cancel.kind, "cancel")
  local tab = assert(resolved.hitTest(48, 16, state), "tab targets are unchanged")
  Assert.equal(tab.kind, "pocket")
  Assert.equal(tab.pocket, "medicine")
end

function T.browse_hit_testing_targets_every_visible_cell_including_empties()
  local resolved = BagLayout.resolve({ manifest = manifest(), heroVisible = true })
  local centers = { { 64, 53 }, { 192, 53 }, { 64, 96 }, { 192, 96 }, { 64, 136 }, { 192, 136 } }
  local state = browsing({ true, false, false, true, false, true })
  for index, center in ipairs(centers) do
    local hit = assert(resolved.hitTest(center[1], center[2], state), "every browse cell resolves a target")
    Assert.equal(hit.kind, "item", "an empty browse cell is still an item target")
    Assert.equal(fieldOf(hit, "visibleIndex"), index - 1)
  end
end

function T.move_target_selection_stays_occupied_only()
  local resolved = BagLayout.resolve({ manifest = manifest(), heroVisible = true })
  local visibleSlots = {}
  for index = 1, 6 do
    visibleSlots[index] = { item = "ITEM_" .. index }
  end
  visibleSlots[2] = { empty = true, visibleIndex = 1 }
  local state = { state = "move_select", visibleSlots = visibleSlots }
  local occupied = assert(resolved.hitTest(64, 53, state), "an occupied move cell resolves")
  Assert.equal(occupied.kind, "item")
  Assert.equal(fieldOf(occupied, "visibleIndex"), 0)
  Assert.isNil(resolved.hitTest(192, 53, state), "an empty cell never becomes a move destination")
end

-- The canonical lower-only resolution carries the generated fallback text
-- rectangle alongside the fallback frame so the compact description can
-- reuse source geometry instead of inventing text offsets.
local function manifestWithFallbackText()
  local layoutManifest = manifest()
  layoutManifest.interactive.overlays.descriptionFallback.textRect = { x = 20, y = 144, width = 236, height = 48 }
  return layoutManifest
end

function T.hidden_hero_composition_carries_the_generated_fallback_text_rectangle()
  local resolved = BagLayout.resolve({ manifest = manifestWithFallbackText(), heroVisible = false })
  Assert.deepEqual(
    resolved.descriptionTextRect,
    { x = 20, y = 144, width = 236, height = 48 },
    "the resolved text rectangle matches the generated fallback geometry"
  )
  Assert.deepEqual(
    resolved.descriptionFallback,
    { x = 0, y = 144, width = 256, height = 48 },
    "the fallback frame stays the canonical overlay geometry"
  )
end

function T.resolve_rejects_a_fallback_without_its_generated_text_rectangle()
  local layoutManifest = manifest()
  layoutManifest.interactive.overlays.descriptionFallback.textRect = nil
  Assert.throws(function()
    BagLayout.resolve({ manifest = layoutManifest, heroVisible = false })
  end, "a lower-only composition without generated fallback text is a composition error")
end

return { tests = T }
