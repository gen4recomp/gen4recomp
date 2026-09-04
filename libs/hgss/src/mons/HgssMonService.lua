-- HGSS mon service: the sole runtime owner of the live party, the exact
-- Generation-IV creation generator, the mon factory bound to HGSS
-- player/version policy, and every immediate mon/party script operation.
-- Constructed once per field runtime from a validated catalog and the
-- canonical mons save bucket; screens, scripts, and the follower selector
-- borrow it, and save capture asks it for a canonical bucket. Consumers
-- observe party changes by polling partyRevision; there are no callbacks.
-- Pure domain module: no rendering, actors, assets, or love resources.

local Experience = require("libs.mons.src.gen4.Experience")
local Mon = require("libs.mons.src.Mon")
local MonFactory = require("libs.mons.src.gen4.MonFactory")
local MonsErrors = require("libs.mons.src.errors")
local MonsSave = require("libs.mons.src.MonsSave")
local NativeLegality = require("libs.mons.src.gen4.NativeLegality")
local Personality = require("libs.mons.src.gen4.Personality")
local Stats = require("libs.mons.src.gen4.Stats")
local Errors = require("libs.errors.src.Errors")

---@class HgssMonService
---@field private _catalog MonCatalog
---@field private _context MonsSave.Context
---@field private _party Party
---@field private _rng Gen4Lcrng
---@field private _factory MonFactory
---@field private _profile { name: string, gender: integer, trainerId: integer }
---@field private _game string
---@field private _language string
---@field private _mapSection integer|fun(): integer|nil
---@field private _date MonDate|(fun(): MonDate)|nil
---@field private _itemById table<integer, string>|nil
local HgssMonService = {}
HgssMonService.__index = HgssMonService

-- Native game identities (pret/pokeheartgold version layout; the domain
-- tests pin heartgold to 7 and soulsilver to 8).
HgssMonService.GAMES = { heartgold = 7, soulsilver = 8 }

-- Native language identities in the Generation-IV mon data layout.
HgssMonService.LANGUAGES = {
  japanese = 1,
  english = 2,
  french = 3,
  italian = 4,
  german = 5,
  spanish = 7,
  korean = 8,
}

-- Native item identities 0..536 in source order (pret/pokeheartgold,
-- include/constants/items.h ITEM_* minus prefix, via romdump MonSources).
-- Index i carries the key for native identity i - 1.
local ITEM_IDS = {
  "NONE",
  "MASTER_BALL",
  "ULTRA_BALL",
  "GREAT_BALL",
  "POKE_BALL",
  "SAFARI_BALL",
  "NET_BALL",
  "DIVE_BALL",
  "NEST_BALL",
  "REPEAT_BALL",
  "TIMER_BALL",
  "LUXURY_BALL",
  "PREMIER_BALL",
  "DUSK_BALL",
  "HEAL_BALL",
  "QUICK_BALL",
  "CHERISH_BALL",
  "POTION",
  "ANTIDOTE",
  "BURN_HEAL",
  "ICE_HEAL",
  "AWAKENING",
  "PARLYZ_HEAL",
  "FULL_RESTORE",
  "MAX_POTION",
  "HYPER_POTION",
  "SUPER_POTION",
  "FULL_HEAL",
  "REVIVE",
  "MAX_REVIVE",
  "FRESH_WATER",
  "SODA_POP",
  "LEMONADE",
  "MOOMOO_MILK",
  "ENERGYPOWDER",
  "ENERGY_ROOT",
  "HEAL_POWDER",
  "REVIVAL_HERB",
  "ETHER",
  "MAX_ETHER",
  "ELIXIR",
  "MAX_ELIXIR",
  "LAVA_COOKIE",
  "BERRY_JUICE",
  "SACRED_ASH",
  "HP_UP",
  "PROTEIN",
  "IRON",
  "CARBOS",
  "CALCIUM",
  "RARE_CANDY",
  "PP_UP",
  "ZINC",
  "PP_MAX",
  "OLD_GATEAU",
  "GUARD_SPEC_",
  "DIRE_HIT",
  "X_ATTACK",
  "X_DEFENSE",
  "X_SPEED",
  "X_ACCURACY",
  "X_SPECIAL",
  "X_SP__DEF",
  "POKE_DOLL",
  "FLUFFY_TAIL",
  "BLUE_FLUTE",
  "YELLOW_FLUTE",
  "RED_FLUTE",
  "BLACK_FLUTE",
  "WHITE_FLUTE",
  "SHOAL_SALT",
  "SHOAL_SHELL",
  "RED_SHARD",
  "BLUE_SHARD",
  "YELLOW_SHARD",
  "GREEN_SHARD",
  "SUPER_REPEL",
  "MAX_REPEL",
  "ESCAPE_ROPE",
  "REPEL",
  "SUN_STONE",
  "MOON_STONE",
  "FIRE_STONE",
  "THUNDERSTONE",
  "WATER_STONE",
  "LEAF_STONE",
  "TINYMUSHROOM",
  "BIG_MUSHROOM",
  "PEARL",
  "BIG_PEARL",
  "STARDUST",
  "STAR_PIECE",
  "NUGGET",
  "HEART_SCALE",
  "HONEY",
  "GROWTH_MULCH",
  "DAMP_MULCH",
  "STABLE_MULCH",
  "GOOEY_MULCH",
  "ROOT_FOSSIL",
  "CLAW_FOSSIL",
  "HELIX_FOSSIL",
  "DOME_FOSSIL",
  "OLD_AMBER",
  "ARMOR_FOSSIL",
  "SKULL_FOSSIL",
  "RARE_BONE",
  "SHINY_STONE",
  "DUSK_STONE",
  "DAWN_STONE",
  "OVAL_STONE",
  "ODD_KEYSTONE",
  "GRISEOUS_ORB",
  "UNUSED_113",
  "UNUSED_114",
  "UNUSED_115",
  "UNUSED_116",
  "UNUSED_117",
  "UNUSED_118",
  "UNUSED_119",
  "UNUSED_120",
  "UNUSED_121",
  "UNUSED_122",
  "UNUSED_123",
  "UNUSED_124",
  "UNUSED_125",
  "UNUSED_126",
  "UNUSED_127",
  "UNUSED_128",
  "UNUSED_129",
  "UNUSED_130",
  "UNUSED_131",
  "UNUSED_132",
  "UNUSED_133",
  "UNUSED_134",
  "ADAMANT_ORB",
  "LUSTROUS_ORB",
  "GRASS_MAIL",
  "FLAME_MAIL",
  "BUBBLE_MAIL",
  "BLOOM_MAIL",
  "TUNNEL_MAIL",
  "STEEL_MAIL",
  "HEART_MAIL",
  "SNOW_MAIL",
  "SPACE_MAIL",
  "AIR_MAIL",
  "MOSAIC_MAIL",
  "BRICK_MAIL",
  "CHERI_BERRY",
  "CHESTO_BERRY",
  "PECHA_BERRY",
  "RAWST_BERRY",
  "ASPEAR_BERRY",
  "LEPPA_BERRY",
  "ORAN_BERRY",
  "PERSIM_BERRY",
  "LUM_BERRY",
  "SITRUS_BERRY",
  "FIGY_BERRY",
  "WIKI_BERRY",
  "MAGO_BERRY",
  "AGUAV_BERRY",
  "IAPAPA_BERRY",
  "RAZZ_BERRY",
  "BLUK_BERRY",
  "NANAB_BERRY",
  "WEPEAR_BERRY",
  "PINAP_BERRY",
  "POMEG_BERRY",
  "KELPSY_BERRY",
  "QUALOT_BERRY",
  "HONDEW_BERRY",
  "GREPA_BERRY",
  "TAMATO_BERRY",
  "CORNN_BERRY",
  "MAGOST_BERRY",
  "RABUTA_BERRY",
  "NOMEL_BERRY",
  "SPELON_BERRY",
  "PAMTRE_BERRY",
  "WATMEL_BERRY",
  "DURIN_BERRY",
  "BELUE_BERRY",
  "OCCA_BERRY",
  "PASSHO_BERRY",
  "WACAN_BERRY",
  "RINDO_BERRY",
  "YACHE_BERRY",
  "CHOPLE_BERRY",
  "KEBIA_BERRY",
  "SHUCA_BERRY",
  "COBA_BERRY",
  "PAYAPA_BERRY",
  "TANGA_BERRY",
  "CHARTI_BERRY",
  "KASIB_BERRY",
  "HABAN_BERRY",
  "COLBUR_BERRY",
  "BABIRI_BERRY",
  "CHILAN_BERRY",
  "LIECHI_BERRY",
  "GANLON_BERRY",
  "SALAC_BERRY",
  "PETAYA_BERRY",
  "APICOT_BERRY",
  "LANSAT_BERRY",
  "STARF_BERRY",
  "ENIGMA_BERRY",
  "MICLE_BERRY",
  "CUSTAP_BERRY",
  "JABOCA_BERRY",
  "ROWAP_BERRY",
  "BRIGHTPOWDER",
  "WHITE_HERB",
  "MACHO_BRACE",
  "EXP__SHARE",
  "QUICK_CLAW",
  "SOOTHE_BELL",
  "MENTAL_HERB",
  "CHOICE_BAND",
  "KINGS_ROCK",
  "SILVERPOWDER",
  "AMULET_COIN",
  "CLEANSE_TAG",
  "SOUL_DEW",
  "DEEPSEATOOTH",
  "DEEPSEASCALE",
  "SMOKE_BALL",
  "EVERSTONE",
  "FOCUS_BAND",
  "LUCKY_EGG",
  "SCOPE_LENS",
  "METAL_COAT",
  "LEFTOVERS",
  "DRAGON_SCALE",
  "LIGHT_BALL",
  "SOFT_SAND",
  "HARD_STONE",
  "MIRACLE_SEED",
  "BLACKGLASSES",
  "BLACK_BELT",
  "MAGNET",
  "MYSTIC_WATER",
  "SHARP_BEAK",
  "POISON_BARB",
  "NEVERMELTICE",
  "SPELL_TAG",
  "TWISTEDSPOON",
  "CHARCOAL",
  "DRAGON_FANG",
  "SILK_SCARF",
  "UPGRADE",
  "SHELL_BELL",
  "SEA_INCENSE",
  "LAX_INCENSE",
  "LUCKY_PUNCH",
  "METAL_POWDER",
  "THICK_CLUB",
  "STICK",
  "RED_SCARF",
  "BLUE_SCARF",
  "PINK_SCARF",
  "GREEN_SCARF",
  "YELLOW_SCARF",
  "WIDE_LENS",
  "MUSCLE_BAND",
  "WISE_GLASSES",
  "EXPERT_BELT",
  "LIGHT_CLAY",
  "LIFE_ORB",
  "POWER_HERB",
  "TOXIC_ORB",
  "FLAME_ORB",
  "QUICK_POWDER",
  "FOCUS_SASH",
  "ZOOM_LENS",
  "METRONOME",
  "IRON_BALL",
  "LAGGING_TAIL",
  "DESTINY_KNOT",
  "BLACK_SLUDGE",
  "ICY_ROCK",
  "SMOOTH_ROCK",
  "HEAT_ROCK",
  "DAMP_ROCK",
  "GRIP_CLAW",
  "CHOICE_SCARF",
  "STICKY_BARB",
  "POWER_BRACER",
  "POWER_BELT",
  "POWER_LENS",
  "POWER_BAND",
  "POWER_ANKLET",
  "POWER_WEIGHT",
  "SHED_SHELL",
  "BIG_ROOT",
  "CHOICE_SPECS",
  "FLAME_PLATE",
  "SPLASH_PLATE",
  "ZAP_PLATE",
  "MEADOW_PLATE",
  "ICICLE_PLATE",
  "FIST_PLATE",
  "TOXIC_PLATE",
  "EARTH_PLATE",
  "SKY_PLATE",
  "MIND_PLATE",
  "INSECT_PLATE",
  "STONE_PLATE",
  "SPOOKY_PLATE",
  "DRACO_PLATE",
  "DREAD_PLATE",
  "IRON_PLATE",
  "ODD_INCENSE",
  "ROCK_INCENSE",
  "FULL_INCENSE",
  "WAVE_INCENSE",
  "ROSE_INCENSE",
  "LUCK_INCENSE",
  "PURE_INCENSE",
  "PROTECTOR",
  "ELECTIRIZER",
  "MAGMARIZER",
  "DUBIOUS_DISC",
  "REAPER_CLOTH",
  "RAZOR_CLAW",
  "RAZOR_FANG",
  "TM01",
  "TM02",
  "TM03",
  "TM04",
  "TM05",
  "TM06",
  "TM07",
  "TM08",
  "TM09",
  "TM10",
  "TM11",
  "TM12",
  "TM13",
  "TM14",
  "TM15",
  "TM16",
  "TM17",
  "TM18",
  "TM19",
  "TM20",
  "TM21",
  "TM22",
  "TM23",
  "TM24",
  "TM25",
  "TM26",
  "TM27",
  "TM28",
  "TM29",
  "TM30",
  "TM31",
  "TM32",
  "TM33",
  "TM34",
  "TM35",
  "TM36",
  "TM37",
  "TM38",
  "TM39",
  "TM40",
  "TM41",
  "TM42",
  "TM43",
  "TM44",
  "TM45",
  "TM46",
  "TM47",
  "TM48",
  "TM49",
  "TM50",
  "TM51",
  "TM52",
  "TM53",
  "TM54",
  "TM55",
  "TM56",
  "TM57",
  "TM58",
  "TM59",
  "TM60",
  "TM61",
  "TM62",
  "TM63",
  "TM64",
  "TM65",
  "TM66",
  "TM67",
  "TM68",
  "TM69",
  "TM70",
  "TM71",
  "TM72",
  "TM73",
  "TM74",
  "TM75",
  "TM76",
  "TM77",
  "TM78",
  "TM79",
  "TM80",
  "TM81",
  "TM82",
  "TM83",
  "TM84",
  "TM85",
  "TM86",
  "TM87",
  "TM88",
  "TM89",
  "TM90",
  "TM91",
  "TM92",
  "HM01",
  "HM02",
  "HM03",
  "HM04",
  "HM05",
  "HM06",
  "HM07",
  "HM08",
  "EXPLORER_KIT",
  "LOOT_SACK",
  "RULE_BOOK",
  "POKE_RADAR",
  "POINT_CARD",
  "JOURNAL",
  "SEAL_CASE",
  "FASHION_CASE",
  "SEAL_BAG",
  "PAL_PAD",
  "WORKS_KEY",
  "OLD_CHARM",
  "GALACTIC_KEY",
  "RED_CHAIN",
  "TOWN_MAP",
  "VS__SEEKER",
  "COIN_CASE",
  "OLD_ROD",
  "GOOD_ROD",
  "SUPER_ROD",
  "SPRAYDUCK",
  "POFFIN_CASE",
  "BICYCLE",
  "SUITE_KEY",
  "OAKS_LETTER",
  "LUNAR_WING",
  "MEMBER_CARD",
  "AZURE_FLUTE",
  "S_S__TICKET",
  "CONTEST_PASS",
  "MAGMA_STONE",
  "PARCEL",
  "COUPON_1",
  "COUPON_2",
  "COUPON_3",
  "STORAGE_KEY",
  "SECRETPOTION",
  "VS__RECORDER",
  "GRACIDEA",
  "SECRET_KEY",
  "APRICORN_BOX",
  "UNOWN_REPORT",
  "BERRY_POTS",
  "DOWSING_MCHN",
  "BLUE_CARD",
  "SLOWPOKETAIL",
  "CLEAR_BELL",
  "CARD_KEY",
  "BASEMENT_KEY",
  "SQUIRTBOTTLE",
  "RED_SCALE",
  "LOST_ITEM",
  "PASS",
  "MACHINE_PART",
  "SILVER_WING",
  "RAINBOW_WING",
  "MYSTERY_EGG",
  "RED_APRICORN",
  "YLW_APRICORN",
  "BLU_APRICORN",
  "GRN_APRICORN",
  "PNK_APRICORN",
  "WHT_APRICORN",
  "BLK_APRICORN",
  "FAST_BALL",
  "LEVEL_BALL",
  "LURE_BALL",
  "HEAVY_BALL",
  "LOVE_BALL",
  "FRIEND_BALL",
  "MOON_BALL",
  "SPORT_BALL",
  "PARK_BALL",
  "PHOTO_ALBUM",
  "GB_SOUNDS",
  "TIDAL_BELL",
  "RAGECANDYBAR",
  "DATA_CARD_01",
  "DATA_CARD_02",
  "DATA_CARD_03",
  "DATA_CARD_04",
  "DATA_CARD_05",
  "DATA_CARD_06",
  "DATA_CARD_07",
  "DATA_CARD_08",
  "DATA_CARD_09",
  "DATA_CARD_10",
  "DATA_CARD_11",
  "DATA_CARD_12",
  "DATA_CARD_13",
  "DATA_CARD_14",
  "DATA_CARD_15",
  "DATA_CARD_16",
  "DATA_CARD_17",
  "DATA_CARD_18",
  "DATA_CARD_19",
  "DATA_CARD_20",
  "DATA_CARD_21",
  "DATA_CARD_22",
  "DATA_CARD_23",
  "DATA_CARD_24",
  "DATA_CARD_25",
  "DATA_CARD_26",
  "DATA_CARD_27",
  "JADE_ORB",
  "LOCK_CAPSULE",
  "RED_ORB",
  "BLUE_ORB",
  "ENIGMA_STONE",
}

-- Native ball identities are the ball subset of the item identities.
local BALL_KEYS = {
  "MASTER_BALL",
  "ULTRA_BALL",
  "GREAT_BALL",
  "POKE_BALL",
  "SAFARI_BALL",
  "NET_BALL",
  "DIVE_BALL",
  "NEST_BALL",
  "REPEAT_BALL",
  "TIMER_BALL",
  "LUXURY_BALL",
  "PREMIER_BALL",
  "DUSK_BALL",
  "HEAL_BALL",
  "QUICK_BALL",
  "CHERISH_BALL",
  "PARK_BALL",
  "FAST_BALL",
  "LEVEL_BALL",
  "LURE_BALL",
  "HEAVY_BALL",
  "LOVE_BALL",
  "FRIEND_BALL",
  "MOON_BALL",
  "SPORT_BALL",
}

-- Source gender values written at the script variable boundary.
HgssMonService.GENDER_MALE = 0
HgssMonService.GENDER_FEMALE = 1
HgssMonService.GENDERLESS = 2

-- Absent-slot sentinel written at the script variable boundary when a party
-- search finds no mon. Six is the source party size, never a valid slot.
HgssMonService.NO_SLOT = 6

-- Nature display names in native 0..24 order.
local NATURE_NAMES = {
  "Hardy",
  "Lonely",
  "Brave",
  "Adamant",
  "Naughty",
  "Bold",
  "Docile",
  "Relaxed",
  "Impish",
  "Lax",
  "Timid",
  "Hasty",
  "Serious",
  "Jolly",
  "Naive",
  "Modest",
  "Mild",
  "Quiet",
  "Bashful",
  "Rash",
  "Calm",
  "Gentle",
  "Sassy",
  "Careful",
  "Quirky",
}

-- Contest value keys in native contest-type order.
local CONTEST_KEYS = { "cool", "beauty", "cute", "smart", "tough", "sheen" }

---@param ids string[]
---@return table<string, integer>
local function keyTable(ids)
  local out = {}
  for index, key in ipairs(ids) do
    out[key] = index - 1
  end
  return out
end

HgssMonService.ITEMS = keyTable(ITEM_IDS)

---@return table<string, integer>
local function ballTable()
  local out = {}
  for _, key in ipairs(BALL_KEYS) do
    local nativeId = HgssMonService.ITEMS[key]
    assert(nativeId ~= nil, "ball identity is missing from the item table: " .. key)
    out[key] = nativeId
  end
  return out
end

HgssMonService.BALLS = ballTable()

---@param nature integer
---@return string
function HgssMonService.natureName(nature)
  assert(
    type(nature) == "number" and nature % 1 == 0 and nature >= 0 and nature <= 24,
    "nature name requires an integer in 0..24"
  )
  return NATURE_NAMES[nature + 1]
end

---@alias MonDate { year: integer, month: integer, day: integer }

---@class HgssMonServiceOptions
---@field catalog MonCatalog
---@field bucket MonsSave.Bucket
---@field profile { name: string, gender: integer, trainerId: integer }
---@field game string
---@field language string
---@field charmap table<string, unknown>
---@field games table<string, unknown>?
---@field languages table<string, unknown>?
---@field items table<string, unknown>?
---@field balls table<string, unknown>?
---@field mapSection? integer|fun(): integer|nil
---@field date? MonDate|(fun(): MonDate)|nil
---@field dateProvider? (fun(): MonDate)|nil
---@param opts HgssMonServiceOptions
---@return HgssMonService
function HgssMonService.new(opts)
  assert(type(opts) == "table", "mon service requires an options record")
  assert(opts.catalog ~= nil, "mon service requires a catalog")
  assert(type(opts.bucket) == "table", "mon service requires a mons bucket")
  assert(type(opts.profile) == "table", "mon service requires an owner profile")
  assert(type(opts.game) == "string", "mon service requires a game key")
  assert(type(opts.language) == "string", "mon service requires a language key")
  assert(type(opts.charmap) == "table", "mon service requires a charmap")
  local games = opts.games or HgssMonService.GAMES
  local languages = opts.languages or HgssMonService.LANGUAGES
  local items = opts.items or HgssMonService.ITEMS
  local balls = opts.balls or HgssMonService.BALLS
  assert(type(games) == "table" and games[opts.game] ~= nil, "mon service game must resolve")
  assert(type(languages) == "table" and languages[opts.language] ~= nil, "mon service language must resolve")
  local context = {
    catalog = opts.catalog,
    charmap = opts.charmap,
    games = games,
    languages = languages,
    items = items,
    balls = balls,
  }
  local restored = MonsSave.restore(opts.bucket, context)
  local profile = {
    name = opts.profile.name,
    gender = opts.profile.gender,
    trainerId = opts.profile.trainerId,
  }
  assert(type(profile.name) == "string", "mon service profile requires a trainer name")
  assert(type(profile.trainerId) == "number", "mon service profile requires a trainer id")
  local factory = MonFactory.new({
    catalog = opts.catalog,
    rng = restored.rng,
    charmap = opts.charmap,
    games = games,
    languages = languages,
    items = items,
    balls = balls,
    game = opts.game,
    language = opts.language,
  })
  return setmetatable({
    _catalog = opts.catalog,
    _context = context,
    _party = restored.party,
    _rng = restored.rng,
    _factory = factory,
    _profile = profile,
    _game = opts.game,
    _language = opts.language,
    _mapSection = opts.mapSection,
    _date = opts.date ~= nil and opts.date or opts.dateProvider,
  }, HgssMonService)
end

---@return MonCatalog
function HgssMonService:catalog()
  return self._catalog
end

---@return table<string, unknown>
function HgssMonService:capture()
  return MonsSave.capture(self._party:capture(), self._rng:capture(), self._catalog:fingerprint())
end

---@return integer
function HgssMonService:partyCount()
  return self._party:count()
end

---@return integer
function HgssMonService:partyRevision()
  return self._party:revision()
end

---@param slot0 integer
---@return table<string, unknown>
function HgssMonService:partyMon(slot0)
  return self._party:get(slot0)
end

---@return integer|nil
function HgssMonService:leadSlot()
  return self._party:leadSlot()
end

---@return integer|nil
function HgssMonService:leadAliveSlot()
  return self._party:leadAliveSlot()
end

---@param slot0 integer
---@param what string
local function checkSlotNumber(slot0, what)
  if type(slot0) ~= "number" or slot0 % 1 ~= 0 then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, what .. " slot must be an integer", { slot = slot0 })
  end
end

---@param value string|integer
---@return string
function HgssMonService:_speciesKey(value)
  if type(value) == "string" then
    self._catalog:species(value)
    return value
  end
  if type(value) == "number" and value % 1 == 0 then
    return self._catalog:speciesKeyByNativeId(value)
  end
  MonsErrors.raise(MonsErrors.RECORD_INVALID, "species identity must be a key or native id", {})
  error("unreachable", 0)
end

---@param value string|integer
---@return string
function HgssMonService:_moveKey(value)
  if type(value) == "string" then
    self._catalog:move(value)
    return value
  end
  if type(value) == "number" and value % 1 == 0 then
    return self._catalog:moveKeyByNativeId(value)
  end
  MonsErrors.raise(MonsErrors.RECORD_INVALID, "move identity must be a key or native id", {})
  error("unreachable", 0)
end

---@param value string|integer|nil
---@return string|nil
function HgssMonService:_abilityKeyOrNil(value)
  -- The source default sentinels (0 in vanilla gifts, 0xFFFF) keep the
  -- PID-selected ability; a nonzero operand names a native ability.
  if value == nil or value == 0 or value == 0xFFFF then
    return nil
  end
  if type(value) == "string" then
    self._catalog:ability(value)
    return value
  end
  if type(value) == "number" and value % 1 == 0 then
    return self._catalog:abilityKeyByNativeId(value)
  end
  MonsErrors.raise(MonsErrors.RECORD_INVALID, "ability identity must be a key or native id", {})
  error("unreachable", 0)
end

---@param tableName string
---@param cacheField string
---@return table<integer, string>
function HgssMonService:_reverseIdentities(tableName, cacheField)
  local cached = self[cacheField]
  if cached ~= nil then
    return cached
  end
  local forward = self._context[tableName]
  assert(type(forward) == "table", "mon service identity table is required: " .. tableName)
  local reverse = {}
  for key, nativeId in pairs(forward) do
    if reverse[nativeId] == nil then
      reverse[nativeId] = key
    end
  end
  self[cacheField] = reverse
  return reverse
end

---@param value string|integer|nil
---@return string
function HgssMonService:_itemKey(value)
  if value == nil then
    return "NONE"
  end
  if type(value) == "string" then
    local items = self._context.items
    assert(type(items) == "table", "mon service item table is required")
    if items[value] == nil then
      MonsErrors.raise(MonsErrors.RECORD_INVALID, "unknown held item " .. value, { item = value })
    end
    return value
  end
  if type(value) == "number" and value % 1 == 0 then
    local key = self:_reverseIdentities("items", "_itemById")[value]
    if key == nil then
      MonsErrors.raise(MonsErrors.RECORD_INVALID, "unknown native item identity " .. value, { nativeId = value })
    end
    assert(key ~= nil, "identity table carries the resolved key")
    return key
  end
  MonsErrors.raise(MonsErrors.RECORD_INVALID, "held item identity must be a key or native id", {})
  error("unreachable", 0)
end

---@param request table<string, unknown>
---@return integer
function HgssMonService:_metLocation(request)
  if request.location ~= nil then
    if type(request.location) ~= "number" or request.location % 1 ~= 0 or request.location < 0 then
      MonsErrors.raise(MonsErrors.RECORD_INVALID, "met location must be a non-negative integer", {})
    end
    return request.location
  end
  local section = self._mapSection
  ---@type integer|nil
  local value = nil
  if type(section) == "function" then
    value = section()
  elseif type(section) == "number" then
    value = section
  end
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "script-gift creation requires the current map section", {})
  end
  assert(type(value) == "number", "met location resolved to a non-negative integer")
  return value
end

---@param request table<string, unknown>
---@return MonDate
function HgssMonService:_metDate(request)
  local configured = request.date ~= nil and request.date or self._date
  ---@type MonDate|nil
  local date = nil
  if type(configured) == "function" then
    date = configured()
  elseif type(configured) == "table" then
    date = configured
  end
  if type(date) ~= "table" then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "script-gift creation requires a met date", {})
  end
  assert(type(date) == "table", "met date resolved to a date record")
  return { year = date.year, month = date.month, day = date.day }
end

---@param slot0 integer
---@return table<string, unknown>
function HgssMonService:_liveMon(slot0)
  checkSlotNumber(slot0, "party")
  return self._party:get(slot0)
end

---@param slot0 integer
---@param mon table<string, unknown>
function HgssMonService:_store(slot0, mon)
  local canonical = Mon.validate(mon, self._context)
  self._party:set(slot0, canonical)
end

---@param mon table<string, unknown>
---@return integer
function HgssMonService:_level(mon)
  local species = self._catalog:species(mon.species)
  return Experience.level(self._catalog:growthCurve(species.growthCurve), mon.experience)
end

---@param mon table<string, unknown>
---@return integer
function HgssMonService:_maxHp(mon)
  local form = self._catalog:form(mon.species, mon.form)
  local nature = Personality.nature(mon.personality)
  local derived = Stats.calculate(form.baseStats, mon.ivs, mon.evs, self:_level(mon), nature)
  if mon.species == "SHEDINJA" then
    return 1
  end
  return derived.hp
end

---@param mon table<string, unknown>
---@return boolean
function HgssMonService:_isOwned(mon)
  return mon.origin.trainerId == self._profile.trainerId and mon.origin.trainerName == self._profile.name
end

---@param mon table<string, unknown>
---@return table<string, unknown>
function HgssMonService:_checked(mon)
  local canonical = Mon.validate(mon, self._context)
  NativeLegality.project(canonical, self._context)
  return canonical
end

-- Adds a validated legal mon; false when the party is full, without
-- mutation. There is no PC fallback.
---@param mon table<string, unknown>
---@return boolean
function HgssMonService:addMon(mon)
  return self._party:add(self:_checked(mon))
end

---@param slot0 integer
---@return table<string, unknown>
function HgssMonService:removeMon(slot0)
  checkSlotNumber(slot0, "party removal")
  return self._party:remove(slot0)
end

---@param left0 integer
---@param right0 integer
function HgssMonService:swapPartyMons(left0, right0)
  checkSlotNumber(left0, "party swap")
  checkSlotNumber(right0, "party swap")
  self._party:swap(left0, right0)
end

-- Builds one starter candidate through the source starter policy without
-- touching the party. The starter task pre-creates all three candidates
-- through this operation and publishes the confirmed instance with addMon,
-- so generation never observes party fullness and confirmation never
-- rerolls. Species and form validation run before any generator draw.
---@param speciesKey string
---@param metContext { location: integer?, date: MonDate|(fun(): MonDate)|nil }?
---@return table<string, unknown>
function HgssMonService:buildStarter(speciesKey, metContext)
  assert(type(speciesKey) == "string", "starter creation requires a species key")
  local species = self:_speciesKey(speciesKey)
  self._catalog:form(species, 0)
  local context = metContext or {}
  assert(type(context) == "table", "starter met context must be a record")
  return self._factory:createStarter({
    species = species,
    profile = self._profile,
    location = self:_metLocation(context),
    date = self:_metDate(context),
  })
end

-- Creates the starter candidate through the source starter policy and
-- inserts the exact instance into the party.
---@param speciesKey string
---@param metContext { location: integer, date: MonDate|(fun(): MonDate)|nil }
---@return table<string, unknown>
function HgssMonService:createStarter(speciesKey, metContext)
  assert(type(speciesKey) == "string", "starter creation requires a species key")
  assert(type(metContext) == "table", "starter creation requires a met context")
  local mon = self:buildStarter(speciesKey, metContext)
  local added = self._party:add(mon)
  assert(added, "starter selection requires a free party slot")
  return self._party:get(self._party:count() - 1)
end

-- Field-script gift in source order: the current map section resolves
-- first, creation consumes its exact generator draws even when the party
-- is full, then insertion reports the source boolean result. Only the
-- Pokedex update is omitted, because no Pokedex owner exists. Invalid
-- identity data fails explicitly without adding a mon.
---@param request { species: string|integer, level: integer, heldItem?: string|integer, form?: integer, ability?: string|integer, location?: integer, date?: MonDate|(fun(): MonDate) }
---@return boolean
function HgssMonService:giveMon(request)
  assert(type(request) == "table", "script-gift creation requires a request record")
  local species = self:_speciesKey(request.species)
  if type(request.level) ~= "number" or request.level % 1 ~= 0 or request.level < 1 or request.level > 100 then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "script-gift level must be an integer in 1..100", {})
  end
  local form = request.form ~= nil and request.form or 0
  if type(form) ~= "number" or form % 1 ~= 0 or form < 0 then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "script-gift form must be a non-negative integer", {})
  end
  local mon = self._factory:createScriptGift({
    species = species,
    level = request.level,
    profile = self._profile,
    ball = "POKE_BALL",
    location = self:_metLocation(request),
    date = self:_metDate(request),
    heldItem = self:_itemKey(request.heldItem),
    form = form,
    ability = self:_abilityKeyOrNil(request.ability),
  })
  return self._party:add(mon)
end

---@param slot0 integer
---@return table<string, unknown>
function HgssMonService:returnLoanMon(slot0)
  checkSlotNumber(slot0, "loan return")
  return self._party:remove(slot0)
end

-- Sets one move slot: an index below the current count replaces, an index
-- exactly at the end appends while slots remain, anything else fails.
---@param slot0 integer
---@param moveSlot0 integer
---@param move string|integer
function HgssMonService:setMove(slot0, moveSlot0, move)
  local mon = self:_liveMon(slot0)
  checkSlotNumber(moveSlot0, "move")
  local key = self:_moveKey(move)
  local definition = self._catalog:move(key)
  local moves = {}
  for index, entry in ipairs(mon.moves) do
    moves[index] = { move = entry.move, pp = entry.pp, ppUps = entry.ppUps }
  end
  local entry = { move = key, pp = definition.basePp, ppUps = 0 }
  if moveSlot0 < #moves then
    moves[moveSlot0 + 1] = entry
  elseif moveSlot0 == #moves and #moves < 4 then
    moves[#moves + 1] = entry
  else
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "move slot is out of range", { slot = moveSlot0 })
  end
  mon.moves = moves
  self:_store(slot0, mon)
end

---@param slot0 integer
---@param moveSlot0 integer
function HgssMonService:deleteMove(slot0, moveSlot0)
  local mon = self:_liveMon(slot0)
  checkSlotNumber(moveSlot0, "move")
  if moveSlot0 >= #mon.moves then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "move slot is out of range", { slot = moveSlot0 })
  end
  local moves = {}
  for index, entry in ipairs(mon.moves) do
    if index ~= moveSlot0 + 1 then
      moves[#moves + 1] = { move = entry.move, pp = entry.pp, ppUps = entry.ppUps }
    end
  end
  mon.moves = moves
  self:_store(slot0, mon)
end

---@param slot0 integer
---@param move string|integer
---@return boolean
function HgssMonService:monHasMove(slot0, move)
  local key = self:_moveKey(move)
  for _, entry in ipairs(self:_liveMon(slot0).moves) do
    if entry.move == key then
      return true
    end
  end
  return false
end

---@param move string|integer
---@return integer|nil
function HgssMonService:partySlotWithMove(move)
  local key = self:_moveKey(move)
  return self._party:findFirst(function(mon)
    for _, entry in ipairs(mon.moves) do
      if entry.move == key then
        return true
      end
    end
    return false
  end)
end

---@param slot0 integer
---@return integer
function HgssMonService:countMonMoves(slot0)
  return #self:_liveMon(slot0).moves
end

---@param slot0 integer
---@param moveSlot0 integer
---@return integer
function HgssMonService:monMove(slot0, moveSlot0)
  local mon = self:_liveMon(slot0)
  checkSlotNumber(moveSlot0, "move")
  local entry = mon.moves[moveSlot0 + 1]
  if entry == nil then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "move slot is out of range", { slot = moveSlot0 })
  end
  assert(entry ~= nil, "move entry carries the validated move")
  return self._catalog:move(entry.move).nativeId
end

---@param slot0 integer
---@return integer
function HgssMonService:partyMonSpecies(slot0)
  return self._catalog:species(self:_liveMon(slot0).species).nativeId
end

---@param slot0 integer
---@return boolean
function HgssMonService:partyMonIsMine(slot0)
  if type(slot0) ~= "number" or slot0 % 1 ~= 0 or slot0 < 0 or slot0 >= self._party:count() then
    return false
  end
  return self:_isOwned(self._party:get(slot0))
end

---@return integer
function HgssMonService:partyCountNotEgg()
  local count = 0
  for index = 0, self._party:count() - 1 do
    if not self._party:get(index).isEgg then
      count = count + 1
    end
  end
  return count
end

---@return integer
function HgssMonService:partyCountEgg()
  local count = 0
  for index = 0, self._party:count() - 1 do
    if self._party:get(index).isEgg then
      count = count + 1
    end
  end
  return count
end

-- Alive party mons only: conscious non-egg members. An excluded slot
-- (the party size when nothing is excluded) skips exactly that position.
-- Counts that include PC storage stay deferred to the absent box aggregate.
---@param excludeSlot integer|nil
---@return integer
function HgssMonService:countAliveMons(excludeSlot)
  local excluded = nil
  if excludeSlot ~= nil and excludeSlot ~= HgssMonService.NO_SLOT then
    checkSlotNumber(excludeSlot, "alive count exclusion")
    if excludeSlot < 0 or excludeSlot >= self._party:count() then
      MonsErrors.raise(MonsErrors.SAVE_INVALID, "alive count exclusion slot is out of range", { slot = excludeSlot })
    end
    excluded = excludeSlot
  end
  local count = 0
  for index = 0, self._party:count() - 1 do
    if index ~= excluded then
      local mon = self._party:get(index)
      if not mon.isEgg and mon.condition.currentHp > 0 then
        count = count + 1
      end
    end
  end
  return count
end

---@param level integer
---@return integer
function HgssMonService:partyCountAtOrBelowLevel(level)
  if type(level) ~= "number" or level % 1 ~= 0 or level < 1 or level > 100 then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "level bound must be an integer in 1..100", {})
  end
  local count = 0
  for index = 0, self._party:count() - 1 do
    if self:_level(self._party:get(index)) <= level then
      count = count + 1
    end
  end
  return count
end

---@param species string|integer
---@return integer
function HgssMonService:countSpecies(species)
  local key = self:_speciesKey(species)
  local count = 0
  for index = 0, self._party:count() - 1 do
    if self._party:get(index).species == key then
      count = count + 1
    end
  end
  return count
end

---@param species string|integer
---@return integer|nil
function HgssMonService:partySlotWithSpecies(species)
  return self._party:findFirst(function(mon)
    return mon.species == self:_speciesKey(species)
  end)
end

---@param slot0 integer
---@return integer
function HgssMonService:monNature(slot0)
  return Personality.nature(self:_liveMon(slot0).personality)
end

---@param nature integer
---@return integer|nil
function HgssMonService:partySlotWithNature(nature)
  if type(nature) ~= "number" or nature % 1 ~= 0 or nature < 0 or nature > 24 then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "nature must be an integer in 0..24", {})
  end
  return self._party:findFirst(function(mon)
    return Personality.nature(mon.personality) == nature
  end)
end

---@param slot0 integer
---@return integer
function HgssMonService:monGender(slot0)
  local mon = self:_liveMon(slot0)
  local ratio = self._catalog:species(mon.species).genderRatio
  local gender = Personality.gender(ratio, mon.personality)
  if gender == "male" then
    return HgssMonService.GENDER_MALE
  end
  if gender == "female" then
    return HgssMonService.GENDER_FEMALE
  end
  return HgssMonService.GENDERLESS
end

---@param slot0 integer
---@return integer
function HgssMonService:monFriendship(slot0)
  return self:_liveMon(slot0).friendship
end

---@param slot0 integer
---@param amount integer
---@return integer
function HgssMonService:monAddFriendship(slot0, amount)
  local mon = self:_liveMon(slot0)
  if type(amount) ~= "number" or amount % 1 ~= 0 or amount < 0 or amount > 255 then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "friendship delta must be an integer in 0..255", {})
  end
  mon.friendship = math.min(255, mon.friendship + amount)
  self:_store(slot0, mon)
  return mon.friendship
end

---@param slot0 integer
---@param amount integer
---@return integer
function HgssMonService:monSubFriendship(slot0, amount)
  local mon = self:_liveMon(slot0)
  if type(amount) ~= "number" or amount % 1 ~= 0 or amount < 0 or amount > 255 then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "friendship delta must be an integer in 0..255", {})
  end
  mon.friendship = math.max(0, mon.friendship - amount)
  self:_store(slot0, mon)
  return mon.friendship
end

---@param index integer
---@return string
local function contestKey(index)
  if type(index) ~= "number" or index % 1 ~= 0 or index < 0 or index > 5 then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "contest type must be an integer in 0..5", {})
  end
  return CONTEST_KEYS[index + 1]
end

---@param slot0 integer
---@param index integer
---@return integer
function HgssMonService:monContestValue(slot0, index)
  return self:_liveMon(slot0).contest[contestKey(index)]
end

---@param slot0 integer
---@param index integer
---@param amount integer
---@return integer
function HgssMonService:monAddContestValue(slot0, index, amount)
  local mon = self:_liveMon(slot0)
  if type(amount) ~= "number" or amount % 1 ~= 0 or amount < 0 or amount > 255 then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "contest delta must be an integer in 0..255", {})
  end
  local key = contestKey(index)
  mon.contest[key] = math.min(255, mon.contest[key] + amount)
  self:_store(slot0, mon)
  return mon.contest[key]
end

---@param value number
---@return integer
local function popcount(value)
  local count = 0
  local remaining = value
  while remaining > 0 do
    count = count + (remaining % 2)
    remaining = math.floor(remaining / 2)
  end
  return math.floor(count)
end

---@param slot0 integer
---@return integer
function HgssMonService:monRibbonCount(slot0)
  local ribbons = self:_liveMon(slot0).ribbons
  return popcount(ribbons.ds1) + popcount(ribbons.gba) + popcount(ribbons.ds2)
end

---@return integer
function HgssMonService:partyRibbonCount()
  local total = 0
  for index = 0, self._party:count() - 1 do
    total = total + self:monRibbonCount(index)
  end
  return total
end

---@return boolean
function HgssMonService:partyHasPokerus()
  for index = 0, self._party:count() - 1 do
    if self._party:get(index).pokerus ~= 0 then
      return true
    end
  end
  return false
end

---@param slot0 integer
---@return { level: integer, maxHp: integer }
function HgssMonService:partyMonDerived(slot0)
  local mon = self:_liveMon(slot0)
  return { level = self:_level(mon), maxHp = self:_maxHp(mon) }
end

---@param slot0 integer
---@return integer
function HgssMonService:monForm(slot0)
  return self:_liveMon(slot0).form
end

---@return boolean
function HgssMonService:partyLegal()
  for index = 0, self._party:count() - 1 do
    local ok, result = pcall(NativeLegality.project, self._party:get(index), self._context)
    if not ok then
      if Errors.is(result) then
        return false
      end
      error(result, 0)
    end
  end
  return true
end

---@return boolean
function HgssMonService:hasKyogreGroudon()
  for _, key in ipairs({ "KYOGRE", "GROUDON" }) do
    local known = pcall(function()
      self._catalog:species(key)
    end)
    if known and self:countSpecies(key) > 0 then
      return true
    end
  end
  return false
end

---@param species string|integer|nil
---@return integer|nil
function HgssMonService:partySlotWithFatefulEncounter(species)
  local key = nil
  if species ~= nil then
    key = self:_speciesKey(species)
  end
  return self._party:findFirst(function(mon)
    if not mon.fatefulEncounter then
      return false
    end
    return key == nil or mon.species == key
  end)
end

-- Restores every party mon to full health and clears persistent status
-- through the aggregate, one owned mutation per mon.
function HgssMonService:healParty()
  for index = 0, self._party:count() - 1 do
    local mon = self._party:get(index)
    mon.condition = { status = 0, currentHp = self:_maxHp(mon) }
    self:_store(index, mon)
  end
end

return HgssMonService
