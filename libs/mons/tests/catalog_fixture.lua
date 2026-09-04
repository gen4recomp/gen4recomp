-- Synthetic catalog and domain-test helpers for the mon domain package.
-- The asset root built here satisfies the generated mon catalog contract so
-- domain tests exercise the locked catalog shape without touching ROM data
-- or the produced cache. Glyph codes below are the real field-font codes for
-- the covered characters. Native game, language, item, and ball identities
-- are the fixed translation tables the domain tests assume at every codec
-- and legality boundary.

local MonAssetSchema = require("libs.assets.src.MonAssetSchema")

local CatalogFixture = {}

CatalogFixture.CHARMAP = {
  A = 0x12B,
  B = 0x12C,
  C = 0x12D,
  D = 0x12E,
  E = 0x12F,
  F = 0x130,
  G = 0x131,
  H = 0x132,
  I = 0x133,
  J = 0x134,
  K = 0x135,
  L = 0x136,
  M = 0x137,
  N = 0x138,
  O = 0x139,
  P = 0x13A,
  Q = 0x13B,
  R = 0x13C,
  S = 0x13D,
  T = 0x13E,
  U = 0x13F,
  V = 0x140,
  W = 0x141,
  X = 0x142,
  Y = 0x143,
  Z = 0x144,
  ["0"] = 0x121,
  ["1"] = 0x122,
  ["2"] = 0x123,
  ["3"] = 0x124,
  ["4"] = 0x125,
  ["5"] = 0x126,
  ["6"] = 0x127,
  ["7"] = 0x128,
  ["8"] = 0x129,
  ["9"] = 0x12A,
  ["-"] = 0x1BE,
  [" "] = 0x1DE,
}

CatalogFixture.GAMES = { heartgold = 7, soulsilver = 8 }
CatalogFixture.LANGUAGES = { english = 2 }
CatalogFixture.ITEMS = { NONE = 0, POKE_BALL = 4, GREAT_BALL = 3, SITRUS_BERRY = 158 }
CatalogFixture.BALLS = { POKE_BALL = 4, GREAT_BALL = 3 }

function CatalogFixture.profile()
  return { name = "RED", gender = 0, trainerId = 2271560481 }
end

-- Synthetic item collection satisfying the generated catalog contract: every
-- source native identity 0..536 resolves exactly once. Only the domain-known
-- keys carry meaningful ball facts; the rest are inert placeholders.
function CatalogFixture.itemTable()
  local known = { NONE = 0, POKE_BALL = 4, GREAT_BALL = 3, SITRUS_BERRY = 158 }
  local items = {}
  local covered = {}
  for key, nativeId in pairs(known) do
    items[key] = { nativeId = nativeId, isBall = nativeId == 4 or nativeId == 3, friendshipBoost = false }
    covered[nativeId] = true
  end
  for nativeId = 0, 536 do
    if not covered[nativeId] then
      items["ITEM_" .. nativeId] = { nativeId = nativeId, isBall = false, friendshipBoost = false }
    end
  end
  return items
end

function CatalogFixture.metDate()
  return { year = 2009, month = 9, day = 13 }
end

local function statSet(hp, attack, defense, speed, specialAttack, specialDefense)
  return {
    hp = hp,
    attack = attack,
    defense = defense,
    speed = speed,
    specialAttack = specialAttack,
    specialDefense = specialDefense,
  }
end

local function moveEntry(nativeId, name, description, category, power, moveType, accuracy, basePp)
  return {
    nativeId = nativeId,
    name = name,
    description = description,
    effect = 0,
    category = category,
    power = power,
    moveType = moveType,
    accuracy = accuracy,
    basePp = basePp,
    effectChance = 0,
    range = 0,
    priority = 0,
    flags = 0,
    unknownC = 0,
    contestType = 0,
  }
end

local function abilityEntry(nativeId, name)
  return { nativeId = nativeId, name = name, description = name }
end

local function formEntry(baseStats, types, abilities, tmhm, levelUpMoves, icon, portrait, follower)
  return {
    baseStats = baseStats,
    types = types,
    abilities = abilities,
    tmhm = tmhm,
    levelUpMoves = levelUpMoves,
    evolutions = {},
    icon = icon,
    portrait = portrait,
    follower = follower,
  }
end

local function learnset(list)
  local out = {}
  for _, item in ipairs(list) do
    out[#out + 1] = { level = item[1], move = item[2] }
  end
  return out
end

local function speciesEntry(fields)
  return {
    nativeId = fields.nativeId,
    name = fields.name,
    growthCurve = fields.growthCurve,
    baseFriendship = 70,
    genderRatio = fields.genderRatio,
    eggCycles = 20,
    eggGroups = fields.eggGroups,
    catchRate = 45,
    baseExpYield = fields.baseExpYield,
    evYield = fields.evYield,
    heldItems = {
      common = { item = "NONE", nativeId = 0 },
      rare = { item = "NONE", nativeId = 0 },
    },
    color = 3,
    flip = false,
    forms = fields.forms,
  }
end

local function growthTables()
  local curves = {}
  local mediumSlow = {}
  local mediumFast = {}
  local fast = {}
  local slow = {}
  local erratic = {}
  local fluctuating = {}
  for level = 1, 100 do
    local cube = level * level * level
    mediumSlow[level] = math.floor(6 * cube / 5) - 15 * level * level + 100 * level - 140
    mediumFast[level] = cube
    fast[level] = math.floor(4 * cube / 5)
    slow[level] = math.floor(5 * cube / 4)
    if level <= 50 then
      erratic[level] = math.floor(cube * (100 - level) / 50)
    elseif level <= 68 then
      erratic[level] = math.floor(cube * (150 - level) / 100)
    elseif level <= 98 then
      erratic[level] = math.floor(cube * math.floor((1911 - 10 * level) / 3) / 500)
    else
      erratic[level] = math.floor(cube * (160 - level) / 100)
    end
    if level <= 15 then
      fluctuating[level] = math.floor(cube * (math.floor((level + 1) / 3) + 24) / 50)
    elseif level <= 36 then
      fluctuating[level] = math.floor(cube * (level + 14) / 50)
    else
      fluctuating[level] = math.floor(cube * (math.floor(level / 2) + 32) / 50)
    end
  end
  curves.medium_slow = mediumSlow
  curves.medium_fast = mediumFast
  curves.fast = fast
  curves.slow = slow
  curves.erratic = erratic
  curves.fluctuating = fluctuating
  -- The closed forms drift around zero at level one while every real table
  -- opens at exactly zero experience, so pin the first entry. All level-two
  -- values are already positive, which keeps every curve non-decreasing.
  for _, curve in pairs({ mediumSlow, mediumFast, fast, slow, erratic, fluctuating }) do
    curve[1] = 0
  end
  local unused = {}
  for level = 1, 100 do
    unused[level] = 0
  end
  curves.unused_6 = unused
  curves.unused_7 = unused
  return curves
end

function CatalogFixture.buildAssetRoot()
  local root = {
    schema = "g4-mon-catalog-v2",
    version = { id = "heartgold", language = "english" },
    species = {
      CHIKORITA = speciesEntry({
        nativeId = 152,
        name = "CHIKORITA",
        growthCurve = "medium_slow",
        genderRatio = 31,
        eggGroups = { "monster", "grass" },
        baseExpYield = 64,
        evYield = statSet(0, 0, 0, 0, 0, 1),
        forms = {
          [0] = formEntry(
            statSet(45, 49, 65, 45, 49, 65),
            { "grass" },
            { "OVERGROW" },
            { "BULLET_SEED", "CUT", "TOXIC" },
            learnset({
              { 1, "TACKLE" },
              { 1, "GROWL" },
              { 1, "TACKLE" },
              { 6, "RAZOR_LEAF" },
              { 9, "POISONPOWDER" },
              { 12, "SYNTHESIS" },
              { 15, "REFLECT" },
            }),
            "CHIKORITA/f0",
            "CHIKORITA/f0/male/plain",
            { visualId = 20153, size = 4, objectParam = 1024 }
          ),
        },
      }),
      TOTODILE = speciesEntry({
        nativeId = 158,
        name = "TOTODILE",
        growthCurve = "medium_slow",
        genderRatio = 31,
        eggGroups = { "monster", "water" },
        baseExpYield = 66,
        evYield = statSet(0, 1, 0, 0, 0, 0),
        forms = {
          [0] = formEntry(
            statSet(50, 65, 64, 43, 44, 48),
            { "water" },
            { "TORRENT" },
            { "CUT" },
            learnset({ { 1, "SCRATCH" }, { 1, "LEER" }, { 6, "WATER_GUN" } }),
            "TOTODILE/f0",
            "TOTODILE/f0/male/plain",
            { visualId = 20154, size = 4, objectParam = 1025 }
          ),
        },
      }),
      EEVEE = speciesEntry({
        nativeId = 133,
        name = "EEVEE",
        growthCurve = "medium_fast",
        genderRatio = 31,
        eggGroups = { "field", "field" },
        baseExpYield = 92,
        evYield = statSet(0, 0, 0, 0, 0, 1),
        forms = {
          [0] = formEntry(
            statSet(55, 55, 50, 55, 45, 65),
            { "normal" },
            { "RUN_AWAY", "ADAPTABILITY" },
            { "TOXIC" },
            learnset({ { 1, "TACKLE" }, { 1, "TAIL_WHIP" }, { 8, "SAND_ATTACK" }, { 15, "QUICK_ATTACK" } }),
            "EEVEE/f0",
            "EEVEE/f0/male/plain"
          ),
          [1] = formEntry(
            statSet(55, 60, 50, 55, 45, 65),
            { "normal" },
            { "ADAPTABILITY" },
            { "TOXIC" },
            learnset({ { 1, "TACKLE" }, { 1, "TAIL_WHIP" }, { 8, "SAND_ATTACK" }, { 15, "QUICK_ATTACK" } }),
            "EEVEE/f1",
            "EEVEE/f1/male/plain"
          ),
        },
      }),
      SHEDINJA = speciesEntry({
        nativeId = 292,
        name = "SHEDINJA",
        growthCurve = "erratic",
        genderRatio = 255,
        eggGroups = { "mineral", "mineral" },
        baseExpYield = 178,
        evYield = statSet(0, 2, 0, 0, 0, 0),
        forms = {
          [0] = formEntry(
            statSet(1, 90, 45, 40, 30, 30),
            { "bug", "ghost" },
            { "WONDER_GUARD" },
            { "TOXIC" },
            learnset({ { 1, "SCRATCH" }, { 1, "HARDEN" } }),
            "SHEDINJA/f0",
            "SHEDINJA/f0/male/plain"
          ),
        },
      }),
    },
    moves = {
      TACKLE = moveEntry(33, "Tackle", "Charges the foe.", "physical", 35, "normal", 95, 35),
      GROWL = moveEntry(45, "Growl", "Growls to lower attack.", "status", 0, "normal", 100, 40),
      RAZOR_LEAF = moveEntry(75, "Razor Leaf", "Cuts with sharp leaves.", "physical", 55, "grass", 95, 25),
      POISONPOWDER = moveEntry(77, "PoisonPowder", "Scatters poison.", "status", 0, "poison", 75, 35),
      SYNTHESIS = moveEntry(235, "Synthesis", "Restores HP.", "status", 0, "grass", 100, 5),
      REFLECT = moveEntry(115, "Reflect", "Raises defense.", "status", 0, "psychic", 100, 20),
      SCRATCH = moveEntry(10, "Scratch", "Scratches the foe.", "physical", 40, "normal", 100, 35),
      LEER = moveEntry(43, "Leer", "Lowers defense.", "status", 0, "normal", 100, 30),
      WATER_GUN = moveEntry(55, "Water Gun", "Shoots water.", "special", 40, "water", 100, 25),
      TAIL_WHIP = moveEntry(39, "Tail Whip", "Lowers defense.", "status", 0, "normal", 100, 30),
      SAND_ATTACK = moveEntry(28, "Sand Attack", "Lowers accuracy.", "status", 0, "ground", 100, 15),
      QUICK_ATTACK = moveEntry(98, "Quick Attack", "Strikes first.", "physical", 40, "normal", 100, 30),
      HARDEN = moveEntry(106, "Harden", "Raises defense.", "status", 0, "normal", 100, 30),
      BULLET_SEED = moveEntry(331, "Bullet Seed", "Shoots seeds.", "physical", 10, "grass", 100, 30),
      CUT = moveEntry(15, "Cut", "Cuts the foe.", "physical", 50, "normal", 95, 30),
      TOXIC = moveEntry(92, "Toxic", "Badly poisons the foe.", "status", 0, "poison", 85, 10),
    },
    abilities = {
      OVERGROW = abilityEntry(65, "Overgrow"),
      TORRENT = abilityEntry(67, "Torrent"),
      RUN_AWAY = abilityEntry(50, "Run Away"),
      ADAPTABILITY = abilityEntry(91, "Adaptability"),
      WONDER_GUARD = abilityEntry(25, "Wonder Guard"),
    },
    growthCurves = growthTables(),
    items = CatalogFixture.itemTable(),
  }
  assert(MonAssetSchema.assertCatalog(root))
  return root
end

function CatalogFixture.makeCatalog()
  local Catalog = require("libs.mons.src.MonCatalog")
  return Catalog.new(CatalogFixture.buildAssetRoot())
end

function CatalogFixture.domainContext(catalog)
  return {
    catalog = catalog,
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  }
end

function CatalogFixture.factoryArgs(seed, catalog)
  local Lcrng = require("libs.mons.src.gen4.Lcrng")
  return {
    catalog = catalog,
    rng = Lcrng.new(seed),
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    game = "heartgold",
    language = "english",
  }
end

function CatalogFixture.makeFactory(seed, catalog)
  local MonFactory = require("libs.mons.src.gen4.MonFactory")
  return MonFactory.new(CatalogFixture.factoryArgs(seed, catalog))
end

function CatalogFixture.normalRequest(overrides)
  local request = {
    species = "CHIKORITA",
    level = 9,
    form = 0,
    profile = CatalogFixture.profile(),
    ball = "POKE_BALL",
    location = 7,
    terrain = 4,
    date = CatalogFixture.metDate(),
  }
  for key, value in pairs(overrides or {}) do
    request[key] = value
  end
  return request
end

function CatalogFixture.toHex(data)
  local parts = {}
  for index = 1, #data do
    parts[#parts + 1] = string.format("%02x", string.byte(data, index))
  end
  return table.concat(parts)
end

function CatalogFixture.fromHex(text)
  assert(#text % 2 == 0, "hex text must carry whole bytes")
  local parts = {}
  for index = 1, #text, 2 do
    parts[#parts + 1] = string.char(tonumber(text:sub(index, index + 1), 16))
  end
  return table.concat(parts)
end

return CatalogFixture
