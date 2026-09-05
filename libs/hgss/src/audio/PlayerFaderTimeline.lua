-- HGSS source-frame interpolation for NNS player-volume moves.

local NnsSoundMath = require("libs.nds.src.nitro.sound.NnsSoundMath")

local PlayerFaderTimeline = {}
PlayerFaderTimeline.__index = PlayerFaderTimeline

---@class PlayerFaderTimelineEntry
---@field level integer
---@field ramp PlayerFaderTimelineRamp?

---@class PlayerFaderTimelineRamp
---@field start integer
---@field target integer
---@field durationFrames integer
---@field elapsedFrames integer
---@field apply fun(level: integer): integer?
---@field onComplete fun()?

---@class PlayerFaderTimeline
---@field _entries table<integer, PlayerFaderTimelineEntry>
---@field _order integer[]
---@field new fun(): PlayerFaderTimeline
---@field set fun(self: PlayerFaderTimeline, key: integer, level: integer, apply: fun(level: integer): integer?)
---@field reset fun(self: PlayerFaderTimeline, key: integer, level: integer)
---@field replace fun(self: PlayerFaderTimeline, key: integer, target: integer, durationFrames: integer, apply: fun(level: integer): integer?, onComplete: fun()?)
---@field cancel fun(self: PlayerFaderTimeline, key: integer)
---@field update fun(self: PlayerFaderTimeline, shouldAdvance: fun(key: integer): boolean?)

local function assertLevel(level)
  assert(type(level) == "number" and level % 1 == 0, "fader level must be an integer")
  assert(level >= 0 and level <= 128, "fader level must be in 0..128")
end

---@param self PlayerFaderTimeline
---@param key integer
---@return PlayerFaderTimelineEntry
local function entryFor(self, key)
  local entry = self._entries[key]
  if entry == nil then
    entry = { level = 127, ramp = nil }
    self._entries[key] = entry
    self._order[#self._order + 1] = key
  end
  return entry
end

function PlayerFaderTimeline.new()
  return setmetatable({ _entries = {}, _order = {} }, PlayerFaderTimeline) --[[@as PlayerFaderTimeline]]
end

function PlayerFaderTimeline:set(key, level, apply)
  assertLevel(level)
  assert(type(apply) == "function", "fader apply callback is required")
  local entry = entryFor(self --[[@as PlayerFaderTimeline]], key)
  entry.ramp = nil
  entry.level = apply(level) or level
end

function PlayerFaderTimeline:reset(key, level)
  assertLevel(level)
  local entry = entryFor(self --[[@as PlayerFaderTimeline]], key)
  entry.level = level
  entry.ramp = nil
end

function PlayerFaderTimeline:replace(key, target, durationFrames, apply, onComplete)
  assertLevel(target)
  assert(type(durationFrames) == "number" and durationFrames % 1 == 0, "fader duration must be an integer")
  assert(durationFrames >= 0, "fader duration must not be negative")
  assert(type(apply) == "function", "fader apply callback is required")
  local entry = entryFor(self --[[@as PlayerFaderTimeline]], key)
  entry.level = apply(entry.level) or entry.level
  if durationFrames == 0 then
    entry.level = apply(target) or target
    entry.ramp = nil
    if onComplete ~= nil then
      onComplete()
    end
    return
  end
  entry.ramp = {
    start = entry.level,
    target = target,
    durationFrames = durationFrames,
    elapsedFrames = 0,
    apply = apply,
    onComplete = onComplete,
  }
end

function PlayerFaderTimeline:cancel(key)
  local entry = self._entries[key]
  if entry ~= nil then
    entry.ramp = nil
  end
end

function PlayerFaderTimeline:update(shouldAdvance)
  for _, key in ipairs(self._order) do
    local entry = self._entries[key]
    if entry ~= nil and entry.ramp ~= nil and (shouldAdvance == nil or shouldAdvance(key)) then
      local ramp = entry.ramp
      ramp.elapsedFrames = ramp.elapsedFrames + 1
      local level = ramp.start + NnsSoundMath.cDiv(ramp.elapsedFrames * (ramp.target - ramp.start), ramp.durationFrames)
      -- Apply exactly once per source frame and retain the applied value.
      entry.level = ramp.apply(level) or level
      if ramp.elapsedFrames >= ramp.durationFrames then
        entry.ramp = nil
        if ramp.onComplete ~= nil then
          ramp.onComplete()
        end
      end
    end
  end
end

return PlayerFaderTimeline
