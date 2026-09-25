-- App shell state replacement tests. App.setState is the single transition point
-- between top-level states: it must dispose the previous state exactly once,
-- tolerate states without a disposal hook (the one centralized optional
-- check), and guarantee application quit can never dispose a state twice.
-- Import sessions are single-use: a file drop must always enter a fresh
-- import session through the import state and never invoke an importer left
-- over from a previous session.

local Assert = require("tests.support.Assert")
local RomImporter = require("romdump.src.source.RomImporter")
local FirstPlayCompletion = require("romdump.src.FirstPlayCompletion")
local HgssGame = require("game.hgss.src.HgssGame")
local CachePreparationState = require("app.src.launcher.CachePreparationState")
local ProducerFingerprint = require("romdump.src.ProducerFingerprint")
local defaultAppBackend = ProducerFingerprint.appBackend
local defaultCheckoutBackend = ProducerFingerprint.checkoutBackend

local App
local ImportState
local VersionSelectState

local function loadShellModules()
  local ok, appOrError = pcall(require, "app.src.App")
  Assert.isTrue(ok, "the app shell must provide app.src.App: " .. tostring(appOrError))
  App = appOrError
  local okImport, importOrError = pcall(require, "app.src.launcher.ImportState")
  Assert.isTrue(okImport, "the app shell must own its import state: " .. tostring(importOrError))
  ImportState = importOrError
  local okVersion, versionOrError = pcall(require, "app.src.launcher.VersionSelectState")
  Assert.isTrue(okVersion, "the app shell must own its version selector: " .. tostring(versionOrError))
  VersionSelectState = versionOrError
end

local T = {}

-- A contract state that counts disposal invocations.
local function countingState()
  local state = { disposed = 0 }
  function state:dispose()
    self.disposed = self.disposed + 1
  end
  return state
end

local function minimalSourceBackend()
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

-- Clear module state so tests are independent of each other and of the boot
-- flow tests.
local function fresh()
  loadShellModules()
  App.state = nil
  App.importer = nil
  App.provisioner = nil
  if App.service ~= nil then
    pcall(function()
      App.service:shutdown()
    end)
  end
  App.service = nil
  App.pendingQuiesce = nil
  App.epoch = 0
  App.drawableWidth = nil
  App.drawableHeight = nil
end

-- One harness for every App-level seam a test can touch: fresh module state,
-- the App opts the boot/draw paths read, the RomImporter.isReady seam, a
-- captured HgssGame.new launch, and a graphics.print/quit spy. Every stub is
-- restored on every path, so no test leaks options or stubs into the next.
---@class AppStateHarness
---@field prints integer
---@field state table
---@field launches table[]
---@field selectOptions table[]
---@field quitCodes integer[]
---@field provisionerDisposals integer
---@field warmups integer
---@field cannedGeneration string? controller-derived generation token answered for the selection
---@field service table scripted process cache service behind the selection
---@field firstPlayCurrent boolean scripted durable attestation currency
---@field firstPlayStored boolean scripted durable attestation presence
---@field firstPlayPublished table[] recorded attestation publications
---@param opts table|nil
---@param ready fun(id: string): boolean
---@param fn fun(result: AppStateHarness)
---@return AppStateHarness
local function withAppHarness(opts, ready, fn)
  fresh()
  local originalOpts = App.opts
  local originalIsReady = RomImporter.isReady
  local originalNew = HgssGame.new
  local graphics = love.graphics
  local originalPrint = graphics.print
  local originalGetDimensions = graphics.getDimensions
  local originalQuit = love.event.quit
  local harnessAppBackend = ProducerFingerprint.appBackend
  local harnessCheckoutBackend = ProducerFingerprint.checkoutBackend
  if harnessAppBackend == defaultAppBackend then
    ProducerFingerprint.appBackend = minimalSourceBackend
  end
  if harnessCheckoutBackend == defaultCheckoutBackend then
    ProducerFingerprint.checkoutBackend = function()
      return minimalSourceBackend()
    end
  end
  local result = {
    prints = 0,
    state = countingState(),
    launches = {},
    selectOptions = {},
    quitCodes = {},
    provisionerDisposals = 0,
    warmups = 0,
    cannedGeneration = "test-generation",
    firstPlayCurrent = true,
    firstPlayStored = true,
    firstPlayPublished = {},
  }
  local epoch = 0
  local service = {}
  function service:select(options)
    epoch = epoch + 1
    result.selectOptions[#result.selectOptions + 1] = options
    return epoch
  end
  function service:request(_, _) end
  function service:observe(_, selector)
    if selector.requestKind == "milestone" and selector.name == "bootstrap" then
      return true, nil
    end
    return nil, nil
  end
  function service:enableSweep(_)
    result.warmups = result.warmups + 1
  end
  function service:update() end
  function service:retire(_)
    result.provisionerDisposals = result.provisionerDisposals + 1
  end
  function service:quiesce(_)
    return 1
  end
  function service:barrierStatus(_, _)
    return "pending"
  end
  function service:generationId(_)
    return result.cannedGeneration
  end
  function service:importSource(_, _)
    return false, "unacknowledged"
  end
  function service:shutdown() end
  result.service = service
  local unownedOption = {}
  App.opts = setmetatable(opts or { dev = false }, {
    __index = function(_, key)
      if key == "dev" then
        return false
      end
      return unownedOption
    end,
  })
  App.service = service
  RomImporter.isReady = ready
  local originalIsCurrent = FirstPlayCompletion.isCurrent
  local originalHasStored = FirstPlayCompletion.hasStored
  local originalPublish = FirstPlayCompletion.publish
  FirstPlayCompletion.isCurrent = function(_, _)
    return result.firstPlayCurrent
  end
  FirstPlayCompletion.hasStored = function()
    return result.firstPlayStored
  end
  FirstPlayCompletion.publish = function(versionId, generationId)
    result.firstPlayPublished[#result.firstPlayPublished + 1] = { versionId = versionId, generationId = generationId }
  end
  HgssGame.new = function(options)
    result.launches[#result.launches + 1] = options
    return result.state
  end
  graphics.print = function()
    result.prints = result.prints + 1
  end
  graphics.getDimensions = function()
    return 800, 600
  end
  love.event.quit = function(code)
    result.quitCodes[#result.quitCodes + 1] = code
  end
  local ok, err = pcall(fn, result)
  App.opts = originalOpts
  RomImporter.isReady = originalIsReady
  FirstPlayCompletion.isCurrent = originalIsCurrent
  FirstPlayCompletion.hasStored = originalHasStored
  FirstPlayCompletion.publish = originalPublish
  HgssGame.new = originalNew
  graphics.print = originalPrint
  graphics.getDimensions = originalGetDimensions
  love.event.quit = originalQuit
  ProducerFingerprint.appBackend = harnessAppBackend
  ProducerFingerprint.checkoutBackend = harnessCheckoutBackend
  if not ok then
    error(err, 0)
  end
  return result
end

---@param appBackend fun(): ProducerSourceTree
---@param checkoutBackend fun(repositoryRoot: string): ProducerSourceTree
---@param fn fun()
local function withProducerBackends(appBackend, checkoutBackend, fn)
  local originalAppBackend = ProducerFingerprint.appBackend
  local originalCheckoutBackend = ProducerFingerprint.checkoutBackend
  ProducerFingerprint.appBackend = appBackend
  ProducerFingerprint.checkoutBackend = checkoutBackend
  local ok, err = pcall(fn)
  ProducerFingerprint.appBackend = originalAppBackend
  ProducerFingerprint.checkoutBackend = originalCheckoutBackend
  if not ok then
    error(err, 0)
  end
end

---@param root string
---@param fn fun()
local function withSourceBaseDirectory(root, fn)
  local fs = love.filesystem
  local original = fs.getSourceBaseDirectory
  fs.getSourceBaseDirectory = function()
    return root
  end
  local ok, err = pcall(fn)
  fs.getSourceBaseDirectory = original
  if not ok then
    error(err, 0)
  end
end

---@param files table<string, string>
---@return ProducerSourceTree
local function fakeSourceBackend(files)
  return {
    list = function()
      local paths = {}
      for path in pairs(files) do
        paths[#paths + 1] = path
      end
      table.sort(paths, function(left, right)
        return left > right
      end)
      return paths
    end,
    read = function(path)
      return assert(files[path])
    end,
    getInfo = function(path)
      if path == "romdump/src" then
        return { type = "directory" }
      end
      return nil
    end,
  }
end

-- An importer stand-in in a given state. App reads isBusy()/state and forwards
-- drops; a terminal (complete/error) stand-in models an importer left over
-- from a finished session.
local function importerStub(state, busy)
  local importer = {
    state = state,
    busy = busy or false,
    filedroppedCalls = 0,
  }
  function importer:isBusy()
    return self.busy
  end
  function importer:filedropped()
    self.filedroppedCalls = self.filedroppedCalls + 1
  end
  return importer
end

-- A minimal dropped-file stand-in satisfying RomSource.fromDroppedFile's
-- protocol. The bytes are not a ROM, so a real importer routes the drop into
-- its reading state without touching the filesystem or caches.
local function droppedFile()
  return {
    getFilename = function()
      return "dropped.nds"
    end,
    open = function()
      return true
    end,
    read = function()
      return "not a real rom"
    end,
    close = function() end,
  }
end

function T.starting_an_import_disposes_the_active_field_state()
  fresh()
  local field = countingState()
  App.setState(field)
  App.saveDir = nil
  App._startImport()
  Assert.equal(field.disposed, 1)
  Assert.equal(getmetatable(App.state).__index, ImportState)
  Assert.notNil(App.importer)
end

-- The bare "portemon" draw is developer branding on an empty frame: product
-- mode draws nothing, dev mode keeps the emergency text.
function T.app_draw_keeps_the_emergency_brand_text_only_in_dev_mode()
  for _, dev in ipairs({ false, true }) do
    local result = withAppHarness({ dev = dev }, function()
      return false
    end, function()
      App.draw()
    end)
    local expected = 0
    if dev then
      expected = 1
    end
    Assert.equal(result.prints, expected, "brand text on an empty frame tracks dev mode")
  end
end

-- An import session is single-use. A file drop during gameplay after a
-- finished import (complete or failed) must enter a fresh import session
-- through the import state; the stale importer's completion callback would
-- otherwise replace the active field state unexpectedly, and re-running a
-- failed importer is just as wrong.
function T.drop_after_a_finished_import_starts_a_fresh_session()
  for _, terminalState in ipairs({ "complete", "error" }) do
    fresh()
    local stale = importerStub(terminalState)
    App.importer = stale
    App.setState({})
    App.filedropped(droppedFile())
    Assert.equal(stale.filedroppedCalls, 0, "the stale importer must not be invoked")
    Assert.isFalse(App.importer == stale, "a finished import session must not be reused")
    Assert.notNil(App.importer)
    Assert.equal(getmetatable(App.state).__index, ImportState)
    Assert.equal(App.state.importer, App.importer)
  end
end

-- Drops while an import is running are ignored: no new session, no forward to
-- the busy importer.
function T.drop_while_busy_is_ignored()
  fresh()
  local busy = importerStub("reading", true)
  App.importer = busy
  local state = {}
  App.setState(state)
  App.filedropped(droppedFile())
  Assert.equal(busy.filedroppedCalls, 0)
  Assert.equal(App.importer, busy)
  Assert.equal(App.state, state)
end

-- A failed import leaves no importer behind: the next update clears it, so a
-- stale reference can never survive the session. The import screen holds its
-- own reference and is unaffected.
function T.failed_import_is_cleared_on_the_next_update()
  fresh()
  App.importer = importerStub("error")
  local state = { update = function() end }
  App.setState(state)
  App.update(0.016)
  Assert.isNil(App.importer, "a failed import session must not linger")
  Assert.equal(App.state, state, "clearing the importer must not disturb the import screen")
end

-- The boot decision when no ROM was supplied: zero ready versions enter the
-- import state, one launches HGSS, and several offer the version selector.

function T.boot_existing_with_no_ready_version_starts_an_import()
  withAppHarness({}, function()
    return false
  end, function()
    App._bootExisting()
    Assert.notNil(App.importer)
    Assert.equal(getmetatable(App.state).__index, ImportState)
  end)
end

function T.boot_existing_with_one_ready_version_enters_the_main_menu()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    App._bootExisting()
    local launch = assert(result.launches[1])
    Assert.keySet(launch, "derivedAssets,development,onExit,versionId")
    Assert.equal(launch.versionId, "heartgold")
    Assert.isFalse(launch.development)
    Assert.equal(App.state, result.state)
    Assert.equal(result.provisionerDisposals, 0, "launch must not dispose its new provisioner")
    Assert.equal(result.warmups, 1, "menu installation authorizes background completion once")
  end)
end

function T.boot_existing_with_two_ready_versions_offers_the_selector_over_the_ready_array()
  withAppHarness({ dev = true }, function(id)
    return id == "heartgold" or id == "soulsilver"
  end, function(result)
    App._bootExisting()
    local selector = App.state
    ---@cast selector table
    Assert.equal(getmetatable(selector).__index, VersionSelectState)
    Assert.deepEqual(selector.ready, { "heartgold", "soulsilver" })
    selector.onPick("soulsilver")
    local launch = assert(result.launches[1])
    Assert.keySet(launch, "derivedAssets,development,onExit,versionId")
    Assert.equal(launch.versionId, "soulsilver")
    Assert.isTrue(launch.development)
    Assert.equal(App.state, result.state)
  end)
end

function T.completed_import_launches_the_imported_version_through_the_hgss_entry()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    -- A fresh import frontloads first-play preparation before the menu:
    -- once the closure is ready, the import still lands on the Hgss
    -- menu entry with the same launch contract as before.
    local original = HgssGame.newFirstPlayCachePreparation
    HgssGame.newFirstPlayCachePreparation = function(_)
      local preparation = {}
      function preparation:poll()
        return true, nil
      end
      function preparation:dispose() end
      return preparation
    end
    local ok, err = pcall(function()
      App._onImported("heartgold")
      App.update(0.016)
      local launch = assert(result.launches[1])
      Assert.keySet(launch, "derivedAssets,development,onExit,versionId")
      Assert.equal(launch.versionId, "heartgold")
      Assert.equal(App.state, result.state)
    end)
    HgssGame.newFirstPlayCachePreparation = original
    if not ok then
      error(err, 0)
    end
  end)
end

function T.shell_exit_mapping_quits_only_for_a_hgss_quit_result()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    App._bootMainMenu({ "heartgold" })
    local launch = assert(result.launches[1])
    launch.onExit({ kind = "continue" })
    launch.onExit(nil)
    Assert.deepEqual(result.quitCodes, {})
    launch.onExit({ kind = "quit" })
    Assert.deepEqual(result.quitCodes, { 0 })
  end)
end

-- Release startup selects the explicit per-game counter without reading any
-- producer source: both source backends fail the boot if touched.
function T.release_startup_passes_the_release_counter_without_reading_producer_sources()
  local touches = 0
  local function touch()
    touches = touches + 1
    error("release startup must not touch producer sources")
  end
  local hostileBackend = { list = touch, read = touch, getInfo = touch }
  withProducerBackends(function()
    touches = touches + 1
    return hostileBackend
  end, function()
    touches = touches + 1
    error("release startup must not select the checkout source")
  end, function()
    withAppHarness({ dev = false }, function(id)
      return id == "heartgold"
    end, function(result)
      App._bootExisting()
      local options = assert(result.selectOptions[1])
      Assert.keySet(options, "development,versionId")
      Assert.equal(options.versionId, "heartgold")
      Assert.isFalse(options.development)
      Assert.isNil(
        options.developmentRepositoryRoot,
        "release selection passes no checkout root; identity is derived below the controller"
      )
      Assert.isNil(options.sweepEnabled, "exhaustive intent travels as an explicit request, never a construction flag")
      Assert.equal(touches, 0)
      Assert.equal(#result.launches, 1)
      Assert.equal(App.state, result.state)
    end)
  end)
end

-- The release counter is selected per game from the explicit release table.
function T.release_startup_selects_the_per_game_release_counter()
  withProducerBackends(function()
    error("release startup must not use the product source")
  end, function()
    error("release startup must not select the checkout source")
  end, function()
    withAppHarness({ dev = false }, function(id)
      return id == "soulsilver"
    end, function(result)
      App._bootExisting()
      local options = assert(result.selectOptions[1])
      Assert.keySet(options, "development,versionId")
      Assert.equal(options.versionId, "soulsilver")
      Assert.isFalse(options.development)
      Assert.isNil(
        options.developmentRepositoryRoot,
        "release selection passes no checkout root; the release counter is derived below the controller"
      )
      Assert.equal(#result.launches, 1)
    end)
  end)
end

-- Explicit development mode passes the checkout root through frozen
-- selectors: the game thread never scans the checkout itself, identity is
-- derived below the controller, and a second boot resends the selectors
-- unchanged even after checkout bytes change.
function T.development_startup_passes_frozen_checkout_selectors_without_scanning()
  local files = {
    ["build/Compiler.lua"] = "checkout compiler",
    ["build/Readers.lua"] = "checkout readers",
  }
  local checkoutRoot = "/deterministic/checkout"
  local checkoutCalls = 0
  local appBackendCalls = 0
  local checkoutBackend = function(repositoryRoot)
    checkoutCalls = checkoutCalls + 1
    Assert.equal(repositoryRoot, checkoutRoot)
    return fakeSourceBackend(files)
  end
  local appBackend = function()
    appBackendCalls = appBackendCalls + 1
    error("development startup must not use the product source")
  end
  withProducerBackends(appBackend, checkoutBackend, function()
    withSourceBaseDirectory(checkoutRoot, function()
      withAppHarness({ dev = true }, function(id)
        return id == "heartgold"
      end, function(result)
        App._bootExisting()
        local first = assert(result.selectOptions[1])
        Assert.equal(first.versionId, "heartgold")
        Assert.isTrue(first.development)
        Assert.equal(
          first.repositoryRoot,
          checkoutRoot,
          "development selection passes the checkout root instead of a digest"
        )
        App._bootMainMenu({ "heartgold" })
        local second = assert(result.selectOptions[2])
        Assert.equal(checkoutCalls, 0, "no checkout scan happens on the game thread")
        Assert.equal(appBackendCalls, 0)
        Assert.deepEqual(
          { second.versionId, second.development, second.repositoryRoot },
          { first.versionId, first.development, first.repositoryRoot },
          "reselection passes the same frozen selectors without rescanning"
        )
        Assert.equal(#result.launches, 2)
      end)
    end)
  end)
end

-- A scripted first-play preparation stand-in behind the app-facing
-- factory seam. It reports pending until its script releases it, so App
-- wiring tests prove epoch ownership and sweep ordering without
-- rebuilding the real bedroom closure (owned by the preparation tests).
local function installFirstPlayFactory(script)
  local original = HgssGame.newFirstPlayCachePreparation
  HgssGame.newFirstPlayCachePreparation = function(options)
    script.captured = options
    script.constructions = (script.constructions or 0) + 1
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
  return original
end

-- Records every controller request selector so tests prove the mandatory
-- import interval requests exactly the bounded first-play set and never a
-- whole-corpus scope.
local function recordServiceRequests(result)
  local requests = {}
  local baseRequest = result.service.request
  result.service.request = function(_, epoch, selector)
    requests[#requests + 1] = selector
    return baseRequest(_, epoch, selector)
  end
  return requests
end

local function requestedMilestones(requests)
  local names = {}
  local urgencies = {}
  local seen = {}
  for _, selector in ipairs(requests) do
    if selector.requestKind == "milestone" then
      -- Interest is re-affirmed on every poll until terminal readiness,
      -- so the same milestone is requested repeatedly: the contract is
      -- the exact SET of names, never a total call count.
      if not seen[selector.name] then
        seen[selector.name] = true
        names[#names + 1] = selector.name
      end
      urgencies[selector.name] = selector.urgency
    end
  end
  table.sort(names)
  return names, urgencies
end

-- A fresh import must not reach the menu while first-play preparation is
-- pending: the import transaction frontloads the existing global set plus
-- the initial bedroom closure through production App and preparation
-- composition, with bootstrap ready and everything else pending below.
function T.fresh_import_waits_for_the_first_play_closure_before_the_menu()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    local requests = recordServiceRequests(result)
    App._onImported("heartgold")
    for _ = 1, 3 do
      App.update(0.016)
    end
    Assert.equal(#result.launches, 0, "a fresh import must not launch the menu while first-play preparation is pending")
    Assert.equal(
      getmetatable(App.state).__index,
      CachePreparationState,
      "the import waits through the visible preparation state"
    )
    local names, urgencies = requestedMilestones(requests)
    Assert.deepEqual(
      names,
      { "bootstrap", "field-planning", "field-runtime", "new-game-intro" },
      "fresh import requests exactly the existing first-play milestone set"
    )
    for _, name in ipairs(names) do
      Assert.equal(urgencies[name], "required", "first-play milestone demand is required urgency")
    end
    for _, selector in ipairs(requests) do
      Assert.isFalse(
        selector.requestKind == "complete",
        "mandatory import preparation never requests whole-corpus scope"
      )
    end
  end)
end

-- Ordinary selection distinguishes raw-ready from first-play-complete: a
-- raw-ready version without a current attestation enters the same bounded
-- preparation a fresh import uses instead of launching the menu directly.
-- A fresh harness models a process restart: no prior selection survives.
function T.existing_selection_after_restart_without_a_completion_enters_preparation()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    result.firstPlayCurrent = false
    result.firstPlayStored = false
    local script = { ready = false }
    local original = installFirstPlayFactory(script)
    local ok, err = pcall(function()
      App._bootExisting()
    end)
    HgssGame.newFirstPlayCachePreparation = original
    if not ok then
      error(err, 0)
    end
    Assert.equal(#result.launches, 0, "an incomplete first-play closure never launches the menu directly")
    Assert.equal(script.constructions, 1, "a restart with no completion prepares again")
    Assert.equal(
      getmetatable(App.state).__index,
      CachePreparationState,
      "the boot waits through the visible preparation state"
    )
    Assert.notNil(script.captured.completion, "ordinary preparation carries the durable gateway")
  end)
end

-- A stored but stale attestation prepares again: the current generation
-- ignores it exactly like a missing one.
function T.existing_selection_with_a_stale_completion_prepares_again()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    result.firstPlayCurrent = false
    result.firstPlayStored = true
    local script = { ready = false }
    local original = installFirstPlayFactory(script)
    local ok, err = pcall(function()
      App._bootExisting()
    end)
    HgssGame.newFirstPlayCachePreparation = original
    if not ok then
      error(err, 0)
    end
    Assert.equal(#result.launches, 0, "a stale completion never launches the menu directly")
    Assert.equal(script.constructions, 1, "a stale completion prepares again")
  end)
end

-- Ordinary selection with a current attestation keeps the fast
-- bootstrap/menu path: no first-play preparation is constructed.
function T.existing_selection_with_a_current_completion_keeps_the_bootstrap_path()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    local factoryCalls = 0
    local original = HgssGame.newFirstPlayCachePreparation
    if original ~= nil then
      HgssGame.newFirstPlayCachePreparation = function(options)
        factoryCalls = factoryCalls + 1
        return original(options)
      end
    end
    local ok, err = pcall(function()
      App._bootExisting()
    end)
    HgssGame.newFirstPlayCachePreparation = original
    if not ok then
      error(err, 0)
    end
    Assert.equal(#result.launches, 1, "a completed first-play closure still launches through selection")
    Assert.equal(factoryCalls, 0, "a current completion never reconstructs first-play preparation")
  end)
end

-- Cancelling first-play preparation retires the selection without
-- publishing: reselecting the same raw-ready version prepares again and
-- the menu cannot launch directly.
function T.cancelled_first_play_prepares_again_without_publishing()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    result.firstPlayCurrent = false
    result.firstPlayStored = false
    local script = { ready = false }
    local original = installFirstPlayFactory(script)
    local ok, err = pcall(function()
      App._onImported("heartgold")
      App.update(0.016)
      Assert.equal(#result.launches, 0, "the menu waits while preparation is pending")
      Assert.equal(script.constructions, 1, "the fresh import prepares once")
      App.keypressed("escape")
      Assert.equal(#result.firstPlayPublished, 0, "cancellation never publishes the completion")
      local selector = App.state
      Assert.equal(getmetatable(selector).__index, VersionSelectState, "cancellation returns to the version selector")
      selector.onPick("heartgold")
      App.update(0.016)
      Assert.equal(script.constructions, 2, "reselecting the same version prepares again")
      Assert.equal(#result.launches, 0, "the menu cannot launch directly after a cancel")
      Assert.equal(#result.firstPlayPublished, 0, "reselection alone publishes nothing")
    end)
    HgssGame.newFirstPlayCachePreparation = original
    if not ok then
      error(err, 0)
    end
  end)
end

-- The completion publishes only after the full closure succeeds: pending
-- preparation publishes nothing, and the success publishes the current
-- generation exactly once before the menu launches on the same epoch.
function T.first_play_completion_publishes_only_on_success()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    result.firstPlayCurrent = false
    result.firstPlayStored = false
    local script = { ready = false }
    local original = installFirstPlayFactory(script)
    local ok, err = pcall(function()
      App._onImported("heartgold")
      App.update(0.016)
      Assert.equal(#result.firstPlayPublished, 0, "pending preparation publishes nothing")
      script.ready = true
      App.update(0.016)
      assert(result.launches[1], "preparation readiness launches the game")
      Assert.deepEqual(
        result.firstPlayPublished,
        { { versionId = "heartgold", generationId = "test-generation" } },
        "success publishes the current generation exactly once"
      )
    end)
    HgssGame.newFirstPlayCachePreparation = original
    if not ok then
      error(err, 0)
    end
  end)
end

-- Unknown generation with a stored attestation waits without demands,
-- then transfers and publishes once the controller-derived generation
-- validates it: the full production gateway composition, not a scripted
-- preparation stand-in.
function T.unknown_generation_waits_without_demands_then_transfers_on_validation()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    result.cannedGeneration = nil
    result.firstPlayCurrent = false
    result.firstPlayStored = true
    local requests = 0
    result.service.request = function()
      requests = requests + 1
    end
    App._bootExisting()
    App.update(0.016)
    Assert.equal(#result.launches, 0, "an unvalidated completion never launches the menu")
    Assert.equal(requests, 0, "no closure demand issues while the generation is unknown")
    Assert.equal(getmetatable(App.state).__index, CachePreparationState)
    Assert.equal(App.state.kind, "first-play")
    result.cannedGeneration = "test-generation"
    result.firstPlayCurrent = true
    App.update(0.016)
    assert(result.launches[1], "the validated completion transfers to the menu")
    Assert.equal(requests, 0, "the transfer demands no closure work")
    Assert.deepEqual(
      result.firstPlayPublished,
      { { versionId = "heartgold", generationId = "test-generation" } },
      "the transfer publishes the validated generation"
    )
  end)
end

-- A failed preparation latches its error without publishing or launching.
function T.failed_first_play_never_publishes()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    result.firstPlayCurrent = false
    result.firstPlayStored = false
    local script = { ready = false, failure = "intro milestone failed in the fixture" }
    local original = installFirstPlayFactory(script)
    local ok, err = pcall(function()
      App._onImported("heartgold")
      App.update(0.016)
      App.update(0.016)
      Assert.equal(#result.launches, 0, "a failed preparation never launches the menu")
      Assert.equal(#result.firstPlayPublished, 0, "a failed preparation never publishes")
      Assert.notNil(App.state.error, "the failure surfaces on the preparation state")
    end)
    HgssGame.newFirstPlayCachePreparation = original
    if not ok then
      error(err, 0)
    end
  end)
end

-- One provisioner epoch spans mandatory preparation and gameplay: the
-- import selects once, never disposes or reselects before launch, and the
-- game inherits the preparation host.
function T.fresh_import_hands_the_same_provisioner_epoch_to_the_game()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    local script = { ready = false }
    local original = installFirstPlayFactory(script)
    local ok, err = pcall(function()
      App._onImported("heartgold")
      Assert.equal(#result.launches, 0, "the menu waits while first-play preparation is pending")
      local epoch = assert(App.epoch, "fresh import borrows a controller epoch")
      local selections = #result.selectOptions
      script.ready = true
      App.update(0.016)
      local launch = assert(result.launches[1], "preparation readiness launches the game")
      Assert.equal(#result.selectOptions, selections, "the launch reuses the preparation epoch without reselection")
      Assert.equal(result.provisionerDisposals, 0, "nothing disposes between preparation and launch")
      Assert.equal(App.epoch, epoch, "the epoch is stable across the handoff")
      Assert.equal(
        launch.derivedAssets,
        script.captured.derivedAssets,
        "the game inherits the host preparation compiled against"
      )
      Assert.equal(script.captured.versionId, "heartgold", "preparation serves the imported version")
    end)
    HgssGame.newFirstPlayCachePreparation = original
    if not ok then
      error(err, 0)
    end
  end)
end

-- Mandatory import work never races whole-corpus warmup: no sweep
-- authorizes before the menu, and menu installation authorizes it exactly
-- once.
function T.fresh_import_preparation_requests_no_corpus_work_or_early_sweep()
  withAppHarness({ dev = false }, function(id)
    return id == "heartgold"
  end, function(result)
    local requests = recordServiceRequests(result)
    local script = { ready = false }
    local original = installFirstPlayFactory(script)
    local ok, err = pcall(function()
      App._onImported("heartgold")
      App.update(0.016)
      Assert.equal(result.warmups, 0, "no background sweep authorizes before the menu launches")
      for _, selector in ipairs(requests) do
        Assert.isFalse(
          selector.requestKind == "complete",
          "mandatory import preparation never requests whole-corpus scope"
        )
      end
      script.ready = true
      App.update(0.016)
      assert(result.launches[1], "preparation readiness launches the game")
      Assert.equal(result.warmups, 1, "menu installation authorizes background completion exactly once")
      App.update(0.016)
      Assert.equal(result.warmups, 1, "sweep authorization never repeats")
    end)
    HgssGame.newFirstPlayCachePreparation = original
    if not ok then
      error(err, 0)
    end
  end)
end

return { tests = T }
