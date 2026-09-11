-- Item asset schema contract: one strict generated catalog plus the icon
-- manifest shape. A representative valid root passes; materially distinct
-- malformed shapes fail loudly. The boolean predicates mirror the raising
-- validators.

local Assert = require("tests.support.Assert")
local ItemFixture = require("libs.items.tests.item_fixture")

local T = {}

local function schema()
  return require("libs.assets.src.ItemAssetSchema")
end

local function validRoot()
  return ItemFixture.buildAssetRoot()
end

function T.valid_roots_pass_and_predicates_mirror()
  local ItemAssetSchema = schema()
  Assert.isTrue(ItemAssetSchema.assertCatalog(validRoot()))
  Assert.isTrue(ItemAssetSchema.isValidCatalog(validRoot()))
end

function T.catalogs_require_exact_item_identity_coverage()
  local ItemAssetSchema = schema()
  -- Dataless source identities carry an empty description: the schema
  -- accepts the empty string while still rejecting a missing field.
  local blank = validRoot()
  blank.items["ITEM_55"].description = ""
  Assert.isTrue(ItemAssetSchema.isValidCatalog(blank))
  local missing = validRoot()
  missing.items["ITEM_55"] = nil
  Assert.isFalse(ItemAssetSchema.isValidCatalog(missing))
  local duplicated = validRoot()
  duplicated.items["ITEM_17_AGAIN"] = {
    nativeId = 17,
    name = "Potion?",
    nameIndefinite = "a Potion?",
    namePlural = "Potions?",
    description = "duplicate",
    pocket = "medicine",
    preventToss = false,
    selectable = false,
    isBall = false,
    friendshipBoost = false,
    icon = "POTION",
  }
  Assert.isFalse(ItemAssetSchema.isValidCatalog(duplicated))
  local missingSection = validRoot()
  missingSection.items = nil
  Assert.isFalse(ItemAssetSchema.isValidCatalog(missingSection))
end

function T.catalogs_reject_malformed_item_records()
  local ItemAssetSchema = schema()
  local variants = {
    extra_field = { price = 200 },
    text_ball = { isBall = "yes" },
    negative_id = { nativeId = -1 },
    past_range_id = { nativeId = 537 },
    fractional_id = { nativeId = 4.5 },
    empty_name = { name = "" },
    unknown_pocket = { pocket = "sack" },
  }
  for name, patch in pairs(variants) do
    local root = validRoot()
    local record = root.items["ITEM_55"]
    for key, value in pairs(patch) do
      record[key] = value
    end
    Assert.isFalse(ItemAssetSchema.isValidCatalog(root), "malformed item record must be rejected: " .. name)
  end
  -- Nil assignments are not expressible as table patches, so the missing
  -- required fields are dropped explicitly.
  for _, key in ipairs({ "friendshipBoost", "icon" }) do
    local root = validRoot()
    root.items["ITEM_55"][key] = nil
    Assert.isFalse(ItemAssetSchema.isValidCatalog(root), "missing item field must be rejected: " .. key)
  end
end

function T.catalogs_reject_malformed_pocket_records()
  local ItemAssetSchema = schema()
  local badPocketKey = validRoot()
  badPocketKey.items["ITEM_55"].pocket = "sack"
  Assert.isFalse(ItemAssetSchema.isValidCatalog(badPocketKey))
  local badCapacity = validRoot()
  badCapacity.pockets.medicine.capacity = 41
  Assert.isFalse(ItemAssetSchema.isValidCatalog(badCapacity))
  local missingPocket = validRoot()
  missingPocket.pockets.mail = nil
  Assert.isFalse(ItemAssetSchema.isValidCatalog(missingPocket))
  local extraPocket = validRoot()
  extraPocket.pockets.sack = { nativeId = 8, capacity = 1, maxQuantity = 1, ordering = "manual" }
  Assert.isFalse(ItemAssetSchema.isValidCatalog(extraPocket))
  local missingNames = validRoot()
  missingNames.pocketNames = nil
  Assert.isFalse(ItemAssetSchema.isValidCatalog(missingNames))
end

function T.catalogs_reject_malformed_optional_tm_and_berry_data()
  local ItemAssetSchema = schema()
  local tmMissingMove = validRoot()
  tmMissingMove.items["TM01"].tmhmMoveNativeId = nil
  Assert.isFalse(ItemAssetSchema.isValidCatalog(tmMissingMove))
  local tmMoveOutOfRange = validRoot()
  tmMoveOutOfRange.items["TM01"].tmhmMoveNativeId = 468
  Assert.isFalse(ItemAssetSchema.isValidCatalog(tmMoveOutOfRange))
  local plainWithMove = validRoot()
  plainWithMove.items["POTION"].tmhmMoveNativeId = 33
  Assert.isFalse(ItemAssetSchema.isValidCatalog(plainWithMove))
  local berryMissingPlural = validRoot()
  berryMissingPlural.items["CHERI_BERRY"].berryNamePlural = nil
  Assert.isFalse(ItemAssetSchema.isValidCatalog(berryMissingPlural))
  local plainWithBerry = validRoot()
  plainWithBerry.items["POTION"].berryNameSingular = "Potion Berry"
  plainWithBerry.items["POTION"].berryNamePlural = "Potion Berries"
  Assert.isFalse(ItemAssetSchema.isValidCatalog(plainWithBerry))
end

function T.catalogs_reject_malformed_roots()
  local ItemAssetSchema = schema()
  local badSchema = validRoot()
  badSchema.schema = "g4-mon-catalog-v2"
  Assert.isFalse(ItemAssetSchema.isValidCatalog(badSchema))
  local extraKey = validRoot()
  extraKey.sprites = {}
  Assert.isFalse(ItemAssetSchema.isValidCatalog(extraKey))
  local badVersion = validRoot()
  badVersion.version = { id = "", language = "en" }
  Assert.isFalse(ItemAssetSchema.isValidCatalog(badVersion))
end

local function validManifest()
  return {
    schema = "g4-item-icons-v1",
    atlas = "assets/generated/item/icons.png",
    entries = {
      POTION = { x = 0, y = 0, width = 32, height = 32 },
      POKE_BALL = { x = 32, y = 0, width = 32, height = 32 },
    },
    representative = { "POTION" },
  }
end

function T.manifests_validate_rects_and_representatives()
  local ItemAssetSchema = schema()
  Assert.isTrue(ItemAssetSchema.assertIconManifest(validManifest()))
  Assert.isTrue(ItemAssetSchema.isValidIconManifest(validManifest()))
  local badRect = validManifest()
  badRect.entries.POTION.width = 0
  Assert.isFalse(ItemAssetSchema.isValidIconManifest(badRect))
  local dangling = validManifest()
  dangling.representative = { "MISSING_ICON" }
  Assert.isFalse(ItemAssetSchema.isValidIconManifest(dangling))
  local badSchema = validManifest()
  badSchema.schema = "g4-item-icons-v0"
  Assert.isFalse(ItemAssetSchema.isValidIconManifest(badSchema))
end

function T.catalog_icons_must_resolve_to_manifest_entries()
  local ItemAssetSchema = schema()
  local root = validRoot()
  local manifest = validManifest()
  manifest.entries = {
    NONE = { x = 0, y = 0, width = 32, height = 32 },
    POTION = { x = 0, y = 0, width = 32, height = 32 },
  }
  manifest.representative = { "NONE" }
  Assert.throws(function()
    ItemAssetSchema.assertCatalogIcons(root, manifest)
  end)
end

return { tests = T }
