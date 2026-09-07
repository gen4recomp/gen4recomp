-- Retail starter chooser semantics: the pure controller moves through
-- unconfirmed inspection, zoomed confirmation with back-out, and a final
-- lock that reports only after its exit transition settles. Left and right
-- rotate one step while unconfirmed and are ignored while confirmed or
-- mid-transition; cancel only backs out of confirmation and never dismisses
-- the application. There is no yes/no cursor anywhere in this contract.

local Assert = require("tests.support.Assert")

local T = {}

local CONTROLLER_MODULE = "libs.hgss.src.ui.StarterChoiceController"

local NAMES = { "Chikorita", "Cyndaquil", "Totodile" }

local function requireController()
  local ok, controller = pcall(require, CONTROLLER_MODULE)
  Assert.isTrue(ok, "the starter controller owns the retail chooser state")
  return assert(controller)
end

local function openController(cursor)
  local StarterChoiceController = requireController()
  return StarterChoiceController.new({ candidates = NAMES, initialCursor = cursor or 0 })
end

local function snapshot(controller)
  if type(controller.snapshot) == "function" then
    return controller:snapshot()
  end
  return controller:status()
end

local function selectionIndex(snap)
  if type(snap.candidateIndex) == "number" then
    return snap.candidateIndex
  end
  if type(snap.selection) == "number" then
    return snap.selection
  end
  if type(snap.selectionIndex) == "number" then
    return snap.selectionIndex
  end
  if type(snap.cursor) == "number" then
    return snap.cursor
  end
  if type(snap.index) == "number" and snap.done ~= true then
    return snap.index
  end
  error("chooser snapshot names no selection index", 0)
end

local function isDone(controller, snap)
  if snap.done == true then
    return true
  end
  if snap.state == "complete" then
    return true
  end
  local phase = snap.transition or snap.phase
  if phase == "done" then
    return true
  end
  if type(controller.isActive) == "function" then
    return not controller:isActive()
  end
  return false
end

local function resultIndex(controller, snap)
  if type(snap.index) == "number" and snap.done == true then
    return snap.index
  end
  if type(snap.resultIndex) == "number" then
    return snap.resultIndex
  end
  if snap.result ~= nil and type(snap.result.index) == "number" then
    return snap.result.index
  end
  if type(controller.result) == "function" then
    local result = controller:result()
    if result ~= nil then
      if type(result) == "number" then
        return result
      end
      if type(result.index) == "number" then
        return result.index
      end
      if type(result.candidate) == "number" then
        return result.candidate
      end
    end
  end
  return nil
end

local function assertNoLegacyConfirmation(snap, label)
  Assert.isNil(snap.confirmIndex, label .. " carries no yes/no cursor")
  Assert.isTrue(
    snap.mode == nil or (snap.mode ~= "selecting" and snap.mode ~= "confirming"),
    label .. " never uses the generic selection/confirmation mode"
  )
end

-- Runs any deterministic phase-completion hook the controller exposes until
-- the snapshot stops changing or the bound is reached. Controllers without a
-- clock hook settle immediately.
local function settle(controller, bound)
  bound = bound or 64
  local tickers = { "update", "tick", "updateFixed", "advance", "step" }
  for _ = 1, bound do
    local before = snapshot(controller)
    local advanced = false
    for _, name in ipairs(tickers) do
      if type(controller[name]) == "function" then
        controller[name](controller)
        advanced = true
      end
    end
    if not advanced then
      return
    end
    local after = snapshot(controller)
    if isDone(controller, after) then
      return
    end
    local moved = false
    for key, value in pairs(after) do
      if before[key] ~= value then
        moved = true
        break
      end
    end
    if not moved then
      return
    end
  end
end

-- Rotates one retail step in the given direction. Prefers a direction-based
-- controller entry point and falls back to focusing the neighboring index so
-- the acceptance intent still executes against older method shapes.
local function rotate(controller, direction)
  Assert.isTrue(direction == "left" or direction == "right", "rotation names a retail direction")
  if type(controller.move) == "function" then
    controller:move(direction)
    return
  end
  if type(controller.navigate) == "function" then
    controller:navigate(direction)
    return
  end
  if type(controller.rotate) == "function" then
    controller:rotate(direction)
    return
  end
  local current = selectionIndex(snapshot(controller))
  local delta = direction == "right" and 1 or -1
  controller:focus((current + delta) % 3)
end

function T.first_activation_inspects_and_second_reaches_confirmation_only_after_settling()
  local controller = openController(0)
  local initial = snapshot(controller)
  Assert.isFalse(isDone(controller, initial), "the chooser opens waiting for input")
  Assert.equal(selectionIndex(initial), 0, "the chooser opens on the first ball")
  assertNoLegacyConfirmation(initial, "the fresh chooser")

  Assert.isNil(controller:confirm(), "first activation inspects instead of publishing")
  local inspected = snapshot(controller)
  Assert.isFalse(isDone(controller, inspected), "inspection still waits for confirmation")
  Assert.equal(selectionIndex(inspected), 0, "inspection keeps the current ball")
  assertNoLegacyConfirmation(inspected, "the inspected chooser")

  Assert.isNil(controller:confirm(), "second activation starts the zoom path, not the lock")
  local zooming = snapshot(controller)
  Assert.isFalse(isDone(controller, zooming), "the lock must wait for the zoom/wait transition to settle")
  Assert.isNil(resultIndex(controller, zooming), "no candidate reports before confirmation settles")
  assertNoLegacyConfirmation(zooming, "the zooming chooser")

  settle(controller)
  local confirmed = snapshot(controller)
  Assert.isFalse(isDone(controller, confirmed), "reaching confirmation still waits for the final lock")
  Assert.equal(selectionIndex(confirmed), 0, "the zoom path preserves the inspected ball")
  assertNoLegacyConfirmation(confirmed, "the confirmed chooser")
end

function T.cancel_backs_out_only_from_confirmation_and_never_dismisses()
  local controller = openController(0)
  Assert.isNil(controller:cancel(), "cancel outside confirmation is a no-op")
  Assert.isFalse(isDone(controller, snapshot(controller)), "cancel never dismisses the application")
  Assert.equal(selectionIndex(snapshot(controller)), 0, "cancel elsewhere keeps the ball")

  controller:confirm()
  controller:confirm()
  settle(controller)
  Assert.isFalse(isDone(controller, snapshot(controller)), "the zoom path must settle into confirmation first")

  Assert.isNil(controller:cancel(), "backing out of confirmation publishes nothing")
  settle(controller)
  local backedOut = snapshot(controller)
  Assert.isFalse(isDone(controller, backedOut), "backing out returns to inspection")
  Assert.equal(selectionIndex(backedOut), 0, "backing out preserves the inspected ball")
  assertNoLegacyConfirmation(backedOut, "the backed-out chooser")

  Assert.isNil(controller:cancel(), "cancel from inspection is a no-op")
  Assert.isFalse(isDone(controller, snapshot(controller)), "inspection survives a second cancel")
end

function T.rotation_changes_selection_only_when_unconfirmed_and_settled()
  local controller = openController(0)
  rotate(controller, "right")
  Assert.equal(
    selectionIndex(snapshot(controller)),
    0,
    "rotation waits for its transition instead of jumping immediately"
  )
  settle(controller)
  Assert.equal(selectionIndex(snapshot(controller)), 1, "a settled right step advances one ball")
  Assert.isFalse(isDone(controller, snapshot(controller)), "rotation never publishes")

  rotate(controller, "left")
  settle(controller)
  Assert.equal(selectionIndex(snapshot(controller)), 0, "a settled left step returns one ball")

  controller:confirm()
  controller:confirm()
  settle(controller)
  Assert.isFalse(isDone(controller, snapshot(controller)), "the zoom path must settle into confirmation first")
  rotate(controller, "right")
  settle(controller)
  Assert.equal(selectionIndex(snapshot(controller)), 0, "rotation while confirmed stays on the confirmed ball")
  assertNoLegacyConfirmation(snapshot(controller), "rotation never introduces a yes/no cursor")
end

function T.transition_inputs_are_ignored_exactly_once_without_double_advance()
  local controller = openController(0)
  rotate(controller, "right")
  rotate(controller, "right")
  Assert.isNil(controller:confirm(), "activation mid-rotation must not queue a second step")
  Assert.isNil(controller:cancel(), "cancel mid-rotation must not corrupt the step")
  settle(controller)
  Assert.equal(
    selectionIndex(snapshot(controller)),
    1,
    "conflicting inputs during rotation collapse to one settled step"
  )
  Assert.isFalse(isDone(controller, snapshot(controller)), "mid-transition input never publishes")
end

function T.final_activation_locks_only_after_exit_settles_and_reports_current_selection()
  local controller = openController(0)
  rotate(controller, "right")
  settle(controller)
  Assert.equal(selectionIndex(snapshot(controller)), 1, "setup advances to the second ball")

  controller:confirm()
  controller:confirm()
  settle(controller)
  Assert.isFalse(isDone(controller, snapshot(controller)), "the zoom path must settle into confirmation first")

  Assert.isNil(controller:confirm(), "final activation starts the lock/exit, not the report")
  Assert.isFalse(isDone(controller, snapshot(controller)), "the report waits for the lock/exit transition to settle")
  settle(controller)
  local finished = snapshot(controller)
  Assert.isTrue(isDone(controller, finished), "the settled lock completes the application")
  Assert.equal(resultIndex(controller, finished), 1, "the settled lock reports the confirmed ball")
  Assert.isNil(controller:confirm(), "the semantic result is one-shot")
end

function T.pointer_capture_advances_inspect_confirm_and_backout()
  local controller = openController(0)
  controller:press(2)
  Assert.isNil(controller:release(0), "a drag across balls commits nothing")
  Assert.isFalse(isDone(controller, snapshot(controller)), "a mismatched release stays unconfirmed")

  controller:press(1)
  Assert.isNil(controller:release(1), "tapping another ball rotates toward it, never publishes")
  settle(controller)
  Assert.equal(selectionIndex(snapshot(controller)), 1, "the settled tap selects the tapped ball")
  Assert.isFalse(isDone(controller, snapshot(controller)), "tapping a ball never locks immediately")

  controller:press(1)
  Assert.isNil(controller:release(1), "tapping the current ball inspects it")
  Assert.isFalse(isDone(controller, snapshot(controller)), "inspecting never publishes")
  controller:press(1)
  Assert.isNil(controller:release(1), "tapping the inspected ball starts confirmation, not the lock")
  settle(controller)
  Assert.isFalse(isDone(controller, snapshot(controller)), "confirmation still waits for the final lock tap")

  controller:press(0)
  Assert.isNil(controller:release(0), "tapping away from the confirmed ball backs out")
  settle(controller)
  Assert.isFalse(isDone(controller, snapshot(controller)), "backing out returns without publishing")
  Assert.equal(selectionIndex(snapshot(controller)), 1, "backing out preserves the inspected ball")
end

function T.pointer_outside_backs_out_only_from_confirmation()
  local controller = openController(0)
  controller:press(nil)
  Assert.isNil(controller:release(nil), "an outside tap while unconfirmed commits nothing")
  Assert.isFalse(isDone(controller, snapshot(controller)), "an outside tap never publishes")
  Assert.equal(selectionIndex(snapshot(controller)), 0, "an outside tap keeps the ball")

  controller:confirm()
  controller:confirm()
  settle(controller)
  Assert.isFalse(isDone(controller, snapshot(controller)), "the zoom path must settle into confirmation first")

  controller:press(nil)
  Assert.isNil(controller:release(nil), "an outside tap backs out of confirmation")
  settle(controller)
  local backedOut = snapshot(controller)
  Assert.isFalse(isDone(controller, backedOut), "backing out returns without publishing")
  Assert.equal(selectionIndex(backedOut), 0, "backing out preserves the inspected ball")
  assertNoLegacyConfirmation(backedOut, "the backed-out chooser")
end

return { tests = T }
