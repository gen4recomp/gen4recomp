-- Mon asset item contract: the generated catalog carries one strict item
-- collection keyed by semantic key, and every malformed shape fails loudly.
-- Rejections name duplicate native identities, extra fields, non-boolean
-- facts, and out-of-range identities; the boolean predicates mirror the
-- raising validators.

local Assert = require("tests.support.Assert")

local T = {}

local function schema()
  return require("libs.assets.src.MonAssetSchema")
end

local function growthCurves()
  local curves = {}
  for _, key in ipairs({
    "medium_fast",
    "erratic",
    "fluctuating",
    "medium_slow",
    "fast",
    "slow",
    "unused_6",
    "unused_7",
  }) do
    local curve = {}
    for level = 1, 100 do
      curve[level] = 0
    end
    curves[key] = curve
  end
  return curves
end

local function itemRecord(nativeId, isBall, friendshipBoost)
  return { nativeId = nativeId, isBall = isBall, friendshipBoost = friendshipBoost }
end

local function fullItems()
  local items = {}
  for nativeId = 0, 536 do
    items["ITEM_" .. nativeId] = itemRecord(nativeId, false, false)
  end
  items["ITEM_0"] = nil
  items["NONE"] = itemRecord(0, false, false)
  return items
end

local function catalogRoot(items)
  return {
    schema = "g4-mon-catalog-v2",
    version = { id = "heartgold", language = "english" },
    species = {
      CHIKORITA = {
        nativeId = 152,
        name = "CHIKORITA",
        growthCurve = "medium_slow",
        baseFriendship = 70,
        genderRatio = 31,
        eggCycles = 20,
        eggGroups = { "monster", "grass" },
        catchRate = 45,
        baseExpYield = 64,
        evYield = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 1 },
        heldItems = { common = { item = "NONE", nativeId = 0 }, rare = { item = "NONE", nativeId = 0 } },
        color = 3,
        flip = false,
        forms = {
          [0] = {
            baseStats = { hp = 45, attack = 49, defense = 65, speed = 45, specialAttack = 49, specialDefense = 65 },
            types = { "grass" },
            abilities = { "OVERGROW" },
            tmhm = {},
            levelUpMoves = { { level = 1, move = "TACKLE" } },
            evolutions = {},
            icon = "CHIKORITA/f0",
            portrait = "CHIKORITA/f0/male/plain",
          },
        },
      },
    },
    moves = {
      TACKLE = {
        nativeId = 33,
        name = "Tackle",
        description = "Charges the foe.",
        effect = 0,
        category = "physical",
        power = 35,
        moveType = "normal",
        accuracy = 95,
        basePp = 35,
        effectChance = 0,
        range = 0,
        priority = 0,
        flags = 0,
        unknownC = 0,
        contestType = 4,
      },
    },
    abilities = {
      OVERGROW = { nativeId = 65, name = "Overgrow", description = "Powers up Grass." },
    },
    growthCurves = growthCurves(),
    items = items,
  }
end

function T.catalogs_require_a_complete_item_collection()
  local MonAssetSchema = schema()
  Assert.isTrue(MonAssetSchema.assertCatalog(catalogRoot(fullItems())))
  Assert.isTrue(MonAssetSchema.isValidCatalog(catalogRoot(fullItems())))
  local missing = catalogRoot(nil)
  missing.items = nil
  Assert.isFalse(MonAssetSchema.isValidCatalog(missing))
  Assert.throws(function()
    MonAssetSchema.assertCatalog(missing)
  end)
end

function T.catalogs_reject_duplicate_item_identities()
  local MonAssetSchema = schema()
  local items = fullItems()
  items["ITEM_4_AGAIN"] = itemRecord(4, true, false)
  Assert.isFalse(MonAssetSchema.isValidCatalog(catalogRoot(items)))
end

function T.catalogs_reject_malformed_item_records()
  local MonAssetSchema = schema()
  local variants = {
    extra_field = { nativeId = 4, isBall = true, friendshipBoost = false, price = 200 },
    text_ball = { nativeId = 4, isBall = "yes", friendshipBoost = false },
    missing_boost = { nativeId = 4, isBall = true },
    negative_id = { nativeId = -1, isBall = false, friendshipBoost = false },
    past_range_id = { nativeId = 537, isBall = false, friendshipBoost = false },
    fractional_id = { nativeId = 4.5, isBall = true, friendshipBoost = false },
  }
  for name, bad in pairs(variants) do
    local items = fullItems()
    items["ITEM_4"] = bad
    Assert.isFalse(
      MonAssetSchema.isValidCatalog(catalogRoot(items)),
      "malformed item record must be rejected: " .. name
    )
  end
end

return { tests = T }
