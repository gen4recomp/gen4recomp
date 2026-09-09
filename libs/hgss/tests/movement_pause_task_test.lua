-- Whole-world and actor-scoped movement-pause barriers: the unscoped
-- all-movement wait behind the field lock also watches the special follower
-- owner, while the actor-scoped wait answers from its actor alone. The task
-- only queries the follower; it never mutates it, and an absent follower
-- service leaves the existing barrier unchanged.

local Assert = require("tests.support.Assert")
local MovementPauseTask = require("libs.hgss.src.script.tasks.MovementPauseTask")

local T = {}

local function ctxWith(options)
  options = options or {}
  local services = {
    actors = {
      allPausable = function()
        return options.allPausable ~= false
      end,
      isPausable = function()
        return options.actorPausable ~= false
      end,
    },
  }
  if options.followerSettled ~= nil then
    local settled = options.followerSettled
    services.followingMon = {
      isMovementSettled = function()
        return settled
      end,
    }
  end
  return {
    environment = {
      currentGeneration = function()
        return 0
      end,
      movementTasksInGeneration = function()
        return {}
      end,
    },
    scheduler = {
      activeMovementForActor = function()
        return nil
      end,
      taskById = function()
        return nil
      end,
    },
    services = services,
  }
end

function T.unscoped_pause_waits_on_the_unsettled_follower()
  local state = MovementPauseTask.create({ actor = nil }, ctxWith({ followerSettled = false }))
  local waiting = MovementPauseTask.poll(state, ctxWith({ followerSettled = false }))
  Assert.isFalse(waiting.complete, "an unsettled follower holds the whole-world barrier")
  Assert.equal(waiting.state, state, "the waiting poll keeps its state")
end

function T.unscoped_pause_completes_once_the_follower_settles()
  local state = MovementPauseTask.create({ actor = nil }, ctxWith({ followerSettled = true }))
  local done = MovementPauseTask.poll(state, ctxWith({ followerSettled = true }))
  Assert.isTrue(done.complete, "a settled follower releases the whole-world barrier")
  Assert.isTrue(done.result.paused, "the completed barrier still reports its paused result")
end

function T.unscoped_pause_without_a_follower_service_keeps_the_existing_barrier()
  local waiting = MovementPauseTask.poll(
    MovementPauseTask.create({ actor = nil }, ctxWith({ allPausable = false })),
    ctxWith({ allPausable = false })
  )
  Assert.isFalse(waiting.complete, "unpausable actors still hold the barrier without a follower")
  local done = MovementPauseTask.poll(MovementPauseTask.create({ actor = nil }, ctxWith({})), ctxWith({}))
  Assert.isTrue(done.complete, "a pausable field with no follower still completes")
end

function T.actor_scoped_pause_ignores_the_unsettled_follower()
  local state = MovementPauseTask.create({ actor = "elm" }, ctxWith({ followerSettled = false }))
  local done = MovementPauseTask.poll(state, ctxWith({ followerSettled = false }))
  Assert.isTrue(done.complete, "the actor-scoped barrier never waits on the special follower")
end

return { tests = T }
