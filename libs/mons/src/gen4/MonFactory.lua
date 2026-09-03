-- Source-faithful mon creation. Canonical sources: pret/pokeheartgold,
-- src/pokemon.c (CreateBoxMon, CreateMon), src/choose_starter.c
-- (CreateStarter), src/script_pokemon_util.c (GiveMon), and
-- src/trainer_memo.c (trainer memo assignment). Creation consumes exactly
-- four generator draws in source order: two for the personality value (low
-- draw first) and two for the six individual values. The factory never
-- inserts into a party; the caller owns publication. Every method returns a
-- validated, native-projectable record or fails.

local Experience = require("libs.mons.src.gen4.Experience")
local Mon = require("libs.mons.src.Mon")
local MonsErrors = require("libs.mons.src.errors")
local Moves = require("libs.mons.src.gen4.Moves")
local NativeLegality = require("libs.mons.src.gen4.NativeLegality")
local Personality = require("libs.mons.src.gen4.Personality")
local Stats = require("libs.mons.src.gen4.Stats")

---@class MonFactory
---@field private _catalog table
---@field private _rng table
---@field private _charmap table
---@field private _games table<string, integer>
---@field private _languages table<string, integer>
---@field private _items table<string, integer>
---@field private _balls table<string, integer>
---@field private _game string
---@field private _language string
local MonFactory = {}
MonFactory.__index = MonFactory

---@param args table
---@return MonFactory
function MonFactory.new(args)
  assert(type(args) == "table", "factory requires an argument record")
  assert(args.catalog ~= nil, "factory requires a catalog")
  assert(args.rng ~= nil, "factory requires an exact generator")
  assert(type(args.charmap) == "table", "factory requires a charmap")
  assert(type(args.games) == "table", "factory requires a game table")
  assert(type(args.languages) == "table", "factory requires a language table")
  assert(type(args.items) == "table", "factory requires an item table")
  assert(type(args.balls) == "table", "factory requires a ball table")
  assert(type(args.game) == "string" and args.games[args.game] ~= nil, "factory game must resolve")
  assert(type(args.language) == "string" and args.languages[args.language] ~= nil, "factory language must resolve")
  return setmetatable({
    _catalog = args.catalog,
    _rng = args.rng,
    _charmap = args.charmap,
    _games = args.games,
    _languages = args.languages,
    _items = args.items,
    _balls = args.balls,
    _game = args.game,
    _language = args.language,
  }, MonFactory)
end

---@return table
function MonFactory:_context()
  return {
    catalog = self._catalog,
    charmap = self._charmap,
    games = self._games,
    languages = self._languages,
    items = self._items,
    balls = self._balls,
  }
end

---@param draw integer
---@return table<string, integer>
local function splitIvDraw(draw)
  return {
    low = draw % 32,
    mid = math.floor(draw / 32) % 32,
    high = math.floor(draw / 1024) % 32,
  }
end

---@param record table
---@return table
function MonFactory:_finish(record)
  local canonical = Mon.validate(record, self:_context())
  NativeLegality.project(canonical, self:_context())
  return canonical
end

---@param request table
---@return table
function MonFactory:createNormal(request)
  assert(type(request) == "table", "normal creation requires a request record")
  local species = self._catalog:species(request.species)
  local form = self._catalog:form(request.species, request.form)
  if type(request.level) ~= "number" or request.level % 1 ~= 0 or request.level < 1 or request.level > 100 then
    MonsErrors.raise(
      MonsErrors.RECORD_INVALID,
      "normal creation level must be an integer in 1..100",
      { policy = "normal", species = request.species }
    )
  end
  local profile = request.profile
  assert(type(profile) == "table", "normal creation requires an owner profile")
  if self._balls[request.ball] == nil then
    MonsErrors.raise(
      MonsErrors.RECORD_INVALID,
      "normal creation ball must resolve",
      { policy = "normal", species = request.species }
    )
  end

  local personality = self._rng:nextU32FromTwoDraws()
  local first = splitIvDraw(self._rng:nextU16())
  local second = splitIvDraw(self._rng:nextU16())
  local ivs = {
    hp = first.low,
    attack = first.mid,
    defense = first.high,
    speed = second.low,
    specialAttack = second.mid,
    specialDefense = second.high,
  }

  local slot = Personality.abilitySlot(#form.abilities, personality)
  local ability = form.abilities[slot]
  local curve = self._catalog:growthCurve(species.growthCurve)
  local experience = Experience.expFor(curve, request.level)
  local nature = Personality.nature(personality)
  local evs = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 }
  local derived = Stats.calculate(form.baseStats, ivs, evs, request.level, nature)
  local maxHp = derived.hp
  if request.species == "SHEDINJA" then
    maxHp = 1
  end

  local record = {
    schema = "g4-mon-v1",
    species = request.species,
    form = request.form,
    personality = personality,
    experience = experience,
    friendship = species.baseFriendship,
    ability = ability,
    heldItem = "NONE",
    markings = 0,
    evs = evs,
    contest = { cool = 0, beauty = 0, cute = 0, smart = 0, tough = 0, sheen = 0 },
    moves = Moves.initial(form.levelUpMoves, request.level, self._catalog),
    ivs = ivs,
    isEgg = false,
    nickname = nil,
    ribbons = { ds1 = 0, gba = 0, ds2 = 0 },
    fatefulEncounter = false,
    shinyLeaves = 0,
    egg = { location = 0 },
    met = {
      location = request.location,
      date = {
        year = request.date.year,
        month = request.date.month,
        day = request.date.day,
      },
      level = request.level,
      terrain = request.terrain,
    },
    origin = {
      trainerId = profile.trainerId,
      trainerName = profile.name,
      trainerGender = profile.gender,
      game = self._game,
      ball = request.ball,
      language = self._language,
    },
    pokerus = 0,
    mood = 0,
    condition = { status = 0, currentHp = maxHp },
    capsule = { id = 0, seals = {} },
    mail = {},
  }
  return self:_finish(record)
end

---@param request table
---@return table
function MonFactory:createStarter(request)
  assert(type(request) == "table", "starter creation requires a request record")
  return self:createNormal({
    species = request.species,
    level = 5,
    form = 0,
    profile = request.profile,
    ball = "POKE_BALL",
    location = request.location,
    terrain = 12,
    date = request.date,
  })
end

---@param request table
---@return table
function MonFactory:createScriptGift(request)
  assert(type(request) == "table", "script-gift creation requires a request record")
  local mon = self:createNormal({
    species = request.species,
    level = request.level,
    form = 0,
    profile = request.profile,
    ball = "POKE_BALL",
    location = request.location,
    terrain = 24,
    date = request.date,
  })
  mon.heldItem = request.heldItem or "NONE"
  mon.form = request.form or 0
  if request.ability ~= nil then
    mon.ability = request.ability
  end
  local context = self:_context()
  NativeLegality.project(mon, context)
  return self:_finish(mon)
end

return MonFactory
