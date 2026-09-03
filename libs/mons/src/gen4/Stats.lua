-- Generation-IV stat derivation. Canonical sources: pret/pokeheartgold,
-- src/pokemon.c (CalcMonStats, ModifyStatByNature, gNatureStatMods).
-- Health follows the standard formula; the other stats apply the nature
-- modifier from the source table, where +1 raises the stat to 110% and -1
-- lowers it to 90%. Table columns are attack, defense, speed, special
-- attack, special defense.

---@class Stats
local Stats = {}

Stats.STAT_KEYS = { "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }

-- Indexed by nature 0..24.
local NATURE_MODIFIERS = {
  { 0, 0, 0, 0, 0 }, -- Hardy
  { 1, -1, 0, 0, 0 }, -- Lonely
  { 1, 0, -1, 0, 0 }, -- Brave
  { 1, 0, 0, -1, 0 }, -- Adamant
  { 1, 0, 0, 0, -1 }, -- Naughty
  { -1, 1, 0, 0, 0 }, -- Bold
  { 0, 0, 0, 0, 0 }, -- Docile
  { 0, 1, -1, 0, 0 }, -- Relaxed
  { 0, 1, 0, -1, 0 }, -- Impish
  { 0, 1, 0, 0, -1 }, -- Lax
  { -1, 0, 1, 0, 0 }, -- Timid
  { 0, -1, 1, 0, 0 }, -- Hasty
  { 0, 0, 0, 0, 0 }, -- Serious
  { 0, 0, 1, -1, 0 }, -- Jolly
  { 0, 0, 1, 0, -1 }, -- Naive
  { -1, 0, 0, 1, 0 }, -- Modest
  { 0, -1, 0, 1, 0 }, -- Mild
  { 0, 0, -1, 1, 0 }, -- Quiet
  { 0, 0, 0, 0, 0 }, -- Bashful
  { 0, 0, 0, 1, -1 }, -- Rash
  { -1, 0, 0, 0, 1 }, -- Calm
  { 0, -1, 0, 0, 1 }, -- Gentle
  { 0, 0, -1, 0, 1 }, -- Sassy
  { 0, 0, 0, -1, 1 }, -- Careful
  { 0, 0, 0, 0, 0 }, -- Quirky
}

local BATTLE_KEYS = { "attack", "defense", "speed", "specialAttack", "specialDefense" }

---@param baseStats table<string, integer>
---@param ivs table<string, integer>
---@param evs table<string, integer>
---@param level integer
---@param nature integer
---@return table<string, integer>
function Stats.calculate(baseStats, ivs, evs, level, nature)
  assert(type(baseStats) == "table", "base stats must be a table")
  assert(type(ivs) == "table", "individual values must be a table")
  assert(type(evs) == "table", "effort values must be a table")
  assert(
    type(level) == "number" and level % 1 == 0 and level >= 1 and level <= 100,
    "level must be an integer in 1..100"
  )
  assert(
    type(nature) == "number" and nature % 1 == 0 and nature >= 0 and nature <= 24,
    "nature must be an integer in 0..24"
  )
  local modifiers = NATURE_MODIFIERS[nature + 1]
  local out = {}
  out.hp = math.floor(((2 * baseStats.hp + ivs.hp + math.floor(evs.hp / 4)) * level) / 100) + level + 10
  for index, key in ipairs(BATTLE_KEYS) do
    local value = math.floor(((2 * baseStats[key] + ivs[key] + math.floor(evs[key] / 4)) * level) / 100) + 5
    local modifier = modifiers[index]
    if modifier == 1 then
      value = math.floor((value * 110) / 100)
    elseif modifier == -1 then
      value = math.floor((value * 90) / 100)
    end
    out[key] = value
  end
  return out
end

return Stats
