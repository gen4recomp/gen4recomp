-- Owns the deterministic fade/load/swap/fade lifecycle for field warps. Map
-- projection and actor state swap through an injected commit callback only
-- while the viewport is fully black. Destination resolution and construction
-- run before the commit; a preparation failure aborts without changing live
-- map ownership. The commit is irreversible, so faults after it begins
-- propagate instead of pretending to roll back.
--
-- Door warps run the door choreography through the same lifecycle, ordered per
-- HGSS (ov01_021E8744.s): the source door opens at start, the ingress step
-- begins only after the opening finished, the swap waits for the completed
-- ingress at full black, the destination door opens at the swap, the egress
-- begins only after the destination opening finished, the close begins only
-- after the egress movement finished, and input unlocks only when the close
-- and the fade-in are both finished. The fade runs orthogonally where HGSS
-- overlaps it: the source fade-out clamps at black until the ingress
-- completes (never overruns), and the fade-in ending early parks the
-- choreography in the choreo_hold phase -- fadeAlpha stays 0, input locked --
-- until the close finishes. A static door (no animation instance) has
-- isFinished() == nil, so nothing waits on it: the egress begins at the swap
-- and the close resolves immediately. The source door never closes.
--
-- The choreography facts are explicit: sourceKind (the warp's trigger
-- classification, passed down from the trigger paths -- never re-read from
-- the permission grid here), sourceDoor (resolved on the source map), and
-- destinationDoor (resolved at load on the destination map). The destination
-- egress predicate is derived from destinationDoor and the profile's
-- destination-facing semantics at its read sites. Doors are a capability
-- contract: no door resolver means no door
-- choreography at all (a headless caller states it has none, and a door-kind
-- warp degrades to a plain fade), while a supplied resolver returning no door
-- for a required door is bad data and raises. A door-kind warp
-- whose door does not resolve, an ingress step with no terrain destination
-- (surfacing when the choreography reaches the ingress, after the open
-- finished), or an egress step without a terrain destination, is a
-- data-contract failure and raises rather than silently continuing. Door
-- warps skip coordinate suppression; generic standing-tile warps keep it.
-- Nothing here knows NARC ids, animation resource numbers, NSBCA, or
-- animation-list slots: doors are the mapProps doorway API and the player is
-- the field locomotion contract.
--
-- Stair warps use the profile-owned locked source step and never use door
-- animation or coordinate compensation.

local WarpSystem = require("libs.hgss.src.transition.WarpSystem")
local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldTransitionProfile = require("libs.hgss.src.transition.FieldTransitionProfile")
local FieldTransitionFade = require("libs.hgss.src.transition.FieldTransitionFade")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")
local SurfaceResolver = require("libs.hgss.src.world.SurfaceResolver")

---@class FieldTransition
---@field loader FieldMapLoader
---@field prepare fun(resolution: table<string, unknown>, facing: FieldDirection): table<string, unknown>
---@field commit fun(resolution: table<string, unknown>, facing: FieldDirection, prepared: table<string, unknown>)
---@field disposePrepared fun(resolution: table<string, unknown>?, prepared: table<string, unknown>?)? -- releases resources owned before commit
---@field resolveDestination function
---@field doorAt fun(runtimeMap: table<string, unknown>, fieldX: integer, fieldZ: integer): table<string, unknown>|nil -- nil = no door choreography
---@field playSound fun(soundId: string)?
---@field stopSound fun(soundId: string)?
---@field onStart fun(sourceMap: table<string, unknown>, trigger: table<string, unknown>, facing: FieldDirection)? -- invoked once per transition start, before ownership changes
---@field onProfile fun(profile: integer, phase: "exit"|"enter", family: string)? -- source-specific semantic hook
---@field cameraAdjust fun(...: unknown)?
---@field escalatorAt fun(runtimeMap: table<string, unknown>, fieldX: integer, fieldZ: integer): table<string, unknown>?
---@field onPanel fun(...: unknown)?
---@field player table<string, unknown>|nil -- FieldPlayer, bound by the owner across the swap
---@field phase "idle"|"fade_out"|"load_destination"|"swap_map"|"fade_in"|"choreo_hold"
---@field fadeAlpha number
---@field fade FieldTransitionFade|nil
---@field fadeStarted boolean
---@field profileId integer|nil
---@field facing FieldDirection
---@field transitionMode "fixed"|"environment"|"panel"|nil
---@field destinationFacing FieldDirection
---@field locked boolean
---@field sourceKind "door"|"stairs"|"directional"|"generic"|nil -- the trigger classification passed down
---@field sourceDoor table<string, unknown>|nil -- the resolved source door, when the source kind is a door
---@field destinationDoor table<string, unknown>|nil -- the resolved destination door, when the destination resolves one
---@field sourceChoreo "wait_open"|"wait_step"|"profile_motion"|"done"|nil -- the source-side choreography state
---@field destinationChoreo "wait_open"|"wait_step"|"wait_close"|"profile_motion"|"done"|nil -- the destination-side choreography state
---@field activeProfileSound string|nil
---@field ownsPlayerAnimationPause boolean
---@field completed table<string, unknown>?
---@field error unknown?
---@field warpContext table<string, unknown>?
---@field suppression table<string, unknown>?
---@field destinationAnchorY number?
---@field destinationStairPresentationStart table<string, unknown>?
---@field prepared table<string, unknown>?
---@field sourceMap RuntimeFieldMap?
---@field sourceWarp table<string, unknown>?
---@field coveredSwap boolean -- true while a covered scripted swap owns the lifecycle: destination resolution/commit run, but no FieldTransitionFade is created or advanced because an external screen cover already owns visibility
---@field escalator table<string, unknown>?
---@field destinationWarpX integer?
---@field destinationWarpZ integer?
local FieldTransition = {}
FieldTransition.__index = FieldTransition

FieldTransition.PHASES = {
  idle = "idle",
  fade_out = "fade_out",
  fade_in = "fade_in",
  load_destination = "load_destination",
  swap_map = "swap_map",
  choreo_hold = "choreo_hold",
}

function FieldTransition.new(options)
  assert(options and options.loader, "field transition loader required")
  assert(type(options.prepare) == "function", "field transition prepare callback required")
  assert(type(options.commit) == "function", "field transition commit callback required")
  return setmetatable({
    loader = options.loader,
    resolveDestination = options.resolveDestination or WarpSystem.resolveDestination,
    prepare = options.prepare,
    commit = options.commit,
    disposePrepared = options.disposePrepared,
    doorAt = options.doorAt,
    playSound = options.playSound,
    stopSound = options.stopSound,
    onStart = options.onStart, -- invoked once per transition start, before ownership changes
    onProfile = options.onProfile,
    cameraAdjust = options.cameraAdjust,
    escalatorAt = options.escalatorAt,
    onPanel = options.onPanel,
    player = options.player,
    profileId = nil,
    transitionMode = nil,
    destinationFacing = nil,
    destinationAnchorY = nil,
    destinationStairPresentationStart = nil,
    phase = FieldTransition.PHASES.idle,
    locked = false,
    sourceKind = nil,
    sourceDoor = nil,
    destinationDoor = nil,
    sourceChoreo = nil,
    destinationChoreo = nil,
    fadeAlpha = 0,
    fade = nil,
    fadeStarted = false,
    activeProfileSound = nil,
    ownsPlayerAnimationPause = false,
    escalator = nil,
    coveredSwap = false,
  }, FieldTransition)
end

function FieldTransition:presentationStatus()
  local fade = self.fade and self.fade:status()
    or {
      coefficient = self.fadeAlpha * 16,
      color = 0,
      direction = "out",
      completed = false,
    }
  local phase = tostring(self.phase)
  if self.sourceChoreo == "wait_open" then
    phase = "door_open"
  elseif self.sourceChoreo == "wait_step" then
    phase = "door_ingress"
  end
  local overlay
  if self.fade and fade.coefficient > 0 and (not fade.completed or fade.direction == "out") then
    local channel = fade.color == 0x7FFF and 1 or 0
    overlay = { r = channel, g = channel, b = channel, a = math.min(1, math.max(0, fade.coefficient / 16)) }
  end
  return {
    phase = phase,
    coefficient = fade.coefficient,
    color = fade.color,
    direction = fade.direction,
    completed = fade.completed,
    overlay = overlay,
    entryAction = self.profileId == FieldTransitionProfile.DOOR and "step_down" or nil,
  }
end

---@param self FieldTransition
---@return { ["exit"]: string, ["enter"]: string, exitSound: string?, enterSound: string?, adjustment: string?, fadeColor: integer?, entryAction: string? }
local function profileFamily(self)
  return assert(FieldTransitionProfile.ROUTINE_FAMILIES[self.profileId], "transition profile routine missing")
end

---@param self FieldTransition
---@param phase "exit"|"enter"
local function invokeProfile(self, phase)
  local family = profileFamily(self)[phase]
  local profileId = assert(self.profileId)
  if self.onProfile then
    self.onProfile(profileId, phase, family)
  end
end

local function beginProfileMotion(self, phase)
  if self.profileId == FieldTransitionProfile.HORIZONTAL_STAIRS then
    if phase == "exit" then
      assert(self.player and type(self.player.beginTransitionStep) == "function", "stair transition step required")
      local started = self.player:beginTransitionStep(self.facing)
      if not started then
        Errors.raise(
          FieldErrors.MAP_TRANSITION_INGRESS_FAILED,
          "horizontal stair source step resolves no terrain destination",
          {
            mapId = self.sourceMap.mapId,
            warpId = self.sourceWarp.index,
            x = self.sourceWarp.x,
            z = self.sourceWarp.z,
            direction = self.facing,
          }
        )
      end
      return true
    end
    assert(self.player and type(self.player.beginTransitionHeldStair) == "function", "held-stair presentation required")
    assert(self.destinationStairPresentationStart, "held-stair presentation start required")
    return self.player:beginTransitionHeldStair(self.destinationStairPresentationStart, self.destinationFacing)
  end
  if self.profileId == FieldTransitionProfile.ESCALATOR then
    assert(self.escalatorAt, "escalator prop resolver required")
    local map, x, z = assert(self.sourceMap), self.sourceWarp.x, self.sourceWarp.z
    if phase == "enter" then
      local resolution = assert(self.resolution)
      map, x, z = assert(resolution.destinationMap), resolution.fieldX, resolution.fieldZ
    end
    self.escalator = self.escalatorAt(map, x, z)
    assert(self.escalator, "escalator transition prop required")
    assert(type(self.escalator.play) == "function", "escalator prop playback required")
    assert(type(self.escalator.isFinished) == "function", "escalator prop completion required")
    assert(self.player and type(self.player.pauseTransitionAnimation) == "function", "escalator player pause required")
    assert(
      self.player and type(self.player.resumeTransitionAnimation) == "function",
      "escalator player resume required"
    )
    assert(self.player and type(self.player.beginTransitionStep) == "function", "escalator step required")
    self.escalator:play("escalator")
    self.player:pauseTransitionAnimation()
    self.ownsPlayerAnimationPause = true
    local direction = phase == "exit" and self.facing or self.destinationFacing
    local started = self.player:beginTransitionStep(direction)
    assert(started, "escalator transition step could not start")
    if phase == "exit" and self.playSound then
      assert(self.stopSound, "escalator transition sound stop callback required")
      self.playSound(FieldTransitionProfile.ROUTINE_FAMILIES[self.profileId].exitSound)
      self.activeProfileSound = FieldTransitionProfile.ROUTINE_FAMILIES[self.profileId].exitSound
    end
    return started
  end
  if self.profileId == FieldTransitionProfile.LADDER or self.profileId == FieldTransitionProfile.LADDER_DOWN then
    if phase == "exit" then
      assert(self.player, "ladder exit player required")
      local method = self.profileId == FieldTransitionProfile.LADDER and self.player.beginTransitionLadderExit
        or self.player.beginTransitionLadderDownExit
      assert(self.player and type(method) == "function", "ladder exit motion required")
      return method(self.player, self.facing)
    end
    assert(self.player and type(self.player.beginTransitionVerticalReturn) == "function", "ladder return required")
    return self.player:beginTransitionVerticalReturn(self.destinationAnchorY)
  end
  return false
end

local function advanceProfileMotion(self)
  if self.player and (self.player.motion == "transition" or self.player.motion == "walking") then
    return self.player:updateFixed({})
  end
  return false
end

local function startFade(self, direction, color)
  if self.fadeStarted and self.fade and not self.fade:status().completed then
    return
  end
  self.fade = FieldTransitionFade.new({ direction = direction, color = color })
  self.fadeStarted = true
end

local function advanceFade(self)
  if not self.fadeStarted or not self.fade then
    return
  end
  self.fade:updateSourceFrame()
  self.fadeAlpha = self.fade:status().coefficient / 16
end

local function stopProfileSound(self)
  if not self.activeProfileSound then
    return
  end
  assert(self.stopSound, "profile transition sound stop callback required")
  self.stopSound(self.activeProfileSound)
  self.activeProfileSound = nil
end

local function resumeOwnedPlayerAnimation(self)
  if not self.ownsPlayerAnimationPause then
    return
  end
  assert(self.player and type(self.player.resumeTransitionAnimation) == "function", "escalator player resume required")
  self.player:resumeTransitionAnimation()
  self.ownsPlayerAnimationPause = false
end

local function resetTransient(self)
  resumeOwnedPlayerAnimation(self)
  stopProfileSound(self)
  self.fadeAlpha = 0
  self.fade = nil
  self.fadeStarted = false
  self.sourceDoor = nil
  self.destinationDoor = nil
  self.sourceChoreo = nil
  self.destinationChoreo = nil
  self.destinationAnchorY = nil
  self.destinationStairPresentationStart = nil
  self.escalator = nil
  self.progressTicks = 0
  self.coveredSwap = false
end

-- Keep the destination warp resolution as the logical anchor and retain the
-- adjacent stair cell only as the visual start of destination presentation.
local function adjustHorizontalStairDestination(self, resolution)
  assert(resolution.destinationWarp, "horizontal stair destination warp required")
  local localX, localZ =
    FieldCoordinates.fieldToLocal(resolution.destinationMap, resolution.destinationWarp.x, resolution.destinationWarp.z)
  local behavior = resolution.destinationMap.collision:getLocal(localX, localZ).behavior
  local deltaX, facing
  if behavior == MetatileBehavior.BEHAVIOR.WARP_STAIRS_EAST then
    deltaX, facing = 1, "west"
  elseif behavior == MetatileBehavior.BEHAVIOR.WARP_STAIRS_WEST then
    deltaX, facing = -1, "east"
  else
    error("horizontal stair destination has no stair behavior", 0)
  end
  local fieldX = resolution.destinationWarp.x + deltaX
  local fieldZ = resolution.destinationWarp.z
  local adjustedLocalX, adjustedLocalZ = FieldCoordinates.fieldToLocal(resolution.destinationMap, fieldX, fieldZ)
  local sample = SurfaceResolver.new(resolution.destinationMap.terrain):resolve({
    localX = adjustedLocalX + FieldCoordinates.TILE_CENTER_OFFSET,
    localZ = adjustedLocalZ + FieldCoordinates.TILE_CENTER_OFFSET,
    currentY = resolution.worldY,
  })
  self.destinationStairPresentationStart =
    FieldCoordinates.fieldToWorld(resolution.destinationMap, fieldX, fieldZ, sample.worldY)
  self.destinationFacing = facing
  self.destinationWarpX = resolution.destinationWarp.x
  self.destinationWarpZ = resolution.destinationWarp.z
end

-- Door arrivals stand on the floor immediately before the destination door;
-- the warp record itself is the door anchor used for destination choreography.
local function adjustVerticalDestination(self, resolution)
  self.destinationAnchorY = resolution.worldY
  local offset = self.profileId == FieldTransitionProfile.LADDER and -2 or 2
  resolution.worldY = resolution.worldY + offset
end

local function selectProfile(self, sourceMap, trigger)
  local descriptor = trigger.transition
  if not descriptor then
    -- Scripted/plain callers have no source classification. They use the
    -- ordinary field-warp lifecycle, which is distinct from numeric profile
    -- 0 and therefore does not emit profile-0 exit audio.
    if trigger.kind == "door" then
      return FieldTransitionProfile.DOOR, "fixed"
    end
    if trigger.kind == "stairs" then
      return FieldTransitionProfile.HORIZONTAL_STAIRS, "fixed"
    end
    return nil, FieldTransitionProfile.MODE_PANEL
  end
  assert(
    descriptor.mode == FieldTransitionProfile.MODE_FIXED
      or descriptor.mode == FieldTransitionProfile.MODE_ENVIRONMENT
      or descriptor.mode == FieldTransitionProfile.MODE_PANEL,
    "unknown field transition mode"
  )
  if descriptor.mode == FieldTransitionProfile.MODE_FIXED then
    assert(
      FieldTransitionProfile.isValid(descriptor.profile),
      "fixed field transition profile must be an integer from 0 through 8"
    )
    return descriptor.profile, descriptor.mode
  end
  if descriptor.mode == FieldTransitionProfile.MODE_PANEL then
    return nil, descriptor.mode
  end
  local sourceEnvironment = sourceMap.fieldData and sourceMap.fieldData.transitionEnvironment
  assert(sourceEnvironment, "source transition environment required")
  assert(type(self.loader.transitionEnvironment) == "function", "field map transition metadata required")
  local destinationEnvironment = self.loader:transitionEnvironment(self.sourceWarp.destinationMapId)
  return FieldTransitionProfile.selectEnvironment(sourceEnvironment, destinationEnvironment, {
    sourceMapId = sourceMap.mapId,
    destinationMapId = self.sourceWarp.destinationMapId,
    sourceEnvironment = sourceEnvironment,
    destinationEnvironment = destinationEnvironment,
  }),
    descriptor.mode
end

-- Begin the source choreography: resolve the source door at the warp tile and
-- start its opening animation. The scripted ingress step is NOT started here
-- -- it waits for the opening to finish (advanceSourceChoreo), per HGSS.
-- Every production composition supplies a real door resolver (headless or
-- presentation), so a door-kind warp that fails to resolve a door -- whether
-- because no resolver was supplied at all, or a supplied resolver returns
-- none -- is a generated-data failure, not a headless capability gap: it
-- raises rather than degrading to a plain fade or a synthetic open sound.
-- Stair warps instead take movement ownership with their locked source step
-- and do not use the door choreography. Stairs require a player (production
-- FieldRuntime always binds one): a missing player is a programming fault.
local function beginSourceChoreography(self)
  local kind = self.sourceKind
  if kind == "door" then
    -- A door-kind warp always requires a resolved door: production
    -- FieldRuntime supplies a real resolver unconditionally (headless or
    -- presentation), so an absent resolver is the same generated-data
    -- failure as a resolver that returns no door for the tile -- neither
    -- degrades to a plain fade or a synthetic open sound.
    local door = self.doorAt and self.doorAt(self.sourceMap, self.sourceWarp.x, self.sourceWarp.z)
    if not door then
      Errors.raise(
        FieldErrors.MAP_TRANSITION_UNRESOLVED_SOURCE_DOOR,
        "door-kind warp on map "
          .. self.sourceMap.mapId
          .. " at ("
          .. self.sourceWarp.x
          .. ","
          .. self.sourceWarp.z
          .. ") resolves no door placement",
        { mapId = self.sourceMap.mapId, x = self.sourceWarp.x, z = self.sourceWarp.z }
      )
    end
    self.sourceDoor = door
    local sound = door:open()
    if sound and self.playSound then
      self.playSound(sound)
    end
    self.sourceChoreo = "wait_open"
    startFade(self, "out", 0)
    return
  end
  if self.transitionMode == FieldTransitionProfile.MODE_PANEL then
    startFade(self, "out", 0)
    return
  end
  invokeProfile(self, "exit")
  local family = profileFamily(self)
  if
    family.exitSound
    and kind ~= "door"
    and self.profileId ~= FieldTransitionProfile.HORIZONTAL_STAIRS
    and self.profileId ~= FieldTransitionProfile.ESCALATOR
    and self.profileId ~= FieldTransitionProfile.LADDER
    and self.profileId ~= FieldTransitionProfile.LADDER_DOWN
    and self.playSound
  then
    self.playSound(family.exitSound)
  end
  if kind ~= "door" and self.profileId ~= FieldTransitionProfile.HORIZONTAL_STAIRS then
    if
      self.profileId ~= FieldTransitionProfile.LADDER
      and self.profileId ~= FieldTransitionProfile.LADDER_DOWN
      and self.profileId ~= FieldTransitionProfile.ESCALATOR
    then
      startFade(self, "out", family.fadeColor or 0)
    end
  end
  if beginProfileMotion(self, "exit") then
    self.sourceChoreo = "profile_motion"
  end
end

-- Advance the source choreography by one tick: wait_open resolves when the
-- opening finished -- a static door reports nil isFinished, so nothing waits
-- on it -- and begins the scripted ingress step; an ingress step with no
-- terrain destination is a data-contract failure raised here, when the
-- choreography reaches it, not at transition start. wait_step advances the
-- player's step and resolves done when the movement finished.
local function advanceSourceChoreo(self)
  if self.sourceChoreo == "profile_motion" then
    if self.profileId == FieldTransitionProfile.ESCALATOR and not self.fadeStarted then
      local family = profileFamily(self)
      startFade(self, "out", family.fadeColor or 0)
    end
    advanceProfileMotion(self)
    if not self.player or (self.player.motion ~= "transition" and self.player.motion ~= "walking") then
      if self.profileId == FieldTransitionProfile.ESCALATOR then
        local propFinished = not self.escalator or self.escalator:isFinished() ~= false
        if propFinished and self.fadeAlpha == 1 then
          resumeOwnedPlayerAnimation(self)
          stopProfileSound(self)
          self.sourceChoreo = "done"
        end
        return
      end
      if not self.escalator or self.escalator:isFinished() ~= false then
        self.sourceChoreo = "done"
      end
    end
    return
  end
  if self.sourceChoreo == "wait_open" then
    assert(self.sourceDoor, "wait_open always carries the resolved source door")
    local finished = self.sourceDoor:isFinished()
    if finished ~= false then
      assert(self.player and type(self.player.scriptedStep) == "function", "door ingress player required")
      local ok = self.player:scriptedStep("north")
      if not ok then
        Errors.raise(
          FieldErrors.MAP_TRANSITION_INGRESS_FAILED,
          "the ingress step from the door anchor resolves no terrain destination",
          { mapId = self.sourceMap.mapId, x = self.sourceWarp.x, z = self.sourceWarp.z }
        )
      end
      self.sourceChoreo = "wait_step"
    end
    return
  end
  if self.sourceChoreo == "wait_step" then
    if self.player and self.player.motion == "walking" then
      self.player:updateFixed({})
    end
    if not self.player or self.player.motion ~= "walking" then
      self.sourceChoreo = "done"
    end
  end
end

-- At load: resolve the destination door. A destination door alone can activate
-- the choreography (the Elm Lab exit pattern: a non-door source warp whose
-- destination tile is a door), and a source-door warp still has a destination
-- side to prepare. Resolved once here (the load phase runs a single tick),
-- opened after the swap.
local function detectDestinationDoor(self)
  if self.sourceKind == "stairs" or not self.doorAt or not self.resolution.destinationWarp then
    return
  end
  self.destinationDoor =
    self.doorAt(self.resolution.destinationMap, self.resolution.destinationWarp.x, self.resolution.destinationWarp.z)
end

local function needsDoorlessDoorEnterStep(self)
  return self.destinationDoor == nil
    and self.profileId == FieldTransitionProfile.DOOR
    and self.destinationFacing == "south"
end

-- After the swap: open the destination door (its opening runs inside the
-- fade-in) and start the destination choreography. The egress step begins
-- only once the opening finished (advanceDestinationChoreo) -- a static door
-- has nothing to wait for, so it begins at the swap.
local function beginDestinationChoreography(self)
  self.destinationChoreo = "wait_open"
  if self.destinationDoor then
    local sound = self.destinationDoor:open()
    if sound and self.playSound and self.destinationDoor ~= self.sourceDoor then
      self.playSound(sound)
    end
  end
end

-- Advance the destination choreography by one tick: wait_open resolves when
-- there is no door or its opening finished (a static door reports nil
-- isFinished, so nothing waits on it) and begins the south scripted egress
-- step; a failed egress step is a data-contract failure. wait_step advances
-- the player's step, closes the destination door once the movement finished (no
-- door: nothing to close, done), and wait_close resolves when the closing
-- finished -- nil isFinished (static door) resolves immediately.
local function advanceDestinationChoreo(self)
  if self.destinationChoreo == "profile_motion" then
    advanceProfileMotion(self)
    if not self.player or (self.player.motion ~= "transition" and self.player.motion ~= "walking") then
      if self.profileId == FieldTransitionProfile.ESCALATOR then
        if self.escalator and self.escalator:isFinished() == false then
          return
        end
        resumeOwnedPlayerAnimation(self)
      end
      if self.profileId == FieldTransitionProfile.LADDER or self.profileId == FieldTransitionProfile.LADDER_DOWN then
        local direction = self.profileId == FieldTransitionProfile.LADDER and "north" or "south"
        assert(self.player and type(self.player.beginTransitionStep) == "function", "ladder destination step required")
        local ok = self.player:beginTransitionStep(direction)
        if not ok then
          Errors.raise(
            FieldErrors.MAP_TRANSITION_EGRESS_FAILED,
            "the ladder destination step resolves no terrain destination",
            { mapId = self.resolution.destinationMap.mapId, direction = direction }
          )
        end
        self.destinationChoreo = "profile_step"
      else
        self.destinationChoreo = "done"
      end
    end
    return
  end
  if self.destinationChoreo == "profile_step" then
    if self.player and self.player.motion == "walking" then
      self.player:updateFixed({})
    end
    if not self.player or self.player.motion ~= "walking" then
      self.destinationChoreo = "done"
    end
    return
  end
  if self.destinationChoreo == "wait_open" then
    local finished = self.destinationDoor and self.destinationDoor:isFinished()
    if not self.destinationDoor or finished ~= false then
      assert(self.player and type(self.player.scriptedStep) == "function", "door egress player required")
      -- Both an actual destination door and the explicitly admitted
      -- doorless profile-1/south case use HGSS STEP_DOWN.
      local ok = self.player:scriptedStep("south")
      if not ok then
        Errors.raise(
          FieldErrors.MAP_TRANSITION_EGRESS_FAILED,
          "the egress step from the transition anchor resolves no terrain destination",
          { mapId = self.resolution.destinationMap.mapId }
        )
      end
      self.destinationChoreo = "wait_step"
    end
    return
  end
  if self.destinationChoreo == "wait_step" then
    if self.player and self.player.motion == "walking" then
      self.player:updateFixed({})
    end
    if not self.player or self.player.motion ~= "walking" then
      local animatedDoor = self.destinationDoor and self.destinationDoor:isFinished() ~= nil
      if animatedDoor then
        local sound = self.destinationDoor:close()
        if sound and self.playSound then
          self.playSound(sound)
        end
        self.destinationChoreo = "wait_close"
      else
        self.destinationChoreo = "done"
      end
    end
    return
  end
  if self.destinationChoreo == "wait_close" and self.destinationDoor:isFinished() ~= false then
    self.destinationChoreo = "done"
  end
end

-- Run one choreography step (a begin or an advance). Before the ownership
-- commit, a failure aborts to idle and records the error. After the commit,
-- the same failure propagates as fatal because live state cannot be rolled
-- back safely.
local function runChoreo(self, fn)
  local ok, err = pcall(fn, self)
  if not ok then
    if self.phase == FieldTransition.PHASES.fade_out then
      self:_abort(err)
    end
    error(err, 0)
  end
end

-- Advance the source stair step by one tick. The transition advances it like
-- a walk, and the HGSS stair sound fires when the movement completes
-- (sub_0205613C plays SEQ_SE_DP_KAIDAN2 after the step finishes, before the
-- fade). Stair warps require a player (asserted at the source begin), so one
-- is always bound here.
local function finish(self)
  resetTransient(self)
  self.phase = FieldTransition.PHASES.idle
  self.locked = false
  self.completed = {
    sourceMapId = self.sourceMap.mapId,
    destinationMapId = self.resolution.destinationMap.mapId,
    sourceWarpId = self.sourceWarp.index,
  }
  self.sourceMap, self.sourceWarp, self.resolution, self.prepared = nil, nil, nil, nil
end

-- Shared setup for `start`/`startCoveredSwap`: validate preconditions and
-- reset per-transition state common to both lifecycles. Each caller then
-- sets its own remaining fields (profile vs covered-swap marker) and phase.
local function beginTransition(self, sourceMap, trigger, facing)
  assert(self.phase == FieldTransition.PHASES.idle, "field transition already active")
  assert(sourceMap and trigger and trigger.warp and facing, "transition source, trigger, and facing required")
  resetTransient(self)
  self.sourceMap = sourceMap
  self.sourceWarp = trigger.warp
  self.sourceKind = trigger.kind
  self.transitionMode = nil
  self.destinationFacing = trigger.destinationFacing or facing
  self.facing = facing
  self.resolution = nil
  self.suppression = nil
  self.prepared = nil
  self.error = nil
  self.warpContext = nil
  self.completed = nil
end

-- Invoke the onStart callback once per transition start: this callback runs
-- before ownership changes and can fail coherently like other pre-commit
-- failures. Returns false (after aborting) when the callback failed.
local function runOnStart(self, sourceMap, trigger, facing)
  if not self.onStart then
    return true
  end
  local ok, err = pcall(function()
    self.onStart(sourceMap, trigger, facing)
  end)
  if not ok then
    self:_abort(err)
    return false
  end
  return true
end

-- Begin a transition from a warp trigger record: the classified trigger
-- ({ kind, warp }) from the session's trigger paths, or a plain-fade record
-- ({ warp = warp }) from scripted warps, which carry no classification. The
-- kind is authoritative -- the transition never re-reads the permission grid
-- to classify the warp tile.
function FieldTransition:start(sourceMap, trigger, facing)
  beginTransition(self, sourceMap, trigger, facing)
  self.profileId, self.transitionMode = selectProfile(self, sourceMap, trigger)
  if not runOnStart(self, sourceMap, trigger, facing) then
    return
  end

  self.phase = FieldTransition.PHASES.fade_out
  self.locked = true
  self.fadeAlpha = 0
  if self.transitionMode == FieldTransitionProfile.MODE_PANEL then
    if self.onPanel then
      self.onPanel("exit")
    end
  end
  runChoreo(self, beginSourceChoreography)
end

-- Begin a covered scripted map swap: the caller (ScriptMapsService) has
-- already required its screen cover to be fully opaque before calling this,
-- so no FieldTransitionFade is created or advanced here -- the
-- source-authored FadeScreen/WaitFade already owns visibility. This still
-- runs destination resolution/preparation/commit through the same
-- `prepare`/`commit` callbacks as an ordinary transition, so map loader
-- protection, player/camera construction, and error handling stay
-- centralized; it skips straight to `load_destination` and finishes at the
-- swap tick instead of running a fade-in phase.
---@param sourceMap RuntimeFieldMap
---@param trigger table<string, unknown> { warp: table<string, unknown> } -- scripted warps carry no trigger classification
---@param facing FieldDirection
function FieldTransition:startCoveredSwap(sourceMap, trigger, facing)
  beginTransition(self, sourceMap, trigger, facing)
  self.profileId = nil
  self.coveredSwap = true
  if not runOnStart(self, sourceMap, trigger, facing) then
    return
  end
  self.locked = true
  self.phase = FieldTransition.PHASES.load_destination
end

-- Restore a coherent idle state after failed destination preparation. Map
-- ownership remains with the runtime throughout this path.
function FieldTransition:_abort(err)
  if self.disposePrepared and (self.resolution or self.prepared) then
    self.disposePrepared(self.resolution, self.prepared)
  end
  local context
  if self.sourceMap and self.sourceWarp then
    context = {
      sourceMapId = self.sourceMap.mapId,
      sourceWarpId = self.sourceWarp.index,
      destinationMapId = self.sourceWarp.destinationMapId,
      destinationWarpId = self.sourceWarp.destinationWarpId,
    }
  end
  self.phase = FieldTransition.PHASES.idle
  self.locked = false
  resetTransient(self)
  self.completed = nil
  self.suppression = nil
  self.sourceMap, self.sourceWarp, self.resolution, self.prepared = nil, nil, nil, nil
  self.error = err
  self.warpContext = context
end

-- Returns true when the tick advanced the choreographed player step, so the
-- session knows to advance the pose clock. The camera and the scene animation
-- clock advance on every locked tick regardless.
function FieldTransition:updateFixed()
  if self.phase == FieldTransition.PHASES.idle then
    return false
  end
  if self.phase == FieldTransition.PHASES.fade_out then
    -- The locomotion report reflects the tick-start state: false during the
    -- open wait, true while the ingress step runs.
    local playerAdvanced = self.sourceChoreo ~= nil and self.player ~= nil and self.player.motion == "walking"
    if self.sourceChoreo then
      runChoreo(self, advanceSourceChoreo)
    end
    self.progressTicks = self.progressTicks + 1
    if self.sourceChoreo == "done" and not self.fadeStarted then
      local family = profileFamily(self)
      if family.exitSound and self.playSound then
        self.playSound(family.exitSound)
      end
      startFade(self, "out", family.fadeColor or 0)
    end
    -- The ingress finishes after the 12-tick fade, so the fade clamps at
    -- black and holds until the choreography completes -- the swap only ever
    -- happens at full black.
    if not self.fadeStarted then
      self.fadeAlpha = 0
    end
    if self.fadeAlpha == 1 and (not self.sourceChoreo or self.sourceChoreo == "done") then
      self.phase = FieldTransition.PHASES.load_destination
    end
    return playerAdvanced
  end
  if self.phase == FieldTransition.PHASES.load_destination then
    local ok, err = pcall(function()
      local result = self.resolveDestination(self.loader, self.sourceMap, self.sourceWarp)
      self.resolution = result
      if self.profileId == FieldTransitionProfile.HORIZONTAL_STAIRS then
        adjustHorizontalStairDestination(self, result)
      elseif
        self.profileId == FieldTransitionProfile.LADDER or self.profileId == FieldTransitionProfile.LADDER_DOWN
      then
        adjustVerticalDestination(self, result)
      end
      detectDestinationDoor(self)
      -- Door and stair warps never suppress: the player egresses off the anchor
      -- (doors) or lands on the standing stair tile (stairs), so pressing back
      -- re-arms immediately. Generic standing-tile warps keep coordinate
      -- suppression.
      if
        self.sourceKind == "door"
        or self.sourceKind == "directional"
        or self.destinationDoor ~= nil
        or self.sourceKind == "stairs"
      then
        self.suppression = nil
      else
        self.suppression = result.suppression
      end
      self.prepared = self.prepare(result, self.destinationFacing)
    end)
    if not ok then
      return self:_abort(err)
    end
    self.phase = FieldTransition.PHASES.swap_map
    return false
  end
  if self.phase == FieldTransition.PHASES.swap_map then
    assert(self.coveredSwap or self.fadeAlpha == 1, "map swap must occur while fully black")
    self.commit(self.resolution, self.destinationFacing, self.prepared)
    if self.coveredSwap then
      -- The source-authored screen cover owns all visibility for this swap:
      -- no ordinary fade-in, no door/profile choreography. Source `FadeScreen`
      -- (the reveal) runs after the script's `Warp` completes, independent of
      -- this transition.
      finish(self)
      return false
    end
    if self.transitionMode == FieldTransitionProfile.MODE_PANEL then
      if self.onPanel then
        self.onPanel("enter")
      end
    elseif self.profileId then
      invokeProfile(self, "enter")
      local family = profileFamily(self)
      if family.adjustment and self.cameraAdjust then
        self.cameraAdjust(self.profileId, family.adjustment, self.player)
      end
      if beginProfileMotion(self, "enter") then
        self.destinationChoreo = "profile_motion"
      end
      startFade(self, "in", family.fadeColor or 0)
    else
      startFade(self, "in", 0)
    end
    if self.destinationChoreo == nil and (self.destinationDoor ~= nil or needsDoorlessDoorEnterStep(self)) then
      runChoreo(self, beginDestinationChoreography)
      -- Start the destination choreography on the swap tick: an animated door
      -- holds in wait_open, a static one (nothing to wait for) steps at once.
      runChoreo(self, advanceDestinationChoreo)
    end
    self.progressTicks = 0
    self.phase = FieldTransition.PHASES.fade_in
    return false
  end
  if self.phase == FieldTransition.PHASES.fade_in or self.phase == FieldTransition.PHASES.choreo_hold then
    local playerAdvanced = self.destinationChoreo ~= nil
      and self.player ~= nil
      and (self.player.motion == "walking" or self.player.motion == "transition")
    if self.destinationChoreo then
      runChoreo(self, advanceDestinationChoreo)
    end
    if self.phase == FieldTransition.PHASES.fade_in then
      if self.fade and self.fade:status().completed then
        if not self.destinationChoreo or self.destinationChoreo == "done" then
          finish(self)
        else
          -- The egress/close choreography outlives the fade-in: hold black
          -- (fadeAlpha stays 0, input stays locked) in the choreo_hold phase
          -- until the choreography finishes.
          self.phase = FieldTransition.PHASES.choreo_hold
        end
      end
    elseif self.destinationChoreo == "done" then
      finish(self)
    end
    return playerAdvanced
  end
  assert(false, "unknown field transition phase")
end

-- Advances the transition fade by exactly one source frame. Field simulation
-- calls updateFixed separately, and FieldRuntime composes the source-frame
-- order after each fixed field tick.
function FieldTransition:updateSourceFrame()
  if self.phase == FieldTransition.PHASES.idle then
    return false
  end
  if self.fadeStarted and self.fade and not self.fade:status().completed then
    advanceFade(self)
    return true
  end
  return false
end

function FieldTransition:consumeCompleted()
  local completed = self.completed
  self.completed = nil
  return completed
end

return FieldTransition
