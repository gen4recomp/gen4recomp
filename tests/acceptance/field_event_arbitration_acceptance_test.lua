-- Production-composed field-event arbitration contracts. These scenarios use
-- ROM-derived maps and events through AcceptanceHarness and stop before draw.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local FieldMovement = require("tests.acceptance.support.FieldMovement")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")
local ScriptIdentity = require("libs.assets.src.ScriptIdentity")
local SignpostTrace = require("tests.acceptance.support.SignpostTrace")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "events", "warps", "interaction" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"
local LAB_2F = "MAP_NEW_BARK_ELMS_LAB_2F"
local MAILBOX_SCRIPT = "vanilla.hgss.scr_seq.0842.script_016"
local VAR_UNK_407C = FieldScriptSymbols.variablesByName.VAR_UNK_407C

local function withGame(map, fn, fieldOptions)
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = map,
    save = "fresh",
    fieldOptions = fieldOptions,
  })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0)
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function coordinateAt(game, fieldX, fieldZ)
  for _, event in ipairs(game.runtime.runtimeMap.fieldData.events.coordinates) do
    if
      fieldX >= event.x
      and fieldX < event.x + event.width
      and fieldZ >= event.z
      and fieldZ < event.z + event.height
    then
      return event
    end
  end
  return nil
end

local function setCoordinatePredicate(game, event, matching)
  game:setWorldState({
    variable = event.variableId,
    value = matching and event.requiredValue or event.requiredValue + 1,
  })
end

-- The generated coordinate event's `scriptId` is the raw one-based source
-- script index, not the composed identity the scheduler records under
-- `script.started`. Reuse the exact production formatter
-- (`Bindings.resolveIntent` -> `scriptIdFor`) instead of duplicating its
-- bank/offset convention here.
local function coordinateCanonicalScriptId(game, event)
  local scriptBankId =
    assert(game.runtime.runtimeMap.fieldData.scriptBankId, "generated map must declare its script bank id")
  return ScriptIdentity.formatVanilla(scriptBankId, event.scriptId - 1)
end

local function warpCellWithBehavior(game, behavior)
  local map = game.runtime.runtimeMap
  local origin = assert(map.coordinateOrigin)
  for _, warp in ipairs(map.fieldData.events.warps) do
    local localX, localZ = warp.x - origin.x, warp.z - origin.z
    if map.collision:containsLocal(localX, localZ) and map.collision:getLocal(localX, localZ).behavior == behavior then
      return { fieldX = warp.x, fieldZ = warp.z }
    end
  end
  return nil
end

function T.tests.literal_east_then_north_route_advances_each_production_move()
  withGame(TOWN, function(game)
    local player = game:snapshot().player
    local map = game.runtime.runtimeMap
    local origin = assert(map.coordinateOrigin)
    local localX, localZ = player.fieldX - origin.x, player.fieldZ - origin.z

    Assert.deepEqual({ player.fieldX, player.fieldZ }, { 682, 394 })
    Assert.isFalse(map.collision:isBlockedLocal(localX, localZ), "default town spawn must be passable")
    Assert.isFalse(map.collision:isBlockedLocal(localX, localZ + 1), "default town spawn must have a south exit")
    Assert.isFalse(map.collision:isBlockedLocal(localX + 1, localZ), "default town spawn must have an east exit")

    OpeningLifecycle.settleNewBarkFriendScene(game)
    local event = assert(coordinateAt(game, 688, 392), "the Elm landing must have a coordinate event")
    setCoordinatePredicate(game, event, true)
    local snapshots = FieldMovement.productionRoute(game, {
      "east",
      "east",
      "east",
      "east",
      "east",
      "east",
      "north",
      "north",
    })

    Assert.equal(#snapshots, 8)
    for index = 1, 6 do
      Assert.deepEqual(
        { snapshots[index].player.fieldX, snapshots[index].player.fieldZ },
        { 682 + index, 394 },
        "east production move " .. tostring(index) .. " must advance"
      )
    end
    Assert.deepEqual({ snapshots[7].player.fieldX, snapshots[7].player.fieldZ }, { 688, 393 })
    Assert.deepEqual({ snapshots[8].player.fieldX, snapshots[8].player.fieldZ }, { 688, 392 })
    Assert.equal(snapshots[8].mapSymbol, TOWN)
  end)
end

local function backgroundCell(game, eventType)
  local player = game:snapshot().player
  local selected
  local selectedDistance
  for _, event in ipairs(game.runtime.runtimeMap.fieldData.events.background) do
    if event.type == eventType and event.scriptId ~= 0 then
      if event.x == 685 and event.z == 400 then
        return event
      end
      local distance = math.abs(event.x - player.fieldX) + math.abs(event.z + 1 - player.fieldZ)
      if selectedDistance == nil or distance < selectedDistance then
        selected = event
        selectedDistance = distance
      end
    end
  end
  return selected
end

-- HGSS's arrival-warp suppression (WarpSystem.isSuppressed) still covers the
-- tile the incoming coordinate warp placed the player on; a standing
-- directional trigger on that exact tile needs the player to leave it once
-- before it can retrigger -- the production boundary these east-exit
-- scenarios actually require settled, not merely a wait.
local function reachElmLabEastExit(game)
  local cell = assert(
    warpCellWithBehavior(game, MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_EAST),
    "Elm Lab 2F must expose its east exit"
  )
  game:moveTo(cell)
  for _, direction in ipairs({ "south", "north", "west" }) do
    local destination = game.runtime.player:resolveStep(direction)
    if destination then
      game:moveTo({ fieldX = destination.fieldX, fieldZ = destination.fieldZ })
      game:moveTo(cell)
      break
    end
  end
  return cell
end

local function enterLab2F(game)
  OpeningLifecycle.settleNewBarkFriendScene(game)
  local event = assert(coordinateAt(game, 688, 392), "the Elm landing must have a coordinate event")
  setCoordinatePredicate(game, event, true)
  FieldMovement.activate(game, { fieldX = event.x, fieldZ = event.z }, "north")
  local transition = game:waitForTransition()
  Assert.equal(transition.destination.mapSymbol, LAB_2F)
end

function T.tests.walking_onto_elm_lab_enters_the_second_floor_without_a_turn()
  withGame(TOWN, function(game)
    Assert.isNil(game.runtime.scriptHosts, "the automatic Elm route must use the production-like composition")
    OpeningLifecycle.settleNewBarkFriendScene(game)
    local event = assert(coordinateAt(game, 688, 392), "the Elm landing must have a coordinate event")
    setCoordinatePredicate(game, event, true)
    game:moveTo({ fieldX = 688, fieldZ = 393 })
    local before = game:snapshot()
    Assert.deepEqual({ before.player.fieldX, before.player.fieldZ }, { 688, 393 })

    game:move("north")
    local screenFadeDirections = {}
    game:advanceUntil("Elm Lab automatic route completes", function(snapshot)
      if snapshot.screenFade and snapshot.screenFade.active then
        screenFadeDirections[snapshot.screenFade.direction] = true
      end
      return snapshot.mapSymbol == LAB_2F and snapshot.transition.phase == "idle" and not snapshot.fieldLocked
    end, 120)
    local destination = game:snapshot()
    Assert.equal(destination.mapSymbol, LAB_2F)
    Assert.deepEqual({ destination.player.fieldX, destination.player.fieldZ }, { 12, 6 })
    Assert.equal(destination.player.facing, "west")
    Assert.isFalse(destination.fieldLocked, "the completed route must release script ownership")
    Assert.equal(game.runtime.scripts.worldState:getVar(VAR_UNK_407C), 1)

    -- The Elm route is covered by the source-authored script screen fade, not
    -- an ordinary FieldTransition fade pair (source `FadeScreen -> WaitFade ->
    -- Warp -> FadeScreen -> WaitFade`).
    Assert.isTrue(screenFadeDirections["out"], "the route must use the production script screen fade-out")
    Assert.isTrue(screenFadeDirections["in"], "the route must use the production script screen fade-in")
    Assert.isTrue(
      destination.screenFade == nil or destination.screenFade.completed,
      "the final script screen fade must be clear at the settled destination"
    )
  end, { audioOutput = FakeAudioOutput.new() })
end

function T.tests.coordinate_priority_and_variable_gate_control_the_landing()
  withGame(TOWN, function(game)
    OpeningLifecycle.settleNewBarkFriendScene(game)
    local event = assert(coordinateAt(game, 688, 392), "the Elm landing must have a coordinate event")
    local coordinateScriptId = coordinateCanonicalScriptId(game, event)
    setCoordinatePredicate(game, event, true)
    FieldMovement.activate(game, { fieldX = event.x, fieldZ = event.z }, "north")
    local starts = game:recordsForScript(coordinateScriptId)
    Assert.equal(#starts, 1, "the matching coordinate event must start its own canonical script exactly once")
    Assert.equal(starts[1].payload.trigger.kind, "coordinate")
  end, { recordingScriptHosts = true })

  -- The coordinate-mismatch scenario: settle New Bark's own startup lifecycle
  -- first (the friend/Marill hide flags above, and any incidental init
  -- script that fires while stepping across the landing), then assert only
  -- that the coordinate event's own canonical script never starts. An
  -- unrelated ambient/background script sharing the same tile approach must
  -- not be mistaken for the coordinate trigger under test.
  withGame(TOWN, function(game)
    OpeningLifecycle.settleNewBarkFriendScene(game)
    local event = assert(coordinateAt(game, 688, 392), "the Elm landing must have a coordinate event")
    local coordinateScriptId = coordinateCanonicalScriptId(game, event)
    setCoordinatePredicate(game, event, false)
    local baseline = #game:recordsForScript(coordinateScriptId)
    FieldMovement.activate(game, { fieldX = event.x, fieldZ = event.z }, "north")
    Assert.equal(
      #game:recordsForScript(coordinateScriptId),
      baseline,
      "a mismatched coordinate variable must skip the coordinate event's own script"
    )
    Assert.equal(game:snapshot().mapSymbol, TOWN)
  end, { recordingScriptHosts = true })
end

function T.tests.elm_lab_second_floor_exits_east_through_production_input()
  withGame(TOWN, function(game)
    enterLab2F(game)
    reachElmLabEastExit(game)
    game:step({ direction = "east" })
    Assert.isFalse(game:snapshot().transition.phase == "idle", "the east exit must start from production input")
  end, { recordingScriptHosts = true })
end

function T.tests.passive_script_handoff_settles_the_player_visual()
  withGame(TOWN, function(game)
    local typeOne = assert(backgroundCell(game, 1), "a scripted type-one background event is required")
    game:moveTo({ fieldX = typeOne.x, fieldZ = typeOne.z + 2 })
    game.runtime.player.facing = "north"
    game:step({ direction = "north" })

    local handoff = game:advanceUntil("passive interaction ownership", function(snapshot)
      return snapshot.player.fieldX == typeOne.x and snapshot.player.fieldZ == typeOne.z + 1 and snapshot.fieldLocked
    end, 120)
    Assert.equal(handoff.playerVisual.pose, "idle")
    Assert.equal(handoff.playerVisual.poseTick, 0)

    local function copyCameraMatrix(view)
      local snapshot = {}
      for index = 1, 16 do
        snapshot[index] = view[index]
      end
      return snapshot
    end
    local function sample()
      return {
        player = game.runtime.player:renderPosition(0),
        camera = copyCameraMatrix(game.runtime.camera:view(0)),
      }
    end
    local first = sample()
    Assert.isFalse(
      first.camera == game.runtime.camera:view(0),
      "retained camera history must not alias the camera live view array"
    )
    for _, alpha in ipairs({ 0.5, 1 }) do
      Assert.deepEqual(game.runtime.player:renderPosition(alpha), first.player)
      Assert.deepEqual(game.runtime.camera:view(alpha), first.camera)
    end
    Assert.deepEqual(first.player, {
      x = game.runtime.player.worldX,
      y = game.runtime.player.worldY,
      z = game.runtime.player.worldZ,
    })

    game:step()
    game:step()
    game:step()
    game:step()
    local later = sample()
    Assert.deepEqual(later.player, first.player)
    Assert.deepEqual(later.camera, first.camera)
  end, { recordingScriptHosts = true })
end

function T.tests.mid_step_direction_edge_cannot_start_passive_sign()
  withGame(TOWN, function(game)
    local typeOne = assert(backgroundCell(game, 1), "a scripted type-one background event is required")
    game:moveTo({ fieldX = typeOne.x, fieldZ = typeOne.z + 1 })
    game:face("east")
    game.runtime.player.facing = "south"
    game:step({ direction = "south" })
    local walking = game:snapshot()
    Assert.equal(walking.player.motion, "walking", "the arbitration setup must enter a real movement step")
    local before = #game:recordsNamed("script.started")
    local establishedFacing = walking.player.facing

    game:step({ direction = "north" })

    Assert.equal(#game:recordsNamed("script.started"), before, "a fresh direction edge must not probe while walking")
    Assert.equal(game:snapshot().player.facing, establishedFacing, "the mid-step probe must not change facing")
  end, { recordingScriptHosts = true })
end

-- One traced opening must show exactly one activation, one wipe-in run, and a
-- single monotonic hidden-to-visible climb with a coherent hidden pair on the
-- activation frame. Returns the endpoint sample index so the caller can
-- delimit dismissal and repeat windows on the same trace.
local function assertSingleMonotonicWipe(trace, fromIndex, label)
  local samples = trace.samples
  local firstActive
  for index = fromIndex, #samples do
    if samples[index].signpost.active then
      firstActive = index
      break
    end
  end
  Assert.notNil(firstActive, label .. " must present the signpost window")
  local opening = samples[firstActive].signpost
  Assert.equal(opening.logicalYOffset, -48, label .. " must start hidden")
  Assert.equal(opening.previousLogicalYOffset, -48, label .. " must open with a coherent hidden interpolation pair")
  Assert.equal(
    samples[firstActive].wipe.alpha0,
    samples[firstActive].wipe.alpha1,
    label .. " must stay hidden for every render alpha on the activation frame"
  )

  local activations = 0
  local wipeRuns = 0
  local currents = {}
  local endpoint = nil
  local index = firstActive
  while index <= #samples do
    local sample = samples[index]
    local previous = samples[index - 1]
    if index == firstActive or not previous.signpost.active then
      activations = activations + 1
    end
    if sample.signpost.command == "wipe_in" and previous.signpost.command ~= "wipe_in" then
      wipeRuns = wipeRuns + 1
    end
    local lastCurrent = currents[#currents]
    if lastCurrent == nil or lastCurrent ~= sample.signpost.logicalYOffset then
      currents[#currents + 1] = sample.signpost.logicalYOffset
    end
    if sample.signpost.command == "nop" and sample.signpost.logicalYOffset == 0 then
      endpoint = index
      break
    end
    index = index + 1
  end
  Assert.notNil(endpoint, label .. " must complete its wipe-in to the presented position")
  Assert.equal(activations, 1, label .. " must activate the window exactly once")
  Assert.equal(wipeRuns, 1, label .. " must run a single wipe-in")
  Assert.deepEqual(currents, { -48, -32, -16, 0 }, label .. " must climb hidden to visible exactly once")
  for position = 2, #currents do
    Assert.isTrue(
      currents[position] >= currents[position - 1],
      label .. " must never reverse direction while wiping in"
    )
  end
  return endpoint
end

function T.tests.passive_mailbox_signpost_wipes_in_once_and_repeats_cleanly()
  withGame(TOWN, function(game)
    OpeningLifecycle.settleNewBarkFriendScene(game)
    -- The friend-house mailbox is a real type-1 background event: select it
    -- by canonical script identity and derive its tile from generated
    -- metadata, never from a magic coordinate.
    local bank = assert(game.runtime.runtimeMap.fieldData.scriptBankId, "generated map must declare its script bank id")
    local mailbox
    for _, event in ipairs(game.runtime.runtimeMap.fieldData.events.background) do
      if
        event.type == 1
        and event.scriptId ~= 0
        and ScriptIdentity.formatVanilla(bank, event.scriptId - 1) == MAILBOX_SCRIPT
      then
        mailbox = event
      end
    end
    Assert.notNil(mailbox, "New Bark must expose the type-1 friend-house mailbox")
    game:moveTo({ fieldX = mailbox.x, fieldZ = mailbox.z + 2 })
    game:face("north")

    local trace = SignpostTrace.attach(game)
    local function approachAndOpen(label)
      local baseline = #game:recordsForScript(MAILBOX_SCRIPT)
      local totalBaseline = #game:recordsNamed("script.started")
      trace:step({ direction = "north" })
      trace:advanceUntil(label .. " owns the field", function(snapshot)
        return snapshot.fieldLocked
      end, 120)
      local arrived = game:snapshot()
      Assert.deepEqual(
        { arrived.player.fieldX, arrived.player.fieldZ },
        { mailbox.x, mailbox.z + 1 },
        label .. " must settle one tile south of the mailbox"
      )
      Assert.equal(arrived.player.facing, "north", label .. " must keep facing the mailbox")
      Assert.equal(
        #game:recordsForScript(MAILBOX_SCRIPT),
        baseline + 1,
        label .. " must start the mailbox script exactly once"
      )
      Assert.equal(#game:recordsNamed("script.started"), totalBaseline + 1, label .. " must start no other script")
    end

    approachAndOpen("the northward approach")
    trace:advanceUntil("the mailbox signpost presents", function()
      return game.runtime.signpost:status().active
    end, 120)
    trace:advanceUntil("the first wipe-in completes", function()
      local status = game.runtime.signpost:status()
      return status.command == "nop" and status.logicalYOffset == 0
    end, 120)
    local firstEndpoint = assertSingleMonotonicWipe(trace, 1, "the first opening")

    local dismissed = nil
    for _ = 1, 480 do
      game.runtime:pressAction()
      trace:step()
      game.runtime:releaseAction()
      local snapshot = game:snapshot()
      if not snapshot.fieldLocked and not game.runtime.signpost:status().active then
        dismissed = snapshot
        break
      end
    end
    Assert.notNil(dismissed, "the mailbox signpost must dismiss through normal confirmation")
    local dismissEnd = #trace.samples
    Assert.isTrue(firstEndpoint < dismissEnd, "the dismissal must extend the trace past the first wipe")

    game:moveTo({ fieldX = mailbox.x, fieldZ = mailbox.z + 2 })
    game:face("north")
    trace:sample()
    approachAndOpen("the repeated northward approach")
    trace:advanceUntil("the repeated mailbox signpost presents", function()
      return game.runtime.signpost:status().active
    end, 120)
    trace:advanceUntil("the repeated wipe-in completes", function()
      local status = game.runtime.signpost:status()
      return status.command == "nop" and status.logicalYOffset == 0
    end, 120)
    assertSingleMonotonicWipe(trace, dismissEnd + 1, "the second opening")
  end, { recordingScriptHosts = true })
end

return T
