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
  local menu = MainMenuState.new({
    saveStore = {
      listMetadata = function()
        return entries
      end,
    },
    readyVersions = { VERSION },
    width = 640,
    height = 480,
    onResult = function(result)
      results[#results + 1] = result
    end,
  })
  local card = menu:view().items[2]
  Assert.equal(card.saveId, saveId)
  Assert.equal(card.playerName, "GOLD")
  Assert.isTrue(card.canContinue, "a displayed record stays continuable while the cache is cold")
  menu:keypressed("down")
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
    local pumps = 0
    App.provisioner = {
      update = function()
        pumps = pumps + 1
      end,
      dispose = function() end,
    }
    local poolWas = App.pool
    App.pool = {
      quiesce = function() end,
      isQuiescent = function()
        return false
      end,
    }
    local ok, err = pcall(function()
      App.filedropped({ name = "replacement.zip" })
      Assert.isNil(App.importer, "raw replacement waits for source quiescence instead of mutating the dump")
      Assert.notNil(App.state, "quiescence waits through a visible preparation state")
      App.update(1 / 60)
      Assert.isTrue(pumps > 0, "input and progress keep pumping while source readers drain")
      Assert.isNil(App.importer, "pumping never starts the importer before quiescence")
      App.provisioner = nil
      App.update(1 / 60)
      Assert.equal(importerCalls.constructed, 1, "the importer starts once the source is quiescent")
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

return { tests = T }
