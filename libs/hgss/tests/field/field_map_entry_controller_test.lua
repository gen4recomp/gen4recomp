-- Map-entry lifecycle tests cover the persistent transition boundary owned by
-- the field session's map-entry controller.

local Assert = require("tests.support.Assert")
local FieldMapEntryController = require("libs.hgss.src.field.FieldMapEntryController")

local T = {
  tests = {},
}

local function controllerFixture(overrides)
  local options = {
    scriptScheduler = {
      foregroundEnvironmentId = function()
        return nil
      end,
    },
    initController = {
      hasLifecycle = function(_, lifecycle)
        return lifecycle == "on_transition" or lifecycle == "on_load" or lifecycle == "on_resume"
      end,
      startLifecycle = function()
        return true
      end,
    },
    enterMapActors = function() end,
    autoAcknowledgePresentation = false,
  }
  for key, value in pairs(overrides or {}) do
    options[key] = value
  end
  return FieldMapEntryController.new(options)
end

function T.tests.full_entry_advances_each_owned_phase_once()
  local order = {}
  local controller = controllerFixture({
    initController = {
      hasLifecycle = function(_, lifecycle)
        return lifecycle == "on_transition" or lifecycle == "on_load" or lifecycle == "on_resume"
      end,
      startLifecycle = function(_, lifecycle, tick)
        order[#order + 1] = lifecycle .. ":" .. tick
        return true
      end,
    },
    enterMapActors = function()
      order[#order + 1] = "actors"
    end,
  })

  controller:begin("full")
  Assert.equal(controller:currentStage(), "transition")
  Assert.isTrue(controller:advance(1))
  Assert.equal(controller:currentStage(), "transition_running")
  Assert.isTrue(controller:advance(2))
  Assert.equal(controller:currentStage(), "actors")
  Assert.isTrue(controller:advance(3))
  Assert.equal(controller:currentStage(), "load")
  Assert.isTrue(controller:advance(4))
  Assert.equal(controller:currentStage(), "load_running")
  Assert.isTrue(controller:advance(5))
  Assert.equal(controller:currentStage(), "await_presentation")
  Assert.isFalse(controller:advance(6))
  controller:acknowledgeDestinationPresentation()
  Assert.isTrue(controller:advance(7))
  Assert.equal(controller:currentStage(), "resume_running")
  Assert.isTrue(controller:advance(8))
  Assert.equal(controller:currentStage(), "ready")
  Assert.isFalse(controller:advance(9))
  Assert.isNil(controller:currentStage())
  Assert.deepEqual(order, { "on_transition:1", "actors", "on_load:4", "on_resume:7" })
end

function T.tests.blocked_or_failed_progression_keeps_the_current_phase()
  local scheduler = { busy = true }
  function scheduler:foregroundEnvironmentId()
    return self.busy and "foreground" or nil
  end
  local controller = controllerFixture({
    scriptScheduler = scheduler,
    initController = {
      hasLifecycle = function()
        return true
      end,
      startLifecycle = function()
        error("lifecycle failure")
      end,
    },
  })

  controller:begin("full")
  Assert.isFalse(controller:advance(1))
  Assert.equal(controller:currentStage(), "transition")
  scheduler.busy = false
  Assert.throws(function()
    controller:advance(2)
  end)
  Assert.equal(controller:currentStage(), "transition")
end

function T.tests.full_entry_waits_for_lifecycle_owned_work_after_foreground_finishes()
  local settled = false
  local controller = controllerFixture({
    initController = {
      hasLifecycle = function(_, lifecycle)
        return lifecycle == "on_load"
      end,
      startLifecycle = function()
        return true
      end,
      isLifecycleSettled = function()
        return settled
      end,
    },
  })

  controller:begin("full")
  controller:advance(1)
  controller:advance(2)
  controller:advance(3)
  controller:advance(4)
  Assert.equal(controller:currentStage(), "load_running")
  Assert.isFalse(controller:destinationWorldPresentable())

  settled = true
  Assert.isTrue(controller:advance(5))
  Assert.equal(controller:currentStage(), "await_presentation")
  Assert.isTrue(controller:destinationWorldPresentable())
end

return T
