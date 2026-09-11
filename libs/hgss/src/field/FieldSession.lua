-- Runs the authoritative field simulation at 30 fixed ticks per second, the
-- DS field cadence (the fixed-step accumulator is render-delta independent).
-- Player movement advances before the camera so both consume the same
-- continuous XYZ. A modal dialogue owns the tick: once the fade/transition
-- phase (which cannot be active while a dialogue is open) has advanced, the
-- session steps the dialogue, advances the scene animation clock, and
-- returns, so movement, warps, interactions, actor pose clocks, and the
-- camera freeze until the dialogue closes.
-- Variable-delta `update(dt)` obtains a fresh input snapshot for every fixed
-- step it executes, so an edge can never be replayed across catch-up ticks;
-- `updateFixed(snapshot)` is the explicit deterministic unit-test API.
--
-- Step 6 is wired through the `interactions`
-- service: `resolve(snapshot)` returns an immutable InteractionIntent for an
-- idle player's Action edge, which the session dispatches to
-- `scriptClient:consume(intent, tick)`. A consumed interaction owns the
-- tick, so the same edge can never also start a move or a warp. There is no
-- fallback client: the load-time binding audit guarantees bindings for every
-- runtime map represented by the generated binding manifest.
-- The resolve service is invoked with the interactions table as self (colon
-- style), so implementations must declare a leading self parameter.
--
-- The session owns field-policy audio updates at semantic boundaries and
-- semantic effects from field traversal. FieldRuntime composes global sound
-- frame work after each fixed field tick.

local TransitionTrigger = require("libs.hgss.src.transition.TransitionTrigger")
local WarpSystem = require("libs.hgss.src.transition.WarpSystem")
local ScriptInteractionClient = require("libs.hgss.src.script.ScriptInteractionClient")
local FieldTransition = require("libs.hgss.src.transition.FieldTransition")
local FieldMapEntryController = require("libs.hgss.src.field.FieldMapEntryController")

---@class FieldSessionOptions
---@field versionId string
---@field currentMap RuntimeFieldMap
---@field player FieldPlayer
---@field camera FieldCamera
---@field transition FieldTransition
---@field actors FieldActorManager
---@field playerVisual FieldPlayerVisual?
---@field dialogue FieldDialogueController
---@field input FieldInput
---@field interactions FieldSession.Interactions
---@field eventResolver table<string, unknown>
---@field eventState { getVar: fun(self: table<string, unknown>, id: integer): integer }
---@field scriptScheduler Scheduler
---@field scriptClient ScriptInteractionClient
---@field menuHost FieldMenuHost
---@field contextChoice ContextChoiceProvider
---@field starterChoice table<string, unknown>? the modal starter-choice surface; while active the tick's UI events route to the script scheduler
---@field signpost FieldSignpostController
---@field applicationHost FieldApplicationHost the one application modal owner (Start Menu and its destinations)
---@field fieldEntranceIndicator FieldEntranceIndicator
---@field terrainEffects FieldTerrainEffectController?
---@field playerAvatar FieldPlayerAvatarState? surf-phase owner stepped once per fixed tick
---@field audio { updateField: fun(self: table<string, unknown>), play: fun(self: table<string, unknown>, idOrSymbol: string) }?
---@field navigationBoundary table<string, unknown>?
---@field initController table<string, unknown>|nil
---@field enterMapActors fun()?
---@field autoAcknowledgePresentation boolean?

---@class FieldSession.Interactions
---@field resolve fun(self: FieldSession.Interactions, snapshot: InteractionResolverSnapshot): InteractionIntent?

---@class FieldSession
---@field versionId string
---@field currentMap RuntimeFieldMap
---@field player FieldPlayer
---@field camera FieldCamera
---@field transition FieldTransition
---@field actors FieldActorManager
---@field playerVisual FieldPlayerVisual?
---@field dialogue FieldDialogueController
---@field input FieldInput
---@field interactions FieldSession.Interactions
---@field eventResolver table<string, unknown>
---@field eventState { getVar: fun(self: table<string, unknown>, id: integer): integer }
---@field scriptScheduler Scheduler
---@field scriptClient ScriptInteractionClient
---@field menuHost FieldMenuHost
---@field contextChoice ContextChoiceProvider
---@field starterChoice table<string, unknown>? the modal starter-choice surface; while active the tick's UI events route to the script scheduler
---@field signpost FieldSignpostController the fixed-tick signpost controller (save-gate interrogation only; the scheduler steps it)
---@field applicationHost FieldApplicationHost the one application modal owner (Start Menu and its destinations)
---@field fieldEntranceIndicator FieldEntranceIndicator
---@field terrainEffects FieldTerrainEffectController?
---@field playerAvatar FieldPlayerAvatarState? surf-phase owner stepped once per fixed tick
---@field audio { updateField: fun(self: table<string, unknown>), play: fun(self: table<string, unknown>, idOrSymbol: string) }?
---@field initController table<string, unknown>|nil
---@field mapEntryStage FieldMapEntryStage? read-only view of mapEntryController state
---@field mapEntryController FieldMapEntryController
---@field childResumePending boolean
---@field tick integer
---@field accumulator number
---@field navigationBoundary table<string, unknown>?
---@field _boundaryMovementDirection FieldDirection?
---@field _actorLocked fun(actorId: string): boolean
---@field _tickScratch FieldSession.TickScratch
local FieldSession = {}

---@param self FieldSession
---@param key string
---@return unknown
local function fieldSessionIndex(self, key)
  if key == "mapEntryStage" then
    return self.mapEntryController:currentStage()
  end
  return FieldSession[key]
end

FieldSession.__index = fieldSessionIndex

-- The DS field cadence: 30 fixed ticks per second, owned here.
FieldSession.FIXED_HZ = 30
FieldSession.FIXED_DT = 1 / FieldSession.FIXED_HZ
FieldSession.MAX_CATCH_UP_TICKS = 5

-- Float slack so a render delta that lands exactly on a tick boundary does
-- not leave a stale full tick in the accumulator.
local ACCUMULATOR_EPSILON = 1e-12

local DIRECTION_DELTAS = {
  north = { x = 0, z = -1 },
  south = { x = 0, z = 1 },
  west = { x = -1, z = 0 },
  east = { x = 1, z = 0 },
}

---@class FieldSession.TickScratch
---@field schedulerInput table<string, unknown>
---@field terrainInput { fieldX: integer, fieldZ: integer, facing: string }
---@field cameraTarget { x: number, y: number, z: number }
---@field entranceInput { map: RuntimeFieldMap, player: FieldPlayer, transition: { ownsField: boolean } }
---@field coordinateProbe { fieldX: integer, fieldZ: integer, facing: string }
---@field terrainResponseInput table<string, unknown>
---@field playerPresentation { locomotionActive: boolean, gesturePose: string?, gestureTick: integer?, gestureOffsetY: number }
---@field carriedMovementInput table<string, unknown>
---@field interactionSnapshot table<string, unknown>
---@field actorContext table<string, unknown>
---@field playerFacts { fieldX: integer, fieldZ: integer, surfaceId: integer, worldY: number }
---@field collisionCandidates table[]

-- Fixed-tick orchestration inputs owned by the session for its lifetime.
-- Each record has exactly one consuming collaborator shape; every use
-- overwrites all required fields and clears optional ones before the call,
-- because every consumer reads its input synchronously and never retains it.
-- The collision slots are preallocated so warmed ticks reuse them.
---@param actorLocked fun(actorId: string): boolean
---@return FieldSession.TickScratch
local function newTickScratch(actorLocked)
  local collisionCandidates = {
    { fieldX = 0, fieldZ = 0, surfaceId = 0 },
    { fieldX = 0, fieldZ = 0, surfaceId = 0 },
  }
  local playerFacts = { fieldX = 0, fieldZ = 0, surfaceId = 0, worldY = 0 }
  return {
    schedulerInput = {},
    terrainInput = { fieldX = 0, fieldZ = 0, facing = "south" },
    cameraTarget = { x = 0, y = 0, z = 0 },
    entranceInput = { map = nil, player = nil, transition = { ownsField = false } },
    coordinateProbe = { fieldX = 0, fieldZ = 0, facing = "south" },
    terrainResponseInput = {
      committed = true,
      destination = {
        behavior = 0,
        fieldX = 0,
        fieldZ = 0,
        worldY = 0,
        originY = 0,
      },
      direction = "south",
    },
    playerPresentation = { locomotionActive = false, gestureOffsetY = 0 },
    carriedMovementInput = {},
    interactionSnapshot = {},
    actorContext = {
      autonomousLocked = false,
      actorLocked = actorLocked,
      player = playerFacts,
      playerCandidates = collisionCandidates,
    },
    playerFacts = playerFacts,
    collisionCandidates = collisionCandidates,
  }
end

local function collapseCameraInterpolation(camera)
  if camera.collapseRenderInterpolation then
    camera:collapseRenderInterpolation()
  end
end

---@param scheduler table<string, unknown>
---@return string?
local function foregroundEnvironmentId(scheduler)
  if scheduler.foregroundEnvironmentId then
    return scheduler:foregroundEnvironmentId()
  end
  return nil
end

---@param scheduler table<string, unknown>
---@return boolean
local function playerInputOwned(scheduler)
  if scheduler.playerInputOwned then
    return scheduler:playerInputOwned()
  end
  return scheduler:playerMovementLocked()
end

---@param options unknown
---@return FieldSession
-- Every collaborator the session steps on a tick is required here: the
-- production runtime supplies them unconditionally, so a session missing any
-- of them -- or missing an operation a tick path calls unconditionally -- is
-- a composition fault rather than a partial-tick configuration.
function FieldSession.new(options)
  assert(type(options) == "table", "field session options required")
  ---@cast options FieldSessionOptions
  assert(options and options.versionId and options.currentMap, "field session identity required")
  assert(
    options.currentMap and type(options.currentMap.updateAnimated) == "function",
    "field session current map animation clock required"
  )
  assert(
    options.player
      and options.player.updateFixed
      and options.player.presentationState
      and options.player.presentationStateInto
      and options.player.collisionCandidatesInto
      and options.camera
      and options.camera.updateFixed,
    "field session player and camera required"
  )
  assert(
    options.transition and options.transition.updateFixed and options.transition.start,
    "field session transition required"
  )
  assert(options.actors and options.actors.step, "field session actors required")
  assert(options.input and options.input.snapshot, "field session input required")
  assert(options.dialogue and options.dialogue.isModal, "field session dialogue required")
  local scriptScheduler = options.scriptScheduler --[[@as table]]
  assert(
    scriptScheduler
      and scriptScheduler.step
      and (scriptScheduler.playerInputOwned or scriptScheduler.playerMovementLocked),
    "field session script scheduler required"
  )
  assert(options.scriptClient and options.scriptClient.consume, "field session script client required")
  assert(options.menuHost and options.menuHost.isModal and options.menuHost.advance, "field session menu host required")
  assert(options.contextChoice and options.contextChoice.isActive, "field session context choice required")
  assert(options.signpost and options.signpost.isModal, "field session signpost controller required")
  assert(
    options.applicationHost
      and options.applicationHost.isActive
      and options.applicationHost.updateFixed
      and options.applicationHost.requestOpen
      and options.applicationHost.takeReopen,
    "field session application host required"
  )
  assert(options.interactions and options.interactions.resolve, "field session interaction resolver required")
  assert(
    options.fieldEntranceIndicator and options.fieldEntranceIndicator.updateFixed,
    "field entrance indicator required"
  )
  assert(
    options.eventResolver and options.eventResolver.resolveCoordinate and options.eventResolver.resolvePassiveSign,
    "field event resolver required"
  )
  assert(options.eventState and options.eventState.getVar, "field event state required")
  if options.audio then
    assert(
      type(options.audio.updateField) == "function" and type(options.audio.play) == "function",
      "field session audio field-policy update and effect playback required"
    )
  end
  local session = setmetatable({
    versionId = options.versionId,
    currentMap = options.currentMap,
    player = options.player,
    camera = options.camera,
    transition = options.transition,
    actors = options.actors,
    playerVisual = options.playerVisual,
    dialogue = options.dialogue,
    input = options.input,
    interactions = options.interactions,
    eventResolver = options.eventResolver,
    eventState = options.eventState,
    scriptScheduler = options.scriptScheduler,
    scriptClient = options.scriptClient,
    menuHost = options.menuHost,
    contextChoice = options.contextChoice,
    starterChoice = options.starterChoice,
    signpost = options.signpost,
    applicationHost = options.applicationHost,
    fieldEntranceIndicator = options.fieldEntranceIndicator,
    terrainEffects = options.terrainEffects,
    playerAvatar = options.playerAvatar,
    audio = options.audio,
    initController = options.initController,
    mapEntryController = FieldMapEntryController.new({
      scriptScheduler = options.scriptScheduler,
      initController = options.initController,
      enterMapActors = options.enterMapActors,
      autoAcknowledgePresentation = options.autoAcknowledgePresentation == true,
    }),
    childResumePending = false,
    navigationBoundary = options.navigationBoundary,
    tick = 0,
    accumulator = 0,
    _boundaryMovementDirection = nil,
  }, FieldSession)
  -- One lock predicate for the session lifetime: it consults the scheduler
  -- at invocation time and never caches a lock result.
  local function actorLocked(actorId)
    return session.scriptScheduler:autonomousActorLocked(actorId)
  end
  session._actorLocked = actorLocked
  session._tickScratch = newTickScratch(session._actorLocked)
  return session
end

function FieldSession:beginMapEntry()
  self.mapEntryController:begin("full")
end

function FieldSession:onChildApplicationResume()
  self.childResumePending = true
end

-- A seamless connection never leaves the world: it stays outside the fade
-- transition and remains presentable for its whole lifecycle. Only a full
-- entry hides the destination until it has been presented.
function FieldSession:destinationWorldPresentable()
  return self.mapEntryController:destinationWorldPresentable()
end

function FieldSession:acknowledgeDestinationPresentation()
  self.mapEntryController:acknowledgeDestinationPresentation()
end

function FieldSession:actorTarget()
  return { x = self.player.worldX, y = self.player.worldY, z = self.player.worldZ }
end

local function isForegroundActive(scheduler)
  return foregroundEnvironmentId(scheduler) ~= nil
end

-- Combined ownership: explicit lock OR field-interaction claim. This is the
-- one fact that gates manual player-input initiation and Start Menu opening;
-- foreground identity alone (`isForegroundActive`) remains a separate,
-- narrower application/menu-lane concern.
local function isPlayerInputOwned(scheduler)
  return playerInputOwned(scheduler)
end

-- The idle-boundary gate for the Start Menu open edge: the menu may open
-- only at a settled field boundary -- player idle, transition idle, no
-- dialogue/signpost/script menu/context choice, no active foreground
-- script owner and no explicit player input lock. Any non-idle player
-- motion means "not idle"; the active application branch above has already
-- returned before this code runs.
---@return boolean
local function canOpenStartMenu(self)
  return self.player.motion == "idle"
    and self.transition.phase == FieldTransition.PHASES.idle
    and not self.dialogue:isModal()
    and not self.signpost:isModal()
    and not self.menuHost:isModal()
    and not self.contextChoice:isActive()
    and not isForegroundActive(self.scriptScheduler)
    and not isPlayerInputOwned(self.scriptScheduler)
end

function FieldSession:_advanceTick()
  local entranceInput = self._tickScratch.entranceInput
  entranceInput.map = self.currentMap
  entranceInput.player = self.player
  entranceInput.transition.ownsField = self.transition.phase == FieldTransition.PHASES.idle
  self.fieldEntranceIndicator:updateFixed(entranceInput)
  self.tick = self.tick + 1
end

function FieldSession:_emitTerrainResponse()
  if not self.terrainEffects then
    return
  end
  local origin = assert(self.currentMap.coordinateOrigin, "terrain response map origin is required")
  local localX, localZ = self.player.fieldX - origin.x, self.player.fieldZ - origin.z
  local cell = self.currentMap.collision:getLocal(localX, localZ)
  local terrainResponseInput = self._tickScratch.terrainResponseInput
  terrainResponseInput.committed = true
  terrainResponseInput.direction = self.player.facing
  local destination = terrainResponseInput.destination
  destination.behavior = cell.behavior
  destination.fieldX = self.player.fieldX
  destination.fieldZ = self.player.fieldZ
  destination.worldY = self.player.worldY
  destination.originY = self.currentMap.physicalOrigin and self.currentMap.physicalOrigin.y or 0
  destination.cellKey = self.player.committedSourceCellKey
  destination.sourceSurfaceId = self.player.committedSourceSurfaceId
  local responses = require("libs.hgss.src.world.FieldTerrainResponse").resolve(terrainResponseInput)
  self.terrainEffects:emitAll(responses)
end

local function resolveCoordinate(self)
  return self.eventResolver.resolveCoordinate(self.currentMap, self.player, self.eventState)
end

local function resolveCoordinateAhead(self, direction)
  local offset = assert(DIRECTION_DELTAS[direction], "coordinate probe direction required")
  local probe = self._tickScratch.coordinateProbe
  probe.fieldX = self.player.fieldX + offset.x
  probe.fieldZ = self.player.fieldZ + offset.z
  probe.facing = direction
  return self.eventResolver.resolveCoordinate(self.currentMap, probe, self.eventState)
end

local function hasCoordinateAhead(self, direction)
  local offset = assert(DIRECTION_DELTAS[direction], "coordinate probe direction required")
  local targetX = self.player.fieldX + offset.x
  local targetZ = self.player.fieldZ + offset.z
  local events = self.currentMap.fieldData.events and self.currentMap.fieldData.events.coordinates or {}
  for _, event in ipairs(events) do
    if
      targetX >= event.x
      and targetX < event.x + event.width
      and targetZ >= event.z
      and targetZ < event.z + event.height
    then
      return true
    end
  end
  return false
end

local function hasCoordinateAt(self, fieldX, fieldZ)
  local events = self.currentMap.fieldData.events and self.currentMap.fieldData.events.coordinates or {}
  for _, event in ipairs(events) do
    if
      fieldX >= event.x
      and fieldX < event.x + event.width
      and fieldZ >= event.z
      and fieldZ < event.z + event.height
    then
      return true
    end
  end
  return false
end

local function resolvePassiveSign(self)
  return self.eventResolver.resolvePassiveSign(self.currentMap, self.player)
end

-- The camera copies its target synchronously, so all fixed-tick camera
-- samples share one session record. The allocating actorTarget stays for
-- callers that retain the result.
---@param self FieldSession
---@return { x: number, y: number, z: number }
local function cameraTargetInto(self)
  local target = self._tickScratch.cameraTarget
  target.x = self.player.worldX
  target.y = self.player.worldY
  target.z = self.player.worldZ
  return target
end

-- An event consumed on the arrival tile owns its tick: the tile settles
-- instead of interpolating onward.
---@param self FieldSession
local function settleArrivalTile(self)
  if self.playerVisual then
    self.playerVisual:settle()
  end
  self.player:collapseRenderInterpolation()
  self.camera:updateFixed(cameraTargetInto(self))
  collapseCameraInterpolation(self.camera)
end

-- The script client resolves the binding; an unbound coordinate event is a
-- composition fault.
---@param self FieldSession
---@param intent InteractionIntent
local function consumeCoordinateIntent(self, intent)
  local result = self.scriptClient:consume(intent, self.tick + 1)
  assert(
    result == ScriptInteractionClient.RESULTS.started or result == ScriptInteractionClient.RESULTS.blocked,
    "a coordinate event must be bound: " .. tostring(intent.mapId)
  )
  settleArrivalTile(self)
end

-- A passive sign facing the player settles the field the same way a
-- coordinate event does once the script client has consumed it.
---@param self FieldSession
---@param intent InteractionIntent
local function consumePassiveIntent(self, intent)
  self.scriptClient:consume(intent, self.tick + 1)
  settleArrivalTile(self)
end

---@alias FieldTickOutcome "continue"|"consumed"
local TICK_CONTINUES = "continue"
local TICK_CONSUMED = "consumed"

---@param self FieldSession
---@return FieldTickOutcome
local function finishTick(self)
  self:_advanceTick()
  return TICK_CONSUMED
end

---@param self FieldSession
---@return FieldTickOutcome
local function advancePreSchedulerBoundary(self)
  if self.mapEntryController:isActive() then
    if self.mapEntryController:advance(self.tick + 1) then
      return finishTick(self)
    end
  elseif self.childResumePending and foregroundEnvironmentId(self.scriptScheduler) == nil then
    self.childResumePending = false
    if self.initController:hasLifecycle("on_resume") then
      assert(self.initController:startLifecycle("on_resume", self.tick + 1))
    end
    return finishTick(self)
  elseif
    self.initController
    and not self.initController.startLifecycle
    and self.initController:evaluate(self.tick + 1)
  then
    return finishTick(self)
  end
  return TICK_CONTINUES
end

---@param self FieldSession
---@return FieldTickOutcome
local function advancePostSchedulerBoundary(self)
  if self.mapEntryController:isActive() then
    if self.mapEntryController:advance(self.tick + 1) or self.mapEntryController:isActive() then
      return finishTick(self)
    end
  end
  if self.mapEntryController:takeConnectionArrival() then
    local arrivalIntent = resolveCoordinate(self)
    if arrivalIntent then
      consumeCoordinateIntent(self, arrivalIntent)
      return finishTick(self)
    end
    local arrivalPassiveIntent = resolvePassiveSign(self)
    if arrivalPassiveIntent then
      consumePassiveIntent(self, arrivalPassiveIntent)
      return finishTick(self)
    end
  end
  return TICK_CONTINUES
end

---@param self FieldSession
---@param inputSnapshot table<string, unknown>
---@return boolean playerInputOwnedAtTickStart
local function runScriptPhase(self, inputSnapshot)
  local playerInputOwnedAtTickStart = playerInputOwned(self.scriptScheduler)
  local schedulerInput = self._tickScratch.schedulerInput
  schedulerInput.heldDirection = inputSnapshot.heldDirection
  schedulerInput.pressedDirection = inputSnapshot.pressedDirection
  schedulerInput.pressedAction = inputSnapshot.actionPressed
  schedulerInput.pressedCancel = inputSnapshot.cancelPressed
  schedulerInput.menuEvents = nil
  schedulerInput.uiEvents = nil
  local menuModal = self.menuHost:isModal()
  local contextChoiceModal = self.contextChoice:isActive()
  -- The script-owned starter modal routes the same normalized UI events to
  -- the scheduler while it owns the choice; like the contextual choice it
  -- suppresses the raw field edges for that tick.
  local starterChoice = self.starterChoice
  local starterChoiceModal = starterChoice ~= nil and starterChoice:isActive()
  if menuModal or contextChoiceModal or starterChoiceModal then
    local uiEvents = self.input:uiSnapshot(self.tick + 1)
    if menuModal then
      schedulerInput.menuEvents = self.menuHost:inputEvents(uiEvents)
    else
      schedulerInput.uiEvents = uiEvents
    end
    schedulerInput.pressedDirection = nil
    schedulerInput.pressedAction = nil
    schedulerInput.pressedCancel = nil
  end
  self.scriptScheduler:step(self.tick + 1, schedulerInput)
  self.menuHost:advance(self.tick + 1)
  local contextChoiceNowModal = self.contextChoice:isActive()
  if not contextChoiceModal and contextChoiceNowModal then
    self.input:beginUi(self.tick + 1)
  elseif contextChoiceModal and not contextChoiceNowModal then
    self.input:clearUi()
  end
  local starterChoiceNowModal = starterChoice ~= nil and starterChoice:isActive()
  if not starterChoiceModal and starterChoiceNowModal then
    self.input:beginUi(self.tick + 1)
  elseif starterChoiceModal and not starterChoiceNowModal then
    self.input:clearUi()
  end
  return playerInputOwnedAtTickStart
end

function FieldSession:updateFixed(inputSnapshot)
  -- Ordinary field-audio policy runs for same-zone completed steps. Map-entry
  -- and changed-zone audio are owned by FieldAudioController:enterMap and
  -- FieldAudioController:enterZone respectively.
  inputSnapshot = inputSnapshot or self.input:snapshot()
  -- The avatar presentation phase advances once per fixed tick before any
  -- modal branch can return, so the surf bob runs on the field cadence even
  -- while ordinary world simulation is frozen.
  if self.playerAvatar then
    self.playerAvatar:updateFixed()
  end
  local carriedBoundaryDirection = self._boundaryMovementDirection
  self._boundaryMovementDirection = nil
  if self.terrainEffects then
    local terrainInput = self._tickScratch.terrainInput
    terrainInput.fieldX = self.player.fieldX
    terrainInput.fieldZ = self.player.fieldZ
    terrainInput.facing = self.player.facing
    self.terrainEffects:updateFixed(terrainInput)
  end
  -- The door/stair choreography drives the player during the locked
  -- transition: the pose clock hears the locomotion state at tick start, the
  -- camera tracks the continuous XYZ, and the scene's animated props
  -- advance under the choreographed locked tick. The camera samples on
  -- every locked tick and on the completion tick -- never coupled to
  -- player motion -- so interpolation pairs collapse instead of replaying.
  local locomotionAtTickStart = self.player:presentationStateInto(self._tickScratch.playerPresentation).locomotionActive
  local playerAdvanced = self.transition:updateFixed()
  if self.transition.locked or self.transition.completed then
    if not playerAdvanced and self.player.motion == "idle" then
      self.player:collapseRenderInterpolation()
    end
    self.currentMap:updateAnimated()
    if playerAdvanced and self.playerVisual then
      self.playerVisual:updateFixed(locomotionAtTickStart)
    end
    self.camera:updateFixed(cameraTargetInto(self))
    if self.transition.completed then
      collapseCameraInterpolation(self.camera)
    end
    -- Keep the just-arrived tile stable until the application consumes the
    -- completion event and autosaves it, even when movement remains held.
    if self.transition.completed and self.input.clearEdges then
      self.input:clearEdges()
    end
    self:_advanceTick()
    return
  end

  -- Application ownership: while the application host is active (Start Menu
  -- or a child application, in any of its phases) it is the one modal owner
  -- -- the session steps only it, once per fixed tick, and freezes world
  -- simulation (no player/actors/scheduler/interaction/movement). Opening a
  -- second incompatible modal is a programming invariant, asserted here.
  if self.applicationHost:isActive() then
    assert(
      not self.dialogue:isModal() and not self.signpost:isModal() and not self.menuHost:isModal(),
      "the application host owns the tick; no other modal may be active"
    )
    local uiEvents = self.input:uiSnapshot(self.tick + 1)
    -- While the Start Menu is active, the menu button has the same close
    -- semantics as HGSS X: a fresh menu edge becomes the controller's menu
    -- event. A child application's own input policy applies instead.
    if inputSnapshot.menuPressed then
      uiEvents[#uiEvents + 1] = { type = "menu" }
    end
    local status = self.applicationHost.status and self.applicationHost:status() or nil
    local wasApplication = status and status.phase == "application"
    self.applicationHost:updateFixed(uiEvents)
    local afterStatus = self.applicationHost.status and self.applicationHost:status() or nil
    if wasApplication and afterStatus and afterStatus.phase == "fading_in" then
      self:onChildApplicationResume()
    end
    self:_advanceTick()
    return
  end

  -- Modal ownership: while a dialogue is open the world steps freeze -- no
  -- queued visibility changes, no facing-warp check, no movement, no warp
  -- commit, no pose clocks, no camera motion. Only the dialogue reads this
  -- tick's input, and the scene animation clock keeps advancing: HGSS's
  -- field update path does not couple map-prop animation progression to
  -- dialogue ownership, so wind/machines keep running while a message box
  -- is up.
  -- Script-owned boxes are exempt: the script scheduler steps them from its
  -- own async phase and the script phase owns the tick instead.
  if self.dialogue:isModal() and not (self.dialogue.isScriptOwned and self.dialogue:isScriptOwned()) then
    self.currentMap:updateAnimated()
    self.dialogue:step(inputSnapshot)
    self:_advanceTick()
    return
  end

  -- Field animation clock: the world's animated props advance once per tick
  -- -- ordinary movement, script-locked ticks, interaction ticks, the
  -- transition-start tick, and modal-dialogue ticks alike (transition ticks
  -- advance it in the branch above). FieldSession owns this clock; the map
  -- aggregate fans one call out to the central scene runtime and the
  -- neighbor coverage runtime. No other module steps it.
  self.currentMap:updateAnimated()

  if advancePreSchedulerBoundary(self) == TICK_CONSUMED then
    return
  end

  local playerInputOwnedAtTickStart = runScriptPhase(self, inputSnapshot)
  if advancePostSchedulerBoundary(self) == TICK_CONSUMED then
    return
  end

  local playerInputOwnedAfterScheduler = isPlayerInputOwned(self.scriptScheduler)
  local foregroundActive = isForegroundActive(self.scriptScheduler)
  local inputSuppressedThisTick = playerInputOwnedAtTickStart or playerInputOwnedAfterScheduler

  -- Start Menu arbitration: a pending script reopen request (opcode 61's
  -- startMenuReopen service) opens the menu unconditionally at this point,
  -- then the menu edge is gated by the idle-boundary check (checked after
  -- the single script-scheduler step established the field lock state,
  -- before actor stepping, interaction resolution, warps, or player
  -- movement). The host's boolean answers "did the open consume this tick?":
  -- true for a successful open and for a fatal composition failure (the
  -- host has entered its terminal failed state, which must freeze the rest
  -- of this tick); false means the menu is unavailable and the field
  -- continues stepping normally. This arbitration freezes world
  -- presentation (actors, player, camera) on its tick, so it runs before
  -- the actor step.
  if self.applicationHost:takeReopen(self.tick + 1) then
    self:_advanceTick()
    return
  end
  if inputSnapshot.menuPressed and canOpenStartMenu(self) then
    if self.applicationHost:requestOpen(self.tick + 1) then
      self:_advanceTick()
      return
    end
  end

  -- World presentation advances even while a foreground script runs, and
  -- exactly once per world-advancing tick (not once per same-run presence
  -- flush). Input suppression does not freeze it.
  local playerFacts = self._tickScratch.playerFacts
  playerFacts.fieldX = self.player.fieldX
  playerFacts.fieldZ = self.player.fieldZ
  playerFacts.surfaceId = self.player.surfaceId
  playerFacts.worldY = self.player.worldY
  local actorContext = self._tickScratch.actorContext
  actorContext.autonomousLocked = self.scriptScheduler:autonomousActorsLocked()
  actorContext.playerCandidates = self.player:collisionCandidatesInto(self._tickScratch.collisionCandidates)
  self.actors:step(self.tick + 1, actorContext)

  if self.childResumePending then
    self:_advanceTick()
    return
  end

  if self.initController and self.initController.startLifecycle then
    local evaluateFrame = self.initController.evaluateFrame
    if evaluateFrame and evaluateFrame(self.initController, self.tick + 1) then
      self:_advanceTick()
      return
    end
  end

  if inputSuppressedThisTick then
    if self.player.motion == "idle" and type(self.player.collapseRenderInterpolation) == "function" then
      self.player:collapseRenderInterpolation()
    end
    collapseCameraInterpolation(self.camera)
    if self.playerVisual then
      local suppressedLocomotionAtTickStart =
        self.player:presentationStateInto(self._tickScratch.playerPresentation).locomotionActive
      self.playerVisual:updateFixed(suppressedLocomotionAtTickStart)
    end
    self.camera:updateFixed(cameraTargetInto(self))
    self:_advanceTick()
    return
  end

  -- Active foreground blocks acquiring another foreground owner even without
  -- an explicit player lock, but does not suppress player movement when
  -- input is not locked.

  if self.transition.suppression then
    self.transition.suppression = WarpSystem.updateSuppression(
      self.transition.suppression,
      self.currentMap.mapId,
      self.player.fieldX,
      self.player.fieldZ
    )
  end

  if not foregroundActive then
    -- Facing-trigger path: an idle player pressing a direction
    -- evaluates the HGSS input path -- a blocked DOOR tile ahead, or a
    -- direction-gated standing door/stairs/warp on the player's own tile.
    -- A valid movement-driven traversal/warp candidate outranks a passive
    -- directional sign eligible on the same tick, so this check runs first;
    -- the passive sign below is only reached when no valid traversal exists.
    -- A seam the navigation boundary already owns is never also an input-path
    -- trigger: the boundary evaluates and commits its own zone crossing once
    -- the step completes.
    local direction = inputSnapshot.pressedDirection or inputSnapshot.heldDirection
    if self.player.motion == "idle" and direction then
      -- A coordinate event on the tile being entered owns the step, even when
      -- that tile is also a direction-triggered warp. The ROM evaluates the
      -- arrival event after the step; pre-empting it here would leave the
      -- generated coordinate script unresolved.
      local coordinateAhead = resolveCoordinateAhead(self, direction)
      local seam = self.navigationBoundary
        and self.navigationBoundary:crossesLogicalZone(self.currentMap, self.player, direction)
      local trigger = seam and nil
        or TransitionTrigger.inputPath(self.currentMap, self.player.fieldX, self.player.fieldZ, direction)
      if
        trigger
        and coordinateAhead == nil
        and not hasCoordinateAhead(self, direction)
        and (
          trigger.kind == "directional"
          or not WarpSystem.isSuppressed(
            self.transition.suppression,
            self.currentMap.mapId,
            trigger.warp.x,
            trigger.warp.z
          )
        )
      then
        self.player.facing = direction
        self.transition:start(self.currentMap, trigger, direction)
        self:_advanceTick()
        return
      end
    end

    -- An idle player's Action edge resolves an interaction
    -- before movement or warps are evaluated. A consumed interaction owns the
    -- tick (the dialogue becomes modal on it), so the same edge cannot also
    -- start a move or warp. The edge itself was already consumed by the input
    -- snapshot, so a held Action cannot re-open anything. Action-button
    -- interactions retain their explicit-button semantics regardless of
    -- traversal precedence -- they are only eligible when the action button
    -- itself is the initiating input.
    if self.player.motion == "idle" and inputSnapshot.actionPressed then
      local interactionSnapshot = self._tickScratch.interactionSnapshot
      interactionSnapshot.runtimeMap = self.currentMap
      interactionSnapshot.fieldX = self.player.fieldX
      interactionSnapshot.fieldZ = self.player.fieldZ
      interactionSnapshot.surfaceId = self.player.surfaceId
      interactionSnapshot.worldY = self.player.worldY
      interactionSnapshot.facing = self.player.facing
      interactionSnapshot.tick = self.tick + 1
      local intent = self.interactions:resolve(interactionSnapshot)
      if intent then
        -- The script client resolves the binding, starts the composed script,
        -- and runs it during this tick. There is no fallback client: the
        -- binding audit at load time guarantees every interactable event is
        -- bound, so an unmapped intent here is a composition fault, not a
        -- silent absorption.
        local result = self.scriptClient:consume(intent, self.tick + 1)
        local results = ScriptInteractionClient.RESULTS
        assert(
          result == results.started or result == results.blocked,
          "an interactable event must be bound: " .. tostring(intent.mapId)
        )
        self:_advanceTick()
        return
      end
    end

    -- A coordinate event on the tile the passive sign also faces is a
    -- movement-driven traversal candidate that only resolves once the player
    -- actually steps onto that tile (the completed-step branch below). Firing
    -- the passive sign here, before the step, would hijack the field ahead of
    -- that traversal ever being attempted, so the passive sign yields to a
    -- pending coordinate on the same tile and lets the step proceed normally.
    local passiveDirection = inputSnapshot.pressedDirection or inputSnapshot.heldDirection
    if
      self.player.motion == "idle"
      and passiveDirection == self.player.facing
      and not hasCoordinateAhead(self, passiveDirection)
    then
      local intent = resolvePassiveSign(self)
      if intent then
        self.scriptClient:consume(intent, self.tick + 1)
        self:_advanceTick()
        return
      end
    end
  end

  -- The pose clock treats a tick as locomoting if the player was locomoting at either
  -- end of it, so the gait phase carries across the tile commit instead of
  -- restarting on every arrival (the ROM's walk range spans two tiles).
  local ordinaryLocomotionAtTickStart =
    self.player:presentationStateInto(self._tickScratch.playerPresentation).locomotionActive

  local movementInput = inputSnapshot
  if carriedBoundaryDirection then
    movementInput = self._tickScratch.carriedMovementInput
    -- A carried completion direction is a fresh one-shot command. Keeping
    -- raw held input here would let FieldPlayer admit its buffered direction
    -- as a walking continuation and skip the required turn.
    movementInput.heldDirection = nil
    movementInput.pressedDirection = carriedBoundaryDirection
  end
  local motionAtPlayerUpdateStart = self.player.motion
  local stepCompleted = self.player:updateFixed(movementInput) == true
  if motionAtPlayerUpdateStart == "idle" and self.player.motion == "jumping" and self.audio then
    self.audio:play("SEQ_SE_DP_DANSA")
  end
  local completionDirection
  if motionAtPlayerUpdateStart == "walking" and stepCompleted then
    completionDirection = inputSnapshot.pressedDirection or inputSnapshot.heldDirection
  elseif motionAtPlayerUpdateStart == "turning" and self.player.motion == "idle" then
    completionDirection = inputSnapshot.pressedDirection or inputSnapshot.heldDirection
  end
  if stepCompleted then
    local zoneChanged = false
    if self.navigationBoundary then
      local boundaryResult = self.navigationBoundary:afterCommittedMove(self.currentMap, self.player, self.camera)
      if boundaryResult and boundaryResult.newMapId then
        zoneChanged = true
        self.currentMap = self.navigationBoundary.zoneController.currentMap
        self.transition.suppression = {
          mapId = boundaryResult.newMapId,
          fieldX = self.player.fieldX,
          fieldZ = self.player.fieldZ,
        }
        -- A seamless crossing enters the destination map before its events
        -- run: the destination transition lifecycle and its actor activation
        -- own the next ticks, and the arrival tile's event -- its coordinate
        -- event, or the passive sign it faces -- waits for them instead of
        -- resolving against a map that is not live yet.
        self.mapEntryController:begin("connection")
      end
    end
    self:_emitTerrainResponse()
    if self.audio and not zoneChanged then
      self.audio:updateField()
    end
    if not zoneChanged then
      local coordinateIntent = resolveCoordinate(self)
      if coordinateIntent then
        consumeCoordinateIntent(self, coordinateIntent)
        self:_advanceTick()
        return
      end
      -- Standing-trigger path: a completed step onto a warp tile
      -- evaluates the HGSS step path -- north/panel/ladder-down/escalator
      -- behaviors only; direction-gated warps wait for the facing path above.
      local trigger =
        TransitionTrigger.stepPath(self.currentMap, self.player.fieldX, self.player.fieldZ, self.player.facing)
      if
        trigger
        and not hasCoordinateAt(self, self.player.fieldX, self.player.fieldZ)
        and not WarpSystem.isSuppressed(
          self.transition.suppression,
          self.currentMap.mapId,
          trigger.warp.x,
          trigger.warp.z
        )
      then
        self.transition:start(self.currentMap, trigger, self.player.facing)
        self:_advanceTick()
        return
      end
      local passiveIntent = resolvePassiveSign(self)
      if passiveIntent then
        consumePassiveIntent(self, passiveIntent)
        self:_advanceTick()
        return
      end
    end
  end
  if completionDirection then
    self._boundaryMovementDirection = completionDirection
  end
  -- Pose clocks advance only on a tick that could change the world, so a fade or
  -- a locked transition freezes animation instead of walking it in place.
  if self.playerVisual then
    self.playerVisual:updateFixed(ordinaryLocomotionAtTickStart)
  end
  self.camera:updateFixed(cameraTargetInto(self))
  self:_advanceTick()
end

---@param dt number
---@param _ table<string, unknown>? legacy snapshot, intentionally ignored
---@return integer
function FieldSession:update(dt, _)
  assert(type(dt) == "number" and dt >= 0, "non-negative update dt required")
  self.accumulator = self.accumulator + dt
  local executed = 0
  while
    self.accumulator + ACCUMULATOR_EPSILON >= FieldSession.FIXED_DT and executed < FieldSession.MAX_CATCH_UP_TICKS
  do
    self.accumulator = self.accumulator - FieldSession.FIXED_DT
    self:updateFixed()
    executed = executed + 1
  end
  if self.accumulator + ACCUMULATOR_EPSILON >= FieldSession.FIXED_DT then
    local discarded = math.floor((self.accumulator + ACCUMULATOR_EPSILON) / FieldSession.FIXED_DT)
    self.accumulator = self.accumulator - discarded * FieldSession.FIXED_DT
  end
  return executed
end

-- The render interpolation factor. The catch-up cap and the drop branch can
-- leave a small float residual outside the tick interval, so the factor is
-- clamped defensively into [0, 1] for presentation consumers.
function FieldSession:renderAlpha()
  local alpha = self.accumulator / FieldSession.FIXED_DT
  return math.min(1, math.max(0, alpha))
end

return FieldSession
