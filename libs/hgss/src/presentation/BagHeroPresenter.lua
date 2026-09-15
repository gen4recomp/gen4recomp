-- Pocket-indexed hero animation state for the field bag: the narrow
-- presenter behind the upper pane. It resolves the pocket-selected pose
-- and pattern clips from the bag presentation manifest and advances one
-- frame per fixed tick -- the source-frame cadence, never render wall
-- time. It also owns the pocket-aware camera framing transition: the
-- gender framing table selects one distance/angle/model-height record per
-- pocket, construction opens at the neutral baseline record and settles
-- the default pocket over seven fixed ticks, and each pocket switch
-- either starts that seven-tick interpolation immediately or queues one
-- pending target behind the in-flight transition. Mesh acquisition and
-- rasterization stay with the draw stage; this module owns only which
-- animation state is selected and its time base.
-- Pure module: no love, no I/O.

---@class BagHeroPresenter.Framing
---@field angleXDegrees number
---@field angleYDegrees number
---@field distance number
---@field modelY number

---@class BagHeroPresenter
---@field _states table<string, { pose: string, pattern: string }>
---@field _pocket string
---@field _frame integer
---@field _framing table<string, BagHeroPresenter.Framing>
---@field _start BagHeroPresenter.Framing
---@field _target BagHeroPresenter.Framing
---@field _current BagHeroPresenter.Framing
---@field _targetPocket string
---@field _pending string?
---@field _progress integer
---@field _duration integer
local BagHeroPresenter = {}
BagHeroPresenter.__index = BagHeroPresenter

---@class BagHeroPresenter.Options
---@field manifest table<string, unknown> the validated bag manifest carrying hero animation states
---@field gender "male"|"female" the profile-selected hero framing table

---@param value unknown
---@param what string
---@return number
local function finiteNumber(value, what)
  assert(type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge, what)
  return value --[[@as number]]
end

---@param record unknown
---@param what string
---@return BagHeroPresenter.Framing
local function framingRecord(record, what)
  assert(type(record) == "table", what .. " must be a framing record")
  local typed = record --[[@as table<string, unknown>]]
  local distance = finiteNumber(typed.distance, what .. " distance must be finite")
  assert(distance > 0, what .. " distance must be positive")
  return {
    angleXDegrees = finiteNumber(typed.angleXDegrees, what .. " pitch must be finite"),
    angleYDegrees = finiteNumber(typed.angleYDegrees, what .. " yaw must be finite"),
    distance = distance,
    modelY = finiteNumber(typed.modelY, what .. " model height must be finite"),
  }
end

---@param record BagHeroPresenter.Framing
---@return BagHeroPresenter.Framing
local function copyFraming(record)
  return {
    angleXDegrees = record.angleXDegrees,
    angleYDegrees = record.angleYDegrees,
    distance = record.distance,
    modelY = record.modelY,
  }
end

-- Shortest signed arc from one heading to another: the interpolation
-- follows the short way around the circle, so a wrap such as 350 to 10
-- travels +20 rather than -340. The exact-180 case deterministically
-- takes the negative direction under Lua modulo semantics.
---@param fromDegrees number
---@param toDegrees number
---@return number
local function shortestDelta(fromDegrees, toDegrees)
  return ((toDegrees - fromDegrees + 180) % 360) - 180
end

---@param start BagHeroPresenter.Framing
---@param target BagHeroPresenter.Framing
---@param progress integer
---@param duration integer
---@return BagHeroPresenter.Framing
local function interpolateFraming(start, target, progress, duration)
  local ratio = progress / duration
  return {
    angleXDegrees = start.angleXDegrees + shortestDelta(start.angleXDegrees, target.angleXDegrees) * ratio,
    angleYDegrees = start.angleYDegrees + shortestDelta(start.angleYDegrees, target.angleYDegrees) * ratio,
    distance = start.distance + (target.distance - start.distance) * ratio,
    modelY = start.modelY + (target.modelY - start.modelY) * ratio,
  }
end

---@param opts BagHeroPresenter.Options
---@return BagHeroPresenter
function BagHeroPresenter.new(opts)
  assert(type(opts) == "table", "the hero presenter requires options")
  local manifest = assert(opts.manifest, "the hero presenter requires the bag manifest")
  local gender = assert(opts.gender, "the hero presenter requires the hero gender")
  assert(gender == "male" or gender == "female", "the hero gender selects its framing table")
  local hero = assert(manifest.hero, "the bag manifest must carry its hero pane")
  local animations = assert(hero.animations, "the hero pane must carry its animation states")
  assert(type(animations.states) == "table" and #animations.states == 8, "the hero needs eight pocket states")
  local states = {}
  for _, state in ipairs(animations.states) do
    assert(type(state.pocket) == "string" and state.pocket ~= "", "hero states name their pocket")
    assert(type(state.pose) == "string" and state.pose ~= "", "hero states name their pose clip")
    assert(type(state.pattern) == "string" and state.pattern ~= "", "hero states name their pattern clip")
    assert(states[state.pocket] == nil, "hero states repeat pocket " .. state.pocket)
    states[state.pocket] = { pose = state.pose, pattern = state.pattern }
  end
  assert(states.items ~= nil, "the hero needs its default pocket state")
  local presentation = assert(hero.presentation, "the hero pane must carry its presentation facts")
  local framing = assert(presentation.framing, "the hero presentation must carry its pocket framing")
  local duration = assert(framing.transitionTicks, "the hero framing must carry its transition duration")
  assert(duration == 7, "the hero framing transition keeps its seven-tick duration")
  local baseline = assert(framing.baseline, "the hero framing must carry its baseline records")
  local byGender = assert(framing.byGender, "the hero framing must carry its gender pocket records")
  local genderRecords =
    assert(byGender[gender], "the hero framing carries the " .. tostring(gender) .. " pocket records")
  local resolved = {}
  for pocket in pairs(states) do
    resolved[pocket] =
      framingRecord(assert(genderRecords[pocket], "the hero framing carries the " .. pocket .. " record"), pocket)
  end
  local start = framingRecord(
    assert(baseline[gender], "the hero framing carries the " .. tostring(gender) .. " baseline record"),
    "baseline"
  )
  local target = assert(resolved.items, "the hero needs its default pocket framing")
  return setmetatable({
    _states = states,
    _pocket = "items",
    _frame = 0,
    _framing = resolved,
    _start = copyFraming(start),
    _target = copyFraming(target),
    _current = copyFraming(start),
    _targetPocket = "items",
    _pending = nil,
    _progress = 0,
    _duration = duration,
  }, BagHeroPresenter)
end

---@param pocketKey string
function BagHeroPresenter:selectPocket(pocketKey)
  if self._states[pocketKey] == nil then
    error("unknown bag pocket " .. tostring(pocketKey), 0)
  end
  self._pocket = pocketKey
  self._frame = 0
  if self._progress >= self._duration then
    if pocketKey == self._targetPocket then
      return
    end
    self._start = copyFraming(self._target)
    self._targetPocket = pocketKey
    self._target = copyFraming(assert(self._framing[pocketKey], "the hero carries the " .. pocketKey .. " framing"))
    self._progress = 0
    self._current = copyFraming(self._start)
  else
    if pocketKey == self._targetPocket then
      self._pending = nil
    else
      self._pending = pocketKey
    end
  end
end

-- One source-frame step of the selected pocket animation plus one step of
-- the framing interpolation. Progress advances before the snapshot is
-- published, so the seventh tick lands exactly on the target record; a
-- queued pocket then starts from the completed target on the next tick.
function BagHeroPresenter:updateFixed()
  self._frame = self._frame + 1
  if self._progress < self._duration then
    self._progress = self._progress + 1
    if self._progress >= self._duration then
      self._current = copyFraming(self._target)
    else
      self._current = interpolateFraming(self._start, self._target, self._progress, self._duration)
    end
  elseif self._pending ~= nil then
    local nextPocket = assert(self._pending, "the queued hero pocket is selected before resuming")
    self._pending = nil
    self._start = copyFraming(self._target)
    self._targetPocket = nextPocket
    self._target = copyFraming(assert(self._framing[nextPocket], "the hero carries the " .. nextPocket .. " framing"))
    self._progress = 1
    self._current = interpolateFraming(self._start, self._target, self._progress, self._duration)
  else
    self._current = copyFraming(self._target)
  end
end

---@return { pocket: string, pose: string, pattern: string, frame: integer, framing: BagHeroPresenter.Framing }
function BagHeroPresenter:status()
  local state = assert(self._states[self._pocket], "the hero carries its selected state")
  return {
    pocket = self._pocket,
    pose = state.pose,
    pattern = state.pattern,
    frame = self._frame,
    framing = copyFraming(self._current),
  }
end

return BagHeroPresenter
