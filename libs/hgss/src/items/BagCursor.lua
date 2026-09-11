-- Runtime-only field Bag cursor: the current pocket plus the per-pocket
-- visible-grid position and scroll offset (include/bag_cursor.h keeps field
-- cursor state separate from saved Bag state). The cursor survives Bag
-- close/reopen inside one field runtime and resets on save/relaunch: no
-- cursor field ever enters the persisted save. Pure mutable runtime helper:
-- no love or save dependency beyond the shared pocket order.

local BagSave = require("libs.hgss.src.save.BagSave")

---@class BagCursor
---@field pocket string
---@field pockets table<string, { position: integer, scroll: integer }>
local BagCursor = {}
BagCursor.__index = BagCursor

---@return BagCursor
function BagCursor.new()
  local pockets = {}
  for _, pocketKey in ipairs(BagSave.POCKET_ORDER) do
    pockets[pocketKey] = { position = 0, scroll = 0 }
  end
  return setmetatable({ pocket = "items", pockets = pockets }, BagCursor)
end

---@param pocketKey string
local function checkPocket(self, pocketKey)
  if type(self.pockets[pocketKey]) ~= "table" then
    error("unknown bag pocket " .. tostring(pocketKey), 0)
  end
end

---@param offset integer
---@param what string
local function checkOffset(offset, what)
  assert(
    type(offset) == "number" and offset % 1 == 0 and offset >= 0,
    "bag cursor " .. what .. " must be a non-negative integer"
  )
end

---@return string
function BagCursor:currentPocket()
  return self.pocket
end

---@param pocketKey string
function BagCursor:setPocket(pocketKey)
  checkPocket(self, pocketKey)
  self.pocket = pocketKey
end

---@param pocketKey string?
---@return integer
function BagCursor:position(pocketKey)
  pocketKey = pocketKey or self.pocket
  checkPocket(self, pocketKey)
  return self.pockets[pocketKey].position
end

---@param pocketKey string
---@param position integer
function BagCursor:setPosition(pocketKey, position)
  checkPocket(self, pocketKey)
  checkOffset(position, "position")
  self.pockets[pocketKey].position = position
end

---@param pocketKey string?
---@return integer
function BagCursor:scroll(pocketKey)
  pocketKey = pocketKey or self.pocket
  checkPocket(self, pocketKey)
  return self.pockets[pocketKey].scroll
end

---@param pocketKey string
---@param scroll integer
function BagCursor:setScroll(pocketKey, scroll)
  checkPocket(self, pocketKey)
  checkOffset(scroll, "scroll")
  self.pockets[pocketKey].scroll = scroll
end

return BagCursor
