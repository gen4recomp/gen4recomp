-- Pure geometry contract for the field-bag presentation: overlay tables
-- become canonical pane rectangles and pocket-indexed animation states with
-- no ROM bytes involved. Malformed source geometry (wrong tab/slot/state
-- counts, rectangles escaping the pane) fails with an attributed error.

local Assert = require("tests.support.Assert")
local BagPresentationCompiler = require("romdump.src.digest.ui.BagPresentationCompiler")
local BagSources = require("romdump.src.config.BagSources")

local T = {}

function T.geometry_preserves_the_audited_rectangles()
  local geometry = BagPresentationCompiler.compileGeometry(BagSources)
  Assert.equal(#geometry.tabs, 8)
  Assert.equal(geometry.tabs[1].x, 0)
  Assert.equal(geometry.tabs[8].x, 224)
  Assert.equal(#geometry.slots, 6)
  Assert.equal(geometry.slots[1].rect.x, 0)
  Assert.equal(geometry.slots[1].rect.y, 32)
  Assert.equal(geometry.slots[1].textRect.x, 32)
  Assert.equal(geometry.slots[1].textRect.y, 40)
  Assert.equal(geometry.slots[1].iconCenter.x, 48)
  Assert.equal(geometry.slots[6].rect.x, 128)
  Assert.equal(geometry.slots[6].rect.y, 118)
  Assert.equal(geometry.slots[6].iconCenter.y, 136)
  Assert.equal(geometry.cursor.size, 16)
  Assert.equal(geometry.cursor.anchorY, 177)
  Assert.equal(geometry.pageIndicator.rect.x, 80)
  Assert.equal(geometry.cancel.rect.x, 192)
  Assert.equal(geometry.cancel.textRect.width, 56)
  Assert.equal(geometry.descriptionFrame.y, 144)
  Assert.equal(#geometry.actionButtons, 4)
  Assert.equal(#geometry.quantityDigits, 3)
end

function T.states_name_one_pose_and_pattern_per_pocket()
  local states = BagPresentationCompiler.compileStates(BagSources)
  Assert.equal(#states, 8)
  Assert.equal(states[1].pocket, "items")
  Assert.equal(states[1].pose, "pocket.items.pose")
  Assert.equal(states[1].pattern, "pocket.items.pattern")
  Assert.equal(states[8].pocket, "key_items")
  local seen = {}
  for _, state in ipairs(states) do
    Assert.isNil(seen[state.pocket], "states must not repeat a pocket")
    seen[state.pocket] = true
  end
end

function T.wrong_tab_count_fails()
  local edited = {
    geometry = { tabs = { { x = 0, y = 0, width = 32, height = 32 } }, slots = BagSources.geometry.slots },
  }
  local ok, err = pcall(BagPresentationCompiler.compileGeometry, edited)
  Assert.isFalse(ok, "seven missing tabs must fail")
  Assert.notNil(tostring(err):find("BAG_GEOMETRY_INVALID"), "the failure must carry the protocol code")
end

function T.out_of_bounds_rectangles_fail()
  local edited = {
    geometry = {
      tabs = BagSources.geometry.tabs,
      slots = {
        { rect = { x = 200, y = 40, width = 88, height = 32 }, iconCenter = { x = 210, y = 50 } },
      },
    },
  }
  local ok, err = pcall(BagPresentationCompiler.compileGeometry, edited)
  Assert.isFalse(ok, "an overflowing slot must fail")
  Assert.notNil(tostring(err):find("BAG_GEOMETRY_INVALID"), "the failure must carry the protocol code")
end

function T.composed_state_layers_are_deterministic_and_follow_source_order()
  local module = BagPresentationCompiler
  local bottom = { width = 2, height = 1, pixels = string.char(10, 20, 30, 255, 10, 20, 30, 255) }
  local top = { width = 2, height = 1, pixels = string.char(40, 50, 60, 255, 0, 0, 0, 0) }
  local first = module.composeImages({ bottom, top }, "browse")
  local second = module.composeImages({ bottom, top }, "browse")
  Assert.equal(first.width, 2)
  Assert.equal(first.height, 1)
  Assert.equal(first.pixels, second.pixels, "composition must be deterministic")
  Assert.deepEqual({ string.byte(first.pixels, 1, 4) }, { 40, 50, 60, 255 }, "the upper source layer wins")
  Assert.deepEqual(
    { string.byte(first.pixels, 5, 8) },
    { 10, 20, 30, 255 },
    "transparent pixels preserve the lower layer"
  )
end

-- The audited NNS global material registers become source-independent
-- semantic colors: the DiffAmb/SpecEmi immediates from the bag setup carry
-- mid-gray diffuse/ambient/specular/emission instead of the white/zero
-- registers the runtime previously assumed.
function T.materials_normalize_the_audited_global_registers()
  local materials = BagPresentationCompiler.compileMaterials(BagSources)
  Assert.deepEqual(materials.diffuse, { r = 15, g = 15, b = 15 }, "diffuse keeps the audited 0x3DEF gray")
  Assert.deepEqual(materials.ambient, { r = 10, g = 10, b = 10 }, "ambient keeps the audited 0x294A gray")
  Assert.deepEqual(materials.specular, { r = 15, g = 15, b = 15 }, "specular keeps the audited 0x3DEF gray")
  Assert.deepEqual(materials.emission, { r = 15, g = 15, b = 15 }, "emission keeps the audited 0x3DEF gray")
end

function T.materials_without_a_register_fail()
  local edited = { presentation = { materials = { diffuse = 0x3DEF } } }
  local ok, err = pcall(BagPresentationCompiler.compileMaterials, edited)
  Assert.isFalse(ok, "a missing register must fail")
  Assert.notNil(tostring(err):find("BAG_GEOMETRY_INVALID"), "the failure must carry the protocol code")
end

-- The retail hero transform carries the audited source height; the compiled
-- runtime translation normalizes it once through the model-unit scale.
function T.hero_translation_uses_the_retail_source_height()
  local MapUnits = require("romdump.src.digest.map.MapUnits")
  local translation =
    assert(BagSources.presentation, "the source config carries a presentation record").transform.translation
  Assert.deepEqual(translation, { x = 0, y = -45, z = 0 }, "the hero source translation must match the retail vector")
  Assert.equal(
    translation.y / MapUnits.MODEL_UNITS_PER_TILE,
    -45 / 16,
    "the normalized runtime height follows the source fact"
  )
end

-- Item slots publish the full source touch rects alongside the narrower text
-- windows they contain; icon centers stay on the audited points and the
-- standard row anchors are explicit text-window-local points.
function T.slots_publish_full_touch_rects_with_separate_text_windows()
  local geometry = BagPresentationCompiler.compileGeometry(BagSources)
  local fullRects = {
    { x = 0, y = 32, width = 128, height = 42 },
    { x = 128, y = 32, width = 128, height = 42 },
    { x = 0, y = 74, width = 128, height = 44 },
    { x = 128, y = 74, width = 128, height = 44 },
    { x = 0, y = 118, width = 128, height = 36 },
    { x = 128, y = 118, width = 128, height = 36 },
  }
  local textRects = {
    { x = 32, y = 40, width = 88, height = 32 },
    { x = 160, y = 40, width = 88, height = 32 },
    { x = 32, y = 80, width = 88, height = 32 },
    { x = 160, y = 80, width = 88, height = 32 },
    { x = 32, y = 120, width = 88, height = 32 },
    { x = 160, y = 120, width = 88, height = 32 },
  }
  local iconCenters = {
    { x = 48, y = 56 },
    { x = 176, y = 56 },
    { x = 48, y = 96 },
    { x = 176, y = 96 },
    { x = 48, y = 136 },
    { x = 176, y = 136 },
  }
  Assert.equal(#geometry.slots, 6)
  for index = 1, 6 do
    local slot = assert(geometry.slots[index], "slot " .. index .. " must be published")
    Assert.deepEqual(slot.rect, fullRects[index], "slot " .. index .. " carries the full source touch rect")
    Assert.deepEqual(slot.textRect, textRects[index], "slot " .. index .. " carries the separate text window")
    Assert.deepEqual(slot.iconCenter, iconCenters[index], "slot " .. index .. " keeps the audited icon center")
    Assert.deepEqual(slot.nameAt, { x = 0, y = 0 }, "slot " .. index .. " names the standard name anchor")
    Assert.deepEqual(slot.quantityAt, { x = 48, y = 16 }, "slot " .. index .. " names the standard quantity anchor")
    Assert.isTrue(
      slot.textRect.x >= slot.rect.x
        and slot.textRect.y >= slot.rect.y
        and slot.textRect.x + slot.textRect.width <= slot.rect.x + slot.rect.width
        and slot.textRect.y + slot.textRect.height <= slot.rect.y + slot.rect.height,
      "slot " .. index .. " text window must be contained in the full touch rect"
    )
  end
end

-- Cancel publishes the full button rect alongside its narrower text window.
function T.cancel_publishes_the_full_button_rect_with_its_text_window()
  local geometry = BagPresentationCompiler.compileGeometry(BagSources)
  Assert.deepEqual(
    geometry.cancel.rect,
    { x = 192, y = 168, width = 64, height = 24 },
    "cancel carries the full source button rect"
  )
  Assert.deepEqual(
    geometry.cancel.textRect,
    { x = 192, y = 168, width = 56, height = 16 },
    "cancel carries the separate text window"
  )
end

return { tests = T }
