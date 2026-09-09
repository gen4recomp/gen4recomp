-- Script runtime coverage for the follower operations: semantic nodes call
-- exactly one named operation on the injected following-mon collaborator
-- and write source result conventions to their result variables. A missing
-- collaborator is an attributed fault, never a silent skip.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
local ScriptEnvironment = require("libs.script.src.ScriptEnvironment")

local T = {}

local function follower(overrides)
  overrides = overrides or {}
  local calls = {}
  local collaborator = {
    _calls = calls,
    _active = overrides._active == true,
    _installed = overrides._installed,
    _sourceState = overrides._sourceState,
    _trigger = overrides._trigger == true,
    _settled = overrides._settled ~= false,
    isActive = function(self)
      calls[#calls + 1] = "isActive"
      return self._active
    end,
    isVisible = function(self)
      calls[#calls + 1] = "isVisible"
      return self._active
    end,
    partnerActorId = function(self)
      calls[#calls + 1] = "partnerActorId"
      return self._installed
    end,
    partnerSourceState = function(self)
      calls[#calls + 1] = "partnerSourceState"
      return self._sourceState
    end,
    facePlayer = function()
      calls[#calls + 1] = "facePlayer"
    end,
    setMovementPaused = function(_, paused)
      calls[#calls + 1] = { "setMovementPaused", paused }
    end,
    setMovementType = function(_, mode)
      calls[#calls + 1] = { "setMovementType", mode }
    end,
    isMovementSettled = function(self)
      calls[#calls + 1] = "isMovementSettled"
      return self._settled
    end,
    repositionRelativeToPlayer = function(_, offset, direction)
      calls[#calls + 1] = { "repositionRelativeToPlayer", offset, direction }
    end,
    isEventTrigger = function(self, kind, param)
      calls[#calls + 1] = { "isEventTrigger", kind, param }
      return self._trigger
    end,
  }
  return collaborator
end

local function runWith(collaborator, vars)
  local stored = vars or {}
  local world = {
    getVar = function(_, id)
      return stored[id]
    end,
    setVar = function(_, id, value)
      stored[id] = value
    end,
  }
  return {
    instance = { scriptId = "test.follower", locals = {}, textArgs = {} },
    services = { followingMon = collaborator, world = world },
    semantics = RuntimeValues,
    scheduler = {
      createTask = function(_, taskType)
        return "task:" .. taskType
      end,
    },
    tick = 1,
    input = {},
  },
    stored
end

local function var(id)
  return { value = "var", id = id }
end

function T.active_query_writes_live_controller_state()
  local run, stored = runWith(follower({ _active = true }))
  Assert.equal(Runtime.executeNode({ op = "follower_is_active", result = var(0x800C) }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(stored[0x800C], 1, "an active follower reads true")
  local idle, idleStored = runWith(follower({ _active = false }))
  Assert.equal(Runtime.executeNode({ op = "follower_is_active", result = var(0x800C) }, idle), Runtime.OUTCOME_CONTINUE)
  Assert.equal(idleStored[0x800C], 0, "an inactive follower reads false, never a constant")
end

function T.partner_state_reports_source_object_param_nibble()
  local present, stored = runWith(follower({ _installed = "field:partner", _sourceState = 3 }))
  Assert.equal(
    Runtime.executeNode({ op = "follower_partner_state", result = var(0x800C) }, present),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(stored[0x800C], 3, "the source follower state remains an integer")
  Assert.equal(present.services.followingMon._calls[1], "partnerSourceState", "the source state owns the query")
  local absent, absentStored = runWith(follower({ _sourceState = 0 }))
  Assert.equal(
    Runtime.executeNode({ op = "follower_partner_state", result = var(0x800C) }, absent),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(absentStored[0x800C], 0, "zero source state remains zero")
end

function T.face_player_delegates_to_the_controller()
  local followingMon = follower()
  local run = runWith(followingMon)
  Assert.equal(Runtime.executeNode({ op = "follower_face_player" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(followingMon._calls[1], "facePlayer", "facing runs through the one owner")
end

function T.pause_toggle_sets_the_controller_latch()
  local followingMon = follower()
  local run = runWith(followingMon)
  Assert.equal(Runtime.executeNode({ op = "follower_set_paused", paused = 1 }, run), Runtime.OUTCOME_CONTINUE)
  Assert.deepEqual(followingMon._calls[1], { "setMovementPaused", true }, "a nonzero operand pauses")
  Assert.equal(Runtime.executeNode({ op = "follower_set_paused", paused = 0 }, run), Runtime.OUTCOME_CONTINUE)
  Assert.deepEqual(followingMon._calls[2], { "setMovementPaused", false }, "zero resumes")
end

function T.movement_wait_blocks_on_controller_settlement()
  local run = runWith(follower({ _settled = false }))
  Assert.equal(Runtime.executeNode({ op = "follower_wait" }, run), Runtime.OUTCOME_BLOCK)
  Assert.equal(run.blockTaskId, "task:follower_wait", "the wait parks on the follower task")
end

-- The movement-mode setter dispatches each semantic mode to the one
-- follower owner exactly once and continues in the same tick. Setting a
-- mode is state, so dispatch starts no actor action by itself.
function T.movement_mode_dispatch_sets_the_controller_mode()
  for _, mode in ipairs({ "follow_player", "follow_transition_a", "follow_transition_b" }) do
    local followingMon = follower()
    local run = runWith(followingMon)
    Assert.equal(
      Runtime.executeNode({ op = "follower_set_movement_type", movementType = mode }, run),
      Runtime.OUTCOME_CONTINUE,
      mode .. " must continue in the same tick"
    )
    Assert.equal(#followingMon._calls, 1, mode .. " must call the controller exactly once")
    Assert.deepEqual(followingMon._calls[1], { "setMovementType", mode }, "the semantic mode rides through")
  end
end

function T.reposition_operation_places_through_the_controller()
  local followingMon = follower()
  local run = runWith(followingMon)
  Assert.equal(Runtime.executeNode({ op = "follower_reposition", a = 3, b = 2 }, run), Runtime.OUTCOME_CONTINUE)
  Assert.deepEqual(followingMon._calls[1], { "repositionRelativeToPlayer", 3, 2 }, "both bytes reach the controller")
end

function T.event_trigger_check_writes_the_source_boolean()
  local run, stored = runWith(follower({ _trigger = true }))
  local node = { op = "follower_is_event_trigger", kind = 1, param = 7, result = var(0x800C) }
  Assert.equal(Runtime.executeNode(node, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(stored[0x800C], 1, "a live trigger reads true")
  local cold, coldStored = runWith(follower({ _trigger = false }))
  Assert.equal(Runtime.executeNode(node, cold), Runtime.OUTCOME_CONTINUE)
  Assert.equal(coldStored[0x800C], 0, "no trigger reads false")
end

function T.missing_collaborator_faults_loudly()
  local run = {
    instance = { scriptId = "test.follower", locals = {}, textArgs = {} },
    services = {},
    semantics = RuntimeValues,
  }
  local err = Assert.throws(function()
    Runtime.executeNode({ op = "follower_is_active", result = var(0x800C) }, run)
  end)
  Assert.isTrue(Errors.is(err), "a missing follower collaborator is an attributed fault")
end

-- The all-object field lock coordinates the special follower owner: it
-- pauses follower movement before evaluating the barrier, and an unsettled
-- follower holds the barrier on the existing movement-pause task exactly
-- like outstanding generic movement does.
local function lockRun(environment, services)
  return {
    instance = { scriptId = "test.lock", instanceId = "inst-1", locals = {}, textArgs = {} },
    environment = environment,
    services = services,
    semantics = RuntimeValues,
    scheduler = {
      createTask = function(_, taskType)
        return "task:" .. taskType
      end,
    },
    tick = 1,
    input = {},
  }
end

function T.lock_all_pauses_the_follower_before_checking_the_barrier()
  local order = {}
  local followingMon = {
    setMovementPaused = function(_, paused)
      order[#order + 1] = { "paused", paused }
    end,
    isMovementSettled = function()
      order[#order + 1] = "settled?"
      return false
    end,
  }
  local actors = {
    allPausable = function()
      order[#order + 1] = "pausable?"
      return true
    end,
  }
  local environment = ScriptEnvironment.new({ environmentId = "env-test", mode = "foreground", createdAtTick = 1 })
  local run = lockRun(environment, { followingMon = followingMon, actors = actors })
  local outcome = Runtime.executeNode({ op = "lock_all" }, run)
  Assert.equal(outcome, Runtime.OUTCOME_BLOCK, "an unsettled follower holds the all-movement barrier")
  Assert.equal(run.blockTaskId, "task:movement_pause", "the barrier parks on the existing pause task")
  Assert.deepEqual(order[1], { "paused", true }, "the follower pauses before the barrier is evaluated")
  local settledAt, pausableAt
  for index, entry in ipairs(order) do
    if entry == "settled?" then
      settledAt = index
    elseif entry == "pausable?" then
      pausableAt = index
    end
  end
  Assert.notNil(settledAt, "the barrier queries follower settlement")
  Assert.notNil(pausableAt, "the barrier still queries generic actor pausability")
  Assert.isTrue(settledAt > 1, "follower settlement is queried after the pause")
  Assert.isTrue(pausableAt > 1, "actor pausability is queried after the pause")
end

function T.lock_all_with_a_settled_follower_follows_the_fast_path()
  local calls = {}
  local followingMon = {
    setMovementPaused = function(_, paused)
      calls[#calls + 1] = paused
    end,
    isMovementSettled = function()
      return true
    end,
  }
  local actors = {
    allPausable = function()
      return true
    end,
  }
  local environment = ScriptEnvironment.new({ environmentId = "env-test", mode = "foreground", createdAtTick = 1 })
  local run = lockRun(environment, { followingMon = followingMon, actors = actors })
  local outcome = Runtime.executeNode({ op = "lock_all" }, run)
  Assert.equal(outcome, Runtime.OUTCOME_YIELD_TICK, "a settled field takes the existing fast path")
  Assert.deepEqual(calls, { true }, "even the fast path pauses the follower first")
  Assert.isNil(run.blockTaskId, "the fast path parks no barrier task")
end

-- The all-object field release unpauses the special follower in the same
-- synchronous node that releases the script locks, so the next field
-- follower update observes the unpaused state.
function T.release_all_unpauses_the_follower_and_releases_both_locks()
  local calls = {}
  local followingMon = {
    setMovementPaused = function(_, paused)
      calls[#calls + 1] = paused
    end,
  }
  local environment = ScriptEnvironment.new({ environmentId = "env-test", mode = "foreground", createdAtTick = 1 })
  environment:acquireLock(ScriptEnvironment.LOCK_PLAYER, nil, "inst-1")
  environment:acquireLock(ScriptEnvironment.LOCK_AUTONOMOUS, nil, "inst-1")
  local run = lockRun(environment, { followingMon = followingMon, actors = {} })
  local outcome = Runtime.executeNode({ op = "release_all" }, run)
  Assert.equal(outcome, Runtime.OUTCOME_CONTINUE, "the release continues in the same tick")
  Assert.deepEqual(calls, { false }, "the release unpauses the special follower exactly once")
  Assert.equal(environment:lockCount(ScriptEnvironment.LOCK_PLAYER), 0, "the release still frees the player lock")
  Assert.equal(
    environment:lockCount(ScriptEnvironment.LOCK_AUTONOMOUS),
    0,
    "the release still frees the autonomous lock"
  )
end

return { tests = T }
