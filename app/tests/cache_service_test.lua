-- The game thread must observe cache readiness without producing it: version
-- selection performs no producer digest computation on the calling thread,
-- frame updates emit only bounded deduplicated request/status traffic, and
-- retirement, source replacement, failure, and shutdown all linearize on
-- explicit controller acknowledgements. Until the off-main controller lands,
-- the service surface below is absent and the current selection path still
-- computes digests inline; those are the intended reds.

local Assert = require("tests.support.Assert")

local T = {}

-- Release-mode producer identity: the selection contract requires the r<int>
-- release shape (development digests are computed by the selection path the
-- first scenario observes, so the fixture carries a release identity).

-- Deterministic process-local thread host mirroring the love.thread shape:
-- FIFO channels, demand without auto-reply so the test scripts every
-- controller answer, and a killable worker to model unexpected thread death.
-- No real OS thread starts here; one focused test below uses a real thread.
local function newChannelHost()
  local channels = {}
  local function newChannel()
    local queue = {}
    local channel = {}
    function channel:push(value)
      queue[#queue + 1] = value
      return true
    end
    function channel:pop()
      if #queue == 0 then
        return nil
      end
      return table.remove(queue, 1)
    end
    function channel:demand(_)
      return table.remove(queue, 1)
    end
    function channel:count()
      return #queue
    end
    channels[#channels + 1] = { channel = channel, queue = queue }
    return channel
  end
  local threads = {}
  local function newThread(source)
    local thread = { source = source, starts = 0, waits = 0, alive = true, startArgs = {}, errorText = nil }
    function thread:start(...)
      self.starts = self.starts + 1
      self.startArgs = { ... }
      return true
    end
    function thread:wait()
      self.waits = self.waits + 1
      self.alive = false
      return true
    end
    function thread:isRunning()
      return self.alive
    end
    function thread:getError()
      return self.errorText
    end
    function thread:kill(message)
      self.alive = false
      self.errorText = message
    end
    threads[#threads + 1] = thread
    return thread
  end
  return { newChannel = newChannel, newThread = newThread, threads = threads }
end

-- The frozen behavioral surface: one process service owning a single
-- controller thread behind flat scalar request/status messages. Names the
-- missing behavior when the controller has not moved off the game thread.
local function requireService()
  local ok, service = pcall(require, "app.src.CacheService")
  Assert.isTrue(
    ok and service ~= nil and type(service.new) == "function",
    "no off-main cache service with bounded request/status protocol exists: " .. tostring(service)
  )
  return service
end

-- Test-local patch helper matching the producer suites: targets stay
-- unannotated parameters so spying on module functions needs no
-- class injection, and every replacement is restored after the run.
local function withPatched(patches, fn)
  local originals = {}
  for index, patch in ipairs(patches) do
    originals[index] = patch.target[patch.name]
    patch.target[patch.name] = patch.wrap(originals[index])
  end
  local ok, first = pcall(fn)
  for index, patch in ipairs(patches) do
    patch.target[patch.name] = originals[index]
  end
  if not ok then
    error(first, 0)
  end
  return true, first
end

-- Plumbing (may adapt to the relocated controller): select one game through
-- the current production selection path and return its provisioner. Frozen:
-- setup (a selected game), action (semantic request plus frame updates),
-- observable boundary (spy counters), expected result (zero synchronous
-- production work on the calling thread).
local function selectGameWithMilestone(spies)
  local CacheFs = require("libs.storage.src.CacheFs")
  local CompilerPool = require("romdump.src.build.CompilerPool")
  local DerivedAssetProvisioner = require("app.src.DerivedAssetProvisioner")
  local FakeCache = require("tests.support.FakeCache")
  local backend = FakeCache.new()
  local cacheFs = CacheFs.forVersion("heartgold", backend)
  local realForVersion = CacheFs.forVersion
  CacheFs.forVersion = function()
    return cacheFs
  end
  local poolUpdates = 0
  local ok, err = pcall(function()
    local pool = CompilerPool.new({ mode = "interactive" })
    local realUpdate = pool.update
    pool.update = function(self, ...)
      poolUpdates = poolUpdates + 1
      return realUpdate(self, ...)
    end
    -- Plumbing adapted to the relocated controller: selection and demand
    -- go through the service; no session or pool is pumped on this thread.
    local Service = require("app.src.CacheService")
    local service = assert(Service.new({ thread = newChannelHost() }))
    local selected = DerivedAssetProvisioner.new({ versionId = "heartgold", service = service })
    local host = selected:gameHost()
    host.requestMilestone("bootstrap", "required")
    for _ = 1, 20 do
      selected:update()
    end
    selected:dispose()
  end)
  CacheFs.forVersion = realForVersion
  assert(ok, err)
  spies.poolUpdates = poolUpdates
  return spies
end

function T.selection_and_frame_updates_do_no_producer_or_filesystem_work_on_the_calling_thread()
  local calls = { digest = 0, moveTree = 0, publish = 0 }
  local ok, err = withPatched({
    {
      target = require("romdump.src.ProducerFingerprint"),
      name = "compute",
      wrap = function(real)
        return function(...)
          calls.digest = calls.digest + 1
          return real(...)
        end
      end,
    },
    {
      target = require("libs.storage.src.CacheFs"),
      name = "moveTree",
      wrap = function(real)
        return function(...)
          calls.moveTree = calls.moveTree + 1
          return real(...)
        end
      end,
    },
    {
      target = require("romdump.src.build.PreparedArtifact"),
      name = "publish",
      wrap = function(real)
        return function(self, ...)
          calls.publish = calls.publish + 1
          return real(self, ...)
        end
      end,
    },
  }, function()
    return selectGameWithMilestone(calls)
  end)
  assert(ok, err)
  Assert.equal(calls.digest, 0, "selecting a version computes no producer digest on the calling thread")
  Assert.equal(calls.moveTree, 0, "frame updates publish no cache trees on the calling thread")
  Assert.equal(calls.publish, 0, "frame updates publish no prepared artifacts on the calling thread")
  Assert.equal(calls.poolUpdates, 0, "frame updates pump no pool control synchronously on the calling thread")
end

function T.repeated_host_requests_send_one_command_and_frame_updates_emit_bounded_polls()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  for _ = 1, 50 do
    service:request(epoch, { requestKind = "milestone", name = "bootstrap", urgency = "required" })
  end
  for index = 1, 3000 do
    service:request(epoch, { requestKind = "cell", matrixMemberId = 11, index = index % 7, urgency = "near" })
  end
  local emitted = service:update()
  Assert.isTrue(emitted.ordinary <= 8, "one frame emits at most eight ordinary records")
  Assert.isTrue(emitted.polls <= 1, "one frame carries at most one poll packet")
  local again = service:update()
  Assert.equal(again.ordinary, 0, "repeated pending requests send no further ensure commands")
  local ready, failure = service:observe(epoch, { requestKind = "milestone", name = "bootstrap" })
  Assert.isNil(ready, "an unanswered request observes no readiness")
  Assert.isNil(failure, "an unanswered request observes no failure")
end

function T.retirement_and_import_wait_for_exact_controller_barriers()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local first = assert(service:select({ versionId = "heartgold", development = true }))
  service:request(first, { requestKind = "milestone", name = "bootstrap", urgency = "required" })
  service:update()
  local barrier = assert(service:retire(first), "retirement returns its barrier identity")
  Assert.equal(service:barrierStatus(first, barrier), "pending", "retirement is not inferred from empty queues")
  local second = assert(service:select({ versionId = "heartgold", development = true }))
  Assert.isTrue(second ~= first, "a new selection mints a fresh epoch")
  local ready = service:observe(first, { requestKind = "milestone", name = "bootstrap" })
  Assert.isNil(ready, "a retired epoch grants no observation rights")
  local quiesce = assert(service:quiesce(second), "source replacement waits for quiescence")
  Assert.equal(service:barrierStatus(second, quiesce), "pending", "quiescence needs controller acknowledgement")
  local ok, _ = service:importSource(second, quiesce)
  Assert.isFalse(ok, "no import crosses an unacknowledged quiescence barrier")
end

function T.retire_then_quiesce_barriers_resolve_without_further_requests()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  service:request(epoch, { requestKind = "milestone", name = "bootstrap", urgency = "required" })
  service:update()
  local retireBarrier = assert(service:retire(epoch), "retirement returns its barrier identity")
  local quiesceBarrier = assert(service:quiesce(epoch), "quiescence follows retirement on the same epoch")
  Assert.isTrue(quiesceBarrier > retireBarrier, "barrier identities stay process-ordered")
  service:injectReply({ op = "poll-result", roundId = 1, epoch = epoch, count = 0 })
  local emitted = service:update()
  Assert.equal(emitted.polls, 1, "a barrier waiter earns its poll round even while retiring")
  service:injectReply({ op = "poll-result", roundId = 2, epoch = epoch, count = 0, retiredBarrierId = retireBarrier })
  local followed = service:update()
  Assert.equal(service:barrierStatus(epoch, retireBarrier), "ready", "the retirement acknowledgement lands")
  Assert.equal(followed.polls, 1, "the quiescence waiter earns its round after retirement clears the epoch")
  service:injectReply({ op = "poll-result", roundId = 3, epoch = epoch, count = 0, quiescedBarrierId = quiesceBarrier })
  service:update()
  Assert.equal(service:barrierStatus(epoch, quiesceBarrier), "ready", "the quiescence acknowledgement lands")
  local ok, _ = service:importSource(epoch, quiesceBarrier)
  Assert.isTrue(ok, "an acknowledged quiescence barrier authorizes import")
end

function T.stale_barrier_answers_never_satisfy_a_newer_waiter()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  service:request(epoch, { requestKind = "milestone", name = "bootstrap", urgency = "required" })
  service:update()
  local retireBarrier = assert(service:retire(epoch), "retirement returns its barrier identity")
  local quiesceBarrier = assert(service:quiesce(epoch), "quiescence follows retirement on the same epoch")
  service:injectReply({ op = "poll-result", roundId = 1, epoch = epoch, count = 0 })
  service:update()
  service:injectReply({ op = "poll-result", roundId = 2, epoch = epoch, count = 0, retiredBarrierId = retireBarrier })
  service:update()
  service:injectReply({ op = "poll-result", roundId = 3, epoch = epoch, count = 0, quiescedBarrierId = retireBarrier })
  service:update()
  Assert.equal(
    service:barrierStatus(epoch, quiesceBarrier),
    "pending",
    "an older barrier identity never satisfies a newer waiter"
  )
  service:update()
  service:injectReply({ op = "poll-result", roundId = 4, epoch = epoch, count = 0, quiescedBarrierId = quiesceBarrier })
  service:update()
  Assert.equal(service:barrierStatus(epoch, quiesceBarrier), "ready", "the exact acknowledgement still lands")
end

function T.late_replies_from_a_retired_epoch_never_enter_the_new_selection()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local first = assert(service:select({ versionId = "heartgold", development = true }))
  service:request(first, { requestKind = "milestone", name = "bootstrap", urgency = "required" })
  service:update()
  service:retire(first)
  local second = assert(service:select({ versionId = "heartgold", development = true }))
  service:injectReply({ epoch = first, requestKind = "milestone", name = "bootstrap", state = "ready" })
  service:update()
  local ready, failure = service:observe(second, { requestKind = "milestone", name = "bootstrap" })
  Assert.isNil(ready, "an obsolete-epoch reply authorizes no new-epoch transition")
  Assert.isNil(failure, "an obsolete-epoch reply reports no new-epoch failure")
end

function T.controller_death_fails_requests_and_shutdown_joins_exactly_once()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  service:request(epoch, { requestKind = "milestone", name = "bootstrap", urgency = "required" })
  service:update()
  assert(host.threads[1], "the service owns exactly one controller thread")
  host.threads[1]:kill("controller stopped unexpectedly")
  service:update()
  local ready, failure = service:observe(epoch, { requestKind = "milestone", name = "bootstrap" })
  Assert.isNil(ready, "a dead controller reports no readiness")
  Assert.isTrue(
    tostring(failure):find("controller", 1, true) ~= nil,
    "pending requests fail with the controller cause: " .. tostring(failure)
  )
  Assert.equal(host.threads[1].starts, 1, "a failed controller is never silently restarted")
  service:shutdown()
  Assert.equal(host.threads[1].waits, 1, "process shutdown joins the controller exactly once")
  service:shutdown()
  Assert.equal(host.threads[1].waits, 1, "repeated shutdown joins nothing again")
end

function T.real_controller_thread_boots_and_answers_a_selection_round()
  local realLove = rawget(_G, "love")
  assert(realLove ~= nil and realLove.thread ~= nil, "the real-thread proof requires the host runtime")
  local ok, entry = pcall(require, "romdump.src.build.CacheControllerWorker")
  Assert.isTrue(
    ok and entry ~= nil and type(entry.run) == "function",
    "no real controller thread entry exists to boot: " .. tostring(entry)
  )
  local request = realLove.thread.newChannel()
  local reply = realLove.thread.newChannel()
  local worker = realLove.thread.newThread(entry.bootstrap())
  worker:start(request, reply, package.path)
  -- Mirror production selection: development identity is derived below
  -- the worker from the repository root, never supplied as a hash.
  local sourceBase = realLove.filesystem.getSourceBaseDirectory()
  request:push({
    op = "select",
    epoch = 1,
    versionId = "heartgold",
    development = true,
    repositoryRoot = sourceBase,
  })
  -- Channel:demand takes no timeout argument, so an unbounded demand
  -- would wedge the suite forever if the worker stalls; poll boundedly
  -- and attribute a timeout with the worker's own error instead.
  local timer = realLove.timer
  local deadline = timer.getTime() + 60
  local answer = nil
  while answer == nil and timer.getTime() < deadline and worker:isRunning() do
    answer = reply:pop()
    if answer == nil then
      timer.sleep(0.05)
    end
  end
  Assert.notNil(answer, "the booted controller answers its selection round: " .. tostring(worker:getError()))
  assert(type(answer) == "table", "the booted controller answers its selection round")
  Assert.isTrue(answer.epoch == 1, "the booted controller answers its selection round")
  Assert.isTrue(answer.ok == true, "development selection succeeds: " .. tostring(answer.errorMessage))
  request:push({ op = "shutdown", epoch = 1 })
  worker:wait()
  Assert.isFalse(worker:isRunning(), "the controller exits on shutdown")
end

return { tests = T }
