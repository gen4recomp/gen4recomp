-- Script runtime coverage for the generic Bag/item operations: semantic
-- nodes evaluate their item/quantity operands, call exactly one named
-- operation on the injected Bag service, and write the source result
-- convention to the result variable (1 or 0 for booleans, the native pocket
-- id or exact quantity for queries). Every node continues in the same tick;
-- none blocks or yields. A missing service is an attributed fault, and an
-- unknown native identity is an attributed reference error, never a read of
-- an absent item.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local ItemFixture = require("libs.items.tests.item_fixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")

local T = {}

local POTION = 17
local TM01 = 328
local CHERI_BERRY = 149

local function openService()
  return HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
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
  local services = { world = world }
  if service ~= nil then
    services.items = service
  end
  return {
    instance = { scriptId = "test.items", locals = {}, textArgs = {} },
    services = services,
    semantics = RuntimeValues,
  }
end

local function var(id)
  return { value = "var", id = id }
end

function T.add_and_take_write_the_source_boolean_result()
  local service = openService()
  local run = runWith(service)
  Assert.equal(
    Runtime.executeNode({ op = "bag_add_item", item = POTION, quantity = 5, result = var("V_ADD") }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(run.services.world.vars.V_ADD, 1, "a successful grant reports success")
  Assert.equal(service:quantity("POTION"), 5)
  Assert.equal(
    Runtime.executeNode({ op = "bag_take_item", item = POTION, quantity = 2, result = var("V_TAKE") }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(run.services.world.vars.V_TAKE, 1)
  Assert.equal(service:quantity("POTION"), 3)
  Assert.equal(
    Runtime.executeNode({ op = "bag_take_item", item = POTION, quantity = 99, result = var("V_SHORT") }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(run.services.world.vars.V_SHORT, 0, "an insufficient take reports failure")
  Assert.equal(service:quantity("POTION"), 3, "a failed take mutates nothing")
end

function T.space_and_presence_queries_write_results_without_mutating()
  local service = openService()
  local run = runWith(service)
  local revision = service:revision()
  Assert.equal(
    Runtime.executeNode({ op = "bag_has_space", item = POTION, quantity = 5, result = var("V_SPACE") }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(run.services.world.vars.V_SPACE, 1)
  Assert.equal(
    Runtime.executeNode({ op = "bag_has_item", item = POTION, quantity = 1, result = var("V_HAS") }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(run.services.world.vars.V_HAS, 0, "an absent item reports not-held")
  Runtime.executeNode({ op = "bag_add_item", item = POTION, quantity = 5, result = var("V_FILL") }, run)
  Runtime.executeNode({ op = "bag_has_item", item = POTION, quantity = 5, result = var("V_HELD") }, run)
  Assert.equal(run.services.world.vars.V_HELD, 1)
  Runtime.executeNode({ op = "bag_has_item", item = POTION, quantity = 6, result = var("V_PARTIAL") }, run)
  Assert.equal(run.services.world.vars.V_PARTIAL, 0, "a short stack reports not-held")
  Assert.equal(service:revision(), revision + 1, "queries never bump the service revision")
end

function T.catalog_queries_write_native_answers()
  local service = openService()
  local run = runWith(service)
  Runtime.executeNode({ op = "item_is_tmhm", item = TM01, result = var("V_TM") }, run)
  Assert.equal(run.services.world.vars.V_TM, 1, "a machine reports as TM/HM")
  Runtime.executeNode({ op = "item_is_tmhm", item = POTION, result = var("V_NOTM") }, run)
  Assert.equal(run.services.world.vars.V_NOTM, 0)
  Runtime.executeNode({ op = "item_get_pocket", item = POTION, result = var("V_POCKET") }, run)
  Assert.equal(run.services.world.vars.V_POCKET, 1, "medicine rides native pocket id 1")
  Runtime.executeNode({ op = "bag_get_quantity", item = POTION, result = var("V_QTY") }, run)
  Assert.equal(run.services.world.vars.V_QTY, 0, "an absent item reads quantity zero")
  Runtime.executeNode({ op = "bag_add_item", item = CHERI_BERRY, quantity = 3, result = var("V_ADD") }, run)
  Runtime.executeNode({ op = "bag_get_quantity", item = CHERI_BERRY, result = var("V_BERRY_QTY") }, run)
  Assert.equal(run.services.world.vars.V_BERRY_QTY, 3)
end

function T.item_nodes_continue_same_tick_and_write_only_the_result()
  local service = openService()
  local run = runWith(service, { V_KEEP = 7 })
  local nodes = {
    { op = "bag_add_item", item = POTION, quantity = 1, result = var("V_R") },
    { op = "bag_take_item", item = POTION, quantity = 1, result = var("V_R") },
    { op = "bag_has_space", item = POTION, quantity = 1, result = var("V_R") },
    { op = "bag_has_item", item = POTION, quantity = 1, result = var("V_R") },
    { op = "item_is_tmhm", item = POTION, result = var("V_R") },
    { op = "item_get_pocket", item = POTION, result = var("V_R") },
    { op = "bag_get_quantity", item = POTION, result = var("V_R") },
  }
  for _, node in ipairs(nodes) do
    Assert.equal(
      Runtime.executeNode(node, run),
      Runtime.OUTCOME_CONTINUE,
      "item operation " .. node.op .. " continues in the same tick"
    )
  end
  Assert.equal(run.services.world.vars.V_KEEP, 7, "no node touches an undeclared variable")
end

function T.missing_items_service_is_an_attributed_fault()
  local run = runWith(nil)
  local err = Assert.throws(function()
    Runtime.executeNode({ op = "bag_get_quantity", item = POTION, result = var("V_QTY") }, run)
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "SCRIPT_SERVICE_MISSING")
end

function T.unknown_native_item_is_an_attributed_reference_error()
  local service = openService()
  local run = runWith(service)
  local err = Assert.throws(function()
    Runtime.executeNode({ op = "bag_get_quantity", item = 9999, result = var("V_QTY") }, run)
  end)
  Assert.isTrue(Errors.is(err), "an unknown native identity faults instead of reading an absent item")
  Assert.isNil(run.services.world.vars.V_QTY, "the fault writes no result")
end

return { tests = T }
