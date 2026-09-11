-- Owns staged field-world replacement and its transition callback surface.

local FieldCamera = require("libs.hgss.src.field.FieldCamera")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local FieldGrid = require("libs.hgss.src.world.FieldGrid")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local FieldPlayerVisual = require("libs.hgss.src.actors.FieldPlayerVisual")
local FieldTransition = require("libs.hgss.src.transition.FieldTransition")
local SurfaceResolver = require("libs.hgss.src.world.SurfaceResolver")

---@class FieldWorldSwapCoordinator
---@field runtime FieldRuntime
local FieldWorldSwapCoordinator = {}
FieldWorldSwapCoordinator.__index = FieldWorldSwapCoordinator

---@param runtime FieldRuntime
---@return FieldWorldSwapCoordinator
function FieldWorldSwapCoordinator.new(runtime)
  return setmetatable({ runtime = runtime }, FieldWorldSwapCoordinator)
end

---@param self FieldWorldSwapCoordinator
---@param logicalMap RuntimeFieldMap
---@param position { fieldX: integer, fieldZ: integer }
---@param matrixMemberId integer
---@return FieldRuntimePhysicalSwap
function FieldWorldSwapCoordinator:stagePhysicalCoverage(logicalMap, position, matrixMemberId)
  local runtime = self.runtime
  local destinationAnchorX = math.floor(position.fieldX / FieldGrid.CELL_TILES)
  local destinationAnchorZ = math.floor(position.fieldZ / FieldGrid.CELL_TILES)
  local current = runtime.physicalCoverage
  if
    current
    and current.matrixMemberId == matrixMemberId
    and current.anchorX == destinationAnchorX
    and current.anchorZ == destinationAnchorZ
  then
    return { coverage = current, replacement = false, previous = nil, state = "prepared" }
  end

  local replacement = runtime.mapLoader:createPhysicalCoverage(logicalMap, position)
  return { coverage = replacement, replacement = true, previous = current, state = "prepared" }
end

---@param self FieldWorldSwapCoordinator
---@param resolution table<string, unknown>
---@param facing FieldDirection
---@return table<string, unknown>
function FieldWorldSwapCoordinator:prepare(resolution, facing)
  local runtime = self.runtime
  assert(runtime.transition.fadeAlpha == 1 or runtime.screenFade:isOpaque(), "field map swap must be hidden by fade")
  local runtimeMap = resolution.destinationMap
  runtime:_applyEffectiveWeather(runtimeMap)
  local fieldX, fieldZ = resolution.fieldX, resolution.fieldZ
  local surfaceId, worldY = resolution.surfaceId, resolution.worldY
  if runtime.transition.sourceKind == "door" then
    assert(resolution.destinationWarp, "door destination warp required")
    fieldX = resolution.destinationWarp.x
    fieldZ = resolution.destinationWarp.z - 1
    local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, fieldX, fieldZ)
    local sample = SurfaceResolver.new(runtimeMap.terrain):resolve({
      localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
      localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
      currentY = worldY,
    })
    surfaceId, worldY = sample.surfaceId, sample.worldY
  elseif runtimeMap.terrain then
    local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, fieldX, fieldZ)
    local surface = SurfaceResolver.new(runtimeMap.terrain):resolve({
      localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
      localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
    })
    surfaceId, worldY = surface.surfaceId, surface.worldY
  end
  local function occupancy(candidate)
    return runtime:_playerOccupantAt(candidate)
  end
  local player = FieldPlayer.new({
    currentMap = runtimeMap,
    fieldX = fieldX,
    fieldZ = fieldZ,
    surfaceId = surfaceId,
    initialWorldY = worldY,
    facing = facing,
    occupancy = occupancy,
  })
  local profile = assert(
    runtime.cameraProfiles[runtimeMap.cameraType],
    "field camera cache has no camera type " .. runtimeMap.cameraType
  )
  local camera = FieldCamera.new(profile, { initialTarget = player:renderPosition() })
  camera:setProjectionAspect(runtime.viewport:worldAspect())
  camera:setZoom(runtime.zoom:effectiveZoom())
  local playerVisual = FieldPlayerVisual.new({
    player = player,
    spriteId = assert(runtime.playerAvatar, "field runtime has no avatar transition owner"):currentSpriteId(),
    playerAvatar = runtime.playerAvatar,
  })
  local physical = (resolution.physical and resolution.physical.coverage) and resolution.physical or nil
  local destinationCoverage = physical and physical.coverage or nil
  local residency = assert(runtime.residency):prepareTransition(runtimeMap, destinationCoverage)
  return { player = player, camera = camera, playerVisual = playerVisual, physical = physical, residency = residency }
end

---@param self FieldWorldSwapCoordinator
---@param resolution table<string, unknown>?
---@param prepared table<string, unknown>?
function FieldWorldSwapCoordinator:abort(resolution, prepared)
  local runtime = self.runtime
  local residency = prepared and prepared.residency
  if residency then
    assert(runtime.residency):discardTransition(residency)
  end
  local physical = (prepared and prepared.physical) or (resolution and resolution.physical)
  if not physical or not physical.replacement then
    return
  end
  if physical.state == "released" or physical.state == "committed" then
    return
  end
  assert(physical.state == "prepared", "physical swap is not disposable")
  assert(physical.coverage ~= runtime.physicalCoverage, "staged physical coverage is already committed")
  physical.coverage:release()
  physical.state = "released"
end

---@param self FieldWorldSwapCoordinator
---@param resolution table<string, unknown>
---@param _ FieldDirection
---@param prepared table<string, unknown>
function FieldWorldSwapCoordinator:commit(resolution, _, prepared)
  local runtime = self.runtime
  local runtimeMap = resolution.destinationMap
  local physical = (prepared and prepared.physical) or resolution.physical
  local residency = assert(prepared and prepared.residency, "prepared residency transaction required")
  -- The follower clears before the old map leaves residency; the manager
  -- retires the old entry afterwards and the controller reinstalls once the
  -- new actor map publishes.
  if runtime.followingMon then
    runtime.followingMon:handleMapExit()
  end
  if runtime.followingMonTransition then
    runtime.followingMonTransition:clear()
  end
  assert(runtime.residency):commitTransition(residency)
  local previousCoverage
  if physical then
    assert(physical.state == "prepared", "physical swap is not committable")
    assert(physical.coverage, "physical swap coverage is required")
    if physical.replacement then
      assert(physical.previous == runtime.physicalCoverage, "physical swap source owner changed")
      previousCoverage = runtime.physicalCoverage
      runtime.physicalCoverage = physical.coverage
    else
      assert(physical.coverage == runtime.physicalCoverage, "reused physical coverage is not current")
    end
    assert(runtimeMap.coverage == runtime.physicalCoverage, "destination map coverage is not the committed owner")
    physical.state = "committed"
  end
  runtime.fieldTerrainEffectController:clear()
  runtime.runtimeMap = runtimeMap
  runtime.player = prepared.player
  runtime.transition.player = prepared.player
  runtime.playerVisual = prepared.playerVisual
  runtime.session.playerVisual = prepared.playerVisual
  runtime.camera = prepared.camera
  runtime.session.currentMap = runtimeMap
  runtime.zoneController.currentMap = runtimeMap
  runtime.session.player = prepared.player
  runtime.session.camera = prepared.camera
  if runtime.audio then
    runtime.audio:enterMap(runtimeMap, { clearMusicOverride = true, play = true })
  end
  runtime.scripts:onMapSwap(prepared.player, runtimeMap)
  runtime.session:beginMapEntry()
  if previousCoverage then
    previousCoverage:release()
  end
end

---@param runtime FieldRuntime
---@param doorAt fun(runtimeMap: table<string, unknown>, fieldX: integer, fieldZ: integer): table<string, unknown>?
---@param escalatorAt fun(runtimeMap: table<string, unknown>, fieldX: integer, fieldZ: integer): table<string, unknown>?
---@param resolveDestination function
---@return FieldTransition
function FieldWorldSwapCoordinator:createTransition(runtime, doorAt, escalatorAt, resolveDestination)
  local function onStart(_, trigger)
    runtime.mapLoader:request(trigger.warp.destinationMapId)
    if runtime.audio then
      runtime.audio:beginWarp(trigger.warp.destinationMapId)
    end
  end
  local function playSound(soundRef)
    local audio = runtime.audio or (runtime.scriptHosts and runtime.scriptHosts.audio)
    assert(audio and type(audio.play) == "function", "field transition audio host required")
    audio:play(soundRef)
  end
  local function stopSound(soundRef)
    local audio = runtime.audio or (runtime.scriptHosts and runtime.scriptHosts.audio)
    assert(audio and type(audio.stop) == "function", "field transition audio host required")
    audio:stop(soundRef)
  end
  local function prepare(resolution, facing)
    return self:prepare(resolution, facing)
  end
  local function disposePrepared(resolution, prepared)
    return self:abort(resolution, prepared)
  end
  local function commit(resolution, facing, prepared)
    return self:commit(resolution, facing, prepared)
  end
  local function onProfile(profile, phase)
    assert(type(profile) == "number", "field transition profile required")
    runtime.player.facing = phase == "enter" and runtime.transition.destinationFacing or runtime.transition.facing
  end
  local function cameraAdjust(profile, adjustment, player)
    assert(runtime.camera and type(runtime.camera.adjustTransition) == "function", "field transition camera required")
    if player and type(runtime.camera.setTransitionPlayer) == "function" then
      runtime.camera:setTransitionPlayer(player)
    end
    runtime.camera:adjustTransition(profile, adjustment)
  end
  local function onPanel(phase)
    runtime.transitionPanel = phase
    local screen = runtime.scriptHosts and runtime.scriptHosts.screen
    if screen and type(screen.setPanelTransition) == "function" then
      screen:setPanelTransition(phase)
    end
  end
  return FieldTransition.new({
    loader = runtime.mapLoader,
    prepare = prepare,
    disposePrepared = disposePrepared,
    commit = commit,
    doorAt = doorAt,
    escalatorAt = escalatorAt,
    resolveDestination = resolveDestination,
    onStart = onStart,
    playSound = playSound,
    stopSound = stopSound,
    onProfile = onProfile,
    cameraAdjust = cameraAdjust,
    onPanel = onPanel,
  })
end

return FieldWorldSwapCoordinator
