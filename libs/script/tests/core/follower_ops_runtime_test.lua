-- Script runtime coverage for the follower operations: semantic nodes call
-- exactly one named operation on the injected following-mon collaborator
-- and write source result conventions to their result variables. A missing
-- collaborator is an attributed fault, never a silent skip.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")

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
    startMovement = function(_, action)
      calls[#calls + 1] = { "startMovement", action }
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

function T.explicit_movement_starts_through_the_controller()
  local followingMon = follower()
  local run = runWith(followingMon)
  local action = { action = "jump", direction = "east", distance = "near", speed = "fast" }
  Assert.equal(
    Runtime.executeNode({ op = "follower_start_movement", movement = action }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(followingMon._calls[1][1], "startMovement", "movement starts through the one owner")
  Assert.deepEqual(followingMon._calls[1][2], action, "the decoded movement rides through")
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

return { tests = T }
