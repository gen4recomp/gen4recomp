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

  Assert.equal(manifest.schema, "g4-bag-assets-v7", "the rebuilt Bag cache must publish the count-variant contract")
  Assert.equal(BagCache.SCHEMA, "g4-bag-assets-v7", "the loader must require the count-variant contract")
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
  local tabKeys = {}
  for key in pairs(tabs) do
    tabKeys[#tabKeys + 1] = key
  end
  table.sort(tabKeys)
  Assert.deepEqual(tabKeys, { "normal", "rects" }, "pocket tabs carry only rects and normal art")
  Assert.equal(#assert(tabs.normal), 8, "all eight normal pocket tabs must be generated")

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
  local normalBytes = {}
  for index, tab in ipairs(tabs.normal) do
    normalBytes[index] = assertImage(bundle, tab, "normal pocket tab " .. index)
    assertNoTimelineOrSourceIdentity(tab, "normal pocket tab " .. index)
  end
  for index, bytes in ipairs(normalBytes) do
    Assert.isTrue(
      bytes ~= tabFocusBytes and bytes ~= itemFocusBytes and bytes ~= cancelFocusBytes and bytes ~= actionFocusBytes,
      "normal tab " .. index .. " must not reuse a focus visual"
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

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
return suite
