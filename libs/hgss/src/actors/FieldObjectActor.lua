-- One runtime map object. The decoded zone-event record stays immutable source
-- data; every value the runtime may change (facing, pose clock, visibility)
-- lives on the actor, mirroring pret/pokeheartgold's split between the event
-- record and the `MapObject` it constructs. Actors are static:
-- Semantic movement is resolved by the generated field-data contract. Pure
-- domain module.
--
-- Dense mutable numeric/boolean state (positions, surfaces, clocks, offsets,
-- residency/visibility/solidity) lives in one store-owned cdata record
-- addressed by a stable storage slot. The record is the single authority:
-- no moved value is mirrored on the Lua table. Symbolic state (facing, pose,
-- cell keys, motion transactions, overrides) stays Lua-side.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldActorPose = require("libs.hgss.src.presentation.FieldActorPose")
local MovementCalibration = require("libs.hgss.src.script.tasks.MovementCalibration")

---@class FieldObjectActor
---@field actorId string
---@field mapId integer
---@field objectEventId integer
---@field sourceEvent table<string, unknown>
---@field spriteId integer
---@field cellKey string?
---@field initialFacing FieldDirection
---@field facing FieldDirection
---@field pose string
---@field private _visual table<string, unknown>
---@field private _idlePresentation { mode: "static"|"animated", cadence: integer }
---@field private _gesturePose string?
---@field activeEmoteKind string? the active semantic emote (e.g. "exclamation") while an emote action is live, else nil
---@field movementType string
---@field private _numericStore FieldActorStore numeric storage owner (the actor's FieldActorStore)
---@field private _numericSlot integer stable storage slot, independent of manager slots
---@field interactionFacingOverride { owner: string, facing: FieldDirection, restoreFacing: FieldDirection }?
---@field pushFacingOverride fun(self: FieldObjectActor, request: { owner: string, facing: FieldDirection }): table<string, unknown>
---@field releaseFacingOverride fun(self: FieldObjectActor, token: table<string, unknown>)
---@field clearFacingOverride fun(self: FieldObjectActor)
---@field beginAction fun(self: FieldObjectActor, descriptor: table<string, unknown>, owner: "script"|"autonomous")
---@field beginFixedStep fun(self: FieldObjectActor) snapshot the current world point for host-frame sampling
---@field renderPosition fun(self: FieldObjectActor, alpha: number?): { x: number?, y: number?, z: number? }
---@field advanceAction fun(self: FieldObjectActor, progressTicks: integer, durationTicks: integer)
---@field reprojectActiveAction fun(self: FieldObjectActor, start: FieldObjectActor.ActionEndpoint, destination: FieldObjectActor.ActionEndpoint)
---@field commitAction fun(self: FieldObjectActor): table<string, unknown>?
---@field cancelAction fun(self: FieldObjectActor)
---@field beginScriptedAction fun(self: FieldObjectActor, descriptor: table<string, unknown>)
---@field advanceScriptedAction fun(self: FieldObjectActor, progressTicks: integer, durationTicks: integer)
---@field commitScriptedAction fun(self: FieldObjectActor): table<string, unknown>?
---@field cancelScriptedAction fun(self: FieldObjectActor)
---@field isScriptedMoving fun(self: FieldObjectActor): boolean
---@field advancePresentationTick fun(self: FieldObjectActor)
---@field settlePresentation fun(self: FieldObjectActor)
---@field currentAction fun(self: FieldObjectActor): string?
---@field presentationState fun(self: FieldObjectActor): FieldObjectActor.PresentationState
---@field scriptedMotionState fun(self: FieldObjectActor): table<string, unknown>?
---@field setFacing fun(self: FieldObjectActor, direction: FieldDirection)
---@field setVisible fun(self: FieldObjectActor, visible: boolean)
---@field setPosition fun(self: FieldObjectActor, position: { fieldX: integer, fieldZ: integer, worldY: number?, worldX: number?, worldZ: number?, surfaceId: integer?, cellKey: string?, sourceSurfaceId: integer?, resident: boolean })
---@field numericState fun(self: FieldObjectActor): G4FieldActorNumeric
---@field numericSlot fun(self: FieldObjectActor): integer
---@field isResident fun(self: FieldObjectActor): boolean
---@field isVisible fun(self: FieldObjectActor): boolean
---@field isSolid fun(self: FieldObjectActor): boolean
---@field isAnimationPaused fun(self: FieldObjectActor): boolean
---@field getPoseTick fun(self: FieldObjectActor): integer
---@field getSurfaceId fun(self: FieldObjectActor): integer?
---@field getSourceSurfaceId fun(self: FieldObjectActor): integer?
---@field getFieldPosition fun(self: FieldObjectActor): { fieldX: integer, fieldZ: integer }
---@field getWorldPosition fun(self: FieldObjectActor): { x: number?, y: number?, z: number? }
---@field getPresentationOffset fun(self: FieldObjectActor): { x: number, y: number, z: number }
---@field setAnimationPaused fun(self: FieldObjectActor, paused: boolean)
---@field setPresentationOffset fun(self: FieldObjectActor, x: number, y: number, z: number)
---@field renderPositionInto fun(self: FieldObjectActor, out: { x: number?, y: number?, z: number? }, alpha: number?): { x: number?, y: number?, z: number? }

local FieldObjectActor = {}
FieldObjectActor.__index = FieldObjectActor

---@class FieldObjectActor.PresentationState
---@field gesturePose string?
---@field gestureTick integer?
---@field gestureOffsetY number

-- A resolved action endpoint in the current physical frame: stable logical
-- field coordinates plus the frame's world/surface projection. Coverage
-- recentering rebuilds the projection while the logical identity survives.
---@class FieldObjectActor.ActionEndpoint
---@field fieldX integer
---@field fieldZ integer
---@field worldX number?
---@field worldY number?
---@field worldZ number?
---@field surfaceId integer?
---@field cellKey string?
---@field sourceSurfaceId integer?
---@field resident boolean?

local FACINGS = { north = true, south = true, west = true, east = true }

-- Walk-in-place bob amplitude, in world units (source-presentation scale,
-- applied before any host/camera transform). Two footstep bounces per cycle.
local WALK_IN_PLACE_BOB_AMPLITUDE = 0.15

local function isLocomotionAction(action)
  return action == "walk" or action == "walk_in_place" or action == "jump" or action == "trajectory_segment"
end

-- Render-only vertical bob for a walk-in-place cycle, derived deterministically
-- from the action's own fixed progress/duration ticks (never from draw
-- frequency). Two bounded bounces per cycle, zero at both boundaries.
---@param progressTicks integer
---@param durationTicks integer
---@return number
local function walkInPlaceBobOffset(progressTicks, durationTicks)
  if durationTicks <= 0 then
    return 0
  end
  local t = progressTicks / durationTicks
  return (WALK_IN_PLACE_BOB_AMPLITUDE / 2) * (1 - math.cos(4 * math.pi * t))
end

local function requireIdlePresentation(visual, idlePresentation)
  assert(type(visual) == "table", "field actor visual is required")
  assert(type(idlePresentation) == "table", "field actor idle presentation is required")
  assert(idlePresentation.mode == "static" or idlePresentation.mode == "animated", "field actor idle mode is invalid")
  assert(
    type(idlePresentation.cadence) == "number" and idlePresentation.cadence % 1 == 0,
    "field actor idle cadence is invalid"
  )
  assert(
    (idlePresentation.mode == "static" and idlePresentation.cadence == 0)
      or (idlePresentation.mode == "animated" and idlePresentation.cadence == 1),
    "field actor idle cadence does not match its mode"
  )
end

-- Writes a world point into the record. The point is all-or-nothing: a fully
-- absent point clears presence, a fully present point sets it. Mixed points
-- never occur on current construction/placement/action paths.
local function setWorld(state, x, y, z)
  if x == nil and y == nil and z == nil then
    state.hasWorldPosition = 0
    state.worldX, state.worldY, state.worldZ = 0, 0, 0
    return
  end
  assert(x ~= nil and y ~= nil and z ~= nil, "field actor world position must be all present or all absent")
  state.worldX, state.worldY, state.worldZ = x, y, z
  state.hasWorldPosition = 1
end

local function setPreviousWorld(state, x, y, z)
  if x == nil and y == nil and z == nil then
    state.hasPreviousWorldPosition = 0
    state.previousWorldX, state.previousWorldY, state.previousWorldZ = 0, 0, 0
    return
  end
  assert(x ~= nil and y ~= nil and z ~= nil, "field actor previous world position must be all present or all absent")
  state.previousWorldX, state.previousWorldY, state.previousWorldZ = x, y, z
  state.hasPreviousWorldPosition = 1
end

local function setSurfaceId(state, surfaceId)
  if surfaceId == nil then
    state.hasSurfaceId = 0
    state.surfaceId = 0
    return
  end
  state.surfaceId = surfaceId
  state.hasSurfaceId = 1
end

local function setSourceSurfaceId(state, sourceSurfaceId)
  if sourceSurfaceId == nil then
    state.hasSourceSurfaceId = 0
    state.sourceSurfaceId = 0
    return
  end
  state.sourceSurfaceId = sourceSurfaceId
  state.hasSourceSurfaceId = 1
end

local function setGestureTick(state, gestureTick)
  if gestureTick == nil then
    state.hasGestureTick = 0
    state.gestureTick = 0
    return
  end
  state.gestureTick = gestureTick
  state.hasGestureTick = 1
end

local function applyIdlePresentation(actor, advance)
  local state = actor:_numeric()
  local idlePresentation = actor._idlePresentation
  if advance and idlePresentation.mode == "animated" and state.animationPaused == 0 then
    state.poseTick = state.poseTick + idlePresentation.cadence
  end
  actor.pose = "idle"
  local pose = FieldActorPose.select(actor._visual, actor.facing, "idle")
  local segment = FieldActorPose.sampleAt(pose, state.poseTick)
  state.presentationOffsetY = assert(segment.displayOffsetY, "field actor idle segment has no display offset")
end

-- Identity is derived only from map and object-event identity, so it survives
-- array reordering, coordinate changes, and repeated map entry.
function FieldObjectActor.actorId(mapId, objectEventId)
  return string.format("map:%d:object:%d", mapId, objectEventId)
end

local function requireFacing(facing, context)
  if FACINGS[facing] then
    return facing
  end
  Errors.raise(FieldErrors.ACTOR_FACING_INVALID, "unsupported actor facing " .. tostring(facing), context)
end

function FieldObjectActor.new(opts)
  assert(type(opts) == "table" and type(opts.sourceEvent) == "table", "FieldObjectActor requires a source event")
  requireIdlePresentation(opts.visual, opts.idlePresentation)
  assert(opts.numericStore ~= nil, "FieldObjectActor requires a numeric storage owner")
  assert(
    type(opts.numericSlot) == "number" and opts.numericSlot % 1 == 0 and opts.numericSlot >= 0,
    "FieldObjectActor requires a numeric storage slot"
  )
  local event = opts.sourceEvent
  local actorId = FieldObjectActor.actorId(opts.mapId, event.objectEventId)
  local facing =
    requireFacing(event.facingDirection, { actorId = actorId, facingDirectionRaw = event.facingDirectionRaw })

  local actor = setmetatable({
    actorId = actorId,
    mapId = opts.mapId,
    objectEventId = event.objectEventId,
    sourceEvent = event,
    -- The runtime sprite: the zone-event value unless the creator resolved a
    -- variable sprite through the field vars (the source record stays raw).
    spriteId = opts.spriteId or event.spriteId,
    cellKey = opts.cellKey,
    initialFacing = facing,
    facing = facing,
    pose = "idle",
    _visual = opts.visual,
    _idlePresentation = opts.idlePresentation,
    _gesturePose = nil,
    activeEmoteKind = nil,
    movementType = assert(event.movementType, "field actor movement type is required"),
    interactionFacingOverride = nil,
    _numericStore = opts.numericStore,
    _numericSlot = opts.numericSlot,
  }, FieldObjectActor)
  local state = actor:_numeric()
  state.fieldX = opts.fieldX
  state.fieldZ = opts.fieldZ
  setWorld(state, opts.worldX, opts.worldY, opts.worldZ)
  if state.hasWorldPosition == 1 then
    setPreviousWorld(state, opts.worldX, opts.worldY, opts.worldZ)
  else
    setPreviousWorld(state, nil, nil, nil)
  end
  setSourceSurfaceId(state, opts.sourceSurfaceId)
  setSurfaceId(state, opts.surfaceId)
  state.poseTick = 0
  setGestureTick(state, nil)
  state.gestureOffsetY = 0
  -- Render-only locomotion presentation offset (walk-in-place bob); never
  -- mutates worldX/worldY/worldZ, which stay the logical/committed anchor.
  state.presentationOffsetX, state.presentationOffsetY, state.presentationOffsetZ = 0, 0, 0
  state.resident = opts.resident == true and 1 or 0
  state.visible = 1
  -- Solid unless the source/generated event explicitly says otherwise; a
  -- zero interaction-script id is only "no A-button script" and carries no
  -- collision meaning of its own.
  state.solid = opts.solid ~= false and 1 or 0
  state.animationPaused = 0
  state.scriptedPresentationAdvanced = 0
  return actor
end

-- Resolves the actor's live numeric record. The result is valid only for
-- immediate use within the current operation: buffer growth replaces the
-- backing array, so never retain it across a call that may create or remove
-- actors.
function FieldObjectActor:_numeric()
  return self._numericStore:numericState(self._numericSlot)
end

-- Immediate non-retained access to the authoritative numeric record for hot
-- manager internals. Non-hot consumers use the grouped/scalar observations.
---@return G4FieldActorNumeric
function FieldObjectActor:numericState()
  return self:_numeric()
end

-- The actor's stable storage slot, independent of manager slots.
---@return integer
function FieldObjectActor:numericSlot()
  return self._numericSlot
end

---@return boolean
function FieldObjectActor:isResident()
  return self:_numeric().resident == 1
end

---@return boolean
function FieldObjectActor:isVisible()
  return self:_numeric().visible == 1
end

---@return boolean
function FieldObjectActor:isSolid()
  return self:_numeric().solid == 1
end

---@return boolean
function FieldObjectActor:isAnimationPaused()
  return self:_numeric().animationPaused == 1
end

---@return integer
function FieldObjectActor:getPoseTick()
  return self:_numeric().poseTick
end

---@return integer?
function FieldObjectActor:getSurfaceId()
  local state = self:_numeric()
  if state.hasSurfaceId == 0 then
    return nil
  end
  return state.surfaceId
end

---@return integer?
function FieldObjectActor:getSourceSurfaceId()
  local state = self:_numeric()
  if state.hasSourceSurfaceId == 0 then
    return nil
  end
  return state.sourceSurfaceId
end

---@return { fieldX: integer, fieldZ: integer }
function FieldObjectActor:getFieldPosition()
  local state = self:_numeric()
  return { fieldX = state.fieldX, fieldZ = state.fieldZ }
end

-- The current logical world point. Nil coordinates (a nonresident actor) read
-- back as absent rather than manufacturing a point.
---@return { x: number?, y: number?, z: number? }
function FieldObjectActor:getWorldPosition()
  local state = self:_numeric()
  if state.hasWorldPosition == 0 then
    return { x = nil, y = nil, z = nil }
  end
  return { x = state.worldX, y = state.worldY, z = state.worldZ }
end

---@return { x: number, y: number, z: number }
function FieldObjectActor:getPresentationOffset()
  local state = self:_numeric()
  return { x = state.presentationOffsetX, y = state.presentationOffsetY, z = state.presentationOffsetZ }
end

-- Scripted pause_animation/resume_animation state on the actor. The manager's
-- fixed-tick step honors the flag; use the manager seam for scripted pauses.
---@param paused boolean
function FieldObjectActor:setAnimationPaused(paused)
  self:_numeric().animationPaused = paused == true and 1 or 0
end

-- Render-only offset set by presentation tooling. See setPresentationOffset on
-- the manager for the validated scripted path.
---@param x number
---@param y number
---@param z number
function FieldObjectActor:setPresentationOffset(x, y, z)
  local state = self:_numeric()
  state.presentationOffsetX, state.presentationOffsetY, state.presentationOffsetZ = x, y, z
end

-- Temporary facing owned by an interaction client. Only one override may be
-- live: a foreign owner must not be able to silently take or drop another's.
function FieldObjectActor:pushFacingOverride(request)
  assert(type(request) == "table" and type(request.owner) == "string", "a facing override requires an owner")
  local actorId = self.actorId --[[@as string]]
  if self.interactionFacingOverride then
    Errors.raise(
      FieldErrors.ACTOR_OVERRIDE_OWNER_MISMATCH,
      "actor " .. actorId .. " already has a facing override owned by " .. self.interactionFacingOverride.owner,
      { actorId = actorId, owner = self.interactionFacingOverride.owner, requestedBy = request.owner }
    )
  end
  local token = {
    owner = request.owner,
    facing = requireFacing(request.facing, { actorId = actorId }),
    restoreFacing = self.facing,
  }
  self.interactionFacingOverride = token
  self.facing = token.facing
  return token
end

function FieldObjectActor:releaseFacingOverride(token)
  if self.interactionFacingOverride == nil or self.interactionFacingOverride ~= token then
    local actorId = self.actorId --[[@as string]]
    Errors.raise(
      FieldErrors.ACTOR_OVERRIDE_OWNER_MISMATCH,
      "released a facing override that actor " .. actorId .. " does not hold",
      { actorId = actorId }
    )
  end
  self.facing = token.restoreFacing
  self.interactionFacingOverride = nil
end

-- Unwind path for hide, map exit, and state disposal: drops whatever override
-- is live without needing its token, and is safe to call when none is.
function FieldObjectActor:clearFacingOverride()
  local token = self.interactionFacingOverride
  if not token then
    return
  end
  self.facing = token.restoreFacing
  self.interactionFacingOverride = nil
end

-- --- Host-frame sampling -------------------------------------------

-- Collapse the sampled baseline onto the current world point after a
-- discontinuous placement, so the next host draw never blends across the gap.
local function collapseRenderBaseline(actor)
  local state = actor:_numeric()
  if state.hasWorldPosition == 1 then
    setPreviousWorld(state, state.worldX, state.worldY, state.worldZ)
  else
    setPreviousWorld(state, nil, nil, nil)
  end
end

-- Snapshot the current world point once per fixed simulation tick, before any
-- movement in that tick can mutate it. Draws between fixed ticks then sample
-- the previous/current pair through renderPosition.
function FieldObjectActor:beginFixedStep()
  collapseRenderBaseline(self)
end

-- Linear host-frame sample between the previous and current fixed-tick world
-- points, matching the player sampling contract. Nil coordinates (a
-- nonresident actor) read back as absent rather than manufacturing a point.
---@param alpha number?
---@return { x: number?, y: number?, z: number? }
function FieldObjectActor:renderPosition(alpha)
  return self:renderPositionInto({}, alpha)
end

-- In-place host-frame sample into a caller-owned table. The output table is
-- reused across calls; never retain it as historical state.
---@param out { x: number?, y: number?, z: number? }
---@param alpha number?
---@return { x: number?, y: number?, z: number? }
function FieldObjectActor:renderPositionInto(out, alpha)
  alpha = alpha == nil and 1 or math.max(0, math.min(1, alpha))
  local state = self:_numeric()
  if state.hasWorldPosition == 0 or state.hasPreviousWorldPosition == 0 then
    if state.hasWorldPosition == 0 then
      out.x, out.y, out.z = nil, nil, nil
    else
      out.x, out.y, out.z = state.worldX, state.worldY, state.worldZ
    end
    return out
  end
  local previousX, previousY, previousZ = state.previousWorldX, state.previousWorldY, state.previousWorldZ
  local currentX, currentY, currentZ = state.worldX, state.worldY, state.worldZ
  out.x = previousX + (currentX - previousX) * alpha
  out.y = previousY + (currentY - previousY) * alpha
  out.z = previousZ + (currentZ - previousZ) * alpha
  return out
end

-- --- Scripted motion presentation --------------------------------

-- Transient scripted motion state: committed anchor + in-progress presentation.
-- Occupancy stays on committed field until commit. Draw uses presentation
-- world while motion is active.

function FieldObjectActor:beginAction(descriptor, owner)
  assert(owner == "script" or owner == "autonomous", "field actor action owner is invalid")
  assert(self._motion == nil, "field actor already has an active action")
  -- descriptor: { action, direction, distance, speed, start, dest, durationTicks, name }
  -- `name` is the decoded semantic emote kind (e.g. "exclamation"); present
  -- only when action == "emote".
  local start = descriptor.start
  local dest = descriptor.dest
  local state = self:_numeric()
  self._motion = {
    owner = owner,
    action = descriptor.action,
    direction = descriptor.direction,
    distance = descriptor.distance,
    speed = descriptor.speed,
    durationTicks = descriptor.durationTicks,
    progressTicks = 0,
    startFieldX = start.fieldX,
    startFieldZ = start.fieldZ,
    startWorldX = start.worldX,
    startWorldY = start.worldY,
    startWorldZ = start.worldZ,
    startSurfaceId = start.surfaceId,
    startCellKey = start.cellKey,
    startSourceSurfaceId = start.sourceSurfaceId,
    startResident = start.resident == true,
    destFieldX = dest.fieldX,
    destFieldZ = dest.fieldZ,
    destWorldX = dest.worldX,
    destWorldY = dest.worldY,
    destWorldZ = dest.worldZ,
    destSurfaceId = dest.surfaceId,
    destCellKey = dest.cellKey,
    destSourceSurfaceId = dest.sourceSurfaceId,
    destResident = dest.resident == true,
    startPose = self.pose,
    startPoseTick = state.poseTick,
    gestureName = descriptor.name,
    startGesturePose = self._gesturePose,
    startGestureTick = state.hasGestureTick == 1 and state.gestureTick or nil,
    startGestureOffsetY = state.gestureOffsetY,
  }
  -- Every action transaction starts from a zero presentation offset; only
  -- walk_in_place's advance re-populates it while it is the active action.
  state.presentationOffsetX, state.presentationOffsetY, state.presentationOffsetZ = 0, 0, 0
  -- The emote indicator is active only for the action instance that carries
  -- it; every other action (including a later emote with a different kind)
  -- starts from a clean slate.
  self.activeEmoteKind = descriptor.action == "emote" and descriptor.name or nil
  -- Locomotion pose is true while a locomotion action is active. Face and
  -- gesture are explicit static presentation transitions; delays and emotes
  -- leave the current idle presentation unchanged.
  if descriptor.action == "gesture" then
    self._gesturePose = nil
    setGestureTick(state, nil)
    state.gestureOffsetY = 0
    self.pose = "idle"
    state.poseTick = 0
  elseif descriptor.action == "reveal_trainer" then
    self._gesturePose = nil
    setGestureTick(state, nil)
    state.gestureOffsetY = 0
    self.pose = "idle"
    state.poseTick = 0
  elseif isLocomotionAction(descriptor.action) then
    self._gesturePose = nil
    setGestureTick(state, nil)
    state.gestureOffsetY = 0
    if state.animationPaused == 0 then
      self.pose = "walk"
    end
  elseif descriptor.action == "face" then
    self._gesturePose = nil
    setGestureTick(state, nil)
    state.gestureOffsetY = 0
    self.pose = "idle"
    state.poseTick = 0
  end
end

function FieldObjectActor:beginScriptedAction(descriptor)
  self:beginAction(descriptor, "script")
end

-- Idempotent physical application of the active action at its stored
-- progress/duration: current world position plus the progress-derived
-- render-only offset. Pose, gesture, and idle clocks are presentation time
-- and stay in advanceAction; a coverage rebase shares only this helper so
-- reprojection never advances action time.
local function applyActionWorldPosition(actor, motion)
  local state = actor:_numeric()
  local progressTicks = motion.progressTicks
  local durationTicks = motion.durationTicks
  local t = durationTicks > 0 and (progressTicks / durationTicks) or 1
  if motion.action == "trajectory_segment" then
    if progressTicks >= durationTicks then
      setWorld(state, motion.destWorldX, motion.destWorldY, motion.destWorldZ)
    else
      local progress = MovementCalibration.trajectoryProgressAt(progressTicks, durationTicks)
      local worldX = motion.startWorldX + (motion.destWorldX - motion.startWorldX) * progress
      local worldZ = motion.startWorldZ + (motion.destWorldZ - motion.startWorldZ) * progress
      local baseY = motion.startWorldY + (motion.destWorldY - motion.startWorldY) * progress
      local arc = MovementCalibration.trajectoryArcAt(progressTicks, durationTicks)
      setWorld(state, worldX, baseY + arc, worldZ)
    end
  elseif motion.action == "walk" or motion.action == "jump" then
    local worldX = motion.startWorldX + (motion.destWorldX - motion.startWorldX) * t
    local worldZ = motion.startWorldZ + (motion.destWorldZ - motion.startWorldZ) * t
    if motion.action == "jump" then
      local offset = MovementCalibration.jumpOffsetAt(motion, progressTicks, durationTicks)
      local baseY = motion.startWorldY + (motion.destWorldY - motion.startWorldY) * t
      setWorld(state, worldX, baseY + offset, worldZ)
    else
      setWorld(state, worldX, motion.startWorldY + (motion.destWorldY - motion.startWorldY) * t, worldZ)
    end
  elseif motion.action == "walk_in_place" then
    -- No translation; keep at start anchor. The visible bob is a render-only
    -- offset derived deterministically from the fixed action tick, never
    -- written into worldY: terrain, camera, save, and collision all keep
    -- reading the unchanged anchor.
    setWorld(state, motion.startWorldX, motion.startWorldY, motion.startWorldZ)
    state.presentationOffsetY = walkInPlaceBobOffset(progressTicks, durationTicks)
  elseif motion.action == "reveal_trainer" then
    setWorld(state, motion.startWorldX, motion.startWorldY, motion.startWorldZ)
    state.presentationOffsetY = MovementCalibration.revealTrainerOffsetAt(progressTicks)
  elseif
    motion.action == "face"
    or motion.action == "delay"
    or motion.action == "emote"
    or motion.action == "gesture"
  then
    -- No translation.
    setWorld(state, motion.startWorldX, motion.startWorldY, motion.startWorldZ)
  end
  if progressTicks == durationTicks then
    if motion.action == "walk" or motion.action == "jump" or motion.action == "trajectory_segment" then
      setWorld(state, motion.destWorldX, motion.destWorldY, motion.destWorldZ)
    end
  end
end

function FieldObjectActor:advanceAction(progressTicks, durationTicks)
  local m = self._motion
  if not m then
    return
  end
  local state = self:_numeric()
  if m.owner == "script" then
    state.scriptedPresentationAdvanced = 1
  end
  m.progressTicks = progressTicks
  m.durationTicks = durationTicks
  applyActionWorldPosition(self, m)
  state = self:_numeric()
  if m.action == "gesture" then
    local presentation = MovementCalibration.gesturePresentationAt(m.gestureName, progressTicks, durationTicks)
    self._gesturePose = presentation.pose
    setGestureTick(state, presentation.poseTick)
    state.gestureOffsetY = presentation.offsetY
  end
  -- Advance pose clock once per eligible tick for active locomotion. A delay
  -- or emote owns its tick without inheriting a prior action: its presentation
  -- comes from the visual idle profile instead.
  if state.animationPaused == 0 then
    if isLocomotionAction(m.action) then
      local poseProgress = MovementCalibration.poseProgressTicks(m, progressTicks)
      self.pose = "walk"
      state.poseTick = m.startPoseTick + poseProgress
    end
  end
  if m.action == "delay" or m.action == "emote" then
    applyIdlePresentation(self, state.animationPaused == 0)
  end
end

-- Rebase the active action's physical endpoints into the current coverage
-- frame at unchanged progress. Only projection-dependent endpoint fields
-- move; owner, kind, progress, duration, and presentation origin state stay
-- untouched, and no presentation clock advances.
function FieldObjectActor:reprojectActiveAction(start, destination)
  local motion = assert(self._motion, "field actor has no active action to reproject")
  assert(motion.startFieldX == start.fieldX and motion.startFieldZ == start.fieldZ)
  assert(motion.destFieldX == destination.fieldX and motion.destFieldZ == destination.fieldZ)
  -- Replace projection-dependent endpoint fields only.
  motion.startWorldX = start.worldX
  motion.startWorldY = start.worldY
  motion.startWorldZ = start.worldZ
  motion.startSurfaceId = start.surfaceId
  motion.startCellKey = start.cellKey
  motion.startSourceSurfaceId = start.sourceSurfaceId
  motion.startResident = start.resident == true
  motion.destWorldX = destination.worldX
  motion.destWorldY = destination.worldY
  motion.destWorldZ = destination.worldZ
  motion.destSurfaceId = destination.surfaceId
  motion.destCellKey = destination.cellKey
  motion.destSourceSurfaceId = destination.sourceSurfaceId
  motion.destResident = destination.resident == true
  -- Recompute the current physical position at motion.progressTicks using the
  -- same idempotent helper used by advanceAction.
  applyActionWorldPosition(self, motion)
  -- A coverage rebase is a coordinate-frame discontinuity: the sampled
  -- baseline must not blend across the old and new frames.
  collapseRenderBaseline(self)
end

function FieldObjectActor:advanceScriptedAction(progressTicks, durationTicks)
  self:advanceAction(progressTicks, durationTicks)
end

function FieldObjectActor:commitAction()
  local m = self._motion
  if not m then
    return nil
  end
  local result = {
    fieldX = m.destFieldX,
    fieldZ = m.destFieldZ,
    surfaceId = m.destSurfaceId,
    cellKey = m.destCellKey,
    sourceSurfaceId = m.destSourceSurfaceId,
    worldX = m.destWorldX,
    worldY = m.destWorldY,
    worldZ = m.destWorldZ,
    resident = m.destResident,
  }
  local state = self:_numeric()
  if m.action == "gesture" then
    local held = MovementCalibration.gesturePresentationAfterCommit(m.gestureName, m.durationTicks)
    self._gesturePose = held.pose
    setGestureTick(state, held.poseTick)
    state.gestureOffsetY = held.offsetY
  end
  -- The transaction settles into the visual's idle semantics; action-owned
  -- render-only state never survives the action boundary.
  state.presentationOffsetX, state.presentationOffsetY, state.presentationOffsetZ = 0, 0, 0
  self.activeEmoteKind = nil
  self._motion = nil
  applyIdlePresentation(self, false)
  return result
end

function FieldObjectActor:commitScriptedAction()
  return self:commitAction()
end

function FieldObjectActor:cancelAction()
  local m = self._motion
  if not m then
    return
  end
  local state = self:_numeric()
  -- Snap back to last committed logical anchor's world position.
  setWorld(state, m.startWorldX, m.startWorldY, m.startWorldZ)
  collapseRenderBaseline(self)
  state = self:_numeric()
  if isLocomotionAction(m.action) then
    self.pose = m.startPose
    state.poseTick = m.startPoseTick
  end
  self._gesturePose = m.startGesturePose
  setGestureTick(state, m.startGestureTick)
  state.gestureOffsetY = m.startGestureOffsetY or 0
  state.presentationOffsetX, state.presentationOffsetY, state.presentationOffsetZ = 0, 0, 0
  self.activeEmoteKind = nil
  self._motion = nil
  applyIdlePresentation(self, false)
end

function FieldObjectActor:cancelScriptedAction()
  self:cancelAction()
end

function FieldObjectActor:isScriptedMoving()
  return self._motion ~= nil and self._motion.owner == "script"
end

function FieldObjectActor:advancePresentationTick()
  local state = self:_numeric()
  if state.scriptedPresentationAdvanced == 1 then
    state.scriptedPresentationAdvanced = 0
    return
  end
  if self._motion ~= nil or state.animationPaused == 1 then
    return
  end
  applyIdlePresentation(self, true)
end

-- Force a stable idle baseline with no residual action presentation offset.
function FieldObjectActor:settlePresentation()
  assert(self._motion == nil, "cannot settle presentation while an action is active")
  local state = self:_numeric()
  self.pose = "idle"
  state.poseTick = 0
  state.presentationOffsetX, state.presentationOffsetY, state.presentationOffsetZ = 0, 0, 0
  self._gesturePose = nil
  setGestureTick(state, nil)
  state.gestureOffsetY = 0
  self.activeEmoteKind = nil
  applyIdlePresentation(self, false)
  self:_numeric().scriptedPresentationAdvanced = 0
end

-- The active semantic action kind (`walk`, `walk_in_place`, `jump`, `face`,
-- `delay`, `emote`, `gesture`), or nil while idle. This is the stable,
-- renderer/emote-facing anchor for "what is this actor currently doing"
-- without reaching into MovementTask's private plan state.
---@return string|nil
function FieldObjectActor:currentAction()
  return self._motion and self._motion.action or nil
end

function FieldObjectActor:scriptedMotionState()
  return self._motion
end

-- The renderer-facing presentation snapshot keeps gesture state private to
-- the actor while exposing the complete draw contract to its consumers.
---@return FieldObjectActor.PresentationState
function FieldObjectActor:presentationState()
  local state = self:_numeric()
  return {
    gesturePose = self._gesturePose,
    gestureTick = state.hasGestureTick == 1 and state.gestureTick or nil,
    gestureOffsetY = state.gestureOffsetY,
  }
end

-- --- Scripted mutation  ------------------------------------

-- Direct facing set for scripted operations (`face_player`, `face`, movement
-- tasks). Unlike the interaction override it has no owner and nothing to
-- restore; the script layer is the authority while it owns the field.
---@param direction FieldDirection
function FieldObjectActor:setFacing(direction)
  self.facing = requireFacing(direction, { actorId = self.actorId })
end

-- Scripted visibility toggle (`show_object`/`hide_object`). The flag-driven
-- existence rule stays authoritative at map entry; these are transient
-- scripted states on the live actor.
---@param visible boolean
function FieldObjectActor:setVisible(visible)
  self:_numeric().visible = visible ~= false and 1 or 0
end

-- Scripted position set: the caller (the actor manager) has already resolved
-- the destination surface and the occupancy index key for the new cell.
---@param position { fieldX: integer, fieldZ: integer, worldY: number?, worldX: number?, worldZ: number?, surfaceId: integer?, cellKey: string?, sourceSurfaceId: integer?, resident: boolean }
function FieldObjectActor:setPosition(position)
  -- A completed action commits through this same path with the world point
  -- already at its destination, so only a changed base point collapses the
  -- sampled pair: commits keep their final segment for the following frame
  -- while teleports never blend from the stale tile.
  local state = self:_numeric()
  local currentX, currentY, currentZ
  if state.hasWorldPosition == 1 then
    currentX, currentY, currentZ = state.worldX, state.worldY, state.worldZ
  end
  local worldChanged = position.worldX ~= currentX or position.worldY ~= currentY or position.worldZ ~= currentZ
  local residencyChanged = (position.resident == true) ~= (state.resident == 1)
  state.fieldX = position.fieldX
  state.fieldZ = position.fieldZ
  setSurfaceId(state, position.surfaceId)
  self.cellKey = position.cellKey
  setSourceSurfaceId(state, position.sourceSurfaceId)
  setWorld(state, position.worldX, position.worldY, position.worldZ)
  state.resident = position.resident == true and 1 or 0
  if worldChanged or residencyChanged then
    collapseRenderBaseline(self)
  end
end

return FieldObjectActor
