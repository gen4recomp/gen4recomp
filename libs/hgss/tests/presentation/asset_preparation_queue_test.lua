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
    local channel = {}
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
    function channel:demand()
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
    local thread = { starts = 0, waits = 0, alive = true, errorText = nil, source = source }
    function thread:start()
      self.starts = self.starts + 1
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

function T.default_construction_uses_packaged_virtual_filesystem_source()
  local AssetPreparationQueue = requireQueue()
  local host = fakeThreadHost()
  local packagedCode = "-- packaged presentation worker source"
  local fileData = {}
  local fakeFilesystem = {
    read = function(path)
      if path == "libs/hgss/src/presentation/asset_preparation_worker.lua" then
        return packagedCode
      end
      return nil
    end,
    newFileData = function(bytes, name)
      local marker = { bytes = bytes, name = name }
      fileData.marker = marker
      return marker
    end,
    getSourceBaseDirectory = function()
      return "/nonexistent-source-base"
    end,
  }
  -- Host package paths intentionally cannot resolve the worker, so only the
  -- packaged virtual-filesystem lookup can supply the source bytes.
  local savedPath = package.path
  package.path = "/nonexistent-package-path/?.lua"
  local fakeLove = { thread = host.love.thread, filesystem = fakeFilesystem }
  local ok, err = pcall(function()
    withLove(fakeLove, function()
      local queue = AssetPreparationQueue.new(fakeCacheFs(), { thread = host.love.thread })
      queue:release()
    end)
  end)
  package.path = savedPath
  Assert.isTrue(ok, "default construction resolves worker source without host package paths: " .. tostring(err))
  Assert.notNil(fileData.marker, "construction builds the worker from virtual-filesystem bytes")
  Assert.equal(fileData.marker.bytes, packagedCode, "the worker is constructed from virtual-filesystem bytes")
  Assert.equal(fileData.marker.name, "asset_preparation_worker.lua", "the packaged worker bytes keep their entry name")
  Assert.equal(host.threadSources[1], fileData.marker, "the thread starts from the virtual-filesystem payload")
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

return { tests = T }
