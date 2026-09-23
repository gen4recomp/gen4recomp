-- Sparse-cache house exit: New Game through the Oak intro into Player's
-- House 2F, down the stairs to 1F, out the front door to New Bark, all
-- against a sparse derived cache that never prebuilds the old whole-corpus
-- closure or the neighboring Route 27 visual. The journey boots the real
-- application (real cache service, real provisioner host, real worker
-- compilation) and records every host demand through a pass-through
-- recorder: production behavior is unchanged, only observed.
--
-- The contract this journey freezes:
-- - New Bark commits and reaches an idle field with no readiness failure,
--   even though the Route 27 visual map is not complete at commit time.
-- - Route 27 (map header 31) is published as a logical resident.
-- - The destination demand enrolled the neighbor logical closure as
--   required and its visual map as near prefetch.
-- - No whole-corpus milestone demand ever fires.

local Assert = require("tests.support.Assert")
local App = require("app.src.App")
local FieldState = require("game.hgss.src.field.FieldState")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
local SaveFs = require("libs.storage.src.SaveFs")
local OakIntroComposition = require("game.hgss.src.newgame.OakIntroComposition")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local ProducerFingerprint = require("romdump.src.ProducerFingerprint")
local DerivedAssetProvisioner = require("app.src.DerivedAssetProvisioner")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "bootstrap" },
    tags = { "product", "opening", "sparse", "transition" },
    slow = true,
  },
  tests = {},
}

local JOYSTICK = {
  getID = function()
    return 1
  end,
}

local HOUSE_2F = "MAP_NEW_BARK_PLAYER_HOUSE_2F"
local HOUSE_1F = "MAP_NEW_BARK_PLAYER_HOUSE_1F"
local TOWN = "MAP_NEW_BARK"
local NEIGHBOR_MAP_ID = 31
local HOUSE_EXIT = { fieldX = 3, fieldZ = 10 }

local activeHostCalls = nil

local function recentCallTrace()
  if activeHostCalls == nil then
    return "no-trace"
  end
  local parts = {}
  local first = math.max(1, #activeHostCalls - 7)
  for i = first, #activeHostCalls do
    local call = activeHostCalls[i]
    parts[#parts + 1] = call.op .. "(" .. tostring(call.arguments[1]) .. "," .. tostring(call.arguments[2]) .. ")"
  end
  return table.concat(parts, " ")
end

local function isolatedBackend(namespace)
  local fs = love.filesystem
  local function map(path)
    return namespace .. "/" .. path:gsub("^saves/", "")
  end
  return {
    write = function(_, path, data)
      return fs.write(map(path), data)
    end,
    read = function(_, path)
      return fs.read(map(path))
    end,
    getInfo = function(_, path)
      return fs.getInfo(map(path))
    end,
    createDirectory = function(_, path)
      return fs.createDirectory(map(path))
    end,
    remove = function(_, path)
      return fs.remove(map(path))
    end,
    replace = function(_, source, destination)
      return os.rename(fs.getSaveDirectory() .. "/" .. map(source), fs.getSaveDirectory() .. "/" .. map(destination))
    end,
  }
end

local function clearCheckpoints(saveStore)
  for _, entry in ipairs(saveStore:list()) do
    saveStore:delete(entry.saveId)
  end
end

local function press(button)
  App.gamepadpressed(JOYSTICK, button)
  App.gamepadreleased(JOYSTICK, button)
end

local function tick(frames)
  for _ = 1, frames do
    App.update(1 / 60)
  end
end

-- A pass-through recorder around the real provisioner host: every demand is
-- logged with its urgency and then served by the real controller, so the
-- recorded trace proves which closures production actually enrolled.
local function recordingHost(realHost, calls)
  local recorded = {}
  for key, value in pairs(realHost) do
    if type(value) == "function" then
      recorded[key] = function(...)
        local arguments = { ... }
        calls[#calls + 1] = { op = key, arguments = arguments }
        return value(...)
      end
    else
      recorded[key] = value
    end
  end
  return recorded
end

local handoffPhases = {
  final_dialogue = true,
  final_fade_out = true,
  final_full_art_fade_in = true,
  final_full_art_hold = true,
  shrink_animation = true,
  shrink_handoff_cover = true,
  handoff_black = true,
}

local function completeOak()
  local interactive = {
    greeting = true,
    oak_welcome = true,
    oak_world_inhabited = true,
    oak_live_alongside = true,
    oak_tell_about_yourself = true,
    gender_question = true,
    gender_select = true,
    gender_confirm = true,
    name_prompt = true,
    name_confirm = true,
    final_dialogue = true,
  }
  local deadline = love.timer.getTime() + 900
  while love.timer.getTime() < deadline do
    Assert.notNil(App.state and App.state.state, "Oak must remain active until the profile is finalized")
    if App.state.state.runtime ~= nil then
      return
    end
    local current = assert(App.state and App.state.state, "Oak must remain active until the profile is finalized")
    if current.runtime ~= nil then
      return
    end
    local view = current.view and current:view() or nil
    if view == nil then
      tick(1)
    elseif view.phase == "name_edit" then
      App.textinput("GOLD")
      App.keypressed("left")
      App.keypressed("up")
      App.keypressed("return")
    elseif interactive[view.phase] then
      press("a")
    else
      tick(1)
    end
    -- The Oak-to-field handoff completes on a presented frame: like the
    -- sibling opening journey, draw through the final/shrink/handoff
    -- phases (re-fetching state after drawing, since a presented frame
    -- can complete the handoff) instead of ticking blindly past them.
    local after = App.state and App.state.state or nil
    local afterView = after and after.view and after:view() or nil
    if afterView ~= nil and handoffPhases[afterView.phase] then
      App.draw()
    end
  end
  error("Oak did not reach the opening field")
end

local function fieldStep(runtime, direction)
  if runtime.player.facing ~= direction then
    runtime.player:turn(direction)
  end
  runtime:press(direction)
  tick(2)
  runtime:release(direction)
  for _ = 1, 120 do
    tick(1)
    if runtime.player.motion == "idle" then
      return
    end
  end
  error("the production player did not finish moving " .. direction)
end

local function stepToward(runtime, targetX, targetZ)
  local player = runtime.player
  if player.fieldX < targetX then
    fieldStep(runtime, "east")
  elseif player.fieldX > targetX then
    fieldStep(runtime, "west")
  elseif player.fieldZ < targetZ then
    fieldStep(runtime, "south")
  elseif player.fieldZ > targetZ then
    fieldStep(runtime, "north")
  end
end

local function walkTo(runtime, targetX, targetZ)
  for _ = 1, 120 do
    if runtime.errorText then
      error(runtime.errorText)
    end
    if runtime.player.fieldX == targetX and runtime.player.fieldZ == targetZ then
      return
    end
    local beforeX, beforeZ = runtime.player.fieldX, runtime.player.fieldZ
    stepToward(runtime, targetX, targetZ)
    if runtime.runtimeMap.mapSymbol ~= HOUSE_1F then
      return
    end
    if runtime.player.fieldX == beforeX and runtime.player.fieldZ == beforeZ then
      error("the production walk to the house exit is blocked at " .. tostring(beforeX) .. "," .. tostring(beforeZ))
    end
  end
  error("the production player did not reach the house exit approach")
end

local function reachFirstFloor(runtime)
  for _ = 1, 3 do
    fieldStep(runtime, "west")
  end
  for _ = 1, 2 do
    fieldStep(runtime, "north")
  end
  Assert.equal(runtime.player.fieldX, 3)
  Assert.equal(runtime.player.fieldZ, 4)
  fieldStep(runtime, "west")
  local lastPhase, lastMap, lastMotion = "none", "none", "none"
  for _ = 1, 600 do
    if runtime.runtimeMap.mapSymbol == HOUSE_1F then
      return
    end
    if runtime.errorText then
      error(runtime.errorText)
    end
    tick(1)
    lastMap = runtime.runtimeMap and runtime.runtimeMap.mapSymbol or "none"
    lastMotion = runtime.player and runtime.player.motion or "none"
    lastPhase = runtime.transition and runtime.transition.phase or "none"
  end
  error(
    "the production field did not complete the Player's House stair warp"
      .. " (map="
      .. tostring(lastMap)
      .. " phase="
      .. tostring(lastPhase)
      .. " motion="
      .. tostring(lastMotion)
      .. " trace={"
      .. recentCallTrace()
      .. "}"
  )
end

local function waitForMom(runtime)
  local world = runtime.scripts.worldState
  local flags = FieldScriptSymbols.flagsByName
  for _ = 1, 2400 do
    if runtime:destinationWorldPresentable() then
      runtime:acknowledgeDestinationPresentation()
    end
    tick(1)
    if runtime.errorText then
      error(runtime.errorText)
    end
    if runtime.dialogue:isModal() then
      press("a")
    end
    if
      world:getVar(FieldScriptSymbols.variablesByName.VAR_SCENE_PLAYERS_HOUSE_1F) == 1
      and world:isFlagSet(flags.FLAG_GOT_BAG)
      and world:isFlagSet(flags.FLAG_GOT_TRAINER_CARD)
      and world:isFlagSet(flags.FLAG_GOT_SAVE_BUTTON)
      and world:isFlagSet(flags.FLAG_GOT_OPTIONS_BUTTON)
      and not world:isFlagSet(flags.FLAG_GOT_POKEGEAR)
    then
      for _ = 1, 120 do
        if not runtime.scripts.scheduler:explicitPlayerLocked() then
          break
        end
        tick(1)
      end
      return
    end
  end
  error("the generated opening Mom event did not release the field")
end

local function leaveHouse(runtime)
  walkTo(runtime, HOUSE_EXIT.fieldX, HOUSE_EXIT.fieldZ - 1)
  fieldStep(runtime, "south")
  -- The south step lands on the door warp tile; door triggers evaluate on
  -- direction input while standing, so press south once more into the door.
  fieldStep(runtime, "south")
  local lastPhase, lastMap, lastMotion, lastPos = "none", "none", "none", "none"
  -- The door destination is the first full outdoor visual compiled on this
  -- sparse root; like the Mom sequence it gets a multi-thousand-tick
  -- budget rather than the interior-warp budget.
  for _ = 1, 2400 do
    if runtime.errorText then
      error(runtime.errorText)
    end
    tick(1)
    lastMap = runtime.runtimeMap and runtime.runtimeMap.mapSymbol or "none"
    lastMotion = runtime.player and runtime.player.motion or "none"
    lastPhase = runtime.transition and runtime.transition.phase or "none"
    lastPos = runtime.player and (runtime.player.fieldX .. "," .. runtime.player.fieldZ) or "none"
    if
      runtime.runtimeMap.mapSymbol == TOWN
      and (runtime.transition == nil or runtime.transition.phase == "idle")
      and runtime.player.motion == "idle"
    then
      return runtime
    end
  end
  error(
    "the production field did not exit the Player's House to New Bark"
      .. " (map="
      .. tostring(lastMap)
      .. " phase="
      .. tostring(lastPhase)
      .. " motion="
      .. tostring(lastMotion)
      .. " pos="
      .. tostring(lastPos)
      .. " trace={"
      .. recentCallTrace()
      .. "})"
  )
end

local function hostCallsFor(calls, op, mapId, urgency)
  local matching = {}
  for _, call in ipairs(calls) do
    if call.op == op and call.arguments[1] == mapId and (urgency == nil or call.arguments[2] == urgency) then
      matching[#matching + 1] = call
    end
  end
  return matching
end

function T.tests.sparse_house_exit_reaches_new_bark_with_a_logical_route_27()
  local namespace = "acceptance/sparse-new-bark-exit"
  local audio = FakeAudioOutput.new()
  local saveStore = GameSaveStore.new(SaveFs.global(isolatedBackend(namespace)))
  clearCheckpoints(saveStore)
  local hostCalls = {}
  activeHostCalls = hostCalls
  local original = {
    opts = App.opts,
    state = App.state,
    fieldNew = FieldState.new,
    storeNew = GameSaveStore.new,
    oakCompose = OakIntroComposition.compose,
    appBackend = ProducerFingerprint.appBackend,
    gameHost = DerivedAssetProvisioner.gameHost,
  }
  local ok, err = xpcall(function()
    local oakHost = {
      audioOutput = { audio = audio.audio, sound = audio.sound },
      clock = {
        nowLocal = function()
          return { year = 2026, month = 8, day = 22, hour = 12, minute = 0, second = 0 }
        end,
      },
      randomU32 = function()
        return 0x12345678
      end,
    }
    rawset(GameSaveStore, "new", function()
      return saveStore
    end)
    rawset(OakIntroComposition, "compose", function(options)
      local input = {}
      for key, value in pairs(options) do
        input[key] = value
      end
      for key, value in pairs(oakHost) do
        input[key] = value
      end
      return original.oakCompose(input)
    end)
    rawset(DerivedAssetProvisioner, "gameHost", function(self)
      return recordingHost(original.gameHost(self), hostCalls)
    end)
    FieldState.new = function(game, fieldOptions)
      local input = {}
      for key, value in pairs(fieldOptions or {}) do
        input[key] = value
      end
      input.audioOutput = { audio = audio.audio, sound = audio.sound }
      return original.fieldNew(game, input)
    end
    App.opts = {
      test = false,
      actors = false,
      dev = true,
    }
    ProducerFingerprint.appBackend = function()
      return ProducerFingerprint.checkoutBackend(love.filesystem.getSourceBaseDirectory())
    end
    App.state = nil
    App._bootMainMenu({ AcceptanceHarness.defaultVersion() })
    local deadline = love.timer.getTime() + 60
    while love.timer.getTime() < deadline do
      local game = App.state
      local inner = game and game.state or nil
      local view = inner and inner.view and inner:view() or nil
      if view ~= nil and view.kind == "main_menu" then
        break
      end
      App.update(1 / 60)
    end
    Assert.equal(App.state.state:view().kind, "main_menu")
    press("a")
    completeOak()
    local runtime = assert(App.state.state.runtime, "New Game must enter the real field")
    for _ = 1, 240 do
      tick(1)
      if runtime.runtimeMap.mapSymbol == HOUSE_2F then
        break
      end
    end
    Assert.equal(runtime.runtimeMap.mapSymbol, HOUSE_2F, "the opening must land in Player's House 2F")
    Assert.isNil(runtime.errorText)
    -- Like the sibling opening journey, let the fresh entry settle before
    -- stepping: on a sparse cache the entry stage and script lock release
    -- later than on a warm cache, and presses during the lock are eaten
    -- without moving (fieldStep only waits for idle, it cannot tell an
    -- eaten press from a finished step).
    for _ = 1, 240 do
      tick(1)
      if runtime:destinationWorldPresentable() then
        runtime:acknowledgeDestinationPresentation()
        break
      end
    end
    for _ = 1, 240 do
      if runtime.session.mapEntryStage == nil and not runtime.scripts.scheduler:explicitPlayerLocked() then
        break
      end
      tick(1)
    end
    reachFirstFloor(runtime)
    waitForMom(runtime)
    leaveHouse(runtime)
    Assert.equal(runtime.runtimeMap.mapSymbol, TOWN, "the house exit must land in New Bark")
    Assert.isNil(runtime.errorText, "the sparse house exit must complete without a readiness failure")
    local residency = assert(runtime.residency, "the live field must own logical residency")
    local neighbor = residency:mapForId(NEIGHBOR_MAP_ID)
    Assert.notNil(neighbor, "Route 27 must be published as a logical resident of New Bark")
    Assert.equal(neighbor.mapId, NEIGHBOR_MAP_ID)
    -- The neighbor visual must not have gated the transition: re-observing
    -- its near visual demand through the production host must still report
    -- pending at commit time. The demand itself is idempotent, so this
    -- observation enrolls nothing new.
    local host = assert(runtime.derivedAssets, "the live field must keep its derived-asset host")
    local visualReady = host.requestField(NEIGHBOR_MAP_ID, "near")
    Assert.isFalse(visualReady, "the Route 27 visual map must not be complete when New Bark commits")
    -- The recorded production trace must show the exact demand the
    -- transition ran on: neighbor logical required, neighbor visual near,
    -- and never the old whole-corpus milestone.
    Assert.isTrue(
      #hostCallsFor(hostCalls, "requestLogicalField", NEIGHBOR_MAP_ID, "required") >= 1,
      "the destination demand must request the neighbor logical closure as required"
    )
    Assert.isTrue(
      #hostCallsFor(hostCalls, "requestField", NEIGHBOR_MAP_ID, "near") >= 1,
      "the destination demand must prefetch the neighbor visual map as near"
    )
    -- Only the bounded milestones may fire on the sparse path: planning,
    -- runtime, intro, and bootstrap. The deleted whole-corpus milestone
    -- must never appear.
    for _, call in ipairs(hostCalls) do
      if call.op == "requestMilestone" then
        local name = call.arguments[1]
        Assert.isTrue(
          name == "field-planning" or name == "field-runtime" or name == "new-game-intro" or name == "bootstrap",
          "no whole-corpus milestone demand may fire on the sparse path: " .. tostring(name)
        )
      end
    end
  end, debug.traceback)
  rawset(GameSaveStore, "new", original.storeNew)
  rawset(OakIntroComposition, "compose", original.oakCompose)
  rawset(DerivedAssetProvisioner, "gameHost", original.gameHost)
  App.setState(nil)
  App.opts = original.opts
  App.state = original.state
  FieldState.new = original.fieldNew
  ProducerFingerprint.appBackend = original.appBackend
  if not ok then
    error(err, 0)
  end
end

return T
