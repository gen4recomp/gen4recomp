-- Starter task save and restore: a task captured in the stable choice
-- phase resumes with identical candidates and cursor, never rerolls the
-- generator, and can publish the selection exactly once.

local Assert = require("tests.support.Assert")
local BoxCodec = require("libs.mons.src.gen4.BoxCodec")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

local T = {}

local TASK_MODULE = "libs.hgss.src.script.tasks.ChooseStarterTask"
local SERVICE_MODULE = "libs.hgss.src.mons.HgssMonService"

local TRIO = { "CHIKORITA", "TOTODILE", "EEVEE" }
local SEED = 0x9ABCDEF0

local function requireTask()
  local ok, task = pcall(require, TASK_MODULE)
  Assert.isTrue(ok, "the starter task owns serializable choice state")
  return assert(task)
end

local function requireService()
  local ok, service = pcall(require, SERVICE_MODULE)
  Assert.isTrue(ok, "the HGSS mon service restores the live party for a resumed choice")
  return assert(service)
end

local function openService(catalog, bucket)
  local HgssMonService = requireService()
  return HgssMonService.new({
    catalog = catalog,
    bucket = bucket,
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    mapSection = 7,
    date = CatalogFixture.metDate(),
  })
end

local function freshBucket(catalog)
  return MonsSave.capture(Party.new():capture(), Lcrng.new(SEED):capture(), catalog:fingerprint())
end

local function providerFor(species)
  return {
    resolve = function()
      return { species[1], species[2], species[3] }
    end,
  }
end

local function modalHost()
  local host = { opened = 0, closed = 0, done = false, index = nil }
  function host:open(_)
    self.opened = self.opened + 1
  end
  function host:close()
    self.closed = self.closed + 1
  end
  function host:status()
    if self.done then
      return { done = true, index = self.index }
    end
    if self.opened > self.closed then
      return { done = false }
    end
    return nil
  end
  function host:finish(index)
    self.done = true
    self.index = index
  end
  return host
end

local function boxedBytes(catalog, mon)
  return BoxCodec.encode(mon, CatalogFixture.domainContext(catalog))
end

function T.restored_choice_keeps_candidates_cursor_and_generator_state()
  local catalog = CatalogFixture.makeCatalog()
  local task = requireTask()
  local service = openService(catalog, freshBucket(catalog))
  local host = modalHost()
  local ctx = {
    services = { mons = service, starterProvider = providerFor(TRIO), starterChoice = host },
    input = { uiEvents = {} },
    instance = { scriptId = "starter-save-fixture" },
  }

  local state = task.create({ node = { op = "choose_starter" } }, ctx)
  for _ = 1, 4 do
    task.poll(state, ctx)
    if host.opened >= 1 then
      break
    end
  end
  local candidateBytes = {}
  for index, candidate in ipairs(state.candidates) do
    candidateBytes[index] = boxedBytes(catalog, candidate)
  end
  Assert.isNil(task.validate(state), "the stable choice phase serializes cleanly")

  local savedBucket = service:capture()
  local savedCalls = savedBucket.rng.calls
  Assert.isTrue(savedCalls > 0, "generation consumes generator draws before save")

  local restoredService = openService(catalog, savedBucket)
  local restoredHost = modalHost()
  local restoredCtx = {
    services = { mons = restoredService, starterProvider = providerFor(TRIO), starterChoice = restoredHost },
    input = { uiEvents = {} },
    instance = { scriptId = "starter-save-fixture" },
  }
  Assert.isNil(task.validate(state), "restored state still validates")
  Assert.equal(restoredService:capture().rng.calls, savedCalls, "restore itself draws nothing")
  Assert.equal(restoredService:partyCount(), 0, "restore publishes nothing early")

  local waiting = task.poll(state, restoredCtx)
  Assert.isFalse(waiting.complete, "the resumed choice waits for confirmation")
  for index, candidate in ipairs(state.candidates) do
    Assert.equal(boxedBytes(catalog, candidate), candidateBytes[index], "resumed candidate bytes are preserved")
  end

  restoredHost:finish(2)
  local outcome = task.poll(state, restoredCtx)
  Assert.isTrue(outcome.complete, "the resumed choice completes on confirmation")
  Assert.equal(restoredService:partyCount(), 1, "the selection is inserted exactly once")
  Assert.equal(
    boxedBytes(catalog, restoredService:partyMon(0)),
    candidateBytes[3],
    "the inserted mon matches the pre-save candidate"
  )
  Assert.equal(restoredService:capture().rng.calls, savedCalls, "publication draws nothing after restore")

  local repeatOutcome = task.poll(state, restoredCtx)
  Assert.isTrue(repeatOutcome.complete, "a reloaded done phase stays complete")
  Assert.equal(restoredService:partyCount(), 1, "a reloaded task never inserts twice")
end

function T.task_state_carries_no_native_byte_buffers()
  local catalog = CatalogFixture.makeCatalog()
  local task = requireTask()
  local service = openService(catalog, freshBucket(catalog))
  local host = modalHost()
  local ctx = {
    services = { mons = service, starterProvider = providerFor(TRIO), starterChoice = host },
    input = { uiEvents = {} },
    instance = { scriptId = "starter-save-fixture" },
  }
  local state = task.create({ node = { op = "choose_starter" } }, ctx)
  for _ = 1, 4 do
    task.poll(state, ctx)
    if host.opened >= 1 then
      break
    end
  end

  local function noByteBuffers(value, path)
    if type(value) == "string" then
      Assert.isTrue(#value ~= 136, path .. " must not carry a native boxed buffer")
    elseif type(value) == "table" then
      for key, entry in pairs(value) do
        noByteBuffers(entry, path .. "." .. tostring(key))
      end
    end
  end
  noByteBuffers(state, "task state")
end

return { tests = T }
