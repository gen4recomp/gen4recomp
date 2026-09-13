-- Lifecycle/state-machine coverage for the presentation preparation queue:
-- one-worker dispatch, demand-before-prefetch priority, cancellation of
-- queued and running work, failure recovery, and idempotent release. Every
-- test injects a deterministic fake love.thread (Thread/Channel mechanics)
-- so no real OS thread is started here; one focused real-worker test lives
-- in the graphics layer.

local Assert = require("tests.support.Assert")

local T = {}

local function requireQueue()
  local ok, AssetPreparationQueue = pcall(require, "libs.hgss.src.presentation.AssetPreparationQueue")
  Assert.isTrue(ok, "the production asset preparation queue boundary is missing: " .. tostring(AssetPreparationQueue))
  return AssetPreparationQueue --[[@as table]]
end

local function fakeCacheFs()
  return {
    resolve = function(_, relativePath)
      return "confined/" .. relativePath
    end,
    read = function()
      error("the queue must not read cache bytes on the main thread")
    end,
  }
end

-- A deterministic fake love.thread: newChannel/newThread record every push,
-- every construction source, and every start/wait call, but never execute
-- worker code. Tests drive "worker completion" explicitly by pushing a
-- response record and then calling a queue method that is documented to
-- drain replies (poll/wait); thread:stop(message) models an unexpected
-- worker exit whose cause is visible through getError.
local function fakeThreadHost()
  local state = { channels = {}, allPushes = {}, threads = {}, threadSources = {} }

  local function newChannel()
    local values = {}
    local channel = { onDemand = nil }
    function channel:push(value)
      values[#values + 1] = value
      state.allPushes[#state.allPushes + 1] = { channel = channel, value = value }
      return true
    end
    function channel:pop()
      if #values == 0 then
        return nil
      end
      return table.remove(values, 1)
    end
    -- Mirrors love.thread Channel:demand(timeout): an omitted timeout stays
    -- a nonblocking pop so existing tests run without delay, while a
    -- test-local onDemand hook can observe the timeout and model a blocking
    -- interval deterministically (for example worker death mid-wait).
    function channel:demand(timeout)
      if channel.onDemand ~= nil then
        return channel.onDemand(timeout)
      end
      return self:pop()
    end
    function channel:getCount()
      return #values
    end
    state.channels[#state.channels + 1] = channel
    return channel
  end

  local function newThread(source)
    state.threadSources[#state.threadSources + 1] = source
    local thread = { starts = 0, waits = 0, alive = true, errorText = nil, source = source, startArgs = {} }
    function thread:start(...)
      self.starts = self.starts + 1
      self.startArgs[#self.startArgs + 1] = { ... }
    end
    function thread:wait()
      self.waits = self.waits + 1
    end
    function thread:getError()
      return self.errorText
    end
    function thread:isRunning()
      return self.alive and self.starts > 0 and self.waits == 0
    end
    function thread:stop(message)
      self.alive = false
      self.errorText = message
    end
    state.threads[#state.threads + 1] = thread
    return thread
  end

  state.love = {
    thread = { newChannel = newChannel, newThread = newThread },
  }
  return state
end

local function withLove(fakeLove, fn)
  local previous = rawget(_G, "love")
  rawset(_G, "love", fakeLove)
  local ok, result = pcall(fn)
  rawset(_G, "love", previous)
  if not ok then
    error(result, 0)
  end
  return result
end

-- Finds the channel that carried the outgoing request record for `token`
-- (identified by the flat request shape: token + kind + path), without
-- assuming channel construction order.
local function requestChannelIndexFor(state, token)
  for _, entry in ipairs(state.allPushes) do
    local value = entry.value
    if type(value) == "table" and value.token == token and value.path ~= nil and value.kind ~= nil then
      for index, channel in ipairs(state.channels) do
        if channel == entry.channel then
          return index
        end
      end
    end
  end
  return nil
end

local function requestWasPushedFor(state, token)
  return requestChannelIndexFor(state, token) ~= nil
end

-- How many physical worker requests carried `token` (identified by the flat
-- request shape). Promotion must change a token's priority without
-- dispatching it a second time.
local function pushCountFor(state, token)
  local count = 0
  for _, entry in ipairs(state.allPushes) do
    local value = entry.value
    if type(value) == "table" and value.token == token and value.path ~= nil and value.kind ~= nil then
      count = count + 1
    end
  end
  return count
end

-- One request/reply Channel pair per queue: the response channel for a
-- known request channel index is the other member of the pair.
local function responseChannelFor(state, requestIndex)
  Assert.equal(#state.channels, 2, "one presentation worker owns exactly one request/reply Channel pair")
  for index, channel in ipairs(state.channels) do
    if index ~= requestIndex then
      return channel
    end
  end
  error("no response channel found")
end

local function meshResponse(token, path)
  return {
    token = token,
    ok = true,
    kind = "mesh",
    path = path,
    vertexData = { fake = "vertexData" },
    indexData = { fake = "indexData" },
    vertexCount = 3,
    indexCount = 3,
    indexType = "uint16",
    centerX = 0,
    centerY = 0,
    centerZ = 0,
  }
end

local function failureResponse(token, kind, path)
  return { token = token, ok = false, kind = kind, path = path, error = "injected worker failure" }
end

function T.one_time_take_and_unknown_token_fail_loudly()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = AssetPreparationQueue.new(fakeCacheFs())
    local token = queue:request("mesh", "geometry/a.g4mesh", "demand")
    Assert.isTrue(requestWasPushedFor(host, token), "an idle worker dispatches the only queued request")

    local requestIndex = requestChannelIndexFor(host, token)
    responseChannelFor(host, requestIndex):push(meshResponse(token, "geometry/a.g4mesh"))

    Assert.equal(queue:poll(token), "ready")
    local prepared = queue:take(token)
    Assert.notNil(prepared, "take transfers the prepared payload")
    Assert.throws(function()
      queue:take(token)
    end, "take is valid only once per ready token")
    Assert.throws(function()
      queue:poll(token)
    end, "an already-transferred token cannot be polled again")

    Assert.throws(function()
      queue:poll("never-requested")
    end, "polling an unknown token fails loudly")
    Assert.throws(function()
      queue:take("never-requested")
    end, "taking an unknown token fails loudly")
    Assert.throws(function()
      queue:cancel("never-requested")
    end, "cancelling an unknown token fails loudly")

    queue:release()
  end)
end

function T.cancelled_ready_payload_never_transfers_but_leaves_unrelated_work_alone()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = AssetPreparationQueue.new(fakeCacheFs())
    local first = queue:request("mesh", "geometry/first.g4mesh", "demand")
    local requestIndex = requestChannelIndexFor(host, first)
    responseChannelFor(host, requestIndex):push(meshResponse(first, "geometry/first.g4mesh"))
    Assert.equal(queue:poll(first), "ready")

    -- A ready token cancelled before take releases its references without
    -- affecting unrelated resources: the payload never transfers.
    queue:cancel(first)
    Assert.throws(function()
      queue:take(first)
    end, "a cancelled ready token cannot be taken")

    local second = queue:request("mesh", "geometry/second.g4mesh", "demand")
    Assert.isTrue(requestWasPushedFor(host, second), "unrelated work still dispatches after a ready cancellation")
    local secondIndex = requestChannelIndexFor(host, second)
    responseChannelFor(host, secondIndex):push(meshResponse(second, "geometry/second.g4mesh"))
    Assert.equal(queue:poll(second), "ready")
    Assert.notNil(queue:take(second), "the unrelated payload still transfers exactly once")
    queue:release()
  end)
end

function T.demand_dispatches_before_queued_prefetch_without_preempting_running_work()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = AssetPreparationQueue.new(fakeCacheFs())

    local running = queue:request("mesh", "geometry/running.g4mesh", "prefetch")
    Assert.isTrue(requestWasPushedFor(host, running), "the idle worker takes the first request immediately")

    local queuedPrefetch = queue:request("mesh", "geometry/prefetch.g4mesh", "prefetch")
    local queuedDemand = queue:request("mesh", "geometry/demand.g4mesh", "demand")
    Assert.isFalse(requestWasPushedFor(host, queuedPrefetch), "queued work waits for the busy worker")
    Assert.isFalse(requestWasPushedFor(host, queuedDemand), "queued work waits for the busy worker")

    local requestIndex = requestChannelIndexFor(host, running)
    responseChannelFor(host, requestIndex):push(meshResponse(running, "geometry/running.g4mesh"))
    Assert.equal(queue:poll(running), "ready")

    Assert.isTrue(requestWasPushedFor(host, queuedDemand), "demand dispatches as soon as the worker is idle")
    Assert.isFalse(requestWasPushedFor(host, queuedPrefetch), "demand outranks queued prefetch at dispatch time")

    queue:take(running)
    queue:cancel(queuedDemand)
    queue:cancel(queuedPrefetch)
    queue:release()
  end)
end

function T.queued_cancellation_never_reaches_the_worker()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = AssetPreparationQueue.new(fakeCacheFs())
    local running = queue:request("mesh", "geometry/running.g4mesh", "prefetch")
    local queued = queue:request("mesh", "geometry/queued.g4mesh", "prefetch")

    queue:cancel(queued)

    local requestIndex = requestChannelIndexFor(host, running)
    responseChannelFor(host, requestIndex):push(meshResponse(running, "geometry/running.g4mesh"))
    Assert.equal(queue:poll(running), "ready")
    queue:take(running)

    Assert.isFalse(requestWasPushedFor(host, queued), "a cancelled queued token is dropped, never dispatched")
    Assert.throws(function()
      queue:take(queued)
    end, "a cancelled token cannot be taken")

    queue:release()
  end)
end

function T.running_cancellation_discards_the_late_result()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = AssetPreparationQueue.new(fakeCacheFs())
    local running = queue:request("mesh", "geometry/running.g4mesh", "demand")
    Assert.isTrue(requestWasPushedFor(host, running))

    queue:cancel(running)

    -- Logical cancellation frees no physical slot: a fresh request queues
    -- behind the still-executing job instead of dispatching immediately.
    local next = queue:request("mesh", "geometry/next.g4mesh", "demand")
    Assert.isFalse(
      requestWasPushedFor(host, next),
      "a fresh request waits while the cancelled job still occupies the worker"
    )

    -- The worker's job was already in flight and is not preempted; its late
    -- result must still be discarded rather than published/taken, and only
    -- then does the queued work dispatch.
    local requestIndex = requestChannelIndexFor(host, running)
    responseChannelFor(host, requestIndex):push(meshResponse(running, "geometry/running.g4mesh"))

    Assert.throws(function()
      queue:take(running)
    end, "a cancelled running token's late result cannot be taken")
    Assert.equal(queue:poll(next), "pending")
    Assert.isTrue(
      requestWasPushedFor(host, next),
      "the queued request dispatches after the late reply frees the worker"
    )

    local nextIndex = requestChannelIndexFor(host, next)
    responseChannelFor(host, nextIndex):push(meshResponse(next, "geometry/next.g4mesh"))
    Assert.equal(queue:poll(next), "ready")
    queue:take(next)
    queue:release()
  end)
end

function T.worker_failure_does_not_wedge_subsequent_requests()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = AssetPreparationQueue.new(fakeCacheFs())
    local failing = queue:request("mesh", "geometry/broken.g4mesh", "demand")
    local requestIndex = requestChannelIndexFor(host, failing)
    responseChannelFor(host, requestIndex):push(failureResponse(failing, "mesh", "geometry/broken.g4mesh"))

    Assert.equal(queue:poll(failing), "failed")
    Assert.throws(function()
      queue:take(failing)
    end, "a failed token never yields a payload")

    local next = queue:request("mesh", "geometry/recovered.g4mesh", "demand")
    Assert.isTrue(requestWasPushedFor(host, next), "the next request runs after an observed worker failure")
    local nextRequestIndex = requestChannelIndexFor(host, next)
    responseChannelFor(host, nextRequestIndex):push(meshResponse(next, "geometry/recovered.g4mesh"))
    Assert.equal(queue:poll(next), "ready")
    queue:take(next)
    queue:release()
  end)
end

function T.release_while_idle_joins_the_worker_and_is_idempotent()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = AssetPreparationQueue.new(fakeCacheFs())
    queue:release()
    queue:release()
    Assert.equal(#host.threads, 1, "one persistent worker is owned for the queue lifetime")
    Assert.equal(host.threads[1].waits, 1, "release joins the worker exactly once even if called twice")
  end)
end

function T.release_while_busy_drains_and_discards_outstanding_work()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = AssetPreparationQueue.new(fakeCacheFs())
    local running = queue:request("mesh", "geometry/running.g4mesh", "demand")
    Assert.isTrue(requestWasPushedFor(host, running))

    queue:release()

    Assert.equal(host.threads[1].waits, 1, "disposal joins the worker after outstanding work returns")
    Assert.throws(function()
      queue:poll(running)
    end, "a released queue discards outstanding tokens rather than reviving them")
  end)
end

function T.default_construction_starts_the_worker_from_a_literal_require_bootstrap()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = AssetPreparationQueue.new(fakeCacheFs(), { thread = host.love.thread })
    local source = host.threadSources[1]
    Assert.equal(type(source), "string", "the worker starts from a literal bootstrap string")
    Assert.isTrue(
      source:find("asset_preparation_worker", 1, true) ~= nil,
      "the bootstrap requires the worker module through the packaged path"
    )
    Assert.isTrue(source:find(".run(", 1, true) ~= nil, "the bootstrap enters the worker through its channel entry")
    Assert.isNil(source:find("io.open", 1, true), "the bootstrap never reads checkout files")
    local startArgs = assert(host.threads[1].startArgs[1], "the worker start carries its channel arguments")
    Assert.isTrue(
      startArgs[1] == host.channels[1] and startArgs[2] == host.channels[2],
      "the worker starts with the queue request/reply channel pair"
    )
    Assert.equal(type(startArgs[3]), "string", "the worker start carries the module search path context")
    Assert.isTrue(#startArgs[3] > 0, "the search path context is non-empty")
    queue:release()
  end)
end

function T.cancelled_running_work_keeps_the_physical_slot_until_its_reply()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = AssetPreparationQueue.new(fakeCacheFs())
    local runningPrefetch = queue:request("mesh", "geometry/running.g4mesh", "prefetch")
    Assert.isTrue(requestWasPushedFor(host, runningPrefetch), "the idle worker takes the first request immediately")
    local queuedPrefetch = queue:request("mesh", "geometry/queued.g4mesh", "prefetch")

    queue:cancel(runningPrefetch)

    local lateDemand = queue:request("mesh", "geometry/late.g4mesh", "demand")
    Assert.isFalse(
      requestWasPushedFor(host, queuedPrefetch),
      "no replacement work starts while the cancelled job still occupies the worker"
    )
    Assert.isFalse(
      requestWasPushedFor(host, lateDemand),
      "no replacement work starts while the cancelled job still occupies the worker"
    )

    local requestIndex = requestChannelIndexFor(host, runningPrefetch)
    responseChannelFor(host, requestIndex):push(meshResponse(runningPrefetch, "geometry/running.g4mesh"))
    Assert.equal(queue:poll(lateDemand), "pending")
    Assert.isTrue(requestWasPushedFor(host, lateDemand), "the late demand wins the next physical dispatch")
    Assert.isFalse(
      requestWasPushedFor(host, queuedPrefetch),
      "the queued prefetch still waits while demand occupies the worker"
    )

    local demandIndex = requestChannelIndexFor(host, lateDemand)
    responseChannelFor(host, demandIndex):push(meshResponse(lateDemand, "geometry/late.g4mesh"))
    Assert.equal(queue:poll(queuedPrefetch), "pending")
    Assert.isTrue(requestWasPushedFor(host, queuedPrefetch), "the queued prefetch dispatches after demand completes")

    queue:take(lateDemand)
    queue:cancel(queuedPrefetch)
    queue:release()
  end)
end

function T.stopped_worker_fails_pending_and_future_requests()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = AssetPreparationQueue.new(fakeCacheFs())
    local token = queue:request("mesh", "geometry/stalled.g4mesh", "demand")
    Assert.isTrue(requestWasPushedFor(host, token), "the idle worker takes the request immediately")

    local pushesBefore = #host.allPushes
    host.threads[1]:stop("injected worker crash")

    local tokenState, failure = queue:poll(token)
    Assert.equal(tokenState, "failed", "a token cannot stay pending after its only worker stopped")
    Assert.isTrue(
      type(failure) == "string" and failure:find("injected worker crash", 1, true) ~= nil,
      "the pending token reports the worker-stop cause: " .. tostring(failure)
    )

    local requestOk, requestResult = pcall(function()
      return queue:request("mesh", "geometry/after.g4mesh", "demand")
    end)
    if requestOk then
      local nextState, nextFailure = queue:poll(requestResult)
      Assert.equal(nextState, "failed", "requests after worker death fail instead of queueing onto a dead worker")
      Assert.isTrue(
        type(nextFailure) == "string" and nextFailure:find("injected worker crash", 1, true) ~= nil,
        "future requests report the same terminal cause: " .. tostring(nextFailure)
      )
    else
      local message = tostring(requestResult)
      Assert.isTrue(
        message:find("injected worker crash", 1, true) ~= nil or message:find("worker stopped", 1, true) ~= nil,
        "future requests report the terminal worker-stop cause: " .. message
      )
    end
    Assert.equal(#host.allPushes, pushesBefore, "no further request is pushed after the worker stopped")

    queue:release()
  end)
end

function T.ready_payload_survives_worker_death_while_pending_work_fails()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = AssetPreparationQueue.new(fakeCacheFs())
    local first = queue:request("mesh", "geometry/first.g4mesh", "demand")
    local second = queue:request("mesh", "geometry/second.g4mesh", "demand")
    Assert.isTrue(requestWasPushedFor(host, first), "the idle worker takes the first request immediately")
    Assert.isFalse(requestWasPushedFor(host, second), "the second request waits for the busy worker")

    local requestIndex = requestChannelIndexFor(host, first)
    responseChannelFor(host, requestIndex):push(meshResponse(first, "geometry/first.g4mesh"))
    Assert.equal(queue:poll(first), "ready")
    Assert.isTrue(requestWasPushedFor(host, second), "the second request dispatches once the worker is idle")

    host.threads[1]:stop("late worker crash")

    Assert.equal(queue:poll(first), "ready", "a drained ready payload stays transferable after the worker dies")
    local prepared = queue:take(first)
    Assert.notNil(prepared, "the ready payload transfers exactly once despite the later worker death")

    local pendingState, pendingFailure = queue:poll(second)
    Assert.equal(pendingState, "failed", "still-pending work fails instead of staying pending forever")
    Assert.isTrue(
      type(pendingFailure) == "string" and pendingFailure:find("late worker crash", 1, true) ~= nil,
      "pending work reports the worker-stop cause: " .. tostring(pendingFailure)
    )

    queue:release()
  end)
end

function T.release_after_worker_death_joins_once_without_masking_cleanup()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = AssetPreparationQueue.new(fakeCacheFs())
    local token = queue:request("mesh", "geometry/stalled.g4mesh", "demand")
    Assert.isTrue(requestWasPushedFor(host, token), "the idle worker takes the request immediately")

    host.threads[1]:stop(nil)

    local tokenState, failure = queue:poll(token)
    Assert.equal(tokenState, "failed", "pending work fails after the worker exits without an error")
    Assert.isTrue(
      type(failure) == "string" and failure:find("worker stopped", 1, true) ~= nil,
      "the terminal cause stays descriptive without a worker error: " .. tostring(failure)
    )

    queue:release()
    queue:release()
    Assert.equal(host.threads[1].waits, 1, "release joins the worker exactly once even after terminal failure")
    Assert.throws(function()
      queue:poll(token)
    end, "a released queue discards outstanding tokens rather than reviving them")
  end)
end

function T.synchronous_wait_reobserves_worker_death_during_channel_block()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = AssetPreparationQueue.new(fakeCacheFs())
    local token = queue:request("mesh", "geometry/stalled.g4mesh", "demand")
    Assert.isTrue(requestWasPushedFor(host, token), "the idle worker takes the request immediately")

    -- The worker dies after the wait's last health probe without producing
    -- a reply; the wait must bound its channel block so liveness is
    -- re-observed instead of hanging forever. An unbounded demand fails
    -- loudly here rather than hanging the suite.
    local requestIndex = requestChannelIndexFor(host, token)
    local reply = responseChannelFor(host, requestIndex)
    local demands = 0
    reply.onDemand = function(timeout)
      demands = demands + 1
      if type(timeout) ~= "number" or timeout <= 0 or timeout > 0.1 then
        error("synchronous wait performed an unbounded channel demand", 0)
      end
      host.threads[1]:stop("injected wait race")
      return nil
    end

    local err = Assert.throws(function()
      queue:wait(token)
    end, "a wait whose worker dies mid-block must raise instead of hanging")
    Assert.isTrue(demands >= 1, "the wait actually blocked on the reply channel")
    Assert.isTrue(
      tostring(err):find("injected wait race", 1, true) ~= nil,
      "the wait reports the worker-stop cause: " .. tostring(err)
    )

    queue:release()
  end)
end

function T.demand_admission_wins_over_queued_prefetch_when_request_discovers_a_completion()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = AssetPreparationQueue.new(fakeCacheFs())
    local running = queue:request("mesh", "geometry/running.g4mesh", "prefetch")
    Assert.isTrue(requestWasPushedFor(host, running), "the idle worker takes the first request immediately")
    local queuedPrefetch = queue:request("mesh", "geometry/queued.g4mesh", "prefetch")
    Assert.isFalse(requestWasPushedFor(host, queuedPrefetch), "queued work waits for the busy worker")

    -- The running job's reply arrives but is not processed yet; the demand
    -- below discovers it during admission and must win the replacement
    -- dispatch over the older queued prefetch.
    local requestIndex = requestChannelIndexFor(host, running)
    responseChannelFor(host, requestIndex):push(meshResponse(running, "geometry/running.g4mesh"))
    local pushesBefore = #host.allPushes

    local admitted = queue:request("mesh", "geometry/demand.g4mesh", "demand")

    local newPushes = {}
    for index = pushesBefore + 1, #host.allPushes do
      local value = host.allPushes[index].value
      if type(value) == "table" and value.token ~= nil and value.path ~= nil and value.kind ~= nil then
        newPushes[#newPushes + 1] = value.token
      end
    end
    Assert.equal(#newPushes, 1, "admission settles exactly one replacement dispatch")
    Assert.equal(
      newPushes[1],
      admitted,
      "the just-admitted demand wins the replacement dispatch over older queued prefetch"
    )
    Assert.isFalse(
      requestWasPushedFor(host, queuedPrefetch),
      "the older queued prefetch still waits while demand occupies the worker"
    )

    queue:take(running)
    queue:cancel(admitted)
    queue:cancel(queuedPrefetch)
    queue:release()
  end)
end

function T.cancelled_running_prefetch_holds_the_worker_until_queued_demand_dispatches()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = AssetPreparationQueue.new(fakeCacheFs())
    local running = queue:request("mesh", "geometry/running.g4mesh", "prefetch")
    Assert.isTrue(requestWasPushedFor(host, running), "the idle worker takes the first request immediately")
    local queuedDemand = queue:request("mesh", "geometry/queued-demand.g4mesh", "demand")
    local queuedPrefetch = queue:request("mesh", "geometry/queued-prefetch.g4mesh", "prefetch")
    Assert.isFalse(requestWasPushedFor(host, queuedDemand), "queued work waits for the busy worker")
    Assert.isFalse(requestWasPushedFor(host, queuedPrefetch), "queued work waits for the busy worker")

    queue:cancel(running)

    -- Cancellation frees no physical slot: even a fresh demand queues
    -- behind the still-executing job instead of dispatching immediately.
    local lateDemand = queue:request("mesh", "geometry/late-demand.g4mesh", "demand")
    Assert.equal(pushCountFor(host, queuedDemand), 0, "nothing dispatches while the cancelled job runs")
    Assert.equal(pushCountFor(host, queuedPrefetch), 0, "nothing dispatches while the cancelled job runs")
    Assert.equal(pushCountFor(host, lateDemand), 0, "nothing dispatches while the cancelled job runs")

    local requestIndex = requestChannelIndexFor(host, running)
    responseChannelFor(host, requestIndex):push(meshResponse(running, "geometry/running.g4mesh"))
    Assert.equal(queue:poll(lateDemand), "pending")
    Assert.equal(pushCountFor(host, queuedDemand), 1, "the earlier demand wins the first dispatch after the late reply")
    Assert.equal(pushCountFor(host, lateDemand), 0, "the later demand still waits its turn")
    Assert.equal(pushCountFor(host, queuedPrefetch), 0, "demand outranks queued prefetch at dispatch time")

    local demandIndex = requestChannelIndexFor(host, queuedDemand)
    responseChannelFor(host, demandIndex):push(meshResponse(queuedDemand, "geometry/queued-demand.g4mesh"))
    Assert.equal(queue:poll(queuedDemand), "ready")
    Assert.equal(pushCountFor(host, lateDemand), 1, "the later demand dispatches once the worker is idle")
    Assert.equal(pushCountFor(host, queuedPrefetch), 0, "prefetch still waits while demand occupies the worker")

    queue:take(queuedDemand)
    queue:cancel(lateDemand)
    local lateIndex = requestChannelIndexFor(host, lateDemand)
    responseChannelFor(host, lateIndex):push(meshResponse(lateDemand, "geometry/late-demand.g4mesh"))
    Assert.equal(queue:poll(queuedPrefetch), "pending")
    Assert.equal(pushCountFor(host, queuedPrefetch), 1, "the queued prefetch dispatches after every demand completes")

    local prefetchIndex = requestChannelIndexFor(host, queuedPrefetch)
    responseChannelFor(host, prefetchIndex):push(meshResponse(queuedPrefetch, "geometry/queued-prefetch.g4mesh"))
    Assert.equal(queue:poll(queuedPrefetch), "ready")
    queue:take(queuedPrefetch)
    queue:release()
  end)
end

function T.late_reply_after_mass_cancellation_dispatches_exactly_one_job()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = AssetPreparationQueue.new(fakeCacheFs())
    local running = queue:request("mesh", "geometry/running.g4mesh", "demand")
    Assert.isTrue(requestWasPushedFor(host, running), "the idle worker takes the first request immediately")
    local firstQueued = queue:request("mesh", "geometry/first-queued.g4mesh", "prefetch")
    local secondQueued = queue:request("mesh", "geometry/second-queued.g4mesh", "prefetch")

    queue:cancel(running)
    queue:cancel(firstQueued)
    queue:cancel(secondQueued)

    local next = queue:request("mesh", "geometry/next.g4mesh", "demand")
    Assert.isFalse(
      requestWasPushedFor(host, next),
      "a fresh request waits while the cancelled job still occupies the worker"
    )

    -- The cancelled job's late reply frees the worker; the cancelled queued
    -- tokens must never reach the worker input channel as stale jobs.
    local requestIndex = requestChannelIndexFor(host, running)
    responseChannelFor(host, requestIndex):push(meshResponse(running, "geometry/running.g4mesh"))
    Assert.equal(queue:poll(next), "pending")
    Assert.equal(pushCountFor(host, next), 1, "the late reply frees the worker for exactly one next job")
    Assert.equal(pushCountFor(host, firstQueued), 0, "a cancelled queued token never reaches the worker")
    Assert.equal(pushCountFor(host, secondQueued), 0, "a cancelled queued token never reaches the worker")

    local nextIndex = requestChannelIndexFor(host, next)
    responseChannelFor(host, nextIndex):push(meshResponse(next, "geometry/next.g4mesh"))
    Assert.equal(queue:poll(next), "ready", "the next job's own payload still publishes normally")
    queue:take(next)
    queue:release()
  end)
end

function T.queued_wait_reobserves_worker_death_through_bounded_demands()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = AssetPreparationQueue.new(fakeCacheFs())
    local running = queue:request("mesh", "geometry/running.g4mesh", "demand")
    Assert.isTrue(requestWasPushedFor(host, running), "the idle worker takes the first request immediately")
    local queued = queue:request("mesh", "geometry/queued.g4mesh", "demand")
    Assert.isFalse(requestWasPushedFor(host, queued), "the second request waits for the busy worker")

    -- A synchronous wait on work that never dispatched must still bound its
    -- channel block, so a worker dying mid-block is re-observed instead of
    -- hanging the waiter forever.
    local requestIndex = requestChannelIndexFor(host, running)
    local reply = responseChannelFor(host, requestIndex)
    local demands = 0
    reply.onDemand = function(timeout)
      demands = demands + 1
      if type(timeout) ~= "number" or timeout <= 0 or timeout > 0.1 then
        error("synchronous wait performed an unbounded channel demand", 0)
      end
      host.threads[1]:stop("injected queued wait race")
      return nil
    end

    local err = Assert.throws(function()
      queue:wait(queued)
    end, "a queued wait whose worker dies mid-block must raise instead of hanging")
    Assert.isTrue(demands >= 1, "the wait actually blocked on the reply channel")
    Assert.isTrue(
      tostring(err):find("injected queued wait race", 1, true) ~= nil,
      "the queued wait reports the worker-stop cause: " .. tostring(err)
    )

    local runningState, runningFailure = queue:poll(running)
    Assert.equal(runningState, "failed", "the running token fails too instead of staying pending forever")
    Assert.isTrue(
      type(runningFailure) == "string" and runningFailure:find("injected queued wait race", 1, true) ~= nil,
      "the running token reports the same terminal cause: " .. tostring(runningFailure)
    )

    queue:release()
  end)
end

function T.finish_promotes_the_queued_prefetch_token_to_demand()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  withLove(host.love, function()
    local queue = AssetPreparationQueue.new(fakeCacheFs())
    local running = queue:request("mesh", "geometry/running.g4mesh", "prefetch")
    Assert.isTrue(requestWasPushedFor(host, running), "the idle worker takes the first request immediately")
    local queued = queue:request("mesh", "geometry/queued.g4mesh", "prefetch")
    Assert.isFalse(requestWasPushedFor(host, queued), "the second request waits for the busy worker")

    -- Finishing the scene task upgrades its outstanding prefetch token to
    -- demand in place: the same token keeps its identity and is never
    -- dispatched twice for the promotion itself.
    queue:promote(queued, "demand")
    Assert.equal(pushCountFor(host, queued), 0, "promotion upgrades priority without dispatching by itself")

    local laterPrefetch = queue:request("mesh", "geometry/later.g4mesh", "prefetch")

    local requestIndex = requestChannelIndexFor(host, running)
    responseChannelFor(host, requestIndex):push(meshResponse(running, "geometry/running.g4mesh"))
    Assert.equal(queue:poll(running), "ready")
    Assert.equal(pushCountFor(host, queued), 1, "the promoted token wins the next physical dispatch")
    Assert.isFalse(requestWasPushedFor(host, laterPrefetch), "the promoted demand outranks later prefetch work")

    Assert.throws(function()
      queue:promote("never-requested", "demand")
    end, "promoting an unknown token fails loudly")

    queue:take(running)
    queue:cancel(queued)
    queue:cancel(laterPrefetch)
    queue:release()
  end)
end

return { tests = T }
