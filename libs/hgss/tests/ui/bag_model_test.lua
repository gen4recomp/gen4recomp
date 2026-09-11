-- View projection for the field bag: one fresh immutable record per build
-- over the live inventory service and the runtime cursor. Covers the exact
-- record shape, empty pockets, single and multi-page pockets, per-pocket
-- cursor memory, defensive reconciliation of stale cursor offsets, and
-- registration-slot identity. Synthetic catalog only; no love, no GPU.

local Assert = require("tests.support.Assert")
local BagCursor = require("libs.hgss.src.items.BagCursor")
local BagModel = require("libs.hgss.src.ui.BagModel")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local ItemFixture = require("libs.items.tests.item_fixture")

local T = {}

local MODEL_KEYS = {
  "revision",
  "pocket",
  "pocketNativeId",
  "pocketName",
  "pockets",
  "slots",
  "selectedAbsoluteIndex",
  "visibleStart",
  "visibleSlots",
  "page",
  "selected",
}

local SLOT_KEYS = {
  "item",
  "nativeId",
  "name",
  "quantity",
  "description",
  "icon",
  "registrationSlot",
}

local function service()
  return HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
end

local function keySet(record)
  local keys = {}
  for key in pairs(record) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

local function stocked()
  local bag = service()
  Assert.isTrue(bag:add("POTION", 5))
  Assert.isTrue(bag:add("POKE_BALL", 3))
  Assert.isTrue(bag:add("GREAT_BALL", 2))
  return bag
end

function T.build_returns_the_exact_locked_record_shape()
  local bag = stocked()
  local cursor = BagCursor.new()
  cursor:setPocket("balls")
  local view = BagModel.build(bag, cursor)
  local expected = {}
  for _, key in ipairs(MODEL_KEYS) do
    expected[#expected + 1] = key
  end
  table.sort(expected)
  Assert.deepEqual(keySet(view), expected, "the model carries exactly the browse record fields")
  Assert.equal(view.revision, bag:revision())
  Assert.equal(view.pocket, "balls")
  Assert.equal(view.pocketNativeId, 2)
  Assert.equal(view.pocketName, "Balls")
  Assert.equal(#view.pockets, 8, "all eight pockets ride every view")
  Assert.equal(view.pockets[1].pocket, "items", "tabs stay in source pocket order")
  Assert.equal(view.pockets[8].pocket, "key_items")
  for _, slot in ipairs(view.slots) do
    Assert.isNil(slot.registered, "the projection carries no boolean registration fact")
    local expectedSlotKeys = {}
    for _, key in ipairs(SLOT_KEYS) do
      if key ~= "registrationSlot" or slot.registrationSlot ~= nil then
        expectedSlotKeys[#expectedSlotKeys + 1] = key
      end
    end
    table.sort(expectedSlotKeys)
    Assert.deepEqual(keySet(slot), expectedSlotKeys, "slots carry exactly the display fields")
  end
end

function T.slots_join_catalog_display_and_service_quantities()
  local bag = stocked()
  local cursor = BagCursor.new()
  cursor:setPocket("medicine")
  local view = BagModel.build(bag, cursor)
  Assert.equal(#view.slots, 1)
  local slot = view.slots[1]
  Assert.equal(slot.item, "POTION")
  Assert.equal(slot.nativeId, 17)
  Assert.equal(slot.name, "Potion")
  Assert.equal(slot.quantity, 5)
  Assert.equal(slot.description, "Potion description")
  Assert.equal(slot.icon, "POTION")
  Assert.isNil(slot.registrationSlot, "an unregistered item projects no slot")
  Assert.isNil(slot.registered, "the projection carries no boolean registration fact")
  Assert.equal(view.selectedAbsoluteIndex, 0)
  Assert.equal(view.visibleStart, 0)
  Assert.equal(#view.visibleSlots, 6, "the visible grid always carries six cells")
  Assert.equal(view.visibleSlots[1].item, "POTION")
  Assert.isTrue(view.visibleSlots[2].empty, "cells past the last item stay empty")
  Assert.deepEqual(view.page, { current = 1, count = 1 })
  Assert.equal(view.selected.item, "POTION")
  Assert.equal(view.selected.quantity, 5)
end

function T.empty_pockets_select_nothing_but_keep_navigable_cells()
  local bag = stocked()
  local cursor = BagCursor.new()
  cursor:setPocket("items")
  local view = BagModel.build(bag, cursor)
  Assert.equal(#view.slots, 0)
  Assert.isNil(view.selected, "an empty pocket selects no item")
  Assert.equal(view.selectedAbsoluteIndex, 0, "an empty pocket rests on its first cell")
  Assert.equal(#view.visibleSlots, 6)
  for index = 1, 6 do
    Assert.isTrue(view.visibleSlots[index].empty, "every cell of an empty pocket is empty")
  end
  Assert.deepEqual(view.page, { current = 1, count = 1 })
end

function T.multi_page_pockets_window_six_cells_and_derive_the_page()
  local bag = service()
  for _, nativeId in ipairs({ 6, 12, 18, 24, 30, 36, 42, 48 }) do
    Assert.isTrue(bag:add("ITEM_" .. nativeId, 1), "setup stock must enter the items pocket")
  end
  Assert.equal(bag:pocketOf("ITEM_6"), "items")
  local cursor = BagCursor.new()
  cursor:setPocket("items")
  cursor:setPosition("items", 6)
  cursor:setScroll("items", 2)
  local view = BagModel.build(bag, cursor)
  Assert.equal(#view.slots, 8)
  Assert.equal(view.visibleStart, 2)
  Assert.equal(#view.visibleSlots, 6)
  Assert.equal(view.visibleSlots[1].item, "ITEM_18", "the window starts at the scroll offset")
  Assert.equal(view.selectedAbsoluteIndex, 6)
  Assert.equal(view.selected.item, "ITEM_42")
  Assert.deepEqual(view.page, { current = 2, count = 2 }, "the page derives from the selection")
end

function T.stale_cursor_offsets_reconcile_to_the_nearest_valid_cell()
  local bag = stocked()
  local cursor = BagCursor.new()
  cursor:setPocket("balls")
  cursor:setPosition("balls", 9)
  cursor:setScroll("balls", 9)
  local view = BagModel.build(bag, cursor)
  Assert.equal(view.selectedAbsoluteIndex, 1, "a stale position clamps to the last item")
  Assert.equal(view.selected.item, "GREAT_BALL")
  Assert.equal(view.visibleStart, 0, "a stale scroll clamps into the reachable window")
  Assert.equal(cursor:position("balls"), 9, "the model never mutates the borrowed cursor")
end

function T.single_registration_projects_the_first_slot()
  local bag = service()
  Assert.isTrue(bag:add("BICYCLE", 1))
  Assert.equal(bag:tryRegister("BICYCLE"), "slot1")
  local cursor = BagCursor.new()
  cursor:setPocket("key_items")
  local view = BagModel.build(bag, cursor)
  Assert.equal(#view.slots, 1)
  Assert.equal(view.slots[1].registrationSlot, 1, "a registered item projects the first slot")
  Assert.equal(view.selected.registrationSlot, 1)
  Assert.isNil(view.slots[1].registered, "the projection carries no boolean registration fact")
end

function T.two_registered_key_items_project_distinct_slot_numbers()
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  local root = ItemFixture.buildAssetRoot()
  root.items.ITEM_5.selectable = true
  local catalog = ItemCatalog.new(root)
  local bag = HgssBagService.new({ catalog = catalog })
  Assert.isTrue(bag:add("BICYCLE", 1))
  Assert.isTrue(bag:add("ITEM_5", 1))
  Assert.isTrue(bag:add("POTION", 5))
  Assert.equal(bag:tryRegister("BICYCLE"), "slot1")
  Assert.equal(bag:tryRegister("ITEM_5"), "slot2")
  local cursor = BagCursor.new()
  cursor:setPocket("key_items")
  local view = BagModel.build(bag, cursor)
  Assert.equal(#view.slots, 2)
  local byItem = {}
  for _, slot in ipairs(view.slots) do
    byItem[slot.item] = slot
  end
  Assert.equal(byItem.BICYCLE.registrationSlot, 1, "the first registration projects slot one")
  Assert.equal(byItem.ITEM_5.registrationSlot, 2, "the second registration projects slot two")
  Assert.isNil(byItem.BICYCLE.registered, "the lossy boolean leaves the projection")
  Assert.isNil(byItem.ITEM_5.registered, "the lossy boolean leaves the projection")
  cursor:setPocket("medicine")
  local medicine = BagModel.build(bag, cursor)
  Assert.equal(#medicine.slots, 1)
  Assert.isNil(medicine.slots[1].registrationSlot, "unrelated items project no slot")
  Assert.isNil(medicine.slots[1].registered, "the lossy boolean leaves unrelated slots")
end

function T.registration_compaction_and_final_removal_refresh_slot_numbers()
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  local root = ItemFixture.buildAssetRoot()
  root.items.ITEM_5.selectable = true
  local catalog = ItemCatalog.new(root)
  local bag = HgssBagService.new({ catalog = catalog })
  Assert.isTrue(bag:add("BICYCLE", 1))
  Assert.isTrue(bag:add("ITEM_5", 1))
  Assert.equal(bag:tryRegister("BICYCLE"), "slot1")
  Assert.equal(bag:tryRegister("ITEM_5"), "slot2")
  local cursor = BagCursor.new()
  cursor:setPocket("key_items")
  Assert.isTrue(bag:unregister("BICYCLE"), "setup releases the first slot")
  local shifted = BagModel.build(bag, cursor)
  local byItem = {}
  for _, slot in ipairs(shifted.slots) do
    byItem[slot.item] = slot
  end
  Assert.isNil(byItem.BICYCLE.registrationSlot, "an unregistered item projects no slot")
  Assert.equal(byItem.ITEM_5.registrationSlot, 1, "the surviving registration compacts forward")
  Assert.isTrue(bag:take("ITEM_5", 1), "setup removes the final copy")
  local cleared = BagModel.build(bag, cursor)
  Assert.equal(#cleared.slots, 1)
  Assert.isNil(cleared.slots[1].registrationSlot, "removing the final copy clears the slot")
  Assert.isNil(cleared.slots[1].registered, "the lossy boolean stays absent after removal")
end

function T.builds_return_fresh_tables()
  local bag = stocked()
  local cursor = BagCursor.new()
  cursor:setPocket("balls")
  local first = BagModel.build(bag, cursor)
  first.slots[1].quantity = -1
  first.visibleSlots[1].quantity = -1
  local second = BagModel.build(bag, cursor)
  Assert.equal(second.slots[1].quantity, 3, "a later build never observes an earlier mutation")
  Assert.equal(second.visibleSlots[1].quantity, 3)
end

return { tests = T }
