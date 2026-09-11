-- Mon catalog item boundary: the generated mon catalog carries no item
-- collection. Item identity lives in the generated item class, so a mon
-- root smuggling the former collection fails loudly instead of forking a
-- second item authority.

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

local function catalogRoot()
  return {
    schema = "g4-mon-catalog-v3",
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
  }
end

function T.catalogs_without_an_item_collection_pass()
  local MonAssetSchema = schema()
  Assert.isTrue(MonAssetSchema.assertCatalog(catalogRoot()))
  Assert.isTrue(MonAssetSchema.isValidCatalog(catalogRoot()))
end

function T.catalogs_reject_a_leftover_item_collection()
  local MonAssetSchema = schema()
  local smuggled = catalogRoot()
  smuggled.items = {
    NONE = { nativeId = 0, isBall = false, friendshipBoost = false },
    POKE_BALL = { nativeId = 4, isBall = true, friendshipBoost = false },
  }
  Assert.isFalse(MonAssetSchema.isValidCatalog(smuggled))
  Assert.throws(function()
    MonAssetSchema.assertCatalog(smuggled)
  end)
end

return { tests = T }
