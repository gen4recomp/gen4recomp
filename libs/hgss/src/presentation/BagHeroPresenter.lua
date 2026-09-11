-- Pocket-indexed hero animation state for the field bag: the narrow
-- presenter behind the upper pane. It resolves the pocket-selected pose
-- and pattern clips from the bag presentation manifest and advances one
-- frame per fixed tick -- the source-frame cadence, never render wall
-- time. Mesh acquisition and rasterization stay with the draw stage; this
-- module owns only which animation state is selected and its time base.
-- Pure module: no love, no I/O.

---@class BagHeroPresenter
---@field _states table<string, { pose: string, pattern: string }>
---@field _pocket string
---@field _frame integer
local BagHeroPresenter = {}
BagHeroPresenter.__index = BagHeroPresenter

---@class BagHeroPresenter.Options
---@field manifest table<string, unknown> the validated bag manifest carrying hero animation states

---@param opts BagHeroPresenter.Options
---@return BagHeroPresenter
function BagHeroPresenter.new(opts)
  assert(type(opts) == "table", "the hero presenter requires options")
  local manifest = assert(opts.manifest, "the hero presenter requires the bag manifest")
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
  return setmetatable({ _states = states, _pocket = "items", _frame = 0 }, BagHeroPresenter)
end

---@param pocketKey string
function BagHeroPresenter:selectPocket(pocketKey)
  if self._states[pocketKey] == nil then
    error("unknown bag pocket " .. tostring(pocketKey), 0)
  end
  self._pocket = pocketKey
  self._frame = 0
end

-- One source-frame step of the selected pocket animation.
function BagHeroPresenter:updateFixed()
  self._frame = self._frame + 1
end

---@return { pocket: string, pose: string, pattern: string, frame: integer }
function BagHeroPresenter:status()
  local state = assert(self._states[self._pocket], "the hero carries its selected state")
  return { pocket = self._pocket, pose = state.pose, pattern = state.pattern, frame = self._frame }
end

return BagHeroPresenter
