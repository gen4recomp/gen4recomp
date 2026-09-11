-- Contract scenarios for the generated field-bag presentation class. Fixtures
-- model the public manifest only; source archive/member identities belong to
-- the producer dependency record and are intentionally absent.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local BagAssetSchema = require("libs.assets.src.BagAssetSchema")
local BagCache = require("libs.assets.src.BagCache")

local T = {}

local POCKETS = { "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }

local function imageRef(path)
  return { image = path, width = 256, height = 192 }
end

local function visualRef(path)
  return imageRef(path)
end

local function rect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

local function constantChannel()
  return { source = "constant", value = 0 }
end

local function trsClip(id, semanticName)
  return {
    id = id,
    name = id,
    category = "joint",
    kind = "trs",
    frameCount = 4,
    tracks = { { target = 0, targetIndex = 0 } },
    semanticNames = { semanticName },
    compiled = {
      anmFlags = 0,
      rotData = {},
      pivotData = { { 0, 0, 0, 0, 0 } },
      targets = {
        {
          nodeIndex = 0,
          channels = {
            trans = { x = constantChannel(), y = constantChannel(), z = constantChannel() },
            rot = constantChannel(),
            scale = { x = constantChannel(), y = constantChannel(), z = constantChannel() },
          },
        },
      },
    },
  }
end

local function dynamicMaterial()
  return {
    id = 0,
    name = "widget",
    baseColor = { r = 255, g = 255, b = 255, a = 255 },
    colors = {
      diffuse = { r = 255, g = 255, b = 255 },
      ambient = { r = 255, g = 255, b = 255 },
      specular = { r = 255, g = 255, b = 255 },
      emission = { r = 0, g = 0, b = 0 },
    },
    alphaMode = "opaque",
    polygonMode = "modulation",
    doubleSided = false,
    polygonAlpha = 31,
    texMtxMode = 0,
    texWidth = 64,
    texHeight = 64,
    wrap = { x = "clamp", y = "clamp" },
    flip = { x = false, y = false },
    diffuse = { r = 255, g = 255, b = 255, a = 255 },
  }
end

local function heroDescriptor(gender)
  local clips = {}
  for _, pocket in ipairs(POCKETS) do
    clips[#clips + 1] = trsClip(gender .. ".pose." .. pocket, "pocket." .. pocket .. ".pose")
    clips[#clips + 1] = trsClip(gender .. ".pattern." .. pocket, "pocket." .. pocket .. ".pattern")
  end
  clips[#clips + 1] = trsClip(gender .. ".material", "bag.material")
  return {
    schema = ModelAsset.SCHEMA,
    kind = "nitro-dynamic",
    dynamic = { nodes = {}, transformProgram = {}, batches = {} },
    materials = { dynamicMaterial() },
    animations = clips,
  }
end

local function tabs()
  local out = {}
  for i = 0, 7 do
    out[#out + 1] = rect(i * 32, 0, 32, 32)
  end
  return out
end

local function slots()
  local out = {}
  local index = 0
  for row = 0, 2 do
    for col = 0, 1 do
      index = index + 1
      out[index] = {
        rect = rect(col == 0 and 32 or 160, 40 + row * 40, 88, 32),
        iconCenter = { x = col == 0 and 48 or 176, y = 56 + row * 40 },
      }
    end
  end
  return out
end

local function markerImage(path)
  return { image = path, width = 40, height = 16 }
end

local function semanticText()
  return {
    actions = {
      toss = "TOSS",
      move = "MOVE",
      register = "REGISTER",
      unregister = "DESELECT",
      cancel = "CANCEL",
      confirm = "YES",
    },
    movePrompt = {
      segments = {
        { kind = "text", value = "Move " },
        { kind = "item" },
        { kind = "text", value = "?" },
      },
    },
    tossQuantity = {
      segments = {
        { kind = "text", value = "Toss how many " },
        { kind = "item" },
        { kind = "text", value = "?" },
      },
    },
    tossConfirm = {
      segments = {
        { kind = "text", value = "Toss " },
        { kind = "quantity" },
        { kind = "text", value = " " },
        { kind = "item" },
        { kind = "text", value = "?" },
      },
    },
  }
end

local function validManifest()
  local states = {}
  for _, pocket in ipairs(POCKETS) do
    states[#states + 1] = {
      pocket = pocket,
      pose = "pocket." .. pocket .. ".pose",
      pattern = "pocket." .. pocket .. ".pattern",
    }
  end
  return {
    schema = "g4-bag-assets-v3",
    logicalSize = { width = 256, height = 192 },
    hero = {
      background = {
        male = imageRef("assets/generated/bag/hero-backdrop-male.png"),
        female = imageRef("assets/generated/bag/hero-backdrop-female.png"),
      },
      description = {
        frame = {
          image = "assets/generated/bag/description-frame.png",
          alternateImage = "assets/generated/bag/description-frame-alt.png",
          rect = rect(0, 144, 256, 48),
        },
        textRect = rect(20, 144, 228, 40),
      },
      model = { male = heroDescriptor("male"), female = heroDescriptor("female") },
      animations = {
        states = states,
        material = { male = "male.material", female = "female.material" },
      },
      presentation = {
        camera = {
          target = { x = 0, y = 0, z = 0 },
          distance = 339.9,
          angleXDegrees = 328.4,
          angleYDegrees = 28.3,
          perspectiveType = 0,
          perspectiveAngle = 256,
          clipNear = 123.0,
          clipFar = 1700.0,
        },
        transform = {
          translation = { x = 0, y = -45, z = 0 },
          rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
          scale = { x = 1, y = 1, z = 1 },
        },
        lights = {
          count = 4,
          color = { r = 31, g = 31, b = 31 },
          vectors = {
            { x = 1, y = 0, z = 0 },
            { x = 1, y = 0, z = 0 },
            { x = 1, y = 0, z = 0 },
            { x = 1, y = 0, z = 0 },
          },
        },
        materials = {
          diffuse = { r = 15, g = 15, b = 15 },
          ambient = { r = 10, g = 10, b = 10 },
          specular = { r = 15, g = 15, b = 15 },
          emission = { r = 15, g = 15, b = 15 },
        },
      },
    },
    interactive = {
      backgrounds = {
        browse = imageRef("assets/generated/bag/background-browse.png"),
        action = imageRef("assets/generated/bag/background-action.png"),
        quantity = imageRef("assets/generated/bag/background-quantity.png"),
        confirmation = imageRef("assets/generated/bag/background-confirmation.png"),
      },
      pocketTabs = {
        rects = tabs(),
        normal = {
          visualRef("assets/generated/bag/tab-normal-1.png"),
          visualRef("assets/generated/bag/tab-normal-2.png"),
          visualRef("assets/generated/bag/tab-normal-3.png"),
          visualRef("assets/generated/bag/tab-normal-4.png"),
          visualRef("assets/generated/bag/tab-normal-5.png"),
          visualRef("assets/generated/bag/tab-normal-6.png"),
          visualRef("assets/generated/bag/tab-normal-7.png"),
          visualRef("assets/generated/bag/tab-normal-8.png"),
        },
        selected = visualRef("assets/generated/bag/tab-selected-frame-1.png"),
      },
      itemSlots = {
        slots = slots(),
        focus = visualRef("assets/generated/bag/focus-frame-1.png"),
        registration = {
          slot1 = markerImage("assets/generated/bag/registration-slot-1.png"),
          slot2 = markerImage("assets/generated/bag/registration-slot-2.png"),
          offset = { x = 0, y = 16 },
        },
      },
      pageIndicator = { rect = rect(80, 168, 56, 16), textAt = { x = 0, y = 0 } },
      cancel = rect(192, 168, 56, 16),
      text = semanticText(),
      overlays = {
        actionMenu = {
          buttons = { rect(8, 136, 80, 16), rect(104, 136, 80, 16), rect(8, 168, 80, 16), rect(104, 168, 80, 16) },
        },
        quantity = {
          digits = { rect(128, 112, 16, 24), rect(160, 112, 16, 24), rect(192, 112, 16, 24) },
        },
        descriptionFallback = { frame = rect(0, 144, 256, 48), textRect = rect(20, 144, 228, 40) },
      },
      widgets = {
        sourceStrip = {
          image = "assets/generated/bag/source-strip-frame-1.png",
          width = 32,
          height = 16,
          placement = { x = 177, y = 14 },
          states = { browsing = false },
        },
      },
    },
  }
end

function T.valid_manifest_passes_schema_and_cache_contract()
  local manifest = validManifest()
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest), "the valid fixture must pass the schema")
  Assert.isTrue(BagCache.validateManifest(manifest), "the cache validator must accept the valid fixture")
  Assert.equal(BagCache.manifestPath(), "data/generated/bag/manifest.lua")
  Assert.equal(DerivedAssetContract.bag.schema, "g4-bag-assets-v3")
end

function T.schema_rejects_wrong_logical_size()
  local manifest = validManifest()
  manifest.logicalSize = { width = 512, height = 192 }
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "only the canonical pane size is valid")
end

function T.schema_rejects_out_of_bounds_rectangles()
  local manifest = validManifest()
  manifest.interactive.cancel = rect(250, 168, 56, 16)
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "a rectangle escaping the pane must fail")
  manifest = validManifest()
  manifest.interactive.pocketTabs.rects[8] = rect(224, 0, 33, 32)
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "an overflowing tab must fail")
end

function T.schema_rejects_wrong_tab_and_slot_cardinality()
  local manifest = validManifest()
  manifest.interactive.pocketTabs.rects[8] = nil
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "seven tabs must fail")
  manifest = validManifest()
  manifest.interactive.itemSlots.slots[7] = manifest.interactive.itemSlots.slots[1]
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "seven slots must fail")
end

function T.schema_rejects_missing_hero_model_and_clips()
  local manifest = validManifest()
  manifest.hero.model.female = nil
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "both gender models are required")
  manifest = validManifest()
  manifest.hero.animations.states[3].pose = "pocket.medicine.pose.missing"
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "an unresolvable pose clip must fail")
  manifest = validManifest()
  manifest.hero.animations.material.male = "male.material.missing"
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "an unresolvable material clip must fail")
end

function T.schema_rejects_source_identities_in_the_runtime_manifest()
  local manifest = validManifest()
  manifest.hero.presentation.camera.target = { x = 0, y = 0, z = 0, memberId = 55 }
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "a member identity must fail")
  manifest = validManifest()
  manifest.interactive.backgrounds.browse = {
    image = "assets/generated/bag/list-slots.png",
    width = 256,
    height = 192,
    narcId = 15,
  }
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "an archive identity must fail")
end

function T.cache_reports_ready_only_with_every_referenced_file()
  local manifest = validManifest()
  local marker = BagCache.marker("deadbeef", "feedface")
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  cacheFs:writeLua(BagCache.manifestPath(), manifest)
  for _, path in ipairs(BagCache.referencedPaths(manifest)) do
    cacheFs:write(path, "payload")
  end
  cacheFs:writeLua(BagCache.provenancePath(), { cacheFormat = BagCache.FORMAT, schema = BagCache.SCHEMA })
  cacheFs:write(BagCache.markerPath(), marker)
  Assert.isTrue(BagCache.isReady(cacheFs, marker))
  cacheFs:remove("assets/generated/bag/tab-normal-1.png")
  Assert.isFalse(BagCache.isReady(cacheFs, marker), "a missing tab image is not ready")
end

function T.old_cache_marker_forces_a_rebuild()
  local manifest = validManifest()
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  for _, path in ipairs(BagCache.referencedPaths(manifest)) do
    cacheFs:write(path, "payload")
  end
  cacheFs:writeLua(BagCache.manifestPath(), manifest)
  local oldMarker = "bag-cache-v1:deadbeef:feedface"
  cacheFs:write(BagCache.markerPath(), oldMarker)
  Assert.isFalse(BagCache.isReady(cacheFs, oldMarker), "a previous cache marker must not read as v3 ready")
end

local function assertInvalid(manifest, why)
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), why)
end

function T.schema_identity_is_the_current_contract()
  Assert.equal(BagAssetSchema.SCHEMA, "g4-bag-assets-v3")
  Assert.equal(DerivedAssetContract.bag.schema, "g4-bag-assets-v3")
  Assert.equal(BagCache.SCHEMA, "g4-bag-assets-v3")
  Assert.equal(BagCache.FORMAT, "bag-cache-v2")
end

function T.previous_bag_contract_is_rejected()
  local manifest = validManifest()
  manifest.schema = "g4-bag-assets-v2"
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "the previous Bag contract must not validate as current")
end

function T.complete_manifest_with_text_and_registration_passes()
  local manifest = validManifest()
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest), "the complete fixture must pass")
  Assert.isTrue(BagCache.validateManifest(manifest), "the cache validator must accept the complete fixture")
end

function T.incomplete_manifest_is_rejected()
  local manifest = validManifest()
  manifest.schema = "g4-bag-assets-v1"
  manifest.interactive.text = nil
  manifest.interactive.itemSlots.registration = nil
  manifest.interactive.backgrounds = nil
  assertInvalid(manifest, "a manifest without semantic text and registration markers is stale")
end

function T.manifest_without_semantic_text_is_rejected()
  local manifest = validManifest()
  manifest.interactive.text = nil
  assertInvalid(manifest, "semantic action labels and templates are mandatory")
end

function T.manifest_without_registration_markers_is_rejected()
  local manifest = validManifest()
  manifest.interactive.itemSlots.registration = nil
  assertInvalid(manifest, "both registration markers are mandatory")
end

function T.every_action_label_is_required_and_non_empty()
  for _, action in ipairs({ "toss", "move", "register", "unregister", "cancel", "confirm" }) do
    local missing = validManifest()
    missing.interactive.text.actions[action] = nil
    assertInvalid(missing, "a missing " .. action .. " label must fail")
    local empty = validManifest()
    empty.interactive.text.actions[action] = ""
    assertInvalid(empty, "an empty " .. action .. " label must fail")
  end
end

function T.unknown_action_and_template_fields_are_rejected()
  local extraAction = validManifest()
  extraAction.interactive.text.actions.use = "USE"
  assertInvalid(extraAction, "an action outside the runtime vocabulary must fail")
  local extraTemplate = validManifest()
  extraTemplate.interactive.text.inspectPrompt = { segments = { { kind = "text", value = "?" } } }
  assertInvalid(extraTemplate, "a template outside the runtime vocabulary must fail")
  local extraField = validManifest()
  extraField.interactive.text.bank = 10
  assertInvalid(extraField, "producer-side message selection must not leak into the manifest")
end

function T.template_segments_are_strict()
  local empty = validManifest()
  empty.interactive.text.movePrompt = { segments = {} }
  assertInvalid(empty, "a template with no segments must fail")
  local missingValue = validManifest()
  missingValue.interactive.text.movePrompt = { segments = { { kind = "text" } } }
  assertInvalid(missingValue, "a text segment without a value must fail")
  local emptyValue = validManifest()
  emptyValue.interactive.text.movePrompt = { segments = { { kind = "text", value = "" } } }
  assertInvalid(emptyValue, "an empty text value must fail")
  local unknownKind = validManifest()
  unknownKind.interactive.text.movePrompt = { segments = { { kind = "icon" } } }
  assertInvalid(unknownKind, "an unknown segment kind must fail")
  local itemExtra = validManifest()
  itemExtra.interactive.text.movePrompt = { segments = { { kind = "item", value = "Potion" } } }
  assertInvalid(itemExtra, "an item segment must carry no extra fields")
  local quantityExtra = validManifest()
  quantityExtra.interactive.text.tossConfirm = {
    segments = { { kind = "quantity", count = 1 } },
  }
  assertInvalid(quantityExtra, "a quantity segment must carry no extra fields")
end

function T.registration_markers_are_exactly_sized()
  local wide = validManifest()
  wide.interactive.itemSlots.registration.slot1 = markerImage("assets/generated/bag/registration-slot-1.png")
  wide.interactive.itemSlots.registration.slot1.width = 41
  assertInvalid(wide, "a 41-pixel marker must fail")
  local short = validManifest()
  short.interactive.itemSlots.registration.slot2 = markerImage("assets/generated/bag/registration-slot-2.png")
  short.interactive.itemSlots.registration.slot2.height = 15
  assertInvalid(short, "a 15-pixel marker must fail")
end

function T.registration_offset_keeps_the_marker_inside_every_slot()
  local paneFittingButSlotOverflowing = validManifest()
  paneFittingButSlotOverflowing.interactive.itemSlots.registration.offset = { x = 200, y = 0 }
  assertInvalid(paneFittingButSlotOverflowing, "an offset that pushes the 40x16 marker outside an 88x32 slot must fail")
  local bottomOverflowing = validManifest()
  bottomOverflowing.interactive.itemSlots.registration.offset = { x = 0, y = 17 }
  assertInvalid(bottomOverflowing, "an offset that pushes the marker below the slot must fail")
  local missing = validManifest()
  missing.interactive.itemSlots.registration.offset = nil
  assertInvalid(missing, "a missing registration offset must fail")
end

function T.quantity_background_is_a_required_semantic_surface()
  local single = validManifest()
  single.interactive.backgrounds.quantity = nil
  assertInvalid(single, "a missing quantity background must fail")
  local missing = validManifest()
  missing.interactive.backgrounds.quantity.width = 128
  assertInvalid(missing, "a non-canonical quantity background must fail")
end

function T.hero_light_vectors_are_a_required_static_quadruple()
  local missing = validManifest()
  missing.hero.presentation.lights.vectors = nil
  assertInvalid(missing, "missing hero light vectors must fail")
  local short = validManifest()
  short.hero.presentation.lights.vectors = {
    { x = 1, y = 0, z = 0 },
    { x = 1, y = 0, z = 0 },
    { x = 1, y = 0, z = 0 },
  }
  assertInvalid(short, "three hero light vectors must fail")
  local ragged = validManifest()
  ragged.hero.presentation.lights.vectors[2] = { x = 1, y = 0 }
  assertInvalid(ragged, "a hero light vector without depth must fail")
  local infinite = validManifest()
  infinite.hero.presentation.lights.vectors[1] = { x = math.huge, y = 0, z = 0 }
  assertInvalid(infinite, "a non-finite hero light vector must fail")
  local leaky = validManifest()
  leaky.hero.presentation.lights.vectors[4] = { x = 1, y = 0, z = 0, memberId = 37 }
  assertInvalid(leaky, "a source identity inside a hero light vector must fail")
  local extra = validManifest()
  extra.hero.presentation.lights.kind = "static"
  assertInvalid(extra, "an unknown hero lights field must fail")
  for _, count in ipairs({ 3, 5 }) do
    local wrongCount = validManifest()
    wrongCount.hero.presentation.lights.count = count
    assertInvalid(wrongCount, "exactly four hero lights are required")
  end
end

function T.hero_material_registers_are_a_required_static_quadruple()
  local missing = validManifest()
  missing.hero.presentation.materials = nil
  assertInvalid(missing, "missing hero material registers must fail")
  local short = validManifest()
  short.hero.presentation.materials = {
    diffuse = { r = 15, g = 15, b = 15 },
    ambient = { r = 10, g = 10, b = 10 },
    specular = { r = 15, g = 15, b = 15 },
  }
  assertInvalid(short, "three hero material registers must fail")
  local ragged = validManifest()
  ragged.hero.presentation.materials.ambient = { r = 10, g = 10 }
  assertInvalid(ragged, "a hero material register without blue must fail")
  local overflow = validManifest()
  overflow.hero.presentation.materials.diffuse = { r = 32, g = 15, b = 15 }
  assertInvalid(overflow, "a hero material channel past 31 must fail")
  local extra = validManifest()
  extra.hero.presentation.materials.kind = "static"
  assertInvalid(extra, "an unknown hero materials field must fail")
end

function T.source_identities_are_rejected_inside_the_new_records()
  local memberLeak = validManifest()
  memberLeak.interactive.itemSlots.registration.slot1 = {
    image = "assets/generated/bag/registration-slot-1.png",
    width = 40,
    height = 16,
    memberId = 37,
  }
  assertInvalid(memberLeak, "a source member identity must fail")
  local segmentLeak = validManifest()
  segmentLeak.interactive.text.movePrompt = {
    segments = { { kind = "text", value = "Move", memberId = 37 } },
  }
  assertInvalid(segmentLeak, "a source identity inside a template segment must fail")
end

function T.cache_references_both_registration_markers()
  local manifest = validManifest()
  local ok, paths = pcall(BagCache.referencedPaths, manifest)
  Assert.isTrue(ok, "the cache must resolve a complete valid manifest")
  assert(paths ~= nil, "a resolvable manifest must list its paths")
  local seen = {}
  for _, path in ipairs(paths) do
    seen[path] = true
  end
  Assert.isTrue(seen["assets/generated/bag/registration-slot-1.png"], "slot 1 marker must be referenced")
  Assert.isTrue(seen["assets/generated/bag/registration-slot-2.png"], "slot 2 marker must be referenced")
end

function T.schema_rejects_animated_visual_timelines()
  local backgroundTimeline = validManifest()
  backgroundTimeline.interactive.backgrounds.browse = {
    frames = {
      {
        image = "assets/generated/bag/background-browse-frame-1.png",
        width = 256,
        height = 192,
        duration = 4,
      },
    },
  }
  assertInvalid(backgroundTimeline, "a background frame timeline must fail; Bag v3 publishes static realizations")
  local tabTimeline = validManifest()
  tabTimeline.interactive.pocketTabs.normal[1] = {
    frames = {
      { image = "assets/generated/bag/tab-normal-1-frame-1.png", width = 16, height = 16, duration = 2 },
      { image = "assets/generated/bag/tab-normal-1-frame-2.png", width = 16, height = 16, duration = 2 },
    },
  }
  assertInvalid(tabTimeline, "a tab frame timeline must fail; Bag v3 publishes static realizations")
  local durationOnStatic = validManifest()
  durationOnStatic.interactive.itemSlots.focus = {
    image = "assets/generated/bag/focus-frame-1.png",
    width = 16,
    height = 16,
    duration = 2,
  }
  assertInvalid(durationOnStatic, "a duration on a static visual must fail")
end

function T.source_widget_requires_producer_placement_and_visibility()
  local bare = validManifest()
  bare.interactive.widgets.sourceStrip = visualRef("assets/generated/bag/source-strip-frame-1.png")
  assertInvalid(bare, "a source widget without producer placement and visibility must fail")
  local placed = validManifest()
  placed.interactive.widgets.sourceStrip = {
    image = "assets/generated/bag/source-strip-frame-1.png",
    width = 32,
    height = 16,
    placement = { x = 177, y = 14 },
  }
  assertInvalid(placed, "a source widget without visibility states must fail")
  local visible = validManifest()
  visible.interactive.widgets.sourceStrip = {
    image = "assets/generated/bag/source-strip-frame-1.png",
    width = 32,
    height = 16,
    states = { browsing = false },
  }
  assertInvalid(visible, "a source widget without canonical placement must fail")
  local misplaced = validManifest()
  misplaced.interactive.widgets.sourceStrip = {
    image = "assets/generated/bag/source-strip-frame-1.png",
    width = 32,
    height = 16,
    placement = { x = 250, y = 190 },
    states = { browsing = false },
  }
  Assert.isTrue(
    BagAssetSchema.isValidManifest(misplaced),
    "a pane-fitting producer placement passes the shape contract; source truth is proven producer-side"
  )
end

function T.static_widget_with_producer_placement_and_visibility_passes()
  local manifest = validManifest()
  manifest.interactive.widgets.sourceStrip = {
    image = "assets/generated/bag/source-strip-frame-1.png",
    width = 32,
    height = 16,
    placement = { x = 177, y = 14 },
    states = { browsing = false },
  }
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest), "the producer-placed static widget must pass")
end

function T.cache_references_the_source_widget_image()
  local manifest = validManifest()
  manifest.interactive.widgets.sourceStrip = {
    image = "assets/generated/bag/source-strip-frame-1.png",
    width = 32,
    height = 16,
    placement = { x = 177, y = 14 },
    states = { browsing = false },
  }
  local ok, paths = pcall(BagCache.referencedPaths, manifest)
  Assert.isTrue(ok, "the cache must resolve a manifest with a placed widget")
  assert(paths ~= nil, "a resolvable manifest must list its paths")
  local seen = {}
  for _, path in ipairs(paths) do
    seen[path] = true
  end
  Assert.isTrue(seen["assets/generated/bag/source-strip-frame-1.png"], "the source widget image must be referenced")
end

return { tests = T }
