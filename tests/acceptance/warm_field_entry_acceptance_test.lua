-- Warm-cache field entry: the same New Game opening measured twice against one
-- persistent derived root. The first (cold) pass compiles demand and records
-- urgency/kind accounting as evidence; the second (warm) pass freezes the
-- product contract: Oak handoff to the first usable bedroom frame completes
-- in under 2.0 seconds with no whole-corpus milestone demand and no
-- whole-family map enumeration. Boots the real application with the real
-- cache service and records demand through a pass-through recorder.

local Assert = require("tests.support.Assert")
local App = require("app.src.App")
local FieldState = require("game.hgss.src.field.FieldState")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
local SaveFs = require("libs.storage.src.SaveFs")
local OakIntroComposition = require("game.hgss.src.newgame.OakIntroComposition")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local ProducerFingerprint = require("romdump.src.ProducerFingerprint")
local DerivedAssetProvisioner = require("app.src.DerivedAssetProvisioner")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "bootstrap" },
    tags = { "product", "opening", "warm-entry" },
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

-- The warm contract: Oak handoff to usable bedroom frame, seconds.
local WARM_ENTRY_BUDGET_SECONDS = 2.0
-- Demand fan-out bound for one warm entry: the destination full/logical
-- closure, footprint neighbors, and one level of warp exits. Whole-corpus
-- enumeration would enroll hundreds of map ids; this bound admits the
-- bounded closure with margin while failing any family-wide walk.
local WARM_ENTRY_DISTINCT_MAP_BOUND = 12

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
local function recordingHost(realHost, trace)
  local recorded = {}
  for key, value in pairs(realHost) do
    if type(value) == "function" then
      recorded[key] = function(...)
        local arguments = { ... }
        trace.calls[#trace.calls + 1] = { op = key, arguments = arguments }
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
    local after = App.state and App.state.state or nil
    local afterView = after and after.view and after:view() or nil
    if afterView ~= nil and handoffPhases[afterView.phase] then
      App.draw()
    end
  end
  error("Oak did not reach the opening field")
end

-- Runs one full New Game entry: menu boot, Oak, bedroom settle. Returns the
-- live runtime and the Oak-handoff to usable-bedroom wall time in seconds.
local function runEntryPass()
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
  local handoffTime = love.timer.getTime()
  local runtime = assert(App.state.state.runtime, "New Game must enter the real field")
  for _ = 1, 240 do
    tick(1)
    if runtime.runtimeMap.mapSymbol == HOUSE_2F then
      break
    end
  end
  Assert.equal(runtime.runtimeMap.mapSymbol, HOUSE_2F, "the opening must land in Player's House 2F")
  Assert.isNil(runtime.errorText)
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
  Assert.isNil(runtime.errorText, "the bedroom entry must complete without a readiness failure")
  return runtime, love.timer.getTime() - handoffTime
end

local function callsFor(calls, op, first, urgency)
  local matching = {}
  for _, call in ipairs(calls) do
    if
      call.op == op
      and (first == nil or call.arguments[1] == first)
      and (urgency == nil or call.arguments[2] == urgency)
    then
      matching[#matching + 1] = call
    end
  end
  return matching
end

local function distinctRequiredMapIds(calls)
  local seen = {}
  for _, call in ipairs(calls) do
    if (call.op == "requestLogicalField" or call.op == "requestField") and call.arguments[2] == "required" then
      seen[call.arguments[1]] = true
    end
  end
  local count = 0
  for _ in pairs(seen) do
    count = count + 1
  end
  return count
end

function T.tests.warm_new_game_entry_reaches_the_bedroom_without_a_corpus_build()
  local namespace = "acceptance/warm-field-entry"
  local audio = FakeAudioOutput.new()
  local saveStore = GameSaveStore.new(SaveFs.global(isolatedBackend(namespace)))
  clearCheckpoints(saveStore)
  local trace = { calls = {} }
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
      return recordingHost(original.gameHost(self), trace)
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
    -- Cold pass: compiles demand and records urgency/kind accounting.
    -- Cold pass: compiles demand and records urgency/kind accounting.
    local coldRuntime, _ = runEntryPass()
    Assert.isTrue(
      #callsFor(trace.calls, "requestMilestone", "field-runtime", "required") >= 1,
      "the cold entry must demand field runtime as required (the session expands it to the script summary internally)"
    )
    Assert.isTrue(
      coldRuntime.derivedAssets.requestMilestone("field-runtime", "required"),
      "field runtime must be ready by bedroom entry"
    )
    -- Warm pass against the same root: the product contract.
    trace.calls = {}
    clearCheckpoints(saveStore)
    App.setState(nil)
    local _, entrySeconds = runEntryPass()
    Assert.isTrue(
      entrySeconds < WARM_ENTRY_BUDGET_SECONDS,
      "warm Oak handoff to usable bedroom frame must complete in under 2.0 seconds, measured "
        .. string.format("%.2f", entrySeconds)
    )
    Assert.equal(
      #callsFor(trace.calls, "requestMilestone"),
      0,
      "the warm entry must not request the old whole-corpus milestone"
    )
    local distinctMaps = distinctRequiredMapIds(trace.calls)
    Assert.isTrue(
      distinctMaps <= WARM_ENTRY_DISTINCT_MAP_BOUND,
      "the warm entry must not enumerate whole map families, saw "
        .. tostring(distinctMaps)
        .. " distinct required map closures"
    )
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
