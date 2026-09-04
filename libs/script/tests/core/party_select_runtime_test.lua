-- Script runtime coverage for party selection: the launch node blocks on
-- the party_select task with the source selection context, while the
-- result node copies an exact slot-or-cancellation value from the
-- instance-scoped handoff into its variable and rejects anything else.
-- Raw args sentinels never reach script variables; a missing service is an
-- attributed fault.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Errors = require("libs.errors.src.Errors")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")

local T = {}

local function openService()
  local catalog = CatalogFixture.makeCatalog()
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0xDDDDDDDD):capture(), catalog:fingerprint()),
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
  return service
end

local function runWith(service)
  local world = {
    vars = {},
    locals = {},
    getVar = function(self, id)
      return self.vars[id]
    end,
    setVar = function(self, id, value)
      self.vars[id] = value
    end,
  }
  local created = {}
  return {
    run = {
      instance = { scriptId = "test.party", locals = {}, textArgs = {} },
      node = { nodeId = "n1" },
      tick = 1,
      input = {},
      services = { mons = service, world = world },
      semantics = RuntimeValues,
      scheduler = {
        createTask = function(_, taskType, spec, _, _, _)
          created[#created + 1] = { taskType = taskType, spec = spec }
          return #created
        end,
      },
    },
    created = created,
    world = world,
  }
end

local function var(id)
  return { value = "var", id = id }
end

function T.launch_blocks_on_the_selection_task()
  local fixture = runWith(openService())
  local outcome = Runtime.executeNode({ op = "party_select" }, fixture.run)
  Assert.equal(outcome, Runtime.OUTCOME_BLOCK)
  Assert.equal(#fixture.created, 1)
  Assert.equal(fixture.created[1].taskType, "party_select")
  local request = fixture.created[1].spec.request
  Assert.equal(request.mode, "select")
  Assert.equal(request.initialSlot, 0)
  Assert.equal(request.eligibility.policy, "occupied")
  Assert.equal(request.allowCancel, true)
  Assert.isNil(fixture.run.blockResultRef, "no game variable is named until the result command runs")
end

function T.result_copies_slots_and_the_cancellation_value()
  local fixture = runWith(openService())
  for _, value in ipairs({ 0, 2, 5, 255 }) do
    fixture.run.instance.locals.__party_selection = value
    Assert.equal(
      Runtime.executeNode({ op = "party_select_result", result = var("V_SEL") }, fixture.run),
      Runtime.OUTCOME_CONTINUE
    )
    Assert.equal(fixture.world.vars.V_SEL, value)
  end
end

function T.result_rejects_unset_and_raw_sentinels()
  local fixture = runWith(openService())
  for _, value in ipairs({ nil, 6, 7, 99 }) do
    fixture.run.instance.locals.__party_selection = value
    local ok, err = pcall(function()
      Runtime.executeNode({ op = "party_select_result", result = var("V_SEL") }, fixture.run)
    end)
    Assert.isFalse(ok, "value " .. tostring(value) .. " must not reach a script variable")
    Assert.isTrue(Errors.is(err))
  end
end

function T.missing_service_is_an_attributed_fault()
  local fixture = runWith(nil)
  local ok, err = pcall(function()
    Runtime.executeNode({ op = "party_select" }, fixture.run)
  end)
  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(err))
  Assert.equal((err --[[@as Errors.Error]]).code, "SCRIPT_SERVICE_MISSING")
end

return { tests = T }
