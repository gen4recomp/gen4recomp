-- Owns the object actors of every runtime map the session currently holds, plus
-- the occupancy index they contribute to collision. Visibility follows
-- pret/pokeheartgold's rule that an object exists only while its event flag is
-- clear (`src/map_object.c`), so this manager subscribes to FieldEventState and
-- applies queued changes on one fixed-tick boundary: an actor never draws while
-- collision considers it absent, or the reverse.
--
-- It is not the player's movement authority and it never draws: `drawRecords`
-- returns presentation-neutral values for the renderer to consume.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local FieldGrid = require("libs.hgss.src.world.FieldGrid")
local FieldObjectActor = require("libs.hgss.src.actors.FieldObjectActor")
local FieldActorAutonomy = require("libs.hgss.src.actors.FieldActorAutonomy")
local FieldObjectMovement = require("libs.assets.src.field.FieldObjectMovement")
local ScriptRng = require("libs.hgss.src.script.ScriptRng")
local MovementCalibration = require("libs.hgss.src.script.tasks.MovementCalibration")
local SurfaceResolver = require("libs.hgss.src.world.SurfaceResolver")
local FieldActorOccupancy = require("libs.hgss.src.actors.FieldActorOccupancy")
local FieldActorPersistence = require("libs.hgss.src.actors.FieldActorPersistence")
local FieldActorStore = require("libs.hgss.src.actors.FieldActorStore")

-- Pinned HGSS special object ids: the field camera target and the walking
-- partner (the object table pins these ids; see
-- pret/pokeheartgold src/field_system.c FieldSystem_CameraTarget).
local CAMERA_TARGET_OBJECT_ID = 241
local PARTNER_OBJECT_ID = 253
-- The walking partner actor id. Map objects use map-scoped identities, but
-- the dynamic partner keeps one stable id across maps so scripts and the
-- interaction resolver never chase a renamed actor after a transition.
local PARTNER_ACTOR_ID = "field:partner"
local AUTONOMOUS_STEP_TICKS = assert(MovementCalibration.SPEED_TICKS.normal)

---@class FieldActorAssets
---@field knows fun(self: FieldActorAssets, spriteId: integer): boolean
---@field acquire fun(self: FieldActorAssets, spriteId: integer): FieldActorAsset
---@field release fun(self: FieldActorAssets, spriteId: integer)
---@field dispose fun(self: FieldActorAssets)?

---@class FieldActorAsset
---@field spriteId integer
---@field visual table<string, unknown>
---@field references integer
-- The provider owns the acquired visual; the manager only holds its reference
-- through the provider's acquire/release pair.

---@class FieldActorManager.VariableSprites
---@field first integer
---@field last integer
---@field variableBase integer

---@class FieldActorEvent
---@field index integer
---@field objectEventId integer
---@field spriteId integer
---@field movementType string
---@field type integer
---@field eventFlag integer
---@field scriptId integer
---@field facingDirectionRaw integer
---@field facingDirection string
---@field x integer
---@field z integer
---@field y integer
---@field xRange integer
---@field yRange integer
---@field solid boolean?

---@class FieldActorEventCollections
---@field objects FieldActorEvent[]

---@class FieldActorFieldData
---@field events FieldActorEventCollections

---@class FieldActorStepContext
---@field autonomousLocked boolean?
---@field actorLocked (fun(actorId: string): boolean)?
---@field player table<string, unknown>?
---@field playerCandidates FieldOccupancyCandidate[]?

---@class FieldActorSurfaceSample
---@field surfaceId integer
---@field worldY number

---@class FieldActorSurfaceOptions
---@field localX number
---@field localZ number
---@field currentY number
---@field currentSurfaceId integer?

---@class FieldActorStateChange
---@field kind "flag"|"var"
---@field id integer
---@field oldValue boolean|integer
---@field newValue boolean|integer
---@field tick integer

---@class FieldActorFlagChange: FieldActorStateChange
---@field kind "flag"
---@field oldValue boolean
---@field newValue boolean

---@class FieldActorManager
---@field assets FieldActorAssets
---@field persistence FieldActorPersistence
---@field variableSprites FieldActorManager.VariableSprites
---@field variableVarBase integer
---@field maps table<integer, FieldActorManager.Entry>
---@field eventState FieldEventState?
---@field unsubscribe fun()?
---@field pendingFlags FieldActorFlagChange[]
---@field currentMapId integer|nil
---@field _visualRevision integer
---@field _drawRecords FieldActorManager.DrawRecord[]
---@field _drawRecordByActorId table<string, FieldActorManager.DrawRecord>
---@field autonomy FieldActorAutonomy
---@field step fun(self: FieldActorManager, tick: integer, context: FieldActorStepContext?)
---@field _resolveSpriteId fun(self: FieldActorManager, event: FieldActorEvent, eventState: FieldEventState?): integer
---@field _acquireVisual fun(self: FieldActorManager, spriteId: integer, actorId: string): FieldActorAsset
---@field _instantiate fun(self: FieldActorManager, entry: FieldActorManager.Entry, event: FieldActorEvent, eventState: FieldEventState?): FieldActorManager.Actor
---@field _destroy fun(self: FieldActorManager, entry: FieldActorManager.Entry, actor: FieldActorManager.Actor)
---@field leaveMap fun(self: FieldActorManager, mapId: integer)
---@field enterMap fun(self: FieldActorManager, runtimeMap: RuntimeFieldMap, eventState: FieldEventState, restoredObjects: table<string, unknown>?)
---@field dispose fun(self: FieldActorManager)
---@field visualRevision fun(self: FieldActorManager): integer
---@field collectSpriteIds fun(self: FieldActorManager, out: table<integer, boolean>)
---@field drawRecords fun(self: FieldActorManager, alpha: number?): FieldActorManager.DrawRecord[]
---@field reconcilePhysicalWorld fun(self: FieldActorManager)
---@field onEventStateChanged fun(self: FieldActorManager, change: FieldActorStateChange)
---@field syncEventStateChanges fun(self: FieldActorManager)
---@field _applyFlag fun(self: FieldActorManager, change: FieldActorFlagChange)
---@field getById fun(self: FieldActorManager, actorId: string): FieldActorManager.Actor?
---@field getActor fun(self: FieldActorManager, actorId: string): FieldActorManager.Actor?
---@field getPosition fun(self: FieldActorManager, actorId: string): FieldActorManager.ActorPosition?
---@field getFacing fun(self: FieldActorManager, actorId: string): FieldDirection?
---@field setFacing fun(self: FieldActorManager, actorId: string, direction: FieldDirection)
---@field show fun(self: FieldActorManager, actorId: string)
---@field hide fun(self: FieldActorManager, actorId: string)
---@field setMovementType fun(self: FieldActorManager, actorId: string, movementType: string)
---@field setAnimationPaused fun(self: FieldActorManager, actorId: string, paused: boolean)
---@field setPresentationOffset fun(self: FieldActorManager, actorId: string, offset: { x: number, y: number, z: number })
---@field clearPresentationOffset fun(self: FieldActorManager, actorId: string)
---@field isVisible fun(self: FieldActorManager, actorId: string): boolean
---@field numericId fun(self: FieldActorManager, actorId: string): integer?
---@field cameraTargetId fun(self: FieldActorManager): string?
---@field partnerId fun(self: FieldActorManager): string?
---@field _resolveScriptedDestination fun(self: FieldActorManager, actor: FieldActorManager.Actor, direction: FieldDirection?, distance: string?): table<string, unknown>
---@field _resolveTrajectoryDestination fun(self: FieldActorManager, actor: FieldActorManager.Actor, deltaX: integer, deltaZ: integer, surfaceBandDelta: integer): table<string, unknown>
---@field installPartner fun(self: FieldActorManager, spec: FieldActorManager.PartnerSpec): string?
---@field updatePartner fun(self: FieldActorManager, spec: FieldActorManager.PartnerSpec): string?
---@field clearPartner fun(self: FieldActorManager): string?
---@field setPosition fun(self: FieldActorManager, actorId: string, position: FieldActorManager.Position, options: { scripted?: boolean }?)
---@field getAt fun(self: FieldActorManager, mapId: integer, candidate: FieldOccupancyCandidate): FieldActorManager.Actor?
---@field probeAt fun(self: FieldActorManager, runtimeMap: RuntimeFieldMap, eventState: FieldEventState, candidate: FieldOccupancyCandidate): FieldActorManager.ProbeResult?
---@field actorsOf fun(self: FieldActorManager, mapId: integer): FieldActorManager.Actor[]
---@field actorIdForMapIndex fun(self: FieldActorManager, index: integer): string?
---@field beginScriptedAction fun(self: FieldActorManager, actorId: string, action: table<string, unknown>)
---@field advanceScriptedAction fun(self: FieldActorManager, actorId: string, progressTicks: integer, durationTicks: integer)
---@field commitScriptedAction fun(self: FieldActorManager, actorId: string)
---@field cancelScriptedMovement fun(self: FieldActorManager, actorId: string)
---@field isScriptedMoving fun(self: FieldActorManager, actorId: string): boolean
---@field _advanceAutonomousAction fun(self: FieldActorManager, entry: FieldActorManager.Entry, actor: FieldActorManager.Actor, action: table<string, unknown>)
---@field _beginAutonomousAction fun(self: FieldActorManager, entry: FieldActorManager.Entry, actor: FieldActorManager.Actor, direction: FieldDirection, context: table<string, unknown>): boolean
---@field getCollisionAt fun(self: FieldActorManager, mapId: integer, candidate: FieldOccupancyCandidate): FieldActorManager.Actor?
---@field isPausable fun(self: FieldActorManager, actorId: string): boolean
---@field allPausable fun(self: FieldActorManager): boolean
---@field _restoreEntry fun(self: FieldActorManager, entry: FieldActorManager.Entry, snapshot: table<string, unknown>?)
---@field captureObjects fun(self: FieldActorManager): table<string, unknown>
---@field new fun(opts: FieldActorManagerOptions): FieldActorManager
---@field isPlacementRejection fun(err: unknown): boolean
---@class FieldActorManager.Actor: FieldObjectActor
---@field movementType string
---@field animationPaused boolean?

---@class FieldActorManager.Entry
---@field runtimeMap RuntimeFieldMap
---@field store FieldActorStore
---@field occupancy FieldActorOccupancy
---@field autonomousActions table<string, table<string, unknown>>
---@field autonomousPresentationCarry table<string, boolean>

---@class FieldActorManager.Position
---@field fieldX integer
---@field fieldZ integer
---@field worldY number?

---@class FieldActorResolvedPosition
---@field fieldX integer
---@field fieldZ integer
---@field worldX number?
---@field worldY number?
---@field worldZ number?
---@field surfaceId integer?
---@field cellKey string?
---@field sourceSurfaceId integer?
---@field resident boolean

---@class FieldActorManager.ActorPosition
---@field fieldX integer
---@field fieldZ integer
---@field worldY number?

---@class FieldActorManager.DrawRecord
---@field actorId string
---@field spriteId integer
---@field world { x: number, y: number, z: number }
---@field facing FieldDirection
---@field pose string
---@field poseTick integer
---@field gesturePose string?
---@field gestureTick integer?
---@field activeEmoteKind string?
---@field visible boolean

-- The physical-projection input for one action endpoint: logical field
-- coordinates plus the surface/height context the terrain path resolves.
-- Committed actors satisfy this directly; action destinations supply the
-- same shape from the stored motion transaction.
---@class FieldActorManager.EndpointPoint
---@field fieldX integer
---@field fieldZ integer
---@field surfaceId integer?
---@field cellKey string?
---@field sourceSurfaceId integer?
---@field worldY number?
---@field sourceEvent table<string, unknown>
---@field actorId string
local FieldActorManager = {}
---@cast FieldActorManager FieldActorManager
FieldActorManager.__index = FieldActorManager

-- MapObject_SetPositionVectorFromObjectEvent uses FX32 source coordinates;
-- object-event Y is expressed in 16 model units per runtime world tile.
local FX32_ONE = 4096
local SOURCE_MODEL_UNITS_PER_TILE = 16
local OBJECT_EVENT_Y_UNITS = SOURCE_MODEL_UNITS_PER_TILE * FX32_ONE

-- MapObject_GetPositionVectorYCoordUInt shifts the source model Y by /8 and
-- then converts it to FX32 tiles. Runtime world Y is already normalized to
-- 16 model units per tile, so two source bands fit in one runtime tile.
local function sourcePositionYBand(worldY)
  local scaled = worldY * 2
  return scaled < 0 and math.ceil(scaled) or math.floor(scaled)
end

-- The terrain-surface failure codes an actor construction can recover from,
-- mapped to the actor-scoped codes the script world observes. A structured
-- error of any other kind propagates unchanged rather than being re-labelled.
local SURFACE_ERROR_CODES = {
  [FieldErrors.TERRAIN_SURFACE_NOT_FOUND] = FieldErrors.ACTOR_SURFACE_MISSING,
  [FieldErrors.TERRAIN_SURFACE_AMBIGUOUS] = FieldErrors.ACTOR_SURFACE_AMBIGUOUS,
  [FieldErrors.TERRAIN_SURFACE_DISCONNECTED] = FieldErrors.ACTOR_SURFACE_AMBIGUOUS,
}

---@class FieldActorManagerOptions
---@field assets FieldActorAssets
---@field policy { variableSprites: FieldActorManager.VariableSprites }
---@field autonomyRng table<string, unknown>?
---@field autonomySeed string?

-- opts.assets: a FieldActorAssetProvider-shaped acquire/release/knows owner.
-- opts.policy: the generated actor index's runtime block
-- ({ variableSprites = { first, last, variableBase } }), so no decomp-derived
-- constant is inlined here.
---@param opts FieldActorManagerOptions
---@return FieldActorManager
function FieldActorManager.new(opts)
  assert(type(opts) == "table" and opts.assets, "FieldActorManager requires an asset provider")
  local policy = opts.policy
  assert(type(policy) == "table" and policy.variableSprites, "FieldActorManager requires a variable-sprite policy")
  local variableSprites = policy.variableSprites
  ---@cast variableSprites FieldActorManager.VariableSprites
  local manager = setmetatable({
    assets = opts.assets,
    persistence = FieldActorPersistence.new(),
    variableSprites = variableSprites,
    variableVarBase = variableSprites.variableBase,
    maps = {},
    eventState = nil,
    unsubscribe = nil,
    pendingFlags = {},
    currentMapId = nil,
    _visualRevision = 0,
    _drawRecords = {},
    _drawRecordByActorId = {},
    autonomy = FieldActorAutonomy.new({
      rng = opts.autonomyRng or ScriptRng.new(opts.autonomySeed or "field:autonomy"),
      profiles = FieldObjectMovement,
    }),
  }, FieldActorManager)
  ---@cast manager FieldActorManager
  return manager
end

---@param plate table<string, unknown>
---@return string?, integer?
local function sourceIdentityFromPlate(plate)
  if plate.cellKey == nil and plate.sourceSurfaceId == nil then
    return nil, nil
  end
  assert(plate.cellKey ~= nil and plate.sourceSurfaceId ~= nil, "terrain source surface identity is incomplete")
  return plate.cellKey, plate.sourceSurfaceId
end

local function stableSurfaceIdentity(runtimeMap, candidate)
  assert(type(candidate) == "table", "occupancy candidate is required")
  if candidate.sourceSurfaceId ~= nil then
    assert(candidate.cellKey ~= nil, "stable source surface id requires a cell key")
    return "source", candidate.cellKey, candidate.sourceSurfaceId
  end
  local surfaceId = assert(candidate.surfaceId, "occupancy candidate requires a surface identity")
  local plate = assert(runtimeMap.terrain:plate(surfaceId), "occupancy candidate surface id is unknown")
  local cellKey, sourceSurfaceId = sourceIdentityFromPlate(plate)
  if cellKey ~= nil then
    return "source", cellKey, sourceSurfaceId
  end
  return "local", surfaceId, nil
end

local function sameSurfaceIdentity(leftKind, leftFirst, leftSecond, rightKind, rightFirst, rightSecond)
  return leftKind == rightKind and leftFirst == rightFirst and leftSecond == rightSecond
end

---@param actor FieldActorManager.Actor
---@return FieldOccupancyCandidate
local function candidateForActor(actor)
  local cellKey = actor.cellKey
  local sourceSurfaceId = actor.sourceSurfaceId
  return {
    fieldX = actor.fieldX,
    fieldZ = actor.fieldZ,
    surfaceId = actor.surfaceId,
    cellKey = cellKey and sourceSurfaceId and cellKey or nil,
    sourceSurfaceId = cellKey and sourceSurfaceId or nil,
  }
end

local function managerSlot(entry, actor)
  return entry.store:managerSlot(actor)
end
local function assignManagerSlot(entry, actor, requestedSlot)
  return entry.store:assignManagerSlot(actor, requestedSlot)
end

local function releaseManagerSlot(entry, actor)
  entry.store:releaseManagerSlot(actor)
end

local function occupancyAdd(entry, actor, candidate)
  entry.occupancy:claim(actor, candidate or {
    fieldX = actor.fieldX,
    fieldZ = actor.fieldZ,
    surfaceId = actor.surfaceId,
    cellKey = actor.cellKey,
    sourceSurfaceId = actor.sourceSurfaceId,
  })
end

local function actorsByManagerSlot(entry)
  return entry.store:actorsByManagerSlot()
end

local function occupancyRemove(entry, key, actor)
  entry.occupancy:releaseByKey(actor, key)
end

---@param entry FieldActorManager.Entry
---@param actor FieldActorManager.Actor
---@param position FieldActorResolvedPosition
local function publishResolvedPosition(entry, actor, position)
  local oldKey
  if actor.resident and actor.solid then
    oldKey = entry.occupancy:key(candidateForActor(actor))
  end
  local newKey
  if position.resident and actor.solid then
    newKey = entry.occupancy:key(position --[[@as FieldOccupancyCandidate]])
  end
  if oldKey and newKey and oldKey == newKey then
    if not entry.occupancy:containsByKey(oldKey, actor) then
      occupancyAdd(entry, actor)
    end
  else
    if oldKey then
      occupancyRemove(entry, oldKey, actor)
    end
    if newKey then
      occupancyAdd(entry, actor, position --[[@as FieldOccupancyCandidate]])
    end
  end
  actor:setPosition(position)
end

local function isResident(runtimeMap, fieldX, fieldZ)
  return not runtimeMap.coverage or runtimeMap.coverage:containsGlobal(fieldX, fieldZ)
end

local function cellKeyFor(fieldX, fieldZ)
  return string.format("%d:%d", math.floor(fieldX / 32), math.floor(fieldZ / 32))
end

---@param runtimeMap RuntimeFieldMap
---@param fieldX integer
---@param fieldZ integer
---@param sourceY number
---@param actorId string
---@return FieldActorSurfaceSample
local function resolveSurfaceAt(runtimeMap, fieldX, fieldZ, sourceY, actorId)
  local ok, result = pcall(function()
    local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, fieldX, fieldZ)
    -- Terrain is sampled at the tile centre, as the player and camera do.
    local surfaceOptions = {
      localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
      localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
      currentY = sourceY / OBJECT_EVENT_Y_UNITS,
    } ---@type FieldActorSurfaceOptions
    return SurfaceResolver.new(runtimeMap.terrain):resolve(surfaceOptions) --[[@as FieldActorSurfaceSample]]
  end)
  if ok then
    return result --[[@as FieldActorSurfaceSample]]
  end
  if not Errors.is(result) then
    error(result)
  end
  -- Only expected surface-resolution conditions are actor-surface failures; a
  -- structured error of any other kind (e.g. out-of-coverage coordinates)
  -- propagates unchanged rather than being re-labelled as a missing surface.
  local structuredError = result --[[@as Errors.Error]]
  local code = SURFACE_ERROR_CODES[structuredError.code]
  if not code then
    error(structuredError)
  end
  Errors.raise(
    code,
    "actor " .. actorId .. " has no single terrain surface: " .. structuredError.message,
    { actorId = actorId, fieldX = fieldX, fieldZ = fieldZ, sourceY = sourceY, cause = structuredError.code }
  )
  error("unreachable after actor surface error")
end

local function resolveSurface(runtimeMap, event, actorId)
  return resolveSurfaceAt(runtimeMap, event.x, event.z, event.y, actorId)
end

local function currentSurfaceFor(runtimeMap, cellKey, sourceSurfaceId)
  if runtimeMap.fieldRegion and runtimeMap.fieldRegion.sourceSurface then
    return runtimeMap.fieldRegion:sourceSurface(cellKey, sourceSurfaceId)
  end
  return nil
end

-- Projects one action endpoint into the current physical frame. Resident
-- points reuse the committed terrain/source-surface path; points outside
-- coverage rebase X/Z from the new origin and keep their known height and
-- source identity with resident=false.
---@param runtimeMap RuntimeFieldMap
---@param point FieldActorManager.Actor|FieldActorManager.EndpointPoint
---@return FieldObjectActor.ActionEndpoint
local function projectEndpoint(runtimeMap, point)
  local fieldX, fieldZ = point.fieldX, point.fieldZ
  if not isResident(runtimeMap, fieldX, fieldZ) then
    local origin = assert(runtimeMap.coordinateOrigin, "runtime map coordinate origin required")
    local worldX, worldZ = FieldGrid.tileCenterToWorld(fieldX - origin.x, fieldZ - origin.z)
    return {
      fieldX = fieldX,
      fieldZ = fieldZ,
      surfaceId = point.surfaceId,
      cellKey = point.cellKey,
      sourceSurfaceId = point.sourceSurfaceId,
      worldX = worldX,
      worldY = point.worldY,
      worldZ = worldZ,
      resident = false,
    }
  end
  local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, fieldX, fieldZ)
  local centerX, centerZ = localX + FieldCoordinates.TILE_CENTER_OFFSET, localZ + FieldCoordinates.TILE_CENTER_OFFSET
  local surfaceId = point.surfaceId
  if point.cellKey and point.sourceSurfaceId and runtimeMap.fieldRegion and runtimeMap.fieldRegion.sourceSurface then
    surfaceId = assert(
      currentSurfaceFor(runtimeMap, point.cellKey, point.sourceSurfaceId),
      "actor source surface is absent from coverage"
    )
  end
  if surfaceId == nil or not runtimeMap.terrain:contains(surfaceId, centerX, centerZ) then
    local sample = resolveSurfaceAt(runtimeMap, fieldX, fieldZ, point.sourceEvent.y, point.actorId)
    surfaceId = sample.surfaceId
  end
  local plate = assert(runtimeMap.terrain:plate(surfaceId), "actor projected surface is missing")
  local cellKey
  local sourceSurfaceId
  if point.sourceSurfaceId ~= nil then
    assert(point.cellKey ~= nil, "actor source surface id requires a cell key")
    cellKey = point.cellKey
    sourceSurfaceId = point.sourceSurfaceId
  else
    local plateCellKey, plateSourceSurfaceId = sourceIdentityFromPlate(plate)
    cellKey = point.cellKey or plateCellKey
    sourceSurfaceId = plateSourceSurfaceId
  end
  local worldY = runtimeMap.terrain:sampleHeight(surfaceId, centerX, centerZ)
  local world = FieldCoordinates.fieldToWorld(runtimeMap, fieldX, fieldZ, worldY)
  return {
    fieldX = fieldX,
    fieldZ = fieldZ,
    surfaceId = surfaceId,
    cellKey = cellKey or cellKeyFor(fieldX, fieldZ),
    sourceSurfaceId = sourceSurfaceId,
    worldX = world.x,
    worldY = world.y,
    worldZ = world.z,
    resident = true,
  }
end

local function projectionFor(runtimeMap, actor)
  return projectEndpoint(runtimeMap, actor)
end

-- The runtime sprite of an object event. FieldSystem_ResolveObjectSpriteID
-- redirects the variable range through the VAR_OBJ_* save variables before the
-- graphics lookup, once at object creation (pret/pokeheartgold src/map_object.c),
-- so this mirrors that call. The variables default to 0, the hero graphic, so a
-- variable actor exists even when no script has written one.
---@param event FieldActorEvent
---@param eventState FieldEventState?
---@return integer
---@param self FieldActorManager
function FieldActorManager:_resolveSpriteId(event, eventState)
  local sprites = self.variableSprites
  if event.spriteId < sprites.first or event.spriteId > sprites.last then
    return event.spriteId
  end
  local state = eventState or self.eventState
  assert(state, "variable sprite resolution requires an event state")
  return state:getVar(self.variableVarBase + (event.spriteId - sprites.first))
end

---@param self FieldActorManager
---@param spriteId integer
---@param actorId string
---@return FieldActorAsset
function FieldActorManager:_acquireVisual(spriteId, actorId)
  if not self.assets:knows(spriteId) then
    Errors.raise(
      FieldErrors.ACTOR_VISUAL_MISSING,
      "spriteId " .. spriteId .. " for " .. actorId .. " is not in the compiled actor set",
      { actorId = actorId, spriteId = spriteId }
    )
  end
  return self.assets:acquire(spriteId)
end

---@param self FieldActorManager
---@param entry FieldActorManager.Entry
---@param event FieldActorEvent
---@param eventState FieldEventState?
---@return FieldActorManager.Actor
function FieldActorManager:_instantiate(entry, event, eventState)
  local runtimeMap = entry.runtimeMap
  local actorId = FieldObjectActor.actorId(runtimeMap.mapId, event.objectEventId)
  if entry.store:getActor(actorId) then
    Errors.raise(
      FieldErrors.ACTOR_DUPLICATE_ID,
      "map " .. runtimeMap.mapId .. " declares object event " .. event.objectEventId .. " more than once",
      { actorId = actorId, mapId = runtimeMap.mapId, objectEventId = event.objectEventId }
    )
  end
  local resident = isResident(runtimeMap, event.x, event.z)
  local surface = resident and resolveSurface(runtimeMap, event, actorId) or nil
  local world = surface and FieldCoordinates.fieldToWorld(runtimeMap, event.x, event.z, surface.worldY) or nil
  local plate = surface and runtimeMap.terrain:plate(surface.surfaceId) or nil
  local plateCellKey, plateSourceSurfaceId
  if plate then
    plateCellKey, plateSourceSurfaceId = sourceIdentityFromPlate(plate)
  end
  local spriteId = self:_resolveSpriteId(event, eventState)
  local asset = self:_acquireVisual(spriteId, actorId)

  -- Local ownership: the visual is acquired for this construction only, so any
  -- failure between acquisition and completed insertion releases it before the
  -- error propagates. Solid actors (the default; an event may opt out) take the
  -- occupancy cell, and two solid actors on one cell are a conflict.
  local actor ---@type FieldActorManager.Actor
  local visual
  local idlePresentation
  local autonomyAttached = false
  local ok, err = pcall(function()
    visual = assert(asset.visual, "field actor visual is required")
    idlePresentation = assert(visual.idlePresentation, "field actor idle presentation is required")
    actor = FieldObjectActor.new({
      mapId = runtimeMap.mapId,
      sourceEvent = event,
      spriteId = spriteId,
      solid = event.solid,
      fieldX = event.x,
      fieldZ = event.z,
      cellKey = plateCellKey or (resident and cellKeyFor(event.x, event.z) or nil),
      sourceSurfaceId = plateSourceSurfaceId,
      surfaceId = surface and surface.surfaceId or nil,
      worldX = world and world.x or nil,
      worldY = world and world.y or nil,
      worldZ = world and world.z or nil,
      resident = resident,
      visual = visual,
      idlePresentation = idlePresentation,
    }) --[[@as FieldActorManager.Actor]]

    assignManagerSlot(entry, actor)
    if actor.resident then
      local key = entry.occupancy:key(candidateForActor(actor))
      local occupant = entry.occupancy:winnerByKey(key)
      if actor.solid and occupant then
        Errors.raise(
          FieldErrors.ACTOR_OCCUPANCY_CONFLICT,
          actorId .. " and " .. occupant.actorId .. " occupy the same field cell and surface",
          {
            actorId = actorId,
            otherActorId = occupant.actorId,
            mapId = runtimeMap.mapId,
            fieldX = actor.fieldX,
            fieldZ = actor.fieldZ,
            surfaceId = actor.surfaceId,
          }
        )
      end
      if actor.solid then
        occupancyAdd(entry, actor)
      end
    end
    entry.store:addActor(actor)
    self.autonomy:attach(actorId, actor.movementType, event)
    autonomyAttached = true
    if self.maps[entry.runtimeMap.mapId] == entry then
      self._visualRevision = self._visualRevision + 1
    end
  end)
  if not ok then
    if actor then
      if actor.resident and actor.solid then
        local key = entry.occupancy:key(candidateForActor(actor))
        occupancyRemove(entry, key, actor)
      end
      if entry.store:hasManagerSlot(actor.actorId) then
        releaseManagerSlot(entry, actor)
      end
      if entry.store:getActor(actorId) then
        entry.store:removeActor(actor)
      end
    end
    if autonomyAttached then
      self.autonomy:detach(actorId)
    end
    self.assets:release(spriteId)
    error(err)
  end
  return actor
end

---@param entry FieldActorManager.Entry
---@param actor FieldActorManager.Actor
---@param self FieldActorManager
function FieldActorManager:_destroy(entry, actor)
  entry.autonomousPresentationCarry[actor.actorId] = nil
  local action = entry.autonomousActions[actor.actorId]
  if action then
    local reservation = entry.occupancy:reservationByKey(action.reservationKey)
    assert(reservation and reservation.actorId == actor.actorId, "actor reservation owner disagrees")
    entry.occupancy:cancelReservation(reservation.candidate, actor.actorId)
    entry.autonomousActions[actor.actorId] = nil
    actor:cancelAction()
  end
  self.autonomy:detach(actor.actorId)
  actor:clearFacingOverride()
  -- Only solid actors ever occupy a cell, and only the exact occupant may
  -- vacate it: a non-solid or stale actor must never erase another actor's
  -- occupancy entry by coordinate.
  if actor.resident and actor.solid then
    local key = entry.occupancy:key(candidateForActor(actor))
    occupancyRemove(entry, key, actor)
  end
  if entry.store:hasManagerSlot(actor.actorId) then
    releaseManagerSlot(entry, actor)
  end
  entry.store:removeActor(actor)
  self.assets:release(actor.spriteId)
  self._drawRecordByActorId[actor.actorId] = nil
  if self.maps[entry.runtimeMap.mapId] == entry then
    self._visualRevision = self._visualRevision + 1
  end
end

---@param manager FieldActorManager
---@param actorId string
---@return FieldActorManager.Actor
local function requireActor(manager, actorId)
  local actor = manager:getById(actorId)
  if actor ~= nil then
    return actor
  end
  Errors.raise(ScriptErrors.SCRIPT_ACTOR_NOT_FOUND, "no live actor " .. tostring(actorId), { actor = actorId })
  error("unreachable: actor lookup failure was raised")
end

---@param self FieldActorManager
---@param eventState FieldEventState
local function bindEventState(self, eventState)
  if self.eventState ~= eventState then
    local oldUnsubscribe = self.unsubscribe
    local unsubscribe = eventState:subscribe(function(change)
      local stateChange = change --[[@as FieldActorStateChange]]
      self:onEventStateChanged(stateChange)
    end)
    self.eventState = eventState
    self.unsubscribe = unsubscribe
    if oldUnsubscribe then
      oldUnsubscribe()
    end
  end
end

---@param runtimeMap RuntimeFieldMap
---@return FieldActorManager.Entry
local function newEntry(runtimeMap)
  local entry = {
    runtimeMap = runtimeMap,
    store = FieldActorStore.new(),
    autonomousActions = {},
    autonomousPresentationCarry = {},
  }
  ---@cast entry FieldActorManager.Entry
  local function managerSlotForEntry(actor)
    return managerSlot(entry, actor)
  end
  entry.occupancy = FieldActorOccupancy.new({
    runtimeMap = runtimeMap,
    managerSlot = managerSlotForEntry,
  })
  return entry
end

---@param self FieldActorManager
---@param entry FieldActorManager.Entry
local function destroyEntry(self, entry)
  while true do
    local order = entry.store:orderedActors()
    if #order == 0 then
      return
    end
    self:_destroy(entry, order[#order])
  end
end

---@param self FieldActorManager
---@param entry FieldActorManager.Entry
---@param eventState FieldEventState
local function populateEntry(self, entry, eventState)
  local runtimeMap = entry.runtimeMap
  local ok, err = pcall(function()
    -- The map loader validates the four event collections against the
    -- authoritative field-record rule, so a runtime map always carries the
    -- objects array; a missing collection here is a composition fault, never
    -- an empty map. The failure rolls the entry back like any construction
    -- failure.
    local fieldData = runtimeMap.fieldData --[[@as FieldActorFieldData]]
    local objects = fieldData.events.objects ---@type FieldActorEvent[]
    assert(type(objects) == "table", "enterMap requires the compiled object collection")
    for _, event in ipairs(objects) do
      entry.store:indexEvent(event)
      if not eventState:isFlagSet(event.eventFlag) then
        self:_instantiate(entry, event, eventState)
      end
    end
  end)
  if not ok then
    destroyEntry(self, entry)
    error(err)
  end
end

local function savedProjection(entry, actor, record)
  actor = assert(actor)
  actor.sourceEvent = assert(actor.sourceEvent)
  local runtimeMap = entry.runtimeMap
  if not isResident(runtimeMap, record.fieldX, record.fieldZ) then
    return {
      fieldX = record.fieldX,
      fieldZ = record.fieldZ,
      resident = false,
    }
  end
  local surfaceId
  local cellKey
  local sourceSurfaceId
  local worldY
  if record.cellKey ~= nil then
    surfaceId = currentSurfaceFor(runtimeMap, record.cellKey, record.sourceSurfaceId)
    if surfaceId == nil then
      Errors.raise(
        FieldErrors.ACTOR_SURFACE_MISSING,
        "saved actor " .. actor.actorId .. " source surface no longer resolves",
        { actorId = actor.actorId, cellKey = record.cellKey, sourceSurfaceId = record.sourceSurfaceId }
      )
    end
    local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, record.fieldX, record.fieldZ)
    local centerX, centerZ = localX + FieldCoordinates.TILE_CENTER_OFFSET, localZ + FieldCoordinates.TILE_CENTER_OFFSET
    if not runtimeMap.terrain:contains(surfaceId, centerX, centerZ) then
      Errors.raise(
        FieldErrors.ACTOR_SURFACE_MISSING,
        "saved actor " .. actor.actorId .. " source surface does not cover its tile",
        { actorId = actor.actorId, cellKey = record.cellKey, sourceSurfaceId = record.sourceSurfaceId }
      )
    end
    worldY = runtimeMap.terrain:sampleHeight(surfaceId, centerX, centerZ)
    cellKey = record.cellKey
    sourceSurfaceId = record.sourceSurfaceId
  else
    local sample = resolveSurfaceAt(runtimeMap, record.fieldX, record.fieldZ, actor.sourceEvent.y, actor.actorId)
    local plate = assert(runtimeMap.terrain:plate(sample.surfaceId), "saved actor surface is missing")
    surfaceId = sample.surfaceId
    worldY = sample.worldY
    cellKey, sourceSurfaceId = sourceIdentityFromPlate(plate)
  end
  local world = FieldCoordinates.fieldToWorld(runtimeMap, record.fieldX, record.fieldZ, worldY)
  return {
    fieldX = record.fieldX,
    fieldZ = record.fieldZ,
    surfaceId = surfaceId,
    cellKey = cellKey,
    sourceSurfaceId = sourceSurfaceId,
    worldX = world.x,
    worldY = world.y,
    worldZ = world.z,
    resident = true,
  }
end

local function savedDestination(entry, actor, point)
  local projection = savedProjection(entry, actor, point)
  if not projection.resident then
    Errors.raise(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "saved autonomous action is outside physical residency",
      { actorId = actor.actorId }
    )
  end
  return projection
end

function FieldActorManager:_restoreEntry(entry, snapshot)
  local function getActor(actorId)
    return entry.store:getActor(actorId)
  end
  local function projectActor(actor, record)
    return savedProjection(entry, actor, record)
  end
  local function projectDestination(actor, point)
    return savedDestination(entry, actor, point)
  end
  local staged =
    self.persistence:stageRestore(snapshot, entry.runtimeMap.mapId, getActor, projectActor, projectDestination)
  local plans = staged.plans
  local records = staged.records
  if #records == 0 then
    return
  end

  local previousOrdered = actorsByManagerSlot(entry)
  local assignments = {}
  for index, actorId in ipairs(records) do
    assignments[index - 1] = plans[actorId].actor
  end
  for _, actor in ipairs(previousOrdered) do
    if not plans[actor.actorId] then
      local slot = 0
      while assignments[slot] ~= nil do
        slot = slot + 1
      end
      assignments[slot] = actor
    end
  end
  entry.store:replaceManagerSlots(assignments)

  local function managerSlotForEntry(actor)
    return managerSlot(entry, actor)
  end
  local occupancy = FieldActorOccupancy.new({
    runtimeMap = entry.runtimeMap,
    managerSlot = managerSlotForEntry,
  })
  for _, actor in ipairs(entry.store:orderedActors()) do
    local plan = plans[actor.actorId]
    local projection = plan and plan.projection
      or (
        isResident(entry.runtimeMap, actor.fieldX, actor.fieldZ) and projectionFor(entry.runtimeMap, actor)
        or {
          fieldX = actor.fieldX,
          fieldZ = actor.fieldZ,
          resident = false,
        }
      )
    local candidate = {
      fieldX = projection.fieldX or actor.fieldX,
      fieldZ = projection.fieldZ or actor.fieldZ,
      surfaceId = projection.surfaceId,
      cellKey = projection.cellKey,
      sourceSurfaceId = projection.sourceSurfaceId,
    }
    if actor.solid and projection.resident ~= false then
      occupancy:claim(actor, candidate)
    end
  end

  for _, actorId in ipairs(records) do
    local plan = plans[actorId]
    local action = plan.record.action
    if action then
      if not plan.projection.resident then
        Errors.raise(
          ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
          "saved autonomous action start is outside physical residency",
          { actorId = actorId }
        )
      end
      if action.start.fieldX ~= plan.record.fieldX or action.start.fieldZ ~= plan.record.fieldZ then
        Errors.raise(
          ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
          "saved autonomous action start is inconsistent",
          { actorId = actorId }
        )
      end
      local destination = assert(plan.destination)
      local candidate = {
        fieldX = destination.fieldX,
        fieldZ = destination.fieldZ,
        surfaceId = destination.surfaceId,
        cellKey = destination.cellKey,
        sourceSurfaceId = destination.sourceSurfaceId,
      }
      local key = occupancy:key(candidate)
      if occupancy:winnerByKey(key) ~= nil or occupancy:reservation(candidate) then
        Errors.raise(
          FieldErrors.ACTOR_OCCUPANCY_CONFLICT,
          "saved autonomous reservations conflict",
          { actorId = actorId }
        )
      end
      occupancy:reserve(actorId, candidate)
      plan.destination = destination
      plan.reservationKey = key
    end
  end

  local stagedActions = {}
  local restoredActors = {}
  local restored, restoreErr = pcall(function()
    for _, actorId in ipairs(records) do
      local plan = plans[actorId]
      local actor, record = plan.actor, plan.record
      actor:setPosition(plan.projection)
      actor:setFacing(record.facing)
      actor.movementType = record.movementType
      self.autonomy:restore(actorId, record.movementType, record.controller)
      restoredActors[#restoredActors + 1] = actor
      if record.action then
        local action = record.action
        actor:beginAction({
          action = action.kind,
          direction = action.direction,
          distance = "near",
          speed = "normal",
          start = {
            fieldX = plan.projection.fieldX,
            fieldZ = plan.projection.fieldZ,
            worldX = plan.projection.worldX,
            worldY = plan.projection.worldY,
            worldZ = plan.projection.worldZ,
            surfaceId = plan.projection.surfaceId,
            cellKey = plan.projection.cellKey,
            sourceSurfaceId = plan.projection.sourceSurfaceId,
            resident = plan.projection.resident,
          },
          dest = plan.destination,
          durationTicks = AUTONOMOUS_STEP_TICKS,
        }, action.owner)
        actor:advanceAction(action.progressTicks, AUTONOMOUS_STEP_TICKS)
        stagedActions[actorId] = {
          reservationKey = plan.reservationKey,
          progressTicks = action.progressTicks,
          destination = plan.destination,
        }
      end
    end
  end)
  if not restored then
    for _, actor in ipairs(restoredActors) do
      actor:cancelAction()
    end
    error(restoreErr, 0)
  end
  entry.occupancy = occupancy
  entry.autonomousActions = stagedActions
end

-- Removes a published entry and releases its actors. An entry that is no
-- longer the one indexed under its map id has already been replaced, so the
-- index and the active map identity are left alone.
---@param self FieldActorManager
---@param entry FieldActorManager.Entry
local function retireEntry(self, entry)
  local mapId = entry.runtimeMap.mapId
  if self.maps[mapId] == entry then
    self.maps[mapId] = nil
    if self.currentMapId == mapId then
      self.currentMapId = nil
    end
  end
  if #entry.store:orderedActors() > 0 then
    self._visualRevision = self._visualRevision + 1
  end
  destroyEntry(self, entry)
end

-- The one production activation seam: the destination entry is built and
-- bound while the previous active entry is still live, so a construction or
-- binding failure leaves the live actor world untouched. Entering the exact
-- same runtime map again is idempotent, so a transition's overlapping load
-- and commit phases cannot duplicate a map's actors.
---@param runtimeMap RuntimeFieldMap
---@param eventState FieldEventState
---@param restoredObjects table<string, unknown>?
---@param self FieldActorManager
function FieldActorManager:enterMap(runtimeMap, eventState, restoredObjects)
  assert(runtimeMap and runtimeMap.fieldData, "enterMap requires a runtime map")
  assert(eventState, "enterMap requires a field event state")
  local mapId = runtimeMap.mapId
  local existing = self.maps[mapId]
  if existing and existing.runtimeMap == runtimeMap then
    assert(restoredObjects == nil, "restored objects cannot be applied to an active map")
    bindEventState(self, eventState)
    self.currentMapId = mapId
    return
  end
  local entry = newEntry(runtimeMap)
  populateEntry(self, entry, eventState)
  local restored, restoreErr = pcall(self._restoreEntry, self, entry, restoredObjects)
  if not restored then
    destroyEntry(self, entry)
    error(restoreErr, 0)
  end
  local bound, bindErr = pcall(bindEventState, self, eventState)
  if not bound then
    destroyEntry(self, entry)
    error(bindErr, 0)
  end
  if restoredObjects and restoredObjects.rng then
    self.autonomy:restoreRng(restoredObjects.rng)
  end

  local previous = self.currentMapId and self.maps[self.currentMapId] or nil
  self.maps[mapId] = entry
  self.currentMapId = mapId
  if #entry.store:orderedActors() > 0 then
    self._visualRevision = self._visualRevision + 1
  end
  if existing then
    retireEntry(self, existing)
  end
  if previous and previous ~= existing then
    retireEntry(self, previous)
  end
end

local function captureAutonomousAction(entry, actor)
  local action = entry.autonomousActions[actor.actorId]
  if action == nil then
    return nil
  end
  assert(actor.resident, "active autonomous action actor must be resident")
  assert(
    actor.cellKey ~= nil and actor.sourceSurfaceId ~= nil,
    "active autonomous action actor needs a physical identity"
  )
  local motion = assert(actor:scriptedMotionState())
  return {
    owner = assert(motion.owner),
    kind = assert(motion.action),
    direction = assert(motion.direction),
    start = {
      fieldX = motion.startFieldX,
      fieldZ = motion.startFieldZ,
      cellKey = assert(actor.cellKey),
      sourceSurfaceId = assert(actor.sourceSurfaceId),
    },
    destination = {
      fieldX = action.destination.fieldX,
      fieldZ = action.destination.fieldZ,
      cellKey = assert(action.destination.cellKey),
      sourceSurfaceId = assert(action.destination.sourceSurfaceId),
    },
    progressTicks = action.progressTicks,
  }
end

---@return table<string, unknown>
function FieldActorManager:captureObjects()
  local function captureController(actorId)
    return self.autonomy:capture(actorId)
  end
  local function captureAction(entry, actor)
    return captureAutonomousAction(entry, actor)
  end
  local function captureRng()
    return self.autonomy:captureRng()
  end
  -- The dynamic partner is derived follower presentation, never persisted
  -- state: it reconstructs from the party after continue.
  local function persistableActors(entry)
    local ordered = {}
    for _, actor in ipairs(actorsByManagerSlot(entry)) do
      if actor.objectEventId ~= PARTNER_OBJECT_ID then
        ordered[#ordered + 1] = actor
      end
    end
    return ordered
  end
  return self.persistence:capture(self.maps, persistableActors, captureController, captureAction, captureRng)
end

---@param mapId integer
---@param self FieldActorManager
function FieldActorManager:leaveMap(mapId)
  local entry = self.maps[mapId]
  if not entry then
    return
  end
  retireEntry(self, entry)
end

-- Queued rather than applied inline: a flag written mid-tick must not change
-- the world under code that has already consulted occupancy this tick.
---@param change FieldActorStateChange
---@param self FieldActorManager
function FieldActorManager:onEventStateChanged(change)
  if change.kind ~= "flag" then
    return
  end
  local flagChange = change --[[@as FieldActorFlagChange]]
  self.pendingFlags[#self.pendingFlags + 1] = flagChange
end

---@param change FieldActorFlagChange
---@param self FieldActorManager
function FieldActorManager:_applyFlag(change)
  for _, entry in pairs(self.maps) do
    for _, event in ipairs(entry.store:eventsForFlag(change.id)) do
      local actorId = FieldObjectActor.actorId(entry.runtimeMap.mapId, event.objectEventId)
      local actor = entry.store:getActor(actorId)
      if change.newValue and actor then
        self:_destroy(entry, actor)
      elseif not change.newValue and not actor then
        self:_instantiate(entry, event)
      end
    end
  end
end

---@param self FieldActorManager
function FieldActorManager:syncEventStateChanges()
  local pending = self.pendingFlags
  if #pending == 0 then
    return
  end
  self.pendingFlags = {}
  for _, change in ipairs(pending) do
    self:_applyFlag(change)
  end
end

local AUTONOMOUS_DELTAS = {
  north = { x = 0, z = -1 },
  south = { x = 0, z = 1 },
  west = { x = -1, z = 0 },
  east = { x = 1, z = 0 },
}

local function withinSourceRange(destination, origin, range)
  assert(type(range) == "number" and range % 1 == 0, "HGSS movement range must be an integer")
  assert(range >= -1, "HGSS movement range below -1")
  return range == -1 or math.abs(destination - origin) <= range
end

local function movementErrorIsBlocked(err)
  if not Errors.is(err) then
    return false
  end
  ---@cast err Errors.Error
  return err.code == FieldErrors.FIELD_COORDINATES_OUT_OF_COVERAGE or SurfaceResolver.isStepRejection(err)
end

-- The one shared physical placement/step rejection classification: a tile
-- outside coverage or a destination surface beyond the reachable step is a
-- placement the caller waits out or steps around. Every other structured
-- failure (ambiguous or missing surfaces, occupancy conflicts, programmer
-- faults, data corruption) propagates unchanged through this predicate's
-- callers.
---@param err unknown
---@return boolean
function FieldActorManager.isPlacementRejection(err)
  return movementErrorIsBlocked(err)
end

local function samePhysicalCandidate(runtimeMap, left, right)
  if left.fieldX ~= right.fieldX or left.fieldZ ~= right.fieldZ then
    return false
  end
  local leftKind, leftFirst, leftSecond = stableSurfaceIdentity(runtimeMap, left)
  local rightKind, rightFirst, rightSecond = stableSurfaceIdentity(runtimeMap, right)
  return sameSurfaceIdentity(leftKind, leftFirst, leftSecond, rightKind, rightFirst, rightSecond)
end

local function playerOccupies(runtimeMap, candidate, facts)
  if facts == nil then
    return false
  end
  for _, playerCandidate in ipairs(facts) do
    if samePhysicalCandidate(runtimeMap, candidate, playerCandidate) then
      return true
    end
  end
  return false
end

---@param self FieldActorManager
---@param entry FieldActorManager.Entry
---@param actor FieldActorManager.Actor
---@param direction FieldDirection
---@param context table<string, unknown>
---@return table<string, unknown>|nil
local function resolveAutonomousDestination(self, entry, actor, direction, context)
  local delta = assert(AUTONOMOUS_DELTAS[direction], "unknown autonomous direction " .. tostring(direction))
  local fieldX, fieldZ = actor.fieldX + delta.x, actor.fieldZ + delta.z
  local event = actor.sourceEvent
  local xRange = assert(event.xRange, "actor source X range is required")
  local zRange = assert(event.yRange, "actor source Z range is required")
  local withinX = withinSourceRange(fieldX, event.x, xRange)
  local withinZ = withinSourceRange(fieldZ, event.z, zRange)
  if not withinX or not withinZ then
    return nil
  end

  local runtimeMap = entry.runtimeMap
  local ok, destination = pcall(function()
    local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, fieldX, fieldZ)
    local centerX, centerZ = localX + FieldCoordinates.TILE_CENTER_OFFSET, localZ + FieldCoordinates.TILE_CENTER_OFFSET
    local sample
    if runtimeMap.probePhysicalCell then
      local probe = runtimeMap:probePhysicalCell(fieldX, fieldZ, {
        currentCellKey = actor.cellKey,
        currentSourceSurfaceId = actor.sourceSurfaceId,
        currentY = actor.worldY,
        fromFieldX = actor.fieldX,
        fromFieldZ = actor.fieldZ,
      })
      if not probe or probe.collision.blocked then
        return nil
      end
      sample = {
        surfaceId = probe.surfaceId,
        worldY = probe.worldY,
        cellKey = probe.cellKey,
        sourceSurfaceId = probe.sourceSurfaceId,
      }
    else
      if runtimeMap.collision.isBlockedLocal and runtimeMap.collision:isBlockedLocal(localX, localZ) then
        return nil
      end
      sample = SurfaceResolver.new(runtimeMap.terrain):resolve({
        localX = centerX,
        localZ = centerZ,
        currentY = actor.worldY,
        currentSurfaceId = actor.surfaceId,
        crossing = {
          fromX = (actor.fieldX - runtimeMap.coordinateOrigin.x) + FieldCoordinates.TILE_CENTER_OFFSET,
          fromZ = (actor.fieldZ - runtimeMap.coordinateOrigin.z) + FieldCoordinates.TILE_CENTER_OFFSET,
          toX = centerX,
          toZ = centerZ,
        },
      })
      local plate = assert(runtimeMap.terrain:plate(sample.surfaceId), "autonomous destination surface is missing")
      sample.cellKey, sample.sourceSurfaceId = sourceIdentityFromPlate(plate)
    end
    local plate = assert(runtimeMap.terrain:plate(sample.surfaceId), "autonomous destination surface is missing")
    local candidate = {
      fieldX = fieldX,
      fieldZ = fieldZ,
      surfaceId = sample.surfaceId,
      cellKey = sample.cellKey or plate.cellKey,
      sourceSurfaceId = sample.sourceSurfaceId or plate.sourceSurfaceId,
    }
    if
      self:getCollisionAt(actor.mapId, candidate) ~= nil
      or playerOccupies(runtimeMap, candidate, context.playerCandidates)
    then
      return nil
    end
    local world = FieldCoordinates.fieldToWorld(runtimeMap, fieldX, fieldZ, sample.worldY)
    return {
      fieldX = fieldX,
      fieldZ = fieldZ,
      surfaceId = sample.surfaceId,
      cellKey = candidate.cellKey,
      sourceSurfaceId = candidate.sourceSurfaceId,
      worldX = world.x,
      worldY = world.y,
      worldZ = world.z,
      resident = isResident(runtimeMap, fieldX, fieldZ),
    }
  end)
  if not ok then
    if movementErrorIsBlocked(destination) then
      return nil
    end
    error(destination)
  end
  return destination
end

function FieldActorManager:_beginAutonomousAction(entry, actor, direction, context)
  local destination = resolveAutonomousDestination(self, entry, actor, direction, context)
  if destination == nil then
    return false
  end
  local destinationCandidate = {
    fieldX = destination.fieldX,
    fieldZ = destination.fieldZ,
    surfaceId = destination.surfaceId,
    cellKey = destination.cellKey,
    sourceSurfaceId = destination.sourceSurfaceId,
  }
  local reservationKey = entry.occupancy:key(destinationCandidate)
  if entry.occupancy:reservationByKey(reservationKey) ~= nil then
    return false
  end
  entry.occupancy:reserve(actor.actorId, destinationCandidate)
  entry.autonomousActions[actor.actorId] =
    { reservationKey = reservationKey, progressTicks = 0, destination = destination }
  local ok, err = pcall(function()
    actor:beginAction({
      action = "walk",
      direction = direction,
      distance = "near",
      speed = "normal",
      start = {
        fieldX = actor.fieldX,
        fieldZ = actor.fieldZ,
        worldX = actor.worldX,
        worldY = actor.worldY,
        worldZ = actor.worldZ,
        surfaceId = actor.surfaceId,
        cellKey = actor.cellKey,
        sourceSurfaceId = actor.sourceSurfaceId,
        resident = actor.resident,
      },
      dest = destination,
      durationTicks = AUTONOMOUS_STEP_TICKS,
    }, "autonomous")
  end)
  if not ok then
    entry.autonomousActions[actor.actorId] = nil
    entry.occupancy:cancelReservation(destinationCandidate, actor.actorId)
    error(err)
  end
  return true
end

function FieldActorManager:_advanceAutonomousAction(entry, actor, action)
  action.progressTicks = action.progressTicks + 1
  local durationTicks = AUTONOMOUS_STEP_TICKS
  actor:advanceAction(action.progressTicks, durationTicks)
  if action.progressTicks < durationTicks then
    return
  end
  local destination = action.destination
  local reservation = entry.occupancy:reservationByKey(action.reservationKey)
  assert(reservation and reservation.actorId == actor.actorId, "autonomous reservation is missing at commit")
  local oldKey = entry.occupancy:key(candidateForActor(actor))
  local newKey = entry.occupancy:key(reservation.candidate)
  if actor.solid then
    assert(entry.occupancy:winnerByKey(newKey) == nil, "autonomous destination became occupied")
    if actor.resident then
      assert(entry.occupancy:containsByKey(oldKey, actor), "autonomous departure occupancy is missing")
    end
  end
  assert(entry.occupancy:key(destination --[[@as FieldOccupancyCandidate]]) == newKey, "autonomous destination changed")
  local resolvedDestination =
    assert(actor:commitAction() --[[@as FieldActorResolvedPosition]], "autonomous action destination is missing")
  assert(
    entry.occupancy:key(resolvedDestination --[[@as FieldOccupancyCandidate]]) == newKey,
    "autonomous action destination changed"
  )
  publishResolvedPosition(entry, actor, resolvedDestination)
  entry.occupancy:cancelReservation(reservation.candidate, actor.actorId)
  entry.autonomousActions[actor.actorId] = nil
  self.autonomy:applyPendingMovementType(actor.actorId)
  local autonomyState = self.autonomy:state(actor.actorId)
  actor.movementType = autonomyState.movementType
  if autonomyState.profile.kind == "pattern" or autonomyState.profile.kind == "shuttle" then
    entry.autonomousPresentationCarry[actor.actorId] = true
  else
    actor:settlePresentation()
  end
end

local function sortedMapIds(maps)
  local ids = {}
  for mapId in pairs(maps) do
    ids[#ids + 1] = mapId
  end
  table.sort(ids)
  return ids
end

---@param tick integer
---@param context FieldActorStepContext?
---@param self FieldActorManager
function FieldActorManager:step(tick, context)
  context = context or {}
  if self.eventState then
    self.eventState:setTick(tick)
  end
  self:syncEventStateChanges()
  local playerFacts
  if context.player then
    playerFacts = {}
    for key, value in pairs(context.player) do
      playerFacts[key] = value
    end
    if context.player.worldY ~= nil then
      playerFacts.positionYBand = sourcePositionYBand(context.player.worldY)
    end
  end
  for _, mapId in ipairs(sortedMapIds(self.maps)) do
    local entry = assert(self.maps[mapId])
    for _, actor in ipairs(entry.store:orderedActors()) do
      actor:beginFixedStep()
      local movementLocked = context.autonomousLocked == true
      if not movementLocked and context.actorLocked then
        movementLocked = context.actorLocked(actor.actorId) == true
      end
      if not movementLocked then
        actor:advancePresentationTick()
      end
      local autonomousAction = entry.autonomousActions[actor.actorId]
      if autonomousAction then
        self:_advanceAutonomousAction(entry, actor, autonomousAction)
      else
        local hasAutonomousPresentationCarry = entry.autonomousPresentationCarry[actor.actorId] == true
        if
          actor.resident
          and not actor:isScriptedMoving()
          and actor.interactionFacingOverride == nil
          and not movementLocked
          and self.autonomy:isOrdinary(actor.actorId)
        then
          local function setFacing(_, id, direction)
            local target = assert(self:getById(id))
            if target.interactionFacingOverride == nil then
              target:setFacing(direction)
            end
          end
          local function walk(_, id, direction)
            local target = assert(self:getById(id))
            return self:_beginAutonomousAction(entry, target, direction, context)
          end
          local capability = {
            fieldX = actor.fieldX,
            fieldZ = actor.fieldZ,
            surfaceId = actor.surfaceId,
            worldY = actor.worldY,
            positionYBand = actor.worldY ~= nil and sourcePositionYBand(actor.worldY) or nil,
            facingOverride = actor.interactionFacingOverride ~= nil,
            player = playerFacts,
            setFacing = setFacing,
            walk = walk,
          }
          self.autonomy:step(actor.actorId, capability)
        end
        if hasAutonomousPresentationCarry then
          if entry.autonomousActions[actor.actorId] == nil then
            actor:settlePresentation()
          end
          entry.autonomousPresentationCarry[actor.actorId] = nil
        end
      end
    end
  end
end

-- Stages one in-flight action into the replacement frame: current-frame
-- start/destination endpoints plus, for autonomous actions, a rebuilt
-- destination reservation in the staged occupancy. Runs before the staged
-- occupancy is published, so any projection or reservation failure leaves
-- the live index untouched.
local function stageActionReprojection(entry, stagedOccupancy, plan)
  local runtimeMap = entry.runtimeMap
  local actor = plan.actor
  local motion = actor:scriptedMotionState()
  local autonomousAction = entry.autonomousActions[actor.actorId]
  if motion == nil then
    assert(autonomousAction == nil, "autonomous action has no actor motion")
    return
  end
  assert(
    motion.startFieldX == actor.fieldX and motion.startFieldZ == actor.fieldZ,
    "action start disagrees with committed position"
  )
  plan.start = plan.projection
    or projectEndpoint(runtimeMap, {
      fieldX = motion.startFieldX,
      fieldZ = motion.startFieldZ,
      surfaceId = motion.startSurfaceId,
      cellKey = motion.startCellKey,
      sourceSurfaceId = motion.startSourceSurfaceId,
      worldY = motion.startWorldY,
      sourceEvent = actor.sourceEvent,
      actorId = actor.actorId,
    })
  plan.destination = projectEndpoint(runtimeMap, {
    fieldX = motion.destFieldX,
    fieldZ = motion.destFieldZ,
    surfaceId = motion.destSurfaceId,
    cellKey = motion.destCellKey,
    sourceSurfaceId = motion.destSourceSurfaceId,
    worldY = motion.destWorldY,
    sourceEvent = actor.sourceEvent,
    actorId = actor.actorId,
  })
  if motion.owner ~= "autonomous" then
    assert(autonomousAction == nil, "scripted motion owns an autonomous action")
    return
  end
  assert(autonomousAction ~= nil, "autonomous motion has no manager action")
  local recorded = assert(autonomousAction.destination, "autonomous action destination is missing")
  assert(
    recorded.fieldX == motion.destFieldX and recorded.fieldZ == motion.destFieldZ,
    "autonomous destination disagrees with actor motion"
  )
  local destination = plan.destination
  plan.reservationKey = stagedOccupancy:reserve(actor.actorId, {
    fieldX = destination.fieldX,
    fieldZ = destination.fieldZ,
    surfaceId = destination.surfaceId,
    cellKey = destination.cellKey,
    sourceSurfaceId = destination.sourceSurfaceId,
  })
  plan.progressTicks = autonomousAction.progressTicks
end

-- Applies one staged plan after the replacement occupancy is published:
-- committed projection/residency, motion rebase at unchanged progress, and
-- the rebuilt autonomous reservation key/destination.
local function applyReprojectionPlan(entry, plan)
  local actor = plan.actor
  local projection = plan.projection
  if projection then
    actor:setPosition({
      fieldX = actor.fieldX,
      fieldZ = actor.fieldZ,
      cellKey = projection.cellKey,
      sourceSurfaceId = projection.sourceSurfaceId,
      surfaceId = projection.surfaceId,
      worldX = projection.worldX,
      worldY = projection.worldY,
      worldZ = projection.worldZ,
      resident = true,
    })
  else
    actor.resident = false
  end
  local start = plan.start
  if start == nil then
    return
  end
  local destination = assert(plan.destination, "reconcile plan destination is missing")
  actor:reprojectActiveAction(start, destination)
  if plan.reservationKey then
    entry.autonomousActions[actor.actorId] = {
      reservationKey = plan.reservationKey,
      progressTicks = plan.progressTicks,
      destination = destination,
    }
  end
end

-- Rebuilds the physical projection of semantic actors as one complete
-- replacement: committed occupancy plus every live action and autonomous
-- reservation. Staging resolves every projection and reservation before any
-- actor or index changes, so a fixed tick observes one complete index.
-- Reconciliation order:
-- 1. stage committed occupant claims in a fresh FieldActorOccupancy
-- 2. stage/reproject every active action
-- 3. stage every autonomous reservation into that same fresh occupancy
-- 4. publish entry.occupancy only after all staging succeeds
-- 5. apply actor/action projection updates and new reservation keys
---@param self FieldActorManager
function FieldActorManager:reconcilePhysicalWorld()
  for _, entry in pairs(self.maps) do
    local runtimeMap = entry.runtimeMap
    local function managerSlotForEntry(actor)
      return managerSlot(entry, actor)
    end
    local stagedOccupancy = FieldActorOccupancy.new({
      runtimeMap = runtimeMap,
      managerSlot = managerSlotForEntry,
    })
    local plans = {}
    for _, actor in ipairs(entry.store:orderedActors()) do
      local plan = { actor = actor }
      if isResident(runtimeMap, actor.fieldX, actor.fieldZ) then
        local projection = projectionFor(runtimeMap, actor)
        if actor.solid then
          stagedOccupancy:claim(actor, {
            fieldX = actor.fieldX,
            fieldZ = actor.fieldZ,
            surfaceId = projection.surfaceId,
            cellKey = projection.cellKey,
            sourceSurfaceId = projection.sourceSurfaceId,
          })
        end
        plan.projection = projection
      end
      plans[#plans + 1] = plan
    end
    for _, plan in ipairs(plans) do
      stageActionReprojection(entry, stagedOccupancy, plan)
    end

    entry.occupancy = stagedOccupancy
    for _, plan in ipairs(plans) do
      applyReprojectionPlan(entry, plan)
    end
  end
end

-- Monotonic signal for presentation residency. Movement, facing, pose, and
-- visibility changes do not alter the set of sprite definitions the field
-- presentation must hold.
---@return integer
---@param self FieldActorManager
function FieldActorManager:visualRevision()
  return self._visualRevision
end

-- Add the distinct sprite definitions needed by every live actor to `out`.
-- The caller owns clearing a reused set before collecting a new snapshot.
---@param out table<integer, boolean>
---@param self FieldActorManager
function FieldActorManager:collectSpriteIds(out)
  assert(type(out) == "table", "collectSpriteIds requires a set table")
  for _, entry in pairs(self.maps) do
    for _, actor in ipairs(entry.store:orderedActors()) do
      out[actor.spriteId] = true
    end
  end
end

---@param alpha number? host-frame sample between the previous and current fixed points; omitted reads the current point
---@return FieldActorManager.DrawRecord[]
---@param self FieldActorManager
function FieldActorManager:drawRecords(alpha)
  local records = self._drawRecords
  local count = 0
  for _, entry in pairs(self.maps) do
    for _, actor in ipairs(entry.store:orderedActors()) do
      if not actor.resident then
        goto continue
      end
      count = count + 1
      local record = self._drawRecordByActorId[actor.actorId]
      if not record then
        record = {
          actorId = actor.actorId,
          spriteId = actor.spriteId,
          world = { x = actor.worldX, y = actor.worldY, z = actor.worldZ },
          facing = actor.facing,
          pose = actor.pose,
          poseTick = actor.poseTick,
          visible = actor.visible,
        }
        self._drawRecordByActorId[actor.actorId] = record
      end
      -- Render-only presentation offset (e.g. walk-in-place bob) is applied
      -- here, at the final draw-position boundary, onto the sampled
      -- previous/current base point; the actor's logical
      -- worldX/worldY/worldZ (read by terrain, collision, and save) never
      -- carry it.
      local offset = actor.presentationOffset
      local presentation = actor:presentationState()
      local gestureOffsetY = presentation.gestureOffsetY
      local base = actor:renderPosition(alpha)
      record.actorId = actor.actorId
      record.spriteId = actor.spriteId
      record.world.x = base.x + (offset and offset.x or 0)
      record.world.y = base.y + (offset and offset.y or 0) + gestureOffsetY
      record.world.z = base.z + (offset and offset.z or 0)
      record.facing = actor.facing
      record.pose = actor.pose
      record.poseTick = actor.poseTick
      record.gesturePose = presentation.gesturePose
      record.gestureTick = presentation.gestureTick
      record.activeEmoteKind = actor.activeEmoteKind
      record.visible = actor.visible
      records[count] = record
      ::continue::
    end
  end
  for index = #records, count + 1, -1 do
    records[index] = nil
  end
  return records
end

---@param actorId string
---@return FieldActorManager.Actor?
---@param self FieldActorManager
function FieldActorManager:getById(actorId)
  for _, entry in pairs(self.maps) do
    local actor = entry.store:getActor(actorId)
    if actor then
      return actor
    end
  end
  return nil
end

---@param mapId integer
---@param candidate FieldOccupancyCandidate
---@return FieldActorManager.Actor?
---@param self FieldActorManager
function FieldActorManager:getAt(mapId, candidate)
  local entry = self.maps[mapId]
  if not entry then
    return nil
  end
  local occupant = entry.occupancy:winner(candidate)
  if occupant then
    return occupant
  end
  -- The non-solid partner never joins the occupancy index, so it needs an
  -- explicit coordinate match to stay discoverable by facing interaction and
  -- script partner lookups without ever blocking movement.
  local partner = entry.store:getActor(PARTNER_ACTOR_ID)
  if partner ~= nil and partner.fieldX == candidate.fieldX and partner.fieldZ == candidate.fieldZ then
    if candidate.cellKey ~= nil and candidate.sourceSurfaceId ~= nil then
      if partner.cellKey == candidate.cellKey and partner.sourceSurfaceId == candidate.sourceSurfaceId then
        return partner
      end
    elseif candidate.surfaceId ~= nil and partner.surfaceId == candidate.surfaceId then
      return partner
    end
  end
  return nil
end

-- Motion collision sees committed occupants and autonomous destinations. The
-- interaction lookup above intentionally remains committed-position based.
---@param mapId integer
---@param candidate FieldOccupancyCandidate
---@return FieldActorManager.Actor?
function FieldActorManager:getCollisionAt(mapId, candidate)
  local entry = self.maps[mapId]
  if not entry then
    return nil
  end
  local key = entry.occupancy:key(candidate)
  local actor = entry.occupancy:winnerByKey(key)
  if actor then
    return actor
  end
  local reservation = entry.occupancy:reservationByKey(key)
  if reservation then
    return assert(entry.store:getActor(reservation.actorId), "autonomous reservation actor is missing")
  end
  return nil
end

-- The read-only identity of a source object event on a map that owns no live
-- actor entry: the same semantic identity activation would give it, without
-- any actor instance or visual reference.
---@class FieldActorManager.ProbeResult
---@field actorId string
---@field objectEventId integer
---@field sourceEvent FieldActorEvent
---@field spriteId integer

-- Inspect destination object events without creating actors. This deliberately
-- repeats only the event filtering and surface comparison needed for collision;
-- actor construction remains the ownership-bearing path used after a commit.
---@param runtimeMap RuntimeFieldMap
---@param eventState FieldEventState
---@param candidate FieldOccupancyCandidate
---@param self FieldActorManager
---@return FieldActorManager.ProbeResult?
function FieldActorManager:probeAt(runtimeMap, eventState, candidate)
  assert(runtimeMap and runtimeMap.fieldData, "probeAt requires a runtime map")
  assert(eventState, "probeAt requires a field event state")
  local targetKind, targetFirst, targetSecond = stableSurfaceIdentity(runtimeMap, candidate)
  local occupant
  for _, event in ipairs(runtimeMap.fieldData.events.objects) do
    if
      event.x == candidate.fieldX
      and event.z == candidate.fieldZ
      and not eventState:isFlagSet(event.eventFlag)
      and event.solid ~= false
    then
      local actorId = FieldObjectActor.actorId(runtimeMap.mapId, event.objectEventId)
      local sample = resolveSurface(runtimeMap, event, actorId)
      local eventKind, eventFirst, eventSecond = stableSurfaceIdentity(runtimeMap, {
        fieldX = event.x,
        fieldZ = event.z,
        surfaceId = sample.surfaceId,
      })
      if targetKind == "source" then
        assert(eventKind == "source", "destination event stable surface identity is missing")
      end
      if sameSurfaceIdentity(targetKind, targetFirst, targetSecond, eventKind, eventFirst, eventSecond) then
        if occupant then
          Errors.raise(
            FieldErrors.ACTOR_OCCUPANCY_CONFLICT,
            actorId .. " and " .. occupant.actorId .. " occupy the same field cell and surface",
            {
              actorId = actorId,
              otherActorId = occupant.actorId,
              mapId = runtimeMap.mapId,
              fieldX = candidate.fieldX,
              fieldZ = candidate.fieldZ,
              surfaceId = candidate.surfaceId,
            }
          )
        end
        occupant = {
          actorId = actorId,
          objectEventId = event.objectEventId,
          sourceEvent = event,
          spriteId = self:_resolveSpriteId(event, eventState),
        }
      end
    end
  end
  return occupant
end

-- Raw facing codes match the pinned field direction table (0 north, 1
-- south, 2 west, 3 east).
local PARTNER_FACING_RAW = { north = 0, south = 1, west = 2, east = 3 }
local PARTNER_FACINGS = { north = true, south = true, west = true, east = true }

---@class FieldActorManager.PartnerSpec
---@field numericId integer must be the source partner object id 253
---@field visualId integer compiled field-actor visual id
---@field mapId integer must be the current actor map
---@field fieldX integer
---@field fieldZ integer
---@field facing FieldDirection
---@field worldY number? terrain surface hint for stacked maps
---@field solid boolean? must be absent or false; the partner never blocks
---@field initiallyVisible boolean? install-only visibility; absent means visible

---@param spec FieldActorManager.PartnerSpec
---@param self FieldActorManager
local function checkPartnerSpec(self, spec)
  assert(type(spec) == "table", "partner spec required")
  if spec.numericId ~= PARTNER_OBJECT_ID then
    Errors.raise(
      FieldErrors.ACTOR_PARTNER_ID_INVALID,
      "partner numeric id must be " .. PARTNER_OBJECT_ID,
      { numericId = spec.numericId }
    )
  end
  if spec.solid == true then
    Errors.raise(FieldErrors.ACTOR_PARTNER_SOLID_INVALID, "the partner actor is never solid", {})
  end
  if spec.initiallyVisible ~= nil then
    assert(type(spec.initiallyVisible) == "boolean", "partner initial visibility must be boolean when present")
  end
  if not PARTNER_FACINGS[spec.facing] then
    Errors.raise(
      FieldErrors.ACTOR_PARTNER_FACING_INVALID,
      "unsupported partner facing " .. tostring(spec.facing),
      { facing = spec.facing }
    )
  end
  assert(
    type(spec.fieldX) == "number" and spec.fieldX % 1 == 0 and type(spec.fieldZ) == "number" and spec.fieldZ % 1 == 0,
    "partner integer field coordinates required"
  )
  if spec.mapId ~= self.currentMapId then
    Errors.raise(
      FieldErrors.ACTOR_PARTNER_MAP_MISMATCH,
      "partner installation requires the current actor map",
      { mapId = spec.mapId, currentMapId = self.currentMapId }
    )
  end
  if not self.assets:knows(spec.visualId) then
    Errors.raise(
      FieldErrors.ACTOR_PARTNER_VISUAL_MISSING,
      "spriteId " .. tostring(spec.visualId) .. " for " .. PARTNER_ACTOR_ID .. " is not in the compiled actor set",
      { actorId = PARTNER_ACTOR_ID, spriteId = spec.visualId }
    )
  end
end

-- The synthetic source event behind the dynamic partner. It carries the
-- source partner object id and the inert interaction script (raw script id 0),
-- so facing the partner resolves to the runtime no-op interaction instead of
-- a composition fault, while collision stays disabled through the actor's
-- own non-solid flag.
---@param spec FieldActorManager.PartnerSpec
---@return FieldActorEvent
local function partnerEvent(spec)
  return {
    index = -1,
    objectEventId = PARTNER_OBJECT_ID,
    spriteId = spec.visualId,
    movementType = "follow_player",
    type = 0,
    eventFlag = 0,
    scriptId = 0,
    facingDirection = spec.facing,
    facingDirectionRaw = PARTNER_FACING_RAW[spec.facing],
    xRange = 0,
    yRange = 0,
    x = spec.fieldX,
    z = spec.fieldZ,
    y = 0,
    solid = false,
  }
end

-- Resolve the partner tile surface without mutating the entry. Only a
-- classified physical placement rejection (outside residency or coverage,
-- or a destination surface beyond the reachable step) answers nil so the
-- controller waits it out; any other failure propagates.
---@param entry FieldActorManager.Entry
---@param spec FieldActorManager.PartnerSpec
---@return table<string, unknown>? surface
local function resolvePartnerSurface(entry, spec)
  local runtimeMap = entry.runtimeMap
  if not isResident(runtimeMap, spec.fieldX, spec.fieldZ) then
    return nil
  end
  local ok, surface = pcall(function()
    local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, spec.fieldX, spec.fieldZ)
    return SurfaceResolver.new(runtimeMap.terrain):resolve({
      localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
      localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
      currentY = spec.worldY,
    })
  end)
  if ok then
    return surface
  end
  if FieldActorManager.isPlacementRejection(surface) then
    return nil
  end
  error(surface)
end

-- Acquire the new visual and construct the replacement actor without
-- publishing it: any failure releases the acquisition and leaves the entry
-- (including a live old partner) untouched.
---@param self FieldActorManager
---@param entry FieldActorManager.Entry
---@param spec FieldActorManager.PartnerSpec
---@param surface table<string, unknown>
---@param initiallyVisible boolean?
---@return FieldActorManager.Actor
local function constructPartner(self, entry, spec, surface, initiallyVisible)
  local asset = self:_acquireVisual(spec.visualId, PARTNER_ACTOR_ID)
  local actor = nil ---@type FieldActorManager.Actor?
  local ok, err = pcall(function()
    local runtimeMap = entry.runtimeMap
    local world = FieldCoordinates.fieldToWorld(runtimeMap, spec.fieldX, spec.fieldZ, surface.worldY)
    local plate = assert(runtimeMap.terrain:plate(surface.surfaceId), "partner projected surface is missing")
    local plateCellKey, plateSourceSurfaceId = sourceIdentityFromPlate(plate)
    local visual = assert(asset.visual, "field actor visual is required")
    local idlePresentation = assert(visual.idlePresentation, "field actor idle presentation is required")
    actor = FieldObjectActor.new({
      mapId = runtimeMap.mapId,
      sourceEvent = partnerEvent(spec),
      spriteId = spec.visualId,
      solid = false,
      fieldX = spec.fieldX,
      fieldZ = spec.fieldZ,
      cellKey = plateCellKey or cellKeyFor(spec.fieldX, spec.fieldZ),
      sourceSurfaceId = plateSourceSurfaceId,
      surfaceId = surface.surfaceId,
      worldX = world.x,
      worldY = world.y,
      worldZ = world.z,
      resident = true,
      visual = visual,
      idlePresentation = idlePresentation,
    }) --[[@as FieldActorManager.Actor]]
    actor.actorId = PARTNER_ACTOR_ID
    actor:setVisible(initiallyVisible ~= false)
  end)
  if not ok then
    self.assets:release(spec.visualId)
    error(err)
  end
  return actor --[[@as FieldActorManager.Actor]]
end

-- Publish a constructed partner: take a manager slot, index it under the
-- source partner object id, attach its (never self-moving) special autonomy
-- profile so presence queries stay coherent, and bump the visual revision on
-- a live map.
---@param self FieldActorManager
---@param entry FieldActorManager.Entry
---@param actor FieldActorManager.Actor
local function publishPartner(self, entry, actor)
  assignManagerSlot(entry, actor)
  entry.store:addActor(actor)
  self.autonomy:attach(PARTNER_ACTOR_ID, actor.movementType, actor.sourceEvent)
  if self.maps[entry.runtimeMap.mapId] == entry then
    self._visualRevision = self._visualRevision + 1
  end
end

-- Install the dynamic partner on the current map. A classified physical
-- placement rejection answers nil (the controller waits for a committed
-- step); anything else either publishes exactly one partner or raises.
---@param spec FieldActorManager.PartnerSpec
---@return string? actorId
---@param self FieldActorManager
function FieldActorManager:installPartner(spec)
  checkPartnerSpec(self, spec)
  local entry = assert(self.maps[spec.mapId], "partner current map entry is missing")
  if entry.store:getActor(PARTNER_ACTOR_ID) ~= nil then
    Errors.raise(
      FieldErrors.ACTOR_PARTNER_ALREADY_INSTALLED,
      "a partner actor is already installed on map " .. tostring(spec.mapId),
      { mapId = spec.mapId }
    )
  end
  local surface = resolvePartnerSurface(entry, spec)
  if surface == nil then
    return nil
  end
  publishPartner(self, entry, constructPartner(self, entry, spec, surface, spec.initiallyVisible))
  return PARTNER_ACTOR_ID
end

-- Replace the live partner visual in place. The replacement is acquired and
-- validated before the old actor is destroyed; a failed replacement keeps
-- the old valid actor, and an unplaceable destination keeps it too.
---@param spec FieldActorManager.PartnerSpec
---@return string? actorId
---@param self FieldActorManager
function FieldActorManager:updatePartner(spec)
  checkPartnerSpec(self, spec)
  local entry = assert(self.maps[spec.mapId], "partner current map entry is missing")
  local old = entry.store:getActor(PARTNER_ACTOR_ID)
  if old == nil then
    Errors.raise(
      FieldErrors.ACTOR_PARTNER_NOT_INSTALLED,
      "no partner actor is installed on map " .. tostring(spec.mapId),
      { mapId = spec.mapId }
    )
  end
  assert(old ~= nil, "partner presence carries the installed actor")
  local surface = resolvePartnerSurface(entry, spec)
  if surface == nil then
    return nil
  end
  local actor = constructPartner(self, entry, spec, surface, old.visible)
  self:_destroy(entry, old)
  publishPartner(self, entry, actor)
  return PARTNER_ACTOR_ID
end

-- Remove the partner actor and release its visual exactly once. Absence is a
-- no-op so transition and disposal paths can clear unconditionally.
---@return string? removedActorId
---@param self FieldActorManager
function FieldActorManager:clearPartner()
  local actor = self:getById(PARTNER_ACTOR_ID)
  if actor == nil then
    return nil
  end
  local entry = assert(self.maps[actor.mapId], "partner map entry is missing")
  self:_destroy(entry, actor)
  return PARTNER_ACTOR_ID
end

---@param mapId integer
---@return FieldActorManager.Actor[]
---@param self FieldActorManager
function FieldActorManager:actorsOf(mapId)
  local entry = self.maps[mapId]
  return entry and entry.store:orderedActors() or {}
end

-- --- Scripted actor API ------------------------------------------------------

-- Alias of `getById` for the script actor world contract.
---@param actorId string
---@return FieldActorManager.Actor?
---@param self FieldActorManager
function FieldActorManager:getActor(actorId)
  return self:getById(actorId)
end

---@param actorId string
---@return FieldActorManager.ActorPosition?
---@param self FieldActorManager
function FieldActorManager:getPosition(actorId)
  local actor = self:getById(actorId)
  if actor == nil then
    return nil
  end
  return { fieldX = actor.fieldX, fieldZ = actor.fieldZ, worldY = actor.worldY }
end

---@param actorId string
---@return FieldDirection?
---@param self FieldActorManager
function FieldActorManager:getFacing(actorId)
  local actor = self:getById(actorId)
  if actor == nil then
    return nil
  end
  return actor.facing
end

---@param actorId string
---@param direction FieldDirection
---@param self FieldActorManager
function FieldActorManager:setFacing(actorId, direction)
  local actor = requireActor(self, actorId)
  actor:setFacing(direction)
end

-- Scripted position set: resolves the destination surface from the terrain
-- (an explicit worldY selects the plate at that height; otherwise the actor's
-- current surface is preserved whenever it covers the destination), then
-- rekeys the occupancy index so collision and the draw list never disagree.
-- The whole destination is calculated and validated -- coordinates, surface,
-- and occupancy conflict -- before the actor or the occupancy index is
-- mutated, so a conversion or surface failure leaves the actor exactly where
-- it was. The destination occupancy slot is never overwritten by default:
-- moving onto another solid actor's cell is a conflict, the same invariant
-- _instantiate enforces -- with one narrowing: pinned HGSS source never
-- performs an inter-object collision check while a script's `ApplyMovement`
-- repositions an actor, only autonomous walk-AI and player movement check it.
-- `options.scripted` is how a script-driven caller (currently only
-- `ScriptActorWorld`) identifies itself; every other caller keeps the
-- default strict behavior, including two script-driven actors that briefly
-- land on the same cell mid-sequence: the later `setPosition` call simply
-- takes over the occupancy slot instead of raising.
---@param actorId string
---@param position FieldActorManager.Position
---@param options { scripted?: boolean }?
---@param self FieldActorManager
function FieldActorManager:setPosition(actorId, position, options)
  local actor = requireActor(self, actorId)
  local entry = assert(self.maps[actor.mapId], "actor map entry missing")
  local resident = isResident(entry.runtimeMap, position.fieldX, position.fieldZ)
  local cellKey = cellKeyFor(position.fieldX, position.fieldZ)
  local sample
  local plate
  local plateCellKey
  local world
  local sourceSurfaceId = resident and actor.sourceSurfaceId or nil
  if resident then
    local localX, localZ = FieldCoordinates.fieldToLocal(entry.runtimeMap, position.fieldX, position.fieldZ)
    local surfaceOpts = {
      localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
      localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
      currentY = position.worldY or actor.worldY,
    } ---@type FieldActorSurfaceOptions
    if position.worldY == nil then
      surfaceOpts.currentSurfaceId = actor.surfaceId
    end
    sample = SurfaceResolver.new(entry.runtimeMap.terrain):resolve(surfaceOpts)
    world = FieldCoordinates.fieldToWorld(entry.runtimeMap, position.fieldX, position.fieldZ, sample.worldY)
    plate = assert(entry.runtimeMap.terrain:plate(sample.surfaceId), "actor destination surface is missing")
    plateCellKey, sourceSurfaceId = sourceIdentityFromPlate(plate)
  end

  local newCandidate = sample
      and {
        fieldX = position.fieldX,
        fieldZ = position.fieldZ,
        surfaceId = sample.surfaceId,
        cellKey = plateCellKey,
        sourceSurfaceId = sourceSurfaceId,
      }
    or nil
  if newCandidate and newCandidate.sourceSurfaceId ~= nil then
    assert(newCandidate.cellKey ~= nil, "actor destination source surface requires a cell key")
  end
  local newKey = newCandidate and entry.occupancy:key(newCandidate) or nil
  local oldKey
  if actor.resident and actor.solid then
    oldKey = entry.occupancy:key(candidateForActor(actor))
  end
  local scripted = options ~= nil and options.scripted == true
  if resident and actor.solid and newKey and oldKey ~= newKey then
    local occupant = entry.occupancy:winnerByKey(newKey)
    if occupant ~= nil and not scripted then
      Errors.raise(
        FieldErrors.ACTOR_OCCUPANCY_CONFLICT,
        actorId .. " cannot move onto " .. occupant.actorId .. "'s field cell",
        {
          actorId = actorId,
          otherActorId = occupant.actorId,
          mapId = actor.mapId,
          fieldX = position.fieldX,
          fieldZ = position.fieldZ,
          surfaceId = sample.surfaceId,
        }
      )
    end
  end
  publishResolvedPosition(entry, actor, {
    fieldX = position.fieldX,
    fieldZ = position.fieldZ,
    worldY = sample and sample.worldY or nil,
    worldX = world and world.x or nil,
    worldZ = world and world.z or nil,
    surfaceId = sample and sample.surfaceId or nil,
    cellKey = plateCellKey or cellKey,
    sourceSurfaceId = sourceSurfaceId,
    resident = resident,
  })
end

---@param actorId string
---@param self FieldActorManager
function FieldActorManager:show(actorId)
  local actor = requireActor(self, actorId)
  actor:setVisible(true)
end

---@param actorId string
---@param self FieldActorManager
function FieldActorManager:hide(actorId)
  local actor = requireActor(self, actorId)
  actor:setVisible(false)
end

---@param actorId string
---@param movementType string
---@param self FieldActorManager
function FieldActorManager:setMovementType(actorId, movementType)
  local actor = requireActor(self, actorId)
  assert(FieldObjectMovement.isType(movementType), "unknown field object movement type " .. tostring(movementType))
  local entry = assert(self.maps[actor.mapId], "actor map entry missing")
  if entry.autonomousActions[actorId] ~= nil then
    self.autonomy:setMovementType(actorId, movementType, true)
    return
  end
  actor.movementType = movementType
  self.autonomy:setMovementType(actorId, movementType)
end

function FieldActorManager:isPausable(actorId)
  local actor = self:getById(actorId)
  if actor == nil then
    return true
  end
  local entry = assert(self.maps[actor.mapId], "actor map entry missing")
  return entry.autonomousActions[actorId] == nil
end

function FieldActorManager:allPausable()
  for _, entry in pairs(self.maps) do
    for actorId in pairs(entry.autonomousActions) do
      if not self:isPausable(actorId) then
        return false
      end
    end
  end
  return true
end

---@param actorId string
---@param self FieldActorManager
---@return boolean
function FieldActorManager:isVisible(actorId)
  local actor = self:getById(actorId)
  if actor == nil then
    Errors.raise(ScriptErrors.SCRIPT_ACTOR_NOT_FOUND, "no live actor " .. tostring(actorId), { actor = actorId })
  end
  assert(actor ~= nil)
  return actor.visible ~= false
end

-- Scripted pause_animation/resume_animation: the actor's pose clock stops
-- advancing while paused (the manager's fixed-tick step honors the flag).
---@param actorId string
---@param paused boolean
---@param self FieldActorManager
function FieldActorManager:setAnimationPaused(actorId, paused)
  local actor = requireActor(self, actorId)
  actor.animationPaused = paused == true
end

---@param actorId string
---@param offset { x: number, y: number, z: number }
---@param self FieldActorManager
function FieldActorManager:setPresentationOffset(actorId, offset)
  local actor = requireActor(self, actorId)
  assert(
    type(offset) == "table" and type(offset.x) == "number" and type(offset.y) == "number" and type(offset.z) == "number",
    "presentation offset requires x,y,z"
  )
  if offset.x ~= offset.x or offset.y ~= offset.y or offset.z ~= offset.z then
    Errors.raise(FieldErrors.ACTOR_FACING_INVALID, "presentation offset must be finite", { actorId = actorId })
  end
  if
    offset.x == math.huge
    or offset.x == -math.huge
    or offset.y == math.huge
    or offset.y == -math.huge
    or offset.z == math.huge
    or offset.z == -math.huge
  then
    Errors.raise(FieldErrors.ACTOR_FACING_INVALID, "presentation offset must be finite", { actorId = actorId })
  end
  actor.presentationOffset.x = offset.x
  actor.presentationOffset.y = offset.y
  actor.presentationOffset.z = offset.z
end

---@param actorId string
---@param self FieldActorManager
function FieldActorManager:clearPresentationOffset(actorId)
  self:setPresentationOffset(actorId, { x = 0, y = 0, z = 0 })
end

-- --- Scripted motion presentation (manager owns occupancy/terrain) -------

-- Resolve destination for a scripted action without mutating actor or
-- occupancy. Returns start/dest world anchors.
---@param actor FieldActorManager.Actor
---@param direction FieldDirection?
---@param distance string?
---@param self FieldActorManager
---@return table<string, unknown> destination
function FieldActorManager:_resolveScriptedDestination(actor, direction, distance)
  local entry = assert(self.maps[actor.mapId], "actor map entry missing")
  local deltaMap = {
    north = { fieldX = 0, fieldZ = -1 },
    south = { fieldX = 0, fieldZ = 1 },
    west = { fieldX = -1, fieldZ = 0 },
    east = { fieldX = 1, fieldZ = 0 },
  }
  local startFieldX, startFieldZ = actor.fieldX, actor.fieldZ
  local startWorldX, startWorldY, startWorldZ = actor.worldX, actor.worldY, actor.worldZ
  local destFieldX, destFieldZ = startFieldX, startFieldZ
  local destWorldX, destWorldY, destWorldZ = startWorldX, startWorldY, startWorldZ
  local destSurfaceId = actor.surfaceId
  local destCellKey = actor.cellKey
  local destSourceSurfaceId = actor.sourceSurfaceId
  local destResident = actor.resident
  if direction ~= nil and distance ~= "zero" then
    local delta = assert(deltaMap[direction], "unknown direction " .. tostring(direction))
    local step = 1
    if distance ~= nil then
      step = MovementCalibration.jumpTiles(distance)
    end
    destFieldX = startFieldX + delta.fieldX * step
    destFieldZ = startFieldZ + delta.fieldZ * step
    -- Resolve surface at destination center.
    local localX, localZ = FieldCoordinates.fieldToLocal(entry.runtimeMap, destFieldX, destFieldZ)
    local sample = SurfaceResolver.new(entry.runtimeMap.terrain):resolve({
      localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
      localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
      currentY = actor.worldY,
      currentSurfaceId = actor.surfaceId,
    })
    local world = FieldCoordinates.fieldToWorld(entry.runtimeMap, destFieldX, destFieldZ, sample.worldY)
    destWorldX, destWorldY, destWorldZ = world.x, world.y, world.z
    destSurfaceId = sample.surfaceId
    local plate = assert(entry.runtimeMap.terrain:plate(sample.surfaceId), "scripted destination surface is missing")
    destCellKey, destSourceSurfaceId = sourceIdentityFromPlate(plate)
    destCellKey = destCellKey or cellKeyFor(destFieldX, destFieldZ)
    destResident = isResident(entry.runtimeMap, destFieldX, destFieldZ)
  elseif direction ~= nil and distance == "zero" then
    -- zero jump stays on same tile; no surface change.
    destFieldX, destFieldZ = startFieldX, startFieldZ
    destWorldX, destWorldY, destWorldZ = startWorldX, startWorldY, startWorldZ
    destSurfaceId = actor.surfaceId
  end
  return {
    start = {
      fieldX = startFieldX,
      fieldZ = startFieldZ,
      worldX = startWorldX,
      worldY = startWorldY,
      worldZ = startWorldZ,
      surfaceId = actor.surfaceId,
      cellKey = actor.cellKey,
      sourceSurfaceId = actor.sourceSurfaceId,
      resident = actor.resident,
    },
    dest = {
      fieldX = destFieldX,
      fieldZ = destFieldZ,
      worldX = destWorldX,
      worldY = destWorldY,
      worldZ = destWorldZ,
      surfaceId = destSurfaceId,
      cellKey = destCellKey or cellKeyFor(destFieldX, destFieldZ),
      sourceSurfaceId = destSourceSurfaceId,
      resident = destResident,
    },
  }
end

---@param actor FieldActorManager.Actor
---@param deltaX integer
---@param deltaZ integer
---@param surfaceBandDelta integer
---@param self FieldActorManager
---@return table<string, unknown> destination
function FieldActorManager:_resolveTrajectoryDestination(actor, deltaX, deltaZ, surfaceBandDelta)
  assert(type(deltaX) == "number" and deltaX % 1 == 0, "trajectory deltaX must be an integer")
  assert(type(deltaZ) == "number" and deltaZ % 1 == 0, "trajectory deltaZ must be an integer")
  assert(
    type(surfaceBandDelta) == "number" and surfaceBandDelta % 1 == 0,
    "trajectory surfaceBandDelta must be an integer"
  )
  local entry = assert(self.maps[actor.mapId], "actor map entry missing")
  local startFieldX, startFieldZ = actor.fieldX, actor.fieldZ
  local startWorldX, startWorldY, startWorldZ = actor.worldX, actor.worldY, actor.worldZ
  local destFieldX = startFieldX + deltaX
  local destFieldZ = startFieldZ + deltaZ
  local destResident = isResident(entry.runtimeMap, destFieldX, destFieldZ)
  local hintWorldY = (startWorldY or 0) + surfaceBandDelta * 0.5
  local localX, localZ = FieldCoordinates.fieldToLocal(entry.runtimeMap, destFieldX, destFieldZ)
  local sample = SurfaceResolver.new(entry.runtimeMap.terrain):resolve({
    localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
    localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
    currentY = hintWorldY,
  })
  local world = FieldCoordinates.fieldToWorld(entry.runtimeMap, destFieldX, destFieldZ, sample.worldY)
  local plate = assert(entry.runtimeMap.terrain:plate(sample.surfaceId), "trajectory destination surface is missing")
  local destCellKey, destSourceSurfaceId = sourceIdentityFromPlate(plate)
  destCellKey = destCellKey or cellKeyFor(destFieldX, destFieldZ)
  return {
    start = {
      fieldX = startFieldX,
      fieldZ = startFieldZ,
      worldX = startWorldX,
      worldY = startWorldY,
      worldZ = startWorldZ,
      surfaceId = actor.surfaceId,
      cellKey = actor.cellKey,
      sourceSurfaceId = actor.sourceSurfaceId,
      resident = actor.resident,
    },
    dest = {
      fieldX = destFieldX,
      fieldZ = destFieldZ,
      worldX = world.x,
      worldY = world.y,
      worldZ = world.z,
      surfaceId = sample.surfaceId,
      cellKey = destCellKey,
      sourceSurfaceId = destSourceSurfaceId,
      resident = destResident,
    },
  }
end

---@param actorId string
---@param action table<string, unknown>
---@param self FieldActorManager
function FieldActorManager:beginScriptedAction(actorId, action)
  local actor = requireActor(self, actorId)
  local entry = assert(self.maps[actor.mapId], "actor map entry missing")
  entry.autonomousPresentationCarry[actorId] = nil
  local autonomousAction = entry.autonomousActions[actorId]
  if autonomousAction then
    local reservation = assert(entry.occupancy:reservationByKey(autonomousAction.reservationKey))
    entry.occupancy:cancelReservation(reservation.candidate, actorId)
    entry.autonomousActions[actorId] = nil
    actor:cancelAction()
    self.autonomy:applyPendingMovementType(actorId)
    actor.movementType = self.autonomy:state(actorId).movementType
  end
  local kind = action.action
  -- Face is instantaneous: apply the facing directly, then still flow
  -- through the generic actor transaction below (with a stay-put start/dest).
  -- Face uses the explicit static presentation transition while delay and
  -- emote retain the actor's selected locomotion presentation.
  if kind == "face" and action.direction ~= nil then
    actor:setFacing(action.direction)
  end
  local direction = action.direction
  local distance = action.distance
  local speed = action.speed
  local durationTicks
  if
    kind == "walk"
    or kind == "walk_in_place"
    or kind == "jump"
    or kind == "face"
    or kind == "delay"
    or kind == "emote"
    or kind == "gesture"
    or kind == "reveal_trainer"
    or kind == "trajectory_segment"
  then
    durationTicks = MovementCalibration.actionTicks(action)
  else
    Errors.raise(
      ScriptErrors.SCRIPT_UNSUPPORTED_REACHABLE,
      "unsupported scripted action " .. tostring(kind),
      { actor = actorId }
    )
  end
  local destInfo
  if kind == "walk" then
    destInfo = self:_resolveScriptedDestination(actor, direction, nil)
  elseif kind == "jump" then
    destInfo = self:_resolveScriptedDestination(actor, direction, distance)
  elseif kind == "trajectory_segment" then
    destInfo = self:_resolveTrajectoryDestination(actor, action.deltaX, action.deltaZ, action.surfaceBandDelta)
  elseif
    kind == "walk_in_place"
    or kind == "face"
    or kind == "delay"
    or kind == "emote"
    or kind == "gesture"
    or kind == "reveal_trainer"
  then
    destInfo = {
      start = {
        fieldX = actor.fieldX,
        fieldZ = actor.fieldZ,
        worldX = actor.worldX,
        worldY = actor.worldY,
        worldZ = actor.worldZ,
        surfaceId = actor.surfaceId,
        cellKey = actor.cellKey,
        sourceSurfaceId = actor.sourceSurfaceId,
        resident = actor.resident,
      },
      dest = {
        fieldX = actor.fieldX,
        fieldZ = actor.fieldZ,
        worldX = actor.worldX,
        worldY = actor.worldY,
        worldZ = actor.worldZ,
        surfaceId = actor.surfaceId,
        cellKey = actor.cellKey,
        sourceSurfaceId = actor.sourceSurfaceId,
        resident = actor.resident,
      },
    }
  end
  actor:beginScriptedAction({
    action = kind,
    direction = direction,
    distance = distance,
    speed = speed,
    deltaX = action.deltaX,
    deltaZ = action.deltaZ,
    surfaceBandDelta = action.surfaceBandDelta,
    ticks = action.ticks,
    start = destInfo.start,
    dest = destInfo.dest,
    durationTicks = durationTicks,
    -- The decoded semantic emote kind (e.g. "exclamation"); only meaningful
    -- when kind == "emote".
    name = action.name,
  })
end

---@param actorId string
---@param progressTicks integer
---@param durationTicks integer
---@param self FieldActorManager
function FieldActorManager:advanceScriptedAction(actorId, progressTicks, durationTicks)
  local actor = requireActor(self, actorId)
  actor:advanceScriptedAction(progressTicks, durationTicks)
end

---@param actorId string
---@param self FieldActorManager
function FieldActorManager:commitScriptedAction(actorId)
  local actor = requireActor(self, actorId)
  local m = actor:scriptedMotionState()
  if not m then
    return
  end
  local entry = assert(self.maps[actor.mapId], "actor map entry missing")
  local destination =
    assert(actor:commitScriptedAction() --[[@as FieldActorResolvedPosition]], "scripted action destination is missing")
  publishResolvedPosition(entry, actor, destination)
end

---@param actorId string
---@param self FieldActorManager
function FieldActorManager:cancelScriptedMovement(actorId)
  local actor = self:getById(actorId)
  if actor == nil then
    return
  end
  if actor:isScriptedMoving() then
    actor:cancelScriptedAction()
  else
    -- Also settle any fractional world drift: recompute world from committed tile.
    local entry = self.maps[actor.mapId]
    if entry then
      local world = FieldCoordinates.fieldToWorld(entry.runtimeMap, actor.fieldX, actor.fieldZ, actor.worldY)
      actor.worldX = world.x
      actor.worldZ = world.z
      -- worldY stays as committed surface height; actor.worldY already correct.
      actor:beginFixedStep()
    end
  end
end

---@param actorId string
---@return boolean
---@param self FieldActorManager
function FieldActorManager:isScriptedMoving(actorId)
  local actor = self:getById(actorId)
  if actor == nil then
    return false
  end
  return actor:isScriptedMoving()
end

-- The numeric local map-object index of one actor (the pinned HGSS object
-- id), used by trigger comparisons.
---@param actorId string
---@return integer?
---@param self FieldActorManager
function FieldActorManager:numericId(actorId)
  local actor = self:getById(actorId)
  return actor and actor.objectEventId or nil
end

-- Resolve a numeric local map-object index to the current map's actor id
-- (the pinned HGSS object-id path used by `S.actorIndex(n)`); nil when the
-- current map has no such object.
---@param index integer
---@return string|nil
---@param self FieldActorManager
function FieldActorManager:actorIdForMapIndex(index)
  local entry = self.currentMapId ~= nil and self.maps[self.currentMapId] or nil
  return entry and entry.store:getActorByIndex(index) or nil
end

-- The field camera target (pinned HGSS object id 241) of the current map;
-- nil when the map declares no camera target.
---@return string|nil
---@param self FieldActorManager
function FieldActorManager:cameraTargetId()
  return self:actorIdForMapIndex(CAMERA_TARGET_OBJECT_ID)
end

-- The walking partner (pinned HGSS object id 253) of the current map; nil
-- while no Pokémon follows the player.
---@return string|nil
---@param self FieldActorManager
function FieldActorManager:partnerId()
  return self:actorIdForMapIndex(PARTNER_OBJECT_ID)
end

---@param self FieldActorManager
function FieldActorManager:dispose()
  local mapIds = {}
  for mapId in pairs(self.maps) do
    mapIds[#mapIds + 1] = mapId
  end
  for _, mapId in ipairs(mapIds) do
    self:leaveMap(mapId)
  end
  if self.unsubscribe then
    self.unsubscribe()
  end
  self.unsubscribe, self.eventState = nil, nil
  self.pendingFlags = {}
end

return FieldActorManager
