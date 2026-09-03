-- Personality derivations. Canonical sources: pret/pokeheartgold,
-- src/pokemon.c (GetNatureFromPersonality, gender and ability selection).
-- Nature is personality mod 25. Gender compares the low personality byte
-- against the species ratio, with fixed-gender and genderless ratios
-- short-circuiting. Shininess XORs the trainer and personality halves with
-- the source threshold below 8. The ability slot follows personality parity
-- for two-ability definitions; single-ability definitions always use slot 1.

---@class Personality
local Personality = {}

---@param personality integer
---@return integer
function Personality.nature(personality)
  assert(
    type(personality) == "number" and personality % 1 == 0 and personality >= 0 and personality <= 0xFFFFFFFF,
    "personality must be an unsigned 32-bit integer"
  )
  return personality % 25
end

---@param ratio integer
---@param personality integer
---@return string
function Personality.gender(ratio, personality)
  assert(type(ratio) == "number" and ratio % 1 == 0 and ratio >= 0 and ratio <= 255, "gender ratio must be a u8")
  assert(
    type(personality) == "number" and personality % 1 == 0 and personality >= 0 and personality <= 0xFFFFFFFF,
    "personality must be an unsigned 32-bit integer"
  )
  if ratio == 255 then
    return "genderless"
  end
  if ratio == 0 then
    return "male"
  end
  if ratio == 254 then
    return "female"
  end
  if (personality % 256) < ratio then
    return "female"
  end
  return "male"
end

---@param a integer
---@param b integer
---@return integer
local function xor16(a, b)
  local value = 0
  local place = 1
  for _ = 1, 16 do
    local abit = math.floor(a / place) % 2
    local bbit = math.floor(b / place) % 2
    if abit ~= bbit then
      value = value + place
    end
    place = place * 2
  end
  return value
end
---@param trainerId integer
---@param personality integer
---@return boolean
function Personality.shiny(trainerId, personality)
  assert(
    type(trainerId) == "number" and trainerId % 1 == 0 and trainerId >= 0 and trainerId <= 0xFFFFFFFF,
    "trainer id must be an unsigned 32-bit integer"
  )
  assert(
    type(personality) == "number" and personality % 1 == 0 and personality >= 0 and personality <= 0xFFFFFFFF,
    "personality must be an unsigned 32-bit integer"
  )
  local a = math.floor(trainerId / 65536) % 65536
  local b = trainerId % 65536
  local c = math.floor(personality / 65536) % 65536
  local d = personality % 65536
  return xor16(xor16(a, b), xor16(c, d)) < 8
end

---@param abilityCount integer
---@param personality integer
---@return integer
function Personality.abilitySlot(abilityCount, personality)
  assert(abilityCount == 1 or abilityCount == 2, "ability count must be 1 or 2")
  assert(
    type(personality) == "number" and personality % 1 == 0 and personality >= 0 and personality <= 0xFFFFFFFF,
    "personality must be an unsigned 32-bit integer"
  )
  if abilityCount == 1 then
    return 1
  end
  return (personality % 2) + 1
end

return Personality
