-- Authoritative validation for the generated item asset class. The catalog
-- carries one strict definition per source native identity 0..536 plus the
-- eight pocket definitions and their display names; the icon manifest carries
-- the compiled atlas rectangles every catalog icon selector must resolve to.
-- Every loader, producer writer, and test calls these validators, so no
-- second interpretation of the shapes exists. Unknown fields, duplicate
-- identities, missing range members, malformed pockets, and malformed
-- optional TM/berry data fail loudly. Love-free and filesystem-free.

local Errors = require("libs.errors.src.Errors")
local Validate = require("libs.assets.src.Validate")

---@class ItemAssetSchema
local ItemAssetSchema = {}

ItemAssetSchema.CATALOG_SCHEMA = "g4-item-catalog-v1"
ItemAssetSchema.ICON_MANIFEST_SCHEMA = "g4-item-icons-v1"

-- The eight source pockets in native order: native id, occupied-slot
-- capacity, per-stack quantity maximum, and player-ordering policy. Pocket
-- capacities and stack maxima follow include/constants/items.h (NUM_BAG_*)
-- and the ItemSlot quantity rule in include/item.h; TM/HM and berry pockets
-- are native-id ordered while every other pocket preserves player order.
ItemAssetSchema.POCKETS = {
  items = { nativeId = 0, capacity = 165, maxQuantity = 999, ordering = "manual" },
  medicine = { nativeId = 1, capacity = 40, maxQuantity = 999, ordering = "manual" },
  balls = { nativeId = 2, capacity = 24, maxQuantity = 999, ordering = "manual" },
  tmhm = { nativeId = 3, capacity = 101, maxQuantity = 99, ordering = "native_id" },
  berries = { nativeId = 4, capacity = 64, maxQuantity = 999, ordering = "native_id" },
  mail = { nativeId = 5, capacity = 12, maxQuantity = 999, ordering = "manual" },
  battle_items = { nativeId = 6, capacity = 30, maxQuantity = 999, ordering = "manual" },
  key_items = { nativeId = 7, capacity = 50, maxQuantity = 999, ordering = "manual" },
}

ItemAssetSchema.MIN_NATIVE_ID = 0
ItemAssetSchema.MAX_NATIVE_ID = 536
ItemAssetSchema.MAX_MOVE_NATIVE_ID = 467

local ITEM_FIELDS = {
  nativeId = true,
  name = true,
  nameIndefinite = true,
  namePlural = true,
  description = true,
  pocket = true,
  preventToss = true,
  selectable = true,
  isBall = true,
  friendshipBoost = true,
  tmhmMoveNativeId = true,
  berryNameSingular = true,
  berryNamePlural = true,
  icon = true,
}

local function fail(code, message, context)
  Errors.raise(code, message, context or {})
end

local function checkKeys(record, allowed, context, code)
  for key in pairs(record) do
    if allowed[key] == nil then
      fail(code, "unknown field " .. tostring(key), context)
    end
  end
end

local function checkNonEmptyString(value, context, code, field)
  if type(value) ~= "string" or value == "" then
    fail(code, field .. " must be a non-empty string", context)
  end
end

local function checkBoolean(value, context, code, field)
  if type(value) ~= "boolean" then
    fail(code, field .. " must be a boolean", context)
  end
end

local function assertItem(key, record, context)
  if type(key) ~= "string" or key == "" then
    fail("ITEM_CATALOG_INVALID", "item keys must be non-empty strings", context)
  end
  if type(record) ~= "table" then
    fail("ITEM_CATALOG_INVALID", "item " .. key .. " must be a record", context)
  end
  checkKeys(record, ITEM_FIELDS, context, "ITEM_CATALOG_INVALID")
  if
    type(record.nativeId) ~= "number"
    or record.nativeId % 1 ~= 0
    or record.nativeId < ItemAssetSchema.MIN_NATIVE_ID
    or record.nativeId > ItemAssetSchema.MAX_NATIVE_ID
  then
    fail("ITEM_CATALOG_INVALID", "item " .. key .. " nativeId must be 0..536", context)
  end
  checkNonEmptyString(record.name, context, "ITEM_CATALOG_INVALID", "item " .. key .. " name")
  checkNonEmptyString(record.nameIndefinite, context, "ITEM_CATALOG_INVALID", "item " .. key .. " nameIndefinite")
  checkNonEmptyString(record.namePlural, context, "ITEM_CATALOG_INVALID", "item " .. key .. " namePlural")
  if type(record.description) ~= "string" then
    fail("ITEM_CATALOG_INVALID", "item " .. key .. " description must be a string", context)
  end
  if ItemAssetSchema.POCKETS[record.pocket] == nil then
    fail("ITEM_CATALOG_INVALID", "item " .. key .. " has an unknown pocket", context)
  end
  checkBoolean(record.preventToss, context, "ITEM_CATALOG_INVALID", "item " .. key .. " preventToss")
  checkBoolean(record.selectable, context, "ITEM_CATALOG_INVALID", "item " .. key .. " selectable")
  checkBoolean(record.isBall, context, "ITEM_CATALOG_INVALID", "item " .. key .. " isBall")
  checkBoolean(record.friendshipBoost, context, "ITEM_CATALOG_INVALID", "item " .. key .. " friendshipBoost")
  checkNonEmptyString(record.icon, context, "ITEM_CATALOG_INVALID", "item " .. key .. " icon")
  -- Optional machine/berry identities are pocket-gated: TM/HM items carry
  -- the taught move, berry items carry both berry-name forms, and every
  -- other item carries neither.
  if record.pocket == "tmhm" then
    if
      type(record.tmhmMoveNativeId) ~= "number"
      or record.tmhmMoveNativeId % 1 ~= 0
      or record.tmhmMoveNativeId < 0
      or record.tmhmMoveNativeId > ItemAssetSchema.MAX_MOVE_NATIVE_ID
    then
      fail("ITEM_CATALOG_INVALID", "item " .. key .. " tmhmMoveNativeId must be 0..467", context)
    end
  elseif record.tmhmMoveNativeId ~= nil then
    fail("ITEM_CATALOG_INVALID", "item " .. key .. " carries a move identity outside the TM/HM pocket", context)
  end
  if record.pocket == "berries" then
    checkNonEmptyString(
      record.berryNameSingular,
      context,
      "ITEM_CATALOG_INVALID",
      "item " .. key .. " berryNameSingular"
    )
    checkNonEmptyString(record.berryNamePlural, context, "ITEM_CATALOG_INVALID", "item " .. key .. " berryNamePlural")
  else
    if record.berryNameSingular ~= nil or record.berryNamePlural ~= nil then
      fail("ITEM_CATALOG_INVALID", "item " .. key .. " carries berry names outside the berry pocket", context)
    end
  end
end

local function collectNativeIds(items, context)
  local ids = {}
  for key, record in pairs(items) do
    local id = record.nativeId
    if type(id) ~= "number" then
      fail("ITEM_CATALOG_INVALID", "item " .. key .. " is missing its native identity", context)
    end
    if ids[id] then
      fail("ITEM_CATALOG_INVALID", "duplicate item native identity " .. tostring(id), context)
    end
    ids[id] = key
  end
  return ids
end

local function assertPockets(pockets, context)
  if type(pockets) ~= "table" then
    fail("ITEM_CATALOG_INVALID", "pockets must be a record", context)
  end
  for key, definition in pairs(pockets) do
    local expected = ItemAssetSchema.POCKETS[key]
    if expected == nil then
      fail("ITEM_CATALOG_INVALID", "unknown pocket " .. tostring(key), context)
    end
    assert(expected ~= nil, "pocket contract carries the validated entry")
    if type(definition) ~= "table" then
      fail("ITEM_CATALOG_INVALID", "pocket " .. key .. " must be a record", context)
    end
    checkKeys(
      definition,
      { nativeId = true, capacity = true, maxQuantity = true, ordering = true },
      context,
      "ITEM_CATALOG_INVALID"
    )
    if
      definition.nativeId ~= expected.nativeId
      or definition.capacity ~= expected.capacity
      or definition.maxQuantity ~= expected.maxQuantity
      or definition.ordering ~= expected.ordering
    then
      fail("ITEM_CATALOG_INVALID", "pocket " .. key .. " does not match the source pocket contract", context)
    end
  end
  for key in pairs(ItemAssetSchema.POCKETS) do
    if pockets[key] == nil then
      fail("ITEM_CATALOG_INVALID", "pocket " .. key .. " is missing", context)
    end
  end
end

local function assertPocketNames(pocketNames, context)
  if type(pocketNames) ~= "table" then
    fail("ITEM_CATALOG_INVALID", "pocketNames must be a record", context)
  end
  for key, name in pairs(pocketNames) do
    if ItemAssetSchema.POCKETS[key] == nil then
      fail("ITEM_CATALOG_INVALID", "unknown pocket name " .. tostring(key), context)
    end
    checkNonEmptyString(name, context, "ITEM_CATALOG_INVALID", "pocket name " .. key)
  end
  for key in pairs(ItemAssetSchema.POCKETS) do
    if pocketNames[key] == nil then
      fail("ITEM_CATALOG_INVALID", "pocket name " .. key .. " is missing", context)
    end
  end
end

-- Full catalog validation: shapes plus exact native-identity coverage. Every
-- source identity 0..536 appears exactly once with only the runtime facts
-- each record carries; there is no partial item table.
function ItemAssetSchema.assertCatalog(catalog)
  local context = {}
  if type(catalog) ~= "table" then
    fail("ITEM_CATALOG_INVALID", "catalog must be a record", context)
  end
  checkKeys(catalog, {
    schema = true,
    version = true,
    items = true,
    pockets = true,
    pocketNames = true,
  }, context, "ITEM_CATALOG_INVALID")
  if catalog.schema ~= ItemAssetSchema.CATALOG_SCHEMA then
    fail("ITEM_CATALOG_INVALID", "catalog schema must be " .. ItemAssetSchema.CATALOG_SCHEMA, context)
  end
  if type(catalog.version) ~= "table" then
    fail("ITEM_CATALOG_INVALID", "catalog version must be a record", context)
  end
  checkKeys(catalog.version, { id = true, language = true }, context, "ITEM_CATALOG_INVALID")
  checkNonEmptyString(catalog.version.id, context, "ITEM_CATALOG_INVALID", "catalog version id")
  checkNonEmptyString(catalog.version.language, context, "ITEM_CATALOG_INVALID", "catalog version language")
  if type(catalog.items) ~= "table" then
    fail("ITEM_CATALOG_INVALID", "items must be a record", context)
  end
  for key, record in pairs(catalog.items) do
    assertItem(key, record, context)
  end
  local byNativeId = collectNativeIds(catalog.items, context)
  for nativeId = ItemAssetSchema.MIN_NATIVE_ID, ItemAssetSchema.MAX_NATIVE_ID do
    if byNativeId[nativeId] == nil then
      fail("ITEM_CATALOG_INVALID", "item native identity " .. nativeId .. " is missing", context)
    end
  end
  assertPockets(catalog.pockets, context)
  assertPocketNames(catalog.pocketNames, context)
  return true
end

function ItemAssetSchema.isValidCatalog(catalog)
  return pcall(ItemAssetSchema.assertCatalog, catalog)
end

local function checkManifestRect(rect, context, field)
  if type(rect) ~= "table" then
    fail("ITEM_MANIFEST_INVALID", field .. " must be a record", context)
  end
  for _, axis in ipairs({ "x", "y", "width", "height" }) do
    if type(rect[axis]) ~= "number" or rect[axis] % 1 ~= 0 or rect[axis] < 0 then
      fail("ITEM_MANIFEST_INVALID", field .. "." .. axis .. " must be a non-negative integer", context)
    end
  end
  if rect.width == 0 or rect.height == 0 then
    fail("ITEM_MANIFEST_INVALID", field .. " must have positive dimensions", context)
  end
end

-- Icon manifest validation: every entry addresses an atlas rectangle and
-- every representative selector resolves.
function ItemAssetSchema.assertIconManifest(manifest)
  local context = {}
  if type(manifest) ~= "table" then
    fail("ITEM_MANIFEST_INVALID", "manifest must be a record", context)
  end
  checkKeys(
    manifest,
    { schema = true, atlas = true, entries = true, representative = true },
    context,
    "ITEM_MANIFEST_INVALID"
  )
  if manifest.schema ~= ItemAssetSchema.ICON_MANIFEST_SCHEMA then
    fail("ITEM_MANIFEST_INVALID", "manifest schema must be " .. ItemAssetSchema.ICON_MANIFEST_SCHEMA, context)
  end
  checkNonEmptyString(manifest.atlas, context, "ITEM_MANIFEST_INVALID", "manifest atlas")
  if type(manifest.entries) ~= "table" then
    fail("ITEM_MANIFEST_INVALID", "manifest entries must be a record", context)
  end
  local entryCount = 0
  for selector, entry in pairs(manifest.entries) do
    entryCount = entryCount + 1
    if type(selector) ~= "string" or selector == "" then
      fail("ITEM_MANIFEST_INVALID", "manifest selectors must be non-empty strings", context)
    end
    checkKeys(entry, { x = true, y = true, width = true, height = true }, context, "ITEM_MANIFEST_INVALID")
    checkManifestRect(entry, context, "manifest entry " .. selector)
  end
  if entryCount == 0 then
    fail("ITEM_MANIFEST_INVALID", "manifest must carry entries", context)
  end
  if not Validate.isArray(manifest.representative) or #manifest.representative == 0 then
    fail("ITEM_MANIFEST_INVALID", "manifest must carry representative selectors", context)
  end
  for _, selector in ipairs(manifest.representative) do
    if manifest.entries[selector] == nil then
      fail("ITEM_MANIFEST_INVALID", "representative selector has no entry: " .. tostring(selector), context)
    end
  end
  return true
end

function ItemAssetSchema.isValidIconManifest(manifest)
  return pcall(ItemAssetSchema.assertIconManifest, manifest)
end

local function checkHash(value, context, field)
  if type(value) ~= "string" or #value ~= 40 or value:match("^[0-9a-f]+$") == nil then
    fail("ITEM_INDEX_INVALID", field .. " must be a 40-character hex digest", context)
  end
end

-- Class index validation: schema identity, version, content hashes, and
-- cache-relative paths.
function ItemAssetSchema.assertIndex(index)
  local context = {}
  if type(index) ~= "table" then
    fail("ITEM_INDEX_INVALID", "index must be a record", context)
  end
  checkKeys(index, {
    schema = true,
    version = true,
    catalogHash = true,
    iconHash = true,
    catalog = true,
    icons = true,
    iconManifest = true,
  }, context, "ITEM_INDEX_INVALID")
  if index.schema ~= "g4-item-index-v1" then
    fail("ITEM_INDEX_INVALID", "index schema must be g4-item-index-v1", context)
  end
  if type(index.version) ~= "table" then
    fail("ITEM_INDEX_INVALID", "index version must be a record", context)
  end
  checkKeys(index.version, { id = true, language = true }, context, "ITEM_INDEX_INVALID")
  checkNonEmptyString(index.version.id, context, "ITEM_INDEX_INVALID", "index version id")
  checkNonEmptyString(index.version.language, context, "ITEM_INDEX_INVALID", "index version language")
  checkHash(index.catalogHash, context, "catalogHash")
  checkHash(index.iconHash, context, "iconHash")
  checkNonEmptyString(index.catalog, context, "ITEM_INDEX_INVALID", "catalog path")
  checkNonEmptyString(index.icons, context, "ITEM_INDEX_INVALID", "icons path")
  checkNonEmptyString(index.iconManifest, context, "ITEM_INDEX_INVALID", "iconManifest path")
  return true
end

function ItemAssetSchema.isValidIndex(index)
  return pcall(ItemAssetSchema.assertIndex, index)
end

-- Catalog-to-manifest resolution: every item icon selector names a compiled
-- atlas entry. Publication calls this before the class leaves the writer.
function ItemAssetSchema.assertCatalogIcons(catalog, manifest)
  local context = {}
  if type(catalog) ~= "table" or type(catalog.items) ~= "table" then
    fail("ITEM_MANIFEST_INVALID", "catalog must carry its item collection", context)
  end
  if type(manifest) ~= "table" or type(manifest.entries) ~= "table" then
    fail("ITEM_MANIFEST_INVALID", "manifest must carry its entries", context)
  end
  for key, record in pairs(catalog.items) do
    if type(record) ~= "table" or manifest.entries[record.icon] == nil then
      fail("ITEM_MANIFEST_INVALID", "item " .. key .. " icon has no manifest entry", context)
    end
  end
  return true
end

return ItemAssetSchema
