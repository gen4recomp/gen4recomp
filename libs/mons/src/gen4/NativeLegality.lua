-- Strict native representability for supported production policies. The
-- projection resolves every semantic identity to its native Generation-IV
-- value and verifies the cross-field relationships the boxed codec depends
-- on: the ability belongs to the final form, the met level tracks the
-- experience-derived level, power points respect the source maximum, effort
-- totals fit, current health fits the derived maximum, and strings fit
-- their fixed capacities. Unknown identities are record failures; known
-- but inconsistent combinations are legality failures. The boxed codec
-- requires this projection and carries no separate permissive checks.

local Experience = require("libs.mons.src.gen4.Experience")
local MonsErrors = require("libs.mons.src.errors")
local Personality = require("libs.mons.src.gen4.Personality")
local Stats = require("libs.mons.src.gen4.Stats")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

---@class NativeLegality
local NativeLegality = {}

NativeLegality.NICKNAME_CAPACITY = 11
NativeLegality.OT_NAME_CAPACITY = 8

---@param text string
---@param charmap table
---@param capacity integer
---@param what string
local function checkShapedText(text, charmap, capacity, what)
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
end

---@param mon table
---@param context table
---@return table
function NativeLegality.project(mon, context)
  assert(type(mon) == "table", "legality projection requires a mon record")
  assert(type(context) == "table", "legality projection requires a context")
  assert(context.catalog ~= nil, "legality projection requires a catalog")
  local catalog = context.catalog

  local species = catalog:species(mon.species)
  local form = catalog:form(mon.species, mon.form)
  if mon.form < 0 or mon.form > 31 then
    MonsErrors.raise(MonsErrors.LEGALITY_INVALID, "form exceeds its native field", { form = mon.form })
  end

  local abilityDefinition = catalog:ability(mon.ability)
  if context.items == nil or context.items[mon.heldItem] == nil then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "unknown held item " .. tostring(mon.heldItem), {})
  end
  if context.games == nil or context.games[mon.origin.game] == nil then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "unknown game " .. tostring(mon.origin.game), {})
  end
  if context.balls == nil or context.balls[mon.origin.ball] == nil then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "unknown ball " .. tostring(mon.origin.ball), {})
  end
  if context.languages == nil or context.languages[mon.origin.language] == nil then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "unknown language " .. tostring(mon.origin.language), {})
  end

  local permitted = false
  for _, key in ipairs(form.abilities) do
    if key == mon.ability then
      permitted = true
    end
  end
  if not permitted then
    MonsErrors.raise(
      MonsErrors.LEGALITY_INVALID,
      "ability " .. tostring(mon.ability) .. " is not permitted by the final form",
      { ability = mon.ability, species = mon.species, form = mon.form }
    )
  end

  local curve = catalog:growthCurve(species.growthCurve)
  if mon.experience > curve[100] then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "experience exceeds the level-100 entry", {})
  end
  local level = Experience.level(curve, mon.experience)
  if mon.met.level ~= level then
    MonsErrors.raise(
      MonsErrors.LEGALITY_INVALID,
      "met level must track the experience-derived level",
      { metLevel = mon.met.level, level = level }
    )
  end

  local moves = {}
  local seen = {}
  for index, entry in ipairs(mon.moves) do
    local definition = catalog:move(entry.move)
    if seen[entry.move] then
      MonsErrors.raise(MonsErrors.LEGALITY_INVALID, "duplicate move " .. entry.move, { move = entry.move })
    end
    seen[entry.move] = true
    local ceiling = definition.basePp + 3 * math.floor(definition.basePp / 5)
    if entry.pp < 0 or entry.pp > ceiling or entry.ppUps < 0 or entry.ppUps > 3 then
      MonsErrors.raise(
        MonsErrors.LEGALITY_INVALID,
        "move entry " .. index .. " exceeds its source power-point range",
        {}
      )
    end
    moves[#moves + 1] = { id = definition.nativeId, pp = entry.pp, ppUps = entry.ppUps }
  end

  local evTotal = 0
  for _, key in ipairs({ "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }) do
    evTotal = evTotal + mon.evs[key]
  end
  if evTotal > 510 then
    MonsErrors.raise(MonsErrors.LEGALITY_INVALID, "effort value total exceeds 510", {})
  end

  local nature = Personality.nature(mon.personality)
  local derived = Stats.calculate(form.baseStats, mon.ivs, mon.evs, level, nature)
  local maxHp = derived.hp
  if mon.species == "SHEDINJA" then
    maxHp = 1
  end
  if mon.condition ~= nil then
    if mon.condition.currentHp < 0 or mon.condition.currentHp > maxHp then
      MonsErrors.raise(MonsErrors.LEGALITY_INVALID, "current health exceeds the derived maximum", {})
    end
  end

  local gender = Personality.gender(species.genderRatio, mon.personality)
  local genderCode = 0
  if gender == "male" then
    genderCode = 1
  elseif gender == "female" then
    genderCode = 2
  end

  local nicknameText = mon.nickname
  if nicknameText == nil then
    nicknameText = species.name
  end
  checkShapedText(nicknameText, context.charmap, NativeLegality.NICKNAME_CAPACITY, "nickname")
  checkShapedText(mon.origin.trainerName, context.charmap, NativeLegality.OT_NAME_CAPACITY, "trainer name")

  return {
    personality = mon.personality,
    speciesId = species.nativeId,
    heldItemId = context.items[mon.heldItem],
    trainerId = mon.origin.trainerId,
    experience = mon.experience,
    friendship = mon.friendship,
    abilityId = abilityDefinition.nativeId,
    markings = mon.markings,
    languageId = context.languages[mon.origin.language],
    evs = {
      hp = mon.evs.hp,
      attack = mon.evs.attack,
      defense = mon.evs.defense,
      speed = mon.evs.speed,
      specialAttack = mon.evs.specialAttack,
      specialDefense = mon.evs.specialDefense,
    },
    contest = {
      cool = mon.contest.cool,
      beauty = mon.contest.beauty,
      cute = mon.contest.cute,
      smart = mon.contest.smart,
      tough = mon.contest.tough,
      sheen = mon.contest.sheen,
    },
    ribbonsDs1 = mon.ribbons.ds1,
    moves = moves,
    ivs = {
      hp = mon.ivs.hp,
      attack = mon.ivs.attack,
      defense = mon.ivs.defense,
      speed = mon.ivs.speed,
      specialAttack = mon.ivs.specialAttack,
      specialDefense = mon.ivs.specialDefense,
    },
    isEgg = mon.isEgg,
    hasNickname = mon.nickname ~= nil,
    ribbonsGba = mon.ribbons.gba,
    fateful = mon.fatefulEncounter,
    genderCode = genderCode,
    form = mon.form,
    leaves = mon.shinyLeaves,
    nicknameText = nicknameText,
    gameId = context.games[mon.origin.game],
    ribbonsDs2 = mon.ribbons.ds2,
    otText = mon.origin.trainerName,
    eggYear = mon.egg.date ~= nil and mon.egg.date.year or 0,
    eggMonth = mon.egg.date ~= nil and mon.egg.date.month or 0,
    eggDay = mon.egg.date ~= nil and mon.egg.date.day or 0,
    metYear = mon.met.date.year,
    metMonth = mon.met.date.month,
    metDay = mon.met.date.day,
    eggLocation = mon.egg.location,
    metLocation = mon.met.location,
    pokerus = mon.pokerus,
    ballId = context.balls[mon.origin.ball],
    metLevel = mon.met.level,
    trainerGender = mon.origin.trainerGender,
    terrain = mon.met.terrain,
    mood = mon.mood,
  }
end

return NativeLegality
