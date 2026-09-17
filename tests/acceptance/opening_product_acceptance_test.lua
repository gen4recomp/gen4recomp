-- One production-composed opening journey. Host seams make time, audio output,
-- randomness, and save-root location deterministic; App and its game states stay real.

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

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "product", "opening", "checkpoint" },
  },
  tests = {},
}

local JOYSTICK = {
  getID = function()
    return 1
  end,
}

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

local function withDrawRecorder(trace, fn)
  local originalDraw = love.graphics.draw
  rawset(love.graphics, "draw", function(image, _)
    local state = App.state and App.state.state
    local view = state and state.view and state:view() or nil
    if view and view.phase then
      trace[#trace + 1] = {
        image = image,
        phase = view.phase,
        primaryWidget = view.primaryWidget,
      }
    end
    -- Keep App.draw and OakIntroRenderer production-composed while stopping
    -- at the host draw boundary; image identity and ordering are the contract.
    return nil
  end)
  local ok, err = xpcall(fn, debug.traceback)
  love.graphics.draw = originalDraw
  if not ok then
    error(err, 0)
  end
end

local function inside(inner, outer)
  return inner ~= nil
    and outer ~= nil
    and inner.x >= outer.x
    and inner.y >= outer.y
    and inner.x + inner.width <= outer.x + outer.width
    and inner.y + inner.height <= outer.y + outer.height
end

local function disjoint(first, second)
  return first.x + first.width <= second.x
    or second.x + second.width <= first.x
    or first.y + first.height <= second.y
    or second.y + second.height <= first.y
end

local function roundedLogicalMetric(physicalPixels, scale)
  return math.floor(physicalPixels / scale + 0.5) * scale
end

local function assertReservedDialogueIsClear(layout)
  if layout.dialogue == nil then
    return
  end
  local dialogue = layout.dialogue.outerRect
  Assert.equal(dialogue.x, math.floor(dialogue.x), "dialogue X must align to the logical raster")
  Assert.equal(dialogue.y, math.floor(dialogue.y), "dialogue Y must align to the logical raster")
  for _, item in ipairs({
    layout.subject,
    layout.reveal,
    layout.oakRegion,
    layout.selectorRegion,
    layout.namingScreen and layout.namingScreen.nameSlots,
  }) do
    if item ~= nil then
      Assert.isTrue(disjoint(item, dialogue), "Oak content must not enter reserved dialogue")
    end
  end
  for _, item in pairs(layout.genderButtons or {}) do
    Assert.isTrue(disjoint(item.rect, dialogue), "gender choice must not enter reserved dialogue")
  end
  for _, item in pairs(layout.confirmationButtons or {}) do
    Assert.isTrue(disjoint(item.rect, dialogue), "confirmation choice must not enter reserved dialogue")
  end
end

local function assertWideHostMetrics(view, width, height)
  local surface = assert(view.pixelSurface)
  local layout = assert(view.layout)
  local scale = surface.placement.scale
  Assert.equal(surface.placement.frame.width, width)
  Assert.equal(surface.placement.frame.height, height)
  Assert.equal(layout.safeFrame.x * scale, roundedLogicalMetric(12, scale))
  Assert.equal(layout.stageContent.width * scale, roundedLogicalMetric(1120, scale))
  if layout.oakRegion then
    local selectorRegion = assert(layout.selectorRegion)
    Assert.equal(
      (selectorRegion.x - (layout.oakRegion.x + layout.oakRegion.width)) * scale,
      roundedLogicalMetric(8, scale)
    )
  else
    local selectorRegion = assert(layout.selectorRegion)
    local genderButtons = assert(layout.genderButtons)
    Assert.isTrue(inside(genderButtons[0].rect, selectorRegion))
    Assert.isTrue(inside(genderButtons[1].rect, selectorRegion))
  end
end

local function assertOneToOneHostMetrics(view, width, height)
  local surface = assert(view.pixelSurface)
  local layout = assert(view.layout)
  Assert.equal(surface.placement.scale, 1)
  local minimum = math.min(width, height)
  Assert.equal(layout.safeFrame.x, math.min(12, math.floor(minimum * 0.035 + 0.5)))
  if layout.oakRegion == nil then
    local selectorRegion = assert(layout.selectorRegion)
    local genderButtons = assert(layout.genderButtons)
    Assert.isTrue(inside(genderButtons[0].rect, selectorRegion))
    Assert.isTrue(inside(genderButtons[1].rect, selectorRegion))
    return
  end
  local oakRegion = assert(layout.oakRegion)
  local selectorRegion = assert(layout.selectorRegion)
  Assert.equal(selectorRegion.y - (oakRegion.y + oakRegion.height), math.min(8, math.floor(minimum * 0.02 + 0.5)))
end

local function assertProfileLayout(view)
  local layout = assert(view.layout, "the production Oak state must publish a layout")
  local logicalViewport =
    assert(view.pixelSurface, "the production Oak state must publish a pixel surface").logicalViewport
  Assert.equal(layout.viewport.width, logicalViewport.width)
  Assert.equal(layout.viewport.height, logicalViewport.height)
  assertReservedDialogueIsClear(layout)
  if view.phase == "gender_select" then
    Assert.isNil(layout.subject, "Oak must be absent while the selector is shown")
    Assert.isNil(layout.oakRegion, "Oak must be absent while the selector is shown")
    local selectorRegion = assert(layout.selectorRegion, "gender selection must publish a selector region")
    for gender = 0, 1 do
      local button = assert(layout.genderButtons and layout.genderButtons[gender])
      Assert.isTrue(inside(button.rect, selectorRegion), "gender button must stay inside the selector region")
      Assert.notNil(button.button, "gender card must resolve shared button geometry")
    end
  elseif view.phase == "name_edit" then
    local naming = assert(layout.namingScreen, "name editing must publish the Naming Screen")
    Assert.isNil(naming.placement, "the Oak-hosted Naming Screen must not carry a child placement")
    Assert.isNil(naming.scale, "the Oak-hosted Naming Screen must not carry a child scale")
    Assert.deepEqual(
      { width = naming.surface.width, height = naming.surface.height },
      { width = 256, height = 192 },
      "the Naming Screen surface must be canonical logical geometry"
    )
    Assert.isTrue(inside(naming.surface, layout.viewport), "Naming Screen must stay inside the viewport")
    local function insideSurface(region)
      return region.x >= 0
        and region.y >= 0
        and region.x + region.width <= naming.surface.width
        and region.y + region.height <= naming.surface.height
    end
    Assert.isTrue(insideSurface(naming.nameSlots), "name slots must stay inside the canonical surface")
    for row = 1, 6 do
      for column = 1, 13 do
        Assert.isTrue(
          insideSurface(naming.cells[row][column]),
          "Naming Screen cell must stay inside the canonical surface"
        )
      end
    end
  end
end

local function assertPhaseSubsequence(phases, expected)
  local cursor = 1
  for _, phase in ipairs(phases) do
    if phase == expected[cursor] then
      cursor = cursor + 1
      if cursor > #expected then
        return
      end
    end
  end
  error("Oak production phase trace stopped before " .. tostring(expected[cursor]), 0)
end

local function completeOak(onDraw)
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
  for _ = 1, 3600 do
    Assert.notNil(App.state and App.state.state, "Oak must remain active until the profile is finalized")
    if App.state.state.runtime ~= nil then
      return
    end
    if onDraw then
      onDraw()
    end
    local view = App.state.state:view()
    if view.phase == "name_edit" then
      App.textinput("GOLD")
      -- Navigate keyboard focus onto the virtual Confirm key before
      -- activating it, matching the one confirm-capable-device contract.
      App.keypressed("left")
      App.keypressed("return")
    elseif interactive[view.phase] then
      press("a")
    else
      tick(1)
    end
  end
  error("Oak did not reach the opening field")
end

local function fieldStep(runtime, direction)
  -- HGSS input turns in place before it walks whenever the pressed direction
  -- is not the player's current facing; settle that turn first (the same
  -- domain operation a script's `turn` performs) so the press below always
  -- resolves to a real production step, never a turn standing in for one.
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
  for _ = 1, 240 do
    if runtime.runtimeMap.mapSymbol == "MAP_NEW_BARK_PLAYER_HOUSE_1F" then
      return
    end
    tick(1)
  end
  error("the production field did not complete the Player's House stair warp")
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

local function openMenu(runtime)
  for _ = 1, 120 do
    local status = runtime.applicationHost:status()
    if status.menu then
      return status.menu
    end
    if status.phase == "closed" then
      press("x")
    end
    tick(1)
  end
  error("the source start menu must open after Mom")
end

-- Semantic Start Menu activation: direct id lookup in the published menu
-- status (loud on absence, never a directional walk), real pointer press at
-- the action's current manifest slot mapped through the runtime placement,
-- then a wait on the action's destination application. Field actions such
-- as Save carry no application id and return the action for host-state
-- assertions.
local function hostPointForAction(runtime, action)
  local slots = assert(runtime.uiManifest and runtime.uiManifest.startMenu.slots, "the menu manifest must carry slots")
  local slot = assert(slots[action.slotId], "the presented action must carry its destination slot")
  local placement = assert(runtime.startMenuPlacement, "the runtime must publish the start menu placement record")
  local readable = {
    frame = placement.frame,
    origin = placement.origin or { x = placement.frame.x, y = placement.frame.y },
    scale = placement.scale,
    logicalWidth = placement.logicalWidth,
    logicalHeight = placement.logicalHeight,
  }
  local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
  return LayoutGeometry.logicalToHost(readable, slot.x + slot.width / 2, slot.y + slot.height / 2)
end

local function choose(runtime, id)
  local menu = runtime.applicationHost:status().menu
  local found = nil
  if menu then
    for _, action in ipairs(menu.actions) do
      if action.id == id then
        found = action
        break
      end
    end
  end
  if found == nil then
    error("start menu action was not available: " .. id)
  end
  local hostX, hostY = hostPointForAction(runtime, found)
  runtime.input:pointerDown("touch:1", hostX, hostY)
  runtime.input:pointerUp("touch:1", hostX, hostY)
  tick(2)
  if found.targetApplication ~= nil then
    for _ = 1, 120 do
      if runtime.applicationHost:status().applicationId == found.targetApplication then
        return found
      end
      tick(1)
    end
    error("the start menu action did not launch its target application: " .. id)
  end
  return found
end

local function waitForHostPhase(runtime, phase, maxTicks)
  for _ = 1, maxTicks do
    if runtime.applicationHost:status().phase == phase then
      return
    end
    tick(1)
  end
  error("the application host did not reach phase " .. tostring(phase))
end

function T.tests.opening_reaches_and_restores_the_first_manual_checkpoint()
  local namespace = "acceptance/opening-product"
  local audio = FakeAudioOutput.new()
  local saveStore = GameSaveStore.new(SaveFs.global(isolatedBackend(namespace)))
  clearCheckpoints(saveStore)
  local handoffDraws = {}
  local original = {
    opts = App.opts,
    state = App.state,
    fieldNew = FieldState.new,
    storeNew = GameSaveStore.new,
    oakCompose = OakIntroComposition.compose,
    appBackend = ProducerFingerprint.appBackend,
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
    local finalizedRecord
    local phases = {}
    local seenPhases = {}
    local checkedResponsiveProfileLayout = false
    local initialWidth, initialHeight = love.graphics.getDimensions()
    FieldState.new = function(game, fieldOptions)
      finalizedRecord = game
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
      dev = false,
    }
    -- `love app/` mounts only app/ as its product VFS root. The repository
    -- source tree stands in for the packaged producer tree in this source-run
    -- acceptance, while App remains on its product (no checkout metadata) path.
    ProducerFingerprint.appBackend = function()
      return ProducerFingerprint.checkoutBackend(love.filesystem.getSourceBaseDirectory())
    end
    App.state = nil
    App._bootMainMenu({ AcceptanceHarness.defaultVersion() })
    Assert.equal(App.state.state:view().kind, "main_menu")
    Assert.equal(#saveStore:list(), 0)
    press("a")
    withDrawRecorder(handoffDraws, function()
      completeOak(function()
        local state = assert(App.state and App.state.state)
        local view = state:view()
        if not seenPhases[view.phase] then
          phases[#phases + 1] = view.phase
          seenPhases[view.phase] = true
        end
        assertProfileLayout(view)
        if view.phase == "gender_select" and not checkedResponsiveProfileLayout then
          checkedResponsiveProfileLayout = true
          for _, size in ipairs({ { 1705, 895 }, { 1710, 895 }, { 1920, 1080 }, { 390, 844 }, { 256, 1080 } }) do
            App.resize(size[1], size[2])
            local resizedView = state:view()
            assertProfileLayout(resizedView)
            if size[1] >= 1705 then
              assertWideHostMetrics(resizedView, size[1], size[2])
            elseif size[1] == 256 then
              assertOneToOneHostMetrics(resizedView, size[1], size[2])
            end
          end
          App.resize(initialWidth, initialHeight)
        end
        local phase = view.phase
        if
          phase == "final_dialogue"
          or phase == "final_fade_out"
          or phase == "final_full_art_fade_in"
          or phase == "final_full_art_hold"
          or phase == "shrink_animation"
          or phase == "shrink_handoff_cover"
          or phase == "handoff_black"
        then
          App.draw()
        end
      end)
    end)
    assertPhaseSubsequence(phases, {
      "greeting",
      "oak_welcome",
      "oak_world_inhabited",
      "oak_live_alongside",
      "oak_tell_about_yourself",
      "gender_question",
      "gender_select",
      "gender_confirm",
      "name_prompt",
      "name_launch_wait",
      "name_edit",
      "name_confirm",
      "final_dialogue",
      "shrink_animation",
      "shrink_handoff_cover",
      "handoff_black",
    })
    Assert.notNil(finalizedRecord, "the real New Game route must hand a finalized record to FieldState")
    local profile = assert(finalizedRecord.playerData and finalizedRecord.playerData.profile)
    Assert.equal(profile.name, "GOLD")
    Assert.equal(profile.gender, 0)
    Assert.equal(profile.trainerId, 0x12345678)
    local fullArtImages = {}
    local shrinkImages = {}
    for _, draw in ipairs(handoffDraws) do
      if draw.primaryWidget == "male" or draw.primaryWidget == "female" then
        fullArtImages[#fullArtImages + 1] = draw.image
      elseif draw.primaryWidget == "shrink_male" or draw.primaryWidget == "shrink_female" then
        shrinkImages[#shrinkImages + 1] = draw.image
      end
    end
    Assert.isTrue(#fullArtImages > 0, "full player art was never drawn before field entry")
    Assert.isTrue(#shrinkImages >= 2, "fewer than two shrink frames were drawn before field entry")
    Assert.isTrue(shrinkImages[1] ~= shrinkImages[2], "shrink frames reused one image")
    local runtime = assert(App.state.state.runtime)
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
    Assert.equal(runtime.runtimeMap.mapSymbol, "MAP_NEW_BARK_PLAYER_HOUSE_2F")
    Assert.equal(#saveStore:list(), 0)
    reachFirstFloor(runtime)
    waitForMom(runtime)
    openMenu(runtime)
    choose(runtime, "vanilla.trainer_card")
    Assert.equal(runtime.applicationHost:status().applicationId, "trainer_card")
    waitForHostPhase(runtime, "application", 120)
    press("b")
    tick(1)
    waitForHostPhase(runtime, "menu", 120)
    openMenu(runtime)
    choose(runtime, "vanilla.save")
    tick(3)
    local entries = saveStore:list()
    Assert.equal(#entries, 1)
    local checkpoint = assert(saveStore:load(entries[1].saveId))
    local savedMap = checkpoint.mapId
    App.setState(nil)
    App._bootMainMenu({ AcceptanceHarness.defaultVersion() })
    local restoredView = App.state.state:view()
    Assert.equal(#restoredView.saves + #restoredView.globalActions, 2)
    press("dpdown")
    press("a")
    tick(4)
    local continuedRuntime = assert(App.state.state.runtime, "Continue must enter the real FieldState")
    Assert.equal(continuedRuntime.runtimeMap.mapId, savedMap)
    App.draw()
    tick(4)
    App.draw()
    Assert.isTrue(continuedRuntime:destinationWorldPresentable(), "field remains presentable after entry draw")
    Assert.equal(#saveStore:list(), 1)
  end, debug.traceback)
  App.setState(nil)
  App.opts = original.opts
  App.state = original.state
  FieldState.new = original.fieldNew
  GameSaveStore.new = original.storeNew
  OakIntroComposition.compose = original.oakCompose
  ProducerFingerprint.appBackend = original.appBackend
  clearCheckpoints(saveStore)
  if not ok then
    error(err, 0)
  end
end

return T
