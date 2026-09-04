-- Script runtime coverage for the follower settle check: with a partner
-- actor installed, the source settle/update step yields through the
-- following controller instead of faulting as an unsupported reachable
-- path. Without a partner it remains an ordinary scheduler yield.

local Assert = require("tests.support.Assert")
local Runtime = require("libs.script.src.Runtime")

local T = {}

local function runWith(partner)
  return {
    instance = { scriptId = "test.follower", locals = {}, textArgs = {} },
    services = {
      actors = {
        partnerId = function()
          return partner
        end,
      },
    },
  }
end

local function settleNode()
  return { op = "yield_tick", source = { opcodes = { 609 } } }
end

function T.settle_check_with_an_installed_partner_yields_without_fault()
  local outcome = Runtime.executeNode(settleNode(), runWith("field:partner"))
  Assert.equal(outcome, Runtime.OUTCOME_YIELD_TICK, "the active settle path yields onto the controller")
end

function T.settle_check_without_a_partner_remains_a_plain_yield()
  local outcome = Runtime.executeNode(settleNode(), runWith(nil))
  Assert.equal(outcome, Runtime.OUTCOME_YIELD_TICK, "the no-follower path stays one scheduler yield")
end

return { tests = T }
