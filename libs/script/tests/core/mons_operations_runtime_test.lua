-- Script runtime coverage for the mon/party operations: semantic nodes
-- evaluate their operands, call exactly one named service operation, and
-- write the source result convention to the result variable. A missing
-- service is an attributed fault, never a silent skip.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Errors = require("libs.errors.src.Errors")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
local Compiler = require("libs.script.src.Compiler")
local S = require("gen4.script")

local T = {}

local function openService()
  local catalog = CatalogFixture.makeCatalog()
  local bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0xDDDDDDDD):capture(), catalog:fingerprint())
  local service = HgssMonService.new({
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
  Assert.isTrue(service:giveMon({
    species = "CHIKORITA",
    level = 5,
    heldItem = "NONE",
    form = 0,
    location = 7,
    date = CatalogFixture.metDate(),
  }))
  Assert.isTrue(service:giveMon({
    species = "TOTODILE",
    level = 5,
    heldItem = "NONE",
    form = 0,
    location = 7,
    date = CatalogFixture.metDate(),
  }))
  return service
end

local function runWith(service, vars)
  local world = {
    vars = vars or {},
    getVar = function(self, id)
      return self.vars[id]
    end,
    setVar = function(self, id, value)
      self.vars[id] = value
    end,
  }
  return {
    instance = { scriptId = "test.mons", locals = {}, textArgs = {} },
    services = { mons = service, world = world },
    semantics = RuntimeValues,
  }
end

local function var(id)
  return { value = "var", id = id }
end

function T.give_mon_writes_the_source_boolean_result()
  local service = openService()
  local run = runWith(service)
  Assert.equal(
    Runtime.executeNode({
      op = "give_mon",
      species = "EEVEE",
      level = 5,
      result = var("VAR_RESULT"),
    }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(run.services.world.vars.VAR_RESULT, 1, "the gift reports success")
  Assert.equal(service:partyCount(), 3, "the created mon enters the party")
end

function T.queries_write_counts_slots_and_sentinels()
  local service = openService()
  local run = runWith(service)
  Assert.equal(Runtime.executeNode({ op = "party_count", result = var("V_COUNT") }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(run.services.world.vars.V_COUNT, 2)
  Runtime.executeNode({ op = "party_slot_with_species", species = "TOTODILE", result = var("V_SLOT") }, run)
  Assert.equal(run.services.world.vars.V_SLOT, 1, "searches write zero-based slots")
  Runtime.executeNode({ op = "party_slot_with_species", species = "EEVEE", result = var("V_MISS") }, run)
  Assert.equal(run.services.world.vars.V_MISS, 6, "missed searches write the party-size sentinel")
  Runtime.executeNode({ op = "count_alive_mons", excludeSlot = 6, result = var("V_ALIVE") }, run)
  Assert.equal(run.services.world.vars.V_ALIVE, 2)
  Runtime.executeNode({ op = "count_alive_mons", excludeSlot = 0, result = var("V_ONE") }, run)
  Assert.equal(run.services.world.vars.V_ONE, 1)
end

function T.mutations_go_through_the_service_once()
  local service = openService()
  local run = runWith(service)
  local revision = service:partyRevision()
  Runtime.executeNode({ op = "mon_add_friendship", amount = 10, slot = 0 }, run)
  Assert.equal(service:monFriendship(0), 80, "the amount-first operands add correctly")
  Assert.equal(service:partyRevision(), revision + 1, "one node is one mutation")
  Runtime.executeNode({ op = "set_mon_move", slot = 0, moveSlot = 0, move = "CUT" }, run)
  Assert.equal(service:partyMon(0).moves[1].move, "CUT")
  Runtime.executeNode({ op = "heal_party" }, run)
  Assert.equal(service:partyMon(0).condition.status, 0)
end

function T.missing_service_is_an_attributed_fault()
  local run = runWith(nil)
  local ok, err = pcall(function()
    Runtime.executeNode({ op = "party_count", result = var("V_COUNT") }, run)
  end)
  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(err))
  ---@cast err Errors.Error
  Assert.equal(err.code, "SCRIPT_SERVICE_MISSING")
end

function T.invalid_slots_fail_before_any_write()
  local service = openService()
  local run = runWith(service, { V_COUNT = -1 })
  local ok, err = pcall(function()
    Runtime.executeNode({ op = "party_mon_species", slot = 9, result = var("V_COUNT") }, run)
  end)
  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(err))
  Assert.equal(run.services.world.vars.V_COUNT, -1, "the failed read writes no result")
end

function T.dsl_constructors_compile_to_validated_graphs()
  local step = S.giveMon({ species = "CHIKORITA", level = 5, result = S.var("V") })
  Assert.equal(step.op, "give_mon")
  local graph = assert(Compiler.compile(S.script({ api = 1, id = "test.mons", steps = { step } })))
  Assert.equal(graph.nodes[graph.entry].op, "give_mon")
  local _, bad = Compiler.compile(S.script({
    api = 1,
    id = "test.mons.bad",
    steps = { { op = "give_mon", species = "CHIKORITA", level = 5, result = 7 } },
  }))
  Assert.isTrue(Errors.is(bad), "a literal result is rejected")
end

return { tests = T }
