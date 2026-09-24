-- Warm first entry after a production fresh import: raw ROM import drives
-- the mandatory first-play preparation (C04) before the Main Menu, and the
-- first New Game after that preparation is the measured warm pass. The
-- Oak-handoff to usable-bedroom interval is timed from the ownership
-- transfer into FieldPreparationState (before any planning/runtime/location
-- wait) and must complete in under 2.0 seconds with no whole-corpus
-- milestone demand and no whole-family map enumeration. A deterministic
-- regression proves the timer includes pre-runtime readiness delay. Boots
-- the real application with the real cache service and records demand
-- through pass-through recorders.

local Assert = require("tests.support.Assert")
local App = require("app.src.App")
local FieldState = require("game.hgss.src.field.FieldState")
local FieldPreparationState = require("game.hgss.src.field.FieldPreparationState")
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

-- Test-local clock indirection: every handoff measurement reads
-- testClock.now(). It delegates to the wall clock by default; the
-- deterministic timing regression swaps in a manual clock. Production is
-- never touched.
local testClock = {
  now = function()
    return love.timer.getTime()
  end,
}
local wallNow = testClock.now

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

-- Observes the Oak -> field-preparation ownership transfer without
-- answering readiness differently: wraps FieldPreparationState.new,
-- latches the first New Game construction with a testClock timestamp taken
-- inside the installing update (before any planning/runtime/location
-- wait), then delegates to production. The latch must fire exactly once
-- per entry; later field states never retrigger it.
local function watchHandoff(onHandoff)
  local originalNew = FieldPreparationState.new
  local handoff = { count = 0, ts = nil }
  FieldPreparationState.new = function(options)
    local preparation = originalNew(options)
    if options ~= nil and options.kind == "newgame" then
      handoff.count = handoff.count + 1
      handoff.ts = testClock.now()
      if onHandoff ~= nil then
        onHandoff(handoff.count)
      end
    end
    return preparation
  end
  handoff.restore = function()
    FieldPreparationState.new = originalNew
  end
  return handoff
end

-- Drives the Oak intro from the installed Main Menu. With exitOnHandoff the
-- driver returns as soon as the handoff latch fires (the timestamp is
-- already captured inside the installing update); otherwise it drives
-- until the live runtime exists, mimicking the old post-runtime
-- measurement boundary for the timing regression.
local function driveOak(handoff, exitOnHandoff)
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
    if exitOnHandoff and handoff.count >= 1 then
      return
    end
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

local function waitForMenu(deadlineSeconds)
  local deadline = love.timer.getTime() + (deadlineSeconds or 120)
  while love.timer.getTime() < deadline do
    local game = App.state
    local inner = game and game.state or nil
    local view = inner and inner.view and inner:view() or nil
    if view ~= nil and view.kind == "main_menu" then
      return
    end
    App.update(1 / 60)
  end
  error("the Main Menu did not install")
end

local function menuInstalled()
  local game = App.state
  local inner = game and game.state or nil
  local view = inner and inner.view and inner:view() or nil
  return view ~= nil and view.kind == "main_menu"
end

local function waitForRuntime()
  local deadline = love.timer.getTime() + 600
  while love.timer.getTime() < deadline do
    local state = App.state and App.state.state or nil
    if state ~= nil and state.runtime ~= nil then
      return state.runtime
    end
    tick(1)
  end
  error("New Game must enter the real field")
end

-- Settles the transferred field to the existing usable-bedroom end
-- condition: House 2F active, no runtime error, destination presentation
-- acknowledged, map-entry initialization done, explicit lock released.
-- Returns the testClock end timestamp.
local function settleBedroom()
  local runtime = waitForRuntime()
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
  return testClock.now()
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

local FIRST_PLAY_MILESTONES = {
  "bootstrap",
  "new-game-intro",
  "field-planning",
  "field-runtime",
}

local function installCommonStubs(context, original)
  local oakHost = {
    audioOutput = { audio = context.audio.audio, sound = context.audio.sound },
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
    return context.saveStore
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
    return recordingHost(original.gameHost(self), context.trace)
  end)
  FieldState.new = function(game, fieldOptions)
    context.fieldConstructions = context.fieldConstructions + 1
    local input = {}
    for key, value in pairs(fieldOptions or {}) do
      input[key] = value
    end
    input.audioOutput = { audio = context.audio.audio, sound = context.audio.sound }
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
end

local function captureOriginals()
  return {
    opts = App.opts,
    state = App.state,
    fieldNew = FieldState.new,
    preparationNew = FieldPreparationState.new,
    storeNew = GameSaveStore.new,
    oakCompose = OakIntroComposition.compose,
    appBackend = ProducerFingerprint.appBackend,
    gameHost = DerivedAssetProvisioner.gameHost,
    provisionerNew = DerivedAssetProvisioner.new,
  }
end

local function restoreOriginals(original)
  rawset(GameSaveStore, "new", original.storeNew)
  rawset(OakIntroComposition, "compose", original.oakCompose)
  rawset(DerivedAssetProvisioner, "gameHost", original.gameHost)
  rawset(DerivedAssetProvisioner, "new", original.provisionerNew)
  App.setState(nil)
  App.opts = original.opts
  App.state = original.state
  FieldState.new = original.fieldNew
  FieldPreparationState.new = original.preparationNew
  ProducerFingerprint.appBackend = original.appBackend
  testClock.now = wallNow
end

-- Drives the real production post-extraction import path
-- (App._onImported -> mandatory first-play preparation -> menu) on an
-- isolated save namespace with a sparse derived root, and proves the C04
-- gate: the first-play preparation installs before the menu, requests the
-- exact first-play milestone set at required urgency, requests no corpus
-- work, and authorizes no background sweep before the menu installs.
local function driveImportToMenu(context, versionId)
  App.state = nil
  App._onImported(versionId)
  local sawFirstPlay = false
  local deadline = love.timer.getTime() + 1500
  while love.timer.getTime() < deadline do
    local state = App.state
    if state ~= nil and state.kind == "first-play" then
      sawFirstPlay = true
    end
    if menuInstalled() then
      break
    end
    App.update(1 / 60)
  end
  Assert.isTrue(menuInstalled(), "the Main Menu must install after production first-play preparation")
  Assert.isTrue(sawFirstPlay, "a fresh import must enter production first-play preparation before the menu")
  for _, name in ipairs(FIRST_PLAY_MILESTONES) do
    Assert.isTrue(
      #callsFor(context.trace.calls, "requestMilestone", name, "required") >= 1,
      "import preparation must request " .. name .. " at required urgency"
    )
  end
  for _, call in ipairs(context.trace.calls) do
    if call.op == "requestMilestone" then
      Assert.isTrue(
        call.arguments[1] ~= "complete",
        "mandatory import preparation must never request whole-corpus work"
      )
    end
  end
  Assert.isFalse(context.sweepCalls.beforeMenu, "background sweep must not authorize before the menu installs")
  Assert.equal(context.fieldConstructions, 0, "import preparation reserves no game candidate and constructs no field")
end

function T.tests.warm_new_game_entry_reaches_the_bedroom_without_a_corpus_build()
  local namespace = "acceptance/warm-field-entry-import"
  local audio = FakeAudioOutput.new()
  local saveStore = GameSaveStore.new(SaveFs.global(isolatedBackend(namespace)))
  clearCheckpoints(saveStore)
  local context = {
    audio = audio,
    saveStore = saveStore,
    trace = { calls = {} },
    sweepCalls = { beforeMenu = false, total = 0 },
    fieldConstructions = 0,
  }
  local original = captureOriginals()
  local handoff = watchHandoff(nil)
  local ok, err = xpcall(function()
    installCommonStubs(context, original)
    rawset(DerivedAssetProvisioner, "new", function(...)
      local provisioner = original.provisionerNew(...)
      local realWarmup = provisioner.startBackgroundWarmup
      provisioner.startBackgroundWarmup = function(self)
        context.sweepCalls.total = context.sweepCalls.total + 1
        if not menuInstalled() then
          context.sweepCalls.beforeMenu = true
        end
        return realWarmup(self)
      end
      return provisioner
    end)
    local versionId = AcceptanceHarness.defaultVersion()
    -- Phase 1: production fresh-import preparation warms the first-play
    -- closure. This is the only warm-up mechanism for the measured run:
    -- no prior New Game gameplay pass populates this namespace.
    driveImportToMenu(context, versionId)
    -- Phase 2: the first and only New Game gameplay run for this
    -- namespace, measured from the preparation handoff.
    context.trace.calls = {}
    context.fieldConstructions = 0
    waitForMenu()
    press("a")
    driveOak(handoff, true)
    Assert.equal(handoff.count, 1, "the handoff observation must fire exactly once per entry")
    local handoffTime = assert(handoff.ts, "the handoff timestamp must be captured at the ownership transfer")
    local endTime = settleBedroom()
    local entrySeconds = endTime - handoffTime
    Assert.isTrue(
      entrySeconds < WARM_ENTRY_BUDGET_SECONDS,
      "warm Oak handoff to usable bedroom frame must complete in under 2.0 seconds, measured "
        .. string.format("%.2f", entrySeconds)
    )
    Assert.equal(
      context.fieldConstructions,
      1,
      "the measured pass must be the first and only New Game gameplay run for this namespace"
    )
    -- Only bounded milestones may fire on the warm first game: planning,
    -- runtime, intro, and bootstrap. Polling repeats them while it waits,
    -- so repetition is accepted but anything outside the set fails.
    for _, call in ipairs(context.trace.calls) do
      if call.op == "requestMilestone" then
        local name = call.arguments[1]
        Assert.isTrue(
          name == "field-planning" or name == "field-runtime" or name == "new-game-intro" or name == "bootstrap",
          "no whole-corpus milestone demand may fire on the warm path: " .. tostring(name)
        )
      end
    end
    local distinctMaps = distinctRequiredMapIds(context.trace.calls)
    Assert.isTrue(
      distinctMaps <= WARM_ENTRY_DISTINCT_MAP_BOUND,
      "the warm entry must not enumerate whole map families, saw "
        .. tostring(distinctMaps)
        .. " distinct required map closures"
    )
  end, debug.traceback)
  handoff.restore()
  restoreOriginals(original)
  if not ok then
    error(err, 0)
  end
end

-- Deterministic timing-boundary regression: a test-local manual clock and
-- an injected readiness delay D prove the measured interval starts at the
-- Oak -> FieldPreparationState ownership transfer. The manual clock only
-- advances by the injected D at the handoff latch, so a timer that begins
-- after the runtime exists measures ~0 while the corrected timer measures
-- D. No real sleeping, no production API.
function T.tests.handoff_timer_includes_pre_runtime_readiness_delay()
  local injectedDelay = 120.0
  local manual = { now = 1000.0 }
  testClock.now = function()
    return manual.now
  end
  local namespace = "acceptance/warm-field-entry-timer"
  local audio = FakeAudioOutput.new()
  local saveStore = GameSaveStore.new(SaveFs.global(isolatedBackend(namespace)))
  clearCheckpoints(saveStore)
  local context = {
    audio = audio,
    saveStore = saveStore,
    trace = { calls = {} },
    fieldConstructions = 0,
  }
  local original = captureOriginals()
  local handoff = watchHandoff(function()
    manual.now = manual.now + injectedDelay
  end)
  local ok, err = xpcall(function()
    installCommonStubs(context, original)
    App.state = nil
    App._bootMainMenu({ AcceptanceHarness.defaultVersion() })
    waitForMenu()
    press("a")
    driveOak(handoff, false)
    Assert.equal(handoff.count, 1, "the handoff observation must fire exactly once per entry")
    local handoffTime = assert(handoff.ts, "the handoff timestamp must be captured at the ownership transfer")
    local oldStyleTime = testClock.now()
    local endTime = settleBedroom()
    -- Corrected measurement boundary (timestamp at the Oak ->
    -- FieldPreparationState ownership transfer): it includes the injected
    -- pre-runtime delay by construction.
    local newDuration = endTime - handoffTime
    Assert.isTrue(
      newDuration >= injectedDelay,
      "the handoff timer must include the injected pre-runtime delay, measured " .. string.format("%.2f", newDuration)
    )
    -- The old post-runtime boundary excludes the same delay: keeping the
    -- timer there would fail the bound above, which is the reviewed defect.
    local oldDuration = endTime - oldStyleTime
    Assert.isTrue(
      oldDuration < injectedDelay,
      "the post-runtime timer must exclude the injected pre-runtime delay, measured "
        .. string.format("%.2f", oldDuration)
    )
  end, debug.traceback)
  handoff.restore()
  restoreOriginals(original)
  if not ok then
    error(err, 0)
  end
end

return T
