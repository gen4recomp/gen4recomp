-- The one field following-mon controller. It derives the active companion
-- from the live party's first alive non-egg mon and its catalog follower
-- descriptor, installs exactly one reserved partner actor through the actor
-- manager, replays committed player anchors through a bounded trail queue,
-- and settles script pause/wait/explicit-movement requests. It owns no
-- actor table, occupancy index, draw record, or visual: those stay with the
-- manager. Presentation state is never saved; continue reconstructs the
-- partner from party state on the first ticks.
--
-- Enablement note: no generated script in the pinned corpus sets a
-- follower story flag, and the starter trail requires installation from
-- party eligibility alone, so enablement derives from party eligibility and
-- map permission in this increment. The enabled/eligible/visible/active/
-- installed split is kept so a future flag re-enters without redesign.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local MovementCalibration = require("libs.hgss.src.script.tasks.MovementCalibration")
local Personality = require("libs.mons.src.gen4.Personality")

local FollowingMonController = {}
FollowingMonController.__index = FollowingMonController

---@class FollowingMonController
---@field _service HgssMonService live party service { partyRevision, leadAliveSlot, partyMon }
---@field _catalog MonCatalog mon catalog { species, followerSelection }
---@field _actors FieldActorManager
---@field _playerOf fun(): FieldPlayer player anchor source { movementRevision, committedAnchor }
---@field _lastMapId integer?
---@field _lastPartyRevision integer?
---@field _lead table<string, unknown>?
---@field _published table<string, unknown>?
---@field _lastPlayerRevision integer?
---@field _lastAnchor table<string, unknown>?
---@field _queue table<string, unknown>[]
---@field _paused boolean
---@field _action { kind: string, progress: integer, duration: integer }?
---@field _lastParams { a: integer, b: integer }?
---@field _suspended boolean
---@field new fun(opts: FollowingMonControllerOptions): FollowingMonController
---@field isEnabled fun(self: FollowingMonController): boolean
---@field isActive fun(self: FollowingMonController): boolean
---@field isVisible fun(self: FollowingMonController): boolean
---@field partnerActorId fun(self: FollowingMonController): string?
---@field update fun(self: FollowingMonController)
---@field handleMapExit fun(self: FollowingMonController)
---@field setMovementPaused fun(self: FollowingMonController, paused: boolean)
---@field isMovementSettled fun(self: FollowingMonController): boolean
---@field settleMovement fun(self: FollowingMonController)
---@field startMovement fun(self: FollowingMonController, action: table<string, unknown>)
---@field facePlayer fun(self: FollowingMonController)
---@field isEventTrigger fun(self: FollowingMonController, kind: integer, param: unknown): boolean
---@field setParam fun(self: FollowingMonController, a: integer, b: integer)
---@field lastParams fun(self: FollowingMonController): { a: integer, b: integer }?
---@field dispose fun(self: FollowingMonController)
---@field _descriptor fun(self: FollowingMonController, snapshot: table<string, unknown>): table<string, unknown>?
---@field _reconcileLead fun(self: FollowingMonController)
---@field _spec fun(self: FollowingMonController, mapId: integer, fieldX: integer, fieldZ: integer, facing: string, worldY: number?): FieldActorManager.PartnerSpec
---@field _tryInstall fun(self: FollowingMonController, spec: FieldActorManager.PartnerSpec): string?
---@field _tryUpdate fun(self: FollowingMonController, spec: FieldActorManager.PartnerSpec): string?
---@field _publish fun(self: FollowingMonController, mapId: integer)
---@field _clearAll fun(self: FollowingMonController)
---@field _discontinuity fun(self: FollowingMonController, mapId: integer)
---@field _handleMapChange fun(self: FollowingMonController, mapId: integer)
---@field _observePlayer fun(self: FollowingMonController, mapId: integer)
---@field _driveQueue fun(self: FollowingMonController, mapId: integer)
---@field _advanceAction fun(self: FollowingMonController)

FollowingMonController.PARTNER_NUMERIC_ID = 253
FollowingMonController.MAX_QUEUED_ANCHORS = 8
FollowingMonController.TRAIL_SPEED = "normal"

local DELTAS = {
  north = { x = 0, z = -1 },
  south = { x = 0, z = 1 },
  west = { x = -1, z = 0 },
  east = { x = 1, z = 0 },
}

local OPPOSITE_FACING = { north = "south", south = "north", west = "east", east = "west" }

-- Trigger kinds the controller answers from live state (corpus-observed
-- 1/2). Anything else is outside the delivered trigger contract and reads
-- false rather than faulting the script.
local KNOWN_TRIGGER_KINDS = { [1] = true, [2] = true }

---@class FollowingMonControllerOptions
---@field service HgssMonService live party service { partyRevision, leadAliveSlot, partyMon }
---@field catalog MonCatalog mon catalog { species, followerSelection }
---@field actors FieldActorManager
---@field playerOf fun(): FieldPlayer player anchor source { movementRevision, committedAnchor }

---@param opts FollowingMonControllerOptions
---@return FollowingMonController
function FollowingMonController.new(opts)
  assert(type(opts) == "table", "following controller requires an options record")
  assert(opts.service and opts.service.partyRevision, "following controller requires the party service")
  assert(opts.catalog and opts.catalog.followerSelection, "following controller requires the mon catalog")
  assert(opts.actors and opts.actors.installPartner, "following controller requires the partner actor seam")
  assert(type(opts.playerOf) == "function", "following controller requires the player anchor source")
  local self = setmetatable({
    _service = opts.service,
    _catalog = opts.catalog,
    _actors = opts.actors,
    _playerOf = opts.playerOf,
    _lastMapId = nil,
    _lastPartyRevision = nil,
    _lead = nil,
    _published = nil,
    _lastPlayerRevision = nil,
    _lastAnchor = nil,
    _queue = {},
    _paused = false,
    _action = nil,
    _lastParams = nil,
    _suspended = false,
  }, FollowingMonController)
  ---@cast self FollowingMonController
  return self
end

---@param anchor table<string, unknown>
---@return { x: integer, z: integer }
local function behindTile(anchor)
  local delta = assert(DELTAS[anchor.facing], "player anchor facing is required")
  return { x = anchor.fieldX - delta.x, z = anchor.fieldZ - delta.z }
end

---@param from table<string, unknown> { fieldX: integer, fieldZ: integer }
---@param to table<string, unknown> { fieldX: integer, fieldZ: integer }
---@return boolean
local function isAdjacent(from, to)
  return math.abs(from.fieldX - to.fieldX) + math.abs(from.fieldZ - to.fieldZ) == 1
end

---@param from table<string, unknown> { fieldX: integer, fieldZ: integer }
---@param to table<string, unknown> { fieldX: integer, fieldZ: integer }
---@return string
local function directionFromTo(from, to)
  local dx, dz = to.fieldX - from.fieldX, to.fieldZ - from.fieldZ
  if dx == 1 then
    return "east"
  end
  if dx == -1 then
    return "west"
  end
  if dz == 1 then
    return "south"
  end
  assert(dz == -1, "trail anchors must be cardinally adjacent")
  return "north"
end

---@param left table<string, unknown>?
---@param right table<string, unknown>?
---@return boolean
local function sameIdentity(left, right)
  if left == nil or right == nil then
    return left == right
  end
  return left.slot == right.slot
    and left.species == right.species
    and left.form == right.form
    and left.personality == right.personality
    and left.visualId == right.visualId
end

---@param self FollowingMonController
---@param snapshot table<string, unknown>
---@return table<string, unknown>? descriptor
function FollowingMonController:_descriptor(snapshot)
  local descriptor = self._catalog:followerSelection(snapshot)
  if descriptor == nil then
    return nil
  end
  local ratio = self._catalog:species(snapshot.species).genderRatio
  if Personality.gender(ratio, snapshot.personality) == "female" and descriptor.female ~= nil then
    return descriptor.female
  end
  return descriptor
end

-- Recompute the desired lead identity on party revisions. Actor work happens
-- in the publish step so a revision that changes nothing observable performs
-- no actor operations at all.
---@param self FollowingMonController
function FollowingMonController:_reconcileLead()
  local slot = self._service:leadAliveSlot()
  local snapshot = slot ~= nil and self._service:partyMon(slot) or nil
  local descriptor = snapshot ~= nil and self:_descriptor(snapshot) or nil
  if snapshot == nil or descriptor == nil then
    self._lead = nil
    return
  end
  self._lead = {
    slot = slot,
    species = snapshot.species,
    form = snapshot.form,
    personality = snapshot.personality,
    visualId = descriptor.visualId,
  }
end

---@return boolean
---@param self FollowingMonController
function FollowingMonController:isEnabled()
  return true
end

---@return boolean
---@param self FollowingMonController
function FollowingMonController:isActive()
  return self:isEnabled() and self._lead ~= nil
end

---@return boolean
---@param self FollowingMonController
function FollowingMonController:isVisible()
  return self:isActive()
end

---@return string?
---@param self FollowingMonController
function FollowingMonController:partnerActorId()
  return self._actors:partnerId()
end

---@param self FollowingMonController
---@param mapId integer
---@param fieldX integer
---@param fieldZ integer
---@param facing string
---@param worldY number?
---@return FieldActorManager.PartnerSpec spec
function FollowingMonController:_spec(mapId, fieldX, fieldZ, facing, worldY)
  assert(self._lead ~= nil, "partner placement requires a lead identity")
  return {
    numericId = FollowingMonController.PARTNER_NUMERIC_ID,
    visualId = self._lead.visualId,
    mapId = mapId,
    fieldX = fieldX,
    fieldZ = fieldZ,
    facing = facing,
    worldY = worldY,
  }
end

-- Only the data fault that means "not installable yet" (a descriptor
-- visual the actor set does not compile) answers nil; programmer misuse
-- propagates.
---@param err unknown
---@return boolean
local function isVisualMissing(err)
  if not Errors.is(err) then
    return false
  end
  ---@cast err Errors.Error
  return err.code == FieldErrors.ACTOR_PARTNER_VISUAL_MISSING
end

-- Install, catching only the data fault that means "not installable yet" (a
-- descriptor visual the actor set does not compile). Programmer misuse
-- propagates. Answers nil when the tile cannot take the partner.
---@param self FollowingMonController
---@param spec FieldActorManager.PartnerSpec
---@return string?
function FollowingMonController:_tryInstall(spec)
  local ok, id = pcall(self._actors.installPartner, self._actors, spec)
  if ok then
    return id
  end
  if isVisualMissing(id) then
    return nil
  end
  error(id)
end

---@param self FollowingMonController
---@param spec FieldActorManager.PartnerSpec
---@return string?
function FollowingMonController:_tryUpdate(spec)
  local ok, id = pcall(self._actors.updatePartner, self._actors, spec)
  if ok then
    return id
  end
  if isVisualMissing(id) then
    return nil
  end
  error(id)
end

-- Publish the desired lead: replace in place when an actor is live,
-- otherwise install behind the player or on the oldest yielded anchor when
-- the behind tile is blocked. Success clears the stale queue and records
-- the published identity; anything less retries on a later tick.
---@param self FollowingMonController
---@param mapId integer
function FollowingMonController:_publish(mapId)
  local partnerId = self._actors:partnerId()
  if partnerId ~= nil then
    local position = assert(self._actors:getPosition(partnerId), "partner position is required")
    local actor = assert(self._actors:getById(partnerId), "partner actor is required")
    local id = self:_tryUpdate(self:_spec(mapId, position.fieldX, position.fieldZ, actor.facing, actor.worldY))
    if id ~= nil then
      self._published = self._lead
      self._queue = {}
    end
    return
  end
  local anchor = self._playerOf():committedAnchor()
  local behind = behindTile(anchor)
  local id = self:_tryInstall(self:_spec(mapId, behind.x, behind.z, anchor.facing, anchor.worldY))
  if id == nil and self._queue[1] ~= nil then
    local head = self._queue[1]
    if head.mapId == mapId then
      id = self:_tryInstall(self:_spec(mapId, head.fieldX, head.fieldZ, head.facing, head.worldY))
      if id ~= nil then
        table.remove(self._queue, 1)
      end
    end
  end
  if id ~= nil then
    self._published = self._lead
  end
end

-- Cancel in-flight presentation, drop the queue and the actor, and forget
-- the published identity. Idempotent: every path below tolerates absence.
---@param self FollowingMonController
function FollowingMonController:_clearAll()
  local partnerId = self._actors:partnerId()
  if partnerId ~= nil then
    self._actors:cancelScriptedMovement(partnerId)
  end
  self._actors:clearPartner()
  self._action = nil
  self._queue = {}
  self._lead = nil
  self._published = nil
end

-- A discontinuous anchor (teleport, jump, map mismatch, bad surface): drop
-- the queue and the in-flight step, then snap to a valid tile behind the
-- player where one exists. Never paths through world geometry.
---@param self FollowingMonController
---@param mapId integer
function FollowingMonController:_discontinuity(mapId)
  local partnerId = self._actors:partnerId()
  if partnerId ~= nil then
    self._actors:cancelScriptedMovement(partnerId)
  end
  self._action = nil
  self._queue = {}
  self._actors:clearPartner()
  self._published = nil
  if self._lead ~= nil then
    local anchor = self._playerOf():committedAnchor()
    if anchor.mapId == mapId then
      local behind = behindTile(anchor)
      local id = self:_tryInstall(self:_spec(mapId, behind.x, behind.z, anchor.facing, anchor.worldY))
      if id ~= nil then
        self._published = self._lead
      end
    end
  end
end

-- A map ownership change: the manager retired the old entry (releasing the
-- old visual), so drop movement state without touching the manager and let
-- the normal publish path reinstall on the new map.
---@param self FollowingMonController
---@param mapId integer
function FollowingMonController:_handleMapChange(mapId)
  self._lastMapId = mapId
  self._queue = {}
  self._action = nil
  self._published = nil
  self._lastPlayerRevision = nil
  self._lastAnchor = nil
end

-- Observe one committed player step: enqueue the player's previous anchor.
-- Anything inconsistent (a missing baseline, a cross-map anchor, an anchor
-- from another actor map) re-baselines instead of enqueueing phantoms.
---@param self FollowingMonController
---@param mapId integer
function FollowingMonController:_observePlayer(mapId)
  local player = self._playerOf()
  local revision = player:movementRevision()
  local anchor = player:committedAnchor()
  if self._lastPlayerRevision == nil then
    self._lastPlayerRevision = revision
    self._lastAnchor = anchor
    return
  end
  if revision == self._lastPlayerRevision then
    self._lastAnchor = anchor
    return
  end
  self._lastPlayerRevision = revision
  local previous = self._lastAnchor
  self._lastAnchor = anchor
  if previous == nil or previous.mapId ~= mapId or anchor.mapId ~= mapId then
    return
  end
  if not isAdjacent(previous, anchor) then
    -- The player itself displaced discontinuously (jump, teleport, scripted
    -- placement): the old trail is stale, so snap instead of replaying it.
    self:_discontinuity(mapId)
    return
  end
  if #self._queue >= FollowingMonController.MAX_QUEUED_ANCHORS then
    -- Bounded retention: beyond the source-safe bound the oldest anchors
    -- drop (catch-up) rather than replaying a stale trail without end.
    table.remove(self._queue, 1)
  end
  self._queue[#self._queue + 1] = previous
end

-- Start the oldest queued anchor when idle and unpaused. A head the partner
-- cannot step to (nonadjacent, foreign map) is a discontinuity, never a
-- pathfind.
---@param self FollowingMonController
---@param mapId integer
function FollowingMonController:_driveQueue(mapId)
  if self._action ~= nil or self._paused then
    return
  end
  local head = self._queue[1]
  if head == nil then
    return
  end
  local partnerId = self._actors:partnerId()
  if partnerId == nil or head.mapId ~= mapId then
    self:_discontinuity(mapId)
    return
  end
  local position = assert(self._actors:getPosition(partnerId), "partner position is required")
  if not isAdjacent(position, head) then
    self:_discontinuity(mapId)
    return
  end
  local direction = directionFromTo(position, head)
  self._actors:setFacing(partnerId, direction)
  local ok, err = pcall(
    self._actors.beginScriptedAction,
    self._actors,
    partnerId,
    { action = "walk", direction = direction, speed = FollowingMonController.TRAIL_SPEED }
  )
  if not ok then
    self:_discontinuity(mapId)
    return
  end
  assert(err == nil, "scripted begin answers through the actor, not a value")
  self._action = {
    kind = "trail",
    progress = 0,
    duration = MovementCalibration.SPEED_TICKS[FollowingMonController.TRAIL_SPEED],
  }
  self._actors:advanceScriptedAction(partnerId, 0, self._action.duration)
end

-- Advance the one in-flight presentation step; commit the queued anchor only
-- when the actor movement commits successfully.
---@param self FollowingMonController
function FollowingMonController:_advanceAction()
  local action = self._action
  if action == nil then
    return
  end
  local partnerId = self._actors:partnerId()
  if partnerId == nil then
    self._action = nil
    return
  end
  local progress = action.progress + 1
  action.progress = progress
  self._actors:advanceScriptedAction(partnerId, progress, action.duration)
  if progress >= action.duration then
    self._actors:commitScriptedAction(partnerId)
    if action.kind == "trail" and #self._queue > 0 then
      table.remove(self._queue, 1)
    end
    self._action = nil
  end
end

-- One fixed-tick reconciliation: map ownership, party identity, placement,
-- anchor observation, queue driving, and action advancement.
---@param self FollowingMonController
function FollowingMonController:update()
  local mapId = self._actors.currentMapId
  if mapId == nil then
    return
  end
  if self._suspended then
    if mapId == self._lastMapId then
      return
    end
    self._suspended = false
  end
  if mapId ~= self._lastMapId then
    self:_handleMapChange(mapId)
  end
  local partyRevision = self._service:partyRevision()
  if partyRevision ~= self._lastPartyRevision then
    self._lastPartyRevision = partyRevision
    self:_reconcileLead()
  end
  if not self:isActive() then
    self:_clearAll()
    return
  end
  if not sameIdentity(self._published, self._lead) then
    self:_publish(mapId)
  end
  self:_observePlayer(mapId)
  self:_driveQueue(mapId)
  self:_advanceAction()
end

-- Clear the actor before the old map leaves residency. The manager retires
-- the entry afterwards; later updates stay suspended until the new actor
-- map publishes.
---@param self FollowingMonController
function FollowingMonController:handleMapExit()
  local partnerId = self._actors:partnerId()
  if partnerId ~= nil then
    self._actors:cancelScriptedMovement(partnerId)
  end
  self._action = nil
  self._queue = {}
  self._actors:clearPartner()
  self._published = nil
  self._suspended = true
end

---@param paused boolean
---@param self FollowingMonController
function FollowingMonController:setMovementPaused(paused)
  self._paused = paused == true
end

-- Settle means no in-flight presentation and no source-required pending
-- movement: a paused queue is retained, not drained, so waits never hang on
-- a paused follower.
---@return boolean
---@param self FollowingMonController
function FollowingMonController:isMovementSettled()
  return self._action == nil and (self._paused or #self._queue == 0)
end

-- Settle any in-flight presentation through the manager owner. Waiting tasks
-- observe this through isMovementSettled; transitions and replacement call
-- it before republishing.
---@param self FollowingMonController
function FollowingMonController:settleMovement()
  local partnerId = self._actors:partnerId()
  if partnerId ~= nil then
    self._actors:cancelScriptedMovement(partnerId)
  end
  self._action = nil
end

-- Explicit scripted follower movement: the script takes over the one action,
-- so the trail queue clears first and pause never blocks it. Absence is a
-- no-op; malformed selectors are programmer faults. Any decoded movement
-- action the actor manager executes may ride through.
---@param action table<string, unknown> decoded movement action
---@param self FollowingMonController
function FollowingMonController:startMovement(action)
  assert(type(action) == "table" and type(action.action) == "string", "follower movement requires an action record")
  local partnerId = self._actors:partnerId()
  if partnerId == nil then
    return
  end
  self._queue = {}
  self:settleMovement()
  if action.direction ~= nil then
    assert(DELTAS[action.direction], "follower movement direction is invalid")
    self._actors:setFacing(partnerId, action.direction)
  end
  local ok, err = pcall(self._actors.beginScriptedAction, self._actors, partnerId, {
    action = action.action,
    direction = action.direction,
    distance = action.distance,
    speed = action.speed,
    ticks = action.ticks,
    name = action.name,
    deltaX = action.deltaX,
    deltaZ = action.deltaZ,
    surfaceBandDelta = action.surfaceBandDelta,
  })
  if not ok then
    self:_discontinuity(assert(self._actors.currentMapId, "follower map is required"))
    return
  end
  assert(err == nil, "scripted begin answers through the actor, not a value")
  self._action = { kind = "explicit", progress = 0, duration = MovementCalibration.actionTicks(action) }
  self._actors:advanceScriptedAction(partnerId, 0, self._action.duration)
end

-- Face the partner toward the player. Absence is a no-op.
---@param self FollowingMonController
function FollowingMonController:facePlayer()
  local partnerId = self._actors:partnerId()
  if partnerId == nil then
    return
  end
  local facing = self._playerOf():committedAnchor().facing
  self._actors:setFacing(partnerId, assert(OPPOSITE_FACING[facing], "player anchor facing is required"))
end

-- Event-trigger check for known trigger kinds: an idle installed partner on
-- a visible map. Unknown kinds read false.
---@param kind integer
---@param _ unknown trigger parameter carried for future trigger kinds
---@return boolean
---@param self FollowingMonController
function FollowingMonController:isEventTrigger(kind, _)
  if not self:isVisible() or self._action ~= nil then
    return false
  end
  if KNOWN_TRIGGER_KINDS[kind] ~= true then
    return false
  end
  return self._actors:partnerId() ~= nil
end

-- Record the source parameter/state operation. Both params ride through
-- opaquely; the controller owns no param-driven behavior in this increment.
---@param a integer
---@param b integer
---@param self FollowingMonController
function FollowingMonController:setParam(a, b)
  self._lastParams = { a = a, b = b }
end

---@return { a: integer, b: integer }?
---@param self FollowingMonController
function FollowingMonController:lastParams()
  return self._lastParams
end

-- Release follower state without touching saved data. The manager owns the
-- actor teardown afterwards.
---@param self FollowingMonController
function FollowingMonController:dispose()
  self._action = nil
  self._queue = {}
  self._actors:clearPartner()
  self._lead = nil
  self._published = nil
  self._lastMapId = nil
  self._suspended = false
end

return FollowingMonController
