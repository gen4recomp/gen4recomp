-- Owns the Elm's Lab starter-ball story policy. The generated scene supplies
-- the model and complete placement list; this controller selects only the
-- retail-visible prefix for the current event state.

local StarterLabBallController = {}
StarterLabBallController.__index = StarterLabBallController

function StarterLabBallController.new(opts)
  assert(opts and opts.eventState and opts.party and opts.flags and opts.sceneOf)
  return setmetatable({
    eventState = opts.eventState,
    party = opts.party,
    flags = opts.flags,
    sceneOf = opts.sceneOf,
  }, StarterLabBallController)
end

function StarterLabBallController:placeStarterBalls()
  local current = assert(self.sceneOf(), "starter-ball placement requires a current map")
  local descriptor = assert(current.scene and current.scene.runtimeProps and current.scene.runtimeProps.starterBalls)
  local placements = assert(descriptor.placements)
  local count
  if self.eventState:isFlagSet(self.flags.gotTm51) then
    count = 0
  elseif self.eventState:isFlagSet(self.flags.metPasserbyBoy) then
    count = 1
  elseif self.party:partyCount() > 0 then
    count = 2
  else
    count = 3
  end
  local selected = {}
  for index = 1, count do
    selected[index] = placements[index]
  end
  current:replaceRuntimeStaticProps("starter_balls", selected)
end

return StarterLabBallController
