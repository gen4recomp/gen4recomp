-- Selected-session drive behavior without worker threads or a ROM: fake
-- channels, session, pool, and timer prove the controller waits on its
-- control channel when settled, polls on the live cadence while worker
-- results are outstanding, and pumps immediately runnable planning.

local Assert = require("tests.support.Assert")
local CacheControllerWorker = require("romdump.src.build.CacheControllerWorker")

local T = {}

local LIVE_CADENCE_SECONDS = 0.005

local function recordingTimer()
  local timer = { sleeps = {} }
  function timer.sleep(first, second)
    local seconds = second == nil and first or second
    timer.sleeps[#timer.sleeps + 1] = seconds
  end
  return timer
end

---@param options { runnable: boolean, poolState: string, wakeDelay: number?, queued: table[]?, demandCommand: table? }
---@return table worker fake-channel controller under test
---@return table session fake selected session
---@return table pool fake compiler pool
---@return table timer recording sleep timer
---@return table log channel/session call log
local function driveSetup(options)
  local log = {
    pops = 0,
    demands = 0,
    replies = {},
    pumpsBeforeDemand = nil,
    queued = options.queued or {},
    demandCommand = options.demandCommand,
  }
  local session = { pumps = 0, runnable = options.runnable, wakeDelay = options.wakeDelay }
  function session.hasRunnablePlanning()
    return session.runnable
  end
  function session.nextPlanningWakeDelay()
    return session.wakeDelay
  end
  function session.update()
    session.pumps = session.pumps + 1
  end
  local pool = { state = options.poolState, updates = 0 }
  function pool.activityState()
    return pool.state
  end
  function pool.update()
    pool.updates = pool.updates + 1
  end
  local control = {}
  function control.pop()
    log.pops = log.pops + 1
    if #log.queued > 0 then
      return table.remove(log.queued, 1)
    end
    return nil
  end
  function control.demand()
    log.demands = log.demands + 1
    log.pumpsBeforeDemand = session.pumps
    return assert(log.demandCommand, "the blocking wait must answer a command")
  end
  local reply = {}
  function reply:push(message)
    log.replies[#log.replies + 1] = message
  end
  local worker = CacheControllerWorker.Worker.new(control, reply)
  worker.session = session
  worker.pool = pool
  return worker, session, pool, recordingTimer(), log
end

-- A settled selected session performs no timed polling and no session
-- update while waiting: one drive blocks on the control channel, handles
-- the command, and only then pumps once.
function T.settled_selected_session_blocks_for_the_next_command()
  local worker, session, _, timer, log = driveSetup({
    runnable = false,
    poolState = "idle",
    demandCommand = { op = "unknown-drive-probe" },
  })
  worker:driveOnce(timer)
  Assert.equal(log.demands, 1, "the settled controller blocks on its control channel")
  Assert.equal(#timer.sleeps, 0, "the settled controller performs no timed sleep")
  Assert.equal(log.pumpsBeforeDemand, 0, "no session pump precedes the blocking wait")
  Assert.equal(session.pumps, 1, "the post-command step pumps the session exactly once")
end

-- A worker-dependent wait keeps the bounded live cadence: exactly one
-- short sleep followed by exactly one pump, with no control block.
function T.worker_dependent_wait_polls_once_with_the_live_cadence()
  local worker, session, _, timer, log = driveSetup({ runnable = false, poolState = "waiting" })
  worker:driveOnce(timer)
  Assert.equal(#timer.sleeps, 1, "a worker wait sleeps exactly once before polling")
  Assert.equal(timer.sleeps[1], LIVE_CADENCE_SECONDS, "the wait keeps the live poll cadence")
  Assert.equal(session.pumps, 1, "the wait polls the session exactly once")
  Assert.equal(log.demands, 0, "a worker wait never blocks on the control channel")
end

-- Immediately runnable local planning pumps without sleeping or
-- blocking, even though no command is available.
function T.runnable_local_planning_pumps_without_sleeping()
  local worker, session, _, timer, log = driveSetup({ runnable = true, poolState = "idle" })
  worker:driveOnce(timer)
  Assert.equal(session.pumps, 1, "runnable planning steps immediately")
  Assert.equal(#timer.sleeps, 0, "runnable planning waits for no sleep")
  Assert.equal(log.demands, 0, "runnable planning waits for no command")
end

-- An already-queued command outranks any wait decision: it is handled
-- first and the session pumps immediately with no sleep or demand.
function T.queued_command_handles_before_any_wait_decision()
  local worker, session, _, timer, log = driveSetup({
    runnable = false,
    poolState = "waiting",
    queued = { { op = "unknown-drive-probe" } },
  })
  worker:driveOnce(timer)
  Assert.isTrue(log.pops >= 1, "the drive consults queued commands first")
  Assert.equal(session.pumps, 1, "the command path pumps the session immediately")
  Assert.equal(#timer.sleeps, 0, "a queued command waits for no sleep")
  Assert.equal(log.demands, 0, "a queued command waits for no demand")
end

-- A session clock wait sleeps on the live cadence instead of spinning:
-- exactly one bounded sleep and one pump, with no control-channel block.
function T.timed_planning_wait_sleeps_once_then_pumps()
  local worker, session, _, timer, log = driveSetup({
    runnable = false,
    poolState = "idle",
    wakeDelay = 0.5,
    demandCommand = { op = "unknown-drive-probe" },
  })
  worker:driveOnce(timer)
  Assert.equal(#timer.sleeps, 1, "a timed wait sleeps exactly once before pumping")
  Assert.isTrue(timer.sleeps[1] <= LIVE_CADENCE_SECONDS, "a timed wait never exceeds the live cadence")
  Assert.equal(session.pumps, 1, "a timed wait pumps the session exactly once")
  Assert.equal(log.demands, 0, "a timed wait never blocks on the control channel")
end

-- An expired clock wait pumps immediately: no sleep is owed when the
-- deadline is already due.
function T.expired_timed_wait_pumps_without_sleeping()
  local worker, session, _, timer, log = driveSetup({
    runnable = false,
    poolState = "idle",
    wakeDelay = 0,
    demandCommand = { op = "unknown-drive-probe" },
  })
  worker:driveOnce(timer)
  Assert.equal(session.pumps, 1, "an expired wait pumps the session exactly once")
  Assert.equal(#timer.sleeps, 0, "an expired wait sleeps for no cadence")
  Assert.equal(log.demands, 0, "an expired wait never blocks on the control channel")
end

-- Pool worker waiting outranks a session clock wait: the drive keeps the
-- live poll cadence instead of the shorter clock remainder.
function T.pool_waiting_outranks_a_shorter_session_clock_wait()
  local worker, session, _, timer, log = driveSetup({
    runnable = false,
    poolState = "waiting",
    wakeDelay = 0.002,
    demandCommand = { op = "unknown-drive-probe" },
  })
  worker:driveOnce(timer)
  Assert.equal(#timer.sleeps, 1, "the pool wait sleeps exactly once before polling")
  Assert.equal(timer.sleeps[1], LIVE_CADENCE_SECONDS, "the pool wait keeps the live poll cadence")
  Assert.equal(session.pumps, 1, "the wait polls the session exactly once")
  Assert.equal(log.demands, 0, "the wait never blocks on the control channel")
end

-- An already-queued command outranks a session clock wait: no sleep is
-- owed when a command is ready.
function T.queued_command_outranks_a_session_clock_wait()
  local worker, session, _, timer, log = driveSetup({
    runnable = false,
    poolState = "idle",
    wakeDelay = 0.5,
    queued = { { op = "unknown-drive-probe" } },
  })
  worker:driveOnce(timer)
  Assert.isTrue(log.pops >= 1, "the drive consults queued commands first")
  Assert.equal(session.pumps, 1, "the command path pumps the session immediately")
  Assert.equal(#timer.sleeps, 0, "a queued command waits for no sleep")
  Assert.equal(log.demands, 0, "a queued command waits for no demand")
end

-- Terminal request/barrier/failure facts are pushed over the existing reply
-- channel: fake control/reply channels plus a fake selected session prove the
-- controller emits each terminal event without any status probe round-trip.
local function pushChannels()
  local queued = {}
  local control = {}
  function control.pop()
    if #queued == 0 then
      return nil
    end
    return table.remove(queued, 1)
  end
  function control.demand()
    return table.remove(queued, 1)
  end
  local replies = {}
  local reply = {}
  function reply:push(message)
    replies[#replies + 1] = message
  end
  return control, reply, replies, queued
end

local function terminalSession(outcomes)
  local session = { pumps = 0, milestoneCalls = 0, ready = true }
  if outcomes ~= nil and outcomes.ready ~= nil then
    session.ready = outcomes.ready
  end
  function session.update()
    session.pumps = session.pumps + 1
  end
  function session.requestMilestone(_, _)
    session.milestoneCalls = session.milestoneCalls + 1
    if session.ready then
      return true, nil
    end
    return false, nil
  end
  function session.milestoneStatus(_)
    return { ready = 1, total = 1 }
  end
  function session.requestField(_, _)
    return true, nil
  end
  function session.requestLogicalField(_, _)
    return true, nil
  end
  function session.requestCell(_, _)
    return true, nil
  end
  function session.requestMonPortraitPage(_, _)
    return true, nil
  end
  function session.requestIconPage(_, _)
    return true, nil
  end
  function session.hasRunnablePlanning()
    return false
  end
  function session.nextPlanningWakeDelay()
    return nil
  end
  return session
end

local function pushWorker(session, epoch)
  local control, reply, replies, queued = pushChannels()
  local worker = CacheControllerWorker.Worker.new(control, reply)
  worker.session = session
  worker.pool = nil
  worker.liveEpoch = epoch
  worker.lifecycle = "active"
  return worker, replies, queued
end

local function packetsOf(replies, op)
  local found = {}
  for _, packet in ipairs(replies) do
    if type(packet) == "table" and packet.op == op then
      found[#found + 1] = packet
    end
  end
  return found
end

-- An immediately settled external request emits one terminal event during
-- request handling: no status probe is required for progress.
function T.request_outcome_is_pushed_without_a_status_probe()
  local worker, replies, queued = pushWorker(terminalSession(), 7)
  queued[#queued + 1] =
    { op = "request", epoch = 7, requestId = 11, requestKind = "milestone", name = "bootstrap", urgency = "required" }
  worker:step()
  local results = packetsOf(replies, "request-result")
  Assert.equal(#results, 1, "an immediately ready request emits one terminal event without a status probe")
  Assert.equal(results[1].requestId, 11, "the terminal event carries the request identity")
  Assert.equal(results[1].state, "ready", "the terminal event carries the ready state")
  Assert.equal(results[1].epoch, 7, "the terminal event carries the epoch identity")
  queued[#queued + 1] = { op = "poll", epoch = 7, roundId = 3, count = 1, id1 = 11 }
  worker:step()
  Assert.equal(#packetsOf(replies, "poll-result"), 0, "no status probe is answered")
end

-- A request that settles after session progress emits exactly one terminal
-- event on the settling pump and never duplicates it on later pumps.
function T.delayed_readiness_emits_exactly_one_terminal_event()
  local session = terminalSession({ ready = false })
  local worker, replies, queued = pushWorker(session, 7)
  queued[#queued + 1] =
    { op = "request", epoch = 7, requestId = 12, requestKind = "milestone", name = "bootstrap", urgency = "required" }
  worker:step()
  Assert.equal(#packetsOf(replies, "request-result"), 0, "a pending request emits no terminal event yet")
  session.ready = true
  worker:step()
  local results = packetsOf(replies, "request-result")
  Assert.equal(#results, 1, "settling progress emits one terminal event")
  Assert.equal(results[1].requestId, 12, "the terminal event carries the request identity")
  Assert.equal(results[1].state, "ready", "the terminal event carries the ready state")
  worker:step()
  Assert.equal(#packetsOf(replies, "request-result"), 1, "later pumps never duplicate the terminal event")
end

-- Retirement and quiescence each push their own exact barrier event at the
-- existing completion point instead of waiting for a status round-trip.
function T.retirement_and_quiescence_push_exact_barrier_events()
  local worker, replies, queued = pushWorker(terminalSession(), 9)
  queued[#queued + 1] = { op = "retire", epoch = 9, barrierId = 4 }
  worker:step()
  local retired = packetsOf(replies, "barrier-result")
  Assert.equal(#retired, 1, "retirement pushes one barrier event")
  Assert.equal(retired[1].epoch, 9, "the retirement event carries the epoch identity")
  Assert.equal(retired[1].barrierId, 4, "the retirement event carries the barrier identity")
  Assert.equal(retired[1].kind, "retire", "the retirement event carries its kind")
  queued[#queued + 1] = { op = "quiesce", epoch = 9, barrierId = 5 }
  worker:step()
  local settled = packetsOf(replies, "barrier-result")
  Assert.equal(#settled, 2, "quiescence pushes its own barrier event")
  Assert.equal(settled[2].epoch, 9, "the quiescence event carries the epoch identity")
  Assert.equal(settled[2].barrierId, 5, "the quiescence event carries the barrier identity")
  Assert.equal(settled[2].kind, "quiesce", "the quiescence event carries its kind")
end

-- A lifecycle failure pushes one terminal fact with the first cause; later
-- failures never spam the channel or replace the primary cause.
function T.lifecycle_failure_pushes_one_terminal_event()
  local worker, replies, queued = pushWorker(terminalSession(), 11)
  queued[#queued + 1] = { op = "select", epoch = 11 }
  worker:step()
  local failures = packetsOf(replies, "controller-failure")
  Assert.equal(#failures, 1, "the first lifecycle failure pushes one terminal event")
  Assert.isTrue(tostring(failures[1].errorMessage) ~= "", "the terminal failure carries its cause")
  queued[#queued + 1] = { op = "select", epoch = 12 }
  worker:step()
  Assert.equal(#packetsOf(replies, "controller-failure"), 1, "later failures never spam the channel")
end

-- A fully idle session with no clock wait still blocks for the next
-- command instead of polling.
function T.idle_session_without_a_timed_wait_blocks_for_the_next_command()
  local worker, session, _, timer, log = driveSetup({
    runnable = false,
    poolState = "idle",
    wakeDelay = nil,
    demandCommand = { op = "unknown-drive-probe" },
  })
  worker:driveOnce(timer)
  Assert.equal(log.demands, 1, "an idle controller blocks on its control channel")
  Assert.equal(#timer.sleeps, 0, "an idle controller performs no timed sleep")
  Assert.equal(session.pumps, 1, "the post-command step pumps the session exactly once")
end

return { metadata = { capabilities = {} }, tests = T }
