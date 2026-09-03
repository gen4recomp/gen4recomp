-- Normal field-runtime coordinator. It joins generated maps through
-- FieldMapLoader, drives the deterministic elevation-aware player, and
-- exposes the field warp transition lifecycle.

local CacheFs = require("libs.storage.src.CacheFs")
local DialogueLayout = require("libs.hgss.src.ui.DialogueLayout")
local FieldActorDefinitionProvider = require("libs.hgss.src.actors.FieldActorDefinitionProvider")
local AuxiliaryFieldUi = require("libs.hgss.src.ui.AuxiliaryFieldUi")
local ContextChoiceProvider = require("libs.hgss.src.interaction.ContextChoiceProvider")
local FieldActorManager = require("libs.hgss.src.actors.FieldActorManager")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
local FieldApplicationRegistry = require("libs.hgss.src.field.FieldApplicationRegistry")
local FieldCamera = require("libs.hgss.src.field.FieldCamera")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local FieldDialogueController = require("libs.hgss.src.ui.FieldDialogueController")
local FieldFontLoader = require("libs.hgss.src.ui.FieldFontLoader")
local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local PlayerData = require("libs.hgss.src.save.PlayerData")
local FieldCameraCache = require("libs.assets.src.field.FieldCameraCache")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldInput = require("libs.hgss.src.field.FieldInput")
local FieldMenuHost = require("libs.hgss.src.ui.FieldMenuHost")
local FieldInteractionResolver = require("libs.hgss.src.interaction.FieldInteractionResolver")
local FieldEventResolver = require("libs.hgss.src.interaction.FieldEventResolver")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local FieldMapLoader = require("libs.hgss.src.world.FieldMapLoader")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local FieldPlayerAvatarState = require("libs.hgss.src.actors.FieldPlayerAvatarState")
local FieldPlayerVisual = require("libs.hgss.src.actors.FieldPlayerVisual")
local FieldZoneIdentity = require("libs.hgss.src.world.FieldZoneIdentity")
local GameSave = require("libs.hgss.src.save.GameSave")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local FieldScriptScreenFade = require("libs.hgss.src.transition.FieldScriptScreenFade")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local MonCache = require("libs.assets.src.MonCache")
local MonCatalog = require("libs.mons.src.MonCatalog")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldSession = require("libs.hgss.src.field.FieldSession")
local FieldSignpostController = require("libs.hgss.src.interaction.FieldSignpostController")
local TextSpeedPolicy = require("libs.hgss.src.ui.TextSpeedPolicy")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldWindowStyles = require("libs.hgss.src.field.FieldWindowStyles")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapSceneLoader = require("libs.hgss.src.presentation.MapSceneLoader")
local NeighborRing = require("libs.hgss.src.presentation.NeighborRing")
local MapProps = require("libs.hgss.src.world.MapProps")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")
local FieldWeatherCache = require("libs.assets.src.field.FieldWeatherCache")
local FieldWeatherResolver = require("libs.hgss.src.world.FieldWeatherResolver")
local StartMenuController = require("libs.hgss.src.ui.StartMenuController")
local StartMenuLayout = require("libs.hgss.src.field.StartMenuLayout")
local StartMenuPolicy = require("libs.hgss.src.ui.StartMenuPolicy")
local TrainerCardController = require("libs.hgss.src.ui.TrainerCardController")
local FieldAudio = require("game.hgss.src.audio.FieldAudio")
local FieldEntranceIndicatorRuntime = require("game.hgss.src.field.FieldEntranceIndicatorRuntime")
local FieldActorEmoteRuntime = require("game.hgss.src.field.FieldActorEmoteRuntime")
local TimeOfDayProps = require("libs.hgss.src.presentation.TimeOfDayProps")
local FieldPresentation = require("data.manifests.field_presentation")
local FieldZoom = require("libs.hgss.src.presentation.FieldZoom")
local FieldWorldSwapCoordinator = require("game.hgss.src.field.FieldWorldSwapCoordinator")
local FieldSaveCoordinator = require("game.hgss.src.field.FieldSaveCoordinator")
local GameSaveValidation = require("game.hgss.src.save.GameSaveValidation")
local LocalClock = require("game.src.LocalClock")
local RepoFs = require("game.src.RepoFs")
local WindowConfig = require("game.src.WindowConfig")

---@class FieldRuntimeOptions
---@field zoomConfig table<string, unknown>?
---@field viewportWidth integer?
---@field viewportHeight integer?
---@field screenTopology ScreenTopology?
---@field overrideFs table<string, unknown>? read-shaped repository filesystem override
---@field presentation boolean?
---@field scriptHosts table<string, unknown>? deterministic host boundaries for script effects
---@field dayNight (fun(): string)? deterministic day/night source for the field-music policy
---@field audioOutput table<string, unknown>? { audio: table<string, unknown>, sound: table<string, unknown> } audio-output host namespaces for the LÖVE sink (defaults to love.audio + love.sound)
---@field localClock LocalClock? injectable host-local civil-time boundary
---@field weatherClock table<string, unknown>? injectable host boundary { today()->{month,day}, hasPenalty()->boolean }
---@field saveStore FieldRuntimeSaveStore? global publication owner
---@field saveValidation GameSaveValidation? shared semantic GameSave validator

---@class FieldRuntimeScriptHosts
---@field audio table<string, unknown>?
---@field camera table<string, unknown>?
---@field screen table<string, unknown>?
---@field events table<string, unknown>?

---@class FieldRuntimeSaveStore
---@field save fun(self: FieldRuntimeSaveStore, record: table<string, unknown>)
---@field publishFirst fun(self: FieldRuntimeSaveStore, record: table<string, unknown>)

---@class FieldRuntime
---@field versionId string
---@field overrideFs table<string, unknown> read-shaped repository filesystem
---@field saveId string
---@field game table<string, unknown> finalized unpublished game or validated loaded GameSave
---@field viewportWidth integer
---@field viewportHeight integer
---@field screenTopology ScreenTopology?
---@field errorText string?
---@field zoom FieldZoom
---@field saveStatus string?
---@field saveStore FieldRuntimeSaveStore? global publication owner
---@field saveValidation GameSaveValidation? shared semantic GameSave validator
---@field savePublished boolean whether the reserved record has been published
---@field saveCoordinator FieldSaveCoordinator required save capture/publication owner
---@field worldSwapCoordinator FieldWorldSwapCoordinator required staged transition/world owner
---@field playerData table<string, unknown> the validated profile/options authority (PlayerData shape)
---@field avatar table<string, unknown> the gender-selected compiled avatar capability
---@field playerAvatar FieldPlayerAvatarState? the one avatar transition owner
---@field monCatalog MonCatalog the immutable domain mon catalog behind the live party
---@field monLanguage string the semantic language key the mon catalog was built for
---@field monService HgssMonService the live party/creation/script mon service
---@field session FieldSession
---@field actors FieldActorManager
---@field actorAssets FieldActorAssets
---@field dialogue FieldDialogueController?
---@field signpost FieldSignpostController the fixed-tick signpost controller (script-owned via ScriptSignpostHost)
---@field auxiliaryFieldUi AuxiliaryFieldUi?
---@field contextChoiceProvider ContextChoiceProvider?
---@field menuHost FieldMenuHost?
---@field actionKeys table<string, boolean>?
---@field cancelKeys table<string, boolean>?
---@field menuKeys table<string, boolean>?
---@field presentation boolean
---@field windowStyles FieldWindowStyles the immutable per-runtime window style catalogue
---@field scriptHosts FieldRuntimeScriptHosts?
---@field transitionPanel "exit"|"enter"|nil
---@field applications FieldApplicationRegistry the immutable per-runtime destination application catalogue
---@field applicationHost FieldApplicationHost the one application modal owner the session steps
---@field startMenuPlacement StartMenuLayout.Placement? the one Start Menu placement record rendering and pointer mapping share
---@field dayNight fun(): string?
---@field audioOutput table<string, unknown>?
---@field audio FieldAudioController? production-composed audio service (absent when only a recording script adapter is injected, without an audio-output host)
---@field mapMusicDayNight (fun(): string)? production-composed day/night band source for the map-music lookup (present whenever the production composition exists)
---@field audioSink LoveAudioSink? production-composed LÖVE output sink (absent without an audio-output host)
---@field screenFade FieldScriptScreenFade the production semantic script screen-fade controller (fade_screen/wait_fade); always composed, advanced once after each field tick
---@field localClock LocalClock the shared host-local civil-time boundary
---@field weatherClock table<string, unknown> injectable host boundary { today()->{month,day}, hasPenalty()->boolean }
---@field fieldEntranceIndicator FieldEntranceIndicator
---@field fieldEntranceIndicatorAsset table<string, unknown>
---@field fieldEffectAssets table<string, unknown>
---@field physicalCoverage FieldCoverage?
---@field residency FieldResidencyCoordinator?
local FieldRuntime = {}
FieldRuntime.__index = FieldRuntime

---@class FieldRuntimePhysicalSwap
---@field coverage FieldCoverage
---@field replacement boolean
---@field previous FieldCoverage?
---@field state "prepared"|"committed"|"released"

-- The audio-output sample rate of the production composition (the mixer and
-- the LÖVE sink render at this rate, the DS SPU rate; source waves are
-- ratio-scaled, so the pitch is preserved at any output rate).
local AUDIO_SAMPLE_RATE = 32768
local CAMERA_PROFILES_PATH = FieldCameraCache.profilesPath()
---@return table<string, boolean>
local function actionBindings()
  local keys = {}
  for _, key in ipairs(FieldPresentation.input and FieldPresentation.input.action or {}) do
    keys[key] = true
  end
  return keys
end

---@return table<string, boolean>
local function cancelBindings()
  local keys = {}
  for _, key in ipairs(FieldPresentation.input and FieldPresentation.input.cancel or {}) do
    keys[key] = true
  end
  return keys
end

---@return table<string, boolean>
local function menuBindings()
  local keys = {}
  for _, key in ipairs(FieldPresentation.input and FieldPresentation.input.menu or {}) do
    keys[key] = true
  end
  return keys
end

---@param avatars table[]
local function validateAvatarConfig(avatars)
  assert(type(avatars) == "table" and #avatars > 0, "field actor index must contain avatars")
  local genders = {}
  for _, avatar in ipairs(avatars) do
    assert(type(avatar) == "table", "field actor avatar metadata must be a table")
    assert(type(avatar.id) == "string" and avatar.id ~= "", "field actor avatar id must be a non-empty string")
    assert(type(avatar.states) == "table", "field actor avatar states must be a visual-state map")
    assert(
      type(avatar.states.walking) == "number" and avatar.states.walking >= 0 and avatar.states.walking % 1 == 0,
      "field actor avatar walking state must be a compiled spriteId"
    )
    for state, spriteId in pairs(avatar.states) do
      assert(
        type(state) == "string" and type(spriteId) == "number" and spriteId >= 0 and spriteId % 1 == 0,
        "field actor avatar states must map visual states to compiled spriteIds"
      )
    end
    assert(PlayerData.GENDERS[avatar.gender] == true, "field actor avatar gender is unsupported")
    assert(genders[avatar.gender] == nil, "field actor index contains duplicate playable avatar genders")
    genders[avatar.gender] = true
  end
  for gender in pairs(PlayerData.GENDERS) do
    assert(genders[gender] == true, "field actor index has no avatar for player gender " .. gender)
  end
end

---@param avatars table[]
---@param gender integer
---@return table<string, unknown>
local function avatarForGender(avatars, gender)
  assert(PlayerData.GENDERS[gender] == true, "field player gender is unsupported")
  local match
  for _, avatar in ipairs(avatars) do
    if avatar.gender == gender then
      assert(match == nil, "compiled avatars contain duplicate playable gender")
      match = avatar
    end
  end
  return assert(match, "compiled avatars have no entry for player gender " .. gender)
end

-- The one actor lookup shared by movement collision and interaction
-- discovery: live occupancy for the active actor map, and a read-only source
-- event probe for any other logical map, resident or preflight. The probe
-- never publishes an actor map or acquires an actor visual.
---@param mapId integer
---@param candidate FieldOccupancyCandidate
---@return FieldActorManager.Actor|FieldActorManager.ProbeResult|nil
function FieldRuntime:_actorAt(mapId, candidate)
  if self.actors.currentMapId == mapId then
    return self.actors:getAt(mapId, candidate)
  end
  local residency = assert(self.residency, "inactive actor lookup requires logical residency")
  local runtimeMap = residency:mapForId(mapId) or residency:mapForPreflight(mapId)
  return self.actors:probeAt(runtimeMap, self.eventState, candidate)
end

---@param candidate FieldOccupancyCandidate
---@return string?
function FieldRuntime:_playerOccupantAt(candidate)
  local currentMap = self.runtimeMap
  local coverage = currentMap.coverage
  local targetMapId = currentMap.mapId
  if coverage then
    targetMapId = FieldZoneIdentity.logicalZoneAt(coverage, candidate.fieldX, candidate.fieldZ, currentMap.mapId)
      or currentMap.mapId
  end
  local occupant
  if self.actors.currentMapId == targetMapId then
    occupant = self.actors:getCollisionAt(targetMapId, candidate)
  else
    occupant = self:_actorAt(targetMapId, candidate)
  end
  return occupant and occupant.actorId or nil
end

local function playerOccupancy(self)
  local function occupancy(candidate)
    return self:_playerOccupantAt(candidate)
  end
  return occupancy
end

-- The spawn surface at a declared spawn tile: the topmost walkable terrain
-- surface at the point, exactly the no-hint arrival rule of scripted warp
-- resolution (WarpSystem.directSurface). The historic nearest-world-Y-zero
-- choice served only the deleted (0,0) synthesis and selected the wrong floor
-- on vertically stacked maps.
local function spawnSurface(runtimeMap, localX, localZ)
  local x = localX + FieldCoordinates.TILE_CENTER_OFFSET
  local z = localZ + FieldCoordinates.TILE_CENTER_OFFSET
  local best
  for _, plate in ipairs(runtimeMap.terrain:candidatesAt(x, z)) do
    local sample = runtimeMap.terrain:sample(plate.id, x, z)
    if best == nil or sample.worldY > best.worldY then
      best = sample
    end
  end
  assert(best, string.format("spawn tile (%d,%d) has no walkable terrain surface", localX, localZ))
  return best
end

-- Compose the current logical context with the session-owned physical world.
-- Cached loader entries remain logical-only; this view is disposable and never
-- releases either collaborator.
local function composePhysicalMap(logicalMap, coverage)
  if not coverage then
    return logicalMap
  end
  local runtimeMap = {}
  for key, value in pairs(logicalMap) do
    runtimeMap[key] = value
  end
  runtimeMap.logicalMap = logicalMap
  runtimeMap.coverage = coverage
  function runtimeMap.release() end
  function runtimeMap.probePhysicalCell(_, fieldX, fieldZ, context)
    return coverage:probe(fieldX, fieldZ, context)
  end
  function runtimeMap.projectPhysicalPoint(_, fieldX, fieldZ, cellKey, sourceSurfaceId)
    return coverage:project(fieldX, fieldZ, cellKey, sourceSurfaceId)
  end
  function runtimeMap.updateAnimated()
    coverage:updateAnimated()
  end
  function runtimeMap.syncPhysicalFields()
    runtimeMap.fieldRegion = coverage.region
    runtimeMap.collision = coverage.region.collision
    runtimeMap.terrain = coverage.region.terrain
    runtimeMap.terrainDependencyHash = coverage.terrainDependencyHash
    runtimeMap.coordinateOrigin = { x = coverage.origin.x, z = coverage.origin.z }
    runtimeMap.physicalOrigin = coverage.origin
  end
  runtimeMap:syncPhysicalFields()
  return runtimeMap
end

---@param localClock LocalClock
---@return table<string, unknown>
local function defaultWeatherClock(localClock)
  local function today()
    local now = localClock:nowLocal()
    return { month = now.month, day = now.day }
  end
  local function hasPenalty()
    return false
  end
  return {
    today = today,
    hasPenalty = hasPenalty,
  }
end

local function closestSurface(runtimeMap, localX, localZ, savedY)
  local best
  local bestDistance
  for _, plate in
    ipairs(
      runtimeMap.terrain:candidatesAt(
        localX + FieldCoordinates.TILE_CENTER_OFFSET,
        localZ + FieldCoordinates.TILE_CENTER_OFFSET
      )
    )
  do
    local sample = runtimeMap.terrain:sample(
      plate.id,
      localX + FieldCoordinates.TILE_CENTER_OFFSET,
      localZ + FieldCoordinates.TILE_CENTER_OFFSET
    )
    local distance = math.abs(sample.worldY - savedY)
    if best == nil or distance < bestDistance then
      best, bestDistance = sample, distance
    end
  end
  return assert(best, "saved coordinate has no walkable terrain surface")
end

-- An outdoor destination map loads with no collision/terrain at all until
-- physical coverage composes over it (FieldMapLoader splits outdoor scenes
-- this way so a bare load never pays for a physical window the caller might
-- discard). `composeMap` is a no-op for non-outdoor scenes, so this runs
-- unconditionally; every FieldCoordinates/terrain lookup below runs only
-- after the composed map is in hand.
---@param game table<string, unknown>
---@param mapLoader FieldMapLoader
---@param composeMap fun(logicalMap: RuntimeFieldMap, position: { fieldX: integer, fieldZ: integer }): RuntimeFieldMap
---@return RuntimeFieldMap, { fieldX: integer, fieldZ: integer, surfaceId: integer, facing: FieldDirection, worldY: number }
local function loadGameLocation(game, mapLoader, composeMap)
  if game.schema == GameSave.SCHEMA then
    local runtimeMap = mapLoader:load(game.mapId)
    runtimeMap = composeMap(runtimeMap, { fieldX = game.fieldX, fieldZ = game.fieldZ })
    local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, game.fieldX, game.fieldZ)
    local surface
    if
      game.terrainDependencyHash == runtimeMap.terrainDependencyHash
      and runtimeMap.terrain:contains(
        game.surfaceId,
        localX + FieldCoordinates.TILE_CENTER_OFFSET,
        localZ + FieldCoordinates.TILE_CENTER_OFFSET
      )
    then
      surface = runtimeMap.terrain:sample(
        game.surfaceId,
        localX + FieldCoordinates.TILE_CENTER_OFFSET,
        localZ + FieldCoordinates.TILE_CENTER_OFFSET
      )
    else
      surface = closestSurface(runtimeMap, localX, localZ, game.worldY)
    end
    return runtimeMap,
      {
        fieldX = game.fieldX,
        fieldZ = game.fieldZ,
        surfaceId = surface.surfaceId,
        facing = game.facing,
        worldY = surface.worldY,
      }
  end

  assert(type(game.location) == "table", "finalized game location is required")
  local runtimeMap = mapLoader:load(game.location.mapSymbol)
  -- The global position is plain origin arithmetic (no collision lookup),
  -- so it is always safe to compute before composing physical coverage.
  local fieldX = runtimeMap.coordinateOrigin.x + game.location.fieldX
  local fieldZ = runtimeMap.coordinateOrigin.z + game.location.fieldZ
  runtimeMap = composeMap(runtimeMap, { fieldX = fieldX, fieldZ = fieldZ })
  -- Composing may have replaced coordinateOrigin with the physical window's
  -- own origin; re-derive local coordinates against it rather than reusing
  -- game.location's pre-compose local coordinates.
  local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, fieldX, fieldZ)
  local surface = spawnSurface(runtimeMap, localX, localZ)
  return runtimeMap,
    {
      fieldX = fieldX,
      fieldZ = fieldZ,
      surfaceId = surface.surfaceId,
      facing = game.location.facing,
      worldY = surface.worldY,
    }
end

-- Build the non-GPU door facade used by simulation and acceptance runtimes.
-- It reads the generated scene/model contracts only to recover the source
-- door's semantic sound selector; no presentation instance is acquired.
local function headlessMapProps(runtimeMap, cacheFs)
  local scene = runtimeMap.scene
  local placements = {}
  for _, placement in ipairs(scene.buildingInstances) do
    local descriptor = assert(cacheFs:loadLua(MapAssetCache.modelPath(placement.modelKey)))
    placements[#placements + 1] = {
      placementIndex = placement.placementIndex,
      modelKey = placement.modelKey,
      transform = placement.transform,
      doorSoundType = descriptor.doorSoundType,
    }
  end
  local doorTiles = {}
  local origin = runtimeMap.coordinateOrigin
  for _, warp in ipairs(runtimeMap.fieldData.events.warps) do
    local localX, localZ = warp.x - origin.x, warp.z - origin.z
    if
      runtimeMap.collision:containsLocal(localX, localZ)
      and MetatileBehavior.isDoor(runtimeMap.collision:getLocal(localX, localZ).behavior)
    then
      doorTiles[#doorTiles + 1] = { x = localX, z = localZ }
    end
  end
  return MapProps.new({
    placements = placements,
    instances = {},
    doorTiles = doorTiles,
  })
end

function FieldRuntime.new(game, options)
  assert(type(game) == "table", "field runtime requires a finalized or loaded game")
  assert(type(game.versionId) == "string" and game.versionId ~= "", "field runtime game version is required")
  options = options or {}
  local effectiveOverrideFs = options.overrideFs or RepoFs.new(love.filesystem.getSourceBaseDirectory())
  local self = setmetatable({
    game = game,
    versionId = game.versionId,
    saveId = game.saveId,
    viewportWidth = options.viewportWidth or WindowConfig.REFERENCE_WIDTH,
    viewportHeight = options.viewportHeight or WindowConfig.REFERENCE_HEIGHT,
    screenTopology = options.screenTopology,
    overrideFs = effectiveOverrideFs,
    presentation = options.presentation == true,
    scriptHosts = options.scriptHosts,
    dayNight = options.dayNight,
    audioOutput = options.audioOutput,
    saveStore = options.saveStore,
    saveValidation = options.saveValidation or GameSaveValidation.new({ overrideFs = effectiveOverrideFs }),
    savePublished = false,
    localClock = options.localClock or LocalClock.system(),
    weatherClock = options.weatherClock,
    errorText = nil,
    zoom = FieldZoom.new(options.zoomConfig or FieldPresentation.zoom),
  }, FieldRuntime)
  self.saveCoordinator = FieldSaveCoordinator.new(self)
  self.worldSwapCoordinator = FieldWorldSwapCoordinator.new(self)
  self.weatherClock = self.weatherClock or defaultWeatherClock(self.localClock)
  self:_load()
  return self
end

function FieldRuntime:_load()
  local ok, err = pcall(function()
    local cacheFs = CacheFs.forVersion(self.versionId)
    self.cacheFs = cacheFs
    -- The compiled actor index carries the runtime-facing actor configuration
    -- (avatars + variable-sprite policy); a missing runtime block is a stale
    -- or foreign cache and fails the boot loudly.
    local actorIndex = assert(
      cacheFs:loadLua(FieldActorCache.indexPath()),
      "field actor index missing -- run `scripts/buildcache.sh` first"
    )
    assert(
      actorIndex.runtime and actorIndex.runtime.avatars and actorIndex.runtime.variableSprites,
      "field actor index has no runtime configuration"
    )
    self.actorConfig = actorIndex.runtime
    validateAvatarConfig(self.actorConfig.avatars)
    -- The player-data validation context: the generated field font charmap
    -- and the imported dialogue frame-index set, loaded once and injected
    -- into fresh-session construction and the save store (the same pattern
    -- as the compiled avatar set). The field-UI class is a required runtime
    -- asset: its manifest is the authority for which frame indexes resolve.
    local fontDef = FieldFontLoader.load(cacheFs)
    local uiManifest = assert(
      cacheFs:loadLua(FieldUiAssetCache.manifestPath()),
      "field UI cache is cold -- run `scripts/buildcache.sh` first"
    )
    assert(FieldUiAssetCache.validateManifest(uiManifest), "field UI manifest is invalid")
    -- The window-style catalogue is composed per runtime from the generated
    -- manifest: the production-owned built-in styles, immutable from then on.
    self.windowStyles = FieldWindowStyles.new(uiManifest)
    self.uiManifest = uiManifest
    local frameIndexes = {}
    for frame = 0, uiManifest.dialogueFrames.count - 1 do
      frameIndexes[frame] = true
    end
    local playerDataContext = {
      charmap = fontDef.charmap,
      frameIndexes = frameIndexes,
    }
    local saveValidation = assert(self.saveValidation)
    local world =
      assert(cacheFs:loadLua(MapAssetCache.worldPath()), "world.lua missing -- run `scripts/buildcache.sh` first")
    local profiles =
      assert(cacheFs:loadLua(CAMERA_PROFILES_PATH), "field camera cache is cold -- run `scripts/buildcache.sh` first")
    assert(profiles.schema == FieldCameraCache.SCHEMA, "unsupported field camera cache")
    self.cameraProfiles = profiles.profiles

    -- The weather catalog: fourteen fog presets and ordered override rules.
    local weatherCatalog = assert(
      cacheFs:loadLua(FieldWeatherCache.catalogPath()),
      "field weather cache is cold -- run `scripts/buildcache.sh` first"
    ) --[[@as FieldWeatherCache.Catalog]]
    assert(FieldWeatherCache.validateCatalog(weatherCatalog), "field weather catalog is invalid")
    self.weatherCatalog = weatherCatalog
    -- The mon catalog behind the live party: loaded once per runtime
    -- through the ready cache path, before save validation and service
    -- construction. Screens and scripts borrow the service, never the
    -- catalog directly.
    local monRoot = MonCache.loadCatalog(cacheFs)
    self.monCatalog = MonCatalog.new(monRoot)
    self.monLanguage = monRoot.version.language
    self.fieldEntranceIndicatorAsset, self.fieldEntranceIndicator = FieldEntranceIndicatorRuntime.load(cacheFs)
    self.fieldEmoteModels = FieldActorEmoteRuntime.load(cacheFs)
    self.fieldEffectAssets = self.fieldEntranceIndicatorAsset
    self.fieldTerrainEffectController = require("libs.hgss.src.world.FieldTerrainEffectController").new({
      effects = {
        tall_grass = self.fieldEntranceIndicatorAsset.effects.tall_grass,
        very_tall_grass = self.fieldEntranceIndicatorAsset.effects.very_tall_grass,
        trainer_reveal = self.fieldEntranceIndicatorAsset.effects.trainer_reveal,
      },
      modelFactory = require("libs.hgss.src.presentation.FieldTerrainEffectModelFactory").new(),
    })

    self.mapLoader = FieldMapLoader.new(cacheFs, world, {
      sceneLoader = self.presentation and MapSceneLoader or nil,
      neighborLoader = self.presentation and NeighborRing or nil,
    })
    local function mapMatrixMemberId(logicalMap)
      local mapIndex = assert(self.mapLoader.world.byId[logicalMap.mapId], "outdoor map catalog record is required")
      local mapRecord = assert(self.mapLoader.world.maps[mapIndex], "outdoor map catalog record is missing")
      return assert(mapRecord.matrix.memberId, "outdoor map matrix member is required")
    end

    -- Initial boot has no live source owner to protect. It is the only path
    -- allowed to publish a newly created initial coverage.
    local function composeInitialMap(logicalMap, position)
      if logicalMap.scene.type ~= "outdoor" then
        return logicalMap
      end
      assert(not self.physicalCoverage, "initial physical coverage already exists")
      self.physicalCoverage = self.mapLoader:createPhysicalCoverage(logicalMap, position)
      return composePhysicalMap(logicalMap, self.physicalCoverage)
    end

    -- Logical zone changes reuse the committed owner. A matrix mismatch here
    -- indicates that a logical seam was routed through the wrong boundary.
    local function composeCurrentMap(logicalMap, coverage)
      if logicalMap.scene.type ~= "outdoor" then
        return logicalMap
      end
      coverage = coverage or assert(self.physicalCoverage, "current outdoor coverage is required")
      assert(
        mapMatrixMemberId(logicalMap) == coverage.matrixMemberId,
        "logical outdoor map does not belong to the current physical matrix"
      )
      return composePhysicalMap(logicalMap, coverage)
    end

    -- A live warp receives an explicit ownership record. The replacement is
    -- transition-owned until commit and never mutates physicalCoverage here.
    local function composePreparedMap(logicalMap, position)
      if logicalMap.scene.type ~= "outdoor" then
        return logicalMap, nil
      end
      local matrixMemberId = mapMatrixMemberId(logicalMap)
      local physical = self:_stagePhysicalCoverage(logicalMap, position, matrixMemberId)
      local ok, runtimeMap = pcall(composePhysicalMap, logicalMap, physical.coverage)
      if not ok then
        if physical.replacement then
          physical.coverage:release()
          physical.state = "released"
        end
        error(runtimeMap, 0)
      end
      return runtimeMap, physical
    end

    local loadedGame
    if self.game.schema == GameSave.SCHEMA then
      loadedGame = assert(saveValidation:validate(self.game))
      assert(loadedGame.versionId == self.versionId, "loaded game belongs to another version")
    else
      assert(self.game.playerData, "finalized game player data is required")
      local validPlayerData, playerDataErr = saveValidation:validatePlayerData(self.game.playerData, playerDataContext)
      assert(validPlayerData, "finalized game player data is invalid: " .. tostring(playerDataErr))
      self.game.playerData = validPlayerData
    end
    local activeGame = loadedGame or self.game
    self.savePublished = loadedGame ~= nil
    self.runtimeMap, self.entryLocation = loadGameLocation(activeGame, self.mapLoader, composeInitialMap)
    self.mapLoader:protectMap(self.runtimeMap.mapId, true)

    self.playerData = activeGame.playerData
    local fieldX, fieldZ = self.entryLocation.fieldX, self.entryLocation.fieldZ
    local surfaceId, facing = self.entryLocation.surfaceId, self.entryLocation.facing
    self.player = FieldPlayer.new({
      currentMap = self.runtimeMap,
      fieldX = fieldX,
      fieldZ = fieldZ,
      surfaceId = surfaceId,
      facing = facing,
      occupancy = playerOccupancy(self),
    })
    self.input = FieldInput.new()
    local worldPoint = self.player:renderPosition()

    local profile = assert(
      self.cameraProfiles[self.runtimeMap.cameraType],
      "field camera cache has no camera type " .. self.runtimeMap.cameraType
    )
    self.camera = FieldCamera.new(profile, { initialTarget = worldPoint })
    local width, height = self.viewportWidth, self.viewportHeight
    self.viewport = FieldViewport.new(width, height, { mode = "expanded" })
    self:_updateCameraProjection()
    local restoredWorld = loadedGame and loadedGame.world
    local restoredAudio = loadedGame and loadedGame.audio
    self.restoredAudio = restoredAudio
    self.eventState = loadedGame
        and FieldEventState.new({ flags = restoredWorld.flags, vars = restoredWorld.variables })
      or self.game.worldState
    assert(self.eventState and self.eventState.serialize, "finalized game event state is required")
    local initialActorRestore = loadedGame and restoredWorld.objects or nil
    local initialActorRestoreMapId = loadedGame and loadedGame.mapId or nil
    self.actorAssets = FieldActorDefinitionProvider.new(cacheFs)
    self.actors = FieldActorManager.new({
      assets = self.actorAssets,
      policy = { variableSprites = self.actorConfig.variableSprites },
    })

    -- The player's graphic is one more compiled actor visual: FieldPlayer
    -- keeps every bit of movement authority while the avatar transition owner
    -- selects which compiled visual presents it. Dynamic residency stays with
    -- FieldState; the simulation side holds no fixed avatar asset.
    self.avatar = avatarForGender(self.actorConfig.avatars, self.playerData.profile.gender)
    local initialAvatarState = "walking"
    if loadedGame and loadedGame.avatar then
      initialAvatarState = loadedGame.avatar.state
    end
    self.playerAvatar = FieldPlayerAvatarState.new({
      capability = self.avatar,
      surfPresentation = self.fieldEffectAssets.effects.surf_attachment.presentation,
      initialState = initialAvatarState,
    })
    self.playerVisual = FieldPlayerVisual.new({
      player = self.player,
      spriteId = self.playerAvatar:currentSpriteId(),
      playerAvatar = self.playerAvatar,
    })

    -- Warp resolution is owned by WarpSystem through FieldTransition's
    -- default resolver: ordinary records follow the indexed path; scripted
    -- `direct` records carry global destination coordinates and resolve
    -- through their own branch. Fallible destination preparation runs before
    -- the commit, so a failed warp never touches current-map ownership.
    -- Door choreography is a presentation capability. A simulation-only
    -- runtime has no resolver and therefore runs door-kind warps through the
    -- ordinary fade lifecycle.
    local headlessProps = {}
    local doorAt
    local escalatorAt
    if self.presentation or self.runtimeMap.sceneRuntime or self.runtimeMap.scene then
      local function resolveDoorAt(runtimeMap, doorFieldX, doorFieldZ)
        local sceneRuntime = runtimeMap.sceneRuntime
        if sceneRuntime and sceneRuntime.mapProps then
          return sceneRuntime.mapProps:doorAt(runtimeMap, doorFieldX, doorFieldZ)
        end
        local props = headlessProps[runtimeMap.mapId]
        if not props then
          props = headlessMapProps(runtimeMap, cacheFs)
          headlessProps[runtimeMap.mapId] = props
        end
        return props:doorAt(runtimeMap, doorFieldX, doorFieldZ)
      end
      local function resolveEscalatorAt(runtimeMap, escalatorFieldX, escalatorFieldZ)
        local sceneRuntime = runtimeMap.sceneRuntime
        if sceneRuntime and sceneRuntime.mapProps then
          return sceneRuntime.mapProps:propAt(runtimeMap, escalatorFieldX, escalatorFieldZ)
        end
        local props = headlessProps[runtimeMap.mapId]
        if not props then
          props = headlessMapProps(runtimeMap, cacheFs)
          headlessProps[runtimeMap.mapId] = props
        end
        return props:propAt(runtimeMap, escalatorFieldX, escalatorFieldZ)
      end
      doorAt = resolveDoorAt
      escalatorAt = resolveEscalatorAt
    end
    self.transition = self.worldSwapCoordinator:createTransition(self, doorAt, escalatorAt, function(_, sourceMap, warp)
      local physical
      local ok, result = pcall(function()
        local function loadDestination(_, mapId)
          assert(mapId == warp.destinationMapId, "transition destination map mismatch")
          local logicalMap = self.mapLoader:load(mapId)
          local destinationPosition
          if warp.direct then
            destinationPosition = { fieldX = warp.x, fieldZ = warp.z }
          else
            local destinationWarp = logicalMap.fieldData.events.warps[warp.destinationWarpId + 1]
            assert(destinationWarp, "transition destination warp is missing")
            destinationPosition = { fieldX = destinationWarp.x, fieldZ = destinationWarp.z }
          end
          local composed, ownership = composePreparedMap(logicalMap, destinationPosition)
          physical = ownership
          return composed
        end
        return require("libs.hgss.src.transition.WarpSystem").resolveDestination({
          load = loadDestination,
        }, sourceMap, warp)
      end)
      if not ok then
        if physical and physical.replacement and physical.state == "prepared" then
          physical.coverage:release()
          physical.state = "released"
        end
        error(result, 0)
      end
      result.physical = physical
      return result
    end)
    self.transition.player = self.player
    self.transition.suppression = nil

    -- The production script screen-fade controller (fade_screen/wait_fade):
    -- composed unconditionally so every supported field script has it,
    -- regardless of presentation mode or scriptHosts injection. Rendering
    -- only reads its status().
    self.screenFade = FieldScriptScreenFade.new()

    -- Modal dialogue is pure and fixed-tick. Runtime layout needs only the
    -- compiled font definition; presentation later owns the atlas and drawing.
    -- The text-speed cadence is captured from the player options at
    -- construction, so an open request never queries options afterwards.
    local fontMetrics = FieldDialogueTheme.fontMetrics(fontDef)
    self.menuHost = FieldMenuHost.new({
      width = self.viewportWidth,
      height = self.viewportHeight,
      input = self.input,
      screenTopology = self.screenTopology,
      measureText = FieldDialogueTheme.measureText(fontDef),
    })
    local function layoutMessage(formatted)
      return DialogueLayout.layout(
        formatted.tokens,
        fontMetrics,
        { width = FieldDialogueTheme.textWidth, maxLines = FieldDialogueTheme.maxLines }
      )
    end
    -- The signpost window presents one 27x4-tile window: the single-window
    -- lines shape the signpost controller captures is the first page of the
    -- same paginated dialogue layout. Overflow beyond the window is the
    -- signpost text path's concern, not this adapter's.
    local function signpostLayout(formatted)
      local result = layoutMessage(formatted)
      return { lines = (result.pages[1] or { lines = {} }).lines }
    end
    local audioService = self:_composeAudio(cacheFs, restoredAudio)
    self.dialogue = FieldDialogueController.new({
      layout = layoutMessage,
      policy = TextSpeedPolicy.forSpeed(self.playerData.options.textSpeed),
      audio = audioService,
      continueCursor = uiManifest.dialogueFrames.continueCursor,
    })
    -- The signpost controller is fixed-tick and pure; the script platform
    -- advances it once per scheduler tick through the signpost host. The
    -- text-speed cadence is captured from the player options at construction,
    -- the same single authority as the dialogue controller.
    self.signpost = FieldSignpostController.new({
      layout = signpostLayout,
      policy = TextSpeedPolicy.forSpeed(self.playerData.options.textSpeed),
    })
    self.auxiliaryFieldUi = loadedGame and AuxiliaryFieldUi.restore(loadedGame.auxiliaryUi) or AuxiliaryFieldUi.new()
    self.contextChoiceProvider = ContextChoiceProvider.new()
    self.actionKeys = actionBindings()
    self.cancelKeys = cancelBindings()
    self.menuKeys = menuBindings()

    -- The field application catalogue: the registry holds child destinations
    -- only, and the runtime registers the production destinations itself --
    -- the Trainer Card is the concrete one. Its factory copies the immutable
    -- profile fields from the authoritative player-data record into the
    -- close-input-only controller, and must return a fully usable controller
    -- or raise. The catalogue is immutable after construction; canonical
    -- unimplemented destinations get capability state, never dummy
    -- factories. The Start Menu is not a registry entry: the application
    -- host composes it through its own menu factory.
    local function playSequence(sequence)
      if self.audio then
        self.audio:play(sequence)
      end
    end
    local function trainerCardFactory()
      return TrainerCardController.new({
        profile = self.playerData.profile,
        playTimeSeconds = self.playTime:seconds(),
        effect = playSequence,
      })
    end
    local applicationDescriptors = {
      {
        id = FieldApplicationIds.TRAINER_CARD,
        factory = trainerCardFactory,
      },
    }
    local function menuFactory(rememberedActionId)
      return self:_composeStartMenu(rememberedActionId)
    end
    local function fieldAction(actionId)
      if actionId == "vanilla.save" then
        return self:_saveCheckpoint()
      end
      error("unknown field action " .. tostring(actionId))
    end
    self.applications = FieldApplicationRegistry.new(applicationDescriptors)
    self.applicationHost = FieldApplicationHost.new({
      registry = self.applications,
      menuFactory = menuFactory,
      input = self.input,
      fieldAction = fieldAction,
      effect = playSequence,
    })
    -- The one Start Menu placement record: the runtime computes it from the
    -- boot topology (so pointer input works before any resize) and re-applies
    -- it on presentation-geometry changes; rendering and the host's pointer
    -- mapper consume this exact record.
    self.startMenuPlacement = nil
    if self.screenTopology ~= nil then
      self.startMenuPlacement = StartMenuLayout.resolve(self.screenTopology, self.viewport.referenceFrame)
      self.applicationHost:setMenuPlacement(self.startMenuPlacement)
    end

    -- Interaction discovery: the resolver is pure and consults the same
    -- live-or-probe actor lookup movement collision uses, so both agree about
    -- objects on a logical map that is not the active actor map; bound
    -- interactions run through the script client and the binding audit
    -- guarantees every interactable event is bound.
    self.messageProvider = FieldMessageProvider.new(cacheFs)
    local function actorAt(mapId, candidate)
      return self:_actorAt(mapId, candidate)
    end
    local function targetMapAt(x, z, currentMap)
      local coverage = currentMap.coverage
      if not coverage then
        return currentMap
      end
      local targetMapId = FieldZoneIdentity.logicalZoneAt(coverage, x, z, currentMap.mapId) or currentMap.mapId
      if targetMapId == currentMap.mapId then
        return currentMap
      end
      local targetMap = assert(self.residency):mapForId(targetMapId)
      return assert(targetMap, "reachable interaction target is not resident")
    end
    self.interactionResolver = FieldInteractionResolver.new({
      actorAt = actorAt,
      targetMapAt = targetMapAt,
    })

    -- The production audio composition lives in _composeAudio: extracted out
    -- of this closure (rather than inlined here) so its module-level
    -- collaborators are not upvalues of this already large boot closure,
    -- which sits close to LuaJIT's 60-upvalue-per-function limit.
    -- The field-script platform (the script override system): registry over
    -- the compiled cache + data/scripts/overrides, composition, mechanical
    -- bindings, scheduler, and interaction client. A resumed save reattaches
    -- its script bucket.
    -- The override files live in the repo tree outside the LÖVE source dir,
    -- so the loader reads them through the io-backed repo filesystem.
    -- The live mon service: constructed once per runtime from the
    -- canonical bucket (the validated continue record, or the unpublished
    -- new-game bucket) and the HGSS player/version policy. A failed
    -- restore propagates before any field state publishes. The met
    -- location resolves from the active map and the met date from the
    -- host clock at creation time.
    local monBucket = loadedGame and loadedGame.mons or assert(self.game.mons, "finalized game mons bucket is required")
    local function monMetMapSection()
      -- Interim section identity: the runtime map id stands in for the
      -- native map-section identity until a mapsec table ships with map
      -- data. The value is write-only metadata in this increment (no
      -- summary, legality, or script consumer reads it) and round-trips
      -- exactly through save and native encoding.
      local currentMap = self.session and self.session.currentMap or self.runtimeMap
      assert(currentMap and currentMap.mapId, "mon met location requires the active map")
      return currentMap.mapId
    end
    local function monMetDate()
      local now = self.localClock:nowLocal()
      return { year = now.year, month = now.month, day = now.day }
    end
    self.monService = HgssMonService.new({
      catalog = self.monCatalog,
      bucket = monBucket,
      profile = self.playerData.profile,
      game = self.versionId,
      language = self.monLanguage,
      charmap = fontDef.charmap,
      mapSection = monMetMapSection,
      date = monMetDate,
    })
    local scriptComposition = require("game.hgss.src.field.FieldScriptComposition").compose(self, {
      cacheFs = cacheFs,
      layoutMessage = layoutMessage,
      fontDef = fontDef,
      audioService = audioService,
      loadedGame = loadedGame,
      mons = self.monService,
    })
    self.scripts = scriptComposition.scripts
    scriptComposition.restore()

    local FieldZoneController = require("libs.hgss.src.world.FieldZoneController")
    local function mapForId(mapId)
      return assert(self.residency):mapForId(mapId)
    end
    local function rebindScripts(runtimeMap, player)
      self.runtimeMap = runtimeMap
      player.currentMap = runtimeMap
      self.scripts:onZoneChange(runtimeMap)
    end
    local function applyWeather(runtimeMap)
      self:_applyEffectiveWeather(runtimeMap)
      self.weatherRuntime = { mapId = runtimeMap.mapId }
    end
    local function enterAudio(runtimeMap)
      if self.audio and self.audio.enterZone then
        self.audio:enterZone(runtimeMap)
      end
    end
    local function onZoneChange(change)
      self.lastZoneChange = change
    end
    self.zoneController = FieldZoneController.new({
      currentMap = self.runtimeMap,
      mapForId = mapForId,
      rebindScripts = rebindScripts,
      applyWeather = applyWeather,
      enterAudio = enterAudio,
      onChange = onZoneChange,
    })

    local FieldResidencyCoordinator = require("libs.hgss.src.world.FieldResidencyCoordinator")
    local function coverageProvider()
      return self.physicalCoverage
    end
    local function resolveInteraction(_, snapshot)
      return self.interactionResolver:resolve(snapshot)
    end
    local function enterMapActors()
      local restore = initialActorRestore
      if restore ~= nil then
        assert(self.runtimeMap.mapId == initialActorRestoreMapId, "loaded actor snapshot map mismatch")
      end
      self.actors:enterMap(self.runtimeMap, self.eventState, restore)
      if restore ~= nil then
        initialActorRestore = nil
        initialActorRestoreMapId = nil
      end
    end
    local onPreparedMap
    if self.audio then
      local function prewarmMapMusic(runtimeMap)
        self.audio:prewarmMapMusic(runtimeMap)
      end
      onPreparedMap = prewarmMapMusic
    end
    self.residency = FieldResidencyCoordinator.new({
      coverage = self.physicalCoverage,
      mapLoader = self.mapLoader,
      actors = self.actors,
      zoneController = self.zoneController,
      composeMap = composeCurrentMap,
      onPreparedMap = onPreparedMap,
    })
    self.residency:initialize()

    self.session = FieldSession.new({
      versionId = self.versionId,
      currentMap = self.runtimeMap,
      player = self.player,
      camera = self.camera,
      transition = self.transition,
      actors = self.actors,
      playerVisual = self.playerVisual,
      dialogue = self.dialogue,
      input = self.input,
      scriptScheduler = self.scripts.scheduler,
      scriptClient = self.scripts.client,
      initController = self.scripts.initController,
      menuHost = self.menuHost,
      contextChoice = self.contextChoiceProvider,
      signpost = self.signpost,
      applicationHost = self.applicationHost,
      -- The session's fixed-tick audio collaborator is the production
      -- GameSound only; a recording script adapter is a script service, not
      -- a session collaborator.
      audio = self.audio,
      navigationBoundary = require("libs.hgss.src.world.FieldNavigationBoundary").new({
        zoneController = self.zoneController,
        residencyCoordinator = self.residency,
        coverageProvider = coverageProvider,
      }),
      interactions = {
        resolve = resolveInteraction,
      },
      eventResolver = FieldEventResolver,
      eventState = self.eventState,
      fieldEntranceIndicator = self.fieldEntranceIndicator,
      enterMapActors = enterMapActors,
      autoAcknowledgePresentation = not self.presentation,
      terrainEffects = self.fieldTerrainEffectController,
      playerAvatar = self.playerAvatar,
    })

    if loadedGame and loadedGame.weatherId ~= nil then
      self:_setLiveWeather(self.runtimeMap, loadedGame.weatherId)
    else
      self:_applyEffectiveWeather(self.runtimeMap)
    end
    self.session:beginMapEntry()
    self.playTime = loadedGame and PlayTime.new(loadedGame.playTimeSeconds) or self.game.playTime
    assert(self.playTime and self.playTime.start and self.playTime.advance, "game play time is required")
    self.playTime:start()

    self.weatherRuntime = { mapId = self.runtimeMap.mapId }
  end)
  -- Construction is binary: a failed boot releases everything acquired so
  -- far exactly once, then the original failure propagates to the caller.
  -- There is no half-constructed runtime; errorText never records boot
  -- failures (warp failures after a successful boot do).
  if not ok then
    self:_releaseAll()
    error(err, 0)
  end
end

function FieldRuntime:update(dt)
  if self.errorText then
    return
  end
  local maxSemanticDt = FieldSession.FIXED_DT * FieldSession.MAX_CATCH_UP_TICKS
  local acceptedDt = math.min(dt, maxSemanticDt)
  if self.playTime then
    self.playTime:advance(acceptedDt)
  end

  if self.residency then
    self.residency:updatePrefetch()
  end

  -- The background registry warm-up (snapshot-miss boot) runs one time
  -- slice per frame; the first save finishes whatever it has not.
  if self.scripts.warmup then
    self.scripts.warmup:update()
  end
  self.session.accumulator = self.session.accumulator + acceptedDt
  local FIXED_DT = FieldSession.FIXED_DT
  local MAX_CATCH_UP = FieldSession.MAX_CATCH_UP_TICKS
  local EPSILON = 1e-12
  local fieldExecuted = 0
  while self.session.accumulator + EPSILON >= FIXED_DT and fieldExecuted < MAX_CATCH_UP do
    self.session.accumulator = self.session.accumulator - FIXED_DT
    self.session:updateFixed()
    fieldExecuted = fieldExecuted + 1
    if self.applicationHost:error() and not self.errorText then
      self.errorText = tostring(self.applicationHost:error())
    end
    if self.errorText then
      break
    end
    self.transition:updateSourceFrame()
    self.screenFade:updateSourceFrame()
    if self.audio then
      self.audio:updateSoundFrame()
    end
  end
  if self.session.accumulator + EPSILON >= FIXED_DT then
    local discarded = math.floor((self.session.accumulator + EPSILON) / FIXED_DT)
    self.session.accumulator = self.session.accumulator - discarded * FIXED_DT
  end

  -- The audio output clock: pump PCM from the engine into the host sink once
  -- per runtime update, separate from the field fixed tick (the sink never
  -- advances game-semantic audio state).
  if self.audioSink then
    self.audioSink:update()
  end
  if self.transition.error and not self.errorText then
    local context = self.transition.warpContext
    if context then
      self.errorText = string.format(
        "%s\nsource map %s warp %s -> map %s warp %s",
        tostring(self.transition.error),
        tostring(context.sourceMapId),
        tostring(context.sourceWarpId),
        tostring(context.destinationMapId),
        tostring(context.destinationWarpId)
      )
    else
      self.errorText = tostring(self.transition.error)
    end
  end
  local completed = self.transition:consumeCompleted()
  if completed and self.camera then
    -- The transition may finish on the same fixed tick that applies the
    -- destination stair/door arrival. Publish a settled camera pair with the
    -- completion event so the first post-transition presentation frame cannot
    -- interpolate from the pre-arrival Y history.
    self.camera:collapseRenderInterpolation()
  end
end

-- Every semantic-input entry point below needs the same live-input guard;
-- factored so the assertion text stays in one place. Returns the input
-- component so a call site can chain straight into it.
local function requireLiveInput(self)
  return assert(self.input, "field runtime is disposed")
end

-- Semantic input keeps the non-rendering runtime independent of keyboard and
-- gamepad event translation. Hosts drive these edges directly.
---@param direction string
function FieldRuntime:press(direction)
  requireLiveInput(self):press(direction)
end

---@param direction string
function FieldRuntime:release(direction)
  requireLiveInput(self):release(direction)
end

function FieldRuntime:pressAction()
  requireLiveInput(self):pressAction("runtime")
end

function FieldRuntime:releaseAction()
  requireLiveInput(self):releaseAction("runtime")
end

function FieldRuntime:pressCancel()
  requireLiveInput(self):pressCancel("runtime")
end

function FieldRuntime:releaseCancel()
  requireLiveInput(self):releaseCancel("runtime")
end

function FieldRuntime:pressMenu()
  requireLiveInput(self):pressMenu("runtime")
end

function FieldRuntime:releaseMenu()
  requireLiveInput(self):releaseMenu("runtime")
end

-- Helper: determine if this port has implemented the destination application
-- for an action kind.
local function implementationAvailable(self, entry)
  if entry.actionKind == "field_action" then
    return entry.id == "vanilla.save" and self.saveStore ~= nil
  end
  if entry.actionKind == "application" then
    return entry.targetApplication ~= nil and self.applications:has(entry.targetApplication)
  end
  return false
end

-- The Start Menu composition step: build the final action list from the
-- authoritative world-state unlock flags (read through FieldScriptSymbols,
-- never raw numbers) and the registered destination capabilities. The source
-- policy produces source-present entries; the runtime separates source
-- enablement from implementation capability and combines them to set the final
-- enabled state. Construct the controller with the selection remembered
-- across a child-application round trip. Return nil only when no source-present
-- actions exist; disabled entries are visible and remain in the menu.
---@param rememberedActionId string?
---@return StartMenuController? nil when the source has no present actions
function FieldRuntime:_composeStartMenu(rememberedActionId)
  local world = self.scripts.worldState
  local flags = FieldScriptSymbols.flagsByName

  -- Source policy: returns all present actions (regardless of implementation)
  local sourceEntries = StartMenuPolicy.actions({
    hasPokedex = world:isFlagSet(flags.FLAG_GOT_POKEDEX),
    hasStarter = world:isFlagSet(flags.FLAG_GOT_STARTER),
    bagUnlocked = world:isFlagSet(flags.FLAG_GOT_BAG),
    hasPokegear = world:isFlagSet(flags.FLAG_GOT_POKEGEAR),
    trainerCardUnlocked = world:isFlagSet(flags.FLAG_GOT_TRAINER_CARD),
    saveUnlocked = world:isFlagSet(flags.FLAG_GOT_SAVE_BUTTON),
    optionsUnlocked = world:isFlagSet(flags.FLAG_GOT_OPTIONS_BUTTON),
  })

  if #sourceEntries == 0 then
    return nil
  end

  local function playMenuSequence(sequence)
    if self.audio then
      self.audio:play(sequence)
    end
  end

  -- Compose source policy with implementation capability: set enabled to
  -- true only when both source-enabled AND implementation-available.
  local entries = {}
  for index, source in ipairs(sourceEntries) do
    entries[index] = {
      id = source.id,
      displayPosition = source.displayPosition,
      actionKind = source.actionKind,
      targetApplication = source.targetApplication,
      sourcePresent = true,
      sourceEnabled = source.sourceEnabled,
      implemented = implementationAvailable(self, source),
      enabled = source.sourceEnabled and implementationAvailable(self, source),
    }
  end

  return StartMenuController.new({
    entries = entries,
    slots = self.uiManifest.startMenu.slots,
    cursorFrames = self.uiManifest.startMenu.cursor.frames,
    rememberedActionId = rememberedActionId,
    effect = playMenuSequence,
  })
end

-- The production audio composition and the script audio service are
-- independent axes: the composition is constructed when no recording
-- script audio adapter is injected OR an audio-output host is explicitly
-- provided (a recording adapter then stays the script service while the
-- production renderer/output composition still exists). FieldAudio.compose
-- wires HGSS field policy over the NDS sound runtime, supplies the cry
-- boundary, and builds the LÖVE sink over the injected audio-output host
-- boundary (acceptance fakes it; production defaults to the love.audio +
-- love.sound namespaces, and a host with no audio module has no sink to
-- pump). The caller consumes only the composed service and sink; the
-- FieldAudioController owns the map music/soundplate field policy through
-- enterMap, resolving each map's music through the injected
-- fieldDataForMap lookup. The day/night source defaults to the wall-clock
-- IsNighttime predicate (hours 0-3 and 20-23, the bandForHour nite band);
-- tests and hosts inject a deterministic one.
---@param cacheFs unknown
---@param restoredAudio table<string, unknown>? the restored save's audio bucket, when resuming
---@return table<string, unknown> audioService the GameSound instance, or the injected recording adapter
function FieldRuntime:_composeAudio(cacheFs, restoredAudio)
  assert(type(cacheFs) == "table" and type(cacheFs.loadLua) == "function", "field runtime cache reader required")
  ---@cast cacheFs CacheFs
  local audioService = self.scriptHosts and self.scriptHosts.audio
  if audioService == nil or self.audioOutput ~= nil then
    local function defaultDayNight()
      return TimeOfDayProps.bandForHour(self.localClock:nowLocal().hour) == "nite" and "night" or "day"
    end
    self.mapMusicDayNight = self.dayNight or defaultDayNight
    local world =
      assert(cacheFs:loadLua(MapAssetCache.worldPath()), "world.lua missing -- run `scripts/buildcache.sh` first")
    local function fieldPosition()
      return self.player.fieldX, self.player.fieldZ
    end
    local function fieldDataForMap(mapIdOrSymbol)
      local mapId = mapIdOrSymbol
      if type(mapIdOrSymbol) == "string" then
        mapId = world.bySymbol and world.bySymbol[mapIdOrSymbol]
      end
      if mapId == nil then
        error("unknown map symbol " .. tostring(mapIdOrSymbol))
      end
      local mapData = cacheFs:loadLua(FieldMapDataCache.fieldPath(mapId))
      if type(mapData) ~= "table" then
        error("missing field data for map " .. tostring(mapIdOrSymbol) .. " (" .. tostring(mapId) .. ")")
      end
      if mapData.schema ~= FieldMapDataCache.FIELD_SCHEMA then
        error("field data schema mismatch for map " .. tostring(mapId))
      end
      if mapData.mapId ~= mapId then
        error("field data mapId mismatch for map " .. tostring(mapId))
      end
      return mapData
    end
    local audio = FieldAudio.compose({
      cacheFs = cacheFs,
      outputRate = AUDIO_SAMPLE_RATE,
      eventState = self.eventState,
      fieldPosition = fieldPosition,
      dayNight = self.mapMusicDayNight,
      fieldDataForMap = fieldDataForMap,
      outputHost = self.audioOutput,
    })
    self.audio = audio.service
    self.audioSink = audio.sink
    if audioService == nil then
      audioService = self.audio
    end
    -- Initialize the FieldAudioController with the current map.
    -- Fresh boot: no override. Resume: restore the persisted override.
    self.audio:enterMap(self.runtimeMap, {
      play = true,
      restoredMusicOverride = restoredAudio and restoredAudio.fieldMusicOverride or nil,
    })
  end
  assert(audioService ~= nil, "field runtime audio composition must produce a service")
  return audioService
end

-- Materialize pending avatar transitions: apply them in source order through
-- the transition owner, swap the player visual when the graphic changed, and
-- play the ordered sound intents through the field audio service. The owner
-- holds all durable/visual/pending state; the runtime keeps no copy.
---@return { spriteId: integer, spriteChanged: boolean, sounds: string[] }
function FieldRuntime:applyAvatarTransitions()
  local avatar = assert(self.playerAvatar, "field runtime has no avatar transition owner")
  local result = avatar:applyTransitions()
  if result.spriteChanged then
    assert(self.playerVisual, "field runtime has no player visual"):setAvatar(result.spriteId)
  end
  if #result.sounds > 0 then
    local audio = self.audio or (self.scriptHosts and self.scriptHosts.audio)
    assert(audio and type(audio.play) == "function", "field avatar transition audio host required")
    for _, symbol in ipairs(result.sounds) do
      audio:play(symbol)
    end
  end
  return result
end

-- Capture the current field session for the explicit-save owner. This boundary
-- only builds and validates a snapshot; publication belongs to storage.
---@return table<string, unknown>? snapshot
---@return string|table<string, unknown>? reason validation or stability failure
---@param allowMenu boolean?
function FieldRuntime:_captureGameSave(allowMenu)
  return assert(self.saveCoordinator, "field runtime has no save coordinator"):capture(allowMenu == true)
end

function FieldRuntime:captureGameSave()
  return self:_captureGameSave(false)
end

function FieldRuntime:_captureManualSaveFromMenu()
  return assert(self.saveCoordinator, "field runtime has no save coordinator"):captureManual()
end

function FieldRuntime:_saveCheckpoint()
  return assert(self.saveCoordinator, "field runtime has no save coordinator"):save()
end

-- Apply effective weather to a runtime map: resolve the catalog rules
-- against the injected date/penalty and event state, store
-- effectiveWeatherId for headless inspection, and select the fog preset
-- (base scene fog when unchanged, catalog preset otherwise).
function FieldRuntime:_applyEffectiveWeather(runtimeMap)
  local base = runtimeMap.scene.weatherId
  local date = self.weatherClock:today()
  local hasPenalty = self.weatherClock:hasPenalty()
  local effective = FieldWeatherResolver.resolve(self.weatherCatalog, {
    mapId = runtimeMap.mapId,
    baseWeatherId = base,
    eventState = self.eventState,
    date = date,
    hasPenalty = hasPenalty,
  })
  self:_setLiveWeather(runtimeMap, effective)
end

function FieldRuntime:_setLiveWeather(runtimeMap, weatherId)
  assert(type(runtimeMap) == "table", "live weather requires a runtime map")
  assert(type(weatherId) == "number" and weatherId % 1 == 0, "live weather id must be an integer")
  local catalogPreset = assert(self.weatherCatalog.presets[weatherId], "live weather id has no catalog preset")
  local preset = weatherId == runtimeMap.scene.weatherId and runtimeMap.scene.fog or catalogPreset
  runtimeMap.effectiveWeatherId = weatherId
  if runtimeMap.sceneRuntime then
    runtimeMap.sceneRuntime.fog = preset
  end
end

-- Select the physical owner for a discontinuous outdoor destination. A
-- matching matrix is reusable only when its resident window is centered on
-- the destination cell; otherwise the new owner remains transition-owned
-- until the prepared swap commits.
---@param logicalMap RuntimeFieldMap
---@param position { fieldX: integer, fieldZ: integer }
---@param matrixMemberId integer
---@return FieldRuntimePhysicalSwap
function FieldRuntime:_stagePhysicalCoverage(logicalMap, position, matrixMemberId)
  return assert(self.worldSwapCoordinator, "field runtime has no world-swap coordinator"):stagePhysicalCoverage(
    logicalMap,
    position,
    matrixMemberId
  )
end

-- Fallible warp preparation, run by FieldTransition while the source map is
-- still authoritative: construct the destination player, camera, and player
-- visual, then stage logical residency as the final ownership-bearing step.
-- The coordinator keeps the source logical world live until the hidden commit.
---@param resolution table<string, unknown>
---@param facing FieldDirection
---@return table<string, unknown> prepared destination player, camera, and player visual
function FieldRuntime:_prepareSwap(resolution, facing)
  return assert(self.worldSwapCoordinator, "field runtime has no world-swap coordinator"):prepare(resolution, facing)
end

-- Dispose only transition-owned physical state. A reused coverage remains
-- owned by the runtime, while a staged replacement is released once on abort.
---@param resolution table<string, unknown>?
---@param prepared table<string, unknown>?
---@return nil
function FieldRuntime:_disposePreparedSwap(resolution, prepared)
  return assert(self.worldSwapCoordinator, "field runtime has no world-swap coordinator"):abort(resolution, prepared)
end

-- The irreversible current-map ownership transfer, run by FieldTransition
-- only after every fallible preparation step succeeded. Logical residency is
-- published first; runtime/session pointers and physical ownership follow.
---@param resolution table<string, unknown>
---@param prepared table<string, unknown>
---@return nil
function FieldRuntime:_commitSwap(resolution, _, prepared)
  return assert(self.worldSwapCoordinator, "field runtime has no world-swap coordinator"):commit(
    resolution,
    _,
    prepared
  )
end

function FieldRuntime:destinationWorldPresentable()
  return self.session:destinationWorldPresentable()
end

function FieldRuntime:acknowledgeDestinationPresentation()
  self.session:acknowledgeDestinationPresentation()
end

function FieldRuntime:_updateCameraProjection()
  self.zoom:resize(self.viewport.worldViewport.height)
  self.camera:setProjectionAspect(self.viewport:worldAspect())
  self.camera:setZoom(self.zoom:effectiveZoom())
end

-- Re-apply the user's zoom change to the camera projection.
function FieldRuntime:applyZoomChange()
  self:_updateCameraProjection()
end

-- Presentation geometry sync owned by the runtime: the viewport and menu
-- host geometry, the new screen topology, the one Start Menu placement
-- record (recomputed from the topology and the viewport's world reference
-- frame and handed to the application host for pointer mapping), and the
-- camera projection update together. FieldState calls this exactly once per
-- structural presentation-geometry change.
---@param width integer
---@param height integer
---@param screenTopology ScreenTopology
function FieldRuntime:resizePresentation(width, height, screenTopology)
  self.screenTopology = screenTopology
  self.viewport:resize(width, height)
  self.menuHost:resize(width, height)
  self.menuHost:setScreenTopology(screenTopology)
  self.startMenuPlacement = StartMenuLayout.resolve(screenTopology, self.viewport.referenceFrame)
  self.applicationHost:setMenuPlacement(self.startMenuPlacement)
  self:_updateCameraProjection()
end

-- The one teardown path shared by reset and dispose: release every owned
-- collaborator exactly once and clear every owned field, so a later release
-- call is a no-op. Disposing the dialogue first is deliberate -- a half-open
-- dialogue must never be persisted, so dispose() saves against a cancelled
-- dialogue -- and the field clearing means reset never leaves a hand-picked
-- subset behind for its re-boot.
function FieldRuntime:_releaseAll()
  if self.transition then
    self:_disposePreparedSwap(self.transition.resolution, self.transition.prepared)
  end
  if self.dialogue then
    self.dialogue:dispose()
  end
  self.dialogue = nil
  if self.signpost then
    self.signpost:dispose()
  end
  self.signpost = nil
  -- The application host disposes its active controller exactly once and
  -- releases the modal input lifetime; it must run before the input is
  -- cleared below.
  if self.applicationHost then
    self.applicationHost:dispose()
  end
  self.applicationHost, self.applications, self.startMenuPlacement = nil, nil, nil
  if self.messageProvider then
    self.messageProvider:dispose()
  end
  self.messageProvider = nil
  if self.residency then
    self.residency:dispose()
  end
  self.residency = nil
  if self.actors then
    self.actors:dispose()
  end
  self.playerVisual = nil
  if self.actorAssets then
    local dispose = assert(self.actorAssets.dispose, "field actor assets dispose operation is required")
    dispose(self.actorAssets)
  end
  if self.physicalCoverage then
    self.physicalCoverage:release()
  end
  if self.mapLoader then
    self.mapLoader:release()
  end
  if self.audioSink then
    self.audioSink:release()
  end
  self.actors, self.actorAssets, self.mapLoader = nil, nil, nil
  self.audio, self.audioSink, self.mapMusicDayNight = nil, nil, nil
  self.session, self.saveStore, self.scripts = nil, nil, nil
  self.transition, self.camera, self.player, self.runtimeMap, self.physicalCoverage = nil, nil, nil, nil, nil
  self.fieldTerrainEffectController = nil
  self.fieldEffectAssets = nil
  self.fieldEntranceIndicator, self.fieldEntranceIndicatorAsset = nil, nil
  self.fieldEmoteModels = nil
  self.viewport, self.input, self.menuHost = nil, nil, nil
  self.auxiliaryFieldUi, self.contextChoiceProvider, self.interactionResolver = nil, nil, nil
  self.eventState, self.avatar, self.actorConfig, self.playerData = nil, nil, nil, nil
  self.playerAvatar = nil
  self.windowStyles, self.uiManifest, self.weatherCatalog = nil, nil, nil
  self.monCatalog, self.monLanguage, self.monService = nil, nil, nil
end

-- End the state's lifetime: persist the field session if one is live, then
-- release every owned resource exactly once through the shared teardown. This
-- is the single general disposal hook invoked by App on both state
-- replacement and application shutdown; clearing the capture-bearing fields
-- in the teardown makes a repeat call a no-op rather than a second save.
function FieldRuntime:dispose()
  -- A half-open dialogue must never be persisted; disposal cancels it cleanly
  -- before the capture (and releases it once, before the shared teardown).
  if self.dialogue then
    self.dialogue:dispose()
    self.dialogue = nil
  end
  -- The same transient gate applies to the signpost: a presented window is
  -- cancelled before the save attempt, never persisted.
  if self.signpost then
    self.signpost:dispose()
    self.signpost = nil
  end
  -- The application host owns the other transient modal (the Start Menu, an
  -- application fade, or a child application).
  if self.applicationHost then
    self.applicationHost:dispose()
  end
  self:_releaseAll()
end

return FieldRuntime
