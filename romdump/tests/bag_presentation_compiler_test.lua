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
  Assert.equal(geometry.slots[1].rect.x, 32)
  Assert.equal(geometry.slots[1].rect.y, 40)
  Assert.equal(geometry.slots[1].iconCenter.x, 48)
  Assert.equal(geometry.slots[6].rect.x, 160)
  Assert.equal(geometry.slots[6].rect.y, 120)
  Assert.equal(geometry.slots[6].iconCenter.y, 136)
  Assert.equal(geometry.cursor.size, 16)
  Assert.equal(geometry.cursor.anchorY, 177)
  Assert.equal(geometry.pageIndicator.rect.x, 80)
  Assert.equal(geometry.cancel.x, 192)
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

function T.widgets_publish_the_audited_strip_placement_and_visibility()
  local widgets = BagPresentationCompiler.compileWidgets(BagSources)
  Assert.deepEqual(
    widgets.sourceStrip.placement,
    { x = 177, y = 14 },
    "the strip keeps its audited sprite-center anchor"
  )
  Assert.equal(widgets.sourceStrip.states.browsing, false, "the strip is hidden in normal browse")
end

function T.widget_placement_outside_the_pane_fails()
  local edited = { widgets = { sourceStrip = { placement = { x = 300, y = 14 }, states = { browsing = false } } } }
  local ok, err = pcall(BagPresentationCompiler.compileWidgets, edited)
  Assert.isFalse(ok, "a placement escaping the pane must fail")
  Assert.notNil(tostring(err):find("BAG_GEOMETRY_INVALID"), "the failure must carry the protocol code")
end

function T.widget_without_browse_visibility_fails()
  local edited = { widgets = { sourceStrip = { placement = { x = 177, y = 14 }, states = {} } } }
  local ok, err = pcall(BagPresentationCompiler.compileWidgets, edited)
  Assert.isFalse(ok, "a widget without browse visibility must fail")
  Assert.notNil(tostring(err):find("BAG_GEOMETRY_INVALID"), "the failure must carry the protocol code")
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

return { tests = T }
