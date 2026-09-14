-- ROM-backed producer contract for the semantic field-bag presentation.
-- This producer contract ends at the generated asset boundary; the user-visible
-- runtime journey belongs to the later integrated Bag acceptance suite.

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

local function assertStaticVisual(visual, label)
  Assert.isTrue(type(visual) == "table", label .. " must be a semantic visual")
  Assert.isTrue(type(visual.image) == "string", label .. " must publish one realized image")
  Assert.isNil(visual.frames, label .. " must not publish a runtime frame timeline")
  Assert.isNil(visual.duration, label .. " must not publish a frame duration")
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

local function assertNoSourceIdentity(value, path)
  if type(value) ~= "table" then
    return
  end
  for key, child in pairs(value) do
    Assert.isFalse(
      key == "narcId"
        or key == "memberId"
        or key == "fileId"
        or key == "bgPriority"
        or key == "layer"
        or key == "cell"
        or key == "animIndex"
        or key == "paletteSlot"
        or key == "oam"
        or key == "template",
      path .. " leaks source presentation identity " .. tostring(key)
    )
    assertNoSourceIdentity(child, path .. "." .. tostring(key))
  end
end

local function compile(romFs)
  local bundle, err = BagAssetCompiler.compile(romFs)
  Assert.notNil(bundle, "the production Bag compiler must rebuild the presentation bundle: " .. tostring(err))
  return assert(bundle)
end

local POCKETS = { "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }

function T.rebuilt_bundle_publishes_source_faithful_semantic_presentation(romFs)
  local bundle = compile(romFs)
  local manifest = assert(bundle.manifest)

  Assert.equal(manifest.schema, "g4-bag-assets-v5", "the rebuilt Bag cache must publish the current contract")
  Assert.equal(BagCache.SCHEMA, "g4-bag-assets-v5", "the loader must require the current contract")
  Assert.equal(BagCache.FORMAT, "bag-cache-v2", "the cache framing must not change with the semantic migration")
  for _, stale in ipairs({ "g4-bag-assets-v2", "g4-bag-assets-v3", "g4-bag-assets-v4" }) do
    Assert.isFalse(
      BagAssetSchema.isValidManifest({ schema = stale }),
      "a " .. stale .. " manifest must not validate through the current loader"
    )
  end
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest), "the rebuilt bundle must validate as the current contract")

  local hero = assert(manifest.hero)
  local translation = assert(hero.presentation).transform.translation
  Assert.equal(translation.x, 0)
  Assert.near(translation.y, -45 / 16, 1e-9, "the compiled hero height normalizes the retail source vector once")
  Assert.equal(translation.z, 0)

  local lights = assert(hero.presentation).lights
  for _, count in ipairs({ 3, 5 }) do
    local original = lights.count
    lights.count = count
    local valid = BagAssetSchema.isValidManifest(manifest)
    lights.count = original
    Assert.isFalse(valid, "a Bag hero with " .. count .. " lights must be rejected")
  end

  Assert.equal(manifest.logicalSize.width, 256)
  Assert.equal(manifest.logicalSize.height, 192)

  local interactive = assert(manifest.interactive)
  local backgrounds = assert(interactive.backgrounds, "Bag backgrounds must be producer-composed semantic images")
  for _, state in ipairs({ "browse", "action", "quantity", "confirmation" }) do
    local pockets = assert(backgrounds[state], state .. " must publish every pocket variant")
    local seen = {}
    for _, pocket in ipairs(POCKETS) do
      local background = assert(pockets[pocket], state .. " must publish the " .. pocket .. " background")
      Assert.equal(background.width, 256, state .. "/" .. pocket .. " background must use canonical pane width")
      Assert.equal(background.height, 192, state .. "/" .. pocket .. " background must use canonical pane height")
      assertImage(bundle, background, state .. "/" .. pocket .. " background")
      assertStaticVisual(background, state .. "/" .. pocket .. " background")
      seen[#seen + 1] = bundle.assets[background.image]
    end
    local distinct = {}
    for _, bytes in ipairs(seen) do
      distinct[bytes] = true
    end
    local distinctCount = 0
    for _ in pairs(distinct) do
      distinctCount = distinctCount + 1
    end
    Assert.isTrue(distinctCount > 1, state .. " backgrounds must vary with the current pocket")
  end

  local tabs = assert(interactive.pocketTabs)
  Assert.equal(#assert(tabs.normal), 8, "all eight normal pocket tabs must be generated")
  local normalBytes = {}
  for index, tab in ipairs(tabs.normal) do
    normalBytes[index] = assertImage(bundle, tab, "normal pocket tab " .. index)
    assertStaticVisual(tab, "normal pocket tab " .. index)
  end
  Assert.isNil(tabs.selected, "the retired selected-tab semantic must not be published")
  local highlight = assert(tabs.highlight, "the tab highlight must be a semantic visual")
  local highlightBytes = assertImage(bundle, highlight, "tab highlight")
  assertStaticVisual(highlight, "tab highlight")
  Assert.isTrue(
    highlightBytes ~= normalBytes[1],
    "highlight and normal pocket visuals must differ in their generated pixels"
  )

  local itemSlots = assert(interactive.itemSlots)
  Assert.isNil(itemSlots.focus, "no generated item-focus visual may be published")
  local fullRects = {
    { x = 0, y = 32, width = 128, height = 42 },
    { x = 128, y = 32, width = 128, height = 42 },
    { x = 0, y = 74, width = 128, height = 44 },
    { x = 128, y = 74, width = 128, height = 44 },
    { x = 0, y = 118, width = 128, height = 36 },
    { x = 128, y = 118, width = 128, height = 36 },
  }
  Assert.equal(#assert(itemSlots.slots), 6, "all six item slots must be generated")
  for index, slot in ipairs(itemSlots.slots) do
    Assert.deepEqual(slot.rect, fullRects[index], "item slot " .. index .. " carries the full touch rect")
    Assert.notNil(slot.textRect, "item slot " .. index .. " carries a separate text window")
    Assert.equal(slot.textRect.width, 88, "item slot " .. index .. " text window keeps the source width")
    Assert.equal(slot.textRect.height, 32, "item slot " .. index .. " text window keeps the source height")
    Assert.notNil(slot.iconCenter, "item slot " .. index .. " carries its icon center")
    Assert.deepEqual(slot.nameAt, { x = 0, y = 0 }, "item slot " .. index .. " names the standard name anchor")
    Assert.deepEqual(
      slot.quantityAt,
      { x = 48, y = 16 },
      "item slot " .. index .. " names the standard quantity anchor"
    )
  end
  Assert.notNil(itemSlots.registration.slot1, "registration marker 1 must remain published")
  Assert.notNil(itemSlots.registration.slot2, "registration marker 2 must remain published")

  local cancel = assert(interactive.cancel, "Cancel must publish split geometry")
  Assert.deepEqual(cancel.rect, { x = 192, y = 168, width = 64, height = 24 }, "Cancel carries the full button rect")
  Assert.deepEqual(
    cancel.textRect,
    { x = 192, y = 168, width = 56, height = 16 },
    "Cancel carries the separate text window"
  )
  Assert.isNil(interactive.widgets, "the rebuilt manifest carries no retired widget namespace")

  Assert.equal(lights.count, 4, "the Bag hero must carry exactly four lights")
  Assert.equal(#lights.vectors, 4, "the Bag hero must carry exactly four light vectors")

  assertNoSourceIdentity(manifest, "manifest")
  for path in pairs(bundle.assets) do
    Assert.isFalse(path:find("icon", 1, true) ~= nil, "item icon pixels must remain outside the Bag bundle")
    Assert.isFalse(path:find("focus", 1, true) ~= nil, "no generated focus asset may remain in the Bag bundle")
  end
end

function T.published_visuals_carry_no_timeline_or_source_identities(romFs)
  local bundle = compile(romFs)
  local manifest = assert(bundle.manifest)
  local interactive = assert(manifest.interactive)
  local visuals = {}
  for _, state in ipairs({ "browse", "action", "quantity", "confirmation" }) do
    for _, pocket in ipairs(POCKETS) do
      visuals[#visuals + 1] =
        { visual = interactive.backgrounds[state][pocket], label = state .. "/" .. pocket .. " background" }
    end
  end
  for index, visual in ipairs(assert(interactive.pocketTabs.normal)) do
    visuals[#visuals + 1] = { visual = visual, label = "normal pocket tab " .. index }
  end
  visuals[#visuals + 1] = { visual = interactive.pocketTabs.highlight, label = "tab highlight" }
  visuals[#visuals + 1] = { visual = interactive.itemSlots.registration.slot1, label = "registration marker 1" }
  visuals[#visuals + 1] = { visual = interactive.itemSlots.registration.slot2, label = "registration marker 2" }
  for _, entry in ipairs(visuals) do
    assertImage(bundle, entry.visual, entry.label)
    assertNoTimelineOrSourceIdentity(entry.visual, entry.label)
  end
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
return suite
