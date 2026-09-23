-- ROM-backed producer contract for the semantic field-bag presentation.
-- The rebuilt bundle publishes source-derived focus visuals with exact
-- target cardinalities, normal pocket-tab artwork, independently placed
-- item-icon anchors, and finalized backgrounds; the previous
-- highlight-shaped manifest no longer validates. This producer contract
-- ends at the generated asset boundary; the user-visible runtime journey
-- belongs to the later integrated Bag acceptance suite.

local Assert = require("tests.support.Assert")
local BagAssetCompiler = require("romdump.src.digest.ui.BagAssetCompiler")
local BagAssetSchema = require("libs.assets.src.BagAssetSchema")
local BagCache = require("libs.assets.src.BagCache")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function assertImage(bundle, visual, label)
  Assert.isTrue(type(visual) == "table", label .. " must be a semantic visual")
  Assert.isTrue(type(visual.image) == "string", label .. " must publish one realized image")
  Assert.isNil(visual.frames, label .. " must not publish a runtime frame timeline")
  Assert.isNil(visual.duration, label .. " must not publish a frame duration")
  Assert.isTrue(type(bundle.assets[visual.image]) == "string", label .. " must reference generated image bytes")
  Assert.isTrue(#bundle.assets[visual.image] > 0, label .. " must contain generated image bytes")
  return bundle.assets[visual.image]
end

-- Every published 2D visual record must be a static semantic realization:
-- one image, no timeline, and no source archive/animation/palette/member
-- identities at any depth. Sequence identities disappear at publication.
local function assertNoTimelineOrSourceIdentity(value, path)
  if type(value) ~= "table" then
    return
  end
  for key, child in pairs(value) do
    Assert.isFalse(
      key == "frames"
        or key == "duration"
        or key == "narcId"
        or key == "memberId"
        or key == "fileId"
        or key == "animIndex"
        or key == "paletteSlot"
        or key == "member"
        or key == "narc",
      path .. " leaks a timeline or source identity " .. tostring(key)
    )
    assertNoTimelineOrSourceIdentity(child, path .. "." .. tostring(key))
  end
end

local function compile(romFs)
  local bundle, err = BagAssetCompiler.compile(romFs)
  Assert.notNil(bundle, "the production Bag compiler must rebuild the presentation bundle: " .. tostring(err))
  return assert(bundle)
end

local function expectedTabTargets()
  local out = {}
  for k = 0, 7 do
    out[#out + 1] = { x = 16 + 32 * k, y = 16 }
  end
  return out
end

local function expectedItemTargets()
  return {
    { x = 48, y = 56 },
    { x = 176, y = 56 },
    { x = 48, y = 96 },
    { x = 176, y = 96 },
    { x = 48, y = 136 },
    { x = 176, y = 136 },
  }
end

function T.rebuilt_bundle_publishes_the_semantic_focus_contract(romFs)
  local bundle = compile(romFs)
  local manifest = assert(bundle.manifest)

  Assert.equal(manifest.schema, "g4-bag-assets-v9", "the rebuilt Bag cache must publish the control contract")
  Assert.equal(BagCache.SCHEMA, "g4-bag-assets-v9", "the loader must require the control contract")
  Assert.equal(BagCache.FORMAT, "bag-cache-v2", "the cache framing must not change with the semantic migration")
  for _, stale in ipairs({
    "g4-bag-assets-v2",
    "g4-bag-assets-v3",
    "g4-bag-assets-v4",
    "g4-bag-assets-v5",
    "g4-bag-assets-v6",
  }) do
    Assert.isFalse(
      BagAssetSchema.isValidManifest({ schema = stale }),
      "a " .. stale .. " manifest must not validate through the current loader"
    )
  end
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest), "the rebuilt bundle must validate as the current contract")

  local interactive = assert(manifest.interactive)
  local tabs = assert(interactive.pocketTabs)
  Assert.isNil(tabs.highlight, "the retired tab highlight must not be published")
  Assert.isNil(tabs.normal, "the retired per-tab normal array must not be published")
  local tabKeys = {}
  for key in pairs(tabs) do
    tabKeys[#tabKeys + 1] = key
  end
  table.sort(tabKeys)
  Assert.deepEqual(tabKeys, { "rects", "strips" }, "pocket tabs carry only rects and strips")

  local focus = assert(interactive.focus, "the rebuilt manifest must publish semantic focus")
  local focusKeys = {}
  for key in pairs(focus) do
    focusKeys[#focusKeys + 1] = key
  end
  table.sort(focusKeys)
  Assert.deepEqual(focusKeys, { "actions", "cancel", "items", "tabs" }, "focus carries exactly four classes")

  Assert.deepEqual(focus.tabs.targets, expectedTabTargets(), "tab focus targets match the audited source table")
  Assert.deepEqual(focus.items.targets, expectedItemTargets(), "item focus targets match the audited source table")
  Assert.deepEqual(focus.cancel.target, { x = 224, y = 176 }, "the Cancel focus target matches the audited source")
  Assert.equal(#assert(focus.actions.targets), 4, "four action focus targets are required")
  local seenActions = {}
  for _, target in ipairs(focus.actions.targets) do
    Assert.isTrue(
      (target.x == 48 or target.x == 144) and (target.y == 144 or target.y == 176),
      "action focus targets match the audited source grid"
    )
    local key = target.x .. "," .. target.y
    Assert.isNil(seenActions[key], "action focus targets must not repeat")
    seenActions[key] = true
  end

  local tabFocusBytes = assertImage(bundle, focus.tabs.visual, "tab focus")
  local itemFocusBytes = assertImage(bundle, focus.items.visual, "item focus")
  local cancelFocusBytes = assertImage(bundle, focus.cancel.visual, "Cancel focus")
  local actionFocusBytes = assertImage(bundle, focus.actions.visual, "action focus")
  for _, entry in ipairs({
    { visual = focus.tabs.visual, label = "tab focus" },
    { visual = focus.items.visual, label = "item focus" },
    { visual = focus.cancel.visual, label = "Cancel focus" },
    { visual = focus.actions.visual, label = "action focus" },
  }) do
    assertNoTimelineOrSourceIdentity(entry.visual, entry.label)
  end
  local stripBytes = {}
  for _, pocket in ipairs({ "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }) do
    local strip = assert(tabs.strips[pocket], pocket .. " must publish its active-pocket strip")
    Assert.equal(strip.width, 256, pocket .. " strip keeps the canonical strip width")
    Assert.equal(strip.height, 32, pocket .. " strip keeps the canonical strip height")
    stripBytes[pocket] = assertImage(bundle, strip, pocket .. " pocket strip")
    assertNoTimelineOrSourceIdentity(strip, pocket .. " pocket strip")
  end
  for _, pocket in ipairs({ "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }) do
    Assert.isTrue(
      stripBytes[pocket] ~= tabFocusBytes
        and stripBytes[pocket] ~= itemFocusBytes
        and stripBytes[pocket] ~= cancelFocusBytes
        and stripBytes[pocket] ~= actionFocusBytes,
      pocket .. " strip must not reuse a focus visual"
    )
  end

  local itemSlots = assert(interactive.itemSlots)
  Assert.equal(#assert(itemSlots.slots), 6, "all six item slots must be generated")
  for index, slot in ipairs(itemSlots.slots) do
    Assert.notNil(slot.iconCenter, "item slot " .. index .. " carries its icon center")
  end
  -- Item icon anchors come from the item-sprite placements, never the focus
  -- table: each center sits inside its slot touch rect, left of its text
  -- window, and away from its row's focus target.
  for index, slot in ipairs(itemSlots.slots) do
    local center = assert(slot.iconCenter, "item slot " .. index .. " carries its icon center")
    Assert.isTrue(
      center.x >= slot.rect.x
        and center.x <= slot.rect.x + slot.rect.width
        and center.y >= slot.rect.y
        and center.y <= slot.rect.y + slot.rect.height,
      "item slot " .. index .. " icon center must sit inside its touch rect"
    )
    Assert.isTrue(center.x < slot.textRect.x, "item slot " .. index .. " icon center must sit left of its text window")
    local focusTarget = assert(focus.items.targets[index], "item slot " .. index .. " has a focus target")
    Assert.isFalse(
      center.x == focusTarget.x and center.y == focusTarget.y,
      "item slot " .. index .. " icon center must not copy its focus target"
    )
  end

  local ok, paths = pcall(BagCache.referencedPaths, manifest)
  Assert.isTrue(ok, "the cache must resolve the rebuilt manifest")
  assert(paths ~= nil, "a resolvable manifest must list its paths")
  local counts = {}
  for _, path in ipairs(paths) do
    counts[path] = (counts[path] or 0) + 1
    Assert.isFalse(path:find("highlight", 1, true) ~= nil, "no retired highlight path may remain referenced")
  end
  for _, visual in ipairs({ focus.tabs.visual, focus.items.visual, focus.cancel.visual, focus.actions.visual }) do
    Assert.equal(counts[visual.image], 1, visual.image .. " must participate in readiness exactly once")
  end
  for path in pairs(bundle.assets) do
    Assert.isFalse(path:find("icon", 1, true) ~= nil, "item icon pixels must remain outside the Bag bundle")
  end
end

function T.action_overlay_publishes_source_slot_geometry_and_normal_face(romFs)
  local bundle = compile(romFs)
  local overlay = assert(assert(bundle.manifest.interactive).overlays).actionMenu
  Assert.notNil(overlay.face, "the action overlay must publish its normal face")
  Assert.deepEqual(overlay.slots, {
    {
      center = { x = 48, y = 144 },
      textRect = { x = 8, y = 136, width = 80, height = 16 },
      hitRect = { x = 0, y = 128, width = 94, height = 32 },
    },
    {
      center = { x = 144, y = 144 },
      textRect = { x = 104, y = 136, width = 80, height = 16 },
      hitRect = { x = 96, y = 128, width = 96, height = 32 },
    },
    {
      center = { x = 48, y = 176 },
      textRect = { x = 8, y = 168, width = 80, height = 16 },
      hitRect = { x = 0, y = 160, width = 94, height = 32 },
    },
    {
      center = { x = 144, y = 176 },
      textRect = { x = 104, y = 168, width = 80, height = 16 },
      hitRect = { x = 96, y = 160, width = 96, height = 32 },
    },
  }, "action slots preserve independent source geometry")
  assertImage(bundle, overlay.face, "normal action face")
  assertNoTimelineOrSourceIdentity(overlay.face, "normal action face")
end

function T.quantity_overlay_publishes_source_controls_and_static_press_feedback(romFs)
  local bundle = compile(romFs)
  local overlay = assert(assert(bundle.manifest.interactive).overlays).quantity
  Assert.deepEqual(overlay.controls, {
    {
      delta = 100,
      role = "increment",
      center = { x = 136, y = 104 },
      hitRect = { x = 120, y = 88, width = 32, height = 24 },
    },
    {
      delta = 10,
      role = "increment",
      center = { x = 168, y = 104 },
      hitRect = { x = 152, y = 88, width = 32, height = 24 },
    },
    {
      delta = 1,
      role = "increment",
      center = { x = 200, y = 104 },
      hitRect = { x = 184, y = 88, width = 32, height = 24 },
    },
    {
      delta = -100,
      role = "decrement",
      center = { x = 136, y = 152 },
      hitRect = { x = 120, y = 136, width = 32, height = 24 },
    },
    {
      delta = -10,
      role = "decrement",
      center = { x = 168, y = 152 },
      hitRect = { x = 152, y = 136, width = 32, height = 24 },
    },
    {
      delta = -1,
      role = "decrement",
      center = { x = 200, y = 152 },
      hitRect = { x = 184, y = 136, width = 32, height = 24 },
    },
  }, "quantity controls preserve source order and geometry")
  Assert.equal(overlay.pressTicks, 2, "quantity press feedback carries the source duration")
  Assert.deepEqual(overlay.confirm.center, { x = 136, y = 176 })
  Assert.deepEqual(overlay.confirm.hitRect, { x = 96, y = 168, width = 78, height = 24 })
  Assert.deepEqual(overlay.cancelHitRect, { x = 178, y = 168, width = 78, height = 24 })
  for _, visual in ipairs({
    overlay.visuals.increment.normal,
    overlay.visuals.increment.pressed,
    overlay.visuals.decrement.normal,
    overlay.visuals.decrement.pressed,
    overlay.confirm.visual,
  }) do
    assertImage(bundle, visual, "quantity control visual")
    assertNoTimelineOrSourceIdentity(visual, "quantity control visual")
  end
end

function T.published_focus_visuals_carry_no_timeline_or_source_identities(romFs)
  local bundle = compile(romFs)
  local manifest = assert(bundle.manifest)
  local focus = assert(assert(manifest.interactive).focus)
  for _, entry in ipairs({
    { visual = focus.tabs.visual, label = "tab focus" },
    { visual = focus.items.visual, label = "item focus" },
    { visual = focus.cancel.visual, label = "Cancel focus" },
    { visual = focus.actions.visual, label = "action focus" },
  }) do
    assertImage(bundle, entry.visual, entry.label)
    assertNoTimelineOrSourceIdentity(entry.visual, entry.label)
  end
end

function T.machine_summary_publishes_the_complete_semantic_contract(romFs)
  local bundle = compile(romFs)
  local manifest = assert(bundle.manifest)
  Assert.equal(manifest.schema, "g4-bag-assets-v10", "the rebuilt Bag cache must publish the move-summary contract")
  local summary = assert(assert(manifest.hero).moveSummary, "the hero must publish a machine move summary")
  Assert.isNil(manifest.hero.description.frame.alternateImage, "the retired alternate-image owner is removed")
  Assert.deepEqual(summary.labels, {
    type = "TYPE",
    pp = "PP",
    category = "CATEGORY",
    power = "POWER",
    accuracy = "ACCURACY",
    unavailable = "---",
  })
  Assert.deepEqual(summary.text, {
    type = { x = 0, y = 104 },
    pp = { x = 16, y = 120 },
    category = { x = 72, y = 104 },
    power = { x = 168, y = 104 },
    accuracy = { x = 168, y = 120 },
    ppValue = { x = 48, y = 120 },
    powerValue = { x = 232, y = 104 },
    accuracyValue = { x = 232, y = 120 },
  })
  Assert.deepEqual(summary.typeCenter, { x = 48, y = 112 })
  Assert.deepEqual(summary.categoryCenter, { x = 144, y = 112 })
  local typeKeys, categoryKeys = {}, {}
  for key, visual in pairs(summary.typeIcons) do
    typeKeys[#typeKeys + 1] = key
    assertImage(bundle, visual, "move type " .. key)
    assertNoTimelineOrSourceIdentity(visual, "move type " .. key)
  end
  for key, visual in pairs(summary.categoryIcons) do
    categoryKeys[#categoryKeys + 1] = key
    assertImage(bundle, visual, "move category " .. key)
    assertNoTimelineOrSourceIdentity(visual, "move category " .. key)
  end
  table.sort(typeKeys)
  table.sort(categoryKeys)
  Assert.deepEqual(typeKeys, {
    "bug",
    "dark",
    "dragon",
    "electric",
    "fighting",
    "fire",
    "flying",
    "ghost",
    "grass",
    "ground",
    "ice",
    "mystery",
    "normal",
    "poison",
    "psychic",
    "rock",
    "steel",
    "water",
  })
  Assert.deepEqual(categoryKeys, { "physical", "special", "status" })
  for _, path in ipairs(BagCache.referencedPaths(manifest)) do
    Assert.isTrue(type(bundle.assets[path]) == "string", path .. " is ready for runtime acquisition")
  end
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
return suite
