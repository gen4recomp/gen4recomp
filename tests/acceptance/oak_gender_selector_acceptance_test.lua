-- Production-composed Oak profile selection through the real generated cache.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local NewGame = require("game.hgss.src.newgame.NewGame")
local OakIntroComposition = require("game.hgss.src.newgame.OakIntroComposition")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "graphics", "rom_dump", "derived_cache" },
    tags = { "oak", "new-game", "selector" },
  },
  tests = {},
}

local function candidate(versionId)
  return NewGame.createCandidate({
    saveService = {
      reserve = function()
        return "save-00000001"
      end,
    },
    versionId = versionId,
    eventState = FieldEventState.new(),
    scriptSymbols = FieldScriptSymbols,
    mapIdentity = {
      mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
      fieldX = 6,
      fieldZ = 6,
      sourceFacing = 1,
    },
  })
end

local function compose(versionId)
  local audio = FakeAudioOutput.new()
  return OakIntroComposition.compose({
    candidate = candidate(versionId),
    versionId = versionId,
    graphics = love.graphics,
    audioOutput = { audio = audio.audio, sound = audio.sound },
    clock = {
      nowLocal = function()
        return { year = 2026, month = 9, day = 15, hour = 12, minute = 0, second = 0 }
      end,
    },
    randomU32 = function()
      return 0x12345678
    end,
    width = 640,
    height = 480,
    textInputHost = { setTextInput = function() end },
  })
end

local function finishDialogue(state)
  local messageKey = assert(state:view().messageKey, "Oak selection requires an active dialogue")
  for _ = 1, 20000 do
    if state:view().messageKey ~= messageKey then
      return
    end
    local status = state.dialogueController:status()
    if status.state == "WAITING_BOUNDARY" or status.state == "WAITING_CLOSE" then
      state:keypressed("return")
    else
      state:tick(1)
    end
  end
  error("Oak dialogue did not reach its semantic completion boundary: " .. messageKey)
end

local function advanceUntil(state, messageKey)
  for _ = 1, 20000 do
    if state:view().messageKey == messageKey then
      return
    end
    if state.dialogueController:isModal() then
      finishDialogue(state)
    else
      state:tick(1)
    end
  end
  error("Oak dialogue did not open: " .. messageKey)
end

local function advanceUntilPhase(state, phase)
  for _ = 1, 200 do
    if state:view().phase == phase then
      return
    end
    if state.dialogueController:isModal() then
      finishDialogue(state)
    else
      state:tick(1)
    end
  end
  error("Oak did not reach phase " .. phase)
end

local function assertSelectorAssets(state, cache)
  local layout = assert(state:view().layout)
  local buttons = assert(layout.genderButtons)
  for gender = 0, 1 do
    local entry = assert(buttons[gender])
    Assert.isNil(entry.button, "production selector must not retain synthetic ImageButton geometry")
    local source = assert(state.manifest.genderSelector.buttons[gender == 0 and "male" or "female"])
    for _, field in ipairs({ "baseImage", "fillMaskImage", "rimMaskImage" }) do
      local path = assert(source[field], "generated selector contract is missing " .. field)
      Assert.isTrue(cache:exists(path, "file"), "generated selector asset is missing " .. path)
    end
  end
end

local function exerciseGender(versionId, focus)
  local state = compose(versionId)
  local cache = CacheFs.forVersion(versionId)
  local ok, err = xpcall(function()
    advanceUntil(state, "profile.gender_question")
    finishDialogue(state)
    state:keypressed("return")
    advanceUntilPhase(state, "gender_select")
    local selected = state:view()
    Assert.equal(selected.phase, "gender_select")
    if focus == 1 then
      state:keypressed("right")
      selected = state:view()
    end
    Assert.equal(selected.genderFocus, focus)
    assertSelectorAssets(state, cache)

    state:keypressed("return")
    finishDialogue(state)
    Assert.equal(state:view().phase, "gender_confirm")
  end, debug.traceback)
  state:dispose()
  if not ok then
    error(err, 0)
  end
end

T.tests.production_oak_selector_uses_retail_assets_and_preserves_gender_confirmation = function()
  local versionId = AcceptanceHarness.defaultVersion()
  exerciseGender(versionId, 0)
  exerciseGender(versionId, 1)
end

local function advanceToNaming(versionId)
  local state = compose(versionId)
  advanceUntil(state, "profile.gender_question")
  finishDialogue(state)
  state:keypressed("return")
  advanceUntilPhase(state, "gender_select")
  state:keypressed("return")
  finishDialogue(state)
  state:keypressed("return")
  finishDialogue(state)
  advanceUntilPhase(state, "name_edit")
  return state
end

T.tests.production_oak_name_entry_uses_the_retail_naming_surface = function()
  local state = advanceToNaming(AcceptanceHarness.defaultVersion())
  local view = state:view()
  Assert.notNil(view.namingScreen, "Oak name entry must expose the HGSS Naming Screen snapshot")
  state:dispose()
end

T.tests.production_oak_name_entry_routes_pointer_keyboard_and_gamepad_to_one_result = function()
  local state = advanceToNaming(AcceptanceHarness.defaultVersion())
  Assert.notNil(state:view().namingScreen, "all naming input paths require the Naming Screen boundary")
  state:textinput("GOLD")
  state:keypressed("backspace")
  Assert.equal(state:view().name, "GOL", "physical input and Back must share naming semantics")
  state:gamepadpressed(nil, "dpdown")
  state:touchpressed(nil, 0, 0)
  Assert.equal(state:view().name, "GOL", "directional and pointer input must not bypass text semantics")
  state:dispose()
end

return T
