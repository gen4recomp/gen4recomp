-- Authoritative validation for the generated mon asset class. Catalogs,
-- class indexes, and icon/portrait manifests are plain source-independent
-- data: every loader, producer writer, and test calls these validators, so
-- no second interpretation of the shapes exists. Unknown fields, duplicate
-- identities, out-of-range values, and dangling cross-references fail loudly.
-- Order is significant only for level-up learnsets and evolution slots, which
-- the source consumes positionally. Per-form checks are structural (they take
-- only an error context); catalog checks additionally resolve every
-- species/move/ability reference against the catalog's own keys. Love-free
-- and filesystem-free.

local Errors = require("libs.errors.src.Errors")
local Validate = require("libs.assets.src.Validate")

---@class MonAssetSchema
local MonAssetSchema = {}

local STAT_KEYS = { "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }

local STAT_SET = { hp = true, attack = true, defense = true, speed = true, specialAttack = true, specialDefense = true }

local GROWTH_KEYS = {
  medium_fast = true,
  erratic = true,
  fluctuating = true,
  medium_slow = true,
  fast = true,
  slow = true,
  unused_6 = true,
  unused_7 = true,
}

local TYPE_KEYS = {
  normal = true,
  fighting = true,
  flying = true,
  poison = true,
  ground = true,
  rock = true,
  bug = true,
  ghost = true,
  steel = true,
  mystery = true,
  fire = true,
  water = true,
  grass = true,
  electric = true,
  psychic = true,
  ice = true,
  dragon = true,
  dark = true,
}

local CATEGORY_KEYS = { physical = true, special = true, status = true }

local EVO_METHODS = {
  friendship = true,
  friendship_day = true,
  friendship_night = true,
  level = true,
  trade = true,
  trade_item = true,
  stone = true,
  level_atk_gt_def = true,
  level_atk_eq_def = true,
  level_atk_lt_def = true,
  level_pid_lo = true,
  level_pid_hi = true,
  level_ninjask = true,
  level_shedinja = true,
  beauty = true,
  stone_male = true,
  stone_female = true,
  item_day = true,
  item_night = true,
  has_move = true,
  other_party_mon = true,
  level_male = true,
  level_female = true,
  coronet = true,
  eterna = true,
  route217 = true,
}

local LEVEL_METHODS = {
  level = true,
  level_atk_gt_def = true,
  level_atk_eq_def = true,
  level_atk_lt_def = true,
  level_pid_lo = true,
  level_pid_hi = true,
  level_ninjask = true,
  level_shedinja = true,
  level_male = true,
  level_female = true,
}

local ITEM_METHODS = {
  trade_item = true,
  stone = true,
  stone_male = true,
  stone_female = true,
  item_day = true,
  item_night = true,
}

local NO_PARAM_METHODS = {
  friendship = true,
  friendship_day = true,
  friendship_night = true,
  trade = true,
  coronet = true,
  eterna = true,
  route217 = true,
}

local FORM_FIELDS = {
  baseStats = true,
  types = true,
  abilities = true,
  tmhm = true,
  levelUpMoves = true,
  evolutions = true,
  icon = true,
  portrait = true,
  follower = true,
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

local function checkU8(value, context, code, field)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > 255 then
    fail(code, field .. " must be a u8", context)
  end
end

local function checkNonEmptyString(value, context, code, field)
  if type(value) ~= "string" or value == "" then
    fail(code, field .. " must be a non-empty string", context)
  end
end

local function checkStats(stats, context, code)
  if type(stats) ~= "table" then
    fail(code, "stats must be a record", context)
  end
  checkKeys(stats, STAT_SET, context, code)
  for _, key in ipairs(STAT_KEYS) do
    checkU8(stats[key], context, code, "stats." .. key)
  end
end

local function checkEvYield(evYield, context, code)
  if type(evYield) ~= "table" then
    fail(code, "evYield must be a record", context)
  end
  checkKeys(evYield, STAT_SET, context, code)
  for _, key in ipairs(STAT_KEYS) do
    local value = evYield[key]
    if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > 3 then
      fail(code, "evYield." .. key .. " must be 0..3", context)
    end
  end
end

local function checkItemIdentity(identity, context, code, field)
  if type(identity) ~= "table" then
    fail(code, field .. " must be a record", context)
  end
  checkKeys(identity, { item = true, nativeId = true }, context, code)
  checkNonEmptyString(identity.item, context, code, field .. ".item")
  if
    type(identity.nativeId) ~= "number"
    or identity.nativeId % 1 ~= 0
    or identity.nativeId < 0
    or identity.nativeId > 536
  then
    fail(code, field .. ".nativeId must be 0..536", context)
  end
end

local function checkStringArray(values, context, code, field, minCount, maxCount)
  if not Validate.isArray(values) or #values < minCount or #values > maxCount then
    fail(code, field .. " must carry " .. minCount .. ".." .. maxCount .. " entries", context)
  end
  local seen = {}
  for _, value in ipairs(values) do
    checkNonEmptyString(value, context, code, field)
    if seen[value] then
      fail(code, "duplicate " .. field .. " entry " .. value, context)
    end
    seen[value] = true
  end
end

local function checkEvolutionShape(entry, context, code)
  if type(entry) ~= "table" then
    fail(code, "evolution must be a record", context)
  end
  local method = entry.method
  if type(method) ~= "string" or EVO_METHODS[method] == nil then
    fail(code, "evolution method is unknown: " .. tostring(method), context)
  end
  checkNonEmptyString(entry.target, context, code, "evolution target")
  if type(entry.form) ~= "number" or entry.form % 1 ~= 0 or entry.form < 0 then
    fail(code, "evolution form must be a non-negative integer", context)
  end
  if LEVEL_METHODS[method] then
    checkKeys(entry, { method = true, level = true, target = true, form = true }, context, code)
    if type(entry.level) ~= "number" or entry.level % 1 ~= 0 or entry.level < 1 or entry.level > 100 then
      fail(code, "evolution level must be 1..100", context)
    end
  elseif ITEM_METHODS[method] then
    checkKeys(entry, { method = true, item = true, target = true, form = true }, context, code)
    checkNonEmptyString(entry.item, context, code, "evolution item")
  elseif method == "beauty" then
    checkKeys(entry, { method = true, threshold = true, target = true, form = true }, context, code)
    if
      type(entry.threshold) ~= "number"
      or entry.threshold % 1 ~= 0
      or entry.threshold < 1
      or entry.threshold > 255
    then
      fail(code, "evolution threshold must be 1..255", context)
    end
  elseif method == "has_move" then
    checkKeys(entry, { method = true, move = true, target = true, form = true }, context, code)
    checkNonEmptyString(entry.move, context, code, "evolution move")
  elseif method == "other_party_mon" then
    checkKeys(entry, { method = true, species = true, target = true, form = true }, context, code)
    checkNonEmptyString(entry.species, context, code, "evolution species")
  elseif NO_PARAM_METHODS[method] then
    checkKeys(entry, { method = true, target = true, form = true }, context, code)
  else
    fail(code, "evolution method has no parameter rule: " .. method, context)
  end
end

local function checkFollowerShape(follower, context, code)
  if type(follower) ~= "table" then
    fail(code, "follower must be a record", context)
  end
  checkKeys(follower, { visualId = true, size = true, objectParam = true, female = true }, context, code)
  if type(follower.visualId) ~= "number" or follower.visualId % 1 ~= 0 or follower.visualId <= 0 then
    fail(code, "follower visualId must be a positive integer", context)
  end
  checkU8(follower.size, context, code, "follower.size")
  if
    type(follower.objectParam) ~= "number"
    or follower.objectParam % 1 ~= 0
    or follower.objectParam < 0
    or follower.objectParam > 65535
  then
    fail(code, "follower objectParam must be a u16", context)
  end
  if follower.female ~= nil then
    if type(follower.female) ~= "table" then
      fail(code, "follower.female must be a record", context)
    end
    checkKeys(follower.female, { visualId = true, size = true, objectParam = true }, context, code)
    if
      type(follower.female.visualId) ~= "number"
      or follower.female.visualId % 1 ~= 0
      or follower.female.visualId <= 0
    then
      fail(code, "follower.female visualId must be a positive integer", context)
    end
    checkU8(follower.female.size, context, code, "follower.female.size")
    if
      type(follower.female.objectParam) ~= "number"
      or follower.female.objectParam % 1 ~= 0
      or follower.female.objectParam < 0
      or follower.female.objectParam > 65535
    then
      fail(code, "follower.female objectParam must be a u16", context)
    end
  end
end

-- Structural form validation: shapes, ranges, and field sets. Reference
-- membership (species/move/ability keys, manifest selectors) is the catalog
-- and writer cross-reference step, which owns the full key universes.
function MonAssetSchema.assertForm(form, context)
  context = context or {}
  if type(form) ~= "table" then
    fail("MON_FORM_INVALID", "form must be a record", context)
  end
  checkKeys(form, FORM_FIELDS, context, "MON_FORM_INVALID")
  checkStats(form.baseStats, context, "MON_FORM_INVALID")
  if not Validate.isArray(form.types) or (#form.types ~= 1 and #form.types ~= 2) then
    fail("MON_FORM_INVALID", "types must carry one or two entries", context)
  end
  for _, typeKey in ipairs(form.types) do
    if TYPE_KEYS[typeKey] == nil then
      fail("MON_FORM_INVALID", "unknown type " .. tostring(typeKey), context)
    end
  end
  checkStringArray(form.abilities, context, "MON_FORM_INVALID", "abilities", 1, 2)
  if not Validate.isArray(form.tmhm) then
    fail("MON_FORM_INVALID", "tmhm must be an array", context)
  end
  local lastMachine = nil
  local seenMachines = {}
  for _, moveKey in ipairs(form.tmhm) do
    checkNonEmptyString(moveKey, context, "MON_FORM_INVALID", "tmhm move")
    if seenMachines[moveKey] then
      fail("MON_FORM_INVALID", "duplicate tmhm move " .. moveKey, context)
    end
    seenMachines[moveKey] = true
    if lastMachine ~= nil and moveKey <= lastMachine then
      fail("MON_FORM_INVALID", "tmhm moves must be sorted", context)
    end
    lastMachine = moveKey
  end
  if not Validate.isArray(form.levelUpMoves) then
    fail("MON_FORM_INVALID", "levelUpMoves must be an array", context)
  end
  for _, entry in ipairs(form.levelUpMoves) do
    if type(entry) ~= "table" then
      fail("MON_FORM_INVALID", "learnset entry must be a record", context)
    end
    checkKeys(entry, { level = true, move = true }, context, "MON_FORM_INVALID")
    if type(entry.level) ~= "number" or entry.level % 1 ~= 0 or entry.level < 1 or entry.level > 100 then
      fail("MON_FORM_INVALID", "learnset level must be 1..100", context)
    end
    checkNonEmptyString(entry.move, context, "MON_FORM_INVALID", "learnset move")
  end
  if not Validate.isArray(form.evolutions) then
    fail("MON_FORM_INVALID", "evolutions must be an array", context)
  end
  for _, entry in ipairs(form.evolutions) do
    checkEvolutionShape(entry, context, "MON_FORM_INVALID")
  end
  checkNonEmptyString(form.icon, context, "MON_FORM_INVALID", "icon selector")
  checkNonEmptyString(form.portrait, context, "MON_FORM_INVALID", "portrait selector")
  if form.follower ~= nil then
    checkFollowerShape(form.follower, context, "MON_FORM_INVALID")
  end
  return true
end

function MonAssetSchema.isValidForm(form, context)
  return pcall(MonAssetSchema.assertForm, form, context)
end

local SPECIES_FIELDS = {
  nativeId = true,
  name = true,
  growthCurve = true,
  baseFriendship = true,
  genderRatio = true,
  eggCycles = true,
  eggGroups = true,
  catchRate = true,
  baseExpYield = true,
  evYield = true,
  heldItems = true,
  color = true,
  flip = true,
  forms = true,
}

local function assertSpecies(key, species, context)
  if type(species) ~= "table" then
    fail("MON_CATALOG_INVALID", "species " .. key .. " must be a record", context)
  end
  checkKeys(species, SPECIES_FIELDS, context, "MON_CATALOG_INVALID")
  if
    type(species.nativeId) ~= "number"
    or species.nativeId % 1 ~= 0
    or species.nativeId < 0
    or species.nativeId > 495
  then
    fail("MON_CATALOG_INVALID", "species " .. key .. " nativeId must be 0..495", context)
  end
  checkNonEmptyString(species.name, context, "MON_CATALOG_INVALID", "species " .. key .. " name")
  if GROWTH_KEYS[species.growthCurve] == nil then
    fail("MON_CATALOG_INVALID", "species " .. key .. " has an unknown growth curve", context)
  end
  checkU8(species.baseFriendship, context, "MON_CATALOG_INVALID", "species " .. key .. " baseFriendship")
  checkU8(species.genderRatio, context, "MON_CATALOG_INVALID", "species " .. key .. " genderRatio")
  checkU8(species.eggCycles, context, "MON_CATALOG_INVALID", "species " .. key .. " eggCycles")
  checkU8(species.catchRate, context, "MON_CATALOG_INVALID", "species " .. key .. " catchRate")
  checkU8(species.baseExpYield, context, "MON_CATALOG_INVALID", "species " .. key .. " baseExpYield")
  if not Validate.isArray(species.eggGroups) or #species.eggGroups ~= 2 then
    fail("MON_CATALOG_INVALID", "species " .. key .. " must carry two egg groups", context)
  end
  checkEvYield(species.evYield, context, "MON_CATALOG_INVALID")
  if type(species.heldItems) ~= "table" then
    fail("MON_CATALOG_INVALID", "species " .. key .. " heldItems must be a record", context)
  end
  checkKeys(species.heldItems, { common = true, rare = true }, context, "MON_CATALOG_INVALID")
  checkItemIdentity(species.heldItems.common, context, "MON_CATALOG_INVALID", "species " .. key .. " heldItems.common")
  checkItemIdentity(species.heldItems.rare, context, "MON_CATALOG_INVALID", "species " .. key .. " heldItems.rare")
  if type(species.color) ~= "number" or species.color % 1 ~= 0 or species.color < 0 or species.color > 127 then
    fail("MON_CATALOG_INVALID", "species " .. key .. " color must be 0..127", context)
  end
  if type(species.flip) ~= "boolean" then
    fail("MON_CATALOG_INVALID", "species " .. key .. " flip must be a boolean", context)
  end
  if type(species.forms) ~= "table" or species.forms[0] == nil then
    fail("MON_CATALOG_INVALID", "species " .. key .. " must carry its base form", context)
  end
  for formId, form in pairs(species.forms) do
    if type(formId) ~= "number" or formId % 1 ~= 0 or formId < 0 then
      fail("MON_CATALOG_INVALID", "species " .. key .. " has an invalid form id", context)
    end
    MonAssetSchema.assertForm(form, { species = key, form = formId })
  end
end

local MOVE_FIELDS = {
  nativeId = true,
  name = true,
  description = true,
  effect = true,
  category = true,
  power = true,
  moveType = true,
  accuracy = true,
  basePp = true,
  effectChance = true,
  range = true,
  priority = true,
  flags = true,
  unknownC = true,
  contestType = true,
}

local function assertMove(key, move, context)
  if type(move) ~= "table" then
    fail("MON_CATALOG_INVALID", "move " .. key .. " must be a record", context)
  end
  checkKeys(move, MOVE_FIELDS, context, "MON_CATALOG_INVALID")
  if type(move.nativeId) ~= "number" or move.nativeId % 1 ~= 0 or move.nativeId < 0 or move.nativeId > 467 then
    fail("MON_CATALOG_INVALID", "move " .. key .. " nativeId must be 0..467", context)
  end
  checkNonEmptyString(move.name, context, "MON_CATALOG_INVALID", "move " .. key .. " name")
  if type(move.description) ~= "string" then
    fail("MON_CATALOG_INVALID", "move " .. key .. " description must be a string", context)
  end
  if type(move.effect) ~= "number" or move.effect % 1 ~= 0 or move.effect < 0 or move.effect > 65535 then
    fail("MON_CATALOG_INVALID", "move " .. key .. " effect must be a u16", context)
  end
  if CATEGORY_KEYS[move.category] == nil then
    fail("MON_CATALOG_INVALID", "move " .. key .. " has an unknown category", context)
  end
  checkU8(move.power, context, "MON_CATALOG_INVALID", "move " .. key .. " power")
  if TYPE_KEYS[move.moveType] == nil then
    fail("MON_CATALOG_INVALID", "move " .. key .. " has an unknown type", context)
  end
  if type(move.accuracy) ~= "number" or move.accuracy % 1 ~= 0 or move.accuracy < 0 or move.accuracy > 100 then
    fail("MON_CATALOG_INVALID", "move " .. key .. " accuracy must be 0..100", context)
  end
  if type(move.basePp) ~= "number" or move.basePp % 1 ~= 0 or move.basePp < 0 or move.basePp > 40 then
    fail("MON_CATALOG_INVALID", "move " .. key .. " basePp must be 0..40", context)
  end
  if
    type(move.effectChance) ~= "number"
    or move.effectChance % 1 ~= 0
    or move.effectChance < 0
    or move.effectChance > 100
  then
    fail("MON_CATALOG_INVALID", "move " .. key .. " effectChance must be 0..100", context)
  end
  if type(move.range) ~= "number" or move.range % 1 ~= 0 or move.range < 0 or move.range > 65535 then
    fail("MON_CATALOG_INVALID", "move " .. key .. " range must be a u16", context)
  end
  if type(move.priority) ~= "number" or move.priority % 1 ~= 0 or move.priority < -128 or move.priority > 127 then
    fail("MON_CATALOG_INVALID", "move " .. key .. " priority must be an i8", context)
  end
  checkU8(move.flags, context, "MON_CATALOG_INVALID", "move " .. key .. " flags")
  checkU8(move.unknownC, context, "MON_CATALOG_INVALID", "move " .. key .. " unknownC")
  checkU8(move.contestType, context, "MON_CATALOG_INVALID", "move " .. key .. " contestType")
end

local function collectKeys(section, context, code, what)
  if type(section) ~= "table" then
    fail(code, what .. " must be a record", context)
  end
  local keys = {}
  for key, record in pairs(section) do
    if type(key) ~= "string" or key == "" then
      fail(code, what .. " keys must be non-empty strings", context)
    end
    if type(record) ~= "table" then
      fail(code, what .. " " .. key .. " must be a record", context)
    end
    keys[key] = true
  end
  return keys
end

local function collectNativeIds(section, field, context, code, what)
  local ids = {}
  for key, record in pairs(section) do
    local id = record[field]
    if type(id) ~= "number" then
      fail(code, what .. " " .. key .. " is missing its native identity", context)
    end
    if ids[id] then
      fail(code, "duplicate " .. what .. " native identity " .. tostring(id), context)
    end
    ids[id] = key
  end
  return ids
end

-- The generated item collection: one record per source native identity
-- 0..536, each carrying only the runtime facts native projection and script
-- policy consume. Any missing, duplicate, extra, or out-of-range identity
-- fails the catalog; there is no partial item table.
local ITEM_FIELDS = { nativeId = true, isBall = true, friendshipBoost = true }

local function assertItems(items, context)
  if type(items) ~= "table" then
    fail("MON_CATALOG_INVALID", "items must be a record", context)
  end
  for key, record in pairs(items) do
    if type(key) ~= "string" or key == "" then
      fail("MON_CATALOG_INVALID", "item keys must be non-empty strings", context)
    end
    if type(record) ~= "table" then
      fail("MON_CATALOG_INVALID", "item " .. key .. " must be a record", context)
    end
    checkKeys(record, ITEM_FIELDS, context, "MON_CATALOG_INVALID")
    if
      type(record.nativeId) ~= "number"
      or record.nativeId % 1 ~= 0
      or record.nativeId < 0
      or record.nativeId > 536
    then
      fail("MON_CATALOG_INVALID", "item " .. key .. " nativeId must be 0..536", context)
    end
    if type(record.isBall) ~= "boolean" then
      fail("MON_CATALOG_INVALID", "item " .. key .. " isBall must be a boolean", context)
    end
    if type(record.friendshipBoost) ~= "boolean" then
      fail("MON_CATALOG_INVALID", "item " .. key .. " friendshipBoost must be a boolean", context)
    end
  end
  local byNativeId = collectNativeIds(items, "nativeId", context, "MON_CATALOG_INVALID", "item")
  for nativeId = 0, 536 do
    if byNativeId[nativeId] == nil then
      fail("MON_CATALOG_INVALID", "item native identity " .. nativeId .. " is missing", context)
    end
  end
end

-- Full catalog validation: shapes plus every species/move/ability cross
-- reference. Growth curves cover levels 1..100 exactly. The item collection
-- covers every source native identity 0..536 exactly once with only the
-- runtime facts each record carries.
function MonAssetSchema.assertCatalog(catalog)
  local context = {}
  if type(catalog) ~= "table" then
    fail("MON_CATALOG_INVALID", "catalog must be a record", context)
  end
  checkKeys(catalog, {
    schema = true,
    version = true,
    species = true,
    moves = true,
    abilities = true,
    growthCurves = true,
    items = true,
  }, context, "MON_CATALOG_INVALID")
  if catalog.schema ~= "g4-mon-catalog-v2" then
    fail("MON_CATALOG_INVALID", "catalog schema must be g4-mon-catalog-v2", context)
  end
  if type(catalog.version) ~= "table" then
    fail("MON_CATALOG_INVALID", "catalog version must be a record", context)
  end
  checkKeys(catalog.version, { id = true, language = true }, context, "MON_CATALOG_INVALID")
  checkNonEmptyString(catalog.version.id, context, "MON_CATALOG_INVALID", "catalog version id")
  checkNonEmptyString(catalog.version.language, context, "MON_CATALOG_INVALID", "catalog version language")
  local speciesKeys = collectKeys(catalog.species, context, "MON_CATALOG_INVALID", "species")
  local moveKeys = collectKeys(catalog.moves, context, "MON_CATALOG_INVALID", "moves")
  local abilityKeys = collectKeys(catalog.abilities, context, "MON_CATALOG_INVALID", "abilities")
  collectNativeIds(catalog.species, "nativeId", context, "MON_CATALOG_INVALID", "species")
  collectNativeIds(catalog.moves, "nativeId", context, "MON_CATALOG_INVALID", "moves")
  collectNativeIds(catalog.abilities, "nativeId", context, "MON_CATALOG_INVALID", "abilities")
  assertItems(catalog.items, context)
  for key, species in pairs(catalog.species) do
    assertSpecies(key, species, context)
    for _, form in pairs(species.forms) do
      for _, abilityKey in ipairs(form.abilities) do
        if abilityKeys[abilityKey] == nil then
          fail("MON_CATALOG_INVALID", "species " .. key .. " references unknown ability " .. abilityKey, context)
        end
      end
      for _, moveKey in ipairs(form.tmhm) do
        if moveKeys[moveKey] == nil then
          fail("MON_CATALOG_INVALID", "species " .. key .. " references unknown tmhm move " .. moveKey, context)
        end
      end
      for _, entry in ipairs(form.levelUpMoves) do
        if moveKeys[entry.move] == nil then
          fail("MON_CATALOG_INVALID", "species " .. key .. " references unknown learnset move " .. entry.move, context)
        end
      end
      for _, entry in ipairs(form.evolutions) do
        if speciesKeys[entry.target] == nil then
          fail("MON_CATALOG_INVALID", "species " .. key .. " evolves into unknown species " .. entry.target, context)
        end
        if entry.move ~= nil and moveKeys[entry.move] == nil then
          fail("MON_CATALOG_INVALID", "species " .. key .. " references unknown evolution move " .. entry.move, context)
        end
        if entry.species ~= nil and speciesKeys[entry.species] == nil then
          fail(
            "MON_CATALOG_INVALID",
            "species " .. key .. " references unknown evolution species " .. entry.species,
            context
          )
        end
      end
    end
  end
  for key, move in pairs(catalog.moves) do
    assertMove(key, move, context)
  end
  if type(catalog.abilities) ~= "table" then
    fail("MON_CATALOG_INVALID", "abilities must be a record", context)
  end
  for key, ability in pairs(catalog.abilities) do
    if type(ability) ~= "table" then
      fail("MON_CATALOG_INVALID", "ability " .. key .. " must be a record", context)
    end
    checkKeys(ability, { nativeId = true, name = true, description = true }, context, "MON_CATALOG_INVALID")
    if
      type(ability.nativeId) ~= "number"
      or ability.nativeId % 1 ~= 0
      or ability.nativeId < 0
      or ability.nativeId > 123
    then
      fail("MON_CATALOG_INVALID", "ability " .. key .. " nativeId must be 0..123", context)
    end
    checkNonEmptyString(ability.name, context, "MON_CATALOG_INVALID", "ability " .. key .. " name")
    if type(ability.description) ~= "string" then
      fail("MON_CATALOG_INVALID", "ability " .. key .. " description must be a string", context)
    end
  end
  if type(catalog.growthCurves) ~= "table" then
    fail("MON_CATALOG_INVALID", "growthCurves must be a record", context)
  end
  for key in pairs(catalog.growthCurves) do
    if GROWTH_KEYS[key] == nil then
      fail("MON_CATALOG_INVALID", "unknown growth curve " .. tostring(key), context)
    end
  end
  for key in pairs(GROWTH_KEYS) do
    local curve = catalog.growthCurves[key]
    if not Validate.isArray(curve) or #curve ~= 100 then
      fail("MON_CATALOG_INVALID", "growth curve " .. key .. " must carry levels 1..100", context)
    end
    if curve[1] ~= 0 then
      fail("MON_CATALOG_INVALID", "growth curve " .. key .. " level 1 must be zero", context)
    end
    for level = 1, 100 do
      local value = curve[level]
      if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > 4294967295 then
        fail("MON_CATALOG_INVALID", "growth curve " .. key .. " level " .. level .. " must be a u32", context)
      end
      if level > 1 and value < curve[level - 1] then
        fail("MON_CATALOG_INVALID", "growth curve " .. key .. " must be non-decreasing", context)
      end
    end
  end
  return true
end

function MonAssetSchema.isValidCatalog(catalog)
  return pcall(MonAssetSchema.assertCatalog, catalog)
end

local function checkHash(value, context, code, field)
  if type(value) ~= "string" or #value ~= 40 or value:match("^[0-9a-f]+$") == nil then
    fail(code, field .. " must be a 40-character hex digest", context)
  end
end

-- Class index validation: schema identity, version, content hashes, and
-- cache-relative paths.
function MonAssetSchema.assertIndex(index)
  local context = {}
  if type(index) ~= "table" then
    fail("MON_INDEX_INVALID", "index must be a record", context)
  end
  checkKeys(index, {
    schema = true,
    version = true,
    catalogHash = true,
    iconHash = true,
    portraitHash = true,
    catalog = true,
    icons = true,
    iconManifest = true,
    portraits = true,
    portraitManifest = true,
  }, context, "MON_INDEX_INVALID")
  if index.schema ~= "g4-mon-index-v1" then
    fail("MON_INDEX_INVALID", "index schema must be g4-mon-index-v1", context)
  end
  if type(index.version) ~= "table" then
    fail("MON_INDEX_INVALID", "index version must be a record", context)
  end
  checkKeys(index.version, { id = true, language = true }, context, "MON_INDEX_INVALID")
  checkNonEmptyString(index.version.id, context, "MON_INDEX_INVALID", "index version id")
  checkNonEmptyString(index.version.language, context, "MON_INDEX_INVALID", "index version language")
  checkHash(index.catalogHash, context, "MON_INDEX_INVALID", "catalogHash")
  checkHash(index.iconHash, context, "MON_INDEX_INVALID", "iconHash")
  checkHash(index.portraitHash, context, "MON_INDEX_INVALID", "portraitHash")
  checkNonEmptyString(index.catalog, context, "MON_INDEX_INVALID", "catalog path")
  checkNonEmptyString(index.icons, context, "MON_INDEX_INVALID", "icons path")
  checkNonEmptyString(index.iconManifest, context, "MON_INDEX_INVALID", "iconManifest path")
  checkNonEmptyString(index.portraits, context, "MON_INDEX_INVALID", "portraits path")
  checkNonEmptyString(index.portraitManifest, context, "MON_INDEX_INVALID", "portraitManifest path")
  return true
end

function MonAssetSchema.isValidIndex(index)
  return pcall(MonAssetSchema.assertIndex, index)
end

local function checkManifestRect(rect, context, code, field)
  if type(rect) ~= "table" then
    fail(code, field .. " must be a record", context)
  end
  for _, axis in ipairs({ "x", "y", "width", "height" }) do
    if type(rect[axis]) ~= "number" or rect[axis] % 1 ~= 0 or rect[axis] < 0 then
      fail(code, field .. "." .. axis .. " must be a non-negative integer", context)
    end
  end
  if rect.width == 0 or rect.height == 0 then
    fail(code, field .. " must have positive dimensions", context)
  end
end

-- Presentation manifest validation: every entry addresses atlas rectangles
-- with animation frames, and every representative selector resolves.
function MonAssetSchema.assertManifest(manifest, expectedSchema)
  local context = {}
  if type(manifest) ~= "table" then
    fail("MON_MANIFEST_INVALID", "manifest must be a record", context)
  end
  checkKeys(
    manifest,
    { schema = true, image = true, entries = true, representative = true },
    context,
    "MON_MANIFEST_INVALID"
  )
  if manifest.schema ~= expectedSchema then
    fail("MON_MANIFEST_INVALID", "manifest schema must be " .. expectedSchema, context)
  end
  checkNonEmptyString(manifest.image, context, "MON_MANIFEST_INVALID", "manifest image")
  if type(manifest.entries) ~= "table" then
    fail("MON_MANIFEST_INVALID", "manifest entries must be a record", context)
  end
  local entryCount = 0
  for selector, entry in pairs(manifest.entries) do
    entryCount = entryCount + 1
    if type(selector) ~= "string" or selector == "" then
      fail("MON_MANIFEST_INVALID", "manifest selectors must be non-empty strings", context)
    end
    if type(entry) ~= "table" then
      fail("MON_MANIFEST_INVALID", "manifest entry " .. selector .. " must be a record", context)
    end
    checkKeys(
      entry,
      { x = true, y = true, width = true, height = true, frames = true },
      context,
      "MON_MANIFEST_INVALID"
    )
    checkManifestRect(entry, context, "MON_MANIFEST_INVALID", "manifest entry " .. selector)
    if not Validate.isArray(entry.frames) or #entry.frames == 0 then
      fail("MON_MANIFEST_INVALID", "manifest entry " .. selector .. " must carry frames", context)
    end
    for frameIndex, frame in ipairs(entry.frames) do
      if type(frame) ~= "table" then
        fail(
          "MON_MANIFEST_INVALID",
          "manifest entry " .. selector .. " frame " .. frameIndex .. " must be a record",
          context
        )
      end
      checkKeys(
        frame,
        { x = true, y = true, width = true, height = true, duration = true },
        context,
        "MON_MANIFEST_INVALID"
      )
      checkManifestRect(
        frame,
        context,
        "MON_MANIFEST_INVALID",
        "manifest entry " .. selector .. " frame " .. frameIndex
      )
      if frame.duration ~= nil then
        if type(frame.duration) ~= "number" or frame.duration % 1 ~= 0 or frame.duration <= 0 then
          fail("MON_MANIFEST_INVALID", "manifest entry " .. selector .. " frame duration must be positive", context)
        end
      end
    end
    local first = entry.frames[1]
    if entry.x ~= first.x or entry.y ~= first.y or entry.width ~= first.width or entry.height ~= first.height then
      fail("MON_MANIFEST_INVALID", "manifest entry " .. selector .. " must match its first frame", context)
    end
  end
  if entryCount == 0 then
    fail("MON_MANIFEST_INVALID", "manifest must carry entries", context)
  end
  if not Validate.isArray(manifest.representative) or #manifest.representative == 0 then
    fail("MON_MANIFEST_INVALID", "manifest must carry representative selectors", context)
  end
  for _, selector in ipairs(manifest.representative) do
    if manifest.entries[selector] == nil then
      fail("MON_MANIFEST_INVALID", "representative selector has no entry: " .. tostring(selector), context)
    end
  end
  return true
end

function MonAssetSchema.assertIconManifest(manifest)
  return MonAssetSchema.assertManifest(manifest, "g4-mon-icon-manifest-v1")
end

function MonAssetSchema.assertPortraitManifest(manifest)
  return MonAssetSchema.assertManifest(manifest, "g4-mon-portrait-manifest-v1")
end

function MonAssetSchema.isValidIconManifest(manifest)
  return pcall(MonAssetSchema.assertIconManifest, manifest)
end

function MonAssetSchema.isValidPortraitManifest(manifest)
  return pcall(MonAssetSchema.assertPortraitManifest, manifest)
end

return MonAssetSchema
