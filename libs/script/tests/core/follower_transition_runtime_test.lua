-- Script runtime coverage for the nonblocking follower-transition command:
-- the semantic node consults the follower's live party state, then starts
-- one transient effect through the injected transition service and continues
-- in the same tick when the party qualifies. A command issued while the
-- party holds no eligible lead continues without touching the effect
-- service. The command never parks a wait task: pacing belongs to the
-- script's own explicit wait, not to this command. A missing service is an
-- attributed fault, never a silent skip.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")

local T = {}

local function service(starts, result)
  local transition = { _starts = starts }
  function transition:start()
    self._starts[#self._starts + 1] = true
    return result ~= false
  end
  return transition
end

local function runWith(transitionService, tasks, sourceActive)
  tasks = tasks or {}
  if sourceActive == nil then
    sourceActive = true
  end
  local followingMon = {
    _sourceActive = sourceActive,
    isSourceActive = function(self)
      return self._sourceActive
    end,
  }
  return {
    instance = { scriptId = "test.follower-transition", locals = {}, textArgs = {} },
    services = { followingMon = followingMon, followerTransition = transitionService },
    semantics = RuntimeValues,
    scheduler = {
      createTask = function(_, taskType)
        tasks[#tasks + 1] = taskType
        return "task:" .. taskType
      end,
    },
    tick = 1,
    input = {},
  }
end

function T.transition_starts_and_continues_in_the_same_tick()
  local starts = {}
  local tasks = {}
  local run = runWith(service(starts, true), tasks)
  Assert.equal(Runtime.executeNode({ op = "follower_transition" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(#starts, 1, "the command starts exactly one transient effect")
  Assert.equal(#tasks, 0, "the command creates no wait task")
  Assert.isNil(run.blockTaskId, "the command parks no blocking task")
end

function T.transition_without_a_partner_is_a_same_tick_no_op()
  local starts = {}
  local tasks = {}
  local run = runWith(service(starts, false), tasks)
  Assert.equal(Runtime.executeNode({ op = "follower_transition" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(#starts, 1, "the service still observes the start attempt")
  Assert.equal(#tasks, 0, "an absent partner creates no wait task either")
  Assert.isNil(run.blockTaskId, "an absent partner parks no blocking task")
end

function T.transition_without_an_eligible_party_never_reaches_the_effect_service()
  local starts = {}
  local tasks = {}
  local run = runWith(service(starts, true), tasks, false)
  Assert.equal(Runtime.executeNode({ op = "follower_transition" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(#starts, 0, "an ineligible party starts no effect")
  Assert.equal(#tasks, 0, "an ineligible party creates no wait task either")
  Assert.isNil(run.blockTaskId, "an ineligible party parks no blocking task")
end

function T.missing_transition_service_faults_loudly()
  local run = runWith(nil, {})
  local err = Assert.throws(function()
    Runtime.executeNode({ op = "follower_transition" }, run)
  end)
  Assert.isTrue(Errors.is(err), "a missing transition service is an attributed fault")
end

function T.missing_follower_collaborator_faults_loudly()
  local run = {
    instance = { scriptId = "test.follower-transition", locals = {}, textArgs = {} },
    services = {},
    semantics = RuntimeValues,
  }
  local err = Assert.throws(function()
    Runtime.executeNode({ op = "follower_transition" }, run)
  end)
  Assert.isTrue(Errors.is(err), "a missing follower collaborator is an attributed fault, never inactive")
end

return { tests = T }
