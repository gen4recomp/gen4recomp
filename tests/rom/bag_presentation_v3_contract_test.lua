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

function T.rebuilt_bundle_publishes_source_faithful_semantic_presentation(romFs)
  local bundle = compile(romFs)
  local manifest = assert(bundle.manifest)

  Assert.equal(manifest.schema, "g4-bag-assets-v3", "the rebuilt Bag cache must publish the v3 contract")
  Assert.equal(BagCache.SCHEMA, "g4-bag-assets-v3", "the loader must require the v3 contract")
  Assert.isFalse(
    BagAssetSchema.isValidManifest({ schema = "g4-bag-assets-v2" }),
    "a v2 manifest must not validate through the v3 loader"
  )

  local lights = assert(manifest.hero).presentation.lights
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
    local background = assert(backgrounds[state], state .. " must have a producer-composed background")
    Assert.equal(background.width, 256, state .. " background must use canonical pane width")
    Assert.equal(background.height, 192, state .. " background must use canonical pane height")
    assertImage(bundle, background, state .. " background")
    assertStaticVisual(background, state .. " background")
  end

  local tabs = assert(interactive.pocketTabs)
  Assert.equal(#assert(tabs.normal), 8, "all eight normal pocket tabs must be generated")
  local normalBytes = {}
  for index, tab in ipairs(tabs.normal) do
    normalBytes[index] = assertImage(bundle, tab, "normal pocket tab " .. index)
    assertStaticVisual(tab, "normal pocket tab " .. index)
  end
  local selected = assert(tabs.selected, "the selected pocket decoration must be a semantic visual")
  local selectedBytes = assertImage(bundle, selected, "selected pocket tab")
  assertStaticVisual(selected, "selected pocket tab")
  Assert.isFalse(
    selected.image ~= nil and selected.image == tabs.normal[1].image,
    "selected and normal pocket visuals must not alias the same generated image"
  )
  Assert.isTrue(
    selectedBytes ~= normalBytes[1],
    "selected and normal pocket visuals must differ in their generated pixels"
  )

  local focus = assert(interactive.itemSlots).focus
  assertImage(bundle, focus, "item focus cursor")
  assertStaticVisual(focus, "item focus cursor")
  local sourceStrip = assert(interactive.widgets).sourceStrip
  assertImage(bundle, sourceStrip, "source strip widget")
  assertStaticVisual(sourceStrip, "source strip widget")

  Assert.equal(lights.count, 4, "the Bag hero must carry exactly four lights")
  Assert.equal(#lights.vectors, 4, "the Bag hero must carry exactly four light vectors")

  assertNoSourceIdentity(manifest, "manifest")
  for path in pairs(bundle.assets) do
    Assert.isFalse(path:find("icon", 1, true) ~= nil, "item icon pixels must remain outside the Bag bundle")
  end
end

function T.widget_placement_and_visibility_match_the_audited_source_facts(romFs)
  local BagSources = require("romdump.src.config.BagSources")
  local bundle = compile(romFs)
  local manifest = assert(bundle.manifest)
  local widget = assert(manifest.interactive.widgets).sourceStrip
  assertImage(bundle, widget, "source strip widget")
  Assert.deepEqual(
    widget.placement,
    BagSources.widgets.sourceStrip.placement,
    "the published strip anchor must be the audited sprite center"
  )
  Assert.equal(widget.states.browsing, false, "the strip stays hidden in normal browse")
end

function T.published_visuals_carry_no_timeline_or_source_identities(romFs)
  local bundle = compile(romFs)
  local manifest = assert(bundle.manifest)
  local interactive = assert(manifest.interactive)
  local visuals = {}
  for _, state in ipairs({ "browse", "action", "quantity", "confirmation" }) do
    visuals[#visuals + 1] = { visual = interactive.backgrounds[state], label = state .. " background" }
  end
  for index, visual in ipairs(assert(interactive.pocketTabs.normal)) do
    visuals[#visuals + 1] = { visual = visual, label = "normal pocket tab " .. index }
  end
  visuals[#visuals + 1] = { visual = interactive.pocketTabs.selected, label = "selected pocket tab" }
  visuals[#visuals + 1] = { visual = interactive.itemSlots.focus, label = "item focus cursor" }
  visuals[#visuals + 1] = { visual = interactive.widgets.sourceStrip, label = "source strip widget" }
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
