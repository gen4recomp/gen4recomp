-- Deterministic field actor movement over permission and BDHC terrain data.
-- Integer field coordinates commit only after a fixed-duration tile step;
-- continuous XYZ is the shared camera and renderer position throughout it.
--
-- Collision order: collision, then terrain surface
-- transition, then dynamic occupancy. The occupancy check is injected as a
-- pure predicate over a physical candidate, so the player never knows which
-- object blocks it, and the actor manager stays the only owner of the index.

local Errors = require("libs.errors.src.Errors")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local FieldGrid = require("libs.hgss.src.world.FieldGrid")
local SurfaceResolver = require("libs.hgss.src.world.SurfaceResolver")
local FieldTraversal = require("libs.hgss.src.world.FieldTraversal")

---@class FieldPlayer : FieldPlayerVisual.Source
---@field currentMap RuntimeFieldMap
---@field resolver SurfaceResolver
---@field occupancy fun(candidate: FieldOccupancyCandidate): string|nil
---@field fieldX integer
---@field fieldZ integer
---@field localX integer
---@field localZ integer
---@field worldX number
---@field worldY number
---@field worldZ number
---@field previousWorldX number
---@field previousWorldY number
---@field previousWorldZ number
---@field surfaceId integer
---@field facing FieldDirection
---@field motion "idle"|"walking"|"turning"|"jumping"|"transition"
---@field progressTicks integer
---@field durationTicks integer
---@field animationPaused boolean
---@field bufferedDirection FieldDirection?
---@field from table<string, unknown>?
---@field to table<string, unknown>?
---@field committedSourceCellKey string?
---@field committedSourceSurfaceId integer?
---@field transitionKind "ladder_exit"|"ladder_down_exit"|"vertical_return"|"held_stair"|nil
---@field transitionFacing FieldDirection?
---@field transitionFrom table<string, unknown>?
---@field transitionTo table<string, unknown>?
---@field transitionProgress number?
---@field private _gesturePose string?
---@field private _gestureTick integer?
---@field private _gestureOffsetY number
---@field private _scriptedMotion table<string, unknown>?
---@field private _movementRevision integer committed tile commits observed by followers
---@field private _lastTraversalKind string traversal kind of the last committed tile
---@field private _movementStartRevision integer resolved translation starts observed by followers
---@field private _movementTransaction FieldPlayer.MovementTransaction? latest resolved translation start
local FieldPlayer = {}
FieldPlayer.__index = FieldPlayer

-- Gameplay timing constants, centralized so emulator calibration changes
-- exactly one place.
FieldPlayer.WALK_STEP_TICKS = 8
FieldPlayer.TURN_TICKS = 2
FieldPlayer.LEDGE_JUMP_TICKS = 16

---@alias FieldDirection "north"|"south"|"west"|"east"

---@class FieldPlayer.MovementTransaction
---@field revision integer
---@field mapId integer
---@field from table<string, unknown>
---@field to table<string, unknown>
---@field direction FieldDirection
---@field traversalKind string
---@field speed string semantic walk speed; durationTicks is its calibration
---@field durationTicks integer

---@class FieldPlayerOptions
---@field currentMap RuntimeFieldMap
---@field fieldX integer
---@field fieldZ integer
---@field surfaceId integer
---@field facing FieldDirection?
---@field initialWorldY number?
---@field occupancy? fun(candidate: FieldOccupancyCandidate): string|nil

---@class FieldOccupancyCandidate
---@field fieldX integer
---@field fieldZ integer
---@field surfaceId integer?
---@field cellKey string?
---@field sourceSurfaceId integer?

local DELTAS = {
  north = { x = 0, z = -1 },
  south = { x = 0, z = 1 },
  west = { x = -1, z = 0 },
  east = { x = 1, z = 0 },
}

local function isInteger(value)
  return type(value) == "number" and value == math.floor(value)
end

---@param fieldX integer
---@param fieldZ integer
---@param surfaceId integer?
---@param cellKey string?
---@param sourceSurfaceId integer?
---@return FieldOccupancyCandidate
local function occupancyCandidate(fieldX, fieldZ, surfaceId, cellKey, sourceSurfaceId)
  return {
    fieldX = fieldX,
    fieldZ = fieldZ,
    surfaceId = surfaceId,
    cellKey = cellKey,
    sourceSurfaceId = sourceSurfaceId,
  }
end

local function projectPoint(runtimeMap, fieldX, fieldZ, cellKey, sourceSurfaceId)
  if runtimeMap.projectPhysicalPoint then
    return runtimeMap:projectPhysicalPoint(fieldX, fieldZ, cellKey, sourceSurfaceId)
  end
  local region = assert(runtimeMap.fieldRegion, "physical field region required")
  local surfaceId = assert(region:sourceSurface(cellKey, sourceSurfaceId), "player surface is absent from coverage")
  local origin = assert(runtimeMap.physicalOrigin or {
    x = runtimeMap.coordinateOrigin.x,
    y = 0,
    z = runtimeMap.coordinateOrigin.z,
  })
  local localX, localZ = fieldX - origin.x, fieldZ - origin.z
  local centerX, centerZ = localX + FieldCoordinates.TILE_CENTER_OFFSET, localZ + FieldCoordinates.TILE_CENTER_OFFSET
  return {
    fieldX = fieldX,
    fieldZ = fieldZ,
    cellKey = cellKey,
    sourceSurfaceId = sourceSurfaceId,
    surfaceId = surfaceId,
    localX = localX,
    localZ = localZ,
    worldX = centerX,
    worldY = runtimeMap.terrain:sampleHeight(surfaceId, centerX, centerZ),
    worldZ = centerZ,
  }
end

-- Only failures that genuinely mean the step was legally rejected are
-- ordinary blocked moves: the destination outside permission coverage, or
-- its terrain beyond the reachable step height. Malformed or ambiguous
-- terrain, and a current surface inconsistent with the player's own position,
-- are corrupted state and propagate instead.
local function recoverableMovementError(err)
  if not Errors.is(err) then
    return false
  end
  ---@cast err Errors.Error
  return err.code == "FIELD_COORDINATES_OUT_OF_COVERAGE" or SurfaceResolver.isStepRejection(err)
end

---@param options FieldPlayerOptions
---@return FieldPlayer
function FieldPlayer.new(options)
  assert(type(options) == "table" and options.currentMap, "FieldPlayer map required")
  assert(isInteger(options.fieldX) and isInteger(options.fieldZ), "FieldPlayer integer field coordinates required")
  assert(type(options.surfaceId) == "number", "FieldPlayer surface id required")
  assert(
    options.occupancy == nil or type(options.occupancy) == "function",
    "FieldPlayer occupancy predicate must be a function"
  )
  local map = options.currentMap
  local localX, localZ = FieldCoordinates.fieldToLocal(map, options.fieldX, options.fieldZ)
  local sample = options.initialWorldY == nil
      and map.terrain:sample(
        options.surfaceId,
        localX + FieldCoordinates.TILE_CENTER_OFFSET,
        localZ + FieldCoordinates.TILE_CENTER_OFFSET
      )
    or { surfaceId = options.surfaceId, worldY = options.initialWorldY }
  local point = FieldCoordinates.fieldToWorld(map, options.fieldX, options.fieldZ, sample.worldY)
  local plate = map.terrain:plate(sample.surfaceId)
  return setmetatable({
    currentMap = map,
    resolver = SurfaceResolver.new(map.terrain),
    occupancy = options.occupancy,
    fieldX = options.fieldX,
    fieldZ = options.fieldZ,
    localX = localX,
    localZ = localZ,
    worldX = point.x,
    worldY = point.y,
    worldZ = point.z,
    previousWorldX = point.x,
    previousWorldY = point.y,
    previousWorldZ = point.z,
    surfaceId = sample.surfaceId,
    committedSourceCellKey = plate and plate.cellKey or nil,
    committedSourceSurfaceId = plate and plate.sourceSurfaceId or nil,
    facing = options.facing or "south",
    motion = "idle",
    progressTicks = 0,
    durationTicks = FieldPlayer.WALK_STEP_TICKS,
    animationPaused = false,
    transitionKind = nil,
    transitionFacing = nil,
    transitionProgress = nil,
    _gesturePose = nil,
    _gestureTick = nil,
    _gestureOffsetY = 0,
    _movementRevision = 0,
    _lastTraversalKind = "idle",
    _movementStartRevision = 0,
    _movementTransaction = nil,
  }, FieldPlayer)
end

-- A destination needs the physical-cell probe, rather than the map's plain
-- composite collision/terrain, whenever it falls outside the resident
-- coverage window or the player's own current surface plate does not reach
-- the tile it is standing on (a plate boundary inside the same resident
-- cell). `tryStep`'s traversal classification and `_resolveStep`'s full
-- resolution must agree on this or one will accept a step the other rejects.
function FieldPlayer:_crossesToPhysicalProbe(destinationX, destinationZ)
  if not self.currentMap.coverage then
    return false
  end
  local currentSurfaceCoversSource = self.currentMap.terrain:contains(
    self.surfaceId,
    self.localX + FieldCoordinates.TILE_CENTER_OFFSET,
    self.localZ + FieldCoordinates.TILE_CENTER_OFFSET
  )
  return not self.currentMap.coverage:containsGlobal(destinationX, destinationZ) or not currentSurfaceCoversSource
end

-- Resolve the adjacent tile for a step: permission blocking and dynamic
-- occupancy gate ordinary steps; `bypassBlocking` skips both for the door
-- choreography's scripted steps (the player must walk into the door tile
-- normal movement cannot enter). Terrain surface resolution always governs.
function FieldPlayer:_resolveStep(direction, bypassBlocking)
  local delta = assert(DELTAS[direction], "unknown field direction " .. tostring(direction))
  local destinationX, destinationZ = self.fieldX + delta.x, self.fieldZ + delta.z
  if not bypassBlocking and self:_crossesToPhysicalProbe(destinationX, destinationZ) then
    local currentSourceSurfaceId = self.committedSourceSurfaceId
    assert(currentSourceSurfaceId ~= nil, "player stable source id is missing")
    local probe = self.currentMap:probePhysicalCell(destinationX, destinationZ, {
      currentCellKey = assert(self.committedSourceCellKey, "player stable source cell identity is missing"),
      currentSourceSurfaceId = currentSourceSurfaceId,
      currentY = self.worldY,
      fromFieldX = self.fieldX,
      fromFieldZ = self.fieldZ,
    })
    if not probe or probe.collision.blocked then
      return nil
    end
    assert(probe.cellKey ~= nil and probe.sourceSurfaceId ~= nil, "physical probe stable surface identity is missing")
    local localX = destinationX - self.currentMap.coordinateOrigin.x
    local localZ = destinationZ - self.currentMap.coordinateOrigin.z
    local worldX, worldZ = FieldGrid.tileCenterToWorld(localX, localZ)
    local candidate =
      occupancyCandidate(destinationX, destinationZ, probe.surfaceId, probe.cellKey, probe.sourceSurfaceId)
    if self.occupancy and self.occupancy(candidate) then
      return nil
    end
    return {
      fieldX = destinationX,
      fieldZ = destinationZ,
      localX = localX,
      localZ = localZ,
      worldX = worldX,
      worldY = probe.worldY,
      worldZ = worldZ,
      surfaceId = probe.surfaceId,
      sourceCellKey = probe.cellKey,
      sourceSurfaceId = probe.sourceSurfaceId,
    }
  end
  local ok, result = pcall(function()
    local destinationLocalX, destinationLocalZ =
      FieldCoordinates.fieldToLocal(self.currentMap, destinationX, destinationZ)
    if not bypassBlocking and self.currentMap.collision:isBlockedLocal(destinationLocalX, destinationLocalZ) then
      return nil
    end
    local sourceX, sourceZ =
      self.localX + FieldCoordinates.TILE_CENTER_OFFSET, self.localZ + FieldCoordinates.TILE_CENTER_OFFSET
    local destinationCenterX, destinationCenterZ =
      destinationLocalX + FieldCoordinates.TILE_CENTER_OFFSET, destinationLocalZ + FieldCoordinates.TILE_CENTER_OFFSET
    local sample = self.resolver:resolve({
      localX = destinationCenterX,
      localZ = destinationCenterZ,
      currentSurfaceId = self.surfaceId,
      currentY = self.worldY,
      crossing = {
        fromX = sourceX,
        fromZ = sourceZ,
        toX = destinationCenterX,
        toZ = destinationCenterZ,
      },
    })
    local point = FieldCoordinates.fieldToWorld(self.currentMap, destinationX, destinationZ, sample.worldY)
    local plate = assert(self.currentMap.terrain:plate(sample.surfaceId), "resolved destination surface missing")
    -- Occupancy is checked against the resolved destination surface, so an
    -- actor on a different surface never blocks a same-cell approach, and it
    -- runs only after terrain accepts the step.
    if not bypassBlocking and self.occupancy then
      local candidate =
        occupancyCandidate(destinationX, destinationZ, sample.surfaceId, plate.cellKey, plate.sourceSurfaceId)
      if self.occupancy(candidate) then
        return nil
      end
    end
    return {
      fieldX = destinationX,
      fieldZ = destinationZ,
      localX = destinationLocalX,
      localZ = destinationLocalZ,
      worldX = point.x,
      worldY = point.y,
      worldZ = point.z,
      surfaceId = sample.surfaceId,
      sourceCellKey = plate.cellKey,
      sourceSurfaceId = plate.sourceSurfaceId,
    }
  end)
  if not ok then
    if recoverableMovementError(result) then
      return nil
    end
    error(result)
  end
  return result
end

---@param point table<string, unknown>
---@return table<string, unknown>
local function copyAnchor(point)
  return {
    fieldX = point.fieldX,
    fieldZ = point.fieldZ,
    localX = point.localX,
    localZ = point.localZ,
    worldX = point.worldX,
    worldY = point.worldY,
    worldZ = point.worldZ,
    surfaceId = point.surfaceId,
    cellKey = point.cellKey,
    sourceCellKey = point.sourceCellKey,
    sourceSurfaceId = point.sourceSurfaceId,
  }
end

-- Shared step start for ordinary and scripted steps: capture the from state,
-- adopt the resolved destination, and enter the walking motion. The semantic
-- speed is final here: manual steps walk normal, scripted steps carry their
-- action speed, and the published duration is that speed's calibration.
function FieldPlayer:_beginStep(direction, destination, speed)
  assert(type(speed) == "string", "movement speed required")
  local MovementCalibration = require("libs.hgss.src.script.tasks.MovementCalibration")
  local durationTicks = assert(MovementCalibration.SPEED_TICKS[speed], "unknown movement speed " .. tostring(speed))
  self.facing = direction
  self.from = {
    fieldX = self.fieldX,
    fieldZ = self.fieldZ,
    localX = self.localX,
    localZ = self.localZ,
    worldX = self.worldX,
    worldY = self.worldY,
    worldZ = self.worldZ,
    surfaceId = self.surfaceId,
  }
  self.to = destination
  self.motion = "walking"
  self.progressTicks = 0
  self.durationTicks = durationTicks
  self:_publishMovementStart(direction, speed)
end

-- Publish the resolved translation before the first in-flight tick: source
-- and destination anchors, direction, traversal kind, semantic speed, and
-- duration are final for this step. Blocked input and facing-only turns
-- never reach this path, so they publish nothing.
---@param direction FieldDirection
---@param speed string
function FieldPlayer:_publishMovementStart(direction, speed)
  assert(type(speed) == "string", "movement speed required")
  local MovementCalibration = require("libs.hgss.src.script.tasks.MovementCalibration")
  assert(
    self.durationTicks == MovementCalibration.SPEED_TICKS[speed],
    "movement duration must match the semantic speed calibration"
  )
  self._movementStartRevision = self._movementStartRevision + 1
  self._movementTransaction = {
    revision = self._movementStartRevision,
    mapId = self.currentMap.mapId,
    from = copyAnchor(assert(self.from, "movement source required")),
    to = copyAnchor(assert(self.to, "movement destination required")),
    direction = direction,
    traversalKind = "walk",
    speed = speed,
    durationTicks = self.durationTicks,
  }
end

function FieldPlayer:_beginTurn(direction)
  self.facing = direction
  self.motion = "turning"
  self.progressTicks = 0
  self.durationTicks = FieldPlayer.TURN_TICKS
end

function FieldPlayer:_beginJump(direction, destination)
  self.facing = direction
  self.from = {
    fieldX = self.fieldX,
    fieldZ = self.fieldZ,
    localX = self.localX,
    localZ = self.localZ,
    worldX = self.worldX,
    worldY = self.worldY,
    worldZ = self.worldZ,
    surfaceId = self.surfaceId,
  }
  self.to = destination
  self.motion = "jumping"
  self.progressTicks = 0
  self.durationTicks = FieldPlayer.LEDGE_JUMP_TICKS
end

function FieldPlayer:_advanceTurn()
  assert(self.motion == "turning", "turning motion required")
  self.progressTicks = self.progressTicks + 1
  if self.progressTicks >= FieldPlayer.TURN_TICKS then
    self.motion = "idle"
    self.progressTicks = 0
  end
  return false
end

-- Shared step classification: resolves the destination collision cell (via
-- the physical probe or the map's own collision grid, matching whichever
-- `_resolveStep` would consult) and runs it through `FieldTraversal.classify`.
-- `tryStep` and the non-mutating `resolveStep` query must agree on this, or
-- one accepts a step the other rejects.
---@param direction FieldDirection
---@return table<string, unknown>
function FieldPlayer:_stepDecision(direction)
  local delta = assert(DELTAS[direction], "unknown field direction " .. tostring(direction))
  local destinationX, destinationZ = self.fieldX + delta.x, self.fieldZ + delta.z
  local ok, destinationCell = pcall(function()
    if self:_crossesToPhysicalProbe(destinationX, destinationZ) then
      local probe = self.currentMap:probePhysicalCell(destinationX, destinationZ, {
        currentCellKey = assert(self.committedSourceCellKey, "player stable source cell identity is missing"),
        currentSourceSurfaceId = assert(self.committedSourceSurfaceId, "player stable source id is missing"),
        currentY = self.worldY,
        fromFieldX = self.fieldX,
        fromFieldZ = self.fieldZ,
      })
      return probe and probe.collision or { blocked = true }
    end
    if not self.currentMap.collision.getLocal then
      local blocked = false
      if self.currentMap.collision.isBlockedLocal then
        blocked = self.currentMap.collision:isBlockedLocal(destinationX, destinationZ)
      end
      return { blocked = blocked }
    end
    local localX, localZ = FieldCoordinates.fieldToLocal(self.currentMap, destinationX, destinationZ)
    return self.currentMap.collision:getLocal(localX, localZ)
  end)
  if not ok then
    if recoverableMovementError(destinationCell) then
      return { kind = "blocked" }
    end
    error(destinationCell)
  end
  return FieldTraversal.classify(destinationCell, direction)
end

-- Non-mutating production movement query: the same collision, terrain,
-- ledge/field-action classification, and live-occupancy resolution `tryStep`
-- uses, without committing a step. Callers (route planners, precondition
-- checks) can ask "where would this direction lead" without duplicating
-- `tryStep`'s domain rule.
---@param direction FieldDirection
---@return { fieldX: integer, fieldZ: integer, localX: integer, localZ: integer, worldX: number, worldY: number, worldZ: number, surfaceId: integer }|nil
function FieldPlayer:resolveStep(direction)
  assert(DELTAS[direction], "unknown field direction " .. tostring(direction))
  local decision = self:_stepDecision(direction)
  if decision.kind == "field_action" or decision.kind == "blocked" then
    return nil
  elseif decision.kind == "ledge_jump" then
    return self:_resolveLedgeLanding(direction)
  end
  return self:_resolveStep(direction)
end

-- Turn in place: the same facing-only mutation the script `turn` service
-- performs, exposed as a narrow public operation so callers that need
-- deterministic facing setup do not have to attempt a movement step.
---@param direction FieldDirection
function FieldPlayer:turn(direction)
  assert(DELTAS[direction], "unknown field direction " .. tostring(direction))
  if self:isScriptedMoving() then
    self.facing = direction
    return
  end
  assert(self.motion == "idle", "cannot turn while the player is moving")
  self.facing = direction
end

function FieldPlayer:tryStep(direction)
  assert(DELTAS[direction], "unknown field direction " .. tostring(direction))
  assert(self.motion == "idle", "cannot begin a field step while walking")
  self.facing = direction

  local decision = self:_stepDecision(direction)
  if decision.kind == "field_action" or decision.kind == "blocked" then
    return false
  elseif decision.kind == "ledge_jump" then
    local destination = self:_resolveLedgeLanding(direction)
    if not destination then
      return false
    end
    self:_beginJump(direction, destination)
    return true
  end

  local destination = self:_resolveStep(direction)
  if not destination then
    return false
  end
  self:_beginStep(direction, destination, "normal")
  return true
end

function FieldPlayer:_resolveLedgeLanding(direction)
  local delta = assert(DELTAS[direction], "unknown field direction " .. tostring(direction))
  local landingX, landingZ = self.fieldX + delta.x * 2, self.fieldZ + delta.z * 2
  local ok, result = pcall(function()
    local landingLocalX, landingLocalZ = FieldCoordinates.fieldToLocal(self.currentMap, landingX, landingZ)
    if self.currentMap.collision:isBlockedLocal(landingLocalX, landingLocalZ) then
      return nil
    end
    local landingCenterX = landingLocalX + FieldCoordinates.TILE_CENTER_OFFSET
    local landingCenterZ = landingLocalZ + FieldCoordinates.TILE_CENTER_OFFSET
    local sample = self.resolver:resolve({
      localX = landingCenterX,
      localZ = landingCenterZ,
      currentSurfaceId = self.surfaceId,
      currentY = self.worldY,
    })
    local plate = assert(self.currentMap.terrain:plate(sample.surfaceId), "resolved landing surface missing")
    local candidate = occupancyCandidate(landingX, landingZ, sample.surfaceId, plate.cellKey, plate.sourceSurfaceId)
    if self.occupancy and self.occupancy(candidate) then
      return nil
    end
    local point = FieldCoordinates.fieldToWorld(self.currentMap, landingX, landingZ, sample.worldY)
    return {
      fieldX = landingX,
      fieldZ = landingZ,
      localX = landingLocalX,
      localZ = landingLocalZ,
      worldX = point.x,
      worldY = sample.worldY,
      worldZ = point.z,
      surfaceId = sample.surfaceId,
      sourceCellKey = plate.cellKey,
      sourceSurfaceId = plate.sourceSurfaceId,
    }
  end)
  if not ok then
    if recoverableMovementError(result) then
      return nil
    end
    error(result)
  end
  return result
end

-- A scripted step for the door choreography: like tryStep, but the blocked
-- permission check and dynamic occupancy are bypassed, so the player can walk
-- into the door tile normal movement cannot enter and out of a door tile onto
-- the floor beyond it. Terrain surface resolution still governs (a door tile
-- without a walkable surface simply fails, and the choreography continues by
-- fading). Returns true when the step began.
function FieldPlayer:scriptedStep(direction)
  assert(DELTAS[direction], "unknown field direction " .. tostring(direction))
  assert(self.motion == "idle", "cannot begin a scripted step while walking")
  local destination = self:_resolveStep(direction, true)
  if not destination then
    return false
  end
  self:_beginStep(direction, destination, "normal")
  return true
end

function FieldPlayer:beginTransitionStep(direction)
  assert(self.motion == "idle", "cannot begin a transition step while moving")
  return self:scriptedStep(direction)
end

-- Starts destination-side horizontal-stair presentation from an adjacent
-- sampled point into the player's existing logical anchor. This is visual
-- motion only: the player keeps the destination warp's logical ownership.
function FieldPlayer:beginTransitionHeldStair(startWorld, facing)
  assert(self.motion == "idle", "cannot begin held-stair presentation while moving")
  assert(facing == "east" or facing == "west", "held-stair presentation facing required")
  assert(type(startWorld) == "table", "held-stair presentation start required")
  assert(type(startWorld.x) == "number" and type(startWorld.y) == "number" and type(startWorld.z) == "number")
  local anchor = { x = self.worldX, y = self.worldY, z = self.worldZ }
  self.motion = "transition"
  self.facing = facing
  self.progressTicks = 0
  self.durationTicks = FieldPlayer.WALK_STEP_TICKS
  self.transitionKind = "held_stair"
  self.transitionFacing = facing
  self.transitionProgress = 0
  self.previousWorldX, self.previousWorldY, self.previousWorldZ = startWorld.x, startWorld.y, startWorld.z
  self.worldX, self.worldY, self.worldZ = startWorld.x, startWorld.y, startWorld.z
  self.transitionFrom = { x = startWorld.x, y = startWorld.y, z = startWorld.z }
  self.transitionTo = anchor
  return true
end

function FieldPlayer:pauseTransitionAnimation()
  self.animationPaused = true
end

function FieldPlayer:resumeTransitionAnimation()
  self.animationPaused = false
end

local function beginTransitionPresentation(self, kind, facing, target)
  assert(self.motion == "idle", "cannot begin a transition motion while moving")
  self.motion = "transition"
  self.facing = facing
  self.progressTicks = 0
  self.durationTicks = 16
  self.transitionKind = kind
  self.transitionFacing = facing
  self.transitionProgress = 0
  self.transitionFrom = { x = self.worldX, y = self.worldY, z = self.worldZ }
  self.transitionTo = { x = target.x, y = target.y, z = target.z }
  return true
end

-- Source-side ladder ascent presentation. This never claims a field tile;
-- destination staging and the final semantic step own logical movement.
function FieldPlayer:beginTransitionLadderExit(facing)
  assert(type(facing) == "string", "ladder exit facing required")
  local target = { x = self.worldX, y = self.worldY + 2, z = self.worldZ }
  if facing == "south" then
    target.y = self.worldY + 0.5
    target.z = self.worldZ - 1.5
  end
  return beginTransitionPresentation(self, "ladder_exit", facing, target)
end

-- Source-side ladder descent presentation. It is deliberately separate from
-- ascent so the two source routines retain their opposite vertical motion.
function FieldPlayer:beginTransitionLadderDownExit(facing)
  assert(type(facing) == "string", "ladder-down exit facing required")
  return beginTransitionPresentation(self, "ladder_down_exit", facing, {
    x = self.worldX,
    y = self.worldY - 2,
    z = self.worldZ,
  })
end

-- Starts the sixteen-update vertical return from ladder staging to the
-- resolved anchor height. The caller performs the final cardinal tile step
-- only after this presentation interpolation completes.
function FieldPlayer:beginTransitionVerticalReturn(anchorY)
  assert(self.motion == "idle", "cannot begin a vertical return while moving")
  assert(type(anchorY) == "number", "ladder anchor height required")
  self.motion = "transition"
  self.progressTicks = 0
  self.durationTicks = 16
  self.transitionKind = "vertical_return"
  self.transitionFacing = nil
  self.transitionProgress = 0
  self.transitionFrom = { x = self.worldX, y = self.worldY, z = self.worldZ }
  self.transitionTo = { x = self.worldX, y = anchorY, z = self.worldZ }
  return true
end

function FieldPlayer:_advanceStep()
  assert(self.motion == "walking" and self.from and self.to, "walking step endpoints required")
  self.progressTicks = self.progressTicks + 1
  local progress = self.progressTicks / self.durationTicks
  self.worldX = self.from.worldX + (self.to.worldX - self.from.worldX) * progress
  self.worldZ = self.from.worldZ + (self.to.worldZ - self.from.worldZ) * progress
  if not self.to.sourceCellKey and self.from.surfaceId == self.to.surfaceId then
    local localX = self.from.localX
      + FieldCoordinates.TILE_CENTER_OFFSET
      + (self.to.localX - self.from.localX) * progress
    local localZ = self.from.localZ
      + FieldCoordinates.TILE_CENTER_OFFSET
      + (self.to.localZ - self.from.localZ) * progress
    self.worldY = self.currentMap.terrain:sampleHeight(self.to.surfaceId, localX, localZ)
  else
    self.worldY = self.from.worldY + (self.to.worldY - self.from.worldY) * progress
  end
  if self.progressTicks < self.durationTicks then
    return false
  end

  self.fieldX, self.fieldZ = self.to.fieldX, self.to.fieldZ
  self.localX, self.localZ = self.to.localX, self.to.localZ
  self.worldX, self.worldY, self.worldZ = self.to.worldX, self.to.worldY, self.to.worldZ
  self.surfaceId = self.to.surfaceId
  self.committedSourceCellKey = self.to.sourceCellKey
  self.committedSourceSurfaceId = self.to.sourceSurfaceId
  self.motion = "idle"
  self.progressTicks = 0
  self.from, self.to = nil, nil
  self:_commitTile("walk")
  return true
end

function FieldPlayer:_advanceJump()
  assert(self.motion == "jumping" and self.from and self.to, "jumping endpoints required")
  self.progressTicks = self.progressTicks + 1
  local progress = self.progressTicks / self.durationTicks
  self.worldX = self.from.worldX + (self.to.worldX - self.from.worldX) * progress
  self.worldZ = self.from.worldZ + (self.to.worldZ - self.from.worldZ) * progress
  local linearY = self.from.worldY + (self.to.worldY - self.from.worldY) * progress
  self.worldY = linearY + math.sin(math.pi * progress) * 0.5
  if self.progressTicks < self.durationTicks then
    return false
  end

  self.fieldX, self.fieldZ = self.to.fieldX, self.to.fieldZ
  self.localX, self.localZ = self.to.localX, self.to.localZ
  self.worldX, self.worldY, self.worldZ = self.to.worldX, self.to.worldY, self.to.worldZ
  self.surfaceId = self.to.surfaceId
  self.committedSourceCellKey = self.to.sourceCellKey
  self.committedSourceSurfaceId = self.to.sourceSurfaceId
  self.motion = "idle"
  self.progressTicks = 0
  self.from, self.to = nil, nil
  self:_commitTile("jump")
  return true
end

function FieldPlayer:updateFixed(input)
  input = input or {}
  self.previousWorldX, self.previousWorldY, self.previousWorldZ = self.worldX, self.worldY, self.worldZ

  if self.motion == "walking" then
    if input.pressedDirection then
      self.bufferedDirection = input.pressedDirection
    end
    return self:_advanceStep()
  end

  if self.motion == "turning" then
    if input.pressedDirection then
      self.bufferedDirection = input.pressedDirection
    end
    return self:_advanceTurn()
  end

  if self.motion == "jumping" then
    if input.pressedDirection then
      self.bufferedDirection = input.pressedDirection
    end
    return self:_advanceJump()
  end

  if self.motion == "transition" then
    self.progressTicks = self.progressTicks + 1
    local progress = self.progressTicks / self.durationTicks
    self.transitionProgress = math.min(1, progress)
    self.worldX = self.transitionFrom.x + (self.transitionTo.x - self.transitionFrom.x) * progress
    self.worldY = self.transitionFrom.y + (self.transitionTo.y - self.transitionFrom.y) * progress
    self.worldZ = self.transitionFrom.z + (self.transitionTo.z - self.transitionFrom.z) * progress
    if self.progressTicks >= self.durationTicks then
      self.worldX, self.worldY, self.worldZ = self.transitionTo.x, self.transitionTo.y, self.transitionTo.z
      self.motion = "idle"
      self.progressTicks = 0
      self.transitionFrom, self.transitionTo = nil, nil
      self.transitionKind = nil
      self.transitionFacing = nil
      self.transitionProgress = nil
    end
    return true
  end

  local direction
  local isWalkingContinuation = false
  if self.bufferedDirection and self.bufferedDirection == input.heldDirection then
    direction = self.bufferedDirection
    isWalkingContinuation = true
  else
    self.bufferedDirection = nil
    direction = input.pressedDirection or input.heldDirection
  end
  if not direction then
    return false
  end
  self.bufferedDirection = nil
  if not isWalkingContinuation and direction ~= self.facing then
    self:_beginTurn(direction)
    return self:_advanceTurn()
  end
  if self:tryStep(direction) then
    if self.motion == "jumping" then
      self:_advanceJump()
    else
      self:_advanceStep()
    end
  end
  return false
end

-- One revision per committed tile: ordinary steps and jumps bump on their
-- commit tick, scripted locomotion bumps when it changes tiles, and
-- teleports bump unconditionally. Interpolation, turns, and blocked input
-- never bump, so followers replay exactly the tiles the player settled on.
---@return integer
function FieldPlayer:movementRevision()
  return self._movementRevision
end

-- The latest resolved translation start: source/destination anchors,
-- direction, traversal kind, semantic speed, and duration, published when
-- the step begins and readable until the next step replaces it. Read-only by
-- convention: callers must not mutate the returned record or its anchors.
---@return FieldPlayer.MovementTransaction?
function FieldPlayer:movementTransaction()
  return self._movementTransaction
end

-- The last committed player anchor: map identity, tile, height, stable
-- surface identity, facing, and traversal kind. Facing and map read live so
-- turns and coverage rebases are visible without a revision bump.
---@return table<string, unknown>
function FieldPlayer:committedAnchor()
  return {
    mapId = self.currentMap.mapId,
    fieldX = self.fieldX,
    fieldZ = self.fieldZ,
    worldY = self.worldY,
    surfaceId = self.surfaceId,
    cellKey = self.committedSourceCellKey,
    sourceSurfaceId = self.committedSourceSurfaceId,
    facing = self.facing,
    traversalKind = self._lastTraversalKind,
  }
end

---@param kind string
function FieldPlayer:_commitTile(kind)
  self._movementRevision = self._movementRevision + 1
  self._lastTraversalKind = kind
end

function FieldPlayer:renderPosition(alpha)
  alpha = alpha == nil and 1 or math.max(0, math.min(1, alpha))
  return {
    x = self.previousWorldX + (self.worldX - self.previousWorldX) * alpha,
    y = self.previousWorldY + (self.worldY - self.previousWorldY) * alpha,
    z = self.previousWorldZ + (self.worldZ - self.previousWorldZ) * alpha,
  }
end

-- Collapse the render pair after a fixed tick that did not advance movement.
-- Locked transition phases still render between fixed updates; retaining the
-- final pair of a scripted door step would replay that fraction throughout
-- the following door animation.
function FieldPlayer:collapseRenderInterpolation()
  assert(self.motion == "idle", "cannot collapse interpolation while the player is moving")
  self.previousWorldX, self.previousWorldY, self.previousWorldZ = self.worldX, self.worldY, self.worldZ
end

-- --- Scripted locomotion (invariant-preserving) -----------------------------

function FieldPlayer:setScriptPosition(position)
  assert(
    type(position) == "table" and position.fieldX ~= nil and position.fieldZ ~= nil,
    "script position requires fieldX/Z"
  )
  local fieldX, fieldZ = position.fieldX, position.fieldZ
  local localX, localZ = FieldCoordinates.fieldToLocal(self.currentMap, fieldX, fieldZ)
  local sampleOpts = {
    localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
    localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
    currentY = position.worldY or self.worldY,
  }
  if position.worldY == nil then
    sampleOpts.currentSurfaceId = self.surfaceId
  end
  local sample = SurfaceResolver.new(self.currentMap.terrain):resolve(sampleOpts)
  local world = FieldCoordinates.fieldToWorld(self.currentMap, fieldX, fieldZ, sample.worldY)
  self.fieldX = fieldX
  self.fieldZ = fieldZ
  self.localX = localX
  self.localZ = localZ
  self.worldX = world.x
  self.worldY = world.y
  self.worldZ = world.z
  self.surfaceId = sample.surfaceId
  self.motion = "idle"
  self.progressTicks = 0
  self.from, self.to = nil, nil
  self._scriptedMotion = nil
  self._gesturePose = nil
  self._gestureTick = nil
  self._gestureOffsetY = 0
  self.previousWorldX, self.previousWorldY, self.previousWorldZ = self.worldX, self.worldY, self.worldZ
  self:_commitTile("scripted")
end

function FieldPlayer:clearGesturePresentation()
  self._gesturePose = nil
  self._gestureTick = nil
  self._gestureOffsetY = 0
end

function FieldPlayer:beginScriptedAction(action)
  local kind = action.action
  -- Face is an instantaneous direction change: it must succeed even when a
  -- scripted walk is mid-presentation (the MovementTask drives facing through
  -- beginScriptedAction while a walk's presentation may still be live). Treat
  -- it as the same mutation the script `turn` service performs: immediate,
  -- no from/to, no motion.
  if kind == "face" then
    assert(type(action.direction) == "string", "face direction required")
    self.facing = action.direction
    self.previousWorldX, self.previousWorldY, self.previousWorldZ = self.worldX, self.worldY, self.worldZ
    return
  end
  assert(self.motion == "idle", "cannot begin scripted action while moving")
  assert(type(action) == "table" and type(action.action) == "string", "scripted action required")
  local MovementCalibration = require("libs.hgss.src.script.tasks.MovementCalibration")
  local durationTicks
  if
    kind == "walk"
    or kind == "walk_in_place"
    or kind == "jump"
    or kind == "face"
    or kind == "delay"
    or kind == "emote"
    or kind == "gesture"
  then
    durationTicks = MovementCalibration.actionTicks(action)
  else
    error("unsupported scripted action " .. tostring(kind))
  end
  local fromState = {
    fieldX = self.fieldX,
    fieldZ = self.fieldZ,
    localX = self.localX,
    localZ = self.localZ,
    worldX = self.worldX,
    worldY = self.worldY,
    worldZ = self.worldZ,
    surfaceId = self.surfaceId,
  }
  local toState
  if kind == "walk" or kind == "jump" then
    local direction = assert(action.direction, "direction required for " .. kind)
    local bypass = true
    local dest = self:_resolveStep(direction, bypass)
    if kind == "jump" and action.distance == "zero" then
      dest = {
        fieldX = self.fieldX,
        fieldZ = self.fieldZ,
        localX = self.localX,
        localZ = self.localZ,
        worldX = self.worldX,
        worldY = self.worldY,
        worldZ = self.worldZ,
        surfaceId = self.surfaceId,
      }
    end
    if not dest then
      error("scripted destination surface missing for " .. tostring(direction))
    end
    toState = dest
  else
    toState = {
      fieldX = self.fieldX,
      fieldZ = self.fieldZ,
      localX = self.localX,
      localZ = self.localZ,
      worldX = self.worldX,
      worldY = self.worldY,
      worldZ = self.worldZ,
      surfaceId = self.surfaceId,
    }
  end
  self.from = fromState
  self.to = toState
  self.motion = "walking"
  self.progressTicks = 0
  self.durationTicks = durationTicks
  self._scriptedMotion = {
    action = kind,
    direction = action.direction,
    distance = action.distance,
    speed = action.speed,
    gestureName = action.name,
    durationTicks = durationTicks,
    progressTicks = 0,
    startGesturePose = self._gesturePose,
    startGestureTick = self._gestureTick,
    startGestureOffsetY = self._gestureOffsetY,
  }
  if kind == "gesture" then
    self._gesturePose = nil
    self._gestureTick = nil
    self._gestureOffsetY = 0
  elseif kind == "walk" or kind == "walk_in_place" or kind == "jump" then
    self._gesturePose = nil
    self._gestureTick = nil
    self._gestureOffsetY = 0
  elseif kind == "face" then
    self._gesturePose = nil
    self._gestureTick = nil
    self._gestureOffsetY = 0
  end
  -- Snapshot previousWorld at begin so first render interpolates from source.
  self.previousWorldX, self.previousWorldY, self.previousWorldZ = fromState.worldX, fromState.worldY, fromState.worldZ
  if kind == "walk" then
    self:_publishMovementStart(
      assert(action.direction, "direction required for walk"),
      assert(action.speed, "speed required for walk")
    )
  end
end

function FieldPlayer:advanceScriptedAction(progressTicks, durationTicks)
  local m = self._scriptedMotion
  if not m then
    return
  end
  m.progressTicks = progressTicks
  m.durationTicks = durationTicks
  local t = durationTicks > 0 and (progressTicks / durationTicks) or 1
  self.previousWorldX, self.previousWorldY, self.previousWorldZ = self.worldX, self.worldY, self.worldZ
  if m.action == "walk" then
    assert(self.from and self.to, "walking endpoints required")
    self.worldX = self.from.worldX + (self.to.worldX - self.from.worldX) * t
    self.worldZ = self.from.worldZ + (self.to.worldZ - self.from.worldZ) * t
    if self.from.surfaceId == self.to.surfaceId then
      local localX = self.from.localX + FieldCoordinates.TILE_CENTER_OFFSET + (self.to.localX - self.from.localX) * t
      local localZ = self.from.localZ + FieldCoordinates.TILE_CENTER_OFFSET + (self.to.localZ - self.from.localZ) * t
      self.worldY = self.currentMap.terrain:sampleHeight(self.to.surfaceId, localX, localZ)
    else
      self.worldY = self.from.worldY + (self.to.worldY - self.from.worldY) * t
    end
  elseif m.action == "jump" then
    assert(self.from and self.to, "jump endpoints required")
    self.worldX = self.from.worldX + (self.to.worldX - self.from.worldX) * t
    self.worldZ = self.from.worldZ + (self.to.worldZ - self.from.worldZ) * t
    local baseY = self.from.worldY + (self.to.worldY - self.from.worldY) * t
    local MovementCalibration = require("libs.hgss.src.script.tasks.MovementCalibration")
    local h = MovementCalibration.JUMP_HEIGHTS[m.distance] or 0
    local arc = 4 * h * t * (1 - t)
    self.worldY = baseY + arc
  elseif m.action == "walk_in_place" or m.action == "delay" or m.action == "emote" or m.action == "gesture" then
    self.worldX = self.from.worldX
    self.worldY = self.from.worldY
    self.worldZ = self.from.worldZ
  end
  if m.action == "gesture" then
    local MovementCalibration = require("libs.hgss.src.script.tasks.MovementCalibration")
    local presentation = MovementCalibration.gesturePresentationAt(m.gestureName, progressTicks, durationTicks)
    self._gesturePose = presentation.pose
    self._gestureTick = presentation.poseTick
    self._gestureOffsetY = presentation.offsetY
  end
  self.progressTicks = progressTicks
  self.durationTicks = durationTicks
end

function FieldPlayer:commitScriptedAction()
  local m = self._scriptedMotion
  if not m then
    return
  end
  if self.to then
    local moved = self.to.fieldX ~= self.fieldX or self.to.fieldZ ~= self.fieldZ
    self.fieldX, self.fieldZ = self.to.fieldX, self.to.fieldZ
    self.localX, self.localZ = self.to.localX, self.to.localZ
    self.worldX, self.worldY, self.worldZ = self.to.worldX, self.to.worldY, self.to.worldZ
    self.surfaceId = self.to.surfaceId
    if moved then
      self:_commitTile("scripted")
    end
  end
  if m.action == "gesture" then
    local MovementCalibration = require("libs.hgss.src.script.tasks.MovementCalibration")
    local held = MovementCalibration.gesturePresentationAfterCommit(m.gestureName, m.durationTicks)
    self._gesturePose = held.pose
    self._gestureTick = held.poseTick
    self._gestureOffsetY = held.offsetY
  end
  self.motion = "idle"
  self.progressTicks = 0
  self.from, self.to = nil, nil
  self._scriptedMotion = nil
  self.previousWorldX, self.previousWorldY, self.previousWorldZ = self.worldX, self.worldY, self.worldZ
end

function FieldPlayer:cancelScriptedMovement()
  local m = self._scriptedMotion
  if m and self.from then
    self.worldX, self.worldY, self.worldZ = self.from.worldX, self.from.worldY, self.from.worldZ
  end
  if m then
    self._gesturePose = m.startGesturePose
    self._gestureTick = m.startGestureTick
    self._gestureOffsetY = m.startGestureOffsetY or 0
  end
  self.motion = "idle"
  self.progressTicks = 0
  self.from, self.to = nil, nil
  self._scriptedMotion = nil
  self.previousWorldX, self.previousWorldY, self.previousWorldZ = self.worldX, self.worldY, self.worldZ
end

function FieldPlayer:presentationState()
  local scripted = self._scriptedMotion
  local locomotionActive
  if scripted ~= nil then
    local action = scripted.action
    locomotionActive = action == "walk" or action == "walk_in_place" or action == "jump"
  else
    locomotionActive = self.motion == "walking" or self.motion == "turning" or self.motion == "jumping"
  end
  return {
    locomotionActive = locomotionActive,
    gesturePose = self._gesturePose,
    gestureTick = self._gestureTick,
    gestureOffsetY = self._gestureOffsetY,
  }
end

function FieldPlayer:isScriptedMoving()
  return self._scriptedMotion ~= nil and self.motion == "walking"
end

-- Collision facts expose both sides of the end-of-step movement model without
-- exposing the player's mutable internals to the actor manager.
---@return table[]
function FieldPlayer:collisionCandidates()
  local current = {
    fieldX = self.fieldX,
    fieldZ = self.fieldZ,
    surfaceId = self.surfaceId,
    cellKey = self.committedSourceCellKey,
    sourceSurfaceId = self.committedSourceSurfaceId,
  }
  local candidates = { current }
  if self.to ~= nil and (self.motion == "walking" or self.motion == "jumping") then
    candidates[#candidates + 1] = {
      fieldX = self.to.fieldX,
      fieldZ = self.to.fieldZ,
      surfaceId = self.to.surfaceId,
      cellKey = self.to.sourceCellKey,
      sourceSurfaceId = self.to.sourceSurfaceId,
    }
  end
  return candidates
end

-- Rebind the player to a newly committed physical coverage window. Global tile
-- coordinates remain authoritative; only local frame and composite surface id
-- change. Current and previous render positions receive the same frame delta.
function FieldPlayer:rebindCoverage(runtimeMap, deltaX, deltaY, deltaZ, cellKey, sourceSurfaceId)
  assert(runtimeMap and runtimeMap.coordinateOrigin, "coverage runtime map required")
  assert(
    type(deltaX) == "number" and type(deltaY) == "number" and type(deltaZ) == "number",
    "coverage rebase delta required"
  )
  assert(cellKey ~= nil and sourceSurfaceId ~= nil, "player source surface identity required")
  local point = projectPoint(runtimeMap, self.fieldX, self.fieldZ, cellKey, sourceSurfaceId)
  self.currentMap = runtimeMap
  self.resolver = SurfaceResolver.new(runtimeMap.terrain)
  local projectedLocalX, projectedLocalZ = point.localX, point.localZ
  assert(projectedLocalX % 1 == 0 and projectedLocalZ % 1 == 0, "projected local coordinates must be integers")
  ---@cast projectedLocalX integer
  ---@cast projectedLocalZ integer
  self.localX, self.localZ = projectedLocalX, projectedLocalZ
  self.surfaceId = point.surfaceId
  self.worldX = self.worldX + deltaX
  self.worldY = self.worldY + deltaY
  self.worldZ = self.worldZ + deltaZ
  self.previousWorldX = self.previousWorldX + deltaX
  self.previousWorldY = self.previousWorldY + deltaY
  self.previousWorldZ = self.previousWorldZ + deltaZ
  self.committedSourceCellKey = cellKey
  self.committedSourceSurfaceId = sourceSurfaceId
end

function FieldPlayer:status()
  local plate = assert(self.currentMap.terrain:plate(self.surfaceId), "player surface missing")
  return {
    fieldX = self.fieldX,
    fieldZ = self.fieldZ,
    localX = self.localX,
    localZ = self.localZ,
    worldY = self.worldY,
    surfaceId = self.surfaceId,
    surfaceNormal = { x = plate.normal.x, y = plate.normal.y, z = plate.normal.z },
    slopeClass = plate.slopeClass,
    destinationSurfaceId = self.to and self.to.surfaceId or nil,
    facing = self.facing,
    motion = self.motion,
    transitionKind = self.transitionKind,
    transitionProgress = self.transitionProgress,
  }
end

return FieldPlayer
