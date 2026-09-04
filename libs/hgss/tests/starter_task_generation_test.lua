-- Starter task generation and publication: all three candidates are built
-- in provider order before the choice UI opens, and confirmation transfers
-- the exact chosen instance into the party without rerolling. A full party
-- at publication is a structured invariant error, never a silent
-- discard or PC fallback.

local Assert = require("tests.support.Assert")
local BoxCodec = require("libs.mons.src.gen4.BoxCodec")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Errors = require("libs.errors.src.Errors")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

local T = {}

local TASK_MODULE = "libs.hgss.src.script.tasks.ChooseStarterTask"
local SERVICE_MODULE = "libs.hgss.src.mons.HgssMonService"

local TRIO = { "CHIKORITA", "TOTODILE", "EEVEE" }
local SEED = 0x12345678
local CALLS_PER_STARTER = 4

local function requireTask()
  local ok, task = pcall(require, TASK_MODULE)
  Assert.isTrue(ok, "the starter task owns candidate generation and selected publication")
  return assert(task)
end

local function requireService()
  local ok, service = pcall(require, SERVICE_MODULE)
  Assert.isTrue(ok, "the HGSS mon service owns the live party used by starter selection")
  return assert(service)
end

local function openService(catalog, seed)
  local HgssMonService = requireService()
  return HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(seed):capture(), catalog:fingerprint()),
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

local function providerFor(species)
  return {
    resolve = function()
      return { species[1], species[2], species[3] }
    end,
  }
end

local function modalHost()
  local host = { opened = 0, closed = 0, cursor = nil, done = false, index = nil }
  function host:open(cursor)
    self.opened = self.opened + 1
    self.cursor = cursor
  end
  function host:close()
    self.closed = self.closed + 1
  end
  function host:status()
    if self.done then
      return { done = true, index = self.index }
    end
    if self.opened > self.closed then
      return { done = false, cursor = self.cursor }
    end
    return nil
  end
  function host:finish(index)
    self.done = true
    self.index = index
  end
  return host
end

local function ctxFor(service, species, host)
  return {
    services = {
      mons = service,
      starterProvider = providerFor(species),
      starterChoice = host,
    },
    input = { uiEvents = {} },
    instance = { scriptId = "starter-generation-fixture" },
  }
end

local function rngCalls(service)
  return service:capture().rng.calls
end

local function boxedBytes(catalog, mon)
  return BoxCodec.encode(mon, CatalogFixture.domainContext(catalog))
end

local function generate(service, species, host)
  local task = requireTask()
  local ctx = ctxFor(service, species, host)
  local state = task.create({ node = { op = "choose_starter" } }, ctx)
  for _ = 1, 4 do
    local outcome = task.poll(state, ctx)
    Assert.isFalse(outcome.complete, "generation and opening must not complete the task")
    if host.opened >= 1 then
      break
    end
  end
  Assert.equal(host.opened, 1, "the choice UI opens exactly once after generation")
  return task, ctx, state
end

function T.three_candidates_are_created_before_the_ui_opens()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED)
  local host = modalHost()
  local _, _, state = generate(service, TRIO, host)

  Assert.equal(service:partyCount(), 0, "generation must not publish into the party")
  Assert.equal(rngCalls(service), #TRIO * CALLS_PER_STARTER, "generation consumes the exact source draws")
  Assert.notNil(state.candidates, "task state carries the three candidates")
  Assert.equal(#state.candidates, 3, "all three candidates are pre-created")
  for index, key in ipairs(TRIO) do
    Assert.equal(state.candidates[index].species, key, "candidate order follows the provider")
    Assert.equal(state.candidates[index].form, 0, "candidates are native form zero")
  end
  local seen = {}
  for _, candidate in ipairs(state.candidates) do
    Assert.isNil(seen[candidate.personality], "candidates are distinct source-derived records")
    seen[candidate.personality] = true
  end
end

function T.confirmation_transfers_the_exact_chosen_instance()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED)
  local host = modalHost()
  local task, ctx, state = generate(service, TRIO, host)

  local before = {}
  for index, candidate in ipairs(state.candidates) do
    before[index] = boxedBytes(catalog, candidate)
  end
  local callsAtChoose = rngCalls(service)

  task.poll(state, ctx)
  host:finish(1)
  local outcome = task.poll(state, ctx)

  Assert.isTrue(outcome.complete, "semantic confirmation completes the task")
  Assert.equal(outcome.result.index, 1, "the result names the confirmed candidate")
  Assert.equal(service:partyCount(), 1, "exactly the chosen mon enters the party")
  Assert.equal(service:partyMon(0).species, "TOTODILE", "the party holds the confirmed species")
  Assert.equal(
    boxedBytes(catalog, service:partyMon(0)),
    before[2],
    "the party entry encodes byte-identically to the pre-choice candidate"
  )
  Assert.equal(rngCalls(service), callsAtChoose, "confirmation performs no additional creation draws")
  Assert.equal(host.closed, 1, "the modal closes exactly once on publication")
end

function T.substituted_provider_species_use_the_same_creation_policy()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED)
  local substituted = { "EEVEE", "CHIKORITA", "TOTODILE" }
  local host = modalHost()
  local _, _, state = generate(service, substituted, host)

  for index, key in ipairs(substituted) do
    Assert.equal(state.candidates[index].species, key, "substituted species are created in order")
  end
  Assert.equal(service:partyCount(), 0, "substitution changes species, not publication")
  Assert.equal(rngCalls(service), #substituted * CALLS_PER_STARTER, "substitution keeps the exact draw policy")

  host:finish(0)
  local task = requireTask()
  local confirmCtx = ctxFor(service, substituted, host)
  local outcome = task.poll(state, confirmCtx)
  Assert.isTrue(outcome.complete, "substituted candidates publish through the same path")
  Assert.equal(service:partyCount(), 1, "the substituted choice enters the party")
  Assert.equal(service:partyMon(0).species, "EEVEE", "the party holds the substituted choice")
end

function T.unresolvable_species_fail_before_any_generator_draw()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED)
  local host = modalHost()
  local task = requireTask()
  local ctx = ctxFor(service, { "CHIKORITA", "MISSINGNO", "EEVEE" }, host)

  local err = Assert.throws(function()
    task.create({ node = { op = "choose_starter" } }, ctx)
  end)
  Assert.isTrue(Errors.is(err), "unknown provider species fail with a structured error")
  Assert.equal(rngCalls(service), 0, "failed validation draws nothing")
  Assert.equal(service:partyCount(), 0, "failed validation publishes nothing")
  Assert.equal(host.opened, 0, "failed validation never opens the choice UI")
end

function T.full_party_at_publication_is_a_structured_error_without_mutation()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED)
  for _ = 1, 6 do
    Assert.isTrue(
      service:giveMon({
        species = "EEVEE",
        level = 5,
        heldItem = "NONE",
        form = 0,
        location = 7,
        date = CatalogFixture.metDate(),
      }),
      "setup gifts must fill the party"
    )
  end
  local partyBefore = {}
  for slot = 0, 5 do
    partyBefore[slot] = boxedBytes(catalog, service:partyMon(slot))
  end

  local host = modalHost()
  local task, ctx, state = generate(service, TRIO, host)
  task.poll(state, ctx)
  host:finish(2)
  local err = Assert.throws(function()
    task.poll(state, ctx)
  end)
  Assert.isTrue(Errors.is(err), "publishing into a full party fails with a structured error")
  Assert.equal(service:partyCount(), 6, "the full party is unchanged")
  for slot = 0, 5 do
    Assert.equal(boxedBytes(catalog, service:partyMon(slot)), partyBefore[slot], "no slot is overwritten")
  end

  local again = Assert.throws(function()
    task.poll(state, ctx)
  end)
  Assert.isTrue(Errors.is(again), "retrying publication still fails instead of duplicating")
  Assert.equal(service:partyCount(), 6, "no duplicate insertion follows the failure")
end

function T.completed_publication_is_idempotent()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, SEED)
  local host = modalHost()
  local task, ctx, state = generate(service, TRIO, host)
  task.poll(state, ctx)
  host:finish(0)
  local outcome = task.poll(state, ctx)
  Assert.isTrue(outcome.complete, "first confirmation completes")

  local repeatOutcome = task.poll(state, ctx)
  Assert.isTrue(repeatOutcome.complete, "a restored done phase stays complete")
  Assert.equal(service:partyCount(), 1, "re-polling never inserts twice")
end

return { tests = T }
