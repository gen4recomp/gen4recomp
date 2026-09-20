-- The read-only Trainer Card viewer controller: it receives the
-- authoritative player profile and copies the required immutable fields
-- (name, trainerId) at construction, so the open card never changes when the
-- caller's profile record is later replaced or mutated. Status exposes
-- exactly those fields plus the open flag; no unimplemented card statistic is
-- modeled as a placeholder. Gender is not a card presentation field: the
-- controller neither requires nor carries it. It owns close input only and
-- has no access to Start Menu internals; a cancel edge returns
-- { kind = "close" } to the FieldApplicationHost exactly once. The close
-- input step exists in the source (ov51_021E6A54 in
-- asm/overlay_trainer_card_main.s at the pinned decomp commit plays
-- SEQ_SE_GS_GEARCANCEL for B and returns the close state), but this branch
-- does not reproduce the card's cancel effect: the controller requests no
-- sound. Every other input — directions, confirm, the synthesized menu edge,
-- and pointers — changes nothing: while a child application is active its
-- own input policy applies and the menu edge must not tear the card down.
-- The immutable profile fields are copied at construction from the
-- authoritative player profile, and the status exposes those and only those;
-- the renderer presents the audited blank rows for every card value the
-- gameplay model does not own. Pure module: no love, no I/O, no Start Menu
-- internals.

---@class TrainerCardController.Profile
---@field name string
---@field trainerId integer
---@field money number

---@class TrainerCardController.Options
---@field profile TrainerCardController.Profile
---@field playTimeSeconds number
---@field effect fun(sequence: string)? source UI sound effect boundary

---@class TrainerCardController.InputProfile
---@field name string?
---@field trainerId integer?
---@field money number?

---@class TrainerCardController.Input
---@field profile TrainerCardController.InputProfile?
---@field playTimeSeconds number?
---@field effect fun(sequence: string)?

---@class TrainerCardController
---@field _name string
---@field _trainerId integer
---@field _visibleTrainerId integer
---@field _money number
---@field _playTimeSeconds number
---@field _effect fun(sequence: string)? source UI sound effect boundary
---@field _result { kind: "close" }?
---@field _closed boolean
local TrainerCardController = {}
TrainerCardController.__index = TrainerCardController
local PlayerData = require("libs.hgss.src.save.PlayerData")

-- The profile is already canonical before it reaches the controller (the
-- player-data model validates it at the runtime boundary), so construction
-- only asserts the fields the card copies.
---@param opts unknown
---@return TrainerCardController
function TrainerCardController.new(opts)
  assert(type(opts) == "table", "the trainer card controller requires the profile")
  ---@cast opts TrainerCardController.Input
  local profile = opts.profile
  assert(type(profile) == "table", "the trainer card controller requires the profile")
  ---@cast profile TrainerCardController.InputProfile
  assert(
    profile.name ~= nil and profile.trainerId ~= nil,
    "the trainer card requires name and trainerId from the player profile"
  )
  assert(profile.money ~= nil, "the trainer card requires money from the player profile")
  assert(opts.playTimeSeconds ~= nil, "the trainer card requires play time")
  assert(type(opts.playTimeSeconds) == "number" and opts.playTimeSeconds >= 0, "trainer card play time is invalid")
  local name = assert(profile.name)
  local trainerId = assert(profile.trainerId)
  local money = assert(profile.money)
  local playTimeSeconds = assert(opts.playTimeSeconds)
  local self = setmetatable({
    _name = name,
    _trainerId = trainerId,
    _visibleTrainerId = PlayerData.visibleTrainerId(trainerId),
    _money = money,
    _playTimeSeconds = playTimeSeconds,
    _effect = opts.effect,
    _result = nil,
    _closed = false,
  }, TrainerCardController)
  if self._effect then
    self._effect("SEQ_SE_DP_CARD3")
  end
  return self
end

-- One fixed tick. The card consumes its own close edge and the terminal
-- outside dismiss edge; foreign input is ignored (the child-application
-- input policy).
---@param uiInput table[]
function TrainerCardController:updateFixed(uiInput)
  assert(type(uiInput) == "table", "the trainer card input must be an event list")
  if self._closed then
    return
  end
  for _, event in ipairs(uiInput) do
    if not self._closed and type(event) == "table" and (event.type == "cancel" or event.type == "dismiss") then
      self:_close()
    end
  end
end

-- The close edge records the close state; the host owns the actual return
-- path.
function TrainerCardController:_close()
  if self._effect then
    self._effect("SEQ_SE_GS_GEARCANCEL")
  end
  self._result = { kind = "close" }
  self._closed = true
end

-- The presentation snapshot: the copied immutable profile fields. Fresh
-- table per call; the caller may not mutate controller state through it.
---@return table<string, unknown>
function TrainerCardController:status()
  if self._closed then
    return { open = false }
  end
  return {
    open = true,
    name = self._name,
    trainerId = self._trainerId,
    visibleTrainerId = self._visibleTrainerId,
    money = self._money,
    playTimeSeconds = self._playTimeSeconds,
  }
end

-- The result contract: nil until a cancel edge, then exactly one
-- { kind = "close" }. _close already records the closed state; consuming the
-- result must not re-close.
---@return { kind: "close" }?
function TrainerCardController:takeResult()
  local result = self._result
  self._result = nil
  return result
end

-- Idempotent release of the logical lifetime: the host disposes the active
-- controller on success, cancellation, failure, reset, or runtime disposal.
-- A pending result is discarded (no close is reported after disposal).
function TrainerCardController:dispose()
  self._result = nil
  self._closed = true
end

return TrainerCardController
