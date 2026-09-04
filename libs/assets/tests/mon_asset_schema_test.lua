-- Mon asset schema contract: strict shapes for forms, catalogs, indexes,
-- and presentation manifests. Rejections name unknown fields, dangling
-- references, and out-of-range values; the boolean predicates mirror the
-- raising validators.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")

local T = {}

local function schema()
  return require("libs.assets.src.MonAssetSchema")
end

local function validForm()
  return {
    baseStats = { hp = 45, attack = 49, defense = 65, speed = 45, specialAttack = 49, specialDefense = 65 },
    types = { "grass" },
    abilities = { "OVERGROW" },
    tmhm = { "TOXIC" },
    levelUpMoves = { { level = 1, move = "TACKLE" } },
    evolutions = { { method = "level", level = 16, target = "BAYLEEF", form = 0 } },
    icon = "CHIKORITA/f0",
    portrait = "CHIKORITA/f0/male/plain",
    follower = { visualId = 20153, size = 4, objectParam = 1024 },
  }
end

function T.valid_forms_pass_andpredicates_mirror_validators()
  local MonAssetSchema = schema()
  Assert.isTrue(MonAssetSchema.assertForm(validForm(), {}))
  Assert.isTrue(MonAssetSchema.isValidForm(validForm(), {}))
end

function T.forms_reject_unknown_fields_and_bad_values()
  local MonAssetSchema = schema()
  local unknown = validForm()
  unknown.narcId = 7
  Assert.isFalse(MonAssetSchema.isValidForm(unknown, {}))
  local err = Assert.throws(function()
    MonAssetSchema.assertForm(unknown, {})
  end)
  Assert.isTrue(Errors.is(err))
  local badStats = validForm()
  badStats.baseStats.hp = 1000
  Assert.isFalse(MonAssetSchema.isValidForm(badStats, {}))
  local badOrder = validForm()
  badOrder.tmhm = { "CUT", "TOXIC" }
  Assert.isTrue(MonAssetSchema.isValidForm(badOrder, {}))
  local unsorted = validForm()
  unsorted.tmhm = { "TOXIC", "BULLET_SEED" }
  Assert.isFalse(MonAssetSchema.isValidForm(unsorted, {}))
  local noFollower = validForm()
  noFollower.follower = nil
  Assert.isTrue(MonAssetSchema.isValidForm(noFollower, {}))
end

local function fullItems()
  local items = {}
  for nativeId = 0, 536 do
    items["ITEM_" .. nativeId] = { nativeId = nativeId, isBall = false, friendshipBoost = false }
  end
  items["ITEM_0"] = nil
  items["NONE"] = { nativeId = 0, isBall = false, friendshipBoost = false }
  return items
end

local function catalogWith(species, moves, abilities, growthCurves)
  return {
    schema = "g4-mon-catalog-v2",
    version = { id = "heartgold", language = "english" },
    species = species,
    moves = moves,
    abilities = abilities,
    growthCurves = growthCurves,
    items = fullItems(),
  }
end

local function zeroCurves()
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

local function validSpecies()
  return {
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
      forms = { [0] = validForm() },
    },
    BAYLEEF = {
      nativeId = 153,
      name = "BAYLEEF",
      growthCurve = "medium_slow",
      baseFriendship = 70,
      genderRatio = 31,
      eggCycles = 20,
      eggGroups = { "monster", "grass" },
      catchRate = 45,
      baseExpYield = 142,
      evYield = { hp = 0, attack = 0, defense = 1, speed = 0, specialAttack = 0, specialDefense = 1 },
      heldItems = { common = { item = "NONE", nativeId = 0 }, rare = { item = "NONE", nativeId = 0 } },
      color = 3,
      flip = false,
      forms = { [0] = validForm() },
    },
  }
end

local function validMoves()
  return {
    NONE = {
      nativeId = 0,
      name = "-",
      description = "",
      effect = 0,
      category = "physical",
      power = 0,
      moveType = "normal",
      accuracy = 0,
      basePp = 0,
      effectChance = 0,
      range = 0,
      priority = 0,
      flags = 0,
      unknownC = 0,
      contestType = 0,
    },
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
      flags = 115,
      unknownC = 5,
      contestType = 4,
    },
    TOXIC = {
      nativeId = 92,
      name = "Toxic",
      description = "Badly poisons the foe.",
      effect = 3,
      category = "status",
      power = 0,
      moveType = "poison",
      accuracy = 85,
      basePp = 10,
      effectChance = 100,
      range = 0,
      priority = 0,
      flags = 0,
      unknownC = 0,
      contestType = 3,
    },
    CUT = {
      nativeId = 15,
      name = "Cut",
      description = "Cuts the foe.",
      effect = 0,
      category = "physical",
      power = 50,
      moveType = "normal",
      accuracy = 95,
      basePp = 30,
      effectChance = 0,
      range = 0,
      priority = 0,
      flags = 0,
      unknownC = 0,
      contestType = 4,
    },
    BULLET_SEED = {
      nativeId = 331,
      name = "Bullet Seed",
      description = "Shoots seeds.",
      effect = 0,
      category = "physical",
      power = 10,
      moveType = "grass",
      accuracy = 100,
      basePp = 30,
      effectChance = 0,
      range = 0,
      priority = 0,
      flags = 0,
      unknownC = 0,
      contestType = 4,
    },
  }
end

local function validAbilities()
  return {
    NONE = { nativeId = 0, name = " -", description = " -" },
    OVERGROW = { nativeId = 65, name = "Overgrow", description = "Powers up Grass." },
  }
end

function T.catalogs_resolve_every_cross_reference()
  local MonAssetSchema = schema()
  local catalog = catalogWith(validSpecies(), validMoves(), validAbilities(), zeroCurves())
  -- BAYLEEF's placeholder form references CHIKORITA's moves; point it at
  -- nothing dangling: the shared validForm already resolves.
  Assert.isTrue(MonAssetSchema.assertCatalog(catalog))
  Assert.isTrue(MonAssetSchema.isValidCatalog(catalog))
end

function T.catalogs_reject_dangling_references_and_duplicates()
  local MonAssetSchema = schema()
  local species = validSpecies()
  species.CHIKORITA.forms[0].abilities = { "BOGUS" }
  Assert.isFalse(MonAssetSchema.isValidCatalog(catalogWith(species, validMoves(), validAbilities(), zeroCurves())))
  local moves = validMoves()
  moves.BOGUS = validMoves().TACKLE
  moves.BOGUS.nativeId = 33
  Assert.isFalse(MonAssetSchema.isValidCatalog(catalogWith(validSpecies(), moves, validAbilities(), zeroCurves())))
  local noBase = validSpecies()
  noBase.CHIKORITA.forms = {}
  Assert.isFalse(MonAssetSchema.isValidCatalog(catalogWith(noBase, validMoves(), validAbilities(), zeroCurves())))
end

function T.manifests_require_entries_and_resolving_representatives()
  local MonAssetSchema = schema()
  local manifest = {
    schema = "g4-mon-icon-manifest-v1",
    image = "assets/generated/mon/icons.png",
    entries = {
      ["CHIKORITA/f0"] = {
        x = 0,
        y = 0,
        width = 32,
        height = 32,
        frames = { { x = 0, y = 0, width = 32, height = 32, duration = 8 } },
      },
    },
    representative = { "CHIKORITA/f0" },
  }
  Assert.isTrue(MonAssetSchema.assertIconManifest(manifest))
  Assert.isTrue(MonAssetSchema.isValidIconManifest(manifest))
  local dangling = {
    schema = "g4-mon-icon-manifest-v1",
    image = "assets/generated/mon/icons.png",
    entries = manifest.entries,
    representative = { "MISSING/f0" },
  }
  Assert.isFalse(MonAssetSchema.isValidIconManifest(dangling))
  local portrait = {
    schema = "g4-mon-portrait-manifest-v1",
    image = "assets/generated/mon/portraits.png",
    entries = manifest.entries,
    representative = { "CHIKORITA/f0" },
  }
  Assert.isTrue(MonAssetSchema.assertPortraitManifest(portrait))
  Assert.isFalse(MonAssetSchema.isValidPortraitManifest(manifest))
end

return { tests = T }
