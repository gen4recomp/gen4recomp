-- ROM conformance: the generated item catalog is the single source of item
-- identity, Bag metadata, display text, TM/HM mapping, and icon selection.
-- Every supported native identity resolves exactly once with
-- source-consistent pocket and mapping facts, and recompilation is
-- deterministic. Assertions are coverage relationships and cross-reference
-- validity, never catalog snapshots or committed commercial payloads.

local Assert = require("tests.support.Assert")
local ItemAssetSchema = require("libs.assets.src.ItemAssetSchema")
local ItemSources = require("romdump.src.config.ItemSources")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

-- The compiled catalog is treated read-only below (ItemCatalog copies its
-- root), so one ROM-backed build serves every test in this suite.
local compiledByVersion = {}

local function compileCatalog(romFs, versionId)
  if compiledByVersion[versionId] == nil then
    local ItemCatalogCompiler = require("romdump.src.digest.items.ItemCatalogCompiler")
    compiledByVersion[versionId] = assert(ItemCatalogCompiler.compileCatalog(romFs, { versionId = versionId }))
  end
  return compiledByVersion[versionId]
end

local function compiledIcons(romFs, versionId)
  local key = "icons:" .. versionId
  if compiledByVersion[key] == nil then
    local ItemPresentationCompiler = require("romdump.src.digest.items.ItemPresentationCompiler")
    compiledByVersion[key] = assert(ItemPresentationCompiler.compileIcons(romFs))
  end
  return compiledByVersion[key]
end

local function countItems(catalog)
  local count = 0
  for _ in pairs(catalog.items) do
    count = count + 1
  end
  return count
end

function T.catalog_covers_every_supported_item_identity_exactly_once(romFs, versionId)
  local catalog = compileCatalog(romFs, versionId)
  Assert.isTrue(ItemAssetSchema.isValidCatalog(catalog), "the compiled catalog must pass the shared schema")
  local keyByNativeId = {}
  for key, record in pairs(catalog.items) do
    Assert.isTrue(type(key) == "string" and key ~= "", "item keys must be non-empty strings")
    local nativeId = record.nativeId
    Assert.isTrue(
      type(nativeId) == "number" and nativeId % 1 == 0 and nativeId >= 0 and nativeId <= 536,
      "item " .. key .. " must carry a source native identity in 0..536"
    )
    Assert.isNil(keyByNativeId[nativeId], "native item identity " .. nativeId .. " must resolve exactly once")
    keyByNativeId[nativeId] = key
  end
  Assert.equal(countItems(catalog), 537, "the catalog must carry every source native identity")
  for nativeId = 0, 536 do
    Assert.notNil(keyByNativeId[nativeId], "native item identity " .. nativeId .. " must resolve")
    Assert.equal(keyByNativeId[nativeId], ItemSources.itemKeys[nativeId], "identity must keep its semantic key")
  end
  -- The item-data archive census anchors the coverage invariant: the
  -- producer never drops a member the dump actually ships.
  local itemData = assert(romFs:openNarc("item_data"))
  Assert.equal(itemData:memberCount(), 514, "item_data member census anchors the coverage invariant")
end

function T.pockets_classify_representatives_across_all_pockets(romFs, versionId)
  local catalog = compileCatalog(romFs, versionId)
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  local items = ItemCatalog.new(catalog)
  local expected = {
    NUGGET = "items",
    POTION = "medicine",
    POKE_BALL = "balls",
    TM01 = "tmhm",
    CHERI_BERRY = "berries",
    GRASS_MAIL = "mail",
    X_ATTACK = "battle_items",
    BICYCLE = "key_items",
  }
  for key, pocket in pairs(expected) do
    Assert.equal(items:item(key).pocket, pocket, key .. " must classify into the " .. pocket .. " pocket")
    Assert.equal(items:pocketKeyByNativeId(items:pocket(pocket).nativeId), pocket)
  end
  local perPocket = {}
  for _, record in pairs(catalog.items) do
    perPocket[record.pocket] = (perPocket[record.pocket] or 0) + 1
  end
  for pocket in pairs(ItemAssetSchema.POCKETS) do
    Assert.isTrue((perPocket[pocket] or 0) > 0, "pocket " .. pocket .. " must carry at least one item")
  end
  -- Definitional ranges compile to exact pocket populations.
  Assert.equal(perPocket.tmhm, 100, "every TM and HM must land in the TM/HM pocket")
  Assert.equal(perPocket.berries, 64, "every berry must land in the berry pocket")
  Assert.equal(perPocket.mail, 12, "every mail item must land in the mail pocket")
end

function T.ball_and_friendship_facts_match_source(romFs, versionId)
  local catalog = compileCatalog(romFs, versionId)
  local function record(key)
    return assert(catalog.items[key], key .. " must be a compiled item identity")
  end
  Assert.equal(record("NONE").nativeId, 0)
  Assert.equal(record("POKE_BALL").nativeId, 4)
  Assert.equal(record("SOOTHE_BELL").nativeId, 218)
  for _, key in ipairs({
    "MASTER_BALL",
    "ULTRA_BALL",
    "GREAT_BALL",
    "POKE_BALL",
    "SAFARI_BALL",
    "CHERISH_BALL",
    "PARK_BALL",
    "MOON_BALL",
  }) do
    Assert.isTrue(record(key).isBall, key .. " must classify as a ball")
  end
  for _, key in ipairs({ "NONE", "POTION", "SOOTHE_BELL", "RARE_CANDY" }) do
    Assert.isFalse(record(key).isBall, key .. " must not classify as a ball")
  end
  Assert.isTrue(record("SOOTHE_BELL").friendshipBoost, "SOOTHE_BELL must carry the friendship boost")
  for _, key in ipairs({ "NONE", "POKE_BALL", "MASTER_BALL", "POTION" }) do
    Assert.isFalse(record(key).friendshipBoost, key .. " must not carry the friendship boost")
  end
  -- Toss and selectability follow the source flags on representatives.
  Assert.isTrue(record("BICYCLE").preventToss, "BICYCLE must refuse tossing")
  Assert.isFalse(record("POTION").preventToss, "POTION must allow tossing")
  Assert.isTrue(record("BICYCLE").selectable, "BICYCLE must be selectable")
end

function T.tmhm_and_berry_mappings_match_source(romFs, versionId)
  local catalog = compileCatalog(romFs, versionId)
  local function record(key)
    return assert(catalog.items[key], key .. " must be a compiled item identity")
  end
  Assert.equal(
    record("TM01").tmhmMoveNativeId,
    ItemSources.machineMoves[0].nativeId,
    "TM01 must teach the first source machine move"
  )
  Assert.equal(
    record("HM01").tmhmMoveNativeId,
    ItemSources.machineMoves[92].nativeId,
    "HM01 must teach the first source hidden move"
  )
  Assert.isNil(record("POTION").tmhmMoveNativeId, "non-machine items carry no move identity")
  local berry = record("CHERI_BERRY")
  Assert.isTrue(
    type(berry.berryNameSingular) == "string" and berry.berryNameSingular ~= "",
    "berries must carry a singular name"
  )
  Assert.equal(berry.berryNameSingular, berry.berryNamePlural, "berry name forms must agree per berry")
  Assert.isTrue(
    berry.berryNameSingular ~= berry.name,
    "berry names must come from the berry bank, not the item-name bank"
  )
  Assert.isNil(record("POTION").berryNameSingular, "non-berry items carry no berry names")
end

function T.text_forms_come_from_the_source_banks(romFs, versionId)
  local catalog = compileCatalog(romFs, versionId)
  for key, record in pairs(catalog.items) do
    Assert.isTrue(type(record.name) == "string" and record.name ~= "", "item " .. key .. " must carry a name")
    Assert.isTrue(
      type(record.nameIndefinite) == "string" and record.nameIndefinite ~= "",
      "item " .. key .. " must carry an indefinite name"
    )
    Assert.isTrue(
      type(record.namePlural) == "string" and record.namePlural ~= "",
      "item " .. key .. " must carry a plural name"
    )
    -- Descriptions are empty exactly for the dataless identities (the
    -- UNUSED block and the dataless EXPLORER_KIT share member 0): text
    -- banks index by native identity, never by data member.
    if record.description == "" then
      Assert.equal(
        ItemSources.itemDataMember(record.nativeId),
        0,
        "item " .. key .. " has an empty description without sharing the fallback member"
      )
      Assert.isTrue(record.nativeId ~= 0, "item " .. key .. " must not be the fallback identity itself")
    else
      Assert.isTrue(type(record.description) == "string", "item " .. key .. " must carry a string description")
    end
  end
  local potion = assert(catalog.items.POTION, "POTION must be a compiled item identity")
  Assert.notNil(potion.nameIndefinite:find(potion.name, 1, true), "the indefinite form must contain the item name")
  Assert.isTrue(potion.namePlural ~= potion.name, "the plural form must differ from the base name")
  for pocket, name in pairs(catalog.pocketNames) do
    Assert.isTrue(type(name) == "string" and name ~= "", "pocket " .. pocket .. " must carry a name")
  end
end

function T.icons_follow_the_source_mapping_without_arithmetic(romFs, versionId)
  local catalog = compileCatalog(romFs, versionId)
  local compiled = compiledIcons(romFs, versionId)
  Assert.isTrue(
    ItemAssetSchema.isValidIconManifest(compiled.manifest),
    "the compiled manifest must pass the shared schema"
  )
  Assert.isTrue(
    ItemAssetSchema.assertCatalogIcons(catalog, compiled.manifest),
    "every catalog icon must resolve to a manifest entry"
  )
  local entryCount = 0
  for _ in pairs(compiled.manifest.entries) do
    entryCount = entryCount + 1
  end
  Assert.equal(entryCount, 537, "every item key must name a manifest entry")
  local iconArchive = assert(romFs:openNarc("item_icons"))
  for nativeId = 0, 536 do
    local graphics = ItemSources.iconGraphics[nativeId]
    Assert.notNil(iconArchive:readMember(graphics.ncgr), "mapped ncgr member must exist")
    Assert.notNil(iconArchive:readMember(graphics.nclr), "mapped nclr member must exist")
  end
  -- Shared source graphics compile to the same atlas region: identities
  -- without their own data row reuse the shared member.
  local entries = compiled.manifest.entries
  Assert.deepEqual(entries.UNUSED_113, entries.NONE, "dataless identities must share the fallback region")
  local uniqueRects = {}
  for _, entry in pairs(entries) do
    uniqueRects[entry.x .. "," .. entry.y] = true
  end
  local uniqueCount = 0
  for _ in pairs(uniqueRects) do
    uniqueCount = uniqueCount + 1
  end
  Assert.isTrue(uniqueCount < 537, "shared graphics must deduplicate atlas regions")
  Assert.isTrue(uniqueCount > 0, "the atlas must carry regions")
end

function T.recompilation_is_deterministic(romFs, versionId)
  local ItemCatalogCompiler = require("romdump.src.digest.items.ItemCatalogCompiler")
  local ItemPresentationCompiler = require("romdump.src.digest.items.ItemPresentationCompiler")
  local Hashing = require("romdump.src.digest.Hashing")
  local first = compileCatalog(romFs, versionId)
  local second = assert(ItemCatalogCompiler.compileCatalog(romFs, { versionId = versionId }))
  Assert.equal(Hashing.hashLua(second), Hashing.hashLua(first), "catalog recompilation must be deterministic")
  local firstIcons = compiledIcons(romFs, versionId)
  local secondIcons = assert(ItemPresentationCompiler.compileIcons(romFs))
  Assert.equal(secondIcons.image.pixels, firstIcons.image.pixels, "icon recompilation must be deterministic")
  Assert.deepEqual(secondIcons.manifest, firstIcons.manifest, "icon manifests must be deterministic")
end

function T.mon_catalog_delegates_item_facts_to_the_shared_catalog(romFs, versionId)
  local MonCatalog = require("libs.mons.src.MonCatalog")
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  local catalog = MonCatalog.new(
    (function()
      local MonCatalogCompiler = require("romdump.src.digest.mons.MonCatalogCompiler")
      return assert(MonCatalogCompiler.compileCatalog(romFs, { versionId = versionId }))
    end)(),
    ItemCatalog.new(compileCatalog(romFs, versionId))
  )
  Assert.equal(catalog:itemKeyByNativeId(0), "NONE")
  Assert.equal(catalog:itemKeyByNativeId(4), "POKE_BALL")
  Assert.equal(catalog:item("SOOTHE_BELL").nativeId, 218)
  Assert.isTrue(catalog:item("POKE_BALL").isBall)
  Assert.isFalse(catalog:item("POTION").isBall)
  Assert.isTrue(catalog:item("SOOTHE_BELL").friendshipBoost)
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
return suite
