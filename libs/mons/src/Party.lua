-- Ordered at-most-six party. Public positions are zero-based dense slots
-- from 0 to count-1, matching script and UI positions. The aggregate owns
-- copies of validated mon records: reads hand out copies so callers cannot
-- bypass validation or revision, and every successful structural change
-- increments the revision once. Adding to a full party returns false without
-- mutation; there is no PC fallback.

local Mon = require("libs.mons.src.Mon")
local MonsErrors = require("libs.mons.src.errors")

---@class Party
---@field private _mons table[]
---@field private _revision integer
local Party = {}
Party.__index = Party

Party.MAX = 6

---@param mons table[]?
---@param revision integer?
---@return Party
local function build(mons, revision)
  return setmetatable({ _mons = mons or {}, _revision = revision or 0 }, Party)
end

---@return Party
function Party.new()
  return build()
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

---@param slot integer
---@param count integer
---@param what string
local function checkSlot(slot, count, what)
  if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 0 or slot >= count then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, what .. " slot is out of range", { slot = slot })
  end
end

---@return integer
function Party:count()
  return #self._mons
end

---@param slot0 integer
---@return table
function Party:get(slot0)
  checkSlot(slot0, #self._mons, "party slot")
  return copyValue(self._mons[slot0 + 1])
end

-- Adds a copy of the mon; false when full, without mutation.
---@param mon table
---@return boolean
function Party:add(mon)
  assert(type(mon) == "table", "party add requires a mon record")
  if #self._mons >= Party.MAX then
    return false
  end
  self._mons[#self._mons + 1] = copyValue(mon)
  self._revision = self._revision + 1
  return true
end

---@param slot0 integer
---@return table
function Party:remove(slot0)
  checkSlot(slot0, #self._mons, "party removal")
  local removed = table.remove(self._mons, slot0 + 1)
  self._revision = self._revision + 1
  return copyValue(removed)
end

---@param left0 integer
---@param right0 integer
function Party:swap(left0, right0)
  checkSlot(left0, #self._mons, "party swap")
  checkSlot(right0, #self._mons, "party swap")
  if left0 ~= right0 then
    local left = left0 + 1
    local right = right0 + 1
    self._mons[left], self._mons[right] = self._mons[right], self._mons[left]
    self._revision = self._revision + 1
  end
end

---@param predicate fun(mon: table): boolean
---@return integer?
function Party:findFirst(predicate)
  assert(type(predicate) == "function", "party search requires a predicate")
  for index, mon in ipairs(self._mons) do
    if predicate(copyValue(mon)) then
      return index - 1
    end
  end
  return nil
end

---@return integer?
function Party:leadSlot()
  if #self._mons == 0 then
    return nil
  end
  return 0
end

---@return integer?
function Party:leadAliveSlot()
  for index, mon in ipairs(self._mons) do
    if not mon.isEgg and mon.condition.currentHp > 0 then
      return index - 1
    end
  end
  return nil
end

---@return integer
function Party:revision()
  return self._revision
end

---@return { max: integer, mons: table[] }
function Party:capture()
  return { max = Party.MAX, mons = copyValue(self._mons) }
end

---@param snapshot table
---@param context table
---@return boolean
function Party.validate(snapshot, context)
  assert(type(context) == "table", "party validation requires a context")
  if type(snapshot) ~= "table" then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "party snapshot must be a record", {})
  end
  if snapshot.max ~= Party.MAX then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "party snapshot must carry max six", {})
  end
  if type(snapshot.mons) ~= "table" then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "party snapshot must carry a mon array", {})
  end
  local count = 0
  for key in pairs(snapshot.mons) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
      MonsErrors.raise(MonsErrors.SAVE_INVALID, "party snapshot keys must be dense from one", {})
    end
    if key > count then
      count = key
    end
  end
  if count > Party.MAX then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "party snapshot exceeds six mons", {})
  end
  for index = 1, count do
    if snapshot.mons[index] == nil then
      MonsErrors.raise(MonsErrors.SAVE_INVALID, "party snapshot must stay dense", {})
    end
  end
  for _, mon in ipairs(snapshot.mons) do
    Mon.validate(mon, context)
  end
  return true
end

---@param snapshot table
---@param context table
---@return Party
function Party.restore(snapshot, context)
  Party.validate(snapshot, context)
  local mons = {}
  for _, mon in ipairs(snapshot.mons) do
    mons[#mons + 1] = Mon.validate(mon, context)
  end
  return build(mons, #mons)
end

return Party
