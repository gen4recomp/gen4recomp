-- Growth-curve lookup. A curve is the generated 1..100 cumulative
-- experience table; the level is the highest table entry at or below the
-- stored experience, clamped to level 100. Experience above the level-100
-- entry has no valid level and is rejected by record validation.

---@class Experience
local Experience = {}

---@param curve integer[]
---@param level integer
---@return integer
function Experience.expFor(curve, level)
  assert(type(curve) == "table", "growth curve must be a table")
  assert(
    type(level) == "number" and level % 1 == 0 and level >= 1 and level <= 100,
    "level must be an integer in 1..100"
  )
  return curve[level]
end

---@param curve integer[]
---@param experience integer
---@return integer
function Experience.level(curve, experience)
  assert(type(curve) == "table", "growth curve must be a table")
  assert(
    type(experience) == "number" and experience % 1 == 0 and experience >= 0,
    "experience must be a non-negative integer"
  )
  local found = 1
  for level = 1, 100 do
    local entry = curve[level]
    assert(
      type(entry) == "number" and entry % 1 == 0 and entry >= 0,
      "growth curve entries must be non-negative integers"
    )
    if entry <= experience then
      found = level
    else
      break
    end
  end
  return found
end

return Experience
