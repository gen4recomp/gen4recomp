-- ROM conformance: the generated mon catalog is the single source of item
-- identity, ball classification, and friendship-boost facts. Every supported
-- native identity resolves exactly once, and the known probe items pin the
-- source derivation.

local Assert = require("tests.support.Assert")
local MonCatalog = require("libs.mons.src.MonCatalog")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

-- The compiled catalog is treated read-only below (MonCatalog copies its
-- root), so one ROM-backed build serves every test in this suite.
local compiledByVersion = {}

local function compileCatalog(romFs, versionId)
  if compiledByVersion[versionId] == nil then
    local MonCatalogCompiler = require("romdump.src.digest.MonCatalogCompiler")
    compiledByVersion[versionId] = assert(MonCatalogCompiler.compileCatalog(romFs, { versionId = versionId }))
  end
  return compiledByVersion[versionId]
end

local function itemMemberCount(romFs)
  return assert(romFs:openNarc("item_data")):memberCount()
end

function T.catalog_covers_every_supported_item_identity_exactly_once(romFs, versionId)
  local catalog = compileCatalog(romFs, versionId)
  local items = assert(catalog.items, "the generated mon catalog must carry the item collection")
  local keyByNativeId = {}
  local count = 0
  for key, record in pairs(items) do
    Assert.isTrue(type(key) == "string" and key ~= "", "item keys must be non-empty strings")
    Assert.keySet(record, "friendshipBoost,isBall,nativeId", "item " .. key .. " carries only the runtime facts")
    local nativeId = record.nativeId
    Assert.isTrue(
      type(nativeId) == "number" and nativeId % 1 == 0 and nativeId >= 0 and nativeId <= 536,
      "item " .. key .. " must carry a source native identity in 0..536"
    )
    Assert.isTrue(type(record.isBall) == "boolean", "item " .. key .. " must carry a ball fact")
    Assert.isTrue(type(record.friendshipBoost) == "boolean", "item " .. key .. " must carry a friendship fact")
    Assert.isNil(keyByNativeId[nativeId], "native item identity " .. nativeId .. " must resolve exactly once")
    keyByNativeId[nativeId] = key
    count = count + 1
  end
  Assert.isTrue(count > 0, "the item collection must not be empty")
  -- Every ROM-backed member is represented: the producer never drops a
  -- member the dump actually ships, whatever it decides about the
  -- member-less tail of the source constant range.
  for memberId = 0, itemMemberCount(romFs) - 1 do
    Assert.notNil(keyByNativeId[memberId], "ROM item member " .. memberId .. " must map to exactly one semantic key")
  end
end

function T.representative_ball_and_friendship_facts_match_source(romFs, versionId)
  local catalog = compileCatalog(romFs, versionId)
  local items = assert(catalog.items, "the generated mon catalog must carry the item collection")
  local function record(key)
    return assert(items[key], key .. " must be a generated item identity")
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
end

function T.strict_lookup_round_trips_and_rejects_unknown_identities(romFs, versionId)
  local catalog = MonCatalog.new(compileCatalog(romFs, versionId))
  local catalogApi = catalog --[[@as table]]
  local ok, key = pcall(catalogApi.itemKeyByNativeId, catalog, 0)
  Assert.isTrue(ok, "native item lookup must resolve through the catalog: " .. tostring(key))
  Assert.equal(key, "NONE", "native identity 0 must round-trip to NONE")
  local okItem, item = pcall(catalogApi.item, catalog, "SOOTHE_BELL")
  Assert.isTrue(okItem, "semantic item lookup must resolve through the catalog")
  Assert.equal(item.nativeId, 218, "SOOTHE_BELL must resolve back to native identity 218")
  local okBall, ball = pcall(catalogApi.itemKeyByNativeId, catalog, 4)
  Assert.isTrue(okBall, "native ball lookup must resolve through the catalog")
  Assert.equal(ball, "POKE_BALL", "native identity 4 must round-trip to POKE_BALL")
  Assert.isFalse(pcall(catalogApi.itemKeyByNativeId, catalog, 9999), "an unknown native identity must raise")
  Assert.isFalse(pcall(catalogApi.item, catalog, "BOGUS_ITEM"), "an unknown item key must raise")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
return suite
