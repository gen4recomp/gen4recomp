-- Starter-ball story policy selects a prefix of the generated Elm placement
-- records and replaces one scene-owned runtime-prop owner.

local Assert = require("tests.support.Assert")
local StarterLabBallController = require("libs.hgss.src.field.StarterLabBallController")

local T = {}

local function scene()
  local placements = {
    { transform = { "first" } },
    { transform = { "second" } },
    { transform = { "third" } },
  }
  local result = {
    scene = { runtimeProps = { starterBalls = { model = "indoor:141:model", placements = placements } } },
    replacements = {},
  }
  function result:replaceRuntimeStaticProps(owner, selected)
    self.replacements[#self.replacements + 1] = { owner = owner, placements = selected }
  end
  return result
end

local function makeController(flags, partyCount)
  local currentScene = scene()
  local eventState = {
    isFlagSet = function(_, flagId)
      return flags[flagId] == true
    end,
  }
  local party = {
    partyCount = function()
      return partyCount
    end,
  }
  return StarterLabBallController.new({
    eventState = eventState,
    party = party,
    flags = { gotTm51 = 1, metPasserbyBoy = 2 },
    sceneOf = function()
      return currentScene
    end,
  }),
    currentScene
end

local function assertPrefix(replacement, count)
  Assert.equal(replacement.owner, "starter_balls")
  Assert.equal(#replacement.placements, count)
  for index = 1, count do
    Assert.equal(replacement.placements[index].transform[1], ({ "first", "second", "third" })[index])
  end
end

function T.retail_precedence_selects_the_generated_prefix()
  local cases = {
    { flags = { [1] = true, [2] = true }, party = 4, count = 0 },
    { flags = { [2] = true }, party = 4, count = 1 },
    { flags = {}, party = 1, count = 2 },
    { flags = {}, party = 0, count = 3 },
  }
  for _, testCase in ipairs(cases) do
    local controller, currentScene = makeController(testCase.flags, testCase.party)
    controller:placeStarterBalls()
    Assert.equal(#currentScene.replacements, 1)
    assertPrefix(currentScene.replacements[1], testCase.count)
  end
end

function T.repeated_execution_replaces_one_owner_without_mutating_descriptor()
  local controller, currentScene = makeController({}, 1)
  local placements = currentScene.scene.runtimeProps.starterBalls.placements
  controller:placeStarterBalls()
  controller:placeStarterBalls()
  Assert.equal(#currentScene.replacements, 2)
  assertPrefix(currentScene.replacements[2], 2)
  Assert.equal(#placements, 3, "the generated descriptor remains complete")
end

function T.missing_current_runtime_prop_descriptor_is_a_composition_error()
  local currentScene = scene()
  currentScene.scene.runtimeProps = nil
  local controller = StarterLabBallController.new({
    eventState = {
      isFlagSet = function()
        return false
      end,
    },
    party = {
      partyCount = function()
        return 0
      end,
    },
    flags = { gotTm51 = 1, metPasserbyBoy = 2 },
    sceneOf = function()
      return currentScene
    end,
  })
  Assert.throws(function()
    controller:placeStarterBalls()
  end)
end

return { tests = T }
