-- Producer-side bag presentation source inventory contract: the bag
-- compilers resolve every archive/member selection, geometry constant, and
-- hero presentation fact through BagSources. Pure data and pure functions;
-- no I/O and no runtime imports.

local Assert = require("tests.support.Assert")

local T = {}

local function sources()
  return require("romdump.src.config.BagSources")
end

function T.provenance_pins_the_decomp_commit()
  local BagSources = sources()
  Assert.equal(BagSources.provenance.repo, "pret/pokeheartgold")
  Assert.equal(BagSources.provenance.commit, "0985e8718df4f25e64d6507d89c0c97c0d288981")
  Assert.isTrue(#BagSources.provenance.sources > 0, "provenance must name its source files")
end

function T.bag_archive_resolves_through_the_semantic_alias()
  local BagSources = sources()
  Assert.equal(BagSources.archive.alias, "bag_ui")
  Assert.equal(BagSources.archive.symbol, "NARC_a_0_1_5")
end

function T.hero_selection_preserves_gender_with_pocket_indexed_states()
  local BagSources = sources()
  Assert.equal(BagSources.hero.male.model, 55)
  Assert.equal(BagSources.hero.female.model, 74)
  Assert.equal(BagSources.hero.male.patternBase, 57)
  Assert.equal(BagSources.hero.female.patternBase, 76)
  Assert.equal(BagSources.hero.male.jointBase, 65)
  Assert.equal(BagSources.hero.female.jointBase, 84)
  Assert.equal(BagSources.hero.male.material, 73)
  Assert.equal(BagSources.hero.female.material, 92)
  Assert.equal(#BagSources.hero.states, 8)
  local expected = { "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }
  for index, pocket in ipairs(expected) do
    Assert.equal(BagSources.hero.states[index].pocket, pocket, "state " .. index .. " selects its pocket")
    Assert.equal(BagSources.hero.states[index].slot, index - 1, "state " .. index .. " is pocket-indexed")
  end
end

function T.two_dimensional_roles_cover_the_audited_members()
  local BagSources = sources()
  local screens = BagSources.screens
  Assert.equal(screens.upperBase, 54)
  Assert.equal(screens.upperAlternate, 9)
  Assert.equal(screens.upperBackdropMale, 94)
  Assert.equal(screens.upperBackdropFemale, 93)
  Assert.equal(screens.listSlots, 43)
  Assert.equal(screens.listWash, 39)
  Assert.equal(screens.actionSlots, 44)
  Assert.equal(screens.actionWash, 42)
  Assert.equal(screens.confirmation, 45)
  Assert.equal(screens.quantity, 52)
  Assert.equal(screens.quantityAlt, 53)
  Assert.equal(BagSources.chars.upper, 7)
  Assert.equal(BagSources.chars.lower, 46)
  Assert.equal(BagSources.chars.registrationMarker, 37)
  Assert.equal(BagSources.sprites.strip.char, 26)
  Assert.equal(BagSources.sprites.strip.cell, 25)
  Assert.equal(BagSources.sprites.cursor.char, 6)
  Assert.equal(BagSources.sprites.cursor.cell, 5)
  Assert.equal(BagSources.sprites.tabs.char, 51)
  Assert.equal(BagSources.sprites.tabs.cell, 49)
end

function T.canonical_geometry_covers_tabs_slots_and_affordances()
  local BagSources = sources()
  local geometry = BagSources.geometry
  Assert.equal(#geometry.tabs, 8)
  for index, tab in ipairs(geometry.tabs) do
    Assert.equal(tab.x, (index - 1) * 32, "tab " .. index .. " tiles the strip row")
    Assert.equal(tab.y, 0)
    Assert.equal(tab.width, 32)
    Assert.equal(tab.height, 32)
  end
  Assert.equal(#geometry.slots, 6)
  local seen = {}
  for _, slot in ipairs(geometry.slots) do
    local cell = slot.rect
    Assert.equal(cell.width, 88)
    Assert.equal(cell.height, 32)
    Assert.isTrue(cell.x == 32 or cell.x == 160, "slots sit in two columns")
    Assert.isTrue(cell.y == 40 or cell.y == 80 or cell.y == 120, "slots sit in three rows")
    local key = cell.x .. "," .. cell.y
    Assert.isNil(seen[key], "slots must not overlap")
    seen[key] = true
    Assert.isTrue(slot.iconCenter.x >= cell.x and slot.iconCenter.x <= cell.x + cell.width)
    Assert.isTrue(slot.iconCenter.y >= cell.y and slot.iconCenter.y <= cell.y + cell.height)
  end
  for _, name in ipairs({
    "cursorAnchor",
    "countReadout",
    "cancel",
    "descriptionFrame",
    "descriptionText",
    "actionButtons",
    "quantityDigits",
  }) do
    Assert.notNil(geometry[name], "geometry must carry " .. name)
  end
  Assert.equal(#geometry.actionButtons, 4)
  Assert.equal(#geometry.quantityDigits, 3)
  local function fits(rect, what)
    Assert.isTrue(rect.x + rect.width <= 256 and rect.y + rect.height <= 192, what .. " must fit the pane")
  end
  fits(geometry.countReadout.rect, "count readout")
  fits(geometry.cancel, "cancel")
  fits(geometry.descriptionFrame, "description frame")
  fits(geometry.descriptionText, "description text")
  for _, button in ipairs(geometry.actionButtons) do
    fits(button, "action button")
  end
  for _, digit in ipairs(geometry.quantityDigits) do
    fits(digit, "quantity digit")
  end
end

function T.presentation_facts_are_finite_source_independent_values()
  local BagSources = sources()
  local camera = BagSources.presentation.camera
  Assert.isTrue(camera.distance > 0, "camera distance must be positive")
  Assert.isTrue(camera.clipFar > camera.clipNear, "camera clipping range must be ordered")
  for _, value in ipairs({
    camera.target.x,
    camera.target.y,
    camera.target.z,
    camera.distance,
    camera.angleXDegrees,
    camera.angleYDegrees,
    camera.clipNear,
    camera.clipFar,
  }) do
    Assert.isTrue(value == value and value < math.huge and value > -math.huge, "camera facts must be finite")
  end
  local transform = BagSources.presentation.transform
  Assert.equal(#transform.rotation, 9)
  Assert.equal(transform.scale.x, 1)
end

function T.hero_light_vectors_carry_the_audited_static_directions()
  local BagSources = sources()
  local lights = BagSources.presentation.lights
  Assert.equal(lights.count, 4)
  Assert.deepEqual(lights.color, { r = 31, g = 31, b = 31 })
  Assert.equal(#lights.vectors, 4)
  for index, vector in ipairs(lights.vectors) do
    Assert.deepEqual(vector, { x = 1, y = 0, z = 0 }, "static light " .. index .. " points down positive x")
  end
end

function T.message_selection_names_the_audited_banks_and_indexes()
  local BagSources = sources()
  Assert.deepEqual(BagSources.messages.actionLabels, {
    toss = { bank = 10, index = 1 },
    move = { bank = 0, index = 3 },
    register = { bank = 10, index = 2 },
    unregister = { bank = 10, index = 18 },
    cancel = { bank = 10, index = 8 },
    confirm = { bank = 10, index = 5 },
  })
  Assert.deepEqual(BagSources.messages.templates, {
    movePrompt = { bank = 10, index = 46 },
    tossQuantity = { bank = 10, index = 53 },
    tossConfirm = { bank = 10, index = 55 },
  })
end

function T.registration_facts_name_the_audited_bitmap_and_crops()
  local BagSources = sources()
  local registration = BagSources.registration
  Assert.equal(registration.bitmapWidth, 104)
  Assert.equal(registration.bitmapHeight, 16)
  Assert.equal(registration.markerWidth, 40)
  Assert.equal(registration.markerHeight, 16)
  Assert.equal(registration.sourceY, 0)
  Assert.equal(registration.slot1X, 24)
  Assert.equal(registration.slot2X, 64)
  Assert.isTrue(registration.slot1X + registration.markerWidth <= registration.bitmapWidth)
  Assert.isTrue(registration.slot2X + registration.markerWidth <= registration.bitmapWidth)
  Assert.deepEqual(registration.offset, { x = 0, y = 16 })
end

function T.strip_widget_carries_producer_placement_and_browse_visibility()
  local BagSources = sources()
  local widget = BagSources.widgets and BagSources.widgets.sourceStrip
  Assert.notNil(widget, "the producer must own the strip widget placement record")
  assert(widget ~= nil, "the strip widget record is required")
  Assert.deepEqual(widget.placement, { x = 177, y = 14 }, "the strip keeps its audited sprite-center anchor")
  Assert.notNil(widget.states, "the producer must own the strip visibility record")
  Assert.equal(widget.states.browsing, false, "the strip is hidden in normal browse")
end

return { tests = T }
