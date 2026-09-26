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

function T.repeated_host_requests_send_one_command_and_frame_updates_send_no_status_probe()
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
  local probes = 0
  local command = service._command:pop()
  while command ~= nil do
    if command.op == "poll" then
      probes = probes + 1
    end
    command = service._command:pop()
  end
  Assert.equal(probes, 0, "thousands of deduplicated requests emit no status probe")
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
  service:update()
  local probes = 0
  local command = service._command:pop()
  while command ~= nil do
    if command.op == "poll" then
      probes = probes + 1
    end
    command = service._command:pop()
  end
  Assert.equal(probes, 0, "barrier waiters never earn a status probe while retiring")
  service:injectReply({ op = "barrier-result", epoch = epoch, barrierId = retireBarrier, kind = "retire" })
  service:update()
  Assert.equal(service:barrierStatus(epoch, retireBarrier), "ready", "the retirement acknowledgement lands")
  Assert.equal(
    service:barrierStatus(epoch, quiesceBarrier),
    "pending",
    "the retirement answer never settles quiescence"
  )
  service:injectReply({ op = "barrier-result", epoch = epoch, barrierId = quiesceBarrier, kind = "quiesce" })
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
  service:update()
  service:injectReply({ op = "barrier-result", epoch = epoch, barrierId = retireBarrier, kind = "retire" })
  service:update()
  service:injectReply({ op = "barrier-result", epoch = epoch, barrierId = retireBarrier, kind = "quiesce" })
  service:update()
  Assert.equal(
    service:barrierStatus(epoch, quiesceBarrier),
    "pending",
    "an older barrier identity never satisfies a newer waiter"
  )
  service:update()
  service:injectReply({ op = "barrier-result", epoch = epoch, barrierId = quiesceBarrier, kind = "quiesce" })
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

function T.selection_answer_caches_the_controller_generation_token()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  Assert.isNil(service:generationId(epoch), "the generation is unknown before the selection answer lands")
  service:request(epoch, { requestKind = "milestone", name = "bootstrap", urgency = "required" })
  service:injectReply({ op = "select-result", epoch = epoch, ok = true, generationId = "g4:test:token" })
  service:update()
  Assert.equal(service:generationId(epoch), "g4:test:token", "the selection answer publishes its generation token")
  service:injectReply({
    op = "poll-result",
    roundId = 1,
    epoch = epoch,
    count = 0,
    generationId = "g4:test:rotated",
  })
  service:update()
  Assert.equal(service:generationId(epoch), "g4:test:token", "a retired status round never rotates the token")
  service:shutdown()
end

function T.generation_token_grants_no_rights_to_stale_or_retired_epochs()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local first = assert(service:select({ versionId = "heartgold", development = true }))
  service:injectReply({ op = "select-result", epoch = first, ok = true, generationId = "g4:test:first" })
  service:update()
  Assert.equal(service:generationId(first), "g4:test:first")
  service:retire(first)
  Assert.isNil(service:generationId(first), "a retiring epoch grants no generation rights")
  local second = assert(service:select({ versionId = "heartgold", development = true }))
  Assert.isNil(service:generationId(second), "a fresh epoch starts with an unknown generation")
  service:injectReply({ op = "select-result", epoch = first, ok = true, generationId = "g4:test:late" })
  service:update()
  Assert.isNil(service:generationId(second), "a late answer for a retired epoch never enters the new selection")
  service:shutdown()
end

function T.provisioner_exposes_the_selection_generation_without_scanning()
  local Service = requireService()
  local DerivedAssetProvisioner = require("app.src.DerivedAssetProvisioner")
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local provisioner = DerivedAssetProvisioner.new({ versionId = "heartgold", service = service })
  local epoch = assert(provisioner.epoch, "selection borrows an epoch")
  Assert.isNil(provisioner:generationId(), "the generation is unknown before the controller answers")
  service:injectReply({ op = "select-result", epoch = epoch, ok = true, generationId = "g4:test:token" })
  service:update()
  Assert.equal(provisioner:generationId(), "g4:test:token", "the provisioner exposes the derived token")
  provisioner:dispose()
  Assert.isNil(provisioner:generationId(), "a retired provisioner reports no generation")
  service:shutdown()
end

function T.icon_page_requests_validate_selectors_and_never_alias_portraits()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  service:request(epoch, { requestKind = "icon-page", pageId = 3, urgency = "required" })
  service:request(epoch, { requestKind = "portrait", pageId = 3, urgency = "required" })
  service:request(epoch, { requestKind = "icon-page", pageId = 3, urgency = "near" })
  local emitted = service:update()
  Assert.equal(emitted.ordinary, 2, "icon and portrait pages keep distinct request identities")
  local iconReady, _ = service:observe(epoch, { requestKind = "icon-page", pageId = 3 })
  local portraitReady, _ = service:observe(epoch, { requestKind = "portrait", pageId = 3 })
  Assert.isNil(iconReady, "an unanswered icon request observes no readiness")
  Assert.isNil(portraitReady, "an unanswered portrait request observes no readiness")
  local badOk, _ = pcall(function()
    service:request(epoch, { requestKind = "icon-page", pageId = -1, urgency = "required" })
  end)
  Assert.isFalse(badOk, "a negative icon page is rejected")
  local kindOk, _ = pcall(function()
    service:request(epoch, { requestKind = "icon", pageId = 3, urgency = "required" })
  end)
  Assert.isFalse(kindOk, "an unlisted request kind is rejected")
  service:shutdown()
end

function T.frame_updates_send_no_status_probe_for_pending_requests()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  for _ = 1, 50 do
    service:request(epoch, { requestKind = "milestone", name = "bootstrap", urgency = "required" })
  end
  local emitted = service:update()
  Assert.equal(emitted.ordinary, 1, "repeated pending requests send one initial command")
  Assert.equal(emitted.polls or 0, 0, "frame updates send no status probe")
  local seen = {}
  local command = service._command:pop()
  while command ~= nil do
    seen[#seen + 1] = command.op
    command = service._command:pop()
  end
  local probes, requests = 0, 0
  for _, op in ipairs(seen) do
    if op == "poll" then
      probes = probes + 1
    end
    if op == "request" then
      requests = requests + 1
    end
  end
  Assert.equal(probes, 0, "no status probe command leaves the game thread")
  Assert.equal(requests, 1, "the deduplicated request still leaves the game thread")
  local again = service:update()
  Assert.equal(again.ordinary, 0, "repeated pending requests send no further commands")
  Assert.equal(again.polls or 0, 0, "idle frames send no status probe")
  local ready, failure = service:observe(epoch, { requestKind = "milestone", name = "bootstrap" })
  Assert.isNil(ready, "an unanswered request observes no readiness")
  Assert.isNil(failure, "an unanswered request observes no failure")
  service:shutdown()
end

function T.pushed_request_completion_lands_in_the_matching_cached_observation()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  local first = assert(service:request(epoch, { requestKind = "milestone", name = "bootstrap", urgency = "required" }))
  local second =
    assert(service:request(epoch, { requestKind = "milestone", name = "field-planning", urgency = "required" }))
  service:update()
  local pending, _ = service:observe(epoch, { requestKind = "milestone", name = "bootstrap" })
  Assert.isNil(pending, "an unanswered request observes no readiness")
  service:injectReply({ op = "request-result", epoch = epoch, requestId = first, state = "ready" })
  service:update()
  local ready, failure = service:observe(epoch, { requestKind = "milestone", name = "bootstrap" })
  Assert.isTrue(ready, "the pushed ready event lands in the matching cached observation")
  Assert.isNil(failure, "a ready observation carries no failure")
  local stillPending, _ = service:observe(epoch, { requestKind = "milestone", name = "field-planning" })
  Assert.isNil(stillPending, "an unrelated request stays pending after another request completes")
  service:injectReply({
    op = "request-result",
    epoch = epoch,
    requestId = second,
    state = "failed",
    errorMessage = "background production failed",
  })
  service:update()
  local failedReady, failedCause = service:observe(epoch, { requestKind = "milestone", name = "field-planning" })
  Assert.isFalse(failedReady, "a failed request reports no readiness")
  Assert.isTrue(
    tostring(failedCause):find("background production failed", 1, true) ~= nil,
    "the pushed failure carries its cause: " .. tostring(failedCause)
  )
  service:shutdown()
end

function T.pushed_barrier_answers_settle_only_the_exact_waiter()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  service:request(epoch, { requestKind = "milestone", name = "bootstrap", urgency = "required" })
  service:update()
  local retireBarrier = assert(service:retire(epoch), "retirement returns its barrier identity")
  local quiesceBarrier = assert(service:quiesce(epoch), "quiescence follows retirement on the same epoch")
  Assert.equal(service:barrierStatus(epoch, retireBarrier), "pending", "retirement waits for its pushed answer")
  service:injectReply({ op = "barrier-result", epoch = epoch, barrierId = retireBarrier, kind = "retire" })
  service:update()
  Assert.equal(service:barrierStatus(epoch, retireBarrier), "ready", "the exact retirement answer lands")
  Assert.equal(
    service:barrierStatus(epoch, quiesceBarrier),
    "pending",
    "the retirement answer never settles quiescence"
  )
  service:injectReply({ op = "barrier-result", epoch = epoch, barrierId = retireBarrier, kind = "quiesce" })
  service:update()
  Assert.equal(
    service:barrierStatus(epoch, quiesceBarrier),
    "pending",
    "an older barrier identity never satisfies a newer waiter"
  )
  service:injectReply({ op = "barrier-result", epoch = epoch, barrierId = quiesceBarrier, kind = "quiesce" })
  service:update()
  Assert.equal(service:barrierStatus(epoch, quiesceBarrier), "ready", "the exact quiescence answer lands")
  local ok, _ = service:importSource(epoch, quiesceBarrier)
  Assert.isTrue(ok, "an acknowledged quiescence barrier authorizes import")
  local again, _ = service:importSource(epoch, quiesceBarrier)
  Assert.isFalse(again, "the quiescence barrier authorizes exactly one import")
  service:shutdown()
end

function T.pushed_controller_failure_fails_pending_observations_terminally()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  service:request(epoch, { requestKind = "milestone", name = "bootstrap", urgency = "required" })
  service:update()
  service:injectReply({ op = "controller-failure", errorMessage = "cache worker exploded" })
  service:update()
  local ready, failure = service:observe(epoch, { requestKind = "milestone", name = "bootstrap" })
  Assert.isNil(ready, "a failed controller reports no readiness")
  Assert.isTrue(
    tostring(failure):find("cache worker exploded", 1, true) ~= nil,
    "pending observations carry the pushed failure cause: " .. tostring(failure)
  )
  Assert.isNil(
    service:request(epoch, { requestKind = "milestone", name = "field-planning", urgency = "required" }),
    "a failed controller takes no new requests"
  )
  Assert.equal(host.threads[1].starts, 1, "a failed controller is never silently restarted")
  service:shutdown()
  Assert.equal(host.threads[1].waits, 1, "process shutdown joins the controller exactly once")
end

function T.selection_generation_comes_only_from_the_selection_answer()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local epoch = assert(service:select({ versionId = "heartgold", development = true }))
  service:request(epoch, { requestKind = "milestone", name = "bootstrap", urgency = "required" })
  service:update()
  service:injectReply({ op = "select-result", epoch = epoch, ok = true, generationId = "g4:test:token" })
  service:update()
  Assert.equal(service:generationId(epoch), "g4:test:token", "the selection answer publishes its generation token")
  service:injectReply({
    op = "request-result",
    epoch = epoch,
    requestId = 1,
    state = "ready",
    generationId = "g4:test:rotated",
  })
  service:update()
  Assert.equal(service:generationId(epoch), "g4:test:token", "request completion never rotates the token")
  service:injectReply({
    op = "poll-result",
    roundId = 7,
    epoch = epoch,
    count = 0,
    generationId = "g4:test:rotated",
  })
  service:update()
  Assert.equal(service:generationId(epoch), "g4:test:token", "no later status round rotates the token")
  service:shutdown()
end

function T.stale_pushed_results_never_enter_a_new_selection()
  local Service = requireService()
  local host = newChannelHost()
  local service = assert(Service.new({ thread = host }))
  local first = assert(service:select({ versionId = "heartgold", development = true }))
  local firstRequest =
    assert(service:request(first, { requestKind = "milestone", name = "bootstrap", urgency = "required" }))
  service:update()
  local firstBarrier = assert(service:retire(first), "retirement returns its barrier identity")
  local second = assert(service:select({ versionId = "heartgold", development = true }))
  service:injectReply({ op = "select-result", epoch = second, ok = true, generationId = "g4:test:second" })
  service:update()
  service:injectReply({ op = "request-result", epoch = first, requestId = firstRequest, state = "ready" })
  service:injectReply({ op = "barrier-result", epoch = first, barrierId = firstBarrier, kind = "retire" })
  service:injectReply({ op = "select-result", epoch = first, ok = true, generationId = "g4:test:late" })
  service:update()
  local ready, failure = service:observe(second, { requestKind = "milestone", name = "bootstrap" })
  Assert.isNil(ready, "an obsolete-epoch reply authorizes no new-epoch transition")
  Assert.isNil(failure, "an obsolete-epoch reply reports no new-epoch failure")
  Assert.equal(
    service:generationId(second),
    "g4:test:second",
    "a late answer for a retired epoch never enters the new selection"
  )
  service:shutdown()
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
