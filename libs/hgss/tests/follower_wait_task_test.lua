-- Follower-wait task: polls the one controller's settlement instead of a
-- movement generation, completes on the first settled poll, and carries no
-- state so a save made mid-wait resumes against the reconstructed
-- controller after continue.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FollowerWaitTask = require("libs.hgss.src.script.tasks.FollowerWaitTask")

local T = {}

local function ctxWith(settled)
  return {
    services = {
      followingMon = {
        isMovementSettled = function()
          return settled
        end,
      },
    },
  }
end

function T.wait_blocks_until_the_controller_settles()
  local state = FollowerWaitTask.create({}, ctxWith(false))
  local waiting = FollowerWaitTask.poll(state, ctxWith(false))
  Assert.isFalse(waiting.complete, "an unsettled follower keeps waiting")
  local done = FollowerWaitTask.poll(state, ctxWith(true))
  Assert.isTrue(done.complete, "the first settled poll completes")
  Assert.isNil(done.result, "the wait carries no result value")
end

function T.wait_state_round_trips_through_save_validation()
  local state = FollowerWaitTask.create({}, ctxWith(false))
  Assert.isNil(FollowerWaitTask.validate(state), "empty wait state validates")
  local err = FollowerWaitTask.validate(
    ---@diagnostic disable-next-line: param-type-mismatch -- the failure branch requires a non-table state
    "not-a-table"
  )
  Assert.isTrue(Errors.is(err), "non-table wait state fails validation")
  FollowerWaitTask.cancel(state, "test cancel")
  Assert.equal(state.cancelled, "test cancel", "cancel marks the state")
end

return { tests = T }
