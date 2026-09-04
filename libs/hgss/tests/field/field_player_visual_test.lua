-- The player visual adapter must read FieldPlayer and never write it: pose from
-- motion, facing from the player, interpolated world position from the shared
-- render position, and a deterministic clock that only advances mid-step.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local FieldActorPose = require("libs.hgss.src.presentation.FieldActorPose")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local FieldPlayerVisual = require("libs.hgss.src.actors.FieldPlayerVisual")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")

---@class TestPlayerStub : FieldPlayerVisual.Source
---@field motion string
---@field worldX number
---@field worldY number
---@field worldZ number
---@field previousWorldX number
---@field previousWorldY number
---@field previousWorldZ number
---@field _gesturePose string?
---@field _gestureTick integer?
---@field _gestureOffsetY number

local T = {}

local EMPTY_MAP_PROPS = {}
---@cast EMPTY_MAP_PROPS MapProps

local function runtimeMap()
  return {
    mapId = 60,
    mapSymbol = "test-map",
    mapSection = "test-section",
    mapSectionNativeId = 7,
    followMode = "ALLOW",
    coordinateOrigin = { x = 0, z = 0 },
    scene = {},
    fieldData = { events = {} },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      isBlockedLocal = function()
        return false
      end,
    },
    terrain = TerrainSurface.new({
      plates = {
        {
          id = 0,
          minX = 0,
          minZ = 0,
          maxX = 32,
          maxZ = 32,
          normal = { x = 0, y = 1, z = 0 },
          distance = 0,
          slopeClass = "flat",
        },
      },
    }),
    terrainDependencyHash = "test-terrain",
    mapProps = EMPTY_MAP_PROPS,
    fieldRegion = {},
    cameraType = 0,
    release = function() end,
    updateAnimated = function() end,
  } --[[@as RuntimeFieldMap]]
end

-- A FieldPlayer-shaped stub: the adapter must depend only on this surface.
---@return TestPlayerStub
local function player()
  ---@type TestPlayerStub
  local stub = {
    facing = "south",
    motion = "idle",
    worldX = 2,
    worldY = 0.5,
    worldZ = 3,
    previousWorldX = 1,
    previousWorldY = 0.5,
    previousWorldZ = 3,
    animationPaused = false,
    _gesturePose = nil,
    _gestureTick = nil,
    _gestureOffsetY = 0,
    renderPosition = function(self, alpha)
      ---@cast self TestPlayerStub
      alpha = alpha == nil and 1 or alpha
      return {
        x = self.previousWorldX + (self.worldX - self.previousWorldX) * alpha,
        y = self.previousWorldY + (self.worldY - self.previousWorldY) * alpha,
        z = self.previousWorldZ + (self.worldZ - self.previousWorldZ) * alpha,
      }
    end,
    clearGesturePresentation = function(self)
      ---@cast self TestPlayerStub
      self._gesturePose = nil
      self._gestureTick = nil
      self._gestureOffsetY = 0
    end,
    presentationState = function(self)
      local locomotionActive = self.motion == "walking" or self.motion == "turning" or self.motion == "jumping"
      return {
        locomotionActive = locomotionActive,
        gesturePose = self._gesturePose,
        gestureTick = self._gestureTick,
        gestureOffsetY = self._gestureOffsetY,
      }
    end,
  }
  return stub
end

-- A real FieldPlayer on an open flat map, for the tile-boundary phase tests.
local function movingPlayer()
  return FieldPlayer.new({ currentMap = runtimeMap(), fieldX = 0, fieldZ = 4, surfaceId = 0, facing = "east" })
end

-- Drive one full session-style tick: capture the pre-update walk-pose state,
-- advance the player, then advance the visual with that capture.
local function walkTick(subject, presentation, direction)
  local walkPoseAtTickStart = subject.motion == "walking" or subject.motion == "turning"
  subject:updateFixed({ heldDirection = direction, pressedDirection = direction })
  presentation:updateFixed(walkPoseAtTickStart)
end

---@param subject FieldPlayer|FieldPlayerVisual.Source
---@return FieldPlayerVisual
local function visual(subject)
  return FieldPlayerVisual.new({
    player = subject,
    spriteId = 0,
  })
end

function T.stands_still_until_the_player_walks()
  local subject = player()
  local presentation = visual(subject)
  presentation:updateFixed()
  Assert.equal(presentation.pose, "idle")
  Assert.equal(presentation.poseTick, 0)

  subject.motion = "walking"
  presentation:updateFixed()
  presentation:updateFixed()
  Assert.equal(presentation.pose, "walk")
  Assert.equal(presentation.poseTick, 2, "the clock advances once per fixed tick while stepping")

  subject.motion = "idle"
  presentation:updateFixed()
  Assert.equal(presentation.pose, "idle")
  Assert.equal(presentation.poseTick, 0, "a settled player holds its facing's first frame")
end

function T.a_stationary_turn_uses_the_walk_pose_without_displacing_the_player()
  local subject = FieldPlayer.new({
    currentMap = runtimeMap(),
    fieldX = 0,
    fieldZ = 4,
    surfaceId = 0,
    facing = "south",
  })
  local presentation = visual(subject)
  local start = { x = subject.worldX, y = subject.worldY, z = subject.worldZ }

  local firstTurn = subject:updateFixed({ heldDirection = "north", pressedDirection = "north" })
  presentation:updateFixed(true)
  Assert.isFalse(firstTurn)
  Assert.equal(subject.facing, "north")
  Assert.equal(subject.motion, "turning")
  Assert.equal(presentation.pose, "walk")
  Assert.equal(presentation.poseTick, 1)
  Assert.equal(presentation.spriteId, 0)

  local secondTurn = subject:updateFixed({})
  presentation:updateFixed(true)
  Assert.isFalse(secondTurn)
  Assert.equal(subject.motion, "idle")
  Assert.equal(presentation.pose, "walk")
  Assert.equal(presentation.poseTick, 2)
  Assert.equal(subject.worldX, start.x)
  Assert.equal(subject.worldY, start.y)
  Assert.equal(subject.worldZ, start.z)

  subject:updateFixed({})
  presentation:updateFixed(false)
  Assert.equal(presentation.pose, "idle")
  Assert.equal(presentation.poseTick, 0)
end

function T.the_draw_record_interpolates_the_shared_render_position()
  local subject = player()
  local presentation = visual(subject)
  local record = presentation:drawRecord(0.5)
  Assert.equal(record.actorId, "field:player")
  Assert.equal(record.spriteId, 0)
  Assert.near(record.world.x, 1.5, 1e-9)
  Assert.equal(record.facing, "south")
  Assert.equal(record.pose, "idle")
  Assert.isTrue(record.visible)
end

function T.the_draw_record_and_world_table_are_reused_and_updated()
  local subject = player()
  local presentation = visual(subject)
  local record = presentation:drawRecord(0.5)
  subject.previousWorldX = 2
  subject.worldX = 5
  subject.facing = "east"

  local updated = presentation:drawRecord(1)
  Assert.isTrue(updated == record, "the player record is reusable")
  Assert.isTrue(updated.world == record.world, "the player world table is reusable")
  Assert.equal(updated.world.x, 5)
  Assert.equal(updated.facing, "east")
end

function T.the_record_follows_the_players_facing()
  local subject = player()
  local presentation = visual(subject)
  subject.facing = "east"
  Assert.equal(presentation:drawRecord(1).facing, "east")
end

function T.switching_avatar_restarts_the_pose_clock()
  local subject = player()
  local presentation = visual(subject)
  subject.motion = "walking"
  presentation:updateFixed()
  presentation:setAvatar(97)
  Assert.equal(presentation.spriteId, 97)
  Assert.equal(presentation.poseTick, 0, "a shorter atlas must not be indexed by the old clock")
end

function T.settle_stops_the_pose_clock_and_retains_the_players_facing()
  local subject = player()
  local presentation = visual(subject)
  subject.facing = "east"
  presentation.pose = "walk"
  presentation.poseTick = 7
  presentation.lastFacing = "south"

  presentation:settle()

  Assert.equal(presentation.pose, "idle")
  Assert.equal(presentation.poseTick, 0)
  Assert.equal(presentation.lastFacing, "east")
  Assert.equal(subject.facing, "east")
end

function T.rejects_an_avatar_without_a_compiled_sprite_id()
  local subject = player()
  local err = Assert.throws(function()
    FieldPlayerVisual.new({ player = subject })
  end)
  Assert.isTrue(
    Errors.is(err) and err.code == "PLAYER_AVATAR_INVALID",
    "expected PLAYER_AVATAR_INVALID, got " .. tostring(err)
  )
end

-- A two-tile walk is the gait the ROM spans: the character animation range is
-- 16 ticks long, exactly two eight-tick walking tiles, so the phase must
-- survive the tile commit instead of restarting on every arrival.
function T.a_two_tile_walk_carries_the_phase_across_the_tile_commit()
  local subject = movingPlayer()
  local presentation = visual(subject)
  for _ = 1, 8 do
    walkTick(subject, presentation, "east")
  end
  Assert.equal(subject.motion, "idle", "the first tile committed")
  Assert.equal(subject.fieldX, 1)
  Assert.equal(presentation.pose, "walk", "the commit tick is still a walking tick")
  Assert.equal(presentation.poseTick, 8, "the phase holds through the tile boundary")

  for _ = 1, 8 do
    walkTick(subject, presentation, "east")
  end
  Assert.equal(subject.fieldX, 2, "the second tile committed")
  Assert.equal(presentation.pose, "walk")
  Assert.equal(presentation.poseTick, 16, "two tiles advance the full 16-tick cycle")
end

-- With the phase allowed to reach the full ROM range, every frame of that range
-- displays: frame 3 of a 16-tick range is unreachable if the clock resets every
-- eight ticks, which is exactly the bug this guards against.
function T.sixteen_continuous_ticks_traverse_the_entire_rom_range()
  local subject = movingPlayer()
  local def = FieldActorFixture.visual(0, { frameCount = 8 })
  for _, direction in pairs(def.directions) do
    direction.walk = {
      frames = {
        { frameIndex = 1, ticks = 4 },
        { frameIndex = 2, ticks = 4 },
        { frameIndex = 3, ticks = 4 },
        { frameIndex = 4, ticks = 4 },
      },
      loop = true,
      durationTicks = 16,
      sourceRange = { startFrame = 0, endFrame = 15, endMode = 0 },
    }
  end
  local presentation = FieldPlayerVisual.new({
    player = subject,
    spriteId = 0,
  })
  local framesAtTick = {}
  for tick = 1, 16 do
    walkTick(subject, presentation, "east")
    framesAtTick[tick] = FieldActorPose.frameIndex(def, "east", "walk", presentation.poseTick)
  end
  Assert.equal(presentation.poseTick, 16)
  Assert.equal(framesAtTick[8], 3, "the back half of the range is reachable mid-cycle")
  Assert.equal(framesAtTick[12], 4)
  Assert.equal(framesAtTick[16], 1, "the cycle wraps to its first frame")
end

function T.the_first_genuinely_idle_tick_resets_the_phase()
  local subject = movingPlayer()
  local presentation = visual(subject)
  for _ = 1, 8 do
    walkTick(subject, presentation, "east")
  end
  Assert.equal(presentation.poseTick, 8)
  Assert.equal(presentation.pose, "walk")

  local walkingAtTickStart = subject.motion == "walking"
  Assert.isFalse(walkingAtTickStart, "the player settled on the commit tick")
  subject:updateFixed({})
  presentation:updateFixed(walkingAtTickStart)
  Assert.equal(presentation.pose, "idle")
  Assert.equal(presentation.poseTick, 0, "only a genuinely idle tick resets the clock")
end

function T.changing_facing_during_continuous_movement_resets_the_phase()
  local subject = movingPlayer()
  local presentation = visual(subject)
  for _ = 1, 4 do
    walkTick(subject, presentation, "east")
  end

  -- Turning mid-walk (buffered to the next step) must start the new facing's
  -- range at its first frame, not import the old range's phase.
  for _ = 1, 4 do
    walkTick(subject, presentation, "south")
  end
  for _ = 1, 4 do
    walkTick(subject, presentation, "south")
  end
  Assert.equal(subject.facing, "south")
  Assert.equal(presentation.poseTick, 4, "the phase restarted on the turn tick")

  for _ = 1, 4 do
    walkTick(subject, presentation, "south")
  end
  Assert.equal(subject.fieldZ, 5, "the south tile committed")
  Assert.equal(presentation.poseTick, 8)
end

function T.gesture_does_not_force_walk_pose_and_draw_record_carries_gesture_offset()
  local subject = movingPlayer()
  local presentation = visual(subject)
  subject:beginScriptedAction({ action = "gesture", name = "warp_out" })
  subject:advanceScriptedAction(5, 20)
  presentation:updateFixed(false)
  Assert.equal(presentation.pose, "idle", "gesture does not force walk pose")
  Assert.equal(presentation.poseTick, 0, "gesture keeps idle tick")
  local record = presentation:drawRecord(1)
  Assert.equal(record.gesturePose, nil, "warp has no clip")
  Assert.near(record.world.y, subject.worldY + 5, 1e-9, "warp offset added to draw Y only")
  Assert.equal(subject.worldY, subject.from.worldY, "logical worldY unchanged during warp")
  subject:advanceScriptedAction(20, 20)
  subject:commitScriptedAction()
  presentation:updateFixed(false)
  Assert.equal(presentation.pose, "idle", "held warp does not force walk")
  local held = presentation:drawRecord(1)
  Assert.near(held.world.y, subject.worldY + 20, 1e-9, "held warp offset persists in draw")
end

function T.give_uses_clip_and_fixed_offset_while_walk_remains_distinct()
  local subject = movingPlayer()
  local presentation = visual(subject)
  subject:beginScriptedAction({ action = "gesture", name = "give" })
  subject:advanceScriptedAction(1, 22)
  presentation:updateFixed(false)
  Assert.equal(presentation.pose, "idle", "give is not walking")
  local record = presentation:drawRecord(1)
  Assert.equal(record.gesturePose, "give", "give publishes gesturePose")
  Assert.equal(record.gestureTick, 0, "give tick 0")
  subject:advanceScriptedAction(22, 22)
  subject:commitScriptedAction()
  presentation:updateFixed(false)
  Assert.equal(presentation.pose, "idle", "held give stays idle")
  local held = presentation:drawRecord(1)
  Assert.equal(held.gesturePose, "give", "held give persists")
  Assert.equal(held.gestureTick, 21, "held give tick final")
  -- scripted walk still uses walk pose
  subject:beginScriptedAction({ action = "walk", direction = "east", speed = "normal" })
  presentation:updateFixed(false)
  Assert.equal(presentation.pose, "walk", "scripted walk does use walk pose")
  presentation:updateFixed(true)
  Assert.equal(presentation.pose, "walk", "scripted walk keeps walk pose")
end

function T.avatar_replacement_clears_held_gesture()
  local subject = movingPlayer()
  local presentation = visual(subject)
  subject:beginScriptedAction({ action = "gesture", name = "give" })
  subject:advanceScriptedAction(22, 22)
  subject:commitScriptedAction()
  Assert.equal(subject:presentationState().gesturePose, "give", "give held before avatar change")
  presentation:setAvatar(42)
  local cleared = subject:presentationState()
  Assert.isNil(cleared.gesturePose, "avatar replacement clears held gesture")
  Assert.isNil(cleared.gestureTick, "avatar replacement clears held tick")
  Assert.equal(cleared.gestureOffsetY, 0, "avatar replacement clears offset")
  local record = presentation:drawRecord(1)
  Assert.isNil(record.gesturePose, "draw record cleared after avatar change")
end

function T.presentation_snapshot_distinguishes_locomotion_from_stationary_scripted_actions()
  local subject = movingPlayer()
  local idleSnap = subject:presentationState()
  Assert.isFalse(idleSnap.locomotionActive, "idle without scripted motion is not locomoting")
  Assert.isNil(idleSnap.gesturePose)
  Assert.isNil(idleSnap.gestureTick)
  Assert.equal(idleSnap.gestureOffsetY, 0)

  subject.motion = "walking"
  Assert.isTrue(subject:presentationState().locomotionActive, "manual walking is locomoting")
  subject.motion = "turning"
  Assert.isTrue(subject:presentationState().locomotionActive, "manual turning is locomoting")
  subject.motion = "jumping"
  Assert.isTrue(subject:presentationState().locomotionActive, "manual jumping is locomoting")
  subject.motion = "transition"
  Assert.isFalse(subject:presentationState().locomotionActive, "transition is not locomoting")
  subject.motion = "idle"
  Assert.isFalse(subject:presentationState().locomotionActive, "idle is not locomoting")

  subject:beginScriptedAction({ action = "walk", direction = "east", speed = "normal" })
  Assert.isTrue(subject:presentationState().locomotionActive, "scripted walk is locomoting")
  Assert.equal(subject.motion, "walking", "walk keeps overloaded walking motion")
  subject:cancelScriptedMovement()

  subject:beginScriptedAction({ action = "walk_in_place", speed = "normal" })
  Assert.isTrue(subject:presentationState().locomotionActive, "walk_in_place is locomoting")
  subject:cancelScriptedMovement()

  subject:beginScriptedAction({ action = "jump", direction = "east", distance = "far", speed = "fast" })
  Assert.isTrue(subject:presentationState().locomotionActive, "scripted jump is locomoting")
  subject:cancelScriptedMovement()

  subject:beginScriptedAction({ action = "gesture", name = "warp_out" })
  local gestureSnap = subject:presentationState()
  Assert.isFalse(gestureSnap.locomotionActive, "gesture stays non-locomoting even though motion is walking")
  Assert.equal(subject.motion, "walking")
  subject:cancelScriptedMovement()

  subject:beginScriptedAction({ action = "delay", ticks = 5 })
  Assert.isFalse(subject:presentationState().locomotionActive, "delay is not locomoting")
  Assert.equal(subject.motion, "walking")
  subject:cancelScriptedMovement()

  subject:beginScriptedAction({ action = "emote", name = "exclamation" })
  Assert.isFalse(subject:presentationState().locomotionActive, "emote is not locomoting")
  subject:cancelScriptedMovement()

  subject:beginScriptedAction({ action = "gesture", name = "give" })
  subject:advanceScriptedAction(1, 22)
  local giveSnap = subject:presentationState()
  Assert.equal(giveSnap.gesturePose, "give")
  Assert.equal(giveSnap.gestureTick, 0)
  Assert.equal(giveSnap.gestureOffsetY, 0)
  subject:advanceScriptedAction(10, 22)
  local giveSnap2 = subject:presentationState()
  Assert.equal(giveSnap2.gesturePose, "give")
  Assert.equal(giveSnap2.gestureTick, 9)
  subject:cancelScriptedMovement()

  subject:beginScriptedAction({ action = "gesture", name = "warp_out" })
  subject:advanceScriptedAction(5, 20)
  Assert.equal(subject:presentationState().gestureOffsetY, 5, "warp_out offset mirrors progress")
  Assert.isNil(subject:presentationState().gesturePose, "warp has no clip")
  local beforeMutate = subject:presentationState()
  local mutated = subject:presentationState()
  mutated.locomotionActive = not mutated.locomotionActive
  mutated.gestureOffsetY = 999
  mutated.gesturePose = "tampered"
  local afterMutate = subject:presentationState()
  Assert.equal(afterMutate.gestureOffsetY, 5, "mutating a snapshot does not affect the next snapshot")
  Assert.isNil(afterMutate.gesturePose)
  Assert.isFalse(beforeMutate == mutated, "each call returns a fresh table")
  Assert.isFalse(mutated == afterMutate, "each call returns a fresh table")
  subject:cancelScriptedMovement()

  subject:beginScriptedAction({ action = "gesture", name = "warp_in" })
  subject:advanceScriptedAction(3, 20)
  Assert.equal(subject:presentationState().gestureOffsetY, 17, "warp_in offset is duration minus progress")
  subject:cancelScriptedMovement()
end

function T.visual_requires_presentation_state_and_clear_collaborator()
  local incomplete = {
    facing = "south",
    motion = "idle",
    renderPosition = function(_, alpha)
      alpha = alpha == nil and 1 or alpha
      return { x = 0, y = 0, z = 0 }
    end,
  }
  Assert.throws(function()
    FieldPlayerVisual.new({ player = incomplete, spriteId = 0 })
  end)
  local missingClear = {
    facing = "south",
    motion = "idle",
    renderPosition = function(_, alpha)
      alpha = alpha == nil and 1 or alpha
      return { x = 0, y = 0, z = 0 }
    end,
    presentationState = function(_)
      return { locomotionActive = false, gesturePose = nil, gestureTick = nil, gestureOffsetY = 0 }
    end,
  }
  Assert.throws(function()
    FieldPlayerVisual.new({ player = missingClear, spriteId = 0 })
  end)
  local complete = player()
  local visualInstance = FieldPlayerVisual.new({ player = complete, spriteId = 0 })
  complete._gesturePose = "give"
  complete._gestureTick = 5
  complete._gestureOffsetY = 3
  visualInstance:setAvatar(77)
  Assert.isNil(complete._gesturePose, "setAvatar must clear gesture unconditionally")
  Assert.equal(complete._gestureOffsetY, 0)
end

function T.scripted_walk_family_still_advances_through_presentation_snapshot()
  local subject = movingPlayer()
  local presentation = visual(subject)
  subject:beginScriptedAction({ action = "walk_in_place", speed = "normal" })
  presentation:updateFixed(false)
  Assert.equal(presentation.pose, "walk", "walk_in_place via snapshot is locomoting")
  subject:cancelScriptedMovement()
  presentation:updateFixed(false)
  Assert.equal(presentation.pose, "idle", "after cancel idle")

  subject:beginScriptedAction({ action = "jump", direction = "east", distance = "far", speed = "fast" })
  presentation:updateFixed(subject:presentationState().locomotionActive)
  Assert.equal(presentation.pose, "walk", "jump via snapshot is locomoting")
  subject:cancelScriptedMovement()
  presentation:updateFixed(false)
  Assert.equal(presentation.pose, "idle")
end

function T.avatar_offset_combines_with_gesture_offset_exactly_once()
  local AvatarState = require("libs.hgss.src.actors.FieldPlayerAvatarState")
  local states = {
    walking = 1001,
    cycling = 1002,
    surfing = 1003,
    watering = 1004,
    fishing = 1005,
    poketch = 1006,
    saving = 1007,
    heal = 1008,
    ladder = 1009,
    rocket = 1010,
    rocket_heal = 1011,
    pokeathlon = 1012,
    apricorn_shake = 1013,
    rocket_saving = 1014,
  }
  local surfPresentation = {
    initialPlayerOffset = { x = 0, y = 4 / 16, z = 4 / 16 },
    oscillator = { initialY = 1 / 16, minY = 1 / 16, maxY = 4 / 16, stepY = (1 / 4) / 16 },
    playerBaseOffset = { x = 0, y = 4 / 16, z = 4 / 16 },
    attachmentBaseOffset = { x = 0, y = -1 / 16, z = 0 },
    yawDegrees = { north = 180, south = 0, west = 270, east = 90 },
  }
  local avatar = AvatarState.new({
    capability = { id = "hero", gender = 0, states = states },
    surfPresentation = surfPresentation,
  })
  avatar:queueTransition("surfing")
  local applied = avatar:applyTransitions()
  Assert.equal(applied.spriteId, 1003)
  avatar:updateFixed()

  local subject = player()
  local logicalBefore = { x = subject.worldX, y = subject.worldY, z = subject.worldZ }
  local presentation = FieldPlayerVisual.new({
    player = subject,
    spriteId = applied.spriteId,
    playerAvatar = avatar,
  })
  local record = presentation:drawRecord(1)
  Assert.near(record.world.x, 2, 1e-9)
  Assert.near(record.world.y, 0.5 + 0.328125, 1e-9, "the surf bob is added to the draw Y exactly once")
  Assert.near(record.world.z, 3 + 0.25, 1e-9)
  Assert.equal(subject.worldX, logicalBefore.x, "the avatar offset never touches logical coordinates")
  Assert.equal(subject.worldY, logicalBefore.y)
  Assert.equal(subject.worldZ, logicalBefore.z)

  subject._gestureOffsetY = 5
  local withGesture = presentation:drawRecord(1)
  Assert.near(withGesture.world.y, 0.5 + 0.328125 + 5, 1e-9, "avatar and gesture offsets compose additively")
end

return { tests = T }
