-- The pure party-screen controller: view (inspect/switch/close) and select
-- (eligible-pick/cancel) modes over an injected immutable view, injected
-- swap, injected layout neighbors/hit-test, and revision reconciliation.
-- Swap fires exactly once with exactly one observed revision increment,
-- cancellation paths never mutate, results are one-shot semantic records
-- with no source sentinels, and pointer input shares the keyboard/gamepad
-- confirm path.

local Assert = require("tests.support.Assert")
local PartyScreenController = require("libs.hgss.src.ui.PartyScreenController")

local T = {}

local function slots(count, eligible)
  local out = {}
  for slot0 = 0, 5 do
    local occupied = slot0 < count
    out[slot0 + 1] = {
      slot = slot0,
      occupied = occupied,
      eligible = occupied and (eligible == nil or eligible[slot0 + 1] ~= false),
      displayName = occupied and ("MON" .. slot0) or nil,
    }
  end
  return out
end

local NEIGHBORS = {
  [0] = { down = 1 },
  [1] = { up = 0, down = 2 },
  [2] = { up = 1, down = 3 },
  [3] = { up = 2, down = 4 },
  [4] = { up = 3, down = 5 },
  [5] = { up = 4, down = "cancel" },
  cancel = { up = 5 },
}

local function fakeLayout(hitTarget)
  return {
    neighbors = NEIGHBORS,
    hitTest = function(_, _)
      return hitTarget
    end,
  }
end

---@param opts table?
---@return table controller, table calls, table model
local function newController(opts)
  opts = opts or {}
  local calls = { swaps = {} }
  local revision = opts.revision or 3
  local current = opts.slots or slots(2)
  local controller = PartyScreenController.new({
    mode = opts.mode or "view",
    initialSlot = opts.initialSlot,
    allowCancel = opts.allowCancel,
    model = {
      refresh = function()
        return { revision = revision, slots = current }
      end,
    },
    swap = function(a, b)
      calls.swaps[#calls.swaps + 1] = { a, b }
      revision = revision + 1
    end,
    resolveLayout = function()
      return fakeLayout(opts.hitTarget)
    end,
  })
  return controller,
    calls,
    {
      setSlots = function(nextSlots, nextRevision)
        current = nextSlots
        if nextRevision ~= nil then
          revision = nextRevision
        else
          revision = revision + 1
        end
      end,
    }
end

local function status(controller)
  return controller:status()
end

function T.view_confirm_opens_the_switch_action()
  local controller = newController()
  controller:updateFixed({ { type = "confirm" } })
  local state = status(controller)
  Assert.equal(state.action, "action_choice")
  Assert.equal(state.cursorNode, 0)
  Assert.isNil(controller:takeResult(), "opening the action choice completes nothing")
end

function T.view_switch_calls_service_once_and_reconciles()
  local controller, calls = newController()
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(status(controller).action, "switch_destination")
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(status(controller).cursorNode, 1)
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(#calls.swaps, 1, "the confirmed switch calls the service exactly once")
  Assert.equal(calls.swaps[1][1], 0)
  Assert.equal(calls.swaps[1][2], 1)
  local state = status(controller)
  Assert.equal(state.action, "browsing")
  Assert.equal(state.cursorNode, 1, "the cursor follows the moved mon")
  Assert.equal(state.view.revision, 4, "exactly one revision increment is observed")
  controller:updateFixed({ { type = "cancel" } })
  local result = controller:takeResult()
  Assert.equal(result.kind, "closed", "an ordinary close carries no slot")
  Assert.isNil(result.slot)
  Assert.isNil(controller:takeResult(), "the result is one-shot")
end

function T.view_cancel_paths_never_mutate()
  local controller, calls = newController()
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "cancel" } })
  Assert.equal(status(controller).action, "browsing")
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "cancel" } })
  Assert.equal(status(controller).action, "browsing")
  Assert.equal(#calls.swaps, 0)
  Assert.equal(status(controller).view.revision, 3)
end

function T.view_confirming_the_source_abandons_the_switch()
  local controller, calls = newController()
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(status(controller).action, "browsing")
  Assert.equal(#calls.swaps, 0, "choosing the source itself swaps nothing")
end

function T.view_navigation_skips_empty_slots()
  local controller = newController({ slots = slots(2) })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(status(controller).cursorNode, 1)
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(status(controller).cursorNode, "cancel", "navigation falls past empty slots to cancel")
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(controller:takeResult().kind, "closed")
end

function T.view_revision_change_reconciles_the_cursor()
  local controller, _, model = newController({ slots = slots(2) })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(status(controller).cursorNode, 1)
  model.setSlots(slots(1))
  controller:updateFixed({})
  Assert.equal(status(controller).cursorNode, 0, "a vanished cursor reconciles to the nearest valid slot")
end

function T.view_pointer_shares_the_confirm_path()
  local controller = newController({ hitTarget = { kind = "slot", slot = 1 } })
  controller:updateFixed({ { type = "pointer_down", pointerId = "p", x = 1, y = 1 } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "p", x = 1, y = 1 } })
  Assert.equal(status(controller).action, "action_choice")
  Assert.equal(status(controller).cursorNode, 1)
end

function T.view_pointer_cancel_closes()
  local controller = newController({ hitTarget = { kind = "cancel" } })
  controller:updateFixed({ { type = "pointer_down", pointerId = "p", x = 1, y = 1 } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "p", x = 1, y = 1 } })
  Assert.equal(controller:takeResult().kind, "closed")
end

function T.view_pointer_cancel_clears_the_capture_without_changing_selection()
  local controller = newController({ hitTarget = { kind = "slot", slot = 1 } })
  controller:updateFixed({ { type = "pointer_down", pointerId = "p", x = 1, y = 1 } })
  controller:updateFixed({
    { type = "pointer_cancel" },
    { type = "pointer_up", pointerId = "p", x = 1, y = 1 },
  })
  Assert.isNil(controller:takeResult(), "a cancelled press never activates")
  Assert.isTrue(status(controller).open)
  Assert.equal(status(controller).cursorNode, 0, "cancellation changes no selection")
  Assert.equal(status(controller).action, "browsing", "cancellation changes no action")
end

function T.view_dragged_pointer_commits_nothing()
  local controller = newController({ hitTarget = { kind = "cancel" } })
  controller:updateFixed({ { type = "pointer_down", pointerId = "p", x = 1, y = 1 } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "p", x = 9, y = 9, dragged = true } })
  Assert.isNil(controller:takeResult(), "a drag never activates its release target")
  Assert.isTrue(status(controller).open)
end

function T.select_confirm_returns_the_semantic_slot()
  local controller = newController({ mode = "select", slots = slots(3, { true, false, true }) })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(status(controller).cursorNode, 2, "navigation skips the ineligible slot")
  controller:updateFixed({ { type = "confirm" } })
  local result = controller:takeResult()
  Assert.deepEqual(result, { kind = "selected", slot = 2 }, "selection carries no source sentinel")
end

function T.select_rejects_ineligible_and_empty_slots()
  local controller = newController({ mode = "select", slots = slots(3, { true, false, true }) })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(status(controller).cursorNode, 2, "directional input skips ineligible slots")
  controller:updateFixed({
    { type = "navigate", direction = "down" },
    { type = "navigate", direction = "down" },
    { type = "navigate", direction = "down" },
    { type = "navigate", direction = "down" },
  })
  Assert.equal(status(controller).cursorNode, "cancel", "empty slots never become selectable")
  controller:updateFixed({ { type = "navigate", direction = "up" } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(controller:takeResult(), { kind = "selected", slot = 2 })
end

function T.select_cancel_returns_cancelled_when_allowed()
  local controller = newController({ mode = "select", allowCancel = true })
  controller:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(controller:takeResult(), { kind = "cancelled" })
end

function T.select_cancel_is_inert_when_forbidden()
  local controller = newController({ mode = "select", allowCancel = false })
  controller:updateFixed({ { type = "cancel" } })
  Assert.isNil(controller:takeResult(), "a forbidden cancel completes nothing")
  Assert.isTrue(status(controller).open)
  controller:updateFixed({ { type = "confirm" } })
  Assert.deepEqual(controller:takeResult(), { kind = "selected", slot = 0 })
end

function T.select_never_swaps()
  local controller, calls = newController({ mode = "select" })
  controller:updateFixed({ { type = "confirm" } })
  controller:takeResult()
  Assert.equal(#calls.swaps, 0, "selection mode owns no swap path")
end

function T.completed_controller_ignores_further_input()
  local controller = newController({ mode = "select" })
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "navigate", direction = "down" }, { type = "cancel" } })
  Assert.deepEqual(controller:takeResult(), { kind = "selected", slot = 0 })
end

function T.cancelled_pointer_capture_never_activates()
  local controller = newController({ hitTarget = { kind = "cancel" } })
  controller:updateFixed({ { type = "pointer_down", pointerId = "p", x = 1, y = 1 } })
  controller:cancelPointerCapture()
  controller:updateFixed({ { type = "pointer_up", pointerId = "p", x = 1, y = 1 } })
  Assert.isNil(controller:takeResult(), "a capture lost to a layout change activates nothing")
  Assert.isTrue(status(controller).open)
end

function T.view_dismiss_from_browsing_closes_immediately()
  local controller = newController()
  controller:updateFixed({ { type = "dismiss" } })
  local result = controller:takeResult()
  Assert.equal(result.kind, "closed", "dismiss closes the party without unwinding")
  Assert.isNil(result.slot, "an outside close carries no slot")
  Assert.isFalse(status(controller).open, "the party is closed")
end

function T.view_dismiss_from_action_choice_closes_without_returning_to_browsing()
  local controller, calls = newController()
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(status(controller).action, "action_choice", "setup opens the nested action choice")
  controller:updateFixed({ { type = "dismiss" } })
  Assert.equal(controller:takeResult().kind, "closed", "dismiss closes instead of popping one level")
  Assert.isFalse(status(controller).open, "the party is closed")
  Assert.equal(#calls.swaps, 0, "dismiss never swaps")
end

function T.view_dismiss_from_switch_destination_closes_without_swapping()
  local controller, calls = newController()
  controller:updateFixed({ { type = "confirm" } })
  controller:updateFixed({ { type = "confirm" } })
  Assert.equal(status(controller).action, "switch_destination", "setup enters the nested switch target")
  controller:updateFixed({ { type = "dismiss" } })
  Assert.equal(controller:takeResult().kind, "closed", "dismiss closes instead of abandoning the switch")
  Assert.equal(#calls.swaps, 0, "dismiss never swaps")
end

function T.view_dismiss_ends_the_batch_so_later_events_cannot_overwrite_the_close()
  local controller = newController()
  controller:updateFixed({ { type = "dismiss" }, { type = "confirm" } })
  Assert.equal(controller:takeResult().kind, "closed", "only the terminal close survives the batch")
  Assert.isNil(controller:takeResult(), "the close result is delivered exactly once")
end

function T.select_dismiss_is_a_programming_error()
  local controller = newController({ mode = "select" })
  local err = Assert.throws(function()
    controller:updateFixed({ { type = "dismiss" } })
  end, "no current producer dismisses script selection")
  Assert.isTrue(
    tostring(err):find("select", 1, true) ~= nil,
    "the failure must name select mode, not a generic unknown event: " .. tostring(err)
  )
end

return { tests = T }
