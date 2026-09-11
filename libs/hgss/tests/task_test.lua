-- Dialogue and input task tests : the hgss
-- dialogue timing profile (print wait -> one-tick defer -> input wait ->
-- one-tick close defer), input-edge semantics (never held state, never the
-- triggering edge), d-pad turn behavior, gendered message selection, message
-- bindings, yes/no selection timing, and dialogue save/resume. The exit
-- criterion: New Bark woman and lab sign dialogue execute end-to-end.

local Assert = require("tests.support.Assert")
local S = require("gen4.script")
local Registry = require("libs.script.src.Registry")
local Composition = require("libs.script.src.Composition")
local TaskRegistry = require("libs.script.src.TaskRegistry")
local Scheduler = require("libs.script.src.Scheduler")
local ScriptSave = require("libs.script.src.ScriptSave")
local WaitTicksTask = require("libs.script.src.tasks.WaitTicksTask")
local WaitInputTask = require("libs.hgss.src.script.tasks.WaitInputTask")
local WaitInputOrTicksTask = require("libs.hgss.src.script.tasks.WaitInputOrTicksTask")
local DialogueTask = require("libs.hgss.src.script.tasks.DialogueTask")
local AskYesNoTask = require("libs.hgss.src.script.tasks.AskYesNoTask")
---@cast WaitTicksTask TaskImplementation
---@cast WaitInputTask TaskImplementation
---@cast WaitInputOrTicksTask TaskImplementation
---@cast DialogueTask TaskImplementation
---@cast AskYesNoTask TaskImplementation
local FakeServices = require("tests.support.script.FakeServices")
local FakeDialogueHost = require("tests.support.script.FakeDialogueHost")
local Diagnostics = require("libs.script.src.Diagnostics")

local T = {}

---@class DialogueHarness
---@field services FakeServices
---@field host FakeDialogueHost
---@field registry Registry
---@field composition Composition
---@field taskRegistry TaskRegistry
---@field scheduler Scheduler
---@field trace Diagnostics.TraceRecorder

---@param opts table|nil
---@return DialogueHarness
local function harness(opts)
  opts = opts or {}
  local services = FakeServices.new(opts)
  local host = FakeDialogueHost.new({
    printTicks = opts.printTicks or 2,
    player = services.player,
  })
  services.dialogue = host
  services.advanceAsync = function()
    host:advance()
  end
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local taskRegistry = TaskRegistry.new()
  taskRegistry:register("wait_ticks", 1, WaitTicksTask)
  taskRegistry:register("wait_input", 1, WaitInputTask)
  taskRegistry:register("wait_input_or_ticks", 1, WaitInputOrTicksTask)
  taskRegistry:register("dialogue", DialogueTask.version, DialogueTask)
  taskRegistry:register("ask_yes_no", 1, AskYesNoTask)
  local recorder = Diagnostics.newTraceRecorder()
  local scheduler = Scheduler.new({
    semantics = require("libs.hgss.src.script.RuntimeValues"),
    services = services,
    taskRegistry = taskRegistry,
    trace = function(record)
      recorder:record(record)
    end,
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  return {
    services = services,
    host = host,
    registry = registry,
    composition = composition,
    taskRegistry = taskRegistry,
    scheduler = scheduler,
    trace = recorder,
  }
end

---@param h DialogueHarness
---@param resource table
---@param tick integer
---@return string instanceId
local function startForeground(h, resource, tick)
  if h.registry:base(resource.id) == nil then
    h.registry:installBase(resource.id, resource, "generated")
  end
  local composed = assert(h.composition:effective(resource.id))
  return h.scheduler:createForeground(composed, nil, tick)
end

local function script(id, stepsOrSpec)
  if type(stepsOrSpec) == "table" and stepsOrSpec.steps ~= nil then
    stepsOrSpec.api = 1
    stepsOrSpec.id = id
    return S.script(stepsOrSpec)
  end
  return S.script({ api = 1, id = id, steps = stepsOrSpec })
end

-- 1. The hgss say timeline with a 2-tick print: the input edge that could
-- have triggered the interaction can never advance the message;
-- the input wait reads only later edges.
T["say hgss timeline"] = function()
  local h = harness({ printTicks = 2 })
  startForeground(
    h,
    script("new_bark.lab_sign", {
      S.say({ message = "msg.hgss.0543.00097" }),
      S.setVar({ variable = "VAR_AFTER", value = 1 }),
      S.stop(),
    }),
    100
  )
  -- T: print started (openMessage + startPrint), context blocked.
  h.scheduler:step(100, { pressedAction = true })
  Assert.isTrue(h.host:isOpen())
  Assert.equal(h.host.calls[1].name, "openMessage")
  Assert.equal(h.host.calls[2].name, "startPrint")
  Assert.equal(h.host.calls[2].args[1], "msg.hgss.0543.00097")
  -- The trigger tick's edge is consumed by the snapshot and cannot advance
  -- the message created by the same interaction.
  h.scheduler:step(101, { pressedAction = true })
  h.scheduler:step(102, { pressedAction = true })
  -- T+3: input armed; the armed wait reads only newly pressed edges, and
  -- 101/102 edges were consumed by their snapshots.
  h.scheduler:step(103, { pressedAction = true })
  -- T+4: an edge advances the wait; the close defers one tick.
  h.scheduler:step(104, { pressedAction = true })
  Assert.isTrue(h.host:isOpen(), "the close defers one tick after the edge")
  -- T+5: the message closes this tick.
  h.scheduler:step(105, {})
  Assert.isFalse(h.host:isOpen())
  -- T+6: graph continuation.
  h.scheduler:step(106, {})
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 2. A held action never satisfies the wait: only edges count.
T["input waits read edges only"] = function()
  local h = harness({ printTicks = 1 })
  startForeground(
    h,
    script("test.held", {
      S.say({ message = "msg.test" }),
      S.setVar({ variable = "VAR_AFTER", value = 1 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, {})
  -- Print completes at T+1 (1 tick); arm at T+2; held action at T+3 must not
  -- advance; an edge at T+4 advances; close at T+5; continuation at T+6.
  h.scheduler:step(101, {})
  h.scheduler:step(102, {})
  h.scheduler:step(103, { actionDown = true })
  Assert.isTrue(h.host:isOpen(), "held state must not advance the message")
  h.scheduler:step(104, { pressedAction = true })
  h.scheduler:step(105, {})
  Assert.isFalse(h.host:isOpen())
  h.scheduler:step(106, {})
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 3. The interaction-triggering edge cannot satisfy a wait created by the
-- same trigger.
T["trigger edge cannot satisfy its own wait"] = function()
  local h = harness({ printTicks = 1 })
  local resource = script("new_bark.npc.woman_1", {
    S.say({ message = "msg.hgss.0542.00009" }),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  h.registry:installBase(resource.id, resource, "generated")
  local trigger = { kind = "object", mapId = 57, scriptId = resource.id }
  h.services.foreground = {
    resolve = function(input)
      if input and input.pressedAction then
        return { trigger = trigger, composed = h.composition:effective(resource.id) }
      end
      return nil
    end,
  }
  -- The trigger edge at 200 starts the interaction and the say task.
  h.scheduler:step(200, { pressedAction = true })
  h.scheduler:step(201, {})
  h.scheduler:step(202, {})
  -- The trigger tick's edge was consumed by the snapshot at 200; the armed
  -- wait at 202 sees no edge and the message stays open.
  h.scheduler:step(203, {})
  Assert.isTrue(h.host:isOpen())
  h.scheduler:step(204, { pressedAction = true })
  h.scheduler:step(205, {})
  Assert.isFalse(h.host:isOpen())
  h.scheduler:step(206, {})
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 4. waitInput primitive: buttons and d-pad options, plus the d-pad turn
-- behavior.
T["waitInput buttons and dpad"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.input", {
      S.waitInput({ buttons = { "a" }, allowDpad = true, turnPlayerOnDpad = true }),
      S.setVar({ variable = "VAR_AFTER", value = 1 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, {})
  h.scheduler:step(101, { pressedDirection = "east" })
  Assert.equal(h.services.player._facing, "east", "d-pad edge turns the player")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0)
  h.scheduler:step(102, {})
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 5. waitInput without d-pad ignores direction edges.
T["waitInput ignores dpad when disabled"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.input2", {
      S.waitInput({ buttons = { "a", "b" }, allowDpad = false }),
      S.setVar({ variable = "VAR_AFTER", value = 1 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, {})
  h.scheduler:step(101, { pressedDirection = "north" })
  h.scheduler:step(102, { pressedDirection = "north" })
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0)
  h.scheduler:step(103, { pressedCancel = true })
  h.scheduler:step(104, {})
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 6. waitInputOrTicks: first completion wins (ticks path).
T["waitInputOrTicks ticks path"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.or", {
      S.waitInputOrTicks({ ticks = 2, buttons = { "a" } }),
      S.setVar({ variable = "VAR_AFTER", value = 1 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, {})
  h.scheduler:step(101, {})
  h.scheduler:step(102, {}) -- ticks complete on the second poll
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0)
  h.scheduler:step(103, {})
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 7. Gendered messages resolve at creation from the player's gender.
T["gendered message selection"] = function()
  local h = harness({ printTicks = 1 })
  startForeground(
    h,
    script("test.gender", {
      S.say({ message = S.gendered("msg.male", "msg.female") }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, {})
  Assert.equal(h.host.calls[2].args[1], "msg.male", "gender 0 selects the male message")
  local h2 = harness({ printTicks = 1 })
  h2.services.player._gender = 1
  startForeground(
    h2,
    script("test.gender", {
      S.say({ message = S.gendered("msg.male", "msg.female") }),
      S.stop(),
    }),
    100
  )
  h2.scheduler:step(100, {})
  Assert.equal(h2.host.calls[2].args[1], "msg.female")
end

-- 8. askYesNo writes the canonical boolean result through the task result,
-- and a real script condition reads it (the branch is driven by the written
-- value, not by script-construction-time truthiness).
T["askYesNo result"] = function()
  local h = harness({ printTicks = 1 })
  startForeground(
    h,
    script("test.yesno", {
      locals = { accepted = "serializable" },
      steps = {
        S.say({ message = "msg.question" }),
        S.askYesNo({ message = "msg.choose", result = S.local_("accepted") }),
        S.if_({
          condition = S.truthy(S.local_("accepted")),
          yes = { S.setVar({ variable = "VAR_AFTER", value = 1 }) },
          no = { S.setVar({ variable = "VAR_AFTER", value = 0 }) },
        }),
        S.stop(),
      },
    }),
    100
  )
  -- Say phase (printTicks=1): 100 create, 101 print done -> defer, 102 armed,
  -- 103 edge -> close delay, 104 close, 105 continuation: ask_yes_no created.
  h.scheduler:step(100, {})
  h.scheduler:step(101, {})
  h.scheduler:step(102, {})
  h.scheduler:step(103, { pressedAction = true })
  h.scheduler:step(104, {})
  h.scheduler:step(105, {})
  -- Ask phase: 105 create (opening delay), 106 waiting, 107 selection edge,
  -- 108 completion -> resume_pending, 109 promote writes the result.
  h.scheduler:step(106, { pressedAction = true })
  Assert.isTrue(h.host:isOpen())
  h.scheduler:step(107, { pressedAction = true })
  h.scheduler:step(108, { pressedAction = true })
  h.scheduler:step(109, {})
  -- The canonical result was written into the local before completion and
  -- drove the following branch; the persistent var proves it.
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 9. Message bindings are passed through to the host at print time.
T["message bindings"] = function()
  local h = harness({ printTicks = 1 })
  startForeground(
    h,
    script("test.bind", {
      S.bufferText({ slot = 0, value = S.playerName() }),
      S.say({ message = "msg.greeting", bindings = { [0] = S.playerName() } }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, {})
  Assert.equal(h.host.calls[2].args[2][0].text, "player_name")
  Assert.equal(h.services.world:getVar("VAR_SCENE"), 0)
end

-- 10. Save/load during dialogue: the phase machine resumes with its delay
-- intact.
T["save during dialogue"] = function()
  local h = harness({ printTicks = 3 })
  local resource = script("test.savedial", {
    S.say({ message = "msg.test" }),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, {})
  h.scheduler:step(101, {})
  -- Capture during typing (printRemaining 1).
  local bucket = ScriptSave.capture(h.scheduler, 101, { registryFingerprint = h.registry:fingerprint() })
  local taskRecord = bucket.tasks[1]
  Assert.equal(taskRecord.taskType, "dialogue")
  Assert.equal(taskRecord.state.mode, "say")
  Assert.equal(taskRecord.state.phase, "typing")
  local recorder = Diagnostics.newTraceRecorder()
  local scheduler2 = Scheduler.new({
    semantics = require("libs.hgss.src.script.RuntimeValues"),
    services = h.services,
    taskRegistry = h.taskRegistry,
    trace = function(record)
      recorder:record(record)
    end,
    resolveComposition = function(id)
      return h.composition:effective(id)
    end,
  })
  ScriptSave.restore(bucket, scheduler2, 101, {})
  -- Continue the resumed timeline: print completes at 102, defer at 103,
  -- armed at 104, edge at 105, close at 106, continuation at 107.
  scheduler2:step(102, {})
  scheduler2:step(103, {})
  scheduler2:step(104, {})
  scheduler2:step(105, { pressedAction = true })
  scheduler2:step(106, {})
  scheduler2:step(107, {})
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 11. NonNPCMsg-style: message with waitForPrint=false starts the printer and
-- continues the same tick. Buffered text args (buffer_text) must ride
-- alongside, matching the blocking path.
T["nonblocking message continues same tick"] = function()
  local h = harness({ printTicks = 2 })
  startForeground(
    h,
    script("test.nonblock", {
      S.bufferText({ slot = 0, value = S.playerName() }),
      S.message({ message = "msg.system", waitForPrint = false }),
      S.setVar({ variable = "VAR_AFTER", value = 1 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, {})
  Assert.isTrue(h.host:isOpen())
  Assert.equal(h.host.calls[2].args[3][0].text, "player_name", "buffered text args reach the nonblocking printer")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1, "starting the printer is a same-tick operation")
end

-- 11b. Blocking say forwards buffered text args to the host (the fixed
-- DialogueTask path); the node itself carries no bindings, so only the
-- instance textArgs can satisfy the substitution.
T["blocking say forwards buffered text args"] = function()
  local h = harness({ printTicks = 2 })
  startForeground(
    h,
    script("test.sayargs", {
      S.bufferText({ slot = 0, value = S.playerName() }),
      S.say({ message = "msg.greeting" }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, {})
  Assert.equal(h.host.calls[2].args[3][0].text, "player_name")
end

-- 11c. Nonblocking message with no dialogue service faults the instance with
-- attribution instead of silently continuing.
T["nonblocking message without a dialogue service faults"] = function()
  local h = harness()
  h.services.dialogue = nil
  local instanceId = startForeground(
    h,
    script("test.nodialogue", {
      S.message({ message = "msg.system", waitForPrint = false }),
      S.setVar({ variable = "VAR_AFTER", value = 1 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, {})
  local fault = assert(h.services.events:eventFor("script.error", instanceId))
  Assert.equal(fault.code, "SCRIPT_SERVICE_MISSING")
  Assert.equal(assert(h.services.events:eventFor("script.ended", instanceId)).completed, false)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0, "the script must not continue past the missing service")
end

-- 12. open/close primitives drive the host directly.
T["open close primitives"] = function()
  local h = harness()
  startForeground(
    h,
    script("test.primitives", {
      S.openMessage(),
      S.closeMessage({ erase = true }),
      S.openMessage(),
      S.holdMessage(),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, {})
  local names = {}
  for _, call in ipairs(h.host.calls) do
    names[#names + 1] = call.name
  end
  Assert.deepEqual(names, { "openMessage", "close", "openMessage", "hold" })
end

-- 14. Blocking print-only message completes on print completion without
-- consuming input and without closing the box: the unfolded NPCMsg
-- primitive owns print completion only; the following wait_input owns input
-- and the parent close_message owns the close.
T["blocking message completes on print without input or close"] = function()
  local h = harness({ printTicks = 1 })
  startForeground(
    h,
    script("test.printonly", {
      S.message({ message = "msg.test", waitForPrint = true }),
      S.setVar({ variable = "VAR_AFTER", value = 1 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, {})
  Assert.isTrue(h.host:isOpen(), "the print-only message opens the box")
  -- Print completes at T+1 with zero input edges throughout: the task must
  -- complete and the graph must continue while the box stays open.
  h.scheduler:step(101, {})
  h.scheduler:step(102, {})
  Assert.isTrue(h.host:isOpen(), "a print-only message must not close the box")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1, "a print-only message must complete without input")
  for _, call in ipairs(h.host.calls) do
    Assert.isTrue(call.name ~= "close", "a print-only message must never close the host")
  end
end

-- 15. Consecutive print-only messages replace the window content: the
-- second print reuses the still-open box from the first without faulting,
-- and the box stays open for the following owners.
T["consecutive blocking messages replace the open box"] = function()
  local h = harness({ printTicks = 1 })
  local instanceId = startForeground(
    h,
    script("test.printchain", {
      S.message({ message = "msg.first", waitForPrint = true }),
      S.message({ message = "msg.second", waitForPrint = true }),
      S.setVar({ variable = "VAR_AFTER", value = 1 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, {})
  h.scheduler:step(101, {})
  h.scheduler:step(102, {})
  h.scheduler:step(103, {})
  h.scheduler:step(104, {})
  Assert.isTrue(h.host:isOpen(), "chained prints must leave the box open")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1, "chained prints must both complete without input")
  Assert.isNil(h.services.events:eventFor("script.error", instanceId), "reprinting into the open box must not fault")
  Assert.equal(h.host.calls[2].args[1], "msg.first")
  Assert.equal(h.host.calls[3].name, "close", "the chained print replaces the open box in the same tick")
  Assert.equal(h.host.calls[5].args[1], "msg.second")
end

-- 13. Cancelling an environment invokes the dialogue task's implementation
-- cancel: the engine-owned box is closed even though the task never reached
-- its close delay.
T["cancellation closes the open box"] = function()
  local h = harness({ printTicks = 5 })
  startForeground(
    h,
    script("test.cancelbox", {
      S.say({ message = "msg.question" }),
      S.setVar({ variable = "VAR_AFTER", value = 1 }),
      S.stop(),
    }),
    100
  )
  h.scheduler:step(100, {})
  h.scheduler:step(101, {})
  Assert.isTrue(h.host:isOpen(), "the box is open mid-print")
  local env = assert(h.scheduler:environments()[1])
  h.scheduler:cancelEnvironment(env.environmentId, "cancelled")
  Assert.isFalse(h.host:isOpen(), "the implementation cancel closed the engine-owned box")
  local closed = false
  for _, call in ipairs(h.host.calls) do
    if call.name == "close" then
      closed = true
    end
  end
  Assert.isTrue(closed, "the host received a close during cancellation")
end

return { tests = T }
