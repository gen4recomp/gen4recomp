-- FieldRuntime treats a transition preparation failure as a terminal
-- presentation state. The first failing update promotes the transition
-- error after completing that tick; later updates do no simulation work
-- until the owning game flow boots a fresh runtime. There is no registry
-- warm-up slice: script readiness comes from published hashes, not a
-- background corpus pass.

local Assert = require("tests.support.Assert")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")

local T = {}

local function runtimeWithTransitionError(transitionError)
  local calls = { session = 0 }
  local runtime = setmetatable({
    scripts = {},
    session = {
      accumulator = 0,
      updateFixed = function()
        calls.session = calls.session + 1
      end,
    },
    transition = {
      error = transitionError,
      phase = "idle",
      updateSourceFrame = function() end,
      warpContext = {
        sourceMapId = 61,
        sourceWarpId = 0,
        destinationMapId = 60,
        destinationWarpId = 0,
      },
      consumeCompleted = function()
        return nil
      end,
    },
    screenFade = {
      fadeDone = function()
        return true
      end,
      updateSourceFrame = function() end,
    },
    applicationHost = {
      error = function()
        return nil
      end,
    },
  }, FieldRuntime)
  return runtime, calls
end

function T.runtime_freezes_simulation_and_warmup_after_promoting_transition_error()
  local tostringCalls = 0
  local transitionError = setmetatable({}, {
    __tostring = function()
      tostringCalls = tostringCalls + 1
      return "destination preparation failed"
    end,
  })
  local runtime, calls = runtimeWithTransitionError(transitionError)

  runtime:update(1 / 30)
  Assert.equal(calls.session, 1, "the failing update completes its session tick")
  Assert.equal(runtime.errorText, "destination preparation failed\nsource map 61 warp 0 -> map 60 warp 0")

  runtime:update(1 / 30)
  Assert.equal(calls.session, 1, "terminal runtime does not continue session updates")
  Assert.equal(tostringCalls, 1, "the transition failure is formatted once")
  Assert.equal(runtime.errorText, "destination preparation failed\nsource map 61 warp 0 -> map 60 warp 0")
end

return { tests = T }
