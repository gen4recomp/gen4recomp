-- Pure fixed-step state for the HGSS directional warp-entrance field effect.
-- The behavior mapping is owned by MetatileBehavior; this module only turns
-- that semantic direction into a presentation-neutral world draw record.

local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")

---@class FieldEntranceIndicator
local FieldEntranceIndicator = {}
FieldEntranceIndicator.__index = FieldEntranceIndicator

local ROTATION_DEGREES = { north = 180, south = 0, west = 270, east = 90 }
local PHASE_LENGTH = 16
local DELTAS = {
  north = { x = 0, z = -1 },
  south = { x = 0, z = 1 },
  west = { x = -1, z = 0 },
  east = { x = 1, z = 0 },
}

-- Signed 12.4 source offsets from ov01_02209354, normalized to field units.
-- The table is indexed by source direction and phase, and is intentionally
-- immutable through the public API.
local PHASE_OFFSETS = {
  north = { { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = -0.125 } },
  south = { { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0.125 } },
  west = { { x = 0, y = 0, z = 0 }, { x = -0.125, y = 0, z = 0 } },
  east = { { x = 0, y = 0, z = 0 }, { x = 0.125, y = 0, z = 0 } },
}

local function copyOffset(offset)
  return { x = offset.x, y = offset.y, z = offset.z }
end

function FieldEntranceIndicator.new()
  return setmetatable({
    phase = 0,
    counter = 0,
    statusRecord = { visible = false, phase = 0, counter = 0 },
  }, FieldEntranceIndicator)
end

local function behaviorOf(map, player)
  if player.behavior ~= nil then
    return player.behavior
  end
  if type(player.fieldX) ~= "number" or type(player.fieldZ) ~= "number" then
    return nil
  end
  local playerMap = player.currentMap or map
  -- A scene-less logical halo carries no collision grid: no entrance tile
  -- behavior is knowable until its visual map realizes.
  if playerMap.collision == nil then
    return nil
  end
  local localX, localZ = FieldCoordinates.fieldToLocal(playerMap, player.fieldX, player.fieldZ)
  return playerMap.collision:getLocal(localX, localZ).behavior
end

function FieldEntranceIndicator:_reset()
  self.phase, self.counter = 0, 0
  self.statusRecord = { visible = false, phase = 0, counter = 0 }
  return self.statusRecord
end

function FieldEntranceIndicator:updateFixed(runtime)
  assert(runtime and runtime.map and runtime.player and runtime.transition, "indicator runtime state is required")
  if runtime.transition.ownsField ~= true then
    return self:_reset()
  end
  local player, map = runtime.player, runtime.map
  local direction = MetatileBehavior.warpEntranceDirection(behaviorOf(map, player))
  if not direction or player.facing ~= direction then
    return self:_reset()
  end
  assert(DELTAS[direction] and ROTATION_DEGREES[direction], "unknown entrance direction")
  self.counter = self.counter + 1
  if self.counter >= PHASE_LENGTH then
    self.counter, self.phase = 0, 1 - self.phase
  end
  local delta = DELTAS[direction]
  local offset = PHASE_OFFSETS[direction][self.phase + 1]
  self.statusRecord = {
    visible = true,
    direction = direction,
    rotationDegrees = ROTATION_DEGREES[direction],
    scale = 1,
    phase = self.phase,
    counter = self.counter,
    offset = copyOffset(offset),
  }
  local world
  if type(player.worldX) == "number" and type(player.worldY) == "number" and type(player.worldZ) == "number" then
    world = { x = player.worldX, y = player.worldY, z = player.worldZ }
  elseif type(player.fieldX) == "number" and type(player.fieldZ) == "number" and type(player.worldY) == "number" then
    world = FieldCoordinates.fieldToWorld(player.currentMap or map, player.fieldX, player.fieldZ, player.worldY)
  end
  if world then
    self.statusRecord.position = {
      x = world.x + delta.x + offset.x,
      y = world.y + offset.y,
      z = world.z + delta.z + offset.z,
    }
  end
  return self.statusRecord
end

function FieldEntranceIndicator:status()
  return self.statusRecord
end

FieldEntranceIndicator.ROTATION_DEGREES = ROTATION_DEGREES
FieldEntranceIndicator.PHASE_OFFSETS = PHASE_OFFSETS

return FieldEntranceIndicator
