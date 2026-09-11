-- The script executor consumes game meaning through a small injected
-- evaluator. This test deliberately supplies synthetic semantics so the core
-- runtime can execute without constructing an HGSS field.

local Assert = require("tests.support.Assert")
local Runtime = require("libs.script.src.Runtime")
local Registry = require("libs.script.src.Registry")
local Composition = require("libs.script.src.Composition")
local TaskRegistry = require("libs.script.src.TaskRegistry")
local Scheduler = require("libs.script.src.Scheduler")
local ScriptEnvironment = require("libs.script.src.ScriptEnvironment")
local FakeServices = require("tests.support.script.FakeServices")

local T = {
  tests = {},
}

-- A recording player-side avatar service with set-union pending membership,
-- mirroring the transition-owner contract without importing game meaning.
local function recordingAvatar()
  local pending = {}
  local avatar = { queued = {}, applied = 0, pending = pending }
  function avatar:queueAvatarTransition(name)
    assert(type(name) == "string", "queued transitions are opaque names")
    self.queued[#self.queued + 1] = name
    pending[name] = true
  end
  function avatar:applyAvatarTransitions()
    self.applied = self.applied + 1
    for name in pairs(pending) do
      pending[name] = nil
    end
  end
  return avatar
end

local function avatarHarness()
  local services = FakeServices.new()
  local avatar = recordingAvatar()
  services.player = avatar --[[@as FakePlayer]]
  local played = {}
  services.audio = {
    play = function(_, sound)
      played[#played + 1] = { sound = sound, applied = avatar.applied }
    end,
  }
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local scheduler = Scheduler.new({
    semantics = require("libs.hgss.src.script.RuntimeValues"),
    services = services,
    taskRegistry = TaskRegistry.new(),
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  return {
    services = services,
    avatar = avatar,
    played = played,
    registry = registry,
    composition = composition,
    scheduler = scheduler,
  }
end

local function installSlice(h, id, steps)
  h.registry:installBase(id, { kind = "field_script", api = 1, id = id, steps = steps }, "generated")
  return assert(h.composition:effective(id))
end

function T.tests.avatar_transition_queue_yields_before_apply()
  local h = avatarHarness()
  local composed = installSlice(h, "test.avatar_slice", {
    { op = "queue_avatar_transition", transition = "heal" },
    { op = "yield_tick" },
    { op = "apply_avatar_transitions" },
    { op = "play_sound", sound = "SEQ_SLICE_MARK" },
  })
  h.scheduler:createForeground(composed, nil, 100)
  h.scheduler:step(100, nil)
  -- The first tick queues the transition and stops at the yield: nothing is
  -- applied and the following marker stays silent while the script survives.
  Assert.deepEqual(h.avatar.queued, { "heal" })
  Assert.equal(h.avatar.applied, 0)
  Assert.equal(#h.played, 0)
  Assert.notNil(h.scheduler:foregroundEnvironmentId())
  h.scheduler:step(101, nil)
  -- The next tick applies and then runs the following operation in the same
  -- tick before the script completes.
  Assert.equal(h.avatar.applied, 1)
  Assert.equal(#h.played, 1)
  Assert.equal(h.played[1].sound, "SEQ_SLICE_MARK")
  Assert.equal(h.played[1].applied, 1, "the marker must run after the apply in the same tick")
  Assert.isNil(h.scheduler:foregroundEnvironmentId())
end

function T.tests.consecutive_avatar_bit_sets_yield_separately_and_accumulate()
  local h = avatarHarness()
  local composed = installSlice(h, "test.avatar_double_slice", {
    { op = "queue_avatar_transition", transition = "cycling" },
    { op = "yield_tick" },
    { op = "queue_avatar_transition", transition = "surfing" },
    { op = "yield_tick" },
    { op = "apply_avatar_transitions" },
    { op = "play_sound", sound = "SEQ_SLICE_MARK" },
  })
  h.scheduler:createForeground(composed, nil, 200)
  h.scheduler:step(200, nil)
  Assert.deepEqual(h.avatar.queued, { "cycling" })
  Assert.equal(h.avatar.applied, 0)
  Assert.isTrue(h.avatar.pending.cycling)
  Assert.equal(#h.played, 0)
  h.scheduler:step(201, nil)
  -- The second set yields on its own tick without applying the first.
  Assert.deepEqual(h.avatar.queued, { "cycling", "surfing" })
  Assert.equal(h.avatar.applied, 0)
  Assert.isTrue(h.avatar.pending.cycling and h.avatar.pending.surfing)
  Assert.equal(#h.played, 0)
  h.scheduler:step(202, nil)
  -- One apply consumes the accumulated set and the marker follows same-tick.
  Assert.equal(h.avatar.applied, 1)
  Assert.isNil(next(h.avatar.pending))
  Assert.equal(#h.played, 1)
  Assert.equal(h.played[1].applied, 1)
  Assert.isNil(h.scheduler:foregroundEnvironmentId())
end

function T.tests.core_runtime_uses_injected_semantics()
  local vars = {}
  local frame = { nodeId = "entry", args = {} }
  local instance = {
    scriptId = "test.synthetic",
    instanceId = "instance-1",
    mode = "foreground",
    locals = {},
    textArgs = {},
    topFrame = function()
      return frame
    end,
  }
  local world = {
    getVar = function(_, id)
      return vars[id] or 0
    end,
    setVar = function(_, id, value)
      vars[id] = value
    end,
    isFlagSet = function()
      return false
    end,
  }
  local semantics = {}
  function semantics.evaluateValue(value)
    if type(value) == "table" and value.value == "var" then
      return vars[value.id] or 0
    end
    return value
  end
  function semantics.resolveIdOperand(value)
    return type(value) == "table" and value.value == "var" and value.id or value
  end
  function semantics.evaluateCondition(condition)
    return semantics.evaluateValue(condition.left) == semantics.evaluateValue(condition.right)
  end
  function semantics.writeRef(ref, value)
    instance.locals[ref.name] = value
  end

  local run = {
    instance = instance,
    environment = {
      acquireLock = function() end,
      releaseLock = function() end,
    },
    services = { world = world },
    semantics = semantics,
  }

  Assert.equal(
    Runtime.executeNode({
      op = "set_var",
      variable = { value = "var", id = "counter" },
      value = 7,
    }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(vars.counter, 7)

  local branch = {
    op = "if",
    condition = {
      condition = "compare",
      left = { value = "var", id = "counter" },
      right = 7,
      operator = "eq",
    },
    yes = "matched",
    no = "missed",
  }
  Assert.equal(Runtime.executeNode(branch, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(frame.nodeId, "matched")
end

function T.tests.signal_caller_clears_signal_and_continues()
  local environment = ScriptEnvironment.new({
    environmentId = "environment-1",
    mode = "foreground",
    createdAtTick = 0,
  })
  environment:setCallerSignal(0, true)

  local outcome = Runtime.executeNode({ op = "signal_caller" }, {
    instance = { scriptId = "test.common", contextSlot = 1 },
    environment = environment,
    services = {},
    semantics = {},
  })

  Assert.equal(outcome, Runtime.OUTCOME_CONTINUE)
  Assert.isFalse(environment:callerSignal(0))
end

local function directRun(mode, player)
  return {
    instance = { scriptId = "test.direct", instanceId = "direct-1", mode = mode, locals = {}, textArgs = {} },
    services = { player = player },
    semantics = {},
  }
end

function T.tests.avatar_queue_applies_continue_outcome()
  local avatar = recordingAvatar()
  local run = directRun("foreground", avatar)
  Assert.equal(
    Runtime.executeNode({ op = "queue_avatar_transition", transition = "heal" }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.deepEqual(avatar.queued, { "heal" })
  Assert.equal(Runtime.executeNode({ op = "apply_avatar_transitions" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(avatar.applied, 1)
  -- An empty apply is a same-tick no-op, never a yield or a fault.
  Assert.equal(Runtime.executeNode({ op = "apply_avatar_transitions" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(avatar.applied, 2)
end

function T.tests.avatar_queue_in_background_fails_before_player_mutation()
  local avatar = recordingAvatar()
  local queueErr = Assert.throws(function()
    Runtime.executeNode({ op = "queue_avatar_transition", transition = "heal" }, directRun("background", avatar))
  end)
  Assert.equal(queueErr.code, "SCRIPT_BACKGROUND_FORBIDDEN")
  Assert.equal(#avatar.queued, 0, "a background queue must fail before the facade mutates")
  Assert.isNil(next(avatar.pending))
  local applyErr = Assert.throws(function()
    Runtime.executeNode({ op = "apply_avatar_transitions" }, directRun("background", avatar))
  end)
  Assert.equal(applyErr.code, "SCRIPT_BACKGROUND_FORBIDDEN")
  Assert.equal(avatar.applied, 0)
end

function T.tests.avatar_operations_without_player_service_fail()
  local queueErr = Assert.throws(function()
    Runtime.executeNode({ op = "queue_avatar_transition", transition = "heal" }, directRun("foreground", nil))
  end)
  Assert.equal(queueErr.code, "SCRIPT_SERVICE_MISSING")
  local applyErr = Assert.throws(function()
    Runtime.executeNode({ op = "apply_avatar_transitions" }, directRun("foreground", nil))
  end)
  Assert.equal(applyErr.code, "SCRIPT_SERVICE_MISSING")
end

function T.tests.avatar_operations_are_internal_generated_carriers()
  local Validator = require("libs.script.src.Validator")
  local Schema = require("libs.script.src.Schema")
  local S = require("gen4.script")
  local ok, validateErr = Validator.validate({
    kind = "field_script",
    api = 1,
    id = "test.avatar_shape",
    steps = {
      { op = "queue_avatar_transition", transition = "heal" },
      { op = "apply_avatar_transitions" },
    },
  })
  Assert.isTrue(ok, "internal avatar carriers must validate: " .. tostring(validateErr))
  local missing, _ = Validator.validate({
    kind = "field_script",
    api = 1,
    id = "test.avatar_bad",
    steps = { { op = "queue_avatar_transition" } },
  })
  Assert.isNil(missing, "a queue without its transition name must not validate")
  Assert.isNil(Schema.ENUMS.avatar_transition, "generic schema must not learn transition vocabulary")
  Assert.isNil(S.queueAvatarTransition, "avatar queue must stay a generated-only carrier")
  Assert.isNil(S.applyAvatarTransitions, "avatar apply must stay a generated-only carrier")
  for _, group in ipairs(Schema.CONSTRUCTORS) do
    for _, row in ipairs(group.rows) do
      Assert.isTrue(
        row.signature:find("vatar") == nil,
        "no public constructor may expose avatar carriers: " .. row.signature
      )
    end
  end
end

return T
