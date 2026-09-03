-- Semantic mon records. The authoritative runtime representation is the
-- readable g4-mon-v1 record; derivable values (level, nature, gender,
-- shininess, maximum stats) are never stored and unknown fields fail, so a
-- persisted record cannot contradict its own personality, identity, or
-- experience. Validation returns an owned canonical copy and never repairs
-- malformed data. Pure domain module: derivations come from the catalog and
-- the generation helpers.

local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")
local Validate = require("libs.assets.src.Validate")
local Experience = require("libs.mons.src.gen4.Experience")
local MonsErrors = require("libs.mons.src.errors")
local Personality = require("libs.mons.src.gen4.Personality")
local Stats = require("libs.mons.src.gen4.Stats")

---@class Mon
local Mon = {}

Mon.SCHEMA = "g4-mon-v1"
Mon.NICKNAME_CAPACITY = 11
Mon.OT_NAME_CAPACITY = 8

local TOP_FIELDS = {
  schema = true,
  species = true,
  form = true,
  personality = true,
  experience = true,
  friendship = true,
  ability = true,
  heldItem = true,
  markings = true,
  evs = true,
  contest = true,
  moves = true,
  ivs = true,
  isEgg = true,
  nickname = true,
  ribbons = true,
  fatefulEncounter = true,
  shinyLeaves = true,
  egg = true,
  met = true,
  origin = true,
  pokerus = true,
  mood = true,
  condition = true,
  capsule = true,
  mail = true,
}

local STAT_KEYS = { "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }
local CONTEST_KEYS = { "cool", "beauty", "cute", "smart", "tough", "sheen" }
local MOVE_FIELDS = { move = true, pp = true, ppUps = true }
local RIBBON_FIELDS = { ds1 = true, gba = true, ds2 = true }
local EGG_FIELDS = { location = true, date = true }
local MET_FIELDS = { location = true, date = true, level = true, terrain = true }
local ORIGIN_FIELDS = {
  trainerId = true,
  trainerName = true,
  trainerGender = true,
  game = true,
  ball = true,
  language = true,
}
local CONDITION_FIELDS = { status = true, currentHp = true }
local CAPSULE_FIELDS = { id = true, seals = true }
local SEAL_FIELDS = { x = true, y = true, graphic = true }
local DATE_FIELDS = { year = true, month = true, day = true }

---@param record table
---@param allowed table<string, boolean>
---@param what string
local function checkKeys(record, allowed, what)
  for key in pairs(record) do
    if allowed[key] == nil then
      MonsErrors.raise(MonsErrors.RECORD_INVALID, what .. " carries unknown field " .. tostring(key), {})
    end
  end
end

---@param value any
---@param bound integer
---@param what string
local function checkIntRange(value, bound, what)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > bound then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, what .. " must be an integer in 0.." .. bound, {})
  end
end

---@param value any
---@param what string
local function checkU8(value, what)
  checkIntRange(value, 255, what)
end

---@param value any
---@param what string
local function checkU16(value, what)
  checkIntRange(value, 65535, what)
end

---@param value any
---@param what string
local function checkU32(value, what)
  checkIntRange(value, 4294967295, what)
end

---@param text any
---@param charmap table
---@param capacity integer
---@param what string
---@return integer
local function checkText(text, charmap, capacity, what)
  if type(text) ~= "string" then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, what .. " must be a string", {})
  end
  local glyphs = 0
  for glyph in Utf8Glyphs.iter(text) do
    if charmap[glyph] == nil then
      MonsErrors.raise(MonsErrors.RECORD_INVALID, what .. " carries an unencodable glyph", {})
    end
    glyphs = glyphs + 1
  end
  if glyphs + 1 > capacity then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, what .. " exceeds its glyph capacity", {})
  end
  return glyphs
end

---@param date any
---@param what string
local function checkDate(date, what)
  if type(date) ~= "table" then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, what .. " must be a record", {})
  end
  checkKeys(date, DATE_FIELDS, what)
  if type(date.year) ~= "number" or date.year % 1 ~= 0 or date.year < 2000 or date.year > 2255 then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, what .. ".year must be an integer in 2000..2255", {})
  end
  if type(date.month) ~= "number" or date.month % 1 ~= 0 or date.month < 1 or date.month > 12 then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, what .. ".month must be an integer in 1..12", {})
  end
  if type(date.day) ~= "number" or date.day % 1 ~= 0 or date.day < 1 or date.day > 31 then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, what .. ".day must be an integer in 1..31", {})
  end
end

---@param value any
---@return any
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copyValue(item)
  end
  return out
end

-- Maximum power points for a move: base value plus one fifth per power-point
-- up, at most three ups.
---@param definition table
---@return integer
local function maxPp(definition)
  return definition.basePp + 3 * math.floor(definition.basePp / 5)
end

---@param record table
---@param context table
---@return table
function Mon.validate(record, context)
  assert(type(context) == "table", "mon validation requires a context")
  assert(context.catalog ~= nil, "mon validation requires a catalog")
  assert(type(context.charmap) == "table", "mon validation requires a charmap")
  if type(record) ~= "table" then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "mon must be a record", {})
  end
  checkKeys(record, TOP_FIELDS, "mon")
  local catalog = context.catalog

  if record.schema ~= Mon.SCHEMA then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "mon schema must be " .. Mon.SCHEMA, {})
  end

  local species = catalog:species(record.species)
  local form = catalog:form(record.species, record.form)
  checkU32(record.personality, "personality")
  checkU32(record.experience, "experience")
  local curve = catalog:growthCurve(species.growthCurve)
  if record.experience > curve[100] then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "experience exceeds the level-100 entry", {})
  end
  local level = Experience.level(curve, record.experience)

  checkU8(record.friendship, "friendship")
  catalog:ability(record.ability)
  local permitted = false
  for _, key in ipairs(form.abilities) do
    if key == record.ability then
      permitted = true
    end
  end
  if not permitted then
    MonsErrors.raise(
      MonsErrors.RECORD_INVALID,
      "ability " .. record.ability .. " is not permitted by the selected form",
      { ability = record.ability }
    )
  end
  if context.items == nil or context.items[record.heldItem] == nil then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "unknown held item " .. tostring(record.heldItem), {})
  end
  checkU8(record.markings, "markings")

  if type(record.evs) ~= "table" then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "effort values must be a record", {})
  end
  checkKeys(
    record.evs,
    { hp = true, attack = true, defense = true, speed = true, specialAttack = true, specialDefense = true },
    "effort values"
  )
  local evTotal = 0
  for _, key in ipairs(STAT_KEYS) do
    checkU8(record.evs[key], "effort value " .. key)
    evTotal = evTotal + record.evs[key]
  end
  if evTotal > 510 then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "effort value total exceeds 510", {})
  end

  if type(record.contest) ~= "table" then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "contest values must be a record", {})
  end
  checkKeys(
    record.contest,
    { cool = true, beauty = true, cute = true, smart = true, tough = true, sheen = true },
    "contest values"
  )
  for _, key in ipairs(CONTEST_KEYS) do
    checkU8(record.contest[key], "contest value " .. key)
  end

  if not Validate.isArray(record.moves) or #record.moves > 4 then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "moves must be an array of at most four entries", {})
  end
  local seen = {}
  for index, entry in ipairs(record.moves) do
    if type(entry) ~= "table" then
      MonsErrors.raise(MonsErrors.RECORD_INVALID, "move entry " .. index .. " must be a record", {})
    end
    checkKeys(entry, MOVE_FIELDS, "move entry " .. index)
    local definition = catalog:move(entry.move)
    if seen[entry.move] then
      MonsErrors.raise(MonsErrors.RECORD_INVALID, "duplicate move " .. entry.move, { move = entry.move })
    end
    seen[entry.move] = true
    if type(entry.pp) ~= "number" or entry.pp % 1 ~= 0 or entry.pp < 0 or entry.pp > maxPp(definition) then
      MonsErrors.raise(MonsErrors.RECORD_INVALID, "move entry " .. index .. " carries invalid power points", {})
    end
    if type(entry.ppUps) ~= "number" or entry.ppUps % 1 ~= 0 or entry.ppUps < 0 or entry.ppUps > 3 then
      MonsErrors.raise(MonsErrors.RECORD_INVALID, "move entry " .. index .. " carries invalid power-point ups", {})
    end
  end

  if type(record.ivs) ~= "table" then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "individual values must be a record", {})
  end
  checkKeys(
    record.ivs,
    { hp = true, attack = true, defense = true, speed = true, specialAttack = true, specialDefense = true },
    "individual values"
  )
  for _, key in ipairs(STAT_KEYS) do
    if type(record.ivs[key]) ~= "number" or record.ivs[key] % 1 ~= 0 or record.ivs[key] < 0 or record.ivs[key] > 31 then
      MonsErrors.raise(MonsErrors.RECORD_INVALID, "individual value " .. key .. " must be 0..31", {})
    end
  end

  if type(record.isEgg) ~= "boolean" then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "egg flag must be a boolean", {})
  end
  if record.nickname ~= nil then
    checkText(record.nickname, context.charmap, Mon.NICKNAME_CAPACITY, "nickname")
  end

  if type(record.ribbons) ~= "table" then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "ribbons must be a record", {})
  end
  checkKeys(record.ribbons, RIBBON_FIELDS, "ribbons")
  checkU32(record.ribbons.ds1, "ribbon field ds1")
  checkU32(record.ribbons.gba, "ribbon field gba")
  if
    type(record.ribbons.ds2) ~= "number"
    or record.ribbons.ds2 % 1 ~= 0
    or record.ribbons.ds2 < 0
    or record.ribbons.ds2 > 9007199254740991
  then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "ribbon field ds2 must be an exactly representable u64", {})
  end

  if type(record.fatefulEncounter) ~= "boolean" then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "fateful-encounter flag must be a boolean", {})
  end
  checkIntRange(record.shinyLeaves, 63, "shiny leaves")

  if type(record.egg) ~= "table" then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "egg record must be a record", {})
  end
  checkKeys(record.egg, EGG_FIELDS, "egg record")
  checkU16(record.egg.location, "egg location")
  if record.egg.date ~= nil then
    checkDate(record.egg.date, "egg date")
  end

  if type(record.met) ~= "table" then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "met record must be a record", {})
  end
  checkKeys(record.met, MET_FIELDS, "met record")
  checkU16(record.met.location, "met location")
  checkDate(record.met.date, "met date")
  if
    type(record.met.level) ~= "number"
    or record.met.level % 1 ~= 0
    or record.met.level < 1
    or record.met.level > 100
  then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "met level must be an integer in 1..100", {})
  end
  checkU8(record.met.terrain, "met terrain")

  if type(record.origin) ~= "table" then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "origin record must be a record", {})
  end
  checkKeys(record.origin, ORIGIN_FIELDS, "origin record")
  checkU32(record.origin.trainerId, "trainer id")
  checkText(record.origin.trainerName, context.charmap, Mon.OT_NAME_CAPACITY, "trainer name")
  if
    type(record.origin.trainerGender) ~= "number"
    or record.origin.trainerGender % 1 ~= 0
    or (record.origin.trainerGender ~= 0 and record.origin.trainerGender ~= 1)
  then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "trainer gender must be 0 or 1", {})
  end
  if context.games == nil or context.games[record.origin.game] == nil then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "unknown game " .. tostring(record.origin.game), {})
  end
  if context.balls == nil or context.balls[record.origin.ball] == nil then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "unknown ball " .. tostring(record.origin.ball), {})
  end
  if context.languages == nil or context.languages[record.origin.language] == nil then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "unknown language " .. tostring(record.origin.language), {})
  end

  checkU8(record.pokerus, "pokerus")
  if type(record.mood) ~= "number" or record.mood % 1 ~= 0 or record.mood < -128 or record.mood > 127 then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "mood must be an integer in -128..127", {})
  end

  if type(record.condition) ~= "table" then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "condition record must be a record", {})
  end
  checkKeys(record.condition, CONDITION_FIELDS, "condition record")
  checkU32(record.condition.status, "status condition")
  local nature = Personality.nature(record.personality)
  local derived = Stats.calculate(form.baseStats, record.ivs, record.evs, level, nature)
  local maxHp = derived.hp
  if record.species == "SHEDINJA" then
    maxHp = 1
  end
  if
    type(record.condition.currentHp) ~= "number"
    or record.condition.currentHp % 1 ~= 0
    or record.condition.currentHp < 0
    or record.condition.currentHp > maxHp
  then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "current health exceeds the derived maximum", {})
  end

  if type(record.capsule) ~= "table" then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "capsule record must be a record", {})
  end
  checkKeys(record.capsule, CAPSULE_FIELDS, "capsule record")
  checkU8(record.capsule.id, "capsule id")
  if not Validate.isArray(record.capsule.seals) or #record.capsule.seals > 8 then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "capsule seals must be an array of at most eight entries", {})
  end
  for index, seal in ipairs(record.capsule.seals) do
    if type(seal) ~= "table" then
      MonsErrors.raise(MonsErrors.RECORD_INVALID, "capsule seal " .. index .. " must be a record", {})
    end
    checkKeys(seal, SEAL_FIELDS, "capsule seal " .. index)
    checkU8(seal.x, "capsule seal x")
    checkU8(seal.y, "capsule seal y")
    checkU8(seal.graphic, "capsule seal graphic")
  end

  if type(record.mail) ~= "table" then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "mail record must be a record", {})
  end
  checkKeys(record.mail, {}, "mail record")

  return copyValue(record)
end

---@param record table
---@param catalog table
---@return string
function Mon.displayName(record, catalog)
  assert(type(record) == "table", "display name requires a mon record")
  assert(catalog ~= nil, "display name requires a catalog")
  if record.nickname ~= nil then
    return record.nickname
  end
  return catalog:species(record.species).name
end

return Mon
