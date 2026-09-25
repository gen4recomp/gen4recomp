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
local FirstPlayCompletion = require("romdump.src.FirstPlayCompletion")

-- Hermetic completion answers for live-controller tests: the suites own
-- controller/threading contracts, not attestation currency, so ordinary
-- selections keep their established bootstrap paths while no real
-- attestation file is read or written. Tests that own currency set the
-- context fields before selecting.
local function stubFirstPlayCompletion(context)
  context.firstPlayCurrent = true
  context.firstPlayStored = true
  context.firstPlayPublished = {}
  local originalIsCurrent = FirstPlayCompletion.isCurrent
  local originalHasStored = FirstPlayCompletion.hasStored
  local originalPublish = FirstPlayCompletion.publish
  FirstPlayCompletion.isCurrent = function(_, _)
    return context.firstPlayCurrent
  end
  FirstPlayCompletion.hasStored = function()
    return context.firstPlayStored
  end
  FirstPlayCompletion.publish = function(versionId, generationId)
    context.firstPlayPublished[#context.firstPlayPublished + 1] = { versionId = versionId, generationId = generationId }
  end
  return { isCurrent = originalIsCurrent, hasStored = originalHasStored, publish = originalPublish }
end

local function restoreFirstPlayCompletion(originals)
  FirstPlayCompletion.isCurrent = originals.isCurrent
  FirstPlayCompletion.hasStored = originals.hasStored
  FirstPlayCompletion.publish = originals.publish
end

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

-- Synthetic service behind the relocated controller: epochs are minted
-- locally, requests only record, and warmup authorization appends its
-- lifecycle event so menu ordering stays observable without threads.
local function newMenuService(events)
  local epoch = 0
  local service = {}
  function service:select(_)
    epoch = epoch + 1
    return epoch
  end
  function service:request(_, _) end
  function service:observe(_, _)
    return nil, nil
  end
  function service:enableSweep(_)
    events[#events + 1] = "provisioner:startBackgroundWarmup"
  end
  function service:update() end
  function service:retire(_) end
  return service
end

local function withAppStubs(fn)
  local App = require("app.src.App")
  local HgssGame = require("game.hgss.src.HgssGame")
  local RomImporter = require("romdump.src.source.RomImporter")
  local Store = require("libs.hgss.src.save.GameSaveStore")
  local original = {
    state = App.state,
    importer = App.importer,
    provisioner = App.provisioner,
    service = App.service,
    epoch = App.epoch,
    pendingQuiesce = App.pendingQuiesce,
    opts = App.opts,
    saveDir = App.saveDir,
    gameNew = HgssGame.new,
    isReady = RomImporter.isReady,
    storeNew = Store.new,
    dimensions = love.graphics.getDimensions,
  }
  local context = {
    games = {},
    importers = {},
    epochs = {},
    requests = {},
    retires = {},
    observations = {},
    barriers = {},
    imports = {},
    selectOptions = {},
    warmups = 0,
    quiesces = 0,
    updates = 0,
  }
  local epoch = 0
  local barrier = 0
  local service = {}
  function service:select(options)
    epoch = epoch + 1
    context.epochs[#context.epochs + 1] = epoch
    context.selectOptions[#context.selectOptions + 1] = options
    return epoch
  end
  function service:request(epochArg, selector)
    context.requests[#context.requests + 1] = { epoch = epochArg, selector = selector }
  end
  function service:observe(epochArg, selector)
    local key = selector.requestKind
      .. ":"
      .. tostring(selector.name or selector.mapId or selector.pageId)
      .. ":"
      .. tostring(selector.matrixMemberId)
      .. ":"
      .. tostring(selector.index)
    local _ = epochArg
    local scripted = context.observations[key]
    if scripted ~= nil then
      return scripted.ready, scripted.failure
    end
    if selector.requestKind == "milestone" and selector.name == "bootstrap" then
      return true, nil
    end
    return nil, nil
  end
  function service:enableSweep(_)
    context.warmups = context.warmups + 1
  end
  function service:update()
    context.updates = context.updates + 1
  end
  function service:retire(epochArg)
    context.retires[#context.retires + 1] = epochArg
  end
  function service:quiesce(epochArg)
    barrier = barrier + 1
    context.quiesces = context.quiesces + 1
    context.barriers[barrier] = { epoch = epochArg, status = "pending" }
    return barrier
  end
  function service:barrierStatus(epochArg, barrierArg)
    local waiter = context.barriers[barrierArg]
    if waiter == nil or waiter.epoch ~= epochArg then
      return nil
    end
    return waiter.status
  end
  function service:generationId(_)
    return context.cannedGeneration
  end
  function service:importSource(epochArg, barrierArg)
    local waiter = context.barriers[barrierArg]
    if waiter == nil or waiter.epoch ~= epochArg or waiter.status ~= "ready" then
      return false, "unacknowledged"
    end
    context.barriers[barrierArg] = nil
    context.imports[#context.imports + 1] = { epoch = epochArg, barrier = barrierArg }
    return true
  end
  function service:shutdown()
    if context.shutdown then
      return
    end
    context.shutdown = true
    context.joins = (context.joins or 0) + 1
  end
  context.service = service
  App.opts = { dev = false }
  App.state = nil
  App.importer = nil
  App.provisioner = nil
  App.service = service
  App.epoch = 0
  App.saveDir = "test-save-dir"
  RomImporter.isReady = function(_)
    return true
  end
  context.cannedGeneration = "test-generation"
  local completionOriginals = stubFirstPlayCompletion(context)
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
  HgssGame.new = original.gameNew
  RomImporter.isReady = original.isReady
  restoreFirstPlayCompletion(completionOriginals)
  rawset(Store, "new", original.storeNew)
  love.graphics.getDimensions = original.dimensions
  App.state = original.state
  App.importer = original.importer
  App.provisioner = original.provisioner
  App.service = original.service
  App.epoch = original.epoch
  App.pendingQuiesce = original.pendingQuiesce
  App.opts = original.opts
  App.saveDir = original.saveDir
  if not ok then
    error(err, 0)
  end
end

function T.game_switch_retires_the_old_epoch_on_the_shared_process_service()
  withAppStubs(function(App, context)
    local service = assert(App.service, "the application owns one process cache service")
    App._bootMainMenu({ VERSION })
    App._bootMainMenu({ VERSION })
    Assert.equal(App.service, service, "a switch reuses the service instead of spawning a second")
    Assert.deepEqual(context.epochs, { 1, 2 }, "returning to a game mints a new epoch even when the generation matches")
    Assert.deepEqual(context.retires, { 1 }, "the old epoch retires exactly once without joining workers")
    Assert.equal(#context.games, 2)
    Assert.equal(context.games[1].disposed, 1, "switching disposes the old game consumer")
    Assert.equal(context.warmups, 2, "each menu installation authorizes background completion once")
    Assert.isNil(context.shutdown, "switching never shuts down the process service")
  end)
end

function T.replacement_rom_waits_for_source_quiescence_before_raw_mutation()
  withAppStubs(function(App, context)
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
    local updatesBefore = context.updates
    local ok, err = pcall(function()
      App.filedropped({ name = "replacement.zip" })
      Assert.isNil(App.importer, "raw replacement waits for source closure instead of mutating the dump")
      Assert.notNil(App.state, "quiescence waits through a visible preparation state")
      Assert.equal(disposals, 1, "the drop retires selected interest before the barrier")
      Assert.equal(context.quiesces, 1, "the drop stops admission before waiting")
      Assert.isNil(App.provisioner, "retired interest detaches while the barrier drains")
      local waiting = App.state
      App.update(1 / 60)
      Assert.isTrue(context.updates > updatesBefore, "input and progress keep pumping while source readers drain")
      Assert.isNil(App.importer, "pumping never starts the importer before closure")
      App.filedropped({ name = "second.zip" })
      Assert.equal(App.state, waiting, "a repeated drop while waiting never replaces the pending file")
      Assert.equal(context.quiesces, 1, "a repeated drop issues no second barrier")
      assert(context.barriers[1] ~= nil, "the drop holds one quiescence barrier")
      context.barriers[1].status = "ready"
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
    App.pendingQuiesce = nil
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

function T.provisioner_wraps_a_selected_service_with_string_urgencies_and_retires_it()
  local Provisioner = require("app.src.DerivedAssetProvisioner")
  local seen = { requests = {}, shutdowns = 0 }
  local scripted = { ready = true, failure = nil }
  local fakeService = {}
  function fakeService:select(options)
    seen.select = options
    return 7
  end
  function fakeService:request(epoch, selector)
    seen.requests[#seen.requests + 1] = { epoch = epoch, selector = selector }
  end
  function fakeService:observe(epoch, selector)
    seen.lastObserve = { epoch = epoch, selector = selector }
    return scripted.ready, scripted.failure
  end
  function fakeService:enableSweep(epoch)
    seen.warmups = (seen.warmups or 0) + 1
    seen.warmupEpoch = epoch
  end
  function fakeService:update()
    seen.updates = (seen.updates or 0) + 1
  end
  function fakeService:retire(epoch)
    seen.retired = epoch
  end
  function fakeService:shutdown()
    seen.shutdowns = seen.shutdowns + 1
  end
  local ok, err = pcall(function()
    local provisioner = Provisioner.new({ versionId = "heartgold", service = fakeService })
    local selectOptions = assert(seen.select)
    Assert.equal(selectOptions.versionId, "heartgold")
    Assert.isNil(
      selectOptions.sweepEnabled,
      "exhaustive intent travels as an explicit request, never a construction flag"
    )
    local host = provisioner:gameHost()
    Assert.isTrue(host.requestMilestone("bootstrap", "required"))
    local milestone = assert(seen.requests[#seen.requests]).selector
    Assert.deepEqual(milestone, { requestKind = "milestone", name = "bootstrap", urgency = "required" })
    Assert.isTrue(host.requestField(60, "required"))
    local field = assert(seen.requests[#seen.requests]).selector
    Assert.deepEqual(field, { requestKind = "field", mapId = 60, urgency = "required" })
    local descriptor = { matrixMemberId = 0, index = 14 }
    Assert.isTrue(host.requestCell(descriptor, "near"))
    local cell = assert(seen.requests[#seen.requests]).selector
    Assert.equal(cell.matrixMemberId, 0)
    Assert.equal(cell.index, 14)
    Assert.equal(cell.urgency, "near")
    Assert.isTrue(host.requestMonPortraitPage(0, "required"))
    local page = assert(seen.requests[#seen.requests]).selector
    Assert.deepEqual(page, { requestKind = "portrait", pageId = 0, urgency = "required" })
    Assert.isTrue(host.requestIconPage(3, "required"))
    local iconPage = assert(seen.requests[#seen.requests]).selector
    Assert.deepEqual(iconPage, { requestKind = "icon-page", pageId = 3, urgency = "required" })
    local iconBadOk, _ = pcall(host.requestIconPage, -1, "required")
    Assert.isFalse(iconBadOk, "a negative icon page is rejected at the facade")
    scripted.ready, scripted.failure = nil, nil
    Assert.deepEqual(
      host.milestoneStatus("new-game-intro"),
      { state = "pending", ready = 0, total = nil },
      "the host forwards the milestone-local progress snapshot"
    )
    Assert.equal(seen.lastObserve.selector.name, "new-game-intro")
    Assert.isNil(host.startBackgroundWarmup, "warmup lifecycle stays off the semantic game host")
    Assert.isNil(host.enableSweep, "corpus authorization stays off the semantic game host")
    Assert.equal(type(provisioner.startBackgroundWarmup), "function", "the provisioner keeps its warmup seam")
    provisioner:startBackgroundWarmup()
    provisioner:startBackgroundWarmup()
    Assert.equal(seen.warmups, 2, "warmup authorization forwards without cache work")
    Assert.equal(seen.warmupEpoch, 7, "warmup authorization carries the borrowed epoch")
    provisioner:update()
    Assert.equal(seen.updates, 1, "provisioner updates pump service observations")
    provisioner:dispose()
    Assert.equal(seen.retired, 7, "disposal retires the borrowed epoch")
    Assert.equal(seen.shutdowns, 0, "disposal never shuts down the process service")
    local retiredOk, retiredErr = pcall(host.requestField, 60, "required")
    Assert.isFalse(retiredOk, "retired host calls reject")
    Assert.isTrue(Errors.is(retiredErr), "the rejection is a structured lifecycle error")
    Assert.equal(retiredErr.code, "DERIVED_ASSETS_RETIRED")
    local retiredProgressOk, retiredProgressErr = pcall(host.milestoneStatus, "new-game-intro")
    Assert.isFalse(retiredProgressOk, "retired progress observation rejects")
    Assert.isTrue(Errors.is(retiredProgressErr), "the progress rejection is a structured lifecycle error")
    Assert.equal(retiredProgressErr.code, "DERIVED_ASSETS_RETIRED")
  end)
  if not ok then
    error(err, 0)
  end
end

-- Menu installation authorizes background completion exactly once after the
-- state handoff: constructor, state installation, then warmup authorization.
-- A failed game constructor recovers to the selector without authorizing.
function T.menu_installation_authorizes_warmup_only_after_successful_handoff()
  local App = require("app.src.App")
  local HgssGame = require("game.hgss.src.HgssGame")
  local Provisioner = require("app.src.DerivedAssetProvisioner")
  local originalGameNew = HgssGame.new
  local originalSetState = App.setState
  local originalShowSelector = App._showVersionSelector
  local originalState = App.state
  local originalProvisioner = App.provisioner
  local originalOpts = App.opts
  App.opts = { dev = false }
  local events = {}
  local game = {
    update = function() end,
    dispose = function() end,
  }
  HgssGame.new = function(options)
    events[#events + 1] = "game:new"
    Assert.notNil(options.derivedAssets, "the menu game receives the semantic host")
    return game
  end
  App.setState = function(next)
    events[#events + 1] = "app:setState"
    originalSetState(next)
  end
  local ok, err = pcall(function()
    local provisioner = Provisioner.new({ versionId = "heartgold", service = newMenuService(events) })
    local host = provisioner:gameHost()
    Assert.isNil(host.startBackgroundWarmup, "warmup lifecycle stays off the semantic game host")
    Assert.isNil(host.enableSweep, "corpus authorization stays off the semantic game host")
    App.provisioner = provisioner
    App.state = nil
    App._launchMenuWithProvisioner("heartgold")
  end)
  local launchedState = App.state
  local launchedEvents = {}
  for _, event in ipairs(events) do
    launchedEvents[#launchedEvents + 1] = event
  end
  HgssGame.new = function()
    error("synthetic game failure", 0)
  end
  local selectorShown = 0
  App._showVersionSelector = function()
    selectorShown = selectorShown + 1
  end
  App.state = nil
  local failOk, failErr
  local innerOk, innerErr = pcall(function()
    failOk, failErr = pcall(App._launchMenuWithProvisioner, "heartgold")
  end)
  local failedSelectorShown = selectorShown
  HgssGame.new = originalGameNew
  App.setState = originalSetState
  App._showVersionSelector = originalShowSelector
  App.state = originalState
  App.provisioner = originalProvisioner
  App.opts = originalOpts
  if not ok then
    error(err, 0)
  end
  if not innerOk then
    error(innerErr, 0)
  end
  Assert.equal(launchedState, game, "the launched game becomes the process state")
  Assert.deepEqual(
    launchedEvents,
    { "game:new", "app:setState", "provisioner:startBackgroundWarmup" },
    "menu installation authorizes background completion after the state is installed"
  )
  Assert.isFalse(failOk, "a failed game constructor still surfaces its error")
  Assert.isTrue(
    tostring(failErr):find("synthetic game failure", 1, true) ~= nil,
    "the surfaced error is the game failure"
  )
  Assert.equal(failedSelectorShown, 1, "a failed launch recovers to the version selector")
end

-- Menu installation authorizes background warmup after the state handoff
-- through the owner-only seam. The game host never carries the control.
function T.menu_installation_authorizes_background_warmup_after_state_handoff()
  local App = require("app.src.App")
  local HgssGame = require("game.hgss.src.HgssGame")
  local Provisioner = require("app.src.DerivedAssetProvisioner")
  local originalGameNew = HgssGame.new
  local originalSetState = App.setState
  local originalState = App.state
  local originalProvisioner = App.provisioner
  local originalOpts = App.opts
  App.opts = { dev = false }
  local events = {}
  local enabled = 0
  local service = newMenuService(events)
  local realEnable = service.enableSweep
  function service:enableSweep(epoch)
    enabled = enabled + 1
    realEnable(self, epoch)
  end
  local game = {
    update = function() end,
    dispose = function() end,
  }
  HgssGame.new = function(options)
    events[#events + 1] = "game:new"
    Assert.notNil(options.derivedAssets, "the menu game receives the semantic host")
    return game
  end
  App.setState = function(next)
    events[#events + 1] = "app:setState"
    originalSetState(next)
  end
  local ok, err = pcall(function()
    local provisioner = Provisioner.new({ versionId = "heartgold", service = service })
    App.provisioner = provisioner
    App.state = nil
    App._launchMenuWithProvisioner("heartgold")
    Assert.equal(
      type(provisioner.startBackgroundWarmup),
      "function",
      "the provisioner keeps the owner-only warmup seam"
    )
  end)
  local launchedState = App.state
  HgssGame.new = originalGameNew
  App.setState = originalSetState
  App.state = originalState
  App.provisioner = originalProvisioner
  App.opts = originalOpts
  if not ok then
    error(err, 0)
  end
  Assert.equal(launchedState, game, "the launched game becomes the process state")
  Assert.deepEqual(
    events,
    { "game:new", "app:setState", "provisioner:startBackgroundWarmup" },
    "menu installation authorizes background warmup after the handoff"
  )
  Assert.equal(enabled, 1, "a successful launch authorizes the background cursor once")
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
---@param harness table live-app harness holding the attached controller worker
---@param rounds integer
local function pumpApp(App, harness, rounds)
  local worker = harness.worker
  for _ = 1, rounds do
    App.update(1 / 60)
    if worker ~= nil then
      worker:step()
    end
  end
end

-- Attaches the real controller to the service channels the selection
-- opened: the service created its command/reply pair first, so the worker
-- consumes the same two channels the game thread observes.
---@param harness table live-app harness holding the controlled thread host
---@return table test-driven controller worker sharing the service channels
local function attachWorker(harness)
  local Worker = require("romdump.src.build.CacheControllerWorker").Worker
  local channels = harness.threadHost.channels
  assert(#channels >= 2, "the service owns its command/reply channels before the worker attaches")
  local worker = Worker.new(channels[1], channels[2])
  harness.worker = worker
  -- Threads spawned so far are controller-side: the compiler pool boots
  -- only once the attached worker handles selection. Pool worker identity
  -- is therefore a thread position minus this prefix, never the raw
  -- controlled-thread index.
  harness.controllerThreads = #harness.threadHost.threads
  return worker
end

-- Pool worker identities owned by the attached controller, skipping the
-- controller-side spawns that share the controlled host.
---@param harness table live-app harness holding the attached controller worker
---@return integer[] compiler worker identities in spawn order
local function compilerWorkerIds(harness)
  local base = harness.controllerThreads or 0
  local ids = {}
  for position = base + 1, #harness.threadHost.threads do
    ids[#ids + 1] = position - base
  end
  return ids
end

---@param harness table live-app harness holding the attached controller worker
---@return table compiler pool owned by the attached controller
local function controllerPool(harness)
  local worker = assert(harness.worker, "no attached controller worker owns a compiler pool")
  return assert(worker.pool, "the controller owns no compiler pool before selection")
end

---@param harness table live-app harness
---@return table result channel shared by every compiler worker
local function resultChannel(harness)
  -- The service owns the first two channels (command, reply); the pool
  -- result channel follows once the attached worker selects a generation.
  return assert(harness.threadHost.channels[3], "the pool must create a result channel first")
end

---@param harness table live-app harness
---@param workerId integer
---@return table input channel owned by that compiler worker
local function inputChannel(harness, workerId)
  return assert(harness.threadHost.channels[3 + workerId], "missing input channel for worker " .. tostring(workerId))
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

---@param pool table process-owned compiler pool for status checks
---@param harness table live-app harness
local function failEveryRunningWorker(pool, harness)
  for _, workerId in ipairs(compilerWorkerIds(harness)) do
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
  for _, workerId in ipairs(compilerWorkerIds(harness)) do
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
    failEveryRunningWorker(controllerPool(harness), harness)
    ackCloseContexts(harness)
    pumpApp(App, harness, 1)
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
    service = App.service,
    pendingQuiesce = App.pendingQuiesce,
    opts = App.opts,
    saveDir = App.saveDir,
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
  if App.service ~= nil then
    pcall(function()
      App.service:shutdown()
    end)
  end
  App.opts = { dev = true }
  App.state = nil
  App.importer = nil
  App.provisioner = nil
  App.service = nil
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
  -- Live-controller tests own threading contracts, never attestation
  -- currency: stub the durable answers so no real file is read or
  -- written and ordinary selections keep their bootstrap paths.
  local completionOriginals = stubFirstPlayCompletion({})
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
  restoreFirstPlayCompletion(completionOriginals)
  HgssGame.new = original.gameNew
  RomImporter.new = original.importerNew
  ProducerFingerprint.appBackend = original.appBackend
  ProducerFingerprint.checkoutBackend = original.checkoutBackend
  realLove.event.quit = original.quit
  realLove.graphics.print = original.print
  App.state = original.state
  App.importer = original.importer
  App.provisioner = original.provisioner
  App.service = original.service
  App.pendingQuiesce = original.pendingQuiesce
  App.opts = original.opts
  App.saveDir = original.saveDir
  App.epoch = original.epoch
  App.drawableWidth = original.drawableWidth
  App.drawableHeight = original.drawableHeight
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
    attachWorker(harness)
    local host = provisioner:gameHost()
    local mapId = supportedFieldMapId(host)
    pumpApp(App, harness, 6)
    local before = controllerPool(harness):diagnostics()
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
    pumpApp(App, harness, 3)
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
    attachWorker(harness)
    local host = provisioner:gameHost()
    supportedFieldMapId(host)
    pumpApp(App, harness, 6)
    local pool = controllerPool(harness)
    Assert.isTrue(pool:diagnostics().counts.running > 0, "cancelled work must stay physically charged")
    assert(App.state, "selection must install a preparation state"):keypressed("escape", nil, nil)
    Assert.isNil(App.provisioner, "cancellation detaches the selection back to the selector")
    Assert.equal(controllerPool(harness), pool, "cancellation preserves the process-owned pool")
    Assert.isTrue(pool:diagnostics().counts.running > 0, "cancelled physical work stays charged to the pool")
    Assert.equal(getmetatable(App.state).__index, VersionSelectState, "cancellation returns to the version selector")
    App.filedropped({})
    Assert.isNil(App.importer, "a selector drop waits for the source barrier with old readers outstanding")
    pumpApp(App, harness, 2)
    Assert.isNil(App.importer, "pumping never starts the importer before source closure")
    drainBarrier(App, harness, 10)
    Assert.equal(#harness.importers, 1, "raw import starts exactly once after the barrier")
    Assert.equal(harness.importers[1].filedroppedCalls, 1, "the dropped file forwards to the importer once")
    Assert.equal(pool:diagnostics().counts.ready, 0, "old terminal work never publishes through the barrier")
  end)
end

function T.cancelled_preparation_leaves_persisted_save_bytes_unchanged(context)
  withLiveApp(context, function(App, harness)
    local saveFs = SaveFs.global()
    local store = GameSaveStore.new(saveFs, {
      recordValidate = function(candidate)
        return GameSave.validate(candidate)
      end,
    })
    local catalogBefore = saveFs:read(GameSaveStore.CATALOG_PATH)
    local saveId = store:reserve()
    store:publishFirst(record(saveId))
    local gamePath = "games/" .. saveId .. ".lua"
    local catalogSeeded = assert(saveFs:read(GameSaveStore.CATALOG_PATH), "seeding publishes a catalog")
    local gameSeeded = assert(saveFs:read(gamePath), "seeding publishes the save body")
    local provisioner = selectVersion(App, VERSION)
    attachWorker(harness)
    local host = provisioner:gameHost()
    supportedFieldMapId(host)
    pumpApp(App, harness, 6)
    assert(App.state, "selection must install a preparation state"):keypressed("escape", nil, nil)
    Assert.isNil(App.provisioner, "cancellation detaches the selection back to the selector")
    selectVersion(App, VERSION)
    pumpApp(App, harness, 4)
    Assert.equal(
      saveFs:read(GameSaveStore.CATALOG_PATH),
      catalogSeeded,
      "cancel and reselection rewrite no save catalog bytes"
    )
    Assert.equal(saveFs:read(gamePath), gameSeeded, "cancel and reselection rewrite no save body bytes")
    saveFs:remove(gamePath)
    if catalogBefore == nil then
      saveFs:remove(GameSaveStore.CATALOG_PATH)
    else
      saveFs:write(GameSaveStore.CATALOG_PATH, catalogBefore)
    end
  end)
end

function T.same_version_reselection_reuses_one_service_with_fresh_interest(context)
  withLiveApp(context, function(App, harness)
    -- One production route: a cold boot-menu entry waits through selection
    -- instead of launching the game directly.
    App._bootMainMenu({ VERSION })
    attachWorker(harness)
    pumpApp(App, harness, 4)
    Assert.equal(#harness.launches, 0, "a cold boot-menu entry must wait for preparation, not launch directly")
    Assert.equal(
      getmetatable(App.state).__index,
      CachePreparationState,
      "a cold boot-menu entry follows the same selection flow"
    )
    local pool = controllerPool(harness)
    local firstEpoch = assert(App.epoch, "selection must mint an epoch")
    local firstHost = assert(App.provisioner, "selection must attach a provisioner"):gameHost()
    local mapId = supportedFieldMapId(firstHost)
    pumpApp(App, harness, 6)
    assert(App.state, "selection must install a preparation state"):keypressed("escape", nil, nil)
    local second = selectVersion(App, VERSION)
    pumpApp(App, harness, 4)
    Assert.equal(controllerPool(harness), pool, "reselection reuses the one process pool")
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
    for _, workerId in ipairs(compilerWorkerIds(harness)) do
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
    pumpApp(App, harness, 2)
    local state, _ = pool:status(answered.jobKey)
    Assert.isTrue(state ~= "ready", "late old-epoch output cannot publish for the new interest")
    Assert.equal(pool:diagnostics().counts.ready, 0, "no obsolete output publishes through reselection")
  end)
end

function T.worker_failure_surfaces_in_preparation_without_further_requests(context)
  withLiveApp(context, function(App, harness)
    local RomImporter = require("romdump.src.source.RomImporter")
    local provisioner = selectVersion(App, VERSION)
    attachWorker(harness)
    local host = provisioner:gameHost()
    supportedFieldMapId(host)
    pumpApp(App, harness, 6)
    Assert.isTrue(
      controllerPool(harness):diagnostics().counts.running > 0,
      "the preparation must have physical work in flight"
    )
    local dispatchedBeforeFailure = #harness.threadHost.dispatched
    -- A genuine worker death behind running work, observed through the
    -- controlled transport rather than a staged session error.
    local crashed = nil
    for _, workerId in ipairs(compilerWorkerIds(harness)) do
      if lastDispatchedJob(harness, workerId) ~= nil then
        crashed = workerId
        break
      end
    end
    Assert.notNil(crashed, "a busy worker is required to fail behind the preparation view")
    local crashedPosition = (harness.controllerThreads or 0) + assert(crashed)
    local thread = harness.threadHost.threads[crashedPosition]
    thread.alive = false
    thread.threadError = "synthetic worker crash"
    pumpApp(App, harness, 1)
    pumpApp(App, harness, 3)
    Assert.equal(
      #harness.threadHost.dispatched,
      dispatchedBeforeFailure,
      "no further producer requests occur after the infrastructure failure"
    )
    Assert.notNil(controllerPool(harness):diagnostics().error, "the pool records the infrastructure failure")
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
    attachWorker(harness)
    local host = provisioner:gameHost()
    supportedFieldMapId(host)
    pumpApp(App, harness, 6)
    local pool = controllerPool(harness)
    Assert.isTrue(pool:diagnostics().counts.running > 0, "cancelled work must stay physically charged")
    assert(App.state, "selection must install a preparation state"):keypressed("escape", nil, nil)
    Assert.isNil(App.provisioner, "no provisioner remains after cancellation")
    -- A late prepared reply for the retired epoch is discarded, never
    -- published, even though its worker slot still matches. This settles
    -- before any other failure so the reply still finds its slot.
    local stale = nil
    local staleWorker = nil
    for _, workerId in ipairs(compilerWorkerIds(harness)) do
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
    pumpApp(App, harness, 1)
    local staleState, _ = pool:status(answered.jobKey)
    Assert.equal(staleState, "cancelled", "late old-epoch output cannot publish after retirement")
    Assert.equal(pool:diagnostics().counts.ready, 0, "obsolete outputs never publish")
    -- Physical lifecycle keeps moving with no session attached: terminal
    -- work settles instead of lingering on the detached pool.
    failEveryRunningWorker(pool, harness)
    pumpApp(App, harness, 2)
    Assert.equal(
      pool:diagnostics().counts.running,
      0,
      "detached updates settle old physical work without reviving the session"
    )
    Assert.isNil(App.provisioner, "settling detached work never reattaches a session")
    App.quit()
    pumpApp(App, harness, 4)
    for _, thread in ipairs(harness.threadHost.threads) do
      Assert.equal(thread.waits, 1, "each owned thread joins exactly once")
    end
    Assert.isNil(App.service, "quit releases the process service")
    Assert.isNil(App.provisioner, "quit leaves no selection behind")
    App.quit()
    pumpApp(App, harness, 2)
    for _, thread in ipairs(harness.threadHost.threads) do
      Assert.equal(thread.waits, 1, "a repeated quit never rejoins owned threads")
    end
  end)
end

function T.selection_switch_to_another_version_reuses_the_service_with_a_fresh_epoch()
  withAppStubs(function(App, context)
    local service = assert(App.service, "the application owns one process cache service")
    App._selectVersion(VERSION)
    App._selectVersion("soulsilver")
    Assert.equal(App.service, service, "a switch reuses the service instead of spawning a second")
    Assert.deepEqual(context.epochs, { 1, 2 }, "switching versions mints a new epoch on the shared service")
    Assert.deepEqual(context.retires, { 1 }, "the old interest retires exactly once without joining workers")
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
      App.service = nil
      Assert.isNil(App.service, "no worker exists before the first selection")
      App.filedropped({ name = "first.nds" })
      Assert.equal(calls.constructed, 1, "a drop with no service starts an import immediately")
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
  withAppStubs(function(App, context)
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
      assert(App.pendingQuiesce ~= nil, "the drop waits behind a quiescence barrier")
      local barrier = App.pendingQuiesce.barrier
      App.update(1 / 60)
      App.update(1 / 60)
      Assert.equal(constructed, 0, "no raw mutation begins before the barrier settles")
      context.barriers[barrier].status = "failed"
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
    App.pendingQuiesce = nil
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
    Assert.deepEqual(context.retires, { 1 }, "repeated disposal retires the epoch exactly once")
    App.quit()
    App.quit()
    Assert.equal(context.joins, 1, "repeated quit joins owned workers exactly once")
    Assert.isNil(App.service, "quit releases the process service")
    Assert.isNil(App.provisioner, "quit leaves no selection behind")
  end)
end

function T.selection_waits_behind_source_closure_then_selects_once()
  withAppStubs(function(App, context)
    App._selectVersion(VERSION)
    local epochBefore = assert(App.epoch, "selection must mint an epoch")
    App.filedropped({ name = "dropped.zip" })
    Assert.isNil(App.importer, "the drop waits for source closure instead of importing")
    local firstWait = assert(App.state, "the drop waits visibly")
    Assert.isNil(App.provisioner, "the drop retires selected interest before the barrier")
    -- A selection behind the outstanding barrier installs a second wait on
    -- the same barrier instead of selecting: no provisioner, no epoch, no
    -- second barrier.
    local pendingOk, pendingErr = pcall(App._selectVersion, VERSION)
    Assert.isTrue(
      pendingOk,
      "selection behind an outstanding barrier must wait instead of raising: " .. tostring(pendingErr)
    )
    Assert.isNil(App.provisioner, "the pending selection constructs no provisioner before closure")
    Assert.equal(App.epoch, epochBefore, "the pending selection mints no epoch before closure")
    Assert.equal(context.quiesces, 1, "the pending selection issues no second barrier")
    local secondWait = assert(App.state, "the pending selection waits visibly")
    Assert.isTrue(secondWait ~= firstWait, "the pending selection installs its own wait")
    Assert.equal(secondWait.kind, "quiescence", "the pending selection waits on source closure")
    -- Replacing the pending choice keeps only the later continuation: the
    -- replaced wait is disposed and can never fire late.
    local replaceOk, replaceErr = pcall(App._selectVersion, "soulsilver")
    Assert.isTrue(replaceOk, "a replacement selection must wait instead of raising: " .. tostring(replaceErr))
    Assert.isNil(App.provisioner, "the replacement constructs no provisioner before closure")
    Assert.equal(App.epoch, epochBefore, "the replacement mints no epoch before closure")
    Assert.equal(context.quiesces, 1, "the replacement issues no second barrier")
    local liveWait = assert(App.state, "the replacement waits visibly")
    Assert.isTrue(secondWait.dead, "the replaced wait can never fire late")
    -- The surviving selection still waits on bootstrap until the milestone
    -- is actually ready; the barrier acknowledgement alone must not launch.
    context.observations["milestone:bootstrap:nil:nil"] = { ready = nil, failure = nil }
    assert(context.barriers[1] ~= nil, "the drop holds one quiescence barrier")
    context.barriers[1].status = "ready"
    App.update(1 / 60)
    Assert.isTrue(liveWait.fired, "the live wait fires exactly once")
    Assert.isFalse(firstWait.fired, "the superseded drop wait never fires")
    Assert.isFalse(secondWait.fired, "the replaced wait never fires")
    local selected = assert(App.provisioner, "exactly one surviving selection attaches after closure")
    Assert.equal(App.epoch, epochBefore + 1, "the surviving selection mints exactly one fresh epoch")
    Assert.equal(
      context.selectOptions[#context.selectOptions].versionId,
      "soulsilver",
      "only the latest live choice selects"
    )
    Assert.equal(selected, App.provisioner, "no further selection replaces the survivor")
    Assert.equal(#context.imports, 0, "the cancelled dropped file is never imported")
    local survivorState = assert(App.state, "a cold surviving selection still waits visibly")
    Assert.equal(
      getmetatable(survivorState).__index,
      CachePreparationState,
      "a cold surviving selection still waits on bootstrap, never launches"
    )
    Assert.equal(survivorState.kind, "bootstrap", "the surviving selection waits on bootstrap readiness")
  end)
end

function T.only_the_live_pending_selection_fires_and_quit_joins_once()
  withAppStubs(function(App, context)
    App._selectVersion(VERSION)
    local epochBefore = assert(App.epoch, "selection must mint an epoch")
    App.filedropped({ name = "dropped.zip" })
    assert(App.state, "the drop waits visibly")
    local firstOk, firstErr = pcall(App._selectVersion, VERSION)
    Assert.isTrue(firstOk, "the first pending selection must wait instead of raising: " .. tostring(firstErr))
    local firstWait = assert(App.state, "the first pending selection waits visibly")
    local secondOk, secondErr = pcall(App._selectVersion, "soulsilver")
    Assert.isTrue(secondOk, "the replacement selection must wait instead of raising: " .. tostring(secondErr))
    local secondWait = assert(App.state, "the replacement waits visibly")
    Assert.isTrue(secondWait ~= firstWait, "the replacement installs its own wait")
    Assert.isTrue(firstWait.dead, "installing the replacement disposes the first wait")
    assert(context.barriers[1] ~= nil, "the drop holds one quiescence barrier")
    context.barriers[1].status = "ready"
    App.update(1 / 60)
    Assert.isTrue(firstWait.fired == false, "the disposed wait can never fire late")
    Assert.isTrue(secondWait.fired, "the live wait fires exactly once")
    Assert.equal(App.epoch, epochBefore + 1, "exactly one surviving selection mints one epoch")
    Assert.equal(
      context.selectOptions[#context.selectOptions].versionId,
      "soulsilver",
      "only the latest live choice executes"
    )
    Assert.equal(#context.imports, 0, "no import starts through the pending selections")
    -- A fresh barrier with a pending choice quits safely: nothing deferred
    -- may run and the owned service joins exactly once.
    local survivor = assert(App.provisioner, "the survivor attaches a provisioner")
    survivor:gameHost().requestMilestone("bootstrap", "required")
    App.update(1 / 60)
    App.filedropped({ name = "late.zip" })
    local lateWait = assert(App.state, "the late drop waits visibly")
    local lateOk, lateErr = pcall(App._selectVersion, VERSION)
    Assert.isTrue(lateOk, "the late pending selection must wait instead of raising: " .. tostring(lateErr))
    local latePending = assert(App.state, "the late pending selection waits visibly")
    Assert.isTrue(latePending ~= lateWait, "the late selection installs its own wait")
    local epochAtQuit = assert(App.epoch, "quitting never selects")
    App.quit()
    Assert.isTrue(latePending.dead, "quit disposes the pending continuation before shutdown")
    Assert.isTrue(lateWait.dead, "quit disposes every installed wait before shutdown")
    Assert.isNil(App.service, "quit releases the process service")
    Assert.isNil(App.provisioner, "quit leaves no selection behind")
    Assert.equal(#context.imports, 0, "quit executes no deferred import")
    Assert.equal(App.epoch, epochAtQuit, "quit executes no deferred selection")
    Assert.equal(context.joins, 1, "the owned service joins exactly once")
    App.quit()
    Assert.equal(context.joins, 1, "a repeated quit never rejoins the service")
  end)
end

-- The fixed icon-page dispatch reaches the selected session without a
-- parallel scheduler: unknown pages fail through the session cause and
-- unknown kinds never dispatch.
function T.icon_page_dispatch_reaches_the_selected_session()
  local Worker = require("romdump.src.build.CacheControllerWorker").Worker
  local control = {
    pop = function()
      return nil
    end,
  }
  local replies = {}
  local reply = {
    push = function(_, packet)
      replies[#replies + 1] = packet
    end,
  }
  local worker = Worker.new(control, reply)
  local seen = {}
  worker.session = {
    requestIconPage = function(_, pageId, urgency)
      seen[#seen + 1] = { pageId = pageId, urgency = urgency }
      return true
    end,
  }
  local ready = worker:_invoke({ requestKind = "icon-page", pageId = 3, urgency = "required" })
  Assert.isTrue(ready, "the selected session answers the icon dispatch")
  Assert.deepEqual(seen, { { pageId = 3, urgency = "required" } }, "icon dispatch carries its scalar selectors")
  local unknownOk, _ = pcall(function()
    return worker:_invoke({ requestKind = "sticker-page", pageId = 3, urgency = "required" })
  end)
  Assert.isFalse(unknownOk, "an unlisted kind never dispatches")
end

-- First-play preparation presentation: the launcher state stays
-- policy-agnostic, delegating readiness to the opaque preparation object
-- while owning liveness, exactly-once transfer, and disposal.
local function scriptedFirstPlayPreparation(script)
  local preparation = {}
  function preparation:poll()
    script.polls = (script.polls or 0) + 1
    if script.failure ~= nil then
      return nil, script.failure
    end
    if script.ready then
      return true, nil
    end
    return nil, nil
  end
  function preparation:dispose()
    script.disposals = (script.disposals or 0) + 1
  end
  return preparation
end

local function firstPlayState(script, overrides)
  local options = {
    kind = "first-play",
    epoch = 7,
    preparation = scriptedFirstPlayPreparation(script),
    provisioner = {
      status = function()
        return {}
      end,
    },
    isCurrent = function()
      return true
    end,
    onReady = function()
      script.fired = (script.fired or 0) + 1
    end,
    onCancel = function()
      script.cancelled = (script.cancelled or 0) + 1
    end,
  }
  for key, value in pairs(overrides or {}) do
    options[key] = value
  end
  return CachePreparationState.new(options)
end

function T.first_play_preparation_delegates_readiness_without_milestone_policy()
  local script = { ready = false }
  local state = firstPlayState(script)
  state:update(0.016)
  Assert.equal(script.polls, 1, "the launcher polls the opaque preparation object")
  Assert.isNil(script.fired, "pending preparation never transfers")
  Assert.isNil(state.error, "pending preparation carries no error")
  script.ready = true
  state:update(0.016)
  Assert.equal(script.fired, 1, "preparation readiness transfers")
  state:update(0.016)
  Assert.equal(script.fired, 1, "the transfer fires exactly once")
end

function T.first_play_failure_latches_without_policy_knowledge()
  local script = { ready = false, failure = "intro milestone failed in the fixture" }
  local state = firstPlayState(script)
  state:update(0.016)
  Assert.isNil(script.fired, "a failed preparation never transfers")
  Assert.notNil(state.error, "the preparation failure surfaces on the launcher state")
  state:update(0.016)
  Assert.isNil(script.fired, "a latched failure never recovers into a transfer")
end

function T.stale_first_play_epoch_never_launches()
  local script = { ready = true }
  local state = firstPlayState(script, {
    isCurrent = function()
      return false
    end,
  })
  state:update(0.016)
  Assert.isNil(script.fired, "a stale epoch never calls its ready callback")
  Assert.equal(script.polls or 0, 0, "a stale epoch never polls preparation")
end

function T.first_play_disposal_releases_the_preparation_once()
  local script = { ready = true }
  local state = firstPlayState(script)
  state:dispose()
  Assert.equal(script.disposals, 1, "launcher disposal releases the preparation object")
  state:dispose()
  Assert.equal(script.disposals, 1, "repeated launcher disposal releases exactly once")
  state:update(0.016)
  Assert.isNil(script.fired, "a disposed state never transfers even when preparation is ready")
end

return { tests = T }
