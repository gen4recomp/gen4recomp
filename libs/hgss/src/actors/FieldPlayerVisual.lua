-- Presents the player with ROM-derived field graphics without taking any
-- movement authority from FieldPlayer.
--
-- FieldPlayer stays the only owner of the player's tile, surface, facing, and
-- step timing; this adapter reads that state, keeps the deterministic pose clock
-- the original advances once per field update while walking, and emits the same
-- ActorDrawRecord shape the object actors emit. The clock represents continuous
-- locomotion: it carries the gait phase across tile boundaries and resets only
-- when the player stops or changes facing, matching the original range-based
-- timeline. Its interpolated world position comes from
-- FieldPlayer:renderPosition, so the player and the camera continue to consume
-- one continuous position.
--
-- Pure domain module: no love dependency and no resource ownership. The caller
-- acquires the avatar's visual from FieldActorAssetProvider and hands it in.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")

---@class FieldPlayerVisual.Source
---@field facing string
---@field animationPaused boolean
---@field presentationState fun(self: unknown): { locomotionActive: boolean, gesturePose: string?, gestureTick: integer?, gestureOffsetY: number }
---@field clearGesturePresentation fun(self: unknown)
---@field renderPosition fun(self: unknown, alpha: number?): { x: number, y: number, z: number }

---@class FieldPlayerVisual.SourceInput
---@field facing string?
---@field animationPaused boolean?
---@field presentationState fun(self: FieldPlayerVisual.SourceInput): { locomotionActive: boolean, gesturePose: string?, gestureTick: integer?, gestureOffsetY: number }?
---@field clearGesturePresentation fun(self: FieldPlayerVisual.SourceInput)
---@field renderPosition fun(self: FieldPlayerVisual.SourceInput, alpha: number?): { x: number, y: number, z: number }

---@class FieldPlayerVisual.Options
---@field player unknown
---@field spriteId integer?
---@field playerAvatar FieldPlayerAvatarState? surf-phase owner supplying the presentation offset

---@class FieldPlayerVisual
---@field actorId string
---@field player FieldPlayerVisual.Source
---@field playerAvatar FieldPlayerAvatarState?
---@field spriteId integer?
---@field pose string
---@field poseTick integer
---@field _drawRecord table<string, unknown>
local FieldPlayerVisual = {}
FieldPlayerVisual.__index = FieldPlayerVisual

FieldPlayerVisual.ACTOR_ID = "field:player"

---@param opts FieldPlayerVisual.Options
---@return FieldPlayerVisual
function FieldPlayerVisual.new(opts)
  assert(type(opts) == "table" and type(opts.player) == "table", "FieldPlayerVisual requires a FieldPlayer")
  local player = opts.player
  assert(type(player.facing) == "string", "FieldPlayerVisual requires player facing")
  assert(type(player.renderPosition) == "function", "FieldPlayerVisual requires renderPosition")
  assert(
    type(player.presentationState) == "function" and type(player.clearGesturePresentation) == "function",
    "FieldPlayerVisual requires presentationState and clearGesturePresentation"
  )
  ---@cast player FieldPlayerVisual.Source
  local self = setmetatable({
    actorId = FieldPlayerVisual.ACTOR_ID,
    player = player,
    playerAvatar = opts.playerAvatar,
    spriteId = nil,
    pose = "idle",
    poseTick = 0,
    lastFacing = opts.player.facing,
    _drawRecord = { world = {} },
  }, FieldPlayerVisual)
  self:setAvatar(opts.spriteId)
  return self
end

-- Switch which compiled graphic presents the player. The pose clock restarts so
-- a swap cannot display a frame index the new atlas does not have.
function FieldPlayerVisual:setAvatar(spriteId)
  if type(spriteId) ~= "number" then
    Errors.raise(
      FieldErrors.PLAYER_AVATAR_INVALID,
      "the player avatar requires a compiled spriteId",
      { spriteId = spriteId }
    )
  end
  self.player:clearGesturePresentation()
  self.spriteId = spriteId
  self.poseTick = 0
end

-- Called once per fixed simulation tick with `locomotionAtTickStart`, whether the
-- player was locomoting when the tick began. The animation clock advances on any
-- tick that touches locomotion -- including the commit tick that arrives at a
-- tile, which is why the caller captures the state before advancing the player
-- so the gait phase carries across tile boundaries. It resets only when the
-- player stops (the first genuinely idle tick) or changes facing, matching the
-- original timeline: a standing actor holds the first frame of its facing
-- range, and a turn starts the new range at its first frame.
function FieldPlayerVisual:updateFixed(locomotionAtTickStart)
  local snapshot = self.player:presentationState()
  local walking = not self.player.animationPaused
    and (locomotionAtTickStart == true or snapshot.locomotionActive == true)

  local facingChanged = self.lastFacing ~= self.player.facing
  if facingChanged then
    self.poseTick = 0
  end
  self.lastFacing = self.player.facing

  if walking then
    self.pose = "walk"
    self.poseTick = self.poseTick + 1
  else
    self.pose = "idle"
    self.poseTick = 0
  end
end

-- Stop locomotion presentation at an explicit ownership handoff. This does
-- not alter the player's logical or render position.
function FieldPlayerVisual:settle()
  self.pose = "idle"
  self.poseTick = 0
  self.lastFacing = self.player.facing
end

function FieldPlayerVisual:status()
  return { pose = self.pose, poseTick = self.poseTick }
end

-- `alpha` is the render interpolation factor of the current fixed step. The
-- avatar offset (surf bob) is presentation-only: it is added to the draw
-- record exactly once alongside the gesture offset and never touches the
-- player's logical coordinates.
function FieldPlayerVisual:drawRecord(alpha)
  local point = self.player:renderPosition(alpha)
  local snapshot = self.player:presentationState()
  local record = self._drawRecord
  local gestureOffsetY = snapshot.gestureOffsetY or 0
  local avatarOffset = { x = 0, y = 0, z = 0 }
  if self.playerAvatar then
    avatarOffset = self.playerAvatar:presentationState().playerOffset
  end
  record.actorId = self.actorId
  record.spriteId = self.spriteId
  record.world.x = point.x + avatarOffset.x
  record.world.y = point.y + avatarOffset.y + gestureOffsetY
  record.world.z = point.z + avatarOffset.z
  record.facing = self.player.facing
  record.pose = self.pose
  record.poseTick = self.poseTick
  record.gesturePose = snapshot.gesturePose
  record.gestureTick = snapshot.gestureTick
  record.visible = true
  return record
end

return FieldPlayerVisual
