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

-- Runs the controller's observation gate until the snapshot stops changing
-- or the bound is reached. Every observation flag reads complete, so each
-- transition settles on its own predicate; controllers without an update
-- hook settle immediately.
local function settle(controller, bound)
  bound = bound or 64
  local complete = {
    rotationComplete = true,
    cameraComplete = true,
    ballArcComplete = true,
    smallWobbleReady = true,
    infoFadeComplete = true,
    machineFadeComplete = true,
  }
  for _ = 1, bound do
    local before = snapshot(controller)
    if type(controller.update) == "function" then
      controller:update(complete)
    elseif type(controller.tick) == "function" then
      controller:tick()
    elseif type(controller.updateFixed) == "function" then
      controller:updateFixed()
    elseif type(controller.advance) == "function" then
      controller:advance()
    elseif type(controller.step) == "function" then
      controller:step()
    else
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

function T.tap_on_another_ball_starts_single_rotation_on_press()
  local controller = openController(0)
  controller:tap(1)
  local started = snapshot(controller)
  Assert.equal(started.transition, "rotate", "the press edge rotates without waiting for release")
  Assert.equal(started.direction, "right", "tapping the next ball rotates right")
  Assert.equal(selectionIndex(started), 0, "semantic selection waits for rotation settlement")

  controller:tap(2)
  local gated = snapshot(controller)
  Assert.equal(gated.transition, "rotate", "a second press during rotation queues nothing")
  Assert.equal(gated.direction, "right", "the in-flight direction survives a conflicting press")
  settle(controller)
  Assert.equal(selectionIndex(snapshot(controller)), 1, "the settled press selects the first tapped ball")

  local wraparound = openController(0)
  wraparound:tap(2)
  Assert.equal(snapshot(wraparound).direction, "left", "tapping the previous ball rotates left")
  settle(wraparound)
  Assert.equal(selectionIndex(snapshot(wraparound)), 2, "the settled left step reaches the tapped ball")
end

function T.tap_on_current_ball_walks_inspect_confirm_lock_without_release()
  local controller = openController(0)
  controller:tap(nil)
  Assert.equal(snapshot(controller).selectionState, "null", "a press miss while unconfirmed stays idle")

  controller:tap(0)
  Assert.equal(snapshot(controller).selectionState, "inspect", "pressing the current ball inspects")
  Assert.isFalse(isDone(controller, snapshot(controller)), "inspection still waits for confirmation")

  controller:tap(nil)
  Assert.equal(snapshot(controller).selectionState, "inspect", "a press miss while inspecting stays idle")

  controller:tap(0)
  Assert.equal(snapshot(controller).transition, "zoomIn", "pressing the inspected ball starts confirmation")
  controller:tap(0)
  Assert.equal(snapshot(controller).transition, "zoomIn", "a second press during zoom queues nothing")
  settle(controller)
  Assert.equal(snapshot(controller).selectionState, "confirm", "the zoom path settles into confirmation")

  controller:tap(1)
  Assert.equal(snapshot(controller).transition, "backOut", "pressing away from confirmation backs out")
  settle(controller)
  Assert.equal(snapshot(controller).selectionState, "inspect", "backing out returns to inspection")

  controller:tap(0)
  settle(controller)
  Assert.equal(snapshot(controller).selectionState, "confirm", "the second zoom path settles into confirmation")
  controller:tap(nil)
  Assert.equal(snapshot(controller).transition, "backOut", "a press miss in confirmation backs out")
  settle(controller)
  Assert.equal(snapshot(controller).selectionState, "inspect", "an outside press preserves the inspected ball")

  controller:tap(0)
  settle(controller)
  controller:tap(0)
  Assert.equal(snapshot(controller).transition, "lockExit", "pressing the confirmed ball locks on press")
  settle(controller)
  local finished = snapshot(controller)
  Assert.isTrue(isDone(controller, finished), "the settled lock completes the application")
  Assert.equal(resultIndex(controller, finished), 0, "the settled lock reports the confirmed ball")
end

function T.confirm_requires_small_wobble_readiness_beyond_camera_and_arc()
  local controller = openController(0)
  Assert.isNil(controller:confirm(), "first activation inspects instead of publishing")
  Assert.isNil(controller:confirm(), "second activation starts the zoom path, not the lock")

  -- The camera and ball arc may both report complete while the selected ball
  -- is still in its large rock: confirmation must wait for the small-wobble
  -- phase. Unrelated completion flags stay false so the gate cannot be
  -- satisfied by an aggregate tick count.
  local waiting = {
    rotationComplete = false,
    cameraComplete = true,
    ballArcComplete = true,
    smallWobbleReady = false,
    infoFadeComplete = false,
    machineFadeComplete = false,
  }
  for _ = 1, 8 do
    controller:update(waiting)
  end
  local zooming = snapshot(controller)
  Assert.isFalse(isDone(controller, zooming), "the zoom path settles only on its own completion")
  Assert.isTrue(
    zooming.selectionState ~= "confirm",
    "camera and arc completion alone must not confirm before the small wobble"
  )
  for _ = 1, 8 do
    controller:update(waiting)
  end
  local stillWaiting = snapshot(controller)
  Assert.isFalse(isDone(controller, stillWaiting), "waiting on the wobble never publishes")
  Assert.isTrue(
    stillWaiting.selectionState ~= "confirm",
    "a second elapsed camera window still must not confirm a large rock"
  )
  Assert.equal(selectionIndex(stillWaiting), 0, "waiting preserves the inspected ball")

  local ready = {
    rotationComplete = false,
    cameraComplete = true,
    ballArcComplete = true,
    smallWobbleReady = true,
    infoFadeComplete = false,
    machineFadeComplete = false,
  }
  local confirmed = nil
  for _ = 1, 16 do
    controller:update(ready)
    confirmed = snapshot(controller)
    if confirmed.selectionState == "confirm" then
      break
    end
  end
  Assert.notNil(confirmed, "the zoom path reports its state")
  Assert.equal(confirmed.selectionState, "confirm", "the small wobble releases confirmation")
  Assert.equal(selectionIndex(confirmed), 0, "confirmation preserves the inspected ball")
end

function T.transitions_ignore_unrelated_observations_and_repeated_false_updates()
  local controller = openController(0)
  rotate(controller, "right")
  local unrelated = {
    rotationComplete = false,
    cameraComplete = true,
    ballArcComplete = true,
    smallWobbleReady = true,
    infoFadeComplete = true,
    machineFadeComplete = true,
  }
  for _ = 1, 16 do
    controller:update(unrelated)
  end
  Assert.equal(
    selectionIndex(snapshot(controller)),
    0,
    "rotation waits for its own completion despite every unrelated flag"
  )
  local completing = {
    rotationComplete = true,
    cameraComplete = false,
    ballArcComplete = false,
    smallWobbleReady = false,
    infoFadeComplete = false,
    machineFadeComplete = false,
  }
  controller:update(completing)
  Assert.equal(selectionIndex(snapshot(controller)), 1, "rotation settles on its own completion")

  Assert.isNil(controller:confirm(), "first activation inspects instead of publishing")
  Assert.isNil(controller:confirm(), "second activation starts the zoom path, not the lock")
  local zoomUnrelated = {
    rotationComplete = true,
    cameraComplete = true,
    ballArcComplete = false,
    smallWobbleReady = true,
    infoFadeComplete = true,
    machineFadeComplete = true,
  }
  for _ = 1, 8 do
    controller:update(zoomUnrelated)
  end
  local zooming = snapshot(controller)
  Assert.equal(zooming.transition, "zoomIn", "the zoom path waits for both the camera and the ball arc")
  local arcReady = {
    rotationComplete = true,
    cameraComplete = true,
    ballArcComplete = true,
    smallWobbleReady = false,
    infoFadeComplete = true,
    machineFadeComplete = true,
  }
  controller:update(arcReady)
  Assert.equal(snapshot(controller).transition, "waitZoom", "camera and arc together release the zoom step")
  for _ = 1, 8 do
    controller:update(arcReady)
  end
  Assert.equal(
    snapshot(controller).selectionState,
    "inspect",
    "repeated wobble-false updates never confirm on unrelated flags"
  )
  local wobbleOnly = {
    rotationComplete = false,
    cameraComplete = false,
    ballArcComplete = false,
    smallWobbleReady = true,
    infoFadeComplete = false,
    machineFadeComplete = false,
  }
  controller:update(wobbleOnly)
  Assert.equal(snapshot(controller).selectionState, "confirm", "the wobble alone releases confirmation")

  Assert.isNil(controller:confirm(), "final activation starts the lock, not the report")
  local earlyFade = {
    rotationComplete = true,
    cameraComplete = true,
    ballArcComplete = true,
    smallWobbleReady = true,
    infoFadeComplete = true,
    machineFadeComplete = false,
  }
  for _ = 1, 8 do
    controller:update(earlyFade)
  end
  Assert.isFalse(isDone(controller, snapshot(controller)), "the info fade alone never publishes the result")
  local machineOnly = {
    rotationComplete = false,
    cameraComplete = false,
    ballArcComplete = false,
    smallWobbleReady = false,
    infoFadeComplete = false,
    machineFadeComplete = true,
  }
  controller:update(machineOnly)
  local finished = snapshot(controller)
  Assert.isTrue(isDone(controller, finished), "the machine fade completes the lock")
  Assert.equal(resultIndex(controller, finished), 1, "the settled lock reports the confirmed ball")
end

return { tests = T }
