-- The script runtime delegates the semantic starter-ball operation to the
-- injected HGSS policy owner and continues immediately.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Runtime = require("libs.script.src.Runtime")

local T = {}

local function runWith(service)
  return {
    instance = { scriptId = "test.starter-balls" },
    services = service and { starterBalls = service } or {},
  }
end

function T.place_starter_balls_delegates_and_continues_same_tick()
  local calls = 0
  local service = {
    placeStarterBalls = function()
      calls = calls + 1
    end,
  }
  Assert.equal(Runtime.executeNode({ op = "place_starter_balls" }, runWith(service)), Runtime.OUTCOME_CONTINUE)
  Assert.equal(calls, 1)
end

function T.missing_starter_ball_service_faults_loudly()
  local err = Assert.throws(function()
    Runtime.executeNode({ op = "place_starter_balls" }, runWith(nil))
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "SCRIPT_SERVICE_MISSING")
end

return { tests = T }
