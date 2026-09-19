-- Cold-cache application composition below the full journeys: the menu
-- lists validated display envelopes without deep validation or generated
-- caches, semantic incompatibility still rejects at load, game switches
-- retire the old epoch on one shared process pool, raw replacement waits
-- for source quiescence, and location planning reuses the committed
-- footprint while the halo stays a near 5x5 interest.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local SaveFs = require("libs.storage.src.SaveFs")
local GameSave = require("libs.hgss.src.save.GameSave")
local BagSave = require("libs.hgss.src.save.BagSave")
local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
local MainMenuState = require("game.hgss.src.menu.MainMenuState")
local FieldCoverage = require("libs.hgss.src.world.FieldCoverage")
local MonsSave = require("libs.mons.src.MonsSave")
local CachePreparationState = require("app.src.launcher.CachePreparationState")
local VersionSelectState = require("app.src.launcher.VersionSelectState")

local T = {}

local VERSION = "heartgold"

local function record(saveId, overrides)
  local value = {
    schema = GameSave.SCHEMA,
    saveId = saveId,
    versionId = VERSION,
    playTimeSeconds = 61,
    mapId = 60,
    fieldX = 684,
    fieldZ = 393,
    worldY = 0,
    surfaceId = 0,
    terrainDependencyHash = "terrain-heartgold",
    facing = "south",
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 0, money = 3000 },
      options = { textFrame = 0, textSpeed = "mid" },
    },
    world = { flags = {}, variables = {}, objects = {}, rng = { state = 1, calls = 0 } },
    scripts = {},
    bag = BagSave.empty(),
    auxiliaryUi = { requested = "shown", state = "shown" },
    audio = {},
    mons = MonsSave.empty("test-catalog-fingerprint", 7),
  }
  for key, override in pairs(overrides or {}) do
    value[key] = override
  end
  return value
end

local function countingStore(backend)
  local calls = { validate = 0, cacheReads = {} }
  local reader = backend.read
  local reading = backend
  function reading.read(_, path)
    if type(path) == "string" and path:sub(1, 6) ~= "saves/" then
      calls.cacheReads[#calls.cacheReads + 1] = path
    end
    return reader(backend, path)
  end
  local store = GameSaveStore.new(SaveFs.global(backend), {
    recordValidate = function(candidate)
      calls.validate = calls.validate + 1
      return GameSave.validate(candidate)
    end,
  })
  return store, calls
end

function T.menu_listing_reads_display_envelopes_without_deep_validation()
  local backend = FakeCache.new()
  local store, calls = countingStore(backend)
  local saveId = store:reserve()
  store:publishFirst(record(saveId))
  Assert.equal(calls.validate, 1, "first publication deep-validates once")

  Assert.isTrue(
    type(store.listMetadata) == "function",
    "menu listing reads validated display envelopes through GameSaveStore.listMetadata without deep validation"
  )
  local entries = store:listMetadata()
  Assert.equal(#entries, 1, "metadata listing preserves catalog ordering")
  local entry = entries[1]
  Assert.equal(entry.saveId, saveId)
  Assert.equal(entry.versionId, VERSION)
  Assert.equal(assert(entry.playerData and entry.playerData.profile).name, "GOLD")
  Assert.equal(entry.playTimeSeconds, 61)
  Assert.isNil(entry.error, "a valid envelope lists no error")
  Assert.equal(calls.validate, 1, "metadata listing performs no deep validation")
  Assert.deepEqual(calls.cacheReads, {}, "metadata listing reads no generated caches")

  local results = {}
  local renderer = {
    draw = function() end,
    dispose = function() end,
  }
  local menu = MainMenuState.new({
    saveStore = {
      listMetadata = function()
        return entries
      end,
    },
    readyVersions = { VERSION },
    width = 640,
    height = 480,
    renderer = renderer,
    onResult = function(result)
      results[#results + 1] = result
    end,
  })
  local card = menu:view().saves[1]
  Assert.equal(card.saveId, saveId)
  Assert.equal(card.playerName, "GOLD")
  Assert.isTrue(card.canContinue, "a displayed record stays continuable while the cache is cold")
  menu:keypressed("return")
  Assert.deepEqual(
    results,
    { { kind = "continue", saveId = saveId } },
    "Continue stays an intent, not a validity claim"
  )
end

function T.incompatible_save_reports_semantic_rejection_not_cache_acceptance()
  local backend = FakeCache.new()
  local store = GameSaveStore.new(SaveFs.global(backend))
  local saveId = store:reserve()
  store:publishFirst(record(saveId))

  Assert.isTrue(
    type(store.listMetadata) == "function",
    "metadata listing keeps display data distinct from semantic validity"
  )
  local before = store:listMetadata()
  Assert.equal(#before, 1)
  Assert.equal(before[1].saveId, saveId)
  Assert.isNil(before[1].error, "listing never marks a record corrupt for missing generated data")

  local semanticFailure = Errors.new("SCRIPT_REGISTRY_MISMATCH", "script registry is incompatible")
  local drifted = GameSaveStore.new(SaveFs.global(backend), {
    recordValidate = function(_)
      return nil, semanticFailure
    end,
  })
  local ok, failure = pcall(function()
    return drifted:load(saveId)
  end)
  Assert.isFalse(ok, "semantic incompatibility still rejects at load")
  Assert.isTrue(Errors.is(failure), "the rejection is a structured error")
  Assert.equal(failure.code, "SCRIPT_REGISTRY_MISMATCH", "deep save errors stay semantic, never cache-versionmarked")
  local after = store:listMetadata()
  Assert.deepEqual(after, before, "a rejected load rewrites neither the payload nor its display envelope")
end

local function withAppStubs(fn)
  local App = require("app.src.App")
  local InteractiveCacheBuild = require("romdump.src.build.InteractiveCacheBuild")
  local HgssGame = require("game.hgss.src.HgssGame")
  local RomImporter = require("romdump.src.source.RomImporter")
  local Store = require("libs.hgss.src.save.GameSaveStore")
  local original = {
    state = App.state,
    importer = App.importer,
    provisioner = App.provisioner,
    opts = App.opts,
    saveDir = App.saveDir,
    buildNew = InteractiveCacheBuild.new,
    gameNew = HgssGame.new,
    isReady = RomImporter.isReady,
    storeNew = Store.new,
    dimensions = love.graphics.getDimensions,
  }
  local context = { sessions = {}, games = {}, importers = {} }
  App.opts = { dev = false }
  App.state = nil
  App.importer = nil
  App.provisioner = nil
  if App.pool ~= nil then
    pcall(function()
      App.pool:shutdown()
    end)
  end
  App.pool = nil
  App.epoch = 0
  App.saveDir = "test-save-dir"
  RomImporter.isReady = function(_)
    return true
  end
  love.graphics.getDimensions = function()
    return 640, 480
  end
  rawset(Store, "new", function()
    return {
      list = function()
        return {}
      end,
    }
  end)
  InteractiveCacheBuild.new = function(options)
    local session = {
      options = options,
      updates = 0,
      retired = 0,
      disposed = 0,
      update = function(self)
        self.updates = self.updates + 1
      end,
      retire = function(self)
        self.retired = self.retired + 1
      end,
      dispose = function(self)
        self.disposed = self.disposed + 1
      end,
      requestMilestone = function(_)
        return true
      end,
      status = function(_)
        return { bootstrap = "ready" }
      end,
    }
    context.sessions[#context.sessions + 1] = session
    return session
  end
  HgssGame.new = function(_)
    local game = {
      disposed = 0,
      dispose = function(self)
        self.disposed = self.disposed + 1
      end,
    }
    context.games[#context.games + 1] = game
    return game
  end
  local ok, err = pcall(fn, App, context)
  InteractiveCacheBuild.new = original.buildNew
  HgssGame.new = original.gameNew
  RomImporter.isReady = original.isReady
  rawset(Store, "new", original.storeNew)
  love.graphics.getDimensions = original.dimensions
  App.state = original.state
  App.importer = original.importer
  App.provisioner = original.provisioner
  App.opts = original.opts
  App.saveDir = original.saveDir
  if not ok then
    error(err, 0)
  end
end

function T.game_switch_retires_the_old_epoch_on_the_shared_process_pool()
  withAppStubs(function(App, context)
    App._bootMainMenu({ VERSION })
    App._bootMainMenu({ VERSION })
    Assert.equal(#context.sessions, 2, "each game selection constructs its session")
    local first, second = context.sessions[1], context.sessions[2]
    Assert.notNil(first.options.pool, "the application owns one process-owned compiler pool across game switches")
    Assert.equal(second.options.pool, first.options.pool, "a switch reuses the pool instead of spawning a second")
    Assert.equal(first.options.epoch, 1)
    Assert.equal(second.options.epoch, 2, "returning to a game mints a new epoch even when the generation matches")
    Assert.equal(first.retired + first.disposed, 1, "the old epoch retires exactly once without joining workers")
    Assert.equal(#context.games, 2)
    Assert.equal(context.games[1].disposed, 1, "switching disposes the old game consumer")
  end)
end

function T.replacement_rom_waits_for_source_quiescence_before_raw_mutation()
  withAppStubs(function(App, _)
    local RomImporter = require("romdump.src.source.RomImporter")
    local originalNew = RomImporter.new
    local importerCalls = { constructed = 0, filedropped = 0 }
    rawset(RomImporter, "new", function(_)
      importerCalls.constructed = importerCalls.constructed + 1
      return {
        state = "busy",
        isBusy = function()
          return true
        end,
        update = function() end,
        filedropped = function()
          importerCalls.filedropped = importerCalls.filedropped + 1
        end,
      }
    end)
    local disposals = 0
    App.provisioner = {
      update = function() end,
      dispose = function()
        disposals = disposals + 1
      end,
    }
    local poolWas = App.pool
    local quiescent = false
    local quiesces = 0
    local poolPumps = 0
    App.pool = {
      quiesce = function()
        quiesces = quiesces + 1
      end,
      isQuiescent = function()
        return quiescent
      end,
      update = function()
        poolPumps = poolPumps + 1
      end,
      diagnostics = function()
        return { error = nil }
      end,
    }
    local ok, err = pcall(function()
      App.filedropped({ name = "replacement.zip" })
      Assert.isNil(App.importer, "raw replacement waits for source closure instead of mutating the dump")
      Assert.notNil(App.state, "quiescence waits through a visible preparation state")
      Assert.equal(disposals, 1, "the drop retires selected interest before the barrier")
      Assert.equal(quiesces, 1, "the drop stops admission before waiting")
      Assert.isNil(App.provisioner, "retired interest detaches while the barrier drains")
      local waiting = App.state
      App.update(1 / 60)
      Assert.isTrue(poolPumps > 0, "input and progress keep pumping while source readers drain")
      Assert.isNil(App.importer, "pumping never starts the importer before closure")
      App.filedropped({ name = "second.zip" })
      Assert.equal(App.state, waiting, "a repeated drop while waiting never replaces the pending file")
      Assert.equal(quiesces, 1, "a repeated drop issues no second barrier")
      quiescent = true
      App.update(1 / 60)
      Assert.equal(importerCalls.constructed, 1, "the importer starts once the source is closed")
      Assert.equal(importerCalls.filedropped, 1, "the dropped file forwards to the importer once")
      App.update(1 / 60)
      Assert.equal(importerCalls.constructed, 1, "settling never starts a second import")
    end)
    rawset(RomImporter, "new", originalNew)
    App.state = nil
    App.importer = nil
    App.provisioner = nil
    App.pool = poolWas
    if not ok then
      error(err, 0)
    end
  end)
end

local function syntheticIndex()
  local cells = {}
  local function cell(x, z)
    return { x = x, z = z, file = "cells/" .. x .. "_" .. z .. ".lua" }
  end
  for offsetZ = -2, 2 do
    for offsetX = -2, 2 do
      local radius = math.max(math.abs(offsetX), math.abs(offsetZ))
      if radius <= 1 then
        if not (offsetX == 1 and offsetZ == 0) then
          cells[#cells + 1] = cell(10 + offsetX, 10 + offsetZ)
        end
      elseif not (offsetX == -2 and offsetZ == 2) then
        cells[#cells + 1] = cell(10 + offsetX, 10 + offsetZ)
      end
    end
  end
  return { matrices = { { matrixMemberId = 7, cells = cells } } }
end

local function keySet(descriptors)
  local keys = {}
  for _, descriptor in ipairs(descriptors) do
    keys[#keys + 1] = descriptor.x .. ":" .. descriptor.z
  end
  table.sort(keys)
  return keys
end

function T.location_requests_reuse_the_committed_footprint_and_keep_the_halo()
  local index = syntheticIndex()
  Assert.isTrue(
    type(FieldCoverage.descriptorsAt) == "function",
    "location planning reuses one authoritative committed-descriptor selector"
  )
  local committed = FieldCoverage.descriptorsAt(index, 7, 10, 10)
  Assert.deepEqual(
    keySet(committed),
    { "10:10", "10:11", "10:9", "11:11", "11:9", "9:10", "9:11", "9:9" },
    "the committed footprint is exactly the radius-1 selection with holes excluded"
  )
  local coverage = setmetatable({ index = index, matrixMemberId = 7 }, { __index = FieldCoverage })
  Assert.deepEqual(
    coverage:descriptorsFor(10, 10),
    committed,
    "coverage delegates to the same selector instead of duplicating spatial logic"
  )
  local halo = coverage:prefetchDescriptors(10, 10)
  local haloKeys = keySet(halo)
  Assert.equal(#haloKeys, 23, "the halo stays 5x5 with holes excluded")
  local haloSet = {}
  for _, key in ipairs(haloKeys) do
    haloSet[key] = true
  end
  for _, key in ipairs(keySet(committed)) do
    Assert.isTrue(haloSet[key] == true, "the halo contains the committed footprint")
  end

  local requests = {}
  local prefetching = setmetatable({
    index = index,
    matrixMemberId = 7,
    anchorX = 10,
    anchorZ = 10,
    cells = {},
    prefetched = {},
    prefetchQueue = {},
    pendingPrefetch = nil,
    derivedAssets = {
      -- The semantic host is dot-called (plain functions, no self), matching
      -- every production consumer of the host.
      requestCell = function(descriptor, urgency)
        requests[#requests + 1] = { descriptor = descriptor, urgency = urgency }
        return true
      end,
      ensureCell = function() end,
    },
  }, { __index = FieldCoverage })
  prefetching:queuePrefetch(10, 10)
  Assert.equal(#requests, 15, "only halo-exclusive cells ride prefetch")
  local committedKeys = {}
  for _, key in ipairs(keySet(committed)) do
    committedKeys[key] = true
  end
  for _, request in ipairs(requests) do
    local key = request.descriptor.x .. ":" .. request.descriptor.z
    Assert.isNil(committedKeys[key], "committed cells never ride prefetch")
    Assert.equal(request.urgency, "near", "halo prefetch rides near interest, never required")
  end
end

function T.provisioner_wraps_a_selected_session_with_string_urgencies_and_retires_it()
  local InteractiveCacheBuild = require("romdump.src.build.InteractiveCacheBuild")
  local Provisioner = require("app.src.DerivedAssetProvisioner")
  local originalNew = InteractiveCacheBuild.new
  local built = {}
  local retired = 0
  local poolShutdowns = 0
  local pool = {
    shutdown = function()
      poolShutdowns = poolShutdowns + 1
    end,
  }
  local seen = {}
  local fakeSession = {
    update = function() end,
  }
  function fakeSession:requestMilestone(name, urgency)
    seen.milestone = { name = name, urgency = urgency }
    return true
  end
  function fakeSession:requestField(mapId, urgency)
    seen.field = { mapId = mapId, urgency = urgency }
    return true
  end
  function fakeSession:ensureField(mapId)
    seen.ensureField = mapId
    return true
  end
  function fakeSession:requestCell(descriptor, urgency)
    seen.cell = { descriptor = descriptor, urgency = urgency }
    return true
  end
  function fakeSession:ensureCell(descriptor)
    seen.ensureCell = descriptor
    return true
  end
  function fakeSession:requestMonPortraitPage(pageId, urgency)
    seen.page = { pageId = pageId, urgency = urgency }
    return true
  end
  function fakeSession:status()
    return { bootstrap = "ready" }
  end
  function fakeSession:retire()
    retired = retired + 1
  end
  InteractiveCacheBuild.new = function(options)
    built[#built + 1] = options
    return fakeSession
  end
  local ok, err = pcall(function()
    local provisioner = Provisioner.new({
      versionId = "heartgold",
      producerFingerprint = "r1",
      pool = pool,
      epoch = 3,
    })
    local sessionOptions = assert(built[1])
    Assert.equal(sessionOptions.epoch, 3)
    Assert.equal(sessionOptions.pool, pool)
    Assert.isTrue(sessionOptions.sweepEnabled)
    Assert.equal(assert(sessionOptions.identity).versionId, "heartgold")
    local host = provisioner:gameHost()
    Assert.isTrue(host.requestMilestone("bootstrap", "required"))
    Assert.deepEqual(seen.milestone, { name = "bootstrap", urgency = "required" })
    Assert.isTrue(host.requestField(60, "required"))
    Assert.deepEqual(seen.field, { mapId = 60, urgency = "required" })
    local descriptor = { matrixMemberId = 0, index = 14 }
    Assert.isTrue(host.requestCell(descriptor, "near"))
    Assert.equal(seen.cell.descriptor, descriptor)
    Assert.equal(seen.cell.urgency, "near")
    Assert.isTrue(host.requestMonPortraitPage(0, "required"))
    Assert.deepEqual(seen.page, { pageId = 0, urgency = "required" })
    provisioner:update()
    provisioner:dispose()
    Assert.equal(retired, 1, "disposal retires the session")
    Assert.equal(poolShutdowns, 0, "disposal never touches the process pool")
    local retiredOk, retiredErr = pcall(host.requestField, 60, "required")
    Assert.isFalse(retiredOk, "retired host calls reject")
    Assert.isTrue(Errors.is(retiredErr), "the rejection is a structured lifecycle error")
    Assert.equal(retiredErr.code, "DERIVED_ASSETS_RETIRED")
  end)
  InteractiveCacheBuild.new = originalNew
  if not ok then
    error(err, 0)
  end
end

-- Selection/import ownership through the real production composition: the
-- application, its provisioner, the generation session and the process pool
-- stay real while only thread transport, game launch, raw import, producer
-- fingerprinting and graphics text are controlled. A ready user-owned dump
-- is required so the real session can plan against genuine source data;
-- without one these scenarios skip instead of proving anything.
--
-- The harness selects the development identity so every scenario starts
-- from a genuinely cold generation even where the release corpus is warm:
-- no derived output exists yet for the working-tree digest, so bootstrap
-- waits through the visible preparation flow instead of launching at once.
-- Controlled worker threads never execute: dispatched jobs stay in their
-- worker slots until the test answers through the result channel, so pending
-- sweep interest, running work and the source-close barrier are fully
-- deterministic. The busy worker below stands in for any executing size
-- class behind the same barrier path.

---@return table controlled thread/channel host with dispatch traffic logs
local function newControlledThreadHost()
  local host = { dispatched = {}, channels = {}, threads = {}, demandCalls = 0 }
  ---@return table fresh channel with traffic logging
  local function newChannel()
    local values = {}
    local channel = { log = {} }
    function channel:push(value)
      values[#values + 1] = value
      channel.log[#channel.log + 1] = value
      if type(value) == "table" and value.jobKey ~= nil and value.status == nil then
        host.dispatched[#host.dispatched + 1] = value
      end
      return true
    end
    function channel:pop()
      if #values == 0 then
        return nil
      end
      return table.remove(values, 1)
    end
    function channel:demand(_)
      host.demandCalls = host.demandCalls + 1
      return channel:pop()
    end
    function channel:getCount()
      return #values
    end
    host.channels[#host.channels + 1] = channel
    return channel
  end
  local function spawnThread()
    local thread = { starts = 0, waits = 0, alive = true, threadError = nil }
    function thread:start()
      self.starts = self.starts + 1
    end
    function thread:wait()
      self.waits = self.waits + 1
    end
    function thread:getError()
      return self.threadError
    end
    function thread:isRunning()
      return self.starts > 0 and self.alive
    end
    host.threads[#host.threads + 1] = thread
    return thread
  end
  host.newChannel = newChannel
  host.newThread = function()
    return spawnThread()
  end
  return host
end

---@param App table application singleton under test
---@param rounds integer
local function pumpApp(App, rounds)
  for _ = 1, rounds do
    App.update(1 / 60)
  end
end

---@param harness table live-app harness
---@return table result channel shared by every worker
local function resultChannel(harness)
  return assert(harness.threadHost.channels[1], "the pool must create a result channel first")
end

---@param harness table live-app harness
---@param workerId integer
---@return table input channel owned by that worker
local function inputChannel(harness, workerId)
  return assert(harness.threadHost.channels[1 + workerId], "missing input channel for worker " .. tostring(workerId))
end

---@param harness table live-app harness
---@param workerId integer
---@return table|nil most recently dispatched job still awaiting its reply
local function lastDispatchedJob(harness, workerId)
  local log = inputChannel(harness, workerId).log
  for index = #log, 1, -1 do
    local message = log[index]
    if type(message) == "table" and message.jobKey ~= nil and message.status == nil then
      return message
    end
  end
  return nil
end

---@param harness table live-app harness
---@param workerId integer
---@param pool table process-owned compiler pool for status checks
local function failRunningOnWorker(harness, workerId, pool)
  local job = assert(lastDispatchedJob(harness, workerId), "worker has no dispatched job to fail")
  local state = pool:status(job.jobKey)
  if state ~= "running" and state ~= "prepared" then
    return
  end
  resultChannel(harness):push({
    status = "failed",
    workerId = workerId,
    epoch = job.epoch,
    generationId = job.generationId,
    kind = job.kind,
    key = job.key,
    jobKey = job.jobKey,
    stageName = job.stageName,
    error = "synthetic worker failure",
  })
end

---@param App table application singleton under test
---@param harness table live-app harness
local function failEveryRunningWorker(App, harness)
  local pool = assert(App.pool, "physical work requires the process pool")
  for workerId in ipairs(harness.threadHost.threads) do
    if lastDispatchedJob(harness, workerId) ~= nil then
      failRunningOnWorker(harness, workerId, pool)
    end
  end
end

-- Answers every close barrier the pool has sent so far with a matching
-- token, exactly as a draining worker would.
---@param harness table live-app harness
local function ackCloseContexts(harness)
  local result = resultChannel(harness)
  for workerId in ipairs(harness.threadHost.threads) do
    local token = nil
    local log = inputChannel(harness, workerId).log
    for index = #log, 1, -1 do
      local message = log[index]
      if type(message) == "table" and message.kind == "close-context" then
        token = message.closeToken
        break
      end
    end
    if token ~= nil then
      result:push({ status = "context-closed", workerId = workerId, closeToken = token })
    end
  end
end

-- Drives the source-close barrier to completion: failing terminal work
-- releases busy slots with a pending close, and each pump collects the next
-- acknowledgement round until the importer starts or the budget is spent.
---@param App table application singleton under test
---@param harness table live-app harness
---@param rounds integer
local function drainBarrier(App, harness, rounds)
  for _ = 1, rounds do
    if #harness.importers > 0 then
      return
    end
    failEveryRunningWorker(App, harness)
    ackCloseContexts(harness)
    pumpApp(App, 1)
  end
end

---@param host table borrowed selected session host
---@return integer first map identity the source supports
local function supportedFieldMapId(host)
  for mapId = 0, 1200 do
    local ok, ready, failure = pcall(host.requestField, mapId, "required")
    if ok and (ready or failure == nil) then
      return mapId
    end
  end
  error("no supported field map for the selection", 0)
end

---@param context table runner context for capability skips
---@param fn fun(App: table, harness: table)
local function withLiveApp(context, fn)
  local RomImporter = require("romdump.src.source.RomImporter")
  if not RomImporter.isReady(VERSION) then
    context:skip("no ready user-owned HGSS dump")
  end
  local App = require("app.src.App")
  local HgssGame = require("game.hgss.src.HgssGame")
  local ProducerFingerprint = require("romdump.src.ProducerFingerprint")
  local realLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local original = {
    state = App.state,
    importer = App.importer,
    provisioner = App.provisioner,
    opts = App.opts,
    saveDir = App.saveDir,
    pool = App.pool,
    epoch = App.epoch,
    drawableWidth = App.drawableWidth,
    drawableHeight = App.drawableHeight,
    gameNew = HgssGame.new,
    importerNew = RomImporter.new,
    appBackend = ProducerFingerprint.appBackend,
    checkoutBackend = ProducerFingerprint.checkoutBackend,
    quit = realLove.event.quit,
    print = realLove.graphics.print,
  }
  if App.pool ~= nil then
    pcall(function()
      App.pool:shutdown()
    end)
  end
  App.opts = { dev = true }
  App.state = nil
  App.importer = nil
  App.provisioner = nil
  App.pool = nil
  App.epoch = 0
  App.saveDir = "test-save-dir"
  App.drawableWidth, App.drawableHeight = 640, 480
  -- A fixed synthetic producer tree keeps the development digest
  -- deterministic and fast; selection ownership never depends on its bytes.
  ProducerFingerprint.appBackend = function()
    return {
      list = function()
        return {}
      end,
      read = function()
        error("the empty source fixture has no files")
      end,
      getInfo = function(path)
        if path == "romdump/src" then
          return { type = "directory" }
        end
        return nil
      end,
    }
  end
  ProducerFingerprint.checkoutBackend = function(_)
    return {
      list = function()
        return { "build/Compiler.lua" }
      end,
      read = function(_)
        return "selection ownership fixture"
      end,
      getInfo = function(path)
        if path == "romdump/src" then
          return { type = "directory" }
        end
        return nil
      end,
    }
  end
  local harness = { launches = {}, importers = {}, quitCodes = {}, prints = {}, threadHost = newControlledThreadHost() }
  local threadHost = harness.threadHost
  HgssGame.new = function(options)
    harness.launches[#harness.launches + 1] = options
    local game = { disposed = 0 }
    function game:dispose()
      self.disposed = self.disposed + 1
    end
    return game
  end
  RomImporter.new = function(options)
    local importer = { filedroppedCalls = 0, updates = 0, state = "waiting" }
    if type(options) == "table" then
      importer.onComplete = options.onComplete
    end
    function importer:isBusy()
      return false
    end
    function importer:update()
      self.updates = self.updates + 1
    end
    function importer:filedropped(_)
      self.filedroppedCalls = self.filedroppedCalls + 1
    end
    harness.importers[#harness.importers + 1] = importer
    return importer
  end
  realLove.event.quit = function(code)
    harness.quitCodes[#harness.quitCodes + 1] = code
  end
  realLove.graphics.print = function(text, _, _)
    harness.prints[#harness.prints + 1] = tostring(text)
  end
  rawset(
    _G,
    "love",
    setmetatable({
      thread = {
        newChannel = function()
          return threadHost.newChannel()
        end,
        newThread = function()
          return threadHost.newThread()
        end,
      },
      system = {
        getProcessorCount = function()
          return 5
        end,
      },
    }, { __index = realLove })
  )
  local ok, err = pcall(fn, App, harness)
  rawset(_G, "love", realLove)
  HgssGame.new = original.gameNew
  RomImporter.new = original.importerNew
  ProducerFingerprint.appBackend = original.appBackend
  ProducerFingerprint.checkoutBackend = original.checkoutBackend
  realLove.event.quit = original.quit
  realLove.graphics.print = original.print
  local pool = App.pool
  App.state = original.state
  App.importer = original.importer
  App.provisioner = original.provisioner
  App.opts = original.opts
  App.saveDir = original.saveDir
  App.pool = original.pool
  App.epoch = original.epoch
  App.drawableWidth = original.drawableWidth
  App.drawableHeight = original.drawableHeight
  if pool ~= nil and pool ~= original.pool then
    pcall(function()
      pool:shutdown()
    end)
  end
  if not ok then
    error(err, 0)
  end
end

---@param App table application singleton under test
---@param versionId string
---@return table attached provisioner
local function selectVersion(App, versionId)
  App._selectVersion(versionId)
  return assert(App.provisioner, "selection must attach a provisioner")
end

function T.drop_during_pending_work_retires_interest_before_source_closure(context)
  withLiveApp(context, function(App, harness)
    local provisioner = selectVersion(App, VERSION)
    local host = provisioner:gameHost()
    local mapId = supportedFieldMapId(host)
    pumpApp(App, 6)
    local before = assert(App.pool, "selection must own a pool"):diagnostics()
    Assert.isTrue(before.counts.running > 0, "the selection must have physical work in flight")
    local dispatchedBeforeDrop = #harness.threadHost.dispatched
    Assert.isTrue(dispatchedBeforeDrop > 0, "pending work must have reached worker input")
    App.filedropped({})
    Assert.isNil(App.importer, "raw replacement must wait for source closure instead of mutating the dump")
    Assert.notNil(App.state, "the drop waits through a visible preparation state")
    Assert.equal(
      getmetatable(App.state).__index,
      CachePreparationState,
      "the drop waits through the preparation state while readers drain"
    )
    -- In-flight game input through the retained host must reject as retired
    -- instead of admitting new interest into the quiescing pool.
    local retiredOk, retiredErr = pcall(host.requestField, mapId, "required")
    Assert.isFalse(retiredOk, "the dropped selection must retire its host before the barrier")
    Assert.isTrue(Errors.is(retiredErr), "the retired rejection is a structured lifecycle error")
    Assert.equal(retiredErr.code, "DERIVED_ASSETS_RETIRED")
    pumpApp(App, 3)
    Assert.equal(
      #harness.threadHost.dispatched,
      dispatchedBeforeDrop,
      "no admission occurs after quiesce while the UI keeps pumping"
    )
    Assert.isNil(App.importer, "pumping never starts the importer before source closure")
    drainBarrier(App, harness, 10)
    Assert.equal(#harness.importers, 1, "the importer starts exactly once after source closure")
    Assert.equal(harness.importers[1].filedroppedCalls, 1, "the dropped file forwards to the importer once")
  end)
end

function T.cancelled_selection_still_guards_raw_import_behind_source_closure(context)
  withLiveApp(context, function(App, harness)
    local provisioner = selectVersion(App, VERSION)
    local host = provisioner:gameHost()
    supportedFieldMapId(host)
    pumpApp(App, 6)
    local pool = assert(App.pool, "selection must own a pool")
    Assert.isTrue(pool:diagnostics().counts.running > 0, "cancelled work must stay physically charged")
    assert(App.state, "selection must install a preparation state"):keypressed("escape", nil, nil)
    Assert.isNil(App.provisioner, "cancellation detaches the selection back to the selector")
    Assert.equal(App.pool, pool, "cancellation preserves the process-owned pool")
    Assert.isTrue(pool:diagnostics().counts.running > 0, "cancelled physical work stays charged to the pool")
    Assert.equal(getmetatable(App.state).__index, VersionSelectState, "cancellation returns to the version selector")
    App.filedropped({})
    Assert.isNil(App.importer, "a selector drop waits for the source barrier with old readers outstanding")
    pumpApp(App, 2)
    Assert.isNil(App.importer, "pumping never starts the importer before source closure")
    drainBarrier(App, harness, 10)
    Assert.equal(#harness.importers, 1, "raw import starts exactly once after the barrier")
    Assert.equal(harness.importers[1].filedroppedCalls, 1, "the dropped file forwards to the importer once")
    Assert.equal(pool:diagnostics().counts.ready, 0, "old terminal work never publishes through the barrier")
  end)
end

function T.same_version_reselection_reuses_one_pool_with_fresh_interest(context)
  withLiveApp(context, function(App, harness)
    -- One production route: a cold boot-menu entry waits through selection
    -- instead of launching the game directly.
    App._bootMainMenu({ VERSION })
    Assert.equal(#harness.launches, 0, "a cold boot-menu entry must wait for preparation, not launch directly")
    Assert.equal(
      getmetatable(App.state).__index,
      CachePreparationState,
      "a cold boot-menu entry follows the same selection flow"
    )
    local pool = assert(App.pool, "selection must own a pool")
    local firstEpoch = assert(App.epoch, "selection must mint an epoch")
    local firstHost = assert(App.provisioner, "selection must attach a provisioner"):gameHost()
    local mapId = supportedFieldMapId(firstHost)
    pumpApp(App, 6)
    assert(App.state, "selection must install a preparation state"):keypressed("escape", nil, nil)
    local second = selectVersion(App, VERSION)
    Assert.equal(App.pool, pool, "reselection reuses the one process pool")
    Assert.isTrue(App.epoch > firstEpoch, "reselection mints a fresh epoch on the shared pool")
    Assert.equal(pool:diagnostics().selected.epoch, App.epoch, "the pool tracks the reselected epoch")
    -- The old interest is retired exactly once: its host rejects, repeated
    -- disposal is safe, and the new host serves fresh interest.
    local retiredOk, retiredErr = pcall(firstHost.requestField, mapId, "required")
    Assert.isFalse(retiredOk, "old interest retires when the selection moves on")
    Assert.isTrue(Errors.is(retiredErr), "the retired rejection is a structured lifecycle error")
    Assert.equal(retiredErr.code, "DERIVED_ASSETS_RETIRED")
    local secondHost = second:gameHost()
    local ready, failure = secondHost.requestField(mapId, "required")
    Assert.isFalse(ready, "fresh interest starts pending, never satisfied by old work")
    Assert.isNil(failure, "fresh interest carries no failure from the retired epoch")
    -- A late completion stamped with the retired epoch cannot satisfy the
    -- reselected interest waiting under the same job identity.
    local stale = nil
    local staleWorker = nil
    for _, workerId in ipairs({ 1, 2 }) do
      stale = lastDispatchedJob(harness, workerId)
      if stale ~= nil then
        staleWorker = workerId
        break
      end
    end
    local answered = assert(stale, "the retired epoch must have dispatched work to answer late")
    resultChannel(harness):push({
      status = "prepared",
      workerId = assert(staleWorker, "a stale dispatch needs its worker"),
      epoch = firstEpoch,
      generationId = answered.generationId,
      kind = answered.kind,
      key = answered.key,
      jobKey = answered.jobKey,
      stageName = answered.stageName,
    })
    pumpApp(App, 2)
    local state, _ = pool:status(answered.jobKey)
    Assert.isTrue(state ~= "ready", "late old-epoch output cannot publish for the new interest")
    Assert.equal(pool:diagnostics().counts.ready, 0, "no obsolete output publishes through reselection")
  end)
end

function T.worker_failure_surfaces_in_preparation_without_further_requests(context)
  withLiveApp(context, function(App, harness)
    local RomImporter = require("romdump.src.source.RomImporter")
    local provisioner = selectVersion(App, VERSION)
    local host = provisioner:gameHost()
    supportedFieldMapId(host)
    pumpApp(App, 6)
    Assert.isTrue(
      assert(App.pool, "selection must own a pool"):diagnostics().counts.running > 0,
      "the preparation must have physical work in flight"
    )
    local dispatchedBeforeFailure = #harness.threadHost.dispatched
    -- A genuine worker death behind running work, observed through the
    -- controlled transport rather than a staged session error.
    local crashed = nil
    for workerId in ipairs(harness.threadHost.threads) do
      if lastDispatchedJob(harness, workerId) ~= nil then
        crashed = workerId
        break
      end
    end
    Assert.notNil(crashed, "a busy worker is required to fail behind the preparation view")
    local thread = harness.threadHost.threads[assert(crashed)]
    thread.alive = false
    thread.threadError = "synthetic worker crash"
    pumpApp(App, 1)
    pumpApp(App, 3)
    Assert.equal(
      #harness.threadHost.dispatched,
      dispatchedBeforeFailure,
      "no further producer requests occur after the infrastructure failure"
    )
    Assert.notNil(
      assert(App.pool, "selection must own a pool"):diagnostics().error,
      "the pool records the infrastructure failure"
    )
    local state = assert(App.state, "the preparation view stays installed through the failure")
    state:draw()
    local shown = false
    for _, text in ipairs(harness.prints) do
      if text:lower():find("fail", 1, true) ~= nil then
        shown = true
        break
      end
    end
    Assert.isTrue(shown, "the preparation view presents the failure instead of crashing")
    state:keypressed("escape", nil, nil)
    Assert.equal(
      getmetatable(App.state).__index,
      VersionSelectState,
      "cancellation after failure returns to the version selector"
    )
    Assert.isNil(App.importer, "cancellation after failure modifies no raw files")
    Assert.equal(#harness.importers, 0, "cancellation after failure starts no import")
    Assert.isTrue(RomImporter.isReady(VERSION), "the previous raw dump is untouched by the failed preparation")
  end)
end

function T.quit_after_cancelled_preparation_joins_owned_workers_once(context)
  withLiveApp(context, function(App, harness)
    local provisioner = selectVersion(App, VERSION)
    local host = provisioner:gameHost()
    supportedFieldMapId(host)
    pumpApp(App, 6)
    local pool = assert(App.pool, "selection must own a pool")
    Assert.isTrue(pool:diagnostics().counts.running > 0, "cancelled work must stay physically charged")
    assert(App.state, "selection must install a preparation state"):keypressed("escape", nil, nil)
    Assert.isNil(App.provisioner, "no provisioner remains after cancellation")
    -- A late prepared reply for the retired epoch is discarded, never
    -- published, even though its worker slot still matches. This settles
    -- before any other failure so the reply still finds its slot.
    local stale = nil
    local staleWorker = nil
    for workerId in ipairs(harness.threadHost.threads) do
      stale = lastDispatchedJob(harness, workerId)
      if stale ~= nil then
        staleWorker = workerId
        break
      end
    end
    local answered = assert(stale, "retired work is required to answer late")
    resultChannel(harness):push({
      status = "prepared",
      workerId = assert(staleWorker, "a stale dispatch needs its worker"),
      epoch = answered.epoch,
      generationId = answered.generationId,
      kind = answered.kind,
      key = answered.key,
      jobKey = answered.jobKey,
      stageName = answered.stageName,
    })
    pumpApp(App, 1)
    local staleState, _ = pool:status(answered.jobKey)
    Assert.equal(staleState, "cancelled", "late old-epoch output cannot publish after retirement")
    Assert.equal(pool:diagnostics().counts.ready, 0, "obsolete outputs never publish")
    -- Physical lifecycle keeps moving with no session attached: terminal
    -- work settles instead of lingering on the detached pool.
    failEveryRunningWorker(App, harness)
    pumpApp(App, 2)
    Assert.equal(
      pool:diagnostics().counts.running,
      0,
      "detached updates settle old physical work without reviving the session"
    )
    Assert.isNil(App.provisioner, "settling detached work never reattaches a session")
    App.quit()
    for _, thread in ipairs(harness.threadHost.threads) do
      Assert.equal(thread.waits, 1, "each owned thread joins exactly once")
    end
    Assert.isNil(App.pool, "quit releases the process pool")
    Assert.isNil(App.provisioner, "quit leaves no selection behind")
    App.quit()
    for _, thread in ipairs(harness.threadHost.threads) do
      Assert.equal(thread.waits, 1, "a repeated quit never rejoins owned threads")
    end
  end)
end

function T.selection_switch_to_another_version_reuses_the_pool_with_a_fresh_epoch()
  withAppStubs(function(App, context)
    App._selectVersion(VERSION)
    App._selectVersion("soulsilver")
    Assert.equal(#context.sessions, 2, "each game selection constructs its session")
    local first, second = context.sessions[1], context.sessions[2]
    Assert.equal(second.options.pool, first.options.pool, "a switch reuses the pool instead of spawning a second")
    Assert.equal(first.options.epoch, 1)
    Assert.equal(second.options.epoch, 2, "switching versions mints a new epoch on the shared pool")
    Assert.equal(first.retired, 1, "the old interest retires exactly once without joining workers")
    Assert.equal(#context.games, 2, "a ready selection launches its menu through the single route")
  end)
end

function T.dropped_file_before_any_worker_starts_a_fresh_import()
  withAppStubs(function(App, _)
    local RomImporter = require("romdump.src.source.RomImporter")
    local ImportState = require("app.src.launcher.ImportState")
    local originalNew = RomImporter.new
    local calls = { constructed = 0, filedropped = 0 }
    rawset(RomImporter, "new", function(_)
      calls.constructed = calls.constructed + 1
      return {
        state = "waiting",
        isBusy = function()
          return false
        end,
        update = function() end,
        filedropped = function()
          calls.filedropped = calls.filedropped + 1
        end,
      }
    end)
    local ok, err = pcall(function()
      Assert.isNil(App.pool, "no worker exists before the first selection")
      App.filedropped({ name = "first.nds" })
      Assert.equal(calls.constructed, 1, "a drop with no pool starts an import immediately")
      Assert.equal(calls.filedropped, 1, "the dropped file forwards to the fresh importer")
      Assert.equal(getmetatable(App.state).__index, ImportState, "the drop enters through the import state")
    end)
    rawset(RomImporter, "new", originalNew)
    App.state = nil
    App.importer = nil
    if not ok then
      error(err, 0)
    end
  end)
end

function T.failed_source_closure_blocks_raw_mutation_and_stays_cancellable()
  withAppStubs(function(App, _)
    local RomImporter = require("romdump.src.source.RomImporter")
    local originalNew = RomImporter.new
    local constructed = 0
    rawset(RomImporter, "new", function(_)
      constructed = constructed + 1
      return {
        state = "waiting",
        isBusy = function()
          return false
        end,
        update = function() end,
        filedropped = function() end,
      }
    end)
    App.provisioner = {
      update = function() end,
      dispose = function() end,
    }
    local poolWas = App.pool
    App.pool = {
      quiesce = function() end,
      isQuiescent = function()
        return false
      end,
      update = function() end,
      diagnostics = function()
        return { error = "synthetic source close failure" }
      end,
    }
    local graphics = love.graphics
    local originalPrint = graphics.print
    local originalPrintf = graphics.printf
    local prints = {}
    graphics.print = function(text, _, _)
      prints[#prints + 1] = tostring(text)
    end
    graphics.printf = function(text, _, _, _)
      prints[#prints + 1] = tostring(text)
    end
    local ok, err = pcall(function()
      App.filedropped({ name = "replacement.zip" })
      App.update(1 / 60)
      App.update(1 / 60)
      Assert.equal(constructed, 0, "no raw mutation begins after an unsuccessful barrier")
      local waiting = assert(App.state, "the waiting view stays installed through the failure")
      waiting:draw()
      local shown = false
      for _, text in ipairs(prints) do
        if text:lower():find("fail", 1, true) ~= nil then
          shown = true
          break
        end
      end
      Assert.isTrue(shown, "the waiting view presents the barrier failure instead of importing")
      waiting:keypressed("escape", nil, nil)
      Assert.equal(
        getmetatable(App.state).__index,
        VersionSelectState,
        "cancellation after barrier failure returns to the version selector"
      )
      Assert.equal(constructed, 0, "cancelling the failed wait starts no import")
    end)
    graphics.print = originalPrint
    graphics.printf = originalPrintf
    rawset(RomImporter, "new", originalNew)
    App.state = nil
    App.importer = nil
    App.provisioner = nil
    App.pool = poolWas
    if not ok then
      error(err, 0)
    end
  end)
end

function T.repeated_dispose_and_quit_release_owned_resources_once()
  withAppStubs(function(App, context)
    App._selectVersion(VERSION)
    local provisioner = assert(App.provisioner, "selection must attach a provisioner")
    provisioner:dispose()
    provisioner:dispose()
    Assert.equal(context.sessions[1].retired, 1, "repeated disposal retires the session exactly once")
    local realPool = App.pool
    if realPool ~= nil then
      pcall(function()
        realPool:shutdown()
      end)
    end
    local shutdowns = 0
    App.pool = {
      shutdown = function()
        shutdowns = shutdowns + 1
      end,
    }
    App.quit()
    App.quit()
    Assert.equal(shutdowns, 1, "repeated quit joins owned workers exactly once")
    Assert.isNil(App.pool, "quit releases the process pool")
    Assert.isNil(App.provisioner, "quit leaves no selection behind")
  end)
end

-- Selection behind an outstanding source-close barrier, without any
-- user-owned dump. The harness below keeps the real production composition
-- (App, provisioner, generation session, process pool) while only the true
-- host boundaries are controlled: worker threads/channels never execute, the
-- installed-version readiness probe is stubbed to ready, and every cache
-- write lands on an isolated in-memory backend. Nothing here reads a ROM.
---@param fn fun(App: table, harness: table)
local function withIsolatedApp(fn)
  local App = require("app.src.App")
  local HgssGame = require("game.hgss.src.HgssGame")
  local RomImporter = require("romdump.src.source.RomImporter")
  local ProducerFingerprint = require("romdump.src.ProducerFingerprint")
  local CacheFs = require("libs.storage.src.CacheFs")
  local realLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local original = {
    state = App.state,
    importer = App.importer,
    provisioner = App.provisioner,
    opts = App.opts,
    saveDir = App.saveDir,
    pool = App.pool,
    epoch = App.epoch,
    drawableWidth = App.drawableWidth,
    drawableHeight = App.drawableHeight,
    gameNew = HgssGame.new,
    importerNew = RomImporter.new,
    isReady = RomImporter.isReady,
    appBackend = ProducerFingerprint.appBackend,
    checkoutBackend = ProducerFingerprint.checkoutBackend,
    quit = realLove.event.quit,
    print = realLove.graphics.print,
    printf = realLove.graphics.printf,
    forVersion = CacheFs.forVersion,
    forStaging = CacheFs.forStaging,
    forArtifactStage = CacheFs.forArtifactStage,
    dimensions = love.graphics.getDimensions,
  }
  if App.pool ~= nil then
    pcall(function()
      App.pool:shutdown()
    end)
  end
  App.opts = { dev = true }
  App.state = nil
  App.importer = nil
  App.provisioner = nil
  App.pool = nil
  App.epoch = 0
  App.saveDir = "test-save-dir"
  App.drawableWidth, App.drawableHeight = 640, 480
  -- Stubbed installed-version readiness: both versions report ready without
  -- consulting any user-owned dump.
  RomImporter.isReady = function(_)
    return true
  end
  -- A fixed synthetic producer tree keeps the development digest
  -- deterministic and fast; selection ownership never depends on its bytes.
  ProducerFingerprint.appBackend = function()
    return {
      list = function()
        return {}
      end,
      read = function()
        error("the empty source fixture has no files")
      end,
      getInfo = function(path)
        if path == "romdump/src" then
          return { type = "directory" }
        end
        return nil
      end,
    }
  end
  ProducerFingerprint.checkoutBackend = function(_)
    return {
      list = function()
        return { "build/Compiler.lua" }
      end,
      read = function(_)
        return "selection ownership fixture"
      end,
      getInfo = function(path)
        if path == "romdump/src" then
          return { type = "directory" }
        end
        return nil
      end,
    }
  end
  -- Isolated cache writes: every version-scoped cache lands on one private
  -- in-memory backend instead of the product save directory.
  local isolated = FakeCache.new()
  rawset(CacheFs, "forVersion", function(versionId, backend)
    return original.forVersion(versionId, backend or isolated)
  end)
  rawset(CacheFs, "forStaging", function(versionId, backend)
    return original.forStaging(versionId, backend or isolated)
  end)
  rawset(CacheFs, "forArtifactStage", function(versionId, name, backend)
    return original.forArtifactStage(versionId, name, backend or isolated)
  end)
  local harness = { launches = {}, importers = {}, quitCodes = {}, prints = {}, threadHost = newControlledThreadHost() }
  local threadHost = harness.threadHost
  HgssGame.new = function(options)
    harness.launches[#harness.launches + 1] = options
    local game = { disposed = 0 }
    function game:dispose()
      self.disposed = self.disposed + 1
    end
    return game
  end
  RomImporter.new = function(options)
    local importer = { filedroppedCalls = 0, updates = 0, state = "waiting" }
    if type(options) == "table" then
      importer.onComplete = options.onComplete
    end
    function importer:isBusy()
      return false
    end
    function importer:update()
      self.updates = self.updates + 1
    end
    function importer:filedropped(_)
      self.filedroppedCalls = self.filedroppedCalls + 1
    end
    harness.importers[#harness.importers + 1] = importer
    return importer
  end
  realLove.event.quit = function(code)
    harness.quitCodes[#harness.quitCodes + 1] = code
  end
  realLove.graphics.print = function(text, _, _)
    harness.prints[#harness.prints + 1] = tostring(text)
  end
  realLove.graphics.printf = function(text, _, _, _)
    harness.prints[#harness.prints + 1] = tostring(text)
  end
  love.graphics.getDimensions = function()
    return 640, 480
  end
  rawset(
    _G,
    "love",
    setmetatable({
      thread = {
        newChannel = function()
          return threadHost.newChannel()
        end,
        newThread = function()
          return threadHost.newThread()
        end,
      },
      system = {
        getProcessorCount = function()
          return 5
        end,
      },
    }, { __index = realLove })
  )
  local ok, err = pcall(fn, App, harness)
  rawset(_G, "love", realLove)
  HgssGame.new = original.gameNew
  RomImporter.new = original.importerNew
  RomImporter.isReady = original.isReady
  ProducerFingerprint.appBackend = original.appBackend
  ProducerFingerprint.checkoutBackend = original.checkoutBackend
  realLove.event.quit = original.quit
  realLove.graphics.print = original.print
  realLove.graphics.printf = original.printf
  love.graphics.getDimensions = original.dimensions
  rawset(CacheFs, "forVersion", original.forVersion)
  rawset(CacheFs, "forStaging", original.forStaging)
  rawset(CacheFs, "forArtifactStage", original.forArtifactStage)
  local pool = App.pool
  App.state = original.state
  App.importer = original.importer
  App.provisioner = original.provisioner
  App.opts = original.opts
  App.saveDir = original.saveDir
  App.pool = original.pool
  App.epoch = original.epoch
  App.drawableWidth = original.drawableWidth
  App.drawableHeight = original.drawableHeight
  if pool ~= nil and pool ~= original.pool then
    pcall(function()
      pool:shutdown()
    end)
  end
  if not ok then
    error(err, 0)
  end
end

-- Drives the source-close barrier toward completion without starting any raw
-- import or firing any pending selection: failing terminal work releases busy
-- slots with a pending close, and each round collects the next acknowledgement
-- round until the pool reports quiescence or the budget is spent. Only the
-- pool is pumped here; the waiting view observes the completed barrier through
-- a later visible pump, so the surviving continuation fires exactly once.
---@param App table application singleton under test
---@param harness table isolated-app harness
---@param rounds integer
local function drainSelectionBarrier(App, harness, rounds)
  for _ = 1, rounds do
    local pool = assert(App.pool, "physical work requires the process pool")
    if App.provisioner ~= nil or pool:isQuiescent() then
      return
    end
    failEveryRunningWorker(App, harness)
    ackCloseContexts(harness)
    pool:update()
  end
end

---@param App table application singleton under test
---@return boolean outstanding true while the pool barrier is incomplete
local function barrierOutstanding(App)
  local pool = assert(App.pool, "physical work requires the process pool")
  local diagnostics = pool:diagnostics()
  return diagnostics.quiescing == true and not pool:isQuiescent()
end

function T.selection_waits_behind_source_closure_then_selects_once()
  withIsolatedApp(function(App, harness)
    local provisioner = selectVersion(App, VERSION)
    local host = provisioner:gameHost()
    host.requestMilestone("bootstrap", "required")
    pumpApp(App, 6)
    local pool = assert(App.pool, "selection must own a pool")
    Assert.isTrue(pool:diagnostics().counts.running > 0, "the selection must have physical work in flight")
    local epochBefore = assert(App.epoch, "selection must mint an epoch")
    App.filedropped({ name = "dropped.zip" })
    local tokenBefore = pool.closeToken
    Assert.isNil(App.importer, "the drop waits for source closure instead of importing")
    Assert.equal(
      getmetatable(assert(App.state, "the drop waits visibly")).__index,
      CachePreparationState,
      "the drop waits through the preparation state"
    )
    assert(App.state, "the drop waits visibly"):keypressed("escape", nil, nil)
    Assert.equal(
      getmetatable(assert(App.state, "cancellation returns visibly")).__index,
      VersionSelectState,
      "cancelling the import wait returns to the selector"
    )
    Assert.equal(App.pool, pool, "cancellation keeps the one process pool")
    Assert.isTrue(barrierOutstanding(App), "physical closure stays outstanding after cancelling the import wait")
    local pendingOk, pendingErr = pcall(App._selectVersion, VERSION)
    Assert.isTrue(
      pendingOk,
      "selection behind an outstanding barrier must wait instead of raising: " .. tostring(pendingErr)
    )
    Assert.isNil(App.provisioner, "the pending selection constructs no provisioner before closure")
    Assert.equal(App.epoch, epochBefore, "the pending selection mints no epoch before closure")
    Assert.equal(App.pool, pool, "the pending selection starts no second pool")
    Assert.equal(pool.closeToken, tokenBefore, "the pending selection issues no second barrier")
    Assert.equal(
      getmetatable(assert(App.state, "the pending selection waits visibly")).__index,
      CachePreparationState,
      "the pending selection waits through the preparation state"
    )
    Assert.equal(App.state.kind, "quiescence", "the pending selection waits on source closure")
    -- Replacing the pending choice keeps only the later continuation.
    assert(App.state, "the pending selection waits visibly"):keypressed("escape", nil, nil)
    local replaceOk, replaceErr = pcall(App._selectVersion, "soulsilver")
    Assert.isTrue(replaceOk, "a replacement selection must wait instead of raising: " .. tostring(replaceErr))
    Assert.isNil(App.provisioner, "the replacement constructs no provisioner before closure")
    Assert.equal(App.epoch, epochBefore, "the replacement mints no epoch before closure")
    Assert.equal(pool.closeToken, tokenBefore, "the replacement issues no second barrier")
    drainSelectionBarrier(App, harness, 12)
    Assert.isTrue(pool:isQuiescent(), "the barrier completes")
    pumpApp(App, 3)
    local selected = assert(App.provisioner, "exactly one surviving selection attaches after closure")
    Assert.equal(App.pool, pool, "the surviving selection reuses the one process pool")
    Assert.equal(App.epoch, epochBefore + 1, "the surviving selection mints exactly one fresh epoch")
    Assert.equal(pool:diagnostics().selected.epoch, App.epoch, "the pool tracks the surviving epoch")
    Assert.equal(pool:diagnostics().selected.versionId, "soulsilver", "only the latest live choice selects")
    Assert.isTrue(selected == App.provisioner, "no further selection replaces the survivor")
    Assert.equal(#harness.importers, 0, "the cancelled dropped file is never imported")
    Assert.equal(#harness.launches, 0, "a cold surviving selection still waits on bootstrap, never launches")
  end)
end

function T.only_the_live_pending_selection_fires_and_quit_joins_once()
  withIsolatedApp(function(App, harness)
    local provisioner = selectVersion(App, VERSION)
    provisioner:gameHost().requestMilestone("bootstrap", "required")
    pumpApp(App, 6)
    local pool = assert(App.pool, "selection must own a pool")
    local epochBefore = assert(App.epoch, "selection must mint an epoch")
    App.filedropped({ name = "dropped.zip" })
    assert(App.state, "the drop waits visibly"):keypressed("escape", nil, nil)
    local firstOk, firstErr = pcall(App._selectVersion, VERSION)
    Assert.isTrue(firstOk, "the first pending selection must wait instead of raising: " .. tostring(firstErr))
    local firstWait = assert(App.state, "the first pending selection waits visibly")
    assert(firstWait, "the first pending selection waits visibly"):keypressed("escape", nil, nil)
    Assert.isNil(App.provisioner, "cancelling the pending selection attaches nothing")
    local secondOk, secondErr = pcall(App._selectVersion, "soulsilver")
    Assert.isTrue(secondOk, "the replacement selection must wait instead of raising: " .. tostring(secondErr))
    local secondWait = assert(App.state, "the replacement waits visibly")
    Assert.isTrue(secondWait ~= firstWait, "the replacement installs its own wait")
    drainSelectionBarrier(App, harness, 12)
    Assert.isTrue(pool:isQuiescent(), "the barrier completes")
    pumpApp(App, 3)
    Assert.isTrue(firstWait.dead, "the cancelled wait can never fire late")
    Assert.isTrue(secondWait.fired, "the live wait fires exactly once")
    Assert.equal(App.epoch, epochBefore + 1, "exactly one surviving selection mints one epoch")
    Assert.equal(pool:diagnostics().selected.versionId, "soulsilver", "only the latest live choice executes")
    Assert.equal(#harness.importers, 0, "no import starts through the pending selections")
    -- A fresh barrier with a pending choice quits safely: nothing deferred
    -- may run and every owned worker joins exactly once.
    assert(App.provisioner, "the survivor attaches a provisioner"):gameHost().requestMilestone("bootstrap", "required")
    pumpApp(App, 4)
    App.filedropped({ name = "late.zip" })
    assert(App.state, "the late drop waits visibly"):keypressed("escape", nil, nil)
    local lateOk, lateErr = pcall(App._selectVersion, VERSION)
    Assert.isTrue(lateOk, "the late pending selection must wait instead of raising: " .. tostring(lateErr))
    local lateWait = assert(App.state, "the late pending selection waits visibly")
    local epochAtQuit = assert(App.epoch, "quitting never selects")
    local threadCount = #harness.threadHost.threads
    Assert.isTrue(threadCount > 0, "quit must own workers to join")
    App.quit()
    Assert.isTrue(lateWait.dead, "quit disposes the pending continuation before shutdown")
    Assert.isNil(App.pool, "quit releases the process pool")
    Assert.isNil(App.provisioner, "quit leaves no selection behind")
    Assert.equal(#harness.importers, 0, "quit executes no deferred import")
    Assert.equal(App.epoch, epochAtQuit, "quit executes no deferred selection")
    for _, thread in ipairs(harness.threadHost.threads) do
      Assert.equal(thread.waits, 1, "each owned thread joins exactly once")
    end
    App.quit()
    for _, thread in ipairs(harness.threadHost.threads) do
      Assert.equal(thread.waits, 1, "a repeated quit never rejoins owned threads")
    end
  end)
end

function T.failed_source_closure_keeps_the_pending_wait_visible_and_safe()
  withIsolatedApp(function(App, harness)
    local provisioner = selectVersion(App, VERSION)
    provisioner:gameHost().requestMilestone("bootstrap", "required")
    pumpApp(App, 6)
    local pool = assert(App.pool, "selection must own a pool")
    local epochBefore = assert(App.epoch, "selection must mint an epoch")
    App.filedropped({ name = "dropped.zip" })
    assert(App.state, "the drop waits visibly"):keypressed("escape", nil, nil)
    Assert.isTrue(barrierOutstanding(App), "physical closure stays outstanding after cancelling the import wait")
    -- Settle terminal work so the barrier advances to waiting close
    -- acknowledgements, then fail one close-waiting worker for a genuine
    -- source-close failure observed through the controlled transport.
    failEveryRunningWorker(App, harness)
    pumpApp(App, 1)
    -- A genuine source-close failure behind the barrier, observed through the
    -- controlled transport rather than a staged pool error.
    local closed = false
    for workerId, worker in ipairs(pool.workers) do
      if worker.closeSent and not worker.closeAcked then
        local thread = harness.threadHost.threads[workerId]
        thread.alive = false
        thread.threadError = "synthetic source close failure"
        closed = true
        break
      end
    end
    Assert.isTrue(closed, "the barrier must have a close-waiting worker to fail")
    pumpApp(App, 2)
    Assert.notNil(pool:diagnostics().error, "the pool records the source-close failure")
    local pendingOk, pendingErr = pcall(App._selectVersion, VERSION)
    Assert.isTrue(
      pendingOk,
      "selection behind a failed barrier must wait safely instead of raising: " .. tostring(pendingErr)
    )
    Assert.isNil(App.provisioner, "the failed barrier permits no provisioner")
    Assert.equal(App.epoch, epochBefore, "the failed barrier permits no epoch")
    Assert.equal(App.pool, pool, "the failed barrier starts no replacement pool")
    pumpApp(App, 2)
    local waiting = assert(App.state, "the failed wait stays installed")
    Assert.equal(
      getmetatable(waiting).__index,
      CachePreparationState,
      "the failed barrier waits through the preparation state"
    )
    waiting:draw()
    local shown = false
    for _, text in ipairs(harness.prints) do
      if text:lower():find("fail", 1, true) ~= nil then
        shown = true
        break
      end
    end
    Assert.isTrue(shown, "the waiting view presents the barrier failure instead of selecting")
    Assert.isNil(App.provisioner, "presenting the failure selects nothing")
    Assert.equal(#harness.importers, 0, "presenting the failure imports nothing")
    waiting:keypressed("escape", nil, nil)
    Assert.equal(
      getmetatable(assert(App.state, "cancellation returns visibly")).__index,
      VersionSelectState,
      "cancellation after barrier failure returns to the version selector"
    )
    Assert.isNil(App.provisioner, "cancelling the failed wait selects nothing")
    Assert.equal(#harness.importers, 0, "cancelling the failed wait starts no import")
    Assert.equal(App.pool, pool, "cancelling the failed wait keeps the one pool")
  end)
end

return { tests = T }
