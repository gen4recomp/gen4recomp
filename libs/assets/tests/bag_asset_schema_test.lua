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
  local fullRects = {
    rect(0, 32, 128, 42),
    rect(128, 32, 128, 42),
    rect(0, 74, 128, 44),
    rect(128, 74, 128, 44),
    rect(0, 118, 128, 36),
    rect(128, 118, 128, 36),
  }
  local textRects = {
    rect(32, 40, 88, 32),
    rect(160, 40, 88, 32),
    rect(32, 80, 88, 32),
    rect(160, 80, 88, 32),
    rect(32, 120, 88, 32),
    rect(160, 120, 88, 32),
  }
  local iconCenters = {
    { x = 48, y = 56 },
    { x = 176, y = 56 },
    { x = 48, y = 96 },
    { x = 176, y = 96 },
    { x = 48, y = 136 },
    { x = 176, y = 136 },
  }
  local out = {}
  for index = 1, 6 do
    out[index] = {
      rect = fullRects[index],
      textRect = textRects[index],
      iconCenter = iconCenters[index],
      nameAt = { x = 0, y = 0 },
      quantityAt = { x = 48, y = 16 },
    }
  end
  return out
end

local function markerImage(path)
  return { image = path, width = 40, height = 16 }
end

local function backgrounds()
  local out = {}
  for _, state in ipairs({ "action", "quantity", "confirmation" }) do
    local pockets = {}
    for _, pocket in ipairs(POCKETS) do
      pockets[pocket] = imageRef("assets/generated/bag/background-" .. state .. "-" .. pocket .. ".png")
    end
    out[state] = pockets
  end
  local browse = {}
  for _, pocket in ipairs(POCKETS) do
    local variants = {}
    for count = 0, 6 do
      variants[#variants + 1] =
        imageRef("assets/generated/bag/background-browse-" .. pocket .. "-count-" .. count .. ".png")
    end
    browse[pocket] = variants
  end
  out.browse = browse
  return out
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

-- Previous highlight-shaped manifest: stale once the semantic focus
-- contract is current. Staleness scenarios use it directly; every other
-- scenario builds on the focus-shaped fixture below.
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
    schema = "g4-bag-assets-v5",
    logicalSize = { width = 256, height = 192 },
    hero = {
      background = {
        male = imageRef("assets/generated/bag/hero-backdrop-male.png"),
        female = imageRef("assets/generated/bag/hero-backdrop-female.png"),
      },
      description = {
        frame = {
          image = "assets/generated/bag/description-frame.png",
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
      backgrounds = backgrounds(),
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
        highlight = visualRef("assets/generated/bag/tab-highlight-frame-1.png"),
      },
      itemSlots = {
        slots = slots(),
        registration = {
          slot1 = markerImage("assets/generated/bag/registration-slot-1.png"),
          slot2 = markerImage("assets/generated/bag/registration-slot-2.png"),
          offset = { x = 0, y = 16 },
        },
      },
      pageIndicator = { rect = rect(80, 168, 56, 16), textAt = { x = 0, y = 0 } },
      cancel = { rect = rect(192, 168, 64, 24), textRect = rect(192, 168, 56, 16) },
      text = semanticText(),
      overlays = {
        actionMenu = {
          face = visualRef("assets/generated/bag/action-face.png"),
          slots = {
            { center = { x = 48, y = 144 }, textRect = rect(8, 136, 80, 16), hitRect = rect(0, 128, 94, 32) },
            { center = { x = 144, y = 144 }, textRect = rect(104, 136, 80, 16), hitRect = rect(96, 128, 96, 32) },
            { center = { x = 48, y = 176 }, textRect = rect(8, 168, 80, 16), hitRect = rect(0, 160, 94, 32) },
            { center = { x = 144, y = 176 }, textRect = rect(104, 168, 80, 16), hitRect = rect(96, 160, 96, 32) },
          },
        },
        quantity = {
          digits = { rect(128, 112, 16, 24), rect(160, 112, 16, 24), rect(192, 112, 16, 24) },
          controls = {
            { delta = 100, role = "increment", center = { x = 136, y = 104 }, hitRect = rect(120, 88, 32, 24) },
            { delta = 10, role = "increment", center = { x = 168, y = 104 }, hitRect = rect(152, 88, 32, 24) },
            { delta = 1, role = "increment", center = { x = 200, y = 104 }, hitRect = rect(184, 88, 32, 24) },
            { delta = -100, role = "decrement", center = { x = 136, y = 152 }, hitRect = rect(120, 136, 32, 24) },
            { delta = -10, role = "decrement", center = { x = 168, y = 152 }, hitRect = rect(152, 136, 32, 24) },
            { delta = -1, role = "decrement", center = { x = 200, y = 152 }, hitRect = rect(184, 136, 32, 24) },
          },
          visuals = {
            increment = {
              normal = visualRef("assets/generated/bag/quantity-increment-normal.png"),
              pressed = visualRef("assets/generated/bag/quantity-increment-pressed.png"),
            },
            decrement = {
              normal = visualRef("assets/generated/bag/quantity-decrement-normal.png"),
              pressed = visualRef("assets/generated/bag/quantity-decrement-pressed.png"),
            },
          },
          pressTicks = 2,
          confirm = {
            visual = visualRef("assets/generated/bag/quantity-confirm.png"),
            center = { x = 136, y = 176 },
            hitRect = rect(96, 168, 78, 24),
          },
          cancelHitRect = rect(178, 168, 78, 24),
        },
        descriptionFallback = { frame = rect(0, 144, 256, 48), textRect = rect(20, 144, 228, 40) },
      },
    },
  }
end

-- The semantic focus contract: four focus classes with exact target
-- cardinalities (eight tab targets, six item targets, one Cancel target,
-- four action targets). Pocket tabs carry only rects and normal art; the
-- retired highlight has no place in the generated manifest.
local function focusVisual(path)
  return { image = path, width = 32, height = 32 }
end

local function focusTargets()
  local tabTargets = {}
  for k = 0, 7 do
    tabTargets[#tabTargets + 1] = { x = 16 + 32 * k, y = 16 }
  end
  local items = {}
  for _, y in ipairs({ 56, 96, 136 }) do
    items[#items + 1] = { x = 48, y = y }
    items[#items + 1] = { x = 176, y = y }
  end
  return {
    tabs = tabTargets,
    items = items,
    cancel = { x = 224, y = 176 },
    actions = {
      { x = 48, y = 144 },
      { x = 144, y = 144 },
      { x = 48, y = 176 },
      { x = 144, y = 176 },
    },
  }
end

local function countVariantImage(pocket, count)
  return imageRef("assets/generated/bag/background-browse-" .. pocket .. "-count-" .. count .. ".png")
end

local function countVariantBackgrounds()
  local pockets = {}
  for _, pocket in ipairs(POCKETS) do
    local variants = {}
    for count = 0, 6 do
      variants[#variants + 1] = countVariantImage(pocket, count)
    end
    pockets[pocket] = variants
  end
  return pockets
end

local function framingRecord()
  return { angleXDegrees = 328.4, angleYDegrees = 28.3, distance = 21.2, modelY = -2.8 }
end

local function framingByGender()
  local byGender = {}
  for _, gender in ipairs({ "male", "female" }) do
    local records = {}
    for _, pocket in ipairs(POCKETS) do
      records[pocket] = framingRecord()
    end
    byGender[gender] = records
  end
  return byGender
end

local function stripVisual(pocket)
  return { image = "assets/generated/bag/tabs-" .. pocket .. ".png", width = 256, height = 32 }
end

local function retailEdgeColors()
  return {
    { r = 10, g = 10, b = 10 },
    { r = 15, g = 9, b = 4 },
    { r = 20, g = 20, b = 20 },
    { r = 0, g = 0, b = 0 },
    { r = 0, g = 0, b = 0 },
    { r = 0, g = 0, b = 0 },
    { r = 0, g = 0, b = 0 },
    { r = 0, g = 0, b = 0 },
  }
end

local function validFocusManifest()
  local manifest = validManifest()
  manifest.schema = "g4-bag-assets-v11"
  manifest.interactive.overlays.tossPrompt = { x = 200, y = 48, shape = "compact", initialSelection = "yes" }
  manifest.interactive.text.tossResult = {
    segments = {
      { kind = "text", value = "Threw away " },
      { kind = "quantity" },
      { kind = "text", value = " " },
      { kind = "item" },
      { kind = "text", value = "." },
    },
  }
  local icon = function(key)
    return { image = "assets/generated/bag/move-" .. key .. ".png", width = 64, height = 16 }
  end
  local typeIcons = {}
  for _, key in ipairs({
    "normal",
    "fighting",
    "flying",
    "poison",
    "ground",
    "rock",
    "bug",
    "ghost",
    "steel",
    "mystery",
    "fire",
    "water",
    "grass",
    "electric",
    "psychic",
    "ice",
    "dragon",
    "dark",
  }) do
    typeIcons[key] = icon(key)
  end
  manifest.hero.moveSummary = {
    background = imageRef("assets/generated/bag/hero-move-summary.png"),
    labels = {
      type = "TYPE",
      pp = "PP",
      category = "CATEGORY",
      power = "POWER",
      accuracy = "ACCURACY",
      unavailable = "---",
    },
    text = {
      type = { x = 0, y = 104 },
      pp = { x = 16, y = 120 },
      category = { x = 72, y = 104 },
      power = { x = 168, y = 104 },
      accuracy = { x = 168, y = 120 },
      ppValue = { x = 48, y = 120 },
      powerValue = { x = 232, y = 104 },
      accuracyValue = { x = 232, y = 120 },
    },
    typeCenter = { x = 48, y = 112 },
    categoryCenter = { x = 144, y = 112 },
    typeIcons = typeIcons,
    categoryIcons = { physical = icon("physical"), special = icon("special"), status = icon("status") },
  }
  manifest.interactive.backgrounds.browse = countVariantBackgrounds()
  manifest.interactive.cancel = {
    rect = rect(192, 168, 64, 24),
    textRect = rect(192, 168, 56, 16),
    labelRect = rect(200, 168, 48, 16),
  }
  manifest.hero.presentation.framing = {
    transitionTicks = 7,
    baseline = { male = framingRecord(), female = framingRecord() },
    byGender = framingByGender(),
  }
  manifest.hero.presentation.edgeColors = retailEdgeColors()
  local strips = {}
  for _, pocket in ipairs(POCKETS) do
    strips[pocket] = stripVisual(pocket)
  end
  manifest.interactive.pocketTabs = {
    rects = manifest.interactive.pocketTabs.rects,
    strips = strips,
  }
  local targets = focusTargets()
  manifest.interactive.focus = {
    tabs = { visual = focusVisual("assets/generated/bag/focus-tabs.png"), targets = targets.tabs },
    items = { visual = focusVisual("assets/generated/bag/focus-items.png"), targets = targets.items },
    cancel = { visual = focusVisual("assets/generated/bag/focus-cancel.png"), target = targets.cancel },
    actions = { visual = focusVisual("assets/generated/bag/focus-actions.png"), targets = targets.actions },
  }
  return manifest
end

function T.previous_manifest_fails_schema_and_cache_contract()
  local manifest = validManifest()
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "the previous highlight-shaped fixture is stale")
  Assert.isNil(manifest.interactive.widgets, "the stale manifest carries no dead widget namespace")
  Assert.equal(BagCache.manifestPath(), "data/generated/bag/manifest.lua")
  Assert.equal(DerivedAssetContract.bag.schema, "g4-bag-assets-v11")
end

function T.schema_rejects_wrong_logical_size()
  local manifest = validFocusManifest()
  manifest.logicalSize = { width = 512, height = 192 }
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "only the canonical pane size is valid")
end

function T.schema_rejects_out_of_bounds_rectangles()
  local manifest = validFocusManifest()
  manifest.interactive.cancel = rect(250, 168, 56, 16)
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "a rectangle escaping the pane must fail")
  manifest = validFocusManifest()
  manifest.interactive.pocketTabs.rects[8] = rect(224, 0, 33, 32)
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "an overflowing tab must fail")
end

function T.schema_rejects_wrong_tab_and_slot_cardinality()
  local manifest = validFocusManifest()
  manifest.interactive.pocketTabs.rects[8] = nil
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "seven tabs must fail")
  manifest = validFocusManifest()
  manifest.interactive.itemSlots.slots[7] = manifest.interactive.itemSlots.slots[1]
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "seven slots must fail")
end

function T.schema_rejects_missing_hero_model_and_clips()
  local manifest = validFocusManifest()
  manifest.hero.model.female = nil
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "both gender models are required")
  manifest = validFocusManifest()
  manifest.hero.animations.states[3].pose = "pocket.medicine.pose.missing"
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "an unresolvable pose clip must fail")
  manifest = validFocusManifest()
  manifest.hero.animations.material.male = "male.material.missing"
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "an unresolvable material clip must fail")
end

function T.schema_rejects_source_identities_in_the_runtime_manifest()
  local manifest = validFocusManifest()
  manifest.hero.presentation.camera.target = { x = 0, y = 0, z = 0, memberId = 55 }
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "a member identity must fail")
  manifest = validFocusManifest()
  manifest.interactive.backgrounds.browse = {
    image = "assets/generated/bag/list-slots.png",
    width = 256,
    height = 192,
    narcId = 15,
  }
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "an archive identity must fail")
end

function T.cache_reports_ready_only_with_every_referenced_file()
  local manifest = validFocusManifest()
  local marker = BagCache.marker("deadbeef", "feedface")
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  cacheFs:writeLua(BagCache.manifestPath(), manifest)
  for _, path in ipairs(BagCache.referencedPaths(manifest)) do
    cacheFs:write(path, "payload")
  end
  cacheFs:writeLua(BagCache.provenancePath(), { cacheFormat = BagCache.FORMAT, schema = BagCache.SCHEMA })
  cacheFs:write(BagCache.markerPath(), marker)
  Assert.isTrue(BagCache.isReady(cacheFs, marker))
  cacheFs:remove("assets/generated/bag/tabs-mail.png")
  Assert.isFalse(BagCache.isReady(cacheFs, marker), "a missing tab image is not ready")
end

function T.old_cache_marker_forces_a_rebuild()
  local manifest = validFocusManifest()
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  for _, path in ipairs(BagCache.referencedPaths(manifest)) do
    cacheFs:write(path, "payload")
  end
  cacheFs:writeLua(BagCache.manifestPath(), manifest)
  local oldMarker = "bag-cache-v1:deadbeef:feedface"
  cacheFs:write(BagCache.markerPath(), oldMarker)
  Assert.isFalse(BagCache.isReady(cacheFs, oldMarker), "a previous cache marker must not read as current ready")
end

local function assertInvalid(manifest, why)
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), why)
end

function T.schema_identity_is_the_current_contract()
  Assert.equal(BagAssetSchema.SCHEMA, "g4-bag-assets-v11")
  Assert.equal(DerivedAssetContract.bag.schema, "g4-bag-assets-v11")
  Assert.equal(BagCache.SCHEMA, "g4-bag-assets-v11")
  Assert.equal(BagCache.FORMAT, "bag-cache-v2")
end

function T.previous_bag_contract_is_rejected()
  local manifest = validFocusManifest()
  manifest.schema = "g4-bag-assets-v2"
  Assert.isFalse(BagAssetSchema.isValidManifest(manifest), "the previous Bag contract must not validate as current")
  local retired = validFocusManifest()
  retired.schema = "g4-bag-assets-v3"
  Assert.isFalse(BagAssetSchema.isValidManifest(retired), "the retired Bag contract must not validate as current")
  local superseded = validFocusManifest()
  superseded.schema = "g4-bag-assets-v4"
  Assert.isFalse(BagAssetSchema.isValidManifest(superseded), "the superseded Bag contract must not validate as current")
  local stale = validFocusManifest()
  stale.schema = "g4-bag-assets-v5"
  Assert.isFalse(
    BagAssetSchema.isValidManifest(stale),
    "the highlight-shaped Bag contract must not validate as current"
  )
  local singleBrowse = validFocusManifest()
  singleBrowse.schema = "g4-bag-assets-v6"
  Assert.isFalse(
    BagAssetSchema.isValidManifest(singleBrowse),
    "the single-browse-visual Bag contract must not validate as current"
  )
  local perTabNormal = validFocusManifest()
  perTabNormal.schema = "g4-bag-assets-v7"
  Assert.isFalse(
    BagAssetSchema.isValidManifest(perTabNormal),
    "the per-tab-normal Bag contract must not validate once strips are current"
  )
end

function T.complete_manifest_with_text_and_registration_passes()
  local manifest = validFocusManifest()
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest), "the complete fixture must pass")
end

function T.incomplete_manifest_is_rejected()
  local manifest = validFocusManifest()
  manifest.schema = "g4-bag-assets-v1"
  manifest.interactive.text = nil
  manifest.interactive.itemSlots.registration = nil
  manifest.interactive.backgrounds = nil
  assertInvalid(manifest, "a manifest without semantic text and registration markers is stale")
end

function T.manifest_without_semantic_text_is_rejected()
  local manifest = validFocusManifest()
  manifest.interactive.text = nil
  assertInvalid(manifest, "semantic action labels and templates are mandatory")
end

function T.manifest_without_registration_markers_is_rejected()
  local manifest = validFocusManifest()
  manifest.interactive.itemSlots.registration = nil
  assertInvalid(manifest, "both registration markers are mandatory")
end

function T.every_action_label_is_required_and_non_empty()
  for _, action in ipairs({ "toss", "move", "register", "unregister", "cancel", "confirm" }) do
    local missing = validFocusManifest()
    missing.interactive.text.actions[action] = nil
    assertInvalid(missing, "a missing " .. action .. " label must fail")
    local empty = validFocusManifest()
    empty.interactive.text.actions[action] = ""
    assertInvalid(empty, "an empty " .. action .. " label must fail")
  end
end

function T.unknown_action_and_template_fields_are_rejected()
  local extraAction = validFocusManifest()
  extraAction.interactive.text.actions.use = "USE"
  assertInvalid(extraAction, "an action outside the runtime vocabulary must fail")
  local extraTemplate = validFocusManifest()
  extraTemplate.interactive.text.inspectPrompt = { segments = { { kind = "text", value = "?" } } }
  assertInvalid(extraTemplate, "a template outside the runtime vocabulary must fail")
  local extraField = validFocusManifest()
  extraField.interactive.text.bank = 10
  assertInvalid(extraField, "producer-side message selection must not leak into the manifest")
end

function T.template_segments_are_strict()
  local empty = validFocusManifest()
  empty.interactive.text.movePrompt = { segments = {} }
  assertInvalid(empty, "a template with no segments must fail")
  local missingValue = validFocusManifest()
  missingValue.interactive.text.movePrompt = { segments = { { kind = "text" } } }
  assertInvalid(missingValue, "a text segment without a value must fail")
  local emptyValue = validFocusManifest()
  emptyValue.interactive.text.movePrompt = { segments = { { kind = "text", value = "" } } }
  assertInvalid(emptyValue, "an empty text value must fail")
  local unknownKind = validFocusManifest()
  unknownKind.interactive.text.movePrompt = { segments = { { kind = "icon" } } }
  assertInvalid(unknownKind, "an unknown segment kind must fail")
  local itemExtra = validFocusManifest()
  itemExtra.interactive.text.movePrompt = { segments = { { kind = "item", value = "Potion" } } }
  assertInvalid(itemExtra, "an item segment must carry no extra fields")
  local quantityExtra = validFocusManifest()
  quantityExtra.interactive.text.tossConfirm = {
    segments = { { kind = "quantity", count = 1 } },
  }
  assertInvalid(quantityExtra, "a quantity segment must carry no extra fields")
end

function T.registration_markers_are_exactly_sized()
  local wide = validFocusManifest()
  wide.interactive.itemSlots.registration.slot1 = markerImage("assets/generated/bag/registration-slot-1.png")
  wide.interactive.itemSlots.registration.slot1.width = 41
  assertInvalid(wide, "a 41-pixel marker must fail")
  local short = validFocusManifest()
  short.interactive.itemSlots.registration.slot2 = markerImage("assets/generated/bag/registration-slot-2.png")
  short.interactive.itemSlots.registration.slot2.height = 15
  assertInvalid(short, "a 15-pixel marker must fail")
end

function T.registration_offset_keeps_the_marker_inside_every_slot()
  local paneFittingButSlotOverflowing = validFocusManifest()
  paneFittingButSlotOverflowing.interactive.itemSlots.registration.offset = { x = 200, y = 0 }
  assertInvalid(paneFittingButSlotOverflowing, "an offset that pushes the 40x16 marker outside an 88x32 slot must fail")
  local bottomOverflowing = validFocusManifest()
  bottomOverflowing.interactive.itemSlots.registration.offset = { x = 0, y = 21 }
  assertInvalid(bottomOverflowing, "an offset that pushes the marker below the slot must fail")
  local missing = validFocusManifest()
  missing.interactive.itemSlots.registration.offset = nil
  assertInvalid(missing, "a missing registration offset must fail")
end

function T.quantity_background_is_a_required_semantic_surface()
  local single = validFocusManifest()
  single.interactive.backgrounds.quantity = nil
  assertInvalid(single, "a missing quantity background must fail")
  local missing = validFocusManifest()
  missing.interactive.backgrounds.quantity.items.width = 128
  assertInvalid(missing, "a non-canonical quantity background must fail")
end

function T.hero_light_vectors_are_a_required_static_quadruple()
  local missing = validFocusManifest()
  missing.hero.presentation.lights.vectors = nil
  assertInvalid(missing, "missing hero light vectors must fail")
  local short = validFocusManifest()
  short.hero.presentation.lights.vectors = {
    { x = 1, y = 0, z = 0 },
    { x = 1, y = 0, z = 0 },
    { x = 1, y = 0, z = 0 },
  }
  assertInvalid(short, "three hero light vectors must fail")
  local ragged = validFocusManifest()
  ragged.hero.presentation.lights.vectors[2] = { x = 1, y = 0 }
  assertInvalid(ragged, "a hero light vector without depth must fail")
  local infinite = validFocusManifest()
  infinite.hero.presentation.lights.vectors[1] = { x = math.huge, y = 0, z = 0 }
  assertInvalid(infinite, "a non-finite hero light vector must fail")
  local leaky = validFocusManifest()
  leaky.hero.presentation.lights.vectors[4] = { x = 1, y = 0, z = 0, memberId = 37 }
  assertInvalid(leaky, "a source identity inside a hero light vector must fail")
  local extra = validFocusManifest()
  extra.hero.presentation.lights.kind = "static"
  assertInvalid(extra, "an unknown hero lights field must fail")
  for _, count in ipairs({ 3, 5 }) do
    local wrongCount = validFocusManifest()
    wrongCount.hero.presentation.lights.count = count
    assertInvalid(wrongCount, "exactly four hero lights are required")
  end
end

function T.hero_material_registers_are_a_required_static_quadruple()
  local missing = validFocusManifest()
  missing.hero.presentation.materials = nil
  assertInvalid(missing, "missing hero material registers must fail")
  local short = validFocusManifest()
  short.hero.presentation.materials = {
    diffuse = { r = 15, g = 15, b = 15 },
    ambient = { r = 10, g = 10, b = 10 },
    specular = { r = 15, g = 15, b = 15 },
  }
  assertInvalid(short, "three hero material registers must fail")
  local ragged = validFocusManifest()
  ragged.hero.presentation.materials.ambient = { r = 10, g = 10 }
  assertInvalid(ragged, "a hero material register without blue must fail")
  local overflow = validFocusManifest()
  overflow.hero.presentation.materials.diffuse = { r = 32, g = 15, b = 15 }
  assertInvalid(overflow, "a hero material channel past 31 must fail")
  local extra = validFocusManifest()
  extra.hero.presentation.materials.kind = "static"
  assertInvalid(extra, "an unknown hero materials field must fail")
end

function T.source_identities_are_rejected_inside_the_new_records()
  local memberLeak = validFocusManifest()
  memberLeak.interactive.itemSlots.registration.slot1 = {
    image = "assets/generated/bag/registration-slot-1.png",
    width = 40,
    height = 16,
    memberId = 37,
  }
  assertInvalid(memberLeak, "a source member identity must fail")
  local segmentLeak = validFocusManifest()
  segmentLeak.interactive.text.movePrompt = {
    segments = { { kind = "text", value = "Move", memberId = 37 } },
  }
  assertInvalid(segmentLeak, "a source identity inside a template segment must fail")
end

function T.cache_references_both_registration_markers()
  local manifest = validFocusManifest()
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
  local backgroundTimeline = validFocusManifest()
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
  assertInvalid(
    backgroundTimeline,
    "a background frame timeline must fail; the current contract publishes static realizations"
  )
  local tabTimeline = validFocusManifest()
  tabTimeline.interactive.pocketTabs.strips.items = {
    image = "assets/generated/bag/tabs-items.png",
    width = 256,
    height = 32,
    duration = 2,
  }
  assertInvalid(tabTimeline, "a duration on a strip visual must fail")
  local durationOnStatic = validFocusManifest()
  durationOnStatic.interactive.itemSlots.focus = {
    image = "assets/generated/bag/focus-frame-1.png",
    width = 16,
    height = 16,
    duration = 2,
  }
  assertInvalid(durationOnStatic, "a duration on a static visual must fail")
end

function T.retired_widget_namespace_is_rejected_as_unknown()
  local withWidgets = validFocusManifest()
  withWidgets.interactive.widgets = {
    sourceStrip = {
      image = "assets/generated/bag/source-strip-frame-1.png",
      width = 32,
      height = 16,
      placement = { x = 177, y = 14 },
      states = { browsing = false },
    },
  }
  assertInvalid(withWidgets, "a retired widget namespace must fail as an unknown field")
end

function T.cache_references_only_live_assets()
  local manifest = validFocusManifest()
  local ok, paths = pcall(BagCache.referencedPaths, manifest)
  Assert.isTrue(ok, "the cache must resolve the current manifest")
  assert(paths ~= nil, "a resolvable manifest must list its paths")
  local seen = {}
  for _, path in ipairs(paths) do
    seen[path] = true
  end
  Assert.isTrue(seen["assets/generated/bag/registration-slot-1.png"], "slot 1 marker must be referenced")
  Assert.isTrue(seen["assets/generated/bag/tabs-items.png"], "pocket strips must be referenced")
  for _, path in ipairs(paths) do
    Assert.isNil(path:find("tab-normal-", 1, true), "no referenced path may belong to the retired per-tab art")
  end
end

function T.semantic_focus_contract_validates_with_exact_target_counts()
  local manifest = validFocusManifest()
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest), "the focus manifest must pass the schema")
  Assert.keySet(manifest.interactive.pocketTabs, "rects,strips", "pocket tabs carry only rects and strips")
  Assert.keySet(manifest.interactive.focus, "actions,cancel,items,tabs", "focus carries exactly four classes")
  Assert.equal(#manifest.interactive.focus.tabs.targets, 8, "eight tab targets are required")
  Assert.equal(#manifest.interactive.focus.items.targets, 6, "six item targets are required")
  Assert.equal(#manifest.interactive.focus.actions.targets, 4, "four action targets are required")
end

function T.control_visuals_are_current_and_each_is_referenced_once()
  local manifest = validFocusManifest()
  local paths = assert(BagCache.referencedPaths(manifest))
  local counts = {}
  for _, path in ipairs(paths) do
    counts[path] = (counts[path] or 0) + 1
  end
  for _, path in ipairs({
    "assets/generated/bag/action-face.png",
    "assets/generated/bag/quantity-increment-normal.png",
    "assets/generated/bag/quantity-increment-pressed.png",
    "assets/generated/bag/quantity-decrement-normal.png",
    "assets/generated/bag/quantity-decrement-pressed.png",
    "assets/generated/bag/quantity-confirm.png",
  }) do
    Assert.equal(counts[path], 1, path .. " is referenced exactly once")
  end
  for _, path in ipairs(paths) do
    Assert.isNil(path:find("quantity-alt", 1, true), "retired quantity alternate art is not required")
  end
end

function T.control_overlay_rejects_incomplete_or_timeline_shapes()
  local missingSlotField = validFocusManifest()
  missingSlotField.interactive.overlays.actionMenu.slots[1].center = nil
  assertInvalid(missingSlotField, "an action slot without a center must fail")
  local wrongControlOrder = validFocusManifest()
  wrongControlOrder.interactive.overlays.quantity.controls[1].delta = 10
  assertInvalid(wrongControlOrder, "quantity controls must keep their source order")
  local alternateDuration = validFocusManifest()
  alternateDuration.interactive.overlays.quantity.pressTicks = 3
  Assert.isTrue(BagAssetSchema.isValidManifest(alternateDuration), "a positive press duration stays consumable")
  local timeline = validFocusManifest()
  timeline.interactive.overlays.quantity.visuals.increment.normal.frames = {}
  assertInvalid(timeline, "a quantity visual timeline must fail")
  local stale = validFocusManifest()
  stale.schema = "g4-bag-assets-v8"
  assertInvalid(stale, "the retired Bag contract must fail")
end

function T.stale_previous_manifest_fails_once_the_focus_contract_is_current()
  Assert.equal(BagAssetSchema.SCHEMA, "g4-bag-assets-v11", "the schema carries the move summary contract")
  Assert.equal(
    DerivedAssetContract.bag.schema,
    "g4-bag-assets-v11",
    "the central contract carries the move summary schema"
  )
  Assert.equal(BagCache.SCHEMA, "g4-bag-assets-v11", "the loader requires the move summary schema")
  Assert.equal(BagCache.FORMAT, "bag-cache-v2", "the cache framing is unchanged")
  Assert.isFalse(
    BagAssetSchema.isValidManifest(validManifest()),
    "the previous highlight-shaped manifest must not validate as current"
  )
end

function T.focus_target_counts_and_bounds_are_strict()
  local shortTabs = validFocusManifest()
  shortTabs.interactive.focus.tabs.targets[8] = nil
  assertInvalid(shortTabs, "seven tab targets must fail")
  local longItems = validFocusManifest()
  longItems.interactive.focus.items.targets[7] = longItems.interactive.focus.items.targets[1]
  assertInvalid(longItems, "seven item targets must fail")
  local missingCancel = validFocusManifest()
  missingCancel.interactive.focus.cancel = nil
  assertInvalid(missingCancel, "a missing Cancel focus class must fail")
  local shortActions = validFocusManifest()
  shortActions.interactive.focus.actions.targets[4] = nil
  assertInvalid(shortActions, "three action targets must fail")
  local escaped = validFocusManifest()
  escaped.interactive.focus.tabs.targets[8] = { x = 256, y = 200 }
  assertInvalid(escaped, "a focus target outside the canonical pane must fail")
  local extraClass = validFocusManifest()
  extraClass.interactive.focus.extra = { visual = focusVisual("assets/generated/bag/focus-extra.png"), targets = {} }
  assertInvalid(extraClass, "a fifth focus class must fail")
  local highlightAlias = validFocusManifest()
  highlightAlias.interactive.pocketTabs.highlight = visualRef("assets/generated/bag/tab-highlight-frame-1.png")
  assertInvalid(highlightAlias, "the retired tab highlight must fail as an unknown field")
end

function T.focus_visual_timelines_and_source_identities_are_rejected()
  local timeline = validFocusManifest()
  timeline.interactive.focus.items.visual = {
    image = "assets/generated/bag/focus-items.png",
    width = 32,
    height = 32,
    duration = 2,
  }
  assertInvalid(timeline, "a duration on a focus visual must fail")
  local frames = validFocusManifest()
  frames.interactive.focus.tabs = {
    frames = { { image = "assets/generated/bag/focus-tabs.png", width = 32, height = 32, duration = 2 } },
  }
  assertInvalid(frames, "a focus frame timeline must fail")
  local leaked = validFocusManifest()
  leaked.interactive.focus.cancel.visual = {
    image = "assets/generated/bag/focus-cancel.png",
    width = 32,
    height = 32,
    animIndex = 17,
  }
  assertInvalid(leaked, "a source animation identity inside a focus visual must fail")
end

function T.cache_readiness_owns_every_focus_visual()
  local manifest = validFocusManifest()
  local ok, paths = pcall(BagCache.referencedPaths, manifest)
  Assert.isTrue(ok, "the cache must resolve the focus manifest")
  assert(paths ~= nil, "a resolvable manifest must list its paths")
  local counts = {}
  for _, path in ipairs(paths) do
    counts[path] = (counts[path] or 0) + 1
  end
  for _, path in ipairs({
    "assets/generated/bag/focus-tabs.png",
    "assets/generated/bag/focus-items.png",
    "assets/generated/bag/focus-cancel.png",
    "assets/generated/bag/focus-actions.png",
  }) do
    Assert.equal(counts[path], 1, path .. " must be referenced exactly once")
  end
  Assert.isNil(counts["assets/generated/bag/tab-highlight-frame-1.png"], "no retired highlight path may survive")
end

local function validDynamicManifest()
  local manifest = validFocusManifest()
  return manifest
end

function T.browse_backgrounds_carry_seven_count_variants_per_pocket()
  local manifest = validDynamicManifest()
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest), "the seven-variant browse presentation must validate")
  for _, pocket in ipairs(POCKETS) do
    local variants = assert(
      manifest.interactive.backgrounds.browse[pocket],
      "pocket " .. pocket .. " must publish its browse count variants"
    )
    Assert.equal(#variants, 7, "pocket " .. pocket .. " publishes one browse visual per visible count 0..6")
    for count = 0, 6 do
      local visual = assert(variants[count + 1], "pocket " .. pocket .. " publishes its count " .. count .. " visual")
      Assert.equal(visual.width, 256, "pocket " .. pocket .. " count " .. count .. " keeps the pane width")
      Assert.equal(visual.height, 192, "pocket " .. pocket .. " count " .. count .. " keeps the pane height")
    end
  end
  local ok, paths = pcall(BagCache.referencedPaths, manifest)
  Assert.isTrue(ok, "the cache must resolve the seven-variant manifest")
  assert(paths ~= nil, "a resolvable manifest must list its paths")
  local counts = {}
  for _, path in ipairs(paths) do
    counts[path] = (counts[path] or 0) + 1
  end
  local browsePaths = 0
  for _, path in ipairs(paths) do
    if path:find("background-browse-", 1, true) ~= nil then
      browsePaths = browsePaths + 1
    end
  end
  Assert.equal(browsePaths, 56, "all seven variants of all eight pockets participate in readiness")
  for _, pocket in ipairs(POCKETS) do
    for count = 0, 6 do
      local path = "assets/generated/bag/background-browse-" .. pocket .. "-count-" .. count .. ".png"
      Assert.equal(counts[path], 1, path .. " must be referenced exactly once")
    end
  end
end

function T.cancel_label_area_is_centered_on_the_cancel_face()
  local manifest = validDynamicManifest()
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest), "the centered cancel label area must validate")
  local cancel = assert(manifest.interactive.cancel, "the manifest must publish cancel geometry")
  Assert.deepEqual(
    cancel.labelRect,
    { x = 200, y = 168, width = 48, height = 16 },
    "the cancel label area keeps the source centering span"
  )
  Assert.equal(
    cancel.labelRect.x + cancel.labelRect.width / 2,
    224,
    "the label area centers on the middle of the cancel face"
  )
  Assert.isTrue(
    cancel.labelRect.x >= cancel.rect.x
      and cancel.labelRect.y >= cancel.rect.y
      and cancel.labelRect.x + cancel.labelRect.width <= cancel.rect.x + cancel.rect.width
      and cancel.labelRect.y + cancel.labelRect.height <= cancel.rect.y + cancel.rect.height,
    "the label area stays inside the cancel control"
  )
end

function T.hero_framing_carries_baseline_and_pocket_records_for_both_genders()
  local manifest = validDynamicManifest()
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest), "the pocket-aware hero framing must validate")
  local framing = assert(manifest.hero.presentation.framing, "the hero presentation must publish its pocket framing")
  Assert.equal(framing.transitionTicks, 7, "the framing transition keeps its fixed-tick duration")
  for _, gender in ipairs({ "male", "female" }) do
    local baseline = assert(framing.baseline[gender], gender .. " publishes its baseline framing record")
    local pockets = assert(framing.byGender[gender], gender .. " publishes its pocket framing records")
    local seen = 0
    for _, pocket in ipairs(POCKETS) do
      local record = assert(pockets[pocket], gender .. " publishes the " .. pocket .. " framing record")
      seen = seen + 1
      for _, field in ipairs({ "angleXDegrees", "angleYDegrees", "distance", "modelY" }) do
        local value = record[field]
        Assert.isTrue(
          type(value) == "number" and value == value and value < math.huge and value > -math.huge,
          gender .. " " .. pocket .. " framing " .. field .. " must be a finite number"
        )
      end
    end
    Assert.equal(seen, 8, gender .. " publishes all eight pocket framing records")
    for _, field in ipairs({ "angleXDegrees", "angleYDegrees", "distance", "modelY" }) do
      local value = baseline[field]
      Assert.isTrue(
        type(value) == "number" and value == value and value < math.huge and value > -math.huge,
        gender .. " baseline framing " .. field .. " must be a finite number"
      )
    end
  end
end

function T.browse_variant_arrays_reject_any_count_but_seven()
  local manifest = validDynamicManifest()
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest), "the seven-variant manifest must validate")
  local short = validDynamicManifest()
  short.interactive.backgrounds.browse.items[7] = nil
  Assert.isFalse(BagAssetSchema.isValidManifest(short), "six browse variants must fail")
  local long = validDynamicManifest()
  long.interactive.backgrounds.browse.items[8] = countVariantImage("items", 7)
  Assert.isFalse(BagAssetSchema.isValidManifest(long), "eight browse variants must fail")
  local missing = validDynamicManifest()
  missing.interactive.backgrounds.browse.mail = nil
  Assert.isFalse(BagAssetSchema.isValidManifest(missing), "a pocket without browse variants must fail")
  local single = validDynamicManifest()
  single.interactive.backgrounds.browse.items = countVariantImage("items", 6)
  Assert.isFalse(
    BagAssetSchema.isValidManifest(single),
    "a single browse visual must fail; every pocket carries seven count variants"
  )
end

function T.cancel_label_area_rejects_missing_and_misplaced_spans()
  local manifest = validDynamicManifest()
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest), "the centered cancel label area must validate")
  local missing = validDynamicManifest()
  missing.interactive.cancel.labelRect = nil
  Assert.isFalse(BagAssetSchema.isValidManifest(missing), "a cancel control without a label area must fail")
  local stale = validDynamicManifest()
  stale.interactive.cancel = {
    rect = rect(192, 168, 64, 24),
    textRect = rect(192, 168, 56, 16),
  }
  Assert.isFalse(
    BagAssetSchema.isValidManifest(stale),
    "the previous text-window-only cancel shape must fail once the label area is current"
  )
  local offCenter = validDynamicManifest()
  offCenter.interactive.cancel.labelRect = rect(192, 168, 48, 16)
  Assert.isFalse(BagAssetSchema.isValidManifest(offCenter), "a label area off the face center must fail")
  local escaping = validDynamicManifest()
  escaping.interactive.cancel.labelRect = rect(208, 168, 48, 16)
  Assert.isFalse(BagAssetSchema.isValidManifest(escaping), "a label area escaping the cancel control must fail")
end

function T.hero_framing_rejects_incomplete_and_nonfinite_records()
  local manifest = validDynamicManifest()
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest), "the pocket-aware hero framing must validate")
  local missingGender = validDynamicManifest()
  missingGender.hero.presentation.framing.byGender.female = nil
  Assert.isFalse(BagAssetSchema.isValidManifest(missingGender), "framing without both genders must fail")
  local missingPocket = validDynamicManifest()
  missingPocket.hero.presentation.framing.byGender.male.mail = nil
  Assert.isFalse(BagAssetSchema.isValidManifest(missingPocket), "framing without all eight pockets must fail")
  local missingBaseline = validDynamicManifest()
  missingBaseline.hero.presentation.framing.baseline.male = nil
  Assert.isFalse(BagAssetSchema.isValidManifest(missingBaseline), "framing without a baseline record must fail")
  local infinite = validDynamicManifest()
  infinite.hero.presentation.framing.byGender.female.items.distance = math.huge
  Assert.isFalse(BagAssetSchema.isValidManifest(infinite), "a non-finite framing distance must fail")
  local notANumber = validDynamicManifest()
  notANumber.hero.presentation.framing.baseline.female.angleXDegrees = 0 / 0
  Assert.isFalse(BagAssetSchema.isValidManifest(notANumber), "a non-numeric framing angle must fail")
  local alternateDuration = validDynamicManifest()
  alternateDuration.hero.presentation.framing.transitionTicks = 8
  Assert.isTrue(BagAssetSchema.isValidManifest(alternateDuration), "a positive transition duration stays consumable")
  local noDuration = validDynamicManifest()
  noDuration.hero.presentation.framing.transitionTicks = 0
  Assert.isFalse(BagAssetSchema.isValidManifest(noDuration), "a non-positive transition duration must fail")
  local staticOnly = validDynamicManifest()
  staticOnly.hero.presentation.framing = nil
  Assert.isFalse(
    BagAssetSchema.isValidManifest(staticOnly),
    "a hero presentation without pocket framing must fail once framing is current"
  )
end

function T.previous_browse_contract_is_rejected()
  local stale = validDynamicManifest()
  stale.schema = "g4-bag-assets-v6"
  stale.interactive.backgrounds.browse = {
    items = countVariantImage("items", 6),
    medicine = countVariantImage("medicine", 6),
    balls = countVariantImage("balls", 6),
    tmhm = countVariantImage("tmhm", 6),
    berries = countVariantImage("berries", 6),
    mail = countVariantImage("mail", 6),
    battle_items = countVariantImage("battle_items", 6),
    key_items = countVariantImage("key_items", 6),
  }
  stale.interactive.cancel = {
    rect = rect(192, 168, 64, 24),
    textRect = rect(192, 168, 56, 16),
  }
  stale.hero.presentation.framing = nil
  Assert.isFalse(
    BagAssetSchema.isValidManifest(stale),
    "the single-browse-visual manifest must not validate once count variants are current"
  )
end

function T.cache_readiness_requires_every_browse_variant()
  local manifest = validDynamicManifest()
  local marker = BagCache.marker("deadbeef", "feedface")
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  cacheFs:writeLua(BagCache.manifestPath(), manifest)
  local ok, paths = pcall(BagCache.referencedPaths, manifest)
  Assert.isTrue(ok, "the cache must resolve the seven-variant manifest")
  assert(paths ~= nil, "a resolvable manifest must list its paths")
  for _, path in ipairs(paths) do
    cacheFs:write(path, "payload")
  end
  cacheFs:writeLua(BagCache.provenancePath(), { cacheFormat = BagCache.FORMAT, schema = BagCache.SCHEMA })
  cacheFs:write(BagCache.markerPath(), marker)
  Assert.isTrue(BagCache.isReady(cacheFs, marker), "the complete seven-variant class is ready")
  cacheFs:remove("assets/generated/bag/background-browse-mail-count-3.png")
  Assert.isFalse(BagCache.isReady(cacheFs, marker), "a missing browse count variant is not ready")
end

-- The strip contract is the current focus-manifest shape above.
local function validStripManifest()
  return validFocusManifest()
end

function T.pocket_strips_and_edge_colors_validate_as_the_current_contract()
  Assert.equal(BagAssetSchema.SCHEMA, "g4-bag-assets-v11")
  Assert.equal(DerivedAssetContract.bag.schema, "g4-bag-assets-v11")
  Assert.equal(BagCache.SCHEMA, "g4-bag-assets-v11")
  Assert.equal(BagCache.FORMAT, "bag-cache-v2")
  local manifest = validStripManifest()
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest), "the pocket-strip manifest must pass the schema")
  Assert.keySet(manifest.interactive.pocketTabs, "rects,strips", "pocket tabs carry only rects and strips")
  local retired = validFocusManifest()
  retired.schema = "g4-bag-assets-v7"
  retired.interactive.pocketTabs = {
    rects = retired.interactive.pocketTabs.rects,
    normal = {
      stripVisual("items"),
      stripVisual("medicine"),
      stripVisual("balls"),
      stripVisual("tmhm"),
      stripVisual("berries"),
      stripVisual("mail"),
      stripVisual("battle_items"),
      stripVisual("key_items"),
    },
  }
  Assert.isFalse(
    BagAssetSchema.isValidManifest(retired),
    "the previous per-tab normal manifest must not validate once strips are current"
  )
end

function T.previous_normal_tab_shape_is_rejected()
  local withNormal = validStripManifest()
  withNormal.interactive.pocketTabs.normal = withNormal.interactive.pocketTabs.strips.items
  withNormal.interactive.pocketTabs.strips = nil
  assertInvalid(withNormal, "a v7-style normal tab array must fail once strips are current")
  local both = validStripManifest()
  both.interactive.pocketTabs.normal = {
    stripVisual("items"),
    stripVisual("medicine"),
    stripVisual("balls"),
    stripVisual("tmhm"),
    stripVisual("berries"),
    stripVisual("mail"),
    stripVisual("battle_items"),
    stripVisual("key_items"),
  }
  assertInvalid(both, "normal art alongside strips must fail; generated data is rebuildable")
end

function T.strip_pockets_and_dimensions_are_exact()
  local missing = validStripManifest()
  missing.interactive.pocketTabs.strips.mail = nil
  assertInvalid(missing, "a strip record without all eight pockets must fail")
  local extra = validStripManifest()
  extra.interactive.pocketTabs.strips.extra = stripVisual("items")
  assertInvalid(extra, "a strip record with an extra pocket must fail")
  local narrow = validStripManifest()
  narrow.interactive.pocketTabs.strips.items =
    { image = "assets/generated/bag/tabs-items.png", width = 128, height = 32 }
  assertInvalid(narrow, "a strip narrower than the canonical strip must fail")
  local short = validStripManifest()
  short.interactive.pocketTabs.strips.items =
    { image = "assets/generated/bag/tabs-items.png", width = 256, height = 16 }
  assertInvalid(short, "a strip shorter than the canonical strip must fail")
  local timeline = validStripManifest()
  timeline.interactive.pocketTabs.strips.items = {
    image = "assets/generated/bag/tabs-items.png",
    width = 256,
    height = 32,
    duration = 2,
  }
  assertInvalid(timeline, "a duration on a strip visual must fail")
end

function T.hero_edge_colors_are_a_required_eight_record_table()
  local missing = validStripManifest()
  missing.hero.presentation.edgeColors = nil
  assertInvalid(missing, "a hero presentation without edge colors must fail")
  local short = validStripManifest()
  short.hero.presentation.edgeColors[8] = nil
  assertInvalid(short, "seven edge colors must fail")
  local long = validStripManifest()
  long.hero.presentation.edgeColors[9] = { r = 0, g = 0, b = 0 }
  assertInvalid(long, "nine edge colors must fail")
  local overflow = validStripManifest()
  overflow.hero.presentation.edgeColors[1] = { r = 32, g = 10, b = 10 }
  assertInvalid(overflow, "an edge channel past 31 must fail")
  local ragged = validStripManifest()
  ragged.hero.presentation.edgeColors[2] = { r = 15, g = 9 }
  assertInvalid(ragged, "an edge record without blue must fail")
  local extra = validStripManifest()
  extra.hero.presentation.edgeColors[3] = { r = 20, g = 20, b = 20, memberId = 37 }
  assertInvalid(extra, "a source identity inside an edge record must fail")
end

function T.cache_readiness_requires_every_pocket_strip()
  local manifest = validStripManifest()
  local marker = BagCache.marker("deadbeef", "feedface")
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  cacheFs:writeLua(BagCache.manifestPath(), manifest)
  local ok, paths = pcall(BagCache.referencedPaths, manifest)
  Assert.isTrue(ok, "the cache must resolve the strip manifest")
  assert(paths ~= nil, "a resolvable manifest must list its paths")
  local counts = {}
  for _, path in ipairs(paths) do
    counts[path] = (counts[path] or 0) + 1
  end
  for _, pocket in ipairs(POCKETS) do
    Assert.equal(counts["assets/generated/bag/tabs-" .. pocket .. ".png"], 1, pocket .. " strip is referenced once")
  end
  for _, path in ipairs(paths) do
    Assert.isNil(path:find("tab-normal-", 1, true), "no retired per-tab normal path may remain referenced")
    cacheFs:write(path, "payload")
  end
  cacheFs:writeLua(BagCache.provenancePath(), { cacheFormat = BagCache.FORMAT, schema = BagCache.SCHEMA })
  cacheFs:write(BagCache.markerPath(), marker)
  Assert.isTrue(BagCache.isReady(cacheFs, marker), "the complete strip class is ready")
  cacheFs:remove("assets/generated/bag/tabs-mail.png")
  Assert.isFalse(BagCache.isReady(cacheFs, marker), "a missing pocket strip is not ready")
end

-- The toss contract under test: the current focus fixture plus the
-- semantic prompt placement and the post-choice result text on the
-- bumped schema. Only the new toss scenarios build on it; every other
-- scenario keeps the versioned focus fixture above.
local function validTossManifest()
  local manifest = validFocusManifest()
  manifest.schema = "g4-bag-assets-v11"
  manifest.interactive.overlays.tossPrompt = { x = 200, y = 48, shape = "compact", initialSelection = "yes" }
  manifest.interactive.text.tossResult = {
    segments = {
      { kind = "text", value = "Threw away " },
      { kind = "quantity" },
      { kind = "text", value = " " },
      { kind = "item" },
      { kind = "text", value = "." },
    },
  }
  return manifest
end

function T.toss_prompt_placement_and_result_text_are_required()
  local manifest = validTossManifest()
  Assert.deepEqual(
    manifest.interactive.overlays.tossPrompt,
    { x = 200, y = 48, shape = "compact", initialSelection = "yes" },
    "the toss prompt carries the audited semantic placement"
  )
  Assert.isTrue(BagAssetSchema.isValidManifest(manifest), "the prompt placement and result text must pass")
  local missingPlacement = validTossManifest()
  missingPlacement.interactive.overlays.tossPrompt = nil
  assertInvalid(missingPlacement, "a manifest without the toss prompt placement must fail")
  local missingResult = validTossManifest()
  missingResult.interactive.text.tossResult = nil
  assertInvalid(missingResult, "a manifest without the post-choice result text must fail")
end

function T.toss_prompt_rejects_malformed_placement_and_source_identities()
  local leaked = validTossManifest()
  leaked.interactive.overlays.tossPrompt = {
    x = 200,
    y = 48,
    shape = "compact",
    initialSelection = "yes",
    memberId = 3,
  }
  assertInvalid(leaked, "producer-side source identities must not leak into the toss prompt")
  local wide = validTossManifest()
  wide.interactive.overlays.tossPrompt = { x = 200, y = 48, shape = "wide", initialSelection = "yes" }
  assertInvalid(wide, "an unsupported prompt shape must fail")
  local unselected = validTossManifest()
  unselected.interactive.overlays.tossPrompt = { x = 200, y = 48, shape = "compact", initialSelection = "maybe" }
  assertInvalid(unselected, "an unsupported initial selection must fail")
  local moved = validTossManifest()
  moved.interactive.overlays.tossPrompt = { x = 0, y = 0, shape = "compact", initialSelection = "yes" }
  Assert.isTrue(BagAssetSchema.isValidManifest(moved), "a non-negative prompt placement stays consumable")
  local negative = validTossManifest()
  negative.interactive.overlays.tossPrompt = { x = -1, y = 0, shape = "compact", initialSelection = "yes" }
  assertInvalid(negative, "a negative prompt placement must fail")
  local quantityOnly = validTossManifest()
  quantityOnly.interactive.text.tossResult = {
    segments = { { kind = "text", value = "Gone." } },
  }
  assertInvalid(quantityOnly, "a result template outside the item vocabulary must fail")
end

function T.generic_contract_accepts_safe_presentation_variants()
  local timing = validDynamicManifest()
  timing.hero.presentation.framing.transitionTicks = 12
  Assert.isTrue(BagAssetSchema.isValidManifest(timing), "a positive framing cadence stays consumable")
  local moved = validTossManifest()
  moved.interactive.overlays.tossPrompt = { x = 100, y = 100, shape = "compact", initialSelection = "yes" }
  Assert.isTrue(BagAssetSchema.isValidManifest(moved), "a record-shaped prompt placement stays consumable")
  local alternate = validTossManifest()
  alternate.interactive.overlays.tossPrompt = { x = 200, y = 48, shape = "compact", initialSelection = "no" }
  Assert.isTrue(BagAssetSchema.isValidManifest(alternate), "either supported preselection stays consumable")
end

function T.path_enumeration_lists_referenced_files_without_reauditing_the_contract()
  local manifest = validDynamicManifest()
  manifest.hero.presentation.framing.transitionTicks = 12
  local paths = BagCache.referencedPaths(manifest)
  Assert.isTrue(type(paths) == "table" and #paths > 0, "traversal lists referenced files")
  local found = false
  for _, path in ipairs(paths) do
    if path == "assets/generated/bag/tabs-mail.png" then
      found = true
    end
  end
  Assert.isTrue(found, "traversal still reaches the tab images")
end

return { tests = T }
