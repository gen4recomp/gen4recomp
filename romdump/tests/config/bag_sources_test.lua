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
  local fullRects = {
    { x = 0, y = 32, width = 128, height = 42 },
    { x = 128, y = 32, width = 128, height = 42 },
    { x = 0, y = 74, width = 128, height = 44 },
    { x = 128, y = 74, width = 128, height = 44 },
    { x = 0, y = 118, width = 128, height = 36 },
    { x = 128, y = 118, width = 128, height = 36 },
  }
  local seen = {}
  for index, slot in ipairs(geometry.slots) do
    local cell = slot.rect
    Assert.deepEqual(cell, fullRects[index], "slot " .. index .. " carries the full touch rect")
    local key = cell.x .. "," .. cell.y
    Assert.isNil(seen[key], "slots must not overlap")
    seen[key] = true
    Assert.equal(slot.textRect.width, 88, "slot " .. index .. " text window keeps the source width")
    Assert.equal(slot.textRect.height, 32, "slot " .. index .. " text window keeps the source height")
    Assert.isTrue(
      slot.textRect.x >= cell.x
        and slot.textRect.y >= cell.y
        and slot.textRect.x + slot.textRect.width <= cell.x + cell.width
        and slot.textRect.y + slot.textRect.height <= cell.y + cell.height,
      "slot " .. index .. " text window must sit inside the touch rect"
    )
    Assert.isTrue(slot.iconCenter.x >= cell.x and slot.iconCenter.x <= cell.x + cell.width)
    Assert.isTrue(slot.iconCenter.y >= cell.y and slot.iconCenter.y <= cell.y + cell.height)
    Assert.deepEqual(slot.nameAt, { x = 0, y = 0 }, "slot " .. index .. " names the standard name anchor")
    Assert.deepEqual(slot.quantityAt, { x = 48, y = 16 }, "slot " .. index .. " names the standard quantity anchor")
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
  fits(geometry.cancel.rect, "cancel")
  fits(geometry.cancel.textRect, "cancel text window")
  fits(geometry.descriptionFrame, "description frame")
  fits(geometry.descriptionText, "description text")
  for _, button in ipairs(geometry.actionButtons) do
    fits(button, "action button")
  end
  for _, digit in ipairs(geometry.quantityDigits) do
    fits(digit, "quantity digit")
  end
end

function T.lower_palette_names_the_pocket_dependent_member_and_remap()
  local BagSources = sources()
  Assert.equal(BagSources.palettes.lower, 41, "the lower realization decodes the pocket-selected member")
  Assert.deepEqual(
    BagSources.lowerPaletteBanks,
    { bankSize = 16, offsets = { 0, 0, 1, 0 } },
    "destination banks copy the audited pocket-relative source banks"
  )
  Assert.deepEqual(BagSources.spriteStates.focus.tabs, { animation = 8, palette = 9 })
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

-- The movable focus table drives one managed sprite through four semantic
-- target groups: eight tab positions, six item positions, one Cancel
-- position, and four action positions. These canonical points are focus
-- targets, never item-icon geometry.
function T.movable_focus_targets_name_four_semantic_classes()
  local BagSources = sources()
  local focus = assert(BagSources.focusTargets, "the producer must publish the movable focus target groups")
  local expectedTabs = {}
  for k = 0, 7 do
    expectedTabs[#expectedTabs + 1] = { x = 16 + 32 * k, y = 16 }
  end
  Assert.deepEqual(focus.tabs, expectedTabs, "tab focus targets follow the audited placement table")
  Assert.deepEqual(focus.items, {
    { x = 48, y = 56 },
    { x = 176, y = 56 },
    { x = 48, y = 96 },
    { x = 176, y = 96 },
    { x = 48, y = 136 },
    { x = 176, y = 136 },
  }, "item focus targets follow the audited placement table")
  Assert.deepEqual(focus.cancel, { x = 224, y = 176 }, "Cancel focus target follows the audited placement table")
  local seen = {}
  Assert.equal(#focus.actions, 4, "action focus targets carry four positions")
  for _, target in ipairs(focus.actions) do
    Assert.isTrue(
      (target.x == 48 or target.x == 144) and (target.y == 144 or target.y == 176),
      "action focus target must sit on the audited action grid"
    )
    local key = target.x .. "," .. target.y
    Assert.isNil(seen[key], "action focus targets must not repeat")
    seen[key] = true
  end
  for _, group in ipairs({ focus.tabs, focus.items, focus.actions }) do
    for index, target in ipairs(group) do
      Assert.isTrue(target.x <= 256 and target.y <= 192, "focus target " .. index .. " must fit the canonical pane")
    end
  end
  Assert.isTrue(focus.cancel.x <= 256 and focus.cancel.y <= 192, "the Cancel focus target must fit the pane")
end

-- Item icon anchors come from the six actual item-icon sprite placements,
-- audited separately from the movable focus records above. The producer
-- keeps one record per role so a focus coordinate can never silently stand
-- in for an icon placement again.
function T.item_icon_anchors_come_from_the_item_sprite_records()
  local BagSources = sources()
  local placements =
    assert(BagSources.itemIconCenters, "the producer must publish item-icon placements apart from focus targets")
  Assert.equal(#placements, 6, "six item-icon placements are required")
  local slots = assert(BagSources.geometry, "geometry must exist").slots
  for index = 1, 6 do
    local center = assert(placements[index], "item-icon placement " .. index .. " must be published")
    Assert.isTrue(center.x >= 0 and center.y >= 0, "item-icon placement " .. index .. " must be a pane point")
    Assert.isTrue(center.x <= 256 and center.y <= 192, "item-icon placement " .. index .. " must fit the pane")
    local cell = assert(slots[index], "slot " .. index .. " must exist").rect
    Assert.isTrue(
      center.x >= cell.x and center.x <= cell.x + cell.width and center.y >= cell.y and center.y <= cell.y + cell.height,
      "item-icon placement " .. index .. " must sit inside its slot touch rect"
    )
  end
end

-- The item-icon placements are the audited template centers of the six
-- item-icon sprites, recorded apart from the focus table above.
function T.item_icon_placements_match_the_audited_template_records()
  local BagSources = sources()
  local placements = assert(BagSources.itemIconCenters, "the producer must publish item-icon placements")
  Assert.deepEqual(placements, {
    { x = 22, y = 59 },
    { x = 152, y = 59 },
    { x = 22, y = 100 },
    { x = 152, y = 100 },
    { x = 22, y = 139 },
    { x = 152, y = 139 },
  }, "item-icon placements follow the audited item-sprite template records")
  local focus = assert(BagSources.focusTargets, "the producer must publish the movable focus target groups")
  for index = 1, 6 do
    Assert.isFalse(
      placements[index].x == focus.items[index].x and placements[index].y == focus.items[index].y,
      "item-icon placement " .. index .. " must not copy its focus target"
    )
  end
end

-- The four action focus targets follow the audited table order: row-major
-- over the action-button grid.
function T.action_focus_targets_follow_the_audited_table_order()
  local BagSources = sources()
  local focus = assert(BagSources.focusTargets, "the producer must publish the movable focus target groups")
  Assert.deepEqual(focus.actions, {
    { x = 48, y = 144 },
    { x = 144, y = 144 },
    { x = 48, y = 176 },
    { x = 144, y = 176 },
  }, "action focus targets follow the audited placement table order")
end

return { tests = T }
