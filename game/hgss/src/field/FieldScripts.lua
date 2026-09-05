-- Game-side field-script platform construction: builds the registry from the
-- compiled script cache plus explicit overrides, composition, the full task
-- registry, service adapters, and the scheduler + interaction client the
-- session steps. FieldState wires the result into FieldSession.

local Bindings = require("libs.hgss.src.script.Bindings")
local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local ScriptActorWorld = require("libs.hgss.src.script.ScriptActorWorld")
local ScriptDialogueHost = require("libs.hgss.src.script.ScriptDialogueHost")
local ScriptMenuHost = require("libs.hgss.src.script.ScriptMenuHost")
local ScriptSignpostHost = require("libs.hgss.src.script.ScriptSignpostHost")
local ScriptInteractionClient = require("libs.hgss.src.script.ScriptInteractionClient")
local ScriptMapsService = require("libs.hgss.src.script.ScriptMapsService")
local WorldState = require("libs.hgss.src.script.WorldState")
local Scheduler = require("libs.script.src.Scheduler")
local HgssScript = require("libs.hgss.src.script.Composition")
local FieldScriptCompatibility = require("game.hgss.src.field.FieldScriptCompatibility")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local MapInitScriptController = require("libs.hgss.src.field.MapInitScriptController")

-- The player facade the script services consume: position/facing/gender/name
-- plus the mutation hooks the movement tasks use (the player can be a
-- scripted actor only while the field is locked). The facade holds the live
-- FieldPlayer by reference so map swaps can rebind it.
---@class ScriptPlayerFacade
---@field private _player FieldPlayer|nil
---@field private _profile table<string, unknown>|nil { gender: integer, name: string }
---@field private _avatarState table<string, unknown>|nil avatar transition owner for queue/apply consumers
---@field private _avatarApplier fun(): table<string, unknown>|nil materializes pending transitions through the owning runtime composition
local ScriptPlayerFacade = {}
ScriptPlayerFacade.__index = ScriptPlayerFacade

---@param player FieldPlayer
---@return ScriptPlayerFacade
local function playerFacade(player)
  return setmetatable({
    _player = player,
    _profile = nil,
  }, ScriptPlayerFacade)
end

function ScriptPlayerFacade:setPlayer(player)
  self._player = player
end

-- Wire the avatar transition owner once the composition owns one; transition
-- queue/apply consumers reach it through this facade only. The owner must
-- carry the queue/apply shape so direct setter callers cannot bypass the
-- composition validation.
---@param avatarState table<string, unknown>
function ScriptPlayerFacade:setAvatarState(avatarState)
  assert(
    type(avatarState.queueTransition) == "function" and type(avatarState.applyTransitions) == "function",
    "field scripts require a queue/apply-shaped avatar transition owner"
  )
  self._avatarState = avatarState
end

-- Wire the runtime materializer that applies pending transitions with their
-- visual and sound effects. Queue/apply consumers require it: an apply
-- without one fails instead of moving avatar state without presenting it.
---@param applier fun(): table<string, unknown>|nil
function ScriptPlayerFacade:setAvatarApplier(applier)
  assert(type(applier) == "function", "the avatar applier must be callable")
  self._avatarApplier = applier
end

-- Queue one semantic transition by opaque name. Never touches logical
-- movement, coordinates, or facing; pending membership belongs to the
-- transition owner, not to the live player instance.
---@param name string
function ScriptPlayerFacade:queueAvatarTransition(name)
  assert(type(name) == "string", "avatar transition name must be a string")
  local owner = self._avatarState
  if owner == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "player facade has no avatar transition owner", {})
  end
  (owner --[[@as table]]):queueTransition(name)
end

-- Apply every pending transition in source order and continue same-tick
-- through the runtime materializer, so the final visual and sound effects
-- apply through the owning composition. An apply without a materializer is
-- a composition fault: avatar state must never move without presenting it.
---@return table<string, unknown>|nil
function ScriptPlayerFacade:applyAvatarTransitions()
  local applier = self._avatarApplier
  if applier ~= nil then
    return applier()
  end
  Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "player facade has no avatar transition materializer", {})
end

-- Wire the real player profile (gender and name) when the game owns one;
-- until then profile-dependent operations fault instead of fabricating
-- values.
---@param profile table<string, unknown> { gender: integer, name: string }
function ScriptPlayerFacade:setProfile(profile)
  self._profile = profile
end

function ScriptPlayerFacade:position()
  local player = assert(self._player, "player facade has no live player")
  return { fieldX = player.fieldX, fieldZ = player.fieldZ, worldY = player.worldY }
end

function ScriptPlayerFacade:facing()
  local player = assert(self._player, "player facade has no live player")
  return player.facing
end

function ScriptPlayerFacade:gender()
  local profile = self._profile
  if profile == nil or profile.gender == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "no player profile is wired; gendered messages cannot resolve",
      {}
    )
  end
  return profile --[[@as { gender: integer, name: string }]].gender
end

function ScriptPlayerFacade:name()
  local profile = self._profile
  if profile == nil or profile.name == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "no player profile is wired; player-name text cannot resolve", {})
  end
  return profile --[[@as { gender: integer, name: string }]].name
end

function ScriptPlayerFacade:turn(direction)
  local player = assert(self._player, "player facade has no live player")
  assert(player.turn, "player facade requires turn")
  player:turn(direction)
end

function ScriptPlayerFacade:setPosition(position)
  local player = assert(self._player, "player facade has no live player")
  assert(player.setScriptPosition, "player facade requires setScriptPosition")
  player:setScriptPosition(position)
end

function ScriptPlayerFacade:beginScriptedAction(action)
  local player = assert(self._player, "player facade has no live player")
  assert(player.beginScriptedAction, "player missing beginScriptedAction")
  player:beginScriptedAction(action)
end

function ScriptPlayerFacade:advanceScriptedAction(progressTicks, durationTicks)
  local player = assert(self._player, "player facade has no live player")
  assert(player.advanceScriptedAction, "player missing advanceScriptedAction")
  player:advanceScriptedAction(progressTicks, durationTicks)
end

function ScriptPlayerFacade:commitScriptedAction()
  local player = assert(self._player, "player facade has no live player")
  assert(player.commitScriptedAction, "player missing commitScriptedAction")
  player:commitScriptedAction()
end

function ScriptPlayerFacade:cancelScriptedMovement()
  local player = assert(self._player, "player facade has no live player")
  assert(player.cancelScriptedMovement, "player missing cancelScriptedMovement")
  player:cancelScriptedMovement()
end

function ScriptPlayerFacade:isScriptedMoving()
  local player = assert(self._player, "player facade has no live player")
  assert(player.isScriptedMoving, "player missing isScriptedMoving")
  return player:isScriptedMoving()
end

---@class FieldScriptsOptions
---@field cacheFs CacheFs
---@field overrideFs table<string, unknown> read-shaped filesystem for data/scripts/overrides
---@field eventState FieldEventState
---@field actors FieldActorManager
---@field player FieldPlayer
---@field profile table<string, unknown>|nil { gender: integer, name: string }
---@field dialogue FieldDialogueController
---@field messageProvider FieldMessageProvider
---@field layout fun(formatted: table<string, unknown>): table<string, unknown>
---@field fontDef table<string, unknown>
---@field frameIndex integer|nil player-selected HGSS user-frame index for dialogue requests
---@field signpost FieldSignpostController the fixed-tick signpost controller the host advances
---@field windowStyles FieldWindowStyles the immutable per-runtime window style catalogue the high-level sign ops resolve appearances against
---@field transition FieldTransition
---@field mapLoader FieldMapLoader
---@field sourceMap RuntimeFieldMap
---@field seedText string|nil
---@field audio table<string, unknown>|nil optional audio backend (absent -> SCRIPT_SERVICE_MISSING on use)
---@field weather table<string, unknown>|nil optional live-weather backend
---@field camera table<string, unknown>|nil optional camera backend
---@field screen table<string, unknown>|nil optional screen backend
---@field events table<string, unknown>|nil optional event sink
---@field auxiliaryUi AuxiliaryFieldUi logical auxiliary field UI state
---@field contextChoice ContextChoiceProvider contextual two-choice provider
---@field menu FieldMenuHost modal field menu host
---@field followingMon table<string, unknown>|nil the live following-mon controller for follower script operations (absent -> SCRIPT_SERVICE_MISSING on use)
---@field followerTransition table<string, unknown>|nil the transient follower-transition owner the nonblocking transition command starts (absent -> SCRIPT_SERVICE_MISSING on use)
---@field starterBalls table<string, unknown>|nil the Elm starter-ball runtime-prop controller (absent -> SCRIPT_SERVICE_MISSING on use)

---@class FieldScripts
---@field registry table<string, unknown>
---@field composition Composition
---@field bindings table<string, unknown>
---@field scheduler Scheduler
---@field client ScriptInteractionClient
---@field worldState WorldState
---@field dialogueHost ScriptDialogueHost
---@field mapsService ScriptMapsService
---@field menuHost ScriptMenuHost
---@field signpostHost ScriptSignpostHost
---@field player ScriptPlayerFacade
---@field cacheFs table<string, unknown> CacheFs-shaped
---@field overrideFs table<string, unknown> read-shaped filesystem for data/scripts/overrides
---@field registrySnapshotKey string|nil key the live registry was built under
---@field registrySnapshotUsed boolean true when a matching snapshot skipped per-use validation
---@field warmup RegistryWarmup|nil background warm-up after a snapshot miss
---@field taskRegistry TaskRegistry the live registered-task registry
---@field initController MapInitScriptController
---@field compatibility FieldScriptCompatibility
---@field mapSource RuntimeFieldMap the active runtime map map-scoped script state is bound to
local FieldScripts = {}
FieldScripts.__index = FieldScripts

-- opts.overrideFs: love.filesystem-shaped read access for the repo
-- `data/scripts/overrides` tree (the game mounts `data` before calling).
---@param opts FieldScriptsOptions
---@return FieldScripts
function FieldScripts.new(opts)
  assert(
    type(opts) == "table" and opts.cacheFs and opts.overrideFs and opts.eventState and opts.actors and opts.player,
    "field scripts require cache, overrides, world, and actors"
  )
  assert(
    opts.dialogue and opts.messageProvider and opts.layout and opts.fontDef,
    "field scripts require the dialogue stack"
  )
  assert(opts.signpost and opts.signpost.isModal, "field scripts require the signpost controller")
  assert(opts.windowStyles and opts.windowStyles.resolve, "field scripts require the window style catalogue")
  assert(
    opts.transition and opts.mapLoader and opts.sourceMap and opts.auxiliaryUi and opts.menu and opts.contextChoice,
    "field scripts require transition, auxiliary UI, context choice, and menu host"
  )
  assert(
    (opts.playerAvatar == nil) == (opts.avatarApplier == nil),
    "field scripts require playerAvatar and avatarApplier together"
  )

  -- The registry is always installed lazily: only the generated layer's
  -- presence comes from the index, and each script decodes on first use. A
  -- matching snapshot proves the corpus unchanged since the cache build
  -- validated it (skip per-use validation) and restores the memoized
  -- fingerprint; on a miss the background warm-up decodes, hashes, and
  -- publishes the snapshot while the game plays, and the first save finishes
  -- it. The override layer is always loaded and validated eagerly.
  local compatibility = FieldScriptCompatibility.new({ cacheFs = opts.cacheFs, overrideFs = opts.overrideFs })
  local registry = compatibility.registry
  local composition = compatibility.composition
  local bindings = Bindings.new()

  local worldState = WorldState.new({
    eventState = opts.eventState,
    catalogs = {
      flags = FieldScriptSymbols.flagsByName,
      variables = FieldScriptSymbols.variablesByName,
    },
    seed = opts.seedText or opts.cacheFs.versionId,
  })
  local player = playerFacade(opts.player)
  -- The real player profile (gender and name) is wired when the game owns
  -- one; without it, profile-dependent operations fault instead of
  -- fabricating values.
  if opts.profile ~= nil then
    player:setProfile(opts.profile)
  end
  -- The avatar transition owner is runtime-owned; the facade only carries it
  -- for transition queue/apply consumers.
  if opts.playerAvatar ~= nil then
    player:setAvatarState(opts.playerAvatar)
    player:setAvatarApplier(assert(opts.avatarApplier))
  end
  local actors = ScriptActorWorld.new(opts.actors --[[@as ScriptActorManager]], player)
  local dialogueHost = ScriptDialogueHost.new({
    controller = opts.dialogue,
    provider = opts.messageProvider,
    layout = opts.layout,
    fontDef = opts.fontDef,
    player = player,
    world = worldState,
    mons = opts.mons,
    frameIndex = opts.frameIndex,
  })
  local mapsService = ScriptMapsService.new({
    transition = opts.transition,
    loader = opts.mapLoader,
    sourceMap = opts.sourceMap,
    screen = opts.screen,
  })
  local function resolveText(message)
    return dialogueHost:resolveMessage(message, {}, {})
  end
  local menuHost = ScriptMenuHost.new({
    provider = opts.messageProvider,
    resolveText = resolveText,
  })
  -- The signpost host reuses the dialogue host's public message-resolution
  -- operation through injection; it never reaches an underscored helper or
  -- duplicates substitution semantics.
  local function resolveMessage(message, messageBindings, textArgs)
    return dialogueHost:resolveMessage(message, messageBindings, textArgs)
  end
  local signpostHost = ScriptSignpostHost.new({
    controller = opts.signpost,
    resolveMessage = resolveMessage,
  })

  ---@class FieldScriptsPlatform: FieldScripts
  ---@field initController MapInitScriptController
  local platform = setmetatable({
    compatibility = compatibility,
    registry = registry,
    registrySnapshotKey = compatibility.registrySnapshotKey,
    registrySnapshotUsed = compatibility.registrySnapshotUsed,
    warmup = compatibility.warmup,
    cacheFs = opts.cacheFs,
    overrideFs = opts.overrideFs,
    composition = composition,
    bindings = bindings,
    worldState = worldState,
    dialogueHost = dialogueHost,
    mapsService = mapsService,
    menuHost = menuHost,
    signpostHost = signpostHost,
    player = player,
    mapSource = opts.sourceMap,
  }, FieldScripts)

  -- The live task registry: the scheduler routes through it.
  local liveTaskRegistry = compatibility.taskRegistry

  local scheduler
  local function advanceAsync()
    opts.auxiliaryUi:advance()
    dialogueHost:advance(scheduler:currentInput())
    -- The signpost controller is pure and fixed-tick: exactly one step per
    -- scheduler tick, commands and printer together.
    signpostHost:advance(scheduler:currentInput())
  end
  local function resolveComposition(id)
    return composition:effective(id)
  end
  scheduler = Scheduler.new({
    services = {
      world = worldState,
      actors = actors,
      player = player,
      dialogue = dialogueHost,
      maps = mapsService,
      -- Optional backends: an absent service faults the operation that
      -- needs it (SCRIPT_SERVICE_MISSING) instead of silently succeeding.
      -- The production game wires real audio/camera/screen/events here when
      -- those subsystems land; tests inject deterministic fakes.
      audio = opts.audio,
      weather = opts.weather,
      camera = opts.camera,
      screen = opts.screen,
      events = opts.events,
      auxiliaryUi = opts.auxiliaryUi,
      contextChoice = opts.contextChoice,
      menu = opts.menu,
      scriptMenu = menuHost,
      signpost = signpostHost,
      windowStyles = opts.windowStyles,
      startMenuReopen = opts.startMenuReopen,
      effects = opts.effects,
      mons = opts.mons,
      starterProvider = opts.starterProvider,
      starterChoice = opts.starterChoice,
      followingMon = opts.followingMon,
      followerTransition = opts.followerTransition,
      starterBalls = opts.starterBalls,
      advanceAsync = advanceAsync,
    },
    taskRegistry = liveTaskRegistry,
    semantics = HgssScript.semantics(),
    resolveComposition = resolveComposition,
  })
  platform.scheduler = scheduler
  platform.taskRegistry = liveTaskRegistry
  local function compose(id)
    return composition:effective(id)
  end
  platform.client = ScriptInteractionClient.new({
    bindings = bindings,
    compose = compose,
    scheduler = scheduler,
    scriptBankId = opts.sourceMap.fieldData.scriptBankId,
  })
  platform.initController = MapInitScriptController.new({
    rules = opts.sourceMap.fieldData.initScripts,
    mapId = opts.sourceMap.fieldData.mapId,
    world = worldState,
    scriptClient = platform.client,
  })
  return platform
end

-- The registry fingerprint used for save validation. On a snapshot miss the
-- warm-up is finished synchronously here (the fingerprint is the save's
-- cross-boot contract and cannot be partial); a warm-up failure is a corrupt
-- cache and fails the save loudly. The digest is then persisted into the
-- keyed snapshot while the world still matches the key it was computed
-- under: a mid-session override edit skips the write, so the next boot
-- warms up again instead of trusting a stale digest.
---@return string
function FieldScripts:registryFingerprint()
  return self.compatibility:registryFingerprint()
end

-- Rebind every map-scoped script collaborator (maps service, script-client
-- bank id, init-controller rules/map id, and mapSource) to sourceMap. Shared
-- by the discontinuous and seamless active-map entry points below so both
-- always establish the same complete destination map context.
---@param self FieldScripts
---@param sourceMap RuntimeFieldMap
local function rebindMapContext(self, sourceMap)
  self.mapsService:setSourceMap(sourceMap)
  self.client:setScriptBankId(sourceMap.fieldData.scriptBankId)
  self.initController:setRules(sourceMap.fieldData.initScripts, sourceMap.fieldData.mapId)
  self.mapSource = sourceMap
end

-- Rebind the facade and warp source after a map swap (the player and the
-- current map are replaced by the transition).
---@param player FieldPlayer
---@param sourceMap RuntimeFieldMap
function FieldScripts:onMapSwap(player, sourceMap)
  self.player:setPlayer(player)
  rebindMapContext(self, sourceMap)
end

---@param sourceMap RuntimeFieldMap
function FieldScripts:onZoneChange(sourceMap)
  rebindMapContext(self, sourceMap)
end

return FieldScripts
