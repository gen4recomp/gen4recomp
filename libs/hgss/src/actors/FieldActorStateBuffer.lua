-- Contiguous numeric/boolean runtime state for one map entry's object actors.
-- Each actor owns a stable zero-based storage slot; the backing FFI array may
-- grow while slot integers never change. Symbolic/domain state (facing, pose,
-- cell keys, motion transactions) stays on the actor Lua object.

local ffi = require("ffi")

local function hasCompleteType(name)
  local ok, size = pcall(ffi.sizeof, name)
  return ok and size ~= nil
end

if not hasCompleteType("G4FieldActorNumeric") then
  ffi.cdef([[
typedef struct {
  int32_t fieldX;
  int32_t fieldZ;
  double worldX, worldY, worldZ;
  double previousWorldX, previousWorldY, previousWorldZ;
  int32_t sourceSurfaceId;
  int32_t surfaceId;
  int32_t poseTick;
  int32_t gestureTick;
  double presentationOffsetX, presentationOffsetY, presentationOffsetZ;
  double gestureOffsetY;
  uint8_t hasWorldPosition;
  uint8_t hasPreviousWorldPosition;
  uint8_t hasSourceSurfaceId;
  uint8_t hasSurfaceId;
  uint8_t hasGestureTick;
  uint8_t resident;
  uint8_t visible;
  uint8_t solid;
  uint8_t animationPaused;
  uint8_t scriptedPresentationAdvanced;
} G4FieldActorNumeric;
]])
end

---@class G4FieldActorNumeric
---@field fieldX integer
---@field fieldZ integer
---@field worldX number
---@field worldY number
---@field worldZ number
---@field previousWorldX number
---@field previousWorldY number
---@field previousWorldZ number
---@field sourceSurfaceId integer
---@field surfaceId integer
---@field poseTick integer
---@field gestureTick integer
---@field presentationOffsetX number
---@field presentationOffsetY number
---@field presentationOffsetZ number
---@field gestureOffsetY number
---@field hasWorldPosition integer
---@field hasPreviousWorldPosition integer
---@field hasSourceSurfaceId integer
---@field hasSurfaceId integer
---@field hasGestureTick integer
---@field resident integer
---@field visible integer
---@field solid integer
---@field animationPaused integer
---@field scriptedPresentationAdvanced integer

---@class FieldActorStateBuffer
---@field private _data ffi.cdata*
---@field private _capacity integer
---@field private _nextSlot integer
---@field private _active table<integer, boolean>
---@field private _freeSlots integer[]
local FieldActorStateBuffer = {}
FieldActorStateBuffer.__index = FieldActorStateBuffer

local DEFAULT_INITIAL_CAPACITY = 16

local function validCapacity(value)
  return type(value) == "number" and value % 1 == 0 and value >= 1
end

---@param initialCapacity integer?
---@return FieldActorStateBuffer
function FieldActorStateBuffer.new(initialCapacity)
  local capacity = initialCapacity or DEFAULT_INITIAL_CAPACITY
  assert(validCapacity(capacity), "actor numeric state initial capacity must be a positive integer")
  return setmetatable({
    _data = ffi.new("G4FieldActorNumeric[?]", capacity),
    _capacity = capacity,
    _nextSlot = 0,
    _active = {},
    _freeSlots = {},
  }, FieldActorStateBuffer)
end

---@param slot integer
local function ensureCapacity(self, slot)
  if slot < self._capacity then
    return
  end
  local capacity = self._capacity
  while capacity <= slot do
    capacity = capacity * 2
  end
  local replacement = ffi.new("G4FieldActorNumeric[?]", capacity)
  ffi.copy(replacement, self._data, self._capacity * ffi.sizeof("G4FieldActorNumeric"))
  self._data = replacement
  self._capacity = capacity
end

---@param slot integer
local function checkSlot(self, slot)
  assert(type(slot) == "number" and slot % 1 == 0, "actor numeric slot must be an integer")
  assert(slot >= 0 and slot < self._nextSlot, "actor numeric slot was never allocated")
  assert(self._active[slot], "actor numeric slot is not live")
end

---@param self FieldActorStateBuffer
---@return integer slot stable zero-based storage identity
function FieldActorStateBuffer:allocate()
  local slot = table.remove(self._freeSlots)
  if slot == nil then
    slot = self._nextSlot
    self._nextSlot = self._nextSlot + 1
    ensureCapacity(self, slot)
  end
  assert(not self._active[slot], "actor numeric slot is already live")
  ffi.fill(self._data[slot], ffi.sizeof("G4FieldActorNumeric") --[[@as integer]])
  self._active[slot] = true
  return slot
end

---@param self FieldActorStateBuffer
---@param slot integer
function FieldActorStateBuffer:release(slot)
  checkSlot(self, slot)
  self._active[slot] = nil
  self._freeSlots[#self._freeSlots + 1] = slot
end

---@param self FieldActorStateBuffer
---@param slot integer
---@return G4FieldActorNumeric live record; resolve on every use, never retain across actor creation/removal
function FieldActorStateBuffer:at(slot)
  checkSlot(self, slot)
  return self._data[slot]
end

return FieldActorStateBuffer
