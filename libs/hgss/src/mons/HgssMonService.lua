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

-- Generated catalog type keys project to the native Gen-IV identities only
-- when a script result crosses the HGSS adapter boundary.
local NATIVE_TYPE_IDS = {
  normal = 0,
  fighting = 1,
  flying = 2,
  poison = 3,
  ground = 4,
  rock = 5,
  bug = 6,
  ghost = 7,
  steel = 8,
  mystery = 9,
  fire = 10,
  water = 11,
  grass = 12,
  electric = 13,
  psychic = 14,
  ice = 15,
  dragon = 16,
  dark = 17,
}

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
---@field games table<string, integer>?
---@field languages table<string, integer>?
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
  assert(type(games) == "table" and games[opts.game] ~= nil, "mon service game must resolve")
  assert(type(languages) == "table" and languages[opts.language] ~= nil, "mon service language must resolve")
  -- Item and ball identities resolve through the generated catalog alone;
  -- no runtime numbering table is built or consulted.
  local context = {
    catalog = opts.catalog,
    charmap = opts.charmap,
    games = games,
    languages = languages,
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

---@param value string|integer|nil
---@return string
function HgssMonService:_itemKey(value)
  if value == nil then
    return "NONE"
  end
  if type(value) == "string" then
    self._catalog:item(value)
    return value
  end
  if type(value) == "number" and value % 1 == 0 then
    return self._catalog:itemKeyByNativeId(value)
  end
  MonsErrors.raise(MonsErrors.RECORD_INVALID, "held item identity must be a key or native id", {})
  error("unreachable", 0)
end

---@return integer|nil
function HgssMonService:_currentMapSection()
  local section = self._mapSection
  if type(section) == "function" then
    return section()
  elseif type(section) == "number" then
    return section
  end
  return nil
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
  local value = self:_currentMapSection()
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

---@param slot0 integer
---@return integer, integer
function HgssMonService:monTypes(slot0)
  local mon = self:_liveMon(slot0)
  local form = self._catalog:form(mon.species, mon.form)
  local type1 = NATIVE_TYPE_IDS[form.types[1]]
  local type2 = NATIVE_TYPE_IDS[form.types[2] or form.types[1]]
  assert(type1 ~= nil and type2 ~= nil, "catalog form carries known native type keys")
  return type1, type2
end

---@param slot0 integer
---@return integer
function HgssMonService:scriptMonLevel(slot0)
  local mon = self:_liveMon(slot0)
  if mon.isEgg then
    return 0
  end
  return self:_level(mon)
end

---@param slot0 integer
---@param form integer
function HgssMonService:setMonForm(slot0, form)
  local mon = self:_liveMon(slot0)
  self._catalog:form(mon.species, form)
  mon.form = form
  self:_store(slot0, mon)
end

---@param item string|integer
---@return boolean
function HgssMonService:partyHasHeldItem(item)
  local key = self:_itemKey(item)
  for index = 0, self._party:count() - 1 do
    local mon = self._party:get(index)
    if mon.heldItem == key then
      return true
    end
  end
  return false
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

-- Source-shaped script operations. Each mirrors one reviewed HGSS party
-- script command's observable behavior (pret/pokeheartgold
-- src/scrcmd_party.c): egg masking, exact result sentinels, inverted
-- ownership polarity, duplicate-species mode, ribbon-kind aggregation, the
-- friendship bonus order, and contest no-op cases. Numeric results are the
-- exact values the script variable carries; party records never store
-- sentinels. The clean query/mutation methods above stay for non-script
-- callers and keep their conventional contracts.
---@param slot0 integer
---@param move string|integer
---@return boolean
function HgssMonService:scriptMonHasMove(slot0, move)
  local key = self:_moveKey(move)
  local mon = self:_liveMon(slot0)
  if mon.isEgg then
    return false
  end
  for _, entry in ipairs(mon.moves) do
    if entry.move == key then
      return true
    end
  end
  return false
end

---@param move string|integer
---@return integer
function HgssMonService:scriptSlotWithMove(move)
  local key = self:_moveKey(move)
  for index = 0, self._party:count() - 1 do
    local mon = self._party:get(index)
    if not mon.isEgg then
      for _, entry in ipairs(mon.moves) do
        if entry.move == key then
          return index
        end
      end
    end
  end
  return 6
end

---@param slot0 integer
---@return integer
function HgssMonService:scriptPartyMonSpecies(slot0)
  local mon = self:_liveMon(slot0)
  if mon.isEgg then
    return 0
  end
  return self._catalog:species(mon.species).nativeId
end

-- Ownership compares only the numeric trainer identity with source u16
-- width: equal identities report FALSE (0) and differing identities
-- report TRUE (1).
---@param slot0 integer
---@return integer
function HgssMonService:scriptPartyMonOwnershipResult(slot0)
  if type(slot0) ~= "number" or slot0 % 1 ~= 0 or slot0 < 0 or slot0 >= self._party:count() then
    return 0
  end
  if self._party:get(slot0).origin.trainerId % 65536 == self._profile.trainerId % 65536 then
    return 0
  end
  return 1
end

---@param level integer
---@return integer
function HgssMonService:scriptCountAtOrBelowLevel(level)
  if type(level) ~= "number" or level % 1 ~= 0 or level < 1 or level > 100 then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "level bound must be an integer in 1..100", {})
  end
  local count = 0
  for index = 0, self._party:count() - 1 do
    local mon = self._party:get(index)
    if not mon.isEgg and self:_level(mon) <= level then
      count = count + 1
    end
  end
  return count
end

-- Out-of-range slots and eggs read nature zero instead of faulting.
---@param slot0 integer
---@return integer
function HgssMonService:scriptMonNature(slot0)
  if type(slot0) ~= "number" or slot0 % 1 ~= 0 or slot0 < 0 or slot0 >= self._party:count() then
    return 0
  end
  local mon = self._party:get(slot0)
  if mon.isEgg then
    return 0
  end
  return Personality.nature(mon.personality)
end

---@param nature integer
---@return integer
function HgssMonService:scriptSlotWithNature(nature)
  if type(nature) ~= "number" or nature % 1 ~= 0 or nature < 0 or nature > 24 then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "nature must be an integer in 0..24", {})
  end
  for index = 0, self._party:count() - 1 do
    local mon = self._party:get(index)
    if not mon.isEgg and Personality.nature(mon.personality) == nature then
      return index
    end
  end
  return 255
end

-- A zero species operand is duplicate detection among non-eggs: 1 as soon
-- as any two share a species, else 0. Any other operand counts exact
-- non-egg matches. Eggs never contribute on either path.
---@param species string|integer
---@return integer
function HgssMonService:scriptCountSpecies(species)
  if type(species) == "number" and species == 0 then
    local seen = {}
    for index = 0, self._party:count() - 1 do
      local mon = self._party:get(index)
      if not mon.isEgg then
        if seen[mon.species] then
          return 1
        end
        seen[mon.species] = true
      end
    end
    return 0
  end
  local key = self:_speciesKey(species)
  local count = 0
  for index = 0, self._party:count() - 1 do
    local mon = self._party:get(index)
    if not mon.isEgg and mon.species == key then
      count = count + 1
    end
  end
  return count
end

---@param species string|integer
---@return integer
function HgssMonService:scriptSlotWithSpecies(species)
  if type(species) == "number" and species == 0 then
    -- No non-egg party mon carries species zero, so the source scan simply
    -- misses instead of faulting.
    return 255
  end
  local key = self:_speciesKey(species)
  for index = 0, self._party:count() - 1 do
    local mon = self._party:get(index)
    if not mon.isEgg and mon.species == key then
      return index
    end
  end
  return 255
end

---@param field string
---@param bit integer
---@return boolean
function HgssMonService:_anyNonEggRibbonBit(field, bit)
  local place = 2 ^ bit
  for index = 0, self._party:count() - 1 do
    local mon = self._party:get(index)
    if not mon.isEgg and math.floor(mon.ribbons[field] / place) % 2 == 1 then
      return true
    end
  end
  return false
end

-- Ribbon-kind aggregation: every source ribbon kind is one bit in the three
-- boxed ribbon fields, except the two spare bits no kind ever sets (the ds1
-- spare at bit 28 and the ds2 spare at bit 20). Each represented kind counts
-- once no matter how many mons own it, and eggs never contribute.
---@return integer
function HgssMonService:scriptPartyRibbonCount()
  local count = 0
  for bit = 0, 27 do
    if self:_anyNonEggRibbonBit("ds1", bit) then
      count = count + 1
    end
  end
  for bit = 0, 31 do
    if self:_anyNonEggRibbonBit("gba", bit) then
      count = count + 1
    end
  end
  for bit = 0, 19 do
    if self:_anyNonEggRibbonBit("ds2", bit) then
      count = count + 1
    end
  end
  return count
end

-- The narrow checksum-failed-egg query, not broad native legality.
-- Semantic records cannot carry checksum failure and the boxed codec
-- rejects corrupt bytes, so every representable party reports FALSE (0).
---@return integer
function HgssMonService:scriptPartyLegalResult()
  return 0
end

-- Friendship mutation in source order: a zero modifier bypasses every
-- bonus; otherwise the Luxury Ball and current-native-section increments
-- apply first, the friendship-boost held item scales the running total by
-- 150 percent with integer division, and the final value saturates at 255.
-- The section comparison reads the native map-section identity against the
-- mon's egg location, and the item fact comes from the generated catalog.
---@param slot0 integer
---@param amount integer
---@return integer
function HgssMonService:scriptAddFriendship(slot0, amount)
  if type(amount) ~= "number" or amount % 1 ~= 0 or amount < 0 or amount > 65535 then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "friendship modifier must be an integer in 0..65535", {})
  end
  local mon = self:_liveMon(slot0)
  local modifier = amount
  if modifier ~= 0 then
    if mon.origin.ball == "LUXURY_BALL" then
      modifier = modifier + 1
    end
    if self:_currentMapSection() == mon.egg.location then
      modifier = modifier + 1
    end
    if self._catalog:item(mon.heldItem).friendshipBoost then
      modifier = math.floor(modifier * 150 / 100)
    end
  end
  mon.friendship = math.min(255, mon.friendship + modifier)
  self:_store(slot0, mon)
  return mon.friendship
end

-- Contest mutation: a selector at or above six is a silent no-op, a maxed
-- sheen blocks the update entirely, and any other selector adds the
-- modifier to its contest value with saturation at 255. Large source-valid
-- modifiers saturate instead of failing.
---@param slot0 integer
---@param selector integer
---@param amount integer
---@return integer
function HgssMonService:scriptAddContestValue(slot0, selector, amount)
  if type(amount) ~= "number" or amount % 1 ~= 0 or amount < 0 or amount > 65535 then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "contest modifier must be an integer in 0..65535", {})
  end
  if type(selector) ~= "number" or selector % 1 ~= 0 or selector < 0 then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "contest selector must be a non-negative integer", {})
  end
  local mon = self:_liveMon(slot0)
  if selector >= 6 then
    return mon.contest.sheen
  end
  local key = CONTEST_KEYS[selector + 1]
  if mon.contest.sheen == 255 then
    return mon.contest[key]
  end
  mon.contest[key] = math.min(255, mon.contest[key] + amount)
  self:_store(slot0, mon)
  return mon.contest[key]
end

return HgssMonService
