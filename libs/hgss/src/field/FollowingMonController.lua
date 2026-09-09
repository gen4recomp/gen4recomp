-- The one field following-mon controller. It derives the active companion
-- from the live party's first alive non-egg mon and its catalog follower
-- descriptor, installs exactly one reserved partner actor through the actor
-- manager, starts ordinary walks from the player's movement-start
-- transaction in the same fixed-step epoch, replays committed player anchors
-- through a bounded trail queue only for paused/busy recovery and resync,
-- and settles script pause/wait requests. It owns no
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
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local MovementCalibration = require("libs.hgss.src.script.tasks.MovementCalibration")
local Personality = require("libs.mons.src.gen4.Personality")

local FollowingMonController = {}
FollowingMonController.__index = FollowingMonController

---@class FollowingMonController
---@field _service table<string, unknown> live party service { partyRevision, leadAliveSlot, partyMon }
---@field _catalog MonCatalog mon catalog { species, followerSelection }
---@field _actors FieldActorManager
---@field _playerOf fun(): FieldPlayer player anchor source { movementRevision, committedAnchor }
---@field _mapOf fun(mapId: integer): table<string, unknown>? read-only runtime map metadata { followMode, mapSymbol }
---@field _lastMapId integer?
---@field _lastPartyRevision integer?
---@field _lead table<string, unknown>?
---@field _published table<string, unknown>?
---@field _pendingHiddenLead table<string, unknown>?
---@field _mapEntry boolean
---@field _lastPlayerRevision integer?
---@field _lastAnchor table<string, unknown>?
---@field _lastMovementTransactionRevision integer?
---@field _consumedStep table<string, unknown>?
---@field _queue table<string, unknown>[]
---@field _paused boolean
---@field _movementType string persistent follower map-object movement mode
---@field _lastFollowerCommand { direction: string, speed: string }? last real follower walk; descriptive only, never an obligation
---@field _action { progress: integer, duration: integer }?
---@field _suspended boolean
---@field new fun(opts: FollowingMonControllerOptions): FollowingMonController
---@field isEnabled fun(self: FollowingMonController): boolean
---@field isActive fun(self: FollowingMonController): boolean
---@field isSourceActive fun(self: FollowingMonController): boolean
---@field isVisible fun(self: FollowingMonController): boolean
---@field partnerActorId fun(self: FollowingMonController): string?
---@field partnerSourceState fun(self: FollowingMonController): integer
---@field update fun(self: FollowingMonController)
---@field handleMapExit fun(self: FollowingMonController)
---@field setMovementPaused fun(self: FollowingMonController, paused: boolean)
---@field isMovementSettled fun(self: FollowingMonController): boolean
---@field settleMovement fun(self: FollowingMonController)
---@field setMovementType fun(self: FollowingMonController, movementType: string)
---@field repositionRelativeToPlayer fun(self: FollowingMonController, offsetSelector: integer, directionRaw: integer)
---@field facePlayer fun(self: FollowingMonController)
---@field isEventTrigger fun(self: FollowingMonController, kind: integer, param: unknown): boolean
---@field dispose fun(self: FollowingMonController)
---@field _descriptor fun(self: FollowingMonController, snapshot: table<string, unknown>): table<string, unknown>?
---@field _desiredLead fun(self: FollowingMonController): table<string, unknown>?
---@field _reconcileLead fun(self: FollowingMonController)
---@field _permitted fun(self: FollowingMonController, mapId: integer): boolean
---@field _spec fun(self: FollowingMonController, mapId: integer, fieldX: integer, fieldZ: integer, facing: string, worldY: number?, initiallyVisible: boolean?): FieldActorManager.PartnerSpec
---@field _tryInstall fun(self: FollowingMonController, spec: FieldActorManager.PartnerSpec): string?
---@field _tryUpdate fun(self: FollowingMonController, spec: FieldActorManager.PartnerSpec): string?
---@field _publish fun(self: FollowingMonController, mapId: integer)
---@field _suppress fun(self: FollowingMonController)
---@field _clearAll fun(self: FollowingMonController)
---@field _discontinuity fun(self: FollowingMonController, mapId: integer)
---@field _handleMapChange fun(self: FollowingMonController, mapId: integer)
---@field _observePlayer fun(self: FollowingMonController, mapId: integer)
---@field _commitMatchesLiveStart fun(self: FollowingMonController, previous: table<string, unknown>?, anchor: table<string, unknown>, mapId: integer): boolean
---@field _observeMovementStart fun(self: FollowingMonController, mapId: integer)
---@field _beginOrdinaryFollow fun(self: FollowingMonController, mapId: integer, tx: FieldPlayer.MovementTransaction)
---@field _beginVacatedSteer fun(self: FollowingMonController, mapId: integer, tx: FieldPlayer.MovementTransaction)
---@field _beginReplayLastWalk fun(self: FollowingMonController, mapId: integer, tx: FieldPlayer.MovementTransaction)
---@field _beginActorWalk fun(self: FollowingMonController, mapId: integer, direction: string, speed: string): boolean
---@field _enqueueVacatedTarget fun(self: FollowingMonController, tx: FieldPlayer.MovementTransaction, speed: string)
---@field _enqueueReplay fun(self: FollowingMonController, mapId: integer, direction: string, speed: string)
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

-- The tower floors where the burrowing species stay unpublished even though
-- the map mode itself allows followers (pret/pokeheartgold
-- FollowMon_DiglettPermissionCheck). Keyed by semantic map symbol, never by
-- display name.
local BURROWING_BLOCKED_MAPS = {
  MAP_BELL_TOWER_1F = true,
  MAP_BELL_TOWER_2F = true,
  MAP_BELL_TOWER_3F = true,
  MAP_BELL_TOWER_4F = true,
  MAP_BELL_TOWER_5F = true,
  MAP_BELL_TOWER_6F = true,
  MAP_BELL_TOWER_7F = true,
  MAP_BELL_TOWER_8F = true,
  MAP_BELL_TOWER_9F = true,
  MAP_BELL_TOWER_ROOF = true,
  MAP_BELL_TOWER_10F = true,
}

local BURROWING_SPECIES = { DIGLETT = true, DUGTRIO = true }

-- The source player-relative placement offsets: 0 north, 1 south, 2 west,
-- 3 east. Any other selector keeps the copied player tile unchanged.
local REPOSITION_OFFSETS = {
  [0] = { x = 0, z = -1 },
  [1] = { x = 0, z = 1 },
  [2] = { x = -1, z = 0 },
  [3] = { x = 1, z = 0 },
}

local ZERO_OFFSET = { x = 0, z = 0 }

-- The source facing-direction mapping shared with field actors: 0 north,
-- 1 south, 2 west, 3 east.
local FACING_BY_RAW = { [0] = "north", [1] = "south", [2] = "west", [3] = "east" }

-- The persistent follower map-object movement modes: ordinary free
-- following plus the two scripted-transition modes. The setter stores the
-- mode only; movement behavior reads it on later ticks.
local FOLLOWER_MOVEMENT_TYPES = {
  follow_player = true,
  follow_transition_a = true,
  follow_transition_b = true,
}

-- Trigger kinds the controller answers from live state (corpus-observed
-- 1/2). Anything else is outside the delivered trigger contract and reads
-- false rather than faulting the script.
local KNOWN_TRIGGER_KINDS = { [1] = true, [2] = true }

---@class FollowingMonControllerOptions
---@field service table<string, unknown> live party service { partyRevision, leadAliveSlot, partyMon }
---@field catalog MonCatalog mon catalog { species, followerSelection }
---@field actors FieldActorManager
---@field playerOf fun(): FieldPlayer player anchor source { movementRevision, committedAnchor }
---@field mapOf (fun(mapId: integer): table<string, unknown>?)? read-only runtime map metadata lookup

---@param opts FollowingMonControllerOptions
---@return FollowingMonController
function FollowingMonController.new(opts)
  assert(type(opts) == "table", "following controller requires an options record")
  assert(opts.service and opts.service.partyRevision, "following controller requires the party service")
  assert(opts.catalog and opts.catalog.followerSelection, "following controller requires the mon catalog")
  assert(opts.actors and opts.actors.installPartner, "following controller requires the partner actor seam")
  assert(type(opts.playerOf) == "function", "following controller requires the player anchor source")
  if opts.mapOf ~= nil then
    assert(type(opts.mapOf) == "function", "following controller map lookup must be a function")
  end
  local actors = assert(opts.actors)
  local mapOf = opts.mapOf
  if mapOf == nil then
    -- The actor manager's current entries carry the same generated runtime
    -- map records, so composition without an explicit lookup still reads
    -- the live map metadata rather than a default.
    local function actorEntryMap(mapId)
      local entry = actors.maps[mapId]
      return entry and entry.runtimeMap or nil
    end
    mapOf = actorEntryMap
  end
  local self = setmetatable({
    _service = opts.service,
    _catalog = opts.catalog,
    _actors = actors,
    _playerOf = opts.playerOf,
    _mapOf = mapOf,
    _lastMapId = nil,
    _lastPartyRevision = nil,
    _lead = nil,
    _published = nil,
    _pendingHiddenLead = nil,
    _mapEntry = false,
    _lastPlayerRevision = nil,
    _lastAnchor = nil,
    _lastMovementTransactionRevision = nil,
    _consumedStep = nil,
    _queue = {},
    _paused = false,
    _movementType = "follow_player",
    _lastFollowerCommand = nil,
    _action = nil,
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

-- Map a player transaction speed to the follower pace the map object keeps.
-- A player run travels as a follower fast walk; every other calibrated walk
-- speed is kept. Anything uncalibrated is a programming failure, never a
-- silent normal.
---@param speed string
---@return string
local function followerSpeed(speed)
  assert(type(speed) == "string", "follower walk speed required")
  if speed == "run" then
    return "fast"
  end
  assert(MovementCalibration.SPEED_TICKS[speed] ~= nil, "unknown follower walk speed " .. tostring(speed))
  return speed
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

-- Derive the desired lead identity from live party state without touching
-- reconciliation, actors, queue, or revisions. Reconciliation retains the
-- result; script command guards read it synchronously in the same tick the
-- party mutates, before any fixed update publishes the actor.
---@param self FollowingMonController
---@return table<string, unknown>? lead
function FollowingMonController:_desiredLead()
  local slot = self._service:leadAliveSlot()
  local snapshot = slot ~= nil and self._service:partyMon(slot) or nil
  local descriptor = snapshot ~= nil and self:_descriptor(snapshot) or nil
  if snapshot == nil or descriptor == nil then
    return nil
  end
  local lead = {
    slot = slot,
    species = snapshot.species,
    form = snapshot.form,
    personality = snapshot.personality,
    visualId = descriptor.visualId,
    size = descriptor.size,
    objectParam = descriptor.objectParam,
  }
  assert(type(lead.size) == "number" and lead.size % 1 == 0, "follower size is required for map permission")
  assert(
    type(lead.objectParam) == "number"
      and lead.objectParam % 1 == 0
      and lead.objectParam >= 0
      and lead.objectParam <= 0xFFFF,
    "follower object parameter is required"
  )
  return lead
end

-- Recompute the desired lead identity on party revisions. Actor work happens
-- in the publish step so a revision that changes nothing observable performs
-- no actor operations at all.
---@param self FollowingMonController
function FollowingMonController:_reconcileLead()
  local previous = self._lead
  local lead = self:_desiredLead()
  if lead == nil then
    self._lead = nil
    self._pendingHiddenLead = nil
    return
  end
  if previous == nil then
    if not self._mapEntry and self._actors:partnerId() == nil then
      self._pendingHiddenLead = lead
    else
      self._pendingHiddenLead = nil
    end
  elseif not sameIdentity(previous, lead) then
    self._pendingHiddenLead = nil
  elseif self._pendingHiddenLead ~= nil and not sameIdentity(self._pendingHiddenLead, lead) then
    self._pendingHiddenLead = nil
  end
  self._lead = lead
end

-- The source follower permission (pret/pokeheartgold
-- FollowMon_GetPermissionBySpeciesAndMap): the burrowing check runs before
-- the map mode, a prevented map publishes nothing, a height-restricted map
-- admits only size-zero followers, and an allowed map admits every lead. A
-- missing map record or an unknown follow mode is a hard generated-data
-- failure, never a silent allow.
---@param self FollowingMonController
---@param mapId integer
---@return boolean
function FollowingMonController:_permitted(mapId)
  assert(self._lead ~= nil, "follower permission requires a lead identity")
  local map = self._mapOf(mapId)
  if map == nil then
    Errors.raise(FieldErrors.FIELD_MAP_UNKNOWN, "no runtime map for follower permission", { mapId = mapId })
  end
  assert(map ~= nil, "follower permission requires the current map record")
  if BURROWING_SPECIES[self._lead.species] and BURROWING_BLOCKED_MAPS[map.mapSymbol] then
    return false
  end
  local mode = map.followMode
  if mode == "ALLOW" then
    return true
  end
  if mode == "PREVENT" then
    return false
  end
  if mode == "HEIGHT_RESTRICT" then
    return self._lead.size == 0
  end
  Errors.raise(
    FieldErrors.FIELD_MAP_WORLD_INVALID,
    "unknown follower map mode; rebuild the derived cache",
    { mapId = mapId, followMode = mode }
  )
  error("unreachable after unknown follower map mode")
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

-- Whether the live party holds an eligible lead right now, regardless of
-- whether fixed-tick reconciliation has installed its actor yet. Read-only:
-- it never publishes actors, mutates the reconciled lead, or touches the
-- map, queue, or revisions.
---@return boolean
---@param self FollowingMonController
function FollowingMonController:isSourceActive()
  return self:isEnabled() and self:_desiredLead() ~= nil
end

---@return boolean
---@param self FollowingMonController
function FollowingMonController:isVisible()
  if not self:isActive() then
    return false
  end
  local mapId = self._actors.currentMapId
  if mapId == nil then
    return false
  end
  return self:_permitted(mapId)
end

---@return string?
---@param self FollowingMonController
function FollowingMonController:partnerActorId()
  return self._actors:partnerId()
end

---@return integer
---@param self FollowingMonController
function FollowingMonController:partnerSourceState()
  if self._lead == nil then
    return 0
  end
  local objectParam = self._lead.objectParam
  assert(
    type(objectParam) == "number" and objectParam % 1 == 0 and objectParam >= 0 and objectParam <= 0xFFFF,
    "follower object parameter is required"
  )
  return math.floor(objectParam / 256) % 16
end

---@param self FollowingMonController
---@param mapId integer
---@param fieldX integer
---@param fieldZ integer
---@param facing string
---@param worldY number?
---@param initiallyVisible boolean?
---@return FieldActorManager.PartnerSpec spec
function FollowingMonController:_spec(mapId, fieldX, fieldZ, facing, worldY, initiallyVisible)
  assert(self._lead ~= nil, "partner placement requires a lead identity")
  return {
    numericId = FollowingMonController.PARTNER_NUMERIC_ID,
    visualId = self._lead.visualId,
    mapId = mapId,
    fieldX = fieldX,
    fieldZ = fieldZ,
    facing = facing,
    worldY = worldY,
    initiallyVisible = initiallyVisible,
  }
end

-- Install, catching only a classified physical placement rejection (the
-- tile cannot take the partner right now, so a later tick retries).
-- Missing visuals, invalid specs, and every other structured failure
-- propagate. Answers nil when the tile cannot take the partner.
---@param self FollowingMonController
---@param spec FieldActorManager.PartnerSpec
---@return string?
function FollowingMonController:_tryInstall(spec)
  local ok, id = pcall(self._actors.installPartner, self._actors, spec)
  if ok then
    return id
  end
  if FieldActorManager.isPlacementRejection(id) then
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
  if FieldActorManager.isPlacementRejection(id) then
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
      self._lastFollowerCommand = nil
    end
    return
  end
  local initiallyVisible = nil
  if self._pendingHiddenLead ~= nil then
    assert(
      self._lead ~= nil and sameIdentity(self._pendingHiddenLead, self._lead),
      "pending follower birth identity is stale"
    )
    initiallyVisible = false
  end
  local anchor = self._playerOf():committedAnchor()
  local behind = behindTile(anchor)
  local id = self:_tryInstall(self:_spec(mapId, behind.x, behind.z, anchor.facing, anchor.worldY, initiallyVisible))
  if id == nil and self._queue[1] ~= nil then
    local head = self._queue[1]
    if head.mapId == mapId then
      id = self:_tryInstall(self:_spec(mapId, head.fieldX, head.fieldZ, head.facing, head.worldY, initiallyVisible))
      if id ~= nil then
        table.remove(self._queue, 1)
      end
    end
  end
  if id ~= nil then
    self._published = self._lead
    self._pendingHiddenLead = nil
    self._lastFollowerCommand = nil
  end
end

-- Drop visible presentation, the in-flight step, and the queue without
-- touching party identity. Idempotent: every path below tolerates absence.
---@param self FollowingMonController
function FollowingMonController:_suppress()
  local partnerId = self._actors:partnerId()
  if partnerId ~= nil then
    self._actors:cancelScriptedMovement(partnerId)
  end
  self._actors:clearPartner()
  self._action = nil
  self._queue = {}
  self._published = nil
  self._pendingHiddenLead = nil
  self._lastFollowerCommand = nil
end

-- Cancel in-flight presentation, drop the queue and the actor, and forget
-- the published identity. Idempotent: every path below tolerates absence.
---@param self FollowingMonController
function FollowingMonController:_clearAll()
  self:_suppress()
  self._lead = nil
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
  self._pendingHiddenLead = nil
  self._lastFollowerCommand = nil
  if self._lead ~= nil and self:_permitted(mapId) then
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
  self._mapEntry = true
  self._queue = {}
  self._action = nil
  self._movementType = "follow_player"
  self._lastFollowerCommand = nil
  self._published = nil
  self._pendingHiddenLead = nil
  self._lastPlayerRevision = nil
  self._lastAnchor = nil
  self._lastMovementTransactionRevision = nil
  self._consumedStep = nil
end

-- Observe one movement-start transaction: an ordinary adjacent walk starts
-- in the same fixed-step epoch instead of waiting for the player commit.
-- A paused or busy follower keeps the vacated source in the bounded queue;
-- the later commit never re-enqueues the same tile (see _observePlayer).
-- Anything non-ordinary (foreign map, non-walk kind) is marked consumed and
-- left to the existing commit/discontinuity observation.
---@param self FollowingMonController
---@param mapId integer
function FollowingMonController:_observeMovementStart(mapId)
  local player = self._playerOf()
  if type(player.movementTransaction) ~= "function" then
    return
  end
  local tx = player:movementTransaction()
  if tx == nil then
    if self._lastMovementTransactionRevision == nil then
      self._lastMovementTransactionRevision = 0
    end
    return
  end
  if self._lastMovementTransactionRevision == nil then
    -- A follower attached after history seeds the current revision instead
    -- of replaying the completed step.
    self._lastMovementTransactionRevision = tx.revision
    return
  end
  if tx.revision == self._lastMovementTransactionRevision then
    return
  end
  if tx.traversalKind ~= "walk" or tx.mapId ~= mapId then
    self._lastMovementTransactionRevision = tx.revision
    return
  end
  if self._actors:partnerId() == nil then
    return
  end
  self._lastMovementTransactionRevision = tx.revision
  if self._movementType == "follow_player" then
    self:_beginOrdinaryFollow(mapId, tx)
  elseif self._movementType == "follow_transition_a" then
    self:_beginVacatedSteer(mapId, tx)
  elseif self._movementType == "follow_transition_b" then
    self:_beginReplayLastWalk(mapId, tx)
  else
    error("unknown follower movement mode " .. tostring(self._movementType))
  end
end

-- Run one follower walk through the actor owner and remember it as the
-- last real walk. A classified physical placement rejection reconciles
-- through the discontinuity path (which forgets the remembered walk);
-- every other failure propagates. Answers whether the actor is now
-- walking.
---@param self FollowingMonController
---@param mapId integer
---@param direction string
---@param speed string
---@return boolean
function FollowingMonController:_beginActorWalk(mapId, direction, speed)
  local partnerId = assert(self._actors:partnerId(), "follower walk requires the partner actor")
  self._actors:setFacing(partnerId, direction)
  local ok, err = pcall(
    self._actors.beginScriptedAction,
    self._actors,
    partnerId,
    { action = "walk", direction = direction, speed = speed }
  )
  if not ok then
    if FieldActorManager.isPlacementRejection(err) then
      self:_discontinuity(mapId)
      return false
    end
    error(err)
  end
  assert(err == nil, "scripted begin answers through the actor, not a value")
  self._action = {
    progress = 0,
    duration = MovementCalibration.SPEED_TICKS[speed],
  }
  self._actors:advanceScriptedAction(partnerId, 0, self._action.duration)
  self._lastFollowerCommand = { direction = direction, speed = speed }
  return true
end

-- Retain one vacated-tile obligation under the bounded queue policy for a
-- paused or busy follower. Remembering waits until the queued walk
-- actually starts through the queue driver.
---@param self FollowingMonController
---@param tx FieldPlayer.MovementTransaction
---@param speed string
function FollowingMonController:_enqueueVacatedTarget(tx, speed)
  if #self._queue >= FollowingMonController.MAX_QUEUED_ANCHORS then
    table.remove(self._queue, 1)
  end
  self._queue[#self._queue + 1] = {
    mapId = tx.mapId,
    fieldX = tx.from.fieldX,
    fieldZ = tx.from.fieldZ,
    facing = tx.direction,
    worldY = tx.from.worldY,
    speed = speed,
  }
end

-- Retain one replay obligation under the bounded queue policy. The record
-- carries the walk direction itself rather than a target tile so the later
-- start replays the same walk regardless of where the trail has moved
-- since. Remembering waits until the queued walk actually starts.
---@param self FollowingMonController
---@param mapId integer
---@param direction string
---@param speed string
function FollowingMonController:_enqueueReplay(mapId, direction, speed)
  if #self._queue >= FollowingMonController.MAX_QUEUED_ANCHORS then
    table.remove(self._queue, 1)
  end
  self._queue[#self._queue + 1] = {
    mapId = mapId,
    direction = direction,
    speed = speed,
  }
end

-- Start the ordinary follow toward the transaction's source anchor: the tile
-- the player vacated. The movement direction derives from the follower's own
-- tile, never from the player's step direction. The follower keeps the
-- transaction's semantic speed, with a player run traveling as fast.
---@param self FollowingMonController
---@param mapId integer
---@param tx FieldPlayer.MovementTransaction
function FollowingMonController:_beginOrdinaryFollow(mapId, tx)
  local speed = followerSpeed(tx.speed)
  self._consumedStep = {
    mapId = tx.mapId,
    fromX = tx.from.fieldX,
    fromZ = tx.from.fieldZ,
    toX = tx.to.fieldX,
    toZ = tx.to.fieldZ,
  }
  local partnerId = assert(self._actors:partnerId(), "ordinary follow requires the partner actor")
  if self._paused or self._action ~= nil then
    self:_enqueueVacatedTarget(tx, speed)
    return
  end
  local position = assert(self._actors:getPosition(partnerId), "partner position is required")
  local target = { fieldX = tx.from.fieldX, fieldZ = tx.from.fieldZ }
  if not isAdjacent(position, target) then
    self:_discontinuity(mapId)
    return
  end
  local direction = directionFromTo(position, target)
  self:_beginActorWalk(mapId, direction, speed)
end

-- Steer toward the transaction's source anchor: the tile the player
-- vacated. The movement direction derives from the follower's own tile,
-- never from the player's step direction. A follower already standing on
-- the vacated tile holds still with no obligation; a nonadjacent target is
-- a discontinuity, never a pathfind.
---@param self FollowingMonController
---@param mapId integer
---@param tx FieldPlayer.MovementTransaction
function FollowingMonController:_beginVacatedSteer(mapId, tx)
  local speed = followerSpeed(tx.speed)
  self._consumedStep = {
    mapId = tx.mapId,
    fromX = tx.from.fieldX,
    fromZ = tx.from.fieldZ,
    toX = tx.to.fieldX,
    toZ = tx.to.fieldZ,
  }
  local partnerId = assert(self._actors:partnerId(), "vacated-tile steering requires the partner actor")
  local position = assert(self._actors:getPosition(partnerId), "partner position is required")
  if position.fieldX == tx.from.fieldX and position.fieldZ == tx.from.fieldZ then
    return
  end
  if self._paused or self._action ~= nil then
    self:_enqueueVacatedTarget(tx, speed)
    return
  end
  local target = { fieldX = tx.from.fieldX, fieldZ = tx.from.fieldZ }
  if not isAdjacent(position, target) then
    self:_discontinuity(mapId)
    return
  end
  local direction = directionFromTo(position, target)
  self:_beginActorWalk(mapId, direction, speed)
end

-- Replay the last real follower walk without steering toward the vacated
-- tile. A controller that never started a real walk yet seeds the replay
-- from the live transaction once; the seed is remembered only when its
-- walk actually starts, exactly like any other walk.
---@param self FollowingMonController
---@param mapId integer
---@param tx FieldPlayer.MovementTransaction
function FollowingMonController:_beginReplayLastWalk(mapId, tx)
  local remembered = self._lastFollowerCommand
  local direction ---@type string
  local speed ---@type string
  if remembered ~= nil then
    direction = assert(remembered.direction, "remembered follower direction is required")
    speed = assert(remembered.speed, "remembered follower speed is required")
    assert(MovementCalibration.SPEED_TICKS[speed] ~= nil, "unknown follower walk speed " .. tostring(speed))
  else
    direction = tx.direction
    speed = followerSpeed(tx.speed)
  end
  self._consumedStep = {
    mapId = tx.mapId,
    fromX = tx.from.fieldX,
    fromZ = tx.from.fieldZ,
    toX = tx.to.fieldX,
    toZ = tx.to.fieldZ,
  }
  assert(self._actors:partnerId() ~= nil, "replay requires the partner actor")
  if self._paused or self._action ~= nil then
    self:_enqueueReplay(mapId, direction, speed)
    return
  end
  self:_beginActorWalk(mapId, direction, speed)
end

-- Whether the live movement-start transaction already accounts for the
-- observed commit: the start was consumed by the ordinary follow or
-- rebaselined away by an accepted mode set, and its anchors match the
-- commit exactly. Such commits must not enqueue the vacated tile again.
---@param self FollowingMonController
---@param previous table<string, unknown>?
---@param anchor table<string, unknown>
---@param mapId integer
---@return boolean
function FollowingMonController:_commitMatchesLiveStart(previous, anchor, mapId)
  local player = self._playerOf()
  if type(player.movementTransaction) ~= "function" then
    return false
  end
  local tx = player:movementTransaction()
  if tx == nil or previous == nil then
    return false
  end
  if tx.revision ~= self._lastMovementTransactionRevision then
    return false
  end
  return tx.mapId == mapId
    and previous.mapId == mapId
    and anchor.mapId == mapId
    and tx.from.fieldX == previous.fieldX
    and tx.from.fieldZ == previous.fieldZ
    and tx.to.fieldX == anchor.fieldX
    and tx.to.fieldZ == anchor.fieldZ
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
  local consumed = self._consumedStep
  self._consumedStep = nil
  if
    consumed ~= nil
    and previous ~= nil
    and previous.mapId == consumed.mapId
    and previous.fieldX == consumed.fromX
    and previous.fieldZ == consumed.fromZ
    and anchor.mapId == consumed.mapId
    and anchor.fieldX == consumed.toX
    and anchor.fieldZ == consumed.toZ
  then
    -- The ordinary step already started from its movement-start transaction;
    -- the commit must not enqueue the same vacated tile a second time.
    return
  end
  if self:_commitMatchesLiveStart(previous, anchor, mapId) then
    -- The live start transaction already accounts for this commit: either
    -- the ordinary follow handled it, or an accepted mode set rebaselined
    -- past it on purpose. Either way the vacated tile is not re-enqueued.
    return
  end
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
  -- A commit observed without its movement start carries no transaction
  -- speed (ordinary walks are consumed at movement start with their own
  -- speed), so the resync anchor replays at the default trail pace.
  previous.speed = FollowingMonController.TRAIL_SPEED
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
  if head.direction ~= nil then
    local direction = assert(head.direction, "queued replay direction required")
    local speed = assert(head.speed, "queued replay speed required")
    assert(MovementCalibration.SPEED_TICKS[speed] ~= nil, "unknown queued replay speed " .. tostring(speed))
    self:_beginActorWalk(mapId, direction, speed)
    return
  end
  local position = assert(self._actors:getPosition(partnerId), "partner position is required")
  if not isAdjacent(position, head) then
    self:_discontinuity(mapId)
    return
  end
  local direction = directionFromTo(position, head)
  local speed = assert(head.speed, "queued trail speed required")
  assert(MovementCalibration.SPEED_TICKS[speed] ~= nil, "unknown queued trail speed " .. tostring(speed))
  self:_beginActorWalk(mapId, direction, speed)
end

-- Advance the one in-flight trail step; commit the queued anchor only
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
    if #self._queue > 0 then
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
  self._mapEntry = false
  if not self:isActive() then
    self:_clearAll()
    return
  end
  if not self:_permitted(mapId) then
    -- Permission lost: clear the visible partner but keep the party-derived
    -- lead, so returning to an allowed map republishes the same follower.
    -- The player baseline keeps tracking so no stale anchor replays later.
    self:_suppress()
    self:_observePlayer(mapId)
    return
  end
  if not sameIdentity(self._published, self._lead) then
    self:_publish(mapId)
  end
  self:_observeMovementStart(mapId)
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
  self._movementType = "follow_player"
  self._lastFollowerCommand = nil
  self._actors:clearPartner()
  self._published = nil
  self._pendingHiddenLead = nil
  self._mapEntry = false
  self._suspended = true
end

---@param paused boolean
---@param self FollowingMonController
function FollowingMonController:setMovementPaused(paused)
  paused = paused == true
  self._paused = paused
end

-- Settle means no in-flight trail and no source-required pending
-- movement: a paused queue is retained, not drained, so waits never hang on
-- a paused follower.
---@return boolean
---@param self FollowingMonController
function FollowingMonController:isMovementSettled()
  return self._action == nil and (self._paused or #self._queue == 0)
end

-- Settle any in-flight trail through the manager owner. Waiting tasks
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

-- Select the persistent follower movement mode. An accepted set is a reset
-- boundary: it cancels in-flight partner movement, drops queued and
-- consumed-step observations, and rebaselines player movement observation to
-- the current transaction/commit, so obligations from the previous mode
-- never execute under the new one. The pause latch survives; setting a mode
-- still starts no actor movement by itself, repeats stay idempotent, the
-- latest set wins, and anything outside the semantic trio faults.
---@param movementType string
---@param self FollowingMonController
function FollowingMonController:setMovementType(movementType)
  assert(FOLLOWER_MOVEMENT_TYPES[movementType] == true, "unknown follower movement mode " .. tostring(movementType))
  local partnerId = self._actors:partnerId()
  if partnerId ~= nil then
    self._actors:cancelScriptedMovement(partnerId)
  end
  self._action = nil
  self._queue = {}
  self._consumedStep = nil
  local player = self._playerOf()
  if type(player.movementTransaction) == "function" then
    local tx = player:movementTransaction()
    if tx ~= nil then
      self._lastMovementTransactionRevision = tx.revision
    end
  end
  self._lastPlayerRevision = player:movementRevision()
  self._lastAnchor = player:committedAnchor()
  self._movementType = movementType
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

-- Direct player-relative placement: copy the player's committed tile,
-- offset one tile by the source selector (0 north, 1 south, 2 west,
-- 3 east, anything else no offset), and face the partner per the source
-- direction byte. An absent partner is a no-op. Stale trail and in-flight
-- presentation clear first so normal following resumes from the placed
-- tile. A classified physical placement rejection reconciles canonically
-- behind the player instead of faulting the script; every other failure
-- propagates.
---@param offsetSelector integer source placement selector
---@param directionRaw integer source facing direction
---@param self FollowingMonController
function FollowingMonController:repositionRelativeToPlayer(offsetSelector, directionRaw)
  local partnerId = self._actors:partnerId()
  if partnerId == nil then
    return
  end
  local facing = FACING_BY_RAW[directionRaw]
  if facing == nil then
    Errors.raise(
      FieldErrors.ACTOR_PARTNER_FACING_INVALID,
      "unsupported partner facing " .. tostring(directionRaw),
      { facing = directionRaw }
    )
  end
  assert(facing ~= nil, "partner facing validation is required")
  local anchor = self._playerOf():committedAnchor()
  local offset = REPOSITION_OFFSETS[offsetSelector] or ZERO_OFFSET
  self._actors:cancelScriptedMovement(partnerId)
  self._action = nil
  self._queue = {}
  local mapId = assert(self._actors.currentMapId, "follower map is required")
  local ok, err = pcall(
    self._actors.setPosition,
    self._actors,
    partnerId,
    { fieldX = anchor.fieldX + offset.x, fieldZ = anchor.fieldZ + offset.z, worldY = anchor.worldY }
  )
  if not ok then
    if FieldActorManager.isPlacementRejection(err) then
      self:_discontinuity(mapId)
      return
    end
    error(err)
  end
  self._actors:setFacing(partnerId, facing)
end

-- Release follower state without touching saved data. The manager owns the
-- actor teardown afterwards.
---@param self FollowingMonController
function FollowingMonController:dispose()
  self._action = nil
  self._queue = {}
  self._actors:clearPartner()
  self._lead = nil
  self._lastFollowerCommand = nil
  self._published = nil
  self._pendingHiddenLead = nil
  self._lastMapId = nil
  self._mapEntry = false
  self._suspended = false
end

return FollowingMonController
